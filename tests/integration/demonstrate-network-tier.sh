#!/usr/bin/env bash
# Demonstrate every network/security case failing against its known-bad mutation.
#
# WHY THIS EXISTS, AND WHY IT IS NOT PART OF run-all.sh OR run.sh:
#
# tests/test-mutations.sh checks that every mutation patch still APPLIES. That
# is all it can afford to check, because running an integration case costs
# minutes and a Docker daemon. Applying is a real guard — a patch that no longer
# applies fails loudly — but it does not prove the mutation still makes its case
# FAIL. A case file can drift until its recorded mutation lands somewhere
# harmless, and "the patch applies" would stay true the whole time.
#
# This script closes that gap the only way it can be closed: by running each
# case against its mutation and requiring a FAIL. It is a HOST tool, run by a
# human on a real daemon, in the same spirit as verify-on-host.sh — not a CI
# gate, because the cost is measured in tens of minutes.
#
# A case that FAILs is the pass condition here. A case that PASSes means its
# mutation no longer damages it, and is reported as UNDEMONSTRATED — the state
# this whole tier exists to make impossible.
#
# ERROR is a third, distinct outcome and is NOT a pass: a case whose container
# never started tells us the harness broke, not that the assertion can fail.
#
# INCONCLUSIVE is the fourth, and it exists because the first run of this script
# reported a case as demonstrated on the strength of run.sh's FAIL verdict
# alone. run.sh reports "FAIL (exited 0 but asserted nothing)" for a case that
# bailed before asserting — a correct verdict, and the exact opposite of a
# demonstration. A real demonstration must produce a `FAIL:` assertion line;
# anything else is reported as INCONCLUSIVE and fails the run.
#
# Usage:
#   bash tests/integration/demonstrate-network-tier.sh            # every network patch
#   bash tests/integration/demonstrate-network-tier.sh 050 210    # only these
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR" || exit 1

MUT="$REPO_DIR/tests/integration/mutate.sh"
MUT_DIR="$REPO_DIR/tests/integration/mutations"
CASES_DIR="$REPO_DIR/tests/integration/cases"
RUN="$REPO_DIR/tests/integration/run.sh"

# ── Refuse to start on a dirty tree ───────────────────────────────────────────
# mutate.sh has its own clean-tree gate, but reaching it one mutation in would
# leave the tree mutated. Check before touching anything.
if ! git -C "$REPO_DIR" diff --quiet; then
  printf 'demonstrate-network-tier.sh: working tree has unstaged changes — commit or stash first.\n' >&2
  printf '  A mutation must be the only difference, or reverting it is a guess.\n' >&2
  exit 1
fi

