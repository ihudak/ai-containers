#!/usr/bin/env bash
# project-files.sh — how project-init.sh and sync-to-projects.sh touch files in a
# project: sourced by both, never run. A base-repo file like those two, so not
# in AI_CONTAINERS_SHARED_FILES; a project's copy has no use for it.
#
# One definition, two callers: ensure_ai_containers_ignored was kept as two
# copies a test compared, and both wrote the project's .gitignore by path.

# ── Project files: read once, write by rename ─────────────────────────────────
# The project root is the agent's to write, and so is its .ai-containers/ when
# that directory is itself a writable mount root (the launch allows it with a
# NOTE); the agent has your UID. So sync never opens a file there by path twice,
# never writes one by path, and never follows a link there (bugs review PRJ-10,
# and GAP-6's reviews for runme.sh): _proj_read opens a file once, checks that
# open is the regular file the path names, and copies it (bounded) to a private
# directory outside the project; everything is decided and built from that copy,
# and _proj_write creates a fresh name beside the file in one exclusive open,
# fills it through that open, and renames it over the file (a link there is
# replaced, not followed). Execute bits are set through that open too
# (/dev/fd/N); only where chmod cannot use it (not Linux) is the name re-checked
# and used, and that can add execute bits, never read or write ones.
# Not covered: a file swapped for a FIFO between the check and the open blocks
# the sync (bash cannot open without blocking).

# _proj_read FILE OUT [MAX] — copy FILE to OUT through one open; set
# _proj_perms to its rwx string. 0, or 1 (not a regular file, a link, the
# open is not the path's file, unreadable), or 2 (over MAX bytes, default 64 KiB).
_proj_perms=""

# _proj_fd_is PATH FD — 0 when PATH names the file open on FD. Linux's
# /dev/fd/N is a link into /proc, so -ef compares the file itself. macOS's is
# a node of fdescfs, whose stat carries fdescfs's device and only the inode of
# the open file, so -ef never matched there and every project was refused; there
# the inode is compared alone. A file swapped in on the same filesystem has
# another inode, and its inode is not the swapper's to pick.
_proj_fd_is() {
  local fd="/dev/fd/$2" a b
  [[ "$1" -ef "$fd" ]] && return 0
  [[ -L "$fd" ]] && return 1
  read -r a _ < <(ls -di "$1" 2>/dev/null) || return 1
  read -r b _ < <(ls -di "$fd" 2>/dev/null) || return 1
  [[ -n "$a" && "$a" == "$b" ]]
}

# _proj_fd_perms PATH FD — the rwx string of the file open on FD, which PATH
# names. fdescfs reports the descriptor's open mode (r--r--r-- for a read), not
# the file's, so off Linux the mode is read by name and the name checked again.
_proj_fd_perms() {
  local p
  if [[ -L "/dev/fd/$2" ]]; then
    ls -lnL "/dev/fd/$2" 2>/dev/null | cut -c2-10
    return
  fi
  p="$(ls -ln "$1" 2>/dev/null | cut -c2-10)" || return 1
  [[ ! -L "$1" ]] && _proj_fd_is "$1" "$2" && printf '%s\n' "$p"
}

_proj_read() {
  local f="$1" out="$2" max="${3:-65536}" fd size
  [[ -f "$f" && ! -L "$f" ]] || return 1
  # Braced: on a bare exec the 2>/dev/null would stay on the shell, and every
  # later error of the sync would vanish.
  { exec {fd}<"$f"; } 2>/dev/null || return 1
  if [[ ! -L "$f" && -f "/dev/fd/$fd" ]] && _proj_fd_is "$f" "$fd" \
     && head -c "$(( max + 1 ))" <&"$fd" > "$out" \
     && _proj_perms="$(_proj_fd_perms "$f" "$fd")" \
     && [[ "$_proj_perms" == [r-][w-]?[r-][w-]?[r-][w-]? ]]; then
    exec {fd}<&-
  else
    exec {fd}<&-; return 1
  fi
  size="$(wc -c < "$out" | tr -d ' ')"
  (( size <= max )) || return 2
  return 0
}

