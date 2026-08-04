#!/bin/sh
# Thin wrapper: the logic lives in shared-cmake (scripts/release-notes-file.sh). Only the product
# name is ours -- and it carries the LINE, because clang-22 and a future clang-23 are separate
# products with separate release notes.
#   usage: release-notes-file.sh <TAG> <FULL_VERSION>
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
. "$SELF/msc.sh"
CLANG_LINE="${CLANG_LINE:-22}"
exec sh "$MSC/release-notes-file.sh" "${1:?TAG required}" "${2:?FULL version required}" "Clang for Mavericks $CLANG_LINE"
