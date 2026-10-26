#!/bin/bash
# Build opencreator-os (OpenWrt 24.10 + Ingenic SDK 6.6 kernel) in WSL.
#
#   ./build.sh [--menuconfig] [--kernel-menuconfig] [--clean-kernel]
#
# Env: WORK (default ~/build/opencreator-os)  build trees (regenerable)
#      OUT  (default /mnt/f/creator5-dev/opencreator-os-builds)  artifacts
#      JOBS (default nproc)
#      INGENIC_FTP_PASS  only if the SDK tarball must be downloaded
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/build/opencreator-os}
OUT=${OUT:-/mnt/f/creator5-dev/opencreator-os-builds}
JOBS=${JOBS:-$(nproc)}
OPENWRT_TAG=v24.10.3
OW=$WORK/openwrt

log() { printf '\n=== %s\n' "$*"; }
die() { echo "build: $*" >&2; exit 1; }

MENU= KMENU= KCLEAN=
for a in "$@"; do
	case $a in
	--menuconfig) MENU=1 ;;
	--kernel-menuconfig) KMENU=1 ;;
	--clean-kernel) KCLEAN=1 ;;
	*) die "unknown option $a" ;;
	esac
done

log "prerequisites"
missing=
for p in build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git \
	libncurses-dev libssl-dev python3-setuptools rsync swig unzip zlib1g-dev file wget \
	device-tree-compiler u-boot-tools python3-pil squashfs-tools; do
	dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done
[ -z "$missing" ] || die "missing packages, run: sudo apt install$missing"

if [ ! -d "$OW/.git" ]; then
	log "clone OpenWrt $OPENWRT_TAG"
	mkdir -p "$WORK"
	git clone https://github.com/openwrt/openwrt.git "$OW"
fi
if [ "$(git -C "$OW" describe --tags --exact-match 2>/dev/null)" != "$OPENWRT_TAG" ]; then
	git -C "$OW" fetch --tags
	git -C "$OW" checkout -q "$OPENWRT_TAG"
fi
ln -sfn "$REPO/feed/x2600" "$OW/target/linux/x2600"

if [ ! -d "$OW/feeds/packages" ]; then
	log "feeds"
	(cd "$OW" && ./scripts/feeds update -a && ./scripts/feeds install -a)
fi

log "kernel tree"
KSRC=$("$REPO/kernel/prepare.sh" --work "$WORK" | tail -1)
[ -f "$KSRC/Makefile" ] || die "kernel/prepare.sh did not produce a tree"

VERSION=$(git -C "$REPO" describe --always --dirty --tags)
log "config ($VERSION)"
{
	cat "$REPO/config/openwrt.seed"
	echo "CONFIG_EXTERNAL_KERNEL_TREE=\"$KSRC\""
	echo "CONFIG_VERSION_NUMBER=\"$VERSION\""
} > "$OW/.config"
(cd "$OW" && make defconfig >/dev/null)
grep -q '^CONFIG_TARGET_x2600_generic_DEVICE_flashforge_creator5pro=y' "$OW/.config" || die "target not selected"

[ -n "$MENU" ] && (cd "$OW" && make menuconfig)
[ -n "$KMENU" ] && (cd "$OW" && make kernel_menuconfig)
[ -n "$KCLEAN" ] && (cd "$OW" && make target/linux/clean)

log "build (-j$JOBS)"
if ! (cd "$OW" && make -j"$JOBS" download world); then
	log "build failed; rerunning single-threaded for the error"
	(cd "$OW" && make -j1 V=s world 2>&1 | tail -80)
	exit 1
fi

BIN=$OW/bin/targets/x2600/generic
DEST=$OUT/$VERSION
log "artifacts -> $DEST"
mkdir -p "$DEST"
cp "$BIN"/openwrt-*flashforge_creator5pro-* "$BIN"/sha256sums "$DEST/"
cp "$OW/build_dir/target-"*/linux-x2600_generic/linux-*/.config "$DEST/kernel.config" 2>/dev/null || true
ls -l "$DEST"
