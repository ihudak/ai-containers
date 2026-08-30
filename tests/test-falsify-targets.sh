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

# ── ENGINE PATHS ARE LAYOUT-DEPENDENT, SO THEY ARE RESOLVED, NOT TYPED ────────
# Every fixture below edits a REAL row of targets.conf, and targets.conf names
# its targets by repo-relative path — which differs between the two repos:
# upstream ai-containers keeps the engine at the repo root, mgd-ai-containers
# keeps it under base/. Typing `tools-lib.sh` into a sed pattern makes the
# pattern match nothing in one of them, and a sed that matches nothing writes an
# UNCHANGED fixture: the gate then passes, the assertion reports the gate
# working, and nothing was tested. That is the silent-success shape this whole
# tier exists to remove, so the paths are derived from the layout instead —
# the same `[[ -f build.sh ]] || base/` probe tests/integration/mutate.sh and
# tests/test-lib-verify-repo.sh already use. One copy of this file serves both.
#
# The `RE_` twins are the same strings with `.` escaped, for use inside a regex.
ENGINE_REL=""
[[ -f "$REPO_DIR/build.sh" ]] || ENGINE_REL="base/"
T_TOOLSLIB="${ENGINE_REL}tools-lib.sh"
# tests/ is unprefixed in BOTH layouts (only the ENGINE moves under base/), so
# this one needs no probe — but it still joins the row-existence loop below,
# because "unprefixed in both" is a claim about the other repo that this repo
# cannot check any other way.
T_LIBVERIFY="tests/lib-verify-repo.sh"
T_ENTRYPOINT="${ENGINE_REL}entrypoint.sh"
T_SBCOMMON="${ENGINE_REL}sandbox-common.sh"
T_REPOSH="${ENGINE_REL}repo.sh"
T_GROUPSH="${ENGINE_REL}group.sh"
# gate 4c below needs a row that is DEFERRED, EXECUTED-PARTIAL, and likely to
# STAY that way. install-tools.sh is the durable choice: its two unreached
# functions (api_get, main) need the network and a real GitHub API, so no
# amount of test-writing promotes that row to EXECUTED-WHOLE. gate 4c used to
# anchor on repo.sh, which was exactly the wrong pick — repo.sh reached full
# execution coverage and correcting its category would have turned that sed
# into a no-op.
T_INSTALLTOOLS="${ENGINE_REL}install-tools.sh"
RE_TOOLSLIB="${T_TOOLSLIB//./\\.}"
RE_ENTRYPOINT="${T_ENTRYPOINT//./\\.}"
RE_SBCOMMON="${T_SBCOMMON//./\\.}"
RE_REPOSH="${T_REPOSH//./\\.}"
RE_GROUPSH="${T_GROUPSH//./\\.}"
RE_INSTALLTOOLS="${T_INSTALLTOOLS//./\\.}"
# The probe must have resolved to a path that really is in the map, or every
# fixture below silently degrades to "no change" exactly as described above.
for _t in "$T_TOOLSLIB" "$T_ENTRYPOINT" "$T_SBCOMMON" "$T_REPOSH" "$T_GROUPSH" "$T_LIBVERIFY" "$T_INSTALLTOOLS"; do
  grep -q "|${_t}|\|^${_t}|" "$CONF" \
    || { printf 'FAIL: %s\n' "the layout probe resolved $_t, which has no row in targets.conf — every fixture below would edit nothing"; exit 1; }
done
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# Confined to the owning process — the fixture must survive a forked child
# running this trap (F30/F32/F64; tests/test-exit-trap-ownership.sh).
# $BASHPID, not $$: $$ is unchanged in a subshell and would guard nothing.
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
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
grep -q '0 problem(s)' <<<"$real_out" \
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
grep -q '0 problem(s)' <<<"$cached_out" \
  && pass "the cached --check reports the same 0 problem(s)" \
  || fail "the cached --check disagreed with the uncached one: $cached_out"

