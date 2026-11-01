# Building opencreator-os

Any x86-64 Linux (tested on Ubuntu 24.04). The OpenWrt build tree needs about
40 GB in `WORK` (default `~/build/opencreator-os`); the first build takes
hours, later ones minutes.

## Prerequisites

```sh
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync \
  swig unzip zlib1g-dev file wget device-tree-compiler u-boot-tools \
  python3-pil squashfs-tools shellcheck
```

- Ingenic xburst2 toolchain r6.0.0 in `~/ing/mips-xburst2-linux-toolchain-r6.0.0`
  (or set `TC` and, for the app, `INGENIC_TOOLCHAIN`).
- Ingenic X2600 6.6 SDK tarball (see `kernel/SOURCE.md`): set
  `INGENIC_SDK_DIR` to the directory holding it, or export `INGENIC_FTP_PASS`
  and `kernel/prepare.sh` downloads it.
- For `chainload.ko` only: the Ingenic 5.10 kernel tree and its prepared build
  directory (`KSRC`, `KOUT`; see `chainload/README.md`).
- The `os-installer` repository next to this one.

## Build and make a stick

```sh
export OUT=~/opencreator-os-builds          # where images go
./build.sh                                  # -> $OUT/<version>/ (version = git describe)
chainload/build.sh                          # once: chainload.ko
installer/tools/build.sh                    # once: static sfdisk + partx
(cd ../os-installer && make mips32)         # touchscreen app
tools/make-install-stick.sh --app ../os-installer/build/mips32/os-installer \
    "$OUT/$(git describe --always --dirty --tags)" stick/
```

Copy the **contents** of `stick/` to the root of a FAT32 USB stick (16 GB if
you want the installer's eMMC backup, about 7.5 GB), then check the copy from its
root: `sha256sum -c --quiet SHA256SUMS`. Without `--app` the stick runs
headless; `--authorized-keys FILE` adds SSH keys. Installing: `install.md`.

Optional: `OWRT_BUILDS=$OUT test/qemu/run.sh -j 8` runs the QEMU system tests
(about 45 min; see `test/qemu/README.md`). `tools/ui-demo.sh APP VERSION_DIR`
runs the PC (`make sdl`) build of the app against the real installer and a
loop-mounted image laid out like the printer's eMMC (needs sudo and about
15 GB).

`build.sh` options: `--menuconfig`, `--kernel-menuconfig`, `--clean-kernel`.

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
