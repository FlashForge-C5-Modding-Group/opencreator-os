# Installing opencreator-os

Copy the files to the root of a FAT32 USB stick, insert it with the printer
off, then power on. Stock runs `runFirmwareExe.sh` before its UI; OpenWrt
has a boot-time USB hook for the same stick. No network, SSH or serial
cable is required. Remove the stick after each step to prevent its selected
action from running again on the next boot.

Do not put opencreator-fs's `runFirmwareExe.sh` on the same stick.
Never apply a FlashForge firmware update while OpenWrt is installed: stock's
updater writes the slot the flag does not point at, which is OpenWrt's.

## 1. Back up the eMMC (once)

1. Copy `runFirmwareExe.sh`, `phase0.sh` (from `tools/printer/`) and an empty
   file named `BACKUP` to a stick with about 2 GB free. This backup excludes
   `userdata`.
2. Boot with it. The backup takes a few minutes before the stock UI appears.
3. Copy `phase0/` and `phase0-console.txt` to the PC, then run
   `tools/verify-backup.sh <copied phase0 dir>`. It joins the images into
   `<date>-creator5pro-emmc/` in the backup directory set in the script, checks the printer's
   checksums and makes the folder read-only.

Use `tools/make-restore-stick.sh` to restore a damaged slot or `usershare`
from this backup (`recovery.md`). The partition table must still match;
see "Backups and the repartition" below.

## 2. Install and test-boot (one stick)

Build the stick as in `build.md` and boot with it. The eMMC backup needs
about 8 GB free on the stick. Stick contents:

```
runFirmwareExe.sh                      stock / OpenWrt USB hook
opencreator-os/install.sh, lib.sh      installer
opencreator-os/slot.sh, restore.sh     the image's /lib/c5/slot.sh; Repair stock helpers
opencreator-os/bin/sfdisk, bin/partx   static util-linux (installer/tools/build.sh)
opencreator-os/os-installer            touchscreen app (--app; optional)
opencreator-os/authorized_keys         optional SSH keys (--authorized-keys)
opencreator-os/ACTION                  optional headless action
kernel.uimage root.squashfs sysupgrade.tar VERSION chainload/ SHA256SUMS MD5SUMS
```

`runFirmwareExe.sh` copies `opencreator-os/` to `/tmp/c5os` and runs the
installer there. With `os-installer` present, it loads stock's touch driver
if available and starts the app, which runs `install.sh --ui`. Without the
app, a display or a touchscreen, the installer runs headless.
On OpenWrt, the same stick and touchscreen menu work; the hook unbinds the
panel's boot-log console (fbcon) while the app runs. `opencreator-os/ACTION`
runs it headless.

The installer accepts only `Creator5:0028` and `Creator5Pro:0029`, passed as
two arguments, e.g. `Creator5Pro 0029`. Both USB hooks supply them. A manual
stock run without arguments reads literal `MACHINE=` and `PID=` values from
`/usr/prog/app_startup.sh` without executing it. Other or missing pairs are
refused before writes; `--check` prints the detected pair.

### Touchscreen flow

1. **Checking the printer.** Checks the model, payload checksums, partition
   table, running slot, boot flag, image sizes, disk layout and `/usr/data`
   space. A failed check ends with "Nothing was written".
   - If stock's data would not fit the shrunk `userdata`, "Please free N MB
     on /usr/data" offers only "Boot to stock". Delete files from
     `/usr/data` using stock's UI or SSH, then reboot with the stick.
   - A failed OpenWrt test boot is reported once: "OpenWrt test failed",
     the reason (e.g. "hung before OpenWrt started (watchdog reset)") and
     "Stock is unchanged and boots normally." "Try again" opens the menu;
     "Boot to stock" ends the installer and continues stock startup.
2. **Menu.** "Install / update opencreator-os", "Swap to OpenWrt" or "Swap to
   stock" (disabled until OpenWrt is installed), and "Uninstall"
   (disabled; not available).
