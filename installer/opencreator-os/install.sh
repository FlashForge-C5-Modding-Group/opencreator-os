#!/bin/sh
# opencreator-os installer. Runs on the stock Creator 5 Pro firmware (busybox
# sh, root) and writes OpenWrt into the eMMC slot stock is NOT running from.
# The boot flag is left on stock unless --flip (or a FLIP marker) is given.
# Install also creates the c5os partition (userdata shrunk) once, optionally
# after a verified whole-eMMC backup to the stick.
#
#   sh install.sh [--from-stick DIR] [--check] [--flip | --chainload] [--yes]
#                 [--hook] [--ui] [--action install|swap] [--backup]
#
#   --from-stick DIR  payload directory (default: the directory above this
#                     script, i.e. the stick root)
#   --check           run every precondition, print the plan, write nothing
#   --flip            after a verified write, point the boot flag at OpenWrt
#                     and reboot (same as a file opencreator-os/FLIP on the stick)
#   --chainload       after a verified write (or when the slot is already up
#                     to date), test-boot OpenWrt from RAM with c5-chainload.sh;
#                     the boot flag stays on stock (same as opencreator-os/CHAINLOAD)
#   --yes             do not ask for confirmation (incl. creating c5os)
#   --hook            started by the stock USB hook (runFirmwareExe.sh): no
#                     final write confirmation, exits 1 after a non-flip
#                     install so stock keeps booting
#   --ui              screen requests on stdout, answers on stdin (the
#                     os-installer app; protocol in lib.sh)
#   --action ACTION   without --ui: install (default) or swap (boot flag to
#                     the other system and reboot)
#   --backup          without --ui: back up the eMMC to DIR/emmc-backup first
# Other non-option arguments (stock passes MACHINE and PID) are ignored.
#
# Payload in DIR: kernel.uimage root.squashfs sysupgrade.tar VERSION
# chainload/chainload.ko chainload/c5-chainload.sh SHA256SUMS MD5SUMS,
# opencreator-os/bin/sfdisk, optional opencreator-os/authorized_keys,
# opencreator-os/FLIP and opencreator-os/CHAINLOAD.
set -u

usage() { sed -n '2,33s/^# \{0,1\}//p' "$0"; }

SELF_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
STICK='' CHECK=0 FLIP=0 CHAIN=0 YES=0 HOOK=0 UI=0 ACTION=install BACKUP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--from-stick)
		[ $# -ge 2 ] || { echo "install: --from-stick needs a directory" >&2; exit 2; }
		STICK=$2
		shift
		;;
	--action)
		case "${2:-}" in install | swap) ACTION=$2 ;; *) echo "install: --action needs install or swap" >&2; exit 2 ;; esac
		shift
		;;
	--check) CHECK=1 ;;
	--flip) FLIP=1 ;;
	--chainload) CHAIN=1 ;;
	--yes) YES=1 ;;
	--hook) HOOK=1 ;;
	--ui) UI=1 ;;
	--backup) BACKUP=1 ;;
	-h | --help) usage; exit 0 ;;
	-*) echo "install: unknown option $1" >&2; usage >&2; exit 2 ;;
	*) ;;
	esac
	shift
done
[ -n "$STICK" ] || STICK=$(dirname "$SELF_DIR")
STICK=$(cd "$STICK" 2>/dev/null && pwd) || { echo "install: payload directory not found" >&2; exit 1; }
C5_SFDISK=${C5_SFDISK:-$SELF_DIR/bin/sfdisk}
C5_PARTX=${C5_PARTX:-$SELF_DIR/bin/partx}

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SELF_DIR/lib.sh"

[ -f "$STICK/opencreator-os/FLIP" ] && FLIP=1
[ -f "$STICK/opencreator-os/CHAINLOAD" ] && CHAIN=1
SD=$OCDIR/stock
MIN_FREE=$((64 * 1024 * 1024))
VERSION=$(head -n 1 "$STICK/VERSION" 2>/dev/null | tr -d '\r')
[ -n "$VERSION" ] || VERSION=unknown
# c5os: userdata's filesystem is shrunk to its new partition size minus
# UD_FS_MARGIN_MIB, and must keep UD_HEADROOM_MIB free beyond the install's
# own needs; the backup splits images into BK_CHUNK_MIB files (FAT32).
UD_FS_MARGIN_MIB=32
UD_HEADROOM_MIB=128
BK_CHUNK_MIB=1024
BK_DIR=emmc-backup
DATA_DOWN=0

finish() {  # finish ID TEXT EXITCODE
	ui_info "$1" "$2"
	sync
	[ "$HOOK" = 1 ] && [ "$UI" = 0 ] && sleep "${C5_SCREEN_PAUSE:-10}"
	exit "$3"
}

# abort before anything was written: in check mode just report
abort() {
	log "abort: $*"
	[ "$CHECK" = 1 ] && exit 1
	log "install: FAILED (nothing written)"
	finish failed "Nothing was written\n$*" 1
}

fail() {
	log "install: FAILED $*"
	if [ "$DATA_DOWN" = 1 ]; then
		if remount_data; then log "c5os: $UD_DEV mounted again on $C5_DATA"; else log "c5os: cannot mount $UD_DEV on $C5_DATA again"; fi
	fi
	log "install: boot flag untouched; stock stays the boot slot"
	finish failed "Installation FAILED\n$*\nBoot flag untouched; stock keeps booting." 1
}

# remount_data: userdata back on C5_DATA with stock's own options
remount_data() {
	mountpoint -q "$C5_DATA" || mount -o sync -t ext4 "$UD_DEV" "$C5_DATA" || return 1
	DATA_DOWN=0 NO_DATA_LOG=0
}

# --- preconditions --------------------------------------------------------------

