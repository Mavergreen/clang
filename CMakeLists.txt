cmake_minimum_required(VERSION 3.16)
# Builds a Cocoa/Sparkle updater .app for one of the two clang-22 products. The LLVM toolchain itself
# is built by build/*.sh (pure shell); CMake exists here ONLY for the updater, exactly as
# mavericks-golang isolates it.
#   -DCLANG_VARIANT=native (default): updates the NATIVE .pkg; x86_64/min-10.9 (runs on the 10.9 box).
#   -DCLANG_VARIANT=cross           : updates the CROSS .pkg; arm64/min-11 (runs on the dev Mac).
# Each links the matching Sparkle slice, derived automatically from CMAKE_OSX_ARCHITECTURES by
# mavericks_add_updater_app. Native and cross use SEPARATE build dirs.
set(CLANG_VARIANT "native" CACHE STRING "which product this updater updates: native | cross")

# Before project(): CMAKE_OSX_* only take effect if set ahead of the compiler/platform checks.
if(CLANG_VARIANT STREQUAL "native")
  set(CMAKE_OSX_DEPLOYMENT_TARGET 10.9 CACHE STRING "native updater runs on 10.9")
  set(CMAKE_OSX_ARCHITECTURES x86_64 CACHE STRING "Intel-only (10.9)")
elseif(CLANG_VARIANT STREQUAL "cross")
  set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0 CACHE STRING "arm64 macOS floor")
  set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "native Apple Silicon")
else()
  message(FATAL_ERROR "CLANG_VARIANT must be 'native' or 'cross' (got '${CLANG_VARIANT}')")
endif()

project(ClangUpdater LANGUAGES OBJC)

find_package(MavericksSharedCMake REQUIRED)
include(Mavericks)          # AppleClang gate + build conventions
include(MavericksSparkle)   # the Sparkle updater .app builder

# VERSION is written by release.yml (or a local `sh build/version.sh auto`) and is gitignored, so a
# fresh checkout has none. Say that outright: the alternative is file(STRINGS) returning empty and the
# line regex below failing with a message about a version nobody tried to set.
if(NOT EXISTS "${CMAKE_SOURCE_DIR}/VERSION")
  message(FATAL_ERROR
    "no ${CMAKE_SOURCE_DIR}/VERSION -- it is gitignored and written per build. Run:\n"
    "  sh build/version.sh auto | sed -n 's/^FULL=//p' > VERSION")
endif()
file(STRINGS "${CMAKE_SOURCE_DIR}/VERSION" MAV_CLANG_VERSION LIMIT_COUNT 1)

# The clang LINE is the LLVM MAJOR (lines/22). Derive it from VERSION so the feed URL, the prefix
# named in the update dialog, and the product title stay honest if a new line ever appears.
string(REGEX REPLACE "^([0-9]+)\\..*$" "\\1" MAV_CLANG_LINE "${MAV_CLANG_VERSION}")
if(NOT MAV_CLANG_LINE MATCHES "^[0-9]+$")
  message(FATAL_ERROR "cannot derive the clang line from VERSION '${MAV_CLANG_VERSION}'")
endif()

if(CLANG_VARIANT STREQUAL "native")
  set(_name       ClangUpdater)
  set(_product    "Mavericks Clang ${MAV_CLANG_LINE}")
  set(_bundle     dev.modernmavericks.ClangUpdater)
  # Per-LINE feed, not /latest/: the repo's newest release may belong to another line, which would
  # offer a 22 user a 23 upgrade unasked -- and, once 22.1.2 ships after 23.1.0, would leave 23 users
  # seeing nothing at all (Sparkle never offers a lower version, so it stalls).
  set(_feed       "https://github.com/ModernMavericks/clang/releases/download/feed-${MAV_CLANG_LINE}/appcast.xml")
  set(_logprefix  "MavClangUpdater")
  set(_confirmbody "The clang toolchain in /usr/local/mavericks-clang-${MAV_CLANG_LINE} was updated.")
  set(_relaunch   "/tmp/.mavericks-clang-updater-relaunched")
else()
  set(_name       ClangCrossUpdater)
  set(_product    "Mavericks Clang ${MAV_CLANG_LINE} (cross)")
  set(_bundle     dev.modernmavericks.ClangCrossUpdater)
  set(_feed       "https://github.com/ModernMavericks/clang/releases/download/feed-${MAV_CLANG_LINE}/appcast-cross.xml")
  set(_logprefix  "MavClangCrossUpdater")
  set(_confirmbody "The cross toolchain in /usr/local/mavericks-clang-${MAV_CLANG_LINE}-cross was updated.")
  set(_relaunch   "/tmp/.mavericks-clang-cross-updater-relaunched")
endif()

# No ICON: this product ships the standard macOS app icon ON PURPOSE, which the icon gate demands you
# say out loud -- here, by configuring with -DMAVERICKS_ALLOW_GENERIC_ICON=ON. Passing a stand-in
# .icns instead would be the placeholder the gate exists to reject. See updater/ICON-CREDIT.txt.
mavericks_add_updater_app(
  NAME ${_name}
  PRODUCT_NAME "${_product}"
  BUNDLE_ID ${_bundle}
  FEED_URL "${_feed}"
  VERSION "${MAV_CLANG_VERSION}"
  LOG_PREFIX "${_logprefix}"
  CONFIRM_TITLE "${_product} updated"
  CONFIRM_BODY "${_confirmbody}"
  RELAUNCH_MARKER "${_relaunch}"
  # no PANE_HINT_KEY -> a background-found update posts an NSUserNotification (CLI toolchain, no pane)
)
