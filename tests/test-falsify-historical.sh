#!/usr/bin/env bash
# tests/test-falsify-historical.sh — the mutation tier's SHIP GATE, and its
# honest scorecard.
#
# tests/falsify/ exists because SIX unfalsifiable checks shipped in this repo.
# A tool that cannot catch the bugs that motivated it is decoration, so this
# file reconstructs the four of those six that are recoverable from git and
# MEASURES, against the real harness, whether the tier would have surfaced each
# one. The method per hole:
#
#   1  rebuild the DEFECTIVE version of the test in a scratch tree — the same
#      assertion, in its pre-fix form;
#   2  prove the reconstruction actually re-opened the hole, by EFFECT, naming
#      the exact exit status or output line the defect lives in. A
#      reconstruction that did not apply looks identical to one that did and
#      would make everything below vacuous;
#   3  require the defective version GREEN on the unmutated tree — the harness
#      refuses a target whose oracle is not green, so a red baseline means the
#      measurement never happened;
#   4  run the mutant through the harness's OWN seeder, oracle runner and
#      verdict predicates (this file SOURCES tests/falsify/run.sh rather than
#      restating them) against BOTH the defective and the fixed test. SURVIVED
#      against the defective one and KILLED against the fixed one is the only
#      pair that means "the tier would have found this". Without the second
#      half you are measuring the harness's inability to kill anything.
#
# ── THE RESULT, AND WHY THIS FILE IS GREEN WHILE REPORTING IT ────────────────
# One of the four is caught. That is the measurement, not a target:
#
#   #2  44676f5  a counter its `exit` never read     NOT CAUGHT — out of remit
#   #3  421d25d  launcher_prepare's unreachable half CAUGHT (SURVIVED→KILLED)
#   #4  9b64bd3  a conjunct an unrelated line served NOT CAUGHT — out of reach
#   #6  7d1970f  a stdout assertion fed both streams NOT CAUGHT — out of reach
#
# Each verdict below is PINNED, not asserted as an aspiration. This file is
# green when the harness's detection power is exactly what is recorded here,
# and goes red the moment it changes IN EITHER DIRECTION — an operator added
# later that reaches #4 or #6 fails this file and forces the record up. Writing
# it to demand four SURVIVED verdicts would simply be red forever while
# teaching nobody which mechanism is missing; writing it to demand nothing
# would be the false green this repo keeps finding. So each NOT-CAUGHT row also
# carries the measured REASON, as an assertion:
#
#   #4  the value the assertion reads (`error:   %s` in assert_runs) arrives
#       through a command substitution inside a double-quoted string. NO
#       operator in the generator can damage it: that line yields ZERO mutants
#       under the FULL operator set. The two mutants that do reach the
#       assertion break sibling assertions present in BOTH versions, so both
#       versions kill them. Swept exhaustively while writing this: all 190
#       mutants of tests/integration/lib.sh, identical verdicts (73 killed /
#       117 survived) against the defective and the fixed test — zero
#       discrimination.
#   #6  `stream-flip` is ONE-DIRECTIONAL: `>&2` → `>&1`. The historical defect
#       was the opposite move — a line that belongs on stdout printed to
#       stderr — and the fixed line carries no redirection token at all, so
#       there is nothing for the operator to flip. Swept exhaustively: 55
#       default-operator mutants plus all 19 stream-flip mutants of
#       tests/integration/mutate.sh, identical verdicts, zero discrimination.
#   #2  is different in kind: it is not an assertion gap. The defective test
#       PRINTS its FAIL: line and only its exit status lies, and the harness's
#       kill disjunction deliberately does not trust an exit status (see
#       run.sh's header, which cites this very bug). So the tier is IMMUNE to
#       #2 rather than blind to it — and that claim is falsified here, not
#       asserted: strip run-all.sh's FAIL:-line guard (layer 2 of the same fix
#       commit) AND run.sh's falsify_has_fail_line, and the survivor appears.
#
# ── COST ─────────────────────────────────────────────────────────────────────
# This file runs REAL oracles — about a dozen of them, ~45 s total, which makes
# it the slowest hermetic test here. It is still hermetic: no docker, no
# network. Everything happens in mktemp -d; the real working tree is only ever
# READ, and its HEAD and porcelain are compared before and after.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
GEN="$TESTS_DIR/falsify/generate.sh"
RUN="$TESTS_DIR/falsify/run.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {   # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
finish() { printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

for f in "$GEN" "$RUN"; do
  [[ -f "$f" ]] || { fail "$f exists — the tier is not here to be measured"; finish; }
done

# The harness itself, sourced: its tree seeder, its oracle runner and its two
# verdict predicates are the subject, so restating any of them here would test
# the restatement. Sourcing runs nothing (run.sh guards on BASH_SOURCE).
# shellcheck source=./falsify/run.sh
source "$RUN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── the fix commits, and the file each one repaired ───────────────────────────
SHA_H2=44676f5   # test-integration-lib.sh's pass/fail collision
SHA_H3=421d25d   # launcher_prepare's refusal check could not reach its branch
SHA_H4=9b64bd3   # a conjunct satisfied by an unrelated line
SHA_H6=7d1970f   # the rollback's "Reverted" line belongs on stdout

LIB_REL="tests/integration/lib.sh"
MUTATE_REL="tests/integration/mutate.sh"
TIL_REL="tests/test-integration-lib.sh"
TMUT_REL="tests/test-mutations.sh"
LIB_ORACLE="test-integration-lib.sh"
MUT_ORACLE="test-mutations.sh"

# The mutants, by LEDGER IDENTITY (<file>:<operator>:<sha1-of-trimmed-line>),
# never file:line. A recorded identity that no longer exists must be LOUD, the
# same rule the survivor ledger applies to a stale entry — so each is looked up
# in the generator's real output below and required to match exactly once.
M3_OP=logic-flip;  M3_SHA=aadc9f013f0877f1d60d52f05d519091f9654ae3  # lib.sh's `-z … || ! -x …` guard
M4_OP=cond-negate; M4_SHA=ed4d2f87a85b4b45a0255a7629484214543301c5  # assert_runs' `if out="$(docker exec …)"`
M6_OP=stream-flip; M6_SHA=e8a08f78ecf05f641b573202d42ba00a78d7404b  # mutate.sh's ROLLBACK FAILED line

ALL_OPS="cond-negate,logic-flip,return-flip,cmp-flip,stream-flip"
ORACLE_TIMEOUT=90
ORACLE_LOG="$TMP/oracle.log"

# ── isolation, recorded from both ends ────────────────────────────────────────
HEAD_BEFORE="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
PORC_BEFORE="$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"

# ── the scratch trees ─────────────────────────────────────────────────────────
# CACHE is the pristine copy every mutant and every restore is taken FROM;
# WORK is the only tree anything is ever written into.
CACHE="$TMP/pristine"
WORK="$TMP/work"
if falsify_seed_tree "$REPO_DIR" "$CACHE"; then
  pass "a pristine scratch tree was seeded from the repo (tracked files + .git)"
else
  fail "a pristine scratch tree was seeded — nothing below can run"
  finish
fi
reseed_work() { rm -rf "$WORK"; cp -a "$CACHE" "$WORK" 2>/dev/null || cp -R "$CACHE" "$WORK"; }
if reseed_work && [[ -f "$WORK/$LIB_REL" ]]; then
  pass "a worker tree was seeded from it"
else
  fail "a worker tree was seeded from it"
  finish
fi

restore_from_cache() { cp -Pp "$CACHE/$1" "$WORK/$1"; }

# ── selecting a mutant from the generator's REAL output ───────────────────────
# Identity is not unique on its own (two `&&` on one line share operator and
# sha1), so a selection that matches anything other than exactly one row is a
# hard failure rather than a silent first-match.
MUT_LINE=""; MUT_TEXT=""; MUT_IDENT=""
select_mutant() {   # <target-rel> <operator> <sha1> <operators> <label>
  local target="$1" op="$2" sha="$3" ops="$4" label="$5" n
  local -a rows=()
  mapfile -t rows < <(FALSIFY_OPERATORS="$ops" bash "$GEN" "$CACHE/$target" 2>/dev/null \
                      | awk -F'\t' -v o="$op" -v s="$sha" '$1 == o && $3 == s')
  n="${#rows[@]}"
  MUT_LINE=""; MUT_TEXT=""; MUT_IDENT="$target:$op:$sha"
  if [[ "$n" != "1" ]]; then
    fail "$label: the recorded mutant $MUT_IDENT is generated exactly once (got $n — a recorded identity that no longer exists must be loud, not skipped)"
    return 1
  fi
  IFS=$'\t' read -r _ MUT_LINE _ MUT_TEXT <<< "${rows[0]}"
  pass "$label: the recorded mutant EXISTS in the generator's output ($MUT_IDENT, line $MUT_LINE)"
  return 0
}

apply_mutant() {   # <target-rel> <lineno> <text>
  falsify_write_mutant "$CACHE/$1" "$WORK/$1" "$2" "$3"
}

# ── one oracle run, judged by the HARNESS's own predicates ────────────────────
# F12: a mutant killed ONLY by a timeout is a mutant whose oracle HUNG and
# never asserted anything. That is not a proven kill, so it is reported as its
# own verdict rather than folded into KILLED.
VERDICT=""; SIGNAL=""
run_oracle() {   # <oracle-name>
  falsify_run_oracle "$WORK" "$1" "$ORACLE_LOG" "$ORACLE_TIMEOUT"
  falsify_verdict "$FALSIFY_RC" "$ORACLE_LOG" "$FALSIFY_TIMED_OUT"
  VERDICT="$FALSIFY_VERDICT"; SIGNAL="$FALSIFY_SIGNAL"
  if [[ "$SIGNAL" == "timeout" ]]; then
    VERDICT="UNPROVEN"
    fail "  the oracle HUNG and asserted nothing (signal=timeout alone) — UNPROVEN, not a kill (backlog F12)"
  fi
}

# Green on the unmutated tree, or nothing measured below means anything.
require_green_baseline() {   # <label> <oracle>
  restore_from_cache "$1" >/dev/null 2>&1 || true
  run_oracle "$2"
  if [[ "$VERDICT" == "SURVIVED" ]]; then
    pass "$3: the reconstructed defective test is GREEN on the unmutated tree"
    return 0
  fi
  fail "$3: the reconstructed defective test is GREEN on the unmutated tree (verdict=$VERDICT signal=$SIGNAL) — the harness would refuse this target, so its measurement never happened"
  sed 's/^/       /' "$ORACLE_LOG" | grep -E 'FAIL:' | head -5
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. Rebuilding the four defective tests
# ══════════════════════════════════════════════════════════════════════════════
# Two mechanisms, chosen per hole by what git can still do:
#
#   REVERSE PATCH   `git show <fix> -- <test> | git apply -R`, run inside the
#                   scratch tree. Exact, and LOUD when the surrounding code has
#                   drifted — the same reason tests/integration/mutations/ ships
#                   patches rather than seds. Used for #4 and #6, where it still
#                   applies cleanly.
#   TARGETED SPLICE for #2 and #3, where it no longer applies: the fix commits
#                   are five days and several hundred lines of unrelated drift
#                   back, and `git apply -R --3way` resolves to a conflicted
#                   tree, not a pre-fix file. Restoring the whole pre-fix FILE
#                   is not an option either — both of those pre-fix files call
#                   lib.sh helpers that have since been renamed
#                   (_ruby_reconcile_done → _it_ruby_reconcile_done), so they
#                   are four assertions RED against today's lib.sh before any
#                   mutant exists, and a red baseline is a measurement that
#                   never ran. The splice therefore re-opens the HOLE inside
#                   today's file, which is the thing being measured, and every
#                   splice below asserts it applied.

PRE_H2="$TMP/prefix-h2.sh"
PRE_H3="$TMP/prefix-h3.sh"
PRE_H4="$TMP/prefix-h4.sh"
PRE_H6="$TMP/prefix-h6.sh"

# ── #2: the pass/fail collision, restored by un-renaming the helpers ──────────
# 44676f5 renamed this file's own pass/fail/check to t_pass/t_fail/t_check so
# that sourcing lib.sh (which defines pass/fail) could no longer capture them.
# Undoing the rename restores the collision exactly. `it_fails` is shielded
# first: it CONTAINS the string t_fail, and rewriting it to `ifails` would
# break lib.sh's own accounting assertion — a corrupted reconstruction wearing
# the hole's clothes.
sed -e 's/it_fails/@@ITFAILS@@/g' \
    -e 's/t_pass/pass/g' -e 's/t_fail/fail/g' -e 's/t_check/check/g' \
    -e 's/@@ITFAILS@@/it_fails/g' \
    "$CACHE/$TIL_REL" > "$PRE_H2"
n_renamed="$(diff "$CACHE/$TIL_REL" "$PRE_H2" | grep -c '^< ')"
if [[ "$n_renamed" -gt 0 ]]; then
  pass "#2: the helper rename was undone on $n_renamed line(s) of a COPY"
else
  fail "#2: the helper rename was undone (0 lines changed — the reconstruction did not apply)"
fi
check "#2: no t_pass/t_fail/t_check survives the un-rename" "0" \
  "$(grep -c 't_pass\|t_fail\|t_check' "$PRE_H2")"
check "#2: lib.sh's own \$it_fails counter was NOT collateral damage" \
  "$(grep -c 'it_fails' "$CACHE/$TIL_REL")" "$(grep -c 'it_fails' "$PRE_H2")"
bash -n "$PRE_H2" 2>/dev/null \
  && pass "#2: the reconstruction parses" || fail "#2: the reconstruction parses"
# The collision is only a collision because lib.sh defines those same names.
grep -qE '^(pass|fail)\(\)' "$CACHE/$LIB_REL" \
  && pass "#2: … and lib.sh really does define pass()/fail(), which is what captures them" \
  || fail "#2: … and lib.sh really does define pass()/fail() — the premise of the hole is gone"

# ── #3: the single launcher_prepare vector, spliced back over the three ───────
# The pre-fix block is taken from git, verbatim, not retyped here.
git -C "$REPO_DIR" show "$SHA_H3^:$TIL_REL" 2>/dev/null \
  | sed -n '/^out="\$(IT_REAL_DOCKER=""/,/^fi$/p' > "$TMP/h3-block.txt"
h3_block_lines="$(grep -c . "$TMP/h3-block.txt")"
check "#3: the pre-fix launcher_prepare vector was recovered from $SHA_H3^ (6 lines)" \
  "6" "$h3_block_lines"
h3_start="$(grep -c "IT_REAL_DOCKER=''; launcher_prepare" "$CACHE/$TIL_REL")"
h3_anchor="$(grep -c 'launcher_prepare accepts an executable IT_REAL_DOCKER (rc=' "$CACHE/$TIL_REL")"
check "#3: the current three-vector block is located exactly once (start)" "1" "$h3_start"
check "#3: … and exactly once (end anchor)" "1" "$h3_anchor"
if [[ "$h3_block_lines" == "6" && "$h3_start" == "1" && "$h3_anchor" == "1" ]]; then
  s_no="$(grep -n "IT_REAL_DOCKER=''; launcher_prepare" "$CACHE/$TIL_REL" | cut -d: -f1)"
  a_no="$(grep -n 'launcher_prepare accepts an executable IT_REAL_DOCKER (rc=' "$CACHE/$TIL_REL" | cut -d: -f1)"
  e_no="$(awk -v a="$a_no" 'NR >= a && $0 == "fi" { print NR; exit }' "$CACHE/$TIL_REL")"
  { head -n "$((s_no - 1))" "$CACHE/$TIL_REL"
    cat "$TMP/h3-block.txt"
    tail -n "+$((e_no + 1))" "$CACHE/$TIL_REL"; } > "$PRE_H3"
  check "#3: the set-but-not-executable vector is gone from the reconstruction" "0" \
    "$(grep -c 'refuses a set-but-not-executable' "$PRE_H3")"
  check "#3: the negative-control vector is gone too" "0" \
    "$(grep -c 'accepts an executable IT_REAL_DOCKER' "$PRE_H3")"
  check "#3: the one pre-fix vector is present, in its command-prefix form" "1" \
    "$(grep -c 'IT_REAL_DOCKER="" bash -c' "$PRE_H3")"
  bash -n "$PRE_H3" 2>/dev/null \
    && pass "#3: the reconstruction parses" || fail "#3: the reconstruction parses"
else
  fail "#3: the splice could not be located — the reconstruction did not apply"
  : > "$PRE_H3"
fi

# ── #4 and #6: reverse-applied, inside the scratch tree ───────────────────────
revert_test_file() {   # <fix-sha> <repo-rel test> <dest> <label>
  local sha="$1" rel="$2" dest="$3" label="$4" rc
  restore_from_cache "$rel"
  ( cd "$WORK" && git show "$sha" -- "$rel" | git apply -R - ) >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "$label: reverse-applying $sha's change to $rel (git apply -R rc=$rc — a patch that no longer applies is a loud failure, not a skip)"
    restore_from_cache "$rel"
    : > "$dest"
    return 1
  fi
  cp -p "$WORK/$rel" "$dest"
  restore_from_cache "$rel"
  pass "$label: $sha's change to $rel was reverse-applied cleanly"
  return 0
}

revert_test_file "$SHA_H4" "$TIL_REL"  "$PRE_H4" "#4"
check "#4: the unfalsifiable two-conjunct form is back" "1" \
  "$(grep -c "ar_has \"\$out\" 'error:   ' && ar_has" "$PRE_H4")"
check "#4: … and the one-line grep that replaced it is gone" "0" \
  "$(grep -c "grep -q 'error:\.\*it-fake-missing-interp'" "$PRE_H4")"

revert_test_file "$SHA_H6" "$TMUT_REL" "$PRE_H6" "#6"
check "#6: the stdout-alone assertion is gone from the reconstruction" "0" \
  "$(grep -c 'the mid-batch rollback reports on stdout' "$PRE_H6")"
check "#6: … and the stream-merging mt() assertion that could not fail is still there" "1" \
  "$(grep -c 'the mid-batch rollback names what it undid' "$PRE_H6")"

# ══════════════════════════════════════════════════════════════════════════════
# 2. Hole #3 — the one the tier catches
# ══════════════════════════════════════════════════════════════════════════════
# lib.sh's guard is `[[ -z "$IT_REAL_DOCKER" || ! -x "$IT_REAL_DOCKER" ]]`. The
# pre-fix test drove one vector, and only the `-z` half; the logic-flip mutant
# turns the `||` into `&&`, which leaves the `-z` half answering exactly as
# before and breaks only the half the pre-fix test could not express.
printf '\n── hole #3: launcher_prepare, %s ──\n' "$SHA_H3"
if select_mutant "$LIB_REL" "$M3_OP" "$M3_SHA" "" "#3"; then
  M3_LINE="$MUT_LINE"; M3_TEXT="$MUT_TEXT"; M3_IDENT="$MUT_IDENT"
  grep -q 'IT_REAL_DOCKER' <<< "$M3_TEXT" \
    && pass "#3: … and it is the IT_REAL_DOCKER guard that it damages" \
    || fail "#3: … and it is the IT_REAL_DOCKER guard that it damages (got: $M3_TEXT)"

  cp -p "$PRE_H3" "$WORK/$TIL_REL"
  if require_green_baseline "$LIB_REL" "$LIB_ORACLE" "#3"; then
    apply_mutant "$LIB_REL" "$M3_LINE" "$M3_TEXT"
    run_oracle "$LIB_ORACLE"
    check "#3: the DEFECTIVE test does not notice the mutant — SURVIVED" "SURVIVED" "$VERDICT"
    h3_pre_signal="$SIGNAL"

    cp -p "$CACHE/$TIL_REL" "$WORK/$TIL_REL"
    run_oracle "$LIB_ORACLE"
    check "#3: the FIXED test kills the same mutant — KILLED" "KILLED" "$VERDICT"
    grep -q 'FAIL: launcher_prepare refuses a set-but-not-executable' "$ORACLE_LOG" \
      && pass "#3: … through the exact vector the defective version lacked" \
      || fail "#3: … through the exact vector the defective version lacked (not in the oracle's output)"
    check "#3: the kill is a real assertion, not a hang" "none" \
      "$(printf '%s' "$SIGNAL" | sed 's/.*timeout.*/timeout/;t;s/.*/none/')"
    pass "#3: VERDICT — the tier WOULD have caught this hole (signals: defective=$h3_pre_signal fixed=$SIGNAL)"
    restore_from_cache "$LIB_REL"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. Hole #2 — out of REMIT, and that is falsified rather than claimed
# ══════════════════════════════════════════════════════════════════════════════
printf '\n── hole #2: the pass/fail collision, %s ──\n' "$SHA_H2"
cp -p "$PRE_H2" "$WORK/$TIL_REL"
if require_green_baseline "$LIB_REL" "$LIB_ORACLE" "#2" && [[ -n "${M3_LINE:-}" ]]; then
  apply_mutant "$LIB_REL" "$M3_LINE" "$M3_TEXT"

  # The hole itself, observed directly: the defective file PRINTS its failure
  # and still exits 0, because the assertion tallied into lib.sh's $it_fails
  # and the file's own `exit "$fails"` never read it. Run OUTSIDE the driver,
  # because the driver is layer 2 of the same fix and would mask it.
  ( cd "$WORK" && bash "$TIL_REL" > "$TMP/direct-pre.log" 2>&1 ); rc_pre=$?
  ( cd "$WORK" && bash "$CACHE/$TIL_REL" > /dev/null 2>&1 ) || true
  cp -p "$CACHE/$TIL_REL" "$WORK/$TIL_REL"
  ( cd "$WORK" && bash "$TIL_REL" > "$TMP/direct-fix.log" 2>&1 ); rc_fix=$?

  n_fail_pre="$(grep -cE '^FAIL:' "$TMP/direct-pre.log")"
  check "#2: the defective file PRINTS its failure" "1" "$n_fail_pre"
  check "#2: … and exits 0 anyway — the hole, reachable and restored" "0" "$rc_pre"
  if [[ "$rc_fix" -ne 0 ]]; then
    pass "#2: the FIXED file exits non-zero on the same mutant (so the exit status is what the rename repaired)"
  else
    fail "#2: the FIXED file exits non-zero on the same mutant (got $rc_fix)"
  fi

  # What the harness makes of that: nothing different. Its kill disjunction
  # reads the OUTPUT as well as the status, so both versions are killed and
  # the survivor the tier exists to report never appears.
  cp -p "$PRE_H2" "$WORK/$TIL_REL"
  run_oracle "$LIB_ORACLE"
  check "#2: the harness KILLS the mutant against the DEFECTIVE test" "KILLED" "$VERDICT"
  h2_pre_signal="$SIGNAL"
  cp -p "$CACHE/$TIL_REL" "$WORK/$TIL_REL"
  run_oracle "$LIB_ORACLE"
  check "#2: … and against the FIXED test" "KILLED" "$VERDICT"
  check "#2: … with the SAME signal, so the tier reports no difference at all" \
    "$h2_pre_signal" "$SIGNAL"
  pass "#2: VERDICT — NOT CAUGHT as a survivor: #2 is an exit-status defect, not an assertion gap"

  # …and the claim "the FAIL:-line half is what closes it" is falsified, not
  # asserted. Remove BOTH layers that read the printed line — run-all.sh's
  # guard (layer 2 of 44676f5, reverted in the scratch tree) and run.sh's own
  # falsify_has_fail_line (neutered here, exactly as tests/test-falsify-run.sh
  # breaks it) — and the survivor appears for the defective test alone.
  if ( cd "$WORK" && git show "$SHA_H2" -- tests/run-all.sh | git apply -R - ) >/dev/null 2>&1; then
    pass "#2: layer 2 (run-all.sh's FAIL:-line guard) reverted in the scratch tree"
    falsify_has_fail_line() { return 1; }   # BROKEN-BY-TEST: the other half
    if falsify_has_fail_line "$TMP/direct-pre.log"; then
      fail "#2: the FAIL:-line predicate was really disabled"
    else
      pass "#2: the FAIL:-line predicate was really disabled (it now returns 1 on a log that HAS a FAIL: line)"
    fi
    cp -p "$PRE_H2" "$WORK/$TIL_REL"
    run_oracle "$LIB_ORACLE"
    check "#2: with BOTH FAIL:-line readers gone, the defective test SURVIVES" "SURVIVED" "$VERDICT"
    cp -p "$CACHE/$TIL_REL" "$WORK/$TIL_REL"
    run_oracle "$LIB_ORACLE"
    check "#2: … while the fixed test still KILLS, through its exit status alone" "KILLED" "$VERDICT"
    pass "#2: so the immunity is real and located: the kill disjunction's FAIL:-line half is what closes #2"
    # shellcheck source=./falsify/run.sh
    source "$RUN"   # the predicate back as shipped, for everything that follows
    falsify_has_fail_line "$TMP/direct-pre.log" \
      && pass "#2: the real FAIL:-line predicate is restored" \
      || fail "#2: the real FAIL:-line predicate is restored"
  else
    fail "#2: layer 2 could not be reverted — the immunity claim is unfalsified"
  fi
  restore_from_cache tests/run-all.sh
  restore_from_cache "$LIB_REL"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 4. Hole #4 — out of REACH: the line the assertion reads has no mutant
# ══════════════════════════════════════════════════════════════════════════════
printf '\n── hole #4: the exec-error conjunct, %s ──\n' "$SHA_H4"
h4_line="$(grep -n "error:   %s" "$CACHE/$LIB_REL" | cut -d: -f1)"
check "#4: assert_runs' error line is located exactly once in lib.sh" "1" \
  "$(grep -c "error:   %s" "$CACHE/$LIB_REL")"
if [[ -n "$h4_line" ]]; then
  n_at_line="$(FALSIFY_OPERATORS="$ALL_OPS" bash "$GEN" "$CACHE/$LIB_REL" 2>/dev/null \
               | awk -F'\t' -v l="$h4_line" '$2 == l' | grep -c .)"
  check "#4: the generator emits ZERO mutants for it, under the FULL operator set (lib.sh:$h4_line)" \
    "0" "$n_at_line"
  n_total="$(FALSIFY_OPERATORS="$ALL_OPS" bash "$GEN" "$CACHE/$LIB_REL" 2>/dev/null | grep -c .)"
  if [[ "$n_total" -gt 0 ]]; then
    pass "#4: … and that zero is about the LINE, not the operators — lib.sh yields $n_total mutants overall"
  else
    fail "#4: … and that zero is about the LINE, not the operators (lib.sh yielded no mutant at all)"
  fi
fi
# The nearest mutant that does reach the assertion is killed by SIBLING
# assertions the defective version also has, so it cannot discriminate either.
if select_mutant "$LIB_REL" "$M4_OP" "$M4_SHA" "" "#4"; then
  cp -p "$PRE_H4" "$WORK/$TIL_REL"
  if require_green_baseline "$LIB_REL" "$LIB_ORACLE" "#4"; then
    apply_mutant "$LIB_REL" "$MUT_LINE" "$MUT_TEXT"
    run_oracle "$LIB_ORACLE"
    check "#4: the nearest reaching mutant is KILLED by the DEFECTIVE test too" "KILLED" "$VERDICT"
    grep -q 'FAIL: a binary that exits non-zero with EMPTY output' "$ORACLE_LOG" \
      && pass "#4: … through a SIBLING assertion, which is what masks the hole" \
      || fail "#4: … through a sibling assertion (expected the empty-output assertion in the oracle's output)"
    cp -p "$CACHE/$TIL_REL" "$WORK/$TIL_REL"
    run_oracle "$LIB_ORACLE"
    check "#4: … and KILLED by the fixed test as well — no discrimination" "KILLED" "$VERDICT"
    pass "#4: VERDICT — NOT CAUGHT: no operator can damage a value carried by a command substitution inside a string"
    restore_from_cache "$LIB_REL"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. Hole #6 — out of REACH: stream-flip only moves stderr TO stdout
# ══════════════════════════════════════════════════════════════════════════════
printf '\n── hole #6: the rollback stream, %s ──\n' "$SHA_H6"
# stream-flip is off by default. Reaching for it and finding nothing must never
# be mistaken for a pass, so its reachability is asserted before any verdict:
# the operator IS enabled here and DOES produce mutants of this target.
n_sf="$(FALSIFY_OPERATORS=stream-flip bash "$GEN" "$CACHE/$MUTATE_REL" 2>/dev/null | grep -c .)"
if [[ "$n_sf" -gt 0 ]]; then
  pass "#6: stream-flip is reachable and produces $n_sf mutant(s) of mutate.sh (it is OFF by default)"
else
  fail "#6: stream-flip is reachable — it produced nothing, so every verdict below would be vacuous"
fi
h6_line="$(grep -n "printf 'Reverted %s..n' \"\$done_id\"" "$CACHE/$MUTATE_REL" | cut -d: -f1)"
check "#6: the mid-batch rollback's Reverted line is located exactly once" "1" \
  "$(grep -c "printf 'Reverted %s..n' \"\$done_id\"" "$CACHE/$MUTATE_REL")"
