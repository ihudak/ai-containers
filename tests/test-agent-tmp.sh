#!/usr/bin/env bash
# Tests for the scratch places an agent's work survives a container restart in.
#
# Containers run with --rm, so only a group directory outlives one. These cases
# cover ~/.cache and ~/.local/state, which are mounted WHOLE from the group
# whatever sandbox.conf says: a nested mount per tool (qmd, Playwright, Claude
# Code) left every other tool's cache and state to vanish with the container.
#
# A fake `docker` on PATH captures the `docker run` arguments, so nothing is
# launched. Later cases (a /var/tmp folder per container, pruning) extend the
# fake and add cases below the marker at the end.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # <description> <command...>
  local desc="$1"; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

REAL_HOME="$HOME"

setup() {  # $1 = sandbox.conf body
  TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  export HOME="$TMP/home"; mkdir -p "$HOME"
  # Physical HOME, so expectations built from it match the canonicalised -v
  # arguments sandbox.sh composes where the temp root is itself a link (macOS).
  HOME="$(p_realdir "$HOME")"; export HOME
  export AI_CONTAINER_GROUP_INIT=clean
  export SANDBOX_USER=dev
  unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS AI_CONTAINER_GROUP
  export SANDBOX_CONF="$TMP/sandbox.conf"
  printf '# schema-version: 4\n%s\n' "${1:-qmd=OFF
playwright=OFF
claude-code=OFF}" > "$SANDBOX_CONF"

  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"

  GROUP_ROOT="$HOME/.ai-containers/default"
  mkdir -p "$TMP/app" "$TMP/launch"
}
teardown() {
  rm -rf "$TMP"
  unset SANDBOX_CONF AI_CONTAINER_GROUP AI_CONTAINER_GROUP_INIT SANDBOX_USER
  export HOME="$REAL_HOME"
}

# Launched from a temp dir: sandbox.sh writes its .agent-* output dirs into $PWD.
run_sandbox() {
  ERR="$TMP/stderr.txt"
  ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app" ) >"$TMP/stdout.txt" 2>"$ERR" </dev/null
  RC=$?
}

# mounted <host-src> <container-dst> — is that exact rw bind flag in the captured args?
mounted() { grep -qx -- "$1:$2:rw" "$CAPTURE"; }

# ── ~/.cache and ~/.local/state, whole ──────────────────────────────────────────
setup
run_sandbox
check "sandbox.sh exits 0 (rc=$RC)" test "$RC" -eq 0
check "cache: ~/.cache mounted whole from the group, whatever sandbox.conf says" \
  mounted "$GROUP_ROOT/.cache" "/home/dev/.cache"
check "state: ~/.local/state mounted whole" \
  mounted "$GROUP_ROOT/.local/state" "/home/dev/.local/state"
check "both made in the group" \
  test -d "$GROUP_ROOT/.cache" -a -d "$GROUP_ROOT/.local/state"
teardown

# A nested mount under either would shadow part of the whole one.
setup 'qmd=ON
playwright=ON
claude-code=ON'
run_sandbox
check "no nested mount under ~/.cache or ~/.local/state" \
  bash -c '! grep -qE ":/home/dev/\.(cache|local/state)/" "$1"' _ "$CAPTURE"
check "claude-code still gets its own share dir" \
  mounted "$GROUP_ROOT/.local/share/claude" "/home/dev/.local/share/claude"
teardown

# ── group bootstrap: only the qmd index is carried, as before ───────────────────
setup
SRC="$HOME/.ai-containers/srcgrp"
mkdir -p "$SRC/.cache/qmd" "$SRC/.cache/pip" "$SRC/.local/state"
: > "$SRC/.cache/qmd/i"; : > "$SRC/.cache/pip/p"; : > "$SRC/.local/state/s"
NEW="$HOME/.ai-containers/newgrp"
AI_CONTAINER_GROUP=newgrp AI_CONTAINER_GROUP_INIT=from:srcgrp run_sandbox
check "slice: qmd still copied, other caches and state not" \
  bash -c '[[ -f "$1/.cache/qmd/i" && ! -e "$1/.cache/pip/p" && ! -e "$1/.local/state/s" ]]' _ "$NEW"
teardown

# (later cases: /var/tmp per container, pruning)

if [[ $fails -eq 0 ]]; then printf 'ALL PASS\n'; else printf '%d FAILED\n' "$fails"; exit 1; fi