# ── 2. Two real-repo facts the derivation must get right ──────────────────────
# docker-shim.sh is reachable ONLY through `ln -sf "$SHIM" "$TMP/bin/docker"` —
# no test names the file at a command position. entrypoint.sh is named by five
# assertions, every one of them a grep or a `bash -n`.
shim_verdict="$(awk -F'|' '$1 == "tests/integration/docker-shim.sh" { print $2 }' "$DERIVED")"
check "docker-shim.sh is EXECUTED (resolved through the symlink, not the name)" \
  "EXECUTED" "$shim_verdict"
# bash-dialect-lint.sh is reachable ONLY through a `p_timeout 10 bash …`
# prefix: its oracle bounds every invocation (backlog F22) and the one bare
# mention is a `bash -n`, which is a parse, not a run. A prefix that RUNS the
# rest of the line has to be walked through or the invocation behind it stops
# being at a command position and disappears — this exact row flipped to
# NOT-EXECUTED the moment the bounds went in, and the aggregate --check caught
# it. Named here so the next time it is named rather than inferred.
lint_verdict="$(awk -F'|' '$1 == "tests/bash-dialect-lint.sh" { print $2 }' "$DERIVED")"
check "bash-dialect-lint.sh is EXECUTED (seen through the p_timeout prefix, not around it)" \
  "EXECUTED" "$lint_verdict"
ep_verdict="$(awk -F'|' -v f="$T_ENTRYPOINT" '$1 == f { print $2 }' "$DERIVED")"
check "$T_ENTRYPOINT is NOT-EXECUTED (bash -n and grep are not execution)" \
  "NOT-EXECUTED" "$ep_verdict"

# The two run-time shapes, asserted where they actually bite. Both were blind
# spots until 2026-08-19 (backlog F33), and both hid the ONE test whose whole
# purpose is the target: tests/lib-verify-repo.sh is reached by its dedicated
# oracle only through `printf 'source %q\n' … >> "$h"`, and sandbox.sh is
# reached by tests/test-parsers.sh only as the argument of a `bash -c` body
# that sources "$1". Named as ORACLES, not just as verdicts: the file was
# already EXECUTED by other tests, so a verdict check would have stayed green
# through the whole blind spot.
executors() { awk -F'|' -v f="$1" '$1 == f { print $3 }' "$DERIVED"; }
case ",$(executors "$T_LIBVERIFY")," in
  *,test-lib-verify-repo.sh,*) pass "$T_LIBVERIFY names its dedicated oracle (reached only via printf-into-a-harness)" ;;
  *) fail "$T_LIBVERIFY does not name test-lib-verify-repo.sh among its executors (got: $(executors "$T_LIBVERIFY"))" ;;
esac
case ",$(executors "${ENGINE_REL}sandbox.sh")," in
  *,test-parsers.sh,*) pass "${ENGINE_REL}sandbox.sh names test-parsers.sh (reached only as a bash -c argument)" ;;
  *) fail "${ENGINE_REL}sandbox.sh does not name test-parsers.sh among its executors (got: $(executors "${ENGINE_REL}sandbox.sh"))" ;;
esac

# ── 3. GATE 1: an executed file with no row fails, BY NAME ────────────────────
f1="$TMP/gate1.conf"
grep -v "^${RE_TOOLSLIB}|" "$CONF" > "$f1"
check "fixture: gate1.conf drops the $T_TOOLSLIB row" \
  "$(( $(grep -c . "$CONF") - 1 ))" "$(grep -c . "$f1")"
gate "$f1"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 1: a dropped row for an executed target fails the gate" \
  || fail "gate 1: a dropped row for an executed target passed the gate"
grep -q "^ERROR: $T_TOOLSLIB is EXECUTED by the hermetic suite" <<<"$out" \
  && pass "gate 1: the failure NAMES the missing file" \
  || fail "gate 1: the failure did not name $T_TOOLSLIB (output: $out)"

