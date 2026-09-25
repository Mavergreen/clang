#!/bin/bash
# platform: macOS-only -- builds lldb on a stock 10.9 box against the system debugserver
#
# Add a modern LLDB (22.1.1) with Python scripting to the clang-22 toolchain,
# built from source and running on macOS 10.9.
#
# Prereqs: the clang-22 toolchain + its build tree must already exist
# (scripts/build.sh -- this script reuses build/clang-22-build so it does NOT
# recompile all of LLVM), and the Python 3.10 framework must be installed at
# /Library/Frameworks/Python.framework/Versions/3.10 (python.org installer).
#
# What it does, in order:
#   1. Build the extra build-tools LLDB's SWIG bindings need, from source:
#      m4 1.4.19, autoconf 2.71, automake 1.16.5, bison 3.8.2 (the 10.9 system
#      bison 2.3 is too old for SWIG), PCRE2 10.44, and SWIG 4.2.1.  (SWIG only
#      ships a git archive reachable from this box; SourceForge is unreachable
#      via the 10.9 curl, so the autotools chain is built to run its autogen.)
#   2. Vendor the in-repo polyfill (which now also back-fills os/log.h,
#      dispatch_activate, TARGET_OS_*, CPU_SUBTYPE_*, Security/AuthSession.h, and
#      the dyld shared-cache stubs -- all newer-than-10.9 APIs LLDB references)
#      into the clang-14 compiler's header-shadow dir + static archive.
#   3. Reconfigure build/clang-22-build to also build lldb, with Python (the
#      framework above) + SWIG + libedit, curses OFF (10.9 ncurses too old), and
#      LLDB_USE_SYSTEM_DEBUGSERVER=ON (debugserver 22 needs a >=10.12 SDK).
#   4. Apply the one unavoidable source change INLINE (below): replace the
#      iOS-Simulator CoreSimulator file with an inert stub.  Its upstream form
#      uses ObjC lightweight generics (a 10.11-SDK feature) that a polyfill
#      cannot add to a system class; iOS-Simulator support is meaningless on
#      10.9 anyway.  Native macOS debugging is unaffected.
#   5. Build + install only the lldb components (clang/lld are left untouched).
#   6. Install a debugserver shim so `run`/`attach` work: modern lldb launches
#      debugserver via a `--fd` socket handoff the ~2013 CLT debugserver lacks;
#      the shim relays it to the CLT debugserver's host:port listen model.
#
#   ./lldb.sh         build + install (idempotent; skips finished sub-steps)
#   ./lldb.sh check   relocatability audit of the installed lldb artifacts
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
ARCHIVES="$ROOT/archives"; BUILD="$ROOT/build"; TOOLCHAINS="$ROOT/toolchains"
TOOLS="$TOOLCHAINS/tools"; POLY="$ROOT/polyfill"
PREV="$TOOLCHAINS/clang-14"          # compiler that built clang-22 (used for the lldb sub-build too)
CLANG22="$TOOLCHAINS/clang-22"       # install prefix (the deliverable toolchain)
CMAKE="$TOOLCHAINS/cmake-new/bin/cmake"; NINJA="$TOOLS/bin/ninja"
SHADOW="$PREV/include/mavericks-legacy-support"
PYFW="/Library/Frameworks/Python.framework/Versions/3.10"
DEBUGSERVER_CLT="/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Versions/A/Resources/debugserver"
BLD="$BUILD/clang-22-build"
LLVM_SRC="$BUILD/llvm-project-22.1.1.src"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export PATH="$TOOLS/bin:$PATH"

msg()   { printf '\n=== %s ===\n' "$*"; }
have()  { "$1" --version 2>/dev/null | grep -qF "$2"; }
fetch() { [ -f "$2" ] && return 0; echo "  fetch $1"; curl -fL --retry 3 -o "$2.tmp" "$1"; mv "$2.tmp" "$2"; }