# _proj_write SRC FILE PERMS — put SRC's bytes at FILE with PERMS (rwx string).
_proj_write() {
  local src="$1" f="$2" p="$3" t um=0 x="" c i
  if ! _proj_dest_same; then
    printf 'ERROR: %s is no longer the directory this run started in (renamed, or replaced by a link); not writing %s\n' "$_proj_dest" "$f" >&2
    return 1
  fi
  t="$(mktemp -u "$(dirname "$f")/.$(basename "$f").XXXXXX")" || return 1
  # Read and write bits through the umask of the create; execute bits after.
  for (( i = 0; i < 9; i++ )); do
    c="${p:i:1}"
    case "$i" in
      0|3|6) [[ "$c" == r ]] || um=$(( um | (0400 >> i) )) ;;
      1|4|7) [[ "$c" == w ]] || um=$(( um | (0400 >> i) )) ;;
      *)     [[ "$c" == [xst] ]] && x+="${x:+,}$(printf '%s' ugo | cut -c$(( i / 3 + 1 )))+x" ;;
    esac
  done
  # noclobber: O_EXCL on a name that does not exist, so a file or a link put
  # there meanwhile fails the create. An existing FIFO or device (or a link to
  # one) is opened without O_EXCL — bash allows that — but the name is a
  # mktemp -u one nothing else knows, and such a target fails the checks below
  # and is never renamed in. The open is kept: bytes and execute bits go through it.
  local w="" ok=1 old_umask had_c=""
  old_umask="$(umask)"; [[ "$-" == *C* ]] && had_c=1
  umask "$(printf '%o' "$um")"; set -C
  { exec {w}>"$t"; } 2>/dev/null || ok=0
  umask "$old_umask"; [[ -n "$had_c" ]] || set +C
  (( ok )) || return 1
  if [[ -L "$t" || ! -f "$t" ]] || ! _proj_fd_is "$t" "$w" || ! cat "$src" >&"$w"; then ok=0
  # /dev/fd/N is the opened file on Linux whatever the name now is; where chmod
  # cannot go through it, the name is checked to still be that file first.
  # Only a link is gone through: chmod on macOS's fdescfs node reckons u+x from
  # the descriptor's mode (-w------- for this write) and sets the file to that.
  elif [[ -n "$x" ]] && ! { [[ -L "/dev/fd/$w" ]] && chmod "$x" "/dev/fd/$w" 2>/dev/null; } \
       && ! { [[ ! -L "$t" ]] && _proj_fd_is "$t" "$w" && chmod "$x" "$t" 2>/dev/null; }; then ok=0
  fi
  exec {w}>&-
  if (( ok )) && _proj_replace "$t" "$f"; then return 0; fi
  [[ -f "$t" && ! -L "$t" ]] && rm -f "$t"
  return 1
}

# _proj_replace TMP FILE — rename TMP over FILE without following FILE if
# it has become a link meanwhile. A plain `mv` moves INTO a directory a link
# there points at; GNU's -T and BSD's -h replace the link itself instead.
_proj_replace() {
  mv -T -f "$1" "$2" 2>/dev/null && return 0
  # BSD mv -h replaces a link, but moves INTO a real directory and succeeds,
  # where GNU's -T refuses; a directory planted there is a failed write.
  [[ -d "$2" && ! -L "$2" ]] && return 1
  mv -h -f "$1" "$2" 2>/dev/null
}

# _perms_of FILE — FILE's rwx string (a file of this engine's, not a project's).
_perms_of() { ls -lnL "$1" 2>/dev/null | cut -c2-10; }

# _perms_new — the rwx string a new file gets under the current umask.
_perms_new() {
  local m i out="" bits=rwxrwxrwx
  m=$(( 0666 & ~$(umask) ))
  for (( i = 0; i < 9; i++ )); do
    if (( m & (0400 >> i) )); then out+="${bits:i:1}"; else out+=-; fi
  done
  printf '%s' "$out"
}

