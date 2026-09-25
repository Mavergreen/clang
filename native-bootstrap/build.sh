#!/bin/bash
# platform: macOS-only -- bootstraps the toolchain from source on a stock 10.9 box
#
# Bootstrap a portable clang-22 / LLVM 22.1.1 toolchain that runs on and targets
# macOS 10.9, entirely from source, on the stock Apple clang-3.5 seed.
#
# Idempotent: every stage is skipped if its toolchain already reports the right
# version, so re-running resumes from the first unfinished stage. An interrupted
# stage is rebuilt from scratch (its build tree is wiped and reconfigured).
#
# Clean / mechanical: no source surgery — only version choice, cmake flags, and
# compiler selection. The chain climbs to a modern libc++ one stage at a time
# because the seed cannot build LLVM >= 4, and each built toolchain is relocatable
# (paths resolved relative to the binary; no absolute repo paths in any Mach-O).
#
# Prerequisite: the built 10.9 polyfill must be vendored in-repo at ./polyfill/
# (lib/libMavericksLegacySupport.a + include/). The script checks for it up front.
#
#   ./build.sh            build everything (skips finished stages)
#   ./build.sh check DIR  audit a toolchain prefix for non-relocatable paths
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
ARCHIVES="$ROOT/archives"; BUILD="$ROOT/build"; TOOLCHAINS="$ROOT/toolchains"; TOOLS="$TOOLCHAINS/tools"
POLY="$ROOT/polyfill"   # built 10.9 back-fill, vendored into the repo (see require_polyfill)
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export PATH="$TOOLS/bin:$PATH"
mkdir -p "$ARCHIVES" "$BUILD" "$TOOLS"

msg()   { printf '\n=== %s ===\n' "$*"; }
have()  { "$1" --version 2>/dev/null | grep -qF "$2"; }                 # tool reports version?
fetch() { [ -f "$2" ] && return 0; echo "  fetch $1"; curl -fL --retry 3 -o "$2.tmp" "$1"; mv "$2.tmp" "$2"; }

# The 10.9 back-fill must be present in-repo before building (stages C+ link it). It is a vendored
# copy of the mavericks-legacy-support source-of-truth repo (which survives a wipe of this tree, per
# the bootstrap notes). If polyfill/ is absent but that repo is, rebuild + re-vendor it automatically
# so a "delete everything except scripts" rebootstrap reproduces the polyfill (and any additions to it,
# e.g. the lldb back-fills) with no manual step.
MLS_SRC="${MLS_SRC:-/Users/Jonathan/Developer/Mavericks Porting Resources/mavericks-legacy-support}"
require_polyfill() {
  [ -f "$POLY/lib/libMavericksLegacySupport.a" ] && [ -d "$POLY/include" ] && return 0
  if [ -f "$MLS_SRC/Makefile" ]; then
    msg "vendoring polyfill from source-of-truth: $MLS_SRC"
    ( cd "$MLS_SRC" && make ) || { echo "ERROR: polyfill build (make) failed in $MLS_SRC" >&2; exit 1; }
    install -d "$POLY/lib"; cp "$MLS_SRC/lib/libMavericksLegacySupport.a" "$POLY/lib/"
    rm -rf "$POLY/include"; cp -R "$MLS_SRC/include" "$POLY/include"
    [ -f "$POLY/lib/libMavericksLegacySupport.a" ] && [ -d "$POLY/include" ] && return 0
  fi
  echo "ERROR: polyfill missing and could not be vendored. Expected one of:" >&2
  echo "  in-repo:  ${POLY#$ROOT/}/lib/libMavericksLegacySupport.a  +  ${POLY#$ROOT/}/include/" >&2
  echo "  source:   $MLS_SRC  (set MLS_SRC=... if it lives elsewhere; 'make' there, then copy lib/ + include/)" >&2
  exit 1
}

