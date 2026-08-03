#!/usr/bin/env bash
# Drives link-agent-tools.sh against a FAKE ~/.ai-tools tree + a throwaway dest dir.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/link-agent-tools.sh" && pass "link-agent-tools.sh bash -n" || fail "link-agent-tools.sh bash -n"

# mk_tool HOME rel/path/binary → creates an executable stub at $HOME/.ai-tools/<rel>.
mk_tool() { install -d "$1/.ai-tools/$(dirname "$2")"; printf '#!/bin/sh\n' > "$1/.ai-tools/$2"; chmod +x "$1/.ai-tools/$2"; }

# ── Links every present tool binary into dest ──
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_tool "$h" npm/bin/claude; mk_tool "$h" npm/bin/copilot; mk_tool "$h" npm/bin/codex
mk_tool "$h" npm/bin/gemini; mk_tool "$h" uv/bin/graphify; mk_tool "$h" bin/vale
AI_RUNTIME_TOOLS="claude-code,copilot,codex,gemini,graphify,vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
ok=1
[[ -L "$d/claude"   && "$(readlink "$d/claude")"   == "$h/.ai-tools/npm/bin/claude" ]]   || ok=0
[[ -L "$d/graphify" && "$(readlink "$d/graphify")" == "$h/.ai-tools/uv/bin/graphify" ]]   || ok=0
[[ -L "$d/vale"     && "$(readlink "$d/vale")"     == "$h/.ai-tools/bin/vale" ]]          || ok=0
[[ "$ok" == 1 ]] && pass "links all present tools (npm/uv/bin sources)" || fail "links all present tools"
rm -rf "$h" "$d"

# ── Only links what exists (missing gemini is skipped, no dangling link) ──
h="$(mktemp -d)"; d="$(mktemp -d)"; mk_tool "$h" npm/bin/claude
AI_RUNTIME_TOOLS="claude-code,gemini" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/claude" && ! -L "$d/gemini" ]] && pass "only links existing binaries (no dangling)" || fail "only links existing binaries"
rm -rf "$h" "$d"

# ── Empty tool home → clean no-op ──
h="$(mktemp -d)"; d="$(mktemp -d)"
AI_RUNTIME_TOOLS="claude-code,vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && -z "$(ls -A "$d")" ]] && pass "empty tool home → exit 0, dest empty" || fail "empty tool home → exit 0, dest empty"
rm -rf "$h" "$d"

# ── No AI_RUNTIME_TOOLS → no-op ──
h="$(mktemp -d)"; d="$(mktemp -d)"; mk_tool "$h" npm/bin/claude
( unset AI_RUNTIME_TOOLS; bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" ) >/dev/null 2>&1
[[ -z "$(ls -A "$d")" ]] && pass "no AI_RUNTIME_TOOLS is a no-op" || fail "no AI_RUNTIME_TOOLS is a no-op"
rm -rf "$h" "$d"

# ── Guards ──
grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/link-agent-tools.sh" && fail "must NOT enable nounset" || pass "does not enable nounset"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
