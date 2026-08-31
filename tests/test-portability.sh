#!/usr/bin/env bash
# The GNU/BSD-neutral helpers must agree with the platform's own tools.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# OWNED BY THIS PROCESS — backlog F30/F32/F64. p_timeout backgrounds the
# command it times and a watchdog beside it; both are forked children of this
# script, and a child can end up running this EXIT trap. When it does, it
# deletes the fixture THIS script is still using, and the four p_* helpers
# below then return empty and report four symptoms of that one fact.
#
# Reproduced 2026-08-30 on a Linux host by restoring 189ebda's flat shared
# /tmp and running the tier oversubscribed: a control went red with the
# sightings' exact signature (dir=n exists=n size=? left=0), and an
# instrumented trap caught the firing directly —
#   TRAPFIRE pid=2284480 bashpid=2285462 subshell=1
#            cmd=[local cmd_pid=$!] fn=[p_timeout main]
# — BASH_SUBSHELL=1 and BASHPID != $$: this trap, running in a forked child.
#
# $BASHPID, not $$: $$ is the SCRIPT's pid and stays the same in a subshell,
# so comparing it to itself would guard nothing. $BASHPID is the pid of the
# process actually executing, which is what distinguishes a child from the
# owner. The removal is thus confined to the one process entitled to make it,
# whatever fires the trap and whenever.
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

printf 'content\n' > "$TMP/f"; chmod 644 "$TMP/f"

# THE FIXTURE, ASSERTED BEFORE ANYTHING IS CONCLUDED FROM IT. Every helper below
# is handed this one file, so if it was never written they all return empty and
# the report is four mysterious "returned empty" lines describing one fact. That
# is exactly how F30/F32 has read three times (see the loop near the end of this
# file). SCAFFOLD-FAILED: is its own channel in the falsify harness, reported
# apart from assertion failures, which is what makes "the fixture is missing"
# land as a cause rather than as four symptoms.
if [[ ! -s "$TMP/f" ]]; then
  printf 'SCAFFOLD-FAILED: fixture %s is missing or empty (exists=%s size=%s) — every helper below would return empty and report four symptoms of this one fact\n' \
    "$TMP/f" "$([[ -e "$TMP/f" ]] && printf y || printf n)" \
    "$(wc -c <"$TMP/f" 2>/dev/null | tr -d ' ' || printf '?')"
  exit 1
fi

[[ "$(p_stat_mode "$TMP/f")" == "644" ]] \
  && pass "p_stat_mode reports the octal mode" \
  || fail "p_stat_mode reports the octal mode — got '$(p_stat_mode "$TMP/f")'"

chmod 755 "$TMP/f"
[[ "$(p_stat_mode "$TMP/f")" == "755" ]] \
  && pass "p_stat_mode tracks a mode change" \
  || fail "p_stat_mode tracks a mode change — got '$(p_stat_mode "$TMP/f")'"

# The digest helpers must be stable and must differ for differing content.
a="$(p_sha1 "$TMP/f")"; b="$(p_sha1 "$TMP/f")"
[[ -n "$a" && "$a" == "$b" ]] \
  && pass "p_sha1 is non-empty and stable" || fail "p_sha1 is non-empty and stable"
printf 'other\n' > "$TMP/g"
[[ "$(p_sha1 "$TMP/f")" != "$(p_sha1 "$TMP/g")" ]] \
  && pass "p_sha1 distinguishes different content" \
  || fail "p_sha1 distinguishes different content"

