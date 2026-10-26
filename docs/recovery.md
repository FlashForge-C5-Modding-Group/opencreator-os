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
  on the AD5X). If the flag points at a slot whose kernel dies before
  OpenWrt's userspace starts, the printer reboots into the same slot forever.
  Everything below is built to make sure the flag never points at an
  OpenWrt image that has not booted successfully at least once.

## Safety mechanisms

**Chainload first.** The installer (`install.sh` from the install stick, or
over SSH) writes OpenWrt into the spare slot and does **not** touch the boot
flag. The first OpenWrt boot is a test boot from RAM: under stock,
`c5-chainload.sh stage /dev/mmcblk0pN` + `go` (or an install stick made with
`tools/make-install-stick.sh --chainload`) loads the OpenWrt kernel with
`chainload.ko` and jumps to it. Nothing on the eMMC changes for this. If the
test boot hangs, a power cycle brings stock back.

**Try-once on every OpenWrt boot.**
1. Early in boot (preinit, before any filesystem is mounted read-write)
   `05_c5_tryboot` points the boot flag at the stock slot. It does not do
   this when stock is not selectable (see "stock-invalid mark" below, or the
   stock slot does not start with a uImage kernel and a squashfs root). Then
   the flag stays on the OpenWrt slot. Falling back to a broken stock could
   not be undone, while this OpenWrt already got as far as preinit.
2. At the end of boot `/etc/init.d/c5-booted` (START=99) checks, in the
   background, that:
   - `/data` is mounted;
   - the test marker `/data/opencreator-os/tryboot-fail-test` is absent;
   - Wi-Fi credentials were imported (`/etc/c5/wifi.conf` or
     `wireless.c5sta.ssid`). Without them the printer cannot be reached, so
     it is never committed;
   - within 120 s, an interface other than `lo` has a global IPv4 address,
     `dropbear` runs, and a socket listens on TCP port 22.

   Only then does it point the flag back at the OpenWrt slot.
3. So an OpenWrt boot that hangs, comes up broken after preinit, or cannot
   be reached over the network leaves the flag on stock. The next power
   cycle boots stock.

A chainload test boot from an eMMC slot runs the same two steps, so a healthy
test boot already makes OpenWrt the default, but only when the chainloaded
kernel is that slot's own kernel. `c5-chainload.sh stage /dev/mmcblk0pN`
compares the staged image with the GPT `kernel`/`kernel2` partition paired
with the rootfs `pN` (`p2`→`p1`, `p4`→`p3`). The image must be exactly one
uImage (64-byte header + `ih_size`) and byte-identical to the start of that
partition. If it is not, or the root is anything else (a USB stick, an
unknown partition), the script adds `c5.nocommit=1` to the command line.
`stage` and `args` print the decision. On such a boot `c5-booted` and
`c5-slot boot-openwrt` leave the flag alone. So a good kernel tested against
a slot whose own kernel is bad never makes that slot the default.

**Sysupgrade is test-then-commit.** `sysupgrade` on OpenWrt points the flag at
stock, writes the new image into the OpenWrt slot, reads it back, and leaves
the flag on stock even when everything verified. Before writing it deletes
the saved chainload kernel and `pending-commit` on userdata. Afterwards it
copies the new kernel to `/data/opencreator-os/chainload/kernel.uimage` and
writes `/data/opencreator-os/pending-commit` (slot, version, date,
checksums). If that fails, sysupgrade fails. The slot then holds the new
image, but no saved kernel exists to stage against it, so reinstall it from
stock with an install stick. `c5-slot status` shows the marker. The printer
then reboots into **stock**. The new image becomes the default only after it
booted once with its own kernel and `c5-booted` found it healthy. That boot
also deletes `pending-commit`. sysupgrade refuses to run while stock is not
selectable (`c5-slot status`, line `stock:`), because it would reboot into
stock. Test it from stock with one of:

- SSH to stock:
  `sh /usr/data/opencreator-os/chainload/c5-chainload.sh stage /dev/mmcblk0pN`
  then `sh /usr/data/opencreator-os/chainload/c5-chainload.sh go`, where
  `/dev/mmcblk0pN` is the OpenWrt rootfs (sysupgrade prints it; `p2` for slot
  1, `p4` for slot 2). The script stages the new kernel because sysupgrade
  copied it there, and `stage` should report `commit: yes`.
- An install stick made with `tools/make-install-stick.sh --chainload` from
  the same build. The installer sees that the slot already holds that image,
  skips the write, and test-boots it. A stick from a different build
  rewrites the slot first.
