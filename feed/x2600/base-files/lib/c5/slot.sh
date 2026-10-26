# shellcheck shell=sh
# shellcheck disable=SC3043  # busybox ash supports 'local'
#
# Slot and boot-flag helpers for the Creator 5 Pro A/B eMMC layout.
#
# Sourced by preinit hooks, init scripts, /lib/upgrade/platform.sh and the
# c5-* tools. Sourcing has no side effects and prints nothing.
#
# Layout (GPT names on the eMMC): kernel/rootfs = slot 1, kernel2/rootfs2 =
# slot 2, ota = boot flag ("ota:kernel" -> slot 1, "ota:kernel2" -> slot 2,
# the SPL compares the first 11 bytes), userdata = stock /usr/data.
#
# Overridable for testing: C5_DISK, C5_CMDLINE_FILE, C5_SYSBLOCK, C5_KMSG.

C5_DISK=${C5_DISK:-/dev/mmcblk0}
C5_CMDLINE_FILE=${C5_CMDLINE_FILE:-/proc/cmdline}
C5_SYSBLOCK=${C5_SYSBLOCK:-/sys/class/block}
C5_KMSG=${C5_KMSG:-/dev/kmsg}
C5_BOOTLOG_SECTOR=128      # bootlog lives at 64 KiB inside the ota partition ...
C5_BOOTLOG_SECTORS=128     # ... and is 64 KiB long
C5_BOOTLOG_MAGIC=C5BOOTLOG1

# $1 = GPT partition name -> /dev/mmcblk0pN (return 1 if unknown)
c5_part_dev() {
	local nr='' u
	if command -v partx >/dev/null 2>&1; then
		nr=$(partx -s -g -o NR,NAME "$C5_DISK" 2>/dev/null |
			awk -v n="$1" '$2 == n { print $1; exit }')
	fi
	if [ -z "$nr" ]; then
		# Fallback without partx: the kernel exports GPT names as PARTNAME.
		for u in "$C5_SYSBLOCK/${C5_DISK##*/}p"*/uevent; do
			[ -f "$u" ] || continue
			grep -qx "PARTNAME=$1" "$u" || continue
			nr=$(sed -n 's/^PARTN=//p' "$u")
			break
		done
	fi
	[ -n "$nr" ] || return 1
	echo "${C5_DISK}p$nr"
}

# $1 = GPT partition name -> size in bytes
c5_part_bytes() {
	local dev sz
	dev=$(c5_part_dev "$1") || return 1
	sz=$(cat "$C5_SYSBLOCK/${dev##*/}/size" 2>/dev/null) || return 1
	[ -n "$sz" ] || return 1
	echo $((sz * 512))
}

c5_slot_kname() { if [ "$1" = 2 ]; then echo kernel2; else echo kernel; fi; }
c5_slot_rname() { if [ "$1" = 2 ]; then echo rootfs2; else echo rootfs; fi; }

# Value of the last root= on the kernel command line (the one the kernel uses).
c5_root_dev() {
	tr -s ' \t' '\n' < "$C5_CMDLINE_FILE" 2>/dev/null | sed -n 's/^root=//p' | tail -n 1
}

# 1 | 2 ; return 1 when the root is not an eMMC slot (USB root, chainload
# test from a stick, root=PARTLABEL=..., unknown partition table, ...)
c5_own_slot() {
	local r d
	r=$(c5_root_dev)
	[ -n "$r" ] || return 1
	d=$(c5_part_dev rootfs) && [ "$r" = "$d" ] && { echo 1; return 0; }
	d=$(c5_part_dev rootfs2) && [ "$r" = "$d" ] && { echo 2; return 0; }
	return 1
}

c5_other_slot() {
	case "$(c5_own_slot)" in
		1) echo 2 ;;
		2) echo 1 ;;
		*) return 1 ;;
	esac
}

# Raw flag string (first 11 bytes of ota, NUL/newline stripped).
c5_flag_read() {
	local dev
	dev=$(c5_part_dev ota) || return 1
	head -c 11 "$dev" | tr -d '\000\n'
}

