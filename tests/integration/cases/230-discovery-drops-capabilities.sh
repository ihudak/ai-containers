#!/usr/bin/env bash
# summary:  the discovery-mode agent shell holds neither NET_ADMIN nor NET_RAW,
#           in the one mode that actually grants both
# tags:     security network-mode discovery fast
# requires: docker
#
# RENAMED from 230-open-drops-capabilities — backlog F7. The old basename, the
# `open` tag and the old summary all described a case that does not exist: the
# body below launches DISCOVERY mode, and always has.
#
# That was not a harmless label. `--tags open` selected this case and `--tags
# security` reported it green, so anyone asking "is open mode's capability drop
# verified?" got yes from a case that never launched open mode — while
# entrypoint.sh's open branch, which reaches its own `exec capsh` and not
# discovery's, was asserted by nothing at all. 240-open-drops-capabilities now
# owns that belt.
#
# Launching discovery here is deliberate and stays. sandbox_up grants
# --cap-add=NET_ADMIN --cap-add=NET_RAW to restricted and discovery (lib.sh:202)
# and nothing at all to open (lib.sh:203), so this is the mode where the drop has
# the most to take away. One case per mode, because each mode reaches a different
# `exec capsh` and a case cannot cover a branch it does not run: 070 restricted,
# this one discovery, 240 open.
#
# THIS CASE ASSERTS ONE BELT, NOT TWO. An earlier version of this comment also
# claimed it asserted that "sandbox.sh passes no --cap-add at all, so the
# capabilities were never granted to begin with". This case cannot observe
# sandbox.sh at all: lib.sh's sandbox_up composes its OWN docker run with its own
# per-mode capability logic (lib.sh:202-203) and never invokes the launcher. What
# sandbox.sh requests is asserted hermetically instead, in
# tests/test-mode-capabilities.sh.
#
# NOTE: entrypoint.sh drops only cap_net_admin in discovery mode and used to
# claim NET_RAW was "kept for tcpdump" — but this case PASSES, which is how that
# claim was discovered to be false: `capsh --user=` setuids from root and the
# kernel clears the permitted and effective sets on that transition unless
# PR_SET_KEEPCAPS is set (capsh --keep=1, never used). So discovery's agent shell
# holds no capabilities either, and --drop=cap_net_admin is equivalent to
# dropping both. entrypoint.sh and AGENTS.md were corrected; this comment is
# corrected with them.
#
# The known-bad configuration that makes this case fail is pointing pid1_caps at
# a fresh `docker exec` — mutations/070-230-pid1-caps-fresh-exec.patch. Note what
# that implies, and what 240's patch exploits: because the drop is equivalent to
# the setuid, deleting --drop from entrypoint.sh does NOT make a capability case
# fail. Only a mutation that stops the setuid clearing the sets does.
#
# Same /proc/1/status rule as 070: a fresh `docker exec` starts from the
# container's capability BOUNDING SET and does not inherit capsh's drops, so
# asking it directly reports capabilities that PID 1 does not actually hold.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up discovery "$adir" -e DISCOVERY_CAPTURE_ENABLED=0 || it_finish

caps="$(pid1_caps "$IT_CID")"
if [[ -n "$caps" ]]; then
  pass "read the agent shell's effective capabilities [$caps]"
else
  fail "read the agent shell's effective capabilities (empty — the assertions below would pass vacuously)"
fi

assert_no_capability "$IT_CID" cap_net_admin
assert_no_capability "$IT_CID" cap_net_raw

it_finish
