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
# Test-then-commit: the boot flag is pointed at the stock slot before our
# slot is written and stays there afterwards, also after a verified write.
# The next boot is therefore stock. The new image becomes the default only
# after it has booted once and /etc/init.d/c5-booted found it healthy: test
# it from stock with chainload (c5-chainload.sh stage/go over SSH, or a
# --chainload install stick), or with switch-to-openwrt.sh (SPL boot,
# try-once still applies). To make that possible the new kernel is copied to
# userdata as opencreator-os/chainload/kernel.uimage (the image
# c5-chainload.sh stages by default; it allows the commit only when that
# image equals the slot's kernel) and opencreator-os/pending-commit records
# what was written; c5-booted removes it when it commits. Both are deleted
# before the slot is written; if they cannot be written again afterwards the
# upgrade fails (the slot is then only usable through a reinstall from
# stock), so a stale saved kernel is never staged against a new rootfs.
#
# Refused while stock is not selectable (c5_stock_blocker: marked invalid by
# an unfinished restore, or no uImage/squashfs in its slot): the upgrade
# makes the next boot stock.
#
# Config: platform_copy_config stores $UPGRADE_BACKUP on userdata as
# opencreator-os/sysupgrade.tgz; preinit 79_c5_move_config moves it to
# /sysupgrade.tgz on the first boot of the new image, and 80_mount_root
# restores it.

. /lib/c5/slot.sh

REQUIRE_IMAGE_METADATA=1
# stage2's default ramfs list already has partx hexdump awk sed cut tar wc tail
# cat dd grep mount umount mkdir cp mv rm sync printf date logger; add the rest
# used by this file and slot.sh. Names are resolved with 'command -v', and
# busybox applet links are recreated in the ramfs pointing at /bin/busybox.
RAMFS_COPY_BIN='head tr sha256sum fwtool jsonfilter'
RAMFS_COPY_DATA='/lib/c5/slot.sh /etc/openwrt_release'

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
	local tar="$1" own dir ksz rsz kmax rmax why
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
	if why=$(c5_stock_blocker); then
		v "refusing: sysupgrade reboots into stock, but $why; repair stock first (c5-restore-stock)"
		return 1
	fi
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

# Version of the image from its fwtool metadata ("unknown" if unreadable).
c5_su_version() { # <tar>
	local meta=/tmp/.c5-su-meta.json ver=''
	if fwtool -q -i "$meta" "$1" 2>/dev/null; then
		ver=$(jsonfilter -i "$meta" -e '@.version.version' 2>/dev/null)
	fi
	rm -f "$meta"
	echo "${ver:-unknown}"
}

# Runs with userdata mounted at /tmp/c5data (c5_with_userdata): forget the
# saved chainload kernel and pending-commit of any earlier upgrade.
c5_drop_pending() {
	local d=/tmp/c5data/opencreator-os
	rm -f "$d/pending-commit" "$d/pending-commit.new" "$d/chainload/kernel.uimage" "$d/chainload/kernel.uimage.new"
	[ ! -e "$d/pending-commit" ] && [ ! -e "$d/chainload/kernel.uimage" ]
}

# Runs with userdata mounted at /tmp/c5data. Uses the C5_SU_* variables set
# by platform_do_upgrade. On any failure nothing usable is left behind.
c5_store_pending() {
	local d=/tmp/c5data/opencreator-os
	if mkdir -p "$d/chainload" &&
		c5_su_member "$C5_SU_TAR" "$C5_SU_DIR" kernel > "$d/chainload/kernel.uimage.new" &&
		[ "$(sha256sum < "$d/chainload/kernel.uimage.new" | cut -d' ' -f1)" = "$C5_SU_KSUM" ] &&
		mv -f "$d/chainload/kernel.uimage.new" "$d/chainload/kernel.uimage" &&
		{
			echo "slot=$C5_SU_SLOT"
			echo "rootdev=$C5_SU_RDEV"
			echo "version=$C5_SU_VERSION"
			echo "previous=$C5_SU_PREVIOUS"
			echo "date=$(date '+%F %T')"
			echo "kernel_sha256=$C5_SU_KSUM"
			echo "rootfs_sha256=$C5_SU_RSUM"
		} > "$d/pending-commit.new" &&
		mv -f "$d/pending-commit.new" "$d/pending-commit"; then
		# sysupgrade -n: drop a stale saved config so it is not restored later.
		[ -n "$UPGRADE_BACKUP" ] || rm -f "$d/sysupgrade.tgz"
		return 0
	fi
	c5_drop_pending
	return 1
}