- `switch-to-openwrt.sh` on stock (the SPL boots it directly; try-once still
  protects everything after preinit, but not a kernel that dies earlier).
  Prefer chainload.

**Writes of stock partitions: flag on OpenWrt, stock marked invalid.**
`c5-restore-stock` and the OpenWrt-side USB recovery hook first point the
flag at the running OpenWrt slot. They then write a **stock-invalid mark**
into one sector of `ota` (offset 128 KiB, with fsync and read back), check
the flag once more, and only then write stock. The mark names the part being
written (`slot` for stock's kernel + rootfs, `usershare`). A part is removed
from the mark only after all its writes read back correctly. While any part
is listed:
- `05_c5_tryboot` keeps the flag on OpenWrt on every boot;
- `c5-slot boot-stock`, the recovery stick's `boot-stock`,
  `c5-restore-stock --reboot` and sysupgrade refuse to select stock.

So a power loss or failed write during a stock restore, even repeated ones,
keeps booting OpenWrt until a restore of that part succeeds. The mark is a
raw sector, so preinit reads it before any filesystem is mounted, and it
does not depend on `userdata`. `c5-slot status` shows it. Observed: stock's
only `ota` writer in its scripts is `mmc_write_str` in `ota_utils.sh`, which
does `echo STR > /dev/mmcblk0p5` (a few bytes at offset 0). Hypothesis, not
checked: `firmwareExe` (a binary) never writes `ota` past the flag either.
If stock did overwrite the mark, its slot magic check still applies.

**The running slot is never written.** sysupgrade writes only the slot it
runs from: that slot's content is in RAM, and the flag points at stock while
it writes. All restore paths write only the other slot or `usershare`, and
refuse a target that is mounted or that is the root device.

**Boot log in the `ota` partition.** Every OpenWrt boot logs its slot and flag
decisions to the 64 KiB at offset 64 KiB of `ota`. Stock never uses that
area. Read it on OpenWrt with `c5-slot bootlog`. On stock (after a fallback):

```
dd if=/dev/mmcblk0p5 bs=512 skip=128 count=128 2>/dev/null | tr -d '\000'
```

The first line is the marker `C5BOOTLOG1`. Each healthy boot also stores
`dmesg`, `logread` and the boot log in `/data/opencreator-os/logs/`. On stock
that directory is `/usr/data/opencreator-os/logs/`.

## What exists to recover with

| What | Where | Made by |
|------|-------|---------|
| Full eMMC backup (`first-mib.bin`, `kernel.img`, `rootfs.img`, `kernel2.img`, `rootfs2.img`, `ota.img`, `usershare.img`, optionally `userdata.img`, `SHA256SUMS`, `MANIFEST.txt`, `partmap.txt`) | `F:/creator5-dev/backups/<date>-creator5pro-emmc/` on the PC (read-only) | `tools/printer/phase0.sh --backup` on the printer, joined and checked with `tools/verify-backup.sh` |
| Stock slot saved at install time (`kernel.img` = whole stock kernel partition, `rootfs.squashfs` = stock squashfs, `SHA256SUMS` or `MD5SUMS`, `MANIFEST.txt`) | `userdata`: `/usr/data/opencreator-os/stock/` on stock = `/data/opencreator-os/stock/` on OpenWrt | `install.sh` |
| `c5-slot status`, `boot-stock`, `boot-openwrt`, `bootlog` | OpenWrt | this repo |
| `c5-restore-stock [--dry-run] [--reboot] [DIR]` | OpenWrt | this repo |
| `switch-to-openwrt.sh` | stock (on the install stick, `opencreator-os/`) | this repo |
| `c5-chainload.sh` + `chainload.ko` | stock, `/usr/data/opencreator-os/chainload/` | `install.sh` |
| Stock-side restore stick (`opencreator-os-restore/`) | runs from stock's USB hook | `tools/make-restore-stick.sh` |
| OpenWrt-side recovery stick (`opencreator-os-recovery/`) | runs early in every OpenWrt boot | by hand, see below |
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
Output: `opencreator-os-restore/result.log`. `restore.conf` becomes
`restore.done` on success and stays in place on failure. One slot per stick.
`--usershare` is refused under stock, because stock has `usershare` mounted;
use the OpenWrt-side stick for that.

This stick needs a working stock userspace. Stock's USB hook is
`/usr/prog/app_startup.sh`, which lives on `usershare`; the stock rootfs
calls it from `S99factory_test_shell` (**Observed** in the stock rootfs). It
cannot repair a stock system whose `usershare` is broken.

Only one `runFirmwareExe.sh` fits on a stick. Do not combine the restore
stick with the install stick or with opencreator-fs's stick. It can share a
stick with the OpenWrt-side `opencreator-os-recovery/` directory.

### OpenWrt-side recovery stick

On every boot from an eMMC slot, `/etc/init.d/c5-usb-recovery` (START=19,
after `/data` is mounted) looks for a FAT USB stick: the first partition
`/dev/sdX1` or an unpartitioned `/dev/sdX`. It waits up to 15 s for the stick
to show up, or 3 s if no USB storage device is attached at all. If the stick
has `opencreator-os-recovery/restore.conf`, it carries out the first
non-comment line of that file (Windows line endings are fine):

| `restore.conf` | Action |
|----------------|--------|
| `boot-stock` | Checks that stock is selectable (not marked invalid, and the slot starts with a uImage kernel and a squashfs root), then points the flag at stock. |
| `restore-stock` | Writes `kernel.img` and `rootfs.squashfs` from `opencreator-os-recovery/` into the stock slot. If the stick has neither file, it uses `/data/opencreator-os/stock/`. |
| `restore-partition usershare` | Writes `usershare.img` (ext4) into `usershare`. OpenWrt does not mount `usershare`. |

Images must be listed in `SHA256SUMS` (or `MD5SUMS`) in the same directory.
They are checked before the write and read back after it. When the action
succeeds, the hook renames `restore.conf` to `restore.done`. It then points
the flag at stock and reboots, but only if stock is selectable. For
`restore-partition` it also requires that stock's kernel and rootfs equal
`kernel.img`/`rootfs.squashfs` on the stick or, if the stick has none, in
`/data/opencreator-os/stock/`, whenever one of them has a verifiable copy.
Otherwise OpenWrt keeps booting with the flag on itself, and
`opencreator-os-recovery/STOCK-NEEDS-REPAIR.txt` on the stick says what is
left (OpenWrt has no display in this release). Repair that with the next
stick, e.g. `restore-stock`. When the action fails, the hook renames
`restore.conf` to `restore.failed`, logs why, and OpenWrt keeps booting. The
flag then points at OpenWrt if anything was written (stock stays marked
invalid), and stays where it was otherwise. Either way, a stick left plugged
in does nothing on the next boot.
The log is `opencreator-os-recovery/result.log` on the stick, copied to
`/data/opencreator-os/logs/recovery-last.log`.

Refused: running from a USB root (not an eMMC slot), the running slot, any
mounted partition, `userdata` (mounted at `/data`, and larger than FAT32's
4 GiB file limit), any other partition name, and images larger than their
partition.

Making the stick from the PC backup (WSL, stick mounted at `/mnt/e`). Use the
images of the slot stock runs from: `kernel2.img` + `rootfs2.img` on the
reference printer. A whole-partition rootfs image works as `rootfs.squashfs`.

```
BK=/mnt/f/creator5-dev/backups/<date>-creator5pro-emmc
mkdir -p /mnt/e/opencreator-os-recovery && cd /mnt/e/opencreator-os-recovery
cp "$BK/kernel2.img" kernel.img
cp "$BK/rootfs2.img" rootfs.squashfs
cp "$BK/usershare.img" .            # only for restore-partition usershare
sha256sum kernel.img rootfs.squashfs usershare.img > SHA256SUMS
printf 'restore-stock\n' > restore.conf
```

For `boot-stock` only `restore.conf` is needed.

## Failure cases

### 1. Chainload test boot hangs or OpenWrt never answers

Nothing on the eMMC changed except the OpenWrt slot, and the flag still
points at stock. Power-cycle: stock boots. Look at
`/usr/data/opencreator-os/logs/` (written only if OpenWrt got as far as
`c5-booted`) and at the boot log in `ota` (see above). Fix the image and run
the installer again; it writes the OpenWrt slot again.

### 2. OpenWrt boots from the SPL but is not healthy

`c5-booted` left the flag on stock (boot log: `booted: NOT healthy (...)`,
e.g. no Wi-Fi credentials, or no IPv4 address / SSH listener within 120 s).
Power-cycle or `reboot`: stock boots. To try OpenWrt again from stock, run
`sh switch-to-openwrt.sh` (install stick or a copy on `/usr/data`) or chainload
again. If OpenWrt hung after preinit, the result is the same: the next power
cycle boots stock.

### 3. OpenWrt runs, you want stock

- `c5-slot boot-stock --reboot` (refuses if the stock slot does not look
  bootable).
- No SSH: plug in an OpenWrt-side recovery stick with `boot-stock` and power
  the printer on.
- Back to OpenWrt later: `switch-to-openwrt.sh` on stock.

### 4. After a sysupgrade

- The printer boots stock; this is expected. Test-boot the new image as
  described above. A healthy test boot commits it.
- Test boot fails: power-cycle into stock. The OpenWrt slot holds the failed
  image, and the flag still points at stock. Install a known-good build with
  the install stick (it rewrites the OpenWrt slot), then chainload-test it.
- sysupgrade reported `READ-BACK MISMATCH`: the flag points at stock and the
  OpenWrt slot is damaged. Same as above: reinstall from stock.
- Your configuration is kept on `userdata` as
  `opencreator-os/sysupgrade.tgz` until the first boot of the new image
  restores it, whichever way that boot happens.

### 5. Stock slot damaged, OpenWrt works

Symptoms: `c5-slot boot-stock` refuses, `c5-slot status` shows
`stock: NOT selectable`, or `c5-restore-stock --dry-run` reports a checksum
problem with the saved copy. A restore that was interrupted or failed leaves
stock marked invalid. OpenWrt then stays the boot slot on every boot until a
restore of the listed part succeeds. If the flag already points at a stock
slot that does not boot, see case 7. Restore it from OpenWrt:

- `c5-restore-stock --dry-run`, then `c5-restore-stock --reboot`. This uses
  `/data/opencreator-os/stock/`.
- If `/data` is gone or the saved copy is bad: an OpenWrt-side recovery
  stick with `restore-stock` and images from the PC backup.
- Over SSH, from the PC backup: copy `kernel.img`, `rootfs.squashfs` (the
  stock slot's images, renamed as for the recovery stick) and a matching
  `SHA256SUMS` into a directory under `/data`, then run
  `c5-restore-stock --reboot DIR`.

### 6. Stock `usershare` damaged

Stock's kernel boots, but its userspace (including SSH and the USB hook,
which live on `usershare`) does not. If OpenWrt is the flag target, use an
OpenWrt-side recovery stick with `restore-partition usershare` and
`usershare.img` from the PC backup. If stock is the flag target, OpenWrt
cannot be reached, so this is case 8.

### 7. Flag points at a slot that never reaches userspace

The SPL keeps booting the same broken slot.

- Broken OpenWrt slot: this needs a kernel or rootfs that dies before preinit
  on an SPL boot after its own kernel passed a chainload test and a healthy
  `c5-booted`. A warm chainload is not a cold-boot proof. Or the tryboot flag
  write failed (boot log: `tryboot: FLAG WRITE FAILED`) and the boot hung
  later. Chainload-first, the kernel identity check and test-then-commit
  exist to make this unlikely.
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
reference printer), and `usershare.img` if needed. `first-mib.bin` (SPL and
U-Boot) only matters if the boot area itself was touched, which nothing in
this project does.

