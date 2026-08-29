#!/usr/bin/env bash
# run-all.sh — run the ai-containers test suite.
#
# Usage:
#   ./tests/run-all.sh                 # run every tests/test-*.sh
#   ./tests/run-all.sh docs-path       # run tests matching a substring
#   ./tests/run-all.sh -v              # stream each test's full output
#
# Exit status: 0 only if every selected test exits 0.
#
# Each test is self-contained (its own temp dirs, isolated HOME, fake docker
# where needed) and must not touch the real repo or the real projects.conf.
# Written for bash 3.2 (stock macOS bash).

set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

verbose=0
filters=""
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) verbose=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'run-all.sh: unknown option: %s\n' "$arg" >&2; exit 2 ;;
    *) filters="${filters:+$filters }$arg" ;;
  esac
done

selected=""
for t in "$tests_dir"/test-*.sh; do
  [ -f "$t" ] || continue
  if [ -n "$filters" ]; then
    match=0
    for f in $filters; do
      case "$(basename "$t")" in *"$f"*) match=1 ;; esac
    done
    [ "$match" -eq 1 ] || continue
  fi
  selected="${selected:+$selected }$t"
done

if [ -z "$selected" ]; then
  printf 'run-all.sh: no tests matched%s\n' "${filters:+ ($filters)}" >&2
  exit 2
fi

total=0
failed=0
failed_names=""
# GUARDED, and it emits the scaffold channel rather than just dying. This is the
# DRIVER: every falsify oracle is `tests/run-all.sh <name>`, so an empty $log
# here makes `> "$log"` fail for every test in the run and the whole thing looks
# like a wall of failures — which the mutation tier reads as "the mutation was
# noticed" (backlog F31). SCAFFOLD-FAILED: is the channel run.sh greps to score
# such a run UNPROVEN instead of KILLED.
#
# AN EXPLICIT TEMPLATE, so that $TMPDIR is HONOURED. A bare `mktemp` honours it
# on GNU and IGNORES it on BSD/macOS, where the per-user directory comes from
# confstr and no environment variable reaches it -- measured: `TMPDIR=/x mktemp
# -d` returns /var/folders/... on this platform. With a template both agree.
#
# That matters because this trap CANNOT run on SIGKILL, and SIGKILL is routine
# here: the falsify watchdog kills a timed-out oracle's whole process group, and
# `tests/test-falsify-run.sh` SIGKILLs drivers on purpose to exercise that path.
# Each such death orphans one log. The trap is right and stays; what changes is
# that a caller can now CONTAIN what the trap cannot reach, by pointing TMPDIR
# at a directory it removes itself -- which is exactly what that test now does.
# STRIPPED OF ITS TRAILING SLASH, and that is not tidiness. macOS exports
# TMPDIR WITH one -- `/var/folders/.../T/` -- so "${TMPDIR}/x" yields `//x`. Most
# things normalise that away and some do not, which is how a test comes to
# compare a path against the same path and lose: `extract-discovery.sh`
# canonicalises what it prints while the assertion holds the raw value, and ten
# of that file's assertions failed on exactly that (measured 2026-08-29). Done
# once, here, so every path this driver hands a test is already clean.
RA_TMP="${TMPDIR:-/tmp}"; RA_TMP="${RA_TMP%/}"
log="$(mktemp "$RA_TMP/run-all-log.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp (run-all.sh could not create its per-test log)\n'; exit 1; }

