#!/usr/bin/env bash
# Unit tests for start-services.sh, the in-container service runner.
#
# Driven against FAKE adapters in a scratch services.d, so what is asserted is
# the runner's own contract — phases, warnings, the watchdog timeout, adapter
# isolation, exit status — and not any one server. services.d/postgres.sh has
# its own file (test-postgres.sh), and that a real server starts in a real image
# is integration case 780-postgres-server-runs.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_DIR/start-services.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

ADAPTERS="$TMP/services.d"; mkdir -p "$ADAPTERS"
TRACE="$TMP/trace"

# fake: complete; behaviour chosen per test through FAKE_* env.
cat > "$ADAPTERS/fake.sh" <<'EOF'
svc_installed_version() { printf '%s' "${FAKE_VERSION-1.2}"; }
svc_runtime_dirs()      { printf '%s\n' "$FAKE_RUNTIME_DIR"; }
svc_start() {
  printf 'start|%s|%s\n' "$1" "$2" >> "$FAKE_TRACE"
  case "${FAKE_START:-ok}" in
    ok)   printf 'fake server log line\n' ;;
    slow) sleep 1; printf 'fake server log line\n' ;;
    fail) printf 'boom: disk on fire\n'; return 1 ;;
    hang) sleep 30 & printf '%s' "$!" > "$FAKE_PIDFILE"; wait ;;
    # A child that IGNORES TERM, as a server mid-shutdown or a stuck client can:
    # the group's TERM kills this function's shell, not the child.
    hang-ignore-term) ( trap '' TERM; exec sleep 30 ) & printf '%s' "$!" > "$FAKE_PIDFILE"; wait ;;
    # The function's OWN shell notes TERM and keeps waiting, so a trace line
    # proves TERM arrived and only a KILL can end it.
    hang-shrug-term)
      trap 'printf "TERM\n" >> "$FAKE_TRACE"' TERM
      sleep 30 & printf '%s' "$!" > "$FAKE_PIDFILE"
      while ! wait; do :; done ;;
  esac
}
svc_provision() {
  printf 'provision\n' >> "$FAKE_TRACE"
  [[ "${FAKE_PROVISION:-ok}" == hang ]] && { sleep 30 & printf '%s' "$!" > "$FAKE_PIDFILE"; wait; }
  printf '; extras: %s' "${FAKE_EXTRAS:-none}"; }
svc_endpoint()  { printf 'fake:1234'; }
EOF
# bad: complete, always fails to start.
cat > "$ADAPTERS/bad.sh" <<'EOF'
svc_installed_version() { printf '9.9'; }
svc_runtime_dirs()      { :; }
svc_start()             { printf 'bad: refused\n'; return 1; }
svc_provision()         { :; }
svc_endpoint()          { printf 'bad:0'; }
EOF
# partial: missing svc_runtime_dirs, svc_provision and svc_endpoint.
cat > "$ADAPTERS/partial.sh" <<'EOF'
svc_installed_version() { printf '1.0'; }
svc_start()             { printf 'start|partial\n' >> "$FAKE_TRACE"; }
EOF
# broken: a file that fails to load at all (source returns non-zero).
printf 'return 1\n' > "$ADAPTERS/broken.sh"
# evil: OUTSIDE services.d; must never be sourced through a crafted name.
printf 'touch "%s/evil-ran"\n' "$TMP" > "$TMP/evil.sh"

