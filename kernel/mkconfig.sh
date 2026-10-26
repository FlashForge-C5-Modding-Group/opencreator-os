#!/bin/bash
# Generate the full kernel .config from the SDK defconfig + creator5pro.config
# and check that every fragment line survived olddefconfig.
#
#   kernel/mkconfig.sh KSRC OUTDIR [--build]
#
# Env: CROSS_COMPILE (default: mipsel-openwrt-linux-musl- from PATH)
# --build  also builds zImage in OUTDIR (standalone test build)
# Copy OUTDIR/.config to feed/x2600/config-6.6 to update the OpenWrt target.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KSRC=$(realpath "${1:?kernel source}")
OUT=$(realpath -m "${2:?output dir}")
DEFCONFIG=x2600_halley7_linux_defconfig
FRAG=$HERE/creator5pro.config
CROSS_COMPILE=${CROSS_COMPILE:-mipsel-openwrt-linux-musl-}
MAKE=(make -C "$KSRC" O="$OUT" ARCH=mips CROSS_COMPILE="$CROSS_COMPILE")

install -m0644 "$HERE/dts/creator5pro.dts" "$KSRC/module_drivers/dts/x2600/creator5pro.dts"
mkdir -p "$OUT"
"${MAKE[@]}" "$DEFCONFIG" >/dev/null
"$KSRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$FRAG" >/dev/null
"${MAKE[@]}" olddefconfig >/dev/null

bad=0
while IFS= read -r line; do
	case $line in
	CONFIG_*=*) sym=${line%%=*} want=${line#*=} ;;
	"# CONFIG_"*" is not set") sym=${line#\# }; sym=${sym%% *}; want=n ;;
	*) continue ;;
	esac
	have=$(grep -E "^$sym=" "$OUT/.config" | head -1 | cut -d= -f2- || true)
	[ -n "$have" ] || have=n
	if [ "$have" != "$want" ]; then
		echo "mkconfig: $sym wanted $want, got $have" >&2
		bad=1
	fi
done < "$FRAG"
[ "$bad" = 0 ] || exit 1
echo "mkconfig: all fragment options applied -> $OUT/.config"

if [ "${3:-}" = --build ]; then
	"${MAKE[@]}" -j"$(nproc)" zImage
	ls -l "$OUT/arch/mips/boot/compressed/zImage"
fi
