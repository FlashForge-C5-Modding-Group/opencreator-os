# QEMU system tests

`test/qemu/run.sh [SCENARIO...]` tests install, boot, fallback, upgrade and
restore using OpenWrt `root.squashfs`, stock 2.0.0 userspace, an emulated
eMMC with the printer's GPT, and emulated SPL slot selection.
It prints `PASS` / `FAIL` / `SKIP` per scenario and exits 1 on failure.
It does not access the printer or require root.

```sh
# from the repo root; first run downloads and builds the QEMU kernel
test/qemu/run.sh            # all scenarios, 8 at a time on 16 CPUs (about 14 min)
test/qemu/run.sh -j 1       # one after the other (about 50 min)
test/qemu/run.sh S1 S8      # stock-side only, a few minutes
```

`-j N` or `QEMU_JOBS=N` runs N scenarios concurrently, defaulting to half
the host CPUs. Each has its own run directory and QEMU instance using one
host CPU under TCG. Scenarios using `prepare_committed` wait for S2's image;
without S2, the first builds it and the others wait. Remaining scenarios
start longest first, using the last passing durations in
`$QWORK/scenario-times`. Terminal output is prefixed by scenario;
`scenario.log` contains only that scenario. S12's whole-eMMC backup takes
12–14 minutes; the rest finish in about 10 minutes.

## Prerequisites

- Host tools: `qemu-system-mipsel` (built with io_uring, as Ubuntu's is;
  otherwise set `QEMU_AIO=threads`), `python3`, `sgdisk`, `sfdisk`,
  `mkfs.ext4`/`debugfs` (e2fsprogs), `mkfs.vfat`, mtools (`mcopy`, `mtype`,
  `mdir`), `mksquashfs`/`unsquashfs`, `git`, `curl`, `flock` (util-linux),
  bash 5.1 or newer.
- A MIPS cross compiler for the QEMU kernel: the OpenWrt toolchain from
  `./build.sh` or `~/ing/mips-xburst2-linux-toolchain-r6.0.0` (or set
  `CROSS_COMPILE`).
- OpenWrt artifacts: `*x2600-generic-flashforge_creator5pro*-root.squashfs`
  with matching `-kernel.uimage` and `-sysupgrade.tar`. Set `OWRT_BIN=DIR`
  to choose a directory. Default: the newest matching build under
  `$OWRT_BUILDS` (default `/mnt/f/creator5-dev/opencreator-os-builds`), falling back
  to `$OWRT_DIR/bin/targets/x2600/generic`.
  S5 also needs `$OWRT_DIR/staging_dir/host/bin/fwtool`.
- `chainload/out/chainload.ko` (only copied around, never loaded).
- The stock firmware archive checkout at
  `/mnt/f/creator5-dev/creator-5-pro-firmware-archive` by default (`STOCK_ARCHIVE`).

`QWORK` defaults to `~/build/opencreator-os/qemu/` and holds the kernel
tree, `vmlinux`, stock root squashfs, 2 GiB base eMMC image,
`scenario-times`, and `runs/<timestamp>/<scenario>/`. Each run keeps serial
logs (`*.log`), command results (`*.res`), step files, `scenario.log` and
per-OpenWrt-boot full-userdata hashes (`*.userdata.sha256`).
Passed images are deleted; failed images are kept. Only the last
`KEEP_RUNS` run directories are kept, default 3. Concurrent runs require
different `QWORK`s.

## Rerunning and logs

Reruns reuse the downloaded sources, kernel object directory and completed
QEMU kernel/modules in `QWORK`. A kernel config or build-script change can
trigger an incremental build using those objects. Fixture changes refresh
the test rootfs; they do not rebuild the OpenWrt image or the 5.10 chainload
kernel. Scenarios run again on each invocation.

S12 streams backup chunks directly from the FAT stick into the host-side
checksums instead of extracting another complete eMMC copy. Its temporary
eMMC and stick drives use QEMU `cache=unsafe`: guest sync/reboot and all
backup readback checks still run, but host-media flushes are skipped. S12
does not simulate power cuts; other scenarios keep QEMU's default cache
policy. This does not change fixtures or the printer's partition geometry.

Rootfs refreshes use a new temporary staging directory rather than reusing
an old `openwrt-stage`. Extraction, copying, permissions and packing errors
abort setup; only missing OpenWrt artifacts intentionally skip scenarios.

