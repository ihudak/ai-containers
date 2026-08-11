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
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"$'\n'"       expected: $2"$'\n'"       got:      $3"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# tests/integration/run.sh's own path is not layout-sensitive (tests/ sits at
# the same place in both layouts; only sandbox.sh et al. move into base/ in
# the mgd-ai-containers fork), so RUN already resolves it correctly above.
# RUNNER is just that same value under the name the callfn.sh helper below
# (and the brief this file implements) uses.
RUNNER="$RUN"

# run.sh is a script, not a library. Sourcing it with IT_SOURCE_ONLY=1 stops it
# before the selection/execution phase so its pure functions can be unit-tested.
# Without this the only way to test variant resolution would be a full run,
# which needs a Docker daemon this suite does not have.
cat > "$TMP/callfn.sh" <<EOF
#!/usr/bin/env bash
export IT_SOURCE_ONLY=1
export IT_IMAGE="\${IT_IMAGE:-ai-sandbox-it}"
source "$RUNNER"
"\$@"
EOF
chmod +x "$TMP/callfn.sh"

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

# ── A case that prints FAIL: but never reaches it_finish is not a pass ────────
# The sibling of the asserted-nothing guard above, and the fix for a real gap:
# a case's normal exit path is lib.sh's it_finish, which `exit`s "$it_fails".
# A case that calls fail() (so a real FAIL: line lands in the log) but then
# hits an early return, a forgotten trailing call, or any other path that
# skips it_finish falls through to whatever its last command happened to
# return — here, an explicit `exit 0` standing in for that mistake. Before
# this guard, rc==0 with n_ok>0 was reported PASS regardless of any FAIL:
# lines also present, exactly the shape of tests/test-integration-lib.sh's
# pass()/fail() collision with this same lib.sh (see that file's header
# comment): the log holds real, load-bearing evidence of failure and the
# summary says PASS anyway.
mkcase 071-forgot-finish "forgotfinish" "docker" \
  'echo "PASS: something real happened first"; echo "FAIL: a real assertion failed here"; exit 0'
out="$(IT_FORCE_CAPS="docker" run_it --tags forgotfinish)"
has "$out" '071-forgot-finish.*FAIL.*printed 1 FAIL.*never reached it_finish' \
  && pass "a case with a FAIL: line but rc=0 is reported FAIL, not PASS" \
  || fail "a case with a FAIL: line but rc=0 is reported FAIL, not PASS -- got: $out"
[[ "$(rc_of "$out")" != "0" ]] \
  && pass "that same case fails the run's own exit code" \
  || fail "that same case fails the run's own exit code (rc=$(rc_of "$out"))"
rm -f "$CASES/071-forgot-finish.sh"

# ── Timeout is enforced per case, not per run ─────────────────────────────────
mkcase 090-hang "fast" "docker" 'echo "PASS: started"; sleep 60'
out="$(IT_FORCE_CAPS="docker" run_it --tags fast --timeout 2)"
has "$out" '090-hang.*FAIL.*timed out' \
  && pass "a hanging case is killed and reported as timed out" \
  || fail "a hanging case is killed and reported as timed out"
rm -f "$CASES/090-hang.sh"

# ── A case's own `# timeout:` header overrides the run's --timeout/default ────
# Added for the packages tier: 700/710/720 budget an agent-tier install (four
# npm global installs, a uv tool install, a vale download) at up to 30
# minutes, which the corpus-wide 300s default was never sized for, and
# nightly.yml runs with no --timeout flag at all — the only CI path these
# cases take. Three scenarios, matching the three ways this can go wrong:
# the header is ignored, the fallback silently reapplies 300 instead of
# genuinely inheriting $timeout_secs, or a malformed value is swallowed
# instead of failing loudly.
#
# Header PRESENT: a short per-case budget must be honoured even when the
# run's own --timeout is much larger — proves the header, not just $timeout_secs,
# reached it_timeout. Checking the reported NUMBER (not just "timed out") is
# what makes this discriminating: a run.sh that read the header but still
# reported $timeout_secs in the failure line would pass a weaker assertion.
cat > "$CASES/096-timeout-header.sh" <<'EOF'
#!/usr/bin/env bash
# tags: timeoutheader
# requires: docker
# timeout: 2
echo "PASS: started"
sleep 30
EOF
out="$(IT_FORCE_CAPS="docker" run_it --tags timeoutheader --timeout 300)"
has "$out" '096-timeout-header.*FAIL.*timed out after 2s' \
  && pass "a case's own timeout: header overrides a larger --timeout default" \
  || fail "a case's own timeout: header overrides a larger --timeout default -- got: $out"
rm -f "$CASES/096-timeout-header.sh"

# Header ABSENT: falls back to the run's own $timeout_secs (--timeout, or its
# 300s default) — asserted against a DELIBERATELY non-default value (3, not
# 300) so this cannot pass by coincidence against the hardcoded default.
cat > "$CASES/097-timeout-default.sh" <<'EOF'
#!/usr/bin/env bash
# tags: timeoutdefault
# requires: docker
echo "PASS: started"
sleep 30
EOF
out="$(IT_FORCE_CAPS="docker" run_it --tags timeoutdefault --timeout 3)"
has "$out" '097-timeout-default.*FAIL.*timed out after 3s' \
  && pass "a case with no timeout: header falls back to the run's own --timeout/default" \
  || fail "a case with no timeout: header falls back to the run's own --timeout/default -- got: $out"
rm -f "$CASES/097-timeout-default.sh"

# Header MALFORMED: a loud, run-aborting error — never a silent revert to 300.
# A silent fallback here is exactly the failure this key exists to prevent
# from recurring under a different name: a case author who mistypes the
# value would otherwise get 300s back with no signal at all, the same gap
# that let 700/710/720 go unbudgeted in the first place.
cat > "$CASES/098-timeout-bad.sh" <<'EOF'
#!/usr/bin/env bash
# tags: timeoutbad
# requires: docker
# timeout: notanumber
echo "PASS: should never run"
exit 0
EOF
out="$(IT_FORCE_CAPS="docker" run_it --tags timeoutbad)"
rc="$(rc_of "$out")"
[[ "$rc" -ne 0 ]] \
  && pass "a non-numeric timeout: header fails the run loudly" \
  || fail "a non-numeric timeout: header fails the run loudly (rc=$rc)"
has "$out" '098-timeout-bad' \
  && pass "the error names the offending case" \
  || fail "the error names the offending case -- got: $out"
rm -f "$CASES/098-timeout-bad.sh"

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

