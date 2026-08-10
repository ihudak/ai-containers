#!/usr/bin/env bash
# summary:  one group's agent credentials are invisible from another group's container
# tags:     security groups fast
# requires: docker launcher
#
# A container group exists so a work agent and a personal agent (or a client's
# and another client's) do not share credentials. `.claude`, `.copilot`,
# `.codex`, `.config/gh` and `.ssh` are mounted from ~/.ai-containers/<group>/,
# and the whole separation is one variable's worth of path construction in
# sandbox.sh. Get it wrong — mount $HOME instead of the group root, resolve the
# group before the override is read — and every agent sees every token, with no
# symptom whatsoever. Nothing is denied, nothing errors, nothing is logged.
#
# BOTH DIRECTIONS, BOTH GROUPS. "Group B cannot see A's secret" is also true when
# .claude is not mounted at all, when the path is misspelled, and when the
# container has no home directory — three ways to pass while proving nothing. So
# each group carries its OWN marker and each container must see exactly one of
# them: the absence only means isolation once the presence has been established
# in the same container.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

launcher_prepare || it_finish
# .claude is only mounted when claude-code is enabled; the minimal conf has it
# off. This is the launcher's own gate, not something the image provides.
launcher_conf claude-code=ON || it_finish

mkdir -p "$IT_LAUNCH_HOME/.ai-containers/ga/.claude" \
         "$IT_LAUNCH_HOME/.ai-containers/gb/.claude"
printf 'token-for-group-a\n' > "$IT_LAUNCH_HOME/.ai-containers/ga/.claude/SECRET"
printf 'token-for-group-b\n' > "$IT_LAUNCH_HOME/.ai-containers/gb/.claude/SECRET"

# ── Group A ────────────────────────────────────────────────────────────────────
export AI_CONTAINER_GROUP=ga
launcher_up open || it_finish
a="$IT_CID"
assert_agent_reads "$a" "$IT_LAUNCH_HOME_IN/.claude/SECRET" token-for-group-a
if agent_exec "$a" "grep -q token-for-group-b '$IT_LAUNCH_HOME_IN/.claude/SECRET'" >/dev/null 2>&1; then
  fail "group A's container cannot see group B's token — IT CAN"
else
  pass "group A's container cannot see group B's token"
fi
sandbox_down "$a"

# ── Group B ────────────────────────────────────────────────────────────────────
export AI_CONTAINER_GROUP=gb
launcher_up open || it_finish
b="$IT_CID"
assert_agent_reads "$b" "$IT_LAUNCH_HOME_IN/.claude/SECRET" token-for-group-b
if agent_exec "$b" "grep -q token-for-group-a '$IT_LAUNCH_HOME_IN/.claude/SECRET'" >/dev/null 2>&1; then
  fail "group B's container cannot see group A's token — IT CAN"
else
  pass "group B's container cannot see group A's token"
fi

# The host tree must be untouched by either container: a group that leaked
# through a shared parent mount would show up as a stray file here.
if [[ "$(cat "$IT_LAUNCH_HOME/.ai-containers/ga/.claude/SECRET")" == "token-for-group-a" ]]; then
  pass "group A's host file is unchanged"
else
  fail "group A's host file is unchanged"
fi

it_finish
