#!/usr/bin/env bash
# Build the mainline Linux kernel used by the QEMU system tests (malta,
# MIPS32r2 little-endian, everything built in) into $QWORK/vmlinux-$KVER.
#
#   test/qemu/kernel/build.sh [--force]
#
# Downloads linux-$KVER.tar.xz from kernel.org into $QWORK/dl (sha256
# pinned in lib/env.sh), merges kernel/malta.config onto malta_defconfig and
# checks that every line of the fragment survived olddefconfig.
set -euo pipefail
# shellcheck source=../lib/env.sh
. "$(dirname "$0")/../lib/env.sh"

FORCE=0
[ "${1:-}" = --force ] && FORCE=1
if [ "$FORCE" = 0 ] && [ -s "$VMLINUX" ]; then
	echo "kernel: $VMLINUX exists"
	exit 0
fi

CC_PREFIX=$(pick_cross_compile) || { echo "kernel: no MIPS cross compiler found (set CROSS_COMPILE)" >&2; exit 1; }
SRC=$QWORK/linux-$KVER
OBJ=$QWORK/kbuild-$KVER
TARBALL=$QWORK/dl/linux-$KVER.tar.xz
mkdir -p "$QWORK/dl"

if [ ! -s "$TARBALL" ]; then
	curl -fSL -o "$TARBALL.part" "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
	mv "$TARBALL.part" "$TARBALL"
fi
echo "$KSHA256  $TARBALL" | sha256sum -c --quiet || { echo "kernel: $TARBALL checksum mismatch" >&2; exit 1; }
[ -f "$SRC/Makefile" ] || tar -xf "$TARBALL" -C "$QWORK"

# Board identity: OpenWrt's board_name is the first root "compatible" of the
# DT. Make it the product's (flashforge,creator5pro, as in
# kernel/dts/creator5pro.dts) so board.d, fwtool's supported_devices check
# and everything else keyed on the board behave as on the printer; malta's
# DT shim is taught to recognise malta by any compatible entry.
DTS=$SRC/arch/mips/boot/dts/mti/malta.dts
SHIM=$SRC/arch/mips/mti-malta/malta-dtshim.c
sed -i 's/^\tcompatible = "mti,malta";/\tcompatible = "flashforge,creator5pro", "mti,malta";/' "$DTS"
sed -i 's/if (strncmp(compat, "mti,malta", len))/if (fdt_node_check_compatible(fdt_buf, root_off, "mti,malta"))/' "$SHIM"
grep -q '"flashforge,creator5pro", "mti,malta"' "$DTS" && grep -q 'fdt_node_check_compatible(fdt_buf, root_off, "mti,malta")' "$SHIM" ||
	{ echo "kernel: malta DT / shim patch did not apply" >&2; exit 1; }

FRAG=$QDIR/kernel/malta.config
KMAKE=(make -C "$SRC" O="$OBJ" ARCH=mips CROSS_COMPILE="$CC_PREFIX" -j"$(nproc)")
mkdir -p "$OBJ"
"${KMAKE[@]}" malta_defconfig >/dev/null
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$OBJ" "$OBJ/.config" "$FRAG" >/dev/null
"${KMAKE[@]}" olddefconfig >/dev/null

missing=0
while IFS= read -r line; do
	case "$line" in
	CONFIG_*=*) grep -qxF "$line" "$OBJ/.config" || { echo "kernel: fragment line lost: $line" >&2; missing=1; } ;;
	"# CONFIG_"*" is not set") grep -qxF "$line" "$OBJ/.config" || { echo "kernel: fragment line lost: $line" >&2; missing=1; } ;;
	esac
done < "$FRAG"
[ "$missing" = 0 ] || exit 1

echo "kernel: building Linux $KVER with ${CC_PREFIX}gcc"
"${KMAKE[@]}" vmlinux
rm -f "$QWORK/vmlinux-$KVER"-*	# kernels of older fragment/script versions
cp "$OBJ/vmlinux" "$VMLINUX.tmp"
mv "$VMLINUX.tmp" "$VMLINUX"
echo "kernel: $VMLINUX"
