#!/bin/sh
# platform: macOS-only -- pkgbuild and productbuild (via build_component_pkg.sh and set_install_floor.sh) build the installer archive
# Package the staged cross toolchain as a product archive with an 11.0 floor: it RUNS on modern macOS
# (arm64) and only TARGETS 10.9. Emits build-info-cross.txt.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
STAGE="$WORK/stage$CROSS_PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "FATAL: run build-cross.sh first" >&2; exit 1; }
VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
DIST="${DIST:-$HERE/../dist}"; mkdir -p "$DIST"
PAYLOAD="$WORK/stage"     # DESTDIR root; contains .$CROSS_PREFIX
NAME="mavericks-clang-${CLANG_LINE}-cross-$VER.pkg"
# BUILD the pkg on LOCAL disk, then move the finished artifact into dist/. dist/ is inside the repo,
# which on a dev box is an NFS mount: pkgbuild writes a ~2.2GB payload as many small random writes,
# which NFS serves at ~170KB/s -- an hour for what takes minutes locally. One sequential move at the
# end costs a fraction of that. On CI dist/ is runner-local and this is a no-op either way.
STAGING_OUT="$WORK/out"; mkdir -p "$STAGING_OUT"
OUT="$STAGING_OUT/$NAME"

rm -rf "$STAGE/SDKs"; ln -s "../var/clang${CLANG_LINE}-cross/SDKs" "$STAGE/SDKs"
hook="$STAGING_OUT/postinstall-hook-cross"
printf '#!/bin/sh\n# platform: host-agnostic\nmkdir -p "$ROOT/usr/local/mavergreen/var/clang%s-cross/SDKs"\n' "$CLANG_LINE" > "$hook"

UPD_APP="${UPD_APP:-}"
UPD_DIR="/Library/Application Support/Mavergreen"
UPD_LABEL="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" agent-label "clang${CLANG_LINE}-cross")"
scr="$STAGING_OUT/pkg-scripts-cross"; rm -rf "$scr"
set -- --stage "$PAYLOAD" --product "clang${CLANG_LINE}-cross" --name "Clang ${CLANG_LINE} cross toolchain for Mavericks" \
  --group clang --line "${CLANG_LINE}-cross" --version "$VER" \
  --exclude "bin/clang-${CLANG_LINE}" --exclude bin/clang.cfg --exclude bin/clang++.cfg --exclude bin/portable-ld \
  --postinstall-hook "$hook" --scripts-out "$scr"
if [ -n "$UPD_APP" ] && [ -d "$UPD_APP" ]; then
  set -- "$@" --updater-app "$UPD_APP"
else
  echo ">> WARNING: no updater at '$UPD_APP'; packaging the toolchain alone (build it: shipyard-cmake --build \"\$MAVERICKS_BUILD_ROOT/clang-updater-cross\" --target clang${CLANG_LINE}-cross-updater)" >&2
  rm -rf "$PAYLOAD$UPD_DIR" "$PAYLOAD/Library/LaunchAgents/$UPD_LABEL.plist"
fi
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true
sh "$SHIPYARD_SCRIPTS/stage_product.sh" "$@"

comp="$STAGING_OUT/mavericks-clang-${CLANG_LINE}-cross-component.pkg"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" \
  --root "$PAYLOAD" \
  --identifier "$CROSS_IDENTIFIER" \
  --version "$VER" \
  --install-location "/" \
  --scripts "$scr" \
  --out "$comp" >/dev/null
sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" \
  --identifier "$CROSS_IDENTIFIER" \
  --title "Clang for Mavericks ${CLANG_LINE} (cross) — LLVM ${LLVM_VERSION}, builds 10.9 programs on modern macOS" \
  --component "$comp" --out "$OUT" --min-os 11.0 --host-arch arm64 --require-scripts
rm -f "$comp" "$STAGING_OUT/mavericks-clang-${CLANG_LINE}-cross-component-components.plist"
mv "$OUT" "$DIST/$NAME"
pkg="$DIST/$NAME"
echo "built $pkg"

# What this variant was built FROM (conformance compares variants; a reader can see it).
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$DIST/build-info-cross.txt" \
  variant=cross arch=arm64 prefix="$CROSS_PREFIX" pkg="$(basename "$pkg")" identifier="$CROSS_IDENTIFIER" \
  llvm="$LLVM_VERSION" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
cat "$DIST/build-info-cross.txt"
