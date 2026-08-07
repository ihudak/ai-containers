#!/usr/bin/env bash
# summary:  open mode starts no capture daemon and creates no output dirs
# tags:     network-mode open fast
# requires: docker
#
# Open mode's documented promise is "unrestricted egress, NO capture, no
# logging". A capture daemon quietly running here would write the user's traffic
# to disk in the one mode that promises it does not — a privacy failure, not a
# correctness one, and the kind nobody would notice because nothing about it is
# visible from inside the container.
#
# Note this is the INVERSE of what 050 asserts for restricted mode: there, the
# three output files existing is the proof the daemon survived startup. Here
# their absence is the proof it never started. Same observation, opposite claim,
# which is why both are worth having.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""
sandbox_up restricted "$adir" || it_finish

assert_file_absent "$IT_CID" /workspace/.agent-blocked/blocked.log
assert_file_absent "$IT_CID" /workspace/.agent-discovery/agent-traffic.pcap

# The files being absent is not the same as no daemon running: a capture process
# could be alive and writing somewhere else entirely. Check for the process too,
# covering BOTH daemons (capture-blocked-traffic.sh and
# capture-agent-destinations.sh) — open mode must start neither.
#
# THE SEARCH MUST EXCLUDE ITSELF. The obvious one-liner,
#   grep -l "capture-" /proc/[0-9]*/cmdline
# always matches, in every container, even with no daemon at all: the `bash -c`
# running it has "capture-" in its OWN cmdline and its own /proc entry. This case
# failed on exactly that in CI run 31152633295. The usual `[c]apture-` bracket
# idiom does NOT help here — that trick works against `ps` output, but grep is
# reading /proc files, so the pattern still matches the shell's own cmdline file.
# Skipping $$ and $PPID is the fix; verified both ways (silent with no daemon,
# still detects a real one).
if docker exec "$IT_CID" bash -c '
      found=""
      for f in /proc/[0-9]*/cmdline; do
        p="${f#/proc/}"; p="${p%/cmdline}"
        [ "$p" = "$$" ] && continue
        [ "$p" = "$PPID" ] && continue
        grep -q "capture-" "$f" 2>/dev/null && found="$found $p"
      done
      [ -n "$found" ] && { printf "%s\n" "$found"; exit 0; }
      exit 1' >/dev/null 2>&1; then
  fail "no capture process is running in open mode — one IS running"
else
  pass "no capture process is running in open mode"
fi

assert_log_contains "$IT_CID" 'OPEN MODE: outbound network is UNRESTRICTED and NOT captured'

it_finish
