#!/usr/bin/env bash
# tests/test-run-all.sh — the runner's VERDICT logic, asserted at last.
#
# Backlog F65. `run-all.sh` decides what every other test in this suite is
# reported as, and almost nothing asserted it. It cannot be covered by the
# mutation tier either: `tests/falsify/targets.conf` excludes it deliberately,
# as the instrument the tier measures with. So the one file whose verdicts every
# other result depends on sat outside both of this repo's coverage mechanisms.
#
# That matters because of how a regression there PRESENTS. It does not look like
# "run-all.sh is broken" — it looks like every other test's verdict being wrong,
# or like a green run that measured nothing. Both are the exact shape this repo
# built the falsify tier to end.
#
# ── METHOD: the REAL runner, over planted tests ───────────────────────────────
# `run-all.sh` resolves its corpus from its own location (`BASH_SOURCE[0]`) and
# sources nothing, so copying it into a scratch `tests/` dir beside a synthetic
# corpus runs the real script against tests this file controls. Not a
# reimplementation of its logic — a copy of the shipped file, so a change to it
# is a change to what is asserted here.
#
# It also cannot recurse: this file is itself collected by `run-all.sh`'s
# `test-*.sh` glob, so it must never invoke the runner in the real tests
# directory, and it does not.
#
# Each planted test below is a VERDICT VECTOR — one shape whose reporting is a
# rule the suite depends on. The vectors that matter most are the ones where the
# exit status and the truth disagree: a test that prints FAIL: and exits 0, and
# a test that exits 0 having asserted nothing. Both are "green" to any check
# that reads only the exit status, and both must be reported FAIL.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ALL="$TESTS_DIR/run-all.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$RUN_ALL" ]] || { printf 'SCAFFOLD-FAILED: no run-all.sh at %s\n' "$RUN_ALL"; exit 1; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

CORPUS="$TMP/tests"
mkdir -p "$CORPUS" || { printf 'SCAFFOLD-FAILED: mkdir corpus\n'; exit 1; }
cp "$RUN_ALL" "$CORPUS/run-all.sh" || { printf 'SCAFFOLD-FAILED: copy run-all.sh\n'; exit 1; }
chmod +x "$CORPUS/run-all.sh"

mkt() {  # <name> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$CORPUS/test-$1.sh"
  chmod +x "$CORPUS/test-$1.sh"
}

# Run the copied runner over whatever is planted, with a TMPDIR of its own so a
# leak vector cannot reach the developer's real temp directory.
# No arguments: every vector below is expressed by WHAT IS PLANTED, not by a
# filter flag, so the runner always sees a whole corpus and selects nothing.
# Passing `"$@"` here would be an unused parameter the linter is right to flag.
run_corpus() {  # → combined output, plus an RC= marker line
  local out rc
  out="$(cd "$CORPUS" && TMPDIR="$TMP/tmpdir" bash ./run-all.sh 2>&1)"; rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}
mkdir -p "$TMP/tmpdir"
has() { grep -qE "$2" <<<"$1"; }
rc_of() { printf '%s' "$1" | sed -n 's/^RC=//p' | tail -1; }

# ── the corpus is real, and the harness itself must be checked first ──────────
# Every assertion below reads this runner's output. If the copy could not run at
# all, they would fail as a block for a reason having nothing to do with verdict
# logic, so the scaffold is proved before anything is judged by it.
mkt zz-plain 'echo "PASS: trivially true"; exit 0'
out="$(run_corpus)"
if [[ "$(rc_of "$out")" == "0" ]] && has "$out" '1 test\(s\), 1 passed, 0 failed'; then
  pass "the copied runner runs a one-test corpus and reports it"
else
  printf 'SCAFFOLD-FAILED: the copied runner did not report a trivial corpus\n%s\n' "$out"
  exit 1
fi

# ── 1. a passing test, and its assertion COUNT ────────────────────────────────
# The count is what makes a pass informative rather than a rubber stamp: a file
# reporting "PASS (0 assertion(s))" would be caught by the assertless rule
# below, and one whose count silently stopped tracking would hide a test that
# stopped asserting most of what it used to.
rm -f "$CORPUS"/test-*.sh
mkt aa-pass 'echo "PASS: one"; echo "PASS: two"; echo "PASS: three"; exit 0'
out="$(run_corpus)"
has "$out" 'PASS  \(3 assertion\(s\)\)' \
  && pass "a passing test is reported PASS with its assertion count" \
  || fail "a passing test is reported PASS with its assertion count — got: $out"
[[ "$(rc_of "$out")" == "0" ]] \
  && pass "an all-green corpus exits 0" \
  || fail "an all-green corpus exits 0 (rc=$(rc_of "$out"))"

# ── 2. a test that FAILS loudly ──────────────────────────────────────────────
rm -f "$CORPUS"/test-*.sh
mkt bb-loud 'echo "PASS: got this far"; echo "FAIL: the thing"; exit 1'
out="$(run_corpus)"
has "$out" 'FAIL  \(exit 1\)' \
  && pass "a test exiting non-zero is reported FAIL with its exit status" \
  || fail "a test exiting non-zero is reported FAIL with its exit status — got: $out"
