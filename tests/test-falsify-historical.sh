#!/usr/bin/env bash
# tests/test-falsify-historical.sh — the mutation tier's SHIP GATE, and its
# honest scorecard.
#
# tests/falsify/ exists because six checks that could not fail shipped in this
# repo — the "Problem" table of
# docs/superpowers/specs/2026-08-11-falsify-mutation-tier-design.md. A mutation
# tier that cannot catch the bugs that motivated it is decoration, so this file
# MEASURES, against the real harness rather than a description of it, whether it
# would have surfaced them.
#
# ── REMIT: #3, #4 AND #6, AND ONLY THOSE ──────────────────────────────────────
# The same design states outright that `run-all.sh`'s `^FAIL:` guard already
# catches #2's shape — "a test printing FAIL: while exiting 0" — and that it
# "cannot catch #3, #4 or #6: an assertion that runs, reports PASS, and whose
# condition can never be false". Those three are this tier's job and the only
# three scored here. #1 (verify-on-host.sh's exit status) and #5 (a Docker-bound
# integration case) are not hermetic-suite assertions at all, so a hermetic
# mutation tier is out of reach of them by construction, not by omission.
#
# ── THE SCORECARD, AS MEASURED. 2 OF 3 ────────────────────────────────────────
#   #3  421d25d  launcher_prepare's unreachable half     CAUGHT
#   #6  7d1970f  a stdout line asserted through a        CAUGHT — but only with
#                stderr-folding helper                    stream-flip, which is
#                                                         OFF by default
#   #4  9b64bd3  a conjunct an unrelated line satisfied  NOT CAUGHT — no
#                                                         operator can damage
#                                                         the value it reads
#
# Every row is PINNED, not aspirational. This file goes red if the tier's
# detection power changes IN EITHER DIRECTION: a lost catch fails its SURVIVED /
# KILLED pair, and an operator added later that reaches #4 fails the zero-mutant
# assertion below and forces this record up. Demanding three catches would be
# red forever while teaching nobody which mechanism is missing; demanding
# nothing would be the false green this repo keeps finding.
#
# #4's row is a finding, not a shrug, and it is stated as one: the hole is fully
# reachable — the section below reconstructs it and drives it to SURVIVED /
# KILLED — using a mutant that damages a printf's VALUE. No operator in the
# generator's vocabulary does that, which is why the tier is blind to it. One
# value-damage operator would take this scorecard to 3 of 3.
#
# ── METHOD ────────────────────────────────────────────────────────────────────
# Per hole, three runs of the harness's OWN oracle runner and verdict predicates
# — this file SOURCES tests/falsify/run.sh and tests/falsify/generate.sh, so it
# cannot drift from what the tier actually does:
#
#   CONTROL   the reconstructed defective test against the UNMUTATED target must
#             be GREEN. Without it a SURVIVED verdict means "this test was
#             already broken", not "the hole is real" — and the harness refuses
#             a target whose oracle is not green anyway.
#   SURVIVED  the defective test against the mutant: nothing noticed.
#   KILLED    today's fixed test against the SAME mutant, required to name the
#             exact assertion the defective version lacked. Without this half
#             the file would be measuring the harness's inability to kill
#             anything.
#
# No mutant is hand-written. Each is selected out of the GENERATOR's real output
# by (operator, line), required to match exactly once, and printed back.
#
# ── ISOLATION ─────────────────────────────────────────────────────────────────
# Hermetic: no docker, no network. Everything happens under mktemp -d; the real
# repo is only ever READ, and its HEAD and `git status --porcelain` are compared
# before and after. About 45 s, most of it nine real oracle runs.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
GEN="$TESTS_DIR/falsify/generate.sh"
RUN="$TESTS_DIR/falsify/run.sh"

