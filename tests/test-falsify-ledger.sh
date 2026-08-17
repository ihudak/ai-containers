#!/usr/bin/env bash
# tests/test-falsify-ledger.sh — the gate on tests/falsify/check-ledger.sh, the
# ratchet that stops a new surviving mutant landing silently.
#
# WHY THIS IS NOT SELF-EVIDENT: the ledger's whole value is that it FAILS. A
# check-ledger.sh that exited 0 unconditionally would look identical from the
# outside on a clean tree — which is precisely the state the repo is in most of
# the time — so the only evidence that any of its four hard failures is live
# code is watching each one fire. Each is therefore demonstrated SEPARATELY,
# against a fixture that trips that check ALONE:
#
#   1  a SURVIVOR absent from the ledger
#   2  an entry with no GAP:/EQUIVALENT: classification
#   2b an entry whose marker carries an EMPTY reason (which suppresses nothing —
#      the same trap `# dialect-lint: allow RULE-ID: reason` already guards)
#   3  an entry whose identity matches no mutant this run generated  (stale)
#   4  an entry whose mutants are now all KILLED                     (obsolete)
#
# Each demonstration asserts its own message AND the ABSENCE of the other four,
# plus a `1 problem(s)` total. A single fixture tripping several checks could
# not tell which fired, and would let three of them be dead code.
#
# FAST BY CONSTRUCTION: every fixture is a handful of lines of run.sh's
# documented STDOUT contract, written here. The real corpus is never invoked —
# it costs minutes and needs a mutation of the real tree; this test runs on
# every PR. The contract those fixtures encode is pinned separately by
# tests/test-falsify-run.sh, which drives the runner itself.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_DIR/tests/falsify/check-ledger.sh"
CONF="$REPO_DIR/tests/falsify/targets.conf"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # $1=label $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1 (expected '$2', got '$3')"; fi
}
has()    { printf '%s' "$2" | grep -qF -- "$1"; }
assert_has()  { has "$2" "$3" && pass "$1" || fail "$1 — not in output: $3"; }
assert_lacks() { has "$2" "$3" && fail "$1 — output also carried '$2'" || pass "$1"; }

[[ -f "$CHECK" ]] || { fail "tests/falsify/check-ledger.sh exists"; exit 1; }
bash -n "$CHECK" && pass "check-ledger.sh bash -n" || fail "check-ledger.sh bash -n"

# ── fixture identities ────────────────────────────────────────────────────────
# 40 hex digits, because that is what the generator emits and what the gate
# refuses to accept anything else in place of.
S='1111111111111111111111111111111111111111'   # a survivor
K='2222222222222222222222222222222222222222'   # a killed mutant
X='3333333333333333333333333333333333333333'   # no mutant carries this
ID_S="alpha.sh:logic-flip:$S"
ID_K="alpha.sh:return-flip:$K"
ID_X="alpha.sh:cmp-flip:$X"

RUN="$TMP/run.txt"
cat > "$RUN" <<EOF
RUN|repo=/fix|conf=/fix/targets.conf|jobs=1|timeout=60|operators=<default>|targets=1|mutants=2
BASELINE|alpha.sh|test-alpha.sh|PASS|11
MUTANT|SURVIVED|$ID_S|test-alpha.sh|1|10|none|12|  a && b
MUTANT|KILLED|$ID_K|test-alpha.sh|2|11|exit+failline|13|  return 1
TARGET|alpha.sh|test-alpha.sh|2|1|1|0|30
TOTAL|1|2|1|1|0|50|40
EOF

mk_ledger() { printf '%s\n' "$2" > "$TMP/$1.txt"; printf '%s' "$TMP/$1.txt"; }

CLEAN="$(mk_ledger clean "$ID_S
  alpha.sh:10  a || b
  GAP: nothing in the suite asserts the || branch's effect.")"

out=""; rc=0
run_gate() {   # $1=ledger $2=run-output → sets out/rc
  # --strict, because these demonstrations are of the REFERENCE-environment
  # contract: obsolete amnesty is fatal there and advisory on a developer host,
  # and a test of "the obsolete check fires" must run where it fires. Check B
  # (a survivor with no entry) is fatal in BOTH modes, so the other
  # demonstrations are unaffected by this flag.
  out="$(bash "$CHECK" --ledger "$1" --run-output "$2" --strict 2>/dev/null)"; rc=$?
}

