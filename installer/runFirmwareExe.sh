#!/bin/sh
# USB boot hook on stock and OpenWrt, with the stick mounted at /mnt.
# Stock's app_startup.sh and OpenWrt's c5-usb-hook pass MACHINE PID.
# Exit 0 stalls stock (used while rebooting); non-zero lets stock boot on.
#
# The installer runs from a copy in /tmp/c5os: command lines free of
# "opencreator", which c5-chainload.sh go-now kills, and the stick can be
# unmounted under it. With the os-installer app on the stick the app draws
# the screens and runs install.sh --ui as its child; the app stays this
# hook's foreground child so stock does not resume booting during a jump.
# No app, or no display/touch (app exit 3): install.sh runs headless.
# OpenWrt's kernel shows its boot log on the panel (fbcon): unbind fbcon while
# the app owns /dev/fb0 so console text and cursor stay off its screens, bind
# it again when the app exits. Stock has no fbcon, so nothing changes there.
S=$(dirname "$0")
T=/tmp/c5os
fbcon_bind() {
	for v in /sys/class/vtconsole/vtcon*; do
		grep -q 'frame buffer' "$v/name" 2>/dev/null && echo "$1" > "$v/bind"
	done
	return 0
}
rm -rf "$T"
cp -r "$S/opencreator-os" "$T" || exit 1
chmod 755 "$T/os-installer" "$T/bin/"* 2>/dev/null
if [ -x "$T/os-installer" ]; then
	if [ -f /usr/prog/modules/gt9xx_touch.ko ]; then
		# stock loads the touch driver only after this hook
		insmod /usr/prog/modules/gt9xx_touch.ko gtp_i2c_bus_num=0 gtp_x_coords_min=0 gtp_y_coords_min=0 \
			gtp_x_coords_max=800 gtp_y_coords_max=480 gtp_x_coords_flip=0 gtp_y_coords_flip=0 \
			gtp_x_y_coords_exchange=0 gtp_version=0x4 gtp_regulator_name=-1 gtp_power_on_gpio=-1 \
			gtp_reset_gpio=PC08 gtp_irq_gpio=PC07 gtp_max_touch_number=2 2>/dev/null
		i=0
		until grep -qi goodix /proc/bus/input/devices 2>/dev/null || [ $i -ge 10 ]; do
			sleep 1
			i=$((i + 1))
		done
	fi
	fbcon_bind 0
	"$T/os-installer" --log "$S/os-installer.log" -- sh "$T/install.sh" --from-stick "$S" --hook --ui "$@"
	rc=$?
	fbcon_bind 1
	[ "$rc" = 3 ] || exit "$rc"
fi
exec sh "$T/install.sh" --from-stick "$S" --hook "$@"
