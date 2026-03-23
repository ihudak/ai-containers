#!/usr/bin/env bash
set -euo pipefail

mode="${DEV_CONTAINER_MODE:-restricted}"
domains_file="${ALLOWLIST_DOMAINS_FILE:-/tmp/allowlist-domains.txt}"
cidrs_file="${ALLOWLIST_CIDRS_FILE:-/tmp/allowlist-cidrs.txt}"
ipv4_set_name="${ALLOWLIST_IPV4_SET:-allowed_ipv4}"
ipv6_set_name="${ALLOWLIST_IPV6_SET:-allowed_ipv6}"
capture_dir="${DISCOVERY_CAPTURE_DIR:-/workspace/.copilot-discovery}"
capture_enabled="${DISCOVERY_CAPTURE_ENABLED:-1}"

apply_restricted_firewall() {
  /usr/local/bin/refresh-ipset-allowlist.sh \
    "$domains_file" \
    "$cidrs_file" \
    "$ipv4_set_name" \
    "$ipv6_set_name"

  iptables -F OUTPUT
  iptables -P OUTPUT DROP
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  iptables -A OUTPUT -m set --match-set "$ipv4_set_name" dst -j ACCEPT

  ip6tables -F OUTPUT
  ip6tables -P OUTPUT DROP
  ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
  ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  ip6tables -A OUTPUT -m set --match-set "$ipv6_set_name" dst -j ACCEPT

  (
    while sleep 300; do
      /usr/local/bin/refresh-ipset-allowlist.sh \
        "$domains_file" \
        "$cidrs_file" \
        "$ipv4_set_name" \
        "$ipv6_set_name"
    done
  ) &
}

apply_discovery_firewall() {
  iptables -F OUTPUT
  iptables -P OUTPUT ACCEPT

  ip6tables -F OUTPUT
  ip6tables -P OUTPUT ACCEPT

  if [[ "$capture_enabled" == "1" ]]; then
    /usr/local/bin/capture-copilot-destinations.sh start "$capture_dir"
    printf 'Discovery capture started in %s\n' "$capture_dir"
    printf 'Use capture-copilot-destinations.sh stop %s before exiting to extract DNS and TLS hostname lists.\n' "$capture_dir"
  fi
}

case "$mode" in
  restricted)
    apply_restricted_firewall
    ;;
  discovery)
    apply_discovery_firewall
    ;;
  *)
    printf 'Unsupported DEV_CONTAINER_MODE: %s\n' "$mode" >&2
    exit 1
    ;;
esac

exec bash