# p_sha1 must pick the tool the PLATFORM actually has. The two assertions above
# cannot see that: this machine carries BOTH sha1sum and shasum and they print
# the same digest for the same bytes, so inverting the probe -- `cond-negate` of
# `command -v sha1sum` (falsify backlog F23) -- changes which tool runs and
# changes nothing observable. Its p_md5 sibling only dies by an accident of tool
# population (`md5 -q` does not exist on Linux, so the inverted probe prints
# empty and the non-empty check catches it), which measures the platform rather
# than the branch, and stops working the moment a host carries both.
#
# So make the branch decide the answer: run p_sha1 with a PATH holding exactly
# ONE of the two tools. Whichever half runs, the inverted probe reaches for the
# tool that is absent and yields an empty digest.
#
#   PATH has sha1sum only:  pristine -> sha1sum (correct);  mutated -> shasum   (absent)
#   PATH has shasum only:   pristine -> shasum  (correct);  mutated -> sha1sum  (absent)
#
# The expected digest is a literal rather than a second call to p_sha1: checking
# a helper against itself is `assert f(x) == f(x)`, which is how the branch went
# unasserted in the first place. shasum is a perl script with an absolute
# shebang, so restricting PATH does not break it.
sha1_want="7fe70820e08a1aac0ef224d9c66ab66831cc4ab1"   # sha1 of the 8 bytes "content\n"
if [[ "$(cat "$TMP/f")" != "content" ]]; then
  fail "p_sha1 branch-selection fixture still holds the bytes sha1_want was computed for"
else
  sha1_stub="$TMP/stub-bin"; mkdir -p "$sha1_stub"
  ln -sf "$(command -v cut)" "$sha1_stub/cut"
  sha1_tools_seen=0
  for sha1_tool in sha1sum shasum; do
    command -v "$sha1_tool" >/dev/null 2>&1 || continue
    sha1_tools_seen=$((sha1_tools_seen + 1))
    ln -sf "$(command -v "$sha1_tool")" "$sha1_stub/$sha1_tool"
    sha1_got="$( export PATH="$sha1_stub"; p_sha1 "$TMP/f" )"
    if [[ "$sha1_got" == "$sha1_want" ]]; then
      pass "p_sha1 digests correctly when $sha1_tool is the only digest tool on PATH"
    else
      fail "p_sha1 digests correctly when $sha1_tool is the only digest tool on PATH — want '$sha1_want', got '$sha1_got'"
    fi
    rm -f "$sha1_stub/$sha1_tool"
  done
  if [[ "$sha1_tools_seen" -gt 0 ]]; then
    pass "p_sha1 branch selection was exercised against $sha1_tools_seen digest tool(s)"
  else
    fail "p_sha1 branch selection was exercised — neither sha1sum nor shasum exists, so the assertions above ran zero times"
  fi
fi

m="$(p_md5 "$TMP/f")"
[[ -n "$m" && "$m" == "$(p_md5 "$TMP/f")" ]] \
  && pass "p_md5 is non-empty and stable" || fail "p_md5 is non-empty and stable"
[[ "$(p_md5 "$TMP/f")" != "$(p_md5 "$TMP/g")" ]] \
  && pass "p_md5 distinguishes different content" \
  || fail "p_md5 distinguishes different content"

# p_stat_meta: assert the VALUE, not merely non-emptiness. The branch selector
# in tests/portability.sh can be inverted -- both the `cmp-flip` and the
# `cond-negate` of `[[ "$_P_STAT_GNU" == "1" ]]` -- and the `[[ -n "$meta" ]]`
# check below passed against the result for as long as it stood alone, because
# on GNU `stat -f` is NOT an invalid option that falls through: it means
# --file-system, so the swapped branch prints a multi-line filesystem report
# plus an error rather than nothing, and that garbage is non-empty. Measured
# (falsify backlog F25):
#
#   pristine:  f 8 1787173959
#   mutated:   stat: cannot read file system information for '%N %z %m': ...
#                File: "f"
#                  ID: 622806a99446626e Namelen: 255     Type: overlayfs
#              (and four more lines)
#
# What separates them is the SHAPE and the VALUE -- exactly three fields, the
# middle one the file's real byte size -- which is the assertion p_stat_mode one
# line up has always carried and this helper did not. That asymmetry is why the
# meta line looked covered by association while both of its mutants survived the
# whole suite.
#
# Called from inside $TMP with a bare filename so "exactly three fields" is a
# property of the helper rather than of whether TMPDIR happens to contain a
# space.
meta="$(cd "$TMP" && p_stat_meta f)"
[[ -n "$meta" ]] && pass "p_stat_meta returns something" || fail "p_stat_meta returns something"

