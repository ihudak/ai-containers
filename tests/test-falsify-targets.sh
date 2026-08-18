#!/usr/bin/env bash
# tests/test-falsify-targets.sh — the gate on tests/falsify/targets.conf, and on
# the derivation that map is checked against.
#
# WHY BOTH: the mutation tier's whole claim is that a surviving mutant means a
# weak assertion. That claim is false for any file the hermetic suite does not
# EXECUTE — mutate entrypoint.sh and 100% of its mutants survive, saying nothing
# about the suite and everything about the classification. So a wrong row in the
# map does not fail loudly on its own; it produces a confident, wrong number.
# Four gates close that, and each is exercised here against a FIXTURE map built
# from the real one, not merely described:
#
#   1. an EXECUTED file with no row fails, naming the file
#   2. a GREPPED-ONLY file registered as an active mutation target is rejected
#      (a gate that only catches omissions lets a wrong classification through)
#   3. a row naming a nonexistent oracle fails loudly — tests/run-all.sh exits 2
#      when its filter matches nothing, so a typo would run ZERO tests and
#      report every mutant killed. That premise is pinned here too.
#   4. an EXECUTED-PARTIAL row with an empty 4th field fails: naming the
#      functions is the entire point of that category.
#
# The derivation itself is falsified against a synthetic repo whose answers are
# known by construction, because "derive-targets.sh agrees with targets.conf"
# would otherwise be two hand-written lists agreeing with each other.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVE="$REPO_DIR/tests/falsify/derive-targets.sh"
CONF="$REPO_DIR/tests/falsify/targets.conf"
RUNALL="$REPO_DIR/tests/run-all.sh"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # $1=label $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1 (expected '$2', got '$3')"; fi
}

[[ -f "$DERIVE" ]] || { fail "tests/falsify/derive-targets.sh exists"; exit 1; }
[[ -f "$CONF" ]]   || { fail "tests/falsify/targets.conf exists"; exit 1; }
bash -n "$DERIVE" && pass "derive-targets.sh bash -n" || fail "derive-targets.sh bash -n"

# ── 1. The real map passes its own gate, with a real (uncached) derivation ─────
real_out="$(bash "$DERIVE" --check 2>&1)"; real_rc=$?
if [[ "$real_rc" -eq 0 ]]; then
  pass "the real targets.conf passes --check ($(printf '%s' "$real_out" | tail -1))"
else
  fail "the real targets.conf fails --check: $real_out"
fi
printf '%s' "$real_out" | grep -q '0 problem(s)' \
  && pass "--check reports 0 problem(s) for the real map, counted not implied" \
  || fail "--check did not report 0 problem(s) for the real map (output: $real_out)"

# Every later fixture reuses ONE derivation: walking every hermetic test costs
# seconds, and the fixtures differ in the MAP, never in the repo.
DERIVED="$TMP/derived.txt"
bash "$DERIVE" > "$DERIVED" 2>"$TMP/derive.err"
if [[ -s "$DERIVED" ]]; then
  pass "derive-targets.sh emits a verdict per candidate ($(grep -c . "$DERIVED") rows)"
else
  fail "derive-targets.sh emitted nothing (stderr: $(cat "$TMP/derive.err"))"
  exit 1
fi
[[ -s "$TMP/derive.err" ]] \
  && fail "derive-targets.sh warned on the real repo: $(cat "$TMP/derive.err")" \
  || pass "derive-targets.sh derives the real repo with no warnings"

# Sets gate_out/gate_rc rather than echoing: a `$(gate ...)` command
# substitution runs in a SUBSHELL, so an exit code assigned inside it never
# reaches the caller — and every gate below asserts on that exit code.
gate_out=""; gate_rc=0
gate() {  # $1=conf → sets gate_out and gate_rc from a cached --check
  gate_out="$(FALSIFY_DERIVED="$DERIVED" bash "$DERIVE" --check "$1" 2>&1)"; gate_rc=$?
}

# The cached path must agree with the uncached one, or every fixture below is
# checking something the real gate does not.
gate "$CONF"; cached_out="$gate_out"
check "the cached derivation reaches the same verdict as the real one" "0" "$gate_rc"
printf '%s' "$cached_out" | grep -q '0 problem(s)' \
  && pass "the cached --check reports the same 0 problem(s)" \
  || fail "the cached --check disagreed with the uncached one: $cached_out"