require() {
  [ -x "$CLANG22/bin/clang" ] || { echo "ERROR: clang-22 missing -- run scripts/build.sh first" >&2; exit 1; }
  [ -d "$BLD" ] && [ -f "$BLD/CMakeCache.txt" ] || { echo "ERROR: $BLD missing -- run scripts/build.sh (keep its build tree)" >&2; exit 1; }
  [ -d "$LLVM_SRC/lldb" ] || { echo "ERROR: LLVM 22 source ($LLVM_SRC) missing" >&2; exit 1; }
  [ -x "$PYFW/bin/python3.10" ] || { echo "ERROR: Python 3.10 framework not at $PYFW" >&2; exit 1; }
  [ -x "$DEBUGSERVER_CLT" ] || echo "WARNING: CLT debugserver not found ($DEBUGSERVER_CLT); live debugging will not work" >&2
}

# --- 1. build tools (SWIG + its autotools/PCRE2 chain), all from source --------
# GNU tarballs: use ftp.gnu.org directly -- ftpmirror.gnu.org redirects to mirrors
# whose TLS the 10.9 curl can't negotiate.
build_tools() {
  if ! have "$TOOLS/bin/m4" 1.4.19; then
    msg "m4 1.4.19"; fetch "https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.gz" "$ARCHIVES/m4-1.4.19.tar.gz"
    rm -rf "$BUILD/m4-1.4.19"; tar -xzf "$ARCHIVES/m4-1.4.19.tar.gz" -C "$BUILD"
    ( cd "$BUILD/m4-1.4.19" && ./configure --prefix="$TOOLS" && make -j"$JOBS" && make install )
  fi
  if ! have "$TOOLS/bin/autoconf" 2.71; then
    msg "autoconf 2.71"; fetch "https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.gz" "$ARCHIVES/autoconf-2.71.tar.gz"
    rm -rf "$BUILD/autoconf-2.71"; tar -xzf "$ARCHIVES/autoconf-2.71.tar.gz" -C "$BUILD"
    ( cd "$BUILD/autoconf-2.71" && ./configure --prefix="$TOOLS" && make -j"$JOBS" && make install )
  fi
  if ! have "$TOOLS/bin/automake" 1.16.5; then
    msg "automake 1.16.5"; fetch "https://ftp.gnu.org/gnu/automake/automake-1.16.5.tar.gz" "$ARCHIVES/automake-1.16.5.tar.gz"
    rm -rf "$BUILD/automake-1.16.5"; tar -xzf "$ARCHIVES/automake-1.16.5.tar.gz" -C "$BUILD"
    ( cd "$BUILD/automake-1.16.5" && ./configure --prefix="$TOOLS" && make -j"$JOBS" && make install )
  fi
  if ! have "$TOOLS/bin/bison" 3.8.2; then    # SWIG 4.2 invokes bison -Wall; the CLT bison 2.3 rejects -W
    msg "bison 3.8.2"; fetch "https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.gz" "$ARCHIVES/bison-3.8.2.tar.gz"
    rm -rf "$BUILD/bison-3.8.2"; tar -xzf "$ARCHIVES/bison-3.8.2.tar.gz" -C "$BUILD"
    ( cd "$BUILD/bison-3.8.2" && ./configure --prefix="$TOOLS" && make -j"$JOBS" && make install )
  fi
  if ! have "$TOOLS/bin/pcre2-config" 10.44; then
    msg "PCRE2 10.44 (static, clang-22)"
    fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz" "$ARCHIVES/pcre2-10.44.tar.gz"
    rm -rf "$BUILD/pcre2-10.44"; tar -xzf "$ARCHIVES/pcre2-10.44.tar.gz" -C "$BUILD"
    ( cd "$BUILD/pcre2-10.44" && CC="$CLANG22/bin/clang" ./configure --prefix="$TOOLS" \
        --enable-static --disable-shared --enable-pcre2-8 && make -j"$JOBS" && make install )
  fi
  if ! { "$TOOLS/bin/swig" -version 2>/dev/null | grep -qF "4.2.1"; }; then
    msg "SWIG 4.2.1 (clang-22, pcre2)"
    fetch "https://github.com/swig/swig/archive/refs/tags/v4.2.1.tar.gz" "$ARCHIVES/swig-4.2.1.tar.gz"
    rm -rf "$BUILD/swig-4.2.1"; tar -xzf "$ARCHIVES/swig-4.2.1.tar.gz" -C "$BUILD"
    ( cd "$BUILD/swig-4.2.1" && ./autogen.sh \
        && CC="$CLANG22/bin/clang" CXX="$CLANG22/bin/clang++" \
           ./configure --prefix="$TOOLS" --with-pcre2="$TOOLS/bin/pcre2-config" --disable-ccache \
        && make -j"$JOBS" && make install )
  fi
  "$TOOLS/bin/swig" -version | grep -i version
}

