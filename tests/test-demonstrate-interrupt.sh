#!/usr/bin/env bash
# tests/test-demonstrate-interrupt.sh — Ctrl-C stops
# demonstrate-network-delivery-tiers.sh (TST-13).
#
# It ran `trap cleanup EXIT INT TERM` with a cleanup() that never exits, as
# demonstrate-needs-rebuild.sh did. bash resumes after a handler for a trapped
# signal returns, so an interrupt reverted the mutation and then went on to the
# next patch. test-demonstrate-needs-rebuild.sh checks the other demonstrator;
# this one had no test.
#
# The demonstrator runs in a SCRATCH COPY of the tree, for the reason
# test-demonstrate-needs-rebuild.sh gives. mutate.sh is a stub that succeeds,
# and run.sh answers the harness selftest at once but "runs" every other case
# by sleeping, which is the window the interrupt lands in. The INT goes to the
# demonstrator's whole process group, as a terminal's Ctrl-C does.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/build.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# ── the scratch copy, with mutate.sh and run.sh stubbed ───────────────────────
COPY="$TMP/repo"
LOG="$TMP/calls.log"
rel_engine="${ENGINE_DIR#"$REPO_DIR"}"
mkdir -p "$COPY/tests" "$COPY$rel_engine" \
  && cp -R "$REPO_DIR/tests/integration" "$COPY/tests/" \
  && cp "$ENGINE_DIR/Dockerfile" "$ENGINE_DIR/build.sh" "$COPY$rel_engine/" \
  || { printf 'SCAFFOLD-FAILED: could not copy the integration tree into %s\n' "$COPY"; exit 1; }
printf '#!/usr/bin/env bash\nprintf "MUT %%s\\n" "$*" >> "%s"\n' "$LOG" \
  > "$COPY/tests/integration/mutate.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'printf "RUN %%s\\n" "$*" >> "%s"\n' "$LOG"
  printf '[[ " $* " == *" 000-harness-selftest "* ]] && exit 0\n'
  printf 'sleep 30\n'
} > "$COPY/tests/integration/run.sh"
( cd "$COPY" \
    && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
    && git add -A && git -c user.email=t@example -c user.name=t commit -q -m copy ) >/dev/null 2>&1 \
  || { printf 'SCAFFOLD-FAILED: could not commit the scratch copy (the demonstrators refuse a dirty tree)\n'; exit 1; }
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nprintf "DOCKER %%s\\n" "$*" >> "%s"\n' "$LOG" > "$TMP/bin/docker"
chmod +x "$TMP/bin/docker"

case_runs() { grep '^RUN ' "$LOG" 2>/dev/null | grep -vc '000-harness-selftest'; }

# $1 = demonstrator, $2… = its selection, which must pick at least two patches
interrupt_check() {
  local demo="$1"; shift
  local name; name="$(basename "$demo" .sh)"
  : > "$LOG"
  set -m
  ( cd "$COPY" && PATH="$TMP/bin:$PATH" exec bash "$demo" "$@" ) >"$TMP/$name.out" 2>&1 &
  local pid=$!
  set +m
  local i
  for (( i = 0; i < 200; i++ )); do
    [[ "$(case_runs)" -ge 1 ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if [[ "$(case_runs)" -lt 1 ]]; then
    kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail "$name: SCAFFOLD — no case ever started (output: $(tail -3 "$TMP/$name.out" | tr '\n' ' '))"
    return
  fi
  kill -INT -- "-$pid"
  for (( i = 0; i < 100; i++ )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail "$name: exits within 10 s of Ctrl-C (it was still running)"
    return
  fi
  wait "$pid"; local rc=$?
  # Its own header says how many patches it selected; with one, "no case starts
  # after Ctrl-C" would hold whether or not the interrupt stopped anything.
  local selected
  selected="$(grep -oE 'Demonstrating [0-9]+' "$TMP/$name.out" | grep -oE '[0-9]+$')"
  if [[ "${selected:-0}" -lt 2 ]]; then
    fail "$name: the selection holds at least two patches (got ${selected:-none})"
    return
  fi
  [[ "$rc" == 130 ]] && pass "$name: Ctrl-C exits 130" || fail "$name: Ctrl-C exits 130 (got $rc)"
  local n; n="$(case_runs)"
  [[ "$n" == 1 ]] && pass "$name: no case starts after Ctrl-C" \
    || fail "$name: no case starts after Ctrl-C ($n cases ran)"
  grep -q '^MUT revert' "$LOG" && pass "$name: the interrupt still reverts the mutation" \
    || fail "$name: the interrupt still reverts the mutation"
}

interrupt_check "$COPY/tests/integration/demonstrate-network-delivery-tiers.sh"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
