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
# target, four one-purpose oracles) built in $TMP, never the real 248-mutant
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
  FALSIFY_REPO="$repo" FALSIFY_CONF="$cnf" \
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
  sleep 30 & wu_pid=$!
  wu_t0=$SECONDS
  watch_until "$wu_pid" 3 && wu_rc=0 || wu_rc=1
  wu_el=$(( SECONDS - wu_t0 ))
  kill "$wu_pid" 2>/dev/null; wait "$wu_pid" 2>/dev/null
  if [[ "$wu_rc" -eq 1 && "$wu_el" -ge 3 ]]; then
    pass "  … a subject that outlives the clock reports the clock expiring (${wu_el}s)"
  else
    fail "  … a subject that outlives the clock reports the clock expiring — rc=$wu_rc after ${wu_el}s, so a real hang would no longer time out"
  fi

  # THE ONE THAT MATTERS. A subject that exits early must end the wait EARLY. A
  # blind `sleep "$limit"` returns the right answer here and takes the full 20
  # seconds to do it — and every second of that is a watchdog holding a pid it
  # no longer owns.
  sleep 1 & wu_pid2=$!
  wu_t0=$SECONDS
  watch_until "$wu_pid2" 20 && wu_rc2=0 || wu_rc2=1
  wu_el2=$(( SECONDS - wu_t0 ))
  wait "$wu_pid2" 2>/dev/null
  if [[ "$wu_rc2" -eq 0 && "$wu_el2" -lt 10 ]]; then
    pass "  … a subject that exits first ends the wait immediately (${wu_el2}s of a 20s clock)"
  else
    fail "  … a subject that exits first ends the wait immediately — rc=$wu_rc2 after ${wu_el2}s of a 20s clock, so the watchdog outlives its oracle and still holds a pid that may be recycled"
  fi
else
  fail "run.sh exposes falsify_watch_until — without it the watchdog sleeps its whole clock and stays alive holding a stale pid"
  fail "  … a subject that outlives the clock reports the clock expiring — there is no wait to ask"
  fail "  … a subject that exits first ends the wait immediately — there is no wait to ask"
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
check "no quota: the budget is what the OS reports" "$host_cpus" "$(budget_of "$(cg v2max v2 'max 100000')")"
check "a quota larger than the machine does not inflate the budget" \
  "$host_cpus" "$(budget_of "$(cg v2big v2 '99900000 100000')")"

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
# The slow fixture at --timeout 1 puts its one mutant at 100% unproven, so the
# boundary is exact rather than approximate.
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp1" --jobs 1 --timeout 1 --max-unproven-pct 50
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
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp2" --jobs 1 --timeout 1 --max-unproven-pct 100
check "control: a run AT the budget passes (100% against a budget of 100)" "0" "$FX_RC"
# And absent, the option changes nothing — this is opt-in because a developer
# host legitimately times out.
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp3" --jobs 1 --timeout 1
check "control: with no budget given, an unproven run still exits 0" "0" "$FX_RC"
fx_run "$RUN" "$CONF_SLOW" "$FX" "$TMP/wit-unp4" --jobs 1 --timeout 1 --max-unproven-pct banana
check "a non-numeric budget is refused (exit 2), not silently ignored" "2" "$FX_RC"

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

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
