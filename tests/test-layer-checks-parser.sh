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

# fails_naming checks BOTH halves of a loud failure: a non-zero status AND the
# message that names the cause. Status alone is not enough for the guards below.
# Delete wf_jobs' missing-file guard outright and wf_jobs still fails on a
# missing file -- one branch later, at "no jobs found", because the awk it feeds
# produced nothing -- so a status-only assertion goes on passing over a guard
# that is no longer there. Reading the message is what binds the assertion to
# the guard under test. (Backlog F18: these guards' `return 1` -> `return 0`
# mutants survived the entire suite.)
fails_naming() {  # $1=label  $2=required stderr substring  $3.. = the command
  local label="$1" want="$2" err rc; shift 2
  err="$("$@" 2>&1 >/dev/null)"; rc=$?
  if (( rc == 0 )); then
    fail "$label (reported success, rc 0)"
  elif [[ "$err" != *"$want"* ]]; then
    fail "$label (failed, but stderr never named the cause: wanted '*$want*', got '$err')"
  else
    pass "$label"
  fi
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
# grep-q-ok: this line IS the hazard — the control's whole job is to be the piped spelling and lose the race
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
# The missing-file guard, in all three functions tests/test-layer-containment.sh
# calls. wf_triggers_on's identical guard (further down) was the only one any
# test reached, which left these three free to report success on a workflow file
# that is not there -- and the containment guard would then iterate zero jobs,
# zero steps, and pass having checked nothing. $TMP/nosuchworkflow.yml is never
# created, here or anywhere below.
fails_naming "wf_jobs fails loudly for a workflow file that does not exist" \
  "no such workflow: $TMP/nosuchworkflow.yml" \
  wf_jobs "$TMP/nosuchworkflow.yml"

fails_naming "wf_steps fails loudly for a workflow file that does not exist" \
  "no such workflow: $TMP/nosuchworkflow.yml" \
  wf_steps "$TMP/nosuchworkflow.yml" anyjob

fails_naming "wf_job_key fails loudly for a workflow file that does not exist" \
  "no such workflow: $TMP/nosuchworkflow.yml" \
  wf_job_key "$TMP/nosuchworkflow.yml" anyjob uses

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

# rc 2, not 1: a missing file is "cannot tell", and the containment guard fails
# an exempt row on 2 where it would pass it on 1.
wf_triggers_on "$TMP/nosuchworkflow.yml" pull_request >/dev/null 2>&1
check "wf_triggers_on reports a workflow file that does not exist as rc 2 (cannot tell)" 2 "$?"
fails_naming "wf_triggers_on names the missing workflow file" \
  "no such workflow: $TMP/nosuchworkflow.yml" \
  wf_triggers_on "$TMP/nosuchworkflow.yml" pull_request

# ── wf_triggers_on: every spelling GitHub accepts (TST-6) ─────────────────────
# The reader used to match only `on:` alone on its line followed by a key at
# exactly two spaces. A workflow written `on: [push, pull_request]` that runs
# ./tests/run-all.sh, registered as coverage=exempt, then passed as "verified
# NOT pull_request-triggered" — the bypass the registry exists to close. Each
# spelling below is one GitHub accepts; each gets a positive and a negative.
# A shape the reader does not understand is rc 2, never a quiet "no": an exempt
# claim that cannot be checked must not pass as verified.
trig_rc() {  # $1=yaml body → wf_triggers_on's rc for pull_request
  printf '%s\n' "$1" > "$TMP/trig.yml"
  wf_triggers_on "$TMP/trig.yml" pull_request 2>/dev/null
  printf '%s' "$?"
}
check "on: <scalar> naming the trigger" 0 "$(trig_rc 'on: pull_request')"
check "on: <scalar> naming another trigger" 1 "$(trig_rc 'on: push')"
check "on: <scalar> with a trailing comment" 0 "$(trig_rc 'on: pull_request  # gate')"
check "on: [flow, list] holding the trigger" 0 "$(trig_rc 'on: [push, pull_request]')"
check "on: [flow, list] with quoted entries" 0 "$(trig_rc "on: [ 'push', \"pull_request\" ]")"
check "on: [flow, list] without the trigger" 1 "$(trig_rc 'on: [push, workflow_dispatch]')"
check "on: followed by a - sequence holding the trigger" 0 \
  "$(trig_rc "$(printf 'on:\n  - push\n  - pull_request\njobs:\n  x:\n    runs-on: y')")"
check "on: followed by an unindented - sequence (valid YAML)" 0 \
  "$(trig_rc "$(printf 'on:\n- push\n- pull_request\njobs:\n  x:\n    runs-on: y')")"
check "on: followed by a - sequence without the trigger" 1 \
  "$(trig_rc "$(printf 'on:\n  - push\njobs:\n  x:\n    runs-on: y')")"
check "on: block map indented four spaces" 0 \
  "$(trig_rc "$(printf 'on:\n    push:\n    pull_request:\n        branches: [main]\njobs:\n  x:\n    runs-on: y')")"
check "on: block map: a deeper key of the same name is not a trigger" 1 \
  "$(trig_rc "$(printf 'on:\n  workflow_run:\n    types:\n      pull_request:\njobs:\n  x:\n    runs-on: y')")"
check "on: block map with a quoted key" 0 \
  "$(trig_rc "$(printf "on:\n  'pull_request':\njobs:\n  x:\n    runs-on: y")")"
check "a quoted \"on\": key" 0 \
  "$(trig_rc "$(printf '"on":\n  pull_request:\njobs:\n  x:\n    runs-on: y')")"
check "pull_request_target is not pull_request (block map)" 1 \
  "$(trig_rc "$(printf 'on:\n  pull_request_target:\njobs:\n  x:\n    runs-on: y')")"
check "pull_request_target is not pull_request (flow list)" 1 "$(trig_rc 'on: [pull_request_target]')"
check "pull_request_target is not pull_request (scalar)" 1 "$(trig_rc 'on: pull_request_target')"
check "a flow list spanning lines cannot be read: rc 2, not a quiet no" 2 \
  "$(trig_rc "$(printf 'on: [push,\n  pull_request]\njobs:\n  x:\n    runs-on: y')")"
check "a flow map cannot be read: rc 2" 2 "$(trig_rc 'on: { push: { branches: [main] } }')"
check "a file with no on: key cannot be read: rc 2" 2 \
  "$(trig_rc "$(printf 'name: x\njobs:\n  x:\n    runs-on: y')")"
check "on: with nothing under it cannot be read: rc 2" 2 \
  "$(trig_rc "$(printf 'on:\njobs:\n  x:\n    runs-on: y')")"
# A plain scalar continued on the next line is the value, not a key.
check "on: with a plain scalar on the next line naming the trigger" 0 \
  "$(trig_rc "$(printf 'on:\n  pull_request\njobs:\n  x:\n    runs-on: y')")"
check "on: with a plain scalar on the next line naming another trigger" 1 \
  "$(trig_rc "$(printf 'on:\n  push\njobs:\n  x:\n    runs-on: y')")"
# Only a MATCHED pair of quotes is stripped: a value that opens with a quote it
# never closes is not the trigger name, whatever lies between.
check "an unmatched leading double quote is not stripped" 1 "$(trig_rc 'on: "pull_requestx')"
check "an unmatched leading single quote is not stripped" 1 "$(trig_rc "on: 'pull_requestx")"
check "comments and blank lines inside the on: block are skipped" 0 \
  "$(trig_rc "$(printf 'on:\n\n  # a comment\n  pull_request:\njobs:\n  x:\n    runs-on: y')")"

# ── wf_if_true: the if: shapes the workflows use, under one event ─────────────
# test-layer-containment.sh derives what each layer RUNS from the workflows
# (TST-2), so it has to know whether a job or step runs for the layer's event.
# It understands only the shapes these files use, and says so (rc 2) for
# anything else rather than guessing. Every input is empty outside
# workflow_dispatch, which is what makes the inputs.* forms decidable.
ifrc() { wf_if_true "$1" "$2" 2>/dev/null; printf '%s' "$?"; }
check "if: absent runs" 0 "$(ifrc '' schedule)"
check "if: always() runs" 0 "$(ifrc 'always()' schedule)"
check "if: success() runs on a green run" 0 "$(ifrc 'success()' pull_request)"
check "if: failure() does not run on a green run" 1 "$(ifrc 'failure()' schedule)"
check "event == matching" 0 "$(ifrc "github.event_name == 'schedule'" schedule)"
check "event == other" 1 "$(ifrc "github.event_name == 'schedule'" pull_request)"
check "event != other" 0 "$(ifrc "github.event_name != 'workflow_dispatch'" pull_request)"
check "event != matching" 1 "$(ifrc "github.event_name != 'pull_request'" pull_request)"
check "the \${{ }} wrapper is unwrapped" 0 "$(ifrc "\${{ github.event_name == 'schedule' }}" schedule)"
check "a double-quoted value is unquoted" 0 "$(ifrc "\"github.event_name == 'schedule'\"" schedule)"
check "inputs.x != 'v' is true when inputs are empty" 0 "$(ifrc "\${{ inputs.tags != 'packages' }}" schedule)"
check "inputs.x == 'v' is false when inputs are empty" 1 "$(ifrc "inputs.tags == 'packages'" schedule)"
check "inputs.* cannot be decided under workflow_dispatch" 2 "$(ifrc "inputs.tags != 'packages'" workflow_dispatch)"
check "an expression it does not know is rc 2, not a guess" 2 "$(ifrc "contains(github.ref, 'main')" schedule)"
check "a compound expression is rc 2" 2 "$(ifrc "always() && github.event_name == 'schedule'" schedule)"