# ── A failing case's CONTAINER LOGS survive the diagnostics tail too ──────────
# Task 14a (Finding 3): the case above pins that the assertion lines survive —
# they are printed unconditionally, ahead of any tail. This one pins the
# SEPARATE fix one layer down, inside the diagnostics tail itself. A real
# failing case's log is: its own PASS:/FAIL: lines, then (if it called
# it_diagnose, directly or via lib.sh's EXIT trap) "── DIAGNOSTICS … ──"
# followed by "── docker logs (last 60) ──" FIRST and iptables -S/ipset/
# capture-dir output AFTER it — and that trailing material routinely exceeds
# 40 lines on its own. A plain `tail -40` therefore kept only the LATER
# sections and silently dropped the container logs — the actual record of
# what the entrypoint/reconcile/agent did, and (per the task's real CI
# failure) the one part a human needed to diagnose the bug. This synthetic
# case reproduces that exact shape: one container-log line, then 60 lines of
# iptables-style noise AFTER it — enough to push the container-log line
# outside a raw last-40-lines window with margin, the same 60-line sizing
# 100-loud-fail already established above for the identical reason. This can
# only pass if run.sh extracts and prints the "docker logs" section
# separately and unconditionally, not by luck of the tail's position.
mkcase 101-diag-container-logs "fast" "docker" \
  'echo "FAIL: distinctive-marker-diag-fail";
   printf "%s\n" "── DIAGNOSTICS fake-cid-101 ──";
   printf "%s\n" "   ── docker logs (last 60) ──";
   printf "%s\n" "     distinctive-container-log-line-101";
   printf "%s\n" "   ── iptables -S OUTPUT ──";
   for i in $(seq 1 60); do printf "     iptables-noise-line-%s\n" "$i"; done;
   exit 1'
out="$(IT_FORCE_CAPS="docker" run_it --tags fast)"
has "$out" 'distinctive-container-log-line-101' \
  && pass "a failing case's container-log line survives the diagnostics tail" \
  || fail "a failing case's container-log line survives the diagnostics tail"
rm -f "$CASES/101-diag-container-logs.sh"

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

# ── Image variants ─────────────────────────────────────────────────────────────
# The packages tier needs images the default minimal one cannot provide. A typo
# in an `image:` header must be a hard error: silently falling back to `default`
# would run a Ruby case against an image with no Ruby and report the product
# broken.
out="$(bash "$TMP/callfn.sh" variant_overrides agents)"
case "$out" in
  *copilot=ON*claude-code=ON*codex=ON*gemini=ON*graphify=ON*vale=ON*node=22,20*)
    pass "variant agents turns on all six agent-tier keys and multi-version node" ;;
  *) fail "variant agents overrides — got: $out" ;;
esac

out="$(bash "$TMP/callfn.sh" variant_overrides native)"
case "$out" in
  *db-clients=pg,mysql,mongo*imagemagick=ON*wkhtmltopdf=ON*ruby=3.3.6,3.4.5*)
    pass "variant native carries the KEEP_BUILD_TOOLCHAIN components and both rubies" ;;
  *) fail "variant native overrides — got: $out" ;;
esac

out="$(IT_RUBY_VERSIONS=3.4.5 bash "$TMP/callfn.sh" variant_overrides native)"
case "$out" in
  *ruby=3.4.5*) pass "IT_RUBY_VERSIONS overrides the native variant's ruby list" ;;
  *)            fail "IT_RUBY_VERSIONS override — got: $out" ;;
esac

bash "$TMP/callfn.sh" variant_overrides no-such-variant >/dev/null 2>&1
if [[ "$?" -ne 0 ]]; then
  pass "an unknown variant is rejected, not silently treated as default"
else
  fail "an unknown variant is rejected — a typo would run a case on the wrong image"
fi

check "variant_image default is the plain image tag" \
  "ai-sandbox-it" "$(bash "$TMP/callfn.sh" variant_image default)"
check "variant_image agents is suffixed" \
  "ai-sandbox-it-agents" "$(bash "$TMP/callfn.sh" variant_image agents)"

# case_variant: header present, header absent, header with extra spacing
printf '#!/usr/bin/env bash\n# tags:  packages\n# image:    agents\n' > "$TMP/c-with.sh"
printf '#!/usr/bin/env bash\n# tags:  mounts\n' > "$TMP/c-without.sh"
check "case_variant reads the image header" \
  "agents" "$(bash "$TMP/callfn.sh" case_variant "$TMP/c-with.sh")"
check "case_variant defaults when the header is absent" \
  "default" "$(bash "$TMP/callfn.sh" case_variant "$TMP/c-without.sh")"

# ── --variant CLI selector ─────────────────────────────────────────────────────
# Task 13: the nightly `packages` job is split into one job per variant, each
# calling run.sh with `--variant <name>` so it only runs ITS half of the tier.
# --variant must COMPOSE with --tags/--exclude (narrow a tag-selected set to one
# image), not replace them — and an unrecognised name must fail loudly, naming
# itself as the cause, rather than silently falling through to the generic
# "selected 0 cases" message a mistyped --tags gets (that message is true but
# does not say WHICH thing was wrong).
#
# Numbers picked well outside every range mkcase()/other blocks in this file
# use (010-100, plus the string-prefixed avariant*/zvariant* names) so there is
# no collision regardless of execution order.
cat > "$CASES/150-variant-agents.sh" <<'EOF'
#!/usr/bin/env bash
# tags: varsel
# requires: docker
# image: agents
echo "PASS: agents-variant case"
exit 0
EOF
cat > "$CASES/151-variant-native.sh" <<'EOF'
#!/usr/bin/env bash
# tags: varsel
# requires: docker
# image: native
echo "PASS: native-variant case"
exit 0
EOF
cat > "$CASES/152-variant-default.sh" <<'EOF'
#!/usr/bin/env bash
# tags: varsel
# requires: docker
echo "PASS: default-variant case"
exit 0
EOF

# PRESENT: --variant agents, combined with --tags varsel, selects ONLY the
# agents-variant case out of the three that share the tag.
out="$(IT_FORCE_CAPS="docker" run_it --tags varsel --variant agents)"
has "$out" 'selected 1 of' \
  && pass "--tags + --variant agents narrows a tag-selected set to just that variant" \
  || fail "--tags + --variant agents narrows a tag-selected set to just that variant -- got: $(printf '%s' "$out" | grep selected)"
has "$out" '150-variant-agents.*PASS' \
  && pass "--variant agents selects the agents-variant case" \
  || fail "--variant agents selects the agents-variant case -- got: $out"
has "$out" '151-variant-native' \
  && fail "--variant agents must not select the native-variant case -- got: $out" \
  || pass "--variant agents excludes the native-variant case"
has "$out" '152-variant-default' \
  && fail "--variant agents must not select the default-variant case -- got: $out" \
  || pass "--variant agents excludes the default-variant case"

# ABSENT: omitting --variant is unchanged behaviour — --tags alone still
# selects across every variant, exactly as it did before this flag existed.
out="$(IT_FORCE_CAPS="docker" run_it --tags varsel)"
has "$out" 'selected 3 of' \
  && pass "omitting --variant selects across all variants (pre-existing behaviour preserved)" \
  || fail "omitting --variant selects across all variants -- got: $(printf '%s' "$out" | grep selected)"

