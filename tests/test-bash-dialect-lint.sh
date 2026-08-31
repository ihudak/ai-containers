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
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# Confined to the owning process — the fixture must survive a forked child
# running this trap (F30/F32/F64; tests/test-exit-trap-ownership.sh).
# $BASHPID, not $$: $$ is unchanged in a subshell and would guard nothing.
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
fails=0
# The worst single-file lint seen so far, in ms; the whole-tree bound is a
# multiple of it. Declared here because vector() writes it and the whole-tree
# assertion reads it.
unit_ms=0
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
# every tracked script (measured 0.6s here, but a loaded macOS host is slower),
# and that clock is CALIBRATED from these vectors rather than fixed — see the
# note above tree_bound_secs for why a flat one produced a false KILL.
# A TIMEOUT IS NOT AN ASSERTION FAILURE, AND EVERY BOUND IN THIS FILE NOW SAYS SO.
#
# Each `p_timeout` below used to call `fail` on expiry. Under tests/falsify/run.sh
# a FAIL: line IS A KILL, so an overrun credited this oracle with catching a
# mutation it never noticed — the one error the tier cannot detect from its own
# output, and the hazard the calibration note further down already described.
# The answer there was a BIGGER CONSTANT. Measured twice on macOS, that is the
# wrong instrument rather than the wrong number:
#
#   2026-08-30  whole-tree bound, flat 30s   -> control red at 35.6s, corpus unscored
#   2026-08-31  whole-tree floor raised 120s -> HELD; a flat 10s single-file bound
#                                               went red instead at 49.6s
#
# Two different constants, one mechanism. Raising the 10s would schedule the
# third. And this file's own note records two pristine controls of ITSELF, same
# run at jobs=8, taking 8s and 132s — a 16x spread no constant spans.
#
# SCAFFOLD-FAILED: is the channel that already exists for exactly this: an oracle
# that could not RUN, as opposed to one that ran and noticed something.
# falsify_verdict scores it UNPROVEN rather than KILLED (run.sh:504, and
# run-all.sh:55 states the intent outright), and run-all.sh:268 classifies it.
# So slowness now costs a verdict, which is honest, instead of manufacturing one.
# The bounds are KEPT — a hang is still infinite and still trips them — and the
# generous whole-tree floor is kept too, because a bound that fires rarely
# produces fewer unproven mutants than one that fires often.
vector() {
  printf '%s\n' "$2" > "$TMP/v.sh"
  # Timed, because the whole-tree bound below is DERIVED from this number
  # rather than being a constant — see the calibration note there. The WORST
  # of the vectors is kept, not the last: load on this tier's own host arrives
  # in bursts (two pristine controls of this very file, same run, jobs=8:
  # 8s and 132s), and a bound calibrated off a quiet moment is the constant
  # again with extra steps.
  local _t0="${EPOCHREALTIME//[.,]/}"
  p_timeout 10 bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1
  local rc=$?
  local _ms=$(( ( ${EPOCHREALTIME//[.,]/} - _t0 ) / 1000 ))
  (( _ms > unit_ms )) && unit_ms="$_ms"
  if [[ "$rc" -eq 124 ]]; then
    printf 'SCAFFOLD-FAILED: %s — the linter did not terminate within 10s; its scan loop never reached EOF\n' "$1"
    # …and stop the file here. Every vector below runs the same loop, so
    # seventeen more ten-second bounds would restate one fact seventeen times
    # and push the run past run.sh's per-mutant clock — trading this UNPROVEN
    # for a timeout, which says the same thing less precisely.
    exit 1
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
  printf 'SCAFFOLD-FAILED: the linter reads the floor — the run did not terminate within 10s\n'
  exit 1
elif [[ "$floor_rc" -eq 0 ]]; then
  fail "the linter reads the floor — a 5.0 construct passed at a 4.4 floor"
else
  pass "the linter reads the floor rather than hardcoding it"
fi

# Run against the real tree: it must be clean today. No file-level
# exclusion exists any more (see bash-dialect-lint.sh's own header) — this
# file and bash-dialect-lint.sh itself are both scanned for real, kept
# clean purely by the markers and the DOLLAR trick above.
# THE BOUND IS CALIBRATED, NOT CONSTANT, AND THAT IS A CORRECTNESS FIX rather
# than a tuning one. A `p_timeout` whose expiry calls `fail` converts SLOWNESS
# into a FAIL: line, and under tests/falsify/run.sh a FAIL: line is a KILL — so
# an overrun here credits this oracle with catching a mutation it never noticed,
# which is the one error this tier cannot detect from its own output. It was not
# hypothetical: on macOS + Colima at --jobs 8 (2026-08-22) the PRISTINE file
# blew the flat 30s bound and went red, the second control of the same run
# having passed in 8s. Only the control mechanism made it visible.
#
# THE RATIO IS NOT PLATFORM-STABLE, and this comment used to claim it was.
# Measured on the reference machine: single-file ~6ms, whole tree (141 scripts,
# one startup shared) ~580ms — 97x. Measured on macOS 2026-08-31: the run's own
# worst single-file sample was 45ms and the idle tree run 10.2s — 227x. The
# multiplier of 300 is ~3x the reference ratio and only ~1.3x the macOS one, so
# on this platform it derives a bound BELOW the honest cost and the floor is
# what actually binds. Keeping the multiplier (it still scales a genuinely slow
# machine) and raising the floor is therefore the fix; re-tuning the multiplier
# to some other constant would just move the same platform assumption.
#
# THE FLOOR IS 120s BECAUSE FORK CONTENTION, NOT CPU, IS WHAT INFLATES THIS RUN,
# and macOS is slow at forking — the same property recorded beside
# fr_fork_cost_cap. Measured 2026-08-31 on one host:
#
#   idle                                   10.2s
#   8 CPU-bound busy loops                 12.1s   (1.2x — load alone is not it)
#   8 fork-heavy loops                     >300s   (did not finish in 5 minutes)
#   the real falsify tier, ONE worker      >30s    (blew the old floor; the
#                                                   control oracle took 35.6s)
#
# No constant survives the third row, and none needs to: the bound exists ONLY
# to tell "terminated" from "hung", and past it run.sh's own per-mutant clock
# takes over and scores the mutant UNPROVEN — the outcome the paragraph above
# says to prefer over a false KILL. 120s is 4x the observed real-tier cost and
# 12x idle, which buys back the headroom the 30s floor had already lost. Deliberately NOT capped against run.sh's per-mutant
# ceiling: on a host loaded past the point where the bound would exceed it, the
# honest outcome is the oracle hitting that ceiling and the mutant scoring
# UNPROVEN, and a cap would trade that for the false KILL this whole note is
# about. A hang is infinite and trips any bound, so F22's kill survives
# everywhere the machine is fast enough to measure at all.
tree_bound_secs() {   # <worst single-file lint, ms> → the whole-tree bound
  local unit="$1" secs
  secs=$(( unit * 3 / 10 ))
  (( secs < 120 )) && secs=120
  printf '%s' "$secs"
}
tree_secs="$(tree_bound_secs "$unit_ms")"
p_timeout "$tree_secs" bash "$LINT" >/dev/null 2>&1
clean_rc=$?
if [[ "$clean_rc" -eq 124 ]]; then
  printf 'SCAFFOLD-FAILED: the whole-tree run did not terminate within %ss (calibrated from a worst single-file lint of %sms)\n' "$tree_secs" "$unit_ms"
  exit 1
elif [[ "$clean_rc" -eq 0 ]]; then
  pass "the repository is clean at the current floor"
else
  fail "the repository is clean at the current floor"
fi

# The derivation itself, asserted on fixed inputs — the run above cannot show
# it, because on any healthy machine it lands on the floor and looks exactly
# like the constant it replaced. These are the three points that tell them
# apart.
check_bound() {   # <label> <unit-ms> <expected seconds>
  local got; got="$(tree_bound_secs "$2")"
  if [[ "$got" == "$3" ]]; then pass "$1"; else fail "$1 — expected ${3}s, got ${got}s"; fi
}
check_bound "the whole-tree bound never drops below its 120s floor"       6    120
# The middle case has to sit ABOVE the floor to test anything: at the old 30s
# floor a 300ms sample derived 90s, but under 120s it would be floored and this
# assertion would silently stop distinguishing the derivation from the constant
# — which is exactly what these three points exist to tell apart.
check_bound "a slower machine gets a derived bound, not the floor"        600  180
check_bound "the bound tracks the measured cost, with no ceiling above it" 1000 300

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
  # F32's TRIGGER IS STILL UNIDENTIFIED, and one fact splits the hypotheses in
  # half: was the SOURCE gone (the falsify worker tree evaporated under the
  # running oracle) or the DESTINATION gone (this process's own mktemp -d went
  # away)? Those point at completely different mechanisms and the recorded
  # occurrence cannot tell them apart. Same channel prefix so run-all.sh
  # surfaces it — it greps ^SCAFFOLD-FAILED: and prints every matching line.
  printf 'SCAFFOLD-FAILED: diag src=%s src-exists=%s src-bytes=%s | tree=%s tree-exists=%s | tmp=%s tmp-exists=%s | dest-dir-exists=%s\n' \
    "$LINT"      "$([[ -e "$LINT" ]] && printf y || printf n)" \
    "$(wc -c <"$LINT" 2>/dev/null | tr -d ' ' || printf '?')" \
    "$REPO_DIR"  "$([[ -d "$REPO_DIR" ]] && printf y || printf n)" \
    "$TMP"       "$([[ -d "$TMP" ]] && printf y || printf n)" \
    "$([[ -d "$empty_repo/tests" ]] && printf y || printf n)"
  exit 1
fi
# The floor is passed in so the copy needs no bash-floor.sh beside it (the
# linter skips its own source when both vars are already set).
p_timeout 10 env AI_CONTAINERS_BASH_FLOOR_MAJOR=5 AI_CONTAINERS_BASH_FLOOR_MINOR=1 \
  bash "$empty_repo/tests/bash-dialect-lint.sh" > "$TMP/empty.out" 2>&1
empty_rc=$?
if [[ "$empty_rc" -eq 124 ]]; then
  printf 'SCAFFOLD-FAILED: the empty-repo run did not terminate within 10s\n'
  exit 1
elif [[ "$empty_rc" -eq 0 ]]; then
  fail "a lint run that examined no files reported SUCCESS"
elif grep -q 'examined no files' "$TMP/empty.out"; then
  pass "a lint run that examined no files fails, and says why"
else
  fail "the empty run failed, but not with the 'examined no files' message (got: $(head -2 "$TMP/empty.out" | tr '\n' ' '))"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