# ── 4. GATE 2: a GREPPED-ONLY file registered as an active target is rejected ──
f2="$TMP/gate2.conf"
sed "s@^${RE_ENTRYPOINT}|GREPPED-ONLY|test-entrypoint-wiring\\.sh\$@${T_ENTRYPOINT}|EXECUTED-WHOLE|test-entrypoint-wiring.sh@" "$CONF" > "$f2"
grep -q "^${RE_ENTRYPOINT}|EXECUTED-WHOLE|" "$f2" \
  && pass "fixture: gate2.conf promotes $T_ENTRYPOINT to an active mutation target" \
  || fail "fixture: gate2.conf did not promote $T_ENTRYPOINT"
gate "$f2"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 2: a GREPPED-ONLY file registered as a mutation target fails the gate" \
  || fail "gate 2: a GREPPED-ONLY file registered as a mutation target passed the gate"
grep -q "$T_ENTRYPOINT is classified EXECUTED-WHOLE but the hermetic suite never EXECUTES it" <<<"$out" \
  && pass "gate 2: the failure names the file and says why (never executed)" \
  || fail "gate 2: the failure did not explain the misclassification (output: $out)"

# The mirror: an executed file mislabelled GREPPED-ONLY is also caught, or the
# map could hide a target by demoting it instead of deleting its row.
f2b="$TMP/gate2b.conf"
sed "s@^${RE_TOOLSLIB}|EXECUTED-WHOLE|test-tools-d\\.sh\$@${T_TOOLSLIB}|GREPPED-ONLY|test-tools-d.sh@" "$CONF" > "$f2b"
gate "$f2b"; out="$gate_out"
grep -q "$T_TOOLSLIB is classified GREPPED-ONLY but the hermetic suite EXECUTES it" <<<"$out" \
  && pass "gate 2 (mirror): demoting an executed target to GREPPED-ONLY fails the gate" \
  || fail "gate 2 (mirror): demoting an executed target to GREPPED-ONLY passed (output: $out)"

# ── 5. GATE 3: a nonexistent oracle fails loudly ─────────────────────────────
# The premise first: run-all.sh EXITS 2 when its filter matches nothing, so a
# typo'd oracle would run zero tests and report every mutant killed. That is the
# quiet-success failure mode this gate exists to make impossible.
bash "$RUNALL" no-such-oracle-zzz >/dev/null 2>&1
check "premise: run-all.sh exits 2 when its filter selects no test" "2" "$?"

f3="$TMP/gate3.conf"
sed "s@^${RE_TOOLSLIB}|EXECUTED-WHOLE|test-tools-d\\.sh\$@${T_TOOLSLIB}|EXECUTED-WHOLE|test-tools-dd.sh@" "$CONF" > "$f3"
grep -q "^${RE_TOOLSLIB}|EXECUTED-WHOLE|test-tools-dd\\.sh\$" "$f3" \
  && pass "fixture: gate3.conf misspells the oracle as test-tools-dd.sh" \
  || fail "fixture: gate3.conf did not misspell the oracle"
[[ ! -f "$REPO_DIR/tests/test-tools-dd.sh" ]] \
  && pass "fixture: tests/test-tools-dd.sh really does not exist" \
  || fail "fixture: tests/test-tools-dd.sh exists, so the typo case proves nothing"
gate "$f3"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 3: a misspelled oracle fails the gate" \
  || fail "gate 3: a misspelled oracle passed the gate"
grep -q 'names oracle test-tools-dd.sh, which does not exist' <<<"$out" \
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
grep -qE 'names oracle test-alpha.sh, which run-all.sh selects 2 test\(s\) for' <<<"$out" \
  && pass "gate 3 (ambiguity): the failure reports how many tests the oracle selects" \
  || fail "gate 3 (ambiguity): the failure did not report the selection count (output: $out)"

