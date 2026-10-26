#!/usr/bin/env bash
# Assemble the opencreator-os USB-stick payload from a build directory.
#
#   tools/make-install-stick.sh [--flip | --chainload] [--authorized-keys FILE] VERSION_DIR OUTDIR
#
# VERSION_DIR  build output, e.g. /mnt/f/creator5-dev/opencreator-os-builds/<ver>,
#              holding openwrt-x2600-generic-flashforge_creator5pro-*
# OUTDIR       new or empty directory; its contents go to the stick root
# --flip       add opencreator-os/FLIP: switch the boot flag after the write
# --chainload  add opencreator-os/CHAINLOAD: after the write, test-boot
#              OpenWrt from RAM (boot flag stays on stock)
# --authorized-keys FILE  ship FILE as the SSH keys for OpenWrt's root
#
# chainload.ko comes from chainload/out/ of this repo (chainload/build.sh).
# FLIP, CHAINLOAD and authorized_keys are left out of the checksum lists so
# they can be added or edited on the stick later.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=openwrt-x2600-generic-flashforge_creator5pro
FLIP=0 CHAIN=0 KEYS=

usage() { sed -n '2,16s/^# \{0,1\}//p' "$0"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--flip) FLIP=1 ;;
	--chainload) CHAIN=1 ;;
	--authorized-keys)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		KEYS=$2
		shift
		;;
	-h | --help) usage; exit 0 ;;
	-*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
	*) break ;;
	esac
	shift
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
[ "$FLIP" = 0 ] || [ "$CHAIN" = 0 ] || { echo "--flip and --chainload are mutually exclusive" >&2; exit 2; }
VDIR=$1 OUT=$2

die() { echo "make-install-stick: $*" >&2; exit 1; }

[ -d "$VDIR" ] || die "$VDIR is not a directory"
for a in kernel.uimage root.squashfs sysupgrade.tar; do
	[ -s "$VDIR/$PREFIX-$a" ] || die "missing $VDIR/$PREFIX-$a"
done
for f in installer/runFirmwareExe.sh installer/opencreator-os/install.sh installer/opencreator-os/lib.sh \
	installer/opencreator-os/switch-to-openwrt.sh chainload/out/chainload.ko chainload/c5-chainload.sh; do
	[ -s "$REPO/$f" ] || die "missing $REPO/$f"
done
for s in installing written 'done' failed chainload chainload-failed; do
	[ -s "$REPO/installer/fb/$s.raw" ] || die "missing screen image installer/fb/$s.raw"
done
[ -z "$KEYS" ] || [ -s "$KEYS" ] || die "authorized keys file $KEYS is empty or missing"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
	die "$OUT exists and is not empty"
fi

mkdir -p "$OUT/opencreator-os/fb" "$OUT/chainload"
install -m 0755 "$REPO/installer/runFirmwareExe.sh" "$OUT/"
install -m 0755 "$REPO/installer/opencreator-os/install.sh" "$REPO/installer/opencreator-os/switch-to-openwrt.sh" "$OUT/opencreator-os/"
install -m 0644 "$REPO/installer/opencreator-os/lib.sh" "$OUT/opencreator-os/"
install -m 0644 "$REPO"/installer/fb/*.raw "$OUT/opencreator-os/fb/"
for a in kernel.uimage root.squashfs sysupgrade.tar; do
	install -m 0644 "$VDIR/$PREFIX-$a" "$OUT/$a"
done
install -m 0644 "$REPO/chainload/out/chainload.ko" "$OUT/chainload/"
install -m 0755 "$REPO/chainload/c5-chainload.sh" "$OUT/chainload/"
basename "$(cd "$VDIR" && pwd)" > "$OUT/VERSION"

# Magic checks: what install.sh will insist on anyway.
[ "$(head -c 4 "$OUT/kernel.uimage" | od -An -tx1 | tr -d ' \n')" = 27051956 ] || die "kernel.uimage is not a uImage"
[ "$(head -c 4 "$OUT/root.squashfs")" = hsqs ] || die "root.squashfs is not squashfs"

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name MD5SUMS | sed 's|^\./||' | LC_ALL=C sort) > "$LIST"
(cd "$OUT" && xargs -d '\n' sha256sum < "$LIST" > SHA256SUMS && xargs -d '\n' md5sum < "$LIST" > MD5SUMS)

if [ -n "$KEYS" ]; then
	install -m 0644 "$KEYS" "$OUT/opencreator-os/authorized_keys"
fi
if [ "$FLIP" = 1 ]; then
	echo "switch the boot flag to OpenWrt after a verified install" > "$OUT/opencreator-os/FLIP"
fi
if [ "$CHAIN" = 1 ]; then
	{
		echo "test-boot OpenWrt from RAM after a verified install ($(date -u '+%F %T') UTC)"
		echo "The test runs once per stick; change this file to run it again."
	} > "$OUT/opencreator-os/CHAINLOAD"
fi

echo "Stick payload for $(cat "$OUT/VERSION") in $OUT:"
(cd "$OUT" && find . -type f | sed 's|^\./|  |' | LC_ALL=C sort)
echo
echo "Copy the contents of $OUT to the root of a FAT32 USB stick."
echo "Do not put opencreator-fs's runFirmwareExe.sh on the same stick."
if [ "$FLIP" = 1 ]; then
	echo "FLIP is set: after a verified write the printer reboots into OpenWrt."
elif [ "$CHAIN" = 1 ]; then
	echo "CHAINLOAD is set: after a verified write the printer test-boots OpenWrt from RAM;"
	echo "the boot flag stays on stock. A healthy OpenWrt then points the flag at itself."
else
	echo "No FLIP: the printer writes the spare slot and boots stock again; see docs/install.md."
fi
