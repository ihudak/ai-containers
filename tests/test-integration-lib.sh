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

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A fabricated stand-in for a "resolvable, executable docker binary" — the
# assertions below only need a PATH that IS an executable file; they never run
# it. `/bin/true` is not that path on every platform (macOS ships `true` at
# `/usr/bin/true`; there is no `/bin/true`), so hardcoding it hardcodes a
# Linux filesystem layout instead of the actual requirement. `command -v true`
# is NOT a substitute — `true` is a shell builtin, so that returns the string
# "true", not a path. Fabricating our own executable is portable by
# construction and states the intent precisely.
TRUE_STUB="$TMP/true-stub"
printf '#!/bin/sh\nexit 0\n' > "$TRUE_STUB"
chmod +x "$TRUE_STUB"

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

# ── it_wait's bound is wall-clock seconds, not a poll count (F6) ──────────────
# The two assertions above only ever poll a predicate that costs nothing, and
# for a free predicate iterations and seconds coincide — which is exactly why a
# body that counted iterations sat here looking correct. This predicate costs 2s
# per evaluation, so the two readings of `it_wait 6` separate: 6 wall-clock
# seconds plus at most one in-flight predicate (~8s, 3 polls) against 6 polls of
# 2s+1s (~18s, 6 polls). Both are asserted — the elapsed time is the defect, the
# poll count is its mechanism — and the 12s threshold sits between the readings
# with 50% margin over the correct one.
t_polls=0
t_slow_false() { t_polls=$((t_polls + 1)); sleep 2; return 1; }
t_start=$EPOCHSECONDS
it_wait 6 t_slow_false && t_fail "it_wait reports failure on a never-true slow predicate" \
                       || t_pass "it_wait reports failure on a never-true slow predicate"
t_elapsed=$(( EPOCHSECONDS - t_start ))
if (( t_elapsed <= 12 )); then
  t_pass "it_wait 6 is bounded by ~6 wall-clock seconds, not 6 polls (took ${t_elapsed}s)"
else
  t_fail "it_wait 6 is bounded by ~6 wall-clock seconds, not 6 polls — took ${t_elapsed}s, the poll-count reading of 6 x (2s predicate + 1s sleep)"
fi
if (( t_polls < 6 )); then
  t_pass "the deadline cuts polling short of the iteration count ($t_polls polls, not 6)"
else
  t_fail "the deadline cuts polling short of the iteration count — got $t_polls polls, exactly the iteration-counting body's count"
fi

# A deadline that has already passed still evaluates the predicate once: a wait
# that reported failure without ever looking would be worse than a slow one.
t_polls=0
t_never() { t_polls=$((t_polls + 1)); return 1; }
it_wait 0 t_never
if (( t_polls == 1 )); then
  t_pass "it_wait 0 still evaluates the predicate exactly once"
else
  t_fail "it_wait 0 still evaluates the predicate exactly once — got $t_polls evaluation(s)"
fi
it_wait 0 true && t_pass "it_wait 0 succeeds when the condition already holds" \
               || t_fail "it_wait 0 succeeds when the condition already holds"

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
for v in launcher_prepare launcher_run launcher_up agent_exec agent_exec_login \
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

# agent_exec_login (task 14a / Finding 1): same identity, but a LOGIN shell.
# Grep the mechanism, not the outcome — same discipline as agent_exec above.
# Without `-l` here, a case that needs rvm's scripts/cd hook (registered only
# by a login shell sourcing /etc/profile.d/rvm.sh) would silently see no rvm
# function at all, exactly the case-750 bug this helper exists to prevent from
# being reintroduced by a future non-login `docker exec ... bash -c`.
if grep -qE 'docker exec -u "\$IT_LAUNCH_UID:\$IT_LAUNCH_GID" "\$1" bash -lc "\$2"' \
   < <(awk '/^agent_exec_login\(\)/,/^}/' "$LIB"); then
  t_pass "agent_exec_login runs as the sandbox user, in a LOGIN shell"
else
  t_fail "agent_exec_login runs as the sandbox user, in a LOGIN shell — rvm-dependent checks would silently see no rvm"
fi

# The launch identity must track what sandbox.sh actually passes (id -u/-g, or
# the SANDBOX_UID/GID override). A hardcoded 1000 waits forever for a pid-1
# handover that never comes on a CI runner whose user is 1001.
t_check "IT_LAUNCH_UID follows the invoking user" "$(id -u)" "$IT_LAUNCH_UID"
t_check "IT_LAUNCH_GID follows the invoking group" "$(id -g)" "$IT_LAUNCH_GID"

# launcher_prepare must REFUSE, not silently continue, when the real docker
# cannot be resolved — otherwise the shim it installs would exit 127 on every
# call and the case would report a mount failure.
#
# Both halves of lib.sh's guard (`-z` OR `! -x`) are driven, and both set the
# variable AFTER sourcing. This is the whole point, not a style choice. The
# original form was:
#
#     out="$(IT_REAL_DOCKER="" bash -c ". '$LIB'; launcher_prepare" 2>&1)"
#
# and it could not express the condition it named. A command-prefix assignment
# puts IT_REAL_DOCKER="" in the child's environment, lib.sh then resolves
# `IT_REAL_DOCKER="${IT_REAL_DOCKER:-$(command -v docker)}"`, and `:-` treats
# EMPTY exactly like unset — so on any machine that has docker the fallback
# succeeds, launcher_prepare correctly proceeds, and the assertion fails. It
# passed only where docker is absent, which is every developer sandbox and no
# CI runner. It had been failing on every CI run since 3bf3aae and reporting
# nothing, because it called lib.sh's fail() (tallying into $it_fails, which
# this file's `exit "$fails"` never reads) and run-all.sh had no ^FAIL: guard
# yet. Both of those are fixed on this branch, which is what made it visible.
#
# Assigning after the source bypasses the fallback and reaches the guard
# directly, on any host, with or without docker installed.
out="$(bash -c ". '$LIB'; IT_REAL_DOCKER=''; launcher_prepare" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'cannot resolve the real docker' <<< "$out"; then
  t_pass "launcher_prepare refuses when the real docker resolves to nothing"
