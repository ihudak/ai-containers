#!/usr/bin/env bash
# repo-git-reset.sh — the git half of `repo.sh reset` and `repo.sh sync` for a
# git-backed repo volume: report its branches, put it on the remote's primary
# branch at the remote's tip, or fast-forward it.
#
# ── WHY THIS IS A FILE AND NOT A STRING ──────────────────────────────────────
# The hermetic suite's fake `docker` can only record a `bash -c '…'` string; it
# cannot run git. As a file this runs directly against real repositories, and
# `tests/test-repo-git-reset.sh` builds them and asserts what actually happened.
# repo.sh mounts it into the seed container read-only.
#
# ── WHY GIT NEVER RUNS ON THE VOLUME'S OWN .git ──────────────────────────────
# This runs as ROOT in the seed container, with the host's ~/.ssh keys and an
# open network, on a volume the agent can write — worktree and .git — whenever
# it is attached :rw (the launcher's git-internals overlay covers host binds,
# not volumes). Git reads far more from a .git than any guard can enumerate:
# config and its includes, hooks, commondir, legacy remotes/ and branches/,
# alternates, replace refs, grafts, symbolic and dangling refs, lock files. Five
# review rounds of sanitising it each found another (bugs review 2026-10-26).
# So no git here opens the volume's .git. Each mode clones the URL repo.sh
# recorded at `add` (AI_REPO_URL — a volume label nothing in a container can
# change) into a private directory of this container, and works there:
#
#   inspect <dir>                        read-only: the remote's primary branch,
#                                        and each local branch's unpushed count
#   reset   <dir> <primary> [<uid:gid>]  the checkout becomes a clean copy of the
#                                        remote's <primary>; every other local
#                                        branch, edit and untracked file is gone
#   pull    <dir> [<uid:gid>]            fast-forward the checked-out branch;
#                                        refused if anything would be lost
#
# The volume's branch tips are read as plain files (refs/heads, packed-refs,
# HEAD), never by git, and never a file that is not regular. Its worktree is
# only ever a worktree for the private clone's git, whose config is the
# clone's own; a FIFO or device anywhere in the volume is refused first, since
# git would block opening it. For the unpushed counts only, the private clone
# reads the volume's objects as an alternate store — objects, not config or
# refs — with the commit-graph off.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  repo-git-reset.sh inspect <dir>
  repo-git-reset.sh reset   <dir> <primary-branch> [<uid>:<gid>]
  repo-git-reset.sh pull    <dir> [<uid>:<gid>]

inspect  Clone the recorded remote privately, then report on stdout, one
         record per line:
           PRIMARY|<branch>                the remote's default branch
           STALE|<reason>                  only when the remote could not be cloned
           BRANCH|<name>|<unpushed>|<flags> one per local branch of the volume
         `unpushed` counts that branch's commits on no remote branch, `?` when
         it cannot be counted. `flags` is `current` for the checked-out branch.

reset    Make the volume a clean checkout of the remote's <primary-branch>:
         edits, untracked and ignored files, and every other local branch go.
         Needs the remote. chowns the tree when given <uid>:<gid>.

pull     Fast-forward the checked-out branch to the remote's tip, keeping
         untracked files and every branch already on the remote. Refused when
         the checkout has uncommitted changes or any local branch has commits
         on no remote branch.
EOF
}

die() { printf 'repo-git-reset: %s\n' "$1" >&2; exit 1; }

# Every git here runs on the private clone, whose config and hooks are its own.
# Still: hooks pointed nowhere, fsmonitor off, no submodule recursion, only
# network transports (and file, for a local remote), no replace refs or grafts,
# no system config.
export GIT_ALLOW_PROTOCOL="ssh:https:http:git:file"
export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/nonexistent/ai-containers-no-grafts GIT_CONFIG_NOSYSTEM=1
git() {
  command git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.useReplaceRefs=false \
    -c fetch.recurseSubmodules=false -c submodule.recurse=false -c advice.detachedHead=false "$@"
}

# `git config --global` would write the invoking user's real ~/.gitconfig, so it
# is done only as root — the container case: the volume is owned by the host
# UID, and git refuses a worktree another user owns.
mark_safe_directory() {  # $1 = dir
  [[ "$(id -u)" == "0" ]] || return 0
  git config --global --add safe.directory "$1" >/dev/null 2>&1 || true
}

WORK=""
trap '[[ -n "$WORK" ]] && rm -rf "$WORK"' EXIT