# h_pass/h_fail/h_check, not pass/fail/check: this file SOURCES two libraries,
# and hole #2 in the table above was a test whose own helpers were captured by a
# library it sourced. Neither falsify library defines these names today; giving
# them a private prefix means neither can start doing so silently.
fails=0
h_pass() { printf 'PASS: %s\n' "$1"; }
h_fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
h_check() {   # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then h_pass "$1"; else h_fail "$1 (expected '$2', got '$3')"; fi
}
h_finish() { printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

for f in "$GEN" "$RUN"; do
  [[ -f "$f" ]] || { h_fail "$f exists — there is no tier here to measure"; h_finish; }
done
# shellcheck source=./falsify/run.sh
source "$RUN"
# shellcheck source=./falsify/generate.sh
source "$GEN"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# git can FAIL rather than answer, and `2>/dev/null` makes those two
# indistinguishable: a failed `git status` yields an empty string, which
# compares unequal to a non-empty before-state, and this file then reports that
# THE HARNESS MODIFIED YOUR WORKING TREE. That is the most alarming claim it can
# make and the one cause it would not be — an environment fault dressed as a
# code defect, which is backlog F58's shape in a place with higher stakes.
#
# So the exit status is kept, and "git could not answer" is reported through the
# scaffold channel run-all.sh already has for exactly this distinction. No retry
# is attempted: index.lock contention was TESTED as a trigger and does not
# produce it (`git status` returns 0 while another process holds the lock), so a
# retry loop here would be guarding a mechanism nobody has observed.
h_repo_state() {   # <git args…> → 0 and the state on stdout; 1 when git could not answer
  local out rc
  out="$(git -C "$REPO_DIR" "$@" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || return 1
  printf '%s' "$out"
}
h_scaffold() {   # <what git could not report>
  printf 'SCAFFOLD-FAILED: git could not report %s — the isolation check could not be MADE, which is not the same as the repo having changed\n' "$1"
  fails=$((fails + 1))
}

if ! HEAD_BEFORE="$(h_repo_state rev-parse HEAD)"; then
  h_scaffold "HEAD before the run"; h_finish
fi
if ! PORC_BEFORE="$(h_repo_state status --porcelain)"; then
  h_scaffold "the working tree before the run"; h_finish
fi

SHA_H3=421d25d   # launcher_prepare's refusal check could not reach its branch
SHA_H4=9b64bd3   # a conjunct satisfied by an unrelated line
SHA_H6=7d1970f   # the rollback's "Reverted" line belongs on stdout

LIB_REL="tests/integration/lib.sh"
MUTATE_REL="tests/integration/mutate.sh"
TIL_REL="tests/test-integration-lib.sh"
TMUT_REL="tests/test-mutations.sh"
LIB_ORACLE="test-integration-lib.sh"
MUT_ORACLE="test-mutations.sh"

# Derived from the generator, never restated: a sixth operator added there must
# change what "the full operator set" means here without a second edit.
ALL_OPS="${FALSIFY_ALL_OPERATORS// /,}"
DEFAULT_OPS="${FALSIFY_DEFAULT_OPERATORS// /,}"
ORACLE_TIMEOUT=180
ORACLE_LOG="$TMP/oracle.log"

# ── the scratch trees ─────────────────────────────────────────────────────────
# CACHE is pristine and only ever read from; WORK is the only tree written into.
CACHE="$TMP/pristine"
WORK="$TMP/work"
if falsify_seed_tree "$REPO_DIR" "$CACHE"; then
  h_pass "a pristine scratch tree was seeded from the repo (tracked files + .git)"
else
  h_fail "a pristine scratch tree was seeded — nothing below can run"
  h_finish
fi
if { cp -a "$CACHE" "$WORK" 2>/dev/null || cp -R "$CACHE" "$WORK"; } && [[ -f "$WORK/$LIB_REL" ]]; then
  h_pass "a worker tree was seeded from it"
else
  h_fail "a worker tree was seeded from it"
  h_finish
fi

restore() { cp -Pp "$CACHE/$1" "$WORK/$1"; }
install_test() { cp -p "$2" "$WORK/$1"; }

# ── locating one line, loudly ─────────────────────────────────────────────────
# A recorded anchor that no longer matches exactly once is a hard failure, never
# a silent first match: the same rule the survivor ledger applies to a stale
# identity.
LOC=0
locate_one() {   # <label> <file> <fixed-string>
  local n
  LOC=0
  n="$(grep -Fc -- "$3" "$2")"
  if [[ "$n" != "1" ]]; then
    h_fail "$1: the anchor is present exactly once (matched $n line(s) — the reconstruction cannot be located)"
    return 1
  fi
  LOC="$(grep -Fn -- "$3" "$2" | cut -d: -f1)"
  h_pass "$1: located at line $LOC"
  return 0
}

# ── selecting a mutant from the generator's REAL output ───────────────────────
MUT_TEXT=""
select_mutant() {   # <label> <target-rel> <operator> <lineno> <operators>
  local label="$1" target="$2" op="$3" lineno="$4" ops="$5"
  local o l t n=0
  MUT_TEXT=""
  while IFS=$'\t' read -r o l _ t; do
    [[ "$o" == "$op" && "$l" == "$lineno" ]] || continue
    n=$((n + 1)); MUT_TEXT="$t"
  done < <(FALSIFY_OPERATORS="$ops" bash "$GEN" "$CACHE/$target" 2>/dev/null)
  if [[ "$n" != "1" ]]; then
    h_fail "$label: the generator emits exactly one $op mutant at $target:$lineno (got $n)"
    return 1
  fi
  h_pass "$label: the generator emits exactly one $op mutant at $target:$lineno"
  printf '       mutant: %s\n' "$MUT_TEXT"
  return 0
}

# ── one oracle run, judged by the HARNESS's own predicates ────────────────────
V_VERDICT=""
V_SIGNAL=""
run_oracle() {   # <label> <oracle>
  falsify_run_oracle "$WORK" "$2" "$ORACLE_LOG" "$ORACLE_TIMEOUT"
  falsify_verdict "$FALSIFY_RC" "$ORACLE_LOG" "$FALSIFY_TIMED_OUT"
  V_VERDICT="$FALSIFY_VERDICT"; V_SIGNAL="$FALSIFY_SIGNAL"
  # A mutant killed ONLY by a timeout is a mutant whose oracle HUNG and never
  # asserted anything. That is not a proven kill and is not reported as one.
  if (( FALSIFY_TIMED_OUT == 1 )); then
    V_VERDICT="UNPROVEN"
    h_fail "$1: the oracle HUNG (${ORACLE_TIMEOUT}s) without asserting — not a kill"
  fi
}

expect_verdict() {   # <label> <expected>
  if [[ "$V_VERDICT" == "$2" ]]; then
    h_pass "$1 — $2 (signal=$V_SIGNAL)"
    return 0
  fi
  h_fail "$1 — expected $2, got $V_VERDICT (signal=$V_SIGNAL)"
  # Indented, so run-all.sh's `^FAIL:` gate counts this file's own failures and
  # not the oracle's transcript.
  grep -E '(^|[[:space:]])FAIL:' "$ORACLE_LOG" | head -5 | sed 's/^/       /'
  return 1
}

oracle_named() {   # <label> <substring the kill must name>
  if grep -qF -- "$2" "$ORACLE_LOG"; then
    h_pass "$1"
  else
    h_fail "$1 (the oracle's output never names it)"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# HOLE #3 — launcher_prepare's unreachable half (421d25d)
# ══════════════════════════════════════════════════════════════════════════════
# lib.sh guards with `[[ -z "$IT_REAL_DOCKER" || ! -x "$IT_REAL_DOCKER" ]]`. The
# pre-fix test drove ONE vector and only the `-z` half. The logic-flip mutant
# turns that `||` into `&&`, which leaves the `-z` half answering exactly as
# before and breaks only the half the pre-fix test could not express.
printf '\n== hole #3: launcher_prepare, %s ==\n' "$SHA_H3"

H3_GUARD='if [[ -z "$IT_REAL_DOCKER" || ! -x "$IT_REAL_DOCKER" ]]; then'
h3_line=""
locate_one "#3: lib.sh's IT_REAL_DOCKER guard" "$CACHE/$LIB_REL" "$H3_GUARD" && h3_line="$LOC"

# ── the reconstruction ────────────────────────────────────────────────────────
# SURGICAL, not a whole-file restore, and not the verbatim pre-fix line either.
# Both alternatives were measured and both are wrong here:
#
#   * `git show 421d25d^:tests/test-integration-lib.sh` does not survive today's
#     lib.sh — the two have drifted since — so it is RED before any mutant
#     exists, and a red baseline is a measurement that never happened.
#   * the verbatim pre-fix vector carried a SECOND, unrelated defect: it set
#     IT_REAL_DOCKER="" as a command prefix, which lib.sh's `:-` fallback then
#     treats as unset. Its outcome therefore depends on whether the HOST has a
#     docker binary — green on a developer sandbox, red on any CI runner. That
#     is asserted, not assumed, a few lines below.
#
# What is reconstructed is the hole the tier is being measured on: only the `-z`
# half of the guard is driven. The two vectors 421d25d added are cut out, with
# their comments, and the vector that predates it is left exactly as it stands
# today — so the control is green on every host.
H3_V2='IT_REAL_DOCKER=/nonexistent/docker'
H3_V3=$'IT_REAL_DOCKER=\'$TRUE_STUB\'; launcher_prepare'
PRE_H3="$TMP/pre-h3.sh"

build_h3() {
  local -a src=() out=()
  local i v2=-1 v3=-1 end=-1 start
  mapfile -t src < "$CACHE/$TIL_REL"
  for (( i = 0; i < ${#src[@]}; i++ )); do
    case "${src[i]}" in
      *"$H3_V2"*) v2=$i ;;
      *"$H3_V3"*) v3=$i ;;
    esac
  done
  if (( v2 < 0 || v3 < 0 || v3 < v2 )); then
    h_fail "#3: both added vectors were located in today's test (set-but-not-executable=$v2, negative-control=$v3)"
    return 1
  fi
  for (( i = v3; i < ${#src[@]}; i++ )); do
    if [[ "${src[i]}" == "fi" ]]; then end=$i; break; fi
  done
  if (( end < 0 )); then
    h_fail "#3: the negative-control vector's closing 'fi' was located"
    return 1
  fi
  start=$v2
  while (( start > 0 )); do
    case "${src[start - 1]}" in \#*) start=$((start - 1)) ;; *) break ;; esac
  done
  out=("${src[@]:0:start}" "${src[@]:end + 1}")
  printf '%s\n' "${out[@]}" > "$PRE_H3" || return 1
  h_pass "#3: the two vectors 421d25d added were cut out ($(( end - start + 1 )) lines, with their comments)"
  return 0
}

if build_h3; then
  h_check "#3: the set-but-not-executable vector is gone" "0" \
    "$(grep -c 'set-but-not-executable' "$PRE_H3")"
  h_check "#3: the negative-control vector is gone" "0" \
    "$(grep -c 'accepts an executable IT_REAL_DOCKER' "$PRE_H3")"
  h_check "#3: the surviving vector — the only one that predates the fix — is still there" "1" \
    "$(grep -c "t_pass \"launcher_prepare refuses when the real docker resolves to nothing\"" "$PRE_H3")"
  bash -n "$PRE_H3" 2>/dev/null \
    && h_pass "#3: the reconstruction parses" || h_fail "#3: the reconstruction parses"
fi

# ── why the verbatim pre-fix line is NOT used, demonstrated ───────────────────
# Both forms are run against the same lib.sh with a fabricated docker on PATH —
# fabricated rather than `/bin/true`, which does not exist on macOS. The
# historical form then never reaches the guard it names (rc=0), so a file
# carrying it is RED wherever docker exists, which is every CI runner.
H3_PATH="$TMP/fake-path"
mkdir -p "$H3_PATH" "$TMP/h3-scratch"
printf '#!/bin/sh\nexit 0\n' > "$H3_PATH/docker"
chmod +x "$H3_PATH/docker"
h3_env=(env "IT_RUN_ID=hist" "IT_IMAGE=hist-img" "IT_NET=hist-net"
        "IT_SCRATCH=$TMP/h3-scratch" "IT_LABEL=ai-containers.it-run=hist"
        "IT_DNS_IMAGE=hist-dns" "PATH=$H3_PATH:$PATH")
h3_lib="$CACHE/$LIB_REL"
h3_out="$("${h3_env[@]}" IT_REAL_DOCKER="" bash -c ". '$h3_lib'; launcher_prepare" 2>&1)"
h3_rc=$?
h_check "#3: the VERBATIM pre-fix vector never reaches the guard when docker exists (rc)" \
  "0" "$h3_rc"
h_check "#3: … and prints no refusal at all, so the assertion naming one would be RED there" "" \
  "$h3_out"
h3_out="$("${h3_env[@]}" bash -c ". '$h3_lib'; IT_REAL_DOCKER=''; launcher_prepare" 2>&1)"
h3_rc=$?
if [[ "$h3_rc" -ne 0 ]] && grep -q 'cannot resolve the real docker' <<< "$h3_out"; then
  h_pass "#3: the retained vector reaches the guard on the SAME host — the reconstruction is host-independent"
else
  h_fail "#3: the retained vector reaches the guard on the same host (rc=$h3_rc, out=$h3_out)"
fi

# ── the three verdicts ────────────────────────────────────────────────────────
if [[ -n "$h3_line" ]] && select_mutant "#3" "$LIB_REL" logic-flip "$h3_line" "$DEFAULT_OPS"; then
  h3_mutant="$MUT_TEXT"
  case "$h3_mutant" in
    *'&&'*) h_pass "#3: the mutant is that guard with its || turned into &&" ;;
    *) h_fail "#3: the mutant is that guard with its || turned into && (got: $h3_mutant)" ;;
  esac

  install_test "$TIL_REL" "$PRE_H3"; restore "$LIB_REL"
  run_oracle "#3 control" "$LIB_ORACLE"
  if expect_verdict "#3 CONTROL: the defective test is green on the UNMUTATED target" "SURVIVED"; then
    falsify_write_mutant "$CACHE/$LIB_REL" "$WORK/$LIB_REL" "$h3_line" "$h3_mutant" \
      || h_fail "#3: the mutant was written into the worker tree"
    run_oracle "#3 defective" "$LIB_ORACLE"
    expect_verdict "#3 SURVIVED: the DEFECTIVE test does not notice the mutant" "SURVIVED"

    restore "$TIL_REL"
    run_oracle "#3 fixed" "$LIB_ORACLE"
    expect_verdict "#3 KILLED: today's FIXED test kills the same mutant" "KILLED"
    oracle_named "#3: … through the exact vector the defective version lacked" \
      "FAIL: launcher_prepare refuses a set-but-not-executable IT_REAL_DOCKER"
  fi
  restore "$LIB_REL"; restore "$TIL_REL"
fi

# ══════════════════════════════════════════════════════════════════════════════
# HOLE #6 — a stdout line asserted through a stderr-folding helper (7d1970f)
# ══════════════════════════════════════════════════════════════════════════════
# The mid-batch rollback's `Reverted <id>` belongs on stdout, like cmd_revert's
# identical line. The pre-fix assertion went through mt(), which folds stderr
# INTO stdout inside its own subshell, so it could not tell the two apart. The
# matching mutant pushes that printf to stderr — which needs `stream-flip`, OFF
# in the default set. Enabling it per-target is exactly what the design intends,
# and reaching for it and finding nothing must never read as a pass, so its
# reachability is asserted before any verdict below.
printf '\n== hole #6: the rollback stream, %s ==\n' "$SHA_H6"

n_sf="$(FALSIFY_OPERATORS=stream-flip bash "$GEN" "$CACHE/$MUTATE_REL" 2>/dev/null | grep -c .)"
if [[ "$n_sf" -gt 0 ]]; then
  h_pass "#6: stream-flip is reachable — $n_sf mutant(s) of mutate.sh (it is OFF by default)"
else
  h_fail "#6: stream-flip is reachable — it produced nothing, so every verdict below would be vacuous"
fi
h_check "#6: … and it is genuinely off by default" "0" \
  "$(FALSIFY_OPERATORS="$DEFAULT_OPS" bash "$GEN" "$CACHE/$MUTATE_REL" 2>/dev/null \
     | grep -c '^stream-flip')"

H6_ANCHOR=$'printf \'Reverted %s\\n\' "$done_id"'
h6_line=""
locate_one "#6: the mid-batch rollback's Reverted line" "$CACHE/$MUTATE_REL" "$H6_ANCHOR" \
  && h6_line="$LOC"

# A WHOLE-FILE pre-fix restore works here — unlike #3, tests/test-mutations.sh
# has not drifted away from today's mutate.sh — so the defective version is
# taken from git verbatim rather than reconstructed.
PRE_H6="$TMP/pre-h6.sh"
if git -C "$REPO_DIR" show "$SHA_H6^:$TMUT_REL" > "$PRE_H6" 2>/dev/null && [[ -s "$PRE_H6" ]]; then
  h_pass "#6: the pre-fix tests/test-mutations.sh was restored whole from $SHA_H6^"
else
  h_fail "#6: the pre-fix tests/test-mutations.sh was restored whole from $SHA_H6^"
fi
h_check "#6: the stdout-alone assertion the fix added is absent from it" "0" \
  "$(grep -c 'the mid-batch rollback reports on stdout' "$PRE_H6")"
# The stream-merging assertion that could not fail is in BOTH versions — the fix
# ADDED a stdout-only assertion rather than repairing that one, which is why the
# defective version still looks like it covers the rollback's output.
h6_merge_now="$(grep -c 'the mid-batch rollback names what it undid' "$CACHE/$TMUT_REL")"
h6_merge_pre="$(grep -c 'the mid-batch rollback names what it undid' "$PRE_H6")"
if [[ "$h6_merge_now" -gt 0 && "$h6_merge_pre" == "$h6_merge_now" ]]; then
  h_pass "#6: … while the stream-merging assertion that could not fail is in both ($h6_merge_now line(s))"
else
  h_fail "#6: … while the stream-merging assertion that could not fail is in both (today=$h6_merge_now, pre-fix=$h6_merge_pre)"
fi

if [[ -n "$h6_line" ]] && select_mutant "#6" "$MUTATE_REL" stream-flip "$h6_line" stream-flip; then
  h6_mutant="$MUT_TEXT"
  case "$h6_mutant" in
    *'>&2') h_pass "#6: the mutant pushes that printf to stderr" ;;
    *) h_fail "#6: the mutant pushes that printf to stderr (got: $h6_mutant)" ;;
  esac

  install_test "$TMUT_REL" "$PRE_H6"; restore "$MUTATE_REL"
  run_oracle "#6 control" "$MUT_ORACLE"
  if expect_verdict "#6 CONTROL: the pre-fix test is green on the UNMUTATED target" "SURVIVED"; then
    falsify_write_mutant "$CACHE/$MUTATE_REL" "$WORK/$MUTATE_REL" "$h6_line" "$h6_mutant" \
      || h_fail "#6: the mutant was written into the worker tree"
    run_oracle "#6 defective" "$MUT_ORACLE"
    expect_verdict "#6 SURVIVED: the DEFECTIVE test does not notice the mutant" "SURVIVED"

    restore "$TMUT_REL"
    run_oracle "#6 fixed" "$MUT_ORACLE"
    expect_verdict "#6 KILLED: today's FIXED test kills the same mutant" "KILLED"
    oracle_named "#6: … through the stdout-alone assertion the fix added" \
      "FAIL: the mid-batch rollback reports on stdout"
  fi
  restore "$MUTATE_REL"; restore "$TMUT_REL"
fi

# ══════════════════════════════════════════════════════════════════════════════
# HOLE #4 — NOT CAUGHT: the value the assertion reads has no mutant (9b64bd3)
# ══════════════════════════════════════════════════════════════════════════════
# The defect was `ar_has "$out" 'error:   ' && ar_has "$out" 'it-fake-missing-interp'`:
# the label is unconditional and the second conjunct is satisfied by the
# `shebang:` line above it, so the conjunction held even with the exec error
# EMPTY. Reproducing it needs a mutant that empties a printf's VALUE — and no
# operator does that. Measured, not assumed, in both directions below.
printf '\n== hole #4: the exec-error conjunct, %s ==\n' "$SHA_H4"

h4_line=""
locate_one "#4: assert_runs' error line in lib.sh" "$CACHE/$LIB_REL" 'error:   %s' && h4_line="$LOC"

if [[ -n "$h4_line" ]]; then
  n_at_line="$(FALSIFY_OPERATORS="$ALL_OPS" bash "$GEN" "$CACHE/$LIB_REL" 2>/dev/null \
               | cut -f2 | grep -cx "$h4_line")"
  h_check "#4: the generator emits ZERO mutants for it under the FULL operator set ($ALL_OPS)" \
    "0" "$n_at_line"
  n_total="$(FALSIFY_OPERATORS="$ALL_OPS" bash "$GEN" "$CACHE/$LIB_REL" 2>/dev/null | grep -c .)"
  if [[ "$n_total" -gt 0 ]]; then
    h_pass "#4: … and that zero is about the LINE, not the operators — lib.sh yields $n_total mutants overall"
  else
    h_fail "#4: … and that zero is about the LINE, not the operators (lib.sh yielded nothing at all)"
  fi
fi

# ── the hole is reachable; only the operator is missing ───────────────────────
# Stated as a finding rather than a shrug, and proved the same way as the two
# above: the SAME defective-vs-fixed pair, driven by the mutant the generator
# would have to be able to emit. It is DERIVED from the real line — the argument
# is cut off and replaced with an empty string — never retyped, and printed back
# before anything is judged by it. This is NOT a catch for the tier: the mutant
# below is not in the generator's output, which is exactly what the zero above
# says.
PRE_H4="$TMP/pre-h4.sh"
H4_FIXED="grep -q 'error:.*it-fake-missing-interp'"
H4_PREFIX=$'ar_has "$out" \'error:   \' && ar_has "$out" \'it-fake-missing-interp\' \\'
# A SECOND assertion reads the same error value: the dead-container case added
# later, which requires docker's own message to land ON the error: line. It is
# unrelated to 9b64bd3 and did not exist when that defect shipped — but it is in
# the file the reconstruction copies, and it notices an emptied error value just
# as well, so leaving it in place makes the "defective" copy kill the mutant and
# the SURVIVED half of this pair unreachable. The reconstruction must model a
# file where NOTHING asserts the error value, so this line is neutralised too:
# replaced by `true`, which keeps the `&& t_pass … || t_fail …` continuation
# that follows it syntactically intact while making it unable to fail.
#
# This is faithfulness, not convenience. Were it removed instead, the oracle
# would differ from the historical file in a second way; were it left, this pair
# would measure the new assertion rather than the old hole.
H4_DEAD="grep -q 'error:.*Error response from daemon'"
h4_damaged=""

build_h4() {
  local -a src=()
  local i k=-1 n=0 kd=-1 nd=0 orig
  mapfile -t src < "$CACHE/$TIL_REL"
  for (( i = 0; i < ${#src[@]}; i++ )); do
    case "${src[i]}" in *"$H4_FIXED"*) n=$((n + 1)); k=$i ;; esac
    case "${src[i]}" in *"$H4_DEAD"*)  nd=$((nd + 1)); kd=$i ;; esac
  done
  if [[ "$n" != "1" ]]; then
    h_fail "#4: the one-line grep 9b64bd3 introduced is present exactly once (got $n)"
    return 1
  fi
  if [[ "$nd" != "1" ]]; then
    h_fail "#4: the dead-container error-value assertion is present exactly once (got $nd)"
    return 1
  fi
  src[k]="$H4_PREFIX"
  src[kd]='true \'
  printf '%s\n' "${src[@]}" > "$PRE_H4" || return 1
  h_pass "#4: that one line was reverted to its two-conjunct pre-fix form"
  printf '       %s\n' "$H4_PREFIX"

  # The value-damage mutant, derived from the real line by cutting the argument.
  mapfile -t src < "$CACHE/$LIB_REL"
  orig="${src[h4_line - 1]}"
  h4_damaged="${orig%% \"\$\(*}"' ""'
  printf '       original: %s\n' "$orig"
  printf '       damaged:  %s\n' "$h4_damaged"
  if [[ "$h4_damaged" == "$orig" ]]; then
    h_fail "#4: the value-damage mutant differs from the line it damages"
    return 1
  fi
  case "$h4_damaged" in
    *'$('*) h_fail "#4: the damaged line no longer computes a value (a command substitution survived)"; return 1 ;;
  esac
  case "$h4_damaged" in
    *'error:   %s'*) h_pass "#4: the damaged line keeps the LABEL and loses only the VALUE — the historical reproduction" ;;
    *) h_fail "#4: the damaged line keeps the label (got: $h4_damaged)"; return 1 ;;
  esac
  return 0
}

