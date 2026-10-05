#!/usr/bin/env bash
# summary:  postgres=ON starts a loopback-only server owned by the agent, started by the entrypoint
# tags:     packages slow needs-external
# requires: docker launcher netadmin
# image:    native
# timeout:  3900
#
# WHAT IS PROVEN, against the real image the `native` variant builds with
# postgres=ON, in RESTRICTED mode:
#   1. a server answers over the default socket AND over 127.0.0.1 — so the
#      entrypoint started it before handing over (nothing else starts it), and the firewall did not get
#      in the way (loopback is allowed; no allowlist entry exists for it). The
#      socket query is a bare `psql`, so it also proves the superuser's own
#      database exists — libpq's default database name is the user name;
#   2. every postgres process runs as the sandbox UID, not as PGDG's `postgres`
#      system user (PostgreSQL refuses root by itself, so "not root" cannot fail;
#      the real alternative is the package's own user, which owns
#      /var/run/postgresql at build time);
#   3. it listens on loopback addresses only;
#   4. POSTGRES_ROLES / POSTGRES_DATABASES from the project's container.env were
#      provisioned: app_user is a superuser and owns myapp_test;
#   5. app_user connects over TCP with a password the server never checks, and
#      can create a contrib extension (pgcrypto) and a database;
#   6. the cluster's collation is en_US.UTF-8, the official postgres image's
#      default, so ORDER BY behaves as it does in CI;
#   7. the entrypoint printed the ready line.
#
# The hermetic halves — validation, the build arg, the runner, the adapter's
# SQL — are tests/test-postgres.sh and tests/test-start-services.sh. Neither can
# show a server starting in a real image; this case is the only place that is.
#
# needs-external is a TAG, not a requirement of the assertions: they touch no
# network (the server is local, loopback needs no allowlist). The tag marks the
# container START, which on the native variant runs the rvm reconcile and, on a
# cold group, reaches get.rvm.io and Ruby sources — the same reason 730 and 770
# carry it. netadmin IS required — launcher_up drives restricted mode.
#
# GROUP: $IT_RUBY_GROUP, shared with 730–770 for the reason 770's header gives —
# the native variant runs the rvm reconcile at every container start, and a cold
# one compiles Ruby; IT_SETTLE covers it.
#
# Mutations 780, 781 and 782 demonstrate this case failing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=3600

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"
scratch="$(it_scratch)"
printf 'POSTGRES_ROLES=app_user\nPOSTGRES_DATABASES=myapp_test:app_user\n' > "$scratch/container.env"
export SANDBOX_ENV_FILE="$scratch/container.env"
launcher_up restricted || it_finish

# Every query runs AS THE AGENT (agent_exec), never as root: the claim is that
# the agent's own shell can use the server with no setup at all.
q() { agent_exec "$IT_CID" "psql -X -At -q -v ON_ERROR_STOP=1 $1" 2>&1; }

# ── 1. The server answers, over the socket and over TCP ─────────────────────────
# The socket query is a BARE psql — no -h, no -d, no -U — because that is the
# promise: libpq defaults the database name to the user name, so it connects
# only if the server is on the default socket AND svc_start created the
# superuser's own database. The TCP query names -d postgres: it is about the
# listener, not about that database.
if [[ "$(q "-c 'select 1'")" == "1" ]]; then
  pass "a bare psql (no -h, no -d) answers over the default socket, as the agent"
else
  fail "a bare psql did not answer — no server, not where libpq looks, or no database named after the user"
  docker exec "$IT_CID" tail -n 30 /var/log/ai-services/postgres.log 2>&1 | sed 's/^/     /'
  docker logs "$IT_CID" 2>&1 | grep -iE 'postgres|services' | tail -n 10 | sed 's/^/     /'
  it_finish
fi
[[ "$(q "-h 127.0.0.1 -d postgres -c 'select 1'")" == "1" ]] \
  && pass "psql over 127.0.0.1:5432 answers in restricted mode (loopback needs no allowlist entry)" \
  || fail "psql over 127.0.0.1:5432 did not answer in restricted mode"

# ── 2. Owned by the agent, not by PGDG's postgres user ──────────────────────────────────────────
# From /proc rather than ps: procps is not guaranteed in every variant.
uids="$(docker exec "$IT_CID" bash -c 'for p in /proc/[0-9]*; do
          [ "$(cat "$p/comm" 2>/dev/null)" = postgres ] && awk "/^Uid:/{print \$2}" "$p/status"
        done | sort -u' 2>/dev/null)"
if [[ -z "$uids" ]]; then
  fail "no postgres process found in /proc — assertion 2 verified nothing"
elif [[ "$uids" == "$IT_LAUNCH_UID" ]]; then
  pass "every postgres process runs as the sandbox UID ($IT_LAUNCH_UID), not PGDG's postgres user"
else
  fail "postgres runs as UID(s) $(tr '\n' ' ' <<<"$uids")— expected only $IT_LAUNCH_UID"
fi

# ── 3. Loopback only ───────────────────────────────────────────────────────────
# /proc/net/tcp{,6}: state 0A is LISTEN; port 5432 is 1538 in hex. 0100007F is
# 127.0.0.1 and the 32-digit form is ::1. Anything else is exposure.
listeners="$(docker exec "$IT_CID" awk 'FNR>1 && $4=="0A" && $2 ~ /:1538$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if [[ -z "$listeners" ]]; then
  fail "no listener on port 5432 in /proc/net — assertion 3 verified nothing"
elif exposed="$(grep -vE '^(0100007F|00000000000000000000000001000000):1538$' <<<"$listeners")"; then
  fail "postgres listens beyond loopback: $(tr '\n' ' ' <<<"$exposed")"
else
  pass "port 5432 is bound to loopback only ($(tr '\n' ' ' <<<"$listeners"))"
fi

# ── 4. Provisioning from container.env ─────────────────────────────────────────
[[ "$(q "-d postgres -c \"select rolsuper from pg_roles where rolname='app_user'\"")" == "t" ]] \
  && pass "POSTGRES_ROLES: app_user exists as a superuser" \
  || fail "POSTGRES_ROLES: app_user is missing or not a superuser"
[[ "$(q "-d postgres -c \"select pg_get_userbyid(datdba) from pg_database where datname='myapp_test'\"")" == "app_user" ]] \
  && pass "POSTGRES_DATABASES: myapp_test exists, owned by app_user" \
  || fail "POSTGRES_DATABASES: myapp_test is missing or not owned by app_user"

# ── 5. The app role over TCP, with a password nobody checks ────────────────────
out="$(agent_exec "$IT_CID" "PGPASSWORD=not-checked psql -X -At -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U app_user -d myapp_test \
        -c 'create extension pgcrypto' -c 'create database it_scratch_db' -c 'select 1'" 2>&1)"
[[ "$(tail -n 1 <<<"$out")" == "1" ]] \
  && pass "app_user (any password) creates a contrib extension and a database over TCP" \
  || fail "app_user over TCP: $out"

# ── 6. Collation matches the official postgres image ───────────────────────────
coll="$(q "-d postgres -c \"select datcollate from pg_database where datname='postgres'\"")"
[[ "$coll" == "en_US.UTF-8" ]] \
  && pass "the cluster's collation is en_US.UTF-8" \
  || fail "the cluster's collation is '$coll', not en_US.UTF-8"

# ── 7. The ready line reached the terminal ─────────────────────────────────────
assert_log_contains "$IT_CID" 'postgres [0-9]+\.[0-9]+ ready on localhost:5432'

it_finish