# The five signatures. Every demonstration asserts exactly one of them present
# and the other four absent, which is what makes it a demonstration OF THAT
# CHECK rather than of the gate in general.
SIG_MISSING='but has no entry in'
SIG_NOCLASS='has no GAP:/EQUIVALENT:/ENV-DEPENDENT: classification'
SIG_EMPTY='an empty reason suppresses nothing'
SIG_STALE='for a mutant that no longer exists — stale, delete it'
SIG_OBSOLETE='for a mutant that is now KILLED — obsolete amnesty, delete it'

only_signature() {   # $1=label $2=the signature that must fire
  local label="$1" want="$2" s
  assert_has "$label: fires" "$want" "$out"
  for s in "$SIG_MISSING" "$SIG_NOCLASS" "$SIG_EMPTY" "$SIG_STALE" "$SIG_OBSOLETE"; do
    [[ "$s" == "$want" ]] && continue
    assert_lacks "$label: does NOT also trip '${s:0:28}…'" "$s" "$out"
  done
}

# ── 0. The clean fixture passes, or every demonstration below proves nothing ──
run_gate "$CLEAN" "$RUN"
check "a ledger matching the run exits 0" "0" "$rc"
assert_has "the clean run reports 0 problem(s), counted not implied" 'OK: 0 problem(s)' "$out"

# ── DEMONSTRATION 1: a survivor absent from the ledger ────────────────────────
D1="$(mk_ledger d1 "# a ledger that records nothing at all")"
run_gate "$D1" "$RUN"
check "1: an unrecorded survivor fails the gate" "1" "$rc"
assert_has "1: exactly one finding" '1 problem(s)' "$out"
assert_has "1: the failure names the mutant identity" "$ID_S" "$out"
only_signature "1" "$SIG_MISSING"
assert_has "1: the failure says both classifications are acceptable answers" \
  'must be classified GAP: or EQUIVALENT:' "$out"

# ── DEMONSTRATION 2: an entry with no classification ──────────────────────────
D2="$(mk_ledger d2 "$ID_S
  alpha.sh:10  a || b")"
run_gate "$D2" "$RUN"
check "2: an unclassified entry fails the gate" "1" "$rc"
assert_has "2: exactly one finding" '1 problem(s)' "$out"
assert_has "2: the failure names the mutant identity" "$ID_S" "$out"
only_signature "2" "$SIG_NOCLASS"

# ── DEMONSTRATION 2b: a marker whose reason is empty suppresses NOTHING ───────
D2B="$(mk_ledger d2b "$ID_S
  alpha.sh:10  a || b
  GAP:")"
run_gate "$D2B" "$RUN"
check "2b: an empty GAP: reason fails the gate" "1" "$rc"
assert_has "2b: exactly one finding" '1 problem(s)' "$out"
only_signature "2b" "$SIG_EMPTY"
assert_has "2b: the failure names the marker that was left empty" 'empty GAP: reason' "$out"

# The same for EQUIVALENT:, whose reason carries the heavier claim of the two.
D2C="$(mk_ledger d2c "$ID_S
  EQUIVALENT:    ")"
run_gate "$D2C" "$RUN"
assert_has "2b: an EQUIVALENT: marker with only whitespace after it is empty too" \
  'empty EQUIVALENT: reason' "$out"

# ── DEMONSTRATION 3: an entry whose mutant no longer exists (stale) ───────────
D3="$(mk_ledger d3 "$ID_S
  GAP: nothing asserts the || branch.

$ID_X
  GAP: recorded when this line still generated a cmp-flip mutant.")"
run_gate "$D3" "$RUN"
check "3: a stale entry fails the gate" "1" "$rc"
assert_has "3: exactly one finding" '1 problem(s)' "$out"
assert_has "3: the failure names the stale identity" "$ID_X" "$out"
only_signature "3" "$SIG_STALE"

# ── DEMONSTRATION 4: an entry whose mutant is now KILLED (obsolete amnesty) ───
D4="$(mk_ledger d4 "$ID_S
  GAP: nothing asserts the || branch.

$ID_K
  GAP: recorded when nothing killed this return-flip.")"
run_gate "$D4" "$RUN"
check "4: an entry for a now-killed mutant fails the gate" "1" "$rc"
assert_has "4: exactly one finding" '1 problem(s)' "$out"
assert_has "4: the failure names the obsolete identity" "$ID_K" "$out"
only_signature "4" "$SIG_OBSOLETE"

