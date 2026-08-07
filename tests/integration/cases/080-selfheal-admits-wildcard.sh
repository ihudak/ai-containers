#!/usr/bin/env bash
# summary:  a blocked IP whose domain matches an allowlisted wildcard is
#           auto-allowed on the spot, without waiting for the 60s refresh
# tags:     security network-mode restricted needs-dns
# requires: docker netadmin sidecar dns
#
# THIS IS THE PROPERTY THAT SILENTLY DIED WITH THE CAPTURE DAEMON. Enforcement
# kept working throughout the original outage, so nothing looked wrong — but
# dynamic CDN IPs behind an allowlisted wildcard (*.githubcopilot.com is the
# real-world case) stopped being admitted, because the code path that admits
# them lives INSIDE the daemon that had died. Two separate bugs have now been
# found in that daemon; this case is what proves the path is alive.
#
# The chain being exercised, end to end:
#   curl -> DNS query (port 53 is unconditionally ACCEPTed by the firewall)
#        -> CoreDNS answers
#        -> the daemon's DNS-map builder sniffs the RESPONSE, records ip -> name
#        -> the connection to that ip is DROPPED and NFLOGged
#        -> log_blocked looks the ip up, matches *.wild.test in the proxy file
#        -> ipset add, immediately -> the retry succeeds
#
# Why a real resolver rather than --add-host: the map is built by sniffing actual
# port-53 RESPONSES. --add-host writes /etc/hosts and produces no DNS traffic at
# all, so the map stays empty, no domain is ever found for the blocked IP, and
# self-healing cannot fire. The case would then pass or fail for reasons entirely
# unrelated to what it claims to test.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fqdn="probe.wild.test"

sidecar_up || it_finish
dns_up "$fqdn" "$IT_SIDECAR_IP" || it_finish
pass "resolver up at $IT_DNS_IP answering $fqdn -> $IT_SIDECAR_IP"

adir="$(it_scratch)"
# Nothing in domains, nothing in cidrs. The ONLY thing that can admit the sidecar
# is the wildcard in the proxy-domains file, matched by the self-healing path —
# so a successful retry below cannot be explained any other way.
allowlist_write "$adir" "" "" "*.wild.test"
bad="$IT_REPO_DIR/tests/integration/fixtures/capture-blocked-traffic.tab-separator-bug.sh"
sandbox_up restricted "$adir" --dns "$IT_DNS_IP" -v "$bad:/usr/local/bin/capture-blocked-traffic.sh:ro" || it_finish

# Self-healing lives in the NFLOG watcher, and tshark takes ~22s to attach.
# Firing traffic before then means the drop is never seen, nothing is looked up,
# and nothing is healed — the case would fail for a timing reason and send
# someone hunting in the product. Waiting on the output FILES is not a
# substitute: init_output_files creates them long before tshark attaches.
sandbox_wait_capture "$IT_CID" || it_finish

# First attempt must be dropped — the ipset cannot contain an address nobody has
# resolved yet — and that drop is what triggers the auto-allow.
reach "$IT_CID" "$fqdn" || true

healed() {
  docker exec "$1" grep -qE "$2.*\(auto-allowed\)" /workspace/.agent-blocked/blocked.log
}
if it_wait 60 healed "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "blocked.log records $IT_SIDECAR_IP as (auto-allowed)"
else
  fail "blocked.log records $IT_SIDECAR_IP as (auto-allowed)"
fi

in_ipset() { docker exec "$1" bash -c 'ipset list allowed_ipv4 2>/dev/null' | grep -qxF "$2"; }
if it_wait 30 in_ipset "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "the address was added to allowed_ipv4 without waiting for the 60s refresh"
else
  fail "the address was added to allowed_ipv4 without waiting for the 60s refresh"
fi

retry_ok() { reach "$1" "$2"; }
if it_wait 30 retry_ok "$IT_CID" "$fqdn"; then
  pass "the retry succeeds — the destination is now reachable"
else
  fail "the retry succeeds — the destination is now reachable"
fi

# A self-healed destination is NOT a hard block. log_blocked returns early after
# the auto-allow and writes the "(auto-allowed)" line to blocked.log ONLY, never
# to blocked-ips.txt or blocked-domains.txt. Conflating the two is the difference
# between "the firewall is innocent" and "the firewall was involved but
# recovered" — a real host verification misread exactly this once.
hard="$(blocked_entries "$IT_CID" blocked-ips.txt)"
case "$hard" in
  *"$IT_SIDECAR_IP"*) fail "a self-healed address must NOT appear in blocked-ips.txt" ;;
  *)                  pass "a self-healed address does not appear in blocked-ips.txt" ;;
esac

it_finish