### 9. FlashForge firmware update while OpenWrt is installed

Stock's updater writes the slot the flag does **not** name and then flips the
flag (**Observed** in the stock OTA scripts). Run from stock, it overwrites
the OpenWrt slot. The printer then boots the new stock from there, with the
old stock still in the other slot. This does not brick the printer, but
OpenWrt is gone and the slots have swapped roles. Do not apply FlashForge
updates that contain a kernel while opencreator-os is installed. If it
happens, reinstall opencreator-os from the new stock.

### 10. `userdata` damaged

OpenWrt cannot mount `/data`, `c5-booted` reports not healthy, and the flag
stays on stock. That OpenWrt boot keeps running, though, and `userdata` is not
mounted there, so repair it there over SSH: `e2fsck -f /dev/mmcblk0p7`, or
write `userdata.img` from a `--all` backup with
`ssh root@PRINTER 'dd of=/dev/mmcblk0p7 bs=1M conv=fsync' < userdata.img`
and verify it as described below. Then run `c5-slot boot-openwrt --reboot`.
Do not write `userdata` from stock, which has it mounted as `/usr/data`.
The saved stock images in `opencreator-os/stock/` live on `userdata`. If they
are lost, the PC backup is the source for case 5.

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

Then point the flag where you want it: `c5-slot boot-stock` on OpenWrt, or
`switch-to-openwrt.sh` on stock.
