#!/usr/bin/env bash
# start-services.sh — start the in-container database servers sandbox.conf enabled.
#
# Two phases, because the entrypoint holds root only until it execs the agent
# shell, and a server must never run as root:
#
#   start-services.sh prepare   ROOT. Creates each enabled service's data, log
#                               and runtime directories and hands them to the
#                               sandbox user. Starts nothing, says nothing.
#   start-services.sh start     SANDBOX USER. Initialises and starts each server,
#                               provisions what the project asked for, and prints
#                               one ready line — or a warning and the log's tail.
#
# Input is AI_SERVICES ("name=value,name=value"), built by sandbox.sh from
# sandbox.conf (sandbox-common.sh: `services_csv()`). Each name has an adapter,
# services.d/<name>.sh, sourced in its OWN subshell so one adapter's functions
# can never stand in for another's. The adapter contract is in AGENTS.md
# ("In-container database servers").
#
# Never fatal: a server that fails to start must not cost the user their shell.
# Every path through `prepare` and `start` exits 0; only a usage error does not.
set -o pipefail

SERVICES_DIR="${AI_SERVICES_DIR:-/etc/ai-containers/services.d}"
STATE_ROOT="${AI_SERVICES_STATE_ROOT:-/var/lib/ai-services}"
LOG_ROOT="${AI_SERVICES_LOG_ROOT:-/var/log/ai-services}"
TIMEOUT="${AI_SERVICES_TIMEOUT:-60}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=60
# A name becomes a PATH ($SERVICES_DIR/<name>.sh), so it is held to a pattern
# with no `/` and no `.` — nothing can name a file outside services.d.
NAME_RE='^[a-z][a-z0-9-]*$'
ADAPTER_FUNCS=(svc_installed_version svc_runtime_dirs svc_start svc_provision svc_endpoint)

warn() { printf 'WARNING: %s\n' "$*" >&2; }