# --- 2. vendor the polyfill into the compiler the lldb sub-build uses. The
#        polyfill (built from the mavericks-legacy-support source-of-truth and
#        re-vendored into polyfill/) already back-fills every newer-than-10.9 API
#        lldb references: header shims (os/log.h, dispatch/dispatch.h,
#        TargetConditionals.h, mach/machine.h CPU_SUBTYPE_*, Security/Authorization.h)
#        plus the implementations in libMavericksLegacySupport.a (os_log,
#        dispatch_*, _availability_version_check, _dyld_get_shared_cache_*, ...). --
vendor_polyfill() {
  msg "vendor polyfill (headers + archive) into clang-14 (build) and clang-22 (runtime)"
  install -d "$SHADOW"
  cp -R "$POLY/include/." "$SHADOW/"
  cp "$POLY/lib/libMavericksLegacySupport.a" "$PREV/lib/libMavericksLegacySupport.a"
  # keep clang-22's own vendored archive in sync, so programs built with clang-22
  # (clang.cfg links this copy) get the same back-fills.
  cp "$POLY/lib/libMavericksLegacySupport.a" "$CLANG22/lib/libMavericksLegacySupport.a"
}

# --- 4. inert stub for the lone iOS-Simulator file (ObjC generics, unbuildable
#        on the 10.9 SDK). Applied INLINE here -- no separate patch file. --------
apply_iossim_stub() {
  local F="$LLVM_SRC/lldb/source/Plugins/Platform/MacOSX/objcxx/PlatformiOSSimulatorCoreSimulatorSupport.mm"
  grep -q "macOS 10.9 stub" "$F" 2>/dev/null && return 0
  msg "stub PlatformiOSSimulatorCoreSimulatorSupport.mm (iOS-Simulator, unbuildable on 10.9 SDK)"
  cat > "$F" <<'STUB'
//===-- PlatformiOSSimulatorCoreSimulatorSupport.mm (macOS 10.9 stub) -----===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// 10.9 TOOLCHAIN STUB -- not the upstream implementation.  The upstream file's
// Objective-C interface declarations use lightweight generics (NSDictionary<...>),
// a macOS 10.11-SDK feature the 10.9 Foundation headers do not declare, so it is
// a hard compile error against the 10.9 SDK -- and, unlike a missing function or
// constant, a polyfill header cannot add generics to a system class.  iOS-Simulator
// support is meaningless on a 10.9 Mac, so this provides inert CoreSimulatorSupport
// symbols: PlatformAppleSimulator links and reports "no simulator devices" at
// runtime.  Native macOS debugging lives in other plugins and is unaffected.
//
//===----------------------------------------------------------------------===//

#include "PlatformiOSSimulatorCoreSimulatorSupport.h"

namespace CoreSimulatorSupport {

Process::Process(lldb::pid_t p) : m_pid(p) {}
Process::Process(lldb_private::Status error)
    : m_pid(LLDB_INVALID_PROCESS_ID), m_error(std::move(error)) {}
Process::Process(lldb::pid_t p, lldb_private::Status error)
    : m_pid(p), m_error(std::move(error)) {}

ModelIdentifier::ModelIdentifier(const std::string &) {}
ModelIdentifier::ModelIdentifier() {}

DeviceType::DeviceType() {}
DeviceType::DeviceType(id) {}
DeviceType::operator bool() { return false; }
std::string DeviceType::GetName() { return std::string(); }
lldb_private::ConstString DeviceType::GetIdentifier() { return lldb_private::ConstString(); }
ModelIdentifier DeviceType::GetModelIdentifier() { return ModelIdentifier(); }
lldb_private::ConstString DeviceType::GetProductFamily() { return lldb_private::ConstString(); }
DeviceType::ProductFamilyID DeviceType::GetProductFamilyID() { return ProductFamilyID::iPhone; }

OSVersion::OSVersion(const std::string &, const std::string &) {}
OSVersion::OSVersion() {}

DeviceRuntime::DeviceRuntime() {}
DeviceRuntime::DeviceRuntime(id) {}
DeviceRuntime::operator bool() { return false; }
OSVersion DeviceRuntime::GetVersion() { return OSVersion(); }
bool DeviceRuntime::IsAvailable() { return false; }

static lldb_private::Status Unsupported() {
  return lldb_private::Status::FromErrorString("iOS Simulator is not supported on macOS 10.9");
}

Device::Device() {}
Device::Device(id) {}
Device::operator bool() { return false; }
std::string Device::GetName() const { return std::string(); }
DeviceType Device::GetDeviceType() { return DeviceType(); }
DeviceRuntime Device::GetDeviceRuntime() { return DeviceRuntime(); }
Device::State Device::GetState() { return State::Shutdown; }
bool Device::Boot(lldb_private::Status &err) { err = Unsupported(); return false; }
bool Device::Shutdown(lldb_private::Status &err) { err = Unsupported(); return false; }
std::string Device::GetUDID() const { return std::string(); }
Process Device::Spawn(lldb_private::ProcessLaunchInfo &) { return Process(Unsupported()); }

bool operator>(const OSVersion &, const OSVersion &) { return false; }
bool operator>(const ModelIdentifier &, const ModelIdentifier &) { return false; }
bool operator<(const OSVersion &, const OSVersion &) { return false; }
bool operator<(const ModelIdentifier &, const ModelIdentifier &) { return false; }
bool operator==(const OSVersion &, const OSVersion &) { return false; }
bool operator==(const ModelIdentifier &, const ModelIdentifier &) { return false; }
bool operator!=(const OSVersion &, const OSVersion &) { return true; }
bool operator!=(const ModelIdentifier &, const ModelIdentifier &) { return true; }

DeviceSet DeviceSet::GetAllDevices(const char *) { return DeviceSet(nullptr); }
DeviceSet DeviceSet::GetAvailableDevices(const char *) { return DeviceSet(nullptr); }
size_t DeviceSet::GetNumDevices() { return 0; }
Device DeviceSet::GetDeviceAtIndex(size_t) { return Device(); }
void DeviceSet::ForEach(std::function<bool(const Device &)>) {}
DeviceSet DeviceSet::GetDevicesIf(std::function<bool(Device)>) { return DeviceSet(nullptr); }
DeviceSet DeviceSet::GetDevices(DeviceType::ProductFamilyID) { return DeviceSet(nullptr); }
Device DeviceSet::GetFanciest(DeviceType::ProductFamilyID) { return Device(); }

} // namespace CoreSimulatorSupport
STUB
}

