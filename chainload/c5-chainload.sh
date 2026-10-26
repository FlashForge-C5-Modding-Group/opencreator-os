#!/bin/sh
# c5-chainload.sh: boot the opencreator-os kernel from RAM under the running
# stock Creator 5 Pro kernel (5.10.186+), without writing the eMMC or the
# boot flag. If the new kernel hangs, a power cycle boots stock as before.
#
#   c5-chainload.sh stage ROOTDEV [IMAGE]   load chainload.ko, stage IMAGE
#                                           (default: kernel.uimage next to
#                                           this script) with root=ROOTDEV
#   c5-chainload.sh go                      stop stock userspace, shut the
#                                           network down and jump (no return)
#   c5-chainload.sh unstage                 rmmod chainload
#   c5-chainload.sh status                  staged? parameters, dmesg lines
#   c5-chainload.sh args ROOTDEV            print the computed cmdline,
#                                           safe_max and krp; changes nothing
#
# ROOTDEV is the OpenWrt squashfs root as the new kernel will name it, e.g.
# /dev/mmcblk0p4 (eMMC slot) or /dev/sda1 (USB stick test).
#
# Files: chainload.ko and kernel.uimage in the same directory as this script
# (normally /usr/data/opencreator-os/chainload/). BusyBox ash.
# Test overrides: C5CL_CMDLINE, C5CL_IOMEM, C5CL_KALLSYMS name the files
# read instead of /proc/cmdline, /proc/iomem, /proc/kallsyms.

DIR=$(cd "$(dirname "$0")" && pwd)
CMDLINE_FILE=${C5CL_CMDLINE:-/proc/cmdline}
IOMEM_FILE=${C5CL_IOMEM:-/proc/iomem}
KALLSYMS_FILE=${C5CL_KALLSYMS:-/proc/kallsyms}
LOWMEM_TOP=$((0x10000000))
SAFE_GAP=$((16 << 20))
SAFE_FLOOR=$((0x01600000 + (8 << 20) + (1 << 20)))	# chainload.ko lower limit

die() { echo "c5-chainload: $*" >&2; exit 1; }
staged() { grep -q '^chainload ' /proc/modules; }

# End of the first System RAM range below 256 MiB (KSEG0 lowmem), minus
# 16 MiB, rounded down to 1 MiB; printed as 0x%08x.
safe_max() {
	ram=$(sed -n 's/^\([0-9a-fA-F]*\)-\([0-9a-fA-F]*\) : System RAM$/\1 \2/p' "$IOMEM_FILE" | {
		while read -r s e; do
			[ $((0x$s)) -lt $LOWMEM_TOP ] || continue
			end=$((0x$e + 1))
			[ "$end" -le $LOWMEM_TOP ] || end=$LOWMEM_TOP
			echo "$end"
			break
		done
	})
	[ -n "$ram" ] || return 1
	sm=$(( (ram - SAFE_GAP) & ~((1 << 20) - 1) ))
	[ "$sm" -gt "$SAFE_FLOOR" ] || return 1
	printf '0x%08x\n' "$sm"
}

# Stock command line with root= replaced; init=, rootfstype= and the rest
# kept; rootwait and ieee754=relaxed appended when absent.
build_cmdline() {
	cl=""
	have_root=0
	read -r line < "$CMDLINE_FILE"
	set -f
	# shellcheck disable=SC2086 # split the command line into words
	for w in $line; do
		case "$w" in
		root=*) w="root=$1"; have_root=1 ;;
		esac
		cl="$cl${cl:+ }$w"
	done
	set +f
	[ "$have_root" = 1 ] || cl="$cl root=$1"
	case " $cl " in *" rootwait "*) ;; *) cl="$cl rootwait" ;; esac
	case " $cl " in *" ieee754=relaxed "*) ;; *) cl="$cl ieee754=relaxed" ;; esac
	echo "$cl"
}

# Address of kernel_restart_prepare; lifts kptr_restrict while reading if
# the addresses are hidden.
find_krp() {
	a=$(awk '$3 == "kernel_restart_prepare" { print $1; exit }' "$KALLSYMS_FILE")
	case "$a" in
	*[!0]*) ;;
	*)
		[ "$KALLSYMS_FILE" = /proc/kallsyms ] || return 1
		old=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null) || return 1
		echo 0 > /proc/sys/kernel/kptr_restrict || return 1
		a=$(awk '$3 == "kernel_restart_prepare" { print $1; exit }' /proc/kallsyms)
		echo "$old" > /proc/sys/kernel/kptr_restrict
		;;
	esac
	case "$a" in *[!0]*) echo "0x$a" ;; *) return 1 ;; esac
}

running_root() { sed -n 's/.*[[:space:]]root=\([^[:space:]]*\).*/\1/p; s/^root=\([^[:space:]]*\).*/\1/p' "$CMDLINE_FILE" | head -n 1; }

