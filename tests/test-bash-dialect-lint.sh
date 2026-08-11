#!/usr/bin/env bash
# The dialect linter must reject constructs newer than the declared floor.
# Vectors run against throwaway files, never the real tree, EXCEPT where a
# vector's own source line is noted below — this file is itself part of the
# tracked corpus the linter's default (no-args) invocation scans, so a
# vector line that unavoidably contains a real construct as test DATA
# carries its own `# dialect-lint: allow RULE-ID: reason` marker, exactly
# like a normal file would. Where a construct CAN be kept out of this
# file's own source (built at runtime instead of written literally), that
# is done instead of adding a marker — see the DOLLAR trick below.
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

# Builds the brace-space value-substitution construct at runtime, so this
# vector's OWN source line below never contains the literal substring the
# dollar-brace-space rule detects — no marker needed for it, unlike the
# rules further down whose name IS the literal being detected.
DOLLAR='$'

vector "plain script passes"            'printf "%s\n" "$1"'                 0
vector "5.3 value substitution rejected" "x=${DOLLAR}{ printf hi; }"          1
vector "5.3 BASH_MONOSECONDS rejected"   'echo "$BASH_MONOSECONDS"'           1  # dialect-lint: allow BASH_MONOSECONDS: intentional bad-code test vector, not real usage
vector "5.3 GLOBSORT rejected"           'GLOBSORT=name'                      1  # dialect-lint: allow GLOBSORT: intentional bad-code test vector, not real usage
vector "5.2 globskipdots rejected"       'shopt -s globskipdots'              1  # dialect-lint: allow globskipdots: intentional bad-code test vector, not real usage
vector "5.1 SRANDOM allowed (at floor)"  'echo "$SRANDOM"'                    0
vector "5.0 EPOCHREALTIME allowed"       'echo "$EPOCHREALTIME"'              0
vector "4.4 \${var@Q} allowed"           'echo "${x@Q}"'                      0
vector "4.3 local -n allowed"            'f() { local -n r=$1; }'             0

# A `#` that is parameter-expansion prefix removal (${var#pattern}) must not
# hide a real violation later on the same line.
vector "#-prefix expansion does not mask a later violation" \
  'x="${bar#prefix}"; y=${ printf hi; }' 1  # dialect-lint: allow dollar-brace-space: intentional bad-code test vector, not real usage

# A `#` inside a quoted string is not a comment either — same requirement.
vector "a quoted # does not mask a later violation" \
  'x="a value # containing hash"; y=${ printf hi; }' 1  # dialect-lint: allow dollar-brace-space: intentional bad-code test vector, not real usage

# Nor is a `#` inside a bracket expression.
vector "a bracket-expression # does not mask a later violation" \
  'case $x in [ #]*) y=${ printf hi; };; esac' 1  # dialect-lint: allow dollar-brace-space: intentional bad-code test vector, not real usage

# The linter matches the raw line: a comment needs no space after `;` in
# real bash, and this one is flagged anyway. That is an accepted
# false-positive in the safe direction (see the header of the linter
# itself), not a bug — this vector pins the direction of the bias.
vector "a comment with no space after ; is still flagged (accepted false positive)" \
  'echo hi;#GLOBSORT' 1  # dialect-lint: allow GLOBSORT: intentional bad-code test vector, not real usage

# A shopt option is detected wherever it appears in the argument list, not
# only when it immediately follows -s/-u.
vector "a shopt option after another option name is still detected" \
  'shopt -s extglob globskipdots' 1  # dialect-lint: allow globskipdots: intentional bad-code test vector, not real usage

# Comments are no longer exempt by default — a construct merely named in a
# comment is flagged unless that specific line carries a marker.
vector "a bare comment naming a construct is flagged by default" \
  '# x=${ printf hi; }' 1  # dialect-lint: allow dollar-brace-space: intentional bad-code test vector, not real usage

# A marker WITH a reason suppresses that line for that rule only. This
# marker is real (has a reason) so it also keeps THIS test file's own
# source line clean under the linter's default whole-tree scan — no
# separate outer marker needed, unlike the vector below.
vector "a marker with a reason suppresses that line" \
  'GLOBSORT=name  # dialect-lint: allow GLOBSORT: legacy shim retained for bash 5.3 compatibility, version-guarded' 0

# A marker with NO reason does not suppress anything — the throwaway file's
# marker below is deliberately reason-less and must still be flagged. The
# outer marker (after the expected-rc `1`) is the real one, needed only so
# this source line itself passes the whole-tree self-scan.
vector "a marker with no reason does not suppress" \
  'GLOBSORT=name  # dialect-lint: allow GLOBSORT' 1  # dialect-lint: allow GLOBSORT: intentional bad-marker test vector, not real usage

# The linter must read the floor rather than hardcoding it: with the floor
# lowered to 4.4, a 5.0 construct becomes a violation.
printf '%s\n' 'echo "$EPOCHREALTIME"' > "$TMP/v.sh"
if AI_CONTAINERS_BASH_FLOOR_MAJOR=4 AI_CONTAINERS_BASH_FLOOR_MINOR=4 \
     bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1; then
  fail "the linter reads the floor — a 5.0 construct passed at a 4.4 floor"
else
  pass "the linter reads the floor rather than hardcoding it"
fi

# Run against the real tree: it must be clean today. No file-level
# exclusion exists any more (see bash-dialect-lint.sh's own header) — this
# file and bash-dialect-lint.sh itself are both scanned for real, kept
# clean purely by the markers and the DOLLAR trick above.
bash "$LINT" >/dev/null 2>&1 \
  && pass "the repository is clean at the current floor" \
  || fail "the repository is clean at the current floor"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
