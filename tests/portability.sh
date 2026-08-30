#!/usr/bin/env bash
# portability.sh — GNU/BSD-neutral helpers for the hermetic suite.
#
# SOURCED by tests, never executed. The suite runs on ubuntu CI (GNU coreutils)
# and, from increment 4 onward, on a developer's macOS host (BSD userland) via
# verify-on-host.sh Phase 5. `stat -c`, `sha1sum` and `md5sum` do not exist on
# macOS; `stat -f`, `shasum` and `md5` do.
#
# Every helper prints to stdout and must NEVER print empty on a supported
# platform: an empty string compares equal to another empty string, which turns
# a portability failure into a test that passes vacuously.
#
# NO HELPER FOR AWK, BUT ONE TRAP WORTH KNOWING, because it cost a floor-run
# failure: **do not use {n} interval quantifiers in an awk regex.** ubuntu:22.04
# — which is the bash-floor container the local layer and CI both run — ships
# mawk 1.3.4-20200120, where intervals are DISABLED by default, so
# /^[0-9a-f]{40}$/ matches NOTHING there. It silently inverts the assertion
# rather than erroring. ubuntu:24.04 mawk and macOS awk both support intervals,
# so this is invisible everywhere except the floor. Write
# `length($3) == 40 && $3 ~ /^[0-9a-f]+$/` instead. `grep -E` and bash `[[ =~ ]]`
# are unaffected — both honour intervals reliably.

# GNU `stat -f` is NOT an invalid option that falls through — it means
# --file-system, so on GNU the old `stat -c … || stat -f …` fallback did not
# error, it printed filesystem information to stdout. Harmless at today's call
# sites (all pre-check existence) and silently wrong for anyone reusing the
# idiom for a new field. Probe the platform once instead of relying on one
# invocation failing.
if stat -c '%a' . >/dev/null 2>&1; then _P_STAT_GNU=1; else _P_STAT_GNU=0; fi

