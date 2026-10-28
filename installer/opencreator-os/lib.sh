# shellcheck shell=sh disable=SC2034
# (SC2034: variables set here are used by the scripts that source this file)
# Shared helpers for the opencreator-os installer scripts that run on the
# stock Creator 5 Pro firmware (busybox sh) or OpenWrt. Sourced, not
# executed, by a script that sets SELF_DIR to the directory holding this
# file and slot.sh (the image's /lib/c5/slot.sh: partitions, slots, boot
# flag), which is sourced from here.
#
# Every path the scripts touch can be overridden through the environment so
# the installer can be exercised against plain files on a PC; the defaults are
# the stock printer's. Besides slot.sh's (C5_DISK, C5_PARTX, C5_CMDLINE_FILE,
# C5_SYSBLOCK, C5_MOUNTS, C5_DROP_CACHES; see there):
#   C5_FDISK       fdisk binary, run as "$C5_FDISK -l $C5_DISK" (fdisk)
#   C5_SFDISK      util-linux sfdisk for GPT dump/write       (sfdisk; install.sh: the stick's bin/sfdisk)
#   C5_DATA        stock userdata mount point                 (/usr/data)
#   C5_REBOOT      reboot command                             (reboot)
#   C5_UNAME_R     kernel release                             ($(uname -r))
#   C5_SUM         force md5sum or sha256sum                  (sha256sum if present)
#   C5_C5OS_MIB    size of the c5os partition in MiB          (4096)
# install.sh points C5_PARTX at the stick's bin/partx.
# Callers set STICK (directory for the stick-side log) as needed;
# LOG_STICK_NAME / LOG_DATA_NAME name the log files on the stick and in
# $OCDIR. UI=1 sends screen requests to the os-installer app on stdout and
# reads its answers on stdin (see the ui_* helpers).

C5_FDISK=${C5_FDISK:-fdisk}
C5_SFDISK=${C5_SFDISK:-sfdisk}
C5_DATA=${C5_DATA:-/usr/data}
C5_REBOOT=${C5_REBOOT:-reboot}
C5_UNAME_R=${C5_UNAME_R:-$(uname -r)}
C5_C5OS_MIB=${C5_C5OS_MIB:-4096}
# shellcheck source-path=SCRIPTDIR source=../../feed/x2600/base-files/lib/c5/slot.sh
. "$SELF_DIR/slot.sh"
UI=${UI:-0}

OCDIR=$C5_DATA/opencreator-os
UIMAGE_MAGIC=27051956
SQUASHFS_MAGIC=hsqs
LOG_STICK_NAME=${LOG_STICK_NAME:-opencreator-os-install.log}
LOG_DATA_NAME=${LOG_DATA_NAME:-install.log}

# Hook arguments win; manual stock runs read literals, never execute startup.
model_read() {
	if [ -z "$MACHINE$PID" ] && [ "$C5_SYSTEM" = stock ]; then
		mr_file=${C5_APP_STARTUP:-/usr/prog/app_startup.sh}
		MACHINE=$(sed -n "s/^MACHINE=//p" "$mr_file" 2>/dev/null | tr -d '\r')
		PID=$(sed -n "s/^PID=//p" "$mr_file" 2>/dev/null | tr -d '\r')
		case "$MACHINE" in \"*\") MACHINE=${MACHINE#\"}; MACHINE=${MACHINE%\"} ;; \'*\') MACHINE=${MACHINE#\'}; MACHINE=${MACHINE%\'} ;; esac
		case "$PID" in \"*\") PID=${PID#\"}; PID=${PID%\"} ;; \'*\') PID=${PID#\'}; PID=${PID%\'} ;; esac
	fi
	case "$MACHINE $PID" in
	"Creator5Pro 0029" | "Creator5 0028") return 0 ;;
	*) return 1 ;;
	esac
}

action_read() {
	if [ -z "$ACTION" ] && [ -f "$STICK/opencreator-os/ACTION" ]; then
		ACTION=$(tr -d '\r' < "$STICK/opencreator-os/ACTION") || return 1
		[ -n "$ACTION" ] || return 1
	fi
	[ -n "$ACTION" ] || { [ "$C5_SYSTEM" != stock ] || ACTION=install; }
	case "$ACTION" in '' | install | swap | repair-stock | update) return 0 ;; *) return 1 ;; esac
}

# --- logging -----------------------------------------------------------------