# --- source unpackers -------------------------------------------------------
unpack_classic() {   # $1=ver : pre-monorepo component tarballs -> in-tree layout at $BUILD/llvm-$1.src
  local V="$1" B="https://releases.llvm.org/$1" c L="$BUILD/llvm-$1.src"
  for c in llvm cfe libcxx libcxxabi; do fetch "$B/$c-$V.src.tar.xz" "$ARCHIVES/$c-$V.src.tar.xz"; done
  for c in llvm cfe libcxx libcxxabi; do rm -rf "$BUILD/$c-$V.src"; tar -xf "$ARCHIVES/$c-$V.src.tar.xz" -C "$BUILD"; done
  mkdir -p "$L/tools" "$L/projects"
  mv "$BUILD/cfe-$V.src" "$L/tools/clang"; mv "$BUILD/libcxx-$V.src" "$L/projects/libcxx"; mv "$BUILD/libcxxabi-$V.src" "$L/projects/libcxxabi"
}
unpack_monorepo() {  # $1=ver : unified tarball -> $BUILD/llvm-project-$1.src
  local V="$1"
  fetch "https://github.com/llvm/llvm-project/releases/download/llvmorg-$V/llvm-project-$V.src.tar.xz" "$ARCHIVES/llvm-project-$V.src.tar.xz"
  rm -rf "$BUILD/llvm-project-$V.src"; tar -xf "$ARCHIVES/llvm-project-$V.src.tar.xz" -C "$BUILD"
}

# --- polyfill: wire the 10.9 back-fill into a clang prefix (declarations + static
#     archive). Needed by every clang that compiles code calling APIs absent from
#     the 10.9 SDK (clonefile, ...). clang.cfg auto-applies on clang >= 12; older
#     intermediates get the same flags explicitly from their stage below. --------
wire_polyfill() {    # $1=prefix
  local P="$1" c
  install -d "$P/lib" "$P/include" "$P/bin"
  cp "$POLY/lib/libMavericksLegacySupport.a" "$P/lib/"
  rm -rf "$P/include/mavericks-legacy-support"; cp -R "$POLY/include" "$P/include/mavericks-legacy-support"
  cat > "$P/include/macos10_9_compat.h" <<'EOF'
#ifndef MACOS10_9_COMPAT_H
#define MACOS10_9_COMPAT_H
/* Declarations for newer-than-10.9 APIs that source may call without including
   their header (e.g. clonefile in LLVM Support/Unix/Path.inc). From the vendored
   polyfill; implementations come from the auto-linked archive below.
   Guarded for __ASSEMBLER__: this header is force-included (clang config / -include)
   on EVERY invocation, including .s/.S assembly, where these C declarations would be
   fed to the integrated assembler and rejected ("invalid instruction mnemonic ...").  */
#ifndef __ASSEMBLER__
#include "mavericks-legacy-support/LegacySupport.h"
#include "mavericks-legacy-support/sys/clonefile.h"
#endif
#endif
EOF
  for c in clang.cfg clang++.cfg; do printf '%s\n' \
    '-include <CFGDIR>/../include/macos10_9_compat.h' \
    '-L<CFGDIR>/../lib' \
    '<CFGDIR>/../lib/libMavericksLegacySupport.a' > "$P/bin/$c"; done
}

