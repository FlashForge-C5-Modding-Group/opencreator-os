# Recovery

**Observed** = seen on the printer or in a stock file.
**Hypothesis** = not verified.

## How the printer picks what to boot

- The eMMC has two boot slots: slot 1 = GPT `kernel` + `rootfs`
  (`mmcblk0p1`/`p2`), slot 2 = `kernel2` + `rootfs2` (`p3`/`p4`). Stock runs
  from one slot, opencreator-os is installed into the other. On the reference
  printer stock runs from slot 2 (**Observed**), so OpenWrt goes to slot 1.
- The bootloader (SPL) reads the first bytes of the `ota` partition
  (`mmcblk0p5`). `ota:kernel2` boots slot 2; anything else boots slot 1. This
  text is called **the boot flag** below.
- **Hypothesis:** the SPL has no boot counter, checksum or fallback to the
  other slot, based on analysis of the same SPL family on the AD5X.
  OpenWrt counts boots in preinit. A kernel that dies before preinit cannot
  advance the counter and may boot repeatedly. Chainload-test changed kernels
  before making them the default.

## Safety mechanisms

**Chainload changed kernels first.** Install and Swap to OpenWrt keep the
flag on stock while `chainload.ko` loads the OpenWrt slot's kernel and jumps
to it. Under stock, run `c5-chainload.sh stage /dev/mmcblk0pN`, then `go`.
Install writes the spare slot before testing it. A failed test returns to
stock; a headless stick does not retry automatically. A kernel whose SHA-256
matches `c5os`'s `good-kernel` skips the test: the installer selects it and
reboots.

**Test boots fail back to stock.** `slot.sh`'s `c5_test_boot` identifies an
eMMC root slot not named by the flag as a test boot. The flag stays on
stock. Three mechanisms return the printer there:
1. Kernel hang: `chainload.ko` arms the SoC watchdog right before the jump
   (`C5CL_WDT`, default 120 s). The OpenWrt kernel keeps it fed
   (`kernel/patches/0005`) until procd opens `/dev/watchdog`. A kernel that
   hangs before that is reset after 120 s, a system that hangs later within
   procd's 30-second timeout. The SPL then boots the flagged slot: stock.
2. Unhealthy: `c5-booted` (START=99) finds `/data` not mounted and fails the
   test at once (reason `c5os not mounted at /data`).
3. Deadline: preinit starts a background job that waits `C5_TEST_DEADLINE`
   seconds (default 180). Override it with `C5_TEST_DEADLINE=N` on the kernel
   command line, which passes it to init. If the boot is not healthy, the
   job fails it with `not healthy within 180 s` at the default deadline.
   It and `c5-booted` use `mkdir /tmp/c5-test.decided`; the first wins.

Failing a test (`slot.sh` `c5_test_fail`) writes the flag to stock and reads
it back, removes `pending-commit` and writes `last-test` on `c5os`, then
runs `reboot -f`. It never writes the stock slot, `userdata` or the
stock-invalid mark. Preinit does not count a test boot: the counter and the
flag stay unchanged. **The watchdog has not been verified on hardware.**
With `C5CL_WDT=0` or a nonworking watchdog, power-cycle a hung test kernel
to boot stock.

**Test outcome.** `c5os`'s `opencreator-os/last-test` holds one line:
- `started VERSION`: the stock installer staged the chainload or selected a
  known-good kernel and is about to boot OpenWrt. VERSION comes from the
  slot's `install.state`.