# check_volume <dir>: the recorded URL is there, <dir>/.git is a real directory
# holding only files and directories (the ref files below are read as text),
# and nothing in the volume is a FIFO or device (git would block opening one).
check_volume() {
  local dir="$1" gd="$1/.git" bad
  [[ -n "${AI_REPO_URL:-}" ]] || die "no recorded URL for this repository (AI_REPO_URL); refusing to run git on it"
  [[ -d "$gd" && ! -L "$gd" ]] || die "not a git repository: $dir (.git is missing, or is a file or link)"
  bad="$(find "$gd" ! -type f ! -type d -print -quit 2>/dev/null)"
  [[ -z "$bad" ]] || die "$bad is not a regular file or directory; refusing this repository"
  bad="$(find "$dir" -path "$gd" -prune -o \( -type p -o -type b -o -type c \) -print -quit 2>/dev/null)"
  [[ -z "$bad" ]] || die "$bad is not a regular file or directory; refusing this repository"
}

# fresh_clone: clone AI_REPO_URL, without a checkout, into a private directory;
# sets F. Fails with git's first error line on stderr's place, in CLONE_ERR.
F="" CLONE_ERR=""
fresh_clone() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-git.XXXXXX")" || die "cannot make a private directory"
  F="$WORK/clone"
  if ! git clone --quiet --no-checkout -- "$AI_REPO_URL" "$F" 2>"$WORK/err"; then
    CLONE_ERR="$(tr '\n' ' ' < "$WORK/err" | cut -c1-200)"
    return 1
  fi
}