# --- final clang-22 wiring: clang-22 AUTO-LOADS clang.cfg, so the 10.9 polyfill applies with zero
#     per-project flags. It is wired the *non-invasive* way -- the way macports-legacy-support is
#     meant to be used -- with two ingredients that only affect the steps they should:
#       -isystem (header shadows): the polyfill's wrapper headers (time.h -> clock_gettime,
#         sys/clonefile.h, mbstate_t/aligned_alloc/*at, ...) #include_next the SDK header and add the
#         newer-than-10.9 declarations. They only take effect when code #includes the normal header,
#         so they never perturb a plain `-E`/assembly invocation.
#       the link archive (+ frameworks): resolves the back-filled symbols at link time only.
#     NOTE: there is deliberately NO `-include macos10_9_compat.h` force-include here. Force-including
#     a header on *every* invocation breaks build systems that probe the compiler (gnulib/autotools
#     capture preprocessed output; the header's transitive system typedefs then leak onto a command
#     line and wreck the shell) and pollutes .s/.S assembly. The header shadows cover everything that
#     #includes its header; for the rare code that calls a 10.9-missing API *without* including any
#     header for it (e.g. clonefile in LLVM's Path.inc), pass `-include <prefix>/include/
#     macos10_9_compat.h` explicitly in that build (wire_polyfill still installs the header for that).
#     clang++.cfg links the toolchain's C++ runtime (libc++ + libc++abi + libunwind .a) STATICALLY but
#     GAP-FILLING, so every C++ executable is SELF-CONTAINED and PORTABLE BY DEFAULT -- no @rpath
#     dependency on the toolchain's dylibs, no rpath at all, and so no per-binary "relocate" step to
#     forget (the old `-Wl,-rpath,<CFGDIR>/../lib` baked an absolute build-machine path that failed when
#     the binary was copied elsewhere). The mechanism: `-nostdlib++` (don't pull the libc++ DYLIB) plus
#     `--ld-path=<CFGDIR>/portable-ld`, a tiny wrapper that APPENDS the three .a at the END of the link
#     line. A static archive supplies only symbols still undefined when it is reached, so: a normal
#     program gets the whole STL (self-contained); a program that bundles its OWN libc++ (e.g. V8 inside
#     codex) resolves those first, and the toolchain's copy fills only the gaps -> no duplicate-symbol
#     error and NO per-project flags. We supply our own libunwind so a C++/Rust unwind never mixes with
#     the 10.9 system unwinder (SIGSEGV in _platform_memmove). The deployed binary depends only on
#     /usr/lib + /System frameworks (present on every 10.9 box); all link inputs are <CFGDIR>-relative,
#     used at link time only -> the OUTPUT carries no repo path. (Had we put the .a EARLY instead, the
#     linker force-pulls them and a bundled-libc++ program like codex fails with duplicate symbols.)
#     CAVEAT: a C++ *shared library* built this way still statically embeds libc++abi; an executable that
#     loads it (and also embeds it) then has two ABI copies, breaking RTTI/exceptions across that
#     boundary. The toolchain's only C++ dylib (liblldb) is built by lldb.sh with its own dynamic flags,
#     so it is unaffected; a project needing a dynamic C++ runtime should override (--no-default-config,
#     then -L/-rpath <prefix>/lib -lc++ -lc++abi -lunwind). --------------
wire_clang22() {     # $1=prefix
  local P="$1"
  wire_polyfill "$P"                          # vendor archive + headers + macos10_9_compat.h (opt-in)
  # The polyfill's Security/ObjC/LaunchServices members pull in libobjc + CoreFoundation + Security +
  # CoreServices; static-archive consumers (this clang) must link those frameworks themselves (per the
  # polyfill README). They're system frameworks (/System/...), so they don't affect relocatability.
  # clang.cfg (the C driver): header shadows + the STATIC polyfill archive + the frameworks its
  # members may need. No libc++/-rpath/-lunwind here -- those are a C++ concern (clang++.cfg). The
  # archive is static (baked in, no runtime dep) and the frameworks are system (/System/...), so a C
  # program is relocatable as-is -- no post-build relocate needed. -dead_strip_dylibs drops the
  # framework/objc load commands a given program does not actually use, so simple C tools (make, ...)
  # come out depending on libSystem alone.
  printf '%s\n' \
    '-isystem <CFGDIR>/../include/mavericks-legacy-support' \
    '-Wl,-dead_strip_dylibs' \
    '<CFGDIR>/../lib/libMavericksLegacySupport.a' \
    '-lobjc' '-framework CoreFoundation' '-framework Security' '-framework CoreServices' > "$P/bin/clang.cfg"
  # Gap-filling static C++ runtime (see header comment): -nostdlib++ + a portable-ld wrapper that
  # appends libc++/libc++abi/libunwind .a at the END of the link line, so they fill only what the
  # program doesn't already provide. Self-contained for normal code; no duplicate for bundled-libc++.
  printf '%s\n' \
    '-isystem <CFGDIR>/../include/mavericks-legacy-support' \
    '-nostdlib++' \
    '<CFGDIR>/../lib/libMavericksLegacySupport.a' \
    '-lobjc' '-framework CoreFoundation' '-framework Security' '-framework CoreServices' \
    '--ld-path=<CFGDIR>/portable-ld' > "$P/bin/clang++.cfg"
  # portable-ld: invoke the real ld64.lld, then append the static C++ runtime LAST (dependency order:
  # libc++ -> libc++abi -> libunwind). Resolves its own dir, so the toolchain stays relocatable.
  printf '%s\n' '#!/bin/sh' \
    'DIR="$(cd "$(dirname "$0")" && pwd)"' \
    'exec "$DIR/ld64.lld" "$@" "$DIR/../lib/libc++.a" "$DIR/../lib/libc++abi.a" "$DIR/../lib/libunwind.a"' > "$P/bin/portable-ld"
  chmod +x "$P/bin/portable-ld"
  # clang auto-invokes its sibling dsymutil when linking an executable/dylib with -g (to build the
  # .dSYM). clang-22's dsymutil -- like its other standalone llvm-* tools -- crashes on launch
  # ("Symbol not found: __Znwm", operator new) because clang-22's libc++ does not re-export libc++abi.
  # Wrap it to force-load libc++abi in a flat namespace so the symbol resolves. Relative path -> stays
  # relocatable. (cc.cfg-style flags can't reach dsymutil; it must be fixed as a binary.)
  if [ ! -e "$P/bin/dsymutil.real" ]; then
    mv "$P/bin/dsymutil" "$P/bin/dsymutil.real"
    printf '%s\n' '#!/bin/sh' \
      'S="$(cd "$(dirname "$0")" && pwd)"' \
      'exec env DYLD_INSERT_LIBRARIES="$S/../lib/libc++abi.1.dylib" DYLD_FORCE_FLAT_NAMESPACE=1 "$S/dsymutil.real" "$@"' > "$P/bin/dsymutil"
    chmod +x "$P/bin/dsymutil"
  fi
}

