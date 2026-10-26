#!/bin/bash
# Build chainload.ko for the stock Creator 5 Pro kernel (5.10.186+) and
# check its module ABI against stock. Runs in WSL.
#
#   chainload/build.sh
#
# Environment (defaults in brackets):
#   KSRC   Ingenic SDK kernel-5.10 tree (5.10.186)          [~/ing/kernel-5.10]
#   KOUT   prepared build dir of KSRC (.config, Module.symvers, scripts/mod)
#                                                           [~/ing/out]
#   TC     mips-xburst2-linux-toolchain-r6.0.0              [~/ing/mips-xburst2-linux-toolchain-r6.0.0]
#   STOCK_MODULES  space-separated dirs with stock .ko files to compare the
#                  struct module layout with   [stock 2.0.8 module_driver in
#                  ../creator-5-pro-firmware-archive, when present]
#   STOCK_XIMAGES  space-separated stock xImage (uImage) files whose export
#                  tables must contain every import   [stock 2.0.8 xImage in
#                  the archive, when present]
#
# KOUT is produced by opencreator/c5-usb-serial-modules/build.sh (defconfig
# x2600_module_base_linux_mmc0_defconfig + HIGHMEM + LOCALVERSION="+",
# then `make vmlinux modules`). This script never modifies it.
#
# Output: chainload/out/chainload.ko, chainload/out/abi-report.txt
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
KSRC=${KSRC:-$HOME/ing/kernel-5.10}
KOUT=${KOUT:-$HOME/ing/out}
TC=${TC:-$HOME/ing/mips-xburst2-linux-toolchain-r6.0.0}
ARCHIVE=$(cd "$HERE/../../.." && pwd)/creator-5-pro-firmware-archive/kernel/ota_kernel_emmc/ota_v1
VERMAGIC="5.10.186+ SMP preempt mod_unload MIPS32_R5 32BIT "
# struct module as compiled into every stock 2.0.7/2.0.8 module:
# .gnu.linkonce.this_module size, offsets of the init and exit pointers
ABI_THIS_MODULE="0x180 0xe0 0x16c"

die() { echo "build: $*" >&2; exit 1; }

if [ -z "${STOCK_MODULES+x}" ]; then
	STOCK_MODULES=""
	[ -d "$ARCHIVE/rootfs_extracted/module_driver" ] && STOCK_MODULES=$ARCHIVE/rootfs_extracted/module_driver
fi
if [ -z "${STOCK_XIMAGES+x}" ]; then
	STOCK_XIMAGES=$(ls "$ARCHIVE"/xImage.0000.* 2>/dev/null || true)
fi

grep -q '^SUBLEVEL = 186$' "$KSRC/Makefile" || die "$KSRC is not Linux 5.10.186"
[ -x "$TC/bin/mips-xburst2-linux-gnu-gcc" ] || die "no mips-xburst2-linux-gnu-gcc in $TC/bin"
for f in .config Module.symvers include/config/kernel.release scripts/mod/modpost; do
	[ -e "$KOUT/$f" ] || die "$KOUT/$f missing: prepare KOUT with opencreator/c5-usb-serial-modules/build.sh"
done
[ "$(cat "$KOUT/include/config/kernel.release")" = "5.10.186+" ] ||
	die "$KOUT is not configured for 5.10.186+"
command -v python3 >/dev/null || die "python3 missing"

CROSS_COMPILE=$TC/bin/mips-xburst2-linux-gnu-
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$HERE/Makefile" "$HERE/chainload_main.c" "$HERE/tramp.S" "$WORK/"
make -C "$KSRC" O="$KOUT" ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" M="$WORK" modules
KO=$WORK/chainload.ko

"${CROSS_COMPILE}objcopy" -O binary -j .modinfo "$KO" "$WORK/modinfo.bin"
got=$(tr '\0' '\n' < "$WORK/modinfo.bin" | sed -n 's/^vermagic=//p')
[ "$got" = "$VERMAGIC" ] || die "vermagic '$got', want '$VERMAGIC'"

