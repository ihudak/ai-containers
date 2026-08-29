#!/usr/bin/env bash
# tests/test-falsify-run.sh — the oracle for tests/falsify/run.sh.
#
# run.sh damages one line of a target file, runs the hermetic test that covers
# it, and reports KILLED or SURVIVED. Two things about that can go wrong in ways
# no one would notice, and both are what this file exists for:
#
#   1. IT COULD MUTATE THE WORKING TREE. That is the single most damaging thing
#      this harness could do, so the isolation is asserted from BOTH ends: the
#      repo's HEAD and `git status --porcelain` are compared byte-for-byte
#      before and after a full run, AND the fixture oracle writes a witness line
#      per invocation recording what the ORIGIN file looked like WHILE it ran.
#      The before/after pair alone would pass a runner that damaged the origin
#      and tidied up after itself; the witness is what closes that.
#
#   2. IT COULD REPORT EVERY MUTANT KILLED. A misspelled oracle name runs zero
#      tests (run-all.sh exits 2), a hung oracle looks like a failing one, and a
#      verdict function that reads a constant instead of the oracle's output
#      reads 100 % and declares the suite perfect. So both verdicts are
#      demonstrated on a fixture with one known-killable and one known-surviving
#      mutant, and then each half of the kill disjunction is BROKEN on a copy of
#      run.sh and required to flip that killable mutant to SURVIVED. An
#      assertion that cannot fail is not an assertion.
#
# FAST BY CONSTRUCTION: everything runs against a tiny fixture repo (one 4-mutant
# target, four one-purpose oracles) built in $TMP, never the real 548-mutant
# corpus. The fixture's tests/run-all.sh is a COPY of the real driver, so the
# oracle contract under test is the real one.
#
# Hermetic: no docker, no network. The real repo is only ever READ.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RUN="$TESTS_DIR/falsify/run.sh"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {   # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

if [[ ! -f "$RUN" ]]; then
  fail "tests/falsify/run.sh exists"
printf '\n%d failure(s)\n' "$fails"; exit "$fails"
fi
pass "tests/falsify/run.sh exists"
bash -n "$RUN" && pass "run.sh parses" || fail "run.sh parses"

# ── the fixture repo ──────────────────────────────────────────────────────────
# fixture-lib.sh has exactly two mutable lines, and which one the oracle
# observes is the whole point: the `if` line is asserted on (3 mutants, all
# killable), fx_never_called is never called (1 mutant, unkillable by
# construction). A tier that cannot tell those apart is measuring nothing.
FX="$TMP/repo"
mkdir -p "$FX/tests"
cat > "$FX/fixture-lib.sh" <<'EOF'
#!/usr/bin/env bash
# A fixture mutation target: one observed function, one the oracle never calls.
fx_bigger() {
  if [[ "$1" -gt "$2" ]]; then printf 'yes\n'; else printf 'no\n'; fi
}
fx_never_called() {
  return 0
}
EOF
cat > "$FX/fixture-slow.sh" <<'EOF'
#!/usr/bin/env bash
fxs_ok() { return 0; }
EOF

# The witness preamble every fixture oracle carries. It is the only vantage
# point that sees both trees at once: the ORIGIN repo (which must never change)
# and the tree this oracle is actually running in (which must carry the mutant).
FX_WITNESS_SNIPPET='
if [[ -n "${FX_WITNESS:-}" && -n "${FX_ORIGIN:-}" ]]; then
  printf "origin=%s self=%s\n" \
    "$(cksum < "$FX_ORIGIN" | tr -d " ")" \
    "$(cksum < "$FX_DIR/fixture-lib.sh" | tr -d " ")" >> "$FX_WITNESS"
fi'

# Oracle A — the shape every real hermetic test has: `FAIL:` lines at line start
# AND a non-zero exit, so both kill signals fire at once.
{
  cat <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
EOF
  printf '%s\n' "$FX_WITNESS_SNIPPET"
  cat <<'EOF'
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
if [[ "$(fx_bigger 5 3)" == "yes" ]]; then printf 'PASS: 5 beats 3\n'
else printf 'FAIL: 5 beats 3\n'; fails=$((fails + 1)); fi
if [[ "$(fx_bigger 3 5)" == "no" ]]; then printf 'PASS: 3 does not beat 5\n'
else printf 'FAIL: 3 does not beat 5\n'; fails=$((fails + 1)); fi
exit "$fails"
EOF
} > "$FX/tests/test-fx-a.sh"

# Oracle B — kills through the EXIT STATUS ONLY. Nothing it or the driver prints
# contains the string `FAIL:` (the driver's own `   FAIL  (exit 1)` has no
# colon), so breaking the FAIL:-line check cannot mask this kill and breaking
# the exit-status check must unmask it.
cat > "$FX/tests/test-fx-b.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
if [[ "$(fx_bigger 5 3)" == "yes" && "$(fx_bigger 3 5)" == "no" ]]; then
  printf 'PASS: fx_bigger orders its arguments\n'
  exit 0
fi
printf '  wrong answer from fx_bigger\n'
exit 1
EOF

# Oracle C — kills through a `FAIL:` LINE ONLY. It exits 0 always and indents
# its FAIL: lines, so run-all.sh's own gate (anchored at ^FAIL:) reports PASS and
# exits 0. That blind spot is real and documented in run-all.sh's own header;
# here it isolates the second half of the kill disjunction.
cat > "$FX/tests/test-fx-c.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
printf '  ok reached the assertions\n'
if [[ "$(fx_bigger 5 3)" == "yes" && "$(fx_bigger 3 5)" == "no" ]]; then
  printf '  ok fx_bigger orders its arguments\n'
else
  printf '  FAIL: fx_bigger orders its arguments\n'
fi
exit 0
EOF

# Oracle D — exits 0 having asserted NOTHING. Run directly it looks like a pass;
# run through the driver it is a failure, which is how this file proves by
# EFFECT that the oracle is `run-all.sh <name>` and not the test file.
cat > "$FX/tests/test-fx-silent.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Oracle E — hangs when its target is mutated. The per-mutant timeout's subject.
cat > "$FX/tests/test-fx-slow.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$FX_DIR/fixture-slow.sh"
if fxs_ok; then
  printf 'PASS: fxs_ok succeeded\n'
else
  sleep 300
fi
EOF

# Oracle F — its workspace collapses when its target is mutated. Green on the
# pristine tree (it must be: run.sh refuses to measure a target whose baseline
# is red, correctly, so an always-failing fixture would produce no verdicts at
# all), and on a mutant it reproduces the SIGNATURE backlog F31 measured in the
# field — the marker line, a real FAIL: line, and a non-zero exit together.
# All three, because a verdict that only holds for the tidy case is not the
# guard that was needed: without the scaffold branch, `failline` alone carries
# this to KILLED.
cat > "$FX/tests/test-fx-scaffold.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
if [[ "$(fx_bigger 5 3)" == "yes" ]]; then
  printf 'PASS: fx_bigger orders its arguments\n'
  exit 0
fi
printf 'SCAFFOLD-FAILED: mktemp -d\n'
printf 'FAIL: everything downstream of a collapsed workspace\n'
exit 1
EOF

# Oracle G — always collapses, and exists only for the DRIVER assertion in case
# 14. run.sh never selects it: it names its oracle as a filter, and no
# targets.conf row here names this file.
cat > "$FX/tests/test-fx-collapse.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'SCAFFOLD-FAILED: mktemp -d\n'
printf 'FAIL: everything downstream of a collapsed workspace\n'
exit 1
EOF

# Oracle H — BLIND to the mutant oracle A catches, and the only thing that
# catches the one oracle A misses. It calls fx_never_called and nothing else, so
# the cmp-flip inside fx_bigger's asserted `if` is invisible to it while
# fx_never_called's return-flip is not. Paired with oracle A in one row, the two
# cover the union — which is the whole point of the oracle SET, and is only
# demonstrable with a member that is genuinely blind on its own.
cat > "$FX/tests/test-fx-blind.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
if fx_never_called; then
  printf 'PASS: fx_never_called succeeds\n'
  exit 0
fi
printf 'FAIL: fx_never_called succeeds\n'
exit 1
EOF

# Oracle I — the DRIVER dies from a SIGNAL when its target is mutated. Green on
# the pristine tree, exactly like oracle F, so the baseline passes and the
# target is actually measured. On a mutant it SIGKILLs its parent, which IS the
# driver: falsify_run_oracle `exec`s `bash run-all.sh` in the subshell it waits
# on, so the test's $PPID is that very process. Nothing prints `FAIL:` and no
# watchdog fires — 137 is the ONLY thing that reaches the runner, which is the
# signature the OOM killer leaves when it picks one of $(nproc) workers on a
# memory-capped host.
cat > "$FX/tests/test-fx-signal.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
if [[ "$(fx_bigger 5 3)" == "yes" ]]; then
  printf 'PASS: fx_bigger orders its arguments\n'
  exit 0
fi
kill -KILL "$PPID"
exit 0
EOF

# Oracle I — the ASSERTLESS shape: green on the pristine tree, and on the
# mutated one it exits non-zero having printed NOTHING. No FAIL:, no
# SCAFFOLD-FAILED:, no signal, no timeout — every other channel that means
# "nothing was observed" is already UNPROVEN before this point, so what is left
# is a test that aborted somewhere without reporting. Not a contrived shape: it
# is exactly what errexit inherited from a sourced product script did to two of
# shared-files.sh's mutants for weeks (backlog F43), and the tier scored both
# KILLED.
cat > "$FX/tests/test-fx-assertless.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
if [[ "$(fx_bigger 5 3)" == "yes" ]]; then
  printf 'PASS: fx_bigger orders its arguments\n'
  exit 0
fi
exit 1
EOF

# THE REAL DRIVER, copied: the oracle contract is `tests/run-all.sh <name>`, so a
# fixture with a hand-written stand-in driver would be testing the stand-in.
cp "$TESTS_DIR/run-all.sh" "$FX/tests/run-all.sh"
# Created HERE, with the other fixture oracles, so it is TRACKED before the
# fixture repo is committed: falsify_seed_tree copies `git ls-files`, so an
# untracked oracle never reaches a worker tree and run-all.sh reports "no tests
# matched". Its assertions live in §14e.
cat > "$FX/tests/test-fx-flaky.sh" <<'FLAKY'
#!/usr/bin/env bash
set -uo pipefail
# Stands in for an oracle that is green on a quiet machine and goes red under
# load. The trigger is a counter rather than real contention, because a test
# that waits for a race is a test that fails somewhere else.
n=0
[[ -f "${FX_FLAKY_COUNT:-}" ]] && n="$(cat "$FX_FLAKY_COUNT")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FX_FLAKY_COUNT"
if (( n >= ${FX_FLAKY_FROM:-4} )); then
  printf 'FAIL: run %s — the machine, not the mutation\n' "$n"
  # Indented continuation, exactly as tests/run-all.sh's `check` helper emits
  # its expected/got pair. The capture has to bring this out too or it reports
  # the name of a failure and none of its evidence.
  printf '       expected-vs-got: the evidence lives on this line\n'
  exit 1
fi
printf 'PASS: flaky oracle run %s\n' "$n"
FLAKY
chmod +x "$FX/tests/test-fx-flaky.sh"

# Oracle K — its SCAFFOLD collapses on its first N invocations and then works.
# Stands in for the one event the baseline gate could not survive: a transient
# exec failure during the single pristine baseline run each target gets. The
# trigger is a counter, not real contention, for the reason the flaky oracle
# above gives — a test that waits for a race is a test that fails somewhere
# else. Past the Nth invocation it behaves exactly like oracle A, so a target
# whose baseline was retried is genuinely measured rather than merely
# un-skipped.
cat > "$FX/tests/test-fx-scafflaky.sh" <<'SCAFFLAKY'
#!/usr/bin/env bash
set -uo pipefail
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n=0
[[ -f "${FX_SCAF_COUNT:-}" ]] && n="$(cat "$FX_SCAF_COUNT")"
n=$(( n + 1 ))
printf '%s' "$n" > "$FX_SCAF_COUNT"
if (( n <= ${FX_SCAF_UNTIL:-0} )); then
  printf 'SCAFFOLD-FAILED: chmod +x the recorder: rc=137, NOTHING on stderr
'
  exit 1
fi
# shellcheck source=/dev/null
source "$FX_DIR/fixture-lib.sh"
if [[ "$(fx_bigger 5 3)" == "yes" && "$(fx_bigger 3 5)" == "no" ]]; then
  printf 'PASS: fx_bigger orders its arguments
'
  exit 0
fi
printf 'FAIL: fx_bigger orders its arguments
'
exit 1
SCAFFLAKY
chmod +x "$FX/tests/test-fx-scafflaky.sh"

# Oracle L — collapses AND asserts, which is what an ORACLE SET looks like when
# one member's workspace fails while another member is genuinely red. The two
# lines arrive in one log because the set is one run-all.sh invocation, so
# FALSIFY_SIGNAL carries `failline` AND `scaffold` together. Retrying that, or
# calling it the environment, sends the reader at the machine while the tree is
# broken.
cat > "$FX/tests/test-fx-scaffold-and-fail.sh" <<'SCAFFAIL'
#!/usr/bin/env bash
set -uo pipefail
n=0
[[ -f "${FX_SCAF_COUNT:-}" ]] && n="$(cat "$FX_SCAF_COUNT")"
n=$(( n + 1 )); printf '%s' "$n" > "$FX_SCAF_COUNT"
printf 'SCAFFOLD-FAILED: chmod +x the recorder: rc=137, NOTHING on stderr\n'
printf 'FAIL: a genuinely red assertion in another member of the set\n'
exit 1
SCAFFAIL
chmod +x "$FX/tests/test-fx-scaffold-and-fail.sh"

( cd "$FX" && git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1
  git add -A && git -c user.email=t@example -c user.name=t commit -qm fixture ) >/dev/null 2>&1
if ( cd "$FX" && git rev-parse HEAD >/dev/null 2>&1 ); then
  pass "fixture repo built and committed"
else
  fail "fixture repo built and committed — every assertion below would be vacuous"
  printf '\n%d failure(s)\n' "$fails"; exit "$fails"
fi

conf() { printf '%s\n' "$2" > "$TMP/$1.conf"; printf '%s' "$TMP/$1.conf"; }
CONF_A="$(conf a 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-a.sh')"
CONF_B="$(conf b 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-b.sh')"
CONF_C="$(conf c 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-c.sh')"
CONF_SILENT="$(conf silent 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-silent.sh')"
CONF_SLOW="$(conf slow 'fixture-slow.sh|EXECUTED-WHOLE|test-fx-slow.sh')"
CONF_TYPO="$(conf typo 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-nosuchtest.sh')"
CONF_SCAFFOLD="$(conf scaffold 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-scaffold.sh')"
CONF_BLIND="$(conf blind 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-blind.sh')"
CONF_SIGNAL="$(conf signal 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-signal.sh')"
CONF_ASSERTLESS="$(conf assertless 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-assertless.sh')"
CONF_SCAFFLAKY="$(conf scafflaky 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-scafflaky.sh')"
CONF_SCAFFAIL="$(conf scaffail 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-scaffold-and-fail.sh')"
# The blind oracle is FIRST deliberately: a runner that ran only the first name
# would report the fx_bigger mutant SURVIVED, which is exactly the regression
# this row type exists to make impossible.
CONF_SET="$(conf set 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-blind.sh,test-fx-a.sh')"
CONF_PARTIAL="$(conf partial 'fixture-lib.sh|EXECUTED-PARTIAL|test-fx-a.sh|fx_bigger')"
CONF_GREPPED="$(conf grepped 'fixture-lib.sh|GREPPED-ONLY|test-fx-a.sh')"