else
  t_fail "launcher_prepare refuses when the real docker resolves to nothing (rc=$rc, out=$out)"
fi
# The other half: a path that is set but not executable — a stale IT_REAL_DOCKER
# pointing at a removed or non-executable binary, which `-z` alone would admit.
out="$(bash -c ". '$LIB'; IT_REAL_DOCKER=/nonexistent/docker; launcher_prepare" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'cannot resolve the real docker' <<< "$out"; then
  t_pass "launcher_prepare refuses a set-but-not-executable IT_REAL_DOCKER"
else
  t_fail "launcher_prepare refuses a set-but-not-executable IT_REAL_DOCKER (rc=$rc, out=$out)"
fi
# And the negative: a resolvable docker must NOT be refused, so the two above
# are not passing merely because launcher_prepare refuses everything.
out="$(bash -c ". '$LIB'; IT_REAL_DOCKER='$TRUE_STUB'; launcher_prepare" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q 'cannot resolve the real docker' <<< "$out"; then
  t_pass "launcher_prepare accepts an executable IT_REAL_DOCKER"
else
  t_fail "launcher_prepare accepts an executable IT_REAL_DOCKER (rc=$rc, out=$out)"
fi

# ── launcher_conf folds in the variant's overrides ─────────────────────────────
# launcher_up drives the REAL sandbox.sh, which re-reads sandbox.conf at LAUNCH
# time. If the launcher config and the image config disagree, the launcher does
# not mount what the image contains and the case fails on correct behaviour.
# That already happened once. The fix is that a case never states the variant's
# overrides, so it cannot forget them.
export IT_VARIANT_OVERRIDES='ruby=3.3.6,3.4.5 imagemagick=ON'
# Scoped to THIS block (restored at its end), and NOT exported.
#
# Not exported because nothing needs it exported: launcher_prepare reads it as
# a plain shell variable, and launcher_run/launcher_script export it themselves
# inside their own subshells. `export` here instead pushed a value THIS block
# picked for its own convenience into every later child in the file —
# including ar_run's `bash -c ". $LIB"`, where lib.sh's own
# `IT_REAL_DOCKER="${IT_REAL_DOCKER:-$(command -v docker)}"` resolution would
# then never run. Nothing downstream reads the value today, which is exactly
# why the leak was invisible rather than harmless: the next assertion about
# that resolution would have inherited an answer chosen three hundred lines
# earlier for an unrelated reason, and on a host WITH docker it would have
# inherited a different one than on a host without.
#
# Restored, not unset: lib.sh assigned it at source time and `set -u` is in
# force, so unsetting would break the next reader instead of the leak. The
# refusal assertions just above are unaffected either way — they run in child
# shells that assign AFTER sourcing, which is the whole point of the long
# comment above them; do not "simplify" them to a command-prefix assignment on
# the strength of this variable now being local.
IT_REAL_DOCKER_OUTER="${IT_REAL_DOCKER:-}"
IT_REAL_DOCKER="${IT_REAL_DOCKER:-$TRUE_STUB}"  # launcher_prepare checks this
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
# End of the launcher_conf block — hand IT_REAL_DOCKER back to whatever lib.sh
# resolved at source time (see the comment where it is overridden above).
IT_REAL_DOCKER="$IT_REAL_DOCKER_OUTER"; unset IT_REAL_DOCKER_OUTER

# ── DOCKER_HOST reaches a HOME-redirected launcher subshell (task-14b) ─────────
# launcher_run/launcher_script redirect HOME to per-case scratch to isolate
# group state — but the docker CLI resolves which daemon to talk to from
# $HOME/.docker/config.json's currentContext, which the redirect throws away.
# On a plain unix:///var/run/docker.sock host (Linux CI) that is invisible; on
# macOS + Colima, which supplies its endpoint ONLY through the active context,
# every docker call made from inside the redirected subshell loses the
# daemon. See lib.sh's IT_DOCKER_HOST comment for the full story.
#
# These assertions drive the REAL launcher_run/launcher_script — HOME
# redirection, PATH shim setup, launcher_conf/minimal-conf.sh, docker-shim.sh
# — all genuine, unmodified production code. Only the process each ultimately
# execs (sandbox.sh / group.sh) is faked, and only to answer one question: did
# DOCKER_HOST arrive in ITS environment. There is no other way to observe that
# without actually starting a container.
#
# A single directory symlink, not per-file: bash's `cd`/`pwd` resolve ".."
# LEXICALLY against the given path (proven empirically — a physical resolve
# would instead land back in the real repo), so IT_LIB_DIR/../.. below still
# computes to $DH_FAKE_REPO even though tests/integration is itself a symlink
# to the real one. That is what lets docker-shim.sh and minimal-conf.sh run
# unmodified while only the repo-root scripts are replaced.
DH_FAKE_REPO="$TMP/dh-fakerepo"
mkdir -p "$DH_FAKE_REPO/tests"
ln -sf "$IT_LIB_DIR" "$DH_FAKE_REPO/tests/integration"
: > "$DH_FAKE_REPO/build.sh"        # satisfies launcher_prepare's IT_REPO_DIR check
: > "$DH_FAKE_REPO/sandbox.conf"    # minimal-conf.sh only requires the file to exist
cat > "$DH_FAKE_REPO/sandbox.sh" <<'DHEOF'
#!/usr/bin/env bash
# Stands in for the real sandbox.sh for exactly one purpose: reveal whether
# DOCKER_HOST reached this process, and how (unset vs a real value vs empty).
printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST-<unset>}"
DHEOF
chmod +x "$DH_FAKE_REPO/sandbox.sh"
cat > "$DH_FAKE_REPO/group.sh" <<'DHEOF'
#!/usr/bin/env bash
printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST-<unset>}"
DHEOF
chmod +x "$DH_FAKE_REPO/group.sh"

