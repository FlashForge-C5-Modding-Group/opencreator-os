#!/bin/sh
# QEMU stand-in for the os-installer touchscreen app (busybox sh). Reads the
# installer's screen requests on stdin, writes ANSWER lines on stdout and
# echoes every input line to the console as "QEMU-UI <line>".
# Settings, from ui.conf next to this script (KEY=VALUE per line):
#   menu=N                         answer to MENU main (default 1)
#   confirm_<id>=ok|early|cancel   ok: wait out the button delay, then ok;
#                                  early: ok at once; cancel (default ok)
# BLOCK ends this script, which closes the installer's stdin.
conf=$(dirname "$0")/ui.conf
get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | tail -n 1; }

while IFS= read -r line; do
	printf 'QEMU-UI %s\n' "$line" > /dev/console
	set -f
	# shellcheck disable=SC2086
	set -- $line
	set +f
	case "${1:-}" in
	MENU)
		m=$(get menu)
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
	BLOCK) exit 0 ;;
	esac
done
