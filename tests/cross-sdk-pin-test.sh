#!/bin/sh
# The cross toolchain's OWN Mach-O must record the family's SDK pins: the arm64 host tools minos 11.0
# against the 11.3 SDK, the compiler-rt builtins x86_64 only at 10.9 against the 10.9 SDK.
# build-cross.sh takes hours on a macOS runner, so this asserts statically that its one LLVM configure
# still passes the settings that do it, and runs the one source edit on a copy of the upstream lines.
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

# The compiler-rt builtins: their own x86_64-apple-darwin sub-build, against the 10.9 SDK, x86_64 only,
# no iOS and no Mac Catalyst.
has '-DLLVM_BUILTIN_TARGETS="$RUNTIME_TARGET"'
has '"-DBUILTINS_${RUNTIME_TARGET}_CMAKE_OSX_SYSROOT=$SDK"'
has '"-DBUILTINS_${RUNTIME_TARGET}_DARWIN_macosx_CACHED_SYSROOT=$SDK"'
has '"-DBUILTINS_${RUNTIME_TARGET}_DARWIN_osx_BUILTIN_ARCHS=x86_64"'
has '"-DBUILTINS_${RUNTIME_TARGET}_COMPILER_RT_ENABLE_IOS=OFF"'
has '"-DBUILTINS_${RUNTIME_TARGET}_COMPILER_RT_ENABLE_MACCATALYST=OFF"'

# ...and their minimum, which only a source edit can set: it must run after the unpack and before the
# configure, on the file compiler-rt reads it from.
order="$(awk '
  /^rm -rf "\$SRC"; tar -xf / { unpack = NR }
  /^mav_pin_builtins_min_ver "\$SRC\/compiler-rt\/cmake\/builtin-config-ix\.cmake" "\$MACOS_MIN"/ { pin = NR }
  /^shipyard-cmake -G Ninja / { cfg = NR }
  END { print (unpack && pin > unpack && cfg > pin) ? "ok" : "bad" }' "$B")"
[ "$order" = ok ] \
  || { echo "FAIL: build/build-cross.sh must mav_pin_builtins_min_ver the unpacked builtin-config-ix.cmake to \$MACOS_MIN before configuring"; exit 1; }

# The edit itself, on the upstream lines it rewrites.
: "${REPO_ROOT:=$ROOT}"; export REPO_ROOT
. "$ROOT/build/lib.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/cross-sdk-pin.XXXXXX")"; trap 'rm -rf "$t"' EXIT
upstream() {
  printf '%s\n' '  set(DARWIN_EMBEDDED_PLATFORMS)' \
    "  set(DARWIN_osx_BUILTIN_MIN_VER $1)" \
    '  set(DARWIN_osx_BUILTIN_MIN_VER_FLAG' \
    '      -mmacosx-version-min=${DARWIN_osx_BUILTIN_MIN_VER})'
}
upstream 10.7 > "$t/bci.cmake"; upstream 10.9 > "$t/want"
mav_pin_builtins_min_ver "$t/bci.cmake" 10.9 \
  || { echo "FAIL: mav_pin_builtins_min_ver refused the upstream line"; exit 1; }
cmp -s "$t/bci.cmake" "$t/want" \
  || { echo "FAIL: mav_pin_builtins_min_ver did not rewrite exactly the minimum:"; diff "$t/want" "$t/bci.cmake" || :; exit 1; }
# A file whose line has changed upstream (here: already rewritten) is refused and left as it was.
if mav_pin_builtins_min_ver "$t/bci.cmake" 10.9 2>/dev/null; then
  echo "FAIL: mav_pin_builtins_min_ver accepted a file without the upstream 10.7 line"; exit 1
fi
cmp -s "$t/bci.cmake" "$t/want" || { echo "FAIL: a refused mav_pin_builtins_min_ver still changed the file"; exit 1; }
{ upstream 10.7; upstream 10.7; } > "$t/twice.cmake"
if mav_pin_builtins_min_ver "$t/twice.cmake" 10.9 2>/dev/null; then
  echo "FAIL: mav_pin_builtins_min_ver accepted the upstream line twice"; exit 1