meta_want_size="$(wc -c < "$TMP/f")"; meta_want_size="${meta_want_size//[[:space:]]/}"
# shellcheck disable=SC2206  # deliberate: splitting on whitespace IS how the field count is measured
meta_fields=($meta)
if [[ "${#meta_fields[@]}" -eq 3 ]]; then
  pass "p_stat_meta returns exactly three fields (got '$meta')"
else
  fail "p_stat_meta returns exactly three fields — got ${#meta_fields[@]} in '$meta'"
fi
if [[ "${meta_fields[1]:-}" == "$meta_want_size" ]]; then
  pass "p_stat_meta's second field is the file's byte size ($meta_want_size)"
else
  fail "p_stat_meta's second field is the file's byte size — want '$meta_want_size', got '${meta_fields[1]:-}' from '$meta'"
fi
if [[ "${meta_fields[2]:-}" =~ ^[0-9]+$ ]]; then
  pass "p_stat_meta's third field is a numeric mtime (${meta_fields[2]})"
else
  fail "p_stat_meta's third field is a numeric mtime — got '${meta_fields[2]:-}' from '$meta'"
fi

# p_realdir: independent (cd + pwd -P, not readlink -f) directory canonicalisation.
mkdir -p "$TMP/dirA" "$TMP/dirB"
rA="$(p_realdir "$TMP/dirA")"; rA2="$(p_realdir "$TMP/dirA")"
[[ -n "$rA" && "$rA" == "$rA2" ]] \
  && pass "p_realdir is non-empty and stable" \
  || fail "p_realdir is non-empty and stable (got '$rA' then '$rA2')"

rB="$(p_realdir "$TMP/dirB")"
[[ -n "$rB" && "$rA" != "$rB" ]] \
  && pass "p_realdir distinguishes different directories" \
  || fail "p_realdir distinguishes different directories (rA='$rA' rB='$rB')"

# A trailing-slash / './' form of the SAME directory must canonicalise identically.
rA3="$(p_realdir "$TMP/dirA/./")"
[[ "$rA3" == "$rA" ]] \
  && pass "p_realdir normalises ./ and a trailing slash to the same answer" \
  || fail "p_realdir normalises ./ and a trailing slash to the same answer (got '$rA3', want '$rA')"

# p_timeout: the BOUND the falsify tier was missing, so a damage that makes a
# call non-terminating fails an assertion BY NAME instead of expiring run.sh's
# per-mutant clock with nothing observed (backlog F22). Three properties, each
# separately breakable:
#
#   1. a command that finishes in time yields ITS OWN status, not the bound's
#   2. a command that does not finish yields 124 rather than hanging forever
#   3. the bounded command is actually DEAD afterwards -- a bound that returns
#      124 and leaves the process spinning would poison every test after it,
#      and both oracles this was written for spin at 100% CPU when damaged
#
# Property 1 carries the mutation coverage: inverting either the liveness probe
# (`while kill -0 …`) or the deadline comparison (`-ge`) makes p_timeout report
# 124 for a command that completed, and that status is what this reads.
p_timeout 3 bash -c 'exit 7'; to_rc=$?
if [[ "$to_rc" -eq 7 ]]; then
  pass "p_timeout returns the command's own exit status when it finishes in time"
else
  fail "p_timeout returns the command's own exit status when it finishes in time -- want 7, got $to_rc"
fi

to_out="$(p_timeout 3 bash -c 'printf ok')"
if [[ "$to_out" == "ok" ]]; then
  pass "p_timeout passes the bounded command's stdout through"
else
  fail "p_timeout passes the bounded command's stdout through -- want 'ok', got '$to_out'"
fi

