#!/usr/bin/env bash
# summary:  a comments-only allowlist does not kill the capture daemon
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
#
# THE regression, and the most important case in this suite. capture-blocked-
# traffic.sh runs `set -euo pipefail`, and its allowlist cache was once built
# with `grep -v '^\s*#' F | grep -v '^\s*$' | sed …`. When F has no non-comment,
# non-blank line the SECOND grep exits 1, pipefail propagates it, and set -e
# killed the daemon ~150 lines before init_output_files. Nothing was logged: no
# blocked.log, no blocked-domains.txt, no NFLOG watcher, and — worst — no
# SELF-HEALING, so dynamic CDN IPs behind an allowlisted wildcard silently
# stopped being admitted.
#
# A comments-only allowlist is a LEGAL configuration: the generated
# allowlist-proxy-domains.txt is nothing but its two header comments whenever no
# proxy-fragment component is enabled, which is why this was invisible to anyone
# running with copilot/claude-code ON — they had a populated allowlist. 050
# pins that populated-allowlist shape; this pins the degenerate one that broke.
#
# tests/test-blocked-capture.sh already pins this hermetically with a fake tshark
# and no root. This case is the same property against REAL tshark, REAL NFLOG and
# REAL NET_ADMIN, where a second failure mode could hide.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""     # all three comments-only — the degenerate legal config
# TEMP MUTATION (task-5 demonstration, reverted in the next commit): bind-mount
# the grep|grep pre-fix daemon (tests/integration/fixtures/capture-blocked-
# traffic.prefix.sh — the ORIGINAL incident this case pins, a DIFFERENT bug
# from 040's tab-separator-bug.sh fixture; see each fixture's own header) over
# the fixed one.
bad="$IT_REPO_DIR/tests/integration/fixtures/capture-blocked-traffic.prefix.sh"
sandbox_up restricted "$adir" -v "$bad:/usr/local/bin/capture-blocked-traffic.sh:ro" || it_finish

# Weaker property first, same one 050 checks: did the daemon survive startup at
# all? A comments-only allowlist must not regress even this far.
for f in blocked.log blocked-domains.txt blocked-ips.txt; do
  it_wait 30 docker exec "$IT_CID" test -f "/workspace/.agent-blocked/$f" || true
  assert_file_exists "$IT_CID" "/workspace/.agent-blocked/$f"
done
assert_log_contains "$IT_CID" 'Blocked traffic capture started'

# Sharper property: the files existing only proves the daemon got past
# init_output_files — it says nothing about whether the NFLOG watcher it starts
# a few lines later ever actually attached. That watcher is what self-healing
# depends on, and self-healing is what actually died in the outage while
# enforcement kept working silently. sandbox_wait_capture blocks on tshark's
# own "Capturing on" announcement (NOT on the output files above — see lib.sh's
# IT_SETTLE comment for why that substitution is unsound and must not be made),
# so reaching a pass here proves start_blocked_watcher() itself ran.
if sandbox_wait_capture "$IT_CID"; then
  # Effect, not just liveness: with the watcher demonstrably attached, fire
  # the blocked flow through it and confirm the comments-only allowlist did
  # not ALSO silently disable recording for it. A single fire is enough —
  # see 040's comment for the real bug this once masked (a tab/IFS-whitespace
  # field-separator defect in capture-blocked-traffic.sh that silently
  # discarded every parsed packet, unrelated to this case's own allowlist
  # shape and now fixed). An earlier draft of this case retried `reach` on
  # every poll iteration, chasing that bug under the wrong theory (a
  # tshark-attach race); it is deliberately not restored.
  reach "$IT_CID" "$IT_SIDECAR_IP" || true
  entry_recorded() { blocked_entries "$1" blocked-ips.txt | grep -qxF "$2"; }
  if it_wait 45 entry_recorded "$IT_CID" "$IT_SIDECAR_IP"; then
    pass "blocked-ips.txt records $IT_SIDECAR_IP despite the comments-only allowlist"
  else
    fail "blocked-ips.txt records $IT_SIDECAR_IP despite the comments-only allowlist"
  fi
else
  fail "blocked-ips.txt records $IT_SIDECAR_IP despite the comments-only allowlist"
fi
it_finish
