#!/usr/bin/env bash
# Drives agent-tools-reconcile.sh against STUBBED npm/uv/curl/tar/dpkg (no network).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/agent-tools-reconcile.sh" && pass "agent-tools-reconcile.sh bash -n" || fail "agent-tools-reconcile.sh bash -n"

# Create a fake toolchain in $1(bin dir), writing installs into $2(home). NPM_FAIL=1
# makes npm exit 1 (simulate offline). Each fake records to $2/calls.log.
mk_stubs() {
  local bin="$1" home="$2"
  cat > "$bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >> "$home/calls.log"
[[ "\${NPM_FAIL:-0}" == "1" ]] && exit 1
if [[ "\$1 \$2" == "install -g" ]]; then
  case "\$3" in
    @anthropic-ai/claude-code) b=claude ;; @github/copilot) b=copilot ;;
    @openai/codex) b=codex ;; @google/gemini-cli) b=gemini ;; *) b="" ;;
  esac
  [[ -n "\$b" ]] && { install -d "$home/.ai-tools/npm/bin"; printf '#!/bin/sh\n' > "$home/.ai-tools/npm/bin/\$b"; chmod +x "$home/.ai-tools/npm/bin/\$b"; }
fi
exit 0
EOF
  cat > "$bin/uv" <<EOF
#!/usr/bin/env bash
echo "uv \$*" >> "$home/calls.log"
if [[ "\$1 \$2" == "tool install" ]]; then
  d="\${UV_TOOL_BIN_DIR:-$home/.ai-tools/uv/bin}"; install -d "\$d"; printf '#!/bin/sh\n' > "\$d/graphify"; chmod +x "\$d/graphify"
fi
exit 0
EOF
  cat > "$bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$home/calls.log"
for a in "\$@"; do case "\$a" in *releases/latest) echo "https://github.com/vale-cli/vale/releases/tag/v3.0.0"; exit 0;; esac; done
prev=""; for a in "\$@"; do [[ "\$prev" == "-o" ]] && : > "\$a"; prev="\$a"; done
exit 0
EOF
  cat > "$bin/tar" <<EOF
#!/usr/bin/env bash
echo "tar \$*" >> "$home/calls.log"
d=""; prev=""; for a in "\$@"; do [[ "\$prev" == "-C" ]] && d="\$a"; prev="\$a"; done
[[ -n "\$d" ]] && { printf '#!/bin/sh\n' > "\$d/vale"; chmod +x "\$d/vale"; }
exit 0
EOF
  printf '#!/usr/bin/env bash\necho amd64\n' > "$bin/dpkg"
  chmod +x "$bin/npm" "$bin/uv" "$bin/curl" "$bin/tar" "$bin/dpkg"
}

# run_case WANT [HOME] [NPM_FAIL] -> echoes the home dir it used (caller inspects & cleans).
run_case() {
  local want="$1" home="${2:-$(mktemp -d)}" npm_fail="${3:-0}"
  local bin; bin="$(mktemp -d)"
  mk_stubs "$bin" "$home"
  PATH="$bin:$PATH" HOME="$home" AI_RUNTIME_TOOLS="$want" NPM_FAIL="$npm_fail" \
    bash "$REPO_DIR/agent-tools-reconcile.sh" >"$home/out.log" 2>&1
  rm -rf "$bin"
  printf '%s' "$home"
}