preflight() {
	[ "$C5_UNAME_R" = "5.10.186+" ] || abort "running kernel is $C5_UNAME_R, not the stock 5.10.186+"
	sum_init || abort "neither sha256sum nor md5sum available"

	for n in kernel rootfs kernel2 rootfs2 ota; do
		part_dev "$n" > /dev/null || abort "GPT partition '$n' not found (or not unique) on $C5_DISK"
	done
	OWN=$(own_slot) || abort "root=$(cmdline_root) is neither GPT rootfs ($(part_dev rootfs)) nor rootfs2 ($(part_dev rootfs2))"
	FLAG=$(flag_slot) || abort "cannot read the boot flag"
	# a flag naming the other slot (e.g. switch-to-openwrt.sh --no-reboot) is
	# pointed back at the running slot before the first partition write
	TGT=$(other_slot "$OWN")
	OKDEV=$(part_dev "$(slot_kname "$OWN")")
	ORDEV=$(part_dev "$(slot_rname "$OWN")")
	TK=$(part_dev "$(slot_kname "$TGT")")
	TR=$(part_dev "$(slot_rname "$TGT")")
	for d in "$TK" "$TR"; do
		if [ "$d" = "$OKDEV" ] || [ "$d" = "$ORDEV" ] || [ "$d" = "$(cmdline_root)" ]; then
			abort "target $d is part of the running slot"
		fi
		is_mounted "$d" && abort "target $d is mounted"
	done
	TKB=$(part_bytes "$TK") || abort "cannot read the size of $TK"
	TRB=$(part_bytes "$TR") || abort "cannot read the size of $TR"

	for f in kernel.uimage root.squashfs chainload/chainload.ko chainload/c5-chainload.sh; do
		[ -s "$STICK/$f" ] || abort "payload file $f missing in $STICK"
	done
	[ "$(magic_hex "$STICK/kernel.uimage")" = "$UIMAGE_MAGIC" ] || abort "kernel.uimage is not a uImage (magic $(magic_hex "$STICK/kernel.uimage"))"
	[ "$(magic_str "$STICK/root.squashfs")" = "$SQUASHFS_MAGIC" ] || abort "root.squashfs is not a squashfs image"
	KSZ=$(file_bytes "$STICK/kernel.uimage")
	RSZ=$(file_bytes "$STICK/root.squashfs")
	[ "$KSZ" -gt 64 ] || abort "kernel.uimage ($KSZ bytes) is too small"
	[ "$KSZ" -le "$TKB" ] || abort "kernel.uimage ($KSZ bytes) does not fit $TK ($TKB bytes)"
	[ "$RSZ" -le "$TRB" ] || abort "root.squashfs ($RSZ bytes) does not fit $TR ($TRB bytes)"
	# chainload.ko (chainload/chainload_main.c) skips the 64-byte uImage header
	# and refuses a payload whose 4 KiB-page-rounded size exceeds
	# SAFE_MIN - LOAD_PHYS = 0x01600000 - 0x00f00000 = 7 MiB (its copy to
	# LOAD_PHYS must stay below the staging pages). Keep in sync with it.
	CL_LIMIT=7340032
	kpay=$(((KSZ - 64 + 4095) / 4096 * 4096))
	[ "$kpay" -le "$CL_LIMIT" ] || abort "kernel.uimage payload ($((KSZ - 64)) bytes, $kpay page-rounded) exceeds the chainload limit of $CL_LIMIT bytes"

	[ -s "$STICK/$SUMS" ] || abort "$SUMS missing in $STICK"
	KSUM=$(sums_get "$STICK/$SUMS" kernel.uimage)
	RSUM=$(sums_get "$STICK/$SUMS" root.squashfs)
	if [ -z "$KSUM" ] || [ -z "$RSUM" ]; then abort "$SUMS does not list kernel.uimage and root.squashfs"; fi
	bad=$(sums_verify "$STICK" "$SUMS") || abort "payload checksum mismatch ($SUMS): ${bad:-empty list}"
	UP_TO_DATE=0
	if [ "$(dev_sum "$TK" "$KSZ")" = "$KSUM" ] && [ "$(dev_sum "$TR" "$RSZ")" = "$RSUM" ]; then
		UP_TO_DATE=1
	fi
	# a previous install of this slot stopped after the image writes but
	# before the overlay header was cleared: redo the cleanup
	PENDING=0
	grep -qx "slot=$TGT" "$OCDIR/install-pending" 2>/dev/null && PENDING=1
	# identifies one chainload test request: the payload plus the CHAINLOAD
	# marker's contents (edit the marker to request another test)
	CL_KEY=$({ cat "$STICK/$SUMS"; cat "$STICK/opencreator-os/CHAINLOAD" 2>/dev/null; } | "$SUM" | cut -c1-16)

	# running stock slot, saved to userdata before anything is written
	[ "$(magic_str "$ORDEV")" = "$SQUASHFS_MAGIC" ] || abort "running rootfs $ORDEV is not squashfs"
	OKB=$(part_bytes "$OKDEV") || abort "cannot read the size of $OKDEV"
	ORB=$(part_bytes "$ORDEV") || abort "cannot read the size of $ORDEV"
	BU=$(squashfs_bytes "$ORDEV") || abort "cannot read bytes_used of $ORDEV"
	if [ "$BU" -le 0 ] || [ "$BU" -gt "$ORB" ]; then abort "implausible squashfs bytes_used $BU on $ORDEV"; fi
	OKSUM=$(dev_sum "$OKDEV" "$OKB")
	ORSUM=$(dev_sum "$ORDEV" "$BU")
	STOCK_SAVED=0
	if [ -f "$SD/$SUMS" ] && [ "$(sums_get "$SD/$SUMS" kernel.img)" = "$OKSUM" ] &&
		[ "$(sums_get "$SD/$SUMS" rootfs.squashfs)" = "$ORSUM" ] && sums_verify "$SD" "$SUMS" > /dev/null; then
		STOCK_SAVED=1
	fi

	if [ "${C5_NO_MOUNTPOINT:-0}" != 1 ]; then
		mountpoint -q "$C5_DATA" || abort "$C5_DATA is not mounted"
	fi
	need=$((KSZ + 6 * 1024 * 1024))
	[ "$STOCK_SAVED" = 1 ] || need=$((need + OKB + BU))
	[ "$need" -ge "$MIN_FREE" ] || need=$MIN_FREE

	geometry
	if [ "$HAVE_C5OS" = 0 ]; then
		# userdata must still fit after the shrink, with headroom; checked
		# before the menu so a full printer never starts a backup
		UD_USED_MIB=$(($(used_bytes "$C5_DATA" || echo 0) / 1048576))
		need_mib=$(((need + 1048575) / 1048576))
		limit=$((UD_SHRINK_MIB - UD_HEADROOM_MIB - need_mib))
		log "check: userdata holds $UD_USED_MIB MiB; at most $limit MiB fit next to c5os"
		if [ "$UD_USED_MIB" -gt "$limit" ]; then
			ui_block c5os-space "$(space_text $((UD_USED_MIB - limit)))"
		fi
	fi
	check_data_space

	INSTALLED=0
	if grep -q "^written slot=$TGT " "$OCDIR/install.state" 2>/dev/null &&
		[ "$(magic_hex "$TK")" = "$UIMAGE_MAGIC" ] && [ "$(magic_str "$TR")" = "$SQUASHFS_MAGIC" ]; then
		INSTALLED=1
	fi
	backup_plan
}

check_data_space() {
	free=$(free_bytes "$C5_DATA") || abort "cannot read free space on $C5_DATA"
	[ "$free" -ge "$need" ] || abort "$C5_DATA has $((free / 1048576)) MiB free, need $((need / 1048576)) MiB"
}

space_text() {  # space_text MB -> c5os-space screen text
	printf '%s' "Please free $1 MB on /usr/data\nThe installer shrinks userdata to ${UD_NEW_MIB} MiB for the new c5os partition.\nRemove the stick, power-cycle, delete files from /usr/data (stock UI or SSH), then try again."
}

