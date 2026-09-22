#!/bin/sh
# The flag-day preinstall (build/flag-day-preinstall.sh) forgets the pre-rename receipt on
# Installer's target volume, only there, and never fails the install. pkgutil is a PATH stub that
# records its arguments, so nothing here touches a real receipt database.
# DELETABLE with build/flag-day-preinstall.sh (shipyard SKILL.md "Consolidation backlog").
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
t="$(mktemp -d "${TMPDIR:-/tmp}/flagday.XXXXXX")"
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$t/bin" "$t/vol"
cat > "$t/bin/pkgutil" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$t/pkgutil.log"
exit \${PKGUTIL_RC:-0}
EOF
chmod +x "$t/bin/pkgutil"

sh "$ROOT/build/flag-day-preinstall.sh" dev.modernmavericks.clang.clang22 "$t/s/preinstall"
[ -x "$t/s/preinstall" ] || fail "no executable preinstall rendered"

# Installer runs preinstall as: $1 pkg path, $2 install location, $3 target volume, $4 system root.
PATH="$t/bin:$PATH" "$t/s/preinstall" /x.pkg / "$t/vol" / || fail "preinstall failed"
[ "$(cat "$t/pkgutil.log")" = "--volume $t/vol --forget dev.modernmavericks.clang.clang22" ] \
  || fail "expected the old receipt forgotten on the target volume, got: $(cat "$t/pkgutil.log")"

# A pkgutil that fails (no such receipt: every fresh install) must not fail the install.
rm -f "$t/pkgutil.log"
PATH="$t/bin:$PATH" PKGUTIL_RC=1 "$t/s/preinstall" /x.pkg / "$t/vol" / || fail "a failing pkgutil failed the install"

# No target volume: nothing is known about where an old install lives, so nothing is done.
rm -f "$t/pkgutil.log"
PATH="$t/bin:$PATH" "$t/s/preinstall" || fail "preinstall with no args failed"
[ ! -f "$t/pkgutil.log" ] || fail "pkgutil ran with no target volume: $(cat "$t/pkgutil.log")"

# Only an OLD identifier may be forgotten: a slip that passed the new one would forget this very pkg.
if sh "$ROOT/build/flag-day-preinstall.sh" dev.mavergreen.clang.clang22 "$t/bad" 2>/dev/null; then
  fail "rendered a preinstall that forgets a dev.mavergreen.* receipt"
fi

# Both variants ship it, derived from their own (new) identifier.
for v in native cross; do
  grep -q 'flag-day-preinstall.sh" "dev.modernmavericks.${[A-Z]*_IDENTIFIER#dev.mavergreen.}"' \
    "$ROOT/build/package-$v-pkg.sh" || fail "package-$v-pkg.sh does not render the flag-day preinstall"
done
echo "OK: flag-day preinstall"
