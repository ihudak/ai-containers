#!/usr/bin/env bash
# summary:  what an agent writes to /var/tmp, ~/.cache and ~/.local/state survives into the next container
# tags:     groups fast
# requires: docker launcher
#
# 510 proves the credential directories persist. This is the same contract for
# the three folders tools use as scratch and cache: a build's downloads, a
# tool's state, a half-finished temp file. ~/.cache and ~/.local/state are group
# directories on the host, mounted over the container path. /var/tmp is the
# group's Docker NAMED VOLUME (<prefix>-vartmp-<group>), not a host bind: GNU tar
# holds back a link whose target holds `..` behind a mode-000 placeholder,
# which macOS virtiofs cannot open, so an archive unpacked into $TMPDIR failed
# on a Mac with a bind (the bug that put ~/.rvm on a volume too). Either way a
# container run with --rm leaves its files for the next one.
#
# The tar check below is that Mac failure, run for real. It can go red only on
# a Mac: on Linux a bind holds the same links, so mutation 520-var-tmp-bind
# leaves it green and is caught by the mount-type assertion (case 460 is the
# precedent for a check whose bite depends on the host).
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

vol_a="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/tmp"}}{{.Type}} {{.Name}}{{end}}{{end}}' "$cid_a" 2>/dev/null)"
if [[ "$vol_a" == "volume it-$IT_RUN_ID-vartmp-scratch" ]]; then
  pass "/var/tmp is the group's Docker volume"
else
  fail "/var/tmp is the group's Docker volume — got '$vol_a'"
fi

group_dir="$IT_LAUNCH_HOME/.ai-containers/scratch"

t1="$(agent_exec_login "$cid_a" 'printf %s "$TMPDIR"' 2>/dev/null)"
if [[ "$t1" =~ ^/var/tmp/[0-9]{6}-[0-9]{6}-[0-9]+$ ]]; then
  pass "the agent's login shell has TMPDIR in its own /var/tmp folder"
else
  fail "the agent's login shell has TMPDIR in its own /var/tmp folder — got '$t1'"
  it_finish
fi

mode_a="$(agent_exec "$cid_a" "stat -c '%a %u' '$t1'" 2>/dev/null)"
if [[ "$mode_a" == "700 $IT_LAUNCH_UID" ]]; then
  pass "the agent's folder is 0700 and its own"
else
  fail "the agent's folder is 0700 and its own — got '$mode_a', want '700 $IT_LAUNCH_UID'"
fi

# The Mac failure: an archive holding a link whose target has `..`, unpacked.
if agent_exec_login "$cid_a" 'cd "$TMPDIR" && mkdir -p s/a/b s/x && ln -s ../../x s/a/b/l && tar -C s -cf t.tar a x && mkdir u && tar -C u -xf t.tar && test -L u/a/b/l' >/dev/null 2>&1; then
  pass "tar unpacks a link whose target holds .. into \$TMPDIR"
else
  fail "tar unpacks a link whose target holds .. into \$TMPDIR"
fi

agent_exec "$cid_a" "printf a > '$t1/a' && mkdir -p \"\$HOME/.cache/it\" \"\$HOME/.local/state/it\" \
  && printf b > \"\$HOME/.cache/it/b\" && printf c > \"\$HOME/.local/state/it/c\"" >/dev/null 2>&1 || true

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
# Each file against the byte written into it, so one place answering for another
# (the same folder mounted at two paths) does not pass.
for want_f in "a $t1/a" "b $home_b/.cache/it/b" "c $home_b/.local/state/it/c"; do
  want="${want_f%% *}" f="${want_f#* }"
  got="$(agent_exec "$cid_b" "cat '$f'" 2>/dev/null)"
  if [[ -n "$home_b" && "$got" == "$want" ]]; then
    pass "they survive into the next container: $f"
  else
    fail "they survive into the next container: $f — got '$got', want '$want'"
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
