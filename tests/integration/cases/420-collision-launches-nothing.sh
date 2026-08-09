#!/usr/bin/env bash
# summary:  a /workspace name collision is refused before any container starts
# tags:     mounts fast
# requires: docker launcher
#
# Everything lands under one flat /workspace umbrella keyed by BASENAME, so two
# sources can claim the same name: EXTRA_MOUNTS=/tmp/app and REPOS="app:ro" both
# want /workspace/app.
#
# WHAT THE CHECK IS ACTUALLY FOR — corrected by running the mutation, and worth
# stating because the first version of this comment had it wrong. Docker does
# NOT silently let the later -v win: it refuses outright with
# `Duplicate mount point: /workspace/app`, exit 125. So the collision check is
# not what stands between the user and a silently shadowed :ro mount.
#
# It is what stands between the user and that message. `Duplicate mount point`
# names a path and nothing else — not which two settings collided, not that
# REPOS and EXTRA_MOUNTS are keyed by basename, not what to change. sandbox.sh
# refuses first and says "name 'app' is used by both EXTRA_MOUNTS and REPOS".
# That is the assertion below that carries the weight, and losing it is a silent
# regression in exactly the sense this suite cares about: nothing breaks, the
# launch still fails, and the person reading the error has to go and find out
# what the launcher already knew.
#
# The exit-code and no-container assertions are kept as guards on WHEN the
# refusal happens — before docker is invoked — and they are honest about being
# satisfiable by docker's own refusal too. Demonstrated with
# mutations/420-collision-not-refused.patch: with both the message and the exit
# removed, those two still pass and the message assertion is the one that fails.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
repo_register_bind app || it_finish

# A second, unrelated directory whose BASENAME is also "app".
clash="$IT_LAUNCH_HOME/elsewhere/app"
mkdir -p "$clash"

export REPOS="app:ro"
export EXTRA_MOUNTS="$clash"

launcher_run open || it_finish
assert_launcher_refused "name 'app' is used by both"

it_finish
