#!/bin/sh
# Stock USB boot hook: stock's app_startup.sh mounts the stick at /mnt and runs
# /mnt/runFirmwareExe.sh MACHINE PID before its UI starts. Exit 0 makes stock
# stall (used while rebooting and after a refused chainload jump); non-zero
# lets stock boot on.
#
# The installer runs from a copy in /tmp/c5os: command lines free of
# "opencreator", which c5-chainload.sh go-now kills, and the stick can be
# unmounted under it. With the os-installer app on the stick the app draws
# the screens and runs install.sh --ui as its child; the app stays this
# hook's foreground child so stock does not resume booting during a jump.
# No app, or no display/touch (app exit 3): install.sh runs headless.
S=$(dirname "$0")
T=/tmp/c5os
rm -rf "$T"
cp -r "$S/opencreator-os" "$T" || exit 1
chmod 755 "$T/os-installer" "$T/bin/"* 2>/dev/null
if [ -x "$T/os-installer" ]; then
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
	"$T/os-installer" --log "$S/os-installer.log" -- sh "$T/install.sh" --from-stick "$S" --hook --ui "$@"
	rc=$?
	[ "$rc" = 3 ] || exit "$rc"
fi
exec sh "$T/install.sh" --from-stick "$S" --hook "$@"
