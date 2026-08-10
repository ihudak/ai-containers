#!/usr/bin/env bash
# Hermetic unit test for the PURE verbs in tests/integration/lib.sh — the ones
# with no daemon behind them. The docker verbs are proven for real by the
# 000-harness-selftest case, which is the only honest way to test them.
#
# The comment-filtering assertions are load-bearing: init_output_files seeds
# every capture output file with explanatory headers, so a raw `-s` check reports
# a clean run as "HARD-BLOCKED" and then lists the header lines as if they were
# blocked destinations. That misreading cost a full host round trip.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_DIR/tests/integration/lib.sh"
fails=0
# t_pass/t_fail/t_check — NOT pass/fail/check — is deliberate, not decorative.
# `. "$LIB"` below REDEFINES pass()/fail() (lib.sh:67-68) to increment lib.sh's
# own $it_fails, not this file's $fails. Bash resolves a function name at CALL
# time, not at definition time, so if this file's own assertions used plain
# pass()/fail() they would silently start tallying into the wrong counter the
# moment lib.sh is sourced — $fails would stay 0 no matter how many assertions
# actually failed, and the final `exit "$fails"` would always report success.
# Giving this file's own helpers names lib.sh does not define sidesteps the
# collision instead of fighting sourcing order. The "pass/fail accounting
# drives the case exit code" block further down is the one deliberate
# exception: it calls the REAL (lib.sh) `fail` on purpose, to test lib.sh's
# own behavior — do not "fix" that call to t_fail. Anyone who sources lib.sh
# from another hermetic test should give their own helpers non-colliding
# names too, for the same reason.
t_pass() { printf 'PASS: %s\n' "$1"; }
t_fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
t_check() { if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$LIB" && t_pass "lib.sh bash -n" || t_fail "lib.sh bash -n"

# lib.sh refuses to load without the runner's environment — a case run by hand
# would otherwise inherit whatever IT_IMAGE happened to be lying around.
out="$(env -u IT_RUN_ID -u IT_IMAGE -u IT_NET bash -c ". '$LIB'" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && t_pass "lib.sh refuses to load outside the runner" \
                  || t_fail "lib.sh refuses to load outside the runner"

export IT_RUN_ID=unit IT_IMAGE=unit-img IT_NET=unit-net IT_SCRATCH="$TMP/scratch"
export IT_LABEL="ai-containers.it-run=unit" IT_DNS_IMAGE=unit-dns
mkdir -p "$IT_SCRATCH"
# shellcheck disable=SC1090
. "$LIB"

# ── allowlist_write ────────────────────────────────────────────────────────────
d="$(it_scratch)"
allowlist_write "$d" "a.example b.example" "10.1.2.3" ""
for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
  # ALL THREE always, even when empty: refresh-ipset-allowlist.sh exits 1 on a
  # missing CIDR file and set -e in entrypoint.sh turns that into a dead
  # container with an error that points nowhere near the real cause.
  [[ -f "$d/$f" ]] && t_pass "allowlist_write always creates $f" \
                   || t_fail "allowlist_write always creates $f"
done
t_check "domains file holds both entries" \
  "a.example|b.example|" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-domains.txt" | tr '\n' '|')"
t_check "cidrs file holds the IP" \
  "10.1.2.3|" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-cidrs.txt" | tr '\n' '|')"
t_check "an empty list yields a comments-only file (the legal degenerate config)" \
  "" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-proxy-domains.txt" | tr '\n' '|')"
[[ -s "$d/allowlist-proxy-domains.txt" ]] \
  && t_pass "a comments-only allowlist is still NON-EMPTY (why -s is the wrong check)" \
  || t_fail "a comments-only allowlist is still NON-EMPTY"

# ── it_wait polls a condition instead of sleeping a guess ──────────────────────
touch_later() { ( sleep 1; touch "$TMP/flag" ) & }
rm -f "$TMP/flag"; touch_later
it_wait 10 test -f "$TMP/flag" && t_pass "it_wait returns as soon as the condition holds" \
                                || t_fail "it_wait returns as soon as the condition holds"
it_wait 2 test -f "$TMP/never" && t_fail "it_wait times out on a condition that never holds" \
                               || t_pass "it_wait times out on a condition that never holds"

# ── The comment filter used by blocked_entries ────────────────────────────────
printf '# header one\n# header two\n\n10.9.9.9\n  \n#trailing\n' > "$TMP/blocked-ips.txt"
t_check "it_strip_comments keeps only real entries" \
  "10.9.9.9|" "$(it_strip_comments < "$TMP/blocked-ips.txt" | tr '\n' '|')"
t_check "it_strip_comments on a comments-only file yields nothing" \
  "" "$(printf '# only\n\n' | it_strip_comments | tr '\n' '|')"

# ── pass/fail accounting drives the case exit code ────────────────────────────
# The inner `fail "x"` deliberately calls the REAL lib.sh fail() (in scope
# since sourcing at the top of this file, never redefined again) to prove ITS
# accounting works — this is testing lib.sh, not this file's own t_fail.
( it_fails=0; fail "x" >/dev/null; [[ "$it_fails" -eq 1 ]] ) \
  && t_pass "fail increments it_fails" || t_fail "fail increments it_fails"

# ── The repo-dir resolver tolerates both layouts ──────────────────────────────
[[ -f "$IT_REPO_DIR/build.sh" ]] \
  && t_pass "IT_REPO_DIR resolves to the engine directory ($IT_REPO_DIR)" \
  || t_fail "IT_REPO_DIR resolves to the engine directory (got $IT_REPO_DIR)"

# ── IT_SETTLE is a FLOOR, not a plain default ──────────────────────────────────
# run.sh (Task 1) always exports its own default of 45 before a case process
# even starts, so a bare "${IT_SETTLE:-60}" fallback in lib.sh would never
# fire — IT_SETTLE already has a value by the time lib.sh is sourced. lib.sh
# must instead clamp a too-low value UP to 60 (see lib.sh's IT_SETTLE comment
# for the ~22s tshark-attach measurement this floor exists to cover). These two
# sub-shells re-source lib.sh with a controlled starting value, independent of
# whatever this test file's own top-level sourcing already did.
out="$(IT_SETTLE=10 bash -c ". '$LIB'; printf '%s' \"\$IT_SETTLE\"")"
t_check "IT_SETTLE is floored to 60 when the caller set it lower" "60" "$out"
out="$(IT_SETTLE=90 bash -c ". '$LIB'; printf '%s' \"\$IT_SETTLE\"")"
t_check "IT_SETTLE above the floor is left alone (a caller may ask for MORE)" "90" "$out"
out="$(bash -c ". '$LIB'; printf '%s' \"\$IT_SETTLE\"")"
t_check "IT_SETTLE defaults to 60 when unset entirely" "60" "$out"