# UNKNOWN NAME: a typo must be a loud, SPECIFIC error — not the generic
# zero-selection message a mistyped --tags produces, which never says the
# variant name itself is the problem.
out="$(IT_FORCE_CAPS="docker" run_it --tags varsel --variant no-such-variant)"
rc="$(rc_of "$out")"
[[ "$rc" -ne 0 ]] \
  && pass "an unknown --variant name fails the run" \
  || fail "an unknown --variant name fails the run (rc=$rc)"
has "$out" 'unknown variant' \
  && pass "the unknown-variant error names the real cause" \
  || fail "the unknown-variant error names the real cause -- got: $out"
has "$out" 'no case was selected' \
  && fail "the unknown-variant error must be distinct from the generic zero-selection message -- got: $out" \
  || pass "the unknown-variant error is distinct from the generic zero-selection message"

rm -f "$CASES/150-variant-agents.sh" "$CASES/151-variant-native.sh" "$CASES/152-variant-default.sh"

# ── --cases CLI selector ────────────────────────────────────────────────────────
# Task 11b: nightly.yml's packages-agents/packages-native jobs hardcode `--tags
# packages --variant <name> --require packages` and never read any
# workflow_dispatch input, so a mutation demonstration cannot select just the
# ONE case a patch targets — every other case sharing that variant runs
# alongside it regardless of which patch is applied. --cases composes with
# --tags/--exclude/--variant (narrows further, exactly like --variant already
# does), so a demonstration can ask for e.g. `--tags packages --variant native
# --cases 760-ruby-persists-no-recompile` and skip the other three
# native-variant cases entirely. That is not just about keeping a
# demonstration's output attributable to one patch — at least one of the seven
# mutations this flag exists to isolate (760's rvm_volume_name change) breaks
# every launcher_up call for its group, not just its own two, so running it
# alongside 730/740/750 risks the whole job blowing its outer timeout before
# any per-case result is even reported.
out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --cases 010-alpha)"
has "$out" 'selected 1 of' \
  && pass "--cases alone selects exactly the named case" \
  || fail "--cases alone selects exactly the named case -- got: $(printf '%s' "$out" | grep selected)"
has "$out" '010-alpha.*PASS' \
  && pass "--cases 010-alpha selects and runs 010-alpha" \
  || fail "--cases 010-alpha selects and runs 010-alpha -- got: $out"
has "$out" '020-beta' \
  && fail "--cases 010-alpha must not select an unnamed case -- got: $out" \
  || pass "--cases 010-alpha excludes every other case"

out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --cases 010-alpha,030-gamma)"
has "$out" 'selected 2 of' \
  && pass "--cases accepts a comma-separated list" \
  || fail "--cases accepts a comma-separated list -- got: $(printf '%s' "$out" | grep selected)"
if has "$out" '010-alpha.*PASS' && has "$out" '030-gamma.*PASS'; then
  pass "--cases with two names selects and runs both"
else
  fail "--cases with two names selects and runs both -- got: $out"
fi

# COMPOSES with --tags, narrowing rather than replacing: --tags security alone
# selects several cases (010/030/050/060/070/080); --cases narrows that down
# to exactly one, the same relationship --variant already has to --tags.
out="$(IT_FORCE_CAPS="docker netadmin dns" run_it --tags security --cases 010-alpha)"
has "$out" 'selected 1 of' \
  && pass "--tags + --cases narrows a tag-selected set to just the named case" \
  || fail "--tags + --cases narrows a tag-selected set to just the named case -- got: $(printf '%s' "$out" | grep selected)"
has "$out" '060-zeta' \
  && fail "--tags + --cases must not admit a same-tag case outside the --cases list -- got: $out" \
  || pass "--tags + --cases excludes a same-tag case outside the --cases list"

# UNKNOWN NAME: loud and specific, the same precedent --variant already sets —
# not the generic zero-selection message, which never names the bad value.
out="$(IT_FORCE_CAPS="docker" run_it --cases no-such-case)"
rc="$(rc_of "$out")"
[[ "$rc" -ne 0 ]] \
  && pass "an unknown --cases name fails the run" \
  || fail "an unknown --cases name fails the run (rc=$rc)"
has "$out" 'unknown case' \
  && pass "the unknown-cases error names the real cause" \
  || fail "the unknown-cases error names the real cause -- got: $out"
has "$out" 'no case was selected' \
  && fail "the unknown-cases error must be distinct from the generic zero-selection message -- got: $out" \
  || pass "the unknown-cases error is distinct from the generic zero-selection message"

# ── --cases + --variant: known names, wrong variant (task 11c) ─────────────────
# nightly.yml's packages-agents/packages-native jobs both thread the SAME
# `cases` workflow_dispatch input into `--tags packages --variant <name>
# ${cases:+--cases <cases>}`. A dispatch plan built for one variant's cases
# (e.g. `--cases 700-agent-tools-install-restricted`, an agents-tier case)
# therefore ALSO reaches the sibling job as
# `--variant native --cases 700-agent-tools-install-restricted` — a real,
# known name that simply belongs to the other variant. That must be a clean,
# deliberate no-op (rc 0, explicit message), never conflated with an unknown
# name (rc 2, tested above) or the generic zero-selection FATAL (rc 1).
#
# Numbers picked well outside every other block's range in this file so there
# is no collision regardless of execution order.
cat > "$CASES/160-cv-agents.sh" <<'EOF'
#!/usr/bin/env bash
# tags: cvsel cvagentsonly
# requires: docker
# image: agents
echo "PASS: cv-agents case"
exit 0
EOF
cat > "$CASES/161-cv-native.sh" <<'EOF'
#!/usr/bin/env bash
# tags: cvsel
# requires: docker
# image: native
echo "PASS: cv-native case"
exit 0
EOF

# KNOWN NAME, WRONG VARIANT: --cases names a real, agents-tier case; --variant
# asks for native. Must exit 0 (not 1, not 2) with a message naming BOTH the
# variant the case actually belongs to (agents) and the variant that was
# asked for (native) — never the generic zero-selection text, and never the
# unknown-name text (this name is real).
out="$(IT_FORCE_CAPS="docker" run_it --tags cvsel --variant native --cases 160-cv-agents)"
rc="$(rc_of "$out")"
[[ "$rc" -eq 0 ]] \
  && pass "--cases naming a known case in the WRONG --variant exits 0, not fatal" \
  || fail "--cases naming a known case in the WRONG --variant exits 0, not fatal (rc=$rc) -- got: $out"
has "$out" 'belonging to variant "agents"' \
  && pass "the wrong-variant message names the variant the case actually belongs to" \
  || fail "the wrong-variant message names the variant the case actually belongs to -- got: $out"
has "$out" 'variant "native"' \
  && pass "the wrong-variant message names the --variant that was asked for" \
  || fail "the wrong-variant message names the --variant that was asked for -- got: $out"
