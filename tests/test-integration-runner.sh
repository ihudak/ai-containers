#!/usr/bin/env bash
# Hermetic unit test for tests/integration/run.sh — the SELECTION and ACCOUNTING
# logic, with no Docker daemon and no real cases.
#
# What it pins, and why it is the most important test in the suite:
#   Selection and skipping are different things, and conflating them reopens the
#   hole the integration suite exists to close. --tags/--exclude decide what is
#   SELECTED (a deliberate, visible choice recorded in the workflow). A SKIP is a
#   case that WAS selected and then could not run. --require makes a skip inside
#   the selected set fatal. If those two ever collapse into one number, "we chose
#   not to check this" starts reading as "this passed" — which is exactly the
#   false confidence that let a dead capture daemon look green for months.
#
# Hermetic: synthetic cases in a temp dir via IT_CASES_DIR, capabilities forced
# via IT_FORCE_CAPS, fake docker on PATH so nothing can reach a real daemon.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_DIR/tests/integration/run.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$RUN" && pass "run.sh bash -n" || fail "run.sh bash -n"

# ── A fake docker that fails loudly if anything actually calls it ───────────────
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# Only the calls the runner legitimately makes with --reuse-image are allowed.
# sweep() also calls `docker ps -aq --filter …`, `docker network ls -q --filter
# …`, `docker rm -f`, and `docker rmi`; detect_caps calls `docker info` — all of
# these must return quietly so a hermetic run never reaches for a real daemon.
case "$1 ${2:-}" in
  "network create"|"network rm"|"network inspect") echo "it-net-fake"; exit 0 ;;
  "container prune"|"volume prune"|"network prune") exit 0 ;;
  "image inspect") exit 0 ;;
  "ps -aq") exit 0 ;;          # empty list: sweep's while-read loop never fires
  "network ls") exit 0 ;;      # same, for the network-cleanup loop
  "rm -f") exit 0 ;;
  rmi\ *) exit 0 ;;            # $2 is the image tag, not a fixed verb — glob it
  info*) exit 0 ;;             # "docker info" alone leaves a trailing space in $2
  *) echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"

# ── Synthetic corpus ────────────────────────────────────────────────────────────
CASES="$TMP/cases"; mkdir -p "$CASES"
mkcase() {  # $1=name $2=tags $3=requires $4=body
  cat > "$CASES/$1.sh" <<EOF
#!/usr/bin/env bash
# summary:  synthetic $1
# tags:     $2
# requires: $3
$4
EOF
}
mkcase 010-alpha  "security fast"        "docker"          'echo "PASS: alpha"; exit 0'
mkcase 020-beta   "network-mode fast"    "docker"          'echo "PASS: beta"; exit 0'
mkcase 030-gamma  "security fast"        "docker netadmin" 'echo "PASS: gamma"; exit 0'
mkcase 040-delta  "network-mode slow"    "docker"          'echo "PASS: delta"; exit 0'
mkcase 050-eps    "security needs-dns"   "docker dns"      'echo "PASS: eps"; exit 0'
mkcase 060-zeta   "security fast"        "docker"          'echo "FAIL: zeta"; exit 1'
mkcase 070-eta    "security fast"        "docker"          'exit 0'            # asserts nothing
mkcase 080-theta  "security fast"        "docker"          'echo "SKIP: no fixture"; exit 77'

run_it() {  # args… → combined output; exit code appended as a marker line
  local out rc
  out="$(PATH="$FAKE_BIN:$PATH" IT_CASES_DIR="$CASES" IT_SCRATCH="$TMP/scratch" \
        bash "$RUN" --reuse-image --image fake-img "$@" 2>&1)"
  rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}

has() { printf '%s' "$1" | grep -qE "$2"; }
rc_of() { printf '%s' "$1" | sed -n 's/^RC=//p' | tail -1; }

