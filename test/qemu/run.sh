#!/usr/bin/env bash
# opencreator-os QEMU system tests (WSL/Linux, no root needed).
#
#   test/qemu/run.sh [-j N] [SCENARIO...]     default: all (S1-S10, S12-S17)
#
# Boots the real OpenWrt root.squashfs and the stock 2.0.0 userspace on an
# emulated eMMC with the printer's GPT, emulates the SPL's slot choice, and
# runs end-to-end install / boot / fallback / upgrade / restore scenarios.
# -j N runs N scenarios at once (default: half the CPUs; -j 1: one by one).
# Prints PASS / FAIL / SKIP per scenario; exits 1 if any scenario failed.
# See test/qemu/README.md.
#
# Environment: QWORK, OWRT_BIN, QEMU_REFRESH_ROOTFS (default 1), QEMU_CPU,
# QEMU_AIO, QEMU_BOOT_TIMEOUT, QEMU_JOBS (-j), KEEP_RUNS (default 3) - see
# lib/env.sh and the README.
export PYTHONDONTWRITEBYTECODE=1
set -uo pipefail

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=lib/scenarios.sh
. "$QDIR/lib/scenarios.sh"

usage() { sed -n '2,15s/^# \{0,1\}//p' "$0"; }

JOBS=${QEMU_JOBS:-$(($(nproc) / 2))}
SCEN=()
while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help) usage; exit 0 ;;
	-j) JOBS=${2:-}; shift; [ $# -gt 0 ] && shift ;;
	-j*) JOBS=${1#-j}; shift ;;
	*) SCEN+=("$1"); shift ;;
	esac
