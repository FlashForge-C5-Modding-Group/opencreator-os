# shellcheck shell=sh
# shellcheck disable=SC3043,SC2034  # busybox ash 'local'; C5_* results are read by callers
#
# Verified writes of saved images into stock's eMMC partitions, shared by
# /usr/sbin/c5-restore-stock and the USB recovery hook
# (/usr/libexec/c5-usb-recovery). Source /lib/c5/slot.sh first.
#
# Functions print progress on stdout. On failure they set C5_WHY and return 1.
#
# Rules:
#  - the slot OpenWrt runs from is never written; nothing mounted is written;
#  - every image is checked against SHA256SUMS (or MD5SUMS when that is the
#    only list, as the installer writes on a stock system without sha256sum)
#    before the write, and the written bytes are read back and checked again;
#  - before anything of stock is written the boot flag is pointed at the
#    running (OpenWrt) slot and stock is marked invalid in ota
#    (c5_stock_invalid_set, fsync + read back); the flag is checked once
#    more after that. 05_c5_tryboot, c5-slot boot-stock, sysupgrade and the
#    USB hook never select stock while the mark is set, so an interrupted or
#    failed write - even several power losses in a row - never leaves the
#    SPL booting a half-written stock. The mark is cleared only after every
#    write of the operation read back correctly. The caller points the flag
#    at stock afterwards if it wants to.

c5_why() { C5_WHY=$*; return 1; }

c5_size_of() { wc -c < "$1" | tr -d ' '; }

# DIR NAME: DIR/NAME must match its entry in DIR/SHA256SUMS (or MD5SUMS).
# Sets C5_SUM (checksum tool) and C5_WANT (expected checksum).
c5_verify_file() {
	local list
	[ -s "$1/$2" ] || { c5_why "missing $1/$2"; return 1; }
	if [ -s "$1/SHA256SUMS" ]; then
		C5_SUM=sha256sum list=SHA256SUMS
	elif [ -s "$1/MD5SUMS" ]; then
		C5_SUM=md5sum list=MD5SUMS
	else
		c5_why "no SHA256SUMS or MD5SUMS in $1"
		return 1
	fi
	C5_WANT=$(awk -v f="$2" '{ n = $2; sub(/^\*/, "", n); sub(/^\.\//, "", n) } n == f { print $1; exit }' "$1/$list")
	[ -n "$C5_WANT" ] || { c5_why "$list in $1 does not list $2"; return 1; }
	echo "checking $1/$2 against $list"
	[ "$("$C5_SUM" < "$1/$2" | cut -d' ' -f1)" = "$C5_WANT" ] || { c5_why "$1/$2 does not match $list"; return 1; }
}

# DEV PARTNAME FILE: DEV may be written with FILE (not the root, not
# mounted, FILE fits).
c5_check_target() {
	local max sz
	[ "$1" != "$(c5_root_dev)" ] || { c5_why "$1 is the running root"; return 1; }
	if c5_mounted "$1"; then c5_why "$1 is mounted"; return 1; fi
	max=$(c5_part_bytes "$2") || { c5_why "cannot size $1"; return 1; }
	sz=$(c5_size_of "$3")
	[ "$sz" -le "$max" ] || { c5_why "${3##*/} ($sz bytes) is larger than $1 ($max bytes)"; return 1; }
}

# The mark lists the stock parts that may be half written: "slot" (stock's
# kernel + rootfs) and/or "usershare". Each operation adds its part before
# writing and removes it after its last verified write; the mark is cleared
# when no part is left, so a good usershare restore does not hide a
# half-written slot and vice versa.

# PART: point the flag at the running slot, add PART to the mark, check the
# flag again. Nothing of stock may be written unless this succeeded.
c5_stock_write_begin() {
	local own cur
	own=$(c5_own_slot) || { c5_why "root $(c5_root_dev) is not an eMMC slot"; return 1; }
	c5_flag_write "$own" || { c5_why "cannot point the boot flag at the running slot $own (flag '$(c5_flag_read)')"; return 1; }
	cur=$(c5_stock_invalid) || cur=
	case " $cur " in *" $1 "*) ;; *) cur="${cur:+$cur }$1" ;; esac
	c5_stock_invalid_set "$cur" || { c5_why "cannot mark stock invalid in the ota partition; nothing written"; return 1; }
	[ "$(c5_flag_slot)" = "$own" ] || { c5_why "boot flag is '$(c5_flag_read)', not slot $own; nothing written"; return 1; }
	echo "boot flag -> slot $own (this system); stock marked invalid ($cur) while it is written"
}

# PART: all writes of PART verified; drop it from the mark.
c5_stock_write_end() {
	local cur rest='' p
	cur=$(c5_stock_invalid) || cur=
	for p in $cur; do
		[ "$p" = "$1" ] || rest="${rest:+$rest }$p"
	done
	if [ -z "$rest" ]; then
		c5_stock_invalid_clear || { c5_why "written and verified, but the stock-invalid mark could not be cleared"; return 1; }
		echo "stock-invalid mark cleared"
	else
		c5_stock_invalid_set "$rest" || { c5_why "written and verified, but the stock-invalid mark could not be updated"; return 1; }
		echo "stock still marked invalid: $rest"
	fi
}

