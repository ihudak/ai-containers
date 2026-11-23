#!/usr/bin/env bash
# summary:  what an agent writes to /var/tmp, ~/.cache and ~/.local/state survives into the next container
# tags:     groups fast
# requires: docker launcher
#
# 510 proves the credential directories persist. This is the same contract for
# the three folders tools use as scratch and cache: a build's downloads, a
# tool's state, a half-finished temp file. Each is a group directory on the
# host, mounted over the container path, so a container run with --rm leaves
# its files for the next one.
#
# Each container also gets a folder of its own inside /var/tmp, named by launch
# time and launcher pid, and the agent's login shell points TMPDIR at it. Two
# containers of one group must not share one, and root must never get one: a
# TMPDIR in a root process's environment would send root's temp files into a
# folder the agent can write. The profile script is the only place TMPDIR is
# set, so a root login shell is the check.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

launcher_prepare || it_finish
launcher_conf claude-code=OFF || it_finish

export AI_CONTAINER_GROUP=scratch
launcher_up open || it_finish
cid_a="$IT_CID"

group_dir="$IT_LAUNCH_HOME/.ai-containers/scratch"

t1="$(agent_exec_login "$cid_a" 'printf %s "$TMPDIR"' 2>/dev/null)"
if [[ "$t1" =~ ^/var/tmp/[0-9]{6}-[0-9]{6}-[0-9]+$ ]]; then
  pass "the agent's login shell has TMPDIR in its own /var/tmp folder"
else
  fail "the agent's login shell has TMPDIR in its own /var/tmp folder — got '$t1'"
  it_finish
fi
slot="${t1#/var/tmp/}"

agent_exec "$cid_a" "printf a > '$t1/a' && mkdir -p \"\$HOME/.cache/it\" \"\$HOME/.local/state/it\" \
  && printf b > \"\$HOME/.cache/it/b\" && printf c > \"\$HOME/.local/state/it/c\"" >/dev/null 2>&1 || true

assert_host_file_exists "$group_dir/.var-tmp/$slot/a"
assert_host_file_exists "$group_dir/.cache/it/b"
assert_host_file_exists "$group_dir/.local/state/it/c"

root_tmp="$(docker exec "$cid_a" bash -lc 'printf %s "${TMPDIR-unset}"' 2>/dev/null)"
if [[ "$root_tmp" == "unset" ]]; then
  pass "a root login shell gets no TMPDIR"
else
  fail "a root login shell gets no TMPDIR — got '$root_tmp'"
fi

sandbox_down "$cid_a"

launcher_up open || it_finish
cid_b="$IT_CID"

home_b="$(agent_exec "$cid_b" 'printf %s "$HOME"' 2>/dev/null)"
for f in "$t1/a" "$home_b/.cache/it/b" "$home_b/.local/state/it/c"; do
  if [[ -n "$home_b" && "$(agent_exec "$cid_b" "cat '$f'" 2>/dev/null)" =~ ^[abc]$ ]]; then
    pass "they survive into the next container: $f"
  else
    fail "they survive into the next container: $f"
  fi
done

t2="$(agent_exec_login "$cid_b" 'printf %s "$TMPDIR"' 2>/dev/null)"
if [[ -n "$t2" && "$t2" != "$t1" ]]; then
  pass "the next container gets a folder of its own"
else
  fail "the next container gets a folder of its own — '$t1' then '$t2'"
fi

sandbox_down "$cid_b"
it_finish
