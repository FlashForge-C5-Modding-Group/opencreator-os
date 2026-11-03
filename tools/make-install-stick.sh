#!/usr/bin/env bash
# Assemble the opencreator-os USB-stick payload from a build directory.
#
#   tools/make-install-stick.sh [--authorized-keys FILE] [--app FILE] [--stack DIR] VERSION_DIR OUTDIR
#
# VERSION_DIR  build output, e.g. /mnt/f/creator5-dev/opencreator-os-builds/<ver>,
#              holding opencreator-os-x2600-generic-flashforge_creator5pro-*
# OUTDIR       new or empty directory; its contents go to the stick root
# --authorized-keys FILE  ship FILE as the SSH keys for OpenWrt's root
# --app FILE   ship the os-installer touchscreen app (os-installer/build/mips32/os-installer);
#              without it the stick runs headless
# --stack DIR  ship the printer stack: DIR holds stack.tar.gz, fluidd.tar.gz and
#              mainsail.tar.gz (tools/make-stack.sh); without it the stick
#              installs OpenWrt only
#
# chainload.ko comes from chainload/out/ of this repo (chainload/build.sh),
# sfdisk and partx from installer/tools/out/ (installer/tools/build.sh).
# ACTION, WEBUI, wifi.conf and authorized_keys (in opencreator-os/) are left
# out of the checksum lists so they can be added or edited on the stick later.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=opencreator-os-x2600-generic-flashforge_creator5pro-squashfs
KEYS='' APP='' STACK=''

usage() { sed -n '2,19s/^# \{0,1\}//p' "$0"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--authorized-keys)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		KEYS=$2
		shift
		;;
	--app)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		APP=$2
		shift
		;;
	--stack)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		STACK=$2
		shift
		;;
	-h | --help) usage; exit 0 ;;
	-*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
	*) break ;;
	esac
	shift
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
VDIR=$1 OUT=$2

die() { echo "make-install-stick: $*" >&2; exit 1; }

[ -d "$VDIR" ] || die "$VDIR is not a directory"
for a in kernel.uimage root.squashfs sysupgrade.tar; do
	[ -s "$VDIR/$PREFIX-$a" ] || die "missing $VDIR/$PREFIX-$a"
done
for f in installer/runFirmwareExe.sh installer/opencreator-os/install.sh installer/opencreator-os/lib.sh \
	installer/opencreator-os/restore.sh feed/x2600/base-files/lib/c5/slot.sh \
	chainload/out/chainload.ko chainload/c5-chainload.sh \
	installer/tools/out/sfdisk installer/tools/out/partx; do
	[ -s "$REPO/$f" ] || die "missing $REPO/$f"
done
[ -z "$KEYS" ] || [ -s "$KEYS" ] || die "authorized keys file $KEYS is empty or missing"
[ -z "$APP" ] || [ -s "$APP" ] || die "app $APP is empty or missing"
if [ -n "$STACK" ]; then
	for a in stack.tar.gz fluidd.tar.gz mainsail.tar.gz; do
		[ -s "$STACK/$a" ] || die "stack archive $STACK/$a is empty or missing"
	done
else
	echo "make-install-stick: no --stack: the stick installs OpenWrt without the printer software (tools/make-stack.sh)" >&2
fi
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
	die "$OUT exists and is not empty"
fi

# Payload checks (install.sh insists on the same) before anything is copied.
KIMG=$VDIR/$PREFIX-kernel.uimage
[ "$(head -c 4 "$KIMG" | od -An -tx1 | tr -d ' \n')" = 27051956 ] || die "kernel.uimage is not a uImage"
[ "$(head -c 4 "$VDIR/$PREFIX-root.squashfs")" = hsqs ] || die "root.squashfs is not squashfs"

# chainload.ko skips the 64-byte uImage header and refuses a payload whose
# page-rounded size exceeds SAFE_MIN - LOAD_PHYS (chainload/chainload_main.c).
cl_const() {
	awk -v n="$1" '$1 == "#define" && $2 == n { v = $3; sub(/[uUlL]+$/, "", v); print v; exit }' "$REPO/chainload/chainload_main.c"
}
LOAD_PHYS=$(cl_const LOAD_PHYS) SAFE_MIN=$(cl_const SAFE_MIN)
[[ "$LOAD_PHYS" =~ ^0x[0-9a-fA-F]+$ && "$SAFE_MIN" =~ ^0x[0-9a-fA-F]+$ ]] ||
	die "cannot read LOAD_PHYS/SAFE_MIN from chainload/chainload_main.c"
CL_LIMIT=$((SAFE_MIN - LOAD_PHYS))
KSZ=$(stat -c %s "$KIMG")
KPAY=$(((KSZ - 64 + 4095) / 4096 * 4096))
if [ "$KSZ" -le 64 ] || [ "$KPAY" -gt "$CL_LIMIT" ]; then
	die "kernel.uimage payload $((KSZ - 64)) bytes ($KPAY page-rounded) exceeds the chainload limit $CL_LIMIT (SAFE_MIN $SAFE_MIN - LOAD_PHYS $LOAD_PHYS)"
fi
echo "kernel.uimage payload $KPAY of $CL_LIMIT bytes (chainload limit)"

mkdir -p "$OUT/opencreator-os/bin" "$OUT/chainload"
install -m 0755 "$REPO/installer/runFirmwareExe.sh" "$OUT/"
install -m 0755 "$REPO/installer/opencreator-os/install.sh" "$OUT/opencreator-os/"
install -m 0644 "$REPO/installer/opencreator-os/lib.sh" "$REPO/installer/opencreator-os/restore.sh" \
	"$REPO/feed/x2600/base-files/lib/c5/slot.sh" "$OUT/opencreator-os/"
install -m 0755 "$REPO/installer/tools/out/sfdisk" "$REPO/installer/tools/out/partx" "$OUT/opencreator-os/bin/"
[ -z "$APP" ] || install -m 0755 "$APP" "$OUT/opencreator-os/os-installer"
for a in kernel.uimage root.squashfs sysupgrade.tar; do
	install -m 0644 "$VDIR/$PREFIX-$a" "$OUT/$a"
done
if [ -n "$STACK" ]; then
	mkdir -p "$OUT/stack"
	install -m 0644 "$STACK/stack.tar.gz" "$STACK/fluidd.tar.gz" "$STACK/mainsail.tar.gz" "$OUT/stack/"
fi
install -m 0644 "$REPO/chainload/out/chainload.ko" "$OUT/chainload/"
install -m 0755 "$REPO/chainload/c5-chainload.sh" "$OUT/chainload/"
basename "$(cd "$VDIR" && pwd)" > "$OUT/VERSION"

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name MD5SUMS | sed 's|^\./||' | LC_ALL=C sort) > "$LIST"
(cd "$OUT" && xargs -d '\n' sha256sum < "$LIST" > SHA256SUMS && xargs -d '\n' md5sum < "$LIST" > MD5SUMS)

if [ -n "$KEYS" ]; then
	install -m 0644 "$KEYS" "$OUT/opencreator-os/authorized_keys"
fi

echo "Stick payload for $(cat "$OUT/VERSION") in $OUT:"
(cd "$OUT" && find . -type f | sed 's|^\./|  |' | LC_ALL=C sort)
echo
echo "Copy the contents of $OUT to the root of a FAT32 USB stick."
echo "Do not put opencreator-fs's runFirmwareExe.sh on the same stick."
echo "Install writes the spare slot, then boots OpenWrt: directly when its kernel is"
echo "known-good, else as a RAM test boot that a healthy OpenWrt commits; see docs/install.md."