platform_do_upgrade() {
	local tar="$1" own other dir kdev rdev rmax ksum rsum ksz rsz why
	own=$(c5_own_slot) || { v "root $(c5_root_dev) is not an eMMC slot; not writing"; return 1; }
	other=$(c5_other_slot)
	if why=$(c5_stock_blocker); then
		v "not writing: the next boot would be stock, but $why"
		return 1
	fi
	dir=$(c5_su_dir "$tar") || { v "not a sysupgrade tar"; return 1; }
	kdev=$(c5_part_dev "$(c5_slot_kname "$own")") || { v "kernel partition not found"; return 1; }
	rdev=$(c5_part_dev "$(c5_slot_rname "$own")") || { v "rootfs partition not found"; return 1; }
	rmax=$(c5_part_bytes "$(c5_slot_rname "$own")") || { v "cannot size $rdev"; return 1; }
	ksum=$(c5_su_member "$tar" "$dir" kernel | sha256sum | cut -d' ' -f1)
	rsum=$(c5_su_member "$tar" "$dir" root | sha256sum | cut -d' ' -f1)
	ksz=$(c5_su_member "$tar" "$dir" kernel | wc -c)
	rsz=$(c5_su_member "$tar" "$dir" root | wc -c)

	c5_with_userdata c5_drop_pending ||
		{ v "cannot remove the saved chainload kernel / pending-commit on userdata; not writing"; return 1; }

	v "Pointing the boot flag at stock (slot $other); it stays there after the write"
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
	c5_bootlog "sysupgrade: slot $own written and verified; flag stays on stock (slot $other) until a test boot commits it"

	C5_SU_TAR=$tar C5_SU_DIR=$dir C5_SU_SLOT=$own C5_SU_RDEV=$rdev C5_SU_KSUM=$ksum C5_SU_RSUM=$rsum
	C5_SU_VERSION=$(c5_su_version "$tar")
	C5_SU_PREVIOUS=$(sed -n "s/^DISTRIB_RELEASE='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" /etc/openwrt_release 2>/dev/null)
	if c5_with_userdata c5_store_pending; then
		v "Recorded opencreator-os/pending-commit and chainload/kernel.uimage on userdata"
	else
		v "ERROR: slot $own is written, but chainload/kernel.uimage and pending-commit could not be stored on userdata."
		v "The next boot is stock (slot $other). The new image cannot be test-booted with the saved kernel;"
		v "reinstall it from stock with an install stick (tools/make-install-stick.sh --chainload)."
		c5_bootlog "sysupgrade: slot $own written, but storing the chainload kernel / pending-commit FAILED"
		return 1
	fi

	v "Slot $own written and verified (version $C5_SU_VERSION). NEXT BOOT IS STOCK (slot $other)."
	v "Test-boot the new image from stock before it becomes the default:"
	v "  over SSH on stock: sh /usr/data/opencreator-os/chainload/c5-chainload.sh stage $rdev"
	v "                     sh /usr/data/opencreator-os/chainload/c5-chainload.sh go"
	v "  or a USB stick made with tools/make-install-stick.sh --chainload"
	v "The first healthy boot of slot $own commits it (c5-booted points the flag at it)."
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
