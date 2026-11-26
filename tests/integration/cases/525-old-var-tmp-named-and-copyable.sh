#!/usr/bin/env bash
# summary:  an old bind-version .var-tmp is named at launch, and the printed copy command makes it usable in the volume
# tags:     groups fast
# requires: docker launcher
#
# /var/tmp used to be a host folder, <group>/.var-tmp. It is now the group's
# Docker volume, and the old folder is neither mounted, copied nor removed by
# the launcher: it is NAMED, at every launch while it is there, with the command
# that copies it into the volume. Nothing else tells a user that what their
# agent left in /var/tmp is no longer where it was.
#
# This runs the whole story the way a user would, with the command taken from
# the launcher's stderr as printed (never rebuilt here, so a command that does
# not work as printed fails here):
#   1. an old folder with a file in it, made before any launch
#   2. launch 1 names it and prints the copy command; the folder stays on the host
#   3. the command is run
#   4. the volume's top folder is then made root's 0755, closed to the agent:
#      `cp -a /src/. /dst/` carries the old folder's own mode and owner onto
#      the volume's root, and what it carries may be anything
#   5. launch 2: the agent reads the old file, and gets a TMPDIR of its own.
#      That works only because the start-up resets /var/tmp to root-owned 1777
#      before it makes the folder as the agent.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

launcher_prepare || it_finish
launcher_conf claude-code=OFF || it_finish

grp=oldtmp
export AI_CONTAINER_GROUP="$grp"
vol="it-$IT_RUN_ID-vartmp-$grp"
old="$IT_LAUNCH_HOME/.ai-containers/$grp/.var-tmp"
old_slot=200101-000000-1
mkdir -p "$old/$old_slot" && chmod 0700 "$old/$old_slot" && printf old > "$old/$old_slot/f" \
  || { fail "could not make the old folder"; it_finish; }

# ── Launch 1 ───────────────────────────────────────────────────────────────────
launcher_up open || it_finish
cid_1="$IT_CID"
err_1="$IT_SCRATCH/525-launch-1.err"
cp "$IT_LAUNCH_ERR" "$err_1"

if grep -q '^NOTE:.*'"$old"'.*no longer mounted' "$err_1"; then
  pass "the launch names the old folder"
else
  fail "the launch names the old folder"
  sed 's/^/     /' "$err_1"
fi
copy_cmd="$(grep -m1 -E '^ +docker run --rm --pull=never .* -a /src/\. /dst/$' "$err_1")"
if [[ -n "$copy_cmd" ]]; then
  pass "the launch prints the copy command"
else
  fail "the launch prints the copy command"
  sed 's/^/     /' "$err_1"
  it_finish
fi
assert_host_file_exists "$old/$old_slot/f"

# ── Copy, as printed ───────────────────────────────────────────────────────────
sandbox_down "$cid_1"
if bash -c "$copy_cmd" >/dev/null 2>"$IT_SCRATCH/525-copy.err"; then
  pass "the printed copy command succeeds"
else
  fail "the printed copy command succeeds"
  sed 's/^/     /' "$IT_SCRATCH/525-copy.err"
  it_finish
fi
assert_host_file_exists "$old/$old_slot/f"

# ── Close the volume's top folder to the agent ─────────────────────────────────
if docker run --rm --pull=never ${IT_SELINUX_OPT:+"$IT_SELINUX_OPT"} -v "$vol:/v" --entrypoint sh "$IT_IMAGE" -c 'chown 0:0 /v && chmod 0755 /v' >/dev/null 2>"$IT_SCRATCH/525-close.err"; then
  pass "the volume's top folder is closed to the agent (root, 0755)"
else
  fail "the volume's top folder is closed to the agent (root, 0755)"
  sed 's/^/     /' "$IT_SCRATCH/525-close.err"
  it_finish
fi

# ── Launch 2 ───────────────────────────────────────────────────────────────────
launcher_up open || it_finish
cid_2="$IT_CID"

assert_agent_reads "$cid_2" "/var/tmp/$old_slot/f" old

top="$(agent_exec "$cid_2" "stat -c '%a %u' /var/tmp" 2>/dev/null)"
if [[ "$top" == "1777 0" ]]; then
  pass "the start-up reset /var/tmp to 1777, root's"
else
  fail "the start-up reset /var/tmp to 1777, root's — got '$top'"
fi

t="$(agent_exec_login "$cid_2" 'printf %s "$TMPDIR"' 2>/dev/null)"
if [[ "$t" =~ ^/var/tmp/[0-9]{6}-[0-9]{6}-[0-9]+$ && "$t" != "/var/tmp/$old_slot" ]]; then
  pass "the agent's login shell has a TMPDIR folder of its own"
else
  fail "the agent's login shell has a TMPDIR folder of its own — got '$t'"
fi
tm="$(agent_exec "$cid_2" "stat -c '%a %u' '$t'" 2>/dev/null)"
if [[ "$tm" == "700 $IT_LAUNCH_UID" ]]; then
  pass "that folder is 0700 and the agent's"
else
  fail "that folder is 0700 and the agent's — got '$tm', want '700 $IT_LAUNCH_UID'"
fi

sandbox_down "$cid_2"
it_finish