# --- build-tools (seed) -----------------------------------------------------
build_tools() {
  if ! have "$TOOLS/bin/ninja" 1.11.1; then
    msg "ninja 1.11.1 (seed)"
    fetch "https://github.com/ninja-build/ninja/archive/refs/tags/v1.11.1.tar.gz" "$ARCHIVES/ninja-1.11.1.tar.gz"
    rm -rf "$BUILD/ninja-1.11.1"; tar -xzf "$ARCHIVES/ninja-1.11.1.tar.gz" -C "$BUILD"
    ( cd "$BUILD/ninja-1.11.1" && CXX=c++ python ./configure.py --bootstrap && install -d "$TOOLS/bin" && install -m755 ninja "$TOOLS/bin/ninja" )
  fi
  if ! have "$TOOLS/bin/cmake" 3.19.8; then   # newest cmake the 10.9 libc++ can build; >=3.21 fails
    msg "cmake 3.19.8 (seed)"
    fetch "https://github.com/Kitware/CMake/releases/download/v3.19.8/cmake-3.19.8.tar.gz" "$ARCHIVES/cmake-3.19.8.tar.gz"
    rm -rf "$BUILD/cmake-3.19.8"; tar -xzf "$ARCHIVES/cmake-3.19.8.tar.gz" -C "$BUILD"
    ( cd "$BUILD/cmake-3.19.8" && ./bootstrap --prefix="$TOOLS" --parallel="$JOBS" --no-qt-gui -- -DCMAKE_USE_OPENSSL=OFF -DCMAKE_BUILD_TYPE=Release && make -j"$JOBS" && make install )
  fi
}

