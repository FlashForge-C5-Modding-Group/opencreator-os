# shellcheck shell=bash
# QEMU system-test helpers: fixtures (stock root, eMMC image, sticks), the SPL
# emulator, boots, image inspection and checks. Sourced by test/qemu/run.sh.
# shellcheck source=env.sh
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

FIX=$QWORK/fixtures
STOCK_SQFS=$FIX/stock-rootfs.squashfs
STOCK_KERNEL=$FIX/stock-kernel.uimage
BASE_DISK=$FIX/base-disk.img
C5OS_DISK=$FIX/c5os-disk.img
OWRT_SQFS=$FIX/openwrt-root.squashfs
QEMU_ROOT_PASSWORD=${QEMU_ROOT_PASSWORD:-root}
export QEMU_ROOT_PASSWORD

# ---------------------------------------------------------------- logging --

# Per-scenario state: RUN (directory), FAILS (failed checks), BOOTN (boots);
# SAY_TAG prefixes the terminal copy (parallel runs interleave there)
say() {
	local t
	t=$(date +%T)
	echo "[$t] $*" >> "$RUN/scenario.log"
	echo "[$t] ${SAY_TAG:-}$*" >&2
}

check() { # check DESCRIPTION CMD... ; records ok/FAIL, never aborts
	local d=$1
	shift
	if "$@" >> "$RUN/checks.out" 2>&1; then
		say "  ok   $d"
	else
		say "  FAIL $d"
		FAILS=$((FAILS + 1))
	fi
}

fatal() { say "  FAIL $*"; FAILS=$((FAILS + 1)); return 1; }

# ------------------------------------------------------- image inspection --

poff() { echo $((PSTART[$1] * 512)); }

img_bytes() { # DISK OFFSET LEN -> raw bytes on stdout
	dd if="$1" bs=1M iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none
}

img_flag() { img_bytes "$1" "$(poff 5)" 11 | tr -d '\000\n'; }
img_flag_hex() { img_bytes "$1" "$(poff 5)" 16 | od -An -tx1 | tr -d ' \n'; }
img_bootlog() { img_bytes "$1" $(($(poff 5) + 65536)) 65536 | tr -d '\000'; }
img_part_sum() { img_bytes "$1" "$(poff "$2")" "$3" | sha256sum | cut -d' ' -f1; }
img_part_magic() { img_bytes "$1" "$(poff "$2")" 4 | od -An -tx1 | tr -d ' \n'; }
img_tries() { img_bytes "$1" $(($(poff 5) + 196608)) 512 | tr -d '\000\n'; }

# ext4 file systems inside the image: debugfs with ?offset=
userdata_spec() { echo "$1?offset=$(poff 7)"; }
data_cat() { debugfs -R "cat $2" "$(userdata_spec "$1")" 2>/dev/null; }
data_has() { debugfs -R "stat $2" "$(userdata_spec "$1")" 2>/dev/null | grep -q '^Inode:'; }
data_ls() { debugfs -R "ls -l $2" "$(userdata_spec "$1")" 2>/dev/null; }
data_rm() { debugfs -w -R "rm $2" "$(userdata_spec "$1")" >/dev/null 2>&1; }
data_put() { # DISK LOCALFILE PATH (parent directory must exist)
	debugfs -w -R "rm $3" "$(userdata_spec "$1")" >/dev/null 2>&1
	debugfs -w -R "write $2 $3" "$(userdata_spec "$1")" 2>&1 | grep -q 'Allocated inode' 
}
data_mkdir() { debugfs -w -R "mkdir $2" "$(userdata_spec "$1")" >/dev/null 2>&1; }

