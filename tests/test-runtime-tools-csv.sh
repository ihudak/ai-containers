#!/usr/bin/env bash
# Unit test for runtime_tools_csv(): ON/OFF filtering, kiro excluded, graphify/vale included.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Stub the config layer runtime_tools_csv depends on: is_enabled reads a fake ON-set.
ENABLED_SET=""
is_enabled() { [[ " $ENABLED_SET " == *" $1 "* ]]; }

# Load the REAL runtime_tools_csv from sandbox-common.sh — extract just the function so
# the file's heavy top-level code does not run — and exercise it against our is_enabled stub.
eval "$(sed -n '/^runtime_tools_csv()/,/^}/p' "$REPO_DIR/sandbox-common.sh")"

ENABLED_SET="claude-code gemini kiro"
got="$(runtime_tools_csv)"
[[ "$got" == "claude-code,gemini" ]] && pass "filters ON tools, preserves order" || fail "filters ON tools (got '$got')"

ENABLED_SET="kiro"
[[ -z "$(runtime_tools_csv)" ]] && pass "kiro alone yields empty (kiro excluded)" || fail "kiro must be excluded"

ENABLED_SET="graphify vale copilot codex"
[[ "$(runtime_tools_csv)" == "copilot,codex,graphify,vale" ]] && pass "graphify+vale included" || fail "graphify+vale must be included"

# The REAL implementation in sandbox-common.sh must match this contract.
grep -q 'runtime_tools_csv()' "$REPO_DIR/sandbox-common.sh" && pass "sandbox-common.sh defines runtime_tools_csv" || fail "sandbox-common.sh must define runtime_tools_csv"
grep -q 'AI_RUNTIME_TOOLS' "$REPO_DIR/sandbox.sh" && pass "sandbox.sh passes AI_RUNTIME_TOOLS" || fail "sandbox.sh must pass AI_RUNTIME_TOOLS"
grep -q '\.ai-tools' "$REPO_DIR/sandbox.sh" && pass "sandbox.sh mounts ~/.ai-tools" || fail "sandbox.sh must mount ~/.ai-tools"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
