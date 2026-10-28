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
installer/tools/build.sh        # static util-linux sfdisk + partx for the install stick
(cd ../os-installer && make mips32)   # touchscreen app (optional on the stick)
tools/make-install-stick.sh --app ../os-installer/build/mips32/os-installer \
    /mnt/f/creator5-dev/opencreator-os-builds/<version> /tmp/stick
```

`installer/tools/build.sh` downloads util-linux 2.40.2 (checksum pinned) and
builds it with the Ingenic toolchain (`TC`, default
`~/ing/mips-xburst2-linux-toolchain-r6.0.0`) into `installer/tools/out/`;
`make-install-stick.sh` refuses to run without it. The app lives in the
separate `os-installer` repository (`make mips32` for the printer, `make sdl`
for the PC). `tools/ui-demo.sh APP VERSION_DIR` runs the SDL build under WSLg
against the real installer and a loop-mounted image laid out like the
printer's eMMC (needs sudo; a backup in the demo writes about 7.3 GB).

`build.sh` clones OpenWrt v24.10.8 into `$WORK/openwrt`, links
`feed/x2600` as `target/linux/x2600`, installs the package feeds (again
whenever `OPENWRT_TAG` changes), unpacks the
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
  `CONFIG_CMDLINE="ieee754=relaxed console=ttyS0,115200n8 console=tty0 fbcon=rotate:3 vt.global_cursor_default=0"`
  in front of the SPL's argv (copied into `arcs_cmdline` by
  `arch/mips/xburst2/core/prom.c`; `bootcmdline_init()` in
  `arch/mips/kernel/setup.c` copies the built-in string first, then appends
  `arcs_cmdline`). A chainload test boot passes its line the same way
  (`a0` = argc, `a1` = argv), so both boot paths get the prefix from the
  kernel; `c5-chainload.sh` adds nothing for it.
- Boot log on the panel: `CONFIG_FRAMEBUFFER_CONSOLE` on the VT
  (`CONFIG_VT_CONSOLE`), only the 8x16 font (100x30 characters landscape),
  `CONFIG_FRAMEBUFFER_CONSOLE_ROTATION` for `fbcon=rotate:3`: the text is
  drawn rotated 90° counter-clockwise in the portrait 480x800 framebuffer,
  the same mapping as the os-installer app's LVGL `LV_DISP_ROT_90`
  (UI x runs up the framebuffer, UI y to the right). No logo. Console order:
  the kernel keeps the first options and position of a repeated `console=`
  and makes the last one `/dev/console`, so the SPL's
  `console=ttyS0,115200n8` stays the primary console and `tty0` only mirrors
  printk. The leading `console=ttyS0,115200n8` keeps procd on serial: procd
  takes the first `console=` word for its shutdown output, and `askconsole`
  uses `/dev/console` (ttyS0) when there are several. No login runs on tty0.
  `loglevel=8` comes from the SPL after the prefix and stays: the panel
  shows everything serial shows. `vt.global_cursor_default=0` hides the VT
  cursor, so no blinking `_` sits under the log. fbcon scrolls by redrawing
  (`SCROLL_REDRAW`, fixed without
  `CONFIG_FRAMEBUFFER_CONSOLE_LEGACY_ACCELERATION`); it never pans the
  framebuffer, and with `rotate:3` it could not anyway, since a console
  scroll would be an X pan, which the driver rejects (`xpanstep` 0).
  `CONFIG_VT_HW_CONSOLE_BINDING` lets the stick's `runFirmwareExe.sh`
  unbind fbcon (`/sys/class/vtconsole/vtconN/bind`) while the os-installer
  app draws and bind it again afterwards. On the printer the console text
  comes out the right way up and at the right size, but the whole picture
  is shifted in a circle (scanout, not fbcon; under investigation).
- Backlight: `gpio-backlight` on PC14 without `default-on`, linked from the
  DPU node (`backlight = <&backlight>`). The panel is always powered, so
  `kernel/patches/0006` keeps the backlight off while the fb driver programs
  the EPLL and the LVDS PHY (it turns it off at probe, which also covers a
  chainload from stock) and turns it on 500 ms after RDMA starts, like
  stock (logo drawn, `sleep 0.5`, then `brightness` 1). Blank turns it off
  before the DPU stops; unblank turns it on 500 ms after the restart.
  `c5-chainload.sh go` turns stock's backlight off right before the jump.
- `make zImage` produces `arch/mips/boot/compressed/zImage` (self-extracting,
  linked at `0x80f00000`); OpenWrt picks it up through `IMAGES_DIR:=compressed`
  and wraps it with `mkimage` into a legacy uImage, load = entry =
  `0x80f00000`.
- Symbol names checked in the tree: SDK Ethernet `CONFIG_INGENIC_MAC`, SDK
  watchdog `CONFIG_INGENIC_WDT`, eMMC `CONFIG_MMC_SDHCI_INGENIC`, RISC-V core
  remoteproc node `ingenic,x2600-riscv-rproc` (under `CONFIG_REMOTEPROC`),
  dev-board Wi-Fi `CONFIG_BCMDHD`, upstream Goodix touch
  `CONFIG_TOUCHSCREEN_GOODIX`.
- `CONFIG_WATCHDOG=y`, `CONFIG_INGENIC_WDT=y` and the enabled watchdog DTS
  node provide `/dev/watchdog`; procd opens and feeds it without a separate
  service. `kernel/patches/0005` (applied by `kernel/prepare.sh` with the
  other `kernel/patches/`) makes the SDK driver mark a counter that is
  already enabled at probe as running. The SPL leaves it off; `chainload.ko`
  arms it for a test boot. With `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`
  (`feed/x2600/config-6.6`) the watchdog core then feeds it every half
  timeout (default heartbeat 15 s) until procd opens it. Watchdog operation
  has not been verified on hardware.
- Display/touch bring-up is in progress. Even with the framebuffer and
  Goodix drivers configured, use the installer headless on OpenWrt until
  display bring-up is verified on hardware; the stock touchscreen flow is
  separate. The kernel's boot log on the panel (above) needs no app.
- Left out on purpose (`kernel/creator5pro.config`): MTD, NAND, UBI, UBIFS,
  JFFS2 and the SDK SPI-flash controller (storage is eMMC only; the boot flag
  and slots are written with `dd`), sound and the SDK ASoC drivers (stock's
  internal codec has no user here), netfilter (no firewall package), the USB
  gadget stack and configfs (dwc2 is host-only: the internal hub is on the
  host controller `13540000.usb`, and stock never binds a gadget to the OTG
  controller), the SDK's `DEBUG_SPINLOCK` and `SPINLOCK_TEST`.
  `CONFIG_LOG_BUF_SHIFT=16` (64 KiB; a printer boot logs about 20 KiB).

### Regenerating `feed/x2600/config-6.6`

`kernel/creator5pro.config` is the human-readable source of intent. To
regenerate the full config:

```sh
CROSS_COMPILE=<toolchain prefix> kernel/mkconfig.sh ~/build/opencreator-os/ingenic-6.6/kernel/kernel-6.6 /tmp/kcfg [--build]
cp /tmp/kcfg/.config feed/x2600/config-6.6
```

`mkconfig.sh` merges the fragment onto the defconfig, runs `olddefconfig` and
fails if any fragment line did not survive. After a full OpenWrt build,
`make kernel_oldconfig` in the OpenWrt tree re-normalises the file. OpenWrt
builds the tree in place, so after a build `O=` refuses it ("source tree is
not clean"); run `mkconfig.sh` on a copy cleaned with
`make ARCH=mips mrproper` instead.

`config-6.6` is not the whole story: OpenWrt adds its own kernel options when
it configures the tree. Every selected kmod package turns its `KCONFIG`
symbols on as modules (that is how USB serial, USB Ethernet and UVC get in),
and `CONFIG_KERNEL_*` options in `config/openwrt.seed` become kernel options
(the seed turns off `KERNEL_MPTCP` and `KERNEL_RT_GROUP_SCHED`, which OpenWrt
enables by default). Check a change against the built `kernel.config`.

## Packages

Every package is built from source by this build (musl, hard-float,
`mipsel_mips32`). Do not install packages from downloads.openwrt.org for
`mipsel_mips32`: those are soft-float and will not run.
