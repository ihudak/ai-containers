#!/usr/bin/env bash
# summary:  the agent's git works in a repository it does not own; root's git
#           still refuses one the agent owns
# tags:     delivery security fast
# requires: docker
#
# git refuses a repository another user owns ("detected dubious ownership"),
# and on Colima a host bind's mount root shows as owned by ROOT inside the
# container while the host and the VM show your uid — so git refused every
# command in a host-path primary, and case 465's commit failed only on macOS.
# The entrypoint trusts every repository in the sandbox user's own git config
# (entrypoint.sh: `trust_repositories_for_sandbox_user()`).
#
# The other half is why it is the user's config and not the image's: root reads
# the system config too, and v0.10.3 put `*` there, so root's git ran what the
# agent wrote into a repository it owns. Here core.fsmonitor, which `git status`
# runs: a `docker exec` without -u is root (the image names no user), and root
# here holds the container's NET_ADMIN.
#
# Reproduced on any host, not only Colima: root makes a repository, and the
# sandbox uid — through `docker exec -u`, as a user runs one — uses git in it.
# Through the entrypoint, since that is what writes the config. Mutations 315
# (the trust dropped) and 316 (put back in the system config) each fail one half.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up open "$adir" || it_finish
# sandbox_up's SANDBOX_UID/GID, not the launching user's.
as_agent() { docker exec -u 1000:1000 "$IT_CID" bash -c "$1"; }

if ! docker exec "$IT_CID" sh -c 'git init -q /tmp/rootrepo && test "$(stat -c %u /tmp/rootrepo)" = 0' >/dev/null 2>&1; then
  fail "could not make a root-owned repository in the container"; it_finish
fi
out="$(as_agent 'git -C /tmp/rootrepo status --short' 2>&1)"
if [[ $? -eq 0 ]]; then
  pass "the sandbox user runs git in a repository root owns"
else
  fail "the sandbox user runs git in a repository root owns ($out)"
fi

# The agent's repository, with a command planted where root's git would run it.
# fsmonitor is handed arguments; the trailing `#` discards them.
if ! as_agent 'git init -q /tmp/agentrepo && : > /tmp/agentrepo/f &&
    git -C /tmp/agentrepo config core.fsmonitor "id -u > /tmp/fsmonitor-ran; false #"' >/dev/null 2>&1; then
  fail "could not make the agent's repository"; it_finish
fi
out="$(docker exec "$IT_CID" git -C /tmp/agentrepo status --short 2>&1)"; rc=$?
ran="$(docker exec "$IT_CID" cat /tmp/fsmonitor-ran 2>/dev/null)"
if [[ "$rc" -ne 0 && "$out" == *"dubious ownership"* && -z "$ran" ]]; then
  pass "root's git refuses a repository the agent owns, and runs nothing from it"
else
  fail "root's git refuses a repository the agent owns (rc=$rc, fsmonitor ran as uid '${ran:-nobody}', out: $out)"
fi

it_finish
