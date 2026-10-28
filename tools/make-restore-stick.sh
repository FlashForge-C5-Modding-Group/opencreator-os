#!/usr/bin/env bash
# Assemble a USB stick that restores partitions of a verified eMMC backup
# (tools/verify-backup.sh output) through the stock USB hook.
#
#   tools/make-restore-stick.sh BACKUP_DIR OUTDIR [--slot1 | --slot2] [--usershare] [--flag-stock]
#
# BACKUP_DIR    e.g. /mnt/f/creator5-dev/backups/<date>-creator5pro-emmc
# OUTDIR        new or empty directory; its contents go to the stick root
# --slot1       restore kernel.img + rootfs.img to kernel + rootfs
# --slot2       restore kernel2.img + rootfs2.img to kernel2 + rootfs2
# --usershare   restore usershare.img (refused while stock runs, since stock
#               mounts it; kept for rescue systems that do not)
# --flag-stock  after restoring the slot, point the boot flag at it and reboot
#
# The printer refuses to write the slot it is running from, so one slot per
# stick. Everything is checked (checksums, partition table, running slot,
# mounts, sizes) before the first write; the stick's restore.conf becomes
# restore.done after a successful restore.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SLOT1=0 SLOT2=0 USERSHARE=0 FLAG=0
ARGS=()

usage() { sed -n '2,18s/^# \{0,1\}//p' "$0"; }
die() { echo "make-restore-stick: $*" >&2; exit 1; }

for a in "$@"; do
	case "$a" in
	--slot1) SLOT1=1 ;;
	--slot2) SLOT2=1 ;;
	--usershare) USERSHARE=1 ;;
	--flag-stock) FLAG=1 ;;
	-h | --help) usage; exit 0 ;;
	-*) echo "unknown option $a" >&2; usage >&2; exit 2 ;;
	*) ARGS+=("$a") ;;
	esac
done
[ ${#ARGS[@]} -eq 2 ] || { usage >&2; exit 2; }
BK=${ARGS[0]} OUT=${ARGS[1]}

[ $((SLOT1 + SLOT2 + USERSHARE)) -gt 0 ] || die "nothing selected (--slot1, --slot2, --usershare)"
[ $((SLOT1 + SLOT2)) -le 1 ] || die "--slot1 and --slot2 together: the running slot is always refused; make one stick per slot"
FLAG_SLOT=
if [ "$FLAG" = 1 ]; then
	[ $((SLOT1 + SLOT2)) -eq 1 ] || die "--flag-stock needs --slot1 or --slot2"
	if [ "$SLOT1" = 1 ]; then FLAG_SLOT=1; else FLAG_SLOT=2; fi
fi

[ -d "$BK" ] || die "$BK is not a directory"
for f in SHA256SUMS MANIFEST.txt partmap.txt; do
	[ -s "$BK/$f" ] || die "missing $BK/$f"
done
for f in installer/restore/runFirmwareExe.sh installer/restore/restore.sh installer/opencreator-os/lib.sh feed/x2600/base-files/lib/c5/slot.sh \
	installer/fb/restoring.raw installer/fb/restored.raw installer/fb/restore-failed.raw; do
	[ -s "$REPO/$f" ] || die "missing $REPO/$f"
done
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
	die "$OUT exists and is not empty"
fi

# action list: "PARTITION IMAGE"
ACTIONS=()
[ "$SLOT1" = 0 ] || ACTIONS+=("kernel kernel.img" "rootfs rootfs.img")
[ "$SLOT2" = 0 ] || ACTIONS+=("kernel2 kernel2.img" "rootfs2 rootfs2.img")
[ "$USERSHARE" = 0 ] || ACTIONS+=("usershare usershare.img")

R=$OUT/opencreator-os-restore
mkdir -p "$R/fb"
install -m 0755 "$REPO/installer/restore/runFirmwareExe.sh" "$OUT/"
install -m 0755 "$REPO/installer/restore/restore.sh" "$R/"
install -m 0644 "$REPO/installer/opencreator-os/lib.sh" "$REPO/feed/x2600/base-files/lib/c5/slot.sh" "$R/"
install -m 0644 "$REPO"/installer/fb/{restoring,restored,restore-failed}.raw "$R/fb/"
tr -d '\r' < "$BK/partmap.txt" > "$R/partmap.txt"
install -m 0644 "$BK/MANIFEST.txt" "$R/"

for a in "${ACTIONS[@]}"; do
	img=${a#* }
	want=$(awk -v f="$img" '$2 == f || $2 == "*" f { print $1; exit }' "$BK/SHA256SUMS")
	[ -n "$want" ] || die "$img is not listed in $BK/SHA256SUMS"
	[ -f "$BK/$img" ] || die "missing $BK/$img"
	echo "copying $img ($(stat -c %s "$BK/$img") bytes)"
	install -m 0644 "$BK/$img" "$R/$img"
	[ "$(sha256sum < "$R/$img" | cut -d' ' -f1)" = "$want" ] || die "$img copy does not match the backup's SHA256SUMS"
done

{
	echo "# opencreator-os restore actions, made $(date -u '+%F %T') UTC"
	echo "# from $(cd "$BK" && pwd)"
	for a in "${ACTIONS[@]}"; do echo "write $a"; done
	[ -z "$FLAG_SLOT" ] || echo "flag $FLAG_SLOT"
} > "$R/restore.conf"

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
(cd "$R" && find . -type f ! -name SHA256SUMS ! -name MD5SUMS ! -name restore.conf | sed 's|^\./||' | LC_ALL=C sort) > "$LIST"
(cd "$R" && xargs -d '\n' sha256sum < "$LIST" > SHA256SUMS && xargs -d '\n' md5sum < "$LIST" > MD5SUMS)

echo "Restore stick in $OUT:"
(cd "$OUT" && find . -type f | sed 's|^\./|  |' | LC_ALL=C sort)
echo "Actions:"
sed -n 's/^\([^#]\)/  \1/p' "$R/restore.conf"
echo
echo "Copy the contents of $OUT to the root of a FAT32 USB stick and boot the printer"
echo "with it. Result: opencreator-os-restore/result.log on the stick."
echo "Use it only on the printer this backup was taken from; the partition table is checked."