# ABI: struct module layout (vs the expected values and every stock module
# found), no __versions, and every import exported by each stock kernel
# (a __ksymtab entry {value, name, namespace} whose name points at it).
READELF=${CROSS_COMPILE}readelf python3 - "$KO" "$ABI_THIS_MODULE" "$STOCK_MODULES" "$STOCK_XIMAGES" \
	> "$WORK/abi-report.txt" <<'EOF' || { cat "$WORK/abi-report.txt"; die "ABI check failed"; }
import glob, os, struct, subprocess, sys, zlib

RE = os.environ['READELF']
ko, want, mod_dirs, ximages = sys.argv[1], tuple(sys.argv[2].split()), sys.argv[3].split(), sys.argv[4].split()
fail = False

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout

def layout(path):
    size = None
    secs = sh(RE, '-SW', path)
    for l in secs.splitlines():
        if ']' in l:
            f = l.split(']', 1)[1].split()
            if f and f[0] == '.gnu.linkonce.this_module':
                size = hex(int(f[4], 16))
    offs, cur = {}, None
    for l in sh(RE, '-rW', path).splitlines():
        if l.startswith('Relocation section'):
            cur = l.split("'")[1]
        elif cur and cur.endswith('.gnu.linkonce.this_module'):
            f = l.split()
            if len(f) >= 5 and len(f[0]) == 8:
                try:
                    offs[f[4]] = hex(int(f[0], 16))
                except ValueError:
                    pass
    return (size, offs.get('init_module'), offs.get('cleanup_module')), '__versions' in secs

ours, vers = layout(ko)
print('chainload.ko: this_module size/init/exit %s %s %s, %s' % (ours + ('__versions' if vers else 'no __versions',)))
if ours != want or vers:
    print('  MISMATCH: want %s %s %s, no __versions' % want)
    fail = True
for d in mod_dirs:
    kos = sorted(glob.glob(os.path.join(d, '**', '*.ko'), recursive=True))
    bad = [os.path.basename(k) for k in kos if layout(k) != (want, False)]
    print('%s: %d stock modules, %d differ%s' % (d, len(kos), len(bad), (': ' + ' '.join(bad)) if bad else ''))
    fail |= bool(bad) or not kos

imports = sorted({f[7] for f in (l.split() for l in sh(RE, '-sW', ko).splitlines())
                  if len(f) >= 8 and f[6] == 'UND'})
print('imports (%d): %s' % (len(imports), ' '.join(imports)))

def exported(img, name, base):
    # __ksymtab_strings is tail-merged: "printk" may sit inside "vprintk"
    key, start = name.encode() + b'\0', 0
    while True:
        o = img.find(key, start)
        if o < 0:
            return False
        start = o + 1
        p = struct.pack('<I', base + o)
        q = img.find(p)
        while q >= 0:
            if q % 4 == 0 and q >= 4 and 0x80000000 <= struct.unpack_from('<I', img, q - 4)[0] < 0x90000000:
                return True
            q = img.find(p, q + 1)

for x in ximages:
    raw = open(x, 'rb').read()
    if raw[:4] != b'\x27\x05\x19\x56':
        print('%s: not a uImage' % x); fail = True; continue
    raw = raw[64:]
    img = zlib.decompressobj(31).decompress(raw[raw.find(b'\x1f\x8b\x08'):])
    base = next((b for b in range(0x80000000, 0x80100000, 0x1000)
                 if exported(img, 'kmalloc_caches', b) and exported(img, 'filp_open', b)), None)
    if base is None:
        print('%s: export table not found' % x); fail = True; continue
    missing = [n for n in imports if not exported(img, n, base)]
    print('%s: vmlinux at %#x, %d/%d imports exported%s' % (os.path.basename(x), base,
          len(imports) - len(missing), len(imports), ('; MISSING: ' + ' '.join(missing)) if missing else ''))
    fail |= bool(missing)
sys.exit(1 if fail else 0)
EOF

mkdir -p "$OUT"
cp "$KO" "$OUT/chainload.ko"
{ echo "vermagic: $got"; cat "$WORK/abi-report.txt"; } > "$OUT/abi-report.txt"
cat "$OUT/abi-report.txt"
(cd "$OUT" && sha256sum chainload.ko)
