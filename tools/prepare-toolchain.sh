#!/bin/bash
# Reuse TC, or fetch and unpack the pinned Ingenic r6 toolchain into ~/ing.
# Prints the ready toolchain directory on stdout; diagnostics go to stderr.
# Env: TC, INGENIC_TOOLCHAIN_TARBALL, INGENIC_DOWNLOAD_DIR, WORK,
#      INGENIC_FTP_USER, INGENIC_FTP_PASS.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/ingenic-download.sh"
NAME=mips-xburst2-linux-toolchain-r6.0.0
TARBALL=$NAME.tar.bz2
SHA256=4e3359e32c2fb7d9e573ce84370220a66e3998bb911452d82267394fad4086e0
URL=ftp://ftp.ingenic.com.cn/Ingenic-MIPS-Toolchain/releases/ingenic-mips-toolchain-r6.0.0/$TARBALL
CACHE=${INGENIC_DOWNLOAD_DIR:-${WORK:-$HOME/build/opencreator-os}/downloads}
die() { echo "toolchain: $*" >&2; exit 1; }

if [ "${TC+x}" = x ]; then
	[ -x "$TC/bin/mips-xburst2-linux-gnu-gcc" ] || die "no mips-xburst2-linux-gnu-gcc in $TC/bin"
else
	TC=$HOME/ing/$NAME
	if [ "${INGENIC_TOOLCHAIN_TARBALL+x}" = x ] && [ ! -f "$INGENIC_TOOLCHAIN_TARBALL" ]; then
		die "toolchain archive not found: $INGENIC_TOOLCHAIN_TARBALL"
	fi
	if [ ! -x "$TC/bin/mips-xburst2-linux-gnu-gcc" ]; then
		if [ -e "$TC" ] || [ -L "$TC" ]; then
			die "incomplete toolchain at $TC; move it aside before preparing again"
		fi
		ARCHIVE=$(ingenic_archive INGENIC_TOOLCHAIN_TARBALL "$CACHE" "$TARBALL" sha256sum "$SHA256" "$URL")
		mkdir -p "$HOME/ing"
		STAGE=$(mktemp -d "$HOME/ing/.toolchain.XXXXXX")
		trap 'rm -rf -- "$STAGE"' EXIT
		echo "toolchain: unpacking $ARCHIVE" >&2
		tar -xjf "$ARCHIVE" -C "$STAGE" >&2
		[ -x "$STAGE/$NAME/bin/mips-xburst2-linux-gnu-gcc" ] || die "$NAME/bin/mips-xburst2-linux-gnu-gcc not found in $ARCHIVE"
		mv -- "$STAGE/$NAME" "$TC"
	fi
fi
TC=$(cd "$TC" && pwd)
printf '%s\n' "$TC"