PRISTINE_CK="$(cksum < "$FX/fixture-lib.sh" | tr -d ' ')"

# ── driving the runner ────────────────────────────────────────────────────────
FX_OUT=""; FX_ERR=""; FX_RC=0
fx_run() {   # <runner> <conf> <repo> <witness> [args…]
  local runner="$1" cnf="$2" repo="$3" wit="$4"; shift 4
  # A GENEROUS DEFAULT TIMEOUT, because every fixture oracle here is
  # sub-second and any timeout at all means the MACHINE was slow, never that
  # the fixture hung. Without this the runner's own 60s default applied, and on
  # macOS it was reached — three host runs failed at three DIFFERENT assertions
  # for the one underlying reason. The worst shape was a timed-out BASELINE:
  # run.sh then skips the whole target (correctly — an oracle that is not green
  # on the pristine tree cannot distinguish anything), so no MUTANT line is
  # emitted at all and every verdict lookup returns MISSING, which reads like a
  # broken runner rather than a slow host.
  #
  # A caller that passes its own --timeout wins: case 11 deliberately uses
  # --timeout 1 to exercise the timeout path, and must not be overridden here.
  local has_timeout=0 a
  for a in "$@"; do [[ "$a" == "--timeout" ]] && has_timeout=1; done
  (( has_timeout )) || set -- "$@" --timeout "${FX_TIMEOUT:-300}"
  # TMPDIR INTO THIS TEST'S OWN SCRATCH, which this file's EXIT trap removes.
  # Several cases below SIGKILL an oracle on purpose (the --timeout 1 path, the
  # stale-watchdog cases), and a SIGKILLed `tests/run-all.sh` cannot run its own
  # EXIT trap -- so it orphans the per-test log it had just created. Measured
  # 2026-08-29: three such logs per run of this file, left in the user's temp
  # directory forever. They are not a cleanup defect in the driver (a normal
  # exit removes the log; only the kill does not), so the cure is CONTAINMENT
  # rather than another trap: run-all.sh creates that log with an explicit
  # ${TMPDIR}-rooted template, so pointing TMPDIR here puts every orphan inside
  # a directory that goes when this file does.
  FALSIFY_REPO="$repo" FALSIFY_CONF="$cnf" TMPDIR="$TMP" \
  FX_WITNESS="$wit" FX_ORIGIN="$repo/fixture-lib.sh" \
    bash "$runner" "$@" > "$TMP/stdout" 2> "$TMP/stderr"
  FX_RC=$?
  FX_OUT="$(cat "$TMP/stdout")"
  FX_ERR="$(cat "$TMP/stderr")"
  # A run that emitted no MUTANT line at all produced no verdicts, so every
  # later lookup says MISSING and none of them says why. Surface the runner's
  # own diagnosis once, here, where the cause is still in hand.
  if ! grep -q '^MUTANT|' <<< "$FX_OUT"; then
    printf '       fx_run: NO MUTANT lines (rc=%s). runner stderr:\n' "$FX_RC" >&2
    sed 's/^/       | /' <<< "$FX_ERR" | tail -8 >&2
  fi
}

fx_field() {   # <runner output> <needle in the mutated line> <field no>
  awk -F'|' -v needle="$2" -v fn="$3" '
    $1 == "MUTANT" && index($0, needle) > 0 { c++; v = $fn }
    END { if (c == 1) print v; else if (c == 0) print "MISSING"; else print "AMBIGUOUS:" c }
  ' <<< "$1"
}
fx_verdict() { fx_field "$1" "$2" 2; }
fx_signal()  { fx_field "$1" "$2" 7; }
fx_ident()   { fx_field "$1" "$2" 3; }

# The two mutants whose fate is known before the run: the cmp-flip inside the
# asserted `if`, and the return-flip inside the function nothing calls.
KILLABLE='-le '
SURVIVOR='return 1'

# ── 1. Isolation, recorded before and after a full run ────────────────────────
head_fx_before="$(git -C "$FX" rev-parse HEAD)"
porc_fx_before="$(git -C "$FX" status --porcelain)"
head_repo_before="$(git -C "$REPO_DIR" rev-parse HEAD)"
porc_repo_before="$(git -C "$REPO_DIR" status --porcelain)"

fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-a" --jobs 2

head_fx_after="$(git -C "$FX" rev-parse HEAD)"
porc_fx_after="$(git -C "$FX" status --porcelain)"
head_repo_after="$(git -C "$REPO_DIR" rev-parse HEAD)"
porc_repo_after="$(git -C "$REPO_DIR" status --porcelain)"

check "a full run leaves the mutated repo's HEAD untouched" "$head_fx_before" "$head_fx_after"
check "a full run leaves the mutated repo's porcelain untouched" "$porc_fx_before" "$porc_fx_after"
check "a full run leaves THIS repo's HEAD untouched" "$head_repo_before" "$head_repo_after"
check "a full run leaves THIS repo's porcelain untouched" "$porc_repo_before" "$porc_repo_after"

# Before/after equality is necessary and not sufficient: a runner that damaged
# the origin and restored it afterwards would pass all four. The witness is
# per-invocation, so it can only be satisfied by never writing there at all.
n_wit="$(grep -c . "$TMP/wit-a" 2>/dev/null)"; n_wit="${n_wit:-0}"
n_origin_moved="$(grep -c -v "origin=$PRISTINE_CK " "$TMP/wit-a" 2>/dev/null)"; n_origin_moved="${n_origin_moved:-0}"
n_self_moved="$(grep -c -v "self=$PRISTINE_CK\$" "$TMP/wit-a" 2>/dev/null)"; n_self_moved="${n_self_moved:-0}"
if [[ "$n_wit" -ge 5 ]]; then
  pass "the oracle really ran ($n_wit invocations witnessed: 1 baseline + 4 mutants)"
else
  fail "the oracle really ran (witnessed $n_wit invocations, expected >= 5)"
fi
check "the ORIGIN file was pristine at every single oracle invocation" "0" "$n_origin_moved"
if [[ "$n_self_moved" -ge 3 ]]; then
  pass "the mutants were really applied — in the WORKER tree ($n_self_moved of $n_wit invocations saw a changed file there)"
else
  fail "the mutants were really applied in the worker tree ($n_self_moved changed, expected >= 3)"
fi

# ── 2. That isolation check can fail: demonstrate the fingerprint reads state ──
cp "$FX/fixture-lib.sh" "$TMP/fixture-lib.keep"
printf '# a change the fingerprint must notice\n' >> "$FX/fixture-lib.sh"
porc_fx_dirty="$(git -C "$FX" status --porcelain)"
if [[ "$porc_fx_dirty" != "$porc_fx_before" ]]; then
  pass "the porcelain fingerprint DOES change when the tree changes (so equality above meant something)"
else
  fail "the porcelain fingerprint DOES change when the tree changes — it reads a constant"
fi
cp "$TMP/fixture-lib.keep" "$FX/fixture-lib.sh"
check "fixture restored after that demonstration" "$porc_fx_before" "$(git -C "$FX" status --porcelain)"

# ── 3. The output contract Task 7 parses ──────────────────────────────────────
check "the run exits 0 (survivors are data, not failure)" "0" "$FX_RC"
grep -qE '^RUN\|repo=.*\|jobs=2\|.*\|targets=1\|mutants=4$' <<< "$FX_OUT" \
  && pass "RUN| header carries the selection totals" \
  || fail "RUN| header carries the selection totals: $(grep '^RUN|' <<< "$FX_OUT")"
check "BASELINE| records the pristine oracle as PASS" "1" \
  "$(grep -c '^BASELINE|fixture-lib.sh|test-fx-a.sh|PASS|' <<< "$FX_OUT")"
check "one MUTANT| line per generated mutant" "4" "$(grep -c '^MUTANT|' <<< "$FX_OUT")"
check "TARGET| tallies the target: 4 = 3 killed + 1 survived + 0 unproven" "1" \
  "$(grep -c '^TARGET|fixture-lib.sh|test-fx-a.sh|4|3|1|0|0|' <<< "$FX_OUT")"
check "TOTAL| closes the run with the UNRESOLVED percentage" "1" \
  "$(grep -c '^TOTAL|1|4|3|1|0|0|25|' <<< "$FX_OUT")"

ident="$(fx_ident "$FX_OUT" "$KILLABLE")"
if [[ "$ident" =~ ^fixture-lib\.sh:cmp-flip:[0-9a-f]{40}$ ]]; then
  pass "the ledger identity is <file>:<operator>:<sha1>, not file:line ($ident)"
else
  fail "the ledger identity is <file>:<operator>:<sha1> (got '$ident')"
fi

# ── 4. BOTH verdicts, on mutants whose fate is known in advance ───────────────
check "the observed mutant is KILLED" "KILLED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
check "the mutant in the never-called function SURVIVES" "SURVIVED" "$(fx_verdict "$FX_OUT" "$SURVIVOR")"
check "a survivor's signal field is 'none'" "none" "$(fx_signal "$FX_OUT" "$SURVIVOR")"
check "a real test kills through BOTH signals at once" "exit+failline" "$(fx_signal "$FX_OUT" "$KILLABLE")"

# ── 5. The oracle is `run-all.sh <name>`, not the test file ───────────────────
# test-fx-silent.sh exits 0 having asserted nothing. Run directly that is a pass;
# run through the driver it is a failure, by the driver's own gate. So a refusal
# here can only come from having gone through the driver.
fx_run "$RUN" "$CONF_SILENT" "$FX" "$TMP/wit-silent" --jobs 1
check "a test that exits 0 asserting nothing is caught — by the DRIVER's gate" "0" \
  "$(grep -c '^MUTANT|' <<< "$FX_OUT")"
grep -q 'not green on the PRISTINE tree' <<< "$FX_ERR" \
  && pass "  … and the runner refuses to mutate a target whose oracle is not green" \
  || fail "  … and the runner refuses to mutate a target whose oracle is not green: $FX_ERR"
check "  … exiting non-zero rather than reporting 4 kills" "1" "$FX_RC"

# ── 6. Oracle property: a filter matching nothing exits 2 ─────────────────────
# Asserted against the REAL driver, because the runner's refusal below is only
# meaningful if that is what a misspelled oracle actually does.
bash "$TESTS_DIR/run-all.sh" no-such-test-zzz-not-a-real-name >/dev/null 2>&1
check "run-all.sh exits 2 when its filter matches nothing" "2" "$?"

fx_run "$RUN" "$CONF_TYPO" "$FX" "$TMP/wit-typo" --jobs 1
check "a misspelled oracle produces NO verdicts at all" "0" "$(grep -c '^MUTANT|' <<< "$FX_OUT")"
grep -q 'matched NO test' <<< "$FX_ERR" \
  && pass "  … and is reported for what it is (run-all.sh exit 2), by name" \
  || fail "  … and is reported for what it is (run-all.sh exit 2): $FX_ERR"
check "  … and the run fails rather than reporting every mutant killed" "1" "$FX_RC"

# ── 6b. A SKIPPED TARGET MUST SAY SO ON THE RECORD STREAM ────────────────────
# The run above is the whole of backlog F54 in miniature: one target, four
# mutants, none attempted, and a TOTAL that reports the targets fr_load_targets
# ACCEPTED rather than the ones it MEASURED. On macOS at --jobs 32 --timeout 5
# that read `TOTAL|9|106|…` while four targets and 158 mutants had never been
# tried, and the only thing that said so was four ERROR lines on stderr — which
# is exactly what a summary reader filters out.
#
# rc=1 is what stops this being silent and it is asserted directly above. These
# assertions are about the RECORD stream, because that is what check-ledger.sh,
# verify-on-host.sh and every later consumer read.
check "a skipped target is recorded on stdout, with the mutants it took with it" "1" \
  "$(grep -c '^SKIPPED|fixture-lib.sh|test-fx-nosuchtest.sh|4|no-test-matched$' <<< "$FX_OUT")"
check "  … and the run says how much of the corpus was never attempted" "1" \
  "$(grep -c '^UNATTEMPTED|1|4|4$' <<< "$FX_OUT")"
# THE CONTRADICTION THE RECORD RESOLVES. TOTAL still says zero verdicts over one
# target; UNATTEMPTED is the line that says four mutants existed and none ran.
check "  … while TOTAL alone still reports a target it never measured" "1" \
  "$(grep -c '^TOTAL|1|0|' <<< "$FX_OUT")"

# THE NEGATIVE CONTROL. Emitted at zero on a healthy run, like ASSERTLESS —
# without this, a build that never emitted the record would pass nothing, and a
# build that emitted it always-nonzero would pass everything above.
fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-unatt" --jobs 1
check "a run that skipped nothing still says so, at zero" "1" \
  "$(grep -c '^UNATTEMPTED|0|0|4$' <<< "$FX_OUT")"
check "  … and records no SKIPPED line at all" "0" \
  "$(grep -c '^SKIPPED|' <<< "$FX_OUT")"

# ── 7. Oracle property: a dirty tree does not by itself change the verdict ────
# Every worker tree is dirty by construction — the mutant IS the modification —
# and tests/integration/mutate.sh's cmd_apply carries a `git diff --quiet` gate.
# If tree dirtiness alone failed that oracle, all 55 of its mutants would be
# reported KILLED and the tier's headline number would be a lie.
#
# The real oracle, on a real tree: tracked files copied into a fresh git repo
# (cheap — no 18 MB .git to duplicate; this assertion is about the ORACLE's
# behaviour on a dirty tree, not about run.sh's copying, which sections 1 and 4
# exercise end to end).
DT="$TMP/dirty-tree"
mkdir -p "$DT"
( cd "$REPO_DIR" && git ls-files ) > "$TMP/tracked.list"
if tar -cf - -T "$TMP/tracked.list" -C "$REPO_DIR" 2>/dev/null | ( cd "$DT" && tar -xf - ) \
   || ( cd "$REPO_DIR" && tar -cf - -T "$TMP/tracked.list" ) | ( cd "$DT" && tar -xf - ); then
  ( cd "$DT" && git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1
    git add -A && git -c user.email=t@example -c user.name=t commit -qm base ) >/dev/null 2>&1
fi
if [[ -f "$DT/tests/integration/mutate.sh" && -d "$DT/.git" ]]; then
  printf '\n# a no-op comment: changes no behaviour, only cleanliness\n' \
    >> "$DT/tests/integration/mutate.sh"
  if ( cd "$DT" && git diff --quiet ); then
    fail "the dirty-tree fixture is actually dirty"
  else
    pass "the dirty-tree fixture is actually dirty (git diff --quiet disagrees)"
  fi
  dt_out="$( cd "$DT" && bash tests/run-all.sh -v test-mutations.sh 2>&1 )"
  dt_rc=$?
  dt_faillines="$(grep -cE '(^|[[:space:]])FAIL:' <<< "$dt_out")"
  check "a no-op comment does not fail test-mutations.sh (exit)" "0" "$dt_rc"
  check "a no-op comment does not fail test-mutations.sh (no FAIL: line)" "0" "$dt_faillines"
else
  fail "could not build the dirty-tree fixture — the dirty-tree property is unverified"
fi

