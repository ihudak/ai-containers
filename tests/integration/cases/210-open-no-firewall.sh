#!/usr/bin/env bash
# summary:  open mode applies no firewall — the allowlist that blocks under
#           restricted does not block here
# tags:     network-mode open fast
# requires: docker sidecar
#
# ASSERTED AS AN EFFECT, DELIBERATELY. The obvious version — "iptables -S shows
# policy ACCEPT" — cannot run: sandbox.sh passes an EMPTY capabilities array for
# open mode (no --cap-add at all), so iptables inside the container fails for
# reasons that have nothing to do with what is being tested, and a case that
# fails for an unrelated reason is worse than no case.
#
# The honest assertion is the differential against 010, which uses this EXACT
# allowlist (empty: nothing allowed) and blocks. Same allowlist, same sidecar,
# same reach() primitive — only the mode differs. If both cases pass, the mode is
# the only thing that can account for the difference in outcome.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""          # byte-identical to 010's allowlist
sandbox_up open "$adir" || it_finish

assert_reachable "$IT_CID" "$IT_SIDECAR_IP"

# Anchor the differential in the log too. 000-harness-selftest already proves the
# sidecar is reachable with no firewall in the picture, so a failure here is the
# firewall; this line records which mode produced that result.
assert_log_contains "$IT_CID" 'OPEN MODE: outbound network is UNRESTRICTED'

it_finish