# A raise is never silent: a user who set IT_SETTLE=30 to speed up a local run
# deserves to know their run is actually waiting 60s, not just get it silently
# doubled. Swap stdout/stderr so the command substitution captures ONLY stderr
# (the classic `2>&1 1>/dev/null` trick — fd2 is duplicated to fd1's CURRENT
# target, a pipe, before fd1 is reassigned to /dev/null).
notice="$(IT_SETTLE=10 bash -c ". '$LIB'" 2>&1 1>/dev/null)"
case "$notice" in
  *IT_SETTLE*10*60*) t_pass "raising IT_SETTLE below the floor prints a stderr notice" ;;
  *) t_fail "raising IT_SETTLE below the floor prints a stderr notice (got: '$notice')" ;;
esac
notice="$(IT_SETTLE=90 bash -c ". '$LIB'" 2>&1 1>/dev/null)"
[[ -z "$notice" ]] \
  && t_pass "no notice when IT_SETTLE is already at/above the floor" \
  || t_fail "no notice when IT_SETTLE is already at/above the floor (got: '$notice')"

# ── capture_ready / sandbox_wait_capture exist ─────────────────────────────────
# Both are docker-backed (docker exec against a real container) so their FULL
# behaviour is proven for real by a later task's case, exactly like
# sidecar_up/sandbox_up above them. Here we only prove lib.sh actually defines
# them — a typo'd name would otherwise surface only when a later task's case
# calls it.
declare -f capture_ready >/dev/null 2>&1 \
  && t_pass "capture_ready is defined" || t_fail "capture_ready is defined"
