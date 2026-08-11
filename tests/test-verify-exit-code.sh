#!/usr/bin/env bash
# Hermetic tests for verify-on-host.sh's EXIT STATUS.
#
# Why this file exists, precisely: verify-on-host.sh was written as a
# human-read diagnostic and later wired into nightly CI as a gate
# (`PHASES="1 2 3" bash ./verify-on-host.sh`). It recorded failures by printing
# "BUILD FAILED" and then exited 0 — from its first day in CI, in both repos, the
# packages job passed unconditionally and could not have done otherwise. Nobody
# knew whether those phases were green, because the job was structurally
# incapable of saying they were not.
#
# That history is why the failure ledger (phase_fail/FAILED_PHASES/RESULT:/exit 1)
# exists and why this file exists to hold the line on it. The phases that history
# refers to (1, 2, 3) are gone — Increment 3 moved what they checked into the
# packages tier of the runtime integration corpus — so this file now tests only
# what verify-on-host.sh still has: Phase 4 and the verdict mechanism itself.
#
# Everything here is fake: a stub repo, a stub `docker`, a stub
# tests/integration/run.sh. No daemon, no image, no network. The stub `docker
# run` EXECUTES the in-container script locally instead of discarding it, so
# the real per-phase check logic is what runs — a stub that merely returned 0
# would test the stub.
#
# The last test is the load-bearing one. It strips the verdict block back out and
# requires the SAME failing scenario to exit 0, which is the only way to know the
# tests above are discriminating rather than agreeing with a script that cannot
# fail. Without it this file would have passed against the broken original.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like run.sh, lib.sh and the script under test: upstream keeps
# the engine beside tests/, mgd-ai-containers keeps it in base/. One copy of this
# file serves both, which is the property that lets the two stay byte-identical.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/verify-on-host.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -f "$VERIFY" ]] || { fail "verify-on-host.sh not found at $VERIFY"; exit 1; }
bash -n "$VERIFY" && pass "verify-on-host.sh bash -n" || fail "verify-on-host.sh bash -n"

# ── Stub docker ────────────────────────────────────────────────────────────────
# Only Phase 0's environment banner still calls docker directly (--version,
# buildx version, info, system df), so a plain "always succeed" stub is enough
# — the surviving script has no `docker run`/`exec` of its own for this stub to
# intercept; Phase 4 delegates entirely to the stub tests/integration/run.sh.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/docker"

# ── Stub repo ──────────────────────────────────────────────────────────────────
# $1=build.sh exit code. Nothing in the surviving script (Phase 0, Phase 4)
# actually executes build.sh any more — only the preflight `[[ -f
# "$REPO/build.sh" ]]` existence check does — but that check still requires the
# file to exist, so mk_repo keeps writing it.
mk_repo() {  # $1=build.sh exit code
  local r="$TMP/repo"
  rm -rf "$r"; mkdir -p "$r/tests/integration"
  cp "$VERIFY" "$r/verify-on-host.sh"
  # verify-on-host.sh sources bash-floor.sh once $REPO is confirmed to be the
  # engine dir. Without this copy the source silently fails (set -uo pipefail
  # has no -e), printing "bash-floor.sh: No such file or directory" into every
  # captured log without affecting the exit code this file asserts on.
  cp "$ENGINE_DIR/bash-floor.sh" "$r/bash-floor.sh"
  printf '#!/usr/bin/env bash\necho "stub build (rc=%s)" >&2\nexit %s\n' "$1" "$1" > "$r/build.sh"
  chmod +x "$r/build.sh"
  printf 'db-clients=\nimagemagick=OFF\nwkhtmltopdf=OFF\nruby=\ncopilot=OFF\n' > "$r/sandbox.conf"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --list-caps) exit 0 ;; esac\nexit %s\n' \
    "${CORPUS_RC:-0}" > "$r/tests/integration/run.sh"
  printf '%s' "$r"
}

# Run a phase selection against a stub repo. Prints the exit code.
run_verify() {  # $1=repo $2=phases  → exit code, log in $TMP/out.log
  PATH="$TMP/bin:$PATH" REPO="$1" PHASES="$2" \
    bash "$1/verify-on-host.sh" > "$TMP/out.log" 2>&1
  printf '%s' "$?"
}

expect_rc() {  # $1=label $2=expected $3=actual
  if [[ "$3" == "$2" ]]; then
    pass "$1"
  else
    fail "$1 — expected exit $2, got $3"
    tail -12 "$TMP/out.log" | sed 's/^/       /'
  fi
}

# ── A phase that fails must make the script fail ───────────────────────────────
r="$(CORPUS_RC=1 mk_repo 0)"
expect_rc "phase 4: a failing corpus exits non-zero" 1 "$(run_verify "$r" 4)"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "phase 4: verdict line says FAILED" \
  || fail "phase 4: verdict line says FAILED"
grep -q 'PHASE 4 FAILED' "$TMP/out.log" \
  && pass "phase 4: names the phase that failed" \
  || fail "phase 4: names the phase that failed"

