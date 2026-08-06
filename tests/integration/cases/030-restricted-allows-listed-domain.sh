#!/usr/bin/env bash
# summary:  restricted mode admits a listed DOMAIN, exercising the getent path
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# Not a duplicate of 020: refresh-ipset-allowlist.sh has two branches, and the
# allowlist is overwhelmingly domains. --add-host puts the name in /etc/hosts,
# which `getent ahostsv4` resolves through nsswitch exactly as it would DNS, so
# this drives the resolve-then-ipset-add path with no resolver in the picture.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "it-sidecar.test" "" ""
sandbox_up restricted "$adir" --add-host "it-sidecar.test:$IT_SIDECAR_IP" || it_finish
assert_reachable "$IT_CID" "it-sidecar.test"
# This is a MECHANISM check, not a second independent property: in
# entrypoint.sh's restricted-mode OUTPUT chain, the ipset match-set rule is
# the ONLY ACCEPT rule that can admit a fresh outbound SYN to a destination
# that is neither loopback nor port 53 — so assert_reachable succeeding
# above already logically implies the resolved address is in the ipset.
# What this earns on PASS is confirmation of WHICH mechanism admitted the
# traffic (the ipset, not some other rule); what it earns on FAIL is the
# ability to tell a curl-side resolution failure apart from an actual
# firewall block — both of which would otherwise just read as
# assert_reachable failing, for reasons a human then has to re-diagnose.
if docker exec "$IT_CID" bash -c 'ipset list allowed_ipv4 2>/dev/null' | grep -qxF "$IT_SIDECAR_IP"; then
  pass "the resolved address landed in the allowed_ipv4 ipset"
else
  fail "the resolved address landed in the allowed_ipv4 ipset"
fi
it_finish