declare -f sandbox_wait_capture >/dev/null 2>&1 \
  && t_pass "sandbox_wait_capture is defined" || t_fail "sandbox_wait_capture is defined"

# ── capture_ready's REAL grep, exercised through a fake docker ─────────────────
# A bare `grep -q 'Capturing on' <string-we-wrote>` (the previous version of
# this test) proves the PATTERN is plausible; it would not catch a typo in
# capture_ready's own grep at lib.sh. A fake `docker` on PATH whose `exec` arm
# redirects the grep to a fixture file lets the test call the actual
# capture_ready() function — same fake-docker-on-PATH pattern already used by
# tests/test-integration-runner.sh.
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# capture_ready's only call shape: docker exec <cid> grep -q 'Capturing on' <path>
# <path> is meaningless here (there is no real container to read it from) —
# redirect that SAME grep to $FAKE_TSHARK_LOG so the test can flip between
# "attached" and "not yet attached" without touching lib.sh at all.
case "$1" in
  exec)
    shift 2   # drop "exec" and <cid>
    if [[ "$1 $2" == "grep -q" ]]; then
      shift 2
      grep -q "$1" "${FAKE_TSHARK_LOG:?FAKE_TSHARK_LOG not set}"
      exit $?
    fi
    printf 'fake docker: unexpected exec call: %s\n' "$*" >&2; exit 99 ;;
  *) printf 'fake docker: unexpected call: %s\n' "$*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"

printf 'Running as user "root" and group "root". This could be dangerous.\nCapturing on '"'"'nflog:100'"'"'\n' \
  > "$TMP/tshark-attached.log"
# The real PRE-attach state — tshark's setuid warning IS already present
# before it has attached — is the negative case that actually matters, not an
# empty file or an unrelated string.
printf 'Running as user "root" and group "root". This could be dangerous.\n' \
  > "$TMP/tshark-notyet.log"

FAKE_TSHARK_LOG="$TMP/tshark-attached.log" PATH="$FAKE_BIN:$PATH" \
  bash -c ". '$LIB'; capture_ready fake-cid" \
  && t_pass "capture_ready returns 0 once tshark's 'Capturing on' line is present" \
  || t_fail "capture_ready returns 0 once tshark's 'Capturing on' line is present"

FAKE_TSHARK_LOG="$TMP/tshark-notyet.log" PATH="$FAKE_BIN:$PATH" \
  bash -c ". '$LIB'; capture_ready fake-cid" \
  && t_fail "capture_ready returns non-zero before tshark has attached (setuid warning only)" \
  || t_pass "capture_ready returns non-zero before tshark has attached (setuid warning only)"

# ── The launcher verbs' pure parts ─────────────────────────────────────────────
for v in launcher_prepare launcher_run launcher_up agent_exec \
         assert_writable assert_not_writable assert_host_file_exists \
         assert_host_file_absent assert_launcher_refused; do
  declare -F "$v" >/dev/null && t_pass "lib.sh defines $v" || t_fail "lib.sh defines $v"
done

# agent_exec MUST run as the sandbox user. This is a FAIL-OPEN check: `docker
# exec` defaults to root, root writes through any ownership mistake, and every
# assert_writable in the mounts and groups tiers would then pass for the wrong
# reason — a :rw mount left owned by root would look perfectly healthy. Grep the
# mechanism (the -u flag carrying the launch identity), not the outcome.
if grep -qE 'docker exec -u "\$IT_LAUNCH_UID:\$IT_LAUNCH_GID"' "$LIB"; then
  t_pass "agent_exec runs as the sandbox user, not root"
