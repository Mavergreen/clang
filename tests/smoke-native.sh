#!/bin/sh
# SKIP (77) until staged. Assert every shipped native HOST Mach-O is 10.9-safe (x86_64 + min 10.9 +
# no post-10.9 imports), then a best-effort Rosetta smoke.
#
# This is the check the cross variant COULD NOT run. There, the host tools are arm64 by design and
# only the emitted binary could be guarded; here the host tools ARE the 10.9 artifact, so the compat
# guard finally applies to the thing a Mavericks user actually executes.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/build/versions.sh"
: "${SHIPYARD_SCRIPTS:?need shipyard}"
STAGE="$WORK/stage-native$NATIVE_PREFIX"
[ -x "$STAGE/bin/clang" ] || { echo "not built -- skipping"; exit 77; }

echo "==> relocatability of the native prefix"
# Spec section 3 asks for this on the native prefix too, not just the cross one: the native tools are
# linked by a different build with different inputs, so "the cross prefix was clean" proves nothing
# about them.
sh "$ROOT/build/verify-relocatable.sh" "$STAGE"

echo "==> compat guard on shipped host Mach-O (x86_64 + min 10.9)"
# Collect first, then guard in ONE call: assert_binary_compatible.sh fails closed on an empty list
# ("CANNOT MEASURE"), so a stage that somehow contains no Mach-O is a failure rather than a silent
# pass. Non-Mach-O entries in bin/ (the .cfg files, the portable-ld shell wrapper) are skipped.
list="$(mktemp)"; trap 'rm -f "$list"' EXIT
for f in "$STAGE"/bin/*; do
  [ -f "$f" ] || continue
  file "$f" 2>/dev/null | grep -q 'Mach-O' || continue
  printf '%s\n' "$f" >> "$list"
done
# ...plus the reused target runtime dylibs, wherever the runtime layout put them (plain lib/ in this
# configuration, lib/<triple>/ under a per-target-runtime-dir build) -- hence find, not a fixed glob.
find "$STAGE/lib" \( -name 'libc++.*dylib' -o -name 'libc++abi.*dylib' -o -name 'libunwind.*dylib' \) \
  -type f >> "$list" 2>/dev/null || true
[ -s "$list" ] || { echo "FAIL: no Mach-O found under $STAGE/bin" >&2; exit 1; }
set --
while IFS= read -r b; do set -- "$@" "$b"; done < "$list"
echo "    guarding $# binaries"
sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$@"

echo "==> Rosetta functional smoke"
# Rosetta's AVAILABILITY never gates -- whether macOS 26 will run a min-10.9 x86_64 binary is not
# something this repo controls, and a release is validated out-of-band on real 10.9 hardware anyway.
#
# But "non-gating" must not mean "ignore the result", which is how this test first reported OK for a
# toolchain that could not compile a single C++ program: the native build produces no libc++ HEADERS
# (LLVM_ENABLE_RUNTIMES=""), they were not carried over from the cross stage, and every compile died
# with "'iostream' file not found" while the suite stayed green. So the two outcomes are separated:
#
#   Rosetta cannot run our binaries at all  -> SKIP, genuinely not our problem
#   Rosetta runs clang++ and the COMPILE fails -> FAIL, that is a broken product
#
# `clang++ --version` is the probe: if that executes, the toolchain runs here, and anything failing
# afterwards is a defect in what we shipped.
if [ ! -e "$STAGE/SDKs/MacOSX10.9.sdk" ]; then
  SDK="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"; mkdir -p "$STAGE/SDKs"; ln -sfn "$SDK" "$STAGE/SDKs/MacOSX10.9.sdk"
fi
softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
if ! arch -x86_64 "$STAGE/bin/clang++" --version >/dev/null 2>&1; then
  echo "    SKIP: cannot execute an x86_64/10.9 binary here (no Rosetta); validate on real hardware"
else
  echo "    Rosetta runs the native clang++ -- from here, failures are real defects"
  printf '#include <iostream>\nint main(){std::cout<<"hi\\n";return 0;}\n' > "$t/h.cpp"
  arch -x86_64 "$STAGE/bin/clang++" "$t/h.cpp" -o "$t/h" \
    || { echo "FAIL: the native clang++ cannot compile a hello world" >&2; exit 1; }
  lipo -archs "$t/h" | grep -qw x86_64 \
    || { echo "FAIL: the native clang++ emitted a non-x86_64 binary" >&2; exit 1; }
  sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$t/h"
  echo "    the native clang++ built a 10.9-safe x86_64 binary"
  "$t/h" >/dev/null 2>&1 && echo "    ...and its output runs too"
fi
echo "OK smoke-native"
