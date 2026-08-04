#!/bin/sh
# Flag any Mach-O load command (dependency / install-name / rpath) that names an absolute path the
# INSTALLED toolchain will not have.
#
# The obvious offender is the build scratch dir ($WORK): a dylib whose install_name still points into
# ~/.cache builds fine and dies on the first machine that is not this one. But the subtler and more
# likely one is a BUILD-HOST PACKAGE MANAGER: CMake happily finds /opt/pkg (pkgsrc) or /opt/homebrew
# (a GHA runner) while probing for zstd/zlib/libedit and bakes that path into clang's load commands.
# The result ships, installs, and fails at first launch on a user's machine with a missing dylib --
# which a $WORK-only grep would never have caught. So the rule is a WHITELIST, not a blacklist:
#
#   allowed: @rpath/@loader_path/@executable_path (relative by construction)
#            /usr/lib/**, /System/**             (present on every macOS)
#            $PREFIX/**                          (our own install location -- the pkg puts it there)
#   flagged: every other absolute path
#
#   usage: verify-relocatable.sh <prefix>
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
P="${1:?usage: verify-relocatable.sh <prefix>}"
n=0; bad=0
tmp="$(mktemp)"
# `|| true`: find exits non-zero when one of these dirs is absent, which under set -e would abort the
# audit before it printed a thing -- a silent pass is the one outcome a gate must never have.
find "$P/bin" "$P/lib" "$P/libexec" -type f 2>/dev/null > "$tmp" || true
[ -s "$tmp" ] || { echo "FATAL: no files under $P/{bin,lib,libexec} -- nothing audited" >&2; exit 1; }
# Read from a FILE, not a pipeline: a `while … | read` runs in a subshell and would lose n/bad.
while IFS= read -r f; do
  file "$f" 2>/dev/null | grep -q Mach-O || continue
  n=$((n+1))
  paths="$(printf '%s\n%s\n%s\n' \
    "$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')" \
    "$(otool -D "$f" 2>/dev/null | tail -n +2)" \
    "$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')")"
  hits=""
  for p in $paths; do
    case "$p" in
      @*|"") continue ;;                       # @rpath &c -- relative by construction
      /usr/lib/*|/System/*) continue ;;        # on every macOS
      "$PREFIX"/*) continue ;;                 # where the pkg actually installs us
      /*) hits="$hits$p
" ;;
    esac
  done
  if [ -n "$hits" ]; then
    bad=$((bad+1))
    echo "FAIL ${f#"$P"/}"
    printf '%s' "$hits" | sed "s#$WORK#<WORK>#g;s/^/    /"
  fi
done < "$tmp"
rm -f "$tmp"
echo "checked $n Mach-O under $P: $bad with unshippable absolute paths"
[ "$bad" -eq 0 ]
