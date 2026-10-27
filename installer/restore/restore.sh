#!/bin/sh
# opencreator-os restore stick: write partition images from a verified eMMC
# backup back to the printer. Runs on the stock firmware (busybox sh, root),
# normally from the stock USB hook via the stick's runFirmwareExe.sh.
#
#   sh restore.sh [--check] [--hook]
#
#   --check  run every check, print the plan, write nothing
#   --hook   started by the stock USB hook: pause on the result screen
# Other non-option arguments (stock passes MACHINE and PID) are ignored.
#
# Files next to this script (made by tools/make-restore-stick.sh): lib.sh,
# fb/*.raw, partmap.txt, MANIFEST.txt, SHA256SUMS, MD5SUMS, the images and
# restore.conf with one action per line:
#   write NAME IMAGE   write IMAGE to GPT partition NAME (whole partition)
#   flag SLOT          afterwards point the boot flag at slot 1 or 2
# All checks pass before anything is written, or nothing is written. Never
# writes the running slot or a mounted partition. On success restore.conf
# becomes restore.done (the hook does not repeat) and the printer reboots if
# the boot flag changed; otherwise the script exits 1 so stock boots on.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
CHECK=0 HOOK=0
for a in "$@"; do
	case "$a" in
	--check) CHECK=1 ;;
	--hook) HOOK=1 ;;
	-h | --help) sed -n '2,20s/^# \{0,1\}//p' "$0"; exit 0 ;;
	-*) echo "restore: unknown option $a" >&2; exit 2 ;;
	*) ;;
	esac
done

# shellcheck source-path=SCRIPTDIR source=../opencreator-os/lib.sh
. "$SELF_DIR/lib.sh"
STICK=$SELF_DIR
FBDIR=$SELF_DIR/fb
C5_FB=${C5_FB:-/dev/fb0}
LOG_STICK_NAME=result.log
LOG_DATA_NAME=restore.log
CONF=$SELF_DIR/restore.conf

# show NAME: put FBDIR/NAME.raw on the panel (stock does the same with cat).
show() {
	[ -f "$FBDIR/$1.raw" ] && [ -e "$C5_FB" ] || return 0
	cat "$FBDIR/$1.raw" > "$C5_FB" 2>/dev/null
	return 0
}

finish() {  # finish SCREEN EXITCODE
	show "$1"
	sync
	[ "$HOOK" = 1 ] && sleep "${C5_SCREEN_PAUSE:-10}"
	exit "$2"
}

refuse() {
	log "refuse: $*"
	[ "$CHECK" = 1 ] && exit 1
	log "restore: FAILED (nothing written)"
	finish restore-failed 1
}

fail() {
	log "restore: FAILED $*"
	finish restore-failed 1
}

log_lines() {  # log_lines PREFIX TEXT
	printf '%s\n' "$2" | while IFS= read -r ll; do log "$1$ll"; done
}

if [ ! -f "$CONF" ]; then
	if [ -f "$SELF_DIR/restore.done" ]; then
		log "restore: already done (restore.done); nothing to do, remove the stick"
	else
		log "restore: no restore.conf in $SELF_DIR; nothing to do"
	fi
	exit 1
fi

log "restore: start from $SELF_DIR (check=$CHECK hook=$HOOK)"
[ -f "$SELF_DIR/MANIFEST.txt" ] && log "restore: backup $(head -n 1 "$SELF_DIR/MANIFEST.txt")"

# --- checks (nothing is written before all of them pass) ---------------------

[ "$C5_UNAME_R" = "5.10.186+" ] || refuse "running kernel is $C5_UNAME_R, not the stock 5.10.186+"
sum_init || refuse "neither sha256sum nor md5sum available"
[ -s "$SELF_DIR/$SUMS" ] || refuse "$SUMS missing"
bad=$(sums_verify "$SELF_DIR" "$SUMS") || refuse "checksum mismatch ($SUMS): ${bad:-empty list}"
log "check: all files match $SUMS"

[ -s "$SELF_DIR/partmap.txt" ] || refuse "partmap.txt missing"
want=$(tr -d '\r' < "$SELF_DIR/partmap.txt" | awk 'NF { $1 = $1; print }')
have=$(part_table)
if [ "$want" != "$have" ]; then
	log "check: backup partition table (NAME NR START SIZE):"
	log_lines "check:   " "$want"
	log "check: this printer's partition table:"
	log_lines "check:   " "${have:-<none parsed from $C5_FDISK -l $C5_DISK>}"
	refuse "the backup was taken from a different partition layout"
fi
log "check: partition table matches the backup"

OWN=$(own_slot) || refuse "root=$(cmdline_root) is neither GPT rootfs nor rootfs2"
log "check: running slot $OWN ($(cmdline_root)), boot flag '$(flag_read)'"