has "$out" 'no case was selected' \
  && fail "the wrong-variant no-op must be distinct from the generic zero-selection FATAL -- got: $out" \
  || pass "the wrong-variant no-op is distinct from the generic zero-selection FATAL"
has "$out" 'unknown case' \
  && fail "the wrong-variant no-op must be distinct from the unknown-cases error -- got: $out" \
  || pass "the wrong-variant no-op is distinct from the unknown-cases error"
has "$out" '160-cv-agents.*PASS' \
  && fail "the wrong-variant no-op must not actually run the case -- got: $out" \
  || pass "the wrong-variant no-op does not run the case"

# KNOWN NAME, RIGHT VARIANT: same case, same tag, --variant now matches its
# OWN image header — runs exactly that one case, unchanged from ordinary
# --cases + --variant composition (the packages-agents job's own shape).
out="$(IT_FORCE_CAPS="docker" run_it --tags cvsel --variant agents --cases 160-cv-agents)"
has "$out" 'selected 1 of' \
  && pass "--cases naming a known case in the RIGHT --variant selects exactly it" \
  || fail "--cases naming a known case in the RIGHT --variant selects exactly it -- got: $(printf '%s' "$out" | grep selected)"
has "$out" '160-cv-agents.*PASS' \
  && pass "--cases + matching --variant runs the named case" \
  || fail "--cases + matching --variant runs the named case -- got: $out"

# UNCHANGED (ordinary case): a scheduled run supplies no --cases at all, so
# --variant alone still selects normally across a variant that DOES have a
# matching case.
out="$(IT_FORCE_CAPS="docker" run_it --tags cvsel --variant native)"
has "$out" '161-cv-native.*PASS' \
  && pass "--tags + --variant alone (no --cases) still selects normally across the variant" \
  || fail "--tags + --variant alone (no --cases) still selects normally across the variant -- got: $out"

# UNCHANGED (gating proof): this is the case the new diagnostic must NOT
# soften. --tags cvagentsonly matches ONLY the agents-tier case, so
# --variant native --without --cases zeroes the selection exactly as it did
# before this fix -- proving the new exit-0 path is --cases-gated, not a
# general --variant/--tags mismatch becoming non-fatal.
out="$(IT_FORCE_CAPS="docker" run_it --tags cvagentsonly --variant native)"
rc="$(rc_of "$out")"
[[ "$rc" -ne 0 ]] \
  && pass "--tags + --variant alone (no --cases) still FAILS on a real zero intersection" \
  || fail "--tags + --variant alone (no --cases) still FAILS on a real zero intersection (rc=$rc) -- got: $out"
has "$out" 'no case was selected' \
  && pass "the no-op fast path never fires without --cases -- ordinary FATAL message still appears" \
  || fail "the no-op fast path never fires without --cases -- got: $out"

rm -f "$CASES/160-cv-agents.sh" "$CASES/161-cv-native.sh"

# case_timeout, as a pure function (see the full run_it() scenarios above for
# the end-to-end "it actually changes what it_timeout kills at" proof — these
# three pin the parsing/validation contract in isolation).
printf '#!/usr/bin/env bash\n# tags: t\n# timeout: 1800\n' > "$TMP/to-with.sh"
printf '#!/usr/bin/env bash\n# tags: t\n'                  > "$TMP/to-without.sh"
printf '#!/usr/bin/env bash\n# tags: t\n# timeout: notanumber\n' > "$TMP/to-bad.sh"

check "case_timeout reads the timeout header" \
  "1800" "$(bash "$TMP/callfn.sh" case_timeout "$TMP/to-with.sh")"

# $timeout_secs is run.sh's own literal default (300, set before the
# CLI-option loop the IT_SOURCE_ONLY early return skips), never CLI input —
# callfn.sh passes no --timeout, so this can only read back 300 if
# case_timeout genuinely falls through to the script's own variable rather
# than a hardcoded literal of its own.
check "case_timeout defaults to \$timeout_secs when the header is absent" \
  "300" "$(bash "$TMP/callfn.sh" case_timeout "$TMP/to-without.sh")"

bash "$TMP/callfn.sh" case_timeout "$TMP/to-bad.sh" >/dev/null 2>&1
if [[ "$?" -ne 0 ]]; then
  pass "case_timeout rejects a non-numeric header instead of silently defaulting"
else
  fail "case_timeout rejects a non-numeric header instead of silently defaulting"
fi

# ── Variant scheduling ─────────────────────────────────────────────────────────
# Grouping matters for DISK, not tidiness: a GitHub runner has ~14 GB free and
# these images are multi-GB. Building all variants up front and removing them at
# the end would peak at the sum. Build → run that variant's cases → rmi → next
# peaks at one.
printf '#!/usr/bin/env bash\n# image: agents\n'  > "$TMP/v-a1.sh"
printf '#!/usr/bin/env bash\n# image: native\n'  > "$TMP/v-n1.sh"
printf '#!/usr/bin/env bash\n# tags: mounts\n'   > "$TMP/v-d1.sh"
printf '#!/usr/bin/env bash\n# image: agents\n'  > "$TMP/v-a2.sh"

check "selected_variants lists each variant once, in first-seen order" \
  "agents native default" \
  "$(bash "$TMP/callfn.sh" selected_variants "$TMP/v-a1.sh" "$TMP/v-n1.sh" "$TMP/v-d1.sh" "$TMP/v-a2.sh")"

check "selected_variants of a default-only selection does not name a packages variant" \
  "default" "$(bash "$TMP/callfn.sh" selected_variants "$TMP/v-d1.sh")"

# ── sweep() must still target the DEFAULT image after the variant loop ────────
# The loop exports IT_IMAGE afresh on every iteration (variant_image "$v"), and
# sweep() — run.sh's own EXIT trap — reads that SAME global to decide what to
# `docker rmi` / report as kept. If the last variant processed is not `default`
# (the common case in a real corpus, where packages-tier cases sort after the
# rest), IT_IMAGE is left pointing at that last variant's tag, not the
# default's. sweep()'s per-variant rmi already excludes `default` deliberately
# (see the loop's own `[[ "$v" != "default" ]]` guard) — but that guard is
# pointless if sweep() itself can no longer find the default image to remove
# EITHER, once IT_IMAGE has drifted. That is a silent multi-GB leak on every
# real (non-"--reuse-image") run, not a hermetic-test artifact: --keep's own
# "kept: image …" message is the one place this is observable without a real
# daemon, since the actual `docker rmi` calls are gated off entirely under
# --reuse-image (both the per-variant one and sweep()'s).
#
# Two cases sharing one tag, filenames chosen so the default-variant case
# sorts BEFORE the agents-variant case in all_cases()'s glob order — the
# ordering a real corpus has today (packages-tier cases are numbered after
# the existing tiers), so this reproduces the failure mode rather than a
# contrived one.
cat > "$CASES/avariantsweep-default.sh" <<'EOF'
#!/usr/bin/env bash
# tags: variantsweep
# requires: docker
echo "PASS: default-variant case"
exit 0
EOF
cat > "$CASES/zvariantsweep-agents.sh" <<'EOF'
#!/usr/bin/env bash
# tags: variantsweep
# requires: docker
# image: agents
echo "PASS: agents-variant case"
exit 0
EOF
out="$(IT_FORCE_CAPS="docker" PATH="$FAKE_BIN:$PATH" IT_CASES_DIR="$CASES" \
      IT_SCRATCH="$TMP/scratch-variant-sweep" \
      bash "$RUN" --reuse-image --image fake-img --keep --tags variantsweep 2>&1)"
