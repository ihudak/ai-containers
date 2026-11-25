#!/usr/bin/env bash
# agent-tmp.sh <dir> <slot> <running> [--now <epoch>]
#
# The container's start-up step for /var/tmp: remove the per-container temp
# folders that nothing has changed for 30 days, then make this launch's own.
#   <dir>      /var/tmp in the container (a temp folder in tests)
#   <slot>     this launch's folder name, YYMMDD-HHMMSS-pid
#   <running>  "?" (not known: prune nothing) or a space-separated list of the
#              folder names containers in use hold (may be empty)
#   --now      the clock, for tests only; never read from the environment
# Exit 0: the folder was made. 1: it was not, after a WARNING: on stderr.
# 2: usage. Pruning never changes the exit code. NOTE:/WARNING: go to stderr.
#
# It runs HERE, as the agent's user, and not on the host, because /var/tmp is a
# Docker volume the host cannot reach into (the design's "Approaches", B). Only
# the folders of its own uid are candidates, so two projects of one group with
# different SANDBOX_UIDs each prune their own and neither warns of the other's.
#
# "Untouched" is the change time (ctime), not the modification time: an archive
# or copy unpacked onto the folder carries the source's old mtimes, and ctime
# cannot be set back (the design's "Second change"). find -cnewer against a
# reference file dated 30 days before now says it the same on GNU and BSD.
#
# Deleting an agent's files is what the persistent /var/tmp exists to stop, so
# anything uncertain is kept: <running> unknown, a name that is not a
# per-container folder, a link, a file, another user's folder, one that cannot be
# read. A folder kept for what it holds, for an error, or because it could not be
# removed is touched, so it is checked again 30 days later rather than using up
# the cap below at every start. The folders are the agent's to write, so nothing
# here follows a link out of one (find -P, du, touch -h and rm -rf leave links
# alone), and the cost is bounded: one find lists at most 500 candidates, and at
# most 50 are checked and removed per start.
set -uo pipefail

if (( $# < 3 )); then
  printf 'usage: agent-tmp.sh <dir> <slot> <running> [--now <epoch>]\n' >&2
  exit 2
fi
dir="$1" slot="$2" running_arg="$3"
now=""
if [[ "${4:-}" == --now ]]; then now="${5:-}"; fi
[[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"

name_re='^[0-9]{6}-[0-9]{6}-[0-9]+$'
cap=50 readmax=500 age=2592000

prune() {
  local d name n=0 kb total_kb=0 checked=0 left=0 listed_cut=0 ref recent size least
  local cands=() listed=() uid
  [[ "$running_arg" == "?" ]] && return 0
  [[ -d "$dir" ]] || return 0
  # Names in use; anything that is not a folder name never reaches a path.
  local running=$'\n' w
  set -f
  for w in $running_arg; do
    [[ "$w" =~ $name_re ]] && running+="$w"$'\n'
  done
  set +f
  uid="$(id -u)" || return 0
  ref="$(mktemp)" || return 0
  # shellcheck disable=SC2064
  trap "rm -f -- '$ref'" RETURN
  touch -t "$(printf '%(%Y%m%d%H%M.%S)T' "$((now - age))")" "$ref" 2>/dev/null || return 0
  # The two -name tests are name_re in fnmatch. One more than readmax is read,
  # to tell a listing that was cut; find then dies of SIGPIPE, which ends nothing.
  mapfile -d '' -n "$((readmax + 1))" listed < <(find -P "$dir" -mindepth 1 -maxdepth 1 \
    -name '[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*' \
    ! -name '??????-??????-*[!0-9]*' -type d -user "$uid" ! -cnewer "$ref" -print0 2>/dev/null)
  if (( ${#listed[@]} > readmax )); then listed_cut=1; listed=("${listed[@]:0:readmax}"); fi
  for d in ${listed[@]+"${listed[@]}"}; do
    name="${d##*/}"
    [[ "$name" =~ $name_re ]] || continue
    [[ "$name" == "$slot" ]] && continue
    [[ -d "$d" && ! -L "$d" ]] || continue
    [[ "$running" == *$'\n'"$name"$'\n'* ]] && continue
    cands+=("$d")
  done
  for d in ${cands[@]+"${cands[@]}"}; do
    if (( checked >= cap )); then left=$((left + 1)); continue; fi
    checked=$((checked + 1))
    # A find that errors keeps the folder, as does anything inside changed in
    # the last 30 days.
    if ! recent="$(find -P "$d" -cnewer "$ref" -print -quit 2>/dev/null)" || [[ -n "$recent" ]]; then
      touch -c -h -- "$d" 2>/dev/null || true
      continue
    fi
    kb="$(du -sk "$d" 2>/dev/null | awk '{print $1; exit}')" || kb=0
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    if rm -rf -- "$d" 2>/dev/null && [[ ! -e "$d" ]]; then
      n=$((n + 1)); total_kb=$((total_kb + kb))
    else
      printf 'NOTE: could not remove %s; it is kept, and checked again in 30 days.\n' "$d" >&2
      touch -c -h -- "$d" 2>/dev/null || true
    fi
  done
  if (( n > 0 )); then
    if (( total_kb >= 1048576 )); then size="$(awk -v k="$total_kb" 'BEGIN{printf "%.1fG", k/1048576}')"
    elif (( total_kb >= 1024 )); then size="$(awk -v k="$total_kb" 'BEGIN{printf "%.1fM", k/1024}')"
    else size="${total_kb}K"; fi
    printf 'NOTE: removed %d temp folder(s) of stopped containers, untouched for 30 days, from %s (%s freed).\n' \
      "$n" "$dir" "$size" >&2
  fi
  if (( left > 0 )); then
    least=""
    (( listed_cut == 0 )) || least="at least "
    printf 'NOTE: %s%d more old temp folder(s) in %s are left for the next launch.\n' \
      "$least" "$left" "$dir" >&2
  fi
  return 0
}

# A malformed call (swapped arguments, say) is refused before anything is
# removed: the protection of running containers' folders rests on its arguments.
if [[ ! "$slot" =~ $name_re ]]; then
  printf 'WARNING: %s is not a temp folder name; the shell keeps /tmp as its TMPDIR.\n' "${slot:-(empty)}" >&2
  exit 1
fi

prune || true

if ! mkdir -m 0700 -- "$dir/$slot" 2>/dev/null; then
  printf 'WARNING: cannot create %s/%s; the shell keeps /tmp as its TMPDIR.\n' "$dir" "$slot" >&2
  exit 1
fi
exit 0