# A stub `docker` answering ONLY `context inspect` — the one subcommand
# IT_DOCKER_HOST resolution calls — same fake-docker-on-PATH idiom as
# capture_ready's FAKE_BIN above.
DH_BIN_OK="$TMP/dh-bin-ok"; mkdir -p "$DH_BIN_OK"
cat > "$DH_BIN_OK/docker" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1 $2" == "context inspect" ]]; then
  printf 'tcp://127.0.0.1:9999\n'
  exit 0
fi
printf 'dh-bin-ok fake docker: unexpected call: %s\n' "$*" >&2
exit 99
FAKE
chmod +x "$DH_BIN_OK/docker"

# A stub `docker` whose `context inspect` genuinely fails — no context
# configured, or a docker too old to have the subcommand at all.
DH_BIN_FAIL="$TMP/dh-bin-fail"; mkdir -p "$DH_BIN_FAIL"
cat > "$DH_BIN_FAIL/docker" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1 $2" == "context inspect" ]]; then
  exit 1
fi
printf 'dh-bin-fail fake docker: unexpected call: %s\n' "$*" >&2
exit 99
FAKE
chmod +x "$DH_BIN_FAIL/docker"

# A stub `docker` that must NEVER be called at all — used to prove an
# already-set IT_DOCKER_HOST (what run.sh exports for every case) short-
# circuits the whole resolution block, subprocess and all.
DH_BIN_POISON="$TMP/dh-bin-poison"; mkdir -p "$DH_BIN_POISON"
cat > "$DH_BIN_POISON/docker" <<'FAKE'
#!/usr/bin/env bash
printf 'dh-bin-poison: docker was called but should not have been: %s\n' "$*" >&2
exit 98
FAKE
chmod +x "$DH_BIN_POISON/docker"

# The bash -c body both helpers run — identical either way, only how
# IT_DOCKER_HOST arrives in THEIR OWN environment differs between them.
DH_LAUNCHER_BODY='
  . "$DH_LIB"
  if [[ "$DH_VERB" == "sandbox" ]]; then
    launcher_run open >/dev/null 2>&1
    cat "$IT_LAUNCH_OUT"
  else
    launcher_script group.sh rm somegroup --yes >/dev/null 2>&1
    cat "$IT_SCRIPT_OUT"
  fi
'

# $1=docker-stub-dir $2=sandbox|group — IT_DOCKER_HOST starts UNSET, exactly
# like a case run standalone outside run.sh; resolution must run for real.
dh_run_launcher() {
  env -u IT_DOCKER_HOST -u DOCKER_HOST \
    PATH="$1:$PATH" \
    IT_RUN_ID="unit-dh-$RANDOM" IT_IMAGE=unit-img IT_NET=unit-net \
    IT_SCRATCH="$TMP/scratch-dh-$RANDOM" \
    IT_LABEL="ai-containers.it-run=unit-dh" \
    IT_REAL_DOCKER="$TRUE_STUB" \
    DH_LIB="$DH_FAKE_REPO/tests/integration/lib.sh" \
    DH_VERB="$2" \
    bash -c "$DH_LAUNCHER_BODY"
}

# $1=docker-stub-dir $2=sandbox|group $3=value to PRE-EXPORT as IT_DOCKER_HOST
# — may be empty. `env VAR="$3" cmd` exports VAR="" as a genuinely SET (not
# absent) variable even when $3 is the empty string, which is the one thing
# dh_run_launcher's optional-arg approach cannot express (a bash `${3:+…}`
# guard treats empty and unset identically) — exactly the distinction
# `${IT_DOCKER_HOST+x}` in lib.sh exists to make, so the test needs the same
# precision the code under test does.
dh_run_launcher_preset() {
  env -u DOCKER_HOST \
    PATH="$1:$PATH" \
    IT_RUN_ID="unit-dh-$RANDOM" IT_IMAGE=unit-img IT_NET=unit-net \
    IT_SCRATCH="$TMP/scratch-dh-$RANDOM" \
    IT_LABEL="ai-containers.it-run=unit-dh" \
    IT_REAL_DOCKER="$TRUE_STUB" \
    DH_LIB="$DH_FAKE_REPO/tests/integration/lib.sh" \
    DH_VERB="$2" \
    IT_DOCKER_HOST="$3" \
    bash -c "$DH_LAUNCHER_BODY"
}

out="$(dh_run_launcher "$DH_BIN_OK" sandbox)"
case "$out" in
  *'DOCKER_HOST=tcp://127.0.0.1:9999'*)
    t_pass "launcher_run's subshell receives a DOCKER_HOST matching the outer resolution" ;;
  *)
    t_fail "launcher_run's subshell receives a DOCKER_HOST matching the outer resolution (got: '$out')" ;;
esac

