#!/usr/bin/env bash
set -euo pipefail

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
#
# <capture_dir> is the agent's: a host bind it owns and can write, kept between
# launches. This daemon is root for the whole session, so it never writes there
# by name. Each output is opened ONCE, at start, after removing whatever at that
# name is not a regular file, and is used only if the open descriptor is the
# regular file with one link that is at that name now (open_output()). A link
# the agent plants later only renames what the daemon writes to; a link planted
# before the start is removed, never followed. Following one wrote the
# firewall's own allowlist as root (bugs review RT-13).
#
# The DNS map says only which name to try: anyone can put a DNS response on the
# wire (port 53 is open to every address), so an address is self-healed only
# when this container's resolver gives it for that name now (resolves_to();
# bugs review RT-14).

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

# _cbt_id: "<dev>:<ino>:<links>:<type>" of its operand, or of stdin with no
# operand, from GNU `stat -c` or BSD `stat -f`. Probed once, never a fallback on
# failure: GNU `stat -f` succeeds and reports the filesystem
# (version.sh: `_ver_stat_gnu`). The suite runs this script on macOS too.
if stat -c '%i' / >/dev/null 2>&1; then _cbt_stat_gnu=1; else _cbt_stat_gnu=0; fi
_cbt_id() {
  if (( _cbt_stat_gnu )); then stat -c '%d:%i:%h:%F' "${@:--}" 2>/dev/null
  else stat -f '%d:%i:%l:%HT' "$@" 2>/dev/null; fi
}

# open_output <var> <path> [fresh]: open <path> read-write (which neither blocks
# on a FIFO nor truncates) and put the descriptor in <var>, or return 1 with a
# WARNING. A link, or anything but a regular file, at that name is removed first
# (the link itself; a directory stays, and is refused), and so is the file when
# [fresh] asks for it to start empty. Then the descriptor must be a regular file
# with one link, and the very file at that name (stat without -L: a link's own):
# a link swapped in between the removal and the open is refused, not written
# through, and so is a second name of a file elsewhere on that filesystem.
open_output() {
  local _var="$1" path="$2" fresh="${3:-}" fd a b links type
  if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) || -n "$fresh" ]]; then
    rm -f -- "$path" 2>/dev/null || true
  fi
  if ! { exec {fd}<>"$path"; } 2>/dev/null; then
    printf 'WARNING: cannot open %s; not writing it\n' "$path" >&2
    return 1
  fi
  a="$(_cbt_id <&"$fd")" || a=""
  b="$(_cbt_id "$path")" || b=""
  IFS=: read -r _ _ links type <<<"$a"
  if [[ -z "$a" || "$a" != "$b" || "$links" != 1 || "$type" != [Rr]egular* ]]; then
    exec {fd}>&-
    printf 'WARNING: %s is not a regular file of its own (a link, or a second name); not writing it\n' "$path" >&2
    return 1
  fi
  printf -v "$_var" '%s' "$fd"
}

# Build a flat list of allowlisted domains (comments and blanks stripped) for
# fast grep lookups in the self-healing path.
#
# ONE awk, not `grep -v … | grep -v … | sed`. This script runs `set -euo pipefail`,
# and the old pipeline's second grep exits 1 when the file has no non-comment,
# non-blank line — which pipefail propagated and `set -e` turned into a SILENT death
# of the whole daemon, ~150 lines before init_output_files. The effect was severe and
# invisible: the firewall still dropped traffic, but nothing was logged, no
# blocked-domains.txt was written, and self-healing never ran, so dynamic CDN IPs
# behind an allowlisted wildcard stopped being admitted. An empty allowlist is a
# perfectly legal configuration (the proxy-domains file is comments-only whenever no
# proxy-fragment component is enabled), so it must not be fatal. awk exits 0 whether
# or not it prints anything.
strip_allowlist() {   # $1 = source file, $2 = destination cache
  if [[ -f "$1" ]]; then
    awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ {
           gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print
         }' "$1" > "$2"
  else
    : > "$2"
  fi
}

