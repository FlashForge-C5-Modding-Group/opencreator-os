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
expect 400 ^(QEMU-STOCK-DONE|QEMU-CHAINLOAD root=)
wait-exit 240
EOF
}

# An OpenWrt boot that should complete: get a shell, wait for c5-booted, run
# the standard probes plus any extra "run" lines from stdin, power off.
steps_openwrt() {
	{
		cat <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 300 ] || break; sleep 2; done; dmesg | grep 'c5: '
run 30 uname uname -r
run 30 cmdline cat /proc/cmdline
run 30 mounts cat /proc/mounts
run 30 slot c5-slot status
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

# OpenWrt installed with a --chainload stick and committed by its first
# (chainloaded) boot. Cached per run in $RUNROOT/committed.img.
prepare_committed() {
	local c=$RUNROOT/committed.img st
	if [ -s "$c" ]; then
		cp --sparse=always "$c" "$DISK"
		say "setup: copied the committed OpenWrt image from an earlier scenario"
		return 0
	fi
	say "setup: install with --chainload and commit (stock boot + OpenWrt boot)"
	flow_install setup-install --chainload || return 1
	[ "$(boot_outcome setup-install)" = "chainload:$OWRT_ROOT" ] ||
		{ fatal "setup: no chainload to $OWRT_ROOT (outcome $(boot_outcome setup-install))"; return 1; }
	st=$RUN/setup-openwrt.steps
	steps_openwrt "$st" < /dev/null
	boot setup-openwrt "$DISK" "$(chainload_cmdline setup-install)" "$st" || return 1
	[ "$(img_flag "$DISK")" = ota:kernel ] || { fatal "setup: first boot did not commit (flag '$(img_flag "$DISK")')"; return 1; }
	cp --sparse=always "$DISK" "$c.tmp" && mv "$c.tmp" "$c"
}

# ------------------------------------------------------------- scenarios --

# S1: default install from the stock USB hook.
scenario_S1() {
	new_disk
	flow_install s1-stock || return 0
	local ow=/opencreator-os used off
	check "stock ran the stick hook and continued booting (hook exit != 0)" log_has s1-stock '^QEMU-STOCK-HOOK continue'
	check "installer reported success" log_has s1-stock 'install: OK; slot 1 written'
	check "boot ended in a power-off (no reboot, no stall)" is_eq "$(boot_outcome s1-stock)" poweroff
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
	check "wifi.conf from usershare wpa_supplicant.conf" is_eq "$(data_cat "$DISK" $ow/wifi.conf)" "# from stock wpa_supplicant.conf (wifi_conf)
SSID='QEMU Test Net'
PSK='qemu-psk-'\\''quoted'\\''-123'"
	check "install.state = written slot=1" bash -c "debugfs -R 'cat $ow/install.state' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^written slot=1 kernel=/dev/mmcblk0p1 rootfs=/dev/mmcblk0p2 '"
	check "chainload files copied to userdata" bash -c "for f in chainload.ko c5-chainload.sh kernel.uimage; do debugfs -R \"stat $ow/chainload/\$f\" '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^Inode:' || exit 1; done"
	check "install log on the stick ends with the 'next:' hints" bash -c "mtype -i '$RUN/stick-s1-stock.img@@1M' ::opencreator-os-install.log | grep -q 'next: or switch for real'"
	check "c5os untouched" is_eq "$(img_part_sum "$DISK" 8 $((PSIZE[8] * 512)))" "$(img_part_sum "$C5OS_DISK" 8 $((PSIZE[8] * 512)))"
}

# S2: install with CHAINLOAD -> fake jump -> OpenWrt from p2, committed.
scenario_S2() {
	new_disk
	flow_install s2-stock --chainload || return 0
	check "stock hook staged and jumped to root=$OWRT_ROOT" is_eq "$(boot_outcome s2-stock)" "chainload:$OWRT_ROOT"
	check "chainload staged slot 1's own kernel (no c5.nocommit)" log_lacks s2-stock '^QEMU-CHAINLOAD .*c5\.nocommit=1'
	check "boot flag still ota:kernel2 after the install" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "install.state records the chainload request" bash -c "debugfs -R 'cat /opencreator-os/install.state' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^chainload slot=1 key='"

	local st=$RUN/s2-openwrt.steps
	steps_openwrt "$st" <<'EOF'
run 30 wificonf cat /etc/c5/wifi.conf
run 30 fstab uci -q get fstab.data.device; uci -q get fstab.data.target
run 30 logs ls /data/opencreator-os/logs/
run 30 overlay mount | grep -E ' on /overlay | on / '
EOF
	boot s2-openwrt "$DISK" "$(chainload_cmdline s2-stock)" "$st"
	check "OpenWrt shell reached and c5-booted ran" res_has s2-openwrt waitboot 'c5: booted:'
	check "preinit tryboot armed the fallback" res_has s2-openwrt waitboot 'c5: tryboot: slot 1 booting; flag -> slot 2 \(fallback armed\)'
	check "c5-booted committed slot 1" res_has s2-openwrt waitboot 'c5: booted: .*flag -> slot 1 \(OpenWrt\)'
	check "flag is now ota:kernel" is_eq "$(img_flag "$DISK")" ota:kernel
	check "bootlog in ota+64KiB has tryboot then booted" bash -c "printf '%s' \"\$1\" | sed -n '1p;\$p' | tr '\n' '|' | grep -q '^C5BOOTLOG1|.*booted: .*flag -> slot 1'" _ "$(img_bootlog "$DISK")"
	check "bootlog order: tryboot before booted" bash -c "printf '%s\n' \"\$1\" | awk '/tryboot: slot 1 booting/{t=NR} /booted: .*flag -> slot 1/{b=NR} END{exit !(t && b && t < b)}'" _ "$(img_bootlog "$DISK")"
	check "/rom is the squashfs root, / the overlay" res_has s2-openwrt mounts "^overlayfs:/overlay / overlay "
	check "/overlay is ext4 on a loop device" res_has s2-openwrt mounts '^/dev/loop[0-9]+ /overlay ext4'
	check "/data = c5os (mmcblk0p8)" res_has s2-openwrt mounts '^/dev/mmcblk0p8 /data ext4'
	check "fstab: /data on mmcblk0p8" bash -c "[ \"\$(printf '%s\n' \"\$1\" | tr -d '\r' | tr '\n' ' ')\" = '/dev/mmcblk0p8 /data ' ]" _ "$(res_out "$RUN/s2-openwrt.res" fstab)"
	check "wifi.conf imported to /etc/c5/wifi.conf" res_has s2-openwrt wificonf "^SSID='QEMU Test Net'"
	check "dropbear running" res_ok s2-openwrt dropbear
	check "hard-float userland works (awk 1.5*2 = 3)" res_has s2-openwrt float '^3$'
	check "c5-slot status reports slot 1" res_has s2-openwrt slot '1'
	check "overlay (rootfs_data) is ext4 after the squashfs on p2" overlay_is_ext4 "$DISK" 2
	check "wifi.conf persisted in the overlay upper dir" bash -c "debugfs -R 'cat /upper/etc/c5/wifi.conf' '$(overlay_spec "$DISK" 2)' 2>/dev/null | grep -q '^SSID='"
	check "logs written to c5os opencreator-os/logs" bash -c "for f in dmesg-last.txt logread-last.txt bootlog-last.txt; do debugfs -R \"stat /opencreator-os/logs/\$f\" '$(c5os_spec "$DISK")' 2>/dev/null | grep -q '^Inode:' || exit 1; done"
	if [ "$FAILS" = 0 ] && [ ! -s "$RUNROOT/committed.img" ]; then
		cp --sparse=always "$DISK" "$RUNROOT/committed.img"
	fi
}

# S3: SPL boots OpenWrt; try-once arms stock then commits; overlay persists.
scenario_S3() {
	new_disk
	prepare_committed || return 0
	check "SPL emulator picks p2 for ota:kernel" is_eq "$(spl_root "$DISK")" "$OWRT_ROOT"
	local st=$RUN/s3-a.steps
	steps_openwrt "$st" <<'EOF'
run 30 persist echo qemu-persist-$$ > /etc/qemu-persist; sync; cat /etc/qemu-persist
run 30 fstab uci -q get fstab.data.device
EOF
	boot s3-a "$DISK" "$(spl_root "$DISK")" "$st"
	check "boot 1: tryboot armed slot 2" res_has s3-a waitboot 'tryboot: slot 1 booting; flag -> slot 2'
	check "boot 1: /data on c5os" res_has s3-a fstab '^/dev/mmcblk0p8'
	check "boot 1: /data = mmcblk0p8" res_has s3-a mounts '^/dev/mmcblk0p8 /data ext4'
	check "boot 1: committed slot 1" res_has s3-a waitboot 'booted: .*flag -> slot 1'
	check "boot 1: flag ota:kernel" is_eq "$(img_flag "$DISK")" ota:kernel
	local token
	token=$(res_out "$RUN/s3-a.res" persist | tail -n 1)
	st=$RUN/s3-b.steps
	steps_openwrt "$st" <<'EOF'
run 30 persist cat /etc/qemu-persist
EOF
	boot s3-b "$DISK" "$(spl_root "$DISK")" "$st"
	check "boot 2: file written in boot 1 is still there" is_eq "$(res_out "$RUN/s3-b.res" persist | tail -n 1)" "$token"
	check "boot 2: committed again" res_has s3-b waitboot 'booted: .*flag -> slot 1'
	check "boot 2: flag ota:kernel" is_eq "$(img_flag "$DISK")" ota:kernel
}

# S4: unhealthy boot falls back to stock; stock switches back; commit.
scenario_S4() {
	new_disk
	prepare_committed || return 0
	echo test > "$RUN/marker"
	check "inject tryboot-fail-test marker (c5os)" c5os_put "$DISK" "$RUN/marker" /opencreator-os/tryboot-fail-test
	local st=$RUN/s4-a.steps
	steps_openwrt "$st" < /dev/null
	boot s4-a "$DISK" "$(spl_root "$DISK")" "$st"
	check "boot 1 (OpenWrt): NOT healthy" res_has s4-a waitboot 'booted: NOT healthy \(.*tryboot-fail-test marker present'
	check "boot 1: flag left on stock (ota:kernel2)" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "SPL emulator now picks the stock slot" is_eq "$(spl_root "$DISK")" "$STOCK_SLOT_ROOT"

	# stock: the user removes the marker (on the host: stock cannot see c5os)
	# and runs switch-to-openwrt.sh from the stick
	check "remove the marker" c5os_rm "$DISK" /opencreator-os/tryboot-fail-test
	make_payload "$RUN/payload-s4" || { fatal "make-install-stick.sh failed"; return 0; }
	rm -f "$RUN/payload-s4/runFirmwareExe.sh"
	make_stick "$RUN/payload-s4" "$RUN/stick-s4.img"
	cat > "$RUN/action.sh" <<'EOF'
mkdir -p /mnt && mount -t vfat /dev/sda1 /mnt && sh /mnt/opencreator-os/switch-to-openwrt.sh
EOF
	data_put "$DISK" "$RUN/action.sh" /qemu-action.sh
	st=$RUN/s4-b.steps
	steps_stock "$st"
	boot s4-b "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-s4.img"
	check "boot 2 (stock) ran" log_has s4-b '^QEMU-STOCK-INIT root=/dev/mmcblk0p4'
	check "boot 2: switch-to-openwrt.sh flipped the flag" log_has s4-b "switch: boot flag -> slot 1 \('ota:kernel'\)"
	check "boot 2: ended in a reboot" is_eq "$(boot_outcome s4-b)" reboot
	check "flag ota:kernel" is_eq "$(img_flag "$DISK")" ota:kernel
	st=$RUN/s4-c.steps
	steps_openwrt "$st" < /dev/null
	boot s4-c "$DISK" "$(spl_root "$DISK")" "$st"
	check "boot 3 (OpenWrt) healthy and committed" res_has s4-c waitboot 'booted: .*flag -> slot 1'
	check "flag ota:kernel" is_eq "$(img_flag "$DISK")" ota:kernel
}

# Build a second sysupgrade.tar: root = test root + /etc/qemu-test-version,
# kernel and fwtool metadata from the build's sysupgrade.tar.
make_sysupgrade_v2() { # OUT
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
	unsquashfs -q -n -d "$w/root/r" "$OWRT_SQFS" >/dev/null 2>&1 || [ -x "$w/root/r/sbin/procd" ] || return 1
	echo "qemu-v2-$RUNID" > "$w/root/r/etc/qemu-test-version"
	rm -f "$w/x/$dir/root"
	mksquashfs "$w/root/r" "$w/x/$dir/root" -noappend -all-root -quiet -comp xz -b 256k \
		-p '/dev/console c 600 0 0 5 1' >/dev/null || return 1
	(cd "$w/x" && tar -c --owner=0 --group=0 --numeric-owner --sort=name -f "$out" "$dir")
	"$fw" -q -I "$w/meta.json" "$out"
	cp "$w/x/$dir/root" "$RUN/v2-root.squashfs"
}

# S5: sysupgrade (test-then-commit), refusal of garbage, power cut.
scenario_S5() {
	new_disk
	prepare_committed || return 0
	make_sysupgrade_v2 "$RUN/v2.tar" > "$RUN/su.log" 2>&1 || { fatal "building the v2 sysupgrade.tar failed: $(tail -n 3 "$RUN/su.log")"; return 0; }
	c5os_mkdir "$DISK" /qemu
	check "copy v2 sysupgrade.tar into c5os" c5os_put "$DISK" "$RUN/v2.tar" /qemu/v2.tar
	local v2sum v2len st
	v2sum=$(sha256sum < "$RUN/v2-root.squashfs" | cut -d' ' -f1)
	v2len=$(stat -c %s "$RUN/v2-root.squashfs")

	st=$RUN/s5-a.steps
	cat > "$st" <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 300 ] || break; sleep 2; done; dmesg | grep 'c5: '
run 30 board cat /tmp/sysinfo/board_name
run 30 hostname uci set system.@system[0].hostname=c5test && uci commit system && uci get system.@system[0].hostname
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
	check "p1 = kernel" is_eq "$(img_part_sum "$DISK" 1 "$OW_K_LEN")" "$OW_K_SUM"
	check "flag left on stock (ota:kernel2) until a test boot commits" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "pending-commit marker for slot 1 (c5os)" bash -c "debugfs -R 'cat /opencreator-os/pending-commit' '$(c5os_spec "$DISK")' 2>/dev/null | grep -qx 'slot=1'"
	check "chainload/kernel.uimage = new kernel" is_eq "$(data_cat "$DISK" /opencreator-os/chainload/kernel.uimage | sha256sum | cut -d' ' -f1)" "$OW_K_SUM"
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
EOF
	boot s5-c "$DISK" "$(chainload_cmdline s5-b)" "$st"
	check "new root is running (/etc/qemu-test-version)" res_has s5-c version '^qemu-v2-'
	check "hostname preserved through sysupgrade" res_has s5-c hostname '^c5test$'
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
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 300 ] || break; sleep 2; done; dmesg | grep 'c5: '
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

