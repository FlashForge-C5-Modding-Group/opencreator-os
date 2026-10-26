#!/bin/sh
# Stock USB boot hook: stock's app_startup.sh mounts the stick at /mnt and runs
# /mnt/runFirmwareExe.sh MACHINE PID before its UI starts. Exit 0 makes stock
# stall (used only while rebooting after --flip); non-zero lets stock boot on.
exec sh "$(dirname "$0")/opencreator-os/install.sh" --from-stick "$(dirname "$0")" --hook "$@"