allowed_domains_cache="$internal_dir/allowed-domains-cache"
strip_allowlist "$domains_file" "$allowed_domains_cache"

# Build a list of wildcard domain patterns from the proxy-domains file.
# Each line like "*.example.com" becomes a suffix match so that
# "anything.example.com" or "deep.sub.example.com" is auto-allowed.
# This is the one that actually fired: with every proxy-fragment component OFF the
# generated allowlist-proxy-domains.txt is nothing but its two header comments.
wildcard_patterns_cache="$internal_dir/wildcard-patterns-cache"
strip_allowlist "$proxy_domains_file" "$wildcard_patterns_cache"

# Every write goes to one of these descriptors, opened by open_output(), and
# /dev/null for an output that could not be opened. The two lists' lines from
# earlier sessions are read through their descriptors (which leaves each at its
# end, where the next line is written) into listed[], which deduplicates them.
fd_log="" fd_domains="" fd_ips="" fd_dns_err="" fd_nflog_err=""
declare -A listed=()

read_listed() {   # $1 = descriptor; its lines from the current offset to the end
  local line=""
  while IFS= read -r line <&"$1" || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == '#'* ]] || listed["$line"]=1
  done
}

init_output_files() {
  open_output fd_domains "$blocked_domains" || fd_domains=""
  open_output fd_ips "$blocked_ips" || fd_ips=""
  open_output fd_log "$blocked_log" || fd_log=""
  open_output fd_dns_err "$capture_dir/tshark-dns-errors.log" fresh || fd_dns_err=""
  open_output fd_nflog_err "$capture_dir/tshark-nflog-errors.log" fresh || fd_nflog_err=""
  local f nul
  for f in fd_domains fd_ips fd_log fd_dns_err fd_nflog_err; do
    [[ -z "${!f}" ]] || continue
    exec {nul}<>/dev/null; printf -v "$f" '%s' "$nul"
  done
  # Empty: new, so its header first. Otherwise read to its end.
  if [[ -n "$(_cbt_empty "$fd_domains")" ]]; then
    cat >&"$fd_domains" <<'HEADER'
# Blocked domains — copy-paste these lines into allowlist-domains.txt
# Generated automatically while the container runs in restricted mode.
# Each domain below was attempted but rejected by the outbound firewall.

HEADER
  else read_listed "$fd_domains"; fi
  if [[ -n "$(_cbt_empty "$fd_ips")" ]]; then
    cat >&"$fd_ips" <<'HEADER'
# Blocked IPs with no known domain — copy-paste into allowlist-cidrs.txt
# If you can identify the owning service, prefer adding the domain to allowlist-domains.txt instead.
# Generated automatically while the container runs in restricted mode.

HEADER
  else read_listed "$fd_ips"; fi
  if [[ -n "$(_cbt_empty "$fd_log")" ]]; then
    printf '%-25s  %-10s  %-42s  %s\n' "TIMESTAMP" "PROTO:PORT" "IP" "DOMAIN" >&"$fd_log"
    printf '%s\n' "$(printf '─%.0s' {1..100})" >&"$fd_log"
  else cat <&"$fd_log" >/dev/null; fi
}

# _cbt_empty <fd>: prints something when the regular file open on <fd> is empty.
# /dev/null, for an output not opened, is no regular file and prints nothing.
_cbt_empty() {
  local s
  if (( _cbt_stat_gnu )); then s="$(stat -c '%s:%F' - <&"$1" 2>/dev/null)"
  else s="$(stat -f '%z:%HT' <&"$1" 2>/dev/null)"; fi
  [[ "$s" == 0:[Rr]egular* ]] && printf 'empty'
}

lookup_domain() {   # the first name the map holds for this address, matched as text
  awk -v ip="$1" '$1 == ip { print $2; exit }' "$dns_map" 2>/dev/null || true
}

is_allowlisted_domain() {
  local domain="$1"
  [[ -z "$domain" ]] && return 1
  grep -qxF -- "$domain" "$allowed_domains_cache" 2>/dev/null
}

