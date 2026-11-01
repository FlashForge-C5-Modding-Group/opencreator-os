# FlashForge firmware updates

A FlashForge update replaces OpenWrt. Plan for a reinstall afterwards.

## What happens

Stock installs an update into the slot it isn't running from, then boots it.
With OpenWrt installed, that slot is OpenWrt's.

| What | Where | After the update |
|------|-------|------------------|
| OpenWrt kernel and system | its slot | overwritten by the new stock |
| OpenWrt settings (`/etc`: password, `uci` changes, packages) | its slot | lost |
| `/data` (`c5os`): stock copy, Wi-Fi, model, SSH keys, logs, swap | its own partition | kept |
| Stock's data (`/usr/data`, `/usr/prog`) | stock's partitions | kept |

Not tested: whether the update copes with the shrunk `userdata` partition.

## Steps

1. On OpenWrt, save your settings to `/data`:
   ```sh
   sysupgrade -b /data/my-settings.tgz
   ```
2. Insert the install stick, reboot and tap **Swap to stock**. Remove the
   stick.
3. Run the FlashForge update from stock as usual.
4. Insert the install stick, reboot and tap **Install / update
   opencreator-os**, then **Skip backup**. This saves a copy of the new stock
   and reinstalls OpenWrt.
5. At **OpenWrt installed**, remove the stick and tap **Reboot**. Wi-Fi, the
   model and SSH keys come back from `/data`.
6. Restore your settings over SSH:
   ```sh
   sysupgrade -r /data/my-settings.tgz && reboot
   ```

> **Note:** until step 4, **Repair stock** would restore the old stock
> version.