# the same for c5os (p8, repartitioned images only)
c5os_spec() { echo "$1?offset=$(poff 8)"; }
c5os_cat() { debugfs -R "cat $2" "$(c5os_spec "$1")" 2>/dev/null; }
c5os_has() { debugfs -R "stat $2" "$(c5os_spec "$1")" 2>/dev/null | grep -q '^Inode:'; }
c5os_rm() { debugfs -w -R "rm $2" "$(c5os_spec "$1")" >/dev/null 2>&1; }
c5os_put() { # DISK LOCALFILE PATH (parent directory must exist)
	debugfs -w -R "rm $3" "$(c5os_spec "$1")" >/dev/null 2>&1
	debugfs -w -R "write $2 $3" "$(c5os_spec "$1")" 2>&1 | grep -q 'Allocated inode'
}
c5os_mkdir() { debugfs -w -R "mkdir $2" "$(c5os_spec "$1")" >/dev/null 2>&1; }

# OpenWrt overlay (fstools rootfs_data) inside slot N's rootfs partition
squashfs_used() { # FILE|DISK [OFFSET] -> bytes_used
	img_bytes "$1" $((${2:-0} + 40)) 8 | od -An -tu8 | tr -d ' '
}
overlay_off() { # DISK SLOTPART -> byte offset of rootfs_data in the image
	local used
	used=$(squashfs_used "$1" "$(poff "$2")")
	echo $(($(poff "$2") + (used + 65535) / 65536 * 65536))
}
overlay_spec() { echo "$1?offset=$(overlay_off "$1" "$2")"; }
overlay_cat() { debugfs -R "cat $3" "$(overlay_spec "$1" "$2")" 2>/dev/null; }
overlay_is_ext4() { [ "$(img_bytes "$1" $(($(overlay_off "$1" "$2") + 1080)) 2 | od -An -tx1 | tr -d ' \n')" = 53ef ]; }

# ------------------------------------------------------------- fixtures --

