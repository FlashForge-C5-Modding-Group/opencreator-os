#!/usr/bin/env bash
# Run the os-installer touchscreen app (SDL build) on the PC against the real
# stock-side installer and a loop-mounted eMMC image with the printer's GPT.
# WSL + WSLg; needs sudo (loop device, mounts; the app runs the installer
# through "sudo -n").
#
#   tools/ui-demo.sh [--fresh] [--chainload] APP VERSION_DIR
#
# APP          os-installer/build/sdl/os-installer
# VERSION_DIR  OpenWrt build output (as for tools/make-install-stick.sh)
# --fresh      start again from a stock-layout eMMC image and an empty stick
# --chainload  install stick with CHAINLOAD (the jump is simulated)
#
# State in DEMO (default ~/build/opencreator-os/demo): disk.img (15,307,776
# sectors, sparse), stick/ (the stick root, keeps emmc-backup/ between runs),
# app.log. A whole-eMMC backup writes about 7.3 GB to stick/.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FRESH=0 STICKOPTS=()
usage() { sed -n '2,19s/^# \{0,1\}//p' "$0"; }
while [ $# -gt 0 ]; do
	case "$1" in
	--fresh) FRESH=1 ;;
	--chainload) STICKOPTS+=(--chainload) ;;
	-h | --help) usage; exit 0 ;;
	-*) echo "ui-demo: unknown option $1" >&2; exit 2 ;;
	*) break ;;
	esac
	shift
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
APP=$(realpath "$1") VDIR=$(realpath "$2")
[ -x "$APP" ] || { echo "ui-demo: $APP is not executable" >&2; exit 1; }

# shellcheck source=../test/qemu/lib/harness.sh
. "$REPO/test/qemu/lib/harness.sh"
DEMO=${DEMO:-$HOME/build/opencreator-os/demo}
mkdir -p "$DEMO"
sudo -v

build_stock_fixture
if [ "$FRESH" = 1 ] || [ ! -s "$DEMO/disk.img" ]; then
	echo "demo: building the eMMC image (printer geometry)"
	sudo rm -rf "$DEMO/stick"
	make_emmc_image "$DEMO/disk.img.tmp" 15307776 15065087 14479359
	mv "$DEMO/disk.img.tmp" "$DEMO/disk.img"
fi

# stick: a fresh payload over the kept stick directory (emmc-backup stays)
rm -rf "$DEMO/payload"
"$REPO/tools/make-install-stick.sh" "${STICKOPTS[@]}" "$VDIR" "$DEMO/payload" > "$DEMO/make-install-stick.log"
install -m 0755 "$REPO/tools/demo/c5-chainload.sh" "$DEMO/payload/chainload/c5-chainload.sh"
resum "$DEMO/payload"
sudo mkdir -p "$DEMO/stick"
sudo cp -a "$DEMO/payload/." "$DEMO/stick/"

printf 'console=ttyS0 root=%s rootfstype=squashfs ro\n' "PLACEHOLDER" > "$DEMO/cmdline"
cp "$FIX/usershare-stage/wifi/wpa_supplicant.conf" "$DEMO/wpa_supplicant.conf"
printf '#!/bin/sh\necho "demo: reboot requested"\n' > "$DEMO/fake-reboot.sh"
chmod 0755 "$DEMO/fake-reboot.sh"

LOOP=$(sudo losetup -fP --show "$DEMO/disk.img")
cleanup() {
	mountpoint -q "$DEMO/data" && sudo umount "$DEMO/data"
	sudo losetup -d "$LOOP"
}
trap cleanup EXIT
sed -i "s|PLACEHOLDER|${LOOP}p4|" "$DEMO/cmdline"
mkdir -p "$DEMO/data"
sudo mount -t ext4 -o sync "${LOOP}p7" "$DEMO/data"
echo "demo: eMMC image on $LOOP, userdata on $DEMO/data"

rc=0
"$APP" --log "$DEMO/app.log" -- sudo -n env C5_DISK="$LOOP" C5_FDISK="$REPO/tools/demo/fdisk-compat.sh" \
	C5_SFDISK="$(command -v sfdisk)" C5_PARTX="$(command -v partx)" C5_DATA="$DEMO/data" C5_CMDLINE="$DEMO/cmdline" C5_UNAME_R=5.10.186+ \
	C5_WPA="$DEMO/wpa_supplicant.conf" C5_REBOOT="$DEMO/fake-reboot.sh" C5_DROP_CACHES=/dev/null \
	sh "$DEMO/stick/opencreator-os/install.sh" --from-stick "$DEMO/stick" --hook --ui Creator5Pro 0029 || rc=$?
echo "demo: app exited with $rc; log in $DEMO/app.log"
[ -d "$DEMO/stick/emmc-backup" ] && echo "demo: backup in $DEMO/stick/emmc-backup"
sudo sgdisk -p "$LOOP" | sed -n '/^Number/,$p'
exit "$rc"
