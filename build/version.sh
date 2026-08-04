#!/bin/sh
# Thin wrapper: the logic lives in shared-cmake (scripts/version.sh) so it cannot drift between repos.
# Every call site -- tests/version-test.sh, build/versions.sh, the release workflow, and a plain
# `sh build/version.sh auto` -- keeps working through this.
#
# Unlike golang (parallel Go minor LINES, one UPSTREAM_VERSION each), this repo ships ONE product from
# ONE upstream, so the root UPSTREAM_VERSION that shared-cmake reads by default is exactly right and
# there is nothing to point MAVERICKS_UPSTREAM_FILE at.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
. "$SELF/msc.sh"
exec sh "$MSC/version.sh" "$@"