# S6: c5-restore-stock from OpenWrt; OpenWrt USB recovery hook.
scenario_S6() {
	new_disk
	prepare_committed || return 0
	damage_stock_slot
	local st=$RUN/s6-a.steps
	cat > "$st" <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 300 ] || break; sleep 2; done; dmesg | grep 'c5: '
run 300 dry c5-restore-stock --dry-run
send c5-restore-stock --reboot
wait-exit 600
EOF
	boot s6-a "$DISK" "$(spl_root "$DISK")" "$st"
	check "dry run passes" res_has s6-a dry '^restore: OK \(dry run\)'
	check "restore printed OK and rebooted" log_has s6-a '^restore: OK; flag -> slot 2, rebooting'
	check "p3 = saved stock kernel (whole partition)" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))" "$BASE_P3"
	check "p4 = stock squashfs" is_eq "$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")" "$STOCK_SQ_SUM"
	check "flag ota:kernel2" is_eq "$(img_flag "$DISK")" ota:kernel2
	st=$RUN/s6-b.steps
	steps_stock "$st"
	boot s6-b "$DISK" "$(spl_root "$DISK")" "$st"
	check "stock boots from the restored slot" log_has s6-b '^QEMU-STOCK-DONE flag=ota:kernel2'

	# USB recovery hook (OpenWrt side)
	if [ ! -f "$QREPO/feed/x2600/base-files/usr/libexec/c5-usb-recovery" ]; then
		say "  SKIP USB recovery hook: usr/libexec/c5-usb-recovery not in the tree"
		return 0
	fi
	new_disk
	prepare_committed || return 0
	damage_stock_slot
	mkdir -p "$RUN/rec/opencreator-os-recovery"
	printf '# QEMU test\nrestore-stock\n' > "$RUN/rec/opencreator-os-recovery/restore.conf"
	make_stick "$RUN/rec" "$RUN/stick-rec.img"
	st=$RUN/s6-rec.steps
	cat > "$st" <<'EOF'
