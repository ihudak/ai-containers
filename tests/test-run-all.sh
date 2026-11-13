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
# exit-trap-ok: the children it forks are run-all.sh drivers, which never return into this file
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
# THE RUN MUST HAVE WORKED for its silence to mean anything: a corpus that
# failed outright also prints no `left in TMPDIR:` line, so this passed on any
# breakage. Conjoined with the tidy test's own PASS.
if has "$out" 'PASS'; then
  pass "scaffold: the tidy corpus run produced a passing test"
else
  fail "scaffold: the tidy corpus run produced a passing test — the assertion below would pass on a broken run (got: $out)"
fi
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

# ── 8. a clock per test, which only the mutation tier sets ───────────────────
# tests/falsify/run.sh runs a mutant's tests as one run-all.sh under one clock of
# --timeout times the set's size, so a mutant that hung one test paid the whole
# set's clock (feature-gaps review GAP-2). RA_TEST_CLOCK (every test) and
# RA_TEST_CLOCKS ("<name>=<seconds> ...") give each test its own: one past it is
# stopped with everything it started, a TEST-TIMEOUT: line says so — not a FAIL:
# line, since no assertion was seen failing — and so is the run, as under the
# set's clock: a later test could fail on what the stopped one left behind.
# RA_CLOCKED_FILE names the stopped test; RA_TIMES_FILE records how long each
# test took, which is how the tier sets the clocks.
rm -f "$CORPUS"/test-*.sh
export HANG_PIDF="$TMP/hang.pid"
mkt ll-hang 'echo "PASS: before the hang"; sleep 30 & echo $! > "$HANG_PIDF"; sleep 30'
mkt mm-after 'echo "PASS: ran after the hang"; exit 0'
child_dead() { local c; c="$(cat "$HANG_PIDF" 2>/dev/null)"; [[ -n "$c" ]] && ! kill -0 "$c" 2>/dev/null; }
reap_child() { local c; c="$(cat "$HANG_PIDF" 2>/dev/null)"; [[ -z "$c" ]] || kill -KILL "$c" 2>/dev/null; rm -f "$HANG_PIDF"; }
t0=$SECONDS
rm -f "$TMP/clocked"
out="$(cd "$CORPUS" && RA_TEST_CLOCK=2 RA_CLOCKED_FILE="$TMP/clocked" TMPDIR="$TMP/tmpdir" bash ./run-all.sh 2>&1)"; rc=$?
el=$(( SECONDS - t0 ))
if (( el < 20 )) && grep -qx 'TEST-TIMEOUT: test-ll-hang.sh ran past its 2s clock and was stopped' <<<"$out"; then
  pass "a test past RA_TEST_CLOCK is stopped, and a TEST-TIMEOUT: line names it and its clock (${el}s)"
else
  fail "a test past RA_TEST_CLOCK is stopped and named (${el}s) — got: $out"
fi
[[ "$(cat "$TMP/clocked" 2>/dev/null)" == 'test-ll-hang.sh 2' ]] \
  && pass "… and RA_CLOCKED_FILE names it with its clock" \
  || fail "… RA_CLOCKED_FILE (got: $(cat "$TMP/clocked" 2>/dev/null))"
! has "$out" 'ran after the hang' && has "$out" '^not run, after a test ran past its clock: test-mm-after.sh$' \
  && has "$out" '1 test\(s\), 0 passed, 1 failed' && [[ "$rc" != 0 ]] \
  && pass "… and the run stops with it: the tests after it are not run, and are named" \
  || fail "… the run went on, or did not say what it did not run (rc=$rc) — got: $out"
! grep -q '^FAIL:' <<<"$out" \
  && pass "… and no FAIL: line is printed for it: a timeout is not an assertion seen failing" \
  || fail "… a FAIL: line was printed for a timeout — got: $out"
child_dead && pass "… and what the stopped test started is stopped with it" \
  || fail "… the stopped test's child ($(cat "$HANG_PIDF" 2>/dev/null)) is still running"
reap_child
out="$(cd "$CORPUS" && RA_TEST_CLOCK=2 TMPDIR="$TMP/tmpdir" bash ./run-all.sh -v 2>&1)"
has "$out" '^PASS: before the hang' && has "$out" '^TEST-TIMEOUT: test-ll-hang.sh ran past its 2s clock' && child_dead \
  && pass "with -v too: the test's output is streamed, and it is stopped with its child" \
  || fail "with -v, a clocked test — got: $out"
