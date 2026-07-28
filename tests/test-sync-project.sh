#!/usr/bin/env bash
# End-to-end tests for sync_project (and its helpers backfill_sandbox_env,
# ensure_ai_containers_ignored) in sync-to-projects.sh — the propagation path
# that pushes shared files from this repo into every registered project's
# .ai-containers/ working copy.
#
# Hermetic: sources sync-to-projects.sh (its `[[ "${BASH_SOURCE[0]}" != "${0}" ]]
# && return 0` guard means sourcing loads the functions without running a sync),
# then calls sync_project directly against a single throwaway project directory
# that is NEVER registered in the real projects.conf. The real projects.conf is
# md5sum'd before/after to prove this suite never wrote to it, and never synced
# into any of the real project paths it lists.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Isolated HOME: sandbox-common.sh (sourced transitively via build.sh, if ever)
# reads ~/.ai-containers. sync-to-projects.sh itself doesn't source it, but keep
# this hermetic against any future coupling and against ensure_ai_containers_ignored
# ever consulting a global git config.
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1

# Snapshot the real projects.conf and every real project path it lists, so we can
# prove at the end that this suite never touched any of them.
REAL_PROJECTS_CONF="$REPO_DIR/projects.conf"
REAL_CONF_MD5_BEFORE=""
[[ -f "$REAL_PROJECTS_CONF" ]] && REAL_CONF_MD5_BEFORE="$(md5sum "$REAL_PROJECTS_CONF" | cut -d' ' -f1)"

