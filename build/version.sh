#!/bin/sh
# platform: host-agnostic
# Thin wrapper: the logic lives in shipyard (scripts/version.sh) so it cannot drift between repos.
# Every call site -- tests/version-test.sh, build/versions.sh, the release workflow, and a plain
# `sh build/version.sh auto` -- keeps working through this.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT

# One repo ships ONE LLVM major LINE, from the root UPSTREAM_VERSION -- never a per-line file. The
# LINE is derived from the upstream version (22.1.1 -> 22), never configured separately:
# CMakeLists.txt already derives MAV_CLANG_LINE the same way, and two sources of truth for "which
# line is this" is how a repo builds 22 and stamps a clang23 identifier. A caller-supplied
# $CLANG_LINE is honoured only as a CHECK against the derived value, never as an override -- pairing
# CLANG_LINE=23 with a 22.x UPSTREAM_VERSION is a bug, not a way to build a different line.
_up_root="$MAVERICKS_ROOT/UPSTREAM_VERSION"
[ -f "$_up_root" ] || { echo "version.sh: no UPSTREAM_VERSION at repo root" >&2; exit 1; }
_derived_line="$(tr -d '[:space:]' < "$_up_root" | sed -n 's/^\([0-9][0-9]*\)\..*$/\1/p')"
[ -n "$_derived_line" ] || { echo "version.sh: cannot derive CLANG_LINE from $_up_root" >&2; exit 1; }
if [ -n "${CLANG_LINE:-}" ] && [ "$CLANG_LINE" != "$_derived_line" ]; then
  echo "version.sh: CLANG_LINE=$CLANG_LINE was given but $_up_root derives $_derived_line -- one source of truth" >&2
  exit 1
fi
CLANG_LINE="$_derived_line"
export CLANG_LINE
MAVERICKS_UPSTREAM_FILE="$_up_root"; export MAVERICKS_UPSTREAM_FILE
if [ "${1:-}" = line ]; then printf '%s\n' "$CLANG_LINE"; exit 0; fi

. "$SELF/msc.sh"
exec sh "$SHIPYARD/version.sh" "$@"
