#!/bin/bash
# Build opencreator-os (OpenWrt 24.10 + Ingenic SDK 6.6 kernel) on Linux.
#
#   ./build.sh [--menuconfig] [--kernel-menuconfig] [--clean-kernel]
#
# Env: WORK (default ~/build/opencreator-os)  build trees (regenerable)
#      OUT  (default /mnt/f/creator5-dev/opencreator-os-builds; set it)  artifacts
#      JOBS (default nproc)
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/build/opencreator-os}
OUT=${OUT:-/mnt/f/creator5-dev/opencreator-os-builds}
JOBS=${JOBS:-$(nproc)}
OPENWRT_TAG=v24.10.8
SF_LIBC_URL=https://downloads.openwrt.org/releases/24.10.8/targets/bcm47xx/legacy/packages/libc_1.2.5-r4_mipsel_mips32.ipk
SF_LIBC_SHA256=deae570efba1fa287005320325d1878db32c935213b613a9b46324069975dc2e
OW=$WORK/openwrt

log() { printf '\n=== %s\n' "$*"; }
die() { echo "build: $*" >&2; exit 1; }

# WSL appends Windows directories (/mnt/c/..., with spaces) to PATH; OpenWrt's
# image step runs find -execdir, which refuses relative or odd PATH entries.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '^/mnt/' -e '^$' -e '^[^/]' | paste -sd:)
export PATH

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

