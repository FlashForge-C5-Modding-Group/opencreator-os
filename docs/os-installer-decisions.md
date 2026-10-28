# Storage layout and touchscreen installer: decisions so far

Starting point for the os-installer design (brainstorm, then spec, then plan).
Not a spec. Labels: **Observed** (seen on the printer or in a stock file),
**Decided** (agreed with the user), **Hypothesis** (not yet checked).

## Storage

- **Observed:** the eMMC is 15,307,776 sectors. Its GPT (8 entries, 7 used)
  declares sectors 34 to 15,065,087 usable. `userdata` (p7) ends at 14,479,359,
  so 585,728 sectors (286 MiB) inside the usable range are unallocated. About
  118 MiB past the last usable sector is outside every partition.
- **Observed:** stock's `/usr/bin/mount_mmc_ext4.sh` (run by
  `S21mount_mmc_ext4` for `userdata` and `S09mount_mmc_prog` for `usershare`)
  runs `fsck -y` and, if the mount still fails, `mkfs.ext4` on the partition.
  It finds the partition with `fdisk -l | grep <name>`.
- **Observed:** stock `/usr/data` holds about 1.0 GB: opencreator 439 MiB,
  bin 362 MiB, python-hf 83 MiB, firmwareRes 45 MiB, gcodes 28 MiB, the rest
  about 60 MiB.
- **Decided:** shrink `userdata` and add one partition after it, so OpenWrt's
  data is never on a filesystem stock may reformat:
  - new partition: 4,096 MiB, ending at sector 15,065,087 (includes the free
    286 MiB), ext4, GPT name `c5os`. The name must not contain any stock
    partition name, because stock matches names with `grep`.
  - `userdata`: shrunk to 2,018 MiB (filesystem shrunk with margin first).
  - nothing is placed past sector 15,065,087 until that area is understood.
  - p1 to p6 are never moved or resized.
- **Decided:** OpenWrt keeps `/etc` in its slot overlay. Packages, Klipper,
  Moonraker, logs and gcode go on `c5os`. The installer saves Wi-Fi settings,
  optional SSH keys and the model on `c5os`; preinit imports them before
  uci-defaults. `userdata` holds the saved stock images and staged chainload
  kernel and is mounted only briefly by OpenWrt.

## Installer

- **Decided:** fork touchscreen-installer as `os-installer` (private, under the
  org). Keep its platform layer (fb0, goodix touch, rotation, SDL), LVGL
  submodule, build (`make mips32` static NaN-2008, `make sdl`), logo, log
  viewer and progress bar. Replace the hardcoded opencreator-fs pages with a
  generic screen engine driven by the shell backend.
- **Decided:** all checks and every write stay in the opencreator-os shell
  backend (`installer/opencreator-os/`), which the QEMU tests cover. The app
  only draws what the backend asks for.
- **Decided (sketch):** the backend requests screens with lines such as
  `INFO`, `CONFIRM <id> <delay> ...` and `BLOCK <id> ...`; the app replies
  `ANSWER <id> ok|cancel` on the backend's stdin. End of input counts as
  cancel. The backend also rejects an `ok` that arrives before the delay.