expect 900 reboot: Restarting system
wait-exit 60
EOF
	boot s6-rec "$DISK" "$(spl_root "$DISK")" "$st" "$RUN/stick-rec.img"
	check "recovery hook rebooted" is_eq "$(boot_outcome s6-rec)" reboot
	check "p3/p4 restored by the recovery hook" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")" "$BASE_P3$STOCK_SQ_SUM"
	check "flag ota:kernel2" is_eq "$(img_flag "$DISK")" ota:kernel2
	check "restore.conf retired as restore.done" bash -c "mdir -b -i '$RUN/stick-rec.img@@1M' ::opencreator-os-recovery/ | grep -q restore.done"
	check "result.log on the stick says OK" bash -c "mtype -i '$RUN/stick-rec.img@@1M' ::opencreator-os-recovery/result.log | grep -q 'OK: restore-stock'"
	check "bootlog records usb-recovery done" bash -c "printf '%s' \"\$1\" | grep -q 'usb-recovery: done'" _ "$(img_bootlog "$DISK")"
	st=$RUN/s6-rec-next.steps
	steps_stock "$st"
	boot s6-rec-next "$DISK" "$(spl_root "$DISK")" "$st"
	check "stock boots after the recovery hook" log_has s6-rec-next '^QEMU-STOCK-DONE flag=ota:kernel2'
	check "stock-invalid mark cleared after the hook's restore" stockinv_clear

	# power cut while c5-restore-stock writes the stock slot
	new_disk
	prepare_committed || return 0
	damage_stock_slot
	st=$RUN/s6-cut.steps
	cat > "$st" <<'EOF'
