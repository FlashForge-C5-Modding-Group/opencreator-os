#!/bin/sh
# QEMU stand-in for the stick's runFirmwareExe.sh with the touchscreen app:
# runs the installer in --ui mode against qemu/fake-ui.sh through two fifos.
# A tapped BLOCK button ends the "app" with 1 and so the hook, as on the
# printer; otherwise the hook returns the installer's status.
S=$(dirname "$0")
rm -f /tmp/ui-in /tmp/ui-out
mkfifo /tmp/ui-in /tmp/ui-out
sh "$S/opencreator-os/install.sh" --from-stick "$S" --hook --ui "$@" > /tmp/ui-out 2>&1 < /tmp/ui-in &
pid=$!
# both sides open ui-out first, so the fifo opens cannot deadlock
sh "$S/qemu/fake-ui.sh" < /tmp/ui-out > /tmp/ui-in || exit
wait $pid