# Parse and check every action; remember the writes for the second pass.
WRITES='' FLAG_TO='' n_act=0
lineno=0
set -f
while IFS= read -r line || [ -n "$line" ]; do
	lineno=$((lineno + 1))
	line=$(printf '%s' "$line" | tr -d '\r')
	# shellcheck disable=SC2086 # split the action into words
	set -- $line
	[ $# -eq 0 ] && continue
	case "$1" in
	\#*) continue ;;
	write)
		[ $# -eq 3 ] || refuse "restore.conf line $lineno: expected 'write NAME IMAGE'"
		name=$2 img=$3
		case "$img" in */* | .*) refuse "restore.conf line $lineno: image must be a plain file name" ;; esac
		case "$name" in
		kernel | kernel2 | rootfs | rootfs2) ;;
		usershare) ;;
		*) refuse "restore.conf line $lineno: partition '$name' is not restorable by this stick" ;;
		esac
		[ -f "$SELF_DIR/$img" ] || refuse "image $img missing"
		[ -n "$(sums_get "$SELF_DIR/$SUMS" "$img")" ] || refuse "image $img is not listed in $SUMS"
		dev=$(part_dev "$name") || refuse "GPT partition '$name' not found"
		if [ "$name" = "$(slot_kname "$OWN")" ] || [ "$name" = "$(slot_rname "$OWN")" ] || [ "$dev" = "$(cmdline_root)" ]; then
			refuse "$name ($dev) belongs to the running slot $OWN; restore it from the other slot or from OpenWrt"
		fi
		if is_mounted "$dev"; then
			if [ "$name" = usershare ]; then
				refuse "usershare ($dev) is mounted by stock (/usr/prog, /etc) and cannot be restored while stock runs; restore it from OpenWrt or another rescue system"
			fi
			refuse "$name ($dev) is mounted"
		fi
		isz=$(file_bytes "$SELF_DIR/$img")
		psz=$(part_bytes "$dev") || refuse "cannot read the size of $dev"
		[ "$isz" = "$psz" ] || refuse "$img is $isz bytes, $name ($dev) is $psz bytes; expected a whole-partition image"
		case "$name" in
		kernel*) [ "$(magic_hex "$SELF_DIR/$img")" = "$UIMAGE_MAGIC" ] || refuse "$img does not start with a uImage header" ;;
		rootfs*) [ "$(magic_str "$SELF_DIR/$img")" = "$SQUASHFS_MAGIC" ] || refuse "$img does not start with squashfs" ;;
		esac
		case " $WRITES " in *" $name:"*) refuse "restore.conf writes $name twice" ;; esac
		WRITES="$WRITES $name:$img"
		;;
	flag)
		[ $# -eq 2 ] || refuse "restore.conf line $lineno: expected 'flag SLOT'"
		case "$2" in 1 | 2) FLAG_TO=$2 ;; *) refuse "restore.conf line $lineno: flag must be 1 or 2" ;; esac
		;;
	*) refuse "restore.conf line $lineno: unknown action '$1'" ;;
	esac
	n_act=$((n_act + 1))
done < "$CONF"
set +f
[ "$n_act" -gt 0 ] || refuse "restore.conf lists no actions"

# image that will be in partition NAME after the restore (empty: unchanged)
planned() { for w in $WRITES; do [ "${w%%:*}" = "$1" ] && echo "${w#*:}"; done; }

if [ -n "$FLAG_TO" ]; then
	for name in "$(slot_kname "$FLAG_TO")" "$(slot_rname "$FLAG_TO")"; do
		img=$(planned "$name")
		if [ -n "$img" ]; then src=$SELF_DIR/$img; else src=$(part_dev "$name"); fi
		case "$name" in
		kernel*) [ "$(magic_hex "$src")" = "$UIMAGE_MAGIC" ] || refuse "flag $FLAG_TO: $name would not hold a uImage" ;;
		rootfs*) [ "$(magic_str "$src")" = "$SQUASHFS_MAGIC" ] || refuse "flag $FLAG_TO: $name would not hold squashfs" ;;
		esac
	done
fi

for w in $WRITES; do
	log "check: would write ${w#*:} -> ${w%%:*} ($(part_dev "${w%%:*}"))"
done
if [ -n "$WRITES" ] && [ "$(flag_slot)" != "$OWN" ]; then
	log "check: boot flag names slot $(flag_slot); would point it back at the running slot $OWN before writing"
fi
[ -z "$FLAG_TO" ] || log "check: would point the boot flag at slot $FLAG_TO after all writes are verified"
if [ "$CHECK" = 1 ]; then
	log "check: OK"
	exit 0
fi

# --- writes ---------------------------------------------------------------------

show restoring
# A power loss mid-write must boot the running (intact) slot: the flag names
# it before the first write; a requested flag change follows the writes.
if [ -n "$WRITES" ]; then
	flag_ensure_own "$OWN" || fail "cannot point the boot flag at the running slot $OWN; nothing written"
fi
for w in $WRITES; do
	name=${w%%:*} img=${w#*:}
	dev=$(part_dev "$name")
	sz=$(file_bytes "$SELF_DIR/$img")
	log "write: $img ($sz bytes) -> $name ($dev)"
	dd if="$SELF_DIR/$img" of="$dev" bs=1M conv=fsync,notrunc 2>/dev/null || fail "dd to $dev failed"
	drop_caches
	[ "$(dev_sum "$dev" "$sz")" = "$(sums_get "$SELF_DIR/$SUMS" "$img")" ] || fail "read-back mismatch on $dev ($name)"
	log "write: $name read back OK ($SUM)"
done

FLAG_CHANGED=0
if [ -n "$FLAG_TO" ]; then
	if [ "$(flag_slot)" = "$FLAG_TO" ]; then
		log "flag: already slot $FLAG_TO ('$(flag_read)')"
	else
		flag_write "$FLAG_TO" || fail "boot flag write failed (now '$(flag_read)')"
		FLAG_CHANGED=1
		log "flag: boot flag -> slot $FLAG_TO ('$(flag_read)')"
	fi
fi

mv -f "$CONF" "$SELF_DIR/restore.done" || log "restore: warning: could not rename restore.conf; remove the stick before the next boot"
log "restore: OK"
if [ "$FLAG_CHANGED" = 1 ]; then
	show restored
	[ "$HOOK" = 1 ] && sleep "${C5_SCREEN_PAUSE:-10}"
	log "restore: rebooting into slot $FLAG_TO"
	sync
	$C5_REBOOT
	exit 0
fi
finish restored 1