[[ "$(rc_of "$out")" != "0" ]] \
  && pass "a corpus containing a failure exits non-zero" \
  || fail "a corpus containing a failure exits non-zero — it exited 0"

# ── 3. THE ONE THAT MATTERS MOST: FAIL: printed, exit status 0 ───────────────
# A test whose assertions failed but whose script ended cleanly. Anything
# reading only the exit status calls this green. The historical scorecard
# (tests/test-falsify-historical.sh, hole #2) names this shape as the one
# `run-all.sh`'s `^FAIL:` guard exists to catch, and treats it as OUT of the
# mutation tier's remit for exactly that reason — so this guard is the only
# thing standing between that shape and a false green, and until now nothing
# asserted it.
rm -f "$CORPUS"/test-*.sh
mkt cc-silent 'echo "PASS: something"; echo "FAIL: but this broke"; exit 0'
out="$(run_corpus)"
has "$out" 'FAIL  \(exited 0 but printed 1 FAIL: line\(s\)\)' \
  && pass "a test printing FAIL: while exiting 0 is reported FAIL, not PASS" \
  || fail "a test printing FAIL: while exiting 0 is reported FAIL — got: $out"
[[ "$(rc_of "$out")" != "0" ]] \
  && pass "… and it makes the whole corpus exit non-zero" \
  || fail "… and it makes the whole corpus exit non-zero — it exited 0"

# ── 4. exit 0 having asserted NOTHING ────────────────────────────────────────
# A bad guard, an early return, a renamed helper: the test runs, says nothing,
# and ends cleanly. Reporting it PASS is how a check that verifies nothing
# survives, which is the defect class this whole repo is organised against.
rm -f "$CORPUS"/test-*.sh
mkt dd-mute 'exit 0'
out="$(run_corpus)"
has "$out" 'FAIL  \(exited 0 but asserted nothing\)' \
  && pass "a test asserting nothing is reported FAIL, not PASS" \
  || fail "a test asserting nothing is reported FAIL — got: $out"

# ── 5. SKIP, and PASS's precedence over it ───────────────────────────────────
# A file may skip PART of itself and still assert real things; that file is a
# pass, not a skip. Getting the precedence backwards would mask a file's real
# assertions behind a single SKIP: line — and skips are exempt from the
# assertless rule above, so the mistake also opens a hole in rule 4.
rm -f "$CORPUS"/test-*.sh
mkt ee-skip 'echo "SKIP: no fixture here"; exit 0'
out="$(run_corpus)"
has "$out" 'SKIP  \(no fixture here\)' \
  && pass "a test that only skips is reported SKIP, with its reason" \
  || fail "a test that only skips is reported SKIP with its reason — got: $out"
[[ "$(rc_of "$out")" == "0" ]] \
  && pass "a skip is not a failure" \
  || fail "a skip is not a failure (rc=$(rc_of "$out"))"

rm -f "$CORPUS"/test-*.sh
mkt ff-both 'echo "SKIP: one arm needs a mac"; echo "PASS: the other arm ran"; exit 0'
out="$(run_corpus)"
has "$out" 'PASS  \(1 assertion\(s\)\)' \
  && pass "a file that both skips and asserts is reported PASS, not SKIP" \
  || fail "a file that both skips and asserts is reported PASS, not SKIP — got: $out"

# ── 6. the leaked-temp counter ───────────────────────────────────────────────
# Added in v0.9.2 after four tests were found leaking a directory on every
# PASSING run — invisible precisely because they passed. A counter that stopped
# firing would restore that invisibility, and it names the leaker because
# "something leaked" is not actionable.
rm -f "$CORPUS"/test-*.sh
mkt gg-leaky 'mkdir -p "${TMPDIR:-/tmp}/left-behind.$$"; echo "PASS: leaked on purpose"; exit 0'
out="$(run_corpus)"
has "$out" 'left in TMPDIR: .*gg-leaky' \
  && pass "a test leaking into TMPDIR is reported, and named" \
  || fail "a test leaking into TMPDIR is reported and named — got: $out"

rm -f "$CORPUS"/test-*.sh
mkt hh-tidy 'd="$(mktemp -d)"; rm -rf "$d"; echo "PASS: cleaned up"; exit 0'
out="$(run_corpus)"
has "$out" 'left in TMPDIR:' \
  && fail "a tidy test must not be reported as leaking — got: $out" \
  || pass "a tidy test is not reported as leaking"

# ── 7. the tally ─────────────────────────────────────────────────────────────
# The summary line is what a human and a CI log both read. It has to agree with
# the per-test verdicts above rather than being counted independently.
rm -f "$CORPUS"/test-*.sh
mkt ii-ok    'echo "PASS: fine"; exit 0'
mkt jj-bad   'echo "FAIL: broken"; exit 1'
mkt kk-quiet 'echo "SKIP: not here"; exit 0'
out="$(run_corpus)"
has "$out" '3 test\(s\), 2 passed, 1 failed' \
  && pass "the summary tallies passes and failures across a mixed corpus" \
  || fail "the summary tallies passes and failures across a mixed corpus — got: $out"
has "$out" 'Failing: test-jj-bad.sh' \
  && pass "the summary names which test failed" \
  || fail "the summary names which test failed — got: $out"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
