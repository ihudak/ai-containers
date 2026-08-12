#!/usr/bin/env bash
# tests/lib-layer-checks.sh — parser for tests/layer-checks.conf and for the
# narrow slice of workflow YAML the containment guard needs. SOURCED, never
# executed directly, and deliberately NOT named test-*.sh so tests/run-all.sh's
# glob skips it (same reason as tests/lib-verify-repo.sh).
#
# CONTRACT: the sourcing file sets LAYER_CHECKS_CONF to the registry path before
# sourcing. Provides lc_rows(), wf_jobs(), wf_steps(), wf_job_key(),
# wf_triggers_on().
#
# lc_rows is generic over the registry's row TYPE — it already serves `check`
# and `setup` rows; the `workflow` row type (added to close the containment
# guard's fourth finding — a brand-new pull_request-triggered workflow was
# invisible to a hardcoded two-file classification list) needs no change here,
# only new rows in tests/layer-checks.conf.
#
# EVERY function here fails loudly and non-zero on an empty result. That is the
# whole point: a parser returning nothing quietly would make its consumer
# iterate zero rows and report success having verified nothing -- the exact
# defect the guard this feeds was written to catch.
#
# The YAML handling is a narrow awk reader for the shape these workflow files
# use (2-space job ids, 4-space `steps:`, 6-space `- ` step starts, 8-space step
# keys), NOT a general YAML parser. yq is not guaranteed on a developer's
# machine and skipping the check when it is absent would mean a check that does
# not run. A reformat that breaks this reader makes the guard RED, never green:
# zero jobs and zero steps are both hard errors.

lc_rows() {  # $1=check|setup → matching rows, type field stripped
  local want="${1:?lc_rows: row type required}" out
  [[ -f "${LAYER_CHECKS_CONF:-}" ]] || {
    echo "lib-layer-checks: LAYER_CHECKS_CONF is unset or missing: ${LAYER_CHECKS_CONF:-<unset>}" >&2
    return 1
  }
  out="$(grep -v '^[[:space:]]*#' "$LAYER_CHECKS_CONF" \
         | grep "^${want}|" \
         | sed "s/^${want}|//")"
  [[ -n "$out" ]] || {
    echo "lib-layer-checks: no '$want' rows in $LAYER_CHECKS_CONF" >&2
    return 1
  }
  printf '%s\n' "$out"
}

