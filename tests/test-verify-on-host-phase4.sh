#!/usr/bin/env bash
# Asserts verify-on-host.sh's Phase 4 exists, is selected by default, and
# delegates the runtime integration corpus to tests/integration/run.sh instead
# of driving `docker run`/`docker build` itself.
#
# This is a static/hermetic check only — it does not run verify-on-host.sh
# against a real Docker daemon (this suite has none). It exists to catch the
# exact failure Phase 4's own header comment warns about: an earlier Phase 3
# kept bind-mounting ~/.rvm for two full verification rounds after the product
# moved to a Docker named volume, because it re-implemented sandbox.sh instead
# of calling it. A wrapper that re-grows its own docker invocations inside
# Phase 4 would be that same regression at the network-mode tier.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like verify-on-host.sh's own TESTS_DIR and the integration
# runner: upstream keeps the engine at the repo root, mgd-ai-containers keeps it
# in base/. One copy serves both verbatim — a second copy is how mgd's harness
# silently fell 117 lines behind.
VOH="$REPO_DIR/verify-on-host.sh"
[[ -f "$VOH" ]] || VOH="$REPO_DIR/base/verify-on-host.sh"
fails=0
pass(){ printf 'PASS: %s\n' "$1"; }
fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -f "$VOH" ]] && pass "verify-on-host.sh exists" || fail "verify-on-host.sh exists"
bash -n "$VOH" >/dev/null 2>&1 && pass "verify-on-host.sh bash -n" || fail "verify-on-host.sh bash -n"

# Phase 4 exists as its own selectable phase.
grep -q '^if want_phase 4; then$' "$VOH" && pass "Phase 4 is gated by want_phase 4" \
  || fail "Phase 4 is gated by want_phase 4"
grep -q 'PHASE 4 —' "$VOH" && pass "Phase 4 prints its own banner" \
  || fail "Phase 4 prints its own banner"

# Selected by default: PHASES="${PHASES:-...}" must include "4" as a
# space-separated token, not merely as a substring (which "14" would also
# match) — mirror the same word-boundary check want_phase() itself uses.
default_expr="$(grep -oE 'PHASES="\$\{PHASES:-[^}]*\}"' "$VOH" | head -1)"
if [[ -n "$default_expr" ]]; then
  default_val="$(printf '%s' "$default_expr" | sed -E 's/.*:-([^}]*)\}.*/\1/')"
  case " $default_val " in
    (*" 4 "*) pass "Phase 4 is in the default PHASES selection ($default_val)" ;;
    (*)       fail "Phase 4 is in the default PHASES selection ($default_val)" ;;
  esac
else
  fail "found a PHASES default assignment to check"
fi

# No network-mode test logic of its own: Phase 4's body must delegate to
# tests/integration/run.sh rather than drive docker directly. Extract the
# block between Phase 4's header comment and the pre-cleanup comment that
# already anchored the end of the phase list before this test existed.
phase4_block="$(sed -n '/# ── Phase 4: the runtime integration corpus/,/# :- defaults: a skipped phase/p' "$VOH")"
if [[ -z "$phase4_block" ]]; then
  fail "could not extract the Phase 4 block (anchors moved?)"
else
  if printf '%s\n' "$phase4_block" | grep -qE '\$\(TESTS_DIR\)?/integration/run\.sh|IT_RUNNER='; then
    pass "Phase 4 resolves tests/integration/run.sh as its runner"
  else
    fail "Phase 4 resolves tests/integration/run.sh as its runner"
  fi
  if printf '%s\n' "$phase4_block" | grep -qE 'bash "\$IT_RUNNER"'; then
    pass "Phase 4 invokes the runner via bash \"\$IT_RUNNER\""
  else
    fail "Phase 4 invokes the runner via bash \"\$IT_RUNNER\""
  fi
  # The regression this test guards against: Phase 4 growing its own `docker
  # run`/`docker build` calls instead of leaving that to run.sh. Strip
  # comment-only lines first so the header comment's prose about the
  # regression itself doesn't trip the check.
  code_only="$(printf '%s\n' "$phase4_block" | grep -vE '^[[:space:]]*#')"
  if printf '%s\n' "$code_only" | grep -qE 'docker[[:space:]]+(run|build|exec)\b'; then
    fail "Phase 4 contains no direct docker run/build/exec (found one)"
  else
    pass "Phase 4 contains no direct docker run/build/exec"
  fi
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