# resolves_to <name> <address>: does this container's resolver give <address>
# for <name> now? What the map holds came off the wire from anyone; this is the
# answer the refresh loop itself would get (refresh-ipset-allowlist.sh uses
# getent too). A name starting with `-` is no host name and is never asked.
resolves_to() {
  [[ -n "$1" && "$1" != -* ]] || return 1
  getent ahosts "$1" 2>/dev/null | awk -v ip="$2" '$1 == ip { found = 1 } END { exit !found }'
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
    if resolves_to "$domain" "$dst_ip"; then
      auto_allow_ip "$dst_ip"
      printf '%-25s  %-10s  %-42s  %s (auto-allowed)\n' \
        "$timestamp" "$proto:$dst_port" "$dst_ip" "$domain" >&"$fd_log"
    else
      printf '%-25s  %-10s  %-42s  %s (not auto-allowed: the resolver does not give this address for it)\n' \
        "$timestamp" "$proto:$dst_port" "$dst_ip" "$domain" >&"$fd_log"
    fi
    return
  fi

  printf '%-25s  %-10s  %-42s  %s\n' \
    "$timestamp" "$proto:$dst_port" "$dst_ip" "${domain:-(no domain)}" >&"$fd_log"
  local item="${domain:-$dst_ip}"
  if [[ -z "${listed["$item"]:-}" ]]; then
    listed["$item"]=1
    if [[ -n "$domain" ]]; then printf '%s\n' "$domain" >&"$fd_domains"
    else printf '%s\n' "$dst_ip" >&"$fd_ips"; fi
  fi
}

start_dns_map_builder() {
  # Captures DNS responses and builds a live IP → FQDN map.
  #
  # Field separator is "|", NOT tshark's default tab — see start_blocked_watcher
  # below for the full explanation of why tab is unusable with `read` (the
  # same `-E separator=`/IFS pairing is used there). It bites here too: an
  # A-only response leaves dns.aaaa empty,
  # an AAAA-only response leaves dns.a empty, and either shape is exactly the
  # "one field missing" case that a tab/IFS-whitespace read collapses into
  # the wrong variable, silently corrupting the self-healing DNS map.
  (
    tshark -i any -n -l \
      -f "port 53" \
      -Y "dns.flags.response == 1 and (dns.a or dns.aaaa)" \
      -T fields -E "separator=|" -e dns.resp.name -e dns.a -e dns.aaaa \
      2>&"$fd_dns_err" | \
    while IFS='|' read -r raw_name a_list aaaa_list; do
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
  #
  # Field separator is "|", NOT tshark's default tab. Tab is IFS WHITESPACE
  # (with space and newline), and bash's `read` COLLAPSES RUNS of IFS
  # whitespace into a single delimiter and strips it from the line's edges.
  # ipv6.dst is ALWAYS empty for an IPv4 packet (and ip.dst always empty for
  # an IPv6 one), so tshark's real tab-separated output for a blocked IPv4
  # TCP packet is shaped like "172.18.0.2\t\t8080\t" — read with
  # IFS=$'\t' collapses the doubled tab into ONE delimiter and drops the
  # trailing one, yielding dst4=172.18.0.2 dst6=8080 (the PORT, misplaced)
  # tcp_port="" udp_port="". The next line's `[[ -z "$dst" || -z "$port" ]]
  # && continue` then silently discarded EVERY blocked packet, always — this
  # shipped and was only found by tests/integration/cases/040-*.sh asserting
  # a real row, not by any check of whether the daemon merely started. "|"
  # cannot occur in an IP literal, a port number, or a DNS label, so it is
  # not IFS whitespace and empty fields are preserved as empty positions
  # instead of being collapsed away. Do NOT revert this to a tab separator —
  # it looks like a harmless cosmetic choice and is actually load-bearing.
  (
    tshark -i "nflog:$nflog_group" -l -n \
      -T fields -E "separator=|" -e ip.dst -e ipv6.dst -e tcp.dstport -e udp.dstport \
      2>&"$fd_nflog_err" | \
    while IFS='|' read -r dst4 dst6 tcp_port udp_port; do
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