# ── Always revert, however we leave ───────────────────────────────────────────
# Without this an interrupted run (Ctrl-C during a 3-minute case) leaves the
# repo mutated, and the next thing anyone runs tests damaged code.
cleanup() {
  bash "$MUT" revert >/dev/null 2>&1
  git -C "$REPO_DIR" checkout -- "$CASES_DIR" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── Select the patches to demonstrate ─────────────────────────────────────────
wanted=("$@")
patches=()
for p in "$MUT_DIR"/*.patch; do
  [[ -f "$p" ]] || continue
  id="$(basename "$p" .patch)"
  # EVERY declared case, not `head -1`. A patch may name more than one — the
  # 070/230 pair share one edit to tests/integration/lib.sh — and reading only
  # the first silently leaves the others never run while the report still says
  # "demonstrated". This is the same defect tests/test-mutations.sh carried in
  # its own validation loop; do not reintroduce it here.
  mapfile -t pcases < <(sed -n 's/^#[[:space:]]*case:[[:space:]]*//p' "$p")
  [[ ${#pcases[@]} -gt 0 ]] || continue
  for case_name in "${pcases[@]}"; do
    cf="$CASES_DIR/$case_name.sh"
    [[ -f "$cf" ]] || continue
    # network tier only — the launcher tier is a different economics and is not
    # what this script is for.
    tags="$(sed -n 's/^#[[:space:]]*tags:[[:space:]]*//p' "$cf" | head -1)"
    case " $tags " in *" network-mode "*) : ;; *) continue ;; esac
    if [[ ${#wanted[@]} -gt 0 ]]; then
      match=0
      for w in "${wanted[@]}"; do [[ "$id" == "$w"* || "$case_name" == "$w"* ]] && match=1; done
      [[ "$match" -eq 1 ]] || continue
    fi
    patches+=("$id|$case_name")
  done
done

if [[ ${#patches[@]} -eq 0 ]]; then
  printf 'demonstrate-network-tier.sh: no network-tier mutations selected%s\n' \
    "${wanted[*]:+ (${wanted[*]})}" >&2
  exit 2
fi

printf 'Demonstrating %s network-tier mutation(s).\n' "${#patches[@]}"
printf 'A case that FAILs is the pass condition. PASS means the mutation is dead.\n\n'

# ── Build the image once ──────────────────────────────────────────────────────
printf '── building the integration image (once) …\n'
if ! bash "$RUN" --cases 000-harness-selftest --keep >/dev/null 2>&1; then
  printf 'demonstrate-network-tier.sh: the harness selftest failed on a CLEAN tree.\n' >&2
  printf '  Fix that first — nothing below would be interpretable.\n' >&2
  exit 1
fi
printf '   image ready, harness selftest green on a clean tree.\n\n'

demonstrated=0; undemonstrated=0; errored=0; inconclusive=0
results=""

for entry in "${patches[@]}"; do
  id="${entry%%|*}"; case_name="${entry##*|}"
  printf '── %-34s ' "$id"

  if ! bash "$MUT" apply "$id" >/dev/null 2>&1; then
    printf 'ERROR (patch did not apply)\n'
    results="${results}ERROR-APPLY  $id\n"; errored=$((errored + 1)); continue
  fi

  out="$(bash "$RUN" --reuse-image --keep --cases "$case_name" 2>&1)"
  bash "$MUT" revert >/dev/null 2>&1

  if grep -qE "^${case_name}[[:space:]]+FAIL|${case_name}.*  FAIL" <<<"$out"; then
    # A FAIL verdict is NOT sufficient. run.sh reports
    # "FAIL (exited 0 but asserted nothing)" for a case that bailed before
    # asserting — a correct verdict, but the opposite of a demonstration: it
    # says the case did nothing, not that its assertion can be false. Requiring
    # a real `FAIL:` assertion line separates the two. run.sh prints every
    # PASS/FAIL/SKIP line first and unbounded (run.sh:1216), so a missing line
    # here is a genuine absence and never truncation.
    line="$(grep -E '^ *FAIL:' <<<"$out" | head -1 | sed 's/^ *//')"
    if [[ -z "$line" ]]; then
      printf 'FAIL  ← INCONCLUSIVE (no assertion failed)\n'
      results="${results}INCONCLUSIVE $id → $case_name — reported FAIL but no 'FAIL:' assertion line;\n"
      results="${results}               the case bailed before asserting, so nothing was demonstrated\n"
      inconclusive=$((inconclusive + 1))
      sed 's/^/       /' <<<"$out" | grep -E 'FAIL|SKIP|asserted nothing' | head -6
      continue
    fi
    printf 'FAIL  ← demonstrated\n'
    results="${results}DEMONSTRATED $id → $case_name\n               ${line}\n"
    demonstrated=$((demonstrated + 1))
  elif grep -qE "${case_name}.*  PASS" <<<"$out"; then
    printf 'PASS  ← UNDEMONSTRATED\n'
    results="${results}UNDEMONSTRATED $id — the case still passes with its mutation applied\n"
    undemonstrated=$((undemonstrated + 1))
  else
    printf 'ERROR (case did not run)\n'
    results="${results}ERROR-RUN    $id\n"
    errored=$((errored + 1))
    sed 's/^/       /' <<<"$out" | tail -12
  fi
done

printf '\n────────────────────────────────────────────────────────────\n'
printf '%b' "$results"
printf '────────────────────────────────────────────────────────────\n'
printf 'demonstrated %s   UNDEMONSTRATED %s   INCONCLUSIVE %s   errored %s\n' \
  "$demonstrated" "$undemonstrated" "$inconclusive" "$errored"

git -C "$REPO_DIR" diff --quiet \
  && printf 'tree clean.\n' \
  || printf 'WARNING: tree is NOT clean — inspect before committing.\n'

[[ "$undemonstrated" -eq 0 && "$errored" -eq 0 && "$inconclusive" -eq 0 ]]