shell 400
run 600 waitboot i=0; until dmesg | grep -q 'c5: booted:'; do i=$((i+1)); [ $i -lt 300 ] || break; sleep 2; done; dmesg | grep 'c5: '
send c5-restore-stock
kill-when 300 stock marked invalid .* while it is written
EOF
	boot s6-cut "$DISK" "$(spl_root "$DISK")" "$st"
	check "cut restore: flag on OpenWrt (ota:kernel)" is_eq "$(img_flag "$DISK")" ota:kernel
	check "cut restore: stock marked invalid (ota+128KiB)" stockinv_set
	st=$RUN/s6-cut-next.steps
	steps_openwrt "$st" <<'EOF'
run 300 restore c5-restore-stock
EOF
	boot s6-cut-next "$DISK" "$(spl_root "$DISK")" "$st"
	check "next boot is OpenWrt; tryboot did not arm the invalid stock" res_has s6-cut-next waitboot 'tryboot: slot 1 booting; .*flag stays on slot 1 \(NO fallback\)'
	check "restore re-run from OpenWrt completes" res_has s6-cut-next restore '^restore: OK'
	check "p3/p4 restored" is_eq "$(img_part_sum "$DISK" 3 $((PSIZE[3] * 512)))$(img_part_sum "$DISK" 4 "$STOCK_SQ_LEN")" "$BASE_P3$STOCK_SQ_SUM"
	check "stock-invalid mark cleared" stockinv_clear
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
	check "tryboot armed the stock fallback" res_has s10-openwrt waitboot "c5: tryboot: slot 1 booting; flag -> slot 2"
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
	check "stock booted and the hook finished the install" log_has s9-again 'install: OK; slot 1 written'
	check "p1 kernel = kernel.uimage" is_eq "$(img_part_sum "$DISK" 1 "$OW_K_LEN")" "$OW_K_SUM"
	check "p2 rootfs = root.squashfs" is_eq "$(img_part_sum "$DISK" 2 "$OW_SQ_LEN")" "$OW_SQ_SUM"
	check "install-pending removed" bash -c "! debugfs -R 'stat /opencreator-os/install-pending' '$(userdata_spec "$DISK")' 2>/dev/null | grep -q '^Inode:'"
	check "flag still on stock" is_eq "$(img_flag_hex "$DISK")" "$(img_flag_hex "$BASE_DISK")"
}

