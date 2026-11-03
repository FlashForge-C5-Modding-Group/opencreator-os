#!/bin/sh
# shellcheck disable=SC1091,SC3043
# Second stage of the install, run on OpenWrt by /usr/libexec/c5-stage2 until it
# succeeds or the user declines: pick Wi-Fi, pick a web UI, download the printer
# stack and install it on /data. See docs/stage2.md.
#
#   stage2.sh [--ui]
#
# --ui   screens through the os-installer app. Without it: saved Wi-Fi, the
#        default web UI, and an exit at the first failure.
#
# Overridable: STAGE2_DIR, STAGE2_MANIFEST_URL, C5_STACK_DIR.

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
C5_SYSTEM=openwrt
export C5_DATA=${C5_DATA:-/data}
LOG_DATA_NAME=stage2.log
. "$SELF_DIR/lib.sh"

UI=0
[ "${1:-}" = --ui ] && UI=1
STAGE2_DIR=${STAGE2_DIR:-$OCDIR/stage2}
STACK_DIR=${C5_STACK_DIR:-$C5_DATA/printer}
DL=$STAGE2_DIR/download
WIFI_CONF=/etc/c5/wifi.conf
DEFAULT_MANIFEST_URL=https://github.com/FlashForge-C5-Modding-Group/opencreator-os/releases/download/stack/manifest
WEBUI_TIMEOUT=120

manifest_url() {
	if [ -n "${STAGE2_MANIFEST_URL:-}" ]; then echo "$STAGE2_MANIFEST_URL"
	elif [ -s "$STAGE2_DIR/manifest-url" ]; then tr -d '\r\n' < "$STAGE2_DIR/manifest-url"
	else echo "$DEFAULT_MANIFEST_URL"; fi
}

online() {
	curl -sS -o /dev/null -m 10 --connect-timeout 8 "$(manifest_url)" -r 0-0 2> /dev/null
}

# TLS needs a real clock; the board has no battery-backed time at first boot.
wait_clock() {
	wc_i=0
	while [ "$(date +%Y)" -lt 2026 ] && [ "$wc_i" -lt 60 ]; do
		[ "$wc_i" != 0 ] || ntpd -q -n -p pool.ntp.org > /dev/null 2>&1 &
		wc_i=$((wc_i + 1))
		sleep 1
	done
}

# --- Wi-Fi --------------------------------------------------------------------

# The interface to scan on: the client's if it is up, else a temporary one.
scan_iface() {
	si=$(iw dev 2> /dev/null | awk '$1 == "Interface" { print $2; exit }')
	if [ -z "$si" ]; then
		si_phy=$(iw phy 2> /dev/null | awk '$1 == "Wiphy" { print $2; exit }')
		[ -n "$si_phy" ] || return 1
		si=c5scan0
		iw phy "$si_phy" interface add "$si" type managed 2> /dev/null || return 1
	fi
	ip link set "$si" up 2> /dev/null
	echo "$si"
}

# wifi_scan -> ENC<TAB>SSID per network, strongest first, no duplicates. Names
# the menu protocol cannot carry are left out; "Other network" reaches them.
wifi_scan() {
	ws_if=$(scan_iface) || return 1
	iwinfo "$ws_if" scan 2> /dev/null | awk '
		/ESSID: "/ { s = $0; sub(/^[^"]*"/, "", s); sub(/"[ \t]*$/, "", s) }
		/Signal:/ { q = $2 + 0 }
		/Encryption:/ {
			e = ($2 == "none") ? "open" : "key"
			if (s != "" && s !~ /[|\\]/ && !(s in seen)) { seen[s] = 1; printf "%d\t%s\t%s\n", q, e, s }
			s = ""
		}' | sort -rn | cut -f2- | head -n 20
	ws_rc=$?
	[ "$ws_if" != c5scan0 ] || iw dev c5scan0 del 2> /dev/null
	return "$ws_rc"
}

wifi_connect() {  # wifi_connect SSID PSK
	(
		umask 077
		mkdir -p /etc/c5
		{ echo "SSID=$(shq "$1")"; echo "PSK=$(shq "$2")"; } > "$WIFI_CONF.new" &&
			mv -f "$WIFI_CONF.new" "$WIFI_CONF" &&
			cp "$WIFI_CONF" "$OCDIR/wifi.conf"
	) || return 1
	# c5-wifi-sta only creates a missing client
	uci -q delete wireless.c5sta
	uci -q commit wireless
	/usr/libexec/c5-wifi-sta --wait 10
	wc_i=0
	while [ "$wc_i" -lt 45 ]; do
		ifstatus wwan 2> /dev/null | grep -q '"up": true' && return 0
		wc_i=$((wc_i + 1))
		sleep 1
	done
	return 1
}