# ── 2. Two real-repo facts the derivation must get right ──────────────────────
# docker-shim.sh is reachable ONLY through `ln -sf "$SHIM" "$TMP/bin/docker"` —
# no test names the file at a command position. entrypoint.sh is named by five
# assertions, every one of them a grep or a `bash -n`.
shim_verdict="$(awk -F'|' '$1 == "tests/integration/docker-shim.sh" { print $2 }' "$DERIVED")"
check "docker-shim.sh is EXECUTED (resolved through the symlink, not the name)" \
  "EXECUTED" "$shim_verdict"
ep_verdict="$(awk -F'|' '$1 == "entrypoint.sh" { print $2 }' "$DERIVED")"
check "entrypoint.sh is NOT-EXECUTED (bash -n and grep are not execution)" \
  "NOT-EXECUTED" "$ep_verdict"

# ── 3. GATE 1: an executed file with no row fails, BY NAME ────────────────────
f1="$TMP/gate1.conf"
grep -v '^tools-lib\.sh|' "$CONF" > "$f1"
check "fixture: gate1.conf drops the tools-lib.sh row" \
  "$(( $(grep -c . "$CONF") - 1 ))" "$(grep -c . "$f1")"
gate "$f1"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 1: a dropped row for an executed target fails the gate" \
  || fail "gate 1: a dropped row for an executed target passed the gate"
printf '%s' "$out" | grep -q '^ERROR: tools-lib.sh is EXECUTED by the hermetic suite' \
  && pass "gate 1: the failure NAMES the missing file" \
  || fail "gate 1: the failure did not name tools-lib.sh (output: $out)"

# ── 4. GATE 2: a GREPPED-ONLY file registered as an active target is rejected ──
f2="$TMP/gate2.conf"
sed 's@^entrypoint\.sh|GREPPED-ONLY|test-entrypoint-wiring\.sh$@entrypoint.sh|EXECUTED-WHOLE|test-entrypoint-wiring.sh@' "$CONF" > "$f2"
grep -q '^entrypoint\.sh|EXECUTED-WHOLE|' "$f2" \
  && pass "fixture: gate2.conf promotes entrypoint.sh to an active mutation target" \
  || fail "fixture: gate2.conf did not promote entrypoint.sh"
gate "$f2"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 2: a GREPPED-ONLY file registered as a mutation target fails the gate" \
  || fail "gate 2: a GREPPED-ONLY file registered as a mutation target passed the gate"
printf '%s' "$out" | grep -q 'entrypoint.sh is classified EXECUTED-WHOLE but the hermetic suite never EXECUTES it' \
  && pass "gate 2: the failure names the file and says why (never executed)" \
  || fail "gate 2: the failure did not explain the misclassification (output: $out)"

# The mirror: an executed file mislabelled GREPPED-ONLY is also caught, or the
# map could hide a target by demoting it instead of deleting its row.
f2b="$TMP/gate2b.conf"
sed 's@^tools-lib\.sh|EXECUTED-WHOLE|test-tools-d\.sh$@tools-lib.sh|GREPPED-ONLY|test-tools-d.sh@' "$CONF" > "$f2b"
gate "$f2b"; out="$gate_out"
printf '%s' "$out" | grep -q 'tools-lib.sh is classified GREPPED-ONLY but the hermetic suite EXECUTES it' \
  && pass "gate 2 (mirror): demoting an executed target to GREPPED-ONLY fails the gate" \
  || fail "gate 2 (mirror): demoting an executed target to GREPPED-ONLY passed (output: $out)"

# ── 5. GATE 3: a nonexistent oracle fails loudly ─────────────────────────────
# The premise first: run-all.sh EXITS 2 when its filter matches nothing, so a
# typo'd oracle would run zero tests and report every mutant killed. That is the
# quiet-success failure mode this gate exists to make impossible.
bash "$RUNALL" no-such-oracle-zzz >/dev/null 2>&1
check "premise: run-all.sh exits 2 when its filter selects no test" "2" "$?"

f3="$TMP/gate3.conf"
sed 's@^tools-lib\.sh|EXECUTED-WHOLE|test-tools-d\.sh$@tools-lib.sh|EXECUTED-WHOLE|test-tools-dd.sh@' "$CONF" > "$f3"
grep -q '^tools-lib\.sh|EXECUTED-WHOLE|test-tools-dd\.sh$' "$f3" \
  && pass "fixture: gate3.conf misspells the oracle as test-tools-dd.sh" \
  || fail "fixture: gate3.conf did not misspell the oracle"
