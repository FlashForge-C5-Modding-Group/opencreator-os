#!/bin/sh
# QEMU stand-in for the os-installer touchscreen app (busybox sh). Reads the
# installer's screen requests on stdin, writes ANSWER lines on stdout and
# echoes every input line to the console as "QEMU-UI <line>".
# Settings, from ui.conf next to this script (KEY=VALUE per line):
#   menu=N                         answer to every MENU (default 1)
#   menu_<id>=N                    answer to MENU <id>, before menu=
#   confirm_<id>=ok|early|cancel   ok: wait out the button delay, then ok;
#                                  early: ok at once; cancel (default ok)
#   hold=<id>                      before answering MENU/CONFIRM <id>, create
#                                  /tmp/qemu-ui-held and wait for
#                                  /tmp/qemu-ui-release (nobody tapped yet)
# BLOCK with a button ("TEXT|BUTTON") taps it: exit 1, as the app does;
# BLOCK without one ends this script with 0 (the app would stay up until
# power-off). Either closes the installer's stdin.
conf=$(dirname "$0")/ui.conf
get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | tail -n 1; }
hold=$(get hold)

while IFS= read -r line; do
	printf 'QEMU-UI %s\n' "$line" > /dev/console
	set -f
	# shellcheck disable=SC2086
	set -- $line
	set +f
	case "${1:-}" in
	MENU | CONFIRM)
		if [ -n "$hold" ] && [ "$2" = "$hold" ]; then
			: > /tmp/qemu-ui-held
			until [ -f /tmp/qemu-ui-release ]; do sleep 1; done
		fi
		;;
	esac
	case "${1:-}" in
	MENU)
		m=$(get "menu_$2")
		[ -n "$m" ] || m=$(get menu)
		printf 'ANSWER %s %s\n' "$2" "${m:-1}"
		;;
	CONFIRM)
		c=$(get "confirm_$2")
		case "${c:-ok}" in
		ok) sleep $(($3 + 1)); printf 'ANSWER %s ok\n' "$2" ;;
		early) printf 'ANSWER %s ok\n' "$2" ;;
		*) printf 'ANSWER %s cancel\n' "$2" ;;
		esac
		;;
	BLOCK)
		case "$line" in *'|'*) printf 'QEMU-UI-TAP %s\n' "${line##*|}" > /dev/console; exit 1 ;; esac
		exit 0
		;;
	esac
done