# ── 5b. GATE 3 over a SET: every member is checked, not just the first ───────
# The oracle field names one or more tests. Each of the three failures below is
# demonstrated with the flaw in the SECOND member: a gate that validated only
# the first would pass all three, and the row would then claim coverage from a
# test that contributes nothing. The synthetic tests/ dir is reused so the
# fixtures differ only in the conf.
# Its OWN synthetic repo, not $AMB's: that one deliberately holds a
# name-collision pair so `test-alpha.sh` selects two tests, which would make
# every case below fail for the wrong reason. Here no name is a substring of
# another.
SET="$TMP/oracleset"
mkdir -p "$SET/tests"
printf '#!/usr/bin/env bash\n' > "$SET/tests/test-one.sh"
printf '#!/usr/bin/env bash\n' > "$SET/tests/test-two.sh"
printf '#!/usr/bin/env bash\n' > "$SET/target.sh"
# Both members are executors here, so the control below isolates the SET
# grammar. Gate 5 further down is where a non-executing member is the subject.
printf 'target.sh|EXECUTED|test-one.sh,test-two.sh\n' > "$SET/set.derived"
set_gate() {  # $1=oracle field → sets gate_out/gate_rc against the synthetic repo
  printf 'target.sh|EXECUTED-WHOLE|%s\n' "$1" > "$SET/set.conf"
  gate_out="$(FALSIFY_REPO="$SET" FALSIFY_TESTS_DIR="$SET/tests" FALSIFY_DERIVED="$SET/set.derived" \
              bash "$DERIVE" --check "$SET/set.conf" 2>&1)"; gate_rc=$?
}

# The control FIRST: a well-formed two-member set must PASS, or every failure
# below could be the gate rejecting the comma rather than the flaw.
set_gate "test-one.sh,test-two.sh"
check "gate 3 (set): a well-formed two-oracle row passes" "0" "$gate_rc"

set_gate "test-one.sh,test-zzz.sh"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 3 (set): a nonexistent SECOND oracle fails the gate" \
  || fail "gate 3 (set): a nonexistent second oracle passed the gate (output: $gate_out)"
grep -q 'names oracle test-zzz.sh, which does not exist' <<<"$gate_out" \
  && pass "gate 3 (set): the failure names the second oracle, not the first" \
  || fail "gate 3 (set): the failure did not name test-zzz.sh (output: $gate_out)"

set_gate "test-one.sh,test-one.sh"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 3 (set): the same oracle named twice fails the gate" \
  || fail "gate 3 (set): a repeated oracle passed the gate (output: $gate_out)"
grep -q 'names oracle test-one.sh twice' <<<"$gate_out" \
  && pass "gate 3 (set): the failure says the repetition buys no coverage" \
  || fail "gate 3 (set): the failure did not report the repetition (output: $gate_out)"

# A TRAILING COMMA is the one malformed shape that would otherwise pass
# SILENTLY: `IFS=, read -a` drops a trailing empty member, so `a.sh,` splits to
# one element and the author's second oracle disappears with no complaint. That
# is why the field's shape is checked before it is split, and why this case is
# here rather than left to the per-member loop.
set_gate "test-one.sh,"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 3 (set): a trailing comma fails the gate" \
  || fail "gate 3 (set): a trailing comma passed the gate (output: $gate_out)"
grep -q 'has a malformed oracle field' <<<"$gate_out" \
  && pass "gate 3 (set): the failure names the field shape, not a missing test" \
  || fail "gate 3 (set): the trailing comma was not reported as a shape error (output: $gate_out)"
# The premise that makes the shape check load-bearing, asserted rather than
# asserted-about: the split really does drop the empty member.
IFS=',' read -r -a _drop <<<"test-one.sh,"
check "premise: IFS=, read -a silently drops a trailing empty member" "1" "${#_drop[@]}"

set_gate "test-one.sh, test-two.sh"
grep -q 'has a malformed oracle field' <<<"$gate_out" \
  && pass "gate 3 (set): a space after the comma fails the gate" \
  || fail "gate 3 (set): a space after the comma passed the gate (output: $gate_out)"

