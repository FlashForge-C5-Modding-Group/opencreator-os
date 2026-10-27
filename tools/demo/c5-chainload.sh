#!/bin/sh
# Stand-in for chainload/c5-chainload.sh in tools/ui-demo.sh: a PC cannot
# jump into the printer's kernel. "stage" records the request; "go"/"go-now"
# show a final screen on the os-installer app and wait until it closes.
case "$1" in
stage) echo "staged (demo) root=$2" ;;
go | go-now)
	printf '%s\n' "BLOCK demo-jump Demo: OpenWrt would start now\nOn the printer the stick's chainload jumps into OpenWrt from RAM here. Close the window to end the demo."
	exec cat > /dev/null
	;;
unstage | status) ;;
*) echo "usage: $0 stage|go|go-now|unstage|status" >&2; exit 2 ;;
esac
exit 0
