#!/usr/bin/env bash
# summary:  a :ro repo refuses the agent's writes while its :rw sibling accepts them
# tags:     security mounts fast
# requires: docker launcher
#
# REPOS="lib:ro" is a promise: the agent can read that repo and cannot change
# it. Nothing verified the promise. tests/test-docs-path.sh and its siblings
# check the ARGUMENT STRING sandbox.sh builds, against a fake docker — which is
# the right test for "did the launcher decide :ro" and no test at all for "is it
# actually read-only in the container the agent gets".
#
# WHY THE :rw SIBLING IS IN THE SAME CONTAINER, not a separate case: "the write
# to /workspace/lib failed" is satisfied by a container whose /workspace is
# broken outright, by a mount that never happened, and by a typo in the probe
# command. Each of those makes the assertion pass while enforcement is untested.
# A :rw mount proving the write path works, in the same container and with the
# same primitive, is what turns "the write failed" into evidence of enforcement.
# The readable-marker assertions do the same job from the other side: they prove
# the :ro mount EXISTS, so "not writable" cannot be "not there".
#
# BOTH BACKENDS. `auto` resolves a path repo to a bind mount on Linux and to a
# volume on macOS (see sandbox.sh's repo loop), and those are different code
# paths ending in different docker arguments. Testing only the local platform's
# would leave the other one covered by nothing anywhere.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish

repo_register_bind   lib  || it_finish
repo_register_bind   app  || it_finish
repo_register_volume vlib || it_finish
repo_register_volume vapp || it_finish

export REPOS="lib:ro app:rw vlib:ro vapp:rw"

# open mode: this case is about mounts, and the firewall setup plus the capture
# daemon would add ~a minute of settle for nothing. Mounts are mode-independent
# — the repo loop runs before the mode is ever consulted.
launcher_up open || it_finish

# The mounts exist and carry their content.
assert_agent_reads "$IT_CID" /workspace/lib/MARKER  marker-lib
assert_agent_reads "$IT_CID" /workspace/app/MARKER  marker-app
assert_agent_reads "$IT_CID" /workspace/vlib/MARKER marker-vlib
assert_agent_reads "$IT_CID" /workspace/vapp/MARKER marker-vapp

# The promise itself.
assert_not_writable "$IT_CID" /workspace/lib
assert_not_writable "$IT_CID" /workspace/vlib
assert_writable     "$IT_CID" /workspace/app
assert_writable     "$IT_CID" /workspace/vapp

it_finish
