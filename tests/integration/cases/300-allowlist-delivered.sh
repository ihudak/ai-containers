#!/usr/bin/env bash
# summary:  the allowlists build.sh generated are the ones inside the image
# tags:     security delivery fast
# requires: docker
#
# ASSEMBLY vs DELIVERY. tests/test-allowlists.sh already covers assembly with 44
# hermetic assertions — component ON means its fragment lands in the generated
# file. DELIVERY, meaning that generated file actually reaches /tmp/ in the
# image, is covered by NOTHING, anywhere. Dockerfile:467-469 are three bare
# `COPY allowlist-*.txt /tmp/` lines, and a stale or absent allowlist would ship
# with every existing test green.
#
# That is not cosmetic drift. refresh-ipset-allowlist.sh reads these exact paths
# (its lines 4-6) to build the ipset that IS the firewall, so a mismatch here is
# a silently wrong firewall: 010 would still block the sidecar, 020 would still
# admit it, and the container would be enforcing a policy nobody wrote.
#
# The comparison is byte-for-byte against what build.sh produced during THIS
# run's image build (run.sh snapshots it into $IT_GENERATED_ALLOWLIST_DIR right
# after the build). Comparing against the repo's working-tree files instead would
# be weaker: they are regenerated on every build and could drift from what the
# image was actually built from.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# --reuse-image skips the build, so there is no snapshot to compare against. That
# is a legitimate reason not to run, and SKIP (exit 77) says so explicitly rather
# than passing vacuously — the runner counts skips separately from passes for
# exactly this reason.
#
# This case carries the `security` tag for that skip's sake. A wrong allowlist in
# the image is a security failure, not a cosmetic one, and CI runs with
# `--require security` — so if a future workflow ever adds --reuse-image, this
# case going quiet FAILS the run instead of silently disappearing from the count.
# Without the tag, the one case that can detect a wrong firewall would be the one
# case allowed to skip unnoticed.
[[ -d "$IT_GENERATED_ALLOWLIST_DIR" ]] \
  || skip "no generated-allowlist snapshot (run.sh was invoked with --reuse-image)"

for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
  want="$(cat "$IT_GENERATED_ALLOWLIST_DIR/$f" 2>/dev/null)"
  got="$(docker run --rm --label "$IT_LABEL" --entrypoint cat "$IT_IMAGE" "/tmp/$f" 2>/dev/null)"

  # An empty `got` covers both "the COPY was dropped" and "the file is there but
  # empty" — distinct causes, same consequence: the firewall would be built from
  # nothing. Report it separately from a mismatch so the diagnosis is immediate.
  if [[ -z "$got" ]]; then
    fail "/tmp/$f exists in the image and is non-empty (it is empty or absent)"
  elif [[ "$want" == "$got" ]]; then
    pass "/tmp/$f matches what build.sh generated"
  else
    fail "/tmp/$f differs from what build.sh generated"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -20 | sed 's/^/     /'
  fi
done

it_finish