fi
upstream 10.7 > "$t/bad.cmake"
if mav_pin_builtins_min_ver "$t/bad.cmake" 'ten' 2>/dev/null; then
  echo "FAIL: mav_pin_builtins_min_ver accepted a version that is not one"; exit 1
fi

# The build-time guard over what the settings above produce: the host tools (bin/ and lib/'s host
# libraries) arm64 only, the builtins x86_64 only, each slice recording its arch's pin.
for line in \
  'for f in "$STAGE"/bin/* "$STAGE"/lib/*.a "$STAGE"/lib/*.dylib; do' \
  '  case "${f##*/}" in libc++*|libunwind*|libMacportsLegacySupport.a) continue ;; esac' \
  'MAVERICKS_ALLOW_ARCHS=arm64 sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$@"' \
  'MAVERICKS_ALLOW_ARCHS=x86_64 sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$STAGE"/lib/clang/*/lib/darwin/*.a'
do
  grep -qxF -- "$line" "$B" || { echo "FAIL: build/build-cross.sh's compat guard lost: $line"; exit 1; }
done
# The x86_64 C++ runtime archives: arch and pins per slice, through shipyard's own rule.
for line in \
  '. "$SHIPYARD_SCRIPTS/sdk-pins.sh"' \
  'for a in "$RTDIR/libc++.a" "$RTDIR/libc++abi.a" "$RTDIR/libunwind.a"; do' \
  '  slices="$(sh "$SHIPYARD_SCRIPTS/macho-slices.sh" "$a")" || { echo "FATAL: $a is not a readable Mach-O" >&2; exit 1; }' \
  '    [ "$s_arch" = x86_64 ] || { echo "FATAL: $a has a slice for $s_arch; the target runtime is x86_64 only" >&2; exit 1; }' \
  '    why="$(mav_sdk_rule "$s_arch" "$s_ft" "$s_minos" "$s_sdk")" || { echo "FATAL: $a: $why" >&2; exit 1; }'
do
  grep -qxF -- "$line" "$B" || { echo "FAIL: build/build-cross.sh's runtime-archive pin check lost: $line"; exit 1; }
done

# A cold rebuild that fails late must still keep its ccache: release.yml saves it right after the
# cross build, whatever that build's outcome, with the same actions/cache major, under the restore
# key plus this run and attempt -- never the restore key itself, which a partial cache would lock --
# and the restore step's restore-keys must be a prefix of that key, or nothing ever restores it.
W="$ROOT/.github/workflows/release.yml"
ci="$(awk '
  /^      - name: / { step = $0; uses = "" }
  /^        uses: / { uses = $2 }
  step ~ /Restore ccache \(cross\)/ && /^          key: / { rkey = $0; ruses = uses }
  step ~ /Restore ccache \(cross\)/ && /^          restore-keys: / { rpre = $0; sub(/^          restore-keys: /, "", rpre) }
  uses ~ /^actions\/cache\/save@/ && /^          key: / { skey = $0; suses = uses; sline = NR; sif = cond }
  /^        if: / { cond = $0 }
  /^      - name: / { cond = "" }
  /^        run: sh build\/build-cross\.sh$/ { bline = NR }
  END {
    sub(/^actions\/cache@/, "", ruses); sub(/^actions\/cache\/save@/, "", suses)
    sval = skey; sub(/^          key: /, "", sval)
    ok = rkey != "" && skey == rkey "-${{ github.run_id }}-${{ github.run_attempt }}" \
         && rpre != "" && index(sval, rpre) == 1 \
         && ruses != "" && suses == ruses && bline && sline > bline \
         && (sif ~ /!cancelled\(\)/ || sif ~ /always\(\)/)
    print ok ? "ok" : "bad: restore=[" rkey "] restore-keys=[" rpre "] " ruses " save=[" skey "] " suses " if=[" sif "] build@" bline " save@" sline
  }' "$W")"
[ "$ci" = ok ] || { echo "FAIL: release.yml's cross ccache save: $ci"; exit 1; }

echo "OK cross-sdk-pin-test"
