#!/usr/bin/env bash
# tests/test-layer-checks-parser.sh — the registry/YAML parser is TESTED, not
# trusted. A parser that silently returns nothing is this repo's signature
# defect: every consumer would then iterate zero rows and report success having
# checked nothing, which is precisely the class of failure the guard it feeds
# exists to close. So every function here must FAIL LOUDLY on an empty result,
# and those failure paths are exercised below, not merely written.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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

# ── The registry ──────────────────────────────────────────────────────────────
n_check="$(lc_rows check | grep -c .)"
[[ "$n_check" -ge 1 ]] \
  && pass "lc_rows check returns $n_check row(s)" \
  || fail "lc_rows check returned nothing"

n_setup="$(lc_rows setup | grep -c .)"
[[ "$n_setup" -ge 1 ]] \
  && pass "lc_rows setup returns $n_setup row(s)" \
  || fail "lc_rows setup returned nothing"

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
