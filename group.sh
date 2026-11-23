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
# note on rvm_volume_name in sandbox-common.sh). Deleting the directory now leaves a
# multi-GB volume orphaned with nothing pointing at it. This script keeps the two in
# step: 'rm' removes both (keeping a volume another home made), and 'gc' finds
# volumes whose group is already gone.
#
# Scope: groups and their volumes ONLY. Repo volumes are a separate, global
# resource with their own lifecycle — use repo.sh for those. The two never overlap:
# repo volumes are named "<prefix>-repo-<name>" and rvm volumes "<prefix>-rvm-<group>",
# and each tool's discovery filters on its own infix.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sandbox-common.sh
source "${_here}/sandbox-common.sh"

groups_root="$HOME/.ai-containers"

usage() {
  cat <<'EOF'
Usage:
  ./group.sh list [--sizes]          List container groups and their rvm volumes
  ./group.sh rm <group> [--yes]      Remove a group: its directory and its rvm volume
  ./group.sh gc [--all] [--yes]      Remove this home's rvm volumes whose group directory is gone

Notes:
  - A group owns two things: the directory ~/.ai-containers/<group>/ and, once you
    have built with a ruby= version, the Docker volume holding its Ruby home.
    'rm' removes both, but keeps a volume another home on this docker made;
    deleting the directory by hand orphans the volume ('gc'
    cleans those up afterwards).
  - 'rm' refuses while a running container still mounts an rvm volume it would
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

# _vol_owner_why <volume> <this home's id>: why gc keeps an orphaned rvm volume
# that is not this home's, printed, rc 0; rc 1 when it is this home's. One
# daemon serves several homes (Docker Desktop's, by every WSL distro), so a group
# directory missing here may be another home's group (bugs review PRJ-16); one
# made before owner labels cannot be told apart, and is kept unless --all.
_vol_owner_why() {
  local o; o="$(docker_volume_label "$1" 'ai-containers.owner')"
  if [[ -z "$o" ]]; then printf 'no owner label'; return 0; fi
  if [[ -z "$2" || "$o" != "$2" ]]; then printf "another home's"; return 0; fi
  return 1
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

# Human-readable size of a docker volume ('-' when unknown). Deliberately a
# separate call behind --sizes: `docker system df -v` walks every volume and is
# slow enough to be annoying as a default.
volume_size() {
  local vol="$1" out
  out="$(docker system df -v --format '{{range .Volumes}}{{.Name}} {{.Size}}
{{end}}' 2>/dev/null | grep -m1 "^${vol} " | cut -d' ' -f2- || true)"
  printf '%s' "${out:--}"
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
  # With no group directory left, the orphans are all there is to name: deleting
  # the directories by hand leaves exactly that, and list returned before them.
  local g vol state dsize
  if [[ -z "$names" ]]; then
    printf 'No container groups yet (%s is empty or absent).\n' "$groups_root"
  else
    if (( show_sizes )); then
      printf '%-24s  %-40s  %-12s  %s\n' "GROUP" "RVM VOLUME" "SIZE" "GROUP DIR"
    else
      printf '%-24s  %-40s  %s\n' "GROUP" "RVM VOLUME" "STATE"
    fi
  fi
  [[ -z "$names" ]] || while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    vol="$(rvm_volume_name "$g")"
    if (( ! dk )); then
      state="unknown"
    elif docker volume inspect "$vol" >/dev/null 2>&1; then
      if [[ "$show_sizes" == "1" ]]; then
        state="$(volume_size "$vol")"
      else
        state="present"
      fi
      docker_volume_in_use "$vol" && state="$state (in use)"
    else
      vol="-"
      state="none"
    fi
    if (( show_sizes )); then
      # The group directory holds the persistent cache, state and temp folders,
      # so it grows on its own; du -sh | cut works with GNU and BSD du alike.
      dsize="$(du -sh "$groups_root/$g" 2>/dev/null | cut -f1)" || dsize=""
      printf '%-24s  %-40s  %-12s  %s\n' "$g" "$vol" "$state" "${dsize:-?}"
    else
      printf '%-24s  %-40s  %s\n' "$g" "$vol" "$state"
    fi
  done <<< "$names"
  if (( ! dk )); then
    printf 'ERROR: docker could not list its volumes (is docker running?), so which groups have a\n' >&2
    printf '       Ruby volume, and which volumes are orphaned, cannot be told.\n' >&2
    exit 1
  fi

  # Orphans: a volume whose group directory no longer exists. Surfaced here rather
  # than only in gc so `list` alone tells you whether there is anything to clean.
  local orphans=""
  local v og own why nolab=0
  own="$(ai_containers_owner_known 2>/dev/null)" || own=""
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    og="$(rvm_group_from_volume "$v")"
    [[ -d "$groups_root/$og" ]] || orphans="${orphans:+$orphans }$v"
  done < <(rvm_volumes)
  if [[ -n "$orphans" ]]; then
    printf '\nOrphaned rvm volume(s) with no group directory — remove with ./group.sh gc:\n'
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
  local vol; vol="$(rvm_volume_name "$name")"
  local has_dir=0 has_vol=0 vout
  [[ -d "$dir" ]] && has_dir=1
  # A docker that cannot answer is not one that says there is no volume: read
  # so, the directory went and the volume was left, orphaned (review of the
  # PRJ-16 fix).
  if vout="$(docker volume inspect "$vol" 2>&1 >/dev/null)"; then has_vol=1
  elif [[ "${vout,,}" != *"no such volume"* ]]; then
    printf 'ERROR: docker could not say whether %s exists (is docker running?); refusing.\n' "$vol" >&2
    exit 1
  fi
  if [[ "$has_dir" == "0" && "$has_vol" == "0" ]]; then
    printf 'ERROR: no such group "%s" (no directory at %s and no volume %s).\n' "$name" "$dir" "$vol" >&2
    exit 1
  fi

  # A volume another home made: one docker serves several homes, and that home's
  # group of this name mounts the same volume. Kept and named; this home's
  # directory goes (review of the PRJ-16 fix).
  local own why="" keep_vol=0 maker="another home on this docker"
  own="$(ai_containers_owner_known 2>/dev/null)" || own=""
  # With no owner key, this home's own labelled volume looks like another's.
  [[ -n "$own" ]] || maker="another home on this docker, or this one before it lost its owner key,"
  if [[ "$has_vol" == "1" ]] && why="$(_vol_owner_why "$vol" "$own")" && [[ "$why" == "another home's" ]]; then
    keep_vol=1
    if [[ "$has_dir" == "0" ]]; then
      printf 'ERROR: %s was made by %s and its group "%s" there may use it; this home\n' "$vol" "$maker" "$name" >&2
      printf '       has no group "%s" to remove. To remove the volume anyway: docker volume rm %s\n' "$name" "$vol" >&2
      _no_key_note "$own" >&2
      exit 1
    fi
  fi

  # Never yank a volume out from under a running container: docker would refuse the
  # rm anyway, but we would already have deleted the directory by then. A docker
  # that cannot list its containers is not read as none using it (PRJ-16).
  local brc=0
  if [[ "$has_vol" == "1" ]] && (( ! keep_vol )); then
    _vol_busy "$vol" || brc=$?
    if (( brc == 0 )); then
      printf 'ERROR: a running container is still using %s. Stop it first.\n' "$vol" >&2
      exit 1
    elif (( brc == 2 )); then
      printf 'ERROR: docker could not list the containers, so whether one uses %s cannot be told; refusing.\n' "$vol" >&2
      exit 1
    fi
  fi

  printf 'This will permanently remove group "%s":\n' "$name"
  [[ "$has_dir" == "1" ]] && printf '  directory  %s\n' "$dir"
  if [[ "$has_vol" == "1" ]] && (( keep_vol )); then
    printf '  (rvm volume %s is kept: %s made it, and its group "%s" there may use it)\n' "$vol" "$maker" "$name"
    _no_key_note "$own"
    has_vol=0
  elif [[ "$has_vol" == "1" ]]; then
    local wnote=""
    [[ -z "$why" ]] || wnote=" — $why, so it may be another home's too"
    printf '  rvm volume %s (installed rubies and gems)%s\n' "$vol" "$wnote"
  fi
  confirm "Remove it?" || { printf 'Aborted.\n'; exit 1; }

  if [[ "$has_vol" == "1" ]]; then
    if docker volume rm "$vol" >/dev/null 2>&1; then
      printf 'Removed volume %s\n' "$vol"
    else
      printf 'WARNING: could not remove volume %s — leaving the directory in place.\n' "$vol" >&2
      exit 1
    fi
  fi
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
  local targets="" kept="" v g own why brc skipped=0 unknown=0
  local -A whose=()
  own="$(ai_containers_owner_known 2>/dev/null)" || own=""
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    g="$(rvm_group_from_volume "$v")"
    [[ -d "$groups_root/$g" ]] && continue          # group still exists — keep
    # Another home's, or one made before owner labels: its group may live in
    # that home (PRJ-16). Kept, and named, unless --all.
    if why="$(_vol_owner_why "$v" "$own")"; then
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
  done < <(rvm_volumes)

  if [[ -n "$kept" ]]; then
    printf 'Kept, as their group may live in another home on this docker (another WSL distro or user):\n%s' "$kept"
    printf './group.sh gc --all removes them too.\n'
    _no_key_note "$own"
  fi
  if [[ -z "$targets" ]]; then
    if (( skipped )); then
      printf 'Nothing removed: %d orphaned volume(s) of this home skipped (above).\n' "$skipped"
      (( ! unknown )) || exit 1
    else
      printf 'Nothing to collect: every rvm volume of this home has a group directory.\n'
    fi
    return 0
  fi

  printf 'Orphaned rvm volume(s) (group directory no longer exists):\n'
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
