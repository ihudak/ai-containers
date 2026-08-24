#!/usr/bin/env bash
# ai-containers-report.sh — report every project registered in THIS repo's
# project registry, and the container group each one uses.
#
# Reads ./projects.conf (the registry `project-init.sh` writes) and resolves
# each project's settings from its portable config,
# <project>/.ai-containers/sandbox.env — the single source of truth. A
# pre-rename <project>-container.sh is never read (sync-to-projects.sh migrates
# it); its presence is reported as a footnote instead.
#
# It does NOT search the filesystem for other ai-containers checkouts. An
# earlier version walked a configurable root to a fixed depth looking for every
# project-init.sh, which answered a different question — "what does this whole
# machine have" — and made the answer depend on where the script happened to be
# run from. To report another base, name it: the argument is a path, not a
# search.
#
# Output columns: container group | project | network mode | cpus | memory |
#                 discovery | path
# Sorted by group, then project name. With MORE THAN ONE base a BASE column is
# added and the sort leads with it; with one base the base is stated once above
# the table instead of repeated on every row. `--tsv` always emits the base
# column, so a machine-readable schema does not change shape with the argument
# count.
#
# Network mode / CPUs / memory come from SANDBOX_MODE, CONTAINER_CPUS and
# CONTAINER_MEMORY[_RESERVATION|_SWAP] (this-machine's sandbox.local.env overrides
# the portable sandbox.env); memory is shown as limit/reservation/swap. Discovery
# is the size of <project>/.ai-containers/.agent-discovery.
#
# Usage:
#   ./ai-containers-report.sh [options] [BASE_DIR ...]
#
#   With no BASE_DIR, reports this repo (the directory holding this script).
#   Each BASE_DIR is a directory containing projects.conf.
#
# Options:
#   --markdown            Emit a Markdown pipe table.
#   --tsv                 Emit raw tab-separated values (no header padding).
#   --full-paths          Do not abbreviate $HOME to '~'.
#   --no-notes            Suppress the footnotes section.
#   --path-map HOST=LOCAL Rewrite HOST path prefix to LOCAL for filesystem
#                         access only (paths are still reported as HOST).
#                         Repeatable — useful when running inside a container
#                         where the host's paths are mounted elsewhere.
#   -h, --help            Show this help.
#
# Environment:
#   AI_CONTAINERS_PATH_MAP   same as --path-map (space-separated list)

set -uo pipefail

# The directory this script lives in IS the base it reports on by default, and
# it is where bash-floor.sh sits beside it.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/bash-floor.sh
source "${script_dir}/bash-floor.sh"

# ---------------------------------------------------------------- args --------
format="text"
abbrev_home=1
show_notes=1
path_maps="${AI_CONTAINERS_PATH_MAP:-}"
bases=""

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

# Print the header comment, however long it is. A hardcoded line range silently
# truncates (or spills past) the moment the header changes length.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --markdown|--md) format="markdown"; shift ;;
    --tsv)        format="tsv"; shift ;;
    --full-paths) abbrev_home=0; shift ;;
    --no-notes)   show_notes=0; shift ;;
    --path-map)   [ $# -ge 2 ] || die "--path-map needs HOST=LOCAL"
                  case "$2" in *=*) ;; *) die "--path-map expects HOST=LOCAL, got '$2'" ;; esac
                  path_maps="${path_maps:+$path_maps }$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    # $'\n', not $(printf '\n'): command substitution strips trailing newlines,
    # so the separator was the empty string and two BASE_DIR arguments were
    # concatenated into one nonexistent path. Latent while the default was a
    # filesystem walk and nobody passed two; a real bug now that naming them is
    # the only way to report on more than one.
    *)            bases="${bases:+$bases$'\n'}$1"; shift ;;
  esac
done


# ------------------------------------------------------------- helpers --------
# Expand a leading '~' and strip trailing slashes.
canon_path() {
  _p="$1"
  # These are case PATTERNS matching a literal leading "~", not attempts to
  # expand one — expanding it is what the bodies do. The directive sits on the
  # `case` because shellcheck accepts none in front of an individual branch.
  # shellcheck disable=SC2088  # literal tilde in a case pattern, by design
  case "$_p" in
    "~") _p="$HOME" ;;
    "~/"*) _p="$HOME/${_p#\~/}" ;;
  esac
  while :; do
    case "$_p" in
      */) _p="${_p%/}" ;;
      *) break ;;
    esac
    [ -n "$_p" ] || { _p="/"; break; }
  done
  printf '%s' "$_p"
}

