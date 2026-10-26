#!/bin/bash
# Import a tools/printer/phase0.sh output directory on the PC (WSL).
#
#   tools/verify-backup.sh SRC [DATE]
#
# SRC   the OUTDIR phase0.sh wrote (copied off the USB stick)
# DATE  defaults to today (YYYY-MM-DD)
#
# Facts go to  F:/creator5-dev/opencreator-os-work/facts-DATE/
# Backup goes to F:/creator5-dev/backups/DATE-creator5pro-emmc/ with chunks
# joined to NAME.img, every image checked against the printer-side SHA256SUMS.
# The backup directory is made read-only afterwards.
set -euo pipefail

SRC=$(realpath "${1:?usage: verify-backup.sh SRC [DATE]}")
DATE=${2:-$(date +%F)}
FACTS=/mnt/f/creator5-dev/opencreator-os-work/facts-$DATE
BK=/mnt/f/creator5-dev/backups/$DATE-creator5pro-emmc

die() { echo "verify-backup: $*" >&2; exit 1; }
[ -d "$SRC/facts" ] || die "$SRC/facts missing"

mkdir -p "$FACTS"
cp -a "$SRC/facts/." "$FACTS/"
[ -f "$SRC/phase0.log" ] && cp "$SRC/phase0.log" "$FACTS/"
echo "facts -> $FACTS"

[ -d "$SRC/backup" ] || { echo "no backup directory; facts only"; exit 0; }
[ -e "$BK" ] && die "$BK already exists; backups are never overwritten"
mkdir -p "$BK"
cp "$SRC/backup/first-mib.bin" "$SRC/backup/SHA256SUMS" "$SRC/backup/MANIFEST.txt" "$SRC/backup/partmap.txt" "$BK/"
while read -r sum name; do
	[ "$name" = first-mib.bin ] && continue
	cat "$SRC/backup/$name".[0-9][0-9][0-9] > "$BK/$name"
done < "$BK/SHA256SUMS"
(cd "$BK" && sha256sum -c SHA256SUMS) || die "checksum mismatch in $BK"
chmod -R a-w "$BK"
echo "backup verified -> $BK"