# run_bounded <seconds> <command…> — the command's own status, or 124 if the
# clock expired. The watchdog shape of tests/portability.sh: `p_timeout()`,
# copied rather than sourced because that file is not in the image; its comment
# explains why this is a watchdog and not a polling loop, and why the watchdog's
# stdio goes to /dev/null. It differs in one respect: p_timeout bounds a single
# process, but this bounds an adapter function that starts CHILDREN by design
# (initdb, pg_ctl -w, psql), and a hang lives in a child, so the command gets its
# own process group (`set -m`) and expiry signals the whole group, not the PID.
# Not timeout(1): this file's tests run on macOS hosts, which do not ship it.
run_bounded() {
  local secs="$1"; shift
  local flag; flag="$(mktemp "${TMPDIR:-/tmp}/ai-services.XXXXXX")" || return 125
  set -m
  "$@" &
  local cmd_pid=$!
  set +m
  ( sleep "$secs"
    printf 'x' > "$flag"
    kill -TERM -- "-$cmd_pid" 2>/dev/null
    sleep 1
    kill -KILL -- "-$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local dog_pid=$!
  wait "$cmd_pid"
  local rc=$?
  kill -TERM "$dog_pid" 2>/dev/null
  wait "$dog_pid" 2>/dev/null
  if [[ -s "$flag" ]]; then rm -f "$flag"; return 124; fi
  rm -f "$flag"
  return "$rc"
}

# version_matches <requested> <installed> — 0 when <installed> IS the requested
# version or a release of it: `17` matches `17` and `17.11`, never `170.1`.
version_matches() {
  [[ "$2" == "$1" || "$2" == "$1".* ]]
}

# load_adapter <name> — source the adapter into THIS shell (callers are always
# inside a subshell). 0 = loaded and complete, 1 = failed to load, 2 = incomplete.
load_adapter() {
  local fn
  # shellcheck source=/dev/null
  source "$SERVICES_DIR/$1.sh" || return 1
  for fn in "${ADAPTER_FUNCS[@]}"; do
    declare -F "$fn" >/dev/null || return 2
  done
  return 0
}

# svc_up <datadir> <logfile> <suffix-file> — start, then provision. svc_start's
# output goes to the log: on success it is initdb/pg_ctl chatter, and on failure
# the runner prints the log's tail anyway. svc_provision's warnings reach the
# terminal; its stdout — the ready-line suffix — goes to a FILE, because this
# runs in the background under run_bounded and has no caller to capture it.
svc_up() {
  svc_start "$1" "$2" >>"$2" 2>&1 || return 1
  svc_provision > "$3"
}

# each_service <callback> — <callback> <name> <value> for every AI_SERVICES entry.
# Whitespace around an entry is dropped, an empty entry is skipped, and an entry
# with no `=value` (or an empty one) means ON.
each_service() {
  local cb="$1" entry name value
  local -a entries=()
  IFS=',' read -ra entries <<< "${AI_SERVICES:-}"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    value=""
    [[ "$entry" == *=* ]] && value="${entry#*=}"
    [[ -n "$value" ]] || value="ON"
    "$cb" "$name" "$value"
  done
}

# prepare_one <name> <value> — ROOT. Silent by design: every warning belongs to
# `start`, which runs next and would otherwise print each one twice.
prepare_one() {
  local name="$1"
  [[ "$name" =~ $NAME_RE && -f "$SERVICES_DIR/$name.sh" ]] || return 0
  (
    load_adapter "$name" || exit 0
    [[ -n "$(svc_installed_version)" ]] || exit 0
    owner="${SANDBOX_UID:-1000}:${SANDBOX_GID:-1000}"
    dirs=("$STATE_ROOT/$name" "$LOG_ROOT")
    while IFS= read -r d; do
      [[ -n "$d" ]] && dirs+=("$d")
    done < <(svc_runtime_dirs)
    for d in "${dirs[@]}"; do
      mkdir -p "$d" && chown "$owner" "$d"
    done
  )
  return 0
}

# start_one <name> <value> — SANDBOX USER.
start_one() {
  local name="$1" value="$2"
  if [[ ! "$name" =~ $NAME_RE ]]; then
    warn "AI_SERVICES: '$name' is not a valid service name — skipped"
    return 0
  fi
  if [[ ! -f "$SERVICES_DIR/$name.sh" ]]; then
    warn "unknown service '$name' (no $SERVICES_DIR/$name.sh) — skipped"
    return 0
  fi
  (
    load_adapter "$name"
    case $? in
      0) ;;
      1) warn "services.d/$name.sh failed to load — skipped"; exit 0 ;;
      *) warn "services.d/$name.sh is incomplete — skipped"; exit 0 ;;
    esac
    installed="$(svc_installed_version)"
    if [[ -z "$installed" ]]; then
      warn "sandbox.conf has $name=$value, but this image has no $name server. Rebuild: ./build.sh"
      exit 0
    fi
    logfile="$LOG_ROOT/$name.log"
    suffix_file="$(mktemp "${TMPDIR:-/tmp}/ai-services-suffix.XXXXXX")" || exit 0
    run_bounded "$TIMEOUT" svc_up "$STATE_ROOT/$name" "$logfile" "$suffix_file"
    rc=$?
    if (( rc == 0 )); then
      printf '%s %s ready on %s%s\n' "$name" "$installed" "$(svc_endpoint)" "$(cat "$suffix_file")" >&2
      if [[ "$value" != "ON" ]] && ! version_matches "$value" "$installed"; then
        warn "sandbox.conf asks for $name=$value, this image has $installed. Rebuild: ./build.sh"
      fi
    else
      if (( rc == 124 )); then
        warn "$name did not become ready within ${TIMEOUT}s — log: $logfile"
      else
        warn "$name failed to start — log: $logfile"
      fi
      tail -n 20 "$logfile" 2>/dev/null | sed 's/^/    /' >&2
    fi
    rm -f "$suffix_file"
  )
  return 0
}

case "${1:-}" in
  prepare) each_service prepare_one ;;
  start)   each_service start_one ;;
  *)       printf 'usage: start-services.sh prepare|start\n' >&2; exit 2 ;;
esac
exit 0
