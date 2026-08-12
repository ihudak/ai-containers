#!/usr/bin/env bash
# tests/test-layer-containment.sh — the suite runs in three layers, and the
# invariant is local ⊇ nightly ⊇ PR.
#
# Stated as prose this decays, exactly as the "seen failing" rule decayed before
# tests/test-mutations.sh made it mechanical. The concrete failure this catches:
# verify-on-host.sh ran the integration corpus and NOTHING else, so a developer
# verifying locally checked less than CI would — the local layer was a SUBSET of
# the PR gate.
#
# FIX ROUND 1 (review finding, Critical): the first version of the "every
# PR-layer check also runs locally" section proved a STRING exists in
# verify-on-host.sh's source text, not that the check it names actually runs.
# `grep -qE "run-all\.sh" "$VERIFY"` still matches after the real invocation is
# commented out, because the filename also appears in the existence-check
# guard, the phase_fail message, the header's phase table, and the
# floor-container invocation — five other non-comment sites carrying the same
# string. Five of the six original rows had this shape. Replaced with EFFECT
# checks, per this project's own doctrine (see AGENTS.md: "the suite asserts
# effect, not configuration ... whether the file exists, whether the log line
# is present"): build a stub repo with tests/lib-verify-repo.sh's instrumented
# stubs (each records its own invocation to WITNESS_LOG, or in bash -n's case —
# no external tool to stub — a genuinely broken tracked file that only
# produces a PARSE ERROR line if bash -n truly runs against it), run the REAL,
# CURRENT verify-on-host.sh against it, and assert each check's OWN witness
# line, not a substring anywhere in the script's source.
#
# INCREMENT 4 FOLLOW-UP: the effect-witness fix above holds for the rows that
# exist — but nothing forced a row to EXIST. Three lists had to agree
# (lib-verify-repo.sh's stubs, the CHECKS table here, and the expect_steps
# baselines) and nothing made them: adding a fourth CI job produced ZERO
# failures, because the job list was hardcoded as three names. All three are now
# tests/layer-checks.conf, the job list is derived from the workflow, and every
# step must classify as a registry check or declared setup.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like run.sh, lib.sh and verify-on-host.sh itself: upstream
# keeps the engine (verify-on-host.sh, bash-floor.sh) beside tests/,
# mgd-ai-containers keeps it in base/ with tests/ one level up, beside it. One
# copy of this file serves both, which is the property that lets the two stay
# byte-identical. .github/workflows/tests.yml and tests/integration/run.sh sit
# at the SAME place in both layouts (CI config must live at the real repo root;
# tests/ is always beside it), so only the engine files need the fallback.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/verify-on-host.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
HERMETIC_YML="$REPO_DIR/.github/workflows/hermetic-checks.yml"
TESTS_YML="$REPO_DIR/.github/workflows/tests.yml"
NIGHTLY_YML="$REPO_DIR/.github/workflows/nightly.yml"
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
LIB_LAYER_CHECKS="$REPO_DIR/tests/lib-layer-checks.sh"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
RUN="$REPO_DIR/tests/integration/run.sh"
LIB_VERIFY_REPO="$REPO_DIR/tests/lib-verify-repo.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Report EVERY missing required file, not just the first — a preflight that
# bails on the first miss can hide the other two from whoever is reading the
# output trying to fix it.
missing_required=0
for f in "$HERMETIC_YML" "$TESTS_YML" "$NIGHTLY_YML" "$LAYER_CHECKS_CONF" "$LIB_LAYER_CHECKS" "$VERIFY" "$RUN" "$LIB_VERIFY_REPO"; do
  if [[ ! -f "$f" ]]; then
    fail "$(basename "$f") not found at $f"
    missing_required=1
  fi
done
if [[ "$missing_required" -eq 1 ]]; then
  fail "one or more required files are missing — nothing below is checked"
  printf '\n%d failure(s)\n' "$fails"
  exit "$fails"
fi

