#!/usr/bin/env bash
# Integration tests for install-agent-skills.sh using fake tool binaries.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; TMP_OWNER="$BASHPID"
# Guarded: the RT-9 cases fork (p_timeout, the lock holders), and a child must
# not run this trap on the fixture the script is still using.
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export TOOLS_D_DIR="$TMP/tools.d"; mkdir -p "$TOOLS_D_DIR"
export TOOLS_LIB="$REPO_DIR/tools-lib.sh"
cat > "$TOOLS_D_DIR/faketool.conf" <<'EOF'
binary=faketool
skills=yes
skills_crossclient=--for cross-client
EOF

# Fake tool: logs each invocation, prints a version. Like the real cobra CLIs
# (dtctl/dtmgd/junoctl) it exposes a `version` SUBCOMMAND, not a --version flag.
mkdir -p "$TMP/bin"; CALLS="$TMP/calls.txt"
cat > "$TMP/bin/faketool" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "version" ]]; then echo "faketool 1.0.0"; exit 0; fi
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

# Version bump (via the `version` subcommand) → stamp mismatches → installs
# re-run despite an existing stamp. Guards the real bug this replaced: a bogus
# version probe yields an empty stamp that never changes, so bumps go unnoticed.
cat > "$TMP/bin/faketool" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "version" ]]; then echo "faketool 2.0.0"; exit 0; fi
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$TMP/bin/faketool"
: > "$CALLS"
bash "$REPO_DIR/install-agent-skills.sh"
grep -q "skills install --for claude --global --force" "$CALLS" && pass "version bump re-installs" || fail "version bump re-installs"

# RT-2: the stamp is shared by every project in the group (~/.agents is group-
# mounted), so it must know WHICH agents got the skills, not only which tool
# versions: an agent enabled later got none until a tool's version changed.
export HOME="$TMP/home-rt2"; mkdir -p "$HOME"
AI_AGENTS_ENABLED="claude-code" bash "$REPO_DIR/install-agent-skills.sh" >/dev/null
: > "$CALLS"
AI_AGENTS_ENABLED="claude-code,copilot" bash "$REPO_DIR/install-agent-skills.sh" >/dev/null
grep -q "skills install --for copilot --global --force" "$CALLS" && pass "a newly enabled agent gets the skills" \
  || fail "a newly enabled agent got no skills (calls: $(tr '\n' ';' < "$CALLS"))"
grep -q -- "--for claude " "$CALLS" && fail "an agent already done was reinstalled ($(tr '\n' ';' < "$CALLS"))" \
  || pass "  … and only that agent is installed"
# A group shared by projects with different agent sets is not reinstalled on
# every alternation between them.
: > "$CALLS"
AI_AGENTS_ENABLED="claude-code" bash "$REPO_DIR/install-agent-skills.sh" >/dev/null
[[ ! -s "$CALLS" ]] && pass "alternating agent sets reinstalls nothing" || fail "alternation reinstalled ($(tr '\n' ';' < "$CALLS"))"

# Fallback path: a tool that supports ONLY `--version` (no `version` subcommand)
# must still yield a non-empty stamp so its skills install. Fresh HOME → no stamp.
cat > "$TOOLS_D_DIR/flagtool.conf" <<'EOF'
binary=flagtool
skills=yes
EOF
cat > "$TMP/bin/flagtool" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "flagtool 3.1.0"; exit 0; fi
if [[ "\$1" == "version" ]]; then exit 1; fi   # no version subcommand
printf 'flag %s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$TMP/bin/flagtool"
export HOME="$TMP/home-flag"; mkdir -p "$HOME"
: > "$CALLS"
bash "$REPO_DIR/install-agent-skills.sh"
grep -q "flag skills install --for claude --global --force" "$CALLS" && pass "flag-only tool installs (fallback)" || fail "flag-only tool installs (fallback)"
grep -q "flagtool=flagtool 3.1.0" "$HOME/.agents/.ai-containers-skills-stamp" && pass "flag-only stamp non-empty" || fail "flag-only stamp non-empty ($(cat "$HOME/.agents/.ai-containers-skills-stamp"))"
export HOME="$TMP/home"   # restore for any later assertions

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