# NO_DATA_LOG=1 while userdata is unmounted (its mount point must stay empty)
log() {
	log_line="$(date '+%F %T') $*"
	printf '%s\n' "$*"
	[ "${CHECK:-0}" != 1 ] || return 0
	if [ -n "${STICK:-}" ] && [ -d "$STICK" ]; then
		printf '%s\n' "$log_line" >> "$STICK/$LOG_STICK_NAME" 2>/dev/null
	fi
	if [ "${NO_DATA_LOG:-0}" != 1 ] && mkdir -p "$OCDIR" 2>/dev/null; then
		printf '%s\n' "$log_line" >> "$OCDIR/$LOG_DATA_NAME" 2>/dev/null
	fi
	return 0
}

die() {
	log "abort: $*"
	return 1
}

# --- os-installer screen protocol ---------------------------------------------
# With UI=1 stdout goes to the os-installer app. One request per line; "\n"
# (two characters) in TEXT breaks lines, the first line is the title:
#   INFO ID TEXT                    status screen
#   PROGRESS N TOTAL                progress bar under the current INFO
#   CONFIRM ID DELAY TEXT|OK|CANCEL OK enabled DELAY seconds after arrival
#   MENU ID TEXT|ITEM|ITEM...       "-ITEM" is shown disabled
#   BLOCK ID TEXT                   no buttons; the user power-cycles
# The app answers "ANSWER ID ok|cancel|N" on stdin; EOF means cancel. Every
# other output line (log lines) only lands in the app's log viewer.

ui_emit() { [ "$UI" = 1 ] && printf '%s\n' "$*"; return 0; }

ui_info() {  # ui_info ID TEXT
	ui_emit "INFO $1 $2"
	log "screen $1: $2"
}

ui_progress() { ui_emit "PROGRESS $1 $2"; }

# ui_block ID TEXT: show TEXT without buttons and stop. With the app the
# installer waits for it to go away (the user power-cycles); exit 1 lets
# the stock hook boot on.
ui_block() {
	if [ "${CHECK:-0}" = 1 ]; then
		log "check: would block at $1: $2"
		exit 1
	fi
	ui_emit "BLOCK $1 $2"
	log "install: BLOCKED at $1: $2"
	sync
	[ "$UI" = 1 ] && cat > /dev/null
	exit 1
}

# ui_answer ID -> the app's answer for ID; "cancel" on EOF. Other lines are
# logged (to stderr: callers capture stdout).
ui_answer() {
	while IFS= read -r ua_line; do
		case "$ua_line" in
		"ANSWER $1 "*) printf '%s\n' "${ua_line#"ANSWER $1 "}"; return 0 ;;
		*) log "ui: ignored '$ua_line'" >&2 ;;
		esac
	done
	echo cancel
}

# ui_confirm ID DELAY TEXT OK CANCEL NONUI [PROMPT] -> 0 ok, 1 cancel. An ok
# that arrives before DELAY seconds passed is treated as cancel. Without the
# app NONUI decides: ok, cancel, or ask (PROMPT + "Type YES" on a terminal).
ui_confirm() {
	if [ "$UI" = 1 ]; then
		uc_t0=$(date +%s)
		ui_emit "CONFIRM $1 $2 $3|$4|$5"
		uc_v=$(ui_answer "$1")
		uc_dt=$(($(date +%s) - uc_t0))
		log "confirm $1: $uc_v"
		[ "$uc_v" = ok ] || return 1
		if [ "$uc_dt" -lt "$2" ]; then
			log "confirm $1: ok arrived after ${uc_dt}s, before the $2 s delay; treating as cancel"
			return 1
		fi
		return 0
	fi
	case "$6" in
	ok) return 0 ;;
	cancel) return 1 ;;
	esac
	# the stock hook may run with the serial console as stdin: never ask there
	{ [ "${HOOK:-0}" != 1 ] && [ -t 0 ]; } || abort "confirm $1: no display and no --yes"
	printf '%s Type YES: ' "${7:-$3}"
	read -r uc_v
	[ "$uc_v" = YES ]
}

