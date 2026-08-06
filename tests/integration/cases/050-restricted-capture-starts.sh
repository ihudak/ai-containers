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
# TEMP MUTATION (task-5 demonstration, reverted in the next commit): bind-mount
# the SAME grep|grep pre-fix daemon that 060 uses
# (capture-blocked-traffic.prefix.sh), paired here with a POPULATED allowlist
# instead of 060's comments-only one. This is the asymmetry that let the
# original incident survive for months: one daemon binary, two allowlists —
# with a populated one (this case) it starts, announces itself, and writes
# its files completely normally; with a comments-only one (060) it dies under
# `set -e` before init_output_files ever runs. Only the allowlist differs
# between this case and 060; expect this one to still PASS.
bad="$IT_REPO_DIR/tests/integration/fixtures/capture-blocked-traffic.prefix.sh"
sandbox_up restricted "$adir" -v "$bad:/usr/local/bin/capture-blocked-traffic.sh:ro" || it_finish

for f in blocked.log blocked-domains.txt blocked-ips.txt; do
  it_wait 30 docker exec "$IT_CID" test -f "/workspace/.agent-blocked/$f" || true
  assert_file_exists "$IT_CID" "/workspace/.agent-blocked/$f"
done
assert_log_contains "$IT_CID" 'Blocked traffic capture started'
assert_log_contains "$IT_CID" 'self-healing: ON'
it_finish