# Stock 2.0.0 root (local test fixture, never committed) + the test init.
build_stock_fixture() {
	local key stage
	mkdir -p "$FIX"
	key=$({ git -C "$STOCK_ARCHIVE" rev-parse "HEAD:$STOCK_ROOTFS_PATH"
		git -C "$STOCK_ARCHIVE" rev-parse HEAD:software/app_startup.sh
		cat "$QDIR"/fixtures/stock/*; declare -f build_stock_fixture; } | sha256sum | cut -c1-16)
	if [ -s "$STOCK_SQFS" ] && [ "$(cat "$STOCK_SQFS.key" 2>/dev/null)" = "$key" ]; then
		return 0
	fi
	echo "fixture: building the stock root squashfs" >&2
	stage=$FIX/stock-stage
	rm -rf "$stage"
	mkdir -p "$stage"
	git -C "$STOCK_ARCHIVE" archive --format=tar "HEAD:$STOCK_ROOTFS_PATH" | tar -x -C "$stage"
	# git keeps no empty directories: recreate the mount points of the stock
	# image (buildroot skeleton + stock's /usr/prog and /usr/data)
	(cd "$stage" && mkdir -p proc sys tmp run mnt root media opt home usr/prog usr/data)
	install -m 0644 "$QDIR/fixtures/stock/inittab" "$stage/etc/inittab"
	install -m 0755 "$QDIR/fixtures/stock/qemu-stock-init" "$QDIR/fixtures/stock/qemu-stock-finish" "$stage/"
	# Keep the stock hook's synchronous success stall inside sysinit, adding
	# only a marker and an endless loop (the printer sleeps for 100000 s).
	git -C "$STOCK_ARCHIVE" show HEAD:software/app_startup.sh | tr -d '\r' |
		awk '/^CONTROL_DIR=/ { exit }
			/sleep 100000/ { sub(/sleep 100000/, "echo QEMU-STOCK-HOOK rc=0 stall; while :; do sleep 100000; done") }
			{ print }
			END { print "echo QEMU-STOCK-HOOK continue" }' > "$stage/qemu-app-startup.sh"
	grep -q 'QEMU-STOCK-HOOK rc=0 stall' "$stage/qemu-app-startup.sh" || { echo "fixture: app_startup.sh stall line not found" >&2; return 1; }
	grep -q '/mnt/runFirmwareExe.sh.*MACHINE.*PID' "$stage/qemu-app-startup.sh" ||
		{ echo "fixture: stock hook must pass MACHINE PID" >&2; return 1; }
	chmod 0755 "$stage/qemu-app-startup.sh"
	rm -f "$STOCK_SQFS"
	mksquashfs "$stage" "$STOCK_SQFS" -comp xz -all-root -noappend -quiet >/dev/null
	git -C "$STOCK_ARCHIVE" show "HEAD:kernel/ota_kernel_emmc/ota_v1/$(git -C "$STOCK_ARCHIVE" ls-tree --name-only HEAD kernel/ota_kernel_emmc/ota_v1/ | sed -n 's#.*/\(xImage\.[^/]*\)$#\1#p' | head -n 1)" > "$STOCK_KERNEL"
	[ "$(head -c 4 "$STOCK_KERNEL" | od -An -tx1 | tr -d ' ')" = 27051956 ] || { echo "fixture: stock xImage missing" >&2; return 1; }
	echo "$key" > "$STOCK_SQFS.key"
	rm -f "$BASE_DISK"
}

# Synthetic saved preferences, shared by stock-layout and repartitioned disks.
stock_network_fixture() {
	mkdir -p "$1/firmwareRes/config"
	cat > "$1/firmwareRes/config/network.json" <<'EOF'
/* Printer Network Config */
{
	"staticIpOpen" : true,
	"st_ipaddress" : "192.168.2.78",
	"st_netmask" : "255.255.255.0",
	"st_gateway" : "192.168.2.1",
	"st_dns" : "192.168.2.1",
	"wifiOpen" : true
}
EOF
}

# make_emmc_image IMG SECTORS QUIRK_LAST P7_LAST: eMMC image with the
# printer's GPT; stock in both slots (as after a stock OTA), flag on slot 2,
# usershare with a Wi-Fi config, empty userdata ending at P7_LAST. The
# primary header is patched like the printer's: last usable LBA = alternate
# LBA = QUIRK_LAST, protective MBR sized to QUIRK_LAST, no backup GPT (last
# 33 sectors zero). MBR boot code and the SPL area (LBA 34..2047) get a
# recognisable pattern so tests can prove a repartition keeps them.
make_emmc_image() {
	local d=$1 sectors=$2 quirk=$3 p7last=$4 st
	rm -f "$d"
	truncate -s $((sectors * 512)) "$d"
	sgdisk -o --resize-table=8 \
		-n 1:2048:18431 -c 1:kernel -n 2:18432:223231 -c 2:rootfs \
		-n 3:223232:239615 -c 3:kernel2 -n 4:239616:444415 -c 4:rootfs2 \
		-n 5:444416:446463 -c 5:ota -n 6:446464:2543615 -c 6:usershare \
		-n 7:2543616:"$p7last" -c 7:userdata \
		-t 1:0700 -t 2:0700 -t 3:0700 -t 4:0700 -t 5:0700 -t 6:0700 -t 7:0700 "$d" >/dev/null || return 1
	python3 - "$d" "$quirk" "$sectors" <<'EOF' || return 1
import struct, sys, zlib
path, quirk, sectors = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, 'r+b') as f:
    f.seek(512)
    h = bytearray(f.read(512))
    assert h[:8] == b'EFI PART'
    struct.pack_into('<Q', h, 32, quirk)   # alternate_lba
    struct.pack_into('<Q', h, 40, 34)      # first_usable_lba (sgdisk: 4 for 8 entries)
    struct.pack_into('<Q', h, 48, quirk)   # last_usable_lba
    size = struct.unpack_from('<I', h, 12)[0]
    struct.pack_into('<I', h, 16, 0)
    struct.pack_into('<I', h, 16, zlib.crc32(bytes(h[:size])) & 0xffffffff)
    f.seek(512)
    f.write(h)
    f.seek(0)
    mbr = bytearray(f.read(512))
    struct.pack_into('<I', mbr, 458, quirk)  # protective entry size_in_lba
    mbr[0:55] = bytes((0x5a + i) & 0xff for i in range(55))  # "boot code"
    f.seek(0)
    f.write(mbr)
    f.seek(34 * 512)
    f.write(bytes((i * 7 + 3) & 0xff or 1 for i in range((2048 - 34) * 512)))  # "SPL"
    f.seek((sectors - 33) * 512)
    f.write(bytes(33 * 512))
EOF
	for p in 1 3; do dd if="$STOCK_KERNEL" of="$d" bs=512 seek="${PSTART[$p]}" conv=notrunc status=none; done
	for p in 2 4; do dd if="$STOCK_SQFS" of="$d" bs=512 seek="${PSTART[$p]}" conv=notrunc status=none; done
	printf 'ota:kernel2\n' | dd of="$d" bs=512 seek="${PSTART[5]}" conv=notrunc,sync status=none
	st=$FIX/usershare-stage
	rm -rf "$st"
	mkdir -p "$st/wifi"
	# a printer that has booted once: stock copies /etc to /usr/prog/etc on
	# its first boot (app_startup.sh) and bind-mounts it on /etc afterwards
	cp -a "$FIX/stock-stage/etc" "$st/etc"
	cat > "$st/wifi/wpa_supplicant.conf" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	ssid="QEMU Test Net"
	psk="qemu-psk-'quoted'-123"
	key_mgmt=WPA-PSK
}
EOF
	MKE2FS_CONFIG=$FIX/stock-stage/etc/mke2fs.conf mkfs.ext4 -q -F -L usershare -d "$st" \
		-E offset="$(poff 6)" "$d" $((PSIZE[6] / 2))k || return 1
	st=$FIX/userdata-stage
	mkdir -p "$st"
	stock_network_fixture "$st"
	MKE2FS_CONFIG=$FIX/stock-stage/etc/mke2fs.conf mkfs.ext4 -q -F -L userdata -d "$st" \
		-E offset="$(poff 7)" "$d" $(((p7last + 1 - PSTART[7]) / 2))k
}

