# shellcheck shell=bash
# QEMU system-test scenarios. Each scenario_* function runs in its own
# directory $RUN with a fresh copy of the eMMC image, records checks with
# check(), and returns 0 (ran; FAILS says whether checks failed) or 77 (SKIP,
# reason in SKIP_WHY). Sourced by test/qemu/run.sh after harness.sh.

STOCK_SLOT_ROOT=/dev/mmcblk0p4
OWRT_ROOT=/dev/mmcblk0p2

# ------------------------------------------------------------------ steps --

# A stock boot: wait for the end of the test init (or a fake chainload jump,
# which happens inside the hook) and for QEMU to exit.
steps_stock() {
	cat > "$1" <<'EOF'
expect 400 ^(QEMU-STOCK-DONE|QEMU-CHAINLOAD root=)|reboot: Restarting system
wait-exit 240
EOF
}

# An OpenWrt boot that should complete: get a shell, wait for c5-booted, run
# the standard probes plus any extra "run" lines from stdin, power off.
steps_openwrt() {
	{
		cat <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -qE 'c5: booted: (slot [12] healthy|chainloaded kernel|NOT healthy|root )'; do i=$((i+1)); [ $i -lt 600 ] || exit 1; sleep 1; done; dmesg | grep 'c5: '
run 30 uname uname -r
run 30 cmdline cat /proc/cmdline
run 30 mounts cat /proc/mounts
run 30 dropbear pidof dropbear
run 30 float awk 'BEGIN { print 1.5 * 2 }'
EOF
		cat
		cat <<'EOF'
send sync; poweroff
wait-exit 240
EOF
	} > "$1"
}

# ---------------------------------------------------------------- outcome --

# boot_outcome NAME -> chainload:<root> | reboot | poweroff | panic | other
boot_outcome() {
	local l=$RUN/$1.log r
	r=$(sed -n 's/^QEMU-CHAINLOAD root=\([^ ]*\).*/\1/p' "$l" | tail -n 1)
	if [ -n "$r" ]; then echo "chainload:$r"
	elif grep -q 'Kernel panic' "$l"; then echo panic
	elif grep -q 'reboot: Restarting system' "$l"; then echo reboot
	elif grep -q 'reboot: Power down' "$l"; then echo poweroff
	else echo other; fi
}

res_has() { res_out "$RUN/$1.res" "$2" | grep -qE -- "$3"; }
res_ok() { [ "$(res_rc "$RUN/$1.res" "$2")" = 0 ]; }
is_eq() { [ "$1" = "$2" ] || { echo "expected '$2', got '$1'"; return 1; }; }
not_eq() { [ "$1" != "$2" ] || { echo "both '$1'"; return 1; }; }

# new_disk: the image as the installer leaves it after its repartition
# (userdata shrunk, c5os p8); new_stock_disk: the stock layout before it
new_disk() { cp --sparse=always "$C5OS_DISK" "$RUN/disk.img"; DISK=$RUN/disk.img; }
new_stock_disk() { cp --sparse=always "$BASE_DISK" "$RUN/disk.img"; DISK=$RUN/disk.img; }

# remember checksums of the stock state for later comparisons
remember_base() {
	BASE_P1=$(img_part_sum "$BASE_DISK" 1 $((PSIZE[1] * 512)))
	BASE_P2=$(img_part_sum "$BASE_DISK" 2 $((PSIZE[2] * 512)))
	BASE_P3=$(img_part_sum "$BASE_DISK" 3 $((PSIZE[3] * 512)))
	BASE_P4=$(img_part_sum "$BASE_DISK" 4 $((PSIZE[4] * 512)))
	# the installer saves squashfs bytes_used, not mksquashfs' 4 KiB padding
	STOCK_SQ_LEN=$(squashfs_used "$STOCK_SQFS")
	STOCK_SQ_SUM=$(head -c "$STOCK_SQ_LEN" "$STOCK_SQFS" | sha256sum | cut -d' ' -f1)
	OW_SQ_SUM=$(sha256sum < "$OWRT_SQFS" | cut -d' ' -f1)
	OW_SQ_LEN=$(stat -c %s "$OWRT_SQFS")
	OW_K=$OWRT_ART-kernel.uimage
	OW_K_SUM=$(sha256sum < "$OW_K" | cut -d' ' -f1)
	OW_K_LEN=$(stat -c %s "$OW_K")
}

# ------------------------------------------------------------ shared flows --

# Stock boot with a default install stick: OpenWrt written to slot 1.
flow_install() { # NAME [make-install-stick options]
	local name=$1 st
	shift
	make_payload "$RUN/payload-$name" "$@" || { fatal "make-install-stick.sh failed: $(tail -n 2 "$RUN/make-install-stick.log" | tr "\n" " ")"; return 1; }
	make_stick "$RUN/payload-$name" "$RUN/stick-$name.img"
	st=$RUN/$name.steps
	steps_stock "$st"
	boot "$name" "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-$name.img"
}

# OpenWrt installed with a default stick (first install: chainload test) and
# committed by its first (chainloaded) boot. Cached per run in
# $RUNROOT/committed.img (S2 leaves its image there). Parallel scenarios
# take a lock: one builds the image, the others wait and copy it.
prepare_committed() {
	local lk rc
	exec {lk}> "$RUNROOT/committed.lock"
	flock "$lk"
	prepare_committed_locked
	rc=$?
	exec {lk}>&-
	return "$rc"
}
prepare_committed_locked() {
	local c=$RUNROOT/committed.img st
	if [ -s "$c" ]; then
		cp --sparse=always "$c" "$DISK"
		say "setup: copied the committed OpenWrt image from an earlier scenario"
		return 0
	fi
	say "setup: install and commit (stock boot + chainloaded OpenWrt boot)"
	flow_install setup-install || return 1
	[ "$(boot_outcome setup-install)" = "chainload:$OWRT_ROOT" ] ||
		{ fatal "setup: no chainload to $OWRT_ROOT (outcome $(boot_outcome setup-install))"; return 1; }
	st=$RUN/setup-openwrt.steps
	steps_openwrt "$st" < /dev/null
	boot setup-openwrt "$DISK" "$(chainload_cmdline setup-install)" "$st" || return 1
	[ "$(img_flag "$DISK")" = ota:kernel ] || { fatal "setup: first boot did not commit (flag '$(img_flag "$DISK")')"; return 1; }
	cp --sparse=always "$DISK" "$c.tmp" && mv "$c.tmp" "$c"
}

# ------------------------------------------------------------- scenarios --

# S1: default (headless) install from the stock USB hook; no good kernel yet,
# so it ends in a chainload test boot of slot 1. Then the test kernel
# "hangs": the watchdog reset boots stock, whose run of the stick reports it.
scenario_S1() {
	new_disk
	flow_install s1-stock || return 0
	local ow=/opencreator-os used off
	check "installer reported success" log_has s1-stock 'install: OK; slot 1 written and verified'
	check "plan: chainload test boot afterwards" log_has s1-stock 'check: afterwards: chainload test boot \(root=/dev/mmcblk0p2\)'
	check "boot ended in the chainload jump to slot 1" is_eq "$(boot_outcome s1-stock)" "chainload:$OWRT_ROOT"
	check "boot flag unchanged ('ota:kernel2\\n')" is_eq "$(img_flag_hex "$DISK")" "$(img_flag_hex "$BASE_DISK")"
	check "p1 kernel = kernel.uimage" is_eq "$(img_part_sum "$DISK" 1 "$OW_K_LEN")" "$OW_K_SUM"
	check "p2 rootfs = root.squashfs" is_eq "$(img_part_sum "$DISK" 2 "$OW_SQ_LEN")" "$OW_SQ_SUM"
	used=$(squashfs_used "$OWRT_SQFS")
	off=$(((used + 65535) / 65536 * 65536))
	check "overlay header after the squashfs cleared (4 KiB of zeros)" is_eq "$(img_bytes "$DISK" $(($(poff 2) + off)) 4096 | tr -d '\000' | wc -c)" 0
	check "p3/p4 (running stock slot) untouched" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 $((PSIZE[4] * 512)))" "$BASE_P3$BASE_P4"
	check "saved stock kernel.img = whole p3" is_eq "$(data_cat "$DISK" $ow/stock/kernel.img | sha256sum | cut -d' ' -f1)" "$BASE_P3"
	check "saved stock rootfs.squashfs = stock squashfs (bytes_used)" is_eq "$(data_cat "$DISK" $ow/stock/rootfs.squashfs | sha256sum | cut -d' ' -f1)" "$STOCK_SQ_SUM"
	check "stock SHA256SUMS lists both images" bash -c "[ \"\$(debugfs -R 'cat $ow/stock/SHA256SUMS' '$(userdata_spec "$DISK")' 2>/dev/null | awk '{print \$2}' | tr '\n' ' ')\" = 'kernel.img rootfs.squashfs ' ]"
	check "stock MANIFEST.txt records slot 2" bash -c "debugfs -R 'cat $ow/stock/MANIFEST.txt' '$(userdata_spec "$DISK")' 2>/dev/null | grep -qx 'slot: 2'"
	check "wifi.conf saved on c5os from usershare" is_eq "$(c5os_cat "$DISK" $ow/wifi.conf)" "# from stock wpa_supplicant.conf (wifi_conf)