# ui_text ID TEXT -> UI_TEXT, 1 on cancel
ui_text() {
	ui_emit "TEXT $1 $2"
	ut_v=$(ui_answer "$1")
	case "$ut_v" in =*) UI_TEXT=${ut_v#=}; return 0 ;; esac
	return 1
}

wifi_pick() {
	ui_info wifi-scan "Wi-Fi\nLooking for networks."
	wp_list=$(wifi_scan) || wp_list=
	wp_clean=/tmp/c5-stage2-scan
	printf '%s\n' "$wp_list" | grep -v '^$' > "$wp_clean"
	# shellcheck disable=SC2046
	set --
	while IFS="$(printf '\t')" read -r _ wp_s; do
		# a leading "-" would mean disabled
		case "$wp_s" in -*) wp_s=" $wp_s" ;; esac
		set -- "$@" "$wp_s"
	done < "$wp_clean"
	wp_n=$#
	ui_menu wifi "Choose your Wi-Fi network\nThe printer stack is downloaded over this network." "$@" "Other network" "Search again" "Set up later"
	case "$UI_CHOICE" in
	0) return 2 ;;
	$((wp_n + 3))) return 2 ;;
	$((wp_n + 2))) return 1 ;;
	$((wp_n + 1)))
		ui_text wifi-ssid "Network name" || return 1
		wp_ssid=$UI_TEXT
		wp_enc=key
		;;
	*)
		wp_line=$(sed -n "${UI_CHOICE}p" "$wp_clean")
		wp_enc=$(printf '%s' "$wp_line" | cut -f1)
		wp_ssid=$(printf '%s' "$wp_line" | cut -f2-)
		;;
	esac
	wp_psk=
	if [ "$wp_enc" = key ]; then
		ui_text wifi-psk "Password for $wp_ssid\nLeave empty for an open network." || return 1
		wp_psk=$UI_TEXT
	fi
	ui_info wifi-join "Connecting to $wp_ssid"
	if wifi_connect "$wp_ssid" "$wp_psk" && { wait_clock; online; }; then
		log "wifi: connected to '$wp_ssid'"
		return 0
	fi
	log "wifi: cannot reach the download server through '$wp_ssid'"
	ui_confirm wifi-fail 0 "Could not connect to $wp_ssid\nCheck the password and that the network has internet access." "Try again" "Set up later" cancel || return 2
	return 1
}

network_ready() {
	if [ "$UI" != 1 ]; then
		/usr/libexec/c5-wifi-sta --wait 10
		wait_clock
		online
		return
	fi
	ui_info net-check "Checking the network"
	wait_clock
	if online; then
		ui_menu net-have "Network connected\nThis printer already has internet access." "Continue" "Choose another Wi-Fi network"
		[ "$UI_CHOICE" = 2 ] || return 0
	fi
	while :; do
		wifi_pick
		case $? in 0) return 0 ;; 2) return 1 ;; esac
	done
}

# --- web UI -------------------------------------------------------------------

# Fluidd unless told otherwise: nobody may be at the printer.
pick_webui() {
	WEBUI=fluidd
	[ "$UI" = 1 ] || return 0
	ui_emit "MENU webui Choose a web interface\nFluidd is chosen after $((WEBUI_TIMEOUT / 60)) minutes if nothing is tapped.|Fluidd|Mainsail"
	pw_v=
	while IFS= read -r -t "$WEBUI_TIMEOUT" pw_line; do
		case "$pw_line" in "ANSWER webui "*) pw_v=${pw_line#ANSWER webui }; break ;; esac
	done
	[ "$pw_v" = 2 ] && WEBUI=mainsail
	log "webui: $WEBUI"
}

# --- download -----------------------------------------------------------------

