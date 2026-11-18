#!/usr/bin/env bash
set -euo pipefail

command="${1:-start}"
capture_dir="${2:-/workspace/.agent-discovery}"
pcap_file="$capture_dir/agent-traffic.pcap"
dns_out="$capture_dir/agent-dns.txt"
sni_out="$capture_dir/agent-sni.txt"
log_file="$capture_dir/tcpdump.log"
# The capture directory is the agent's, kept on the host between launches, and
# `start` runs as root. So the pid file is in a root-only directory of this
# container's own /run, which a new container starts without: a tcpdump.pid the
# agent left in the capture directory named a live pid (1 always is), and the
# next launch reported "already running" and captured nothing (bugs review
# RT-15). DISCOVERY_INTERNAL_DIR is for the tests only; the entrypoint never
# sets it.
internal_dir="${DISCOVERY_INTERNAL_DIR:-/run/agent-discovery-internal}"
pid_file="$internal_dir/tcpdump.pid"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
}

ensure_capture_dir() {
  if [[ -e "$capture_dir" && ! -d "$capture_dir" ]]; then
    printf 'Capture path exists but is not a directory: %s\n' "$capture_dir" >&2
    exit 1
  fi
  mkdir -p "$capture_dir"
}

tcpdump_running() {
  [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1
}

extract_capture() {
  ensure_capture_dir
  require_command tshark

  if [[ ! -f "$pcap_file" ]]; then
    printf 'No capture file found at %s\n' "$pcap_file" >&2
    exit 1
  fi

  tshark -r "$pcap_file" -Y "dns.qry.name" -T fields -e dns.qry.name 2>/dev/null | sort -u > "$dns_out" || true
  tshark -r "$pcap_file" -Y "tls.handshake.extensions_server_name" -T fields -e tls.handshake.extensions_server_name 2>/dev/null | sort -u > "$sni_out" || true

  printf 'DNS queries saved to %s\n' "$dns_out"
  printf 'TLS SNI hostnames saved to %s\n' "$sni_out"
}

# _cad_id: "<dev>:<ino>:<links>:<type>" of its operand, or of stdin with no
# operand, from GNU `stat -c` or BSD `stat -f`, probed once (the suite runs
# this on macOS too; capture-blocked-traffic.sh: `_cbt_id()`).
if stat -c '%i' / >/dev/null 2>&1; then _cad_stat_gnu=1; else _cad_stat_gnu=0; fi
_cad_id() {
  if (( _cad_stat_gnu )); then stat -c '%d:%i:%h:%F' "${@:--}" 2>/dev/null
  else stat -f '%d:%i:%l:%HT' "$@" 2>/dev/null; fi
}

start_capture() {
  ensure_capture_dir
  require_command tcpdump
  mkdir -p "$internal_dir"; chmod 700 "$internal_dir"

  if tcpdump_running; then
    printf 'Capture already running with PID %s\n' "$(cat "$pid_file")"
    exit 0
  fi

  # Root writes the log and tcpdump the pcap: never through anything the agent
  # left at those names. Both are removed, a link as the link (a pid file an
  # older engine kept here too), and the log is opened read-write, which does
  # not block on a FIFO, then used only if the descriptor is the regular file of
  # one link at that name now, not one a second container swapped in between.
  rm -f -- "$log_file" "$pcap_file" "$capture_dir/tcpdump.pid"
  local lfd a b links type
  exec {lfd}<>"$log_file"
  a="$(_cad_id <&"$lfd")" || a=""
  b="$(_cad_id "$log_file")" || b=""
  IFS=: read -r _ _ links type <<<"$a"
  if [[ -z "$a" || "$a" != "$b" || "$links" != 1 || "$type" != [Rr]egular* ]]; then
    printf 'Refusing to start the capture: %s is not a regular file of its own\n' "$log_file" >&2
    exit 1
  fi
  nohup tcpdump -i any -n -s 0 -U -w "$pcap_file" 'port 53 or port 443' </dev/null >&"$lfd" 2>&1 &
  local tcpdump_pid=$!
  disown "$tcpdump_pid" 2>/dev/null || true
  echo "$tcpdump_pid" > "$pid_file"

  printf 'Capture started with PID %s\n' "$tcpdump_pid"
  printf 'Writing pcap to %s\n' "$pcap_file"
  printf 'Capture log: %s\n' "$log_file"
}

stop_capture() {
  if ! [[ -f "$pid_file" ]]; then
    printf 'No capture PID file found at %s\n' "$pid_file" >&2
    exit 1
  fi

  local tcpdump_pid
  tcpdump_pid="$(cat "$pid_file")"

  if kill -0 "$tcpdump_pid" >/dev/null 2>&1; then
    kill "$tcpdump_pid"
    wait "$tcpdump_pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"
  extract_capture
}

status_capture() {
  if tcpdump_running; then
    printf 'Capture is running with PID %s\n' "$(cat "$pid_file")"
  else
    printf 'Capture is not running\n'
  fi

  if [[ -f "$pcap_file" ]]; then
    printf 'Capture file: %s\n' "$pcap_file"
  fi
}

case "$command" in
  start)
    start_capture
    ;;
  stop)
    stop_capture
    ;;
  extract)
    extract_capture
    ;;
  status)
    status_capture
    ;;
  *)
    printf 'Usage: %s {start|stop|extract|status} [capture-dir]\n' "$0" >&2
    exit 1
    ;;
esac
