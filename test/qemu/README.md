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
| OpenWrt userland, base-files (`slot.sh`, preinit hooks, `c5-booted`, `c5-slot`, `c5-restore-stock`, `c5-usb-recovery`, `platform.sh`, sysupgrade, fstools overlay, uci-defaults) | real: the build's `root.squashfs`. By default the working tree's `feed/x2600/base-files` are laid over it (`QEMU_REFRESH_ROOTFS=0` tests the artifact unchanged). |
| Stock userland: busybox 1.31.1, glibc, `fdisk`, `e2fsck`, `mount_mmc_ext4.sh`, `S08mdev`/`S09mount_mmc_prog`/`S21mount_mmc_ext4`, the USB hook part of `app_startup.sh` | real, from the archive (rebuilt as a squashfs; git loses empty directories, so the skeleton mount points are recreated) |
| Installer (`runFirmwareExe.sh`, `install.sh`, `lib.sh`, `switch-to-openwrt.sh`, the stick's static `bin/sfdisk` and `bin/partx`), restore stick, `tools/make-install-stick.sh`, `tools/make-restore-stick.sh` | real, run by stock's hook from a FAT32 USB stick image |
| os-installer app | `fixtures/fake-ui.sh` answers the installer's screen protocol (`--ui`) from `qemu/ui.conf` on the stick and echoes every request to the console as `QEMU-UI ...`; `fixtures/qemu-ui-hook.sh` replaces the stick's `runFirmwareExe.sh` on UI sticks (`make_ui_payload`). Sticks without it run the real hook headless |
| eMMC | `sd-card` on `sdhci-pci`, 2 GiB (QEMU needs a power-of-two size): names and starts of p1-p7 and sizes of p1-p6 exactly as on the printer (8-entry GPT). Two images: the stock layout (`new_stock_disk`; p7 `userdata` ends at the primary header's last usable LBA 3,952,639, which also is its alternate LBA, no backup GPT, as on the printer) and the layout the installer leaves (`new_disk`; p7 shrunk to 304 MiB, p8 `c5os` 384 MiB, backup GPT at the disk end). The installer gets `C5_C5OS_MIB=384` instead of the printer's 4096 |
| SPL | `spl_root` in `lib/harness.sh`: `ota:kernel2` in the first 11 bytes of `ota` -> `root=/dev/mmcblk0p4`, else `/dev/mmcblk0p2`; the command line is the SPL's fixed one without the X2600 memory map (`mem=`, `rmem=`, `rtos_size=`, `lpj=`) plus the product kernel's built-in `ieee754=relaxed` |
| Kernel | mainline Linux 6.6.58 for QEMU malta (`kernel/malta.config`), everything built in. Neither the X2600 kernel nor the stock 5.10 kernel run in QEMU. Its DT's first root `compatible` is `flashforge,creator5pro` (as in `kernel/dts/creator5pro.dts`), so OpenWrt's `board_name`, `board.d` (lan = eth0 DHCP) and fwtool's `supported_devices` check behave as on the printer |
| Network | `-nic user,model=pcnet,restrict=on`: eth0 (in OpenWrt's `br-lan`) gets 10.0.2.15 by DHCP, which `c5-booted` needs (global IPv4 + dropbear on :22) before it commits - on the printer that is normally Wi-Fi. Wi-Fi credentials come from the usershare `wpa_supplicant.conf` via the installer, as on the printer |
| chainload | `fixtures/fake-c5-chainload.sh` replaces `chainload/c5-chainload.sh` on test sticks (checksums re-made). It embeds the repo's `c5-chainload.sh` and runs its `args` on stock to compute the command line (`root=`, `c5.nocommit=1` when the staged kernel is not the slot's own, ...); `go`/`go-now` print `QEMU-CHAINLOAD root=<dev> cmdline=<...>` and power off; the harness boots OpenWrt with exactly that command line and the eMMC as left - what a RAM chainload does |
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
| S1 | default install from the stock USB hook: slot 1 written and read back, overlay header cleared, flag untouched, stock slot saved to `userdata/opencreator-os/stock/`, `wifi.conf` from usershare's `wpa_supplicant.conf`, hook exits non-zero so stock boots on |
| S2 | `--chainload` stick: install, fake jump to `root=/dev/mmcblk0p2`, OpenWrt boots with the flag still on stock: tryboot arms stock, overlay created, `/data` = c5os (p8), `wifi.conf` imported, dropbear up, `c5-booted` commits (`ota:kernel`), bootlog (ota+64 KiB) and `/data/opencreator-os/logs` written |
| S3 | SPL boots OpenWrt: tryboot re-arms stock, `c5-booted` commits again; a file written in one boot survives the next (overlay) |
| S4 | `tryboot-fail-test` marker: `c5-booted` reports NOT healthy, flag stays on stock, SPL boots stock, `switch-to-openwrt.sh` (stick) flips back, healthy boot commits |
| S5 | sysupgrade: garbage refused with nothing written; second image (same kernel, root + `/etc/qemu-test-version`, fwtool metadata copied) written, flag left on stock with `pending-commit` on c5os and `chainload/kernel.uimage` on userdata; SPL boots stock; chainload test boot commits it, hostname survives, marker and `sysupgrade.tgz` (c5os) consumed. Power cut (QEMU killed at "Writing rootfs"): flag on stock and the next boot is stock |
| S6 | `c5-restore-stock --dry-run` then `--reboot` from OpenWrt repairs a damaged stock slot exactly, flag -> stock, stock boots. OpenWrt USB recovery hook (`opencreator-os-recovery/restore.conf` = `restore-stock`) does the same before `c5-booted`. Power cut during `c5-restore-stock`: flag on OpenWrt, stock marked invalid (ota+128 KiB), next boot is OpenWrt without a fallback to the half-written stock, re-running the restore completes and clears the mark |
| S7 | stock-side restore stick (`tools/make-restore-stick.sh --slot1 --flag-stock`) from a backup taken of the pristine (repartitioned, c5os) image restores slot 1 over OpenWrt, flips the flag, reboots; stock boots from slot 1; the stick does nothing the second time |
| S8 | corrupted `root.squashfs` on the stick: installer aborts on the checksum, nothing written, flag unchanged, stock boots on |
| S9 | power cut (QEMU killed) while the installer writes the rootfs: flag still on stock, `install-pending` left on userdata, the next boot is stock and the same stick finishes the install |
| S10 | chainload test of a kernel that is not slot 1's own: command line carries `c5.nocommit=1`, OpenWrt boots, `c5-booted` does not commit, flag stays on stock |
| S11 | zero-write USB test stick (`tools/make-test-stick.sh`, fake chainload swapped in): stock's hook stages `root=/dev/sda2 c5.usbtest=1 c5.nocommit=1`; OpenWrt boots from the stick and writes `opencreator-os-test/openwrt/summary.txt` (PASS for root, overlay, emmc, data, wifi-conf, ipv4, ssh, fpu; uarts/heartbeat/watchdog/Wi-Fi FAIL in QEMU) with the whole eMMC image byte-identical across the OpenWrt boot. A second boot says `already attempted`; a corrupted `kernel.uimage` is refused. Across the stock boots GPT and p1-p5 stay byte-identical and usershare/userdata keep their files (their superblocks change because stock itself fscks and mounts them read-write) |
| S12 | full touchscreen flow on the stock layout (UI stick, 3 GiB): menu -> backup prompt -> whole-eMMC backup to `emmc-backup/` (every image checked against the recorded sums and the pre-boot image) -> c5os prompt (5 s delay) -> userdata shrunk, GPT rewritten (backup header at the disk end, MBR boot code and SPL area untouched, p1-p6 unchanged), kernel told with partx, c5os formatted, userdata files kept -> install -> chainload; OpenWrt then mounts c5os at `/data`, sees a valid backup GPT and commits |
| S13 | refusals on the stock layout: userdata too full -> `BLOCK c5os-space` before the menu, nothing written, no backup; an `ok` before the c5os prompt's 5 s delay is treated as cancel; a cancelled c5os prompt aborts with nothing written |
| S14 | Swap from the menu: stock -> OpenWrt (flag `ota:kernel`, reboot), stock running with the flag on OpenWrt -> Swap to stock (flag back, stock boots on), and Swap disabled and refused when OpenWrt is not installed |

## Not covered

- The X2600 kernel (`kernel/`, DTS, config), its drivers (MMC timing, UARTs
  `ttyS2/4/5/7`, USB host/OTG, Ethernet, Wi-Fi RTL8821CU and its power pin,
  watchdog) and kernel modules: QEMU runs a malta kernel.
- `chainload.ko` and the real jump (`c5-chainload.sh` stage/go): faked.
- The real SPL (binary code in the first MiB), its `ota` parsing beyond the
  documented 11-byte compare, memory map and boot timing.
- GPIO (PC11 heartbeat), the framebuffer and touchscreen (`/dev/fb0` is absent;
  the os-installer app is replaced by `fixtures/fake-ui.sh`), Wi-Fi
  association (`wireless.c5sta` needs a radio), network and SSH logins.
- The stock 5.10 kernel's behaviour (mount options, devtmpfs, timing); stock
  services after the USB hook (UI, Klipper, network, adb).
- eMMC wear, write caching and power loss inside the device: a QEMU kill
  loses only what the guest had not written yet.
