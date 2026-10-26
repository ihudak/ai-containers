#!/usr/bin/env bash
# tests/test-run-all-root-identity.sh — run-all.sh gives the agent a non-root
# identity when the suite runs as root (TST-9).
#
# sandbox.sh refuses an agent UID or GID of 0 and takes both from `id` by
# default, so before this every launching test failed in the root floor
# container. run-all.sh now exports SANDBOX_UID/SANDBOX_GID=1000 there, unless
# the run set them.
#
# METHOD: a COPY of run-all.sh in a scratch tests/ directory beside one probe
# test that prints the identity it was given, with a fake `id` first on PATH.
# A copy, because run-all.sh runs every test-*.sh beside it: run in place it
# would run this file again. It is copied at run time, so it cannot drift.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

mkdir -p "$TMP/tests" "$TMP/bin" \
  && cp "$REPO_DIR/tests/run-all.sh" "$TMP/tests/" \
  || { printf 'SCAFFOLD-FAILED: could not copy run-all.sh\n'; exit 1; }
cat > "$TMP/tests/test-probe.sh" <<'EOF'
printf 'PASS: probe\n'
printf 'IDENT=%s:%s\n' "${SANDBOX_UID-unset}" "${SANDBOX_GID-unset}"
EOF

# probe <fake id -u> <fake id -g> [env assignments…] → the IDENT line it saw
probe() {
  local u="$1" g="$2"; shift 2
  printf '#!/bin/sh\ncase "$1" in -u) echo %s ;; -g) echo %s ;; *) exec /usr/bin/env -i id "$@" ;; esac\n' \
    "$u" "$g" > "$TMP/bin/id"
  chmod +x "$TMP/bin/id"
  env -u SANDBOX_UID -u SANDBOX_GID "$@" PATH="$TMP/bin:$PATH" bash "$TMP/tests/run-all.sh" -v 2>&1 \
    | sed -n 's/^IDENT=//p'
}

got="$(probe 0 0)"
[[ "$got" == "1000:1000" ]] && pass "as root, the agent gets 1000:1000" \
  || fail "as root, the agent gets 1000:1000 (got '$got')"
got="$(probe 1000 0)"
[[ "$got" == "1000:1000" ]] && pass "with GID 0 alone, the agent still gets a non-root identity" \
  || fail "with GID 0 alone, the agent still gets a non-root identity (got '$got')"
got="$(probe 0 0 SANDBOX_UID=4242 SANDBOX_GID=4343)"
[[ "$got" == "4242:4343" ]] && pass "as root, an identity the run names is kept" \
  || fail "as root, an identity the run names is kept (got '$got')"
got="$(probe 1001 1001)"
[[ "$got" == "unset:unset" ]] && pass "as a user, nothing is exported (sandbox.sh takes id's own)" \
  || fail "as a user, nothing is exported (got '$got')"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