# --- Stage A: seed -> LLVM 3.9.1 (newest the seed can compile) -> clang-3.9 ----
stage_clang39() {
  have "$TOOLCHAINS/clang-3.9/bin/clang" 3.9.1 && return 0
  msg "Stage A: LLVM 3.9.1 -> clang-3.9 (seed)"
  unpack_classic 3.9.1
  local BLD="$BUILD/clang-3.9-build"; rm -rf "$BLD"
  # -O1, not Release's -O3: the seed (Apple clang-3.5) segfaults in X86 instruction
  # selection at -O2/-O3 on heavy CodeGen TUs (CGClass/CGBlocks/...). Seed bug, not
  # a source issue -> a standard optimization-level flag, no source changes.
  cmake -G Ninja -S "$BUILD/llvm-3.9.1.src" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$TOOLCHAINS/clang-3.9" \
    -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DCLANG_DEFAULT_CXX_STDLIB=libc++
  ninja -C "$BLD"; ninja -C "$BLD" install
}

# --- Stage B: clang-3.9 -> LLVM 6.0.1 -> clang-6 ------------------------------
stage_clang6() {
  have "$TOOLCHAINS/clang-6/bin/clang" 6.0.1 && return 0
  msg "Stage B: LLVM 6.0.1 -> clang-6 (built by clang-3.9)"
  local PREV="$TOOLCHAINS/clang-3.9"
  unpack_classic 6.0.1
  local BLD="$BUILD/clang-6-build"; rm -rf "$BLD"
  cmake -G Ninja -S "$BUILD/llvm-6.0.1.src" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$TOOLCHAINS/clang-6" \
    -DCMAKE_C_COMPILER="$PREV/bin/clang" -DCMAKE_CXX_COMPILER="$PREV/bin/clang++" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DCLANG_DEFAULT_CXX_STDLIB=libc++
  ninja -C "$BLD"; ninja -C "$BLD" install
}

