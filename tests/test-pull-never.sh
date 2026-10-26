#!/usr/bin/env bash
# IMAGE_NAME can come from a committed sandbox.env, so no `docker run` of the
# project's image may let docker pull it: an image this machine never built
# would be fetched from a registry and run — as root in the seed containers,
# with repo volumes mounted, before the launch's own run (review of batch 2, F2).
#
# Structural, not behavioural: these runs sit behind repo volumes and an rvm
# migration that a hermetic fake cannot drive cheaply. Each `docker run` (or
# `docker container run`) statement is joined across its continuation lines, and
# every one must carry --pull=never unless it runs the seed image, which repo.sh
# builds locally itself (ensure_seed_image) — an allow-list, so a run added later
# under any spelling of the image fails here until it is decided (re-review of
# 3529f22).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# statements <file>: every `docker run` statement, one per line, continuations joined.
statements() {
  awk '
    function flush() { if (cur != "") print FILENAME ":" start ": " cur; cur = "" }
    /^[[:space:]]*#/ { next }
    cur != "" { cur = cur " " $0; if ($0 !~ /\\$/) flush(); next }
    /docker (container )?run/ { start = FNR; cur = $0; if ($0 !~ /\\$/) flush() }
  ' "$1"
}

seen=0
for f in sandbox.sh sandbox-common.sh extract-discovery.sh repo.sh; do
  [[ -f "$ENGINE_DIR/$f" ]] || { fail "SCAFFOLD: $f not found under $ENGINE_DIR"; continue; }
  while IFS= read -r st; do
    seen=$((seen + 1))
    if [[ "$st" == *--pull=never* ]]; then pass "--pull=never: ${st%%: *}"
    elif [[ "$st" == *'$seed_image'* ]]; then pass "seed image (built locally by repo.sh): ${st%%: *}"
    else fail "a docker run without --pull=never: ${st:0:160}"; fi
  done < <(statements "$ENGINE_DIR/$f")
done
# The scan must have found the runs it exists for, or it verified nothing.
(( seen >= 10 )) && pass "found $seen docker runs" \
  || fail "found only $seen docker runs — the scan is broken"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
