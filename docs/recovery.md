# Recovery

How opencreator-os keeps the Creator 5 Pro recoverable, and what to do in
each failure case. Labels: **Observed** = seen on the printer or in a stock
file; **Hypothesis** = not verified yet.

## How the printer picks what to boot

- The eMMC has two boot slots: slot 1 = GPT `kernel` + `rootfs`
  (`mmcblk0p1`/`p2`), slot 2 = `kernel2` + `rootfs2` (`p3`/`p4`). Stock runs
  from one slot, opencreator-os is installed into the other. On the reference
  printer stock runs from slot 2 (**Observed**), so OpenWrt goes to slot 1.
- The bootloader (SPL) reads the first bytes of the `ota` partition
  (`mmcblk0p5`). `ota:kernel2` boots slot 2; anything else boots slot 1. This
  text is called **the boot flag** below.
- The SPL has no fallback of its own: no boot counter, no checksum, no retry
  of the other slot (**Hypothesis**, from the analysis of the same SPL family
  on the AD5X). OpenWrt counts boots in preinit, not in the bootloader.
  A kernel that dies before preinit cannot advance that counter and can
  keep booting forever. Changed kernels therefore need a chainload test
  before they become the default.

## Safety mechanisms

**Chainload changed kernels first.** The stock installer writes OpenWrt into
the spare slot and keeps the flag on stock for the RAM test, which Install
and Swap to OpenWrt then run (by hand under stock:
`c5-chainload.sh stage /dev/mmcblk0pN` + `go`): `chainload.ko` loads the
slot's OpenWrt kernel and jumps to it. The test follows a real slot write; it
is not a zero-write test. If it fails before committing, the printer returns
to stock by itself (next paragraph); a headless install stick left in does
not start it again. A kernel whose SHA-256 matches `c5os`'s `good-kernel`
skips the RAM test: the installer points the flag at it and reboots.

**Test boots fail back to stock.** A test boot is a boot whose root is an
eMMC slot the flag does not name, so stock chainloaded it (`slot.sh`
`c5_test_boot`). Its flag stays on stock, and three things end it there
without a power cycle:
1. Kernel hang: `chainload.ko` arms the SoC watchdog right before the jump
   (`C5CL_WDT`, default 120 s). The OpenWrt kernel keeps it fed
   (`kernel/patches/0005`) until procd opens `/dev/watchdog`. A kernel that
   hangs before that is reset after 120 s, a system that hangs later within
   procd's 30-second timeout. The SPL then boots the flagged slot: stock.
2. Unhealthy: `c5-booted` (START=99) finds `/data` not mounted and fails the
   test at once (reason `c5os not mounted at /data`).
3. Stuck: preinit starts a background job that waits `C5_TEST_DEADLINE`
   seconds (default 180; a `C5_TEST_DEADLINE=N` word on the kernel command
   line overrides it, the kernel passes it to init). If `c5-booted` has not
   found the boot healthy by then, the job fails the test (reason
   `not healthy within 180 s`). Both take the decision with
   `mkdir /tmp/c5-test.decided`; the first one wins.

Failing a test (`slot.sh` `c5_test_fail`) writes the flag to stock and reads
it back, removes `pending-commit` and writes `last-test` on `c5os`, then
runs `reboot -f`. It never writes the stock slot, `userdata` or the
stock-invalid mark. Preinit does not count a test boot: the counter and the
flag stay as they are. The watchdog part is not verified on hardware; with
`C5CL_WDT=0` or a watchdog that does not work, a hung test kernel needs a
power cycle, which also boots stock.

**The outcome is recorded once on `c5os`.** `opencreator-os/last-test` holds
one line:
- `started VERSION`: written by the stock installer right before it boots
  OpenWrt (after staging the chainload, or right after a known-good flip
  wrote the flag). VERSION is the version `install.state` records for that
  slot.
