#!/usr/bin/env bash
# Integration tests for install-agent-skills.sh using fake tool binaries.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export TOOLS_D_DIR="$TMP/tools.d"; mkdir -p "$TOOLS_D_DIR"
export TOOLS_LIB="$REPO_DIR/tools-lib.sh"
cat > "$TOOLS_D_DIR/faketool.conf" <<'EOF'
binary=faketool
skills=yes
skills_crossclient=--for cross-client
EOF

# Fake tool: logs each invocation, prints a version.
mkdir -p "$TMP/bin"; CALLS="$TMP/calls.txt"
cat > "$TMP/bin/faketool" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "faketool 1.0.0"; exit 0; fi
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$TMP/bin/faketool"
export PATH="$TMP/bin:$PATH"
export AI_AGENTS_ENABLED="claude-code,copilot"

bash "$REPO_DIR/install-agent-skills.sh"
grep -q "skills install --for cross-client --global --force" "$CALLS" && pass "cross-client" || fail "cross-client"
grep -q "skills install --for claude --global --force"       "$CALLS" && pass "claude mapped" || fail "claude mapped"
grep -q "skills install --for copilot --global --force"      "$CALLS" && pass "copilot" || fail "copilot"
[[ -f "$HOME/.agents/.ai-containers-skills-stamp" ]] && pass "stamp written" || fail "stamp written"

# Second run with unchanged version → no new calls (stamp hit).
: > "$CALLS"
bash "$REPO_DIR/install-agent-skills.sh"
[[ ! -s "$CALLS" ]] && pass "stamp no-op" || fail "stamp no-op ($(cat "$CALLS"))"

# Version bump → stamp mismatches → installs re-run despite an existing stamp.
cat > "$TMP/bin/faketool" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "faketool 2.0.0"; exit 0; fi
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$TMP/bin/faketool"
: > "$CALLS"
bash "$REPO_DIR/install-agent-skills.sh"
grep -q "skills install --for claude --global --force" "$CALLS" && pass "version bump re-installs" || fail "version bump re-installs"

# A tool whose `skills install` always fails (unsupported everywhere): the script
# must skip it, never fail, and still exit 0. Use a fresh HOME so no stamp short-circuits.
cat > "$TOOLS_D_DIR/badtool.conf" <<'EOF'
binary=badtool
skills=yes
skills_crossclient=--for cross-client
EOF
cat > "$TMP/bin/badtool" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "badtool 1.0.0"; exit 0; fi
exit 1   # every skills-install attempt fails
EOF
chmod +x "$TMP/bin/badtool"
export HOME="$TMP/home2"; mkdir -p "$HOME"
bash "$REPO_DIR/install-agent-skills.sh"; rc=$?
[[ "$rc" -eq 0 ]] && pass "failing tool never fails start" || fail "failing tool never fails start (rc=$rc)"
[[ -f "$HOME/.agents/.ai-containers-skills-stamp" ]] && pass "stamp written despite failing tool" || fail "stamp after failing tool"

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
