# opencreator-os

OpenWrt-based replacement for the stock Linux on the FlashForge Creator 5 Pro
(Ingenic X2600 host SoC), installed into the spare eMMC boot slot while the
stock system stays in the other slot.

Status: under construction. Do not install yet.

## Phase 0 (read-only capture and backup)

Copy `tools/printer/runFirmwareExe.sh` and `tools/printer/phase0.sh` to the
root of a FAT32 stick with at least 8 GB free, insert it, power the printer on.
Stock runs the hook before its UI, writes facts and a partition backup to
`phase0/` on the stick, and then boots normally. Import on the PC with
`tools/verify-backup.sh <copied phase0 dir>`.

## License

GPL-2.0-only. See `LICENSE`.
