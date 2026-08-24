#!/usr/bin/env bash
# tests/test-repo-git-reset.sh — repo-git-reset.sh against REAL git repositories.
#
# This file is the reason repo-git-reset.sh is a file at all. The rest of
# repo.sh's container-side work is a bash string inside `docker run … -c`, and
# tests/test-repo-destructive.sh's fake docker can only record that string — it
# cannot run git, so it can assert that a reset was ASKED FOR and never that a
# branch was deleted, a head moved, or work destroyed. Those are the only facts
# that matter for a destructive command.
#
# git is available hermetically; docker is not. So every repository below is a
# real one built by `git init`, with real commits, real branches, real
# remote-tracking refs and real unpushed work, and every assertion reads the
# repository's own state afterwards.
#
# The remote is a local bare repo, so there is no network and no auth: a `fetch`
# genuinely succeeds, and the offline path is exercised by deleting the remote
# rather than by pretending.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/repo-git-reset.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
SCRIPT="$ENGINE_DIR/repo-git-reset.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$SCRIPT" ]] || { printf 'SCAFFOLD-FAILED: no repo-git-reset.sh under %s\n' "$ENGINE_DIR"; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'SCAFFOLD-FAILED: no git\n'; exit 1; }

bash -n "$SCRIPT" && pass "repo-git-reset.sh bash -n" || fail "repo-git-reset.sh bash -n"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Isolated git identity/config: these tests must not read or write the
# developer's real ~/.gitconfig, and must not depend on what it says.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
: > "$GIT_CONFIG_GLOBAL"

g() { git -C "$1" "${@:2}"; }
commit_in() {  # $1 = repo, $2 = filename
  printf '%s\n' "$2" > "$1/$2"
  g "$1" add -A >/dev/null 2>&1
  g "$1" commit -qm "add $2" >/dev/null 2>&1
}

# mk_repo <case-name> [default-branch] — a bare "remote" with a default branch
# and one extra branch, cloned into a working repo. Echoes the working repo path.
mk_repo() {
  local name="$1" head="${2:-main}"
  local remote="$TMP/$name.git" work="$TMP/$name"
  git init -q --bare --initial-branch="$head" "$remote" >/dev/null 2>&1
  local seed="$TMP/$name.seed"
  git init -q --initial-branch="$head" "$seed" >/dev/null 2>&1
  commit_in "$seed" first
  g "$seed" remote add origin "$remote" >/dev/null 2>&1
  g "$seed" push -q origin "$head" >/dev/null 2>&1
  # A second branch that exists on the remote too, so "pushed" is a real state.
  g "$seed" checkout -q -b shared >/dev/null 2>&1
  commit_in "$seed" shared-file
  g "$seed" push -q origin shared >/dev/null 2>&1
  g "$seed" checkout -q "$head" >/dev/null 2>&1
  git clone -q "$remote" "$work" >/dev/null 2>&1
  printf '%s' "$work"
}

run_script() {  # $@ -> OUT / RC
  OUT="$("$SCRIPT" "$@" 2>&1)"; RC=$?
}
OUT=""; RC=0

# ── 1. inspect: primary, branches, and what is genuinely unpushed ─────────────

W="$(mk_repo basic)"
g "$W" checkout -q -b feat/local >/dev/null 2>&1     # 2 commits on no remote
commit_in "$W" a
commit_in "$W" b
g "$W" checkout -q -b tracked origin/shared >/dev/null 2>&1   # fully pushed
g "$W" checkout -q main >/dev/null 2>&1

run_script inspect "$W"
if grep -q '^PRIMARY|main$' <<<"$OUT"; then
  pass "inspect names the remote's primary branch"
else
  fail "inspect names the remote's primary branch
$OUT"
fi
if grep -q '^BRANCH|feat/local|2|$' <<<"$OUT"; then
  pass "inspect counts commits that are on no remote"
else
  fail "inspect counts commits that are on no remote
$OUT"
fi
if grep -q '^BRANCH|tracked|0|$' <<<"$OUT"; then
  pass "a branch whose commits are all on a remote counts 0"
else
  fail "a branch whose commits are all on a remote counts 0
$OUT"
fi
if grep -q '^BRANCH|main|0|current$' <<<"$OUT"; then
  pass "inspect flags the checked-out branch"
else
  fail "inspect flags the checked-out branch