# --- 3 + 5. reconfigure for lldb, build, install --------------------------------
stage_lldb() {
  [ -x "$CLANG22/bin/lldb" ] && have "$CLANG22/bin/lldb" 22.1.1 && return 0
  apply_iossim_stub
  msg "reconfigure clang-22 build: + lldb (Python framework, SWIG, libedit; system debugserver)"
  # Linker inputs beyond clang-22's defaults, needed because the lldb sub-build is
  # compiled by clang-14 and clang-22's libc++ does not re-export libc++abi:
  #   libMavericksLegacySupport.a  -- 10.9 back-fills (incl. the dyld stubs)
  #   -framework CoreFoundation    -- pulled by polyfill members
  #   -lc++abi                     -- operator new/delete (clang-22 libc++ omits the re-export)
  #   -L clang-14/lib              -- a libc++ that HAS std::__shared_mutex_base (system one doesn't)
  #   libclang_rt.osx.a            -- __isPlatformVersionAtLeast (clang-14 has no compiler-rt)
  local RT="$CLANG22/lib/clang/22/lib/darwin/libclang_rt.osx.a"
  local LD="$PREV/lib/libMavericksLegacySupport.a -framework CoreFoundation -lc++abi -L$PREV/lib $RT"
  "$CMAKE" -S "$LLVM_SRC/llvm" -B "$BLD" \
    -DLLVM_ENABLE_PROJECTS="clang;lld;lldb" \
    -DLLDB_ENABLE_PYTHON=ON -DLLDB_ENABLE_LIBEDIT=ON -DLLDB_ENABLE_CURSES=OFF -DLLDB_ENABLE_LUA=OFF \
    -DLLDB_USE_SYSTEM_DEBUGSERVER=ON \
    -DPython3_EXECUTABLE="$PYFW/bin/python3.10" \
    -DSWIG_EXECUTABLE="$TOOLS/bin/swig" \
    -DCMAKE_OSX_SYSROOT="/" \
    -DCMAKE_EXE_LINKER_FLAGS="$LD" -DCMAKE_SHARED_LINKER_FLAGS="$LD"
  msg "build lldb (reuses the existing LLVM/clang objects)"
  # DYLD_LIBRARY_PATH: in-build host tools link clang-14's libc++ (which re-exports
  # libc++abi); point them at it so they don't crash on operator new/delete.
  DYLD_LIBRARY_PATH="$PREV/lib" "$NINJA" -C "$BLD" lldb lldb-dap lldb-argdumper lldb-server
  msg "install lldb components (clang/lld untouched)"
  DYLD_LIBRARY_PATH="$PREV/lib" "$NINJA" -C "$BLD" \
    install-lldb install-liblldb install-lldb-server install-lldb-dap \
    install-lldb-argdumper install-lldb-python-scripts install-lldb-headers
}