else
  t_fail "agent_exec runs as the sandbox user, not root — writability assertions would fail open"
fi

# The launch identity must track what sandbox.sh actually passes (id -u/-g, or
# the SANDBOX_UID/GID override). A hardcoded 1000 waits forever for a pid-1
# handover that never comes on a CI runner whose user is 1001.
t_check "IT_LAUNCH_UID follows the invoking user" "$(id -u)" "$IT_LAUNCH_UID"
t_check "IT_LAUNCH_GID follows the invoking group" "$(id -g)" "$IT_LAUNCH_GID"

# launcher_prepare must REFUSE, not silently continue, when the real docker
# cannot be resolved — otherwise the shim it installs would exit 127 on every
# call and the case would report a mount failure.
out="$(IT_REAL_DOCKER="" bash -c ". '$LIB'; launcher_prepare" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'cannot resolve the real docker' <<< "$out"; then
  t_pass "launcher_prepare refuses when the real docker cannot be resolved"
else
  t_fail "launcher_prepare refuses when the real docker cannot be resolved (rc=$rc, out=$out)"
fi

# ── launcher_conf folds in the variant's overrides ─────────────────────────────
# launcher_up drives the REAL sandbox.sh, which re-reads sandbox.conf at LAUNCH
# time. If the launcher config and the image config disagree, the launcher does
# not mount what the image contains and the case fails on correct behaviour.
# That already happened once. The fix is that a case never states the variant's
# overrides, so it cannot forget them.
export IT_VARIANT_OVERRIDES='ruby=3.3.6,3.4.5 imagemagick=ON'
export IT_REAL_DOCKER="${IT_REAL_DOCKER:-/bin/true}"  # launcher_prepare checks this
launcher_prepare >/dev/null 2>&1
launcher_conf >/dev/null 2>&1
conf="$IT_LAUNCH_HOME/sandbox.conf"
grep -qx 'ruby=3.3.6,3.4.5' "$conf" \
  && t_pass "launcher_conf applies the variant's overrides with no case arguments" \
  || t_fail "launcher_conf applies the variant's overrides with no case arguments"
grep -qx 'imagemagick=ON' "$conf" \
  && t_pass "launcher_conf applies every variant override, not just the first" \
  || t_fail "launcher_conf applies every variant override, not just the first"

# A case's own argument must win over the variant's value for the same key,
# so a case can narrow the variant deliberately.
launcher_conf ruby=3.4.5 >/dev/null 2>&1
grep -qx 'ruby=3.4.5' "$conf" \
  && t_pass "a case argument overrides the variant's value for the same key" \
  || t_fail "a case argument overrides the variant's value for the same key"

# And with no variant set, behaviour is exactly as before.
unset IT_VARIANT_OVERRIDES
launcher_conf claude-code=ON >/dev/null 2>&1
grep -qx 'claude-code=ON' "$conf" \
  && t_pass "launcher_conf still works with no variant overrides set" \
  || t_fail "launcher_conf still works with no variant overrides set"
grep -qx 'ruby=' "$conf" \
  && t_pass "an unset variant leaves the version lists empty" \
  || t_fail "an unset variant leaves the version lists empty"