# ── wf_it_selections: what a workflow RUNS for one event (TST-2, GAP-5) ───────
# The containment guard used to hold its own copy of each layer's run.sh
# arguments; the PR copy was a literal and nightly was modelled as "everything
# outside packages, plus every packages case", which no job ran: a packages
# case with no image: header was credited to nightly while no nightly job
# selected it. This reads every `tests/integration/run.sh` invocation from the
# workflow itself, as the event sees it.
cat > "$TMP/it.yml" <<'YAML'
name: Fixture-it
on:
  schedule:
    - cron: '1 2 * * *'
  pull_request:
  workflow_dispatch:
    inputs:
      cases:
        default: ''

jobs:
  caller:
    if: github.event_name == 'schedule'
    uses: ./.github/workflows/hermetic-checks.yml

  full:
    runs-on: x
    if: ${{ inputs.tags != 'packages' }}
    steps:
      - uses: actions/checkout@v7

      - name: Catalogue
        run: ./tests/integration/run.sh --list

      - name: Folded
        run: >-
          ./tests/integration/run.sh --require security
          ${{ inputs.tags && format('--tags {0}', inputs.tags) || '' }}
          --exclude packages${{ inputs.exclude && format(',{0}', inputs.exclude) || '' }}

      - name: Diagnostics
        if: failure()
        run: |
          ./tests/integration/run.sh --tags never-on-green

  gated:
    runs-on: x
    steps:
      - name: Dispatch only
        if: github.event_name == 'workflow_dispatch'
        run: |
          args="--tags x"
          ./tests/integration/run.sh $args

      - name: Literal
        if: github.event_name != 'workflow_dispatch'
        run: |
          # ./tests/integration/run.sh --tags commented-out
          echo before
          bash tests/integration/run.sh --tags fast --exclude needs-dns 2>&1 | tee log

      - run: ./tests/integration/run.sh --tags packages --variant agents
        if: always()

  scheduled:
    if: github.event_name == 'schedule'
    runs-on: x
    steps:
      - name: Nightly only
        run: ./tests/integration/run.sh --tags slow   # a trailing comment