# 2 GiB stock-layout image (before the installer's repartition). Rebuilt
# when the image recipe changes.
build_base_disk() {
	local key
	key=$({ cat "$STOCK_SQFS.key"; declare -f make_emmc_image stock_network_fixture host_c5os_script build_c5os_disk; echo "$DISK_SECTORS $GPT_QUIRK_LAST ${PSTART[*]} ${PSIZE[*]}"; } | sha256sum | cut -c1-16)
	if [ -s "$BASE_DISK" ] && [ "$(cat "$BASE_DISK.key" 2>/dev/null)" = "$key" ]; then
		build_c5os_disk
		return
	fi
	echo "fixture: building the eMMC base image" >&2
	rm -f "$C5OS_DISK"
	make_emmc_image "$BASE_DISK.tmp" "$DISK_SECTORS" "$GPT_QUIRK_LAST" "$GPT_QUIRK_LAST" || return 1
	mv "$BASE_DISK.tmp" "$BASE_DISK"
	echo "$key" > "$BASE_DISK.key"
	build_c5os_disk
}

# host_c5os_script DISK C5OS_START C5OS_SIZE: the sfdisk script the
# installer's make_c5os writes (install.sh c5os_script): backup GPT at the
# disk end, p7 shrunk to end before C5OS_START, p8 c5os with p7's type.
host_c5os_script() {
	local disk=$1 start=$2 size=$3 sectors
	sectors=$(($(stat -c %s "$disk") / 512))
	sfdisk --dump "$disk" 2>/dev/null | awk -v last=$((sectors - 34)) -v start="$start" -v size="$size" -v dev="$disk" '
		/^(label|label-id|device|unit|first-lba|sector-size):/ { print; next }
		/^last-lba:/ { print "last-lba: " last; next }
		/^table-length:/ { tl = 1; print; next }
		/^[^ ]+ *: *start=/ {
			if (!tl) { print "table-length: 8"; tl = 1 }
			n++
			if (n == 7) {
				p7s = $0; sub(/.*start= */, "", p7s); sub(/,.*/, "", p7s)
				sub(/size= *[0-9]+/, "size=" (start - p7s))
				t = $0; sub(/.*type= */, "", t); sub(/,.*/, "", t); type = t
			}
			print; next
		}
		END { print dev "p8 : start=" start ", size=" size ", type=" type ", name=\"c5os\"" }'
}