# --- Stage C: clang-6 -> LLVM 14.0.6 (monorepo) -> clang-14 -------------------
stage_clang14() {
  have "$TOOLCHAINS/clang-14/bin/clang" 14.0.6 && return 0
  msg "Stage C: LLVM 14.0.6 -> clang-14 (built by clang-6 + polyfill)"
  local PREV="$TOOLCHAINS/clang-6"
  wire_polyfill "$PREV"                                  # clang-6 predates auto clang.cfg -> pass flags
  local PF="$PREV/include/macos10_9_compat.h" PA="$PREV/lib/libMavericksLegacySupport.a"
  # -framework CoreFoundation: Path.cpp's __builtin_available(macos 10.12) lowers to a
  # CoreFoundation version check (_CFBundleGetVersionNumber) on a 10.9 deployment target;
  # the reference lives in an archive member so ld64's autolink hint is missed. CF is a
  # system framework (/System/...), so this stays relocatable.
  local LD="$PA -framework CoreFoundation"
  # The libcxx/libcxxabi RUNTIMES are a sub-build compiled by the just-built clang-14,
  # which does NOT inherit the flags above (llvm/runtimes forwards only RUNTIMES_CMAKE_ARGS).
  # libcxx's filesystem uses the *at family (openat/fdopendir/unlinkat/AT_*) absent from the
  # 10.9 SDK; the polyfill's header-shadow declares them and its archive implements them.
  # -fno-jump-tables: the runtimes (libc++abi's cxa_demangle) emit big switch jump tables
  # whose label-difference relocations crash the 10.9 system ld64-241.9 ("name != NULL"
  # assertion) at -O1+. Branches instead of jump tables avoid it; -O3 is otherwise kept.
  local SH="$PREV/include/mavericks-legacy-support" RT="$PA -Wl,-framework,CoreFoundation"
  local RC="-I$SH -fno-jump-tables"
  local RTARGS="-DCMAKE_C_FLAGS=$RC;-DCMAKE_CXX_FLAGS=$RC;-DCMAKE_EXE_LINKER_FLAGS=$RT;-DCMAKE_SHARED_LINKER_FLAGS=$RT;-DCMAKE_MODULE_LINKER_FLAGS=$RT"
  # Also build lld here: clang-14's own (LLVM-14-compiled-by-clang-6) objects link fine with
  # the 10.9 system ld64, but the objects clang-14 PRODUCES for LLVM 22 (stage D) widely crash
  # ld64-241.9's relocation parser. So stage D must link with lld, which clang-14 provides.
  unpack_monorepo 14.0.6
  local BLD="$BUILD/clang-14-build"; rm -rf "$BLD"
  cmake -G Ninja -S "$BUILD/llvm-project-14.0.6.src/llvm" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$TOOLCHAINS/clang-14" \
    -DCMAKE_C_COMPILER="$PREV/bin/clang" -DCMAKE_CXX_COMPILER="$PREV/bin/clang++" \
    -DCMAKE_C_FLAGS="-include $PF" -DCMAKE_CXX_FLAGS="-include $PF" \
    -DCMAKE_EXE_LINKER_FLAGS="$LD" -DCMAKE_SHARED_LINKER_FLAGS="$LD" -DCMAKE_MODULE_LINKER_FLAGS="$LD" \
    -DRUNTIMES_CMAKE_ARGS="$RTARGS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DCLANG_DEFAULT_CXX_STDLIB=libc++
  ninja -C "$BLD"; ninja -C "$BLD" install
}

# --- newer cmake (>=3.20, needed by LLVM 22), built by clang-14 ---------------
build_cmake_new() {
  have "$TOOLCHAINS/cmake-new/bin/cmake" 3.28.6 && return 0
  msg "cmake 3.28.6 (built by clang-14)"
  local PREV="$TOOLCHAINS/clang-14"
  fetch "https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6.tar.gz" "$ARCHIVES/cmake-3.28.6.tar.gz"
  rm -rf "$BUILD/cmake-3.28.6"; tar -xzf "$ARCHIVES/cmake-3.28.6.tar.gz" -C "$BUILD"
  # Old-toolchain workarounds for this build-tool (cmake is not a deliverable, so none of
  # this touches the clang-22 output):
  #  -Wno-undef-prefix : cmake's bundled libuv uses TARGET_OS_TV/TARGET_OS_WATCH, absent from
  #                      the 10.9 SDK; clang-14 makes that a (default-error) diagnostic.
  #  -O0 for the full build : several bundled-lib files (e.g. curl's doh.c, kwsys) emit, at any
  #                      -O>=1, relocations the 10.9 system ld64-241.9 cannot parse (it asserts
  #                      "name != NULL"). Only -O0 reliably avoids them; -fno-jump-tables alone
  #                      is not enough. cmake's own runtime speed is irrelevant to the toolchain.
  ( cd "$BUILD/cmake-3.28.6" && CC="$PREV/bin/clang" CXX="$PREV/bin/clang++" \
      CFLAGS="-Wno-undef-prefix" CXXFLAGS="-Wno-undef-prefix" \
      ./bootstrap --prefix="$TOOLCHAINS/cmake-new" --parallel="$JOBS" --no-qt-gui --generator=Ninja -- \
        -DCMAKE_USE_OPENSSL=OFF -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        -DCMAKE_C_FLAGS=-Wno-undef-prefix -DCMAKE_CXX_FLAGS=-Wno-undef-prefix \
        -DCMAKE_C_FLAGS_RELEASE="-O0 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O0 -DNDEBUG" \
        && ninja && ninja install )
}

