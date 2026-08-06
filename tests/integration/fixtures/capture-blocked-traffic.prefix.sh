#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# KNOWN-BAD FIXTURE #1 of 2 — BUG: STARTUP DEATH (grep|grep under set -e).
#
# Deliberately reverted, kept ONLY so
# tests/integration/cases/060-restricted-empty-allowlist-still-captures.sh can
# be demonstrated FAILING against a real pre-fix daemon (real tshark, real
# NFLOG, real NET_ADMIN — not the hermetic fake tshark that
# tests/test-blocked-capture.sh uses). Do NOT "fix" this file: fixing it
# defeats its only purpose. Do NOT let this file drift from
# ../../../capture-blocked-traffic.sh except in the one function called out
# below — its evidentiary value depends on differing from the shipped script
# in exactly that one respect.
#
# This is a byte-for-byte copy of capture-blocked-traffic.sh with ONLY
# strip_allowlist() reverted to the original grep|grep|sed pipeline (and its
# two call sites adapted to match) — the construct that actually caused the
# ORIGINAL outage this whole capture tier (040/050/060) exists to catch. With
# a comments-only allowlist, this daemon dies under `set -e` BEFORE
# init_output_files ever runs: no blocked.log, no blocked-domains.txt, no
# blocked-ips.txt, no watcher at all. See the KNOWN-BAD block below for the
# mechanism.
#
# NOT to be confused with its sibling,
# capture-blocked-traffic.tab-separator-bug.sh (used by case 040) — that one
# is a COMPLETELY DIFFERENT, LATER bug: its daemon starts and announces itself
# FINE, creates all three output files FINE, and then silently drops every
# blocked packet's RECORD due to a tab/IFS-whitespace field-separator defect
# in the read loops, unrelated to allowlist parsing. Two distinct bugs, two
# distinct fixtures — do not consolidate them into one "the daemon is broken"
# fixture; each demonstrates a different failure a different case exists to
# catch.
# ═══════════════════════════════════════════════════════════════════════════

# Background daemon: captures outbound traffic that is blocked in restricted mode.
# Must be started as a root process before exec capsh so it retains CAP_NET_RAW.
# Reads blocked packets via tshark on the NFLOG netlink group that entrypoint.sh
# configures (default group 100).
#
# Usage: capture-blocked-traffic.sh [capture_dir]
#
# Writes to <capture_dir>:
#   blocked.log          timestamped log of every blocked destination
#   blocked-domains.txt  deduplicated domains  → copy-paste into allowlist-domains.txt
#   blocked-ips.txt      deduplicated IPs      → copy-paste into allowlist-cidrs.txt
#
# Internal state (dns-map, caches) is stored under a root-only directory
# (/run/agent-blocked-internal by default) so the sandbox user cannot
# tamper with the self-healing lookup tables.

capture_dir="${1:-/workspace/.agent-blocked}"
nflog_group="${NFLOG_GROUP:-100}"
domains_file="${ALLOWLIST_DOMAINS_FILE:-/tmp/allowlist-domains.txt}"
proxy_domains_file="${ALLOWLIST_PROXY_DOMAINS_FILE:-/tmp/allowlist-proxy-domains.txt}"
ipv4_set_name="${ALLOWLIST_IPV4_SET:-allowed_ipv4}"
ipv6_set_name="${ALLOWLIST_IPV6_SET:-allowed_ipv6}"
self_healing="${SELF_HEALING_ENABLED:-1}"

# Internal state directory — root-only, not on the bind-mounted workspace.
# BLOCKED_INTERNAL_DIR is an override for TESTS only (the entrypoint never sets it);
# it keeps the DNS map and allowlist caches out of the sandbox user's reach in
# production while letting the suite drive this script without root.
internal_dir="${BLOCKED_INTERNAL_DIR:-/run/agent-blocked-internal}"
mkdir -p "$internal_dir"
chmod 700 "$internal_dir"

dns_map="$internal_dir/dns-map.txt"
dns_map_lock="$internal_dir/dns-map.lock"
dns_map_max_lines=10000
blocked_log="$capture_dir/blocked.log"
blocked_domains="$capture_dir/blocked-domains.txt"
blocked_ips="$capture_dir/blocked-ips.txt"

mkdir -p "$capture_dir"
: > "$dns_map"

