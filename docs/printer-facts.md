# Creator 5 Pro facts this project relies on

Labels: **Observed** = read on a printer or in a stock file; **Confirmed** =
several sources agree; **Hypothesis** = not yet verified. Stock artifacts are
named logically with SHA-256; raw captures never enter this repository.

Source of the Observed items: `tools/printer/phase0.sh` run from the stock
USB hook on 2026-10-26 (stock software 1.9.9, kernel package 2.0.7,
Linux 5.10.186+, busybox 1.31.1).

## eMMC and slots (Observed)

| GPT name | Device | Size | Use |
|---|---|---|---|
| `kernel` | mmcblk0p1 | 8 MiB | slot 1 kernel (legacy uImage) |
| `rootfs` | mmcblk0p2 | 100 MiB | slot 1 root (squashfs) |
| `kernel2` | mmcblk0p3 | 8 MiB | slot 2 kernel |
| `rootfs2` | mmcblk0p4 | 100 MiB | slot 2 root |
| `ota` | mmcblk0p5 | 1 MiB | boot flag (`ota:kernel` / `ota:kernel2`) |
| `usershare` | mmcblk0p6 | 1 GiB | stock `/usr/prog`, also mounted on `/etc` |
| `userdata` | mmcblk0p7 | ~5.7 GiB | stock `/usr/data` |

No `rtos` partition exists on this unit even though stock OTA scripts name
one. Image limits: kernel uImage ≤ 8 MiB, root squashfs ≤ 100 MiB.

The installer changes this layout once (not an observation): it shrinks
`userdata` to 2,018 MiB and adds `c5os` (mmcblk0p8, 4,096 MiB, ext4) after
it, ending at the GPT's last usable sector 15,065,087. OpenWrt's fixed fstab
mounts the ext4 filesystem labelled `c5os` at `/data` (`rw,noatime`); there
is no fallback mount of `userdata`.

## Bootloader (Observed; behaviour Confirmed with the stock OTA scripts)

- U-Boot SPL 2013.07 (built Nov 11 2025) in the first MiB.
- It reads the `ota` partition: `ota:kernel2` boots `kernel2` with
  `root=/dev/mmcblk0p4`, anything else boots `kernel` with
  `root=/dev/mmcblk0p2`.
- Fixed command line: `console=ttyS0,115200n8 loglevel=8 mem=236M@0x0
  rmem=16M@0xec00000 rtos_size=4M@0xfc00000 mem=256M@0x30000000
  init=/linuxrc root=/dev/mmcblk0pN rootwait rootfstype=squashfs ro
  lpj=11476992`.
- **Hypothesis** (AD5X analysis of the same SPL family): only the uImage magic
  is checked; no CRC, boot counter or fallback.

## Memory (Observed)

- Lowmem `0x00000000-0x0ebfffff` (236 MiB), highmem `0x30000000-0x3fffffff`.
- `0x0ec00000-0x0fffffff` (rmem for the stock framebuffer, RTOS for the
  RISC-V core) is outside `mem=`, so Linux never maps it.
- chainload: `safe_max = 0x0dc00000` (lowmem end − 16 MiB);
  `kernel_restart_prepare` is visible in `/proc/kallsyms`.

## Device tree (Observed)

The running DTB is byte-identical in kernel packages 2.0.7 and 2.0.8
(SHA-256 `29e46c95…94a7cc`). Enabled: uart0 (`uart0_pe`, console), uart2
(`uart2_pd`, mainBoardGD), uart3 (`uart3_pb`, VDS dryer, RS-485 enable PC3),
uart4 (`uart4_pb`, heaterBoard), uart5 (`uart5_pb`, eBoard), uart7
(`uart7_pc`, levelBoard); msc0 8-bit HS200 1.8 V at 25 MHz, non-removable;
OTG controller `dr_mode=otg` and host controller `dr_mode=host`, both PHYs
with external VBUS detect; both PDMA controllers; i2c3 (no clients); the
RISC-V remoteproc node. No MAC node is enabled and stock never loads its MAC
driver, so the board is treated as having no Ethernet. No `chosen`, `memory`
or `reserved-memory` nodes. `kernel/dts/creator5pro.dts` lists each
difference from this as DEVIATION.

## Peripherals (Observed)

- GPIO chips GPA..GPE at bases 0, 32, 64, 96, 128 → PC11 heartbeat is gpio 75.
- USB: internal hub `05e3:0610` on the OTG controller carries the
  RTL8821CU Wi-Fi (`0bda:c811`), the camera and the front socket. Wi-Fi power
  is PB07 (stock `8821cu.ko power_on=PB07`; active level **Hypothesis**: high).
- Framebuffer: 480x800, virtual 480x1600, 32 bpp, byte order B,G,R,A.
- Stock busybox: has `sha256sum`, `md5sum`, `strings`, `hexdump`, `fbset`,
  `devmem`; `od` rejects `-A` and `-j`; no `partx`, `unsquashfs`, `timeout`.
