#!/bin/sh
# The shipped fetch_sdk.sh exits 2 if sdk-pins.sh is not staged beside it (fetch_sdk.sh's own guard),
# so build-cross.sh's libexec cp must always carry sdk-pins.sh along with fetch_sdk.sh. Regression
# test: assert the cp line still names all three, in the same directory.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"

line="$(grep -n 'cp "\$SHIPYARD_SCRIPTS/fetch_sdk.sh"' "$ROOT/build/build-cross.sh")"
[ -n "$line" ] || { echo "FAIL: no libexec cp of fetch_sdk.sh found in build/build-cross.sh"; exit 1; }
case "$line" in
  *'$SHIPYARD_SCRIPTS/sdk-pins.sh'*) : ;;
  *) echo "FAIL: build/build-cross.sh's libexec cp dropped sdk-pins.sh: $line"; exit 1 ;;
esac

echo "OK libexec-sdk-pins-test"
