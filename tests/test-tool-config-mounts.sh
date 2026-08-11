#!/usr/bin/env bash
# Integration tests for tools.d config-dir mounts in sandbox.sh.
#
# Covers the group-scoped mounting of every descriptor's config_dir(s):
#   - an ACTIVE tool's config dir is created in the group and mounted;
#   - an INACTIVE tool's is neither created nor mounted (no silent widening);
#   - config_dir may list SEVERAL space-separated paths, so a tool that keeps its
#     config in one directory and its credentials in another gets both;
#   - the fetch mode (install=release vs install=repo-file) has no bearing on
#     mounting — only the tool's sandbox.conf key does;
#   - the host home is used as a one-time seed, never re-seeded afterwards;
#   - AI_CONTAINER_GROUP=host mounts straight from $HOME.
#
# Uses a fake `docker` on PATH to capture the assembled `docker run` args
# without launching a container, plus a synthetic TOOLS_D_DIR/SANDBOX_CONF so
# the assertions never depend on the shipped descriptors or sandbox.conf.
# (test-tools-d.sh covers descriptor PARSING and the basic dtctl mount; this
# file covers the mount DECISION MATRIX and multi-path config dirs.)
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

REAL_HOME="$HOME"

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  # Canonicalise HOME up front, independently of resolve_path (the function
  # under test) — p_realdir uses cd + pwd -P, not readlink -f. sandbox.sh's
  # add_mount_if_exists resolve_path()s every mount source before composing
  # `docker run -v`, so on a host where the temp root is itself reached
  # through a symlink (macOS's /var -> /private/var, universal for mktemp -d
  # output), the composed -v argument comes back canonicalised while
  # $GROUP_ROOT-built expectations below stayed in the raw, uncanonicalised
  # form — a mismatch that looked like a missing mount but wasn't one. With
  # HOME itself already physical, every path built from it (GROUP_ROOT, the
  # host-group mounts) is already in the same form resolve_path will produce,
  # so no further divergence is possible.
  HOME="$(p_realdir "$HOME")"; export HOME
  export AI_CONTAINER_GROUP_INIT=clean   # non-interactive group bootstrap
  # Pin the in-container username so the expected mount targets are stable
  # (sandbox.sh derives dev_home from SANDBOX_USER, defaulting to `id -un`).
  export SANDBOX_USER=dev
  unset VAULT_PATH SPECS_PATH DOCS_PATH EXTRA_MOUNTS REPOS AI_CONTAINER_GROUP

  # Synthetic descriptors: alpha/beta are normally installed tools, gamma is
  # provided from outside the image and splits its state over two dirs.
  export TOOLS_D_DIR="$TMP/tools.d"; mkdir -p "$TOOLS_D_DIR"
  cat > "$TOOLS_D_DIR/alpha.conf" <<'EOF'
repo=acme/alpha
config_dir=.config/alpha
EOF
  cat > "$TOOLS_D_DIR/beta.conf" <<'EOF'
repo=acme/beta
config_dir=.config/beta
EOF
  # gamma: a vendored-binary tool (install=repo-file) whose state spans two dirs.
  cat > "$TOOLS_D_DIR/gamma.conf" <<'EOF'
repo=acme/vendored
binary=gamma-cli
install=repo-file
repo_path=utils/gamma/gamma-cli-linux-${ARCH}
config_dir=.gamma .config/gamma-cli
EOF

  # Minimal config: only the keys these cases care about. Everything else is
  # absent, which get_versions reports as empty (i.e. OFF).
  export SANDBOX_CONF="$TMP/sandbox.conf"
  printf '# schema-version: 3\nalpha=ON\nbeta=OFF\ngamma=ON\n' > "$SANDBOX_CONF"

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
  mkdir -p "$TMP/app"
}
teardown() {
  rm -rf "$TMP"
  unset TOOLS_D_DIR SANDBOX_CONF AI_CONTAINER_GROUP AI_CONTAINER_GROUP_INIT SANDBOX_USER
  export HOME="$REAL_HOME"
}

