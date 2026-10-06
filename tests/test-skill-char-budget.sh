#!/usr/bin/env bash
# tests/test-skill-char-budget.sh — SKILL_CHAR_BUDGET must reach the container,
# always, and a host value must win over the default.
#
# WHAT THIS VARIABLE IS FOR. Copilot CLI lists every installed plugin's skills
# for the model within a character budget — 15,000 by default, filled plugin by
# plugin in load order — and a skill past it is listed by name only, with no
# description, so the model cannot tell when to use it. Copilot reads the budget
# from SKILL_CHAR_BUDGET in its own process environment. A plugin set of about
# 22,700 characters already overflows the default, so the launcher passes 25000
# unless the host says otherwise.
#
# WHY A LAUNCHER -e AND NOT THE IMAGE OR THE PROFILE. The same reasons as
# REPOS_PATH (tests/test-repos-path.sh): a default in sandbox.sh reaches every
# existing project at once, where one in sandbox.env would reach only new ones;
# an image ENV would need a rebuild and still could not carry a host value; and
# /etc/profile.d reaches login shells only, never a `docker exec` session. A
# launcher -e is in the container's configured environment, which the agent
# shell inherits from the entrypoint and every `docker exec` gets.
#
# SCOPE. The two facts that belong to THIS variable: the default is composed
# when nothing is configured, and a configured value replaces it. Precedence
# between sandbox.env and sandbox.local.env is load_env_defaults' behaviour,
# covered by tests/test-sandbox-env.sh.
#
# Uses a fake `docker` on PATH to capture the assembled `docker run` args without
# launching a container — the same pattern as tests/test-repos-path.sh.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# mgd-ai-containers keeps the engine under base/; resolve it, and refuse to run
# against nothing — a missing sandbox.sh would leave every case asserting on an
# argv that was never written.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
[[ -f "$ENGINE_DIR/sandbox.sh" ]] || { printf 'SCAFFOLD-FAILED: no sandbox.sh under %s\n' "$REPO_DIR"; exit 1; }
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
  # repo's own dev container, which since this change exports SKILL_CHAR_BUDGET
  # itself — so each case sees only what it sets.
  unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH REPOS EXTRA_MOUNTS SKILL_CHAR_BUDGET
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
teardown() { rm -rf "$TMP"; unset SKILL_CHAR_BUDGET; }

run_sandbox() {
  mkdir -p "$TMP/launch"
  # Exit status is deliberately not captured: these cases assert what reached the
  # docker argv, and the fake `docker` already exits 0 for `run`.
  ( cd "$TMP/launch" && bash "$ENGINE_DIR/sandbox.sh" restricted "$@" ) \
    >"$TMP/stdout.txt" 2>"$TMP/stderr.txt" </dev/null || true
}

# got: what reached the argv, for a failure message.
got() { grep '^SKILL_CHAR_BUDGET=' "$CAPTURE" || echo '<absent>'; }

# ── Case 1: nothing configured → the default reaches the container ───────────
# UNCONDITIONAL, not `${SKILL_CHAR_BUDGET:+…}`: the point is that nobody has to
# know the variable exists for Copilot to see every skill's description.
setup
mkdir -p "$TMP/app"
run_sandbox "$TMP/app"
if [[ ! -s "$CAPTURE" ]]; then
  fail "the launch reached no docker run — every case below would assert nothing (stderr: $(tr '\n' ' ' < "$TMP/stderr.txt"))"
elif grep -qx -- "SKILL_CHAR_BUDGET=25000" "$CAPTURE"; then
  pass "unset SKILL_CHAR_BUDGET → container gets SKILL_CHAR_BUDGET=25000"
else
  fail "unset SKILL_CHAR_BUDGET → container gets SKILL_CHAR_BUDGET=25000 (got: $(got))"
fi
teardown

# ── Case 2: a host value replaces the default ────────────────────────────────
# Proves the value is a DEFAULT and not a constant. Inline env is the override
# vehicle because load_env_defaults sets each key only if unset, so an inline
# value is exactly what a sandbox.env / sandbox.local.env entry becomes by the
# time the docker argv is assembled.
setup
mkdir -p "$TMP/app"
export SKILL_CHAR_BUDGET=40000
run_sandbox "$TMP/app"
if grep -qx -- "SKILL_CHAR_BUDGET=40000" "$CAPTURE" && ! grep -qx -- "SKILL_CHAR_BUDGET=25000" "$CAPTURE"; then
  pass "host SKILL_CHAR_BUDGET is forwarded instead of the default, and the default is not also passed"
else
  fail "host SKILL_CHAR_BUDGET=40000 is forwarded instead of the default (got: $(got))"
fi
teardown

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
