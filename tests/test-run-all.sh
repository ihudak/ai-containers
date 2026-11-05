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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
