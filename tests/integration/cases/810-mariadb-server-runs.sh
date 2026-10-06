#!/usr/bin/env bash
# summary:  mariadb=<series> installs from MariaDB's repository and starts a loopback-only server owned by the agent, utf8mb4 as packaged
# tags:     packages slow
# requires: docker launcher netadmin
# image:    mariadb
# timeout:  900
#
# WHAT IS PROVEN, against the real image the `mariadb` variant builds with
# mariadb=11.4 (a series from MariaDB's own repository) and db-clients=mysql,
# in RESTRICTED mode:
#   1. a bare `mariadb` connects as the agent's own account over the default
#      socket — the entrypoint started the server, and the account exists — and
#      `mysql` runs MariaDB's client too, though db-clients=mysql installed
#      MySQL's (apt swapped it; mariadb-client-compat supplies the name);
#   2. root connects over 127.0.0.1:3306 with no password though container.env
#      sets an app's own MYSQL_PORT=7777 and MARIADB_PORT=7778; and over ::1,
#      where the container has an IPv6 loopback;
#   3. every mariadbd process runs as the sandbox UID;
#   4. it listens on loopback addresses only;
#   5. MYSQL_USERS / MYSQL_DATABASES were provisioned, as for mysql=;
#   6. it is the PINNED series (11.4.x, MariaDB's build), serving the package's
#      own character set — utf8mb4, utf8mb4_uca1400_ai_ci, as the official 11.4
#      image does, where --no-defaults alone would serve latin1 — and the time
#      zone tables are loaded;
#   7. libmysqlclient-dev's headers survived the client swap, so a native
#      driver (mysql2, mysqlclient) still compiles;
#   8. the entrypoint printed the ready line.
#
# The hermetic halves are tests/test-mariadb.sh and tests/test-mysql.sh.
#
# Mutations 810-814 demonstrate this case failing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
scratch="$(it_scratch)"
printf 'MYSQL_PORT=7777\nMARIADB_PORT=7778\nMYSQL_USERS=app_user,reporting:s3cret\nMYSQL_DATABASES=myapp_test\n' > "$scratch/container.env"
export SANDBOX_ENV_FILE="$scratch/container.env"
launcher_up restricted || it_finish
me="${SANDBOX_USER:-$(id -un)}"

# MariaDB 11.4's client warns on every passwordless TCP login that it disabled
# server-certificate verification; that line is the client's, not an answer.
q()  { agent_exec "$IT_CID" "mariadb -N -B $1" 2>&1 \
         | grep -v -E '^(mariadb|mysql): \[Warning\]|Deprecated program name|ssl-verify-server-cert is disabled'; }

# ── 1. A bare client connects as the agent's own account; `mysql` is MariaDB's ─
if [[ "$(q "-e 'select current_user()'")" == "$me@localhost" ]]; then
  pass "a bare mariadb connects over the default socket as $me@localhost, as the agent"
else
  fail "a bare mariadb did not connect as $me@localhost — no server, not on the default socket, or no account"
  docker exec "$IT_CID" tail -n 30 /var/log/ai-services/mariadb.log 2>&1 | sed 's/^/     /'
  docker logs "$IT_CID" 2>&1 | grep -iE 'mariadb|services' | tail -n 10 | sed 's/^/     /'
  it_finish
fi
out="$(agent_exec "$IT_CID" "mysql -N -B -e 'select version()'" 2>&1 | grep -v -E 'Warning|Deprecated')"
[[ "$out" == *MariaDB* ]] && pass "\`mysql\` runs MariaDB's client though db-clients=mysql installed MySQL's ($out)" \
  || fail "\`mysql\` is not MariaDB's client: $out"

