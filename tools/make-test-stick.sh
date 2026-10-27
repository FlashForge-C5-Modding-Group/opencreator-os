#!/usr/bin/env bash
# Build the zero-write USB test stick image (docs/usb-test.md).
#
#   tools/make-test-stick.sh [--authorized-keys FILE] VERSION_DIR OUT.img
#
# VERSION_DIR  build output, e.g. /mnt/f/creator5-dev/opencreator-os-builds/<ver>
# OUT.img      disk image to write to a USB stick (balenaEtcher, Rufus, dd)
# --authorized-keys FILE  SSH keys for root during the test (optional)
#
# Layout (MBR): partition 1 FAT32 64 MiB with the stock hook, chainload.ko,
# the kernel and the test scripts; partition 2 96 MiB, the OpenWrt squashfs
# followed by zeros (OpenWrt formats its overlay there on first boot).
# Needs: sfdisk, mkfs.vfat, mtools. No root.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=opencreator-os-x2600-generic-flashforge_creator5pro-squashfs
P1_MIB=64 P2_MIB=96
KEYS=

usage() { sed -n '2,14s/^# \{0,1\}//p' "$0"; }
die() { echo "make-test-stick: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--authorized-keys) [ $# -ge 2 ] || die "--authorized-keys needs a file"; KEYS=$2; shift ;;
	-h | --help) usage; exit 0 ;;
	-*) die "unknown option $1" ;;
	*) break ;;
	esac
	shift
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
VDIR=$1 IMG=$2

for t in sfdisk mkfs.vfat mcopy mmd fsck.vfat; do
	command -v "$t" > /dev/null || die "missing $t (apt install fdisk dosfstools mtools)"
done
[ -d "$VDIR" ] || die "$VDIR is not a directory"
KIMG=$VDIR/$PREFIX-kernel.uimage RIMG=$VDIR/$PREFIX-root.squashfs
{ [ -s "$KIMG" ] && [ -s "$RIMG" ]; } || die "missing $PREFIX-{kernel.uimage,root.squashfs} in $VDIR"
[ "$(head -c 4 "$KIMG" | od -An -tx1 | tr -d ' \n')" = 27051956 ] || die "kernel.uimage is not a uImage"
[ "$(head -c 4 "$RIMG")" = hsqs ] || die "root.squashfs is not squashfs"
[ "$(stat -c %s "$RIMG")" -lt $(((P2_MIB - 16) << 20)) ] || die "root.squashfs leaves less than 16 MiB overlay in partition 2"
for f in installer/usbtest/runFirmwareExe.sh installer/usbtest/usbtest.sh installer/opencreator-os/lib.sh \
	installer/usbtest/fb/booting.raw installer/usbtest/fb/refused.raw chainload/out/chainload.ko chainload/c5-chainload.sh; do
	[ -s "$REPO/$f" ] || die "missing $REPO/$f"
done
[ -z "$KEYS" ] || [ -s "$KEYS" ] || die "authorized keys file $KEYS is empty or missing"

# chainload.ko refuses a payload larger than SAFE_MIN - LOAD_PHYS.
cl_const() {
	awk -v n="$1" '$1 == "#define" && $2 == n { v = $3; sub(/[uUlL]+$/, "", v); print v; exit }' "$REPO/chainload/chainload_main.c"
}
LIMIT=$(($(cl_const SAFE_MIN) - $(cl_const LOAD_PHYS)))
KPAY=$((($(stat -c %s "$KIMG") - 64 + 4095) / 4096 * 4096))
[ "$KPAY" -le "$LIMIT" ] || die "kernel payload $KPAY bytes exceeds the chainload limit $LIMIT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
T=$TMP/stage/opencreator-os-test
mkdir -p "$T"
install -m 0644 "$REPO/installer/usbtest/usbtest.sh" "$REPO/installer/opencreator-os/lib.sh" \
	"$REPO/chainload/out/chainload.ko" "$REPO/chainload/c5-chainload.sh" \
	"$REPO/installer/usbtest/fb/booting.raw" "$REPO/installer/usbtest/fb/refused.raw" "$T/"
install -m 0644 "$KIMG" "$T/kernel.uimage"
basename "$(cd "$VDIR" && pwd)" > "$T/VERSION"
(cd "$T" && find . -type f | sed 's|^\./||' | LC_ALL=C sort > "$TMP/list" &&
	xargs -d '\n' sha256sum < "$TMP/list" > SHA256SUMS && xargs -d '\n' md5sum < "$TMP/list" > MD5SUMS)
[ -z "$KEYS" ] || install -m 0644 "$KEYS" "$T/authorized_keys"

P1=$TMP/p1.img
truncate -s "${P1_MIB}M" "$P1"
mkfs.vfat -F 32 -n C5TEST "$P1" > /dev/null
mcopy -i "$P1" "$REPO/installer/usbtest/runFirmwareExe.sh" ::/runFirmwareExe.sh
mmd -i "$P1" ::/opencreator-os-test
mcopy -i "$P1" "$T"/* ::/opencreator-os-test/
fsck.vfat -n "$P1" > /dev/null || die "FAT partition check failed"

rm -f "$IMG"
truncate -s $(((1 + P1_MIB + P2_MIB) << 20)) "$IMG"
sfdisk -q "$IMG" << EOF
label: dos
start=1MiB, size=${P1_MIB}MiB, type=c
start=$((1 + P1_MIB))MiB, size=${P2_MIB}MiB, type=83
EOF
dd if="$P1" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$RIMG" of="$IMG" bs=1M seek=$((1 + P1_MIB)) conv=notrunc status=none
(cd "$(dirname "$IMG")" && sha256sum "$(basename "$IMG")" > "$(basename "$IMG").sha256")

echo "Test stick image for $(cat "$T/VERSION"): $IMG ($((1 + P1_MIB + P2_MIB)) MiB)"
sfdisk -l "$IMG" | sed -n '/^Device/,$p'
echo "Write it to a USB stick (all data on the stick is lost), power the printer"
echo "on with it inserted, wait 5 minutes, cut the power. See docs/usb-test.md."