$OUT"
fi
if ! grep -q '^STALE|' <<<"$OUT"; then
  pass "a reachable remote produces no STALE record"
else
  fail "a reachable remote produces no STALE record
$OUT"
fi

# ── 2. reset: on primary, at the remote tip, other branches gone ──────────────

W="$(mk_repo doreset)"
g "$W" checkout -q -b feat/local >/dev/null 2>&1
commit_in "$W" a
g "$W" checkout -q -b another >/dev/null 2>&1
printf 'dirty\n' > "$W/first"          # uncommitted change
printf 'junk\n'  > "$W/untracked.txt"  # untracked file
mkdir -p "$W/subdir" && printf 'x\n' > "$W/subdir/deep.txt"

run_script reset "$W" main
if [[ "$RC" -eq 0 ]]; then pass "reset exits 0"; else fail "reset exits 0 (rc=$RC)
$OUT"; fi

if [[ "$(g "$W" symbolic-ref --short HEAD)" == "main" ]]; then
  pass "reset leaves the checkout ON the primary branch"
else
  fail "reset leaves the checkout ON the primary branch (on $(g "$W" symbolic-ref --short HEAD))"
fi

remaining="$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')"
if [[ "$remaining" == "main " ]]; then
  pass "every other local branch is deleted"
else
  fail "every other local branch is deleted (left: $remaining)"
fi

if [[ "$(g "$W" rev-parse HEAD)" == "$(g "$W" rev-parse origin/main)" ]]; then
  pass "reset moves the primary branch to the remote tip"
else
  fail "reset moves the primary branch to the remote tip"
fi

if [[ ! -f "$W/untracked.txt" && ! -d "$W/subdir" ]] && [[ -z "$(g "$W" status --porcelain)" ]]; then
  pass "the working tree is clean — untracked files and edits are gone"
else
  fail "the working tree is clean ($(g "$W" status --porcelain | tr '\n' ' '))"
fi

if grep -q '^DELETED|feat/local$' <<<"$OUT" && grep -q '^DELETED-COUNT|2$' <<<"$OUT"; then
  pass "reset reports each branch it deleted, and how many"
else
  fail "reset reports each branch it deleted, and how many
$OUT"
fi
# A branch git REFUSES to delete reports KEPT, and the count above still looks
# right — so "the count is 2" alone cannot tell a clean run from one that tried
# to delete the checked-out branch and failed.
if ! grep -q '^KEPT|' <<<"$OUT"; then
  pass "a clean reset keeps nothing back"
else
  fail "a clean reset keeps nothing back
$OUT"
fi

# ── 3. the primary branch it is TOLD to use is the one it uses ────────────────

# The prompt names a branch; reset must honour that name rather than re-deriving
# one, or what was approved and what happens can differ.
W="$(mk_repo told)"
g "$W" checkout -q -b shared origin/shared >/dev/null 2>&1
g "$W" checkout -q main >/dev/null 2>&1
run_script reset "$W" shared
if [[ "$(g "$W" symbolic-ref --short HEAD)" == "shared" ]]; then
  pass "reset honours the primary branch it was given, not one it re-derives"
else
  fail "reset honours the primary branch it was given (on $(g "$W" symbolic-ref --short HEAD))"
fi

# ── 4. a primary branch that exists only on the remote ────────────────────────

W="$(mk_repo remoteonly)"
g "$W" checkout -q -b work origin/shared >/dev/null 2>&1
g "$W" branch -D main >/dev/null 2>&1       # no local main at all
run_script reset "$W" main
if [[ "$RC" -eq 0 && "$(g "$W" symbolic-ref --short HEAD)" == "main" ]]; then
  pass "a primary branch present only on the remote is created and checked out"
else
  fail "a primary branch present only on the remote is created and checked out (rc=$RC)
$OUT"
fi

# ── 5. master, not main — the name is never assumed ───────────────────────────

W="$(mk_repo oldschool master)"
run_script inspect "$W"
if grep -q '^PRIMARY|master$' <<<"$OUT"; then
  pass "a repository whose default is master is detected as master"
else
  fail "a repository whose default is master is detected as master
$OUT"
fi