# ── 2. root over TCP, no password; the app's MYSQL_PORT did not move it ────────
[[ "$(q "-h 127.0.0.1 -P 3306 -uroot -e 'select 1'")" == "1" ]] \
  && pass "root connects over 127.0.0.1:3306 with no password — an app's MYSQL_PORT / MARIADB_PORT did not move the server" \
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
          [ "$(cat "$p/comm" 2>/dev/null)" = mariadbd ] && awk "/^Uid:/{print \$2}" "$p/status"
        done | sort -u' 2>/dev/null)"
if [[ -z "$uids" ]]; then
  fail "no mariadbd process found in /proc — assertion 3 verified nothing"
elif [[ "$uids" == "$IT_LAUNCH_UID" ]]; then
  pass "every mariadbd process runs as the sandbox UID ($IT_LAUNCH_UID)"
else
  fail "mariadbd runs as UID(s) $(tr '\n' ' ' <<<"$uids")— expected only $IT_LAUNCH_UID"
fi

# ── 4. Loopback only ───────────────────────────────────────────────────────────
listeners="$(docker exec "$IT_CID" awk 'FNR>1 && $4=="0A" && $2 ~ /:0CEA$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if [[ -z "$listeners" ]]; then
  fail "no listener on port 3306 in /proc/net — assertion 4 verified nothing"
elif exposed="$(grep -vE '^(0100007F|00000000000000000000000001000000):0CEA$' <<<"$listeners")"; then
  fail "mariadb listens beyond loopback: $(tr '\n' ' ' <<<"$exposed")"
else
  pass "port 3306 is bound to loopback only ($(tr '\n' ' ' <<<"$listeners"))"
fi

# ── 5. Provisioning from container.env ─────────────────────────────────────────
out="$(q "-h 127.0.0.1 -uapp_user myapp_test -e 'create table it_t (id int primary key); insert into it_t values (1); select count(*) from it_t'")"
[[ "$out" == "1" ]] && pass "MYSQL_USERS/MYSQL_DATABASES: app_user (no password) creates a table in myapp_test over TCP" \
  || fail "app_user in myapp_test over TCP: $out"
[[ "$(q "-h 127.0.0.1 -ureporting -ps3cret -e 'select current_user()'")" == "reporting@localhost" ]] \
  && pass "MYSQL_USERS: reporting connects with the password it was given" \
  || fail "reporting with its password: $(q "-h 127.0.0.1 -ureporting -ps3cret -e 'select current_user()'")"

# ── 6. The pinned series, its own character set, the zone tables ───────────────
ver="$(q "-e 'select version()'")"
[[ "$ver" == 11.4.*MariaDB* ]] && pass "the server is the pinned series, MariaDB's own build ($ver)" || fail "not the pinned 11.4: $ver"
cs="$(q "-e 'select @@character_set_server, @@collation_server'")"
[[ "$cs" == $'utf8mb4\tutf8mb4_uca1400_ai_ci' ]] \
  && pass "it serves the package's own character set: utf8mb4 / utf8mb4_uca1400_ai_ci, as the official 11.4 image does" \
  || fail "character set and collation are '$cs', not the package's utf8mb4 / utf8mb4_uca1400_ai_ci"
[[ "$(q "-e \"select convert_tz('2026-01-01 12:00:00','UTC','Europe/Berlin')\"")" == "2026-01-01 13:00:00" ]] \
  && pass "the time zone tables are loaded: a named zone converts" \
  || fail "named time zones do not convert — the zone tables are missing"

# ── 7. A native driver still compiles ──────────────────────────────────────────
docker exec "$IT_CID" test -f /usr/include/mysql/mysql.h \
  && pass "libmysqlclient-dev's mysql.h survived the client swap" \
  || fail "/usr/include/mysql/mysql.h is gone — a native driver would not compile"

# ── 8. The ready line reached the terminal ─────────────────────────────────────
assert_log_contains "$IT_CID" 'mariadb 11\.4\.[0-9]+ ready on localhost:3306 \(socket /var/run/mysqld/mysqld\.sock\), root and .* with no password; users: app_user, reporting; databases: myapp_test'

it_finish
