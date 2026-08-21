#!/usr/bin/env bash
# Which mutation patches only take effect on a real image rebuild.
#
# Lifted VERBATIM from demonstrate-network-delivery-tiers.sh:114-151 so that
# demonstrate-launcher-tier.sh does not carry a hand-written second opinion
# about what a build input is. A copy of build_time_inputs() that drifted from
# the original would not fail loudly: it would send a build-input patch down the
# --reuse-image path and report the case UNDEMONSTRATED — a mutation declared
# dead that was never applied to anything, which is the precise defect this
# mechanism exists to prevent.
#
# UNFINISHED ON PURPOSE. demonstrate-network-delivery-tiers.sh still holds its own copy,
# so there are two right now. Folding it onto this file is a four-line change
# (delete 114-151, `source` this instead) that was written, verified green
# against `shellcheck -S warning -e SC1091`, and then REVERTED: it dirties a
# tracked file, and both mutate.sh:206 and the demonstrators refuse to run on a
# dirty tree, so the extraction cannot be used until it is committed. Do that
# fold-in in the same commit that first tracks this file.
#
# Requires $ENGINE_DIR to be set by the caller (the directory holding build.sh
# and the Dockerfile — the repo root upstream, base/ in mgd-ai-containers).

# ── Which patches only take effect on a rebuild ───────────────────────────────
# DERIVED from the Dockerfile — itself, plus every path it COPYs out of the build
# context — rather than kept as a list here. A missing entry does not fail
# silently, but it fails MISLEADINGLY: the case runs against an image that never
# contained the mutation, passes, and is reported as UNDEMONSTRATED, which reads
# as "this mutation no longer damages its case" when the truth is "this mutation
# was never applied to anything". Deriving it means a patch that starts touching
# entrypoint.sh or install-tools.sh is rebuilt without anyone remembering to say
# so.
#
# build.sh is in the set although nothing COPYs it: run.sh invokes it to produce
# the build args AND the allowlist-*.txt files the Dockerfile then COPYs, so a
# mutation there changes the image as surely as one in the Dockerfile.
#
# The names emitted here are UNPREFIXED even where the engine lives in base/,
# because they are compared against the patch's own `+++ b/…` paths, and one
# mutation set serves both repos with upstream paths in it. Only the Dockerfile
# is READ through $ENGINE_DIR.
#
# The KNOWN LIMIT is what build.sh READS — an allowlist-*.d fragment,
# sandbox-common.sh — which no patch touches today. If one ever does, the
# symptom is the misleading UNDEMONSTRATED above, so extend this function rather
# than the case.
build_time_inputs() {
  printf 'Dockerfile\nbuild.sh\n'
  sed -n 's/^COPY[[:space:]]\{1,\}\([^[:space:]]\{1,\}\)[[:space:]].*/\1/p' "$ENGINE_DIR/Dockerfile"
}
patch_needs_rebuild() {  # $1=patch → 0 if it changes something the image is built FROM
  local changed input
  while IFS= read -r changed; do
    while IFS= read -r input; do
      # The exact file, or anything beneath a directory the Dockerfile COPYs
      # whole: tools.d/dtctl.conf is as much a build input as tools-lib.sh.
      [[ "$changed" == "$input" || "$changed" == "$input/"* ]] && return 0
    done < <(build_time_inputs)
  done < <(sed -n 's|^+++ b/||p' "$1")
  return 1
}
