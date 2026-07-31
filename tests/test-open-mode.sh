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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
