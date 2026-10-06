#!/usr/bin/env bash
# shellcheck shell=bash
# services.d/mysql.sh — the MySQL adapter for start-services.sh.
#
# SOURCED by start-services.sh (never executed), in a subshell of its own, and
# implementing the adapter contract in AGENTS.md ("In-container database
# servers").
#
# A THROWAWAY TEST SERVER: a copy of the template data directory the image
# initialised at build time (Dockerfile), started as the sandbox user with every
# option on its command line (--no-defaults: no packaged my.cnf is read), on
# the loopback addresses and the default socket only, with durability off.
# root and the sandbox user have no password. sandbox.sh runs the container
# with --rm.
#
# Every path is overridable so tests/test-mysql.sh can drive this file against
# fakes; nothing in the image sets them. The knobs are AI_SERVICES_MYSQL_*,
# never MYSQL_*: container.env reaches `start`, and an app's own MYSQL_PORT
# read here would move the server off the port its clients expect.

MYSQL_MYSQLD="${AI_SERVICES_MYSQL_MYSQLD:-/usr/sbin/mysqld}"
MYSQL_CLIENT="${AI_SERVICES_MYSQL_CLIENT:-/usr/bin/mysql}"
MYSQL_TEMPLATE="${AI_SERVICES_MYSQL_TEMPLATE:-/usr/share/ai-containers/mysql-template}"
MYSQL_SOCKET_DIR="${AI_SERVICES_MYSQL_SOCKET_DIR:-/var/run/mysqld}"
MYSQL_PORT="${AI_SERVICES_MYSQL_PORT:-3306}"
MYSQL_SELF="${AI_SERVICES_MYSQL_SELF:-$(id -un)}"
MYSQL_IF_INET6="${AI_SERVICES_MYSQL_IF_INET6:-/proc/net/if_inet6}"
# User and database names a project may ask for. Deliberately narrow — every
# name reaches SQL. The sandbox user's own name is not held to it: it comes from
# the host, where a macOS `John.Doe` is legal; _mysql_str quotes either.
MYSQL_NAME_RE='^[a-z_][a-z0-9_]*$'

_mysql_sock() { printf '%s/mysqld.sock' "$MYSQL_SOCKET_DIR"; }

# Whitespace off both ends — [[:space:]] includes the \r a CRLF container.env leaves.
_mysql_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# An SQL string literal: single-quoted, ' doubled and \ escaped (MySQL reads a
# backslash as an escape unless NO_BACKSLASH_ESCAPES is set, which it is not).
_mysql_str() {
  local s="${1//\\/\\\\}"
  printf "'%s'" "${s//\'/\'\'}"
}

_mysql_in() {  # <needle> <haystack…> → 0 if present
  local x="$1" y; shift
  for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done
  return 1
}

# Does MYSQL_USERS give root a password? (`root:<password>`, the password possibly empty.)
_mysql_root_pw_asked() {
  local entry
  local -a entries=()
  IFS=',' read -ra entries <<< "${MYSQL_USERS:-}"
  for entry in "${entries[@]}"; do
    entry="$(_mysql_trim "$entry")"
    [[ "$entry" == *:* && "$(_mysql_trim "${entry%%:*}")" == root ]] && return 0
  done
  return 1
}

_mysql_join() {  # <item…> → "a, b, c"
  local out="$1" y; shift
  for y in "$@"; do out+=", $y"; done
  printf '%s' "$out"
}

# _mysql_sql <statement> — run it as root over the socket. Prints the client's
# error text (one line) on failure and returns its status.
_mysql_sql() {
  local err rc
  err="$("$MYSQL_CLIENT" --no-defaults -uroot --socket="$(_mysql_sock)" -e "$1" 2>&1 >/dev/null)"
  rc=$?
  (( rc == 0 )) || printf '%s' "${err//$'\n'/ }"
  return "$rc"
}

svc_installed_version() {
  # The server binary alone is not this layer: the template is what it builds.
  [[ -x "$MYSQL_MYSQLD" && -d "$MYSQL_TEMPLATE" ]] || return 0
  "$MYSQL_MYSQLD" --version 2>/dev/null | sed -n 's/.* Ver \([0-9][0-9.]*\).*/\1/p'
}

svc_runtime_dirs() { printf '%s\n' "$MYSQL_SOCKET_DIR"; }

