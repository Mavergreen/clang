/*
 * 10.9 SDK back-fill: make <sys/_types/_mbstate_t.h> self-contained.
 *
 * WHY THIS EXISTS: the 10.9 SDK's copy is
 *
 *     #ifndef _MBSTATE_T
 *     #define _MBSTATE_T
 *     typedef __darwin_mbstate_t mbstate_t;
 *     #endif
 *
 * with nothing that defines __darwin_mbstate_t. It works only because 10.9 reaches it exclusively
 * from <wchar.h>, which has already pulled in <sys/_types.h> -> <machine/_types.h>. Later SDKs
 * include <sys/_types.h> from the header itself; 10.9 does not.
 *
 * Modern libc++ (__mbstate_t.h) probes with __has_include(<sys/_types/_mbstate_t.h>) and, finding it,
 * includes it STANDALONE -- so on 10.9 every #include <iostream> fails with
 *
 *     error: unknown type name '__darwin_mbstate_t'
 *
 * Stock upstream macports-legacy-support does not cover this (nothing in its headers mentions
 * mbstate). It is the second of Wowfunhappy's back-fills that the family's port lacks --
 * native-bootstrap/build.sh names mbstate_t alongside aligned_alloc -- so, per the spec, it is
 * carried here as a tracked patch rather than pulled from a private fork.
 *
 * Shipped as an overlay include dir (-isystem .../include/mavericks-compat) placed BEFORE the SDK, so
 * #include_next reaches Apple's real header. Kept OUT of the vendored LegacySupport/ tree, which stays
 * a verbatim copy of upstream.
 */
#ifndef MAVERICKS_COMPAT_SYS_TYPES_MBSTATE_T_H
#define MAVERICKS_COMPAT_SYS_TYPES_MBSTATE_T_H

/* Defines __darwin_mbstate_t (via <machine/_types.h>) before the SDK header typedefs it. */
#include <sys/_types.h>

#include_next <sys/_types/_mbstate_t.h>

#endif /* MAVERICKS_COMPAT_SYS_TYPES_MBSTATE_T_H */
