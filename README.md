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
- `docs/stock-updates.md`: running a FlashForge firmware update with OpenWrt installed
- `docs/build.md`: building the image and install stick
- `docs/image.md`: kernel, packages and base files
- `docs/printer-facts.md`: observed printer behaviour

Runtime data and recovery files live on the ext4 `c5os` partition, mounted
at `/data` on OpenWrt: `/data/opencreator-os/stock/` is the verified saved
stock slot, and `/data/opencreator-os/chainload/` holds the stock-side
chainload helpers and saved OpenWrt kernel. The stock installer mounts
`c5os` at `/tmp/c5os-config`. Normal OpenWrt operation, including repair
and sysupgrade, never mounts stock `userdata` and has no fallback to it.
Stock-side pre-`c5os` `install.log` and the partition-creation
`c5os-rebooted` marker remain under `/usr/data/opencreator-os/`; normal
installer state/logs move to `c5os` once it is mounted.

Upgrading a printer with the old saved-copy layout requires an explicit
[migration](docs/recovery.md#migrating-an-existing-printer-from-the-old-userdata-layout).
Prefer reinstalling from stock using a newly generated install stick;
automatic reads from the old `userdata` copy are intentionally absent.

## Phase 0 (read-only capture)

Copy `tools/printer/runFirmwareExe.sh` and `tools/printer/phase0.sh` to the
root of a FAT32 stick and boot the printer with it. Before the stock UI
starts, the hook writes facts to `phase0/` on the stick, then stock boots
normally. Add an empty `BACKUP` file to back up the eMMC partitions except
`userdata`; see `docs/install.md`.

## License

GPL-2.0-only. See `LICENSE`.
