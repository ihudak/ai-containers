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
#
# FIX ROUND 2 (final review, three findings, all reproduced against this file
# printing "0 failure(s)" before the fix): the registry/derivation above closed
# the ORIGINAL defect but reintroduced the same SHAPE of bug three ways.
#   1. The classification loop below consumed `wf_steps` only as
#      `done < <(wf_steps …)` — a step-less job (e.g. a second reusable-workflow
#      `uses:` appended to hermetic-checks.yml) makes wf_steps print an error
#      and return 1, and the loop never looked: `classified` stayed positive
#      from the OTHER jobs and the run stayed green.
#   2. The nightly⊇PR assertions were `grep -qF` against the WHOLE FILE — the
#      exact historical defeat this header already documents for verify-on-host.sh
#      above, reintroduced here: commenting out nightly's `hermetic:` job (condition
#      and `uses:` both, as a comment that still names them) left both greps
#      matching non-executable text.
#   3. The classification loop walked only hermetic-checks.yml. A fourth job
#      added directly to tests.yml — the actual PR gate, not the reusable
#      workflow — with real inline steps was never visited at all.
# Fixed together: wf_job_key() (tests/lib-layer-checks.sh) reads a job-level
# `uses:`/`if:` through the same block-aware awk state machine wf_jobs/wf_steps
# use, so a commented-out job never enters it and the nightly assertions fail at
# their cause. The classification loop now walks {hermetic-checks.yml,
# tests.yml}: a job with its own job-level `uses:` must point at
# hermetic-checks.yml (anything else, including no steps and no such `uses:`, is
# an unclassified bypass); every other job's steps must classify — and its own
# wf_steps call is now checked, not discarded.
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

# Sourced early (before the stub-repo machinery needs it) so wf_job_key is
# available to the nightly assertions right below.
# shellcheck source=lib-layer-checks.sh
source "$LIB_LAYER_CHECKS"

# ── Every workflow file is enumerated from disk — not named ────────────────────
# FIX ROUND 3 (re-review of the branch after FIX ROUND 2 landed, the fourth and
# final finding in this file's own recurring defect: a check that cannot fail).
# The classification loop further down used to walk a hardcoded, literal
# {$HERMETIC_YML, $TESTS_YML} — two names typed into this file. A brand-new
# workflow that triggers on pull_request was invisible to it: demonstrated by
# planting .github/workflows/zz-extra-pr-gate.yml, whose only job ran
# ./tests/run-all.sh (a genuine hermetic check) on every pull_request, and
# watching this file still print "0 failure(s)". It was benign today only by
# accident — the other real pull_request workflow, integration.yml, happens to
# be covered by the separate case-containment section further down; a third
# workflow would have bypassed both mechanisms.
#
# The fix is the same SHAPE as the registry itself: enumerate
# .github/workflows/*.yml from the FILESYSTEM, so a new file is caught the day
# it lands rather than the day someone remembers to add it here; require a
# `workflow` row in tests/layer-checks.conf for every one of them; and drive
# the classification loop below from the rows marked `coverage=classified`
# instead of the two-name literal. A `coverage=exempt` row's claim ("this
# workflow never runs on pull_request, so the containment invariant does not
# apply") is not merely trusted — it is VERIFIED against the file's own `on:`
# block via wf_triggers_on(), the same effect-over-text-presence standard this
# file applies everywhere else (its stub-repo section above, its job-level-key
# reads instead of whole-file greps).
wf_dir="$REPO_DIR/.github/workflows"
workflow_files=()
while IFS= read -r f; do
  workflow_files+=("$(basename "$f")")
done < <(find "$wf_dir" -maxdepth 1 -type f -name '*.yml' | sort)

if [[ "${#workflow_files[@]}" -eq 0 ]]; then
  fail "no *.yml files found under $wf_dir — nothing was enumerated"
else
  pass "enumerated ${#workflow_files[@]} workflow file(s) from $wf_dir"
fi