# The base image after the installer's repartition (userdata shrunk, c5os).
build_c5os_disk() {
	local d=$C5OS_DISK.tmp
	[ -s "$C5OS_DISK" ] && return 0
	echo "fixture: building the repartitioned eMMC image" >&2
	cp --sparse=always "$BASE_DISK" "$d"
	host_c5os_script "$d" "${PSTART[8]}" "${PSIZE[8]}" > "$FIX/c5os.sfdisk"
	sfdisk -q --force "$d" < "$FIX/c5os.sfdisk" >/dev/null 2>&1 || { echo "fixture: sfdisk failed" >&2; return 1; }
	stock_network_fixture "$FIX/userdata-stage"
	MKE2FS_CONFIG=$FIX/stock-stage/etc/mke2fs.conf mkfs.ext4 -q -F -L userdata -d "$FIX/userdata-stage" \
		-E offset="$(poff 7)" "$d" $((PSIZE[7] / 2))k || return 1
	MKE2FS_CONFIG=$FIX/stock-stage/etc/mke2fs.conf mkfs.ext4 -q -F -L c5os \
		-E offset="$(poff 8)" "$d" $((PSIZE[8] / 2))k || return 1
	mv "$d" "$C5OS_DISK"
}

# OpenWrt root used by the tests: the build's root.squashfs, by default with
# the working tree's feed/x2600/base-files and the QEMU kernel's USB Ethernet
# modules laid over it (QEMU_REFRESH_ROOTFS=0 tests the build artifact
# unchanged).
build_openwrt_fixture() {
	local src=$OWRT_ART-root.squashfs key stage
	[ -s "$src" ] || return 1
	if [ "${QEMU_REFRESH_ROOTFS:-1}" = 0 ]; then
		key=artifact-$(stat -c %Y-%s "$src")
	else
		key=refresh-$(stat -c %Y-%s "$src")-${VMLINUX##*/}-$( { declare -f build_openwrt_fixture; cd "$QREPO/feed/x2600/base-files" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } | sha256sum | cut -c1-16)
	fi
	if [ -s "$OWRT_SQFS" ] && [ "$(cat "$OWRT_SQFS.key" 2>/dev/null)" = "$key" ]; then
		return 0
	fi
	rm -f "$OWRT_SQFS"
	if [ "${QEMU_REFRESH_ROOTFS:-1}" = 0 ]; then
		cp "$src" "$OWRT_SQFS"
	else
		echo "fixture: OpenWrt root + working-tree base-files" >&2
		stage=$FIX/openwrt-stage
		rm -rf "$stage"
		# device nodes cannot be created unprivileged; OpenWrt's image has
		# only /dev/console, recreated below as a pseudo file
		unsquashfs -q -n -d "$stage" "$src" >/dev/null 2>&1 || [ -x "$stage/sbin/procd" ] || return 1
		# Replace the target-owned namespace, not just Git's unstaged deletions:
		# an older artifact must refresh identically after staging or committing.
		rm -rf "$stage/lib/c5"
		rm -f "$stage"/lib/preinit/*c5* "$stage"/usr/libexec/c5* \
			"$stage"/usr/sbin/c5* "$stage"/etc/init.d/c5* \
			"$stage"/etc/uci-defaults/*c5*
		(cd "$QREPO/feed/x2600/base-files" && find . -type f -print0 | xargs -0 -I{} sh -c '
			mkdir -p "$(dirname "$1/$2")" && cp -f "$2" "$1/$2" && chmod "$(stat -c %a "$2")" "$1/$2"' _ "$stage" {})
		# git file modes (the F: checkout may show everything as 0777/0644)
		git -C "$QREPO" ls-files -s feed/x2600/base-files | while read -r mode _ _ path; do
			f=$stage/${path#feed/x2600/base-files/}
			[ -f "$f" ] || continue
			if [ "$mode" = 100755 ]; then chmod 0755 "$f"; else chmod 0644 "$f"; fi
		done
		chmod 0755 "$stage/etc/init.d/c5-usb-hook" "$stage/usr/libexec/c5-usb-hook"
		ln -sf ../init.d/c5-usb-hook "$stage/etc/rc.d/S19c5-usb-hook"
		for f in "$stage"/etc/rc.d/*c5*; do
			[ -e "$f" ] || rm -f "$f"
		done
		# the QEMU kernel's usbnet/cdc_ether (kernel/build.sh): the image's
		# kmod-usb-net autoload entries load them at boot (S16)
		mkdir -p "$stage/lib/modules/$KVER"
		cp "$VMLINUX.modules"/*.ko "$stage/lib/modules/$KVER/"
		mksquashfs "$stage" "$OWRT_SQFS" -noappend -all-root -quiet -comp xz -b 256k \
			-p '/dev/console c 600 0 0 5 1' >/dev/null
	fi
	echo "$key" > "$OWRT_SQFS.key"
}

# ---------------------------------------------------------------- sticks --

# make_payload OUTDIR [make-install-stick.sh options]: install payload from
# the OpenWrt fixture, with the fake c5-chainload.sh and re-made checksums.
make_payload() {
	local out=$1 vdir=$RUN/vdir/qemu-test
	shift
	rm -rf "$vdir" "$out"
	mkdir -p "$vdir"
	ln -s "$OWRT_SQFS" "$vdir/${OWRT_ART##*/}-root.squashfs"
	ln -s "$OWRT_ART-kernel.uimage" "$vdir/${OWRT_ART##*/}-kernel.uimage"
	ln -s "$OWRT_ART-sysupgrade.tar" "$vdir/${OWRT_ART##*/}-sysupgrade.tar"
	"$QREPO/tools/make-install-stick.sh" "$@" "$vdir" "$out" > "$RUN/make-install-stick.log" 2>&1 || return 1
	fake_chainload > "$out/chainload/c5-chainload.sh"
	chmod 0755 "$out/chainload/c5-chainload.sh"
	resum "$out"
}

