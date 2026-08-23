#!/usr/bin/env bash
# changelog-section.sh — print ONE version's section of CHANGELOG.md, so a tag
# push can publish the notes a human already wrote.
#
# WHY THIS EXISTS. `.github/workflows/release.yml` used to publish
# `generate_release_notes: true` — GitHub's own list of merged pull requests.
# That is a different artefact from the CHANGELOG: it names every branch that
# landed and explains none of them. Worse, it RACED with anyone who also ran
# `gh release create`, because both wrote the same body and neither waited for
# the other. The v0.5.0 release still carries the generated block twice for
# exactly that reason, and v0.6.0 needed a hand edit to remove a duplicated
# "Full Changelog" line. Now the tag push is the only author, and what it
# publishes is the section already reviewed in the CHANGELOG's own pull request.
#
# A tag whose version has NO section is an error, not an empty release. The
# whole premise is that the notes were written before the tag was cut, so
# publishing silence would defeat the change rather than degrade gracefully.
set -uo pipefail

# The declared bash floor, in one place, as every other entry point does it.
# This script uses mapfile, `printf -v` and array slicing, and its whole job is
# to decide what a release publishes — running it under an unsupported bash and
# finding out from the release body is not an acceptable failure mode.
# shellcheck source=bash-floor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-floor.sh"

usage() {
  printf 'usage: %s <version> [changelog-path]\n' "${0##*/}" >&2
  printf '  version         section heading to extract, exactly as written (e.g. v0.6.0)\n' >&2
  printf '  changelog-path  default: CHANGELOG.md beside this script\n' >&2
}

die() { printf 'changelog-section: %s\n' "$1" >&2; exit 1; }

if (( $# < 1 || $# > 2 )); then usage; exit 2; fi

version="$1"
[[ -n "$version" ]] || { usage; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die "cannot resolve own directory"
changelog="${2:-$here/CHANGELOG.md}"
[[ -r "$changelog" ]] || die "cannot read changelog: $changelog"

# The heading is matched as a LITERAL string, never as a regex. A version is
# mostly dots, and `.` in a pattern would let `v0.6.0` match a `v0X6Y0` heading
# — a heading that does not exist today and would be silently accepted the day
# somebody typos one. `## <version>` alone and `## <version> <anything>` (the
# em-dash and date this file actually uses) both open the section; `## v0.6`
# does NOT open `## v0.6.0 — …`, because the space is required.
prefix="## $version"

# Read with mapfile and walk an ARRAY rather than `while read … || [[ -n "$line" ]]`
# and `while [[ "$body" == *$'\n\n' ]]`. That is not style: the mutation tier
# scored four mutants of those two idioms UNPROVEN-by-timeout rather than
# KILLED, because negating either condition produces a genuine infinite loop —
# `read` fails at EOF with an empty line forever, and `${body%…}` on a body that
# does not end in the pattern strips nothing forever. A loop shape whose damaged
# form hangs cannot be measured, so it leaves the corpus in silence instead of
# owing the ledger a survivor. Every loop below is bounded by an array length.
mapfile -t lines < "$changelog" || die "cannot read changelog: $changelog"

found=0 collecting=0 fenced=0
declare -a body_lines=() headings=()

for line in "${lines[@]}"; do
  # A fenced code block can legitimately contain a line starting with `## `.
  # Outside a fence that ends the section; inside one it is content. No entry
  # needs this today — both CHANGELOGs are fence-free — which is precisely when
  # it is cheap to get right, rather than after a release publishes half a
  # section and nobody can see why.
  if [[ "$line" == '```'* || "$line" == '~~~'* ]]; then
    fenced=$(( 1 - fenced ))
  elif (( fenced == 0 )) && [[ "$line" == '## '* ]]; then
    headings+=("$line")
    if [[ "$line" == "$prefix" || "$line" == "$prefix "* ]]; then
      found=$(( found + 1 ))
      collecting=1
      continue
    fi
    collecting=0
    continue
  fi
  (( collecting == 1 )) && body_lines+=("$line")
done

if (( found == 0 )); then
  printf 'changelog-section: no "## %s" heading in %s\n' "$version" "$changelog" >&2
  if (( ${#headings[@]} > 0 )); then
    printf 'the file has:\n' >&2
    printf '  %s\n' "${headings[@]}" >&2
  else
    printf 'the file has no "## " headings at all\n' >&2
  fi
  exit 1
fi

# Two headings for one version is a bug in the CHANGELOG, and concatenating
# their bodies would hide it behind a release that looks merely long.
if (( found > 1 )); then
  die "$found headings match \"## $version\" in $changelog; expected exactly one"
fi

n_lines="${#body_lines[@]}"
start=0 end="$n_lines"
while (( start < end )) && [[ -z "${body_lines[start]//[[:space:]]/}" ]]; do start=$(( start + 1 )); done
while (( end > start )) && [[ -z "${body_lines[end - 1]//[[:space:]]/}" ]]; do end=$(( end - 1 )); done

body=""
(( end > start )) && printf -v body '%s\n' "${body_lines[@]:start:end - start}"

[[ -n "${body//[[:space:]]/}" ]] || die "the \"## $version\" section of $changelog is empty"

# GitHub rejects a release body over 125,000 characters. Refuse HERE, naming the
# size and the limit, rather than letting the workflow hand an oversized body to
# the API and fail on its message — which names neither, and arrives after the
# tag is already pushed. Not theoretical: the v0.6.0 section is 92,088 bytes,
# 74% of the ceiling, because it absorbed everything that had accumulated under
# `Unreleased`. Truncating instead would be worse: silently publishing part of a
# release note is the failure this script exists to prevent.
readonly BODY_MAX=125000
readonly BODY_WARN=100000
n_bytes="${#body}"
if (( n_bytes > BODY_MAX )); then
  die "the \"## $version\" section is $n_bytes characters; the GitHub release-body limit is $BODY_MAX"
fi
if (( n_bytes > BODY_WARN )); then
  printf 'changelog-section: warning: "## %s" is %s characters, %s%% of the %s limit\n' \
    "$version" "$n_bytes" "$(( n_bytes * 100 / BODY_MAX ))" "$BODY_MAX" >&2
fi

printf '%s' "$body"