# Property 2, and with it the only honest form of property 3. The first draft
# of this block checked that the bounded command was no longer alive after
# p_timeout returned -- a check that CANNOT FAIL, because p_timeout ends with
# `wait "$cmd_pid"`, which by definition does not return until the child is
# dead. It passed against a damage that removed the kill outright.
#
# What is actually falsifiable is that the bound CUTS THE COMMAND SHORT: bound a
# 30-second sleep at 1 second and require both the 124 and an elapsed time
# nowhere near 30. Remove the kills and the status stays 124 (the watchdog still
# marks the flag) while `wait` sits out the full thirty seconds -- so the status
# alone would call that a working bound, and only the clock catches it.
to_t0=$SECONDS
p_timeout 1 bash -c 'sleep 30'
to_slow_rc=$?
to_elapsed=$(( SECONDS - to_t0 ))
if [[ "$to_slow_rc" -eq 124 ]]; then
  pass "p_timeout returns 124 when the clock expires"
else
  fail "p_timeout returns 124 when the clock expires -- got $to_slow_rc"
fi
if [[ "$to_elapsed" -lt 10 ]]; then
  pass "p_timeout cuts the command short rather than outliving it (${to_elapsed}s for a 30s command bounded at 1s)"
else
  fail "p_timeout cuts the command short rather than outliving it -- a 30s command bounded at 1s took ${to_elapsed}s, so nothing was actually killed"
fi

# No helper may leave the caller with an empty answer on THIS platform: an empty
# string compares equal to another empty string, which is how a portability bug
# turns into a test that passes by accident.
for h in p_stat_mode p_sha1 p_md5 p_stat_meta; do
  if [[ -n "$($h "$TMP/f")" ]]; then pass "$h is non-empty on this platform"
  else
    # ON THE FAIL: LINE ITSELF. The diagnosis used to sit on indented lines
    # UNDERNEATH this one, and it has now been lost three times running:
    #
    #   2026-08-21  mgd-ai-containers PR #76, run 32523718531   p_md5 + p_stat_meta
    #   2026-08-23  ai-containers main, run 32635611521         three helpers
    #   2026-08-26  ai-containers PR #134, run 32980406406      all four
    #
    # The first loss was diagnosed as the wrong STREAM and fixed by moving the
    # diag from stderr to stdout. It went missing again anyway. The third time
    # supplies the fact that settles it: all four FAIL: lines reached the log and
    # NOT ONE continuation line did — so whatever drops them, the FAIL: line is
    # the transport that demonstrably survives. The harness is not the culprit;
    # feeding its own extraction awk a synthetic FAIL:-plus-indented-diag block
    # keeps the diag lines correctly.
    #
    # So stop relying on a second line arriving. A diagnostic that needs its
    # explanation to travel separately is one transport away from being no
    # diagnostic at all, and this repo has now paid that three times.
    # THE DIRECTORY AS WELL AS THE FILE, because they are different findings and
    # the first real firing of this diagnostic could not tell them apart. On
    # 2026-08-27 it reported `exists=n` — the fixture was GONE, which nobody knew
    # across the three prior occurrences (2026-08-21, 08-23, 08-26) because the
    # explanation never reached the log. That is a fact, and it is where the
    # trail stops: not reproducible standalone, not reproducible over repeated
    # full-suite runs, no glob `rm` anywhere in tests/, run-all.sh runs nothing
    # in parallel, and bash does not fire an EXIT trap inside a `( )` subshell
    # (measured, not assumed).
    #
    # Two candidates remain and one field separates them:
    #   dir=n   something removed the whole scratch directory — a trap that fired
    #           early, or a cleanup that reached too far
    #   dir=y   something removed this file specifically, or it was never written
    # `left=` is the tie-breaker for dir=y: an otherwise-populated directory
    # means targeted removal, an empty one means the whole fixture step lost.
    fail "$h returned empty — comparisons using it would pass vacuously [fixture=$TMP/f dir=$([[ -d "$TMP" ]] && printf y || printf n) exists=$([[ -e "$TMP/f" ]] && printf y || printf n) size=$(wc -c <"$TMP/f" 2>/dev/null | tr -d ' ' || printf '?') left=$(ls -A "$TMP" 2>/dev/null | wc -l | tr -d ' ') | $h stderr: $( $h "$TMP/f" 2>&1 >/dev/null | head -1 | tr -d '\n' )]"
    # WHY it was empty, because the last time this fired nobody could tell.
    # CI, 2026-08-21 (mgd-ai-containers PR #76, run 32523718531): p_md5 AND
    # p_stat_meta both returned empty in ONE control run, while the same run
    # measured the corpus normally — a pristine oracle going red under the
    # tier's own load (backlog F30/F32). The report named the symptom and
    # nothing else, and the helpers are why: p_md5 and p_sha1 are PIPELINES
    # (`md5sum … | cut`), so a failing md5sum still leaves `cut` succeeding with
    # empty output, and p_stat_meta's error goes to stderr with stdout empty.
    # Both hide the cause. Two facts separate the candidates — did the file
    # vanish, or did the tool fail on a file that is right there?
    # ON STDOUT, the same stream as fail(), and that is not a detail. The
    # falsify harness captures an oracle with `> "$out" 2>&1` and then keeps a
    # FAIL: line plus the indented lines IMMEDIATELY FOLLOWING it. stdout to a
    # file is block-buffered and stderr is not, so a diagnostic written to
    # stderr is flushed out of order and stops being adjacent to the FAIL: it
    # explains — at which point the harness drops it.
    #
    # Measured: CI run 32635611521 (2026-08-23, ai-containers main) reported
    # exactly three `FAIL: … returned empty` lines from this loop and NOT ONE
    # diag line, so the second recurrence of F30/F32 arrived as unexplained as
    # the first — with the explanation sitting in the same file, written for
    # this exact purpose, on the wrong stream.
  fi