# make_ui_payload OUTDIR "KEY=VALUE ..." [make-install-stick.sh options]:
# make_payload, with the stick hook replaced by fixtures/qemu-ui-hook.sh,
# which runs the installer with --ui against fixtures/fake-ui.sh configured
# by the given ui.conf settings (menu=N, menu_<id>=N, confirm_<id>=ok|early|cancel).
make_ui_payload() {
	local out=$1 conf=$2
	shift 2
	make_payload "$out" "$@" || return 1
	mkdir -p "$out/qemu"
	install -m 0755 "$QDIR/fixtures/fake-ui.sh" "$out/qemu/fake-ui.sh"
	printf '%s\n' $conf > "$out/qemu/ui.conf"
	install -m 0755 "$QDIR/fixtures/qemu-ui-hook.sh" "$out/runFirmwareExe.sh"
	resum "$out"
}

# fixtures/fake-c5-chainload.sh with the repo's chainload/c5-chainload.sh
# embedded as function c5cl_real (used for its "args" computation)
fake_chainload() {
	local f=$QDIR/fixtures/fake-c5-chainload.sh
	head -n 1 "$f"
	echo "c5cl_real() {"
	echo "cat <<'C5CL_REAL_EOF'"
	cat "$QREPO/chainload/c5-chainload.sh"
	echo "C5CL_REAL_EOF"
	echo "}"
	tail -n +2 "$f"
}