# A GLOB in the field is refused by the same shape check, and that is why the
# character class is a whitelist rather than "anything but a comma or a space".
# `test-*.sh` would otherwise reach the per-member loop, where an unquoted split
# expands it against the working directory — so what the row asked for and what
# the runner ran would depend on where the runner was invoked from.
set_gate "test-one.sh,test-*.sh"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 3 (set): a glob in the oracle field fails the gate" \
  || fail "gate 3 (set): a glob in the oracle field passed the gate (output: $gate_out)"
grep -q 'has a malformed oracle field' <<<"$gate_out" \
  && pass "gate 3 (set): the glob is refused by shape, before anything expands it" \
  || fail "gate 3 (set): the glob was not refused by the shape check (output: $gate_out)"

# ── 5c. GATE 5: an oracle that never EXECUTES the target ─────────────────────
# The quiet failure this closes: a real, uniquely-selecting test that simply
# does not run the file. Gate 3 passes it — the test exists — and the tier then
# mutates the target and watches every mutant SURVIVE, because nothing ran the
# mutated code. Each survivor is then owed a ledger entry classified GAP, and
# the ledger fills up with debt for coverage the row never had.
#
# Synthetic first, so the rule is stated with nothing else in the picture: two
# real tests, one of which the derivation records as an executor and one of
# which it does not.
set_gate "test-two.sh"
[[ "$gate_rc" -ne 0 ]] \
  && fail "gate 5: test-two.sh IS a recorded executor here, so this must pass — the fixture is wrong (output: $gate_out)" \
  || pass "gate 5 (control): an oracle the derivation DOES observe executing the target passes"
printf 'target.sh|EXECUTED|test-one.sh\n' > "$SET/set.derived"
set_gate "test-two.sh"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 5: an existing, uniquely-selecting oracle that never executes the target fails the gate" \
  || fail "gate 5: a non-executing oracle passed the gate (output: $gate_out)"
grep -q 'never observes EXECUTING it' <<<"$gate_out" \
  && pass "gate 5: the failure says the oracle never executes the target" \
  || fail "gate 5: the failure did not say the oracle never executes the target (output: $gate_out)"
grep -q 'it is executed by: test-one.sh' <<<"$gate_out" \
  && pass "gate 5: the failure names who DOES execute it, so the row can be repaired" \
  || fail "gate 5: the failure did not name the real executors (output: $gate_out)"
printf 'target.sh|EXECUTED|test-one.sh,test-two.sh\n' > "$SET/set.derived"

# And on the REAL map, because the synthetic repo cannot show the rule catching
# a plausible mistake. tests/lib-verify-repo.sh's oracle is swapped for
# tests/test-portability.sh: a real test, selecting exactly one, that this
# target's derivation does not list — precisely the row a tired author writes.
f5="$TMP/gate5.conf"
sed "s@^${T_LIBVERIFY//./\\.}|EXECUTED-WHOLE|test-lib-verify-repo\\.sh@${T_LIBVERIFY}|EXECUTED-WHOLE|test-portability.sh@" "$CONF" > "$f5"
grep -q "^${T_LIBVERIFY//./\\.}|EXECUTED-WHOLE|test-portability\\.sh" "$f5" \
  && pass "fixture: gate5.conf points $T_LIBVERIFY at test-portability.sh" \
  || fail "fixture: gate5.conf was not rewritten — the assertion below would be vacuous"
[[ -f "$REPO_DIR/tests/test-portability.sh" ]] \
  && pass "fixture: tests/test-portability.sh is a REAL test, so gate 3 cannot be what fires" \
  || fail "fixture: tests/test-portability.sh does not exist, so this would fire gate 3 instead"
case ",$(executors "$T_LIBVERIFY")," in
  *,test-portability.sh,*) fail "fixture: test-portability.sh IS an executor of $T_LIBVERIFY, so the case proves nothing" ;;
  *) pass "fixture: test-portability.sh is not among $T_LIBVERIFY's executors" ;;
