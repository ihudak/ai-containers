#!/usr/bin/env bash
# mutate.sh — apply the known-bad configuration a case is supposed to catch.
#
# The suite's authoring rule: "a security case is not accepted until it has been
# demonstrated to FAIL against the known-bad configuration". A case never
# observed failing is not a regression test — it is a case that is green because
# its primitive is broken, which manufactures exactly the false confidence this
# suite exists to eliminate.
#
# For increment 1 that demonstration was possible by hand, and two of the bugs
# were preserved as fixtures under tests/integration/fixtures/. Increment 2's
# known-bad configurations live in PRODUCTION files — a dropped :ro suffix, a
# missing chown, a collision check downgraded to a warning — so they cannot be
# kept as fixture copies. They are kept as patches instead, and this script
# applies and reverts them:
#
#     tests/integration/mutate.sh list
#     tests/integration/mutate.sh apply 400-ro-suffix-dropped
#     tests/integration/run.sh --reuse-image --tags mounts     # expect FAIL
#     tests/integration/mutate.sh revert
#
# Patches, not sed expressions, for one reason: a patch that no longer applies
# is a LOUD failure. When someone refactors sandbox.sh's repo loop, `git apply`
# refuses and tests/test-mutations.sh goes red, saying the demonstration is
# stale. A sed expression would quietly match nothing and report success,
# leaving a mutation that mutates nothing — the decorative check this whole
# project keeps finding.
set -uo pipefail

INT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$INT_DIR/../.." && pwd)"
[[ -f "$REPO_DIR/build.sh" ]] || REPO_DIR="$(cd "$INT_DIR/../../base" && pwd)"
MUT_DIR="$INT_DIR/mutations"
STATE="$MUT_DIR/.applied"

usage() {
  cat <<'EOF'
Usage: tests/integration/mutate.sh <command>

  list              every mutation, the case it must break, and what it changes
  apply <id>        apply one mutation (refuses unless the tree is clean)
  revert            undo the applied mutation
  verify            check every patch still applies (no changes made)

A mutation makes the product WRONG on purpose. Revert before committing;
`git status` will show the touched file until you do.
EOF
}

patch_field() {  # $1=patch $2=field → the header value
  sed -n "s/^# $2:[[:space:]]*//p" "$1" | head -1
}

cmd_list() {
  local p id
  printf '%-38s %-34s %s\n' "MUTATION" "BREAKS CASE" "WHAT IT CHANGES"
  for p in "$MUT_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    id="$(basename "$p" .patch)"
    printf '%-38s %-34s %s\n' "$id" "$(patch_field "$p" case)" "$(patch_field "$p" what)"
  done
}

cmd_verify() {
  local p bad=0
  for p in "$MUT_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    if ( cd "$REPO_DIR" && git apply --check "$p" ) 2>/dev/null; then
      printf 'ok      %s\n' "$(basename "$p" .patch)"
    else
      printf 'STALE   %s — the code it patches has changed\n' "$(basename "$p" .patch)" >&2
      bad=1
    fi
  done
  return "$bad"
}

cmd_apply() {
  local id="${1:-}"
  [[ -n "$id" ]] || { printf 'mutate.sh: apply needs a mutation id (see `list`)\n' >&2; exit 2; }
  local p="$MUT_DIR/$id.patch"
  [[ -f "$p" ]] || { printf 'mutate.sh: no such mutation: %s\n' "$id" >&2; exit 2; }
  if [[ -f "$STATE" ]]; then
    printf 'mutate.sh: %s is still applied — revert first\n' "$(cat "$STATE")" >&2
    exit 1
  fi
  # A dirty tree makes revert ambiguous and risks discarding real work.
  if ! ( cd "$REPO_DIR" && git diff --quiet ); then
    printf 'mutate.sh: the working tree has unstaged changes — commit or stash first.\n' >&2
    printf '           A mutation must be the only difference, or reverting it is a guess.\n' >&2
    exit 1
  fi
  ( cd "$REPO_DIR" && git apply "$p" ) || {
    printf 'mutate.sh: %s no longer applies. The code it breaks has changed; regenerate it.\n' "$id" >&2
    exit 1
  }
  printf '%s' "$id" > "$STATE"
  printf 'Applied %s — %s\n' "$id" "$(patch_field "$p" what)"
  printf 'Now run:  tests/integration/run.sh --reuse-image --tags <tier>   (expect %s to FAIL)\n' \
    "$(patch_field "$p" case)"
  printf 'Then:     tests/integration/mutate.sh revert\n'
}

cmd_revert() {
  [[ -f "$STATE" ]] || { printf 'mutate.sh: nothing applied.\n'; return 0; }
  local id; id="$(cat "$STATE")"
  ( cd "$REPO_DIR" && git apply -R "$MUT_DIR/$id.patch" ) || {
    printf 'mutate.sh: could not reverse %s cleanly. Recover with: git checkout -- <file>\n' "$id" >&2
    exit 1
  }
  rm -f "$STATE"
  printf 'Reverted %s\n' "$id"
}

case "${1:-}" in
  list)   cmd_list ;;
  verify) cmd_verify ;;
  apply)  shift; cmd_apply "${1:-}" ;;
  revert) cmd_revert ;;
  -h|--help|help|"") usage ;;
  *) printf 'mutate.sh: unknown command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
