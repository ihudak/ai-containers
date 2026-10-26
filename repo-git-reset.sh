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
  repo-git-reset.sh pull    <dir> [<uid>:<gid>]

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

# This runs as ROOT in the seed container, with the host's ~/.ssh keys and an
# open network, on a .git the agent can write through any :rw repo volume (the
# launcher's git-internals overlay covers host binds, not volumes). So nothing
# that .git holds may run: every git here goes through this wrapper — hooks
# pointed at nowhere, fsmonitor off, only network transports (and file, for a
# local remote) — and guard_repo cuts the config to what a fetch and a checkout
# need before any git touches it.
export GIT_ALLOW_PROTOCOL="ssh:https:http:git:file"
# Replace refs and grafts let the agent swap in its own content under a real
# commit's id (re-review of the batch 2 fixes, G2).
# The graft file is a path that never exists: an existing one, even /dev/null,
# makes git print a deprecation hint into every fetch error (re-review, H4).
export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/nonexistent/ai-containers-no-grafts
# No submodule recursion either: a submodule's config under .git/modules is not
# rewritten, and fetch recurses "on demand" by default.
# The remote is pinned on the command line too, which outranks every file in
# .git: with config deleted, git would otherwise read a legacy .git/remotes or
# .git/branches entry for origin (re-review of b86cfe6).
git() {
  command git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c fetch.recurseSubmodules=false -c submodule.recurse=false -c core.useReplaceRefs=false \
    ${AI_REPO_URL:+-c "remote.origin.url=$AI_REPO_URL"} \
    ${AI_REPO_URL:+-c "remote.origin.fetch=+refs/heads/*:refs/remotes/origin/*"} "$@"
}