out="$(dh_run_launcher "$DH_BIN_FAIL" sandbox)"
case "$out" in
  *'DOCKER_HOST=<unset>'*)
    t_pass "an unresolvable docker context leaves DOCKER_HOST UNEXPORTED, not empty" ;;
  *)
    t_fail "an unresolvable docker context leaves DOCKER_HOST unexported, not empty (got: '$out')" ;;
esac

out="$(dh_run_launcher "$DH_BIN_OK" group)"
case "$out" in
  *'DOCKER_HOST=tcp://127.0.0.1:9999'*)
    t_pass "launcher_script's subshell (group.sh/repo.sh) also receives the resolved DOCKER_HOST" ;;
  *)
    t_fail "launcher_script's subshell also receives the resolved DOCKER_HOST (got: '$out')" ;;
esac

# An ALREADY-EXPORTED IT_DOCKER_HOST (what run.sh hands down to every case)
# must win outright — no docker subprocess at all, not even one that would
# have succeeded. DH_BIN_POISON fails loudly (exit 98, stderr message) if
# resolution is attempted despite this, which would otherwise be invisible:
# a re-resolution landing on the SAME value looks identical to short-
# circuiting from the subshell's stdout alone.
out="$(dh_run_launcher_preset "$DH_BIN_POISON" sandbox "tcp://pre-resolved:2375" 2>"$TMP/dh-poison.err")"
case "$out" in
  *'DOCKER_HOST=tcp://pre-resolved:2375'*)
    t_pass "an already-exported IT_DOCKER_HOST is used as-is" ;;
  *)
    t_fail "an already-exported IT_DOCKER_HOST is used as-is (got: '$out')" ;;
esac
if [[ -s "$TMP/dh-poison.err" ]]; then
  t_fail "an already-exported IT_DOCKER_HOST must not trigger a docker subprocess (stderr: $(cat "$TMP/dh-poison.err"))"
else
  t_pass "an already-exported IT_DOCKER_HOST skips the docker subprocess entirely"
fi

# An already-exported EMPTY IT_DOCKER_HOST (run.sh's own resolution genuinely
# found nothing) is the same "already decided" case — must ALSO skip
# resolution, and must ALSO leave DOCKER_HOST unexported down in sandbox.sh.
out="$(dh_run_launcher_preset "$DH_BIN_POISON" sandbox "" 2>"$TMP/dh-poison2.err")"
case "$out" in
  *'DOCKER_HOST=<unset>'*)
    t_pass "an already-exported EMPTY IT_DOCKER_HOST is honoured, not re-resolved" ;;
  *)
    t_fail "an already-exported EMPTY IT_DOCKER_HOST is honoured, not re-resolved (got: '$out')" ;;
esac
[[ -s "$TMP/dh-poison2.err" ]] \
  && t_fail "an already-exported empty IT_DOCKER_HOST must not trigger a docker subprocess (stderr: $(cat "$TMP/dh-poison2.err"))" \
  || t_pass "an already-exported empty IT_DOCKER_HOST skips the docker subprocess entirely"


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

# ── an entry with NO line in blocked.log says so, rather than vanishing ────────
# The awk END block's `n == 0` arm. blocked-domains.txt and blocked.log are two
# separate files written by two separate code paths in capture-blocked-traffic.sh,
# so they can legitimately disagree: a name deduplicated into blocked-domains.txt
# whose blocked.log line is missing (truncated read, a rotation, a field layout
# that stopped matching $3/$4). Without this arm the per-entry loop prints the
# heading, prints NOTHING for that entry, and then prints its allowlist verdict —
# a report that silently drops the one entry it was asked about while looking
# complete. That is the same "a check that cannot report what it claims" defect
# this increment exists to close, so it gets a test rather than an argument.
#
# $blog is PRESENT here, deliberately: an absent blocked.log is the separate
# UNKNOWN branch tested further down, and awk handed an unopenable file skips
# END entirely — which is exactly why lib.sh pipes it through `cat`.
printf 'repo1.maven.org\nghost.example\n' > "$fx/domains-with-ghost.txt"
out="$(forensics_report "$fx/blocked.log" "$fx/domains-with-ghost.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"
grep -q 'ghost.example .*no matching line in blocked.log' <<< "$out" \
  && t_pass "an entry with no line in blocked.log is named and stated as unmatched" \
  || t_fail "an entry with no line in blocked.log is named and stated as unmatched (got: $out)"
# The fallback must be per-entry, not a whole-report bail-out: the entry that DOES
# have lines is still aggregated with its count.
grep -qE '203\.0\.113\.9.*x2' <<< "$out" \
  && t_pass "the matched entry is still aggregated alongside the unmatched one" \
  || t_fail "the matched entry is still aggregated alongside the unmatched one"
# And the unmatched entry still gets its allowlist verdict — proof the loop
# continued past the fallback instead of `exit`-ing the enclosing awk for good.
[[ "$(grep -c 'allowlisted in this image' <<<"$out")" == "2" ]] \
  && t_pass "both entries get an allowlist verdict, so the loop did not stop at the unmatched one" \
  || t_fail "both entries get an allowlist verdict (got: $out)"

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

# ── _it_is_bare_ip: BOTH address families, or the report loses a real name ─────
# The image-grep loop in dump_blocked_forensics skips bare IP literals — no
# program carries a raw address the way it carries a hostname, and the entry is
# in blocked-ips.txt precisely because nothing resolved a name for it. The
# predicate it inherited from verify-on-host.sh's Phase 3 was `^[0-9.]+$`, IPv4
# only, so an IPv6 literal was treated as a name: it burned one of the ten
# capped grep slots and a bounded 90s `docker exec grep -r`, evicting a REAL
# hostname from a report whose cap exists to keep it readable. This repo can
# genuinely produce one — the WSL2/nf_tables caveat leaves IPv6 egress
# unenforced on some hosts and the capture logs whatever it saw dropped.
_it_is_bare_ip '203.0.113.9' \
  && t_pass "a bare IPv4 literal is recognised as an address, not a name" \
  || t_fail "a bare IPv4 literal is recognised as an address, not a name"
