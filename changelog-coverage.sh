#!/usr/bin/env bash
# changelog-coverage.sh — what has landed since the last tag, and whether the
# Unreleased section accounts for it. Run before cutting a release.
#
# WHY A REPORT AND NOT A GATE. The obvious design is a per-PR check: "you
# touched non-docs files, so add a CHANGELOG entry". Measured against this
# repo's own history (43 merges, v0.9.3..HEAD) that rule fires on about twenty
# of them, and most are test-coverage slices this project deliberately
# summarises at release time rather than per PR. A check that cries wolf on
# half of all commits is suppressed within a week and then catches nothing,
# which is worse than no check because it looks like coverage.
#
# The refined rule — "if non-docs commits exist since the last tag, Unreleased
# must be non-empty" — was measured too: it catches the real misses AND fires
# on every release commit, because a release MOVES entries out of Unreleased
# and leaves it empty by construction. Eight false positives in fourteen
# sampled commits.
#
# So the check is made at the moment the omission actually costs something. The
# failure this exists for was never "this PR lacks an entry" — twice in two days
# it was "a release is being cut and several merged fixes are described
# nowhere" (#200/#201, then #211/#212). That is a release-time question, it
# needs no definition of "functional change", and it imposes no per-PR friction.
#
# WHAT IT DELIBERATELY DOES NOT TRY TO DO. The first version matched PR numbers
# from merge subjects against the Unreleased text and listed the misses as
# "worth checking". On its first run against this repo it flagged both merges it
# was pointed at — and both were already described in full, just without their
# numbers written out. A heuristic that is 100% noise on first contact is the
# very thing this script's own reasoning rejects, so it is gone.
#
# What remains has no false-positive concept at all: it LISTS the non-docs
# merges a release would contain, so a human can read the notes against them,
# and it raises exactly one mechanical alarm — non-docs commits exist and
# Unreleased is empty. That condition needs no judgement and was the actual
# failure both times.
set -uo pipefail

# The declared bash floor, as every entry point here does: this is run by a
# human before tagging, and finding out from a release that it ran under an
# unsupported bash is not an acceptable failure mode.
# shellcheck source=bash-floor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-floor.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="${CHANGELOG_FILE:-$here/CHANGELOG.md}"
strict=0

usage() {
  sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//; s/^#$//'
  printf '\nUsage: %s [--check]\n\n  --check   exit 1 when there are non-docs commits since the last tag\n            and the Unreleased section is empty. Otherwise always exits 0.\n' \
    "$(basename "${BASH_SOURCE[0]}")"
}

for arg in "$@"; do
  case "$arg" in
    --check) strict=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$CHANGELOG" ]] || { printf 'ERROR: no CHANGELOG at %s\n' "$CHANGELOG" >&2; exit 2; }

# A project copy is not a git repo and has no releases; say so and succeed,
# rather than reporting an empty range as if it were a clean bill of health.
if ! git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'SKIP: not a git repository — release coverage is a base-repo question\n'
  exit 0
fi
tag="$(git -C "$here" describe --tags --abbrev=0 2>/dev/null)"
if [[ -z "$tag" ]]; then
  printf 'SKIP: no tags yet, so there is no "since the last release" to report on\n'
  exit 0
fi

# ── what landed ───────────────────────────────────────────────────────────────
# --first-parent: one line per merge, not per commit inside it, because the unit
# a reader accounts for is the merged change.
mapfile -t merges < <(git -C "$here" log --first-parent --format='%h|%s' "$tag..HEAD" 2>/dev/null)

nondocs=0
docs_only=0
declare -a landed=()
unreleased="$(awk '/^## Unreleased/{f=1;next} /^## v[0-9]/{f=0} f' "$CHANGELOG")"
entries="$(printf '%s\n' "$unreleased" | grep -c '^### ' || true)"

for m in "${merges[@]}"; do
  sha="${m%%|*}"; subj="${m#*|}"
  # Files the merge introduced, against its FIRST parent: a merge commit has no
  # diff of its own, so `git show --name-only` on one prints nothing and would
  # silently classify every merge as docs-only.
  files="$(git -C "$here" diff --name-only "${sha}^1" "$sha" 2>/dev/null)"
  # A HERE-STRING, NOT A PIPE. `producer | grep -q` under `pipefail` can report
  # the opposite of what it observed: grep -q exits on its first match, the
  # producer dies of SIGPIPE, and the pipeline status becomes 141 (backlog F34,
  # enforced over every tracked script by tests/test-grep-q-pipelines.sh — which
  # caught this line in the very tool written to catch omissions).
  if grep -qvE '^(docs/|CHANGELOG\.md$|$)' <<< "$files"; then
    nondocs=$(( nondocs + 1 ))
    landed+=("$sha  ${subj}")
  else
    docs_only=$(( docs_only + 1 ))
  fi
done

# ── report ────────────────────────────────────────────────────────────────────
printf 'since %s: %d merge(s) — %d touching non-docs files, %d docs-only\n' \
  "$tag" "${#merges[@]}" "$nondocs" "$docs_only"
printf 'Unreleased: %s entr%s\n' "$entries" "$([[ "$entries" == "1" ]] && echo y || echo ies)"

if (( nondocs > 0 && entries == 0 )); then
  printf '\nEMPTY UNRELEASED with %d non-docs merge(s) since %s.\n' "$nondocs" "$tag"
  printf 'Cutting a release now would publish notes describing none of them.\n'
  for u in "${landed[@]}"; do printf '  %s\n' "$u"; done
  (( strict )) && exit 1
  exit 0
fi

if (( ${#landed[@]} > 0 )); then
  printf '\nthe non-docs merges these notes should account for:\n'
  for u in "${landed[@]}"; do printf '  %s\n' "$u"; done
fi
exit 0
