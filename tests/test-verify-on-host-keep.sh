#!/usr/bin/env bash
# Asserts verify-on-host.sh never reports Phase 3 FAILED for a run that passed.
#
# The bug this pins: "keep the artifacts" and "the phase failed" shared one
# variable. The failure path set KEEP_RUBY_IMAGE=1, and the cleanup block then
# read that same variable as the failure verdict — so a human setting
# KEEP_RUBY_IMAGE=1 to probe a HEALTHY image was told:
#
#     Phase 3 FAILED — kept for re-probing:
#
# printed directly beneath a log showing Ruby installed, every binary resolving
# through a non-login shell, and the second run reusing the volume with no
# recompile. A verifier that reports the opposite of what it just measured is
# worse than one that reports nothing: it is "green because we did not look"
# inverted, and it teaches you to distrust the line that matters.
#
# Static/hermetic: reads the script, runs no Docker. The two reasons for keeping
# must stay SEPARATE variables — that separation is the whole fix, so it is what
# gets asserted, not the wording around it.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: upstream keeps the engine at the repo root, mgd-ai-containers
# keeps it in base/. One copy serves both.
VOH="$REPO_DIR/verify-on-host.sh"
[[ -f "$VOH" ]] || VOH="$REPO_DIR/base/verify-on-host.sh"

fails=0
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -f "$VOH" ]] && pass "verify-on-host.sh exists" || {
  fail "verify-on-host.sh exists"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }
bash -n "$VOH" >/dev/null 2>&1 && pass "verify-on-host.sh bash -n" \
  || fail "verify-on-host.sh bash -n"

# The failure path must record a FAILURE, not a keep request.
if grep -qE '^[[:space:]]*RUBY_PHASE_FAILED=1[[:space:]]*$' "$VOH"; then
  pass "the failure path sets RUBY_PHASE_FAILED (not KEEP_RUBY_IMAGE)"
else
  fail "the failure path sets RUBY_PHASE_FAILED (not KEEP_RUBY_IMAGE)"
fi
if grep -qE '^[[:space:]]*KEEP_RUBY_IMAGE=1[[:space:]]*$' "$VOH"; then
  fail "no code path ASSIGNS KEEP_RUBY_IMAGE — it is a human-supplied input only"
else
  pass "no code path assigns KEEP_RUBY_IMAGE — it is a human-supplied input only"
fi

# Keeping must trigger on either reason.
if grep -q 'RUBY_PHASE_FAILED:-0.*==.*"1".*||.*KEEP_RUBY_IMAGE:-0.*==.*"1"' "$VOH"; then
  pass "artifacts are kept when EITHER the phase failed or the human asked"
else
  fail "artifacts are kept when EITHER the phase failed or the human asked"
fi

# The verdict line must be chosen by the failure flag alone. Guard against a
# regression that reports failure whenever anything is kept: every occurrence of
# the FAILED banner must sit inside a RUBY_PHASE_FAILED test.
#
# Comment lines are excluded. The comment above the fix QUOTES the banner to
# explain the bug, and scanning it as code flagged the explanation as the
# defect — the same false positive the workflow scanner in
# tests/test-exec-bits.sh hit, for the same reason. A checker that reads prose
# as code will always find the thing the prose is about.
failed_banner_lines="$(awk '/Phase 3 FAILED/ && $0 !~ /^[[:space:]]*#/ {print NR}' "$VOH")"
if [[ -z "$failed_banner_lines" ]]; then
  fail "the 'Phase 3 FAILED' banner still exists (a real failure must still say so)"
else
  pass "the 'Phase 3 FAILED' banner exists for real failures"
  bad=0
  while IFS= read -r ln; do
    [[ -z "$ln" ]] && continue
    # The nearest enclosing condition is within the few lines above the banner.
    if ! sed -n "$((ln > 4 ? ln - 4 : 1)),${ln}p" "$VOH" | grep -q 'RUBY_PHASE_FAILED'; then
      bad=1
      printf '     line %s is not guarded by RUBY_PHASE_FAILED\n' "$ln"
    fi
  done <<< "$failed_banner_lines"
  [[ "$bad" -eq 0 ]] \
    && pass "every 'Phase 3 FAILED' banner is guarded by RUBY_PHASE_FAILED" \
    || fail "every 'Phase 3 FAILED' banner is guarded by RUBY_PHASE_FAILED"
fi

# A passing run that keeps its artifacts must say so in as many words, otherwise
# the honest branch exists but stays invisible to whoever reads the log.
if grep -q 'Phase 3 PASSED — kept at your request' "$VOH"; then
  pass "a kept-but-passing run says PASSED, naming KEEP_RUBY_IMAGE as the reason"
else
  fail "a kept-but-passing run says PASSED, naming KEEP_RUBY_IMAGE as the reason"
fi

# Documented, since it is now a supported input rather than an internal flag.
grep -q 'KEEP_RUBY_IMAGE=1 PHASES=3' "$VOH" \
  && pass "KEEP_RUBY_IMAGE is documented in the usage header" \
  || fail "KEEP_RUBY_IMAGE is documented in the usage header"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
