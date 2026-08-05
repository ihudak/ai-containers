#!/usr/bin/env bash
set -euo pipefail

# group.sh — manage AI sandbox container groups and the resources they own.
#
# A container group is a named directory under ~/.ai-containers/<group>/ holding
# the agent dotfile trees (.claude, .codex, .copilot, .config/gh, .ssh, .agents, …)
# that get mounted into the container. Selected at run time with
# AI_CONTAINER_GROUP; see the README "Container groups" section.
#
# A group used to be ONLY a directory, so `rm -rf ~/.ai-containers/<group>` was the
# whole story. That stopped being true when the group's Ruby home (~/.rvm) moved to
# a Docker named volume (it cannot live on a macOS bind mount — see the tar/virtiofs
# note on rvm_volume_name in sandbox-common.sh). Deleting the directory now leaves a
# multi-GB volume orphaned with nothing pointing at it. This script keeps the two in
# step: 'rm' removes both, and 'gc' finds volumes whose group is already gone.
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
  ./group.sh rm <group> [--yes]      Remove a group: its directory AND its rvm volume
  ./group.sh gc [--yes]              Remove rvm volumes whose group directory is gone

Notes:
  - A group owns two things: the directory ~/.ai-containers/<group>/ and, once you
    have built with a ruby= version, the Docker volume holding its Ruby home.
    'rm' removes both; deleting the directory by hand orphans the volume ('gc'
    cleans those up afterwards).
  - 'rm' refuses while a running container still mounts the group's rvm volume.
  - The 'host' group is not a directory under ~/.ai-containers (it means "mount my
    real $HOME"), so it is never listed or removed here.
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
  if [[ -z "$names" ]]; then
    printf 'No container groups yet (%s is empty or absent).\n' "$groups_root"
    return 0
  fi

  printf '%-24s  %-40s  %s\n' "GROUP" "RVM VOLUME" "$([[ "$show_sizes" == "1" ]] && echo "SIZE" || echo "STATE")"
  local g vol state
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    vol="$(rvm_volume_name "$g")"
    if docker volume inspect "$vol" >/dev/null 2>&1; then
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
    printf '%-24s  %-40s  %s\n' "$g" "$vol" "$state"
  done <<< "$names"

  # Orphans: a volume whose group directory no longer exists. Surfaced here rather
  # than only in gc so `list` alone tells you whether there is anything to clean.
  local orphans=""
  local v og
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    og="$(rvm_group_from_volume "$v")"
    [[ -d "$groups_root/$og" ]] || orphans="${orphans:+$orphans }$v"
  done < <(rvm_volumes)
  if [[ -n "$orphans" ]]; then
    printf '\nOrphaned rvm volume(s) with no group directory — remove with ./group.sh gc:\n'
    for v in $orphans; do printf '  %s\n' "$v"; done
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
    printf 'ERROR: the "host" group is your real $HOME, not a managed directory — refusing.\n' >&2
    exit 1
  fi

  local dir="$groups_root/$name"
  local vol; vol="$(rvm_volume_name "$name")"
  local has_dir=0 has_vol=0
  [[ -d "$dir" ]] && has_dir=1
  docker volume inspect "$vol" >/dev/null 2>&1 && has_vol=1
  if [[ "$has_dir" == "0" && "$has_vol" == "0" ]]; then
    printf 'ERROR: no such group "%s" (no directory at %s and no volume %s).\n' "$name" "$dir" "$vol" >&2
    exit 1
  fi

  # Never yank a volume out from under a running container: docker would refuse the
  # rm anyway, but we would already have deleted the directory by then.
  if [[ "$has_vol" == "1" ]] && docker_volume_in_use "$vol"; then
    printf 'ERROR: a running container is still using %s. Stop it first.\n' "$vol" >&2
    exit 1
  fi

  printf 'This will permanently remove group "%s":\n' "$name"
  [[ "$has_dir" == "1" ]] && printf '  directory  %s\n' "$dir"
  [[ "$has_vol" == "1" ]] && printf '  rvm volume %s (installed rubies and gems)\n' "$vol"
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
  local assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      *) printf 'ERROR: unknown option for gc: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done

  local targets="" v g
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    g="$(rvm_group_from_volume "$v")"
    [[ -d "$groups_root/$g" ]] && continue          # group still exists — keep
    docker_volume_in_use "$v" && {
      printf 'Skipping %s — a running container is using it.\n' "$v" >&2
      continue
    }
    targets="${targets:+$targets }$v"
  done < <(rvm_volumes)

  if [[ -z "$targets" ]]; then
    printf 'Nothing to collect: every rvm volume has a group directory.\n'
    return 0
  fi

  printf 'Orphaned rvm volume(s) (group directory no longer exists):\n'
  for v in $targets; do printf '  %s\n' "$v"; done
  confirm "Remove them?" || { printf 'Aborted.\n'; exit 1; }
  for v in $targets; do
    docker volume rm "$v" >/dev/null 2>&1 && printf 'Removed %s\n' "$v" \
      || printf 'WARNING: could not remove %s\n' "$v" >&2
  done
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  rm)   shift; cmd_rm   "$@" ;;
  gc)   shift; cmd_gc   "$@" ;;
  -h|--help|help|"") usage ;;
  *) printf 'ERROR: unknown command: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