declare -A wf_row_file=()
while IFS='|' read -r wfile coverage why; do
  wf_row_file["$wfile"]=1
  wf_target="$wf_dir/$wfile"

  if [[ ! -f "$wf_target" ]]; then
    # `classified`/`cases` assert the guard DEPENDS on this file (the
    # classification loop or the integration-case section relies on it
    # existing), so a missing file there is a genuine defect. `exempt` asserts
    # a NEGATIVE — "this file, if present, is not part of the PR gate" — and
    # with no file to make that claim about, the row is inert, not stale: skip
    # it silently rather than failing. See the `workflow` row-type block in
    # tests/layer-checks.conf for why this asymmetry exists (this file is
    # shared byte-identically with a sibling repo holding a different
    # workflow set).
    if [[ "$coverage" == "exempt" ]]; then
      continue
    fi
    fail "workflow row '$wfile' (tests/layer-checks.conf) names a file that does not exist at $wf_target — this registry row is stale"
    continue
  fi

  if [[ -z "$why" ]]; then
    fail "workflow row '$wfile' (tests/layer-checks.conf) has an empty <why> field — classify it meaningfully, the same standard setup rows are held to"
    continue
  fi

  case "$coverage" in
    classified|cases)
      pass "workflow row '$wfile' declares coverage=$coverage"
      ;;
    exempt)
      if wf_triggers_on "$wf_target" pull_request; then
        fail "workflow row '$wfile' claims coverage=exempt but $wfile DOES trigger on pull_request — it is part of the PR gate and needs coverage=classified or coverage=cases, not exempt"
      else
        pass "workflow row '$wfile' claims coverage=exempt and $wfile is verified NOT pull_request-triggered"
      fi
      ;;
    *)
      fail "workflow row '$wfile' (tests/layer-checks.conf) has unrecognised coverage '$coverage' (want classified, cases, or exempt)"
      ;;
  esac
done < <(lc_rows workflow)

for wfile in "${workflow_files[@]}"; do
  if [[ -z "${wf_row_file[$wfile]:-}" ]]; then
    fail "$wfile has no 'workflow' row in tests/layer-checks.conf — classify it there (classified|cases|exempt) or its coverage stays silently unclassified"
  else
    pass "$wfile has a workflow row in tests/layer-checks.conf"
  fi
done

# ── Nightly's hermetic caller — a JOB-LEVEL KEY, not a text grep ───────────────
# The reusable workflow only makes `nightly ⊇ PR` true over checks if nightly
# actually calls it, gated the right way. FIX ROUND 2: `grep -qF` against the
# WHOLE FILE passes on a commented-out job — commenting out
#   # hermetic:
#   #   if: github.event_name == 'schedule'
#   #   uses: ./.github/workflows/hermetic-checks.yml
# leaves both old patterns matching text that is no longer executable YAML.
# wf_job_key (tests/lib-layer-checks.sh) reads the value under the NAMED JOB
# through the same block-aware awk state machine wf_jobs/wf_steps already use —
# a commented-out job never enters that state machine's `jobs:` block as a job
# at all (its header line does not match the job-start pattern), so this fails
# at its cause instead of at a stale substring match. tests.yml's own "calls
# hermetic-checks.yml" is asserted the same way, folded into the classification
# loop below (its `hermetic` job is one of the jobs that loop walks).
val="$(wf_job_key "$NIGHTLY_YML" hermetic uses 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$val" == "./.github/workflows/hermetic-checks.yml" ]]; then
  pass "nightly.yml job 'hermetic' has uses: ./.github/workflows/hermetic-checks.yml"
else
  fail "nightly.yml job 'hermetic' does not resolve uses: ./.github/workflows/hermetic-checks.yml (job/key absent, or commented out) — $val"
fi

# Schedule-gated ON PURPOSE (mutation dispatches break the tree deliberately).
# Pinning the exact condition means `if: false` cannot be substituted for it —
# and, as above, a commented-out job cannot satisfy it either.
val="$(wf_job_key "$NIGHTLY_YML" hermetic if 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$val" == "github.event_name == 'schedule'" ]]; then
  pass "nightly's hermetic caller is gated on the schedule event, not disabled"