# ── 5b. a default branch that is neither main nor master ─────────────────────
#
# With main/master fixtures alone, every step of the fallback chain returns the
# same answer, so inverting or skipping any of them changes nothing observable.
# A default of `trunk` — with something ELSE checked out, so the last-resort
# fallback would give a different answer — is what makes the steps distinguishable.
W="$(mk_repo trunkrepo trunk)"
g "$W" checkout -q -b shared origin/shared >/dev/null 2>&1
run_script inspect "$W"
if grep -q '^PRIMARY|trunk$' <<<"$OUT"; then
  pass "the remote's own HEAD wins over guessing, and over what is checked out"
else
  fail "the remote's own HEAD wins over guessing, and over what is checked out
$OUT"
fi

# ── 5c. no origin/HEAD to read: the main/master guesses ──────────────────────
#
# origin exists but is unreachable and its HEAD ref is gone, so `set-head -a`
# cannot restore it and the guess loop is the only thing left. Nothing else in
# this file reaches that loop.
W="$(mk_repo guessing)"
g "$W" symbolic-ref -d refs/remotes/origin/HEAD >/dev/null 2>&1
g "$W" remote set-url origin "$TMP/does-not-exist.git" >/dev/null 2>&1
run_script inspect "$W"
if grep -q '^PRIMARY|main$' <<<"$OUT"; then
  pass "with no origin/HEAD, the first EXISTING guess is used"
else
  fail "with no origin/HEAD, the first existing guess is used
$OUT"
fi

# ── 6. offline: the remote is gone ───────────────────────────────────────────

W="$(mk_repo offline)"
g "$W" checkout -q -b feat/x >/dev/null 2>&1
commit_in "$W" a
rm -rf "$TMP/offline.git"                    # the remote no longer exists
run_script inspect "$W"
if grep -q '^STALE|' <<<"$OUT"; then
  pass "an unreachable remote is reported as STALE"
else
  fail "an unreachable remote is reported as STALE
$OUT"
fi
if grep -q '^PRIMARY|main$' <<<"$OUT"; then
  pass "… and the primary branch is still resolved, from the refs already there"
else
  fail "… and the primary branch is still resolved, from the refs already there
$OUT"
fi
stale_line="$(grep '^STALE|' <<<"$OUT")"
if [[ "$(wc -l <<<"$stale_line")" -eq 1 ]]; then
  pass "the STALE reason is one line — the record-per-line contract holds"
else
  fail "the STALE reason is one line — a multi-line git error corrupts parsing
$stale_line"
fi
run_script reset "$W" main
if [[ "$RC" -eq 0 && "$(g "$W" symbolic-ref --short HEAD)" == "main" ]]; then
  pass "reset still works offline — clean slate, just not a fresh one"
else
  fail "reset still works offline (rc=$RC)
$OUT"
fi

# ── 7. a repository with no remote at all ────────────────────────────────────

W="$TMP/noremote"; git init -q --initial-branch=main "$W" >/dev/null 2>&1
commit_in "$W" first
g "$W" checkout -q -b side >/dev/null 2>&1
commit_in "$W" side-file
run_script inspect "$W"
if grep -q '^STALE|no "origin" remote' <<<"$OUT" && grep -q '^PRIMARY|side$' <<<"$OUT"; then
  pass "with no origin, the checked-out branch is the primary and STALE says why"
else
  fail "with no origin, the checked-out branch is the primary and STALE says why
$OUT"
fi
run_script reset "$W" main
if [[ "$RC" -eq 0 ]] && [[ "$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/)" == "main" ]]; then
  pass "with no origin, reset still lands on the named branch and drops the rest"
else
  fail "with no origin, reset still lands on the named branch and drops the rest (rc=$RC)
$OUT"
fi

# ── 7b. a detached HEAD with no remote — there is no branch to name ──────────
#
# The one path where detect_primary has no answer at all. Every other fixture
# reaches one of the fallbacks, so its "found nothing" return was unobservable
# and could be flipped to success with no test noticing.
W="$TMP/detached"; git init -q --initial-branch=main "$W" >/dev/null 2>&1
commit_in "$W" first
commit_in "$W" second
g "$W" checkout -q --detach HEAD~1 >/dev/null 2>&1
run_script inspect "$W"
if ! grep -q '^PRIMARY|' <<<"$OUT"; then
  pass "a detached HEAD with no remote yields NO primary — not an empty one"
else
  fail "a detached HEAD with no remote yields no primary
$OUT"
fi

# ── 8. refusals ──────────────────────────────────────────────────────────────

