#!/bin/sh
# platform: macOS-only -- pkgutil unpacks the legacy-support .pkg
# Fetch the PREBUILT x86_64/10.9 legacy-support shim (static .a + wrapper headers) from the
# mavericks-legacysupport release. No from-source build here: the family already ports
# macports-legacy-support and publishes a .pkg, and re-deriving it would be a second answer to
# "which shim is baked in?". Integrity is re-checked against the release's SHA256SUMS EVERY run, so
# a poisoned download cache cannot silently change the shipped archive.
# Prints the path of the extracted .a on stdout; everything else goes to stderr.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/versions.sh"
: "${MLS_VERSION:?set MLS_VERSION}"

OUT="$WORK/legacy-support"
A="$OUT/lib/libMacportsLegacySupport.a"
CACHE="$WORK/legacy-support-dl"
tag="$MLS_VERSION"
pkg_name="macports-legacy-support-$MLS_VERSION.pkg"
base="https://github.com/Mavergreen/macports-legacy-support/releases/download/$tag"

mkdir -p "$CACHE"
pkg="$CACHE/$pkg_name"; sums="$CACHE/SHA256SUMS"

# Download once, atomically (tmp+mv) so an interrupted fetch cannot poison the cache.
if [ ! -f "$pkg" ]; then
  tmp="$pkg.tmp.$$"; curl -fsSL -o "$tmp" "$base/$pkg_name"; mv "$tmp" "$pkg"
fi
curl -fsSL -o "$sums" "$base/SHA256SUMS"
want=$(awk -v f="$pkg_name" '$2==f {print $1}' "$sums")
[ -n "$want" ] || { echo "FATAL: $pkg_name not listed in SHA256SUMS" >&2; exit 1; }
got=$(shasum -a 256 "$pkg" | awk '{print $1}')
[ "$want" = "$got" ] || { echo "FATAL: legacy-support pkg sha mismatch: $got != $want" >&2; rm -f "$pkg"; exit 1; }

# Extract the prebuilt static lib + headers from the pkg payload (no root, no compile).
exp="$CACHE/expanded"; rm -rf "$exp"
pkgutil --expand-full "$pkg" "$exp" 1>&2
a_src=$(find "$exp" -type f -name libMacportsLegacySupport.a | head -1)
[ -n "$a_src" ] || { echo "FATAL: libMacportsLegacySupport.a not found in pkg payload" >&2; exit 1; }
usrlocal=$(dirname "$(dirname "$a_src")")     # .../Payload/usr/local

rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/include"
cp "$usrlocal/lib/libMacportsLegacySupport.a" "$OUT/lib/"
cp -R "$usrlocal/include/LegacySupport" "$OUT/include/"
test -f "$A" || { echo "FATAL: no static .a extracted" >&2; exit 1; }

# The shim must actually be for the target we cross-build against, not the host. A .a that is
# arm64-only would link nothing and fail far later, inside the libc++ runtimes build.
lipo -info "$A" 2>/dev/null | sed -n 's/.*: //p' | grep -qw x86_64 \
  || { echo "FATAL: $A has no x86_64 slice (archs: $(lipo -info "$A" 2>&1 | sed -n 's/.*: //p'))" >&2; exit 1; }

echo "$A"
