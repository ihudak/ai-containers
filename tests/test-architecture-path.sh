#!/usr/bin/env bash
# tests/test-architecture-path.sh — ARCHITECTURE_REPO_PATH reaches the container.
#
# WHAT THIS VARIABLE IS. A host pointer to the architecture repository —
# standards, radar, ADRs — that workflow plugins ground against. The NAME is not
# ours: product-architecture's CONSUMING.md documents ARCHITECTURE_REPO_PATH as
# the path to that repository's root, its MCP server refuses to start without it,
# and its /check-radar, /create-adr and /validate-service commands read through
# it before falling back to WebFetch. Re-exporting it under the same name, at the
# repository root, is what lets that tooling work inside the container unchanged.
#
# WHAT IT SHARES WITH DOCS_PATH. The grammar ([@]<source>[:ro|:rw], :ro by
# default), the re-point when the same directory is already mounted, and the
# collision error when a DIFFERENT directory holds the name. Its fixed slot is
# /workspace/architecture — a capability, not one repository's name, for the
# same reason /workspace/obsidian became /workspace/vault.
#
# Uses a fake `docker` on PATH to capture the assembled `docker run` args without
# launching a container — the same pattern as tests/test-docs-path.sh.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# mgd-ai-containers keeps the engine under base/; resolve it, and refuse to run
# against nothing — a missing sandbox.sh would turn every refusal case green.
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
  # Isolate from anything the invoking shell exports — this pointer is meant to
  # be exported once in a host profile, so the developer running this suite is
  # exactly the person most likely to have it set.
  unset ARCHITECTURE_REPO_PATH VAULT_PATH SPECS_PATH DOCS_PATH REPOS EXTRA_MOUNTS SANDBOX_CONF
  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
# Volume queries succeed with no output: a registered repo's volume counts as
# PRESENT, so a volume-backed repo can be exercised without a daemon.
if [[ "\$1" == "volume" ]]; then exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"
}
teardown() { rm -rf "$TMP"; unset ARCHITECTURE_REPO_PATH EXTRA_MOUNTS SANDBOX_CONF REPOS; }

# run sandbox.sh restricted <primary>; sets RC and writes stderr to $ERR.
run_sandbox() {
  ERR="$TMP/stderr.txt"
  # Launched from a temp dir: sandbox.sh writes its .agent-blocked/.agent-discovery
  # output dirs into $PWD, which must not be the repo.
  mkdir -p "$TMP/launch"
  ( cd "$TMP/launch" && bash "$ENGINE_DIR/sandbox.sh" restricted "$@" ) >"$TMP/stdout.txt" 2>"$ERR" </dev/null
  RC=$?
}

# Register a bind-backend 'path' repo in the temp HOME registry (no docker volume
# needed on Linux: the repo loop bind-mounts the source directly). Call AFTER setup().
register_repo() {  # $1=name $2=source-dir
  mkdir -p "$HOME/.ai-containers"
  printf '%s|path|%s|0|0|bind\n' "$1" "$2" >> "$HOME/.ai-containers/repos.conf"
}

# Case 1: host path, not the working dir → READ-ONLY at the fixed slot, and the
# pointer re-exported at that slot rather than as the host path.
setup
mkdir -p "$TMP/arch" "$TMP/app"
export ARCHITECTURE_REPO_PATH="$TMP/arch"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "$TMP/arch:/workspace/architecture:ro" "$CAPTURE" \
   && grep -qx "ARCHITECTURE_REPO_PATH=/workspace/architecture" "$CAPTURE"; then
  pass "host path → /workspace/architecture :ro + re-export"
else
  fail "host path → /workspace/architecture :ro + re-export (rc=$RC)"
fi
teardown

# Case 2: the :rw suffix overrides the read-only default.
setup
mkdir -p "$TMP/arch" "$TMP/app"
export ARCHITECTURE_REPO_PATH="$TMP/arch:rw"
run_sandbox "$TMP/app"
if grep -qx "$TMP/arch:/workspace/architecture:rw" "$CAPTURE" \
   && grep -qx "ARCHITECTURE_REPO_PATH=/workspace/architecture" "$CAPTURE"; then
  pass "host path:rw → /workspace/architecture :rw"
else
  fail "host path:rw → /workspace/architecture :rw"
fi
teardown

# Case 3: @name → the registered repo at /workspace/<name>, read-only by default,
# and nothing at the fixed slot.
setup
mkdir -p "$TMP/archvol" "$TMP/app"
register_repo product-architecture "$TMP/archvol"
export ARCHITECTURE_REPO_PATH="@product-architecture"
run_sandbox "$TMP/app"
if grep -qx "$TMP/archvol:/workspace/product-architecture:ro" "$CAPTURE" \
   && grep -qx "ARCHITECTURE_REPO_PATH=/workspace/product-architecture" "$CAPTURE" \
   && ! grep -q ":/workspace/architecture:" "$CAPTURE"; then
  pass "@name → /workspace/<name> :ro"
else
  fail "@name → /workspace/<name> :ro"
fi
teardown

# Case 4: @name:rw → the suffix reaches the repo mount.
setup
mkdir -p "$TMP/archvol" "$TMP/app"
register_repo product-architecture "$TMP/archvol"
export ARCHITECTURE_REPO_PATH="@product-architecture:rw"
run_sandbox "$TMP/app"
if grep -qx "$TMP/archvol:/workspace/product-architecture:rw" "$CAPTURE" \
   && grep -qx "ARCHITECTURE_REPO_PATH=/workspace/product-architecture" "$CAPTURE"; then
  pass "@name:rw → /workspace/<name> :rw"
else
  fail "@name:rw → /workspace/<name> :rw"
fi
teardown

