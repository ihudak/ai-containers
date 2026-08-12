#!/usr/bin/env bash
# tests/test-shared-files-parity.sh — project-init.sh and sync-to-projects.sh
# must copy the SAME set of shared engine files into a project's
# .ai-containers/ working copy.
#
# Exists because the two scripts used to each hand-maintain their OWN copy
# list, and had already silently diverged before this file existed:
# sync-to-projects.sh copied group.sh, project-init.sh did not, so a freshly
# initialised project had no group.sh until its first sync — and nothing
# compared the two lists to notice. shared-files.sh fixed that by giving both
# scripts one array to source (AI_CONTAINERS_SHARED_FILES); this file is the
# check whose absence let the drift happen in the first place, plus two
# hand-written content guards for the two things that can never be
# self-consistently checked by re-reading shared-files.sh itself: whether
# bash-floor.sh is IN it (sandbox-common.sh — also shared — sources it
# unconditionally, so its absence breaks every copied project's first build.sh
# invocation) and whether shared-files.sh is OUT of it (a project is a leaf
# that never runs project-init.sh/sync-to-projects.sh, so never needs its own
# copy of the file that drives those copies).
#
# The Critical-bug end-to-end reproduction at the bottom is the exact
# repro used in review: initialise a scratch project for real and run its
# .ai-containers/build.sh --help.
set -uo pipefail

