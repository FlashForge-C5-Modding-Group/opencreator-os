# shellcheck shell=sh
# shellcheck disable=SC3043  # busybox ash supports 'local'
#
# Slot and boot-flag helpers for the Creator 5 Pro A/B eMMC layout.
#
# Sourced by preinit hooks, init scripts, /lib/upgrade/platform.sh, the
# c5-* tools and, from the install and restore sticks, by the installer on
# stock (busybox 1.31) and OpenWrt. Sourcing has no side effects and prints
# nothing.
#
# Layout (GPT names on the eMMC): kernel/rootfs = slot 1, kernel2/rootfs2 =
# slot 2, ota = boot flag ("ota:kernel" -> slot 1, "ota:kernel2" -> slot 2,
# the SPL compares the first 11 bytes), c5os = OpenWrt's /data.
#
# Overridable for testing: C5_DISK, C5_PARTX, C5_CMDLINE_FILE, C5_SYSBLOCK,
# C5_KMSG, C5_MOUNTS, C5_DROP_CACHES, C5_DATA, C5_OCDIR, C5_UDATA,
# C5_TEST_DEADLINE (also from the kernel command line: the kernel passes
# C5_TEST_DEADLINE=N to init's environment).

C5_DISK=${C5_DISK:-/dev/mmcblk0}
C5_PARTX=${C5_PARTX:-partx}
C5_CMDLINE_FILE=${C5_CMDLINE_FILE:-/proc/cmdline}
C5_SYSBLOCK=${C5_SYSBLOCK:-/sys/class/block}
C5_KMSG=${C5_KMSG:-/dev/kmsg}
C5_MOUNTS=${C5_MOUNTS:-/proc/mounts}
C5_DROP_CACHES=${C5_DROP_CACHES:-/proc/sys/vm/drop_caches}
C5_DATA=${C5_DATA:-/data}                       # c5os mount point (fstab)
C5_OCDIR=${C5_OCDIR:-$C5_DATA/opencreator-os}   # logs, pending-commit, sysupgrade.tgz
# Transient mount for the stock restore source and staged chainload kernel.
C5_UDATA=${C5_UDATA:-/tmp/c5-userdata}
C5_BOOTLOG_SECTOR=128      # bootlog lives at 64 KiB inside the ota partition ...
C5_BOOTLOG_SECTORS=128     # ... and is 64 KiB long
C5_BOOTLOG_MAGIC=C5BOOTLOG1
# Stock-invalid sector: the installer's restore.sh sets it before writing
# stock and clears it after read-back. Never select stock while it is set.
C5_STOCKINV_SECTOR=256
C5_STOCKINV_MAGIC=C5STOCKINVALID1
C5_TRIES_SECTOR=384
C5_TRIES_MAGIC=C5TRIES1
# shellcheck disable=SC2034  # read by the preinit hook
C5_TRIES_MAX=3
# Test boot (chainloaded from stock, flag on stock): seconds after preinit
# until it must be healthy (c5-booted), else it fails back to stock.
case "${C5_TEST_DEADLINE:-}" in '' | *[!0-9]*) C5_TEST_DEADLINE=180 ;; esac
# c5-booted and the deadline both mkdir this; the first one decides.
C5_TEST_DECIDED=/tmp/c5-test.decided

# $1 = GPT partition name -> /dev/mmcblk0pN (return 1 if unknown)
c5_part_dev() {
	local nr='' u
	if command -v "$C5_PARTX" >/dev/null 2>&1; then
		nr=$("$C5_PARTX" -s -g -o NR,NAME "$C5_DISK" 2>/dev/null |
			awk -v n="$1" '$2 == n { print $1; exit }')
	fi
	if [ -z "$nr" ]; then
		# Fallback without partx: the kernel exports GPT names as PARTNAME.
		for u in "$C5_SYSBLOCK/${C5_DISK##*/}p"*/uevent; do
			[ -f "$u" ] || continue
			grep -qx "PARTNAME=$1" "$u" || continue
			nr=$(sed -n 's/^PARTN=//p' "$u")
			break
		done
	fi
	[ -n "$nr" ] || return 1
	echo "${C5_DISK}p$nr"
}

# $1 = GPT partition name -> size in bytes
c5_part_bytes() {
	local dev sz
	dev=$(c5_part_dev "$1") || return 1
	sz=$(cat "$C5_SYSBLOCK/${dev##*/}/size" 2>/dev/null) || return 1
	[ -n "$sz" ] || return 1
	echo $((sz * 512))
}

