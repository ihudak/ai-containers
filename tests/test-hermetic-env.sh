#!/usr/bin/env bash
# A hermetic test that launches sandbox.sh must not inherit the developer's own
# VAULT_PATH, SPECS_PATH, DOCS_PATH, ARCHITECTURE_REPO_PATH, EXTRA_MOUNTS or
# REPOS: the launch mounts those real directories writable, and WRITES into the
# git repositories it protects there (sandbox.sh: launcher_ro_overlay(), the
# commondir placeholder). On 2026-10-06 a suite run did exactly that to a real
# vault, through a test that never unset them.
#
# Two layers, both checked: tests/run-all.sh unsets them for every test it runs,
# and every test that runs sandbox.sh unsets them itself, for a run on its own.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

need=(VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS)
# scrubs <file>: one `unset` line names every variable in $need.
scrubs() {
  local v line
  while IFS= read -r line; do
    for v in "${need[@]}"; do
      [[ " $line " == *[[:space:]]"$v"[[:space:]]* ]] || continue 2
    done
    return 0
  done < <(grep -E '^[[:space:]]*unset[[:space:]]' "$1")
  return 1
}

scrubs "$REPO_DIR/tests/run-all.sh" \
  && pass "run-all.sh unsets the developer's pointers for every test" \
  || fail "run-all.sh unsets ${need[*]} before running tests"

# A test that EXECUTES sandbox.sh (not one that only reads its text).
n=0; bad=""
for f in "$REPO_DIR"/tests/test-*.sh; do
  [[ "$f" == "${BASH_SOURCE[0]}" || "${f##*/}" == test-hermetic-env.sh ]] && continue
  if grep -qE '^[^#]*(bash|exec)[^#|]*sandbox\.sh["]?[[:space:]]+("?\$[0-9{]|restricted|open|discovery|--version|version|-V)|^[^#]*\./sandbox\.sh[[:space:]]+(restricted|open|discovery|"?\$)' "$f"; then
    n=$((n + 1))
    scrubs "$f" || bad+=" ${f##*/}"
  fi
done
if (( n == 0 )); then
  fail "found no test that runs sandbox.sh — the detection is broken, and this check verified nothing"
elif [[ -n "$bad" ]]; then
  fail "these tests run sandbox.sh without unsetting ${need[*]}:$bad"
else
  pass "all $n tests that run sandbox.sh unset the developer's pointers"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
