#!/bin/sh
# Stock USB boot hook for Phase 0. Put this file and phase0.sh in the root of
# a FAT32 stick and power the printer on with the stick inserted. Stock's
# app_startup.sh mounts the stick and runs this script before the UI.
# Facts land in $(dirname $0)/phase0/ on the stick (no backup; append
# --backup to the phase0.sh line for that). The script always exits 1 so
# stock keeps booting normally; remove the stick afterwards (or the hook
# runs again on the next boot).
sh $(dirname $0)/phase0.sh > $(dirname $0)/phase0-console.txt 2>&1
echo "phase0 exit $?" >> $(dirname $0)/phase0-console.txt
sync
exit 1
