# shellcheck shell=sh
# shellcheck disable=SC1091,SC3043,SC2034  # RAMFS_COPY_*/REQUIRE_* are read by stage2/fwtool.sh
#
# sysupgrade for the Creator 5 Pro A/B eMMC layout.
#
# The image is sysupgrade.tar (sysupgrade-<board>/{CONTROL,kernel,root} plus
# fwtool metadata). It is written into the slot OpenWrt runs from; the stock
# slot is never touched.
#
# Flow (OpenWrt v24.10): platform_check_image runs in validate_firmware_image
# (a separate process) before the upgrade; platform_do_upgrade and
# platform_copy_config run later from do_stage2 inside the ramfs, so nothing
# computed in platform_check_image survives - everything is recomputed here.
#
# Safety: the boot flag is pointed at the stock slot before our slot is
# written and back at our slot only after the written kernel and rootfs read
# back correctly, so a power loss or a bad write boots stock. The next boot's
# 05_c5_tryboot re-arms the try-once fallback as usual.
#
# Config: platform_copy_config stores $UPGRADE_BACKUP on userdata as
# opencreator-os/sysupgrade.tgz; preinit 79_c5_move_config moves it to
# /sysupgrade.tgz, which 80_mount_root restores.

. /lib/c5/slot.sh

REQUIRE_IMAGE_METADATA=1
# stage2's default ramfs list already has partx hexdump awk sed cut tar wc tail
# cat dd grep mount umount mkdir cp mv rm sync printf date logger; add the rest
# used by this file and slot.sh. Names are resolved with 'command -v', and
# busybox applet links are recreated in the ramfs pointing at /bin/busybox.
RAMFS_COPY_BIN='head tr sha256sum'
RAMFS_COPY_DATA='/lib/c5/slot.sh'

c5_su_dir() { # <tar> -> "sysupgrade-<board>/" (from the first member path)
	local d
	d=$(tar tf "$1" 2>/dev/null | sed -n 's#^\(sysupgrade-[^/]*/\).*#\1#p' | head -n 1)
	[ -n "$d" ] && echo "$d"
}

c5_su_member() { # <tar> <dir> <name>
	tar xOf "$1" "$2$3" 2>/dev/null
}

# Mount userdata at /tmp/c5data; run "$@"; unmount.
c5_with_userdata() {
	local dev rc
	dev=$(c5_part_dev userdata) || { v "no userdata partition"; return 1; }
	mkdir -p /tmp/c5data
	mount -t ext4 -o rw,noatime "$dev" /tmp/c5data || { v "cannot mount $dev"; return 1; }
	"$@"
	rc=$?
	sync
	umount /tmp/c5data
	return $rc
}

platform_check_image() {
	local tar="$1" own dir ksz rsz kmax rmax
	own=$(c5_own_slot) || { v "root $(c5_root_dev) is not an eMMC slot; refusing"; return 1; }
	dir=$(c5_su_dir "$tar") || { v "not a sysupgrade tar"; return 1; }
	[ "$(c5_su_member "$tar" "$dir" kernel | head -c 4 | hexdump -ve '1/1 "%02x"')" = 27051956 ] ||
		{ v "kernel is not a uImage"; return 1; }
	[ "$(c5_su_member "$tar" "$dir" root | head -c 4)" = hsqs ] ||
		{ v "root is not squashfs"; return 1; }
	ksz=$(c5_su_member "$tar" "$dir" kernel | wc -c)
	rsz=$(c5_su_member "$tar" "$dir" root | wc -c)
	kmax=$(c5_part_bytes "$(c5_slot_kname "$own")") || { v "cannot size the kernel partition"; return 1; }
	rmax=$(c5_part_bytes "$(c5_slot_rname "$own")") || { v "cannot size the rootfs partition"; return 1; }
	[ "$ksz" -le "$kmax" ] || { v "kernel too large ($ksz > $kmax)"; return 1; }
	[ "$rsz" -le "$rmax" ] || { v "rootfs too large ($rsz > $rmax)"; return 1; }
	return 0
}

