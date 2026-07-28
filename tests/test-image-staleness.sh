#!/usr/bin/env bash
# Tests for the image-staleness / agent auto-refresh path in sandbox.sh:
# image_age_hours (portable RFC3339 .Created parsing) and maybe_rebuild_stale_image
# (the staleness-threshold decision matrix and the sandbox.sh -> build.sh handoff).
#
# Uses a fake `docker` on PATH (pattern: tests/test-agents-cache-bust.sh,
# tests/test-docs-path.sh) so no daemon is needed. sandbox.sh has no source
# guard, so it is sourced with no args (hits the safe `usage` branch of its
# entry point) inside a subshell, never in the main test shell, so this
# script's own `set -uo pipefail` and shell options are never clobbered by
# sandbox.sh's `set -euo pipefail`.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Isolated HOME: sandbox-common.sh (sourced by sandbox.sh) reads ~/.ai-containers.
export HOME="$TMP/home"; mkdir -p "$HOME"

# ── Fake docker ──────────────────────────────────────────────────────────────
# State files it reads:
#   $CREATED_FILE   the .Created value `docker image inspect --format '{{.Created}}'`
#                   should echo; if the file is absent, inspect fails (rc=1).
#   $INSPECT_PLAIN_RC  exit code for a plain `docker image inspect <img>` (no
#                      --format), used by maybe_rebuild_stale_image's existence
#                      check. Default 0 (image exists).
make_fake_docker() {
  local bin="$1/bin"; mkdir -p "$bin"
  cat > "$bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
  image)
    shift
    if [[ "$1" == "inspect" ]]; then
      shift
      fmt=""; rest=()
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--format" ]]; then shift; fmt="$1"; shift; else rest+=("$1"); shift; fi
      done
      if [[ -n "$fmt" ]]; then
        # --format form: echo $CREATED_FILE's content, or fail if absent.
        [[ -f "$CREATED_FILE" ]] || exit 1
        cat "$CREATED_FILE"
        exit 0
      else
        # Plain existence check.
        exit "$(cat "$INSPECT_PLAIN_RC" 2>/dev/null || echo 0)"
      fi
    fi
    exit 1
    ;;
  *) exit 0 ;;
esac
FAKE
  chmod +x "$bin/docker"
  printf '%s' "$bin"
}

FAKE_BIN="$(make_fake_docker "$TMP")"
export DOCKER_LOG="$TMP/docker.log"
export CREATED_FILE="$TMP/created.txt"
export INSPECT_PLAIN_RC="$TMP/inspect-plain-rc"
export PATH="$FAKE_BIN:$PATH"

reset_docker_state() {
  : > "$DOCKER_LOG"
  rm -f "$CREATED_FILE"
  printf '0\n' > "$INSPECT_PLAIN_RC"
}