# ═══════════════════════════════════════════════════════════════════════════
# KNOWN-BAD: this is the ORIGINAL construct, deliberately reintroduced here.
# The shipped capture-blocked-traffic.sh replaced this whole block with a
# single awk pass specifically BECAUSE of the bug reproduced below. Do not
# "fix" it — see the file banner.
#
# Under `set -euo pipefail`, `grep -v PATTERN FILE` exits 1 (not an error —
# just "no lines matched") whenever FILE has no line matching PATTERN to
# invert, i.e. whenever every line already fails PATTERN. The SECOND grep in
# this pipeline (`grep -v '^[[:space:]]*$'`, dropping blank lines) exits 1
# exactly when its input — already comment-stripped by the first grep — has
# no non-blank line left, which is precisely a comments-only allowlist file.
# `pipefail` propagates that exit 1 as the pipeline's status, and `set -e`
# then kills this entire script on the spot — ~150 lines before
# init_output_files ever runs. Nothing is logged, no blocked.log, no
# blocked-domains.txt, no NFLOG watcher, and no self-healing, while the
# firewall keeps dropping traffic just as correctly and silently as before.
#
# A comments-only allowlist is a LEGAL configuration: allowlist-domains.txt
# and allowlist-proxy-domains.txt are nothing but their header comments
# whenever the corresponding component/fragment is OFF, which is exactly the
# case tests/integration/cases/060-*.sh drives.
# ═══════════════════════════════════════════════════════════════════════════
allowed_domains_cache="$internal_dir/allowed-domains-cache"
if [[ -f "$domains_file" ]]; then
  grep -v '^[[:space:]]*#' "$domains_file" \
    | grep -v '^[[:space:]]*$' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$allowed_domains_cache"
else
  : > "$allowed_domains_cache"
fi

# Build a list of wildcard domain patterns from the proxy-domains file.
# Each line like "*.example.com" becomes a suffix match so that
# "anything.example.com" or "deep.sub.example.com" is auto-allowed.
# KNOWN-BAD — see the block comment above allowed_domains_cache. This is the
# call site that actually fired in the original outage: with every
# proxy-fragment component OFF, the generated allowlist-proxy-domains.txt is
# nothing but its two header comments, so this second grep is the one that
# exits 1 and kills the script.
wildcard_patterns_cache="$internal_dir/wildcard-patterns-cache"
if [[ -f "$proxy_domains_file" ]]; then
  grep -v '^[[:space:]]*#' "$proxy_domains_file" \
    | grep -v '^[[:space:]]*$' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$wildcard_patterns_cache"
else
  : > "$wildcard_patterns_cache"
fi

init_output_files() {
  if [[ ! -f "$blocked_domains" ]]; then
    cat > "$blocked_domains" <<'HEADER'
# Blocked domains — copy-paste these lines into allowlist-domains.txt
# Generated automatically while the container runs in restricted mode.
# Each domain below was attempted but rejected by the outbound firewall.

HEADER
  fi
  if [[ ! -f "$blocked_ips" ]]; then
    cat > "$blocked_ips" <<'HEADER'
# Blocked IPs with no known domain — copy-paste into allowlist-cidrs.txt
# If you can identify the owning service, prefer adding the domain to allowlist-domains.txt instead.
# Generated automatically while the container runs in restricted mode.

HEADER
  fi
  if [[ ! -f "$blocked_log" ]]; then
    printf '%-25s  %-10s  %-42s  %s\n' "TIMESTAMP" "PROTO:PORT" "IP" "DOMAIN" >> "$blocked_log"
    printf '%s\n' "$(printf '─%.0s' {1..100})" >> "$blocked_log"
  fi
}

lookup_domain() {
  grep -m1 "^${1} " "$dns_map" 2>/dev/null | awk '{print $2}' || true
}

is_allowlisted_domain() {
  local domain="$1"
  [[ -z "$domain" ]] && return 1
  grep -qxF "$domain" "$allowed_domains_cache" 2>/dev/null
}

matches_wildcard_domain() {
  local domain="$1"
  [[ -z "$domain" ]] && return 1
  while IFS= read -r pattern; do
    # pattern is e.g. "*.example.com" — strip the "*" prefix to get ".example.com"
    local suffix="${pattern#\*}"
    # match if domain ends with the suffix (e.g. "foo.bar.example.com" ends with ".example.com")
    [[ "$domain" == *"$suffix" ]] && return 0
  done < "$wildcard_patterns_cache"
  return 1
}

auto_allow_ip() {
  local ip="$1"
  if [[ "$ip" == *:* ]]; then
    ipset add "$ipv6_set_name" "$ip" -exist 2>/dev/null
  else
    ipset add "$ipv4_set_name" "$ip" -exist 2>/dev/null
  fi
}

