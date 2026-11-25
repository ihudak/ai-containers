#!/usr/bin/env bash
# lib-fake-docker-volume.sh <state-dir> volume <sub> [args...]
#
# The `docker volume` half of a hermetic test's fake docker. A launch now makes
# the group's /var/tmp volume (sandbox-common.sh: `vartmp_volume_ensure()`) and
# refuses to start when docker cannot say what that volume is, so every fake
# that lets a launch reach `docker run` hands its `volume` calls here, with one
# line before its own handling:
#
#   [[ "\$1" == volume ]] && exec bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$TMP/volumes" "\$@"
#
# It keeps each volume as a directory of <state-dir>, holding `labels`, one
# key=value per line, and answers as docker does:
#   create [--label k=v]... <name>   records the labels (an existing volume keeps
#                                    its own), prints the name
#   inspect [--format F] <name>...   F with `index .Labels "<key>"` prints that
#                                    label, empty when unset; `{{.Name}}` the
#                                    name; none a JSON array. A missing volume:
#                                    `no such volume` on stderr, exit 1
#   rm [-f] <name>...                removes; a missing one fails as inspect does
#   ls [-q] [--filter name=<s>]      the names holding <s>, one per line, whatever
#                                    --format asks (a caller reading a table then
#                                    finds none, as with a docker that ignores it)
# A test makes a volume of its own (unlabelled, another group's) by calling it
# directly, with the same <state-dir>.
set -uo pipefail

state="${1:-}"
if [[ -z "$state" || "${2:-}" != volume ]]; then
  printf 'usage: lib-fake-docker-volume.sh <state-dir> volume <sub> [args...]\n' >&2
  exit 2
fi
shift 2
mkdir -p "$state" || exit 1
sub="${1:-}"
(( $# )) && shift

no_such() { printf 'Error response from daemon: get %s: no such volume\n' "$1" >&2; }

case "$sub" in
  create)
    labels=() name=""
    while (( $# )); do
      case "$1" in
        --label) labels+=("${2:-}"); shift; (( $# )) && shift ;;
        --label=*) labels+=("${1#--label=}"); shift ;;
        -d|--driver|-o|--opt) shift; (( $# )) && shift ;;
        -*) shift ;;
        *) name="$1"; shift ;;
      esac
    done
    if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]]; then
      printf 'Error response from daemon: invalid volume name %s\n' "${name:-(none)}" >&2
      exit 1
    fi
    if [[ ! -d "$state/$name" ]]; then
      mkdir "$state/$name" || exit 1
      if (( ${#labels[@]} )); then printf '%s\n' "${labels[@]}"; fi > "$state/$name/labels"
    fi
    printf '%s\n' "$name"
    ;;
  inspect)
    fmt="" names=() rc=0
    while (( $# )); do
      case "$1" in
        -f|--format) fmt="${2:-}"; shift; (( $# )) && shift ;;
        --format=*) fmt="${1#--format=}"; shift ;;
        *) names+=("$1"); shift ;;
      esac
    done
    (( ${#names[@]} )) || { printf 'docker volume inspect: requires at least 1 argument\n' >&2; exit 1; }
    out=()
    for n in "${names[@]}"; do
      if [[ "$n" == */* || ! -d "$state/$n" ]]; then no_such "$n"; rc=1; continue; fi
      if [[ "$fmt" =~ index\ \.Labels\ \"([^\"]*)\" ]]; then
        key="${BASH_REMATCH[1]}" val=""
        while IFS= read -r line; do
          if [[ "$line" == "$key="* ]]; then val="${line#"$key="}"; break; fi
        done < "$state/$n/labels"
        out+=("$val")
      elif [[ -n "$fmt" ]]; then
        out+=("$n")
      else
        out+=("{\"Name\": \"$n\", \"Driver\": \"local\"}")
      fi
    done
    if [[ -n "$fmt" ]]; then
      if (( ${#out[@]} )); then printf '%s\n' "${out[@]}"; fi
    elif (( ${#out[@]} )); then
      printf '['; ( IFS=,; printf '%s' "${out[*]}" ); printf ']\n'
    fi
    exit "$rc"
    ;;
  rm)
    rc=0
    for n in "$@"; do
      case "$n" in -f|--force) continue ;; esac
      if [[ "$n" == */* || ! -d "$state/$n" ]]; then no_such "$n"; rc=1; continue; fi
      rm -rf -- "${state:?}/$n" || rc=1
      printf '%s\n' "$n"
    done
    exit "$rc"
    ;;
  ls)
    substr=""
    while (( $# )); do
      case "$1" in
        --filter|-f) [[ "${2:-}" == name=* ]] && substr="${2#name=}"; shift; (( $# )) && shift ;;
        --filter=name=*) substr="${1#--filter=name=}"; shift ;;
        --format) shift; (( $# )) && shift ;;
        *) shift ;;
      esac
    done
    for d in "$state"/*/; do
      [[ -d "$d" ]] || continue
      n="${d%/}"; n="${n##*/}"
      if [[ "$n" == *"$substr"* ]]; then printf '%s\n' "$n"; fi
    done
    ;;
  *)
    printf 'docker volume %s: not emulated by lib-fake-docker-volume.sh\n' "$sub" >&2
    exit 1
    ;;
esac
exit 0
