#!/bin/sh
# opencreator-os installer. Runs on the stock Creator 5 Pro firmware (busybox
# sh, root) and writes OpenWrt into the eMMC slot stock is NOT running from.
# The boot flag is left on stock unless --flip (or a FLIP marker) is given.
#
#   sh install.sh [--from-stick DIR] [--check] [--flip] [--yes] [--hook]
#
#   --from-stick DIR  payload directory (default: the directory above this
#                     script, i.e. the stick root)
#   --check           run every precondition, print the plan, write nothing
#   --flip            after a verified write, point the boot flag at OpenWrt
#                     and reboot (same as a file opencreator-os/FLIP on the stick)
#   --yes             do not ask for confirmation
#   --hook            started by the stock USB hook (runFirmwareExe.sh):
#                     implies --yes, pauses on the result screen, and exits 1
#                     after a non-flip install so stock keeps booting
# Other non-option arguments (stock passes MACHINE and PID) are ignored.
#
# Payload in DIR: kernel.uimage root.squashfs sysupgrade.tar VERSION
# chainload/chainload.ko chainload/c5-chainload.sh SHA256SUMS MD5SUMS,
# optional opencreator-os/authorized_keys and opencreator-os/FLIP.
set -u

usage() { sed -n '2,23s/^# \{0,1\}//p' "$0"; }

SELF_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
STICK='' CHECK=0 FLIP=0 YES=0 HOOK=0
while [ $# -gt 0 ]; do
	case "$1" in
	--from-stick)
		[ $# -ge 2 ] || { echo "install: --from-stick needs a directory" >&2; exit 2; }
		STICK=$2
		shift
		;;
	--check) CHECK=1 ;;
	--flip) FLIP=1 ;;
	--yes) YES=1 ;;
	--hook) HOOK=1 YES=1 ;;
	-h | --help) usage; exit 0 ;;
	-*) echo "install: unknown option $1" >&2; usage >&2; exit 2 ;;
	*) ;;
	esac
	shift
done
[ -n "$STICK" ] || STICK=$(dirname "$SELF_DIR")
STICK=$(cd "$STICK" 2>/dev/null && pwd) || { echo "install: payload directory not found" >&2; exit 1; }
FBDIR=$SELF_DIR/fb

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SELF_DIR/lib.sh"

[ -f "$STICK/opencreator-os/FLIP" ] && FLIP=1
SD=$OCDIR/stock
MIN_FREE=$((64 * 1024 * 1024))
VERSION=$(head -n 1 "$STICK/VERSION" 2>/dev/null | tr -d '\r')
[ -n "$VERSION" ] || VERSION=unknown

finish() {  # finish SCREEN EXITCODE
	show "$1"
	sync
	[ "$HOOK" = 1 ] && sleep "${C5_SCREEN_PAUSE:-10}"
	exit "$2"
}

# abort before anything was written: in check mode just report
abort() {
	log "abort: $*"
	[ "$CHECK" = 1 ] && exit 1
	log "install: FAILED (nothing written)"
	finish failed 1
}

fail() {
	log "install: FAILED $*"
	log "install: boot flag untouched; stock stays the boot slot"
	finish failed 1
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
	[ "$FLAG" = "$OWN" ] || abort "boot flag and running root disagree (flag: slot $FLAG '$(flag_read)', running: slot $OWN)"
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
	[ "$KSZ" -le "$TKB" ] || abort "kernel.uimage ($KSZ bytes) does not fit $TK ($TKB bytes)"
	[ "$RSZ" -le "$TRB" ] || abort "root.squashfs ($RSZ bytes) does not fit $TR ($TRB bytes)"

	[ -s "$STICK/$SUMS" ] || abort "$SUMS missing in $STICK"
	KSUM=$(sums_get "$STICK/$SUMS" kernel.uimage)
	RSUM=$(sums_get "$STICK/$SUMS" root.squashfs)
	if [ -z "$KSUM" ] || [ -z "$RSUM" ]; then abort "$SUMS does not list kernel.uimage and root.squashfs"; fi
	bad=$(sums_verify "$STICK" "$SUMS") || abort "payload checksum mismatch ($SUMS): ${bad:-empty list}"

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
	need=$((KSZ + 2 * 1024 * 1024))
	[ "$STOCK_SAVED" = 1 ] || need=$((need + OKB + BU))
	[ "$need" -ge "$MIN_FREE" ] || need=$MIN_FREE
	free=$(free_bytes "$C5_DATA") || abort "cannot read free space on $C5_DATA"
	[ "$free" -ge "$need" ] || abort "$C5_DATA has $((free / 1048576)) MiB free, need $((need / 1048576)) MiB"
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

# wpa_get FILE KEY -> raw value of KEY in the first network={} block
wpa_get() {
	tr -d '\r' < "$1" | awk -v k="$2" '
		!inb && /^[ \t]*network[ \t]*=[ \t]*\{/ { inb = 1; next }
		inb && /^[ \t]*\}/ { exit }
		inb { l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l)
		      if (index(l, k "=") == 1) { print substr(l, length(k) + 2); exit } }'
}

