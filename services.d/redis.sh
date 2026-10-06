#!/usr/bin/env bash
# shellcheck shell=bash
# services.d/redis.sh — the Redis adapter for start-services.sh.
#
# SOURCED by start-services.sh (never executed), in a subshell of its own, and
# implementing the adapter contract in AGENTS.md ("In-container database
# servers").
#
# A THROWAWAY server: Ubuntu's redis-server, started as the sandbox user with
# every option on its command line (the package's /etc/redis/redis.conf is not
# read), on the loopback addresses only, with persistence off — no snapshots, no
# append-only file. sandbox.sh runs the container with --rm.
#
# The binaries and the port are overridable so tests/test-redis.sh can drive this
# file against fakes; nothing in the image sets them. The knobs are
# AI_SERVICES_REDIS_*, never REDIS_*: container.env reaches `start`, and an app's
# own REDIS_PORT read here would move the server off the port its clients expect.

REDIS_SERVER="${AI_SERVICES_REDIS_SERVER:-/usr/bin/redis-server}"
REDIS_CLI="${AI_SERVICES_REDIS_CLI:-/usr/bin/redis-cli}"
REDIS_PORT="${AI_SERVICES_REDIS_PORT:-6379}"
# How many 0.1 s waits svc_start allows the server to answer: 30 s by default.
REDIS_TRIES="${AI_SERVICES_REDIS_TRIES:-300}"
[[ "$REDIS_TRIES" =~ ^[1-9][0-9]*$ ]] || REDIS_TRIES=300

# The pid of the server answering on the port, from its own INFO.
_redis_info_pid() {
  "$REDIS_CLI" -h 127.0.0.1 -p "$REDIS_PORT" info server 2>/dev/null \
    | sed -n 's/^process_id:\([0-9][0-9]*\).*/\1/p'
}

svc_installed_version() {
  [[ -x "$REDIS_SERVER" ]] || return 0
  "$REDIS_SERVER" --version 2>/dev/null | sed -n 's/^Redis server v=\([0-9][0-9.]*\) .*/\1/p'
}

# Nothing outside its data directory: the pid file lives there, and there is no
# socket — clients connect over TCP (redis://localhost:6379).
svc_runtime_dirs() { :; }

svc_start() {  # <datadir> <logfile>
  local datadir="$1" logfile="$2" pid i
  # Both loopback addresses: a client that resolves `localhost` to ::1 first
  # (Node 17 and later) must not be refused. The `-` makes ::1 optional, so a
  # container without IPv6 still starts. --save '' and --appendonly no: nothing
  # is written to disk. --daemonize: the server detaches into a session of its
  # own and the call returns, so the runner's watchdog never holds the server.
  "$REDIS_SERVER" --bind 127.0.0.1 -::1 --port "$REDIS_PORT" \
    --daemonize yes --pidfile "$datadir/redis.pid" --logfile "$logfile" --dir "$datadir" \
    --save '' --appendonly no || return 1
  # Detached, so started is not ready. Ready is THIS server answering: the pid it
  # reports must be the one it wrote, so no other Redis on the port passes for
  # it. One that died after writing its pid fails at once. One that never wrote
  # it — the port was taken, and it logged "Address already in use" and exited —
  # fails at the end of the wait, whose bound is well inside the runner's
  # deadline; the runner then prints the log's tail, which names the cause. No
  # probe of the port first: a listener that never accepts would hang it.
  for (( i = 0; i < REDIS_TRIES; i++ )); do
    pid="$(cat "$datadir/redis.pid" 2>/dev/null)"
    if [[ -n "$pid" ]]; then
      [[ "$(_redis_info_pid)" == "$pid" ]] && return 0
      if ! kill -0 "$pid" 2>/dev/null; then
        printf 'redis-server (pid %s) exited before answering\n' "$pid"
        return 1
      fi
    fi
    sleep 0.1
  done
  printf 'redis-server did not answer on 127.0.0.1:%s in time\n' "$REDIS_PORT"
  return 1
}

# Nothing to create: Redis has no users or databases to provision.
svc_provision() { return 0; }

svc_endpoint() { printf 'redis://localhost:%s' "$REDIS_PORT"; }
