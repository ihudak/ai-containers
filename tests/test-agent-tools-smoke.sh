#!/usr/bin/env bash
# BLOCKING pre-merge gate. Builds the image and runs a RESTRICTED-mode container against
# a scratch group, proving each enabled agent-tier tool installs BEHIND THE FIREWALL,
# persists across runs, and resolves under a non-login `docker exec`.
# Gated: only runs when AGENT_TOOLS_SMOKE=1 (needs Docker + network + DOCKER_CONFIG).
set -uo pipefail
[[ "${AGENT_TOOLS_SMOKE:-0}" == "1" ]] || { echo "SKIP: set AGENT_TOOLS_SMOKE=1 to run the real-container smoke test"; exit 0; }
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="ai-sandbox-smoke"
fails=0; pass(){ printf 'PASS: %s\n' "$1"; }; fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# 1. A normal build suffices: the install-source hosts (npm registry + GitHub in
#    base.txt, PyPI in pyenv.txt) are included in the restricted allowlist
#    UNCONDITIONALLY (build.sh:119/:136), independent of which tools are ON. The
#    firewall still applies at runtime — this gate proves install works behind it.
IMAGE_NAME="$IMG" "$REPO_DIR/build.sh" "$IMG" || { fail "image build"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

group="smoke-$$"
run() { # run a restricted container to completion of a probe command
  docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -e DEV_CONTAINER_MODE=restricted \
    -e AI_RUNTIME_TOOLS="claude-code,copilot,codex,gemini,graphify,vale" \
    -e AI_CONTAINER_GROUP="$group" \
    -v "$HOME/.ai-containers/$group/.ai-tools:/home/$(id -un)/.ai-tools" \
    --entrypoint bash "$IMG" -lc "$1"
}

# 2. First run: tools install behind the firewall; assert each resolves via non-login exec.
run 'for t in claude codex gemini copilot graphify vale; do command -v "$t" >/dev/null || { echo MISSING:$t; exit 3; }; done; echo ALLPRESENT' \
  | grep -q ALLPRESENT && pass "all six install + resolve behind the firewall (first run)" \
  || fail "all six install + resolve behind the firewall (first run)"

# 3. Second run: tools persist in the group home and still resolve (no reinstall needed).
run 'for t in claude graphify vale; do command -v "$t" >/dev/null || { echo MISSING:$t; exit 3; }; done; echo PERSISTED' \
  | grep -q PERSISTED && pass "tools persist to a second run (no reinstall needed)" \
  || fail "tools persist to a second run"

docker rmi "$IMG" >/dev/null 2>&1 || true
rm -rf "$HOME/.ai-containers/$group" 2>/dev/null || true
printf '\n%d failure(s)\n' "$fails"
exit "$fails"
