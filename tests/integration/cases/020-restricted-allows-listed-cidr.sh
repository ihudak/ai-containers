#!/usr/bin/env bash
# summary:  restricted mode admits a destination listed in allowlist-cidrs
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# The literal-IP branch of refresh-ipset-allowlist.sh (is_ipv4 → ipset add).
# Without this, 010 could pass because NOTHING is reachable — a firewall that
# drops everything is not the product.
#
# WHAT THIS CASE DOES NOT COVER, despite its name. It allowlists a bare host IP,
# not a CIDR RANGE — refresh-ipset-allowlist.sh's is_ipv4 and is_ipv4_cidr are
# separate branches and only the first is exercised here. Also untested by this
# trio: IPv6 admission and blocking (every case sets ALLOW_IPV6_BYPASS=1), the
# 60-second background refresh loop (only the synchronous startup call runs), and
# the cidrs-file invalid-entry error path. A reader scanning "restricted-mode
# reachability" could reasonably assume all of those are covered; they are not.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""
sandbox_up restricted "$adir" || it_finish
assert_reachable "$IT_CID" "$IT_SIDECAR_IP"
it_finish
