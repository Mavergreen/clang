# build/lib.sh -- sourced helpers. The shared implementations (upstream_version, msc_scripts) live in
# shared-cmake; this only locates them. Add repo-specific helpers below, not copies of shared ones.
: "${MAVERICKS_ROOT:=$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." 2>/dev/null && pwd || pwd)}"
export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/msc.sh"
. "$MSC/lib.sh"

# How many compile jobs an LLVM build may run at once.
#
# NOT just $(sysctl -n hw.ncpu). LLVM's heavier C++ translation units (DAGCombiner,
# LegalizeVectorTypes, the SelectionDAG family) peak well above 1GB of compiler memory each, so one
# job per core needs far more RAM than a core-count implies. On a 16GB box with swap disabled --
# `sysctl vm.swapusage` reporting total = 0.00M, which is not exotic on a tuned workstation -- the
# kernel simply SIGKILLs the compiler, and ninja reports the useless
#
#   build-native.sh: line NN: 27975 Killed: 9    ninja -C ... -j 8
#
# with no error above it to explain why. Measured here: -j8 died around 2000/4353 objects.
#
# So cap on BOTH cores and memory, at roughly 3GB per job. A CI runner with plenty of RAM is unaffected
# (its core count stays the binding constraint); a memory-tight machine slows down instead of failing.
# Override with MAVERICKS_JOBS when you know better than the heuristic.
# --- CI-only helpers (env-guarded; a plain local build sets neither var and is unaffected) -------

# ccache launcher flags for cmake, only when explicitly requested AND ccache is present.
mav_ccache_args() {
  if [ "${MAVERICKS_USE_CCACHE:-}" = 1 ] && command -v ccache >/dev/null 2>&1; then
    printf '%s' "-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
  fi
}

# Run ninja, bounded by MAVERICKS_BUILD_DEADLINE (epoch seconds) when set: stop gracefully with
# headroom so ccache still saves and a re-run resumes warm. Returns 75 (incomplete) if under two
# minutes remain, or if the run was cut short; the caller's `set -e` then aborts before install and
# packaging, and the workflow additionally detects incompleteness by the absence of the staged
# toolchain.
#
# THE BOUND IS ENFORCED IN-SHELL, NOT VIA timeout(1). macOS ships no timeout -- it is GNU coreutils,
# absent from a stock GitHub-hosted macos runner. Shelling out to it would return 127, which `|| return
# 75` turns into "build INCOMPLETE (hit the budget)" on EVERY run, blaming a budget overflow that never
# happened. Probing for timeout/gtimeout and falling back would work, but then the bounding path
# differs between a dev box that happens to have coreutils and CI that does not -- and the untested
# path is the one that matters. One implementation, identical everywhere.
#
# SIGTERM (not KILL) so ninja tears down its children and leaves a consistent build dir; everything
# already compiled stays in ccache, which is the whole point of stopping early.
mav_ninja() {
  [ -n "${MAVERICKS_BUILD_DEADLINE:-}" ] || { ninja "$@"; return $?; }

  _rem=$(( MAVERICKS_BUILD_DEADLINE - $(date +%s) ))
  if [ "$_rem" -le 120 ]; then
    echo "mav_ninja: <2m of build budget left; stopping to preserve ccache (resume by re-running)" >&2
    return 75
  fi

  ninja "$@" & _mav_nj=$!
  ( sleep "$_rem"; kill -TERM "$_mav_nj" 2>/dev/null ) & _mav_wd=$!
  _mav_rc=0; wait "$_mav_nj" || _mav_rc=$?
  kill -TERM "$_mav_wd" 2>/dev/null || :
  wait "$_mav_wd" 2>/dev/null || :
  if [ "$_mav_rc" -ne 0 ]; then
    echo "mav_ninja: build stopped short (rc=$_mav_rc); ccache is preserved -- re-run to resume" >&2
    return 75
  fi
}

mavericks_build_jobs() {
  if [ -n "${MAVERICKS_JOBS:-}" ]; then printf '%s\n' "$MAVERICKS_JOBS"; return 0; fi
  _ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  _memgb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 ))"
  _memjobs="$(( _memgb / 3 ))"
  [ "$_memjobs" -lt 1 ] && _memjobs=1
  if [ "$_memjobs" -lt "$_ncpu" ]; then printf '%s\n' "$_memjobs"; else printf '%s\n' "$_ncpu"; fi
}
