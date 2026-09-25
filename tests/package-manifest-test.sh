#!/bin/sh
# platform: macOS-only -- pkgbuild, productbuild and PlistBuddy build and read the two archives
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
: "${SHIPYARD_SCRIPTS:=$R/../mavergreen-shipyard/scripts}"
[ -f "$SHIPYARD_SCRIPTS/stage_product.sh" ] || { echo "no shipyard with stage_product.sh at $SHIPYARD_SCRIPTS -- skipping" >&2; exit 77; }
command -v pkgbuild >/dev/null 2>&1 || { echo "no pkgbuild -- skipping" >&2; exit 77; }
export SHIPYARD_SCRIPTS
W="$(mktemp -d "${TMPDIR:-/tmp}/package-manifest.XXXXXX")"
keep=""; [ ! -f "$R/VERSION" ] || keep=yes
trap 'rm -rf "$W"; [ -n "$keep" ] || rm -f "$R/VERSION"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
export MAVERICKS_WORK="$W/work" DIST="$W/dist" UPD_APP=""
. "$R/build/versions.sh"
mk() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; chmod 755 "$1"; }
for t in "$WORK/stage-native$NATIVE_PREFIX" "$WORK/stage$CROSS_PREFIX"; do
  for f in bin/clang "bin/clang-$CLANG_LINE" bin/clang++ bin/clang.cfg bin/clang++.cfg bin/portable-ld bin/llvm-ar; do mk "$t/$f"; done
  mkdir -p "$t/SDKs" "$t/share/man/man1"; : > "$t/share/man/man1/scan-build.1"
done
sh "$R/build/package-native-pkg.sh" > "$W/native.log" 2>&1 || { cat "$W/native.log"; fail "the native archive must package from a staged tree"; }
sh "$R/build/package-cross-pkg.sh" > "$W/cross.log" 2>&1 || { cat "$W/cross.log"; fail "the cross archive must package from a staged tree"; }
V="$W/vol"; mkdir -p "$V"
for p in "$DIST"/mavericks-clang-*-native-*.pkg "$DIST"/mavericks-clang-*-cross-*.pkg; do
  [ -f "$p" ] || fail "no archive at $p"
  x="$W/x-$(basename "$p")"; pkgutil --expand "$p" "$x"
  [ "$(sed -n 's/.*<line choice="\([^"]*\)".*/\1/p' "$x/Distribution" | grep -v '^default$' | head -1)" = dev.mavergreen.base ] \
    || fail "$(basename "$p"): the base component comes first"
  for comp in "$x"/*.pkg; do (cd "$V" && gzip -dc "$comp/Payload" | cpio -id --quiet); done
  grep -q "mkdir -p \"\$ROOT/usr/local/mavergreen/var/" "$x"/mavericks-clang-*-component.pkg/Scripts/postinstall \
    || fail "$(basename "$p"): the postinstall creates the tree's var-backed SDKs directory"
done
grep -q 'os-version min="11.0"' "$W"/x-mavericks-clang-*-cross-*.pkg/Distribution || fail "the cross archive's floor is 11.0 (R3)"
N="clang$CLANG_LINE"; X="clang$CLANG_LINE-cross"
[ "$(readlink "$V/usr/local/mavergreen/$N/SDKs")" = "../var/$N/SDKs" ] || fail "SDKs is a link into var/, so an upgrade keeps what a user put there (C1)"
[ "$(readlink "$V/usr/local/mavergreen/$X/SDKs")" = "../var/$X/SDKs" ] || fail "the cross tree's SDKs is var-backed too"
pb() { /usr/libexec/PlistBuddy -c "Print :$2" "$V/usr/local/mavergreen/$1/mavergreen.plist"; }
[ "$(pb "$N" group)/$(pb "$N" line)" = "clang/$CLANG_LINE" ] || fail "$N is group clang, line $CLANG_LINE"
[ "$(pb "$X" group)/$(pb "$X" line)" = "clang/$CLANG_LINE-cross" ] || fail "$X is group clang, line $CLANG_LINE-cross"
MG() { sh "$SHIPYARD_SCRIPTS/mavergreen.sh" --root "$V" "$@"; }
MG link "$N" || fail "linking the native toolchain must succeed"
MG link "$X" || fail "linking the cross toolchain beside the native one must succeed"
MG check || fail "a box with both toolchains installed must pass mavergreen check"
F="$V/usr/local/mavergreen"
[ "$(MG select clang)" = "$N" ] || fail "the first member installed keeps the selection; installing the second never takes it"
[ "$(readlink "$F/bin/clang")" = "../$N/bin/clang" ] || fail "bare clang belongs to the selected member, the native toolchain"
[ "$(readlink "$F/bin/clang-$CLANG_LINE")" = "../$N/bin/clang" ] || fail "clang-$CLANG_LINE is the native driver, not the real binary bin/clang-$CLANG_LINE"
[ "$(readlink "$F/bin/clang-$CLANG_LINE-cross")" = "../$X/bin/clang" ] || fail "clang-$CLANG_LINE-cross is the cross driver, selected or not"
[ "$(readlink "$F/share/man/man1/scan-build-$CLANG_LINE.1")" = "../../../$N/share/man/man1/scan-build.1" ] || fail "scan-build's manpage is exported with its line"
MG select clang "$X" || fail "select must move the clang group to the cross toolchain"
[ "$(readlink "$F/bin/clang")" = "../$X/bin/clang" ] && [ "$(readlink "$F/bin/llvm-ar")" = "../$X/bin/llvm-ar" ] \
  || fail "after select, every bare name belongs to the cross toolchain"
[ "$(readlink "$F/bin/clang-$CLANG_LINE")" = "../$N/bin/clang" ] \
  || fail "select must leave clang-$CLANG_LINE on the native driver (R4 excludes the cross tree's real bin/clang-$CLANG_LINE; Task A6 refuses the takeover anyway)"
MG check || fail "mavergreen check must stay clean after select"
for gone in "clang.cfg-$CLANG_LINE" "portable-ld-$CLANG_LINE" "clang-$CLANG_LINE-$CLANG_LINE" "clang-$CLANG_LINE-$CLANG_LINE-cross" clang.cfg portable-ld "clang.cfg-$CLANG_LINE-cross" "portable-ld-$CLANG_LINE-cross"; do
  [ ! -e "$F/bin/$gone" ] && [ ! -L "$F/bin/$gone" ] || fail "$gone must not be exported"
done
echo "PASS: package-manifest"
