# shellcheck shell=bash disable=SC2034  # variables are used by the sourcing scripts
# Shared settings for the QEMU system tests. Sourced by test/qemu/*.sh.
#
# Overridable from the environment:
#   QWORK          work directory for fixtures and runs (outside the repo)
#   OWRT_BIN       directory with the OpenWrt build artifacts
#   STOCK_ARCHIVE  git checkout of creator-5-pro-firmware-archive (stock rootfs)
#   STOCK_ROOTFS_PATH  path of the extracted stock 2.0.0 rootfs inside it
#   KVER           mainline Linux version for the QEMU kernel
#   QEMU_CPU       QEMU CPU model (must run stock NaN2008 glibc and OpenWrt musl)
#   CROSS_COMPILE  toolchain prefix for the QEMU kernel

QREPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
QDIR=$QREPO/test/qemu
QWORK=${QWORK:-$HOME/build/opencreator-os/qemu}
OWRT_DIR=${OWRT_DIR:-$HOME/build/opencreator-os/openwrt}
OWRT_BUILDS=${OWRT_BUILDS:-/mnt/f/creator5-dev/opencreator-os-builds}
# Artifacts are <prefix>-{kernel.uimage,root.squashfs,sysupgrade.tar}; the
# prefix depends on CONFIG_VERSION_DIST / CONFIG_VERSION_FILENAMES, so it is
# found by the device suffix. Default directory: the newest build copied to
# F: by ./build.sh, else the OpenWrt tree's bin directory.
OWRT_SUFFIX=x2600-generic-flashforge_creator5pro
owrt_prefix_in() { # DIR -> path prefix of the newest *-$OWRT_SUFFIX-root.squashfs
	local f
	f=$(ls -1t "$1"/*"$OWRT_SUFFIX"*-root.squashfs 2>/dev/null | head -n 1)
	[ -n "$f" ] && echo "${f%-root.squashfs}"
}
if [ -z "${OWRT_BIN:-}" ]; then
	OWRT_BIN=$(ls -1dt "$OWRT_BUILDS"/*/ 2>/dev/null | while read -r d; do
		owrt_prefix_in "${d%/}" >/dev/null && { echo "${d%/}"; break; }
	done)
	[ -n "$OWRT_BIN" ] || OWRT_BIN=$OWRT_DIR/bin/targets/x2600/generic
fi
OWRT_ART=$(owrt_prefix_in "$OWRT_BIN") || OWRT_ART=$OWRT_BIN/openwrt-$OWRT_SUFFIX
STOCK_ARCHIVE=${STOCK_ARCHIVE:-/mnt/f/creator5-dev/creator-5-pro-firmware-archive}
STOCK_ROOTFS_PATH=${STOCK_ROOTFS_PATH:-kernel/ota_kernel_emmc/ota_v1/rootfs_extracted}
KVER=${KVER:-6.6.58}
KSHA256=${KSHA256:-e7df81e588d70fab5ec3ec3bb04ac53d51f0860fc3b1ec45e0a4167a026899db}
# 24Kf: MIPS32r2 + 64-bit FPU (FR switchable). The stock userland is
# NaN2008/FP64 and OpenWrt's is legacy-NaN; with ieee754=relaxed (passed on
# every boot, built into the product kernel) the kernel runs both. P5600 (the
# NaN2008 model) reads corrupt data from every block device under this
# kernel (squashfs "decompression failed", even uncompressed images fault).
QEMU_CPU=${QEMU_CPU:-24Kf}
QEMU_MEM=${QEMU_MEM:-256}
# The product kernel's built-in command-line prefix (CONFIG_CMDLINE in
# kernel/creator5pro.config, put in front of the SPL's argv); the QEMU
# kernel has none, so the harness passes it.
X2600_CMDLINE=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$QREPO/kernel/creator5pro.config")
VMLINUX=$QWORK/vmlinux-$KVER-$(cat "$QDIR/kernel/malta.config" "$QDIR/kernel/build.sh" | sha256sum | cut -c1-8)

# Printer GPT (sectors), see docs/printer-facts.md. p1-p6 are exact; p7
# (userdata) is cut to what is left of the 2 GiB emulated card (QEMU's
# sd-card needs a power-of-two size). As on the printer, the stock-layout
# image's primary header claims last usable LBA = alternate LBA =
# GPT_QUIRK_LAST, far below the disk end, and there is no backup GPT.
DISK_SECTORS=$((2 * 1024 * 1024 * 2))
GPT_QUIRK_LAST=3952639
# c5os size the stock-side installer uses in the tests (C5_C5OS_MIB)
QEMU_C5OS_MIB=384
# Partition layout after the installer's repartition: p7 shrunk, p8 = c5os
# ending at GPT_QUIRK_LAST, 1 MiB aligned (the backend's formula).
declare -A PSTART=([1]=2048 [2]=18432 [3]=223232 [4]=239616 [5]=444416 [6]=446464 [7]=2543616 [8]=3166208)
declare -A PSIZE=([1]=16384 [2]=204800 [3]=16384 [4]=204800 [5]=2048 [6]=2097152 [7]=622592 [8]=786432)
declare -A PNAME=([1]=kernel [2]=rootfs [3]=kernel2 [4]=rootfs2 [5]=ota [6]=usershare [7]=userdata [8]=c5os)

pick_cross_compile() {
	local c
	if [ -n "${CROSS_COMPILE:-}" ]; then echo "$CROSS_COMPILE"; return; fi
	for c in "$OWRT_DIR"/staging_dir/toolchain-mipsel_mips32_*_musl/bin/mipsel-openwrt-linux-musl-gcc \
		"$HOME/ing/mips-xburst2-linux-toolchain-r6.0.0/bin/mips-xburst2-linux-gnu-gcc"; do
		[ -x "$c" ] && { echo "${c%gcc}"; return; }
	done
	return 1
}