c5_slot_kname() { if [ "$1" = 2 ]; then echo kernel2; else echo kernel; fi; }
c5_slot_rname() { if [ "$1" = 2 ]; then echo rootfs2; else echo rootfs; fi; }

# Value of the last root= on the kernel command line (the one the kernel uses).
c5_root_dev() {
	tr -s ' \t' '\n' < "$C5_CMDLINE_FILE" 2>/dev/null | sed -n 's/^root=//p' | tail -n 1
}

# 1 | 2 ; return 1 when the root is not an eMMC slot (USB root, chainload
# test from a stick, root=PARTLABEL=..., unknown partition table, ...)
c5_own_slot() {
	local r d
	r=$(c5_root_dev)
	[ -n "$r" ] || return 1
	d=$(c5_part_dev rootfs) && [ "$r" = "$d" ] && { echo 1; return 0; }
	d=$(c5_part_dev rootfs2) && [ "$r" = "$d" ] && { echo 2; return 0; }
	return 1
}

c5_other_slot() {
	case "$(c5_own_slot)" in
		1) echo 2 ;;
		2) echo 1 ;;
		*) return 1 ;;
	esac
}

# Raw flag string (first 11 bytes of ota, NUL/newline stripped).
c5_flag_read() {
	local dev
	dev=$(c5_part_dev ota) || return 1
	head -c 11 "$dev" | tr -d '\000\n'
}

# Slot the SPL will boot next: 2 iff the first 11 bytes are "ota:kernel2".
c5_flag_slot() {
	if [ "$(c5_flag_read)" = "ota:kernel2" ]; then echo 2; else echo 1; fi
}

c5_drop_caches() {
	sync
	{ echo 3 > "$C5_DROP_CACHES"; } 2>/dev/null
	return 0
}

# $1 = 1|2 ; whole-sector write, NUL padded, read back.
c5_flag_write() {
	local s dev
	dev=$(c5_part_dev ota) || return 1
	case "$1" in
		1) s="ota:kernel" ;;
		2) s="ota:kernel2" ;;
		*) return 1 ;;
	esac
	printf '%s' "$s" | dd of="$dev" bs=512 count=1 conv=sync,notrunc,fsync 2>/dev/null || return 1
	c5_drop_caches
	[ "$(c5_flag_read)" = "$s" ]
}

c5_tries_read() {
	local dev
	dev=$(c5_part_dev ota) || return 1
	dd if="$dev" bs=512 skip="$C5_TRIES_SECTOR" count=1 2>/dev/null |
		tr -d '\000' |
		awk -v m="$C5_TRIES_MAGIC" '
			NR == 1 && $0 ~ "^" m " [0-9]+$" && $2 <= 2147483646 { n=$2; ok=1 }
			END { printf "%d\n", NR == 1 && ok ? n : 0 }'
}

c5_tries_write() {
	local dev
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 10 ] && [ "$1" -le 2147483646 ] || return 1
	dev=$(c5_part_dev ota) || return 1
	printf '%s %s' "$C5_TRIES_MAGIC" "$1" |
		dd of="$dev" bs=512 seek="$C5_TRIES_SECTOR" count=1 conv=sync,notrunc,fsync 2>/dev/null || return 1
	c5_drop_caches
	[ "$(c5_tries_read)" -eq "$1" ]
}

# ota device if it is large enough to hold the bootlog area, else return 1.
c5_bootlog_dev() {
	local dev bytes
	dev=$(c5_part_dev ota) || return 1
	bytes=$(c5_part_bytes ota) || return 1
	[ "$bytes" -ge $(((C5_BOOTLOG_SECTOR + C5_BOOTLOG_SECTORS) * 512)) ] || return 1
	echo "$dev"
}

c5_bootlog_reset() {
	local dev
	dev=$(c5_bootlog_dev) || return 0
	dd if=/dev/zero of="$dev" bs=512 seek="$C5_BOOTLOG_SECTOR" count="$C5_BOOTLOG_SECTORS" \
		conv=notrunc,fsync 2>/dev/null
	return 0
}

# The area starts with the line $C5_BOOTLOG_MAGIC; anything else (zeros after
# a reset, or whatever stock left there) reads as an empty log.
c5_bootlog_show() {
	local dev
	dev=$(c5_bootlog_dev) || return 0
	dd if="$dev" bs=512 skip="$C5_BOOTLOG_SECTOR" count="$C5_BOOTLOG_SECTORS" 2>/dev/null |
		tr -d '\000' | awk -v m="$C5_BOOTLOG_MAGIC" 'NR == 1 { if ($0 != m) exit; next } { print }'
}

