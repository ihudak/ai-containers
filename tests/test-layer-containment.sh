#!/usr/bin/env bash
# tests/test-layer-containment.sh — the suite runs in three layers, and the
# invariant is local ⊇ nightly ⊇ PR.
#
# Stated as prose this decays, exactly as the "seen failing" rule decayed before
# tests/test-mutations.sh made it mechanical. The concrete failure this catches:
# verify-on-host.sh ran the integration corpus and NOTHING else, so a developer
# verifying locally checked less than CI would — the local layer was a SUBSET of
# the PR gate.
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
TESTS_YML="$REPO_DIR/.github/workflows/tests.yml"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
RUN="$REPO_DIR/tests/integration/run.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

for f in "$TESTS_YML" "$VERIFY" "$RUN"; do
  [[ -f "$f" ]] || { fail "$(basename "$f") not found — nothing below is checked"; \
    printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }
done

# ── Every PR-layer check also runs locally ─────────────────────────────────────
# name|regex matching its invocation in tests.yml|regex matching it in verify-on-host.sh
CHECKS='hermetic suite|run-all\.sh|run-all\.sh
schema gate|check-sandbox-version\.sh|check-sandbox-version\.sh
floor suite|container: ubuntu:22\.04|ubuntu:22\.04
bash -n|bash -n|bash -n
dialect lint|bash-dialect-lint\.sh|bash-dialect-lint\.sh
shellcheck|shellcheck|shellcheck'
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  name="${row%%|*}"; rest="${row#*|}"
  ci_re="${rest%%|*}"; local_re="${rest#*|}"
  if ! grep -qE "$ci_re" "$TESTS_YML"; then
    fail "$name is invoked by tests.yml — it is not, so this row is stale"
    continue
  fi
  if grep -qE "$local_re" "$VERIFY"; then
    pass "$name runs in the local layer too"
  else
    fail "$name runs in CI but NOT in verify-on-host.sh — local is not a superset"
  fi
done <<< "$CHECKS"

# ── The named list cannot police what it does not name ─────────────────────────
# A hand-written list validates only what someone remembered — the exact failure
# the mgd port shipped, where the byte-identity gate iterated the same list it
# was meant to police. So pin the STEP COUNT per job: a new CI step must be
# given a layer, and cannot widen the PR gate past the local one unnoticed.
#   suite:       checkout, bash version, rsync, run tests, schema gate  = 5
#   suite-floor: install git+rsync, checkout, bash version, run tests   = 4
#   lint:        checkout, bash -n, dialect lint, shellcheck            = 4
expect_steps() {  # $1=job $2=expected count
  local got
  got="$(awk -v j="$1" '
    $0 ~ "^  "j":$" {inj=1; next}
    inj && /^  [a-z]/ {inj=0}
    inj && /^      - / {c++}
    END {print c+0}' "$TESTS_YML")"
  if [[ "$got" == "$2" ]]; then
    pass "tests.yml job '$1' has $2 step(s)"
  else
    fail "tests.yml job '$1' has $got step(s), baseline says $2 — a step was added or removed; give it a layer in verify-on-host.sh, then update this baseline"
  fi
}
expect_steps suite 5
expect_steps suite-floor 4
expect_steps lint 4

# The floor job must run the image matching the DECLARED floor. If bash-floor.sh
# says 5.1 and the job runs ubuntu:24.04 (bash 5.2), the floor is untested again
# and nothing else would notice.
# shellcheck source=../bash-floor.sh
source "$ENGINE_DIR/bash-floor.sh"
floor="${AI_CONTAINERS_BASH_FLOOR_MAJOR}.${AI_CONTAINERS_BASH_FLOOR_MINOR}"
case "$floor" in
  5.1) want_img="ubuntu:22.04" ;;
  5.2) want_img="ubuntu:24.04" ;;
  *)   want_img="" ;;
esac
if [[ -z "$want_img" ]]; then
  fail "no container image is mapped to floor $floor — suite-floor cannot test the claim"
elif grep -qF "container: $want_img" "$TESTS_YML"; then
  pass "suite-floor runs $want_img, matching the declared floor $floor"
else
  fail "suite-floor does not run $want_img — the declared floor $floor is untested"
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
