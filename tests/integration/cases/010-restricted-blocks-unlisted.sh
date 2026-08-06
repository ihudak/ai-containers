#!/usr/bin/env bash
# summary:  restricted mode drops a destination absent from the allowlist
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# The most basic promise the product makes. Deliberately offline: the sidecar is
# a container on a private network, so "blocked" is a decision this firewall made
# and not a property of the internet.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""   # TEMP known-bad: sidecar allowlisted
sandbox_up restricted "$adir" || it_finish
assert_blocked "$IT_CID" "$IT_SIDECAR_IP"
it_finish
