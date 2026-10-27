#!/bin/sh
# Stand-in for stock busybox "fdisk -l DISK" (tools/ui-demo.sh): prints one
# "NR START END SIZE NAME" line per GPT entry, the shape installer/lib.sh's
# part_map and part_table parse, from util-linux sfdisk --dump.
[ "$1" = -l ] && [ -n "$2" ] || { echo "usage: $0 -l DISK" >&2; exit 2; }
sfdisk --dump "$2" 2>/dev/null | awk '
	/ : *start=/ {
		dev = $1; nr = dev; sub(/.*[^0-9]/, "", nr)
		s = $0; sub(/.*start= */, "", s); sub(/,.*/, "", s)
		z = $0; sub(/.*size= */, "", z); sub(/,.*/, "", z)
		n = ""; if (match($0, /name="[^"]*"/)) n = substr($0, RSTART + 6, RLENGTH - 7)
		printf "%4d %12d %12d %10dK %s\n", nr, s, s + z - 1, z / 2, n
	}'