done

# ── the diagnosis must live ON the FAIL: line ────────────────────────────────
# Asserted on this file's own text, because the property is invisible from
# inside a passing run: the diagnosis only appears when a helper returns empty,
# and by then the reporter has already decided what it could keep.
#
# The predecessor of this check asserted the diag lines went to stdout rather
# than stderr. They did, and they were lost anyway — twice more. The property
# worth pinning is not which STREAM the explanation uses but whether it needs a
# SECOND LINE to arrive at all: the FAIL: line is the one transport observed
# surviving every recurrence.
#
# Anchored to the `fail "$h returned empty` statement, so the check reads the
# code rather than this comment.
#
# "the failure line itself", NOT "the FAIL: line", and that is not a style
# choice: a whitespace-prefixed `FAIL:` inside a pass/fail STRING makes the
# falsify harness read this oracle as red on the pristine tree and skip the
# whole target. tests/test-falsify-targets.sh guards it, having been written
# after the previous wording of this very block cost 13 unmeasured mutants on
# 2026-08-23. Rewriting this sentence naturally reintroduces the bug.
if grep -qE '^[[:space:]]*fail "\$h returned empty.*fixture=' "$0"; then
  pass "the empty-helper diagnosis travels on the failure line itself, needing no continuation to survive"
else
  fail "the empty-helper diagnosis travels on the failure line itself — it has moved back onto a continuation line, the transport that lost it three times (2026-08-21, 2026-08-23, 2026-08-26)"
fi

# ── the fixture's EXIT trap is confined to its owner (F30/F32/F64) ───────────
# The mechanism, reproduced 2026-08-30 (see the trap's own comment at the top of
# this file): p_timeout forks the command it times and a watchdog beside it, and
# a forked child can end up running this script's EXIT trap — deleting the
# fixture the script is still using. Five sightings; the four p_* helpers then
# return empty and report four symptoms of that one fact.
#
# ASSERTED ON THE MECHANISM, NOT THE RACE. Whether a child fires the trap is
# load-dependent — that is why it took five sightings and 276 controls to catch
# once, and a test that tried to race it would pass by luck. What is
# deterministic is whether the trap, WHEN it runs in a child, can destroy the
# fixture. So run the trap's own action in a forked child and look.
pt_action="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
if [[ -z "$pt_action" ]]; then
  fail "the fixture's EXIT trap action could be read back (nothing to test otherwise)"
