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
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$LINT" && pass "bash-dialect-lint.sh bash -n" || fail "bash-dialect-lint.sh bash -n"

# $1=label $2=file content $3=expected rc
# Every invocation of the linter in this file is BOUNDED. bash-dialect-lint.sh's
# scan loop (line 105) is `while IFS=: read -r lineno linetext`, and negating it
# makes the linter spin at EOF and never exit -- so an unbounded call hangs this
# oracle rather than failing it, and run.sh scores the mutant UNPROVEN with
# nothing observed (backlog F22). A bound turns the hang into a named failure.
# The whole-tree run gets a wider clock than the single-vector ones: it scans
# every tracked script (measured 0.6s here, but a loaded macOS host is slower).
vector() {
  printf '%s\n' "$2" > "$TMP/v.sh"
  p_timeout 10 bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -eq 124 ]]; then
    fail "$1 — the linter did not terminate within 10s; its scan loop never reached EOF"
    # …and stop the file here. Every vector below runs the same loop, so
    # seventeen more ten-second bounds would restate one fact seventeen times
    # and push the run past run.sh's 60s per-mutant clock — converting a clean
    # `exit+failline` kill back into the timeout this was written to remove.
    printf '\n%d failure(s)\n' "$fails"
    exit "$fails"
  elif [[ "$rc" -eq "$3" ]]; then pass "$1"
  else fail "$1 — expected rc $3, got $rc"; fi
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
# marker below is deliberately reason-less (it has the required trailing `:`
# but nothing after it) and must still be flagged. Without the trailing `:`
# this vector would fail the marker regex on syntax alone — missing the
# rule-id separator, not missing a reason — and would keep passing even if
# the reason requirement itself were deleted from marker_allows(), which is
# exactly what happened: the requirement was removed and this vector still
# reported 0 failures. The outer marker (after the expected-rc `1`) is the
# real one, needed only so this source line itself passes the whole-tree
# self-scan.
vector "a marker with no reason does not suppress" \
  'GLOBSORT=name  # dialect-lint: allow GLOBSORT:' 1  # dialect-lint: allow GLOBSORT: intentional bad-marker test vector, not real usage

# The linter must read the floor rather than hardcoding it: with the floor
# lowered to 4.4, a 5.0 construct becomes a violation.
printf '%s\n' 'echo "$EPOCHREALTIME"' > "$TMP/v.sh"
# Bounded, and restructured around the bound: as an `if … then fail; else pass`
# a timeout is non-zero and lands in the PASSING branch, so the hang would have
# been reported as the linter correctly rejecting the construct.
p_timeout 10 env AI_CONTAINERS_BASH_FLOOR_MAJOR=4 AI_CONTAINERS_BASH_FLOOR_MINOR=4 \
  bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1
floor_rc=$?
if [[ "$floor_rc" -eq 124 ]]; then
  fail "the linter reads the floor — the run did not terminate within 10s"
elif [[ "$floor_rc" -eq 0 ]]; then
  fail "the linter reads the floor — a 5.0 construct passed at a 4.4 floor"
else
  pass "the linter reads the floor rather than hardcoding it"
fi

# Run against the real tree: it must be clean today. No file-level
# exclusion exists any more (see bash-dialect-lint.sh's own header) — this
# file and bash-dialect-lint.sh itself are both scanned for real, kept
# clean purely by the markers and the DOLLAR trick above.
p_timeout 30 bash "$LINT" >/dev/null 2>&1
clean_rc=$?
if [[ "$clean_rc" -eq 124 ]]; then
  fail "the repository is clean at the current floor — the whole-tree run did not terminate within 30s"
elif [[ "$clean_rc" -eq 0 ]]; then
  pass "the repository is clean at the current floor"
else
  fail "the repository is clean at the current floor"
fi

# ── The "examined no files" guard, exercised ──────────────────────────────────
# bash-dialect-lint.sh:84-87 refuses to report success when it examined nothing
# — the same rule the bash -n CI step applies to itself. It had never run:
# replacing its `exit 1` with `exit 0` produced zero test failures. A scratch git
# repo whose only tracked file is not a .sh, with the linter copied in UNTRACKED,
# makes `git ls-files '*.sh'` empty for real.
empty_repo="$TMP/emptyrepo"; mkdir -p "$empty_repo/tests"
( cd "$empty_repo" \
    && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
    && printf 'placeholder\n' > README.md && git add README.md \
    && git -c user.email=t@example -c user.name=t commit -q -m init ) >/dev/null 2>&1
cp "$LINT" "$empty_repo/tests/bash-dialect-lint.sh"   # deliberately NOT git-added
# CHECKED, AND CHECKED FOR CONTENT. An unchecked scaffold write turns a
# scaffolding LOSS into an assertion FAILURE: the run below would report
# "the empty run failed, but not with the 'examined no files' message
# (got: bash: …/emptyrepo/tests/bash-dialect-lint.sh: No such file or
# directory)" — which reads as a defect in the linter and is nothing of the
# kind. Measured on macOS, 2026-08-21: a falsify CONTROL run tripped on exactly
# that line, and the whole diagnosis was a missing file.
#
# SCAFFOLD-FAILED: is a CHANNEL, not a louder failure. tests/run-all.sh reports
# it as "could not set itself up", and tests/falsify/run.sh scores a mutant
# whose oracle said it UNPROVEN rather than KILLED — so a scaffold that
# evaporates under load stops manufacturing false kills. Read back for CONTENT
# because empty-after-write is the shape ENOSPC takes on APFS (backlog F31).
if [[ ! -s "$empty_repo/tests/bash-dialect-lint.sh" ]]; then
  printf 'SCAFFOLD-FAILED: could not stage the linter into %s (missing or empty after cp)\n' \
    "$empty_repo/tests"
  exit 1
fi
# The floor is passed in so the copy needs no bash-floor.sh beside it (the
# linter skips its own source when both vars are already set).
p_timeout 10 env AI_CONTAINERS_BASH_FLOOR_MAJOR=5 AI_CONTAINERS_BASH_FLOOR_MINOR=1 \
  bash "$empty_repo/tests/bash-dialect-lint.sh" > "$TMP/empty.out" 2>&1
empty_rc=$?
if [[ "$empty_rc" -eq 124 ]]; then
  fail "a lint run that examined no files fails, and says why — it did not terminate within 10s"
elif [[ "$empty_rc" -eq 0 ]]; then
  fail "a lint run that examined no files reported SUCCESS"
elif grep -q 'examined no files' "$TMP/empty.out"; then
  pass "a lint run that examined no files fails, and says why"
else
  fail "the empty run failed, but not with the 'examined no files' message (got: $(head -2 "$TMP/empty.out" | tr '\n' ' '))"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
