#!/usr/bin/env bash
# Tests for remove_replaced_image() (sandbox-common.sh): what build.sh does with
# the image a successful rebuild just replaced.
#
# A fake `docker` on PATH answers `image inspect` and `rmi` the way each daemon
# does, chosen per case by FAKE_INSPECT:
#   gone29   Docker 29 with an image that no longer exists: an EMPTY LINE on
#            stdout and exit 1. That line is the bug this file exists for: read
#            through `$(inspect || printf 0)` it became "\n0", not "0", and every
#            rebuild on Docker Desktop's containerd image store (which deletes
#            the image as the build moves its tag) reported a tag it did not have.
#   gone     an older CLI: nothing on stdout, exit 1
#   <n>      the image exists and carries n tags
# FAKE_RMI_RC is what `docker rmi` exits with. Every call is logged, so a case
# can tell that nothing was removed, not just that nothing was printed.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$REPO_DIR/sandbox-common.sh"

CALLS="$TMP/calls.log"; export CALLS
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "image inspect")
    case "$FAKE_INSPECT" in
      gone29) printf '\n'; exit 1 ;;
      gone)   exit 1 ;;
      *)      printf '%s\n' "$FAKE_INSPECT"; exit 0 ;;
    esac ;;
  "rmi "*) exit "${FAKE_RMI_RC:-0}" ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

OLD="sha256:5f5b6cf7db8c0123456789abcdef0123456789abcdef0123456789abcdef0123"
NEW="sha256:92b3ba4a4a8d0123456789abcdef0123456789abcdef0123456789abcdef0123"

# run_case INSPECT RMI_RC OLD NEW → sets $err (stderr) and $calls (the docker calls)
run_case() {
  : > "$CALLS"
  err="$(FAKE_INSPECT="$1" FAKE_RMI_RC="$2" remove_replaced_image "$3" "$4" 2>&1 >/dev/null)"
  calls="$(cat "$CALLS")"
}

# ── Already gone, Docker 29 style: no NOTE, no rmi, the cache tip still shown ──
run_case gone29 0 "$OLD" "$NEW"
[[ "$err" != *"still carries a tag"* ]] && pass "an image Docker 29 says is gone is not reported as tagged" \
  || fail "an image Docker 29 says is gone is not reported as tagged: $err"
[[ "$calls" != *rmi* ]] && pass "an image already gone is not removed again" || fail "an image already gone is not removed again: $calls"
[[ "$err" != *NOTE* ]] && pass "an image already gone gets no NOTE at all" || fail "an image already gone gets no NOTE at all: $err"
[[ "$err" == *"docker builder prune"* ]] && pass "the build-cache tip is still printed" || fail "the build-cache tip is still printed: $err"

# ── Already gone, older CLI (nothing on stdout) ──
run_case gone 0 "$OLD" "$NEW"
[[ "$err" != *NOTE* && "$calls" != *rmi* ]] && pass "an image an older CLI says is gone gets no NOTE and no rmi" \
  || fail "an image an older CLI says is gone gets no NOTE and no rmi: $err / $calls"

# ── Still tagged: left in place, by name ──
run_case 1 0 "$OLD" "$NEW"
[[ "$err" == *"the replaced image 5f5b6cf7db8c still carries a tag"* ]] && pass "an image that still carries a tag is named and left" \
  || fail "an image that still carries a tag is named and left: $err"
[[ "$calls" != *rmi* ]] && pass "an image that still carries a tag is not removed" || fail "an image that still carries a tag is not removed: $calls"

# ── Untagged: removed, by its full ID, without --force ──
run_case 0 0 "$OLD" "$NEW"
[[ "$err" == *"Removed the image this build replaced (5f5b6cf7db8c)"* ]] && pass "an untagged replaced image is removed" \
  || fail "an untagged replaced image is removed: $err"
grep -qxF "rmi $OLD" <<< "$calls" && pass "rmi names the full image ID and no --force" || fail "rmi names the full image ID and no --force: $calls"

# ── Untagged but a container still uses it: rmi fails, kept, said so ──
run_case 0 1 "$OLD" "$NEW"
[[ "$err" == *"could not remove the replaced image 5f5b6cf7db8c"* ]] && pass "an image rmi refuses is reported, not hidden" \
  || fail "an image rmi refuses is reported, not hidden: $err"

# ── Nothing replaced: same ID, or no image before the build ──
run_case 0 0 "$OLD" "$OLD"
[[ -z "$err" && -z "$calls" ]] && pass "an unchanged image ID touches nothing" || fail "an unchanged image ID touches nothing: $err / $calls"
run_case 0 0 "" "$NEW"
[[ -z "$err" && -z "$calls" ]] && pass "a first build (no previous image) touches nothing" || fail "a first build touches nothing: $err / $calls"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
