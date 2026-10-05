#!/usr/bin/env bash
# Unit tests for the `postgres` sandbox.conf key and its adapter.
#
# The key buys a PostgreSQL SERVER inside the container: a build-time layer (the
# PGDG packages), a run-time env var (AI_SERVICES, read by start-services.sh) and
# an adapter (services.d/postgres.sh) that initialises, starts and provisions a
# throwaway cluster as the sandbox user.
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring and logic
# assertions, the adapter driven against fake binaries. That the layer BUILDS
# and a real server answers in a real container is integration case
# 780-postgres-server-runs (packages tier, `native` variant), demonstrated
# failing by mutations 780-782. The runner's own contract is
# tests/test-start-services.sh.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
TMP_ROOT="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP_ROOT"' EXIT

# ── Part A: sandbox.conf value → POSTGRES_VERSION build arg ────────────────────
# ON cannot pass through as the literal "ON" — the layer would look for a package
# named postgresql-ON — so it becomes `latest`, which the layer resolves through
# PGDG's own `postgresql` metapackage. A pinned major passes verbatim. OFF and
# empty emit NO arg at all (not an empty one): the Dockerfile's ARG defaults to
# empty, and a project that never enables the key keeps the config digest it had.

pg_build_args() {  # $1 = sandbox.conf body → every docker build arg, one per line
  local d
  d="$(mktemp -d "$TMP_ROOT/ba.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n' >&2; return 1; }
  printf '# schema-version: 4\n%s\n' "$1" > "$d/sandbox.conf"
  ( export SANDBOX_CONF="$d/sandbox.conf"
    # shellcheck source=/dev/null
    source "$REPO_DIR/build.sh"
    declare -a args=()
    build_args_from_config args
    printf '%s\n' "${args[@]}" )
}

out="$(pg_build_args 'postgres=ON')"
grep -qx 'POSTGRES_VERSION=latest' <<<"$out" \
  && pass "postgres=ON → POSTGRES_VERSION=latest" \
  || fail "postgres=ON → POSTGRES_VERSION=latest"

out="$(pg_build_args 'postgres=17')"
grep -qx 'POSTGRES_VERSION=17' <<<"$out" \
  && pass "postgres=17 → POSTGRES_VERSION=17 (pinned major, verbatim)" \
  || fail "postgres=17 → POSTGRES_VERSION=17"

for off in 'postgres=OFF' 'postgres=' 'copilot=ON'; do
  out="$(pg_build_args "$off")"
  if [[ -z "$out" ]]; then
    fail "'$off': build_args_from_config produced nothing at all — this assertion verified nothing"
  elif grep -q '^POSTGRES_VERSION=' <<<"$out"; then
    fail "'$off' → no POSTGRES_VERSION build arg (got: $(grep '^POSTGRES_VERSION=' <<<"$out"))"
  else
    pass "'$off' → no POSTGRES_VERSION build arg (never an empty or literal-OFF one)"
  fi
done

# ── Part B: validate_config — one value, capitals, a major ─────────────────────
VC_TMP="$(mktemp -d "$TMP_ROOT/vc.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n'; exit 1; }
vc() {  # $1 = postgres value → sets VC_RC and VC_OUT
  printf '# schema-version: 4\npostgres=%s\n' "$1" > "$VC_TMP/sandbox.conf"
  VC_OUT="$(SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" 2>&1)"
  VC_RC=$?
}

for good in ON OFF '' 10 17 18; do
  vc "$good"
  [[ "$VC_RC" -eq 0 ]] \
    && pass "validate_config accepts postgres=$good" \
    || fail "validate_config accepts postgres=$good (rc=$VC_RC, out='$VC_OUT')"
done

# Each refusal must NAME the key: an error that does not say "postgres" sends the
# reader looking everywhere but here.
for bad in '16,17' on Off oN latest 17beta1 abc; do
  vc "$bad"
  if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *postgres* ]]; then
    pass "validate_config refuses postgres=$bad, by name"
  else
    fail "validate_config refuses postgres=$bad, by name (rc=$VC_RC, out='$VC_OUT')"
  fi
done

# A minor is refused AND the message hands back the major to pin instead.
vc '17.2'
if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *"postgres=17"* ]]; then
  pass "validate_config refuses postgres=17.2 and suggests postgres=17"
else
  fail "validate_config refuses postgres=17.2 and suggests postgres=17 (rc=$VC_RC, out='$VC_OUT')"
fi

# ── Part F: the shipped default ────────────────────────────────────────────────
# New keys reach every project through sync's append, so the upstream default is
# what every project gets until someone opts in. Off, because it costs ~180 MB.
grep -qx 'postgres=OFF' "$REPO_DIR/sandbox.conf" \
  && pass "sandbox.conf ships postgres=OFF" \
  || fail "sandbox.conf ships postgres=OFF"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
