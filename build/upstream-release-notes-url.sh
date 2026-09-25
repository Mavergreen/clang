#!/bin/sh
# platform: host-agnostic
# Print the URL of the release notes for one upstream LLVM version. shipyard's
# upstream-notes.sh links it from our release notes when a release ships a NEW upstream.
#   usage: upstream-release-notes-url.sh <upstream-version>      (bare: 22.1.1)
set -eu
printf 'https://github.com/llvm/llvm-project/releases/tag/llvmorg-%s\n' "${1:?usage: upstream-release-notes-url.sh <upstream-version>}"
