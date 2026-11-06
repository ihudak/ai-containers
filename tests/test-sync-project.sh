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
# Hermetic: the developer's own pointers must not reach a launch — sandbox.sh
# mounts them writable and writes into the git repositories it protects there.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT

# Isolated HOME: sandbox-common.sh (sourced transitively via build.sh, if ever)
# reads ~/.ai-containers. sync-to-projects.sh itself doesn't source it, but keep
# this hermetic against any future coupling and against ensure_ai_containers_ignored
# ever consulting a global git config.
export HOME="$TMP/home"; mkdir -p "$HOME"
# git's global excludes file is $XDG_CONFIG_HOME/git/ignore where that is set:
# a developer's exported one would decide what these tests see.
unset XDG_CONFIG_HOME
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1

# Snapshot the real projects.conf and every real project path it lists, so we can
# prove at the end that this suite never touched any of them.
REAL_PROJECTS_CONF="$REPO_DIR/projects.conf"
REAL_CONF_MD5_BEFORE=""
[[ -f "$REAL_PROJECTS_CONF" ]] && REAL_CONF_MD5_BEFORE="$(p_md5 "$REAL_PROJECTS_CONF")"

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
#
# .agent-discovery/ and .agent-blocked/ are pruned from the walk: they are
# git-ignored OUTPUT directories (see the project .gitignore section below),
# bind-mounted from the host launch directory a running container writes to —
# and a project's generated .ai-containers/runme.sh cds INTO .ai-containers/
# before running sandbox.sh, so that IS the launch directory, putting these
# two dirs directly under $p/.ai-containers. This guard exists to prove the
# suite never writes a project's CONFIG; a live container legitimately
# appending to its own pcap/log output while the suite happens to run is not
# that, and fingerprinting it turned an idle developer machine with a running
# discovery-mode container into a false failure here.
snapshot_real_projects() {
  local out="$1" p i=0
  : > "$out"
  for p in "${real_project_paths[@]}"; do
    i=$((i+1))
    if [[ -d "$p/.ai-containers" ]]; then
      # p_stat_meta is a shell function, so it cannot be reached by -exec.
      while IFS= read -r _entry; do
        p_stat_meta "$_entry"
      done < <(find "$p/.ai-containers" \( -name .agent-discovery -o -name .agent-blocked \) -prune -o -print 2>/dev/null) | sort >> "$out"
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
  # project-init.sh writes). NOTE: this fixture deliberately omits
  # `sandbox.local.env` — it simulates a project initialised BEFORE that pattern
  # existed, which is exactly the case sync must backfill (see section 7). The
  # SENTINEL line stands in for a project's own hand-added entry: sync is
  # append-only and must never drop or reorder it.
  cat > "$dest/.gitignore" <<'EOF'
.agent-blocked/
.agent-discovery/
allowlist-domains.txt
allowlist-proxy-domains.txt
allowlist-cidrs.txt
allowlist-domains.d/custom.txt
allowlist-proxy-domains.d/custom.txt
allowlist-cidrs.d/custom.txt
SENTINEL-project-owned-ignore-entry
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

# ── Derive the shared-file list from shared-files.sh (do not hardcode) ─────────
#
# The list used to be hand-written INLINE in sync_project's `for f in ...; do`
# loop, and this test extracted it by scraping that loop's text out of the
# function body. It now lives in shared-files.sh — a single array both
# project-init.sh and sync-to-projects.sh source — added specifically because
# the two scripts' independent inline lists had already silently diverged
# (sync-to-projects.sh copied group.sh; project-init.sh did not, so a freshly
# initialised project had no group.sh until its first sync). Sourcing the
# array here still derives from the actual runtime source of truth rather than
# hand-copying it — the property this section always meant to preserve — it
# just no longer needs to scrape loop syntax to get it, because the loop no
# longer embeds the list as text.
if [[ -f "$REPO_DIR/shared-files.sh" ]]; then
  pass "shared-files.sh exists"
  # shellcheck disable=SC1091
  source "$REPO_DIR/shared-files.sh"
  derived_shared_files=("${AI_CONTAINERS_SHARED_FILES[@]}")
else
  fail "shared-files.sh exists"
  derived_shared_files=()
fi

# sync_project's copy loop must actually iterate the sourced array, not a
# reintroduced hardcoded list — the exact regression that let group.sh diverge
# in the first place, and the reason shared-files.sh exists. (See
# tests/test-shared-files-parity.sh for the equivalent check against
# project-init.sh, and for the end-to-end proof that both scripts really do
# copy the identical set at runtime, not just that they cite the same array.)
if grep -qE '^\s*for f in "\$\{AI_CONTAINERS_SHARED_FILES\[@\]\}"; do' "$REPO_DIR/sync-to-projects.sh"; then
  pass "sync-to-projects.sh's copy loop iterates the shared AI_CONTAINERS_SHARED_FILES array"
else
  fail "sync-to-projects.sh's copy loop iterates the shared AI_CONTAINERS_SHARED_FILES array — it may have reverted to an independent hardcoded list"
fi

# The derived list is only used to assert each file ARRIVES. On its own it cannot
# notice a file DISAPPEARING from shared-files.sh (the expectation would shrink
# with it), so pin the contract independently: an explicit literal list,
# compared as a set. Adding or removing a shared file is a deliberate act and
# must update this literal too.
expected_shared_files=(
  Dockerfile Dockerfile.seed .dockerignore
  bash-floor.sh host-preflight.sh sandbox-common.sh tools-lib.sh
  build.sh sandbox.sh repo.sh group.sh entrypoint.sh version.sh
  repo-git-reset.sh
  rvm-reconcile.sh link-default-ruby.sh
  agent-tools-reconcile.sh link-agent-tools.sh start-services.sh
  link-node-globals.sh
  refresh-ipset-allowlist.sh
  capture-blocked-traffic.sh capture-agent-destinations.sh
  install-tools.sh install-agent-skills.sh install-node-lts.sh
  extract-discovery.sh
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

if [[ -f "$DEST/services.d/postgres.sh" ]] && cmp -s "$REPO_DIR/services.d/postgres.sh" "$DEST/services.d/postgres.sh" 2>/dev/null; then
  pass "services.d/ adapters synced"
else
  fail "services.d/ adapters synced"
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

[[ "$(p_md5 "$REAL_PROJECTS_CONF" 2>/dev/null)" == "$REAL_CONF_MD5_BEFORE" ]] \
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
# Stronger form of the same claim, using the BEFORE sentinel: the pre-existing
# content must survive byte-for-byte, in order, as the file's prefix — not just
# "present somewhere" (mirrors the DEST-gitignore append-only check below).
[[ "$(head -n "$(printf '%s\n' "$SENTINEL_ROOT_GITIGNORE_BEFORE" | wc -l)" "$PROJ/.gitignore")" \
   == "$SENTINEL_ROOT_GITIGNORE_BEFORE" ]] \
  && pass "root .gitignore: pre-existing content is an intact, in-order prefix" \
  || fail "root .gitignore: pre-existing content is an intact, in-order prefix"

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

# ── 6b. A project that TRACKS .ai-containers/ is left alone (no ignore rule) ─────
# A project can deliberately commit its .ai-containers/ working copy (fip does).
# Adding /.ai-containers/ to its root .gitignore would then silently hide
# newly-synced files from commits. When any file under .ai-containers/ is in the
# git index, ensure_ai_containers_ignored must be a no-op — no override needed.
TRACKED="$TMP/tracked-proj"; mkdir -p "$TRACKED/.ai-containers"
git -C "$TRACKED" init -q
printf 'baked\n' > "$TRACKED/.ai-containers/build.sh"
printf '*.log\n'  > "$TRACKED/.gitignore"
git -C "$TRACKED" add .ai-containers/build.sh .gitignore
git -C "$TRACKED" -c user.email=t@example.com -c user.name=t commit -qm init
ensure_ai_containers_ignored "$TRACKED"
grep -qxF '/.ai-containers/' "$TRACKED/.gitignore" 2>/dev/null \
  && fail "tracked .ai-containers/: must NOT add an ignore rule (would hide synced files)" \
  || pass "tracked .ai-containers/: no ignore rule added (no override needed)"
[[ "$(cat "$TRACKED/.gitignore")" == '*.log' ]] \
  && pass "tracked .ai-containers/: root .gitignore left byte-identical" \
  || fail "tracked .ai-containers/: root .gitignore left byte-identical ($(cat "$TRACKED/.gitignore"))"

# ── 6c. Nothing of the project's repository is run (bugs review GIT-29) ───────
# check-ignore and ls-files read the project's config, includes and all, ran its
# core.fsmonitor, and hung on a FIFO index; on a Mac without the Command Line
# Tools they opened the installer. The work tree is now a .git at the project's
# root, "already ignored" the root .gitignore's own line, and "tracked" the
# index read with no repository, bounded, and only where git runs.
# In a subshell of its own: its fake uname, held FIFO writer and the like must
# not reach the sections after it (bash's command hash kept the fake uname, and a
# later sync took this host for a Mac). Its FAIL lines count toward the total.
c6="$TMP/6c.out"
(
  G6=(git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main)
  # A FIFO index: not read, nothing added, and it says why. A writer is held on
  # it meanwhile, so the code before the fix, which ran git on it, failed rather
  # than blocked: a test that hangs a run on a regression costs every run.
  FI="$TMP/fifo-index"; mkdir -p "$FI" && "${G6[@]}" -C "$FI" init -q && rm -f "$FI/.git/index" && mkfifo "$FI/.git/index" \
    || { printf 'SCAFFOLD-FAILED: 6c FIFO\n'; exit 1; }
  ( exec 3<>"$FI/.git/index"; exec sleep 30 ) & w6=$!
  fi_out="$(ensure_ai_containers_ignored "$FI" 2>&1)" || true
  kill "$w6" 2>/dev/null; wait "$w6" 2>/dev/null || true
  # The NOTE names why and the way out: git, run on it, says only that it
  # could not read it (review of the fix, M3).
  [[ ! -e "$FI/.gitignore" ]] && grep -qF 'its index is not a regular file' <<<"$fi_out" \
    && grep -qF 'AI_CONTAINERS_NO_GITIGNORE=1' <<<"$fi_out" \
    && pass "6c a FIFO index is not read, gets no line added, and is named" \
    || fail "6c FIFO index (gitignore: $(cat "$FI/.gitignore" 2>&1); out: $(tr '\n' ' ' <<<"$fi_out"))"
  # The read is bounded: an index git takes too long over is not known, and
  # says so; nothing waits for it.
  rg6="$(command -v git)"; mkdir -p "$TMP/slowgit" \
    && printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = ls-files ] && exec sleep 8; done\nexec %q "$@"\n' "$rg6" > "$TMP/slowgit/git" \
    && chmod +x "$TMP/slowgit/git" && SG="$TMP/slow-proj" && mkdir -p "$SG" && "${G6[@]}" -C "$SG" init -q \
    && : > "$SG/f" && "${G6[@]}" -C "$SG" add f || { printf 'SCAFFOLD-FAILED: 6c slow git\n'; exit 1; }
  t6=$SECONDS
  sg_out="$( _ver_secs=1; PATH="$TMP/slowgit:$PATH"; ensure_ai_containers_ignored "$SG" 2>&1 )" || true
  t6=$(( SECONDS - t6 ))
  [[ ! -e "$SG/.gitignore" ]] && grep -qF 'within 1 s' <<<"$sg_out" && (( t6 < 6 )) \
    && pass "6c an index read that takes too long is cut off, adds nothing, and is named" \
    || fail "6c slow index read (${t6} s; gitignore: $(cat "$SG/.gitignore" 2>&1); out: $(tr '\n' ' ' <<<"$sg_out"))"
  # A sparse index whose copy lies outside the cone: git, with no objects, says
  # error: and exits 0, listing nothing. Not known, so nothing is added (M2).
  # init, then set: git 2.34's set --sparse-index makes no sparse index.
  mksparse() {  # DIR CONE-DIR
    mkdir -p "$1/.ai-containers" "$1/src" && "${G6[@]}" -C "$1" init -q && : > "$1/.ai-containers/x" && : > "$1/src/y" \
      && "${G6[@]}" -C "$1" add . && "${G6[@]}" -C "$1" commit -qm s \
      && "${G6[@]}" -C "$1" sparse-checkout init --cone --sparse-index >/dev/null 2>&1 \
      && "${G6[@]}" -C "$1" sparse-checkout set "$2" >/dev/null 2>&1 \
      && [[ "$("${G6[@]}" -C "$1" config --get index.sparse)" == true ]]
  }
  SPI="$TMP/sparse-proj"
  if mksparse "$SPI" src; then
    spi_out="$(ensure_ai_containers_ignored "$SPI" 2>&1)" || true
    [[ ! -e "$SPI/.gitignore" ]] && grep -qF 'only in part' <<<"$spi_out" \
      && pass "6c a sparse index git cannot read in full adds nothing, and is named" \
      || fail "6c sparse index (gitignore: $(cat "$SPI/.gitignore" 2>&1); out: $(tr '\n' ' ' <<<"$spi_out"))"
    # Read in part, but what it lists is in the index: tracked, and nothing said.
    SPC="$TMP/sparse-cone"
    if mksparse "$SPC" .ai-containers; then
      spc_out="$(ensure_ai_containers_ignored "$SPC" 2>&1)" || true
      [[ ! -e "$SPC/.gitignore" && -z "$spc_out" ]] \
        && pass "6c a sparse index that lists the copy counts as tracking it" \
        || fail "6c sparse cone holding the copy (gitignore: $(cat "$SPC/.gitignore" 2>&1); out: $spc_out)"
    else
      fail "6c sparse cone holding the copy: no sparse index made"
    fi
  else
    printf 'NOTE: this git makes no sparse index; the sparse-index check is not applicable\n'
  fi
  # Ignored elsewhere, as git ignores it: info/exclude, a core.excludesFile
  # reached through a link (as dotfile managers make them), and the XDG default.
  # No line, and no NOTE (M1).
  IE="$TMP/info-ex"; mkdir -p "$IE" && "${G6[@]}" -C "$IE" init -q && printf '.ai-containers\n' >> "$IE/.git/info/exclude" \
    || { printf 'SCAFFOLD-FAILED: 6c info/exclude\n'; exit 1; }
  ie_out="$(ensure_ai_containers_ignored "$IE" 2>&1)" || true
  [[ ! -e "$IE/.gitignore" && -z "$ie_out" ]] \
    && pass "6c a copy info/exclude ignores gets no line" \
    || fail "6c info/exclude (gitignore: $(cat "$IE/.gitignore" 2>&1); out: $ie_out)"
  GX="$TMP/glob-ex"; mkdir -p "$GX" "$TMP/dotfiles" && "${G6[@]}" -C "$GX" init -q \
    && printf '*.swp\n/.ai-containers/\n' > "$TMP/dotfiles/gitignore_global" && ln -s "$TMP/dotfiles/gitignore_global" "$TMP/gx-link" \
    && printf '[core]\n\texcludesFile = %s\n' "$TMP/gx-link" > "$TMP/gx.cfg" || { printf 'SCAFFOLD-FAILED: 6c excludesFile\n'; exit 1; }
  gx_out="$(GIT_CONFIG_GLOBAL="$TMP/gx.cfg" ensure_ai_containers_ignored "$GX" 2>&1)" || true
  [[ ! -e "$GX/.gitignore" && -z "$gx_out" ]] \
    && pass "6c a copy your core.excludesFile ignores, through a link, gets no line" \
    || fail "6c core.excludesFile (gitignore: $(cat "$GX/.gitignore" 2>&1); out: $gx_out)"
  XG="$TMP/xdg-ex"; mkdir -p "$XG" "$TMP/xdg/git" && "${G6[@]}" -C "$XG" init -q && : > "$TMP/empty.cfg" \
    && printf '.ai-containers/\n' > "$TMP/xdg/git/ignore" || { printf 'SCAFFOLD-FAILED: 6c XDG\n'; exit 1; }
  xg_out="$(GIT_CONFIG_GLOBAL="$TMP/empty.cfg" XDG_CONFIG_HOME="$TMP/xdg" ensure_ai_containers_ignored "$XG" 2>&1)" || true
  [[ ! -e "$XG/.gitignore" && -z "$xg_out" ]] \
    && pass "6c a copy git's default global excludes file ignores gets no line" \
    || fail "6c XDG git/ignore (gitignore: $(cat "$XG/.gitignore" 2>&1); out: $xg_out)"
  # A relative core.excludesFile is the work tree's, as git opens it there,
  # wherever the sync was started from (re-review L1).
  RX="$TMP/rel-ex"; mkdir -p "$RX" && "${G6[@]}" -C "$RX" init -q && printf '.ai-containers/\n' > "$RX/rel-ignore-6c" \
    && printf '[core]\n\texcludesFile = rel-ignore-6c\n' > "$TMP/rx.cfg" || { printf 'SCAFFOLD-FAILED: 6c relative excludesFile\n'; exit 1; }
  rx_out="$(cd "$TMP" && GIT_CONFIG_GLOBAL="$TMP/rx.cfg" ensure_ai_containers_ignored "$RX" 2>&1)" || true
  [[ ! -e "$RX/.gitignore" && -z "$rx_out" ]] \
    && pass "6c a relative core.excludesFile is read from the work tree's top" \
    || fail "6c relative core.excludesFile (gitignore: $(cat "$RX/.gitignore" 2>&1); out: $rx_out)"
  # A git directory the sync cannot search is not "no index" (re-review L2).
  if [[ "$(id -u)" != 0 ]]; then
    US="$TMP/unsearch"; mkdir -p "$US/.ai-containers" && "${G6[@]}" -C "$US" init -q && : > "$US/.ai-containers/x" \
      && "${G6[@]}" -C "$US" add .ai-containers/x && chmod 000 "$US/.git" || { printf 'SCAFFOLD-FAILED: 6c unsearchable\n'; exit 1; }
    us_out="$(ensure_ai_containers_ignored "$US" 2>&1)" || true
    chmod 700 "$US/.git"
    [[ ! -e "$US/.gitignore" ]] && grep -qF 'cannot be searched' <<<"$us_out" \
      && pass "6c a git directory that cannot be searched adds nothing, and is named" \
      || fail "6c unsearchable .git (gitignore: $(cat "$US/.gitignore" 2>&1); out: $us_out)"
  fi
  # A .git that is a link is not followed, and is named (L3).
  LG="$TMP/link-git"; mkdir -p "$LG" "$TMP/real-git" && "${G6[@]}" -C "$TMP/real-git" init -q && ln -s "$TMP/real-git/.git" "$LG/.git" \
    || { printf 'SCAFFOLD-FAILED: 6c .git link\n'; exit 1; }
  lg_out="$(ensure_ai_containers_ignored "$LG" 2>&1)" || true
  [[ ! -e "$LG/.gitignore" ]] && grep -qF 'its .git is a link' <<<"$lg_out" \
    && pass "6c a .git that is a link is not followed, and is named" \
    || fail "6c .git link (gitignore: $(cat "$LG/.gitignore" 2>&1); out: $lg_out)"
  # Trailing whitespace as git trims it: one CR and spaces, never a tab (L5).
  WS="$TMP/ws-tab"; mkdir -p "$WS" && "${G6[@]}" -C "$WS" init -q && printf '/.ai-containers/\t\n' > "$WS/.gitignore"
  ensure_ai_containers_ignored "$WS" >/dev/null 2>&1 || true
  grep -qxF '/.ai-containers/' "$WS/.gitignore" \
    && pass "6c a line git does not match (a trailing tab) gets the line added" \
    || fail "6c trailing tab ($(od -c "$WS/.gitignore" | head -3 | tr '\n' ' '))"
  WC="$TMP/ws-cr"; mkdir -p "$WC" && "${G6[@]}" -C "$WC" init -q && printf '.ai-containers/ \r\n' > "$WC/.gitignore"
  ensure_ai_containers_ignored "$WC" >/dev/null 2>&1 || true
  [[ "$(wc -l < "$WC/.gitignore" | tr -d ' ')" == 1 ]] \
    && pass "6c a CRLF line with a trailing space still counts as the line" \
    || fail "6c CRLF line ($(od -c "$WC/.gitignore" | head -3 | tr '\n' ' '))"
  # An included core.fsmonitor is not run, and the line is added.
  FM="$TMP/fsmon"; mkdir -p "$FM" && "${G6[@]}" -C "$FM" init -q && : > "$FM/f" && "${G6[@]}" -C "$FM" add f \
    && printf '#!/bin/sh\ntouch %q\n' "$TMP/fsmon-ran" > "$TMP/fsmon.sh" && chmod +x "$TMP/fsmon.sh" \
    && printf '[core]\n\tfsmonitor = %s\n' "$TMP/fsmon.sh" > "$FM/.git/inc.cfg" && "${G6[@]}" -C "$FM" config include.path inc.cfg \
    || { printf 'SCAFFOLD-FAILED: 6c fsmonitor\n'; exit 1; }
  ensure_ai_containers_ignored "$FM" >/dev/null 2>&1 || true
  [[ ! -e "$TMP/fsmon-ran" ]] && grep -qxF '/.ai-containers/' "$FM/.gitignore" 2>/dev/null \
    && pass "6c an included core.fsmonitor is not run, and the line is added" \
    || fail "6c fsmonitor ran ($(ls "$TMP/fsmon-ran" 2>&1)) or no line ($(cat "$FM/.gitignore" 2>&1))"
  # macOS's git shim with no developer directory is not run: nothing is added.
  if [[ "$(command -v git)" == /usr/bin/git ]]; then
    MC="$TMP/mac-proj"; mkdir -p "$MC" "$TMP/mac" && "${G6[@]}" -C "$MC" init -q \
      && printf '#!/bin/sh\necho Darwin\n' > "$TMP/mac/uname" && printf '#!/bin/sh\nexit 2\n' > "$TMP/mac/xcode-select" \
      && chmod +x "$TMP/mac/uname" "$TMP/mac/xcode-select" || { printf 'SCAFFOLD-FAILED: 6c mac\n'; exit 1; }
    # GIT_TRACE: a git run at all, for the global excludes as much as the
    # index, is the installer on a real Mac (re-review M1).
    mc_out="$(GIT_TRACE="$TMP/mac-trace" PATH="$TMP/mac:/usr/bin:$PATH" ensure_ai_containers_ignored "$MC" 2>&1)" || true
    [[ ! -e "$MC/.gitignore" && ! -s "$TMP/mac-trace" ]] && grep -qF 'git does not run' <<<"$mc_out" \
      && pass "6c macOS's git shim is not run: nothing is added, and it says why" \
      || fail "6c macOS shim (gitignore: $(cat "$MC/.gitignore" 2>&1); git ran: $(head -2 "$TMP/mac-trace" 2>/dev/null | tr '\n' ' '); out: $(tr '\n' ' ' <<<"$mc_out"))"
  else
    printf 'NOTE: git is not /usr/bin/git here; the macOS shim check is not applicable\n'
  fi
  # Still read as before: a linked worktree that tracks .ai-containers/ through
  # its .git file, a sha256 repository that does, and a plain spelling of the line.
  WM="$TMP/wt-main"; mkdir -p "$WM/.ai-containers" && "${G6[@]}" -C "$WM" init -q && : > "$WM/.ai-containers/x" \
    && "${G6[@]}" -C "$WM" add .ai-containers/x && "${G6[@]}" -C "$WM" commit -qm s && "${G6[@]}" -C "$WM" worktree add -q "$TMP/wt-linked" \
    || { printf 'SCAFFOLD-FAILED: 6c worktree\n'; exit 1; }
  # Silent: a NOTE leaves no line either (re-review M2).
  wl_out="$(ensure_ai_containers_ignored "$TMP/wt-linked" 2>&1)" || true
  [[ ! -e "$TMP/wt-linked/.gitignore" && -z "$wl_out" ]] \
    && pass "6c a linked worktree that tracks .ai-containers/ gets no line" \
    || fail "6c linked worktree ($(cat "$TMP/wt-linked/.gitignore" 2>&1); out: $wl_out)"
  # Its counterparts: one that does not track it gets the line, and one whose
  # main repository's info/exclude ignores it gets none, silently.
  WU="$TMP/wtu-main"; mkdir -p "$WU" && "${G6[@]}" -C "$WU" init -q && : > "$WU/f" && "${G6[@]}" -C "$WU" add f \
    && "${G6[@]}" -C "$WU" commit -qm s && "${G6[@]}" -C "$WU" worktree add -q "$TMP/wtu-linked" \
    && "${G6[@]}" -C "$WU" worktree add -q "$TMP/wtx-linked" || { printf 'SCAFFOLD-FAILED: 6c untracked worktree\n'; exit 1; }
  wu_out="$(ensure_ai_containers_ignored "$TMP/wtu-linked" 2>&1)" || true
  grep -qxF '/.ai-containers/' "$TMP/wtu-linked/.gitignore" 2>/dev/null \
    && pass "6c a linked worktree that does not track .ai-containers/ gets the line" \
    || fail "6c untracked linked worktree (gitignore: $(cat "$TMP/wtu-linked/.gitignore" 2>&1); out: $wu_out)"
  printf '/.ai-containers/\n' >> "$WU/.git/info/exclude"
  wx_out="$(ensure_ai_containers_ignored "$TMP/wtx-linked" 2>&1)" || true
  [[ ! -e "$TMP/wtx-linked/.gitignore" && -z "$wx_out" ]] \
    && pass "6c a linked worktree its main repository's info/exclude ignores gets no line" \
    || fail "6c linked worktree, common info/exclude (gitignore: $(cat "$TMP/wtx-linked/.gitignore" 2>&1); out: $wx_out)"
  if "${G6[@]}" init -q --object-format=sha256 "$TMP/sha-proj" >/dev/null 2>&1; then
    mkdir -p "$TMP/sha-proj/.ai-containers" && : > "$TMP/sha-proj/.ai-containers/x" && "${G6[@]}" -C "$TMP/sha-proj" add .ai-containers/x
    sh_out="$(ensure_ai_containers_ignored "$TMP/sha-proj" 2>&1)" || true
    [[ ! -e "$TMP/sha-proj/.gitignore" && -z "$sh_out" ]] \
      && pass "6c a sha256 repository that tracks .ai-containers/ gets no line" \
      || fail "6c sha256 ($(cat "$TMP/sha-proj/.gitignore" 2>&1); out: $sh_out)"
    # Its counterparts: a sha256 repository, and a sha256 linked worktree (whose
    # format is its common directory's), that do not track it get the line.
    "${G6[@]}" init -q --object-format=sha256 "$TMP/shau" && : > "$TMP/shau/f" && "${G6[@]}" -C "$TMP/shau" add f \
      && "${G6[@]}" -C "$TMP/shau" commit -qm s && "${G6[@]}" -C "$TMP/shau" worktree add -q "$TMP/shau-linked" \
      || { printf 'SCAFFOLD-FAILED: 6c sha256 untracked\n'; exit 1; }
    for d6 in "$TMP/shau" "$TMP/shau-linked"; do
      su_out="$(ensure_ai_containers_ignored "$d6" 2>&1)" || true
      grep -qxF '/.ai-containers/' "$d6/.gitignore" 2>/dev/null \
        && pass "6c a sha256 $([[ $d6 == *linked ]] && echo 'linked worktree' || echo repository) that does not track .ai-containers/ gets the line" \
        || fail "6c sha256 untracked $d6 (gitignore: $(cat "$d6/.gitignore" 2>&1); out: $su_out)"
    done
  fi
  SP="$TMP/spelled"; mkdir -p "$SP" && "${G6[@]}" -C "$SP" init -q && printf '.ai-containers\n' > "$SP/.gitignore"
  ensure_ai_containers_ignored "$SP" >/dev/null 2>&1 || true
  [[ "$(cat "$SP/.gitignore")" == '.ai-containers' ]] \
    && pass "6c a root .gitignore that already names .ai-containers gets no second line" \
    || fail "6c plain spelling ($(cat "$SP/.gitignore"))"
  # The trades, as documented: a broader pattern gets the line once more, and a
  # project nested in an enclosing repository, with no .git of its own, gets none.
  BP="$TMP/broad"; mkdir -p "$BP" && "${G6[@]}" -C "$BP" init -q && printf '.ai-*\n' > "$BP/.gitignore"
  ensure_ai_containers_ignored "$BP" >/dev/null 2>&1 || true
  grep -qxF '/.ai-containers/' "$BP/.gitignore" \
    && pass "6c a broader pattern gets the line once more (documented)" \
    || fail "6c broader pattern ($(cat "$BP/.gitignore"))"
  NM="$TMP/mono"; mkdir -p "$NM/apps/a" && "${G6[@]}" -C "$NM" init -q
  ensure_ai_containers_ignored "$NM/apps/a" >/dev/null 2>&1 || true
  [[ ! -e "$NM/apps/a/.gitignore" ]] \
    && pass "6c a project nested in an enclosing repository gets no line (documented)" \
    || fail "6c nested project ($(cat "$NM/apps/a/.gitignore"))"
) > "$c6" 2>&1 || true
cat "$c6"
# A scaffold that failed skipped the checks after it: a failure too (L9).
fails=$((fails + $(grep -cE '^(FAIL|SCAFFOLD-FAILED):' "$c6" || true)))

# ── 7. The project's .ai-containers/.gitignore is BACKFILLED, append-only ────────
# sync_project's shared-file copy loop does not list `.gitignore`; instead
# ensure_inner_gitignore appends any REQUIRED pattern the project is missing. This
# matters for `sandbox.local.env` (this machine's absolute mount paths): a project
# initialised before that pattern existed would otherwise have no protection at all —
# and for a project that deliberately TRACKS .ai-containers/ (section 6b), the root
# .gitignore protects nothing, so this inner file is the ONLY guard. The fixture omits
# `sandbox.local.env` on purpose, so sync must add it.
grep -qxF 'sandbox.local.env' "$DEST/.gitignore" 2>/dev/null \
  && pass ".ai-containers/.gitignore backfilled with sandbox.local.env" \
  || fail ".ai-containers/.gitignore backfilled with sandbox.local.env"

# Append-only: every pre-sync line must still be present, in its original order, and
# the project's own hand-added entry must survive untouched.
[[ "$(head -n "$(printf '%s\n' "$SENTINEL_DEST_GITIGNORE" | wc -l)" "$DEST/.gitignore")" \
     == "$SENTINEL_DEST_GITIGNORE" ]] \
  && pass ".ai-containers/.gitignore backfill is append-only (pre-sync lines intact, in order)" \
  || fail ".ai-containers/.gitignore backfill is append-only"
grep -qxF 'SENTINEL-project-owned-ignore-entry' "$DEST/.gitignore" 2>/dev/null \
  && pass ".ai-containers/.gitignore keeps the project's own entry" \
  || fail ".ai-containers/.gitignore keeps the project's own entry"

# Idempotent: a second sync must not append the same patterns again.
GI_AFTER_FIRST="$(cat "$DEST/.gitignore")"
ensure_inner_gitignore "$DEST" >/dev/null
[[ "$(cat "$DEST/.gitignore")" == "$GI_AFTER_FIRST" ]] \
  && pass ".ai-containers/.gitignore backfill is idempotent (no duplicate lines)" \
  || fail ".ai-containers/.gitignore backfill is idempotent"

gi_all_covered=1
for pat in '.agent-blocked/' '.agent-discovery/' 'sandbox.local.env' \
           'allowlist-domains.txt' 'allowlist-proxy-domains.txt' 'allowlist-cidrs.txt' \
           'allowlist-domains.d/custom.txt' 'allowlist-proxy-domains.d/custom.txt' 'allowlist-cidrs.d/custom.txt'; do
  grep -qxF "$pat" "$DEST/.gitignore" 2>/dev/null || gi_all_covered=0
done
[[ "$gi_all_covered" -eq 1 ]] \
  && pass ".ai-containers/.gitignore still covers all generated/output patterns after sync" \
  || fail ".ai-containers/.gitignore still covers all generated/output patterns after sync"

# Regression: a .gitignore whose last line lacks a trailing newline must not have
# the first appended pattern glued onto it (real projects hit this — the file's
# last line and the first appended pattern merged into one unmatchable line,
# e.g. "/projects.conf.agent-blocked/" instead of two separate lines).
NOEOL_DEST="$TMP/noeol-proj/.ai-containers"; mkdir -p "$NOEOL_DEST"
printf '/projects.conf' > "$NOEOL_DEST/.gitignore"   # deliberately no trailing newline
ensure_inner_gitignore "$NOEOL_DEST" >/dev/null
grep -qxF '/projects.conf' "$NOEOL_DEST/.gitignore" \
  && pass "no-trailing-newline .gitignore: pre-existing line stays intact, unglued" \
  || fail "no-trailing-newline .gitignore: pre-existing line stays intact, unglued"
grep -qxF '.agent-blocked/' "$NOEOL_DEST/.gitignore" \
  && pass "no-trailing-newline .gitignore: first appended pattern lands as its own line" \
  || fail "no-trailing-newline .gitignore: first appended pattern lands as its own line"

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
[[ "$(p_md5 "$REAL_PROJECTS_CONF" 2>/dev/null)" == "$REAL_CONF_MD5_BEFORE" ]] \
  && pass "real ./projects.conf md5sum unchanged after the full suite" \
  || fail "real ./projects.conf md5sum unchanged after the full suite"

# ── A project still on the removed host group is named ──────────────────────────
# project-init.sh wrote AI_CONTAINER_GROUP=host into sandbox.local.env; every
# launch of such a project is now refused, so the sync says where to change it
# (review of batch 11).
hl="$PROJ/.ai-containers/sandbox.local.env"
[[ -f "$hl" ]] && cp "$hl" "$TMP/hl.bak"
printf 'AI_CONTAINER_GROUP=host\n' >> "$hl"
hout="$(sync_project "$PROJ" 2>&1)"
grep -qF "$hl sets AI_CONTAINER_GROUP=host" <<<"$hout" && grep -qF 'from:host' <<<"$hout" \
  && pass "sync names a project whose sandbox.local.env still sets the host group" \
  || fail "sync did not name the host group ($(grep -i host <<<"$hout" | head -2 | tr '\n' ' '))"
if [[ -f "$TMP/hl.bak" ]]; then cp "$TMP/hl.bak" "$hl"; else rm -f "$hl"; fi
hout="$(sync_project "$PROJ" 2>&1)"
! grep -qF 'AI_CONTAINER_GROUP=host' <<<"$hout" && pass "…and says nothing for a project without it" \
  || fail "sync warned about a host group that is not set"
# The file is read as the launcher reads it (LNCH-20): an exported, quoted value is
# the host group; a line with spaces round `=`, which the loader ignores, or a
# second line after the one it keeps, is not.
printf 'export AI_CONTAINER_GROUP="host"\n' >> "$hl"
hout="$(sync_project "$PROJ" 2>&1)"
grep -qF "$hl sets AI_CONTAINER_GROUP=host" <<<"$hout" \
  && pass "sync names an exported, quoted host group" || fail "sync missed an exported, quoted host group"
if [[ -f "$TMP/hl.bak" ]]; then cp "$TMP/hl.bak" "$hl"; else rm -f "$hl"; fi
printf 'AI_CONTAINER_GROUP=mine\nAI_CONTAINER_GROUP=host\nAI_CONTAINER_GROUP = host\n' >> "$hl"
hout="$(sync_project "$PROJ" 2>&1)"
! grep -qF 'AI_CONTAINER_GROUP=host' <<<"$hout" \
  && pass "sync says nothing for lines the loader ignores or does not keep" \
  || fail "sync warned about a host group the launcher never reads"
# …and a sandbox.local.env that names another group wins over a sandbox.env's host.
se="$PROJ/.ai-containers/sandbox.env"; cp "$se" "$TMP/se.bak"
printf 'AI_CONTAINER_GROUP=host\n' >> "$se"
hout="$(sync_project "$PROJ" 2>&1)"
! grep -qF 'AI_CONTAINER_GROUP=host' <<<"$hout" \
  && pass "sync says nothing when sandbox.local.env's group wins over sandbox.env's host" \
  || fail "sync warned about a sandbox.env host group that sandbox.local.env overrides"
# sandbox.env alone setting it is named — also when the shell exports another
# group, which the launcher would honour but which says nothing about the file.
if [[ -f "$TMP/hl.bak" ]]; then cp "$TMP/hl.bak" "$hl"; else rm -f "$hl"; fi
if [[ -f "$hl" ]]; then { grep -v '^AI_CONTAINER_GROUP' "$hl" || true; } > "$TMP/hl.tmp"; cp "$TMP/hl.tmp" "$hl"; rm -f "$TMP/hl.tmp"; fi
hout="$(AI_CONTAINER_GROUP=other sync_project "$PROJ" 2>&1)"
grep -qF "$se sets AI_CONTAINER_GROUP=host" <<<"$hout" \
  && pass "sync names a sandbox.env that alone sets the host group, whatever the shell exports" \
  || fail "sync missed a host group set in sandbox.env alone ($(grep -i 'host' <<<"$hout" | head -1))"
# A loader that does not work — here a helper it calls is not lifted out, as a
# one-line or spaced definition would not be — must say the check could not run,
# not report the group unset (review of d6dd1e8).
mkdir -p "$TMP/brokeneng"
sed 's/^env_key_portable() {/env_key_portable () {/' "$REPO_DIR/sandbox-common.sh" > "$TMP/brokeneng/sandbox-common.sh"
hout="$(script_dir="$TMP/brokeneng" warn_host_group "$PROJ/.ai-containers" 2>&1)"
grep -qF 'could not check AI_CONTAINER_GROUP' <<<"$hout" \
  && pass "sync says when its loader could not check the group" \
  || fail "sync stayed silent with a loader that does not work (got: $hout)"
rm -rf "$TMP/brokeneng"
cp "$TMP/se.bak" "$se"; rm -f "$TMP/se.bak"
if [[ -f "$TMP/hl.bak" ]]; then cp "$TMP/hl.bak" "$hl"; else rm -f "$hl"; fi
rm -f "$TMP/hl.bak"

snapshot_real_projects "$REAL_PROJECT_SNAPSHOTS/after.txt"
if diff -q "$REAL_PROJECT_SNAPSHOTS/before.txt" "$REAL_PROJECT_SNAPSHOTS/after.txt" >/dev/null 2>&1; then
  pass "no real registered project directory was modified"
else
  fail "no real registered project directory was modified (fingerprint diff below)"
  diff "$REAL_PROJECT_SNAPSHOTS/before.txt" "$REAL_PROJECT_SNAPSHOTS/after.txt" | sed 's/^/    /'
fi

printf '\n%d failure(s)\n' "$fails"
exit "$([[ "$fails" -eq 0 ]] && echo 0 || echo 1)"
