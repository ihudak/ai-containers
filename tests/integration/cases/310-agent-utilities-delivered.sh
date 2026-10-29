#!/usr/bin/env bash
# summary:  the shell utilities and the node toolchain agents reach for are on PATH in the image, and run
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
# `node`, `npm` and `npx` are not from that layer, but every npm-installed agent
# and qmd runs on them, and they can break the same way: from Node 26 the binary
# needs libatomic.so.1, which only the pyenv layer's build-essential brought in,
# and the cleanup purge took it away, so `node --version` died at exec while
# node was still on PATH. That is mutation 311-libatomic-not-installed.
#
# A bare container on `sleep`, not sandbox_up: these binaries are image
# contents, so the entrypoint, the firewall and the agent shell are all beside
# the point, and booting them would only add time and ways to fail first.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

cid="$(docker run -d --label "$IT_LABEL" --entrypoint sleep "$IT_IMAGE" infinity 2>&1)" \
  || { fail "docker run failed: $cid"; it_finish; }
it_track "container:$cid"

for b in rg fd tree file column bc make sqlite3 zstd xxd less node npm npx; do
  assert_runs "$cid" "$b"
done

# /etc/profile sources /etc/profile.d/*.sh in whatever shell reads it. A
# function named npm-agent-tools is a syntax error to dash, so a POSIX `sh -l`
# stopped there, the rest of /etc/profile unread (bugs review RT-12); bash must
# still define it. That is mutation 312-profile-function-unguarded.
out="$(docker exec "$cid" sh -l -c 'echo sh-login-ok' 2>&1)"
[[ "$out" == sh-login-ok ]] && pass "a POSIX sh login shell starts cleanly" \
  || fail "a POSIX sh login shell: $out"
out="$(docker exec "$cid" bash -l -c 'type -t npm-agent-tools' 2>&1)"
[[ "$out" == function ]] && pass "npm-agent-tools is defined in a bash login shell" \
  || fail "npm-agent-tools in a bash login shell: $out"
# … forwarding its arguments intact (a re-quoted eval dropped them all), and in
# an interactive shell too, from /etc/bash.bashrc.
out="$(docker exec "$cid" bash -l -c 'npm() { printf "[%s]" "$@"; }; npm-agent-tools "a b"' 2>&1)"
[[ "$out" == "[--prefix][/root/.ai-tools/npm][a b]" ]] && pass "npm-agent-tools forwards its arguments intact" \
  || fail "npm-agent-tools arguments: $out"
out="$(docker exec "$cid" bash -i -c 'type -t npm-agent-tools' 2>/dev/null)"
[[ "$out" == function ]] && pass "npm-agent-tools is defined in an interactive bash" \
  || fail "npm-agent-tools in an interactive bash: $out"

it_finish
