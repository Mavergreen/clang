#!/bin/bash
# platform: macOS-only -- builds on a stock 10.9 box with the bootstrapped toolchain
#
# Build GNU Make 4.4.1 for macOS 10.9 with clang-22 (the OS ships only make 3.81, from 2006).
#
# Builds with PLAIN clang-22 -- no special flags. clang-22's config applies the 10.9 polyfill the
# non-invasive way (header shadows via -isystem, not a force-include), so it doesn't perturb gnulib's
# compiler probes; and its C config (clang.cfg) adds only the static polyfill archive + dead-stripped
# frameworks, so make links against libSystem alone and is relocatable on its own -- no relocate step
# needed. The result is also symlinked into toolchains/tools/bin alongside ninja/cmake.
#
# Prereqs: the clang-22 toolchain (scripts/build.sh). Uses the system make (3.81) to drive the build.
#
#   ./make.sh         build + install (idempotent)
#   ./make.sh check   relocatability audit of the install
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
ARCHIVES="$ROOT/archives"; CLANG="$ROOT/toolchains/clang-22"
VER="4.4.1"
PREFIX="$ROOT/toolchains/make-$VER"            # relocatable install prefix
SRC="$ROOT/build/make-$VER"                    # disposable build tree
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
mkdir -p "$ARCHIVES"

msg()   { printf '\n=== %s ===\n' "$*"; }
fetch() { [ -f "$2" ] && return 0; echo "  fetch $1"; curl -fL --retry 3 -o "$2.tmp" "$1"; mv "$2.tmp" "$2"; }

require() { [ -x "$CLANG/bin/clang" ] || { echo "ERROR: clang-22 missing -- run scripts/build.sh first" >&2; exit 1; }; }

build_make() {
  [ -x "$PREFIX/bin/make" ] && return 0
  msg "GNU Make $VER -> $PREFIX (clang-22, deployment 10.9)"
  fetch "https://ftp.gnu.org/gnu/make/make-$VER.tar.gz" "$ARCHIVES/make-$VER.tar.gz"
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -xzf "$ARCHIVES/make-$VER.tar.gz" -C "$ROOT/build"
  # Plain clang-22 -- no special flags. clang-22's config applies the polyfill the non-invasive way
  # (header shadows, not a force-include), so it no longer perturbs gnulib's compiler probes; and its
  # C config adds only the static polyfill archive + (dead-stripped) frameworks, so make links
  # against libSystem alone and is relocatable on its own -- no relocate step. system make (3.81)
  # drives the build.
  ( cd "$SRC" \
      && CC="$CLANG/bin/clang" MACOSX_DEPLOYMENT_TARGET=10.9 \
         ./configure --prefix="$PREFIX" --disable-dependency-tracking \
      && make -j"$JOBS" \
      && make install )
}

check_reloc() {
  msg "relocatability audit"; local f n=0 bad=0 hits
  while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q Mach-O || continue; n=$((n+1))
    hits="$(printf '%s\n%s\n%s\n' \
      "$(otool -L "$f" 2>/dev/null | tail -n +2)" "$(otool -D "$f" 2>/dev/null | tail -n +2)" \
      "$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')" | grep -F "$ROOT" || true)"
    [ -n "$hits" ] && { bad=$((bad+1)); echo "FAIL ${f#$ROOT/}"; echo "$hits" | sed "s#$ROOT#<REPO>#g;s/^/    /"; }
  done < <(find "$PREFIX/bin" "$PREFIX/lib" -type f 2>/dev/null)
  echo "checked $n Mach-O under ${PREFIX#$ROOT/}: $bad with absolute repo paths"; [ "$bad" -eq 0 ]
}

case "${1:-all}" in
  all)   require; build_make; check_reloc
         # expose it alongside ninja/cmake (relative symlink; make is self-contained so it travels fine)
         install -d "$ROOT/toolchains/tools/bin"
         ln -sf "../../make-$VER/bin/make" "$ROOT/toolchains/tools/bin/make"
         msg "DONE"; "$PREFIX/bin/make" --version | head -1
         echo "  also linked: toolchains/tools/bin/make" ;;
  check) check_reloc ;;
  *) echo "usage: $0 [all|check]"; exit 1 ;;
esac