# Append one line "<uptime> <message>" to the bootlog (and to the kernel log).
# When the area is full the oldest lines are dropped.
c5_bootlog() {
	local dev max tmp up
	{ echo "c5: $*" > "$C5_KMSG"; } 2>/dev/null
	dev=$(c5_bootlog_dev) || return 0
	max=$((C5_BOOTLOG_SECTORS * 512 - ${#C5_BOOTLOG_MAGIC} - 1))
	tmp=/tmp/.c5-bootlog.$$
	up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
	{
		c5_bootlog_show
		printf '%s %s\n' "${up:-?}" "$*"
	} > "$tmp.new" || { rm -f "$tmp.new"; return 0; }
	if [ "$(wc -c < "$tmp.new")" -gt "$max" ]; then
		# keep the newest bytes, then drop the (possibly cut) first line
		tail -c "$max" "$tmp.new" | sed 1d > "$tmp.cut"
		mv -f "$tmp.cut" "$tmp.new"
	fi
	# Build the whole 64 KiB area in a file so dd never sees short pipe reads.
	dd if=/dev/zero of="$tmp" bs=512 count="$C5_BOOTLOG_SECTORS" 2>/dev/null &&
		{ echo "$C5_BOOTLOG_MAGIC"; cat "$tmp.new"; } | dd of="$tmp" conv=notrunc 2>/dev/null &&
		dd if="$tmp" of="$dev" bs=512 seek="$C5_BOOTLOG_SECTOR" count="$C5_BOOTLOG_SECTORS" \
			conv=notrunc,fsync 2>/dev/null
	rm -f "$tmp" "$tmp.new"
	return 0
}

# First 4 bytes of a file or device as lowercase hex.
c5_magic_hex() { head -c 4 "$1" 2>/dev/null | hexdump -ve '1/1 "%02x"'; }

# Hash only the uImage header and payload, not partition padding.
c5_kernel_sum() {
	local size
	[ "$(c5_magic_hex "$1")" = 27051956 ] || return 1
	size=$(hexdump -s 12 -n 4 -e '4/1 "%02x"' "$1") || return 1
	[ "${#size}" = 8 ] || return 1
	size=$((0x$size + 64))
	head -c "$size" "$1" | sha256sum | cut -d' ' -f1
}

# $1 = device: is it mounted anywhere?
c5_mounted() { awk -v d="$1" '$1 == d { f = 1 } END { exit !f }' "$C5_MOUNTS"; }

# $1 = directory: is something mounted on it?
c5_is_mountpoint() { awk -v m="$1" '$2 == m { f = 1 } END { exit !f }' "$C5_MOUNTS"; }

# NAME MNT OPTS CMD...: mount the ext4 partition NAME at MNT with OPTS, run
# CMD, sync, unmount. Returns CMD's status, or 1 (with a bootlog line) when
# the partition is missing or cannot be mounted. An already mounted
# partition is bind-mounted instead if a second mount fails with EBUSY.
c5_with_part() {
	local name="$1" mnt="$2" opts="$3" dev mp rc
	shift 3
	dev=$(c5_part_dev "$name") || { c5_bootlog "no $name partition"; return 1; }
	mkdir -p "$mnt"
	if ! mount -t ext4 -o "$opts" "$dev" "$mnt" 2>/dev/null; then
		mp=$(awk -v d="$dev" '$1 == d { print $2; exit }' "$C5_MOUNTS")
		if [ -z "$mp" ] || ! mount -o bind "$mp" "$mnt" 2>/dev/null; then
			c5_bootlog "cannot mount $dev ($name) on $mnt"
			return 1
		fi
	fi
	"$@"
	rc=$?
	sync
	umount "$mnt"
	return $rc
}

# $1 = 1|2: kernel partition starts with a uImage header and rootfs with a
# squashfs superblock (what the SPL and the kernel need to get going).
c5_slot_bootable() {
	local k r
	k=$(c5_part_dev "$(c5_slot_kname "$1")") || return 1
	r=$(c5_part_dev "$(c5_slot_rname "$1")") || return 1
	[ "$(c5_magic_hex "$k")" = 27051956 ] && [ "$(head -c 4 "$r" 2>/dev/null)" = hsqs ]
}

# ota device if it is large enough to hold the stock-invalid sector.
c5_stockinv_dev() {
	local dev bytes
	dev=$(c5_part_dev ota) || return 1
	bytes=$(c5_part_bytes ota) || return 1
	[ "$bytes" -ge $(((C5_STOCKINV_SECTOR + 1) * 512)) ] || return 1
	echo "$dev"
}

# Stock marked invalid? Prints the recorded reason and returns 0 if so.
c5_stock_invalid() {
	local dev s
	dev=$(c5_stockinv_dev) || return 1
	s=$(dd if="$dev" bs=512 skip="$C5_STOCKINV_SECTOR" count=1 2>/dev/null | tr -d '\000')
	case "$s" in
		"$C5_STOCKINV_MAGIC "*) echo "${s#"$C5_STOCKINV_MAGIC "}"; return 0 ;;
	esac
	return 1
}

# $* = reason; written with fsync and read back.
c5_stock_invalid_set() {
	local dev
	dev=$(c5_stockinv_dev) || return 1
	printf '%s %s' "$C5_STOCKINV_MAGIC" "$*" | head -c 500 |
		dd of="$dev" bs=512 seek="$C5_STOCKINV_SECTOR" count=1 conv=sync,notrunc,fsync 2>/dev/null || return 1
	c5_drop_caches
	c5_stock_invalid > /dev/null
}

c5_stock_invalid_clear() {
	local dev
	dev=$(c5_stockinv_dev) || return 1
	dd if=/dev/zero of="$dev" bs=512 seek="$C5_STOCKINV_SECTOR" count=1 conv=notrunc,fsync 2>/dev/null || return 1
	c5_drop_caches
	! c5_stock_invalid > /dev/null
}

# Chainload test with a kernel that is not the root slot's own kernel
# (c5-chainload.sh adds c5.nocommit=1): never point the flag at this slot.
c5_nocommit() {
	tr -s ' \t' '\n' < "$C5_CMDLINE_FILE" 2>/dev/null | grep -qx 'c5\.nocommit=1'
}

# Is there a reason the flag must not point at stock (the other slot)?
# Prints it and returns 0 if so; returns 1 when stock may be selected.
c5_stock_blocker() {
	local s why
	s=$(c5_other_slot) || { echo "root $(c5_root_dev) is not an eMMC slot"; return 0; }
	if why=$(c5_stock_invalid); then
		echo "stock marked invalid (may be half written: $why)"
		return 0
	fi
	c5_slot_bootable "$s" || { echo "stock slot $s has no uImage kernel / squashfs root"; return 0; }
	return 1
}

# Test boot: the root is an eMMC slot the flag does not name, so stock
# chainloaded it (the SPL boots only the flagged slot).
c5_test_boot() {
	local own
	own=$(c5_own_slot) && [ "$(c5_flag_slot)" != "$own" ]
}

# Version of the running image (the build's git describe).
c5_version() (
	# shellcheck disable=SC1091  # on the target
	. /etc/openwrt_release 2>/dev/null
	echo "${DISTRIB_RELEASE:-unknown}"
)

# c5os opencreator-os/last-test: "started VERSION" (the stock installer,
# before it boots OpenWrt), then "ok VERSION" or "failed VERSION REASON"
# (OpenWrt). The installer renames it to last-test.seen once it told the user.
# Runs with c5os mounted at /tmp/c5-test (c5_with_part): $1 = the line;
# "failed ..." also removes pending-commit, so nothing commits that build.
c5_test_record() {
	local d=/tmp/c5-test/opencreator-os
	mkdir -p "$d" || return 1
	case "$1" in
	failed*) rm -f "$d/pending-commit"; [ ! -e "$d/pending-commit" ] || return 1 ;;
	esac
	printf '%s\n' "$1" > "$d/last-test.new" && mv -f "$d/last-test.new" "$d/last-test"
}

# A test boot failed ($* = reason): flag -> stock (written and read back),
# last-test "failed ..." and no pending-commit on c5os, reboot -f. Writes
# nothing else: no stock partition, no stock-invalid mark.
c5_test_fail() {
	local other
	other=$(c5_other_slot)
	if c5_flag_write "$other"; then
		c5_bootlog "test: FAILED: $*; flag -> slot $other (stock)"
	else
		c5_bootlog "test: FAILED: $*; FLAG WRITE FAILED (flag now '$(c5_flag_read)')"
	fi
	c5_with_part c5os /tmp/c5-test rw,noatime c5_test_record "failed $(c5_version) $*" ||
		c5_bootlog "test: recording last-test / removing pending-commit on c5os FAILED"
	c5_bootlog "test: rebooting into stock"
	sync
	reboot -f
}

# Started in the background by preinit on a test boot: fails it unless
# c5-booted found it healthy first.
c5_test_deadline() {
	sleep "$C5_TEST_DEADLINE"
	mkdir "$C5_TEST_DECIDED" 2>/dev/null || return 0
	c5_test_fail "not healthy within $C5_TEST_DEADLINE s"
}