# run sandbox.sh restricted <primary>; sets RC, writes stderr to $ERR.
run_sandbox() {
  ERR="$TMP/stderr.txt"
  # Launched from a temp dir: sandbox.sh writes its .agent-blocked/.agent-discovery
  # output dirs into $PWD, which must not be the repo.
  mkdir -p "$TMP/launch"
  ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$@" ) >"$TMP/stdout.txt" 2>"$ERR" </dev/null
  RC=$?
}

# mounted <host-src> <container-dst> — is that exact bind flag in the captured args?
mounted() { grep -qx -- "$1:$2:rw" "$CAPTURE"; }

# ── Case 1: active tool → group dir created and mounted ─────────────────────────
setup
run_sandbox "$TMP/app"
[[ $RC -eq 0 ]] && pass "sandbox.sh exits 0" || fail "sandbox.sh exits 0 (rc=$RC)"
if [[ -d "$GROUP_ROOT/.config/alpha" ]]; then
  pass "active tool: group config dir created"; else fail "active tool: group config dir created"; fi
if mounted "$GROUP_ROOT/.config/alpha" "/home/dev/.config/alpha"; then
  pass "active tool: config dir mounted from group"; else fail "active tool: config dir mounted from group"; fi

# ── Case 2: inactive tool → nothing created, nothing mounted ────────────────────
if [[ ! -e "$GROUP_ROOT/.config/beta" ]]; then
  pass "inactive tool: no group config dir"; else fail "inactive tool: no group config dir"; fi
if ! grep -q '/.config/beta' "$CAPTURE"; then
  pass "inactive tool: not mounted"; else fail "inactive tool: not mounted"; fi

# ── Case 3: a multi-path config_dir gets ALL of its paths ───────────────────────
if [[ -d "$GROUP_ROOT/.gamma" && -d "$GROUP_ROOT/.config/gamma-cli" ]]; then
  pass "multi-path: both group config dirs created"; else fail "multi-path: both group config dirs created"; fi
if mounted "$GROUP_ROOT/.gamma" "/home/dev/.gamma"; then
  pass "multi-path: first config dir mounted"; else fail "multi-path: first config dir mounted"; fi
if mounted "$GROUP_ROOT/.config/gamma-cli" "/home/dev/.config/gamma-cli"; then
  pass "multi-path: second config dir mounted (space-separated list)"; else fail "multi-path: second config dir mounted (space-separated list)"; fi
teardown

# ── Case 4: the fetch mode does not bypass the key ─────────────────────────────
# A repo-file tool switched OFF must be treated exactly like any other OFF tool.
setup
printf '# schema-version: 3\nalpha=ON\nbeta=OFF\ngamma=OFF\n' > "$SANDBOX_CONF"
run_sandbox "$TMP/app"
if ! grep -q '/.gamma' "$CAPTURE"; then
  pass "repo-file tool with key OFF is not mounted"; else fail "repo-file tool with key OFF is not mounted"; fi
if [[ ! -e "$GROUP_ROOT/.gamma" ]]; then
  pass "repo-file tool with key OFF creates no group dir"; else fail "repo-file tool with key OFF creates no group dir"; fi
teardown

# ── Case 5: host home seeds the group copy exactly once ────────────────────────
setup
mkdir -p "$HOME/.gamma"
printf 'token: from-host\n' > "$HOME/.gamma/credentials.yaml"
run_sandbox "$TMP/app"
if [[ "$(cat "$GROUP_ROOT/.gamma/credentials.yaml" 2>/dev/null)" == "token: from-host" ]]; then
  pass "seeded from host home on first use"; else fail "seeded from host home on first use"; fi

printf 'token: group-only\n' > "$GROUP_ROOT/.gamma/credentials.yaml"
printf 'token: host-changed\n' > "$HOME/.gamma/credentials.yaml"
run_sandbox "$TMP/app"
if [[ "$(cat "$GROUP_ROOT/.gamma/credentials.yaml")" == "token: group-only" ]]; then
  pass "never re-seeded once the group has it"; else fail "never re-seeded once the group has it"; fi
