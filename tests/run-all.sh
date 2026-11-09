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
# For the mutation tier only (tests/falsify/run.sh sets them):
#   RA_TEST_CLOCK=<s>               a clock for every test
#   RA_TEST_CLOCKS="<name>=<s> ..." a clock for each named test
#   RA_TIMES_FILE=<path>            append "<name> <seconds>" per test
#   RA_CLOCKED_FILE=<path>          append "<name> <seconds>" for a test its
#                                   clock stopped
#
# Each test is self-contained (its own temp dirs, isolated HOME, fake docker
# where needed) and must not touch the real repo or the real projects.conf.
# Written for bash 3.2 (stock macOS bash).

set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each test starts here, looked up again by path (the loop below): from a WSL
# checkout under /mnt/c the directory every test inherited went stale partway
# through a long run, while the path stayed good, and git, rsync and bash then
# failed with ENOENT from getcwd (the drvfs flake, docs/testing.md; GAP-10).
ra_cwd="$PWD"

verbose=0
filters=""
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) verbose=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# has no .sh suffix and the gates discover scripts by that suffix. THAT TRADE IS
# NOT FREE, and the honest version is: a quoted heredoc escapes both `bash -n`
# and the shellcheck pass just as completely as an unsuffixed tracked file
# would, so those two are lost either way. (A line here may not BEGIN with the
# word shellcheck after the `#`: that is a directive, and shellcheck errors
# SC1072/SC1073 on it.) Only the dialect linter still sees this body, because it
# matches raw lines rather than parsing files. Keeping it generated buys the
# guarantee that the shim cannot drift from the driver that installs it; it does
# not buy lint coverage, and claiming otherwise was the reason to write this
# down.
#
# IT CONTAINS, IT DOES NOT JUDGE. Nothing here fails a test for leaking, and
# that is deliberate: every falsify oracle is `tests/run-all.sh <name>`, so a
# test turned red by its own untidiness would be scored as the mutation being
# noticed -- a false KILL, which is precisely what the survivor ledger exists to
# prevent. Containment is safe here; a verdict is not.
RA_TMPROOT="$(mktemp -d "$RA_TMP/run-all-tmp.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp -d (run-all.sh could not create its scratch root)\n'; exit 1; }
# ONE THING TO REMOVE, AND IT EXISTS BEFORE ANYTHING IS REMOVABLE. The per-test
# log used to be its own `mktemp` taken BEFORE this directory, with a trap
# covering both installed AFTER it -- so a failing `mktemp -d` exited between
# them and orphaned the log. Demonstrated with a stub mktemp that fails only on
# -d: SCAFFOLD-FAILED, rc=1, run-all-log.XXXXXX left behind. Inside the scratch
# root it needs no mktemp of its own (the directory is already unique) and no
# second trap, so the window cannot reopen.
log="$RA_TMPROOT/run-all-log"
# exit-trap-ok: what this driver forks (a test, its clock, tee) never returns into this script, so never runs this trap
trap 'rm -rf "$RA_TMPROOT"' EXIT
mkdir -p "$RA_TMPROOT/bin" || { printf 'SCAFFOLD-FAILED: mkdir (run-all.sh could not create its shim directory)\n'; exit 1; }
# RESOLVED HERE, BEFORE THE SHIM DIRECTORY GOES ON PATH, so `command -v` still
# finds the system mktemp rather than the shim. The shim itself cannot do this
# — by the time it runs it IS the first mktemp on PATH — which is why it fell
# back to a hardcoded /usr/bin:/bin list, and why that list was the whole
# resolution. On a host where mktemp lives elsewhere (NixOS, a stripped image)
# every mktemp call in every test would exit 127 and the suite would collapse.
# Exported, not baked into the heredoc: the heredoc is quoted so that nothing
# inside it expands, which is what keeps its $@ and $TMPDIR intact.
# WITH EVERY SHIM DIRECTORY STRIPPED FROM PATH FIRST, because run-all.sh NESTS:
# a falsify oracle is `run-all.sh <name>`, and its fixtures run run-all.sh again
# inside that. A plain `command -v mktemp` in the inner one resolves to the OUTER
# shim, the inner shim then execs it, the outer execs what IT was told is real —
# and the two exec each other forever. Measured: the suite ran 20 minutes into
# test-falsify-run.sh without finishing, and test-falsify-historical.sh reported
# an oracle HUNG 180s without asserting. Both were this.
RA_RESOLVE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' \
  | grep -v '/run-all-tmp\.[^/]*/bin$' | paste -sd: -)"
