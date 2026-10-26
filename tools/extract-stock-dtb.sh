#!/bin/bash
# Extract the built-in device tree from a stock xImage (local use only; the
# output is a stock artifact and must never be committed).
#
#   tools/extract-stock-dtb.sh [XIMAGE] [OUTDIR]
#
# A DTB captured on the printer (phase0 facts/running.dtb) can be decompiled
# directly with: dtc -I dtb -O dts running.dtb
set -euo pipefail

XIMAGE=${1:-$(ls /mnt/f/creator5-dev/creator-5-pro-firmware-archive/kernel/ota_kernel_emmc/ota_v1/xImage.0000.* | head -1)}
OUT=${2:-/mnt/f/creator5-dev/opencreator-os-work/stock-dtb}
command -v dtc >/dev/null || { echo "need dtc: sudo apt install device-tree-compiler" >&2; exit 1; }
mkdir -p "$OUT"

python3 - "$XIMAGE" "$OUT/stock.dtb" <<'EOF'
import struct, sys, zlib
img = open(sys.argv[1], 'rb').read()[64:]          # drop the uImage header
off = img.find(b'\x1f\x8b\x08')
if off < 0:
    sys.exit('no gzip member')
d = zlib.decompressobj(16 + zlib.MAX_WBITS)
kernel = d.decompress(img[off:])
pos = 0
while True:
    pos = kernel.find(b'\xd0\x0d\xfe\xed', pos)
    if pos < 0:
        sys.exit('no FDT found')
    size, = struct.unpack('>I', kernel[pos + 4:pos + 8])
    ver, = struct.unpack('>I', kernel[pos + 20:pos + 24])
    if 0x100 < size < 0x100000 and 16 <= ver <= 17:
        open(sys.argv[2], 'wb').write(kernel[pos:pos + size])
        print(f'FDT at vmlinux+0x{pos:x}, {size} bytes')
        break
    pos += 4
EOF
dtc -q -I dtb -O dts -o "$OUT/stock.dts" "$OUT/stock.dtb"
sha256sum "$XIMAGE" "$OUT/stock.dtb"
echo "-> $OUT/stock.dts"
