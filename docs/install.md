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
`usershare` is ever damaged (see `recovery.md`).

## 2. Install and test-boot (one stick)

```sh
./build.sh
tools/make-install-stick.sh --chainload [--authorized-keys ~/.ssh/id_ed25519.pub] \
    /mnt/f/creator5-dev/opencreator-os-builds/<version> /tmp/stick
```

Copy `/tmp/stick/*` to the stick and boot with it. The installer:

1. checks the payload checksums, the partition table, the running slot, the
   boot flag and the image sizes, and stops before writing if any check fails;
2. saves the running stock kernel and rootfs to `/usr/data/opencreator-os/stock/`
   and imports stock's Wi-Fi settings;
3. writes OpenWrt into the slot stock is not running from and reads it back;
4. test-boots that OpenWrt from RAM (`chainload.ko`). The boot flag still
   points at stock.

OpenWrt then joins your Wi-Fi. If within 120 s it has an IPv4 address and SSH
is listening, and the kernel it runs is the one in its slot, it points the
boot flag at itself. SSH in as `root` (password `FlashForge2026`, or the key
you shipped). `c5-slot status` shows the slots, the flag and the boot log.

If anything goes wrong at any point up to that, power-cycle: stock boots.
The screen shows the installer's progress and result (`installing`,
`written`, `chainload`, `done`, `failed`, `chainload-failed`).

`--flip` instead of `--chainload` points the flag at OpenWrt without the RAM
test. It skips the only test of the new kernel before the bootloader runs
it, so do not use it for a new kernel.

## 3. Later boots

Every boot of OpenWrt points the flag back at stock early in preinit and at
itself again once healthy. A boot that dies after preinit returns to stock
on the next power cycle. A kernel that dies before preinit cannot be caught
this way; see "What cannot be recovered without the cloner" in `recovery.md`.
on the next power cycle. A kernel that dies before preinit cannot be caught
this way; see failure case 7 in `recovery.md`.
new image; it becomes the default only after it has booted healthy once.

## 4. Going back to stock

- `c5-slot boot-stock` (flag only) or `c5-restore-stock` (rewrites stock's
  slot from the saved copy first), then reboot.
- Without network: the OpenWrt-side recovery stick (`recovery.md`).
- To remove OpenWrt from the spare slot: a restore stick from the backup,
  `tools/make-restore-stick.sh <backup> /tmp/restore --slot1`.
