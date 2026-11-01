# Kernel source

| | |
|---|---|
| Tarball | `ingenic-linux-kernel6.6-x2600-v1.0-20250221.tar.bz2` (680,775,459 bytes) |
| MD5 | `2ae10ef28565e357051437c6262013e8`, from adjacent `md5sum.txt` |
| FTP | `ftp://ftp.ingenic.com.cn/DevSupport/X2600E/01_SW/06_kernel6.6_x2600-sdk_v1.0-20250221/01_ingenic-linux-kernel6.6-x2600-v1.0-20250221/`; public login `ingenic_public` / `BFdg2f9B12` |
| Local copy | `D:/ingenic/X2600/06_kernel6.6_x2600-sdk_v1.0-20250221/` |
| Used part | `kernel/kernel-6.6` (Linux 6.6.18, `localversion-rt` = `-rt23`) |
| Mirror | github.com/Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221, `kernel/kernel-6.6` |

`kernel/prepare.sh` extracts only `kernel/kernel-6.6` to
`$WORK/ingenic-6.6/kernel/kernel-6.6`, copies `dts/creator5pro.dts` to
`module_drivers/dts/x2600/`, and applies `patches/*.patch` idempotently.
