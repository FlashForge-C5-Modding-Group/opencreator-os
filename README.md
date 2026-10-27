# opencreator-os

OpenWrt-based replacement for the stock Linux on the FlashForge Creator 5 Pro
(Ingenic X2600 host SoC), installed into the spare eMMC boot slot while the
stock system stays in the other slot.

Status: builds and passes the QEMU system tests (`test/qemu/run.sh`); not
yet run on a printer.

- `docs/usb-test.md`: zero-write test boot from a USB stick (first step)
- `docs/install.md`: backup, install, test boot, going back to stock
- `docs/recovery.md`: safety mechanisms and every failure case
- `docs/build.md`: building in WSL
- `docs/printer-facts.md`: what the printer was observed to do

## Phase 0 (read-only capture)

Copy `tools/printer/runFirmwareExe.sh` and `tools/printer/phase0.sh` to the
root of a FAT32 stick, insert it, power the printer on. Stock runs the hook
before its UI, writes facts to `phase0/` on the stick, and then boots
normally. Adding an empty file `BACKUP` also backs up the eMMC; see
`docs/install.md`.

## License

GPL-2.0-only. See `LICENSE`.
