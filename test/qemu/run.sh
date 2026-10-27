#!/usr/bin/env bash
# opencreator-os QEMU system tests (WSL/Linux, no root needed).
#
#   test/qemu/run.sh [SCENARIO...]     default: all (S1..S11)
#
# Boots the real OpenWrt root.squashfs and the stock 2.0.0 userspace on an
# emulated eMMC with the printer's GPT, emulates the SPL's slot choice, and
# runs end-to-end install / boot / fallback / upgrade / restore scenarios.
# Prints PASS / FAIL / SKIP per scenario; exits 1 if any scenario failed.
# See test/qemu/README.md.
#
# Environment: QWORK, OWRT_BIN, QEMU_REFRESH_ROOTFS (default 1), QEMU_CPU,
# QEMU_BOOT_TIMEOUT, KEEP_RUNS (default 3) - see lib/env.sh and the README.
export PYTHONDONTWRITEBYTECODE=1
set -uo pipefail

# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=lib/scenarios.sh
. "$QDIR/lib/scenarios.sh"

usage() { sed -n '2,13s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h | --help) usage; exit 0 ;; esac

SCEN=("$@")
[ ${#SCEN[@]} -gt 0 ] || read -r -a SCEN <<< "$ALL_SCENARIOS"
for s in "${SCEN[@]}"; do
	declare -F "scenario_$s" > /dev/null || { echo "unknown scenario $s (known: $ALL_SCENARIOS)" >&2; exit 2; }
done

for t in qemu-system-mipsel python3 sgdisk sfdisk mkfs.ext4 debugfs mkfs.vfat mcopy mtype mdir mksquashfs unsquashfs git; do
	command -v "$t" > /dev/null || { echo "missing host tool: $t" >&2; exit 2; }
done

"$QDIR/kernel/build.sh" || exit 2
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
else
	echo "OpenWrt root.squashfs not found ($OWRT_ART-root.squashfs): every scenario is skipped" >&2
fi
echo "runs: $RUNROOT"

declare -A RESULT
for s in "${SCEN[@]}"; do
	RUN=$RUNROOT/$s
	mkdir -p "$RUN"
	FAILS=0 BOOTN=0 SKIP_WHY=
	if [ "$OWRT_OK" = 0 ]; then
		RESULT[$s]="SKIP (no OpenWrt root.squashfs)"
		echo "$s: ${RESULT[$s]}"
		continue
	fi
	remember_base
	echo "=== $s"
	start=$(date +%s)
	"scenario_$s"
	rc=$?
	dur=$(($(date +%s) - start))
	if [ "$rc" = 77 ]; then
		RESULT[$s]="SKIP ($SKIP_WHY)"
	elif [ "$FAILS" = 0 ] && [ "$rc" = 0 ]; then
		RESULT[$s]="PASS (${BOOTN} boots, ${dur}s)"
	else
		RESULT[$s]="FAIL ($FAILS failed checks, ${BOOTN} boots, ${dur}s; see $RUN)"
	fi
	echo "$s: ${RESULT[$s]}"
	# images of passed scenarios are dropped; failed ones stay for inspection
	case "${RESULT[$s]}" in PASS* | SKIP*) rm -f "$RUN"/*.img "$RUN"/*.tar ;; esac
done

echo
echo "Summary ($RUNROOT):"
failed=0
for s in "${SCEN[@]}"; do
	echo "  $s ${RESULT[$s]}"
	case "${RESULT[$s]}" in FAIL*) failed=1 ;; esac
done
rm -f "$RUNROOT/committed.img"
exit "$failed"