# _proj_note_skip FILE WHAT — say FILE was left alone because it is a link,
# not a regular file, or over _proj_read's bound, so WHAT did not happen.
_proj_note_skip() {
  printf '  NOTE: %s is a link, not a regular file, or too large to read, so %s: %s\n' "$(basename "$1")" "$2" "$1"
}

# Ensure the project's root .gitignore ignores its .ai-containers/ working copy.
# The per-project .ai-containers/ is a synced copy of the central repo and the
# launcher embeds machine-specific absolute paths (EXTRA_MOUNTS), so it should
# not be committed to the project. A project that already TRACKS .ai-containers/
# (any file under it in the git index) is left untouched — no ignore rule is added,
# so a deliberately version-controlled working copy keeps working with no override.
# Idempotent, git-repos only; to keep an untracked copy under version control
# instead, remove the added line. AI_CONTAINERS_NO_GITIGNORE=1 skips this entirely.
#   git is asked nothing about the project's repository (bugs review GIT-29): its
# config can include a file the agent writes, whose core.fsmonitor check-ignore
# and ls-files ran on every sync, a FIFO index hung every sync, and on a Mac
# without the Command Line Tools they opened the installer. So the work tree is
# a .git at the project's root (a project nested in an enclosing repository, a
# monorepo directory, has none of its own and gets no line; a .git that is a
# link is not followed); "already ignored" is a line of the root .gitignore, of
# info/exclude or of your global excludes file, as written here or plainly
# spelled (a broader pattern that covers it gets the line once more); and
# "tracked" is the index read with no repository, bounded, and only where git
# runs (_proj_index_tracks). Where that cannot be known, no line is added and a
# NOTE says why: the inner .ai-containers/.gitignore already keeps
# sandbox.local.env out.
ensure_ai_containers_ignored() {
  local project_path="$1" gd="" cdir="" rc name
  [[ "${AI_CONTAINERS_NO_GITIGNORE:-0}" == "1" ]] && return 0
  name="$(basename "$project_path")"
  if [[ -L "$project_path/.git" ]]; then
    _proj_gi_note "its .git is a link, which is not followed" "$name"; return 0
  elif [[ -d "$project_path/.git" ]]; then
    gd="$project_path/.git"
  elif [[ -f "$project_path/.git" ]]; then
    if ! _proj_ptr "$project_path/.git" gd || [[ "$gd" != "gitdir: "* ]] \
       || ! _proj_resolve "$project_path" "${gd#gitdir: }" gd; then
      _proj_gi_note "its .git names no git directory that can be read" "$name"; return 0
    fi
  else
    return 0
  fi
  # The project's own file, in the agent's tree: built privately and renamed
  # in (PRJ-10). A link is left alone — git does not follow one either — and named.
  local gi="${project_path}/.gitignore" tmpd perms
  if [[ -L "$gi" || ( -e "$gi" && ! -f "$gi" ) ]]; then
    _proj_note_skip "$gi" "/.ai-containers/ is not added to it"; return 0
  fi
  tmpd="$(mktemp -d)" || return 0
  perms="$(_perms_new)"; : > "$tmpd/gi"
  if [[ -e "$gi" ]]; then
    if ! _proj_read "$gi" "$tmpd/gi" 4194304; then
      rm -rf "$tmpd"; _proj_note_skip "$gi" "/.ai-containers/ is not added to it"; return 0
    fi
    perms="$_proj_perms"
  fi
  if grep -qxE "$_proj_line_re" "$tmpd/gi"; then rm -rf "$tmpd"; return 0; fi
  if ! _proj_common "$gd" cdir; then
    rm -rf "$tmpd"; _proj_gi_note "the commondir of its git directory cannot be read" "$name"; return 0
  fi
  if _proj_ignored_elsewhere "$cdir" "$project_path"; then rm -rf "$tmpd"; return 0; fi
  # If the project intentionally TRACKS .ai-containers/, never add an ignore rule —
  # it would silently hide newly-synced files from commits (PRJ-4).
  rc=0; _proj_index_tracks "$gd" "$cdir" || rc=$?
  if (( rc != 1 )); then
    rm -rf "$tmpd"
    if (( rc != 0 )); then
      _proj_gi_note "whether it tracks .ai-containers/ is not known: $_proj_why" "$name"
    fi
    return 0
  fi
  if [[ -s "$tmpd/gi" && -n "$(tail -c1 "$tmpd/gi")" ]]; then printf '\n' >> "$tmpd/gi"; fi
  {
    printf '# AI sandbox tooling — local working copy synced from the central ai-containers repo\n'
    printf '# (the launcher embeds machine-specific paths). Remove this line to version it instead.\n'
    printf '/.ai-containers/\n'
  } >> "$tmpd/gi"
  if _proj_write "$tmpd/gi" "$gi" "$perms"; then
    printf '  Added /.ai-containers/ to %s/.gitignore\n' "$name"
  else
    printf '  NOTE: could not add /.ai-containers/ to %s\n' "$gi"
  fi
  rm -rf "$tmpd"
}

