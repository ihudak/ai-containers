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
         record per line, in this order:
           NESTED|<path>                   a git repository inside the checkout, which reset removes
           NESTED-MORE|<n>                 how many more past the first 50
           PRIMARY|<branch>                the remote's default branch
           STALE|<reason>                  only when the remote could not be cloned
           BRANCH|<name>|<unpushed>|<flags> one per local branch of the volume
           STASH|<entries>                 only when the volume has a stash
           TAG|<name>|<kept>|<on-remote>   one per local tag of the volume:
                                           <kept> yes, no, moved (the remote has
                                           it on another commit), same (on the
                                           same commit, another tag object) or ?;
                                           <on-remote> yes when the remote keeps
                                           its commit
           END|inspect                     last, once everything was reported
         reset: DELETED|<branch>, ON|<branch>, AT|<commit>, DELETED-COUNT|<n>,
           REMOVED|<path> for each git repository inside the checkout it removed
         `unpushed` counts that branch's commits on no remote branch or tag, `?` when
         it cannot be counted. `flags` is `current` for the checked-out branch.

reset    Make the volume a clean checkout of the remote's <primary-branch>:
         edits, untracked and ignored files, and every other local branch go.
         Needs the remote. chowns the tree when given <uid>:<gid>.

pull     Fast-forward the checked-out branch to the remote's tip, keeping
         untracked files and every branch already on the remote. Refused when
         the checkout has uncommitted or staged changes, any local branch has
         commits on no remote branch or tag, or anything the fast-forward would
         replace holds untracked or ignored files.
EOF
}

die() {
  local msg="$1" d="${UNDO_DIR:-}"
  # pull fast-forwards the worktree before it installs the new .git. A failure
  # after that left the checkout at the remote's tip under the old .git, where
  # it reads as uncommitted changes and every later sync refuses it (bugs review
  # REPO-6): put the worktree back, or say that reset is the way out. Only while
  # the old .git is whole: install_git_dir clears this before it removes it.
  if [[ -n "$d" ]]; then
    UNDO_DIR=""
    if undo_fast_forward "$d" "$UNDO_FROM" "$UNDO_TO"; then
      msg+="; the checkout was put back as it was"
    else
      msg+="; the checkout could not be put back, so its files may be at the remote's tip under the old .git — run reset to start clean"
    fi
  fi
  printf 'repo-git-reset: %s\n' "$msg" >&2; exit 1
}
# undo_fast_forward <dir> <from> <to>: the two-way merge pull made, reversed.
undo_fast_forward() {
  git --git-dir="$F/.git" --work-tree="$1" read-tree -m -u "$2" "$3" >/dev/null 2>&1
}

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
# Each search fails closed: a directory find cannot enter hides what is in it
# (review of 82698a0, F3).
# glob_quoted <str> <var>: <str> with the characters fnmatch treats specially
# escaped, so find -path matches it literally. A volume path holding [, * or ?
# did not prune its own .git, which reset then removed as nested (REPO-17).
# A loop, not ${s//…/\\&}: that replacement is bash 5.2's, past the floor.
glob_quoted() {
  local -n _gq_out="$2"
  local s="$1" c i
  _gq_out=""
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '*'|'?'|'['|']'|'\') _gq_out+="\\$c" ;;
      *) _gq_out+="$c" ;;
    esac
  done
}

