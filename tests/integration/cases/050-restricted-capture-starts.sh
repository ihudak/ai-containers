#!/usr/bin/env bash
# summary:  the blocked-traffic capture daemon reaches init_output_files
# tags:     security network-mode restricted fast
# requires: docker netadmin
#
# The existence of the three output files is the cheapest true signal that the
# daemon survived startup. tests/test-entrypoint-wiring.sh asserts the daemon is
# WIRED IN and passed every day of the outage, because the wiring was correct and
# the process died ~150 lines later.
#
# Deliberately weaker than 060: this case does not fire any traffic and does not
# wait for tshark to attach (sandbox_wait_capture) — it only asks whether the
# daemon got past startup at all, with a normal, populated allowlist (the shape a
# real user runs). 060 asks the sharper question — does the watcher stay LIVE —
# against the degenerate comments-only config that actually broke it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
# A populated, ordinary configuration — the shape a real user runs.
allowlist_write "$adir" "example.test other.test" "10.250.0.0/24" "*.proxy.test"
sandbox_up restricted "$adir" || it_finish

for f in blocked.log blocked-domains.txt blocked-ips.txt; do
  it_wait 30 docker exec "$IT_CID" test -f "/workspace/.agent-blocked/$f" || true
  assert_file_exists "$IT_CID" "/workspace/.agent-blocked/$f"
done
assert_log_contains "$IT_CID" 'Blocked traffic capture started'

# Restricted mode's own banner. 110/210/220 assert the discovery and open banners
# by content; restricted had only tests/test-entrypoint-wiring.sh's structural
# check that SOME boxed banner exists in its branch — which would still pass if
# the text were swapped for another mode's. This is the mode whose banner carries
# the DNS-tunnelling caveat, so wrong text here misinforms about a real limit.
assert_log_contains "$IT_CID" 'DNS \(port 53\) is unrestricted'
assert_log_contains "$IT_CID" 'self-healing: ON'
it_finish
