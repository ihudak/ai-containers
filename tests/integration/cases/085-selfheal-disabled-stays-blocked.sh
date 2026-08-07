#!/usr/bin/env bash
# summary:  SELF_HEALING_ENABLED=0 logs the drop and leaves it blocked
# tags:     security network-mode restricted needs-dns
# requires: docker netadmin sidecar dns
#
# The same fixture as 080 with ONE env var flipped, and it must stay needs-dns
# for a reason worth stating: without a real resolver the DNS map is empty, no
# domain is ever found for the blocked IP, and SELF_HEALING_ENABLED=0 and =1
# produce byte-identical output. The case would pass while measuring nothing —
# it would be asserting that a disabled feature does nothing, in a configuration
# where the enabled feature also does nothing.
#
# (The plan originally tagged this `fast`; that was corrected once the map's
# dependency on sniffed port-53 responses was traced. A `fast` version of this
# case would have been decorative.)
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fqdn="probe.wild.test"

sidecar_up || it_finish
dns_up "$fqdn" "$IT_SIDECAR_IP" || it_finish

adir="$(it_scratch)"
allowlist_write "$adir" "" "" "*.wild.test"
sandbox_up restricted "$adir" --dns "$IT_DNS_IP" || it_finish

# Prove the switch is actually off before asserting on its consequences. Without
# this, a typo'd env var name would make the case assert "stays blocked" against
# a container where self-healing was never disabled — and pass, because the
# wildcard match would then have healed it and... no, it would fail. But it would
# fail for the wrong reason, which costs a debugging round trip.
assert_log_contains "$IT_CID" 'self-healing: OFF'

sandbox_wait_capture "$IT_CID" || it_finish

reach "$IT_CID" "$fqdn" || true

# With healing off, the drop must be recorded as a HARD block — the domain is
# known (the DNS map was built), so it lands in blocked-domains.txt rather than
# blocked-ips.txt.
recorded() { blocked_entries "$1" blocked-domains.txt | grep -qxF "$2"; }
if it_wait 60 recorded "$IT_CID" "$fqdn"; then
  pass "the drop is recorded in blocked-domains.txt as a HARD block"
else
  fail "the drop is recorded in blocked-domains.txt as a HARD block"
fi

if docker exec "$IT_CID" grep -q '(auto-allowed)' /workspace/.agent-blocked/blocked.log 2>/dev/null; then
  fail "no (auto-allowed) line is written when self-healing is off"
else
  pass "no (auto-allowed) line is written when self-healing is off"
fi

# The property that matters: still blocked. 080 proves the same fixture becomes
# reachable when healing is ON, so this is a genuine differential rather than an
# assertion that an unreachable thing is unreachable.
if reach "$IT_CID" "$fqdn"; then
  fail "the destination stays blocked on retry — it was REACHABLE"
else
  pass "the destination stays blocked on retry"
fi

it_finish
