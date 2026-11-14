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
      if [[ "$base" == "$arg" ]]; then n=$((n + 1)); found="$r"; cands+="  $(_ac_term "$r")"$'\n'; fi
    done
    if (( n > 1 )); then
      printf 'ERROR: "%s" is the name of %d registered projects:\n%s' "$(_ac_term "$arg")" "$n" "$cands" >&2
      printf 'Give the path of the one you mean.\n' >&2
      exit 1
    fi
  fi

  if [[ -n "$found" ]]; then
    PRJ_ROOT="$found"
  elif [[ -n "$ok" ]]; then
    PRJ_ROOT="${phys:-$abs}"
  else
    printf 'ERROR: "%s" is not a registered project (see %s).\n' "$(_ac_term "$arg")" "$prj_conf" >&2
    if (( ${#roots[@]} )); then
      printf 'Registered:\n' >&2
      for r in "${roots[@]}"; do printf '  %s\n' "$(_ac_term "$r")" >&2; done
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

# ── what a project is made of, read the way the launcher reads it ──

# _prj_strip <path>: without trailing slashes ("/" stays "/").
_prj_strip() {
  local p="$1"
  while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done
  printf '%s' "$p"
}

# _prj_phys <path>: its physical spelling — pwd -P of it where it is a directory,
# else of its nearest existing ancestor followed by the rest as given; the path
# as given when no ancestor can be entered. Records name physical paths
# (build.sh's image-projects.conf), and a launch directory or a project that is
# gone still has a parent to resolve.
_prj_phys() {
  local p rest="" up phys
  p="$(_prj_strip "$1")"
  if [[ -d "$p" ]] && phys="$(cd "$p" 2>/dev/null && pwd -P)"; then printf '%s' "$phys"; return 0; fi
  up="$p"
  while [[ "$up" == /*/* ]]; do
    rest="/${up##*/}$rest"; up="${up%/*}"
    if [[ -d "$up" ]] && phys="$(cd "$up" 2>/dev/null && pwd -P)"; then
      printf '%s%s' "${phys%/}" "$rest"; return 0
    fi
  done
  printf '%s' "$p"
}

# _prj_within <path> <dir>: <path> is <dir> or lies below it. "/" and "" contain
# nothing: a root of / would otherwise take every working copy there is.
_prj_within() {
  local p d
  p="$(_prj_strip "$1")"; d="$(_prj_strip "$2")"
  [[ -n "$d" && "$d" != / ]] || return 1
  [[ "$p" == "$d" || "$p" == "$d/"* ]]
}

# _prj_has_env <dot>: the project has launcher settings to read. Without either
# file nothing says which image or group it used (its .ai-containers was deleted
# by hand, or never had them).
_prj_has_env() { [[ -f "$1/sandbox.env" || -f "$1/sandbox.local.env" ]]; }

# prj_env <dot> <KEY> [default]: the value sandbox.sh would use for <KEY> in that
# project — sandbox.local.env over sandbox.env, as load_env_defaults() reads them,
# whatever this shell has set — or <default>. Their warnings are sandbox.sh's to
# print, not this listing's.
prj_env() {
  local dot="$1" key="$2" def="${3:-}"
  ( unset "$key"
    load_env_defaults "$dot/sandbox.local.env" local || true
    load_env_defaults "$dot/sandbox.env" || true
    printf '%s' "${!key:-$def}" ) 2>/dev/null || true
}

# prj_id <path>: the id build.sh gives the image it builds there
# (ai_containers_project_id() of the physical directory); for a path that is
# gone, of its physical spelling as far as it still exists (_prj_phys). rc 1,
# and no key made, where there is no key yet: no image here carries an id then,
# and asking must not write one.
prj_id() {
  [[ -e "$project_id_key_file" || -L "$project_id_key_file" ]] || return 1
  ai_containers_project_id "$(_prj_phys "$1")"
}

# _prj_only_dot <root>: <root> holds nothing but .ai-containers, so it is left
# empty once that goes.
_prj_only_dot() (
  shopt -s nullglob dotglob
  ents=("$1"/*)
  for e in ${ents[@]+"${ents[@]}"}; do
    [[ "${e##*/}" == .ai-containers ]] || exit 1
  done
  exit 0
)

# prj_running <root>: the running containers of that project, one name per line:
# those that bind-mount its .ai-containers or anything under it (a launch from
# runme.sh mounts its output directories there, and its launcher read-only), in
# either spelling of the path, and those whose image is its IMAGE_NAME. rc 0 when
# it named any, 1 when none runs, 2 when docker could not list them: that is
# never read as "none". With no settings to read, by mounts only: the default
# image name is no evidence that a container is this project's.
prj_running() {
  local dot phys name src names
  local -A seen=()
  dot="$(_prj_strip "$1")/.ai-containers"
  phys="$(_prj_phys "$dot")"
  names="$(docker ps --format '{{.Names}}' 2>/dev/null)" || return 2
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    # One that stopped since the listing has no mounts to read, and is not running.
    while IFS= read -r src; do
      if [[ -n "$src" ]] && { _prj_within "$src" "$dot" || _prj_within "$src" "$phys"; }; then
        seen["$name"]=1; break
      fi
    done < <(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$name" 2>/dev/null || true)
  done <<< "$names"
  if _prj_has_env "$dot"; then
    names="$(docker ps --filter "ancestor=$(prj_env "$dot" IMAGE_NAME ai-sandbox)" --format '{{.Names}}' 2>/dev/null)" || return 2
    while IFS= read -r name; do
      if [[ -n "$name" ]]; then seen["$name"]=1; fi
    done <<< "$names"
  fi
  (( ${#seen[@]} )) || return 1
  printf '%s\n' "${!seen[@]}" | LC_ALL=C sort
}

# _prj_refuse_running <when>: exit 1, naming them, while a container of the
# project being removed runs, or when docker cannot tell.
_prj_refuse_running() {
  local running rc=0
  running="$(prj_running "$PRJ_ROOT")" || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) printf 'ERROR: a container of this project is running%s: %s. Stop it first; nothing was removed.\n' \
         "$1" "$(_ac_term "$(printf '%s' "$running" | tr '\n' ' ' | sed 's/ $//')")" >&2 ;;
    *) printf 'ERROR: docker could not list the running containers, so whether one of this project runs\n' >&2
       printf '       cannot be told; refusing. Nothing was removed.\n' >&2 ;;
  esac
  exit 1
}

# prj_workcopies <root>: the :rwcopy working copies launched from that project —
# those whose ai-containers.launch-dir is its root or lies under it, either
# spelling of either path, but not under a deeper registered project, whose
# copies they are. One volume name per line.
prj_workcopies() {
  local root wc ldir r rp f g deeper
  local -a forms=() deep=() lforms=()
  root="$(_prj_strip "$1")"
  forms=("$root" "$(_prj_phys "$root")")
  # Registered projects inside this one. The same directory registered under
  # another spelling is this one, not a deeper one.
  while IFS= read -r r; do
    r="$(_prj_strip "$r")"; rp="$(_prj_phys "$r")"
    [[ "$rp" != "${forms[1]}" ]] || continue
    for f in "$r" "$rp"; do
      for g in "${forms[@]}"; do
        if [[ "$f" != "$g" ]] && _prj_within "$f" "$g"; then deep+=("$r" "$rp"); break 2; fi
      done
    done
  done < <(prj_roots)
  [[ -n "$_vl_loaded" ]] || docker_volume_labels_load
  while IFS= read -r wc; do
    [[ -n "$wc" ]] || continue
    ldir="$(docker_volume_label "$wc" 'ai-containers.launch-dir')"
    [[ -n "$ldir" ]] || continue
    # shellcheck disable=SC2034  # read through a nameref by _prj_within_any
    lforms=("$ldir" "$(_prj_phys "$ldir")")
    _prj_within_any lforms forms || continue
    deeper=0
    if (( ${#deep[@]} )) && _prj_within_any lforms deep; then deeper=1; fi
    (( deeper )) || printf '%s\n' "$wc"
  done < <(repo_workcopy_volumes)
  return 0
}

# _prj_within_any <paths-array> <dirs-array>: one of the paths lies within one of
# the dirs.
_prj_within_any() {
  local -n _pw_p="$1" _pw_d="$2"
  local p d
  for p in "${_pw_p[@]}"; do
    for d in "${_pw_d[@]}"; do
      if _prj_within "$p" "$d"; then return 0; fi
    done
  done
  return 1
}

# prj_seed_ready: resolve the seed helper image (ensure_seed_image(), which may
# build it) once, in this shell, so the per-copy inspections reuse it and its
# seed_selinux_opt. ensure_seed_image exits when the image cannot be had; run in
# a command substitution, that is _prj_seed_state=failed — the copies are then
# not checked — never the end of the command.
_prj_seed_state=""
prj_seed_ready() {
  local opt
  [[ -z "$_prj_seed_state" ]] || return 0
  if opt="$(ensure_seed_image; printf '%s' "$seed_selinux_opt")"; then
    seed_selinux_opt="$opt"; _prj_seed_state=ok
  else
    _prj_seed_state=failed
  fi
  return 0
}

# prj_copy_risk <vol>: one line saying what removing that working copy would
# lose; rc 1 when it may lose something or could not be checked, 0 when nothing
# is at risk. Checked by repo-git-reset.sh's read-only inspect pass, as
# `repo.sh reset` does, against the URL its base volume records — never by git on
# the copy's own .git. Not being able to check is never read as safe, and what
# an inspection cut short had already reported is still said.
prj_copy_risk() {
  local vol="$1" repo base type recs line kind rest br unpushed tname tkept ton
  local ended="" stale="" wt_got="" i out="" known=""
  local -a items=() held=()
  repo="$(docker_volume_label "$vol" 'ai-containers.repo')"
  if [[ -z "$repo" ]]; then
    printf 'NOT CHECKED: it carries no ai-containers.repo label\n'; return 1
  fi
  base="$(repo_volume_name "$repo")"
  if ! docker_volume_present "$base"; then
    printf 'NOT CHECKED: its base volume %s is gone, and with it the remote to compare with\n' "$(_ac_term "$base")"; return 1
  fi
  # Under a nested REPO_VOLUME_PREFIX two repos' base volumes share a name
  # (REPO-11): another repo's URL is never the one to compare with.
  if [[ "$(docker_volume_label "$base" 'ai-containers.repo')" != "$repo" ]]; then
    printf 'NOT CHECKED: %s is not labelled as repo %s'"'"'s base volume\n' "$(_ac_term "$base")" "$(_ac_term "$repo")"; return 1
  fi
  type="$(docker_volume_label "$base" 'ai-containers.type')"
  if [[ "$type" == path ]]; then
    printf 'NOT CHECKED: a copy of a path repo, which has no remote to compare with\n'; return 1
  fi
  if [[ "$type" != git ]]; then
    printf 'NOT CHECKED: its base volume records no repo type\n'; return 1
  fi
  prj_seed_ready
  if [[ "$_prj_seed_state" != ok ]]; then
    printf 'NOT CHECKED: the seed helper image (%s) could not be had\n' "$(_ac_term "$seed_image")"; return 1
  fi
  recs="$(inspect_git "$vol")" || true
  # items: everything at risk; held: what is at risk whatever the rest says, kept
  # for a line that ends up "not checked".
  while IFS= read -r line; do
    kind="${line%%|*}"; rest="${line#*|}"
    case "$kind" in
      STALE) stale="$rest" ;;
      BRANCH)
        br="${rest%%|*}"; rest="${rest#*|}"; unpushed="${rest%%|*}"
        if [[ ! "$unpushed" =~ ^[0-9]+$ ]]; then items+=("$br: unpushed count unknown")
        elif (( 10#$unpushed > 0 )); then
          items+=("$br: $unpushed unpushed commit(s)"); held+=("$br: $unpushed unpushed commit(s)")
        fi ;;
      STASH) items+=("a stash (${rest} entr(y/ies))"); held+=("a stash (${rest} entr(y/ies))") ;;
      TAG)
        # At risk as `repo.sh reset` counts it (collect_inspections()): unless the
        # remote has the tag (yes) or another on its commit (same), or keeps the
        # commit it marks.
        tname="${rest%%|*}"; rest="${rest#*|}"; tkept="${rest%%|*}"; ton="${rest#*|}"
        if [[ "$tkept" != yes && "$tkept" != same && "$ton" != yes ]]; then
          items+=("tag $tname: its commit may be on no remote branch or tag")
        fi ;;
      NESTED) items+=("$rest: a git repository inside the checkout"); held+=("$rest: a git repository inside the checkout") ;;
      NESTED-MORE) items+=("$rest more git repositories inside the checkout"); held+=("$rest more git repositories inside the checkout") ;;
      WORKTREE)
        wt_got=1
        case "$rest" in
          clean) ;;
          changed) items+=("uncommitted work in the checkout"); held+=("uncommitted work in the checkout") ;;
          *) items+=("uncommitted work unknown (the checkout could not be compared)")
             held+=("uncommitted work unknown (the checkout could not be compared)") ;;
        esac ;;
      END) ended=1 ;;
    esac
  done <<< "$recs"
  for i in ${held[@]+"${held[@]}"}; do known+="${known:+, }$i"; done
  [[ -z "$known" ]] || known=" — and it holds: $(_ac_term "$known")"
  if [[ -n "$stale" ]]; then
    printf 'NOT CHECKED: the remote could not be reached (%s)%s\n' "$(_ac_term "$stale")" "$known"; return 1
  fi
  if [[ -z "$ended" ]]; then
    printf 'NOT CHECKED: the inspection was cut short or did not run%s\n' "$known"; return 1
  fi
  [[ -n "$wt_got" ]] || items+=("uncommitted work unknown (the checkout could not be compared)")
  if (( ${#items[@]} )); then
    for i in "${items[@]}"; do out+="${out:+, }$i"; done
    printf 'AT RISK: %s\n' "$(_ac_term "$out")"; return 1
  fi
  printf 'nothing at risk: every branch pushed, no stash, the checkout clean\n'
  return 0
}

# _prj_image_why <image> <id>: why that image is not this project's to remove,
# rc 1; nothing and rc 0 when its ai-containers.project label is <id>.
_prj_image_why() {
  local img="$1" id="$2" labels proj
  if ! labels="$(docker image inspect --format '{{json .Config.Labels}}' "$img" 2>/dev/null)"; then
    printf 'no image has that name'; return 1
  fi
  # Keys, not text: a key follows an unescaped { or , (ai_containers_retag_check()).
  if [[ "$labels" != *'{"ai-containers.'* && "$labels" != *',"ai-containers.'* ]]; then
    printf 'it carries no ai-containers labels, so this tool did not build it'; return 1
  fi
  proj="$(docker image inspect --format '{{index .Config.Labels "ai-containers.project"}}' "$img" 2>/dev/null)" || proj=""
  if [[ -z "$proj" || "$proj" == "<no value>" ]]; then
    printf 'it records no project (built before images did)'; return 1
  fi
  if [[ -z "$id" ]]; then
    printf "this project's id cannot be computed"; return 1
  fi
  if [[ "$proj" != "$id" ]]; then
    printf "it was built for another project"; return 1
  fi
  return 0
}

# prj_image_remove <image> <id>: remove the image the narrow way
# remove_replaced_image() does — `docker rmi` without --force, so one a container
# still references survives — and only when its ai-containers.project label is
# <id>: IMAGE_NAME is portable, and may name a base image or another project's.
# Says what it did or why not; never fails the caller.
prj_image_remove() {
  local img="$1" id="$2" why err
  if ! why="$(_prj_image_why "$img" "$id")"; then
    printf 'Image %s not removed: %s.\n' "$(_ac_term "$img")" "$why"
    return 0
  fi
  if err="$(docker rmi "$img" 2>&1 >/dev/null)"; then
    printf 'Removed the image %s.\n' "$(_ac_term "$img")"
  else
    printf 'NOTE: could not remove the image %s (docker said: %s); ./project.sh gc removes it later.\n' \
      "$(_ac_term "$img")" "$(_ac_term "$err")" >&2
  fi
  return 0
}

# _prj_shared <dot>: the group and the repo volumes a project uses, as the
# launcher resolves them: `group <g>`, then `repo <r>` for each REPOS entry and
# each @name a pointer or the working dir names.
_prj_shared() {
  local dot="$1" e v
  local -a list=()
  printf 'group %s\n' "$(prj_env "$dot" AI_CONTAINER_GROUP default)"
  read -r -d '' -a list < <(prj_env "$dot" REPOS) || true
  for e in ${list[@]+"${list[@]}"}; do printf 'repo %s\n' "${e%%:*}"; done
  # SPECS_PATH takes no :ro/:rw suffix (sandbox.sh: parse_pointer_spec()).
  v="$(prj_env "$dot" SPECS_PATH)"; if [[ "$v" == @?* ]]; then printf 'repo %s\n' "${v#@}"; fi
  for e in DOCS_PATH ARCHITECTURE_REPO_PATH; do
    v="$(prj_env "$dot" "$e")"; v="${v%:ro}"; v="${v%:rw}"
    if [[ "$v" == @?* ]]; then printf 'repo %s\n' "${v#@}"; fi
  done
  v="$(prj_env "$dot" SANDBOX_WORKDIR)"; if [[ "$v" == @?* ]]; then printf 'repo %s\n' "${v#@}"; fi
  return 0
}

# prj_unused_shared <root>: for the group and each repo volume that project uses,
# a NOTE when no other registered project uses it, naming the command that
# removes it. Nothing is removed here: groups are group.sh's, repos repo.sh's.
# A registered project whose .ai-containers is gone uses nothing; one whose
# settings cannot be read at all is said to use nothing either way.
prj_unused_shared() {
  local root rootp dot r what name
  local -A used=()
  root="$(_prj_strip "$1")"; dot="$root/.ai-containers"; rootp="$(_prj_phys "$root")"
  _prj_has_env "$dot" || return 0
  while IFS= read -r r; do
    r="$(_prj_strip "$r")"
    # This project under another spelling is not another project.
    [[ "$(_prj_phys "$r")" != "$rootp" ]] || continue
    [[ -d "$r/.ai-containers" ]] || continue
    while IFS= read -r what; do used["$what"]=1; done < <(_prj_shared "$r/.ai-containers")
  done < <(prj_roots)
  while IFS= read -r what; do
    [[ -z "${used["$what"]+x}" ]] || continue
    # The names come from the project's files, which the agent can write.
    name="$(_ac_term "${what#* }")"
    case "$what" in
      group\ *) printf 'NOTE: group %s is used by no other registered project; remove it with ./group.sh rm %s\n' "$name" "$name" ;;
      repo\ *)  printf 'NOTE: repo %s is used by no other registered project; remove it with ./repo.sh rm %s\n' "$name" "$name" ;;
    esac
    used["$what"]=1
  done < <(_prj_shared "$dot")
  return 0
}

# cmd_rm <project> [--yes]: remove a project's setup — its working copies, its
# image, its .ai-containers, its records — after listing all of it and what each
# working copy would lose. Ordered so that a failure part-way leaves the
# projects.conf line (a re-run finds the project and finishes) until nothing
# else is left to point at.
cmd_rm() {
  local arg="" assume_yes=0 a
  for a in "$@"; do
    case "$a" in
      --yes|-y) assume_yes=1 ;;
      -*) printf 'ERROR: unknown flag %s\n' "$(_ac_term "$a")" >&2; exit 1 ;;
      *) if [[ -n "$arg" ]]; then printf 'ERROR: unexpected argument %s\n' "$(_ac_term "$a")" >&2; exit 1; fi; arg="$a" ;;
    esac
  done
  [[ -n "$arg" ]] || { printf 'ERROR: usage: ./project.sh rm <project> [--yes]\n' >&2; exit 1; }
  prj_resolve "$arg"
  # Printed through _ac_term: projects.conf is a file anyone may have edited.
  local t_root t_dot
  t_root="$(_ac_term "$PRJ_ROOT")"; t_dot="$(_ac_term "$PRJ_DOT")"

  # projects.conf is edited by hand too: a line that is not an absolute path, or
  # is the root directory, names nothing rm may take apart.
  if [[ "$PRJ_ROOT" != /* || "$(_prj_strip "$PRJ_ROOT")" == / || "$(_prj_phys "$PRJ_ROOT")" == / ]]; then
    printf 'ERROR: the registered root "%s" is not an absolute path to a project directory; refusing.\n' "$t_root" >&2
    printf '       Fix or remove its line in %s.\n' "$prj_conf" >&2
    exit 1
  fi
  # Nor one whose .ai-containers is ~/.ai-containers (a project registered at
  # $HOME, or at a link to it) or lies in it or around it: that directory holds
  # every group, the project-id key and every registry. Nor one whose
  # .ai-containers holds this engine.
  local dot_p acr_p eng_p
  dot_p="$(_prj_phys "$PRJ_DOT")"; acr_p="$(_prj_phys "$ai_containers_root")"; eng_p="$(_prj_phys "$_here")"
  if _prj_within "$dot_p" "$acr_p" || _prj_within "$acr_p" "$dot_p"; then
    printf 'ERROR: %s is, holds or lies in %s, where every group, the project-id key\n' "$t_dot" "$(_ac_term "$ai_containers_root")" >&2
    printf '       and the registries live; refusing. Remove its line from %s by hand.\n' "$prj_conf" >&2
    exit 1
  fi
  if _prj_within "$eng_p" "$dot_p"; then
    printf 'ERROR: %s holds this engine (%s); refusing to remove it.\n' "$t_dot" "$(_ac_term "$_here")" >&2
    exit 1
  fi
  # A link would send the removal into wherever it points, which the agent may
  # have chosen (as sync-to-projects.sh refuses one).
  if [[ -L "$PRJ_DOT" ]] || { [[ -e "$PRJ_DOT" ]] && [[ ! -d "$PRJ_DOT" ]]; }; then
    printf 'ERROR: %s is a link or not a directory; refusing to remove anything through it.\n' "$t_dot" >&2
    exit 1
  fi
  if ! docker volume ls --quiet >/dev/null 2>&1; then
    printf 'ERROR: docker cannot be reached, so neither the project'"'"'s running containers nor its working\n' >&2
    printf '       copies can be checked; refusing. Start docker and run this again.\n' >&2
    exit 1
  fi
  _prj_refuse_running ""

  # What is there, and what removing it would lose — gathered before anything goes.
  # img stays empty when nothing says which image the project used.
  local img="" id why="" img_ok=0 ip_path="" line
  id="$(prj_id "$PRJ_DOT")" || id=""
  if _prj_has_env "$PRJ_DOT"; then
    img="$(prj_env "$PRJ_DOT" IMAGE_NAME ai-sandbox)"
    if why="$(_prj_image_why "$img" "$id")"; then img_ok=1; fi
  fi
  if [[ -n "$id" && -f "$image_projects_file" && -r "$image_projects_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "${line%%|*}" == "$id" ]]; then ip_path="${line#*|}"; break; fi
    done < "$image_projects_file"
  fi
  docker_volume_labels_load
  local -a copies=() risks=()
  local wc risk at_risk=0 i
  while IFS= read -r wc; do
    if [[ -n "$wc" ]]; then copies+=("$wc"); fi
  done < <(prj_workcopies "$PRJ_ROOT")
  # Once for every copy; a seed image that cannot be had makes them "not checked".
  if (( ${#copies[@]} )); then prj_seed_ready; fi
  for i in "${!copies[@]}"; do
    if risk="$(prj_copy_risk "${copies[i]}")"; then :; else at_risk=$((at_risk + 1)); fi
    risks[i]="$risk"
  done
  local notes; notes="$(prj_unused_shared "$PRJ_ROOT")"
  # The root goes only if .ai-containers is all it holds now (a setup kept in a
  # directory of its own); a repository it was added to stays.
  local root rm_root=0 repo
  root="$(_prj_strip "$PRJ_ROOT")"
  if [[ -d "$root" && ! -L "$root" ]] && _prj_only_dot "$root"; then rm_root=1; fi

  printf 'About to remove project %s:\n' "$t_root"
  if [[ -d "$PRJ_DOT" ]]; then printf '  directory   %s\n' "$t_dot"
  else printf '  directory   %s (already gone)\n' "$t_dot"; fi
  if (( rm_root )); then printf '  directory   %s (it holds nothing else)\n' "$(_ac_term "$root")"; fi
  printf '  registry    %s (projects.conf)\n' "$t_root"
  if [[ -n "$ip_path" ]]; then
    printf '  registry    %s (image-projects.conf, once no image carries its id)\n' "$(_ac_term "$ip_path")"
  fi
  if [[ -z "$img" ]]; then
    printf '  image       (unknown — no sandbox.env; ./project.sh gc removes it by its label)\n'
  elif (( img_ok )); then
    printf '  image       %s\n' "$(_ac_term "$img")"
  else
    printf '  image       %s — kept: %s\n' "$(_ac_term "$img")" "$why"
  fi
  for i in "${!copies[@]}"; do
    repo="$(docker_volume_label "${copies[i]}" 'ai-containers.repo')"
    printf '  working copy %s (%s) — %s\n' "$(_ac_term "${copies[i]}")" "$(_ac_term "${repo:-?}")" "${risks[i]}"
  done
  if (( at_risk )); then printf '%d working cop(y/ies) at risk or not checked.\n' "$at_risk"; fi

  if ! confirm "Remove all of the above?"; then
    printf 'Nothing was removed.\n' >&2
    exit 1
  fi
  # A launch during the question (runme.sh started in another terminal) would
  # find its setup gone under it.
  _prj_refuse_running " (it started after the listing)"

  # 1. The working copies. A failure stops everything: the line stays, so a
  #    re-run finds the project and the copies it has left.
  for wc in ${copies[@]+"${copies[@]}"}; do
    if ! docker volume rm "$wc" >/dev/null; then
      printf 'ERROR: could not remove the working copy %s (in use?). Nothing else was removed;\n' "$(_ac_term "$wc")" >&2
      printf '       run ./project.sh rm %s again once it can be.\n' "$t_root" >&2
      exit 1
    fi
    printf 'Removed the working copy %s.\n' "$(_ac_term "$wc")"
  done
  # 2. The image, only if the listing said it goes (prj_image_remove checks again).
  if (( img_ok )); then prj_image_remove "$img" "$id"; fi
  # 3. The directory. rm -rf removes a link it meets inside, never what it points
  #    to; one that has replaced the directory itself since it was checked stops it.
  if [[ -L "$PRJ_DOT" ]]; then
    printf 'ERROR: %s has become a link since it was checked; it is left alone, and so are its\n' "$t_dot" >&2
    printf '       registry lines.\n' >&2
    exit 1
  fi
  if [[ -e "$PRJ_DOT" ]]; then
    if ! rm -rf -- "$PRJ_DOT" || [[ -e "$PRJ_DOT" || -L "$PRJ_DOT" ]]; then
      printf 'ERROR: could not remove %s (see above). Its registry lines are kept;\n' "$t_dot" >&2
      printf '       fix what stopped it and run ./project.sh rm %s again.\n' "$t_root" >&2
      exit 1
    fi
    printf 'Removed %s.\n' "$t_dot"
  fi
  # 4. Its image-projects.conf line, once no image carries the id: another
  #    project's build, or gc, still needs the line to name an image that does.
  if [[ -n "$id" && -n "$ip_path" ]]; then
    local carriers
    if ! carriers="$(docker images -q --filter "label=ai-containers.project=$id" 2>/dev/null)"; then
      printf 'NOTE: docker could not list images, so its image-projects.conf line is kept; ./project.sh gc drops it later.\n' >&2
    elif [[ -n "$carriers" ]]; then
      printf 'NOTE: an image still carries this project'"'"'s id, so its image-projects.conf line is kept; ./project.sh gc drops it later.\n' >&2
    else
      prj_image_projects_drop "$id" || {
        printf 'ERROR: could not drop its line from %s. The projects.conf line is kept;\n' "$image_projects_file" >&2
        printf '       run ./project.sh rm %s again.\n' "$t_root" >&2
        exit 1
      }
      printf 'Removed %s from image-projects.conf.\n' "$(_ac_term "$ip_path")"
    fi
  fi
  # 5. Its projects.conf line.
  prj_conf_remove "$PRJ_ROOT" || exit 1
  printf 'Removed %s from projects.conf.\n' "$t_root"
  # 6. The root, if it was listed: rmdir removes it only while it is empty.
  if (( rm_root )) && [[ -d "$root" && ! -L "$root" ]] && rmdir -- "$root" 2>/dev/null; then
    printf 'Removed the empty directory %s.\n' "$(_ac_term "$root")"
  fi
  if [[ -n "$notes" ]]; then printf '%s\n' "$notes"; fi
  printf 'OK: removed project %s.\n' "$t_root"
}

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
