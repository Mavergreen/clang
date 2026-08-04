/*
 * aligned_alloc back-fill for the x86_64/10.9 runtimes build.
 *
 * WHY THIS EXISTS: LLVM 22's libc++ hardcodes _LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION to 1 on Apple
 * (libcxx/include/__config: the Apple case falls through to the unconditional `#define ... 1`, and
 * the old _LIBCPP_HAS_NO_LIBRARY_ALIGNED_ALLOCATION escape hatch is gone), so
 * libcxx/src/include/aligned_alloc.h calls ::aligned_alloc unconditionally. aligned_alloc is C11 and
 * arrived on macOS in 10.15; the pinned 10.9 SDK predates it entirely, so libc++abi fails to compile:
 *
 *   aligned_alloc.h:44:12: error: no member named 'aligned_alloc' in the global namespace
 *
 * Stock upstream macports-legacy-support does NOT back-fill it -- its stdlib.h wrapper declares
 * posix_memalign and arc4random only, and libMacportsLegacySupport.a defines no aligned_alloc. This
 * is the one place Wowfunhappy's forked shim carried a back-fill that the family's port does not
 * (native-bootstrap/build.sh names mbstate_t, aligned_alloc and the *at family among its wrapper
 * headers), so the
 * spec's instruction applies: carry it as a TRACKED patch here, never a private source.
 *
 * The implementation is the same substitution libc++ itself makes on platforms without aligned_alloc
 * (Android below API 28): posix_memalign, which 10.9 has. libc++'s caller already rounds the size up
 * to a multiple of the alignment, so the C11 precondition is met.
 *
 * SCOPE: force-included into the RUNTIMES sub-build only (build/build-cross.sh), never into the
 * shipped clang.cfg -- force-including a header on every user invocation breaks build systems that
 * probe the compiler, which is why native-bootstrap/build.sh deliberately dropped that approach for
 * the product. __ASSEMBLER__ is guarded for the same reason it is there: compiler-rt has .S sources,
 * and C declarations fed to the integrated assembler are rejected outright.
 */
#ifndef MAVERICKS_ALIGNED_ALLOC_H
#define MAVERICKS_ALIGNED_ALLOC_H

#ifndef __ASSEMBLER__

#include <Availability.h>
#include <stdlib.h>

/* Only where the deployment target genuinely lacks it; a future SDK/min bump makes this vanish
   rather than collide with the real declaration. */
#if !defined(__MAC_OS_X_VERSION_MIN_REQUIRED) || __MAC_OS_X_VERSION_MIN_REQUIRED < 101500

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((unused)) static inline void *aligned_alloc(size_t __alignment, size_t __size) {
  void *__p = 0;
  return posix_memalign(&__p, __alignment, __size) ? 0 : __p;
}

#ifdef __cplusplus
}
#endif

#endif /* deployment target < 10.15 */

#endif /* __ASSEMBLER__ */

#endif /* MAVERICKS_ALIGNED_ALLOC_H */
