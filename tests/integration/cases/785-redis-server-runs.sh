#!/usr/bin/env bash
# summary:  redis=ON starts a loopback-only, non-persisting server owned by the agent, started by the entrypoint
# tags:     packages slow
# requires: docker launcher netadmin
# image:    services
# timeout:  900
#
# WHAT IS PROVEN, against the real image the `services` variant builds with
# redis=ON, in RESTRICTED mode:
#   1. a bare `redis-cli ping` answers PONG as the agent — so the entrypoint
#      started the server before handing over (nothing else starts it), on the
#      port clients default to, and the firewall did not get in the way
#      (loopback is allowed). The project's container.env sets an app's own
#      REDIS_PORT=7777, which reaches the adapter's `start` and must not move the
#      server; and it answers over ::1 too, where the container has an IPv6
#      loopback, because Node 17 and later resolve `localhost` to ::1 first;
#   2. every redis-server process runs as the sandbox UID, not root and not the
#      package's `redis` user;
#   3. it listens on loopback addresses only;
#   4. nothing is persisted: no snapshot schedule (`save` empty) and no
#      append-only file;
#   5. the agent can SET and GET;
#   6. the entrypoint printed the ready line.
#
# The hermetic halves — validation, the build arg, the runner, the adapter's
# command line and readiness — are tests/test-redis.sh and
# tests/test-start-services.sh. Neither can show a server starting in a real
# image; this case is the only place that is.
#
# Mutations 785, 786, 787 and 788 demonstrate this case failing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
scratch="$(it_scratch)"
printf 'REDIS_PORT=7777\nREDIS_URL=redis://localhost:6379/0\n' > "$scratch/container.env"
export SANDBOX_ENV_FILE="$scratch/container.env"
launcher_up restricted || it_finish

# Every command runs AS THE AGENT (agent_exec), never as root: the claim is that
# the agent's own shell can use the server with no setup at all.
rc() { agent_exec "$IT_CID" "redis-cli $1" 2>&1; }

# ── 1. The server answers, where clients look ──────────────────────────────────
if [[ "$(rc ping)" == "PONG" ]]; then
  pass "a bare redis-cli ping answers PONG on 127.0.0.1:6379, as the agent — an app's REDIS_PORT=7777 did not move it"
else
  fail "a bare redis-cli ping did not answer — no server, or not on 6379"
  docker exec "$IT_CID" tail -n 30 /var/log/ai-services/redis.log 2>&1 | sed 's/^/     /'
  docker logs "$IT_CID" 2>&1 | grep -iE 'redis|services' | tail -n 10 | sed 's/^/     /'
  it_finish
fi
if docker exec "$IT_CID" grep -qE '^0{31}1 .* lo$' /proc/net/if_inet6 2>/dev/null; then
  [[ "$(rc '-h ::1 ping')" == "PONG" ]] \
    && pass "it answers over ::1 as well, where Node 17+ looks for localhost first" \
    || fail "no answer over ::1, though the container has an IPv6 loopback"
else
  pass "no IPv6 loopback in this container — the ::1 bind is optional, and the server still started"
fi

# ── 2. Owned by the agent ──────────────────────────────────────────────────────
# From /proc rather than ps: procps is not guaranteed in every variant.
uids="$(docker exec "$IT_CID" bash -c 'for p in /proc/[0-9]*; do
          [ "$(cat "$p/comm" 2>/dev/null)" = redis-server ] && awk "/^Uid:/{print \$2}" "$p/status"
        done | sort -u' 2>/dev/null)"
if [[ -z "$uids" ]]; then
  fail "no redis-server process found in /proc — assertion 2 verified nothing"
elif [[ "$uids" == "$IT_LAUNCH_UID" ]]; then
  pass "every redis-server process runs as the sandbox UID ($IT_LAUNCH_UID)"
else
  fail "redis-server runs as UID(s) $(tr '\n' ' ' <<<"$uids")— expected only $IT_LAUNCH_UID"
fi

# ── 3. Loopback only ───────────────────────────────────────────────────────────
# /proc/net/tcp{,6}: state 0A is LISTEN; port 6379 is 18EB in hex. 0100007F is
# 127.0.0.1 and the 32-digit form is ::1. Anything else is exposure.
listeners="$(docker exec "$IT_CID" awk 'FNR>1 && $4=="0A" && $2 ~ /:18EB$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if [[ -z "$listeners" ]]; then
  fail "no listener on port 6379 in /proc/net — assertion 3 verified nothing"
elif exposed="$(grep -vE '^(0100007F|00000000000000000000000001000000):18EB$' <<<"$listeners")"; then
  fail "redis listens beyond loopback: $(tr '\n' ' ' <<<"$exposed")"
else
  pass "port 6379 is bound to loopback only ($(tr '\n' ' ' <<<"$listeners"))"
fi

# ── 4. Nothing persisted ───────────────────────────────────────────────────────
save="$(rc 'config get save' | sed -n '2p')"
aof="$(rc 'config get appendonly' | sed -n '2p')"
[[ -z "$save" && "$aof" == "no" ]] \
  && pass "no snapshot schedule and no append-only file: nothing is written to disk" \
  || fail "persistence is on: save='$save' appendonly='$aof'"

# ── 5. The agent uses it ───────────────────────────────────────────────────────
[[ "$(rc 'set it:key it-value')" == "OK" && "$(rc 'get it:key')" == "it-value" ]] \
  && pass "the agent can SET and GET" \
  || fail "SET/GET as the agent failed: $(rc 'get it:key')"

# ── 6. The ready line reached the terminal ─────────────────────────────────────
assert_log_contains "$IT_CID" 'redis [0-9]+\.[0-9]+(\.[0-9]+)? ready on redis://localhost:6379'

it_finish