SSID='QEMU Test Net'
PSK='qemu-psk-'\\''quoted'\\''-123'"
	check "install.state = written slot=1" bash -c "debugfs -R 'cat $ow/install.state' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^written slot=1 kernel=/dev/mmcblk0p1 rootfs=/dev/mmcblk0p2 '"
	check "chainload files copied to userdata" bash -c "for f in chainload.ko c5-chainload.sh kernel.uimage; do debugfs -R \"stat $ow/chainload/\$f\" '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^Inode:' || exit 1; done"
	check "chainload kernel = slot 1's uImage" is_eq "$(data_cat "$DISK" $ow/chainload/kernel.uimage | sha256sum | cut -d' ' -f1)" "$OW_K_SUM"
	check "install log on the stick ends with the jump" bash -c "mtype -i '$RUN/stick-s1-stock.img@@1M' ::opencreator-os-install.log | grep -q 'chainload: staged; jumping into OpenWrt'"
	check "hook model stored on c5os" is_eq "$(c5os_cat "$DISK" $ow/model)" "Creator5Pro 0029"
	check "credentials not copied to userdata" bash -c "! debugfs -R 'stat $ow/wifi.conf' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	check "first install has matching pending commit" is_eq "$(c5os_cat "$DISK" $ow/pending-commit)" "slot=1"
	check "last-test: started before the jump" is_eq "$(c5os_cat "$DISK" $ow/last-test)" "started qemu-test"

	# the fake jump powered off without booting anything: what a hung test
	# kernel leaves after the watchdog reset; the SPL boots stock
	steps_stock "$RUN/s1-hang.steps"
	boot s1-hang "$DISK" "$(spl_root "$DISK")" "$RUN/s1-hang.steps" "$RUN/stick-s1-stock.img"
	check "hang: next stock run reports it" log_has s1-hang '^test: the OpenWrt test boot \(qemu-test\) failed: hung before OpenWrt started \(watchdog reset\); stock is unchanged'
	check "hang: report in the stick log" bash -c "mtype -i '$RUN/stick-s1-stock.img@@1M' ::opencreator-os-install.log | grep -q 'hung before OpenWrt started'"
	check "hang: reported once (last-test.seen)" is_eq "$(c5os_cat "$DISK" $ow/last-test.seen):$(c5os_has "$DISK" $ow/last-test && echo left)" "started qemu-test:"
	check "hang: headless stick does not retry" log_has s1-hang 'switch: this stick already started OpenWrt in slot 1'
	check "hang: stock boots on, flag on stock" is_eq "$(grep -c '^QEMU-STOCK-HOOK continue' "$RUN/s1-hang.log"):$(img_flag "$DISK")" "1:ota:kernel2"
}

# S2: default install -> fake jump -> OpenWrt from p2 with the stick still
# in, committed; the deferred USB hook then reports the install (headless).
scenario_S2() {
	new_disk
	flow_install s2-stock || return 0
	check "stock hook staged and jumped to root=$OWRT_ROOT" is_eq "$(boot_outcome s2-stock)" "chainload:$OWRT_ROOT"
	check "chainload staged slot 1's own kernel (no c5.nocommit)" log_lacks s2-stock '^QEMU-CHAINLOAD .*c5\.nocommit=1'
	check "boot flag still ota:kernel2 after the install" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "install.state records the chainload request" bash -c "debugfs -R 'cat /opencreator-os/install.state' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^chainload slot=1 key='"

	local st=$RUN/s2-openwrt.steps
	steps_openwrt "$st" <<'EOF'
run 30 wificonf cat /etc/c5/wifi.conf
run 30 fstab uci -q get fstab.data.label; uci -q get fstab.data.target
run 30 hostname uci -q get system.@system[0].hostname
run 30 logs ls /data/opencreator-os/logs/
run 30 overlay mount | grep -E ' on /overlay | on / '
run 30 deadline ps w | grep '[c]5_test_deadline'
run 300 hook i=0; until [ -f /data/opencreator-os/last-test.seen ]; do i=$((i+1)); [ $i -lt 300 ] || exit 1; sleep 1; done; cat /data/opencreator-os/last-test.seen; logread | grep -E 'c5-usb-hook|test: '
EOF
	boot s2-openwrt "$DISK" "$(chainload_cmdline s2-stock)" "$st" "$RUN/stick-s2-stock.img"
	check "OpenWrt shell reached and c5-booted ran" res_has s2-openwrt waitboot 'c5: booted:'
	check "preinit: test boot not counted, deadline armed" res_has s2-openwrt waitboot 'c5: bootcount: slot 1 test boot; counter and flag untouched; healthy within 180 s or back to stock'
	check "deadline job from preinit still runs after c5-booted" res_ok s2-openwrt deadline
	check "c5-booted committed slot 1" res_has s2-openwrt waitboot 'c5: booted: .*flag -> slot 1 \(OpenWrt\)'
	check "flag is now ota:kernel" is_eq "$(img_flag "$DISK")" ota:kernel
	check "healthy boot reset tries" is_eq "$(img_tries "$DISK")" "C5TRIES1 0"
	check "USB hook deferred at START=19 on the test boot" res_has s2-openwrt hook 'c5-usb-hook.*deferred until c5-booted'
	check "c5-booted recorded last-test ok; the deferred hook's installer reported it" res_has s2-openwrt hook '^ok [^ ]+$'
	check "the detached hook's installer output goes to syslog" res_has s2-openwrt hook 'c5-usb-hook: test: OpenWrt .* installed'
	check "installed report in the stick log (headless)" bash -c "mtype -i '$RUN/stick-s2-stock.img@@1M' ::opencreator-os-install.log | grep -q 'test: OpenWrt .* installed: the test boot succeeded and slot 1 is the boot system (no display)'"
	check "last-test consumed" bash -c "! debugfs -R 'stat /opencreator-os/last-test' '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	check "healthy kernel checksum saved on c5os" is_eq "$(c5os_cat "$DISK" /opencreator-os/good-kernel)" "$OW_K_SUM"
	check "hostname derived from hook model" res_has s2-openwrt hostname '^creator5pro$'
	check "bootlog records healthy boot" bash -c "printf '%s' \"\$1\" | grep -q 'booted: slot 1 healthy; good kernel recorded'" _ "$(img_bootlog "$DISK")"
	check "bootlog order: bootcount before booted" bash -c "printf '%s\n' \"\$1\" | awk '/bootcount: slot 1 test boot/{t=NR} /booted: .*flag -> slot 1/{b=NR} END{exit !(t && b && t < b)}'" _ "$(img_bootlog "$DISK")"
	check "/rom is the squashfs root, / the overlay" res_has s2-openwrt mounts "^overlayfs:/overlay / overlay "
	check "/overlay is ext4 on a loop device" res_has s2-openwrt mounts '^/dev/loop[0-9]+ /overlay ext4'
	check "/data = c5os (mmcblk0p8)" res_has s2-openwrt mounts '^/dev/mmcblk0p8 /data ext4'
	check "fixed fstab selects c5os label at /data" bash -c "[ \"\$(printf '%s\n' \"\$1\" | tr -d '\r' | tr '\n' ' ')\" = 'c5os /data ' ]" _ "$(res_out "$RUN/s2-openwrt.res" fstab)"
	check "wifi.conf imported to /etc/c5/wifi.conf" res_has s2-openwrt wificonf "^SSID='QEMU Test Net'"
	check "dropbear running" res_ok s2-openwrt dropbear
	check "hard-float userland works (awk 1.5*2 = 3)" res_has s2-openwrt float '^3$'
	check "overlay (rootfs_data) is ext4 after the squashfs on p2" overlay_is_ext4 "$DISK" 2
	check "wifi.conf persisted in the overlay upper dir" bash -c "debugfs -R 'cat /upper/etc/c5/wifi.conf' '$(overlay_spec "$DISK" 2)' 2>/dev/null | grep -q '^SSID='"
	check "logs written to c5os opencreator-os/logs" bash -c "for f in dmesg-last.txt logread-last.txt bootlog-last.txt; do debugfs -R \"stat /opencreator-os/logs/\$f\" '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:' || exit 1; done"
	# run.sh starts the scenarios that use prepare_committed after S2
	if [ "$FAILS" = 0 ] && [ ! -s "$RUNROOT/committed.img" ]; then
		cp --sparse=always "$DISK" "$RUNROOT/committed.img.s2" && mv "$RUNROOT/committed.img.s2" "$RUNROOT/committed.img"
	fi
}

# S3: normal SPL boots count failures without rewriting the flag; health
# resets the counter and the overlay survives the next boot.
scenario_S3() {
	new_disk
	prepare_committed || return 0
	check "SPL emulator picks p2 for ota:kernel" is_eq "$(spl_root "$DISK")" "$OWRT_ROOT"
	printf 'C5TRIES1 2\n' | dd of="$DISK" bs=512 seek=$((PSTART[5] + 384)) conv=sync,notrunc status=none
	local st=$RUN/s3-a.steps token
	steps_openwrt "$st" <<'EOF'
run 30 persist echo qemu-persist-$$ > /etc/qemu-persist; sync; cat /etc/qemu-persist
run 30 fstab uci -q get fstab.data.label
EOF
	boot s3-a "$DISK" "$(spl_root "$DISK")" "$st"
	check "boot 1: third attempt retains OpenWrt" res_has s3-a waitboot 'bootcount: slot 1 booting; tries=3/3; flag untouched'
	check "boot 1: fixed label resolves to /data" res_has s3-a mounts '^/dev/mmcblk0p8 /data ext4'
	check "boot 1: healthy without a pending commit" res_has s3-a waitboot 'booted: slot 1 healthy; good kernel recorded'
	check "boot 1: no redundant flag commit" log_lacks s3-a 'booted: committed'
	check "boot 1: counter reset" is_eq "$(img_tries "$DISK")" "C5TRIES1 0"
	check "boot 1: flag unchanged" is_eq "$(img_flag "$DISK")" ota:kernel
	token=$(res_out "$RUN/s3-a.res" persist | tail -n 1)
	st=$RUN/s3-b.steps
	steps_openwrt "$st" <<'EOF'
run 30 persist cat /etc/qemu-persist
EOF
	boot s3-b "$DISK" "$(spl_root "$DISK")" "$st"
	check "boot 2: persisted file survives" is_eq "$(res_out "$RUN/s3-b.res" persist | tail -n 1)" "$token"
	check "boot 2: starts counting at one again" res_has s3-b waitboot 'bootcount: slot 1 booting; tries=1/3'
	check "boot 2: health resets counter" is_eq "$(img_tries "$DISK")" "C5TRIES1 0"
	check "boot 2: flag unchanged" is_eq "$(img_flag "$DISK")" ota:kernel
}