# ── --list needs no capabilities and no daemon ─────────────────────────────────
out="$(IT_CASES_DIR="$CASES" bash "$RUN" --list 2>&1)"
has "$out" '010-alpha' && pass "--list shows a case" || fail "--list shows a case"
has "$out" 'security fast' && pass "--list shows tags" || fail "--list shows tags"

# ── Tag selection ──────────────────────────────────────────────────────────────
out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --tags fast)"
has "$out" 'selected 6 of 8' \
  && pass "--tags fast selects exactly the 6 fast cases" \
  || fail "--tags fast selects exactly the 6 fast cases -- got: $(printf '%s' "$out" | grep selected)"

out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --tags security --exclude needs-dns)"
has "$out" 'selected 5 of 8' \
  && pass "--exclude removes needs-dns from a security selection" \
  || fail "--exclude removes needs-dns from a security selection -- got: $(printf '%s' "$out" | grep selected)"

# ── Selection and skipping are reported SEPARATELY ─────────────────────────────
out="$(IT_FORCE_CAPS="docker" run_it --tags security)"
has "$out" 'selected 6 of 8' \
  && pass "unmet requirements do not change the SELECTED count" \
  || fail "unmet requirements do not change the SELECTED count"
has "$out" 'skipped 3' \
  && pass "skips are counted separately from selection" \
  || fail "skips are counted separately from selection -- got: $(printf '%s' "$out" | grep skipped)"

# ── Every skip prints its unmet requirement ────────────────────────────────────
has "$out" '030-gamma.*SKIP.*netadmin' \
  && pass "a skip names the unmet requirement" \
  || fail "a skip names the unmet requirement"
has "$out" '080-theta.*SKIP.*no fixture' \
  && pass "a case-declared skip (exit 77) reports its own reason" \
  || fail "a case-declared skip (exit 77) reports its own reason"

# ── --require turns a skip inside the selected set into a failure ──────────────
# The DISCRIMINATING form. An earlier version ran `--tags security --require
# security` and asserted rc != 0 — but 060-zeta and 070-eta fail unconditionally
# in that selection, so the run was red whether --require worked or not. The
# assertion would have passed against a --require that did nothing at all.
#
# Select a set where the ONLY possible cause of failure is --require: 030-gamma
# skips (needs netadmin, which IT_FORCE_CAPS withholds) and nothing else in the
# selection can fail. Then run it twice, with and without the flag, and require
# the exit codes to DIFFER. That is the only shape that isolates the flag.
mkcase 035-passes "security fast" "docker" 'echo "PASS: passes"; exit 0'
out_without="$(IT_FORCE_CAPS="docker" run_it --tags security --exclude needs-dns \
                 --timeout 20 --tags security)"
# Narrow to just the skipping case plus a passing one, so nothing else is red.
mkcase 036-skips  "reqtest" "docker netadmin" 'echo "PASS: never runs"; exit 0'
mkcase 037-passes "reqtest" "docker"          'echo "PASS: runs fine"; exit 0'
no_flag="$(IT_FORCE_CAPS="docker" run_it --tags reqtest)"
with_flag="$(IT_FORCE_CAPS="docker" run_it --tags reqtest --require reqtest)"
rm -f "$CASES/035-passes.sh"

[[ "$(rc_of "$no_flag")" == "0" ]] \
  && pass "without --require, a skipped case does not fail the run" \
  || fail "without --require, a skipped case does not fail the run (rc=$(rc_of "$no_flag"))"
[[ "$(rc_of "$with_flag")" != "0" ]] \
  && pass "with --require, the SAME skip fails the run (isolates the flag)" \
  || fail "with --require, the SAME skip fails the run (rc=$(rc_of "$with_flag"))"
rm -f "$CASES/036-skips.sh" "$CASES/037-passes.sh"

out="$(IT_FORCE_CAPS="docker" run_it --tags security --require security)"
has "$out" 'required tag .security.' \
  && pass "--require failure names the tag and the skipped cases" \
  || fail "--require failure names the tag and the skipped cases"

