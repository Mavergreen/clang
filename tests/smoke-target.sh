#!/bin/sh
# SKIP (77) until staged. Compile hello.cpp with the cross clang, assert the OUTPUT and the shipped
# x86_64/10.9 runtimes are 10.9-safe (arch x86_64 + LC_VERSION_MIN_MACOSX 10.9, no post-10.9 imports).
#
# This is the in-CI equivalence proof that stands in for the absent 10.9 runner. It is deliberately
# an END-TO-END test: it invokes clang++ with NO flags at all, so it fails if clang.cfg stops being
# auto-loaded, if the default target drifts, or if the polyfill stops being linked -- the whole
# batteries-included claim, not just the presence of some files.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
: "${MSC_SCRIPTS:?need shared-cmake}"
STAGE="$WORK/stage$CROSS_PREFIX"
CLANGXX="$STAGE/bin/clang++"
[ -x "$CLANGXX" ] || { echo "not built -- skipping"; exit 77; }

# clang.cfg references <CFGDIR>/../SDKs/MacOSX10.9.sdk. The SDK is NOT redistributed (Apple's bytes),
# so the staged tree carries only an empty SDKs/; populate it here the same way an installed toolchain
# would at first use. build/package-cross-pkg.sh strips this again before packaging -- a symlink into
# ~/Library/Caches baked into a shipped .pkg is a build-machine path no user has.
if [ ! -e "$STAGE/SDKs/MacOSX10.9.sdk" ]; then
  mkdir -p "$STAGE/SDKs"
  SDK="$(sh "$MSC_SCRIPTS/fetch_sdk.sh")"; ln -sfn "$SDK" "$STAGE/SDKs/MacOSX10.9.sdk"
fi

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
cat > "$t/hello.cpp" <<'EOF'
#include <iostream>
int main(){ std::cout << "hello mavericks\n"; return 0; }
EOF
"$CLANGXX" "$t/hello.cpp" -o "$t/hello"
lipo -archs "$t/hello" | grep -qw x86_64 || { echo "FAIL: not x86_64"; exit 1; }

# The compat guard: assert the emitted binary is 10.9-safe. Do NOT point it at the arm64 host clang --
# it asserts arch x86_64 by design and would fail for the wrong reason.
sh "$MSC_SCRIPTS/assert_binary_compatible.sh" "$t/hello"

# ...and the shipped target runtime dylibs, if the runtimes build produced any. Discovered rather than
# assumed: LLVM lays per-target runtimes under lib/<triple>/ and the triple is the runtimes-build one
# (x86_64-apple-darwin), not the product's default target.
rtlib="$(find "$STAGE/lib" -name 'libc++.*dylib' -print 2>/dev/null | head -1)"
if [ -n "$rtlib" ]; then
  RTDIR="$(dirname "$rtlib")"
  for d in "$RTDIR"/libc++.*dylib "$RTDIR"/libc++abi.*dylib; do
    [ -f "$d" ] && sh "$MSC_SCRIPTS/assert_binary_compatible.sh" "$d"
  done
else
  echo "note: no target libc++ dylib staged (static-only runtimes); the emitted binary is the proof"
fi
echo "OK smoke-target"