# Source sandbox.sh's function definitions in a subshell (clearing the
# positional params with `set --` FIRST, so sandbox.sh's own
# `command="${1:-usage}"` sees no args and takes the safe `usage` branch of
# its entry point instead of erroring/exiting — it has no source guard).
# Never touches the invoking shell's options or state. Runs from a temp cwd
# so nothing lands in the repo.
# run_fn <fn-name> [args...] — prints stdout, forwards exit status via $?.
run_fn() {
  ( cd "$TMP" && HOME="$HOME" PATH="$PATH" bash -c '
      src="$1"; fn="$2"; shift 2
      fn_args=("$@")
      set --
      source "$src" >/dev/null   # the source-time usage-branch print is noise, not the tested output
      "$fn" "${fn_args[@]}"
    ' _ "$REPO_DIR/sandbox.sh" "$@" )
}

# ══════════════════════════════════════════════════════════════════════════════
# image_age_hours
# ══════════════════════════════════════════════════════════════════════════════

# 1. Nanoseconds + Z
reset_docker_state
now_epoch="$(date -u +%s)"
created_epoch=$(( now_epoch - 5 * 3600 ))
created="$(date -u -d "@${created_epoch}" +'%Y-%m-%dT%H:%M:%S.123456789Z')"
printf '%s\n' "$created" > "$CREATED_FILE"
out="$(run_fn image_age_hours myimg)"; rc=$?
expected=$(( ( $(date -u +%s) - created_epoch ) / 3600 ))
if [[ $rc -eq 0 && "$out" == "$expected" ]]; then
  pass "nanoseconds + Z parses to the correct hour count"
else
  fail "nanoseconds + Z parses to the correct hour count (rc=$rc out='$out' expected='$expected')"
fi

# 2. Without fractional seconds
reset_docker_state
now_epoch="$(date -u +%s)"
created_epoch=$(( now_epoch - 10 * 3600 ))
created="$(date -u -d "@${created_epoch}" +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$created" > "$CREATED_FILE"
out="$(run_fn image_age_hours myimg)"; rc=$?
expected=$(( ( $(date -u +%s) - created_epoch ) / 3600 ))
if [[ $rc -eq 0 && "$out" == "$expected" ]]; then
  pass "no-fractional-seconds timestamp parses to the correct hour count"
else
  fail "no-fractional-seconds timestamp parses to the correct hour count (rc=$rc out='$out' expected='$expected')"
fi

# 3. +00:00 offset form
reset_docker_state
now_epoch="$(date -u +%s)"
created_epoch=$(( now_epoch - 3 * 3600 ))
created="$(date -u -d "@${created_epoch}" +'%Y-%m-%dT%H:%M:%S+00:00')"
printf '%s\n' "$created" > "$CREATED_FILE"
out="$(run_fn image_age_hours myimg)"; rc=$?
expected=$(( ( $(date -u +%s) - created_epoch ) / 3600 ))
if [[ $rc -eq 0 && "$out" == "$expected" ]]; then
  pass "+00:00-offset timestamp parses to the correct hour count"
else
  fail "+00:00-offset timestamp parses to the correct hour count (rc=$rc out='$out' expected='$expected')"
fi

# 4. Fresh timestamp -> age 0
reset_docker_state
created="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$created" > "$CREATED_FILE"
out="$(run_fn image_age_hours myimg)"; rc=$?
check "fresh timestamp -> age 0" "0" "$out"
[[ $rc -eq 0 ]] && pass "fresh timestamp -> rc 0" || fail "fresh timestamp -> rc 0 (rc=$rc)"

# 5. ~87h-old timestamp -> exact hour count, computed from date -u +%s (not hardcoded)
reset_docker_state
now_epoch="$(date -u +%s)"
created_epoch=$(( now_epoch - 87 * 3600 - 90 ))   # a bit past 87h so integer division lands on 87
created="$(date -u -d "@${created_epoch}" +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$created" > "$CREATED_FILE"
out="$(run_fn image_age_hours myimg)"; rc=$?
expected=$(( ( $(date -u +%s) - created_epoch ) / 3600 ))
if [[ $rc -eq 0 && "$out" == "$expected" ]]; then
  pass "~87h-old timestamp computes the exact hour count"
else
  fail "~87h-old timestamp computes the exact hour count (rc=$rc out='$out' expected='$expected')"
fi

# 6. docker image inspect failing (--format call itself fails) -> non-zero, no bogus age
reset_docker_state
rm -f "$CREATED_FILE"   # fake docker: --format inspect fails when this is absent
out="$(run_fn image_age_hours myimg)"; rc=$?
if [[ $rc -ne 0 && -z "$out" ]]; then
  pass "docker image inspect failure -> non-zero, no output"
else
  fail "docker image inspect failure -> non-zero, no output (rc=$rc out='$out')"
fi

# 7. Empty output from docker (inspect succeeds but prints nothing)
reset_docker_state
printf '' > "$CREATED_FILE"
out="$(run_fn image_age_hours myimg)"; rc=$?
if [[ $rc -ne 0 && -z "$out" ]]; then
  pass "empty .Created output -> non-zero, no output"
else
  fail "empty .Created output -> non-zero, no output (rc=$rc out='$out')"
fi

# 8. Unparseable garbage -> non-zero
reset_docker_state
printf 'not-a-timestamp-at-all\n' > "$CREATED_FILE"
out="$(run_fn image_age_hours myimg)"; rc=$?
if [[ $rc -ne 0 ]]; then
  pass "unparseable garbage -> non-zero"
else
  fail "unparseable garbage -> non-zero (rc=$rc out='$out')"
fi

# ══════════════════════════════════════════════════════════════════════════════
# maybe_rebuild_stale_image
# ══════════════════════════════════════════════════════════════════════════════

# run_stale_check [env-assignments...] -- runs maybe_rebuild_stale_image in a
# subshell (no TTY on stdin: redirected from /dev/null so the interactive
# `read ... </dev/tty` branch is never reachable; there is no controlling TTY
# to open in this test either way). Captures stdout/stderr/rc.
run_stale_check() {
  local envs=("$@")
  OUT="$TMP/stale.out"; ERR="$TMP/stale.err"
  ( cd "$TMP" && env "${envs[@]}" bash -c '
      src="$1"; img="$2"; sdir="$3"
      set --
      source "$src" >/dev/null   # the source-time usage-branch print is noise, not the tested output
      image_name="$img"; script_dir="$sdir"
      maybe_rebuild_stale_image
    ' _ "$REPO_DIR/sandbox.sh" "$IMG" "$SCRIPT_DIR_ARG"
  ) </dev/null >"$OUT" 2>"$ERR"
  RC=$?
}

IMG="ai-sandbox-test"
SCRIPT_DIR_ARG="$REPO_DIR"   # only used for the actual-rebuild case; overridden there

# ── Threshold disabled by each documented word ──────────────────────────────
# (sandbox.sh: case "${max_age,,}" in 0|off|never|no|false|disabled) return 0 ;; esac)
for word in 0 off never no false disabled OFF Never DISABLED; do
  reset_docker_state
  # No CREATED_FILE and inspect-plain would succeed -- if the check ran past the
  # disable case it would try to compute an age; assert it never gets that far.
  run_stale_check AGENT_REBUILD_MAX_AGE_HOURS="$word"
  if [[ $RC -eq 0 && -z "$(cat "$OUT")" && -z "$(cat "$ERR")" && ! -s "$DOCKER_LOG" ]]; then
    pass "AGENT_REBUILD_MAX_AGE_HOURS=$word disables the check (no prompt, no docker calls)"
  else
    fail "AGENT_REBUILD_MAX_AGE_HOURS=$word disables the check (rc=$RC out='$(cat "$OUT")' err='$(cat "$ERR")' dockerlog='$(cat "$DOCKER_LOG")')"
  fi
done

# ── Non-integer threshold -> warning + skip, still returns 0 ───────────────
reset_docker_state
run_stale_check AGENT_REBUILD_MAX_AGE_HOURS="banana"
if [[ $RC -eq 0 ]] && grep -q 'is not a non-negative integer; skipping staleness check' "$ERR" && [[ ! -s "$DOCKER_LOG" ]]; then
  pass "non-integer threshold warns, skips, and returns 0"
else
  fail "non-integer threshold warns, skips, and returns 0 (rc=$RC err='$(cat "$ERR")' dockerlog='$(cat "$DOCKER_LOG")')"
fi

# ── Image missing entirely -> NOTE, no build ────────────────────────────────
reset_docker_state
printf '1\n' > "$INSPECT_PLAIN_RC"   # `docker image inspect <img>` (no format) fails
run_stale_check AGENT_REBUILD_MAX_AGE_HOURS=72
if [[ $RC -eq 0 ]] && grep -q "NOTE: image \"$IMG\" not found" "$ERR" && ! grep -q '^build ' "$DOCKER_LOG"; then
  pass "missing image -> NOTE, no build"
else
  fail "missing image -> NOTE, no build (rc=$RC err='$(cat "$ERR")' dockerlog='$(cat "$DOCKER_LOG")')"
fi

# ── Age below threshold -> silent, no build ─────────────────────────────────
reset_docker_state
created="$(date -u -d "@$(( $(date -u +%s) - 10 * 3600 ))" +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$created" > "$CREATED_FILE"
run_stale_check AGENT_REBUILD_MAX_AGE_HOURS=72
if [[ $RC -eq 0 && -z "$(cat "$OUT")" && -z "$(cat "$ERR")" ]] && ! grep -q '^build ' "$DOCKER_LOG"; then
  pass "age below threshold -> silent, no build"
else
  fail "age below threshold -> silent, no build (rc=$RC out='$(cat "$OUT")' err='$(cat "$ERR")')"
fi

# ── Age >= threshold, non-TTY, no AGENT_REBUILD_ACK -> warns and continues, no build ──
reset_docker_state
created="$(date -u -d "@$(( $(date -u +%s) - 100 * 3600 ))" +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$created" > "$CREATED_FILE"
run_stale_check AGENT_REBUILD_MAX_AGE_HOURS=72
if [[ $RC -eq 0 ]] \
   && grep -q "is .* hour(s) old" "$ERR" \
   && grep -q 'Skipping rebuild (no TTY and AGENT_REBUILD_ACK != 1)' "$ERR" \
   && ! grep -q '^build ' "$DOCKER_LOG"; then
  pass "stale, non-TTY, no ACK -> warns and continues, no build"
else
  fail "stale, non-TTY, no ACK -> warns and continues, no build (rc=$RC err='$(cat "$ERR")' dockerlog='$(cat "$DOCKER_LOG")')"
fi

# ── Age == threshold exactly (boundary) also triggers (age < max_age is the only skip) ──
reset_docker_state
created="$(date -u -d "@$(( $(date -u +%s) - 72 * 3600 - 5 ))" +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$created" > "$CREATED_FILE"
run_stale_check AGENT_REBUILD_MAX_AGE_HOURS=72
if [[ $RC -eq 0 ]] && grep -q 'Skipping rebuild (no TTY and AGENT_REBUILD_ACK != 1)' "$ERR"; then
  pass "age at threshold boundary triggers the stale path"
else
  fail "age at threshold boundary triggers the stale path (err='$(cat "$ERR")')"
fi

# ── Age >= threshold, WITH AGENT_REBUILD_ACK=1 -> rebuilds, passing a fresh
#    numeric AGENTS_CACHE_BUST to build.sh (the sandbox.sh -> build.sh handoff) ──
# Throwaway repo copy with build.sh stubbed so we capture its argv/env without
# running the real build logic (mirrors tests/test-agents-cache-bust.sh's isolation).
REBUILD_REPO="$TMP/rebuild-repo"; mkdir -p "$REBUILD_REPO"
cp "$REPO_DIR/sandbox.sh" "$REBUILD_REPO/sandbox.sh"
cp "$REPO_DIR/sandbox-common.sh" "$REBUILD_REPO/sandbox-common.sh"
cp "$REPO_DIR/tools-lib.sh" "$REBUILD_REPO/tools-lib.sh"
BUILD_CAPTURE="$TMP/build-capture.txt"
cat > "$REBUILD_REPO/build.sh" <<STUB
#!/usr/bin/env bash
{
  printf 'ARGS:%s\n' "\$*"
  printf 'AGENTS_CACHE_BUST=%s\n' "\${AGENTS_CACHE_BUST:-<unset>}"
} > "$BUILD_CAPTURE"
exit 0
STUB
chmod +x "$REBUILD_REPO/build.sh"

reset_docker_state
created="$(date -u -d "@$(( $(date -u +%s) - 100 * 3600 ))" +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$created" > "$CREATED_FILE"
before_epoch="$(date -u +%s)"
( cd "$TMP" && HOME="$HOME" PATH="$FAKE_BIN:$PATH" AGENT_REBUILD_MAX_AGE_HOURS=72 AGENT_REBUILD_ACK=1 bash -c '
    src="$1"; img="$2"; sdir="$3"
    set --
    source "$src" >/dev/null   # the source-time usage-branch print is noise, not the tested output
    image_name="$img"; script_dir="$sdir"
    maybe_rebuild_stale_image
  ' _ "$REBUILD_REPO/sandbox.sh" "$IMG" "$REBUILD_REPO"
) </dev/null >"$TMP/ack.out" 2>"$TMP/ack.err"
ACK_RC=$?
after_epoch="$(date -u +%s)"

if [[ $ACK_RC -eq 0 ]] && grep -q 'Refreshing AI agents via targeted rebuild' "$TMP/ack.err"; then
  pass "AGENT_REBUILD_ACK=1 performs the rebuild"
else
  fail "AGENT_REBUILD_ACK=1 performs the rebuild (rc=$ACK_RC err='$(cat "$TMP/ack.err")')"
fi

if [[ -f "$BUILD_CAPTURE" ]]; then
  build_args="$(grep '^ARGS:' "$BUILD_CAPTURE" | cut -d: -f2-)"
  bust_line="$(grep '^AGENTS_CACHE_BUST=' "$BUILD_CAPTURE" | cut -d= -f2)"
  check "build.sh is invoked with the image name as its argument" "$IMG" "$build_args"
  if [[ "$bust_line" =~ ^[0-9]+$ ]] && (( bust_line >= before_epoch && bust_line <= after_epoch )); then
    pass "build.sh receives a fresh numeric AGENTS_CACHE_BUST"
  else
    fail "build.sh receives a fresh numeric AGENTS_CACHE_BUST (got '$bust_line', window [$before_epoch,$after_epoch])"
  fi
else
  fail "build.sh is invoked with the image name as its argument (build.sh stub never ran)"
  fail "build.sh receives a fresh numeric AGENTS_CACHE_BUST (build.sh stub never ran)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Hermeticity
# ══════════════════════════════════════════════════════════════════════════════

if [[ -e "$REPO_DIR/.agent-blocked" || -e "$REPO_DIR/.agent-discovery" ]]; then
  fail "real repo untouched (found .agent-blocked/.agent-discovery in $REPO_DIR)"
else
  pass "real repo untouched"
fi

if [[ -e "${_REAL_HOME:-/nonexistent-marker}/.ai-containers/__test_marker__" ]]; then
  fail "real ~/.ai-containers untouched"
else
  pass "real ~/.ai-containers untouched (isolated HOME was used throughout)"
fi

printf '\n%s failure(s)\n' "$fails"
(( fails == 0 )) || exit 1
