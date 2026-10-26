# Building opencreator-os

Everything builds in WSL2 (Ubuntu 24.04). Build trees live in the WSL home
(`~/build/opencreator-os`, regenerable, ~40 GB); artifacts are copied to
`F:/creator5-dev/opencreator-os-builds/<version>/`.

## Prerequisites

```sh
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync \
  swig unzip zlib1g-dev file wget device-tree-compiler u-boot-tools \
  python3-pil squashfs-tools shellcheck
```

The Ingenic SDK tarball is expected at
`/mnt/d/ingenic/X2600/06_kernel6.6_x2600-sdk_v1.0-20250221/` (see
`kernel/SOURCE.md`). If it is missing, `kernel/prepare.sh` downloads it from
Ingenic's public FTP; export the password from your notes first:

```sh
export INGENIC_FTP_PASS=...
```

## Build

```sh
cd /mnt/f/creator5-dev/opencreator/opencreator-os
./build.sh                      # OpenWrt image (kernel.uimage, root.squashfs, sysupgrade.tar)
chainload/build.sh              # chainload.ko for the stock 5.10 kernel
tools/make-install-stick.sh /mnt/f/creator5-dev/opencreator-os-builds/<version> /tmp/stick
```

`build.sh` clones OpenWrt v24.10.3 into `$WORK/openwrt`, links
`feed/x2600` as `target/linux/x2600`, installs the package feeds, unpacks the
SDK kernel (`kernel/prepare.sh`), writes `.config` from `config/openwrt.seed`
plus `CONFIG_EXTERNAL_KERNEL_TREE` and `CONFIG_VERSION_NUMBER` (`git
describe`), and runs `make`. Options: `--menuconfig`, `--kernel-menuconfig`,
`--clean-kernel`.

## Kernel

- Tree: `kernel/kernel-6.6` of `ingenic-linux-kernel6.6-x2600-v1.0-20250221`,
  Linux 6.6.18 with the RT patch set present but not enabled; the tree ships
  `localversion-rt`, so `uname -r` is `6.6.18-rt23-c5pro`.
- OpenWrt uses it as an external tree: no OpenWrt kernel patches are applied,
  the tree is built in place, and modules install under
  `/lib/modules/6.6.18-rt23-c5pro`.
- Base defconfig: `arch/mips/configs/x2600_halley7_linux_defconfig`.
- Board DTS: `kernel/dts/creator5pro.dts`, copied to
  `module_drivers/dts/x2600/` and built in through
  `CONFIG_DT_X2600_MODULE_BASE=y` and
  `CONFIG_DT_X2600_MODULE_BASE_DTS_FILE="x2600/creator5pro.dts"` (path relative
  to `module_drivers/dts/`; the choice lives in
  `arch/mips/xburst2/soc-x2600/Kconfig.DT`, the build rule in
  `module_drivers/dts/Makefile`). It includes `x2600.dtsi`, the same as the
  SDK's `x2600_module_base_mmc0.dts`.
- Command line: `CONFIG_MIPS_CMDLINE_BUILTIN_EXTEND` puts
  `CONFIG_CMDLINE="ieee754=relaxed"` in front of the SPL's argv (copied into
  `arcs_cmdline` by `arch/mips/xburst2/core/prom.c`).
- `make zImage` produces `arch/mips/boot/compressed/zImage` (self-extracting,
  linked at `0x80f00000`); OpenWrt picks it up through `IMAGES_DIR:=compressed`
  and wraps it with `mkimage` into a legacy uImage, load = entry =
  `0x80f00000`.
- Symbol names checked in the tree: SDK Ethernet `CONFIG_INGENIC_MAC`, SDK
  watchdog `CONFIG_INGENIC_WDT`, eMMC `CONFIG_MMC_SDHCI_INGENIC`, RISC-V core
  remoteproc node `ingenic,x2600-riscv-rproc` (under `CONFIG_REMOTEPROC`),
  dev-board Wi-Fi `CONFIG_BCMDHD`, touch `CONFIG_TOUCHSCREEN_GT9XX`.

### Regenerating `feed/x2600/config-6.6`

`kernel/creator5pro.config` is the human-readable source of intent. To
regenerate the full config:

```sh
CROSS_COMPILE=<toolchain prefix> kernel/mkconfig.sh ~/build/opencreator-os/ingenic-6.6/kernel/kernel-6.6 /tmp/kcfg [--build]
cp /tmp/kcfg/.config feed/x2600/config-6.6
```

`mkconfig.sh` merges the fragment onto the defconfig, runs `olddefconfig` and
fails if any fragment line did not survive. After a full OpenWrt build,
`make kernel_oldconfig` in the OpenWrt tree re-normalises the file.

## Packages

Every package is built from source by this build (musl, hard-float,
`mipsel_mips32`). Do not install packages from downloads.openwrt.org for
`mipsel_mips32`: those are soft-float and will not run.
