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
# Owned by this shell only: p_timeout forks, and a child's EXIT must not delete
# the fixture this script is still using.
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

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

# The helper fetches only from the URL repo.sh pins (AI_REPO_URL, from the
# volume's own label): here, the bare remote mk_repo made beside each checkout.
run_script() {  # $@ -> OUT / RC
  OUT="$(AI_REPO_URL="${AI_REPO_URL-${2:-}.git}" "$SCRIPT" "$@" 2>&1)"; RC=$?
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
# Nothing in the volume names the primary or proves a branch pushed: the refs
# there are the agent's to write. Without the remote, neither is claimed.
if ! grep -q '^PRIMARY|' <<<"$OUT" && grep -qx 'BRANCH|feat/x|?|current' <<<"$OUT"; then
  pass "… with no primary claimed and every count unknown"
else
  fail "… with no primary claimed and every count unknown
$OUT"
fi
stale_line="$(grep '^STALE|' <<<"$OUT")"
if [[ "$(wc -l <<<"$stale_line")" -eq 1 ]]; then
  pass "the STALE reason is one line — the record-per-line contract holds"
else
  fail "the STALE reason is one line — a multi-line git error corrupts parsing
$stale_line"
fi
printf 'edit\n' > "$W/a"
run_script reset "$W" main
if [[ "$RC" -ne 0 && "$OUT" == *"cannot clone the recorded remote"* && "$(cat "$W/a")" == edit ]] \
   && [[ "$(g "$W" symbolic-ref --short HEAD)" == "feat/x" ]]; then
  pass "reset refuses offline, and leaves the checkout exactly as it was"
else
  fail "offline reset (rc=$RC)
$OUT"
fi

# ── 7. a repository with no remote at all ────────────────────────────────────

W="$TMP/noremote"; git init -q --initial-branch=main "$W" >/dev/null 2>&1
commit_in "$W" first
g "$W" checkout -q -b side >/dev/null 2>&1
commit_in "$W" side-file
# The recorded URL is the only remote, whatever the .git says, and here it leads
# nowhere: STALE says so, both branches are listed, and nothing is claimed.
run_script inspect "$W"
if grep -q '^STALE|' <<<"$OUT" && ! grep -q '^PRIMARY|' <<<"$OUT" \
   && grep -qx 'BRANCH|side|?|current' <<<"$OUT" && grep -qx 'BRANCH|main|?|' <<<"$OUT"; then
  pass "with no reachable remote, STALE says why, the branches are listed, and no primary is claimed"
else
  fail "with no reachable remote
$OUT"
fi
run_script reset "$W" main
if [[ "$RC" -ne 0 && "$(g "$W" for-each-ref --format='%(refname:short)' refs/heads/ | wc -l)" -eq 2 ]]; then
  pass "… and reset refuses it, deleting nothing"
else
  fail "reset without a remote (rc=$RC)
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
if [[ "$RC" -ne 0 ]] && grep -q 'the remote has no branch named' <<<"$OUT"; then
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

# ── The helper runs as ROOT in the seed container, with your ~/.ssh keys and an
# open network, on a .git the agent can write through any :rw repo volume — the
# launcher's git-internals overlay covers host binds, not volumes. Nothing that
# .git holds may run: not config keys, not includes, not hooks (bugs-review
# re-review of batch 2, F6). The config is cut to the keys a fetch and a
# checkout need, and a .git holding anything but files and directories, or not
# a directory at all, is refused.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability.sh"
W="$(mk_repo poisoned)"
M="$TMP/ran-poisoned"
printf 'x\n' > "$TMP/evil.gitconfig"
git -C "$W" config core.fsmonitor "sh -c 'echo fsmonitor >> $M'"
git -C "$W" config include.path "$TMP/evil.gitconfig"
git config --file "$TMP/evil.gitconfig" core.fsmonitor "sh -c 'echo include >> $M'"
git -C "$W" config filter.evil.smudge "sh -c 'echo smudge >> $M; cat'"
printf '* filter=evil\n' > "$W/.git/info/attributes"
for h in post-checkout post-merge reference-transaction pre-auto-gc post-rewrite; do
  printf '#!/bin/sh\necho %s >> %s\n' "$h" "$M" > "$W/.git/hooks/$h"; chmod +x "$W/.git/hooks/$h"
done
url_before="$(git -C "$W" remote get-url origin)"
run_script inspect "$W"
run_script reset "$W" main; out_r="$OUT"
if [[ ! -e "$M" ]]; then pass "nothing the .git holds runs: config keys, an include, a filter, hooks"
else fail "the agent's .git ran: $(tr '\n' ' ' < "$M")"; fi
if [[ "$out_r" == *"ON|main"* && "$(git -C "$W" remote get-url origin)" == "$url_before" ]]; then
  pass "… and the reset still works, with the remote kept"
else
  fail "reset after sanitising (out: $out_r)"
fi
if ! git config --file "$W/.git/config" --get core.fsmonitor >/dev/null && ! git config --file "$W/.git/config" --get include.path >/dev/null \
   && ! git config --file "$W/.git/config" --get filter.evil.smudge >/dev/null; then
  pass "the config is cut to what a fetch and a checkout need"
else
  fail "dangerous keys survived: $(git config --file "$W/.git/config" --list | tr '\n' ' ')"
fi
rm -f "$M"

W="$(mk_repo fifo)"
mkfifo "$W/.git/refs/heads/evil"
AI_REPO_URL="$TMP/fifo.git" p_timeout 20 "$SCRIPT" inspect "$W" >"$TMP/fifo.out" 2>&1; rc=$?
if [[ "$rc" != 0 && "$rc" != 124 ]] && grep -q 'not a regular file or directory' "$TMP/fifo.out"; then
  pass "a FIFO in .git is refused, not read (no hang)"
else
  fail "FIFO in .git (rc=$rc: $(tr '\n' ' ' < "$TMP/fifo.out"))"
fi
( exec 3<>"$W/.git/refs/heads/evil" ) 2>/dev/null

W="$(mk_repo gitfile)"
mv "$W/.git" "$TMP/gitfile-real.git"; printf 'gitdir: %s\n' "$TMP/gitfile-real.git" > "$W/.git"
run_script inspect "$W"
if [[ "$RC" != 0 && "$OUT" == *"is a file or link"* ]]; then pass "a .git FILE (pointing anywhere) is refused"
else fail ".git file accepted (rc=$RC: $OUT)"; fi

# The remote is the one repo.sh recorded, not the one the .git names: the agent
# could point origin at any repository your SSH key reads, and the next sync
# would fetch it into a volume it reads (security review of 6f5dd80).
W="$(mk_repo pinned)"; mk_repo other >/dev/null
git -C "$W" remote set-url origin "$TMP/other.git"
git -C "$W" remote add extra "$TMP/other.git"
run_script inspect "$W"
grep -qx 'PRIMARY|main' <<<"$OUT" || fail "inspect read the remote the .git names (out: $(tr '\n' ' ' <<<"$OUT"))"
run_script reset "$W" main
if [[ "$(git -C "$W" remote get-url origin)" == "$TMP/pinned.git" ]] && ! git -C "$W" remote get-url extra >/dev/null 2>&1 \
   && [[ "$(git config --file "$W/.git/config" --get remote.origin.fetch)" == '+refs/heads/*:refs/remotes/origin/*' ]]; then
  pass "the remote is the recorded URL, with the standard refspec, and no other remote is kept"
else
  fail "remote not pinned (origin: $(git -C "$W" remote get-url origin); remotes: $(git -C "$W" remote | tr '\n' ' '))"
fi
AI_REPO_URL="" run_script inspect "$W"
if [[ "$RC" != 0 && "$OUT" == *"no recorded URL"* ]]; then pass "without a recorded URL the helper runs no git at all"
else fail "helper ran without AI_REPO_URL (rc=$RC: $OUT)"; fi
if grep -qF -- '-c fetch.recurseSubmodules=false' "$SCRIPT" && grep -qF -- '-c submodule.recurse=false' "$SCRIPT"; then
  pass "submodules are never recursed into (their config is not sanitised)"
else
  fail "the git wrapper does not turn submodule recursion off"
fi

# With .git/config deleted, git falls back to a legacy .git/remotes/origin (or
# .git/branches/origin) for the remote: the pin must not depend on a config file
# being there to rewrite (re-review of b86cfe6).
W="$(mk_repo legacy)"; mk_repo secret >/dev/null
S2="$TMP/secret.seed"; commit_in "$S2" SECRET-CONTENT; g "$S2" push -q origin main >/dev/null 2>&1
rm -f "$W/.git/config"; mkdir -p "$W/.git/remotes" "$W/.git/branches"
printf 'URL: %s\nPull: refs/heads/*:refs/remotes/origin/*\n' "$TMP/secret.git" > "$W/.git/remotes/origin"
printf '%s\n' "$TMP/secret.git" > "$W/.git/branches/origin"
run_script inspect "$W"; run_script reset "$W" main
log_l="$(git -C "$W" log --all --format=%s 2>/dev/null)"
if [[ $'\n'"$log_l"$'\n' != *$'\nadd SECRET-CONTENT\n'* ]] \
   && [[ ! -e "$W/.git/remotes" && ! -e "$W/.git/branches" ]]; then
  pass "a deleted config with a legacy remotes file still fetches only the recorded URL"
else
  fail "legacy remote file was used (log: $(git -C "$W" log --all --format=%s 2>&1 | tr '\n' ' '); out: $OUT)"
fi
# An alternates chain into the worktree can end in a FIFO the scan of .git never
# sees: a seed clone has no alternates, so the file is not kept (re-review, F2).
W="$(mk_repo alt)"
mkdir -p "$W/evil/info" && mkfifo "$W/evil/info/alternates"
printf '%s\n' "$W/evil" > "$W/.git/objects/info/alternates"
AI_REPO_URL="$TMP/alt.git" p_timeout 20 "$SCRIPT" inspect "$W" >"$TMP/alt.out" 2>&1; rc=$?
# Either guard stops it: the FIFO in the worktree is refused, or the alternates
# file that leads to it is dropped. What must never happen is the hang.
if [[ "$rc" != 124 ]] && { [[ ! -e "$W/.git/objects/info/alternates" ]] || grep -q 'not a regular file or directory' "$TMP/alt.out"; }; then
  pass "an alternates chain to a FIFO hangs nothing"
else fail "alternates (rc=$rc: $(tr '\n' ' ' < "$TMP/alt.out"))"; fi
( exec 3<>"$W/evil/info/alternates" ) 2>/dev/null
# A branch named like an option is a refname the agent can write; it is never
# handed to git where an option is parsed (re-review, F3).
W="$(mk_repo dash)"
g "$W" update-ref "refs/heads/--output=$TMP/dash-pwned" HEAD
run_script inspect "$W"
run_script reset "$W" main
if [[ ! -e "$TMP/dash-pwned" ]]; then pass "a branch named --output=… is not parsed as an option"
else fail "a branch name was parsed as an option ($TMP/dash-pwned was written)"; fi

# reset promises the remote's tip and a clean slate; refs the agent can write
# must not redirect it (re-review of the batch 2 fixes, G1-G5).
evil_commit() {  # $1 = repo → a commit whose f says EVIL, on no branch
  local t; t="$(printf 'EVIL\n' | git -C "$1" hash-object -w --stdin)"
  t="$(printf '100644 blob %s\tfirst\n' "$t" | git -C "$1" mktree)"
  git -C "$1" commit-tree "$t" -m evil </dev/null
}
W="$(mk_repo tagjack)"; g "$W" tag origin/main "$(evil_commit "$W")"
run_script inspect "$W"; run_script reset "$W" main
if [[ "$(cat "$W/first")" == first ]]; then pass "a tag named origin/<primary> does not take over reset's target"
else fail "reset landed on the agent's tag (first: $(cat "$W/first"); out: $OUT)"; fi
W="$(mk_repo replace)"; g "$W" replace -f "$(g "$W" rev-parse origin/main)" "$(evil_commit "$W")"
run_script inspect "$W"; run_script reset "$W" main
if [[ "$(cat "$W/first")" == first && -z "$(g "$W" for-each-ref refs/replace)" ]]; then
  pass "a replace ref neither swaps reset's content nor survives it"
else fail "replace ref (first: $(cat "$W/first"); refs: $(g "$W" for-each-ref refs/replace | tr '\n' ' '))"; fi
W="$(mk_repo ambig)"; g "$W" checkout -q -b rel >/dev/null 2>&1; commit_in "$W" r1; commit_in "$W" r2
g "$W" checkout -q main >/dev/null 2>&1; g "$W" tag rel main
run_script inspect "$W"
if grep -qx 'BRANCH|rel|2|' <<<"$OUT"; then pass "a branch that shares its name with a tag is reported by its name, with its unpushed count"
else fail "ambiguous branch (out: $(tr '\n' ' ' <<<"$OUT"))"; fi
run_script reset "$W" main
if ! g "$W" show-ref --verify --quiet refs/heads/rel && grep -qx 'DELETED|rel' <<<"$OUT"; then pass "… and reset really deletes it"
else fail "reset of ambiguous branch (out: $(tr '\n' ' ' <<<"$OUT"))"; fi
W="$(mk_repo hide)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" w1; commit_in "$W" w2; commit_in "$W" w3
g "$W" update-ref refs/remotes/elsewhere/work work; g "$W" checkout -q main >/dev/null 2>&1
run_script inspect "$W"
if grep -qx 'BRANCH|work|3|' <<<"$OUT"; then pass "unpushed work is counted against origin, not refs the agent can plant"
else fail "unpushed count fooled (out: $(tr '\n' ' ' <<<"$OUT"))"; fi
W="$(mk_repo attrfifo)"; mkfifo "$W/.gitattributes"
AI_REPO_URL="$TMP/attrfifo.git" p_timeout 20 "$SCRIPT" reset "$W" main >"$TMP/af.out" 2>&1; rc=$?
if [[ "$rc" != 124 ]] && grep -q 'not a regular file or directory' "$TMP/af.out"; then pass "a FIFO in the worktree is refused, not read (no hang)"
else fail "worktree FIFO (rc=$rc: $(tr '\n' ' ' < "$TMP/af.out"))"; fi
( exec 3<>"$W/.gitattributes" ) 2>/dev/null

# refs/remotes/origin is the agent's to write; a successful fetch overwrites it
# with the remote's tips, but a failed one leaves it as planted — so then no
# count is trusted (security review of 61f7806).
W="$(mk_repo staleref)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" s1
g "$W" update-ref refs/remotes/origin/work work; g "$W" checkout -q main >/dev/null 2>&1
AI_REPO_URL="$TMP/does-not-exist.git" run_script inspect "$W"
if grep -q '^STALE|' <<<"$OUT" && grep -qx 'BRANCH|work|?|' <<<"$OUT"; then
  pass "after a failed fetch every unpushed count is unknown, not read from planted refs"
else
  fail "stale refs trusted (out: $(tr '\n' ' ' <<<"$OUT"))"
fi

# A symbolic ref under refs/remotes/origin survives fetch --prune; it must not
# make unpushed work look pushed (security review of cbf90aa).
W="$(mk_repo symref)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" y1; commit_in "$W" y2
g "$W" checkout -q main >/dev/null 2>&1; g "$W" symbolic-ref refs/remotes/origin/planted refs/heads/work
run_script inspect "$W"
if grep -qx 'BRANCH|work|2|' <<<"$OUT"; then pass "a planted symbolic ref under refs/remotes/origin hides no unpushed work"
else fail "symbolic ref hid unpushed work (out: $(tr '\n' ' ' <<<"$OUT"))"; fi

# … nor with a .lock beside it (security review of f6368d6): the volume's refs
# are never what a count is made against.
W="$(mk_repo symlock)"; g "$W" checkout -q -b work >/dev/null 2>&1; commit_in "$W" z1
g "$W" checkout -q main >/dev/null 2>&1; g "$W" symbolic-ref refs/remotes/origin/planted refs/heads/work
: > "$W/.git/refs/remotes/origin/planted.lock"
run_script inspect "$W"
if grep -qx 'BRANCH|work|1|' <<<"$OUT"; then pass "a planted symbolic ref that cannot be removed hides no unpushed work"
else fail "undeletable symref trusted (out: $(tr '\n' ' ' <<<"$OUT"))"; fi

# The replace-ref cleanup is itself a ref update: an agent's reference-transaction
# hook must not run through it (re-review of 61f7806, H1).
W="$(mk_repo hookreplace)"; M2="$TMP/ran-hookreplace"
g "$W" replace -f "$(g "$W" rev-parse HEAD)" "$(evil_commit "$W")"
printf '#!/bin/sh\necho ran >> %s\n' "$M2" > "$W/.git/hooks/reference-transaction"; chmod +x "$W/.git/hooks/reference-transaction"
run_script inspect "$W"; run_script reset "$W" main
if [[ ! -e "$M2" && -z "$(g "$W" for-each-ref refs/replace)" && ! -e "$W/.git/hooks/reference-transaction" ]]; then
  pass "a replace ref and a hook in the volume's .git run nothing, and are gone after reset"
else fail "hook ran during replace-ref cleanup ($(cat "$M2" 2>/dev/null | wc -l) times)"; fi
# A socket in the checkout does not hang git and clean -ffdx removes it, so it
# is not refused; a FIFO is (re-review, H5).
W="$(mk_repo sock)"
if command -v python3 >/dev/null 2>&1; then
  python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$W/app.sock"
  run_script reset "$W" main
  if [[ "$RC" == 0 ]]; then pass "a stale socket in the checkout does not refuse the reset"
  else fail "socket refused (rc=$RC: $OUT)"; fi
fi
# The grafts setting must not bury a fetch error under git's deprecation hint.
W="$(mk_repo hint)"
AI_REPO_URL="$TMP/does-not-exist.git" run_script inspect "$W"
if grep -q '^STALE|fatal: repository .*does-not-exist.git' <<<"$OUT" && ! grep -qi 'graft' <<<"$OUT"; then
  pass "an unreachable remote's STALE reason is git's error, not a grafts hint"
else fail "STALE reason (out: $(grep STALE <<<"$OUT" | cut -c1-160))"; fi

# pull: the fast-forward repo.sh sync runs, through the same guarded path.
W="$(mk_repo pull)"
S="$TMP/pull.seed"; commit_in "$S" newer; g "$S" push -q origin main >/dev/null 2>&1
git -C "$W" config core.fsmonitor "sh -c 'echo fsmonitor >> $M'"
run_script pull "$W"
if [[ "$RC" == 0 && -f "$W/newer" && ! -e "$M" ]]; then pass "pull fast-forwards, and runs nothing the .git holds"
else fail "pull (rc=$RC; newer: $([[ -f "$W/newer" ]] && echo yes || echo no); ran: $(cat "$M" 2>/dev/null); out: $OUT)"; fi
rm -f "$M"

# ── The redesign's own promises ──────────────────────────────────────────────
# R1 of the review of f6368d6: a dangling symbolic ref for origin/main and a
# .lock that stops set-head made reset keep the agent's commit on main. Nothing
# in the volume's .git is read for that decision any more.
W="$(mk_repo dangle)"; commit_in "$W" evil.txt
g "$W" symbolic-ref refs/remotes/origin/main refs/heads/nonexistent
rm -f "$W/.git/refs/remotes/origin/HEAD"; : > "$W/.git/refs/remotes/origin/HEAD.lock"
tip_r="$(git -C "$TMP/dangle.git" rev-parse --short main)"
run_script inspect "$W"; grep -qx 'PRIMARY|main' <<<"$OUT" || fail "dangle: no PRIMARY (out: $(tr '\n' ' ' <<<"$OUT"))"
grep -qx 'BRANCH|main|1|current' <<<"$OUT" || fail "dangle: main's unpushed commit not counted (out: $(tr '\n' ' ' <<<"$OUT"))"
run_script reset "$W" main
if [[ "$OUT" == *"AT|$tip_r"* && ! -e "$W/evil.txt" && "$(git -C "$W" rev-parse --short HEAD)" == "$tip_r" ]]; then
  pass "planted refs and locks cannot keep reset off the remote's tip"
else
  fail "reset landed off the remote tip (out: $(tr '\n' ' ' <<<"$OUT"))"
fi
if [[ -z "$(git -C "$W" for-each-ref refs/remotes/origin/HEAD.lock 2>/dev/null)" && ! -e "$W/.git/refs/remotes/origin/HEAD.lock" ]]; then
  pass "… and after reset the .git is the fresh clone's, nothing the agent left"
else fail "agent's .git leftovers survived reset"; fi

# sync keeps what it can and refuses what it cannot: untracked files and pushed
# branches stay; an edit, an unpushed branch or a diverged branch refuses.
W="$(mk_repo keep)"; S="$TMP/keep.seed"
commit_in "$S" upstream-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'scratch\n' > "$W/untracked.txt"
g "$W" branch --track shared origin/shared >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" == 0 && -f "$W/upstream-new" && -f "$W/untracked.txt" ]] && g "$W" show-ref --verify --quiet refs/heads/shared; then
  pass "pull fast-forwards, keeping untracked files and branches already on the remote"
else fail "pull lost something (rc=$RC; out: $OUT)"; fi
W="$(mk_repo dirty)"; S="$TMP/dirty.seed"
commit_in "$S" newer2; g "$S" push -q origin main >/dev/null 2>&1
printf 'edited\n' > "$W/first"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"uncommitted changes"* && "$(cat "$W/first")" == edited ]]; then
  pass "pull refuses a checkout with uncommitted changes, and keeps them"
