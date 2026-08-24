#!/usr/bin/env bash
# repo-git-reset.sh — the git half of `repo.sh reset`, for a git-backed repo
# volume: find the remote's primary branch, put the checkout on it at the
# remote's tip, and drop everything else.
#
# ── WHY THIS IS A FILE AND NOT A STRING ──────────────────────────────────────
# repo.sh's other container-side programs are bash strings passed to
# `docker run … bash -c '…'`. That is fine for `git clone` and `git pull`, which
# are one call each. This one is a dozen calls with branch detection, fallbacks
# and a destructive loop, and the hermetic suite's fake `docker` can only record
# the STRING — it cannot run git. Asserting the string is asserting
# configuration, which is the thing this project's tests exist not to do.
#
# As a file it is executable directly against a real git repository, and git is
# available hermetically where docker is not. So `tests/test-repo-git-reset.sh`
# builds real repos with real branches and real unpushed commits, runs this, and
# asserts what actually happened to them. repo.sh mounts it into the seed
# container read-only, so no seed-image rebuild is involved and an existing
# seed image keeps working.
#
# ── TWO MODES, AND WHY THE FETCH IS IN THE FIRST ONE ─────────────────────────
#   inspect <dir>                        read-only; fetches, then reports
#   reset   <dir> <primary> [<uid:gid>]  destructive; does NOT fetch
#
# `repo.sh` must tell you which branches it is about to delete BEFORE you
# confirm, and an accurate "not on any remote" count needs current remote refs —
# so the fetch belongs to `inspect`, whose results the prompt is built from.
# `reset` then acts on the state `inspect` left in the volume, and is handed the
# primary branch NAME that the prompt showed you, so what was promised is what
# happens rather than a second derivation that could differ.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  repo-git-reset.sh inspect <dir>
  repo-git-reset.sh reset   <dir> <primary-branch> [<uid>:<gid>]

inspect  Fetch (pruning), then report on stdout, one record per line:
           PRIMARY|<branch>
           STALE|<reason>                  only when the fetch failed
           BRANCH|<name>|<unpushed>|<flags> one per local branch
         `unpushed` counts commits on that branch that are on no remote.
         `flags` is `current` for the checked-out branch, else empty.

reset    Put the checkout on <primary-branch> at its remote tip, discard
         uncommitted changes and untracked/ignored files, and delete every
         other local branch. Does not fetch. chowns the tree when given
         <uid>:<gid>.
EOF
}

die() { printf 'repo-git-reset: %s\n' "$1" >&2; exit 1; }

# `git config --global` would write to the invoking user's real ~/.gitconfig, so
# it is done only as root — which is exactly the container case it exists for
# (the volume is owned by the host UID, and git refuses "dubious ownership").
# Running as a normal user on the host, the caller owns the tree and git does
# not complain, so there is nothing to add.
mark_safe_directory() {  # $1 = dir
  [[ "$(id -u)" == "0" ]] || return 0
  git config --global --add safe.directory "$1" >/dev/null 2>&1 || true
}

have_origin() { git -C "$1" remote get-url origin >/dev/null 2>&1; }