reap_child
t0=$SECONDS
out="$(cd "$CORPUS" && RA_TEST_CLOCKS="test-nosuch.sh=60 test-ll-hang.sh=1" TMPDIR="$TMP/tmpdir" bash ./run-all.sh 2>&1)"
el=$(( SECONDS - t0 ))
(( el < 20 )) && has "$out" '^TEST-TIMEOUT: test-ll-hang.sh ran past its 1s clock' \
  && pass "RA_TEST_CLOCKS gives a named test its own clock (${el}s)" \
  || fail "RA_TEST_CLOCKS per test (${el}s) — got: $out"
reap_child
# A test stopped in mid-line: the TEST-TIMEOUT: line still starts a line.
rm -f "$CORPUS"/test-*.sh
mkt qq-partial 'printf "waiting... "; sleep 30'
out="$(cd "$CORPUS" && RA_TEST_CLOCK=1 TMPDIR="$TMP/tmpdir" bash ./run-all.sh -v 2>&1)"
grep -qx 'TEST-TIMEOUT: test-qq-partial.sh ran past its 1s clock and was stopped' <<<"$out" \
  && pass "a test stopped in mid-line still gets its TEST-TIMEOUT: line at a line's start" \
  || fail "TEST-TIMEOUT: after a partial line — got: $out"
# What the driver reads is its own: a test that runs it again gets none of it.
rm -f "$CORPUS"/test-*.sh
mkt nn-env 'echo "PASS: env ${RA_TEST_CLOCK:-unset} ${RA_TEST_CLOCKS:-unset} ${RA_TIMES_FILE:-unset} ${RA_CLOCKED_FILE:-unset}"'
mkt oo-quick 'echo "PASS: quick"'
rm -f "$TMP/times"
out="$(cd "$CORPUS" && RA_TEST_CLOCK=30 RA_TEST_CLOCKS="test-oo-quick.sh=30" RA_TIMES_FILE="$TMP/times" RA_CLOCKED_FILE="$TMP/clocked" TMPDIR="$TMP/tmpdir" bash ./run-all.sh -v 2>&1)"
has "$out" '^PASS: env unset unset unset unset' \
  && pass "the clock settings are not passed on to the tests" \
  || fail "the clock settings leaked into a test's environment — got: $out"
[[ "$(awk '{print $1}' "$TMP/times" 2>/dev/null | tr '\n' ' ')" == 'test-nn-env.sh test-oo-quick.sh ' ]] \
  && awk '$2 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' "$TMP/times" \
  && pass "RA_TIMES_FILE gets one '<name> <seconds>' line per test" \
  || fail "RA_TIMES_FILE (got: $(cat "$TMP/times" 2>/dev/null | tr '\n' '|'))"
! has "$out" 'TEST-TIMEOUT' && ! has "$out" 'not run' && has "$out" '2 test\(s\), 2 passed, 0 failed' \
  && pass "tests inside their clocks are reported as they always were" \
  || fail "a clock changed the report of tests inside it — got: $out"
# A clocked test leads a process group of its own, which the mutation tier's
# watchdog does not reach when it ends the driver's: the driver ends it itself,
# on TERM (143) and INT (130) alike.
rm -f "$CORPUS"/test-*.sh
mkt ll-hang 'echo "PASS: before the hang"; sleep 30 & echo $! > "$HANG_PIDF"; sleep 30'
for sig in TERM:143 INT:130; do
  rm -f "$HANG_PIDF"
  # In its own job, so it does not start with SIGINT ignored, as a background
  # command of a script does (env --default-signal is GNU's only).
  set -m
  ( cd "$CORPUS" && RA_TEST_CLOCK=60 TMPDIR="$TMP/tmpdir" exec bash ./run-all.sh ) >/dev/null 2>&1 &
  drv=$!
  set +m
  for _ in $(seq 1 100); do [[ -s "$HANG_PIDF" ]] && break; sleep 0.1; done
  kill -"${sig%%:*}" "$drv" 2>/dev/null; wait "$drv"; drc=$?
  sleep 0.5
  [[ -s "$HANG_PIDF" ]] && child_dead && [[ "$drc" == "${sig#*:}" ]] \
    && pass "a ${sig%%:*} to the driver stops the clocked test it is running, and what that test started (exit ${sig#*:})" \
    || fail "${sig%%:*} to the driver (rc=$drc, want ${sig#*:}; child: $(cat "$HANG_PIDF" 2>/dev/null), alive: $(kill -0 "$(cat "$HANG_PIDF" 2>/dev/null)" 2>/dev/null && echo yes || echo no))"
  reap_child
