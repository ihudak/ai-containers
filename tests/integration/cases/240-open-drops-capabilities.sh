#!/usr/bin/env bash
# summary:  the open-mode agent shell holds neither NET_ADMIN nor NET_RAW
# tags:     security network-mode open fast
# requires: docker
#
# The belt backlog F7 believed was already covered. It was not. F7's own entry
# read "the missing belt is now covered by 240-open-grants-no-capabilities", and
# no such case had ever been written — that sentence was the only mention of the
# name anywhere in the repo. Meanwhile 230 carried the `open` tag while launching
# discovery, so `--tags open`, `--tags security` and a reader skimming basenames
# all saw a green capability case for a mode nothing exercised.
#
# Open mode is "no firewall", NOT "no isolation" — a distinction worth pinning,
# because the name invites the opposite reading. entrypoint.sh's open branch
# reaches its OWN `exec capsh --drop=cap_net_admin,cap_net_raw --user=…`,
# separate from the restricted branch 070 covers and the discovery branch 230
# covers. Three modes, three execs, three cases; a case cannot cover a branch it
# does not run.
#
# WHAT IS AND IS NOT MEANINGFUL HERE. sandbox_up passes no --cap-add for open
# mode (lib.sh:203), so cap_net_admin is never granted and asserting its absence
# is nearly free. cap_net_raw is the load-bearing one: Docker's default bounding
# set includes it (for ping), and neither sandbox.sh nor sandbox_up issues any
# --cap-drop, so an open-mode CONTAINER holds cap_net_raw whatever entrypoint.sh
# does. Only the handover to the sandbox user takes it away from the agent shell.
# Both are asserted; cap_net_raw is the one with something to prove.
#
# KNOWN-BAD: mutations/240-open-keeps-capabilities.patch. Deleting `--drop=` from
# the open branch would NOT fail this case — as 230's note records, `capsh
# --user=` setuids from root and the kernel clears the permitted and effective
# sets on that transition, so the drop is equivalent to the setuid and removing
# it is an equivalent mutation. The patch therefore adds the one flag that stops
# the setuid clearing them: `--keep=1` (PR_SET_KEEPCAPS), which 230's note names
# as "never used". PID 1 still becomes the sandbox user, so sandbox_up's handover
# wait still succeeds and the break reaches THIS case's assertion instead of
# dying in the harness first — assert_no_capability reports cap_net_raw still
# present. 230 is untouched by that patch and still passes, which is exactly the
# coverage 230 could never provide.
#
# Same /proc/1/status rule as 070 and 230: a fresh `docker exec` starts from the
# container's capability BOUNDING SET and does not inherit capsh's drops, so
# asking it directly reports capabilities that PID 1 does not actually hold.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up open "$adir" || it_finish

caps="$(pid1_caps "$IT_CID")"
if [[ -n "$caps" ]]; then
  pass "read the agent shell's effective capabilities [$caps]"
else
  fail "read the agent shell's effective capabilities (empty — the assertions below would pass vacuously)"
fi

assert_no_capability "$IT_CID" cap_net_admin
assert_no_capability "$IT_CID" cap_net_raw

it_finish
