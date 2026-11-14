#!/usr/bin/env bash
set -euo pipefail
unset CDPATH  # a relative cd follows it and prints the directory (bugs review GIT-17, GIT-20)

# project.sh — the front door for a project's container setup.
#
# A project's setup is several things in several places: its .ai-containers/
# working copy, its line in this checkout's projects.conf, its line in
# ~/.ai-containers/image-projects.conf, its image, and the :rwcopy working-copy
# volumes made for it. project-init.sh makes them; nothing removed or moved
# them, so deleting or relocating a project left every other piece behind.
# 'rm', 'mv' and 'gc' keep the pieces in step; 'init', 'report' and 'sync' are
# the tools that already existed, reached from here.
#
# Scope: a project's own setup ONLY. Groups (~/.ai-containers/<group>/, their
# rvm volumes) are group.sh's, and repo volumes are repo.sh's; neither is
# touched here. A base-repo tool: it is not copied into projects.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sandbox-common.sh
source "${_here}/sandbox-common.sh"
# Sourced BEFORE anything below is defined: repo.sh has its own usage(), cmd_rm()
# and cmd_gc(), and the definitions that come later in this file must win.
# Sourcing it brings more than its functions: its top level refuses a non-numeric
# SANDBOX_UID/SANDBOX_GID (exit 1) and sets seed_selinux_opt="", so project.sh
# inherits that check for every command, init, report and sync included.
# shellcheck source=repo.sh
source "${_here}/repo.sh"

prj_conf="${_here}/projects.conf"

usage() {
  cat <<'EOF2'
Usage:
  ./project.sh init   [args]               Set a project up (project-init.sh)
  ./project.sh report [args]               Report what is registered (ai-containers-report.sh)
  ./project.sh sync   [args]               Sync shared files to projects (sync-to-projects.sh)
  ./project.sh rm  <project> [--yes]       Remove a project's container setup
  ./project.sh mv  <project> <new-path>    Move a project and keep its setup with it
  ./project.sh gc  [--yes]                 Remove what registered projects no longer need

<project> is a registered path, a path to it, or the basename of exactly one
registered project.

Notes:
  - Groups and repo volumes are NOT touched: they are shared. Use ./group.sh and
    ./repo.sh for those.
EOF2
}