esac
gate "$f5"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 5: the real map fails when a row names a real but non-executing oracle" \
  || fail "gate 5: the real map accepted a non-executing oracle (output: $out)"
grep -q "names oracle test-portability.sh, which the derivation never observes EXECUTING it" <<<"$out" \
  && pass "gate 5: the real-map failure names the row's target and the useless oracle" \
  || fail "gate 5: the real-map failure did not name test-portability.sh (output: $out)"

# ── 6. GATE 4: EXECUTED-PARTIAL with an empty 4th field ──────────────────────
f4="$TMP/gate4.conf"
{ cat "$CONF"; printf '%s|EXECUTED-PARTIAL|test-parsers.sh|\n' "$T_SBCOMMON"; } \
  | grep -v "^#DEFERRED|${RE_SBCOMMON}|" > "$f4"
gate "$f4"; out="$gate_out"
[[ "$gate_rc" -ne 0 ]] \
  && pass "gate 4: an EXECUTED-PARTIAL row with an empty function list fails the gate" \
  || fail "gate 4: an EXECUTED-PARTIAL row with an empty function list passed the gate"
grep -q "$T_SBCOMMON is EXECUTED-PARTIAL with an empty function list" <<<"$out" \
  && pass "gate 4: the failure names the file and the missing 4th field" \
  || fail "gate 4: the failure did not name the empty function list (output: $out)"

# A `-` placeholder is empty too — the deferred rows use it for EXECUTED-WHOLE,
# so a copy-paste into an EXECUTED-PARTIAL row must not slip through.
f4b="$TMP/gate4b.conf"
{ cat "$CONF"; printf '%s|EXECUTED-PARTIAL|test-parsers.sh|-\n' "$T_SBCOMMON"; } \
  | grep -v "^#DEFERRED|${RE_SBCOMMON}|" > "$f4b"
gate "$f4b"; out="$gate_out"
grep -q "$T_SBCOMMON is EXECUTED-PARTIAL with an empty function list" <<<"$out" \
  && pass "gate 4: a '-' function list counts as empty" \
  || fail "gate 4: a '-' function list was accepted (output: $out)"

# Naming functions is only meaningful if the names are real.
f4c="$TMP/gate4c.conf"
# Rewrite whatever the row's 4th field currently is, rather than a literal copy
# of it. The old version matched the function list verbatim, so the day that
# list changed the sed became a no-op, gate4c.conf was identical to the real
# map, the gate passed — and the FAILURE MESSAGE BLAMED THE GATE. Caught when
# cmd_rm joined the list (backlog F1).
sed -E "s@^#DEFERRED\|${RE_INSTALLTOOLS}\|EXECUTED-PARTIAL\|([^|]*)\|[^|]*@#DEFERRED|${T_INSTALLTOOLS}|EXECUTED-PARTIAL|\1|asset_name,no_such_function@" "$CONF" > "$f4c"
# THE FIXTURE'S OWN PREMISE, asserted the way gate 5 already asserts its own.
# Without this the case above could only ever fail for the wrong reason.
grep -q "^#DEFERRED|${RE_INSTALLTOOLS}|EXECUTED-PARTIAL|[^|]*|asset_name,no_such_function" "$f4c" \
  && pass "fixture: gate4c.conf names a function that does not exist in $T_INSTALLTOOLS" \
  || fail "fixture: gate4c.conf was not rewritten — the assertion below would be vacuous"
gate "$f4c"; out="$gate_out"
grep -q "naming function no_such_function, which is not defined in $T_INSTALLTOOLS" <<<"$out" \
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
grep -q 'has an empty reason — an empty reason suppresses nothing' <<<"$out" \
  && pass "the empty-reason failure says the reason is required" \
  || fail "the empty-reason failure was not reported (output: $out)"
