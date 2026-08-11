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
# refers to (1, 2, 3) are gone for good — Increment 3 moved what they checked
# into the packages tier of the runtime integration corpus, and those numbers
# must never be reused (see verify-on-host.sh's own header). Increment 4 added
# phases 5 (the hermetic suite + schema gate) and 7 (lint, shellcheck gating), so
# this file now tests Phase 4, Phase 5, Phase 7 and the verdict mechanism itself
# — including, again, whether one failing phase can hide another, which phases 5
# and 7 make possible to demonstrate again (see the dedicated block below).
#
# Everything here is fake: a stub repo, a stub `docker`, a stub `shellcheck`, and
# stubs for tests/integration/run.sh, tests/run-all.sh, check-sandbox-version.sh
# and tests/bash-dialect-lint.sh. No daemon, no image, no network — none of the
# stubs literally executes the command it stands in for; each is a canned exit
# code so the pass/fail PATH through verify-on-host.sh is what gets exercised,
# not a real build or a real container.
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

# ── Static checks: the phase 5/7 selection wiring ───────────────────────────────
# The default selection must name every phase this script has. A local layer
# nobody selects is not a local layer.
grep -qE 'PHASES="\$\{PHASES:-4 5 7\}"' "$VERIFY" \
  && pass "PHASES defaults to every phase (4 5 7)" \
  || fail "PHASES defaults to every phase (4 5 7)"
grep -qE '^VALID_PHASES="0 4 5 7"' "$VERIFY" \
  && pass "VALID_PHASES names 0 4 5 7" || fail "VALID_PHASES names 0 4 5 7"

# Every phase must record through phase_fail — the founding defect was a phase
# that failed while the script exited 0.
for p in 5 7; do
  if awk -v p="$p" '$0 ~ "PHASE "p" —" {g=1} g && /phase_fail '"$p"'/ {found=1} END{exit !found}' "$VERIFY"; then
    pass "phase $p records through phase_fail"
  else
    fail "phase $p records through phase_fail — a failure there would exit 0"
  fi
done

# ── Stub docker ────────────────────────────────────────────────────────────────
# Phase 0's environment banner calls docker directly (--version, buildx version,
# info, system df) and must always see success, or every test here would die at
# Phase 0 regardless of which phase it means to exercise. Phase 5's
# declared-floor step is the one real `docker run` in the surviving script; this
# stub does not execute its payload (that would mean apt-get and a real image
# pull inside a "hermetic" test) — it exits $DOCKER_RUN_RC instead, so that
# sub-step's pass/fail path is independently testable via a canned code, same
# idiom as CORPUS_RC below for tests/integration/run.sh. Phase 4 has no direct
# `docker run`/`exec` of its own — it delegates entirely to the stub
# tests/integration/run.sh.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  run) exit "${DOCKER_RUN_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

# ── Stub shellcheck ────────────────────────────────────────────────────────────
# Phase 7 gates on shellcheck's exit code. A real shellcheck is not guaranteed
# on whatever machine runs this suite, and this repo currently carries a real
# pre-existing shellcheck backlog (Task 9 of this increment clears it) — neither
# fact may leak into a hermetic test's result, so the stub always wins over PATH.
cat > "$TMP/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
exit "${SHELLCHECK_RC:-0}"
EOF
chmod +x "$TMP/bin/shellcheck"

# ── Stub repo ──────────────────────────────────────────────────────────────────
# $1=build.sh exit code. Nothing in the surviving script (Phase 0, Phase 4)
# actually executes build.sh any more — only the preflight `[[ -f
# "$REPO/build.sh" ]]` existence check does — but that check still requires the
# file to exist, so mk_repo keeps writing it.
#
# Phases 5 and 7 need their own stub targets (tests/run-all.sh,
# check-sandbox-version.sh, tests/bash-dialect-lint.sh) and, for Phase 7's
# `git ls-files`, a real git repository with at least one tracked file — an
# empty/non-git stub dir would make Phase 7 fail with "parsed no files"
# regardless of what a given test is trying to isolate, which is a different
# assertion (covered on its own below). Each stub's exit code is independently
# configurable (SUITE_RC / SCHEMA_RC / DIALECT_RC, alongside the existing
# CORPUS_RC and DOCKER_RUN_RC), so a test can make exactly one phase — or two at
# once — fail without touching the others.
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
  chmod +x "$r/tests/integration/run.sh"
  printf '#!/usr/bin/env bash\nexit %s\n' "${SUITE_RC:-0}" > "$r/tests/run-all.sh"
  chmod +x "$r/tests/run-all.sh"
  printf '#!/usr/bin/env bash\nexit %s\n' "${SCHEMA_RC:-0}" > "$r/check-sandbox-version.sh"
  chmod +x "$r/check-sandbox-version.sh"
  printf '#!/usr/bin/env bash\nexit %s\n' "${DIALECT_RC:-0}" > "$r/tests/bash-dialect-lint.sh"
  chmod +x "$r/tests/bash-dialect-lint.sh"
  ( cd "$r" && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
      && git add -A \
      && git -c user.email=t@example -c user.name=t commit -q -m stub ) >/dev/null 2>&1
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
# HISTORICAL NOTE, corrected: this comment used to say Phase 4 was "the only
# selectable, ledger-tracked phase left in the script", so the cross-phase "one
# broken phase never hides another" property — the ledger's FOUNDING purpose —
# had no second phase left to demonstrate it against, and this block could only
# re-check the single-phase mechanism (a recorded failure reaches the summary
# with its phase number). That was true only because Increment 3 had removed
# phases 1-3 and left just one. Increment 4 added phases 5 and 7, so the
# cross-phase demonstration is possible again — restored in the dedicated block
# immediately below, not folded in here, so each keeps testing one thing.
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

