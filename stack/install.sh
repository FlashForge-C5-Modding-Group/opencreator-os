#!/bin/sh
# The printer stack's installer (docs/stack.md), run by the image's
# c5-stack-setup after it unpacked the stack to P:
#
#   C5_MODEL_FILE=... C5_CALIBRATION_DIR=... C5_PRINTER_DATA=DIR sh install.sh P
#
# Prepares the user data in C5_PRINTER_DATA (default /data/printer_data):
# its directories, the default configuration where a file is missing (an
# existing one is kept), the stock calibration where missing, the model's
# printer.model.cfg (always rewritten) and Moonraker's service list. Writes
# only under P and C5_PRINTER_DATA, starts nothing, and can run again.
set -u

P=${1:?usage: install.sh STACK_DIR}
D=${C5_PRINTER_DATA:-/data/printer_data}

fail() { echo "install.sh: $*" >&2; exit 1; }

for d in config logs gcodes database comms misc tmp nginx grumpyscreen/thumbnails; do
	mkdir -p "$D/$d" || fail "cannot create $D/$d"
done

# defaults: copy what is missing, keep what the user has
(cd "$P/defaults/config" && find . -type d) | while IFS= read -r d; do
	mkdir -p "$D/config/$d" || exit 1
done || fail "cannot create the configuration directories"
(cd "$P/defaults/config" && find . -type f) | while IFS= read -r f; do
	[ -e "$D/config/$f" ] && continue
	cp "$P/defaults/config/$f" "$D/config/$f" || exit 1
	echo "install.sh: new config/${f#./}"
done || fail "cannot copy the default configuration"

if [ -n "${C5_CALIBRATION_DIR:-}" ] && [ -d "$C5_CALIBRATION_DIR" ]; then
	for f in "$C5_CALIBRATION_DIR"/*.json; do
		[ -f "$f" ] || continue
		mkdir -p "$D/config/calibration" || fail "cannot create $D/config/calibration"
		[ -e "$D/config/calibration/${f##*/}" ] && continue
		cp "$f" "$D/config/calibration/" || fail "cannot copy calibration ${f##*/}"
		echo "install.sh: calibration ${f##*/} copied"
	done
fi

model=$(awk '{ print $1; exit }' "${C5_MODEL_FILE:-/nonexistent}" 2> /dev/null)
case "$model" in
Creator5Pro) printf '%s\n' '# Written by install.sh: Creator 5 Pro' '[include printer.pro.cfg]' ;;
Creator5) printf '%s\n' '# Written by install.sh: Creator 5 (no chamber heater, chamber fans or aux fan)' ;;
*) printf '%s\n' '# Written by install.sh: model unknown, assumed Creator 5 Pro' '[include printer.pro.cfg]' ;;
esac > "$D/config/printer.model.cfg" || fail "cannot write printer.model.cfg"

printf '%s\n' klipper moonraker nginx grumpyscreen mcu-wake > "$D/moonraker.asvc" ||
	fail "cannot write moonraker.asvc"
exit 0
