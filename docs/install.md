# Installing opencreator-os

Everything happens through USB sticks: build a stick on the PC, copy it to
the root of a FAT32 stick, insert it with the printer off, power on. Stock
runs `runFirmwareExe.sh` from the stick before its UI. Nothing needs a
network, SSH or a serial cable. Remove the stick after each step; otherwise
it runs again on the next boot.

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
tools/make-install-stick.sh --chainload --app ../os-installer/build/mips32/os-installer \
    [--authorized-keys ~/.ssh/id_ed25519.pub] \
    /mnt/f/creator5-dev/opencreator-os-builds/<version> /tmp/stick
```

Copy `/tmp/stick/*` to a FAT32 stick and boot with it. For the eMMC backup
below the stick needs about 8 GB free. The stick holds:

```
runFirmwareExe.sh                      stock's USB hook
opencreator-os/install.sh, lib.sh, switch-to-openwrt.sh
opencreator-os/bin/sfdisk, bin/partx   static util-linux (installer/tools/build.sh)
opencreator-os/os-installer            touchscreen app (--app; optional)
opencreator-os/CHAINLOAD or FLIP, opencreator-os/authorized_keys   (options)
kernel.uimage root.squashfs sysupgrade.tar VERSION chainload/ SHA256SUMS MD5SUMS
```

`runFirmwareExe.sh` copies `opencreator-os/` to `/tmp/c5os` and runs the
installer from there. With `os-installer` on the stick it loads the touch
driver and starts the app, which runs `install.sh --ui` and draws the screens
the installer asks for. Without the app, or when the app finds no display or
touchscreen, `install.sh` runs headless (see below).

### Touchscreen flow

1. **Checking the printer.** The payload checksums, the partition table, the
   running slot, the boot flag, the image sizes, the disk layout and the space
   on `/usr/data`. Nothing is written yet; a failed check ends with "Nothing
   was written". If stock's data would not fit the shrunk `userdata`, a
   screen "Please free N MB on /usr/data" stays up without buttons:
   power-cycle without the stick, delete files from `/usr/data` (stock UI or
   SSH) and try again.
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
      `/usr/data/opencreator-os/stock/` and imports stock's Wi-Fi settings.
   4. It writes OpenWrt into the slot stock is not running from and reads it
      back.
   5. With `--chainload` it test-boots that OpenWrt from RAM
      (`chainload.ko`). The boot flag still points at stock. Without
      `--chainload` or `--flip` it ends on "OpenWrt written to slot N" and
      stock boots on after "Continue".
4. **Swap.** From stock with OpenWrt installed: points the boot flag at
   OpenWrt and reboots into it. When the flag points at OpenWrt: points it
   back at stock, and stock keeps booting.

After a test boot, OpenWrt joins your Wi-Fi. If within 120 s it has an IPv4
address and SSH is listening, and the kernel it runs is the one in its slot,
it points the boot flag at itself. SSH in as `root` (password
`FlashForge2026`, or the key you shipped). `c5-slot status` shows the slots,
the flag and the boot log.

If anything goes wrong at any point up to that, power-cycle: stock boots.
The installer logs to `opencreator-os-install.log` on the stick and to
`/usr/data/opencreator-os/install.log`; the app logs every line it got to
`os-installer.log` on the stick.

`--flip` instead of `--chainload` points the flag at OpenWrt without the RAM
test. It skips the only test of the new kernel before the bootloader runs
it, so do not use it for a new kernel.

### Headless stick

A stick without `os-installer` shows no screens and never makes the backup.
It cannot create `c5os` either: on a printer without `c5os` it stops with
`abort: confirm c5os: no display and no --yes` and writes nothing. Use the
app for the first install; afterwards a headless stick installs and updates
as before. Over SSH to stock,
`sh /mnt/opencreator-os/install.sh --from-stick /mnt --check` prints the plan
and writes nothing; on an untouched printer it includes
`check: c5os: would create (userdata 5828 MiB -> 2018 MiB, c5os 4096 MiB at sector 6676480)`,
afterwards `check: c5os: present`. The other options (`--yes`,
`--action install|swap`, `--backup`, `--ui`, `--hook`) are listed by
`install.sh --help`.

### eMMC backup on the stick

"Back up" copies every partition, the first MiB (GPT and bootloader) and
everything after the last partition (`disk-tail.img`) to `emmc-backup/` on
the stick in 1 GiB chunks, reads it back, compares checksums and then writes
`VERIFIED`. It runs before `c5os` is created, so `userdata` is included at
full size: about 7.3 GB, estimated at 15 to 25 minutes on the printer. If
the stick has too little space, a screen says how much is needed;
power-cycle and choose "Skip backup", or use a larger stick. A verified
backup already on the stick is not made again.

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
partitions never move; write them with the OpenWrt-side recovery stick or
over SSH (`recovery.md`). Its `userdata.img` is larger than the shrunk
`userdata` and cannot be written back. For a restore stick that works after
the repartition, take a new backup with section 1's stick afterwards.

## 3. Later boots

Every boot of OpenWrt points the flag back at stock early in preinit and at
itself again once healthy. A boot that dies after preinit returns to stock
on the next power cycle. A kernel that dies before preinit cannot be caught
this way; see failure case 7 in `recovery.md`.

On OpenWrt, `/data` is `c5os`: logs, `pending-commit`, `sysupgrade.tgz` and
`tryboot-fail-test` live in `/data/opencreator-os/`. OpenWrt mounts `userdata`
only briefly, at `/tmp/c5-userdata`, to read stock's Wi-Fi settings, the
shipped `authorized_keys` and the saved stock images, and to store the kernel
stock's `c5-chainload.sh` stages after a sysupgrade. On a printer without
`c5os` (the USB test before any install) `/data` is `userdata`.

`sysupgrade` writes the other slot, keeps the flag on stock and records the
new image; it becomes the default only after it has booted healthy once.

## 4. Going back to stock

- `c5-slot boot-stock` (flag only) or `c5-restore-stock` (rewrites stock's
  slot from the saved copy first), then reboot.
- Without network: the OpenWrt-side recovery stick (`recovery.md`).
- To remove OpenWrt from the spare slot: a restore stick from a backup whose
  `partmap.txt` matches the printer (see "Backups and the repartition"),
  `tools/make-restore-stick.sh <backup> /tmp/restore --slot1`. "Uninstall" is
  not available yet, and `c5os` stays in place.