Run the tests as your normal user, not with `sudo`. If an earlier root run
left your own `QWORK` cache root-owned, restore its ownership without
deleting the cached builds:

```sh
sudo chown -R -- "$(id -u):$(id -g)" "${QWORK:-$HOME/build/opencreator-os/qemu}"
```

Per-scenario stick assembly is saved in
`$QWORK/runs/<timestamp>/<scenario>/make-install-stick.log`. Kernel builds
and fixture preparation print to the terminal. To capture the whole run
and preserve its failure status:

```sh
set -o pipefail
test/qemu/run.sh 2>&1 | tee "$HOME/qemu-run.log"
```

## What is real and what is emulated

| Piece | In the tests |
|---|---|
| OpenWrt userland and base-files | Build's `root.squashfs`: `slot.sh`, preinit, `c5-booted`, `c5-usb-hook`, fixed fstab, `platform.sh`, sysupgrade, fstools overlay and uci-defaults. Working-tree `feed/x2600/base-files` is applied by default, including deletions and init-link updates. `QEMU_REFRESH_ROOTFS=0` tests the unchanged artifact. |
| Stock userland | Archived busybox 1.31.1, glibc, `fdisk`, `e2fsck`, `mount_mmc_ext4.sh`, `S08mdev`/`S09mount_mmc_prog`/`S21mount_mmc_ext4` and the USB hook in `app_startup.sh`, rebuilt as squashfs with missing empty mount directories recreated. |
| Installer and restore stick | Real `runFirmwareExe.sh`, `install.sh`, `lib.sh`, image base-files `slot.sh`, static `bin/sfdisk` and `bin/partx`, `tools/make-install-stick.sh` and `tools/make-restore-stick.sh`. Stock and OpenWrt hooks run them from FAT32 stick images with model `Creator5Pro 0029`. |
| os-installer app | `fixtures/fake-ui.sh` implements `--ui` using stick file `qemu/ui.conf`: `menu=N` sets every MENU response, overridden by `menu_<id>=N`; `confirm_<id>=ok\|early\|cancel`; `hold=<id>` creates `/tmp/qemu-ui-held` and waits for `/tmp/qemu-ui-release`. Requests print as `QEMU-UI ...`; BLOCK taps print `QEMU-UI-TAP <button>` and exit 1. UI sticks use `fixtures/qemu-ui-hook.sh` via `make_ui_payload`, replacing `runFirmwareExe.sh`: app exit 1 returns 1; installer exit 0 ends immediately; other installer exits print `QEMU-UI-CONTINUE <status>` and simulate tapping Continue. Other sticks use the real headless hook. |
| eMMC | 2 GiB `sd-card` on `sdhci-pci`; size must be a power of two. The 8-entry GPT matches printer p1–p7 names/starts and p1–p6 sizes. `new_stock_disk`: p7 `userdata` ends at LBA 3,952,639, also the primary header's last usable and alternate LBA, with no backup GPT. `new_disk`: p7 = 272 MiB, p8 `c5os` = 416 MiB, backup GPT at disk end. `C5_C5OS_MIB=416` replaces the printer's 4096, leaving room for saved stock and chainload plus the product's 256 MiB swap file and unchanged 64 MiB free-space requirement. Synchronous 512-byte SD transfers limit S12 backup speed to about 8 MB/s with `aio=io_uring`, 4 MB/s with threads. |
| SPL | `spl_root` in `lib/harness.sh` selects `root=/dev/mmcblk0p4` when `ota` starts with the 11 bytes `ota:kernel2`, otherwise `/dev/mmcblk0p2`. The SPL command line omits X2600 `mem=`, `rmem=`, `rtos_size=` and `lpj=`. Both stock and OpenWrt boots prepend `CONFIG_CMDLINE` from `kernel/creator5pro.config`: `ieee754=relaxed console=ttyS0,115200n8 console=tty0 fbcon=rotate:3 vt.global_cursor_default=0`. Chainload carries this prefix once. QEMU has a VT but no display; serial remains `/dev/console`. |
| Kernel | Mainline Linux 6.6.58 for Malta, configured by `kernel/malta.config`. Everything is built in except `usbnet` and `cdc_ether`: `kernel/build.sh` builds modules and the harness installs them in `/lib/modules/6.6.58` for the image's kmod-usb-net autoload entries. Neither printer kernel runs. DT root `compatible` starts with `flashforge,creator5pro`, matching `kernel/dts/creator5pro.dts` for `board_name`, `board.d` eth0 DHCP and fwtool `supported_devices` checks. |
| Network | `-nic user,model=pcnet,restrict=on`; eth0 in `br-lan` gets 10.0.2.15 by DHCP. S16 substitutes CDC Ethernet `usb-net` on xHCI with `QEMU_USB_NIC=1`. Boot health requires `c5-booted` with c5os mounted, not networking. Wi-Fi credentials pass from usershare's `wpa_supplicant.conf` through the installer and c5os. |
| chainload | Test sticks substitute `fixtures/fake-c5-chainload.sh` and regenerate checksums. It embeds the real script and runs `args` on stock to compute `root=`, commit eligibility (`c5.nocommit=1` for a non-slot kernel) and `watchdog=`. `go`/`go-now` print `QEMU-CHAINLOAD root=<dev> cmdline=<...>` and power off. The harness boots OpenWrt with that command line and unchanged eMMC state. Booting stock instead simulates a hung-kernel watchdog reset. |
| Stock init | Real stock busybox `init` with `fixtures/stock/inittab`: stock sysinit lines, then synchronous `/qemu-stock-init` for mdev, mount scripts and the hook instead of rcS. A successful hook stalls sysinit; pending plain reboots and `/qemu-stock-finish` poweroff require it to return. |
| Stock SSH actions | Harness writes `/usr/data/qemu-action.sh` into userdata with debugfs; `/qemu-stock-init` runs it once after the hook returns. |
| OpenWrt console actions | `lib/qemu-run.py` drives `askconsole` over serial using a quiet `read` loop piped into `sh`. |

