#!/bin/sh
# Stock side of the zero-write USB test (docs/usb-test.md). Started by the
# stick's runFirmwareExe.sh from a copy in /tmp:
#
#   usbtest.sh STICKDIR      (STICKDIR = <stick>/opencreator-os-test)
#
# Test-boots OpenWrt from RAM (chainload.ko) with its root on the stick's
# second partition and c5.usbtest=1 on the command line. Writes only to the
# stick: hook.log, wifi.conf (from stock's wpa_supplicant.conf) and the
# ATTEMPTED marker, which makes the next boot skip the test so a power cycle
# always returns to stock. Nothing is written to the eMMC; the boot flag is
# not touched.
#
# Exit 1 = stock keeps booting. After the jump nothing returns; if the jump
# is refused, the refused screen is shown and exit 0 stalls stock until the
# user power-cycles.
# Test overrides: C5T_ROOTDEV (/dev/sda2), C5T_WPA, C5T_FB, C5T_UNAME_R,
# C5T_CMDLINE, C5T_TMP (/tmp/c5usbtest), C5T_NOJUMP (stop after staging).

T=$1
W=${C5T_TMP:-/tmp/c5usbtest}
ROOTDEV=${C5T_ROOTDEV:-/dev/sda2}
WPA=${C5T_WPA:-/usr/prog/wifi/wpa_supplicant.conf}
FB=${C5T_FB:-/dev/fb0}
UNAME_R=${C5T_UNAME_R:-$(uname -r)}
CMDLINE_FILE=${C5T_CMDLINE:-/proc/cmdline}
LOG=$T/hook.log

[ -d "$T" ] || { echo "usbtest: no directory '$T'" >&2; exit 1; }
# shellcheck source=../opencreator-os/lib.sh
. "$W/lib.sh"

# lib.sh's log also writes to /usr/data; this test writes only to the stick.
log() {
	echo "$*"
	echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
	return 0
}
give_up() {
	log "usbtest: $*"
	log "usbtest: nothing was written to the eMMC; stock keeps booting"
	sync
	exit 1
}
show() { [ -e "$FB" ] && [ -f "$W/$1.raw" ] && cat "$W/$1.raw" > "$FB" 2>/dev/null; return 0; }

VERSION=$(head -n 1 "$T/VERSION" 2>/dev/null | tr -d '\r')
log "usbtest: opencreator-os ${VERSION:-unknown}, stock kernel $UNAME_R"

if [ -e "$T/ATTEMPTED" ]; then
	log "usbtest: already attempted ($(head -n 1 "$T/ATTEMPTED" 2>/dev/null)); delete opencreator-os-test/ATTEMPTED to test again"
	exit 1
fi

[ "$UNAME_R" = "5.10.186+" ] || give_up "expects the stock 5.10.186+ kernel, not $UNAME_R"
root=$(sed -n 's/.*[[:space:]]root=\([^[:space:]]*\).*/\1/p; s/^root=\([^[:space:]]*\).*/\1/p' "$CMDLINE_FILE" | head -n 1)
case "$root" in
/dev/mmcblk0p*) ;;
*) give_up "stock runs from '$root', not from the eMMC" ;;
esac
[ -b "$ROOTDEV" ] || [ -f "$ROOTDEV" ] || give_up "$ROOTDEV not found (stick partition 2)"
[ "$(magic_str "$ROOTDEV")" = "$SQUASHFS_MAGIC" ] || give_up "$ROOTDEV does not start with the OpenWrt squashfs"

sum_init
bad=$(sums_verify "$T" "$SUMS") || give_up "payload checksum mismatch ($SUMS): $bad"
for f in chainload.ko c5-chainload.sh kernel.uimage booting.raw refused.raw; do
	cp "$T/$f" "$W/" || give_up "cannot copy $f to $W"
	[ "$(file_sum "$W/$f")" = "$(sums_get "$T/$SUMS" "$f")" ] || give_up "copy of $f in $W is corrupt"
done
log "usbtest: payload verified ($SUM) and copied to $W"

if [ ! -f "$WPA" ]; then
	log "usbtest: $WPA not found; OpenWrt will have no Wi-Fi"
elif ssid=$(wifi_conf "$WPA" "$T/wifi.conf"); then
	log "usbtest: Wi-Fi '$ssid' written to the stick (opencreator-os-test/wifi.conf; delete it after the test)"
else
	log "usbtest: no usable network block in $WPA; OpenWrt will have no Wi-Fi"
fi

if ! out=$(C5CL_EXTRA=c5.usbtest=1 sh "$W/c5-chainload.sh" stage "$ROOTDEV" "$W/kernel.uimage" 2>&1); then
	log "$out"
	grep -q '^chainload ' /proc/modules 2>/dev/null && rmmod chainload
	give_up "staging failed"
fi
log "$out"

if [ -n "${C5T_NOJUMP:-}" ]; then
	rmmod chainload 2>/dev/null
	give_up "C5T_NOJUMP set; not jumping"
fi

echo "$(date '+%F %T') ${VERSION:-unknown}" > "$T/ATTEMPTED" || give_up "cannot write the ATTEMPTED marker"
log "usbtest: jumping to OpenWrt (root=$ROOTDEV). It writes its report to opencreator-os-test/openwrt/ on this stick."
log "usbtest: wait 5 minutes, then cut the power; stock boots again and skips the test."
show booting
sync
cd /
umount /mnt 2>/dev/null
sync
# go-now kills processes whose command line names opencreator; run it under
# a command line naming c5-chainload, which it spares. It returns only when
# the jump was refused (stock half shut down): show that and stall.
# shellcheck disable=SC2016
exec sh -c 'sh "$1" go-now; [ -e "$3" ] && cat "$2" > "$3" 2>/dev/null; exit 0' \
	c5-chainload "$W/c5-chainload.sh" "$W/refused.raw" "$FB"