resum() { # DIR: recompute SHA256SUMS/MD5SUMS over the files they list
	local l
	l=$(awk '{ f = $2; sub(/^\*/, "", f); print f }' "$1/SHA256SUMS")
	(cd "$1" && printf '%s\n' "$l" | xargs -d '\n' sha256sum > SHA256SUMS.new &&
		printf '%s\n' "$l" | xargs -d '\n' md5sum > MD5SUMS.new &&
		mv SHA256SUMS.new SHA256SUMS && mv MD5SUMS.new MD5SUMS)
}

# make_stick DIR IMG [SIZE_MB]: FAT32 stick image (default 256 MiB), one MBR
# partition (/dev/sda1)
make_stick() {
	local img=$2 mb=${3:-256}
	rm -f "$img"
	truncate -s "${mb}M" "$img"
	echo '2048,,c' | sfdisk -q "$img" >/dev/null
	mkfs.vfat -F 32 -n C5STICK --offset 2048 "$img" $((mb * 1024 - 1024)) >/dev/null
	(cd "$1" && mcopy -s -m -i "$img@@1M" ./* ::/)
}
stick_cat() { mtype -i "$1@@1M" "::$2" 2>/dev/null; }

# --------------------------------------------------------------- booting --

# SPL emulator: the root device the Creator 5 Pro SPL would boot from DISK.
spl_root() {
	# the SPL compares the first 11 bytes with "ota:kernel2" (strncmp)
	if [ "$(img_bytes "$1" "$(poff 5)" 11 | tr -d '\000')" = "ota:kernel2" ]; then
		echo /dev/mmcblk0p4
	else
		echo /dev/mmcblk0p2
	fi
}

# boot NAME DISK ROOT STEPSFILE [STICKIMG] -> runs one QEMU boot; returns the
# driver's status. Console log: $RUN/NAME.log, command results: $RUN/NAME.res
# ROOT is a root device (SPL-style command line) or "cmdline:<full command
# line>" (what a chainload passes, see chainload_cmdline).
boot() {
	local name=$1 disk=$2 root=$3 steps=$4 stick=${5:-} extra='' rc cl
	local -a q
	BOOTN=$((BOOTN + 1))
	[ -n "$stick" ] && extra=' qemu_stick=1'
	case "$root" in
	cmdline:*) cl=${root#cmdline:} ;;
	# the X2600 kernel's built-in prefix ($X2600_CMDLINE: ieee754=relaxed, the
	# screen console) + the SPL's fixed command line (minus mem=/rmem=/lpj=,
	# which describe the X2600's memory map). Stock boots here carry the prefix
	# too, so a chainload line built from their /proc/cmdline has it once, as
	# the chainloaded X2600 kernel adds it in front of stock's line.
	*) cl="$X2600_CMDLINE console=ttyS0,115200n8 loglevel=8 init=/linuxrc root=$root rootwait rootfstype=squashfs ro$extra" ;;
	esac
	# User-mode networking provides the normal LAN/DHCP environment; boot
	# health itself depends only on reaching c5-booted with c5os mounted.
	# QEMU_USB_NIC=1 replaces the PCI NIC with a USB Ethernet adapter on xHCI
	# (usb-net, CDC Ethernet, globally administered MAC): as on the printer,
	# which has no Ethernet MAC, the adapter becomes eth0.
	# QEMU's sd-card reads and writes the image one 512-byte block at a time,
	# synchronously; io_uring makes each of those about twice as fast as the
	# default thread pool (S12's whole-eMMC backup is bound by it).
	q=(qemu-system-mipsel -M malta -cpu "$QEMU_CPU" -m "$QEMU_MEM" -kernel "$VMLINUX"
		-append "$cl"
		-display none -monitor none -serial stdio -no-reboot
		-drive "if=none,id=emmc,file=$disk,format=raw,aio=$QEMU_AIO"
		-device sdhci-pci -device sd-card,drive=emmc)
	if [ -n "$stick" ] || [ "${QEMU_USB_NIC:-0}" = 1 ]; then
		q+=(-device qemu-xhci,id=xhci)
	fi
	if [ "${QEMU_USB_NIC:-0}" = 1 ]; then
		q+=(-netdev user,id=usbnic,restrict=on -device usb-net,bus=xhci.0,netdev=usbnic,mac=00:16:3e:c5:00:01)
	else
		q+=(-nic user,model=pcnet,restrict=on)
	fi
	# the stick sits on xHCI: UHCI's ~1 MB/s is too slow for S12's backup
	[ -n "$stick" ] && q+=(-drive "if=none,id=stick,file=$stick,format=raw,aio=$QEMU_AIO"
		-device usb-storage,bus=xhci.0,drive=stick)
	say "boot $BOOTN '$name': $(echo "$cl" | grep -o 'root=[^ ]*')$(echo " $cl" | grep -o ' c5\.[^ ]*' | tr -d '\n') flag='$(img_flag "$disk")'${stick:+ stick=${stick##*/}}$([ "${QEMU_USB_NIC:-0}" = 1 ] && echo ' usb-nic')"
	: > "$RUN/$name.res"
	: > "$RUN/$name.log"
	python3 "$QDIR/lib/qemu-run.py" --log "$RUN/$name.log" --results "$RUN/$name.res" \
		--steps "$steps" --timeout "${QEMU_BOOT_TIMEOUT:-900}" -- "${q[@]}" 2>> "$RUN/scenario.log"
	rc=$?
	if [ "$rc" != 0 ]; then
		say "  boot '$name' driver failed (rc=$rc): $(grep -A1 '^== FAIL' "$RUN/$name.res" | tail -n 1)"
		FAILS=$((FAILS + 1))
	fi
	return "$rc"
}