run_script reset "$TMP" main
if [[ "$RC" -ne 0 ]] && grep -q 'not a git repository' <<<"$OUT"; then
  pass "a directory that is not a git repository is refused"
else
  fail "a directory that is not a git repository is refused (rc=$RC)
$OUT"
fi

W="$(mk_repo nosuch)"
run_script reset "$W" nonexistent-branch
if [[ "$RC" -ne 0 ]] && grep -q 'no local or remote branch named' <<<"$OUT"; then
  pass "a primary branch that exists nowhere is refused, not invented"
else
  fail "a primary branch that exists nowhere is refused, not invented (rc=$RC)
$OUT"
fi
if [[ "$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/ | wc -l)" -ge 1 ]]; then
  pass "… and nothing was deleted on the way to that refusal"
else
  fail "… and nothing was deleted on the way to that refusal"
fi

# By its OWN message: with no argument the directory check downstream also
# fails, so a bare "rc != 0" passes whether or not the argument guard exists.
run_script inspect
if [[ "$RC" -ne 0 ]] && grep -q 'inspect needs a directory' <<<"$OUT"; then
  pass "inspect with no directory is refused by the argument guard"
else
  fail "inspect with no directory is refused by the argument guard (rc=$RC)
$OUT"
fi
# By its own message: with a directory but no primary, the checks downstream
# also fail, so a bare "rc != 0" passes whether or not this guard exists.
run_script reset "$W"
if [[ "$RC" -ne 0 ]] && grep -q 'reset needs a directory and a primary branch' <<<"$OUT"; then
  pass "reset without a primary branch is refused by the argument guard"
else
  fail "reset without a primary branch is refused by the argument guard (rc=$RC)
$OUT"
fi

run_script frobnicate "$W"
if [[ "$RC" -ne 0 ]]; then pass "an unknown subcommand is refused"; else fail "an unknown subcommand is refused"; fi

# ── 9. the global git config is written ONLY as root ─────────────────────────
#
# Read with `git config`, not `grep`. This assertion first grepped the file for
# the string "safe.directory" — which git never writes: the on-disk form is a
# `[safe]` section with a `directory =` key. The grep could not match on any
# input, so the check passed unconditionally and every mutant of the root guard
# it was meant to cover survived. That is the exact shape of guard this suite
# exists to keep out, and it got in anyway.
safe_dirs="$(GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" git config --global --get-all safe.directory 2>/dev/null)"
if [[ "$(id -u)" == "0" ]]; then
  if [[ -n "$safe_dirs" ]]; then
    pass "running as root, the repo is marked a safe.directory — the container case this is for"
  else
    fail "running as root, the repo is marked a safe.directory (got nothing)"
  fi
else
  if [[ -z "$safe_dirs" ]]; then
    pass "running as a normal user, no global safe.directory is written"
  else
    fail "running as a normal user, no global safe.directory is written (got: $safe_dirs)"
  fi
fi

# ── 10. the ownership argument ───────────────────────────────────────────────
#
# Optional, and the only part of reset with a visible failure mode that is not
# a git operation. Chowning to your own identity succeeds unprivileged; an
# identity that does not exist fails for root and non-root alike, so neither
# case depends on who runs the suite.
W="$(mk_repo owned)"
run_script reset "$W" main "$(id -u):$(id -g)"
if [[ "$RC" -eq 0 ]] && ! grep -q '^WARN|' <<<"$OUT"; then
  pass "a valid owner is applied without complaint"
else
  fail "a valid owner is applied without complaint (rc=$RC)
$OUT"
fi

W="$(mk_repo unowned)"
run_script reset "$W" main "nosuchuser99999:nosuchgroup99999"
if grep -q '^WARN|chown failed' <<<"$OUT"; then
  pass "an owner that cannot be applied is reported, not swallowed"
else
  fail "an owner that cannot be applied is reported, not swallowed
$OUT"
fi
if [[ "$(g "$W" symbolic-ref --short HEAD)" == "main" ]]; then
  pass "… and the reset itself still happened"
else
  fail "… and the reset itself still happened"
fi

printf '\n%s\n' "----------------------------------------"
if [[ "$fails" -eq 0 ]]; then
  printf 'test-repo-git-reset.sh: all checks passed\n'; exit 0
fi
printf 'test-repo-git-reset.sh: %s check(s) failed\n' "$fails"
exit 1