check_volume() {
  local dir="$1" gd="$1/.git" gq bad nosearch nested="${2:-refuse}"
  [[ "$dir" != */ ]] || die "the volume path must not end in a slash: $(shown "$dir")"
  glob_quoted "$gd" gq
  nosearch="cannot check $(shown "$dir"): find could not search all of it (an unreadable directory, or a path too long); refusing this repository"
  [[ -n "${AI_REPO_URL:-}" ]] || die "no recorded URL for this repository (AI_REPO_URL); refusing to run git on it"
  [[ -d "$gd" && ! -L "$gd" ]] || die "not a git repository: $(shown "$dir") (.git is missing, or is a file or link)"
  # The refs are read as files (volume_refs), which the reftable format has none
  # of: inspect named no branch at risk and reset then deleted them all (bugs
  # review REPO-4).
  [[ ! -e "$gd/reftable" && ( ! -e "$gd/refs/heads" || -d "$gd/refs/heads" ) ]] \
    || die "$(shown "$dir") uses the reftable ref format, which this helper cannot read; refusing this repository"
  bad="$(find "$gd" ! -type f ! -type d -print -quit 2>/dev/null)" || die "$nosearch"
  [[ -z "$bad" ]] || die "$(shown "$bad") is not a regular file or directory; refusing this repository"
  bad="$(find "$dir" -path "$gq" -prune -o \( -type p -o -type b -o -type c \) -print -quit 2>/dev/null)" || die "$nosearch"
  [[ -z "$bad" ]] || die "$(shown "$bad") is not a regular file or directory; refusing this repository"
  # Any .git below the top level is refused, whatever it is. git opens one
  # during checkout and status (where the remote has a submodule, say): a .git
  # file sends it to a directory named inside, a git directory's commondir to
  # another, and a ref there linked to /dev/zero exhausted memory (review of
  # fb1705e, Q3; security review of 8f5e5b9). Nothing this helper seeds makes
  # one: submodules are never initialised in a volume.
  # `reset` deletes them anyway, as untracked content, so it lists them for the
  # confirmation (inspect: NESTED records) and removes them before any git runs,
  # so git never reads one (bugs review REPO-5: initialised submodules, an
  # editable install's clone, a clone in an ignored directory blocked reset).
  # find follows no link, so one that is a link is removed as a link.
  case "$nested" in
    refuse)
      bad="$(find "$dir" -path "$gq" -prune -o -name .git -print -quit 2>/dev/null)" || die "$nosearch"
      [[ -z "$bad" ]] || die "$(shown "$bad") is a git repository inside the checkout; remove it (rm -rf from a container), or reset, which lists and removes it, then retry" ;;
    list)
      local -a found=(); local p n=0
      nested_in "$dir" found
      for p in ${found[@]+"${found[@]}"}; do
        n=$(( n + 1 ))
        (( n <= 50 )) && printf 'NESTED|%s\n' "$(shown "${p#"$dir/"}")"
      done
      (( n > 50 )) && printf 'NESTED-MORE|%s\n' "$(( n - 50 ))" ;;
    defer) NESTED_PENDING=1 ;;   # reset removes them itself, once it knows it will go ahead
  esac
}

# nested_in <dir> <array>: every .git below <dir>'s top level, link or not, into
# <array>. find follows no link, so a path through a linked directory is never
# one; the find's status is waited for, since a process substitution's is not
# seen (review of REPO-5).
nested_in() {
  local -n _ni_out="$2"
  local _ni_gq; glob_quoted "$1/.git" _ni_gq
  mapfile -d '' _ni_out < <(find "$1" -path "$_ni_gq" -prune -o -name .git -prune -print0 2>/dev/null)
  wait "$!" || die "cannot check $(shown "$1"): find could not search all of it (an unreadable directory, or a path too long); refusing this repository"
}

