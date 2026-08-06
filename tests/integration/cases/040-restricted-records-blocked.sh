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

reach "$IT_CID" "$IT_SIDECAR_IP" || true    # generate exactly one blocked flow

# This single fire is exactly what caught the real bug that shipped:
# capture-blocked-traffic.sh's NFLOG read loop used `IFS=$'\t' read`, and tab
# is IFS WHITESPACE — bash's `read` collapses RUNS of it and strips it from
# the line's edges. Every IPv4 packet leaves tshark's ipv6.dst field empty,
# so the real output was shaped like "172.18.0.2\t\t8080\t"; the doubled tab
# collapsed to one delimiter and the trailing one was stripped, landing the
# PORT in the ipv6.dst variable and leaving tcp_port empty, which the next
# line's `[[ -z "$dst" || -z "$port" ]] && continue` then silently discarded
# — every single blocked packet, forever, while the daemon kept announcing
# itself and creating its output files normally. It shipped and was found
# ONLY because this case asserts a real ROW appears, not merely that the
# files exist (that weaker property is exactly what 050 checks, and it
# stayed green throughout). Fixed by using a field separator ("|") that is
# not IFS whitespace; see capture-blocked-traffic.sh for the full comment.
# An earlier draft of this case retried `reach` on every poll iteration to
# compensate — that was chasing the wrong cause (a tshark-attach race) and
# masked this real one by resending until the daemon's parser got lucky on
# some other field shape. It is deliberately not restored: the single fire,
# once past sandbox_wait_capture, is not just sufficient but the point.
entry_recorded() { blocked_entries "$1" blocked-ips.txt | grep -qxF "$2"; }
if it_wait 45 entry_recorded "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "blocked-ips.txt records $IT_SIDECAR_IP as a real entry"
else
  fail "blocked-ips.txt records $IT_SIDECAR_IP as a real entry"
fi

# blocked.log is the authoritative record: log_blocked returns early after
# self-healing an allowlisted domain and writes the "(auto-allowed)" line to
# blocked.log ONLY. Reading just the two copy-paste files therefore reports
# "blocked nothing" for traffic that WAS dropped and then admitted.
logged() { docker exec "$1" grep -qF "$2" /workspace/.agent-blocked/blocked.log; }
if it_wait 20 logged "$IT_CID" "$IT_SIDECAR_IP"; then
  pass "blocked.log records the destination with a timestamp"
else
  fail "blocked.log records the destination with a timestamp"
fi
it_finish
