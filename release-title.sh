#!/usr/bin/env bash
# release-title.sh — print the GitHub Release title for a tag.
#
# WHY THIS EXISTS. `.github/workflows/release.yml` passes only `body_path` to
# softprops/action-gh-release, so the release NAME defaults to the tag string:
# every release published so far has been titled "v0.6.0", "v0.7.0", and every
# descriptive title in the repo's history was typed in by hand afterwards. A
# manual step that is invisible until someone notices a bare title is a step
# that will be forgotten.
#
# The description already exists in the right place — the annotated tag's own
# message, written at the moment of tagging:
#
#   git tag -a v0.7.0 -m "v0.7.0 — a real repo reset, two host helper scripts"
#
# So the tag becomes the single author of BOTH the notes and the title, which is
# the same principle changelog-section.sh already established for the body: one
# thing writes it, and what it writes was reviewed before the tag was cut.
#
# ── WHY A SCRIPT AND NOT THREE LINES OF YAML ─────────────────────────────────
# Logic in a workflow can be read but not run: nothing in the hermetic suite can
# execute a `run:` block, so its only guarantee is that someone looked at it.
# changelog-section.sh was extracted for exactly this reason and is covered by
# tests/test-changelog-section.sh; this file follows it, and
# tests/test-release-title.sh drives it against real annotated and lightweight
# tags in a throwaway repository.
#
# ── THE FAILURE MODE THIS IS SHAPED AROUND ───────────────────────────────────
# "Lightweight tag" and "annotated tag whose object was never fetched" both
# produce an EMPTY `%(contents:subject)`. Treating them the same would mean a
# shallow checkout silently publishes a bare title that looks exactly like a
# deliberate choice. So the two are told apart by the object's TYPE, not by
# whether the subject came back empty:
#
#   git cat-file -t <tag>  ->  "tag"     annotated: use its subject
#                              "commit"  lightweight: fall back to the tag name
#                              error     not present at all: fail loudly
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/bash-floor.sh
source "${_here}/bash-floor.sh"

die() { printf 'release-title: %s\n' "$1" >&2; exit 1; }

tag="${1:-}"
[[ -n "$tag" ]] || die "usage: release-title.sh <tag>"

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

# The object the tag NAME resolves to. `<tag>^{}` would peel straight through to
# the commit and lose the distinction this whole script turns on.
kind="$(git cat-file -t "refs/tags/$tag" 2>/dev/null)" \
  || die "no such tag: $tag — the release title cannot be derived from a tag that is not here (a shallow fetch that omitted tag objects looks exactly like this)"

case "$kind" in
  tag)
    # Annotated. `%(contents:subject)` is the first line of the message, which
    # is the convention `git tag -m` already produces.
    subject="$(git tag -l --format='%(contents:subject)' "$tag" 2>/dev/null | head -1)"
    # Trim, then decide: an annotated tag with an EMPTY message is a real thing
    # (`git tag -a v1 -m ""`), and it should fall back rather than publish a
    # blank title.
    subject="${subject#"${subject%%[![:space:]]*}"}"
    subject="${subject%"${subject##*[![:space:]]}"}"
    if [[ -n "$subject" ]]; then printf '%s\n' "$subject"; else printf '%s\n' "$tag"; fi
    ;;
  commit)
    # Lightweight: there is no message to read, and that is not an error — it is
    # simply a tag with nothing to say. The tag name is the honest title.
    printf '%s\n' "$tag"
    ;;
  *)
    die "refs/tags/$tag is a '$kind' object, which is neither an annotated tag nor a lightweight one"
    ;;
esac
