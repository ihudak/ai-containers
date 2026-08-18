#!/usr/bin/env bash
# Integration test for project-init.sh's generated runme.sh launcher.
# Drives project-init non-interactively (scripted stdin) inside an isolated copy
# of the repo so its projects.conf/shared-file writes never touch the real tree,
# then asserts the generated launcher carries the guarded GITHUB_TOKEN block.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT

# Isolated script_dir: a copy of the repo so projects.conf and shared-file copies
# land in TMP, not the working tree. Exclude heavy/irrelevant dirs.
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
rsync -a --exclude='.git' --exclude='tests' --exclude='docs' "$REPO_DIR/"/ "$SCRIPTS/"

# Isolated HOME so group-init prompts fire deterministically (no ~/.ai-containers).
export HOME="$TMP/home"; mkdir -p "$HOME"

# Target project (a git repo, as real projects are).
PROJ="$TMP/proj/myproj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q

# Scripted answers, in prompt order:
#   path, name(def), image(def), cpus(def), memory(def), reservation(def),
#   memory+swap(def), group(def "default"), group-init menu(1 → from:host),
#   extra-mounts(empty). Launcher doesn't exist yet, so no overwrite prompt.
printf '%s\n\n\n\n\n\n\n\n\n\n' "$PROJ" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1

LAUNCHER="$PROJ/.ai-containers/runme.sh"
if [[ -f "$LAUNCHER" ]]; then
  pass "launcher generated"
else
  fail "launcher generated (missing $LAUNCHER)"; echo "$fails FAILED"; exit 1
fi

grep -q 'command -v gh' "$LAUNCHER"                    && pass "gh guard present"        || fail "gh guard present"
grep -q ': "${GITHUB_TOKEN:=$(gh auth token' "$LAUNCHER" && pass "non-clobbering assign" || fail "non-clobbering assign"
grep -q 'export GITHUB_TOKEN' "$LAUNCHER"              && pass "token exported"          || fail "token exported"

# The token block must come BEFORE ./build.sh (else the build can't see it).
tok_line="$(grep -n 'export GITHUB_TOKEN' "$LAUNCHER" | head -1 | cut -d: -f1)"
build_line="$(grep -n '^\./build\.sh' "$LAUNCHER" | head -1 | cut -d: -f1)"
if [[ -n "$tok_line" && -n "$build_line" && "$tok_line" -lt "$build_line" ]]; then
  pass "token block precedes ./build.sh"
else
  fail "token block precedes ./build.sh (tok=$tok_line build=$build_line)"
fi

# The generated launcher must be valid bash.
bash -n "$LAUNCHER" && pass "launcher parses" || fail "launcher parses"

