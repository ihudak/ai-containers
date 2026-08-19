#!/usr/bin/env bash
# tests/test-layer-checks-parser.sh — the registry/YAML parser is TESTED, not
# trusted. A parser that silently returns nothing is this repo's signature
# defect: every consumer would then iterate zero rows and report success having
# checked nothing, which is precisely the class of failure the guard it feeds
# exists to close. So every function here must FAIL LOUDLY on an empty result,
# and those failure paths are exercised below, not merely written.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # $1=label $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1 (expected '$2', got '$3')"; fi
}

LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
# shellcheck source=lib-layer-checks.sh
source "$REPO_DIR/tests/lib-layer-checks.sh"

# ── A well-formed two-job fixture, covering every shape the real files use ────
cat > "$TMP/wf.yml" <<'YAML'
name: Fixture
on:
  workflow_call:

permissions:
  contents: read

jobs:
  alpha:
    name: Alpha job
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - name: Plain step
        run: echo hi

      - name: "Quoted: has a colon"
        run: |
          echo multi
          echo line

  beta:
    runs-on: ubuntu-latest
    container: ubuntu:22.04
    steps:
      - name: Only step
        run: echo solo
YAML

check "wf_jobs lists every job in order" \
  "$(printf 'alpha\nbeta')" "$(wf_jobs "$TMP/wf.yml")"

check "wf_steps resolves name:, falls back to uses:, and keeps colons in quoted names" \
  "$(printf 'actions/checkout@v5\nPlain step\nQuoted: has a colon')" \
  "$(wf_steps "$TMP/wf.yml" alpha)"

check "wf_steps does not leak steps across job boundaries" \
  "Only step" "$(wf_steps "$TMP/wf.yml" beta)"

# ── wf_has_step, and the pipeline hazard it exists to remove ─────────────────
# `wf_steps "$f" "$j" | grep -qxF "$step"` is the obvious spelling and it is
# WRONG under `set -o pipefail`: grep -q exits on the match, the producer left
# mid-write takes the broken pipe, and pipefail promotes the producer's status
# over grep's success — so the pipeline says "no such step" about a step that
# is present. It shipped that way and produced a "this registry row is stale"
# failure with nothing stale, on a machine loaded by the falsify tier.
#
# The fixture makes that race DETERMINISTIC rather than waiting for a loaded
# machine: several thousand steps, far more than a pipe buffer holds, with the
# sought step FIRST so grep exits while the producer is still writing. Measured
# on the piped spelling: 200 false negatives out of 200. Reimplement
# wf_has_step with a pipe and the first assertion below fails every time.
{
  printf 'jobs:\n  big:\n    runs-on: x\n    steps:\n'
  printf '      - name: the first step\n'
  for _i in $(seq 1 8000); do printf '      - name: filler step %s\n' "$_i"; done
} > "$TMP/big.yml"
big_bytes="$(wc -c < "$TMP/big.yml")"
if [[ "$big_bytes" -gt 65536 ]]; then
  pass "fixture: the big-job step list is $big_bytes bytes, past any pipe buffer"
else
  fail "fixture: the big-job step list is only $big_bytes bytes — too small to lose the race, so the assertion below proves nothing"
fi

if wf_has_step "$TMP/big.yml" big "the first step"; then
  pass "wf_has_step finds a step that a grep -q pipeline would race past"
else
  fail "wf_has_step finds a step that a grep -q pipeline would race past"
fi
# The control: the piped spelling really does fail on this fixture, so the
# assertion above is measuring the fix and not a fixture that never raced.
if wf_steps "$TMP/big.yml" big 2>/dev/null | grep -qxF "the first step"; then
  fail "control: the piped spelling passed here, so this fixture does not exercise the hazard"
else
  pass "control: the piped spelling DOES lose the race on this fixture"
fi
# Still says no when the step is genuinely absent, and when the job is.
if wf_has_step "$TMP/wf.yml" alpha "no such step"; then
  fail "wf_has_step reported a step that is not there"
else
  pass "wf_has_step reports absence for a step that is not there"
fi
if wf_has_step "$TMP/wf.yml" nosuchjob "Plain step"; then
  fail "wf_has_step reported a step in a job that does not exist"
