#!/usr/bin/env bash
# summary:  mysql=ON starts a loopback-only server owned by the agent, from the build-time template, provisioned from container.env
# tags:     packages slow
# requires: docker launcher netadmin
# image:    services
# timeout:  900
#
# WHAT IS PROVEN, against the real image the `services` variant builds with
# mysql=ON, in RESTRICTED mode:
#   1. a bare `mysql` connects as the agent, over the default socket, to its own
#      account — so the entrypoint started the server before handing over, and
#      the account the client logs in as by default exists;
#   2. root connects over 127.0.0.1:3306 with no password — what an app
#      configured as Rails' default does — though container.env sets an app's
#      own MYSQL_PORT=7777, which reaches the adapter's `start` and must not move
#      the server; and over ::1 too, where the container has an IPv6 loopback;
#   3. every mysqld process runs as the sandbox UID, not root and not the
#      package's `mysql` user;
#   4. it listens on loopback addresses only, and there is NO X Protocol
#      listener (33060) at all — it would bind every address;
#   5. MYSQL_USERS / MYSQL_DATABASES from container.env were provisioned:
#      app_user (no password) creates a table in myapp_test over TCP, and
#      reporting connects with the password it was given;
#   6. the template carries the time zone tables (a named zone converts), and
#      the binary log is off;
#   7. the entrypoint printed the ready line, naming what it provisioned.
#
# The hermetic halves are tests/test-mysql.sh and tests/test-start-services.sh;
# neither can show the template starting in a real image.
#
# Mutations 790-795 demonstrate this case failing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
scratch="$(it_scratch)"
printf 'MYSQL_PORT=7777\nMYSQL_USERS=app_user,reporting:s3cret\nMYSQL_DATABASES=myapp_test\n' > "$scratch/container.env"
export SANDBOX_ENV_FILE="$scratch/container.env"
launcher_up restricted || it_finish
me="${SANDBOX_USER:-$(id -un)}"

# Every query runs AS THE AGENT (agent_exec), never as root: the claim is that
# the agent's own shell can use the server with no setup at all.
q() { agent_exec "$IT_CID" "mysql -N -B $1" 2>&1 | grep -v '^mysql: \[Warning\]'; }

# ── 1. A bare client connects, as the agent's own account ──────────────────────
if [[ "$(q "-e 'select current_user()'")" == "$me@localhost" ]]; then
  pass "a bare mysql connects over the default socket as $me@localhost, as the agent"
else
  fail "a bare mysql did not connect as $me@localhost — no server, not on the default socket, or no account"
  docker exec "$IT_CID" tail -n 30 /var/log/ai-services/mysql.log 2>&1 | sed 's/^/     /'
  docker logs "$IT_CID" 2>&1 | grep -iE 'mysql|services' | tail -n 10 | sed 's/^/     /'
  it_finish
fi

# ── 2. root over TCP, no password; the app's MYSQL_PORT did not move it ────────
[[ "$(q "-h 127.0.0.1 -P 3306 -uroot -e 'select 1'")" == "1" ]] \
  && pass "root connects over 127.0.0.1:3306 with no password — an app's MYSQL_PORT=7777 did not move the server" \
  || fail "root over 127.0.0.1:3306 with no password: $(q "-h 127.0.0.1 -P 3306 -uroot -e 'select 1'")"
if docker exec "$IT_CID" grep -qE '^0{31}1 .* lo$' /proc/net/if_inet6 2>/dev/null; then
  [[ "$(q "-h ::1 -P 3306 -uroot -e 'select 1'")" == "1" ]] \
    && pass "it answers over ::1 as well, where Node 17+ looks for localhost first" \
    || fail "no answer over ::1, though the container has an IPv6 loopback"
else
  pass "no IPv6 loopback in this container — ::1 is not bound, and the server still started"
fi

# ── 3. Owned by the agent ──────────────────────────────────────────────────────
uids="$(docker exec "$IT_CID" bash -c 'for p in /proc/[0-9]*; do
          [ "$(cat "$p/comm" 2>/dev/null)" = mysqld ] && awk "/^Uid:/{print \$2}" "$p/status"
        done | sort -u' 2>/dev/null)"
if [[ -z "$uids" ]]; then
  fail "no mysqld process found in /proc — assertion 3 verified nothing"
elif [[ "$uids" == "$IT_LAUNCH_UID" ]]; then
  pass "every mysqld process runs as the sandbox UID ($IT_LAUNCH_UID)"
else
  fail "mysqld runs as UID(s) $(tr '\n' ' ' <<<"$uids")— expected only $IT_LAUNCH_UID"
fi

# ── 4. Loopback only, and no X Protocol listener ───────────────────────────────
# /proc/net/tcp{,6}: state 0A is LISTEN; 3306 is 0CEA in hex, 33060 is 8124.
listeners="$(docker exec "$IT_CID" awk 'FNR>1 && $4=="0A" && $2 ~ /:0CEA$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if [[ -z "$listeners" ]]; then
  fail "no listener on port 3306 in /proc/net — assertion 4 verified nothing"
elif exposed="$(grep -vE '^(0100007F|00000000000000000000000001000000):0CEA$' <<<"$listeners")"; then
  fail "mysql listens beyond loopback: $(tr '\n' ' ' <<<"$exposed")"
else
  pass "port 3306 is bound to loopback only ($(tr '\n' ' ' <<<"$listeners"))"
fi
x="$(docker exec "$IT_CID" awk 'FNR>1 && $4=="0A" && $2 ~ /:8124$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
[[ -z "$x" ]] && pass "no X Protocol listener on 33060" || fail "an X Protocol listener is up: $(tr '\n' ' ' <<<"$x")"

# ── 5. Provisioning from container.env ─────────────────────────────────────────
out="$(q "-h 127.0.0.1 -uapp_user myapp_test -e 'create table it_t (id int primary key); insert into it_t values (1); select count(*) from it_t'")"
[[ "$out" == "1" ]] && pass "MYSQL_USERS/MYSQL_DATABASES: app_user (no password) creates a table in myapp_test over TCP" \
  || fail "app_user in myapp_test over TCP: $out"
[[ "$(q "-h 127.0.0.1 -ureporting -ps3cret -e 'select current_user()'")" == "reporting@localhost" ]] \
  && pass "MYSQL_USERS: reporting connects with the password it was given" \
  || fail "reporting with its password: $(q "-h 127.0.0.1 -ureporting -ps3cret -e 'select current_user()'")"

# ── 6. What the template carries, and what is off ──────────────────────────────
[[ "$(q "-e \"select convert_tz('2026-01-01 12:00:00','UTC','Europe/Berlin')\"")" == "2026-01-01 13:00:00" ]] \
  && pass "the time zone tables are loaded: a named zone converts, as in the official image" \
  || fail "named time zones do not convert — the zone tables are missing"
[[ "$(q "-e 'select @@log_bin'")" == "0" ]] && pass "the binary log is off" || fail "the binary log is on"

# ── 7. The ready line reached the terminal ─────────────────────────────────────
assert_log_contains "$IT_CID" 'mysql 8\.[0-9]+\.[0-9]+ ready on localhost:3306 \(socket /var/run/mysqld/mysqld\.sock\), root and .* with no password; users: app_user, reporting; databases: myapp_test'

it_finish
