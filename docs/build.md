# Building opencreator-os

Requires x86-64 Linux and about 50 GB of disk.

## 1. Install packages

```sh
sudo apt install bc build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync \
  swig unzip zlib1g-dev file wget curl device-tree-compiler u-boot-tools \
  python3-pil squashfs-tools shellcheck
```

## 2. Clone the repositories

```sh
git clone https://github.com/FlashForge-C5-Modding-Group/opencreator-os.git
git clone --recurse-submodules https://github.com/FlashForge-C5-Modding-Group/os-installer.git
cd opencreator-os
```

Run the remaining steps from `opencreator-os/`.

## 3. Build the stick helpers

Both helpers prepare the Ingenic toolchain automatically at
`~/ing/mips-xburst2-linux-toolchain-r6.0.0`. Chainload also extracts and builds
Ingenic's 5.10.186 kernel for the stock-compatible module. The OS image uses
the separate 6.6 SDK.

Optional settings must be exported before running the helpers:

| Variable | Use |
|---|---|
| `INGENIC_TOOLCHAIN_TARBALL` | Existing `mips-xburst2-linux-toolchain-r6.0.0.tar.bz2` |
| `INGENIC_510_SDK_TARBALL` | Existing `ingenic-linux-kernel4.4.94-kernel5.10-x2600-v2.0-20230906.tar.bz2` |
| `INGENIC_SDK_TARBALL` | Existing `ingenic-linux-kernel6.6-x2600-v1.0-20250221.tar.bz2` |
| `INGENIC_DOWNLOAD_DIR` | Shared archive cache |
| `WORK` | OS build workspace; default `~/build/opencreator-os` |
| `TC` | Already-extracted toolchain instead of the default installation |
| `KSRC` / `KOUT` | 5.10 source / build directory; default `~/ing/kernel-5.10` / `~/ing/out` |

Use absolute Linux/WSL paths. For each archive, setup uses the explicit
tarball override first, then a cached archive, otherwise downloads it.
The shared cache defaults to `$WORK/downloads` (or
`~/build/opencreator-os/downloads` when `WORK` is unset).
`INGENIC_SDK_DIR` overrides the archive cache for 6.6 only.
Archives are checksum-verified before extraction; downloads are verified
before entering the cache. Missing explicit archive paths fail without
downloading. A checksum mismatch fails without replacing the archive;
remove or replace a bad cached file before retrying. Missing explicit
`TC` or `KSRC` also fails.
Existing extracted trees and prepared build output are reused without
unpacking or rechecking their archives.
Explicit pre-extracted `TC` / `KSRC` overrides bypass their corresponding
archive settings.

```sh
installer/tools/build.sh
chainload/build.sh
```

Output: `installer/tools/out/` and `chainload/out/`. See
[`chainload/README.md`](../chainload/README.md#build) for the 5.10 preparation
and ABI checks.

## 4. Build the image

```sh
export OUT=~/opencreator-os-builds
./build.sh
```

The first build takes hours. Output: `$OUT/<version>/`, where `<version>` is
`git describe --always --dirty --tags`.

Incremental builds reuse the resolved OpenWrt configuration when the generated
seed (including version and kernel path), OpenWrt release, feeds and target
contents are unchanged. Missing or edited `.config` files are regenerated.
`--menuconfig` and `--kernel-menuconfig` still start from the seed; save
permanent changes in `config/openwrt.seed` or `feed/x2600/config-6.6`.
Sources download as needed during `world`, without a separate download pass.

## 5. Build the touchscreen app

The app uses the toolchain installed by step 3. If you exported a custom
`TC`, first run `export INGENIC_TOOLCHAIN="$TC"`.

```sh
(cd ../os-installer && make mips32)
```

## 6. Build the printer stack (optional)

The stack (`stack.md`) packs Kalico, Moonraker with the procd provider and
opencreator-fs's configuration from checkouts next to this repo
(`../kalico`, `../moonraker-procd`, `../opencreator-fs`; each checkout's
`HEAD`), plus the OpenWrt packages `./build.sh` built:

```sh
tools/make-stack.sh ~/build/opencreator-os/stack-out
```

`--kalico DIR`, `--moonraker DIR` and `--opencreator-fs DIR` choose other
checkouts. Downloads pinned in `stack/sources.txt` are cached in
`~/build/opencreator-os/stack-dl`.

## 7. Assemble the stick

```sh
tools/make-install-stick.sh --app ../os-installer/build/mips32/os-installer \
    --stack ~/build/opencreator-os/stack-out \
    "$OUT/$(git describe --always --dirty --tags)" stick/
```

Leave out `--stack` for a stick that installs OpenWrt only.

## 8. Copy to a USB stick

Copy the contents of `stick/` to the root of a FAT32 stick (16 GB to fit the
installer's eMMC backup), then check it from the stick's root:

```sh
sha256sum -c --quiet SHA256SUMS && echo OK
```

To install, see `install.md`.

## Source archives

- [Ingenic toolchain r6.0.0](ftp://ftp.ingenic.com.cn/Ingenic-MIPS-Toolchain/releases/ingenic-mips-toolchain-r6.0.0/mips-xburst2-linux-toolchain-r6.0.0.tar.bz2):
  SHA-256 `4e3359e32c2fb7d9e573ce84370220a66e3998bb911452d82267394fad4086e0`.
- [5.10 SDK source and MD5](../chainload/README.md#sdk-source).
- [6.6 SDK source and MD5](../kernel/SOURCE.md).

Downloads use Ingenic's public FTP login. Override it with
`INGENIC_FTP_USER` / `INGENIC_FTP_PASS` if needed.

## Optional QEMU tests

These validate the installer in an emulator; they are not required to build
or assemble the install stick. The first run builds a separate test kernel.

```sh
OWRT_BUILDS=$OUT test/qemu/run.sh -j 8
```

S20 installs a real stack when `QEMU_STACK` names a `tools/make-stack.sh`
output directory, and is skipped otherwise:

```sh
OWRT_BUILDS=$OUT QEMU_STACK=~/build/opencreator-os/stack-out test/qemu/run.sh S20
```

## Changing the kernel config

Edit `kernel/creator5pro.config`, then regenerate the full config on a clean
copy of the kernel tree:

```sh
CROSS_COMPILE=~/ing/mips-xburst2-linux-toolchain-r6.0.0/bin/mips-xburst2-linux-gnu- \
  kernel/mkconfig.sh <clean kernel-6.6 copy> /tmp/kcfg
cp /tmp/kcfg/.config feed/x2600/config-6.6
```

Check the result in the built `kernel.config`.
