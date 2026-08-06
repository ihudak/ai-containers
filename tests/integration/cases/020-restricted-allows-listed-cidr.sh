#!/usr/bin/env bash
# summary:  restricted mode admits a destination listed in allowlist-cidrs
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# The literal-IP branch of refresh-ipset-allowlist.sh (is_ipv4 → ipset add).
# Without this, 010 could pass because NOTHING is reachable — a firewall that
# drops everything is not the product.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""
sandbox_up restricted "$adir" || it_finish
assert_reachable "$IT_CID" "$IT_SIDECAR_IP"
it_finish