# ── The gate must not pass having checked nothing ─────────────────────────────
NORUN="$TMP/no-target.txt"
cat > "$NORUN" <<EOF
RUN|repo=/fix|conf=/fix/targets.conf|jobs=1|timeout=60|operators=<default>|targets=0|mutants=0
TOTAL|0|0|0|0|0|0|3
EOF
bash "$CHECK" --ledger "$CLEAN" --run-output "$NORUN" >/dev/null 2>&1
check "a run output with no TARGET| line is refused, not reported clean" "2" "$?"
bash "$CHECK" --ledger "$CLEAN" >/dev/null 2>&1
check "the full mode refuses to run without a run output" "2" "$?"

# ── Scope: a partial run does not condemn entries it never measured ───────────
SCOPED="$(mk_ledger scoped "$ID_S
  GAP: nothing asserts the || branch.

beta.sh:logic-flip:$X
  GAP: a survivor in a file this run did not measure.")"
run_gate "$SCOPED" "$RUN"
check "an entry for a file outside the run is not reported stale" "0" "$rc"
err="$(bash "$CHECK" --ledger "$SCOPED" --run-output "$RUN" 2>&1 >/dev/null)"
assert_has "an out-of-scope entry is reported as SKIPPED, never silently ignored" \
  "SKIPPED beta.sh:logic-flip:$X" "$err"

# ── Identity is not unique: one entry covers every mutant that shares it ──────
# Two cond-negate mutants of the SAME line differ in `seq` alone. Both survive;
# one entry answers for both, and the gate reports how many it is covering.
COLL="$TMP/collide-run.txt"
C='4444444444444444444444444444444444444444'
cat > "$COLL" <<EOF
BASELINE|alpha.sh|test-alpha.sh|PASS|11
MUTANT|SURVIVED|alpha.sh:cond-negate:$C|test-alpha.sh|1|20|none|9|  while ! read -r l || [[ -n "\$l" ]]; do
MUTANT|SURVIVED|alpha.sh:cond-negate:$C|test-alpha.sh|2|20|none|9|  while read -r l || [[ ! -n "\$l" ]]; do
TARGET|alpha.sh|test-alpha.sh|2|0|2|0|30
EOF
COLL_LED="$(mk_ledger collide "alpha.sh:cond-negate:$C
  GAP: covers both cond-negate damages of this one line.")"
run_gate "$COLL_LED" "$COLL"
check "one entry satisfies two colliding mutants sharing its identity" "0" "$rc"
run_gate "$(mk_ledger collide-empty '# nothing recorded')" "$COLL"
assert_has "the gate reports how many distinct damages an identity covers" \
  'SURVIVED (2 distinct mutant(s))' "$out"

# Backlog F10: a single-clause `if [[ X ]];` yields two cond-negate mutants
# whose mutated TEXT is byte-identical — the same damage generated twice. That
# must count ONCE, or the survivor count is inflated by a generator artefact.
DUP="$TMP/dupetext.txt"
cat > "$DUP" <<EOF
BASELINE|alpha.sh|test-alpha.sh|PASS|11
MUTANT|SURVIVED|alpha.sh:cond-negate:$C|test-alpha.sh|1|20|none|9|  if ! [[ -z "\$x" ]]; then
MUTANT|SURVIVED|alpha.sh:cond-negate:$C|test-alpha.sh|2|20|none|9|  if ! [[ -z "\$x" ]]; then
TARGET|alpha.sh|test-alpha.sh|2|0|2|0|30
EOF
run_gate "$(mk_ledger dupe-empty '# nothing recorded')" "$DUP"
assert_has "F10: two mutants with identical damage are deduplicated to one" \
  'SURVIVED (1 distinct mutant(s))' "$out"

# The dedupe key includes the mutated line, which may itself contain a `|` — the
# parser must take the 9th field VERBATIM rather than truncating at the pipe, or
# two different damages would collapse into one and a survivor would vanish.
PIPED="$TMP/piped.txt"
cat > "$PIPED" <<EOF
BASELINE|alpha.sh|test-alpha.sh|PASS|11
MUTANT|SURVIVED|alpha.sh:logic-flip:$C|test-alpha.sh|1|20|none|9|  a | grep x && b
MUTANT|SURVIVED|alpha.sh:logic-flip:$C|test-alpha.sh|2|20|none|9|  a | grep x || c
TARGET|alpha.sh|test-alpha.sh|2|0|2|0|30
EOF
run_gate "$(mk_ledger piped-empty '# nothing recorded')" "$PIPED"
assert_has "a mutated line containing '|' is read verbatim, not truncated" \
  'SURVIVED (2 distinct mutant(s))' "$out"

