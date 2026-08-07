#!/bin/sh
# Thin wrapper: the logic lives in shipyard (scripts/version.sh) so it cannot drift between repos.
# Every call site -- tests/version-test.sh, build/versions.sh, the release workflow, and a plain
# `sh build/version.sh auto` -- keeps working through this.
#
# A CLANG LINE (the LLVM major) is a product: clang-22 and a future clang-23 ship side by side, each
# with its own lines/<major>/UPSTREAM_VERSION, prefix, identifier and (later) update feed. Mirrors
# golang's GO_LINE / nodejs's NODE_LINE. Adding a line is one new lines/<major>/UPSTREAM_VERSION.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
CLANG_LINE="${CLANG_LINE:-22}"
MAVERICKS_UPSTREAM_FILE="$MAVERICKS_ROOT/lines/$CLANG_LINE/UPSTREAM_VERSION"; export MAVERICKS_UPSTREAM_FILE
[ -f "$MAVERICKS_UPSTREAM_FILE" ] || { echo "version.sh: no such line: lines/$CLANG_LINE" >&2; exit 1; }
. "$SELF/msc.sh"
exec sh "$SHIPYARD/version.sh" "$@"