done
# On that path too, what the test prints as it dies stays out of the output, as
# under the set's clock: the tier's clock, or its cleanup, TERMs the driver, and
# a dying FAIL: line would score a kill. Twelve times, since a leak is a race:
# the wrong order (the test before tee) leaked in about one run of four in the
# third review of the GAP-2 clock, though in none of twelve when this was
# written. What pins the order is the TERM-ignoring case below.
rm -f "$CORPUS"/test-*.sh
mkt ss-dying 'trap '"'"'echo "FAIL: printed while dying"'"'"' EXIT; echo "PASS: started"; sleep 30'
leak=0; started=0
for _ in $(seq 1 12); do
  set -m
  ( cd "$CORPUS" && RA_TEST_CLOCK=60 TMPDIR="$TMP/tmpdir" exec bash ./run-all.sh -v ) > "$TMP/dying.out" 2>&1 &
  drv=$!
  set +m
  for _ in $(seq 1 100); do grep -q '^PASS: started' "$TMP/dying.out" 2>/dev/null && break; sleep 0.1; done
  grep -q '^PASS: started' "$TMP/dying.out" && started=$((started + 1))
  kill -TERM "$drv" 2>/dev/null; wait "$drv" 2>/dev/null
  grep -q 'printed while dying' "$TMP/dying.out" && leak=$((leak + 1))
done
(( started == 12 && leak == 0 )) \
  && pass "a TERM to the driver keeps what its clocked test prints while dying out of the output (12 of 12)" \
  || fail "a TERM to the driver let a dying test's output through ($leak of 12; started in $started)"
rm -f "$TMP/dying.out"
# A test that ignores TERM is KILLed half a second later; and if the driver is
# KILLed in that half second, the test's clock, stopped last, still ends it.
export HANG_PIDF="$TMP/hang.pid"
rm -f "$CORPUS"/test-*.sh
mkt tt-deaf 'trap "" TERM; sleep 30 & echo $! > "$HANG_PIDF"; wait'
for how in term term+kill; do
  rm -f "$HANG_PIDF"
  set -m
  ( cd "$CORPUS" && RA_TEST_CLOCK=60 TMPDIR="$TMP/tmpdir" exec bash ./run-all.sh ) >/dev/null 2>&1 &
  drv=$!
  set +m
  for _ in $(seq 1 100); do [[ -s "$HANG_PIDF" ]] && break; sleep 0.1; done
  kill -TERM "$drv" 2>/dev/null
  if [[ "$how" == term+kill ]]; then sleep 0.2; kill -KILL "$drv" 2>/dev/null; fi
  wait "$drv" 2>/dev/null
  for _ in $(seq 1 40); do child_dead && break; sleep 0.1; done
  [[ -s "$HANG_PIDF" ]] && child_dead \
    && pass "a test that ignores TERM is stopped all the same ($how to the driver)" \
    || fail "a test that ignores TERM outlived the driver ($how; child: $(cat "$HANG_PIDF" 2>/dev/null))"
  reap_child
done
# And when the driver is KILLed (the OOM killer), nothing of the test may run on
# into the next oracle in that tree: its clock ends it within a second or two.
rm -f "$HANG_PIDF"
( cd "$CORPUS" && RA_TEST_CLOCK=60 TMPDIR="$TMP/tmpdir" exec bash ./run-all.sh ) >/dev/null 2>&1 &
drv=$!
for _ in $(seq 1 100); do [[ -s "$HANG_PIDF" ]] && break; sleep 0.1; done
kill -KILL "$drv" 2>/dev/null; wait "$drv" 2>/dev/null
for _ in $(seq 1 50); do child_dead && break; sleep 0.1; done
[[ -s "$HANG_PIDF" ]] && child_dead \
  && pass "a KILLed driver's clocked test is stopped too, by its clock, within seconds" \
  || fail "a KILLed driver left its clocked test running (child: $(cat "$HANG_PIDF" 2>/dev/null))"
