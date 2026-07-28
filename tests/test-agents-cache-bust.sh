#!/usr/bin/env bash
# Tests for the persisted agent cache-bust token and the replaced-image cleanup.
#
# Covers the regression this machinery exists for: docker's build cache is keyed
# by build-arg VALUE, so after a targeted agent refresh a later plain ./build.sh
# using the old default (0) cache-hits the PRE-refresh image and moves the tag
# back onto it — undoing the refresh and making sandbox.sh's staleness prompt
# reappear on every launch. build.sh must therefore reuse the persisted token.
#
# Uses a fake `docker` on PATH to capture the assembled `docker build` args and
# to simulate image IDs without a daemon.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# ── Fake docker ────────────────────────────────────────────────────────────────
# State files it reads/writes:
#   $DOCKER_LOG        every invocation, one line per call
#   $IMAGE_ID_FILE     current image ID for the tag ("" = tag does not exist)
#   $NEXT_IMAGE_ID     ID the next successful `build` assigns to the tag
#   $REPO_TAGS         value returned for '{{len .RepoTags}}'
#   $BUILD_RC          exit status for `build` (default 0)
#   $RMI_RC            exit status for `rmi` (default 0)
make_fake_docker() {
  local bin="$1/bin"; mkdir -p "$bin"
  cat > "$bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
  build)
    rc="$(cat "$BUILD_RC" 2>/dev/null || echo 0)"
    if [[ "$rc" == "0" ]]; then cat "$NEXT_IMAGE_ID" > "$IMAGE_ID_FILE"; fi
    exit "$rc"
    ;;
  image)
    # image inspect --format '<fmt>' <ref> — find the value after --format.
    fmt=""; prev=""
    for a in "$@"; do
      if [[ "$prev" == "--format" ]]; then fmt="$a"; break; fi
      prev="$a"
    done
    case "$fmt" in
      *RepoTags*) cat "$REPO_TAGS" 2>/dev/null || echo 0; exit 0 ;;
      *)
        id="$(cat "$IMAGE_ID_FILE" 2>/dev/null || true)"
        [[ -n "$id" ]] || exit 1
        printf '%s\n' "$id"
        exit 0
        ;;
    esac
    ;;
  rmi) exit "$(cat "$RMI_RC" 2>/dev/null || echo 0)" ;;
  *) exit 0 ;;
esac
FAKE
  chmod +x "$bin/docker"
  printf '%s' "$bin"
}

# A throwaway copy of the repo so builds write .agents-cache-bust there, never
# into the real tree (mirrors tests/test-project-init.sh's isolation rationale).
new_repo() {
  local d="$TMP/repo-$1"; mkdir -p "$d"
  rsync -a --exclude='.git' --exclude='tests' --exclude='docs' \
        --exclude='.agents-cache-bust' "$REPO_DIR"/ "$d/"
  printf '%s' "$d"
}

# run_build <repo> [env assignments...] -- [build.sh args...]
run_build() {
  local repo="$1"; shift
  local envs=() args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then shift; args=("$@"); break; fi
    envs+=("$1"); shift
  done
  ( cd "$repo" && PATH="$FAKE_BIN:$PATH" env "${envs[@]}" bash ./build.sh "${args[@]}" ) \
    >>"$TMP/build.out" 2>>"$TMP/build.err"
}

bust_arg() { # last AGENTS_CACHE_BUST value seen by docker build
  grep -o 'AGENTS_CACHE_BUST=[0-9]*' "$DOCKER_LOG" | tail -1 | cut -d= -f2
}

FAKE_BIN="$(make_fake_docker "$TMP")"
export DOCKER_LOG="$TMP/docker.log"
export IMAGE_ID_FILE="$TMP/image-id"
export NEXT_IMAGE_ID="$TMP/next-image-id"
export REPO_TAGS="$TMP/repo-tags"
export BUILD_RC="$TMP/build-rc"
export RMI_RC="$TMP/rmi-rc"
reset_state() {
  : > "$DOCKER_LOG"; : > "$IMAGE_ID_FILE"
  printf 'sha256:aaaaaaaaaaaa000000\n' > "$NEXT_IMAGE_ID"
  printf '0\n' > "$REPO_TAGS"; printf '0\n' > "$BUILD_RC"; printf '0\n' > "$RMI_RC"
}

