#!/usr/bin/env bash
# summary:  the restricted-mode agent shell holds neither NET_ADMIN nor NET_RAW
# tags:     security network-mode restricted fast
# requires: docker netadmin
#
# EVERY OTHER SECURITY CASE IN THIS SUITE DEPENDS ON THIS ONE. The container is
# STARTED with both capabilities — apply_restricted_firewall needs NET_ADMIN to
# build the ipset and the iptables chain, and capture-blocked-traffic.sh needs
# NET_RAW for tshark — and entrypoint.sh drops them from the agent shell with
# `exec capsh --drop=cap_net_admin,cap_net_raw`. Without that drop an agent runs
# `iptables -F OUTPUT` and the entire allowlist is decorative: 010's "blocked"
# would still pass while meaning nothing, because the agent could lift the block
# whenever it liked.
#
# READ /proc/1/status, NEVER A FRESH `docker exec`. This is the whole reason
# pid1_caps exists in lib.sh rather than being inlined here. `docker exec` starts
# a NEW process from the container's capability BOUNDING SET; it does not inherit
# the drops that `exec capsh` applied to PID 1. So `docker exec … capsh --print`
# reports NET_ADMIN present in a container that dropped it perfectly — this case
# would be permanently, invisibly green, which is exactly the class of failure
# the whole suite exists to eliminate. PID 1 IS the agent shell (entrypoint.sh
# execs into it), so its /proc entry is the authoritative answer.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up restricted "$adir" || it_finish

# Read it once and assert we got something: an empty capability string would make
# both assertions below pass vacuously (a substring search in "" never matches),
# turning this case into a decoration. That failure mode is quiet, so name it.
caps="$(pid1_caps "$IT_CID")"
if [[ -n "$caps" ]]; then
  pass "read the agent shell's effective capabilities [$caps]"
else
  fail "read the agent shell's effective capabilities (empty — the assertions below would pass vacuously)"
fi

assert_no_capability "$IT_CID" cap_net_admin
assert_no_capability "$IT_CID" cap_net_raw

# The bit and the EFFECT are different claims. A capability can be absent from
# CapEff while some other path still lets the user change the ruleset (a setuid
# helper, a stray sudo rule). Assert the thing that actually matters: the sandbox
# user cannot lift the firewall. -u 1000:1000 is the sandbox UID/GID sandbox_up
# passes; running this as root would prove nothing.
if docker exec -u 1000:1000 "$IT_CID" iptables -P OUTPUT ACCEPT >/dev/null 2>&1; then
  fail "the sandbox user cannot flush the firewall — the command SUCCEEDED"
else
  pass "the sandbox user cannot flush the firewall"
fi

it_finish