- `ok VERSION`: `c5-booted` committed `pending-commit`, or found `started`
  with its slot selected. VERSION is the image's `DISTRIB_RELEASE`
  (the build's `git describe`).
- `failed VERSION REASON`: a failed test boot or boot-counter fallback.

The installer reports the outcome once, then renames it to `last-test.seen`.
Stock reports `failed` or a remaining `started` after a hang or power cycle.
OpenWrt reports `ok`; see `install.md`.

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

The kernel enables the hardware watchdog; procd requests a 30-second
timeout and feeds it every 5 seconds through `/dev/watchdog`. No separate
watchdog service is needed. The SPL disables it on boot. On test boots,
`chainload.ko` arms it and the kernel feeds it until procd takes over
(`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`, `kernel/patches/0005`).
It does not cover every service failure, and the counter cannot catch
failures before preinit. **These safety changes are not verified on hardware.**

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
`c5os`, and writes `pending-commit` there
(slot, version, date, checksums). OpenWrt never mounts `userdata` for an
upgrade or repair. If saving these fails, sysupgrade fails;
reinstall from stock with a new install stick. The next boot is **stock**.
The new image becomes the default only after a healthy boot with its own
slot kernel commits it. Inspect the marker:
`cat /data/opencreator-os/pending-commit`. To test from stock:

- Over SSH on stock, mount `c5os` read-only without journal replay and stage
  the saved kernel before jumping:

  ```sh
  mkdir -p /tmp/c5os-config
  mount -t ext4 -o ro,noload /dev/mmcblk0p8 /tmp/c5os-config &&
      sh /tmp/c5os-config/opencreator-os/chainload/c5-chainload.sh stage /dev/mmcblk0p2 &&
      sh /tmp/c5os-config/opencreator-os/chainload/c5-chainload.sh go
  ```

  These are the reference printer's partitions: use the OpenWrt rootfs
  printed by sysupgrade (`p2` for slot 1, `p4` for slot 2), and the actual
  GPT `c5os` device if not `p8`. If `c5os` is already mounted by the
  installer at `/tmp/c5os-config`, do not mount it again.
  `stage` uses the saved new kernel and should report `commit: yes`.
  `go` remounts `/tmp/c5os-config` read-only before the jump; it keeps the
  script available there while the detached shutdown process runs.
- With an install stick, use "Swap to OpenWrt" to test the slot's own
  kernel. "Install" skips writing if the slot already holds the same build;
  a different build rewrites the slot first.

**Stock-slot repair: flag on OpenWrt, stock marked invalid.**
The installer's OpenWrt "Repair stock" action first points the flag at the
running OpenWrt slot. It writes a **stock-invalid mark** into one `ota`
sector at offset 128 KiB (with fsync and read-back), checks the flag again,
then writes stock's kernel and rootfs. The mark is cleared only after both
writes read back correctly. While it is set:
- preinit never falls back to stock;
- "Swap to stock" and changed-kernel sysupgrade refuse to select stock.

A power loss or failed write leaves OpenWrt selected until repair succeeds.
The mark does not depend on `userdata`. Inspect it on OpenWrt:
`. /lib/c5/slot.sh; c5_stock_invalid` (no output means no mark).
**Observed:** stock's scripts only write `ota` through `mmc_write_str` in
`ota_utils.sh`, at offset 0. **Hypothesis:** `firmwareExe` also leaves later
sectors alone. The slot magic check still applies if the mark is lost.

**Inactive targets only.** Stock installs and stock-slot repair refuse
running or mounted targets. Sysupgrade replaces its own OpenWrt slot from
RAM, selecting the flag according to the known-good kernel record.

**Boot log.** Every OpenWrt slot boot logs slot and flag decisions to the
64 KiB at offset 64 KiB of `ota`. No stock script writer of this area was
found. On OpenWrt:

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
`c5os`. Outside the installer, stock leaves `c5os` unmounted; to read them:
`mkdir -p /tmp/c5os-ro && mount -t ext4 -o ro,noload /dev/mmcblk0p8 /tmp/c5os-ro`,
then `/tmp/c5os-ro/opencreator-os/logs/`. Unmount with `umount /tmp/c5os-ro`
afterwards. `/data` has no `userdata` fallback:
the fixed fstab mounts only ext4 label `c5os` (`rw,noatime`).

## What exists to recover with

| What | Where | Made by |
|------|-------|---------|
| Full eMMC backup (`first-mib.bin`, `kernel.img`, `rootfs.img`, `kernel2.img`, `rootfs2.img`, `ota.img`, `usershare.img`, optionally `userdata.img`, `SHA256SUMS`, `MANIFEST.txt`, `partmap.txt`) | `<date>-creator5pro-emmc/` on the PC (read-only) | `tools/printer/phase0.sh --backup` on the printer, joined and checked with `tools/verify-backup.sh` |
| Whole-eMMC backup made by the installer (the same format with `userdata` at full size, plus `disk-tail.img` and `VERIFIED`) | `emmc-backup/` on the install stick; import it with `tools/verify-backup.sh` (`install.md`) | `install.sh` ("Back up" in the touchscreen installer), before it creates `c5os` |
| Stock slot saved at install time (`kernel.img` = whole stock kernel partition, `rootfs.squashfs` = stock squashfs, `SHA256SUMS` or `MD5SUMS`, `MANIFEST.txt`) | `c5os`: `/data/opencreator-os/stock/` on OpenWrt; `/tmp/c5os-config/opencreator-os/stock/` while the stock installer mounts it | `install.sh`, saving the running stock slot and checking the copy |
| Install stick: Update / Repair OpenWrt / Swap to stock / Repair stock | OpenWrt's USB hook; headless `opencreator-os/ACTION` | `tools/make-install-stick.sh` |
| `c5-chainload.sh` + `chainload.ko` + slot kernel `kernel.uimage` | `c5os`, `opencreator-os/chainload/`; stock accesses it at `/tmp/c5os-config/opencreator-os/chainload/` | `install.sh`; changed-kernel sysupgrade replaces the saved kernel on `c5os` |
| Stock-side restore stick (`opencreator-os-restore/`) | runs from stock's USB hook | `tools/make-restore-stick.sh` |
| Slot, counter and boot-log shell helpers | OpenWrt, `/lib/c5/slot.sh` (also on the install stick as `opencreator-os/slot.sh`) | this repo |
| Verified stock-slot repair helpers | install stick, `opencreator-os/restore.sh` (needs the stick's `lib.sh` and `slot.sh`) | `tools/make-install-stick.sh` |
| Ingenic USB cloner | PC, printer in boot-ROM USB mode | Ingenic (`DevSupport/Tools/USBBurner/cloner-latest-ubuntu.tar.gz`) |

Check the PC backup from its folder: `sha256sum -c SHA256SUMS`.
`tools/verify-backup.sh` checks the backup before making it read-only.

### Stock-side restore stick

Usage: `tools/make-restore-stick.sh BACKUP_DIR OUTDIR (--slot1 | --slot2) [--usershare] [--flag-stock]`

Copy the contents of `OUTDIR` to a FAT32 stick's root and power on with it.
Stock's pre-UI USB hook mounts it at `/mnt` and runs `runFirmwareExe.sh`,
then `opencreator-os-restore/restore.sh`. The helper checks `partmap.txt`
and checksums, refuses running or mounted targets, and verifies each write.
With `--flag-stock`, it selects the restored slot and reboots if the flag
changed; otherwise stock startup continues. It uses `sync; reboot -f`
because normal reboot can hang in BusyBox init's synchronous `sysinit`.
Without `--flag-stock`, success returns to stock startup without rebooting.
Output: `opencreator-os-restore/result.log`. Its action file is marked done
on success and stays in place on failure. One slot per stick.
`--usershare` is refused under stock because stock has `usershare` mounted;
use manual SSH repair from OpenWrt as described below.

Backups taken before `c5os` was created have the old table in `partmap.txt`,
including the installer's `emmc-backup/` and pre-install phase0 backups.
On a repartitioned printer, `restore.sh` refuses them with
`the backup was taken from a different partition layout` and writes nothing.
The p1–p6 partitions have not moved, so their slot, `ota` and `usershare`
images remain valid. Use the verified repair helpers or manual SSH
procedure below, or build a restore stick from a new phase0 backup.

This stick requires working stock userspace. Its USB hook,
`/usr/prog/app_startup.sh`, lives on `usershare` and is called by
`S99factory_test_shell` in stock's rootfs (**Observed**).
It cannot repair broken `usershare`.

Only one `runFirmwareExe.sh` fits on a stick. Do not combine the restore
stick with the install stick or with opencreator-fs's stick.

### Install stick on OpenWrt

Works with or without the app. OpenWrt's `c5-usb-hook` (START=19) mounts the
first mountable FAT USB candidate read-write at `/mnt`, runs
`runFirmwareExe.sh` with the stored model, then unmounts. It runs detached,
one run at a time, with output in syslog; boot, Wi-Fi and SSH do not wait.
While a test outcome is pending, the hook waits for `c5-booted`'s health
decision so the installer can report it. A missing or invalid
`/data/opencreator-os/model` skips the hook; inspect
`logread -e c5-usb-hook` over SSH.

Put one word in the stick's `opencreator-os/ACTION`:

| `ACTION` | Action |
|----------|--------|
| `update` | Verifies `sysupgrade.tar` against `SHA256SUMS`, tests it with `sysupgrade -T`, then updates (or reinstalls the same build) with the configuration kept, except the image-owned `/etc/config/fstab`, which is reset to the image's. |
| `swap` | Refuses unselectable stock, clears `pending-commit`, resets the counter, selects stock and reboots. |
| `repair-stock` | Requires `c5os` mounted at `/data`, verifies `/data/opencreator-os/stock/`, repairs stock's kernel and rootfs, then selects stock and reboots only if selectable. Never mounts `userdata`. |

Windows line endings are accepted. Headless OpenWrt with no `ACTION` does
nothing; headless stock defaults to `install`. Stock supports `install` and
`swap`; OpenWrt supports `update`, `swap` and `repair-stock`. OpenWrt has no
uninstall action. Remove the stick after use: its action is not consumed.
The log is `opencreator-os-install.log` on the stick, and
`/data/opencreator-os/install.log` on OpenWrt.

Repair takes its images from `/data/opencreator-os/stock/` on `c5os`, not
from the stick. It never falls back to the old copy on `userdata`. If the
copy is missing, migrate an existing printer below or use the PC backup
with the SSH helpers. Repair does not restore `usershare`.

`update` ignores `sysupgrade`'s exit status: a successful handover stops
ubusd, so it returns "Connection failed". The installer waits up to 60 s
for stage2 to kill it; if the wait expires, nothing was written and it
reports "Update / Repair FAILED".

Stock-side reboots use `sync; reboot -f`, because stock's init is still
blocked in the synchronous USB hook. OpenWrt reboots normally.

### Migrating an existing printer from the old `userdata` layout

**Normal OpenWrt operation must never mount `userdata`.** There is no
automatic migration or compatibility fallback. Older installations may
still have `stock/`, `chainload/` and installer state under
`/usr/data/opencreator-os/` on stock; the new location is
`opencreator-os/` on `c5os`. Do not erase the old files to begin migration.

**Preferred: reinstall from working stock with a newly generated stick.**
This avoids mounting `userdata` on OpenWrt and refreshes the chainload
helpers as well as the saved stock copy:

1. Use the current checkout and an image containing the no-`userdata`
   changes. Existing image artifacts live under
   `/mnt/f/creator5-dev/opencreator-os-builds/`; the directory name or
   `-dirty` suffix alone does not prove which source changes they contain.
   Build a new image if necessary (`build.md`). Regenerate the stick so
   its installer and chainload scripts also come from the current checkout;
   merely replacing an old stick's image is not enough. In WSL, from this
   repository, with `VERSION_DIR` set to the chosen build directory:

   ```sh
   : "${VERSION_DIR:?Set VERSION_DIR to the no-userdata image build directory}"
   tools/make-install-stick.sh --app ../os-installer/build/mips32/os-installer \
       "$VERSION_DIR" /tmp/c5os-migration-stick
   ```

   The output directory must be new or empty. Copy its contents to a FAT32
   stick's root. Omit `--app` and its argument for a headless stick only
   when `c5os` already exists.
2. Boot stock. If currently on OpenWrt and stock is selectable, use the new
   stick's **Swap to stock** action (`ACTION=swap` headlessly). Then remove
   that action file or replace it with `install` before booting stock again.
3. On stock, use **Install / update opencreator-os** (headless:
   `ACTION=install`). The installer reuses existing `c5os`; it does not
   shrink `userdata` again. It saves and verifies the running stock slot
   directly to `c5os`, writes/skips the OpenWrt slot according to payload
   checksums, installs current chainload helpers and the slot kernel on
   `c5os`, and test-boots OpenWrt as usual. Reinstallation can reset the
   OpenWrt slot overlay; keep a separate backup of configuration you need.
4. After a healthy boot, check the saved copy without writing a slot:

   ```sh
   (
       set -eu
       SELF_DIR=/mnt/opencreator-os  # new install stick mounted at /mnt
       . "$SELF_DIR/lib.sh"
       . "$SELF_DIR/restore.sh"
       c5_restore_stock /data/opencreator-os/stock 1
       test -s /data/opencreator-os/chainload/c5-chainload.sh
       test -s /data/opencreator-os/chainload/chainload.ko
       test -s /data/opencreator-os/chainload/kernel.uimage
   )
   ```

   Expect checksum checks and the stock slot mapping, without any
   `writing ...` messages. Remove the stick when finished. Keep the legacy
   `userdata` copy until the new installation and saved images are verified;
   it is no longer used.

**One-off manual exception, only if explicitly authorized by the user:**
copy the legacy saved stock images from OpenWrt using a single
`ro,noload` mount. This is useful when stock needs repair before it can
run the preferred reinstall. It is a recovery operation, not permission
for boot scripts, the installer on OpenWrt, repair or sysupgrade to mount
`userdata`. Do not add it to startup or fstab.

Mount the newly generated install stick at `/mnt`
(`mount -t vfat /dev/sda1 /mnt`, adjusting the USB device if needed), then
run this entire subshell over SSH on OpenWrt. It discovers both eMMC
partitions by GPT name, requires writable `c5os` at `/data`, rejects an
already mounted `userdata` and refuses to overwrite an existing
destination or interrupted `.new` copy:

```sh
(
    set -eu
    SELF_DIR=/mnt/opencreator-os
    . "$SELF_DIR/lib.sh"
    . "$SELF_DIR/restore.sh"
    c5dev=$(c5_part_dev c5os)
    uddev=$(c5_part_dev userdata)
    awk -v d="$c5dev" '$1 == d && $2 == "/data" && $3 == "ext4" &&
        $4 ~ /(^|,)rw(,|$)/ { ok = 1 } END { exit !ok }' /proc/mounts
    if c5_mounted "$uddev"; then
        echo "userdata is already mounted; stop and resolve it first" >&2
        exit 1
    fi
    mnt=/tmp/c5-userdata-migrate
    src=$mnt/opencreator-os/stock
    dst=/data/opencreator-os/stock
    for p in "$dst" "$dst.new"; do
        if [ -e "$p" ] || [ -L "$p" ]; then
            echo "refusing to replace $p; inspect and preserve it first" >&2
            exit 1
        fi
    done
    mkdir "$mnt"
    mounted=0
    trap 'if [ "$mounted" = 1 ]; then umount "$mnt" || exit 1; fi; rmdir "$mnt"' EXIT
    mount -t ext4 -o ro,noload "$uddev" "$mnt"
    mounted=1
    c5_restore_stock "$src" 1
    mkdir -p /data/opencreator-os
    mkdir "$dst.new"
    cp -a "$src/." "$dst.new/"
    sync
    c5_restore_stock "$dst.new" 1
    mv "$dst.new" "$dst"
    sync
    c5_restore_stock "$dst" 1
)
```

All three `c5_restore_stock ... 1` calls are **check-only**: they require
matching entries for both images in `SHA256SUMS` (or `MD5SUMS`), check
image magics, slot mapping and target sizes, and do not write partitions
or the boot flag. The source on `userdata` is never modified; promotion
from `stock.new` happens only after destination verification. Any failure
stops the sequence and unmounts `userdata`; a failed copy may leave
`stock.new` for inspection. Do not blindly rerun or remove an existing
saved copy. A source-checksum failure requires a known-good PC backup,
not a newly generated checksum list for corrupt files.

This manual step migrates **saved repair images only**, not old runtime
scripts, state or chainload helpers. Use the new stick's **Repair stock**
if needed, then complete the stock-side reinstall above to install current
helpers and the no-`userdata` image. Do not copy the old chainload scripts
to `c5os` or use a legacy sysupgrade path as the cutover.

## Failure cases

### 1. Chainload test boot hangs, is unhealthy, or OpenWrt never answers

The flag stays on stock. The test returns there through the watchdog or
health checks:

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

The next stock run of the install stick reports the failure once:
- With the app: "OpenWrt test failed" shows the reason. "Try again" opens
  the menu; "Boot to stock" continues stock startup.
- With or without the app, the log records
  `test: the OpenWrt test boot (VERSION) failed: REASON; stock is unchanged`.
- Headless sticks do not repeat the test ("OpenWrt already tried").

A failed test rewrites the stock flag, resets the `ota` boot log, records
`last-test`, removes `pending-commit` and may change the slot's rootfs
overlay. It does not write the counter, stock-invalid mark, stock slot or
`userdata`. `c5os`'s `opencreator-os/logs/` retains the last completed
`c5-booted` logs. Install already wrote the OpenWrt slot and, on first
install, created `c5os`. Read the `ota` boot log on stock, fix the image and
reinstall.

An unreachable SSH server does not mean the test failed: networking is not
a health gate. Check the flag/boot log before expecting a power cycle to
return to stock. Use the headless install stick's `swap` action if needed.

### 2. OpenWrt boots from the SPL but is not healthy

`c5-booted` reports `booted: NOT healthy (/data not mounted)` or never runs.
The flag stays on OpenWrt and the counter is not reset. After three failed
attempts reaching preinit, the fourth selects stock and reboots if stock is
selectable. It removes `pending-commit` and records
`failed VERSION boot counter: 3 boots of slot N did not become healthy`;
the next stock install-stick run reports it as in case 1.
This also covers failed known-good flips. Power-cycle if the watchdog does
not reset a hang. Failures before preinit cannot be counted (case 7).
Test boots are not counted; they return to stock as in case 1.

Wi-Fi or SSH failure alone is not unhealthy. Inspect the network separately;
use `ACTION=swap` on the install stick if you need stock.

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
- Configuration stays on `c5os` at `/data/opencreator-os/sysupgrade.tgz`
  until the new image's preinit stages it for restoration.

### 5. Stock slot damaged, OpenWrt works

Symptoms: the installer's Swap action refuses stock, `c5_stock_blocker`
prints a reason, or Repair stock reports a checksum problem. An interrupted
repair leaves stock marked invalid and OpenWrt selected. If the flag already
points at broken stock, see case 7.

- Use the install stick with `ACTION=repair-stock`. It verifies the saved
  copy in `/data/opencreator-os/stock/` on `c5os` and reads every write back.
- If `c5os` or its saved copy is bad, use a repaired, mounted `/data` and
  copy the stock slot's images from the PC backup into
  `/data/stock-restore/` over SSH. Name them `kernel.img`
  and `rootfs.squashfs` and create a matching `SHA256SUMS` on the PC before
  copying. For an older printer whose only saved copy is on `userdata`,
  use the explicitly authorized one-off migration above.
  With the install stick mounted (`mount -t vfat /dev/sda1 /mnt`),
  the verified helper can check first, then repair:

  ```sh
  SELF_DIR=/mnt/opencreator-os
  . "$SELF_DIR/lib.sh"
  . "$SELF_DIR/restore.sh"
  c5_restore_stock /data/stock-restore 1 &&
      c5_restore_stock /data/stock-restore 0
  ```

  The flag stays on OpenWrt. After success, use the installer's `swap`
  action to select stock. Source these helpers; they are not standalone.

### 6. Stock `usershare` damaged

Stock's kernel boots, but userspace, SSH and the USB hook on `usershare`
fail. Repair stock does **not** restore this partition. With OpenWrt
selected, copy `usershare.img` and a matching `SHA256SUMS` from the PC backup
to `/data/usershare-restore/`. Mount the install stick at `/mnt` as in case
5, then run on OpenWrt:

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

This refuses mounted targets, selects OpenWrt, marks stock invalid and
verifies the write. After success, run Repair stock or the case 5 helper to
verify/restore stock's slot and clear the mark before selecting stock.
**Do not clear it after a failed write.** If neither system is reachable and
stock is selected, use case 8. No automatic USB usershare-restore action exists.

### 7. Flag points at a slot that never reaches userspace

The SPL keeps booting the same broken slot.

- Broken OpenWrt slot: a kernel or rootfs that dies before preinit never
  increments the counter, even if a warm chainload previously succeeded.
  A failed counter/flag write can also prevent fallback. Chainload-first
  and the kernel identity check reduce this risk, but do not prove cold
  boot. A known-good-kernel upgrade also writes a new rootfs and keeps the
  flag on OpenWrt; interrupted writes are still a risk.
- Broken stock slot as flag target: stock writes first select OpenWrt and
  keep stock marked invalid until verified. Switches to stock check the
  mark and slot magics. Damage that preserves the magics, stock OTA updates
  or outside tampering can still leave broken stock selected.

In both cases no software path is left: go to case 8.

### 8. Neither system boots (last resort, untested)

Ingenic's USB cloner can write eMMC without a running system. It requires
X2600 boot-ROM USB mode and a board-specific cloner configuration.
**Neither is tested on the Creator 5 Pro; entering USB boot mode is unknown.**
Restore a stock slot, `ota.img` (`ota:kernel2` on the reference printer) and,
if needed, `usershare.img` from the PC backup.

Restore `first-mib.bin` (GPT, SPL and U-Boot) only if the boot area was
touched. This project only writes its partition table, sectors 0–33, when
creating `c5os`. A pre-install `first-mib.bin` contains the old table.

### 9. FlashForge firmware update while OpenWrt is installed

**Do not apply FlashForge updates containing a kernel while opencreator-os
is installed.** Stock's OTA scripts write the unselected slot and flip the
flag (**Observed**). Updating from stock overwrites OpenWrt and boots the
new stock, leaving the old stock in the other slot. The printer still
boots, but OpenWrt is gone and slot roles are swapped.
Reinstall opencreator-os from the new stock; see `stock-updates.md`.

### 10. `c5os` or `userdata` damaged

If `c5os` (`/data`) cannot mount, `c5-booted` reports unhealthy and leaves the
flag unchanged. Normal boots fall back after three failures; test boots
return to stock at once (case 1). The USB hook skips the stick because its
stored model is unavailable.

Over SSH, with p8 unmounted, run `e2fsck -f /dev/mmcblk0p8`. If repair fails,
`mkfs.ext4 -F -L c5os /dev/mmcblk0p8` creates an empty filesystem,
**destroying** saved stock images, chainload helpers/kernel, installer
state/logs, imported settings/model, the good-kernel record, pending commit,
swap file and sysupgrade backup. `/etc` remains in the slot overlay.
Re-run the stock install stick to populate `c5os` and create a pending
commit; healthy normal boots alone do not change the flag.
The installer's backup predates `c5os`; phase0 does not back it up.
Outside the installer and manual recovery, stock leaves `c5os` unmounted.

`userdata` (stock's `/usr/data`) holds stock's own data. The only
opencreator-os files kept there by the stock installer are the pre-`c5os`
`/usr/data/opencreator-os/install.log` and partition-creation reboot marker
`/usr/data/opencreator-os/c5os-rebooted`. Once `c5os` is mounted, normal
installer state/logs, saved stock and chainload files live on `c5os`.
Stock Wi-Fi import may still read stock's settings on `/usr/data`.
OpenWrt never mounts `userdata` in normal operation, including stock
repair and sysupgrade. Old saved images may remain there on an unmigrated
printer; see the migration procedure above.

With `userdata` unmounted on OpenWrt, repair it over SSH with
`e2fsck -f /dev/mmcblk0p7`. **Do not write it from stock**, which has it
mounted.

Pre-repartition `userdata.img` backups, including the installer's
`emmc-backup/` and pre-install phase0 `--all` backups, exceed the shrunk
partition and cannot be restored. For a post-repartition backup, use
`ssh root@PRINTER 'dd of=/dev/mmcblk0p7 bs=1M conv=fsync' < userdata.img`,
then check it as below. Lost saved stock images belong on `c5os`;
restore them from the PC backup as in case 5, not into `userdata`.

### 11. Creating `c5os` fails or is interrupted

**Not verified on hardware.** The installer shrinks `userdata`'s filesystem
before rewriting the table, then grows it to the new partition. The
filesystem fits both layouts. Stock's boot script formats `userdata` if it
cannot mount it; after a power loss during this step it should still be
mountable. This does not cover power loss during the partition-table write.

Failures before the table write (`cannot unmount /usr/data (something holds
it open)`, an `e2fsck` error, `resize2fs shrink failed`, "Please free N MB")
leave the table unchanged and `/usr/data` mounted. Run the same install
stick again:
- Without `c5os` in the table, it repeats the step.
- With `c5os`, it compares the table with the kernel's view and reboots once
  if they differ, or finishes growing `userdata` and formatting `c5os`.
- `kernel does not see the new partition table after a reboot` stops the
  installer. Check `opencreator-os-install.log` on the stick.

## Restoring single partitions from the PC backup over SSH

From a system that does **not** use the target partition. A stock slot can be
written from OpenWrt. The OpenWrt slot can be written from stock. Never write
the slot or a partition the running system uses.

```
# on the PC, in the <date>-creator5pro-emmc backup folder
P=<printer ip>; N=3; IMG=kernel2.img   # partition number from partmap.txt
ssh root@$P "dd of=/dev/mmcblk0p$N bs=1M conv=fsync" < $IMG
ssh root@$P "sync; echo 3 > /proc/sys/vm/drop_caches; head -c $(stat -c %s $IMG) /dev/mmcblk0p$N | sha256sum"
grep " $IMG\$" SHA256SUMS                # must print the same checksum
```

For a stock slot, prefer the verified helpers in case 5: they pin OpenWrt
and set the stock-invalid mark before writing. For `usershare`, use case 6.
After a successful repair, select stock with the installer's `swap` action.
From stock, select OpenWrt with that installer's Swap action or chainload.