_it_is_bare_ip '2606:4700::1111' \
  && t_pass "a bare IPv6 literal is recognised as an address, not a name" \
  || t_fail "a bare IPv6 literal is recognised as an address, not a name"
_it_is_bare_ip '::1' \
  && t_pass "the compressed IPv6 loopback is recognised as an address" \
  || t_fail "the compressed IPv6 loopback is recognised as an address"
_it_is_bare_ip '::ffff:203.0.113.9' \
  && t_pass "an IPv4-mapped IPv6 literal (digits, dots AND colons) is recognised as an address" \
  || t_fail "an IPv4-mapped IPv6 literal is recognised as an address"
# The complement: the predicate must not swallow NAMES, or the image grep — the
# one step that says which file in the image asked for a host — never runs at
# all. A hostname cannot contain a colon, so the colon arm has to reject one
# that somehow does rather than assume anything with a colon is an address.
_it_is_bare_ip 'repo1.maven.org' \
  && t_fail "a hostname must not be mistaken for a bare address" \
  || t_pass "a hostname is not mistaken for a bare address"
_it_is_bare_ip 'ipv6.test-hosts.example' \
  && t_fail "a hostname with digits must not be mistaken for a bare address" \
  || t_pass "a hostname with digits is not mistaken for a bare address"
_it_is_bare_ip 'not-an-address:8080' \
  && t_fail "a colon alone must not make something an address" \
  || t_pass "a colon alone does not make something an address"

# ── the blocked-ips → blocked-domains merge must not FABRICATE its target ──────
# dump_blocked_forensics needs a live container, so it is driven here through a
# fake `docker` on PATH serving exactly its call shapes — the same idiom the
# assert_runs block below uses. The merge is the one line of it that can decide
# a file's EXISTENCE, and forensics_report reads existence as the difference
# between "the capture ran and saw nothing" and "we do not know".
#
# The vector is a clean run whose other reads failed: blocked-ips.txt is
# PRESENT AND EMPTY (a `docker exec cat` of a file the capture daemon created
# and never wrote to SUCCEEDS — this is what a clean run looks like, not a
# corner case), blocked.log and blocked-domains.txt absent. Guarded with `-f`
# the merge appends nothing and creates blocked-domains.txt anyway; appending
# nothing and appending something are indistinguishable from the exit status,
# which is why this needs a test rather than a reading.
MB_BIN="$TMP/mb-bin"; mkdir -p "$MB_BIN"
cat > "$MB_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# dump_blocked_forensics' call shapes, and only those:
#   inspect -f '{{.State.Running}}' <cid>   → the liveness probe
#   exec <cid> cat <abs-path>               → the four evidence reads
# A read is served iff $MB_CONTAINER holds a file of that basename; otherwise it
# fails exactly as `docker exec cat` does for a path the container lacks.
case "$1" in
  inspect) printf 'true\n'; exit 0 ;;
  exec)
    shift 2
    if [[ "$1" == "cat" ]]; then
      f="${2##*/}"
      [[ -f "$MB_CONTAINER/$f" ]] || exit 1
      cat "$MB_CONTAINER/$f"; exit 0
    fi
    printf 'mb fake docker: unexpected exec: %s\n' "$*" >&2; exit 99 ;;
esac
printf 'mb fake docker: unexpected call: %s\n' "$*" >&2; exit 99
FAKE
chmod +x "$MB_BIN/docker"

# $1=directory standing in for the container's /workspace/.agent-blocked →
# prints the per-run scratch dir dump_blocked_forensics wrote into, so the
# caller can assert on which files exist. IT_DOCKER_HOST is pinned empty so
# lib.sh's source-time resolution never reaches the fake with a `context
# inspect` it has no arm for (same reason ar_run below does it).
mb_run() {
  local scratch="$TMP/mb-scratch-$RANDOM"
  mkdir -p "$scratch"
  MB_CONTAINER="$1" IT_DOCKER_HOST="" PATH="$MB_BIN:$PATH" IT_SCRATCH="$scratch" \
    bash -c ". '$LIB'; dump_blocked_forensics fake-cid" >"$TMP/mb-report.txt" 2>&1
  printf '%s' "$(ls -d "$scratch"/case-* 2>/dev/null | head -1)"
}

MB_EMPTY="$TMP/mb-container-empty"; mkdir -p "$MB_EMPTY"
: > "$MB_EMPTY/blocked-ips.txt"           # present, zero bytes — the clean run
mb_d="$(mb_run "$MB_EMPTY")"
if [[ -n "$mb_d" ]]; then
  t_pass "dump_blocked_forensics ran against the fake docker and made a scratch dir"
else
  t_fail "dump_blocked_forensics ran against the fake docker (no scratch dir: $(cat "$TMP/mb-report.txt"))"
fi
[[ ! -e "$mb_d/blocked-domains.txt" ]] \
  && t_pass "an EMPTY blocked-ips.txt does not fabricate blocked-domains.txt" \
  || t_fail "an EMPTY blocked-ips.txt fabricated blocked-domains.txt ($(wc -c < "$mb_d/blocked-domains.txt") bytes) — the merge created a target with nothing to append"
grep -q 'UNKNOWN — the capture never ran' "$TMP/mb-report.txt" \
  && t_pass "with every read failed, the report still says UNKNOWN rather than clean" \
  || t_fail "with every read failed, the report says UNKNOWN (got: $(cat "$TMP/mb-report.txt"))"

