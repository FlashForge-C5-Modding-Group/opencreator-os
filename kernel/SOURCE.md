# Kernel source

| | |
|---|---|
| Tarball | `ingenic-linux-kernel6.6-x2600-v1.0-20250221.tar.bz2` (680,775,459 bytes) |
| MD5 | `2ae10ef28565e357051437c6262013e8`, from adjacent `md5sum.txt` |
| FTP | [Ingenic X2600 6.6 SDK](ftp://ftp.ingenic.com.cn/DevSupport/X2600E/01_SW/06_kernel6.6_x2600-sdk_v1.0-20250221/01_ingenic-linux-kernel6.6-x2600-v1.0-20250221/); public login `ingenic_public` / `BFdg2f9B12` |
| Used part | `kernel/kernel-6.6` (Linux 6.6.18, `localversion-rt` = `-rt23`) |
| Mirror | [Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221](https://github.com/Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221), `kernel/kernel-6.6` |

This 6.6 SDK supplies the opencreator-os image kernel. The
[5.10 SDK](../chainload/README.md#sdk-source) supplies the stock-compatible
chainload module's build prerequisites.

`kernel/prepare.sh` uses `INGENIC_SDK_TARBALL` when set; otherwise it uses
the archive in `INGENIC_SDK_DIR`, or downloads it there. That directory
defaults to `${INGENIC_DOWNLOAD_DIR:-${WORK:-$HOME/build/opencreator-os}/downloads}`.
A missing explicit tarball fails without downloading. Before extraction,
the archive must match the pinned MD5 above; a checksum mismatch fails
without replacing the archive.

Preparation extracts only `kernel/kernel-6.6` to
`$WORK/ingenic-6.6/kernel/kernel-6.6` (`WORK` defaults to
`~/build/opencreator-os`). An existing extracted tree is reused without
rechecking or unpacking the archive. Every run copies
`dts/creator5pro.dts` to `module_drivers/dts/x2600/` and applies
`patches/*.patch` idempotently, then prints the kernel source path on the
final stdout line.
