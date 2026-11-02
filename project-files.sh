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
_proj_read() {
  local f="$1" out="$2" max="${3:-65536}" fd size
  [[ -f "$f" && ! -L "$f" ]] || return 1
  # Braced: on a bare exec the 2>/dev/null would stay on the shell, and every
  # later error of the sync would vanish.
  { exec {fd}<"$f"; } 2>/dev/null || return 1
  if [[ ! -L "$f" && -f "/dev/fd/$fd" && "$f" -ef "/dev/fd/$fd" ]] \
     && head -c "$(( max + 1 ))" <&"$fd" > "$out" \
     && _proj_perms="$(ls -lnL "/dev/fd/$fd" 2>/dev/null | cut -c2-10)" \
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
  if [[ -L "$t" || ! -f "$t" || ! "$t" -ef "/dev/fd/$w" ]] || ! cat "$src" >&"$w"; then ok=0
  # /dev/fd/N is the opened file on Linux whatever the name now is; where chmod
  # cannot go through it, the name is checked to still be that file first.
  elif [[ -n "$x" ]] && ! chmod "$x" "/dev/fd/$w" 2>/dev/null \
       && ! { [[ ! -L "$t" && "$t" -ef "/dev/fd/$w" ]] && chmod "$x" "$t" 2>/dev/null; }; then ok=0
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
  mv -T -f "$1" "$2" 2>/dev/null || mv -h -f "$1" "$2" 2>/dev/null
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
ensure_ai_containers_ignored() {
  local project_path="$1"
  [[ "${AI_CONTAINERS_NO_GITIGNORE:-0}" == "1" ]] && return 0
  git -C "$project_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$project_path" check-ignore -q .ai-containers 2>/dev/null && return 0
  # If the project intentionally TRACKS .ai-containers/ (any file under it is in the
  # git index), never add an ignore rule — it would silently hide newly-synced files
  # from commits. Makes AI_CONTAINERS_NO_GITIGNORE=1 unnecessary for tracked layouts.
  [[ -n "$(git -C "$project_path" ls-files -- .ai-containers 2>/dev/null | head -1)" ]] && return 0
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
  if [[ -s "$tmpd/gi" && -n "$(tail -c1 "$tmpd/gi")" ]]; then printf '\n' >> "$tmpd/gi"; fi
  {
    printf '# AI sandbox tooling — local working copy synced from the central ai-containers repo\n'
    printf '# (the launcher embeds machine-specific paths). Remove this line to version it instead.\n'
    printf '/.ai-containers/\n'
  } >> "$tmpd/gi"
  if _proj_write "$tmpd/gi" "$gi" "$perms"; then
    printf '  Added /.ai-containers/ to %s/.gitignore\n' "$(basename "$project_path")"
  else
    printf '  NOTE: could not add /.ai-containers/ to %s\n' "$gi"
  fi
  rm -rf "$tmpd"
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
  [[ ! -L "$_proj_dest" && -d "$_proj_dest" && "$_proj_dest" -ef "/dev/fd/$_proj_dest_fd" ]]
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