reap_child
unset HANG_PIDF
# A test that kills its driver and then exits leaves no child behind either.
rm -f "$CORPUS"/test-*.sh
export HANG_PIDF="$TMP/hang.pid"; rm -f "$HANG_PIDF"
mkt rr-orphan 'sleep 30 & echo $! > "$HANG_PIDF"; kill -KILL "$PPID"; exit 0'
( cd "$CORPUS" && RA_TEST_CLOCK=60 TMPDIR="$TMP/tmpdir" exec bash ./run-all.sh ) >/dev/null 2>&1
for _ in $(seq 1 50); do child_dead && break; sleep 0.1; done
[[ -s "$HANG_PIDF" ]] && child_dead \
  && pass "a test that kills its driver and exits does not leave its children running" \
  || fail "a test that killed its driver left a child running ($(cat "$HANG_PIDF" 2>/dev/null))"
reap_child
unset HANG_PIDF
# What a test prints while its clock stops it is not part of the run's output.
rm -f "$CORPUS"/test-*.sh
mkt ss-dying 'trap '"'"'echo "FAIL: printed while dying"'"'"' EXIT; echo "PASS: started"; sleep 30'
out="$(cd "$CORPUS" && RA_TEST_CLOCK=1 TMPDIR="$TMP/tmpdir" bash ./run-all.sh -v 2>&1)"
has "$out" '^PASS: started' && has "$out" '^TEST-TIMEOUT: test-ss-dying.sh' && ! has "$out" '^FAIL: printed while dying' \
  && pass "what a test prints while its clock stops it does not reach the output, as under the set's clock" \
  || fail "a dying test's output reached the run — got: $out"
# And still this driver's own child: the tier's signal fixture kills its $PPID,
# standing in for the OOM killer taking the driver, which must then die.
rm -f "$CORPUS"/test-*.sh
mkt pp-parent 'kill -KILL "$PPID"; echo "PASS: the driver outlived me"; exit 0'
bad_pp=""
for v in "" -v; do
  ( cd "$CORPUS" && RA_TEST_CLOCK=30 TMPDIR="$TMP/tmpdir" exec bash ./run-all.sh $v ) >/dev/null 2>&1; prc=$?
  [[ "$prc" == 137 ]] || bad_pp+="${v:-plain}=$prc "
done
[[ -z "$bad_pp" ]] \
  && pass "a clocked test is the driver's own child, with and without -v: killing its parent kills the driver" \
  || fail "a clocked test's parent is not the driver (exit statuses: $bad_pp)"

# ── 9. a test that could not set itself up says why ──────────────────────────
# Its SCAFFOLD-FAILED: line usually points at "the error above", and only that
# line was shown: on 2026-11-05 test-falsify-historical.sh's seed failed in a
# floor container, and the cause (git would not trust a copy of a .git another
# uid owned) was seen only once these lines were. The lines just above it are
# shown too, an assertion line excepted: the tier reads an indented FAIL: as one.
rm -f "$CORPUS"/test-*.sh
mkt ss-seed 'echo "PASS: before the seed"; echo "cp: cannot stat '"'"'x'"'"': No such file or directory" >&2
echo "FAIL: an assertion, not a setup error"; echo "ERROR: /r has no tracked files — nothing to seed" >&2
echo "SCAFFOLD-FAILED: no tree could be seeded (see the error above)"; exit 1'
out="$(run_corpus)"
has "$out" '^ +cp: cannot stat .x.: No such file' && has "$out" '^ +ERROR: /r has no tracked files' \
  && has "$out" '^ +SCAFFOLD-FAILED: no tree could be seeded' \
  && pass "a test that could not set itself up is shown with the lines above its SCAFFOLD-FAILED: line" \
  || fail "a test that could not set itself up is shown with the lines above its SCAFFOLD-FAILED: line — got: $out"
! has "$out" 'PASS: before the seed|FAIL: an assertion' \
  && pass "  … but not its PASS: or FAIL: lines" \
  || fail "  … but not its PASS: or FAIL: lines — got: $out"