# ── 8. Breaking the EXIT half of the kill disjunction ─────────────────────────
# A copy of run.sh, one predicate rewritten to `return 1`. The break has to
# reach the variable the verdict is built from, so it is applied to the
# predicate itself and the flip is required — not merely allowed.
BRK="$TMP/brk"
mkdir -p "$BRK/tests/falsify"
cp "$TESTS_DIR/portability.sh" "$BRK/tests/"
cp "$TESTS_DIR/falsify/generate.sh" "$TESTS_DIR/falsify/derive-targets.sh" "$BRK/tests/falsify/"
BRK_RUN="$BRK/tests/falsify/run.sh"

fx_break() {   # <sed expression> <label> → 0 when the break really applied
  cp "$RUN" "$BRK_RUN"
  sed "$1" "$BRK_RUN" > "$TMP/broken.sh"
  if cmp -s "$BRK_RUN" "$TMP/broken.sh"; then
    fail "the $2 break applied (sed matched nothing — the demonstration would prove nothing)"
    return 1
  fi
  mv "$TMP/broken.sh" "$BRK_RUN"
  if ! bash -n "$BRK_RUN" 2>/dev/null; then
    fail "the $2 break left a parseable script"
    return 1
  fi
  pass "the $2 break applied to a COPY of run.sh, which still parses"
  return 0
}

# Control first: with oracle B the kill signal is the exit status ALONE.
fx_run "$RUN" "$CONF_B" "$FX" "$TMP/wit-b" --jobs 1
check "control: oracle B kills through the exit status only" "exit" "$(fx_signal "$FX_OUT" "$KILLABLE")"
check "control: and that mutant is KILLED" "KILLED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
if fx_break 's|^falsify_exit_kills() {.*|falsify_exit_kills() { return 1 # BROKEN-BY-TEST|' \
     "exit-status-detection"; then
  fx_run "$BRK_RUN" "$CONF_B" "$FX" "$TMP/wit-b2" --jobs 1
  check "  … with exit-status detection broken, the KILLED mutant flips to SURVIVED" \
    "SURVIVED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
fi

# ── 9. Breaking the FAIL:-line half ──────────────────────────────────────────
# Oracle C exits 0 and indents its FAIL: lines, so run-all.sh's own ^FAIL: gate
# reports PASS: the ONLY thing that can kill here is the FAIL:-line check.
fx_run "$RUN" "$CONF_C" "$FX" "$TMP/wit-c" --jobs 1
check "control: oracle C kills through a FAIL: line only" "failline" "$(fx_signal "$FX_OUT" "$KILLABLE")"
check "control: and that mutant is KILLED" "KILLED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
if fx_break 's|^falsify_has_fail_line() {.*|falsify_has_fail_line() { return 1 # BROKEN-BY-TEST|' \
     "FAIL:-line detection"; then
  fx_run "$BRK_RUN" "$CONF_C" "$FX" "$TMP/wit-c2" --jobs 1
  check "  … with FAIL:-line detection broken, the KILLED mutant flips to SURVIVED" \
    "SURVIVED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
fi

# ── 10. Breaking the ISOLATION, on a throwaway copy of the fixture repo ───────
# fr_slot_tree is what decides where a mutant is written. Point it at the origin
# and the witness must notice — otherwise section 1's witness assertion is
# reading a constant too.
FXD="$TMP/repo-broken-isolation"
cp -a "$FX" "$FXD"
if fx_break 's|^fr_slot_tree() {.*|fr_slot_tree() { printf "%s" "$FR_REPO"; }|' \
     "worker-tree-location"; then
  fx_run "$BRK_RUN" "$CONF_A" "$FXD" "$TMP/wit-broken" --jobs 1
  n_moved="$(grep -c -v "origin=$PRISTINE_CK " "$TMP/wit-broken" 2>/dev/null)";   n_moved="${n_moved:-0}"
  if [[ "$n_moved" -ge 1 ]]; then
    pass "a runner that writes into the origin tree IS caught by the witness ($n_moved invocation(s))"
  else
    fail "a runner that writes into the origin tree IS caught by the witness — it saw nothing, so section 1 proves nothing"
  fi
fi
check "the real fixture repo is still clean after that" "$porc_fx_before" "$(git -C "$FX" status --porcelain)"

# ── 11. The per-mutant timeout is UNPROVEN, never KILLED ──────────────────────
# It used to be reported KILLED, and that inverted the tool: a merely SLOW
# oracle then reclassified a real survivor as killed, hiding the one thing this
# tier produces. Observed on a real host — the fixture mutant in a function
# NOTHING CALLS, which cannot hang, timed out under load and was called KILLED.
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-slow" --jobs 1 --timeout 1
check "a hung oracle is UNPROVEN, not KILLED" "UNPROVEN" "$(fx_verdict "$FX_OUT" 'return 1')"
sig="$(fx_signal "$FX_OUT" 'return 1')"
[[ "$sig" == *timeout* ]] \
  && pass "  … with the timeout named in its signal field ($sig)" \
  || fail "  … with the timeout named in its signal field (got '$sig')"
# The note must report what it MEASURED, not repeat back the clock it was
# configured with. It used to print "TIMEOUT after ${FR_TIMEOUT}s" for every
# timeout — a string indistinguishable from one that never looked at the
# mutant's own elapsed time, and on macOS it was printing "after 600s" for
# mutants inside a target whose entire wall time was 64 seconds (backlog F50).
grep -qE 'TIMEOUT: the oracle ran [0-9]+\.[0-9]s against a 1s clock \(UNPROVEN — nothing was observed asserting\)' <<< "$FX_ERR" \
  && pass "  … and flagged on stderr as UNPROVEN, naming the measured elapsed and the clock" \
  || fail "  … and flagged on stderr as UNPROVEN, naming the measured elapsed and the clock: $FX_ERR"

# AND THE TWO NUMBERS MUST AGREE. A run that lasted less than its own clock did
# not time out, whatever the signal field says. That is the contradiction the
# old wording made unreadable — every note repeated the limit back, so a verdict
# that could not have happened read exactly like one that did. Asserted here
# against the fixture that genuinely hangs, so the check is known to hold when
# the verdict is honest.
to_ran="$(sed -n 's/.*the oracle ran \([0-9][0-9]*\)\.[0-9]s against a \([0-9][0-9]*\)s clock.*/\1 \2/p' <<< "$FX_ERR" | head -1)"
if [[ -z "$to_ran" ]]; then
  fail "  … and both of the note's numbers are readable — got none from: $FX_ERR"
elif (( ${to_ran% *} >= ${to_ran#* } )); then
  pass "  … and the elapsed it reports is at least the clock it names (${to_ran% *}s vs ${to_ran#* }s)"
else
  fail "  … and the elapsed it reports is at least the clock it names — ran ${to_ran% *}s against a ${to_ran#* }s clock, so the tier called something a timeout that finished well inside its own limit"
fi
check "  … counted as unproven, NOT as a kill, in TOTAL" "1" \
  "$(grep -c '^TOTAL|1|1|0|0|1|1|100|' <<< "$FX_OUT")"

# ── 11b. THE TIMEOUT FLAG MUST NAME WHO ARMED IT ──────────────────────────────
# `out` is "$FR_OUT/w$slot.log" — one file per WORKER SLOT, reused by every
# mutant that ever runs in that slot across every target — and the timeout flag
# is derived from it. So "the flag exists" only ever meant "somebody wrote it",
# while it was read as "MY oracle timed out".
#
# Those came apart on macOS, 2026-08-20, --jobs 8 --timeout 600: five mutants
# carried a `timeout` signal after running 6.6s to 59.8s of a 600-second clock.
# Two were scored UNPROVEN on a BARE `timeout` — no `exit`, no `failline`, which
# is an oracle that ran to completion and passed, i.e. a SURVIVOR. A watchdog
# that had really fired would have TERMed it and left `timeout+signal`. So a
# stale watchdog took two survivors out of the ledger's reach without a word,
# through UNPROVEN's accepted-but-not-required exemption (backlog F50).
#
# Asserted on the predicate itself, because the defect was that "the flag
# exists" and "this invocation armed it" were the same expression. Sourced in a
# SUBSHELL so run.sh's globals cannot reach this file's own state; run.sh guards
# its main with `BASH_SOURCE == $0`, so sourcing defines functions and runs
# nothing.
flag_is_mine() {   # <flagfile> <token> → run.sh's own predicate, in a subshell
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    falsify_flag_is_mine "$1" "$2" )
}

if ( set +u
     # shellcheck source=/dev/null
     source "$RUN" >/dev/null 2>&1
     declare -F falsify_flag_is_mine >/dev/null ); then
  pass "run.sh exposes falsify_flag_is_mine"
  ff="$TMP/flagcheck"; rm -f "$ff"

  flag_is_mine "$ff" "tok-a" \
    && fail "  … a missing flag is not mine" \
    || pass "  … a missing flag is not mine"

  : > "$ff"
  flag_is_mine "$ff" "tok-a" \
    && fail "  … an EMPTY flag is not mine — that is precisely what the old ': > \$flag' wrote, and it was read as this run's timeout" \
    || pass "  … an EMPTY flag is not mine (the form the old code wrote)"

  printf '%s' "tok-b" > "$ff"
  flag_is_mine "$ff" "tok-a" \
    && fail "  … ANOTHER invocation's flag is not mine — a stale watchdog's write still scores as my timeout, which is the whole finding" \
    || pass "  … another invocation's flag is not mine"

  printf '%s' "tok-a" > "$ff"
  flag_is_mine "$ff" "tok-a" \
    && pass "  … my own flag IS mine, so a real timeout is still detected" \
    || fail "  … my own flag IS mine, so a real timeout is still detected — the ownership check has disabled the timeout path outright"
  rm -f "$ff"
else
  fail "run.sh exposes falsify_flag_is_mine — without it 'the flag exists' is still the whole test, so any invocation's flag reads as this one's timeout"
  fail "  … a missing flag is not mine — there is no predicate to ask"
  fail "  … an EMPTY flag is not mine (the form the old code wrote) — there is no predicate to ask"
  fail "  … another invocation's flag is not mine — there is no predicate to ask"
  fail "  … my own flag IS mine, so a real timeout is still detected — there is no predicate to ask"
fi

# ── 11c. THE WATCHDOG MUST NOT OUTLIVE THE ORACLE IT WATCHES ─────────────────
# It used to `sleep "$limit"` blind, so it stayed alive for the rest of its clock
# after the oracle had finished — and a stale watchdog does not just sit there,
# it goes on to `kill -TERM -"$pid"` against a pid recorded up to <timeout>
# seconds earlier. Recycled by then on a busy host, that kill lands on another
# worker's live oracle and truncates it, which is how two mutants came back
# UNPROVEN on a bare `timeout` while being reliable kills (backlog F50).
#
# Asserted on the wait itself, because the property is about TIME: a blind
# `sleep "$limit"` passes the "clock expired" case below and fails the one after
# it, which is the whole difference.
# run.sh's own microsecond clock, in a subshell, so these cases measure time the
# same way the code under test does rather than with a second-resolution
# approximation of it (backlog F55).
fr_now_us_of() {
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    fr_now_us )
}

watch_until() {   # <pid> <seconds> → run.sh's own wait, in a subshell
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    falsify_watch_until "$1" "$2" )
}

if ( set +u
     # shellcheck source=/dev/null
     source "$RUN" >/dev/null 2>&1
     declare -F falsify_watch_until >/dev/null ); then
  pass "run.sh exposes falsify_watch_until"

  # A subject that outlives the clock: the wait must report the clock expiring.
  #
  # MEASURED IN MILLISECONDS, and that is a fix rather than a flourish. This
  # assertion used `$SECONDS`, whose resolution is one second: a wait of ~3.00 s
  # reads as 2 or 3 depending only on where the start landed inside a second, so
  # `>= 3` failed roughly whenever the boundaries fell badly. It did — once,
  # under full-suite load, and the message was `rc=1 after 2s` (backlog F55):
  # rc was RIGHT and only the clock reading was wrong.
  #
  # The threshold is deliberately BELOW the nominal clock. What this case has to
  # separate is "waited for the clock" from "returned immediately without
  # waiting" — a blind `return 1` finishes in single-digit milliseconds, so 2000
  # ms discriminates that with a full second of margin either side and no
  # dependence on boundary alignment.
  sleep 30 & wu_pid=$!
  wu_t0="$(fr_now_us_of)"
  watch_until "$wu_pid" 3 && wu_rc=0 || wu_rc=1
  wu_el=$(( ( $(fr_now_us_of) - wu_t0 ) / 1000 ))
  kill "$wu_pid" 2>/dev/null; wait "$wu_pid" 2>/dev/null
  if [[ "$wu_rc" -eq 1 && "$wu_el" -ge 2000 ]]; then
    pass "  … a subject that outlives the clock reports the clock expiring (${wu_el}ms)"
  else
    fail "  … a subject that outlives the clock reports the clock expiring — rc=$wu_rc after ${wu_el}ms, so a real hang would no longer time out"
  fi

  # THE ONE THAT MATTERS. A subject that exits early must end the wait EARLY. A
  # blind `sleep "$limit"` returns the right answer here and takes the full 20
  # seconds to do it — and every second of that is a watchdog holding a pid it
  # no longer owns.
  sleep 1 & wu_pid2=$!
  wu_t0="$(fr_now_us_of)"
  watch_until "$wu_pid2" 20 && wu_rc2=0 || wu_rc2=1
  wu_el2=$(( ( $(fr_now_us_of) - wu_t0 ) / 1000 ))
  wait "$wu_pid2" 2>/dev/null
  if [[ "$wu_rc2" -eq 0 && "$wu_el2" -lt 10000 ]]; then
    pass "  … a subject that exits first ends the wait immediately (${wu_el2}ms of a 20s clock)"
  else
    fail "  … a subject that exits first ends the wait immediately — rc=$wu_rc2 after ${wu_el2}ms of a 20s clock, so the watchdog outlives its oracle and still holds a pid that may be recycled"
  fi
else
  fail "run.sh exposes falsify_watch_until — without it the watchdog sleeps its whole clock and stays alive holding a stale pid"
  fail "  … a subject that outlives the clock reports the clock expiring — there is no wait to ask"
  fail "  … a subject that exits first ends the wait immediately — there is no wait to ask"
fi

# ── 11d. A WORKER THAT PRODUCES NO VERDICT MUST SAY WHY ──────────────────────
# fr_harvest reports "a mutant worker produced no verdict at all (slot N)" and
# stops there. That sentence is true and useless: it cannot tell a worker that
# exited on its own from one something else SIGKILLed. On macOS, under a clock
# tight enough to fire the watchdog, 158 of 264 mutants left the measured set
# through exactly that line with no cause recorded, and the entry filed for it
# had to stop short of a mechanism (backlog F52).
#
# The pool HELD the fact and threw it away. `wait -n` returns the finished
# child's status; the loop discarded it and then went looking for the finished
# pid with `kill -0`, which answers "does some process hold this pid" — not "is
# this still my worker". `wait -n -p` names the pid AND keeps the status.
#
# Two assertions, deliberately split. The sentence is a pure function of a wait
# status, asserted directly. The WIRING — that a killed worker's status reaches
# that sentence — is asserted by running the pool against a worker this test
# kills itself, because a cause-builder nothing calls proves nothing.
exit_cause() {   # <wait status> → run.sh's own clause, in a subshell
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    fr_exit_cause "$1" )
}

