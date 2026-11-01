# What is in the image

Why the kernel, packages and base files are configured the way they are. For
building, see `build.md`.

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
  Before fbcon takes over (about 1.25 s), dummycon keeps the VT buffer at
  100x30 too (`CONFIG_DUMMY_CONSOLE_COLUMNS=100`,
  `CONFIG_DUMMY_CONSOLE_ROWS=30`), rather than retaining only 80x25. The
  first screen fbcon draws therefore has a full 30 lines.
  `loglevel=8` comes from the SPL after the prefix and stays: the panel
  shows everything serial shows. `vt.global_cursor_default=0` hides the VT
  cursor, so no blinking `_` sits under the log. fbcon scrolls by redrawing
  (`SCROLL_REDRAW`, fixed without
  `CONFIG_FRAMEBUFFER_CONSOLE_LEGACY_ACCELERATION`); it never pans the
  framebuffer, and with `rotate:3` it could not anyway, since a console
  scroll would be an X pan, which the driver rejects (`xpanstep` 0).
  `CONFIG_VT_HW_CONSOLE_BINDING` lets the stick's `runFirmwareExe.sh`
  unbind fbcon (`/sys/class/vtconsole/vtconN/bind`) while the os-installer
  app draws and bind it again afterwards.
- Backlight: `gpio-backlight` on PC14 without `default-on`, linked from the
  DPU node (`backlight = <&backlight>`). The panel is always powered, so
  `kernel/patches/0006` keeps the backlight off while the fb driver programs
  the EPLL and the LVDS PHY (it turns it off at probe, which also covers a
  chainload from stock) and turns it on 50 ms after RDMA starts. Stock
  waits 0.5 s (logo drawn, `sleep 0.5`, then `brightness` 1); that long,
  the first boot-log lines scroll by unseen. Blank turns it off before the
  DPU stops; unblank turns it on 50 ms after the restart.
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
- Display and touch: the KX070 panel runs with stock's 31 MHz pixel clock
  and porches (`kernel/patches/0004`, taken from stock's register dump);
  boot log, os-installer screens and touch work on the printer.
- Left out on purpose (`kernel/creator5pro.config`): MTD, NAND, UBI, UBIFS,
  JFFS2 and the SDK SPI-flash controller (storage is eMMC only; the boot flag
  and slots are written with `dd`), sound and the SDK ASoC drivers (stock's
  internal codec has no user here), netfilter (no firewall package), the USB
  gadget stack and configfs (dwc2 is host-only: the internal hub is on the
  host controller `13540000.usb`, and stock never binds a gadget to the OTG
  controller), the SDK's `DEBUG_SPINLOCK` and `SPINLOCK_TEST`.
  `CONFIG_LOG_BUF_SHIFT=16` (64 KiB; a printer boot logs about 20 KiB).

## Packages

Every package is built from source by this build (musl, hard-float,
`mipsel_mips32`). Do not install packages from downloads.openwrt.org for
`mipsel_mips32`: those are soft-float and will not run.

Packages come from `DEFAULT_PACKAGES` in `feed/x2600/Makefile` (plus
`config/openwrt.seed`); the target drops OpenWrt's default `mtd` and `urngd`:

- Wi-Fi client: `wpa-supplicant-mbedtls` instead of `wpad-basic-mbedtls`.
  Only `wpa_supplicant` runs (OpenWrt's `/etc/init.d/wpad` and `mac80211.sh`
  start `hostapd` only if it is installed). It is OpenWrt's full mbedTLS
  build: WPA3-SAE, OWE, Suite-B 192, 802.11r, and PMF (802.11w has no build
  switch any more). `wpa-supplicant-basic` is not an option: it uses the
  internal TLS, which has no SAE or OWE.
  The local `wifi-scripts` patch checks for optional previous radio state
  before selecting it and skips the hostapd reset call when its executable
  is absent, just as normal setup does. Daemon errors remain visible.
  Shared key management treats an unset FILS option as disabled, including
  preserved client configurations: no UCI migration or unused AP daemon is
  needed to avoid these warnings.
- No `fdisk` (and its `libfdisk`, `libncurses`, `terminfo`): OpenWrt never
  calls it. The installer's `fdisk -l` (`part_table`) and `c5-chainload.sh`
  run only on stock.
- No `urngd`: on the printer the kernel logs `random: crng init done` at
  3.9 s, during preinit, and urngd only started at 11.9 s.
- USB Ethernet adapters: `kmod-usb-net-cdc-ether`, `-cdc-ncm`, `-rtl8152`,
  `-asix`, `-asix-ax88179`. Like every OpenWrt kmod (and the USB serial
  ones) they are loaded at boot by `kmodloader`, not on plug. The board has
  no Ethernet MAC, so an adapter is `eth0`, which `02_network` puts in
  `br-lan` with DHCP; it gets an address when plugged in. An adapter that
  registers as `usb0` (a CDC device with a locally administered MAC, such as
  a phone) is not configured.
- Camera: `kmod-video-uvc` for the internal UVC camera (`05a3:9230`).

## Base files

Files that sysupgrade preserves (such as `/etc/config/fstab`) get no
migration code: a change to one reaches an existing install through a fresh
install or "Update / Repair OpenWrt" from the USB stick, which drops the
image-owned files listed in `IMAGE_OWNED` (`installer/opencreator-os/install.sh`)
from the kept configuration.

`feed/x2600/base-files/etc/sysctl.d/11-c5.conf` disables IPv4 and IPv6
forwarding (`ip_forward`, IPv6 `all.forwarding` and `default.forwarding`)
and sets `kernel.panic=10`. It sorts after OpenWrt 24.10.8 base-files'
`10-default.conf`, which enables forwarding and sets a 3-second panic
timeout; `10-c5.conf` would run too early. The release's netifd does not
write forwarding sysctls on interface setup. S2 checks that IPv4 and IPv6
forwarding are still zero after boot and a lan `ifup`.
