#!/usr/bin/env bash
# summary:  the shell utilities agents reach for are on PATH in the image, and run
# tags:     delivery fast
# requires: docker
#
# The Dockerfile's agent-utilities layer bakes these into EVERY image, with no
# sandbox.conf key, so the default variant is the right one to check and the PR
# gate is the right place: a dropped package fails the next agent turn that
# shells out to it, and the agent cannot repair that — nothing in the container
# can `apt-get`, because entrypoint.sh drops root before the agent shell exists.
#
# assert_runs, not `command -v`: on PATH and EXECUTES are different failures. fd
# is a symlink to Ubuntu's `fdfind`, and a symlink whose target moved stays on
# PATH while every call to it dies. Every tool below answers `--version` with
# exit 0 — xxd too, which folds a leading `--` into `-` before matching `-v`.
#
# `make` is the one this case is most likely to catch. It looks redundant with
# build-essential, which the pyenv layer installs, but the cleanup purge takes
# build-essential's `make` with it — so dropping it from the agent-utilities
# list empties it out of the default image while every other tool still passes.
# That is mutation 310-make-not-installed.
#
# A bare container on `sleep`, not sandbox_up: these binaries are image
# contents, so the entrypoint, the firewall and the agent shell are all beside
# the point, and booting them would only add time and ways to fail first.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

cid="$(docker run -d --label "$IT_LABEL" --entrypoint sleep "$IT_IMAGE" infinity 2>&1)" \
  || { fail "docker run failed: $cid"; it_finish; }
it_track "container:$cid"

for b in rg fd tree file column bc make sqlite3 zstd xxd less; do
  assert_runs "$cid" "$b"
done

it_finish
