#!/usr/bin/env bash
# Demonstrate every LAUNCHER/PACKAGES-tier mutation whose patch changes a file
# BAKED INTO THE IMAGE, by running its case against an image REBUILT WITH the
# mutation applied.
#
# WHY THIS EXISTS (backlog F36):
#
# AGENTS.md documents one demonstration procedure for a mutation:
#
#     tests/integration/mutate.sh apply 400-ro-suffix-dropped
#     tests/integration/run.sh --reuse-image --tags mounts   # expect 400 to FAIL
#     tests/integration/mutate.sh revert
#
# That procedure is correct for a patch that mutates a CASE FILE or the harness
# library, which the case reads from the working tree at run time. It is silently
# WRONG for a patch that mutates entrypoint.sh, link-default-ruby.sh,
# rvm-reconcile.sh, build.sh or the Dockerfile: --reuse-image runs the case
# against an image built BEFORE the patch existed, so the case PASSES and the
# mutation is reported dead when it was never applied to anything.
#
# demonstrate-network-tier.sh already solved this for the two tiers it covers,
# via patch_needs_rebuild() and a real rebuild. Those functions now live in
# lib-rebuild.sh and this script is their second consumer — the "launcher/
# packages-tier demonstrator that uses them" F36 asks for.
#
# SELECTION IS DERIVED, NOT LISTED. A patch is in scope here when it needs a
# rebuild AND its case is not in the network-mode/delivery tiers (which
# demonstrate-network-tier.sh owns). Today that is exactly nine patches across
# seven cases and three image variants. A tenth that starts touching a build
# input joins automatically; nothing here has to be remembered.
#
# OUTCOMES — a FAIL is the pass condition, as in the network demonstrator:
#   DEMONSTRATED   the case FAILed with a real `FAIL:` assertion line
#   UNDEMONSTRATED the case still PASSed with its mutation applied → THE FINDING
#   INCONCLUSIVE   FAIL verdict but no assertion line (the case bailed early)
#   SKIPPED        an unmet `requires:` capability — demonstrates nothing
#   ERROR          the case never ran
#
# WHY NO --keep, AND WHY NO build_clean_image() RESTORE: every patch selected
# here needs a rebuild, so none of them uses --reuse-image and none of them
# shares an image with the next. Without --keep, run.sh disposes of the image it
# built — the default variant in sweep() (run.sh:746), a non-default variant at
# run.sh:1258 — so no mutated image can outlive its own patch. That is a
# stronger guarantee than rebuilding a clean one afterwards, and it is why this
# script does not need demonstrate-network-tier.sh's restore dance. The cleanup
# trap still removes all three tags, because an interrupt can land between the
# build and run.sh's own disposal.
#
# COST. The packages tier costs tens of minutes per case: the `native` variant
# compiles every IT_RUBY_VERSIONS entry from source at CONTAINER START, and the
# `agents` variant does four npm global installs plus a uv tool install. This
# script therefore takes a budget and refuses to START a patch it cannot finish
# inside it, rather than discovering the overrun two hours in. Elapsed time per
# patch is reported so the next budget is a measurement, not a guess.
#
# NAMING: F37 records that demonstrate-network-tier.sh covers two tiers while
# its name says one, and sequences the rename after F36. This script inherits
# that awkwardness deliberately — it covers the launcher tier (mounts/volumes)
# AND the packages tier. When F37 lands, both collapse into demonstrate-
# mutations.sh and this comment goes with them.
#
# Usage:
#   bash tests/integration/demonstrate-launcher-tier.sh                 # all nine
#   bash tests/integration/demonstrate-launcher-tier.sh 410 630         # only these
#   bash tests/integration/demonstrate-launcher-tier.sh --dry-run       # plan only, no docker
#   bash tests/integration/demonstrate-launcher-tier.sh --budget-minutes 45
#   bash tests/integration/demonstrate-launcher-tier.sh --variant default
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR" || exit 1