- **Decided (user requirements):**
  - checks run before every write;
  - when stock's data does not fit the shrunk `userdata`, a blocking screen
    says "Please free X MB on /usr/data" and offers only "Boot to stock"
    (`BLOCK <id> <text>|<button>`: the button exits the app with 1, so the
    stock hook boots on);
  - creating the partition needs a confirm screen ("Create a 4 GB
    partition") whose Ok button unlocks after 5 seconds;
  - the eMMC backup is an installer step, written to the USB stick and
    verified before anything on the eMMC is written. It must include
    `userdata` while it is still full size.
- **Decided:** the repartition runs under stock, from the USB hook, before
  OpenWrt is installed. OpenWrt's display bring-up is not hardware-verified;
  use headless installer actions there for now. Stock has
  `resize2fs`, `e2fsck`, `mkfs.ext4` and `partprobe`; it has no GPT editor, so
  the stick carries static util-linux `sfdisk` (GPT rewrite, backup header at
  the disk end) and `partx` (tells the kernel through `BLKPG`, and finds
  partitions by GPT name for `slot.sh`), built by
  `installer/tools/build.sh`. If the kernel still shows the old table, the
  installer reboots once and continues.
- **Decided:** PC demo = the SDL build under WSLg running the real backend
  against a sparse disk image laid out like the printer's eMMC, through the
  backend's path overrides (`C5_DISK`, `C5_SYSBLOCK`, `C5_CMDLINE_FILE`, ...).
  The jump into OpenWrt is not part of the demo (QEMU covers it).
  `libsdl2-dev` (2.30.0) is installed in WSL.
- **Decided:** the same install stick runs from OpenWrt's boot-time USB hook.
  Its actions are "Update OpenWrt", "Swap to stock" and "Repair stock";
  headless operation reads `opencreator-os/ACTION`. No action file on
  headless OpenWrt means no action; stock still defaults to install.
- **Decided:** only the exact model pairs `Creator5 0028` and
  `Creator5Pro 0029` are accepted; other pairs are refused before writes.
- **Decided:** normal OpenWrt boots keep the flag on OpenWrt. Three failed
  boots reaching preinit trigger stock fallback on the next attempt if stock
  is selectable; START=99 with `/data` mounted resets the counter. Only a
  matching `pending-commit` permits the health service to change the flag.
  Hardware watchdog feeding is handled by procd, not a separate daemon.
- **Decided:** Install and Swap to OpenWrt on stock always end in OpenWrt:
  a kernel matching `good-kernel` gets the boot flag and a reboot, any other
  a chainload test boot that commits via `pending-commit`. The former
  `FLIP`/`CHAINLOAD` stick options are gone. A headless hook run does not
  repeat this for the same stick payload, so a stick left in cannot loop.
- **Decided:** a failed test boot returns to stock without a power cycle.
  `chainload.ko` arms the SoC watchdog for the jump (default 120 s,
  `C5CL_WDT`) and the OpenWrt kernel keeps it fed until procd opens it
  (`kernel/patches/0005`). OpenWrt fails a test boot back to stock at once
  when `/data` is not mounted at START=99, or when it is not healthy 180 s
  after preinit; test boots do not count toward the three failed boots. It
  never writes the stock slot, `userdata` or the stock-invalid mark. The
  watchdog path is not verified on hardware.
- **Decided:** the outcome of the boot the installer started (test boot or
  flip) is recorded in `c5os` `opencreator-os/last-test` and reported once.
  A failure, or a hang (`started` still there), is reported by the next stock
  run: "OpenWrt test failed" with the reason, "Try again" (menu) or "Boot to
  stock". Success is reported by OpenWrt's run of the stick, which the USB
  hook defers until `c5-booted` has decided: "OpenWrt installed" with one
  "Reboot" button; headless only a log line.

## Open questions for the design

- **Hypothesis:** nothing holds files open on `/usr/data` when the USB hook
  runs, so it can be unmounted for the shrink. Check `/proc/*/fd`, `cwd` and
  `maps` at hook time; if the unmount fails the installer must stop with
  nothing written.
- **Unknown:** what the 118 MiB past the last usable sector holds, and where
  the backup GPT header is (disk end or right after sector 15,065,087).
  The repartition must rewrite the backup header where the bootloader and
  stock expect it.
- **Unknown:** whether `partprobe` can re-read the table while `usershare` is
  mounted, or the installer must reboot between repartitioning and use.
- **Unknown:** whether a stock OTA update or factory reset depends on the
  `userdata` size (`ota_utils.sh` checks kernel/rootfs/rtos sizes only, as far
  as read so far).