RA_REAL_MKTEMP="$(PATH="$RA_RESOLVE_PATH" command -v mktemp 2>/dev/null || true)"
unset RA_RESOLVE_PATH
export RA_REAL_MKTEMP
cat > "$RA_TMPROOT/bin/mktemp" <<'RA_MKTEMP_SHIM'
#!/usr/bin/env bash
# Generated by tests/run-all.sh -- see the comment above its creation.
# Pass through untouched whenever the caller said where it wanted the file:
# an operand IS a template, and -p/-t name a directory or prefix. Otherwise
# append a $TMPDIR-rooted template, which is the one form BSD and GNU agree on.
# $RA_REAL_MKTEMP is resolved by run-all.sh with `command -v`, BEFORE this
# directory is on PATH. The list below is the fallback for a shim invoked
# without that (a test that calls it directly), not the primary resolution.
# NOT `command -v mktemp` here: this shim is on PATH, so that resolves to itself.
_ra_real="${RA_REAL_MKTEMP:-}"
if [ -z "$_ra_real" ] || [ ! -x "$_ra_real" ]; then
  _ra_real=""
  for _c in /usr/bin/mktemp /bin/mktemp; do
    [ -x "$_c" ] && { _ra_real="$_c"; break; }
  done
fi
[ -n "$_ra_real" ] || { echo "mktemp: no system mktemp found" >&2; exit 127; }
for _a in "$@"; do
  case "$_a" in
    # --tmpdir[=DIR] is the caller naming a directory, exactly like -p, and it
    # must be treated as one: GNU REFUSES an absolute template alongside it
    # ("with --tmpdir, it may not be absolute"), so falling into the -* arm and
    # appending one turns a working call into an error. It matches neither -p*
    # nor -t* (it begins with two dashes), which is how it reached that arm.
    -p*|-t*|--tmpdir|--tmpdir=*) exec "$_ra_real" "$@" ;;
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

# HERMETIC MEANS NOT YOUR DIRECTORIES. A test that launches sandbox.sh with the
# developer's own VAULT_PATH/SPECS_PATH/EXTRA_MOUNTS/REPOS still exported mounts
# those real directories — and the launch WRITES into the git repositories it
# protects there (sandbox.sh: launcher_ro_overlay(), the commondir placeholder).
# On 2026-10-06 a suite run did exactly that to a real vault. Unset for every
# test here; each test that launches sandbox.sh unsets them too, for a run on its
# own, and tests/test-hermetic-env.sh fails if one does not.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS \
      SANDBOX_ENV_FILE SANDBOX_WORKDIR

