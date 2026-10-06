#!/usr/bin/env bash
# shellcheck shell=bash
# services.d/mongo.sh — the MongoDB adapter for start-services.sh.
#
# SOURCED by start-services.sh (never executed), in a subshell of its own, and
# implementing the adapter contract in AGENTS.md ("In-container database
# servers").
#
# A THROWAWAY TEST SERVER: mongod from MongoDB's own repository, started as the
# sandbox user with every option on its command line (/etc/mongod.conf is not
# read), on the loopback addresses only, without authentication, its
# WiredTiger cache capped. Nothing to provision: MongoDB creates a database and
# a collection on the first write to them. sandbox.sh runs the container with --rm.
#
# Every path is overridable so tests/test-mongo.sh can drive this file against
# fakes; nothing in the image sets them. The knobs are AI_SERVICES_MONGO_*,
# never MONGO_*: container.env reaches `start`, and an app's own MONGO_PORT
# read here would move the server off the port its clients expect.

MONGO_MONGOD="${AI_SERVICES_MONGO_MONGOD:-/usr/bin/mongod}"
MONGO_PORT="${AI_SERVICES_MONGO_PORT:-27017}"
MONGO_IF_INET6="${AI_SERVICES_MONGO_IF_INET6:-/proc/net/if_inet6}"
# WiredTiger's own default is half of (memory − 1 GB): 1.5 GB of a 4 GB container
# (measured), for a server that holds test fixtures. A quarter of a gigabyte
# keeps it beside an app and its test runner.
MONGO_CACHE_GB="${AI_SERVICES_MONGO_CACHE_GB:-0.25}"

svc_installed_version() {
  [[ -x "$MONGO_MONGOD" ]] || return 0
  "$MONGO_MONGOD" --version 2>/dev/null | sed -n 's/^db version v\([0-9][0-9.]*\).*/\1/p'
}

# Nothing outside its data directory: the pid file and log live where the runner
# puts them, and the socket in /tmp, where mongod puts it, owner-only.
svc_runtime_dirs() { :; }

svc_start() {  # <datadir> <logfile>
  local datadir="$1" logfile="$2" bind="127.0.0.1"
  local -a v6=()
  # ::1 as well where the container has an IPv6 loopback — a client that looks
  # up `localhost` as ::1 first (Node 17 and later) must not be refused — and
  # only there.
  if grep -qE '^0{31}1 .* lo$' "$MONGO_IF_INET6" 2>/dev/null; then bind="127.0.0.1,::1"; v6=(--ipv6); fi
  # --fork returns once the server accepts connections, and non-zero when it
  # cannot start (the port taken, say); its reason is in the log.
  "$MONGO_MONGOD" --dbpath "$datadir" --logpath "$logfile" --logappend --fork \
    --pidfilepath "$datadir/mongod.pid" --port "$MONGO_PORT" --bind_ip "$bind" ${v6[@]+"${v6[@]}"} \
    --wiredTigerCacheSizeGB "$MONGO_CACHE_GB" >/dev/null || return 1
}

# Nothing to create: a database exists once something writes to it.
svc_provision() { return 0; }

svc_endpoint() { printf 'mongodb://localhost:%s' "$MONGO_PORT"; }
