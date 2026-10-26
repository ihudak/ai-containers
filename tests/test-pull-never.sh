#!/usr/bin/env bash
# IMAGE_NAME can come from a committed sandbox.env, so no `docker run` of the
# project's image may let docker pull it: an image this machine never built
# would be fetched from a registry and run — as root in the seed containers,
# with repo volumes mounted, before the launch's own run (review of batch 2, F2).
#
# Structural, not behavioural: these runs sit behind repo volumes and an rvm
# migration that a hermetic fake cannot drive cheaply. Each `docker run`
# statement is joined across its continuation lines, and any that names the
# project image — "$image_name", "$image", "${IMAGE_NAME…}" — must carry
# --pull=never. A statement naming no image variable is the seed image or a
# fixed base, which repo.sh / verify-on-host.sh build or pin themselves.
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
    /docker run/ { start = FNR; cur = $0; if ($0 !~ /\\$/) flush() }
  ' "$1"
}

seen=0
for f in sandbox.sh sandbox-common.sh extract-discovery.sh; do
  [[ -f "$ENGINE_DIR/$f" ]] || { fail "SCAFFOLD: $f not found under $ENGINE_DIR"; continue; }
  while IFS= read -r st; do
    case "$st" in
      *'"$image_name"'*|*'"$image"'*|*'${IMAGE_NAME'*|*'"$IMAGE_NAME"'*) ;;
      *) continue ;;
    esac
    seen=$((seen + 1))
    if [[ "$st" == *--pull=never* ]]; then pass "--pull=never: ${st%%: *}"
    else fail "a docker run of the project image may pull it: ${st:0:160}"; fi
  done < <(statements "$ENGINE_DIR/$f")
done
# The scan must have found the runs it exists for, or it verified nothing.
(( seen >= 4 )) && pass "found $seen docker runs of the project image" \
  || fail "found only $seen docker runs of the project image — the scan is broken"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
