#!/bin/sh
# Package the staged cross toolchain as a component .pkg. NO 10.9.5 install floor: this pkg RUNS on
# modern macOS (arm64) and only TARGETS 10.9 (golang cross-pkg precedent). Emits build-info-cross.txt.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${MSC_SCRIPTS:?need shared-cmake}"
export COPYFILE_DISABLE=1
STAGE="$WORK/stage$PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "FATAL: run build-cross.sh first" >&2; exit 1; }
VER="$(sh "$MSC_SCRIPTS/resolve-version.sh" "$(sh "$MSC_SCRIPTS/release-mode.sh")")"
DIST="$HERE/../dist"; mkdir -p "$DIST"
PAYLOAD="$WORK/stage"     # DESTDIR root; contains .$PREFIX
NAME="mavericks-clang-cross-$VER.pkg"
# BUILD the pkg on LOCAL disk, then move the finished artifact into dist/. dist/ is inside the repo,
# which on a dev box is an NFS mount: pkgbuild writes a ~2.2GB payload as many small random writes,
# which NFS serves at ~170KB/s -- an hour for what takes minutes locally. One sequential move at the
# end costs a fraction of that. On CI dist/ is runner-local and this is a no-op either way.
STAGING_OUT="$WORK/out"; mkdir -p "$STAGING_OUT"
OUT="$STAGING_OUT/$NAME"

# The Apple 10.9 SDK is NOT redistributed -- the pkg ships libexec/fetch_sdk.sh and the SDK arrives at
# first use. tests/smoke-target.sh legitimately populates SDKs/MacOSX10.9.sdk as a symlink into this
# machine's ~/Library/Caches to prove the clang.cfg path resolves; shipping that symlink would bake a
# build-machine path into the artifact. verify-relocatable.sh only audits Mach-O, so it cannot see a
# stray symlink -- strip it here, then assert nothing is left.
rm -rf "$STAGE/SDKs"; mkdir -p "$STAGE/SDKs"
[ -z "$(ls -A "$STAGE/SDKs" 2>/dev/null)" ] || { echo "FATAL: $STAGE/SDKs is not empty" >&2; exit 1; }

# AppleDouble sidecars are what an NFS-hosted stage sprays; they would ship as real payload files.
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true

pkg="$(sh "$MSC_SCRIPTS/build_component_pkg.sh" \
  --root "$PAYLOAD" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$VER" \
  --install-location "/" \
  --out "$OUT")"
mv "$pkg" "$DIST/$NAME"
rm -f "$STAGING_OUT/$(basename "$NAME" .pkg)-components.plist"
pkg="$DIST/$NAME"
echo "built $pkg"

# What this variant was built FROM (conformance compares variants; a reader can see it).
sh "$MSC_SCRIPTS/build-info.sh" "$DIST/build-info-cross.txt" \
  variant=cross arch=arm64 prefix="$PREFIX" pkg="$(basename "$pkg")" identifier="$PKG_IDENTIFIER" \
  llvm="$LLVM_VERSION" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
cat "$DIST/build-info-cross.txt"
