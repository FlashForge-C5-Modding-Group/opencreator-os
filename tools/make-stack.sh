#!/bin/bash
# Build the printer stack archives for an install stick (docs/stack.md).
#
#   tools/make-stack.sh [--kalico DIR] [--moonraker DIR] [--opencreator-fs DIR] OUTDIR
#
# OUTDIR  new or empty directory; gets stack.tar.gz, fluidd.tar.gz and
#         mainsail.tar.gz for tools/make-install-stick.sh --stack OUTDIR
# --kalico DIR          Kalico checkout (default ../kalico)
# --moonraker DIR       Moonraker checkout with the procd provider
#                       (default ../moonraker-procd)
# --opencreator-fs DIR  opencreator-fs checkout (default ../opencreator-fs)
#
# Packs each checkout's HEAD (uncommitted changes are left out), the
# OpenWrt packages the stack needs from the local build (./build.sh; the
# CONFIG_PACKAGE_*=m lines of config/openwrt.seed and their dependencies
# beyond the image), and the downloads pinned in stack/sources.txt.
# Env: WORK (default ~/build/opencreator-os) as for build.sh; downloads are
#      cached in $WORK/stack-dl.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HOME/build/opencreator-os}
OW=$WORK/openwrt
DL=$WORK/stack-dl

log() { printf '\n=== %s\n' "$*"; }
die() { echo "make-stack: $*" >&2; exit 1; }
usage() { sed -n '2,19s/^# \{0,1\}//p' "$0"; }

KALICO=$REPO/../kalico
MOONRAKER=$REPO/../moonraker-procd
OFS=$REPO/../opencreator-fs
while [ $# -gt 0 ]; do
	case "$1" in
	--kalico | --moonraker | --opencreator-fs)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		case "$1" in
		--kalico) KALICO=$2 ;;
		--moonraker) MOONRAKER=$2 ;;
		*) OFS=$2 ;;
		esac
		shift
		;;
	-h | --help) usage; exit 0 ;;
	-*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
	*) break ;;
	esac
	shift