# Translate a host path to a locally reachable path via --path-map rules.
local_path() {
  _hp="$1"
  [ -n "$path_maps" ] || { printf '%s' "$_hp"; return; }
  for _m in $path_maps; do
    _from="${_m%%=*}"; _to="${_m#*=}"
    [ -n "$_from" ] || continue
    case "$_hp" in
      "$_from") printf '%s' "$_to"; return ;;
      "$_from"/*) printf '%s%s' "$_to" "${_hp#"$_from"}"; return ;;
    esac
  done
  printf '%s' "$_hp"
}

# Pretty-print a path for the report ($HOME -> ~ unless --full-paths).
display_path() {
  _dp="$1"
  if [ "$abbrev_home" -eq 1 ] && [ -n "${HOME:-}" ]; then
    case "$_dp" in
      "$HOME") _dp="~" ;;
      "$HOME"/*) _dp="~${_dp#"$HOME"}" ;;
    esac
  fi
  printf '%s' "$_dp"
}

# Last effective `AI_CONTAINER_GROUP=...` in sandbox.env (comments and
# AI_CONTAINER_GROUP_INIT ignored; quotes and trailing comments stripped).
launcher_group() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*(export[[:space:]]+)?AI_CONTAINER_GROUP[[:space:]]*=/ {
      v = $0
      sub(/^[^=]*=/, "", v)
      sub(/[[:space:]]*#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'\''|'\''$/, "", v)
      val = v
    }
    END { if (val != "") print val }
  ' "$1" 2>/dev/null
}

# Locate sandbox.env for a project (portable config, source of truth for group).
find_launcher() {
  _d="$1/.ai-containers"
  [ -f "$_d/sandbox.env" ] || return 1
  printf '%s' "$_d/sandbox.env"
}

# Last effective `NAME=...` value in an env file (comments, quotes and trailing
# comments stripped; a leading `export ` is tolerated). NAME must be a plain
# identifier. Empty when the file is absent or sets no active value. The `=`
# anchor keeps CONTAINER_MEMORY from matching CONTAINER_MEMORY_RESERVATION etc.
env_var() {
  awk -v name="$2" '
    BEGIN { re = "^[[:space:]]*(export[[:space:]]+)?" name "[[:space:]]*=" }
    /^[[:space:]]*#/ { next }
    $0 ~ re {
      v = $0
      sub(/^[^=]*=/, "", v)
      sub(/[[:space:]]*#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'\''|'\''$/, "", v)
      val = v
    }
    END { if (val != "") print val }
  ' "$1" 2>/dev/null
}

# Effective value of NAME for a project: this-machine's sandbox.local.env
# overrides the portable sandbox.env. Empty when neither sets it.
resolve_env_var() {
  _dir="$1/.ai-containers"
  _val="$(env_var "$_dir/sandbox.local.env" "$2")"
  [ -n "$_val" ] || _val="$(env_var "$_dir/sandbox.env" "$2")"
  printf '%s' "$_val"
}

# Map a raw SANDBOX_MODE value to a report label. Unset in both env files reports
# as DEFAULT-OPEN (the implicit "open" default).
network_mode_label() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    open)       printf 'OPEN' ;;
    discovery)  printf 'DISCOVERY' ;;
    restricted) printf 'RESTRICTED' ;;
    "")         printf 'DEFAULT-OPEN' ;;
    *)          printf '%s' "$1" | tr '[:lower:]' '[:upper:]' ;;
  esac
}

# Effective network-mode label for a project: sandbox.local.env SANDBOX_MODE
# overrides the portable sandbox.env value; DEFAULT-OPEN when neither sets it.
resolve_network_mode() {
  network_mode_label "$(resolve_env_var "$1" SANDBOX_MODE)"
}

# Human-readable size of a project's .ai-containers/.agent-discovery directory
# (N/A when it does not exist).
agent_discovery_size() {
  _ad="$1/.ai-containers/.agent-discovery"
  [ -d "$_ad" ] || { printf 'N/A'; return; }
  _sz="$(du -sh "$_ad" 2>/dev/null | cut -f1)"
  printf '%s' "${_sz:-N/A}"
}

# Pre-rename launchers (<project>-container.sh, superseded by runme.sh — see
# migrate_launcher_naming() in sync-to-projects.sh). Never read for the group:
# such a file does not launch anything anymore. Reported as a diagnostic only.
# A launcher is identified the same way the migration does it: the
# `export IMAGE_NAME=` marker.
legacy_launchers() {
  _d="$1/.ai-containers"
  [ -d "$_d" ] || return 0
  for _c in "$_d"/*-container.sh; do
    [ -f "$_c" ] || continue
    grep -qE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "$_c" 2>/dev/null || continue
    printf '%s ' "$(basename "$_c")"
  done
}

# ---------------------------------------------------------- the base(s) -------
# No arguments: this repo. Nothing is searched for — see the header.
if [ -z "$bases" ]; then
  bases="$script_dir"
  [ -f "$script_dir/projects.conf" ] || die "no projects.conf in $(display_path "$script_dir") — this repo has no registered projects yet. Run ./project-init.sh <path> first, or name another base explicitly."
fi

base_total="$(printf '%s\n' "$bases" | awk 'NF' | wc -l | tr -d ' ')"
# One base: the BASE column would be the same string on every row, so it is
# stated once above the table instead. More than one: it is the only thing
# telling the rows apart, so it comes back.
if [ "$base_total" -gt 1 ]; then first_col=1; else first_col=2; fi

# ---------------------------------------------------------- collect ----------
rows="$(mktemp)"; notes="$(mktemp)"; seen="$(mktemp)"
trap 'rm -f "$rows" "$notes" "$seen"' EXIT

proj_count=0

printf '%s\n' "$bases" | while IFS= read -r base_raw; do
  [ -n "$base_raw" ] || continue
  base="$(canon_path "$base_raw")"
  base_local="$(local_path "$base")"
  reg="$base_local/projects.conf"
  if [ ! -f "$reg" ]; then
    printf '%s: base %s has no projects.conf — skipped\n' "${0##*/}" "$(display_path "$base")" >&2
    continue
  fi
  base_label="$(display_path "$base")"

  # Registry lines: skip comments/blanks, tolerate a missing trailing newline.
  sed -e 's/[[:space:]]*$//' "$reg" | awk 'NF && $0 !~ /^[[:space:]]*#/' | while IFS= read -r line; do
    proj="$(canon_path "$line")"
    proj_local="$(local_path "$proj")"
    name="$(basename "$proj")"
    [ "$name" = "/" ] && name="(root)"

    group=""
    note=""
    netmode="n/a"
    cpu="n/a"
    mem="n/a"
    disc="N/A"
    if [ ! -d "$proj_local" ]; then
      group="n/a"
      note="path does not exist (stale registry entry)"
    else
      if launcher="$(find_launcher "$proj_local")"; then
        group="$(launcher_group "$launcher")"
        if [ -z "$group" ]; then
          group="default"
          note="sandbox.env sets no AI_CONTAINER_GROUP (implicit default)"
        fi
      else
        group="n/a"
        note="no .ai-containers/sandbox.env — run sync-to-projects.sh"
      fi
      netmode="$(resolve_network_mode "$proj_local")"
      cpu="$(resolve_env_var "$proj_local" CONTAINER_CPUS)"; [ -n "$cpu" ] || cpu="n/a"
      mem_lim="$(resolve_env_var "$proj_local" CONTAINER_MEMORY)"
      mem_rsv="$(resolve_env_var "$proj_local" CONTAINER_MEMORY_RESERVATION)"
      mem_swp="$(resolve_env_var "$proj_local" CONTAINER_MEMORY_SWAP)"
      if [ -n "$mem_lim$mem_rsv$mem_swp" ]; then
        mem="${mem_lim:--}/${mem_rsv:--}/${mem_swp:--}"
      fi
      disc="$(agent_discovery_size "$proj_local")"
      stale="$(legacy_launchers "$proj_local")"
      if [ -n "$stale" ]; then
        note="${note:+$note; }stale pre-rename launcher(s): ${stale% } (superseded by runme.sh)"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base_label" "$group" "$name" "$netmode" "$cpu" "$mem" "$disc" "$(display_path "$proj")" >>"$rows"
    [ -n "$note" ] && printf '%s (%s): %s\n' "$name" "$(display_path "$proj")" "$note" >>"$notes"
    printf '%s\t%s\n' "$proj" "$base_label" >>"$seen"
  done
