#!/bin/sh
# The CI helpers must be INERT without their env vars (local builds unaffected) and active with them.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$ROOT"; export REPO_ROOT
. "$ROOT/build/lib.sh"

# --- mav_ccache_args: empty unless requested AND available -------------------------------------
[ -z "$(MAVERICKS_USE_CCACHE= mav_ccache_args)" ] || { echo "FAIL: ccache args leaked when unset"; exit 1; }
[ -z "$(mav_ccache_args)" ] || { echo "FAIL: ccache args leaked when var absent entirely"; exit 1; }

# Both remaining branches are driven off a controlled PATH rather than off whatever this machine
# happens to have installed. Keying on the real ccache would silently skip the requested-and-available
# case on any box without it -- which is the ONLY case CI ever takes, so it is the one that must not
# go untested. The helper probes with `command -v`, so a stub is indistinguishable from the real thing.
_stub="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$_stub/ccache"; chmod +x "$_stub/ccache"
_empty="$(mktemp -d)"
case "$(PATH="$_stub:$PATH" MAVERICKS_USE_CCACHE=1 mav_ccache_args)" in
  *-DCMAKE_C_COMPILER_LAUNCHER=ccache*) : ;;
  *) echo "FAIL: ccache args missing when requested and available"; rm -rf "$_stub" "$_empty"; exit 1 ;;
esac
case "$(PATH="$_stub:$PATH" MAVERICKS_USE_CCACHE=1 mav_ccache_args)" in
  *-DCMAKE_CXX_COMPILER_LAUNCHER=ccache*) : ;;
  *) echo "FAIL: only the C launcher was set"; rm -rf "$_stub" "$_empty"; exit 1 ;;
esac
[ -z "$(PATH="$_empty" MAVERICKS_USE_CCACHE=1 mav_ccache_args)" ] \
  || { echo "FAIL: ccache args emitted though ccache is not on PATH"; rm -rf "$_stub" "$_empty"; exit 1; }
rm -rf "$_stub" "$_empty"

# --- mav_ninja: an expired deadline yields the incomplete sentinel without running ninja ---------
# `rc=0; cmd || rc=$?`, never `cmd; rc=$?`: under set -e the bare form exits this script at the
# failing command and the assertion below never runs -- the exact trap shared-cmake's
# run-repo-tests.sh documents.
rc=0; MAVERICKS_BUILD_DEADLINE=1 mav_ninja --version >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || { echo "FAIL: expired deadline should return 75, got $rc"; exit 1; }

# --- mav_ninja: a LIVE deadline must actually run ninja and succeed ------------------------------
# This is the case that catches a bounding mechanism which does not exist on this platform: macOS
# ships no timeout(1), so an implementation that shells out to it returns 127 -> 75 and reports every
# build "INCOMPLETE (hit the budget)" when nothing of the sort happened.
if command -v ninja >/dev/null 2>&1; then
  rc=0; MAVERICKS_BUILD_DEADLINE=$(( $(date +%s) + 3600 )) mav_ninja --version >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: live deadline should run ninja and succeed, got $rc"; exit 1; }
  # ...and with no deadline at all, the plain path.
  rc=0; mav_ninja --version >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: unbounded mav_ninja should succeed, got $rc"; exit 1; }
else
  echo "note: ninja absent -- skipped the live-deadline assertions"
fi

echo "OK ci-helpers-test"
