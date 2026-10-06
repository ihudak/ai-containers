#!/usr/bin/env bash
# Unit tests for the `claude-code-sandbox` sandbox.conf key.
#
# The key buys three things: the bubblewrap + socat packages and the managed
# settings file at build time (one build arg), and the two --security-opt flags
# bubblewrap needs at run time. These are wiring assertions. That bubblewrap then
# starts inside a container run with those flags is a claim no hermetic test can
# make; it needs a Docker host.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
trap 'rm -rf "${TMP:-}" "${F1:-}"' EXIT

# ── Part A: build.sh — the build arg ───────────────────────────────────────────
for state in ON OFF; do
  F1="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  printf '# schema-version: 4\nclaude-code-sandbox=%s\n' "$state" > "$F1/sandbox.conf"
  want=0; [[ "$state" == ON ]] && want=1
  out="$(
    export SANDBOX_CONF="$F1/sandbox.conf"
    # shellcheck source=/dev/null
    source "$REPO_DIR/build.sh"
    declare -a args=()
    build_args_from_config args
    printf '%s\n' "${args[@]}"
  )"
  if grep -qx "INSTALL_CLAUDE_CODE_SANDBOX=$want" <<<"$out"; then
    pass "claude-code-sandbox=$state: INSTALL_CLAUDE_CODE_SANDBOX=$want"
  else
    fail "claude-code-sandbox=$state: INSTALL_CLAUDE_CODE_SANDBOX=$want"
  fi
  rm -rf "$F1"
done

# ── Part B: sandbox.sh — the run flags ─────────────────────────────────────────
# A fake `docker` on PATH captures the assembled `docker run` argv, the harness
# test-tool-config-mounts.sh established. No daemon involved.
REAL_HOME="$HOME"
cs_setup() {  # $1 = sandbox.conf body
  TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  export HOME="$TMP/home"; mkdir -p "$HOME"
  HOME="$(p_realdir "$HOME")"; export HOME
  export AI_CONTAINER_GROUP_INIT=clean
  export SANDBOX_USER=dev
  unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS AI_CONTAINER_GROUP CONTAINER_SHM_SIZE
  export SANDBOX_CONF="$TMP/sandbox.conf"
  printf '# schema-version: 4\n%s\n' "$1" > "$SANDBOX_CONF"
  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin" "$TMP/app" "$TMP/launch"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"
}
cs_teardown() {
  rm -rf "$TMP"
  unset SANDBOX_CONF AI_CONTAINER_GROUP_INIT SANDBOX_USER
  export HOME="$REAL_HOME"
}
cs_run() { ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app" ) >/dev/null 2>&1 </dev/null; }

cs_setup 'claude-code-sandbox=ON'
cs_run
security_opts="$(grep -A1 -x -- '--security-opt' "$CAPTURE")"
for opt in seccomp=unconfined apparmor=unconfined; do
  if grep -qx -- "$opt" <<<"$security_opts"; then
    pass "claude-code-sandbox=ON: --security-opt $opt"
  else
    fail "claude-code-sandbox=ON: --security-opt $opt"
  fi
done
cs_teardown

# OFF: every container that does not ask for the inner sandbox keeps Docker's
# default profiles — the flags must not leak into it.
cs_setup 'claude-code-sandbox=OFF'
cs_run
if [[ -s "$CAPTURE" ]] && ! grep -q -- '--security-opt' "$CAPTURE"; then
  pass "claude-code-sandbox=OFF: no --security-opt flag"
else
  fail "claude-code-sandbox=OFF: no --security-opt flag"
fi
cs_teardown

# ── Part C: the managed settings file holds the boundary ───────────────────────
# Each line below is a property the docs page promises; a settings edit that
# drops one turns the sandbox back into a prompt-saver Claude can step out of.
S="$REPO_DIR/claude-managed-settings.json"
for want in '"enabled": true' '"failIfUnavailable": true' '"allowUnsandboxedCommands": false' \
            '"strictAllowlist": true' '"name": "GITHUB_PERSONAL_ACCESS_TOKEN", "mode": "deny"' \
            '"name": "COPILOT_GITHUB_TOKEN", "mode": "deny"'; do
  if grep -qF -- "$want" "$S"; then pass "managed settings: $want"; else fail "managed settings: $want"; fi
done
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$S" 2>/dev/null; then
    pass "managed settings: valid JSON"
  else
    fail "managed settings: valid JSON"
  fi
fi

[[ $fails -eq 0 ]] && exit 0 || exit 1
