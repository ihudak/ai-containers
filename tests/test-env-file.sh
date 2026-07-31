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

# The override guarantee depends on ORDER inside the docker run block:
# --env-file must appear AFTER --add-host but BEFORE the first -e sandbox var.
addhost_ln=$(grep -n -- '--add-host=host.docker.internal:host-gateway' "$REPO_DIR/sandbox.sh" | head -1 | cut -d: -f1)
envfile_ln=$(grep -nF 'env_file_args[@]' "$REPO_DIR/sandbox.sh" | head -1 | cut -d: -f1)
firstE_ln=$(grep -nE '^[[:space:]]*-e ' "$REPO_DIR/sandbox.sh" | head -1 | cut -d: -f1)
if [[ -n "$addhost_ln" && -n "$envfile_ln" && -n "$firstE_ln" \
      && "$addhost_ln" -lt "$envfile_ln" && "$envfile_ln" -lt "$firstE_ln" ]]; then
  pass "--env-file expansion sits between --add-host and the first -e sandbox var"
else
  fail "--env-file ordering (add-host=$addhost_ln env-file=$envfile_ln first-e=$firstE_ln)"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
