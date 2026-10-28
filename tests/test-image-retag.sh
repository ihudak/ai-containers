#!/usr/bin/env bash
# Tests for image_retag_guard() and the ai-containers.project label
# (sandbox-common.sh), which build.sh runs before it builds into IMAGE_NAME
# (bugs review ENV-7).
#
# IMAGE_NAME is portable, so a committed sandbox.env can name any tag, and the
# build retags it and deletes the image it held. A fake `docker` on PATH answers
# `image inspect` per case, chosen by FAKE_INSPECT:
#   gone29     Docker 29 with no such image: an empty line, exit 1
#   foreign    an image ai-containers did not build: no labels at all
#   legacy     built by ai-containers before v0.6.0: only the Dockerfile's title
#   old        built by ai-containers before the project label existed
#   <path>     built by ai-containers for the project at <path>
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_DIR"; [[ -f "$REPO_DIR/base/entrypoint.sh" ]] && ENGINE="$REPO_DIR/base"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ENGINE/sandbox-common.sh"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
[[ -z "${CALLS:-}" ]] || printf '%s\n' "$*" >> "$CALLS"
[[ "$1 ${2:-}" == "image inspect" ]] || exit 0
case "$FAKE_INSPECT" in
  gone29)  printf '\n'; exit 1 ;;
  foreign) printf '||\n' ;;
  legacy)  printf '|AI Sandbox Container|\n' ;;
  old)     printf '2026-01-01T00:00:00Z|AI Sandbox Container|\n' ;;
  *)       printf '2026-01-01T00:00:00Z|AI Sandbox Container|%s\n' "$FAKE_INSPECT" ;;
esac
FAKE
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/proj-a/.ai-containers" "$TMP/proj-b/.ai-containers"
A="$(ai_containers_project_id "$TMP/proj-a/.ai-containers")"
B="$(ai_containers_project_id "$TMP/proj-b/.ai-containers")"

guard() {  # $1=FAKE_INSPECT → "<rc>" ; stderr in $TMP/err
  FAKE_INSPECT="$1" image_retag_guard my-image "$A" 2>"$TMP/err"
  printf '%s' "$?"
}

[[ "$(guard gone29)" == 0 && ! -s "$TMP/err" ]] \
  && pass "a tag that does not exist yet is built, silently" \
  || fail "a missing tag (rc $(guard gone29); $(head -1 "$TMP/err"))"

rc="$(guard foreign)"
[[ "$rc" == 1 ]] && grep -qF "holds an image ai-containers did not build" "$TMP/err" \
  && grep -qF "docker rmi my-image" "$TMP/err" \
  && pass "an image ai-containers did not build (ubuntu:24.04, say) is refused, with the way out" \
  || fail "a foreign image is not refused (rc $rc; $(head -1 "$TMP/err"))"

[[ "$(guard legacy)" == 0 && ! -s "$TMP/err" ]] \
  && pass "an ai-containers image from before v0.6.0 (only the Dockerfile title) is rebuilt, silently" \
  || fail "a pre-v0.6.0 ai-containers image (rc $(guard legacy); $(head -1 "$TMP/err"))"

[[ "$(guard old)" == 0 && ! -s "$TMP/err" ]] \
  && pass "an ai-containers image from before the project label is rebuilt, silently" \
  || fail "an unlabelled ai-containers image (rc $(guard old); $(head -1 "$TMP/err"))"

[[ "$(guard "$A")" == 0 && ! -s "$TMP/err" ]] \
  && pass "this project's own image is rebuilt, silently" \
  || fail "this project's image (rc $(guard "$A"); $(head -1 "$TMP/err"))"

rc="$(guard "$B")"
[[ "$rc" == 0 ]] && grep -qF "built for $B" "$TMP/err" && grep -qF "one for $A" "$TMP/err" \
  && pass "another project's image is built over with a WARNING naming both projects" \
  || fail "a sibling project's image (rc $rc; $(head -1 "$TMP/err"))"

# The label the build stamps is the same id the guard compares with, and a
# symlink to the engine copy is the same project.
ln -s "$TMP/proj-a" "$TMP/link-a"
labels="$(ai_containers_provenance_labels "$TMP/link-a/.ai-containers" 2026-01-01T00:00:00Z)"
grep -qxF "ai-containers.project=$A" <<<"$labels" \
  && pass "the build labels its image with the project's physical path" \
  || fail "no ai-containers.project=$A label (got: $(grep project <<<"$labels"))"

# build.sh runs the guard before it builds, and stops when it refuses: run it
# from an engine copy, against the fake docker, which logs every call.
# shellcheck source=../shared-files.sh
source "$ENGINE/shared-files.sh"
E="$TMP/proj-a/.ai-containers"
for f in "${AI_CONTAINERS_SHARED_FILES[@]}"; do cp -p "$ENGINE/$f" "$E/$f"; done
cp "$ENGINE/sandbox.conf" "$E/sandbox.conf"
for d in tools.d services.d migrations allowlist-domains.d allowlist-proxy-domains.d allowlist-cidrs.d; do
  [[ ! -d "$ENGINE/$d" ]] || cp -R "$ENGINE/$d" "$E/"
done
CALLS="$TMP/calls.log"; export CALLS
for case in foreign "$A"; do
  : > "$CALLS"
  ( cd "$E" && FAKE_INSPECT="$case" IMAGE_NAME=my-image GITHUB_TOKEN='' GITHUB_PERSONAL_ACCESS_TOKEN='' bash ./build.sh ) >"$TMP/out" 2>&1 </dev/null
  rc=$?
  if [[ "$case" == foreign ]]; then
    [[ "$rc" != 0 ]] && ! grep -q '^build ' "$CALLS" && grep -qF "did not build" "$TMP/out" \
      && [[ ! -e "$E/allowlist-domains.txt" ]] \
      && pass "build.sh refuses to build into a foreign tag before it writes anything or runs docker build" \
      || fail "build.sh over a foreign tag (rc $rc; calls: $(tr '\n' ';' < "$CALLS"))"
  else
    grep -q '^build ' "$CALLS" && grep -q -- '--label ai-containers.project=' <<<"$(tr '\n' ' ' < "$CALLS")" \
      && pass "build.sh builds into this project's own tag, stamping the project label" \
      || fail "build.sh over its own tag (rc $rc; calls: $(tr '\n' ';' < "$CALLS" | cut -c1-300))"
  fi
done

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