# ── 1. First build: no token file → 0, and the token is persisted ──────────────
reset_state
R="$(new_repo first)"
run_build "$R"
check "first build passes AGENTS_CACHE_BUST=0" "0" "$(bust_arg)"
check "first build persists the token" "0" "$(cat "$R/.agents-cache-bust" 2>/dev/null | tr -d '[:space:]')"

# ── 2. Persisted token is reused by a plain build (the actual regression) ──────
reset_state
R="$(new_repo reuse)"
printf '1770000000\n' > "$R/.agents-cache-bust"
run_build "$R"
check "plain build reuses the persisted token instead of 0" "1770000000" "$(bust_arg)"

# ── 3. Explicit AGENTS_CACHE_BUST wins and replaces the persisted token ───────
reset_state
R="$(new_repo explicit)"
printf '1770000000\n' > "$R/.agents-cache-bust"
run_build "$R" AGENTS_CACHE_BUST=1888888888
check "explicit token wins" "1888888888" "$(bust_arg)"
check "explicit token is persisted" "1888888888" "$(cat "$R/.agents-cache-bust" | tr -d '[:space:]')"

# ── 4. --no-cache mints a FRESH token (that build refreshes the agents) ───────
reset_state
R="$(new_repo nocache)"
printf '1770000000\n' > "$R/.agents-cache-bust"
now="$(date -u +%s)"
run_build "$R" -- --no-cache
minted="$(bust_arg)"
if [[ "$minted" =~ ^[0-9]+$ ]] && (( minted >= now )); then
  pass "--no-cache mints a fresh token"
else
  fail "--no-cache mints a fresh token (got '$minted', now=$now)"
fi
check "--no-cache persists the minted token" "$minted" "$(cat "$R/.agents-cache-bust" | tr -d '[:space:]')"
grep -q -- '--no-cache' "$DOCKER_LOG" && pass "--no-cache reaches docker build" \
                                      || fail "--no-cache reaches docker build"

# ── 5. NO_CACHE=1 env behaves like the flag ──────────────────────────────────
reset_state
R="$(new_repo nocache-env)"
printf '5\n' > "$R/.agents-cache-bust"
run_build "$R" NO_CACHE=1
minted="$(bust_arg)"
if [[ "$minted" != "5" ]] && (( minted > 5 )); then
  pass "NO_CACHE=1 mints a fresh token too"
else
  fail "NO_CACHE=1 mints a fresh token too (got '$minted')"
fi

# ── 6. A FAILED build must not persist the token ─────────────────────────────
reset_state
R="$(new_repo failed)"
printf '7\n' > "$R/.agents-cache-bust"
printf '1\n' > "$BUILD_RC"
run_build "$R" AGENTS_CACHE_BUST=9999999999
check "failed build leaves the persisted token untouched" "7" "$(cat "$R/.agents-cache-bust" | tr -d '[:space:]')"

