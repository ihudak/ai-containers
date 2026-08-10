#!/usr/bin/env bash
# summary:  a :rwcopy write stays in the working copy and never reaches the base volume
# tags:     volumes fast
# requires: docker launcher
#
# :rwcopy exists so two workspaces can write to the same repo at once without
# wedging each other's git state. The base volume is the shared, canonical copy;
# each launch dir gets its own working copy seeded from it. If a launch mounted
# the base by mistake — one wrong variable in the `case "$rmode"` arm — every
# project pointing at that repo would be writing to one tree, and nothing would
# say so until two agents produced an impossible git index between them.
#
# So the assertion is not "the write worked". It is that the write landed in the
# working copy AND is absent from the base. Either half alone passes for the
# wrong reason: a write that failed entirely is also absent from the base.
#
# The working copy is found by LABEL, not by recomputing
# repo_workcopy_volume_name's hash of the launch dir. Recomputing would mean
# this case agrees with sandbox.sh's naming by construction — including when
# both are wrong — and it would silently stop finding anything if the tag scheme
# changed. seed_workcopy_volume stamps ai-containers.repo/.workcopy at creation;
# reading those is asking the system what it did.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
repo_register_volume shared || it_finish
base="$(repo_fixture_volume_name shared)"

export REPOS="shared:rwcopy"
launcher_up open || it_finish

# The seed happened: the working copy carries the base's content.
assert_agent_reads "$IT_CID" /workspace/shared/MARKER marker-shared

wc_vol="$(docker volume ls -q \
  --filter "label=$IT_LABEL" \
  --filter "label=ai-containers.workcopy=1" \
  --filter "label=ai-containers.repo=shared" 2>/dev/null | head -1)"
if [[ -n "$wc_vol" ]]; then
  pass "a labelled working-copy volume was created ($wc_vol)"
else
  fail "a labelled working-copy volume was created"
  docker volume ls --filter "label=$IT_LABEL" 2>&1 | sed 's/^/     /'
  it_finish
fi
if [[ "$wc_vol" != "$base" ]]; then
  pass "the working copy is a different volume from the base"
else
  fail "the working copy is a different volume from the base — the base was mounted directly"
fi

assert_writable "$IT_CID" /workspace/shared
agent_exec "$IT_CID" "printf 'written-in-the-copy\n' > /workspace/shared/COPY_ONLY" >/dev/null 2>&1 || true
assert_agent_reads "$IT_CID" /workspace/shared/COPY_ONLY written-in-the-copy

# Read both volumes from OUTSIDE the container under test. Reading through the
# same container could only ever show the working copy again.
vol_has() {  # $1=volume $2=path
  docker run --rm --label "$IT_LABEL" -v "$1:/v:ro" --entrypoint test "$IT_IMAGE" -f "/v/$2"
}
if vol_has "$wc_vol" COPY_ONLY; then
  pass "the write is present in the working-copy volume"
else
  fail "the write is present in the working-copy volume — it went somewhere else entirely"
fi
if vol_has "$base" COPY_ONLY; then
  fail "the base volume is untouched — the write LEAKED into the shared base"
else
  pass "the base volume is untouched"
fi
if vol_has "$base" MARKER; then
  pass "the base volume still holds its own content"
else
  fail "the base volume still holds its own content"
fi

it_finish