if [[ "$(cat "$HOME/.gamma/credentials.yaml")" == "token: host-changed" ]]; then
  pass "host copy left untouched"; else fail "host copy left untouched"; fi
teardown

# ── Case 6: AI_CONTAINER_GROUP=host mounts straight from $HOME ──────────────────
setup
mkdir -p "$HOME/.gamma" "$HOME/.config/gamma-cli" "$HOME/.config/alpha"
export AI_CONTAINER_GROUP=host AI_CONTAINER_HOST_ACK=1
run_sandbox "$TMP/app"
if mounted "$HOME/.gamma" "/home/dev/.gamma"; then
  pass "host group: mounted from \$HOME"; else fail "host group: mounted from \$HOME"; fi
if [[ ! -d "$HOME/.ai-containers/host" ]]; then
  pass "host group: no group dir created"; else fail "host group: no group dir created"; fi
unset AI_CONTAINER_HOST_ACK
teardown

# ── Case 7: an inactive tool's host config is not pulled in ─────────────────────
setup
mkdir -p "$HOME/.config/beta"
printf 'secret: host-beta\n' > "$HOME/.config/beta/config.yaml"
run_sandbox "$TMP/app"
if ! grep -q '/.config/beta' "$CAPTURE"; then
  pass "inactive tool: host config not mounted"; else fail "inactive tool: host config not mounted"; fi
if [[ ! -e "$GROUP_ROOT/.config/beta" ]]; then
  pass "inactive tool: host config not copied into the group"; else fail "inactive tool: host config not copied into the group"; fi
teardown

# ── Case 7b: a glob metacharacter in config_dir is NOT expanded ─────────────────
# The list used to be split by an unquoted expansion, which also globs: a
# descriptor like `config_dir=.config/*` would have expanded against the launch
# directory and mounted whatever happened to match.
setup
cat > "$TOOLS_D_DIR/delta.conf" <<'EOF'
repo=acme/delta
config_dir=.config/delta-*
EOF
printf '# schema-version: 3\nalpha=ON\nbeta=OFF\ngamma=ON\ndelta=ON\n' > "$SANDBOX_CONF"
mkdir -p "$HOME/.config/delta-one" "$HOME/.config/delta-two"
( cd "$HOME/.config" && run_sandbox "$TMP/app" )
if [[ -d "$GROUP_ROOT/.config/delta-*" ]]; then
  pass "glob in config_dir taken literally, not expanded"; else fail "glob in config_dir taken literally, not expanded"; fi
if ! grep -q '/.config/delta-one' "$CAPTURE" && ! grep -q '/.config/delta-two' "$CAPTURE"; then
  pass "glob in config_dir mounts no matching sibling dirs"; else fail "glob in config_dir mounts no matching sibling dirs"; fi
teardown

# ── Case 8: group bootstrap from the host copies every config_dir ──────────────
# _copy_group_slice (sandbox-common.sh) pulls each descriptor's config dirs, so a
# group created with AI_CONTAINER_GROUP_INIT=from:host inherits all of them.
setup
mkdir -p "$HOME/.gamma" "$HOME/.config/gamma-cli"
printf 'a\n' > "$HOME/.gamma/one.yaml"
printf 'b\n' > "$HOME/.config/gamma-cli/two.yaml"
export AI_CONTAINER_GROUP_INIT=from:host
run_sandbox "$TMP/app"
if [[ -f "$GROUP_ROOT/.gamma/one.yaml" && -f "$GROUP_ROOT/.config/gamma-cli/two.yaml" ]]; then
  pass "from:host bootstrap copies both config dirs"; else fail "from:host bootstrap copies both config dirs"; fi
teardown

# ── Hermeticity: the real home and repo are untouched ───────────────────────────
if [[ ! -e "$REAL_HOME/.ai-containers/default/.gamma" ]]; then
  pass "real home untouched"; else fail "real home untouched"; fi

printf '\n%s failure(s)\n' "$fails"
(( fails == 0 )) || exit 1
