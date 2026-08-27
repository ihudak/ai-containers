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

# -P (physical): resolve symlinks in the path, e.g. macOS's /var -> /private/var
# under a mktemp -d tree. `git rev-parse --show-toplevel` below always returns a
# physically-resolved path (git resolves symlinks when walking up to find
# .git), so REPO_DIR must be resolved the same way or the string comparison
# against GIT_ROOT further down never matches on a host where the temp root is
# itself reached through a symlink — turning APPLY_PREFIX into the whole
# (bogus, absolute) REPO_DIR instead of an empty string, which `git apply
# --directory=` then treats as a path prefix and rejects every target path as
# invalid.
INT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$INT_DIR/../.." && pwd -P)"
[[ -f "$REPO_DIR/build.sh" ]] || REPO_DIR="$(cd "$INT_DIR/../../base" && pwd -P)"
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
# ── THE PREFIX IS PER PATCH, NOT PER REPO ────────────────────────────────────
# It was per repo until increment 5, and that was correct only while EVERY patch
# damaged an engine file. The network-tier mutations broke the assumption: they
# damage tests/integration/cases/*.sh and tests/integration/lib.sh, which sit at
# the REPO ROOT in both layouts — tests/ is never under base/. A blanket
# `--directory=base` turns those into base/tests/integration/... , which exists
# nowhere, so all thirteen were reported "no longer applies" here while passing
# upstream, where APPLY_PREFIX is empty and the bug cannot show.
#
# Upstream's copy of this file carries the same latent defect; it is invisible
# there for exactly that reason. Deciding the prefix from the PATCH rather than
# from the repo is the fix in both, and leaves the upstream behaviour bit-for-bit
# unchanged (an empty APPLY_PREFIX short-circuits before anything is inspected).
#
# The decision is made by ASKING THE FILESYSTEM where the patch's targets live,
# not by pattern-matching `tests/` — a rule keyed on a directory name would need
# editing the next time a patch damages something new, which is the same
# maintenance trap the blanket prefix already sprang once. The prefixed location
# is tried first, so every pre-existing engine patch resolves exactly as before.
_patch_targets() {   # <patch file> → its a/<path> targets, one per line
  sed -n 's|^--- a/||p' "$1"
}

