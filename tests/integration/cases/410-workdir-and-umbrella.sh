#!/usr/bin/env bash
# summary:  the agent shell starts in the selected workdir, and it is writable
# tags:     mounts fast
# requires: docker launcher
#
# Two claims sandbox.sh makes about where an agent lands:
#   with a primary path → /workspace/<basename>, bind-mounted rw
#   with none           → the /workspace umbrella itself, usable
#
# HOW THE CWD IS OBSERVED, and why not the obvious way.
#
# `docker inspect .Config.WorkingDir` is out: that field is the argument we
# passed, and echoing it back proves only that docker stored it.
#
# Reading /proc/1/cwd is out too, though it took a CI run to learn why. PID 1 IS
# the agent shell, but entrypoint.sh reaches it through `capsh --user=`, which
# setuids away from root — and the kernel clears the process's DUMPABLE flag on
# that transition. /proc/1 then becomes root-owned, and reading its `cwd`
# symlink requires CAP_SYS_PTRACE, which Docker's default capability set does
# not include. So the read fails as root AND as the sandbox user, and reports
# '<unreadable>' rather than anything about the working directory.
# (/proc/1/status stays world-readable, which is why lib.sh's pid-1 handover
# check works and this did not.)
#
# What is left is the real thing anyway: a process started in this container
# lands in the working directory, and a RELATIVE write from there arrives at the
# expected place on the host. That is the mechanism docker applies to PID 1 and
# to every exec alike, and it is what a human at the prompt experiences. The
# relative path is the point — an absolute one would prove the mount and say
# nothing about where the shell started.
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

cwd="$(agent_exec "$first" 'pwd' 2>/dev/null | tr -d '\r\n')"
if [[ "$cwd" == "/workspace/myproject" ]]; then
  pass "a shell in the container starts in /workspace/myproject"
else
  fail "a shell in the container starts in /workspace/myproject — got '${cwd:-<nothing>}'"
fi
assert_writable "$first" /workspace/myproject

# Relative, deliberately: this resolves against the working directory, so its
# arrival on the host proves the workdir and the bind mount together.
agent_exec "$first" "printf 'from-the-agent\n' > AGENT_WROTE" >/dev/null 2>&1 || true
assert_host_file_exists "$proj/AGENT_WROTE"
if [[ "$(cat "$proj/AGENT_WROTE" 2>/dev/null)" == "from-the-agent" ]]; then
  pass "a relative write from the working directory lands on the host"
else
  fail "a relative write from the working directory lands on the host — content mismatch"
fi

sandbox_down "$first"

# ── With no primary: the umbrella itself ───────────────────────────────────────
launcher_up open || it_finish

cwd="$(agent_exec "$IT_CID" 'pwd' 2>/dev/null | tr -d '\r\n')"
if [[ "$cwd" == "/workspace" ]]; then
  pass "with no primary, a shell starts in the /workspace umbrella"
else
  fail "with no primary, a shell starts in the /workspace umbrella — got '${cwd:-<nothing>}'"
fi
assert_writable "$IT_CID" /workspace

it_finish
