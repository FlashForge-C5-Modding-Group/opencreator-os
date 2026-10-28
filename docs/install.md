# Installing opencreator-os

Everything happens through USB sticks: build a stick on the PC, copy it to
the root of a FAT32 stick, insert it with the printer off, power on. Stock
runs `runFirmwareExe.sh` from the stick before its UI; OpenWrt has its own
boot-time USB hook for the same stick. Nothing needs a network, SSH or a
serial cable. Remove the stick after each step; otherwise its selected
action can run again on the next boot.

Do not put opencreator-fs's `runFirmwareExe.sh` on the same stick.
Never apply a FlashForge firmware update while OpenWrt is installed: stock's
updater writes the slot the flag does not point at, which is OpenWrt's.

## 1. Back up the eMMC (once)

1. Copy `runFirmwareExe.sh`, `phase0.sh` (from `tools/printer/`) and an empty
   file named `BACKUP` to a stick with about 2 GB free.
2. Boot with it. The backup takes a few minutes before the stock UI appears.
3. Copy `phase0/` and `phase0-console.txt` to the PC, then in WSL:
   `tools/verify-backup.sh <copied phase0 dir>`. It joins the images into
   `F:/creator5-dev/backups/<date>-creator5pro-emmc/`, checks them against the
   printer's checksums and makes the folder read-only.

The backup is what `tools/make-restore-stick.sh` writes back if a slot or
`usershare` is ever damaged (see `recovery.md`), as long as the partition
table has not changed; see "Backups and the repartition" below.

## 2. Install and test-boot (one stick)

```sh
./build.sh
installer/tools/build.sh                    # static sfdisk and partx for the stick
(cd ../os-installer && make mips32)         # touchscreen app
tools/make-install-stick.sh --app ../os-installer/build/mips32/os-installer \
    [--authorized-keys ~/.ssh/id_ed25519.pub] \
    /mnt/f/creator5-dev/opencreator-os-builds/<version> /tmp/stick
```

Copy `/tmp/stick/*` to a FAT32 stick and boot with it. For the eMMC backup
below the stick needs about 8 GB free. The stick holds:

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
installer from there. With `os-installer` on the stick it loads stock's touch
driver when present and starts the app, which runs `install.sh --ui` and
draws the screens the installer asks for. Without the app, or when the app
finds no display or touchscreen, `install.sh` runs headless (see below).
On OpenWrt the kernel shows its boot log on the panel; the hook unbinds that
console (fbcon) while the app runs and binds it again when the app exits.
**Use headless actions on OpenWrt until display bring-up is verified on
hardware; no OpenWrt screen is promised.** The changes described here have
not been validated on a printer.

The installer accepts only `Creator5:0028` and `Creator5Pro:0029` (passed
as two arguments, e.g. `Creator5Pro 0029`). Both USB hooks supply these
arguments. A manual stock run without arguments reads literal `MACHINE=`
and `PID=` values from `/usr/prog/app_startup.sh`, without executing it.
Other or missing pairs are refused before writes; `--check` prints the
detected pair.

### Touchscreen flow