# ui_menu ID TEXT ITEM... -> UI_CHOICE = chosen 1-based index, 0 for cancel
# (a variable: the request itself goes to stdout).
ui_menu() {
	if [ "$UI" != 1 ]; then
		case "${ACTION:-}" in swap) UI_CHOICE=2 ;; repair-stock) UI_CHOICE=3 ;; install | update) UI_CHOICE=1 ;; *) UI_CHOICE=0 ;; esac
		return 0
	fi
	um_id=$1 um_line="MENU $1 $2"
	shift 2
	for um_i in "$@"; do um_line="$um_line|$um_i"; done
	ui_emit "$um_line"
	um_v=$(ui_answer "$um_id")
	log "menu $um_id: $um_v"
	case "$um_v" in '' | *[!0-9]*) UI_CHOICE=0 ;; *) UI_CHOICE=$um_v ;; esac
}

# --- partitions ----------------------------------------------------------------

# part_table: "NAME NR START SIZE" (sectors) per GPT entry, the format of
# tools/printer/phase0.sh's partmap.txt, from the fdisk -l listing stock's
# mmc_name_to_dev parses (NR START END SIZE NAME; name last).
part_table() {
	"$C5_FDISK" -l "$C5_DISK" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $NF, $1, $2, $3 - $2 + 1 }'
}

# flag_ensure_own SLOT: before writing any partition, the boot flag must name
# the running slot, so a power loss mid-write still boots stock.
flag_ensure_own() {
	fe_now=$(c5_flag_slot)
	[ "$fe_now" = "$1" ] && return 0
	log "flag: boot flag names slot $fe_now ('$(c5_flag_read)') but slot $1 is running; pointing it back at slot $1 before writing"
	c5_flag_write "$1" || { log "flag: write to slot $1 FAILED (now '$(c5_flag_read)')"; return 1; }
	log "flag: boot flag -> slot $1 ('$(c5_flag_read)')"
}

# --- images and checksums ------------------------------------------------------

# magic_str FILE -> first 4 bytes (slot.sh's c5_magic_hex gives them as hex)
magic_str() { head -c 4 "$1" 2>/dev/null; }

file_bytes() { wc -c < "$1" | tr -d ' '; }

# squashfs_bytes DEV -> bytes_used from the superblock (le64 at offset 40).
# Stock busybox od has no -j/-A, so read the low 32 bits with hexdump (the SoC
# is little-endian and squashfs images here are far below 4 GiB).
squashfs_bytes() {
	sb_n=$(hexdump -s 40 -n 4 -e '1/4 "%u"' "$1" 2>/dev/null)
	case "$sb_n" in '' | *[!0-9]*) return 1 ;; esac
	echo "$sb_n"
}

# sum_init: pick sha256sum + SHA256SUMS, or md5sum + MD5SUMS when stock lacks it
sum_init() {
	if [ "${C5_SUM:-}" = md5sum ] || ! command -v sha256sum > /dev/null 2>&1; then
		SUM=md5sum SUMS=MD5SUMS
	else
		SUM=sha256sum SUMS=SHA256SUMS
	fi
	command -v "$SUM" > /dev/null 2>&1
}

file_sum() { "$SUM" < "$1" | cut -d' ' -f1; }

# dev_sum DEV LEN: checksum of the first LEN bytes of DEV
dev_sum() { head -c "$2" "$1" | "$SUM" | cut -d' ' -f1; }

# sums_get SUMSFILE PATH -> recorded checksum of PATH
sums_get() {
	awk -v p="$2" '{ f = $2; sub(/^\*/, "", f); sub(/^\.\//, "", f); if (f == p) { print $1; exit } }' "$1"
}

# sums_verify DIR SUMSFILE: every entry of SUMSFILE (paths relative to DIR)
# must exist and match. Prints the first failing path.
sums_verify() {
	sv_bad=$(awk '{ f = $2; sub(/^\*/, "", f); sub(/^\.\//, "", f); print $1, f }' "$1/$2" | while read -r sv_sum sv_path; do
		if [ ! -f "$1/$sv_path" ] || [ "$(file_sum "$1/$sv_path")" != "$sv_sum" ]; then
			echo "$sv_path"
			break
		fi
	done)
	[ -z "$sv_bad" ] || { echo "$sv_bad"; return 1; }
	[ -s "$1/$2" ]
}

# free_bytes DIR -> available bytes on the filesystem holding DIR
free_bytes() {
	fb_k=$(df -k "$1" 2>/dev/null | awk 'NR > 1 && NF >= 4 && $(NF-2) ~ /^[0-9]+$/ { a = $(NF-2) } END { print a }')
	case "$fb_k" in '' | *[!0-9]*) return 1 ;; esac
	echo $((fb_k * 1024))
}

