#!/usr/bin/env bash
# The dialect linter must reject constructs newer than the declared floor.
# Vectors run against throwaway files, never the real tree.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$REPO_DIR/tests/bash-dialect-lint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$LINT" && pass "bash-dialect-lint.sh bash -n" || fail "bash-dialect-lint.sh bash -n"

# $1=label $2=file content $3=expected rc
vector() {
  printf '%s\n' "$2" > "$TMP/v.sh"
  bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -eq "$3" ]]; then pass "$1"; else fail "$1 — expected rc $3, got $rc"; fi
}

vector "plain script passes"            'printf "%s\n" "$1"'                 0
vector "5.3 value substitution rejected" 'x=${ printf hi; }'                  1
vector "5.3 BASH_MONOSECONDS rejected"   'echo "$BASH_MONOSECONDS"'           1
vector "5.3 GLOBSORT rejected"           'GLOBSORT=name'                      1
vector "5.2 globskipdots rejected"       'shopt -s globskipdots'              1
vector "5.1 SRANDOM allowed (at floor)"  'echo "$SRANDOM"'                    0
vector "5.0 EPOCHREALTIME allowed"       'echo "$EPOCHREALTIME"'              0
vector "4.4 \${var@Q} allowed"           'echo "${x@Q}"'                      0
vector "4.3 local -n allowed"            'f() { local -n r=$1; }'             0
# A construct inside a comment is not a use.
vector "commented construct allowed"     '# x=${ printf hi; }'                0
# A `#` that is parameter-expansion prefix removal (${var#pattern}) is not a
# comment; a real violation later on the same line must still be caught.
vector "#-prefix expansion does not mask a later violation" \
  'x="${bar#prefix}"; y=${ printf hi; }'                                      1

# The linter must read the floor rather than hardcoding it: with the floor
# lowered to 4.4, a 5.0 construct becomes a violation.
printf '%s\n' 'echo "$EPOCHREALTIME"' > "$TMP/v.sh"
if AI_CONTAINERS_BASH_FLOOR_MAJOR=4 AI_CONTAINERS_BASH_FLOOR_MINOR=4 \
     bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1; then
  fail "the linter reads the floor — a 5.0 construct passed at a 4.4 floor"
else
  pass "the linter reads the floor rather than hardcoding it"
fi

# Run against the real tree: it must be clean today.
bash "$LINT" >/dev/null 2>&1 \
  && pass "the repository is clean at the current floor" \
  || fail "the repository is clean at the current floor"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