MUT="$REPO_DIR/tests/integration/mutate.sh"
MUT_DIR="$REPO_DIR/tests/integration/mutations"
CASES_DIR="$REPO_DIR/tests/integration/cases"
RUN="$REPO_DIR/tests/integration/run.sh"
IT_IMAGE="${IT_IMAGE:-ai-sandbox-it}"

# Same two-layout resolution as demonstrate-network-tier.sh and mutate.sh: one
# copy of this file serves upstream (engine at the root) and mgd-ai-containers
# (engine in base/), so it must not assume either.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/build.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
[[ -f "$ENGINE_DIR/Dockerfile" ]] || {
  printf 'demonstrate-launcher-tier.sh: no Dockerfile under %s — cannot tell which patches need a rebuild.\n' "$ENGINE_DIR" >&2
  exit 1
}
# shellcheck source=tests/integration/lib-rebuild.sh
source "$REPO_DIR/tests/integration/lib-rebuild.sh"
# A source that FAILS must not be survivable. Neither script sets -e, so without
# this check a missing or unreadable lib-rebuild.sh prints one line to stderr and
# then patch_needs_rebuild resolves to command-not-found — rc 127, which `if`
# reads as "does not need a rebuild". Every build-input patch would silently take
# the --reuse-image path and be reported UNDEMONSTRATED: a mutation declared dead
# that was never applied to anything, which is the exact defect this library was
# extracted to prevent. Verified: with the path broken, all 11 rebuild patches
# read as reuse.
declare -F patch_needs_rebuild >/dev/null || {
  printf 'demonstrate-launcher-tier.sh: lib-rebuild.sh did not load — cannot tell which patches need a rebuild.\n' >&2
  exit 1
}

# ── Arguments ─────────────────────────────────────────────────────────────────
dry_run=0; budget_min=120; want_variant=""; wanted=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         dry_run=1; shift ;;
    --budget-minutes)  budget_min="$2"; shift 2 ;;
    --variant)         want_variant="$2"; shift 2 ;;
    -h|--help)         sed -n '68,74p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) printf 'demonstrate-launcher-tier.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    *)  wanted+=("$1"); shift ;;
  esac
done
[[ "$budget_min" =~ ^[0-9]+$ ]] || {
  printf 'demonstrate-launcher-tier.sh: --budget-minutes wants a positive integer, got %s\n' "$budget_min" >&2
  exit 2
}

# ── Refuse to start on a dirty tree ───────────────────────────────────────────
# The SAME whole-tree gate as mutate.sh:206 and demonstrate-network-tier.sh, and
# deliberately not a cleverer one. A narrower gate here (e.g. "only files some
# patch touches") would let this script start and then die at the first
# `mutate.sh apply`, which enforces the whole tree regardless — a gate looser
# than the one it delegates to buys nothing and reports the failure one layer
# too late. Untracked files do not trip `git diff --quiet`, so a new, uncommitted
# demonstrator (this file) can still be run from the tree it lives in.
if ! git -C "$REPO_DIR" diff --quiet; then
  printf 'demonstrate-launcher-tier.sh: working tree has unstaged changes — commit or stash first.\n' >&2
  printf '  A mutation must be the only difference, or reverting it is a guess.\n' >&2
  printf '  (mutate.sh enforces this too; failing here just says so before any image is built.)\n' >&2
  exit 1
fi

# ── Always revert, and never leave a mutated image ────────────────────────────
# run.sh disposes of its own image when --keep is absent, but an interrupt can
# land between the build and that disposal. All three variant tags, because a
# selected case can be on any of them.
cleanup() {
  bash "$MUT" revert >/dev/null 2>&1
  git -C "$REPO_DIR" checkout -- "$CASES_DIR" 2>/dev/null
  if [[ "$dry_run" -eq 0 ]]; then
    docker rmi -f "$IT_IMAGE" "$IT_IMAGE-agents" "$IT_IMAGE-native" >/dev/null 2>&1
  fi
}
trap cleanup EXIT INT TERM

case_meta() {  # $1=case file, $2=key → first value or empty
  sed -n "s/^#[[:space:]]*$2:[[:space:]]*//p" "$1" | head -1
}

