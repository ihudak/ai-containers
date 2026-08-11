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

# The patches carry upstream ai-containers paths (a/sandbox.sh), but
# mgd-ai-containers keeps the engine in base/ — the same layout split run.sh and
# lib.sh already resolve. Rather than maintain a second set of patches per repo
# (two copies of the same known-bad configuration, guaranteed to drift), apply
# them with `--directory=base` there. One mutation set serves both layouts, and
# the shared files stay byte-identical, which is the property that lets a fix in
# one repo be a straight copy into the other.
GIT_ROOT="$( cd "$REPO_DIR" && git rev-parse --show-toplevel 2>/dev/null )" || GIT_ROOT="$REPO_DIR"
APPLY_PREFIX=""
if [[ "$REPO_DIR" != "$GIT_ROOT" ]]; then
  APPLY_PREFIX="${REPO_DIR#"$GIT_ROOT"/}"
fi
git_apply() {  # $@ = git apply args (patch last)
  ( cd "$GIT_ROOT" && git apply ${APPLY_PREFIX:+--directory="$APPLY_PREFIX"} "$@" )
}

usage() {
  cat <<'EOF'
Usage: tests/integration/mutate.sh <command>

  list              every mutation, the case it must break, and what it changes
  apply <id>...     apply one or more mutations (refuses unless the tree is clean)
  revert            undo the applied mutation(s), in reverse order
  verify            check every patch still applies (no changes made)

A mutation makes the product WRONG on purpose. Revert before committing;
`git status` will show the touched file(s) until you do.
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
    if git_apply --check "$p" 2>/dev/null; then
      printf 'ok      %s\n' "$(basename "$p" .patch)"
    else
      printf 'STALE   %s — the code it patches has changed\n' "$(basename "$p" .patch)" >&2
      bad=1
    fi
  done
  return "$bad"
}

# One patch, exit 0 if it still applies. Exists so tests/test-mutations.sh does
# not carry a second copy of the layout resolution above — a copy that would be
# correct in this repo and silently wrong in the base/ one.
cmd_check() {
  local id="${1:-}"
  [[ -n "$id" ]] || { printf 'mutate.sh: check needs a mutation id\n' >&2; exit 2; }
  [[ -f "$MUT_DIR/$id.patch" ]] || { printf 'mutate.sh: no such mutation: %s\n' "$id" >&2; exit 2; }
  git_apply --check "$MUT_DIR/$id.patch" 2>/dev/null
}

cmd_apply() {  # $@ = one or more mutation ids
  [[ "$#" -gt 0 ]] || { printf 'mutate.sh: apply needs at least one mutation id (see `list`)\n' >&2; exit 2; }
  local id
  # Validate the WHOLE batch before touching the tree. A batch that applies
  # three patches and then rejects the fourth leaves a state no one asked for,
  # and the demonstration it was meant to produce is silently a different one.
  for id in "$@"; do
    [[ -f "$MUT_DIR/$id.patch" ]] || { printf 'mutate.sh: no such mutation: %s\n' "$id" >&2; exit 2; }
  done
  if [[ -f "$STATE" ]]; then
    printf 'mutate.sh: still applied — revert first:\n' >&2
    sed 's/^/  /' "$STATE" >&2
    exit 1
  fi
  if ! ( cd "$GIT_ROOT" && git diff --quiet ); then
    printf 'mutate.sh: the working tree has unstaged changes — commit or stash first.\n' >&2
    printf '           A mutation must be the only difference, or reverting it is a guess.\n' >&2
    exit 1
  fi
  for id in "$@"; do
    git_apply "$MUT_DIR/$id.patch" || {
      printf 'mutate.sh: %s no longer applies. The code it breaks has changed; regenerate it.\n' "$id" >&2
      # Roll back what this batch already applied, newest first, so the tree is
      # left exactly as found rather than half-mutated.
      #
      # The reversal is NOT silenced and its status IS checked. It used to be
      # `git_apply -R … 2>/dev/null` with the result discarded and $STATE
      # deleted unconditionally, so a rollback that failed reported exactly
      # like one that worked: a mutated production file left in the tree, no
      # message, and no state file recording that it was still applied. The
      # next `apply` then started from a tree it believed was clean. A
      # mutation is a deliberately WRONG product file; losing track of one is
      # the worst outcome this script has.
      if [[ -f "$STATE" ]]; then
        local done_id still=""
        while IFS= read -r done_id; do
          [[ -n "$done_id" ]] || continue
          if git_apply -R "$MUT_DIR/$done_id.patch"; then
            printf 'Reverted %s\n' "$done_id" >&2
          else
            printf 'mutate.sh: ROLLBACK FAILED for %s — it is STILL APPLIED.\n' "$done_id" >&2
            # Oldest-first, matching the order apply wrote them: this loop runs
            # newest-first, so prepend.
            still="$done_id${still:+ $still}"
          fi
        done < <(tac "$STATE" 2>/dev/null || sed '1!G;h;$!d' "$STATE")
        # $STATE must describe the TREE, not the intention. Rewrite it with
        # exactly what is still applied so the next `apply` refuses (correctly)
        # and `revert` has something to retry; remove it only when the tree is
        # genuinely back to where it started.
        if [[ -n "$still" ]]; then
          : > "$STATE"
          for done_id in $still; do printf '%s\n' "$done_id" >> "$STATE"; done
          printf 'mutate.sh: the tree is still mutated. %s records what is applied.\n' "$STATE" >&2
          printf '           Recover with: git checkout -- <file>, then rm %s\n' "$STATE" >&2
        else
          rm -f "$STATE"
        fi
      fi
      exit 1
    }
    printf '%s\n' "$id" >> "$STATE"
    printf 'Applied %s — %s\n' "$id" "$(patch_field "$MUT_DIR/$id.patch" what)"
  done
  printf '\nNow run:  tests/integration/run.sh --reuse-image --tags <tier>\n'
  printf 'Expect these cases to FAIL, and every other case to still PASS:\n'
  for id in "$@"; do printf '  %s\n' "$(patch_field "$MUT_DIR/$id.patch" case)"; done
  printf 'Then:     tests/integration/mutate.sh revert\n'
}