1. **Checking the printer.** The model, payload checksums, the partition
   table, the running slot, the boot flag, the image sizes, the disk layout
   and the space on `/usr/data`. Nothing is written yet; a failed check ends
   with "Nothing was written". If stock's data would not fit the shrunk
   `userdata`, a screen "Please free N MB on /usr/data" offers only "Boot to
   stock": tap it, delete files from `/usr/data` (stock UI or SSH), then
   reboot with the stick. If the last test boot of OpenWrt failed, the next
   screen says so once: "OpenWrt test failed", the reason (e.g. "hung before
   OpenWrt started (watchdog reset)") and "Stock is unchanged and boots
   normally." "Try again" goes on to the menu; "Boot to stock" ends the
   installer and stock boots on.
2. **Menu.** "Install / update opencreator-os", "Swap to OpenWrt" or "Swap to
   stock" (disabled while OpenWrt is not installed), and "Uninstall"
   (disabled, not yet available).
3. **Install / update:**
   1. "Back up the eMMC to this stick first?": "Back up" or "Skip backup"
      (see "eMMC backup on the stick").
   2. First install only: "Create a 4 GB partition". The "Create partition"
      button unlocks after 5 seconds. The installer unmounts `/usr/data`,
      checks and shrinks its filesystem, shrinks `userdata` (p7) from
      5,828 MiB to 2,018 MiB and adds the ext4 partition `c5os` (p8,
      4,096 MiB) after it; the backup GPT moves to the end of the disk. If
      the kernel does not pick up the new table, the printer reboots once and
      the installer continues on the next boot; leave the stick in. Later
      runs find `c5os` and skip this step.
   3. It saves the running stock kernel and rootfs to
      `/usr/data/opencreator-os/stock/`. It saves stock's Wi-Fi settings,
      optional stick `authorized_keys` and the model on `c5os` in
      `opencreator-os/`. A hand-written stick `opencreator-os/wifi.conf`
      takes precedence over stock's Wi-Fi.
   4. It writes OpenWrt into the slot stock is not running from and reads it
      back (a slot that already holds this build is not rewritten).
   5. It always ends in OpenWrt. If the slot's kernel matches `c5os`'s
      `good-kernel` (the kernel of the last healthy OpenWrt boot, e.g. when
      the same build is reinstalled), it points the boot flag at OpenWrt and
      reboots. Otherwise it writes `pending-commit` on `c5os` and test-boots
      that OpenWrt from RAM (`chainload.ko`), "Test-booting OpenWrt from
      RAM": the boot flag stays on stock until the healthy boot commits it.
      The screen may go blank; if OpenWrt does not come up, the printer
      returns to stock by itself within about 4 minutes.
4. **Swap.** From stock with OpenWrt installed: the same rule as step 5, for
   the kernel in OpenWrt's slot: a known-good kernel gets the boot flag and a
   reboot, any other a RAM test boot (with `pending-commit` written if
   missing). When the flag points at OpenWrt: points it back at stock, and
   stock keeps booting.

After a test boot, OpenWrt imports the saved settings in preinit, before
uci-defaults, and attempts to join your Wi-Fi. Reaching START=99 with
`/data` mounted is healthy; there is no IPv4, SSH-listener or Wi-Fi timeout
gate. With its own slot's kernel and a matching `pending-commit`, the health
service points the flag at OpenWrt and removes the marker. Normal healthy
boots only reset the failed-boot counter and record `good-kernel`.

A test boot does not count as a failed boot. It must be healthy within
180 s after preinit; otherwise, or at once when `/data` is not mounted,
OpenWrt points the flag back at stock and reboots. A kernel that hangs
earlier is reset by the watchdog `chainload.ko` armed for the jump (120 s).
Either way stock boots, unchanged; `recovery.md` case 1 lists what is left
behind.

How the boot went is reported once, from `c5os`'s
`opencreator-os/last-test` (`recovery.md`). A failure is reported by the next
stock run of the stick (screen above, and the log line
`test: the OpenWrt test boot (VERSION) failed: REASON; stock is unchanged`);
a power cycle during the test is reported as a watchdog reset. Success is
reported by OpenWrt when the stick is still in after the test boot or flip:
the USB hook waits until the health service has decided, then the installer
shows "OpenWrt installed": "The test boot succeeded and OpenWrt is now the
boot system. Remove the USB stick, then tap Reboot." "Reboot" boots OpenWrt
again (the flag already names it); with the stick still in, that boot shows
the normal OpenWrt menu. Without a working display only the log line
`test: OpenWrt VERSION installed: the test boot succeeded and slot N is the boot system (no display)`
is written and OpenWrt keeps running. The report is then renamed to
`last-test.seen`. `--check` only logs the report.

SSH in as `root`, password `FlashForge2026`; **no key is needed**.
`authorized_keys` on the stick is optional. The model sets the initial
hostname to `creator5` or `creator5pro` (missing model defaults to
`creator5pro`).

A failed test boot returns to stock by itself; power-cycling also boots stock.
Lack of Wi-Fi alone does not prevent a commit. The installer logs to
`opencreator-os-install.log` on the stick and to
`/usr/data/opencreator-os/install.log` under stock; the app logs to
`os-installer.log` on the stick. See `recovery.md` for boot-log commands.

A headless stick that stays in does not loop: once it has started OpenWrt
(flipped the flag or begun a test boot; recorded per payload in
`/usr/data/opencreator-os/install.state`), a later headless run of the same
stick on stock logs a failed test (if any), ends with "OpenWrt already
tried" and stock boots on. With the app, Install and Swap may always be
retried.

### Headless stick

A stick without `os-installer` shows no screens. Headless stock skips the
backup unless run with `--backup`, and refuses to create `c5os` unless
`--yes` was supplied (`abort: confirm c5os: no display and no --yes`).
Use the app for the first install; afterwards a headless stick can update
or swap slots. Over SSH to stock,
`sh /mnt/opencreator-os/install.sh --from-stick /mnt --check` prints the plan
and writes nothing; on an untouched printer it includes
`check: c5os: would create (userdata 5828 MiB -> 2018 MiB, c5os 4096 MiB at sector 6676480)`,
afterwards `check: c5os: present`. The plan also says how the run ends:
`check: afterwards: flip (known-good kernel)` or
`check: afterwards: chainload test boot (root=/dev/mmcblk0pN)`. The other
options (`--yes`, `--action install|swap|repair-stock|update`, `--backup`,
`--ui`, `--hook`) are listed by `install.sh --help`; stock accepts only
`install` and `swap`.

For headless operation, put one word in `opencreator-os/ACTION` on the
stick: `install`, `swap`, `repair-stock` or `update` (Windows line endings
are accepted). An explicit `--action` overrides the file. With no action
file, stock defaults to `install`, but OpenWrt does nothing.

### The same stick on OpenWrt

At boot, `c5-usb-hook` (START=19) mounts the first FAT USB candidate
read-write at `/mnt`, runs its `runFirmwareExe.sh` with the model stored in
`/data/opencreator-os/model`, and unmounts it when `runFirmwareExe.sh` returns. The
stick runs detached, one run at a time, with its output in syslog: boot,
network and SSH go on while a screen waits for a tap.
Missing or invalid stored model means no hook; see `logread -e c5-usb-hook`.
For now omit `--app` when building a stick for headless OpenWrt use.

While the outcome of an installer test boot is open (a test boot, or
`last-test` still `started` after a flip), the hook does not run at
START=19. It logs `test boot outcome pending; USB hook deferred until
c5-booted`, and `c5-booted` runs it once it has decided, so the installer
sees the committed result and first reports it ("OpenWrt installed",
above).

The backend offers these actions (menu labels apply when a display works):

| Menu | Headless `ACTION` | What it does |
|------|-------------------|--------------|
| Update / Repair OpenWrt | `update` | Checks `sysupgrade.tar` against the stick's `SHA256SUMS`, runs `sysupgrade -T`, saves the configuration with `sysupgrade -b`, drops the files the image owns (`/etc/config/fstab`) from it, then runs `sysupgrade -f` with that backup. User settings (Wi-Fi, passwords, SSH keys, hostname) stay; the image-owned files are reset to the image's. Reinstalling the running build is allowed and repairs those files. |
| Swap to stock | `swap` | Refuses unselectable stock; clears `pending-commit`, resets the counter, selects stock and reboots. |
| Repair stock | `repair-stock` | Checks and restores the saved stock slot from `userdata` (`/usr/data/opencreator-os/stock/` on stock), reads it back, then selects stock and reboots only if selectable. The app asks first ("Repair stock" enabled after 5 s, or "Cancel"); headless runs do not ask. |

On stock and OpenWrt the installer exits with status 0 once it has asked for
a reboot, and the app then exits at once without a Continue button, leaving
the "Rebooting ..." screen up (stock acts on the reboot only after its USB
hook returns). Failures and cancels (non-zero status) show Continue.

There is no uninstall action on OpenWrt: it cannot wipe its own slot.
Repair does not restore `usershare`, and it does not take stock images from
the stick; see `recovery.md` if the saved copy is lost.

### eMMC backup on the stick

"Back up" copies every partition, the first MiB (GPT and bootloader) and
everything after the last partition (`disk-tail.img`) to `emmc-backup/` on
the stick in 1 GiB chunks, reads it back, compares checksums and then writes
`VERIFIED`. It runs before `c5os` is created, so `userdata` is included at
full size: about 7.3 GB, estimated at 15 to 25 minutes on the printer. If
the stick has too little space, a screen says how much is needed and offers
"Boot to stock": then use a larger stick, or reboot with this one and choose
"Skip backup". A verified backup already on the stick is not made again.

The files have the format of `phase0.sh --backup --all` (`NAME.img.000`,
`.001`, ..., `first-mib.bin`, `SHA256SUMS`, `partmap.txt`, `MANIFEST.txt`)
plus `disk-tail.img` and `VERIFIED`. To import them on the PC like a phase0
backup (WSL, stick at `/mnt/e`):

```sh
mkdir -p /tmp/bk/facts && cp -r /mnt/e/emmc-backup /tmp/bk/backup
tools/verify-backup.sh /tmp/bk <date>-installer
```

### Backups and the repartition

A restore stick (`tools/make-restore-stick.sh`) made from a backup taken
before the repartition, i.e. the installer's backup or a section 1 backup
from before the first install, is refused on a printer that has `c5os`:
`restore.sh` compares the partition table with the backup's `partmap.txt`
and stops with `the backup was taken from a different partition layout`.
The slot, `ota` and `usershare` images in it are still valid, because those
partitions never move; use the OpenWrt repair path for the saved stock slot,
or restore from the PC backup over SSH (`recovery.md`). Its `userdata.img`
is larger than the shrunk `userdata` and cannot be written back. For a
restore stick that works after the repartition, take a new backup with
section 1's stick afterwards.

## 3. Later boots

Normal OpenWrt boots leave the boot flag on OpenWrt. Early preinit increments
a counter in `ota`; after three consecutive failed boots that reached
preinit, the next attempt selects stock and reboots, provided stock is
selectable. Healthy boots (START=99 with `/data` mounted) reset the counter.
A kernel that dies before preinit cannot advance it. Test boots chainloaded
from stock are not counted; they fail back to stock themselves (section 2).
The built-in hardware watchdog is fed by procd through `/dev/watchdog`; no
extra watchdog daemon is used. These safety changes are not
hardware-verified.

The fixed `/etc/config/fstab` mounts ext4 label `c5os` at `/data` with
`rw,noatime`, with no `userdata` fallback. `/data/opencreator-os/` holds
`model`, `wifi.conf`, optional `authorized_keys`, `good-kernel`,
`pending-commit`, `last-test` (or `last-test.seen`), `sysupgrade.tgz` and
`logs/`. Preinit imports settings only from `c5os` into `/etc/c5/` and
`/etc/dropbear/` if the destination is not already populated. It also
stages the saved sysupgrade configuration,
which includes `/etc/c5/` (`/lib/upgrade/keep.d/c5`), so a `wifi.conf`
edited on OpenWrt survives a sysupgrade.
OpenWrt mounts `userdata` only briefly to repair stock or stage a changed
kernel for stock's `c5-chainload.sh`.

`/data/swapfile` is a 256 MiB swap file (mode 600). After the health
decision on the first boot that finds it missing, `c5-booted` runs
`/etc/init.d/c5-swap create`, which writes it with `dd` (no holes), runs
`mkswap` and turns it on; later boots turn it on only through the fixed
fstab's `config swap` section when `block` mounts `/data`. A plain
sysupgrade keeps the old fstab, so an install upgraded that way from an image
whose fstab had no such section gets no swap; "Update / Repair OpenWrt" from
the install stick resets fstab to the image's. It is
not created when `/data` is not `c5os` or when `c5os` would keep less than
64 MiB free (`logread -e c5-swap` says why). Swappiness stays at the kernel
default (60). The file lives on `c5os`, not in the overlay, so sysupgrade
keeps it.
Swap is turned off at shutdown before `/data` is unmounted (`c5-swap`
stop, K89) and by sysupgrade before it switches to its RAM root; otherwise
the file would keep `c5os` mounted, leaving it to journal recovery, and
sysupgrade could not mount it read-only to read `good-kernel`.

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
