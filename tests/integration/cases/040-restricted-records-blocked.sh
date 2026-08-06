#!/usr/bin/env bash
# summary:  a blocked attempt is RECORDED as a real (non-comment) entry
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# Enforcement and recording are separate properties, and only enforcement kept
# working during the outage: packets were still dropped, but every record of what
# was dropped was gone. 010 proves the drop; this proves the record.
#
# The "non-comment" qualifier is the whole point. init_output_files seeds each
# output file with explanatory headers, so a plain -s (non-empty) check is true
# on a clean run — which once reported an untouched firewall as HARD-BLOCKED and
# then listed the header lines as if they were blocked destinations.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up restricted "$adir" || it_finish

# Before: the file exists and is non-empty, yet holds no real entries.
before="$(blocked_entries "$IT_CID" blocked-ips.txt)"
[[ -z "$before" ]] \
  && pass "blocked-ips.txt starts with zero real entries (headers are comments)" \
  || fail "blocked-ips.txt starts with zero real entries — got: $before"

# tshark measured ~22s to attach to the NFLOG group in CI (task-0 probe). Until
# it attaches, a blocked packet is dropped by the kernel and recorded by
# nobody. Wait for the watcher's OWN readiness signal, not the existence of
# blocked.log/blocked-domains.txt/blocked-ips.txt — init_output_files() writes
# those long before start_blocked_watcher() ever launches tshark (see lib.sh's
# capture_ready()/sandbox_wait_capture() and the IT_SETTLE comment above them).
# Skipping this wait would make this case race the daemon's own startup:
# passing when the runner happens to be slow enough to cover the gap by luck,
# failing when it is fast — for a reason with nothing to do with the product.
sandbox_wait_capture "$IT_CID" || it_finish

# ── TEMP DEBUG (task-5 root-cause, remove before landing) ──────────────────────
# The retry-fire fix below still saw ZERO captures over 30 retries / ~180s in
# CI run 31111498241 — far past anything a residual attach-race could explain.
# This independent raw tshark listener (decoupled from capture-blocked-
# traffic.sh's own parsing) plus the kernel's own OUTPUT rule counters will
# show whether the NFLOG event is generated at all, isolating "kernel never
# delivers it" from "capture-blocked-traffic.sh's read loop drops it".
docker exec -d "$IT_CID" bash -c \
  'timeout 20 tshark -i nflog:100 -l -n -T fields -e frame.number -e ip.dst -e tcp.dstport -e udp.dstport \
     > /tmp/dbg-raw.txt 2>/tmp/dbg-raw-err.txt'
sleep 2
for _ in 1 2 3 4 5 6 7 8; do reach "$IT_CID" "$IT_SIDECAR_IP" || true; done
sleep 3
printf 'DEBUG iptables -L OUTPUT -v -n:\n'
docker exec "$IT_CID" iptables -L OUTPUT -v -n
printf 'DEBUG /tmp/dbg-raw.txt (independent nflog:100 capture):\n'
docker exec "$IT_CID" cat /tmp/dbg-raw.txt
printf 'DEBUG /tmp/dbg-raw-err.txt:\n'
docker exec "$IT_CID" cat /tmp/dbg-raw-err.txt
printf 'DEBUG /proc/net/netfilter/nfnetlink_log:\n'
docker exec "$IT_CID" bash -c 'cat /proc/net/netfilter/nfnetlink_log 2>&1 || true'
printf 'DEBUG conntrack state / nf_conntrack count:\n'
docker exec "$IT_CID" bash -c 'cat /proc/sys/net/netfilter/nf_conntrack_count 2>&1 || true'
# ── END TEMP DEBUG ──────────────────────────────────────────────────────────────

# A SINGLE `reach` fired the instant sandbox_wait_capture returns is not a
# reliable traffic generator, even though the readiness wait above is
# correct. tshark's "Capturing on" line proves start_blocked_watcher() ran,
# but a real CI run of exactly this case (task-5, 2026-08-06) showed it is not
# a perfectly tight bound: the firewall correctly dropped the one packet
# (ipset stayed at 0 entries — 010 already proves the drop works), yet
# blocked-ips.txt/blocked.log stayed untouched for the full wait below, with
# nothing left to retry because curl had already given up. That is the
# "second failure mode" this tier exists to catch that a hermetic fake-tshark
# test cannot: a hermetic test controls when tshark "arrives"; this one only
# controls when the case ASKS whether it has, and a real capture pipeline can
# still have a residual gap after that answer turns "yes". Keep firing the
# blocked flow on every poll iteration instead of once — this is a test
# robustness fix, not a product bug: 010/020/030 (open/allowed-listed traffic)
# never depend on capture and were unaffected.
fire_and_check_entry() {
  reach "$IT_CID" "$IT_SIDECAR_IP" || true
  blocked_entries "$IT_CID" blocked-ips.txt | grep -qxF "$IT_SIDECAR_IP"
}
if it_wait 30 fire_and_check_entry; then
  pass "blocked-ips.txt records $IT_SIDECAR_IP as a real entry"
else
  fail "blocked-ips.txt records $IT_SIDECAR_IP as a real entry"
fi

# blocked.log is the authoritative record: log_blocked returns early after
# self-healing an allowlisted domain and writes the "(auto-allowed)" line to
# blocked.log ONLY. Reading just the two copy-paste files therefore reports
# "blocked nothing" for traffic that WAS dropped and then admitted. By the
# time the loop above succeeds, blocked.log already has the same entry
# (log_blocked writes it before blocked-ips.txt), so this converges
# immediately in practice; it keeps firing too, for the same reason as above.
fire_and_check_log() {
  reach "$IT_CID" "$IT_SIDECAR_IP" || true
  docker exec "$IT_CID" grep -qF "$IT_SIDECAR_IP" /workspace/.agent-blocked/blocked.log
}
if it_wait 10 fire_and_check_log; then
  pass "blocked.log records the destination with a timestamp"
else
  fail "blocked.log records the destination with a timestamp"
fi
it_finish