# ── forensics_report ────────────────────────────────────────────────────────────
# The reverse-mapped NAME can be wrong on a shared CDN address; the IP and port
# cannot. A report that prints only the name is unfalsifiable — that is what made
# repo1.maven.org unexplainable across two verification rounds and three PRs
# before the evidence (which dies with the container) was captured on purpose.
#
# The fixture below is built from log_blocked()'s OWN printf format strings
# (capture-blocked-traffic.sh), not a hand-typed guess at its output. That is
# deliberate: a fixture that encodes an assumption about the format rather than
# the writer's real output would make this test pass against a format nothing
# produces — which is the exact defect this task exists to guard against. If
# log_blocked()'s printf ever changes, this fixture changes with it and the
# mismatch becomes visible instead of silently drifting.
fx="$TMP/forensics"; mkdir -p "$fx"
{
  printf '# blocked destinations\n'
  # HARD-BLOCKED: same domain, two packets, one address.
  printf '%-25s  %-10s  %-42s  %s\n' \
    "2026-08-10T04:00:01" "tcp:443" "203.0.113.9" "repo1.maven.org"
  printf '%-25s  %-10s  %-42s  %s\n' \
    "2026-08-10T04:00:03" "tcp:443" "203.0.113.9" "repo1.maven.org"
  # SELF-HEALED: log_blocked()'s other printf arm, "(auto-allowed)" appended
  # after the domain — a fifth field, not a fourth.
  printf '%-25s  %-10s  %-42s  %s (auto-allowed)\n' \
    "2026-08-10T04:00:09" "tcp:443" "198.51.100.4" "api.anthropic.com"
} > "$fx/blocked.log"
printf 'repo1.maven.org\n' > "$fx/blocked-domains.txt"
printf '203.0.113.9 repo1.maven.org\n203.0.113.9 jruby.example\n' > "$fx/dns-map.txt"
printf 'api.anthropic.com\nregistry.npmjs.org\n' > "$fx/allowlist.txt"

out="$(forensics_report "$fx/blocked.log" "$fx/blocked-domains.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"

grep -q '203\.0\.113\.9' <<< "$out" \
  && t_pass "forensics prints the destination IP, which cannot be mis-attributed" \
  || t_fail "forensics prints the destination IP"
grep -qE 'x2' <<< "$out" \
  && t_pass "forensics prints the hit count" \
  || t_fail "forensics prints the hit count"
grep -qi 'allowlisted in this image: no' <<< "$out" \
  && t_pass "forensics states the allowlist verdict for the blocked name" \
  || t_fail "forensics states the allowlist verdict"
grep -q 'jruby.example' <<< "$out" \
  && t_pass "forensics lists EVERY name mapped to the address, so a CDN collision is visible" \
  || t_fail "forensics lists every name mapped to the address"
grep -q 'api.anthropic.com' <<< "$out" \
  && t_pass "forensics reports the self-healed entry separately from the hard block" \
  || t_fail "forensics reports the self-healed entry"

# The header comments in every output file are NOT entries. init_output_files
# seeds them, and counting them as destinations once reported a clean run as
# HARD-BLOCKED and listed the headers as the addresses.
printf '# blocked destinations\n#\n' > "$fx/empty-domains.txt"
out="$(forensics_report "$fx/blocked.log" "$fx/empty-domains.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"
grep -qi 'hard-blocked' <<< "$out" \
  && t_fail "a comments-only blocked-domains.txt must not report a hard block" \
  || t_pass "a comments-only blocked-domains.txt reports no hard block"
grep -q 'NOT allowlisted' <<< "$out" \
  && t_fail "the resolved-names split must not print when there was no hard block either" \
  || t_pass "the resolved-names split stays nested under a real hard block"

# ── resolved-names split by allowlist membership ───────────────────────────────
# Ported from verify-on-host.sh's Phase 3. The firewall's ipset refresher
# resolves EVERY allowlisted domain every 60 seconds and makes no TCP connection
# at all, so a raw "names this container resolved" list is mostly the allowlist
# re-resolving itself. Phase 3's own history: a 49-name list once looked like a
# container talking to 49 hosts when 47 of them were just that. The short list
# that actually matters — names resolved but never authorised — is what this
# split exists to surface, so it has to isolate that ONE name, not just mention
# it somewhere in a 3-name soup.
printf '10.0.0.1 allowed-one.example\n10.0.0.2 allowed-two.example\n10.0.0.3 not-allowed.example\n' \
  > "$fx/dns-map-mixed.txt"
printf 'allowed-one.example\nallowed-two.example\n' > "$fx/allowlist-mixed.txt"
out="$(forensics_report "$fx/blocked.log" "$fx/blocked-domains.txt" \
        "$fx/dns-map-mixed.txt" "$fx/allowlist-mixed.txt" 2>&1)"

