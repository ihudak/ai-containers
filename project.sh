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
# The no-follow reads and writes of a project's files (_proj_read, _proj_write),
# and the index read that tells whether a repository tracks .ai-containers/
# (_proj_index_tracks), which runs git through version.sh's bound (_ver_run).
# shellcheck source=project-files.sh
source "${_here}/project-files.sh"
# shellcheck source=version.sh
source "${_here}/version.sh"

prj_conf="${_here}/projects.conf"

usage() {
  cat <<'EOF2'
Usage:
  ./project.sh init   [args]               Set a project up (project-init.sh)
  ./project.sh report [args]               Report what is registered (ai-containers-report.sh)
  ./project.sh sync   [args]               Sync shared files to projects (sync-to-projects.sh)
  ./project.sh rm  <project> [--yes]       Remove a project's container setup
  ./project.sh mv  <project> <new-dir> [--yes]
                                           Move a project's setup to <new-dir>, with its
                                           working copies and records
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

# _prj_refuse_running <when> [<root>]: exit 1, naming them, while a container of
# the project at <root> (PRJ_ROOT) runs, or when docker cannot tell.
_prj_refuse_running() {
  local running rc=0
  running="$(prj_running "${2:-$PRJ_ROOT}")" || rc=$?
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
# Says what it did or why not, and sets PRJ_IMAGE_REMOVED=1 when it removed it;
# never fails the caller.
PRJ_IMAGE_REMOVED=0
prj_image_remove() {
  local img="$1" id="$2" why err
  PRJ_IMAGE_REMOVED=0
  if ! why="$(_prj_image_why "$img" "$id")"; then
    printf 'Image %s not removed: %s.\n' "$(_ac_term "$img")" "$why"
    return 0
  fi
  if err="$(docker rmi "$img" 2>&1 >/dev/null)"; then
    PRJ_IMAGE_REMOVED=1
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

# _prj_ip_path <id>: the path image-projects.conf records for that id; nothing
# when there is no id, no file to read or no such line.
_prj_ip_path() {
  local line
  [[ -n "$1" && -f "$image_projects_file" && -r "$image_projects_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line%%|*}" == "$1" ]]; then printf '%s' "${line#*|}"; return 0; fi
  done < "$image_projects_file"
  return 0
}

# _prj_ip_drop <id> <recorded path>: drop that id's image-projects.conf lines once
# no image carries the id — another project's build, or gc, still needs the line
# to name an image that does — saying which. rc 1 when the file cannot be
# rewritten; the caller says how to finish.
_prj_ip_drop() {
  local carriers
  if ! carriers="$(docker images -q --filter "label=ai-containers.project=$1" 2>/dev/null)"; then
    printf 'NOTE: docker could not list images, so its image-projects.conf line is kept; ./project.sh gc drops it later.\n' >&2
  elif [[ -n "$carriers" ]]; then
    printf 'NOTE: an image still carries this project'"'"'s id, so its image-projects.conf line is kept; ./project.sh gc drops it later.\n' >&2
  elif ! prj_image_projects_drop "$1"; then
    printf 'ERROR: could not drop its line from %s.\n' "$image_projects_file" >&2
    return 1
  else
    printf 'Removed %s from image-projects.conf.\n' "$(_ac_term "$2")"
  fi
  return 0
}

# _prj_guard <root> <label> <verb> [registered]: exit 1, saying why, unless
# <root>/.ai-containers is one this tool may <verb> (remove, move): <root> an
# absolute path that is not /; its .ai-containers neither ~/.ai-containers nor in
# it or around it — a project registered at $HOME, or at a link to it, has that
# one, which holds every group, the project-id key and every registry — nor
# holding this engine; and, where it exists, a directory, not a link, which would
# carry the <verb> wherever it points (as sync-to-projects.sh refuses one: the
# agent may have chosen where). <label> names <root>; with registered, the
# messages say where its line is to fix. For rm's root, and for both of mv's.
_prj_guard() {
  local root="$1" label="$2" verb="$3" reg="${4:-}" dot t_root t_dot dot_p acr_p eng_p
  dot="${root%/}/.ai-containers"
  t_root="$(_ac_term "$root")"; t_dot="$(_ac_term "$dot")"
  # projects.conf is edited by hand too: a line that is not an absolute path, or
  # is the root directory, names nothing this tool may take apart.
  if [[ "$root" != /* || "$(_prj_strip "$root")" == / || "$(_prj_phys "$root")" == / ]]; then
    printf 'ERROR: %s "%s" is not an absolute path to a project directory; refusing.\n' "$label" "$t_root" >&2
    if [[ -n "$reg" ]]; then printf '       Fix or remove its line in %s.\n' "$prj_conf" >&2; fi
    exit 1
  fi
  dot_p="$(_prj_phys "$dot")"; acr_p="$(_prj_phys "$ai_containers_root")"; eng_p="$(_prj_phys "$_here")"
  if _prj_within "$dot_p" "$acr_p" || _prj_within "$acr_p" "$dot_p"; then
    printf 'ERROR: %s is, holds or lies in %s, where every group, the project-id key\n' "$t_dot" "$(_ac_term "$ai_containers_root")" >&2
    if [[ -n "$reg" ]]; then
      printf '       and the registries live; refusing. Remove its line from %s by hand.\n' "$prj_conf" >&2
    else
      printf '       and the registries live; refusing.\n' >&2
    fi
    exit 1
  fi
  if _prj_within "$eng_p" "$dot_p"; then
    printf 'ERROR: %s holds this engine (%s); refusing to %s it.\n' "$t_dot" "$(_ac_term "$_here")" "$verb" >&2
    exit 1
  fi
  if [[ -L "$dot" ]] || { [[ -e "$dot" ]] && [[ ! -d "$dot" ]]; }; then
    printf 'ERROR: %s is a link or not a directory; refusing to %s anything through it.\n' "$t_dot" "$verb" >&2
    exit 1
  fi
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
  _prj_guard "$PRJ_ROOT" "the registered root" remove registered
  if ! docker volume ls --quiet >/dev/null 2>&1; then
    printf 'ERROR: docker cannot be reached, so neither the project'"'"'s running containers nor its working\n' >&2
    printf '       copies can be checked; refusing. Start docker and run this again.\n' >&2
    exit 1
  fi
  _prj_refuse_running ""

  # What is there, and what removing it would lose — gathered before anything goes.
  # img stays empty when nothing says which image the project used.
  local img="" id why="" img_ok=0 ip_path=""
  id="$(prj_id "$PRJ_DOT")" || id=""
  if _prj_has_env "$PRJ_DOT"; then
    img="$(prj_env "$PRJ_DOT" IMAGE_NAME ai-sandbox)"
    if why="$(_prj_image_why "$img" "$id")"; then img_ok=1; fi
  fi
  ip_path="$(_prj_ip_path "$id")"
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
  if [[ -n "$id" && -n "$ip_path" ]] && ! _prj_ip_drop "$id" "$ip_path"; then
    printf '       The projects.conf line is kept; run ./project.sh rm %s again.\n' "$t_root" >&2
    exit 1
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

# ── mv: what moving a project needs ──

# _prj_registered <root>: <root> is a line of projects.conf, as prj_roots reads it.
_prj_registered() {
  local r
  while IFS= read -r r; do
    if [[ "$r" == "$1" ]]; then return 0; fi
  done < <(prj_roots)
  return 1
}

# _prj_base <path>: its last component, trailing slashes aside, as basename gives
# it — the name the launcher mounts it under, /workspace/<name>.
_prj_base() { local p; p="$(_prj_strip "$1")"; printf '%s' "${p##*/}"; }

# _prj_logical <path>: <path> made absolute and spelled as `cd <path> && pwd`
# spells it — how runme.sh's cd names the launch directory, which names its
# working copies — whether or not it exists yet: the nearest directory that does,
# through cd and pwd, then the rest as given. rc 1 when that rest holds a . or ..,
# which cd would read against directories that are not there yet.
_prj_logical() {
  local p="$1" up b out rest=""
  [[ "$p" == /* ]] || p="$PWD/$p"
  while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
  p="$(_prj_strip "$p")"; up="$p"
  while :; do
    if [[ -d "$up" ]] && out="$(cd "$up" 2>/dev/null && pwd)"; then
      out="${out%/}$rest"; printf '%s' "${out:-/}"; return 0
    fi
    [[ "$up" != / ]] || return 1
    b="${up##*/}"
    if [[ "$b" == . || "$b" == .. ]]; then return 1; fi
    rest="/$b$rest"; up="${up%/*}"; up="${up:-/}"
  done
}

# _prj_rebase <path> <from> <to>: where <path> is once <from> has moved to <to> —
# the same place under <to> — when it lies within <from>, either spelling of
# either; nothing when it does not.
_prj_rebase() {
  local p f
  for p in "$(_prj_strip "$1")" "$(_prj_phys "$1")"; do
    for f in "$(_prj_strip "$2")" "$(_prj_phys "$2")"; do
      if _prj_within "$p" "$f"; then printf '%s%s' "$(_prj_strip "$3")" "${p#"$f"}"; return 0; fi
    done
  done
  return 0
}

# Device of a path, through a link: GNU `stat -c` or BSD `stat -f`, the platform
# probed once on / as sandbox.sh: `_launcher_dev_ino()` probes it — never a
# fallback on failure, since GNU `stat -f` succeeds and reports the filesystem.
if stat -c '%d' / >/dev/null 2>&1; then _prj_stat_gnu=1; else _prj_stat_gnu=0; fi
_prj_dev() {
  local out
  if (( _prj_stat_gnu )); then out="$(stat -L -c '%d' "$1" 2>/dev/null)"; else out="$(stat -L -f '%d' "$1" 2>/dev/null)"; fi
  [[ "$out" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$out"
}

# _prj_tree <dir>: what is under <dir>, one line an entry in C order: its kind,
# its path (%q), and a file's cksum or a link's target. Two trees with the same
# lines hold the same names, kinds, links and contents. rc 1 when any of it
# cannot be read.
_prj_tree() (
  cd -P -- "$1" 2>/dev/null || exit 1
  find . -print0 | while IFS= read -r -d '' p; do
    if [[ -L "$p" ]]; then t="$(readlink "$p")" || exit 1; printf 'l %q %q\n' "$p" "$t"
    elif [[ -d "$p" ]]; then printf 'd %q\n' "$p"
    elif [[ -f "$p" ]]; then t="$(cksum < "$p")" || exit 1; printf 'f %q %s\n' "$p" "$t"
    else printf 'o %q\n' "$p"; fi
  done | LC_ALL=C sort
)

# _prj_ino <path>: the inode of <path> itself, a link's own: `ls -di`, which both
# userlands have, as project-files.sh: `_proj_fd_is()` reads one.
_prj_ino() {
  local i
  read -r i _ < <(ls -di "$1" 2>/dev/null) || return 1
  [[ "$i" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$i"
}

# _prj_mv_to <src dir> <dst>: rename it, with GNU mv's -T where mv takes it: a
# directory put at <dst> then fails the move (ENOTEMPTY), and so does a link
# (ENOTDIR), where a plain mv moves into either; the same hazard as in
# project-files.sh: `_proj_replace()`. Probed once, on a directory of its own.
# BSD mv has no -T; there _prj_landed, after the move, is what catches it.
_prj_mv_T=""
_prj_mv_to() {
  local d
  if [[ -z "$_prj_mv_T" ]]; then
    _prj_mv_T=0
    if d="$(mktemp -d)"; then
      if mkdir "$d/a" && mv -T "$d/a" "$d/b" 2>/dev/null && [[ -d "$d/b" && ! -e "$d/a" ]]; then _prj_mv_T=1; fi
      rm -rf "$d"
    fi
  fi
  if (( _prj_mv_T )); then mv -T -- "$1" "$2"; else mv -- "$1" "$2"; fi
}

# _prj_landed <inode> <dst>: the directory with that inode is <dst> itself — a
# directory, not a link — not inside something put at <dst> before the move.
_prj_landed() { [[ -d "$2" && ! -L "$2" && "$(_prj_ino "$2")" == "$1" ]]; }

# _prj_where <inode> <path>...: the physical path, of each <path> and the
# .ai-containers in it (through a link), that is the directory with <inode>;
# nothing when none is.
_prj_where() {
  local ino="$1" p c
  shift
  for p in "$@"; do
    for c in "$p" "${p%/}/.ai-containers"; do
      if [[ -e "$c" && "$(_prj_ino "$c")" == "$ino" ]]; then _prj_phys "$c"; return 0; fi
    done
  done
  return 0
}

# _prj_move_dot <old .ai-containers> <new root>: move it to <new root>/.ai-containers,
# the agent's output directories with it. On one filesystem, a rename. Across
# filesystems, cp -a to a temp name in <new root> (named in _prj_mv_tmp while it
# is there, for cmd_mv's interrupt trap), the copy compared with the original
# (_prj_tree), renamed into place, and only then the original removed. Either
# rename must land the directory at <new root>/.ai-containers itself, by its
# inode (_prj_landed): one that went into something put there meanwhile is
# named, and nothing is recorded. rc 0 moved; 1 not moved there (what went
# elsewhere is named; a copy that differs or failed is removed; the original is
# kept unless it is what went elsewhere); 2 moved, but the original could not be
# removed entirely. AI_CONTAINERS_MV_COPY=1 is a test knob: the copy path on one
# filesystem too, which the hermetic suite has no other way to reach.
_prj_mv_tmp=""
_prj_move_dot() {
  local old="$1" root="$2" new od nd tmpd a b ino cino where
  new="${root%/}/.ai-containers"
  if [[ -e "$new" || -L "$new" || -L "$old" || ! -d "$old" ]] || ! ino="$(_prj_ino "$old")"; then
    printf 'ERROR: %s is no longer a directory, or %s exists now; nothing was moved.\n' "$(_ac_term "$old")" "$(_ac_term "$new")" >&2
    return 1
  fi
  # A rename on one device. Not covered: two mounts of one filesystem (a bind
  # mount) share a device number, rename(2) then fails EXDEV, and GNU mv falls
  # back to copying and deleting, unchecked.
  if [[ "${AI_CONTAINERS_MV_COPY:-}" != 1 ]] && od="$(_prj_dev "$old")" && nd="$(_prj_dev "$root")" && [[ "$od" == "$nd" ]]; then
    if _prj_mv_to "$old" "$new" && _prj_landed "$ino" "$new" && [[ ! -e "$old" && ! -L "$old" ]]; then return 0; fi
    where="$(_prj_where "$ino" "$new" "$old")"
    if [[ -n "$where" && "$where" == "$(_prj_phys "$old")" ]]; then
      printf 'ERROR: could not move %s to %s; it is where it was.\n' "$(_ac_term "$old")" "$(_ac_term "$new")" >&2
    else
      printf 'ERROR: %s did not land at %s: something was put there meanwhile, and the setup is now at\n' "$(_ac_term "$old")" "$(_ac_term "$new")" >&2
      printf '       %s. Move it back to %s, and remove what was put at %s.\n' \
        "$(_ac_term "${where:-a place that could not be found}")" "$(_ac_term "$old")" "$(_ac_term "$new")" >&2
    fi
    return 1
  fi
  if ! tmpd="$(mktemp -d "${root%/}/.ai-containers.XXXXXX")"; then
    printf 'ERROR: cannot write in %s.\n' "$(_ac_term "$root")" >&2
    return 1
  fi
  _prj_mv_tmp="$tmpd"
  if ! cp -a "$old" "$tmpd/.ai-containers" || ! a="$(_prj_tree "$old")" || ! b="$(_prj_tree "$tmpd/.ai-containers")" \
     || [[ "$a" != "$b" ]] || [[ -e "$new" || -L "$new" ]] || ! cino="$(_prj_ino "$tmpd/.ai-containers")"; then
    rm -rf -- "$tmpd"; _prj_mv_tmp=""
    printf 'ERROR: the copy of %s made in %s could not be made or is not the same; it is removed, and\n' "$(_ac_term "$old")" "$(_ac_term "$root")" >&2
    printf '       %s is kept.\n' "$(_ac_term "$old")" >&2
    return 1
  fi
  if ! _prj_mv_to "$tmpd/.ai-containers" "$new" || ! _prj_landed "$cino" "$new"; then
    if [[ -e "$tmpd/.ai-containers" || -L "$tmpd/.ai-containers" ]]; then
      rm -rf -- "$tmpd"
      printf 'ERROR: could not move the checked copy of %s to %s; it is removed, and %s is kept.\n' \
        "$(_ac_term "$old")" "$(_ac_term "$new")" "$(_ac_term "$old")" >&2
    else
      where="$(_prj_where "$cino" "$new")"
      rmdir -- "$tmpd" 2>/dev/null || true
      printf 'ERROR: the checked copy of %s did not land at %s: something was put there meanwhile, and the\n' "$(_ac_term "$old")" "$(_ac_term "$new")" >&2
      printf '       copy is now at %s. %s is kept; remove that copy, and what was put at %s.\n' \
        "$(_ac_term "${where:-a place that could not be found}")" "$(_ac_term "$old")" "$(_ac_term "$new")" >&2
    fi
    _prj_mv_tmp=""
    return 1
  fi
  rmdir -- "$tmpd" 2>/dev/null || true
  _prj_mv_tmp=""
  # rm -rf removes a link it meets inside, never what it points to.
  if [[ -L "$old" ]] || ! rm -rf -- "$old" || [[ -e "$old" || -L "$old" ]]; then return 2; fi
  return 0
}

# prj_copy_check <src> <dst>: rc 0 when rsync finds nothing to change from volume
# <src> to volume <dst> — names, kinds, links, owners, modes, times, and contents
# by checksum — 1 when it finds anything or cannot run. Both read-only: a check
# must not change what it checks. In the seed helper image (prj_seed_ready
# first), shaped as repo.sh's seed runs are; volume to volume, with no host path,
# so with no SELinux option (AGENTS.md, "SELinux daemons").
prj_copy_check() {
  local out
  out="$(docker run --rm --entrypoint bash -v "$1":/src:ro -v "$2":/dst:ro "$seed_image" \
           -c 'rsync -aH --numeric-ids --checksum --delete --dry-run --itemize-changes /src/ /dst/')" || return 1
  [[ -z "$out" ]]
}

# prj_copy_volume <old> <new> <repo> <launch dir>: copy working copy <old> to a
# new volume <new>, labelled as a working copy of <repo> launched from <launch
# dir> (the labels sandbox.sh: `seed_workcopy_volume()` gives one), then check the
# copy (prj_copy_check). On any failure the new volume is removed, rc 1; <old> is
# never touched — the caller removes it once this returned 0. A <new> that exists
# is refused, not copied into: docker volume create would take it as it is, and
# removing it on a failure would remove what it held.
prj_copy_volume() {
  local old="$1" new="$2" repo="$3" ldir="$4"
  if docker volume inspect "$new" >/dev/null 2>&1; then
    printf 'ERROR: a volume named %s exists already; %s is not copied over it.\n' "$(_ac_term "$new")" "$(_ac_term "$old")" >&2
    return 1
  fi
  if ! docker volume create --label "ai-containers.workcopy=1" --label "ai-containers.repo=$repo" \
         --label "ai-containers.launch-dir=$ldir" "$new" >/dev/null; then
    printf 'ERROR: could not create the volume %s.\n' "$(_ac_term "$new")" >&2
    return 1
  fi
  if docker run --rm --entrypoint bash -v "$old":/src:ro -v "$new":/dst "$seed_image" \
       -c 'rsync -aH --numeric-ids /src/ /dst/' >&2 && prj_copy_check "$old" "$new"; then
    return 0
  fi
  printf 'ERROR: the copy of %s to %s failed or does not check out the same as it; %s is kept.\n' \
    "$(_ac_term "$old")" "$(_ac_term "$new")" "$(_ac_term "$old")" >&2
  if ! docker volume rm "$new" >/dev/null 2>&1; then
    printf 'NOTE: could not remove the failed copy %s; remove it with docker volume rm %s.\n' "$(_ac_term "$new")" "$(_ac_term "$new")" >&2
  fi
  return 1
}

# _prj_unmake <volume>...: remove the copies this run made, before anything old
# went, so that a failure leaves the project as it was.
_prj_unmake() {
  local v
  for v in "$@"; do
    if docker volume rm "$v" >/dev/null 2>&1; then
      printf 'Removed the new copy %s again.\n' "$(_ac_term "$v")" >&2
    else
      printf 'NOTE: could not remove the new copy %s; remove it with docker volume rm %s.\n' "$(_ac_term "$v")" "$(_ac_term "$v")" >&2
    fi
  done
}

# _prj_load_init: project-init.sh sourced for emit_env_list, the one writer of a
# list one entry per line (multiline-env.sh takes it the same way); its sourcing
# guard keeps the wizard from running. Only when a list is written: no other
# command needs it.
_prj_init_loaded=""
_prj_load_init() {
  [[ -z "$_prj_init_loaded" ]] || return 0
  # shellcheck source=project-init.sh
  source "${_here}/project-init.sh" || return 1
  declare -F emit_env_list >/dev/null || return 1
  _prj_init_loaded=1
}

# _prj_mount_dir <entry>: an EXTRA_MOUNTS entry without its mode, as sandbox.sh
# reads one (sandbox.sh: `_bind_opts_ok()`): a trailing `:<options>` is a mode
# only when each option is one `-v` takes; any other ':' belongs to the path.
# The options below are the list in sandbox.sh's `_bind_opts_ok()`, and must stay
# that list: an option one has and the other lacks splits an entry differently.
_prj_mount_opt='(ro|rw|z|Z|cached|delegated|consistent|nocopy|shared|slave|private|rshared|rslave|rprivate)'
_prj_mount_dir() {
  local ent="$1"
  if [[ "$ent" == *:* && "${ent##*:}" =~ ^${_prj_mount_opt}(,${_prj_mount_opt})*$ ]]; then ent="${ent%:*}"; fi
  printf '%s' "$ent"
}

# _prj_env_get <file> <key>: the value load_env_defaults gives <key> from <file>,
# read as a sandbox.local.env, whatever this shell has set.
_prj_env_get() {
  ( unset "$2"; load_env_defaults "$1" local 2>/dev/null || true; printf '%s' "${!2-}" ) || true
}

# _prj_env_dump <file> <key>: every key but <key> load_env_defaults sets from
# <file>, read as a sandbox.local.env, as `KEY=<%q value>` lines in C order. With
# every exported variable but PATH unset first, so that none this shell exported
# is taken for one the file set; PATH, which the loader refuses from a file
# (env_key_denied), stays for the commands it runs, and is not in the dump.
_prj_env_dump() (
  while IFS= read -r _pd_k; do
    if [[ "$_pd_k" != PATH ]]; then unset "$_pd_k" 2>/dev/null || true; fi
  done < <(compgen -e)
  load_env_defaults "$1" local 2>/dev/null || true
  while IFS= read -r _pd_k; do
    if [[ "$_pd_k" != "$2" && "$_pd_k" != PATH ]]; then printf '%s=%q\n' "$_pd_k" "${!_pd_k}"; fi
  done < <(compgen -e | LC_ALL=C sort)
)

# _prj_mounts_rewrite <file> <list>: <file> with the EXTRA_MOUNTS assignment
# load_env_defaults reads — the first one outside another key's value written
# over several lines, itself one line or several — replaced by emit_env_list's
# lines for <list>, an export kept; those lines appended where there is none.
# Every other line as it was.
_prj_mounts_rewrite() {
  local line t u done=0 inval=0 skip=0 pre
  local open_re='^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*="[[:space:]]*$'
  local em_re='^[[:space:]]*(export[[:space:]]+)?EXTRA_MOUNTS='
  while IFS= read -r line || [[ -n "$line" ]]; do
    t="${line%$'\r'}"
    if (( inval )); then
      u="${t#"${t%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
      if [[ -n "$u" && "$u" != '#'* && "$u" == *'"' ]]; then inval=0; fi
      if (( ! skip )); then printf '%s\n' "$line"; fi
      if (( ! inval )); then skip=0; fi
      continue
    fi
    if (( ! done )) && [[ "$t" =~ $em_re ]]; then
      pre="${BASH_REMATCH[1]:+export }"
      emit_env_list "${pre}EXTRA_MOUNTS" "$2"
      done=1
      if [[ "$t" =~ $open_re ]]; then inval=1; skip=1; fi
      continue
    fi
    if [[ "$t" =~ $open_re ]]; then inval=1; fi
    printf '%s\n' "$line"
  done < "$1"
  if (( ! done )); then emit_env_list EXTRA_MOUNTS "$2"; fi
}

# prj_add_mount <dot> <path> [check]: add <path> to EXTRA_MOUNTS in
# <dot>/sandbox.local.env, made if absent, unless an entry already covers it —
# is it or a directory above it, its :<options> aside, either spelling — which is
# then named in PRJ_MOUNT_COVER and nothing is written. The assignment, one line
# or several, is replaced by emit_env_list's lines for the old entries and
# <path>, and the result read back as the launcher reads it: the list must be the
# old one plus <path>, and every other key as it was, or the file is not written
# (rc 1). Read by _proj_read and written by _proj_write: the project directory is
# the agent's to write, and a link planted there is refused, never followed. With
# check, all of it but the write. A path holding whitespace, unless an entry
# covers it, is rc 1: it cannot be an entry, since they are separated by it.
PRJ_MOUNT_COVER=""
prj_add_mount() {
  local dot="$1" path file mode="${3:-}" tmpd perms e d df pf entry list bad=0
  local -a ents=() got=()
  path="$(_prj_strip "$2")"; file="$dot/sandbox.local.env"; PRJ_MOUNT_COVER=""
  if ! _prj_load_init; then
    printf 'ERROR: emit_env_list could not be loaded from %s.\n' "$(_ac_term "${_here}/project-init.sh")" >&2
    return 1
  fi
  tmpd="$(mktemp -d)" || return 1
  : > "$tmpd/old"; perms="$(_perms_new)"
  if [[ -e "$file" || -L "$file" ]]; then
    if ! _proj_read "$file" "$tmpd/old" 1048576; then
      rm -rf "$tmpd"
      printf 'ERROR: %s is a link, not a regular file, too large or unreadable; %s is not added to it.\n' \
        "$(_ac_term "$file")" "$(_ac_term "$path")" >&2
      return 1
    fi
    perms="$_proj_perms"
  fi
  read -r -a ents <<<"$(_prj_env_get "$tmpd/old" EXTRA_MOUNTS)" || true
  for e in ${ents[@]+"${ents[@]}"}; do
    d="$(_prj_mount_dir "$e")"; d="${d/#\~/$HOME}"
    [[ "$d" == /* ]] || continue
    for df in "$d" "$(_prj_phys "$d")"; do
      for pf in "$path" "$(_prj_phys "$path")"; do
        if _prj_within "$pf" "$df"; then PRJ_MOUNT_COVER="$e"; rm -rf "$tmpd"; return 0; fi
      done
    done
  done
  if [[ "$path" == *[[:space:]]* ]]; then
    rm -rf "$tmpd"
    printf 'ERROR: %s holds whitespace, which separates EXTRA_MOUNTS entries; it cannot be one.\n' "$(_ac_term "$path")" >&2
    return 1
  fi
  # A path holding ':' takes its mode: sandbox.sh would read a last part such as
  # `ro` as one.
  entry="$path"; if [[ "$path" == *:* ]]; then entry="$path:rw"; fi
  list="${ents[*]-}"; list="${list:+$list }$entry"
  if ! _prj_mounts_rewrite "$tmpd/old" "$list" > "$tmpd/new"; then bad=1; fi
  if [[ "$(_prj_env_dump "$tmpd/old" EXTRA_MOUNTS)" != "$(_prj_env_dump "$tmpd/new" EXTRA_MOUNTS)" ]]; then bad=1; fi
  read -r -a got <<<"$(_prj_env_get "$tmpd/new" EXTRA_MOUNTS)" || true
  if [[ "$(printf '[%q]' ${got[@]+"${got[@]}"})" != "$(printf '[%q]' ${ents[@]+"${ents[@]}"} "$entry")" ]]; then bad=1; fi
  if (( bad )); then
    rm -rf "$tmpd"
    printf 'ERROR: %s with %s added to EXTRA_MOUNTS would not read back as written; it is left as it is.\n' \
      "$(_ac_term "$file")" "$(_ac_term "$path")" >&2
    return 1
  fi
  if [[ "$mode" != check ]] && ! _proj_write "$tmpd/new" "$file" "$perms"; then
    rm -rf "$tmpd"
    printf 'ERROR: could not write %s.\n' "$(_ac_term "$file")" >&2
    return 1
  fi
  rm -rf "$tmpd"
}

# _prj_tracks_dot <root>: rc 0 when the repository whose work tree is <root> — a
# .git there, as ensure_ai_containers_ignored() takes one — records anything
# under .ai-containers/ in its index (_proj_index_tracks, which reads the index
# with no repository). What cannot be read counts as no.
_prj_tracks_dot() {
  local root="$1" gd="" cdir=""
  if [[ -L "$root/.git" ]]; then return 1
  elif [[ -d "$root/.git" ]]; then gd="$root/.git"
  elif [[ -f "$root/.git" ]]; then
    if ! _proj_ptr "$root/.git" gd || [[ "$gd" != "gitdir: "* ]] || ! _proj_resolve "$root" "${gd#gitdir: }" gd; then return 1; fi
  else return 1; fi
  _proj_common "$gd" cdir || return 1
  _proj_index_tracks "$gd" "$cdir"
}

# cmd_mv <project> <new-dir> [--yes]: move a project's setup to
# <new-dir>/.ai-containers, with what is tied to where it lived: its working
# copies (named after the launch directory), its projects.conf line, its image
# (whose label is the old place's id) and image-projects.conf line. The directory
# it leaves is added to EXTRA_MOUNTS, so the container still sees it — unless an
# entry covers it or it lies inside <new-dir> — or removed, when .ai-containers was
# all it held; one that cannot be an entry is refused, and so is what the launcher
# would resolve against the moved launch directory. A project already moved by hand (<project>
# holds no .ai-containers, <new-dir> does) gets all of that but the move, its old
# path registered or not (gc may have dropped its line). Everything is listed
# first. Nothing old goes before what replaces it is checked: the working copies
# are copied and checked, then the directory moved (across filesystems: copied,
# checked, and only then removed), then the old copies removed. A failure before
# the move undoes the copies; one after it leaves what a re-run — which then
# finds the project already moved — finishes.
cmd_mv() {
  local arg="" narg="" assume_yes=0 a
  for a in "$@"; do
    case "$a" in
      --yes|-y) assume_yes=1 ;;
      -*) printf 'ERROR: unknown flag %s\n' "$(_ac_term "$a")" >&2; exit 1 ;;
      *) if [[ -z "$arg" ]]; then arg="$a"
         elif [[ -z "$narg" ]]; then narg="$a"
         else printf 'ERROR: unexpected argument %s\n' "$(_ac_term "$a")" >&2; exit 1; fi ;;
    esac
  done
  if [[ -z "$arg" || -z "$narg" ]]; then
    printf 'ERROR: usage: ./project.sh mv <project> <new-dir> [--yes]\n' >&2; exit 1
  fi
  prj_resolve "$arg" unregistered-ok
  local old_root old_dot new_root new_dot reg=0 new_reg=0 moved=0
  old_root="$(_prj_strip "$PRJ_ROOT")"
  if _prj_registered "$PRJ_ROOT"; then reg=1
  # Not registered: spelled as given, as <new-dir> is, not as prj_resolve's
  # physical path — it is what goes into EXTRA_MOUNTS.
  elif old_root="$(_prj_logical "$arg")"; then PRJ_ROOT="$old_root"
  else old_root="$(_prj_strip "$PRJ_ROOT")"; fi
  old_dot="${old_root%/}/.ai-containers"
  if ! new_root="$(_prj_logical "$narg")"; then
    printf 'ERROR: "%s" holds a . or .. where it does not exist yet; give it without them.\n' "$(_ac_term "$narg")" >&2
    exit 1
  fi
  new_dot="${new_root%/}/.ai-containers"
  if _prj_registered "$new_root"; then new_reg=1; fi
  local t_old t_new t_odot t_ndot
  t_old="$(_ac_term "$old_root")"; t_new="$(_ac_term "$new_root")"
  t_odot="$(_ac_term "$old_dot")"; t_ndot="$(_ac_term "$new_dot")"

  # Neither end may be ~/.ai-containers, hold the engine, or be a link.
  if (( reg )); then _prj_guard "$PRJ_ROOT" "the registered root" move registered
  else _prj_guard "$PRJ_ROOT" "the project root" move; fi
  _prj_guard "$new_root" "the new directory" move
  # A link there could be repointed between the checks and the move.
  if [[ -L "$new_root" ]]; then
    printf 'ERROR: %s is a link; give the directory itself (%s), or another, as <new-dir>.\n' \
      "$t_new" "$(_ac_term "$(_prj_phys "$new_root")")" >&2
    printf '       Nothing was changed.\n' >&2
    exit 1
  fi
  if [[ "$(_prj_phys "$old_root")" == "$(_prj_phys "$new_root")" ]]; then
    printf 'ERROR: %s is the project'"'"'s own directory (%s); its setup is already there.\n' "$t_new" "$t_old" >&2
    exit 1
  fi
  if _prj_within "$new_root" "$old_dot" || _prj_within "$(_prj_phys "$new_root")" "$(_prj_phys "$old_dot")"; then
    printf 'ERROR: %s lies inside %s, which is what moves; refusing.\n' "$t_new" "$t_odot" >&2
    exit 1
  fi
  # Which case: a move, or one already made by hand.
  if [[ -d "$old_dot" && -d "$new_dot" ]]; then
    printf 'ERROR: both %s and %s exist; remove or move one of them first. Nothing was changed.\n' "$t_odot" "$t_ndot" >&2
    exit 1
  fi
  if [[ ! -d "$old_dot" && -d "$new_dot" ]]; then moved=1; fi
  if (( ! moved && ! reg )); then
    printf 'ERROR: "%s" is not a registered project (see %s), and %s holds no .ai-containers it was moved to.\n' \
      "$(_ac_term "$arg")" "$prj_conf" "$t_new" >&2
    exit 1
  fi
  if (( ! moved )) && [[ ! -d "$old_dot" ]]; then
    printf 'ERROR: neither %s nor %s exists; there is nothing to move.\n' "$t_odot" "$t_ndot" >&2
    exit 1
  fi
  local src_dot="$old_dot"; if (( moved )); then src_dot="$new_dot"; fi
  # What the launcher resolves against the launch directory ($PWD, the
  # .ai-containers that moves) would name another directory after the move, or
  # none: a relative EXTRA_MOUNTS entry or pointer. And a working directory other
  # than the project itself leaves the project's mounts unknown here.
  local e d v k lf="$src_dot/sandbox.local.env"
  local -a em=()
  read -r -d '' -a em < <(prj_env "$src_dot" EXTRA_MOUNTS) || true
  for e in ${em[@]+"${em[@]}"}; do
    d="$(_prj_mount_dir "$e")"
    if [[ "$d" != /* && "$d" != '~'* ]]; then
      printf 'ERROR: the EXTRA_MOUNTS entry %s in %s is relative: the launcher resolves it against\n' "$(_ac_term "$e")" "$(_ac_term "$lf")" >&2
      printf '       the launch directory, which moves, so it would name another directory. Make it absolute,\n' >&2
      printf '       then run this again. Nothing was changed.\n' >&2
      exit 1
    fi
  done
  for k in VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH; do
    v="$(_prj_env_get "$lf" "$k")"; v="${v%:ro}"; v="${v%:rw}"
    if [[ -n "$v" && "$v" != /* && "$v" != '~'* && "$v" != @* ]]; then
      printf 'ERROR: %s=%s in %s is relative: the launcher resolves it against the launch directory,\n' "$k" "$(_ac_term "$v")" "$(_ac_term "$lf")" >&2
      printf '       which moves, so it would name another directory. Make it absolute, then run this again.\n' >&2
      printf '       Nothing was changed.\n' >&2
      exit 1
    fi
  done
  v="$(_prj_env_get "$lf" SANDBOX_WORKDIR)"
  if [[ -n "$v" && "$v" != .. && "$v" != ../ ]]; then
    printf 'ERROR: SANDBOX_WORKDIR=%s in %s: mv handles only a project whose working directory is\n' "$(_ac_term "$v")" "$(_ac_term "$lf")" >&2
    printf '       the project itself (..), which it checks the names mounted beside against. Set it to .. or\n' >&2
    printf '       remove it, move, then set it again. Nothing was changed.\n' >&2
    exit 1
  fi
  if ! docker volume ls --quiet >/dev/null 2>&1; then
    printf 'ERROR: docker cannot be reached, so neither the project'"'"'s running containers nor its working\n' >&2
    printf '       copies can be checked; refusing. Start docker and run this again.\n' >&2
    exit 1
  fi
  _prj_refuse_running "" "$old_root"
  _prj_refuse_running "" "$new_root"

  # What there is, and what becomes of it — gathered before anything changes.
  # The image: only one whose label is the old place's id goes (img_ok).
  local img="" id nid why="" img_ok=0 ip_path
  id="$(prj_id "$old_dot")" || id=""
  nid="$(prj_id "$new_dot")" || nid=""
  if _prj_has_env "$src_dot"; then
    img="$(prj_env "$src_dot" IMAGE_NAME ai-sandbox)"
    if why="$(_prj_image_why "$img" "$id")"; then img_ok=1
    elif [[ -n "$nid" ]] && _prj_image_why "$img" "$nid" >/dev/null; then why="it was built for the new place already"; fi
  fi
  ip_path="$(_prj_ip_path "$id")"

  # The working copies launched from under the old .ai-containers (or from under
  # an old root that is gone) take the name a launch from the new place uses.
  docker_volume_labels_load
  local wc ldir nl repo i
  local -a wc_old=() wc_new=() wc_repo=() wc_ldir=() wc_done=() stay=() stay_why=()
  while IFS= read -r wc; do
    [[ -n "$wc" ]] || continue
    ldir="$(docker_volume_label "$wc" 'ai-containers.launch-dir')"
    nl="$(_prj_rebase "$ldir" "$old_dot" "$new_dot")"
    if [[ -z "$nl" && ! -e "$old_root" ]]; then nl="$(_prj_rebase "$ldir" "$old_root" "$new_root")"; fi
    repo="$(docker_volume_label "$wc" 'ai-containers.repo')"
    if [[ -z "$nl" ]]; then
      stay+=("$wc"); stay_why+=("($(_ac_term "${repo:-?}")) — stays: launched from $(_ac_term "$ldir"), which does not move"); continue
    fi
    if [[ -z "$repo" ]]; then
      stay+=("$wc"); stay_why+=("— stays: it carries no ai-containers.repo label, so its new name cannot be told"); continue
    fi
    wc_old+=("$wc"); wc_repo+=("$repo"); wc_ldir+=("$nl")
    wc_new+=("$(repo_workcopy_volume_name "$repo" "$(workcopy_tag "$nl")")"); wc_done+=("")
  done < <(prj_workcopies "$old_root")
  if (( ${#wc_old[@]} )); then
    prj_seed_ready
    if [[ "$_prj_seed_state" != ok ]]; then
      printf 'ERROR: the seed helper image (%s) could not be had, so the working copies cannot be copied;\n' "$(_ac_term "$seed_image")" >&2
      printf '       refusing. Nothing was changed.\n' >&2
      exit 1
    fi
  fi
  # A new name already taken: by an exact copy, labelled for the new place, a run
  # cut short made — done; by anything else, refused: it may hold work too.
  for i in "${!wc_old[@]}"; do
    docker_volume_present "${wc_new[i]}" || continue
    if [[ "$(docker_volume_label "${wc_new[i]}" 'ai-containers.workcopy')" == 1 \
          && "$(docker_volume_label "${wc_new[i]}" 'ai-containers.repo')" == "${wc_repo[i]}" \
          && "$(docker_volume_label "${wc_new[i]}" 'ai-containers.launch-dir')" == "${wc_ldir[i]}" ]] \
       && prj_copy_check "${wc_old[i]}" "${wc_new[i]}"; then
      wc_done[i]=1; continue
    fi
    printf 'ERROR: the working copy %s would be copied to %s, which exists and is not an exact copy of it\n' \
      "$(_ac_term "${wc_old[i]}")" "$(_ac_term "${wc_new[i]}")" >&2
    printf '       (a launch from %s made it?); refusing. Nothing was changed. If it holds nothing you\n' "$t_ndot" >&2
    printf '       need, remove it (docker volume rm %s) and run this again.\n' "$(_ac_term "${wc_new[i]}")" >&2
    exit 1
  done

  # The directory left behind: gone, left empty (removed once the rest is done),
  # inside <new-dir> (the container mounts it there), or added to EXTRA_MOUNTS —
  # unless an entry covers it. One that cannot be an entry (whitespace) is
  # refused: it is usually the project's code, and no edit could mount it.
  local rm_old_root=0 add_mount=0 cover="" inside=0
  if [[ -d "$old_root" ]]; then
    if [[ ! -L "$old_root" ]] && _prj_only_dot "$old_root"; then rm_old_root=1
    elif _prj_within "$old_root" "$new_root" || _prj_within "$(_prj_phys "$old_root")" "$(_prj_phys "$new_root")"; then inside=1
    elif ! prj_add_mount "$src_dot" "$old_root" check; then
      if [[ "$old_root" == *[[:space:]]* ]]; then
        printf '       It would have to be one for the container to still see it once its setup moves; rename\n' >&2
        printf '       that directory, or choose a <new-dir> that holds it.\n' >&2
      fi
      printf '       Nothing was changed.\n' >&2
      exit 1
    else
      cover="$PRJ_MOUNT_COVER"
      if [[ -z "$cover" ]]; then add_mount=1; fi
    fi
  fi
  # One name the launcher would mount twice under /workspace makes every launch
  # fail: the new root (the working directory), the old root if added, each
  # EXTRA_MOUNTS entry, each REPOS repo.
  local nb ob n_set
  local -a names=() whats=() rp=()
  nb="$(_prj_base "$new_root")"; ob="$(_prj_base "$old_root")"
  read -r -d '' -a rp < <(prj_env "$src_dot" REPOS) || true
  for e in ${em[@]+"${em[@]}"}; do names+=("$(_prj_base "$(_prj_mount_dir "$e")")"); whats+=("the EXTRA_MOUNTS entry $e"); done
  for e in ${rp[@]+"${rp[@]}"}; do names+=("${e%%:*}"); whats+=("the REPOS repo ${e%%:*}"); done
  n_set=${#names[@]}
  if (( add_mount )); then names+=("$ob"); whats+=("$old_root, which mv adds to EXTRA_MOUNTS"); fi
  # The new root against everything else mounted; the old root, when added,
  # against what the project already mounts.
  for i in "${!names[@]}"; do
    if [[ "${names[i]}" == "$nb" ]]; then
      printf 'ERROR: %s and %s would both be mounted at /workspace/%s, which the\n' "$t_new" "$(_ac_term "${whats[i]}")" "$(_ac_term "$nb")" >&2
      printf '       launcher refuses; refusing. Choose another <new-dir>. Nothing was changed.\n' >&2
      exit 1
    fi
  done
  for (( i = 0; add_mount && i < n_set; i++ )); do
    if [[ "${names[i]}" == "$ob" ]]; then
      printf 'ERROR: %s, which mv would add to EXTRA_MOUNTS, and %s would both be mounted at\n' "$t_old" "$(_ac_term "${whats[i]}")" >&2
      printf '       /workspace/%s, which the launcher refuses; refusing. Nothing was changed.\n' "$(_ac_term "$ob")" >&2
      exit 1
    fi
  done
  # The new root must be one that can be made, or written in.
  if (( ! moved )); then
    local up="$new_root"
    while [[ ! -e "$up" && "$up" != / ]]; do up="${up%/*}"; up="${up:-/}"; done
    if [[ ! -d "$up" || ! -w "$up" ]]; then
      printf 'ERROR: %s cannot be made or written in (%s is not a directory you can write); refusing.\n' "$t_new" "$(_ac_term "$up")" >&2
      exit 1
    fi
  fi

  printf 'About to move project %s to %s:\n' "$t_old" "$t_new"
  if (( moved )); then printf '  directory   %s (already there; nothing to move)\n' "$t_ndot"
  else printf '  directory   %s → %s\n' "$t_odot" "$t_ndot"; fi
  if (( rm_old_root )); then printf '  directory   %s (it holds nothing else once .ai-containers is moved)\n' "$t_old"; fi
  if (( reg && ! new_reg )); then printf '  registry    %s → %s (projects.conf, the line rewritten)\n' "$t_old" "$t_new"
  elif (( reg )); then printf '  registry    %s (projects.conf, its line removed: %s is there already)\n' "$t_old" "$t_new"
  elif (( ! new_reg )); then printf '  registry    %s (projects.conf, added)\n' "$t_new"; fi
  if [[ -n "$ip_path" ]]; then
    printf '  registry    %s (image-projects.conf, once no image carries its id)\n' "$(_ac_term "$ip_path")"
  fi
  if [[ -z "$img" ]]; then printf '  image       (unknown — no sandbox.env; ./project.sh gc removes it by its label)\n'
  elif (( img_ok )); then printf '  image       %s (removed; the next ./build.sh builds it again)\n' "$(_ac_term "$img")"
  else printf '  image       %s — kept: %s\n' "$(_ac_term "$img")" "$why"; fi
  for i in "${!wc_old[@]}"; do
    printf '  working copy %s (%s) → %s%s\n' "$(_ac_term "${wc_old[i]}")" "$(_ac_term "${wc_repo[i]}")" \
      "$(_ac_term "${wc_new[i]}")" "${wc_done[i]:+ (copied already; the old one is removed)}"
  done
  for i in "${!stay[@]}"; do printf '  working copy %s %s\n' "$(_ac_term "${stay[i]}")" "${stay_why[i]}"; done
  if (( add_mount )); then printf '  EXTRA_MOUNTS + %s (in %s/sandbox.local.env)\n' "$t_old" "$t_ndot"
  elif [[ -n "$cover" ]]; then printf '  EXTRA_MOUNTS %s is already covered by %s\n' "$t_old" "$(_ac_term "$cover")"
  elif (( inside )); then printf '  EXTRA_MOUNTS %s lies inside %s, which the container mounts: nothing to add\n' "$t_old" "$t_new"
  fi

  if ! confirm "Move all of the above?"; then
    printf 'Nothing was changed.\n' >&2
    exit 1
  fi
  # A launch during the question would find its setup gone under it.
  _prj_refuse_running " (it started after the listing)" "$old_root"
  _prj_refuse_running " (it started after the listing)" "$new_root"

  local fail=0 leftover=0 mrc=0 first_made="" up2 old_int old_term
  local -a made=()
  # An interrupt removes the temp copy a move across filesystems makes in
  # <new-dir> (it holds sandbox.local.env). Set here and put back before this
  # returns: project.sh is sourced by tests, so never a global trap.
  old_int="$(trap -p INT)"; old_term="$(trap -p TERM)"
  trap '_prj_mv_interrupted 130' INT
  trap '_prj_mv_interrupted 143' TERM
  # 1. Copy the working copies, each checked. A failure undoes the copies made.
  for i in "${!wc_old[@]}"; do
    [[ -z "${wc_done[i]}" ]] || continue
    if ! prj_copy_volume "${wc_old[i]}" "${wc_new[i]}" "${wc_repo[i]}" "${wc_ldir[i]}"; then
      _prj_unmake ${made[@]+"${made[@]}"}
      printf 'ERROR: the working copy %s could not be copied (see above); nothing else was changed.\n' "$(_ac_term "${wc_old[i]}")" >&2
      exit 1
    fi
    made+=("${wc_new[i]}")
    printf 'Copied the working copy %s to %s, and checked the copy.\n' "$(_ac_term "${wc_old[i]}")" "$(_ac_term "${wc_new[i]}")"
  done
  # 2. Move the directory. A failure undoes the copies, and the directories
  #    mkdir -p made: the first of them is recorded, and all from <new-dir> up to
  #    it go, each only while empty.
  if (( ! moved )); then
    up2="$new_root"
    while [[ ! -e "$up2" && ! -L "$up2" && "$up2" != / ]]; do first_made="$up2"; up2="${up2%/*}"; up2="${up2:-/}"; done
    if ! mkdir -p -- "$new_root"; then
      _prj_rmdirs "$new_root" "$first_made"
      _prj_unmake ${made[@]+"${made[@]}"}
      printf 'ERROR: could not make %s; nothing was changed.\n' "$t_new" >&2
      exit 1
    fi
    _prj_move_dot "$old_dot" "$new_root" || mrc=$?
    if (( mrc == 1 )); then
      _prj_rmdirs "$new_root" "$first_made"
      _prj_unmake ${made[@]+"${made[@]}"}
      printf 'ERROR: %s is not at %s (see above); the registry and the working copies are as they were.\n' "$t_odot" "$t_ndot" >&2
      exit 1
    fi
    printf 'Moved %s to %s.\n' "$t_odot" "$t_ndot"
    if (( mrc == 2 )); then
      printf 'ERROR: %s is checked and in place, but the old %s could not be removed entirely.\n' "$t_ndot" "$t_odot" >&2
      leftover=1
    fi
  fi
  # 3. The old working copies, each now copied and checked.
  for i in "${!wc_old[@]}"; do
    if docker volume rm "${wc_old[i]}" >/dev/null; then
      printf 'Removed the working copy %s (now %s).\n' "$(_ac_term "${wc_old[i]}")" "$(_ac_term "${wc_new[i]}")"
    else
      printf 'ERROR: could not remove the old working copy %s (in use?); %s is its checked copy.\n' \
        "$(_ac_term "${wc_old[i]}")" "$(_ac_term "${wc_new[i]}")" >&2
      fail=1
    fi
  done
  # 4. The directory it left, in EXTRA_MOUNTS.
  if (( add_mount )); then
    if ! prj_add_mount "$new_dot" "$old_root"; then
      printf 'ERROR: %s is not in EXTRA_MOUNTS yet (see above), and the registry is not changed;\n' "$t_old" >&2
      printf '       fix that and run ./project.sh mv %s %s again.\n' "$t_old" "$t_new" >&2
      exit 1
    fi
    if [[ -n "$PRJ_MOUNT_COVER" ]]; then
      printf 'EXTRA_MOUNTS already covers %s (%s).\n' "$t_old" "$(_ac_term "$PRJ_MOUNT_COVER")"
    else
      printf 'Added %s to EXTRA_MOUNTS in %s/sandbox.local.env.\n' "$t_old" "$t_ndot"
    fi
  fi
  # 5. The registry.
  if (( reg && ! new_reg )); then
    prj_conf_replace "$PRJ_ROOT" "$new_root" || exit 1
    printf 'Rewrote %s as %s in projects.conf.\n' "$t_old" "$t_new"
  elif (( reg )); then
    prj_conf_remove "$PRJ_ROOT" || exit 1
    printf 'Removed %s from projects.conf (%s is there already).\n' "$t_old" "$t_new"
  elif (( ! new_reg )); then
    prj_conf_add "$new_root" || exit 1
    printf 'Added %s to projects.conf.\n' "$t_new"
  fi
  # 6. The image built for the old place, then its image-projects.conf line once
  #    no image carries the old id: with the line gone and the image still there,
  #    build.sh would refuse to replace it (ENV-8).
  local rebuilt=0
  if (( img_ok )); then
    prj_image_remove "$img" "$id"
    rebuilt="$PRJ_IMAGE_REMOVED"
  fi
  if [[ -n "$id" && -n "$ip_path" ]] && ! _prj_ip_drop "$id" "$ip_path"; then
    printf '       Run ./project.sh mv %s %s again to finish.\n' "$t_old" "$t_new" >&2
    exit 1
  fi
  if (( rebuilt )); then
    printf 'NOTE: the next ./build.sh (runme.sh runs it) builds %s again, from the cache.\n' "$(_ac_term "$img")"
  fi
  # 7. The old root it left empty, after the image: removed even when the image
  #    stays, since build.sh's check walks up from the old .ai-containers to the
  #    nearest directory there is, and refuses where that is empty (a drive not
  #    mounted looks so) — the old root kept empty would be that directory.
  if (( rm_old_root && ! leftover )); then
    if [[ -d "$old_root" && ! -L "$old_root" ]] && rmdir -- "$old_root" 2>/dev/null; then
      printf 'Removed the empty directory %s.\n' "$t_old"
    else
      printf 'NOTE: %s was not removed: it is not empty now. Add it to EXTRA_MOUNTS if the container should see it.\n' "$t_old" >&2
    fi
  fi
  # An image kept with the old place's id that build.sh would still refuse to
  # replace — its walk ends on an empty directory — is said, with the way out:
  # asked of build.sh's own check (ai_containers_retag_check).
  if (( img_ok && ! rebuilt )) && ! ai_containers_retag_check "$img" "$(_prj_phys "$new_dot")" >/dev/null 2>&1; then
    printf 'NOTE: the next ./build.sh will refuse to replace %s, which was built for the old place: remove\n' "$(_ac_term "$img")"
    printf '      the container that keeps it (docker ps -a --filter ancestor=%s), then docker rmi %s.\n' \
      "$(_ac_term "$img")" "$(_ac_term "$img")"
  fi
  # 8. A repository the old root is, which recorded the files that moved.
  if [[ -d "$old_root" ]] && _prj_tracks_dot "$old_root"; then
    printf 'NOTE: %s'"'"'s repository tracks .ai-containers/; those files now show as deleted there.\n' "$t_old"
  fi
  if (( leftover )); then
    printf 'ERROR: what is left of %s is only a copy of %s now: remove it by hand.\n' "$t_odot" "$t_ndot" >&2
  fi
  if (( fail )); then
    if (( leftover )); then
      printf 'ERROR: not every old working copy could be removed (see above); once that leftover is gone, run\n' >&2
    else
      printf 'ERROR: not every old working copy could be removed (see above); once they can be, run\n' >&2
    fi
    printf '       ./project.sh mv %s %s again to remove them.\n' "$t_old" "$t_new" >&2
  fi
  if (( fail || leftover )); then exit 1; fi
  eval "${old_int:-trap - INT}"; eval "${old_term:-trap - TERM}"
  printf 'OK: moved project %s to %s.\n' "$t_old" "$t_new"
}

# _prj_mv_interrupted <status>: cmd_mv's INT and TERM trap — the temp copy a move
# across filesystems was making in <new-dir> goes; what was done before is above.
_prj_mv_interrupted() {
  if [[ -n "$_prj_mv_tmp" ]]; then rm -rf -- "$_prj_mv_tmp"; _prj_mv_tmp=""; fi
  printf '\nERROR: interrupted; what was done is listed above, and no temporary copy is left in <new-dir>.\n' >&2
  exit "$1"
}

# _prj_rmdirs <dir> <top>: remove <dir> and each directory above it up to <top>,
# each only while it is empty — what one mkdir -p made, <top> its first. Nothing
# when <top> is empty (mkdir -p made nothing).
_prj_rmdirs() {
  local d="$1"
  [[ -n "$2" ]] || return 0
  while rmdir -- "$d" 2>/dev/null; do
    [[ "$d" != "$2" ]] || break
    d="${d%/*}"
  done
  return 0
}

# ── gc: what points at projects that are gone ──

# _prj_maybe_unmounted <path>: why <path>, which is not there, may only look
# gone — the reason printed, rc 0 — or rc 1 when it is gone. The judgement
# ai_containers_retag_check() makes before it replaces an image built for a path
# that is not there (ENV-9), walked the same way: from the nearest directory
# above <path> that does exist, a drive that is not mounted looks like that
# directory EMPTY (its mount point stays) or a removable-media root
# (_ac_removable_root: the mount point went with the drive); and a path under a
# directory that cannot be searched only looks absent. Emptiness by a glob,
# which follows a link as the path does and has no failure to mistake for
# "empty". A path that is not absolute cannot be judged at all, and a walk up it
# would never end.
_prj_maybe_unmounted() {
  local up t
  if [[ "$1" != /* ]]; then printf 'it is not an absolute path, so where it is cannot be told'; return 0; fi
  up="$(_prj_strip "$1")"; up="${up%/*}"
  while [[ -n "$up" && ! -e "$up" ]]; do up="${up%/*}"; done
  [[ -n "$up" && -d "$up" ]] || return 1
  t="$(_ac_term "$up")"
  if [[ ! -x "$up" ]]; then printf 'it may only look gone: %s cannot be searched' "$t"; return 0; fi
  [[ -r "$up" ]] || return 1
  if _ac_removable_root "$up"; then
    printf 'it may be on a drive that is not mounted: %s is where removable drives are mounted' "$t"; return 0
  fi
  if ( shopt -s nullglob dotglob; _pu_e=("$up"/*); (( ${#_pu_e[@]} == 0 )) ); then
    printf 'it may be on a drive that is not mounted: %s is empty' "$t"; return 0
  fi
  return 1
}

# _prj_reg_bad <file>: why gc does not read that registry — a link, which
# _prj_rewrite would refuse to rewrite once copies and images were gone, or one
# that is not a regular file or cannot be read — printed, rc 0; rc 1 when it may
# be read, or is not there.
_prj_reg_bad() {
  if [[ -L "$1" ]]; then printf 'it is a link'; return 0; fi
  [[ -e "$1" ]] || return 1
  if [[ ! -f "$1" ]]; then printf 'it is not a regular file'; return 0; fi
  if [[ ! -r "$1" ]]; then printf 'it cannot be read'; return 0; fi
  return 1
}

# _prj_vol_users <volume>: the running containers that mount it, one name per
# line; rc 0 when any does, 1 when none, 2 when docker could not list them —
# never read as none, which is what docker_volume_in_use() makes of a failure.
_prj_vol_users() {
  local out
  out="$(docker ps --filter "volume=$1" --format '{{.Names}}' 2>/dev/null)" || return 2
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# _prj_id_images <id>: the local images whose ai-containers.project label is
# <id>, one reference per line, each once: repository:tag for each tag of a
# tagged one, the image id for one with none (the image a later build replaced,
# which a container kept then). By reference, not by id: docker rmi refuses an
# id that more than one tag names, without --force. rc 1 when docker could not
# list them.
_prj_id_images() {
  local out line ref
  local -A seen=()
  out="$(docker images --filter "label=ai-containers.project=$1" --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null)" || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ref="${line#* }"
    if [[ "$ref" == "$line" || "$ref" == *'<none>'* ]]; then ref="${line%% *}"; fi
    [[ -z "${seen["$ref"]+x}" ]] || continue
    seen["$ref"]=1
    printf '%s\n' "$ref"
  done <<< "$out"
  return 0
}

# cmd_gc [--yes]: remove what points at projects that are gone — the projects.conf
# lines whose project has no .ai-containers, the working copies launched from a
# directory that is gone, and the images built for a path image-projects.conf
# maps that is gone, then those lines once no image carries their id — after
# listing all of it, with what each working copy would lose, and what is kept: a
# path that may only look gone (a drive not mounted, a directory that cannot be
# searched), a working copy a running container uses, a .ai-containers that is a
# link. An image-projects.conf line's id is the one it records: the path it maps
# is gone, and the id is what the images carry. Ordered as rm is, so a failure
# part-way leaves what a re-run needs: the working copies (one that cannot be
# removed stops it), the images, the image-projects.conf lines, the projects.conf
# lines.
cmd_gc() {
  local assume_yes=0 a
  for a in "$@"; do
    case "$a" in
      --yes|-y) assume_yes=1 ;;
      -*) printf 'ERROR: unknown flag %s\n' "$(_ac_term "$a")" >&2; exit 1 ;;
      *) printf 'ERROR: unexpected argument %s (usage: ./project.sh gc [--yes])\n' "$(_ac_term "$a")" >&2; exit 1 ;;
    esac
  done
  if ! docker volume ls --quiet >/dev/null 2>&1; then
    printf 'ERROR: docker cannot be reached, so neither the working copies nor the images can be checked;\n' >&2
    printf '       refusing. Start docker and run this again.\n' >&2
    exit 1
  fi
  # What is gone, and what is kept — gathered before anything goes. Every value
  # printed comes from a file or a label, so through _ac_term.
  local -a kept=() pdrop=() imgs=() img_ids=() img_lines=() ipd=() ipd_path=() copies=() copy_desc=() risks=()
  local r root dot why t

  # 1. projects.conf: a line whose project has no .ai-containers.
  local -A seen=()
  if why="$(_prj_reg_bad "$prj_conf")"; then
    kept+=("  registry    $(_ac_term "$prj_conf") — not read: $why")
  else
    while IFS= read -r r; do
      [[ -z "${seen["$r"]+x}" ]] || continue
      seen["$r"]=1
      root="$(_prj_strip "$r")"; dot="${root%/}/.ai-containers"; t="$(_ac_term "$r")"
      if [[ "$root" == /* && -L "$dot" ]]; then
        kept+=("  registry    $t (projects.conf) — kept: its .ai-containers is a link, which ./project.sh rm and mv refuse")
      elif [[ "$root" == /* && -d "$dot" ]]; then
        continue
      elif why="$(_prj_maybe_unmounted "$dot")"; then
        if [[ "$root" == /* ]]; then why+="; if it is gone for good, ./project.sh rm $t removes its line"; fi
        kept+=("  registry    $t (projects.conf) — kept: $why")
      else
        pdrop+=("$r")
      fi
    done < <(prj_roots)
  fi

  # 2. image-projects.conf: an id whose every line maps a path that is gone. Its
  #    images go first, and the line once none carries the id (_prj_ip_drop).
  local line id path refs ref
  local -a ip_ids=()
  local -A ip_st=() ip_why=() ip_p=()
  if why="$(_prj_reg_bad "$image_projects_file")"; then
    kept+=("  registry    $(_ac_term "$image_projects_file") — not read: $why")
  elif [[ -f "$image_projects_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ "$line" == *'|'* && "$line" != '#'* ]] || continue
      id="${line%%|*}"; path="${line#*|}"
      [[ -n "$id" ]] || continue
      if [[ -z "${ip_st["$id"]+x}" ]]; then ip_ids+=("$id"); ip_st["$id"]=gone; ip_p["$id"]="$path"; fi
      if [[ "$path" == /* ]] && [[ -e "$path" || -L "$path" ]]; then
        ip_st["$id"]=live
      elif [[ "${ip_st["$id"]}" == gone ]] && why="$(_prj_maybe_unmounted "$path")"; then
        ip_st["$id"]=kept; ip_why["$id"]="$why"; ip_p["$id"]="$path"
      fi
    done < "$image_projects_file"
  fi
  for id in ${ip_ids[@]+"${ip_ids[@]}"}; do
    path="${ip_p["$id"]}"; t="$(_ac_term "$path")"
    case "${ip_st["$id"]}" in
      kept)
        if refs="$(_prj_id_images "$id")"; then
          while IFS= read -r ref; do
            if [[ -n "$ref" ]]; then kept+=("  image       $(_ac_term "$ref") (built for $t) — kept: ${ip_why["$id"]}"); fi
          done <<< "$refs"
        fi
        kept+=("  registry    $t (image-projects.conf) — kept: ${ip_why["$id"]}") ;;
      gone)
        if ! refs="$(_prj_id_images "$id")"; then
          kept+=("  registry    $t (image-projects.conf) — kept: docker could not list the images that carry its id")
          continue
        fi
        while IFS= read -r ref; do
          [[ -n "$ref" ]] || continue
          if why="$(_prj_image_why "$ref" "$id")"; then
            imgs+=("$ref"); img_ids+=("$id"); img_lines+=("  image       $(_ac_term "$ref") (built for $t, which is gone)")
          else
            kept+=("  image       $(_ac_term "$ref") — kept: $why")
          fi
        done <<< "$refs"
        ipd+=("$id"); ipd_path+=("$path") ;;
    esac
  done

  # 3. The working copies launched from a directory that is gone, unless it may
  #    only look gone or a running container uses the copy (or docker cannot tell).
  local v ldir repo desc users urc
  docker_volume_labels_load
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    ldir="$(docker_volume_label "$v" 'ai-containers.launch-dir')"
    [[ "$ldir" == /* ]] || continue
    if [[ -e "$ldir" || -L "$ldir" ]]; then continue; fi
    repo="$(docker_volume_label "$v" 'ai-containers.repo')"
    desc="$(_ac_term "$v") ($(_ac_term "${repo:-?}"), launched from $(_ac_term "$ldir"))"
    if why="$(_prj_maybe_unmounted "$ldir")"; then kept+=("  working copy $desc — kept: $why"); continue; fi
    urc=0; users="$(_prj_vol_users "$v")" || urc=$?
    case "$urc" in
      1) copies+=("$v"); copy_desc+=("$desc") ;;
      0) kept+=("  working copy $desc — kept: a running container uses it ($(_ac_term "$(printf '%s' "$users" | tr '\n' ' ' | sed 's/ $//')"))") ;;
      *) kept+=("  working copy $desc — kept: docker could not list the running containers, so whether one uses it cannot be told") ;;
    esac
  done < <(repo_workcopy_volumes)
  local i risk at_risk=0
  # Once for every copy; a seed image that cannot be had makes them "not checked".
  if (( ${#copies[@]} )); then prj_seed_ready; fi
  for i in "${!copies[@]}"; do
    if risk="$(prj_copy_risk "${copies[i]}")"; then :; else at_risk=$((at_risk + 1)); fi
    risks[i]="$risk"
  done

  if (( ${#kept[@]} )); then
    printf 'Kept:\n'
    printf '%s\n' "${kept[@]}"
  fi
  if (( ${#pdrop[@]} + ${#imgs[@]} + ${#ipd[@]} + ${#copies[@]} == 0 )); then
    printf 'Nothing to collect.\n'
    return 0
  fi
  printf 'About to remove:\n'
  for r in ${pdrop[@]+"${pdrop[@]}"}; do
    t="$(_ac_term "$r")"
    printf '  registry    %s (projects.conf: it has no .ai-containers)\n' "$t"
    printf '              If %s was moved rather than deleted, answer no and run ./project.sh mv %s <new-dir> (it also works after gc).\n' "$t" "$t"
  done
  for line in ${img_lines[@]+"${img_lines[@]}"}; do printf '%s\n' "$line"; done
  for i in "${!ipd[@]}"; do
    printf '  registry    %s (image-projects.conf, once no image carries its id)\n' "$(_ac_term "${ipd_path[i]}")"
  done
  for i in "${!copies[@]}"; do printf '  working copy %s — %s\n' "${copy_desc[i]}" "${risks[i]}"; done
  if (( at_risk )); then printf '%d working cop(y/ies) at risk or not checked.\n' "$at_risk"; fi

  if ! confirm "Remove everything listed under About to remove?"; then
    printf 'Nothing was removed.\n' >&2
    exit 1
  fi
  # A launch during the question (a project moved by hand, launched from where
  # it is now, reattaching nothing — or a sibling container) would lose its copy.
  for v in ${copies[@]+"${copies[@]}"}; do
    urc=0; users="$(_prj_vol_users "$v")" || urc=$?
    case "$urc" in
      1) ;;
      0) printf 'ERROR: a container started using the working copy %s after the listing: %s. Stop it first;\n' \
           "$(_ac_term "$v")" "$(_ac_term "$(printf '%s' "$users" | tr '\n' ' ' | sed 's/ $//')")" >&2
         printf '       nothing was removed.\n' >&2
         exit 1 ;;
      *) printf 'ERROR: docker could not list the running containers, so whether one uses the working copy %s\n' "$(_ac_term "$v")" >&2
         printf '       cannot be told; refusing. Nothing was removed.\n' >&2
         exit 1 ;;
    esac
  done

  # 1. The working copies. A failure stops everything: the images and registry
  #    lines stay, so a re-run lists them again.
  for v in ${copies[@]+"${copies[@]}"}; do
    if ! docker volume rm "$v" >/dev/null; then
      printf 'ERROR: could not remove the working copy %s (in use?). The images and registry lines listed\n' "$(_ac_term "$v")" >&2
      printf '       are kept; run ./project.sh gc again once it can be.\n' >&2
      exit 1
    fi
    printf 'Removed the working copy %s.\n' "$(_ac_term "$v")"
  done
  # 2. The images (prj_image_remove checks each label again).
  for i in "${!imgs[@]}"; do prj_image_remove "${imgs[i]}" "${img_ids[i]}"; done
  # 3. The image-projects.conf lines, each once no image carries its id: an image
  #    left with the id and no line names nothing build.sh can judge (ENV-8).
  for i in "${!ipd[@]}"; do
    if ! _prj_ip_drop "${ipd[i]}" "${ipd_path[i]}"; then
      printf '       The projects.conf lines are kept; run ./project.sh gc again.\n' >&2
      exit 1
    fi
  done
  # 4. The projects.conf lines.
  for r in ${pdrop[@]+"${pdrop[@]}"}; do
    prj_conf_remove "$r" || exit 1
    printf 'Removed %s from projects.conf.\n' "$(_ac_term "$r")"
  done
  printf 'OK: removed what pointed at projects that are gone.\n'
}

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
