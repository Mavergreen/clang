#!/bin/sh
# platform: macOS-only -- pkgbuild and productbuild (via build_component_pkg.sh and set_install_floor.sh) build the installer archive
# Package the staged native toolchain: a flat component pkg wrapped in a product archive that enforces
# the 10.9.5 install floor. This variant RUNS on 10.9, so the floor is a REQUIREMENT (the cross pkg's
# is 11.0), and a bare component pkg cannot express it -- an OS floor is a productbuild/Distribution
# concept. Emits build-info-native.txt.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
export COPYFILE_DISABLE=1
STAGE="$WORK/stage-native$NATIVE_PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "FATAL: run build-native.sh first" >&2; exit 1; }
VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
DIST="${DIST:-$HERE/../dist}"; mkdir -p "$DIST"
PAYLOAD="$WORK/stage-native"
NAME="mavericks-clang-${CLANG_LINE}-native-$VER.pkg"
# Assemble on LOCAL disk and move the finished artifact into dist/ -- same reasoning as the cross
# packaging: pkgbuild's scratch dir lands next to its output, and on an NFS-hosted repo that turns
# minutes into an hour. On CI dist/ is runner-local and this is a no-op.
OUTDIR="$WORK/out"; mkdir -p "$OUTDIR"

rm -rf "$STAGE/SDKs"; ln -s "../var/clang${CLANG_LINE}/SDKs" "$STAGE/SDKs"
hook="$OUTDIR/postinstall-hook-native"
printf '#!/bin/sh\n# platform: host-agnostic\nmkdir -p "$ROOT/usr/local/mavergreen/var/clang%s/SDKs"\n' "$CLANG_LINE" > "$hook"

UPD_APP="${UPD_APP:-}"
UPD_DIR="/Library/Application Support/Mavergreen"
UPD_LABEL="$(sh "$SHIPYARD_SCRIPTS/product-name.sh" agent-label "clang${CLANG_LINE}")"
scr="$OUTDIR/pkg-scripts-native"; rm -rf "$scr"
set -- --stage "$PAYLOAD" --product "clang${CLANG_LINE}" --name "Clang ${CLANG_LINE} for Mavericks" \
  --group clang --line "$CLANG_LINE" --version "$VER" \
  --exclude "bin/clang-${CLANG_LINE}" --exclude bin/clang.cfg --exclude bin/clang++.cfg --exclude bin/portable-ld \
  --postinstall-hook "$hook" --scripts-out "$scr"
if [ -n "$UPD_APP" ] && [ -d "$UPD_APP" ]; then
  set -- "$@" --updater-app "$UPD_APP"
else
  echo ">> WARNING: no updater at '$UPD_APP'; packaging the toolchain alone (build it: shipyard-cmake --build \"\$MAVERICKS_BUILD_ROOT/clang-updater\" --target clang${CLANG_LINE}-updater)" >&2
  rm -rf "$PAYLOAD$UPD_DIR" "$PAYLOAD/Library/LaunchAgents/$UPD_LABEL.plist"
fi
find "$PAYLOAD" -name '._*' -delete 2>/dev/null || true
sh "$SHIPYARD_SCRIPTS/stage_product.sh" "$@"

comp="$OUTDIR/mavericks-clang-${CLANG_LINE}-native-component.pkg"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" \
  --root "$PAYLOAD" \
  --identifier "$NATIVE_IDENTIFIER" \
  --version "$VER" \
  --install-location "/" \
  --scripts "$scr" \
  --out "$comp" >/dev/null

sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" \
  --identifier "$NATIVE_IDENTIFIER" \
  --title "Clang for Mavericks ${CLANG_LINE} — LLVM ${LLVM_VERSION} for OS X 10.9" \
  --component "$comp" --out "$OUTDIR/$NAME" --host-arch x86_64 --require-scripts
rm -f "$comp" "$OUTDIR/mavericks-clang-${CLANG_LINE}-native-component-components.plist"
mv "$OUTDIR/$NAME" "$DIST/$NAME"
echo "built $DIST/$NAME"

# What this variant was built FROM. Conformance compares any key appearing in more than one variant,
# so llvm/legacy_support/target must match the cross record; variant/arch/prefix/pkg/identifier are
# the keys that are supposed to differ.
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$DIST/build-info-native.txt" \
  variant=native arch=x86_64 prefix="$NATIVE_PREFIX" pkg="$NAME" identifier="$NATIVE_IDENTIFIER" \
  llvm="$LLVM_VERSION" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
cat "$DIST/build-info-native.txt"