# ── EVERY TEST GETS ITS OWN TMPDIR, AND IT GOES WHEN THE RUN DOES ─────────────
# Two problems, one mechanism, and they are the same problem seen from two ends.
#
# LEAKS. A test that forgets to clean up leaves its scratch in the user's temp
# directory forever, and nothing notices. Measured 2026-08-29 on one macOS host:
# 447 stale entries, 90 MB, none of them from a failure -- a clean 71/71 run
# leaked 14 on its own, from four separate causes (two EXIT traps silently
# replaced by a later one, a removal naming the wrong variable, and logs
# orphaned by SIGKILLs that no trap can survive). Fixing those four was
# necessary and is not sufficient: the fifth arrives the same way, invisibly,
# and only the two trap clobbers were even in principle reviewable.
#
# THE SYMLINKED-TMPDIR ARM. verify-on-host.sh Phase 5 and CI's
# suite-symlinked-tmp job re-run this suite with TMPDIR pointed at a SYMLINK, to
# catch the macOS path-shape class (/var/folders vs /private/var/folders) that
# has cost this repo 22 assertions across two increments. On Linux that works.
# On a Mac it largely does not, because a bare `mktemp` HONOURS $TMPDIR on GNU
# and IGNORES it on BSD -- the per-user directory comes from confstr and no
# environment variable reaches it. Measured the same day, instrumenting every
# call: of 60 tests, ZERO honoured a symlinked TMPDIR fully, 53 ignored it
# ENTIRELY, and 622 of 834 calls escaped to /var/folders. The arm that exists
# because CI is not a Mac was, on a Mac, mostly a second ordinary run.
#
# A generated shim fixes both: it supplies an explicit $TMPDIR-rooted template
# when the caller gave none, so BSD and GNU agree, and then a per-test TMPDIR
# both CONTAINS the test and is genuinely reached by it. Generated into the
# run's own scratch rather than committed, because a tracked file named `mktemp`
# has no .sh suffix and would escape every gate this repo runs -- `bash -n`, the
# dialect linter and the shellcheck pass all discover scripts by that suffix.
#
# IT CONTAINS, IT DOES NOT JUDGE. Nothing here fails a test for leaking, and
# that is deliberate: every falsify oracle is `tests/run-all.sh <name>`, so a
# test turned red by its own untidiness would be scored as the mutation being
# noticed -- a false KILL, which is precisely what the survivor ledger exists to
# prevent. Containment is safe here; a verdict is not.
RA_TMPROOT="$(mktemp -d "$RA_TMP/run-all-tmp.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp -d (run-all.sh could not create its scratch root)\n'; exit 1; }
trap 'rm -f "$log"; rm -rf "$RA_TMPROOT"' EXIT
mkdir -p "$RA_TMPROOT/bin" || { printf 'SCAFFOLD-FAILED: mkdir (run-all.sh could not create its shim directory)\n'; exit 1; }
cat > "$RA_TMPROOT/bin/mktemp" <<'RA_MKTEMP_SHIM'
#!/usr/bin/env bash
# Generated by tests/run-all.sh -- see the comment above its creation.
# Pass through untouched whenever the caller said where it wanted the file:
# an operand IS a template, and -p/-t name a directory or prefix. Otherwise
# append a $TMPDIR-rooted template, which is the one form BSD and GNU agree on.
_ra_real=""
for _c in /usr/bin/mktemp /bin/mktemp; do
  [ -x "$_c" ] && { _ra_real="$_c"; break; }
done
# NOT `command -v mktemp`: this shim is on PATH, so that resolves to itself.
[ -n "$_ra_real" ] || { echo "mktemp: no system mktemp found" >&2; exit 127; }
for _a in "$@"; do
  case "$_a" in
    -p*|-t*) exec "$_ra_real" "$@" ;;
    -*)      ;;
    *)       exec "$_ra_real" "$@" ;;
  esac
done
# Trailing slash stripped: macOS exports TMPDIR with one, and "$TMPDIR/x" then
# yields `//x` -- a path that compares unequal to its own canonical form.
_ra_tmp="${TMPDIR:-/tmp}"
exec "$_ra_real" "$@" "${_ra_tmp%/}/tmp.XXXXXXXXXX"
RA_MKTEMP_SHIM
chmod +x "$RA_TMPROOT/bin/mktemp" || { printf 'SCAFFOLD-FAILED: chmod (run-all.sh could not make its mktemp shim executable)\n'; exit 1; }
PATH="$RA_TMPROOT/bin:$PATH"
export PATH

