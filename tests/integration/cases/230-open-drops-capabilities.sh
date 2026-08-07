#!/usr/bin/env bash
# summary:  the open-mode agent shell holds neither NET_ADMIN nor NET_RAW
# tags:     security network-mode open fast
# requires: docker
#
# Open mode is "no firewall", NOT "no isolation" — a distinction worth pinning,
# because the name invites the opposite reading. It gets the same capability drop
# as restricted mode (entrypoint.sh: exec capsh --drop=cap_net_admin,cap_net_raw)
# AND sandbox.sh passes no --cap-add at all, so this asserts both belts: even if
# the drop regressed, the capabilities were never granted to begin with.
#
# Contrast discovery mode, which deliberately KEEPS NET_RAW so the sandbox user
# can run tcpdump — that asymmetry is what this case's demonstrated failure
# exploits (running it against discovery makes cap_net_raw fail, and only that
# one).
#
# Same /proc/1/status rule as 070: a fresh `docker exec` starts from the
# container's capability BOUNDING SET and does not inherit capsh's drops, so
# asking it directly reports capabilities that PID 1 does not actually hold.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up discovery "$adir" -e DISCOVERY_CAPTURE_ENABLED=0 || it_finish

caps="$(pid1_caps "$IT_CID")"
if [[ -n "$caps" ]]; then
  pass "read the agent shell's effective capabilities [$caps]"
else
  fail "read the agent shell's effective capabilities (empty — the assertions below would pass vacuously)"
fi

assert_no_capability "$IT_CID" cap_net_admin
assert_no_capability "$IT_CID" cap_net_raw

it_finish
