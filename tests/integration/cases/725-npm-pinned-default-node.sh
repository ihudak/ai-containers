#!/usr/bin/env bash
# summary:  npm= replaces the default Node's npm at build time, and a Node from
#           node= keeps the npm it ships with
# tags:     packages slow
# requires: docker
# image:    agents
#
# The agents variant sets npm=$IT_NPM_VERSION (11.6.2): OLDER than the npm the
# default Node ships (Node 26 bundles 11.20.0), so as bundled npm moves forward a
# layer that did nothing can never report the pinned version by accident, and
# one npm 11 still supports on every Node the variant has.
#
# Two assertions. The first is the key working. The second is its boundary: only
# the default Node gets the npm, because a newer npm may refuse an older Node
# (npm 12 needs Node 22 or later). It first proves `nvm use 20` switched, or a
# default-Node shell would pass it vacuously.
#
# A bare container on `sleep`, as case 310 runs: npm is image content, so the
# entrypoint, the firewall and the agent-tier install are beside the point.
#
# Mutation 725-npm-arg-not-passed drops the pinned build arg in build.sh, so the
# layer is skipped and the image builds with the bundled npm: the first assertion
# fails and the second still passes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

cid="$(docker run -d --label "$IT_LABEL" --entrypoint sleep "$IT_IMAGE" infinity 2>&1)" \
  || { fail "docker run failed: $cid"; it_finish; }
it_track "container:$cid"

want="${IT_NPM_VERSION:-11.6.2}"

# The default Node's npm, as a plain non-interactive command finds it: the Node
# layer links /usr/local/bin/npm into the default Node.
out="$(docker exec "$cid" npm --version 2>&1)"
[[ "$out" == "$want" ]] && pass "the default Node's npm is npm=$want" \
  || fail "the default Node's npm is ${out:-nothing}, want npm=$want"

out="$(docker exec "$cid" bash -c 'source "${NVM_DIR:-/opt/nvm}/nvm.sh" >/dev/null 2>&1
  nvm use 20 >/dev/null 2>&1 || { echo "nvm use 20 failed"; exit 1; }
  printf "%s %s\n" "$(node --version)" "$(npm --version)"' 2>&1)"
node_v="${out%% *}"; npm_v="${out#* }"
if [[ "$node_v" == v20.* && "$npm_v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$npm_v" != "$want" ]]; then
  pass "after nvm use 20, Node $node_v keeps its own npm $npm_v"
else
  fail "after nvm use 20: '$out' (want Node v20.x with an npm other than $want)"
fi

it_finish
