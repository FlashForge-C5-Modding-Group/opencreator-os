# Zero-write USB test

Boots OpenWrt on the printer from a USB stick without writing anything to
the eMMC: no slot, no boot flag, no `userdata`. It checks the hardware
bring-up of the 6.6 kernel before anything is installed.

## How it works

1. Stock boots as usual and its USB hook (`app_startup.sh`) runs
   `runFirmwareExe.sh` from the stick's FAT partition.
2. `usbtest.sh` checks the payload checksums, copies stock's Wi-Fi settings
   to the stick (`opencreator-os-test/wifi.conf`), writes the `ATTEMPTED`
   marker, loads `chainload.ko` with the OpenWrt kernel and jumps to it.
   The command line is stock's, with `root=/dev/sda2` (the squashfs on the
   stick's second partition), `c5.nocommit=1` and `c5.usbtest=1`.
3. OpenWrt runs from the stick. With `c5.usbtest=1` it never writes the
   eMMC: the boot flag, bootlog and stock-invalid writers refuse,
   `userdata` is mounted read-only without journal replay or fsck, the USB
   recovery hook is skipped, and the overlay lives on the stick after the
   squashfs.
4. `c5-usbtest` writes `opencreator-os-test/openwrt/` to the stick (system
   state right after boot and again once Wi-Fi has an address, at most
   180 s later, plus `summary.txt`) and unmounts the stick.
5. The user cuts the power. Stock boots; the hook sees `ATTEMPTED` and lets
   stock continue, so the test runs once per stick.

## Build the stick

```sh
./build.sh
tools/make-test-stick.sh [--authorized-keys ~/.ssh/id_ed25519.pub] \
    /mnt/f/creator5-dev/opencreator-os-builds/<version> /mnt/f/.../c5-usbtest.img
```

Write the image to a stick of at least 256 MB with balenaEtcher or Rufus
(everything on the stick is erased). Windows then shows only the FAT
partition (`C5TEST`); that is expected.

## Run it

1. Printer off, stick in, printer on.
2. Stock's boot screen, then a black screen "USB test / Booting OpenWrt"
   (the screen may go blank or show garbage once OpenWrt runs; OpenWrt has
   no display driver yet).
3. Wait 5 minutes, then switch the printer off and on. Stock boots normally.
4. Put the stick in the PC. The results are in `opencreator-os-test/`:
   - `hook.log`: what stock did before the jump;
   - `openwrt/summary.txt`: one PASS/FAIL line per check, ending in `DONE`;
   - `openwrt/early/`, `openwrt/final/`: `dmesg`, `logread`, mounts, USB,
     tty, GPIO, network and so on.
5. Delete `opencreator-os-test/wifi.conf` from the stick afterwards (it
   holds the Wi-Fi password). To run the test again, delete `ATTEMPTED`.

If Wi-Fi came up, OpenWrt stays reachable over SSH (`root`, password
`FlashForge2026` or the shipped key) until the power is cut.

## Reading the result

| What you see | Meaning |
|---|---|
| `summary.txt` ends in `DONE` | OpenWrt booted from the stick; read the PASS/FAIL lines |
| `openwrt/early/` but no `summary.txt` | OpenWrt hung or the stick was pulled during the wait |
| no `openwrt/`, `hook.log` ends in "jumping" | the new kernel died before userspace (or never found `/dev/sda2`) |
| "refused" screen | `chainload.ko` refused the jump; nothing changed; power-cycle |
| `hook.log` ends in "stock keeps booting" | a check failed before the jump; the line above says which |

In every case the eMMC is unchanged and a power cycle returns to stock.

## What it does not show

A cold boot through the bootloader: stock has already set up clocks and
devices when the jump happens. That is only exercised after an install
(`install.md`), which comes after the eMMC backup.