# EVERY LINE OF THIS FUNCTION IS OBSERVABLE, and that is deliberate rather than
# incidental — the falsify tier measured the first draft and three of its mutants
# survived, all for the same reason: state nothing reads. It counted targets that
# resolved at the repo root into an `n_root` no decision used, and it carried two
# `return` statements whose status the only caller discards inside a `$(…)`. A
# line no assertion can watch is a line no assertion is watching, so they are
# gone rather than excused in the ledger. What is left is one printf whose
# presence or absence every damage above it changes:
#   * negate the APPLY_PREFIX test  → engine patches lose their prefix
#   * flip the `&&` before n_pref   → nothing counts as resolved, same result
#   * flip either comparison, or the final `&&` → the prefix is emitted always
#                                     or never, and one half of the patch set
#                                     stops applying either way
# tests/test-mutations.sh drives `mutate.sh check` over BOTH halves of the real
# mutation set — twenty engine patches under base/ and thirteen tests/ ones at
# the root — so each of those damages fails it by name.
#
# mapfile + a `for`, not a `while read`: a `while` head is one cond-negate away
# from never terminating, which the tier can only report as UNPROVEN (nothing
# was observed asserting) after burning the whole per-mutant timeout. A `for`
# over an array has no condition to negate.
patch_prefix() {   # <patch file> → the --directory value to use, or empty
  local patch="$1" path n_pref=0
  local -a paths=()
  if [[ -n "$APPLY_PREFIX" ]]; then
    mapfile -t paths < <(_patch_targets "$patch")
    for path in "${paths[@]}"; do
      [[ -e "$GIT_ROOT/$APPLY_PREFIX/$path" ]] && n_pref=$(( n_pref + 1 ))
    done
    # Unanimity or nothing. A patch whose targets straddle both roots cannot be
    # applied in one `git apply` at all, and a patch whose targets resolve
    # nowhere is stale — both must reach `git apply` and be REFUSED there,
    # loudly, rather than be silently applied against whichever half matched.
    (( ${#paths[@]} > 0 && n_pref == ${#paths[@]} )) && printf '%s' "$APPLY_PREFIX"
  fi
}

git_apply() {  # $@ = git apply args (patch last)
  local prefix
  prefix="$(patch_prefix "${*: -1}")"
  ( cd "$GIT_ROOT" && git apply ${prefix:+--directory="$prefix"} "$@" )
}

# NOT needed before every git_apply call: `git apply [--check|-R]` on a plain
# (non --index) patch, as all of ours are, needs no repository at all — verified
# empirically, it succeeds unchanged even run outside any git work tree, and
# under a simulated ownership-mismatch failure (GIT_TEST_ASSUME_DIFFERENT_OWNER=1).
# So cmd_verify/cmd_check/cmd_revert, which only ever call git_apply, stay
# correct in a git-unusable environment with no gate at all — adding one there
# would convert a check that still works into a spurious failure.
# cmd_apply is different: its OWN cleanliness gate (`git diff --quiet`, below)
# DOES need real repository access and fails the same way for "git is broken"
# and "there are unstaged changes" alike, so that one call site needs this.
require_git_usable() {
  git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1 && return 0
  printf 'mutate.sh: git is unusable against %s (ownership mismatch, unreadable, or not a repository) — nothing was verified.\n' "$GIT_ROOT" >&2
  return 1
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

# "DOES NOT APPLY" AND "COULD NOT BE CHECKED" ARE DIFFERENT ANSWERS, and only
# one of them means somebody has to regenerate a patch. `git apply --check`
# separates them and always has — measured, not assumed:
#
#   applies                 rc 0
#   does not apply          rc 1
#   never got that far      rc 128 (missing/unreadable patch, unusable repo)
#                           and any other status, including 128+N when the
#                           process is SIGKILLed under memory or process pressure
#
# Flattening the third into the second is how a killed `git` becomes the report
# "the code it patches has changed" — an instruction to go and edit a patch that
# was never examined. That happened: a macOS host run on 2026-08-27 reported
# 410-workspace-root-not-chowned stale while the patch applied cleanly on every
# other machine and nothing had touched entrypoint.sh in weeks.
#
# Same defect, same day, as the one tests/falsify/generate.sh carried between its
# `bash -n` gate and its DISCARD tally. Look for this shape wherever a checker's
# status is passed straight through.
cmd_verify() {
  local p id bad=0 rc
  for p in "$MUT_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    id="$(basename "$p" .patch)"
    git_apply --check "$p" 2>/dev/null
    rc=$?
    case "$rc" in
      0) printf 'ok      %s\n' "$id" ;;
      1) printf 'STALE   %s — the code it patches has changed\n' "$id" >&2
         bad=1 ;;
      *) printf 'UNCHECKED %s — git apply exited %s without judging the patch; NOTHING is known about whether it still applies\n' \
           "$id" "$rc" >&2
         bad=2 ;;
    esac
  done
  return "$bad"
}

# One patch. Exit 0 if it still applies, 1 if it does not, 3 if that could not be
# determined — see cmd_verify above for why the third is not folded into the
# second. 3 rather than 2 because 2 is already this script's usage error, and a
# caller must be able to tell "you called me wrong" from "git could not answer".
#
# Exists so tests/test-mutations.sh does not carry a second copy of the layout
# resolution above — a copy that would be correct in this repo and silently wrong
# in the base/ one.
cmd_check() {
  local id="${1:-}" rc
  [[ -n "$id" ]] || { printf 'mutate.sh: check needs a mutation id\n' >&2; exit 2; }
  [[ -f "$MUT_DIR/$id.patch" ]] || { printf 'mutate.sh: no such mutation: %s\n' "$id" >&2; exit 2; }
  git_apply --check "$MUT_DIR/$id.patch" 2>/dev/null
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) printf 'mutate.sh: git apply exited %s without judging %s — the patch was not examined\n' \
         "$rc" "$id" >&2
       return 3 ;;
  esac
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
  require_git_usable || exit 1
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
            # stdout, matching cmd_revert's identical line. Both report the same
            # fact — "this mutation is no longer in the tree" — and splitting one
            # to stderr made `mutate.sh apply a b c > log` record a partial
            # rollback in two places that a reader has to reassemble. The
            # ROLLBACK FAILED line below stays on stderr: that one is an error.
            printf 'Reverted %s\n' "$done_id"
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