# ── A CLOCK PER TEST, WHICH ONLY THE MUTATION TIER SETS ───────────────────────
# tests/falsify/run.sh runs a mutant's tests as ONE run of this driver, under one
# clock of --timeout times the number of tests, so a mutant that hung one test
# paid the whole set's clock: 72 minutes for sandbox.sh's 24 tests at 180 s, and
# five such mutants were a third of a measured sample's CPU (feature-gaps review
# GAP-2). With a clock, a test that runs past it is stopped together with its
# process group (what left it, by setsid or its own job control, is not), a
# TEST-TIMEOUT: line says so — NOT a FAIL: line, since
# no assertion was seen failing, and the tier scores a timeout as unproven, not
# as a kill — and so is the run: the tests after it are not run, as under the
# set's clock, where the hung test held them back. Run, they could fail on what
# the stopped test left in the tree, and that would read as the mutant's doing
# (review of the GAP-2 clock). RA_CLOCKED_FILE names the stopped test for the
# tier, which a line in the output can only do ambiguously.
#
# Read once and taken out of the environment: a test that runs this driver
# itself (tests/test-run-all.sh, the tier's own tests) must not inherit them.
ra_clock_all="${RA_TEST_CLOCK:-}"; ra_clocks="${RA_TEST_CLOCKS:-}"; ra_times="${RA_TIMES_FILE:-}"
ra_clocked="${RA_CLOCKED_FILE:-}"
unset RA_TEST_CLOCK RA_TEST_CLOCKS RA_TIMES_FILE RA_CLOCKED_FILE
ra_clock_for() {  # <name> → its clock in whole seconds, or nothing
  ra_c=""
  for ra_kv in $ra_clocks; do
    case "$ra_kv" in "$1="*) ra_c="${ra_kv#*=}" ;; esac
  done
  [ -n "$ra_c" ] || ra_c="$ra_clock_all"
  case "$ra_c" in ''|*[!0-9]*|0) ra_c="" ;; esac
  printf '%s' "$ra_c"
}
ra_cur=""; ra_dog=""; ra_tee=""; ra_not_run=""
ra_sig() {  # <signal> <pid>...: each one's process group, or the process where
  # job control made none
  ra_s="$1"; shift
  for ra_p in "$@"; do
    [ -n "$ra_p" ] || continue
    kill -"$ra_s" -"$ra_p" 2>/dev/null || kill -"$ra_s" "$ra_p" 2>/dev/null
  done
}
ra_stop_test() {  # the current clocked test, its clock and tee
  # tee before the test, as the clock does, so nothing the dying test prints
  # reaches the output (third review of the GAP-2 clock); TERM so its own traps
  # run, and KILL half a second later, inside the tier's one-second grace. The
  # clock is KILLed last: stopped first, a driver KILLed in that half second left
  # a test that ignores TERM with nothing to end it.
  ra_sig TERM "$ra_tee" "$ra_cur"
  if [ -n "$ra_cur$ra_tee" ]; then sleep 0.5; fi
  ra_sig KILL "$ra_tee" "$ra_cur" "$ra_dog"
}
if [ -n "$ra_clock_all$ra_clocks" ]; then
  # A clocked test leads a process group of its own, and the tier's watchdog
  # ends a run by signalling THIS driver's group, which no longer holds it. So
  # the driver ends the test's group, and its clock's, on the way out.
  trap 'ra_stop_test; exit 143' TERM
  trap 'ra_stop_test; exit 130' INT
fi

# AS ROOT, A NON-ROOT AGENT. sandbox.sh refuses a UID or GID of 0 for the agent
# and takes both from `id` by default, so in a root container (the floor job,
# verify-on-host.sh's floor container) every test that launches it stopped at
# the refusal (TST-9). The suite runs as root there on purpose — some tests have
# root-only branches — so the agent gets the identity the refusal itself
# suggests, and only when the run named none. A test that checks the default
# identity asks a fresh environment for it, not this one.
if [ "$(id -u)" = 0 ] || [ "$(id -g)" = 0 ]; then
  export SANDBOX_UID="${SANDBOX_UID:-1000}" SANDBOX_GID="${SANDBOX_GID:-1000}"
fi

