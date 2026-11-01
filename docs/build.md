# Building opencreator-os

Requires x86-64 Linux and about 50 GB of disk.

## 1. Install packages

```sh
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync \
  swig unzip zlib1g-dev file wget curl device-tree-compiler u-boot-tools \
  python3-pil squashfs-tools shellcheck
```

## 2. Install the Ingenic toolchain

```sh
curl -fO -u ingenic_public:BFdg2f9B12 \
  ftp://ftp.ingenic.com.cn/Ingenic-MIPS-Toolchain/releases/ingenic-mips-toolchain-r6.0.0/mips-xburst2-linux-toolchain-r6.0.0.tar.bz2
echo "4e3359e32c2fb7d9e573ce84370220a66e3998bb911452d82267394fad4086e0  mips-xburst2-linux-toolchain-r6.0.0.tar.bz2" | sha256sum -c
mkdir -p ~/ing && tar -xjf mips-xburst2-linux-toolchain-r6.0.0.tar.bz2 -C ~/ing
```

## 3. Clone the repositories

```sh
git clone https://github.com/FlashForge-C5-Modding-Group/opencreator-os.git
git clone --recurse-submodules https://github.com/FlashForge-C5-Modding-Group/os-installer.git
cd opencreator-os
```

Run the remaining steps from `opencreator-os/`.

## 4. Build the stick helpers

```sh
installer/tools/build.sh
chainload/build.sh
```

`chainload/build.sh` needs Ingenic's 5.10 kernel tree; see `chainload/README.md`.
Its SDK is on the same FTP server:
`/DevSupport/X2600E/01_SW/03_kernel4.4.94_kernel5.10_x2600-sdk_v2.0-20230906/00_ingenic-linux-kernel4.4.94-kernel5.10-x2600-v2.0-20230906/`.

## 5. Build the image

If the 6.6 SDK is already downloaded, set its full Linux/WSL path:

```sh
export INGENIC_SDK_TARBALL="/mnt/d/ingenic/X2600/06_kernel6.6_x2600-sdk_v1.0-20250221/ingenic-linux-kernel6.6-x2600-v1.0-20250221.tar.bz2"
```

This overrides `INGENIC_SDK_DIR`; a missing file fails without downloading.
Otherwise, the SDK is read from `INGENIC_SDK_DIR` (default in
`kernel/prepare.sh`) or downloaded there from Ingenic's FTP. Before extraction,
the archive must match the pinned MD5 in `kernel/SOURCE.md`. An existing
extracted kernel tree is reused without rechecking or unpacking the archive.

```sh
export OUT=~/opencreator-os-builds
./build.sh
```

The first build takes hours. Output: `$OUT/<version>/`, where `<version>` is
`git describe --always --dirty --tags`.

## 6. Build the touchscreen app

```sh
(cd ../os-installer && make mips32)
```

## 7. Assemble the stick

```sh
tools/make-install-stick.sh --app ../os-installer/build/mips32/os-installer \
    "$OUT/$(git describe --always --dirty --tags)" stick/
```

## 8. Copy to a USB stick

Copy the contents of `stick/` to the root of a FAT32 stick (16 GB to fit the
installer's eMMC backup), then check it from the stick's root:

```sh
sha256sum -c --quiet SHA256SUMS && echo OK
```

To install, see `install.md`.

## Tests

```sh
OWRT_BUILDS=$OUT test/qemu/run.sh -j 8
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