if ( set +u
     # shellcheck source=/dev/null
     source "$RUN" >/dev/null 2>&1
     declare -F fr_exit_cause >/dev/null ); then
  pass "run.sh exposes fr_exit_cause"
  check "  … 137 is named as the signal it is, not left as a number" \
        "it was KILLED BY SIGKILL" "$(exit_cause 137)"
  check "  … 143 names SIGTERM" \
        "it was KILLED BY SIGTERM" "$(exit_cause 143)"
  check "  … a worker that exited 0 having written nothing says exactly that" \
        "it exited 0 and wrote nothing" "$(exit_cause 0)"
  check "  … an ordinary failure reports its code" \
        "it exited 1" "$(exit_cause 1)"
  # 128 is an exit STATUS of 128, not signal 0. A >= that should be a > reads it
  # as a signal, which is why this case is here and not implied by the two above.
  check "  … 128 is an exit status, not signal 0" \
        "it exited 128" "$(exit_cause 128)"
  check "  … a status that was never captured is not invented" \
        "exit status not captured" "$(exit_cause "")"
else
  fail "run.sh exposes fr_exit_cause — a worker that vanishes still reports no cause"
  fail "  … 137 is named as the signal it is, not left as a number — no builder to ask"
  fail "  … 143 names SIGTERM — no builder to ask"
  fail "  … a worker that exited 0 having written nothing says exactly that — no builder to ask"
  fail "  … an ordinary failure reports its code — no builder to ask"
  fail "  … 128 is an exit status, not signal 0 — no builder to ask"
  fail "  … a status that was never captured is not invented — no builder to ask"
fi

# THE WIRING, through the real pool. A worker killed before it can write is
# exactly F52's missing mutant; the pool must name the signal that took it.
f52_killed="$( { set +u
  # shellcheck source=/dev/null
  source "$RUN" >/dev/null 2>&1
  rm -f "$TMP/f52-no-result"
  ( sleep 30 ) & f52_pid=$!
  FR_PID_SLOT["$f52_pid"]=7
  FR_PID_RESULT["$f52_pid"]="$TMP/f52-no-result"
  kill -KILL "$f52_pid" 2>/dev/null
  fr_wait_for_slot
  printf 'BROKEN=%s\n' "$FR_BROKEN"
} 2>&1 )"
case "$f52_killed" in
  *'produced no verdict at all'*'KILLED BY SIGKILL'*)
    pass "the pool reports a SIGKILLed worker as killed, not merely as absent" ;;
  *'produced no verdict at all'*'exit status not captured'*)
    # NOT a pass for the pool and not a failure of it: a platform limit, stated.
    # bash 5.1's `wait -n -p` intermittently returns 127 — its own "there are no
    # unwaited-for children" — for a child that has already terminated, and then
    # no status exists to attribute. Measured: the bash-floor CI job produced
    # exactly this, and the identical job passed on re-run. The pool saying so
    # is the correct behaviour; the thing that would be wrong is inventing a
    # number, which the next assertion pins.
    pass "the pool reported an honest non-capture (bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} supplied no status for an already-terminated child)" ;;
  *)
    fail "the pool reports a SIGKILLed worker as killed, not merely as absent — got: $(printf '%s' "$f52_killed" | tr '\n' ' ')" ;;
esac
# THE HARD ONE, and it holds on every bash: a `wait`-internal code is not a
# worker exit status. 127 means wait had nothing to report; printing "it exited
# 127" attributes to the worker a number nothing ever measured.
case "$f52_killed" in
  *'exited 127'*)
    fail "the pool reported wait's own 'no unwaited-for children' code as the worker's exit status — got: $(printf '%s' "$f52_killed" | tr '\n' ' ')" ;;
  *)
    pass "  … and never reports a wait-internal code as a worker exit status" ;;
esac
case "$f52_killed" in
  *'BROKEN=1'*) pass "  … and still counts it broken, so the run cannot pass on it" ;;
  *)            fail "  … and still counts it broken, so the run cannot pass on it — got: $(printf '%s' "$f52_killed" | tr '\n' ' ')" ;;
esac

# THE NEGATIVE CONTROL. Without it, a pool that called every worker broken would
# pass both assertions above.
f52_ok="$( { set +u
  # shellcheck source=/dev/null
  source "$RUN" >/dev/null 2>&1
  rm -f "$TMP/f52-result"
  ( printf 'MUTANT|KILLED|a.sh:op:deadbeef|o.sh|1|2|exit+failline|5|x\n' > "$TMP/f52-result" ) &
  f52_pid2=$!
  # shellcheck disable=SC2034  # both are read by fr_wait_for_slot/fr_harvest, sourced above
  FR_PID_SLOT["$f52_pid2"]=3
  # shellcheck disable=SC2034  # likewise
  FR_PID_RESULT["$f52_pid2"]="$TMP/f52-result"
  fr_wait_for_slot
  printf 'BROKEN=%s KILLED=%s\n' "$FR_BROKEN" "$FR_KILLED"
} 2>&1 )"
case "$f52_ok" in
  *'BROKEN=0 KILLED=1'*) pass "  … while a worker that DID write is harvested, not reported broken" ;;
  *)                     fail "  … while a worker that DID write is harvested, not reported broken — got: $(printf '%s' "$f52_ok" | tr '\n' ' ')" ;;
esac

# ── a re-seed that FAILED must not be reported as one that worked ────────────
# Introduced by the seed-fidelity guard itself: once fr_seed_slot can FAIL, the
# mid-run reseed can fail too, and it was neither reported nor counted -- the
# NOTE said "re-seeded" unconditionally. Every mutant scored in that slot
# afterwards ran against a tree that is not the repo, and the run still exited 0.
rsf_out="$( { set +u
  # shellcheck source=/dev/null
  source "$RUN" >/dev/null 2>&1
  rm -f "$TMP/rsf-result"
  ( printf 'NOTE|reseed-failed|a.sh:op:deadbeef|slot 3 could NOT be re-seeded; every later mutant in it runs against a tree that is not the repo\n' \
      > "$TMP/rsf-result" ) &
  rsf_pid=$!
  # shellcheck disable=SC2034  # read by fr_wait_for_slot/fr_harvest, sourced above
  FR_PID_SLOT["$rsf_pid"]=3
  # shellcheck disable=SC2034  # likewise
  FR_PID_RESULT["$rsf_pid"]="$TMP/rsf-result"
  fr_wait_for_slot
  printf 'RESEEDFAILED=%s BROKEN=%s\n' "$FR_RESEED_FAILED" "$FR_BROKEN"; } 2>&1 )"
case "$rsf_out" in
  *'RESEEDFAILED=1'*) pass "a failed re-seed is COUNTED, so the run cannot exit 0 on verdicts from a broken tree" ;;
  *) fail "a failed re-seed is COUNTED — got: $(printf '%s' "$rsf_out" | tr '\n' ' ')" ;;
esac
case "$rsf_out" in
  *'RESEED FAILED'*) pass "  … and named on stderr where it happens, not only in the summary" ;;
  *) fail "  … and named on stderr where it happens — got: $(printf '%s' "$rsf_out" | tr '\n' ' ')" ;;
esac
# The note must not ALSO read as a successful reseed, which is what made the
# regression invisible: the two share a prefix.
case "$rsf_out" in
  *'|reseed|'*) fail "  … and is not also reported as a successful re-seed" ;;
  *) pass "  … and is not also reported as a successful re-seed" ;;
esac

# ── 11e. A FOREIGN TIMEOUT FLAG MUST NAME BOTH TOKENS ────────────────────────
# On macOS at --jobs 32 --timeout 5, a watchdog belonging to another invocation
# killed a live oracle twice in one run. The NOTE said "slot 0 held a timeout
# flag armed by 50776.1787249974304247, not by this run" — a bare pid, of a
# process that had already exited, with nothing to compare it against. It named
# the event and identified nobody (backlog F53).
#
# Two changes, asserted separately. The token now carries the SLOT and MUTANT
# that armed it, so a foreign token names a place in the run rather than a dead
# pid. And the NOTE prints this invocation's own token beside the foreign one,
# because one token identifies nothing — a pair identifies a leak.
token_of() {   # <label> → run.sh's own token builder, in a subshell
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    fr_token "$1" )
}

if ( set +u
     # shellcheck source=/dev/null
     source "$RUN" >/dev/null 2>&1
     declare -F fr_token >/dev/null ); then
  pass "run.sh exposes fr_token"
  f53_t1="$(token_of 's3.m47')"
  if [[ "$f53_t1" =~ ^s3\.m47\.[0-9]+\.[0-9]+$ ]]; then
    pass "  … the token leads with the slot and mutant that armed it ($f53_t1)"
  else
    fail "  … the token leads with the slot and mutant that armed it — got '$f53_t1', so a foreign flag still names only a dead pid"
  fi
  # Uniqueness is what makes the ownership check an ownership check at all.
  f53_t2="$(token_of 's3.m47')"
  [[ "$f53_t1" != "$f53_t2" ]] \
    && pass "  … and two invocations with the SAME label still differ" \
    || fail "  … and two invocations with the SAME label still differ — both were '$f53_t1', so one worker's flag reads as another's"
  # An unlabelled call must not produce a leading empty field: '.1234.5678' looks
  # like a truncated token rather than an unlabelled one.
  f53_t3="$(token_of '')"
  [[ "$f53_t3" == '?.'* ]] \
    && pass "  … and an unlabelled token says so rather than leading with a dot" \
    || fail "  … and an unlabelled token says so rather than leading with a dot — got '$f53_t3'"
else
  fail "run.sh exposes fr_token — the flag token is built inline and cannot be asserted"
  fail "  … the token leads with the slot and mutant that armed it — no builder to ask"
  fail "  … and two invocations with the SAME label still differ — no builder to ask"
  fail "  … and an unlabelled token says so rather than leading with a dot — no builder to ask"
fi

if ( set +u
     # shellcheck source=/dev/null
     source "$RUN" >/dev/null 2>&1
     declare -F fr_foreign_note >/dev/null ); then
  pass "run.sh exposes fr_foreign_note"
  f53_note="$( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    fr_foreign_note 'a.sh:op:deadbeef' 7 'THEIRS.111.222' 'MINE.333.444' )"
  case "$f53_note" in
    *'THEIRS.111.222'*'MINE.333.444'*)
      pass "  … and the note names the foreign token AND this invocation's own" ;;
    *'THEIRS.111.222'*)
      fail "  … and the note names the foreign token AND this invocation's own — only the foreign one is there, which is the state F53 was filed in: $f53_note" ;;
    *)
      fail "  … and the note names the foreign token AND this invocation's own — got: $f53_note" ;;
  esac
else
  fail "run.sh exposes fr_foreign_note — the note is built inline and cannot be asserted"
  fail "  … and the note names the foreign token AND this invocation's own — no builder to ask"
fi

# THE WIRING, end to end. A fixture oracle that arms this slot's flag WHILE the
# oracle is running stands in for another invocation's watchdog — the F53 event,
# without needing a second worker to leak one. Nothing else in this file reaches
# the foreign-flag branch of falsify_run_oracle.
cat > "$FX/tests/test-fx-plantflag.sh" <<'PLANT'
#!/usr/bin/env bash
set -uo pipefail
# Stands in for a watchdog belonging to some other invocation.
if [[ -n "${FX_PLANT_FLAG:-}" ]]; then
  printf 'someone-elses-worker.99999.1700000000000000' > "$FX_PLANT_FLAG"
fi
printf 'PASS: plantflag ran\n'
PLANT
chmod +x "$FX/tests/test-fx-plantflag.sh"

f53_wire="$( set +u
  # shellcheck source=/dev/null
  source "$RUN" >/dev/null 2>&1
  export FX_PLANT_FLAG="$TMP/f53.log.timedout"
  rm -f "$TMP/f53.log" "$TMP/f53.log.timedout"
  falsify_run_oracle "$FX" "test-fx-plantflag.sh" "$TMP/f53.log" 30 "s7.m42"
  printf 'timedout=%s foreign=%s mine=%s\n' \
    "$FALSIFY_TIMED_OUT" "$FALSIFY_FOREIGN_FLAG" "$FALSIFY_TOKEN" )"
case "$f53_wire" in
  *'timedout=0'*) pass "a flag armed by someone else is NOT scored as a timeout" ;;
  *)              fail "a flag armed by someone else is NOT scored as a timeout — got: $f53_wire" ;;
esac
case "$f53_wire" in
  *'foreign=someone-elses-worker.99999.1700000000000000'*)
    pass "  … and the foreign token is reported verbatim" ;;
  *)
    fail "  … and the foreign token is reported verbatim — got: $f53_wire" ;;
esac
case "$f53_wire" in
  *'mine=s7.m42.'*)
    pass "  … and this invocation's own token names the slot and mutant it was given" ;;
  *)
    fail "  … and this invocation's own token names the slot and mutant it was given — got: $f53_wire" ;;
esac

# THE NEGATIVE CONTROL. Without it, a build that reported EVERY flag as foreign
# would pass all three assertions above.
f53_clean="$( set +u
  # shellcheck source=/dev/null
  source "$RUN" >/dev/null 2>&1
  unset FX_PLANT_FLAG
  rm -f "$TMP/f53b.log" "$TMP/f53b.log.timedout"
  falsify_run_oracle "$FX" "test-fx-plantflag.sh" "$TMP/f53b.log" 30 "s1.m1"
  printf 'timedout=%s foreign=[%s]\n' "$FALSIFY_TIMED_OUT" "$FALSIFY_FOREIGN_FLAG" )"
case "$f53_clean" in
  *'timedout=0 foreign=[]'*) pass "  … while a run that nobody interfered with reports no foreign flag" ;;
  *)                         fail "  … while a run that nobody interfered with reports no foreign flag — got: $f53_clean" ;;
esac

# ── 11f. ARMING THE FLAG MUST BE ATOMIC ──────────────────────────────────────
# F53 was filed as "a watchdog from another invocation killed a live oracle".
# It was not. The macOS run that F53's own instrumentation asked for came back
# with the two tokens printed side by side, and they were THE SAME STRING:
#
#   slot 1 held a timeout flag armed by s1.m2.67442.1787254686507373, not by
#   this invocation, whose own token was s1.m2.67442.1787254686507373
#
# `printf '%s' "$token" > "$flag"` is two steps. The redirection creates and
# truncates the destination; the token lands afterwards. falsify_flag_is_mine
# read it in between, got an incomplete file, and could only call it somebody
# else's — while the reporter, reading again microseconds later, got the whole
# token. A worker mistaking its OWN flag, not a leak from anyone.
#
# The contract assertions below are necessary and would not have caught it. The
# LAST one is the guard: it makes the write slow, on purpose, and asserts that
# the destination does not exist while the token is still being produced. That
# is the only assertion here that fails on the code F53 was filed against.
arm_flag() {   # <flagfile> <token> → run.sh's own writer, in a subshell
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    falsify_arm_flag "$1" "$2" )
}

