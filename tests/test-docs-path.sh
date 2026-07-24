#!/usr/bin/env bash
# Integration tests for DOCS_PATH handling in sandbox.sh.
# Uses a fake `docker` on PATH to capture the assembled `docker run` args
# without launching a container.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export AI_CONTAINER_GROUP_INIT=clean   # non-interactive group bootstrap
  # Isolate from any VAULT_PATH/SPECS_PATH exported in the invoking shell (e.g.
  # a host profile, or this very repo's own dev container) so the qmd-warning
  # cases only ever see the corpora each case sets up itself.
  unset VAULT_PATH SPECS_PATH
  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"
}
teardown() { rm -rf "$TMP"; unset DOCS_PATH VAULT_PATH SPECS_PATH EXTRA_MOUNTS SANDBOX_CONF; }

# run sandbox.sh restricted <primary>; sets RC and writes stderr to $ERR.
run_sandbox() {
  ERR="$TMP/stderr.txt"
  ( cd "$REPO_DIR" && ./sandbox.sh restricted "$@" ) >"$TMP/stdout.txt" 2>"$ERR" </dev/null
  RC=$?
}

# Register a bind-backend 'path' repo in the temp HOME registry (no docker volume
# needed on Linux: the repo loop bind-mounts the source directly). Call AFTER setup().
register_repo() {  # $1=name $2=source-dir
  mkdir -p "$HOME/.ai-containers"
  printf '%s|path|%s|0|0|bind\n' "$1" "$2" >> "$HOME/.ai-containers/repos.conf"
}

# Case 1: DOCS_PATH set, dir exists, not primary → :ro mount + env re-export.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if grep -q "/workspace/docs:ro" "$CAPTURE" && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE" \
   && ! grep -q "DOCS_PATH has been removed" "$ERR"; then
  pass "ro mount + env re-export"; else fail "ro mount + env re-export"; fi
teardown

# Case 2: DOCS_PATH set to a missing dir → WARNING, no docs mount.
setup
mkdir -p "$TMP/app"
export DOCS_PATH="$TMP/nope"
run_sandbox "$TMP/app"
if grep -q "WARNING: DOCS_PATH is set but directory does not exist" "$ERR" \
   && ! grep -q "/workspace/docs:ro" "$CAPTURE"; then
  pass "missing dir → warning, no mount"; else fail "missing dir → warning, no mount"; fi
teardown

# Case 3: name 'docs' already claimed (EXTRA_MOUNTS) → collision error, non-zero exit.
setup
mkdir -p "$TMP/docs" "$TMP/mydocs" "$TMP/app"
export EXTRA_MOUNTS="$TMP/docs"
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if [[ $RC -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR"; then
  pass "collision on docs → error"; else fail "collision on docs → error"; fi
teardown

# Case 4: docs repo passed as the primary (== $DOCS_PATH) → re-point, no grounding mount.
setup
mkdir -p "$TMP/productdocs" "$TMP/app"
export DOCS_PATH="$TMP/productdocs"
run_sandbox "$TMP/productdocs"
if grep -q ":/workspace/productdocs:rw" "$CAPTURE" \
   && grep -qx "DOCS_PATH=/workspace/productdocs" "$CAPTURE" \
   && ! grep -q ":/workspace/docs:" "$CAPTURE"; then
  pass "docs==workdir → re-point, no grounding mount"; else fail "docs==workdir → re-point, no grounding mount"; fi
teardown

# Case 5: qmd=OFF + DOCS mounted → exactly one warning naming DOCS_PATH.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
sed 's/^qmd=.*/qmd=OFF/' "$REPO_DIR/sandbox.conf" > "$TMP/conf-off"
export SANDBOX_CONF="$TMP/conf-off"   # force qmd=OFF; don't couple to the committed default
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if grep -q "qmd=OFF in sandbox.conf, but markdown corpora are mounted (DOCS_PATH)" "$ERR" \
   && [[ "$(grep -c 'qmd=OFF' "$ERR")" -eq 1 ]]; then
  pass "qmd=OFF → one consolidated warning"; else fail "qmd=OFF → one consolidated warning"; fi
teardown

# Case 6: qmd=ON (via SANDBOX_CONF) + DOCS mounted → no qmd warning.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
sed 's/^qmd=.*/qmd=ON/' "$REPO_DIR/sandbox.conf" > "$TMP/conf-on"
export SANDBOX_CONF="$TMP/conf-on"
export DOCS_PATH="$TMP/mydocs"
run_sandbox "$TMP/app"
if ! grep -q "qmd=OFF" "$ERR"; then
  pass "qmd=ON → no warning"; else fail "qmd=ON → no warning"; fi
teardown

# Case 7: no corpus mounted → no qmd warning.
setup
mkdir -p "$TMP/app"
run_sandbox "$TMP/app"
if ! grep -q "qmd=OFF" "$ERR"; then
  pass "no corpus → no warning"; else fail "no corpus → no warning"; fi
teardown

# Case V: VAULT_PATH set → mounted rw at /workspace/vault (not /workspace/obsidian).
setup
mkdir -p "$TMP/mykb" "$TMP/app"
export VAULT_PATH="$TMP/mykb"
run_sandbox "$TMP/app"
if grep -q ":/workspace/vault:rw" "$CAPTURE" && grep -qx "VAULT_PATH=/workspace/vault" "$CAPTURE" \
   && ! grep -q "obsidian" "$CAPTURE"; then
  pass "VAULT_PATH → /workspace/vault"; else fail "VAULT_PATH → /workspace/vault"; fi
teardown

# Case 8: DOCS_PATH=@name (registered) → mount at /workspace/<name> ro + env re-point.
setup
mkdir -p "$TMP/docsvol" "$TMP/app"
register_repo docs2 "$TMP/docsvol"
export DOCS_PATH="@docs2"
run_sandbox "$TMP/app"
if grep -q ":/workspace/docs2:ro" "$CAPTURE" && grep -qx "DOCS_PATH=/workspace/docs2" "$CAPTURE"; then
  pass "DOCS_PATH=@name → /workspace/docs2 ro"; else fail "DOCS_PATH=@name → /workspace/docs2 ro"; fi
teardown

# Case 9: SPECS_PATH=@name (registered) → mount at /workspace/<name> rw + env re-point.
setup
mkdir -p "$TMP/specsvol" "$TMP/app"
register_repo specs2 "$TMP/specsvol"
export SPECS_PATH="@specs2"
run_sandbox "$TMP/app"
if grep -q ":/workspace/specs2:rw" "$CAPTURE" && grep -qx "SPECS_PATH=/workspace/specs2" "$CAPTURE"; then
  pass "SPECS_PATH=@name → /workspace/specs2 rw"; else fail "SPECS_PATH=@name → /workspace/specs2 rw"; fi
teardown

# Case 10: DOCS_PATH=<path>:rw (not primary) → grounding mount is rw.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
export DOCS_PATH="$TMP/mydocs:rw"
run_sandbox "$TMP/app"
if grep -q ":/workspace/docs:rw" "$CAPTURE" && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "DOCS_PATH=path:rw → /workspace/docs rw"; else fail "DOCS_PATH=path:rw → /workspace/docs rw"; fi
teardown

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