# ── RESTORED: two phases failing in the same run must BOTH be named ────────────
# This is the demonstration the comment above used to say was lost. Phase 5
# (via SUITE_RC) and Phase 7 (via DIALECT_RC) are made to fail independently,
# together, so the founding property — one broken phase does not hide another —
# has a real cross-phase case again, not just the single-phase mechanism check
# above. PHASES="5 7" deliberately excludes Phase 4, so CORPUS_RC is irrelevant
# here and only these two are in play.
r="$(SUITE_RC=1 DIALECT_RC=1 mk_repo 0)"
rc="$(run_verify "$r" "5 7")"
expect_rc "phase 5 and phase 7 can fail in the same run" 1 "$rc"
grep -q 'PHASE 5 FAILED' "$TMP/out.log" \
  && pass "both-failing run: names phase 5" \
  || fail "both-failing run: names phase 5"
grep -q 'PHASE 7 FAILED' "$TMP/out.log" \
  && pass "both-failing run: names phase 7" \
  || fail "both-failing run: names phase 7"
n5="$(grep -c '^\[host-verify\]   phase 5:' "$TMP/out.log")"
n7="$(grep -c '^\[host-verify\]   phase 7:' "$TMP/out.log")"
if [[ "$n5" -eq 1 && "$n7" -eq 1 ]]; then
  pass "RESULT: FAILED summary names BOTH phase 5 and phase 7, not just the first"
else
  fail "RESULT: FAILED summary names BOTH phase 5 and phase 7 — got phase5=$n5 phase7=$n7"
  sed -n '/RESULT:/,$p' "$TMP/out.log" | sed 's/^/       /'
fi
grep -q 'RESULT: FAILED — 2 phase(s)' "$TMP/out.log" \
  && pass "verdict counts exactly 2 failed phases, not 1" \
  || fail "verdict counts exactly 2 failed phases, not 1"

# ── shellcheck missing from PATH must fail the phase, not silently skip it ─────
# Phase 7's shellcheck sub-check is gated on `command -v shellcheck`. Bypasses
# run_verify()'s PATH (which always prepends the stub shellcheck) with a
# second bin dir carrying only the stub docker, so this exercises the ELSE
# branch none of the tests above ever reach. Must ALSO strip any PATH component
# that resolves a REAL shellcheck (a caught bug: an earlier version of this test
# merely prepended the no-shellcheck dir, leaving a real shellcheck reachable
# later in the inherited $PATH on any host that has one installed — it passed
# the exit-code assertion but failed the message assertion, which is exactly
# why both are checked).
mkdir -p "$TMP/bin-no-shellcheck"
cp "$TMP/bin/docker" "$TMP/bin-no-shellcheck/docker"
no_sc_path="$TMP/bin-no-shellcheck"
IFS=':' read -ra _path_parts <<< "$PATH"
for _p in "${_path_parts[@]}"; do
  [[ -x "$_p/shellcheck" ]] && continue
  no_sc_path="$no_sc_path:$_p"
done
r="$(mk_repo 0)"
PATH="$no_sc_path" REPO="$r" PHASES=7 bash "$r/verify-on-host.sh" \
  > "$TMP/out.log" 2>&1
expect_rc "shellcheck missing from PATH fails phase 7, not a silent skip" 1 "$?"
grep -q 'shellcheck not installed' "$TMP/out.log" \
  && pass "names the reason: shellcheck not installed" \
  || fail "names the reason: shellcheck not installed"

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
# This guard must SURVIVE the addition of phases 5 and 7 — VALID_PHASES grew to
# "0 4 5 7", and 1/2/3 must still be rejected, not accidentally re-admitted.
r="$(mk_repo 0)"
expect_rc "a stale PHASES=1 selection fails loudly, not exits 0" 1 "$(run_verify "$r" 1)"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "PHASES=1: verdict line says FAILED" \
  || fail "PHASES=1: verdict line says FAILED"

r="$(mk_repo 0)"
expect_rc "a stale PHASES=\"1 2 3\" selection still fails after 5 and 7 exist" 1 \
  "$(run_verify "$r" "1 2 3")"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "PHASES=\"1 2 3\": verdict line says FAILED" \
  || fail "PHASES=\"1 2 3\": verdict line says FAILED"

# The empty case is NOT affected — ${PHASES:-4 5 7} must still default cleanly
# to every real phase this script has, with no phase_fail firing for a
# selection nobody made. This is also the one test that exercises ALL of
# phases 4, 5 and 7 (and every one of their sub-checks) passing together in a
# single hermetic run, since mk_repo's stubs all default their *_RC to 0.
r="$(mk_repo 0)"
expect_rc "an empty/unset PHASES still defaults to 4 5 7 and passes" 0 "$(run_verify "$r" "")"
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