if ( set +u
     # shellcheck source=/dev/null
     source "$RUN" >/dev/null 2>&1
     declare -F falsify_arm_flag >/dev/null ); then
  pass "run.sh exposes falsify_arm_flag"
  f53f="$TMP/arm.flag"; rm -f "$f53f"
  arm_flag "$f53f" "s2.m9.1234.5678"
  check "  … the flag holds exactly the token" "s2.m9.1234.5678" "$(cat "$f53f" 2>/dev/null)"
  # A slot's flag is reused across every mutant that runs in it, so overwriting
  # a stale one is the normal case, not an edge case.
  arm_flag "$f53f" "s2.m10.1234.9999"
  check "  … arming again replaces the previous token" "s2.m10.1234.9999" "$(cat "$f53f" 2>/dev/null)"
  if [[ -z "$(ls "$TMP"/arm.flag.*.arming 2>/dev/null)" ]]; then
    pass "  … and leaves no half-written temporary behind"
  else
    fail "  … and leaves no half-written temporary behind — $(ls "$TMP"/arm.flag.*.arming 2>/dev/null | tr '\n' ' ')"
  fi
  # And the round trip: what it writes must read back as MINE, or the ownership
  # check and the writer disagree about what a token is.
  if flag_is_mine "$f53f" "s2.m10.1234.9999"; then
    pass "  … and what it wrote reads back as this invocation's own"
  else
    fail "  … and what it wrote reads back as this invocation's own — the writer and falsify_flag_is_mine disagree"
  fi

  # ── THE GUARD ──────────────────────────────────────────────────────────────
  # `printf` is overridden with a shell function, which takes precedence over
  # the builtin, so the token takes two seconds to be produced. Nothing else
  # about the writer changes. Then, one second in, the destination is examined:
  #
  #   rename      the token is being built somewhere else — destination ABSENT
  #   redirection the destination was created first — present, and EMPTY
  #
  # Whole-second sleeps rather than fractions, because this assertion has to
  # mean the same thing on a loaded macOS host as it does in the container.
  f53g="$TMP/arm-slow.flag"
  rm -f "$f53g" "$TMP"/arm-slow.flag.*.arming
  f53_mid="$( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    printf() {                       # slow ONLY the token write, nothing else
      if [[ "${1:-}" == '%s' && "${2:-}" == s9.* ]]; then sleep 2; fi
      builtin printf "$@"
    }
    falsify_arm_flag "$f53g" "s9.m1.4242.777" &
    sleep 1
    if [[ -e "$f53g" ]]; then builtin printf 'PRESENT:%s' "$(cat "$f53g" 2>/dev/null)"
    else                      builtin printf 'ABSENT'; fi
    wait )"
  case "$f53_mid" in
    ABSENT)
      pass "the destination does not exist while the token is still being written" ;;
    PRESENT:)
      fail "the destination does not exist while the token is still being written — it exists and is EMPTY, which is exactly the state a reader calls somebody else's flag (backlog F53)" ;;
    *)
      fail "the destination does not exist while the token is still being written — got '$f53_mid'" ;;
  esac
  # And it must still arrive. An arm that never completes would pass the
  # assertion above for the wrong reason.
  check "  … and the token does arrive once the write completes" "s9.m1.4242.777" "$(cat "$f53g" 2>/dev/null)"
else
  fail "run.sh exposes falsify_arm_flag — the flag is written by a bare redirection, which a reader can catch half-done"
  fail "  … the flag holds exactly the token — no writer to ask"
  fail "  … arming again replaces the previous token — no writer to ask"
  fail "  … and leaves no half-written temporary behind — no writer to ask"
  fail "  … and what it wrote reads back as this invocation's own — no writer to ask"
  fail "the destination does not exist while the token is still being written — no writer to ask"
  fail "  … and the token does arrive once the write completes — no writer to ask"
fi

# ── 12. Selections that must fail loudly rather than verify nothing ───────────
fx_run "$RUN" "$CONF_GREPPED" "$FX" "$TMP/wit-g" --jobs 1
check "a GREPPED-ONLY-only map is refused (exit 2), never silently empty" "2" "$FX_RC"
grep -q 'GREPPED-ONLY' <<< "$FX_ERR" \
  && pass "  … saying the rows were skipped by category" \
  || fail "  … saying the rows were skipped by category: $FX_ERR"

fx_run "$RUN" "$CONF_PARTIAL" "$FX" "$TMP/wit-p" --jobs 1
check "an ACTIVE EXECUTED-PARTIAL row is refused (exit 2)" "2" "$FX_RC"
grep -q 'per-function mutation unit' <<< "$FX_ERR" \
  && pass "  … because whole-file mutation there manufactures survivors" \
  || fail "  … because whole-file mutation there manufactures survivors: $FX_ERR"

fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-x" --jobs 0
check "--jobs 0 is refused (exit 2)" "2" "$FX_RC"
fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-x" --nonsense
check "an unknown option is refused (exit 2)" "2" "$FX_RC"

# ── 13. The REAL targets.conf is what an unfiltered run would read ────────────
# No mutants are run here: --target with a name no active row carries must fail
# before any oracle does, against the real map.
out="$(bash "$RUN" --target no-such-target-file.sh 2>&1)"; rc=$?
check "--target with no matching active row is refused (exit 2)" "2" "$rc"
grep -q 'matches no active row' <<< "$out" \
  && pass "  … naming the filter that matched nothing" \
  || fail "  … naming the filter that matched nothing: $out"
n_active="$(bash "$TESTS_DIR/falsify/derive-targets.sh" --rows "$TESTS_DIR/falsify/targets.conf" \
            | awk -F'|' '$1 == "ACTIVE" && $4 == "EXECUTED-WHOLE"' | grep -c .)"
if [[ "$n_active" -ge 1 ]]; then
  pass "the real map still has $n_active active EXECUTED-WHOLE target(s) for the tier to run"
else
  fail "the real map still has active EXECUTED-WHOLE targets — the tier would mutate nothing"
fi

# ── 14. A COLLAPSED ORACLE IS UNPROVEN, NEVER KILLED ─────────────────────────
# The oracle reports that it could not set ITSELF up. Everything it printed
# afterwards — including a real FAIL: line and a non-zero exit, both present in
# this fixture — is evidence about the machine, not about the mutation. Scoring
# that as a kill is how a real GAP goes invisible: the mutant leaves the
# survivor set, check-ledger.sh stops demanding an entry, and the hole is
# reported as covered. Measured in the field before it was fixed (backlog F31).
#
# Demonstrated failing by deleting the falsify_has_scaffold_failure branch from
# falsify_verdict: the verdict becomes KILLED and both assertions below fire.
fx_run "$RUN" "$CONF_SCAFFOLD" "$FX" "$TMP/wit-scaffold"
check "a collapsed oracle is UNPROVEN, not KILLED" \
  "UNPROVEN" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
fx_sig="$(fx_signal "$FX_OUT" "$KILLABLE")"
case "$fx_sig" in
  *scaffold*) pass "  … and the signal names the scaffold ($fx_sig)" ;;
  *)          fail "  … and the signal names the scaffold (got '$fx_sig')" ;;
esac

# THE OTHER HALF, in the driver rather than the tier: a human running the suite
# must be told the workspace collapsed, not handed "FAIL (exit 1)" over the top
# of it. That is what sent this investigation after a defect in the code under
# test for two days. The driver under test is the REAL tests/run-all.sh, copied
# into the fixture above.
#
# Demonstrated failing by removing the SCAFFOLD-FAILED branch from run-all.sh:
# the line becomes "FAIL  (exit 1)" and the marker is never surfaced, because
# the branch below it greps only for FAIL:/ERROR lines.
drv="$( cd "$FX" && bash tests/run-all.sh fx-collapse 2>&1 )"
grep -q 'could not set itself up' <<< "$drv" \
  && pass "the driver names a collapsed workspace as such" \
  || fail "the driver names a collapsed workspace as such (got: $(grep -E '^ +FAIL' <<< "$drv" | head -1))"
grep -q 'SCAFFOLD-FAILED: mktemp -d' <<< "$drv" \
  && pass "  … and surfaces the marker line itself" \
  || fail "  … and surfaces the marker line itself"

# ── 14b. AN ORACLE KILLED BY A SIGNAL IS UNPROVEN, NEVER KILLED ──────────────
# The third channel through which "the oracle never observed anything" was
# being scored as "the oracle observed the mutation": the process was SHOT.
# `wait` reports 128+N and falsify_exit_kills read that as simply non-zero, so
# the mutant left the survivor set, check-ledger.sh stopped demanding an entry,
# and the hole was reported as covered — the same inversion as the timeout
# (case 11) and the collapsed workspace (case 14), which is why it belongs
# beside them.
#
# NOT hypothetical: the tier runs $(nproc) workers each running a whole
# run-all.sh, and the container this was found in reports `oom_kill 7` against
# an 8 GiB `memory.max`. The kernel picks a worker's driver and SIGKILLs it.
#
# The PREMISE first, by effect rather than by reading the source: 128 is only a
# sound boundary because the real driver never returns a failure COUNT. Run it
# all three reachable ways and record what it actually returns.
( cd "$FX" && bash tests/run-all.sh fx-a >/dev/null 2>&1 ); drv_pass=$?
( cd "$FX" && bash tests/run-all.sh fx-collapse >/dev/null 2>&1 ); drv_fail=$?
( cd "$FX" && bash tests/run-all.sh fx-silent >/dev/null 2>&1 ); drv_silent=$?
( cd "$FX" && bash tests/run-all.sh no-such-test-zzz >/dev/null 2>&1 ); drv_none=$?
check "premise: the driver returns 0 when everything passes" "0" "$drv_pass"
check "premise: the driver returns 1 for a failing test, not a failure count" "1" "$drv_fail"
check "premise: the driver returns 1 for a test that asserted nothing" "1" "$drv_silent"
check "premise: the driver returns 2 when its filter selects nothing" "2" "$drv_none"

fx_run "$RUN" "$CONF_SIGNAL" "$FX" "$TMP/wit-signal" --jobs 1
check "an oracle killed by a signal is UNPROVEN, not KILLED" \
  "UNPROVEN" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
fx_sig="$(fx_signal "$FX_OUT" "$KILLABLE")"
case "$fx_sig" in
  *signal*) pass "  … and the signal field says so ($fx_sig)" ;;
  *)        fail "  … and the signal field says so (got '$fx_sig')" ;;
esac
# `exit` would be the OLD, wrong reading of 137 — name it, so a regression that
# reinstates it cannot hide behind a signal field that merely contains
# something.
case "$fx_sig" in
  *exit*) fail "  … and does NOT claim the driver exited non-zero of its own accord (got '$fx_sig')" ;;
  *)      pass "  … and does not claim the driver exited non-zero of its own accord" ;;
esac
# A signal death is not a timeout either, and conflating them would send a
# reader to raise --timeout for a memory problem.
case "$fx_sig" in
  *timeout*) fail "  … and is not reported as a timeout (got '$fx_sig')" ;;
  *)         pass "  … and is not reported as a timeout" ;;
esac
# And the runner says so where a human will see it, with the lever named. A
# verdict a reader cannot act on sends them classifying an environment failure
# as an assertion gap in the ledger.
grep -q 'ORACLE KILLED BY A SIGNAL (UNPROVEN' <<< "$FX_ERR" \
  && pass "  … and the runner warns on stderr, naming --jobs and the memory cap" \
  || fail "  … and the runner warns on stderr, naming --jobs and the memory cap (stderr: $FX_ERR)"

# ── 14c. --jobs auto READS THE CGROUP QUOTA, WHICH nproc DOES NOT ────────────
# `nproc` reads the affinity MASK. `docker run --cpus=N` — how this repo's own
# sandbox.sh starts every container, defaulting to 1.0 — sets a CFS QUOTA and
# leaves the mask alone, so nproc over-reports inside one and `--jobs $(nproc)`
# oversubscribes. That lands on the per-mutant clock --timeout is measured
# against, and a mutant that trips it is scored UNPROVEN — which is not owed a
# ledger entry, so a mutant that WAS killed leaves the measured set in silence.
#
# Driven against PLANTED cgroup files rather than this machine's: a test that
# only asserted "the budget equals what this host happens to have" would pass
# identically on a host with no quota at all, which is most of them.
cg() {   # <name> <layout> <content…> → a FALSIFY_CGROUP root
  local root="$TMP/cg-$1"; rm -rf "$root"; mkdir -p "$root"
  case "$2" in
    v2) printf '%s\n' "$3" > "$root/cpu.max" ;;
    v1) mkdir -p "$root/cpu"
        printf '%s\n' "$3" > "$root/cpu/cpu.cfs_quota_us"
        printf '%s\n' "$4" > "$root/cpu/cpu.cfs_period_us" ;;
    none) : ;;
  esac
  printf '%s' "$root"
}
# Split deliberately: what was READ from the file is a machine-independent
# fact, while the budget depends on the machine. Asserting "quota 3 -> budget 3"
# hard-codes a host with at least 3 CPUs — which is how this block first shipped,
# and a 2-CPU CI runner caught it. And a helper that recomputed min(quota, host)
# to build the expectation would just be the implementation written twice,
# agreeing with itself however wrong it was.
quota_of() {   # <cgroup root> → what fr_quota_cpus reads, or "" for no quota
  ( set +u; export FALSIFY_CGROUP="$1"
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    fr_quota_cpus )
}
budget_of() {  # <cgroup root> → the worker count run.sh would use
  ( set +u; export FALSIFY_CGROUP="$1"
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    fr_cpu_budget )
}
host_cpus="$( ( set +u
                # shellcheck source=/dev/null
                source "$RUN" >/dev/null 2>&1; fr_host_cpus ) )"
[[ "$host_cpus" =~ ^[1-9][0-9]*$ ]] \
  && pass "fr_host_cpus reports a positive integer ($host_cpus)" \
  || fail "fr_host_cpus reported '$host_cpus'"

# What each layout is READ as — the same answer on every machine.
# ── a partial `cp -a` must not nest the tree ─────────────────────────────────
# `cp -R src dst` means "copy src TO dst" when dst is absent and "copy src INSIDE
# dst" when it exists. So a `cp -a` that creates the destination and THEN fails
# turns the fallback into a nested tree: part of the files at the top level, the
# rest under dst/<basename>/, and whatever cp -a never reached missing entirely.
#
# macOS's cp -a returns non-zero when it cannot copy extended attributes, having
# already copied contents, and a 2026-08-27 host run produced exactly that — three
# oracles red on scratch trees, each reported as a defect in the code it tests,
# the loudest being `no *.yml files found under .../w0/.github/workflows`.
#
# Driven through the REAL fr_seed_slot with a `cp` that copies part of the tree
# and exits 1, because the bug lives in the recovery path and a reimplementation
# here would just be the same mistake written twice.
seed_cache="$TMP/seedsrc"; mkdir -p "$seed_cache/.github/workflows" "$seed_cache/a"
printf 'x\n' > "$seed_cache/a/file1"
printf 'y\n' > "$seed_cache/.github/workflows/nightly.yml"
seed_fakebin="$TMP/seedbin"; mkdir -p "$seed_fakebin"
cat > "$seed_fakebin/cp" <<'FAKECP'
#!/usr/bin/env bash
# -a: copy only part of the tree, then fail — the shape a macOS xattr error takes.
if [ "$1" = "-a" ]; then
  mkdir -p "$3/a"; command cp "$2/a/file1" "$3/a/" 2>/dev/null; exit 1
fi
exec /bin/cp "$@"
FAKECP
chmod +x "$seed_fakebin/cp"
seed_out="$( set +u
  export PATH="$seed_fakebin:$PATH"
  # shellcheck source=/dev/null
  source "$RUN" >/dev/null 2>&1
  FR_WORK="$TMP/seedwork"
  FR_OUT="$TMP/seedout"
  # ONE assignment under the directive, on its own line. A `disable` applies to
  # the NEXT COMMAND, so above `A=1; B=2; C=3` it covers A only — which is why
  # the two directives at the top of this file each sit over a single assignment.
  # shellcheck disable=SC2034  # read by fr_seed_slot, sourced from $RUN above
  FR_CACHE="$seed_cache"
  mkdir -p "$FR_WORK" "$FR_OUT"
  fr_seed_slot 0 >/dev/null 2>&1
  find "$FR_WORK/w0" -type f 2>/dev/null | sed "s|^$FR_WORK/w0/||" | sort | tr '\n' ' ' )"