else
  fail "nightly's hermetic caller does not resolve if: github.event_name == 'schedule' (job/key absent, or commented out) — $val"
fi

# ── Build a stub repo and run the REAL verify-on-host.sh against it ────────────
# tests/lib-verify-repo.sh (shared with tests/test-verify-exit-code.sh — see
# its own header for why this is one copy, not two) gives us mk_repo(),
# run_verify() and $WITNESS_LOG. mk_repo() copies $VERIFY as-is, so this picks
# up whatever is on disk right now, local edits included — the same property
# that lets Step 3-style demonstrations (comment out a real invocation, keep
# the naming comment) actually exercise this file.
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=lib-verify-repo.sh
source "$LIB_VERIFY_REPO"

# MK_REPO_PROBE=1: plant and commit the broken-syntax probe INSIDE mk_repo,
# where $r is a guaranteed-set local — not here, where a failed mk_repo (empty
# stdout) previously fed a bare `cd "$r"` with an empty string. `cd ""`
# SUCCEEDS and stays in the current directory, so that failure mode used to
# silently commit the whole real working tree under a fake identity instead of
# failing loudly. Planting it inside mk_repo is the fix for that: mk_repo no
# longer has a `return` at all, and the conditions that could once make it hand
# back an empty $r are now removed or checked at source time — see the comment
# below, and the one above mk_repo in tests/lib-verify-repo.sh.
r="$(MK_REPO_PROBE=1 mk_repo 0)"
# No guard follows: sourcing tests/lib-verify-repo.sh aborts the sourcing
# script outright if any of its source-time checks fail (TMP/VERIFY/ENGINE_DIR,
# lc_rows sourced, the registry's path-bin AND repo-script stub rows, git able
# to init/add/commit), so control never reaches this line with a registry that
# would yield an empty $r; and mk_repo's own parameters carry defaults, so even
# an arg-less call cannot kill the command substitution under `set -u` — mk_repo
# cannot return non-zero or print an empty path (for a caller that, like this
# one, leaves TMP set and does not run `set -e` with `shopt -s
# inherit_errexit`; see tests/lib-verify-repo.sh for both caveats).
# That is NOT a guarantee that every operation inside mk_repo succeeded
# (see the comment above mk_repo in tests/lib-verify-repo.sh for the narrow
# residual that stays unchecked); it is only the guarantee this guard used to
# re-detect. The guard this replaces existed because that failure used to
# arrive as a discarded `return` — and an empty $r once fed a bare `cd "$r"`,
# which SUCCEEDS and stays put, committing the whole real working tree under a
# fake identity.

# PHASES="5 6 7" covers every check named in the registry in one hermetic run.
# 6 joined the list when the falsify tier gained its phase: the registry rows
# come from hermetic-checks.yml, so a job added there with no local phase to
# match is precisely the `local ⊉ PR` breach this file exists to catch — and
# leaving 6 out here would have hidden it behind a harness that never selected
# the phase, which is the same silent-success shape one layer down.
# The deliberately broken probe file makes Phase 7 report FAILED — expected
# and irrelevant here: this run's purpose is the WITNESS/log content it
# leaves behind, not its own exit code.
run_verify "$r" "5 6 7" >/dev/null

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
  # wf_has_step, never `wf_steps | grep -q`: under pipefail that pipeline
  # reports "no such step" for a step that is present whenever grep's early
  # exit beats the producer, which on a loaded machine it does. See the note
  # above wf_has_step in tests/lib-layer-checks.sh.
  if wf_has_step "$HERMETIC_YML" "$job" "$step"; then
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