# geometry: partition table and c5os layout, in 512-byte sectors.
# HAVE_C5OS=1: p7 userdata / p8 c5os as on the disk. HAVE_C5OS=0: c5os is
# planned to end at the primary GPT's last usable LBA, 1 MiB aligned, and
# userdata to end right before it.
geometry() {
	DISK_SECTORS=$(cat "$C5_SYSBLOCK/${C5_DISK##*/}/size" 2>/dev/null)
	case "$DISK_SECTORS" in '' | *[!0-9]*) abort "cannot read the size of $C5_DISK" ;; esac
	PT=$(part_table)
	pt_names=$(printf '%s\n' "$PT" | awk '{ printf "%s%s", s, $1; s = " " }')
	case "$pt_names" in
	"kernel rootfs kernel2 rootfs2 ota usershare userdata") HAVE_C5OS=0 ;;
	"kernel rootfs kernel2 rootfs2 ota usershare userdata c5os") HAVE_C5OS=1 ;;
	*) abort "unexpected partition table: ${pt_names:-<none>}" ;;
	esac
	command -v "$C5_SFDISK" > /dev/null 2>&1 || abort "sfdisk not found ($C5_SFDISK)"
	GPT_LAST=$("$C5_SFDISK" --dump "$C5_DISK" 2>/dev/null | sed -n 's/^last-lba: *//p')
	case "$GPT_LAST" in '' | *[!0-9]*) abort "cannot read the GPT of $C5_DISK with $C5_SFDISK" ;; esac
	# shellcheck disable=SC2046
	set -- $(printf '%s\n' "$PT" | awk '$1 == "userdata" { print $2, $3, $4 }')
	UD_NR=$1 UD_START=$2 UD_SIZE=$3
	UD_DEV=${C5_DISK}p$UD_NR
	UD_MIB=$((UD_SIZE / 2048))
	if [ "$HAVE_C5OS" = 1 ]; then
		# shellcheck disable=SC2046
		set -- $(printf '%s\n' "$PT" | awk '$1 == "c5os" { print $2, $3, $4 }')
		C5OS_DEV=${C5_DISK}p$1 C5OS_START=$2 C5OS_SIZE=$3
		C5OS_END=$((C5OS_START + C5OS_SIZE - 1))
		UD_NEW_SIZE=$UD_SIZE
	else
		C5OS_DEV=${C5_DISK}p8
		C5OS_END=$GPT_LAST
		C5OS_START=$(((C5OS_END + 1 - C5_C5OS_MIB * 2048) / 2048 * 2048))
		C5OS_SIZE=$((C5OS_END - C5OS_START + 1))
		UD_NEW_SIZE=$((C5OS_START - UD_START))
	fi
	UD_NEW_MIB=$((UD_NEW_SIZE / 2048))
	UD_SHRINK_MIB=$((UD_NEW_MIB - UD_FS_MARGIN_MIB))
	[ "$HAVE_C5OS" = 1 ] && return 0

	[ "$UD_NR" = 7 ] || abort "userdata is partition $UD_NR, not 7"
	[ "$(printf '%s\n' "$PT" | awk '{ if ($3 > m) { m = $3; n = $1 } } END { print n }')" = userdata ] ||
		abort "userdata is not the last partition on $C5_DISK"
	[ "$UD_NEW_SIZE" -ge $((256 * 2048)) ] || abort "disk too small for a ${C5_C5OS_MIB} MiB c5os"
	[ "$(dd if="$C5_DISK" bs=512 skip=$((DISK_SECTORS - 33)) count=33 2>/dev/null | tr -d '\000' | wc -c)" -eq 0 ] ||
		abort "unexpected data in the last 33 sectors of $C5_DISK (backup GPT area)"
}

# --- install steps --------------------------------------------------------------

save_stock() {
	if [ "$STOCK_SAVED" = 1 ]; then
		log "stock: slot $OWN already saved in $SD (checksums match), skipping"
		return 0
	fi
	log "stock: saving slot $OWN ($OKDEV whole, first $BU bytes of $ORDEV) to $SD"
	rm -rf "$SD.new"
	mkdir -p "$SD.new" || fail "cannot create $SD.new"
	dd if="$OKDEV" of="$SD.new/kernel.img" bs=1M 2>/dev/null || fail "reading $OKDEV"
	head -c "$BU" "$ORDEV" > "$SD.new/rootfs.squashfs" || fail "reading $ORDEV"
	sync
	[ "$(file_sum "$SD.new/kernel.img")" = "$OKSUM" ] || fail "saved kernel.img does not match $OKDEV"
	[ "$(file_sum "$SD.new/rootfs.squashfs")" = "$ORSUM" ] || fail "saved rootfs.squashfs does not match $ORDEV"
	printf '%s  kernel.img\n%s  rootfs.squashfs\n' "$OKSUM" "$ORSUM" > "$SD.new/$SUMS"
	{
		echo "saved: $(date '+%F %T')"
		echo "slot: $OWN"
		echo "kernel: $OKDEV ($OKB bytes, whole partition)"
		echo "rootfs: $ORDEV (squashfs bytes_used $BU of $ORB)"
		echo "kernel release: $C5_UNAME_R"
		echo "cmdline: $(cat "$C5_CMDLINE")"
		if [ -f "${C5_OTA_INFO:-/etc/ota_info}" ]; then
			echo "ota_info:"
			sed 's/^/  /' "${C5_OTA_INFO:-/etc/ota_info}"
		fi
	} > "$SD.new/MANIFEST.txt"
	rm -rf "$SD"
	mv "$SD.new" "$SD" || fail "cannot move $SD.new to $SD"
	sync
	log "stock: saved and verified ($SUM)"
}

save_wifi() {
	wpa=${C5_WPA:-/usr/prog/wifi/wpa_supplicant.conf}
	if [ ! -f "$wpa" ]; then
		log "wifi: $wpa not found; wifi.conf not written"
	elif ssid=$(wifi_conf "$wpa" "$OCDIR/wifi.conf"); then
		if grep -qx "PSK=''" "$OCDIR/wifi.conf"; then
			log "wifi: saved SSID '$ssid' (no psk= in $wpa; open network?) to $OCDIR/wifi.conf"
		else
			log "wifi: saved SSID '$ssid' with its key to $OCDIR/wifi.conf"
		fi
	elif [ $? = 2 ]; then
		fail "cannot write $OCDIR/wifi.conf"
	else
		log "wifi: no network block with ssid= in $wpa; wifi.conf not written"
	fi
	if [ -s "$STICK/opencreator-os/authorized_keys" ]; then
		(umask 077; cp "$STICK/opencreator-os/authorized_keys" "$OCDIR/authorized_keys" && chmod 600 "$OCDIR/authorized_keys") ||
			fail "cannot copy authorized_keys"
		log "ssh: copied authorized_keys to $OCDIR/authorized_keys"
	fi
}