# An identity with one survivor and one kill is still a live entry, not amnesty.
MIXED="$TMP/mixed.txt"
cat > "$MIXED" <<EOF
BASELINE|alpha.sh|test-alpha.sh|PASS|11
MUTANT|SURVIVED|alpha.sh:cond-negate:$C|test-alpha.sh|1|20|none|9|  damage one
MUTANT|KILLED|alpha.sh:cond-negate:$C|test-alpha.sh|2|20|exit|9|  damage two
TARGET|alpha.sh|test-alpha.sh|2|1|1|0|30
EOF
run_gate "$COLL_LED" "$MIXED"
check "an identity that still has one survivor is not obsolete amnesty" "0" "$rc"

# ── A named group: N survivors of one cause cost one classification ───────────
GRP_RUN="$TMP/group-run.txt"
cat > "$GRP_RUN" <<EOF
BASELINE|alpha.sh|test-alpha.sh|PASS|11
MUTANT|SURVIVED|$ID_S|test-alpha.sh|1|10|none|9|  a || b
MUTANT|SURVIVED|$ID_X|test-alpha.sh|2|12|none|9|  x != y
TARGET|alpha.sh|test-alpha.sh|2|0|2|0|30
EOF
GRP="$(mk_ledger group "GROUP: alpha.sh's unexercised guard cluster
$ID_S
$ID_X
  GAP: one fixture would kill both; neither path is exercised at all.")"
run_gate "$GRP" "$GRP_RUN"
check "consecutive identities share one classification (a named group)" "0" "$rc"
listed="$(bash "$CHECK" --ledger "$GRP" --list 2>/dev/null)"
check "both grouped identities carry the group's classification" "2" \
  "$(printf '%s\n' "$listed" | grep -c "|GAP|alpha.sh's unexercised guard cluster|")"

# A group must be named, for the same reason a reason must be given.
UNNAMED="$(mk_ledger unnamed "GROUP:
$ID_S
  GAP: something.")"
out="$(bash "$CHECK" --ledger "$UNNAMED" --lint 2>/dev/null)"; rc=$?
check "an unnamed GROUP: fails the gate" "1" "$rc"
assert_has "the unnamed-group failure says a group must be named" \
  'GROUP: with an empty name' "$out"

# ── The identity grammar is enforced, so `file:line` cannot creep back in ─────
lint_out() { out="$(bash "$CHECK" --ledger "$1" --lint 2>/dev/null)"; rc=$?; }

lint_out "$(mk_ledger fileline "alpha.sh:42
  GAP: recorded by line number.")"
check "a file:line entry fails the gate" "1" "$rc"
assert_has "a file:line entry is rejected as not an identity" \
  'not an entry identity and not a GROUP: line' "$out"

lint_out "$(mk_ledger badop "alpha.sh:no-such-operator:$S
  GAP: something.")"
assert_has "an unknown operator is rejected" 'not an entry identity' "$out"

lint_out "$(mk_ledger shortsha "alpha.sh:logic-flip:9f3c21a
  GAP: an abbreviated digest.")"
assert_has "an abbreviated sha1 is rejected — the gate compares what run.sh prints" \
  'not an entry identity' "$out"

lint_out "$(mk_ledger dup2 "$ID_S
  GAP: one.

$ID_S
  GAP: two.")"
assert_has "a duplicate identity is rejected" "duplicate entry for $ID_S" "$out"

lint_out "$(mk_ledger orphan "  GAP: a classification belonging to nothing.")"
assert_has "indented text before any identity is rejected" \
  'indented text before any entry identity' "$out"

lint_out "$(mk_ledger twoclass "$ID_S
  GAP: one claim.
  EQUIVALENT: and a contradictory second one.")"
assert_has "two classifications on one entry are rejected" \
  'a second classification' "$out"

out="$(bash "$CHECK" --ledger "$TMP/definitely-absent.txt" --lint 2>/dev/null)"; rc=$?
check "a missing ledger file fails rather than passing vacuously" "1" "$rc"
assert_has "the missing-ledger failure names the path" 'no such ledger' "$out"

