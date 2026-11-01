# opencreator-os

OpenWrt-based replacement for stock Linux on the FlashForge Creator 5 and
Creator 5 Pro (Ingenic X2600 host SoC). Installs in the spare eMMC boot slot,
leaving stock in the other slot.

Status: installed and running on a Creator 5 Pro, with the touchscreen
installer, test boot, display and touch. Not yet exercised on hardware: the
watchdog reset and the boot-counter fallback. System tests:
`test/qemu/run.sh`.

- `docs/install.md`: backup, installation, test boot and return to stock
- `docs/recovery.md`: safety mechanisms and failure cases
- `docs/build.md`: building the image and install stick
- `docs/image.md`: kernel, packages and base files
- `docs/printer-facts.md`: observed printer behaviour

## Phase 0 (read-only capture)

Copy `tools/printer/runFirmwareExe.sh` and `tools/printer/phase0.sh` to the
root of a FAT32 stick and boot the printer with it. Before the stock UI
starts, the hook writes facts to `phase0/` on the stick, then stock boots
normally. Add an empty `BACKUP` file to back up the eMMC partitions except
`userdata`; see `docs/install.md`.

## License

GPL-2.0-only. See `LICENSE`.