# ── 10. each test starts in the runner's directory looked up afresh ─────────
# From a WSL checkout under /mnt/c, the directory every test inherited from the
# runner went stale partway through a two-hour run, while the path itself
# stayed good: git "Unable to read current working directory", rsync's
# getcwd() and a new bash's shell-init all failed with ENOENT, 16 test files at
# once (the drvfs flake, docs/testing.md; GAP-10). Deleting the starting
# directory and making it again at the same path is the same state on any
# filesystem: the inherited directory is gone, a fresh cd by path works.
rm -f "$CORPUS"/test-*.sh
START="$TMP/start"; mkdir -p "$START"
mkt aa-stale 'rm -rf "$RA10_START" && mkdir "$RA10_START" && echo "PASS: the start directory was made again"'
mkt bb-cwd 'if p="$(/bin/pwd 2>&1)" && [[ "$p" == "$RA10_PHYS" ]] && [[ "$(bash -c "echo ok" 2>&1)" == ok ]]; then echo "PASS: cwd resolves"; else echo "FAIL: cwd does not resolve: $p"; exit 1; fi'
out="$(cd "$START" && RA10_START="$START" RA10_PHYS="$(cd "$START" && pwd -P)" TMPDIR="$TMP/tmpdir" bash "$CORPUS/run-all.sh" 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && has "$out" '2 test\(s\), 2 passed, 0 failed' \
  && pass "a test starts in the runner's directory looked up again, not one gone stale under it" \
  || fail "a test starts in the runner's directory looked up again (rc=$rc) — got: $out"

