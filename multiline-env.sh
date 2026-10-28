#!/usr/bin/env bash
# multiline-env.sh — rewrite the one-line lists in registered projects'
# sandbox.local.env one entry per line, the layout project-init.sh now writes:
#
#   EXTRA_MOUNTS="/a:ro /b /c:ro"      →      EXTRA_MOUNTS="
#                                               /a:ro
#                                               /b
#                                               /c:ro
#                                             "
#
# Usage:
#   ./multiline-env.sh [--dry-run] [--projects-conf <path>] [<project-path> ...]
#
# With no positional paths, reads project paths from --projects-conf (default:
# this repo's own projects.conf), exactly as migrate-runme.sh does.
#
# Only the list keys are touched — EXTRA_MOUNTS, REPOS, PREVIEW_PORTS — and only
# when they hold two or more entries on one line. Every other line, comments
# included, is kept as it is. Only sandbox.local.env is converted: sandbox.env is
# the portable file a team shares, and a teammate whose copy of the engine
# predates multi-line values would read the list as a bare `"`.
#
# For the same reason a project is SKIPPED when its own .ai-containers/ copy of
# load_env_defaults cannot read a multi-line value — run sync-to-projects.sh
# first. That is checked by running the project's loader on a probe file, not by
# looking for a version string. The converted file is read back with the same
# loader before it is written, and the project is left alone unless every list
# comes back as the same entries.
#
# Before writing, the old file is copied to sandbox.local.env.pre-multiline
# (timestamped instead when that backup already exists, so a second run never
# overwrites the first one), readable by you alone: the file may hold a token.
# Nothing is written through a symbolic link: a linked sandbox.local.env is skipped,
# checked again just before it is written, and the backup is created with noclobber.
# The run exits non-zero when any project could not be converted.
set -euo pipefail
unset CDPATH  # a relative cd follows it and prints the directory (bugs review GIT-17, GIT-20)
# shellcheck source=bash-floor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-floor.sh"

own_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourcing (not executing) project-init.sh pulls in emit_env_list — the one writer
# of the layout, so this script and a fresh project can never disagree — and its
# `projects_conf` global, without running the wizard (it returns early when sourced).
# shellcheck source=SCRIPTDIR/project-init.sh
source "${own_dir}/project-init.sh"
default_projects_conf="$projects_conf"

# One line holding a list key and its double-quoted value, optionally `export`ed.
list_line_re='^[[:space:]]*(export[[:space:]]+)?(EXTRA_MOUNTS|REPOS|PREVIEW_PORTS)="([^"]*)"[[:space:]]*$'

dry_run=0
projects_conf_arg=""
paths=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --projects-conf) projects_conf_arg="${2:-}"; shift 2 ;;
    --projects-conf=*) projects_conf_arg="${1#*=}"; shift ;;
    -h|--help)
      printf 'Usage: %s [--dry-run] [--projects-conf <path>] [<project-path> ...]\n' "$(basename "$0")"
      exit 0 ;;
    -*) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 1 ;;
    *) paths+=("$1"); shift ;;
  esac
done

target_conf="${projects_conf_arg:-$default_projects_conf}"