# wifi-scripts installs source files directly (its Build/Prepare is empty),
# so apply these small source patches rather than package patch overlays.
log "OpenWrt source patches"
for p in "$REPO"/patches/openwrt/*.patch; do
	[ -e "$p" ] || continue
	if patch -d "$OW" -p1 -R --dry-run -s -f --fuzz=0 < "$p" >/dev/null 2>&1; then
		log "already applied: $(basename "$p")"
	else
		patch -d "$OW" -p1 -N -s --fuzz=0 < "$p" || die "patch failed: $(basename "$p")"
		log "applied: $(basename "$p")"
	fi
done

# Copy (not symlink) the target: the repo usually sits on a Windows drive
# where every file looks 0777, so take file modes from the git index.
log "sync target/linux/x2600"
rm -rf "$OW/target/linux/x2600"
mkdir -p "$OW/target/linux/x2600"
(cd "$REPO/feed/x2600" && tar -cf - .) | tar -xf - -C "$OW/target/linux/x2600" --no-same-permissions
find "$OW/target/linux/x2600" -type d -exec chmod 0755 {} + -o -type f -exec chmod 0644 {} +
git -C "$REPO" ls-files -s feed/x2600 | awk '$1 == "100755" { sub(/^feed\/x2600\//, "", $4); print $4 }' |
	while IFS= read -r f; do [ ! -e "$OW/target/linux/x2600/$f" ] || chmod 0755 "$OW/target/linux/x2600/$f"; done

# The soft-float area: opkg-sf installs upstream's mipsel_mips32 packages under
# /data/sf, apart from the image (docs/image.md). Only the loader, whose path is
# fixed in those binaries, sits in /lib.
log "soft-float area"
SF_IPK=$WORK/libc-sf-$SF_LIBC_SHA256.ipk
if [ ! -s "$SF_IPK" ]; then
	wget -q -O "$SF_IPK.part" "$SF_LIBC_URL" || die "cannot download $SF_LIBC_URL"
	[ "$(sha256sum < "$SF_IPK.part" | cut -d' ' -f1)" = "$SF_LIBC_SHA256" ] || die "soft-float libc checksum mismatch"
	mv -f "$SF_IPK.part" "$SF_IPK"
fi
mkdir -p "$OW/files/lib" "$OW/files/etc/profile.d" "$OW/files/usr/sbin"
tar -xzOf "$SF_IPK" ./data.tar.gz | tar -xzOf - ./lib/libc.so > "$OW/files/lib/ld-musl-mipsel-sf.so.1"
chmod 0755 "$OW/files/lib/ld-musl-mipsel-sf.so.1"
echo /data/sf/lib:/data/sf/usr/lib > "$OW/files/etc/ld-musl-mipsel-sf.path"
SF_URL=https://downloads.openwrt.org/releases/${OPENWRT_TAG#v}
cat > "$OW/files/etc/opkg-sf.conf" <<EOF
dest root /
lists_dir ext /var/opkg-lists-sf
option check_signature
arch all 100
arch mipsel_mips32 200
src/gz sf_core $SF_URL/targets/bcm47xx/legacy/packages
src/gz sf_base $SF_URL/packages/mipsel_mips32/base
src/gz sf_packages $SF_URL/packages/mipsel_mips32/packages
src/gz sf_luci $SF_URL/packages/mipsel_mips32/luci
src/gz sf_routing $SF_URL/packages/mipsel_mips32/routing
src/gz sf_telephony $SF_URL/packages/mipsel_mips32/telephony
EOF
cat > "$OW/files/usr/sbin/opkg-sf" <<EOF
#!/bin/sh
grep -q ' /data ' /proc/mounts || { echo "opkg-sf: /data is not mounted" >&2; exit 1; }
mkdir -p /data/sf/var/lock /data/sf/etc/opkg
[ -e /data/sf/etc/opkg/keys ] || ln -s /etc/opkg/keys /data/sf/etc/opkg/keys
sf() { opkg -f /etc/opkg-sf.conf -o /data/sf "\$@"; }
# upstream's index leaves libc out, as every image already has it
if [ "\$1" = install ] && [ ! -e /data/sf/lib/libc.so ]; then
	curl -fsSL -o /tmp/sf-libc.ipk "$SF_LIBC_URL" || exit 1
	[ "\$(sha256sum < /tmp/sf-libc.ipk | cut -d' ' -f1)" = "$SF_LIBC_SHA256" ] || { echo "opkg-sf: libc checksum mismatch" >&2; exit 1; }
	sf install /tmp/sf-libc.ipk || exit 1
	rm -f /tmp/sf-libc.ipk
fi
sf "\$@"
EOF
chmod 0755 "$OW/files/usr/sbin/opkg-sf"
cat > "$OW/files/etc/profile.d/sf.sh" <<'EOF'
export PATH="$PATH:/data/sf/usr/sbin:/data/sf/usr/bin:/data/sf/sbin:/data/sf/bin"
export TERMINFO_DIRS=/data/sf/usr/share/terminfo:/usr/share/terminfo
EOF

# feeds.conf.default pins each feed to a commit of the release: update the
# feeds whenever the checked-out tag changes.
if [ ! -d "$OW/feeds/packages" ] || [ "$(cat "$OW/.c5-feeds-tag" 2>/dev/null)" != "$OPENWRT_TAG" ]; then
	log "feeds ($OPENWRT_TAG)"
	(cd "$OW" && ./scripts/feeds update -a && ./scripts/feeds install -a)
	echo "$OPENWRT_TAG" > "$OW/.c5-feeds-tag"
fi

log "kernel tree"
KSRC=$("$REPO/kernel/prepare.sh" --work "$WORK" | tail -1)
[ -f "$KSRC/Makefile" ] || die "kernel/prepare.sh did not produce a tree"
# OpenWrt copies .config.set to .config only when .config.set differs from
# .config.prev. A kernel patch that adds a Kconfig symbol leaves .config.set
# unchanged while kbuild has already dropped the then-unknown symbol from
# .config, so force the copy every build.
rm -f "$KSRC/.config.prev"

VERSION=$(git -C "$REPO" describe --always --dirty --tags)
log "config ($VERSION)"
{
	cat "$REPO/config/openwrt.seed"
	echo "CONFIG_EXTERNAL_KERNEL_TREE=\"$KSRC\""
	echo "CONFIG_VERSION_NUMBER=\"$VERSION\""
} > "$OW/.c5-config.seed"
# Hash inputs, not mtimes: the target is copied afresh on every invocation.
# Feed revisions/diffs and generated indexes avoid scanning entire feed trees.
CONFIG_KEY=$(
	set -e
	cd "$OW"
	{
		printf '%s\n' "$OPENWRT_TAG"
		sha256sum .c5-config.seed .c5-feeds-tag
		for f in feeds.conf feeds.conf.default feeds/*.index feeds/*.targetindex; do
			[ ! -f "$f" ] || sha256sum "$f"
		done
		for f in feeds/*; do
			[ -e "$f/.git" ] || continue
			printf '%s\n' "$f"
			git -C "$f" rev-parse HEAD
			git -C "$f" diff --binary HEAD --
			(cd "$f" && git ls-files --others --exclude-standard -z |
				xargs -0 -r sha256sum)
		done
		if [ -d package/feeds ]; then
			find package/feeds -type l -printf '%p %l\0' | LC_ALL=C sort -z
		fi
		tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
			-cf - target/linux/x2600
	} | sha256sum | cut -d' ' -f1
)
CONFIG_HASH=
[ ! -f "$OW/.config" ] || CONFIG_HASH=$(sha256sum < "$OW/.config")
CONFIG_STAMP=$OW/.c5-defconfig
# Interactive config always starts from the seed. Detect later .config edits
# too, preserving the seed-authoritative behavior on the following build.
if [ -n "$MENU$KMENU" ] || [ ! -f "$OW/.config" ] ||
	[ "$(cat "$CONFIG_STAMP" 2>/dev/null)" != "$CONFIG_KEY $CONFIG_HASH" ]; then
	rm -f "$CONFIG_STAMP"
	cp "$OW/.c5-config.seed" "$OW/.config"
	(cd "$OW" && make defconfig >/dev/null)
else
	log "config unchanged; reusing .config"
fi
grep -q '^CONFIG_TARGET_x2600_generic_DEVICE_flashforge_creator5pro=y' "$OW/.config" || die "target not selected"
printf '%s %s\n' "$CONFIG_KEY" "$(sha256sum < "$OW/.config")" > "$CONFIG_STAMP"

[ -n "$MENU" ] && (cd "$OW" && make menuconfig)
[ -n "$KMENU" ] && (cd "$OW" && make kernel_menuconfig)
[ -n "$KCLEAN" ] && (cd "$OW" && make target/linux/clean)

log "build (-j$JOBS)"
if ! (cd "$OW" && make -j"$JOBS" world); then
	log "build failed; rerunning single-threaded for the error"
	(cd "$OW" && make -j1 V=s world 2>&1 | tail -80)
	exit 1
fi

BIN=$OW/bin/targets/x2600/generic
DEST=$OUT/$VERSION
log "artifacts -> $DEST"
mkdir -p "$DEST"
cp "$BIN"/opencreator-os-x2600-generic-flashforge_creator5pro-* "$BIN"/sha256sums "$DEST/"
cp "$OW/build_dir/target-"*/linux-x2600_generic/linux-*/.config "$DEST/kernel.config" 2>/dev/null || true
ls -l "$DEST"