grep -q '3 total, 1 NOT allowlisted' <<< "$out" \
  && t_pass "forensics counts resolved names and splits by allowlist membership precisely" \
  || t_fail "forensics counts resolved names and splits by allowlist membership precisely"
grep -q 'not-allowed.example' <<< "$out" \
  && t_pass "the unlisted name is named" \
  || t_fail "the unlisted name is named"
# Extract just the "resolved but NOT allowlisted" section (up to the next "all N
# (" line) and prove it holds ONLY the one unlisted name — not a pass that merely
# tolerates the allowlisted names leaking in from the full-list section below it.
unlisted_block="$(awk '/resolved but NOT allowlisted/{f=1;next} /all [0-9]+ \(the rest/{f=0} f' <<< "$out")"
if grep -q 'not-allowed.example' <<< "$unlisted_block" \
   && ! grep -qE 'allowed-one.example|allowed-two.example' <<< "$unlisted_block"; then
  t_pass "the unlisted section holds exactly the one unlisted name, not the allowlisted ones"
else
  t_fail "the unlisted section holds exactly the one unlisted name (got: '$unlisted_block')"
fi
grep -q 'allowed-one.example' <<< "$out" \
  && t_pass "the full resolved-name list is still printed underneath the split" \
  || t_fail "the full resolved-name list is still printed underneath the split"

# ── "dropped nothing" vs UNKNOWN vs a real report — three DISTINCT states ──────
# forensics_report tells these apart purely by whether $blog (blocked.log) is
# present on disk. That is only trustworthy if the CALLER (dump_blocked_forensics)
# preserves real absence rather than fabricating an empty stand-in on a failed
# read — this repo's capture daemon died silently for months once, and during
# that outage "the firewall dropped nothing" read as evidence when the honest
# answer was "we don't know". These three assertions pin the file-presence
# contract forensics_report is built on, so a regression here (e.g. dump_blocked_
# forensics going back to `: > "$d/$f"` on a failed read) is caught even though
# dump_blocked_forensics itself needs a live container to exercise directly.
#
# State 1: $blog is MISSING — the honest "we do not know" branch.
out="$(forensics_report "$fx/no-such-blocked.log" "$fx/empty-domains.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"
grep -q 'UNKNOWN — the capture never ran' <<< "$out" \
  && t_pass "a MISSING blocked.log reports UNKNOWN, not a clean run" \
  || t_fail "a MISSING blocked.log reports UNKNOWN, not a clean run (got: $out)"
grep -q 'dropped nothing' <<< "$out" \
  && t_fail "a MISSING blocked.log must never claim a clean run" \
  || t_pass "a MISSING blocked.log does not claim a clean run"

# State 2: $blog is PRESENT but holds no real entries (header comments only) —
# the capture genuinely ran and genuinely saw nothing.
printf '# blocked destinations\n#\n' > "$fx/present-empty.log"
out="$(forensics_report "$fx/present-empty.log" "$fx/empty-domains.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"
grep -q 'firewall dropped nothing' <<< "$out" \
  && t_pass "a PRESENT-but-empty blocked.log reports a clean run" \
  || t_fail "a PRESENT-but-empty blocked.log reports a clean run (got: $out)"
grep -q 'UNKNOWN' <<< "$out" \
  && t_fail "a PRESENT-but-empty blocked.log must never claim UNKNOWN" \
  || t_pass "a PRESENT-but-empty blocked.log does not claim UNKNOWN"

# State 3: $blog is PRESENT WITH entries — the real report, and it must not ALSO
# hedge with either of the other two claims.
out="$(forensics_report "$fx/blocked.log" "$fx/blocked-domains.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"
case "$out" in
  *'firewall dropped nothing'*|*'UNKNOWN'*)
    t_fail "a PRESENT-with-entries report must not also hedge as clean-run or UNKNOWN" ;;
  *)
    t_pass "a PRESENT-with-entries report does not hedge as clean-run or UNKNOWN" ;;
esac