reset() { rm -rf "$TMP/state" "$TMP/log" "$TMP/run"; mkdir -p "$TMP/state" "$TMP/log"; : > "$TRACE"; }
run_runner() {  # $1 = phase, $2… = extra VAR=value → sets OUT (stdout+stderr) and RC
  local phase="$1"; shift
  OUT="$(env AI_SERVICES_DIR="$ADAPTERS" AI_SERVICES_STATE_ROOT="$TMP/state" \
             AI_SERVICES_LOG_ROOT="$TMP/log" FAKE_TRACE="$TRACE" FAKE_PIDFILE="$TMP/childpid" AI_SERVICES_TIMEOUT=5 \
             FAKE_RUNTIME_DIR="$TMP/run/fake" \
             SANDBOX_UID="$(id -u)" SANDBOX_GID="$(id -g)" "$@" \
             bash "$RUNNER" "$phase" 2>&1)"
  RC=$?
}
has()  { grep -qF -- "$1" <<<"$OUT"; }
# gone <pid> — dead within ~2 s. Polled, not one `kill -0`: a killed child stays
# a zombie, which `kill -0` still finds, until whoever inherited it reaps it.
gone() {
  local tries=20
  while (( tries-- > 0 )); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# T1 — the happy path: ready line, svc_start's chatter in the log not on screen.
reset; run_runner start AI_SERVICES=fake=ON
[[ "$RC" -eq 0 ]] && pass "T1 start exits 0" || fail "T1 start exits 0 (rc=$RC)"
has "fake 1.2 ready on fake:1234; extras: none" \
  && pass "T1 prints '<name> <version> ready on <endpoint><suffix>'" \
  || fail "T1 ready line (got: $OUT)"
grep -qx "start|$TMP/state/fake|$TMP/log/fake.log" "$TRACE" \
  && pass "T1 svc_start gets <state-root>/<name> and <log-root>/<name>.log" \
  || fail "T1 svc_start arguments (trace: $(cat "$TRACE"))"
grep -qx 'provision' "$TRACE" && pass "T1 svc_provision runs after a successful start" || fail "T1 svc_provision ran"
! has 'fake server log line' && grep -q 'fake server log line' "$TMP/log/fake.log" \
  && pass "T1 svc_start's stdout goes to the log, not the terminal" \
  || fail "T1 svc_start's stdout goes to the log, not the terminal"

# T2 — prepare creates and owns the directories, and starts nothing.
rm -rf "$TMP/state" "$TMP/log" "$TMP/run"; : > "$TRACE"
run_runner prepare AI_SERVICES=fake=ON
[[ "$RC" -eq 0 && -d "$TMP/state/fake" && -d "$TMP/log" && -d "$TMP/run/fake" ]] \
  && pass "T2 prepare creates the data, log and runtime directories" \
  || fail "T2 prepare creates the data, log and runtime directories (rc=$RC, out=$OUT)"
[[ -z "$OUT" && ! -s "$TRACE" ]] \
  && pass "T2 prepare is silent and starts nothing" \
  || fail "T2 prepare is silent and starts nothing (out=$OUT, trace=$(cat "$TRACE"))"

# T3 — prepare skips a service the image does not have.
rm -rf "$TMP/state" "$TMP/log" "$TMP/run"
run_runner prepare AI_SERVICES=fake=ON FAKE_VERSION=
[[ ! -d "$TMP/state/fake" && -z "$OUT" ]] \
  && pass "T3 prepare skips a server this image lacks, silently (start reports it)" \
  || fail "T3 prepare skips a server this image lacks (out=$OUT)"

# T4 — unknown service.
reset; run_runner start AI_SERVICES=nosuch=ON
[[ "$RC" -eq 0 ]] && has "WARNING: unknown service 'nosuch'" \
  && pass "T4 an unknown service warns and exits 0" \
  || fail "T4 an unknown service warns and exits 0 (rc=$RC, out=$OUT)"

# T5 — a name that could escape services.d is refused in BOTH phases.
reset; rm -f "$TMP/evil-ran"
run_runner start 'AI_SERVICES=../evil=ON'
has "is not a valid service name" \
  && pass "T5 '../evil' is refused as a service name" \
  || fail "T5 '../evil' is refused as a service name (out=$OUT)"
run_runner prepare 'AI_SERVICES=../evil=ON'
[[ ! -e "$TMP/evil-ran" ]] \
  && pass "T5 no file outside services.d is ever sourced" \
  || fail "T5 a crafted name sourced a file outside services.d"

# T6 — key on, image without the server.
reset; run_runner start AI_SERVICES=fake=17 FAKE_VERSION=
has "WARNING: sandbox.conf has fake=17, but this image has no fake server. Rebuild: ./build.sh" \
  && pass "T6 a server missing from the image is named, with the rebuild command" \
  || fail "T6 missing-server warning (out=$OUT)"
[[ ! -s "$TRACE" ]] && pass "T6 svc_start is not called" || fail "T6 svc_start is not called"

# T7 — an incomplete adapter is skipped, and another adapter's functions never stand in.
reset; run_runner start AI_SERVICES=fake=ON,partial=ON
has "WARNING: services.d/partial.sh is incomplete — skipped" \
  && pass "T7 an incomplete adapter is skipped with a warning" \
  || fail "T7 incomplete adapter warning (out=$OUT)"
has "fake 1.2 ready on fake:1234" && ! grep -q 'start|partial' "$TRACE" \
  && pass "T7 adapters are isolated: fake's functions did not complete partial" \
  || fail "T7 adapters are isolated (out=$OUT, trace=$(cat "$TRACE"))"

# T8 — mismatch: ready line AND the warning.
reset; run_runner start AI_SERVICES=fake=17 FAKE_VERSION=16.15
has "fake 16.15 ready on fake:1234" \
  && has "WARNING: sandbox.conf asks for fake=17, this image has 16.15. Rebuild: ./build.sh" \
  && pass "T8 a stale image still starts, with the mismatch named" \
  || fail "T8 mismatch (out=$OUT)"

# T9 — no false mismatch.
for pair in '17:17.11' '17:17' 'ON:16.15'; do
  reset; run_runner start "AI_SERVICES=fake=${pair%%:*}" "FAKE_VERSION=${pair#*:}"
  ! has "asks for" \
    && pass "T9 fake=${pair%%:*} with ${pair#*:} installed is not a mismatch" \
    || fail "T9 fake=${pair%%:*} with ${pair#*:} installed is not a mismatch (out=$OUT)"
done

# T10 — the prefix trap: 17 must not match 170.1.
reset; run_runner start AI_SERVICES=fake=17 FAKE_VERSION=170.1
has "asks for fake=17, this image has 170.1" \
  && pass "T10 17 does not match 170.1" \
  || fail "T10 17 does not match 170.1 (out=$OUT)"

# T11 — an entry with no value is ON.
reset; run_runner start AI_SERVICES=fake FAKE_VERSION=16.15
has "fake 16.15 ready" && ! has "asks for" \
  && pass "T11 'fake' alone is treated as fake=ON" \
  || fail "T11 'fake' alone is treated as fake=ON (out=$OUT)"

# T12 — start failure: warning, log path, log tail, exit 0, no provisioning.
reset; run_runner start AI_SERVICES=fake=ON FAKE_START=fail
[[ "$RC" -eq 0 ]] && has "WARNING: fake failed to start — log: $TMP/log/fake.log" \
  && has "    boom: disk on fire" && ! has "ready on" \
  && pass "T12 a failed start prints the log path and its tail, and exits 0" \
  || fail "T12 failed start (rc=$RC, out=$OUT)"
! grep -qx 'provision' "$TRACE" && pass "T12 nothing is provisioned after a failed start" || fail "T12 provisioned after a failed start"

# T13 — one failure does not stop the next.
reset; run_runner start AI_SERVICES=bad=ON,fake=ON
has "WARNING: bad failed to start" && has "fake 1.2 ready on fake:1234" \
  && pass "T13 a failing service does not stop the next one" \
  || fail "T13 a failing service does not stop the next one (out=$OUT)"

# T14 — the watchdog: a hang in a CHILD process (where a real adapter hangs:
# initdb, pg_ctl -w, psql) is cut off, reported, and the child is killed too.
for mode in FAKE_START FAKE_PROVISION; do
  reset; rm -f "$TMP/childpid"; started=$SECONDS
  run_runner start AI_SERVICES=fake=ON "$mode=hang" AI_SERVICES_TIMEOUT=1
  took=$((SECONDS - started))
  [[ "$RC" -eq 0 ]] && has "WARNING: fake did not become ready within 1s" && (( took < 10 )) \
    && pass "T14 $mode=hang is cut off at AI_SERVICES_TIMEOUT (${took}s) and reported" \
    || fail "T14 $mode=hang watchdog (rc=$RC, took=${took}s, out=$OUT)"
  cpid="$(cat "$TMP/childpid" 2>/dev/null)"
  [[ -n "$cpid" ]] && gone "$cpid" \
    && pass "T14 $mode=hang: the hung child process is dead afterwards" \
    || fail "T14 $mode=hang: child '$cpid' survived the watchdog"
  [[ -n "$cpid" ]] && kill -KILL "$cpid" 2>/dev/null
done

# T14b — a child that ignores TERM. The group's TERM kills the function's own
# shell, `wait` returns, and the watchdog — with its KILL still pending — is
# stopped; so the KILL must not live only in the watchdog.
reset; rm -f "$TMP/childpid"; started=$SECONDS
run_runner start AI_SERVICES=fake=ON FAKE_START=hang-ignore-term AI_SERVICES_TIMEOUT=1
took=$((SECONDS - started))
[[ "$RC" -eq 0 ]] && has "WARNING: fake did not become ready within 1s" && (( took < 10 )) \
  && pass "T14b a hang whose child ignores TERM is cut off (${took}s) and reported" \
  || fail "T14b TERM-ignoring hang (rc=$RC, took=${took}s, out=$OUT)"
cpid="$(cat "$TMP/childpid" 2>/dev/null)"
[[ -n "$cpid" ]] && gone "$cpid" \
  && pass "T14b the child that ignored TERM is dead afterwards (KILLed)" \
  || fail "T14b child '$cpid' ignored TERM and survived the watchdog"
[[ -n "$cpid" ]] && kill -KILL "$cpid" 2>/dev/null

# T14c — no job control: `set -m` creates no process group (simulated with an
# exported function that swallows -m/+m), so there is no group to signal. The
# watchdog must fall back to the PID, or `wait` blocks for the whole hang. The
# function's shell notes TERM and keeps waiting (hang-shrug-term), so TERM and
# KILL are each observed: the trace line is the TERM fallback, and the deadline
# being met at all is the KILL fallback.
reset; rm -f "$TMP/childpid"; started=$SECONDS
nojc_set() { case "${1:-}" in -m|+m) return 0 ;; esac; builtin set "$@"; }
OUT="$( set() { nojc_set "$@"; }; export -f set nojc_set
        env AI_SERVICES_DIR="$ADAPTERS" AI_SERVICES_STATE_ROOT="$TMP/state" AI_SERVICES_LOG_ROOT="$TMP/log" \
            FAKE_TRACE="$TRACE" FAKE_PIDFILE="$TMP/childpid" FAKE_RUNTIME_DIR="$TMP/run/fake" \
            AI_SERVICES=fake=ON FAKE_START=hang-shrug-term AI_SERVICES_TIMEOUT=1 bash "$RUNNER" start 2>&1 )"; RC=$?