# S4: kill after preinit three times; fourth preinit selects stock. Invalid
# stock blocks fallback even after the limit; a healthy boot still resets tries.
scenario_S4() {
	new_disk
	prepare_committed || return 0
	local st n
	for n in 1 2 3; do
		st=$RUN/s4-fail-$n.steps
		printf 'kill-when 400 c5: bootcount: slot 1 booting; tries=%s/3; flag untouched\n' "$n" > "$st"
		boot "s4-fail-$n" "$DISK" "$(spl_root "$DISK")" "$st"
		check "failed boot $n counts after preinit" is_eq "$(img_tries "$DISK")" "C5TRIES1 $n"
		check "failed boot $n keeps OpenWrt selected" is_eq "$(img_flag "$DISK")" ota:kernel
	done
	st=$RUN/s4-fallback.steps
	printf 'expect 400 c5: bootcount: slot 1 failed 3 boots; flag -> slot 2 \\(stock\\); rebooting\nwait-exit 240\n' > "$st"
	boot s4-fallback "$DISK" "$(spl_root "$DISK")" "$st"
	check "fourth preinit reboots into stock" is_eq "$(boot_outcome s4-fallback):$(img_flag "$DISK")" reboot:ota:kernel2
	check "fallback resets counter" is_eq "$(img_tries "$DISK")" "C5TRIES1 0"
	check "fallback records last-test on c5os" bash -c "printf '%s\n' \"\$1\" | grep -qxE 'failed [^ ]+ boot counter: 3 boots of slot 1 did not become healthy'" _ "$(c5os_cat "$DISK" /opencreator-os/last-test)"
	make_payload "$RUN/payload-s4" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s4" "$RUN/stick-s4.img"
	steps_stock "$RUN/s4-stock.steps"
	boot s4-stock "$DISK" "$(spl_root "$DISK")" "$RUN/s4-stock.steps" "$RUN/stick-s4.img"
	check "stock boots after three failed OpenWrt boots" log_has s4-stock '^QEMU-STOCK-DONE flag=ota:kernel2'
	check "stock run of the stick reports the counter fallback" log_has s4-stock '^test: the OpenWrt test boot \([^)]+\) failed: boot counter: 3 boots of slot 1 did not become healthy; stock is unchanged'
	check "counter report shown once (last-test.seen)" c5os_has "$DISK" /opencreator-os/last-test.seen

	new_disk
	prepare_committed || return 0
	printf 'C5TRIES1 3\n' | dd of="$DISK" bs=512 seek=$((PSTART[5] + 384)) conv=sync,notrunc status=none
	printf 'C5STOCKINVALID1 slot' | dd of="$DISK" bs=512 seek=$((PSTART[5] + 256)) conv=sync,notrunc status=none
	st=$RUN/s4-blocked.steps
	echo 'kill-when 400 c5: bootcount: slot 1 booting; tries=4; .*NO fallback' > "$st"
	boot s4-blocked "$DISK" "$(spl_root "$DISK")" "$st"
	check "unselectable stock never gets the flag" is_eq "$(img_flag "$DISK")" ota:kernel
	check "blocked fourth attempt still counts" is_eq "$(img_tries "$DISK")" "C5TRIES1 4"
	steps_openwrt "$RUN/s4-healthy.steps" < /dev/null
	boot s4-healthy "$DISK" "$(spl_root "$DISK")" "$RUN/s4-healthy.steps"
	check "healthy blocked-fallback boot resets counter" is_eq "$(img_tries "$DISK")" "C5TRIES1 0"
	check "healthy boot retains OpenWrt" is_eq "$(img_flag "$DISK")" ota:kernel
}

# Build a second sysupgrade.tar: root = test root + /etc/qemu-test-version,
# kernel and fwtool metadata from the build's sysupgrade.tar.
make_sysupgrade_v2() { # OUT [changed-kernel]
	local out=$1 w=$RUN/su fw=$OWRT_DIR/staging_dir/host/bin/fwtool dir
	[ -x "$fw" ] || { echo "no $fw"; return 1; }
	rm -rf "$w"
	mkdir -p "$w/x" "$w/root"
	cp "$OWRT_ART-sysupgrade.tar" "$w/orig.tar"
	"$fw" -q -i "$w/meta.json" "$w/orig.tar" || { echo "no metadata in sysupgrade.tar"; return 1; }
	"$fw" -q -t -i /dev/null "$w/orig.tar"
	tar -xf "$w/orig.tar" -C "$w/x"
	dir=$(cd "$w/x" && ls -d sysupgrade-*)
	[ -f "$w/x/$dir/root" ] && [ -f "$w/x/$dir/kernel" ] || { echo "unexpected tar layout"; return 1; }
	if [ "${2:-}" = changed-kernel ]; then
		# A different, valid uImage header (timestamp + corrected header CRC),
		# with the same payload. QEMU executes its own malta kernel.
		python3 - "$w/x/$dir/kernel" <<'EOF' || return 1
import struct, sys, zlib
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
struct.pack_into(">I", b, 8, struct.unpack_from(">I", b, 8)[0] ^ 1)
struct.pack_into(">I", b, 4, 0)
struct.pack_into(">I", b, 4, zlib.crc32(b[:64]) & 0xffffffff)
open(p, "wb").write(b)
EOF
	fi
	unsquashfs -q -n -d "$w/root/r" "$OWRT_SQFS" >/dev/null 2>&1 || [ -x "$w/root/r/sbin/procd" ] || return 1
	echo "qemu-v2-$RUNID" > "$w/root/r/etc/qemu-test-version"
	rm -f "$w/x/$dir/root"
	mksquashfs "$w/root/r" "$w/x/$dir/root" -noappend -all-root -quiet -comp xz -b 256k \
		-p '/dev/console c 600 0 0 5 1' >/dev/null || return 1
	(cd "$w/x" && tar -c --owner=0 --group=0 --numeric-owner --sort=name -f "$out" "$dir")
	"$fw" -q -I "$w/meta.json" "$out"
	cp "$w/x/$dir/root" "$RUN/v2-root.squashfs"
	cp "$w/x/$dir/kernel" "$RUN/v2-kernel.uimage"
}

# S5: known-good direct upgrade, changed-kernel test/commit, garbage and cut.
scenario_S5() {
	new_disk
	prepare_committed || return 0
	make_sysupgrade_v2 "$RUN/v2.tar" > "$RUN/su.log" 2>&1 || { fatal "building the v2 sysupgrade.tar failed: $(tail -n 3 "$RUN/su.log")"; return 0; }
	c5os_mkdir "$DISK" /qemu
	c5os_put "$DISK" "$RUN/v2.tar" /qemu/v2.tar
	local v2sum v2len v2ksum st
	st=$RUN/s5-direct.steps
	cat > "$st" <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 600 ] || break; sleep 1; done
run 60 copy cp /data/qemu/v2.tar /tmp/v2.tar && sysupgrade -T /tmp/v2.tar
send sysupgrade -v /tmp/v2.tar
wait-exit 900
EOF
	boot s5-direct "$DISK" "$(spl_root "$DISK")" "$st"
	check "same-kernel sysupgrade reboots" is_eq "$(boot_outcome s5-direct)" reboot
	check "known-good direct upgrade retains OpenWrt flag" is_eq "$(img_flag "$DISK")" ota:kernel
	check "known-good direct upgrade has no pending commit" bash -c "! debugfs -R 'stat /opencreator-os/pending-commit' '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	check "bootlog identifies known-good direct path" bash -c "printf '%s' \"\$1\" | grep -q 'known-good kernel; flag stays on OpenWrt'" _ "$(img_bootlog "$DISK")"
	steps_openwrt "$RUN/s5-direct-next.steps" <<'EOF'
run 30 version cat /etc/qemu-test-version
EOF
	boot s5-direct-next "$DISK" "$(spl_root "$DISK")" "$RUN/s5-direct-next.steps"
	check "same-kernel upgraded root boots directly" res_has s5-direct-next version '^qemu-v2-'
	check "same-kernel healthy boot resets counter" is_eq "$(img_tries "$DISK")" "C5TRIES1 0"

	new_disk
	prepare_committed || return 0
	make_sysupgrade_v2 "$RUN/v2.tar" changed-kernel > "$RUN/su-changed.log" 2>&1 || { fatal "building changed-kernel sysupgrade failed"; return 0; }
	c5os_mkdir "$DISK" /qemu
	check "copy changed-kernel sysupgrade into c5os" c5os_put "$DISK" "$RUN/v2.tar" /qemu/v2.tar
	v2sum=$(sha256sum < "$RUN/v2-root.squashfs" | cut -d' ' -f1)
	v2len=$(stat -c %s "$RUN/v2-root.squashfs")
	v2ksum=$(sha256sum < "$RUN/v2-kernel.uimage" | cut -d' ' -f1)

	st=$RUN/s5-a.steps
	cat > "$st" <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 600 ] || break; sleep 1; done; dmesg | grep 'c5: '