else fail "pull over uncommitted changes (rc=$RC; out: $OUT)"; fi
W="$(mk_repo unpushed)"
g "$W" checkout -q -b local-work >/dev/null 2>&1; commit_in "$W" lw; g "$W" checkout -q main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *"local-work has commits on no remote"* ]] && g "$W" show-ref --verify --quiet refs/heads/local-work; then
  pass "pull refuses while a local branch holds unpushed work, and keeps it"
else fail "pull with an unpushed branch (rc=$RC; out: $OUT)"; fi
W="$(mk_repo diverged)"; S="$TMP/diverged.seed"
commit_in "$W" mine; commit_in "$S" theirs; g "$S" push -q origin main >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && -f "$W/mine" ]]; then pass "pull refuses a branch with commits of its own"
else fail "pull of a diverged branch (rc=$RC; out: $OUT)"; fi

# sync must lose nothing the old `git pull --ff-only` kept (review of d9b56a8, P1):
# an untracked file the remote now tracks, a stash, a tag on no remote, a linked
# worktree — each refuses, and is kept.
W="$(mk_repo collide)"; S="$TMP/collide.seed"
commit_in "$S" notes.txt; g "$S" push -q origin main >/dev/null 2>&1
printf 'mine\n' > "$W/notes.txt"
run_script pull "$W"
if [[ "$RC" != 0 && "$(cat "$W/notes.txt")" == mine ]]; then pass "pull refuses to overwrite an untracked file the remote now tracks"
else fail "pull overwrote an untracked file (rc=$RC; notes: $(cat "$W/notes.txt"); out: $OUT)"; fi
W="$(mk_repo stash)"; S="$TMP/stash.seed"; commit_in "$S" s-new; g "$S" push -q origin main >/dev/null 2>&1
printf 'wip\n' > "$W/first"; g "$W" stash -q
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *stash* ]] && g "$W" rev-parse -q --verify refs/stash >/dev/null; then pass "pull refuses while a stash would be lost"
else fail "pull with a stash (rc=$RC; out: $OUT)"; fi
W="$(mk_repo ltag)"; S="$TMP/ltag.seed"; commit_in "$S" t-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" tag -a -m mine v-local; commit_in "$W" only-local; g "$W" tag lone; g "$W" reset -q --hard HEAD~1
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *tag* ]] && g "$W" rev-parse -q --verify refs/tags/lone >/dev/null; then pass "pull refuses while a tag on no remote would be lost"
else fail "pull with a local tag (rc=$RC; out: $OUT)"; fi
W="$(mk_repo wt)"; S="$TMP/wt.seed"; commit_in "$S" w-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" worktree add -q "$TMP/wt-linked" shared >/dev/null 2>&1
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" == *worktree* ]]; then pass "pull refuses while a linked worktree would be cut off"
else fail "pull with a linked worktree (rc=$RC; out: $OUT)"; fi
# A failed install never leaves the volume without a .git (P4); a ref file with
# no newline and no end is read only so far (P6).
W="$(mk_repo hugeref)"; head -c 5000000 /dev/zero | tr '\0' a > "$W/.git/refs/heads/huge"
run_script inspect "$W"
if [[ "$RC" == 0 ]] && grep -qx 'BRANCH|huge|?|' <<<"$OUT"; then pass "a ref file that is not a ref is read only as far as needed, and counted unknown"
else fail "huge ref file (rc=$RC; out: $(head -c 300 <<<"$OUT"))"; fi
# The volume's own alternates are not followed for the counts (P3).
W="$(mk_repo altout)"; mkdir -p "$TMP/elsewhere"; git init -q "$TMP/elsewhere"; commit_in "$TMP/elsewhere" far
oid_far="$(g "$TMP/elsewhere" rev-parse HEAD)"
printf '%s\n' "$TMP/elsewhere/.git/objects" > "$W/.git/objects/info/alternates"
printf '%s\n' "$oid_far" > "$W/.git/refs/heads/elsewhere"
run_script inspect "$W"
if grep -qx 'BRANCH|elsewhere|?|' <<<"$OUT"; then pass "inspect does not follow the volume's own alternates out of it"
else fail "volume alternates followed (out: $(tr '\n' ' ' <<<"$OUT"))"; fi