took=$((SECONDS - started))
[[ "$RC" -eq 0 ]] && has "WARNING: fake did not become ready within 1s" && (( took < 10 )) \
  && pass "T14c with no process group the watchdog KILLs the PID: cut off (${took}s) and reported" \
  || fail "T14c no job control (rc=$RC, took=${took}s, out=$OUT)"
grep -qx 'TERM' "$TRACE" \
  && pass "T14c with no process group the PID is sent TERM first" \
  || fail "T14c no TERM reached the PID (trace: $(cat "$TRACE"))"
cpid="$(cat "$TMP/childpid" 2>/dev/null)"
[[ -n "$cpid" ]] && kill -KILL "$cpid" 2>/dev/null

# T15 — nothing asked for: nothing said.
reset; run_runner start AI_SERVICES=
[[ "$RC" -eq 0 && -z "$OUT" ]] && pass "T15 empty AI_SERVICES: silent, exit 0" || fail "T15 empty AI_SERVICES (rc=$RC, out=$OUT)"

# T16 — usage error is the ONE non-zero exit.
OUT="$(bash "$RUNNER" bogus 2>&1)"; RC=$?
[[ "$RC" -eq 2 && "$OUT" == *usage* ]] && pass "T16 an unknown phase is a usage error (exit 2)" || fail "T16 usage (rc=$RC, out=$OUT)"