# ── 11. the run stops at the first test that printed a FAIL: line ─────────────
# Only the mutation tier sets RA_STOP_AT_FAIL (tests/falsify/run.sh
# --stop-at-kill, feature-gaps review GAP-2). One FAIL: line makes a mutant
# KILLED, and the tests after it could add nothing to that verdict but their
# run time: the whole-file measurement of sandbox.sh paid 30 minutes a mutant
# for them. The line is the tier's own (`falsify_has_fail_line`): FAIL: at a
# line's start or after whitespace.
rm -f "$CORPUS"/test-*.sh
export RA11_W="$TMP/ra11"; mkdir -p "$RA11_W"
ra11() {  # <env's arguments> -- <run-all.sh's arguments> → $out, $rc
  local -a e=()
  while [[ "${1-}" != -- ]]; do e+=("$1"); shift; done; shift
  rm -f "$RA11_W"/*
  out="$(cd "$CORPUS" && env "${e[@]}" TMPDIR="$TMP/tmpdir" bash ./run-all.sh "$@" 2>&1)"; rc=$?
}
mkt aa-pass 'echo "PASS: first"'
mkt bb-fail 'echo "PASS: something held"; echo "FAIL: an assertion"; exit 1'
mkt cc-after ': > "$RA11_W/cc-ran"; echo "PASS: the third ran"'
for v in -v ""; do
  ra11 RA_STOP_AT_FAIL=1 -- $v
  [[ ! -e "$RA11_W/cc-ran" ]] && has "$out" '^not run, after a test failed: test-cc-after.sh$' \
    && has "$out" '2 test\(s\), 1 passed, 1 failed' && has "$out" '^Failing: test-bb-fail.sh$' && [[ "$rc" == 1 ]] \
    && pass "RA_STOP_AT_FAIL${v:+ with -v}: the run stops after the first test that printed a FAIL: line, and names what it did not run" \
    || fail "RA_STOP_AT_FAIL${v:+ with -v}: the run did not stop, or did not say so (rc=$rc) — got: $out"
done
ra11 -u RA_STOP_AT_FAIL -- -v
[[ -e "$RA11_W/cc-ran" ]] && ! has "$out" 'not run' && has "$out" '3 test\(s\), 2 passed, 1 failed' \
  && pass "… and without it every test runs, as always" \
  || fail "… without RA_STOP_AT_FAIL a test was not run — got: $out"
ra11 RA_STOP_AT_FAIL=0 -- -v
[[ -e "$RA11_W/cc-ran" ]] && pass "… and RA_STOP_AT_FAIL=0 is off" || fail "… RA_STOP_AT_FAIL=0 stopped the run — got: $out"
# A test that fails with no FAIL: line showed no assertion failing: the tier
# counts such a kill apart (ASSERTLESS), and the rest of the set may hold the
# assertion.
mkt bb-fail 'echo "PASS: something held"; exit 1'
ra11 RA_STOP_AT_FAIL=1 -- -v
[[ -e "$RA11_W/cc-ran" ]] && ! has "$out" 'not run' \
  && pass "a test that exits non-zero with no FAIL: line does not stop the run" \
  || fail "a failure with no FAIL: line stopped the run — got: $out"
# Exit 0 and a FAIL: line: the runner's own rule already counts it failed.
mkt bb-fail 'echo "FAIL: an assertion, and the exit status forgotten"; exit 0'
ra11 RA_STOP_AT_FAIL=1 -- -v
[[ ! -e "$RA11_W/cc-ran" ]] && has "$out" '^not run, after a test failed: test-cc-after.sh$' && [[ "$rc" == 1 ]] \
  && pass "a test that printed FAIL: and exited 0 stops the run too" \
  || fail "FAIL: with exit 0 did not stop the run (rc=$rc) — got: $out"
# FAIL: after whitespace is the tier's kill and not the runner's failure: the
# runner reports this test PASS. Stopped there, the run must still not exit 0
# with tests it never ran.
mkt bb-fail 'echo "PASS: something held"; echo "  FAIL: an assertion, indented"; exit 0'
ra11 RA_STOP_AT_FAIL=1 -- -v
[[ ! -e "$RA11_W/cc-ran" ]] && has "$out" '^not run, after a test failed: test-cc-after.sh$' && [[ "$rc" == 1 ]] \
  && pass "a FAIL: line after whitespace stops the run, which then exits 1 though the runner counted the test passed" \
  || fail "an indented FAIL: line (rc=$rc) — got: $out"
ra11 -u RA_STOP_AT_FAIL -- -v
[[ -e "$RA11_W/cc-ran" && "$rc" == 0 ]] \
  && pass "… and without RA_STOP_AT_FAIL that run is green, as it was" \
  || fail "… the indented FAIL: line changed a run without RA_STOP_AT_FAIL (rc=$rc) — got: $out"
# A setup that broke is in the output either way, and the tier reads UNPROVEN
# from it wherever the run ends.
mkt bb-fail 'echo "SCAFFOLD-FAILED: no workspace"; echo "FAIL: an assertion on the wreckage"; exit 1'
ra11 RA_STOP_AT_FAIL=1 -- -v
[[ ! -e "$RA11_W/cc-ran" ]] && has "$out" 'SCAFFOLD-FAILED: no workspace' \
  && pass "a test with a FAIL: line and a SCAFFOLD-FAILED: line stops the run, its marker printed" \
  || fail "FAIL: beside SCAFFOLD-FAILED: — got: $out"
# Under a clock, which is how the tier runs it: a test inside its clock that
# printed FAIL: stops the run the same way.
mkt bb-fail 'echo "PASS: something held"; echo "FAIL: an assertion"; exit 1'
ra11 RA_STOP_AT_FAIL=1 RA_TEST_CLOCK=30 -- -v
[[ ! -e "$RA11_W/cc-ran" ]] && has "$out" '^FAIL: an assertion$' && has "$out" '^not run, after a test failed: test-cc-after.sh$' \
  && ! has "$out" 'TEST-TIMEOUT' && [[ "$rc" == 1 ]] \
  && pass "under a clock, with -v: a test that printed FAIL: stops the run" \
  || fail "under a clock a FAIL: line did not stop the run (rc=$rc) — got: $out"
# The clock wins: a test that printed FAIL: and then ran past its clock is a
# timeout, reported as one, with the clock's own line for what was not run.
mkt bb-fail 'echo "FAIL: an assertion, then a hang"; sleep 30'
rm -f "$TMP/clocked"
ra11 RA_STOP_AT_FAIL=1 RA_TEST_CLOCK=2 RA_CLOCKED_FILE="$TMP/clocked" -- -v
[[ ! -e "$RA11_W/cc-ran" ]] && has "$out" '^TEST-TIMEOUT: test-bb-fail.sh ran past its 2s clock' \
  && has "$out" '^not run, after a test ran past its clock: test-cc-after.sh$' && ! has "$out" 'not run, after a test failed' \
  && [[ "$(cat "$TMP/clocked" 2>/dev/null)" == 'test-bb-fail.sh 2' ]] \
  && pass "a test that printed FAIL: and then ran past its clock is reported as the timeout it is" \
  || fail "FAIL: then a hang: the clock's report was lost — got: $out"
# The decision reads the test's log, which under a clock with -v comes through
# tee. Where tee could not finish (something the test started still holds its
# output open), the log may not be whole, and the run goes on.
export HANG_PIDF="$TMP/hang.pid"; rm -f "$HANG_PIDF"
mkt bb-fail 'echo "FAIL: an assertion"; set -m; sleep 20 & echo $! > "$HANG_PIDF"; exit 1'
ra11 RA_STOP_AT_FAIL=1 RA_TEST_CLOCK=30 -- -v
[[ -s "$HANG_PIDF" && -e "$RA11_W/cc-ran" ]] && ! has "$out" 'not run' \
  && pass "where the test's output could not be read to its end, the run does not stop on it" \
  || fail "the run stopped on a log that was cut off — got: $out"
reap_child
unset HANG_PIDF
# What the driver reads is its own.
rm -f "$CORPUS"/test-*.sh
mkt nn-env 'echo "PASS: env ${RA_STOP_AT_FAIL:-unset}"'
ra11 RA_STOP_AT_FAIL=1 -- -v
has "$out" '^PASS: env unset$' \
  && pass "RA_STOP_AT_FAIL is not passed on to the tests" \
  || fail "RA_STOP_AT_FAIL leaked into a test's environment — got: $out"

# ── 12. the order of the run, which only the mutation tier sets ──────────────
# RA_ORDER="<name> <name> ..." (tests/falsify/run.sh --stop-at-kill): the tests
# it names run first, in its order, and the others after them in the usual
# order. The tier puts a target's quickest tests first, so the run reaches the
# test that fails, and stops, before it has paid for the slow ones.
rm -f "$CORPUS"/test-*.sh
export RA12_W="$TMP/ra12.order"
for n in aa bb cc dd; do mkt "$n" "echo $n >> \"\$RA12_W\"; echo \"PASS: $n\""; done
ra12() {  # <env's arguments> -- <run-all.sh's arguments> → $out, $rc, $ran
  local -a e=()
  while [[ "${1-}" != -- ]]; do e+=("$1"); shift; done; shift
  : > "$RA12_W"
  out="$(cd "$CORPUS" && env "${e[@]}" TMPDIR="$TMP/tmpdir" bash ./run-all.sh "$@" 2>&1)"; rc=$?
  ran="$(tr '\n' ' ' < "$RA12_W")"
}
ra12 -u RA_ORDER --
check_ran() { [[ "$ran" == "$2" ]] && pass "$1" || fail "$1 — ran: '$ran', expected '$2' — got: $out"; }
check_ran "without RA_ORDER the tests run in the usual order" "aa bb cc dd "
ra12 RA_ORDER="test-cc.sh test-aa.sh" --
check_ran "RA_ORDER: the tests it names run first, in its order, and the rest after them in the usual order" "cc aa bb dd "
has "$out" '4 test\(s\), 4 passed, 0 failed' && [[ "$rc" == 0 ]] \
  && pass "… and every test still runs once, and the run is green" \
  || fail "… RA_ORDER changed what ran or the result (rc=$rc) — got: $out"
ra12 RA_ORDER="test-dd.sh test-nosuch.sh test-dd.sh test-bb.sh" --
check_ran "… a name that is no test is passed over, and a name given twice runs once" "dd bb aa cc "
ra12 RA_ORDER="test-dd.sh test-bb.sh test-aa.sh" -- aa dd
check_ran "… only the selected tests run, in RA_ORDER's order among themselves" "dd aa "
# With RA_STOP_AT_FAIL: what is not run is what came after the failing test in
# this order, and is named in this order.
mkt bb 'echo bb >> "$RA12_W"; echo "FAIL: bb"; exit 1'
ra12 RA_ORDER="test-dd.sh test-bb.sh" RA_STOP_AT_FAIL=1 -- -v
check_ran "with RA_STOP_AT_FAIL the run stops after the failing test in RA_ORDER's order" "dd bb "
has "$out" '^not run, after a test failed: test-aa.sh test-cc.sh$' \
  && pass "… and names what it did not run" \
  || fail "… the tests not run are not named as expected — got: $out"
rm -f "$CORPUS"/test-*.sh
mkt nn-env 'echo "PASS: env ${RA_ORDER:-unset}"'
ra12 RA_ORDER="test-nn-env.sh" -- -v
has "$out" '^PASS: env unset$' \
  && pass "RA_ORDER is not passed on to the tests" \
  || fail "RA_ORDER leaked into a test's environment — got: $out"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