cmd_revert() {
  [[ -f "$STATE" ]] || { printf 'mutate.sh: nothing applied.\n'; return 0; }
  local id still=""
  # Reverse order. Two patches touching the same file apply cleanly forwards and
  # conflict backwards if reversed in the order they were applied.
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if git_apply -R "$MUT_DIR/$id.patch" 2>/dev/null; then
      printf 'Reverted %s\n' "$id"
    elif git_apply --check "$MUT_DIR/$id.patch" 2>/dev/null; then
      # The FORWARD patch applies cleanly, so the mutation is not in the tree at
      # all and there is nothing to undo — only a stale state file. .applied is
      # gitignored and therefore SURVIVES a branch switch or a `git checkout --`,
      # both entirely ordinary things to do between demonstrations; before this
      # branch that combination made `git apply -R` fail, `revert` exit 1 with
      # the state file still on disk, and the next `apply` refuse ("still
      # applied") against a pristine tree. That cost a wasted CI dispatch.
      #
      # Said as its own outcome, not folded into "Reverted": "I undid it" and
      # "it was already gone" are different facts about the tree, and a script
      # whose job is keeping the tree honest must not blur them.
      printf 'Already absent: %s — the tree does not carry it (state cleared, nothing undone)\n' "$id"
    else
      # Neither direction applies: the file matches neither the mutated nor the
      # clean text, so a human has to decide. Recorded, not exited on — the ids
      # not yet processed would otherwise be dropped from $STATE, losing track
      # of mutations that ARE still in the tree.
      printf 'mutate.sh: could not reverse %s, and the tree does not match the unmutated\n' "$id" >&2
      printf '           file either. Recover with: git checkout -- <file>\n' >&2
      still="$id${still:+ $still}"   # oldest-first; this loop runs newest-first
    fi
  done < <(tac "$STATE" 2>/dev/null || sed '1!G;h;$!d' "$STATE")
  # Same rule as cmd_apply's rollback: the state file describes the TREE.
  if [[ -n "$still" ]]; then
    : > "$STATE"
    for id in $still; do printf '%s\n' "$id" >> "$STATE"; done
    printf 'mutate.sh: %s still records what could not be reverted.\n' "$STATE" >&2
    exit 1
  fi
  rm -f "$STATE"
}

case "${1:-}" in
  list)   cmd_list ;;
  verify) cmd_verify ;;
  check)  shift; cmd_check "${1:-}" ;;
  apply)  shift; cmd_apply "$@" ;;
  revert) cmd_revert ;;
  -h|--help|help|"") usage ;;
  *) printf 'mutate.sh: unknown command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