hex_decode() {
	printf '%s' "$1" | awk '{ h = "0123456789abcdef"; t = tolower($0); s = ""
		for (i = 1; i < length(t); i += 2)
			s = s sprintf("%c", (index(h, substr(t, i, 1)) - 1) * 16 + index(h, substr(t, i + 1, 1)) - 1)
		printf "%s", s }'
}

# wpa_value RAW: "quoted" -> contents; even-length hex -> decoded (ssid only)
wpa_value() {
	case "$1" in
	\"*\"*) wv=${1#\"}; printf '%s' "${wv%\"*}" ;;
	*) printf '%s' "$1" ;;
	esac
}

save_wifi() {
	wpa=${C5_WPA:-/usr/prog/wifi/wpa_supplicant.conf}
	if [ -f "$wpa" ]; then
		ssid_raw=$(wpa_get "$wpa" ssid)
		psk_raw=$(wpa_get "$wpa" psk)
		ssid=$(wpa_value "$ssid_raw")
		case "$ssid_raw" in
		\"*) ;;
		*) if [ -n "$ssid_raw" ] && ! printf '%s' "$ssid_raw" | grep -q '[^0-9A-Fa-f]' && [ $((${#ssid_raw} % 2)) = 0 ]; then
				ssid=$(hex_decode "$ssid_raw")
			fi ;;
		esac
		psk=$(wpa_value "$psk_raw")
		if [ -n "$ssid" ]; then
			(
				umask 077
				{ echo "SSID=$(shq "$ssid")"; echo "PSK=$(shq "$psk")"; } > "$OCDIR/wifi.conf.new" &&
					chmod 600 "$OCDIR/wifi.conf.new" && mv -f "$OCDIR/wifi.conf.new" "$OCDIR/wifi.conf"
			) || fail "cannot write $OCDIR/wifi.conf"
			if [ -n "$psk" ]; then
				log "wifi: saved SSID '$ssid' with its key to $OCDIR/wifi.conf"
			else
				log "wifi: saved SSID '$ssid' (no psk= in $wpa; open network?) to $OCDIR/wifi.conf"
			fi
		else
			log "wifi: no network block with ssid= in $wpa; wifi.conf not written"
		fi
	else
		log "wifi: $wpa not found; wifi.conf not written"
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
	if [ "$(dev_sum "$TK" "$KSZ")" = "$KSUM" ] && [ "$(dev_sum "$TR" "$RSZ")" = "$RSUM" ]; then
		log "write: slot $TGT already holds this payload ($TK, $TR); not rewriting"
		return 0
	fi
	log "write: kernel.uimage ($KSZ bytes) -> $TK"
	dd if="$STICK/kernel.uimage" of="$TK" bs=1M conv=fsync,notrunc 2>/dev/null || fail "dd to $TK failed"
	log "write: root.squashfs ($RSZ bytes) -> $TR"
	dd if="$STICK/root.squashfs" of="$TR" bs=1M conv=fsync,notrunc 2>/dev/null || fail "dd to $TR failed"
	drop_caches
	[ "$(dev_sum "$TK" "$KSZ")" = "$KSUM" ] || fail "read-back mismatch on $TK"
	[ "$(dev_sum "$TR" "$RSZ")" = "$RSUM" ] || fail "read-back mismatch on $TR"
	log "write: slot $TGT written and read back OK ($SUM)"
	# fstools puts the overlay (rootfs_data) right after the squashfs, at
	# bytes_used rounded up to 64 KiB; wipe any stale ext4 superblock there so
	# the first boot formats a fresh overlay.
	bu=$(squashfs_bytes "$STICK/root.squashfs") || fail "cannot read bytes_used of root.squashfs"
	off=$(((bu + 65535) / 65536 * 65536))
	if [ $((off + 4096)) -le "$TRB" ]; then
		dd if=/dev/zero of="$TR" bs=512 seek=$((off / 512)) count=8 conv=fsync,notrunc 2>/dev/null ||
			fail "cannot clear the overlay area of $TR"
		log "write: cleared 4 KiB overlay header at offset $off of $TR"
	fi
}

# --- main ------------------------------------------------------------------------

log "install: opencreator-os $VERSION from $STICK (check=$CHECK flip=$FLIP hook=$HOOK)"
preflight

if [ "$STOCK_SAVED" = 1 ]; then save_plan="already saved in $SD"; else save_plan="would save $OKDEV ($OKB bytes) + $ORDEV ($BU bytes) to $SD"; fi
log "check: running slot $OWN ($OKDEV, $ORDEV), boot flag slot $FLAG"
log "check: would write slot $TGT: $TK (kernel, $KSZ of $TKB bytes) and $TR (rootfs, $RSZ of $TRB bytes)"
log "check: stock: $save_plan"
log "check: flip boot flag afterwards: $([ "$FLIP" = 1 ] && echo yes || echo no)"
if [ "$CHECK" = 1 ]; then
	log "check: OK"
	exit 0
fi

if [ "$YES" != 1 ]; then
	[ -t 0 ] || abort "not interactive; re-run with --yes"
	printf 'Write OpenWrt to slot %s (%s, %s)? Type YES: ' "$TGT" "$TK" "$TR"
	read -r answer
	[ "$answer" = YES ] || abort "not confirmed"
fi

show installing
mkdir -p "$OCDIR" || fail "cannot create $OCDIR"
save_stock
save_wifi
copy_chainload
write_slot

prev_flip=$(grep -x "flipped slot=$TGT version=$VERSION" "$OCDIR/install.state" 2>/dev/null)
{
	echo "written slot=$TGT kernel=$TK rootfs=$TR version=$VERSION"
	[ -z "$prev_flip" ] || echo "$prev_flip"
} > "$OCDIR/install.state"
sync

if [ "$FLIP" = 1 ]; then
	if [ -n "$prev_flip" ]; then
		log "flip: the boot flag was already switched to this build once and stock is running again"
		log "flip: (OpenWrt probably failed its health check and fell back); not switching again"
		log "flip: retry with sh $SELF_DIR/switch-to-openwrt.sh, or remove opencreator-os/FLIP"
		finish written 1
	fi
	if ! flag_write "$TGT"; then
		flag_write "$OWN"
		fail "boot flag write failed; flag set back to slot $OWN ('$(flag_read)')"
	fi
	echo "flipped slot=$TGT version=$VERSION" >> "$OCDIR/install.state"
	log "flip: boot flag -> slot $TGT ('$(flag_read)'); rebooting into OpenWrt"
	log "install: OK"
	show 'done'
	sync
	[ "$HOOK" = 1 ] && sleep "${C5_SCREEN_PAUSE:-10}"
	$C5_REBOOT
	exit 0
fi

log "install: OK; slot $TGT written, boot flag still on stock (slot $OWN)"
log "next: test-boot it from stock without touching the flag:"
log "next:   sh $OCDIR/chainload/c5-chainload.sh stage $TR && sh $OCDIR/chainload/c5-chainload.sh go"
log "next: or switch for real: sh $SELF_DIR/switch-to-openwrt.sh (or re-run with --flip / a FLIP marker)"
if [ "$HOOK" = 1 ]; then
	finish written 1
fi
show written
exit 0