# Layout-tolerant, like verify-on-host.sh / test-layer-containment.sh /
# test-bash-floor.sh: upstream ai-containers keeps shared-files.sh (and
# project-init.sh, sync-to-projects.sh, build.sh) beside tests/;
# mgd-ai-containers keeps them in base/ with tests/ one level up. Every path
# built from REPO_DIR below — including the rsync source tree further down —
# must resolve to wherever those files actually live, or this fails at the
# very first check with a plain "No such file or directory" that says
# nothing about the layout mismatch.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_DIR/shared-files.sh" ]] || REPO_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -f "$REPO_DIR/shared-files.sh" ]] \
  && pass "shared-files.sh exists" \
  || { fail "shared-files.sh exists"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

# shellcheck disable=SC1091
source "$REPO_DIR/shared-files.sh"

# ── Hand-written content guards (deliberately NOT derived from the array itself —
# a check that re-reads shared-files.sh to build its own expectation can never
# notice something disappearing FROM shared-files.sh; the expectation shrinks
# with it) ───────────────────────────────────────────────────────────────────

is_member() {  # $1=needle, rest=haystack array elements
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

if is_member "bash-floor.sh" "${AI_CONTAINERS_SHARED_FILES[@]}"; then
  pass "AI_CONTAINERS_SHARED_FILES includes bash-floor.sh"
else
  fail "AI_CONTAINERS_SHARED_FILES includes bash-floor.sh — sandbox-common.sh (also shared) sources it unconditionally, so a copied project's first build.sh/sandbox.sh/repo.sh call would fail with 'bash-floor.sh: No such file or directory'"
fi

if is_member "shared-files.sh" "${AI_CONTAINERS_SHARED_FILES[@]}"; then
  fail "AI_CONTAINERS_SHARED_FILES excludes shared-files.sh — a project is a leaf that never runs project-init.sh/sync-to-projects.sh and never needs this file"
else
  pass "AI_CONTAINERS_SHARED_FILES excludes shared-files.sh"
fi

# ── Structural guard: both callers must iterate the SAME sourced array, not a
# reintroduced independent list — the exact shape of the original bug ────────

if grep -qE '^\s*source "\$\{script_dir\}/shared-files\.sh"' "$REPO_DIR/project-init.sh"; then
  pass "project-init.sh sources shared-files.sh"
else
  fail "project-init.sh sources shared-files.sh"
fi
if grep -qE '^\s*for f in "\$\{AI_CONTAINERS_SHARED_FILES\[@\]\}"; do' "$REPO_DIR/project-init.sh"; then
  pass "project-init.sh's copy loop iterates the shared AI_CONTAINERS_SHARED_FILES array"
else
  fail "project-init.sh's copy loop iterates the shared AI_CONTAINERS_SHARED_FILES array — it may have reverted to an independent hardcoded list"
fi
if grep -qE '^\s*source "\$\{script_dir\}/shared-files\.sh"' "$REPO_DIR/sync-to-projects.sh"; then
  pass "sync-to-projects.sh sources shared-files.sh"
else
  fail "sync-to-projects.sh sources shared-files.sh"
fi

# ── End-to-end guard: run BOTH real scripts from an identical throwaway source
# tree and prove they land the identical file SET (not just that they cite the
# same array — a real behavioral check, immune to how each script constructs
# its list internally). This is what would have caught the ORIGINAL group.sh
# divergence, which predates shared-files.sh entirely. ────────────────────────

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# A throwaway copy of the whole repo, so project-init.sh's projects.conf
# writes and both scripts' file copies never touch the real tree (mirrors
# tests/test-project-init.sh's technique).
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
rsync -a --exclude='.git' --exclude='tests' --exclude='docs' "$REPO_DIR/"/ "$SCRIPTS/"

# ── Project A: real project-init.sh, driven non-interactively ────────────────
PROJ_A="$TMP/proj/init-target"; mkdir -p "$PROJ_A"; git -C "$PROJ_A" init -q
# Scripted answers, in prompt order (mirrors tests/test-project-init.sh):
#   path, name(def), image(def), cpus(def), memory(def), reservation(def),
#   memory+swap(def), group(def "default"), group-init menu(1 -> from:host),
#   extra-mounts(empty).
printf '%s\n\n\n\n\n\n\n\n\n\n' "$PROJ_A" | bash "$SCRIPTS/project-init.sh" >"$TMP/init.log" 2>&1
init_rc=$?
DEST_A="$PROJ_A/.ai-containers"
if [[ "$init_rc" -eq 0 && -d "$DEST_A" ]]; then
  pass "project-init.sh initialised the scratch project"
else
  fail "project-init.sh initialised the scratch project (rc=$init_rc)"
fi

# ── Project B: real sync_project(), against a minimal pre-existing .ai-containers ──
PROJ_B="$TMP/proj/sync-target"; mkdir -p "$PROJ_B/.ai-containers"; git -C "$PROJ_B" init -q
DEST_B="$PROJ_B/.ai-containers"
# Source the SCRATCH copy of sync-to-projects.sh (its own BASH_SOURCE-derived
# script_dir resolves to $SCRIPTS, matching what project-init.sh copied from —
# an apples-to-apples comparison against the same source tree). The guarded
# early return (see the script's own comment) loads sync_project() without
# running a sync of projects.conf.
# shellcheck disable=SC1091
source "$SCRIPTS/sync-to-projects.sh"
sync_out="$(sync_project "$PROJ_B" 2>&1)"; sync_rc=$?
if [[ "$sync_rc" -eq 0 && -f "$DEST_B/bash-floor.sh" ]]; then
  pass "sync_project() populated the scratch project"
else
  fail "sync_project() populated the scratch project (rc=$sync_rc, out=$sync_out)"
fi

# $SCRIPTS is a verbatim rsync copy of $REPO_DIR made above, so the
# AI_CONTAINERS_SHARED_FILES array already sourced from $REPO_DIR/shared-files.sh
# (near the top of this file) is the same list that tree's two scripts used.

# Every file shared-files.sh names, that actually exists in the scratch source
# tree, must have landed in BOTH destinations.
parity_ok=1
for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do
  [[ -f "$SCRIPTS/$f" ]] || continue
  a_has=0; b_has=0
  [[ -f "$DEST_A/$f" ]] && a_has=1
  [[ -f "$DEST_B/$f" ]] && b_has=1
  if [[ "$a_has" != "1" || "$b_has" != "1" ]]; then
    fail "shared file copied by BOTH project-init.sh and sync-to-projects.sh: $f (project-init:$a_has sync:$b_has)"
    parity_ok=0
  fi
done
[[ "$parity_ok" -eq 1 ]] \
  && pass "every shared file landed in both the init-only and sync-only scratch projects" \
  || true

# The stronger form: the two destinations' shared-file SETS are identical, not
# merely each individually present — this is what actually reproduces the
# historical group.sh bug (present in one destination, absent in the other).
listed_a="$(cd "$DEST_A" && for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do [[ -f "$f" ]] && printf '%s\n' "$f"; done | sort)"
listed_b="$(cd "$DEST_B" && for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do [[ -f "$f" ]] && printf '%s\n' "$f"; done | sort)"
if [[ "$listed_a" == "$listed_b" ]]; then
  pass "project-init.sh and sync-to-projects.sh copy the SAME set of shared files"
else
  fail "project-init.sh and sync-to-projects.sh copy DIFFERENT sets of shared files
     project-init only: $(comm -23 <(printf '%s\n' "$listed_a") <(printf '%s\n' "$listed_b") | tr '\n' ' ')
     sync only:         $(comm -13 <(printf '%s\n' "$listed_a") <(printf '%s\n' "$listed_b") | tr '\n' ' ')"
fi

# ── The Critical-bug reproduction used in review: a freshly initialised
# project's build.sh must actually run, not die on a missing bash-floor.sh. ──
if bash "$DEST_A/build.sh" --help >"$TMP/build-help.log" 2>&1; then
  pass "a freshly initialised project's .ai-containers/build.sh --help succeeds"
else
  fail "a freshly initialised project's .ai-containers/build.sh --help succeeds (see $TMP/build-help.log: $(cat "$TMP/build-help.log" | tr '\n' ' '))"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