if [[ -n "$h6_line" ]]; then
  n_at_line="$(FALSIFY_OPERATORS="$ALL_OPS" bash "$GEN" "$CACHE/$MUTATE_REL" 2>/dev/null \
               | awk -F'\t' -v l="$h6_line" '$2 == l' | grep -c .)"
  check "#6: the generator emits ZERO mutants for it under the FULL operator set (mutate.sh:$h6_line)" \
    "0" "$n_at_line"
  grep -q '>&' <<< "$(sed -n "${h6_line}p" "$CACHE/$MUTATE_REL")" \
    && fail "#6: … because the fixed line carries no redirection token (it does carry one)" \
    || pass "#6: … because the fixed line carries no redirection token for stream-flip to flip"
fi
if select_mutant "$MUTATE_REL" "$M6_OP" "$M6_SHA" "stream-flip" "#6"; then
  cp -p "$PRE_H6" "$WORK/$TMUT_REL"
  if require_green_baseline "$MUTATE_REL" "$MUT_ORACLE" "#6"; then
    apply_mutant "$MUTATE_REL" "$MUT_LINE" "$MUT_TEXT"
    run_oracle "$MUT_ORACLE"
    check "#6: the stream-flip mutant SURVIVES the defective test" "SURVIVED" "$VERDICT"
    cp -p "$CACHE/$TMUT_REL" "$WORK/$TMUT_REL"
    run_oracle "$MUT_ORACLE"
    check "#6: … and SURVIVES the fixed test identically — no discrimination" "SURVIVED" "$VERDICT"
    pass "#6: VERDICT — NOT CAUGHT: stream-flip is one-directional (>&2 → >&1); the historical defect is the reverse move"
    restore_from_cache "$MUTATE_REL"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 6. The scorecard, and the isolation both ends of it rest on
# ══════════════════════════════════════════════════════════════════════════════
printf '\n── ship gate ──\n'
printf 'SHIP GATE: 1 of the 4 recoverable historical holes is caught by the tier.\n'
printf '  #2 %s  NOT CAUGHT — out of remit (an exit-status defect; the kill\n' "$SHA_H2"
printf '                       disjunction is immune to it, demonstrated above)\n'
printf '  #3 %s  CAUGHT     — SURVIVED against the defective test, KILLED against the fixed one\n' "$SHA_H3"
printf '  #4 %s  NOT CAUGHT — out of reach (no operator damages the value read)\n' "$SHA_H4"
printf '  #6 %s  NOT CAUGHT — out of reach (stream-flip is one-directional)\n' "$SHA_H6"

check "the real repo's HEAD is untouched by all of the above" \
  "$HEAD_BEFORE" "$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"
check "the real repo's working tree is untouched by all of the above" \
  "$PORC_BEFORE" "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"

finish