for t in $selected; do
  name="$(basename "$t")"
  total=$((total + 1))
  printf '── %s\n' "$name"
  # ONE DIRECTORY PER TEST, all under the root the EXIT trap removes. Not
  # removed at the bottom of this loop: the body `continue`s from several
  # branches, so a per-iteration removal would be skipped by exactly the runs
  # that failed -- the ones whose scratch is most likely to be worth keeping and
  # most certain to be left behind.
  ra_td="$RA_TMPROOT/$name"
  mkdir -p "$ra_td" || ra_td="$RA_TMPROOT"
  if [ "$verbose" -eq 1 ]; then
    TMPDIR="$ra_td" bash "$t" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
  else
    TMPDIR="$ra_td" bash "$t" >"$log" 2>&1
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    # A printed FAIL: line is a failure regardless of the exit code, checked
    # BEFORE the assertion count below. The exit code is exactly the signal
    # that can rot: a shadowed counter variable, a forgotten `exit "$fails"`,
    # a helper redefined after the fact — any of these leaves a test printing
    # real FAIL: lines while still exiting 0. That already happened for real:
    # tests/test-integration-lib.sh sourced tests/integration/lib.sh, which
    # redefines pass()/fail() to increment ITS OWN $it_fails, so every
    # assertion after the source line tallied into a variable the file's own
    # `exit "$fails"` never read — two genuine FAIL:s printed, exit 0 anyway.
    # Gating purely on exit code, as this loop did before, reported that file
    # as a clean pass; a test that cannot report the thing it was written to
    # report is worse than no test.
    fail_lines="$(grep -cE '^FAIL:' "$log")"
    if [ "$fail_lines" -gt 0 ]; then
      failed=$((failed + 1))
      failed_names="${failed_names:+$failed_names }$name"
      printf '   FAIL  (exited 0 but printed %s FAIL: line(s))\n' "$fail_lines"
      if [ "$verbose" -eq 0 ]; then
        grep -E '^FAIL:' "$log" | sed 's/^/     /' | head -20
        printf '     (run with -v for full output)\n'
      fi
      continue
    fi
    # Surface the assertion count without the noise. PASS takes precedence
    # over SKIP: a test that both skips part of itself and asserts real
    # PASS/ok lines is a genuine pass, not a skip.
    ok="$(grep -cE '^(PASS|  ok)' "$log")"
    if [ "$ok" -gt 0 ]; then
      printf '   PASS  (%s assertion(s))\n' "$ok"
    elif grep -qE '^SKIP:' "$log"; then
      # A test may deliberately skip itself (e.g. a gated real-container smoke
      # test whose enabling env is unset). An explicit SKIP: line is a
      # first-class outcome, not a silent no-op, so it is not a failure and is
      # exempt from the "asserted nothing" guard below.
      printf '   SKIP  (%s)\n' "$(grep -m1 -E '^SKIP:' "$log" | sed 's/^SKIP:[[:space:]]*//')"
    else
      # Exiting 0 without asserting anything is not a pass: it is a test that
      # silently did nothing (bad guard, early return, renamed helper).
      failed=$((failed + 1))
      failed_names="${failed_names:+$failed_names }$name"
      printf '   FAIL  (exited 0 but asserted nothing)\n'
    fi
  elif grep -qE '^SCAFFOLD-FAILED:' "$log"; then
    # THE TEST COULD NOT BUILD ITS OWN WORKSPACE, which is a different event
    # from an assertion failing and is reported as one. A test that cannot
    # `mktemp -d` measures nothing; saying "FAIL (exit 1)" over the top of that
    # sends a reader hunting for a defect in the code under test. Still a
    # failure — it counts and the suite exits non-zero — but named for what it
    # is, and its own line is surfaced rather than the assertion greps below,
    # which a collapsed test fills with true-but-irrelevant noise.
    failed=$((failed + 1))
    failed_names="${failed_names:+$failed_names }$name"
    printf '   FAIL  (could not set itself up — the environment, not the code)\n'
    grep -E '^SCAFFOLD-FAILED:' "$log" | sed 's/^/     /' | head -5
  else
    failed=$((failed + 1))
    failed_names="${failed_names:+$failed_names }$name"
    printf '   FAIL  (exit %s)\n' "$rc"
    if [ "$verbose" -eq 0 ]; then
      grep -E '^(FAIL|  FAIL|ERROR)' "$log" | sed 's/^/     /' | head -20
      printf '     (run with -v for full output)\n'
    fi
  fi
done

printf '\n%s test(s), %s passed, %s failed\n' "$total" "$((total - failed))" "$failed"
if [ "$failed" -gt 0 ]; then
  printf 'Failing: %s\n' "$failed_names"
  exit 1
fi