ra_rest="$selected"
for t in $selected; do
  ra_rest="${ra_rest#"$t"}"; ra_rest="${ra_rest# }"
  name="$(basename "$t")"
  total=$((total + 1))
  printf '── %s\n' "$name"
  cd -- "$ra_cwd" 2>/dev/null || true
  # ONE DIRECTORY PER TEST, all under the root the EXIT trap removes. Not
  # removed at the bottom of this loop: the body `continue`s from several
  # branches, so a per-iteration removal would be skipped by exactly the runs
  # that failed -- the ones whose scratch is most likely to be worth keeping and
  # most certain to be left behind.
  ra_td="$RA_TMPROOT/$name"
  mkdir -p "$ra_td" || ra_td="$RA_TMPROOT"
  ra_clock="$(ra_clock_for "$name")"; ra_timed_out=0; ra_t0=$SECONDS; ra_us0="${EPOCHREALTIME:-}"
  if [ -n "$ra_clock" ]; then
    # Monitor mode, so the test and its clock each lead a process group that
    # can be signalled whole: a test's children (a launcher, a fake docker, a
    # sleep) would otherwise outlive it. The test is still this driver's own
    # child, as without a clock: tests/test-falsify-run.sh's signal fixture
    # kills its $PPID, standing in for the OOM killer taking the driver, and a
    # subshell or a pipeline between them took that blow instead. So with -v
    # its output reaches tee through a FIFO, and tee is this driver's child too,
    # waited for so the log is whole before it is read.
    ra_flag="$RA_TMPROOT/.clock.$total"; ra_fifo="$RA_TMPROOT/.out.$total"; ra_tee=""; ra_out="$log"
    rm -f "$ra_flag" "$ra_fifo" "$ra_fifo.done"
    set -m
    if [ "$verbose" -eq 1 ] && mkfifo "$ra_fifo"; then
      ( tee "$log" < "$ra_fifo"; : > "$ra_fifo.done" ) &
      ra_tee=$!
      ra_out="$ra_fifo"
    fi
    TMPDIR="$ra_td" bash "$t" >"$ra_out" 2>&1 &
    ra_cur=$!
    # The clock, a second at a time: it also ends the test the moment the driver
    # is gone (the OOM killer, a KILL), which nothing else would now that the
    # test's group is not the driver's (review of the GAP-2 clock).
    ra_self=$$
    # The driver is asked first, and the test's whole group, not its leader: a
    # test that kills its parent and exits leaves its children in that group.
    # tee is stopped with the test, as it was under the set's clock: what a
    # dying test prints is not a verdict (re-review of the GAP-2 clock).
    ( ra_n=0
      while [ "$ra_n" -lt "$ra_clock" ]; do
        sleep 1; ra_n=$((ra_n + 1))
        kill -0 "$ra_self" 2>/dev/null || { ra_sig KILL "$ra_cur" "$ra_tee"; exit 0; }
        kill -0 -"$ra_cur" 2>/dev/null || kill -0 "$ra_cur" 2>/dev/null || exit 0
      done
      : > "$ra_flag"; ra_sig TERM "$ra_tee" "$ra_cur"; sleep 2; ra_sig KILL "$ra_tee" "$ra_cur" ) &
    ra_dog=$!
    set +m
    wait "$ra_cur"
    rc=$?
    # KILL: the clock has nothing to clean up, and a TERM ignored since the
    # driver started would leave the wait below blocked.
    ra_sig KILL "$ra_dog"; wait "$ra_dog" 2>/dev/null
    # And whatever the test left running, which would act on the next one.
    kill -KILL -"$ra_cur" 2>/dev/null
    if [ -n "$ra_tee" ]; then
      # Bounded: a process that left the test's group can hold the FIFO open.
      ra_n=0
      # Not when the clock stopped it, which stopped tee too: no marker comes.
      while [ ! -e "$ra_fifo.done" ] && [ ! -f "$ra_flag" ] && [ "$ra_n" -lt 20 ]; do sleep 0.1; ra_n=$((ra_n + 1)); done
      ra_sig KILL "$ra_tee"; wait "$ra_tee" 2>/dev/null
    elif [ "$verbose" -eq 1 ]; then
      cat "$log"
    fi
    ra_cur=""; ra_dog=""; ra_tee=""
    [ ! -f "$ra_flag" ] || ra_timed_out=1
    rm -f "$ra_flag" "$ra_fifo" "$ra_fifo.done"
  elif [ "$verbose" -eq 1 ]; then
    TMPDIR="$ra_td" bash "$t" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
  else
    TMPDIR="$ra_td" bash "$t" >"$log" 2>&1
    rc=$?
  fi
  if [ -n "$ra_times" ]; then
    # Whole seconds, truncated, from microseconds where bash has them: $SECONDS
    # counts the second boundaries crossed, so a 10 ms test could read as 1.
    # Digits only: the decimal point is the locale's.
    if [ -n "$ra_us0" ] && [ -n "${EPOCHREALTIME:-}" ]; then
      ra_el=$(( (${EPOCHREALTIME//[!0-9]/} - ${ra_us0//[!0-9]/}) / 1000000 ))
    else
      ra_el=$(( SECONDS - ra_t0 ))
    fi
    { printf '%s %s\n' "$name" "$ra_el" >> "$ra_times"; } 2>/dev/null
  fi
  # WHAT THE TEST LEFT, COUNTED AND NEVER JUDGED. Containment made leaks
  # INVISIBLE: before this scratch root existed they surfaced as debris in the
  # developer's own temp directory, which is exactly how four of them were
  # found. Now run-all.sh removes everything on exit, so a reintroduced trap
  # clobber would be permanently undetectable -- the fix having removed the only
  # signal that the class exists.
  #
  # REPORTED AT THE END, never as a failure and never inline. Every falsify
  # oracle is `tests/run-all.sh <name>` run with -v, so a test turned red by its
  # own untidiness would be scored as the mutation being noticed -- a false
  # KILL, the thing the survivor ledger exists to prevent. And an extra line
  # beside PASS/FAIL/SKIP is a line something downstream may be parsing.
  if [ "$ra_td" != "$RA_TMPROOT" ]; then
    ra_left="$(ls -A "$ra_td" 2>/dev/null | wc -l | tr -d ' ')"
    [ "${ra_left:-0}" -gt 0 ] 2>/dev/null && ra_leaky="${ra_leaky:+$ra_leaky }$name:$ra_left"
  fi
  if [ "$ra_timed_out" -eq 1 ]; then
    failed=$((failed + 1))
    failed_names="${failed_names:+$failed_names }$name"
    # On a line of its own, though the test's last write may have ended mid-line.
    if [ "$verbose" -eq 1 ] && [ -s "$log" ] && [ -n "$(tail -c 1 "$log")" ]; then printf '\n'; fi
    printf 'TEST-TIMEOUT: %s ran past its %ss clock and was stopped\n' "$name" "$ra_clock"
    if [ -n "$ra_clocked" ]; then { printf '%s %s\n' "$name" "$ra_clock" >> "$ra_clocked"; } 2>/dev/null; fi
    # No excerpt of its log: without -v the log holds what it printed while it
    # died, which is not a result (third review of the GAP-2 clock).
    printf '   FAIL  (ran past its %ss clock)\n' "$ra_clock"
    ra_not_run="$ra_rest"
    break
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
    # And up to five lines above the first marker, which is where "see the
    # error above" points: shown alone, the marker hid the line saying why. A
    # floor run on 2026-11-05 showed test-falsify-historical.sh's marker over a
    # git that would not trust a copied .git, which only these lines named. Not
    # a PASS: or FAIL: line: the falsify tier reads an indented FAIL: here as an
    # assertion's.
    awk '/^SCAFFOLD-FAILED:/ { for (i = (n > 5 ? n - 5 : 0); i < n; i++) print b[i % 5]; exit }
         NF && !/(^|[[:space:]])(PASS|FAIL):/ { b[n % 5] = $0; n++ }' "$log" | sed 's/^/     /'
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
# AFTER the totals line, and only when there is something to say: that line is
# parsed in several places and this one must not come between anything and it.
# `left` rather than `leaked`, because a test may keep scratch deliberately --
# this reports a fact and draws no conclusion from it.
[ -n "${ra_leaky:-}" ] && printf 'left in TMPDIR: %s\n' "$ra_leaky"
if [ -n "$ra_not_run" ]; then
  ra_names=""
  for ra_t in $ra_not_run; do ra_names="${ra_names:+$ra_names }$(basename "$ra_t")"; done
  printf 'not run, after a test ran past its clock: %s\n' "$ra_names"
fi
if [ "$failed" -gt 0 ]; then
  printf 'Failing: %s\n' "$failed_names"
  exit 1
fi
