#!/usr/bin/env bash
# Structural + syntax tests for the project env-file injection in sandbox.sh.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/sandbox.sh" && pass "sandbox.sh passes bash -n" || fail "sandbox.sh bash -n"

grep -q 'SANDBOX_ENV_FILE' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh honours SANDBOX_ENV_FILE" || fail "sandbox.sh honours SANDBOX_ENV_FILE"
grep -q 'container.env' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh auto-detects container.env" || fail "sandbox.sh auto-detects container.env"
grep -q -- '--env-file' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh passes --env-file to docker run" || fail "sandbox.sh passes --env-file"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