Test-only deviations outside product code:

- `/qemu-stock-init` exports `C5_UNAME_R=5.10.186+` for installer/restore
  release checks, and `C5_C5OS_MIB=416` for the 2 GiB card.
- `qemu_stick=1` makes stock init wait up to 60 s for USB instead of 2 s.
- S14's healthy UI boot uses `C5_TEST_DEADLINE=600` through `slot.sh`'s test
  override. Malta/TCG clock and delay calibration under parallel load can
  exceed the printer's 180 s deadline. Host waits remain bounded.
  S2 checks the default 180 s deadline; S15 uses 10 s for failure.
  Printer behavior and kernel `lpj` are unchanged.
- Stock's post-hook `sleep 100000` prints `QEMU-STOCK-HOOK rc=0 stall` and
  loops forever without returning from `app_startup.sh` or releasing
  sysinit. Real busybox init/reboot remain in use; a plain reboot stays
  pending behind the stall.
- `kernel/build.sh` patches the Malta DT compatible and accepts Malta
  in any compatible entry.
- CPU `24Kf` is MIPS32r2 with a 64-bit FPU. `ieee754=relaxed` supports
  both stock NaN2008/FP64 and OpenWrt legacy-NaN userland.
  Do not use `P5600`: block-device reads are corrupt under this kernel.

## Scenarios

Stock boots have a default 180 s expectation timeout and 240 s VM-exit
timeout; S12 allows longer for backups and partition work. Both stock step
helpers accept `reboot: Restarting system`, stock-completion and
fake-chainload markers. A pending reboot blocked by the hook stall times
out rather than counting as completion.

Each real OpenWrt run uses `boot_openwrt`: hash all of p7 (`userdata`,
including filesystem metadata and journal) before starting QEMU, then
compare again immediately after QEMU exits. This covers healthy boots,
same-/changed-kernel upgrades, repair, fallback and interrupted writes.
The second hash is taken **before the next stock boot**: stock legitimately
mounts userdata read-write and changes its journal. Hash equality proves
byte-for-byte preservation, not absence of reads or read-only mounts.
S17 additionally inspects the actual migration mount's `ro,norecovery`
(`ro,noload`) options and checks that it is gone before normal repair.