check "a partial cp -a does not nest the seeded tree" \
  ".github/workflows/nightly.yml a/file1 " "$seed_out"

# ── a seeded tree that is NOT the repo, caught at the seed ────────────────────
# The nesting fix above recovers when `cp -a` FAILS. It does nothing when a copy
# exits 0 having produced an incomplete tree, and that is the case that reached a
# 2026-08-27 host run: two oracles red on the PRISTINE tree, both targets skipped
# with every one of their mutants, and the report naming the code the oracles
# test. The tier had the evidence and discarded it — fr_seed_slot recorded the
# damaged tree's `git status` as the REFERENCE fingerprint, so the damage became
# the baseline; and the only post-seed guard asked whether the directory EXISTS,
# which a partial copy always satisfies.
#
# Driven through the REAL fr_seed_slot against a REAL git tree, because the check
# is a git-status comparison and a fixture without git could not exercise it.
sf_repo="$TMP/seedfid"; mkdir -p "$sf_repo/.github/workflows" "$sf_repo/sub"
printf 'a\n' > "$sf_repo/.github/workflows/nightly.yml"
printf 'b\n' > "$sf_repo/sub/keep.txt"
printf '#!/bin/sh\ntrue\n' > "$sf_repo/exec.sh"; chmod 755 "$sf_repo/exec.sh"
( cd "$sf_repo" && git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1
  git add -A && git -c user.email=t@example -c user.name=t commit -qm fixture ) >/dev/null 2>&1
if ( cd "$sf_repo" && git rev-parse HEAD >/dev/null 2>&1 ); then
  pass "scaffold: seed-fidelity fixture repo built"
else
  fail "scaffold: seed-fidelity fixture repo built — the assertions below would be vacuous"
fi