# ── Select ────────────────────────────────────────────────────────────────────
patches=()
for p in "$MUT_DIR"/*.patch; do
  [[ -f "$p" ]] || continue
  id="$(basename "$p" .patch)"
  # Only a patch the image is built FROM. Everything else is correctly served by
  # the documented --reuse-image procedure and is not this script's business.
  patch_needs_rebuild "$p" || continue
  # EVERY declared case, not head -1 — same reason as demonstrate-network-tier.sh:
  # a patch may name more than one (735 and 730 both name 730-native-clients-run),
  # and reading only the first leaves the others never run while the report still
  # claims a demonstration.
  mapfile -t pcases < <(sed -n 's/^#[[:space:]]*case:[[:space:]]*//p' "$p")
  for case_name in "${pcases[@]}"; do
    cf="$CASES_DIR/$case_name.sh"
    [[ -f "$cf" ]] || continue
    # The complement of demonstrate-network-tier.sh's selection. Stated as an
    # exclusion rather than an inclusion list of mounts/groups/volumes/packages
    # so a case in a NEW tier lands here (visibly, runnable) instead of being
    # silently owned by neither script.
    tags="$(case_meta "$cf" tags)"
    case " $tags " in *" network-mode "*|*" delivery "*) continue ;; esac
    variant="$(case_meta "$cf" image)"; variant="${variant:-default}"
    [[ -n "$want_variant" && "$variant" != "$want_variant" ]] && continue
    if [[ ${#wanted[@]} -gt 0 ]]; then
      match=0
      for w in "${wanted[@]}"; do [[ "$id" == "$w"* || "$case_name" == "$w"* ]] && match=1; done
      [[ "$match" -eq 1 ]] || continue
    fi
    patches+=("$id|$case_name|$variant")
  done
done

if [[ ${#patches[@]} -eq 0 ]]; then
  printf 'demonstrate-launcher-tier.sh: no rebuild-tier mutations selected%s\n' \
    "${wanted[*]:+ (${wanted[*]})}" >&2
  exit 2
fi

printf 'Rebuild-tier mutations selected: %s\n' "${#patches[@]}"
printf 'A case that FAILs is the pass condition. PASS means the mutation is dead.\n\n'
printf '%-34s %-38s %s\n' PATCH CASE VARIANT
for entry in "${patches[@]}"; do
  IFS='|' read -r id case_name variant <<<"$entry"
  printf '%-34s %-38s %s\n' "$id" "$case_name" "$variant"
done
printf '\n'

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Dry run: nothing built, nothing applied, no docker call made.\n'
  exit 0
fi

# ── Preflight: the harness must be green on a CLEAN tree ──────────────────────
# Without this, a failure below is uninterpretable — it could be the mutation or
# it could be the machine. Cheapest possible proof: the default variant's
# selftest. --keep so the image survives for the first default-variant patch;
# the cleanup trap owns it from here.
printf '── preflight: harness selftest on a clean tree … '
pre_t0=$SECONDS
if ! bash "$RUN" --cases 000-harness-selftest --keep >/dev/null 2>&1; then
  printf 'FAILED\n'
  printf 'demonstrate-launcher-tier.sh: the harness selftest failed on a CLEAN tree.\n' >&2
  printf '  Fix that first — nothing below would be interpretable.\n' >&2
  exit 1
fi
printf 'green (%ss)\n\n' "$((SECONDS - pre_t0))"

demonstrated=0; undemonstrated=0; inconclusive=0; skipped=0; errored=0; unrun=0
results=""; t_start=$SECONDS

for entry in "${patches[@]}"; do
  IFS='|' read -r id case_name variant <<<"$entry"

  # Budget gate. Refuse to START what cannot finish: the estimate for a
  # not-yet-measured variant is deliberately pessimistic, because overrunning a
  # budget is worse than deferring a patch to the next run.
  elapsed_min=$(( (SECONDS - t_start) / 60 ))
  if [[ "$elapsed_min" -ge "$budget_min" ]]; then
    printf '── %-34s SKIPPED (budget: %s min used of %s)\n' "$id" "$elapsed_min" "$budget_min"
    results="${results}NOT-RUN      $id → $case_name — budget exhausted before it started\n"
    unrun=$((unrun + 1)); continue
  fi

  printf '── %-34s [%s] rebuilding … ' "$id" "$variant"

  if ! bash "$MUT" apply "$id" >/dev/null 2>&1; then
    printf 'ERROR (patch did not apply)\n'
    results="${results}ERROR-APPLY  $id\n"; errored=$((errored + 1)); continue
  fi

  # No --keep and no --reuse-image: run.sh builds this case's variant image WITH
  # the mutation in the tree, runs the case, and disposes of the image itself.
  t0=$SECONDS
  out="$(bash "$RUN" --cases "$case_name" 2>&1)"
  dt=$((SECONDS - t0))
  bash "$MUT" revert >/dev/null 2>&1

  if grep -qE "^${case_name}[[:space:]]+SKIP|${case_name}.*  SKIP" <<<"$out"; then
    reason="$(grep -E 'SKIP' <<<"$out" | head -1 | sed 's/^ *//')"
    printf 'SKIP  ← demonstrates nothing (%ss)\n' "$dt"
    results="${results}SKIPPED      $id → $case_name — unmet requirement, nothing demonstrated\n               ${reason}\n"
    skipped=$((skipped + 1)); continue
  fi

  if grep -qE "^${case_name}[[:space:]]+FAIL|${case_name}.*  FAIL" <<<"$out"; then
    # A FAIL verdict alone is not a demonstration — run.sh reports
    # "FAIL (exited 0 but asserted nothing)" for a case that bailed before
    # asserting. Requiring a real `FAIL:` line separates the two.
    line="$(grep -E '^ *FAIL:' <<<"$out" | head -1 | sed 's/^ *//')"
    if [[ -z "$line" ]]; then
      printf 'FAIL  ← INCONCLUSIVE, no assertion (%ss)\n' "$dt"
      results="${results}INCONCLUSIVE $id → $case_name — reported FAIL but no 'FAIL:' assertion line\n"
      inconclusive=$((inconclusive + 1))
      sed 's/^/       /' <<<"$out" | grep -E 'FAIL|SKIP|asserted nothing' | head -6
      continue
    fi
    printf 'FAIL  ← demonstrated (%ss)\n' "$dt"
    results="${results}DEMONSTRATED $id → $case_name  [${dt}s]\n               ${line}\n"
    demonstrated=$((demonstrated + 1))
  elif grep -qE "${case_name}.*  PASS" <<<"$out"; then
    printf 'PASS  ← UNDEMONSTRATED (%ss)\n' "$dt"
    results="${results}UNDEMONSTRATED $id → $case_name  [${dt}s]\n               the case still passes with its mutation applied and the image rebuilt\n"
    undemonstrated=$((undemonstrated + 1))
  else
    printf 'ERROR (case did not run) (%ss)\n' "$dt"
    results="${results}ERROR-RUN    $id → $case_name\n"
    errored=$((errored + 1))
    sed 's/^/       /' <<<"$out" | tail -12
  fi
done

printf '\n────────────────────────────────────────────────────────────\n'
printf '%b' "$results"
printf '────────────────────────────────────────────────────────────\n'
printf 'demonstrated %s   UNDEMONSTRATED %s   INCONCLUSIVE %s   skipped %s   errored %s   not-run %s\n' \
  "$demonstrated" "$undemonstrated" "$inconclusive" "$skipped" "$errored" "$unrun"
printf 'elapsed %s min of %s budgeted\n' "$(( (SECONDS - t_start) / 60 ))" "$budget_min"

git -C "$REPO_DIR" diff --quiet \
  && printf 'tree clean.\n' \
  || printf 'WARNING: tree is NOT clean — inspect before committing.\n'

[[ "$undemonstrated" -eq 0 && "$errored" -eq 0 && "$inconclusive" -eq 0 && "$unrun" -eq 0 && "$skipped" -eq 0 ]]
