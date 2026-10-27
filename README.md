# opencreator-os

OpenWrt-based replacement for the stock Linux on the FlashForge Creator 5
and Creator 5 Pro (Ingenic X2600 host SoC), installed into the spare eMMC
boot slot while the stock system stays in the other slot.

Status: hardware bring-up in progress. The boot safety and installer changes
described here are not yet validated on a printer; see `test/qemu/run.sh`
for the system tests. OpenWrt-side installation is headless until display
bring-up is verified on hardware.

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