if [[ ${#paths[@]} -eq 0 ]]; then
  [[ -f "$target_conf" ]] || { printf 'ERROR: no projects.conf at %s and no paths given\n' "$target_conf" >&2; exit 1; }
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    paths+=("$line")
  done < "$target_conf"
fi

# load_with <sandbox-common.sh> <env-file> — print each list key the file sets, as
# KEY=<entries joined by single spaces>, read by THAT engine copy's own loader, as a
# sandbox.local.env (`local`; a loader that has no modes ignores the argument). The
# file's functions are lifted out rather than the file sourced: sourcing runs its top
# level, which loads the env files beside it. All of them, because the loader calls
# helpers whose names differ between engine versions.
load_with() {
  bash -c '
    eval "$(sed -n "/^[A-Za-z_][A-Za-z0-9_]*() *{/,/^}/p" "$1")"
    unset EXTRA_MOUNTS REPOS PREVIEW_PORTS
    load_env_defaults "$2" local 2>/dev/null
    for k in EXTRA_MOUNTS REPOS PREVIEW_PORTS; do
      [[ -n "${!k+x}" ]] || continue
      read -r -a e <<<"${!k}"
      printf "%s=%s\n" "$k" "${e[*]}"
    done
  ' _ "$1" "$2"
}

# reads_multiline <sandbox-common.sh> — does this engine copy join a multi-line value?
reads_multiline() {
  local probe got
  probe="$(mktemp)" || return 1
  printf 'REPOS="\n  a\n  b\n"\n' > "$probe"
  got="$(load_with "$1" "$probe")" || got=""
  rm -f "$probe"
  [[ "$got" == "REPOS=a b" ]]
}

count_converted=0
count_skipped=0
count_failed=0

process_project() {
  local project_path="$1"
  local dest="${project_path}/.ai-containers"
  local file="${dest}/sandbox.local.env"
  local line prefix key value new changed=0
  local -a entries

  printf '%s\n' "$project_path"
  # Never write THROUGH a link. .ai-containers/ lives in the project, where an agent
  # in the container may be able to plant one; this script runs on the host, so a
  # followed link would let that agent pick which host file gets overwritten.
  if [[ -L "$file" ]]; then
    printf '  SKIP  .ai-containers/sandbox.local.env is a symbolic link — left alone\n'
    ((++count_skipped)); return 0
  fi
  if [[ ! -f "$file" ]]; then
    printf '  SKIP  no .ai-containers/sandbox.local.env\n'
    ((++count_skipped)); return 0
  fi

  new=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $list_line_re ]]; then
      prefix="${BASH_REMATCH[1]:+export }"; key="${BASH_REMATCH[2]}"; value="${BASH_REMATCH[3]}"
      read -r -a entries <<<"$value"
      if (( ${#entries[@]} >= 2 )); then
        new+="$(emit_env_list "${prefix}${key}" "${entries[*]}")"$'\n'
        printf '  %s: %d entries → one per line\n' "$key" "${#entries[@]}"
        changed=1
        continue
      fi
    fi
    new+="${line}"$'\n'
  done < "$file"

  if (( ! changed )); then
    printf '  SKIP  no one-line list with two or more entries\n'
    ((++count_skipped)); return 0
  fi

  if ! reads_multiline "${dest}/sandbox-common.sh"; then
    printf '  SKIP  this copy of sandbox-common.sh cannot read a multi-line value yet — run sync-to-projects.sh first\n'
    ((++count_skipped)); return 0
  fi

  local candidate before after
  candidate="$(mktemp)" || return 1
  if ! printf '%s' "$new" > "$candidate"; then
    rm -f "$candidate"
    printf '  ERROR could not write a temporary file — left unchanged\n' >&2
    return 1
  fi
  before="$(load_with "${dest}/sandbox-common.sh" "$file")"
  after="$(load_with "${dest}/sandbox-common.sh" "$candidate")"
  if [[ "$before" != "$after" ]]; then
    rm -f "$candidate"
    printf '  ERROR the converted file would not read back the same lists — left unchanged\n' >&2
    return 1
  fi

  if (( dry_run )); then
    printf '  [dry-run] would change:\n'
    diff -u "$file" "$candidate" | tail -n +3 | sed 's/^/    /' || true
    rm -f "$candidate"
    ((++count_converted)); return 0
  fi

  # The backup is created with noclobber, so a name already taken by a regular file
  # or by a link — dangling or not — fails instead of being written through
  # (noclobber still opens an existing FIFO or device, so the name is checked for
  # anything at all first). umask 077: sandbox.local.env may hold a token, and the
  # copy must not be readable where the file is not.
  local backup="${file}.pre-multiline"
  [[ -e "$backup" || -L "$backup" ]] && backup="${backup}.$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -e "$backup" || -L "$backup" ]] || ! ( umask 077; set -C; cat "$file" > "$backup" ) 2>/dev/null; then
    rm -f "$candidate"
    printf '  ERROR could not create the backup %s — left unchanged\n' "$(basename "$backup")" >&2
    return 1
  fi
  # Checked again here: the loader runs above took time, and the directory may be
  # one an agent can write.
  if [[ -L "$file" || ! -f "$file" ]]; then
    rm -f "$candidate"
    printf '  ERROR sandbox.local.env changed into a link or a non-file while converting — left alone\n' >&2
    return 1
  fi
  if ! cat "$candidate" > "$file"; then   # keeps the file's own mode and owner
    rm -f "$candidate"
    printf '  ERROR could not write sandbox.local.env — it is unchanged; the backup %s can be removed\n' "$(basename "$backup")" >&2
    return 1
  fi
  rm -f "$candidate"
  printf '  Wrote sandbox.local.env (old file backed up as %s).\n' "$(basename "$backup")"
  ((++count_converted))
}

for p in "${paths[@]}"; do
  if ! process_project "$p"; then
    ((++count_failed))
    printf '  ERROR processing %s — see message above.\n' "$p" >&2
  fi
done

printf '\nDone. Converted: %d  Skipped: %d  Failed: %d\n' "$count_converted" "$count_skipped" "$count_failed"
if (( dry_run )); then
  printf '(dry-run: nothing was written)\n'
fi
(( count_failed == 0 ))
