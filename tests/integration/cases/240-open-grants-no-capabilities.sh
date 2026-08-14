#!/usr/bin/env bash
# summary:  open mode never GRANTS NET_ADMIN/NET_RAW to the container at all —
#           the second belt, distinct from the agent shell's capsh drop
# tags:     security network-mode open fast
# requires: docker
#
# WHY THIS EXISTS AS A SEPARATE CASE FROM 230.
#
# 230 is named 230-open-drops-capabilities and its header claims to assert "both
# belts": that the agent shell's capabilities are DROPPED, and that sandbox.sh
# "passes no --cap-add at all, so ... the capabilities were never granted to
# begin with". It asserts only the first. Its code launches
# `sandbox_up discovery` — deliberately, and for a good reason: discovery DOES
# add --cap-add=NET_ADMIN --cap-add=NET_RAW, so proving the agent shell holds
# nothing there is strictly stronger than proving it in a mode where nothing was
# ever granted. That strengthening is right and this case does not undo it.
#
# But it left the second belt untested by anything, in either tier. Measured, not
# assumed: deleting sandbox.sh's `[[ "$mode" == "open" ]] && capabilities=()`
# outright — so open-mode containers are launched WITH NET_ADMIN and NET_RAW —
# passes all 45 hermetic tests, and no integration case notices either. 210
# asserts reachability, 220 asserts no capture, and 230 is in discovery mode. The
# only hermetic check that mentions the array (tests/test-open-mode.sh) asserts
# the guarded empty-array EXPANSION idiom, which is a bash-4.3 crash guard, not a
# claim about the array's contents.
#
# THE ASSERTION IS THE MIRROR OF 230's, DELIBERATELY.
#
# 230 reads PID 1 (pid1_caps), because the agent shell's drops are what it cares
# about and a fresh `docker exec` does not inherit them. This case reads a FRESH
# EXEC on purpose — that is precisely what reports the container's capability
# BOUNDING SET, which is the thing --cap-add controls and the thing this case is
# about. The two cases read different sources because they assert different
# properties; neither is a mistake to be "consolidated".
#
# The contrast is observable and was observed: running 230's own mutation against
# discovery mode reports a fresh exec holding cap_net_admin
# (0x00000000a80435fb). Open mode must not.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up open "$adir" || it_finish

# A fresh exec's capabilities: the container's bounding set, NOT the agent
# shell's. Empty output would make every assertion below pass vacuously, which
# is the failure mode 230 guards the same way.
caps="$(docker exec "$IT_CID" capsh --print 2>/dev/null | sed -n 's/^Current: //p')"
if [[ -n "$caps" ]]; then
  pass "read a fresh exec's capabilities [$caps]"
else
  fail "read a fresh exec's capabilities (empty — the assertions below would pass vacuously)"
  it_finish
fi

for cap in cap_net_admin cap_net_raw; do
  if grep -q "$cap" <<<"$caps"; then
    fail "open mode never grants $cap — it is in the container's bounding set [$caps]"
  else
    pass "open mode never grants $cap"
  fi
done

it_finish