# ── Both layers call the one definition ───────────────────────────────────────
# The reusable workflow only makes `nightly ⊇ PR` true over checks if BOTH
# workflows actually call it. Extracting the jobs and forgetting to wire nightly
# would leave the invariant exactly as false as before, with a file present that
# makes it LOOK addressed.
for wf in "$TESTS_YML" "$NIGHTLY_YML"; do
  if grep -qF 'uses: ./.github/workflows/hermetic-checks.yml' "$wf"; then
    pass "$(basename "$wf") calls hermetic-checks.yml"
  else
    fail "$(basename "$wf") does not call hermetic-checks.yml — the hermetic checks do not run in that layer"
  fi
done

# Nightly's caller is schedule-gated ON PURPOSE (mutation dispatches break the
# tree deliberately). Pin the exact condition so `if: false` — which would
# silently remove nightly's hermetic leg while leaving the `uses:` above intact,
# passing the assertion right before this one — cannot be substituted for it.
if grep -qF "if: github.event_name == 'schedule'" "$NIGHTLY_YML"; then
  pass "nightly's hermetic caller is gated on the schedule event, not disabled"
else
  fail "nightly's hermetic caller does not carry the expected schedule condition — it may have been disabled rather than gated"
fi

# ── Build a stub repo and run the REAL verify-on-host.sh against it ────────────
# tests/lib-verify-repo.sh (shared with tests/test-verify-exit-code.sh — see
# its own header for why this is one copy, not two) gives us mk_repo(),
# run_verify() and $WITNESS_LOG. mk_repo() copies $VERIFY as-is, so this picks
# up whatever is on disk right now, local edits included — the same property
# that lets Step 3-style demonstrations (comment out a real invocation, keep
# the naming comment) actually exercise this file.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=lib-layer-checks.sh
source "$LIB_LAYER_CHECKS"
# shellcheck source=lib-verify-repo.sh
source "$LIB_VERIFY_REPO"

# MK_REPO_PROBE=1: plant and commit the broken-syntax probe INSIDE mk_repo,
# where $r is a guaranteed-set local — not here, where a failed mk_repo (empty
# stdout) previously fed a bare `cd "$r"` with an empty string. `cd ""`
# SUCCEEDS and stays in the current directory, so that failure mode used to
# silently commit the whole real working tree under a fake identity instead of
# failing loudly. The guard below is the fix for the case mk_repo's own return
# does not cover: empty output without a non-zero exit status.
r="$(MK_REPO_PROBE=1 mk_repo 0)"
[[ -n "$r" ]] || { fail "mk_repo produced no repo path — the registry is unreadable"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

# PHASES="5 7" covers every check named in the registry in one hermetic run.
# The deliberately broken probe file makes Phase 7 report FAILED — expected
# and irrelevant here: this run's purpose is the WITNESS/log content it
# leaves behind, not its own exit code.
run_verify "$r" "5 7" >/dev/null

# floor_img/floor feed both the registry loop below (which expands the
# @FLOOR_IMAGE@ placeholder) and the suite-floor image assertion further down,
# so they are resolved once, here, before either first use.
# shellcheck source=../bash-floor.sh
source "$ENGINE_DIR/bash-floor.sh"
floor="${AI_CONTAINERS_BASH_FLOOR_MAJOR}.${AI_CONTAINERS_BASH_FLOOR_MINOR}"

# ── Every PR-layer check also runs locally — EFFECT, not text presence ─────────
# Rows come from tests/layer-checks.conf; see its header. Two assertions per row:
# the CI step exists (by EXACT step name, not a substring anywhere in the file —
# the substring form is what let a filename in a comment satisfy a row), and the
# witness line proving the check genuinely ran locally is present.
floor_img="${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}"
if [[ -z "$floor_img" ]]; then
  fail "bash-floor.sh maps no image to floor $floor — the floor-suite row cannot be checked"
fi

# shellcheck disable=SC2034  # kind/target/rc_var are positional registry columns (tests/lib-layer-checks.sh) consumed by lib-verify-repo.sh's stub-builder; only id/job/step/wtgt/wre drive this assertion loop, but `read` needs every field named to consume the row
while IFS='|' read -r id job step kind target rc_var wtgt wre; do
  # Exact step-name match within the named job.
  if wf_steps "$HERMETIC_YML" "$job" 2>/dev/null | grep -qxF "$step"; then
    pass "$id: hermetic-checks.yml job '$job' has step '$step'"
  else
    fail "$id: hermetic-checks.yml job '$job' has NO step named '$step' — this registry row is stale"
    continue
  fi

  case "$wtgt" in
    witness) hay="$WITNESS_LOG" ;;
    log)     hay="$TMP/out.log" ;;
    *) fail "$id: unrecognised witness target '$wtgt' — this registry row is broken"; continue ;;
  esac

  expect_re="${wre//@FLOOR_IMAGE@/$floor_img}"
  if grep -qE "$expect_re" "$hay"; then
    pass "$id runs in the local layer too (observed actually running)"
  else
    fail "$id runs in CI but was NOT OBSERVED RUNNING in verify-on-host.sh (no witness — local is not a superset)"
  fi
