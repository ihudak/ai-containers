#!/usr/bin/env bash
# summary:  the agent shell starts in the selected workdir, and it is writable
# tags:     mounts fast
# requires: docker launcher
#
# Two claims sandbox.sh makes about where an agent lands:
#   with a primary path → /workspace/<basename>, bind-mounted rw
#   with none           → the /workspace umbrella itself, usable
#
# READ /proc/1/cwd, NOT `docker inspect .Config.WorkingDir`. The inspect field is
# the argument we passed; echoing it back proves only that docker stored it. PID
# 1 IS the agent shell (entrypoint.sh execs into it), so its cwd is where a human
# typing at that prompt actually is — which is the claim.
#
# The umbrella half is the one with a real bug behind it. /workspace is an
# in-image directory, not a mount, so it belongs to root until
# chown_workspace_root fixes it; it is deliberately non-recursive, and every
# sub-mount keeps its own ownership. Delete that one call and an agent launched
# with no primary argument cannot create a file in its own working directory.
#
# The host-visibility assertion is what distinguishes a real bind mount from a
# directory that merely exists at the right path inside the container. An
# agent's work landing somewhere the human never sees is the same class of
# silent loss as capture output that never reaches the launch dir (case 430).
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

launcher_prepare || it_finish

proj="$IT_LAUNCH_HOME/myproject"
mkdir -p "$proj"

# ── With a primary host path ───────────────────────────────────────────────────
launcher_up open "$proj" || it_finish
first="$IT_CID"

cwd="$(docker exec "$first" readlink /proc/1/cwd 2>/dev/null)"
if [[ "$cwd" == "/workspace/myproject" ]]; then
  pass "agent shell cwd is /workspace/myproject"
else
  fail "agent shell cwd is /workspace/myproject — got '${cwd:-<unreadable>}'"
fi
assert_writable "$first" /workspace/myproject

agent_exec "$first" "printf 'from-the-agent\n' > /workspace/myproject/AGENT_WROTE" >/dev/null 2>&1 || true
assert_host_file_exists "$proj/AGENT_WROTE"
if [[ "$(cat "$proj/AGENT_WROTE" 2>/dev/null)" == "from-the-agent" ]]; then
  pass "what the agent wrote is visible on the host"
else
  fail "what the agent wrote is visible on the host — content mismatch"
fi

sandbox_down "$first"

# ── With no primary: the umbrella itself ───────────────────────────────────────
launcher_up open || it_finish

cwd="$(docker exec "$IT_CID" readlink /proc/1/cwd 2>/dev/null)"
if [[ "$cwd" == "/workspace" ]]; then
  pass "with no primary, agent shell cwd is the /workspace umbrella"
else
  fail "with no primary, agent shell cwd is the /workspace umbrella — got '${cwd:-<unreadable>}'"
fi
assert_writable "$IT_CID" /workspace

it_finish
