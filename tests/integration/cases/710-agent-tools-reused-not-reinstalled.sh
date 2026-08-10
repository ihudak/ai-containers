#!/usr/bin/env bash
# summary:  a second container in the same group reuses ~/.ai-tools instead of
#           re-downloading every agent-tier tool
# tags:     packages slow needs-external
# requires: docker launcher netadmin external
# image:    agents
# timeout:  2400
#
# 2400s: TWO launcher_up calls, each internally bounded by IT_SETTLE=900 below
# (same reasoning as case 700). If the first container never gets a working
# `claude`, the case fails and exits immediately after ~1800s (900 + the
# redundant post-wait) — bounded, and the second phase is never reached. The
# path that actually needs the larger budget is the one where reuse itself is
# BROKEN: the first container succeeds in well under 900s (real install time,
# not the ceiling), but the second — meant to be near-instant — instead pays
# its own full cold install, up to its own 900s IT_SETTLE ceiling, plus its
# smaller 120s confirmation wait. ~900 (first) + ~900 (second, broken-reuse
# case) + modest log/grep/assert_runs overhead ≈ 1900-2000s worst case;
# 2400s leaves real margin rather than sitting on the exact estimate.
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