done

# Projects registered in more than one base.
awk -F'\t' '{ c[$1]++; b[$1] = ($1 in b ? b[$1] ", " : "") $2 }
            END { for (p in c) if (c[p] > 1) printf "%s: registered in multiple bases (%s)\n", p, b[p] }' \
  "$seen" >>"$notes"

proj_count="$(wc -l <"$rows" | tr -d ' ')"

[ "$proj_count" -gt 0 ] || die "no projects found in any registry"

# ------------------------------------------------------------ render ---------
sorted="$(mktemp)"; trap 'rm -f "$rows" "$notes" "$seen" "$sorted"' EXIT

# One base: say which, once, instead of repeating it down a column.
if [ "$first_col" -eq 2 ] && [ "$format" != "tsv" ]; then
  printf 'base: %s\n\n' "$(display_path "$(canon_path "$bases")")"
fi

# With one base the sort key starts at the group; with several it leads with the
# base so a base's rows stay together.
if [ "$first_col" -eq 1 ]; then
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3 "$rows" >"$sorted"
else
  LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 "$rows" >"$sorted"
fi

case "$format" in
  tsv)
    # Always every column, including base. A machine-readable schema that
    # changed shape with the argument count would not be one.
    printf 'base\tcontainer_group\tproject\tnetwork_mode\tcpus\tmemory\tagent_discovery_size\tpath\n'
    cat "$sorted"
    ;;
  markdown)
    awk -F'\t' -v c0="$first_col" '
      BEGIN {
        h[1] = "Base"; h[2] = "Container group"; h[3] = "Project"; h[4] = "Network mode"
        h[5] = "CPUs"; h[6] = "Memory (limit/reservation/swap)"; h[7] = ".agent-discovery"; h[8] = "Path"
        head = ""; sep = ""
        for (i = c0; i <= 8; i++) { head = head "| " h[i] " "; sep = sep "|---" }
        print head "|"; print sep "|"
      }
      { row = ""
        for (i = c0; i <= 8; i++) row = row "| " (i == 8 ? "`" $i "`" : $i) " "
        print row "|" }
    ' "$sorted"
    ;;
  *)
    awk -F'\t' -v c0="$first_col" '
      BEGIN {
        h[1] = "BASE"; h[2] = "GROUP"; h[3] = "PROJECT"; h[4] = "NETWORK"
        h[5] = "CPUS"; h[6] = "MEM(L/R/S)"; h[7] = "DISCOVERY"; h[8] = "PATH"
      }
      { n++; for (i = c0; i <= 8; i++) { r[n, i] = $i; if (length($i) > w[i]) w[i] = length($i) } }
      END {
        for (i = c0; i <= 8; i++) if (length(h[i]) > w[i]) w[i] = length(h[i])
        # Built by concatenation rather than a printf with a fixed argument
        # list, because the number of columns is now a variable.
        line = ""; rule = ""
        for (i = c0; i <= 8; i++) {
          line = line (i < 8 ? sprintf("%-*s  ", w[i], h[i]) : h[i])
          pad = ""; for (j = 0; j < w[i]; j++) pad = pad "-"
          rule = rule pad (i < 8 ? "  " : "")
        }
        print line; print rule
        for (k = 1; k <= n; k++) {
          line = ""
          for (i = c0; i <= 8; i++) line = line (i < 8 ? sprintf("%-*s  ", w[i], r[k, i]) : r[k, i])
          print line
        }
      }
    ' "$sorted"
    ;;
esac

if [ "$show_notes" -eq 1 ] && [ "$format" != "tsv" ]; then
  if [ "$base_total" -gt 1 ]; then
    printf '\n%s base(s), %s registered project(s).\n' "$base_total" "$proj_count"
  else
    printf '\n%s registered project(s).\n' "$proj_count"
  fi
  if [ -s "$notes" ]; then
    printf '\nNotes:\n'
    LC_ALL=C sort -u "$notes" | sed 's/^/  - /'
  fi
fi