# The remote's own answer, preferred over guessing. `set-head -a` re-asks the
# remote, so a default branch renamed after this volume was cloned is picked up;
# it needs the network, and when that fails the ref recorded at clone time is
# still there to read. Only then do the guesses apply, and the LAST resort is
# whatever is checked out — never a hardcoded "main", which would silently
# retarget a repo whose default is something else.
# Returns 0 having echoed a name, or 1 having echoed nothing. That status is
# READ by the caller — not decoration. When it was ignored, every `return`
# in here could be flipped with no observable effect, which is a fair
# description of a value that means nothing.
detect_primary() {  # $1 = dir  → echoes a branch name; 1 if there is none
  local dir="$1" ref name
  if have_origin "$dir"; then
    git -C "$dir" remote set-head origin -a >/dev/null 2>&1 || true
    ref="$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
    if [[ -n "$ref" ]]; then
      name="${ref#refs/remotes/origin/}"
      [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
    fi
    local guess
    for guess in main master; do
      if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$guess"; then
        printf '%s' "$guess"; return 0
      fi
    done
  fi
  # No remote, or a remote with no usable head: stay where we are.
  name="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [[ -n "$name" ]]; then printf '%s' "$name"; return 0; fi
  # Detached HEAD with no usable remote — there is no branch to name.
  return 1
}

cmd_inspect() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || { usage >&2; die "inspect needs a directory"; }
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || die "not a git repository: $dir"
  mark_safe_directory "$dir"

  if have_origin "$dir"; then
    local err
    if ! err="$(git -C "$dir" fetch --prune origin 2>&1)"; then
      # One line, and the first one: a multi-line git error would corrupt the
      # record-per-line contract this output is parsed under.
      printf 'STALE|%s\n' "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"
    fi
  else
    printf 'STALE|no "origin" remote — nothing to fetch from\n'
  fi

  local primary
  if primary="$(detect_primary "$dir")"; then
    printf 'PRIMARY|%s\n' "$primary"
  fi

  local current; current="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  local b unpushed flags
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    # Commits reachable from this branch and from NO remote-tracking ref. This
    # is the number that decides whether deleting the branch destroys work.
    unpushed="$(git -C "$dir" rev-list --count "$b" --not --remotes 2>/dev/null)"
    unpushed="${unpushed//[^0-9]/}"
    flags=""
    [[ "$b" == "$current" ]] && flags="current"
    printf 'BRANCH|%s|%s|%s\n' "$b" "${unpushed:-0}" "$flags"
  done < <(git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
}

cmd_reset() {
  local dir="${1:-}" primary="${2:-}" owner="${3:-}"
  [[ -n "$dir" && -n "$primary" ]] || { usage >&2; die "reset needs a directory and a primary branch"; }
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || die "not a git repository: $dir"
  mark_safe_directory "$dir"

  # Where the primary branch should end up. With a remote-tracking ref, that is
  # the remote's tip; without one (no remote, or a purely local repo) the branch
  # keeps its own tip — reset still cleans the tree and drops the other
  # branches, it just has nothing newer to move to.
  local target="$primary"
  if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$primary"; then
    target="origin/$primary"
  fi

  if git -C "$dir" show-ref --verify --quiet "refs/heads/$primary"; then
    git -C "$dir" checkout --force "$primary" >/dev/null 2>&1 \
      || die "could not check out $primary"
  elif [[ "$target" != "$primary" ]]; then
    # The remote has it and we do not: create it tracking the remote.
    git -C "$dir" checkout --force -B "$primary" "$target" >/dev/null 2>&1 \
      || die "could not create $primary from $target"
  else
    die "no local or remote branch named $primary"
  fi

  git -C "$dir" reset --hard "$target" >/dev/null 2>&1 || die "could not reset to $target"
  git -C "$dir" clean -ffdx >/dev/null 2>&1 || die "could not clean the working tree"

  # Every other local branch. `-D`, not `-d`: an unmerged branch is exactly what
  # the caller has already been shown and has confirmed.
  local b deleted=0
  while IFS= read -r b; do
    [[ -n "$b" && "$b" != "$primary" ]] || continue
    if git -C "$dir" branch -D "$b" >/dev/null 2>&1; then
      printf 'DELETED|%s\n' "$b"; deleted=$(( deleted + 1 ))
    else
      printf 'KEPT|%s|could not delete\n' "$b"
    fi
  done < <(git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

  printf 'ON|%s\n' "$primary"
  printf 'AT|%s\n' "$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
  printf 'DELETED-COUNT|%s\n' "$deleted"

  [[ -n "$owner" ]] && { chown -R "$owner" "$dir" || printf 'WARN|chown failed\n'; }
  return 0
}

case "${1:-}" in
  inspect) shift; cmd_inspect "$@" ;;
  reset)   shift; cmd_reset   "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