if [[ -n "$h4_line" ]] && build_h4; then
  install_test "$TIL_REL" "$PRE_H4"; restore "$LIB_REL"
  run_oracle "#4 control" "$LIB_ORACLE"
  if expect_verdict "#4 CONTROL: the defective test is green on the UNMUTATED target" "SURVIVED"; then
    falsify_write_mutant "$CACHE/$LIB_REL" "$WORK/$LIB_REL" "$h4_line" "$h4_damaged" \
      || h_fail "#4: the value-damage mutant was written into the worker tree"
    run_oracle "#4 defective" "$LIB_ORACLE"
    expect_verdict "#4 SURVIVED: the DEFECTIVE test does not notice an emptied error value" "SURVIVED"

    restore "$TIL_REL"
    run_oracle "#4 fixed" "$LIB_ORACLE"
    expect_verdict "#4 KILLED: today's FIXED test kills it" "KILLED"
    oracle_named "#4: … through the one-line grep that replaced the two conjuncts" \
      "FAIL: the failure dump carries the exec error itself"
    h_pass "#4: so the hole is REACHABLE and the tier is blind to it for one reason only — no value-damage operator"
  fi
  restore "$LIB_REL"; restore "$TIL_REL"
fi

# ══════════════════════════════════════════════════════════════════════════════
# The scorecard, and the isolation it rests on
# ══════════════════════════════════════════════════════════════════════════════
printf '\n== ship gate ==\n'
printf 'SHIP GATE: 2 of the 3 holes in this tier'"'"'s remit are caught.\n'
printf '  #3 %s  CAUGHT     — SURVIVED against the defective test, KILLED against the fixed one\n' "$SHA_H3"
printf '  #6 %s  CAUGHT     — same pair, but only with stream-flip, which is OFF by default\n' "$SHA_H6"
printf '  #4 %s  NOT CAUGHT — the hole is reachable (SURVIVED/KILLED above) but the mutant\n' "$SHA_H4"
printf '                       that reaches it damages a VALUE, and no operator can\n'
printf '  #2 44676f5  out of remit — run-all.sh'"'"'s ^FAIL: guard already catches its shape\n'
printf '  #1, #5      out of reach — not hermetic-suite assertions at all\n'

if head_after="$(h_repo_state rev-parse HEAD)"; then
  h_check "the real repo's HEAD is untouched by all of the above" "$HEAD_BEFORE" "$head_after"
else
  h_scaffold "HEAD after the run"
fi
if porc_after="$(h_repo_state status --porcelain)"; then
  h_check "the real repo's working tree is untouched by all of the above" "$PORC_BEFORE" "$porc_after"
else
  h_scaffold "the working tree after the run"
fi

h_finish