# --- Stage D (deliverable): clang-14 -> LLVM 22.1.1 -> clang-22 ---------------
stage_clang22() {
  have "$TOOLCHAINS/clang-22/bin/clang" 22.1.1 && return 0
  msg "Stage D: LLVM 22.1.1 -> clang-22 (built by clang-14 + polyfill; lld + libc++ defaults)"
  local PREV="$TOOLCHAINS/clang-14" CMAKE="$TOOLCHAINS/cmake-new/bin/cmake"
  wire_polyfill "$PREV"
  local PF="$PREV/include/macos10_9_compat.h" PA="$PREV/lib/libMavericksLegacySupport.a"
  # -L$PREV/lib: LLVM 22's clang uses std::shared_mutex etc., whose out-of-line symbols are
  # absent from the 2013 system libc++ that Darwin links by default. clang-14's libc++ has
  # them; its install_name is @rpath/libc++.1.dylib, so the recorded dep stays @rpath and the
  # installed clang-22 uses its OWN libc++ at runtime (via @loader_path/../lib) -> relocatable.
  local LD="$PA -framework CoreFoundation -L$PREV/lib"
  # LINK WITH lld, not the 10.9 system ld64: ld64-241.9 cannot parse the relocations clang-14
  # emits for much of LLVM 22 (APInt, the demangler, ...) and asserts. lld (built into clang-14)
  # handles them, and keeps clang-22 at -O3. -fno-jump-tables stays on the runtimes only as
  # cheap belt-and-suspenders in case LLVM_USE_LINKER doesn't reach the runtimes sub-build.
  # -Wno-undef-prefix: LLVM 22 (e.g. clang's DirectoryWatcher-mac.cpp) tests TARGET_OS_OSX,
  # absent from the 10.9 SDK; clang-14 makes that a (default-error) -Wundef-prefix diagnostic.
  # (clang-6 in stage C predates this warning, so LLVM 14's main build didn't need it.)
  # -DDARWIN_macosx_CACHED_SYSROOT=/ : compiler-rt finds the macOS SDK via xcodebuild, which
  # this Command-Line-Tools-only 10.9 box lacks, so DARWIN_osx_SYSROOT comes back empty and its
  # sdk_has_arch_support() errors. Presetting the cached sysroot to / (headers live in /usr/include)
  # short-circuits the detection. Needed by both the builtins and full compiler-rt sub-builds.
  # compiler-rt: build ONLY the builtins (libclang_rt.builtins, the part the toolchain needs).
  # The sanitizers/XRay/fuzzer/profile require macOS SDK >= 10.12 (TSan hard-errors) and aren't
  # usable on 10.9, so disable them.
  local CRT="-DCOMPILER_RT_BUILD_SANITIZERS=OFF;-DCOMPILER_RT_BUILD_XRAY=OFF;-DCOMPILER_RT_BUILD_LIBFUZZER=OFF;-DCOMPILER_RT_BUILD_PROFILE=OFF;-DCOMPILER_RT_BUILD_MEMPROF=OFF;-DCOMPILER_RT_BUILD_ORC=OFF;-DCOMPILER_RT_BUILD_GWP_ASAN=OFF;-DCOMPILER_RT_BUILD_CTX_PROFILE=OFF"
  local SH="$PREV/include/mavericks-legacy-support" RT="$PA -Wl,-framework,CoreFoundation"
  local RC="-I$SH -fno-jump-tables -Wno-undef-prefix"
  local RTARGS="-DCMAKE_C_FLAGS=$RC;-DCMAKE_CXX_FLAGS=$RC;-DCMAKE_EXE_LINKER_FLAGS=$RT;-DCMAKE_SHARED_LINKER_FLAGS=$RT;-DCMAKE_MODULE_LINKER_FLAGS=$RT;-DLLVM_USE_LINKER=lld;-DDARWIN_macosx_CACHED_SYSROOT=/;$CRT"
  # Main build also needs the polyfill header-shadow (-I): LLVM 22's Threading.inc does
  # #include <pthread/qos.h> (a macOS 10.10+ header absent from the 10.9 SDK) which the
  # polyfill supplies. LLVM 14 (stage C) didn't include it, so its main build didn't need -I.
  local MF="-include $PF -I$SH -Wno-undef-prefix"
  unpack_monorepo 22.1.1
  local BLD="$BUILD/clang-22-build"; rm -rf "$BLD"
  "$CMAKE" -G Ninja -S "$BUILD/llvm-project-22.1.1.src/llvm" -B "$BLD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$TOOLCHAINS/clang-22" \
    -DCMAKE_C_COMPILER="$PREV/bin/clang" -DCMAKE_CXX_COMPILER="$PREV/bin/clang++" \
    -DLLVM_USE_LINKER=lld \
    -DCMAKE_C_FLAGS="$MF" -DCMAKE_CXX_FLAGS="$MF" \
    -DCMAKE_EXE_LINKER_FLAGS="$LD" -DCMAKE_SHARED_LINKER_FLAGS="$LD" -DCMAKE_MODULE_LINKER_FLAGS="$LD" \
    -DRUNTIMES_CMAKE_ARGS="$RTARGS" -DBUILTINS_CMAKE_ARGS="-DDARWIN_macosx_CACHED_SYSROOT=/" \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind;compiler-rt" \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DCLANG_DEFAULT_LINKER=lld -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_LIBXML2=OFF
  # DYLD_LIBRARY_PATH: the in-build host tools (clang, llvm-libtool-darwin, ...) were compiled
  # against clang-14's libc++ (which re-exports libc++abi -> operator new/delete), but their
  # @rpath resolves at runtime to the freshly-built target libc++, which does NOT re-export
  # libc++abi -> they'd crash (dyld: __ZdlPv not found). Point them back at clang-14's libc++.
  DYLD_LIBRARY_PATH="$PREV/lib" ninja -C "$BLD"
  DYLD_LIBRARY_PATH="$PREV/lib" ninja -C "$BLD" install
  wire_clang22 "$TOOLCHAINS/clang-22"      # final toolchain auto-applies the polyfill (clang-22 auto-loads clang.cfg)
}

