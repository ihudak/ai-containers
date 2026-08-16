#!/usr/bin/env bash
# summary:  the open-mode agent shell holds neither NET_ADMIN nor NET_RAW
# tags:     security network-mode open fast
# requires: docker
#
# Open mode is "no firewall", NOT "no isolation" — a distinction worth pinning,
# because the name invites the opposite reading. It gets the same capability drop
# as restricted mode (entrypoint.sh: exec capsh --drop=cap_net_admin,cap_net_raw).
#
# THIS CASE ASSERTS ONE BELT, NOT TWO. An earlier version of this comment claimed
# it also asserted that "sandbox.sh passes no --cap-add at all, so the
# capabilities were never granted to begin with". That was wrong twice over, and
# both errors matter:
#
#   1. This case cannot observe sandbox.sh at all. lib.sh's sandbox_up composes
#      its OWN docker run with its own per-mode capability logic (lib.sh:202-203)
#      and never invokes the launcher. What sandbox.sh requests is asserted
#      hermetically instead, in tests/test-mode-capabilities.sh.
#   2. "Never granted" is false for cap_net_raw regardless of mode. Docker's
#      default bounding set includes it (for ping) and sandbox.sh issues no
#      --cap-drop anywhere, so an open-mode CONTAINER holds cap_net_raw whatever
#      that line does. Only cap_net_admin is genuinely never granted.
#
# What this case does assert is the drop, and it asserts it under the strongest
# available conditions — see the discovery-mode note below.
#
# NOTE: discovery mode is NOT a useful contrast here, though it looks like one.
# entrypoint.sh drops only cap_net_admin there and used to claim NET_RAW was
# "kept for tcpdump" — but running this case against discovery mode PASSES, which
# is how that claim was discovered to be false: `capsh --user=` setuids from root
# and the kernel clears the permitted and effective sets on that transition unless
# PR_SET_KEEPCAPS is set (capsh --keep=1, never used). So discovery's agent shell
# holds no capabilities either, and --drop=cap_net_admin is equivalent to dropping
# both. entrypoint.sh and AGENTS.md were corrected; this comment is corrected with
# them. The only known-bad config that makes this case fail is pointing pid1_caps
# at a fresh `docker exec` — see the demonstration in the plan.
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