# T17 — stray whitespace and empty entries.
reset; run_runner start 'AI_SERVICES= fake=ON , '
has "fake 1.2 ready on fake:1234" && ! has WARNING \
  && pass "T17 whitespace and an empty entry are tolerated" \
  || fail "T17 whitespace (out=$OUT)"

# T18 — a nonsense timeout falls back to the default rather than timing out at once.
reset; run_runner start AI_SERVICES=fake=ON AI_SERVICES_TIMEOUT=abc
has "fake 1.2 ready on fake:1234" \
  && pass "T18 a non-numeric AI_SERVICES_TIMEOUT falls back to the default" \
  || fail "T18 non-numeric timeout (out=$OUT)"
# 0 is numeric and means "expire at once": every server would be reported as
# not ready. A one-second start makes that deterministic rather than a race
# between the watchdog's `sleep 0` and a fast fake.
reset; run_runner start AI_SERVICES=fake=ON AI_SERVICES_TIMEOUT=0 FAKE_START=slow
has "fake 1.2 ready on fake:1234" && ! has "did not become ready" \
  && pass "T18 AI_SERVICES_TIMEOUT=0 falls back to the default too" \
  || fail "T18 zero timeout (out=$OUT)"

# T19 — an adapter that fails to LOAD is named as such (not as "incomplete").
reset; run_runner start AI_SERVICES=broken=ON
has "WARNING: services.d/broken.sh failed to load — skipped" && ! has "incomplete" \
  && pass "T19 an adapter that fails to load says so" \
  || fail "T19 load failure (out=$OUT)"

# T20 — prepare chowns every directory it creates to SANDBOX_UID:SANDBOX_GID.
# Run as an ordinary user a real chown to oneself is a no-op, so a recording
# stub on PATH is the only observer.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nprintf "%%s|" "$@" >> "%s/chown.log"; printf "\\n" >> "%s/chown.log"\n' "$TMP" "$TMP" > "$TMP/bin/chown"
chmod +x "$TMP/bin/chown"
reset; : > "$TMP/chown.log"
run_runner prepare AI_SERVICES=fake=ON "PATH=$TMP/bin:$PATH" SANDBOX_UID=4242 SANDBOX_GID=4343
for d in "$TMP/state/fake" "$TMP/log" "$TMP/run/fake"; do
  grep -qxF "4242:4343|$d|" "$TMP/chown.log" \
    && pass "T20 prepare chowns $d to SANDBOX_UID:SANDBOX_GID" \
    || fail "T20 prepare chown of $d (log: $(cat "$TMP/chown.log"))"
done

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