- `ok VERSION`: `c5-booted` committed a `pending-commit`, or found `started`
  and the flag names its slot. VERSION is the image's `DISTRIB_RELEASE`
  (the build's `git describe`).
- `failed VERSION REASON`: a failed test boot, or the counter fallback below.

Whoever tells the user renames it to `last-test.seen`. Stock reports a
`started` that is still there (the test kernel hung and the watchdog reset
the printer, or it was power-cycled) or a `failed`; OpenWrt reports `ok`
(`install.md`).

**Three failed boots, then stock.**
1. Early preinit (`05_c5_bootcount`) increments a counter in one `ota` sector
   at offset 192 KiB (`C5TRIES1 N`; empty or malformed data means zero).
   The first three attempts leave the flag alone. If those fail to become
   healthy, the fourth attempt selects stock, resets the counter, removes
   `pending-commit` and records `last-test` as
   `failed VERSION boot counter: 3 boots of slot N did not become healthy`
   on `c5os`, and reboots. Test boots are not counted (above).
2. Fallback is refused if stock is marked invalid or lacks a uImage kernel
   and squashfs root. OpenWrt stays selected; the boot log says `NO fallback`.
3. At START=99, `c5-booted` treats `/data` being mounted as healthy. It resets
   the counter and records the running slot kernel's SHA-256 as
   `/data/opencreator-os/good-kernel` (the 64-byte uImage header plus payload,
   not the entire padded partition). Wi-Fi, IPv4 and SSH are not health
   gates; a healthy printer may still be unreachable over the network.
4. Only a `pending-commit` whose `slot=N` matches the running slot allows
   `c5-booted` to select that slot and remove the marker. Stock-side test
   boots (Install, Swap to OpenWrt) and changed-kernel sysupgrades create
   this marker. Healthy normal boots do not change the flag, so they cannot
   undo a requested swap to stock.

The hardware watchdog is enabled in the kernel and fed by procd through
`/dev/watchdog` (by default a requested 30-second timeout and a feed every
5 seconds). No separate watchdog service is needed. The SPL disables it on
boot; on a test boot `chainload.ko` has armed it, and the kernel feeds it
until procd takes over (`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` and
`kernel/patches/0005`). It cannot promise a reboot for every failed service,
and the counter cannot catch failures before preinit. These safety changes
have not been verified on hardware.

A chainload test may commit only when its kernel is the root slot's own
kernel. `c5-chainload.sh stage /dev/mmcblk0pN` compares the staged image with
the GPT `kernel`/`kernel2` partition paired with rootfs `pN` (`p2`→`p1`,
`p4`→`p3`). The image must be exactly one uImage (64-byte header + `ih_size`)
and byte-identical to the start of that partition. Otherwise, or for a
non-slot root, the script adds `c5.nocommit=1`; `stage` and `args` print the
decision. On such a boot both preinit and `c5-booted` leave the counter
alone and do not record a good kernel; a healthy one leaves the flag alone
too. A `c5.nocommit=1` boot of an eMMC slot is still a test boot and fails
back to stock when it is not healthy.

**Sysupgrade uses the known-good kernel record.** It writes the OpenWrt slot
from RAM, never stock's slot. If the new kernel's SHA-256 matches
`good-kernel`, it removes any pending commit, resets the counter, keeps the
flag on OpenWrt and reboots directly. The counter protects the next boots;
the new rootfs has not necessarily been tested.

For a changed kernel, sysupgrade requires selectable stock. Before writing
it removes the old saved chainload kernel and pending commit, points the
flag at stock and resets the counter. It writes and reads back the new
image, copies the new kernel to `opencreator-os/chainload/kernel.uimage` on
`userdata` (stock's `/usr/data`), and writes `pending-commit` on `c5os`
(slot, version, date, checksums). If saving these fails, sysupgrade fails;
reinstall from stock with an install stick. The next boot is **stock**.
The new image becomes the default only after a healthy boot with its own
slot kernel commits it. Inspect the marker with
`cat /data/opencreator-os/pending-commit`. Test it from stock with either:

- SSH to stock:
  `sh /usr/data/opencreator-os/chainload/c5-chainload.sh stage /dev/mmcblk0pN`
  then `sh /usr/data/opencreator-os/chainload/c5-chainload.sh go`, where
  `/dev/mmcblk0pN` is the OpenWrt rootfs (sysupgrade prints it; `p2` for slot
  1, `p4` for slot 2). The script stages the new kernel because sysupgrade
  copied it there, and `stage` should report `commit: yes`.
- An install stick: "Swap to OpenWrt" test-boots the slot as it is (copying
  its own kernel to `opencreator-os/chainload/`). "Install" from a stick of
  the same build sees that the slot already holds that image, skips the
  write and test-boots it; a stick from a different build rewrites the slot
  first.

**Stock-slot repair: flag on OpenWrt, stock marked invalid.**
The installer's OpenWrt "Repair stock" action first points the flag at the
running OpenWrt slot. It writes a **stock-invalid mark** into one `ota`
sector at offset 128 KiB (with fsync and read-back), checks the flag again,
then writes stock's kernel and rootfs. The mark is cleared only after both
writes read back correctly. While it is set:
- preinit never falls back to stock;
- "Swap to stock" and changed-kernel sysupgrade refuse to select stock.

A power loss or failed write during repair therefore leaves OpenWrt
selected until repair succeeds. This raw-sector mark does not depend on
`userdata`. On OpenWrt inspect it with
`. /lib/c5/slot.sh; c5_stock_invalid` (no output means no mark). Stock's
only `ota` writer found in its scripts is `mmc_write_str` in `ota_utils.sh`,
which writes a few bytes at offset 0. **Hypothesis:** the `firmwareExe`
binary also leaves the later sectors alone. The slot magic check still
applies if the mark is lost.

**Write only inactive targets, except sysupgrade from RAM.** Stock installs
and stock-slot repair refuse a running or mounted target. Sysupgrade
deliberately replaces its own OpenWrt slot after moving into RAM; its flag
choice depends on whether the kernel is known-good, as above.

**Boot log in the `ota` partition.** Every OpenWrt slot boot logs its slot
and flag decisions to the 64 KiB at offset 64 KiB of `ota`. No stock script
writer of that area was found. On OpenWrt:

```
. /lib/c5/slot.sh
c5_bootlog_show
c5_tries_read
c5_flag_read
```

On stock after a fallback:

```
dd if=/dev/mmcblk0p5 bs=512 skip=128 count=128 2>/dev/null | tr -d '\000'
```

The first line is the marker `C5BOOTLOG1`. Each healthy boot also stores
`dmesg`, `logread` and the boot log in `/data/opencreator-os/logs/` on
`c5os`. Stock does not mount `c5os`; to read them there:
`mkdir -p /tmp/c5os-ro && mount -t ext4 -o ro /dev/mmcblk0p8 /tmp/c5os-ro`,
then `/tmp/c5os-ro/opencreator-os/logs/`. `/data` has no `userdata` fallback:
the fixed fstab mounts only ext4 label `c5os` (`rw,noatime`).

## What exists to recover with

| What | Where | Made by |
|------|-------|---------|
| Full eMMC backup (`first-mib.bin`, `kernel.img`, `rootfs.img`, `kernel2.img`, `rootfs2.img`, `ota.img`, `usershare.img`, optionally `userdata.img`, `SHA256SUMS`, `MANIFEST.txt`, `partmap.txt`) | `F:/creator5-dev/backups/<date>-creator5pro-emmc/` on the PC (read-only) | `tools/printer/phase0.sh --backup` on the printer, joined and checked with `tools/verify-backup.sh` |
| Whole-eMMC backup made by the installer (the same format with `userdata` at full size, plus `disk-tail.img` and `VERIFIED`) | `emmc-backup/` on the install stick; import it with `tools/verify-backup.sh` (`install.md`) | `install.sh` ("Back up" in the touchscreen installer), before it creates `c5os` |
| Stock slot saved at install time (`kernel.img` = whole stock kernel partition, `rootfs.squashfs` = stock squashfs, `SHA256SUMS` or `MD5SUMS`, `MANIFEST.txt`) | `userdata`: `/usr/data/opencreator-os/stock/` on stock; OpenWrt mounts `userdata` read-only at `/tmp/c5-userdata` to use it | `install.sh` |
| Install stick: Update OpenWrt / Swap to stock / Repair stock | OpenWrt's USB hook; headless `opencreator-os/ACTION` | `tools/make-install-stick.sh` |
| `c5-chainload.sh` + `chainload.ko` | stock, `/usr/data/opencreator-os/chainload/` | `install.sh` |
| Stock-side restore stick (`opencreator-os-restore/`) | runs from stock's USB hook | `tools/make-restore-stick.sh` |
| Slot, counter and boot-log shell helpers | OpenWrt, `/lib/c5/slot.sh` (also on the install stick as `opencreator-os/slot.sh`) | this repo |
| Verified stock-slot repair helpers | install stick, `opencreator-os/restore.sh` (needs the stick's `lib.sh` and `slot.sh`) | `tools/make-install-stick.sh` |
| Ingenic USB cloner | PC, printer in boot-ROM USB mode | Ingenic (`DevSupport/Tools/USBBurner/cloner-latest-ubuntu.tar.gz`) |

Before you rely on any of this, check the PC backup:
`cd F:/creator5-dev/backups/<date>-creator5pro-emmc && sha256sum -c SHA256SUMS`
(from WSL). `tools/verify-backup.sh` ran the same check when it built the
directory and then made it read-only.

### Stock-side restore stick

`tools/make-restore-stick.sh BACKUP_DIR OUTDIR (--slot1 | --slot2) [--usershare] [--flag-stock]`
builds a stick from the PC backup. Copy `OUTDIR` to the root of a FAT32 stick
and power the printer on with it. Stock's USB hook mounts the stick at `/mnt`
before its UI and runs `runFirmwareExe.sh`, which runs
`opencreator-os-restore/restore.sh`. It checks the partition table against
the backup's `partmap.txt` and the image checksums, refuses the slot stock
runs from and anything mounted, writes, and reads back. With
`--flag-stock` it then points the flag at the restored slot and reboots.
Output: `opencreator-os-restore/result.log`. Its action file is marked done
on success and stays in place on failure. One slot per stick.
`--usershare` is refused under stock because stock has `usershare` mounted;
use manual SSH repair from OpenWrt as described below.

A backup taken before the installer created `c5os` (the installer's own
`emmc-backup/`, or a phase0 backup from before the first install) has the old
partition table in `partmap.txt`. On a repartitioned printer `restore.sh`
refuses such a stick with `the backup was taken from a different partition
layout`, and writes nothing. The slot, `ota` and `usershare` images in that
backup are still valid (p1 to p6 never move): use the verified repair helpers
or manual SSH procedure below, or take a new phase0 backup after the
repartition and build the restore stick from that.

This stick needs a working stock userspace. Stock's USB hook is
`/usr/prog/app_startup.sh`, which lives on `usershare`; the stock rootfs
calls it from `S99factory_test_shell` (**Observed** in the stock rootfs). It
cannot repair a stock system whose `usershare` is broken.

Only one `runFirmwareExe.sh` fits on a stick. Do not combine the restore
stick with the install stick or with opencreator-fs's stick.

### Install stick on OpenWrt

Use the same stick built by `tools/make-install-stick.sh`, without the app
for now. OpenWrt's `c5-usb-hook` (START=19) mounts the first mountable FAT
USB candidate read-write at `/mnt`, runs `runFirmwareExe.sh` with the stored
model, then unmounts when it returns. It runs detached (one run at a time,
output in syslog), so boot and SSH do not wait for it. Apart from the
kernel's boot log (not yet seen on hardware) there is no screen on OpenWrt
until display bring-up is verified on hardware; with the app, Repair stock
asks for confirmation first. Missing or invalid
`/data/opencreator-os/model` skips the hook; inspect
`logread -e c5-usb-hook` over SSH.

Put one word in the stick's `opencreator-os/ACTION`:

| `ACTION` | Action |
|----------|--------|
| `update` | Verifies `sysupgrade.tar` against `SHA256SUMS`, tests it with `sysupgrade -T`, then updates with configuration kept. |
| `swap` | Refuses unselectable stock, clears `pending-commit`, resets the counter, selects stock and reboots. |
| `repair-stock` | Mounts `userdata` read-only without journal replay, verifies the saved `opencreator-os/stock/` images, repairs stock's kernel and rootfs, then selects stock and reboots only if selectable. |

Windows line endings are accepted. Headless OpenWrt with no `ACTION` does
nothing; headless stock defaults to `install`. Stock supports `install` and
`swap`; OpenWrt supports `update`, `swap` and `repair-stock`. OpenWrt has no
uninstall action. Remove the stick after use: its action is not consumed.
The log is `opencreator-os-install.log` on the stick, and
`/data/opencreator-os/install.log` on OpenWrt.

Repair takes its images from the saved copy on `userdata`, not from the
stick. If that copy is lost, use the PC backup with the SSH helpers below.
It does not restore `usershare`.

**Removed:** `c5-slot` and `c5-restore-stock` are replaced by installer
actions and the shell helpers above. The OpenWrt recovery-stick
`restore.conf` protocol was removed; use the install stick's `ACTION`.
`switch-to-openwrt.sh` was removed; use the stock installer's Swap action
or chainload. The zero-write USB test was removed; use a backed-up slot
install and chainload test instead. The generated `10-c5-fstab` setup was
removed in favour of the fixed fstab. The separate stock restore stick
still uses its own action file and is unchanged.

## Failure cases

### 1. Chainload test boot hangs, is unhealthy, or OpenWrt never answers

The flag is still on stock, and the test boot returns there by itself
("Test boots fail back to stock" above):

| What happens | What ends it | `last-test` reason |
|---|---|---|
| Kernel hangs before procd opened `/dev/watchdog` | watchdog reset after `C5CL_WDT` s (default 120) | none written; stock reports `hung before OpenWrt started (watchdog reset)` |
| System hangs after procd opened it | procd's 30-second watchdog | as above |
| `/data` (`c5os`) not mounted at START=99 | `c5-booted` at once | `c5os not mounted at /data` |
| START=99 not reached within 180 s after preinit | the preinit deadline | `not healthy within 180 s` |

With `C5CL_WDT=0`, or if the watchdog does not work (not verified on
hardware), a hung kernel stays hung: power-cycle; stock boots, and is
reported the same way as a watchdog reset. In the boot log a failed test
shows as `test: FAILED: REASON; flag -> slot N (stock)` and
`test: rebooting into stock`.

The next run of the install stick on stock reports it once: with the app,
the screen "OpenWrt test failed" with the reason and "Stock is unchanged and
boots normally."; "Try again" goes on to the menu, "Boot to stock" lets stock
boot. With or without the app it logs
`test: the OpenWrt test boot (VERSION) failed: REASON; stock is unchanged`.
A headless stick logs only that line, then does not repeat the test
("OpenWrt already tried").

What a failed test boot changed: the flag (rewritten to stock), the `ota`
boot log (reset at every slot boot), `last-test` and the removed
`pending-commit` on `c5os`, and the slot's own rootfs overlay. It does not
write the boot counter, the stock-invalid mark, the stock slot or
`userdata`; `c5os`'s `opencreator-os/logs/` still holds the last boot that
completed `c5-booted`. Before the test, the install already wrote the
OpenWrt slot and, on first install, created `c5os`. Read the `ota` boot log
on stock as shown above, fix the image and reinstall.

If OpenWrt merely never answers SSH, it may still have committed: networking
is not a health gate. Check the flag/boot log before assuming a power cycle
returns to stock. Use the headless install stick's `swap` action if needed.

### 2. OpenWrt boots from the SPL but is not healthy

`c5-booted` reports `booted: NOT healthy (/data not mounted)` or never
runs. A normal boot leaves the flag on OpenWrt and does not reset the
counter. After three failed attempts that reached preinit, the next
attempt selects stock and reboots if stock is selectable. That fallback
records `last-test` as `failed VERSION boot counter: 3 boots of slot N did
not become healthy` and removes `pending-commit`, so the next stock run of
an install stick reports it like a failed test boot (case 1). This also
covers a known-good flip whose boots fail. The watchdog may reset a hung
system; otherwise power-cycle. A failure before preinit cannot be counted
(case 7). A test boot (flag still on stock) is not counted; it returns to
stock by itself (case 1).

Wi-Fi or SSH failure alone no longer means unhealthy. Inspect the network
separately; use `ACTION=swap` on the install stick if you need stock.

### 3. OpenWrt runs, you want stock

- Use the install stick with `opencreator-os/ACTION` containing `swap` and
  reboot with it. It refuses unselectable stock. No SSH or screen is needed.
- If stock needs repair, use `repair-stock` instead.
- Back to OpenWrt later: the install stick's "Swap to OpenWrt" on stock,
  headless `ACTION=swap`, or a chainload test.

### 4. After a sysupgrade

- Known-good kernel: the printer reboots directly into OpenWrt with the
  counter protecting subsequent boots; no chainload is needed.
- Changed kernel: it boots stock; test-boot as described above. A healthy
  test boot commits the pending image. If the test fails before committing,
  it returns to stock by itself (case 1); install a working build.
- `READ-BACK MISMATCH`: the OpenWrt slot may be damaged. A changed-kernel
  upgrade has its flag on stock; reinstall there. On the known-good path
  the flag remains on OpenWrt, so a write failure can instead require the
  last-resort recovery in case 7 if preinit cannot be reached.
- Your configuration is kept on `c5os` as
  `/data/opencreator-os/sysupgrade.tgz` until preinit on the new image moves
  it into place for restoration, whichever way that boot happens.

### 5. Stock slot damaged, OpenWrt works

Symptoms: the installer's Swap action refuses stock, `c5_stock_blocker`
prints a reason, or Repair stock reports a checksum problem. An interrupted
repair leaves stock marked invalid and OpenWrt selected. If the flag already
points at broken stock, see case 7.

- Use the install stick with `ACTION=repair-stock`. It verifies the saved
  copy in `opencreator-os/stock/` on `userdata` and reads every write back.
- If `userdata` or the saved copy is bad, copy the stock slot's images from
  the PC backup into `/data/stock-restore/` over SSH. Name them `kernel.img`
  and `rootfs.squashfs` and create a matching `SHA256SUMS` on the PC before
  copying. With the install stick mounted (`mount -t vfat /dev/sda1 /mnt`),
  the verified helper can check first, then repair:

  ```sh
  SELF_DIR=/mnt/opencreator-os
  . "$SELF_DIR/lib.sh"
  . "$SELF_DIR/restore.sh"
  c5_restore_stock /data/stock-restore 1 &&
      c5_restore_stock /data/stock-restore 0
  ```

  This leaves the flag on OpenWrt; after success use the installer's
  `swap` action to select stock. Unlike the old command, these are sourced
  shell helpers, not a standalone recovery program.

### 6. Stock `usershare` damaged

Stock's kernel boots, but its userspace (including SSH and the USB hook,
which live on `usershare`) does not. The installer's Repair stock action
does **not** repair this partition. If OpenWrt is selected, restore over SSH.
Copy `usershare.img` and a matching `SHA256SUMS` from the PC backup into
`/data/usershare-restore/`, then, with the install stick mounted at `/mnt`
as in case 5, on OpenWrt:

```sh
(
    set -e
    SELF_DIR=/mnt/opencreator-os
    . "$SELF_DIR/lib.sh"
    . "$SELF_DIR/restore.sh"
    dir=/data/usershare-restore
    dev=$(c5_part_dev usershare)
    c5_verify_file "$dir" usershare.img
    tool=$C5_SUM sum=$C5_WANT
    c5_check_target "$dev" usershare "$dir/usershare.img"
    own=$(c5_own_slot)
    c5_flag_write "$own"
    c5_stock_invalid_set usershare
    [ "$(c5_flag_slot)" = "$own" ]
    c5_write_verified "$dir/usershare.img" "$dev" "$tool" "$sum"
)
```

This refuses a mounted target, pins the flag on OpenWrt, marks stock
invalid, and verifies the write. After success, run Repair stock (or the
case 5 helper with verified PC images) to verify/restore stock's slot and
clear the mark before selecting stock. Do not clear it after a failed
write. If stock is already selected and neither system can be reached,
this is case 8. There is no automatic USB usershare-restore action.

### 7. Flag points at a slot that never reaches userspace

The SPL keeps booting the same broken slot.

- Broken OpenWrt slot: a kernel or rootfs that dies before preinit never
  increments the counter, even if a warm chainload previously succeeded.
  A failed counter/flag write can also prevent fallback. Chainload-first
  and the kernel identity check reduce this risk, but do not prove cold
  boot. A known-good-kernel upgrade also writes a new rootfs and keeps the
  flag on OpenWrt; interrupted writes are still a risk.
- Broken stock slot as flag target: avoided because every write of stock
  points the flag at OpenWrt first and keeps stock marked invalid until it
  verified, and because every automatic or manual switch to stock checks the
  mark and the slot's magics. Damage that keeps the magics intact, a stock
  OTA update, or outside tampering can still cause it.

In both cases no software path is left: go to case 8.

### 8. Neither system boots (last resort, untested)

Only Ingenic's USB cloner can write the eMMC without a running system. It
needs the X2600 boot ROM's USB boot mode and a cloner configuration for this
board. Neither has been tried on the Creator 5 Pro, and how to enter USB boot
mode on this board is unknown. With the cloner, write the partitions back
from the PC backup: a stock slot, `ota.img` (holds `ota:kernel2` on the
reference printer), and `usershare.img` if needed. `first-mib.bin` (GPT, SPL
and U-Boot) only matters if the boot area itself was touched. The only part
of it this project writes is the partition table (sectors 0 to 33), when the
installer creates `c5os`; a `first-mib.bin` from before that holds the old
table.

### 9. FlashForge firmware update while OpenWrt is installed

Stock's updater writes the slot the flag does **not** name and then flips the
flag (**Observed** in the stock OTA scripts). Run from stock, it overwrites
the OpenWrt slot. The printer then boots the new stock from there, with the
old stock still in the other slot. This does not brick the printer, but
OpenWrt is gone and the slots have swapped roles. Do not apply FlashForge
updates that contain a kernel while opencreator-os is installed. If it
happens, reinstall opencreator-os from the new stock.

### 10. `c5os` or `userdata` damaged

`c5os` (`/data` on OpenWrt): if `/data` cannot mount, `c5-booted` reports
not healthy and leaves the flag unchanged. A normal boot eventually falls
back after three failures; a test boot with its flag on stock fails back
there at once (case 1). With `/data` unavailable, the USB hook also
lacks its stored model and skips the stick.

If OpenWrt is reachable over SSH and p8 is unmounted, repair it with
`e2fsck -f /dev/mmcblk0p8`. If it cannot be repaired,
`mkfs.ext4 -F -L c5os /dev/mmcblk0p8` makes an empty one, destroying its
contents: logs, imported settings/model, good-kernel record and any pending
commit or sysupgrade backup (`/etc` still lives in the slot overlay).
Re-run the stock install stick to populate `c5os` and create a pending commit
again; a healthy normal boot alone does not change the flag.
The installer's backup predates `c5os`, and phase0's fixed backup list does
not include it. Stock does not otherwise use `c5os`.

`userdata` (stock's `/usr/data`): it holds stock's data, the saved stock
images in `opencreator-os/stock/` and the staged chainload kernel. Imported
OpenWrt settings/model live on `c5os`, not `userdata`. OpenWrt does not keep
it mounted, so repair it from OpenWrt over SSH: `e2fsck -f /dev/mmcblk0p7`.
Do not write `userdata` from stock, which has it mounted as `/usr/data`. A
`userdata.img` from a backup taken before the repartition (the installer's
`emmc-backup/`, or a phase0 `--all` backup from before the first install) is
larger than the shrunk partition and cannot be written back; one taken
afterwards can, with
`ssh root@PRINTER 'dd of=/dev/mmcblk0p7 bs=1M conv=fsync' < userdata.img`
and the check described below. If the saved stock images are lost, the PC
backup is the source for case 5.

### 11. Creating `c5os` fails or is interrupted

Design intent, not yet tried on a printer: the installer shrinks the
`userdata` filesystem before it rewrites the partition table and grows it
back to the partition afterwards, so the filesystem always fits both the old
and the new `userdata`. Stock's boot script, which formats `userdata` when it
cannot mount it, should therefore still find a mountable filesystem after a
power loss during this step. This does not cover a power loss in the middle
of the partition table write itself. Failures before the table is written
(`cannot unmount /usr/data (something holds it open)`, an `e2fsck` error,
`resize2fs shrink failed`, "Please free N MB") leave the table unchanged and
`/usr/data` mounted. Afterwards, run the same install stick again. Without
`c5os` in the table it repeats the step; with `c5os` it compares the table
with what the kernel sees and reboots once if they differ, or finishes the
step (grows the `userdata` filesystem, formats `c5os`) if it was cut short.
`kernel does not see the new partition table after a reboot` stops the
installer; the log on the stick (`opencreator-os-install.log`) has the
details.

## Restoring single partitions from the PC backup over SSH

From a system that does **not** use the target partition. A stock slot can be
written from OpenWrt. The OpenWrt slot can be written from stock. Never write
the slot or a partition the running system uses.

```
# WSL, in F:/creator5-dev/backups/<date>-creator5pro-emmc
P=<printer ip>; N=3; IMG=kernel2.img   # partition number from partmap.txt
ssh root@$P "dd of=/dev/mmcblk0p$N bs=1M conv=fsync" < $IMG
ssh root@$P "sync; echo 3 > /proc/sys/vm/drop_caches; head -c $(stat -c %s $IMG) /dev/mmcblk0p$N | sha256sum"
grep " $IMG\$" SHA256SUMS                # must print the same checksum
```

For a stock slot, prefer the verified helpers in case 5: they pin OpenWrt
and set the stock-invalid mark before writing. For `usershare`, use case 6.
After a successful repair, select stock with the installer's `swap` action.
From stock, select OpenWrt with that installer's Swap action or chainload.
