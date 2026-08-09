#!/usr/bin/env bash
# summary:  what an agent writes to ~/.claude survives into the group on the host
# tags:     groups fast
# requires: docker launcher
#
# The group's other half of the contract. 500 proves group B cannot read group
# A's credentials; this proves the credentials are there to read next time —
# that `gh auth login` or a Claude Code OAuth handshake inside the container
# lands in ~/.ai-containers/<group>/ and not in a layer that vanishes when the
# container exits.
#
# The failure is quiet in the most expensive way: the agent authenticates,
# everything works for the whole session, and the next container asks the human
# to log in again. Nothing errors, so nobody suspects the mount — people
# reasonably blame the CLI's token expiry.
#
# Two ways this breaks and both are covered: a mount that is read-only (the
# write fails, or worse, silently succeeds into an overlay), and a mount whose
# host directory is owned by someone the agent is not — the -xdev in
# setup_sandbox_user's recursive chown deliberately does not cross into mounts,
# so the group directory's ownership is exactly as the host left it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

launcher_prepare || it_finish
launcher_conf claude-code=ON || it_finish

export AI_CONTAINER_GROUP=persist
launcher_up open || it_finish

group_dir="$IT_LAUNCH_HOME/.ai-containers/persist"

# sandbox.sh creates the group and its per-component dirs on first run — this is
# a fresh group, so the directory did not exist a moment ago.
if [[ -d "$group_dir/.claude" ]]; then
  pass "first run created the group's .claude/ on the host"
else
  fail "first run created the group's .claude/ on the host"
  ls -la "$group_dir" 2>&1 | sed 's/^/     /'
  it_finish
fi

assert_writable "$IT_CID" "$IT_LAUNCH_HOME_IN/.claude"

agent_exec "$IT_CID" \
  "printf '{\"token\":\"issued-in-container\"}\n' > '$IT_LAUNCH_HOME_IN/.claude/.credentials.json'" \
  >/dev/null 2>&1 || true

assert_host_file_exists "$group_dir/.claude/.credentials.json"
if grep -q 'issued-in-container' "$group_dir/.claude/.credentials.json" 2>/dev/null; then
  pass "the credential the agent wrote is readable on the host"
else
  fail "the credential the agent wrote is readable on the host"
fi

# And it must belong to the invoking user, not root: a root-owned credential
# file is one the human cannot rotate or delete without sudo, and the next
# container — same uid — may not be able to rewrite it either.
owner="$(ls -ln "$group_dir/.claude/.credentials.json" 2>/dev/null | awk '{print $3}')"
if [[ "$owner" == "$IT_LAUNCH_UID" ]]; then
  pass "the file belongs to the invoking user ($IT_LAUNCH_UID)"
else
  fail "the file belongs to the invoking user ($IT_LAUNCH_UID) — owned by uid '${owner:-?}'"
fi

# It must survive the container, which is the entire point.
sandbox_down "$IT_CID"
assert_host_file_exists "$group_dir/.claude/.credentials.json"

it_finish
