#!/usr/bin/env bash
# summary:  a blocked destination is recorded in the HOST launch dir, not just in the container
# tags:     security mounts fast
# requires: docker launcher netadmin
#
# This is the motivating incident's twin, one layer out.
#
# Increment 1 proved the capture daemon starts and writes its three files — by
# reading them with `docker exec` INSIDE the container. Every one of those cases
# stays green if the host bind mount is wrong, missing, or unwritable: the
# daemon runs, the files exist where it looked, and the human staring at
# .agent-blocked/ in their project sees an empty directory. The operator's only
# record of what the firewall dropped, silently going nowhere, is precisely the
# failure this suite was built after.
#
# So this case never looks inside the container. It reads the host filesystem.
#
# 192.0.2.1 is RFC 5737 TEST-NET-1: reserved for documentation, in no allowlist
# fragment, and routable nowhere. That makes it a deterministic blocked
# destination with no sidecar, no DNS and no external dependency — the packet
# leaves, OUTPUT drops it, NFLOG hands it to the watcher.
#
# It is tagged `fast` despite paying tshark's ~22s attach (see lib.sh's
# IT_SETTLE), matching 040. A case whose failure means "you have no idea what
# your agent tried to reach" belongs on the PR gate, not in nightly.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

export ALLOW_IPV6_BYPASS=1   # cosmetic: suppresses the ip6tables banner on hosts without it

launcher_prepare || it_finish
launcher_up restricted || it_finish

blk="$IT_LAUNCH_DIR/.agent-blocked"

# The mount itself, from the host side. If this is not here, nothing below can
# be — and the reason would otherwise look like "the daemon didn't log".
if [[ -d "$blk" ]]; then pass "host launch dir has .agent-blocked/"
else fail "host launch dir has .agent-blocked/ — sandbox.sh did not create or mount it"; it_finish; fi

sandbox_wait_capture "$IT_CID" || it_finish

# Fire at the reserved address. Expected to fail; the point is the record.
assert_blocked "$IT_CID" 192.0.2.1 80

# The watcher writes asynchronously — poll the file rather than sleeping a guess.
host_has_ip() { it_strip_comments < "$blk/blocked-ips.txt" 2>/dev/null | grep -q '192\.0\.2\.1'; }
if it_wait 30 host_has_ip; then
  pass "192.0.2.1 recorded in the HOST blocked-ips.txt"
else
  fail "192.0.2.1 recorded in the HOST blocked-ips.txt"
  printf '     ── host %s ──\n' "$blk"
  ls -la "$blk" 2>&1 | sed 's/^/     /'
  printf '     ── in-container view, for contrast ──\n'
  blocked_entries "$IT_CID" blocked-ips.txt | sed 's/^/     /'
fi

assert_host_file_exists "$blk/blocked.log"
assert_host_readable    "$blk/blocked-ips.txt"

if grep -q '192\.0\.2\.1' "$blk/blocked.log" 2>/dev/null; then
  pass "the full blocked.log on the host names the destination"
else
  fail "the full blocked.log on the host names the destination"
  tail -10 "$blk/blocked.log" 2>&1 | sed 's/^/     /'
fi

# blocked-domains.txt must exist but stay EMPTY of real entries: the address was
# never resolved from a name, so a domain appearing here would mean the daemon
# is inventing correlations — which is how a self-healing rule admits the wrong
# host.
if [[ -f "$blk/blocked-domains.txt" ]]; then
  pass "host blocked-domains.txt exists"
  n="$(it_strip_comments < "$blk/blocked-domains.txt" | grep -c . | tail -1)"
  if [[ "${n:-0}" -eq 0 ]]; then
    pass "no domain invented for an IP that was never resolved"
  else
    fail "no domain invented for an IP that was never resolved — found $n entry/entries"
    it_strip_comments < "$blk/blocked-domains.txt" | sed 's/^/     /'
  fi
else
  fail "host blocked-domains.txt exists"
fi

it_finish
