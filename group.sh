#!/usr/bin/env bash
set -euo pipefail
unset CDPATH  # a relative cd follows it and prints the directory (bugs review GIT-17, GIT-20)

# group.sh — manage AI sandbox container groups and the resources they own.
#
# A container group is a named directory under ~/.ai-containers/<group>/ holding
# the agent dotfile trees (.claude, .codex, .copilot, .config/gh, .ssh, .agents, …)
# that get mounted into the container. Selected at run time with
# AI_CONTAINER_GROUP; see docs/groups.md.
#
# A group used to be ONLY a directory, so `rm -rf ~/.ai-containers/<group>` was the
# whole story. That stopped being true when the group's Ruby home (~/.rvm) moved to
# a Docker named volume (it cannot live on a macOS bind mount — see the tar/virtiofs
# note on rvm_volume_name in sandbox-common.sh), and again when its /var/tmp did, for
# the same reason. A group now owns a directory and up to two volumes, Ruby and
# temp, and deleting the directory leaves a volume orphaned with nothing pointing
# at it. This script keeps them in step: 'rm' removes them all (keeping a volume
# another home made), and 'gc' finds volumes whose group is already gone. Each
# volume is judged on its own, by the same helpers.
#
# A temp volume is the group's by its ai-containers.vartmp-group label alone, which
# the launch puts on it (sandbox-common.sh: `vartmp_volume_ensure()`), never by its
# name: one of the name without that label was made outside a launch, and is named,
# never removed.
#
# Scope: groups and their volumes ONLY. Repo volumes are a separate, global
# resource with their own lifecycle — use repo.sh for those. They never overlap:
# repo volumes are named "<prefix>-repo-<name>", Ruby volumes "<prefix>-rvm-<group>"
# and temp volumes "<prefix>-vartmp-<group>", and each tool's discovery filters on
# its own infix.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sandbox-common.sh
source "${_here}/sandbox-common.sh"

groups_root="$HOME/.ai-containers"