grep -qE '^ERROR: tests/run-all\.sh .*has no row' <<<"$out" \
  && pass "an empty reason leaves the target UNMAPPED, not excluded" \
  || fail "an empty reason still suppressed the target (output: $out)"

# A deferral must state why, for the same reason.
f5b="$TMP/defer-empty.conf"
sed "s@^#DEFERRED|${RE_GROUPSH}|EXECUTED-WHOLE|test-group-lifecycle\\.sh|-|.*\$@#DEFERRED|${T_GROUPSH}|EXECUTED-WHOLE|test-group-lifecycle.sh|-|@" "$CONF" > "$f5b"
gate "$f5b"; out="$gate_out"
grep -q "#DEFERRED| for $T_GROUPSH has an empty reason" <<<"$out" \
  && pass "a #DEFERRED| row with an empty reason fails the gate" \
  || fail "a #DEFERRED| row with an empty reason passed the gate (output: $out)"

# ── 8. Structural gates: duplicates, unknown categories, phantom targets ──────
f6="$TMP/dup.conf"
{ cat "$CONF"; printf '%s|EXECUTED-WHOLE|test-tools-d.sh\n' "$T_TOOLSLIB"; } > "$f6"
gate "$f6"; out="$gate_out"
grep -q "duplicate row for $T_TOOLSLIB" <<<"$out" \
  && pass "a duplicate row for the same target fails the gate" \
  || fail "a duplicate row for the same target passed the gate (output: $out)"

f7="$TMP/badcat.conf"
sed "s@^${RE_TOOLSLIB}|EXECUTED-WHOLE|test-tools-d\\.sh\$@${T_TOOLSLIB}|EXECUTED|test-tools-d.sh@" "$CONF" > "$f7"
gate "$f7"; out="$gate_out"
grep -q "$T_TOOLSLIB has unknown category EXECUTED " <<<"$out" \
  && pass "an unknown category fails the gate" \
  || fail "an unknown category passed the gate (output: $out)"

f8="$TMP/phantom.conf"
{ cat "$CONF"; printf 'no-such-script.sh|EXECUTED-WHOLE|test-tools-d.sh\n'; } > "$f8"
gate "$f8"; out="$gate_out"
grep -q 'no-such-script.sh is not an in-scope candidate' <<<"$out" \
  && pass "a row naming a file that is not a candidate fails the gate" \
  || fail "a row naming a phantom target passed the gate (output: $out)"

# A GREPPED-ONLY row must not carry a function list either — the mutation unit
# only shrinks below the file for EXECUTED-PARTIAL.
f9="$TMP/funcs-on-whole.conf"
sed "s@^${RE_TOOLSLIB}|EXECUTED-WHOLE|test-tools-d\\.sh\$@${T_TOOLSLIB}|EXECUTED-WHOLE|test-tools-d.sh|tools_list_names@" "$CONF" > "$f9"
gate "$f9"; out="$gate_out"
grep -q "$T_TOOLSLIB is EXECUTED-WHOLE but lists functions" <<<"$out" \
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
         aliased.sh var-path.sh transitive.sh never-mentioned.sh \
         printf-sourced.sh printf-prose.sh argv-sourced.sh argv-not-dragged.sh; do
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
printf 'source %q\n' "$REPO_DIR/printf-sourced.sh" >> "$BIN/harness.sh"
bash "$BIN/harness.sh"
printf 'source %s is where it lives\n' "$REPO_DIR/printf-prose.sh" >&2
bash -c 'src="$1"; source "$src"' _ "$REPO_DIR/argv-sourced.sh"
bash -c 'source /nowhere/fixed.sh' _ "$REPO_DIR/argv-not-dragged.sh"
cat > "$REPO_DIR/written-stub.sh" <<'INNER'
bash /elsewhere/heredoc-named.sh
source /elsewhere/heredoc-named.sh
INNER
FIXEOF
git -C "$FIX" init -q 2>/dev/null
git -C "$FIX" add -A 2>/dev/null