# Zero the start of the area fstools uses as the overlay (squashfs bytes_used
# rounded up to 64 KiB) so the new rootfs never mounts a stale overlay.
c5_wipe_overlay() { # <rootfs dev> <partition bytes>
	local used off
	used=$(hexdump -s 40 -n 4 -e '1/4 "%u"' "$1") || return 1
	[ -n "$used" ] || return 1
	off=$(((used + 65535) / 65536 * 65536))
	[ $((off + 4096)) -le "$2" ] || return 0
	dd if=/dev/zero of="$1" bs=512 seek=$((off / 512)) count=8 conv=notrunc,fsync 2>/dev/null
}

platform_do_upgrade() {
	local tar="$1" own other dir kdev rdev rmax ksum rsum ksz rsz
	own=$(c5_own_slot) || { v "root $(c5_root_dev) is not an eMMC slot; not writing"; return 1; }
	other=$(c5_other_slot)
	dir=$(c5_su_dir "$tar") || { v "not a sysupgrade tar"; return 1; }
	kdev=$(c5_part_dev "$(c5_slot_kname "$own")") || { v "kernel partition not found"; return 1; }
	rdev=$(c5_part_dev "$(c5_slot_rname "$own")") || { v "rootfs partition not found"; return 1; }
	rmax=$(c5_part_bytes "$(c5_slot_rname "$own")") || { v "cannot size $rdev"; return 1; }
	ksum=$(c5_su_member "$tar" "$dir" kernel | sha256sum | cut -d' ' -f1)
	rsum=$(c5_su_member "$tar" "$dir" root | sha256sum | cut -d' ' -f1)
	ksz=$(c5_su_member "$tar" "$dir" kernel | wc -c)
	rsz=$(c5_su_member "$tar" "$dir" root | wc -c)

	v "Pointing the boot flag at stock (slot $other) while slot $own is written"
	c5_flag_write "$other" || { v "boot flag write failed; not writing"; return 1; }
	c5_bootlog "sysupgrade: writing slot $own"

	v "Writing kernel ($ksz bytes) to $kdev"
	c5_su_member "$tar" "$dir" kernel | dd of="$kdev" bs=1M conv=notrunc,fsync 2>/dev/null
	v "Writing rootfs ($rsz bytes) to $rdev"
	c5_su_member "$tar" "$dir" root | dd of="$rdev" bs=1M conv=notrunc,fsync 2>/dev/null
	c5_drop_caches

	if [ "$(head -c "$ksz" "$kdev" | sha256sum | cut -d' ' -f1)" != "$ksum" ] ||
	   [ "$(head -c "$rsz" "$rdev" | sha256sum | cut -d' ' -f1)" != "$rsum" ]; then
		v "READ-BACK MISMATCH: boot flag stays on stock (slot $other)"
		c5_bootlog "sysupgrade: READ-BACK MISMATCH on slot $own; flag stays on slot $other"
		return 1
	fi
	c5_wipe_overlay "$rdev" "$rmax" || v "warning: could not clear the old overlay"

	c5_flag_write "$own" || { v "boot flag write failed; next boot is stock (slot $other)"; return 1; }
	c5_bootlog "sysupgrade: slot $own written and verified; flag -> slot $own"
	v "Slot $own written and verified"

	# sysupgrade -n: drop a stale saved config so it is not restored later.
	[ -n "$UPGRADE_BACKUP" ] || c5_with_userdata rm -f /tmp/c5data/opencreator-os/sysupgrade.tgz
	return 0
}

c5_store_backup() {
	mkdir -p /tmp/c5data/opencreator-os &&
		cp -f "$UPGRADE_BACKUP" /tmp/c5data/opencreator-os/sysupgrade.tgz
}

platform_copy_config() {
	[ -f "$UPGRADE_BACKUP" ] || return 0
	if c5_with_userdata c5_store_backup; then
		v "Configuration saved to userdata"
	else
		v "Saving the configuration to userdata failed"
		return 1
	fi
}
