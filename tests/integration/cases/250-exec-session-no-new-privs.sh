#!/usr/bin/env bash
# summary:  a docker exec session into a launched container runs with no_new_privs
# tags:     security network-mode open fast
# requires: docker launcher
#
# The entrypoint gives the agent shell no_new_privs (RT-10), but a `docker exec`
# session is a fresh process from the daemon, outside that shell's tree, and
# did not inherit it: a `docker exec -u <agent>` shell had NoNewPrivs 0 while
# /usr/bin/passwd and the image's other setuid-root binaries were still there
# for it to run (bugs review RT-11). sandbox.sh passes
# --security-opt=no-new-privileges, which the daemon applies to every process
# in the container, exec sessions included.
#
# Launched through sandbox.sh itself (launcher_up), not sandbox_up, because the
# claim is about the options sandbox.sh passes; sandbox_up deliberately does not
# pass this one (it would hide RT-10's own flag from cases 070/230/240).
# Paired with the EFFECT, independent of what the image ships: a setuid-root
# copy of `id`, made here as root, must still report the agent's uid when the
# agent's exec session runs it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

launcher_up open || it_finish

nnp() {  # $1=docker exec user ('' = the default, root) → NoNewPrivs of that session
  docker exec ${1:+-u "$1"} "$IT_CID" sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status 2>/dev/null
}
v="$(nnp "$IT_LAUNCH_UID")"
[[ "$v" == 1 ]] && pass "a docker exec -u <agent> session runs with no_new_privs" \
  || fail "a docker exec -u <agent> session runs with NoNewPrivs [${v:-<unreadable>}]"
v="$(nnp '')"
[[ "$v" == 1 ]] && pass "a root docker exec session runs with no_new_privs too" \
  || fail "a root docker exec session runs with NoNewPrivs [${v:-<unreadable>}]"
assert_no_new_privs "$IT_CID"

# A nosuid /tmp would make the effect check pass without the option, so it is
# refused rather than trusted.
opts="$(docker exec "$IT_CID" findmnt -no OPTIONS -T /tmp 2>/dev/null)"
if [[ -z "$opts" || ",$opts," == *,nosuid,* ]]; then
  fail "the filesystem holding /tmp ignores setuid bits or cannot be read (options: ${opts:-<unreadable>}) — the effect check below would prove nothing"
elif docker exec "$IT_CID" sh -c 'cp /usr/bin/id /tmp/suid-id && chown 0:0 /tmp/suid-id && chmod 4755 /tmp/suid-id' 2>/dev/null; then
  got="$(docker exec -u "$IT_LAUNCH_UID" "$IT_CID" /tmp/suid-id -u 2>/dev/null)"
  [[ "$got" == "$IT_LAUNCH_UID" ]] \
    && pass "a setuid-root binary run from the agent's exec session does not make it root (uid $got)" \
    || fail "a setuid-root binary run from the agent's exec session ran as uid [${got:-<nothing>}], not $IT_LAUNCH_UID"
else
  fail "could not make a setuid-root binary to run (the effect assertion would prove nothing)"
fi

it_finish