usage() {
  cat <<'EOF'
Usage:
  ./group.sh list [--sizes]          List container groups and their Ruby and temp volumes
  ./group.sh rm <group> [--yes]      Remove a group: its directory, its Ruby volume and its temp volume
  ./group.sh gc [--all] [--yes]      Remove this home's Ruby and temp volumes whose group directory is gone

Notes:
  - A group owns up to three things: the directory ~/.ai-containers/<group>/;
    the Docker volume holding its containers' /var/tmp, which its first launch
    makes; and, once you have built with a ruby= version, the Docker volume
    holding its Ruby home. 'rm' removes all three, but keeps a volume another
    home on this docker made; deleting the directory by hand orphans the
    volumes ('gc' cleans those up afterwards).
  - A temp volume is known by the label its launch puts on it. A volume of its
    name without that label was made some other way (a `docker run -v` of it):
    'list' shows it as not the group's, 'rm' names it with the command that
    removes it, and neither 'rm' nor 'gc' ever removes it.
  - 'rm' refuses while a running container still mounts a volume it would
    remove.
  - 'host' is not a group (it once meant "mount my real $HOME", and is no longer
    supported), so it is never removed here.
  - One docker may serve several homes (Docker Desktop's, by every WSL distro),
    and a group directory missing here may be another home's group. So 'gc'
    takes only the volumes this home made, by their ai-containers.owner label;
    another home's, and one made before that label, are kept and named, and
    --all takes them too.
  - Repo volumes are NOT touched: they are global, shared across every group, and
    managed with ./repo.sh.
EOF
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

# Echo each existing group name (directory basename), one per line.
group_names() {
  [[ -d "$groups_root" ]] || return 0
  local d
  for d in "$groups_root"/*/; do
    [[ -d "$d" ]] || continue
    printf '%s\n' "$(basename "$d")"
  done
}

# _vol_owner_why <volume> <this home's id>: why gc keeps an orphaned Ruby or temp
# volume that is not this home's, printed, rc 0; rc 1 when it is this home's. One
# daemon serves several homes (Docker Desktop's, by every WSL distro), so a group
# directory missing here may be another home's group (bugs review PRJ-16); one
# made before owner labels cannot be told apart, and is kept unless --all.
_vol_owner_why() {
  _owner_why "$(docker_volume_label "$1" 'ai-containers.owner')" "$2"
}

# _owner_why <owner label> <this home's id>: _vol_owner_why on a label already read.
_owner_why() {
  if [[ -z "$1" ]]; then printf 'no owner label'; return 0; fi
  if [[ -z "$2" || "$1" != "$2" ]]; then printf "another home's"; return 0; fi
  return 1
}

# _vol_label <volume> <key>: the label's value, empty when unset; rc 1 when
# docker cannot say. sandbox-common.sh: `docker_volume_label()` reads a failure
# as no label, which is what rm and list must not do: a docker that answered
# whether the volume exists and then cannot say whose it is would have the
# group's own temp volume read as not the group's, and another home's Ruby
# volume as one with no owner label, which rm removes.
_vol_label() {
  docker volume inspect --format "{{if .Labels}}{{index .Labels \"$2\"}}{{end}}" "$1" 2>/dev/null
}

# _whose_say <why>: _vol_owner_why's answer, said for a volume --all takes.
_whose_say() {
  case "$1" in
    "no owner label") printf 'no owner label: it may be another home'"'"'s' ;;
    *)                printf "another home's: its group of that name may use it" ;;
  esac
}

# _no_key_note <this home's id>: with no owner key (~/.ai-containers/project-id.key,
# lost with an rm -rf of ~/.ai-containers), this home's own labelled volumes
# cannot be told from another home's, and are said to be another's.
_no_key_note() {
  [[ -z "$1" ]] || return 0
  printf 'NOTE: this home has no owner key (%s/project-id.key), so the volumes it labelled before\n' "$groups_root"
  printf '      losing it cannot be told apart from another home'"'"'s.\n'
}

# _docker_answers: rc 0 when docker lists its volumes; otherwise an ERROR, rc 1.
# A docker that cannot be reached listed no volume, which gc took for nothing
# to collect (review of the PRJ-16 fix).
_docker_answers() {
  docker volume ls -q >/dev/null 2>&1 && return 0
  printf 'ERROR: docker could not list its volumes (is docker running?).\n' >&2
  return 1
}

# _vol_busy <volume>: rc 0 when a running container uses it, 1 when none does,
# 2 when docker could not list the containers, which is never read as none.
_vol_busy() {
  local out
  out="$(docker ps --quiet --filter "volume=$1" 2>/dev/null)" || return 2
  [[ -n "$out" ]]
}

# _group_vol <kind> <group>: the name of the group's volume of that kind, ruby or
# temp.
_group_vol() {
  case "$1" in
    ruby) rvm_volume_name "$2" ;;
    temp) vartmp_volume_name "$2" ;;
  esac
}

# _group_volumes: "<kind> <volume>" for every Ruby and every temp volume, one per
# line. A volume name holds no blank or newline (docker allows
# [a-zA-Z0-9][a-zA-Z0-9_.-]*), and no label value is ever put on a line.
_group_volumes() {
  rvm_volumes | sed 's/^/ruby /'
  vartmp_volumes | sed 's/^/temp /'
}

# _vol_group <kind> <volume>: the group the volume serves, rc 0; rc 1 when it
# serves none; rc 2 when docker cannot read its labels (_vol_label), which is
# not a volume with none: read so, gc --all removed an orphaned Ruby volume as
# one with no owner label, and a temp volume was passed over in silence. A Ruby
# volume's by its label, or by its name before labels, as
# sandbox-common.sh: `rvm_group_from_volume()` reads it. A temp volume's by its label
# only, and only when the volume carries that group's temp volume name: under
# nested REPO_VOLUME_PREFIX values another prefix's volume carries a name of this
# one's, which is how a name match took one repo's volume for another's
# (REPO-11). One with no label was made outside a launch, and is no group's.
# A volume that carries a temp volume's label is never a Ruby one: prefix
# p-rvm-x's temp volume p-rvm-x-vartmp-g is listed with prefix p's Ruby volumes,
# and with no Ruby label its name made it group x-vartmp-g's, an orphan that gc
# removed.
_vol_group() {
  local g tl
  tl="$(_vol_label "$2" 'ai-containers.vartmp-group')" || return 2
  case "$1" in
    ruby) [[ -z "$tl" ]] || return 1
          g="$(_vol_label "$2" 'ai-containers.rvm-group')" || return 2
          [[ -n "$g" ]] || g="${2#"${repo_volume_prefix}"-rvm-}"
          printf '%s\n' "$g" ;;
    temp) [[ -n "$tl" && "$(vartmp_volume_name "$tl")" == "$2" ]] || return 1
          printf '%s\n' "$tl" ;;
  esac
}

# _vol_not_ours <kind> <volume> <group>: why the volume of the group's Ruby or
# temp volume name is not the group's, printed; nothing when it is; rc 1 when
# docker cannot read its labels. A temp volume is the group's by its label alone
# (see _vol_group). A Ruby volume is the group's unless it carries a temp
# volume's label or another group's Ruby label: under nested REPO_VOLUME_PREFIX
# values prefix p-rvm-x's temp volume p-rvm-x-vartmp-g has the Ruby volume name
# of group x-vartmp-g under prefix p, and its Ruby volume of group g,
# p-rvm-x-rvm-g, that of group x-rvm-g; by its name alone rm removed either. One
# with no label, made before labels, is still the group's.
_vol_not_ours() {
  local tl rl
  tl="$(_vol_label "$2" 'ai-containers.vartmp-group')" || return 1
  case "$1" in
    ruby) if [[ -n "$tl" ]]; then
            printf 'it is a temp volume, its label naming group "%s"' "$(_ac_term "$tl")"; return 0
          fi
          rl="$(_vol_label "$2" 'ai-containers.rvm-group')" || return 1
          [[ -z "$rl" || "$rl" == "$3" ]] || printf 'its label names group "%s"' "$(_ac_term "$rl")" ;;
    temp) if [[ -z "$tl" ]]; then printf 'it has no temp volume label'
          elif [[ "$tl" != "$3" ]]; then printf 'its label names group "%s"' "$(_ac_term "$tl")"; fi ;;
  esac
  return 0
}

# _foreign_say <kind> <volume> <group> <why>: a volume of the group's Ruby or
# temp volume name that is not the group's (_vol_not_ours says why), named, and
# never removed here. One with no label was made outside a launch (a `docker
# run -v` of it), and a launch refuses it
# (sandbox-common.sh: `vartmp_volume_ensure()`): whose it is cannot be told, so
# it is named with the command that removes it. One whose label names another
# group is most likely that group's under another REPO_VOLUME_PREFIX, in use
# there: no such command.
_foreign_say() {
  local word="temp"
  [[ "$1" == temp ]] || word="Ruby"
  if [[ "$4" == "it has no temp volume label" ]]; then
    printf '  (volume %s is kept: %s, so it is not the %s volume of group "%s".\n' "$2" "$4" "$word" "$3"
    printf '   Once nothing in it is needed: docker volume rm %s)\n' "$2"
  else
    printf '  (volume %s is kept: %s, so it is not the %s volume of group "%s";\n' "$2" "$4" "$word" "$3"
    printf "   it may be that group's volume under another REPO_VOLUME_PREFIX, in use there.)\n"
  fi
}

# Each volume's human-readable size, from ONE `docker system df -v` per run
# (_df_load, which list --sizes calls before its rows): it walks every volume on
# the daemon, slow enough to be annoying as a default, and asked once per volume
# it made list --sizes slower with every group.
declare -A _df_size=()
_df_load() {
  local l lines=()
  mapfile -t lines < <(docker system df -v --format '{{range .Volumes}}{{.Name}} {{.Size}}
{{end}}' 2>/dev/null)
  for l in ${lines[@]+"${lines[@]}"}; do
    if [[ "$l" == ?*' '?* ]]; then _df_size[${l%% *}]="${l#* }"; fi
  done
}
# volume_size <volume>: its size, '-' when docker did not give one.
volume_size() {
  printf '%s' "${_df_size[$1]:--}"
}

# _vol_cells <kind> <group> <sizes> <docker answers>: the group's volume of that
# kind and its state, a line each, as list shows them. The state is "present",
# or its size with --sizes, then " (in use)" while a running container mounts
# it; "none", the name "-", when docker says there is no such volume; "unknown"
# when docker cannot be reached (<docker answers> 0), cannot say whether the
# volume exists, or cannot read its labels. A volume of the name that is not the
# group's (_vol_not_ours) is named, its state "not the group's".
_vol_cells() {
  local kind="$1" g="$2" vol state why vout
  vol="$(_group_vol "$kind" "$g")"
  if (( ! $4 )); then
    state="unknown"
  elif ! vout="$(docker volume inspect "$vol" 2>&1 >/dev/null)"; then
    if [[ "${vout,,}" == *"no such volume"* ]]; then vol="-"; state="none"; else state="unknown"; fi
  elif ! why="$(_vol_not_ours "$kind" "$vol" "$g")"; then
    state="unknown"
  elif [[ -n "$why" ]]; then
    state="not the group's"
  else
    if (( $3 )); then state="$(volume_size "$vol")"; else state="present"; fi
    docker_volume_in_use "$vol" && state="$state (in use)"
  fi
  printf '%s\n%s\n' "$vol" "$state"
}

cmd_list() {
  local show_sizes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sizes) show_sizes=1 ;;
      *) printf 'ERROR: unknown option for list: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done

  local names; names="$(group_names)"
  # A docker that cannot be reached is not one with no volumes: the groups are
  # still listed, their volumes unknown, and the run says so, rc 1 (review of
  # the PRJ-16 fix).
  local dk=1
  docker volume ls -q >/dev/null 2>&1 || dk=0
  if (( show_sizes && dk )) && [[ -n "$names" ]]; then _df_load; fi
  # With no group directory left, the orphans are all there is to name: deleting
  # the directories by hand leaves exactly that, and list returned before them.
  # Each row: the group, its Ruby volume and state, its temp volume and state.
  local g dsize dout drc cell_unknown=0
  local -a rc=() tc=()
  if [[ -z "$names" ]]; then
    printf 'No container groups yet (%s is empty or absent).\n' "$groups_root"
  else
    if (( show_sizes )); then
      printf '%-24s  %-40s  %-16s  %-40s  %-16s  %s\n' "GROUP" "RVM VOLUME" "SIZE" "TEMP VOLUME" "SIZE" "GROUP DIR"
    else
      printf '%-24s  %-40s  %-16s  %-40s  %s\n' "GROUP" "RVM VOLUME" "STATE" "TEMP VOLUME" "STATE"
    fi
  fi
  [[ -z "$names" ]] || while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    mapfile -t rc < <(_vol_cells ruby "$g" "$show_sizes" "$dk")
    mapfile -t tc < <(_vol_cells temp "$g" "$show_sizes" "$dk")
    if [[ "${rc[1]-}" == unknown || "${tc[1]-}" == unknown ]]; then cell_unknown=1; fi
    if (( show_sizes )); then
      # The group directory holds the persistent cache and state folders, so
      # it grows on its own; the field before the tab is du -sh's size, GNU's
      # and BSD's alike (BSD's padded with blanks, which are dropped), and only
      # one that reads as a size is shown, else "?".
      # du exits 1 when it cannot read part of the directory (a folder the
      # agent made unreadable), having printed the total of what it could read:
      # that total is shown as the least it holds.
      drc=0; dout="$(du -sh "$groups_root/$g" 2>/dev/null)" || drc=$?
      dsize="${dout%%$'\t'*}"
      dsize="${dsize#"${dsize%%[![:space:]]*}"}"
      [[ "$dsize" =~ ^[0-9][0-9.,]*[A-Za-z]*$ ]] || dsize=""
      if [[ -n "$dsize" ]] && (( drc )); then dsize="at least $dsize"; fi
      printf '%-24s  %-40s  %-16s  %-40s  %-16s  %s\n' "$g" "${rc[0]-}" "${rc[1]-}" "${tc[0]-}" "${tc[1]-}" "${dsize:-?}"
    else
      printf '%-24s  %-40s  %-16s  %-40s  %s\n' "$g" "${rc[0]-}" "${rc[1]-}" "${tc[0]-}" "${tc[1]-}"
    fi
  done <<< "$names"
  if (( ! dk )); then
    printf 'ERROR: docker could not list its volumes (is docker running?), so which groups have a\n' >&2
    printf '       Ruby or temp volume, and which volumes are orphaned, cannot be told.\n' >&2
    exit 1
  fi

  # Orphans: a volume whose group directory no longer exists. Surfaced here rather
  # than only in gc so `list` alone tells you whether there is anything to clean.
  local orphans=""
  local kind v og own why nolab=0
  own="$(ai_containers_owner_known 2>/dev/null)" || own=""
  local ogrc
  while read -r kind v; do
    ogrc=0; og="$(_vol_group "$kind" "$v")" || ogrc=$?
    if (( ogrc == 2 )); then cell_unknown=1; continue; fi
    (( ogrc == 0 )) || continue
    [[ -d "$groups_root/$og" ]] || orphans="${orphans:+$orphans }$v"
  done < <(_group_volumes)
  if [[ -n "$orphans" ]]; then
    printf '\nOrphaned Ruby and temp volume(s) with no group directory — remove with ./group.sh gc:\n'
    for v in $orphans; do
      if why="$(_vol_owner_why "$v" "$own")"; then
        case "$why" in
          "no owner label") printf '  %s  (no owner label: gc keeps it unless --all)\n' "$v" ;;
          *)                printf "  %s  (another home's: gc keeps it unless --all)\n" "$v" ;;
        esac
        nolab=1
      else
        printf '  %s\n' "$v"
      fi
    done
    if (( nolab )); then _no_key_note "$own"; fi
  fi
  # A volume docker could not say exists, or whose it is, is not one it says is
  # absent or another group's: its state is unknown, and the run says so, rc 1.
  if (( cell_unknown )); then
    printf 'ERROR: docker could not say whether some volumes exist or whose they are (shown as "unknown",\n' >&2
    printf '       or left out of the orphans).\n' >&2
    exit 1
  fi
}

cmd_rm() {
  local name="" assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      -*) printf 'ERROR: unknown option for rm: %s\n' "$1" >&2; exit 1 ;;
      *) [[ -n "$name" ]] && { printf 'ERROR: rm takes a single <group>.\n' >&2; exit 1; }; name="$1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || { printf 'ERROR: usage: ./group.sh rm <group> [--yes]\n' >&2; exit 1; }
  if [[ "$name" == "host" ]]; then
    printf 'ERROR: "host" is not a group (it named your real $HOME, and is no longer supported) — refusing.\n' >&2
    exit 1
  fi
  # Before any path is built: the name goes into an rm -rf, and `rm ../dev` deleted
  # ~/dev (bugs review PRJ-1). Every group was made under this rule.
  validate_group_name "$name"

  local dir="$groups_root/$name"
  local has_dir=0
  [[ -d "$dir" ]] && has_dir=1

  # Each volume on its own, Ruby then temp: its name, and what rm does with it
  # (act: none, remove, keep, or foreign for a volume of the name that is not
  # the group's), why it may be another home's, and why a foreign one is not
  # the group's.
  local own maker="another home on this docker" k v vout ol
  own="$(ai_containers_owner_known 2>/dev/null)" || own=""
  # With no owner key, this home's own labelled volume looks like another's.
  [[ -n "$own" ]] || maker="another home on this docker, or this one before it lost its owner key,"
  local -A vol=() act=() why=() lab=()
  for k in ruby temp; do
    v="$(_group_vol "$k" "$name")"
    vol[$k]="$v"; act[$k]=none; why[$k]=""; lab[$k]=""
    # A docker that cannot answer is not one that says there is no volume: read
    # so, the directory went and the volume was left, orphaned (review of the
    # PRJ-16 fix).
    if ! vout="$(docker volume inspect "$v" 2>&1 >/dev/null)"; then
      [[ "${vout,,}" == *"no such volume"* ]] && continue
      printf 'ERROR: docker could not say whether %s exists (is docker running?); refusing.\n' "$v" >&2
      exit 1
    fi
    # Whose it is, from labels read so that a docker that cannot say is not one
    # that says there are none (_vol_label). One of the name that is not the
    # group's (_vol_not_ours) is named, never removed.
    if ! lab[$k]="$(_vol_not_ours "$k" "$v" "$name")" || ! ol="$(_vol_label "$v" 'ai-containers.owner')"; then
      printf 'ERROR: docker could not say whose %s is (is docker running?); refusing.\n' "$v" >&2
      exit 1
    fi
    if [[ -n "${lab[$k]}" ]]; then act[$k]=foreign; continue; fi
    # A volume another home made: one docker serves several homes, and that
    # home's group of this name mounts the same volume. Kept and named; this
    # home's directory goes (review of the PRJ-16 fix).
    act[$k]=remove
    if why[$k]="$(_owner_why "$ol" "$own")" && [[ "${why[$k]}" == "another home's" ]]; then act[$k]=keep; fi
  done

  # Nothing of this home's to remove: no directory, and no volume but another
  # home's or one that is not the group's.
  local n_rm=0 n_keep=0
  for k in ruby temp; do
    case "${act[$k]}" in remove) n_rm=$(( n_rm + 1 )) ;; keep) n_keep=$(( n_keep + 1 )) ;; esac
  done
  if [[ "$has_dir" == "0" ]] && (( n_rm == 0 )); then
    if (( n_keep )); then
      for k in ruby temp; do
        [[ "${act[$k]}" == keep ]] || continue
        printf 'ERROR: %s was made by %s and its group "%s" there may use it; this home\n' "${vol[$k]}" "$maker" "$name" >&2
        printf '       has no group "%s" to remove. To remove the volume anyway: docker volume rm %s\n' "$name" "${vol[$k]}" >&2
      done
      _no_key_note "$own" >&2
    else
      printf 'ERROR: no such group "%s" (no directory at %s, and no Ruby or temp volume of its own).\n' "$name" "$dir" >&2
    fi
    for k in ruby temp; do
      if [[ "${act[$k]}" == foreign ]]; then _foreign_say "$k" "${vol[$k]}" "$name" "${lab[$k]}" >&2; fi
    done
    exit 1
  fi

  # Never yank a volume out from under a running container: docker would refuse the
  # rm anyway, but we would already have deleted the directory by then. Every
  # volume rm would remove is checked before anything goes. A docker that cannot
  # list its containers is not read as none using it (PRJ-16).
  local brc bad=0
  for k in ruby temp; do
    [[ "${act[$k]}" == remove ]] || continue
    brc=0; _vol_busy "${vol[$k]}" || brc=$?
    if (( brc == 0 )); then
      printf 'ERROR: a running container is still using %s. Stop it first.\n' "${vol[$k]}" >&2
      bad=1
    elif (( brc == 2 )); then
      printf 'ERROR: docker could not list the containers, so whether one uses %s cannot be told; refusing.\n' "${vol[$k]}" >&2
      bad=1
    fi
  done
  (( bad == 0 )) || exit 1

  printf 'This will permanently remove group "%s":\n' "$name"
  [[ "$has_dir" == "1" ]] && printf '  directory  %s\n' "$dir"
  local word what wnote kept=0
  for k in ruby temp; do
    case "$k" in
      ruby) word="rvm volume";  what="installed rubies and gems" ;;
      temp) word="temp volume"; what="its containers' /var/tmp" ;;
    esac
    case "${act[$k]}" in
      remove)
        wnote=""
        [[ -z "${why[$k]}" ]] || wnote=" — ${why[$k]}, so it may be another home's too"
        printf '  %s %s (%s)%s\n' "$word" "${vol[$k]}" "$what" "$wnote" ;;
      keep)
        printf '  (%s %s is kept: %s made it, and its group "%s" there may use it)\n' "$word" "${vol[$k]}" "$maker" "$name"
        kept=1 ;;
      foreign)
        _foreign_say "$k" "${vol[$k]}" "$name" "${lab[$k]}" ;;
    esac
  done
  if (( kept )); then _no_key_note "$own"; fi
  confirm "Remove it?" || { printf 'Aborted.\n'; exit 1; }

  # Every volume is tried; one docker would not remove keeps the directory, whose
  # removal would orphan it.
  local failed=0
  for k in ruby temp; do
    [[ "${act[$k]}" == remove ]] || continue
    if docker volume rm "${vol[$k]}" >/dev/null 2>&1; then
      printf 'Removed volume %s\n' "${vol[$k]}"
    else
      printf 'WARNING: could not remove volume %s — leaving the directory in place.\n' "${vol[$k]}" >&2
      failed=1
    fi
  done
  (( failed == 0 )) || exit 1
  if [[ "$has_dir" == "1" ]]; then
    rm -rf "$dir"
    printf 'Removed directory %s\n' "$dir"
  fi
}

cmd_gc() {
  local assume_yes=0 all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      --all) all=1 ;;
      *) printf 'ERROR: unknown option for gc: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done

  _docker_answers || exit 1
  local targets="" kept="" kind v g own why brc grc ol skipped=0 unknown=0
  local -A whose=()
  own="$(ai_containers_owner_known 2>/dev/null)" || own=""
  while read -r kind v; do
    grc=0; g="$(_vol_group "$kind" "$v")" || grc=$?
    (( grc != 1 )) || continue                      # no group's volume — never touched
    # Its labels, read so that a docker that cannot say is not one that says
    # there are none (_vol_label): skipped, named, and gc exits 1.
    if (( grc == 0 )) && [[ -d "$groups_root/$g" ]]; then continue; fi   # group still exists — keep
    if (( grc == 2 )) || ! ol="$(_vol_label "$v" 'ai-containers.owner')"; then
      printf 'Skipping %s — docker could not say whose it is.\n' "$v" >&2
      skipped=$(( skipped + 1 )); unknown=1; continue
    fi
    # Another home's, or one made before owner labels: its group may live in
    # that home (PRJ-16). Kept, and named, unless --all.
    if why="$(_owner_why "$ol" "$own")"; then
      if (( ! all )); then kept+="  $v: $why"$'\n'; continue; fi
      whose[$v]="$why"
    fi
    brc=0; _vol_busy "$v" || brc=$?
    if (( brc == 0 )); then
      printf 'Skipping %s — a running container is using it.\n' "$v" >&2
      skipped=$(( skipped + 1 )); continue
    elif (( brc == 2 )); then
      printf 'Skipping %s — docker could not list the containers, so whether one uses it cannot be told.\n' "$v" >&2
      skipped=$(( skipped + 1 )); unknown=1; continue
    fi
    targets="${targets:+$targets }$v"
  done < <(_group_volumes)

  if [[ -n "$kept" ]]; then
    printf 'Kept, as their group may live in another home on this docker (another WSL distro or user):\n%s' "$kept"
    printf './group.sh gc --all removes them too.\n'
    _no_key_note "$own"
  fi
  if [[ -z "$targets" ]]; then
    if (( skipped )); then
      printf 'Nothing removed: %d volume(s) skipped (above).\n' "$skipped"
      (( ! unknown )) || exit 1
    else
      printf 'Nothing to collect: every Ruby and temp volume of this home has a group directory.\n'
    fi
    return 0
  fi

  printf 'Orphaned Ruby and temp volume(s) (group directory no longer exists):\n'
  for v in $targets; do printf '  %s%s\n' "$v" "${whose[$v]:+  ($(_whose_say "${whose[$v]}"))}"; done
  confirm "Remove them?" || { printf 'Aborted.\n'; exit 1; }
  for v in $targets; do
    docker volume rm "$v" >/dev/null 2>&1 && printf 'Removed %s\n' "$v" \
      || printf 'WARNING: could not remove %s\n' "$v" >&2
  done
  (( ! unknown )) || exit 1
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  rm)   shift; cmd_rm   "$@" ;;
  gc)   shift; cmd_gc   "$@" ;;
  -h|--help|help|"") usage ;;
  *) printf 'ERROR: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