[[ ! -f "$REPO_DIR/tests/test-tools-dd.sh" ]] \
  && pass "fixture: tests/test-tools-dd.sh really does not exist" \
  || fail "fixture: tests/test-tools-dd.sh exists, so the typo case proves nothing"
gate "$f3"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 3: a misspelled oracle fails the gate" \
  || fail "gate 3: a misspelled oracle passed the gate"
printf '%s' "$out" | grep -q 'names oracle test-tools-dd.sh, which does not exist' \
  && pass "gate 3: the failure names the missing oracle and the run-all.sh exit-2 consequence" \
  || fail "gate 3: the failure did not name the missing oracle (output: $out)"

# An oracle that EXISTS but whose name selects more than one test is equally
# unusable: run-all.sh would run both and attribute either one's failure to this
# target. No pair of real test filenames collides that way, so the rule is
# demonstrated on a synthetic tests/ directory that does — otherwise the check
# would be unreachable code claiming to guard something.
AMB="$TMP/ambig"
mkdir -p "$AMB/tests"
printf '#!/usr/bin/env bash\n' > "$AMB/tests/test-alpha.sh"
printf '#!/usr/bin/env bash\n' > "$AMB/tests/test-alpha.sh-and-more.sh"
printf '#!/usr/bin/env bash\n' > "$AMB/target.sh"
printf 'target.sh|EXECUTED-WHOLE|test-alpha.sh\n' > "$AMB/amb.conf"
printf 'target.sh|EXECUTED|test-alpha.sh\n' > "$AMB/amb.derived"
out="$(FALSIFY_REPO="$AMB" FALSIFY_TESTS_DIR="$AMB/tests" FALSIFY_DERIVED="$AMB/amb.derived" \
       bash "$DERIVE" --check "$AMB/amb.conf" 2>&1)"; amb_rc=$?
[[ "$amb_rc" -ne 0 ]] \
  && pass "gate 3 (ambiguity): an oracle whose name selects several tests fails the gate" \
  || fail "gate 3 (ambiguity): a multi-selecting oracle passed the gate (output: $out)"
printf '%s' "$out" | grep -qE 'names oracle test-alpha.sh, which run-all.sh selects 2 test\(s\) for' \
  && pass "gate 3 (ambiguity): the failure reports how many tests the oracle selects" \
  || fail "gate 3 (ambiguity): the failure did not report the selection count (output: $out)"

# ── 6. GATE 4: EXECUTED-PARTIAL with an empty 4th field ──────────────────────
f4="$TMP/gate4.conf"
{ cat "$CONF"; printf 'sandbox-common.sh|EXECUTED-PARTIAL|test-parsers.sh|\n'; } \
  | grep -v '^#DEFERRED|sandbox-common\.sh|' > "$f4"
gate "$f4"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 4: an EXECUTED-PARTIAL row with an empty function list fails the gate" \
  || fail "gate 4: an EXECUTED-PARTIAL row with an empty function list passed the gate"
printf '%s' "$out" | grep -q 'sandbox-common.sh is EXECUTED-PARTIAL with an empty function list' \
  && pass "gate 4: the failure names the file and the missing 4th field" \
  || fail "gate 4: the failure did not name the empty function list (output: $out)"

# A `-` placeholder is empty too — the deferred rows use it for EXECUTED-WHOLE,
# so a copy-paste into an EXECUTED-PARTIAL row must not slip through.
f4b="$TMP/gate4b.conf"
{ cat "$CONF"; printf 'sandbox-common.sh|EXECUTED-PARTIAL|test-parsers.sh|-\n'; } \
  | grep -v '^#DEFERRED|sandbox-common\.sh|' > "$f4b"
gate "$f4b"; out="$gate_out"
printf '%s' "$out" | grep -q 'sandbox-common.sh is EXECUTED-PARTIAL with an empty function list' \
  && pass "gate 4: a '-' function list counts as empty" \
  || fail "gate 4: a '-' function list was accepted (output: $out)"

