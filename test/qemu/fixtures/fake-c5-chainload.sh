#!/bin/sh
# Test double for chainload/c5-chainload.sh in the QEMU system tests.
# chainload.ko only runs on the X2600's stock kernel. This stand-in keeps the
# interface (stage ROOTDEV [IMAGE] / go / go-now / unstage / status) and
# computes the command line with the real script's "args" (embedded below by
# the harness, function c5cl_real), so root=, c5.nocommit=1 and the rest are
# the product's. Instead of jumping into the staged kernel it prints
#   QEMU-CHAINLOAD root=<ROOTDEV> cmdline=<command line>
# on the console and powers off; the harness then boots OpenWrt with that
# command line and the eMMC (boot flag included) exactly as left - which is
# what a RAM chainload amounts to.
DIR=$(cd "$(dirname "$0")" && pwd)
STATE=/tmp/qemu-chainload

jump() {
	[ -s "$STATE.root" ] || { echo "c5-chainload(fake): not staged" >&2; exit 1; }
	exec >/dev/console 2>&1
	sync
	# the real go-now remounts these read-only before the jump
	for m in /usr/data /usr/prog /tmp/c5os-config; do
		mount -o remount,ro "$m" 2>/dev/null
	done
	sync
	awk '$2 == "/tmp/c5os-config" { print "QEMU-CHAINLOAD-MOUNT " $0 }' /proc/mounts
	echo "QEMU-CHAINLOAD root=$(cat "$STATE.root") cmdline=$(cat "$STATE.cmdline")"
	poweroff -f
}

case "$1" in
stage)
	[ -n "$2" ] || { echo "usage: $0 stage ROOTDEV [IMAGE]" >&2; exit 2; }
	img=${3:-$DIR/kernel.uimage}
	[ -f "$img" ] || { echo "c5-chainload(fake): no image $img" >&2; exit 1; }
	[ ! -s "$STATE.root" ] || { echo "c5-chainload(fake): already staged" >&2; exit 1; }
	c5cl_real > /tmp/qemu-c5-chainload-real.sh
	args=$(sh /tmp/qemu-c5-chainload-real.sh args "$2" "$img") || { echo "$args"; exit 1; }
	echo "$args"
	echo "$args" | sed -n 's/^cmdline=//p' > "$STATE.cmdline"
	[ -s "$STATE.cmdline" ] || { echo "c5-chainload(fake): no cmdline from args" >&2; exit 1; }
	echo "$2" > "$STATE.root"
	echo "image:    $img ($(wc -c < "$img") bytes)"
	echo "staged (QEMU fake) root=$2"
	;;
go | go-now) jump ;;
unstage) rm -f "$STATE.root" "$STATE.cmdline" ;;
status) if [ -s "$STATE.root" ]; then echo "staged root=$(cat "$STATE.root")"; else echo "not staged"; fi ;;
*) echo "usage: $0 stage|go|go-now|unstage|status" >&2; exit 2 ;;
esac
exit 0