# S11: zero-write USB test stick (tools/make-test-stick.sh): stock's hook
# chainloads OpenWrt with its root on the stick, OpenWrt reports to the
# stick. Nothing may be written to the eMMC.

# make_test_stick IMG [corrupt]: the product stick image from the OpenWrt
# fixture, with the fake c5-chainload.sh and re-made checksums; "corrupt"
# flips one byte of kernel.uimage after the checksums were made
make_test_stick() {
	local img=$1 vdir=$RUN/vdir/qemu-test t=$RUN/stick-dir
	rm -rf "$vdir" "$t"
	mkdir -p "$vdir" "$t"
	ln -s "$OWRT_SQFS" "$vdir/${OWRT_ART##*/}-root.squashfs"
	ln -s "$OWRT_ART-kernel.uimage" "$vdir/${OWRT_ART##*/}-kernel.uimage"
	"$QREPO/tools/make-test-stick.sh" "$vdir" "$img" > "$RUN/make-test-stick.log" 2>&1 || return 1
	mcopy -s -n -i "$img@@1M" ::opencreator-os-test "$t/" || return 1
	fake_chainload > "$t/opencreator-os-test/c5-chainload.sh"
	resum "$t/opencreator-os-test"
	if [ "${2:-}" = corrupt ]; then
		printf '\xff' | dd of="$t/opencreator-os-test/kernel.uimage" bs=1 \
			seek=$(($(stat -c %s "$t/opencreator-os-test/kernel.uimage") / 2)) conv=notrunc status=none
	fi
	mcopy -o -i "$img@@1M" "$t/opencreator-os-test/c5-chainload.sh" "$t/opencreator-os-test/SHA256SUMS" \
		"$t/opencreator-os-test/MD5SUMS" "$t/opencreator-os-test/kernel.uimage" ::opencreator-os-test/
}
stick_test_cat() { mtype -i "$1@@1M" "::opencreator-os-test/$2" 2>/dev/null | tr -d '\r'; }