YAML

check "wf_it_selections: the scheduled view" \
  "$(printf '%s\n' 'full|Folded|--require security --exclude packages' \
                   'gated|Literal|--tags fast --exclude needs-dns' \
                   'gated|(unnamed step)|--tags packages --variant agents' \
                   'scheduled|Nightly only|--tags slow')" \
  "$(wf_it_selections "$TMP/it.yml" schedule)"

check "wf_it_selections: the pull_request view drops the schedule-gated job" \
  "$(printf '%s\n' 'full|Folded|--require security --exclude packages' \
                   'gated|Literal|--tags fast --exclude needs-dns' \
                   'gated|(unnamed step)|--tags packages --variant agents')" \
  "$(wf_it_selections "$TMP/it.yml" pull_request)"

out="$(wf_it_selections "$TMP/it.yml" push 2>&1)"; rc=$?
check "wf_it_selections: a workflow the event does not trigger contributes nothing (rc 0)" "0|" "$rc|$out"

fails_naming "wf_it_selections refuses workflow_dispatch, whose inputs are not empty" \
  "workflow_dispatch" wf_it_selections "$TMP/it.yml" workflow_dispatch

fails_naming "wf_it_selections fails loudly for a workflow file that does not exist" \
  "no such workflow: $TMP/nosuchworkflow.yml" \
  wf_it_selections "$TMP/nosuchworkflow.yml" schedule

printf 'name: x\non: { schedule: [] }\njobs:\n  j:\n    runs-on: x\n    steps:\n      - run: ./tests/integration/run.sh --tags a\n' > "$TMP/it-on.yml"
fails_naming "wf_it_selections fails when it cannot tell whether the event triggers the workflow" \
  "cannot read the on: block" wf_it_selections "$TMP/it-on.yml" schedule