copy_chainload() {
	mkdir -p "$OCDIR/chainload" || fail "cannot create $OCDIR/chainload"
	for f in chainload/chainload.ko chainload/c5-chainload.sh kernel.uimage; do
		cp "$STICK/$f" "$OCDIR/chainload/" || fail "cannot copy $f to $OCDIR/chainload"
		want=$(sums_get "$STICK/$SUMS" "$f")
		[ -z "$want" ] || [ "$(file_sum "$OCDIR/chainload/${f##*/}")" = "$want" ] || fail "copy of $f is corrupt"
	done
	sync
	log "chainload: chainload.ko, c5-chainload.sh, kernel.uimage copied to $OCDIR/chainload"
}

write_slot() {
	if [ "$UP_TO_DATE" = 1 ] && [ "$PENDING" = 0 ]; then
		log "write: slot $TGT already up to date ($TK, $TR match the payload); not rewriting"
		return 0
	fi
	if [ "$UP_TO_DATE" = 1 ]; then
		log "write: slot $TGT matches the payload but the previous install did not finish (install-pending); redoing the overlay cleanup"
	else
		# transaction marker: removed only after the overlay header is cleared
		printf 'slot=%s\nrootfs=%s\nversion=%s\n' "$TGT" "$TR" "$VERSION" > "$OCDIR/install-pending" ||
			fail "cannot write $OCDIR/install-pending"
		sync
		write_images
	fi
	clear_overlay
	rm -f "$OCDIR/install-pending" || fail "cannot remove $OCDIR/install-pending"
	sync
}

write_images() {
	ui_info write "Writing OpenWrt to slot $TGT\nDo not power off."
	ui_progress 0 2
	log "write: kernel.uimage ($KSZ bytes) -> $TK"
	dd if="$STICK/kernel.uimage" of="$TK" bs=1M conv=fsync,notrunc 2>/dev/null || fail "dd to $TK failed"
	ui_progress 1 2
	log "write: root.squashfs ($RSZ bytes) -> $TR"
	dd if="$STICK/root.squashfs" of="$TR" bs=1M conv=fsync,notrunc 2>/dev/null || fail "dd to $TR failed"
	ui_progress 2 2
	drop_caches
	[ "$(dev_sum "$TK" "$KSZ")" = "$KSUM" ] || fail "read-back mismatch on $TK"
	[ "$(dev_sum "$TR" "$RSZ")" = "$RSUM" ] || fail "read-back mismatch on $TR"
	log "write: slot $TGT written and read back OK ($SUM)"
}

# fstools puts the overlay (rootfs_data) right after the squashfs, at
# bytes_used rounded up to 64 KiB; wipe any stale ext4 superblock there so
# the first boot formats a fresh overlay.
clear_overlay() {
	bu=$(squashfs_bytes "$STICK/root.squashfs") || fail "cannot read bytes_used of root.squashfs"
	off=$(((bu + 65535) / 65536 * 65536))
	if [ $((off + 4096)) -le "$TRB" ]; then
		dd if=/dev/zero of="$TR" bs=512 seek=$((off / 512)) count=8 conv=fsync,notrunc 2>/dev/null ||
			fail "cannot clear the overlay area of $TR"
		log "write: cleared 4 KiB overlay header at offset $off of $TR"
	fi
}

# log_lines PREFIX TEXT: log every non-empty line of TEXT
log_lines() {
	printf '%s\n' "$2" | while IFS= read -r ll; do
		if [ -n "$ll" ]; then log "$1$ll"; fi
	done
}

# release_stick: flush and unmount the stick when it is a mount point (the
# stock hook mounts it at /mnt). This script runs from it, so a plain umount
# is usually busy; a lazy umount detaches it and the open script stays
# readable. Later log lines go to $OCDIR/install.log only.
release_stick() {
	mountpoint -q "$STICK" 2>/dev/null || return 0
	rs_dir=$STICK
	STICK=''
	sync
	if umount "$rs_dir" 2>/dev/null; then
		log "chainload: unmounted $rs_dir"
	elif umount -l "$rs_dir" 2>/dev/null; then
		log "chainload: $rs_dir busy (this script runs from it); lazily unmounted"
	else
		log "chainload: could not unmount $rs_dir"
	fi
}

# chainload_test: stage the target slot's kernel with root= on the target
# rootfs and jump into it from RAM. The eMMC and the boot flag are untouched.
chainload_test() {
	cl=$OCDIR/chainload/c5-chainload.sh
	ui_info chainload "Test-booting OpenWrt from RAM\nThe screen may go blank. If OpenWrt is not up within 3 minutes, power-cycle: stock boots."
	log "chainload: staging $OCDIR/chainload/kernel.uimage with root=$TR"
	if ! cl_out=$(sh "$cl" stage "$TR" 2>&1); then
		log_lines "chainload: " "$cl_out"
		log "chainload: stage FAILED; last kernel messages:"
		log_lines "dmesg: " "$(dmesg 2>/dev/null | tail -n 30)"
		log "install: FAILED chainload test; slot $TGT stays written, boot flag on stock (slot $OWN)"
		finish failed "Chainload test FAILED\nSlot $TGT stays written; the boot flag stays on stock." 1
	fi
	log_lines "chainload: " "$cl_out"
	echo "chainload slot=$TGT key=$CL_KEY version=$VERSION" >> "$OCDIR/install.state"
	log "chainload: staged; jumping into OpenWrt from RAM (boot flag stays on stock, slot $OWN)"
	log "chainload: no OpenWrt within 3 minutes -> power-cycle; stock boots and this test is not repeated"
	sync
	release_stick
	sync
	if [ "$HOOK" = 1 ]; then
		# "go" backgrounds go-now and returns, and go-now kills every process
		# whose command line mentions opencreator (this script): the hook would
		# return and stock would resume booting while the jump is prepared.
		# Run go-now in the foreground under a command line naming
		# c5-chainload, which go-now spares. It returns only if the jump was
		# refused; stock is half shut down then, so say so on the screen and
		# stall (exit 0 makes the stock hook sleep) until the user power-cycles.
		# shellcheck disable=SC2016
		exec sh -c 'sh "$1" go-now
			if [ "$2" = 1 ]; then
				printf "%s\n" "BLOCK chainload-failed The jump into OpenWrt was refused\nNothing was changed. Power-cycle the printer."
				cat > /dev/null
			fi
			exit 0' c5-chainload "$cl" "$UI"
	fi
	sh "$cl" go
	exit 0
}

# --- eMMC backup to the stick ---------------------------------------------------
# Same layout as tools/printer/phase0.sh --backup --all (tools/verify-backup.sh
# and tools/make-restore-stick.sh take it as is): NAME.img.000, .001, ... of
# BK_CHUNK_MIB MiB per partition, first-mib.bin, disk-tail.img.* (everything
# after the last partition), SHA256SUMS, partmap.txt, MANIFEST.txt; plus
# VERIFIED = checksum of SHA256SUMS once the stick copy was read back.

# backup_plan: BK_LIST lines "NAME DEV SKIP SECTORS" (DEV a partition with
# SKIP 0, or the disk), BK_TOTAL_MIB, BK_NEED_MIB
backup_plan() {
	BK=$STICK/$BK_DIR
	TAIL_START=$(printf '%s\n' "$PT" | awk '{ e = $3 + $4; if (e > m) m = e } END { printf "%d", m }')
	# first-mib first, as phase0.sh
	BK_LIST="first-mib $C5_DISK 0 2048
$(printf '%s\n' "$PT" | awk -v d="$C5_DISK" '{ print $1, d "p" $2, 0, $4 }')"
	if [ "$DISK_SECTORS" -gt "$TAIL_START" ]; then
		BK_LIST="$BK_LIST
disk-tail $C5_DISK $TAIL_START $((DISK_SECTORS - TAIL_START))"
	fi
	BK_TOTAL_MIB=$(printf '%s\n' "$BK_LIST" | awk '{ t += int(($4 + 2047) / 2048) } END { printf "%d", t }')
	BK_NEED_MIB=$((BK_TOTAL_MIB + 2))
}

# disk_range SKIP SECTORS: those sectors of C5_DISK on stdout
disk_range() {
	if [ $(($1 % 2048)) = 0 ] && [ $(($2 % 2048)) = 0 ]; then
		dd if="$C5_DISK" bs=1M skip=$(($1 / 2048)) count=$(($2 / 2048)) 2>/dev/null
	else
		dd if="$C5_DISK" bs=512 skip="$1" count="$2" 2>/dev/null
	fi
}

backup_emmc() {
	if [ -f "$BK/VERIFIED" ] && [ -f "$BK/$SUMS" ] && [ "$(cat "$BK/VERIFIED")" = "$(file_sum "$BK/$SUMS")" ]; then
		log "backup: verified backup already on the stick ($BK_DIR); not repeating it"
		return 0
	fi
	rm -rf "$BK"
	mkdir -p "$BK" || fail "backup: cannot create $BK"
	bk_free=$(($(free_bytes "$STICK" || echo 0) / 1048576))
	log "backup: needs $BK_NEED_MIB MiB, $bk_free MiB free on the stick"
	if [ "$bk_free" -lt "$BK_NEED_MIB" ]; then
		rmdir "$BK" 2>/dev/null
		ui_block backup-space "Not enough space on the USB stick\nThe backup needs ${BK_NEED_MIB} MB free, the stick has $bk_free MB.\nUse a larger stick, or power-cycle and choose Skip backup."
	fi
	# userdata must not change between its checksum and its copy
	NO_DATA_LOG=1
	ui_info backup-run "Backing up the eMMC to the stick\nDo not remove the stick or power off."
	: > "$BK/$SUMS"
	bk_done=0
	ui_progress 0 "$BK_TOTAL_MIB"
	while read -r bk_name bk_dev bk_skip bk_n; do
		bk_mib=$(((bk_n + 2047) / 2048))
		log "backup: $bk_name ($bk_dev, $bk_mib MiB)"
		if [ "$bk_name" = first-mib ]; then
			bk_sum=$(disk_range 0 2048 | "$SUM" | cut -d' ' -f1)
			dd if="$C5_DISK" of="$BK/first-mib.bin" bs=1M count=1 2>/dev/null || fail "backup: dd of first-mib failed"
			echo "$bk_sum  first-mib.bin" >> "$BK/$SUMS"
			bk_done=$((bk_done + bk_mib))
			ui_progress "$bk_done" "$BK_TOTAL_MIB"
			continue
		fi
		if [ "$bk_dev" = "$C5_DISK" ]; then
			bk_sum=$(disk_range "$bk_skip" "$bk_n" | "$SUM" | cut -d' ' -f1)
		else
			bk_sum=$("$SUM" < "$bk_dev" | cut -d' ' -f1)
		fi
		bk_i=0
		while [ $((bk_i * BK_CHUNK_MIB * 2048)) -lt "$bk_n" ]; do
			bk_c=$(printf '%03d' "$bk_i")
			bk_off=$((bk_i * BK_CHUNK_MIB * 2048))
			bk_len=$((bk_n - bk_off))
			[ "$bk_len" -le $((BK_CHUNK_MIB * 2048)) ] || bk_len=$((BK_CHUNK_MIB * 2048))
			if [ "$bk_dev" = "$C5_DISK" ]; then
				disk_range $((bk_skip + bk_off)) "$bk_len" > "$BK/$bk_name.img.$bk_c" || fail "backup: dd of $bk_name chunk $bk_c failed"
			else
				dd if="$bk_dev" of="$BK/$bk_name.img.$bk_c" bs=1M skip=$((bk_i * BK_CHUNK_MIB)) count="$BK_CHUNK_MIB" 2>/dev/null ||
					fail "backup: dd of $bk_name chunk $bk_c failed"
			fi
			bk_done=$((bk_done + (bk_len + 2047) / 2048))
			ui_progress "$bk_done" "$BK_TOTAL_MIB"
			bk_i=$((bk_i + 1))
		done
		echo "$bk_sum  $bk_name.img" >> "$BK/$SUMS"
	done <<EOF
$BK_LIST
EOF
	printf '%s\n' "$PT" > "$BK/partmap.txt"
	{
		echo "date: $(date '+%F %T')"
		echo "running root: $(cmdline_root)"
		echo "ota flag: $(flag_read)"
		cat "${C5_OTA_INFO:-/etc/ota_info}" 2>/dev/null
		printf '%s\n' "$PT"
		echo "installer: opencreator-os $VERSION"
		echo "disk sectors: $DISK_SECTORS"
		echo "tail: start=$TAIL_START sectors=$((DISK_SECTORS - TAIL_START))"
	} > "$BK/MANIFEST.txt"
	sync

	ui_info backup-verify "Verifying the backup on the stick"
	drop_caches
	bk_done=0
	ui_progress 0 "$BK_TOTAL_MIB"
	while read -r bk_name bk_dev bk_skip bk_n; do
		if [ "$bk_name" = first-mib ]; then
			bk_files=$BK/first-mib.bin bk_rec=first-mib.bin
		else
			bk_files=$(ls "$BK/$bk_name.img".[0-9][0-9][0-9] 2>/dev/null) bk_rec=$bk_name.img
		fi
		bk_bytes=0
		for bk_f in $bk_files; do bk_bytes=$((bk_bytes + $(file_bytes "$bk_f"))); done
		# shellcheck disable=SC2086
		bk_got=$(cat $bk_files 2>/dev/null | "$SUM" | cut -d' ' -f1)
		if [ "$bk_bytes" != $((bk_n * 512)) ] || [ "$bk_got" != "$(sums_get "$BK/$SUMS" "$bk_rec")" ]; then
			fail "backup: verification of $bk_name failed (stick unreliable)"
		fi
		bk_done=$((bk_done + (bk_n + 2047) / 2048))
		ui_progress "$bk_done" "$BK_TOTAL_MIB"
	done <<EOF
$BK_LIST
EOF
	file_sum "$BK/$SUMS" > "$BK/VERIFIED"
	sync
	NO_DATA_LOG=0
	log "backup: verified; $BK_TOTAL_MIB MiB in $BK_DIR"
}

# --- c5os partition ---------------------------------------------------------------

# c5os_kernel_ok: the kernel's partitions match the GPT's p7/p8
c5os_kernel_ok() {
	[ "$(part_bytes "$UD_DEV")" = $((UD_SIZE * 512)) ] &&
		[ "$(part_bytes "$C5OS_DEV")" = $((C5OS_SIZE * 512)) ] &&
		[ "$(cat "$C5_SYSBLOCK/${C5OS_DEV##*/}/start" 2>/dev/null)" = "$C5OS_START" ]
}

# c5os_reboot: the kernel still has the old partitions; reboot once and let
# the stick continue (userdata must be mounted: the marker lives there)
c5os_reboot() {
	[ -f "$OCDIR/c5os-rebooted" ] && fail "kernel does not see the new partition table after a reboot"
	mkdir -p "$OCDIR" && : > "$OCDIR/c5os-rebooted" || fail "cannot write $OCDIR/c5os-rebooted"
	log "c5os: the kernel still uses the old partition table; rebooting once"
	ui_info c5os-reboot "Partition table written\nRebooting once so the kernel sees it; the installer continues after the reboot. Leave the stick in."
	sync
	sleep 5
	$C5_REBOOT
	exit 0
}

# finish_c5os: grow userdata to p7, format c5os, userdata mounted again.
# Each step is skipped when already done, so a re-run completes it.
finish_c5os() {
	resize2fs "$UD_DEV" > /tmp/c5os-resize.log 2>&1 || { log_lines "resize2fs: " "$(cat /tmp/c5os-resize.log)"; fail "resize2fs grow failed"; }
	if tune2fs -l "$C5OS_DEV" 2>/dev/null | grep -q '^Filesystem volume name: *c5os$'; then
		log "c5os: $C5OS_DEV already has the c5os file system"
	else
		mkfs.ext4 -F -L c5os "$C5OS_DEV" > /tmp/c5os-mkfs.log 2>&1 || { log_lines "mkfs: " "$(cat /tmp/c5os-mkfs.log)"; fail "mkfs.ext4 on $C5OS_DEV failed"; }
	fi
	remount_data || fail "cannot remount $UD_DEV on $C5_DATA"
	log "c5os: created $C5OS_DEV (start $C5OS_START, $((C5OS_SIZE / 2048)) MiB, ext4); userdata is now ${UD_NEW_MIB} MiB"
}

# c5os_script: the sfdisk script for the new table: the disk's own GPT with
# the backup header at the disk end, p7 shrunk, p8 c5os with p7's type
c5os_script() {
	"$C5_SFDISK" --dump "$C5_DISK" 2>/dev/null | awk -v last=$((DISK_SECTORS - 34)) -v start="$C5OS_START" \
		-v size="$C5OS_SIZE" -v ud="$UD_NEW_SIZE" -v dev="${C5_DISK}p8" '
		/^(label|label-id|device|unit|first-lba|sector-size):/ { print; next }
		/^last-lba:/ { print "last-lba: " last; next }
		/^table-length:/ { tl = 1; print; next }
		/^[^ ]+ *: *start=/ {
			if (!tl) { print "table-length: 8"; tl = 1 }
			n++
			if (n == 7) {
				sub(/size= *[0-9]+/, "size=" ud)
				t = $0; sub(/.*type= */, "", t); sub(/,.*/, "", t); type = t
			}
			print; next
		}
		END {
			if (n != 7 || type == "") exit 1
			print dev " : start=" start ", size=" size ", type=" type ", name=\"c5os\""
		}'
}

make_c5os() {
	if [ "$HAVE_C5OS" = 1 ]; then
		if ! c5os_kernel_ok; then
			c5os_reboot
		fi
		rm -f "$OCDIR/c5os-rebooted"
		fs_blocks=$(dumpe2fs -h "$UD_DEV" 2>/dev/null | sed -n 's/^Block count: *//p')
		fs_bs=$(dumpe2fs -h "$UD_DEV" 2>/dev/null | sed -n 's/^Block size: *//p')
		if [ "${fs_blocks:-0}" -lt $(($(part_bytes "$UD_DEV") / ${fs_bs:-4096})) ] ||
			! tune2fs -l "$C5OS_DEV" 2>/dev/null | grep -q '^Filesystem volume name: *c5os$'; then
			log "c5os: finishing an interrupted c5os setup"
			ui_info c5os-run "Finishing the c5os partition\nDo not power off."
			finish_c5os
		else
			log "c5os: $C5OS_DEV present ($((C5OS_SIZE / 2048)) MiB)"
		fi
		return 0
	fi

	if [ "$C5_C5OS_MIB" -ge 1024 ] && [ $((C5_C5OS_MIB % 1024)) = 0 ]; then
		c5os_human="$((C5_C5OS_MIB / 1024)) GB"
	else
		c5os_human="${C5_C5OS_MIB} MB"
	fi
	if [ "$YES" = 1 ]; then c5os_nonui=ok; else c5os_nonui=ask; fi
	ui_confirm c5os 5 "Create a ${c5os_human} partition\nuserdata (stock /usr/data, ${UD_MIB} MiB) is shrunk to ${UD_NEW_MIB} MiB and the rest becomes the ext4 partition c5os for OpenWrt. The backup GPT moves to the end of the disk. Do not power off while this runs (about a minute)." \
		"Create partition" "Cancel" "$c5os_nonui" "Create the c5os partition (userdata $UD_MIB MiB -> $UD_NEW_MIB MiB)?" ||
		abort "cancelled at c5os"

	ui_info c5os-run "Creating the c5os partition\nChecking and shrinking the userdata filesystem..."
	log "c5os: shrinking userdata ($UD_DEV) to $UD_SHRINK_MIB MiB, then p7 to $UD_NEW_MIB MiB and p8 c5os at $C5OS_START ($((C5OS_SIZE / 2048)) MiB)"
	cd / || true
	sync
	NO_DATA_LOG=1 DATA_DOWN=1
	if ! umount "$C5_DATA" 2>/dev/null; then
		DATA_DOWN=0 NO_DATA_LOG=0
		log_lines "fuser: " "$(fuser -m "$C5_DATA" 2>&1)"
		fail "cannot unmount $C5_DATA (something holds it open); nothing written"
	fi
	e2fsck -f -y "$UD_DEV" > /tmp/c5os-fsck.log 2>&1
	rc=$?
	log_lines "e2fsck: " "$(tail -n 5 /tmp/c5os-fsck.log)"
	[ "$rc" -lt 4 ] || fail "e2fsck on $UD_DEV returned $rc"
	min_blocks=$(resize2fs -P "$UD_DEV" 2>/dev/null | sed -n 's/.*: *\([0-9][0-9]*\)$/\1/p' | tail -n 1)
	fs_bs=$(dumpe2fs -h "$UD_DEV" 2>/dev/null | sed -n 's/^Block size: *//p')
	case "$min_blocks$fs_bs" in '' | *[!0-9]*) fail "cannot read the minimum size of $UD_DEV" ;; esac
	min_mib=$(((min_blocks * fs_bs + 1048575) / 1048576))
	log "c5os: userdata needs at least $min_mib MiB"
	if [ "$min_mib" -gt $((UD_SHRINK_MIB - UD_HEADROOM_MIB)) ]; then
		remount_data || fail "cannot remount $UD_DEV on $C5_DATA"
		ui_block c5os-space "$(space_text $((min_mib - (UD_SHRINK_MIB - UD_HEADROOM_MIB))))"
	fi
	resize2fs "$UD_DEV" "${UD_SHRINK_MIB}M" > /tmp/c5os-resize.log 2>&1 ||
		{ log_lines "resize2fs: " "$(cat /tmp/c5os-resize.log)"; fail "resize2fs shrink failed"; }
	log "c5os: userdata file system shrunk to $UD_SHRINK_MIB MiB"

	# power loss from here on is safe: the file system fits the old and the new p7
	dd if="$C5_DISK" of=/tmp/c5os-lba0 bs=512 count=1 2>/dev/null || fail "cannot read LBA 0 of $C5_DISK"
	c5os_script > /tmp/c5os.sfdisk || fail "cannot build the new partition table from $C5_SFDISK --dump"
	log_lines "sfdisk script: " "$(cat /tmp/c5os.sfdisk)"
	# sfdisk would only try BLKRRPART, which fails while any partition of
	# the disk is mounted; partx below updates p7/p8 one by one (BLKPG)
	if ! "$C5_SFDISK" --force --no-reread --no-tell-kernel --wipe never --wipe-partitions never "$C5_DISK" < /tmp/c5os.sfdisk > /tmp/c5os-sfdisk.log 2>&1; then
		log_lines "sfdisk: " "$(cat /tmp/c5os-sfdisk.log)"
		fail "sfdisk failed: $(tail -n 2 /tmp/c5os-sfdisk.log | tr '\n' ' ')"
	fi
	log_lines "sfdisk: " "$(tail -n 6 /tmp/c5os-sfdisk.log)"
	if [ "$(head -c 440 /tmp/c5os-lba0 | "$SUM")" = "$(head -c 440 "$C5_DISK" | "$SUM")" ]; then
		log "c5os: MBR boot code unchanged"
	else
		dd if=/tmp/c5os-lba0 of="$C5_DISK" bs=1 count=440 conv=notrunc,fsync 2>/dev/null || fail "cannot restore the MBR boot code"
		log "c5os: MBR boot code restored"
	fi
	drop_caches
	if "$C5_PARTX" -u --nr 7:8 "$C5_DISK" > /tmp/c5os-partx.log 2>&1; then
		log "c5os: kernel told about p7/p8 (partx)"
	else
		log_lines "partx: " "$(cat /tmp/c5os-partx.log)"
	fi

	PT=$(part_table)
	# shellcheck disable=SC2046
	set -- $(printf '%s\n' "$PT" | awk '$1 == "c5os" { print $2, $3, $4 } $1 == "userdata" { u = $4 } END { print u }')
	[ $# = 4 ] && [ "$1" = 8 ] && [ "$2" = "$C5OS_START" ] && [ "$3" = "$C5OS_SIZE" ] && [ "$4" = "$UD_NEW_SIZE" ] ||
		fail "the new partition table does not read back as written: $(printf '%s\n' "$PT" | tr '\n' ';')"
	HAVE_C5OS=1 UD_SIZE=$UD_NEW_SIZE
	if ! c5os_kernel_ok; then
		remount_data || fail "cannot remount $UD_DEV on $C5_DATA"
		c5os_reboot
	fi
	log "c5os: kernel sees the new partitions"
	finish_c5os
}

# --- actions ---------------------------------------------------------------------

do_swap() {
	if [ "$FLAG" = "$OWN" ]; then
		[ "$INSTALLED" = 1 ] || abort "swap: OpenWrt is not installed"
		if ! flag_write "$TGT"; then
			flag_write "$OWN"
			fail "boot flag write failed; flag set back to slot $OWN ('$(flag_read)')"
		fi
		log "swap: boot flag -> slot $TGT ('$(flag_read)'); rebooting into OpenWrt"
		ui_info swap "Rebooting into OpenWrt (slot $TGT)"
		sync
		$C5_REBOOT
		exit 0
	fi
	flag_write "$OWN" || fail "boot flag write failed ('$(flag_read)')"
	log "swap: boot flag -> slot $OWN ('$(flag_read)'); stock stays the boot slot"
	finish swap "Boot flag set to stock (slot $OWN)\nThe printer keeps booting stock." 1
}

do_install() {
	if [ "$CHAIN_DONE" = 1 ]; then
		log "chainload: this stick's test boot already ran (key $CL_KEY) and stock is running again:"
		log "chainload: the test hung, or OpenWrt failed its health check (see $OCDIR/logs/ if it got that far)"
		log "chainload: not repeating it; to test again, edit or re-create opencreator-os/CHAINLOAD on the stick"
		finish written "Test boot already ran\nThis stick's OpenWrt test boot ran before and stock is running again. Edit or re-create opencreator-os/CHAINLOAD to test again." 1
	fi

	if [ "$BACKUP" = 1 ]; then bk_nonui=ok; else bk_nonui=cancel; fi
	if ui_confirm backup 0 "Back up the eMMC to this stick first?\n${BK_NEED_MIB} MB will be written to the stick and verified (about 20 minutes on the printer). The backup includes the full-size userdata and is what tools/make-restore-stick.sh restores from." \
		"Back up" "Skip backup" "$bk_nonui"; then
		backup_emmc
	elif [ "$UI" = 1 ]; then
		log "backup: skipped by the user"
	else
		log "backup: skipped (no --backup)"
	fi
	make_c5os
	check_data_space

	if [ "$YES" != 1 ] && [ "$HOOK" != 1 ] && [ "$UI" != 1 ]; then
		[ -t 0 ] || abort "not interactive; re-run with --yes"
		printf 'Write OpenWrt to slot %s (%s, %s)? Type YES: ' "$TGT" "$TK" "$TR"
		read -r answer
		[ "$answer" = YES ] || abort "not confirmed"
	fi

	ui_info install "Installing opencreator-os $VERSION\nSaving the stock slot and writing slot $TGT. Do not power off."
	mkdir -p "$OCDIR" || fail "cannot create $OCDIR"
	save_stock
	save_wifi
	copy_chainload
	flag_ensure_own "$OWN" || fail "cannot point the boot flag at the running slot $OWN; nothing written to slot $TGT"
	write_slot

	prev_flip=$(grep -x "flipped slot=$TGT version=$VERSION" "$OCDIR/install.state" 2>/dev/null)
	prev_chain=$(grep "^chainload slot=$TGT " "$OCDIR/install.state" 2>/dev/null)
	{
		echo "written slot=$TGT kernel=$TK rootfs=$TR version=$VERSION"
		[ -z "$prev_flip" ] || echo "$prev_flip"
		[ -z "$prev_chain" ] || echo "$prev_chain"
	} > "$OCDIR/install.state"
	sync
	written_text="OpenWrt written to slot $TGT\nThe boot flag still points at stock. Use Swap to OpenWrt, a FLIP stick or switch-to-openwrt.sh."

	if [ "$FLIP" = 1 ]; then
		if [ -n "$prev_flip" ]; then
			log "flip: the boot flag was already switched to this build once and stock is running again"
			log "flip: (OpenWrt probably failed its health check and fell back); not switching again"
			log "flip: retry with sh $SELF_DIR/switch-to-openwrt.sh, or remove opencreator-os/FLIP"
			finish written "$written_text" 1
		fi
		if ! flag_write "$TGT"; then
			flag_write "$OWN"
			fail "boot flag write failed; flag set back to slot $OWN ('$(flag_read)')"
		fi
		echo "flipped slot=$TGT version=$VERSION" >> "$OCDIR/install.state"
		log "flip: boot flag -> slot $TGT ('$(flag_read)'); rebooting into OpenWrt"
		log "install: OK"
		ui_info 'done' "Rebooting into OpenWrt"
		sync
		[ "$HOOK" = 1 ] && [ "$UI" = 0 ] && sleep "${C5_SCREEN_PAUSE:-10}"
		$C5_REBOOT
		exit 0
	fi

	log "install: OK; slot $TGT written, boot flag still on stock (slot $OWN)"
	[ "$CHAIN" = 1 ] && chainload_test
	log "next: test-boot it from stock without touching the flag:"
	log "next:   sh $OCDIR/chainload/c5-chainload.sh stage $TR && sh $OCDIR/chainload/c5-chainload.sh go"
	log "next: or switch for real: sh $SELF_DIR/switch-to-openwrt.sh (or re-run with --flip / a FLIP marker)"
	if [ "$HOOK" = 1 ]; then
		finish written "$written_text" 1
	fi
	ui_info written "$written_text"
	exit 0
}

# --- main ------------------------------------------------------------------------

log "install: opencreator-os $VERSION from $STICK (check=$CHECK flip=$FLIP chainload=$CHAIN hook=$HOOK ui=$UI action=$ACTION)"
ui_info check "Checking the printer..."
[ "$FLIP" = 1 ] && [ "$CHAIN" = 1 ] && abort "FLIP and CHAINLOAD are both set; use one of them"
preflight

# A hook-run chainload test that already ran for this request and left stock
# running (the test hung and was power-cycled, or OpenWrt failed its health
# check) is not repeated, so a power cycle really returns to stock.
CHAIN_DONE=0
if [ "$CHAIN" = 1 ] && [ "$HOOK" = 1 ] &&
	grep -q "^chainload slot=$TGT key=$CL_KEY " "$OCDIR/install.state" 2>/dev/null; then
	CHAIN_DONE=1
fi

if [ "$STOCK_SAVED" = 1 ]; then save_plan="already saved in $SD"; else save_plan="would save $OKDEV ($OKB bytes) + $ORDEV ($BU bytes) to $SD"; fi
log "check: running slot $OWN ($OKDEV, $ORDEV), boot flag slot $FLAG"
if [ "$FLAG" != "$OWN" ]; then
	log "check: boot flag names slot $FLAG ('$(flag_read)'); would point it back at the running slot $OWN before writing"
fi
if [ "$UP_TO_DATE" = 1 ] && [ "$PENDING" = 1 ]; then
	log "check: slot $TGT matches the payload but a previous install did not finish; would redo the overlay cleanup on $TR"
elif [ "$UP_TO_DATE" = 1 ]; then
	log "check: slot $TGT already up to date: $TK (kernel, $KSZ bytes) and $TR (rootfs, $RSZ bytes) match; no write"
else
	log "check: would write slot $TGT: $TK (kernel, $KSZ of $TKB bytes) and $TR (rootfs, $RSZ of $TRB bytes)"
fi
log "check: stock: $save_plan"
if [ "$HAVE_C5OS" = 1 ]; then
	log "check: c5os: present"
else
	log "check: c5os: would create (userdata $UD_MIB MiB -> $UD_NEW_MIB MiB, c5os $((C5OS_SIZE / 2048)) MiB at sector $C5OS_START)"
fi
log "check: backup: $([ "$BACKUP" = 1 ] && echo "yes ($BK_NEED_MIB MiB to $BK_DIR)" || echo "no (--backup)")"
log "check: flip boot flag afterwards: $([ "$FLIP" = 1 ] && echo yes || echo no)"
if [ "$CHAIN_DONE" = 1 ]; then
	log "check: chainload test afterwards: no (already ran for this stick, key $CL_KEY)"
else
	log "check: chainload test afterwards: $([ "$CHAIN" = 1 ] && echo "yes (root=$TR)" || echo no)"
fi
if [ "$CHECK" = 1 ]; then
	log "check: OK"
	exit 0
fi

if [ "$FLAG" = "$TGT" ]; then
	SWAP_LABEL="Swap to stock"
elif [ "$INSTALLED" = 1 ]; then
	SWAP_LABEL="Swap to OpenWrt"
else
	SWAP_LABEL="-Swap to OpenWrt (not installed)"
fi
ui_menu main "opencreator-os $VERSION\nStock slot $OWN, boot flag: $([ "$FLAG" = "$OWN" ] && echo stock || echo OpenWrt). OpenWrt: $([ "$INSTALLED" = 1 ] && echo "installed in slot $TGT" || echo "not installed")" \
	"Install / update opencreator-os" "$SWAP_LABEL" "-Uninstall (not yet available)"
case "$UI_CHOICE" in
1) do_install ;;
2) do_swap ;;
0) abort "cancelled at main" ;;
*) abort "menu item $UI_CHOICE is not available" ;;
esac