rm -f "$CASES/avariantsweep-default.sh" "$CASES/zvariantsweep-agents.sh"
has "$out" 'kept: image fake-img,' \
  && pass "sweep() still names the default image after a later variant ran" \
  || fail "sweep() still names the default image after a later variant ran -- got: $(printf '%s' "$out" | grep 'kept:')"

# ── The unknown-variant `exit 1` must not bypass that same protection ─────────
# Code review on the fix above found the gap in it: the save/restore only
# covered the loop's NORMAL exit (falling through past `done`). The loop's
# OTHER exit — an unrecognized `image:` header hits `exit 1` straight out of
# the middle of the loop — skips the restore entirely, so the bug reproduces
# whenever that hard error fires after at least one non-default variant has
# already run. Same file-ordering trick as above (agents sorts first, so
# IT_IMAGE is already pointing at the agents tag by the time the bogus-header
# case is reached), but the second case carries an unrecognized `image:`
# value instead of a valid one.
cat > "$CASES/avariantexit-agents.sh" <<'EOF'
#!/usr/bin/env bash
# tags: variantexit
# requires: docker
# image: agents
echo "PASS: agents-variant case"
exit 0
EOF
cat > "$CASES/zvariantexit-bogus.sh" <<'EOF'
#!/usr/bin/env bash
# tags: variantexit
# requires: docker
# image: totally-bogus-variant
echo "PASS: never runs -- unknown variant aborts first"
exit 0
EOF
out="$(IT_FORCE_CAPS="docker" PATH="$FAKE_BIN:$PATH" IT_CASES_DIR="$CASES" \
      IT_SCRATCH="$TMP/scratch-variant-exit" \
      bash "$RUN" --reuse-image --image fake-img --keep --tags variantexit 2>&1)"
rc="$?"
rm -f "$CASES/avariantexit-agents.sh" "$CASES/zvariantexit-bogus.sh"
[[ "$rc" -ne 0 ]] \
  && pass "an unrecognized image: header still fails the run" \
  || fail "an unrecognized image: header still fails the run (rc=$rc)"
has "$out" 'kept: image fake-img,' \
  && pass "sweep() names the default image even when the loop exits via the unknown-variant error" \
  || fail "sweep() names the default image even when the loop exits via the unknown-variant error -- got: $(printf '%s' "$out" | grep 'kept:')"

# ── multiruby capability ────────────────────────────────────────────────────────
# 750 has nothing to select between when one version is configured, so it must
# SKIP BY NAME rather than pass by testing a one-element list. Derived from the
# resolved IT_RUBY_VERSIONS — a hardcoded `true` here would be exactly the
# decorative check this suite exists to eliminate.
probe_out="$(IT_RUBY_VERSIONS=3.3.6,3.4.5 bash "$TMP/callfn.sh" probe_multiruby; echo "rc=$?")"
case "$probe_out" in *rc=0*) pass "multiruby is present with two versions" ;;
                     *)      fail "multiruby is present with two versions ($probe_out)" ;; esac

probe_out="$(IT_RUBY_VERSIONS=3.4.5 bash "$TMP/callfn.sh" probe_multiruby; echo "rc=$?")"
case "$probe_out" in *rc=1*) pass "multiruby is absent with one version" ;;
                     *)      fail "multiruby is absent with one version ($probe_out)" ;; esac

# An empty IT_RUBY_VERSIONS is not a reachable state to probe here: run.sh's own
# top-level `IT_RUBY_VERSIONS="${IT_RUBY_VERSIONS:-3.3.6,3.4.5}"` normalises it at
# source time — which runs whether run.sh is executed OR sourced, since the
# IT_SOURCE_ONLY early return sits far below that line — and probe_multiruby is
# only ever reached via detect_caps, after that normalisation (or after
# IT_FORCE_CAPS short-circuits detect_caps entirely). An empty case has no
# distinct branch anyway: probe_multiruby's `case` falls "" and "3.4.5" through
# the SAME `*)` arm, so it is already covered by "absent with one version" above.
# No third assertion here on purpose — manufacturing the empty state would test
# something that cannot occur, not add coverage.

# The brief's own draft of this fourth assertion grepped run.sh's SOURCE TEXT for
# the literal registration line `probe_multiruby && c="$c multiruby"`. That proves
# the string exists, not that detect_caps ever executes it — exactly the kind of
# decorative check this suite exists to eliminate. --list-caps is the real
# observation point: it prints the capability list detect_caps actually produced.
#
# It must run through a docker stub that FAILS `docker info`, not merely rely on
# this machine having no `docker` binary at all (this file's own header line 15:
# "fake docker on PATH so nothing can reach a real daemon" — every other real-run.sh
# invocation in this file honors that; this is the one that didn't). On a CI
# runner with a live daemon, an unguarded `--list-caps` call would take the `if
# docker info` branch in detect_caps, run a real `docker network create`/`rm`,
# and then — since `docker image inspect "$IT_DNS_IMAGE"` fails on a machine that
# never pulled it — fall through to `it_timeout 120 docker pull
# coredns/coredns:1.11.3`, a real network pull inside what is supposed to be a
# hermetic unit test. FAKE_BIN/docker above cannot be reused for this: it answers
# `info` and `image inspect` with success, which would route into
# probe_netadmin/probe_launcher and hit their `docker run` calls, which that stub
# does not handle (see its own header comment) and would abort with "unexpected
# call". This stub instead fails `info` outright, so the ENTIRE docker block is
# skipped deterministically regardless of host, while still exercising
# detect_caps's real control flow. It also logs every subcommand it is asked to
# run, so the test can prove the block was genuinely skipped — not merely that
# its output happened to omit multiruby by coincidence.
NOINFO_BIN="$TMP/bin-noinfo"; mkdir -p "$NOINFO_BIN"
NOINFO_LOG="$TMP/noinfo-docker.log"
: > "$NOINFO_LOG"
cat > "$NOINFO_BIN/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOINFO_LOG"
exit 1
EOF
chmod +x "$NOINFO_BIN/docker"

out="$(IT_RUBY_VERSIONS=3.3.6,3.4.5 PATH="$NOINFO_BIN:$PATH" bash "$RUN" --list-caps 2>&1)"
case "$out" in *multiruby*) pass "detect_caps reports multiruby when two versions are configured" ;;
               *)           fail "detect_caps reports multiruby when two versions are configured ($out)" ;; esac

