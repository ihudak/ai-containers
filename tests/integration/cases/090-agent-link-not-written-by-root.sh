#!/usr/bin/env bash
# summary:  a link the agent puts in .agent-blocked does not make the root daemon
#           write the firewall's allowlist
# tags:     security network-mode restricted slow
# requires: docker launcher netadmin
#
# Bugs review RT-13. capture-blocked-traffic.sh runs as root for the whole
# session and writes into .agent-blocked, a host directory the agent owns. It
# used to append each blocked address to blocked-ips.txt BY NAME, so the agent
# replaced that file with a link to /tmp/allowlist-cidrs.txt, connected once to
# an address with no name, and root appended the address to the allowlist the
# refresh loop reloads every 60 s: the firewall lifted for any destination the
# agent chose. tests/test-blocked-capture.sh pins the mechanism with fakes; this
# is the real daemon, as root, in the real launch layout.
#
# 192.0.2.1 is RFC 5737 TEST-NET-1 (as in 430): in no allowlist, routable
# nowhere, no DNS name, so it lands in blocked-ips.txt.
#
# `slow`: it waits out one refresh of the allowlist (60 s), then looks at the
# live set, since what matters is what the firewall enforces.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

export ALLOW_IPV6_BYPASS=1

launcher_prepare || it_finish
launcher_up restricted || it_finish
sandbox_wait_capture "$IT_CID" || it_finish

cidrs=/tmp/allowlist-cidrs.txt
before="$(docker exec "$IT_CID" cat "$cidrs" 2>/dev/null)"

# As the agent: the list the daemon writes becomes a link to the allowlist.
if agent_exec "$IT_CID" "ln -sf $cidrs /workspace/.agent-blocked/blocked-ips.txt" \
   && [[ "$(agent_exec "$IT_CID" 'readlink /workspace/.agent-blocked/blocked-ips.txt')" == "$cidrs" ]]; then
  pass "the agent replaced blocked-ips.txt with a link to $cidrs"
else
  fail "SCAFFOLD: the agent could not plant the link"; it_finish
fi

assert_blocked "$IT_CID" 192.0.2.1 80

# The row in blocked.log says the watcher has handled the drop.
logged() { docker exec "$1" grep -q '192\.0\.2\.1' /workspace/.agent-blocked/blocked.log 2>/dev/null; }
retry_logged() { reach "$1" 192.0.2.1 80 >/dev/null 2>&1 || true; logged "$1"; }
if it_wait 60 retry_logged "$IT_CID"; then
  pass "the daemon recorded the drop of 192.0.2.1"
else
  fail "the daemon never recorded the drop of 192.0.2.1"; it_finish
fi

after="$(docker exec "$IT_CID" cat "$cidrs" 2>/dev/null)"
if [[ "$after" == "$before" ]]; then
  pass "$cidrs is unchanged: root did not write through the agent's link"
else
  fail "$cidrs changed under the agent's link — now: $(tr '\n' ' ' <<<"$after")"
fi

# One refresh later (every 60 s), the live set still lacks it. That set is what
# the firewall enforces; a connection attempt would say nothing here, since
# 192.0.2.1 is routable nowhere and fails allowed or not (measured under the
# mutation: the address was in the set and the attempt still failed).
sleep 65
if docker exec "$IT_CID" ipset list allowed_ipv4 2>/dev/null | grep -qxF '192.0.2.1'; then
  fail "192.0.2.1 is in allowed_ipv4 after a refresh"
else
  pass "192.0.2.1 is not in allowed_ipv4 after a refresh"
fi

it_finish
