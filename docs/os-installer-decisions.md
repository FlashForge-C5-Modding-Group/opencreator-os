# Storage layout and touchscreen installer decisions

Design reference, not a spec. Labels: **Observed** = seen on a printer or in a
stock file; **Decided** = agreed with the user; **Hypothesis** = not verified.

## Storage

- **Observed:** the eMMC has 15,307,776 sectors. The GPT has 8 entries,
  7 used, and usable sectors 34–15,065,087. `userdata` (p7) ends at
  14,479,359, leaving 585,728 sectors (286 MiB) unallocated within the usable
  range and about 118 MiB beyond it.
- **Observed:** stock's `/usr/bin/mount_mmc_ext4.sh`, run by
  `S21mount_mmc_ext4` for `userdata` and `S09mount_mmc_prog` for `usershare`,
  runs `fsck -y`, then `mkfs.ext4` if mounting still fails. It finds
  partitions with `fdisk -l | grep <name>`.
- **Observed:** stock `/usr/data` uses about 1.0 GB: opencreator 439 MiB,
  bin 362 MiB, python-hf 83 MiB, firmwareRes 45 MiB, gcodes 28 MiB, other
  files about 60 MiB.
- **Decided:** shrink `userdata` to 2,018 MiB and add ext4 `c5os` after it:
  4,096 MiB ending at sector 15,065,087, including the free 286 MiB.
  This isolates OpenWrt data from stock's automatic reformatting.
  - Shrink the filesystem with margin before shrinking the partition.
  - The GPT name must not contain a stock partition name: stock uses `grep`.
  - Keep data partitions within sector 15,065,087; do not move or resize p1–p6.
- **Decided:** OpenWrt keeps `/etc` in its slot overlay; packages, Klipper,
  Moonraker, logs and gcode go on `c5os`. The installer saves Wi-Fi settings,
  optional SSH keys and the model there; preinit imports them before
  uci-defaults. Saved stock images, installer state and the staged chainload
  kernel also live on `c5os`; OpenWrt never mounts stock `userdata`.
  Stock retains only its pre-c5os installer log and partition-reboot marker
  on `userdata`, alongside stock's own files.

## Installer

- **Decided:** `os-installer` is private under the org. It uses
  touchscreen-installer's fb0, Goodix touch, rotation and SDL platform layer,
  LVGL submodule, static NaN-2008 `make mips32` build, `make sdl` build,
  logo, log viewer and progress bar. A generic screen engine follows the
  shell backend.
- **Decided:** all checks and writes belong in
  `installer/opencreator-os/`, covered by QEMU tests. The app only draws
  backend-requested screens. The protocol is documented in `lib.sh`:
  status, progress, confirmation, menu and blocking screens; `ANSWER` replies
  on stdin. EOF cancels; the backend rejects confirmation before its delay.
- **Decided:** checks precede writes. If stock data will not fit, block with
  "Please free X MB on /usr/data" and only "Boot to stock". A `BLOCK` button
  exits the app with status 1, letting the stock hook continue.
- **Decided:** creating the partition requires a "Create a 4 GB partition"
  confirmation with a 5-second button delay.
- **Decided:** offer an optional eMMC backup to the USB stick. If selected,
  verify it before eMMC writes, including `userdata` at full size.
- **Decided:** repartition under stock's USB hook before installing OpenWrt.
  Stock provides `resize2fs`, `e2fsck`, `mkfs.ext4` and `partprobe`, but no
  GPT editor. The stick carries static util-linux `sfdisk` to rewrite the
  GPT with its backup header at disk end, and `partx` to update the kernel
  through `BLKPG` and find partitions by GPT name for `slot.sh`. Build them
  with `installer/tools/build.sh`. If the kernel retains the old table,
  reboot once and continue.
- **Decided:** use the touchscreen app on stock and OpenWrt; display and
  touch work on the printer. A missing app or display/touch falls back to
  headless operation (`installer/runFirmwareExe.sh`).
- **Decided:** the PC demo runs the SDL build with the real backend, a sparse
  printer-layout eMMC image, and path overrides such as `C5_DISK`,
  `C5_SYSBLOCK` and `C5_CMDLINE_FILE`. QEMU, not the demo, covers the jump
  into OpenWrt.
- **Decided:** OpenWrt's boot-time USB hook runs the same stick, offering
  "Update / Repair OpenWrt", "Swap to stock" and "Repair stock".
  Headless operation reads `opencreator-os/ACTION`; without it, OpenWrt
  takes no action and stock defaults to install.
- **Decided:** accept only `Creator5 0028` and `Creator5Pro 0029`; reject
  other model pairs before writes.
- **Decided:** normal OpenWrt boots keep the flag on OpenWrt. Three failed
  boots reaching preinit trigger stock fallback on the next attempt if
  stock is selectable. START=99 with `/data` mounted resets the counter.
  Only a matching `pending-commit` lets the health service change the flag.
  Procd feeds the hardware watchdog; no separate daemon.
- **Decided:** Install and Swap to OpenWrt on stock end in OpenWrt. A kernel
  matching `good-kernel` gets the boot flag and a reboot; other kernels get
  a chainload test boot, committed through `pending-commit`. A headless hook
  does not repeat the same stick payload, preventing loops with a stick left in.
- **Decided:** a failed test boot returns to stock without a power cycle.
  `chainload.ko` arms the SoC watchdog before jumping: default 120 s,
  configurable through `C5CL_WDT`. OpenWrt feeds it until procd opens it
  (`kernel/patches/0005`). OpenWrt returns to stock immediately if `/data`
  is not mounted at START=99, or if the boot is not healthy 180 s after
  preinit. Test boots do not count toward the three-boot limit and never
  write the stock slot, `userdata` or stock-invalid mark.
  The watchdog path is not verified on hardware.
- **Decided:** record each installer-started boot at
  `opencreator-os/last-test` on `c5os` and report it once:
  - Failure or a remaining `started` record: the next stock run shows
    "OpenWrt test failed", its reason, "Try again" for the menu, and
    "Boot to stock".
  - Success: OpenWrt's USB hook waits for `c5-booted`, then shows
    "OpenWrt installed" with "Reboot". Headless operation logs it.

## Open questions for the design

- **Hypothesis:** no process holds `/usr/data` open at USB-hook time.
  Check `/proc/*/fd`, `cwd` and `maps`; unmount failure must stop the shrink
  without writes.
- **Unknown:** the contents of the 118 MiB beyond the original last usable
  sector, and whether stock or the bootloader depends on the original
  backup GPT location. The installer moves the backup GPT to disk end and
  refuses to proceed if the final 33 sectors contain data.
- **Unknown:** whether the kernel accepts the partition update while
  `usershare` is mounted. The installer uses `partx` and reboots if needed.
- **Unknown:** whether stock OTA updates or factory reset depend on
  `userdata` size. The reviewed `ota_utils.sh` size checks cover only
  kernel, rootfs and rtos.