# img_regions DISK: sha256 per region - GPT head (LBA 0..2047), p1..p7, the
# rest (backup GPT)
img_regions() {
	local p end
	echo "head $(img_bytes "$1" 0 $((PSTART[1] * 512)) | sha256sum | cut -c1-16)"
	for p in 1 2 3 4 5 6; do
		echo "p$p $(img_part_sum "$1" "$p" $((PSIZE[$p] * 512)) | cut -c1-16)"
	done
	end=$(sgdisk -i 7 "$1" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
	echo "p7 $(img_bytes "$1" "$(poff 7)" $(((end + 1 - PSTART[7]) * 512)) | sha256sum | cut -c1-16)"
	echo "tail $(tail -c +$(((end + 1) * 512 + 1)) "$1" | sha256sum | cut -c1-16)"
}
# fs_tree DISK PART OUTDIR: file tree of an ext4 partition (contents only)
fs_tree() {
	rm -rf "$3"
	mkdir -p "$3"
	debugfs -R "rdump / $3" "$1?offset=$(poff "$2")" >/dev/null 2>&1
}

scenario_S11() {
	if [ ! -f "$QREPO/tools/make-test-stick.sh" ]; then
		SKIP_WHY="tools/make-test-stick.sh not in the tree"
		return 77
	fi
	new_stock_disk
	local stick=$RUN/stick-s11.img st r r0 r1 r2 sum0 sum1 summary cl
	make_test_stick "$stick" || { fatal "make-test-stick.sh failed: $(tail -n 2 "$RUN/make-test-stick.log" | tr '\n' ' ')"; return 0; }
	img_regions "$DISK" > "$RUN/regions-0.txt"
	fs_tree "$DISK" 6 "$RUN/tree0-usershare"
	fs_tree "$DISK" 7 "$RUN/tree0-userdata"

	st=$RUN/s11-stock.steps
	steps_stock "$st"
	boot s11-stock "$DISK" "$(spl_root "$DISK")" "$st" "$stick"
	check "stock hook staged and jumped to root=/dev/sda2" is_eq "$(boot_outcome s11-stock)" chainload:/dev/sda2
	cl=$(chainload_cmdline s11-stock)
	check "cmdline: root=/dev/sda2" bash -c "printf '%s' \"\$1\" | grep -qE '(^|[: ])root=/dev/sda2( |$)'" _ "$cl"
	check "cmdline: c5.usbtest=1" bash -c "printf '%s' \"\$1\" | grep -qE ' c5\.usbtest=1( |$)'" _ "$cl"
	check "cmdline: c5.nocommit=1" bash -c "printf '%s' \"\$1\" | grep -qE ' c5\.nocommit=1( |$)'" _ "$cl"
	check "stick: ATTEMPTED marker" bash -c "mdir -b -i '$stick@@1M' ::opencreator-os-test/ | grep -q ATTEMPTED"
	check "stick: wifi.conf from usershare" bash -c "mtype -i '$stick@@1M' ::opencreator-os-test/wifi.conf | grep -q '^SSID='"
	check "stick: hook.log says payload verified" bash -c "mtype -i '$stick@@1M' ::opencreator-os-test/hook.log | grep -q 'payload verified'"
	sum0=$(sha256sum < "$DISK")

	st=$RUN/s11-openwrt.steps
	cat > "$st" <<'EOF'
shell 400
run 400 report i=0; until logread | grep -q 'c5-usbtest: report written'; do i=$((i+1)); [ $i -lt 200 ] || break; sleep 2; done; logread | grep 'c5-usbtest'
run 30 cmdline cat /proc/cmdline
run 30 mounts cat /proc/mounts
run 30 rominfo grep ' /rom ' /proc/self/mountinfo; cat /sys/class/block/sda2/dev
send sync; poweroff
wait-exit 240
EOF
	if [ -n "$cl" ]; then
		boot s11-openwrt "$DISK" "$cl" "$st" "$stick"
	else
		fatal "no chainload command line; OpenWrt boot skipped"
	fi
	sum1=$(sha256sum < "$DISK")
	check "eMMC image byte-identical across the OpenWrt test boot (whole image sha256)" is_eq "$sum1" "$sum0"
	check "c5-usbtest reported and unmounted the stick" res_has s11-openwrt report 'report written; stick unmounted'
	check "/data is userdata, read-only" res_has s11-openwrt mounts '^/dev/mmcblk0p7 /data ext4 ro[, ]'
	summary=$(stick_test_cat "$stick" openwrt/summary.txt)
	printf '%s\n' "$summary" > "$RUN/summary.txt"
	check "summary.txt ends with DONE" is_eq "$(printf '%s\n' "$summary" | tail -n 1)" DONE
	for r in root overlay emmc data wifi-conf ipv4 ssh fpu; do
		check "summary: PASS $r" bash -c "printf '%s\n' \"\$1\" | grep -qE '^PASS +$r '" _ "$summary"
	done
	say "  info: summary FAIL lines (expected in QEMU: no X2600 UARTs, GPIO, watchdog, Wi-Fi):$(printf '%s\n' "$summary" | awk '$1 == "FAIL" { printf " %s", $2 }')"
	check "report has early/ and final/ snapshots" bash -c "mdir -b -i '$stick@@1M' ::opencreator-os-test/openwrt/ | grep -q early && mdir -b -i '$stick@@1M' ::opencreator-os-test/openwrt/ | grep -q final"

	st=$RUN/s11-again.steps
	steps_stock "$st"
	boot s11-again "$DISK" "$(spl_root "$DISK")" "$st" "$stick"
	check "second boot: hook.log says already attempted" bash -c "mtype -i '$stick@@1M' ::opencreator-os-test/hook.log | grep -q 'already attempted'"
	check "second boot: stock continued, no chainload" is_eq "$(boot_outcome s11-again)" poweroff

	local bad=$RUN/stick-s11-bad.img
	make_test_stick "$bad" corrupt || { fatal "make-test-stick.sh failed (corrupt stick)"; return 0; }
	st=$RUN/s11-bad.steps
	steps_stock "$st"
	boot s11-bad "$DISK" "$(spl_root "$DISK")" "$st" "$bad"
	check "corrupt kernel.uimage: payload checksum mismatch" log_has s11-bad 'usbtest: payload checksum mismatch .*kernel\.uimage'
	check "corrupt kernel.uimage: stock continued, no chainload" is_eq "$(boot_outcome s11-bad)" poweroff
	check "corrupt kernel.uimage: no ATTEMPTED marker" bash -c "! mdir -b -i '$bad@@1M' ::opencreator-os-test/ | grep -q ATTEMPTED"

	# Stock's own boot fscks and mounts usershare/userdata read-write, which
	# updates their superblocks (mount count/time) on the printer too, so
	# across stock boots those two are compared by content.
	img_regions "$DISK" > "$RUN/regions-2.txt"
	r0=$(grep -vE '^p[67] ' "$RUN/regions-0.txt") r2=$(grep -vE '^p[67] ' "$RUN/regions-2.txt")
	check "whole flow: GPT, p1-p5 and backup GPT byte-identical" is_eq "$r2" "$r0"
	fs_tree "$DISK" 6 "$RUN/tree2-usershare"
	fs_tree "$DISK" 7 "$RUN/tree2-userdata"
	check "whole flow: usershare files unchanged" diff -r --no-dereference "$RUN/tree0-usershare" "$RUN/tree2-usershare"
	check "whole flow: userdata files unchanged" diff -r --no-dereference "$RUN/tree0-userdata" "$RUN/tree2-userdata"
	r1=$(diff "$RUN/regions-0.txt" "$RUN/regions-2.txt" | sed -n 's/^> \(p[67]\) .*/\1/p' | tr '\n' ' ')
	say "  info: raw bytes changed by stock's own fsck/mount: ${r1:-none}"
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
	make_ui_payload "$RUN/payload-s12" "menu=1 confirm_backup=ok confirm_c5os=ok" --chainload ||
		{ fatal "make-install-stick.sh failed: $(tail -n 2 "$RUN/make-install-stick.log" | tr '\n' ' ')"; return 0; }
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

	st=$RUN/s12-openwrt.steps
	steps_openwrt "$st" <<'EOF'
run 30 wificonf cat /etc/c5/wifi.conf
run 30 fstab uci -q get fstab.data.device
EOF
	boot s12-openwrt "$DISK" "$(chainload_cmdline s12-stock)" "$st"
	check "OpenWrt: /data on c5os (fstab)" res_has s12-openwrt fstab '^/dev/mmcblk0p8'
	check "OpenWrt: /data = mmcblk0p8" res_has s12-openwrt mounts '^/dev/mmcblk0p8 /data ext4'
	check "OpenWrt kernel: backup GPT valid now" log_lacks s12-openwrt 'Alternate GPT is invalid'
	check "OpenWrt committed slot 1 (flag ota:kernel)" is_eq "$(img_flag "$DISK")" ota:kernel
	check "OpenWrt logs on c5os" c5os_has "$DISK" /opencreator-os/logs/dmesg-last.txt
	check "wifi.conf imported" res_has s12-openwrt wificonf "^SSID='QEMU Test Net'"
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
	check "full userdata: blocked before the menu" log_has s13-full '^QEMU-UI BLOCK c5os-space Please free [0-9]+ MB on /usr/data'
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
		ui_stock_boot "s13-$c" "$stick"
		stick_cat "$stick" opencreator-os-install.log | tr -d '\r' > "$RUN/s13-$c-install.log"
		check "$c: backup skipped by the user" grep -q 'backup: skipped by the user' "$RUN/s13-$c-install.log"
		if [ "$c" = early ]; then
			check "early: ok before the delay rejected" grep -q 'confirm c5os: ok arrived after 0s, before the 5 s delay; treating as cancel' "$RUN/s13-$c-install.log"
		fi
		check "$c: aborted at c5os" grep -q 'abort: cancelled at c5os' "$RUN/s13-$c-install.log"
		check "$c: GPT unchanged" is_eq "$(gpt_layout "$DISK")" "$base_gpt"
		check "$c: p1/p2 untouched" is_eq "$(img_part_sum "$DISK" 1 $((PSIZE[1] * 512)))$(img_part_sum "$DISK" 2 $((PSIZE[2] * 512)))" "$BASE_P1$BASE_P2"
		check "$c: stock continued" log_has "s13-$c" '^QEMU-STOCK-HOOK continue'
	done
}

# S14: Swap from the menu: stock -> OpenWrt, OpenWrt flag -> stock, and the
# disabled item when nothing is installed.
scenario_S14() {
	local stick=$RUN/stick-s14.img st
	new_disk
	flow_install s14-install || return 0
	check "install left the flag on stock" is_eq "$(img_flag "$DISK")" ota:kernel2
	make_ui_payload "$RUN/payload-s14" "menu=2" || { fatal "make-install-stick.sh failed"; return 0; }
	make_stick "$RUN/payload-s14" "$stick"
	ui_stock_boot s14-a "$stick"
	check "menu offers Swap to OpenWrt" bash -c "[[ \"\$1\" == *'|Swap to OpenWrt|-Uninstall (not yet available)' ]]" _ "$(ui_menu_line s14-a)"
	check "swap rebooted" is_eq "$(boot_outcome s14-a)" reboot
	check "flag -> OpenWrt (ota:kernel)" is_eq "$(img_flag "$DISK")" ota:kernel

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
}

ALL_SCENARIOS="S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14"
