#!/bin/sh
# Phase 0: read-only fact capture (and optional eMMC backup) on a stock
# Creator 5 Pro. Runs on the printer (busybox sh) as root. Nothing on the
# eMMC is written.
#
#   sh /path/on/stick/phase0.sh [--backup] [--all] [--out DIR]
#
# Output goes to $(dirname $0)/phase0, i.e. next to this script on the USB
# stick. --out DIR overrides it.
# --backup  also back up kernel, rootfs, kernel2, rootfs2, rtos, ota and
#           usershare (large partitions split into 1 GiB chunks
#           NAME.img.000, .001, ... so FAT32 works); off by default
# --all     with --backup, also back up userdata (/usr/data)
#
# Copy the phase0 directory to the PC afterwards and run
# tools/verify-backup.sh on it.
set -u

OUT=$(dirname $0)/phase0
BACKUP=0 ALL=0
while [ $# -gt 0 ]; do
	case $1 in
	--backup) BACKUP=1 ;;
	--all) ALL=1 ;;
	--out) OUT=${2:?--out needs a directory}; shift ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift
done

DISK=/dev/mmcblk0
CHUNK_MB=1024
mkdir -p "$OUT/facts" || exit 1
F=$OUT/facts
LOG=$OUT/phase0.log
log() { echo "$*"; echo "$(date '+%F %T') $*" >> "$LOG"; }
cap() { name=$1; shift; sh -c "$*" > "$F/$name" 2>&1; }

log "phase0: start, output $OUT"

cap cmdline.txt 'cat /proc/cmdline'
cap version.txt 'cat /proc/version; uname -a'
cap cpuinfo.txt 'cat /proc/cpuinfo'
cap meminfo.txt 'cat /proc/meminfo'
cap iomem.txt 'cat /proc/iomem'
cap mounts.txt 'cat /proc/mounts'
cap partitions.txt 'cat /proc/partitions'
cap mmcblk0.txt "cat /sys/block/mmcblk0/size; cat /sys/block/mmcblk0/device/type; cat /sys/block/mmcblk0/device/name 2>/dev/null"
cap fdisk.txt "fdisk -l $DISK"
cap modules.txt 'cat /proc/modules'
cap dmesg.txt 'dmesg'
cap gpio.txt 'ls /sys/class/gpio; for c in /sys/class/gpio/gpiochip*; do echo $c $(cat $c/base) $(cat $c/label) $(cat $c/ngpio); done'
cap usb.txt 'for d in /sys/bus/usb/devices/*; do echo $d $(cat $d/idVendor 2>/dev/null) $(cat $d/idProduct 2>/dev/null) $(cat $d/product 2>/dev/null); done'
cap kallsyms.txt "grep -E ' (kernel_restart_prepare|machine_restart|kernel_restart|__cpu_disable)\$' /proc/kallsyms"
cap tools.txt 'which sha256sum md5sum partx dd od head strings fbset devmem; busybox 2>&1 | head -1'
cap ota_info.txt 'cat /etc/ota_info'
cap fbset.txt 'fbset 2>&1; cat /sys/class/graphics/fb0/bits_per_pixel /sys/class/graphics/fb0/virtual_size 2>&1'
cap tty.txt 'ls -l /dev/ttyS* /dev/ttyUSB* /dev/ttyACM* 2>&1'
cap net.txt 'ip addr; ip link'
cap df.txt 'df -k'

cat /sys/firmware/fdt > "$F/running.dtb" 2>/dev/null || rm -f "$F/running.dtb"

# Partition map by GPT name: NAME NR START_SECTOR SIZE_SECTORS
fdisk -l "$DISK" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $NF, $1, $2, $3 - $2 + 1 }' > "$F/partmap.txt"
log "partmap:"; cat "$F/partmap.txt" | tee -a "$LOG"

part_nr() { awk -v n="$1" '$1 == n { print $2; exit }' "$F/partmap.txt"; }
part_dev() { nr=$(part_nr "$1"); [ -n "$nr" ] && echo "${DISK}p$nr"; }

dd if=$DISK of="$F/first-mib.bin" bs=1M count=1 2>/dev/null
strings -n 6 "$F/first-mib.bin" | grep -nE 'ota:kernel|root=/dev/mmcblk|U-Boot|console=|init=|rootfstype|rmem|rtos' > "$F/spl-strings.txt"