declare -f dump_blocked_forensics >/dev/null 2>&1 \
  && t_pass "dump_blocked_forensics is defined" || t_fail "dump_blocked_forensics is defined"
# dump_blocked_forensics itself needs a live container (a `docker inspect`
# liveness probe, `docker exec` reads of a root-only tmpfs and an image file,
# and the image-grep's own `docker exec … grep` against the live filesystem)
# and is not unit-testable here — see lib.sh's comment on it. Its own body is
# deliberately thin (docker-exec plumbing feeding forensics_report, plus one
# bounded, N-capped docker-exec grep loop), so proving forensics_report's
# three file-presence states above — MISSING / present-but-empty /
# present-with-entries — proves the contract dump_blocked_forensics must not
# violate (no fabricated files on a failed read, no masking a dead container
# as "the capture never ran"), even though the wrapper's own plumbing can only
# be verified by inspection.

# ── Ruby-case helpers ───────────────────────────────────────────────────────────
# ruby_wait_ready and assert_runs both take a live container id and are not
# unit-testable here — same reason capture_ready/sandbox_wait_capture above are
# only proven to be DEFINED, not exercised: there is no docker daemon in this
# environment. What the brief deliberately factored OUT into pure predicates —
# _ruby_reconcile_done / _ruby_reconcile_ok, decided from captured log text on
# stdin — IS hermetically testable, and that split is the point: it is what
# lets ruby_wait_ready's decision logic be proven correct without a container.
t_check "IT_RUBY_GROUP is a stable name shared across cases in one run" \
  "itruby" "$IT_RUBY_GROUP"

# A failed rvm bootstrap exits in SECONDS; polling only for `ruby` on PATH once
# burned a full 30-minute timeout on a compile that never started. That is why
# the reconcile's own terminal log lines are part of the condition.
_ruby_reconcile_done <<< '[rvm-reconcile] done.' \
  && t_pass "ruby readiness recognises a completed reconcile" \
  || t_fail "ruby readiness recognises a completed reconcile"
_ruby_reconcile_done <<< '[rvm-reconcile] FAILED: ruby-3.4.5' \
  && t_pass "ruby readiness recognises a FAILED reconcile (does not wait out the timeout)" \
  || t_fail "ruby readiness recognises a FAILED reconcile"
_ruby_reconcile_done <<< '[rvm-reconcile] installing ruby-3.4.5…' \
  && t_fail "an in-progress reconcile must not be reported ready" \
  || t_pass "an in-progress reconcile is not reported ready"

# `done.` and `FAILED:` both END the wait but are opposite OUTCOMES — that is
# why termination and success are two separate predicates, not one.
_ruby_reconcile_ok <<< '[rvm-reconcile] done.' \
  && t_pass "a completed reconcile is distinguished from a failed one" \
  || t_fail "a completed reconcile is distinguished from a failed one"
_ruby_reconcile_ok <<< '[rvm-reconcile] FAILED: ruby-3.4.5' \
  && t_fail "FAILED must not be reported as success" \
  || t_pass "FAILED is not reported as success"

declare -f ruby_wait_ready >/dev/null 2>&1 \
  && t_pass "ruby_wait_ready is defined" || t_fail "ruby_wait_ready is defined"
declare -f assert_runs >/dev/null 2>&1 \
  && t_pass "assert_runs is defined" || t_fail "assert_runs is defined"

# assert_runs must capture the command's output BEFORE piping it through head.
# `if out="$(cmd | head -1)"` reports HEAD's exit status, and head succeeds on
# the empty output of a binary that just died — the exact mistake that made the
# equivalent check in verify-on-host.sh unreachable for its whole existence.
# Grep the mechanism, not the outcome: an out="$(... 2>&1)" assignment as the
# if-condition, not a pipeline ending in head.
if grep -qE 'if out="\$\(docker exec "\$1" bash -c "\$2 --version 2>&1"\)"' "$LIB"; then
  t_pass "assert_runs captures output before piping through head, not after"
else
  t_fail "assert_runs captures output before piping through head — the head-exit-status bug would be unreachable"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