3. **Install / update:**
   1. "Back up the eMMC to this stick first?": "Back up" or "Skip backup".
      See "eMMC backup on the stick".
   2. First install: "Create a 4 GB partition". "Create partition" unlocks
      after 5 s. The installer unmounts `/usr/data`, checks and shrinks its
      filesystem, shrinks `userdata` (p7) from 5,828 MiB to 2,018 MiB and
      adds ext4 `c5os` (p8, 4,096 MiB). The backup GPT moves to the disk's
      end. If the kernel cannot pick up the new table, the printer reboots
      once and installation resumes; **leave the stick in**. Later runs
      skip partition creation.
   3. Saves the running stock kernel and rootfs to
      `/usr/data/opencreator-os/stock/`: the whole kernel partition and the
      rootfs squashfs's `bytes_used`, in 1 MiB blocks plus the final partial
      block. Both are checksum-verified in `stock.new/` before it is renamed
      to `stock/`. Saves stock's Wi-Fi settings, optional stick
      `authorized_keys` and the model in `c5os`'s `opencreator-os/`. A stick
      `opencreator-os/wifi.conf` overrides stock's Wi-Fi settings.
   4. Writes OpenWrt to the other slot and reads it back. A slot already
      holding this build is not rewritten.
   5. Boots OpenWrt. If the slot's kernel matches `c5os`'s `good-kernel`
      (the last healthy OpenWrt boot's kernel), it selects OpenWrt in the
      boot flag and reboots. Otherwise it writes `pending-commit` on
      `c5os` and test-boots OpenWrt from RAM through `chainload.ko`.
      "Test-booting OpenWrt from RAM" may be followed by a blank screen.
      The flag stays on stock until a healthy boot commits it. If OpenWrt
      fails, the printer returns to stock within about 4 minutes.
4. **Swap.** From stock, uses the same known-good-kernel rule as step 5:
   select OpenWrt and reboot, or RAM test-boot with `pending-commit` written
   if missing. When the flag points at OpenWrt, selects stock and continues
   booting stock.

OpenWrt imports saved settings in preinit, before uci-defaults, and attempts
to join Wi-Fi. A healthy boot reaches START=99 with `/data` mounted; IPv4,
an SSH listener and Wi-Fi are not required. With its own slot's kernel and
a matching `pending-commit`, the health service selects OpenWrt in the flag
and removes the marker. Normal healthy boots reset the failed-boot counter
and record `good-kernel`.

Test boots do not count as failed boots. If unhealthy 180 s after preinit,
or immediately if `/data` is not mounted, OpenWrt selects stock and reboots.
An earlier kernel hang is reset by the 120 s watchdog armed by
`chainload.ko`. Stock remains unchanged; see `recovery.md` case 1 for files
left behind. Power-cycling during a test also boots stock.

The outcome is reported once from `c5os`'s `opencreator-os/last-test`:

- **Failure:** the next stock run shows the failure screen and logs
  `test: the OpenWrt test boot (VERSION) failed: REASON; stock is unchanged`.
  A power cycle during the test is reported as a watchdog reset.
- **Success:** if the stick remains inserted after the test boot or flip,
  OpenWrt's hook waits for the health decision, then shows "OpenWrt
  installed" and "The test boot succeeded and OpenWrt is now the boot system.
  Remove the USB stick, then tap Reboot." Reboot boots OpenWrt; if the stick
  remains inserted, the normal OpenWrt menu appears.
  Without a working display, it only logs
  `test: OpenWrt VERSION installed: the test boot succeeded and slot N is the boot system (no display)`
  and OpenWrt keeps running.

The report is renamed to `last-test.seen`. `--check` only logs it. See
`recovery.md` for report details.

SSH: user `root`, password `root`; no key required. Stick `authorized_keys`
is optional. The initial hostname is `creator5` or `creator5pro`, based on
the model; a missing model defaults to `creator5pro`.

Logs: `opencreator-os-install.log` and `os-installer.log` on the stick, and
`/usr/data/opencreator-os/install.log` under stock. Boot-log commands:
`recovery.md`.

A headless stick does not loop. After it starts OpenWrt by flag flip or test
boot, `/usr/data/opencreator-os/install.state` records the attempt per
payload. A later headless stock run logs any test failure, ends with
"OpenWrt already tried" and continues stock startup. The app always allows
Install and Swap retries.

### Headless stick

A stick without `os-installer` shows no screens. On stock it skips backup
unless given `--backup`, and refuses partition creation without `--yes`
(`abort: confirm c5os: no display and no --yes`). Use the app for the first
install; headless sticks can then update or swap slots.

Over SSH to stock, run
`sh /mnt/opencreator-os/install.sh --from-stick /mnt --check` for a plan
without writes. Before installation it includes
`check: c5os: would create (userdata 5828 MiB -> 2018 MiB, c5os 4096 MiB at sector 6676480)`;
afterwards, `check: c5os: present`. It ends with
`check: afterwards: flip (known-good kernel)` or
`check: afterwards: chainload test boot (root=/dev/mmcblk0pN)`.
See `install.sh --help` for options. Stock accepts only `install` and `swap`.

For headless operation, put one word in `opencreator-os/ACTION` on the
stick: `install`, `swap`, `repair-stock` or `update` (Windows line endings
are accepted). An explicit `--action` overrides the file. With no action
file, stock defaults to `install`, but OpenWrt does nothing.

### The same stick on OpenWrt

At boot, `c5-usb-hook` (START=19) mounts the first FAT USB candidate
read-write at `/mnt`, runs `runFirmwareExe.sh` with the model from
`/data/opencreator-os/model`, then unmounts it. Runs are detached and
serialized, with output in syslog; boot, networking and SSH continue while
the app waits for input. A missing or invalid model prevents the hook from
running; see `logread -e c5-usb-hook`. Omit `--app` for headless OpenWrt use.

While a test outcome is pending (a test boot, or `last-test` still `started`
after a flip), START=19 logs
`test boot outcome pending; USB hook deferred until c5-booted`.
`c5-booted` runs the hook after its health decision so the installer reports
the committed result first.

Actions (menu labels require a working display):

| Menu | Headless `ACTION` | What it does |
|------|-------------------|--------------|
| Update / Repair OpenWrt | `update` | Copies `sysupgrade.tar` to `/tmp/sysupgrade.img` and verifies it against the stick's `SHA256SUMS`. Saves settings with `sysupgrade -b`, removes image-owned files (`/etc/config/fstab`) from the backup, checks image and backup with `sysupgrade -T -f`, then runs `sysupgrade -f` with the backup. Shows "Updating OpenWrt / The printer reboots by itself; do not power off." Keeps Wi-Fi, passwords, SSH keys and hostname; resets image-owned files. Reinstalling the running build is allowed. |
| Swap to stock | `swap` | Refuses unselectable stock; clears `pending-commit`, resets the counter, selects stock and reboots. |
| Repair stock | `repair-stock` | Checks and restores the saved stock slot from `userdata` (`/usr/data/opencreator-os/stock/` on stock), reads it back, then selects stock and reboots only if selectable. The app offers "Repair stock" after 5 s or "Cancel"; headless runs do not ask. |

For actions requesting a reboot, status 0 exits the app without a Continue
button and leaves "Rebooting ..." on screen. Failures and cancellations
show Continue; on stock, dismissing that screen resumes startup without
rebooting.

`reboot_now` runs `sync` before rebooting to flush eMMC and USB filesystems.
Stock uses `reboot -f` because its synchronous `sysinit` USB hook can leave
init blocked in `app_startup.sh` after a successful hook, preventing a normal
reboot. OpenWrt uses a normal procd reboot.

Update / Repair OpenWrt prechecks sysupgrade's requirements but ignores its
exit status: a successful handover stops ubusd, so sysupgrade returns
"Connection failed". The installer waits up to 60 s instead. Stage2
terminates the remaining processes, including the installer and app,
leaving the updating screen unresponsive while it writes and reboots. If
the wait expires, handover failed: "Update / Repair FAILED"; nothing was
written.

OpenWrt has no uninstall action because it cannot wipe its own slot.
Repair does not restore `usershare` or use stock images from the stick.
If the saved copy is lost, see `recovery.md`.

### eMMC backup on the stick

"Back up" copies every partition, the first MiB (GPT and bootloader) and
the disk tail after the last partition (`disk-tail.img`) to `emmc-backup/`
in 1 GiB chunks. It reads back and checksums the backup before writing
`VERIFIED`. It precedes partition creation and includes full-size
`userdata`: about 7.3 GB, estimated at 15–25 minutes on the printer.
Insufficient space offers "Boot to stock"; use a larger stick or reboot
and choose "Skip backup". An existing verified backup is not repeated.

Format: `phase0.sh --backup --all` files (`NAME.img.000`, `.001`, ...,
`first-mib.bin`, `SHA256SUMS`, `partmap.txt`, `MANIFEST.txt`), plus
`disk-tail.img` and `VERIFIED`. To import on the PC, with the stick mounted
at `<stick>`:

```sh
mkdir -p /tmp/bk/facts && cp -r <stick>/emmc-backup /tmp/bk/backup
tools/verify-backup.sh /tmp/bk <date>-installer
```

### Backups and the repartition

Restore sticks from pre-repartition backups (the installer's backup or a
section 1 backup taken before installation) are refused once `c5os` exists.
`restore.sh` compares the table against `partmap.txt` and stops with
`the backup was taken from a different partition layout`.

Slot, `ota` and `usershare` images remain valid because those partitions do
not move. Use OpenWrt's repair action for the saved stock slot, or restore
PC backup images over SSH (`recovery.md`). The old `userdata.img` is too
large for the shrunk partition. For a compatible restore stick, repeat
section 1's backup after repartitioning.

## 3. Later boots

Normal OpenWrt boots keep the flag on OpenWrt. Early preinit increments an
`ota` counter; after three consecutive failed boots that reached preinit,
the next attempt selects stock and reboots if stock is selectable.
Healthy boots (START=99 with `/data` mounted) reset the counter. A kernel
failure before preinit cannot advance it. Chainloaded test boots are not
counted and return to stock on failure (section 2).
Procd feeds the hardware watchdog through `/dev/watchdog`; no extra
watchdog daemon is used. **These safety changes are not hardware-verified.**

The fixed `/etc/config/fstab` mounts ext4 label `c5os` at `/data` with
`rw,noatime`, with no `userdata` fallback. `/data/opencreator-os/` holds
`model`, `wifi.conf`, optional `authorized_keys`, `good-kernel`,
`pending-commit`, `last-test` or `last-test.seen`, `sysupgrade.tgz` and
`logs/`. Preinit imports settings only from `c5os` into `/etc/c5/` and
`/etc/dropbear/`, without replacing populated destinations. It stages the
saved sysupgrade configuration, including `/etc/c5/`
(`/lib/upgrade/keep.d/c5`), so OpenWrt edits to `wifi.conf` survive
sysupgrade. OpenWrt mounts `userdata` only briefly for stock repair or to
stage a changed kernel for stock's `c5-chainload.sh`.

`/data/swapfile` is 256 MiB, mode 600. After the health decision on the
first boot without it, `c5-booted` runs `/etc/init.d/c5-swap create`: `dd`
writes it without holes, then `mkswap` initializes it and swap is enabled.
Later boots enable it through fstab's `config swap` when `block` mounts
`/data`. Plain sysupgrade preserves fstab: upgrades from images without
that section get no swap. Use the stick's "Update / Repair OpenWrt" to
reset fstab to the image's.

Creation is skipped if `/data` is not `c5os` or less than 64 MiB would
remain free; see `logread -e c5-swap`. Swappiness stays at the kernel
default, 60. The file is on `c5os`, not the overlay, and survives
sysupgrade. Swap is disabled at shutdown before `/data` is unmounted
(`c5-swap` stop, K89), and before sysupgrade switches to its RAM root.
Otherwise swap would keep `c5os` mounted, requiring journal recovery and
preventing sysupgrade from mounting it read-only to read `good-kernel`.

`sysupgrade` writes the OpenWrt slot from RAM, never the stock slot. If the
new kernel's SHA-256 matches `good-kernel`, it keeps the flag on OpenWrt and
needs no pending commit or chainload. Otherwise it leaves the flag on stock,
stores the new chainload kernel on `userdata` and `pending-commit` on
`c5os`; a healthy test boot with that slot's own kernel commits it.

## 4. Going back to stock

- Boot with the install stick and `opencreator-os/ACTION` containing `swap`.
  If stock is damaged, use `repair-stock` instead; it restores the saved
  stock slot before rebooting. Both actions also work headless, without SSH.
- To remove OpenWrt from the spare slot: a restore stick from a backup whose
  `partmap.txt` matches the printer (see "Backups and the repartition"),
  `tools/make-restore-stick.sh <backup> /tmp/restore --slot1`. "Uninstall" is
  not available yet, and `c5os` stays in place.