# ── 7. Replaced-image cleanup ────────────────────────────────────────────────
# shellcheck disable=SC1090
( reset_state
  cd "$TMP" && PATH="$FAKE_BIN:$PATH"
  source "$REPO_DIR/sandbox-common.sh"

  out="$(remove_replaced_image "sha256:oldoldoldold111" "sha256:newnewnewnew222" 2>&1)"
  grep -q 'Removed the image this build replaced (oldoldoldol' <<<"$out" \
    && printf 'PASS: untagged predecessor is removed\n' \
    || printf 'FAIL: untagged predecessor is removed (%s)\n' "$out"
  grep -q 'docker builder prune' <<<"$out" \
    && printf 'PASS: prune hint printed\n' || printf 'FAIL: prune hint printed\n'
  grep -q '^rmi sha256:oldoldoldold111$' "$DOCKER_LOG" \
    && printf 'PASS: rmi targets the single old ID without --force\n' \
    || printf 'FAIL: rmi targets the single old ID without --force\n'

  : > "$DOCKER_LOG"
  remove_replaced_image "sha256:same111" "sha256:same111" 2>/dev/null
  grep -q '^rmi' "$DOCKER_LOG" \
    && printf 'FAIL: unchanged image must not be removed\n' \
    || printf 'PASS: unchanged image must not be removed\n'

  : > "$DOCKER_LOG"
  remove_replaced_image "" "sha256:new222" 2>/dev/null
  grep -q '^rmi' "$DOCKER_LOG" \
    && printf 'FAIL: absent predecessor must not be removed\n' \
    || printf 'PASS: absent predecessor must not be removed\n'

  : > "$DOCKER_LOG"; printf '2\n' > "$REPO_TAGS"
  out="$(remove_replaced_image "sha256:tagged333" "sha256:new222" 2>&1)"
  if grep -q '^rmi' "$DOCKER_LOG"; then
    printf 'FAIL: still-tagged predecessor must be kept\n'
  else
    grep -q 'still carries a tag' <<<"$out" \
      && printf 'PASS: still-tagged predecessor is kept\n' \
      || printf 'FAIL: still-tagged predecessor is kept (%s)\n' "$out"
  fi

  : > "$DOCKER_LOG"; printf '0\n' > "$REPO_TAGS"; printf '1\n' > "$RMI_RC"
  out="$(remove_replaced_image "sha256:inuse444" "sha256:new222" 2>&1)"
  grep -q 'could not remove the replaced image' <<<"$out" \
    && printf 'PASS: in-use predecessor failure is non-fatal and reported\n' \
    || printf 'FAIL: in-use predecessor failure is non-fatal and reported (%s)\n' "$out"
) > "$TMP/cleanup.out" 2>&1
cat "$TMP/cleanup.out"
fails=$(( fails + $(grep -c '^FAIL' "$TMP/cleanup.out") ))

# ── 8. The real repo was never written to ────────────────────────────────────
if [[ -e "$REPO_DIR/.agents-cache-bust" ]]; then
  fail "tests must not create .agents-cache-bust in the real repo"
else
  pass "real repo untouched"
fi

# ── 9. An unwritable location warns instead of failing the build ─────────────
( ro="$TMP/readonly"; mkdir -p "$ro"; chmod 500 "$ro"
  cd "$TMP" && PATH="$FAKE_BIN:$PATH"
  # shellcheck disable=SC1090
  source "$REPO_DIR/sandbox-common.sh"
  agents_cache_bust_file="$ro/.agents-cache-bust"
  out="$(write_agents_cache_bust 12345 2>&1)"; rc=$?
  chmod 700 "$ro"
  if (( rc == 0 )) && grep -q 'could not persist the agent cache-bust token' <<<"$out"; then
    printf 'PASS: unwritable token file warns without failing\n'
  else
    printf 'FAIL: unwritable token file warns without failing (rc=%s, out=%s)\n' "$rc" "$out"
  fi
) > "$TMP/ro.out" 2>&1
cat "$TMP/ro.out"
fails=$(( fails + $(grep -c '^FAIL' "$TMP/ro.out") ))

# ── 10. A pathological token file degrades to 0, it does not leak ────────────
( cd "$TMP" && PATH="$FAKE_BIN:$PATH"
  # shellcheck disable=SC1090
  source "$REPO_DIR/sandbox-common.sh"
  agents_cache_bust_file="$TMP/junk-token"
  printf 'not-a-number\n' > "$agents_cache_bust_file"
  [[ "$(read_agents_cache_bust)" == "0" ]] \
    && printf 'PASS: non-numeric token reads as 0\n' || printf 'FAIL: non-numeric token reads as 0\n'
  printf '  1770000000 \n\n' > "$agents_cache_bust_file"
  [[ "$(read_agents_cache_bust)" == "1770000000" ]] \
    && printf 'PASS: surrounding whitespace is tolerated\n' || printf 'FAIL: surrounding whitespace is tolerated\n'
  head -c 200000 /dev/zero | tr '\0' '9' > "$agents_cache_bust_file"
  v="$(read_agents_cache_bust)"
  [[ ${#v} -gt 1 || "$v" == "0" ]] \
    && printf 'PASS: oversized token does not crash the reader\n' || printf 'FAIL: oversized token does not crash the reader\n'
) > "$TMP/junk.out" 2>&1
cat "$TMP/junk.out"
fails=$(( fails + $(grep -c '^FAIL' "$TMP/junk.out") ))

printf '\n%s failure(s)\n' "$fails"
(( fails == 0 )) || exit 1
