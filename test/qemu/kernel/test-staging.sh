#!/usr/bin/env bash
# Exercise staging selection with an installed OpenWrt compiler, not a fake GCC.
# Usage: bash test/qemu/kernel/test-staging.sh COMPILER_PREFIX TARGET_STAGING_DIR
# No kernel build, network access, or changes to the toolchain/staging trees.
set -euo pipefail

[ "$#" = 2 ] || { echo "usage: $0 COMPILER_PREFIX TARGET_STAGING_DIR" >&2; exit 2; }
PREFIX=$1
EXPECTED_STAGE=$(realpath "$2")
[ -d "$EXPECTED_STAGE/usr/include" ] || { echo "target staging headers not found: $2" >&2; exit 2; }
COMPILER=$(command -v "${PREFIX}gcc")
case "${COMPILER##*/}" in
*-openwrt-*-gcc) ;;
*) echo "an installed OpenWrt compiler is required" >&2; exit 2 ;;
esac
COMPILER=$(realpath "$COMPILER")
PREFIX=${COMPILER%gcc}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A different OpenWrt checkout must not supply the selected compiler's stage.
export OWRT_DIR=$WORK/other-openwrt OWRT_BIN=$WORK/no-artifacts
mkdir -p "$OWRT_DIR/staging_dir/target-mipsel_mips32_musl" "$WORK/explicit/usr/include"
# shellcheck source=../lib/env.sh
. "$(dirname "$0")/../lib/env.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
compile_null() {
	"${CC_PREFIX}gcc" -ffreestanding -c -x c /dev/null -o "$WORK/null.o" 2>"$WORK/diagnostics"
	[ ! -s "$WORK/diagnostics" ] || { cat "$WORK/diagnostics" >&2; fail "compiler emitted diagnostics"; }
}

test_selected_compiler_stage() {
	local CROSS_COMPILE STAGING_DIR CC_PREFIX
	unset STAGING_DIR
	export CROSS_COMPILE=$PREFIX
	CC_PREFIX=$(pick_cross_compile)
	set_openwrt_staging_dir "$CC_PREFIX"
	[ "$STAGING_DIR" = "$EXPECTED_STAGE" ] || fail "stage did not follow the selected compiler"
	compile_null
	# Check the real driver's include search, not just the shell variable.
	"${CC_PREFIX}gcc" -E -v -x c /dev/null >"$WORK/preprocessed" 2>"$WORK/search"
	grep -Fxq " $EXPECTED_STAGE/usr/include" "$WORK/search" || fail "target headers are absent from GCC's include search"
}

test_empty_stage_and_path_prefix() {
	local CROSS_COMPILE STAGING_DIR CC_PREFIX
	local PATH=$PATH
	export STAGING_DIR='' CROSS_COMPILE=${PREFIX##*/}
	PATH="$(dirname "$COMPILER"):$PATH"
	export PATH
	CC_PREFIX=$(pick_cross_compile)
	set_openwrt_staging_dir "$CC_PREFIX"
	[ "$STAGING_DIR" = "$EXPECTED_STAGE" ] || fail "empty stage or PATH compiler selection was not handled"
	compile_null
}

printf '#define STAGING_PROBE 37\n' >"$WORK/explicit/usr/include/staging-probe.h"
printf '#include <staging-probe.h>\nint stage_check[STAGING_PROBE == 37 ? 1 : -1];\n' >"$WORK/explicit.c"
test_explicit_stage() {
	local CROSS_COMPILE STAGING_DIR CC_PREFIX
	export STAGING_DIR=$WORK/explicit CROSS_COMPILE=$PREFIX
	CC_PREFIX=$(pick_cross_compile)
	set_openwrt_staging_dir "$CC_PREFIX"
	[ "$STAGING_DIR" = "$WORK/explicit" ] || fail "explicit stage was replaced"
	# This header exists only in the caller's stage. Overwriting that stage
	# makes the actual compiler fail, even if auto-selection otherwise works.
	"${CC_PREFIX}gcc" -ffreestanding -c "$WORK/explicit.c" -o "$WORK/explicit.o" 2>"$WORK/diagnostics"
	[ ! -s "$WORK/diagnostics" ] || { cat "$WORK/diagnostics" >&2; fail "explicit stage compile emitted diagnostics"; }
}

test_non_openwrt_compiler() {
	local STAGING_DIR CC_PREFIX
	unset STAGING_DIR
	CC_PREFIX=$(command -v gcc)
	CC_PREFIX=${CC_PREFIX%gcc}
	set_openwrt_staging_dir "$CC_PREFIX"
	[ "${STAGING_DIR+x}" != x ] || fail "non-OpenWrt compiler received an automatic stage"
	compile_null
	export STAGING_DIR=$WORK/explicit
	set_openwrt_staging_dir "$CC_PREFIX"
	[ "$STAGING_DIR" = "$WORK/explicit" ] || fail "non-OpenWrt compiler lost the caller's stage"
	compile_null
}

test_selected_compiler_stage
test_empty_stage_and_path_prefix
test_explicit_stage
test_non_openwrt_compiler
echo "PASS: actual compiler staging selection and explicit-stage precedence"
