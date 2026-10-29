#!/usr/bin/env bash
# tests/test-install-node-lts.sh — the nvm layer's install loop, run against a
# fake installer and a fake nvm, so each path is driven rather than read: the
# newest LTS installs; it is listed but unpublished (nvm: "Provided checksum to
# compare to is empty."), and the LTS release before it is the default (bugs
# review BLD-9); any other failure is retried and fails the build; nvm itself
# does not install, and the build fails.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/install-node-lts.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"; trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

# The fake installer counts its runs in $RUNS and logs what it found, then
# writes $NVM_DIR/nvm.sh, whose `nvm` logs each call to $LOG.
#   FAKE_INSTALLER_FAILS=N  the first N runs fail, leaving debris behind them
#   FAKE_LTS=ok|unpublished|other   how `nvm install --lts` ends
#   FAKE_PREV_FAILS         any other `nvm install` fails
#   FAKE_LIST=newline|patch the LTS list: a line's first LTS release is the
#                           newest, or a patch release of the current line is
LOG="$TMP/calls"; RUNS="$TMP/runs"; SEEN="$TMP/seen"
cat > "$TMP/installer.sh" <<'INST'
n=$(( $(cat "$RUNS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$RUNS"
printf 'run %s: profile=%s debris=%s\n' "$n" "${PROFILE:-unset}" "$([ -e "$NVM_DIR/.git/debris" ] && echo yes || echo no)" >> "$SEEN"
if [ "$n" -le "${FAKE_INSTALLER_FAILS:-0}" ]; then mkdir -p "$NVM_DIR/.git"; : > "$NVM_DIR/.git/debris"; exit 1; fi
cat > "$NVM_DIR/nvm.sh" <<'NVM'
nvm() {
  printf '%s\n' "$*" >> "$LOG"
  case "$1 ${2:-}" in
    "install --lts")
      case "${FAKE_LTS:-ok}" in
        ok) return 0 ;;
        unpublished) printf 'Computing checksum with sha256sum\nProvided checksum to compare to is empty.\nBinary download failed, trying source.\n' >&2; return 3 ;;
        *) printf 'Checksums do not match.\n' >&2; return 3 ;;
      esac ;;
    "install "*)     [ -z "${FAKE_PREV_FAILS:-}" ] ;;
    "alias default") return 0 ;;
    "ls-remote --lts")
      # Out of order on purpose, with v8/v10 and 24.9/24.10: a plain sort or
      # nvm's own order would pick the wrong one.
      printf '       v24.10.0   (LTS: Krypton)\n       v8.17.0   (LTS: Carbon)\n'
      printf '       v24.9.0   (LTS: Krypton)\n       v10.24.1   (LTS: Dubnium)\n       v22.21.0   (LTS: Jod)\n'
      if [ "${FAKE_LIST:-newline}" = patch ]; then
        printf '       v24.22.2   (LTS: Krypton)\n->     v24.22.3 * (Latest LTS: Krypton)\n'
      else
        printf '%s\n' '->     v26.13.0 * (Latest LTS: Lithium)'   # %s: a format starting with - is an option
      fi ;;
    *) return 9 ;;
  esac
}
NVM
INST

run() {  # env assignments as arguments → RC, OUT
  : > "$LOG"; : > "$SEEN"; rm -f "$RUNS"
  OUT="$(env "$@" LOG="$LOG" RUNS="$RUNS" SEEN="$SEEN" NVM_DIR="$TMP/nvm" AI_NODE_SLEEP=0 bash "$SCRIPT" "$TMP/installer.sh" 2>&1)"; RC=$?
}
calls() { tr '\n' ';' < "$LOG"; }
lts_calls() { grep -c '^install --lts$' "$LOG"; }

run
if [[ "$RC" == 0 ]] && grep -qx 'install --lts' "$LOG" && grep -qx "alias default lts/\*" "$LOG" && [[ "$OUT" != *WARNING* ]]; then
  pass "the newest LTS installs and is the default, with no warning"
else fail "the plain path (rc $RC; calls: $(calls); $OUT)"; fi
grep -qx 'run 1: profile=/dev/null debris=no' "$SEEN" && pass "  … and the installer runs with PROFILE=/dev/null" \
  || fail "  … the installer's PROFILE ($(cat "$SEEN"))"

# A new line's first LTS release listed but unpublished: after the second such
# failure, the previous line's newest release, v24.10.0 (not v24.9.0, not v8).
run FAKE_LTS=unpublished
if [[ "$RC" == 0 && "$(lts_calls)" == 2 ]] && grep -qx 'install v24.10.0' "$LOG" && grep -qx 'alias default v24.10.0' "$LOG" \
   && [[ "$OUT" == *"WARNING: the newest Node LTS is listed but its checksums are not published yet"*"v24.10.0"*"--no-cache"* ]]; then
  pass "a new LTS line not yet published: the previous line's newest release is the default, with a warning"
else fail "the new-line fallback (rc $RC; calls: $(calls); $OUT)"; fi
# A patch release of the current line unpublished: the same line's previous one.
run FAKE_LTS=unpublished FAKE_LIST=patch
grep -qx 'alias default v24.22.2' "$LOG" && [[ "$RC" == 0 ]] \
  && pass "a patch release not yet published: the same line's previous release is the default" \
  || fail "the patch fallback (rc $RC; calls: $(calls); $OUT)"
# It counts unpublished --lts failures, not attempts: two failed clones, then one
# unpublished failure is not yet a fallback; the second one is.
run FAKE_INSTALLER_FAILS=2 FAKE_LTS=unpublished
if [[ "$RC" == 0 && "$(lts_calls)" == 2 && "$(cat "$RUNS")" == 4 ]] && grep -qx 'alias default v24.10.0' "$LOG"; then
  pass "  … after two unpublished failures, however many attempts the clone took"