# Tags live only in .git, which sync replaces: each local tag comes back at the
# value it had — one on a pushed commit, one re-pointed with tag -f — as
# `git pull --ff-only` would have left them (review of fb1705e, Q1).
W="$(mk_repo keeptag)"; S="$TMP/keeptag.seed"; commit_in "$S" kt-new; g "$S" push -q origin main >/dev/null 2>&1
g "$W" tag mylabel HEAD
run_script pull "$W"
if [[ "$RC" == 0 && "$(g "$W" rev-parse -q --verify refs/tags/mylabel 2>/dev/null)" == "$(g "$W" rev-parse HEAD~1)" ]]; then
  pass "a local tag on a pushed commit survives sync, at its own commit"
else fail "local tag lost by sync (rc=$RC; tags: $(g "$W" tag -l | tr '\n' ' '); out: $OUT)"; fi
# Messages on stderr carry names from the volume too (Q2).
W="$(mk_repo escerr)"; printf 'ref: refs/heads/z\e]0;pwned\a\n' > "$W/.git/HEAD"
run_script pull "$W"
if [[ "$RC" != 0 && "$OUT" != *$'\e'* && "$OUT" != *$'\a'* ]]; then pass "a name in an error message is shown as ?, not raw"
else fail "raw control characters in an error (out: $(cat -v <<<"$OUT"))"; fi
# A git directory the agent puts anywhere in the worktree (where the remote has
# a submodule, say) is read by git during checkout: it holds only regular files
# and directories too, or the volume is refused (Q3).
W="$(mk_repo subgit)"; mkdir -p "$W/sub/.git/refs/heads"; ln -s /dev/zero "$W/sub/.git/refs/heads/x"
run_script reset "$W" main
if [[ "$RC" != 0 && "$OUT" == *"sub/.git/refs/heads/x is not a regular file or directory"* ]]; then pass "a link inside a nested .git is refused"
else fail "nested .git link (rc=$RC; out: $OUT)"; fi
grep -qE -- '--memory[ =]' "$REPO_DIR/repo.sh" 2>/dev/null || grep -qE -- '--memory[ =]' "$(dirname "$SCRIPT")/repo.sh" \
  && pass "the seed containers that run git are given a memory limit" || fail "no --memory on the git helper's container"

