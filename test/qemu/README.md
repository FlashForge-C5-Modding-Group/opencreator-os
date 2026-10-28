# QEMU system tests

`test/qemu/run.sh [SCENARIO...]` boots the real OpenWrt `root.squashfs` and
the stock 2.0.0 userspace in QEMU on an emulated eMMC with the printer's GPT,
emulates the SPL's slot choice, and runs install, boot, fallback, upgrade and
restore scenarios end to end. It prints `PASS` / `FAIL` / `SKIP` per scenario
and exits 1 if any scenario failed. Nothing touches the printer and nothing
needs root.

```sh
# WSL, from the repo root; first run downloads and builds the QEMU kernel
test/qemu/run.sh            # all scenarios (about 30 min)
test/qemu/run.sh S1 S8      # stock-side only, a few minutes
```

## Prerequisites

- Host tools: `qemu-system-mipsel`, `python3`, `sgdisk`, `sfdisk`,
  `mkfs.ext4`/`debugfs` (e2fsprogs), `mkfs.vfat`, mtools (`mcopy`, `mtype`,
  `mdir`), `mksquashfs`/`unsquashfs`, `git`, `curl`.
- A MIPS cross compiler for the QEMU kernel: the OpenWrt toolchain from
  `./build.sh` or `~/ing/mips-xburst2-linux-toolchain-r6.0.0` (or set
  `CROSS_COMPILE`).
- OpenWrt artifacts: the newest `/mnt/f/creator5-dev/opencreator-os-builds/*/`
  that holds `*x2600-generic-flashforge_creator5pro*-root.squashfs` with its
  `-kernel.uimage` and `-sysupgrade.tar` (override with `OWRT_BIN=DIR`). S5
  also needs the host `fwtool` from the OpenWrt tree
  (`$OWRT_DIR/staging_dir/host/bin/fwtool`).
- `chainload/out/chainload.ko` (only copied around, never loaded).
- The stock firmware archive checkout at
  `/mnt/f/creator5-dev/creator-5-pro-firmware-archive` (`STOCK_ARCHIVE`).

Fixtures and run directories live under `~/build/opencreator-os/qemu/`
(`QWORK`), outside the repo: the kernel tree and `vmlinux`, the stock root
squashfs, the 2 GiB base eMMC image, and `runs/<timestamp>/<scenario>/` with
every boot's serial log (`*.log`), command results (`*.res`), step files and
`scenario.log`. Images of passed scenarios are deleted; failed ones are kept.
Only the last `KEEP_RUNS` (3) run directories are kept.

## What is real and what is emulated

