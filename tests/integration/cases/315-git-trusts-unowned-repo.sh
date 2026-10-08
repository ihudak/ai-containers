#!/usr/bin/env bash
# summary:  git works in a repository whose directory the agent does not own
# tags:     delivery fast
# requires: docker
#
# git refuses a repository another user owns ("detected dubious ownership"),
# and on Colima a host bind's mount root shows as owned by ROOT inside the
# container while the host and the VM show your uid — so git refused every
# command in a host-path primary, and case 465's commit failed only on macOS.
# The image sets safe.directory=* system-wide (Dockerfile).
#
# Reproduced here on any host, not only Colima: root makes a repository, and a
# non-root uid — the agent's position — runs git in it. On Linux nothing else
# in the corpus shows a mount root owned by someone else, so without this case
# CI would pass with the setting gone. Mutation 315-git-safe-directory-dropped
# demonstrates it failing.
#
# A bare container on `sleep`, as in case 310: the setting is image content.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

cid="$(docker run -d --label "$IT_LABEL" --entrypoint sleep "$IT_IMAGE" infinity 2>&1)" \
  || { fail "docker run failed: $cid"; it_finish; }
it_track "container:$cid"

if ! docker exec "$cid" sh -c 'git init -q /tmp/rootrepo && test "$(stat -c %u /tmp/rootrepo)" = 0' >/dev/null 2>&1; then
  fail "could not make a root-owned repository in the container"; it_finish
fi

out="$(docker exec -u 1000:1000 -e HOME=/tmp "$cid" git -C /tmp/rootrepo status --short 2>&1)"
if [[ $? -eq 0 ]]; then
  pass "a non-root uid runs git in a repository root owns"
else
  fail "a non-root uid runs git in a repository root owns ($out)"
fi

it_finish
