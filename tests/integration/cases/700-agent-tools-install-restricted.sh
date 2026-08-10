#!/usr/bin/env bash
# summary:  all six agent-tier tools install behind the restricted firewall and
#           resolve in a NON-login shell
# tags:     packages security slow needs-external
# requires: docker launcher netadmin external
# image:    agents
#
# THIS IS THE BLOCKING GATE. Nothing agent-tier is baked into the image: Copilot,
# Claude Code, Codex, Gemini, graphify and vale install at container start into a
# group-mounted ~/.ai-tools. So "the image built" says nothing about whether the
# tools exist — the install happens later, over the network, THROUGH the
# restricted firewall, and a missing allowlist fragment breaks it silently.
#
# Non-login resolution is asserted separately because it has its own provider:
# link-agent-tools.sh symlinks each binary onto /usr/local/bin so
# `docker exec -T … bash -c "claude …"` works. PATH from /etc/profile.d only
# covers login and interactive shells, which is not how an agent is driven.
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

# NON-login, NON-interactive: the shape `docker exec -T … bash -c` produces, and
# the one PATH-from-profile does not cover.
for b in claude codex gemini copilot graphify vale; do
  if docker exec "$IT_CID" bash -c "command -v $b >/dev/null 2>&1"; then
    pass "$b resolves in a non-login shell (link-agent-tools.sh)"
  else
    fail "$b resolves in a non-login shell — installed but not linked onto /usr/local/bin"
  fi
done

it_finish