# ── ...but --require only applies INSIDE the selected set ──────────────────────
# 050-eps (needs-dns) is deliberately EXCLUDED, not skipped, so it must never even
# be considered by --require: a deliberate selection is not a silent hole. This
# does NOT assert the run's overall exit code: 060-zeta/070-eta fail independently
# of --require by construction (see "Failure accounting" below), and 080-theta
# correctly still trips --require security on its own account (a genuine
# self-declared skip inside the selected set — exactly what --require exists to
# catch). rc==0 is therefore unreachable here regardless of the exclude/skip
# distinction, so checking it would test the wrong thing. What must never happen
# is 050-eps showing up anywhere in the accounting once --exclude removed it.
out="$(IT_FORCE_CAPS="docker netadmin" run_it --tags security --exclude needs-dns --require security)"
has "$out" '050-eps' \
  && fail "--require must not reference 050-eps once --exclude removed it -- got: $out" \
  || pass "--require ignores cases removed by --exclude (selection != skip)"

# ── Failure accounting ─────────────────────────────────────────────────────────
out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --tags fast)"
has "$out" '060-zeta.*FAIL' && pass "a failing case is reported FAIL" || fail "a failing case is reported FAIL"
[[ "$(rc_of "$out")" != "0" ]] && pass "a failing case fails the run" || fail "a failing case fails the run"

# ── The asserted-nothing guard, carried over from tests/run-all.sh ─────────────
has "$out" '070-eta.*FAIL.*asserted nothing' \
  && pass "exit 0 with no PASS line is FAIL, not a silent pass" \
  || fail "exit 0 with no PASS line is FAIL, not a silent pass"

# ── Timeout is enforced per case, not per run ─────────────────────────────────
mkcase 090-hang "fast" "docker" 'echo "PASS: started"; sleep 60'
out="$(IT_FORCE_CAPS="docker" run_it --tags fast --timeout 2)"
has "$out" '090-hang.*FAIL.*timed out' \
  && pass "a hanging case is killed and reported as timed out" \
  || fail "a hanging case is killed and reported as timed out"
rm -f "$CASES/090-hang.sh"

# ── A failing case's own FAIL: line survives a long diagnostics tail ──────────
# Pins the fix in cf0a870: run.sh's failed-case dump used to pipe the whole
# case log through a bare `tail -40`. lib.sh's it_diagnose appends the
# case's diagnostics AFTER its own PASS:/FAIL: lines, and that tail alone
# commonly exceeds 40 lines, so the plain `tail -40` kept only the
# diagnostics and silently dropped the line that said why the case failed.
# The 60 filler lines below are the whole point of this test: with only a
# handful of trailing lines, a reverted fix would still happen to pass this
# assertion (the FAIL: line would still fall inside a 40-line tail) and the
# test would be decorative. 60 lines guarantees the marker falls OUTSIDE a
# raw last-40-lines window, so this test can only pass if the fix's
# "print PASS:/FAIL:/SKIP: lines first, unconditionally" behaviour is
# actually there.
mkcase 100-loud-fail "fast" "docker" \
  'echo "FAIL: distinctive-marker-loud-fail"; for i in $(seq 1 60); do echo "noise line $i"; done; exit 1'
out="$(IT_FORCE_CAPS="docker" run_it --tags fast)"
has "$out" 'FAIL: distinctive-marker-loud-fail' \
  && pass "a failing case's FAIL: line survives 60 lines of trailing output" \
  || fail "a failing case's FAIL: line survives 60 lines of trailing output"
rm -f "$CASES/100-loud-fail.sh"