# The positive check above could pass even if the docker block silently ran and
# just happened not to break anything on this host, so it does not by itself
# prove the block was skipped. Two independent confirmations that it was:
case "$out" in *" docker "*) fail "docker capability must not appear once \`docker info\` fails ($out)" ;;
               *)            pass "docker capability is absent once \`docker info\` fails, confirming the gate held" ;; esac

log_contents="$(cat "$NOINFO_LOG")"
case "$log_contents" in
  info) pass "the docker stub saw exactly one call (info) and detect_caps stopped there" ;;
  *)    fail "the docker stub saw exactly one call (info) and detect_caps stopped there -- got: $log_contents" ;;
esac

# ── Task 13b: capability probes must not go blind when only a --variant
#    image was built ────────────────────────────────────────────────────────
# The real CI regression: a per-variant job builds ai-sandbox-it-agents and
# NEVER builds the default ai-sandbox-it tag detect_caps used to hardcode.
# The netadmin/launcher gate's `docker image inspect "$IT_IMAGE"` was always
# false, so both probes were skipped entirely — reporting netadmin/launcher
# ABSENT when the truth was "nothing was ever built to probe with". Every
# launcher/netadmin case then SKIPPED, and --require turned that into a
# confusing red run (see task 13b's brief).
#
# Reproduced and fixed with NO real docker daemon: a fake `docker image
# inspect` that succeeds ONLY for the variant tag (never the default), plus
# fake probe_netadmin/probe_launcher (the REAL ones start actual containers,
# which needs a daemon and is covered by the runtime integration suite, not
# this hermetic one — see AGENTS.md's "Two tiers, two verbs").
CAPS_BIN="$TMP/bin-caps"; mkdir -p "$CAPS_BIN"
cat > "$CAPS_BIN/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  info*)             exit 0 ;;
  "network create")  echo "it-net-fake"; exit 0 ;;
  "network rm")       exit 0 ;;
  "image inspect")
    # $3 is the tag under test -- only the AGENTS VARIANT's tag "exists".
    # The default ai-sandbox-it tag is deliberately never built in this
    # scenario, matching the CI job that only builds ai-sandbox-it-agents.
    [[ "$3" == "ai-sandbox-it-agents" ]] && exit 0
    exit 1 ;;
  pull*)              exit 1 ;;  # offline-safe: never really reach a registry
  *) exit 1 ;;
esac
EOF
chmod +x "$CAPS_BIN/docker"

cat > "$TMP/caps-case.sh" <<'EOF'
#!/usr/bin/env bash
# tags: caps13b
# requires: docker netadmin launcher
# image: agents
echo "PASS: never actually executed by this test"
EOF

CAPS_BUILD_LOG="$TMP/caps-build.log"
cat > "$TMP/caps-probe.sh" <<EOF
#!/usr/bin/env bash
export IT_SOURCE_ONLY=1
export IT_IMAGE="ai-sandbox-it"
source "$RUNNER"
# Stand in for a real build: just record which variant was asked for. This
# test is about WHICH image detect_caps ends up pointed at, not about
# build.sh/docker build itself.
build_image() { printf '%s\n' "\$1" >> "$CAPS_BUILD_LOG"; return 0; }
probe_netadmin() { return 0; }
probe_launcher() { return 0; }
ensure_caps_image "\$1"
detect_caps
printf 'IT_CAPS_IMAGE=%s\n' "\$IT_CAPS_IMAGE"
printf 'caps=%s\n' "\$_caps"
EOF
chmod +x "$TMP/caps-probe.sh"

: > "$CAPS_BUILD_LOG"
out="$(PATH="$CAPS_BIN:$PATH" bash "$TMP/caps-probe.sh" "$TMP/caps-case.sh" 2>&1)"

has "$out" 'IT_CAPS_IMAGE=ai-sandbox-it-agents' \
  && pass "capability detection probes the variant that actually got built, not the unbuilt default tag" \
  || fail "capability detection probes the variant that actually got built -- got: $out"
has "$out" 'caps=.*netadmin' \
  && pass "netadmin is detected once a variant image exists, even though the default tag was never built" \
  || fail "netadmin is detected once a variant image exists -- got: $out"
has "$out" 'caps=.*launcher' \
  && pass "launcher is detected once a variant image exists, even though the default tag was never built" \
  || fail "launcher is detected once a variant image exists -- got: $out"
[[ "$(cat "$CAPS_BUILD_LOG")" == "agents" ]] \
  && pass "capability detection builds only the one variant it needs, exactly once" \
  || fail "capability detection builds only the one variant it needs, exactly once -- got: $(cat "$CAPS_BUILD_LOG" | tr '\n' ' ')"

# ── --list-caps must never report "undetermined" as "absent" ──────────────────
# --list-caps deliberately never builds (see the runner's own comment on that
# flag): probing accurately can require a build, and --list-caps must not
# perform one just to answer a question. But it also must not let "we never
# checked" read as "checked, and no" -- that collapse is the exact defect
# class task 13b exists to eliminate, and it's what made this failure
# confusing instead of obvious in the first place.
LISTCAPS_BIN="$TMP/bin-listcaps"; mkdir -p "$LISTCAPS_BIN"
cat > "$LISTCAPS_BIN/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  info*)             exit 0 ;;
  "network create")  echo "it-net-fake"; exit 0 ;;
  "network rm")       exit 0 ;;
  "image inspect")    exit 1 ;;   # nothing has ever been built, not even the default
  pull*)              exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$LISTCAPS_BIN/docker"

out="$(PATH="$LISTCAPS_BIN:$PATH" bash "$RUN" --list-caps 2>&1)"
cap_line="$(printf '%s\n' "$out" | grep '^capabilities:')"

has "$cap_line" ' docker ' \
  && pass "--list-caps: docker is still detected (proves the docker-info block engaged, not skipped)" \
  || fail "--list-caps: docker is still detected -- got: $cap_line"
has "$cap_line" 'netadmin' \
  && fail "--list-caps must not claim netadmin is a known capability when it was never probed -- got: $cap_line" \
  || pass "--list-caps: netadmin does not appear in the plain capabilities line when unprobed"
has "$out" 'undetermined' \
  && pass "--list-caps reports an explicit undetermined state distinct from absent" \
  || fail "--list-caps reports an explicit undetermined state distinct from absent -- got: $out"
has "$out" 'undetermined.*netadmin' \
  && pass "the undetermined line names netadmin" \
  || fail "the undetermined line names netadmin -- got: $out"
has "$out" 'undetermined.*launcher' \
  && pass "the undetermined line names launcher" \
  || fail "the undetermined line names launcher -- got: $out"