svc_start() {  # <datadir> <logfile>
  local datadir="$1" logfile="$2" bind="127.0.0.1" err
  cp -a "$MYSQL_TEMPLATE/." "$datadir/" || return 1
  # ::1 as well where the container has an IPv6 loopback — a client that looks
  # up `localhost` as ::1 first (Node 17 and later) must not be refused — and
  # only there: mysqld refuses to start on an address it cannot bind (measured).
  if grep -qE '^0{31}1 .* lo$' "$MYSQL_IF_INET6" 2>/dev/null; then bind="127.0.0.1,::1"; fi
  # --daemonize returns once the server accepts connections, and non-zero when
  # it cannot start (the port taken, say); its reason is in the log.
  # performance_schema off: 147 MB idle instead of 376 MB (measured). Binary log,
  # redo flush and doublewrite off: durability buys nothing for a server
  # deleted on exit. No X Protocol: it would listen on 33060, on every address.
  "$MYSQL_MYSQLD" --no-defaults --datadir="$datadir" --socket="$(_mysql_sock)" \
    --port="$MYSQL_PORT" --bind-address="$bind" --mysqlx=OFF \
    --pid-file="$datadir/mysqld.pid" --log-error="$logfile" \
    --performance-schema=OFF --skip-log-bin --innodb-redo-log-capacity=8388608 \
    --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=OFF --secure-file-priv= \
    --daemonize || return 1
  # The mysql client logs in as the OS user unless told otherwise, so without
  # this a bare `mysql` is refused. Server initialisation, like the official
  # image's root account, and so here rather than in svc_provision.
  [[ "$MYSQL_SELF" == root ]] && return 0
  err="$(_mysql_sql "CREATE USER $(_mysql_str "$MYSQL_SELF")@'localhost'; GRANT ALL PRIVILEGES ON *.* TO $(_mysql_str "$MYSQL_SELF")@'localhost' WITH GRANT OPTION")" && return 0
  printf 'could not create the account %s: %s\n' "$(_mysql_str "$MYSQL_SELF")" "$err"
  return 1
}

svc_provision() {
  local entry name pw err root_pw="" root_set=""
  local -a entries=() users=() dbs=() known=(root "$MYSQL_SELF")

  IFS=',' read -ra entries <<< "${MYSQL_USERS:-}"
  for entry in "${entries[@]}"; do
    entry="$(_mysql_trim "$entry")"
    [[ -n "$entry" ]] || continue
    # The entry is trimmed, then the name; the password is everything after the
    # first `:` — a space inside it is part of it. It cannot hold a comma.
    name="$(_mysql_trim "${entry%%:*}")"
    pw=""
    [[ "$entry" == *:* ]] && pw="${entry#*:}"
    # root already exists: a password for it is set LAST, after every statement
    # below has run as root with none.
    if [[ "$name" == root ]]; then
      if [[ "$entry" == *:* ]]; then root_pw="$pw"; root_set=1; fi
      continue
    fi
    # Known names first: the sandbox user's own name is not held to the pattern
    # (a macOS John.Doe), and listing it, or a name twice, is not an error.
    _mysql_in "$name" "${known[@]}" && continue
    if [[ ! "$name" =~ $MYSQL_NAME_RE ]]; then
      printf "WARNING: MYSQL_USERS: '%s' is not a valid user name (lowercase letters, digits, _) — skipped\n" "$name" >&2
      continue
    fi
    if err="$(_mysql_sql "CREATE USER $(_mysql_str "$name")@'localhost' IDENTIFIED BY $(_mysql_str "$pw"); GRANT ALL PRIVILEGES ON *.* TO $(_mysql_str "$name")@'localhost' WITH GRANT OPTION")"; then
      users+=("$name"); known+=("$name")
    else
      printf "WARNING: MYSQL_USERS: could not create user '%s': %s\n" "$name" "$err" >&2
    fi
  done

  entries=()
  IFS=',' read -ra entries <<< "${MYSQL_DATABASES:-}"
  for entry in "${entries[@]}"; do
    name="$(_mysql_trim "$entry")"
    [[ -n "$name" ]] || continue
    if [[ "$name" == *:* ]]; then
      printf "WARNING: MYSQL_DATABASES: '%s' — a MySQL database has no owner, and every user here has all privileges; list the name alone — skipped\n" "$name" >&2
      continue
    fi
    if [[ ! "$name" =~ $MYSQL_NAME_RE ]]; then
      printf "WARNING: MYSQL_DATABASES: '%s' is not a valid database name (lowercase letters, digits, _) — skipped\n" "$name" >&2
      continue
    fi
    (( ${#dbs[@]} )) && _mysql_in "$name" "${dbs[@]}" && continue   # listed twice
    if err="$(_mysql_sql "CREATE DATABASE IF NOT EXISTS \`$name\`")"; then
      dbs+=("$name")
    else
      printf "WARNING: MYSQL_DATABASES: could not create database '%s': %s\n" "$name" "$err" >&2
    fi
  done

  if [[ -n "$root_set" ]]; then
    if err="$(_mysql_sql "ALTER USER 'root'@'localhost' IDENTIFIED BY $(_mysql_str "$root_pw")")"; then
      users+=(root)
    else
      printf "WARNING: MYSQL_USERS: could not set root's password: %s\n" "$err" >&2
    fi
  fi

  (( ${#users[@]} )) && printf '; users: %s' "$(_mysql_join "${users[@]}")"
  (( ${#dbs[@]} )) && printf '; databases: %s' "$(_mysql_join "${dbs[@]}")"
  return 0
}

svc_endpoint() {
  local who="root and $MYSQL_SELF"
  _mysql_root_pw_asked && who="$MYSQL_SELF"
  printf 'localhost:%s (socket %s), %s with no password' "$MYSQL_PORT" "$(_mysql_sock)" "$who"
}
