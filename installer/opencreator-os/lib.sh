# shellcheck shell=sh disable=SC2034
# (SC2034: variables set here are used by the scripts that source this file)
# Shared helpers for the opencreator-os installer scripts that run on the
# stock Creator 5 Pro firmware (busybox sh). Sourced, not executed.
#
# Every path the scripts touch can be overridden through the environment so
# the installer can be exercised against plain files on a PC; the defaults are
# the stock printer's.
#   C5_DISK        eMMC disk; partitions are ${C5_DISK}pN      (/dev/mmcblk0)
#   C5_FDISK       fdisk binary, run as "$C5_FDISK -l $C5_DISK" (fdisk)
#   C5_SYSBLOCK    sysfs block class directory                (/sys/class/block)
#   C5_CMDLINE     kernel command line file                   (/proc/cmdline)
#   C5_MOUNTS      mount table                                (/proc/mounts)
#   C5_DATA        stock userdata mount point                 (/usr/data)
#   C5_FB          framebuffer device                         (/dev/fb0)
#   C5_DROP_CACHES page cache control file                    (/proc/sys/vm/drop_caches)
#   C5_REBOOT      reboot command                             (reboot)
#   C5_UNAME_R     kernel release                             ($(uname -r))
#   C5_SUM         force md5sum or sha256sum                  (sha256sum if present)
# Callers set STICK (directory for the stick-side log) and FBDIR (screen
# images) as needed; LOG_STICK_NAME / LOG_DATA_NAME name the log files on
# the stick and in $OCDIR.

C5_DISK=${C5_DISK:-/dev/mmcblk0}
C5_FDISK=${C5_FDISK:-fdisk}
C5_SYSBLOCK=${C5_SYSBLOCK:-/sys/class/block}
C5_CMDLINE=${C5_CMDLINE:-/proc/cmdline}
C5_MOUNTS=${C5_MOUNTS:-/proc/mounts}
C5_DATA=${C5_DATA:-/usr/data}
C5_FB=${C5_FB:-/dev/fb0}
C5_DROP_CACHES=${C5_DROP_CACHES:-/proc/sys/vm/drop_caches}
C5_REBOOT=${C5_REBOOT:-reboot}
C5_UNAME_R=${C5_UNAME_R:-$(uname -r)}

OCDIR=$C5_DATA/opencreator-os
UIMAGE_MAGIC=27051956
SQUASHFS_MAGIC=hsqs
LOG_STICK_NAME=${LOG_STICK_NAME:-opencreator-os-install.log}
LOG_DATA_NAME=${LOG_DATA_NAME:-install.log}

# --- logging and screen ------------------------------------------------------

log() {
	log_line="$(date '+%F %T') $*"
	echo "$*"
	if [ -n "${STICK:-}" ] && [ -d "$STICK" ]; then
		echo "$log_line" >> "$STICK/$LOG_STICK_NAME" 2>/dev/null
	fi
	if mkdir -p "$OCDIR" 2>/dev/null; then
		echo "$log_line" >> "$OCDIR/$LOG_DATA_NAME" 2>/dev/null
	fi
	return 0
}

die() {
	log "abort: $*"
	return 1
}

# show NAME: put FBDIR/NAME.raw on the panel (stock does the same with cat).
show() {
	[ -n "${FBDIR:-}" ] && [ -f "$FBDIR/$1.raw" ] && [ -e "$C5_FB" ] || return 0
	cat "$FBDIR/$1.raw" > "$C5_FB" 2>/dev/null
	return 0
}

drop_caches() {
	sync
	echo 3 > "$C5_DROP_CACHES" 2>/dev/null
	return 0
}

# --- partitions ----------------------------------------------------------------

# part_map: "NAME NR" for every GPT entry of C5_DISK. Uses the same fdisk -l
# listing stock's mmc_name_to_dev parses (NR START END SIZE NAME; name last).
part_map() {
	"$C5_FDISK" -l "$C5_DISK" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $NF, $1 }'
}

# part_table: "NAME NR START SIZE" (sectors) per GPT entry, the format of
# tools/printer/phase0.sh's partmap.txt.
part_table() {
	"$C5_FDISK" -l "$C5_DISK" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $NF, $1, $2, $3 - $2 + 1 }'
}

# part_dev NAME -> /dev/mmcblk0pN; fails when NAME is not unique or absent.
part_dev() {
	pd_nr=$(part_map | awk -v n="$1" '$1 == n { print $2; c++ } END { if (c != 1) exit 1 }') || return 1
	[ -n "$pd_nr" ] || return 1
	echo "${C5_DISK}p$pd_nr"
}

# part_bytes DEV -> size in bytes (sysfs counts 512-byte sectors).
part_bytes() {
	pb_sz=$(cat "$C5_SYSBLOCK/${1##*/}/size" 2>/dev/null) || return 1
	case "$pb_sz" in '' | *[!0-9]*) return 1 ;; esac
	echo $((pb_sz * 512))
}

