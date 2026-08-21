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
#     there — bounded at ~900 (launcher_up) + ~10 (the redundant wait, only
#     if launcher_up DID succeed but claude specifically stayed missing) with
#     NO tail after it (the mtime check, rm -f, and phase 2 never run).
#     ≤910s, self-contained. That second term was 900 until backlog F57: this
#     header already called the wait REDUNDANT and still budgeted a full
#     ceiling for it, on a condition it says is decided before the wait runs.
#   - PHASE 1 SUCCEEDS (the only way to reach phase 2 at all): its own
#     redundant wait resolved near-instantly, because reaching this branch
#     means the condition was already true — so phase 1's real cost is just
#     launcher_up's own completion time, realistically well under its 900s
#     ceiling. Phase 2 then runs the SAME launcher_up(≤900) gate, followed by
#     a SMALLER 120s confirmation wait that — unlike phase 1's — does NOT
#     exit early on failure, so the reuse-mtime-check and final assert_runs
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
# never be noticed. Asserting the effect (the installed binary's own mtime,
# not the mount configuration) is what makes it observable — see the mtime_of
# comment below for why that specific signal replaced an earlier log-grep one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# See case 700: run_agent_tools_reconcile runs before entrypoint.sh's exec to
# the sandbox user, so launcher_up's pid-1 wait is gated behind the whole
# install, not just the firewall. Applies to BOTH launcher_up calls below — the
# second is expected to clear it almost immediately, because install_npm/
# install_uv/install_vale each short-circuit on an already-present binary — but
# the ceiling has to cover the first, cold one.
# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=900

# The evidence is the NPM-INSTALLED BINARY'S MTIME, not a log grep — this case
# shipped first with `docker logs "$first" | grep -q 'agent-tools-reconcile'`
# for "the first start ran the reconcile" and `docker logs | grep -qE 'added
# [0-9]+ package'` for "the second did not reinstall". Task 14a's baseline CI
# run showed the FIRST of those two FAIL while `claude --version` still ran
# correctly moments later in the SAME (first) container — a combination the
# code as read cannot produce cleanly: agent-tools-reconcile.sh's log()
# wraps every branch (install / already-present / FAILED / unknown-tool) and
# unconditionally logs "done." as its last line, so a reconcile that actually
# executed cannot leave `docker logs` with zero matching lines; but claude
# only ever reaches /usr/local/bin (or resolves at all) via that same
# reconcile + link_agent_tools.sh, which both gate on the identical
# AI_RUNTIME_TOOLS check. Root cause NOT conclusively established — there is
# no Docker daemon available to reproduce this, and the two observations
# contradict each other under a straight reading of entrypoint.sh /
# agent-tools-reconcile.sh. See the task report for the full trace of what
# was and was not ruled out (AI_RUNTIME_TOOLS wiring, the docker-shim, mount
# scoping via the launcher's own per-case scratch $HOME — all checked and
# found correct).
#
# Whatever the mechanism, grepping free-text stdout for a phrase is the wrong
# primitive to hang this case's two central claims on, npm-version-dependent
# wording ("added N packages" is not guaranteed stable) included — this is
# the SAME lesson case 760's header already draws for ruby (a real reinstall
# there can print neither of two plausible greppable patterns, for its own
# reason). An mtime is not: absent before the case runs and present after
# launch 1 is direct proof an install happened (nothing else can have created
# it — group `agentreuse`'s directory lives under THIS case's own fresh
# per-invocation scratch $HOME, so it does not exist until this case creates
# it); unchanged after launch 2 is direct proof of reuse; changed is direct
# proof of a genuine reinstall. All three readings hold regardless of how much
# of the reconcile's own stdout `docker logs` happened to capture.
claude_bin="$IT_LAUNCH_HOME_IN/.ai-tools/npm/bin/claude"
# No `-L`: an npm global install SYMLINKS bin/claude into lib/node_modules/...,
# and a real (re)install recreates that symlink even when the target package
# content is byte-identical — so the SYMLINK's own mtime, not its target's, is
# the thing that moves exactly when npm actually touches this path.
mtime_of() { docker exec "$1" bash -c "stat -c %Y '$claude_bin' 2>/dev/null"; }

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=agentreuse

launcher_up restricted || it_finish
# 10s, not 900: the reconcile completes inside entrypoint, before the handover
# launcher_up waits for, so this condition is already decided. See 700's note
# and backlog F57.
it_wait 10 docker exec "$IT_CID" bash -c "command -v claude >/dev/null" \
  || { fail "first container: claude absent after the reconcile completed"; it_finish; }
first="$IT_CID"

first_mtime="$(mtime_of "$first")"
if [[ -z "$first_mtime" ]]; then
  fail "claude is on PATH but the npm-installed binary is missing: $claude_bin"
  it_diagnose "$first"
  it_finish
fi
pass "the first start installed claude into ~/.ai-tools ($claude_bin)"
docker rm -f "$first" >/dev/null 2>&1 || true

launcher_up restricted || it_finish
it_wait 120 docker exec "$IT_CID" bash -c "command -v claude >/dev/null" \
  || fail "the second container did not have the tools available within 120s"

second_mtime="$(mtime_of "$IT_CID")"
if [[ -z "$second_mtime" ]]; then
  fail "claude is on PATH but the npm-installed binary is missing after the second launch: $claude_bin"
  it_diagnose "$IT_CID"
elif [[ "$second_mtime" == "$first_mtime" ]]; then
  pass "the second start reused ~/.ai-tools (mtime unchanged: $first_mtime)"
else
  fail "the second start RE-INSTALLED claude — ~/.ai-tools was not reused (mtime $first_mtime -> $second_mtime)"
fi
assert_runs "$IT_CID" claude

it_finish
