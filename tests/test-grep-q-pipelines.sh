#!/usr/bin/env bash
# tests/test-grep-q-pipelines.sh — no tracked script may pipe a producer into
# `grep -q` while `pipefail` is set.
#
# THE RULE IS NOT STYLE. `grep -q` exits the instant it matches; the producer,
# still writing, takes the broken pipe and dies 141; and `set -o pipefail`
# promotes that over grep's success. The pipeline then reports the OPPOSITE of
# what it observed, and which way it lies depends on what the caller expected:
#
#   if producer | grep -q X; then pass; else fail; fi     # false FAIL when X is there
#   if producer | grep -q X; then fail; else pass; fi     # false PASS when X is there
#
# The second is a REGRESSION GUARD REPORTING "no defect" AT EXACTLY THE MOMENT
# THE DEFECT COMES BACK, which is the failure mode this whole suite exists to
# make impossible. It is also the one that survives review, because the guard is
# green on a healthy tree and nobody looks again.
#
# Both are reproduced below against the real bash on this machine, so the rule
# rests on measurement rather than on this comment. It reached the repo for real
# on 2026-08-18: tests/test-layer-containment.sh reported a registry row stale
# when nothing was, on a machine loaded by the falsify tier running several
# copies of it at once (backlog F34).
#
# THE TWO CORRECT SPELLINGS:
#
#   grep -q X < <(producer)            # the producer is not in the pipeline, so
#                                      # its status never reaches pipefail. Use
#                                      # when only the match matters.
#   out="$(producer)" || return 1      # keeps the producer's status, which some
#   grep -q X <<<"$out"                # callers need (see wf_has_step).
#
# A line that must keep the piped spelling — a fixture whose job is to BE the
# hazard — opts out in this repo's usual idiom, and the reason is checked:
#
#   # grep-q-ok: <reason>
#
# on the same line, or on the line above when the pipeline is split across lines.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ── 1. The hazard, measured here, in both directions ─────────────────────────
# Without this the rule below is an assertion about an opinion. A producer
# larger than the pipe buffer makes the race deterministic; the same shape at
# four lines is what shipped, and only misbehaves under load.
_big="$(seq 1 200000)"

_false_fail=0
for _i in 1 2 3 4 5; do
  # shellcheck disable=SC2312  # the pipeline's status IS the subject here
  printf '%s\n' "$_big" | grep -q '^1$' || _false_fail=$((_false_fail + 1))  # grep-q-ok: this line IS the hazard being measured
done
if [[ "$_false_fail" -eq 5 ]]; then
  pass "measured: a match through a pipe reports FAILURE 5/5 times (false negative)"
else
  fail "measured: a match through a pipe reported failure only $_false_fail/5 times — this machine does not reproduce the hazard, so the rule below is unverified here"
fi

_false_pass=0
for _i in 1 2 3 4 5; do
  if printf '%s\n' "$_big" | grep -q '^1$'; then :; else _false_pass=$((_false_pass + 1)); fi  # grep-q-ok: this line IS the hazard being measured
done
if [[ "$_false_pass" -eq 5 ]]; then
  pass "measured: a regression guard in this shape reports NO DEFECT 5/5 times while the defect is present"
else
  fail "measured: the guard shape reported no-defect only $_false_pass/5 times"
fi

# Both replacements survive the same input. A rule that forbids one spelling
# without a working alternative is not actionable.
if grep -q '^1$' < <(printf '%s\n' "$_big"); then
  pass "the process-substitution spelling reports the match correctly"
else
  fail "the process-substitution spelling reports the match correctly"
fi
_out="$(printf '%s\n' "$_big")"
if grep -q '^1$' <<<"$_out"; then
  pass "the capture-then-match spelling reports the match correctly"
else
  fail "the capture-then-match spelling reports the match correctly"
fi
unset _big _out

# ── 2. The rule, over every tracked script ───────────────────────────────────
# Only files that set pipefail are subject to it: without pipefail the pipeline
# takes grep's status and the hazard cannot arise.
scanned=0
offenders=0
offender_list=""
while IFS= read -r f; do
  [[ -f "$REPO_DIR/$f" ]] || continue
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*o?[a-z]*[[:space:]]*.*pipefail|^[[:space:]]*set[[:space:]]+-o[[:space:]]+pipefail' "$REPO_DIR/$f" || continue
  scanned=$((scanned + 1))
  while IFS=: read -r n _; do
    [[ -n "$n" ]] || continue
    line="$(sed -n "${n}p" "$REPO_DIR/$f")"
    prev="$(sed -n "$((n - 1))p" "$REPO_DIR/$f")"
    # A comment line is prose about the rule, not a pipeline subject to it.
    case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
    # The opt-out, on this line or the one above (a split pipeline puts the
    # `| grep -q` on its own continuation line). The reason is required: a
    # bare marker suppresses nothing, exactly like `# dialect-lint: allow`.
    if grep -qE '#[[:space:]]*grep-q-ok:[[:space:]]*[^[:space:]]' <<<"$line" \
       || grep -qE '#[[:space:]]*grep-q-ok:[[:space:]]*[^[:space:]]' <<<"$prev"; then
      continue
    fi
    offenders=$((offenders + 1))
    offender_list="${offender_list}
  $f:$n  ${line#"${line%%[![:space:]]*}"}"
    # A SINGLE pipe, never `||`: `grep -q A "$f" || grep -q B "$f"` is two
    # independent greps reading files, with no pipeline and no hazard, and
    # counting it would train readers to ignore this list.
  done < <(grep -nE '[^|]\|[[:space:]]*grep[[:space:]]+-[a-zA-Z-]*q' "$REPO_DIR/$f" | cut -d: -f1)
done < <(cd "$REPO_DIR" && git ls-files '*.sh')

if [[ "$scanned" -gt 0 ]]; then
  pass "scanned $scanned tracked script(s) that set pipefail"
else
  fail "scanned no scripts at all — the rule below would pass vacuously"
fi

if [[ "$offenders" -eq 0 ]]; then
  pass 'no `grep -q` pipeline under pipefail without a stated reason' 
else
  fail "$offenders grep -q pipeline(s) under pipefail; each can report the opposite of what it observed:$offender_list"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
