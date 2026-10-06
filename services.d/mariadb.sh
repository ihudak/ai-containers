#!/usr/bin/env bash
# shellcheck shell=bash
# services.d/mariadb.sh — the MariaDB adapter for start-services.sh.
#
# SOURCED by start-services.sh (never executed), in a subshell of its own, and
# implementing the adapter contract in AGENTS.md ("In-container database
# servers").
#
# MariaDB speaks MySQL's protocol, its accounts and its SQL for everything
# provisioning does, so this adapter IS the MySQL one (services.d/mysql.sh) —
# the same accounts, the same MYSQL_USERS / MYSQL_DATABASES, the same ready line
# — with its own binaries, its own template, and its own start: mariadbd has no
# --daemonize. mysql= and mariadb= are never both on (build.sh refuses it), so
# the shared socket path and port are never contested.
#
# The knobs are AI_SERVICES_MARIADB_*, never MARIADB_* or MYSQL_*: container.env
# reaches `start`, and an app's own variables must not move the server.

# shellcheck source=services.d/mysql.sh
source "$(dirname "${BASH_SOURCE[0]}")/mysql.sh"

MYSQL_MYSQLD="${AI_SERVICES_MARIADB_MARIADBD:-/usr/sbin/mariadbd}"
MYSQL_CLIENT="${AI_SERVICES_MARIADB_CLIENT:-/usr/bin/mariadb}"
MYSQL_TEMPLATE="${AI_SERVICES_MARIADB_TEMPLATE:-/usr/share/ai-containers/mariadb-template}"
MYSQL_SOCKET_DIR="${AI_SERVICES_MARIADB_SOCKET_DIR:-/var/run/mysqld}"
MYSQL_PORT="${AI_SERVICES_MARIADB_PORT:-3306}"
MYSQL_SELF="${AI_SERVICES_MARIADB_SELF:-$(id -un)}"
MYSQL_IF_INET6="${AI_SERVICES_MARIADB_IF_INET6:-/proc/net/if_inet6}"
# How many 0.1 s waits svc_start allows the server to answer: 30 s by default.
MARIADB_TRIES="${AI_SERVICES_MARIADB_TRIES:-300}"
[[ "$MARIADB_TRIES" =~ ^[1-9][0-9]*$ ]] || MARIADB_TRIES=300

# The pid file of the server answering on the socket, from the server itself.
_mariadb_pid_file() {
  "$MYSQL_CLIENT" --no-defaults -uroot --socket="$(_mysql_sock)" -N -B -e 'SELECT @@pid_file' 2>/dev/null
}

svc_start() {  # <datadir> <logfile>
  local datadir="$1" logfile="$2" bind="127.0.0.1" pid i
  local -a cs=()
  cp -a "$MYSQL_TEMPLATE/." "$datadir/" || return 1
  # ::1 as well where the container has an IPv6 loopback (Node 17 and later look
  # up `localhost` as ::1 first), and only there: an address that cannot be
  # bound stops the server.
  if grep -qE '^0{31}1 .* lo$' "$MYSQL_IF_INET6" 2>/dev/null; then bind="127.0.0.1,::1"; fi
  # --no-defaults keeps every packaged option out — and with it the character
  # set the package intends: run bare, MariaDB 10.11 serves latin1. So the
  # package's own character set and collation options are read from its
  # defaults and passed back — what the official mariadb image, built from the
  # same packages, serves: utf8mb4 with utf8mb4_general_ci on Ubuntu's 10.11,
  # with utf8mb4_uca1400_ai_ci (character-set-collations) on MariaDB's 11.4.
  mapfile -t cs < <("$MYSQL_MYSQLD" --print-defaults 2>/dev/null | tr ' ' '\n' \
                     | grep -E '^--(character-set-server|collation-server|character-set-collations)=')
  # No --daemonize in mariadbd: it is started in the background, with its own
  # pid, and waited for. The redo log matches the template's (8 MB), or the
  # server would resize it at every start.
  "$MYSQL_MYSQLD" --no-defaults --datadir="$datadir" --socket="$(_mysql_sock)" \
    --port="$MYSQL_PORT" --bind-address="$bind" \
    --pid-file="$datadir/mariadbd.pid" --log-error="$logfile" \
    --skip-log-bin --innodb-log-file-size=8388608 --innodb-flush-log-at-trx-commit=0 \
    --innodb-doublewrite=OFF --secure-file-priv= ${cs[@]+"${cs[@]}"} \
    </dev/null >/dev/null 2>&1 &
  pid=$!
  # Ready is THIS server answering on the socket: the pid file it reports is the
  # one this start gave it, so another server on the socket never passes for it
  # (measured: one did, and the start then failed on an account that existed).
  # One that exits first (the port or the socket taken) fails at once; its
  # reason is in the log.
  for (( i = 0; i < MARIADB_TRIES; i++ )); do
    if [[ "$(_mariadb_pid_file)" == "$datadir/mariadbd.pid" ]]; then
      _mysql_create_self
      return
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      printf 'mariadbd (pid %s) exited before answering\n' "$pid"
      return 1
    fi
    sleep 0.1
  done
  printf 'mariadbd did not answer on %s in time\n' "$(_mysql_sock)"
  return 1
}