# FILE DEV TOOL SUM: dd FILE to DEV, then compare TOOL over the first
# size-of-FILE bytes of DEV with SUM.
c5_write_verified() {
	local sz
	sz=$(c5_size_of "$1")
	echo "writing ${1##*/} ($sz bytes) -> $2"
	dd if="$1" of="$2" bs=1M conv=notrunc,fsync 2>/dev/null || { c5_why "writing $2 failed"; return 1; }
	c5_drop_caches
	[ "$(head -c "$sz" "$2" | "$3" | cut -d' ' -f1)" = "$4" ] || { c5_why "read-back mismatch on $2"; return 1; }
	echo "verified $2"
}

# DIR DRY(0|1): write DIR/kernel.img and DIR/rootfs.squashfs into the slot
# this system is not running from. Sets C5_STOCK_SLOT. With DRY=1 only the
# checks run. The boot flag is left on the running slot.
c5_restore_stock() {
	local dir="$1" own slot kdev rdev ksum rsum
	own=$(c5_own_slot) || { c5_why "root $(c5_root_dev) is not an eMMC slot; cannot tell which slot is stock"; return 1; }
	slot=$(c5_other_slot)
	C5_STOCK_SLOT=$slot
	kdev=$(c5_part_dev "$(c5_slot_kname "$slot")") || { c5_why "no $(c5_slot_kname "$slot") partition"; return 1; }
	rdev=$(c5_part_dev "$(c5_slot_rname "$slot")") || { c5_why "no $(c5_slot_rname "$slot") partition"; return 1; }
	c5_verify_file "$dir" kernel.img || return 1
	ksum=$C5_WANT
	c5_verify_file "$dir" rootfs.squashfs || return 1
	rsum=$C5_WANT
	[ "$(c5_magic_hex "$dir/kernel.img")" = 27051956 ] || { c5_why "kernel.img is not a uImage"; return 1; }
	[ "$(head -c 4 "$dir/rootfs.squashfs")" = hsqs ] || { c5_why "rootfs.squashfs is not squashfs"; return 1; }
	c5_check_target "$kdev" "$(c5_slot_kname "$slot")" "$dir/kernel.img" || return 1
	c5_check_target "$rdev" "$(c5_slot_rname "$slot")" "$dir/rootfs.squashfs" || return 1
	echo "running slot $own; stock slot $slot: kernel.img -> $kdev, rootfs.squashfs -> $rdev"
	[ "$2" = 1 ] && return 0
	c5_stock_write_begin slot || return 1
	c5_write_verified "$dir/kernel.img" "$kdev" "$C5_SUM" "$ksum" || return 1
	c5_write_verified "$dir/rootfs.squashfs" "$rdev" "$C5_SUM" "$rsum" || return 1
	c5_stock_write_end slot
}

# NAME DIR DRY(0|1): write DIR/NAME.img into the stock partition NAME. Only
# usershare (stock /usr/prog and /etc, not mounted by OpenWrt) is allowed.
# The boot flag is left on the running slot.
c5_restore_partition() {
	local dev
	case "$1" in
		usershare) ;;
		userdata)
			c5_why "userdata is mounted at $C5_DATA and is too large for FAT32; restore it from stock or over SSH"
			return 1
			;;
		*)
			c5_why "restoring partition '$1' is not supported (only usershare)"
			return 1
			;;
	esac
	dev=$(c5_part_dev "$1") || { c5_why "no $1 partition"; return 1; }
	c5_verify_file "$2" "$1.img" || return 1
	# ext4 superblock magic 0xEF53 (little endian) at byte 1080
	[ "$(dd if="$2/$1.img" bs=1 skip=1080 count=2 2>/dev/null | hexdump -ve '1/1 "%02x"')" = 53ef ] ||
		{ c5_why "$1.img is not an ext4 image"; return 1; }
	c5_check_target "$dev" "$1" "$2/$1.img" || return 1
	echo "$1.img -> $dev"
	[ "$3" = 1 ] && return 0
	c5_stock_write_begin "$1" || return 1
	c5_write_verified "$2/$1.img" "$dev" "$C5_SUM" "$C5_WANT" || return 1
	c5_stock_write_end "$1"
}

# DIR: does the stock slot hold exactly DIR/kernel.img + DIR/rootfs.squashfs
# (both verified against DIR's checksum list first)? 0 = yes; 1 = no
# (C5_WHY says why); 2 = cannot tell (files missing or not verifiable).
c5_stock_matches() {
	local slot kdev rdev ksum
	[ -s "$1/kernel.img" ] && [ -s "$1/rootfs.squashfs" ] || return 2
	slot=$(c5_other_slot) || return 2
	kdev=$(c5_part_dev "$(c5_slot_kname "$slot")") || return 2
	rdev=$(c5_part_dev "$(c5_slot_rname "$slot")") || return 2
	c5_verify_file "$1" kernel.img > /dev/null || return 2
	ksum=$C5_WANT
	c5_verify_file "$1" rootfs.squashfs > /dev/null || return 2
	[ "$(head -c "$(c5_size_of "$1/kernel.img")" "$kdev" | "$C5_SUM" | cut -d' ' -f1)" = "$ksum" ] ||
		{ c5_why "$kdev differs from $1/kernel.img"; return 1; }
	[ "$(head -c "$(c5_size_of "$1/rootfs.squashfs")" "$rdev" | "$C5_SUM" | cut -d' ' -f1)" = "$C5_WANT" ] ||
		{ c5_why "$rdev differs from $1/rootfs.squashfs"; return 1; }
}
