#!/usr/bin/env bash
# summary:  discovery mode applies no drop policy — the allowlist that blocks
#           under restricted does not block here
# tags:     network-mode discovery fast
# requires: docker netadmin sidecar
#
# The differential against 010, which uses this EXACT allowlist (empty: nothing
# allowed) and blocks. Same allowlist, same sidecar, same reach() primitive —
# only the mode differs, so the mode is the only thing that can account for the
# difference in outcome.
#
# Capture is DISABLED here on purpose. Discovery's other half — that it records
# traffic — belongs to 120, and leaving tcpdump running would make this case pay
# for a capture it never inspects. Measure one property at a time.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""          # byte-identical to 010's allowlist
sandbox_up discovery "$adir" -e DISCOVERY_CAPTURE_ENABLED=0 || it_finish

assert_reachable "$IT_CID" "$IT_SIDECAR_IP"

# Record which mode produced that result. Without this line a reader cannot tell
# a genuine discovery-mode pass from a case that accidentally started some other
# mode — the reachability assertion alone looks identical either way.
assert_log_contains "$IT_CID" 'DISCOVERY MODE: outbound network is UNRESTRICTED'

it_finish
