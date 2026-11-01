# What is in the image

Kernel, package and base-file configuration. For building, see `build.md`.

## Kernel

- Tree: `kernel/kernel-6.6` of `ingenic-linux-kernel6.6-x2600-v1.0-20250221`,
  Linux 6.6.18 with the RT patch set present but not enabled; the tree ships
  `localversion-rt`, so `uname -r` is `6.6.18-rt23-c5pro`.
- OpenWrt uses it as an external tree: no OpenWrt kernel patches are applied,
  the tree is built in place, and modules install under
  `/lib/modules/6.6.18-rt23-c5pro`.
- Base defconfig: `arch/mips/configs/x2600_halley7_linux_defconfig`.
- Board DTS: `kernel/dts/creator5pro.dts`, copied to
  `module_drivers/dts/x2600/`. `CONFIG_DT_X2600_MODULE_BASE=y` and
  `CONFIG_DT_X2600_MODULE_BASE_DTS_FILE="x2600/creator5pro.dts"` build it in.
  The path is relative to `module_drivers/dts/`; the Kconfig choice is in
  `arch/mips/xburst2/soc-x2600/Kconfig.DT`, the build rule in
  `module_drivers/dts/Makefile`. Like the SDK's `x2600_module_base_mmc0.dts`,
  it includes `x2600.dtsi`.
- Command line: `CONFIG_MIPS_CMDLINE_BUILTIN_EXTEND` prefixes the SPL's argv with
  `CONFIG_CMDLINE="ieee754=relaxed console=ttyS0,115200n8 console=tty0 fbcon=rotate:3 vt.global_cursor_default=0"`.
  `arch/mips/xburst2/core/prom.c` copies argv into `arcs_cmdline`;
  `bootcmdline_init()` in `arch/mips/kernel/setup.c` appends it to the
  built-in string. Chainload passes argc in `a0` and argv in `a1`, so both
  boot paths get the prefix; `c5-chainload.sh` adds nothing.
- Panel console: `CONFIG_FRAMEBUFFER_CONSOLE`, `CONFIG_VT_CONSOLE` and the
  8x16 font give 100x30 characters in landscape. `CONFIG_FRAMEBUFFER_CONSOLE_ROTATION`
  enables `fbcon=rotate:3`: 90° counter-clockwise in the portrait 480x800
  framebuffer, matching os-installer's LVGL `LV_DISP_ROT_90` (UI x runs up
  the framebuffer, UI y to the right). No logo or tty0 login.
  The kernel retains the first options and position of a repeated `console=`
  and makes the last console `/dev/console`. The SPL's `console=ttyS0,115200n8`
  therefore keeps ttyS0 primary; tty0 mirrors printk. The leading ttyS0
  option also keeps procd's shutdown output on serial; `askconsole` uses
  `/dev/console` when several consoles are configured.
  `CONFIG_DUMMY_CONSOLE_COLUMNS=100` and `CONFIG_DUMMY_CONSOLE_ROWS=30`
  preserve 30 lines before fbcon takes over at about 1.25 s, instead of 80x25.
  The SPL's `loglevel=8` makes the panel show all serial output.
  `vt.global_cursor_default=0` hides the VT cursor.
  Scrolling uses `SCROLL_REDRAW` without
  `CONFIG_FRAMEBUFFER_CONSOLE_LEGACY_ACCELERATION`; the driver rejects X
  panning (`xpanstep=0`), which `rotate:3` would need.
  `CONFIG_VT_HW_CONSOLE_BINDING` lets `runFirmwareExe.sh` unbind fbcon through
  `/sys/class/vtconsole/vtconN/bind` while os-installer draws, then rebind it.
- Backlight: `gpio-backlight` on PC14, without `default-on`, linked from the
  DPU node by `backlight = <&backlight>`. The panel is always powered.
  `kernel/patches/0006` turns the backlight off at probe, including after
  chainload, while the driver programs the EPLL and LVDS PHY. It turns it on
  50 ms after RDMA starts; stock's 0.5 s delay would hide early boot-log lines.
  Blank turns it off before the DPU stops; unblank turns it on 50 ms after
  restart. `c5-chainload.sh go` turns stock's backlight off before the jump.