run 30 board cat /tmp/sysinfo/board_name
run 30 hostname uci set system.@system[0].hostname=c5test && uci commit system && uci get system.@system[0].hostname
run 30 wifi printf "SSID='S5 Edited'\nPSK='s5-edited-123'\n" > /etc/c5/wifi.conf && cat /etc/c5/wifi.conf
run 30 before head -c 11 /dev/mmcblk0p5 | tr -d '\000'; echo; head -c 1048576 /dev/mmcblk0p2 | sha256sum
run 120 garbage dd if=/dev/urandom of=/tmp/garbage.bin bs=1k count=64 2>/dev/null; sysupgrade -v /tmp/garbage.bin; echo "sysupgrade-rc=$?"
run 30 after head -c 11 /dev/mmcblk0p5 | tr -d '\000'; echo; head -c 1048576 /dev/mmcblk0p2 | sha256sum
run 60 copy cp /data/qemu/v2.tar /tmp/v2.tar && sysupgrade -T /tmp/v2.tar; echo "test-rc=$?"
send sysupgrade -v /tmp/v2.tar
wait-exit 900
EOF
	boot s5-a "$DISK" "$(spl_root "$DISK")" "$st"
	check "garbage image refused" res_has s5-a garbage 'sysupgrade-rc=[1-9]'
	check "nothing written by the refused upgrade (flag, p2 head)" is_eq "$(res_out "$RUN/s5-a.res" after)" "$(res_out "$RUN/s5-a.res" before)"
	check "v2 image passes sysupgrade -T" res_has s5-a copy 'test-rc=0'
	check "sysupgrade ended in a reboot" is_eq "$(boot_outcome s5-a)" reboot
	check "p2 = v2 root" is_eq "$(img_part_sum "$DISK" 2 "$v2len")" "$v2sum"
	check "p1 = changed kernel" is_eq "$(img_part_sum "$DISK" 1 "$OW_K_LEN")" "$v2ksum"
	check "flag left on stock (ota:kernel2) until a test boot commits" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "pending-commit marker for slot 1 (c5os)" bash -c "debugfs -R 'cat /opencreator-os/pending-commit' '$(c5os_spec "$DISK")' 2>/dev/null | grep -qx 'slot=1'"
	check "chainload/kernel.uimage = changed kernel" is_eq "$(data_cat "$DISK" /opencreator-os/chainload/kernel.uimage | sha256sum | cut -d' ' -f1)" "$v2ksum"
	check "config saved to c5os (sysupgrade.tgz)" c5os_has "$DISK" /opencreator-os/sysupgrade.tgz
	check "bootlog: written and verified, flag stays on stock" bash -c "printf '%s' \"\$1\" | grep -q 'sysupgrade: slot 1 written and verified; flag stays on stock'" _ "$(img_bootlog "$DISK")"
	check "SPL emulator now picks stock" is_eq "$(spl_root "$DISK")" "$STOCK_SLOT_ROOT"

	# stock boots; over "SSH" the user test-boots slot 1 with chainload
	cat > "$RUN/action.sh" <<'EOF'
sh /usr/data/opencreator-os/chainload/c5-chainload.sh stage /dev/mmcblk0p2 && sh /usr/data/opencreator-os/chainload/c5-chainload.sh go
EOF
	data_put "$DISK" "$RUN/action.sh" /qemu-action.sh
	st=$RUN/s5-b.steps
	steps_stock "$st"
	boot s5-b "$DISK" "$(spl_root "$DISK")" "$st"
	check "stock booted and chainloaded slot 1" is_eq "$(boot_outcome s5-b)" "chainload:$OWRT_ROOT"
	st=$RUN/s5-c.steps
	steps_openwrt "$st" <<'EOF'
run 30 version cat /etc/qemu-test-version
run 30 hostname uci get system.@system[0].hostname
run 30 wificonf cat /etc/c5/wifi.conf
EOF
	boot s5-c "$DISK" "$(chainload_cmdline s5-b)" "$st"
	check "new root is running (/etc/qemu-test-version)" res_has s5-c version '^qemu-v2-'
	check "hostname preserved through sysupgrade" res_has s5-c hostname '^c5test$'
	check "wifi.conf edited before sysupgrade kept (keep.d)" res_has s5-c wificonf "^SSID='S5 Edited'"
	# the bootlog, not waitboot's dmesg: that returns on the first "booted:"
	# line and can miss the "committed" line logged right after it
	check "c5-booted committed the sysupgrade" bash -c "printf '%s' \"\$1\" | grep -q 'booted: committed sysupgrade'" _ "$(img_bootlog "$DISK")"
	check "flag ota:kernel" is_eq "$(img_flag "$DISK")" ota:kernel
	check "pending-commit removed" bash -c "! debugfs -R 'stat /opencreator-os/pending-commit' '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	check "sysupgrade.tgz consumed" bash -c "! debugfs -R 'stat /opencreator-os/sysupgrade.tgz' '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"

	# power cut in the middle of the rootfs write
	new_disk
	prepare_committed || return 0
	c5os_mkdir "$DISK" /qemu
	c5os_put "$DISK" "$RUN/v2.tar" /qemu/v2.tar
	st=$RUN/s5-cut.steps
	cat > "$st" <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 600 ] || break; sleep 1; done; dmesg | grep 'c5: '
run 60 copy cp /data/qemu/v2.tar /tmp/v2.tar
send sysupgrade -v /tmp/v2.tar
kill-when 600 Writing rootfs
EOF
	boot s5-cut "$DISK" "$(spl_root "$DISK")" "$st"
	check "power cut during the rootfs write: flag on stock" is_eq "$(img_flag "$DISK")" ota:kernel2
	if [ "$(img_part_sum "$DISK" 2 "$v2len")" = "$v2sum" ]; then
		say "  info: the rootfs write had completed when QEMU was killed"
	else
		say "  info: p2 holds a partial v2 root after the cut"
	fi
	st=$RUN/s5-cut-next.steps
	steps_stock "$st"
	boot s5-cut-next "$DISK" "$(spl_root "$DISK")" "$st"
	check "next boot after the power cut is stock" log_has s5-cut-next '^QEMU-STOCK-DONE flag=ota:kernel2'
}

# Damage the stock slot (keeps the magics, breaks the contents) so a restore
# has something to repair.
damage_stock_slot() {
	dd if=/dev/urandom of="$DISK" bs=1M seek=$(($(poff 4) / 1048576 + 2)) count=2 conv=notrunc status=none
	dd if=/dev/urandom of="$DISK" bs=512 seek=$((PSTART[3] + 256)) count=256 conv=notrunc status=none
}

# S6: real OpenWrt USB hook + install stick, headless ACTION repair and swap;
# Repair stock from the app asks first, and boot does not wait for the app.
scenario_S6() {
	new_disk
	prepare_committed || return 0
	damage_stock_slot
	local st=$RUN/s6-repair.steps stick=$RUN/stick-s6.img
	make_payload "$RUN/payload-s6" || { fatal "make-install-stick.sh failed"; return 0; }
	printf 'repair-stock\r\n' > "$RUN/payload-s6/opencreator-os/ACTION"
	make_stick "$RUN/payload-s6" "$stick"
	printf 'shell 400\nsend logread -f\nexpect 900 reboot: Restarting system\nwait-exit 240\n' > "$st"
	boot s6-repair "$DISK" "$(spl_root "$DISK")" "$st" "$stick"
	check "headless repair reboots to stock" is_eq "$(boot_outcome s6-repair):$(img_flag "$DISK")" reboot:ota:kernel2
	check "hook forwards saved model to installer" bash -c "mtype -i '$stick@@1M' ::opencreator-os-install.log | grep -q 'check: model: Creator5Pro 0029'"
	check "repair restores exact stock kernel and squashfs" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")" "$BASE_P3$STOCK_SQ_SUM"
	check "repair clears invalid marker" stockinv_clear
	steps_stock "$RUN/s6-stock.steps"
	boot s6-stock "$DISK" "$(spl_root "$DISK")" "$RUN/s6-stock.steps"
	check "repaired stock boots" log_has s6-stock '^QEMU-STOCK-DONE flag=ota:kernel2'

	new_disk
	prepare_committed || return 0
	damage_stock_slot
	printf 'shell 400\nsend logread -f\nkill-when 900 writing rootfs.squashfs .* -> /dev/mmcblk0p4\n' > "$RUN/s6-cut.steps"
	boot s6-cut "$DISK" "$(spl_root "$DISK")" "$RUN/s6-cut.steps" "$stick"
	check "interrupted repair retains OpenWrt flag" is_eq "$(img_flag "$DISK")" ota:kernel
	check "interrupted repair marks stock invalid" stockinv_set
	boot s6-retry "$DISK" "$(spl_root "$DISK")" "$st" "$stick"
	check "retry refuses fallback to invalid stock" log_has s6-retry 'bootcount: .*NO fallback'
	check "same repair stick completes on next run" is_eq "$(boot_outcome s6-retry):$(img_flag "$DISK")" reboot:ota:kernel2
	check "retry restores exact stock contents" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")" "$BASE_P3$STOCK_SQ_SUM"
	check "retry clears invalid marker" stockinv_clear
	boot s6-retry-stock "$DISK" "$(spl_root "$DISK")" "$RUN/s6-stock.steps"
	check "stock boots after interrupted repair retry" log_has s6-retry-stock '^QEMU-STOCK-DONE flag=ota:kernel2'

	new_disk
	prepare_committed || return 0
	printf 'swap\n' > "$RUN/payload-s6/opencreator-os/ACTION"
	make_stick "$RUN/payload-s6" "$stick"
	boot s6-swap "$DISK" "$(spl_root "$DISK")" "$st" "$stick"
	check "headless swap selects stock and reboots" is_eq "$(boot_outcome s6-swap):$(img_flag "$DISK")" reboot:ota:kernel2
	check "swap resets tries" is_eq "$(img_tries "$DISK")" "C5TRIES1 0"
	boot s6-swap-stock "$DISK" "$(spl_root "$DISK")" "$RUN/s6-stock.steps"
	check "stock boots after headless swap" log_has s6-swap-stock '^QEMU-STOCK-DONE flag=ota:kernel2'

	new_disk
	prepare_committed || return 0
	printf 'C5STOCKINVALID1 slot' | dd of="$DISK" bs=512 seek=$((PSTART[5] + 256)) conv=sync,notrunc status=none
	steps_openwrt "$RUN/s6-refuse.steps" <<'EOF'
run 30 hooklog logread
EOF
	boot s6-refuse "$DISK" "$(spl_root "$DISK")" "$RUN/s6-refuse.steps" "$stick"
	check "refused swap invocation reaches installer with stored model" res_has s6-refuse hooklog 'check: model: Creator5Pro 0029'
	check "installer refuses swap when stock is not selectable" res_has s6-refuse hooklog 'Cannot select stock'
	check "refused swap never selects stock" is_eq "$(img_flag "$DISK")" ota:kernel
	check "refused swap does not clear invalid mark" stockinv_set

	# app: the main menu waits for a tap, boot goes on (network, dropbear);
	# Repair stock asks first: Cancel writes nothing, ok repairs and reboots
	new_disk
	prepare_committed || return 0
	damage_stock_slot
	c5os_rm "$DISK" /opencreator-os/last-test  # no "OpenWrt installed" screen first
	local dmg
	dmg=$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")
	make_ui_payload "$RUN/payload-s6-ui" "menu_main=3 confirm_repair-stock=cancel hold=main" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s6-ui" "$RUN/stick-s6-ui.img"
	steps_openwrt "$RUN/s6-ui-cancel.steps" <<'EOF'
run 120 held i=0; until [ -f /tmp/qemu-ui-held ]; do i=$((i+1)); [ $i -lt 120 ] || exit 1; sleep 1; done; [ ! -f /tmp/qemu-ui-release ] && pidof dropbear && ifstatus lan | grep '"up": true'
run 30 release touch /tmp/qemu-ui-release
run 120 hookdone i=0; while grep -q ' /mnt ' /proc/mounts; do i=$((i+1)); [ $i -lt 120 ] || exit 1; sleep 1; done
EOF
	boot s6-ui-cancel "$DISK" "$(spl_root "$DISK")" "$RUN/s6-ui-cancel.steps" "$RUN/stick-s6-ui.img"
	check "app: c5-booted, dropbear and lan up while the menu waits for a tap" res_ok s6-ui-cancel held
	check "app: Repair stock asks first" log_has s6-ui-cancel '^QEMU-UI CONFIRM repair-stock 5 Repair stock\\nRewrite the stock slot from the copy saved at install, then boot stock\.\|Repair stock\|Cancel$'
	check "app: Cancel aborts" log_has s6-ui-cancel '^QEMU-UI abort: cancelled at repair-stock'
	check "app: the hook returns after Cancel" res_ok s6-ui-cancel hookdone
	check "app: Cancel ends with Continue (status 1)" log_has s6-ui-cancel '^QEMU-UI-CONTINUE 1$'
	check "app: Cancel writes nothing" is_eq "$(img_flag "$DISK"):$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")" "ota:kernel:$dmg"
	make_ui_payload "$RUN/payload-s6-ui" "menu_main=3 confirm_repair-stock=ok" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s6-ui" "$RUN/stick-s6-ui.img"
	printf 'expect 600 ^QEMU-UI CONFIRM repair-stock \nexpect 900 reboot: Restarting system\nwait-exit 240\n' > "$RUN/s6-ui-repair.steps"
	boot s6-ui-repair "$DISK" "$(spl_root "$DISK")" "$RUN/s6-ui-repair.steps" "$RUN/stick-s6-ui.img"
	check "app: Repair stock repairs and reboots to stock" is_eq "$(boot_outcome s6-ui-repair):$(img_flag "$DISK"):$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")" "reboot:ota:kernel2:$BASE_P3$STOCK_SQ_SUM"
	check "app: Rebooting into stock, then the app ends without Continue" bash -c "grep -q '^QEMU-UI INFO swap Rebooting into stock' \"\$1\" && ! grep -q '^QEMU-UI-CONTINUE' \"\$1\"" _ "$RUN/s6-ui-repair.log"
}

