#!/usr/bin/env bash
# Structural + syntax tests for the `open` network mode.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/entrypoint.sh" && pass "entrypoint.sh bash -n" || fail "entrypoint.sh bash -n"
bash -n "$REPO_DIR/sandbox.sh"    && pass "sandbox.sh bash -n"    || fail "sandbox.sh bash -n"

grep -qE '^[[:space:]]*open\)' "$REPO_DIR/entrypoint.sh" \
  && pass "entrypoint.sh has an open) case" || fail "entrypoint.sh has an open) case"
grep -q 'restricted|discovery|open' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh command case accepts open" || fail "sandbox.sh command case accepts open"

# Regression guard: capabilities can be empty (open mode), so its docker-run
# expansion MUST use the ${arr[@]+...} guard, else `set -u` on bash <4.4 crashes
# open mode with "unbound variable".
if grep -qF '${capabilities[@]+"${capabilities[@]}"}' "$REPO_DIR/sandbox.sh"; then
  pass "capabilities uses the guarded empty-array expansion"
else
  fail "capabilities uses the guarded empty-array expansion (bare expansion crashes open mode under set -u on bash 4.3)"
fi
# Prove the guard actually protects an empty array under set -u.
if bash -uc 'capabilities=(); printf "%s" "${capabilities[@]+"${capabilities[@]}"}"' >/dev/null 2>&1; then
  pass "guarded empty-array expansion is safe under set -u"
else
  fail "guarded empty-array expansion is safe under set -u"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
