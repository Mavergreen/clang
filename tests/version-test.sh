#!/bin/sh
# Drives the version wrapper with a synthetic tag set (MAVERICKS_TAGS) so it never touches git.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"

# No tags yet for this upstream -> N=1, RELEASE=yes
out="$(MAVERICKS_TAGS="" sh "$ROOT/build/version.sh" auto)"
echo "$out" | grep -qx 'FULL=22.1.1-mavericks.1' || { echo "FAIL auto/no-tags FULL: $out"; exit 1; }
echo "$out" | grep -qx 'RELEASE=yes'             || { echo "FAIL auto/no-tags RELEASE: $out"; exit 1; }

# Existing tag -> auto keeps N, RELEASE=no
out="$(MAVERICKS_TAGS='22.1.1-mavericks.1
22.1.1-mavericks.3' sh "$ROOT/build/version.sh" auto)"
echo "$out" | grep -qx 'FULL=22.1.1-mavericks.3' || { echo "FAIL auto/tags FULL: $out"; exit 1; }
echo "$out" | grep -qx 'RELEASE=no'              || { echo "FAIL auto/tags RELEASE: $out"; exit 1; }

# local -> N=max+1, RELEASE=yes
out="$(MAVERICKS_TAGS='22.1.1-mavericks.3' sh "$ROOT/build/version.sh" local)"
echo "$out" | grep -qx 'FULL=22.1.1-mavericks.4' || { echo "FAIL local FULL: $out"; exit 1; }

# versions.sh exports the pins the build reads
( . "$ROOT/build/versions.sh"
  [ "$LLVM_VERSION" = "22.1.1" ] || { echo "FAIL LLVM_VERSION=$LLVM_VERSION"; exit 1; }
  [ "$TARGET_TRIPLE" = "x86_64-apple-macos10.9" ] || { echo "FAIL TARGET_TRIPLE=$TARGET_TRIPLE"; exit 1; }
  [ -n "$MLS_VERSION" ] || { echo "FAIL MLS_VERSION empty"; exit 1; }
  case "$LLVM_SRC_URL" in *"$LLVM_VERSION"*) : ;; *) echo "FAIL LLVM_SRC_URL=$LLVM_SRC_URL"; exit 1 ;; esac
) || exit 1

echo "OK version-test"
