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
out="$(IT_FORCE_CAPS="docker" run_it --tags security --require security)"
[[ "$(rc_of "$out")" != "0" ]] \
  && pass "--require security fails the run when a security case skipped" \
  || fail "--require security fails the run when a security case skipped"
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

# ── A forced capability set is never silent ───────────────────────────────────
out="$(IT_FORCE_CAPS="docker" run_it --list-caps)"
has "$out" 'FORCED' \
  && pass "IT_FORCE_CAPS is reported in the banner, never applied silently" \
  || fail "IT_FORCE_CAPS is reported in the banner, never applied silently"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
