#!/usr/bin/env bash
# summary:  mongo=ON starts a loopback-only MongoDB owned by the agent, its cache capped, started by the entrypoint
# tags:     packages slow
# requires: docker launcher netadmin
# image:    services
# timeout:  900
#
# WHAT IS PROVEN, against the real image the `services` variant builds with
# mongo=ON, in RESTRICTED mode:
#   1. a bare `mongosh` reaches the server as the agent — so the entrypoint
#      started it before handing over, on the port clients default to, though
#      container.env sets an app's own MONGO_PORT=7777, which reaches the
#      adapter's `start` and must not move it; and over ::1 too, where the
#      container has an IPv6 loopback;
#   2. every mongod process runs as the sandbox UID, not root and not the
#      package's `mongodb` user;
#   3. it listens on loopback addresses only;
#   4. the WiredTiger cache is capped at 0.25 GB — its default would take half of
#      (memory − 1 GB), 1.5 GB of a 4 GB container;
#   5. the agent writes and reads a document, in a database nothing created
#      first;
#   6. the entrypoint printed the ready line.
#
# The hermetic halves are tests/test-mongo.sh and tests/test-start-services.sh;
# neither can show the server starting in a real image.
#
# Mutations 800-803 demonstrate this case failing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
scratch="$(it_scratch)"
printf 'MONGO_PORT=7777\nMONGODB_URI=mongodb://localhost:27017/app_test\n' > "$scratch/container.env"
export SANDBOX_ENV_FILE="$scratch/container.env"
launcher_up restricted || it_finish

# Every command runs AS THE AGENT (agent_exec), never as root.
sh_() { agent_exec "$IT_CID" "mongosh --quiet $1" 2>&1; }

# ── 1. The server answers, where clients look ──────────────────────────────────
if [[ "$(sh_ "--eval 'db.runCommand({ping: 1}).ok'")" == "1" ]]; then
  pass "a bare mongosh reaches mongodb://localhost:27017, as the agent — an app's MONGO_PORT=7777 did not move it"
else
  fail "a bare mongosh did not reach the server — no server, or not on 27017"
  docker exec "$IT_CID" tail -n 20 /var/log/ai-services/mongo.log 2>&1 | cut -c1-300 | sed 's/^/     /'
  docker logs "$IT_CID" 2>&1 | grep -iE 'mongo|services' | tail -n 10 | sed 's/^/     /'
  it_finish
fi
if docker exec "$IT_CID" grep -qE '^0{31}1 .* lo$' /proc/net/if_inet6 2>/dev/null; then
  [[ "$(sh_ "'mongodb://[::1]:27017' --eval 'db.runCommand({ping: 1}).ok'")" == "1" ]] \
    && pass "it answers over ::1 as well, where Node 17+ looks for localhost first" \
    || fail "no answer over ::1, though the container has an IPv6 loopback"
else
  pass "no IPv6 loopback in this container — ::1 is not bound, and the server still started"
fi

# ── 2. Owned by the agent ──────────────────────────────────────────────────────
uids="$(docker exec "$IT_CID" bash -c 'for p in /proc/[0-9]*; do
          [ "$(cat "$p/comm" 2>/dev/null)" = mongod ] && awk "/^Uid:/{print \$2}" "$p/status"
        done | sort -u' 2>/dev/null)"
if [[ -z "$uids" ]]; then
  fail "no mongod process found in /proc — assertion 2 verified nothing"
elif [[ "$uids" == "$IT_LAUNCH_UID" ]]; then
  pass "every mongod process runs as the sandbox UID ($IT_LAUNCH_UID)"
else
  fail "mongod runs as UID(s) $(tr '\n' ' ' <<<"$uids")— expected only $IT_LAUNCH_UID"
fi

# ── 3. Loopback only ───────────────────────────────────────────────────────────
# /proc/net/tcp{,6}: state 0A is LISTEN; 27017 is 6989 in hex.
listeners="$(docker exec "$IT_CID" awk 'FNR>1 && $4=="0A" && $2 ~ /:6989$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if [[ -z "$listeners" ]]; then
  fail "no listener on port 27017 in /proc/net — assertion 3 verified nothing"
elif exposed="$(grep -vE '^(0100007F|00000000000000000000000001000000):6989$' <<<"$listeners")"; then
  fail "mongod listens beyond loopback: $(tr '\n' ' ' <<<"$exposed")"
else
  pass "port 27017 is bound to loopback only ($(tr '\n' ' ' <<<"$listeners"))"
fi

# ── 4. The cache cap ───────────────────────────────────────────────────────────
cache="$(sh_ "--eval 'db.serverStatus().wiredTiger.cache[\"maximum bytes configured\"]'")"
[[ "$cache" == "268435456" ]] \
  && pass "the WiredTiger cache is capped at 0.25 GB ($cache bytes)" \
  || fail "the WiredTiger cache is $cache bytes, not 268435456 (0.25 GB)"

# ── 5. The agent uses it ───────────────────────────────────────────────────────
out="$(sh_ "mongodb://localhost:27017/app_test --eval 'db.it.insertOne({k: \"v\"}); db.it.findOne().k'")"
[[ "$out" == "v" ]] && pass "the agent writes and reads a document in app_test, which nothing created first" \
  || fail "insert/find as the agent: $out"

# ── 6. The ready line reached the terminal ─────────────────────────────────────
assert_log_contains "$IT_CID" 'mongo [0-9]+\.[0-9]+\.[0-9]+ ready on mongodb://localhost:27017'

it_finish