# A cp that copies everything and then removes the workflows, exiting 0: the
# damage without the failure, which is what the exit-code guard cannot see.
sf_bin="$TMP/seedfidbin"; mkdir -p "$sf_bin"
cat > "$sf_bin/cp" <<'SFCP'
#!/usr/bin/env bash
if [ "$1" = "-a" ] && [ -d "$2/.github" ]; then
  /bin/cp -a "$2" "$3"; rm -f "$3"/.github/workflows/*.yml; exit 0
fi
exec /bin/cp "$@"
SFCP
chmod +x "$sf_bin/cp"

sf_run() {   # <PATH-prefix or ""> → "<rc>|<stderr>"
  ( set +u
    [[ -n "$1" ]] && export PATH="$1:$PATH"
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    FR_WORK="$TMP/sfwork.$2"; FR_OUT="$TMP/sfout.$2"
    # shellcheck disable=SC2034  # read by fr_seed_slot, sourced from $RUN above
    FR_CACHE="$TMP/sfcache.$2"
    mkdir -p "$FR_WORK" "$FR_OUT"
    falsify_seed_tree "$sf_repo" "$FR_CACHE" >/dev/null 2>&1 || { printf 'seed-failed|'; exit 0; }
    err="$(fr_seed_slot 0 2>&1 >/dev/null)"; rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$err" | tr '\n' ' ')" )
}

sf_clean="$(sf_run "" clean)"
check "an undamaged seed is accepted" "0|" "$sf_clean"

sf_damaged="$(sf_run "$sf_bin" dmg)"
case "$sf_damaged" in
  0\|*)  fail "a seed missing tracked files is REJECTED — accepted it silently (the shape that cost a host run)" ;;
  seed*) fail "a seed missing tracked files is REJECTED — the cache seed itself failed, so nothing was exercised" ;;
  *)     pass "a seed missing tracked files is REJECTED" ;;
esac
case "$sf_damaged" in
  *nightly.yml*) pass "  … and the message NAMES the file that went missing" ;;
  *) fail "  … and the message NAMES the file that went missing — got: $sf_damaged" ;;
esac

# Mode drift, repaired rather than merely detected. `cp -Pp` does not always
# preserve modes (measured on a virtiofs mount: the one 0600 file in this repo
# arrives 0755), and tests/test-verify-lint-scope.sh asserts an EMPTY porcelain,
# so an unrepaired exec bit reddens an oracle on its own.
sf_md="$TMP/sfmode"; mkdir -p "$sf_md"
cp -R "$sf_repo/." "$sf_md/" >/dev/null 2>&1
chmod 644 "$sf_md/exec.sh"
sf_mode_before="$( cd "$sf_md" && git status --porcelain -uno | tr -d ' \n' )"
sf_mode_after="$( set +u
  # shellcheck source=/dev/null
  source "$RUN" >/dev/null 2>&1
  _fr_match_modes "$sf_repo" "$sf_md" >/dev/null 2>&1
  cd "$sf_md" && git status --porcelain -uno | tr -d ' \n' )"
if [[ -n "$sf_mode_before" ]]; then
  pass "scaffold: a stripped exec bit does read as drift ($sf_mode_before)"
else
  fail "scaffold: a stripped exec bit does read as drift — the repair below would be vacuous"
fi
check "mode drift is repaired, not just detected" "" "$sf_mode_after"

# ── the fork-cost cap, exercised ON LINUX ────────────────────────────────────
# A platform conditional whose macOS branch nothing runs is the untested claim
# this repo keeps purging — and it is not hypothetical here: the first version of
# this cap lived in verify-on-host.sh, made the DEFAULT platform-dependent, and
# broke test-verify-exit-code.sh on macOS ONLY, where no CI job could see it.
#
# `uname` is faked rather than the platform sniffed, so both branches run on
# every machine. The cap must also be INERT off Darwin: a narrowing probe that
# fires everywhere would silently serialise Linux CI.
# BOTH BRANCHES ARE FAKED, and the off-Darwin one is the whole reason. Faking
# only Darwin leaves the negative arm reading the REAL machine, so
# "the cap is empty off Darwin" is an assertion about the host rather than about
# the code -- green on the Linux that happens to run CI, red on every Mac. That
# is this repo's most-repeated defect (the symlinked-TMPDIR class), and it cost
# this very block: a 2026-08-28 host run failed here with `expected '', got '1'`
# on a machine where the claim was never in question.
fake_uname() {   # <dir> <kernel name> -> a uname on PATH reporting that kernel
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo %s; exit 0; }\nexec /usr/bin/uname "$@"\n' \
    "$2" > "$1/uname"
  chmod +x "$1/uname"
}
fake_uname_dir="$TMP/fake-uname"          ; fake_uname "$fake_uname_dir" Darwin
fake_uname_linux="$TMP/fake-uname-linux"  ; fake_uname "$fake_uname_linux" Linux
cap_under() {  # <PATH-prefix> → what fr_fork_cost_cap returns there
  ( set +u; export PATH="$1:$PATH"
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    fr_fork_cost_cap )
}
# Each fake's own premise, checked before anything is concluded from it.
check "scaffold: the fake uname reports Darwin" "Darwin" "$(PATH="$fake_uname_dir:$PATH" uname -s)"
check "scaffold: the other fake uname reports Linux" "Linux" "$(PATH="$fake_uname_linux:$PATH" uname -s)"
check "the fork-cost cap is 1 on Darwin" "1" "$(cap_under "$fake_uname_dir")"
check "the fork-cost cap is EMPTY off Darwin, so it narrows nothing" "" "$(cap_under "$fake_uname_linux")"
# And it reaches the budget: a cap of 1 binds on any machine, so this pins the
# narrowing without assuming a host CPU count.
check "the Darwin cap narrows fr_cpu_budget to 1" "1" \
  "$( ( set +u; export PATH="$fake_uname_dir:$PATH"
        # shellcheck source=/dev/null
        source "$RUN" >/dev/null 2>&1; fr_cpu_budget ) )"

check "cgroup v2: a 2-CPU quota is read as 2" "2" "$(quota_of "$(cg v2quota v2 '200000 100000')")"
check "cgroup v2: a fractional quota floors to 1, not to 0" "1" "$(quota_of "$(cg v2half v2 '50000 100000')")"
check "cgroup v2: \`max\` is NO quota" "" "$(quota_of "$(cg v2max v2 'max 100000')")"
check "cgroup v1: quota/period is read the same way" "3" "$(quota_of "$(cg v1quota v1 '300000' '100000')")"
check "cgroup v1: -1 is unlimited, not a quota of zero" "" "$(quota_of "$(cg v1unl v1 '-1' '100000')")"
check "no cgroup files at all: no quota is INVENTED" "" "$(quota_of "$(cg nocg none)")"
check "an unparseable quota is treated as no quota, never as a limit" "" "$(quota_of "$(cg junk v2 'banana 100000')")"

# And what it becomes. A quota of 1 binds on ANY machine, so this pins the
# capping without assuming anything about the host; the other two pin the
# directions that must NOT cap.
check "a 1-CPU quota caps the budget at 1, on any machine" "1" "$(budget_of "$(cg v2one v2 '100000 100000')")"
# NEITHER OF THESE IS `== fr_host_cpus` ANY MORE, and the reason is a regression
# this pair caught the hard way. F59 capped the budget at the PERFORMANCE-core
# count on a machine whose cores are not all equal, so on Apple Silicon the OS
# reports 18 and the budget is 6 — and both assertions went red there while
# staying green on Linux, which has no performance levels. Verified on Linux
# only, the change looked clean; it had in fact been red on main in both repos.
#
# Worse than a stale number: the second assertion is about QUOTA handling, and
# once it fails on the baseline it can no longer be evaluated for the property
# it was written to check. A stale expectation had disabled a distinct guard.
#
# So the topology belongs where it can be FIXED rather than read — §17 stubs
# sysctl and asserts the P-core cap on numbers that are the same everywhere.
# What these two are for, and what is machine-independent, is the quota.
unquota_budget="$(budget_of "$(cg v2max v2 'max 100000')")"
if [[ "$unquota_budget" =~ ^[1-9][0-9]*$ ]] && (( unquota_budget <= host_cpus )); then
  pass "no quota: the budget is a real worker count, never above what the OS reports ($unquota_budget of $host_cpus)"
else
  fail "no quota: the budget is a real worker count, never above what the OS reports (got '$unquota_budget', OS reports $host_cpus)"
fi
# The property, stated as one: a quota bigger than the machine must change
# NOTHING. Comparing the two budgets rather than either against a constant keeps
# this true on every machine and still fails an implementation that hands out
# the quota — which would answer 999 here.
check "a quota larger than the machine does not inflate the budget" \
  "$unquota_budget" "$(budget_of "$(cg v2big v2 '99900000 100000')")"

# End to end, with a 1-CPU quota so the expectation holds on any runner: the
# runner resolves it and SAYS BOTH NUMBERS. "jobs=1" alone leaves a reader
# unable to tell a quota from a small machine, and that gap is the finding.
FALSIFY_CGROUP="$(cg v2run v2 '100000 100000')" fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-auto" --jobs auto
grep -qE 'jobs=1\|' <<< "$FX_OUT" \
  && pass "--jobs auto resolves to the quota, and the RUN record carries it" \
  || fail "--jobs auto did not resolve to 1 (RUN record: $(grep -m1 '^RUN|' <<< "$FX_OUT"))"
grep -q "the cgroup quota allows 1" <<< "$FX_ERR" \
  && pass "  … and the note names the quota alongside what the OS reports" \
  || fail "  … and the note names the quota alongside what the OS reports (stderr: $FX_ERR)"

# A quota EQUAL to the machine is still a quota, and the note must say so. This
# is the case a 2-CPU runner produced against a 2-CPU fixture, where the note
# claimed "no cgroup CPU quota in effect" — the opposite of the truth, and
# invisible on any host with more CPUs than the fixture.
FALSIFY_CGROUP="$(cg v2eq v2 "$((host_cpus * 100000)) 100000")" fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-eq" --jobs auto
grep -q "the cgroup quota allows $host_cpus" <<< "$FX_ERR" \
  && pass "a quota equal to the machine is still reported as a quota" \
  || fail "a quota equal to the machine was reported as no quota at all (stderr: $FX_ERR)"

# ── 14d. --max-unproven-pct BOUNDS HOW MUCH A RUN MAY LEAVE UNMEASURED ────────
# An UNPROVEN mutant is deliberately NOT owed a ledger entry (backlog F27: the
# timeout is machine state, and a ratchet that cannot be satisfied everywhere at
# once is not a ratchet). The price is that an unbounded number of mutants can
# drop out of the measured set with nothing failing — a run reporting 210 killed
# where the reference reports 223 scores exactly as green. Measured, on two
# machines running the same commit on the same day.
#
# The slow fixture puts its one mutant at 100% unproven, so the boundary is
# exact rather than approximate.
#
# THE CLOCK IS 5s, NOT 1s, AND THE ONE SECOND WAS A FLAKE THIS SUITE SHIPPED.
# The mutant `sleep 300`s, so every value from about 2 to 250 trips it equally
# -- the clock is not what makes this case work. What one second DID do was
# leave the BASELINE no headroom: it is sub-second unloaded, and on a loaded
# macOS host (load 5.5, a full verify-on-host.sh plus a second agent) it went
# over, which times out the baseline, skips the target, and fails the run for a
# reason having nothing to do with the budget under test. Measured 2026-08-29:
# `control: a run AT the budget passes` reported rc=1 in Phase 5 on this host
# while the SAME assertion passed 205/205 in the bash-floor container minutes
# later, on the same commit. Five seconds is 5x the headroom for a fixture that
# needs none of it, and still 60x below the sleep it has to catch.
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp1" --jobs 1 --timeout 5 --max-unproven-pct 50
[[ "$FX_RC" -ne 0 ]] \
  && pass "a run over the unproven budget FAILS, however green its verdicts look" \
  || fail "a run at 100% unproven passed a --max-unproven-pct 50 budget (rc=$FX_RC)"
grep -q 'over the --max-unproven-pct 50 budget' <<< "$FX_ERR" \
  && pass "  … and the error names the budget it broke" \
  || fail "  … and the error names the budget it broke (stderr: $FX_ERR)"
grep -q 'measured materially less than it appears to' <<< "$FX_ERR" \
  && pass "  … and says what that MEANS, not just that a number was exceeded" \
  || fail "  … and says what that means (stderr: $FX_ERR)"
# The control, and it matters: without it every assertion above is satisfied by
# a runner that fails on --max-unproven-pct unconditionally.
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp2" --jobs 1 --timeout 5 --max-unproven-pct 100
check "control: a run AT the budget passes (100% against a budget of 100)" "0" "$FX_RC"
# And absent, the option changes nothing — this is opt-in because a developer
# host legitimately times out.
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp3" --jobs 1 --timeout 1
check "control: with no budget given, an unproven run still exits 0" "0" "$FX_RC"
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp4" --jobs 1 --timeout 5 --max-unproven-pct banana
check "a non-numeric budget is refused (exit 2), not silently ignored" "2" "$FX_RC"

# ── 14e. A CONTROL RUN CATCHES AN ORACLE THAT GOES RED PARTWAY THROUGH ───────
# `run.sh` runs each target's oracle on the pristine tree and requires PASS —
# ONCE, at the start, with no workers running. That establishes the oracle is
# green on a QUIET machine, which is not the condition the mutants are measured
# under, and the tier itself is what loads the machine (backlog F30, F32).
#
# The failure that matters is not a slow oracle — F12 closed that — but a
# FAILING-because-loaded one. Measured 2026-08-17: a contaminated oracle failed
# with signal `exit+failline` in 2.5 seconds, no timeout involved. The obvious
# remedy, "re-verify any kill that also timed out", would have missed it
# completely.
#
# A false KILL is worse than a missed one: the mutant never reaches the survivor
# set, check-ledger.sh never demands an entry, and the gap becomes INVISIBLE.
#
# THE FIXTURE reproduces the shape deterministically instead of racing for it.
# test-fx-flaky.sh counts its own invocations in a file outside every worker
# tree and starts failing from the Nth. At --jobs 1 the order is fixed —
# baseline, m1, m2, control, m3, m4 — so FX_FLAKY_FROM=4 makes the BASELINE
# pass and the CONTROL fail, which is precisely the case the per-target baseline
# cannot see.
CONF_FLAKY="$(conf flaky 'fixture-lib.sh|EXECUTED-WHOLE|test-fx-flaky.sh')"

export FX_FLAKY_COUNT="$TMP/flaky.count"; : > "$FX_FLAKY_COUNT"
export FX_FLAKY_FROM=4
fx_run "$RUN" "$CONF_FLAKY" "$FX" "$TMP/wit-flaky" --jobs 1 --timeout 120 --controls 1
check "an oracle that goes red mid-target is caught by a CONTROL run" "1" \
  "$(grep -c '^CONTROL|FAIL|' <<< "$FX_OUT")"
check "  … and the summary counts it: one control, one failure" "1" \
  "$(grep -c '^CONTROLS|1|1$' <<< "$FX_OUT")"
check "  … and the run FAILS rather than reporting a clean corpus" "1" "$FX_RC"
grep -q 'CONTROL FAILED' <<< "$FX_ERR" \
  && pass "  … naming it at the moment it happened" \
  || fail "  … naming it at the moment it happened: $FX_ERR"
grep -q 'may have been killed by the machine rather than by the damage' <<< "$FX_ERR" \
  && pass "  … and saying what it means for the kill count" \
  || fail "  … and saying what it means for the kill count: $FX_ERR"
# AND WHAT ACTUALLY WENT RED. The first real macOS run to trip a control
# (2026-08-21) reported `exit+failline` on tests/bash-dialect-lint.sh and
# nothing about WHICH assertion failed — the one fact that distinguishes a
# load-sensitive oracle from a defect in it. The oracle's own output lives in a
# per-SLOT log that the next mutant overwrites and the scratch tree takes with
# it, so it has to be carried out on the record stream or it is gone.
check "  … and carrying the oracle's own FAIL: line out with it" "1" \
  "$(grep -c '^NOTE|control-output|.*the machine, not the mutation' <<< "$FX_OUT")"
# AND THE EVIDENCE UNDER IT. `check` prints the assertion name on the FAIL:
# line and the expected/got values INDENTED beneath. Capturing only the FAIL:
# line takes the name and throws away the reason — measured on the first host
# run that produced a diagnosis: five of six lines were bare names.
check "  … together with the indented evidence beneath it" "1" \
  "$(grep -c '^NOTE|control-output|.*expected-vs-got: the evidence' <<< "$FX_OUT")"
grep -q 'control output:.*the machine, not the mutation' <<< "$FX_ERR" \
  && pass "  … on stderr too, beside the error it explains" \
  || fail "  … on stderr too, beside the error it explains: $FX_ERR"
# THE POINT, stated as an assertion. The mutants dispatched AFTER the oracle
# went red are scored KILLED, and without the control the run would have
# reported that as coverage and exited 0.
[[ "$(grep -c '^MUTANT|KILLED|' <<< "$FX_OUT")" -gt 0 ]] \
  && pass "  … while the mutants after it were indeed scored KILLED, which is the harm" \
  || fail "  … while the mutants after it were indeed scored KILLED — the fixture did not reproduce the false-kill shape"

# THE NEGATIVE CONTROL. A healthy oracle must report controls that PASSED, and
# must not fail the run. Without this, a build that failed every control would
# pass every assertion above.
: > "$FX_FLAKY_COUNT"; export FX_FLAKY_FROM=9999
fx_run "$RUN" "$CONF_FLAKY" "$FX" "$TMP/wit-flaky2" --jobs 1 --timeout 120 --controls 1
check "control: a healthy oracle reports its control passing" "1" \
  "$(grep -c '^CONTROLS|1|0$' <<< "$FX_OUT")"
check "  … and the run exits 0" "0" "$FX_RC"
check "  … having emitted no CONTROL|FAIL line" "0" \
  "$(grep -c '^CONTROL|FAIL|' <<< "$FX_OUT")"
unset FX_FLAKY_FROM FX_FLAKY_COUNT

# ── a collapse that ALSO asserted is not "the environment" ────────────────────
# FALSIFY_SIGNAL is built additively, so `failline+scaffold` is an ordinary
# value rather than a contradiction, and a target's oracle field is a SET run as
# one invocation into one log. One member red plus one member collapsed
# therefore produces both markers -- and reading only `scaffold` there retries a
# broken tree FR_BASELINE_ATTEMPTS times and then blames the machine for it.
# The rule is falsify_verdict's own, one channel over: an assertion that WAS
# observed failing still wins.
export FX_SCAF_COUNT="$TMP/scaffail.count"; : > "$FX_SCAF_COUNT"
FALSIFY_BASELINE_ATTEMPTS=3 fx_run "$RUN" "$CONF_SCAFFAIL" "$FX" "$TMP/wit-scaffail" --jobs 1 --controls 1
check "a collapse that ALSO printed FAIL: is NOT retried" "1" "$(cat "$FX_SCAF_COUNT")"
check "  … and is recorded as a red oracle, not as a scaffold skip" "1" \
  "$(grep -c '^SKIPPED|fixture-lib.sh|test-fx-scaffold-and-fail.sh|[0-9]*|baseline-not-green$' <<< "$FX_OUT")"
grep -q 'is not green on the PRISTINE tree' <<< "$FX_ERR" \
  && pass "  … sending the reader at the oracle, which is where the FAIL: line points" \
  || fail "  … sending the reader at the oracle: $FX_ERR"
! grep -q 'could not SET ITSELF UP' <<< "$FX_ERR" \
  && pass "  … and never claiming the environment over the top of an assertion" \
  || fail "  … and never claiming the environment over the top of an assertion: $FX_ERR"
unset FX_SCAF_COUNT

# ── a baseline that could not SET ITSELF UP is the environment, not a verdict ──
# `scaffold` is this runner's word for "the oracle never ran", and falsify_verdict
# scores a scaffold-failed MUTANT UNPROVEN for exactly that reason. The baseline
# gate read the same event as "the oracle is not green on the PRISTINE tree" — a
# claim about the oracle's CODE — and retired the whole target on it.
#
# What that cost, measured: a 2026-08-28 macOS host run came back 508 killed /
# 11 survived / 0 unproven with all 30 controls GREEN, and still exited
# non-zero. One `chmod +x` inside test-integration-shim.sh's scaffold returned
# 137 during the ONE baseline invocation that oracle gets, which retired all 29
# mutants of tests/integration/docker-shim.sh — and because the corpus exits
# non-zero, the survivor ratchet Phase 6 exists to pair with it never ran.
# Ninety-seven minutes of measurement discarded by a single transient exec.
export FX_SCAF_COUNT="$TMP/scaf.count"
: > "$FX_SCAF_COUNT"; export FX_SCAF_UNTIL=1
FALSIFY_BASELINE_ATTEMPTS=3 fx_run "$RUN" "$CONF_SCAFFLAKY" "$FX" "$TMP/wit-scaf1" --jobs 1 --controls 1
check "a baseline that collapses ONCE does not retire the target" "0" \
  "$(grep -c '^SKIPPED|' <<< "$FX_OUT")"
check "  … the target is genuinely measured, not merely un-skipped" "1" \
  "$( [[ "$(grep -c '^MUTANT|' <<< "$FX_OUT")" -gt 0 ]] && printf 1 || printf 0 )"
check "  … and the run exits 0" "0" "$FX_RC"
# NAMED EVEN WHEN THE RETRY WORKS. A machine quietly getting worse with nothing
# saying so is the reason this is bounded rather than looped until green.
grep -q 'could not SET ITSELF UP (attempt 1 of 3' <<< "$FX_ERR" \
  && pass "  … while still reporting the collapse it absorbed" \
  || fail "  … while still reporting the collapse it absorbed: $FX_ERR"
grep -q 'the environment, not a verdict' <<< "$FX_ERR" \
  && pass "  … and saying which of the two it is" \
  || fail "  … and saying which of the two it is: $FX_ERR"

# THE RETRY IS BOUNDED, and a persistent collapse still retires the target —
# nothing can be measured through an oracle that cannot start. What changes is
# that it must be PERSISTENT, and that it is then named for what it is.
: > "$FX_SCAF_COUNT"; export FX_SCAF_UNTIL=9999
FALSIFY_BASELINE_ATTEMPTS=3 fx_run "$RUN" "$CONF_SCAFFLAKY" "$FX" "$TMP/wit-scaf2" --jobs 1 --controls 1
check "a baseline that ALWAYS collapses still retires the target" "1" \
  "$(grep -c '^SKIPPED|' <<< "$FX_OUT")"
check "  … and the run FAILS rather than reporting a clean corpus" "1" "$FX_RC"
# THE BOUND, OBSERVED. Without this the loop could be running once, or forever,
# and every other assertion here would read the same.
check "  … having tried exactly FALSIFY_BASELINE_ATTEMPTS times" "3" "$(cat "$FX_SCAF_COUNT")"
# A DIFFERENT REASON IN THE RECORD, because stderr is what a summary reader
# filters out and the record is then the only place the two can be told apart.
check "  … recording it as a SCAFFOLD skip, not as a red oracle" "1" \
  "$(grep -c '^SKIPPED|fixture-lib.sh|test-fx-scafflaky.sh|[0-9]*|baseline-scaffold$' <<< "$FX_OUT")"
grep -q 'could not SET ITSELF UP on the PRISTINE tree' <<< "$FX_ERR" \
  && pass "  … and sending the reader at the machine rather than at the oracle" \
  || fail "  … and sending the reader at the machine rather than at the oracle: $FX_ERR"
unset FX_SCAF_UNTIL FX_SCAF_COUNT

# THE NEGATIVE CONTROL, and the one that keeps the retry SCOPED. An oracle that
# goes red with a FAIL: line IS a statement about the code, and re-running it
# would only spend the clock before reaching the same conclusion. The counter is
# the assertion: one invocation, not three.
export FX_FLAKY_COUNT="$TMP/flaky.count"; : > "$FX_FLAKY_COUNT"; export FX_FLAKY_FROM=1
FALSIFY_BASELINE_ATTEMPTS=3 fx_run "$RUN" "$CONF_FLAKY" "$FX" "$TMP/wit-scaf3" --jobs 1 --controls 1
check "a baseline that goes RED is taken at its word on the first attempt" "1" \
  "$(cat "$FX_FLAKY_COUNT")"
check "  … and its target is retired as before" "1" \
  "$(grep -c '^SKIPPED|fixture-lib.sh|test-fx-flaky.sh|[0-9]*|baseline-not-green$' <<< "$FX_OUT")"
grep -q 'is not green on the PRISTINE tree' <<< "$FX_ERR" \
  && pass "  … still named as a red oracle, not as an environment failure" \
  || fail "  … still named as a red oracle, not as an environment failure: $FX_ERR"
unset FX_FLAKY_FROM FX_FLAKY_COUNT

# --controls 0 disables them, and SAYS SO with a zero total rather than by
# omitting the record — "no controls ran" and "controls ran and passed" are
# different claims and must not read the same.
fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-noctl" --jobs 1 --controls 0
check "--controls 0 runs none, and still emits the record" "1" \
  "$(grep -c '^CONTROLS|0|0$' <<< "$FX_OUT")"
fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-badctl" --jobs 1 --controls banana
check "a non-numeric --controls is refused (exit 2)" "2" "$FX_RC"
grep -q 'must be a non-negative integer' <<< "$FX_ERR" \
  && pass "  … saying what it expected" \
  || fail "  … saying what it expected: $FX_ERR"

# ── 15. AN ORACLE FIELD NAMING SEVERAL TESTS RUNS ALL OF THEM ────────────────
# The row's oracle field is a SET, and a runner that honoured only the first
# name would report every mutant the later members catch as a SURVIVOR. That is
# not hypothetical: it is what the tier did before the set existed, and eight
# real kills of tests/lib-verify-repo.sh sat in the survivor ledger because of
# it. So the claim is proved by DIFFERENCE, on one unchanged fixture repo:
#
#   run 1  test-fx-blind.sh              → the fx_bigger mutant SURVIVES
#   run 2  test-fx-blind.sh,test-fx-a.sh → the same mutant is KILLED
#
# The first run is the control that makes the second mean something: without it
# a runner that silently ignored the field entirely and always ran the whole
# fixture suite would also pass. And the two runs disagree on ONE input only —
# the second name in the field.
fx_run "$RUN" "$CONF_BLIND" "$FX" "$TMP/wit-blind"
check "control: the blind oracle does not notice the fx_bigger mutant" \
  "SURVIVED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
check "control: the blind oracle DOES notice the fx_never_called mutant" \
  "KILLED" "$(fx_verdict "$FX_OUT" "$SURVIVOR")"

fx_run "$RUN" "$CONF_SET" "$FX" "$TMP/wit-set"
check "a second oracle in the field kills what the first is blind to" \
  "KILLED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
# Both members ran, not just the last: each of these two mutants is invisible to
# one member and fatal to the other, so only a run that invoked BOTH kills both.
check "  … and the first oracle still kills what the second is blind to" \
  "KILLED" "$(fx_verdict "$FX_OUT" "$SURVIVOR")"
# The record carries the whole set, so a ledger reader can see which tests were
# asked. A runner that split the field and reported only one name would leave
# the ledger blaming an oracle that never had the chance to notice.
check "the MUTANT record reports the oracle field verbatim" \
  "test-fx-blind.sh,test-fx-a.sh" "$(fx_field "$FX_OUT" "$KILLABLE" 4)"
# And the baseline is the SET's baseline: run.sh refuses a target whose oracle
# is not green on the pristine tree, so a second member that was red there must
# stop the target rather than be quietly dropped.
check "the BASELINE record names the whole set too" \
  "1" "$(grep -c '^BASELINE|fixture-lib.sh|test-fx-blind.sh,test-fx-a.sh|PASS|' <<< "$FX_OUT")"

# ── A KILL WITH NO ASSERTION ATTACHED IS COUNTED, NAMED, AND BOUNDABLE ────────
# The tier has recorded which channel produced every kill since it was written,
# and nothing consumed it — which is why three separate false-kill mechanisms
# each had to be found by hand, on one mutant, by somebody looking closely
# (F35 a signal death, F30 a load-induced kill, F43 an errexit abort). The
# verdict stays KILLED, deliberately: the oracle DID distinguish the mutant, and
# demoting it would be a second guess dressed as a measurement. What changes is
# that the run now says how much of its coverage arrived this way.
fx_run "$RUN" "$CONF_ASSERTLESS" "$FX" "$TMP/wit-assertless"
check "an oracle that exits non-zero in silence still reports KILLED" \
  "KILLED" "$(fx_verdict "$FX_OUT" "$KILLABLE")"
fx_sig="$(fx_signal "$FX_OUT" "$KILLABLE")"
case "$fx_sig" in
  *failline*) fail "  … and its signal carries no failline (got '$fx_sig' — the fixture printed a FAIL: line, so this case is measuring the wrong thing)" ;;
  *exit*)     pass "  … and its signal is a bare exit, with no failline ($fx_sig)" ;;
  *)          fail "  … and its signal is a bare exit, with no failline (got '$fx_sig')" ;;
esac
# The COUNT, on its own line, emitted whether or not anything asked for a bound.
# The WHOLE line rather than the numerator: `ASSERTLESS|3|3` also pins that the
# denominator is the kill count, so a reader sees three-of-three without doing
# arithmetic the report should have done — and a regression that reported the
# count against the wrong total would still read plausibly if only field 2 were
# checked. All three of this fixture's killable mutants take the silent path;
# the fourth is fx_never_called's, which nothing kills.
check "the run reports how many kills arrived with no assertion, over how many kills" \
  "ASSERTLESS|3|3" "$(grep '^ASSERTLESS|' <<< "$FX_OUT")"
grep -q 'KILLED WITH NO ASSERTION ATTACHED' <<< "$FX_ERR" \
  && pass "  … and names the mutant, so the count is actionable rather than a number" \
  || fail "  … and names the mutant (no 'KILLED WITH NO ASSERTION ATTACHED' line in stderr)"
# Reporting without a bound must not fail the run: a developer host discovering
# this mid-task is not how it should be raised, and the same reasoning is why
# --max-unproven-pct is opt-in.
check "reporting alone does not fail the run" "0" "$FX_RC"

fx_run "$RUN" "$CONF_ASSERTLESS" "$FX" "$TMP/wit-assertless2" --max-assertless 0
[[ "$FX_RC" -ne 0 ]] \
  && pass "--max-assertless 0 fails a run whose kills carry no assertion (rc=$FX_RC)" \
  || fail "--max-assertless 0 fails a run whose kills carry no assertion — got rc 0, so the bound is decorative"
grep -q 'over the --max-assertless' <<< "$FX_ERR" \
  && pass "  … and says which budget was exceeded" \
  || fail "  … and says which budget was exceeded (stderr: $(tail -2 <<< "$FX_ERR"))"

# The bound must be satisfiable by an honest oracle, or it is a tax rather than
# a ratchet: the SAME flag against an oracle that reports its failures properly
# has to pass. Without this the case above would also pass if --max-assertless
# simply failed every run.
fx_run "$RUN" "$CONF_A" "$FX" "$TMP/wit-assertless3" --max-assertless 0
check "--max-assertless 0 passes an oracle that prints its FAIL: lines" "0" "$FX_RC"
check "  … and that run reports zero assertless kills" \
  "0" "$(awk -F'|' '$1 == "ASSERTLESS" { print $2 }' <<< "$FX_OUT")"

# ── §15. the clock scales with the ORACLE SET ─────────────────────────────────
# A target whose oracle names three test files does three times the work per
# mutant, so one global ceiling cannot be right for it and for a single-oracle
# target at once. The ceiling is a hang detector, not a cost estimate (F36), so
# it scales with the set rather than being tuned per target.
#
# Measured on macOS + Colima 2026-08-21 (F28): at the 120s default,
# tests/lib-verify-repo.sh — the only three-oracle target — timed out 42 of 55
# mutants and put two PRISTINE controls over the clock at 132.8s and 156.0s,
# while all eight single-oracle targets recorded zero timeouts in the same run.
eff_timeout() {   # <clock> <oracle-set> → run.sh's own computation, in a subshell
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    # Read by fr_effective_timeout, which shellcheck cannot follow through the
    # non-constant source above.
    # shellcheck disable=SC2034
    FR_TIMEOUT="$1"
    fr_effective_timeout "$2" )
}
check "one oracle gets the plain clock"            "120" "$(eff_timeout 120 'test-a.sh')"
check "three oracles get three times the clock"    "360" "$(eff_timeout 120 'test-a.sh,test-b.sh,test-c.sh')"
check "two oracles get twice the clock"            "600" "$(eff_timeout 300 'test-a.sh,test-b.sh')"
# A degenerate set must never yield 0: a zero clock would make every mutant time
# out instantly and score the whole target UNPROVEN.
check "an empty oracle set still gets one clock, never zero" "120" "$(eff_timeout 120 '')"
check "a trailing comma does not count as an oracle"         "240" "$(eff_timeout 120 'test-a.sh,test-b.sh,')"

# ── §16. the watchdog's clock is WALL TIME, not a count of sleeps ─────────────
# falsify_watch_until is the per-mutant ceiling. Written as `for (( i = 0; i <
# secs; i++ )); do … sleep 1; done` it counts ITERATIONS, and an iteration on a
# loaded machine costs a sleep plus a fork plus whatever the scheduler adds — so
# the ceiling grows with exactly the load the tier itself creates. Measured on
# macOS + Colima at --jobs 8 (2026-08-22): a pristine CONTROL of
# tests/bash-dialect-lint.sh, a single-oracle target on a 120s ceiling, was
# recorded at 132.2s having exited on its own. A clock that reports 120 and
# enforces 132 makes two runs incomparable and every timeout count a property
# of the machine.
#
# Demonstrated WITHOUT a wall-clock margin, deliberately: an assertion that
# measures real elapsed time inside an oracle is the very defect this section
# is about — under load it flips, and in this tier a flipped assertion is a
# false KILL. So the clock and the sleep are both stubbed and the POLL COUNT is
# read instead. It is exact, it is instant, and it cannot be load-sensitive.
watch_polls() {   # <us the fake clock advances per poll> <ceiling seconds> → polls
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    _adv="$1"; _now=0; _polls=0
    # Both assign globals that the sourced run.sh reads; shellcheck cannot
    # follow that through a non-constant source.
    # shellcheck disable=SC2034
    fr_now_us_into() { FR_NOW_US="$_now"; }
    # Shadows the one-second wait, so no real time passes and the only thing
    # that moves the clock is this stub. The fifo is stubbed out with it: this
    # section is about the arithmetic, not the plumbing.
    falsify_tick() { _polls=$(( _polls + 1 )); _now=$(( _now + _adv )); }
    # shellcheck disable=SC2034
    falsify_tick_open() { FR_TICK_FD=""; }
    falsify_tick_close() { :; }
    command sleep 30 & _pid=$!
    falsify_watch_until "$_pid" "$2" >/dev/null 2>&1
    kill -TERM "$_pid" 2>/dev/null
    printf '%s' "$_polls" )
}
# Ten simulated seconds per poll against a 60s ceiling: six polls, not sixty.
# The iteration-counting version returns 60 here — it never reads a clock at
# all — which is the 10%-and-growing overrun measured on the host, in the small.
check "the ceiling is reached in elapsed time, not in sleeps" "6" "$(watch_polls 10000000 60)"
# The other direction, and the one that would silently SHORTEN every ceiling: a
# poll that returns early (a busy `sleep`, a signal) must not spend the budget.
# The iteration-counting version returns 2 here and cuts the oracle at 0.2s.
check "a poll that returns early does not spend the budget" "20" "$(watch_polls 100000 2)"

# ── §17. the watchdog does not FORK to watch, and says how late it noticed ────
# A pristine CONTROL of tests/bash-dialect-lint.sh on a 120s ceiling was recorded
# at 152.6s and 150.0s (host, jobs=18, 2026-08-22) while every other target in
# the same run overshot by 0.2-2.8s. The kill cannot account for it — TERM, one
# second, then SIGKILL, which nothing ignores — so the watchdog noticed late. It
# was paying three forks a second to read a clock bash exposes as a variable,
# on the most fork-heavy target in the corpus.
# The real clock and the real wait, so this measures the plumbing rather than
# the arithmetic §16 covers. Reported as forked/no-fork, not as a count: the
# number of one-second waits inside a two-second ceiling is a race with the
# scheduler, and an assertion that can flip on timing is the defect this whole
# section is about.
watch_forks() {   # <ceiling seconds> <1 = break mkfifo> → forked | no-fork
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    _sleeps=0
    [[ "$2" == "1" ]] && { mkfifo() { return 1; }; }
    # Still really waits — otherwise the fallback would spin against a real
    # clock and prove nothing about being bounded.
    sleep() { _sleeps=$(( _sleeps + 1 )); command sleep "$1"; }
    command sleep 30 & _pid=$!
    falsify_watch_until "$_pid" "$1" >/dev/null 2>&1
    kill -TERM "$_pid" 2>/dev/null
    (( _sleeps > 0 )) && printf 'forked' || printf 'no-fork' )
}
check "the one-second wait forks nothing when a fifo can be opened" "no-fork" "$(watch_forks 2 0)"
# A host that cannot make a fifo still gets a BOUNDED wait rather than a loop
# that spins a core — the fallback is load-bearing, not a formality.
check "a host without mkfifo still falls back to a bounded wait" "forked" "$(watch_forks 2 1)"

# The lateness itself, on a fake clock so the number is exact: polls landing
# every 7 simulated seconds against a 60s ceiling first exceed it at 63s.
watch_late() {   # <us per poll> <ceiling seconds> → FR_WATCH_LATE_MS
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    _adv="$1"; _now=0
    # Both assign globals that the sourced run.sh reads; shellcheck cannot
    # follow that through a non-constant source.
    # shellcheck disable=SC2034
    fr_now_us_into() { FR_NOW_US="$_now"; }
    falsify_tick() { _now=$(( _now + _adv )); }
    # shellcheck disable=SC2034
    falsify_tick_open() { FR_TICK_FD=""; }
    falsify_tick_close() { :; }
    command sleep 30 & _pid=$!
    falsify_watch_until "$_pid" "$2" >/dev/null 2>&1
    kill -TERM "$_pid" 2>/dev/null
    printf '%s' "$FR_WATCH_LATE_MS" )
}
check "a timeout records how late the watchdog noticed" "3000" "$(watch_late 7000000 60)"
# Landing exactly on the deadline is not lateness, and must not be reported as
# 1ms of it: the field has to be able to say "on time" for the split to mean
# anything.
check "a watchdog that fires on the deadline reports no lateness" "0" "$(watch_late 10000000 60)"

# ── §17. `--jobs auto` does not count efficiency cores as equals ──────────────
# hw.ncpu sums both performance levels on Apple Silicon. Measured on the host
# (F59): 18 = 6 performance + 12 efficiency, no SMT, and `auto` took all 18 —
# against oracles that spend over half their wall time creating processes, work
# that collapses on an efficiency core. The pristine control that proves the
# cost went 445.8s red -> 251s green on the same commit and clock at half the
# jobs.
#
# `sysctl` is stubbed rather than read: this assertion has to hold on the Linux
# CI that has no perflevels and on a Mac that does, so the machine underneath
# must not be able to change the answer.
#
# AND SO IS `uname`, for the same reason and one probe further out. Stubbing the
# core counts but not the kernel name leaves fr_fork_cost_cap reading the real
# machine, and its Darwin branch caps the budget at 1 -- which collapses every
# expectation in this section to 1 on a Mac while CI stays green. Measured: a
# 2026-08-28 host run failed all four of the checks below with `got '1'`, none
# of which is about the fork-cost cap at all. This section is about the CORE
# MIX; the cap has its own section above, where both of its branches are faked.
cpu_budget() {   # <hw.ncpu> <hw.perflevel0.logicalcpu, or empty for absent> → workers
  ( set +u
    # shellcheck source=/dev/null
    source "$RUN" >/dev/null 2>&1
    _ncpu="$1"; _perf="$2"
    uname() { [[ "$1" == "-s" ]] && { printf 'Linux\n'; return 0; }; return 1; }
    sysctl() {
      case "${3:-$2}" in
        hw.ncpu) printf '%s\n' "$_ncpu" ;;
        hw.perflevel0.logicalcpu) [[ -n "$_perf" ]] || return 1; printf '%s\n' "$_perf" ;;
        *) return 1 ;;
      esac
    }
    # nproc would be preferred by fr_host_cpus and would read the REAL machine.
    nproc() { printf '%s\n' "$_ncpu"; }
    # No cgroup quota: this section is about the core mix, and FR_CGROUP pointing
    # at a path that cannot exist is how fr_quota_cpus is told so. Read by
    # fr_quota_cpus, which shellcheck cannot follow through the source above.
    # shellcheck disable=SC2034
    FR_CGROUP="$TMP/no-such-cgroup"
    fr_cpu_budget )
}
check "a 6P+12E machine is capped at its performance cores" "6"  "$(cpu_budget 18 6)"
# The other direction, and the one that must not regress: a machine whose cores
# are all equal reports no perflevel at all and keeps every one of them.
check "a uniform machine keeps all of its cores"            "12" "$(cpu_budget 12 '')"
# A perflevel that is not a positive integer is no answer, and must not be read
# as one — the same rule fr_quota_cpus applies to an unparseable quota.
check "an unparseable performance-core count is ignored"    "18" "$(cpu_budget 18 'zero')"
# It NARROWS only. A perflevel larger than the reported count (a machine nobody
# has met yet, or a stub) cannot hand out workers the OS did not report.
check "the performance-core count never widens the budget"  "8"  "$(cpu_budget 8 16)"

# ── §18. --help documents every record the runner actually emits ─────────────
# THE OUTPUT FORMAT IS A STATED CONTRACT -- the block is headed "parse THIS, not
# stderr", and check-ledger.sh, verify-on-host.sh and this file all parse those
# records positionally. It had drifted: CONTROL, CONTROLS, SKIPPED and
# UNATTEMPTED were all being emitted and none was listed, because fr_usage cut
# the block at a hardcoded line 60 that the text had grown past -- so --help
# ended mid-sentence and the four sat below the cut, undocumented and unnoticed.
#
# DERIVED FROM THE SOURCE, not from a second list. A hand-maintained list of
# expected record types is a third thing to keep in sync and would have drifted
# exactly as the first two did; this reads what the runner PRINTS and requires
# --help to mention it. A new record type therefore fails here on the commit
# that introduces it.
help_out="$(bash "$RUN" --help 2>&1)"
[[ -n "$help_out" ]] \
  && pass "--help prints something at all" \
  || fail "--help prints something at all"
# The truncation itself, asserted: the block's last line is a whole sentence.
[[ "$help_out" == *"sort downstream if order matters."* ]] \
  && pass "  … and reaches the END of the usage block rather than stopping mid-sentence" \
  || fail "  … and reaches the END of the usage block — got last line: $(tail -1 <<<"$help_out")"
# And it must STOP there: everything below the marker is design rationale, and
# dumping the whole 157-line header would be the opposite failure.
! grep -q 'ISOLATION: THE WORKING TREE IS NEVER MUTATED' <<<"$help_out" \
  && pass "  … and stops at the marker rather than dumping the design notes" \
  || fail "  … and stops at the marker rather than dumping the design notes"
undocumented=""
while IFS= read -r rec; do
  grep -q "^  *${rec}|" <<<"$help_out" || undocumented="${undocumented:+$undocumented }$rec"
done < <(grep -oE "printf '[A-Z]+\|" "$RUN" | sed "s/printf '//; s/|//" | sort -u)
check "every record type the runner emits is documented in --help" "" "$undocumented"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
