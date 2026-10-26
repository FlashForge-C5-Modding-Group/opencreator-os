#!/bin/sh
# Stock USB boot hook for the opencreator-os restore stick: stock's
# app_startup.sh mounts the stick at /mnt and runs this before its UI. Exit 0
# makes stock stall (used only while rebooting); non-zero lets stock boot on.
exec sh "$(dirname "$0")/opencreator-os-restore/restore.sh" --hook "$@"