REAL_PROJECT_SNAPSHOTS="$TMP/real-project-snapshots"; mkdir -p "$REAL_PROJECT_SNAPSHOTS"
real_project_paths=()
if [[ -f "$REAL_PROJECTS_CONF" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    real_project_paths+=("$line")
  done < "$REAL_PROJECTS_CONF"
fi
# Record an mtime+size fingerprint of each real project's .ai-containers (if it
# exists on this machine) BEFORE running anything, to diff against AFTER.
snapshot_real_projects() {
  local out="$1" p i=0
  : > "$out"
  for p in "${real_project_paths[@]}"; do
    i=$((i+1))
    if [[ -d "$p/.ai-containers" ]]; then
      find "$p/.ai-containers" -exec stat -c '%n %s %Y' {} \; 2>/dev/null | sort >> "$out"
    fi
  done
}
snapshot_real_projects "$REAL_PROJECT_SNAPSHOTS/before.txt"

# Source sync-to-projects.sh for its functions without running a sync (guarded
# early return when sourced — see the script's own comment).
# shellcheck disable=SC1090
source "$REPO_DIR/sync-to-projects.sh"

# ── Fixture: a throwaway "project" with an already-initialised .ai-containers ──
#
# Modelled on what project-init.sh actually produces (read from the real script):
#   - <project>/runme.sh                          the project's OWN launcher (NOT under .ai-containers/; never synced)
#   - <project>/.gitignore                        pre-existing, no trailing newline (exercise the append logic)
#   - <project>/.ai-containers/runme.sh           the generated launcher (export IMAGE_NAME=...)
#   - <project>/.ai-containers/sandbox.conf       a project sandbox.conf (schema-version present)
#   - <project>/.ai-containers/.gitignore         project-init.sh's generated-output ignore list
#   - <project>/.ai-containers/allowlist-*.d/custom.txt   project-owned overrides
build_fixture() {
  local proj="$1"
  mkdir -p "$proj"
  git -C "$proj" init -q
  local dest="$proj/.ai-containers"
  mkdir -p "$dest"/allowlist-domains.d "$dest"/allowlist-proxy-domains.d "$dest"/allowlist-cidrs.d

  # The project's OWN launcher lives in the project root (sibling of
  # .ai-containers/), distinct from .ai-containers/runme.sh. sync_project must
  # never touch it.
  printf '#!/usr/bin/env bash\n# SENTINEL project launcher — must survive sync\necho project-launcher-sentinel\n' > "$proj/runme.sh"
  chmod +x "$proj/runme.sh"

  # Pre-existing root .gitignore with NO trailing newline, to exercise the
  # newline-insertion branch of ensure_ai_containers_ignored.
  printf '*.log' > "$proj/.gitignore"

  # .ai-containers/runme.sh — the generated launcher project-init.sh writes,
  # carrying the literal `export IMAGE_NAME=...` backfill_sandbox_env scans for.
  cat > "$dest/runme.sh" <<'EOF'
#!/usr/bin/env bash
# runme.sh — launch the AI sandbox for fixtureproj.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export IMAGE_NAME=fixtureproj-ai-sandbox
export AI_CONTAINER_GROUP=default
./build.sh
./sandbox.sh discovery ..
EOF
  chmod +x "$dest/runme.sh"

  # Project sandbox.conf: schema-version present, one key already set (must
  # survive reconcile untouched) — used only to prove reconcile doesn't spill
  # into unrelated files; reconcile itself is out of scope for this suite.
  cat > "$dest/sandbox.conf" <<'EOF'
# schema-version: 3
copilot=OFF
EOF

  # Project-owned .gitignore covering generated/output files (what
  # project-init.sh writes). sync_project must never touch this file.
  cat > "$dest/.gitignore" <<'EOF'
.agent-blocked/
.agent-discovery/
.agents-cache-bust
allowlist-domains.txt
allowlist-proxy-domains.txt
allowlist-cidrs.txt
allowlist-domains.d/custom.txt
allowlist-proxy-domains.d/custom.txt
allowlist-cidrs.d/custom.txt
EOF

  # Project-owned custom.txt overrides (never touched/synced — rsync excludes
  # them and the shared-file loop doesn't list them).
  printf 'SENTINEL custom domains — must survive sync\n' > "$dest/allowlist-domains.d/custom.txt"
  printf 'SENTINEL custom proxy domains — must survive sync\n' > "$dest/allowlist-proxy-domains.d/custom.txt"
  printf 'SENTINEL custom cidrs — must survive sync\n' > "$dest/allowlist-cidrs.d/custom.txt"

  # A stray README.md in the child copy the script must delete on sync.
  printf '# stale child README — must be deleted by sync_project\n' > "$dest/README.md"
}

PROJ="$TMP/fixtureproj"
build_fixture "$PROJ"
DEST="$PROJ/.ai-containers"

# Sentinels captured BEFORE sync, to diff against AFTER.
SENTINEL_ROOT_LAUNCHER="$(cat "$PROJ/runme.sh")"
SENTINEL_ROOT_GITIGNORE_BEFORE="$(cat "$PROJ/.gitignore")"
SENTINEL_SANDBOX_CONF_KEY_LINE='copilot=OFF'
SENTINEL_CUSTOM_DOMAINS="$(cat "$DEST/allowlist-domains.d/custom.txt")"
SENTINEL_CUSTOM_PROXY="$(cat "$DEST/allowlist-proxy-domains.d/custom.txt")"
SENTINEL_CUSTOM_CIDRS="$(cat "$DEST/allowlist-cidrs.d/custom.txt")"
SENTINEL_DEST_GITIGNORE="$(cat "$DEST/.gitignore")"

# ── Derive the shared-file list from the script's OWN loop (do not hardcode) ──
#
# sync_project's copy loop is:
#   for f in Dockerfile Dockerfile.seed .dockerignore sandbox-common.sh build.sh \
#             sandbox.sh repo.sh entrypoint.sh refresh-ipset-allowlist.sh \
#             capture-blocked-traffic.sh capture-agent-destinations.sh \
#             install-tools.sh install-agent-skills.sh tools-lib.sh; do
# Extract the actual `for f in ... ; do` file list straight out of the function
# body so this test tracks the script instead of a copy that can go stale.
shared_files_raw="$(sed -n '/^sync_project()/,/^}/p' "$REPO_DIR/sync-to-projects.sh" \
  | grep -A2 '# Shared scripts and build files' | grep -E '^\s*for f in ')"
if [[ -z "$shared_files_raw" ]]; then
  fail "could not locate the shared-file copy loop in sync-to-projects.sh (script shape changed?)"
else
  pass "located the shared-file copy loop in sync-to-projects.sh"
fi
# Reconstruct the exact word list `for f in <words>; do` iterates over. The loop
# spans two physical lines (continued with a trailing backslash); read both.
shared_files_block="$(sed -n '/^sync_project()/,/^}/p' "$REPO_DIR/sync-to-projects.sh" \
  | awk '/for f in/{p=1} p{print} p && /do$/{exit}')"
shared_files_words="$(printf '%s\n' "$shared_files_block" \
  | sed -e 's/^\s*for f in //' -e 's/;\s*do$//' -e 's/\\$//')"
derived_shared_files=()
for w in $shared_files_words; do derived_shared_files+=("$w"); done

# The derived list is only used to assert each file ARRIVES. On its own it cannot
# notice a file DISAPPEARING from the script (the expectation would shrink with
# it), so pin the contract independently: an explicit literal list, compared as a
# set. Adding or removing a shared file is a deliberate act and must update this.
expected_shared_files=(
  Dockerfile Dockerfile.seed .dockerignore sandbox-common.sh build.sh
  sandbox.sh repo.sh entrypoint.sh refresh-ipset-allowlist.sh
  capture-blocked-traffic.sh capture-agent-destinations.sh
  install-tools.sh install-agent-skills.sh tools-lib.sh
)
derived_sorted="$(printf '%s\n' "${derived_shared_files[@]}" | sort | tr '\n' ' ')"
expected_sorted="$(printf '%s\n' "${expected_shared_files[@]}" | sort | tr '\n' ' ')"
if [[ "$derived_sorted" == "$expected_sorted" ]]; then
  pass "shared-file list matches the pinned contract (${#expected_shared_files[@]} files)"
else
  fail "shared-file list drifted from the pinned contract
     script:   $derived_sorted
     expected: $expected_sorted"
fi

# ── Run the sync ────────────────────────────────────────────────────────────────
sync_out="$(sync_project "$PROJ" 2>&1)"
sync_rc=$?
[[ "$sync_rc" -eq 0 ]] && pass "sync_project exits 0" || fail "sync_project exits 0 (rc=$sync_rc, out=$sync_out)"

# ── 1. Every file in the derived shared list lands in dest/ with matching content ──
all_landed=1
for f in "${derived_shared_files[@]}"; do
  src="$REPO_DIR/$f"
  [[ -f "$src" ]] || continue   # loop itself skips files that don't exist centrally
  if [[ ! -f "$DEST/$f" ]]; then
    fail "shared file synced: $f (missing in dest)"
    all_landed=0
    continue
  fi
  if ! cmp -s "$src" "$DEST/$f"; then
    fail "shared file synced: $f (content differs from source)"
    all_landed=0
    continue
  fi
done
[[ "$all_landed" -eq 1 ]] && pass "all shared files landed in .ai-containers/ with matching content"

# ── 2. Allowlist fragment dirs + tools.d synced (excluding custom.txt) ─────────
if [[ -f "$DEST/allowlist-domains.d/base.txt" ]] && cmp -s "$REPO_DIR/allowlist-domains.d/base.txt" "$DEST/allowlist-domains.d/base.txt"; then
  pass "allowlist-domains.d/base.txt synced with matching content"
else
  fail "allowlist-domains.d/base.txt synced with matching content"
fi
if [[ -f "$DEST/tools.d/dtctl.conf" ]] && cmp -s "$REPO_DIR/tools.d/dtctl.conf" "$DEST/tools.d/dtctl.conf" 2>/dev/null; then
  pass "tools.d/ fragments synced"
else
  fail "tools.d/ fragments synced"
fi

# ── 3. Deliberately-NOT-synced files stay untouched (sentinels survive) ────────
[[ "$(cat "$PROJ/runme.sh" 2>/dev/null)" == "$SENTINEL_ROOT_LAUNCHER" ]] \
  && pass "project's root runme.sh launcher is untouched" \
  || fail "project's root runme.sh launcher is untouched"

grep -qxF "$SENTINEL_SANDBOX_CONF_KEY_LINE" "$DEST/sandbox.conf" 2>/dev/null \
  && pass "sandbox.conf pre-set key (copilot=OFF) survives reconcile untouched" \
  || fail "sandbox.conf pre-set key (copilot=OFF) survives reconcile untouched"

[[ "$(cat "$DEST/allowlist-domains.d/custom.txt" 2>/dev/null)" == "$SENTINEL_CUSTOM_DOMAINS" ]] \
  && pass "allowlist-domains.d/custom.txt untouched" \
  || fail "allowlist-domains.d/custom.txt untouched"
[[ "$(cat "$DEST/allowlist-proxy-domains.d/custom.txt" 2>/dev/null)" == "$SENTINEL_CUSTOM_PROXY" ]] \
  && pass "allowlist-proxy-domains.d/custom.txt untouched" \
  || fail "allowlist-proxy-domains.d/custom.txt untouched"
[[ "$(cat "$DEST/allowlist-cidrs.d/custom.txt" 2>/dev/null)" == "$SENTINEL_CUSTOM_CIDRS" ]] \
  && pass "allowlist-cidrs.d/custom.txt untouched" \
  || fail "allowlist-cidrs.d/custom.txt untouched"

[[ "$(md5sum "$REAL_PROJECTS_CONF" 2>/dev/null | cut -d' ' -f1)" == "$REAL_CONF_MD5_BEFORE" ]] \
  && pass "real ./projects.conf is untouched by the sync" \
  || fail "real ./projects.conf is untouched by the sync"
[[ ! -f "$DEST/projects.conf" ]] \
  && pass "projects.conf is not copied into the child .ai-containers/" \
  || fail "projects.conf is not copied into the child .ai-containers/"

# ── 4. README.md removed from the child copy ───────────────────────────────────
[[ ! -f "$DEST/README.md" ]] \
  && pass "README.md removed from the child .ai-containers/ copy" \
  || fail "README.md removed from the child .ai-containers/ copy"

# ── 5. sandbox.env: backfilled when missing, IMAGE_NAME read from the launcher ──
[[ -f "$DEST/sandbox.env" ]] && pass "sandbox.env was backfilled" || fail "sandbox.env was backfilled"
grep -qxF 'IMAGE_NAME=fixtureproj-ai-sandbox' "$DEST/sandbox.env" 2>/dev/null \
  && pass "sandbox.env IMAGE_NAME matches the launcher's export" \
  || fail "sandbox.env IMAGE_NAME matches the launcher's export ($(cat "$DEST/sandbox.env" 2>/dev/null))"

# sandbox.env must NEVER be overwritten when it already exists — mutate it with
# a sentinel value that does NOT match the launcher, re-sync, and prove it survives.
printf 'IMAGE_NAME=sentinel-should-not-be-overwritten\n' > "$DEST/sandbox.env"
sync_project "$PROJ" >/dev/null 2>&1
grep -qxF 'IMAGE_NAME=sentinel-should-not-be-overwritten' "$DEST/sandbox.env" 2>/dev/null \
  && pass "sandbox.env is never overwritten once it exists" \
  || fail "sandbox.env is never overwritten once it exists ($(cat "$DEST/sandbox.env" 2>/dev/null))"

# ── 6. ensure_ai_containers_ignored: root .gitignore, idempotent, git-repos only ──
grep -qxF '/.ai-containers/' "$PROJ/.gitignore" 2>/dev/null \
  && pass "ensure_ai_containers_ignored adds /.ai-containers/ to the project's root .gitignore" \
  || fail "ensure_ai_containers_ignored adds /.ai-containers/ to the project's root .gitignore"
# Original content (no trailing newline originally) must be preserved, not clobbered.
grep -qxF '*.log' "$PROJ/.gitignore" 2>/dev/null \
  && pass "ensure_ai_containers_ignored preserves pre-existing .gitignore content" \
  || fail "ensure_ai_containers_ignored preserves pre-existing .gitignore content"

# Idempotency: calling again must not duplicate the line.
ensure_ai_containers_ignored "$PROJ"
occurrences="$(grep -cxF '/.ai-containers/' "$PROJ/.gitignore" 2>/dev/null)"
[[ "$occurrences" -eq 1 ]] \
  && pass "ensure_ai_containers_ignored is idempotent (line added exactly once)" \
  || fail "ensure_ai_containers_ignored is idempotent (found $occurrences occurrences)"

# Non-git-repo project: must be a no-op (no .gitignore created).
NONGIT="$TMP/nongit-proj"; mkdir -p "$NONGIT"
ensure_ai_containers_ignored "$NONGIT"
[[ ! -f "$NONGIT/.gitignore" ]] \
  && pass "ensure_ai_containers_ignored is a no-op for a non-git-repo project" \
  || fail "ensure_ai_containers_ignored is a no-op for a non-git-repo project"

# AI_CONTAINERS_NO_GITIGNORE=1 hook, if the code supports it (verified above by
# reading the function body: it checks AI_CONTAINERS_NO_GITIGNORE early and returns).
NOGI="$TMP/nogi-proj"; mkdir -p "$NOGI"; git -C "$NOGI" init -q
printf 'PRE-EXISTING\n' > "$NOGI/.gitignore"
AI_CONTAINERS_NO_GITIGNORE=1 ensure_ai_containers_ignored "$NOGI"
[[ "$(cat "$NOGI/.gitignore")" == "PRE-EXISTING" ]] \
  && pass "AI_CONTAINERS_NO_GITIGNORE=1 skips the .gitignore edit entirely" \
  || fail "AI_CONTAINERS_NO_GITIGNORE=1 skips the .gitignore edit entirely ($(cat "$NOGI/.gitignore"))"

# ── 7. The project's .ai-containers/.gitignore still covers generated/output files ──
# sync_project's shared-file copy loop does not list `.gitignore`, so the
# project-owned one (written by project-init.sh) must pass through completely
# unmodified — prove both that it is byte-identical to its pre-sync content AND
# that it still covers every generated/output pattern project-init.sh seeds.
[[ "$(cat "$DEST/.gitignore" 2>/dev/null)" == "$SENTINEL_DEST_GITIGNORE" ]] \
  && pass ".ai-containers/.gitignore content is untouched by sync" \
  || fail ".ai-containers/.gitignore content is untouched by sync"
gi_all_covered=1
for pat in '.agent-blocked/' '.agent-discovery/' '.agents-cache-bust' \
           'allowlist-domains.txt' 'allowlist-proxy-domains.txt' 'allowlist-cidrs.txt' \
           'allowlist-domains.d/custom.txt' 'allowlist-proxy-domains.d/custom.txt' 'allowlist-cidrs.d/custom.txt'; do
  grep -qxF "$pat" "$DEST/.gitignore" 2>/dev/null || gi_all_covered=0
done
[[ "$gi_all_covered" -eq 1 ]] \
  && pass ".ai-containers/.gitignore still covers all generated/output patterns after sync" \
  || fail ".ai-containers/.gitignore still covers all generated/output patterns after sync"

# ── 8. `./sync-to-projects.sh <path>` supports an unregistered single project ──
# Verified in the code: when $# -ge 1 the main block resolves $1 and calls
# sync_project directly, WITHOUT ever reading projects.conf. Exercise the actual
# CLI entry point (not just the sourced function) against a second throwaway
# project that is provably not registered anywhere.
UNREG="$TMP/unregistered-proj"
build_fixture "$UNREG"
if grep -qxF "$UNREG" "$REAL_PROJECTS_CONF" 2>/dev/null; then
  fail "CLI-path fixture project must not already be registered (test bug)"
else
  pass "CLI-path fixture project confirmed unregistered"
fi
cli_out="$(cd "$REPO_DIR" && ./sync-to-projects.sh "$UNREG" 2>&1)"
cli_rc=$?
[[ "$cli_rc" -eq 0 ]] && pass "CLI invocation with an explicit unregistered path exits 0" \
                       || fail "CLI invocation with an explicit unregistered path exits 0 (rc=$cli_rc, out=$cli_out)"
[[ -f "$UNREG/.ai-containers/build.sh" ]] \
  && pass "CLI invocation with an explicit path syncs that project directly" \
  || fail "CLI invocation with an explicit path syncs that project directly"
grep -q 'projects.conf not found\|No projects registered' <<<"$cli_out" \
  && fail "CLI single-path invocation must not fall through to the projects.conf path" \
  || pass "CLI single-path invocation never consults projects.conf"

# ── 9. Hermeticity: real projects.conf and real registered project dirs untouched ──
[[ "$(md5sum "$REAL_PROJECTS_CONF" 2>/dev/null | cut -d' ' -f1)" == "$REAL_CONF_MD5_BEFORE" ]] \
  && pass "real ./projects.conf md5sum unchanged after the full suite" \
  || fail "real ./projects.conf md5sum unchanged after the full suite"

snapshot_real_projects "$REAL_PROJECT_SNAPSHOTS/after.txt"
if diff -q "$REAL_PROJECT_SNAPSHOTS/before.txt" "$REAL_PROJECT_SNAPSHOTS/after.txt" >/dev/null 2>&1; then
  pass "no real registered project directory was modified"
else
  fail "no real registered project directory was modified (fingerprint diff below)"
  diff "$REAL_PROJECT_SNAPSHOTS/before.txt" "$REAL_PROJECT_SNAPSHOTS/after.txt" | sed 's/^/    /'
fi

printf '\n%d failure(s)\n' "$fails"
exit "$([[ "$fails" -eq 0 ]] && echo 0 || echo 1)"