# Branch names are read as file names, which git's rules do not bind: one holding
# terminal escapes reaches the confirmation only as ? (security review of d9b56a8).
W="$(mk_repo esc)"; cp "$W/.git/refs/heads/main" "$W/.git/refs/heads/x"$'\e]0;pwned\a'
run_script inspect "$W"
if [[ "$OUT" != *$'\e'* && "$OUT" != *$'\a'* ]] && grep -q '^BRANCH|x?]0;pwned?|' <<<"$OUT"; then
  pass "control characters in a branch file's name are shown as ?"
else fail "raw control characters in the records ($(cat -v <<<"$OUT" | tr '\n' ' '))"; fi
W="$(mk_repo c1)"; cp "$W/.git/refs/heads/main" "$W/.git/refs/heads/y"$'\xc2\x9b'"31m"
run_script inspect "$W"
if [[ "$OUT" != *$'\xc2\x9b'* && "$OUT" != *$'\x9b'* ]] && grep -q '^BRANCH|y??31m|' <<<"$OUT"; then
  pass "an 8-bit (C1) control sequence in a branch file's name is shown as ?"
else fail "C1 control in the records ($(cat -v <<<"$OUT" | tr '\n' ' '))"; fi

printf '\n%s\n' "----------------------------------------"
if [[ "$fails" -eq 0 ]]; then
  printf 'test-repo-git-reset.sh: all checks passed\n'; exit 0
fi
printf 'test-repo-git-reset.sh: %s check(s) failed\n' "$fails"
exit 1
