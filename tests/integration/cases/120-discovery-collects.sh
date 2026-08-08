#!/usr/bin/env bash
# summary:  discovery mode captures traffic to a pcap and extraction lists the
#           destination
# tags:     network-mode discovery slow
# requires: docker netadmin
#
# THE PROBE IS A DNS QUERY, NOT AN HTTP REQUEST, and that is the whole design of
# this case. capture-agent-destinations.sh starts tcpdump with the filter
# 'port 53 or port 443', and extract_capture reads the pcap for dns.qry.name and
# tls.handshake.extensions_server_name. An HTTP request to a sidecar on 8080
# produces a pcap the filter never records; plain HTTP on 443 produces no SNI.
# Either way the case would assert against an empty file and pass or fail for
# reasons unrelated to capture.
#
# A DNS query to a dead address still LEAVES the container, so the packet is
# captured and the name is extractable — entirely offline, no sidecar needed.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

probe_name="it-probe-120.test"
dead_resolver="10.253.0.53"       # nothing listens; only the outbound query matters

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up discovery "$adir" || it_finish     # capture ENABLED (the default)
assert_log_contains "$IT_CID" 'Discovery capture started'

it_wait 30 docker exec "$IT_CID" test -f /workspace/.agent-discovery/agent-traffic.pcap || true
assert_file_exists "$IT_CID" /workspace/.agent-discovery/agent-traffic.pcap

# Fire the probe on every poll rather than once. tcpdump buffers, and the pcap
# only becomes non-empty once a packet is flushed to disk — a single query fired
# before tcpdump is fully attached leaves nothing to retry. Same lesson the
# capture tier learned about tshark's ~22s NFLOG attach: a readiness signal tells
# you a process started, not that it is yet seeing packets.
fire_and_check_pcap() {
  docker exec "$IT_CID" nslookup -timeout=1 -retries=1 "$probe_name" "$dead_resolver" \
    >/dev/null 2>&1 || true
  docker exec "$IT_CID" test -s /workspace/.agent-discovery/agent-traffic.pcap
}
if it_wait 45 fire_and_check_pcap; then
  pass "the pcap is non-empty after outbound traffic"
else
  fail "the pcap is non-empty after outbound traffic"
fi

# Drive the REAL extraction path — the one the README tells users to run —
# rather than reimplementing tshark here. A case that parses the pcap itself
# would keep passing after `stop`/`extract_capture` broke.
docker exec "$IT_CID" /usr/local/bin/capture-agent-destinations.sh \
  stop /workspace/.agent-discovery >/dev/null 2>&1 || true

if docker exec "$IT_CID" grep -qxF "$probe_name" \
     /workspace/.agent-discovery/agent-dns.txt 2>/dev/null; then
  pass "extraction lists the queried destination in agent-dns.txt"
else
  fail "extraction lists the queried destination in agent-dns.txt"
  docker exec "$IT_CID" bash -c \
    'ls -la /workspace/.agent-discovery
     echo "--- agent-dns.txt ---"; cat /workspace/.agent-discovery/agent-dns.txt 2>&1
     echo "--- tcpdump.log ---";   cat /workspace/.agent-discovery/tcpdump.log 2>&1' \
    2>&1 | sed 's/^/     /'
fi

it_finish
