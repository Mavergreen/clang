#!/bin/sh
# The cross toolchain's OWN Mach-O must record the family's SDK pins: the arm64 host tools minos 11.0
# against the 11.3 SDK. build-cross.sh takes hours on a macOS runner, so this asserts statically that
# its one LLVM configure still passes the settings that do it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
B="$ROOT/build/build-cross.sh"

# The configure is one command continued over many lines. Take exactly those lines, so a flag that is
# dropped, or moved out of the call, fails here.
cfg="$(awk '/^shipyard-cmake -G Ninja /{on=1} on{print; if ($0 !~ /\\$/) exit}' "$B")"
[ -n "$cfg" ] || { echo "FAIL: no shipyard-cmake configure found in build/build-cross.sh"; exit 1; }
has() {
  printf '%s\n' "$cfg" | grep -qF -- "$1" \
    || { echo "FAIL: build/build-cross.sh's configure no longer passes $1"; exit 1; }
}

has '-DCMAKE_OSX_ARCHITECTURES=arm64'
has '-DCMAKE_OSX_DEPLOYMENT_TARGET="$HOST_MACOS_MIN"'
has '-DCMAKE_OSX_SYSROOT="$HOST_SDK"'
grep -qxF 'HOST_SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch arm64)"' "$B" \
  || { echo "FAIL: build/build-cross.sh no longer takes HOST_SDK from fetch_sdk.sh --arch arm64"; exit 1; }
grep -qxF 'export HOST_MACOS_MIN="11.0"' "$ROOT/build/versions.sh" \
  || { echo "FAIL: build/versions.sh no longer pins HOST_MACOS_MIN to 11.0"; exit 1; }

echo "OK cross-sdk-pin-test"
