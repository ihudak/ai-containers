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
TESTS_YML="$REPO_DIR/.github/workflows/hermetic-checks.yml"
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
for f in "$TESTS_YML" "$VERIFY" "$RUN" "$LIB_VERIFY_REPO"; do
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

# ── Build a stub repo and run the REAL verify-on-host.sh against it ────────────
# tests/lib-verify-repo.sh (shared with tests/test-verify-exit-code.sh — see
# its own header for why this is one copy, not two) gives us mk_repo(),
# run_verify() and $WITNESS_LOG. mk_repo() copies $VERIFY as-is, so this picks
# up whatever is on disk right now, local edits included — the same property
# that lets Step 3-style demonstrations (comment out a real invocation, keep
# the naming comment) actually exercise this file.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=lib-verify-repo.sh
source "$LIB_VERIFY_REPO"

r="$(mk_repo 0)"
# bash -n has no external tool of its own to stub, so its effect proof is
# different in kind: a tracked file with a REAL syntax error. Phase 7 can only
# print "PARSE ERROR: <path>" for it if `bash -n` genuinely runs against this
# file's actual content — a comment that merely names "bash -n" could never
# produce this line, unlike a plain substring match against the script text.
printf '#!/usr/bin/env bash\nif [ 1 -eq\n' > "$r/tests/broken-syntax-probe.sh"
( cd "$r" && git add -A \
    && git -c user.email=t@example -c user.name=t commit -q -m broken-probe ) >/dev/null 2>&1

# PHASES="5 7" covers every check named in CHECKS below in one hermetic run.
# The deliberately broken probe file makes Phase 7 report FAILED — expected
# and irrelevant here: this run's purpose is the WITNESS/log content it
# leaves behind, not its own exit code.
run_verify "$r" "5 7" >/dev/null

# ── Every PR-layer check also runs locally — EFFECT, not text presence ─────────
# name|regex matching its invocation in tests.yml|witness or log|regex matching
# a witness/log line that only appears if the check GENUINELY ran
#
#   witness → grep against $WITNESS_LOG (each stub's OWN "STUB:<name>" line;
#             see lib-verify-repo.sh's header for why the docker-run line uses
#             a different prefix than tests/run-all.sh's own line, even though
#             the floor invocation's argv also embeds the string "run-all.sh")
#   log     → grep against $TMP/out.log (verify-on-host.sh's own stdout/stderr)
CHECKS='hermetic suite|run-all\.sh|witness|^STUB:run-all\.sh$
schema gate|check-sandbox-version\.sh|witness|^STUB:check-sandbox-version\.sh$
floor suite|container: ubuntu:22\.04|witness|^STUB:docker-run.*ubuntu:22\.04
bash -n|bash -n|log|PARSE ERROR: .*broken-syntax-probe\.sh
dialect lint|bash-dialect-lint\.sh|witness|^STUB:bash-dialect-lint\.sh$
shellcheck|shellcheck|witness|^STUB:shellcheck$'
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  name="${row%%|*}"; rest="${row#*|}"
  ci_re="${rest%%|*}"; rest2="${rest#*|}"
  target="${rest2%%|*}"; expect_re="${rest2#*|}"
  if ! grep -qE "$ci_re" "$TESTS_YML"; then
    fail "$name is invoked by tests.yml — it is not, so this row is stale"
    continue
  fi
  case "$target" in
    witness) hay="$WITNESS_LOG" ;;
    log)     hay="$TMP/out.log" ;;
    *) fail "$name: unrecognised CHECKS target '$target' — this row is broken"; continue ;;
  esac
  if grep -qE "$expect_re" "$hay"; then
    pass "$name runs in the local layer too (observed actually running)"
  else
    fail "$name runs in CI but was NOT OBSERVED RUNNING in verify-on-host.sh (no witness — local is not a superset)"
  fi
done <<< "$CHECKS"

# ── The named list cannot police what it does not name ─────────────────────────
# A hand-written list validates only what someone remembered — the exact failure
# the mgd port shipped, where the byte-identity gate iterated the same list it
# was meant to police. So pin the STEP COUNT per job: a new CI step must be
# given a layer, and cannot widen the PR gate past the local one unnoticed.
#   suite:       checkout, bash version, rsync, run tests, schema gate  = 5
#   suite-floor: install git+rsync, checkout, trust checkout (safe.directory),
#                bash version, run tests                                = 5
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
expect_steps suite-floor 5
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
