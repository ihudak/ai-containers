#!/usr/bin/env bash
# bash-dialect-lint.sh — reject bash constructs newer than the declared floor.
#
# WHY THIS EXISTS: the three bash versions in play are all different. The
# container and CI run 5.2, a developer's Mac runs 5.3, and the floor is 5.1.
# Nothing else compares them, so a `${ cmd; }` written comfortably on the host
# would sail through review and CI and die at container start.
#
# Usage: bash-dialect-lint.sh [file…]   (no args = every tracked *.sh)
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bash-floor.sh
[[ -n "${AI_CONTAINERS_BASH_FLOOR_MAJOR:-}" ]] || source "$REPO_DIR/bash-floor.sh"
FLOOR_MAJOR="$AI_CONTAINERS_BASH_FLOOR_MAJOR"
FLOOR_MINOR="$AI_CONTAINERS_BASH_FLOOR_MINOR"

# One row per construct: <major> <minor> <extended-regex> <description>
# Only constructs ABOVE the floor are reported, so raising or lowering the floor
# in bash-floor.sh changes what this permits with no edit here.
RULES='
5 3|\$\{[[:space:]]|${ command; } value substitution
5 3|BASH_MONOSECONDS|BASH_MONOSECONDS
5 3|BASH_TRAPSIG|BASH_TRAPSIG
5 3|GLOBSORT|GLOBSORT
5 2|shopt[[:space:]]+-[su][[:space:]]+globskipdots|shopt globskipdots
5 2|shopt[[:space:]]+-[su][[:space:]]+noexpand_translation|shopt noexpand_translation
5 2|shopt[[:space:]]+-[su][[:space:]]+varredir_close|shopt varredir_close
5 1|SRANDOM|SRANDOM
5 1|\$\{[A-Za-z_][A-Za-z0-9_]*@[UuLKk]\}|${var@U/@u/@L/@K/@k}
5 0|EPOCHSECONDS|EPOCHSECONDS
5 0|EPOCHREALTIME|EPOCHREALTIME
5 0|BASH_ARGV0|BASH_ARGV0
4 4|\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAa]\}|${var@Q/@E/@P/@A/@a}
'

files=("$@")
if [[ "${#files[@]}" -eq 0 ]]; then
  while IFS= read -r f; do
    # These two files ARE this linter's rule table and test-vector corpus:
    # every forbidden construct necessarily appears in them as a literal
    # string — a regex pattern, a human-readable rule description (e.g. the
    # RULES row for `${ command; }` itself contains the text "${ "), or a
    # throwaway vector's file content — never as real usage. That is a
    # structural false positive with no possible "clean" fix other than
    # excluding them from the default whole-tree scan. The exclusion applies
    # ONLY here, to the auto-discovered file list — an explicit invocation
    # (`bash-dialect-lint.sh tests/bash-dialect-lint.sh`) is never silently
    # filtered, it just inherits the same self-reference false positive, same
    # as it always would for a file whose job is to name every construct.
    case "$f" in
      tests/bash-dialect-lint.sh|tests/test-bash-dialect-lint.sh) continue ;;
    esac
    files+=("$REPO_DIR/$f")
  done < <(cd "$REPO_DIR" && git ls-files '*.sh')
fi
# A lint run that examined nothing must not report success — the same rule the
# `bash -n over every script` CI step already applies to itself.
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "ERROR: bash-dialect-lint.sh examined no files" >&2
  exit 1
fi

rc=0
while IFS= read -r rule; do
  [[ -n "$rule" ]] || continue
  ver="${rule%%|*}"; rest="${rule#*|}"
  re="${rest%%|*}"; desc="${rest#*|}"
  rmaj="${ver%% *}"; rmin="${ver##* }"
  # Permitted at or below the floor.
  (( rmaj < FLOOR_MAJOR || (rmaj == FLOOR_MAJOR && rmin <= FLOOR_MINOR) )) && continue
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    # Strip comments before matching: a construct named in a comment is not a
    # use. A `#` only starts a comment when it is at the start of the line or
    # preceded by whitespace — NOT the plain `sed 's/[[:space:]]*#.*$//'` this
    # started as, which also matched the `#` inside parameter-expansion prefix
    # removal (${var#pattern}, ${var##pattern} — both bash 2.0, all over this
    # repo, see e.g. sandbox-common.sh) and truncated the rest of the line,
    # silently discarding any real violation that followed it. Two -e passes
    # instead of one alternation so this stays POSIX BRE (no -E dependency).
    if sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' "$f" | grep -qE "$re"; then
      printf '%s: uses %s (bash %s.%s) — floor is %s.%s\n' \
        "${f#"$REPO_DIR"/}" "$desc" "$rmaj" "$rmin" "$FLOOR_MAJOR" "$FLOOR_MINOR" >&2
      rc=1
    fi
  done
done <<< "$RULES"
exit "$rc"