# fetch NAME: the manifest line "SHA256 BYTES NAME URL" -> $DL/NAME, resumed
# after an interruption, with the progress bar following the file's size.
fetch() {
	fe_line=$(awk -v n="$1" '$3 == n { print; exit }' "$DL/manifest")
	[ -n "$fe_line" ] || { log "download: $1 is not in the manifest"; return 1; }
	fe_sum=$(echo "$fe_line" | cut -d' ' -f1)
	fe_size=$(echo "$fe_line" | cut -d' ' -f2)
	fe_url=$(echo "$fe_line" | cut -d' ' -f4)
	if [ -f "$DL/$1" ] && [ "$(sha256sum < "$DL/$1" | cut -d' ' -f1)" = "$fe_sum" ]; then
		log "download: $1 already here"
		return 0
	fi
	ui_info "dl-$1" "$2\n$((fe_size / 1048576)) MB. Do not power off."
	curl -fsSL --retry 5 --retry-delay 5 --connect-timeout 20 -C - -o "$DL/$1.part" "$fe_url" 2>> "$OCDIR/$LOG_DATA_NAME" &
	fe_pid=$!
	while kill -0 "$fe_pid" 2> /dev/null; do
		ui_progress "$(file_bytes "$DL/$1.part" 2> /dev/null || echo 0)" "$fe_size"
		sleep 2
	done
	wait "$fe_pid" || { log "download: $1 failed"; return 1; }
	if [ "$(sha256sum < "$DL/$1.part" | cut -d' ' -f1)" != "$fe_sum" ]; then
		log "download: $1 checksum mismatch"
		rm -f "$DL/$1.part"
		return 1
	fi
	mv -f "$DL/$1.part" "$DL/$1"
}

download() {
	mkdir -p "$DL" || return 1
	curl -fsSL --retry 3 --connect-timeout 20 -o "$DL/manifest.new" "$(manifest_url)" 2>> "$OCDIR/$LOG_DATA_NAME" &&
		mv -f "$DL/manifest.new" "$DL/manifest" || { log "download: no manifest at $(manifest_url)"; return 1; }
	fetch stack.tar.gz "Downloading Kalico, Moonraker and GrumpyScreen" &&
		fetch "$WEBUI.tar.gz" "Downloading $WEBUI"
}

# --- install ------------------------------------------------------------------

install_stack() {
	ui_info stack-install "Installing the printer software\nThis takes a few minutes. Do not power off."
	is_new=$STACK_DIR.new
	rm -rf "$is_new"
	mkdir -p "$is_new/www" || return 1
	tar -xzf "$DL/stack.tar.gz" -C "$is_new" || { log "install: cannot unpack the stack"; return 1; }
	tar -xzf "$DL/$WEBUI.tar.gz" -C "$is_new/www" || { log "install: cannot unpack $WEBUI"; return 1; }
	echo "$WEBUI" > "$is_new/webui"
	# user configuration and history survive a repeated run
	if [ -d "$STACK_DIR" ]; then
		rm -rf "$STACK_DIR.old"
		mv -f "$STACK_DIR" "$STACK_DIR.old" || return 1
	fi
	mv -f "$is_new" "$STACK_DIR" || return 1
	C5_MODEL_FILE=$OCDIR/model sh "$STACK_DIR/install.sh" "$STACK_DIR" || { log "install: the stack's install.sh failed"; return 1; }
	rm -rf "$STACK_DIR.old"
	sync
}

# --- main ---------------------------------------------------------------------

finish_done() {
	rm -f "$STAGE2_DIR/pending"
	rm -rf "$DL"
	: > "$STAGE2_DIR/done"
	sync
	log "stage2: done ($WEBUI)"
	ui_menu stage2-done "Your printer is ready\n$WEBUI is at http://$(uname -n).local or this printer's IP address." "Restart"
	reboot_now
	exit 0
}

# ask_later TEXT: 0 to try again; otherwise stops, keeping or dropping pending
ask_later() {
	if [ "$UI" != 1 ]; then log "stage2: $1; trying again next boot"; exit 1; fi
	ui_menu stage2-fail "$1" "Try again" "Ask at next boot" "Don't ask again"
	case "$UI_CHOICE" in
	1) return 0 ;;
	3)
		rm -f "$STAGE2_DIR/pending"
		: > "$STAGE2_DIR/declined"
		log "stage2: declined"
		;;
	esac
	sync
	exit 0
}

log "stage2: start (ui=$UI)"
until network_ready; do
	ask_later "No network yet\nThe printer software needs an internet connection to download."
done
pick_webui
until download; do
	ask_later "Download failed\nThe log has the details. Finished downloads are kept."
done
until install_stack; do
	ask_later "Install failed\nThe log has the details."
done
finish_done