# ── The REAL ledger ───────────────────────────────────────────────────────────
out="$(bash "$CHECK" --lint 2>/dev/null)"; rc=$?
check "the real tests/falsify/survivors.txt passes its own grammar gate" "0" "$rc"
assert_has "the real ledger reports 0 problem(s), counted not implied" '0 problem(s)' "$out"

real_list="$(bash "$CHECK" --list 2>/dev/null)"
n_entries="$(printf '%s\n' "$real_list" | grep -c .)"
[[ "$n_entries" -ge 1 ]] \
  && pass "the real ledger holds $n_entries classified entr(y/ies)" \
  || fail "the real ledger is empty — the tier has produced survivors and they must be recorded"

# Every entry names a file the tier actually mutates. An identity for a file
# with no ACTIVE row would be skipped as out-of-scope by every run — silently
# unmeasured rather than loudly wrong — so it is checked here instead.
bad_files=0
while IFS='|' read -r ident _; do
  [[ -n "$ident" ]] || continue
  f="${ident%%:*}"
  awk -F'|' -v f="$f" '$0 !~ /^#/ && $1 == f && $2 ~ /^EXECUTED/ { found=1 }
                       END { exit !found }' "$CONF" \
    || { fail "ledger entry $ident names $f, which has no active row in targets.conf"; bad_files=$((bad_files+1)); }
done < <(printf '%s\n' "$real_list")
[[ "$bad_files" -eq 0 ]] \
  && pass "every real ledger entry names an ACTIVE target in targets.conf" \
  || fail "$bad_files ledger entr(y/ies) name a file the tier does not mutate"

# The tools-lib.sh survivor the tier measured is recorded, and recorded as a GAP
# — an assertion hole, not an equivalence.
#
# There WAS a second identity pinned here,
# tools-lib.sh:logic-flip:e46b949d…, the `while IFS= read … ||` line. It was
# removed on 2026-08-16 because it is no longer a survivor: F11's fix
# (test-tools-d.sh now parses a descriptor with a blank line mid-file and a final
# line with no trailing newline) kills it, and check-ledger.sh's obsolete-amnesty
# check rejects a ledger entry for a mutant that is now KILLED. It had been stale
# since that fix landed on 2026-08-14 and this loop was what held it in place —
# nothing noticed, because the gate's stale/obsolete checks need a real
# --run-output and nothing yet feeds it one (F13).
#
# THE LESSON, not just the correction: a survivor identity written down in a test
# is the ledger's content stated a second time, and this repo's own rule is that
# a fact stated twice eventually disagrees with itself. Do not re-grow this list.
# One pin is kept deliberately — the tier's oldest continuously-measured survivor,
# as a canary that the ledger is real output rather than a fixture — and the
# pin's justification has to be re-measured, not assumed, whenever it fails.
want="tools-lib.sh:return-flip:f128fd8d7318dc079eeec1117ae9a4525988fac4"
line="$(printf '%s\n' "$real_list" | grep -F "$want|" || true)"
if [[ -z "$line" ]]; then
  fail "the measured survivor $want is missing from the ledger"
# RE-MEASURED TWICE ON 2026-08-17, and the second re-measurement undid the
# first. The pin failed in the morning; the classification was moved
# GAP -> ENV-DEPENDENT on the reading that /etc/ai-containers/tools.d exists in
# a sandbox and not on a runner. That reading was wrong: test-tools-d.sh never
# leaves TOOLS_D_DIR unset or pointing at a missing path, so tools-lib.sh's
# /etc default is never consulted and the guard is unreachable everywhere. The
# CI kill that prompted the move came from the shared-/tmp race this branch
# fixes — concurrent copies of this very oracle failing each other — and with
# that fixed, CI and the container agree again (209/36/4 both).
#
# The lesson the instruction above was aiming at, sharpened: re-measuring is not
# enough on its own. Two machines disagreeing is a fact; WHICH difference
# between them is operative is a hypothesis, and the visible one was not it.
#
# The pin stays sharp rather than being loosened to "any classification": if
# the killing assertion F11 describes is ever written, this becomes KILLED
# everywhere, the entry should be DELETED, and this assertion fires again to
# make someone re-measure. That is the canary doing its job, not noise.
elif [[ "$line" != "$want|GAP|"* ]]; then
  fail "$want is recorded as ${line#"$want|"}, not a GAP — re-measure before changing this pin"
else
  pass "the measured survivor ${want##*:} is recorded as a GAP with a reason"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