compute() {
	rootdev=$1
	case "$rootdev" in /dev/?*) ;; *) die "ROOTDEV must be a /dev path, got '$rootdev'" ;; esac
	[ "$rootdev" != "$(running_root)" ] || die "$rootdev is the running stock root"
	cmdline=$(build_cmdline "$rootdev")
	case "$cmdline" in *'"'*) die "command line contains a double quote" ;; esac
	sm=$(safe_max) || die "no System RAM range starting below 256 MiB in $IOMEM_FILE, or it ends below $(printf '0x%08x' $((SAFE_FLOOR + SAFE_GAP)))"
	krp=$(find_krp) || die "kernel_restart_prepare address not readable in $KALLSYMS_FILE"
}

cmd_args() {
	[ -n "$1" ] || die "usage: $0 args ROOTDEV"
	compute "$1"
	echo "cmdline=$cmdline"
	echo "safe_max=$sm"
	echo "krp=$krp"
}

cmd_stage() {
	[ -n "$1" ] || die "usage: $0 stage ROOTDEV [IMAGE]"
	img=${2:-$DIR/kernel.uimage}
	[ "$(uname -r)" = "5.10.186+" ] || die "expects the stock 5.10.186+ kernel, not $(uname -r)"
	[ -f "$DIR/chainload.ko" ] || die "no $DIR/chainload.ko"
	[ -f "$img" ] || die "no image $img"
	staged && die "already staged (run: $0 unstage)"
	compute "$1"
	if [ -b "$rootdev" ]; then
		[ "$(head -c 4 "$rootdev")" = hsqs ] ||
			echo "c5-chainload: warning: $rootdev does not start with a squashfs superblock" >&2
	else
		echo "c5-chainload: warning: $rootdev is not a block device under stock (the new kernel may still name it so)" >&2
	fi
	echo "image:    $img ($(wc -c < "$img") bytes)"
	echo "cmdline:  $cmdline"
	echo "safe_max: $sm   krp: $krp"
	insmod "$DIR/chainload.ko" image="$img" cmdline="\"$cmdline\"" krp="$krp" safe_max="$sm" ||
		{ dmesg | grep 'chainload:' | tail -n 20; die "insmod failed"; }
	dmesg | grep 'chainload:' | tail -n 40
	echo "staged. Next: $0 go   (or: $0 unstage)"
}

cmd_status() {
	if staged; then
		echo "staged"
		for p in image cmdline krp safe_max; do
			echo "  $p: $(cat /sys/module/chainload/parameters/$p 2>/dev/null)"
		done
	else
		echo "not staged"
	fi
	dmesg | grep 'chainload:' | tail -n 20
}

# Runs detached from the SSH session: the network goes down on the way.
go_now() {
	trap '' HUP
	if [ -w /dev/console ]; then exec >/dev/console 2>&1 </dev/null; fi
	echo "c5-chainload: stopping stock userspace"
	killall firmwareExe 2>/dev/null
	for p in /proc/[0-9]*; do
		[ "${p#/proc/}" = "$$" ] && continue
		case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in
		*c5-chainload*) ;;
		*klippy*|*moonraker*|*opencreator*|*c5_bridge*|*c5_socat*)
			kill "${p#/proc/}" 2>/dev/null ;;
		esac
	done
	killall wpa_supplicant hostapd udhcpc dhcpcd 2>/dev/null
	sleep 2
	sync
	for m in /usr/data /usr/prog; do
		mountpoint -q "$m" && mount -o remount,ro "$m" 2>/dev/null
	done
	mountpoint -q /mnt && umount /mnt 2>/dev/null
	sync
	# Network and USB do DMA into RAM: stop them before the copy.
	for i in wlan0 wlan1 eth0; do ifconfig "$i" down 2>/dev/null; done
	rmmod 8821cu rtl8188fu soc_mac_driver 2>/dev/null
	for d in /sys/bus/platform/drivers/dwc2/*.otg /sys/bus/platform/drivers/dwc2/*.usb; do
		[ -e "$d" ] && echo "${d##*/}" > /sys/bus/platform/drivers/dwc2/unbind
	done
	for c in /sys/devices/system/cpu/cpu[1-9]*/online; do
		[ -f "$c" ] && echo 0 > "$c"
	done
	sync
	echo "c5-chainload: jumping"
	echo 1 > /sys/module/chainload/parameters/go
	echo "c5-chainload: jump refused (dmesg | grep chainload); power-cycle to recover"
}

cmd_go() {
	staged || die "not staged (run: $0 stage ROOTDEV)"
	echo "c5-chainload: going; SSH drops. Power-cycle if the printer is not back within 3 minutes."
	if command -v setsid >/dev/null 2>&1; then
		setsid sh "$0" go-now >/dev/null 2>&1 </dev/null &
	elif command -v nohup >/dev/null 2>&1; then
		nohup sh "$0" go-now >/dev/null 2>&1 </dev/null &
	else
		sh "$0" go-now >/dev/null 2>&1 </dev/null &	# go-now ignores SIGHUP
	fi
}

case "$1" in
stage) shift; cmd_stage "$@" ;;
go) cmd_go ;;
go-now) go_now ;;
unstage) staged || die "not staged"; rmmod chainload ;;
status) cmd_status ;;
args) shift; cmd_args "$@" ;;
*) sed -n '2,22p' "$0"; exit 2 ;;
esac
