#!/usr/bin/env bash
# summary:  the launcher's own .ai-containers/ is read-only inside the container; the project around it is not
# tags:     security mounts fast
# requires: docker launcher
#
# The documented launch mounts the whole project read-write (SANDBOX_WORKDIR=..),
# and the project's .ai-containers/ holds what the HOST runs at the next launch:
# sandbox.sh, build.sh, the Dockerfile and entrypoint, sandbox.env, sandbox.conf,
# container.env. Writable from inside, an agent could switch the next launch to
# open mode, add mounts, or run code on the host — and .ai-containers/ is
# gitignored, so `git status` would never show it. sandbox.sh mounts it again,
# :ro, on top of the project. tests/test-launcher-dir-ro.sh checks the ARGUMENTS
# it builds against a fake docker; this checks that the container the agent gets
# actually refuses the write.
#
# The launcher must sit INSIDE the directory it mounts, so this case runs a
# project's working copy of the engine (launcher_engine_in), not the repo's.
#
# Paired, as in case 400: the project's own writable root proves the write path
# works with the same primitive, and the markers prove both mounts exist, so
# "not writable" cannot be "not there" or "/workspace is broken".
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

proj="$(it_scratch)/proj"
launcher_engine_in "$proj" || it_finish
printf 'marker-project\n'  > "$proj/MARKER"
printf 'marker-launcher\n' > "$proj/.ai-containers/MARKER"
# What the next launch reads. A comment only, so it configures nothing here.
printf '# sandbox.env (case 450)\n' > "$proj/.ai-containers/sandbox.env"
before="$(cat "$proj/.ai-containers/sandbox.env")"

# open mode: this case is about mounts; see case 400 for why the mode is not.
launcher_up open "$proj" || it_finish

assert_agent_reads "$IT_CID" /workspace/proj/MARKER               marker-project
assert_agent_reads "$IT_CID" /workspace/proj/.ai-containers/MARKER marker-launcher

assert_writable     "$IT_CID" /workspace/proj
assert_not_writable "$IT_CID" /workspace/proj/.ai-containers

# The threat itself, not just a new file: changing one the next launch reads.
if agent_exec "$IT_CID" 'echo SANDBOX_MODE=open >> /workspace/proj/.ai-containers/sandbox.env' >/dev/null 2>&1
then fail "agent cannot append to .ai-containers/sandbox.env — the append SUCCEEDED"
else pass "agent cannot append to .ai-containers/sandbox.env"; fi
[[ "$(cat "$proj/.ai-containers/sandbox.env")" == "$before" ]] \
  && pass "the host's sandbox.env is unchanged" \
  || fail "the host's sandbox.env is unchanged — it now reads: $(tr '\n' ' ' <"$proj/.ai-containers/sandbox.env")"

it_finish
