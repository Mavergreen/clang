# Build ingredients

Everything baked into the shipped cross `.pkg`, where it is pinned, and how a change to it reaches a
release. An *ingredient* is an input to the product; the *own upstream* is the thing this repo exists
to port. An own-upstream bump cuts `<upstream>-mavericks.1`; an ingredient bump cuts a
`-mavericks.(N+1)` repackage of the same upstream, via
`.github/workflows/repackage-on-ingredient-bump.yml`.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| LLVM/Clang source (own upstream) | `UPSTREAM_VERSION` | ✅ customManager → `github-tags` on `llvm/llvm-project` | `release.yml` on push to main cuts `-mavericks.1` |
| macports-legacy-support shim (prebuilt) | `MLS_VERSION # mavericks-legacysupport` in `build/versions.sh` | ✅ shared preset's `# mavericks-legacysupport` customManager | `build/versions.sh` is a watched path → repackage dispatched |
| LLVM release-signing keys | `keys/llvm-release.asc` | ❌ **untrackable — manual refresh** (see below) | not a watched path; a stale bundle fails the build loudly, never silently |
| MacOSX10.9 SDK | `ModernMavericks/shared-cmake@v1` (`fetch_sdk.sh`) | ✅ github-actions manager tracks the tag | `@v1` is a *moving* tag, so content moves without any path here changing |

Not ingredients: `build/*.sh` and `native-bootstrap/` are this repo's own recipe — a change there is a
repackage you cut deliberately (`workflow_dispatch` with `local_release=true`), not something Renovate
drives.

## Why no source checksum is pinned for LLVM

There is no `LLVM_SHA256` in `build/versions.sh` on purpose. A pinned hash cannot vouch for a tarball
that does not exist yet, so it is exactly the thing that blocks the bot: every LLVM bump would need a
human to fetch and paste one. Instead `build/build-cross.sh` GPG-verifies
`llvm-project-<ver>.src.tar.xz` against `keys/llvm-release.asc` — a signature vouches for bytes nobody
has seen, which is what makes a Renovate bump of `UPSTREAM_VERSION` self-contained.

## Why the LLVM signing keys are untracked

`keys/llvm-release.asc` is LLVM's published release-key bundle, fetched verbatim from
<https://releases.llvm.org/release-keys.asc> — the URL llvm/llvm-project's own release body names
under "Verifying Packages". There is no version or datasource for Renovate to compare against, so
there is nothing to track.

It carries **all six** LLVM release managers rather than only whoever signed the currently pinned
release. LLVM rotates who cuts a release (22.1.1 was Douglas Yung), so a single-key bundle would make
a routine Renovate bump fail on an unrelated-looking GPG error the day the rotation lands — defeating
the point of preferring a signature to a hash. Carrying the set LLVM publishes for this purpose is
their own trust model, not a widening of ours. Refresh the file if LLVM adds a release manager; the
failure mode is a loud build failure at `gpg --verify`, never a silent downgrade.

## Conformance deviations

- **floor:mavericks-clang-cross-\*.pkg** — this variant RUNS on modern macOS and only TARGETS 10.9, so
  it declares no 10.9.5 install floor (golang cross-pkg precedent).
- **updater:mavericks-clang-cross-\*.pkg** — no Sparkle updater in this phase (swift-toolchain
  precedent for a heavy dev toolchain); added in a later phase.
- **sdk:not-redistributed** — the Apple MacOSX10.9 SDK is not baked into the artifact. The pkg ships
  `libexec/fetch_sdk.sh` and the SDK is fetched at first use (golang precedent + redistribution
  cleanliness).