# The complement, so the assertion above cannot be satisfied by a merge that
# simply stopped working: a blocked-ips.txt WITH a bare IP in it is still
# merged, and that IP is still the only copy of a real hard-blocked destination.
MB_FULL="$TMP/mb-container-full"; mkdir -p "$MB_FULL"
printf '203.0.113.77\n' > "$MB_FULL/blocked-ips.txt"
printf '# blocked destinations\n' > "$MB_FULL/blocked.log"
mb_d="$(mb_run "$MB_FULL")"
if [[ -f "$mb_d/blocked-domains.txt" ]] && grep -qx '203.0.113.77' "$mb_d/blocked-domains.txt"; then
  t_pass "a NON-empty blocked-ips.txt is still merged into blocked-domains.txt"
else
  t_fail "a NON-empty blocked-ips.txt is still merged into blocked-domains.txt (got: $(cat "$mb_d/blocked-domains.txt" 2>/dev/null))"
fi
grep -q '203.0.113.77' "$TMP/mb-report.txt" \
  && t_pass "the merged bare IP reaches the forensics report as a hard-blocked entry" \
  || t_fail "the merged bare IP reaches the forensics report (got: $(cat "$TMP/mb-report.txt"))"

# ── Ruby-case helpers ───────────────────────────────────────────────────────────
# ruby_wait_ready and assert_runs both take a live container id and are not
# unit-testable here — same reason capture_ready/sandbox_wait_capture above are
# only proven to be DEFINED, not exercised: there is no docker daemon in this
# environment. What the brief deliberately factored OUT into pure predicates —
# _it_ruby_reconcile_done / _it_ruby_reconcile_ok, decided from captured log text on
# stdin — IS hermetically testable, and that split is the point: it is what
# lets ruby_wait_ready's decision logic be proven correct without a container.
t_check "IT_RUBY_GROUP is a stable name shared across cases in one run" \
  "itruby" "$IT_RUBY_GROUP"

# A failed rvm bootstrap exits in SECONDS; polling only for `ruby` on PATH once
# burned a full 30-minute timeout on a compile that never started. That is why
# the reconcile's own terminal log lines are part of the condition.
_it_ruby_reconcile_done <<< '[rvm-reconcile] done.' \
  && t_pass "ruby readiness recognises a completed reconcile" \
  || t_fail "ruby readiness recognises a completed reconcile"
_it_ruby_reconcile_done <<< '[rvm-reconcile] FAILED: ruby-3.4.5' \
  && t_pass "ruby readiness recognises a FAILED reconcile (does not wait out the timeout)" \
  || t_fail "ruby readiness recognises a FAILED reconcile"
_it_ruby_reconcile_done <<< '[rvm-reconcile] installing ruby-3.4.5…' \
  && t_fail "an in-progress reconcile must not be reported ready" \
  || t_pass "an in-progress reconcile is not reported ready"

# `done.` and `FAILED:` both END the wait but are opposite OUTCOMES — that is
# why termination and success are two separate predicates, not one.
_it_ruby_reconcile_ok <<< '[rvm-reconcile] done.' \
  && t_pass "a completed reconcile is distinguished from a failed one" \
  || t_fail "a completed reconcile is distinguished from a failed one"
_it_ruby_reconcile_ok <<< '[rvm-reconcile] FAILED: ruby-3.4.5' \
  && t_fail "FAILED must not be reported as success" \
  || t_pass "FAILED is not reported as success"

# Empty input: no terminal line at all means "not yet ready" and "not ok",
# never a false positive from an unset grep matching nothing.
_it_ruby_reconcile_done <<< '' \
  && t_fail "empty input must not be reported as a terminated reconcile" \
  || t_pass "empty input is not a terminated reconcile"
_it_ruby_reconcile_ok <<< '' \
  && t_fail "empty input must not be reported as a successful reconcile" \
  || t_pass "empty input is not a successful reconcile"

# ── The PARTIAL-failure vector: the one that actually ships ────────────────────
# The brief's single-line vectors test `done.` and `FAILED:` as MUTUALLY
# EXCLUSIVE isolated lines. Real rvm-reconcile.sh is not that shape: its
# per-version failure at line 99 (`log "FAILED: ruby-$v is not installed …"`)
# does NOT exit — it falls through to the default-setting block and
# unconditionally logs "done." at line 115. So a reconcile where ONE requested
# version fails to compile and another succeeds produces a log with BOTH a
# FAILED: line and a later done. line — exactly the multi-line shape a
# single-line vector can never represent. The `native` image variant this
# increment introduces is configured `ruby=3.3.6,3.4.5` (two versions), so this
# is not a hypothetical: it is the exact log shape that variant can produce.
# Reconstructed from rvm-reconcile.sh's real control flow (lines 78-115), not
# invented: version A's install loop fails both attempts (no "already present"
# / no success line for it), version B installs cleanly, the verification loop
# emits FAILED: only for A, and the default-setting block unconditionally logs
# done. regardless.
partial_log="$(cat <<'LOG'
[rvm-reconcile] installing ruby-3.3.6…
[rvm-reconcile] install failed; refreshing rvm definitions (rvm get stable) and retrying…
[rvm-reconcile] installing ruby-3.4.5…
[rvm-reconcile] FAILED: ruby-3.3.6 is not installed (all install attempts failed)
[rvm-reconcile] setting default ruby-3.4.5 (first bootstrap)
[rvm-reconcile] done.
LOG
)"
_it_ruby_reconcile_done <<< "$partial_log" \
  && t_pass "a partial-failure reconcile IS recognised as terminated (it reached done.)" \
  || t_fail "a partial-failure reconcile is recognised as terminated"
