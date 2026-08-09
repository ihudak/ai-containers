#!/usr/bin/env bash
# summary:  a /workspace name collision is refused before any container starts
# tags:     mounts fast
# requires: docker launcher
#
# Everything lands under one flat /workspace umbrella keyed by BASENAME, so two
# sources can claim the same name: EXTRA_MOUNTS=/tmp/app and REPOS="app:ro" both
# want /workspace/app. Docker resolves that silently — the later -v wins — so
# the agent gets one of them and no indication the other exists. If the loser is
# the :ro repo, a mount the user believes is protected has been replaced by a
# writable directory under the same path.
#
# sandbox.sh refuses instead. This case pins the refusal at the level that
# matters: not "an error was printed" but NOTHING WAS STARTED. A check that
# warned and carried on would satisfy a stderr grep perfectly while leaving the
# ambiguous container running — which is why assert_launcher_refused asserts the
# exit code, the message, AND the absence of the container, and why it takes all
# three to pass.
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
