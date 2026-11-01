# chainload: boot opencreator-os from RAM under the stock kernel

`chainload.ko` boots a RAM-loaded kernel from the stock Creator 5 Pro kernel
(`5.10.186+`, without kexec). It calls `kernel_restart_prepare()` to shut
devices down, arms the SoC watchdog, then jumps as the U-Boot SPL does.
It writes neither the eMMC nor the boot flag. A hung kernel resets into the
flagged slot, or needs a power cycle if the watchdog is disabled.
opencreator-os uses it to test a kernel and rootfs on USB or the spare eMMC
slot before selecting that slot for SPL boot.

## Credit and licence

`chainload_main.c` and `tramp.S` come from
[kiln-os](https://github.com/djvalic/kiln-os) by djvalic,
`kernel-ingenic66/chainload/` at commit `fd0db64` (`chainload.c` was renamed
so that the module can be called `chainload.ko`). Both files are
`SPDX-License-Identifier: GPL-2.0` and stay under that licence; each header
credits kiln-os. Our changes to `chainload_main.c`:

- Comments and the module description name the Creator 5 Pro, not the AD5X.
- `SAFE_MAX` (0x0ec00000) is replaced by the `safe_max` module parameter:
  default 0x0c000000, page aligned, at most 0x20000000 (KSEG0 limit), and
  above `SAFE_MIN + MAX_IMAGE + 1 MiB` (0x02700000).
- Copying the image to 0x00f00000 must not reach the source pages at
  `SAFE_MIN` (0x01600000); otherwise staging fails with `-EFBIG`.
  This limits images to below 7 MiB despite the `MAX_IMAGE` read limit of
  8 MiB, the SPL kernel slot size.
- After `kernel_restart_prepare()` and `local_irq_disable()`, the module
  arms the X2600 watchdog before entering the trampoline. It uses WDT in
  TCU0 at 0x13630000 and CPM at 0x10000000: reboot signature 0x3535 in
  `CPM_CPSPR`, TCU0 clock ungated (`CLKGR1` bit 8), WDT clock stop cleared
  (`TSCR` bit 16), prescaler 1024 and compare value `wdt * rate / 1024`.
  `CPM_OPCR` bit 2 selects the RTC clock: clear = EXTCLK/512 = 46875 Hz,
  set = 32768 Hz. `OPCR` is only read. `wdt` is seconds, default 120,
  0 = off, maximum 1431 for the 16-bit compare register at 46875 Hz.
  Staging and `go` messages print it. Register access is inline; imports
  are unchanged.

`tramp.S` is unchanged. `Makefile`, `build.sh`, `c5-chainload.sh` and this
README were written for opencreator-os; kiln-os's `Makefile`, `chainload.sh`
and `setup.sh` were not used.

## Build

```
chainload/build.sh
```

Requires the Ingenic SDK `kernel-5.10` tree (5.10.186) at
`~/ing/kernel-5.10`, prepared build directory `~/ing/out` and toolchain
`~/ing/mips-xburst2-linux-toolchain-r6.0.0`. Override with `KSRC`, `KOUT`
and `TC`. Prepare `~/ing/out` with
`opencreator/c5-usb-serial-modules/build.sh`: SDK
`x2600_module_base_linux_mmc0_defconfig`, `HIGHMEM=y`, `LOCALVERSION="+"`,
built with `vmlinux modules`. The script leaves that directory unchanged
and builds in a temporary copy of the module sources.

Output: `chainload/out/chainload.ko` and `chainload/out/abi-report.txt`.
The build fails unless all of the following hold:

- vermagic is exactly `5.10.186+ SMP preempt mod_unload MIPS32_R5 32BIT `
  including the trailing space, read from `.modinfo` with `objcopy`.
- `.gnu.linkonce.this_module` (`struct module`) matches the stock size and
  `init`/`exit` offsets, with no `__versions`. Checks use fixed values and
  every `.ko` in `STOCK_MODULES`, defaulting to the archive's stock 2.0.8
  `module_driver/`. The archive is `../../../creator-5-pro-firmware-archive`
  relative to `chainload/`.
- Every undefined symbol is exported in `__ksymtab` by every kernel in
  `STOCK_XIMAGES`, defaulting to the archived stock 2.0.8 `xImage`.
  Non-exported symbols, including `kernel_restart_prepare` and
  `device_shutdown`, fail the check.

### ABI comparison (2026-10-26)

| | stock 2.0.8 (software 2.0.0), 25 modules | stock 2.0.7 (software 1.9.9, on the printer), 25 modules | chainload.ko |
|---|---|---|---|
| vermagic | `5.10.186+ SMP preempt mod_unload MIPS32_R5 32BIT` | same | same |
| `.gnu.linkonce.this_module` size | 0x180 | 0x180 | 0x180 |
| `init` / `exit` relocation offsets | 0xe0 / 0x16c | 0xe0 / 0x16c | 0xe0 / 0x16c |
| `__versions` | none | none | none |
| imports exported by that kernel (`__ksymtab`) | 21/21 | 21/21 | 21 imports |

Imports: `__get_free_pages __num_online_cpus __stack_chk_fail
__stack_chk_guard filp_close filp_open flush_icache_range free_pages
kernel_read memcpy memset param_ops_charp param_ops_ulong printk
sprint_symbol strcpy strlen strncmp sysfs_streq vfree vmalloc`. Both stock
kernels link at 0x80010000. To check stock 2.0.7, point `STOCK_MODULES` and
`STOCK_XIMAGES` at the 1.9.9-1.3.0 package's `kernel-2.0.7`
`module_driver/` and `xImage`. `DEBUG_SPINLOCK=y` in `~/ing/out` puts `init`
at stock's 0xe0 offset.

The module avoids config-dependent kernel structs by reading file size to
EOF rather than from `struct inode`. It calls the unexported
`kernel_restart_prepare` through `krp=`, validated with `sprint_symbol`
before staging.

## Usage (on stock, over SSH)

Put `chainload.ko`, `c5-chainload.sh` and the OpenWrt `kernel.uimage` in
one directory, normally `/usr/data/opencreator-os/chainload/`, where the
installer places them.

```sh
sh c5-chainload.sh args /dev/mmcblk0p2      # inspect without staging
sh c5-chainload.sh stage /dev/mmcblk0p2
sh c5-chainload.sh status
sh c5-chainload.sh unstage                 # cancel, or:
sh c5-chainload.sh go                      # SSH drops
```

`stage ROOTDEV [IMAGE]` does the following:

- Requires `uname -r` = `5.10.186+` and a `ROOTDEV` other than the running
  stock root.
- Warns if `ROOTDEV` is not a block device or does not start with `hsqs`.
- Replaces `root=` in `/proc/cmdline`, removes `c5.*` words, preserves
  `init=/linuxrc`, `rootfstype=squashfs`, `mem=`/`rmem=` and other words,
  and adds missing `rootwait` and `ieee754=relaxed`.
  OpenWrt prepends `CONFIG_CMDLINE`, including
  `console=tty0 fbcon=rotate:3`, for the same panel boot log as an SPL boot.
  Do not append `console=tty0` here: placing it after `console=ttyS0` would
  make the panel `/dev/console`.
- Allows `c5-booted` to commit a healthy test boot only if `ROOTDEV` is the
  GPT `rootfs`/`rootfs2` partition from `fdisk -l`, and `IMAGE` is a uImage
  exactly 64 + `ih_size` bytes long and byte-identical to the paired
  `kernel`/`kernel2` partition's start. Comparison uses sha256, or md5.
  Otherwise it appends `c5.nocommit=1` to leave the flag unchanged.
  `stage` prints the decision as `commit:`.
- Reads `krp` from `/proc/kallsyms`, temporarily lifting `kptr_restrict`
  if addresses are zero.
- Sets `safe_max` to the end of the first `System RAM` range below
  256 MiB, minus 16 MiB, rounded down to 1 MiB.
- Passes `C5CL_WDT` as `wdt=`: integer seconds, default 120, 0 = off,
  maximum 1431. `args`, `stage` and `status` display it.
- Loads the module and prints its `chainload:` dmesg lines.

`go` runs detached, through `setsid`, `nohup` or a plain background job with
SIGHUP ignored, and writes its progress to `/dev/console`. In order, it:

1. Stops `firmwareExe`, klippy, moonraker, opencreator, `c5_bridge`,
   `c5_socat`, `wpa_supplicant`, `hostapd`, `udhcpc` and `dhcpcd`.
2. Syncs, remounts `/usr/data` and `/usr/prog` read-only, and unmounts
   `/mnt`. Stock `/etc` shares `/usr/prog`'s partition.
3. Takes `wlan0`, `wlan1` and `eth0` down and unloads `8821cu`,
   `rtl8188fu` and `soc_mac_driver`.
4. Unbinds dwc2 USB controllers to stop DMA into RAM.
5. Offlines secondary CPUs, turns off `backlight_gpio0`, and writes `go`.
   OpenWrt's framebuffer driver turns the backlight on when its display runs.

SSH stays up until the network goes down, just before the jump.

For a test without installing to eMMC, write `root.squashfs` raw to a USB
stick's first partition and use `stage /dev/sda1`. For an installed spare
slot, use its `rootfs` device. On the observed printer, stock uses slot 2
(`/dev/mmcblk0p4`) and OpenWrt uses slot 1 (`/dev/mmcblk0p2`).

Test path overrides are listed in the `c5-chainload.sh` header.

## Memory (Creator 5 Pro, Observed 2026-10-26)

The SPL command line has `mem=236M@0x0 rmem=16M@0xec00000
rtos_size=4M@0xfc00000 mem=256M@0x30000000`. `/proc/iomem` shows System
RAM at 0x00000000-0x0ebfffff (lowmem) and at 0x30000000-0x3fffffff
(highmem), so `c5-chainload.sh` passes `safe_max=0x0dc00000`.

- The image is copied to physical 0x00f00000 (virtual 0x80f00000, the uImage
  load and entry address). The zboot decompressor writes the kernel from
  0x80010000 upwards, and its own bss, heap and stack sit just above the
  image.
- Staged image pages, the page list, argv and the trampoline all lie in
  [0x01600000, safe_max). The copy therefore never overwrites its source,
  and the new kernel's early boot does not overwrite argv.
- The usable image size is below 7 MiB, because the copy must stay under
  0x01600000. Keep the zImage under about 6.5 MiB to leave room for the
  decompressor's bss and heap. Otherwise raise `SAFE_MIN` in
  `chainload_main.c`.

## Recovery

`stage` and `go` do not write eMMC or change `ota`. Until a healthy OpenWrt
boot commits a slot, a reset or power cycle boots the flagged stock slot.
`stage` does not reboot; `unstage` unloads the module.

`go` arms the watchdog for `C5CL_WDT` seconds, default 120. If the new kernel
does not feed it, the SoC resets into the flagged slot. SPL disables it on
boot. The opencreator-os kernel feeds an already-running watchdog through
`kernel/patches/0005` and `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`; the
watchdog core pings it every half timeout until procd takes over
`/dev/watchdog`.

For kernels that cannot feed a running watchdog, use `C5CL_WDT=0`; a hung
kernel then needs a power cycle. OpenWrt also returns unhealthy test boots
to stock; see `docs/recovery.md`.

Not verified on hardware: the watchdog register sequence follows the SDK
sources; QEMU has no X2600 watchdog.

## Risks

- A reboot notifier or device shutdown hook in stock's out-of-tree drivers
  could reset the board. In that case the test ends in a normal stock boot.
- The cache flush assumes that Config1/Config2 describe L1 and L2 (index
  ops). kiln-os has verified this on the same X2600.
- cpu1 is offlined under stock. The new kernel's SMP code resets and starts
  it again.
- The new system can write its mounted filesystems. OpenWrt mounts `c5os`
  at `/data`, not stock `userdata`, and a healthy eligible test boot can
  commit the boot flag.
