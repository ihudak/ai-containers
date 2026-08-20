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

# ── The re-entry guard, on the paths that sourcing alone never reaches ───────
# `return 0 2>/dev/null || exit 0` behaves differently depending on how the file
# is entered, and the ordinary path exercises only one of the two ways. SOURCED
# a second time, `return` succeeds and returns immediately, so the `|| exit 0`
# half is never evaluated at all. EXECUTED, `return` fails ("can only `return'
# from a function or sourced script", swallowed by the 2>/dev/null) and the
# `|| exit 0` is what ends the run.
#
# That asymmetry is a defect this project has already been bitten by once, in
# tests/lib-verify-repo.sh: three guards written to "fail loudly" had never
# failed, because the half that fails is the half nothing ran. Here it left
# mutants of this one line alive against the entire suite (falsify backlog
# F15). Measured, all three damages of the line:
#
#   line                        re-source rc   exec rc (sentinel)   ran on past guard
#   pristine  `... || exit 0`         0                0                    no
#   damage A  `... || exit 1`         0                1                    no
#   damage B  `... && exit 0`         0                0                   YES
#   damage C  `return 1 || exit 0`    1                0                    no
#
# Three different observations are needed because no one of them separates all
# three: C only moves the SOURCED status, A only moves the EXECUTED status, and
# B moves neither — it short-circuits, falls THROUGH the guard and re-runs the
# whole file, which on a bash at or above the floor still ends in status 0.
#
# "Ran on past the guard" is read from an xtrace of the run: the first statement
# after the guard is the sentinel assignment, so its trace line appears if and
# only if the guard failed to stop the file. The no-sentinel run below is the
# CONTROL for that detector — it must report YES. Without it a mistyped marker
# would make the fall-through assertion pass for the wrong reason, which is the
# same vacuity this whole entry is about.
#
# Placed HERE, above the point where this file sources the PRODUCT script
# sync-to-projects.sh, and not at the end with the other late assertions.
# That script sets `-euo pipefail`, so from its source line onward this test
# runs under errexit — and damage C makes a re-source return 1, which under
# errexit aborts the run right there. Assertions placed after it would never
# execute, and the tier would score the abort as a kill with nothing having
# been asserted.
#
# Every one of these runs its subject as the CONDITION of an `if` rather than as
# a bare statement. This file sources the PRODUCT script sync-to-projects.sh
# BELOW, which sets `-euo pipefail`, so every line from there to the end of
# the file runs under errexit whether it means to or not. A bare non-zero
# command under errexit
# aborts the test where it stands — no FAIL line, no failure count, just exit 1
# — and the falsify tier scores that abort as KILLED, so the mutant would look
# caught while nothing had asserted anything.
GUARD_TARGET="$REPO_DIR/shared-files.sh"
GUARD_SENTINEL="_AI_CONTAINERS_SHARED_FILES_SOURCED"
guard_exec() {  # $1 = preset|plain ; sets guard_rc and guard_ran_on
  local trace
  if [[ "$1" == "preset" ]]; then
    if trace="$(env "$GUARD_SENTINEL=1" bash -x "$GUARD_TARGET" 2>&1 >/dev/null)"; then guard_rc=0; else guard_rc=$?; fi
  else
    if trace="$(bash -x "$GUARD_TARGET" 2>&1 >/dev/null)"; then guard_rc=0; else guard_rc=$?; fi
  fi
  if [[ "$trace" == *"$GUARD_SENTINEL=1"* ]]; then guard_ran_on=yes; else guard_ran_on=no; fi
}

# Sourced twice: the second source must report success. Callers source this file
# unconditionally and read the status; a re-entry that returns 1 makes a
# perfectly healthy second source look like a failed one.
if bash -c 'source "$1"; source "$1"' _ "$GUARD_TARGET" >/dev/null 2>&1; then guard_resource_rc=0; else guard_resource_rc=$?; fi
[[ "$guard_resource_rc" -eq 0 ]] \
  && pass "sourcing shared-files.sh a second time returns 0" \
  || fail "sourcing shared-files.sh a second time returns 0 — got $guard_resource_rc, so the re-entry guard reports a healthy re-source as a failure"

guard_exec plain
[[ "$guard_ran_on" == "yes" ]] \
  && pass "executing shared-files.sh with no sentinel set runs the body (the fall-through detector is live)" \
  || fail "executing shared-files.sh with no sentinel set runs the body — saw no '$GUARD_SENTINEL=1' in the xtrace, so the fall-through assertion below cannot fail and proves nothing"
[[ "$guard_rc" -eq 0 ]] \
  && pass "executing shared-files.sh with no sentinel set exits 0" \
  || fail "executing shared-files.sh with no sentinel set exits 0 — got $guard_rc"

guard_exec preset
[[ "$guard_rc" -eq 0 ]] \
  && pass "executing shared-files.sh with the sentinel already set exits 0" \
  || fail "executing shared-files.sh with the sentinel already set exits 0 — got $guard_rc; the re-entry guard's '|| exit' half reports the wrong status"
[[ "$guard_ran_on" == "no" ]] \
  && pass "executing shared-files.sh with the sentinel already set stops AT the guard" \
  || fail "executing shared-files.sh with the sentinel already set stops AT the guard — the xtrace shows '$GUARD_SENTINEL=1' running, so execution fell through and re-ran the whole file"

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

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
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
# …and put this file's OWN options back. `set -e` is a shell option, not a
# property of the sourced file, and sync-to-projects.sh:21 is `set -euo
# pipefail` — so without this line every statement below runs under errexit,
# which line 24's `set -uo pipefail` says this file never wanted.
#
# It is not a style point. Under errexit a bare command that returns non-zero
# ends the test WHERE IT STANDS: no `FAIL:` line, no failure count, just exit 1
# — and exit 1 is exactly what the falsify tier reads as a kill. Two of
# shared-files.sh's re-entry-guard mutants were being scored KILLED that way by
# an oracle that never reached an assertion (backlog F43). Restoring the options
# here means a failing statement below is reported by the assertion that owns
# it, or not at all.
set +e
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