p_stat_mode() {  # $1=file → octal mode, e.g. 644
  if [[ "$_P_STAT_GNU" == "1" ]]; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

p_stat_meta() {  # $1=file → "name size mtime", for change detection
  if [[ "$_P_STAT_GNU" == "1" ]]; then stat -c '%n %s %Y' "$1"; else stat -f '%N %z %m' "$1"; fi
}

p_sha1() {  # $1=file → hex digest only
  if command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | cut -d' ' -f1
  else shasum -a 1 "$1" | cut -d' ' -f1; fi
}

p_md5() {  # $1=file → hex digest only
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
  else md5 -q "$1"; fi
}

p_realdir() {  # $1=existing dir → its fully-resolved (symlink-free) absolute path
  # Independent of readlink -f / greadlink -f, which is what the code under
  # test (resolve_path) itself uses — a test that canonicalises its EXPECTED
  # value with the same mechanism as the code being asserted on is not a test,
  # it is `assert f(x) == f(x)`. `cd` + `pwd -P` is a different primitive (a
  # shell builtin, not readlink) that reaches the same physical, symlink-free
  # answer: on macOS, where /var is itself a symlink to /private/var, `cd
  # /var/folders/… && pwd -P` reports /private/var/folders/…, matching what
  # resolve_path's readlink -f independently resolves it to.
  ( cd "$1" 2>/dev/null && pwd -P )
}

# p_timeout <seconds> <command> [args…] — run a command under a wall-clock bound.
# Returns the command's OWN exit status if it finishes in time, or 124 (the code
# GNU timeout uses, so a caller needs no special-casing) if the clock expires.
#
# Unlike the helpers above this one produces no value on stdout of its own — it
# passes the command's through — so it is deliberately NOT part of the "must
# never print empty" family, and must not be added to test-portability.sh's
# non-empty sweep.
#
# WHY THIS EXISTS RATHER THAN `timeout 10 …`: timeout(1) is GNU coreutils and is
# absent from a stock macOS. That is not a hypothesis — it took the first real
# macOS run (2026-08-08) to surface it in the integration runner, whose
# it_timeout() resolves GNU timeout, then Homebrew's gtimeout, then a pure-bash
# fallback. The falsify backlog's F22 prescribed `timeout 10` for the callers
# below; on the very host those callers are verified on, that is a command not
# found.
#
# WHY THERE IS NO GNU-timeout FAST PATH HERE, unlike it_timeout: a
# `command -v timeout` probe is a platform branch whose two arms behave
# identically on any machine that HAS timeout — which is exactly the shape of
# defect that let p_sha1's probe be inverted with every test green (backlog
# F23), and it cost a whole increment to write an assertion that could see it.
# One implementation has no unassertable arm, and it makes the bound behave the
# same on Linux and macOS — which matters here, because the verdicts these
# callers produce are currently a function of how fast the machine is.
#
# WHY A WATCHDOG AND NOT A POLLING LOOP, which is what it_timeout's fallback
# uses: the polling shape was written here first and then discarded, because a
# `while kill -0 "$pid"` loop followed by a bare `wait "$pid"` IS ITSELF
# HANGABLE BY ITS OWN MUTATION. Negate the liveness probe and the loop never
# runs, so control falls to a `wait` on a child that is still alive and blocks
# forever. Measured: it hung test-portability.sh for the full two minutes it was
# given. A bound whose own cond-negate mutant is UNPROVEN would have added a
# fifth hanging mutant to the corpus in the helper written to remove the other
# four. The watchdog has no loop and no conditional in front of the kill, so
# every path through it terminates: `wait` cannot block past the deadline
# because something always kills the child at it.
#
# The watchdog's stdio goes to /dev/null, and that redirect is load-bearing
# rather than tidiness. Without it the watchdog -- and, more to the point, the
# `sleep` it forks -- inherit the caller's stdout, so `out="$(p_timeout 10 …)"`
# blocks until the sleep finishes even though the bounded command returned
# immediately and the watchdog was already killed: a command substitution reads
# until EVERY holder of the write end lets go. Measured before the redirect:
# 0s called directly, 10s the moment the same call was wrapped in `$( )`, which
# is exactly how two of the three callers below use it.
#
# The flag file, not the exit status, is what says "expired": a killed child
# reports 143, which is also a status a command can legitimately exit with, and
# a bound that cannot tell those apart is the same confusion between "the
# process died" and "the process was seen failing" that this whole exercise is
# about.
p_timeout() {  # $1=seconds, $2… = command
  local secs="$1"; shift
  # An explicit template: `mktemp` with no arguments at all is a GNU extension,
  # and this file exists because of exactly that class of difference.
  local flag; flag="$(mktemp "${TMPDIR:-/tmp}/p_timeout.XXXXXX")" || return 125
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"
    printf 'x' > "$flag"
    kill -TERM "$cmd_pid" 2>/dev/null
    sleep 1
    kill -KILL "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local dog_pid=$!
  wait "$cmd_pid"
  local rc=$?
  kill -TERM "$dog_pid" 2>/dev/null
  wait "$dog_pid" 2>/dev/null
  if [[ -s "$flag" ]]; then rm -f "$flag"; return 124; fi
  rm -f "$flag"
  return "$rc"
}

# ── A REAL TTY ON STDIN, for the consent prompts ─────────────────────────────
# `repo.sh` gates its destructive commands on `[[ -t 0 ]]`, so the branch that
# reads "Type 'yes' to confirm" is unreachable from an ordinary test — which is
# why nothing asserted that answering "no" leaves the data alone. Reaching it
# needs a pty, and `script(1)` is the only vehicle available: **python3 is
# ABSENT from ubuntu:22.04**, the bash-floor image, so a Python-`pty` harness
# would pass on macOS and on a developer host and die in exactly the arm the
# floor container exists to catch. There is nothing behind `script`.
#
# GNU takes the command as ONE STRING and BSD takes argv, so the platform is
# PROBED ONCE rather than discovered by letting one invocation fail — the same
# discipline, and the same reason, as _P_STAT_GNU above.
#
# Measured on both arms before being relied on: GNU on WSL2, ubuntu:22.04 (as
# root) and ubuntu:24.04, util-linux 2.37.2/2.39.3; BSD on macOS 15. Both give
# rc 0 for a delayed "yes", rc 1 for "no", and the transcript echoes the prompt
# BEFORE the reply — which is what proves `read -r -p` blocked on the pty rather
# than consuming buffered input.
#
# TWO TRAPS, both of which ship green. The pty emits `\r`, so exact-match and
# line-count assertions need it stripped — but stripping it THROUGH A PIPE
# replaces the command's exit status with `tr`'s:
#
#   out=$( … | p_pty cmd | tr -d '\r' ); rc=$?   # rc is tr's 0 — the abort is INVISIBLE
#   out=$( … | p_pty cmd ); rc=$?; out="${out//$'\r'/}"   # rc=1, correct
#
# The status is the entire point of the mutants these prompts carry, so strip
# after capturing, never in the pipeline.
if script --version 2>/dev/null | grep -q util-linux; then _P_PTY_GNU=1; else _P_PTY_GNU=0; fi

p_pty() {  # $1… = command + args, run with a real tty on stdin
  if [[ "$_P_PTY_GNU" == "1" ]]; then
    # %q, because GNU collapses the command to one string and a path containing
    # a space would otherwise split into two arguments.
    local cmd; printf -v cmd '%q ' "$@"
    script -qec "$cmd" /dev/null
  else
    script -q /dev/null "$@"
  fi
}