log_blocked() {
  local timestamp="$1" proto="$2" dst_ip="$3" dst_port="$4"
  local domain
  domain="$(lookup_domain "$dst_ip")"

  # Self-healing: if the blocked IP maps to an allowlisted domain (exact or
  # wildcard), add it to the ipset immediately so subsequent packets go through
  # without waiting for the next scheduled refresh.
  if [[ "$self_healing" == "1" ]] && { is_allowlisted_domain "$domain" || matches_wildcard_domain "$domain"; }; then
    auto_allow_ip "$dst_ip"
    printf '%-25s  %-10s  %-42s  %s (auto-allowed)\n' \
      "$timestamp" "$proto:$dst_port" "$dst_ip" "$domain" >> "$blocked_log"
    return
  fi

  printf '%-25s  %-10s  %-42s  %s\n' \
    "$timestamp" "$proto:$dst_port" "$dst_ip" "${domain:-(no domain)}" >> "$blocked_log"
  if [[ -n "$domain" ]]; then
    grep -qxF "$domain" "$blocked_domains" 2>/dev/null || printf '%s\n' "$domain" >> "$blocked_domains"
  else
    grep -qxF "$dst_ip" "$blocked_ips" 2>/dev/null || printf '%s\n' "$dst_ip" >> "$blocked_ips"
  fi
}

start_dns_map_builder() {
  # Captures DNS responses and builds a live IP → FQDN map.
  (
    tshark -i any -n -l \
      -f "port 53" \
      -Y "dns.flags.response == 1 and (dns.a or dns.aaaa)" \
      -T fields -e dns.resp.name -e dns.a -e dns.aaaa \
      2>"$capture_dir/tshark-dns-errors.log" | \
    while IFS=$'\t' read -r raw_name a_list aaaa_list; do
      # dns.resp.name can return comma-separated duplicates; take the first.
      local name="${raw_name%%,*}"
      [[ -z "$name" ]] && continue
      for ip in ${a_list//,/ }; do
        [[ -z "$ip" ]] && continue
        flock "$dns_map_lock" bash -c '
          grep -qxF "$1 $2" "$3" 2>/dev/null || {
            if [ "$(wc -l < "$3" 2>/dev/null || echo 0)" -ge "$4" ]; then
              tail -n $(( $4 / 2 )) "$3" > "$3.tmp" && mv "$3.tmp" "$3"
            fi
            printf "%s %s\n" "$1" "$2" >> "$3"
          }
        ' -- "$ip" "$name" "$dns_map" "$dns_map_max_lines"
      done
      for ip in ${aaaa_list//,/ }; do
        [[ -z "$ip" ]] && continue
        flock "$dns_map_lock" bash -c '
          grep -qxF "$1 $2" "$3" 2>/dev/null || {
            if [ "$(wc -l < "$3" 2>/dev/null || echo 0)" -ge "$4" ]; then
              tail -n $(( $4 / 2 )) "$3" > "$3.tmp" && mv "$3.tmp" "$3"
            fi
            printf "%s %s\n" "$1" "$2" >> "$3"
          }
        ' -- "$ip" "$name" "$dns_map" "$dns_map_max_lines"
      done
    done
  ) &
}

start_blocked_watcher() {
  # Reads blocked packets from the NFLOG netlink group via tshark.
  # entrypoint.sh adds an NFLOG rule at the END of the OUTPUT chain (after all
  # ACCEPT rules) with --nflog-group 100.  Every packet that reaches it is
  # about to be dropped by the default DROP policy.
  #
  # NFLOG delivers packets to userspace via netlink, which works reliably in
  # all environments including WSL2 with the nf_tables backend.  The older LOG
  # target (dmesg) silently fails in many container/WSL2 setups.
  #
  # Both ip.dst (IPv4) and ipv6.dst (IPv6) are captured so blocked IPv6
  # destinations are logged and self-healed just like IPv4 ones.
  (
    tshark -i "nflog:$nflog_group" -l -n \
      -T fields -e ip.dst -e ipv6.dst -e tcp.dstport -e udp.dstport \
      2>"$capture_dir/tshark-nflog-errors.log" | \
    while IFS=$'\t' read -r dst4 dst6 tcp_port udp_port; do
      local dst="${dst4:-$dst6}"
      local port="${tcp_port:-$udp_port}"
      [[ -z "$dst" || -z "$port" ]] && continue
      local proto="TCP"
      [[ -n "$udp_port" && -z "$tcp_port" ]] && proto="UDP"
      ts="$(date -u '+%Y-%m-%dT%H:%M:%S')"
      log_blocked "$ts" "$proto" "$dst" "$port"
    done
  ) &
}

init_output_files
start_dns_map_builder
start_blocked_watcher

printf 'Blocked traffic capture started → %s\n' "$capture_dir"
if [[ "$self_healing" == "1" ]]; then
  printf '  self-healing: ON (exact + wildcard domain matching)\n'
else
  printf '  self-healing: OFF (logging only)\n'
fi
printf '  blocked.log         — full timestamped log\n'
printf '  blocked-domains.txt — copy-paste to allowlist-domains.txt\n'
printf '  blocked-ips.txt     — copy-paste to allowlist-cidrs.txt\n'
