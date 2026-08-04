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
: "${MSC_SCRIPTS:?need shared-cmake}"
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
sh "$MSC_SCRIPTS/assert_binary_compatible.sh" "$@"

echo "==> best-effort Rosetta smoke (never gates)"
# Functional stand-in for a real 10.9 run. Non-gating on purpose: Rosetta's willingness to run a
# min-10.9 x86_64 binary on macOS 26 is not something this repo controls, and a released toolchain is
# validated out-of-band on real hardware before it is trusted.
if [ ! -e "$STAGE/SDKs/MacOSX10.9.sdk" ]; then
  SDK="$(sh "$MSC_SCRIPTS/fetch_sdk.sh")"; mkdir -p "$STAGE/SDKs"; ln -sfn "$SDK" "$STAGE/SDKs/MacOSX10.9.sdk"
fi
softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true
t="$(mktemp -d)"
printf '#include <iostream>\nint main(){std::cout<<"hi\\n";return 0;}\n' > "$t/h.cpp"
if arch -x86_64 "$STAGE/bin/clang++" "$t/h.cpp" -o "$t/h" 2>"$t/err"; then
  if lipo -archs "$t/h" | grep -qw x86_64; then
    echo "    rosetta smoke: the native clang++ ran and built an x86_64 binary"
    "$t/h" >/dev/null 2>&1 && echo "    rosetta smoke: its output also ran"
  fi
else
  echo "    rosetta smoke: skipped/failed (non-gating): $(head -1 "$t/err")"
fi
rm -rf "$t"
echo "OK smoke-native"