# remove_nested <dir>: reset's removal of the git repositories inside the
# checkout, right before the first git that uses the volume as a worktree, so
# none is ever read and none is removed by a reset that cannot go ahead (bugs
# review REPO-5). Each is named in a REMOVED record.
remove_nested() {
  local -a found=(); local p bad gq
  glob_quoted "$1/.git" gq
  nested_in "$1" found
  for p in ${found[@]+"${found[@]}"}; do
    rm -rf -- "$p" || die "could not remove $(shown "${p#"$1/"}"), a git repository inside the checkout"
    printf 'REMOVED|%s\n' "$(shown "${p#"$1/"}")"
  done
  bad="$(find "$1" -path "$gq" -prune -o -name .git -print -quit 2>/dev/null)" \
    || die "cannot check $(shown "$1"): find could not search all of it; refusing this repository"
  [[ -z "$bad" ]] || die "$(shown "$bad") is a git repository inside the checkout, and is still there after removing them; refusing"
  NESTED_PENDING=""
}

# fresh_clone: clone AI_REPO_URL, without a checkout, into a private directory;
# sets F. Fails with git's first error line on stderr's place, in CLONE_ERR.
# With no template (--template=): the clone's .git becomes the volume's, and a
# template brings sample hooks and, from git 2.34 and 2.43 at least, an empty
# legacy branches/ that reset is meant to leave no trace of (TST-10).
F="" CLONE_ERR=""
# Set by pull between its fast-forward and the removal of the old .git (die()).
UNDO_DIR="" UNDO_FROM="" UNDO_TO=""
# Set by check_volume's defer mode until remove_nested has run (reset).
NESTED_PENDING=""
fresh_clone() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-git.XXXXXX")" || die "cannot make a private directory"
  F="$WORK/clone"
  if ! git clone --quiet --no-checkout --template= -- "$AI_REPO_URL" "$F" 2>"$WORK/err"; then
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
    # These records are one per line, tab-separated: a file name holding either
    # split into records of its own, a fake BRANCH among them (REPO-10). Such a
    # name is shown with ? for them, its state unknown.
    if [[ "$name" == *[$'\n\t']* ]]; then name="${name//[$'\n\t']/?}"; oid='?'; fi
    seen[$name]=1
    printf '%s\t%s\n' "$name" "$oid"
  done < <(find "$gd/refs/$kind" -type f -print0 2>/dev/null)
  [[ -f "$gd/packed-refs" ]] || return 0
  while IFS=' ' read -r oid ref; do
    [[ "$ref" == "refs/$kind/"* ]] || continue
    name="${ref#"refs/$kind/"}"
    if [[ "$name" == *$'\t'* ]]; then name="${name//$'\t'/?}"; oid='?'; fi
    [[ -z "${seen[$name]:-}" ]] || continue
    seen[$name]=1
    [[ "$oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || oid='?'
    printf '%s\t%s\n' "$name" "$oid"
  done < <(cut -c1-4200 "$gd/packed-refs")
}
volume_branches() { volume_refs "$1" heads; }

# other_ref <dir>: the first ref outside refs/heads, refs/tags and refs/remotes
# (refs/wip/*, refs/original/*, a tool's keep refs), loose or packed — what
# replacing .git would drop with its commits (review of 82698a0, F1).
other_ref() {
  local gd="$1/.git" f oid ref rq
  glob_quoted "$gd/refs" rq
  f="$(find "$gd/refs" -mindepth 1 -type f ! -path "$rq/heads/*" ! -path "$rq/tags/*" \
    ! -path "$rq/remotes/*" -print -quit 2>/dev/null)"
  [[ -z "$f" ]] || { printf '%s' "${f#"$gd/"}"; return; }
  [[ -f "$gd/packed-refs" ]] || return 0
  while IFS=' ' read -r oid ref; do
    [[ "$oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && "$ref" == refs/* ]] || continue
    case "$ref" in refs/heads/*|refs/tags/*|refs/remotes/*) continue ;; esac
    printf '%s' "$ref"; return
  done < <(cut -c1-4200 "$gd/packed-refs")
}

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

# on_remote <oid>: 0 when the private clone keeps the commit — on a remote
# branch, or on a tag of the remote's, which the clone fetched (REPO-15: a tag
# on a commit only a remote tag reaches was reported lost); 1 when it does not;
# 2 when the clone cannot see the commit at all, so that is unknown: the
# volume's objects are not linked when it names alternates of its own.
# The commit-graph is off, as for the branch counts: in inspect the volume's
# objects are an alternate store, and git reads a commit-graph from there too,
# so one the agent wrote could make a local-only commit look kept (automated
# security review of REPO-15).
on_remote() {
  local -a cg=(-c core.commitGraph=false -c core.multiPackIndex=false)
  git -C "$F" "${cg[@]}" cat-file -e "$1^{commit}" 2>/dev/null || return 2
  [[ -n "$(git -C "$F" "${cg[@]}" for-each-ref --count=1 --contains "$1" --format=x refs/remotes/origin/ refs/tags/ 2>/dev/null)" ]]
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
  check_volume "$dir" list
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
        rev-list --count "$oid" --not --remotes=origin --tags 2>/dev/null)" || unpushed='?'
      [[ "$unpushed" =~ ^[0-9]+$ ]] || unpushed='?'
    fi
    flags=""; [[ "$name" == "$current" ]] && flags="current"
    printf 'BRANCH|%s|%s|%s\n' "$(shown "$name")" "$unpushed" "$flags"
  done < <(volume_branches "$dir")
  # What else replacing .git loses besides branches, for the confirmation (bugs
  # review REPO-8): the stash, with its entry count, and every local tag — kept
  # when the remote has it at the same object (the clone brings it back), and
  # whether the commit it marks is on a remote branch, since a tag can hold the
  # only reference to one.
  local gd="$dir/.git" n kept on theirs
  if [[ -e "$gd/refs/stash" || -e "$gd/logs/refs/stash" ]] || grep -qs ' refs/stash$' "$gd/packed-refs"; then
    n="$(grep -c . "$gd/logs/refs/stash" 2>/dev/null)" || n=""
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || n='?'
    printf 'STASH|%s\n' "$n"
  fi
  while IFS=$'\t' read -r name oid; do
    [[ -n "$name" ]] || continue
    kept='?'; on='?'
    # Unknown without a clone or an object name read from the tag: a failed git
    # call here would read as "no", and an empty oid matched a missing tag as
    # "kept". show-ref, not rev-parse: a name holding revision syntax (`v1:a`)
    # must name a ref, never resolve to an object.
    if [[ "$oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && [[ -n "$cloned" ]]; then
      theirs="$(git -C "$F" show-ref --verify -s "refs/tags/$name" 2>/dev/null)" || theirs=""
      if [[ "$theirs" == "$oid" ]]; then
        kept=yes; on=yes
      else
        # Only for a tag reset drops: a history walk per tag made a repo with a
        # thousand tags take half a minute to inspect (review of REPO-8). One
        # the remote has at another object is replaced by the remote's, not
        # simply dropped (REPO-15).
        kept=no; [[ -n "$theirs" ]] && kept=moved
        # The remote's names the same commit through another object (one tag
        # lightweight, the other annotated, or two annotations): the commit is
        # kept, only this tag's own object is not (review of REPO-15).
        if [[ "$kept" == moved ]]; then
          local mine_c theirs_c
          mine_c="$(git -C "$F" rev-parse -q --verify "$oid^{commit}" 2>/dev/null)" || mine_c=""
          theirs_c="$(git -C "$F" rev-parse -q --verify "refs/tags/$name^{commit}" 2>/dev/null)" || theirs_c=""
          [[ -n "$mine_c" && "$mine_c" == "$theirs_c" ]] && kept=same
        fi
        on_remote "$oid"
        case $? in 0) on=yes ;; 1) on=no ;; *) on='?' ;; esac
      fi
    fi
    printf 'TAG|%s|%s|%s\n' "$(shown "$name")" "$kept" "$on"
  done < <(volume_refs "$dir" tags)
  # Last, so a reader can tell a finished inspection from one cut short: repo.sh
  # reads these records through a process substitution and never sees this
  # script's exit status (REPO-16).
  printf 'END|inspect\n'
  return 0
}

# install_git_dir <dir>: the private clone's .git becomes the volume's — copied
# beside the old one first, so a copy that fails (a full disk) leaves the old
# .git in place rather than none (review of d9b56a8, P4).
install_git_dir() {
  local stage
  stage="$(mktemp -d "$1/.git-install.XXXXXX")" || die "could not stage the new .git"
  cp -a "$F/.git" "$stage/.git" || { rm -rf "$stage"; die "could not copy the new .git"; }
  # Past this point the old .git is not whole, so the fast-forward is not undone
  # (review of the REPO-6 fix): the worktree matches the new .git, which is kept
  # and named until it is in place.
  UNDO_DIR=""
  rm -rf "$1/.git" || die "could not remove all of the old .git; the new one, matching the checkout, is in $stage/.git — from a root container with the volume at $1, remove $1/.git, then: mv $stage/.git $1/.git ; then ./repo.sh sync"
  mv "$stage/.git" "$1/.git" || die "could not install the new .git, which matches the checkout — from a root container with the volume at $1: mv $stage/.git $1/.git ; then ./repo.sh sync"
  rmdir "$stage"
}

cmd_reset() {
  local dir="${1:-}" primary="${2:-}" owner="${3:-}"
  [[ -n "$dir" && -n "$primary" ]] || { usage >&2; die "reset needs a directory and a primary branch"; }
  [[ "$primary" != -* ]] && command git check-ref-format --branch "$primary" >/dev/null 2>&1 \
    || die "not a branch name: $primary"
  check_volume "$dir" defer
  local -a before=()
  local name oid
  while IFS=$'\t' read -r name oid; do [[ -n "$name" ]] && before+=("$name"); done < <(volume_branches "$dir")
  fresh_clone || die "cannot clone the recorded remote: ${CLONE_ERR}"
  git -C "$F" show-ref --verify --quiet "refs/remotes/origin/$primary" \
    || die "the remote has no branch named $primary"
  remove_nested "$dir"
  # The first git that uses the volume as a worktree: never while a deferred
  # removal has not run (a guard against an edit that drops the call).
  [[ -z "$NESTED_PENDING" ]] || die "the git repositories inside the checkout were not removed; refusing"
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
  # The readers cut each packed-refs line at 4200 bytes, so a longer one would be
  # read as another ref's name, and sync keeps refs by name (REPO-10). Only here:
  # in inspect and reset a cut name is only shown, and reset is the way out every
  # refusal below names. awk, not grep '^.\{4201\}': musl's regex allows no count
  # past 255, the pattern was an error there, and the check passed. Any status
  # but 0 refuses, a failed awk included.
  if [[ -f "$dir/.git/packed-refs" ]]; then
    local lrc=0
    LC_ALL=C awk 'length($0) > 4200 { exit 3 }' "$dir/.git/packed-refs" 2>/dev/null || lrc=$?
    case "$lrc" in
      0) ;;
      3) die "$(shown "$dir")'s packed-refs has a line longer than 4200 bytes; use reset" ;;
      *) die "cannot read $(shown "$dir")'s packed-refs; use reset" ;;
    esac
  fi
  local b; b="$(volume_head "$dir")"
  [[ -n "$b" ]] || die "the checkout is not on a branch (detached HEAD): nothing to fast-forward"
  local -A tip=()
  local name oid
  while IFS=$'\t' read -r name oid; do [[ -n "$name" ]] && tip[$name]="$oid"; done < <(volume_branches "$dir")
  [[ -n "${tip[$b]:-}" && "${tip[$b]}" != '?' ]] || die "cannot read the tip of $(shown "$b")"
  fresh_clone || die "cannot clone the recorded remote: ${CLONE_ERR}"
  git -C "$F" show-ref --verify --quiet "refs/remotes/origin/$b" || die "the remote has no branch named $(shown "$b")"
  # Nothing may be lost: every local branch is already on the remote, and the
  # checked-out one is behind (or at) the remote's tip of the same name.
  for name in "${!tip[@]}"; do
    [[ "${tip[$name]}" != '?' ]] && on_remote "${tip[$name]}" \
      || die "branch $(shown "$name") has commits on no remote branch or tag; push it, or use reset"
  done
  git -C "$F" merge-base --is-ancestor "${tip[$b]}" "refs/remotes/origin/$b" \
    || die "$(shown "$b") has diverged from the remote; push it, or use reset"
  # Nor anything else that lives only in .git, which is replaced (review of
  # d9b56a8, P1): a stash, notes, linked worktrees, a tag on no remote.
  local gd="$dir/.git"
  [[ ! -e "$gd/refs/stash" && ! -e "$gd/logs/refs/stash" ]] && ! grep -qs ' refs/stash$' "$gd/packed-refs" \
    || die "the repository has a stash; apply or drop it, or use reset"
  [[ -z "$(volume_refs "$dir" notes)" ]] || die "the repository has git notes; push or remove them, or use reset"
  # An operation stopped halfway lives only in .git: a stopped `git am` lost the
  # patches only rebase-apply/ held, which `git pull --ff-only` keeps (bugs review
  # REPO-2).
  local op
  for op in rebase-apply rebase-merge sequencer MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_START; do
    [[ ! -e "$gd/$op" && ! -L "$gd/$op" ]] \
      || die "an operation is in progress ($op in .git): finish or abort it, or use reset"
  done
  [[ -z "$(find "$gd/worktrees" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
    || die "the repository has linked worktrees; remove them (git worktree remove), or use reset"
  local other; other="$(other_ref "$dir")"
  [[ -z "$other" ]] || die "$(shown "$other") holds commits sync would drop with .git; delete it, or use reset"
  local tname toid
  while IFS=$'\t' read -r tname toid; do
    [[ -n "$tname" ]] || continue
    [[ "$toid" != '?' ]] && git -C "$F" cat-file -e "$toid" 2>/dev/null \
      || die "tag $(shown "$tname") is on no remote; push it, or use reset"
  done < <(volume_refs "$dir" tags)
  mark_safe_directory "$dir"
  # The worktree must match its branch's commit: compared by the clone's git,
  # with its own config, against the volume's files.
  git --git-dir="$F/.git" --work-tree="$dir" read-tree "${tip[$b]}" || die "could not read $(shown "$b")"
  git --git-dir="$F/.git" --work-tree="$dir" update-index -q --ignore-submodules --refresh >/dev/null 2>&1 || true
  git --git-dir="$F/.git" --work-tree="$dir" diff-files --ignore-submodules=all --quiet \
    || die "the checkout has uncommitted changes; commit and push them, or use reset"
  # --ignore-submodules=all also hides a submodule's path turned into a link or
  # a file, which sync then kept (REPO-10): the branch's submodules must still
  # be directories in the checkout, or absent.
  local rec p
  while IFS= read -r -d '' rec; do
    [[ "$rec" == "160000 "* ]] || continue
    p="${rec#*$'\t'}"
    [[ ( -d "$dir/$p" && ! -L "$dir/$p" ) || ( ! -e "$dir/$p" && ! -L "$dir/$p" ) ]] \
      || die "$(shown "$p") is a submodule in $(shown "$b") but not a directory in the checkout; restore it, or use reset"
  done < <(git -C "$F" ls-tree -r -z "${tip[$b]}")
  # What is staged lives in the volume's index alone, which the clone's fresh
  # one cannot see (a change staged, then undone in the file). A copy is read
  # against the tip by the clone's git; an index it cannot read is refused
  # (review of 82698a0, F1).
  if [[ -e "$gd/index" ]]; then
    # Bounded: the agent writes this file, and it is copied (REPO-10). A real
    # index of 400,000 files is about 50 MiB.
    # k, not M: busybox find has no M suffix, and the error read as "small
    # enough" (review of REPO-10). A find that fails refuses.
    local big
    big="$(find "$gd/index" -size +524288k -print -quit 2>/dev/null)" \
      || die "cannot check the size of the checkout's index; use reset"
    [[ -z "$big" ]] || die "the checkout's index is larger than 512 MiB; refusing to read it (use reset)"
    cp "$gd/index" "$WORK/volume-index" || die "cannot read the checkout's index"
    # Its ENTRIES, into a fresh index: diff-index trusts an index's cache-tree
    # extension, so a hand-crafted one could hide staged entries (REPO-10). A
    # fresh index has none, and --index-info needs no object the clone lacks.
    # git's errors are kept to their last 4 KiB: it prints a line for each
    # extension it ignores, which an index the agent wrote makes about three
    # times its size (review of the REPO-3 fix).
    local ierr shared="" isz
    if ! ierr="$( { LC_ALL=C GIT_INDEX_FILE="$WORK/volume-index" git --git-dir="$F/.git" ls-files -s -z \
        > "$WORK/index-entries"; } 2>&1 | tail -c 4096)"; then
      # A split index (core.splitIndex) keeps most of its entries in the
      # sharedindex.<oid> it names, in .git beside it, and git also looks for
      # that file beside the index it reads: copied there, the copy reads whole
      # (bugs review REPO-3; "use reset" wiped far more than a sync). The name is
      # the one git could not open; only a regular file of that name in .git is
      # copied, the two together bounded as the index alone was, and git checks
      # only that its trailing checksum is the one named.
      if [[ "$ierr" == */sharedindex.* ]]; then shared="${ierr##*/sharedindex.}"; shared="${shared%%[!0-9a-f]*}"; fi
      [[ ${#shared} == 40 || ${#shared} == 64 ]] || die "cannot read the checkout's index (sparse or damaged); use reset"
      shared="sharedindex.$shared"
      [[ -f "$gd/$shared" && ! -L "$gd/$shared" ]] \
        || die "the checkout's index is split (core.splitIndex), and its $shared is missing or not a file; use reset"
      isz="$(wc -c < "$WORK/volume-index")" || die "cannot check the size of the checkout's index; use reset"
      big="$(find "$gd/$shared" -size +$(( 524288 - (isz + 1023) / 1024 ))k -print -quit 2>/dev/null)" \
        || die "cannot check the size of the checkout's $shared; use reset"
      [[ -z "$big" ]] || die "the checkout's index and its $shared are larger than 512 MiB together; refusing to read them (use reset)"
      cp "$gd/$shared" "$WORK/$shared" || die "cannot read the checkout's $shared"
      GIT_INDEX_FILE="$WORK/volume-index" git --git-dir="$F/.git" ls-files -s -z > "$WORK/index-entries" 2>/dev/null \
        || die "cannot read the checkout's split index (damaged); use reset"
    fi
    GIT_INDEX_FILE="$WORK/fresh-index" git --git-dir="$F/.git" update-index -z --index-info < "$WORK/index-entries" 2>/dev/null \
      || die "cannot read the checkout's index (damaged); use reset"
    local raw empty staged
    raw="$(GIT_INDEX_FILE="$WORK/fresh-index" git --git-dir="$F/.git" diff-index --cached --raw --no-abbrev \
      --ignore-submodules=all "${tip[$b]}" 2>/dev/null)" || die "cannot compare the checkout's index with $(shown "$b"); use reset"
    empty="$(git --git-dir="$F/.git" hash-object -t blob --stdin < /dev/null)"
    # An added entry of the empty blob is what `git add -N` (intent to add)
    # stages: nothing would be lost, and it was refused (REPO-10). An unmerged
    # entry is an operation stopped halfway, named as such.
    staged="$(awk -F'\t' -v e="$empty" '
      $0 == "" { next }
      { n = split($1, m, " "); st = m[n]
        if (st == "A" && m[4] == e) next
        if (st == "U") { print "unmerged"; exit }
        print "staged"; exit }' <<<"$raw")"
    case "$staged" in
      unmerged) die "the checkout's index has unmerged entries (a merge or rebase stopped halfway); finish or abort it, or use reset" ;;
      staged)   die "the checkout has staged changes; commit and push them, or use reset" ;;
    esac
  fi
  # What the fast-forward replaces must hold nothing but what the branch tracks.
  # read-tree refuses to overwrite an untracked file, but it replaced an IGNORED
  # one in silence, as `git pull --ff-only` does, and it deleted whatever a
  # submodule's directory held when the remote turned that path, or a directory
  # above it, into something else (REPO-10 and its reviews). Each path the
  # remote adds or retypes is walked from the top, following no link:
  #  - a parent that is a link or not a directory ends the walk: in the way
  #    unless the branch tracks it as a file or a link, which git replaces
  #    cleanly (a tracked compatibility link a rename moves over); a submodule's
  #    path that is not a directory was refused above;
  #  - the path itself: absent, or a directory of nothing but directories, is
  #    fine; a former submodule's directory must hold no file; a path the branch
  #    tracks as a tree, unless it is a directory becoming a submodule (git keeps
  #    its files then), must hold no untracked or ignored file, and no submodule
  #    of the branch's under it any file; anything else is in the way.
  # Every git and find below fails closed: a failure read as "nothing there"
  # would let read-tree delete what it found (review of REPO-10, L-2).
  git -C "$F" diff-tree -r -z --raw --no-renames "${tip[$b]}" "refs/remotes/origin/$b" > "$WORK/changes" \
    || die "cannot list what the remote changes in $(shown "$b"); use reset"
  local meta st srcmode dstmode c rest ttype found sub sm
  while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
    st="${meta##* }"; srcmode="${meta%% *}"; srcmode="${srcmode#:}"
    dstmode="${meta#* }"; dstmode="${dstmode%% *}"
    [[ "$st" == A || "$st" == T ]] || continue
    c=""; rest="$p"
    while [[ "$rest" == */* ]]; do
      c="${c:+$c/}${rest%%/*}"; rest="${rest#*/}"
      [[ -d "$dir/$c" && ! -L "$dir/$c" ]] && continue
      if [[ -e "$dir/$c" || -L "$dir/$c" ]]; then
        ttype="$(git -C "$F" cat-file -t "${tip[$b]}:$c" 2>/dev/null)" || ttype=""
        [[ -n "$ttype" && "$ttype" != tree ]] \
          || die "$(shown "$c") is in the checkout, untracked or ignored, where the remote now has a directory; move it aside, or use reset"
      fi
      continue 2
    done
    [[ -e "$dir/$p" || -L "$dir/$p" ]] || continue
    # A directory holding nothing but directories (empty ones included) is no
    # obstacle: there is nothing in it to lose (review of REPO-10, L-3).
    if [[ -d "$dir/$p" && ! -L "$dir/$p" ]]; then
      found="$(find "$dir/$p" -mindepth 1 ! -type d -print -quit 2>/dev/null)" \
        || die "cannot search $(shown "$p") in the checkout; use reset"
    else
      found=x
    fi
    if [[ "$srcmode" == 160000 ]]; then
      [[ -z "$found" ]] \
        || die "$(shown "$p") is a submodule's directory holding files, and the remote turns it into something else; move them aside, or use reset"
      continue
    fi
    [[ "$st" == T ]] && continue                        # a file or link the branch tracks, clean
    [[ -n "$found" ]] || continue
    ttype="$(git -C "$F" cat-file -t "${tip[$b]}:$p" 2>/dev/null)" || ttype=""
    if [[ "$ttype" == tree ]]; then
      # git keeps a DIRECTORY's files when the path becomes a submodule; an
      # ignored file or link standing there instead is replaced (third review).
      [[ "$dstmode" == 160000 && -d "$dir/$p" && ! -L "$dir/$p" ]] && continue
      # No -z: only emptiness is tested, and a NUL in $( ) is a bash warning.
      found="$(GIT_LITERAL_PATHSPECS=1 git --git-dir="$F/.git" --work-tree="$dir" ls-files -o -- "$p" 2>/dev/null)" \
        || die "cannot list the untracked files in $(shown "$p"); use reset"
      [[ -z "$found" ]] \
        || die "$(shown "$p") holds untracked or ignored files, and the remote turns that directory into something else; move them aside, or use reset"
      # ls-files -o never looks inside a submodule's directory, and read-tree
      # deletes it with the directory above (review of REPO-10, M-1).
      GIT_LITERAL_PATHSPECS=1 git -C "$F" ls-tree -r -z "${tip[$b]}" -- "$p/" > "$WORK/subs" \
        || die "cannot list the submodules in $(shown "$p"); use reset"
      while IFS= read -r -d '' sm; do
        [[ "$sm" == "160000 "* ]] || continue
        sub="${sm#*$'\t'}"
        [[ -e "$dir/$sub" || -L "$dir/$sub" ]] || continue
        found=x
        if [[ -d "$dir/$sub" && ! -L "$dir/$sub" ]]; then
          found="$(find "$dir/$sub" -mindepth 1 ! -type d -print -quit 2>/dev/null)" \
            || die "cannot search $(shown "$sub") in the checkout; use reset"
        fi
        [[ -z "$found" ]] \
          || die "$(shown "$sub") is a submodule's directory holding files, and the remote turns $(shown "$p") into something else; move them aside, or use reset"
      done < "$WORK/subs"
      continue
    fi
    die "$(shown "$p") is in the checkout, untracked or ignored, and the remote now tracks it; move it aside, or use reset"
  done < "$WORK/changes"
  # A two-way merge from that commit to the remote's tip, as `pull --ff-only`
  # does, without --force: it refuses to overwrite an untracked file the remote
  # now tracks, and leaves every other untracked file alone.
  git --git-dir="$F/.git" --work-tree="$dir" read-tree -m -u "${tip[$b]}" "refs/remotes/origin/$b" \
    || die "could not fast-forward $(shown "$b") without overwriting files in the checkout (an untracked file the remote now tracks?)"
  # From here a failure undoes the fast-forward (die), until install_git_dir
  # starts removing the old .git.
  UNDO_FROM="$(git -C "$F" rev-parse "refs/remotes/origin/$b")" UNDO_TO="${tip[$b]}" UNDO_DIR="$dir"
  git -C "$F" update-ref "refs/heads/$b" "refs/remotes/origin/$b" || die "could not move $(shown "$b")"
  git -C "$F" symbolic-ref HEAD "refs/heads/$b" || die "could not check out $(shown "$b")"
  git -C "$F" branch --quiet --set-upstream-to="origin/$b" "$b" >/dev/null 2>&1 || true
  for name in "${!tip[@]}"; do
    [[ "$name" == "$b" ]] && continue
    command git check-ref-format "refs/heads/$name" >/dev/null 2>&1 \
      || { printf 'WARN|could not keep branch %s (not a valid name)\n' "$(shown "$name")"; continue; }
    git -C "$F" update-ref "refs/heads/$name" "${tip[$name]}" || { printf 'WARN|could not keep branch %s\n' "$(shown "$name")"; continue; }
    # Only the checked-out branch was re-tracked; every other one lost its
    # upstream (bugs review REPO-9). One with a same-named branch on origin
    # tracks it again; other remotes stay a documented loss (their URLs are
    # config the agent wrote).
    # Only where the branch is behind or at it: one that diverged from its
    # namesake (merged elsewhere, then force-pushed) would report "diverged".
    if git -C "$F" show-ref --verify -q "refs/remotes/origin/$name" \
       && git -C "$F" merge-base --is-ancestor "${tip[$name]}" "refs/remotes/origin/$name"; then
      git -C "$F" branch --quiet --set-upstream-to="origin/$name" "$name" >/dev/null 2>&1 || true
    fi
  done
  # Every local tag comes back at the value it had — the refusal above made sure
  # its object is in the clone — as `pull --ff-only` would have left it (review
  # of fb1705e, Q1).
  while IFS=$'\t' read -r tname toid; do
    [[ -n "$tname" ]] || continue
    command git check-ref-format "refs/tags/$tname" >/dev/null 2>&1 \
      || { printf 'WARN|could not keep tag %s (not a valid name)\n' "$(shown "$tname")"; continue; }
    git -C "$F" update-ref "refs/tags/$tname" "$toid" || printf 'WARN|could not keep tag %s\n' "$(shown "$tname")"
  done < <(volume_refs "$dir" tags)
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