- `make zImage` produces `arch/mips/boot/compressed/zImage` (self-extracting,
  linked at `0x80f00000`); OpenWrt picks it up through `IMAGES_DIR:=compressed`
  and wraps it with `mkimage` into a legacy uImage, load = entry =
  `0x80f00000`.
- SDK symbols: Ethernet `CONFIG_INGENIC_MAC`, watchdog `CONFIG_INGENIC_WDT`,
  eMMC `CONFIG_MMC_SDHCI_INGENIC`, RISC-V remoteproc node
  `ingenic,x2600-riscv-rproc` under `CONFIG_REMOTEPROC`, dev-board Wi-Fi
  `CONFIG_BCMDHD`, upstream Goodix touch `CONFIG_TOUCHSCREEN_GOODIX`.
- `CONFIG_WATCHDOG=y`, `CONFIG_INGENIC_WDT=y` and the enabled watchdog DTS
  node provide `/dev/watchdog`; procd opens and feeds it without a separate
  service. `kernel/patches/0005`, applied by `kernel/prepare.sh`, makes the
  SDK driver mark a counter already enabled at probe as running. The SPL
  leaves it off; `chainload.ko` arms it for a test boot.
  `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` in `feed/x2600/config-6.6` lets the
  watchdog core feed it every half timeout until procd opens it; the default
  heartbeat is 15 s. Watchdog operation is not verified on hardware.