done
[ $# -eq 1 ] || { usage >&2; exit 2; }
OUT=$1
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
	die "$OUT exists and is not empty"
fi
[ -f "$OW/.config" ] || die "$OW/.config missing: run ./build.sh first"

# srcgit DIR ARGS...: git in a checkout; a worktree made by Windows git names
# its git directory as F:/..., which WSL's git cannot follow
srcgit() {
	local dir=$1 gd
	shift
	if git -C "$dir" rev-parse --git-dir > /dev/null 2>&1; then
		git -C "$dir" "$@"
	elif [ -f "$dir/.git" ] && gd=$(sed -n 's/^gitdir: \([A-Za-z]\):\(.*\)$/\1 \2/p' "$dir/.git") && [ -n "$gd" ]; then
		gd="/mnt/$(printf '%s' "${gd%% *}" | tr '[:upper:]' '[:lower:]')${gd#* }"
		(cd "$dir" && GIT_DIR=$gd GIT_WORK_TREE=. git "$@")
	else
		die "$dir is not a git checkout"
	fi
}

log "host and toolchain"
for t in python3 curl git tar gzip sha256sum readelf; do
	command -v "$t" > /dev/null || die "host tool $t missing"
done
shopt -s nullglob
ccs=("$OW"/staging_dir/toolchain-mipsel_mips32_gcc-*_musl/bin/mipsel-openwrt-linux-musl-gcc)
[ ${#ccs[@]} = 1 ] || die "expected one OpenWrt mipsel gcc under $OW/staging_dir, found ${#ccs[@]}"
CC=${ccs[0]}
export STAGING_DIR=$OW/staging_dir/target-mipsel_mips32_musl
OPT=$(sed -n 's/^CONFIG_TARGET_OPTIMIZATION="\(.*\)"$/\1/p' "$OW/.config")
[ -n "$OPT" ] || die "no CONFIG_TARGET_OPTIMIZATION in $OW/.config"
mfs=("$OW"/bin/targets/x2600/generic/*.manifest)
[ ${#mfs[@]} = 1 ] || die "expected one image manifest in $OW/bin/targets/x2600/generic, found ${#mfs[@]}"
MANIFEST=${mfs[0]}
shopt -u nullglob
for d in "$KALICO" "$MOONRAKER" "$OFS"; do
	[ -z "$(srcgit "$d" status --porcelain)" ] ||
		echo "make-stack: warning: $d has uncommitted changes; only HEAD is packed" >&2
done
echo "compiler $CC ($OPT)"

log "downloads (stack/sources.txt)"
mkdir -p "$DL"
declare -A SRC
while read -r name sha url; do
	[ -n "$name" ] || continue
	f=$DL/$sha-$name
	if [ ! -s "$f" ]; then
		curl -fsSL --retry 3 -o "$f.part" "$url" || die "cannot download $url"
		[ "$(sha256sum < "$f.part" | cut -d' ' -f1)" = "$sha" ] || { rm -f "$f.part"; die "$name: sha256 mismatch"; }
		mv "$f.part" "$f"
	fi
	SRC[$name]=$f
	echo "$name"
done < "$REPO/stack/sources.txt"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
B=$T/stack
mkdir -p "$B/root"
chmod 0755 "$B"

log "OpenWrt packages"
roots=$(sed -n 's/^CONFIG_PACKAGE_\(.*\)=m$/\1/p' "$REPO/config/openwrt.seed")
for r in $roots; do
	[ -n "$(find "$OW/bin" -name "${r}_*.ipk" -print -quit)" ] || die "$r is not built: run ./build.sh"
done
# shellcheck disable=SC2086  # one package name per word
ipks=$(python3 "$REPO/tools/ipk_closure.py" "$MANIFEST" "$OW/bin" $roots) || die "ipk_closure.py failed"
for ipk in $ipks; do
	tar -xzOf "$ipk" ./data.tar.gz | tar -xzf - -C "$B/root" || die "cannot unpack $ipk"
done
echo "$(printf '%s\n' "$ipks" | wc -l) ipks"
# opkg's Alternatives (coreutils-stty: 300:/bin/stty:/usr/libexec/stty-coreutils),
# made relative inside root/; /bin and /sbin links go to usr/, which env.sh
# puts on PATH. The highest priority wins.
declare -A ALT_PRIO
for ipk in $ipks; do
	alts=$(tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - ./control | sed -n 's/^Alternatives: *//p')
	for a in ${alts//,/ }; do
		IFS=: read -r prio link target <<< "$a"
		case "$link" in /bin/* | /sbin/*) link=/usr$link ;; esac
		[ "${ALT_PRIO[$link]:-0}" -lt "$prio" ] || continue
		ALT_PRIO[$link]=$prio
		mkdir -p "$B/root${link%/*}"
		ln -sfn "$(realpath -m --relative-to="$B/root${link%/*}" "$B/root$target")" "$B/root$link"
		echo "alternative $link -> $target"
	done
done

pys=("$B"/root/usr/lib/python3.*)
if [ ${#pys[@]} != 1 ] || [ ! -d "${pys[0]}" ]; then die "expected one usr/lib/python3.* in the packages"; fi
PYVER=${pys[0]##*/}
SITE=$B/root/usr/lib/$PYVER/site-packages
mkdir -p "$SITE"

sods=()
for f in "$B"/root/usr/lib/libsodium.so.[0-9]*; do [ -f "$f" ] && [ ! -L "$f" ] && sods+=("$f"); done
[ ${#sods[@]} = 1 ] || die "expected one libsodium.so.N file, found ${#sods[@]}"
# libnacl loads the unversioned name
ln -sf "${sods[0]##*/}" "$B/root/usr/lib/libsodium.so"

log "Python packages ($PYVER)"
for n in "${!SRC[@]}"; do
	case "$n" in *.whl) python3 -m zipfile -e "${SRC[$n]}" "$SITE" && echo "$n" ;; esac
done
mkdir -p "$T/sfd" "$SITE/streaming_form_data"
tar -xzf "${SRC[streaming-form-data-1.11.0.tar.gz]}" -C "$T/sfd"
SFD=$T/sfd/streaming-form-data-1.11.0/streaming_form_data
cp "$SFD"/*.py "$SITE/streaming_form_data/"
[ -d "$STAGING_DIR/usr/include/$PYVER" ] || die "no $PYVER headers in $STAGING_DIR/usr/include"
# shellcheck disable=SC2086  # OPT is a list of flags
"$CC" $OPT -O2 -fPIC -shared -I"$STAGING_DIR/usr/include/$PYVER" \
	-o "$SITE/streaming_form_data/_parser.so" "$SFD/_parser.c" || die "cannot build streaming_form_data/_parser.so"
echo "streaming_form_data (_parser.so built)"

log "Kalico"
srcgit "$KALICO" archive --prefix=klipper/ HEAD klippy scripts COPYING | tar -x -C "$B"
srcgit "$KALICO" describe --always --tags --long > "$B/klipper/klippy/.version"
CH=$B/klipper/klippy/chelper
args=$(python3 - "$CH/__init__.py" <<'EOF'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
v = {}
for node in tree.body:
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id in ("COMPILE_ARGS", "SOURCE_FILES"):
                v[t.id] = ast.literal_eval(node.value)
print(v["COMPILE_ARGS"] % ("c_helper.so", " ".join(v["SOURCE_FILES"])))
EOF
) || die "cannot read COMPILE_ARGS/SOURCE_FILES from klippy/chelper/__init__.py"
# shellcheck disable=SC2086  # flag lists
if ! (cd "$CH" && "$CC" $OPT $args); then
	echo "make-stack: retrying c_helper.so without LTO" >&2
	# shellcheck disable=SC2086
	(cd "$CH" && "$CC" $OPT ${args/ -flto -fwhole-program -fno-use-linker-plugin/}) || die "cannot build c_helper.so"
fi
# klippy rebuilds unless the library is newer than every source and header
touch "$CH/c_helper.so"
echo "kalico $(cat "$B/klipper/klippy/.version") (c_helper.so built)"

log "Moonraker"
srcgit "$MOONRAKER" archive --prefix=moonraker/ HEAD moonraker LICENSE | tar -x -C "$B"
srcgit "$MOONRAKER" describe --always --tags --long > "$B/moonraker/moonraker/.version"
echo "moonraker $(cat "$B/moonraker/moonraker/.version")"

log "opencreator-fs"
mkdir -p "$T/ofs" "$B/defaults" "$B/opencreator"
srcgit "$OFS" archive HEAD fs/usr/data/config fs/usr/data/grumpyscreen/grumpyscreen.cfg \
	fs/usr/data/opencreator/startup/scripts/08-mcu-wake.sh fs/usr/data/opencreator/moonraker/shaper_graph.py |
	tar -x -C "$T/ofs"
O=$T/ofs/fs/usr/data
cp -r "$O/config" "$B/defaults/config"
rm -f "$B/defaults/config/moonraker.conf"
find "$B/defaults/config" -type f -exec sed -i \
	-e 's|/usr/data/opencreator/klipper/klippy-env/bin/python|/data/printer/bin/python3|g' \
	-e 's|/usr/data/opencreator/moonraker/shaper_graph.py|/data/printer/opencreator/shaper_graph.py|g' \
	-e 's|/usr/data/opencreator/klipper/config/|/data/printer_data/config/|g' \
	-e 's|/usr/data/firmwareRes/config/|/data/printer_data/config/calibration/|g' \
	-e 's|/usr/data/gcodes|/data/printer_data/gcodes|g' \
	-e 's|/usr/data/power_loss_recovery.json|/data/printer_data/power_loss_recovery.json|g' {} +
cp "$REPO/stack/config/moonraker.conf" "$B/defaults/config/moonraker.conf"
sed -e '/^factory_reset_cmd:/d' -e '/^switch_to_stock_cmd:/d' -e '/^support_zip_cmd:/d' -e '/^restart_wifi_cmd:/d' \
	-e 's|^gui_restart_cmd:.*|gui_restart_cmd: /etc/init.d/grumpyscreen restart|' \
	-e 's|^restart_klipper_cmd:.*|restart_klipper_cmd: /etc/init.d/klipper restart|' \
	-e 's|^shutdown_host_cmd:.*|shutdown_host_cmd: /sbin/poweroff|' \
	-e 's|^thumbnail_path:.*|thumbnail_path: /data/printer_data/grumpyscreen/thumbnails/|' \
	"$O/grumpyscreen/grumpyscreen.cfg" > "$B/defaults/config/grumpyscreen.cfg"
# OpenWrt's busybox read takes whole seconds only ("invalid timeout" for 0.2)
sed -e 's|^LOG=.*|LOG=/data/printer_data/logs/mcu-wake.log|' \
	-e 's|^PRINTER_LOG=.*|PRINTER_LOG=/data/printer_data/logs/klippy.log|' \
	-e 's|read -r -n 1 -t 0\.2 |read -r -n 1 -t 1 |g' \
	-e 's|read -r -n 1 -t 0\.05 |read -r -n 1 -t 1 |g' \
	"$O/opencreator/startup/scripts/08-mcu-wake.sh" > "$B/opencreator/mcu-wake.sh"
if grep -qE 'read .*-t [0-9]*\.' "$B/opencreator/mcu-wake.sh"; then
	die "mcu-wake.sh still has a fractional read timeout"
fi
# its Kalico default and its fallback search for Pillow
sed -e 's|/usr/data/opencreator/klipper/klipper/klippy|/data/printer/klipper/klippy|g' \
	-e 's|/usr/prog/moonraker/moonraker-env/lib/python3\*/site-packages|/data/printer/root/usr/lib/python3*/site-packages|g' \
	"$O/opencreator/moonraker/shaper_graph.py" > "$B/opencreator/shaper_graph.py"
if left=$(grep -rlE '/usr/(data|prog)|pellcorp|/etc/init\.d/S[0-9]' "$B/defaults" "$B/opencreator"); then
	die "stock paths left after the port: ${left//$B\//}"
fi
echo "opencreator-fs $(srcgit "$OFS" rev-parse --short HEAD)"

log "GrumpyScreen"
mkdir -p "$B/grumpyscreen"
install -m 0755 "${SRC[grumpyscreen]}" "$B/grumpyscreen/grumpyscreen"
if readelf -l "$B/grumpyscreen/grumpyscreen" | grep -q INTERP; then
	die "grumpyscreen is dynamically linked; the stack needs the static build"
fi

log "stack files"
install -m 0755 "$REPO/stack/install.sh" "$B/install.sh"
mkdir -p "$B/bin" "$B/etc"
install -m 0755 "$REPO"/stack/bin/* "$B/bin/"
install -m 0644 "$REPO/stack/etc/nginx.conf" "$B/etc/"
{
	echo "stack $(git -C "$REPO" describe --always --dirty --tags)"
	echo "kalico $(srcgit "$KALICO" rev-parse HEAD)"
	echo "moonraker $(srcgit "$MOONRAKER" rev-parse HEAD)"
	echo "opencreator-fs $(srcgit "$OFS" rev-parse HEAD)"
} > "$B/VERSION"
cat "$B/VERSION"

log "sanity"
for f in root/usr/bin/python3 root/usr/sbin/nginx root/etc/nginx/mime.types root/usr/bin/stty \
	klipper/klippy/chelper/c_helper.so "${SITE#"$B"/}/streaming_form_data/_parser.so" \
	"${SITE#"$B"/}/libnacl" "${SITE#"$B"/}/inotify_simple.py" "${SITE#"$B"/}/importlib_metadata"; do
	[ -e "$B/$f" ] || die "$f missing in the stack"
done
for f in "$CH/c_helper.so" "$SITE/streaming_form_data/_parser.so"; do
	readelf -h "$f" | grep -q 'Machine: *MIPS' || die "${f#"$B"/} is not a MIPS library"
done

log "pack -> $OUT"
mkdir -p "$OUT"
tar --owner=0 --group=0 --numeric-owner -czf "$OUT/stack.tar.gz" -C "$B" .
for ui in fluidd mainsail; do
	rm -rf "${T:?}/$ui"
	python3 -m zipfile -e "${SRC[$ui.zip]}" "$T/$ui"
	[ -f "$T/$ui/index.html" ] || die "$ui.zip has no index.html at its top"
	chmod 0755 "$T/$ui"
	tar --owner=0 --group=0 --numeric-owner -czf "$OUT/$ui.tar.gz" -C "$T/$ui" .
done
for f in stack.tar.gz fluidd.tar.gz mainsail.tar.gz; do
	printf '%-16s %10s bytes  sha256 %s\n' "$f" "$(stat -c %s "$OUT/$f")" "$(sha256sum < "$OUT/$f" | cut -d' ' -f1)"
done
echo
echo "Next: tools/make-install-stick.sh --stack $OUT [other options] VERSION_DIR STICKDIR"
