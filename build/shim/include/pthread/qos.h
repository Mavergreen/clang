/*
 * <pthread/qos.h> back-fill for the 10.9 target.
 *
 * WHY THIS EXISTS: Darwin's QoS API (qos_class_t, pthread_set_qos_class_self_np) arrived in macOS
 * 10.10. The pinned 10.9 SDK has no pthread/ directory at all. LLVM's
 * llvm/lib/Support/Unix/Threading.inc includes <pthread/qos.h> under a bare `#if defined(__APPLE__)`
 * and uses the API under a bare `#elif defined(__APPLE__)` -- no availability check anywhere -- so
 * building LLVM's own host tools for 10.9 fails outright:
 *
 *   Threading.inc:25:10: fatal error: 'pthread/qos.h' file not found
 *
 * DECISION, not a mechanical fix. Unlike the aligned_alloc and mbstate_t back-fills, which paper over
 * places the 10.9 SDK is internally inconsistent (a header that will not compile standalone; a
 * function libc++ hard-requires), QoS is a real 10.10 FEATURE that 10.9 genuinely lacks. There is
 * nothing to polyfill: a 10.9 kernel has no quality-of-service classes.
 *
 * So this declares the interface and implements the setter as a no-op that REPORTS FAILURE. That is
 * the honest answer on 10.9, and it is exactly the answer LLVM already handles -- its caller maps a
 * non-zero return to SetThreadPriorityResult::FAILURE, which is what it yields on every platform
 * without QoS. Thread-priority hints are advisory; losing them costs scheduling niceness, nothing
 * more.
 *
 * The consequence worth stating plainly: this header SHIPS (it lives in the overlay the toolchain
 * installs as include/mavericks-compat and references from clang.cfg), so user code targeting 10.9
 * that calls these APIs will now compile and silently get failure at runtime instead of a build
 * error. That is the same bargain the rest of the polyfill makes.
 *
 * If a future SDK/deployment target does provide the real header, #include_next hands off to it and
 * none of this applies.
 */
#ifndef MAVERICKS_COMPAT_PTHREAD_QOS_H
#define MAVERICKS_COMPAT_PTHREAD_QOS_H

#ifndef __ASSEMBLER__

#if defined(__has_include_next) && __has_include_next(<pthread/qos.h>)
#  include_next <pthread/qos.h>
#else

#include <sys/cdefs.h>

__BEGIN_DECLS

/* Values are Apple's own, so a binary built here agrees with one built against a real SDK. */
typedef enum {
  QOS_CLASS_USER_INTERACTIVE = 0x21,
  QOS_CLASS_USER_INITIATED   = 0x19,
  QOS_CLASS_DEFAULT          = 0x15,
  QOS_CLASS_UTILITY          = 0x11,
  QOS_CLASS_BACKGROUND       = 0x09,
  QOS_CLASS_UNSPECIFIED      = 0x00
} qos_class_t;

/* static inline, not an extern: 10.9's libSystem exports no such symbol, so a declaration alone
   would only move the failure from compile time to link time. */
__attribute__((unused)) static inline int
pthread_set_qos_class_self_np(qos_class_t __qos_class, int __relative_priority) {
  (void)__qos_class;
  (void)__relative_priority;
  return -1;            /* "could not set" -- see the header comment */
}

__attribute__((unused)) static inline qos_class_t qos_class_self(void) {
  return QOS_CLASS_DEFAULT;
}

__attribute__((unused)) static inline qos_class_t qos_class_main(void) {
  return QOS_CLASS_DEFAULT;
}

__END_DECLS

#endif /* no real <pthread/qos.h> */

#endif /* __ASSEMBLER__ */

#endif /* MAVERICKS_COMPAT_PTHREAD_QOS_H */