confirm() {   # $1 = prompt; honours --yes via $assume_yes
  local prompt="$1"
  [[ "${assume_yes:-0}" == "1" ]] && return 0
  if [[ ! -t 0 ]]; then
    printf 'ERROR: %s (stdin is not a TTY — pass --yes to proceed non-interactively)\n' "$prompt" >&2
    return 1
  fi
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# _prj_key <line>: a registry line as it is matched: no CR, no trailing blanks.
_prj_key() {
  local k="${1%$'\r'}"
  while [[ "$k" == *[[:space:]] ]]; do k="${k%?}"; done
  printf '%s' "$k"
}

# prj_roots: each registered root, one per line; blank and # lines skipped.
prj_roots() {
  [[ -f "$prj_conf" ]] || return 0
  local line k
  while IFS= read -r line || [[ -n "$line" ]]; do
    k="$(_prj_key "$line")"
    [[ -n "$k" && "$k" != "#"* ]] || continue
    printf '%s\n' "$k"
  done < "$prj_conf"
}

# prj_resolve <arg> [unregistered-ok]: sets PRJ_ROOT and PRJ_DOT, or exits 1.
# shellcheck disable=SC2034  # PRJ_DOT is read by the commands built on this
prj_resolve() {
  local arg="$1" ok="${2:-}" abs phys="" r rp want found="" n=0 cands="" base
  [[ -n "$arg" ]] || { printf 'ERROR: no project given.\n' >&2; exit 1; }
  if [[ "$arg" == /* ]]; then abs="$arg"; else abs="$PWD/$arg"; fi
  while [[ "${abs%/}" != "$abs" && "$abs" != "/" ]]; do abs="${abs%/}"; done
  [[ -d "$arg" ]] && phys="$(cd "$arg" 2>/dev/null && pwd -P)" || true

  local roots=() root
  while IFS= read -r root; do roots+=("$root"); done < <(prj_roots)

  # 1. the same physical directory
  if [[ -n "$phys" ]]; then
    for r in "${roots[@]+"${roots[@]}"}"; do
      [[ -d "$r" ]] || continue
      rp="$(cd "$r" 2>/dev/null && pwd -P)" || continue
      [[ "$rp" == "$phys" ]] && { found="$r"; break; }
    done
  fi
  # 2. the same string, made absolute and without a trailing /
  if [[ -z "$found" ]]; then
    for r in "${roots[@]+"${roots[@]}"}"; do
      want="$r"
      while [[ "${want%/}" != "$want" && "$want" != "/" ]]; do want="${want%/}"; done
      [[ "$want" == "$abs" ]] && { found="$r"; break; }
    done
  fi
  # 3. a basename exactly one registered root has
  if [[ -z "$found" && "$arg" != */* ]]; then
    for r in "${roots[@]+"${roots[@]}"}"; do
      base="${r%/}"; base="${base##*/}"
      if [[ "$base" == "$arg" ]]; then n=$((n + 1)); found="$r"; cands+="  $r"$'\n'; fi
    done
    if (( n > 1 )); then
      printf 'ERROR: "%s" is the name of %d registered projects:\n%s' "$arg" "$n" "$cands" >&2
      printf 'Give the path of the one you mean.\n' >&2
      exit 1
    fi
  fi

  if [[ -n "$found" ]]; then
    PRJ_ROOT="$found"
  elif [[ -n "$ok" ]]; then
    PRJ_ROOT="${phys:-$abs}"
  else
    printf 'ERROR: "%s" is not a registered project (see %s).\n' "$arg" "$prj_conf" >&2
    if (( ${#roots[@]} )); then
      printf 'Registered:\n' >&2
      for r in "${roots[@]}"; do printf '  %s\n' "$r" >&2; done
    fi
    exit 1
  fi
  PRJ_DOT="${PRJ_ROOT%/}/.ai-containers"
}

# _prj_rewrite <file> <new-content-file>: replace <file> with the new content, by
# a temp file beside it and a rename; refuses a link or anything but a regular
# file. The mode is kept by copying the file first (cp -p) rather than reading
# it, which is stat -c on one userland and stat -f on the other.
_prj_rewrite() {
  local file="$1" new="$2" dir tmp
  if [[ -L "$file" ]] || { [[ -e "$file" ]] && [[ ! -f "$file" ]]; }; then
    printf 'ERROR: %s is a link or not a regular file — refusing to rewrite it.\n' "$file" >&2
    return 1
  fi
  dir="$(dirname "$file")"
  tmp="$(mktemp "$dir/.$(basename "$file").XXXXXX")" || {
    printf 'ERROR: cannot write beside %s.\n' "$file" >&2; return 1; }
  if [[ -f "$file" ]]; then
    cp -p "$file" "$tmp" 2>/dev/null || { rm -f "$tmp"; printf 'ERROR: cannot copy %s.\n' "$file" >&2; return 1; }
  else
    chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  # cp -p made the temp as read-only as the original: it must be writable to be
  # written, and read-only again before it replaces a file that was.
  local ro=0; [[ -f "$file" && ! -w "$file" ]] && ro=1
  chmod u+w "$tmp" 2>/dev/null || true
  if ! cat "$new" > "$tmp" || { (( ro )) && ! chmod u-w "$tmp"; } || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    printf 'ERROR: cannot rewrite %s.\n' "$file" >&2
    return 1
  fi
}

# _prj_edit <file> <op> <a> [<b>]: change only the lines an op names, every other
# byte staying. ops: remove (line is <a>), replace (line <a> becomes <b>, a CR it
# had kept), add (<a> as a last line unless a line is it), drop-id (the lines
# whose field before the first | is <a>). A missing file is empty for add and
# nothing to do for the rest.
_prj_edit() {
  local file="$1" op="$2" a="$3" b="${4:-}" out line k cr nl hit=0 last_nl=1
  # No existence or type check here: a file this finds nothing to change is left
  # alone, and one it would change goes through _prj_rewrite's refusal of a link.
  [[ -e "$file" || -L "$file" || "$op" == add ]] || return 0
  if [[ -f "$file" && ! -r "$file" ]]; then
    printf 'ERROR: cannot read %s.\n' "$file" >&2
    return 1
  fi
  out="$(mktemp)" || return 1
  if [[ -f "$file" ]]; then
    while :; do
      nl=1
      IFS= read -r line || { nl=0; [[ -n "$line" ]] || break; }
      cr=""; [[ "$line" == *$'\r' ]] && cr=$'\r'
      k="$(_prj_key "$line")"
      case "$op" in
        remove)  [[ "$k" == "$a" && "$k" != "#"* ]] && { hit=1; continue; } ;;
        replace) if [[ "$k" == "$a" && "$k" != "#"* ]]; then hit=1; line="$b$cr"; fi ;;
        add)     [[ "$k" == "$a" ]] && hit=1 ;;
        drop-id) [[ "$k" == *"|"* && "${k%%|*}" == "$a" ]] && { hit=1; continue; } ;;
      esac
      printf '%s' "$line" >> "$out"
      (( nl )) && printf '\n' >> "$out"
      last_nl=$nl
    done < "$file" || { rm -f "$out"; printf 'ERROR: cannot read %s.\n' "$file" >&2; return 1; }
  fi
  if [[ "$op" == add && "$hit" == 0 ]]; then
    hit=1
    { (( last_nl )) || printf '\n'; printf '%s\n' "$a"; } >> "$out"
  elif [[ "$op" == add ]]; then
    hit=0
  fi
  if (( hit )); then
    _prj_rewrite "$file" "$out" || { rm -f "$out"; return 1; }
  fi
  rm -f "$out"
}

prj_conf_remove()  { _prj_edit "$prj_conf" remove "$1"; }
prj_conf_replace() { _prj_edit "$prj_conf" replace "$1" "$2"; }
prj_conf_add()     { _prj_edit "$prj_conf" add "$1"; }

# prj_image_projects_drop <id>: the lines of image-projects.conf for that id.
prj_image_projects_drop() { _prj_edit "$image_projects_file" drop-id "$1"; }

cmd_rm() { printf 'ERROR: rm is not yet implemented.\n' >&2; exit 1; }
cmd_mv() { printf 'ERROR: mv is not yet implemented.\n' >&2; exit 1; }
cmd_gc() { printf 'ERROR: gc is not yet implemented.\n' >&2; exit 1; }

# Sourced for its helpers (tests), not run: by behaviour, as in repo.sh.
(return 0 2>/dev/null) && return 0

case "${1:-}" in
  init)   shift; exec "$_here/project-init.sh" "$@" ;;
  report) shift; exec "$_here/ai-containers-report.sh" "$@" ;;
  sync)   shift; exec "$_here/sync-to-projects.sh" "$@" ;;
  rm)     shift; cmd_rm "$@" ;;
  mv)     shift; cmd_mv "$@" ;;
  gc)     shift; cmd_gc "$@" ;;
  -h|--help|help|"") usage ;;
  *) printf 'ERROR: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
