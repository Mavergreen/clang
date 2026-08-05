#!/bin/sh
# The CI helpers must be INERT without their env vars (local builds unaffected) and active with them.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$ROOT"; export REPO_ROOT
. "$ROOT/build/lib.sh"

# --- mav_ccache_args: empty unless requested AND available -------------------------------------
[ -z "$(MAVERICKS_USE_CCACHE= mav_ccache_args)" ] || { echo "FAIL: ccache args leaked when unset"; exit 1; }
# Unset explicitly rather than trusting the ambient env: CI (and run-repo-tests under it) exports
# MAVERICKS_USE_CCACHE=1 job-wide, so a test of the *absent* case must control the var itself.
[ -z "$(unset MAVERICKS_USE_CCACHE; mav_ccache_args)" ] || { echo "FAIL: ccache args leaked when var absent entirely"; exit 1; }

# Both remaining branches are driven off a controlled PATH rather than off whatever this machine
# happens to have installed. Keying on the real ccache would silently skip the requested-and-available
# case on any box without it -- which is the ONLY case CI ever takes, so it is the one that must not
# go untested. The helper probes with `command -v`, so a stub is indistinguishable from the real thing.
_stub="$(mktemp -d "${TMPDIR:-/tmp}/mavci.XXXXXX")"; printf '#!/bin/sh\nexit 0\n' > "$_stub/ccache"; chmod +x "$_stub/ccache"
_empty="$(mktemp -d "${TMPDIR:-/tmp}/mavci.XXXXXX")"
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

echo "OK ci-helpers-test"
