# Building opencreator-os

You need an x86-64 Linux machine (tested on Ubuntu 24.04) with about 50 GB
free. The first OpenWrt build takes hours; later builds take minutes.

## 1. Install the build packages

```sh
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync \
  swig unzip zlib1g-dev file wget curl device-tree-compiler u-boot-tools \
  python3-pil squashfs-tools shellcheck
```

## 2. Get the Ingenic downloads

Both come from Ingenic's FTP server, `ftp://ftp.ingenic.com.cn`. Log in as
`ingenic_public`; Ingenic gives out the password, and it is not stored in
this repository.

**Toolchain** (MIPS GCC 12.1, glibc 2.33; the one stock was built with).
Ingenic's toolchains are in `/Ingenic-MIPS-Toolchain/releases/` ([release
notes](https://www.ingenic.com.cn/news-detail/nid-348.html)). Use r6.0.0:

```
/Ingenic-MIPS-Toolchain/releases/ingenic-mips-toolchain-r6.0.0/mips-xburst2-linux-toolchain-r6.0.0.tar.bz2
sha256 4e3359e32c2fb7d9e573ce84370220a66e3998bb911452d82267394fad4086e0
```

Unpack it so the scripts find it:

```sh
mkdir -p ~/ing && tar -xjf mips-xburst2-linux-toolchain-r6.0.0.tar.bz2 -C ~/ing
ls ~/ing/mips-xburst2-linux-toolchain-r6.0.0/bin/mips-xburst2-linux-gnu-gcc
```

**X2600 6.6 SDK** (the kernel source), 680 MB, in
`/DevSupport/X2600E/01_SW/06_kernel6.6_x2600-sdk_v1.0-20250221/` (details in
`kernel/SOURCE.md`). You don't need to fetch it yourself: step 5 downloads it
if you export the password first.

```sh
export INGENIC_FTP_PASS=...                 # or put the tarball in a directory
export INGENIC_SDK_DIR=~/ingenic-sdk        # and point INGENIC_SDK_DIR at it
```

## 3. Clone the repositories side by side

```sh
git clone https://github.com/FlashForge-C5-Modding-Group/opencreator-os.git
git clone --recurse-submodules https://github.com/FlashForge-C5-Modding-Group/os-installer.git
cd opencreator-os
```

The commands below run from `opencreator-os/`.

## 4. Build the stick helpers (once)

```sh
installer/tools/build.sh      # static sfdisk + partx -> installer/tools/out/
chainload/build.sh            # chainload.ko for stock's kernel -> chainload/out/
```

`chainload/build.sh` also needs Ingenic's 5.10 kernel tree, prepared the way
`chainload/README.md` describes (the X2600 SDK `v2.0-20230906`, the
`03_...` directory next to the 6.6 SDK on the FTP server).

## 5. Build the OpenWrt image

```sh
export OUT=~/opencreator-os-builds
./build.sh
```

The images go to `$OUT/<version>/`, where `<version>` is
`git describe --always --dirty --tags`. Build trees go to `~/build/opencreator-os`
(set `WORK` to change it). Options: `--menuconfig`, `--kernel-menuconfig`,
`--clean-kernel`.

## 6. Build the touchscreen app

```sh
(cd ../os-installer && make mips32)
```

## 7. Assemble the stick

```sh
tools/make-install-stick.sh --app ../os-installer/build/mips32/os-installer \
    "$OUT/$(git describe --always --dirty --tags)" stick/
```

`stick/` must be new or empty. Add `--authorized-keys FILE` to ship your SSH
key. Without `--app` the stick runs headless.

## 8. Copy it to a USB stick

Format a USB stick as FAT32: 16 GB if you want the installer to back up the
eMMC (about 7.5 GB), otherwise any size. Copy the **contents** of `stick/` to
its root, not the folder itself. Then, from the stick's root:

```sh
sha256sum -c --quiet SHA256SUMS && echo OK
```

Installing is in `install.md`.

## Optional

- QEMU system tests, about 45 min (`test/qemu/README.md`):
  `OWRT_BUILDS=$OUT test/qemu/run.sh -j 8`
- PC demo of the installer screens: build the app with `make sdl` and run
  `tools/ui-demo.sh ../os-installer/build/sdl/os-installer "$OUT/<version>"`
  (needs sudo and about 15 GB).

## Changing the kernel config

Edit `kernel/creator5pro.config`, then regenerate the full config on a clean
copy of the kernel tree (OpenWrt builds the tree in place):

```sh
CROSS_COMPILE=<toolchain prefix> kernel/mkconfig.sh <clean kernel-6.6 copy> /tmp/kcfg
cp /tmp/kcfg/.config feed/x2600/config-6.6
```

`mkconfig.sh` fails if a fragment line didn't survive. Selected kmod packages
and `CONFIG_KERNEL_*` lines in `config/openwrt.seed` add kernel options too,
so check the result in the built `kernel.config`.
