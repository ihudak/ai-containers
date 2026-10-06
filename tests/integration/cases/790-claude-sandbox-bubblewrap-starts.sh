#!/usr/bin/env bash
# summary:  claude-code-sandbox=ON: bubblewrap starts inside the container, as the agent user
# tags:     packages slow claude-sandbox
# requires: docker launcher netadmin
# image:    sandbox
# timeout:  1800
#
# THE QUESTION THIS CASE EXISTS TO ANSWER. claude-code-sandbox=ON lifts Docker's
# seccomp and AppArmor profiles so that Claude Code's own sandbox — bubblewrap —
# can create a user namespace and mount inside it. Whether that is ENOUGH was never
# measured: a host whose kernel restricts unprivileged user namespaces (Ubuntu
# 24.04 sets kernel.apparmor_restrict_unprivileged_userns=1, and so do this suite's
# ubuntu-24.04 runners) restricts an unconfined process's namespace too, unless a
# host AppArmor profile grants bubblewrap `userns`. Claude Code's
# failIfUnavailable then stops every session at startup.
#
# Claude Code itself needs a login, so the case runs bubblewrap directly, as the
# agent user, with what the sandbox needs: a new user, network, IPC and UTS
# namespace, a read-only root with one writable bind, /dev, and the container's
# own /proc bound in (enableWeakerNestedSandbox, which the managed settings set).
# Inside, a write to the bound directory must succeed and a write to the read-only
# root must not — so a bubblewrap that "starts" without isolating anything fails
# too.
#
# Assertions, in order:
#   1. bwrap and socat are installed and run (socat answers -V; it rejects --version);
#   2. /etc/claude-code/managed-settings.json is in the image;
#   3. bubblewrap starts and isolates, as the agent user, WITHOUT a network
#      namespace: a user, IPC and UTS namespace, the read-only root and the bind;
#   4. the same WITH a network namespace (--unshare-net), which Claude Code's
#      sandbox needs to restrict a command's traffic. Measured on this suite's
#      ubuntu-24.04 runner with both profiles lifted, 4 failed setting up the new
#      namespace's loopback (`loopback: Failed RTM_NEWADDR: Operation not
#      permitted`): the host's userns restriction leaves the namespace without the
#      capability. 3 and 4 are separate so a red run says which half failed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
launcher_up restricted || it_finish

assert_runs "$IT_CID" bwrap
if out="$(docker exec "$IT_CID" socat -V 2>&1)"; then
  pass "socat runs: $(printf '%s\n' "$out" | grep -m1 -i 'socat version' || printf '%s\n' "$out" | head -1)"
else
  fail "socat is present but FAILED TO RUN: $(printf '%s\n' "$out" | head -1)"
fi

if docker exec "$IT_CID" test -s /etc/claude-code/managed-settings.json; then
  pass "the managed settings file is in the image"
else
  fail "the managed settings file is MISSING — Claude Code would run with its sandbox off"
fi

bwrap_probe() {  # $1=extra namespace flag (or empty) $2=what it proves
  local probe out
  probe='d="$(mktemp -d)" &&
    bwrap --unshare-user '"$1"' --unshare-ipc --unshare-uts --die-with-parent \
          --ro-bind / / --bind "$d" "$d" --dev /dev --bind /proc /proc \
          sh -c "touch \"$d/probe\" && ! touch /usr/.it-bwrap-probe 2>/dev/null && echo BWRAP-ISOLATES"'
  out="$(agent_exec "$IT_CID" "$probe" 2>&1)"
  if grep -q '^BWRAP-ISOLATES$' <<<"$out"; then
    pass "bubblewrap starts as the agent user $2, its root read-only and its bind writable"
  else
    fail "bubblewrap did not start (or did not isolate) as the agent user $2 — Claude Code's sandbox cannot run here"
    printf '     output: %s\n' "$(printf '%s\n' "$out" | head -3)"
  fi
}
bwrap_probe "" "without a network namespace"
bwrap_probe "--unshare-net" "with a network namespace, as Claude Code's network isolation needs"

it_finish