# used_bytes DIR -> used bytes on the filesystem holding DIR
used_bytes() {
	ub_k=$(df -k "$1" 2>/dev/null | awk 'NR > 1 && NF >= 4 && $(NF-3) ~ /^[0-9]+$/ { u = $(NF-3) } END { print u }')
	case "$ub_k" in '' | *[!0-9]*) return 1 ;; esac
	echo $((ub_k * 1024))
}

# shq STRING -> STRING single-quoted for sh
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --- Wi-Fi credentials from stock's wpa_supplicant.conf ----------------------

# wpa_blocks FILE -> one line per network={} block with an ssid=:
#   INDEX<TAB>DISABLED<TAB>PRIORITY<TAB>SSID_RAW<TAB>KEY_RAW
# KEY_RAW is psk= (or sae_password= when there is no psk=), may be empty.
wpa_blocks() {
	tr -d '\r' < "$1" | awk '
		function out() { if (inb && ssid != "") printf "%d\t%d\t%d\t%s\t%s\n", n, dis, pri, ssid, (psk != "" ? psk : sae) }
		!inb && /^[ \t]*network[ \t]*=[ \t]*\{/ { inb = 1; n++; ssid = psk = sae = ""; dis = pri = 0; next }
		inb && /^[ \t]*\}/ { out(); inb = 0; next }
		inb { l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l)
		      e = index(l, "="); if (!e) next
		      k = substr(l, 1, e - 1); v = substr(l, e + 1)
		      if (k == "ssid") ssid = v; else if (k == "psk") psk = v
		      else if (k == "sae_password") sae = v
		      else if (k == "disabled") dis = v + 0; else if (k == "priority") pri = v + 0 }'
}

# wpa_pick FILE -> the wpa_blocks line of the network to use: enabled
# blocks only; highest priority=, then one with a key over an open one,
# then the newest (wpa_supplicant's update_config appends new networks).
wpa_pick() {
	wpa_blocks "$1" | awk -F '\t' '$2 == 0 {
		k = ($5 != "") ? 1 : 0
		if (!found || $3 > bp || ($3 == bp && k >= bk)) { found = 1; bp = $3; bk = k; best = $0 } }
		END { if (found) print best; else exit 1 }'
}

# ssid_value RAW: quoted -> contents; unquoted even-length hex -> decoded
ssid_value() {
	case "$1" in
	\"*) wpa_value "$1" ;;
	*) if [ -n "$1" ] && ! printf '%s' "$1" | grep -q '[^0-9A-Fa-f]' && [ $((${#1} % 2)) = 0 ]; then
			hex_decode "$1"
		else
			printf '%s' "$1"
		fi ;;
	esac
}

hex_decode() {
	printf '%s' "$1" | awk '{ h = "0123456789abcdef"; t = tolower($0); s = ""
		for (i = 1; i < length(t); i += 2)
			s = s sprintf("%c", (index(h, substr(t, i, 1)) - 1) * 16 + index(h, substr(t, i + 1, 1)) - 1)
		printf "%s", s }'
}

# wpa_value RAW: "quoted" -> contents, anything else unchanged
wpa_value() {
	case "$1" in
	\"*\"*) wv=${1#\"}; printf '%s' "${wv%\"*}" ;;
	*) printf '%s' "$1" ;;
	esac
}

# First line of a wifi.conf written by wifi_conf; a wifi.conf without it was
# written by hand and is left alone by callers that check.
WIFI_CONF_AUTO="# from stock wpa_supplicant.conf (wifi_conf)"

# wifi_conf WPA_CONF OUT: write OUT as shell-sourceable SSID='...' PSK='...'
# (mode 600; what OpenWrt's c5-wifi-sta reads) from the network wpa_pick
# chooses. Prints the SSID. Returns 1 when no enabled block has an ssid=,
# 2 when OUT cannot be written.
wifi_conf() {
	wc_line=$(wpa_pick "$1") || return 1
	wc_ssid=$(ssid_value "$(printf '%s' "$wc_line" | cut -f4)")
	[ -n "$wc_ssid" ] || return 1
	wc_psk=$(wpa_value "$(printf '%s' "$wc_line" | cut -f5-)")
	(
		umask 077
		{ echo "$WIFI_CONF_AUTO"; echo "SSID=$(shq "$wc_ssid")"; echo "PSK=$(shq "$wc_psk")"; } > "$2.new" &&
			chmod 600 "$2.new" 2>/dev/null; mv -f "$2.new" "$2"
	) || return 2
	printf '%s\n' "$wc_ssid"
}
