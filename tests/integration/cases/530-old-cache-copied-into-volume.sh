#!/usr/bin/env bash
# summary:  a group's old host .cache is copied into its new cache volume once, the agent's to read and write
# tags:     groups fast
# requires: docker launcher
#
# ~/.cache used to be a host folder, <group>/.cache, bound over the container
# path. It is now the group's Docker volume, and the launch that makes the
# volume copies the old folder into it once (sandbox-common.sh:
# `cache_volume_copy_old()`): qmd's index and Playwright's browsers are slow to
# rebuild. The copy runs as the agent's uid, so what it makes is the agent's:
# on a Mac, root reads a host bind's files as its own, and a copy as root left
# folders in the volume that the agent could not enter (case 525's failure).
# That half is seen only on a Mac; on Linux the files keep the host uid either
# way, and mutation 530-old-cache-not-copied is what this case catches.
#
# The old folder itself is never changed, and a later launch does not copy
# again: by then the volume holds what the agent wrote since.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

launcher_prepare || it_finish
launcher_conf claude-code=OFF || it_finish

export AI_CONTAINER_GROUP=oldcache
old="$IT_LAUNCH_HOME/.ai-containers/oldcache/.cache"
mkdir -p "$old/it" "$old/priv" && printf old > "$old/it/f" && printf p > "$old/priv/g" && chmod 700 "$old/priv" \
  || { fail "could not make the old host .cache"; it_finish; }

launcher_up open || it_finish
cid_a="$IT_CID"

if grep -qF "Copying this group's ~/.cache into the docker volume it-$IT_RUN_ID-cache-oldcache" "$IT_LAUNCH_ERR" \
   && grep -qF 'Copied.' "$IT_LAUNCH_ERR"; then
  pass "the first launch says it copies the old .cache into the volume"
else
  fail "the first launch says it copies the old .cache — got: $(grep -iF -e cop -e WARNING "$IT_LAUNCH_ERR" | tr '\n' ' ')"
fi
got="$(agent_exec "$cid_a" 'cat "$HOME/.cache/it/f"' 2>/dev/null)"
[[ "$got" == old ]] && pass "the agent reads a file the old .cache held" \
  || fail "the agent reads a file the old .cache held — got '$got'"
got="$(agent_exec "$cid_a" 'cat "$HOME/.cache/priv/g"' 2>/dev/null)"
[[ "$got" == p ]] && pass "the agent reads a file in a 0700 folder the old .cache held" \
  || fail "the agent reads a file in a 0700 folder the old .cache held — got '$got'"
owners="$(agent_exec "$cid_a" 'stat -c "%u %a" "$HOME/.cache/it/f" "$HOME/.cache/priv" | tr "\n" " "' 2>/dev/null)"
[[ "$owners" == "$IT_LAUNCH_UID 644 $IT_LAUNCH_UID 700 " ]] \
  && pass "what was copied is the agent's, modes kept" \
  || fail "what was copied is the agent's, modes kept — got '$owners', want '$IT_LAUNCH_UID 644 $IT_LAUNCH_UID 700 '"
if agent_exec "$cid_a" 'printf n > "$HOME/.cache/priv/new" && printf new > "$HOME/.cache/it/f"' >/dev/null 2>&1; then
  pass "the agent writes into what was copied"
else
  fail "the agent writes into what was copied"
fi
top="$(agent_exec "$cid_a" 'ls -A "$HOME/.cache" | tr "\n" " "' 2>/dev/null)"
[[ "$top" == "it priv " ]] && pass "the copy left no staging folder behind" \
  || fail "the copy left no staging folder behind — ~/.cache holds '$top'"
[[ "$(cat "$old/it/f" 2>/dev/null)" == old && ! -e "$old/priv/new" ]] \
  && pass "the old host folder is untouched" || fail "the old host folder changed"

sandbox_down "$cid_a"

# A later launch: the volume is there, so nothing is copied again, though the old
# folder still is.
printf changed > "$old/it/f"
launcher_up open || it_finish
cid_b="$IT_CID"
got="$(agent_exec "$cid_b" 'cat "$HOME/.cache/it/f"' 2>/dev/null)"
[[ "$got" == new ]] && pass "a later launch copies nothing again: the volume keeps what the agent wrote" \
  || fail "a later launch copies nothing again — got '$got', want 'new'"
grep -qF 'Copying' "$IT_LAUNCH_ERR" && fail "a later launch says it copies" || pass "a later launch says nothing of a copy"

sandbox_down "$cid_b"
it_finish
