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
#   c5-chainload.sh args ROOTDEV [IMAGE]    print the computed cmdline,
#                                           safe_max, krp and the commit
#                                           decision; changes nothing
#
# ROOTDEV is the OpenWrt squashfs root as the new kernel will name it, e.g.
# /dev/mmcblk0p4 (eMMC slot) or /dev/sda1 (USB stick test).
#
# Commit: a healthy OpenWrt boot from an eMMC slot points the boot flag at
# that slot (c5-booted), so the SPL will boot the slot's own kernel next.
# That is only allowed when the staged IMAGE is that kernel: ROOTDEV is the
# GPT rootfs (rootfs2) partition and IMAGE is a uImage byte-identical to
# the GPT kernel (kernel2) partition over the uImage length (64 + ih_size),
# with no trailing bytes. Otherwise "c5.nocommit=1" is added to the command
# line and the test boot leaves the flag alone.
#
# Files: chainload.ko and kernel.uimage in the same directory as this script
# (normally /usr/data/opencreator-os/chainload/). BusyBox ash.
# C5CL_EXTRA: words appended to the new command line (e.g. c5.usbtest=1 for
# the zero-write USB test stick); only c5.* words are accepted.
# Test overrides: C5CL_CMDLINE, C5CL_IOMEM, C5CL_KALLSYMS name the files
# read instead of /proc/cmdline, /proc/iomem, /proc/kallsyms; C5CL_DISK
# (/dev/mmcblk0), C5CL_FDISK (fdisk), C5CL_DEVROOT (prefix for reading
# partition devices, empty).

DIR=$(cd "$(dirname "$0")" && pwd)
CMDLINE_FILE=${C5CL_CMDLINE:-/proc/cmdline}
IOMEM_FILE=${C5CL_IOMEM:-/proc/iomem}
KALLSYMS_FILE=${C5CL_KALLSYMS:-/proc/kallsyms}
DISK=${C5CL_DISK:-/dev/mmcblk0}
FDISK=${C5CL_FDISK:-fdisk}
DEVROOT=${C5CL_DEVROOT:-}
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
# kept (c5.* words dropped); rootwait and ieee754=relaxed appended when
# absent, and c5.nocommit=1 unless $commit is 1.
build_cmdline() {
	cl=""
	have_root=0
	read -r line < "$CMDLINE_FILE"
	set -f
	# shellcheck disable=SC2086 # split the command line into words
	for w in $line; do
		case "$w" in
		root=*) w="root=$1"; have_root=1 ;;
		c5.*) continue ;;
		esac
		cl="$cl${cl:+ }$w"
	done
	set +f
	[ "$have_root" = 1 ] || cl="$cl root=$1"
	case " $cl " in *" rootwait "*) ;; *) cl="$cl rootwait" ;; esac
	case " $cl " in *" ieee754=relaxed "*) ;; *) cl="$cl ieee754=relaxed" ;; esac
	[ "$commit" = 1 ] || cl="$cl c5.nocommit=1"
	[ -z "${C5CL_EXTRA:-}" ] || cl="$cl $C5CL_EXTRA"
	echo "$cl"
}

magic_hex() { head -c 4 "$1" 2>/dev/null | hexdump -ve '1/1 "%02x"'; }

# fdisk -l rows "NR START END SIZE ... NAME" (the listing stock's OTA
# scripts parse); GPT name of partition number $1 / number of name $1.
part_name() {
	"$FDISK" -l "$DISK" 2>/dev/null |
		awk -v n="$1" '$1 == n && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $NF; exit }'
}
part_nr() {
	"$FDISK" -l "$DISK" 2>/dev/null |
		awk -v n="$1" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $NF == n { print $1; c++ }
			END { if (c != 1) exit 1 }'
}