# guard_repo <dir>: refuse a .git that is not a plain directory, or that holds
# anything but files and directories (a FIFO or device hangs git; a symlink can
# lead anywhere); drop commondir and config.worktree, which send git to config
# of the agent's choosing; and rewrite config to the keys below — with no
# include, filter, alias, hook path, fsmonitor, ssh command or uploadpack left
# in it to run.
guard_repo() {
  local dir="$1" gd="$1/.git" bad k v tmp
  # The one remote is the URL repo.sh recorded when it registered the repo (the
  # volume's own label), never what the .git names: the agent could point origin
  # at any repository your SSH key reads, and fetch it into a volume it reads.
  [[ -n "${AI_REPO_URL:-}" ]] || die "no recorded URL for this repository (AI_REPO_URL); refusing to run git on it"
  [[ -d "$gd" && ! -L "$gd" ]] || die "$gd is not a directory (a .git file or link can point anywhere)"
  bad="$(find "$gd" ! -type f ! -type d -print -quit 2>/dev/null)"
  [[ -z "$bad" ]] || die "$bad is not a regular file or directory; refusing to run git on this repository"
  # The worktree is read too (.gitattributes on checkout): a FIFO or device
  # anywhere in it would hang git. A socket does not, and clean removes it;
  # links are a checkout's business (re-review, H5).
  bad="$(find "$dir" -path "$gd" -prune -o \( -type p -o -type b -o -type c \) -print -quit 2>/dev/null)"
  [[ -z "$bad" ]] || die "$bad is not a regular file or directory; refusing to run git on this repository"
  # Gone, not just cleaned: commondir and config.worktree send git to config of
  # the agent's choosing, remotes/ and branches/ name remotes, and alternates can
  # chain into the worktree, where a FIFO hangs git — a fresh clone has none.
  rm -rf "$gd/commondir" "$gd/config.worktree" "$gd/remotes" "$gd/branches" \
         "$gd/objects/info/alternates" "$gd/objects/info/http-alternates" "$gd/info/grafts"
  [[ ! -e "$gd/config" || -f "$gd/config" ]] || die "$gd/config is not a regular file"
  [[ -e "$gd/config" ]] || : > "$gd/config"
  tmp="$gd/config.sanitised.$$"
  : > "$tmp" || die "cannot write $tmp"
  while IFS= read -r -d '' k; do
    v="${k#*$'\n'}"; k="${k%%$'\n'*}"
    case "$k" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|\
      core.ignorecase|core.precomposeunicode|core.symlinks|extensions.objectformat|branch.*.merge)
        command git config --file "$tmp" --add "$k" "$v" || die "cannot rewrite $gd/config" ;;
      branch.*.remote)
        [[ "$v" == origin ]] && { command git config --file "$tmp" --add "$k" "$v" || die "cannot rewrite $gd/config"; } ;;
    esac
  done < <(command git config --file "$gd/config" --null --list 2>/dev/null)
  command git config --file "$tmp" remote.origin.url "$AI_REPO_URL" || die "cannot rewrite $gd/config"
  command git config --file "$tmp" remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' || die "cannot rewrite $gd/config"
  mv -f "$tmp" "$gd/config" || die "cannot replace $gd/config"
  # Trusted for the root that runs here, then the replace refs go — through the
  # guarded wrapper, since deleting a ref runs the reference-transaction hook,
  # and only after safe.directory, without which git refuses a volume another
  # uid owns and nothing is deleted (re-review of 61f7806, H1/H2).
  mark_safe_directory "$dir"
  local r
  while IFS= read -r r; do
    [[ -n "$r" ]] && git -C "$dir" update-ref -d "$r" >/dev/null 2>&1
  done < <(git -C "$dir" for-each-ref --format='%(refname)' refs/replace/ 2>/dev/null)
}

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
  [[ -e "$dir/.git" ]] || die "not a git repository: $dir"
  guard_repo "$dir"
  # refs/remotes/origin is the agent's to write. A fetch overwrites it with the
  # remote's tips; without one, no count made against it is trusted.
  local fetched=1
  mark_safe_directory "$dir"

  # A symbolic ref under refs/remotes/origin survives fetch --prune, and one the
  # agent pointed at its own branch makes unpushed work count as pushed
  # (security review of cbf90aa). Every symbolic ref there goes, but origin/HEAD
  # pointing inside refs/remotes/origin — what set-head -a writes. Plain
  # remote-tracking refs stay: the fetch overwrites them, and without one they
  # still name the primary branch while the counts are reported unknown.
  local r t
  while IFS=$'\t' read -r r t; do
    [[ -n "$t" ]] || continue
    [[ "$r" == refs/remotes/origin/HEAD && "$t" == refs/remotes/origin/* && "$t" != refs/remotes/origin/HEAD ]] && continue
    git -C "$dir" update-ref --no-deref -d "$r" >/dev/null 2>&1
  done < <(git -C "$dir" for-each-ref --format='%(refname)%09%(symref)' refs/remotes/origin/ 2>/dev/null)
  if have_origin "$dir"; then
    local err
    if ! err="$(git -C "$dir" fetch --prune origin 2>&1)"; then
      fetched=""
      # One line, and the first one: a multi-line git error would corrupt the
      # record-per-line contract this output is parsed under.
      printf 'STALE|%s\n' "$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"
    fi
  else
    printf 'STALE|no "origin" remote — nothing to fetch from\n'
    fetched=""
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
    # Branch names are refnames the agent can write: git gets the full refname,
    # so one spelled like an option (--output=…) is never parsed as one, and a |
    # is shown as ? so it cannot split these records (re-review of b86cfe6).
    # Against origin only: refs under another remote's name are the agent's to
    # plant. A count that fails is `?`, never 0 (re-review, G3/G4).
    unpushed="$(git -C "$dir" rev-list --count "refs/heads/$b" --not --remotes=origin 2>/dev/null)" || unpushed='?'
    [[ "$unpushed" =~ ^[0-9]+$ && -n "$fetched" ]] || unpushed='?'
    flags=""
    [[ "$b" == "$current" ]] && flags="current"
    printf 'BRANCH|%s|%s|%s\n' "${b//|/?}" "$unpushed" "$flags"
  done < <(git -C "$dir" for-each-ref --format='%(refname:lstrip=2)' refs/heads/ 2>/dev/null)
}

cmd_reset() {
  local dir="${1:-}" primary="${2:-}" owner="${3:-}"
  [[ -n "$dir" && -n "$primary" ]] || { usage >&2; die "reset needs a directory and a primary branch"; }
  [[ "$primary" != -* ]] || die "refusing a primary branch named like an option: $primary"
  [[ -e "$dir/.git" ]] || die "not a git repository: $dir"
  guard_repo "$dir"
  mark_safe_directory "$dir"

  # Where the primary branch should end up. With a remote-tracking ref, that is
  # the remote's tip; without one (no remote, or a purely local repo) the branch
  # keeps its own tip — reset still cleans the tree and drops the other
  # branches, it just has nothing newer to move to.
  # Full refnames throughout: a short `origin/main` resolves to a tag or a
  # branch of that name before the remote-tracking ref, and the agent can make
  # either (re-review of the batch 2 fixes, G1).
  local target=""
  if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$primary"; then
    target="refs/remotes/origin/$primary"
  elif git -C "$dir" show-ref --verify --quiet "refs/heads/$primary"; then
    target="refs/heads/$primary"
  else
    die "no local or remote branch named $primary"
  fi
  git -C "$dir" checkout --force -B "$primary" "$target" >/dev/null 2>&1 \
    || die "could not check out $primary at $target"

  git -C "$dir" reset --hard "$target" >/dev/null 2>&1 || die "could not reset to $target"
  git -C "$dir" clean -ffdx >/dev/null 2>&1 || die "could not clean the working tree"

  # Every other local branch. `-D`, not `-d`: an unmerged branch is exactly what
  # the caller has already been shown and has confirmed.
  local b deleted=0
  while IFS= read -r b; do
    [[ -n "$b" && "$b" != "$primary" ]] || continue
    if git -C "$dir" update-ref -d "refs/heads/$b" >/dev/null 2>&1; then
      printf 'DELETED|%s\n' "${b//|/?}"; deleted=$(( deleted + 1 ))
    else
      printf 'KEPT|%s|could not delete\n' "${b//|/?}"
    fi
  done < <(git -C "$dir" for-each-ref --format='%(refname:lstrip=2)' refs/heads/ 2>/dev/null)

  printf 'ON|%s\n' "$primary"
  printf 'AT|%s\n' "$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
  printf 'DELETED-COUNT|%s\n' "$deleted"

  [[ -n "$owner" ]] && { chown -R "$owner" "$dir" || printf 'WARN|chown failed\n'; }
  return 0
}

# pull: the fast-forward `repo.sh sync` runs, through the same guard.
cmd_pull() {
  local dir="${1:-}" owner="${2:-}"
  [[ -n "$dir" ]] || { usage >&2; die "pull needs a directory"; }
  [[ -e "$dir/.git" ]] || die "not a git repository: $dir"
  guard_repo "$dir"
  mark_safe_directory "$dir"
  git -C "$dir" pull --ff-only --no-recurse-submodules origin || die "pull --ff-only failed"
  if [[ -n "$owner" ]]; then chown -R "$owner" "$dir" || printf 'WARN|chown failed\n'; fi
  printf 'AT|%s\n' "$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
}

case "${1:-}" in
  inspect) shift; cmd_inspect "$@" ;;
  reset)   shift; cmd_reset   "$@" ;;
  pull)    shift; cmd_pull    "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