# volume_refs <dir> <kind>: "<name>\t<oid>" per ref under refs/<kind>/ (heads,
# tags, notes), read from the ref files as text — a loose ref wins over
# packed-refs, as in git — with `?` for an oid that is not one (a symbolic ref,
# or garbage). Only the first 200 bytes of a file are read: the agent writes
# them, and a ref is a line of hex.
volume_refs() {
  local gd="$1/.git" kind="$2" f name line oid ref
  local -A seen=()
  while IFS= read -r -d '' f; do
    name="${f#"$gd/refs/$kind/"}"
    line="$(head -c 200 "$f" 2>/dev/null)"; line="${line%%$'\n'*}"
    if [[ "$line" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then oid="$line"; else oid='?'; fi
    seen[$name]=1
    printf '%s\t%s\n' "$name" "$oid"
  done < <(find "$gd/refs/$kind" -type f -print0 2>/dev/null)
  [[ -f "$gd/packed-refs" ]] || return 0
  while IFS=' ' read -r oid ref; do
    [[ "$ref" == "refs/$kind/"* ]] || continue
    name="${ref#"refs/$kind/"}"
    [[ -z "${seen[$name]:-}" ]] || continue
    seen[$name]=1
    [[ "$oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || oid='?'
    printf '%s\t%s\n' "$name" "$oid"
  done < <(cut -c1-300 "$gd/packed-refs")
}
volume_branches() { volume_refs "$1" heads; }

# volume_head <dir>: the checked-out branch's name, from HEAD as text; nothing
# for a detached or unreadable HEAD.
volume_head() {
  local line
  [[ -f "$1/.git/HEAD" ]] || return 0
  line="$(head -c 300 "$1/.git/HEAD" 2>/dev/null)"; line="${line%%$'\n'*}"
  [[ "$line" == 'ref: refs/heads/'* ]] && printf '%s' "${line#ref: refs/heads/}"
  return 0
}

# A name for the records and the terminal: a | or a newline would split the
# records, and a name read from the volume's files is not bound by git's rules,
# so anything but printable ASCII is shown as ? too — in the C locale, so 8-bit
# (C1) controls such as \x9b are caught, which [:cntrl:] misses in UTF-8.
shown() { local LC_ALL=C n="${1//|/?}"; printf '%s' "${n//[^[:print:]]/?}"; }

# on_remote <oid>: the commit is in the private clone and on a remote branch.
on_remote() {
  git -C "$F" cat-file -e "$1^{commit}" 2>/dev/null || return 1
  [[ -n "$(git -C "$F" for-each-ref --count=1 --contains "$1" --format=x refs/remotes/origin/ 2>/dev/null)" ]]
}

remote_primary() {
  local ref
  ref="$(git -C "$F" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  if [[ "$ref" == refs/remotes/origin/?* ]]; then printf '%s' "${ref#refs/remotes/origin/}"; return 0; fi
  local guess
  for guess in main master; do
    if git -C "$F" show-ref --verify --quiet "refs/remotes/origin/$guess"; then printf '%s' "$guess"; return 0; fi
  done
  return 1
}

cmd_inspect() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || { usage >&2; die "inspect needs a directory"; }
  check_volume "$dir"
  local current; current="$(volume_head "$dir")"
  local cloned=1 primary
  if ! fresh_clone; then
    cloned=""
    printf 'STALE|%s\n' "${CLONE_ERR:-the recorded remote could not be cloned}"
  else
    primary="$(remote_primary)" && printf 'PRIMARY|%s\n' "$primary"
    # The volume's objects, for counting — objects only, no config or refs — and
    # not when the volume names alternates of its own, which git would follow
    # out of the volume (review of d9b56a8, P3): then the counts are unknown.
    if [[ -d "$dir/.git/objects" && ! -s "$dir/.git/objects/info/alternates" && ! -s "$dir/.git/objects/info/http-alternates" ]]; then
      printf '%s\n' "$dir/.git/objects" > "$F/.git/objects/info/alternates"
    fi
  fi
  local name oid unpushed flags
  while IFS=$'\t' read -r name oid; do
    [[ -n "$name" ]] || continue
    unpushed='?'
    if [[ -n "$cloned" && "$oid" != '?' ]]; then
      unpushed="$(git -C "$F" -c core.commitGraph=false -c core.multiPackIndex=false \
        rev-list --count "$oid" --not --remotes=origin 2>/dev/null)" || unpushed='?'
      [[ "$unpushed" =~ ^[0-9]+$ ]] || unpushed='?'
    fi
    flags=""; [[ "$name" == "$current" ]] && flags="current"
    printf 'BRANCH|%s|%s|%s\n' "$(shown "$name")" "$unpushed" "$flags"
  done < <(volume_branches "$dir")
  return 0
}

# install_git_dir <dir>: the private clone's .git becomes the volume's — copied
# beside the old one first, so a copy that fails (a full disk) leaves the old
# .git in place rather than none (review of d9b56a8, P4).
install_git_dir() {
  rm -rf "$1/.git.new" || die "could not clear $1/.git.new"
  cp -a "$F/.git" "$1/.git.new" || { rm -rf "$1/.git.new"; die "could not copy the new .git"; }
  rm -rf "$1/.git" || die "could not remove the old .git"
  mv "$1/.git.new" "$1/.git" || die "could not install the new .git"
}

cmd_reset() {
  local dir="${1:-}" primary="${2:-}" owner="${3:-}"
  [[ -n "$dir" && -n "$primary" ]] || { usage >&2; die "reset needs a directory and a primary branch"; }
  [[ "$primary" != -* ]] && command git check-ref-format --branch "$primary" >/dev/null 2>&1 \
    || die "not a branch name: $primary"
  check_volume "$dir"
  local -a before=()
  local name oid
  while IFS=$'\t' read -r name oid; do [[ -n "$name" ]] && before+=("$name"); done < <(volume_branches "$dir")
  fresh_clone || die "cannot clone the recorded remote: ${CLONE_ERR}"
  git -C "$F" show-ref --verify --quiet "refs/remotes/origin/$primary" \
    || die "the remote has no branch named $primary"
  mark_safe_directory "$dir"
  # The volume is only a worktree here: the clone's git checks the remote's tree
  # out into it, then removes everything else — .git is never touched by clean.
  git --git-dir="$F/.git" --work-tree="$dir" checkout --quiet --force -B "$primary" "refs/remotes/origin/$primary" \
    || die "could not check out $primary"
  git --git-dir="$F/.git" --work-tree="$dir" clean -ffdxq || die "could not clean the working tree"
  local b
  while IFS= read -r b; do
    [[ -n "$b" && "$b" != "refs/heads/$primary" ]] && git -C "$F" update-ref -d "$b"
  done < <(git -C "$F" for-each-ref --format='%(refname)' refs/heads/)
  install_git_dir "$dir"

  local deleted=0
  for name in ${before[@]+"${before[@]}"}; do
    [[ "$name" != "$primary" ]] || continue
    printf 'DELETED|%s\n' "$(shown "$name")"; deleted=$(( deleted + 1 ))
  done
  printf 'ON|%s\n' "$primary"
  printf 'AT|%s\n' "$(git -C "$F" rev-parse --short HEAD 2>/dev/null)"
  printf 'DELETED-COUNT|%s\n' "$deleted"
  if [[ -n "$owner" ]]; then chown -R "$owner" "$dir" || printf 'WARN|chown failed\n'; fi
  return 0
}

cmd_pull() {
  local dir="${1:-}" owner="${2:-}"
  [[ -n "$dir" ]] || { usage >&2; die "pull needs a directory"; }
  check_volume "$dir"
  local b; b="$(volume_head "$dir")"
  [[ -n "$b" ]] || die "the checkout is not on a branch (detached HEAD): nothing to fast-forward"
  local -A tip=()
  local name oid
  while IFS=$'\t' read -r name oid; do [[ -n "$name" ]] && tip[$name]="$oid"; done < <(volume_branches "$dir")
  [[ -n "${tip[$b]:-}" && "${tip[$b]}" != '?' ]] || die "cannot read the tip of $b"
  fresh_clone || die "cannot clone the recorded remote: ${CLONE_ERR}"
  git -C "$F" show-ref --verify --quiet "refs/remotes/origin/$b" || die "the remote has no branch named $b"
  # Nothing may be lost: every local branch is already on the remote, and the
  # checked-out one is behind (or at) the remote's tip of the same name.
  for name in "${!tip[@]}"; do
    [[ "${tip[$name]}" != '?' ]] && on_remote "${tip[$name]}" \
      || die "branch $(shown "$name") has commits on no remote branch; push it, or use reset"
  done
  git -C "$F" merge-base --is-ancestor "${tip[$b]}" "refs/remotes/origin/$b" \
    || die "$b has diverged from the remote; push it, or use reset"
  # Nor anything else that lives only in .git, which is replaced (review of
  # d9b56a8, P1): a stash, notes, linked worktrees, a tag on no remote.
  local gd="$dir/.git"
  [[ ! -e "$gd/refs/stash" && ! -e "$gd/logs/refs/stash" ]] && ! grep -qs ' refs/stash$' "$gd/packed-refs" \
    || die "the repository has a stash; apply or drop it, or use reset"
  [[ -z "$(volume_refs "$dir" notes)" ]] || die "the repository has git notes; push or remove them, or use reset"
  [[ -z "$(find "$gd/worktrees" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
    || die "the repository has linked worktrees; remove them (git worktree remove), or use reset"
  local tname toid
  while IFS=$'\t' read -r tname toid; do
    [[ -n "$tname" ]] || continue
    [[ "$toid" != '?' ]] && git -C "$F" cat-file -e "$toid" 2>/dev/null \
      || die "tag $(shown "$tname") is on no remote; push it, or use reset"
  done < <(volume_refs "$dir" tags)
  mark_safe_directory "$dir"
  # The worktree must match its branch's commit: compared by the clone's git,
  # with its own config, against the volume's files.
  git --git-dir="$F/.git" --work-tree="$dir" read-tree "${tip[$b]}" || die "could not read $b"
  git --git-dir="$F/.git" --work-tree="$dir" update-index -q --refresh >/dev/null 2>&1 || true
  git --git-dir="$F/.git" --work-tree="$dir" diff-files --quiet \
    || die "the checkout has uncommitted changes; commit and push them, or use reset"
  # A two-way merge from that commit to the remote's tip, as `pull --ff-only`
  # does, without --force: it refuses to overwrite an untracked file the remote
  # now tracks, and leaves every other untracked file alone.
  git --git-dir="$F/.git" --work-tree="$dir" read-tree -m -u "${tip[$b]}" "refs/remotes/origin/$b" \
    || die "could not fast-forward $b without overwriting files in the checkout (an untracked file the remote now tracks?)"
  git -C "$F" update-ref "refs/heads/$b" "refs/remotes/origin/$b" || die "could not move $b"
  git -C "$F" symbolic-ref HEAD "refs/heads/$b" || die "could not check out $b"
  git -C "$F" branch --quiet --set-upstream-to="origin/$b" "$b" >/dev/null 2>&1 || true
  for name in "${!tip[@]}"; do
    [[ "$name" == "$b" ]] && continue
    command git check-ref-format "refs/heads/$name" >/dev/null 2>&1 || continue
    git -C "$F" update-ref "refs/heads/$name" "${tip[$name]}" || printf 'WARN|could not keep branch %s\n' "$(shown "$name")"
  done
  install_git_dir "$dir"
  if [[ -n "$owner" ]]; then chown -R "$owner" "$dir" || printf 'WARN|chown failed\n'; fi
  printf 'AT|%s\n' "$(git -C "$F" rev-parse --short HEAD 2>/dev/null)"
}

case "${1:-}" in
  inspect) shift; cmd_inspect "$@" ;;
  reset)   shift; cmd_reset   "$@" ;;
  pull)    shift; cmd_pull    "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