# --- relocatability audit: flag any Mach-O load command (dep / install-name /
#     rpath) that hardcodes an absolute path into this repo. -------------------
check_reloc() {      # $1=prefix
  local P="$1" f n=0 bad=0 hits
  while IFS= read -r f; do
    file "$f" | grep -q Mach-O || continue; n=$((n+1))
    hits="$(printf '%s\n%s\n%s\n' \
      "$(otool -L "$f" 2>/dev/null | tail -n +2)" \
      "$(otool -D "$f" 2>/dev/null | tail -n +2)" \
      "$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/path /{print $2; r=0}')" | grep -F "$ROOT" || true)"
    [ -n "$hits" ] && { bad=$((bad+1)); echo "FAIL ${f#$ROOT/}"; echo "$hits" | sed "s#$ROOT#<REPO>#g;s/^/    /"; }
  done < <(find "$P/bin" "$P/lib" -type f 2>/dev/null)
  echo "checked $n Mach-O under ${P#$ROOT/}: $bad with absolute repo paths"; [ "$bad" -eq 0 ]
}

case "${1:-all}" in
  all) require_polyfill; build_tools; stage_clang39; stage_clang6; stage_clang14; build_cmake_new; stage_clang22
       msg "DONE"; "$TOOLCHAINS/clang-22/bin/clang" --version | head -1 ;;
  check) check_reloc "${2:?usage: build.sh check <toolchain-prefix>}" ;;
  *) echo "usage: $0 [all|check <prefix>]"; exit 1 ;;
esac
