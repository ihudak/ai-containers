#!/usr/bin/env bash
# tests/test-array-key-expansion.sh — no tracked script may write
# `${!array[@]+…}`. The guard does not guard; it silently empties the loop.
#
# THE RULE IS NOT STYLE. `${var[@]+word}` is the ordinary way to make an array
# expansion safe under `set -u`, and it works for VALUES. Applied to KEYS it
# does not mean what it looks like, and bash gives no warning:
#
#   declare -A m=([a]=1)
#   echo "${!m[@]+X}"      # prints NOTHING — the array has a key, yet the
#                          # alternate-value test reports it unset
#
# So `for k in ${!m[@]+"${!m[@]}"}` iterates ZERO times over a populated array.
# Nothing errors. The loop simply does not run, and every lookup through it
# quietly finds nothing — which reads as "no match" rather than as a bug.
#
# With more than one key it degrades differently and just as quietly: bash
# reparses the construct as INDIRECT expansion, taking the joined keys as a
# variable name, and reports `2 1: invalid variable name`.
#
# THE GUARD IS ALSO UNNECESSARY, which is what makes the mistake tempting rather
# than merely wrong. Key expansion is ALREADY safe on an empty array under
# `set -u`:
#
#   set -u; declare -A m=(); for k in "${!m[@]}"; do …; done   # rc=0, no error
#
# So the correct spelling is the plain one. If you also need to skip the loop
# entirely when the array is empty, test the COUNT: `(( ${#m[@]} )) || return 1`.
#
# It reached this repo for real on 2026-08-21, in the first draft of
# sandbox.sh's pointer_already_mounted_as: the helper compared a host directory
# against every mounted repo's source, found nothing because the loop never ran,
# and the collision it existed to resolve persisted. The symptom was the
# original bug appearing unfixed — the most expensive kind, because the fix
# looks wrong rather than the idiom.
#
# Everything above is reproduced below against the real bash on this machine, so
# the rule rests on measurement rather than on this comment.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# ── 1. The defect, measured ───────────────────────────────────────────────────
got="$(bash -c 'set -u; declare -A m=([a]=1); printf "%s" "${!m[@]+X}"' 2>&1)"
[[ -z "$got" ]] \
  && pass "\${!m[@]+X} expands to nothing on a POPULATED array (the guard is always false)" \
  || fail "\${!m[@]+X} expands to nothing on a populated array — got '$got'"

n="$(bash -c 'set -u; declare -A m=([a]=1); for k in ${!m[@]+"${!m[@]}"}; do printf x; done' 2>/dev/null)"
[[ -z "$n" ]] \
  && pass "the guarded loop runs ZERO times over a populated array" \
  || fail "the guarded loop runs zero times over a populated array — got '$n'"

# ── 2. The correct spelling, measured ─────────────────────────────────────────
n="$(bash -c 'set -u; declare -A m=([a]=1 [b]=2); for k in "${!m[@]}"; do printf x; done' 2>/dev/null)"
[[ "$n" == "xx" ]] \
  && pass "the plain form iterates every key" \
  || fail "the plain form iterates every key — got '$n'"

if bash -c 'set -u; declare -A m=(); for k in "${!m[@]}"; do :; done' 2>/dev/null; then
  pass "the plain form is already set -u-safe on an EMPTY array (no guard needed)"
else
  fail "the plain form is already set -u-safe on an empty array"
fi

# ── 3. The rule ───────────────────────────────────────────────────────────────
# This file quotes the broken form in its own prose and in its own measurements,
# so it must exclude itself — a linter that trips on its own description of the
# defect teaches nobody anything. tests/test-docs.sh learned the same lesson the
# other way round, by SATISFYING its own check.
self="tests/$(basename "${BASH_SOURCE[0]}")"
found=0
while IFS= read -r f; do
  [[ "$f" == "$self" ]] && continue
  if grep -nE '\$\{![A-Za-z_][A-Za-z0-9_]*\[@\]\+' "$REPO_DIR/$f" >/dev/null 2>&1; then
    fail "$f uses \${!array[@]+…}, which silently empties the loop — write \"\${!array[@]}\""
    grep -nE '\$\{![A-Za-z_][A-Za-z0-9_]*\[@\]\+' "$REPO_DIR/$f" | sed 's/^/     /'
    found=$((found+1))
  fi
done < <(cd "$REPO_DIR" && git ls-files '*.sh')
(( found == 0 )) && pass "no tracked script uses \${!array[@]+…}"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