# A plain run: value is folded as YAML folds it: a line break is a space, a
# BLANK line is a newline. So the second step below runs `run.sh --tags c` and
# then a separate command, `--exclude d`, which run.sh never sees.
cat > "$TMP/it-plain.yml" <<'YAML'
on:
  schedule:
jobs:
  j:
    runs-on: x
    steps:
      - name: Continued
        run: ./tests/integration/run.sh --tags a
          --exclude b

      - name: Broken by a blank line
        run: ./tests/integration/run.sh --tags c

          --exclude d

      - name: Folded, broken by a blank line
        run: >-
          ./tests/integration/run.sh --tags e

          --exclude f

      - name: Folded, broken by a more-indented line
        run: >-
          ./tests/integration/run.sh --tags g
            --exclude h
YAML
check "wf_it_selections folds plain and > values as YAML does, a blank or more-indented line ending the command" \
  "$(printf '%s\n' 'j|Continued|--tags a --exclude b' 'j|Broken by a blank line|--tags c' \
                   'j|Folded, broken by a blank line|--tags e' 'j|Folded, broken by a more-indented line|--tags g')" \
  "$(wf_it_selections "$TMP/it-plain.yml" schedule)"

printf 'on:\n  schedule:\njobs:\n  j:\n    runs-on: x\n    steps:\n      - name: Var\n        run: ./tests/integration/run.sh $ARGS\n' > "$TMP/it-var.yml"
fails_naming "wf_it_selections fails, naming the step, on arguments it cannot render" \
  "j/Var" wf_it_selections "$TMP/it-var.yml" schedule

printf 'on:\n  schedule:\njobs:\n  j:\n    runs-on: x\n    steps:\n      - name: Bare\n        run: ./tests/integration/run.sh --tags ${{ inputs.tags }}\n' > "$TMP/it-bare.yml"
fails_naming "wf_it_selections renders only the guarded inputs idiom, not a bare \${{ inputs.x }}" \
  "j/Bare" wf_it_selections "$TMP/it-bare.yml" schedule

printf "on:\n  schedule:\njobs:\n  j:\n    runs-on: x\n    steps:\n      - name: Odd\n        if: contains(github.ref, 'x')\n        run: ./tests/integration/run.sh --tags a\n" > "$TMP/it-if.yml"
fails_naming "wf_it_selections fails, naming the step, on a step if: it cannot evaluate" \
  "j/Odd" wf_it_selections "$TMP/it-if.yml" schedule

printf "on:\n  schedule:\njobs:\n  j:\n    if: contains(github.ref, 'x')\n    runs-on: x\n    steps:\n      - name: Fine\n        run: ./tests/integration/run.sh --tags a\n" > "$TMP/it-jif.yml"
fails_naming "wf_it_selections fails, naming the job, on a job if: it cannot evaluate" \
  "job 'j'" wf_it_selections "$TMP/it-jif.yml" schedule

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

grep -q '^#' < <(lc_rows check) \
  && fail "lc_rows returned a comment line" \
  || pass "lc_rows strips comments and blank lines"

grep -q '^check|' < <(lc_rows check) \
  && fail "lc_rows left the type field on the row" \
  || pass "lc_rows strips the leading type field"

LAYER_CHECKS_CONF="$TMP/empty.conf"; printf '# only a comment\n' > "$LAYER_CHECKS_CONF"
if lc_rows check >/dev/null 2>&1; then
  fail "lc_rows reported success on a registry with no rows"
else
  pass "lc_rows fails loudly on a registry with no rows"
fi

# The registry guard is separate from the no-rows one above: it fires before any
# parsing, and its own `return 1` was unreached because every case up to here
# pointed LAYER_CHECKS_CONF at a file that exists. Both spellings of "no
# registry" go through it.
LAYER_CHECKS_CONF="$TMP/absent.conf"
fails_naming "lc_rows fails loudly when LAYER_CHECKS_CONF names a file that is not there" \
  "LAYER_CHECKS_CONF is unset or missing: $TMP/absent.conf" \
  lc_rows check

# Unset, not merely wrong: lc_rows reads the variable as ${LAYER_CHECKS_CONF:-},
# and this suite runs under `set -u`. Drop that default and the read aborts the
# shell instead of reporting the cause -- which the message assertion catches,
# because an "unbound variable" abort names nothing.
unset LAYER_CHECKS_CONF
fails_naming "lc_rows fails loudly, and still diagnoses, when LAYER_CHECKS_CONF is unset entirely" \
  "LAYER_CHECKS_CONF is unset or missing: <unset>" \
  lc_rows check
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