else
  ( eval "$pt_action" )   # a real forked child, running exactly what the trap runs
  if [[ -d "$TMP" && -f "$TMP/f" ]]; then
    pass "the EXIT trap's action, run in a forked child, leaves the fixture alone"
  else
    fail "the EXIT trap's action, run in a forked child, destroyed the fixture — dir=$([[ -d "$TMP" ]] && printf y || printf n) file=$([[ -f "$TMP/f" ]] && printf y || printf n)"
  fi
fi
# And the guard must not be inert. A condition that never holds would confine the
# removal to nobody, trading a destroyed fixture for one leaked on every run —
# which is the defect the trap exists to prevent, and which four tests shipped
# (v0.9.2) before run-all.sh grew a leak counter.
if [[ "$BASHPID" == "$TMP_OWNER" ]]; then
  pass "the guard's condition holds in the owning process, so the fixture is still cleaned up"
else
  fail "the guard's condition holds in the owning process (BASHPID=$BASHPID TMP_OWNER=$TMP_OWNER)"
fi

# ── SOURCING THIS FILE MUST NOT WRITE ANYTHING, ANYWHERE ─────────────────────
# The _P_PTY_GNU probe runs `script`, and `script`'s DEFAULT is to create a file
# called `typescript` in the current directory. The first version passed
# `--version`, which BSD getopt consumes as the end-of-options marker -- leaving
# BSD script with no file and no command, so it would have written that file
# into whatever directory a test happened to be in, the repo root included.
#
# Asserted from a scratch cwd rather than reasoned about, and asserted on the
# DIRECTORY rather than on the probe's arguments: an argv check would have to be
# rewritten every time the probe is, and would not have caught this at all.
# Linux cannot exercise the BSD arm, but it CAN prove the invocation is bounded,
# which is the half that generalises.
pty_cwd="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d (pty cwd)\n'; exit 1; }
# THE SOURCE MUST BE OBSERVED HAPPENING. The first version of this block named a
# variable ($TESTS_DIR) that does not exist in this file: `. ""` failed
# silently, `ls -A .` saw an empty directory, and the assertion passed against a
# probe deliberately rewritten to write `typescript`. An assertion whose subject
# never ran reports the absence of its own effect. The marker makes the source
# prove itself before anything is concluded from the directory.
pty_probe_out="$( cd "$pty_cwd" && bash -c '. "$1" >/dev/null 2>&1 && printf SOURCED; printf "|"; ls -A .' _ "$REPO_DIR/tests/portability.sh" )"
if [[ "$pty_probe_out" == SOURCED\|* ]]; then
  pass "scaffold: portability.sh was actually sourced in the probe cwd"
else
  fail "scaffold: portability.sh was actually sourced in the probe cwd — the assertion below would be vacuous (got '$pty_probe_out')"
fi
pty_left="${pty_probe_out#*|}"
[[ -z "$pty_left" ]] \
  && pass "sourcing portability.sh creates no file in the current directory" \
  || fail "sourcing portability.sh creates no file in the current directory — left: $(printf '%s' "$pty_left" | tr '\n' ' ')"
rm -rf "$pty_cwd"

# ── p_pty: a real tty on stdin, and the child's status ────────────────────────
# ASSERTED BY EFFECT. Both mutants that can damage this helper — the util-linux
# probe, and the arm test that reads it — select the WRONG `script` syntax, and
# either wrong choice makes the call fail outright: GNU takes the command as ONE
# STRING, BSD as argv. So RUNNING it is the assertion. Nothing here reads
# _P_PTY_GNU, which would assert the configuration instead of the behaviour, and
# would still pass with both arms broken.
#
# Measured with the arm inverted: the transcript comes back EMPTY and the status
# is 1 instead of 7 — so both assertions below flip, which is what makes them
# worth having rather than decorative.
#
# The status assertion is not a duplicate of the tty one. `p_pty` exists to
# drive repo.sh's consent prompts, where the whole question is whether an
# aborted destructive command reports failure; a helper that produced a tty but
# swallowed the status would pass the first check and be useless for its only
# caller.
if ! command -v script >/dev/null 2>&1; then
  printf 'SKIP: no script(1) on this host, so p_pty cannot be exercised\n'