# ── --reuse-image must keep short-circuiting unchanged ─────────────────────────
# The pre-existing behaviour this fix must not disturb: with --reuse-image, no
# build ever happens (a developer's own pre-built image is trusted as-is), and
# capability probing still runs directly against $IT_IMAGE, exactly as it did
# before --variant/ensure_caps_image existed.
CAPS_BUILD_LOG2="$TMP/caps-build-reuse.log"
cat > "$TMP/caps-reuse-probe.sh" <<EOF
#!/usr/bin/env bash
export IT_SOURCE_ONLY=1
export IT_IMAGE="ai-sandbox-it"
source "$RUNNER"
reuse_image=1
build_image() { printf '%s\n' "\$1" >> "$CAPS_BUILD_LOG2"; return 0; }
probe_netadmin() { return 0; }
probe_launcher() { return 0; }
ensure_caps_image "\$1"
detect_caps
printf 'IT_CAPS_IMAGE=%s\n' "\$IT_CAPS_IMAGE"
printf 'caps=%s\n' "\$_caps"
EOF
chmod +x "$TMP/caps-reuse-probe.sh"

: > "$CAPS_BUILD_LOG2"
out="$(PATH="$CAPS_BIN:$PATH" bash "$TMP/caps-reuse-probe.sh" "$TMP/caps-case.sh" 2>&1)"

[[ ! -s "$CAPS_BUILD_LOG2" ]] \
  && pass "--reuse-image never triggers a build, even to determine capabilities" \
  || fail "--reuse-image never triggers a build, even to determine capabilities -- got: $(cat "$CAPS_BUILD_LOG2" | tr '\n' ' ')"
has "$out" 'IT_CAPS_IMAGE=ai-sandbox-it' \
  && pass "--reuse-image probes the plain --image tag, unchanged from before this fix" \
  || fail "--reuse-image probes the plain --image tag, unchanged from before this fix -- got: $out"
has "$out" 'caps=.*netadmin' \
  && pass "--reuse-image's short-circuit still lets netadmin be detected (gate bypassed, not blocked)" \
  || fail "--reuse-image's short-circuit still lets netadmin be detected -- got: $out"

# ── Task 13c: the PLAIN default-variant run must not freeze netadmin/launcher
#    absent ───────────────────────────────────────────────────────────────────
# Task 13b's tests above cover only three shapes: a --variant-mismatched image
# (agents built, default never built), --list-caps before any build, and
# --reuse-image. None of those is the shape that actually runs in CI's PR gate
# (.github/workflows/integration.yml: --tags fast --exclude … --require
# security) or verify-on-host.sh (--require security, no --variant at all): no
# --variant flag, nothing built yet, a selection needing netadmin/launcher.
# c3b66de fixed the GENERAL case (ensure_caps_image before detect_caps), but
# nothing pinned this specific shape — a reviewer found the gap after the fix
# landed.
#
# This drives the REAL script end-to-end, not IT_SOURCE_ONLY + a direct
# function call (which would skip straight past the actual question — does
# ensure_caps_image's build genuinely run before detect_caps in the real
# top-to-bottom flow?) and not --reuse-image (which bypasses build_image()
# entirely, i.e. bypasses the very code this gap is about). run.sh forks its
# own build.sh and, inside probe_launcher, docker-shim.sh — so the script
# under test is copied into a throwaway REPO_DIR alongside stand-ins for both,
# with a stub `docker` on PATH whose `image inspect` succeeds only once the
# stub build.sh has actually touched a marker for that tag: the same
# build-marker idiom task-13b's fake docker uses above (there, a hardcoded
# tag), just earned here by a REAL build_image() call instead of asserted by
# fiat. No real docker daemon anywhere.
#
# Demonstrated failing against e4d62f5 (the commit before c3b66de) before
# being confirmed against the current file — see task-13c-report.md for the
# verbatim red output this produced there.
CAPS13C_REPO="$TMP/caps13c-repo"
mkdir -p "$CAPS13C_REPO/tests/integration/cases"
cp "$RUN" "$CAPS13C_REPO/tests/integration/run.sh"
cp "$REPO_DIR/tests/integration/minimal-conf.sh" "$CAPS13C_REPO/tests/integration/minimal-conf.sh"
cp "$REPO_DIR/tests/integration/docker-shim.sh" "$CAPS13C_REPO/tests/integration/docker-shim.sh"
chmod +x "$CAPS13C_REPO/tests/integration/run.sh" \
         "$CAPS13C_REPO/tests/integration/minimal-conf.sh" \
         "$CAPS13C_REPO/tests/integration/docker-shim.sh"

# Content is irrelevant beyond being valid key=VALUE lines: minimal-conf.sh
# only strips ON/list keys down to OFF/empty; nothing here is ever built for
# real.
cat > "$CAPS13C_REPO/sandbox.conf" <<'EOF'
copilot=ON
node=22
ruby=
EOF

CAPS13C_MARKERS="$TMP/caps13c-built-images"
mkdir -p "$CAPS13C_MARKERS"

# Stand-in for the real build.sh: records that IMAGE_NAME was "built" — so a
# later `docker image inspect` on that tag succeeds — without a real docker
# build (there is no daemon here to run one). Mirrors run.sh's own contract:
# build_image() calls `IMAGE_NAME="$img" ./build.sh "$img"`.
cat > "$CAPS13C_REPO/build.sh" <<EOF
#!/usr/bin/env bash
set -u
img="\${1:-\$IMAGE_NAME}"
mkdir -p "$CAPS13C_MARKERS"
touch "$CAPS13C_MARKERS/\$img"
# build.sh also (re)generates allowlist-*.txt in the repo; run.sh's
# build_image() snapshots/restores those and (for the default variant) copies
# them into IT_GENERATED_ALLOWLIST_DIR — give it real files to copy.
: > "\$(dirname "\$0")/allowlist-domains.txt"
: > "\$(dirname "\$0")/allowlist-cidrs.txt"
: > "\$(dirname "\$0")/allowlist-proxy-domains.txt"
exit 0
EOF
chmod +x "$CAPS13C_REPO/build.sh"

# Two synthetic cases, both the DEFAULT variant (no `image:` header) — the
# exact shape of the real regression: a plain run, no --variant anywhere.
# Tags mirror the real corpus's 010 (security) and 400 (security+mounts) so a
# single --require security run makes both cases' skip fail the run, exactly
# as it would have for the real PR gate.
cat > "$CAPS13C_REPO/tests/integration/cases/690-caps13c-netadmin.sh" <<'EOF'
#!/usr/bin/env bash
# tags: security fast
# requires: docker netadmin
echo "PASS: netadmin case attempted"
exit 0
EOF
cat > "$CAPS13C_REPO/tests/integration/cases/695-caps13c-launcher.sh" <<'EOF'
#!/usr/bin/env bash
# tags: security mounts fast
# requires: docker launcher
echo "PASS: launcher case attempted"
exit 0
EOF
chmod +x "$CAPS13C_REPO/tests/integration/cases/"*.sh

