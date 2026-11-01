#!/bin/bash
# Prepare the stock-compatible 5.10.186+ kernel build used by chainload.ko.
# Optional KSRC/KOUT/TC override the defaults under ~/ing; JOBS defaults to nproc.
# INGENIC_510_SDK_TARBALL overrides the shared download cache for source setup.
# Prints the absolute prepared KOUT on stdout; all other output goes to stderr.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../tools/ingenic-download.sh"
log() { echo "chainload prepare: $*" >&2; }
die() { log "$*"; exit 1; }

if [ "${KSRC+x}" = x ]; then
	if [ -z "$KSRC" ] || [ ! -f "$KSRC/Makefile" ]; then
		die "explicit KSRC has no kernel Makefile: $KSRC"
	fi
else
	KSRC=$HOME/ing/kernel-5.10
	[ "${INGENIC_510_SDK_TARBALL+x}" != x ] || [ -f "$INGENIC_510_SDK_TARBALL" ] ||
		die "SDK archive not found: $INGENIC_510_SDK_TARBALL"
fi
KOUT=${KOUT:-$HOME/ing/out}
TC=$("$HERE/../tools/prepare-toolchain.sh")
JOBS=${JOBS:-$(nproc)}

if [ ! -f "$KSRC/Makefile" ]; then
	if [ -e "$KSRC" ] || [ -L "$KSRC" ]; then
		die "refusing to replace incomplete source tree: $KSRC"
	fi
	TARBALL=ingenic-linux-kernel4.4.94-kernel5.10-x2600-v2.0-20230906.tar.bz2
	SDK_ROOT=${TARBALL%.tar.bz2}
	URL=ftp://ftp.ingenic.com.cn/DevSupport/X2600E/01_SW/03_kernel4.4.94_kernel5.10_x2600-sdk_v2.0-20230906/00_ingenic-linux-kernel4.4.94-kernel5.10-x2600-v2.0-20230906/$TARBALL
	ARCHIVE=$(ingenic_archive INGENIC_510_SDK_TARBALL \
		"${INGENIC_DOWNLOAD_DIR:-${WORK:-$HOME/build/opencreator-os}/downloads}" \
		"$TARBALL" md5sum 7c040a22c6a1978385d3f644d9d9a7b7 "$URL")
	mkdir -p "$(dirname "$KSRC")"
	STAGE=$(mktemp -d "$(dirname "$KSRC")/.kernel-5.10.XXXXXX")
	trap 'rm -rf "$STAGE"' EXIT
	log "unpacking kernel/kernel-5.10 to $KSRC"
	tar -xjf "$ARCHIVE" -C "$STAGE" --strip-components=3 \
		--exclude='*/.git' "$SDK_ROOT/kernel/kernel-5.10" >&2
	[ -f "$STAGE/Makefile" ] || die "kernel/kernel-5.10 not found in $ARCHIVE"
	mv "$STAGE" "$KSRC"
	trap - EXIT
fi
KSRC=$(cd "$KSRC" && pwd)
version=$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{print v"."p"."s}' "$KSRC/Makefile")
[ "$version" = 5.10.186 ] || die "$KSRC is Linux $version, expected 5.10.186"
mkdir -p "$KOUT"
KOUT=$(cd "$KOUT" && pwd)
[ "$KSRC" != "$KOUT" ] || die "KOUT must be separate from KSRC"
CROSS_COMPILE=$TC/bin/mips-xburst2-linux-gnu-

config_matches() {
	[ -f "$KOUT/.config" ] || return 1
	local option
	for option in HIGHMEM DEBUG_SPINLOCK MODULES SMP PREEMPT MODULE_UNLOAD CPU_MIPS32_R5 32BIT; do
		grep -Fxq "CONFIG_$option=y" "$KOUT/.config" || return 1
	done
	grep -Fxq 'CONFIG_LOCALVERSION="+"' "$KOUT/.config" || return 1
	for option in LOCALVERSION_AUTO MODVERSIONS; do
		grep -Eq "^(# CONFIG_$option is not set|CONFIG_$option=n)$" "$KOUT/.config" || return 1
	done
}
build_ready() {
	config_matches || return 1
	local file
	for file in vmlinux Module.symvers include/config/kernel.release scripts/mod/modpost; do
		[ -s "$KOUT/$file" ] || return 1
	done
	[ "$(cat "$KOUT/include/config/kernel.release")" = 5.10.186+ ]
}

if build_ready; then
	log "reusing configured build at $KOUT"
else
	if ! config_matches; then
		log "configuring stock-compatible x2600_module_base_linux_mmc0_defconfig"
		make -C "$KSRC" O="$KOUT" ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" \
			x2600_module_base_linux_mmc0_defconfig >&2
		"$KSRC/scripts/config" --file "$KOUT/.config" \
			-e HIGHMEM --set-str LOCALVERSION + -d LOCALVERSION_AUTO \
			-e DEBUG_SPINLOCK -e MODULES -d MODVERSIONS >&2
		make -C "$KSRC" O="$KOUT" ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" olddefconfig >&2
		config_matches || die "kernel configuration does not match the stock ABI requirements"
	fi
	log "building vmlinux and modules with $JOBS jobs"
	make -C "$KSRC" O="$KOUT" ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" \
		-j"$JOBS" vmlinux modules >&2
	build_ready || die "kernel build did not produce the required 5.10.186+ module prerequisites"
fi
printf '%s\n' "$KOUT"