- Display and touch: the KX070 panel runs with stock's 31 MHz pixel clock
  and porches (`kernel/patches/0004`, taken from stock's register dump);
  boot log, os-installer screens and touch work on the printer.
- Disabled in `kernel/creator5pro.config`:
  - MTD, NAND, UBI, UBIFS, JFFS2 and the SDK SPI-flash controller: storage is
    eMMC; `dd` writes the boot flag and slots.
  - Sound and SDK ASoC drivers: no user of stock's internal codec.
  - Netfilter: no firewall package.
  - USB gadget stack and configfs: dwc2 is host-only. The internal hub uses
    `13540000.usb`; stock never binds a gadget to the OTG controller.
  - SDK `DEBUG_SPINLOCK` and `SPINLOCK_TEST`.
  `CONFIG_LOG_BUF_SHIFT=16` provides 64 KiB; a printer boot logs about 20 KiB.

## Packages

Packages are built from source with musl and hard-float for `mipsel_mips32`.
Do not install downloads.openwrt.org's `mipsel_mips32` packages: they are
soft-float and will not run.

Packages come from `DEFAULT_PACKAGES` in `feed/x2600/Makefile` (plus
`config/openwrt.seed`); the target drops OpenWrt's default `mtd` and `urngd`:

- Wi-Fi client: `wpa-supplicant-mbedtls`, not `wpad-basic-mbedtls`. It supports
  WPA3-SAE, OWE, Suite-B 192, 802.11r and PMF; 802.11w has no build switch.
  `wpa-supplicant-basic` uses internal TLS without SAE or OWE.
  OpenWrt's `/etc/init.d/wpad` and `mac80211.sh` start hostapd only when
  installed, so only `wpa_supplicant` runs.
  The local `wifi-scripts` patch checks optional previous radio state before
  selecting it and skips hostapd reset when the executable is absent.
  Daemon errors remain visible. Shared key management treats unset FILS as
  disabled, including in preserved client configurations; no UCI migration
  or AP daemon is needed.
- No `fdisk`, `libfdisk`, `libncurses` or `terminfo`: OpenWrt never calls
  fdisk. The installer's `fdisk -l` (`part_table`) and `c5-chainload.sh` run
  only on stock.
- No `urngd`: the printer logs `random: crng init done` at 3.9 s during
  preinit, before urngd would start at 11.9 s.
- USB Ethernet: `kmod-usb-net-cdc-ether`, `-cdc-ncm`, `-rtl8152`, `-asix`,
  `-asix-ax88179`. Like all OpenWrt kmods, including USB serial, kmodloader
  loads them at boot, not on plug. With no board Ethernet MAC, an adapter
  becomes `eth0`; `02_network` adds it to `br-lan` with DHCP, acquiring an
  address when plugged in. Adapters registering as `usb0`, such as CDC
  devices with locally administered MACs, are not configured.
- Camera: `kmod-video-uvc` for the internal UVC camera (`05a3:9230`).

## Base files

Sysupgrade-preserved files such as `/etc/config/fstab` have no migration
code. To apply changes, use a fresh install or "Update / Repair OpenWrt"
from the USB stick. The latter drops the image-owned files in `IMAGE_OWNED`
(`installer/opencreator-os/install.sh`) from the preserved configuration.

`feed/x2600/base-files/etc/sysctl.d/11-c5.conf` disables IPv4 `ip_forward`
and IPv6 `all.forwarding` and `default.forwarding`, and sets `kernel.panic=10`.
It must sort after OpenWrt 24.10.8's `10-default.conf`, which enables
forwarding and sets a 3-second panic timeout. This release's netifd does not
write forwarding sysctls during interface setup. S2 checks forwarding stays
zero after boot and a lan `ifup`.

`/etc/hotplug.d/iface/30-c5-ip` writes `c5: lan <IPv4>` or
`c5: wwan <IPv4> (<SSID>)` to writable `/dev/tty0` on `ifup` and
address-changing `ifupdate` events. It reads the address through OpenWrt's
`network_get_ipaddr` and the Wi-Fi SSID from `wireless.c5sta.ssid`; other
interfaces, address-less events and missing VTs produce no notice. There
is no daemon, display clearing or framebuffer access. S2 checks the real
LAN DHCP event through `/dev/vcs1` when available, plus SSID formatting
with a temporary logical `wwan` on loopback, not a Wi-Fi association.

**Reimplementation, source reasoning:** `installer/runFirmwareExe.sh`
unbinds fbcon before the installer app owns `/dev/fb0` and rebinds it when
the app exits. The hotplug writes only VT text; it neither rebinds fbcon
nor draws over the app, so it does not conflict with that ownership.
Notices need not be visible while fbcon is unbound. Physical-printer
visibility, including after rebind, remains unverified; QEMU has no
framebuffer and checks VT text only.

`/etc/config/fstab` mounts ext4 label `c5os` at `/data` (`rw,noatime`), with
no `userdata` fallback, and enables `/data/swapfile` (`config swap`).
`c5-booted` creates the 256 MiB swap file once, after the first healthy
boot without it, unless less than 64 MiB would stay free
(`logread -e c5-swap`). `c5-swap` turns swap off before `/data` is unmounted
and before sysupgrade, so `c5os` unmounts cleanly. The file lives on `c5os`
and survives sysupgrade.

Preinit (`79_c5_import`) copies `model`, `wifi.conf` and `authorized_keys`
from `c5os`'s `opencreator-os/` into `/etc/c5/` and `/etc/dropbear/` when the
destination is empty, and stages a saved `sysupgrade.tgz`.
`/lib/upgrade/keep.d/c5` keeps `/etc/c5/` across sysupgrade.

Stock Wi-Fi import also reads
`/usr/data/firmwareRes/config/network.json`: when `staticIpOpen` is `true`,
it exports `IPADDR`, `NETMASK`, `GATEWAY` and `DNS` into `wifi.conf`.
`c5-wifi-sta` configures static IPv4 when `IPADDR` is nonempty; DHCP remains
the default. A hand-written, shell-sourceable stick
`opencreator-os/wifi.conf` takes precedence over stock import and accepts
the same optional keys alongside `SSID` and `PSK`; `DNS` may contain
space-separated server addresses. Existing configured Wi-Fi is not
overwritten.