_wf_awk() {  # $1=yaml  $2=job filter ('' = list jobs instead of steps)
  awk -v job="$2" '
    function val(s) {
      sub(/^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      return s
    }
    function grab(s) {
      if (s ~ /^name:[[:space:]]/)      { nm = val(s) }
      else if (s ~ /^uses:[[:space:]]/) { us = val(s) }
    }
    function flush() {
      if (started) { print (nm != "" ? nm : (us != "" ? us : "(unnamed step)")) }
      started = 0; nm = ""; us = ""
    }
    BEGIN { inj = 0; injob = 0; insteps = 0; started = 0; nm = ""; us = "" }
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    # Any column-0 key ends the jobs block (permissions:, on:, a trailing key).
    inj && /^[^[:space:]#]/ { flush(); inj = 0; injob = 0; insteps = 0 }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      flush()
      cur = $0; sub(/^  /, "", cur); sub(/:[[:space:]]*$/, "", cur)
      if (job == "") { print cur }
      injob = (cur == job); insteps = 0; next
    }
    injob && /^    steps:[[:space:]]*$/ { insteps = 1; next }
    # A 4-space key after steps: ends the step list (none today, but a job with
    # `steps:` followed by another job-level key must not swallow it).
    injob && insteps && /^    [A-Za-z]/ { flush(); insteps = 0; next }
    insteps && /^      - / {
      flush(); started = 1
      line = $0; sub(/^      - /, "", line); grab(line); next
    }
    insteps && started && /^        [A-Za-z]/ {
      line = $0; sub(/^        /, "", line); grab(line); next
    }
    END { flush() }
  ' "$1"
}

wf_jobs() {  # $1=workflow yaml → job ids, one per line
  local f="${1:?wf_jobs: workflow path required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(_wf_awk "$f" "")"
  [[ -n "$out" ]] || { echo "lib-layer-checks: no jobs found in $f" >&2; return 1; }
  printf '%s\n' "$out"
}

wf_steps() {  # $1=workflow yaml  $2=job id → step identities, one per line
  local f="${1:?wf_steps: workflow path required}"
  local j="${2:?wf_steps: job id required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(_wf_awk "$f" "$j")"
  [[ -n "$out" ]] || { echo "lib-layer-checks: job '$j' in $f has no steps" >&2; return 1; }
  printf '%s\n' "$out"
}

# wf_job_key reads a JOB-LEVEL key (4-space indented, directly under a named
# job — e.g. a reusable-workflow caller's `uses:`, or its `if:` gate), as
# opposed to wf_steps' 8-space step keys. Added for the containment guard's
# nightly/PR assertions, which used to `grep -qF` a pattern against the WHOLE
# workflow file — passing on a job commented out in place (the comment still
# contains the string being grepped for). This reuses the same block-aware
# state machine as wf_jobs/wf_steps: a commented-out job's header line
# ("  # hermetic:") does not match the job-start pattern, so it never becomes
# `injob`, and a key read against it fails loudly at its actual cause instead
# of matching stale text.
wf_job_key() {  # $1=yaml  $2=job id  $3=job-level key (e.g. uses, if) → value
  local f="${1:?wf_job_key: workflow path required}"
  local j="${2:?wf_job_key: job id required}"
  local k="${3:?wf_job_key: key required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(awk -v job="$j" -v key="$k" '
    function val(s) {
      sub(/^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      return s
    }
    BEGIN { inj = 0; injob = 0 }
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    # Any column-0 key ends the jobs block, same as _wf_awk.
    inj && /^[^[:space:]#]/ { inj = 0; injob = 0 }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      cur = $0; sub(/^  /, "", cur); sub(/:[[:space:]]*$/, "", cur)
      injob = (cur == job)
      next
    }
    injob && /^    [A-Za-z0-9_-]+:/ {
      line = $0; sub(/^    /, "", line)
      k2 = line; sub(/:.*/, "", k2)
      if (k2 == key) { print val(line); exit }
      next
    }
    ' "$f")"
  [[ -n "$out" ]] || {
    echo "lib-layer-checks: job '$j' has no '$k:' key in $f (job absent, key absent, or job commented out)" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# wf_triggers_on is a PREDICATE, unlike every function above it — "the trigger
# is absent" is an ordinary, expected outcome (most workflows do not trigger on
# pull_request), not an empty-result error, so it does not follow this file's
# fail-loudly-on-empty convention. Only a missing file/arg is a loud failure;
# a genuine "no" is a quiet rc=1.
#
# Added for tests/test-layer-containment.sh to VERIFY a `workflow` row's
# `coverage=exempt` claim against the file's own `on:` block, rather than
# trusting its <why> prose — the same effect-over-text-presence standard this
# project applies everywhere else (see AGENTS.md: "the suite asserts effect,
# not configuration"). Narrow reader, like _wf_awk: matches only the BLOCK form
# `on:\n  <trigger>:`, which is the shape every workflow in this repo uses, not
# flow-style `on: [push, pull_request]`. A line inside a step's `run:` script
# that merely mentions the trigger name (e.g. a comment) must NOT count — the
# scan is bounded to the on: block by column-0 lines ending it, same rule
# wf_jobs/wf_steps use to bound the jobs: block.
wf_triggers_on() {  # $1=yaml  $2=trigger name (e.g. pull_request) → rc 0 present, rc 1 absent
  local f="${1:?wf_triggers_on: workflow path required}"
  local trig="${2:?wf_triggers_on: trigger name required}"
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  awk -v trig="$trig" '
    /^on:[[:space:]]*$/ { ion = 1; next }
    ion && /^[^[:space:]#]/ { ion = 0 }
    ion && $0 ~ ("^  " trig ":") { found = 1 }
    END { exit !found }
  ' "$f"
}