synth_want="$(cat <<'WANT'
aliased.sh|EXECUTED
argv-not-dragged.sh|NOT-EXECUTED
argv-sourced.sh|EXECUTED
grepped.sh|NOT-EXECUTED
heredoc-named.sh|NOT-EXECUTED
never-mentioned.sh|NOT-EXECUTED
parsed-only.sh|NOT-EXECUTED
printf-prose.sh|NOT-EXECUTED
printf-sourced.sh|EXECUTED
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
# The two run-time shapes. Each is paired with the negative that says what the
# rule is keyed on, because a rule that fires on everything would satisfy the
# positive alone: the printf rule is keyed on the REDIRECT (the prose line
# writes the identical `source <path>` text to stderr and must not count), and
# the argv rule is keyed on the body naming its target through a VARIABLE (the
# not-dragged body names a literal path, so its own argument is just an
# argument).
check "  a path printf'd into a file as a source line is executed" \
  "EXECUTED" "$(synth_verdict printf-sourced.sh)"
check "  the same text printf'd to stderr is prose, not a script" \
  "NOT-EXECUTED" "$(synth_verdict printf-prose.sh)"
check "  an argument a bash -c body runs as \"\$1\" is executed" \
  "EXECUTED" "$(synth_verdict argv-sourced.sh)"
check "  a bash -c body that names its target literally does not drag its arguments in" \
  "NOT-EXECUTED" "$(synth_verdict argv-not-dragged.sh)"

# ── 10. The map is the tier inventory: every in-scope candidate has a row ─────
n_cand="$(grep -c . "$DERIVED")"
n_rows="$(bash "$DERIVE" --rows "$CONF" | grep -c .)"
check "every in-scope candidate has exactly one row in targets.conf" "$n_cand" "$n_rows"

active_rows="$(grep -cE '^[^#[:space:]]' "$CONF")"
[[ "$active_rows" -ge 1 ]] \
  && pass "targets.conf has $active_rows uncommented row(s) for tests/falsify/run.sh to read" \
  || fail "targets.conf has no uncommented rows — the tier would mutate nothing"

# ── no ORACLE may print the token a failure is detected by ───────────────────
# run.sh decides a mutant was noticed with
#
#   grep -qE '(^|[[:space:]])FAIL:' "$out"
#
# deliberately loose, so an indented FAIL: from a nested runner still counts. The
# cost of that looseness is that an oracle which merely MENTIONS the token in
# passing output is read as having failed — and on the PRISTINE tree that means
# "baseline not green", which skips the whole target. Thirteen mutants stopped
# being measured on 2026-08-23 because an assertion in tests/test-portability.sh
# read "…attach them to the FAIL: they explain". The run said so (SKIPPED,
# UNATTEMPTED|1|13|264, exit 1) — but only if somebody noticed 251 was not 264.
#
# Checked for ORACLES only. tests/test-falsify-run.sh names the token in three
# assertions and is entitled to: it is nobody's oracle, so it poisons nothing.
oracle_poison=""
while IFS='|' read -r _t _kind orc _rest; do
  case "$_t" in ''|'#'*) continue ;; esac
  [[ -n "$orc" ]] || continue
  # `local` is invalid outside a function; this block runs at file scope.
  saved_ifs="$IFS"; IFS=','
  for o in $orc; do
    IFS="$saved_ifs"
    [[ -f "$REPO_DIR/tests/$o" ]] || continue
    if grep -qE '(pass|fail|check|h_pass|h_fail|h_check) "[^"]*[[:space:]]FAIL:' "$REPO_DIR/tests/$o"; then
      oracle_poison="${oracle_poison:+$oracle_poison }$o"
    fi
  done
  IFS="$saved_ifs"
done < "$CONF"
if [[ -z "$oracle_poison" ]]; then
  pass "no oracle prints a whitespace-prefixed FAIL: in its own assertion text"
else
  fail "no oracle prints a whitespace-prefixed FAIL: in its own assertion text — $oracle_poison"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
