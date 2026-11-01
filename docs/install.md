# Installing opencreator-os

Everything runs from a FAT32 USB stick, inserted with the printer off.

> **Notes**
> - Remove the stick when you're done, or it runs again on the next boot.
> - Don't put opencreator-fs's `runFirmwareExe.sh` on the same stick.
> - Never run a FlashForge firmware update while OpenWrt is installed: it
>   overwrites the OpenWrt slot.

## Install

1. Build the install stick (`build.md`) and copy it to a FAT32 stick. Use a
   16 GB stick if you want the installer to back up the eMMC.
2. Insert the stick and power on. The installer appears before stock's UI.
3. Tap **Install / update opencreator-os**.
4. Tap **Back up** (about 20 min; recommended on the first install) or
   **Skip backup**.
5. First install only: tap **Create partition** (it unlocks after 5 s). This
   shrinks `userdata` to 2 GB and adds a 4 GB `c5os` partition for OpenWrt's
   data. Don't power off or remove the stick; the printer may reboot once.
6. Wait while the installer saves a copy of stock, writes OpenWrt and
   test-boots it. The boot log scrolls on the screen.
7. When **OpenWrt installed** appears, remove the stick and tap **Reboot**.

> **Notes**
> - If `/usr/data` holds more than fits in 2 GB, the installer asks you to
>   free space. Tap **Boot to stock**, delete files from `/usr/data`, and
>   start again.
> - If the test boot fails, the printer returns to stock within about
>   4 minutes (or power-cycle it). Boot with the stick again to see
>   **OpenWrt test failed** and the reason; stock is unchanged. Tap
>   **Try again** or **Boot to stock**.
> - Logs: `opencreator-os-install.log` and `os-installer.log` on the stick.
> - The installer checksums the original eMMC stream while copying it to
>   FAT32-sized chunks, avoiding a separate source checksum pass. It still
>   syncs, drops cached data and independently reads the USB copy back to
>   verify its exact size and whole-partition SHA-256 (or MD5 fallback).
>   The backup and restore format is unchanged.

## Log in

1. Wait for OpenWrt to join Wi-Fi. It uses stock's Wi-Fi settings; an
   `opencreator-os/wifi.conf` on the install stick overrides them.
2. Find the printer's IP address in your router.
3. `ssh root@<printer ip>`, password `root`.

> **Notes**
> - The hostname is `creator5pro` (or `creator5`).
> - Data lives on `/data` (the `c5os` partition), which also holds a 256 MiB
>   swap file. Boot logs are in `/data/opencreator-os/logs/` (`recovery.md`).

## Update OpenWrt

1. Build a new install stick.
2. Insert it into the running printer and reboot.
3. Tap **Update / Repair OpenWrt**. The printer updates and reboots by
   itself; don't power off.
4. If the kernel changed, the printer boots stock first. Insert the stick
   again, reboot, and tap **Swap to OpenWrt** to test-boot the new kernel.
   Then continue as in step 7 of Install.
5. Remove the stick.

> **Note:** an update keeps Wi-Fi, passwords, SSH keys and the hostname.

## Switch between OpenWrt and stock

1. Insert the install stick and reboot.
2. Tap **Swap to stock** (on OpenWrt) or **Swap to OpenWrt** (on stock).
3. Remove the stick when the printer has rebooted.

## Repair stock

If stock is damaged, the stock copy saved at install can be put back:

1. Boot OpenWrt with the install stick inserted.
2. Tap **Repair stock**, then confirm.
3. The printer restores stock and boots it. Remove the stick.

## Without the touchscreen

1. Build the stick without `--app`.
2. Create `opencreator-os/ACTION` on the stick containing one word:

   | ACTION | On stock | On OpenWrt |
   |--------|----------|------------|
   | `install` | Install / update | - |
   | `swap` | Swap to OpenWrt | Swap to stock |
   | `update` | - | Update / Repair OpenWrt |
   | `repair-stock` | - | Repair stock |

3. Insert the stick and reboot.

> **Notes**
> - Do the first install with the touchscreen: a headless stick never creates
>   the `c5os` partition.
> - Without an `ACTION` file, stock defaults to `install`; OpenWrt does nothing.
> - After a failed test boot, a headless stick lets stock start instead of
>   trying again.
> - To see what the installer would do, SSH into stock and run (writes
>   nothing):
>   ```sh
>   mount -t vfat /dev/sda1 /mnt
>   sh /mnt/opencreator-os/install.sh --from-stick /mnt --check
>   ```

## Back up the eMMC without installing

1. Put `tools/printer/runFirmwareExe.sh`, `tools/printer/phase0.sh` and an
   empty file named `BACKUP` on a stick with 2 GB free.
2. Insert it and power on. The backup takes a few minutes, then stock starts.
3. Copy `phase0/` and `phase0-console.txt` to the PC and run
   `tools/verify-backup.sh <phase0 dir>`.

> **Note:** this backup leaves out `userdata`. Backups taken before the
> install can't be used for restore sticks afterwards, because the partition
> table changed. Back up again after installing.

## Remove OpenWrt

- To stop using it, swap to stock.
- To wipe the OpenWrt slot, use a restore stick (`recovery.md`). There is no
  uninstall yet, and `c5os` stays.