| Piece | In the tests |
|---|---|
| OpenWrt userland, base-files (`slot.sh`, preinit hooks, `c5-booted`, `c5-usb-hook`, fixed fstab, `platform.sh`, sysupgrade, fstools overlay, uci-defaults) | real: the build's `root.squashfs`. By default the working tree's `feed/x2600/base-files` are laid over it, including removed files and updated init links (`QEMU_REFRESH_ROOTFS=0` tests the artifact unchanged). |
| Stock userland: busybox 1.31.1, glibc, `fdisk`, `e2fsck`, `mount_mmc_ext4.sh`, `S08mdev`/`S09mount_mmc_prog`/`S21mount_mmc_ext4`, the USB hook part of `app_startup.sh` | real, from the archive (rebuilt as a squashfs; git loses empty directories, so the skeleton mount points are recreated) |
| Installer (`runFirmwareExe.sh`, `install.sh`, `lib.sh`, `slot.sh` from the image's base-files, the stick's static `bin/sfdisk` and `bin/partx`), restore stick, `tools/make-install-stick.sh`, `tools/make-restore-stick.sh` | real, run by the stock or OpenWrt USB hook from a FAT32 stick image; both hooks pass `Creator5Pro 0029` |
| os-installer app | `fixtures/fake-ui.sh` answers the installer's screen protocol (`--ui`) from `qemu/ui.conf` on the stick (`menu=N` for every MENU, `menu_<id>=N` for MENU `<id>` before that, `confirm_<id>=ok\|early\|cancel`), echoes every request to the console as `QEMU-UI ...` and taps a `BLOCK` button (`QEMU-UI-TAP <button>`, exit 1 like the app); `fixtures/qemu-ui-hook.sh` replaces the stick's `runFirmwareExe.sh` on UI sticks (`make_ui_payload`) and, like the real hook, exits 1 when the "app" does. Sticks without it run the real hook headless |
| eMMC | `sd-card` on `sdhci-pci`, 2 GiB (QEMU needs a power-of-two size): names and starts of p1-p7 and sizes of p1-p6 exactly as on the printer (8-entry GPT). Two images: the stock layout (`new_stock_disk`; p7 `userdata` ends at the primary header's last usable LBA 3,952,639, which also is its alternate LBA, no backup GPT, as on the printer) and the layout the installer leaves (`new_disk`; p7 shrunk to 304 MiB, p8 `c5os` 384 MiB, backup GPT at the disk end). The installer gets `C5_C5OS_MIB=384` instead of the printer's 4096 |
| SPL | `spl_root` in `lib/harness.sh`: `ota:kernel2` in the first 11 bytes of `ota` -> `root=/dev/mmcblk0p4`, else `/dev/mmcblk0p2`; the command line is the SPL's fixed one without the X2600 memory map (`mem=`, `rmem=`, `rtos_size=`, `lpj=`), behind the product kernel's built-in prefix (`CONFIG_CMDLINE` from `kernel/creator5pro.config`: `ieee754=relaxed` and the screen console `console=ttyS0,115200n8 console=tty0 fbcon=rotate:3`; the QEMU kernel has a VT, the runs have no display, serial stays `/dev/console`). Stock boots get the prefix too, so a chainload line (built from stock's `/proc/cmdline`) carries it once, as the chainloaded X2600 kernel would add it |
| Kernel | mainline Linux 6.6.58 for QEMU malta (`kernel/malta.config`), everything built in. Neither the X2600 kernel nor the stock 5.10 kernel run in QEMU. Its DT's first root `compatible` is `flashforge,creator5pro` (as in `kernel/dts/creator5pro.dts`), so OpenWrt's `board_name`, `board.d` (lan = eth0 DHCP) and fwtool's `supported_devices` check behave as on the printer |
| Network | `-nic user,model=pcnet,restrict=on`: eth0 (in OpenWrt's `br-lan`) gets 10.0.2.15 by DHCP. Boot health requires reaching `c5-booted` with c5os mounted, not a network connection. Wi-Fi credentials come from usershare's `wpa_supplicant.conf` through the installer and c5os |
| chainload | `fixtures/fake-c5-chainload.sh` replaces `chainload/c5-chainload.sh` on test sticks (checksums re-made). It embeds the repo's `c5-chainload.sh` and runs its `args` on stock to compute the command line (`root=`, `c5.nocommit=1` when the staged kernel is not the slot's own, ...; it also prints `watchdog=`); `go`/`go-now` print `QEMU-CHAINLOAD root=<dev> cmdline=<...>` and power off; the harness boots OpenWrt with exactly that command line and the eMMC as left - what a RAM chainload does. Booting stock instead after the fake jump stands for a watchdog reset after a hung test kernel |
| Stock init | stock busybox `init` with `fixtures/stock/inittab`: stock's sysinit lines, then `/qemu-stock-init` (mdev, stock mount scripts, the hook) instead of rcS, then `/qemu-stock-finish` powers off unless something requested a reboot |
| A user on SSH (stock) | `/usr/data/qemu-action.sh`, written into userdata by the harness (debugfs) and run once by `/qemu-stock-init` after the hook |
| A user on the console (OpenWrt) | `lib/qemu-run.py` drives the serial console: OpenWrt's `askconsole` shell, switched to a quiet command channel (a `read` loop piped into `sh`) |

Test-only deviations, all outside the product code:

- `C5_UNAME_R=5.10.186+` is exported by `/qemu-stock-init` (the installer and
  restore stick insist on the stock kernel release; the QEMU kernel is 6.6.58).
- `qemu_stick=1` on the stock command line makes `/qemu-stock-init` wait up to
  60 s for the USB stick: QEMU's xHCI + usb-storage enumerate more slowly than
  stock's 2 s "wait for USB".
- `C5_C5OS_MIB=384` is exported by `/qemu-stock-init` (the 2 GiB card).
- stock's endless `sleep 100000` after a hook exit 0 prints
  `QEMU-STOCK-HOOK rc=0 stall` and ends the hook script instead.
- QEMU malta kernel: the DT compatible above, and malta's DT shim recognises
  malta by any compatible entry (`kernel/build.sh` patches both).
- CPU: QEMU `24Kf` (MIPS32r2 with a 64-bit FPU). The stock userland is
  NaN2008/FP64 and OpenWrt's is legacy-NaN; `ieee754=relaxed` lets one CPU run
  both, as the X2600 kernel does for OpenWrt. `P5600` (NaN2008) would be closer
  but reads corrupt data from every block device under this kernel.

## Scenarios

| | |
|---|---|
| S1 | default (headless) install from the stock USB hook: slot 1 written and read back, overlay header cleared, flag untouched, stock saved to `userdata/opencreator-os/stock/`; `wifi.conf`, hook model `Creator5Pro 0029`, and matching `pending-commit` saved on c5os, not userdata; no `good-kernel` yet, so it plans and starts a chainload test boot of slot 1 with the slot's own uImage copied to `userdata/opencreator-os/chainload/`, after writing c5os `last-test` = `started qemu-test`. Then stock boots again (what a watchdog reset after a hung test kernel leaves): the stick's headless run reports `hung before OpenWrt started (watchdog reset)` in both logs, renames `last-test` to `last-test.seen`, does not retry, and stock boots on with the flag on stock |
| S2 | default install: fake jump to `root=/dev/mmcblk0p2` with the install stick still in; preinit does not count the test boot and arms the 180 s deadline, whose job (started in preinit) still runs after `c5-booted`; overlay created, fixed fstab label mounts c5os (p8) at `/data`, Wi-Fi imported, model-derived hostname `creator5pro`, dropbear up; healthy boot resets tries, commits matching pending install, records `last-test` ok, `good-kernel`, bootlog and c5os logs. The USB hook is deferred at START=19 until `c5-booted`; its headless run logs `installed ... (no display)` and marks it seen |
| S3 | normal SPL boots keep the OpenWrt flag; a third attempt becomes healthy and resets the counter to zero, next boot starts at one; no redundant flag commits; overlay file survives reboot |
| S4 | three boots killed after preinit each count and retain OpenWrt; fourth preinit selects stock, resets counter, records `last-test` = `failed ... boot counter: 3 boots of slot 1 did not become healthy` and reboots; stock boots, and a headless stick's run reports it (seen). With stock marked invalid the fourth attempt never flips, and a subsequent healthy boot resets tries |
| S5 | same-kernel sysupgrade takes the known-good direct path (OpenWrt flag retained, no pending commit) and boots the new root directly. Changed valid uImage header takes test-then-commit: stock flag, pending commit on c5os, staged kernel on userdata, stock boot and chainload, preserved hostname and OpenWrt-edited `/etc/c5/wifi.conf` (keep.d), consumed backup and marker. Garbage is refused without writes; changed-kernel rootfs-write power cut leaves stock bootable |
| S6 | real OpenWrt USB hook runs the install stick headless with `opencreator-os/ACTION=repair-stock` (CRLF accepted): damaged stock repaired byte-for-byte, flag selects stock, stock boots. Power cut during repair retains OpenWrt and the invalid-stock mark; the same stick completes on the next run and stock boots. `ACTION=swap` selects and boots stock, but is refused when stock is not selectable |
| S7 | stock-side restore stick (`tools/make-restore-stick.sh --slot1 --flag-stock`) from a backup taken of the pristine (repartitioned, c5os) image restores slot 1 over OpenWrt, flips the flag, reboots; stock boots from slot 1; the stick does nothing the second time |
| S8 | corrupted `root.squashfs` on the stick: installer aborts on the checksum, nothing written, flag unchanged, stock boots on |
| S9 | power cut (QEMU killed) while the installer writes the rootfs: flag still on stock, `install-pending` left on userdata, the next boot is stock and the same stick finishes the install and test-boots slot 1 |
| S10 | chainload test of a kernel that is not slot 1's own: command line carries `c5.nocommit=1`, OpenWrt boots, preinit logs `test boot (c5.nocommit=1); counter and flag untouched`, `c5-booted` does not commit, flag stays on stock |
| S12 | full touchscreen flow on stock layout (UI stick, 3 GiB): menu -> whole-eMMC backup (recorded sums checked) -> delayed c5os prompt -> shrink userdata and rewrite GPT, preserving MBR/SPL and p1-p6 -> install -> chainload. Model, hand-written Wi-Fi override and authorized keys live only on c5os and import into `/etc`; OpenWrt mounts c5os by label at `/data`, sees a valid backup GPT and commits |
| S13 | full userdata blocks before the menu with a "Boot to stock" button; tapping it lets stock boot on. Early/cancelled c5os prompts abort without partition writes. An unknown hook model is rejected in an existing stock boot without submitting any eMMC writes (the whole-device sectors-written counter stays unchanged) |
| S14 | stock-side Swap to OpenWrt: the stock UI first shows "OpenWrt test failed" / `hung before OpenWrt started (watchdog reset)`, "Try again" goes on to the menu. Swap with an untested kernel recreates `pending-commit`, test-boots the slot's own kernel with the UI stick in: the healthy boot commits, records `last-test` ok, then (after the commit) shows "OpenWrt installed"; Reboot reboots and it is marked seen; the next SPL boot is OpenWrt and shows the normal OpenWrt menu, no installed screen. Swap to stock; swap is disabled/refused without an installation. A headless stick that already started OpenWrt (committed image, flag back on stock) does not again and stock boots on; the same build reinstalled from the app skips the test and selects OpenWrt directly (known-good kernel), recording `last-test` started |
| S15 | failed test boots: c5os relabelled so OpenWrt's fstab cannot mount `/data`: `c5-booted` fails the test at once (`reboot -f`), flag on stock, `last-test` failed with the reason, `pending-commit` removed, no stock-invalid mark; counter, stock slot and userdata untouched. The stock UI stick shows "OpenWrt test failed" with the reason, "Boot to stock" skips the menu and stock boots (seen). Then Swap to OpenWrt from the app, and a test boot with `C5_TEST_DEADLINE=10` on the command line fails at the deadline the same way |

## Not covered

- The X2600 kernel (`kernel/`, DTS, config), its drivers (MMC timing, UARTs
  `ttyS2/4/5/7`, USB host/OTG, Ethernet, Wi-Fi RTL8821CU and its power pin,
  watchdog) and kernel modules: QEMU runs a malta kernel.
- `chainload.ko` and the real jump (`c5-chainload.sh` stage/go): faked. Not
  covered at all: the watchdog it arms, the `kernel/patches/0005` driver
  change that keeps it fed, and a real watchdog reset (QEMU malta has no
  X2600 watchdog).
- The real SPL (binary code in the first MiB), its `ota` parsing beyond the
  documented 11-byte compare, memory map and boot timing.
- GPIO (PC11 heartbeat), the framebuffer and touchscreen (`/dev/fb0` is absent;
  the os-installer app is replaced by `fixtures/fake-ui.sh`), Wi-Fi
  association (`wireless.c5sta` needs a radio), network and SSH logins.
- The stock 5.10 kernel's behaviour (mount options, devtmpfs, timing); stock
  services after the USB hook (UI, Klipper, network, adb).
- eMMC wear, write caching and power loss inside the device: a QEMU kill
  loses only what the guest had not written yet.
