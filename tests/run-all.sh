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
log="$(mktemp)" || { printf 'SCAFFOLD-FAILED: mktemp (run-all.sh could not create its per-test log)\n'; exit 1; }
trap 'rm -f "$log"' EXIT

for t in $selected; do
  name="$(basename "$t")"
  total=$((total + 1))
  printf '── %s\n' "$name"
  if [ "$verbose" -eq 1 ]; then
    bash "$t" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
  else
    bash "$t" >"$log" 2>&1
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