OTA=$(part_dev ota)
if [ -n "$OTA" ]; then
	dd if="$OTA" of="$F/ota-sector0.bin" bs=512 count=1 2>/dev/null
	head -c 64 "$OTA" | od -A d -c > "$F/ota-sector0.txt"
fi

ROOT=$(sed -n 's/.*[[:space:]]root=\([^[:space:]]*\).*/\1/p' /proc/cmdline)
echo "running root: $ROOT" > "$F/slots.txt"
for n in kernel kernel2 rootfs rootfs2 rtos ota usershare userdata; do
	d=$(part_dev "$n") || continue
	[ -n "$d" ] || continue
	echo "$n $d $(( $(cat /sys/class/block/${d#/dev/}/size) * 512 ))" >> "$F/slots.txt"
done
: > "$F/slot-sums.txt"
for n in rootfs rootfs2; do
	d=$(part_dev "$n")
	[ -n "$d" ] || continue
	magic=$(head -c 4 "$d")
	used=$(od -An -t u8 -j 40 -N 8 "$d" | tr -d ' ')
	echo "$n magic=$magic bytes_used=$used" >> "$F/slots.txt"
	[ "$magic" = hsqs ] && echo "$(head -c "$used" "$d" | sha256sum | cut -d' ' -f1)  $n.squashfs($used)" >> "$F/slot-sums.txt"
done
for n in kernel kernel2; do
	d=$(part_dev "$n")
	[ -n "$d" ] || continue
	echo "$n uimage_magic=$(head -c 4 "$d" | hexdump -ve '1/1 "%02x"')" >> "$F/slots.txt"
	echo "$(sha256sum < "$d" | cut -d' ' -f1)  $n.partition" >> "$F/slot-sums.txt"
done
log "facts done:"; cat "$F/slots.txt" | tee -a "$LOG"

[ "$BACKUP" = 1 ] || { log "phase0: facts only, done"; exit 0; }
[ -s "$F/partmap.txt" ] || { log "phase0: no partitions parsed from fdisk -l (see facts/fdisk.txt); backup skipped"; exit 1; }

B=$OUT/backup
mkdir -p "$B" || exit 1
NAMES="kernel rootfs kernel2 rootfs2 rtos ota usershare"
[ "$ALL" = 1 ] && NAMES="$NAMES userdata"

need=1
for n in $NAMES; do
	d=$(part_dev "$n"); [ -n "$d" ] || continue
	need=$(( need + $(cat /sys/class/block/${d#/dev/}/size) / 2048 + 1 ))
done
free=$(df -k "$OUT" | awk 'NR == 2 { print int($4 / 1024) }')
log "backup needs ${need} MiB, ${free} MiB free on $OUT"
[ "$free" -gt "$need" ] || { log "phase0: NOT ENOUGH SPACE, backup skipped"; exit 1; }

cp "$F/first-mib.bin" "$B/first-mib.bin"
( cd "$B" && sha256sum first-mib.bin > SHA256SUMS )
cp "$F/partmap.txt" "$B/partmap.txt"
for n in $NAMES; do
	d=$(part_dev "$n"); [ -n "$d" ] || { log "no partition $n"; continue; }
	mb=$(( ( $(cat /sys/class/block/${d#/dev/}/size) + 2047 ) / 2048 ))
	log "backup $n ($d, $mb MiB)"
	i=0
	while [ $(( i * CHUNK_MB )) -lt "$mb" ]; do
		c=$(printf '%03d' "$i")
		dd if="$d" of="$B/$n.img.$c" bs=1M skip=$(( i * CHUNK_MB )) count=$CHUNK_MB 2>/dev/null || { log "dd FAILED $n chunk $c"; exit 1; }
		i=$(( i + 1 ))
	done
	echo "$(sha256sum < "$d" | cut -d' ' -f1)  $n.img" >> "$B/SHA256SUMS"
done
{
	echo "date: $(date '+%F %T')"
	echo "running root: $ROOT"
	echo "ota flag: $(head -c 16 "$OTA" | tr -d '\000\n')"
	cat /etc/ota_info 2>/dev/null
	cat "$F/partmap.txt"
} > "$B/MANIFEST.txt"
sync
log "phase0: done; copy $OUT to the PC"