# Naming functions is only meaningful if the names are real.
f4c="$TMP/gate4c.conf"
sed 's@^#DEFERRED|repo\.sh|EXECUTED-PARTIAL|test-repo-registry\.sh|is_git_url,fmt_epoch@#DEFERRED|repo.sh|EXECUTED-PARTIAL|test-repo-registry.sh|is_git_url,no_such_function@' "$CONF" > "$f4c"
gate "$f4c"; out="$gate_out"
printf '%s' "$out" | grep -q 'naming function no_such_function, which is not defined in repo.sh' \
  && pass "gate 4: a named function that is not defined in the target fails the gate" \
  || fail "gate 4: an undefined function name was accepted (output: $out)"

# ── 7. An EXCLUDED row with an empty reason suppresses NOTHING ────────────────
f5="$TMP/exclude-empty.conf"
sed 's@^#EXCLUDED|tests/run-all\.sh|.*$@#EXCLUDED|tests/run-all.sh|@' "$CONF" > "$f5"
grep -q '^#EXCLUDED|tests/run-all\.sh|$' "$f5" \
  && pass "fixture: exclude-empty.conf empties the exclusion reason" \
  || fail "fixture: exclude-empty.conf did not empty the reason"
gate "$f5"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "an #EXCLUDED| row with an empty reason fails the gate" \
  || fail "an #EXCLUDED| row with an empty reason passed the gate"
printf '%s' "$out" | grep -q 'has an empty reason — an empty reason suppresses nothing' \
  && pass "the empty-reason failure says the reason is required" \
  || fail "the empty-reason failure was not reported (output: $out)"
printf '%s' "$out" | grep -qE '^ERROR: tests/run-all\.sh .*has no row' \
  && pass "an empty reason leaves the target UNMAPPED, not excluded" \
  || fail "an empty reason still suppressed the target (output: $out)"

# A deferral must state why, for the same reason.
f5b="$TMP/defer-empty.conf"
sed 's@^#DEFERRED|group\.sh|EXECUTED-WHOLE|test-group-lifecycle\.sh|-|.*$@#DEFERRED|group.sh|EXECUTED-WHOLE|test-group-lifecycle.sh|-|@' "$CONF" > "$f5b"
gate "$f5b"; out="$gate_out"
printf '%s' "$out" | grep -q '#DEFERRED| for group.sh has an empty reason' \
  && pass "a #DEFERRED| row with an empty reason fails the gate" \
  || fail "a #DEFERRED| row with an empty reason passed the gate (output: $out)"

# ── 8. Structural gates: duplicates, unknown categories, phantom targets ──────
f6="$TMP/dup.conf"
{ cat "$CONF"; printf 'tools-lib.sh|EXECUTED-WHOLE|test-tools-d.sh\n'; } > "$f6"
gate "$f6"; out="$gate_out"
printf '%s' "$out" | grep -q 'duplicate row for tools-lib.sh' \
  && pass "a duplicate row for the same target fails the gate" \
  || fail "a duplicate row for the same target passed the gate (output: $out)"

f7="$TMP/badcat.conf"
sed 's@^tools-lib\.sh|EXECUTED-WHOLE|test-tools-d\.sh$@tools-lib.sh|EXECUTED|test-tools-d.sh@' "$CONF" > "$f7"
gate "$f7"; out="$gate_out"
printf '%s' "$out" | grep -q 'tools-lib.sh has unknown category EXECUTED ' \
  && pass "an unknown category fails the gate" \
  || fail "an unknown category passed the gate (output: $out)"

f8="$TMP/phantom.conf"
{ cat "$CONF"; printf 'no-such-script.sh|EXECUTED-WHOLE|test-tools-d.sh\n'; } > "$f8"
gate "$f8"; out="$gate_out"
printf '%s' "$out" | grep -q 'no-such-script.sh is not an in-scope candidate' \
  && pass "a row naming a file that is not a candidate fails the gate" \
  || fail "a row naming a phantom target passed the gate (output: $out)"

# A GREPPED-ONLY row must not carry a function list either — the mutation unit
# only shrinks below the file for EXECUTED-PARTIAL.
f9="$TMP/funcs-on-whole.conf"
sed 's@^tools-lib\.sh|EXECUTED-WHOLE|test-tools-d\.sh$@tools-lib.sh|EXECUTED-WHOLE|test-tools-d.sh|tools_list_names@' "$CONF" > "$f9"
gate "$f9"; out="$gate_out"
printf '%s' "$out" | grep -q 'tools-lib.sh is EXECUTED-WHOLE but lists functions' \
  && pass "a function list on a non-EXECUTED-PARTIAL row fails the gate" \
  || fail "a function list on an EXECUTED-WHOLE row was accepted (output: $out)"

