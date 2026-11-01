#!/bin/bash
# Fetch (if missing), verify and unpack Ingenic's X2600 SDK 6.6 kernel, then add
# our board DTS and patches. Prints the kernel source path on the last line.
#
#   kernel/prepare.sh [--work DIR]
#
# Env: INGENIC_SDK_TARBALL full path to an existing SDK archive (overrides DIR)
#      INGENIC_SDK_DIR     archive directory (default: shared downloads cache)
#      INGENIC_FTP_USER    default ingenic_public
#      INGENIC_FTP_PASS    default BFdg2f9B12 (Ingenic's public login)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/../tools/ingenic-download.sh"
WORK=${WORK:-$HOME/build/opencreator-os}
[ "${1:-}" = --work ] && WORK=$2
SDK_DIR=${INGENIC_SDK_DIR:-${INGENIC_DOWNLOAD_DIR:-$WORK/downloads}}
TARBALL=ingenic-linux-kernel6.6-x2600-v1.0-20250221.tar.bz2
FTP_URL=ftp://ftp.ingenic.com.cn/DevSupport/X2600E/01_SW/06_kernel6.6_x2600-sdk_v1.0-20250221/01_ingenic-linux-kernel6.6-x2600-v1.0-20250221/
MD5=2ae10ef28565e357051437c6262013e8
KSRC=$WORK/ingenic-6.6/kernel/kernel-6.6

log() { echo "prepare: $*" >&2; }
die() { log "$*"; exit 1; }

if [ "${INGENIC_SDK_TARBALL+x}" = x ] && [ ! -f "$INGENIC_SDK_TARBALL" ]; then
	die "SDK archive not found: $INGENIC_SDK_TARBALL"
fi

if [ ! -f "$KSRC/Makefile" ]; then
	ARCHIVE=$(ingenic_archive INGENIC_SDK_TARBALL "$SDK_DIR" "$TARBALL" md5sum "$MD5" "$FTP_URL$TARBALL")
	log "unpacking kernel/kernel-6.6"
	mkdir -p "$WORK/ingenic-6.6"
	tar -xjf "$ARCHIVE" -C "$WORK/ingenic-6.6" --strip-components=1 --wildcards '*/kernel/kernel-6.6/*'
	[ -f "$KSRC/Makefile" ] || die "kernel/kernel-6.6 not found in $ARCHIVE"
fi

ver=$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{print v"."p"."s}' "$KSRC/Makefile")
log "kernel $ver at $KSRC"
[ "$ver" = 6.6.18 ] || log "WARNING: expected 6.6.18"

install -m0644 "$HERE/dts/creator5pro.dts" "$KSRC/module_drivers/dts/x2600/creator5pro.dts"
for p in "$HERE"/patches/*.patch; do
	[ -e "$p" ] || continue
	# --fuzz=0 both ways: with fuzz, a reverse dry run of an unapplied patch
	# can succeed and the patch would be skipped as "already applied".
	if patch -d "$KSRC" -p1 -R --dry-run -s -f --fuzz=0 < "$p" >/dev/null 2>&1; then
		log "already applied: $(basename "$p")"
	else
		patch -d "$KSRC" -p1 -N -s --fuzz=0 < "$p" || die "patch failed: $(basename "$p")"
		log "applied: $(basename "$p")"
	fi
done
echo "$KSRC"