# ── Every job is accounted for: a hermetic-checks.yml caller, or classified ────
# A hand-written list can only police what it names. An earlier version pinned
# a STEP COUNT per job against a baseline, with a hardcoded list of three job
# names — so a fourth CI job was entirely invisible (no row, no count, no
# witness), and even for a named job the remedy for a new step was "change 5 to
# 6". The job list here is DERIVED from the workflow, and the remedy is to
# declare what the step is: calling it a check forces a registry row, which
# forces a stub and a local invocation, or the witness assertion above fails.
#
# FIX ROUND 2 walked {hermetic-checks.yml, tests.yml}, not hermetic-checks.yml
# alone — a job added directly to tests.yml (the real PR gate) is otherwise
# invisible here even though it runs on every PR. Deliberately NOT extended to
# nightly.yml: its integration-* jobs legitimately carry many non-hermetic
# steps, and its one in-scope job (`hermetic`) is already asserted above via
# wf_job_key. A job in either walked workflow either declares its OWN job-level
# `uses:` — which must point at hermetic-checks.yml, or it is an unclassified
# bypass, whether or not it has any steps of its own — or every one of its
# steps must classify as a registry check or declared setup. wf_jobs/wf_steps
# calls are now CHECKED, not merely consumed via `done < <(…)`: a step-less job
# with no approved `uses:` (wf_steps fails loudly) used to leave `classified`
# unchanged and slip through as an invisible bypass instead of a named failure.
#
# FIX ROUND 3: that {hermetic-checks.yml, tests.yml} list was still a literal
# written into this file — a THIRD hermetic-shaped workflow needed only its own
# new name typed here, and nothing forced that. The list below is now DERIVED
# from tests/layer-checks.conf's `workflow` rows marked coverage=classified
# (asserted to exist, above), which is the same two files today by construction
# but requires an explicit registry row — checked against the filesystem
# enumeration above — for a third one to ever join it.
#
# This subsumes the count assertion rather than dropping it: if every step
# classifies and every registry row finds its step (above), the counts agree by
# construction.
classified=0
while IFS= read -r wfile; do
  wf="$wf_dir/$wfile"
  wfname="$wfile"
  if ! jobs_out="$(wf_jobs "$wf")"; then
    fail "$wfname: could not enumerate jobs — nothing in this workflow is classified (see stderr above)"
    continue
  fi
  while IFS= read -r job; do
    if uses_val="$(wf_job_key "$wf" "$job" uses 2>/dev/null)"; then
      if [[ "$uses_val" == "./.github/workflows/hermetic-checks.yml" ]]; then
        pass "$wfname job '$job' calls hermetic-checks.yml (its steps are classified there)"
        classified=$((classified+1))
      else
        fail "$wfname job '$job' has a job-level uses: '$uses_val', not hermetic-checks.yml — its steps are never classified or run locally"
      fi
      continue
    fi
    if ! steps_out="$(wf_steps "$wf" "$job")"; then
      fail "$wfname job '$job' has no steps and no job-level uses: pointing at hermetic-checks.yml — nothing classifies it (see stderr above)"
      continue
    fi
    while IFS= read -r step; do
      if lc_rows check | awk -F'|' -v j="$job" -v s="$step" '$2==j && $3==s {found=1} END{exit !found}'; then
        classified=$((classified+1))
      elif lc_rows setup | awk -F'|' -v j="$job" -v s="$step" '$1==j && $2==s {found=1} END{exit !found}'; then
        classified=$((classified+1))
      else
        fail "step '$step' in job '$job' ($wfname) is neither a registry check nor declared setup — classify it in tests/layer-checks.conf"
      fi
    done <<< "$steps_out"
  done <<< "$jobs_out"
done < <(lc_rows workflow | awk -F'|' '$2 == "classified" { print $1 }')

# A classification pass that classified NOTHING must not report success: a
# parser change or a workflow reorganisation would otherwise turn this whole
# section into a silent no-op that still goes green.
if [[ "$classified" -gt 0 ]]; then
  pass "every job/step in hermetic-checks.yml and tests.yml is accounted for ($classified item(s))"
else
  fail "classified no jobs or steps at all — the workflow parse returned nothing"
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
