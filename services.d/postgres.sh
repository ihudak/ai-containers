#!/usr/bin/env bash
# shellcheck shell=bash
# services.d/postgres.sh — the PostgreSQL adapter for start-services.sh.
#
# SOURCED by start-services.sh (never executed), in a subshell of its own, and
# implementing the adapter contract in AGENTS.md ("In-container database
# servers").
#
# What it builds is a THROWAWAY TEST CLUSTER: initdb into the container's own
# filesystem on every start, trust authentication, listening on localhost and
# the Debian default socket only, durability switched off. Nothing here is fit
# for data anyone wants to keep, and nothing here has to be — sandbox.sh runs
# the container with --rm.
#
# Every path is overridable from the environment so tests/test-postgres.sh can
# drive this file against fake binaries. Nothing in the image sets them. The
# knobs are AI_SERVICES_PG_*, never PG_*: container.env reaches `start`, and an
# app's own PG_PORT=5433 read here would move the server off libpq's default.
# (`prepare`, which runs as root, gets none of them: entrypoint.sh scrubs its
# environment.)

PG_MAJOR_FILE="${AI_SERVICES_PG_MAJOR_FILE:-/etc/ai-containers/postgres-major}"
PG_LIB_ROOT="${AI_SERVICES_PG_LIB_ROOT:-/usr/lib/postgresql}"
PG_SOCKET_DIR="${AI_SERVICES_PG_SOCKET_DIR:-/var/run/postgresql}"
PG_PORT="${AI_SERVICES_PG_PORT:-5432}"
PG_SUPERUSER="${AI_SERVICES_PG_SUPERUSER:-$(id -un)}"
# Role and database names a project may ask for. Deliberately narrow — every
# name reaches SQL — and the superuser's own name is NOT held to it: it comes
# from the host, where a macOS `John.Doe` is legal. _pg_ident quotes either.
PG_NAME_RE='^[a-z_][a-z0-9_]*$'

_pg_bin() {
  local major
  # 2>/dev/null BEFORE the <: redirections apply left to right, and a missing
  # marker must fail silently — it is how "not in this image" is detected.
  major="$(tr -d '[:space:]' 2>/dev/null < "$PG_MAJOR_FILE")"
  printf '%s/%s/bin' "$PG_LIB_ROOT" "$major"
}

# Whitespace off both ends — [[:space:]] includes the \r a CRLF container.env leaves.
_pg_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# An SQL identifier: double-quoted, any embedded " doubled.
_pg_ident() { printf '"%s"' "${1//\"/\"\"}"; }

_pg_in() {  # <needle> <haystack…> → 0 if present
  local x="$1" y; shift
  for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done
  return 1
}

_pg_join() {  # <item…> → "a, b, c"
  local out="$1" y; shift
  for y in "$@"; do out+=", $y"; done
  printf '%s' "$out"
}

# _pg_sql <statement> — run it as the superuser over the socket. Prints psql's
# error text (one line) on failure and returns psql's status.
_pg_sql() {
  local err rc
  err="$("$(_pg_bin)/psql" -X -q -v ON_ERROR_STOP=1 -h "$PG_SOCKET_DIR" -p "$PG_PORT" \
           -U "$PG_SUPERUSER" -d postgres -c "$1" 2>&1 >/dev/null)"
  rc=$?
  (( rc == 0 )) || printf '%s' "${err//$'\n'/ }"
  return "$rc"
}

svc_installed_version() {
  local bin; bin="$(_pg_bin)/postgres"
  [[ -x "$bin" ]] || return 0
  "$bin" --version 2>/dev/null | sed -n 's/^postgres (PostgreSQL) \([0-9][0-9.]*\).*/\1/p'
}

svc_runtime_dirs() { printf '%s\n' "$PG_SOCKET_DIR"; }

