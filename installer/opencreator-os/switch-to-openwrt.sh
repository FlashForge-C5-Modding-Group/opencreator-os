#!/bin/sh
# Point the boot flag at the OpenWrt slot and reboot. Runs on the stock
# firmware (busybox sh, root), e.g. after OpenWrt's try-once fallback returned
# the printer to stock, or after a non-flip install once the chainload test
# passed.
#
#   sh switch-to-openwrt.sh [--no-reboot]
#
# The slot stock is NOT running from must hold a uImage kernel and a squashfs
# root; otherwise nothing is changed.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
STICK=$(dirname "$SELF_DIR")
REBOOT=1
for a in "$@"; do
	case "$a" in
	--no-reboot) REBOOT=0 ;;
	-h | --help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
	*) echo "switch: unknown argument $a" >&2; exit 2 ;;
	esac
done

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SELF_DIR/lib.sh"

[ "$C5_UNAME_R" = "5.10.186+" ] || { die "running kernel is $C5_UNAME_R, not stock (on OpenWrt use c5-slot)"; exit 1; }
OWN=$(own_slot) || { die "root=$(cmdline_root) is not a GPT rootfs/rootfs2 partition"; exit 1; }
TGT=$(other_slot "$OWN")
TK=$(part_dev "$(slot_kname "$TGT")") || { die "GPT partition $(slot_kname "$TGT") not found"; exit 1; }
TR=$(part_dev "$(slot_rname "$TGT")") || { die "GPT partition $(slot_rname "$TGT") not found"; exit 1; }
[ "$(magic_hex "$TK")" = "$UIMAGE_MAGIC" ] || { die "$TK (slot $TGT kernel) does not start with a uImage header"; exit 1; }
[ "$(magic_str "$TR")" = "$SQUASHFS_MAGIC" ] || { die "$TR (slot $TGT rootfs) is not squashfs"; exit 1; }

log "switch: running stock slot $OWN, boot flag '$(flag_read)'"
if ! flag_write "$TGT"; then
	flag_write "$OWN"
	die "boot flag write failed; flag set back to slot $OWN ('$(flag_read)')"
	exit 1
fi
log "switch: boot flag -> slot $TGT ('$(flag_read)')"
sync
if [ "$REBOOT" = 1 ]; then
	log "switch: rebooting"
	$C5_REBOOT
fi
exit 0