# ── $IT_SCRATCH survives a run with failures, is removed after a clean one ────
# Pins the other half of cf0a870: sweep() (run.sh's own EXIT trap) used to
# unconditionally `rm -rf $IT_SCRATCH` unless --keep was passed. CI's
# "Collect diagnostics" step copies $IT_SCRATCH into an uploaded artifact,
# but that step runs AFTER run.sh has already exited and sweep() has already
# deleted it — a red run shipped an empty diagnostics artifact. Both
# directions matter: keeping scratch forever (even on a clean run) would
# just leak disk on every green run.
#
# Deliberately NOT using run_it()'s shared $TMP/scratch here — that path is
# reused by every call above, so whether it "survives" or "is removed" at
# this point in the file would depend on which earlier call last touched
# it, not on THIS invocation's own outcome. Each scenario below gets its own
# scratch dir so the assertion is unambiguous.
SCRATCH_HAD_FAILURE="$TMP/scratch-had-failure"
SCRATCH_ALL_CLEAN="$TMP/scratch-all-clean"

# --tags fast always includes 060-zeta, a permanent fixture that fails by
# construction, so this run has n_fail > 0 without needing a dedicated case.
PATH="$FAKE_BIN:$PATH" IT_CASES_DIR="$CASES" IT_SCRATCH="$SCRATCH_HAD_FAILURE" \
  bash "$RUN" --reuse-image --image fake-img --tags fast >/dev/null 2>&1
[[ -d "$SCRATCH_HAD_FAILURE" ]] \
  && pass "\$IT_SCRATCH survives a run that had a failing case" \
  || fail "\$IT_SCRATCH survives a run that had a failing case"

# --tags network-mode selects only 020-beta and 040-delta — the only two
# cases carrying that tag — both of which genuinely pass, so this run has
# n_fail == 0 without needing a dedicated case.
PATH="$FAKE_BIN:$PATH" IT_CASES_DIR="$CASES" IT_SCRATCH="$SCRATCH_ALL_CLEAN" \
  bash "$RUN" --reuse-image --image fake-img --tags network-mode >/dev/null 2>&1
[[ ! -d "$SCRATCH_ALL_CLEAN" ]] \
  && pass "\$IT_SCRATCH is removed after a run with no failures" \
  || fail "\$IT_SCRATCH is removed after a run with no failures"

# ── A forced capability set is never silent ───────────────────────────────────
out="$(IT_FORCE_CAPS="docker" run_it --list-caps)"
has "$out" 'FORCED' \
  && pass "IT_FORCE_CAPS is reported in the banner, never applied silently" \
  || fail "IT_FORCE_CAPS is reported in the banner, never applied silently"

# ── Portability: no GNU coreutils ───────────────────────────────────────────────
# macOS ships neither `timeout` nor a BSD equivalent. Before the it_timeout shim,
# every case on a Mac exited 127 and the runner reported 14 of 16 FAILED in 0s —
# and detect_caps's `timeout 120 docker pull` died the same way, so the dns
# capability went undetected and looked convincingly like a Colima limitation.
# CI never saw any of it: ubuntu-latest has coreutils.
grep -q 'command -v gtimeout' "$RUN" \
  && pass "run.sh falls back to gtimeout when GNU timeout is absent" \
  || fail "run.sh falls back to gtimeout when GNU timeout is absent"
grep -q 'return 124' "$RUN" \
  && pass "the pure-bash timeout fallback returns 124 like GNU timeout" \
  || fail "the pure-bash timeout fallback returns 124 like GNU timeout"
# The fallback must be REACHABLE — a shim that only ever resolves to GNU timeout
# is untested on the platform it exists for.
if grep -q 'elif command -v gtimeout' "$RUN" && grep -q '^else$' "$RUN"; then
  pass "the shim has all three branches (timeout / gtimeout / bash fallback)"
else
  fail "the shim has all three branches (timeout / gtimeout / bash fallback)"
fi
# No bare `timeout ` call sites may remain — that is the bug itself.
if grep -nE '^\s+timeout [0-9"$]' "$RUN" | grep -v it_timeout | grep -q .; then
  fail "no bare GNU timeout call sites remain in run.sh"
else
  pass "no bare GNU timeout call sites remain in run.sh"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
