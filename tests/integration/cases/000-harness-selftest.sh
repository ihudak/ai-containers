#!/usr/bin/env bash
# summary:  the harness itself works — sidecar serves, an open-mode sandbox reaches it
# tags:     harness fast
# requires: docker sidecar
#
# Proves the primitives before any case that depends on them can lie about a
# security property. If this fails, every "blocked" result below is meaningless:
# a destination nothing could ever reach looks exactly like a destination the
# firewall dropped.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

sidecar_up || it_finish
pass "sidecar started on $IT_NET as $IT_SIDECAR ($IT_SIDECAR_IP)"

adir="$(it_scratch)"
allowlist_write "$adir" "" "" ""

# open mode: no firewall at all, so reachability here is a property of the
# harness (network, sidecar, curl), not of any enforcement decision.
sandbox_up open "$adir" || it_finish
pass "open-mode sandbox started ($IT_CID)"
assert_reachable "$IT_CID" "$IT_SIDECAR_IP"

# The image must actually carry the sidecar runtime; if node ever stops being
# unconditional, every network case silently loses its destination.
if docker run --rm --entrypoint node "$IT_IMAGE" --version >/dev/null 2>&1; then
  pass "the image ships node (the sidecar runtime)"
else
  fail "the image ships node (the sidecar runtime)"
fi

it_finish