# RT-9: the stamp is rewritten under a lock. Stock macOS has no flock(1): the
# installer then runs unlocked, and these checks cannot run.
if command -v flock >/dev/null 2>&1; then
  # Deterministic: the holder marks when it has the lock and when it lets go; the
  # installer, started once the lock is held, may only finish after the release.
  export HOME="$TMP/home-rt9"; mkdir -p "$HOME/.agents"
  lk="$HOME/.agents/.ai-containers-skills.lock"
  ( flock 8; : > "$TMP/held9"; sleep 2; : > "$TMP/released9" ) 8>>"$lk" &
  holder=$!
  for _ in $(seq 1 100); do [[ -e "$TMP/held9" ]] && break; sleep 0.05; done
  out9="$(AI_AGENTS_ENABLED="claude-code" bash "$REPO_DIR/install-agent-skills.sh" 2>&1)"
  if [[ -e "$TMP/released9" ]]; then rel9=yes; else rel9=no; fi
  wait "$holder"
  [[ -e "$TMP/held9" && "$rel9" == yes && "$out9" == *"waiting"* ]] \
    && pass "RT-9 the installer waits for the stamp lock, and says so" \
    || fail "RT-9 the installer did not wait for the stamp lock (finished after release: $rel9; $out9)"
  # Bounded: a holder that keeps the lock past the wait is outwaited, not obeyed.
  rm -f "$TMP/held9" "$TMP/released9"
  ( flock 8; : > "$TMP/held9"; exec sleep 6 ) 8>>"$lk" &
  holder=$!
  for _ in $(seq 1 100); do [[ -e "$TMP/held9" ]] && break; sleep 0.05; done
  t9=$SECONDS
  out9="$(AI_CONTAINERS_SKILLS_LOCK_WAIT=1 AI_AGENTS_ENABLED="copilot" bash "$REPO_DIR/install-agent-skills.sh" 2>&1)"
  t9=$((SECONDS - t9)); kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [[ "$t9" -lt 5 && "$out9" == *"still held"* ]] && grep -q $'^copilot\t' "$HOME/.agents/.ai-containers-skills-stamp" \
    && pass "RT-9 a lock held past the wait is given up on, and the skills still install (${t9}s)" \
    || fail "RT-9 a held lock held up the start (${t9}s; $out9)"
  # A lock path that is not a regular file is not opened: a FIFO would block.
  export HOME="$TMP/home-rt9f"; mkdir -p "$HOME/.agents"; mkfifo "$HOME/.agents/.ai-containers-skills.lock"
  t9=$SECONDS
  out9="$(AI_AGENTS_ENABLED="claude-code" p_timeout 20 bash "$REPO_DIR/install-agent-skills.sh" 2>&1)"; rc9=$?
  t9=$((SECONDS - t9))
  [[ "$rc9" == 0 && "$t9" -lt 5 && "$out9" == *"not a regular file"* ]] \
    && pass "RT-9 a FIFO at the lock path is not opened; the skills install unlocked (${t9}s)" \
    || fail "RT-9 a FIFO at the lock path (rc $rc9, ${t9}s; $out9)"
  # Two projects of one group starting together keep each other's lines.
  export HOME="$TMP/home-rt9b"; mkdir -p "$HOME"
  printf '#!/usr/bin/env bash\nif [[ "$1" == "version" ]]; then echo "faketool 3.0.0"; exit 0; fi\nsleep 1; exit 0\n' > "$TMP/bin/faketool"
  chmod +x "$TMP/bin/faketool"
  AI_AGENTS_ENABLED="claude-code" bash "$REPO_DIR/install-agent-skills.sh" >/dev/null & a=$!
  AI_AGENTS_ENABLED="copilot" bash "$REPO_DIR/install-agent-skills.sh" >/dev/null & b=$!
  wait "$a" "$b"
  st="$(cat "$HOME/.agents/.ai-containers-skills-stamp" 2>/dev/null)"
  grep -q $'^claude\t' <<<"$st" && grep -q $'^copilot\t' <<<"$st" \
    && pass "RT-9 two concurrent starts keep both projects' stamp lines" \
    || fail "RT-9 a concurrent start lost a project's stamp lines (stamp: $(tr '\t\n' ' ;' <<<"$st"))"
else
  printf 'SKIP: RT-9 the stamp lock checks need flock(1)\n'
fi

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
