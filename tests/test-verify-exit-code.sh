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
# Everything here is fake: a stub repo, a stub `docker`, stub tool binaries. No
# daemon, no image, no network. The stub `docker run` EXECUTES the in-container
# script locally instead of discarding it, so the real per-phase check logic is
# what runs — a stub that merely returned 0 would test the stub.
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
# `run ... -lc <script>` runs the script with the local bash. That is what makes
# these tests exercise the phase's real in-container logic (the MISSING /
# PRESENT-BUT-FAILED-TO-RUN branches) rather than a canned exit code.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  info|--version|version|system|rmi|stop|inspect) exit 0 ;;
  buildx) exit 0 ;;
  run)
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "-lc" || "$prev" == "-c" ]]; then exec bash -lc "$a"; fi
      prev="$a"
    done
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

# The six binaries Phase 2 checks. Present and runnable by default; a test below
# removes one to prove absence is detected.
for c in psql mysql mongosh convert wkhtmltopdf gcc; do
  printf '#!/usr/bin/env bash\necho "%s (stub) 1.0"\n' "$c" > "$TMP/bin/$c"
  chmod +x "$TMP/bin/$c"
done

# ── Stub repo ──────────────────────────────────────────────────────────────────
mk_repo() {  # $1=build.sh exit code
  local r="$TMP/repo"
  rm -rf "$r"; mkdir -p "$r/tests/integration"
  cp "$VERIFY" "$r/verify-on-host.sh"
  printf '#!/usr/bin/env bash\necho "stub build (rc=%s)" >&2\nexit %s\n' "$1" "$1" > "$r/build.sh"
  chmod +x "$r/build.sh"
  printf 'db-clients=\nimagemagick=OFF\nwkhtmltopdf=OFF\nruby=\ncopilot=OFF\n' > "$r/sandbox.conf"
  printf '#!/usr/bin/env bash\nexit %s\n' "${SMOKE_RC:-0}" > "$r/tests/test-agent-tools-smoke.sh"
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
r="$(mk_repo 1)"
expect_rc "phase 2: a failing build exits non-zero" 1 "$(run_verify "$r" 2)"
grep -q 'RESULT: FAILED' "$TMP/out.log" \
  && pass "phase 2: verdict line says FAILED" \
  || fail "phase 2: verdict line says FAILED"
grep -q 'PHASE 2 FAILED' "$TMP/out.log" \
  && pass "phase 2: names the phase that failed" \
  || fail "phase 2: names the phase that failed"

# ── A phase that passes must NOT make it fail ──────────────────────────────────
# The other half of the property. A script hard-wired to exit 1 would satisfy
# every assertion above and be just as useless.
r="$(mk_repo 0)"
expect_rc "phase 2: a clean run exits 0" 0 "$(run_verify "$r" 2)"
grep -q 'RESULT: PASSED' "$TMP/out.log" \
  && pass "phase 2: verdict line says PASSED" \
  || fail "phase 2: verdict line says PASSED"

# ── An absent tool fails the phase, not just the reader's attention ────────────
# This is the check that printed MISSING and returned 0.
mv "$TMP/bin/mongosh" "$TMP/mongosh.hidden"
r="$(mk_repo 0)"
rc="$(run_verify "$r" 2)"
expect_rc "phase 2: an absent tool exits non-zero" 1 "$rc"
grep -q 'MISSING' "$TMP/out.log" \
  && pass "phase 2: reports which tool is absent" \
  || fail "phase 2: reports which tool is absent"
mv "$TMP/mongosh.hidden" "$TMP/bin/mongosh"

# ── A tool that is present but will not run is a distinct failure ──────────────
# `if out="$(cmd | head -1)"` tests head's status, so this branch was unreachable
# in both Phase 2 and Phase 3 — including the Phase 3 diagnostic written
# specifically to catch a `bundle` killed by an rvm-rewritten shebang.
printf '#!/usr/bin/env bash\nexit 127\n' > "$TMP/bin/convert"
chmod +x "$TMP/bin/convert"
r="$(mk_repo 0)"
rc="$(run_verify "$r" 2)"
expect_rc "phase 2: a present-but-broken tool exits non-zero" 1 "$rc"
grep -q 'PRESENT BUT FAILED TO RUN' "$TMP/out.log" \
  && pass "phase 2: distinguishes broken from absent" \
  || fail "phase 2: distinguishes broken from absent (the head -1 status bug)"
printf '#!/usr/bin/env bash\necho "convert (stub) 1.0"\n' > "$TMP/bin/convert"
chmod +x "$TMP/bin/convert"

# ── Every phase is wired, not just the one under test ──────────────────────────
# A ledger with one caller is a ledger that catches one phase. Phase 3 is
# exercised through its build-failure branch only: the rest of it drives a real
# container for several minutes and belongs to the runtime corpus, not here.
r="$(mk_repo 1)"
expect_rc "phase 1: a failing build exits non-zero" 1 "$(run_verify "$r" 1)"
expect_rc "phase 3: a failing build exits non-zero" 1 "$(run_verify "$r" 3)"

r="$(SMOKE_RC=1 mk_repo 0)"
expect_rc "phase 1: a failing smoke test exits non-zero" 1 "$(run_verify "$r" 1)"

r="$(CORPUS_RC=1 mk_repo 0)"
expect_rc "phase 4: a failing corpus exits non-zero" 1 "$(run_verify "$r" 4)"

r="$(mk_repo 0)"
expect_rc "phase 4: a passing corpus exits 0" 0 "$(run_verify "$r" 4)"

# ── Multiple failures are all reported, and none stops the others ──────────────
# The phases are documented as independent. An early `exit 1` would turn the
# nightly into one-failure-per-run and hide the rest behind it.
r="$(CORPUS_RC=1 mk_repo 1)"
rc="$(run_verify "$r" "1 2 3 4")"
expect_rc "all four phases fail: still exits 1" 1 "$rc"
n="$(grep -c '^\[host-verify\]   phase [0-9]:' "$TMP/out.log")"
if [[ "$n" -eq 4 ]]; then
  pass "all four failures reach the summary (a failing phase does not abort the rest)"
else
  fail "all four failures reach the summary — got $n of 4"
  sed -n '/RESULT:/,$p' "$TMP/out.log" | sed 's/^/       /'
fi

# ── THE DEMONSTRATION ──────────────────────────────────────────────────────────
# Strip the verdict block and require the failing scenario to exit 0 again. That
# reproduces the exact defect this file was written for, and proves the
# assertions above discriminate. Truncation at a marker, not a sed substitution:
# a marker that has moved is a loud failure here, whereas a sed that matches
# nothing would leave the script intact and report a clean pass — the decorative
# check this project keeps finding.
r="$(mk_repo 1)"
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
    PATH="$TMP/bin:$PATH" REPO="$r" PHASES=2 bash "$r/neutered.sh" >/dev/null 2>&1
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