_it_ruby_reconcile_ok <<< "$partial_log" \
  && t_fail "a PARTIAL failure (one version FAILED, reconcile still logs done.) must NOT be reported as success" \
  || t_pass "a partial-failure reconcile is correctly NOT reported as success"

declare -f ruby_wait_ready >/dev/null 2>&1 \
  && t_pass "ruby_wait_ready is defined" || t_fail "ruby_wait_ready is defined"
declare -f assert_runs >/dev/null 2>&1 \
  && t_pass "assert_runs is defined" || t_fail "assert_runs is defined"

# ── assert_runs' three outcomes, exercised through a fake docker ───────────────
# assert_runs backs 21 assertions across the packages tier and exists for ONE
# outcome its own comment names: a binary that is correctly on PATH and still
# dies on exec. rvm rewrites gem binstub shebangs to
# `#!/usr/bin/env ruby_executable_hooks`, so a correctly linked `bundle` can
# resolve and then fail to run — "on PATH" and "runs" are genuinely different
# failures. Its predecessor in verify-on-host.sh was UNREACHABLE for its entire
# existence because it tested `head`'s exit status: `if out="$(cmd | head -1)"`
# reports HEAD's status, and head succeeds on the empty output of a binary that
# just died.
#
# These four vectors REPLACE a `grep -qE` for the exact characters of the one
# line that fixed that (`if out="$(docker exec "$1" bash -c "$2 --version
# 2>&1")"`). The grep never called the function: a pure refactor — naming the
# positional parameters — turned it red without changing behaviour, and a
# regression anywhere else in assert_runs left it green. It is subsumed rather
# than merely deleted: the empty-output/non-zero-exit vector below is exactly
# the shape the head-exit-status bug cannot distinguish, so under that bug it
# reports PASS and this file goes red. Nothing about the grep's stated property
# survives unasserted.
#
# Same fake-docker-on-PATH idiom as capture_ready's test above, with one
# deliberate difference: this fake does not pattern-match the script assert_runs
# builds, it RUNS it against a controlled PATH standing in for the container's.
# So `command -v`, the exit status of `<bin> --version` and the diagnostic dump
# are all produced by real bash semantics, not by a fake agreeing with the
# test's expectations.
AR_BIN="$TMP/ar-docker"; mkdir -p "$AR_BIN"
cat > "$AR_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# assert_runs' only call shape: docker exec <cid> bash -c "<script>" (three
# times: the command -v probe, the --version run, the failure diagnostics).
case "$1" in
  exec)
    shift 2   # drop "exec" and <cid>
    if [[ "$1" == "bash" && "$2" == "-c" ]]; then
      # $FAKE_CONTAINER_BIN stands in for the container's PATH; /usr/bin:/bin
      # keep printf/head/readlink resolvable for assert_runs' own diagnostics.
      PATH="${FAKE_CONTAINER_BIN:?FAKE_CONTAINER_BIN not set}:/usr/bin:/bin" bash -c "$3"
      exit $?
    fi
    printf 'fake docker: unexpected exec call: %s\n' "$*" >&2; exit 99 ;;
  *) printf 'fake docker: unexpected call: %s\n' "$*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$AR_BIN/docker"

AR_TOOL=it-fake-tool
AR_ABSENT="$TMP/ar-absent"; mkdir -p "$AR_ABSENT"    # nothing on the container PATH
AR_BROKEN="$TMP/ar-broken"; mkdir -p "$AR_BROKEN"    # exits non-zero, prints NOTHING
AR_SHEBANG="$TMP/ar-shebang"; mkdir -p "$AR_SHEBANG" # the real binstub shape
AR_OK="$TMP/ar-ok"; mkdir -p "$AR_OK"                # answers --version and exits 0

# Silent AND non-zero: the head-exit-status bug's blind spot exactly. `head`
# succeeds on this binary's empty output, so the buggy form reports it as a
# working binary.
printf '#!/bin/sh\nexit 3\n' > "$AR_BROKEN/$AR_TOOL"
# The shipped defect, reproduced rather than described: an interpreter that
# does not exist. The kernel execs /usr/bin/env, env fails to find the
# interpreter, exit 127 with a message on stderr — which assert_runs' own
# `2>&1` folds into the captured output.
printf '#!/usr/bin/env it-fake-missing-interp\nprint 1\n' > "$AR_SHEBANG/$AR_TOOL"
# Two lines on purpose: the PASS line must carry only the first.
printf '#!/bin/sh\nprintf "%%s\\n" "it-fake-tool 1.2.3" "SECOND-LINE-MUST-NOT-APPEAR"\n' > "$AR_OK/$AR_TOOL"
chmod +x "$AR_BROKEN/$AR_TOOL" "$AR_SHEBANG/$AR_TOOL" "$AR_OK/$AR_TOOL"

# IT_DOCKER_HOST is pinned (to empty) so lib.sh's source-time resolution block
# short-circuits instead of reaching the fake docker with a `context inspect`
# it has no arm for. rc is printed rather than inferred from the subshell's
# status: `return 1` vs `return 0` is part of assert_runs' contract.
ar_run() {  # $1=directory standing in for the container's PATH
  FAKE_CONTAINER_BIN="$1" IT_DOCKER_HOST="" PATH="$AR_BIN:$PATH" \
    bash -c ". '$LIB'; assert_runs fake-cid $AR_TOOL; printf 'rc=%s\n' \"\$?\"" 2>&1
}
ar_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# 1. Absent from PATH → the PATH failure, and NOT the exec one.
out="$(ar_run "$AR_ABSENT")"
ar_has "$out" "FAIL: $AR_TOOL is on PATH" \
  && t_pass "assert_runs fails a binary that is absent from PATH" \
  || t_fail "assert_runs fails a binary that is absent from PATH (got: $out)"