done < <(lc_rows check)

# ── Every step is classified: a check with a witness, or declared setup ────────
# A hand-written list can only police what it names. The previous version pinned
# a STEP COUNT per job against a baseline, with a hardcoded list of three job
# names — so a fourth CI job was entirely invisible (no row, no count, no
# witness), and even for a named job the remedy for a new step was "change 5 to
# 6". Here the job list is DERIVED from the workflow, and the remedy is to
# declare what the step is: calling it a check forces a registry row, which
# forces a stub and a local invocation, or the witness assertion above fails.
#
# This subsumes the count assertion rather than dropping it: if every step
# classifies and every registry row finds its step (above), the counts agree by
# construction.
classified=0
while IFS= read -r job; do
  while IFS= read -r step; do
    if lc_rows check | awk -F'|' -v j="$job" -v s="$step" '$2==j && $3==s {found=1} END{exit !found}'; then
      classified=$((classified+1))
    elif lc_rows setup | awk -F'|' -v j="$job" -v s="$step" '$1==j && $2==s {found=1} END{exit !found}'; then
      classified=$((classified+1))
    else
      fail "step '$step' in job '$job' is neither a registry check nor declared setup — classify it in tests/layer-checks.conf"
    fi
  done < <(wf_steps "$HERMETIC_YML" "$job")
done < <(wf_jobs "$HERMETIC_YML")

# A classification pass that classified NOTHING must not report success: a
# parser change or a workflow reorganisation would otherwise turn this whole
# section into a silent no-op that still goes green.
if [[ "$classified" -gt 0 ]]; then
  pass "every step in hermetic-checks.yml is classified ($classified step(s))"
else
  fail "classified no steps at all — the workflow parse returned nothing"
fi

# The floor job must run the image matching the DECLARED floor. The map lives in
# bash-floor.sh (see its comment); this asserts the workflow agrees with it.
if [[ -z "$floor_img" ]]; then
  fail "no container image is mapped to floor $floor — suite-floor cannot test the claim"
elif grep -qF "container: $floor_img" "$HERMETIC_YML"; then
  pass "suite-floor runs $floor_img, matching the declared floor $floor"
else
  fail "suite-floor does not run $floor_img — the declared floor $floor is untested"
fi

# ── Integration-case containment, asked of run.sh rather than reimplemented ────
sel() { bash "$RUN" --dry-run "$@" 2>/dev/null | grep -E '^[0-9]{3}-' | sort; }
pr_set="$(sel --tags fast --exclude needs-external,needs-dns)"
nightly_set="$( { sel --exclude packages; sel --tags packages; } | sort -u )"
local_set="$(sel)"

[[ -n "$pr_set" && -n "$nightly_set" && -n "$local_set" ]] \
  && pass "all three selections are non-empty" \
  || fail "a selection came back empty — containment below would pass vacuously"

missing="$(comm -23 <(printf '%s\n' "$pr_set") <(printf '%s\n' "$nightly_set"))"
[[ -z "$missing" ]] \
  && pass "PR selection ⊆ nightly selection" \
  || fail "PR selection ⊄ nightly: $(printf '%s' "$missing" | tr '\n' ' ')"

missing="$(comm -23 <(printf '%s\n' "$nightly_set") <(printf '%s\n' "$local_set"))"
[[ -z "$missing" ]] \
  && pass "nightly selection ⊆ local selection" \
  || fail "nightly selection ⊄ local: $(printf '%s' "$missing" | tr '\n' ' ')"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