stockinv_set() { [ "$(img_bytes "$DISK" $(($(poff 5) + 131072)) 15)" = C5STOCKINVALID1 ]; }
stockinv_clear() { ! stockinv_set; }

# S10: chainload test of a kernel that is not slot 1's own -> c5.nocommit=1,
# OpenWrt boots but never touches the flag.
scenario_S10() {
	new_disk
	flow_install s10-install || return 0
	cat > "$RUN/action.sh" <<'EOF'
cl=/usr/data/opencreator-os/chainload
cp $cl/kernel.uimage /tmp/other.uimage && echo trailing >> /tmp/other.uimage &&
	sh $cl/c5-chainload.sh stage /dev/mmcblk0p2 /tmp/other.uimage && sh $cl/c5-chainload.sh go
EOF
	data_put "$DISK" "$RUN/action.sh" /qemu-action.sh
	local st=$RUN/s10-stock.steps
	steps_stock "$st"
	boot s10-stock "$DISK" "$(spl_root "$DISK")" "$st"
	check "chainload of a foreign kernel carries c5.nocommit=1" log_has s10-stock '^QEMU-CHAINLOAD root=/dev/mmcblk0p2 .*c5\.nocommit=1'
	st=$RUN/s10-openwrt.steps
	steps_openwrt "$st" < /dev/null
	boot s10-openwrt "$DISK" "$(chainload_cmdline s10-stock)" "$st"
	check "foreign chainload leaves counter and flag untouched" res_has s10-openwrt waitboot 'bootcount: slot 1 test boot \(c5.nocommit=1\); counter and flag untouched'
	check "foreign chainload does not start counter" is_eq "$(img_tries "$DISK")" ""
	check "c5-booted did not commit (nocommit)" res_has s10-openwrt waitboot 'booted: chainloaded kernel is not slot 1.s own kernel \(c5\.nocommit=1\)'
	check "flag still on stock" is_eq "$(img_flag "$DISK")" ota:kernel2
}

# S7: stock-side restore stick restores slot 1 from a backup of the image.
scenario_S7() {
	if [ ! -x "$QREPO/tools/make-restore-stick.sh" ] && [ ! -f "$QREPO/tools/make-restore-stick.sh" ]; then
		SKIP_WHY="tools/make-restore-stick.sh not in the tree"
		return 77
	fi
	# the layout the installer leaves (c5os): a restore stick refuses a
	# backup whose partition table differs from the printer's
	new_disk
	# backup of the pristine image, in tools/verify-backup.sh's layout
	local bk=$RUN/backup p n
	mkdir -p "$bk"
	for p in 1 2 3 4; do
		n=${PNAME[$p]}
		img_bytes "$DISK" "$(poff "$p")" $((PSIZE[$p] * 512)) > "$bk/$n.img"
	done
	(cd "$bk" && sha256sum kernel.img rootfs.img kernel2.img rootfs2.img > SHA256SUMS)
	for p in 1 2 3 4 5 6 7 8; do
		sgdisk -i "$p" "$DISK" | awk -v n="${PNAME[$p]}" -v p="$p" '/^First sector/ { f = $3 } /^Last sector/ { l = $3 } END { print n, p, f, l - f + 1 }'
	done > "$bk/partmap.txt"
	echo "QEMU test backup of $DISK ($(date -u '+%F %T'))" > "$bk/MANIFEST.txt"

	flow_install s7-install || return 0
	check "precondition: slot 1 holds OpenWrt" is_eq "$(img_part_sum "$DISK" 2 "$OW_SQ_LEN")" "$OW_SQ_SUM"
	"$QREPO/tools/make-restore-stick.sh" "$bk" "$RUN/restore-payload" --slot1 --flag-stock > "$RUN/make-restore-stick.log" 2>&1 ||
		{ fatal "make-restore-stick.sh failed: $(tail -n 2 "$RUN/make-restore-stick.log")"; return 0; }
	make_stick "$RUN/restore-payload" "$RUN/stick-restore.img"
	local st=$RUN/s7-restore.steps
	steps_stock "$st"
	boot s7-restore "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-restore.img"
	check "restore stick checks passed" log_has s7-restore 'check: partition table matches the backup'
	check "restore reported OK" log_has s7-restore 'restore: OK'
	check "p1 = backup kernel.img" is_eq "$(img_part_sum "$DISK" 1 $((PSIZE[1] * 512)))" "$BASE_P1"
	check "p2 = backup rootfs.img" is_eq "$(img_part_sum "$DISK" 2 $((PSIZE[2] * 512)))" "$BASE_P2"
	check "p3/p4 (running slot) untouched" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 $((PSIZE[4] * 512)))" "$BASE_P3$BASE_P4"
	check "flag -> slot 1 (--flag-stock) and reboot" is_eq "$(img_flag "$DISK"):$(boot_outcome s7-restore)" ota:kernel:reboot
	check "restore.conf retired as restore.done" bash -c "mdir -b -i '$RUN/stick-restore.img@@1M' ::opencreator-os-restore/ | grep -q restore.done"
	st=$RUN/s7-next.steps
	steps_stock "$st"
	boot s7-next "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-restore.img"
	check "stock boots from the restored slot 1" log_has s7-next '^QEMU-STOCK-INIT root=/dev/mmcblk0p2'
	check "the stick does nothing the second time" log_has s7-next 'restore: already done'
}

# S8: corrupted payload is refused before anything is written.
scenario_S8() {
	new_disk
	local p=$RUN/payload-s8 st
	make_payload "$p" || { fatal "make-install-stick.sh failed"; return 0; }
	# flip one byte in the middle of the squashfs (magic intact)
	printf '\xff' | dd of="$p/root.squashfs" bs=1 seek=$(($(stat -c %s "$p/root.squashfs") / 2)) conv=notrunc status=none
	make_stick "$p" "$RUN/stick-s8.img"
	st=$RUN/s8.steps
	steps_stock "$st"
	boot s8 "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-s8.img"
	check "installer refused: checksum mismatch" log_has s8 'abort: payload checksum mismatch \(SHA256SUMS\): root.squashfs'
	check "installer said nothing was written" log_has s8 'install: FAILED \(nothing written\)'
	check "stock continued booting" log_has s8 '^QEMU-STOCK-HOOK continue'
	check "p1/p2 untouched" is_eq "$(img_part_sum "$DISK" 1 $((PSIZE[1] * 512)))$(img_part_sum "$DISK" 2 $((PSIZE[2] * 512)))" "$BASE_P1$BASE_P2"
	check "flag unchanged" is_eq "$(img_flag_hex "$DISK")" "$(img_flag_hex "$BASE_DISK")"
	check "no stock copy saved" bash -c "! debugfs -R 'stat /opencreator-os/stock' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
}