# ── A phase that passes must NOT make it fail ──────────────────────────────────
# The other half of the property. A script hard-wired to exit 1 would satisfy
# every assertion above and be just as useless.
r="$(mk_repo 0)"
expect_rc "phase 4: a passing corpus exits 0" 0 "$(run_verify "$r" 4)"
grep -q 'RESULT: PASSED' "$TMP/out.log" \
  && pass "phase 4: verdict line says PASSED" \
  || fail "phase 4: verdict line says PASSED"

# ── A failure is recorded and reported by the verdict, not just by exiting ─────
# The ledger existed to report every failure instead of stopping at the first.
# Phase 4 is now the only selectable, ledger-tracked phase left in the script
# (Phase 0 always runs and hard-exits on its own fatal condition rather than
# recording into the ledger), so the cross-phase "none stops the others"
# property this used to demonstrate with phases 1-4 together no longer has a
# second phase to demonstrate it against. What's left to check is the
# mechanism itself: a recorded failure reaches the summary with its phase
# number, under the same $PHASES default the script ships with.
r="$(CORPUS_RC=1 mk_repo 0)"
rc="$(run_verify "$r" 4)"
expect_rc "phase 4 fails: still exits 1" 1 "$rc"
n="$(grep -c '^\[host-verify\]   phase 4:' "$TMP/out.log")"
if [[ "$n" -eq 1 ]]; then
  pass "the failure reaches the summary with its phase number"
else
  fail "the failure reaches the summary with its phase number — got $n"
  sed -n '/RESULT:/,$p' "$TMP/out.log" | sed 's/^/       /'
fi

# ── A stale PHASES selection must fail loudly, not verify nothing and exit 0 ───
# The founding defect of this whole file, reachable now through phase SELECTION
# instead of phase REPORTING: PHASES="1 2 3" names only phases this script no
# longer has (they moved into the packages tier in Increment 3). want_phase()
# is a bare substring match with no validation, so nothing matched, nothing
# called phase_fail, and the script declared success having run zero checks —
# exactly what the failure ledger above exists to prevent. The string is not
# hypothetical: `PHASES="1 2 3" bash ./verify-on-host.sh` was the literal
# command in nightly.yml's packages job, in AGENTS.md, and in every note anyone
# wrote about this script for two increments. It survives in muscle memory and
# in the sibling repo's checkouts long after the phases themselves are gone,
# which is why the selection must reject it rather than quietly match nothing.
r="$(mk_repo 0)"
expect_rc "a stale PHASES=1 selection fails loudly, not exits 0" 1 "$(run_verify "$r" 1)"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "PHASES=1: verdict line says FAILED" \
  || fail "PHASES=1: verdict line says FAILED"

r="$(mk_repo 0)"
expect_rc "a stale PHASES=\"1 2 3\" selection fails loudly, not exits 0" 1 "$(run_verify "$r" "1 2 3")"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "PHASES=\"1 2 3\": verdict line says FAILED" \
  || fail "PHASES=\"1 2 3\": verdict line says FAILED"

# The empty case is NOT affected — ${PHASES:-4} must still default cleanly to
# the one real phase, with no phase_fail firing for a selection nobody made.
r="$(mk_repo 0)"
expect_rc "an empty/unset PHASES still defaults to 4 and passes" 0 "$(run_verify "$r" "")"
grep -q 'RESULT: PASSED' "$TMP/out.log" \
  && pass "PHASES=\"\": verdict line says PASSED (default still works)" \
  || fail "PHASES=\"\": verdict line says PASSED (default still works)"

# ── THE DEMONSTRATION ──────────────────────────────────────────────────────────
# Strip the verdict block and require the failing scenario to exit 0 again. That
# reproduces the exact defect this file was written for, and proves the
# assertions above discriminate. Truncation at a marker, not a sed substitution:
# a marker that has moved is a loud failure here, whereas a sed that matches
# nothing would leave the script intact and report a clean pass — the decorative
# check this project keeps finding.
r="$(CORPUS_RC=1 mk_repo 0)"
marker='# ── Verdict ─'
if ! grep -qF "$marker" "$r/verify-on-host.sh"; then
  fail "the verdict marker moved — this demonstration verified NOTHING; update it"
else
  before="$(wc -l < "$r/verify-on-host.sh")"
  awk -v m="$marker" 'index($0, m) { exit } { print }' \
    "$r/verify-on-host.sh" > "$r/neutered.sh"
  after="$(wc -l < "$r/neutered.sh")"
  if [[ "$after" -ge "$before" ]]; then
    fail "truncation removed nothing ($before → $after lines) — nothing was demonstrated"
  else
    pass "verdict block located and stripped ($before → $after lines)"
    PATH="$TMP/bin:$PATH" REPO="$r" PHASES=4 bash "$r/neutered.sh" >/dev/null 2>&1
    if [[ "$?" -eq 0 ]]; then
      pass "without the verdict block the same failing run exits 0 (the original bug)"
    else
      fail "without the verdict block the run still fails — something ELSE is setting"
      printf '       the exit code, so the tests above are not measuring the verdict.\n'
    fi
  fi
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