# Case 5: the architecture repo IS the working dir → re-point at the working-dir
# mount (writable), and no second, read-only mount at the slot.
setup
mkdir -p "$TMP/product-architecture"
export ARCHITECTURE_REPO_PATH="$TMP/product-architecture"
run_sandbox "$TMP/product-architecture"
if [[ "$RC" -eq 0 ]] && grep -qx "$TMP/product-architecture:/workspace/product-architecture:rw" "$CAPTURE" \
   && grep -qx "ARCHITECTURE_REPO_PATH=/workspace/product-architecture" "$CAPTURE" \
   && ! grep -q ":/workspace/architecture:" "$CAPTURE"; then
  pass "arch repo == working dir → re-point, no second mount"
else
  fail "arch repo == working dir → re-point, no second mount (rc=$RC)"
fi
teardown

# Case 6: the same checkout is attached as a repo named 'architecture' → re-point
# at it, mount it once, and start.
setup
mkdir -p "$TMP/archrepo" "$TMP/app"
register_repo architecture "$TMP/archrepo"
export ARCHITECTURE_REPO_PATH="$TMP/archrepo" REPOS="architecture:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "ARCHITECTURE_REPO_PATH=/workspace/architecture" "$CAPTURE" \
   && [[ "$(grep -c "^$TMP/archrepo:" "$CAPTURE")" -eq 1 ]]; then
  pass "same checkout as repo 'architecture' → re-points, single mount, starts"
else
  fail "same checkout as repo 'architecture' → re-points, single mount, starts (rc=$RC)"
fi
teardown

# Case 7: the same checkout attached under ANOTHER name → the pointer follows it.
setup
mkdir -p "$TMP/archrepo" "$TMP/app"
register_repo product-architecture "$TMP/archrepo"
export ARCHITECTURE_REPO_PATH="$TMP/archrepo" REPOS="product-architecture:ro"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -qx "ARCHITECTURE_REPO_PATH=/workspace/product-architecture" "$CAPTURE" \
   && [[ "$(grep -c "^$TMP/archrepo:" "$CAPTURE")" -eq 1 ]]; then
  pass "same checkout under another repo name → follows it"
else
  fail "same checkout under another repo name → follows it (rc=$RC)"
fi
teardown

# Case 8: THE REGRESSION GUARD. A DIFFERENT directory, with 'architecture' already
# taken by a repo, is refused — the re-point must not become a silent wrong mount.
setup
mkdir -p "$TMP/archrepo" "$TMP/otherarch" "$TMP/app"
register_repo architecture "$TMP/archrepo"
export ARCHITECTURE_REPO_PATH="$TMP/otherarch" REPOS="architecture:rw"
run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 ]] && grep -q "name 'architecture' is used by REPOS, but ARCHITECTURE_REPO_PATH also mounts at /workspace/architecture" "$ERR"; then
  pass "a DIFFERENT directory colliding on 'architecture' is refused"
else
  fail "a DIFFERENT directory colliding on 'architecture' is refused (rc=$RC)"
fi
teardown

# Case 9: the name claimed by EXTRA_MOUNTS → refused too.
setup
mkdir -p "$TMP/architecture" "$TMP/arch" "$TMP/app"
export EXTRA_MOUNTS="$TMP/architecture"
export ARCHITECTURE_REPO_PATH="$TMP/arch"
run_sandbox "$TMP/app"
if [[ "$RC" -ne 0 ]] && grep -q "name 'architecture' is used by EXTRA_MOUNTS" "$ERR"; then
  pass "collision with EXTRA_MOUNTS on 'architecture' is refused"
else
  fail "collision with EXTRA_MOUNTS on 'architecture' is refused (rc=$RC)"
fi
teardown

# Case 10: a missing directory warns and the container still starts, without the
# mount and without a pointer to nothing.
setup
mkdir -p "$TMP/app"
export ARCHITECTURE_REPO_PATH="$TMP/nope"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && grep -q "WARNING: ARCHITECTURE_REPO_PATH is set but directory does not exist" "$ERR" \
   && ! grep -q ":/workspace/architecture:" "$CAPTURE" \
   && ! grep -q "^ARCHITECTURE_REPO_PATH=" "$CAPTURE"; then
  pass "missing dir → warning, no mount, no pointer"
else
  fail "missing dir → warning, no mount, no pointer (rc=$RC)"
fi
teardown

# Case 11: qmd=OFF with the architecture repo mounted → it is named in the one
# consolidated warning, like every other markdown corpus.
setup
mkdir -p "$TMP/arch" "$TMP/app"
sed 's/^qmd=.*/qmd=OFF/' "$ENGINE_DIR/sandbox.conf" > "$TMP/conf-off"
export SANDBOX_CONF="$TMP/conf-off"   # force qmd=OFF; don't couple to the committed default
export ARCHITECTURE_REPO_PATH="$TMP/arch"
run_sandbox "$TMP/app"
if grep -q "qmd=OFF in sandbox.conf, but markdown corpora are mounted (ARCHITECTURE_REPO_PATH)" "$ERR" \
   && [[ "$(grep -c 'qmd=OFF' "$ERR")" -eq 1 ]]; then
  pass "qmd=OFF → named in the consolidated warning"
else
  fail "qmd=OFF → named in the consolidated warning"
fi
teardown

# Case 12: unset → nothing mounted and nothing exported. The container must never
# see the host's raw value, and an unset pointer must stay unset inside.
setup
mkdir -p "$TMP/app"
run_sandbox "$TMP/app"
if [[ "$RC" -eq 0 ]] && ! grep -q "ARCHITECTURE_REPO_PATH" "$CAPTURE" \
   && ! grep -q ":/workspace/architecture:" "$CAPTURE"; then
  pass "unset → no mount, no pointer"
else
  fail "unset → no mount, no pointer (rc=$RC)"
fi
teardown

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