# S9: power cut while the installer writes the rootfs; the next boot is
# stock, and the same stick finishes the install.
scenario_S9() {
	new_disk
	make_payload "$RUN/payload-s9" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s9" "$RUN/stick-s9.img"
	local st=$RUN/s9-cut.steps
	echo 'kill-when 400 ^write: root\.squashfs' > "$st"
	boot s9-cut "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-s9.img"
	check "power cut during the rootfs write" log_has s9-cut '^write: root\.squashfs'
	check "flag still on stock" is_eq "$(img_flag_hex "$DISK")" "$(img_flag_hex "$BASE_DISK")"
	check "SPL emulator picks stock" is_eq "$(spl_root "$DISK")" "$STOCK_SLOT_ROOT"
	check "install-pending recorded on userdata" bash -c "debugfs -R 'cat /opencreator-os/install-pending' '$(userdata_spec "$DISK")' 2>/dev/null | grep -qx 'slot=1'"
	st=$RUN/s9-again.steps
	steps_stock "$st"
	boot s9-again "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-s9.img"
	check "stock booted and the hook finished the install" log_has s9-again 'install: OK; slot 1 written and verified'
	check "the finished install test-boots slot 1" is_eq "$(boot_outcome s9-again)" "chainload:$OWRT_ROOT"
	check "p1 kernel = kernel.uimage" is_eq "$(img_part_sum "$DISK" 1 "$OW_K_LEN")" "$OW_K_SUM"
	check "p2 rootfs = root.squashfs" is_eq "$(img_part_sum "$DISK" 2 "$OW_SQ_LEN")" "$OW_SQ_SUM"
	check "install-pending removed" bash -c "! debugfs -R 'stat /opencreator-os/install-pending' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	check "flag still on stock" is_eq "$(img_flag_hex "$DISK")" "$(img_flag_hex "$BASE_DISK")"
}

# ------------------------------------------------- os-installer protocol --

# ui_stock_boot NAME STICKIMG [TIMEOUT]: stock boot with a --ui stick
ui_stock_boot() {
	local st=$RUN/$1.steps t=${3:-400}
	printf 'expect %s ^(QEMU-STOCK-DONE|QEMU-CHAINLOAD root=)\nwait-exit 240\n' "$t" > "$st"
	QEMU_BOOT_TIMEOUT=$((t + 600)) boot "$1" "$DISK" "$(spl_root "$DISK")" "$st" "$2"
}
ui_menu_line() { sed -n 's/^QEMU-UI \(MENU main .*\)/\1/p' "$RUN/$1.log" | tr -d '\r' | tail -n 1; }
gpt_header_field() { # DISK OFFSET -> u64 of the primary GPT header
	python3 -c 'import struct,sys; f=open(sys.argv[1],"rb"); f.seek(512+int(sys.argv[2])); print(struct.unpack("<Q", f.read(8))[0])' "$1" "$2"
}
gpt_layout() { sgdisk -p "$1" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1, $2, $3, $NF }'; }

# S12: the full touchscreen flow on a stock-layout printer: menu -> backup
# -> c5os repartition -> install -> chainload; then OpenWrt on c5os.
scenario_S12() {
	new_stock_disk
	echo "keep me" > "$RUN/keep.txt"
	data_put "$DISK" "$RUN/keep.txt" /qemu-keep.txt || { fatal "cannot put the marker on userdata"; return 0; }
	cp --sparse=always "$DISK" "$RUN/before.img"
	local before=$RUN/before.img stick=$RUN/stick-s12.img bk=$RUN/bk name sum got want n start size st
	make_ui_payload "$RUN/payload-s12" "menu=1 confirm_backup=ok confirm_c5os=ok" ||
		{ fatal "make-install-stick.sh failed: $(tail -n 2 "$RUN/make-install-stick.log" | tr '\n' ' ')"; return 0; }
	printf "SSID='QEMU Stick Override'\nPSK='stick-override-123'\n" > "$RUN/payload-s12/opencreator-os/wifi.conf"
	echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f qemu-fixture' > "$RUN/payload-s12/opencreator-os/authorized_keys"
	make_stick "$RUN/payload-s12" "$stick" 3072
	ui_stock_boot s12-stock "$stick" 2400
	check "stock kernel: no valid backup GPT before the repartition" log_has s12-stock 'Alternate GPT is invalid'
	check "menu shown" log_has s12-stock '^QEMU-UI MENU main '
	check "backup prompt (no delay)" log_has s12-stock '^QEMU-UI CONFIRM backup 0 '
	check "backup ran" log_has s12-stock '^QEMU-UI INFO backup-run '
	check "c5os prompt with a 5 s delay" log_has s12-stock '^QEMU-UI CONFIRM c5os 5 Create a 384 MB partition'
	check "outcome: chainload into slot 1" is_eq "$(boot_outcome s12-stock)" "chainload:$OWRT_ROOT"

	rm -rf "$bk"
	mkdir -p "$bk"
	mcopy -s -n -i "$stick@@1M" ::emmc-backup "$bk/" 2>/dev/null
	check "backup: VERIFIED = checksum of SHA256SUMS" is_eq "$(tr -d '\r\n' < "$bk/emmc-backup/VERIFIED" 2>/dev/null)" "$(sha256sum < "$bk/emmc-backup/SHA256SUMS" 2>/dev/null | cut -d' ' -f1)"
	check "backup: lists p1-p7, first-mib, disk-tail" is_eq "$(awk '{ print $2 }' "$bk/emmc-backup/SHA256SUMS" 2>/dev/null | tr '\n' ' ')" \
		"first-mib.bin kernel.img rootfs.img kernel2.img rootfs2.img ota.img usershare.img userdata.img disk-tail.img "
	while read -r sum name; do
		case "$name" in
		first-mib.bin) got=$(sha256sum < "$bk/emmc-backup/first-mib.bin" | cut -d' ' -f1); start=0 size=2048 ;;
		disk-tail.img) got=$(cat "$bk/emmc-backup/disk-tail.img".[0-9][0-9][0-9] | sha256sum | cut -d' ' -f1); start=$((GPT_QUIRK_LAST + 1)) size=$((DISK_SECTORS - GPT_QUIRK_LAST - 1)) ;;
		*)
			got=$(cat "$bk/emmc-backup/$name".[0-9][0-9][0-9] | sha256sum | cut -d' ' -f1)
			read -r _ n start size < <(awk -v p="${name%.img}" '$1 == p' "$bk/emmc-backup/partmap.txt")
			;;
		esac
		if [ "$name" = usershare.img ] || [ "$name" = userdata.img ]; then
			# stock mounted these before the backup (mount count, journal):
			# the copy must match what the installer read, not before.img
			check "backup: $name chunks = recorded sum" is_eq "$got" "$sum"
			continue
		fi
		want=$(img_bytes "$before" $((start * 512)) $((size * 512)) | sha256sum | cut -d' ' -f1)
		check "backup: $name = recorded sum = the eMMC before the repartition" is_eq "$got:$sum" "$want:$want"
	done < <(tr -d '\r' < "$bk/emmc-backup/SHA256SUMS" 2>/dev/null)
	rm -rf "$bk"

	check "GPT: p7 userdata shrunk, p8 c5os" is_eq "$(gpt_layout "$DISK" | sed -n '7,8p' | tr '\n' ';')" \
		"7 2543616 3166207 userdata;8 3166208 3952639 c5os;"
	check "GPT: p1-p6 unchanged" is_eq "$(gpt_layout "$DISK" | sed -n '1,6p')" "$(gpt_layout "$before" | sed -n '1,6p')"
	check "GPT verifies clean (backup header present)" bash -c "sgdisk -v '$DISK' | grep -q 'No problems found'"
	check "GPT header: alternate LBA = last sector" is_eq "$(gpt_header_field "$DISK" 32)" $((DISK_SECTORS - 1))
	check "GPT header: last usable LBA = disk end - 34" is_eq "$(gpt_header_field "$DISK" 48)" $((DISK_SECTORS - 34))
	check "MBR boot code (bytes 0..439) unchanged" is_eq "$(img_bytes "$DISK" 0 440 | sha256sum)" "$(img_bytes "$before" 0 440 | sha256sum)"
	check "SPL area (LBA 34..2047) unchanged" is_eq "$(img_bytes "$DISK" $((34 * 512)) $((2014 * 512)) | sha256sum)" "$(img_bytes "$before" $((34 * 512)) $((2014 * 512)) | sha256sum)"
	check "p1 kernel = kernel.uimage" is_eq "$(img_part_sum "$DISK" 1 "$OW_K_LEN")" "$OW_K_SUM"
	check "p2 rootfs = root.squashfs" is_eq "$(img_part_sum "$DISK" 2 "$OW_SQ_LEN")" "$OW_SQ_SUM"
	check "p3-p5 unchanged" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 $((PSIZE[4] * 512)))$(img_part_sum "$DISK" 5 $((PSIZE[5] * 512)))" \
		"$(img_part_sum "$before" 3 $((PSIZE[3] * 512)))$(img_part_sum "$before" 4 $((PSIZE[4] * 512)))$(img_part_sum "$before" 5 $((PSIZE[5] * 512)))"
	check "userdata keeps its files" is_eq "$(data_cat "$DISK" /qemu-keep.txt)" "keep me"
	check "userdata file system grown to the new p7" bash -c "dumpe2fs -h '$(userdata_spec "$DISK")' 2>/dev/null | grep -qE '^Block count: +77824$'"
	check "c5os is ext4 labelled c5os" bash -c "dumpe2fs -h '$(c5os_spec "$DISK")' 2>/dev/null | grep -qE '^Filesystem volume name: +c5os$'"
	check "stock copy saved to userdata" data_has "$DISK" /opencreator-os/stock/SHA256SUMS
	check "c5os stores hook model" is_eq "$(c5os_cat "$DISK" /opencreator-os/model)" "Creator5Pro 0029"
	check "c5os preserves hand-written stick Wi-Fi override" is_eq "$(c5os_cat "$DISK" /opencreator-os/wifi.conf)" "$(cat "$RUN/payload-s12/opencreator-os/wifi.conf")"
	check "c5os stores authorized keys" is_eq "$(c5os_cat "$DISK" /opencreator-os/authorized_keys)" "$(cat "$RUN/payload-s12/opencreator-os/authorized_keys")"
	check "userdata does not store settings or model" bash -c "for f in model wifi.conf authorized_keys; do ! debugfs -R \"stat /opencreator-os/\$f\" '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^Inode:' || exit 1; done"

	st=$RUN/s12-openwrt.steps
	steps_openwrt "$st" <<'EOF'
