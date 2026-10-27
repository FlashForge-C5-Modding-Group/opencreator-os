#!/bin/sh
# Stock USB boot hook of the zero-write USB test stick (docs/usb-test.md).
# Stock's app_startup.sh mounts the stick's FAT partition at /mnt and runs
# this before its UI. The test script runs from a copy in /tmp so the stick
# can be unmounted before the jump.
S=$(cd "$(dirname "$0")" && pwd)/opencreator-os-test
rm -rf /tmp/c5usbtest
mkdir -p /tmp/c5usbtest || exit 1
cp "$S/usbtest.sh" "$S/lib.sh" /tmp/c5usbtest/ || exit 1
cd /tmp/c5usbtest || exit 1
exec sh /tmp/c5usbtest/usbtest.sh "$S"
