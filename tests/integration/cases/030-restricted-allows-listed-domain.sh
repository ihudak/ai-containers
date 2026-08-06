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
# The name resolved AND the resolved address reached the ipset — assert the
# second half explicitly, or a case that fails for a DNS reason reads as a
# firewall pass.
if docker exec "$IT_CID" bash -c 'ipset list allowed_ipv4 2>/dev/null' | grep -qF "$IT_SIDECAR_IP"; then
  pass "the resolved address landed in the allowed_ipv4 ipset"
else
  fail "the resolved address landed in the allowed_ipv4 ipset"
fi
it_finish