done
case "$JOBS" in '' | *[!0-9]* | 0) echo "-j needs a positive number" >&2; exit 2 ;; esac
[ ${#SCEN[@]} -gt 0 ] || read -r -a SCEN <<< "$ALL_SCENARIOS"
for s in "${SCEN[@]}"; do
	declare -F "scenario_$s" > /dev/null || { echo "unknown scenario $s (known: $ALL_SCENARIOS)" >&2; exit 2; }
done

for t in qemu-system-mipsel python3 sgdisk sfdisk mkfs.ext4 debugfs mkfs.vfat mcopy mtype mdir mksquashfs unsquashfs git flock; do
	command -v "$t" > /dev/null || { echo "missing host tool: $t" >&2; exit 2; }
done

"$QDIR/kernel/build.sh" || exit 2
# the install stick ships a static sfdisk and partx for the repartition
{ [ -x "$QREPO/installer/tools/out/sfdisk" ] && [ -x "$QREPO/installer/tools/out/partx" ]; } ||
	"$QREPO/installer/tools/build.sh" || exit 2
build_stock_fixture || exit 2
build_base_disk || exit 2

RUNID=$(date +%Y%m%d-%H%M%S)
RUNROOT=$QWORK/runs/$RUNID
mkdir -p "$RUNROOT"
# keep the last KEEP_RUNS run directories (images are sparse but large)
ls -1d "$QWORK"/runs/2*/ 2>/dev/null | head -n -"${KEEP_RUNS:-3}" | xargs -r rm -rf

OWRT_OK=1
build_openwrt_fixture || OWRT_OK=0
if [ "$OWRT_OK" = 1 ]; then
	echo "OpenWrt artifacts: $OWRT_ART-* (refresh base-files: ${QEMU_REFRESH_ROOTFS:-1})"
	remember_base
else
	echo "OpenWrt root.squashfs not found ($OWRT_ART-root.squashfs): every scenario is skipped" >&2
fi
echo "runs: $RUNROOT (${JOBS} at a time)"

# run_scenario S: scenario_S in $RUNROOT/S; the result line goes to
# $RUNROOT/S/result, the duration to $RUNROOT/S/seconds
run_scenario() {
	local s=$1 start rc dur res
	RUN=$RUNROOT/$s FAILS=0 BOOTN=0 SKIP_WHY=
	mkdir -p "$RUN"
	if [ "$OWRT_OK" = 0 ]; then
		res="SKIP (no OpenWrt root.squashfs)"
	else
		echo "=== $s"
		start=$(date +%s)
		"scenario_$s"
		rc=$?
		dur=$(($(date +%s) - start))
		if [ "$rc" = 77 ]; then
			res="SKIP ($SKIP_WHY)"
		elif [ "$FAILS" = 0 ] && [ "$rc" = 0 ]; then
			res="PASS (${BOOTN} boots, ${dur}s)"
			echo "$dur" > "$RUN/seconds"
		else
			res="FAIL ($FAILS failed checks, ${BOOTN} boots, ${dur}s; see $RUN)"
		fi
		# images of passed scenarios are dropped; failed ones stay for inspection
		case "$res" in PASS* | SKIP*) rm -f "$RUN"/*.img "$RUN"/*.tar ;; esac
	fi
	echo "$res" > "$RUN/result"
	echo "$s: $res"
}

# Scheduling for -j N > 1: the scenarios that reuse $COMMITTED_BY's image
# (prepare_committed) start after it; the rest by the duration of their
# last passing run, longest first, so the long ones do not end up last.
TIMES=$QWORK/scenario-times
selected() { [[ " ${SCEN[*]} " == *" $1 "* ]]; }
needs_committed() { [ "$1" != "$COMMITTED_BY" ] && declare -f "scenario_$1" | grep -q prepare_committed; }
start_order() {
	local s t
	for s in "${SCEN[@]}"; do
		t=$(awk -v s="$s" '$1 == s { t = $2 } END { print t + 0 }' "$TIMES" 2>/dev/null)
		[ "$s" = "$COMMITTED_BY" ] && t=999999
		echo "${t:-0} $s"
	done | sort -s -k1,1nr | awk '{ print $2 }'
}

declare -A FINISHED=() JOB=()
if [ "$JOBS" -gt 1 ]; then
	mapfile -t pending < <(start_order)
else
	pending=("${SCEN[@]}")
fi
# scenarios run as background jobs, which ignore SIGINT: stop them (and
# their QEMUs) with us
trap 'trap - INT TERM; kill 0 2>/dev/null; exit 130' INT TERM
running=0
while [ ${#pending[@]} -gt 0 ] || [ "$running" -gt 0 ]; do
	rest=()
	for s in "${pending[@]}"; do
		if [ "$running" -lt "$JOBS" ] &&
			{ ! needs_committed "$s" || ! selected "$COMMITTED_BY" || [ -n "${FINISHED[$COMMITTED_BY]:-}" ]; }; then
			if [ "$JOBS" -gt 1 ]; then SAY_TAG="$s: "; fi
			run_scenario "$s" &
			JOB[$!]=$s
			running=$((running + 1))
		else
			rest+=("$s")
		fi
	done
	pending=("${rest[@]}")
	[ "$running" -gt 0 ] || { echo "nothing left to start: ${pending[*]}" >&2; exit 2; }
	wait -n -p pid
	FINISHED[${JOB[$pid]}]=1
	running=$((running - 1))
done

echo
echo "Summary ($RUNROOT):"
failed=0
for s in "${SCEN[@]}"; do
	res=$(cat "$RUNROOT/$s/result" 2>/dev/null) || res="FAIL (no result; see $RUNROOT/$s)"
	echo "  $s $res"
	case "$res" in FAIL*) failed=1 ;; esac
done
# durations of passing runs for the next start order
{
	cat "$TIMES" 2>/dev/null
	for s in "${SCEN[@]}"; do
		[ -s "$RUNROOT/$s/seconds" ] && echo "$s $(cat "$RUNROOT/$s/seconds")"
	done
} | awk '{ t[$1] = $2 } END { for (s in t) print s, t[s] }' | sort > "$TIMES.new" && mv "$TIMES.new" "$TIMES"
rm -f "$RUNROOT/committed.img" "$RUNROOT/committed.lock"
exit "$failed"
