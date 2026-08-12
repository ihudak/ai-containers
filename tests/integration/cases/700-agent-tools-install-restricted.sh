#!/usr/bin/env bash
# summary:  all six agent-tier tools install behind the restricted firewall and
#           resolve for the AGENT, in a non-login shell
# tags:     packages security slow needs-external
# requires: docker launcher netadmin external
# image:    agents
# timeout:  2100
#
# 2100s, not the 300s corpus default — and not the naive 900+900=1800 sum
# either (that number was tried first and rejected on review: it equalled
# this case's own wait budget with NOTHING left for the loops that still run
# afterward, so in exactly the scenario this case exists to diagnose cleanly,
# the OUTER it_timeout could kill it before it_finish, downgrading a named
# assertion failure into an ambiguous "timed out after Ns").
#
# The two waits below are NOT two independent 900s risks stacked on top of
# each other. entrypoint.sh runs the whole agent-tools reconcile BEFORE the
# exec that hands PID 1 to the sandbox user, so by the time launcher_up
# RETURNS SUCCESSFULLY the install has already finished — the realistic
# dominant failure mode is launcher_up itself failing around its own 900s
# IT_SETTLE ceiling (a badly broken/hung reconcile), which exits this case
# via `|| it_finish` at roughly that ceiling, never reaching the second wait
# at all. The narrower case the second wait exists for is different: the
# reconcile genuinely FINISHED (pid 1 flipped, launcher_up succeeded) but one
# specific tool never got installed — nothing installs asynchronously after
# the handover, so that condition is already permanently decided, and
# it_wait has no way to know that; it will poll its own full 900s before
# giving up. That compound case — launcher_up completing near its own
# ceiling AND the specific-tool wait separately exhausting its own — is the
# true (rare, not the expected) upper bound: ~900+900 ≈ 1800s, plus the two
# six-tool loops afterward (12 bounded docker execs total, ~30-40s). 2100s
# gives that bound real margin instead of sitting exactly on it.
#
# THIS IS THE BLOCKING GATE. Nothing agent-tier is baked into the image: Copilot,
# Claude Code, Codex, Gemini, graphify and vale install at container start into a
# group-mounted ~/.ai-tools. So "the image built" says nothing about whether the
# tools exist — the install happens later, over the network, THROUGH the
# restricted firewall, and a missing allowlist fragment breaks it silently.
#
# Non-login, non-root resolution is asserted separately because it has its own
# provider: link-agent-tools.sh symlinks each binary onto /usr/local/bin so
# `docker exec -T … bash -c "claude …"` works. PATH from /etc/profile.d only
# covers login and interactive shells, which is not how an agent is driven. The
# second loop below runs as the AGENT uid (agent_exec), not root: `docker exec`
# defaults to root, and a root-only check does not prove the thing a real
# session needs — the non-root agent shell resolving the tool through the same
# /usr/local/bin symlink. assert_runs above already proves the binary is on
# PATH and executes (as root); this loop is what proves link-agent-tools.sh's
# actual target user can reach it too, which is the assertion the earlier
# version of this comment claimed to make but did not — it ran the identical
# check as root.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# entrypoint.sh runs run_agent_tools_reconcile BEFORE the exec that hands PID 1
# to the sandbox user — the same position run_ruby_reconcile occupies (see case
# 630). launcher_up's own pid-1-handover wait is therefore gated behind the
# ENTIRE six-tool install completing, not just the firewall coming up. The 60s
# network floor was never sized for four npm global installs, a uv tool install
# and a vale download; raised here to the same 900s budget the
# reconcile-completion wait below uses, so launcher_up does not fail-fast for a
# reason that has nothing to do with whether the tools actually installed.
# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=900

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=agenttools
launcher_up restricted || it_finish

# The reconcile is install-if-missing and non-fatal on failure, so poll for the
# binaries rather than for an exit code that is always 0.
it_wait 900 docker exec "$IT_CID" bash -c "command -v claude >/dev/null" \
  || fail "the agent-tools reconcile did not finish within 900s"

for b in claude codex gemini copilot graphify vale; do
  assert_runs "$IT_CID" "$b"
done

# NON-login, NON-interactive, and — the distinct thing assert_runs above does
# NOT prove — as the AGENT, not root: `docker exec` defaults to root, and a
# real session runs as the sandbox user (capsh --user=). agent_exec is the
# shape `docker exec -T … bash -c` produces (see its own comment in lib.sh),
# through the non-root uid link-agent-tools.sh's /usr/local/bin symlinks are
# what make reachable at all — PATH from /etc/profile.d only covers login and
# interactive shells, which this is neither.
for b in claude codex gemini copilot graphify vale; do
  if agent_exec "$IT_CID" "command -v $b >/dev/null 2>&1"; then
    pass "$b resolves for the agent in a non-login shell (link-agent-tools.sh)"
  else
    fail "$b resolves for the agent in a non-login shell — installed but not linked onto /usr/local/bin, or not reachable by uid $IT_LAUNCH_UID"
  fi
done

it_finish