# Hash the entire userdata partition, including its ext4 journal, around one
# real OpenWrt run. boot() waits for QEMU to exit, so the second hash is taken
# before any later stock boot can legitimately update userdata's journal.
boot_openwrt() {
	local name=$1 disk=$2 before after rc
	before=$(img_part_sum "$disk" 7 $((PSIZE[7] * 512)))
	boot "$@"
	rc=$?
	after=$(img_part_sum "$disk" 7 $((PSIZE[7] * 512)))
	printf 'before %s\nafter  %s\n' "$before" "$after" > "$RUN/$name.userdata.sha256"
	check "$name: full userdata partition unchanged by OpenWrt" is_eq "$after" "$before"
	return "$rc"
}

# chainload_cmdline NAME -> "cmdline:<command line>" the fake chainload of
# boot NAME handed over (for boot's ROOT argument)
chainload_cmdline() {
	local c
	c=$(sed -n 's/^QEMU-CHAINLOAD root=[^ ]* cmdline=//p' "$RUN/$1.log" | tail -n 1)
	[ -n "$c" ] && echo "cmdline:$c"
}

# result of a "run" step: res_rc NAME.res CMDNAME / res_out NAME.res CMDNAME
res_rc() { sed -n "s/^== $2 rc=\([0-9]*\)$/\1/p" "$1" | tail -n 1; }
res_out() { awk -v n="== $2 rc=" 'index($0, n) == 1 { on = 1; next } /^== / { on = 0 } on' "$1"; }

# log grep helpers for checks
log_has() { grep -qE -- "$2" "$RUN/$1.log"; }
log_lacks() { ! grep -qE -- "$2" "$RUN/$1.log"; }