# ── §3: launcher config lives in sandbox.env / sandbox.local.env; runme.sh is thin ──
SBENV="$PROJ/.ai-containers/sandbox.env"
grep -q '^IMAGE_NAME='          "$SBENV" && pass "sandbox.env has IMAGE_NAME"      || fail "sandbox.env has IMAGE_NAME"
grep -q '^SANDBOX_MODE=open'    "$SBENV" && pass "sandbox.env has SANDBOX_MODE"    || fail "sandbox.env has SANDBOX_MODE"
grep -q '^SANDBOX_WORKDIR=\.\.' "$SBENV" && pass "sandbox.env has SANDBOX_WORKDIR" || fail "sandbox.env has SANDBOX_WORKDIR"
grep -q '^CONTAINER_CPUS='      "$SBENV" && pass "sandbox.env has CONTAINER_CPUS"  || fail "sandbox.env has CONTAINER_CPUS"
! grep -qE '^export (IMAGE_NAME|CONTAINER_)' "$LAUNCHER" && pass "runme.sh is thin (no baked config exports)" || fail "runme.sh is thin (no baked config exports)"
grep -qxF './sandbox.sh' "$LAUNCHER" && pass "runme.sh calls bare ./sandbox.sh" || fail "runme.sh calls bare ./sandbox.sh"
grep -qxF 'sandbox.local.env' "$PROJ/.ai-containers/.gitignore" && pass "sandbox.local.env is gitignored" || fail "sandbox.local.env is gitignored"
# PROJ is a NEW group (isolated HOME) → group_init=from:host, host-referential, so it lands
# in sandbox.local.env (not the portable file) even without EXTRA_MOUNTS.
SBLOCAL1="$PROJ/.ai-containers/sandbox.local.env"
{ [[ -f "$SBLOCAL1" ]] && grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBLOCAL1"; } && pass "GROUP_INIT → sandbox.local.env (new group)" || fail "GROUP_INIT → sandbox.local.env (new group)"
! grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBENV" && pass "GROUP_INIT not in portable sandbox.env" || fail "GROUP_INIT not in portable sandbox.env"
! grep -q '^EXTRA_MOUNTS=' "$SBLOCAL1" && pass "no EXTRA_MOUNTS in local without mounts" || fail "no EXTRA_MOUNTS in local without mounts"

# A second project WITH an extra-mount answer → EXTRA_MOUNTS in sandbox.local.env only.
PROJ2="$TMP/proj/withmounts"; mkdir -p "$PROJ2"; git -C "$PROJ2" init -q
printf '%s\n\n\n\n\n\n\n\n\n%s\n' "$PROJ2" "$TMP" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
SBLOCAL="$PROJ2/.ai-containers/sandbox.local.env"
{ [[ -f "$SBLOCAL" ]] && grep -q '^EXTRA_MOUNTS=' "$SBLOCAL"; } && pass "extra mounts → sandbox.local.env" || fail "extra mounts → sandbox.local.env"
! grep -q 'EXTRA_MOUNTS' "$PROJ2/.ai-containers/runme.sh"      && pass "EXTRA_MOUNTS not baked into runme.sh"     || fail "EXTRA_MOUNTS not baked into runme.sh"
! grep -q '^EXTRA_MOUNTS=' "$PROJ2/.ai-containers/sandbox.env" && pass "EXTRA_MOUNTS not in portable sandbox.env" || fail "EXTRA_MOUNTS not in portable sandbox.env"

# A third project reusing the already-bootstrapped "default" group, with no extra
# mounts either → group_init AND extra_mounts are both empty. sandbox.local.env must
# still be written (previously it was skipped entirely in this case), and its header
# must document the SANDBOX_MODE override as a commented example.
mkdir -p "$HOME/.ai-containers/default"  # Simulate group being bootstrapped by PROJ
PROJ3="$TMP/proj/plain"; mkdir -p "$PROJ3"; git -C "$PROJ3" init -q
printf '%s\n\n\n\n\n\n\n\n\n\n\n' "$PROJ3" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
SBLOCAL3="$PROJ3/.ai-containers/sandbox.local.env"
[[ -f "$SBLOCAL3" ]] && pass "sandbox.local.env always written (no mounts, no group-init)" || fail "sandbox.local.env always written (no mounts, no group-init)"
grep -q '^#SANDBOX_MODE=open' "$SBLOCAL3" && pass "sandbox.local.env documents SANDBOX_MODE example" || fail "sandbox.local.env documents SANDBOX_MODE example"
grep -q 'restricted  firewall enabled' "$SBLOCAL3" && pass "sandbox.local.env documents restricted mode" || fail "sandbox.local.env documents restricted mode"
! grep -q '^SANDBOX_MODE=' "$SBLOCAL3" && pass "SANDBOX_MODE stays commented (no live duplicate)" || fail "SANDBOX_MODE stays commented (no live duplicate)"
! grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBLOCAL3" && pass "no stray GROUP_INIT when not answered" || fail "no stray GROUP_INIT when not answered"
! grep -q '^EXTRA_MOUNTS=' "$SBLOCAL3" && pass "no stray EXTRA_MOUNTS when not answered" || fail "no stray EXTRA_MOUNTS when not answered"

# Regression test (final-review finding): re-running project-init.sh on an existing
# project must back up rather than silently destroy hand-edited sandbox.local.env
# content — nothing in it (REPOS, SANDBOX_WORKDIR, SANDBOX_MODE, ...) is ever re-prompted.
printf 'REPOS="handedited:ro"\n' >> "$SBLOCAL3"
printf '%s\n\n\n\n\n\n\n\n\n\n\n' "$PROJ3" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
BACKUP3="$PROJ3/.ai-containers/sandbox.local.env.pre-init"
[[ -f "$BACKUP3" ]] && pass "sandbox.local.env backed up before re-init overwrite" || fail "sandbox.local.env backed up before re-init overwrite"
grep -q '^REPOS="handedited:ro"' "$BACKUP3" && pass "backup preserves hand-edited content" || fail "backup preserves hand-edited content"
! grep -q '^REPOS="handedited:ro"' "$SBLOCAL3" && pass "fresh sandbox.local.env does not carry stale hand-edit forward" || fail "fresh sandbox.local.env does not carry stale hand-edit forward"
# Assert the EFFECT (git actually ignores the file), not the literal pattern
# string. The pattern is now a glob — `sandbox.local.env.pre-init*` — because
# repeated re-inits produce timestamped backups, and a `grep -qxF` for the exact
# old string failed against a strictly BROADER pattern that ignores strictly
# more. A test that breaks when the code gets more correct is testing the wrong
# thing.
(
  cd "$PROJ3" || exit 1
  : > .ai-containers/sandbox.local.env.pre-init
  : > ".ai-containers/sandbox.local.env.pre-init.20260101T000000Z"
  : > .ai-containers/runme.sh.pre-migrate
)
for f in sandbox.local.env.pre-init \
         sandbox.local.env.pre-init.20260101T000000Z \
         runme.sh.pre-migrate; do
  if (cd "$PROJ3" && git check-ignore -q ".ai-containers/$f"); then
    pass "git ignores $f"
  else
    fail "git ignores $f"
  fi
done

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
