# chainload: boot opencreator-os from RAM under the stock kernel

`chainload.ko` is a small module for the stock Creator 5 Pro kernel
(5.10.186+). It loads a kernel image into RAM, shuts devices down with the
kernel's own `kernel_restart_prepare()`, and jumps to the image the same way
the U-Boot SPL does. Nothing on the eMMC is written and the boot flag is
left alone. Right before the jump it arms the SoC watchdog, so if the new
kernel hangs, the printer resets (or is power-cycled) and the SPL boots stock
exactly as before. The stock kernel has no kexec. opencreator-os uses this
to test a kernel and rootfs (on a USB stick or in the spare eMMC slot)
before the SPL ever boots it.

## Credit and licence

`chainload_main.c` and `tramp.S` come from
[kiln-os](https://github.com/djvalic/kiln-os) by djvalic,
`kernel-ingenic66/chainload/` at commit `fd0db64` (`chainload.c` was renamed
so that the module can be called `chainload.ko`). Both files are
`SPDX-License-Identifier: GPL-2.0` and stay under that licence; each header
credits kiln-os. Our changes to `chainload_main.c`:

- Comments and the module description name the Creator 5 Pro, not the AD5X.
- The AD5X constant `SAFE_MAX` (0x0ec00000) is now the `safe_max` module
  parameter: a physical address with default 0x0c000000. It must be page
  aligned, at most 0x20000000 (the KSEG0 limit), and above
  `SAFE_MIN + MAX_IMAGE + 1 MiB` (0x02700000).
- New check: the image is refused (`-EFBIG`) if copying it to 0x00f00000
  would reach `SAFE_MIN` (0x01600000), where the source pages are staged.
  Without this check, an image larger than 7 MiB would overwrite its own
  source during the copy. `MAX_IMAGE` (8 MiB, the SPL kernel slot size) is
  still the read limit.
- New: right before the jump, after `kernel_restart_prepare()` and
  `local_irq_disable()` and before the trampoline, the module arms the X2600
  watchdog (WDT in TCU0 at 0x13630000, CPM at 0x10000000) the way the SDK's
  5.10 reboot path does: reboot signature 0x3535 in `CPM_CPSPR`, TCU0 clock
  ungated (`CLKGR1` bit 8), WDT clock stop bit cleared (`TSCR` bit 16),
  compare value `wdt * rate / 1024` with prescaler 1024 and the RTC clock
  that `CPM_OPCR` bit 2 selects (clear: EXTCLK/512 = 46875 Hz, set:
  32768 Hz; `OPCR` is only read), then the counter enabled. The new module
  parameter `wdt` is in seconds: default 120, 0 = off, at most 1431 (the
  16-bit compare register at 46875 Hz). The staging and `go` messages print
  it. The register access is inline; the imports are unchanged.

`tramp.S` is unchanged. `Makefile`, `build.sh`, `c5-chainload.sh` and this
README were written for opencreator-os; kiln-os's `Makefile`, `chainload.sh`
and `setup.sh` were not used.

## Build (WSL)

```
chainload/build.sh
```

The script builds against the Ingenic SDK `kernel-5.10` tree (5.10.186) in
`~/ing/kernel-5.10`, using the prepared build directory `~/ing/out` and
toolchain `~/ing/mips-xburst2-linux-toolchain-r6.0.0`. You can override these
with `KSRC`, `KOUT` and `TC`. `~/ing/out` is the output of
`opencreator/c5-usb-serial-modules/build.sh`: SDK
`x2600_module_base_linux_mmc0_defconfig` plus `HIGHMEM=y` and
`LOCALVERSION="+"`, built with `vmlinux modules`. The script never modifies
that directory. It builds in a temporary copy of this directory, so no
objects end up here.

Output: `chainload/out/chainload.ko` and `chainload/out/abi-report.txt`.
The build fails unless all of the following hold:

- vermagic is exactly `5.10.186+ SMP preempt mod_unload MIPS32_R5 32BIT `
  (with the trailing space). It is read from `.modinfo` with `objcopy`.
- `.gnu.linkonce.this_module` (that is, `struct module`) has the stock
  size and `init`/`exit` offsets, and the module has no `__versions`. This
  is checked against fixed values and against every `.ko` in
  `STOCK_MODULES`. By default that is the stock 2.0.8 `module_driver/` in
  `../creator-5-pro-firmware-archive`.
- every undefined symbol is exported by every kernel in `STOCK_XIMAGES`
  (default: the archived stock 2.0.8 `xImage`). To check this, the script
  gunzips the uImage payload into `vmlinux.bin` and finds the load base.
  Then, for each import, it looks for a `__ksymtab` entry
  `{value, name, namespace}` whose name pointer points at that string. The
  search accepts tail-merged strings such as `printk` inside `vprintk`.
  Non-exported symbols, such as `kernel_restart_prepare` and
  `device_shutdown`, are correctly reported as missing.

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
kernels decompress to `vmlinux.bin` linked at 0x80010000. The 2.0.7 row
came from running `build.sh` with `STOCK_MODULES` and `STOCK_XIMAGES` also
pointing at the 1.9.9-1.3.0 package's `kernel-2.0.7` rootfs `module_driver/`
and `xImage`, which were extracted outside the repo. The `~/ing/out` config
already sets `DEBUG_SPINLOCK=y`, which puts `init` at 0xe0 as in stock, so
no separate build config was needed. The module never touches
config-dependent kernel structs: it finds the file size by reading to EOF,
not from `struct inode`. It reaches `kernel_restart_prepare`, which is not
exported, through the `krp=` address, and checks that address with
`sprint_symbol` before staging.

## Usage (on stock, over SSH)

Put `chainload.ko`, `c5-chainload.sh` and the OpenWrt `kernel.uimage` in
one directory, normally `/usr/data/opencreator-os/chainload/`. The installer
puts them there.

```
sh c5-chainload.sh args /dev/mmcblk0p2      # print cmdline, safe_max, krp, watchdog, commit decision; changes nothing
sh c5-chainload.sh stage /dev/mmcblk0p2     # insmod + stage; harmless
sh c5-chainload.sh status
sh c5-chainload.sh unstage                  # or:
sh c5-chainload.sh go                       # no return; SSH drops
```

`stage ROOTDEV [IMAGE]` does the following:

- Refuses to run unless `uname -r` is `5.10.186+`, and refuses a `ROOTDEV`
  that is the running stock root.
- Warns if `ROOTDEV` is not a block device under stock, or does not start
  with `hsqs`.
- Builds the new command line from `/proc/cmdline`: it replaces `root=`,
  keeps `init=/linuxrc`, `rootfstype=squashfs`, `mem=`/`rmem=` and the
  rest (minus any `c5.*` words), and appends `rootwait` and
  `ieee754=relaxed` if they are missing. The OpenWrt kernel puts its
  built-in prefix (`CONFIG_CMDLINE`, with `console=tty0 fbcon=rotate:3` for
  the boot log on the panel) in front of this line as it does in front of
  the SPL's, so a test boot shows the same screen console. Adding
  `console=tty0` here would put it after `console=ttyS0` and make the panel
  `/dev/console`.
- Decides whether a healthy test boot may commit the slot (make it the SPL's
  boot slot; OpenWrt's `c5-booted` does that). This is allowed only when
  `ROOTDEV` is the GPT `rootfs`/`rootfs2` partition (looked up with
  `fdisk -l`) and `IMAGE` is a uImage whose size is exactly 64 + `ih_size`
  and which is byte-identical (sha256, else md5) to the start of the paired
  `kernel`/`kernel2` partition. In every other case `c5.nocommit=1` is
  appended, and the test boot leaves the flag alone. `stage` prints the
  decision as `commit:`.
- Reads `krp` from `/proc/kallsyms`. If the addresses read as zero, it lifts
  `kptr_restrict` briefly.
- Computes `safe_max` from `/proc/iomem`: the end of the first `System RAM`
  range below 256 MiB, minus 16 MiB, rounded down to 1 MiB.
- Passes `wdt=` from `C5CL_WDT` (seconds from the jump until the watchdog
  resets a hung kernel; default 120, 0 = off). Anything but a number from 0
  to 1431 is refused. `args` prints it as `watchdog=`, `stage` and `status`
  show it too.
- Runs `insmod` and prints the module's `chainload:` dmesg lines.

`go` runs detached, through `setsid`, `nohup` or a plain background job with
SIGHUP ignored, and writes its progress to `/dev/console`. In order, it:

1. Kills `firmwareExe`, klippy, moonraker and opencreator processes, then
   `wpa_supplicant`, `hostapd`, `udhcpc` and `dhcpcd`.
2. Syncs and remounts `/usr/data` and `/usr/prog` read-only (stock `/etc` is
   on the same partition as `/usr/prog`), and unmounts `/mnt`.
3. Downs `wlan0`, `wlan1` and `eth0`, and unloads `8821cu`, `rtl8188fu` and
   `soc_mac_driver`.
4. Unbinds the dwc2 USB controllers. USB and the network do DMA into RAM.
5. Offlines cpu1 and writes `go`.

SSH stays up until the network goes down, just before the jump.

For a test with nothing on the eMMC, write `root.squashfs` raw to the first
partition of a USB stick and use `stage /dev/sda1`. For the installed spare
slot, use the slot's `rootfs` device. On the observed printer stock runs
from slot 2 (`/dev/mmcblk0p4`), so OpenWrt goes to slot 1 (`/dev/mmcblk0p2`).

Paths can be overridden for testing: `C5CL_CMDLINE`, `C5CL_IOMEM` and
`C5CL_KALLSYMS` replace `/proc/cmdline`, `/proc/iomem` and `/proc/kallsyms`
for `args`; `C5CL_DISK`, `C5CL_FDISK` and `C5CL_DEVROOT` (a prefix for
reading partition devices) affect the commit decision.

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

Nothing on the eMMC or in the `ota` boot flag changes during `stage` or `go`,
so any reset or power cycle boots the installed stock slot as before.
`stage` alone changes nothing; `unstage` removes the module.

A hung test kernel resets by itself: `go` arms the SoC watchdog for `wdt`
seconds (`C5CL_WDT`, default 120; the `go` message names the value). If
nothing feeds it, the SoC resets and the SPL boots the flagged (stock) slot.
The SPL disables the watchdog on boot, so normal boots are unaffected. The
opencreator-os kernel keeps a watchdog it finds running fed
(`kernel/patches/0005`, with `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` the
watchdog core pings it every half timeout) until procd opens
`/dev/watchdog` and feeds it itself. A kernel that does not feed a running
watchdog is reset after `wdt` seconds even if it boots; stage such an image
with `C5CL_WDT=0`. With `C5CL_WDT=0` nothing is armed and a hung kernel needs
a power cycle. Once OpenWrt runs, it sends an unhealthy test boot back to
stock itself (`docs/recovery.md`).

Not verified on hardware: the register sequence follows the SDK sources, and
QEMU has no X2600 watchdog.

## Risks

- A reboot notifier or device shutdown hook in stock's out-of-tree drivers
  could reset the board. In that case the test ends in a normal stock boot.
- The cache flush assumes that Config1/Config2 describe L1 and L2 (index
  ops). kiln-os has verified this on the same X2600.
- cpu1 is offlined under stock. The new kernel's SMP code resets and starts
  it again.
- The new system may write `/data` (stock `userdata`, ext4 with a journal),
  as any boot does.
