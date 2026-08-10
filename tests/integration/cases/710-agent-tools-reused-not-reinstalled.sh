#!/usr/bin/env bash
# summary:  a second container in the same group reuses ~/.ai-tools instead of
#           re-downloading every agent-tier tool
# tags:     packages slow needs-external
# requires: docker launcher netadmin external
# image:    agents
# timeout:  2400
#
# 2400s: TWO launcher_up calls, each internally bounded by IT_SETTLE=900
# below — but the two waits below are not independent 900s risks that stack
# freely (see case 700's header for the full mechanism: the reconcile
# finishes BEFORE PID 1 hands over, so launcher_up succeeding already means
# the install is done, and a genuinely broken/hung reconcile shows up as
# launcher_up itself failing near its own ceiling, not as a slow success).
# Two distinct paths through this case, bounded differently:
#
#   - PHASE 1 NEVER RESOLVES `claude`: `|| { fail; it_finish }` exits right
#     there — bounded at ~900 (launcher_up) + ~900 (the redundant wait, only
#     if launcher_up DID succeed but claude specifically stayed missing) with
#     NO tail after it (the log grep, rm -f, and phase 2 never run). ≤1800s,
#     self-contained.
#   - PHASE 1 SUCCEEDS (the only way to reach phase 2 at all): its own
#     redundant wait resolved near-instantly, because reaching this branch
#     means the condition was already true — so phase 1's real cost is just
#     launcher_up's own completion time, realistically well under its 900s
#     ceiling. Phase 2 then runs the SAME launcher_up(≤900) gate, followed by
#     a SMALLER 120s confirmation wait that — unlike phase 1's — does NOT
#     exit early on failure, so the reuse-log-grep and final assert_runs
#     still run afterward regardless. Bound: ≤900 (phase 1, typically much
#     less) + ~900 (phase 2 launcher_up, only near its ceiling if reuse is
#     genuinely broken and a full reinstall is needed) + ≤120 (phase 2's own
#     wait) + ~10s tail ≈ 1930s.
#
# The second path is the binding one (≈1930s), not the first (≤1800s) —
# 2400s leaves ~470s of real margin over it, not an arithmetic coincidence.
#
# The whole reason ~/.ai-tools is group-mounted rather than baked. If reuse
# breaks, nothing FAILS — every container just pays a full six-tool network
# install at every start, which looks like slowness rather than a bug and would
# never be noticed. Asserting the effect (no install lines the second time)
# rather than the mount configuration is what makes it observable.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# See case 700: run_agent_tools_reconcile runs before entrypoint.sh's exec to
# the sandbox user, so launcher_up's pid-1 wait is gated behind the whole
# install, not just the firewall. Applies to BOTH launcher_up calls below — the
# second is expected to clear it almost immediately, because install_npm/
# install_uv/install_vale each short-circuit on an already-present binary — but
# the ceiling has to cover the first, cold one.
IT_SETTLE=900

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=agentreuse

launcher_up restricted || it_finish
it_wait 900 docker exec "$IT_CID" bash -c "command -v claude >/dev/null" \
  || { fail "first container never finished installing"; it_finish; }
first="$IT_CID"
docker logs "$first" 2>&1 | grep -q 'agent-tools-reconcile' \
  && pass "the first start ran the reconcile" \
  || fail "the first start ran the reconcile"
docker rm -f "$first" >/dev/null 2>&1 || true

launcher_up restricted || it_finish
it_wait 120 docker exec "$IT_CID" bash -c "command -v claude >/dev/null" \
  || fail "the second container did not have the tools available within 120s"

# `npm install -g` prints its added-package summary only when it actually
# installs. agent-tools-reconcile.sh's install_npm calls it with no output
# redirection at all, and entrypoint.sh runs the whole reconcile synchronously
# — no `&`, no `>` — before the exec that hands PID 1 to the sandbox user, so
# its stdout/stderr are still PID 1's own and reach `docker logs` unfiltered.
# Verified by reading both files, not assumed: nothing between npm and the
# container's own stdout redirects it anywhere else. Its absence on the second
# start is the evidence of reuse.
if docker logs "$IT_CID" 2>&1 | grep -qE 'added [0-9]+ package'; then
  fail "the second start RE-INSTALLED — ~/.ai-tools was not reused"
  docker logs "$IT_CID" 2>&1 | grep -E 'added [0-9]+ package' | head -5 | sed 's/^/     /'
else
  pass "the second start reused ~/.ai-tools (no npm install occurred)"
fi
assert_runs "$IT_CID" claude

it_finish
