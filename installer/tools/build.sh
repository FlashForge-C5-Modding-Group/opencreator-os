#!/bin/bash
# Build static util-linux sfdisk and partx for the stock Creator 5 Pro
# userland (MIPS32r2 o32, NaN2008). The installer uses sfdisk to rewrite the
# GPT, and partx to find partitions by GPT name (slot.sh) and to tell the
# kernel about the changed partitions (BLKPG; sfdisk
# only tries BLKRRPART, which fails while the disk is in use). Stock has only
# busybox fdisk.
#
#   installer/tools/build.sh
#
# Environment (defaults in brackets):
#   TC     mips-xburst2-linux-toolchain-r6.0.0              [~/ing/mips-xburst2-linux-toolchain-r6.0.0]
#   WORK   download and build directory                    [~/build/opencreator-os/sticktools]
#
# Output: installer/tools/out/sfdisk, installer/tools/out/partx
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
TC=${TC:-$HOME/ing/mips-xburst2-linux-toolchain-r6.0.0}
WORK=${WORK:-$HOME/build/opencreator-os/sticktools}
UL_VER=2.40.2
UL_TAR=util-linux-$UL_VER.tar.xz
UL_URL=https://www.kernel.org/pub/linux/utils/util-linux/v${UL_VER%.*}/$UL_TAR
# From kernel.org's v2.40/sha256sums.asc (good signature by the kernel.org
# checksum autosigner, key B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1)
UL_SHA256=d78b37a66f5922d70edf3bdfb01a6b33d34ed3c3cafd6628203b2a2b67c8e8b3

die() { echo "build: $*" >&2; exit 1; }

CROSS=$TC/bin/mips-xburst2-linux-gnu-
[ -x "${CROSS}gcc" ] || die "no mips-xburst2-linux-gnu-gcc in $TC/bin"
for t in curl tar xz make; do
	command -v "$t" >/dev/null || die "$t missing"
done

mkdir -p "$WORK"
if ! echo "$UL_SHA256  $WORK/$UL_TAR" | sha256sum -c --status 2>/dev/null; then
	curl -fL -o "$WORK/$UL_TAR.part" "$UL_URL"
	echo "$UL_SHA256  $WORK/$UL_TAR.part" | sha256sum -c --status ||
		die "$UL_TAR: sha256 mismatch"
	mv "$WORK/$UL_TAR.part" "$WORK/$UL_TAR"
fi

# Fresh source tree in $WORK/$1 (one per tool: the two configurations differ).
extract() {
	rm -rf "${WORK:?}/$1"
	mkdir -p "$WORK/$1"
	tar -xJf "$WORK/$UL_TAR" -C "$WORK/$1" --strip-components=1
	cd "$WORK/$1"
}

# --disable-year2038: the toolchain's glibc has only a 32-bit time_t (as
# stock). PKG_CONFIG_LIBDIR keeps the host's .pc files out of the build.
COMMON=(--host=mips-xburst2-linux-gnu --prefix=/usr --disable-all-programs
	--disable-shared --disable-nls --disable-bash-completion --disable-makeinstall-chown
	--disable-year2038 --without-python --without-ncurses --without-ncursesw --without-tinfo
	--without-readline --without-systemd --without-udev --without-cap-ng
	CC="${CROSS}gcc" CFLAGS="-O2 -mnan=2008" LDFLAGS="-static" PKG_CONFIG_LIBDIR="$WORK/no-pkgconfig")

# Strip $1 into $OUT/$2 and check it is a static NaN2008 o32 MIPS32r2 binary.
install_tool() {
	mkdir -p "$OUT"
	cp "$1" "$OUT/$2"
	"${CROSS}strip" "$OUT/$2"
	file "$OUT/$2" | grep -q 'statically linked' || die "$OUT/$2 is not statically linked"
	# readelf (2.39 and 2.42) prints no NaN line for -A; EF_MIPS_NAN2008 is in -h
	local flags f
	flags=$("${CROSS}readelf" -h "$OUT/$2" | sed -n 's/^ *Flags: *//p')
	for f in nan2008 o32 mips32r2; do
		case ", $flags," in *", $f,"*) ;; *) die "$OUT/$2: ELF flags '$flags' lack $f" ;; esac
	done
}

# sfdisk, without libblkid (no signature probing).
# --enable-fdisks=check: 2.40 has no --enable-sfdisk, and a plain
# --enable-fdisks also forces cfdisk, which needs ncurses; "check" builds
# whatever has its requirements (the grep below makes sure sfdisk does).
extract sfdisk
./configure "${COMMON[@]}" --enable-fdisks=check --enable-libfdisk --enable-libsmartcols \
	--enable-libuuid --enable-static-programs=sfdisk
grep -q '^sfdisk_static_SOURCES' Makefile || die "configure did not enable sfdisk.static (see $PWD/config.log)"
make -j"$(nproc)" sfdisk.static
install_tool sfdisk.static sfdisk

# partx (needs libblkid). It is not in --enable-static-programs, so libtool
# gets -all-static to link libc statically too.
extract partx
./configure "${COMMON[@]}" --enable-partx --enable-libblkid --enable-libsmartcols
grep -q '^partx_SOURCES' Makefile || die "configure did not enable partx (see $PWD/config.log)"
make -j"$(nproc)" partx LDFLAGS=-all-static
install_tool partx partx

(cd "$OUT" && sha256sum sfdisk partx)