# The line, as git reads an ignore file: with or without either slash, a
# trailing CR and trailing spaces trimmed, and nothing else (a tab is kept).
_proj_line_re=$'/?\\.ai-containers/? *\r?'

# Every git run here: none of the repository-locating or -c variables of the
# shell that started the sync (a git hook exports GIT_DIR), which would point
# the throwaway repository at another.
_proj_git_env=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE
  -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE
  -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CEILING_DIRECTORIES)

# _proj_gi_note REASON PROJECT-NAME — why no line was added, and the way out.
_proj_gi_note() {
  printf '  NOTE: /.ai-containers/ is not added to %s/.gitignore: %s. Add it yourself if the copy is not to be committed, or set AI_CONTAINERS_NO_GITIGNORE=1 to skip this.\n' "$2" "$1"
}

# _proj_ptr FILE OUTVAR — a .git file or a commondir, read as git and the
# launcher read it (sandbox.sh: `_git_ptr_read()`): at most 4096 bytes, no NUL,
# its trailing CRs and LFs cut. Fails on anything else.
_proj_ptr() {
  local -n _pp_out=$2
  local t
  _pp_out=""
  t="$(mktemp)" || return 1
  if ! _proj_read "$1" "$t" 4096 || [[ "$(tr -d '\000' < "$t" | wc -c)" != "$(wc -c < "$t")" ]]; then rm -f "$t"; return 1; fi
  IFS= read -r -d '' _pp_out < "$t" || true
  rm -f "$t"
  while [[ "$_pp_out" == *[$'\r\n'] ]]; do _pp_out="${_pp_out%?}"; done
  [[ -n "$_pp_out" ]]
}