else
  # Substring, not equality: BSD `script` prefixes the transcript with ^D.
  pty_out="$(p_pty bash -c '[[ -t 0 ]] && printf TTY' </dev/null 2>/dev/null | tr -d '\r\n')"
  if [[ "$pty_out" == *TTY* ]]; then
    pass "p_pty gives the child a real tty on stdin"
  else
    fail "p_pty gives the child a real tty on stdin (got '$pty_out')"
  fi
  p_pty bash -c 'exit 7' </dev/null >/dev/null 2>&1
  pty_rc=$?
  if [[ "$pty_rc" == "7" ]]; then
    pass "p_pty propagates the child's exit status"
  else
    fail "p_pty propagates the child's exit status (expected 7, got $pty_rc)"
  fi
fi

# ── …and the arm THIS machine does not run ───────────────────────────────────
# The two assertions above run whichever arm the probe selects, which is the
# right way to check that p_pty WORKS and is enough to kill every mutant the
# tier can generate here: any wrong choice picks the wrong `script` syntax and
# the call fails outright. Measured — with the arm inverted the transcript comes
# back empty and the status is 1 instead of 7.
#
# What they cannot see is the OTHER arm's contents. Every CI job in
# hermetic-checks.yml is ubuntu-24.04, and the floor container is ubuntu:22.04,
# so on this project's CI the BSD arm is never executed by anything: a typo in
# it — `-Q` for `-q`, the file and the command transposed — ships green forever
# and surfaces only on a developer's Mac. Measured both ways: the effect
# assertions above MISS both of those, and the argv assertions below catch them.
#
# This is the F23 shape from the other side. There the probe was inverted and no
# test could see it; here the probe is fine and the unexecuted arm is unchecked.
# Asserting argv is asserting configuration, which is normally the weaker thing
# to do — it is justified only because for this one arm there is no behaviour to
# observe on any machine that runs this suite.
PTY_BIN="$TMP/ptybin"; mkdir -p "$PTY_BIN"
export SCRIPT_ARGV_LOG="$TMP/script-argv.txt"
cat > "$PTY_BIN/script" <<'PTYFAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SCRIPT_ARGV_LOG"
exit 0
PTYFAKE
chmod +x "$PTY_BIN/script"

pty_argv() {   # <forced _P_PTY_GNU> [cmd…] → the argv p_pty handed to `script`
  local flag="$1"; shift
  : > "$SCRIPT_ARGV_LOG"
  ( PATH="$PTY_BIN:$PATH"; _P_PTY_GNU="$flag"; p_pty "$@" ) >/dev/null 2>&1
  cat "$SCRIPT_ARGV_LOG"
}
gnu_argv="$(pty_argv 1 bash -c 'echo hi')"
bsd_argv="$(pty_argv 0 bash -c 'echo hi')"

case "$gnu_argv" in
  "-qec "*" /dev/null") pass "p_pty's GNU arm: script -qec <one string> /dev/null" ;;
  *) fail "p_pty's GNU arm: script -qec <one string> /dev/null (got '$gnu_argv')" ;;
esac
# The one that matters on this platform: nothing else here ever runs it.
case "$bsd_argv" in
  "-q /dev/null bash -c echo hi") pass "p_pty's BSD arm: script -q /dev/null <argv…> — unexecuted here, so unobservable otherwise" ;;
  *) fail "p_pty's BSD arm: script -q /dev/null <argv…> (got '$bsd_argv')" ;;
esac
# A branch that collapsed to one arm satisfies whichever case above matches it,
# and only this comparison sees that.
if [[ "$gnu_argv" != "$bsd_argv" ]]; then
  pass "  … and the two differ, so the branch is a real branch"
else
  fail "  … and the two differ — both arms issued '$gnu_argv', the branch is dead"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
