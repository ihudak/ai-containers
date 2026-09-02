#!/usr/bin/env bash
# tests/test-repos-path.sh — REPOS_PATH must reach the container, always.
#
# WHAT THIS VARIABLE IS FOR. Plugins running inside the sandbox need to know
# where the code repositories are mounted. Everything the launcher attaches —
# the positional [primary], every REPOS entry, every EXTRA_MOUNTS path — lands
# under the /workspace umbrella, so that directory is the answer. Hardcoding it
# in each plugin would bake a layout decision that lives in sandbox.sh, so the
# launcher states it instead.
#
# WHY THE DEFAULT LIVES IN CODE AND NOT IN sandbox.env. `sandbox.env` is written
# ONCE by project-init.sh and `sync-to-projects.sh` deliberately never overwrites
# it. A default that lived only there would reach new projects and silently miss
# every project that already exists — which is all of them. So sandbox.sh carries
# the default and the env files stay pure override, which is also what makes the
# ordinary precedence (inline > sandbox.local.env > sandbox.env) apply for free.
#
# SCOPE. The two facts that belong to THIS variable: the default is composed when
# nothing is configured, and a configured value replaces it. The precedence
# BETWEEN sandbox.env and sandbox.local.env is load_env_defaults' behaviour and
# is covered by tests/test-sandbox-env.sh; asserting it again here would need a
# second isolated engine tree, the hand-picked-file-copy pattern that has already
# broken twelve fixtures at once in this repo when a new dependency appeared.
#
# Uses a fake `docker` on PATH to capture the assembled `docker run` args without
# launching a container — the same pattern as tests/test-docs-path.sh.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

setup() {
  TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  # Resolved once, here: sandbox.sh canonicalises paths before they reach the
  # docker argv, so an unresolved `mktemp -d` value compares unequal on any
  # platform whose temp dir is a symlink (macOS /var → /private/var).
  TMP="$(p_realdir "$TMP")"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export AI_CONTAINER_GROUP_INIT=clean   # non-interactive group bootstrap
  # Isolate from anything the invoking shell exports — a host profile, or this
  # repo's own dev container — so each case sees only what it sets itself.
  unset VAULT_PATH SPECS_PATH DOCS_PATH REPOS EXTRA_MOUNTS REPOS_PATH
  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
if [[ "\$1" == "volume" ]]; then exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"
}
teardown() { rm -rf "$TMP"; unset REPOS_PATH; }

run_sandbox() {
  mkdir -p "$TMP/launch"
  # Exit status is deliberately not captured: these cases assert what reached the
  # docker argv, and the fake `docker` already exits 0 for `run`. A status check
  # here would assert the harness, not the launcher.
  ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$@" ) \
    >"$TMP/stdout.txt" 2>"$TMP/stderr.txt" </dev/null || true
}

# ── Case 1: nothing configured → the default reaches the container ───────────
# UNCONDITIONAL, not `${REPOS_PATH:+…}`: a plugin cannot ask the user to set a
# variable before the tool works, so the container always has one.
setup
mkdir -p "$TMP/app"
run_sandbox "$TMP/app"
if grep -qx "REPOS_PATH=/workspace" "$CAPTURE"; then
  pass "unset REPOS_PATH → container gets REPOS_PATH=/workspace"
else
  fail "unset REPOS_PATH → container gets REPOS_PATH=/workspace (got: $(grep -c . "$CAPTURE") argv lines, REPOS_PATH=$(grep '^REPOS_PATH=' "$CAPTURE" || echo '<absent>'))"
fi
teardown

# ── Case 2: a configured value replaces the default ──────────────────────────
# Proves the value is a DEFAULT and not a constant. Inline env is used as the
# override vehicle because load_env_defaults sets each key only if unset, so an
# inline value is exactly what a sandbox.env / sandbox.local.env entry becomes
# by the time the docker argv is assembled.
setup
mkdir -p "$TMP/app"
export REPOS_PATH=/workspace/code
run_sandbox "$TMP/app"
if grep -qx "REPOS_PATH=/workspace/code" "$CAPTURE" && ! grep -qx "REPOS_PATH=/workspace" "$CAPTURE"; then
  pass "configured REPOS_PATH overrides the default, and the default is not also passed"
else
  fail "configured REPOS_PATH overrides the default (got: $(grep '^REPOS_PATH=' "$CAPTURE" || echo '<absent>'))"
fi
teardown

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