# ── 9. The derivation, falsified against a repo whose answers are known ───────
# Two hand-written lists agreeing with each other proves nothing, so the
# resolver is driven over a synthetic repo built to contain one instance of each
# resolution rule — including the three that matter most: a path reached only
# through a VARIABLE, one reached only through a SYMLINK, and two named only by
# `bash -n` and by a heredoc BODY, which must NOT count.
FIX="$TMP/fixrepo"
mkdir -p "$FIX/tests" "$FIX/bin"
for f in sourced.sh parsed-only.sh shellchecked.sh grepped.sh heredoc-named.sh \
         aliased.sh var-path.sh transitive.sh never-mentioned.sh; do
  printf '#!/usr/bin/env bash\n: %s\n' "$f" > "$FIX/$f"
done
cat > "$FIX/sourced.sh" <<'FIXEOF'
#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$REPO_DIR/transitive.sh"
FIXEOF
cat > "$FIX/tests/test-synth.sh" <<'FIXEOF'
#!/usr/bin/env bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAR="$REPO_DIR/var-path.sh"
BIN="$REPO_DIR/bin"
source "$REPO_DIR/sourced.sh"
bash -n "$REPO_DIR/parsed-only.sh"
shellcheck "$REPO_DIR/shellchecked.sh"
grep -q needle "$REPO_DIR/grepped.sh"
bash "$VAR" --flag
ln -sf "$REPO_DIR/aliased.sh" "$BIN/dockerish"
"$BIN/dockerish" run --rm
cat > "$REPO_DIR/written-stub.sh" <<'INNER'
bash /elsewhere/heredoc-named.sh
source /elsewhere/heredoc-named.sh
INNER
FIXEOF
git -C "$FIX" init -q 2>/dev/null
git -C "$FIX" add -A 2>/dev/null

synth_want="$(cat <<'WANT'
aliased.sh|EXECUTED
grepped.sh|NOT-EXECUTED
heredoc-named.sh|NOT-EXECUTED
never-mentioned.sh|NOT-EXECUTED
parsed-only.sh|NOT-EXECUTED
shellchecked.sh|NOT-EXECUTED
sourced.sh|EXECUTED
transitive.sh|EXECUTED
var-path.sh|EXECUTED
WANT
)"
synth_got="$(FALSIFY_REPO="$FIX" FALSIFY_TESTS_DIR="$FIX/tests" bash "$DERIVE" 2>/dev/null | cut -d'|' -f1,2)"
check "the derivation resolves variables, symlinks and transitive execution, and refuses bash -n / grep / shellcheck / heredoc bodies" \
  "$synth_want" "$synth_got"

# Name the individual rules too, so a regression says WHICH resolution broke.
synth_verdict() { printf '%s' "$synth_got" | awk -F'|' -v f="$1" '$1 == f { print $2 }'; }
check "  indirection: bash \"\$VAR\" resolves to the file VAR holds" \
  "EXECUTED" "$(synth_verdict var-path.sh)"
check "  indirection: a symlink invoked under another name resolves to its target" \
  "EXECUTED" "$(synth_verdict aliased.sh)"
check "  transitivity: what an executed file itself runs is executed" \
  "EXECUTED" "$(synth_verdict transitive.sh)"
check "  bash -n is not execution" "NOT-EXECUTED" "$(synth_verdict parsed-only.sh)"
check "  shellcheck is not execution" "NOT-EXECUTED" "$(synth_verdict shellchecked.sh)"
check "  a heredoc body is not code this file runs" \
  "NOT-EXECUTED" "$(synth_verdict heredoc-named.sh)"

# ── 10. The map is the tier inventory: every in-scope candidate has a row ─────
n_cand="$(grep -c . "$DERIVED")"
n_rows="$(bash "$DERIVE" --rows "$CONF" | grep -c .)"
check "every in-scope candidate has exactly one row in targets.conf" "$n_cand" "$n_rows"

active_rows="$(grep -cE '^[^#[:space:]]' "$CONF")"
[[ "$active_rows" -ge 1 ]] \
  && pass "targets.conf has $active_rows uncommented row(s) for tests/falsify/run.sh to read" \
  || fail "targets.conf has no uncommented rows — the tier would mutate nothing"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
