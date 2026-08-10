#!/usr/bin/env bash
# summary:  all six agent-tier tools install behind the restricted firewall and
#           resolve for the AGENT, in a non-login shell
# tags:     packages security slow needs-external
# requires: docker launcher netadmin external
# image:    agents
# timeout:  1800
#
# 1800s, not the 300s corpus default: launcher_up's own readiness wait is
# bounded by IT_SETTLE=900 below. If the reconcile script itself finishes
# (pid 1 flips) but ONE tool specifically failed to install — the exact
# failure this case exists to catch, e.g. a missing allowlist fragment for
# just @anthropic-ai/claude-code — the redundant post-launcher_up it_wait
# below re-polls the same now-permanently-false condition for its own full
# 900s before reporting it (nothing installs asynchronously after PID 1
# hands over; see the comment on that wait). 900+900 is the real worst case
# a correct run can hit; the two six-tool loops add well under a minute.
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
