#!/bin/sh
# Single source of truth for every pinned input. Sourced, not executed.
: "${REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
export REPO_ROOT
# Heavy build I/O (an LLVM source tree + a full Release build) must live on a LOCAL disk: this repo
# is on an NFS mount, where the build crawls and sprays AppleDouble ._* sidecars. Default to the
# local cache; the durable bits (scripts, pins) stay in the repo. Override with MAVERICKS_WORK --
# but never to a path under the NFS tree. On CI, $HOME/.cache is a fine local path too.
export WORK="${MAVERICKS_WORK:-$HOME/.cache/mavericks-clang/work}"

. "$REPO_ROOT/build/lib.sh"

# Upstream LLVM is the Renovate-tracked UPSTREAM_VERSION (bare x.y.z). The full package version lives
# in VERSION (<upstream>-mavericks.N), which the release workflow writes and .gitignore excludes; before
# a release is cut fall back to the computed auto version so a build never depends on a committed VERSION.
export LLVM_VERSION="$(upstream_version)"
if [ -f "$REPO_ROOT/VERSION" ]; then
  export PKG_VERSION="$(cat "$REPO_ROOT/VERSION")"
else
  export PKG_VERSION="$(sh "$REPO_ROOT/build/version.sh" auto | sed -n 's/^FULL=//p')"
fi

# LLVM monorepo source tarball. Verified by GPG signature against the vendored release-signer key
# (keys/llvm-release.asc) in build/build-cross.sh -- a signature verifies a version that does not
# exist yet, so a Renovate bump of UPSTREAM_VERSION is self-contained (no hand-pasted hash).
export LLVM_SRC_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"
export LLVM_SIG_URL="${LLVM_SRC_URL}.sig"

# The 10.9 legacy-support shim, fetched PREBUILT from the mavericks-legacysupport release
# (ModernMavericks/macports-legacy-support), verified against its SHA256SUMS every run. Renovate bumps
# this pin via the shared preset's `# mavericks-legacysupport` customManager (unquoted, marker on line).
export MLS_VERSION=1.5.2-mavericks.2   # mavericks-legacysupport

# The product: an arm64-hosted clang whose DEFAULT target is x86_64 Mavericks.
export TARGET_TRIPLE="x86_64-apple-macos10.9"
export MACOS_MIN="10.9"
export PREFIX="/usr/local/mavericks-clang"      # cross variant install prefix
export PKG_IDENTIFIER="dev.modernmavericks.clang"

# shared-cmake scripts dir for the shell callers (SDK fetch, compat guard, productbuild, build-info).
# mavericks-shared-cmake is a find_package package INSTALLED to a prefix and self-registered in
# CMake's user package registry -- it is NOT vendored. Resolve in the family's usual order:
#   1. $MAVERICKS_SHARED_SCRIPTS override, else
#   2. the user package registry entry (honors whatever --prefix it was installed to), else
#   3. a sibling checkout (dev-only fallback).
_mav_shared_scripts() {
  if [ -n "${MAVERICKS_SHARED_SCRIPTS:-}" ] && [ -d "$MAVERICKS_SHARED_SCRIPTS" ]; then
    printf '%s\n' "$MAVERICKS_SHARED_SCRIPTS"; return 0; fi
  for _r in "$HOME/.cmake/packages/MavericksSharedCMake/"*; do
    [ -f "$_r" ] || continue; _d="$(cat "$_r")/scripts"
    [ -d "$_d" ] && { printf '%s\n' "$_d"; return 0; }; done
  [ -d "$REPO_ROOT/../mavericks-shared-cmake/scripts" ] && \
    { printf '%s\n' "$REPO_ROOT/../mavericks-shared-cmake/scripts"; return 0; }
  return 1
}
MSC_SCRIPTS="$(_mav_shared_scripts || true)"; export MSC_SCRIPTS
