#!/usr/bin/env bash
# summary:  nvm can still switch Node versions once ~/.ai-tools holds the
#           agent-tier npm packages
# tags:     packages slow needs-external
# requires: docker launcher netadmin external
# image:    agents
# timeout:  2000
#
# 2000s. Same launcher_up(≤900) shape as case 700, and the same non-additive
# reasoning applies: the reconcile finishes BEFORE PID 1 hands over, so a
# genuinely broken/hung install shows up as launcher_up itself failing near
# its own 900s ceiling — the dominant, realistic worst case is ~900+tail, not
# 900+900. The narrower compound case (reconcile genuinely finished, but
# `claude` specifically stayed missing) is what the redundant it_wait below
# can still spend its own full 900s on, since that condition is already
# fixed by then and nothing makes it_wait give up early. Unlike case 700
# (which still runs a tail after either outcome) and unlike 710's phase 1
# (which exits immediately on this wait's failure), THIS case also does not
# exit early (`|| fail`, not `|| { fail; it_finish; }`) — it falls through
# into the nvm-use loop and the npmrc check regardless. True bound:
# ~900 (launcher_up) + ~900 (compound case, redundant wait) + ~10s (three
# single, non-polling agent_exec calls) ≈ 1810s. 2000s leaves ~190s of real
# margin over that, not over the smaller "typical" case.
#
# The slow tag follows from that budget, and was missing while every other
# packages case carried it: this case pays the same cold six-tool agent-tier
# install case 700 does, so `--exclude slow` — the natural local narrowing —
# has to drop it too, or the one flag a developer reaches for to keep a local
# run short still admits a ~30-minute case.
#
# The regression this exists for shipped: /etc/skel/.npmrc carried
# `prefix=${HOME}/.ai-tools/npm`, and nvm's nvm_die_on_prefix check FAILS
# `nvm use <version>` outright rather than warning — so the multi-version
# node=22,20 workflow sandbox.conf advertises was broken by the agent-tier tool
# home. The fix passes --prefix per invocation instead, because nvm inspects
# .npmrc/$PREFIX/$NPM_CONFIG_PREFIX and never a command's own flags.
#
# Needs a SECOND version to switch to, which is why the agents variant sets
# node=22,20. With only the LTS installed this case would pass against a
# one-element list.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# See case 700's comment: run_agent_tools_reconcile runs before entrypoint.sh's
# exec to the sandbox user, so the pid-1 wait is gated behind the whole install.
# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=900

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=nodemulti
launcher_up restricted || it_finish
it_wait 900 docker exec "$IT_CID" bash -c "command -v claude >/dev/null" \
  || fail "the agent-tools reconcile did not finish within 900s"

# Source nvm.sh directly rather than /etc/bash.bashrc. Ubuntu's stock
# /etc/bash.bashrc — unmodified by this Dockerfile apart from the exports it
# appends to the END of the file — opens with `[ -z "$PS1" ] && return` (a real
# line, checked against the file, not assumed). agent_exec always runs a
# NON-interactive `bash -c`, which has no PS1, so sourcing /etc/bash.bashrc
# there returns at that guard before ever reaching the NVM_DIR export appended
# after it — `nvm use` would then fail with "command not found" regardless of
# whether the defect under test is present, which is exactly the kind of
# harness-caused failure this suite exists to not produce. nvm.sh itself
# carries no such guard — sourcing it from a non-interactive shell is its
# whole reason to exist (every CI system that uses nvm relies on this) — so it
# is the direct, unambiguous way to reach it here. NVM_DIR is a plain
# Dockerfile ENV (baked into the image config, so every `docker exec` sees it
# regardless of -u); the ${NVM_DIR:-/opt/nvm} fallback just mirrors the
# defensive style entrypoint.sh itself uses for SANDBOX_USER etc.
for v in 20 22; do
  if out="$(agent_exec "$IT_CID" 'source "${NVM_DIR:-/opt/nvm}/nvm.sh" >/dev/null 2>&1; nvm use '"$v"' 2>&1')"; then
    pass "nvm use $v succeeds with ~/.ai-tools populated: $(printf '%s\n' "$out" | tail -1)"
  else
    fail "nvm use $v FAILED — a baked npm prefix breaks nvm outright, it does not warn"
    printf '%s\n' "$out" | tail -5 | sed 's/^/     /'
  fi
done

# The mechanism, asserted directly: no npm prefix may be set anywhere nvm looks.
# $IT_LAUNCH_HOME_IN, not a bare $HOME inside the exec'd shell: agent_exec runs
# `docker exec -u <uid>:<gid>` with a NUMERIC id, and this suite does not rely
# on Docker resolving $HOME from /etc/passwd for that form (case 630 took the
# same position for the rvm mount path, for the same reason) — the known,
# lib.sh-derived path is unambiguous either way.
# shellcheck disable=SC2088  # descriptive message text, not a path — the real path uses $IT_LAUNCH_HOME_IN above
if agent_exec "$IT_CID" "test -f '$IT_LAUNCH_HOME_IN/.npmrc' && grep -q '^prefix=' '$IT_LAUNCH_HOME_IN/.npmrc'"; then
  fail "~/.npmrc sets a prefix — this is exactly what trips nvm_die_on_prefix"
else
  # shellcheck disable=SC2088  # descriptive message text, not a path
  pass "~/.npmrc sets no prefix"
fi

it_finish
