#!/bin/sh
# platform: macOS-only -- verify-relocatable.sh reads the staged Mach-O with otool
# SKIP (77) until the toolchain is staged; otherwise assert the audit passes on the staged prefix.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
STAGE="$WORK/stage$CROSS_PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "not built -- skipping"; exit 77; }
sh "$ROOT/build/verify-relocatable.sh" "$STAGE"
echo "OK relocatable-test"
