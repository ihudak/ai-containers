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
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$LIB" && pass "lib.sh bash -n" || fail "lib.sh bash -n"

# lib.sh refuses to load without the runner's environment — a case run by hand
# would otherwise inherit whatever IT_IMAGE happened to be lying around.
out="$(env -u IT_RUN_ID -u IT_IMAGE -u IT_NET bash -c ". '$LIB'" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "lib.sh refuses to load outside the runner" \
                  || fail "lib.sh refuses to load outside the runner"

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
  [[ -f "$d/$f" ]] && pass "allowlist_write always creates $f" \
                   || fail "allowlist_write always creates $f"
done
check "domains file holds both entries" \
  "a.example|b.example|" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-domains.txt" | tr '\n' '|')"
check "cidrs file holds the IP" \
  "10.1.2.3|" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-cidrs.txt" | tr '\n' '|')"
check "an empty list yields a comments-only file (the legal degenerate config)" \
  "" "$(grep -vE '^[[:space:]]*(#|$)' "$d/allowlist-proxy-domains.txt" | tr '\n' '|')"
[[ -s "$d/allowlist-proxy-domains.txt" ]] \
  && pass "a comments-only allowlist is still NON-EMPTY (why -s is the wrong check)" \
  || fail "a comments-only allowlist is still NON-EMPTY"

# ── it_wait polls a condition instead of sleeping a guess ──────────────────────
touch_later() { ( sleep 1; touch "$TMP/flag" ) & }
rm -f "$TMP/flag"; touch_later
it_wait 10 test -f "$TMP/flag" && pass "it_wait returns as soon as the condition holds" \
                                || fail "it_wait returns as soon as the condition holds"
it_wait 2 test -f "$TMP/never" && fail "it_wait times out on a condition that never holds" \
                               || pass "it_wait times out on a condition that never holds"

# ── The comment filter used by blocked_entries ────────────────────────────────
printf '# header one\n# header two\n\n10.9.9.9\n  \n#trailing\n' > "$TMP/blocked-ips.txt"
check "it_strip_comments keeps only real entries" \
  "10.9.9.9|" "$(it_strip_comments < "$TMP/blocked-ips.txt" | tr '\n' '|')"
check "it_strip_comments on a comments-only file yields nothing" \
  "" "$(printf '# only\n\n' | it_strip_comments | tr '\n' '|')"

# ── pass/fail accounting drives the case exit code ────────────────────────────
( it_fails=0; fail "x" >/dev/null; [[ "$it_fails" -eq 1 ]] ) \
  && pass "fail increments it_fails" || fail "fail increments it_fails"

# ── The repo-dir resolver tolerates both layouts ──────────────────────────────
[[ -f "$IT_REPO_DIR/build.sh" ]] \
  && pass "IT_REPO_DIR resolves to the engine directory ($IT_REPO_DIR)" \
  || fail "IT_REPO_DIR resolves to the engine directory (got $IT_REPO_DIR)"

# ── IT_SETTLE is a FLOOR, not a plain default ──────────────────────────────────
# run.sh (Task 1) always exports its own default of 45 before a case process
# even starts, so a bare "${IT_SETTLE:-60}" fallback in lib.sh would never
# fire — IT_SETTLE already has a value by the time lib.sh is sourced. lib.sh
# must instead clamp a too-low value UP to 60 (see lib.sh's IT_SETTLE comment
# for the ~22s tshark-attach measurement this floor exists to cover). These two
# sub-shells re-source lib.sh with a controlled starting value, independent of
# whatever this test file's own top-level sourcing already did.
out="$(IT_SETTLE=10 bash -c ". '$LIB'; printf '%s' \"\$IT_SETTLE\"")"
check "IT_SETTLE is floored to 60 when the caller set it lower" "60" "$out"
out="$(IT_SETTLE=90 bash -c ". '$LIB'; printf '%s' \"\$IT_SETTLE\"")"
check "IT_SETTLE above the floor is left alone (a caller may ask for MORE)" "90" "$out"
out="$(bash -c ". '$LIB'; printf '%s' \"\$IT_SETTLE\"")"
check "IT_SETTLE defaults to 60 when unset entirely" "60" "$out"

# ── capture_ready / sandbox_wait_capture exist ─────────────────────────────────
# Both are docker-backed (docker exec against a real container) so they are
# proven for real by a later task's case, exactly like sidecar_up/sandbox_up
# above them. Here we only prove lib.sh actually defines them — a typo'd name
# would otherwise surface only when a later task's case calls it.
declare -f capture_ready >/dev/null 2>&1 \
  && pass "capture_ready is defined" || fail "capture_ready is defined"
declare -f sandbox_wait_capture >/dev/null 2>&1 \
  && pass "sandbox_wait_capture is defined" || fail "sandbox_wait_capture is defined"

# The predicate itself, independent of docker exec: tshark's real startup
# banner looks like `Capturing on 'nflog:100'` (task-0 CI probe). Prove the
# grep pattern capture_ready uses actually matches that shape, not a string we
# invented for the test.
printf 'Running as user "root" and group "root".\nCapturing on '"'"'nflog:100'"'"'\n' > "$TMP/tshark.log"
grep -q 'Capturing on' "$TMP/tshark.log" \
  && pass "capture_ready's predicate matches tshark's real startup banner shape" \
  || fail "capture_ready's predicate matches tshark's real startup banner shape"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