CAPS13C_BIN="$TMP/caps13c-bin"
mkdir -p "$CAPS13C_BIN"
cat > "$CAPS13C_BIN/docker" <<EOF
#!/usr/bin/env bash
# No real daemon anywhere. \`image inspect\` is gated on a BUILD MARKER file —
# task-13b's fake docker above gates on a hardcoded tag; this one gates on
# whatever the stub build.sh actually touched, so "nothing has been built yet
# when detect_caps first runs" is a real, earned state, not asserted by fiat.
CAPS13C_MARKERS="$CAPS13C_MARKERS"
case "\$1 \$2" in
  info*)              exit 0 ;;
  "network create")   echo "it-net-fake"; exit 0 ;;
  "network rm")        exit 0 ;;
  "network ls")        exit 0 ;;
  "image inspect")
    [[ -f "\$CAPS13C_MARKERS/\$3" ]] && exit 0 || exit 1 ;;
  "ps -aq")            exit 0 ;;
  "volume ls")          exit 0 ;;
  rmi\ *)               exit 0 ;;
  "rm -f")              exit 0 ;;
  pull*)                exit 1 ;;   # offline-safe; dns capability is irrelevant here
  "inspect -f")
    echo "true"; exit 0 ;;          # probe_launcher's own liveness check
  run*)
    # Covers both probe_netadmin's --cap-add=NET_ADMIN call and
    # probe_launcher's shimmed -d -i run: a successful exit is all either
    # needs here, not a real container.
    exit 0 ;;
  *) echo "fake docker (task-13c): unexpected call: \$*" >&2; exit 99 ;;
esac
EOF
chmod +x "$CAPS13C_BIN/docker"

cat > "$CAPS13C_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# The "external" capability probe is irrelevant here; fail fast rather than
# let a real network attempt slow the run or succeed unpredictably.
exit 1
EOF
chmod +x "$CAPS13C_BIN/curl"

out="$(PATH="$CAPS13C_BIN:$PATH" \
       IT_CASES_DIR="$CAPS13C_REPO/tests/integration/cases" \
       IT_SCRATCH="$TMP/caps13c-scratch" \
       IT_IMAGE="task13c-image" \
       bash "$CAPS13C_REPO/tests/integration/run.sh" --require security 2>&1)"
rc=$?

has "$out" 'capabilities:.*netadmin' \
  && pass "a plain run (no --variant, nothing built yet) still detects netadmin" \
  || fail "a plain run (no --variant, nothing built yet) still detects netadmin -- got: $out"
has "$out" 'capabilities:.*launcher' \
  && pass "a plain run (no --variant, nothing built yet) still detects launcher" \
  || fail "a plain run (no --variant, nothing built yet) still detects launcher -- got: $out"
has "$out" '690-caps13c-netadmin.*PASS' \
  && pass "the netadmin-requiring case is SELECTED and ATTEMPTED, not skipped" \
  || fail "the netadmin-requiring case is SELECTED and ATTEMPTED, not skipped -- got: $out"
has "$out" '695-caps13c-launcher.*PASS' \
  && pass "the launcher-requiring case is SELECTED and ATTEMPTED, not skipped" \
  || fail "the launcher-requiring case is SELECTED and ATTEMPTED, not skipped -- got: $out"
has "$out" 'SKIP' \
  && fail "no case should SKIP once its capability was actually detected -- got: $out" \
  || pass "neither case SKIPped (both capabilities were detected, not frozen absent)"
has "$out" 'undetermined' \
  && fail "a successful build must leave nothing undetermined -- got: $out" \
  || pass "a successful build leaves nothing undetermined (both probes actually ran)"
[[ "$rc" -eq 0 ]] \
  && pass "the PR-gate shape (--require security) exits clean once caps are actually probed" \
  || fail "the PR-gate shape (--require security) exits clean once caps are actually probed -- got rc=$rc"

# ── IT_SOURCE_ONLY halts an EXECUTED run.sh too, not only a sourced one ────────
# The guard is a bare `return`, which only halts a SOURCED script. Executed, it
# fails and the old one-line form fell straight through into the sweep EXIT
# trap, the allowlist snapshot and a real image build — the I/O the guard's own
# comment says it exists to prevent — with the option-parsing loop skipped too,
# so the run would silently ignore every flag it was handed and still exit 0.
#
# No production path executes run.sh with the variable set. That is a
# convention, and this file's whole subject is the difference between a
# convention and a mechanism.
#
# Driven against the caps13c throwaway repo above (its own copy of run.sh, a
# stub build.sh that records what it "built", a stub docker) precisely BECAUSE
# the old behaviour is destructive: falling through touches the repo's
# allowlist files and forks build.sh, so the red demonstration has to happen
# somewhere disposable.
SO_MARKER_TAG="sourceonly-image"
out="$(PATH="$CAPS13C_BIN:$PATH" \
       IT_SOURCE_ONLY=1 \
       IT_CASES_DIR="$CAPS13C_REPO/tests/integration/cases" \
       IT_SCRATCH="$TMP/sourceonly-scratch" \
       IT_IMAGE="$SO_MARKER_TAG" \
       bash "$CAPS13C_REPO/tests/integration/run.sh" --require security 2>&1)"
rc=$?

[[ "$rc" -eq 2 ]] \
  && pass "an EXECUTED run.sh with IT_SOURCE_ONLY set exits 2, not 0" \
  || fail "an EXECUTED run.sh with IT_SOURCE_ONLY set exits 2, not 0 -- got rc=$rc, out: $out"
has "$out" 'IT_SOURCE_ONLY' \
  && pass "the refusal names IT_SOURCE_ONLY as the cause" \
  || fail "the refusal names IT_SOURCE_ONLY as the cause -- got: $out"
# The load-bearing one: a build marker proves the fall-through reached
# build_image() for real. Under the old guard this file exists.
[[ ! -e "$CAPS13C_MARKERS/$SO_MARKER_TAG" ]] \
  && pass "an executed IT_SOURCE_ONLY run builds no image (the guard's whole purpose)" \
  || fail "an executed IT_SOURCE_ONLY run builds no image -- build.sh ran for $SO_MARKER_TAG"
# Second, independent witness that execution stopped at the guard rather than
# merely failing later: detect_caps never printed its banner.
has "$out" 'capabilities:' \
  && fail "an executed IT_SOURCE_ONLY run must not reach capability detection -- got: $out" \
  || pass "an executed IT_SOURCE_ONLY run never reaches capability detection"

# And the other invocation mode is untouched: sourcing still returns cleanly,
# which is what every callfn.sh assertion above depends on.
bash "$TMP/callfn.sh" true >/dev/null 2>&1
[[ "$?" -eq 0 ]] \
  && pass "sourcing run.sh with IT_SOURCE_ONLY still returns 0 (the guard's supported mode)" \
  || fail "sourcing run.sh with IT_SOURCE_ONLY still returns 0"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