slot_kname() { if [ "$1" = 2 ]; then echo kernel2; else echo kernel; fi; }
slot_rname() { if [ "$1" = 2 ]; then echo rootfs2; else echo rootfs; fi; }
other_slot() { if [ "$1" = 2 ]; then echo 1; else echo 2; fi; }

cmdline_root() { sed -n 's/.*[[:space:]]root=\([^[:space:]]*\).*/\1/p; s/^root=\([^[:space:]]*\).*/\1/p' "$C5_CMDLINE" | head -n 1; }

# own_slot -> 1 | 2 for the running root= device; fails otherwise.
own_slot() {
	os_root=$(cmdline_root)
	[ -n "$os_root" ] || return 1
	[ "$os_root" = "$(part_dev rootfs)" ] && { echo 1; return 0; }
	[ "$os_root" = "$(part_dev rootfs2)" ] && { echo 2; return 0; }
	return 1
}

is_mounted() { awk -v d="$1" '$1 == d { f = 1 } END { exit !f }' "$C5_MOUNTS"; }

# --- boot flag (first sector of the ota partition) ---------------------------

flag_read() {
	fr_dev=$(part_dev ota) || return 1
	head -c 11 "$fr_dev" | tr -d '\000\n'
}

# The SPL boots slot 2 only when the first 11 bytes are "ota:kernel2".
flag_slot() {
	fs_val=$(flag_read) || return 1
	if [ "$fs_val" = "ota:kernel2" ]; then echo 2; else echo 1; fi
}

# flag_write SLOT: whole 512-byte sector, NUL padded, then read back.
flag_write() {
	case "$1" in 1) fw_s=ota:kernel ;; 2) fw_s=ota:kernel2 ;; *) return 1 ;; esac
	fw_dev=$(part_dev ota) || return 1
	printf '%s' "$fw_s" | dd of="$fw_dev" bs=512 count=1 conv=sync,fsync,notrunc 2>/dev/null || return 1
	drop_caches
	[ "$(flag_read)" = "$fw_s" ]
}

# --- images and checksums ------------------------------------------------------

# magic_hex FILE -> first 4 bytes as lowercase hex
magic_hex() { head -c 4 "$1" 2>/dev/null | hexdump -ve '1/1 "%02x"'; }
magic_str() { head -c 4 "$1" 2>/dev/null; }

file_bytes() { wc -c < "$1" | tr -d ' '; }

# squashfs_bytes DEV -> bytes_used from the superblock (le64 at offset 40).
# Stock busybox od has no -j/-A, so read the low 32 bits with hexdump (the SoC
# is little-endian and squashfs images here are far below 4 GiB).
squashfs_bytes() {
	sb_n=$(hexdump -s 40 -n 4 -e '1/4 "%u"' "$1" 2>/dev/null)
	case "$sb_n" in '' | *[!0-9]*) return 1 ;; esac
	echo "$sb_n"
}

# sum_init: pick sha256sum + SHA256SUMS, or md5sum + MD5SUMS when stock lacks it
sum_init() {
	if [ "${C5_SUM:-}" = md5sum ] || ! command -v sha256sum > /dev/null 2>&1; then
		SUM=md5sum SUMS=MD5SUMS
	else
		SUM=sha256sum SUMS=SHA256SUMS
	fi
	command -v "$SUM" > /dev/null 2>&1
}

file_sum() { "$SUM" < "$1" | cut -d' ' -f1; }

# dev_sum DEV LEN: checksum of the first LEN bytes of DEV
dev_sum() { head -c "$2" "$1" | "$SUM" | cut -d' ' -f1; }

# sums_get SUMSFILE PATH -> recorded checksum of PATH
sums_get() {
	awk -v p="$2" '{ f = $2; sub(/^\*/, "", f); sub(/^\.\//, "", f); if (f == p) { print $1; exit } }' "$1"
}

# sums_verify DIR SUMSFILE: every entry of SUMSFILE (paths relative to DIR)
# must exist and match. Prints the first failing path.
sums_verify() {
	sv_bad=$(awk '{ f = $2; sub(/^\*/, "", f); sub(/^\.\//, "", f); print $1, f }' "$1/$2" | while read -r sv_sum sv_path; do
		if [ ! -f "$1/$sv_path" ] || [ "$(file_sum "$1/$sv_path")" != "$sv_sum" ]; then
			echo "$sv_path"
			break
		fi
	done)
	[ -z "$sv_bad" ] || { echo "$sv_bad"; return 1; }
	[ -s "$1/$2" ]
}

# free_bytes DIR -> available bytes on the filesystem holding DIR
free_bytes() {
	fb_k=$(df -k "$1" 2>/dev/null | awk 'NR > 1 && NF >= 4 && $(NF-2) ~ /^[0-9]+$/ { a = $(NF-2) } END { print a }')
	case "$fb_k" in '' | *[!0-9]*) return 1 ;; esac
	echo $((fb_k * 1024))
}

# shq STRING -> STRING single-quoted for sh
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