# _proj_resolve DIR PATH OUTVAR — PATH taken from DIR, physically, into OUTVAR
# exactly (a trailing newline kept). Fails unless it is a directory.
_proj_resolve() {
  local -n _pr_out=$3
  local _pr_p="$2"
  _pr_out=""
  [[ "$_pr_p" == /* ]] || _pr_p="$1/$_pr_p"
  IFS= read -r -d '' _pr_out < <(cd -P -- "$_pr_p" 2>/dev/null && printf '%s\0' "$PWD") || { _pr_out=""; return 1; }
}

# _proj_common GITDIR OUTVAR — the common directory: the one GITDIR's commondir
# names (a linked worktree's), or GITDIR itself. Fails when a commondir is there
# but cannot be read as git reads it.
_proj_common() {
  local -n _pc_out=$2
  local _pc_c=""
  _pc_out="$1"
  [[ -e "$1/commondir" || -L "$1/commondir" ]] || return 0
  _proj_ptr "$1/commondir" _pc_c && _proj_resolve "$1" "$_pc_c" "$2"
}

# _proj_ignored_elsewhere COMMONDIR WORKTREE — 0 when info/exclude or the global
# excludes file holds the line: git ignores the copy, though the root .gitignore
# does not say so. The global one is core.excludesFile, as git config gives it
# outside any repository (a relative one from WORKTREE's top, where git opens
# it), else git's default. Not as git resolves it inside the project: a
# repository's own core.excludesFile, or a global one an includeIf on the
# project's path chooses, is not read, since that is reading the project's
# config. Each file is read as data, within version.sh's bound.
_proj_ignored_elsewhere() {
  local f gx="" rc=1 t
  local files=("$1/info/exclude")
  declare -F _ver_run >/dev/null && declare -F _ver_git_runs >/dev/null || return 1
  if _ver_git_runs; then
    rc=0; _ver_run gx "${_proj_git_env[@]}" GIT_DIR=/dev/null GIT_ALLOC_LIMIT=64m \
      git config --type=path --get core.excludesFile || rc=$?
  fi
  if (( rc == 0 )); then
    gx="${gx%$'\n'}"
    [[ -z "$gx" || "$gx" == /* ]] || gx="$2/$gx"
    files+=("$gx")
  elif (( rc == 1 )); then
    files+=("${XDG_CONFIG_HOME:-${HOME:-}/.config}/git/ignore")
  fi
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    t=""; _ver_run t head -c 4194304 -- "$f" || continue
    grep -qxE "$_proj_line_re" <<<"$t" && return 0
  done
  return 1
}

# _proj_index_tracks GITDIR COMMONDIR — 0 when the index of GITDIR records
# anything under .ai-containers/, 1 when it records nothing there (or there is
# no index), 2 when that cannot be known, with the reason in _proj_why. The
# index is read with no repository: a throwaway GIT_DIR of this sync's own and
# only GIT_INDEX_FILE the project's, so nothing of the project's config is read,
# core.fsmonitor and lazy fetches off, every transport refused, within
# version.sh's bound (`_ver_run()`), and only where git runs (`_ver_git_runs()`,
# no installer on a Mac). One that is not a regular file — a FIFO hung every
# sync — is not read, and neither is one git reads only in part: a sparse index
# needs the objects, and git, without them, says error: and exits 0, as
# sandbox.sh: `_git_index_read()` found.
_proj_why=""
_proj_index_tracks() {
  local gd="$1" idx cfg="$2/config" fmt=sha1 out="" tmpr si rc
  _proj_why=""
  if ! declare -F _ver_run >/dev/null || ! declare -F _ver_git_runs >/dev/null; then
    _proj_why="version.sh is not loaded"; return 2
  fi
  if ! _ver_git_runs; then _proj_why="git does not run on this host"; return 2; fi
  # One the sync cannot search hides its index: not "no index" (re-review L2).
  if [[ ! -x "$gd" || ! -r "$gd" ]]; then _proj_why="its git directory cannot be searched"; return 2; fi
  idx="$gd/index"
  [[ -e "$idx" || -L "$idx" ]] || return 1
  if [[ -L "$idx" || ! -f "$idx" ]]; then _proj_why="its index is not a regular file"; return 2; fi
  for si in "$gd"/sharedindex.*; do
    if [[ ( -e "$si" || -L "$si" ) && ( -L "$si" || ! -f "$si" ) ]]; then _proj_why="its split index is not a regular file"; return 2; fi
  done
  # The object format, from the common directory's config. GIT_ALLOC_LIMIT, as
  # version.sh sets it: a planted value of gigabytes is read whole.
  if [[ -f "$cfg" && ! -L "$cfg" ]]; then
    rc=0; _ver_run out "${_proj_git_env[@]}" GIT_DIR=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_ALLOC_LIMIT=64m git config --file "$cfg" --get extensions.objectformat || rc=$?
    if (( rc == 0 )); then fmt="${out%$'\n'}"; elif (( rc != 1 )); then _proj_why="its config cannot be read"; return 2; fi
  fi
  if [[ ! "$fmt" =~ ^[a-z0-9]{1,16}$ ]]; then _proj_why="its object format is not one git knows"; return 2; fi
  tmpr="$(mktemp -d)" || { _proj_why="no temporary directory"; return 2; }
  rc=0; _ver_run out "${_proj_git_env[@]}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git init -q --object-format="$fmt" "$tmpr/r" || rc=$?
  if (( rc != 0 )); then
    rm -rf "$tmpr"; _proj_why="its object format is not one git knows"; return 2
  fi
  # stderr to a file, for the error: a partial read prints; exec'd, so the
  # bound's kill reaches git itself.
  rc=0; _ver_run out sh -c 'exec "$@" 2>"$0"' "$tmpr/err" "${_proj_git_env[@]}" LC_ALL=C GIT_DIR="$tmpr/r/.git" \
    GIT_INDEX_FILE="$idx" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none \
    git -C "$tmpr/r" -c core.fsmonitor=false ls-files -- .ai-containers || rc=$?
  if (( rc == 0 )) && grep -qE '^(error|fatal):' "$tmpr/err" 2>/dev/null; then rc=3; fi
  rm -rf "$tmpr"
  if (( rc == 124 )); then _proj_why="its index could not be read within ${_ver_secs:-10} s"; return 2; fi
  # What it lists is in the index, read in full or not: tracked (re-review L3).
  if (( rc == 0 || rc == 3 )) && [[ -n "$out" ]]; then return 0; fi
  if (( rc == 3 )); then _proj_why="git could read its index only in part (a sparse index needs the repository)"; return 2; fi
  if (( rc != 0 )); then _proj_why="git could not read its index"; return 2; fi
  return 1
}

# proj_dest_pin DEST / proj_dest_unpin — hold DEST (a project's .ai-containers,
# checked by proj_dest_ok and made) open, so _proj_write can refuse every write
# once the path no longer names that directory: a re-init waits at its Overwrite
# prompt for as long as you take, and DEST renamed and replaced by a link
# meanwhile carried the launcher wherever the link pointed (review of PRJ-11).
# A rename inside a running container fails (EBUSY: the launcher overlays it);
# this covers what runs outside one. What is left is the instant between the
# check and the create.
_proj_dest="" _proj_dest_fd=""
proj_dest_pin() {
  proj_dest_unpin
  { exec {_proj_dest_fd}<"$1"; } 2>/dev/null || { _proj_dest_fd=""; return 1; }
  _proj_dest="$1"
  _proj_dest_same || { proj_dest_unpin; return 1; }
}
proj_dest_unpin() {
  if [[ -n "$_proj_dest_fd" ]]; then exec {_proj_dest_fd}<&-; fi
  _proj_dest="" _proj_dest_fd=""
}
_proj_dest_same() {
  [[ -z "$_proj_dest_fd" ]] && return 0
  [[ ! -L "$_proj_dest" && -d "$_proj_dest" ]] && _proj_fd_is "$_proj_dest" "$_proj_dest_fd"
}

# proj_dest_ok DEST — 0 when DEST (a project's .ai-containers) is a real
# directory or absent; otherwise say why and return 1. A link there would carry
# every write below it somewhere else.
proj_dest_ok() {
  if [[ -L "$1" ]]; then
    printf 'ERROR: %s is a link; refusing to write through it. Replace it with a directory.\n' "$1" >&2
    return 1
  fi
  if [[ -e "$1" && ! -d "$1" ]]; then
    printf 'ERROR: %s is not a directory.\n' "$1" >&2
    return 1
  fi
  return 0
}

# proj_backup FILE BACKUP — copy FILE to BACKUP (a fresh name) through
# _proj_read and _proj_write, with FILE's mode: a .pre-init or .pre-migrate
# backup made with cp copied whatever a link there pointed at into the project.
# 1 when FILE is a link, not a regular file, too large or unreadable.
proj_backup() {
  local tmpd rc=0
  tmpd="$(mktemp -d)" || return 1
  if _proj_read "$1" "$tmpd/f" 16777216; then
    _proj_write "$tmpd/f" "$2" "$_proj_perms" || rc=1
  else
    rc=1
  fi
  rm -rf "$tmpd"
  return "$rc"
}

# proj_version_record SRC DEST — version_record (version.sh) into a private
# directory, then renamed in as DEST/engine-version, or a stale one removed.
proj_version_record() {
  local tmpd
  tmpd="$(mktemp -d)" || return 0
  version_record "$1" "$tmpd"
  if [[ -f "$tmpd/engine-version" ]]; then
    _proj_write "$tmpd/engine-version" "$2/engine-version" "$(_perms_new)" \
      || printf '  NOTE: could not record the engine version in %s\n' "$2"
  else
    rm -f "$2/engine-version"
  fi
  rm -rf "$tmpd"
  return 0
}

# Ensure the project's INNER .ai-containers/.gitignore covers the generated/local files.
#
# project-init.sh seeds this list, but sync must backfill it too: a project initialised
# before a pattern existed never gets it otherwise. This matters most for
# `sandbox.local.env`, which holds THIS MACHINE's absolute mount paths and is the one file
# in the working copy that must never be committed. Its only protection is this inner
# ignore file — and for the layout ensure_ai_containers_ignored deliberately leaves alone
# (a project that TRACKS .ai-containers/), the root .gitignore protects nothing at all.
# Idempotent: appends only patterns that are not already listed verbatim.
ensure_inner_gitignore() {
  local dest="$1"
  # did_add, not added: reconcile_sandbox_conf's `local added=()` (an array,
  # different function above) makes shellcheck's array/scalar tracking — which
  # isn't scope-aware — falsely flag this unrelated scalar as SC2178/SC2128.
  # Renaming sidesteps the collision instead of suppressing a real pattern.
  # Built privately and renamed in (PRJ-10). This file is sync's: a link there
  # is replaced by a file of the patterns; anything else not a file is named.
  local gi="${dest}/.gitignore" pat did_add=0 tmpd perms
  tmpd="$(mktemp -d)" || return 0
  perms="$(_perms_new)"; : > "$tmpd/gi"
  if [[ -e "$gi" && ! -L "$gi" ]]; then
    if ! _proj_read "$gi" "$tmpd/gi" 4194304; then
      rm -rf "$tmpd"; _proj_note_skip "$gi" "its patterns are not backfilled"; return 0
    fi
    perms="$_proj_perms"
  fi
  # Guarantee a trailing newline before appending to a non-empty file
  # (otherwise the first appended pattern gets glued onto the file's last line).
  if [[ -s "$tmpd/gi" && -n "$(tail -c1 "$tmpd/gi")" ]]; then printf '\n' >> "$tmpd/gi"; fi
  for pat in '.agent-blocked/' '.agent-discovery/' 'sandbox.local.env' 'sandbox.local.env.pre-init*' 'sandbox.env.pre-init*' \
             '*.pre-migrate' '*.pre-migrate.*' '*.pre-multiline' '*.pre-multiline.*' \
             'allowlist-domains.txt' 'allowlist-proxy-domains.txt' 'allowlist-cidrs.txt' \
             'allowlist-domains.d/custom.txt' 'allowlist-proxy-domains.d/custom.txt' \
             'allowlist-cidrs.d/custom.txt'; do
    if ! grep -qxF "$pat" "$tmpd/gi"; then
      printf '%s\n' "$pat" >> "$tmpd/gi"
      did_add=1
    fi
  done
  [[ -L "$gi" ]] && did_add=1
  if (( did_add )); then
    if _proj_write "$tmpd/gi" "$gi" "$perms"; then
      printf '  Backfilled .ai-containers/.gitignore patterns.\n'
    else
      printf '  NOTE: could not backfill %s\n' "$gi"
    fi
  fi
  rm -rf "$tmpd"
  return 0
}