# ── All six install on a fresh home ──
h="$(run_case "claude-code,copilot,codex,gemini,graphify,vale")"
c="$h/calls.log"
grep -q 'npm install -g @anthropic-ai/claude-code' "$c" && pass "installs claude-code" || fail "installs claude-code"
grep -q 'npm install -g @github/copilot' "$c"           && pass "installs copilot"     || fail "installs copilot"
grep -q 'npm install -g @openai/codex' "$c"             && pass "installs codex"       || fail "installs codex"
grep -q 'npm install -g @google/gemini-cli' "$c"        && pass "installs gemini"      || fail "installs gemini"
grep -q 'uv tool install graphifyy' "$c"                && pass "installs graphify"    || fail "installs graphify"
grep -q 'tar ' "$c"                                     && pass "installs vale (tar)"  || fail "installs vale (tar)"
[[ -x "$h/.ai-tools/bin/vale" ]] && pass "vale binary lands at .ai-tools/bin/vale" || fail "vale binary lands at .ai-tools/bin/vale"
[[ -L "$h/.local/bin/claude" ]] && pass "claude native-path symlink created" || fail "claude native-path symlink created"
[[ "$(readlink "$h/.local/bin/claude")" == "$h/.ai-tools/npm/bin/claude" ]] && pass "claude symlink points at npm/bin/claude" || fail "claude symlink points at npm/bin/claude"
[[ -f "$h/.ai-tools/.reconcile.lock" ]] && pass "reconcile lock file created" || fail "reconcile lock file created"
rm -rf "$h"

# ── Idempotent: a second run on the SAME home does NOT reinstall ──
h="$(mktemp -d)"; run_case "claude-code,graphify,vale" "$h" >/dev/null; : > "$h/calls.log"; run_case "claude-code,graphify,vale" "$h" >/dev/null
[[ ! -s "$h/calls.log" || -z "$(grep -E 'install' "$h/calls.log")" ]] && pass "idempotent: present tools not reinstalled" || fail "idempotent: present tools not reinstalled"
rm -rf "$h"

# ── Empty AI_RUNTIME_TOOLS → no-op ──
h="$(run_case "")"; [[ ! -s "$h/calls.log" ]] && pass "empty AI_RUNTIME_TOOLS is a no-op" || fail "empty AI_RUNTIME_TOOLS is a no-op"; rm -rf "$h"

# ── Selective: only codex requested → only codex installed ──
h="$(run_case "codex")"; { grep -q 'npm install -g @openai/codex' "$h/calls.log" && ! grep -q '@google/gemini-cli' "$h/calls.log"; } && pass "installs only requested tools" || fail "installs only requested tools"; rm -rf "$h"

# ── Offline npm: FAILED logged, non-fatal, other tools still attempted ──
h="$(run_case "claude-code,graphify" "" 1)"
{ grep -q 'FAILED' "$h/out.log" && grep -q 'uv tool install graphifyy' "$h/calls.log"; } && pass "npm failure is non-fatal; other tools proceed" || fail "npm failure is non-fatal; other tools proceed"; rm -rf "$h"

# ── Exit code: script must exit 0 whether or not an install fails (non-fatal) ──
h="$(mktemp -d)"; bin="$(mktemp -d)"; mk_stubs "$bin" "$h"
PATH="$bin:$PATH" HOME="$h" AI_RUNTIME_TOOLS="claude-code,copilot,codex,gemini,graphify,vale" NPM_FAIL=0 \
  bash "$REPO_DIR/agent-tools-reconcile.sh" >"$h/out.log" 2>&1
rc=$?
rm -rf "$bin" "$h"
[[ "$rc" -eq 0 ]] && pass "exit code 0 when all installs succeed" || fail "exit code 0 when all installs succeed"

h="$(mktemp -d)"; bin="$(mktemp -d)"; mk_stubs "$bin" "$h"
PATH="$bin:$PATH" HOME="$h" AI_RUNTIME_TOOLS="claude-code,graphify" NPM_FAIL=1 \
  bash "$REPO_DIR/agent-tools-reconcile.sh" >"$h/out.log" 2>&1
rc=$?
rm -rf "$bin" "$h"
[[ "$rc" -eq 0 ]] && pass "exit code 0 when npm install fails (non-fatal)" || fail "exit code 0 when npm install fails (non-fatal)"

# ── Guards ──
grep -qE 'flock[[:space:]]+9' "$REPO_DIR/agent-tools-reconcile.sh" && pass "flock-guarded (real call, not just the header comment)" || fail "flock-guarded (real call, not just the header comment)"
grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/agent-tools-reconcile.sh" && fail "must NOT enable nounset" || pass "does not enable nounset"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