ar_has "$out" 'FAILED TO RUN' \
  && t_fail "an absent binary must not be reported as present-but-broken (got: $out)" \
  || t_pass "an absent binary is not reported as present-but-broken"
ar_has "$out" 'rc=1' \
  && t_pass "assert_runs returns non-zero for an absent binary" \
  || t_fail "assert_runs returns non-zero for an absent binary (got: $out)"

# 2. Present, exits non-zero, prints NOTHING → the branch this whole block
#    exists for. Under `if out="$(cmd | head -1)"` this vector reports PASS.
out="$(ar_run "$AR_BROKEN")"
ar_has "$out" "FAIL: $AR_TOOL is present but FAILED TO RUN" \
  && t_pass "a binary that exits non-zero with EMPTY output is reported as present but FAILED TO RUN" \
  || t_fail "a binary that exits non-zero with EMPTY output is reported as present but FAILED TO RUN (got: $out)"
ar_has "$out" 'PASS:' \
  && t_fail "a silently-failing binary must not also report PASS (got: $out)" \
  || t_pass "a silently-failing binary reports no PASS"
ar_has "$out" "FAIL: $AR_TOOL is on PATH" \
  && t_fail "a present-but-broken binary must not be reported as missing from PATH (got: $out)" \
  || t_pass "a present-but-broken binary is not reported as missing from PATH"
ar_has "$out" 'rc=1' \
  && t_pass "assert_runs returns non-zero for a present-but-broken binary" \
  || t_fail "assert_runs returns non-zero for a present-but-broken binary (got: $out)"

# 3. The real binstub shape: on PATH, unresolvable interpreter. Same verdict,
#    plus the diagnostics that make it actionable — without them the report
#    says only "FAILED TO RUN" and the next step is a container round trip.
out="$(ar_run "$AR_SHEBANG")"
ar_has "$out" "FAIL: $AR_TOOL is present but FAILED TO RUN" \
  && t_pass "a binary with an unresolvable interpreter is reported as present but FAILED TO RUN" \
  || t_fail "a binary with an unresolvable interpreter is reported as present but FAILED TO RUN (got: $out)"
ar_has "$out" "path:    $AR_SHEBANG/$AR_TOOL" \
  && t_pass "the failure dump names the resolved path of the binary that died" \
  || t_fail "the failure dump names the resolved path of the binary that died (got: $out)"
# Both halves on ONE line, deliberately. As two separate `ar_has` conjuncts this
# could not fail for the property it names: `error:   ` is an unconditional
# label lib.sh prints whatever the value, and `it-fake-missing-interp` is
# independently satisfied by the `shebang:` line two lines above it. Emptying
# the error value in lib.sh left this file at 0 failure(s) — an assertion that
# cannot fail, inside the test written to close exactly that defect class.
grep -q 'error:.*it-fake-missing-interp' <<<"$out" \
  && t_pass "the failure dump carries the exec error itself, not just the verdict" \
  || t_fail "the failure dump carries the exec error itself (got: $out)"
# The shebang line is the one diagnostic that depends on `readlink -f`, which
# stock readlink lacked before macOS 12.3 — assert it only where the platform
# can produce it, rather than failing a correct lib.sh on an old host.
#
# The probe runs under the SAME PATH the dump ran under, not the ambient one.
# The fake pins the dump to "$FAKE_CONTAINER_BIN:/usr/bin:/bin", so an ambient
# probe on a pre-12.3 mac with Homebrew coreutils on PATH would find a working
# `readlink -f`, take the assert branch, and then fail against a dump produced
# by /usr/bin/readlink, which has none — a red against a correct lib.sh, for a
# difference the test itself introduced.
if PATH="/usr/bin:/bin" readlink -f / >/dev/null 2>&1; then
  ar_has "$out" 'shebang: #!/usr/bin/env it-fake-missing-interp' \
    && t_pass "the failure dump shows the rewritten shebang (the rvm binstub signature)" \
    || t_fail "the failure dump shows the rewritten shebang (got: $out)"
else
  # SKIP:, not NOTE: — run-all.sh recognises a column-0 SKIP: as a first-class
  # outcome and greps for it. It will still be masked in run-all.sh's one-line
  # summary, because PASS takes precedence over SKIP for a file that also
  # asserted real passes, and that precedence is right: this file IS a pass.
  # The line is for whoever reads the file's own output, and for a grep.
  printf 'SKIP: the shebang-dump assertion — /usr/bin/readlink here has no -f (macOS < 12.3)\n'
fi

# 4. Present and working → PASS, rc 0, and only the FIRST line of --version.
out="$(ar_run "$AR_OK")"
ar_has "$out" "PASS: $AR_TOOL runs: it-fake-tool 1.2.3" \
  && t_pass "a working binary reports PASS with its version line" \
  || t_fail "a working binary reports PASS with its version line (got: $out)"
ar_has "$out" 'FAIL:' \
  && t_fail "a working binary must not report any FAIL (got: $out)" \
  || t_pass "a working binary reports no FAIL"
ar_has "$out" 'SECOND-LINE-MUST-NOT-APPEAR' \
  && t_fail "the PASS line must carry only the first line of --version output (got: $out)" \
  || t_pass "the PASS line carries only the first line of --version output"
ar_has "$out" 'rc=0' \
  && t_pass "assert_runs returns zero for a working binary" \
  || t_fail "assert_runs returns zero for a working binary (got: $out)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