run 30 wificonf cat /etc/c5/wifi.conf
run 30 keys cat /etc/dropbear/authorized_keys
run 30 model cat /etc/c5/model
run 30 fstab uci -q get fstab.data.label
EOF
	boot s12-openwrt "$DISK" "$(chainload_cmdline s12-stock)" "$st"
	check "OpenWrt: fixed c5os label in fstab" res_has s12-openwrt fstab '^c5os$'
	check "OpenWrt: /data = mmcblk0p8" res_has s12-openwrt mounts '^/dev/mmcblk0p8 /data ext4'
	check "OpenWrt kernel: backup GPT valid now" log_lacks s12-openwrt 'Alternate GPT is invalid'
	check "OpenWrt committed slot 1 (flag ota:kernel)" is_eq "$(img_flag "$DISK")" ota:kernel
	check "OpenWrt logs on c5os" c5os_has "$DISK" /opencreator-os/logs/dmesg-last.txt
	check "stick Wi-Fi override imported" res_has s12-openwrt wificonf "^SSID='QEMU Stick Override'"
	check "authorized keys imported from c5os" res_has s12-openwrt keys '^ssh-ed25519 .* qemu-fixture$'
	check "model imported from c5os" res_has s12-openwrt model '^Creator5Pro 0029$'
}

# S13: refusals on a stock-layout printer: userdata too full (blocked before
# the menu), an early ok on the delayed c5os prompt, a cancelled c5os prompt.
scenario_S13() {
	local base_gpt stick
	new_stock_disk
	base_gpt=$(gpt_layout "$DISK")
	head -c 200M /dev/urandom > "$RUN/big.bin"
	data_put "$DISK" "$RUN/big.bin" /big.bin || { fatal "cannot put big.bin on userdata"; return 0; }
	rm -f "$RUN/big.bin"
	make_ui_payload "$RUN/payload-s13a" "menu=1" || { fatal "make-install-stick.sh failed"; return 0; }
	stick=$RUN/stick-s13a.img
	make_stick "$RUN/payload-s13a" "$stick"
	ui_stock_boot s13-full "$stick"
	check "full userdata: blocked before the menu, with Boot to stock" log_has s13-full '^QEMU-UI BLOCK c5os-space Please free [0-9]+ MB on /usr/data.*Tap Boot to stock.*\|Boot to stock'
	check "full userdata: Boot to stock tapped" log_has s13-full '^QEMU-UI-TAP Boot to stock'
	check "full userdata: no menu" log_lacks s13-full '^QEMU-UI MENU '
	check "full userdata: stock continued" log_has s13-full '^QEMU-STOCK-HOOK continue'
	check "full userdata: GPT unchanged" is_eq "$(gpt_layout "$DISK")" "$base_gpt"
	check "full userdata: p1/p2 untouched" is_eq "$(img_part_sum "$DISK" 1 $((PSIZE[1] * 512)))$(img_part_sum "$DISK" 2 $((PSIZE[2] * 512)))" "$BASE_P1$BASE_P2"
	check "full userdata: no backup on the stick" bash -c "! mdir -b -i '$stick@@1M' :: | grep -q emmc-backup"

	local c
	for c in early cancel; do
		new_stock_disk
		make_ui_payload "$RUN/payload-s13-$c" "menu=1 confirm_backup=cancel confirm_c5os=$c" || { fatal "make-install-stick.sh failed"; return 0; }
		stick=$RUN/stick-s13-$c.img
		make_stick "$RUN/payload-s13-$c" "$stick"
		if [ "$c" = cancel ]; then
			cat > "$RUN/unknown-model.sh" <<'EOF'
mount -t vfat /dev/sda1 /mnt
sync
before=$(awk '{print $7}' /sys/block/mmcblk0/stat) || exit 1
sh /mnt/opencreator-os/install.sh --from-stick /mnt --hook UnknownModel 9999 > /tmp/unknown-model.log 2>&1
rc=$?
sync
after=$(awk '{print $7}' /sys/block/mmcblk0/stat) || exit 1
cat /tmp/unknown-model.log
echo "QEMU-MODEL-REFUSAL rc=$rc"
echo "QEMU-MODEL-SECTORS-WRITTEN before=$before after=$after"
[ "$before" -eq "$after" ] && echo QEMU-MODEL-NOTHING-WRITTEN
umount /mnt
EOF
			data_put "$DISK" "$RUN/unknown-model.sh" /qemu-action.sh
		fi
		ui_stock_boot "s13-$c" "$stick"
		stick_cat "$stick" opencreator-os-install.log | tr -d '\r' > "$RUN/s13-$c-install.log"
		check "$c: backup skipped by the user" grep -q 'backup: skipped by the user' "$RUN/s13-$c-install.log"
		if [ "$c" = early ]; then
			# the fake app answers at once; whole seconds can still read 1 s
			check "early: ok before the delay rejected" grep -qE 'confirm c5os: ok arrived after [0-4]s, before the 5 s delay; treating as cancel' "$RUN/s13-$c-install.log"
		fi
		check "$c: aborted at c5os" grep -q 'abort: cancelled at c5os' "$RUN/s13-$c-install.log"
		check "$c: GPT unchanged" is_eq "$(gpt_layout "$DISK")" "$base_gpt"
		check "$c: p1/p2 untouched" is_eq "$(img_part_sum "$DISK" 1 $((PSIZE[1] * 512)))$(img_part_sum "$DISK" 2 $((PSIZE[2] * 512)))" "$BASE_P1$BASE_P2"
		if [ "$c" = cancel ]; then
			check "unknown hook model aborts" log_has "s13-$c" "^install: model mismatch: 'UnknownModel 9999'; nothing written"
			check "unknown model returns failure" log_has "s13-$c" '^QEMU-MODEL-REFUSAL rc=1'
			check "unknown model submits no eMMC writes" log_has "s13-$c" '^QEMU-MODEL-NOTHING-WRITTEN'
		fi
		check "$c: stock continued" log_has "s13-$c" '^QEMU-STOCK-HOOK continue'
	done
}