# check_commit ROOTDEV IMAGE: commit=1 when IMAGE is exactly the kernel
# stored in the eMMC slot of ROOTDEV, else commit=0. commit_why says why.
check_commit() {
	commit=0
	case "$1" in
	"$DISK"p[0-9]*) ;;
	*) commit_why="$1 is not a partition of $DISK"; return 0 ;;
	esac
	cc_nr=${1#"$DISK"p}
	case "$cc_nr" in *[!0-9]*) commit_why="$1 is not a partition of $DISK"; return 0 ;; esac
	cc_rname=$(part_name "$cc_nr")
	case "$cc_rname" in
	rootfs) cc_kname=kernel ;;
	rootfs2) cc_kname=kernel2 ;;
	*) commit_why="$1 is GPT '${cc_rname:-?}', not rootfs/rootfs2"; return 0 ;;
	esac
	cc_knr=$(part_nr "$cc_kname") || { commit_why="GPT partition $cc_kname not found (or not unique)"; return 0; }
	cc_kdev=${DISK}p$cc_knr
	[ "$(magic_hex "$2")" = 27051956 ] || { commit_why="$2 is not a uImage"; return 0; }
	[ "$(magic_hex "$DEVROOT$cc_kdev")" = 27051956 ] || { commit_why="$cc_kdev ($cc_kname) holds no uImage"; return 0; }
	cc_hs=$(head -c 16 "$2" | tail -c 4 | hexdump -ve '1/1 "%02x"')
	[ "${#cc_hs}" = 8 ] || { commit_why="cannot read the uImage size of $2"; return 0; }
	cc_len=$((64 + 0x$cc_hs))
	[ "$(wc -c < "$2" | tr -d ' ')" = "$cc_len" ] ||
		{ commit_why="$2 is not exactly one uImage ($cc_len bytes by its header)"; return 0; }
	if command -v sha256sum > /dev/null 2>&1; then cc_sum=sha256sum; else cc_sum=md5sum; fi
	[ "$(head -c "$cc_len" "$2" | $cc_sum | cut -d' ' -f1)" = "$(head -c "$cc_len" "$DEVROOT$cc_kdev" | $cc_sum | cut -d' ' -f1)" ] ||
		{ commit_why="$2 differs from $cc_kdev ($cc_kname)"; return 0; }
	commit=1
	commit_why="$2 equals $cc_kdev ($cc_kname, $cc_len bytes, $cc_sum)"
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
	set -f
	# shellcheck disable=SC2086 # split into words
	for w in ${C5CL_EXTRA:-}; do
		case "$w" in c5.?*) ;; *) set +f; die "C5CL_EXTRA accepts only c5.* words, got '$w'" ;; esac
	done
	set +f
	[ "$rootdev" != "$(running_root)" ] || die "$rootdev is the running stock root"
	check_commit "$rootdev" "$2"
	cmdline=$(build_cmdline "$rootdev")
	case "$cmdline" in *'"'*) die "command line contains a double quote" ;; esac
	sm=$(safe_max) || die "no System RAM range starting below 256 MiB in $IOMEM_FILE, or it ends below $(printf '0x%08x' $((SAFE_FLOOR + SAFE_GAP)))"
	krp=$(find_krp) || die "kernel_restart_prepare address not readable in $KALLSYMS_FILE"
}

commit_text() {
	if [ "$commit" = 1 ]; then
		echo "yes: a healthy boot makes this slot the default ($commit_why)"
	else
		echo "no (c5.nocommit=1): $commit_why"
	fi
}

cmd_args() {
	[ -n "$1" ] || die "usage: $0 args ROOTDEV [IMAGE]"
	compute "$1" "${2:-$DIR/kernel.uimage}"
	echo "cmdline=$cmdline"
	echo "safe_max=$sm"
	echo "krp=$krp"
	echo "commit=$(commit_text)"
}

cmd_stage() {
	[ -n "$1" ] || die "usage: $0 stage ROOTDEV [IMAGE]"
	img=${2:-$DIR/kernel.uimage}
	[ "$(uname -r)" = "5.10.186+" ] || die "expects the stock 5.10.186+ kernel, not $(uname -r)"
	[ -f "$DIR/chainload.ko" ] || die "no $DIR/chainload.ko"
	[ -f "$img" ] || die "no image $img"
	staged && die "already staged (run: $0 unstage)"
	compute "$1" "$img"
	if [ -b "$rootdev" ]; then
		[ "$(head -c 4 "$rootdev")" = hsqs ] ||
			echo "c5-chainload: warning: $rootdev does not start with a squashfs superblock" >&2
	else
		echo "c5-chainload: warning: $rootdev is not a block device under stock (the new kernel may still name it so)" >&2
	fi
	echo "image:    $img ($(wc -c < "$img") bytes)"
	echo "cmdline:  $cmdline"
	echo "safe_max: $sm   krp: $krp"
	echo "commit:   $(commit_text)"
	# busybox insmod >= 1.28 (stock: 1.31.1) quotes a value containing
	# spaces itself; older ones need the quotes in the argument. Quotes too
	# many truncate the command line at the first space, so try both forms
	# and keep only the one whose staged cmdline reads back unchanged.
	got=
	for q in '' '"'; do
		insmod "$DIR/chainload.ko" image="$img" cmdline="$q$cmdline$q" krp="$krp" safe_max="$sm" || continue
		got=$(cat /sys/module/chainload/parameters/cmdline 2>/dev/null)
		[ "$got" = "$cmdline" ] && break
		echo "c5-chainload: insmod form ${q:-unquoted} staged cmdline '$got'; unloading" >&2
		rmmod chainload || die "cannot unload a wrongly staged chainload.ko"
		got=
	done
	[ -n "$got" ] ||
		{ dmesg | grep 'chainload:' | tail -n 20; die "insmod failed, or the command line did not survive it"; }
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
*) sed -n '2,35p' "$0"; exit 2 ;;
esac