# Slot the SPL will boot next: 2 iff the first 11 bytes are "ota:kernel2".
c5_flag_slot() {
	if [ "$(c5_flag_read)" = "ota:kernel2" ]; then echo 2; else echo 1; fi
}

c5_drop_caches() {
	sync
	{ echo 3 > /proc/sys/vm/drop_caches; } 2>/dev/null
	return 0
}

# $1 = 1|2 ; whole-sector write, NUL padded, read back.
c5_flag_write() {
	local s dev
	dev=$(c5_part_dev ota) || return 1
	case "$1" in
		1) s="ota:kernel" ;;
		2) s="ota:kernel2" ;;
		*) return 1 ;;
	esac
	printf '%s' "$s" | dd of="$dev" bs=512 count=1 conv=sync,notrunc,fsync 2>/dev/null || return 1
	c5_drop_caches
	[ "$(c5_flag_read)" = "$s" ]
}

# ota device if it is large enough to hold the bootlog area, else return 1.
c5_bootlog_dev() {
	local dev bytes
	dev=$(c5_part_dev ota) || return 1
	bytes=$(c5_part_bytes ota) || return 1
	[ "$bytes" -ge $(((C5_BOOTLOG_SECTOR + C5_BOOTLOG_SECTORS) * 512)) ] || return 1
	echo "$dev"
}

c5_bootlog_reset() {
	local dev
	dev=$(c5_bootlog_dev) || return 0
	dd if=/dev/zero of="$dev" bs=512 seek="$C5_BOOTLOG_SECTOR" count="$C5_BOOTLOG_SECTORS" \
		conv=notrunc,fsync 2>/dev/null
	return 0
}

# The area starts with the line $C5_BOOTLOG_MAGIC; anything else (zeros after
# a reset, or whatever stock left there) reads as an empty log.
c5_bootlog_show() {
	local dev
	dev=$(c5_bootlog_dev) || return 0
	dd if="$dev" bs=512 skip="$C5_BOOTLOG_SECTOR" count="$C5_BOOTLOG_SECTORS" 2>/dev/null |
		tr -d '\000' | awk -v m="$C5_BOOTLOG_MAGIC" 'NR == 1 { if ($0 != m) exit; next } { print }'
}

# Append one line "<uptime> <message>" to the bootlog (and to the kernel log).
# When the area is full the oldest lines are dropped.
c5_bootlog() {
	local dev max tmp up
	{ echo "c5: $*" > "$C5_KMSG"; } 2>/dev/null
	dev=$(c5_bootlog_dev) || return 0
	max=$((C5_BOOTLOG_SECTORS * 512 - ${#C5_BOOTLOG_MAGIC} - 1))
	tmp=/tmp/.c5-bootlog.$$
	up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
	{
		c5_bootlog_show
		printf '%s %s\n' "${up:-?}" "$*"
	} > "$tmp.new" || { rm -f "$tmp.new"; return 0; }
	if [ "$(wc -c < "$tmp.new")" -gt "$max" ]; then
		# keep the newest bytes, then drop the (possibly cut) first line
		tail -c "$max" "$tmp.new" | sed 1d > "$tmp.cut"
		mv -f "$tmp.cut" "$tmp.new"
	fi
	# Build the whole 64 KiB area in a file so dd never sees short pipe reads.
	dd if=/dev/zero of="$tmp" bs=512 count="$C5_BOOTLOG_SECTORS" 2>/dev/null &&
		{ echo "$C5_BOOTLOG_MAGIC"; cat "$tmp.new"; } | dd of="$tmp" conv=notrunc 2>/dev/null &&
		dd if="$tmp" of="$dev" bs=512 seek="$C5_BOOTLOG_SECTOR" count="$C5_BOOTLOG_SECTORS" \
			conv=notrunc,fsync 2>/dev/null
	rm -f "$tmp" "$tmp.new"
	return 0
}
