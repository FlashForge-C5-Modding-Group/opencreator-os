#!/bin/sh
# Exercise docs/recovery.md's explicitly authorized one-off saved-stock copy.
# This is a test fixture, never installed into OpenWrt or the installer payload.
set -eu
SELF_DIR=/mnt/opencreator-os
. "$SELF_DIR/lib.sh"
. "$SELF_DIR/restore.sh"
c5dev=$(c5_part_dev c5os)
uddev=$(c5_part_dev userdata)
awk -v d="$c5dev" '$1 == d && $2 == "/data" && $3 == "ext4" &&
    $4 ~ /(^|,)rw(,|$)/ { ok = 1 } END { exit !ok }' /proc/mounts
if c5_mounted "$uddev"; then
    echo "userdata is already mounted; stop and resolve it first" >&2
    exit 1
fi
mnt=/tmp/c5-userdata-migrate
src=$mnt/opencreator-os/stock
dst=/data/opencreator-os/stock
for p in "$dst" "$dst.new"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
        echo "refusing to replace $p; inspect and preserve it first" >&2
        exit 1
    fi
done
mkdir "$mnt"
mounted=0
trap 'if [ "$mounted" = 1 ]; then umount "$mnt" || exit 1; fi; rmdir "$mnt"' EXIT
mount -t ext4 -o ro,noload "$uddev" "$mnt"
mounted=1
# Expose the actual mount, not merely the requested mount command, as evidence.
awk -v d="$uddev" '$1 == d { print "QEMU-MIGRATION-MOUNT " $0;
    if ($2 == "/tmp/c5-userdata-migrate" && $3 == "ext4" &&
        $4 ~ /(^|,)ro(,|$)/ && $4 ~ /(^|,)(noload|norecovery)(,|$)/) ok = 1
} END { exit !ok }' /proc/mounts
c5_restore_stock "$src" 1
mkdir -p /data/opencreator-os
mkdir "$dst.new"
cp -a "$src/." "$dst.new/"
sync
c5_restore_stock "$dst.new" 1
mv "$dst.new" "$dst"
sync
c5_restore_stock "$dst" 1