# --- 6. debugserver shim so run/attach work with the CLT debugserver ------------
install_debugserver_shim() {
  [ -x "$CLANG22/bin/debugserver" ] && grep -q 'debugserver shim for the macOS 10.9 toolchain' "$CLANG22/bin/debugserver" 2>/dev/null && return 0
  msg "install debugserver shim (bridges modern lldb's --fd handoff to the CLT debugserver)"
  install -m 0755 "$ROOT/scripts/debugserver-shim.py" "$CLANG22/bin/debugserver"
}

check_reloc() {
  msg "lldb relocatability audit"; local f n=0 bad=0 hits
  for f in "$CLANG22"/bin/lldb "$CLANG22"/bin/lldb-server "$CLANG22"/bin/lldb-dap \
           "$CLANG22"/bin/lldb-argdumper "$CLANG22"/lib/liblldb.22.1.1.dylib \
           "$CLANG22"/lib/python3.10/site-packages/lldb/native/_lldb.abi3.so; do
    [ -f "$f" ] || continue; n=$((n+1))
    hits="$(printf '%s\n%s\n' "$(otool -L "$f" 2>/dev/null | tail -n +2)" \
      "$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')" | grep -F "$ROOT" || true)"
    [ -n "$hits" ] && { bad=$((bad+1)); echo "FAIL ${f#$ROOT/}"; echo "$hits" | sed "s#$ROOT#<REPO>#g;s/^/    /"; }
  done
  echo "checked $n Mach-O: $bad with absolute repo paths"; [ "$bad" -eq 0 ]
}

case "${1:-all}" in
  all) require; build_tools; vendor_polyfill; stage_lldb; install_debugserver_shim; check_reloc
       msg "DONE"; "$CLANG22/bin/lldb" --version | head -1 ;;
  check) check_reloc ;;
  *) echo "usage: $0 [all|check]"; exit 1 ;;
esac
