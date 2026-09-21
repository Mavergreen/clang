# build/lib.sh -- sourced helpers. The shared implementations (upstream_version, msc_scripts) live in
# shipyard; this only locates them. Add repo-specific helpers below, not copies of shared ones.

# platform: a family checkout may live on NFS, where this build cost 11.16s wall / 25% CPU against
#           2.96s / 88% on local disk, with identical user time -- the whole difference is I/O wait.
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
export MAVERICKS_BUILD_ROOT

: "${MAVERICKS_ROOT:=$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." 2>/dev/null && pwd || pwd)}"
export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/msc.sh"
. "$SHIPYARD/lib.sh"

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

mavericks_build_jobs() {
  if [ -n "${MAVERICKS_JOBS:-}" ]; then printf '%s\n' "$MAVERICKS_JOBS"; return 0; fi
  _ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  _memgb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 ))"
  _memjobs="$(( _memgb / 3 ))"
  [ "$_memjobs" -lt 1 ] && _memjobs=1
  if [ "$_memjobs" -lt "$_ncpu" ]; then printf '%s\n' "$_memjobs"; else printf '%s\n' "$_ncpu"; fi
}