# S14: stock-side Swap and reinstall. The stock UI reports the hung first
# test (Try again goes on to the menu). Swap to OpenWrt with an untested
# kernel test-boots it (recreating pending-commit), the healthy boot commits
# and, the stick still in, shows "OpenWrt installed" whose Reboot boots
# OpenWrt again without it; Swap to stock; the disabled item when nothing is
# installed. A headless stick that already started OpenWrt does not again;
# the same build reinstalled from the app flips directly (known-good kernel).
scenario_S14() {
	local stick=$RUN/stick-s14.img st
	new_disk
	flow_install s14-install || return 0
	check "install test-booted slot 1, flag left on stock" is_eq "$(boot_outcome s14-install):$(img_flag "$DISK")" "chainload:$OWRT_ROOT:ota:kernel2"
	c5os_rm "$DISK" /opencreator-os/pending-commit
	make_ui_payload "$RUN/payload-s14" "menu=2 menu_installed=1" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s14" "$stick"
	ui_stock_boot s14-a "$stick"
	check "stock UI reports the hung test before the menu" log_has s14-a '^QEMU-UI CONFIRM test-failed 0 OpenWrt test failed\\nhung before OpenWrt started \(watchdog reset\)\\nStock is unchanged and boots normally\.\|Try again\|Boot to stock$'
	check "Try again goes on to the menu" bash -c "grep -n -e '^QEMU-UI CONFIRM test-failed ' -e '^QEMU-UI MENU main ' \"\$1\" | cut -d' ' -f2 | tr '\n' ' ' | grep -qx 'CONFIRM MENU '" _ "$RUN/s14-a.log"
	check "menu offers Swap to OpenWrt" bash -c "[[ \"\$1\" == *'|Swap to OpenWrt|-Uninstall (not yet available)' ]]" _ "$(ui_menu_line s14-a)"
	check "untested kernel: swap test-boots slot 1" is_eq "$(boot_outcome s14-a)" "chainload:$OWRT_ROOT"
	check "swap staged slot 1's own kernel (no c5.nocommit)" log_lacks s14-a '^QEMU-CHAINLOAD .*c5\.nocommit=1'
	check "swap recreated pending-commit for slot 1" is_eq "$(c5os_cat "$DISK" /opencreator-os/pending-commit)" "slot=1"
	check "swap: last-test started again, the hang report kept as seen" is_eq "$(c5os_cat "$DISK" /opencreator-os/last-test):$(c5os_cat "$DISK" /opencreator-os/last-test.seen)" "started qemu-test:started qemu-test"
	check "flag stays on stock until the test boot commits" is_eq "$(img_flag "$DISK")" ota:kernel2
	st=$RUN/s14-a-openwrt.steps
	printf 'expect 600 ^QEMU-UI MENU installed \nexpect 300 reboot: Restarting system\nwait-exit 240\n' > "$st"
	boot s14-a-openwrt "$DISK" "$(chainload_cmdline s14-a)" "$st" "$stick"
	check "healthy test boot committed: flag -> OpenWrt (ota:kernel)" is_eq "$(img_flag "$DISK")" ota:kernel
	check "OpenWrt shows OpenWrt installed with one Reboot button" log_has s14-a-openwrt '^QEMU-UI MENU installed OpenWrt installed\\nThe test boot succeeded and OpenWrt is now the boot system\. Remove the USB stick, then tap Reboot\.\|Reboot$'
	check "the screen comes after the commit" bash -c "awk '/c5: booted: committed/ && !c { c = NR } /c5: booted: last-test ok/ && !o { o = NR } /^QEMU-UI MENU installed / && !m { m = NR } END { exit !(c && o && m && c < o && o < m) }' \"\$1\"" _ "$RUN/s14-a-openwrt.log"
	check "Reboot reboots" is_eq "$(boot_outcome s14-a-openwrt)" reboot
	check "Rebooting into OpenWrt, then the app ends without Continue" bash -c "grep -q '^QEMU-UI INFO reboot Rebooting into OpenWrt' \"\$1\" && ! grep -q '^QEMU-UI-CONTINUE' \"\$1\"" _ "$RUN/s14-a-openwrt.log"
	check "installed screen marked seen before the reboot" is_eq "$(c5os_cat "$DISK" /opencreator-os/last-test.seen | cut -d' ' -f1):$(c5os_has "$DISK" /opencreator-os/last-test && echo left)" "ok:"
	make_ui_payload "$RUN/payload-s14-n" "menu=0" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s14-n" "$RUN/stick-s14-n.img"
	steps_openwrt "$RUN/s14-a-next.steps" < /dev/null
	boot s14-a-next "$DISK" "$(spl_root "$DISK")" "$RUN/s14-a-next.steps" "$RUN/stick-s14-n.img"
	check "next boot is OpenWrt (slot 1)" res_has s14-a-next cmdline 'root=/dev/mmcblk0p2'
	check "next boot: the normal OpenWrt menu, no installed screen" is_eq "$(grep -cF 'QEMU-UI MENU main opencreator-os qemu-test\nOpenWrt slot 1|' "$RUN/s14-a-next.log"):$(grep -c '^QEMU-UI MENU installed' "$RUN/s14-a-next.log")" "1:0"
	check "next boot keeps OpenWrt selected" is_eq "$(img_flag "$DISK")" ota:kernel

	# stock running while the flag names OpenWrt (e.g. after a fallback)
	st=$RUN/s14-b.steps
	steps_stock "$st"
	boot s14-b "$DISK" "$STOCK_SLOT_ROOT" "$st" "$stick"
	check "menu offers Swap to stock" bash -c "[[ \"\$1\" == *'|Swap to stock|'* ]]" _ "$(ui_menu_line s14-b)"
	check "flag -> stock (ota:kernel2)" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "swap to stock powered off normally" is_eq "$(boot_outcome s14-b)" poweroff
	check "stock continued" log_has s14-b '^QEMU-STOCK-HOOK continue'

	new_disk
	ui_stock_boot s14-c "$stick"
	check "nothing installed: swap disabled" bash -c "[[ \"\$1\" == *'|-Swap to OpenWrt (not installed)|'* ]]" _ "$(ui_menu_line s14-c)"
	check "nothing installed: swap refused" bash -c "mtype -i '$stick@@1M' ::opencreator-os-install.log | grep -q 'abort: swap: OpenWrt is not installed'"
	check "nothing installed: flag unchanged" is_eq "$(img_flag_hex "$DISK")" "$(img_flag_hex "$C5OS_DISK")"
	check "nothing installed: p1/p2 untouched" is_eq "$(img_part_sum "$DISK" 1 $((PSIZE[1] * 512)))$(img_part_sum "$DISK" 2 $((PSIZE[2] * 512)))" "$BASE_P1$BASE_P2"

	# committed OpenWrt, stock selected again; the stick that installed it
	new_disk
	prepare_committed || return 0
	printf 'ota:kernel2\n' | dd of="$DISK" bs=512 seek="${PSTART[5]}" conv=sync,notrunc status=none
	flow_install s14-again || return 0
	check "headless: this stick already started OpenWrt, not again" log_has s14-again 'switch: this stick already started OpenWrt in slot 1'
	check "headless retry: no chainload, no reboot" is_eq "$(boot_outcome s14-again)" poweroff
	check "headless retry: stock continued" log_has s14-again '^QEMU-STOCK-HOOK continue'
	check "headless retry: flag stays on stock" is_eq "$(img_flag "$DISK")" ota:kernel2
	make_ui_payload "$RUN/payload-s14-re" "menu=1 confirm_backup=cancel" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s14-re" "$RUN/stick-s14-re.img"
	ui_stock_boot s14-reinstall "$RUN/stick-s14-re.img"
	check "same-build reinstall: known-good kernel, no test boot" log_has s14-reinstall 'switch: slot 1 kernel matches c5os good-kernel; no test boot'
	check "same-build reinstall never chainloads" log_lacks s14-reinstall '^QEMU-CHAINLOAD '
	check "same-build reinstall directly selects OpenWrt" is_eq "$(boot_outcome s14-reinstall):$(img_flag "$DISK")" reboot:ota:kernel
	check "flip records last-test started" is_eq "$(c5os_cat "$DISK" /opencreator-os/last-test)" "started qemu-test"
	check "stock flip: Rebooting into OpenWrt, then the app ends without Continue" bash -c "grep -q '^QEMU-UI INFO reboot Rebooting into OpenWrt (slot 1)' \"\$1\" && ! grep -q '^QEMU-UI-CONTINUE' \"\$1\"" _ "$RUN/s14-reinstall.log"
}

# S15: failed test boots return to stock by themselves and stock reports
# them. c5os relabelled (OpenWrt cannot mount /data): c5-booted fails the
# test at once; the stock UI says why, "Boot to stock" lets stock boot on.
# A stall (C5_TEST_DEADLINE=10 on the command line) fails at the deadline.
scenario_S15() {
	local stick=$RUN/stick-s15.img ud tries st ow=/opencreator-os
	new_disk
	flow_install s15-install || return 0
	check "install test-boots slot 1" is_eq "$(boot_outcome s15-install)" "chainload:$OWRT_ROOT"
	debugfs -w -R "ssv volume_name notc5os" "$(c5os_spec "$DISK")" >/dev/null 2>&1
	ud=$(img_part_sum "$DISK" 7 $((PSIZE[7] * 512)))
	tries=$(img_tries "$DISK")
	st=$RUN/s15-unhealthy.steps
	printf 'expect 600 c5: test: rebooting into stock\nwait-exit 240\n' > "$st"
	boot s15-unhealthy "$DISK" "$(chainload_cmdline s15-install)" "$st"
	check "unhealthy: /data not mounted" log_has s15-unhealthy 'c5: booted: NOT healthy \(/data not mounted\)'
	check "unhealthy: failed at once, flag -> stock" log_has s15-unhealthy 'c5: test: FAILED: c5os not mounted at /data; flag -> slot 2 \(stock\)'
	check "unhealthy: reboot -f" is_eq "$(boot_outcome s15-unhealthy)" reboot
	check "unhealthy: flag names stock" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "unhealthy: last-test failed with the reason" bash -c "printf '%s\n' \"\$1\" | grep -qxE 'failed [^ ]+ c5os not mounted at /data'" _ "$(c5os_cat "$DISK" $ow/last-test)"
	check "unhealthy: pending-commit removed" bash -c "! debugfs -R 'stat $ow/pending-commit' '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	check "unhealthy: no stock-invalid mark" stockinv_clear
	check "unhealthy: counter untouched (test boots do not count)" is_eq "$(img_tries "$DISK")" "$tries"
	check "unhealthy: stock slot and userdata untouched" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 $((PSIZE[4] * 512))):$(img_part_sum "$DISK" 7 $((PSIZE[7] * 512)))" "$BASE_P3$BASE_P4:$ud"
	debugfs -w -R "ssv volume_name c5os" "$(c5os_spec "$DISK")" >/dev/null 2>&1

	make_ui_payload "$RUN/payload-s15" "confirm_test-failed=cancel" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s15" "$stick"
	ui_stock_boot s15-report "$stick"
	check "stock UI: OpenWrt test failed, with the reason" log_has s15-report '^QEMU-UI CONFIRM test-failed 0 OpenWrt test failed\\nc5os not mounted at /data\\nStock is unchanged and boots normally\.\|Try again\|Boot to stock$'
	check "stock UI: Boot to stock skips the menu" log_lacks s15-report '^QEMU-UI MENU '
	check "stock UI: stock boots on" is_eq "$(grep -c -e '^QEMU-STOCK-HOOK continue' -e '^QEMU-STOCK-DONE flag=ota:kernel2' "$RUN/s15-report.log")" 2
	check "stock UI: shown once (last-test.seen)" bash -c "[ -z \"\$2\" ] && printf '%s\n' \"\$1\" | grep -qxE 'failed [^ ]+ c5os not mounted at /data'" _ \
		"$(c5os_cat "$DISK" $ow/last-test.seen)" "$(c5os_has "$DISK" $ow/last-test && echo left)"

	# Swap to OpenWrt from the app, then a test boot that stalls past the deadline
	make_ui_payload "$RUN/payload-s15b" "menu=2" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s15b" "$stick"
	ui_stock_boot s15-swap "$stick"
	check "swap: no report again" log_lacks s15-swap '^QEMU-UI CONFIRM test-failed '
	check "swap: test boot of slot 1" is_eq "$(boot_outcome s15-swap)" "chainload:$OWRT_ROOT"
	st=$RUN/s15-deadline.steps
	printf 'expect 600 c5: test: rebooting into stock\nwait-exit 240\n' > "$st"
	boot s15-deadline "$DISK" "$(chainload_cmdline s15-swap) C5_TEST_DEADLINE=10" "$st"
	check "deadline: preinit armed 10 s" log_has s15-deadline 'c5: bootcount: slot 1 test boot; counter and flag untouched; healthy within 10 s or back to stock'
	check "deadline: failed, flag -> stock" log_has s15-deadline 'c5: test: FAILED: not healthy within 10 s; flag -> slot 2 \(stock\)'
	check "deadline: c5-booted came too late or not at all" log_lacks s15-deadline 'c5: booted: committed'
	check "deadline: reboot, flag names stock" is_eq "$(boot_outcome s15-deadline):$(img_flag "$DISK")" reboot:ota:kernel2
	check "deadline: last-test failed with the reason" bash -c "printf '%s\n' \"\$1\" | grep -qxE 'failed [^ ]+ not healthy within 10 s'" _ "$(c5os_cat "$DISK" $ow/last-test)"
	check "deadline: pending-commit removed" bash -c "! debugfs -R 'stat $ow/pending-commit' '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	if awk '/procd: - init -/ { p = 1 } /c5: test: FAILED/ { exit !p }' "$RUN/s15-deadline.log"; then
		say "  info: the deadline fired after procd's init started (job outlived preinit)"
	else
		say "  info: the deadline fired before procd's init started"
	fi
}

ALL_SCENARIOS="S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S12 S13 S14 S15"
# the scenario whose image prepare_committed reuses (run.sh -j starts the
# scenarios that call prepare_committed after it)
COMMITTED_BY=S2