svc_start() {  # <datadir> <logfile>
  local datadir="$1" logfile="$2" bin err
  bin="$(_pg_bin)"
  # en_US.UTF-8, not the image's C.utf8: the official postgres image — what CI
  # service containers usually run — defaults to it, and collation decides
  # ORDER BY on text. A suite green in CI must not go red here on sort order.
  # --no-sync: initdb's own flush of the new cluster, for the reason fsync is
  # off below.
  "$bin/initdb" -D "$datadir" -U "$PG_SUPERUSER" --auth=trust \
    --encoding=UTF8 --locale=en_US.UTF-8 --no-sync || return 1
  # fsync/synchronous_commit/full_page_writes off: durability buys nothing for a
  # cluster deleted on exit. mmap: dynamic shared memory from files in the data
  # directory, so Docker's 64 MB /dev/shm never limits it and sandbox.sh's
  # --shm-size stays playwright's business.
  cat >> "$datadir/postgresql.conf" <<EOF || return 1

# ── ai-containers (services.d/postgres.sh): a throwaway test cluster ──
listen_addresses = 'localhost'
port = $PG_PORT
unix_socket_directories = '$PG_SOCKET_DIR'
fsync = off
synchronous_commit = off
full_page_writes = off
dynamic_shared_memory_type = mmap
EOF
  "$bin/pg_ctl" -D "$datadir" -l "$logfile" -w -t 30 start || return 1
  # psql and libpq default the database name to the user name, and initdb makes
  # only postgres/template0/template1 — so without this a bare `psql` fails with
  # `database "<user>" does not exist`. Cluster initialisation, like the
  # official image's default POSTGRES_DB, and so here rather than in
  # svc_provision, which creates only what the project asked for.
  [[ "$PG_SUPERUSER" == postgres ]] && return 0
  err="$(_pg_sql "CREATE DATABASE $(_pg_ident "$PG_SUPERUSER") OWNER $(_pg_ident "$PG_SUPERUSER")")" && return 0
  printf "could not create the superuser's own database %s: %s\n" "$(_pg_ident "$PG_SUPERUSER")" "$err"
  return 1
}

svc_provision() {
  local entry name owner err
  local -a entries=() roles=() dbs=() known=("$PG_SUPERUSER")

  IFS=',' read -ra entries <<< "${POSTGRES_ROLES:-}"
  for entry in "${entries[@]}"; do
    name="$(_pg_trim "$entry")"
    # Known names first: the superuser's own name is not held to the pattern
    # (a macOS John.Doe), and listing it must not draw a warning.
    _pg_in "$name" "${known[@]}" && continue   # the superuser itself, or a repeat
    if [[ ! "$name" =~ $PG_NAME_RE ]]; then
      printf "WARNING: POSTGRES_ROLES: '%s' is not a valid role name (lowercase letters, digits, _) — skipped\n" "$name" >&2
      continue
    fi
    if err="$(_pg_sql "CREATE ROLE $(_pg_ident "$name") SUPERUSER LOGIN")"; then
      roles+=("$name"); known+=("$name")
    else
      printf "WARNING: POSTGRES_ROLES: could not create role '%s': %s\n" "$name" "$err" >&2
    fi
  done

  entries=()
  IFS=',' read -ra entries <<< "${POSTGRES_DATABASES:-}"
  for entry in "${entries[@]}"; do
    entry="$(_pg_trim "$entry")"
    name="${entry%%:*}"
    owner="$PG_SUPERUSER"
    [[ "$entry" == *:* ]] && owner="${entry#*:}"
    if [[ ! "$name" =~ $PG_NAME_RE ]] || { [[ "$entry" == *:* ]] && [[ ! "$owner" =~ $PG_NAME_RE ]]; }; then
      printf "WARNING: POSTGRES_DATABASES: '%s' is not name or name:owner (lowercase letters, digits, _) — skipped\n" "$entry" >&2
      continue
    fi
    if ! _pg_in "$owner" "${known[@]}"; then
      printf "WARNING: POSTGRES_DATABASES: '%s' — owner '%s' is not a role here (add it to POSTGRES_ROLES) — skipped\n" "$entry" "$owner" >&2
      continue
    fi
    _pg_in "$name" "${dbs[@]}" && continue
    if err="$(_pg_sql "CREATE DATABASE $(_pg_ident "$name") OWNER $(_pg_ident "$owner")")"; then
      dbs+=("$name")
    else
      printf "WARNING: POSTGRES_DATABASES: could not create database '%s': %s\n" "$name" "$err" >&2
    fi
  done

  (( ${#roles[@]} )) && printf '; roles: %s' "$(_pg_join "${roles[@]}")"
  (( ${#dbs[@]} )) && printf '; databases: %s' "$(_pg_join "${dbs[@]}")"
  return 0
}

svc_endpoint() {
  printf 'localhost:%s (socket %s), superuser %s' "$PG_PORT" "$PG_SOCKET_DIR" "$PG_SUPERUSER"
}
