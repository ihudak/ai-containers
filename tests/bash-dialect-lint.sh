#!/usr/bin/env bash
# bash-dialect-lint.sh — reject bash constructs newer than the declared floor.
#
# WHY THIS EXISTS: the three bash versions in play are all different. The
# container and CI run 5.2, a developer's Mac runs 5.3, and the floor is 5.1.
# Nothing else compares them, so a brace-space command substitution written
# comfortably on the host would sail through review and CI and die at
# container start.
#
# Usage: bash-dialect-lint.sh [file…]   (no args = every tracked *.sh)
#
# MATCHING IS LINE-BASED AND NOT SHELL-AWARE, DELIBERATELY. An earlier
# version stripped comments before matching so a construct merely NAMED in
# a comment would not be flagged. That stripping was unsound: a hash that
# opens a real comment cannot be told apart, by regex alone, from a hash
# that is part of a quoted string, a bracket expression, or parameter-
# expansion prefix removal — every such variant either hid a real
# violation or let one through. Building a real shell tokenizer is out of
# scope for a lint script. Instead: match the RAW line, with no stripping
# at all, and accept the one remaining consequence — a rule's name written
# in a comment or a string literal gets flagged even though it is not a
# use. That is the correct bias for this guard: a false positive costs a
# human ten seconds; a false negative costs a container that will not
# start. A line that must not be flagged for a specific rule — because it
# IS that rule's own definition, or a test vector whose job is to contain
# the exact bad code the rule detects — carries an explicit, reviewable
# opt-out on that line, in the same idiom as this repo's
# `# shellcheck disable=SCxxxx` comments:
#
#   # dialect-lint: allow RULE-ID: reason
#
# The reason is required (checked for, not just documented) — a marker
# with no reason after the colon does not suppress anything.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like verify-on-host.sh / test-layer-containment.sh /
# test-bash-floor.sh: upstream ai-containers keeps bash-floor.sh beside
# tests/, mgd-ai-containers keeps it in base/ with tests/ one level up. This
# file is invoked directly by BOTH repos' hermetic-checks.yml lint job and by
# verify-on-host.sh Phase 7, so it needs the same fallback those already
# have — without it, REPO_DIR/bash-floor.sh resolves to the mgd repo ROOT,
# where the file does not exist (it is in base/), and this script dies with
# "No such file or directory" the moment it is run there.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/bash-floor.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
# shellcheck source=../bash-floor.sh
[[ -n "${AI_CONTAINERS_BASH_FLOOR_MAJOR:-}" ]] || source "$ENGINE_DIR/bash-floor.sh"
FLOOR_MAJOR="$AI_CONTAINERS_BASH_FLOOR_MAJOR"
FLOOR_MINOR="$AI_CONTAINERS_BASH_FLOOR_MINOR"

# One row per construct: <major> <minor>|<rule-id>|<extended-regex>|<description>
# Only constructs ABOVE the floor are reported, so raising or lowering the
# floor in bash-floor.sh changes what this permits with no edit here.
#
# An ARRAY, not one multi-line string: a handful of rows below name a bash
# variable that cannot be described without spelling out the exact
# identifier its own regex hunts for, so the row unavoidably matches
# itself. Those rows carry a real, genuine `# …` shell comment — which only
# works OUTSIDE a quoted string, i.e. once each row is its own array
# element rather than one line inside a single multi-line string.
RULES=(
  '5 3|dollar-brace-space|\$\{[[:space:]]|brace-space command substitution'
  '5 3|BASH_MONOSECONDS|BASH_MONOSECONDS|BASH_MONOSECONDS'  # dialect-lint: allow BASH_MONOSECONDS: this row is the rule's own definition, not a use
  '5 3|BASH_TRAPSIG|BASH_TRAPSIG|BASH_TRAPSIG'  # dialect-lint: allow BASH_TRAPSIG: this row is the rule's own definition, not a use
  '5 3|GLOBSORT|GLOBSORT|GLOBSORT'  # dialect-lint: allow GLOBSORT: this row is the rule's own definition, not a use
  '5 2|globskipdots|shopt[[:space:]]+-[su][[:space:]].*globskipdots|shopt globskipdots'
  '5 2|noexpand_translation|shopt[[:space:]]+-[su][[:space:]].*noexpand_translation|shopt noexpand_translation'
  '5 2|varredir_close|shopt[[:space:]]+-[su][[:space:]].*varredir_close|shopt varredir_close'
  '5 1|SRANDOM|SRANDOM|SRANDOM'
  '5 1|case-mod-expansion|\$\{[A-Za-z_][A-Za-z0-9_]*@[UuLKk]\}|case-modifying parameter expansion (@U/@u/@L/@K/@k)'
  '5 0|EPOCHSECONDS|EPOCHSECONDS|EPOCHSECONDS'
  '5 0|EPOCHREALTIME|EPOCHREALTIME|EPOCHREALTIME'
  '5 0|BASH_ARGV0|BASH_ARGV0|BASH_ARGV0'
  '4 4|attr-expansion|\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAa]\}|attribute parameter expansion (@Q/@E/@P/@A/@a)'
)

files=("$@")
if [[ "${#files[@]}" -eq 0 ]]; then
  while IFS= read -r f; do files+=("$REPO_DIR/$f"); done \
    < <(cd "$REPO_DIR" && git ls-files '*.sh')
fi
# A lint run that examined nothing must not report success — the same rule the
# `bash -n over every script` CI step already applies to itself.
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "ERROR: bash-dialect-lint.sh examined no files" >&2
  exit 1
fi

# $1 = a matched line's raw text, $2 = the rule id being checked against it.
marker_allows() {
  grep -qE "#[[:space:]]*dialect-lint:[[:space:]]*allow[[:space:]]+${2}:[[:space:]]*[^[:space:]]" <<<"$1"
}

rc=0
for rule in "${RULES[@]}"; do
  [[ -n "$rule" ]] || continue
  ver="${rule%%|*}"; rest="${rule#*|}"
  id="${rest%%|*}"; rest="${rest#*|}"
  re="${rest%%|*}"; desc="${rest#*|}"
  rmaj="${ver%% *}"; rmin="${ver##* }"
  # Permitted at or below the floor.
  (( rmaj < FLOOR_MAJOR || (rmaj == FLOOR_MAJOR && rmin <= FLOOR_MINOR) )) && continue
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS=: read -r lineno linetext; do
      [[ -n "$lineno" ]] || continue
      marker_allows "$linetext" "$id" && continue
      printf '%s:%s: uses %s (bash %s.%s) — floor is %s.%s\n' \
        "${f#"$REPO_DIR"/}" "$lineno" "$desc" "$rmaj" "$rmin" "$FLOOR_MAJOR" "$FLOOR_MINOR" >&2
      rc=1
    done < <(grep -nE "$re" "$f")
  done
done
exit "$rc"