else fail "the fallback's count (rc $RC; runs $(cat "$RUNS"); calls: $(calls); $OUT)"; fi

# Any other failure is no fallback: a mismatched checksum is an integrity signal.
run FAKE_LTS=other AI_NODE_ATTEMPTS=4
if [[ "$RC" == 1 && "$(lts_calls)" == 4 && "$OUT" == *"failed after 4 attempts"* ]] && ! grep -q '^install v' "$LOG"; then
  pass "any other --lts failure is retried and fails the build, with no fallback"
else fail "another --lts failure (rc $RC; calls: $(calls); $OUT)"; fi
run FAKE_LTS=unpublished FAKE_PREV_FAILS=1 AI_NODE_ATTEMPTS=4
[[ "$RC" == 1 && "$OUT" == *"failed after 4 attempts"* ]] \
  && pass "when the fallback will not install either, the build fails" || fail "both fail (rc $RC; calls: $(calls); $OUT)"
run FAKE_INSTALLER_FAILS=9 AI_NODE_ATTEMPTS=4
if [[ "$RC" == 1 && ! -s "$LOG" && "$OUT" == *"failed after 4 attempts"* ]]; then
  pass "when nvm itself will not install, no Node is tried, and the build fails"
else fail "the installer fails (rc $RC; calls: $(calls); $OUT)"; fi

# A clean slate per attempt: the first run leaves debris and fails; the second
# must not find it.
run FAKE_INSTALLER_FAILS=1
if [[ "$RC" == 0 ]] && grep -qx 'run 2: profile=/dev/null debris=no' "$SEEN"; then
  pass "each attempt starts from an empty NVM_DIR"
else fail "the clean slate ($(tr '\n' ';' < "$SEEN"))"; fi

run2=0; OUT="$(bash "$SCRIPT" 2>&1)" || run2=$?
[[ "$run2" == 2 ]] && pass "no installer is a usage error" || fail "no installer (rc $run2; $OUT)"
run2=0; OUT="$(NVM_DIR="$TMP/nvm" AI_NODE_SLEEP=0 AI_NODE_ATTEMPTS=1 bash "$SCRIPT" "$TMP/no-such-installer.sh" 2>&1)" || run2=$?
[[ "$run2" == 2 ]] && pass "an installer that is not there is a usage error, not five attempts" || fail "a missing installer (rc $run2; $OUT)"
# The backoff knob is honoured: two failing attempts with no backoff finish at
# once, where a misread knob sleeps 15 s between them.
t0=$SECONDS
run FAKE_INSTALLER_FAILS=9 AI_NODE_ATTEMPTS=2
(( SECONDS - t0 < 10 )) && [[ "$RC" == 1 ]] && pass "AI_NODE_SLEEP=0 means no backoff ($((SECONDS - t0))s)" \
  || fail "the backoff knob (rc $RC, $((SECONDS - t0))s)"

# Its own failures stop it, not a later step: a temporary file it cannot make,
# and a reset of NVM_DIR that fails (a slate that is not clean is no retry).
# Each through a PATH shim, so a root run sees the same.
mkdir -p "$TMP/fail-bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/fail-bin/mktemp"; chmod +x "$TMP/fail-bin/mktemp"
run2=0; OUT="$(PATH="$TMP/fail-bin:$PATH" NVM_DIR="$TMP/nvm" AI_NODE_SLEEP=0 bash "$SCRIPT" "$TMP/installer.sh" 2>&1)" || run2=$?
[[ "$run2" == 1 && "$OUT" == *"cannot make a temporary file"* ]] && pass "a temporary file it cannot make stops it" \
  || fail "mktemp failing (rc $run2; $OUT)"
rm -f "$TMP/fail-bin/mktemp"
printf '#!/bin/sh\nexit 1\n' > "$TMP/fail-bin/mkdir"; chmod +x "$TMP/fail-bin/mkdir"
: > "$LOG"; rm -f "$RUNS"
run2=0; OUT="$(PATH="$TMP/fail-bin:$PATH" LOG="$LOG" RUNS="$RUNS" SEEN="$SEEN" NVM_DIR="$TMP/nvm" AI_NODE_SLEEP=0 bash "$SCRIPT" "$TMP/installer.sh" 2>&1)" || run2=$?
[[ "$run2" == 1 && "$OUT" == *"cannot reset"* && ! -e "$RUNS" ]] && pass "a reset of NVM_DIR that fails stops it before the installer runs" \
  || fail "the reset failing (rc $run2; runs: $(cat "$RUNS" 2>/dev/null); $OUT)"
rm -rf "$TMP/fail-bin"

# The Dockerfile runs it, so a project builds it: it must be a shared file.
# shellcheck source=../shared-files.sh
source "$REPO_DIR/shared-files.sh"
case " ${AI_CONTAINERS_SHARED_FILES[*]} " in
  *" install-node-lts.sh "*) pass "install-node-lts.sh is a shared file" ;;
  *) fail "install-node-lts.sh is not in AI_CONTAINERS_SHARED_FILES" ;;
esac
grep -q '^COPY install-node-lts.sh /tmp/install-node-lts.sh' "$REPO_DIR/Dockerfile" \
  && grep -q 'bash /tmp/install-node-lts.sh /tmp/nvm-install.sh' "$REPO_DIR/Dockerfile" \
  && pass "the Dockerfile's nvm layer runs it" || fail "the Dockerfile does not run install-node-lts.sh"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