| | |
|---|---|
| S1 | Headless stock-hook install writes and reads back slot 1, clears the overlay header, preserves the flag, and saves stock in `c5os/opencreator-os/stock/`. `wifi.conf`, model `Creator5Pro 0029` and matching `pending-commit` go to c5os. Without `good-kernel`, it stages slot 1's uImage in `c5os/opencreator-os/chainload/`, records c5os `last-test` = `started qemu-test`, and chainloads. Normal `install.state`, `install.log`, stock and chainload files live on c5os, not userdata; only the pre-c5os stock log and partition-reboot marker may use userdata. The fake jump observes c5os remounted read-only at `/tmp/c5os-config`. A simulated watchdog reset boots stock; the headless stick logs the hung test, marks it seen and continues stock without retry or flag change. |
| S2 | Install chainloads `root=/dev/mmcblk0p2` with the stick inserted. Preinit leaves the counter unchanged and starts the 180 s deadline, which remains active after `c5-booted`. Overlay is created, fstab mounts c5os p8 by label at `/data`, Wi-Fi imports, hostname is `creator5pro`, and dropbear starts. A healthy boot resets tries, commits matching pending install, records `last-test` ok, `good-kernel`, bootlog and c5os logs. START=19 defers the USB hook until `c5-booted`; its detached headless run logs `installed ... (no display)` to stick/syslog and marks it seen. `c5-swap` creates `/data/swapfile` mode 600 and activates it in `/proc/swaps`. A temporary lan DNS setting plus `ifup lan` reaches jailed ntpd's `/etc/resolv.conf` through `20-c5-ntp` restarting sysntpd; restricted slirp supplies no DNS. IPv4/IPv6 forwarding stay zero after boot and lan `ifup`. |
| S3 | SPL boots retain the OpenWrt flag. A healthy third attempt resets the counter; the next boot starts at one. No redundant flag commits; overlay files survive reboot. |
| S4 | Three boots killed after preinit increment the counter and retain OpenWrt. The fourth selects stock, resets the counter, records `last-test` = `failed ... boot counter: 3 boots of slot 1 did not become healthy`, and reboots. The headless stock stick reports and marks it seen. With stock marked invalid, the fourth attempt retains OpenWrt; a healthy boot resets tries. |
| S5 | Same-kernel sysupgrade boots the new root directly, retaining the OpenWrt flag without pending commit or stale c5os staged kernel. App "Update / Repair OpenWrt" accepts the same build, restores image `/etc/config/fstab`, and preserves user `uci` settings. A changed valid uImage header takes test-then-commit through the stock hook/app: stock flag, pending commit and staged kernel on c5os, stock boot and chainload. The stock SSH action mounts c5os read-only at `/tmp/c5os-config` and uses its chainload script. Hostname and `/etc/c5/wifi.conf` survive through keep.d; backup and marker are consumed. Both app updates stay on "Updating OpenWrt", not FAILED; procd does not answer a started upgrade. Garbage is refused without writes. A power cut during changed-kernel rootfs writing leaves stock bootable. Full userdata hashes bracket each OpenWrt run, including the upgrade and commit separately. |
| S6 | OpenWrt's headless hook accepts CRLF `opencreator-os/ACTION=repair-stock`, reads saved stock directly from `/data/opencreator-os/stock`, repairs damaged stock byte-for-byte, selects it and boots it. Full userdata hashes are compared after each OpenWrt repair run exits and before stock boots. A repair power cut retains OpenWrt and the invalid-stock mark; the same stick completes repair on the next run. `ACTION=swap` boots stock only if selectable. At the UI menu, `c5-booted`, dropbear and lan are already running. Repair stock confirms after 5 s; Cancel writes nothing and shows Continue; ok repairs and shows "Rebooting into stock", reboots, and ends the app without Continue. |
| S7 | `tools/make-restore-stick.sh --slot1 --flag-stock` uses a pristine repartitioned/c5os backup to restore slot 1 over OpenWrt, select it, and reboot into stock slot 1. A second run does nothing. |
| S8 | A corrupt stick `root.squashfs` fails checksum validation without writes or flag changes; stock continues booting. A separate image with c5os filled by debugfs fails the capacity preflight before any slot write, saved-stock copy or flag change. |
| S9 | Killing QEMU during rootfs writing leaves the stock flag and c5os `install-pending`. The next stock boot with the same stick finishes installation and test-boots slot 1. |
| S10 | A chainloaded non-slot-1 kernel gets `c5.nocommit=1`. Preinit logs `test boot (c5.nocommit=1); counter and flag untouched`; `c5-booted` does not commit and the flag remains stock. |
| S12 | Stock-layout UI flow with a 3 GiB stick: menu → whole-eMMC backup with verified recorded sums → delayed c5os prompt → userdata shrink/GPT rewrite preserving MBR/SPL and p1–p6 → install → chainload. Model, Wi-Fi override and authorized keys reside only on c5os and import into `/etc`. OpenWrt mounts c5os by label at `/data`, validates backup GPT and commits. A separate run forces stick `partx` failure without changing the GPT write or kernel partition view: installer records `c5os-rebooted` and reboots inside sysinit; the same stick completes c5os setup next boot, clears the marker and chainloads. |
| S13 | Full userdata blocks before the menu; "Boot to stock" continues stock. Early/cancelled c5os prompts write no partitions. An unknown hook model is rejected in a running stock system with no eMMC writes, checked by the whole-device sectors-written counter. |
| S14 | Stock UI shows "OpenWrt test failed" / `hung before OpenWrt started (watchdog reset)`; "Try again" opens the menu. Swap with an untested kernel recreates `pending-commit` and test-boots the slot's kernel with the UI stick inserted. A healthy boot commits and records `last-test` ok before showing "OpenWrt installed". Reboot shows "Rebooting into OpenWrt", ends the app without Continue, reboots and marks it seen. The next SPL boot shows the normal OpenWrt menu. Swap to stock continues stock; swap without an installation is disabled/refused. A headless stick that already started OpenWrt does not repeat it when the flag returns to stock. Reinstalling the same known-good build through the app selects OpenWrt directly, records `last-test` started, shows "Rebooting into OpenWrt", ends without Continue and reboots from stock. A later stock-side Swap with the known-good kernel also selects it directly and reboots without chainload or Continue. |
| S15 | Relabelled c5os prevents `/data` mounting; `c5-booted` immediately fails the test with `reboot -f`, retains the stock flag, records `last-test` failed with reason, and removes `pending-commit`. No stock-invalid mark; counter, stock slot and userdata are untouched. Stock UI shows "OpenWrt test failed" with the reason; "Boot to stock" bypasses the menu, boots stock and marks it seen. A subsequent app Swap test with `C5_TEST_DEADLINE=10` fails identically at the deadline. |
| S16 | USB `usb-net` Ethernet at boot, no PCI NIC, refreshed root required: image autoload entries load `usbnet`/`cdc_ether`, the adapter becomes eth0, and `br-lan` gets 10.0.2.15. `wpa_supplicant` runs; `hostapd` and `urngd` do not. |
| S17 | Converts a prepared committed image into the old userdata-only saved-stock layout with debugfs. The new installer first refuses a stock repair because the c5os source is absent (no fallback). Runs the documented explicitly authorized one-off migration: discover partitions, mount userdata `ro,noload`, dry-verify source, copy to c5os `stock.new`, dry-verify, rename, dry-verify final, unmount. The actual read-only/no-replay mount is recorded; dry migration leaves both stock slot partitions, boot flag and invalid marker unchanged. Releasing the held new installer repairs damaged stock from `/data/opencreator-os/stock`, selects stock and reboots. The full userdata partition is unchanged across this entire OpenWrt boot, checked before the repaired stock boot. |

## Not covered

- X2600 kernel, DTS, config, modules and drivers: MMC timing, UARTs
  `ttyS2/4/5/7`, USB host/OTG, Ethernet, RTL8821CU Wi-Fi/power pin and
  watchdog.
- `chainload.ko`, real `c5-chainload.sh` stage/go, watchdog arming,
  `kernel/patches/0005` watchdog feeding and hardware watchdog resets.
- SPL binary in the first MiB, `ota` parsing beyond the 11-byte compare,
  memory map and boot timing.
- PC11 heartbeat GPIO, framebuffer, touchscreen and the real os-installer
  app. QEMU has no `/dev/fb0`.
- Wi-Fi association (`wireless.c5sta` needs a radio), network and SSH logins.
- Stock 5.10 kernel behavior, including mount options, devtmpfs and timing;
  stock services after the USB hook: UI, Klipper, network and adb.
- eMMC wear, write caching and internal power loss. Killing QEMU loses
  only writes the guest has not submitted.