else
  pass "wf_has_step reports absence for a job that does not exist"
fi

# ── The failure paths, exercised ──────────────────────────────────────────────
printf 'name: NoJobs\non:\n  push:\n' > "$TMP/nojobs.yml"
if wf_jobs "$TMP/nojobs.yml" >/dev/null 2>&1; then
  fail "wf_jobs reported success on a file with no jobs"
else
  pass "wf_jobs fails loudly on a file with no jobs"
fi

printf 'jobs:\n  empty:\n    runs-on: x\n    steps:\n' > "$TMP/nosteps.yml"
if wf_steps "$TMP/nosteps.yml" empty >/dev/null 2>&1; then
  fail "wf_steps reported success on a job with no steps"
else
  pass "wf_steps fails loudly on a job with no steps"
fi

if wf_steps "$TMP/wf.yml" nosuchjob >/dev/null 2>&1; then
  fail "wf_steps reported success for a job that does not exist"
else
  pass "wf_steps fails loudly for a job that does not exist"
fi

# ── wf_job_key: job-level uses:/if:, and its failure paths ────────────────────
# Mirrors the shape of nightly.yml's real `hermetic` job (a reusable-workflow
# caller with an `if:` gate) plus a plain job with neither, and a job whose
# header is commented out — the exact real-world defeat this function exists
# to close (a `grep -qF` against the whole file still matches a comment).
cat > "$TMP/wf2.yml" <<'YAML'
name: Fixture2
on:
  workflow_call:

jobs:
  caller:
    if: github.event_name == 'schedule'
    uses: ./.github/workflows/hermetic-checks.yml

  plain:
    runs-on: ubuntu-latest
    steps:
      - name: Only step
        run: echo solo

  # commented:
  #   if: github.event_name == 'schedule'
  #   uses: ./.github/workflows/hermetic-checks.yml
YAML

check "wf_job_key resolves a job-level uses:" \
  "./.github/workflows/hermetic-checks.yml" "$(wf_job_key "$TMP/wf2.yml" caller uses)"

check "wf_job_key resolves a job-level if: (quotes inside the value untouched)" \
  "github.event_name == 'schedule'" "$(wf_job_key "$TMP/wf2.yml" caller if)"

if wf_job_key "$TMP/wf2.yml" plain uses >/dev/null 2>&1; then
  fail "wf_job_key reported success for a key absent from an existing job"
else
  pass "wf_job_key fails loudly when the job exists but the key does not (absent-key)"
fi

if wf_job_key "$TMP/wf2.yml" nosuchjob uses >/dev/null 2>&1; then
  fail "wf_job_key reported success for a job that does not exist"
else
  pass "wf_job_key fails loudly for a job that does not exist (absent-job)"
fi

# The commented-out job must not be readable AT ALL — not "readable with the
# wrong value". A regression back to a whole-file text grep would still see
# these lines; the block-aware parser must not enter them as job "commented".
if wf_job_key "$TMP/wf2.yml" commented uses >/dev/null 2>&1; then
  fail "wf_job_key reported success for a job whose header is commented out"
else
  pass "wf_job_key fails loudly for a commented-out job header (never becomes a job)"
fi

# ── wf_triggers_on: the on: block predicate, and its false-positive traps ──────
# Added for the containment guard's `workflow` row `coverage=exempt` claim: a
# row saying "this workflow never runs on pull_request" must be VERIFIED
# against the file, not trusted. wf3.yml carries a REAL pull_request trigger
# plus a decoy mention of the same word inside a step's run: script/comment —
# proving the function reads the on: block, not the whole file. wf4.yml is the
# mirror case: NO pull_request trigger, but the word appears in a step name and
# a run: comment anyway — the exact shape a whole-file grep would wrongly match.
cat > "$TMP/wf3.yml" <<'YAML'
name: Fixture3 - real trigger plus a same-word decoy
on:
  push:
    branches:
      - main
  pull_request:
  workflow_dispatch:

jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: mentions pull_request again, harmlessly
        run: |
          # pull_request should not need to be found HERE for the trigger to count
          echo done
YAML

cat > "$TMP/wf4.yml" <<'YAML'
name: Fixture4 - decoy only, no real trigger
on:
  push:
    branches:
      - main
  workflow_dispatch:

jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: "this step just talks about pull_request in its name"
        run: |
          # pull_request is mentioned here too, as a decoy
          echo pull_request
YAML

if wf_triggers_on "$TMP/wf3.yml" pull_request; then
  pass "wf_triggers_on finds a real pull_request trigger in the on: block"
else
  fail "wf_triggers_on missed a real pull_request trigger declared in the on: block"
fi

if wf_triggers_on "$TMP/wf3.yml" workflow_call; then
  fail "wf_triggers_on false-positived on workflow_call, which wf3.yml does not declare"
else
  pass "wf_triggers_on correctly reports an absent trigger (workflow_call not in wf3.yml)"
fi

if wf_triggers_on "$TMP/wf4.yml" pull_request; then
  fail "wf_triggers_on false-positived: wf4.yml mentions pull_request only OUTSIDE the on: block (a step name and a run: comment), never as a real trigger"
else
  pass "wf_triggers_on ignores a trigger name mentioned outside the on: block"
fi

if wf_triggers_on "$TMP/nosuchworkflow.yml" pull_request >/dev/null 2>&1; then
  fail "wf_triggers_on reported success for a workflow file that does not exist"
else
  pass "wf_triggers_on fails for a workflow file that does not exist"
fi

# ── The registry ──────────────────────────────────────────────────────────────
n_check="$(lc_rows check | grep -c .)"
[[ "$n_check" -ge 1 ]] \
  && pass "lc_rows check returns $n_check row(s)" \
  || fail "lc_rows check returned nothing"

n_setup="$(lc_rows setup | grep -c .)"
[[ "$n_setup" -ge 1 ]] \
  && pass "lc_rows setup returns $n_setup row(s)" \
  || fail "lc_rows setup returned nothing"

n_workflow="$(lc_rows workflow | grep -c .)"
[[ "$n_workflow" -ge 1 ]] \
  && pass "lc_rows workflow returns $n_workflow row(s)" \
  || fail "lc_rows workflow returned nothing"

# Every enumerated .github/workflows/*.yml file must have exactly one
# `workflow` row — the property tests/test-layer-containment.sh relies on to
# catch a brand-new workflow the day it is added. Checked here against the
# REAL registry and the REAL directory, not a fixture, because this is the
# actual contract the containment guard depends on.
#
# The comparison is against rows whose file EXISTS here, not the raw row
# count: tests/layer-checks.conf is shared byte-identically with a sibling
# repo whose .github/workflows/ holds a different file set, so a
# coverage=exempt row is allowed to name a file that does not exist in THIS
# repo (see the asymmetry note in tests/layer-checks.conf's `workflow`
# row-type block) — that row is inert here, not a drift, and must not be
# counted against this file-set parity check either.
n_wf_files="$(find "$REPO_DIR/.github/workflows" -maxdepth 1 -type f -name '*.yml' | wc -l | tr -d ' ')"
n_wf_rows_present=0
while IFS='|' read -r wf_row_file _wf_row_coverage _wf_row_why; do
  [[ -f "$REPO_DIR/.github/workflows/$wf_row_file" ]] && n_wf_rows_present=$((n_wf_rows_present+1))
done < <(lc_rows workflow)
[[ "$n_wf_files" -eq "$n_wf_rows_present" ]] \
  && pass "tests/layer-checks.conf has exactly one workflow row per .github/workflows/*.yml file that exists here ($n_wf_rows_present of $n_workflow row(s))" \
  || fail "tests/layer-checks.conf has $n_wf_rows_present workflow row(s) naming a file that exists here, but .github/workflows/ has $n_wf_files file(s) — they have drifted apart"

lc_rows check | grep -q '^#' \
  && fail "lc_rows returned a comment line" \
  || pass "lc_rows strips comments and blank lines"

lc_rows check | grep -q '^check|' \
  && fail "lc_rows left the type field on the row" \
  || pass "lc_rows strips the leading type field"

LAYER_CHECKS_CONF="$TMP/empty.conf"; printf '# only a comment\n' > "$LAYER_CHECKS_CONF"
if lc_rows check >/dev/null 2>&1; then
  fail "lc_rows reported success on a registry with no rows"
else
  pass "lc_rows fails loudly on a registry with no rows"
fi
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
