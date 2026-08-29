# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

## v0.9.3 — 2026-08-29

**A patch, and every entry is again a repair.** No new `sandbox.conf` key, no new
column, nothing a consumer has to adopt.

**Where v0.9.2 was about tests that could not fail, this release is about tools
and gates that reported something other than what they measured.** Read as a
set, the six entries are one failure mode seen six ways: a `--help` that
documented less than its script implemented; a capability probe that answered
yes on the very platform it existed to protect; a collapse that had *also*
asserted, reported as the environment rather than as the failure it was; a
timeout that only ever measured the machine it ran on; a label naming a flag
that does not exist; and five defects an adversarial review found in v0.9.2's
own new code.

**The sharpest is the capability probe, because of where it came from.**
`tests/test-run-all-shim.sh` was added in v0.9.2 to close that release's largest
coverage gap — the `mktemp` shim injected on `PATH` for every test in the suite,
which nothing asserted. It gated its GNU long-option assertions on
`mktemp --tmpdir -u` exiting 0. BSD exits 0 there too, treating `--` as the
end-of-options marker, so on macOS the probe reported GNU support and four
`--suffix` assertions ran against an option BSD does not have. Green on Linux,
red on a Mac. The gate written to make the file portable is precisely what made
it fail on the other platform, and it asked a question where this repo's own
rule is to measure an effect. It now probes by effect.

**Two of the six were reachable only by running on a Mac, and five only by
reviewing the previous release's fixes.** That is the same pattern v0.9.2
recorded and the reason both layers exist: CI is ubuntu-only and cannot see the
BSD class by construction, and no gate reviews the code that was written to
satisfy it.

**One entry is a correction to the correction.** The adversarial review found
that v0.9.2's failure-report fix — added so a failing case could say *why* —
still dropped the one line explaining a dead container, because `assert_runs`
captured the tool's stderr but not the docker CLI's. The fix whose entire
purpose was legibility was itself illegible in the case that motivated it.

### `--help` truncated at a line number, and four record types sat below the cut

`fr_usage` was `sed -n '2,60p'`. The header block it prints has grown to 157
lines, so `--help` ended **mid-sentence** — on *"They are one invocation, not
several: a"* — and everything past the cut was invisible to a caller.

What was past the cut mattered. The block is headed **"the output format (parse
THIS, not stderr)"**, and `CONTROL`, `CONTROLS`, `SKIPPED` and `UNATTEMPTED` were
all being emitted and none of the four was listed. `check-ledger.sh`,
`verify-on-host.sh` and the tests parse those records positionally, so this is a
stated contract that had drifted, not a formatting nicety. `SKIPPED`'s `<reason>`
field is documented with all three of its values, because
`no-test-matched` / `baseline-scaffold` / `baseline-not-green` send a reader to
three different places.

`FALSIFY_BASELINE_ATTEMPTS` is documented too — an environment-only knob with no
flag, previously discoverable only by reading the source.

**The cut is now a marker, not a number.** A line number cannot notice it has
gone stale; a marker moves with the text it delimits.

**And the drift is now guarded, by derivation rather than by a second list.**
A hand-maintained list of expected record types would be a third thing to keep
in sync and would drift exactly as the other two did. The check reads what the
runner *prints* — every `printf 'X|'` in the source — and requires `--help` to
mention it, so a new record type fails on the commit that introduces it. It also
pins both edges: the help must reach the end of the usage block, and must stop
at the marker rather than dumping the design notes. Demonstrated against the
unfixed runner: it reports the mid-sentence last line verbatim and names all four
missing types.

### A capability probe that said yes on the platform it was protecting

`tests/test-run-all-shim.sh` gates its GNU long-option assertions on
`/usr/bin/mktemp --tmpdir -u` exiting 0. **BSD exits 0 there** — it treats `--`
as the end-of-options marker, shrugs, and prints an ordinary path — so on a stock
macOS the probe reports "GNU long options supported" and four `--suffix`
assertions then run against an option BSD does not have. Measured 2026-08-29:
both failed with `mktemp: unrecognized option` in Phase 5 on this host while the
whole file passed on Linux. That is this repo's most-repeated defect shape, this
time wearing a capability probe.

Probed by EFFECT now: `--tmpdir=DIR` must actually place the path in `DIR`, and
`--suffix` must be accepted. BSD satisfies neither, GNU both, and nothing in
between is read as a yes.

### A collapse that also asserted was reported as the environment

`FALSIFY_SIGNAL` is built **additively** — `falsify_verdict` appends `failline`
and then appends `scaffold` on top of it — so `exit+failline+scaffold` is an
ordinary value rather than a contradiction. The baseline retry added in v0.9.2
tested for `scaffold` alone at all three of its sites, which reads a run that
**did** observe an assertion failing as one that observed nothing.

It bites on the oracle **sets**. `tests/lib-verify-repo.sh` names three tests run
as one `run-all.sh` invocation into one log. Let one member go genuinely red
while another's `mktemp -d` collapses, and both markers land together: the
baseline is then re-run `FALSIFY_BASELINE_ATTEMPTS` times against a 360-second
clock, the target is skipped as `baseline-scaffold`, and the run reports "that is
the ENVIRONMENT rather than the oracle" directly above the excerpt showing the
assertion that failed. The reader is sent at the machine while the tree is
broken. Demonstrated against the pre-fix runner: the retry counter reads 3.

This is the rule `falsify_verdict` already applies one channel over, in its own
words — *"A FAIL: line printed before the signal still wins"*. The scaffold
channel was the one place it was not applied. `fr_scaffold_only` now states it
once and all three sites use it.

Checked in the other direction rather than assumed: every real test in the suite
`exit`s immediately after printing `SCAFFOLD-FAILED:`, so a genuine collapse
carries no `^FAIL:` line and is still retried. The only files emitting both are
two fixtures whose baselines are green by construction.

### A one-second clock that only ever measured the machine

Three `--max-unproven-pct` cases ran the slow fixture at `--timeout 1`. The
mutant `sleep 300`s, so any clock from about 2 to 250 trips it equally — the one
second was doing nothing for the case and leaving the **baseline** no headroom.
On a loaded macOS host it went over, which times out the baseline, skips the
target, and fails the run for a reason having nothing to do with the budget
under test. Measured 2026-08-29: `control: a run AT the budget passes` reported
rc=1 in Phase 5 while the same assertion passed 205/205 in the bash-floor
container minutes later on the same commit. Raised to 5s — 5× the headroom for a
fixture that needs none, still 60× below the sleep it must catch.

### An assertion label naming a flag that does not exist

`--baseline-attempts` is not a flag; the knob is the environment variable
`FALSIFY_BASELINE_ATTEMPTS`. The label now names what a reader can actually set.

### What an adversarial review of v0.9.2 found

Five defects, all in the release's own new code, plus the first assertion the
`mktemp` shim has ever had.

- **The failure report still lost the one line explaining a dead container.**
  `assert_runs` captured `docker exec`'s output with the `2>&1` *inside* the
  container's `bash -c`, which merges the tool's stderr but not the docker
  CLI's. Against a removed container `out` came back empty, the dump printed a
  bare `error:` label, and the daemon's `Error response from daemon: …` escaped
  **unindented** — where the report's context rule drops it and `it_diagnose`'s
  dump has already pushed it out of the tail window. Fixed at the source with a
  second, outer redirect, so the message lands on the `error:` line rather than
  needing the runner to learn docker-specific text.
- **The ownership reclaim shared the image removal's gate.** `it_reclaim_scratch`
  sat inside `[[ $v != default && $reuse_image -eq 0 && $keep -eq 0 ]]` — but
  whether an image was *reused*, or the user asked to *keep* it, says nothing
  about whether a case left root-owned files behind. Two live consequences:
  under `--reuse-image` the reclaim never ran with the variant's image, so the
  sweep fell back to `$IT_IMAGE` — the default tag a `--variant agents` run
  never builds, and `docker run` on a missing tag reaches for the **registry**,
  from inside the `EXIT` trap (nightly's `packages-agents` job is that shape
  exactly); under `--keep` nothing was reclaimed at all, leaving the kept
  scratch root-owned and needing `sudo`. The reclaim is now unconditional and
  only the `docker rmi` stays gated, and the container runs `--pull=never` so a
  missing image fails locally instead of fetching one to run as root over a
  host bind mount.
- **The resource registry leaked any path containing a space.** `it_track`
  joined with spaces and `it_cleanup` iterated `for r in $_it_resources`
  unquoted, so a tracked path was split into fragments matching no
  `container:`/`dir:` prefix and silently survived — reproduced with
  `TMPDIR="/tmp/sp ace"`. Newline-delimited now, read back with
  `IFS= read -r`. The quoted trap this registry replaced did not have the hole,
  so it was a regression introduced by the cure.
- **The `mktemp` shim turned `--tmpdir` into an error.** `--tmpdir` and
  `--tmpdir=DIR` fell into the generic `-*` arm, so the shim appended an
  absolute template and GNU refused it outright. They are the caller naming a
  directory, exactly like `-p`.
- **A comment claimed both `safe.directory` lines were needed.** `*` subsumes
  `/w`; the `/w` entry is kept for what it documents, not because anything
  depends on it.

`tests/test-run-all-shim.sh` is new, and closes the review's largest structural
gap: the shim is injected on `PATH` for **every** test in the suite, and
`run-all.sh` cannot be covered by the falsify tier (`targets.conf` excludes it as
the measuring instrument), so the most widely-executed new code in the release
had no assertion at all. It extracts the shim from `run-all.sh`'s heredoc rather
than copying it, so a change to the shim is a change to what is tested.

Adding the dead-container assertion also made
`tests/test-falsify-historical.sh`'s hole-#4 reconstruction unfaithful: that
pair reverts the *one* line asserting the error value and requires the defective
copy not to notice, and the new assertion reads the same value. The
reconstruction now neutralises both, so it once again models a file where
nothing asserts that value. The ship-gate scorecard is unchanged at 2 of 3 —
correctly, because the generator still has no value-damage operator; what
changed is the test file's coverage, not the tier's power.

## v0.9.2 — 2026-08-29

**A patch, and every entry is again a repair.** No new key, no new column,
nothing to adopt.

**The whole release came out of running the suite on real hosts.** Two full
`verify-on-host` runs — one macOS, one Linux — each turned up defects that CI
cannot reach by construction, and a comprehensive review of those fixes found
five more. The pattern across all of them is one thing: **a test that could not
fail, or could fail for the wrong reason.**

**The sharpest was an assertion that passed on the value of HEAD.** A schema
check grepped the whole `--version` report for `77`, and that report's first line
is the engine version — so it passed whenever the short git sha happened to
contain those two digits, whatever the schema field said. CI killed that mutant
at one commit and reported it SURVIVED at the next, with nothing in between but
a merge. The ledger caught it by refusing an unclassified survivor; nobody
noticed it by reading.

**Four fixes concern scratch state**, which turned out to be one thread pulled
end to end: four tests leaking a temp directory on every *passing* run, a sweep
that could not remove what its own cases left behind, a suite that did not
contain its own temp, and — after the containment landed — the realisation that
it had removed the only signal by which such leaks were ever found. That signal
is now a report rather than debris, and it earned itself immediately: on its
first run in the downstream repo it named a duplicated scaffold block that had
been orphaning a directory per run, invisible upstream because only the other
repo's directory layout exposed it.

**Two defects were introduced by fixes in this same release and caught by the
gates within minutes** — an apostrophe closing a single-quoted awk program, and
a comment line beginning with the word shellcheck being read as a directive.
Both are recorded at the site rather than quietly corrected.

Verified end to end on a host before tagging: Phase 4 36/36, Phase 5 71/71
across all three arms, Phase 6 **548/548 verdicts with zero unproven and zero
timeouts**, Phase 7 clean over 161 scripts.

### An assertion that passed on the value of HEAD

- **`grep -q '77'` searched the whole `--version` report**, and that report
  contains the engine version. So the schema assertion passed whenever the short
  git sha happened to contain those two digits — whatever the schema field
  actually said.
- Found by CI going red on `main` with a survivor that had been killed **at the
  previous commit and nothing in between but a merge**:
  `version.sh:cond-negate:c26ba37…`, the `[[ -f "$conf" ]]` guard in
  `version_schema`. Negate it and the report reads `schema unknown`; the
  assertion still passed at commit `9a3f774`, because of the `77` inside `f774`.
- **A mutant whose verdict depends on the commit hash** is the sharpest form of
  the thing this tier exists to find, and the ledger caught it by refusing an
  unclassified survivor rather than by anyone noticing.
- Both assertions are now anchored to their own line and field. The mutant is
  killed: `version.sh` goes 27/3 → **29/1**, and the one survivor left is the
  entry the ledger already holds.
- Nothing was added to `survivors.txt`. A gap that can be closed by making the
  assertion say what it meant is not a gap to classify.

### What a review of the last five fixes found

An Opus review of the five host-found repairs returned PASS WITH
RECOMMENDATIONS and eleven findings. None was a correctness bug in shipped
behaviour; five were worth fixing before tagging, and all five are shapes this
repo purges elsewhere.

- **The leak fix leaked.** `run-all.sh` created its per-test log, then its
  scratch root, then one trap covering both — so a failing `mktemp -d` exited
  between them and orphaned the log. Demonstrated with a stub `mktemp` that
  fails only on `-d`: HEAD leaves `run-all-log.XXXXXX` behind, the fix leaves
  nothing. The log now lives *inside* the scratch root, needing no `mktemp` and
  no second trap, so the window cannot reopen.
- **Containment was applied to the test of the falsify runner, not the runner.**
  `tests/falsify/run.sh` still handed its oracle the developer's `TMPDIR`, and
  the watchdog ends that oracle with `kill -KILL`, which no `EXIT` trap
  survives. Rooted in `$FR_SCRATCH` now, so the run's own cleanup is the
  backstop the kill removed.
- **Three assertions were red for the wrong reason.** They grepped the *whole*
  runner output rather than the extract, and were failing pre-fix only because
  filler pushed the context past `tail -40`. They now assert against the
  extract, and the marker is matched without its line count — hardcoding
  `last 40 lines` meant changing the tail would silently make the extract the
  entire output and every check below it vacuous.
- **A comment named a guard that has never existed** (`tests/test-temp-leaks.sh`,
  zero commits in any branch) — and the containment fix had removed the only
  signal by which those leaks were originally found. `run-all.sh` now counts
  what each test leaves in its own `TMPDIR` and prints `left in TMPDIR:` after
  the totals. It **reports and never judges**: every falsify oracle is
  `run-all.sh <name>`, so failing a test for untidiness would manufacture a
  false KILL.
- **The failure-context window ended at the first unindented line** — which is
  exactly what `docker exec` prints against a dead container, landing between
  the `FAIL:` and the `error:` line and dropping the reason. `CONTEXT_MAX` was
  already the real bound; the reset only cost information.

Three claims that were overstated are now corrected rather than removed: the
generated `mktemp` shim escapes `bash -n` and the shellcheck pass exactly as a
tracked unsuffixed file would (only the dialect linter still sees it); the
symlinked-`TMPDIR` arm is no longer inert on macOS, so the comment saying it is
described a mechanism that no longer exists; and the `SKIP:` line in
`test-integration-runner.sh` is *not* visible in the CI arm where it fires.

Two defects were introduced while writing these fixes and caught by the gates
within minutes: an apostrophe in an awk comment closed the single-quoted program
(six assertions red at once), and a comment line beginning with the word
`shellcheck` was parsed as a directive (`SC1072`/`SC1073`). Both are recorded at
the site.

### A failing assertion reached the report; the reason attached to it did not

The integration runner's failure report extracted assertion lines with
`grep -E '^(PASS|FAIL|SKIP):'`, which by construction cannot carry the context
a helper prints *under* its `FAIL:` — that context is indented, so it does not
start with the keyword, and every line of it was dropped. `lib.sh`'s
`assert_runs` is the case in point: beneath its "X is present but FAILED TO
RUN" it prints `path:`, `shebang:` and `error:`, which is the entire record of
why a binary that resolves on `PATH` would not execute.

Measured on the 2026-08-29 nightly. `700-agent-tools-install-restricted` failed
with **"codex is present but FAILED TO RUN"** and the artifact contained none of
the three, so the run named what broke and could not say why. The `tail -40`
below the extract did not stand in for them either: by that point the log's last
lines are `it_diagnose`'s ipset/capture dump. That is the *same* truncation this
block already existed to correct, one level further in — the assertion was
rescued, the reason attached to it was not.

The extract now carries an indented, non-blank run directly beneath a `FAIL:`,
capped at 8 lines per failure. Unbounded would pull a case's whole trailing dump
into the extract and recreate the defect from the other side; real helpers print
a handful of labelled lines, so the cap is generous for every current caller and
still refuses a runaway.

The test that guards it is deliberately awkward: its synthetic case prints 60
lines of trailing noise after the context. With a short log the `tail -40` alone
would surface those lines and the assertion would pass against the unfixed
runner — the filler is what puts the context out of the tail's reach, so only
the extract can carry it.

This does not explain the codex failure itself, which is not reproducible on a
Linux host — the same case passes there. It makes the next occurrence legible.

### The suite now contains its own temp, and the macOS TMPDIR arm finally reaches it

Two problems, one mechanism, and they turned out to be the same problem seen
from opposite ends.

**Leaks.** The four fixed in the previous entry were found by hand, and only two
of them were reviewable in principle — a `trap … EXIT` silently replaced by a
later one leaves no trace at the call site, and in one case the replacing trap
was in a different file entirely. The fifth would arrive the same way.

**The symlinked-`TMPDIR` arm.** `verify-on-host.sh` Phase 5 and CI's
`suite-symlinked-tmp` job re-run the suite with `TMPDIR` pointed at a **symlink**
to catch the macOS path-shape class (`/var/folders` vs `/private/var/folders`)
that has cost this repo 22 assertions across two increments. On Linux it works.
On a Mac it largely did not: a bare `mktemp` honours `$TMPDIR` on GNU and
**ignores** it on BSD, where the per-user directory comes from `confstr` and no
environment variable reaches it. Measured 2026-08-29 by instrumenting every
call: of 60 tests, **zero** honoured a symlinked `TMPDIR` fully, **53 ignored it
entirely**, and **622 of 834 calls escaped** to `/var/folders`. The arm that
exists *because CI is not a Mac* was, on a Mac, mostly a second ordinary run.

`run-all.sh` now gives each test its own `TMPDIR` under one scratch root it
removes at exit, and generates a `mktemp` shim on `PATH` that supplies an
explicit `$TMPDIR`-rooted template when the caller gives none — so BSD and GNU
agree, the per-test directory is genuinely reached, and what a test forgets goes
with the run either way.

**It contains; it does not judge.** Nothing here fails a test for leaking. Every
falsify oracle is `tests/run-all.sh <name>`, so a test turned red by its own
untidiness would score as the mutation being noticed — a false `KILL`, which is
exactly what the survivor ledger exists to prevent.

**The shim is generated, not committed**, because a tracked file named `mktemp`
has no `.sh` suffix and every gate here discovers scripts by that suffix
(`git ls-files '*.sh'`) — it would have escaped `bash -n`, the dialect linter and
shellcheck alike.

**And the arm immediately earned itself.** Handing tests a real `TMPDIR` on macOS
broke ten assertions in `test-extract-discovery.sh` and one in
`test-integration-shim.sh` — because **macOS exports `TMPDIR` with a trailing
slash**, so `"${TMPDIR}/x"` yields `//x`. `extract-discovery.sh` canonicalises
the path it prints while the assertion holds the raw value, and the two compare
unequal. That is precisely the path-shape class the arm was built for, invisible
until tests actually received a `TMPDIR`. Stripped once in `run-all.sh`, so every
path it hands out is already clean.

### Four tests left a temp directory behind on every PASSING run

A macOS host had accumulated **447 stale entries in the user temp directory**,
90 MB, and 281 of them carried one signature. None came from a failure: a clean,
71/71 suite run leaked on its own. Four causes, deliberately listed apart
because only the first two share a mechanism and none share a fix.

**`tests/test-mutations.sh`** installed `trap 'rm -rf "$stale_root"' EXIT` at
line 57 and then `trap 'rm -rf "$tmp"' EXIT` at line 256. Bash keeps exactly ONE
EXIT handler, so the second DISCARDED the first and `$stale_root` was never
removed. This file is also the oracle for the `tests/integration/mutate.sh`
falsify target, so one corpus run invoked it ~63 times and left ~63 directories.

**`tests/test-integration-lib.sh`** lost its handler the same way, but to
ANOTHER FILE: `. "$LIB"` at line 60 sources `tests/integration/lib.sh`, whose
top level runs `trap 'it_cleanup' EXIT`. `it_cleanup` removes every resource
`it_track` was given and knew nothing of this file's `$TMP`. The cure is that
registry — `it_track "dir:$TMP"` — rather than a combined trap, so one handler
owns all teardown and nothing rots the day `lib.sh` renames its own.

**`tests/test-db-clients.sh`** removed `"$F2"` where it meant `"$F4"`. `$F2` was
already gone forty lines above, so the removal was a no-op. That file also had
no trap at all, so an interrupted run left all six of its fixtures; it has one
now, backstopping the inline removals rather than replacing them.

**`tests/test-falsify-run.sh` was not a cleanup defect**, and treating it as one
would have fixed nothing. `tests/run-all.sh` removes its per-test log correctly
on a normal exit — demonstrated — and leaks exactly one when SIGKILLed, also
demonstrated. The three it left came from the cases that SIGKILL a driver ON
PURPOSE to exercise the watchdog path, and no trap runs on SIGKILL. So the cure
is containment: `run-all.sh` now creates that log from an explicit
`${TMPDIR:-/tmp}` template and `fx_run` points `TMPDIR` at its own scratch, so
what the trap cannot reach lands somewhere the test already deletes.

**That last change fixes a second thing.** A bare `mktemp` honours `$TMPDIR` on
GNU and IGNORES it on BSD/macOS, where the per-user directory comes from
`confstr` and no environment variable reaches it (measured: `TMPDIR=/x mktemp -d`
returns `/var/folders/…`). `run-all.sh` therefore ignored `TMPDIR` on every Mac,
which is the mechanism Phase 5's symlinked-`TMPDIR` arm relies on. With an
explicit template both platforms agree.

**The measurement needed fixing before the defects could be.** Snapshot-diffing
the temp directory around each test attributed the same directory to two
different tests and flagged entries belonging to other software on the machine
entirely. The replacement is a `mktemp` shim on `PATH` that supplies a
`$TMPDIR`-rooted template when the caller gives none: each test then runs in a
private temp root and whatever remains in it is unambiguously that test's. Under
that method the suite leaks **0**.

### The floor container trusted the mount, but not the copies the suite makes of it

Phase 5 re-runs the hermetic suite as root inside the bash-floor container
against the working tree bind-mounted `:ro` at `/w`, and trusted exactly that
one path through git's `safe.directory`. The narrow scope was reasoned from
"this container is single-purpose and throwaway (`--rm`) and never touches any
other directory", and that premise is false:
`tests/test-falsify-historical.sh` seeds a scratch copy of the repo — `.git`
included — into a `mktemp` dir, and `cp -a` running as root **preserves the
host uid on the copy**. git then refuses the copy as dubious ownership,
`_fr_tracked_state` folds that `fatal:` into the tree's state (`2>&1`,
deliberately), and the seed-faithfulness guard fires. The guard was right: no
oracle could have run in that tree. The trust was too narrow.

**The class cannot appear in the three environments this repo had run in until
now**, which is why it surfaced only on 2026-08-29, in the first full
`verify-on-host.sh` run on a Linux host. On a macOS host the Docker
file-sharing layer interposes and the container never sees a host uid at all;
in a daemon-less container Phase 5's floor container does not run; and in
Actions `actions/checkout` clones *inside* the container as root, so the uids
match by construction. A Linux host is the first place a real bind mount
carries a real uid that differs from the container's root.

Fixed by trusting `*` in addition to `/w`. Not a narrower pattern: the floor
image ships git 2.34.1, where prefix globs do not exist — measured, not
assumed, `safe.directory '/tmp/*'` still refuses the same repo and only the
literal `*` is honoured. The trust that adds is bounded to a `--rm` container
whose one mount is the developer's own `:ro` tree — the same trust `/w` already
granted, extended to copies of `/w` at paths nothing can predict.

### The integration sweep could not remove what its own cases left behind

`$IT_SCRATCH` is a host directory bind-mounted into containers that run as
root — and `docker exec` defaults to root too — so a case can leave a
**root-owned directory** in it. Unlinking a file needs write permission on its
*parent*, so one such directory makes its whole subtree unremovable by the
non-root user doing the sweeping: `rm -rf` prints `Permission denied` per
entry, leaves everything above it on disk, and the run still exits 0.

Measured 2026-08-29: case 700 execs `graphify --version`, and of the six
agent-tier tools graphify is the only Python one, so CPython writes
`__pycache__/` as root into the uid-1000 group tree. Two such directories per
run, surviving every sweep of every run.

Fixed in the sweep rather than in the case. Stopping *this* leak at the source
would have meant suppressing Python bytecode for one `docker exec`, leaving the
next root-run command that writes anything to reopen the same hole; the sweep
is what owns the "scratch is removed" invariant. `it_remove_scratch` tries a
plain `rm -rf` first and starts **no container at all** when that succeeds, so
an ordinary green run costs nothing extra. Only when something survives does it
escalate — to a container that does nothing but **chown**: the deletion stays
on the host side under the user's own account, and the container's entire power
is handing ownership back, through one explicit mount of one directory. It is
non-fatal at every step, because it runs from the `EXIT` trap where aborting
would discard the exit status the whole run exists to produce; a leak it cannot
clear is now reported **by path** instead of being silent to the exit code and
illegible in the output.

Ownership is also reclaimed **inside the variant loop**, against each variant's
own image, immediately before that image is discarded. Doing it only in the
sweep would have fixed the full local run and not nightly: `--variant agents`
never builds the default image, so by sweep time that run has nothing left to
start a recovery container from — and it is precisely the run that produces
these leftovers.

**Only a Linux host can see any of this.** macOS's Docker file-sharing layer
never hands the container a host uid, and CI discards the whole VM, so the leak
is free there. It surfaced in this repo's first full `verify-on-host.sh` run on
a Linux host.

## v0.9.1 — 2026-08-29

**A patch: five repairs, no new keys.** Every one was found by running the local
layer on a Mac, and **none of them can happen on Linux CI** — which is the whole
argument for that layer existing.

**The costly one was a single transient `chmod`.** A corpus came back 508 killed,
11 survived, **zero** unproven, all 30 controls green — and exited non-zero,
because one scaffold step returned 137 during the one pristine-baseline
invocation an oracle gets. `scaffold` is the runner's own word for *"the oracle
never ran"*, and a scaffold-failed **mutant** was already scored UNPROVEN for
exactly that reason; the baseline gate was the single place reading it as a claim
about the oracle's **code**. Ninety-seven minutes of measurement discarded by an
event the tier already knew how to classify.

**Two blocks of the tier's own tests only ever ran one branch** — they faked
`uname` for the Darwin arm and then read the real machine for the negative one,
so the assertion was about the host: green on the Linux that runs CI, red on
every Mac. And **a test wrote its fixture into the working tree**, which Phase 5
mounts `:ro`; CI's floor job checks out *inside* its container, so that whole
class is structurally invisible there. The `:ro` mount's comment had cited a grep
as proof no test does this. The grep was wrong; the mount is the evidence.

**The parallelism question is now measured rather than retracted.** `--jobs 6`
against `--jobs 1` on the same host and corpus bought **1.21×** — and turned two
KILLED mutants UNPROVEN, which no ledger entry is owed, so the run scored green
while the coverage claim quietly shrank by two. The ceiling is global fork
throughput; workers divide it rather than add to it. The cap stays at 1, for a
reason that now has numbers behind it.

Verified end to end on a host: Phase 4 36/36, Phase 5 71/71 across all three
arms, Phase 6 **548/548 verdicts with zero unproven and zero timeouts**, Phase 7
clean over 161 scripts.

### Two things the mgd port found, carried back

- **A fixture path that worked here only by coincidence of layout.** The
  relocated `cantrun` fixture resolved its sibling as
  `$ENGINE_DIR/tests/portability.sh`, which is correct here because `tests/`
  sits under the engine — and wrong in the fork, where `tests/` is at the repo
  root. There it broke outright: three assertions red, reporting on a generator
  that had failed to source anything. `$TESTS_DIR/portability.sh` is
  layout-independent and is what the mirror fixture 70 lines above already uses.
  **Latent here, not broken** — the demonstration is the fork's run.
- **A mutant count in prose, which had already gone stale.** The Cadence row
  said "~10 min over 251 mutants" for long enough that the corpus more than
  doubled underneath it. It states a *standing property*, so any number in it
  has to be maintained forever; "the whole corpus" cannot rot. Adopted from the
  fork, which had it right.
- Deliberately **not** swept: the other counts in this repo
  (`the same 264-mutant corpus`, `249 mutants gave 4 unproven`, `97 min over 519
  mutants on 2026-08-28`) record *what was measured*, and the count is part of
  the evidence. A number describing what is true now rots; a number describing
  what was measured then is data.

### One transient `chmod` retired a target and discarded ninety-seven minutes

A macOS Phase 6 run came back 508 killed, 11 survived, **zero** unproven, with
all 30 controls green — and exited non-zero. One `chmod +x` inside
`test-integration-shim.sh`'s scaffold returned 137 (SIGKILL, nothing on stderr,
`ulimit -u` at 10666 against 417 processes in use, so not fork exhaustion)
during the single pristine-baseline invocation each target gets. That retired
all 29 mutants of `tests/integration/docker-shim.sh`, and because the corpus
then exits non-zero, the survivor ratchet the phase exists to pair with it never
ran at all.

`scaffold` is this runner's own word for "the oracle said it could not set
ITSELF up", and every other place that reads it treats the event as the
machine's rather than the code's: `falsify_verdict` scores a scaffold-failed
mutant UNPROVEN for exactly that reason, and the record format says so outright.
The baseline gate was the one place that did not — it read the same event as
"the oracle is not green on the PRISTINE tree", which is a claim about the
oracle's code, and skipped the target on it.

`fr_run_baseline` now retries that one channel, `FALSIFY_BASELINE_ATTEMPTS`
times (default 3), and nothing else: an oracle that goes red with a `FAIL:` line
is a statement about the code and is still taken at its word on the first
attempt — pinned by a counter that must read exactly one. A collapse that
persists still retires the target and still fails the run, but it must now be
persistent, it is named as the environment rather than as a red oracle, and the
`SKIPPED` record carries a third reason (`baseline-scaffold`) so a summary
reader can tell the two apart without the stderr they filter out.

### More workers on macOS buy 21 %, and cost two mutants

`fr_fork_cost_cap` capped `--jobs auto` at one worker on Darwin, and the comment
under it recorded a **retraction** rather than a measurement: the `--jobs 2` run
it once cited had been taken under two confounds of ours, which left everything
above 1 unmeasured rather than refuted. That comment asked for the run. Here it
is — same host, whole corpus, `--jobs 6 --timeout 120` against the previous
night's `--jobs 1`:

| | mutants | wall | per mutant | controls | unproven | timeouts |
|---|---|---|---|---|---|---|
| `--jobs 1` | 519 | 97.1 min | 11.22 s | 30 / 30 | 0 | 1 |
| `--jobs 6` | 548 | 84.9 min | 9.29 s | 32 / 32 | 2 | 8 |

Six workers bought **1.21×**, because the ceiling is a *global* fork/exec
throughput one rather than a per-core one — so workers divide the same
throughput instead of adding to it. The most expensive target paid 4.8× per
mutant for it (median 43.5 s → 207.0 s on `tests/lib-verify-repo.sh`, taking
66 % of that target's clock where one worker took 14 %).

And it cost measurement. Every one of the 519 shared mutants got the same
verdict at six workers as at one **except two**, and both moved KILLED →
UNPROVEN — `tests/bash-dialect-lint.sh`'s `f204b4ce` pair ran 128.9 s under one
worker and ~300 s under six, never reaching the assertion that had been observed
failing. An unproven mutant is not owed a ledger entry, so `check-ledger.sh`
scored that run OK: the coverage claim stayed green while the coverage dropped
by two. Controls stayed green and no verdict was *inverted*, so the failure mode
is fewer answers rather than wrong ones.

The cap therefore stays at 1, now for a measured reason. The knobs stay open for
an operator who wants the 21 %, and the banner says to raise `FALSIFY_TIMEOUT`
alongside `FALSIFY_JOBS`, because the clock is what load consumes first. It also
now names where the time actually goes: 36 % of the run is one target.

### Two blocks of the mutation tier's own tests only ever ran one branch

`tests/test-falsify-run.sh` faked `uname` to exercise `fr_fork_cost_cap`'s
Darwin arm and then read the **real** machine for the negative arm, so "the cap
is empty off Darwin" was an assertion about the host: green on Linux CI, red on
every Mac. The `--jobs auto` core-mix section had the same shape one probe
further out — it stubbed `sysctl` and `nproc` but not `uname`, so the Darwin cap
collapsed all four of its expectations to 1 on a Mac while CI stayed green. Five
assertions, all failing only on the platform the code is written for. Both arms
are now faked in both directions.

### A test wrote its fixture into the working tree, and only the local layer could see it

`tests/test-falsify-generate.sh` dropped a rewritten copy of `generate.sh` at
`tests/falsify/tmp-cantrun-$$.sh` — beside the original, because the copy sources
`../portability.sh` relative to its own directory. `verify-on-host.sh`'s Phase 5
mounts the working tree `:ro` into the bash-floor container, where that redirect
simply fails, and every assertion below it then reported on a file that was
never written. CI's `suite-floor` job checks out *inside* its container, so the
tree is writable there and the whole class is invisible to it.

The `:ro` mount was right and stays; the fixture now reproduces the two-file
layout it needs inside `mktemp -d`. The comment above that mount claimed the
property was confirmed by grepping every redirect in `tests/*.sh` — it was not,
and the mount itself is what caught it, which is the only guard in this repo
that could have.

## v0.9.0 — 2026-08-28

**A minor bump, and the reason is `shellcheck=ON`.** A new `sandbox.conf` key
installs Ubuntu's `shellcheck` — deliberately Ubuntu's, because the base is
`ubuntu:24.04` and CI pins `runs-on: ubuntu-24.04`, so apt hands back the same
version the lint gate runs. It exists because its absence cost two red pull
requests in one day: an agent working inside a container with no linter cannot
check its own work before pushing. `ai-containers-report.sh` also gained
`VERSION` and `SCHEMA` columns, read through `version.sh` so they cannot
disagree with what `./sandbox.sh --version` reports in the same project.

**The rest is the mutation tier learning to say what went wrong.** Most of the
entries below are one shape: the tier detected a failure and reported something
else, or nothing at all — a killed `git apply` read as a stale patch, a syntax
gate that could not run counted as a rejected candidate, a skipped target that
would not name what went red, four scaffold steps that failed silently, a
re-seed that reported itself as a success. Each was found by a host run, because
none of them can happen on Linux CI.

**The worst was a scratch tree that was not the repo.** Worker trees were seeded
and never checked, and the tier recorded the damaged tree's `git status` as the
**reference** every later check compared against — so a tree born broken had its
damage adopted as normal, and the only post-seed guard asked whether the
directory *existed*, which a partial copy always satisfies. Three consecutive
Phase 6 runs blamed the code the oracles test.

**Two defects here were introduced by fixes in this same release**, which is the
honest measure of how much of this was diagnosis rather than repair. Both were
Darwin-only: a worker cap in the wrong place, and a banner change that moved
`→ 1 worker on macOS` between two values a `grep` asserts. CI is Linux, so
neither could be seen there, and the second surfaced as an unrelated target
failing three targets deep into a two-hour run. The rule this repo already had —
a platform conditional needs a faked `uname`, or it is an untested claim — now
covers both branches of each.

**Diagnosis no longer costs two hours.** `docs/contributing.md` says to chase a
falsify failure with `--target`, which reproduces in a minute or two what the
corpus takes hours to reach, and Phase 0 no longer demands a Docker daemon for
phases that have no container in them.

### The Phase 6 banner broke its own assertion, on macOS only

- **`(jobs=X, timeout=Y)` is an asserted contract, not prose.**
  `test-verify-exit-code.sh` greps for that substring literally, so an operator
  who raised a knob can see in the log they paste back which one the run used.
- The runtime-estimate change put `→ 1 worker on macOS` **between** the two
  values. Only the Darwin branch changed, CI is Linux, so CI stayed green — and
  the failure surfaced on a Mac as **`tests/lib-verify-repo.sh` not green on the
  pristine tree**, three targets into a two-hour corpus run, naming neither the
  file nor the platform. Two host runs were spent on it.
- **The banner is written twice, once per platform, and only the Linux half was
  ever asserted.** `uname` is now faked — the same way `test-falsify-run.sh`
  exercises `fr_fork_cost_cap`'s Darwin arm — so Linux CI runs the macOS branch
  too, and the new assertion is demonstrated failing against the broken banner.
- Extra detail goes on its own line now, where it cannot come between two values
  something greps for.

### A `mktemp -d` in a subshell leaked a directory per invocation

- `sha="$(falsify_sha1_string …)"` called the scratch-dir helper **inside a
  command substitution**. `mktemp -d` made the directory on disk while the
  variables tracking it were set in the subshell and died with it, so the
  parent's release had nothing to release.
- Exactly one per invocation, which is why it never looked like a leak: one
  target run left 1, a 16-target corpus 16, and a container running the tier for
  weeks held **4,877 directories at 644 MB**. On macOS those land in
  `/var/folders`, shared with everything else on the machine.
- The scratch directory is now claimed in the **parent**, before anything reaches
  a subshell. Measured both paths: `delta=1` → `delta=0`.

### `(no error text)` was true, and useless

- **A non-zero exit that wrote nothing is a different finding** from a command
  that failed and said why. The scaffold helper printed `(no error text)` for
  both.
- A 2026-08-28 host run hit exactly that on **`chmod +x`** — a command that says
  *"No such file or directory"* when its target is missing. Silence rules that
  out and points somewhere else: at the command substitution never having run.
  On macOS the per-user process limit is low, and a **failed fork** yields empty
  output and a non-zero status, indistinguishable from a failed command unless
  the limit is reported next to it.
- The silent branch now reports the exit status, says plainly that the command
  may never have run, and prints `ulimit -u`, the caller's live process count,
  and `ls -l` of the file the step was acting on — the three facts that separate
  "fork exhaustion" from "the file went away" from "the command genuinely
  failed".

### Phase 0 demanded a daemon for phases that have no container in them

- **`PHASES=6` exited 1 without Docker.** Phase 0's environment banner made the
  daemon check unconditional, so the mutation tier and the linters — neither of
  which touches Docker anywhere — could not run without one.
- **That is not a technicality.** Phase 6 runs *serially* on macOS and takes
  hours, and the obvious way to give it the whole machine is to stop the VM
  holding 12 vCPUs and 36 GiB. The check turned the single configuration that
  makes the slowest phase fastest into an immediate `exit 1`.
- Fatal now only when the selected phases include one that needs a daemon
  (`4`, `5`), and it says which. Otherwise the banner reports the daemon
  unreachable and carries on.
- The header's advice to use `PHASES="5 7"` to *"skip the phases that need
  Docker"* was **wrong about 5** — it re-runs the suite inside the bash-floor
  container. `PHASES="6 7"` is the Docker-free selection.
- Both directions asserted, and the new assertions demonstrated failing against
  the old script: a gate that never fires and a gate that always fires are
  equally useless.

### Phase 6 promised 45 minutes and took 110

- **The estimate was measured at `--jobs 6` and never re-measured.** Its own
  comment said so. `fr_fork_cost_cap` narrows `auto` to **one** worker on macOS —
  deliberately, because `--jobs 2` put 2 of 24 controls red — so the real figure
  had been several-fold higher than the banner for every run since that cap
  existed.
- **A 2026-08-28 run took 110 minutes and its operator concluded the tier had
  hung.** That is the failure mode: an estimate nothing re-measures is worse than
  none, because the banner is what decides whether a healthy run gets killed.
- Now states that macOS runs **serially**, gives the measured figure *as*
  measured with its date, says the number grows with the corpus, and names the
  measurement behind the cap so `--jobs 2` is not rediscovered by hand.
- Part of that growth is real progress: the same run was the first to measure two
  targets that had been silently skipped.
### A failed re-seed reported itself as a successful one

- **Introduced by the seed-fidelity guard itself.** Once `fr_seed_slot` could
  fail, the mid-run re-seed could fail too — and its `NOTE` said *"re-seeded"*
  unconditionally, was never counted, and left the run exiting 0 on verdicts
  produced in a tree that is not the repo.
- **It also retried forever.** The fingerprint is the slot's reference; a failed
  re-seed left the stale one in place, so the very next mutant saw the same
  mismatch and paid another full tree copy. One bad slot became a copy storm, on
  the slowest platform the tier runs on.
- Now: the failure is named on stderr where it happens, counted, and makes the
  run exit non-zero; and the tree is fingerprinted as it actually is so the
  retry stops.

### Four unchecked scaffold steps, and a diagnostic that pointed nowhere

- **`test-integration-shim.sh` built its fixture with four unchecked commands** —
  `mkdir`, a heredoc, `chmod`, `ln -sf` — so a failure in *any* of them surfaced
  only as the symptom of the last: `link-exists=n`.
- A 2026-08-28 host run reported exactly that, as a falsify CONTROL failure, with
  the tmpdir present. Reproduced locally by failing the **`mkdir`**: the old code
  emits that identical diag line, naming nothing.
- Each step now reports itself and the error it gave, and the diag reports
  `$TMP/bin` — the directory the link lives in, which it never mentioned.

### A scratch tree that was not the repo, and three runs that blamed the code

- **The falsify tier seeded worker trees and never checked it had copied the
  repo.** Three consecutive Phase 6 runs died the same way: an oracle red on the
  *pristine* tree, the target skipped, every one of its mutants gone from the
  measured set, and the report naming the code the oracle tests —
  `no *.yml files found under .../w0/.github/workflows`.
- **The tier had the evidence and threw it away.** `fr_seed_slot` records the
  fresh tree's `git status` as the *reference* fingerprint every later debris
  check compares against, so a tree born damaged had its damage written down as
  normal. The only post-seed guard asked whether the slot **directory exists** —
  which a partial copy always satisfies, so it could never fire for the one
  failure mode that happens.
- **And the seeding ran backgrounded**, so `fr_seed_slot`'s exit status went to a
  bare `wait` and was discarded outright.
- **Fixed by verifying the seed against its origin** — a tracked-file
  `git status` comparison at both hops (repo → cache, cache → slot), fatal and
  naming the drift, before the fingerprint is taken. Slot seeding now collects
  its exit status per pid.
- **`cp -Pp` does not always preserve file modes.** Measured on a virtiofs mount:
  the one 0600 file in this repo arrives 0755, so the copy reads as ` M` to git
  while the origin is clean — and `tests/test-verify-lint-scope.sh` asserts an
  **empty** porcelain, so that alone reddens an oracle for a reason having
  nothing to do with any mutant. Every run in that environment had been doing
  this silently. Git-visible modes are now aligned after the copy.
- Demonstrated both directions: the damaged tree the Mac produced is now
  **rejected in seconds** naming the missing file, where the previous code
  returned 0 and ran the corpus for 45 minutes against it.

### `shellcheck=ON` — the linter the gate uses, in the container

- **A new `sandbox.conf` key** (default `OFF`) installing Ubuntu's `shellcheck`
  package.
- **The version match is the point, not a detail.** This base is `ubuntu:24.04`
  and CI pins `runs-on: ubuntu-24.04`, so apt hands back **the same shellcheck
  the lint gate runs**. A newer binary — Homebrew's, say — reports findings the
  gate does not, and time spent on those is time spent on a lint nobody is
  blocked by. Matching the gate beats being current here.
- **It exists because its absence cost two red pull requests in one day.** An
  agent working inside a container with no `shellcheck` cannot check its own work
  before pushing; the first fix for an `SC2034` was wrong, and the correction to
  it was wrong too, because the only place the real check ran was CI. Both were
  the same one-line directive.
- **A key rather than always-installed**, matching `vale`, `goreleaser` and every
  other optional tool: most projects in these containers write no shell at all,
  and the repo's size discipline is deliberate. Turn it **ON** in any project
  whose work *is* shell — above all this engine's own checkout, where Phase 7 and
  `hermetic-checks.yml`'s `lint` job both gate on it.
- Placed after the cleanup purge alongside `imagemagick`/`wkhtmltopdf`/
  `playwright`; `apt-get install` marks it manual, so the later qmd-layer
  `--auto-remove` does not reclaim it.

### A partial `cp -a` nested the scratch tree, and three oracles took the blame

- **`cp -R src dst` means two different things.** "Copy src TO dst" when dst is
  absent; "copy src INSIDE dst" when it exists. So a `cp -a` that creates the
  destination and **then** fails turns the fallback into a nested tree: part of
  the files at the top level, the rest under `dst/<basename>/`, and whatever
  `cp -a` never reached missing outright.
- **macOS produces exactly that shape.** Its `cp -a` (`= -pRP`) returns non-zero
  when it cannot copy extended attributes, *having already copied contents*. A
  2026-08-27 host run showed the result:

  ```
  FAIL: no *.yml files found under …/work/w0/.github/workflows — nothing was enumerated
  FAIL: ARCH: uname -m x86_64 -> linux/ (want linux/amd64)
  ```

  The workflows were sitting under `w0/pristine/` instead. **Three oracles went
  red in one run for this single reason**, each reported as a defect in the code
  it tests — `tests/lib-verify-repo.sh` and `tools-lib.sh` skipped entirely,
  retiring every one of their mutants.
- **Both copies had it**, and the `.git` one is worse: a partial `cp -a` there
  yields `$dest/.git/.git`, a work tree whose git directory is one level too
  deep, so every oracle that shells out to git in the scratch tree fails for a
  reason unrelated to the mutant.
- **Fixed by clearing the destination before the retry**, and **demonstrated**
  with a `cp` that copies part of the tree and exits 1 — driven through the real
  `fr_seed_slot`, because the bug lives in the recovery path and a
  reimplementation in the test would repeat the same mistake. Against the old
  code the assertion fails with the nested tree in its `got:`; against the fixed
  code it passes.
- **It explains the two SEEDING failures and nothing else — a scope this entry
  originally overstated.** The claim written here first was that this was "the
  cause of the vanishing files this session kept meeting", covering
  `test-portability.sh`'s `exists=n` and the shim's lost recorder too. That is
  wrong, and the evidence arrived the same day: a CI control run on **Linux**
  reported `dir=n exists=n left=0` for `test-portability.sh` — its whole
  `mktemp -d` gone. That directory is the test's own, never seeded from the
  cache, so no `cp` in this file can touch it, and the platform rules out the
  macOS xattr path entirely.
- **So there are two separate faults, and only one is fixed here.** The seeded
  worker tree being nested is this one, demonstrated and closed. Test-owned
  `mktemp -d` directories disappearing mid-run is a different, still-open
  problem, seen now on both macOS and Linux CI and not reproduced in 24
  consecutive control runs locally. The diagnostics added earlier are what
  separated them; without `dir=n` the two would still read as one story.

### The shim's scaffold guard watched one third of the scaffold

- **A macOS Phase 6 run reported the shim broken. It was not.**

  ```
  FAIL: volume create: labelled
        expected: volume|create|--label|ai-containers.it-run=unit|ai-containers-rvm-g|
        got:
  ```

  The first four cases passed and every later one failed with an empty capture —
  the same partway-through loss this file's header already records from
  2026-08-21, one component over.
- **`shim_scaffold_ok` watched the `docker` symlink and nothing else.** The
  scaffold is three things: the symlink, the **recorder** the shim `exec`s
  (`IT_REAL_DOCKER`), and the directory holding both. Lose the recorder and the
  shim still runs, the symlink check still passes, `$REC` stays empty, and the
  file reports a run of assertion failures about the shim's *behaviour* — the
  exact misreading the `docker` check was added to prevent.
- **Each piece is named separately**, because they point at different culprits:
  "the recorder is gone while the symlink survives" is a finding; "the scaffold
  is gone" is not.
- **The directory is checked FIRST, and the order is load-bearing.** Asked after
  the two files, `-e "$TMP/bin/docker"` is already false when the directory is
  gone, so that branch fires and the directory branch can never run — a line no
  assertion can watch. Caught while demonstrating the arms, not in review.
- **All three demonstrated by removing each in turn**, against a control that
  stays green. With the recorder removed, the old guard produces the Mac's exact
  line and the new one produces `SCAFFOLD-FAILED: the recorder … is gone
  mid-run`. That channel matters: `run-all.sh` reports it as "could not set
  itself up", and the falsify tier scores such a mutant UNPROVEN rather than
  KILLED, so a scaffold that evaporates stops manufacturing false kills.
- **This is the second test this week losing files from its own `mktemp -d`
  mid-run on that host**, after `test-portability.sh`. Both intermittent, both
  macOS-only, neither reproducible on Linux. The cause is still unknown and is
  deliberately not guessed at; both now say precisely what went missing, which is
  what the next occurrence needs.

### The empty-helper diagnostic fired for real, and now splits its two causes

- **It worked.** On 2026-08-27 the diagnostic added a release earlier fired for
  the first time on a genuine failure and reported the fact three prior
  occurrences could not:

  ```
  FAIL: p_stat_mode returned empty … [fixture=/tmp/tmp.E2JLz5Q8Ru/f exists=n size=?
        | p_stat_mode stderr: stat: cannot statx '…/f': No such file or directory]
  ```

  **`exists=n` — the fixture file is gone.** Across 2026-08-21, 08-23 and 08-26
  nobody knew that; the explanation never reached the log.
- **The trail stops there, and that is recorded rather than guessed past.** Not
  reproducible standalone (3/3 clean, both repos), not reproducible over repeated
  full-suite runs (3 further runs, 72/72 each), no glob `rm` anywhere in
  `tests/`, `run-all.sh` runs nothing in parallel, and bash does **not** fire an
  `EXIT` trap inside a `( )` subshell — measured, not assumed. Four hypotheses
  this session have now been killed by measurement; a fifth is not worth writing
  down.
- **So the instrument gets sharper instead.** The diagnostic now reports the
  **directory** and what is left in it, which separates the two remaining
  candidates on sight:

  | | `dir` | `exists` | `left` |
  |---|---|---|---|
  | something removed the file specifically | `y` | `n` | non-zero |
  | something removed the whole scratch dir | `n` | `n` | 0 |

  Both arms demonstrated by removing each in turn, rather than reasoned about.

### The Darwin worker cap was in the wrong place, and broke a test only macOS could see

- **A host run finally named it**, one release after the baseline learned to say
  what went red:

  ```
  FAIL: phase 6: the defaults survive an operator who exported the knobs
        -- got '--jobs 1 --timeout 120', so the suite is reading the developer's shell instead of the code
  ```

  `test-verify-exit-code.sh` scrubs `FALSIFY_*` and asserts the corpus is invoked
  with the script's **own** defaults. Putting the Darwin cap in
  `verify-on-host.sh` made "the default" platform-dependent, so on macOS the
  assertion saw `--jobs 1` and concluded the operator's shell had leaked in. On
  Linux the branch never fires, so **no CI job could see it** — and the failure
  skipped `tests/lib-verify-repo.sh` entirely, retiring all 55 of its mutants.
- **`auto` means "work out a sensible number", so a platform needing a different
  number needs a different `auto`, not a different caller.** The cap moves to
  `fr_fork_cost_cap`, beside the probes that already narrow the budget by
  reported CPUs, cgroup quota and performance cores — each narrows, none widens.
- **It also fixes a case the caller-side version never covered**: anyone running
  `tests/falsify/run.sh --jobs auto` directly on a Mac got no benefit at all.
- **Both branches are now exercised on every machine.** `uname` is faked rather
  than the platform sniffed, so Linux CI runs the Darwin arm too — and asserts
  the cap is **inert** off Darwin, since a narrowing probe that fired everywhere
  would silently serialise CI. A Darwin conditional with no Linux-visible test is
  the untested claim this repo keeps purging, and this one had already proved why.
- **The measurements move with the cap** — and one of them is retracted. See
  below.

### A skipped target would not say what went red

- **The most consequential failure the mutation tier can report was also the only
  one that said nothing.** An oracle that is not green on the PRISTINE tree gets
  its whole target **skipped** — every one of its mutants retired from the
  measured set — and the report was an `rc` and a signal name:

  ```
  ERROR: oracle '…' is not green on the PRISTINE tree (rc=1, signal=exit+failline) — Skipping …
  ```

- **Three macOS host runs in a row hit this and none of them could be diagnosed.**
  Two oracle sets went red on the pristine tree every time, and every time the
  only way forward was to guess — which is how this session spent an hour on a
  memory hypothesis that turned out to be unsupported.
- **`fr_run_control` has captured exactly this since 2026-08-21.** The control
  path extracts the `FAIL:` lines *and their indented evidence*, for a failure
  strictly less severe than a skipped target. The baseline never got it.
- **One definition now, used by both.** `fr_oracle_excerpt` carries the extraction
  and the reasoning behind it — the continuation lines matter as much as the
  `FAIL:` line, because this repo's `check` helper puts the assertion's name on
  one and the `expected:`/`got:` evidence on the others. Two copies would drift
  into disagreeing about what counts as evidence.
- **Demonstrated in both directions** against a deliberately red pristine oracle:
  the old code prints the skip and nothing else; the new one prints the `FAIL:`
  line and its two evidence lines. An oracle that goes red *silently* is reported
  as that rather than as "no output was captured", the same distinction the
  control path already draws.

### A killed `git apply` was reported as a stale mutation patch

- **A macOS Phase 6 run reported `410-workspace-root-not-chowned` stale**, with
  the remedy *"the code it breaks has changed; regenerate the patch"* — while the
  patch applied cleanly on every other machine and its target, `entrypoint.sh`,
  had not been touched in weeks.
- **`git apply --check` answers three ways and the caller flattened two of them.**
  Measured: **0** applies, **1** does not apply, **128** (and any other status,
  including 128+N when the process is SIGKILLed under memory or process pressure)
  means it never judged the patch at all. `mutate.sh check` returned that status
  verbatim and `test-mutations.sh` read every non-zero as "the code changed".
- **The remedy is what made it expensive.** A wrong verdict that says nothing
  costs a reader a minute; one that confidently instructs them to regenerate a
  patch nobody examined costs an investigation — and invites an edit to a file
  that was never wrong.
- **`mutate.sh check` now returns 3 for could-not-determine** (3, not 2 — 2 is
  already its usage error, and a caller must be able to tell "you called me
  wrong" from "git could not answer"), `verify` prints `UNCHECKED` rather than
  `STALE`, and `test-mutations.sh` reports the three answers separately.
- **Reproduced before fixing, and the old message reproduces byte-for-byte.**
  With a `git` that dies on exactly one mid-run `apply --check` — the shape a
  loaded machine produces — the old caller emits the Mac's line verbatim and the
  new one says the patch was never examined. Real `git`: 0 failures, unchanged.
- **The falsify tier immediately found a hole in the new code, and it was a real
  one.** Splitting the return into three answers created a `1) return 0` mutant
  that nothing killed: with it, `mutate.sh` would report every **stale** patch as
  applying, and the staleness guard — the entire reason `cmd_check` exists —
  would pass while detecting nothing. Until then no assertion had ever handed it
  a patch that does not apply, because every patch in `mutations/` applies. Now
  one does, through a fixture repo rather than a temporary file dropped into the
  real `mutations/` (which the coverage loops would count, and an interrupted run
  would leave behind). That target now measures **60 mutants, 60 killed, 0
  survivors**.
- **This is the second instance of one shape in one day**, after
  `tests/falsify/generate.sh` conflating "this candidate does not parse" with
  "`bash -n` never ran". Both turn machine trouble into a confident, wrong,
  actionable-looking verdict. The pattern is worth looking for wherever a
  checker's exit status is passed straight through to a caller that only asks
  whether it was zero.

### A diagnostic that has been lost three times now travels on the failure line

- **`test-portability.sh` reports four helpers "returned empty" and, three times
  running, has failed to say why.** `2026-08-21` (mgd PR #76, run 32523718531),
  `2026-08-23` (main, run 32635611521), `2026-08-26` (PR #134, run 32980406406).
  Each time the explanation existed, in the same file, written for that purpose.
- **The first loss was diagnosed as the wrong stream** and fixed by moving the
  diagnostic from stderr to stdout. It went missing twice more anyway. The third
  occurrence supplies the fact that settles it: **all four `FAIL:` lines reached
  the log and not one continuation line did.** The harness is not the culprit —
  feeding its own extraction `awk` a synthetic block keeps continuation lines
  correctly. Whatever drops them, the failure line is the transport observed
  surviving every recurrence.
- **So the diagnosis now travels on that line**, and needs no second line to
  arrive. A diagnostic whose explanation travels separately is one transport away
  from being no diagnostic at all, and this repo has paid that three times.
- **The fixture is also asserted before any helper is consulted.** Every helper
  is handed one file; if it was never written they all return empty and the
  report is four symptoms of one fact. That is now a `SCAFFOLD-FAILED:` — its own
  channel in the harness — naming the cause once.
- **The rewording is load-bearing, not cosmetic.** A whitespace-prefixed `FAIL:`
  inside a `pass`/`fail` string makes the falsify harness read the oracle as red
  on the pristine tree and **skip the whole target**. The natural phrasing here —
  "the FAIL: line" — is exactly the poison that cost 13 unmeasured mutants on
  2026-08-23, so the guard caught this change reintroducing it, and the comment
  now says why the wording cannot be tidied back.

### `--jobs auto` was wrong on Darwin, and it is why Phase 6 could not complete

- **`fr_cpu_budget` resolves `auto` to `min(nproc, cgroup quota)`. macOS has no
  cgroup**, so it takes `nproc` — 12 on the measured host — and every falsify
  worker runs a whole `run-all.sh`. The budget measures how many CPUs may be
  burned; the binding constraint on macOS is fork throughput.
- **Measured**, one Apple Silicon host, one target (`version.sh`, 30 mutants):

  | | result |
  |---|---|
  | oracle baseline | **136 ms** on Linux vs **2514 ms** here (~18×, unloaded) |
  | `--jobs auto` (12) | many controls red, oracles red on pristine trees, no score |
  | `--jobs 4` | 2 of 26 controls red, 4 mutants over a 300 s clock, no score |
  | `--jobs 1` | clean — 29 killed / 1 survived / 0 unproven, controls 2/2 green |

- **`--jobs 2` was reported here as a clean negative. RETRACTED — it was not
  measured cleanly, and the write-up was the mistake.** Two confounds, both ours:
  an assistant was running the hermetic suite and a second falsify job on the
  same machine throughout that run, and the run predates the fix that moved the
  Darwin cap out of `verify-on-host.sh` — so one of the oracles it reported red
  on the pristine tree was red **deterministically**, from that bug, not from
  load. A number obtained under a bug the number is being used to reason about is
  not a measurement. Above 1 is **unmeasured**, not refuted.
- **The memory hypothesis built on that run is RETRACTED too.** `rc=137` in the
  failing assertions was read as evidence of host memory pressure, and Colima's
  36 GiB was proposed as the cause. It does not hold: a later run with every
  other application closed and the assistant idle failed the same way, the host
  has 64 GB, and the concrete causes turned out to be two status-code
  conflations and one misplaced platform conditional — none of them memory. The
  rc=137 remains unexplained and is recorded as that, rather than as a theory.
- **`verify-on-host.sh` now defaults `FALSIFY_JOBS` to 1 on Darwin**, and only
  there — an unset environment on Linux runs exactly what it always ran, and an
  explicit `FALSIFY_JOBS` still wins everywhere. A failed control invalidates
  every kill near it, so the default is the only value **observed** clean rather
  than the largest that might work. **2 is untested and deliberately not chosen**;
  measure it and raise this the same hour.
- **Phase 5's symlinked-TMPDIR arm is INERT on Darwin, not merely redundant**,
  and the comment now says so: macOS's `mktemp` ignores `TMPDIR` when given no
  template, so the export steers nothing there. The arm still runs — the point it
  exists to make is made on Linux, where CI's `suite-symlinked-tmp` job runs.

### A syntax gate that could not run counted as a rejected candidate

- **`generate.sh` conflated "this candidate does not parse" with "the check never
  ran".** It returned `bash -n`'s status straight through, and the caller
  discarded on any non-zero. `bash -n` distinguishes them cleanly and always has
  — measured, not assumed: **rc 2** is a syntax error, **rc 0** parses, and
  anything else (an unreadable scratch file, and the shape a failed fork takes
  under memory or process pressure) means bash never judged the candidate.
- **The consequence is the one failure a mutation tier must never have.** With
  the gate un-runnable, the old generator exits **0** and reports
  `0 mutant(s), 17 discarded` — a plausible tally, a successful exit, and an
  empty corpus. Coverage shrinks without the number that reports it moving. On a
  loaded macOS host — where oracle runs are **~18× slower than Linux** before any
  contention, and every falsify worker runs a whole `run-all.sh` — that is
  reachable, not theoretical.
- **A gate that cannot run now aborts the generation and names the cause**,
  rather than blaming the candidate. Demonstrated by making the gate return 127:
  the generator exits non-zero, emits no mutants, says `bash -n could not run`,
  and prints **no discard tally** — because a tally would read as a completed
  run. A stubbed gate (which the tests use to prove the gate is load-bearing)
  still yields 0 and still reads as "parses", so that demonstration is untouched.

### Two tests that went red because the machine was busy

- **`test-blocked-capture.sh` allowed the daemon 2 seconds** to record one packet
  — work that takes milliseconds. The budget was never about the work; it is
  headroom against the machine, and 2s went red on a Mac running two suites at
  once. Now 30s, which **costs nothing when the daemon is prompt** (the loop
  breaks on the first poll — the file still runs in 0.16s), and the failure
  message now says how long it waited, so a slow pass is never mistaken for a
  fast one.
- **`test-falsify-generate.sh` compared the walked count against the pinned
  total**, so a generator that came up short and a walk that could not read its
  own input produced the identical sentence: `independently re-applied 36
  mutants — walked 34 instead`. Those are different defects with different
  owners. The two facts are now separate assertions, and the one that fired on
  macOS — the **generator** came up short — says so.
- **Neither is a tolerance raised to hide a defect.** A test that goes red
  because a laptop was busy teaches people to ignore red, which is the one thing
  this suite cannot afford. Both still fail on a real defect, and both now say
  which defect.

### The symlinked-TMPDIR guard could not run on the platform it exists for

- **`test-symlinked-tmp-guard.sh` failed on every Mac**, in both repositories,
  while passing in CI and in the floor container. Its whole demonstration rests
  on `TMPDIR` steering `mktemp -d` — GNU coreutils behaviour, and **not
  universal**. macOS's `mktemp`, given no template, ignores `TMPDIR` entirely and
  uses the per-user directory from `confstr(_CS_DARWIN_USER_TEMP_DIR)`. Measured
  on Darwin arm64: `TMPDIR=/Users/x/tmp-plain mktemp -d` returns
  `/var/folders/w9/…/T/tmp.UuY97xwbZb`.
- **The guard was right to fail, which is the point.** With no lever, the naive
  fixture fails under *both* arms — every path it is handed is symlinked
  whatever `TMPDIR` says — so assertion 1 passed **for the wrong reason** and
  assertion 2, the control that exists to catch exactly that, failed. It refused
  to certify a demonstration it could not perform. What it must not do is report
  a platform lacking the lever as though the mechanism were broken.
- **The lever is now measured, not assumed**, and where it is absent the same
  property is demonstrated through an explicit `mktemp -d "$dir/…XXXXXX"`, which
  every `mktemp` honours — the symlink still has to be what makes the naive
  comparison fail. Only the claim that *`TMPDIR` is the lever* is lost, and that
  is printed as a `NOTE` naming what went unexercised rather than quietly
  skipped. Probed rather than sniffed with `uname`: the question is what
  `mktemp` does here, and a platform test is a proxy that can drift.
- **Reproduced before fixing, with a fake `mktemp` of the macOS shape** — no Mac
  required. The old guard under it emits the identical
  `the same fixture passes under an ordinary TMPDIR (got rc=1, wanted 0)`, and
  passes under GNU `mktemp` as a control; the new guard passes under both.
- **This is the third instance of the shape the file itself was written to
  prevent** — an assumption true in CI's environment and false in a developer's.
  That it happened to the guard *for* that class is the sharpest possible
  argument for the local layer: nothing but a real host run could have found it.

### `--version` answered for whatever git repo it was standing in

- **A project copy that was never told its version reported the PROJECT's own
  release.** `git -C` resolves the *enclosing* repository, and it does so for an
  ignored directory exactly as for a tracked one — so `<project>/.ai-containers/`
  with no `engine-version` fell through to `git describe` on the project itself.
  A project tagged `v9.1.2` reported `ai-containers  v9.1.2`: a real release
  string, for entirely the wrong tree, with nothing marking it a guess.
- **This was the common case, not a corner.** Every project synced before
  `engine-version` existed is in exactly that state until its next sync — and
  `docs/configuration.md` promises those report `unknown` "rather than guessing",
  while `version.sh`'s own header said it "does not fall back to the git repo the
  caller happens to be standing in". Both were describing an intent the code did
  not implement. Demonstrated against this repository's own `.ai-containers/`,
  which reported `v0.8.1-2-g17caa8f-dirty` and now reports `unknown`.
- **Git is now asked only about an engine tree**, identified by `project-init.sh`
  — base-repo-only by construction, deliberately absent from
  `AI_CONTAINERS_SHARED_FILES`, so no project copy has ever had one while every
  engine tree does. A predicate over the directory's own contents also keeps
  working where "is this a git repo" cannot: a release tarball has no `.git`, and
  a project copy is ignored by, but still inside, its project's repository.

### `ai-containers-report.sh` reports each project's version and schema

- **Two new columns, `VERSION` and `SCHEMA`**, after `BASE` — and leading the
  table when `BASE` is absent, which is the single-base default.
- **They are per PROJECT, which is the whole point.** A project's
  `.ai-containers/` is a working *copy* that drifts from the base it was made
  from until someone runs `sync-to-projects.sh`, and until now nothing showed
  that drift: two projects from one base could sit on different engine releases
  and different schema versions with the report saying nothing about it.
- **Read through `version.sh`**, not re-derived, so a column cannot disagree with
  what `./sandbox.sh --version` reports inside the same project. `version_schema`
  was extracted from `version_report` for the second caller rather than the
  marker-parsing being written twice. That makes `version.sh` a hard dependency
  beside the script, exactly as `bash-floor.sh` already is.
- **`unknown` and `n/a` mean different things and are kept distinct**: `unknown`
  is a copy that was never told (or has no `sandbox.conf`), `n/a` is a registry
  entry whose path does not exist, so nothing could be read at all.
- **The sort keys moved with the columns.** They name `GROUP` and `PROJECT` by
  field number, and inserting two columns ahead of them would otherwise have
  silently re-sorted the report by version while the header went on promising
  "sorted by group, then project name".

### `--version` could report a release the copy did not come from

- **`version_record()` left a stale record standing.** When the source tree
  cannot state its own version it correctly declines to write `unknown` — a file
  saying `unknown` is worse than no file, because it stops a later sync telling
  "never recorded" from "recorded once, badly". But declining to *write* is not
  the same as leaving whatever is already there, and that is what it did: a
  project recorded once from a git checkout and then re-synced from a `.git`-less
  export of the engine — a release tarball, an `rsync`ed copy, a Docker build
  context — kept reporting the **old release forever**, with nothing in the
  output hinting that the number described a tree the copy no longer came from.
  Reproduced before it was fixed, not reasoned about.
- **It is the one thing this feature's own header says must never happen.**
  "The engine release is the only one that can lie, and the design is shaped
  around that" — every other part of it is: `git describe` keeps its suffix, the
  recorded value beats the git repo the caller happens to be standing in, and an
  unrecorded copy says `unknown` rather than guessing. This was the remaining
  path where it lied, confidently.
- **Fixed by removing the stale record, not by writing `unknown`**, so absence
  keeps meaning exactly one thing and the rule above survives intact.
- **The mutation tier found the new line's one weakness and it turned out to be
  equivalent** — `|| true` against `&& true` on the `rm`. The site looked like it
  should discriminate, because it sits in a function whose callers run `set -euo
  pipefail`; it does not, since bash suppresses errexit for the non-final command
  of an AND-OR list. Measured directly, recorded in `survivors.txt` as
  EQUIVALENT, and the `|| true` kept: it states the intent at the point of the
  risk and stops being redundant the moment anything is added after it.
- **A second assertion came out of it that does discriminate**, covering a path
  nothing reached before: non-fatality when a stale record exists and **cannot**
  be removed. The pre-existing non-fatality assertion uses a destination
  directory that does not exist, where `rm -f` succeeds by definition, so only an
  existing-but-unwritable directory reaches the failure. It checks its own
  premise and reports a skip rather than passing vacuously where the mode is
  ignored (root, or a filesystem that does not enforce it).

## v0.8.1 — 2026-08-26

**A patch release that exists because v0.8.0 could not publish itself.** The tag
push failed before any of this repository's scripts ran, and the repair that
followed was wrong twice — first in a way that failed loudly, then in a way that
published a release titled `v0.8.0` and looked fine. Nothing else changed: no
key, no script, no behaviour inside the container.

**This section exists at all because the fixes were recorded against the wrong
release.** Both landed after `v0.8.0` was tagged and both wrote their entries
into that tag's section, so `CHANGELOG.md` on `main` described work the tag did
not contain and no longer matched the release body published from it. The
entries are unchanged; only the version they are filed under is. A changelog
that misreports which tag carries a fix is the same class of defect as a test
that passes without asserting anything — it is consulted, it agrees, and it is
wrong.

### The release workflow could not check itself out

- **v0.8.0's first tag push failed before any of this repo's scripts ran.**
  `de3c706` added `fetch-tags: true` so the release title could come from the
  annotated tag's message. That flag drops `actions/checkout`'s `--no-tags`, so
  git's automatic tag-following targets `refs/tags/<tag>` at the same moment as
  checkout's own explicit `+<sha>:refs/tags/<tag>` refspec, and git refuses two
  sources for one destination: `fatal: Cannot fetch both <sha> and
  refs/tags/v0.8.0 to refs/tags/v0.8.0`.
- **It had never been exercised.** v0.7.0 was published from the previous
  configuration, and v0.8.0 was the first release after the change — so a
  modification to the release path shipped green and broke on first use, which
  is the failure mode this repo's whole test posture exists to prevent.
- **The obvious repair is a trap, and this was measured rather than reasoned.**
  Removing `fetch-tags` makes the fetch succeed and leaves `refs/tags/<tag>`
  pointing at a **commit**: `git cat-file -t` reports `commit`,
  `release-title.sh` correctly reads that as a lightweight tag, and the release
  publishes the bare tag name — exactly the defect `de3c706` existed to fix.
  `fetch-depth: 0` yields a real tag object and a rendered title.
- **`fetch-depth: 0` was necessary and not sufficient, which took a second
  failed attempt to learn.** With it, the workflow ran green and published a
  release titled `v0.8.0` — the bare tag name — with a perfectly good body.
  `actions/checkout` fetches real tag objects and then, on a tag push,
  force-updates `refs/tags/<tag>` to the commit SHA. Two fetches, the second
  undoing the first, straight from the runner log:

  ```
  git fetch ... +refs/heads/*:... +refs/tags/*:refs/tags/*   <- the tag object
  git fetch --no-tags ... +<sha>:refs/tags/v0.8.0            <- clobbers it
  ```

  No checkout configuration prevents that second fetch, so the workflow now
  restores the tag object itself and **fails loudly** if it is not an annotated
  tag — a wrong title on a published release is much more annoying to correct
  than a failed workflow.
- **`tests/test-release-checkout.sh` pins it by effect, not by key name**, and
  its first version was itself wrong in the instructive way: it simulated ONE
  fetch, so it passed on the configuration that published a bare-titled release.
  A guard that is consulted and agrees is worse than no guard. It now issues the
  sequence the runner actually issues, and **executes the workflow's own recovery
  step** rather than assuming it — a `release.yml` that stops restoring the tag
  object fails three of its assertions, and `fetch-tags: true` fails it outright.

## v0.8.0 — 2026-08-26

**A minor bump, and the reason is `playwright=ON`.** A new `sandbox.conf` key
bakes the OS packages Playwright's browsers link against — it has to be
build-time, because `entrypoint.sh` drops root before the agent shell exists and
nothing in the container can ever `apt-get install`. `sandbox.sh` gained
`--version`, and a new `CONTAINER_SHM_SIZE` alongside it: headless Chromium dies
on Docker's 64 MB `/dev/shm`, and `CONTAINER_MEMORY` does not govern that.

The rest is repair, and two of the three defects fixed here were **tests that
passed in one environment and covered nothing in another** — a fixture that
modelled "rvm is absent" by finding the developer's rvm, and a version check
that asserted the git path only where the checkout happened to have tags. Both
had been green on somebody's machine while asserting nothing on everybody
else's. The lesson each time was the same: construct the state the test needs
instead of inheriting it.


### `--version`, and a PATH repair that took bash with it

- **`./runme.sh --version` (and `./sandbox.sh --version`) reports three numbers
  from three places**: the engine release, `sandbox.conf`'s schema version, and
  the pinned `nvm-version`. It is pure output — the generated launcher
  short-circuits **before** its own `./build.sh`, so asking what version this is
  never builds an image to answer.
- **The engine release is the only one that can lie, and the design is shaped
  around that.** In this repo it comes from `git describe --tags`, suffix
  included, so a tree eleven commits past a release says so instead of claiming
  to be the release. A project's `.ai-containers/` is a working *copy*, not a git
  repo, so `project-init.sh` and `sync-to-projects.sh` write `engine-version`
  into it at copy time; the recorded value is preferred over git precisely so a
  copy sitting inside an unrelated repo cannot report that repo's version, and a
  copy that was never told reports `unknown` rather than guessing.
- **`nvm-version` is in the report because it is pinned rather than detected** —
  nvm's latest cannot be resolved at build time behind a rate limit, and
  `update-nvm-version.yml` exists solely to keep the key current, so the field is
  that job's output. An empty key reports the Dockerfile's `ARG NVM_VERSION`
  default instead, labelled, because the question is what the *image* gets.
- **Sourcing it from `sandbox-common.sh` was tried and reverted within the
  hour.** Several fixtures copy a hand-picked set of engine files into an
  isolated tree, and one new hard dependency there broke twelve tests at once.
  `version.sh` is sourced directly by the three entry points that call into it —
  the same reasoning that has six entry points sourcing `bash-floor.sh` directly.
- **The PATH sanitising from the previous entry could take `bash` and `sed` with
  it.** It dropped any directory providing `rvm`, which is harmless when rvm has
  a directory of its own and catastrophic when a system-wide install is
  symlinked into `/usr/local/bin`. This repo had already sprung that exact trap
  once with `shellcheck` in place of `rvm`. A directory is now dropped only when
  the tool is *all* it provides; otherwise it is replaced by a shadow of symlinks
  to everything else, so nothing is built in the common case and nothing is lost
  in the rare one.
- **The mutation tier found a real flaw in the guard for that fix.** Five mutants
  came back `UNPROVEN` with a `scaffold` channel, because the guard built its own
  benign PATH *with the function under test* — so a broken helper broke the
  test's own setup, and an oracle that cannot set itself up reports nothing. The
  benign arm is now derived by a deliberately different algorithm, and the guard
  asserts its own premise. That target went from 7 killed / 2 survived / 5
  unproven to **12 killed / 2 survived / 0 unproven**, with both survivors
  classified in the ledger.

### A test fixture that modelled "rvm is absent" by finding the developer's rvm

- **`test-rvm-reconcile.sh` failed on any machine with rvm installed, and passed
  everywhere else.** Its `boot_case` models "rvm bootstrapped but the loader
  gave us no usable rvm" by *omitting* its own `rvm` stub, then asserts the
  reconcile hits bash's `rvm: command not found`. It composed the child's PATH
  as `"$bin:$PATH"` — the stub directory prepended to whatever the developer
  had. Omitting the stub therefore meant "unresolvable" only on a machine with
  no rvm. On one that had it, the call reached the **host's** rvm, the reconcile
  succeeded, and the case failed pointing at the product: it reported
  `ruby-3.4.5 already present`, which was the version in the developer's
  `~/.rvm`, not in the test's temp home.
- **CI could never see it.** GitHub's runners have no rvm, so the case passed
  there for the thirteen days between `f95cd57` — the commit that made the case
  reach that branch at all — and its discovery. `verify-on-host.sh`'s Phase 5
  runs the same suite, so the **local** layer, the one `local ⊇ nightly ⊇ PR`
  calls a superset, was the only layer that could fail, and did. This is the
  third instance of that shape here, after macOS's `/var`→`/private/var` and the
  symlinked `TMPDIR`: an assumption true in CI's environment and false in a
  developer's, invisible to the layer that runs most often.
- **Fixed at the fixture's PATH contract, and applied to all three cases** — not
  only the one that broke. The other two prepend a stub that shadows the host's
  rvm anyway, so they were correct by *ordering*; making the invariant hold by
  construction means the next case to omit a stub inherits it rather than
  rediscovering this.
- **`tests/test-rvm-fixture-isolation.sh` is the guard, and it works by
  demonstration.** It plants an rvm on `PATH` — so it runs identically on a
  clean CI runner and on a developer's machine — and shows a naive composition
  finding it, a sanitised one not, and the real fixture surviving end to end,
  with a clean-host control so the assertion cannot be satisfied by a test that
  fails everywhere equally. Reverting the single fixed line turns it red; the
  control stays green throughout.

### `playwright=ON` — browser OS dependencies, baked at build time

- **A new `sandbox.conf` key: `playwright=ON | x.y.z | OFF`** (default `OFF`).
  It installs the operating-system packages Playwright's browsers link against
  — `libnss3`, `libgbm1`, `libatk-bridge2.0-0t64`, the font set — by running
  Playwright's own `install-deps` in a build layer. The package list is
  Playwright's, deliberately not ours: a hardcoded list rots against both new
  Playwright releases and Ubuntu's own renames, and the t64 transition already
  moved most of that set once.
- **It has to be a build-time key, and that is the whole point.**
  `entrypoint.sh` permanently drops root via `capsh --user=` before the agent
  shell exists, so the runtime-reconcile pattern the agent-tier tools and rvm
  use is simply unavailable here — nothing in the container can ever `apt-get
  install`. That is also why `npx playwright install --with-deps` fails inside
  the container: the `--with-deps` half needs root.
- **Only the libraries are baked; the browsers are not.** Those are ~500 MB
  downloaded at run time into `~/.cache/ms-playwright`, which `sandbox.sh` now
  group-mounts exactly as it does `~/.cache/qmd` — containers run with `--rm`,
  so without it every start re-downloads all of them.
  `allowlist-domains.d/playwright.txt` admits `cdn.playwright.dev` for that
  download, gated on `is_active` so a **pinned** version counts as on, not just
  the literal `ON`.
- **`/dev/shm` is the resource that actually bites, and `CONTAINER_MEMORY` does
  not govern it.** It is a tmpfs sized independently of the memory cgroup, so a
  container given 16g still gets Docker's 64m default and headless Chromium
  dies with `Target closed` — a message pointing nowhere near the cause. A new
  `CONTAINER_SHM_SIZE` variable sets it, and `sandbox.sh` passes `--shm-size=1g`
  automatically when the key is active and **nothing at all** otherwise, so
  every container that does not ask for Playwright composes the `docker run` it
  always did. Playwright's own docs suggest `--ipc=host` here; that shares the
  host IPC namespace and is not a trade this project makes.
- **`install-deps --dry-run` changed contract mid-development, which is why the
  case does not rest on it alone.** Three measurements, each on a real image:
  `playwright@1.58.2`, on a host with none of the packages installed, printed
  the `apt-get` command it would run and exited **0** without consulting dpkg;
  `playwright@1.62.1`, in an image with every package present, printed `All
  system dependencies are installed.` and exited 0; the same 1.62.1 with
  `libnss3` and `libgbm1` removed exited **1** naming them. So on 1.62 it is the
  dpkg-backed check its documentation describes, and on 1.58 it was not — and
  `playwright=ON` means *latest at build time*, so which contract an image meets
  depends on when it was built. Case `770-playwright-deps-present` therefore
  asserts primarily against `dpkg-query`, over a fixed set of packages measured
  to be installed by no other layer of the `native` variant, and adds
  Playwright's own verdict as a second assertion that reports explicitly when the
  installed version does not verify anything rather than counting that as a pass.
  The image records the resolved version at
  `/etc/ai-containers-playwright-version` so the case pins to what it was *built*
  against rather than to whatever is current.
- **Cost, stated rather than buried.** The deps for all three browser engines
  add several hundred MB, most of it WebKit's GStreamer and codec set, and the
  `native` image variant carries them so nightly actually builds the layer.
  `nightly.yml`'s cost-switch comment now names Playwright alongside
  `IT_RUBY_VERSIONS` as a contributor, and says which lever to throw first.

### The release title comes from the tag, like the notes already did

- **Every release published so far was titled `v0.6.0`, `v0.7.0`.**
  `release.yml` passed only `body_path` to `softprops/action-gh-release`, so the
  name defaulted to the tag string, and every descriptive title in this repo's
  history was typed in by hand afterwards — a manual step invisible until
  someone notices a bare title, and therefore one that gets forgotten. It now
  comes from the annotated tag's own message, so `git tag -a v0.8.0 -m "v0.8.0 —
  …"` supplies both halves and the tag is the single author of the release, the
  same principle `changelog-section.sh` already established for the body.
- **Absent is not the same as lightweight, and conflating them is the bug this
  is shaped around.** A lightweight tag and an annotated tag whose object was
  never fetched both yield an empty `%(contents:subject)`. If both fell back to
  the tag name, a shallow checkout would publish a bare title that looks exactly
  like a deliberate choice and nobody would learn the fetch was wrong. The two
  are told apart by the object's TYPE — `git cat-file -t` returns `tag`,
  `commit`, or an error — so a lightweight tag falls back, an empty message
  falls back, and a missing tag object **fails the release**. The checkout now
  passes `fetch-tags: true` for the same reason.
- **In a script, not three lines of YAML.** Nothing in the hermetic suite can
  execute a `run:` block, so logic living there is read but never run —
  `changelog-section.sh` was extracted for exactly that reason.
  `tests/test-release-title.sh` drives `release-title.sh` against real
  annotated, multi-line, empty-message, lightweight and absent tags in a
  throwaway repository, and one of its assertions checks **this repository's own
  most recent tag** carries a descriptive message, so the convention the script
  rests on cannot quietly stop being followed. 7 mutants, 7 killed.

## v0.7.0 — 2026-08-24

**A minor bump, not a patch, and the reason is `repo.sh reset`.** It is a
destructive command that now destroys *more*: it switches to the remote's
primary branch and deletes every other local branch, where before it reset
whichever branch you happened to be on and left the rest alone. It lists what it
will delete and flags branches carrying commits that are on no remote before
asking, so this is not silent loss — but it is a changed contract, and a patch
number would tell a reader they could skip these notes.

Two new commands ship (`extract-discovery.sh`, `ai-containers-report.sh`), and
`ai-containers-report.sh` reports its own repository's registry rather than
searching the filesystem.

### The suite runs a third time, with TMPDIR pointed at a symlink

- **CI is ubuntu-only, and that is a blind spot with a name.** macOS's temp
  directory is reached through a symlink — `/var` points at `/private/var` — so
  `mktemp -d` hands back `/var/folders/…` while anything canonicalising reports
  `/private/var/folders/…`. A test comparing one against the other passes in
  `suite` **and** in `suite-floor` and fails on every Mac. That shape has now
  cost this repo twice: 19 assertions in increment 4, and three more on
  2026-08-24 (`test-report.sh`, `test-docs-path.sh`, and the docs orphan gate).
  `suite-symlinked-tmp` runs the same suite with `TMPDIR` pointed at a symlink —
  a stand-in for a Mac, on Linux, in parallel with the other jobs so the gate's
  latency barely moves. `verify-on-host.sh` Phase 5 mirrors it, because
  `tests/test-layer-containment.sh` requires every PR-gate check to exist
  locally too.
- **Two things stop it becoming a green gate that gates nothing.** The CI step
  asserts its own arm is a symlink *and* resolves elsewhere before running
  anything. And `tests/test-symlinked-tmp-guard.sh` demonstrates the premise
  rather than describing it: a deliberately path-naive comparison must FAIL
  under the symlinked arm and PASS under an ordinary one, and a
  `p_realdir`-correct one must pass under both. The second half is the
  load-bearing one — without it, a fixture that failed for some unrelated reason
  would look like proof that the symlink was doing the detecting.
- **The witness can tell the two runs apart.** Phase 5 now invokes
  `tests/run-all.sh` twice, and both emit an identical `STUB:run-all.sh`, so
  that line alone would be satisfied by the ordinary run while the symlinked one
  had been deleted. `lib-verify-repo.sh`'s repo-script stubs now also record
  `STUB-TMPDIR:<name> <dir>`, and the registry row keys on the arm's name.
  Verified by deleting the symlinked run (caught) and by pointing it at a plain
  directory instead of the symlink (also caught) — the second being exactly the
  mistake that would otherwise leave the job green and inert.
- **Phase 5's copy is gated on the ordinary run having passed.** The two
  exercise one suite in two environments, so a suite that is already broken
  fails both and reports the same problem twice — into a verdict that counts
  failures rather than distinct phases, where one broken test would read as
  "2 phase(s)".
- **It does not replace running on a Mac, and the docs say so.** It catches the
  path-resolution class only. The GNU-vs-BSD class — `realpath -m
  --relative-to`, flags BSD does not have — is invisible to it, and was found by
  a real host run.

### Fixed — the two nightly failures

- **`models.inference.ai.azure.com` went NXDOMAIN and the firewall quietly
  stopped allowing GitHub Models.** GitHub retired that endpoint in favour of
  `models.github.ai`; the nightly allowlist-health job caught it on 2026-08-22
  and had failed every night since. This is the failure mode that job exists
  for: a dead allowlist entry is not harmless, it is a capability silently
  withdrawn whose only symptom is a tool that mysteriously cannot reach a model
  from behind the firewall. Every one of the 135 concrete hostnames across the
  fragments now resolves.
- **Case `710-agent-tools-reused-not-reinstalled` still asserted the npm
  layout.** Claude Code installs natively now, so `command -v claude` resolved
  while `~/.ai-tools/npm/bin/claude` was absent, and the case failed nightly
  from 2026-08-23 — correctly reporting that the file it expected was not
  there. It now keys on the native install, and **which artifact it watches is
  the whole question**: `~/.local/bin/claude` is re-created on every start by
  design (that directory does not survive the container), so its mtime can
  never show reuse; the `versions/` directory's mtime moves whenever any new
  version lands, so a self-update — which is not a reinstall of the group's
  tool home — would read as a failure. The version binary itself,
  `versions/<v>`, is group-mounted, written once by the install of that version
  and by nothing else, and is left untouched by a self-update. The version is
  resolved after the first launch rather than hardcoded, using the same
  `sort -V` selection `install_claude_native` uses, because 2.1.99 must not
  outrank 2.1.241.
- **When the case cannot find a native install it now names both layouts**, so
  a future fallback to npm is diagnosable from the failure message instead of
  from a guess.

### `reset` says what it did, in prose

- **The git helper's records were reaching the terminal raw.** A real run ended
  with `DELETED|throwaway`, `ON|master`, `AT|3500160`, `DELETED-COUNT|1` — the
  helper's machine-readable protocol, correct and honest and reading exactly
  like debug output that escaped. `reset_git` now captures that stream and
  renders it: `removed branch throwaway`, then `now on master at 3500160`.
- **A record it does not recognise is printed verbatim, not dropped.** The
  tidier-looking loop ignores unknown kinds, and would silently swallow the
  output of any record type added to the helper later. Silence is the one thing
  a destructive command must never report, so unknown records fall through to
  the terminal unchanged.
- **stderr is deliberately not captured**, so the helper's own `die` messages
  still arrive unaltered and immediately; `KEPT` (a branch git refused to
  delete) and `WARN` (a failed chown) are rendered *to* stderr for the same
  reason — they must not be lost in a successful run's output.
- The records themselves are unchanged: the tests read them, and
  `tests/test-repo-git-reset.sh` still asserts against the protocol rather than
  the prose.

### Fixed — extract-discovery could not find the capture in this repository

- **The launch directory is not always the directory the script ships in.**
  `extract-discovery.sh` looked for `.agent-discovery/` in `$PWD` and beside
  itself, on the reasoning that it ships next to `sandbox.sh` and that *is* the
  launch directory. True in a consumer project, where `runme.sh` cd's into
  `.ai-containers/` before launching — and false in this repository, where the
  engine sits at the repository root while the container is launched from the
  synced `.ai-containers/` working copy. The capture landed one level below
  everywhere the script looked. It now searches `./.ai-containers/` and the
  `.ai-containers/` beside itself as well. Reported from a macOS host against a
  real capture; no test had the base repo's shape, and the one that has it now
  needed a second fixture to be worth anything (see below).
- **The error listed the same directory twice.** In that same repository `$PWD`
  and the script's own directory are the same place, so both candidates printed
  identically — which reads as a bug in the error message rather than as an
  answer to the question. The candidate list is deduplicated.
- **A launch directory is now accepted as the argument.** Passing
  `.ai-containers/` is the natural thing to reach for, and being told there is
  no pcap *inside* it was a worse answer than looking one level down for the one
  that obviously is.
- **The first fixture for this could not have caught it.** Testing from the base
  repo's root exercises `$PWD/.ai-containers` and the script-relative
  `.ai-containers` at once — they are the same directory there — so either
  candidate alone still found the capture and deleting one went unnoticed. A
  second fixture stands in a *project* root with the script elsewhere, which is
  what tells the two apart; each candidate is now independently pinned, checked
  by deleting each in turn.

### `ai-containers-report.sh` reports THIS repo's projects

- **A new base-repo tool**, beside `project-init.sh` and `sync-to-projects.sh`:
  one row per project in this repo's `projects.conf`, showing its container
  group, network mode, CPUs, memory as limit/reservation/swap, the size of its
  `.agent-discovery`, and its path — each resolved from the project's own
  `sandbox.env` with `sandbox.local.env` overriding, the same precedence
  `sandbox-common.sh` applies. It is deliberately **not** in
  `AI_CONTAINERS_SHARED_FILES`: a project is a leaf with no registry of its own.
- **It does not search the filesystem.** It previously walked a configurable
  root to a fixed depth collecting every `project-init.sh` it could find, which
  answers a different question — "what does this whole machine have" rather than
  "what is this checkout responsible for keeping in sync" — and made the answer
  depend on where it was run from. To report another base you name it; the
  argument is a path, not a search.
- **The BASE column appears only when it distinguishes rows.** With one base it
  was the same 37-character string on every line; it is now stated once above
  the table. With several it returns, and the rows stay grouped by base.
  `--tsv` always emits it, because a machine-readable schema that changed shape
  with the argument count would not be one.

### Fixed — three defects in that script, two of which shellcheck found

- **Two `BASE_DIR` arguments concatenated into one nonexistent path.** The
  separator was `$(printf '\n')` — the empty string, because command
  substitution strips trailing newlines. Latent while a filesystem walk supplied
  the base list and nobody passed two; load-bearing the moment naming them
  became the only way to report on more than one.
- **A path containing a glob character was stripped wrongly.** `${_hp#$_from}`
  and `${_dp#$HOME}` leave the pattern unquoted inside `${…}`, where it is
  matched as a **glob**, so a project path containing `[`, `*` or `?` produced a
  mangled prefix strip. Both are now quoted.
- **`tr 'A-Z' 'a-z'` replaced with the POSIX character classes** — hygiene, not
  a third defect, and the entry says so because measuring it showed the claim it
  first carried ("makes the case folding correct outside ASCII") was false: GNU
  `tr` does not case-fold multibyte characters under `[:upper:]` either, and
  both forms produce identical output for every input tested. The change
  silences a shellcheck note in a file being rewritten anyway. The same
  spelling elsewhere in the repo (`sandbox.sh`'s git-URL host lowercasing,
  `tests/test-docs.sh`'s anchor generation) was left alone deliberately: a
  hostname is ASCII by protocol, and no tracked heading contains a non-ASCII
  letter, so neither can observe the difference.

### Documentation

- **The two workflows that verify nothing are now listed as such.**
  `docs/contributing.md`'s "What CI covers" table described three workflows;
  `release.yml` appeared only in prose further down and `update-nvm-version.yml`
  was undocumented entirely. Both are now in a second table, kept out of the
  first on purpose — listing a publisher and a dependency bumper as "coverage"
  would overstate what CI checks.

### `repo.sh reset` is a real reset

- **It lands on the primary branch, not wherever you were standing.** `reset`
  discarded local changes and reset the *current* branch to its upstream, which
  left you on whatever half-finished branch the volume happened to be on, with
  every other local branch still there. It now fetches (pruning), works out the
  remote's primary branch, checks that branch out at the remote's tip, cleans
  the tree, and deletes every other local branch.
- **The primary branch is asked for, never assumed.** It comes from the
  remote's own `HEAD` — refreshed with `git remote set-head origin -a`, so a
  default branch renamed since the clone is picked up — falling back to
  `origin/main`, then `origin/master`, then the checked-out branch. Nothing
  hardcodes `main`; a repo whose default is `master` or `trunk` lands on its own
  default, and a repo with no usable remote and a detached HEAD is left
  untouched with a message rather than reset onto a guess.
- **It tells you what it will delete before deleting it, on every run.** The
  summary names the branch it will switch to and each branch it will drop,
  marking those carrying commits that are on no remote, and raises a separate
  warning when there are any. It prints under `--yes` too — partly so that
  non-interactive runs leave a record of what went, and partly because the
  hermetic tier has no tty and could never assert a listing shown only at the
  prompt.
- **The listing is measured after the fetch, not before.** A read-only `inspect`
  pass does the fetch and reports the branches, and the destructive pass is
  handed the branch name that listing displayed rather than deriving its own —
  so what was approved is what happens. "Not on any remote" is
  `git rev-list --count <branch> --not --remotes`, i.e. against every remote,
  not just a configured upstream: a branch pushed under a different name is not
  reported as work about to be lost.
- **A failed fetch no longer stops the clean-up.** No network, no credentials,
  or a vanished remote warns loudly, does the local half, and reports `STALE`:
  the tree is clean and on the primary branch, at the remote tip as last
  fetched. `reset` could always be run offline and still can.

### The git half moved into its own file, to be testable at all

- **`repo-git-reset.sh`** is mounted read-only into the seed container instead of
  being embedded as a `docker run … bash -c '…'` string like `seed_from_git` and
  `sync_from_git`. Those are one git call each; this is a dozen, with branch
  detection, fallbacks and a destructive loop — and `tests/test-repo-destructive.sh`'s
  fake `docker` can only record the string, never run it, so every assertion
  about it would have been an assertion about configuration. As a file it runs
  directly against real repositories in `tests/test-repo-git-reset.sh`: real
  branches, real unpushed commits, real remotes (a local bare repo, so no
  network), with the offline path exercised by deleting the remote rather than
  by pretending. Mounting rather than baking it into `Dockerfile.seed` keeps
  every existing seed image working with no rebuild.
- **It is a hard member of `AI_CONTAINERS_SHARED_FILES`.** `repo.sh` mounts it
  from its own directory, so a project copy without it has a broken `reset` —
  the same class of dependency as `bash-floor.sh`.
- **The old reset coverage could not have noticed the git half disappearing.**
  `tests/test-repo-destructive.sh` asserted that `reset` removed the working
  copies and kept the base volume, and both stay true if the reset never
  happens; its fake `docker` answered `run` with silence, which would have sent
  every reset down the "no branch to reset onto" path with the suite green. The
  fake now answers the `inspect` call with a canned report, and five new
  assertions cover the helper being mounted, the inspect-before-destroy order,
  the primary branch being threaded through rather than re-derived, the summary
  and its warning, and the primary branch never appearing in the deletion list.

- **One defect, caught by the existing destructive tests within a minute of
  being written.** The summary line was built with an inline
  `$([[ -n "$stale" ]] && printf …)`; a command substitution's exit status
  becomes the status of the assignment containing it, so on every run where the
  fetch **succeeded** — the normal case — the non-zero status met `set -e` and
  killed the script.

### A script for the thing the discovery banner used to only describe

- **`extract-discovery.sh` turns a discovery capture into hostname lists from the
  host.** Discovery mode ends with a `docker run --rm --entrypoint …` line printed
  into a banner that has scrolled away by the time anyone needs it, carrying three
  things the reader has to get right — the image tag, the host path to mount, and
  the in-container capture path — all three of which are already knowable from
  where the script sits. It ships in `AI_CONTAINERS_SHARED_FILES`, so it lands
  beside `sandbox.sh` in every project, which is the launch directory itself, which
  is why the normal invocation is `./extract-discovery.sh` with no arguments at
  all. `entrypoint.sh`'s banner now names it first and keeps the raw `docker run`
  underneath, for a launch directory that has no working copy in it.
- **It also answers the question the extract only sets up: which of those
  hostnames restricted mode would still block.** That verdict is read out of the
  image's own baked `/tmp/allowlist-domains.txt` and
  `/tmp/allowlist-proxy-domains.txt`, applying the same two rules
  `capture-blocked-traffic.sh` applies at runtime — exact full-line match, and
  leading-`*` stripped and suffix-matched, so `example.com` is **not** covered by
  `*.example.com`. Reading the image rather than re-assembling the fragments is
  what makes the report unable to disagree with the running container; it also
  duplicates none of `build.sh`.
- **It deletes nothing by default.** The pcap is the only file here that reaches
  gigabytes and the only raw evidence, and re-extracting is possible exactly as
  long as it exists — so the default prints its size and the command to drop it,
  `--clean` removes it once the extract has succeeded (keeping the hostname
  lists), and `--discard` drops a capture you have decided not to analyse at all,
  prompting unless `--yes`. Both remove only the specific filenames inside that
  one directory, never `rm -rf` on a path handed in.

- **The mutation tier took the survivor count from 18 to 1.** Adding the script
  as an `EXECUTED-WHOLE` target generated 63 mutants, and the first run killed
  45 — every survivor an assertion that had not been written: the counts line
  nothing read, `--discard`'s exit status and its "freed" receipt, the
  confirmation prompt actually answered rather than declined, an empty capture
  directory, an image whose allowlists cannot be read, a comments-only proxy
  list (the configuration that once killed `capture-blocked-traffic.sh`
  outright), and every size branch above bytes. Nine assertions later, 62 of 63
  die. The last one is recorded in `tests/falsify/survivors.txt` as a GAP, with
  the reason it cannot be written here: it needs a file that exists and cannot
  be opened, and the suite runs as root, where mode bits deny nothing.
- **One of those survivors was a defect, not a missing assertion.** The two
  allowlist reads nested a command substitution inside a here-string word, whose
  exit status bash discards — so `read_from_image`'s `|| true` fallback was
  inert, and an image whose `cat` failed was indistinguishable from one whose
  allowlist was empty. Both now assign to a variable first, which is what makes
  the fallback observable at all.
- **Two defects were caught by its tests rather than by review, and one of them
  was in the test.** An unconfirmed `--discard` died instead of doing nothing:
  `read` fails at EOF, `set -e` turned that into an exit, and the "nothing
  removed" message never printed — so piping input, or answering with Ctrl-D,
  looked like a crash. Separately, the test invoked the script behind an `env`
  prefix carrying an array of per-call assignments, which
  `tests/falsify/derive-targets.sh` cannot see through: its `env` rule stops at
  the first token that is neither a flag nor an assignment, so the `bash` behind
  it was never found and the script classified as `NOT-EXECUTED`. It would have
  entered the mutation tier claiming no oracle, and every mutant would have
  "survived" a test that in fact kills them — the derivation was right that
  nothing it could see executed the file, which is exactly why the invocation is
  now a bare `bash <path>` at a command position.

### Release notes come from the CHANGELOG, and only one thing writes them

- **`generate_release_notes: true` is gone from `.github/workflows/release.yml`.**
  It published GitHub's list of merged pull requests — every branch that landed,
  none of them explained — and it **raced** with anyone who also ran
  `gh release create`, because both write the same body and neither waits for the
  other. v0.5.0's release still carries the generated block twice for that reason,
  and v0.6.0 needed a hand edit to remove a duplicated "Full Changelog" line. The
  tag push is now the only author: `changelog-section.sh` extracts the `## <tag>`
  section and the workflow publishes exactly that. `docs/contributing.md` says so
  in as many words, because the fix is only half mechanical — the other half is
  not running the CLI as well.
- **Four ways to publish a wrong release now fail instead.** A tag whose version
  has no section, a version with two sections, an empty section, and a section
  over GitHub's 125,000-character release-body limit each stop the workflow before
  anything is published, each naming what is wrong. The size ceiling is nearer
  than it sounds: v0.6.0's section is 92,088 characters, 74% of it, because it
  absorbed everything that had accumulated under `Unreleased`. A warning fires at
  80% so the next one is not a surprise.
- **The missing-version error lists the headings the file does have.** Without
  that, a typo and an unwritten section produce the same message, and the reader
  cannot tell which they have.

### Fixed

- **Two defects in the new script, both found by the mutation tier rather than by
  review — which is the entire argument for having one.** Its first draft looped
  with `while read … || [[ -n "$line" ]]` and `while [[ "$body" == *$'\n\n' ]]`.
  Negating either condition produces a *genuine infinite loop* — `read` fails at
  EOF with an empty line forever, and `${body%…}` strips nothing forever — so four
  mutants scored `UNPROVEN`-by-timeout rather than `KILLED` and left the measured
  set in silence. Every loop is now bounded by an array length. Separately, the
  trailing-trim assertion compared against `$(…)`, which strips trailing newlines,
  so it passed whether or not the trim had run and **survived** a comparison flip
  that disabled the trim outright; it now reads the file. `changelog-section.sh`
  is a falsify target: 49 mutants, 49 killed, 0 survivors, 0 unproven.
- **The script did not source `bash-floor.sh`**, so it could run under a bash
  older than the declared 5.1 floor while using `mapfile`, `printf -v` and array
  slicing. Caught by `tests/test-bash-floor.sh`, which is exactly the guard that
  exists for it.
- **An apostrophe in an error message defeated the falsify derivation.**
  `derive-targets.sh` tracks quote parity to decide what a script executes, and
  `GitHub's` inside a double-quoted string read as an unterminated single-quoted
  string — after which it stopped scanning and said so. It warned rather than
  guessing, which is why this is a one-word fix and not a silent gap in the target
  map.

## v0.6.0 — 2026-08-23

This section covers everything since **v0.4.1**. `v0.5.0` was tagged without
moving the then-`Unreleased` entries under a version heading, so a handful of
the items below shipped in that tag; they are left where they are rather than
split out retroactively on a guess about which was which.

### The falsify mutation tier — a test of the tests

`tests/falsify/` damages the code on purpose and asks whether anything notices.
It generates mutants of nine targets, runs each target's declared oracle set,
and scores every mutant **killed**, **survived**, or **unproven**. It runs on
every CI run and as Phase 6 of `verify-on-host.sh`: **264 mutants, 262 killed,
2 survivors, 0 unproven**, in ~76 seconds inside the container.

- **Every survivor is owed a classified ledger entry.** `tests/falsify/survivors.txt`
  distinguishes `GAP:` (no test kills it today), `EQUIVALENT:` (no test *could*),
  and `ENV-DEPENDENT:` (the verdict moves with the machine and neither reading is
  wrong) — different claims, and conflating them is how a ledger stops protecting
  anything. `check-ledger.sh` is the ratchet: an unclassified survivor, an entry
  for a mutant that no longer exists, and an entry for a mutant that is now killed
  each fail the gate. **There are two entries today and neither is a `GAP`.**
- **`UNPROVEN` is not `KILLED`, and it has three channels.** The oracle timed out,
  it printed `SCAFFOLD-FAILED:` (it could not set *itself* up), or it was killed by
  a signal — the OOM killer's signature on a memory-capped host. All three used to
  read as `KILLED`, which removes a survivor the ledger was owed and grows the
  coverage claim without growing the coverage.
- **A kill is only trustworthy if the oracle was green under the same load.**
  Control runs execute the *unmutated* code alongside the mutants; a failed control
  means the kill count cannot be believed, and the run now says *what* went red
  rather than only that something did.
- **An oracle must be observed executing its target.** The gate that enforces this
  found oracles that never ran the file they were named for — a mutant they could
  not possibly have killed was scoring as killed. Making a target's oracle a *set*
  rather than a single test turned eight real kills that had been reading as
  survivors back into kills.
- **Most of what the tier found were defects in the suite's own ability to fail**,
  which is what it exists for: an unchecked `mktemp -d` scored as a kill, four
  oracles that hung, kills arriving with no assertion, and a cluster of guards that
  could not fail at all.
- **The clock had to be fixed before the results meant anything.** Two timers
  measured the machine's load rather than the code under test, the watchdog paid
  three forks a second to read the clock, and `--jobs auto` counted a Mac's twelve
  efficiency cores as equals — the same corpus takes ~76s in the container and
  ~45 minutes natively on macOS, so a worker budget that over-reports costs real
  time. `--jobs auto` now reads the cgroup CPU quota and the performance-core count.

### Agent CLIs can update themselves again

Moving the agent tools to a runtime `~/.ai-tools` home traded the old rebuild
machinery for "each tool's own updater takes over". Three days later an unrelated
fix removed the npm prefix those updaters depended on. Neither half was in place
for the sixteen days between `bc2e551` and a user hitting it, and the documentation
kept promising the updater worked throughout.

- **Claude Code installs natively** into a group-mounted `~/.local/share/claude`,
  involving npm at no point — so `claude update` works and nvm's `nvm_die_on_prefix`
  never fires, keeping the `node=22,20` multi-version workflow intact. Verified
  end-to-end in a **restricted-mode** container: the install, the self-update, and
  `nvm use` afterwards.
- **Codex and Gemini have no self-updater at all**, so the reconcile updates them on
  every container start (~7s with a warm npm cache). **Copilot was never affected.**
  Each row of that table was established by running the tool in a container rather
  than reasoned from its install method — see `AGENTS.md`.
- **The install is no longer redone on every start.** The presence check keyed on
  `~/.local/bin/claude`, a launcher that dies with the container, instead of the
  group-mounted version tree that persists — so every container start re-ran
  `curl … | bash`.

### An image records which files built it, and the launcher checks

`./build.sh` stamps the image with a **payload digest** (the engine files that went
into it), a **config digest** (only the `sandbox.conf` keys that are build-time
inputs), the build time, and the source commit. `sandbox.sh` compares both on every
launch and names *which* drifted, because "you synced and did not rebuild" and "you
changed a build-time key and did not rebuild" send you to different places — even
though both end in `./build.sh`. The config digest deliberately ignores runtime-only
keys, so flipping a mode does not cry rebuild. An image built before this existed
carries no label and stays silent: absence is not evidence of drift.

### Documentation

- **The 1133-line README is now eleven task-oriented guides** under `docs/` —
  overview, getting started, configuration, groups, repos and mounts, security,
  agent tools, multiple projects, troubleshooting, resources, contributing — plus
  nine per-component pages under `docs/components/`. The root README is 86 lines
  and `docs/README.md` is the map.
- **A contributing page** (`docs/contributing.md`), because a green PR is not a green
  repository: it states the rules, what CI structurally cannot check (there is no
  macOS runner in any workflow), which `verify-on-host.sh` phases to run while you
  work versus before you open a PR, how to read a falsify result, and — measured —
  how long each takes, so nobody kills a 45-minute phase thinking it has hung.
- **Status is gated, not remembered.** Every spec and every backlog heading must say
  where it stands, and a check enforces it. A status nobody can see is a status
  nobody acts on, and one that is wrong is worse — that bookkeeping failure cost
  real work three times.
- Skip messages now say plainly when a check had nothing to check, rather than
  passing silently and reading as coverage.

### CI

- **Every job is pinned to `ubuntu-24.04`, never `ubuntu-latest`.** An unpinned
  runner is an unpinned toolchain underneath a blocking merge gate: what passes
  could change with nobody having edited this repo. Not hypothetical — `cd ""` is a
  silent no-op on bash 5.1 and 5.2 and an **error** on 5.3, so a label rolled onto a
  bash-5.3 image changes what the falsify tier reports. A test enforces that all
  pinned jobs name the *same* image, so "CI passed" keeps meaning one toolchain.
- **The lint job's `apt-get` is bounded and retried** (three attempts, five minutes
  each). It is the only network operation in the gate, and a mirror stall once left
  it running for 72 minutes against a normal 40 seconds. Both layers now report the
  shellcheck version they ran rather than pinning a number that can drift from the
  image.

### Added

- **`c-toolchain=ON`** keeps a C compiler in the finished image (`build-essential`
  plus the headers `ruby`/`db-clients` already pull in). Turn it on when something
  compiles *inside* the container — `go test -race`, cgo, a source-only wheel,
  `node-gyp`. Before this key there was no way to *ask* for a compiler: one arrived
  only as a side effect of an unrelated language runtime.
- **The runtime integration corpus is now 35 cases** with 35 known-bad mutations, one
  per case in every covered tier, so a new case with no mutation fails at review time.
- **`repo.sh` and the group isolation boundary are asserted**, on the volumes they
  destroy rather than on their exit codes — `rm`, `reset`, `gc`, `add`, `sync`,
  `reindex`.
- **The per-mode output mounts are now asserted** rather than assumed — restricted
  bind-mounts `.agent-blocked`, discovery bind-mounts `.agent-discovery` and arms the
  capture flag, open mounts neither. And the capability drop in **open** mode is
  checked by a case that actually launches open mode: the case named for that job had
  been launching discovery instead, so nothing verified it.

### Fixed

- **Two start-up warnings that were not true**, printed on every container start.
- **A lint that scanned nothing reported a clean bill of health.** The local lint also
  could not see a script you had just written — `git ls-files` skips an untracked
  file — so a new script was linted by CI and never by its author.
- **Phase 5's schema gate compared a commit to itself and reported OK**, and Phase 7
  linted only the engine directory rather than the whole repository.
- **`it_wait` bounded poll count, not wall clock**, so its timeout meant nothing on a
  loaded machine; and three 900-second waits polled a condition that had already been
  decided.
- **`api_get` returned a failed transfer's partial body** as if it were a response.
- **The isolation check stopped checking when `git` could not answer**, reporting an
  environment failure as repository contamination.
- **A fix verified on Linux had been red on macOS from the moment it merged**, because
  the assertion read the host's topology instead of fixing it. Assertions that touch
  the machine now stub it.
- **A host pointer no longer fights a mount that is already there**, and
  `project-init.sh` takes no arguments — the README had claimed otherwise since it
  was written.

### Undiscardable failure signalling in the stub-repo library

Closes all three open items in the follow-up backlog left by the layer-containment registry — the work the 2026-08-12 ruling scheduled before increment 5.

- **13 caller guards deleted, not policed.** `tests/lib-verify-repo.sh`'s `mk_repo` is invoked as `r="$(mk_repo 0)"` — a command-substitution subshell — so *nothing raised inside it can reach the caller*, whatever verb it uses. That is why 13 call sites each carried a hand-written `[[ -n "$r" ]] || { …; exit 1; }`, and why nothing policed the set: a 14th site needed no entry to go green. The backlog recorded three candidate fixes and two do not survive contact — `exit` inside `mk_repo` kills only the subshell, and enumerating call sites from source is a pattern match defeated by reformatting. So every check that can fail moved to **source time**, where a plain `exit 1` from a sourced file terminates the sourcing script, and the guards were deleted rather than kept under supervision.
- **The old idiom never exited at all.** Three guards used `return 1 2>/dev/null || exit 1`. In a sourced file `return` *succeeds* and returns immediately, so the `|| exit 1` half is never evaluated and the status lands on a `source` line nobody reads. That idiom only reaches its `exit` when the file is executed — which this one, by its own header, never is. All five negative cases in the new test are red against the pre-fix library, not the two the backlog predicted.
- **The library's first test.** `tests/test-lib-verify-repo.sh` drives every abort path by effect: a sentinel line after the `source` that must never print, plus the specific guard's own stderr message, so a case cannot pass because some *other* guard fired. Two positive controls are load-bearing rather than decorative — without them a library hard-wired to `exit 1` would satisfy every negative case.
- **A `git` probe at source time.** `mk_repo`'s stub repo must be a real repository with tracked files, because Phase 7 runs `git ls-files '*.sh'` against it. When git could not deliver that, Phase 7 failed with `bash -n parsed no files` — a *different* failure that still satisfies any assertion merely expecting the phase under test to fail, quietly converting a real test into a vacuous one.
- **`DOCKER_RUN_RC` was a knob nothing turned.** It appeared in exactly two places — the `docker` stub's own default and the `floor-suite` registry row — and no test set it, so `verify-on-host.sh`'s `hermetic suite at the declared floor exited` branch had never run and the registry's `rc_var` column was inert. The new case reads the variable's *name* from the registry, which makes the column load-bearing by effect: rename it in the stub and the assertion goes red at its cause, where asserting that two strings match would have passed while the branch stayed unexercised.
- **Two of this branch's own new guards were found defeatable in final review**, consistent with the four found the same way last increment. The `-f "$ENGINE_DIR/bash-floor.sh"` clause added mid-branch had no case at all — deleting it left all three consuming tests at `0 failure(s)`, and it bites the sibling port specifically, whose probe tests only for `verify-on-host.sh`. And the comment asserting `mk_repo` cannot print an empty path was false: an arg-less call leaves `$1` unbound, `set -u` kills the substitution, and that is the one thing the deleted guards caught which nothing else did. Fixed by *removing* the failure — the parameter now defaults — rather than by `${1:?…}`, which fires inside the command substitution and would have improved the error message while leaving `$r` empty. The invariant is now stated with its two residual routes named (unsetting `TMP` after sourcing; `set -e` **combined with** `shopt -s inherit_errexit`, since errexit alone does not reach inside a command substitution) rather than absolutely.
- **`git -C ""` is a no-op since Git 2.9**, so a control probing an empty `$r` would have been answered by the *ambient* repository. Not defeated in practice — a sibling condition caught it — but it is the same shape as `cd ""` succeeding and staying put, which in this repo once committed an entire real working tree under a fake identity. Now gated on a non-empty path.
- **The registry's `-` rc_var sentinel no longer indirects through `$-`.** `${-}` is not an undefined variable — it is the shell's own option flags — so `${rc_var:-0}` and `${!rc_var:-0}` turned a row declaring "no canned exit code" into `exit huB`, dying with `numeric argument required` and reporting 2. Deferred once as unreachable (the only `-` row is `kind=probe`, which neither stub loop touches) and then fixed anyway, because the registry exists precisely so a new row can be added *without* reading `lib-verify-repo.sh`, and `rc_var=-` on a `repo-script` or `path-bin` row is the natural thing to write. Both stub kinds needed it and needed it differently — a path-bin stub is written at source time and reads the variable when it *runs*, a repo-script stub is written inside `mk_repo` with the value already resolved — so a fix to one form would not have fixed the other. Each form is demonstrated failing on its own.
- **One minor closed as recorded rather than in code**, so the accounting reconciles against an enumerated list: `_gitprobe` leaking into the sourcing namespace. Not a defect — `lib-verify-repo.sh` is a sourced script, not a function, so `local` is unavailable and *every* source-time variable is a global by construction (`_n_pathbin`, `_n_reposcript`, the eight read-loop columns, `WITNESS_LOG`); the `_` prefix already marks them, and singling one out would be inconsistent rather than cleaner.

### Layer-containment registry, and the nightly checks leg

- **One registry replaces three hand-maintained lists.** `tests/layer-checks.conf` declares each hermetic check once — its CI step, how it is stubbed, and the witness line proving it ran. `tests/lib-verify-repo.sh` builds stubs from it and `tests/test-layer-containment.sh` asserts witnesses from it, replacing two independent lists plus a per-job step-count baseline. Adding a fourth CI job produced **zero failures** before this change; the job list is now derived from the workflow file, and every step must classify as a registry check or as declared setup with a stated reason.
- **`nightly ⊇ PR` now holds over checks, not only over integration cases.** `suite`, `suite-floor` and `lint` moved verbatim into `.github/workflows/hermetic-checks.yml` (`on: workflow_call`), called by both `tests.yml` and `nightly.yml`. Measured at 2¼ runner-minutes; duplication, not cost, decided the shape. Nightly's caller is schedule-gated so mutation dispatches — which break the tree on purpose — do not bury their own signal.
- **The floor's test image is declared with the floor.** `bash-floor.sh` gains a map keyed on the declared floor, so raising it without extending the map yields the empty string and fails loudly rather than running the "floor" suite at the wrong bash. The floor stays **5.1**: at 5.2 the `suite-floor` job would run ubuntu:24.04's bash 5.2.21, identical to what `suite` already runs on ubuntu-latest, returning the floor to *asserted* rather than *tested*.
- **The last two guards that could not fail are now demonstrated failing** — `bash-dialect-lint.sh`'s "examined no files" refusal and `verify-on-host.sh`'s "bash -n parsed no files" branch. Both were correct; neither had ever run.
- **Eight further parked defects cleared**: `EXTRA_MOUNTS`/`PREVIEW_PORTS` glob expansion, the GNU `stat -f` fallback trap, `xargs` without `-r` double-counting one failure, Phase 7's silent success, `boot_case()`'s unreachable branch, `test-parsers.sh`'s divergent fixture list, a stale "only remaining phase" comment in `verify-on-host.sh`, and three drift-prone `IT_SOURCE_ONLY` comments now cross-referenced to each other.
- **The eleventh, closed as recorded rather than in code.** Spec §6.11 (report-hygiene nits in increment 4's task reports) has nothing to change in code — those reports are historical artifacts in `.superpowers/sdd/2026-08-11-execution-layers-and-portability/`, already written and already reviewed, and editing them now would falsify the record rather than correct it. Noted here so the "none dropped" rule has a visible resolution for all eleven parked items, not ten and a silence.

### Fixed

- **The nightly `packages` job could not fail, and never had.** `verify-on-host.sh` recorded a failed phase by *printing* it: Phase 1 printed `PHASE 1 exit: N`, Phase 2 printed `BUILD FAILED`, Phase 3 set a variable it used only to decide whether to keep the image, Phase 4 printed `PHASE 4 exit: N`, and the script's last statement was a `printf`. So `PHASES="1 2 3" bash ./verify-on-host.sh` — the whole of the nightly packages job in both repos — exited 0 whatever happened, and every green night since increment 1 wired it in proved only that the runner could reach the checkout. The root cause is a conversion that was never made: the script was born (`08ea799`) as a human-read **diagnostic**, something you run, read and paste back, and was later reused as a **gate**. A report says what it saw; a gate has to be able to say no. Phases now record into a failure ledger, still run independently (one broken phase must not hide the state of the other three), and the script prints a `RESULT:` verdict naming each failed phase and exits 1. Pinned by `tests/test-verify-exit-code.sh`, whose last assertion strips the verdict block back out and requires the same failing run to exit 0 again — without that, the file would have passed against the broken original.
  - **Two dead checks found in the same pass, both the same shape.** Phase 2's tool loop printed `MISSING` and returned 0, so an image that built successfully but produced none of `psql`/`mysql`/`mongosh`/`convert`/`wkhtmltopdf`/`gcc` completed the phase quietly. And both phases tested the wrong process's status: `if out="$("$c" --version 2>&1 | head -1)"` reports **`head`'s** exit code, and `head` succeeds on the empty output of a binary that just died — so Phase 3's `PRESENT BUT FAILED TO RUN` branch, written specifically to catch a `bundle` killed by an rvm-rewritten `#!/usr/bin/env ruby_executable_hooks` shebang, was unreachable. Both now capture first and `head` afterwards, and Phase 2 distinguishes absent from present-but-broken rather than calling both `MISSING` — the two send you to completely different places. `bundler` is reported but not required — a caution that turned out to rest on a wrong premise, corrected here rather than left standing: `link-default-ruby.sh` has linked `ruby`/`gem`/`bundle`/`bundler`/`rake`/`irb`/`erb` since the day it was written (`aad8ab2`), all **seven**, so `bundler` was always part of the contract. The five-name list propagated from `AGENTS.md` into this entry and from there into increment 3's spec and plan before a case that actually asserts the property (`740-ruby-bootstraps-and-resolves`) counted them against the script.
  - **Phase 3's "aborting phase 3" did not abort.** When `rvm_volume_ensure` produced no volume name the script printed that line and fell through to `docker run -v :/home/<user>/.rvm`, which docker rejects — so the phase died several steps later for a reason unrelated to the one just printed. The remainder of the body is now guarded.

- **`sync-to-projects.sh` deleted every provisioned project's `runme.sh`.** `migrate_launcher_naming()` removed any `runme.sh` that lacked an `export IMAGE_NAME=` marker, treating the absence as proof of a stale pre-migration "engine" file. But the *current* thin `runme.sh` carries no such marker either — only the retired "fat launcher" era did — so the discriminator could no longer tell "current and correct" apart from "genuinely stale", and every sync silently deleted the project's real launcher. The delete/rename steps are removed outright rather than narrowed: the migration window they served has long closed, and `sync_project` now only repoints a stale `./runme.sh` self-call to `./sandbox.sh` in place. A project still on the genuinely old two-file layout (`runme.sh` = engine plus `<project>-container.sh` = launcher) is now left untouched rather than half-migrated; re-run `project-init.sh` for those.
- **`migrate-runme.sh` could not complete a single run.** It sourced `project-init.sh` to reuse an `emit_launcher()` that had never existed, on the stated assumption of a `BASH_SOURCE` guard that also did not exist. With empty stdin — its documented non-interactive use case — `project-init.sh`'s first `read -r -p` returned non-zero on EOF and `set -euo pipefail` killed the process at the `source` line: **exit 1, no output at all**, and because the `source` preceded argument parsing, `--dry-run` could not prevent it. With non-empty stdin the full interactive wizard ran as a side effect, rsyncing files and appending to `projects.conf` for whatever path happened to be on stdin. `emit_launcher()` is now a real function in `project-init.sh` (one launcher template, two callers, no drift), `valid_group_name()` moved alongside it, and a sourcing guard sits after the globals a caller needs and before the first prompt. Pinned by `tests/test-migrate-runme.sh`, which fails 11 assertions against the pre-fix code.
- **Backups could clobber each other.** `project-init.sh`'s `sandbox.local.env.pre-init` and `migrate-runme.sh`'s `*.pre-migrate` both used a fixed filename and a plain `cp`, so a second re-init overwrote the first backup and the original hand-edited `EXTRA_MOUNTS`/`REPOS` became unrecoverable, with no warning printed either time. Both now fall back to a timestamped name when a backup already exists, and the `.gitignore` patterns cover the timestamped and `*.pre-migrate` forms.

- **The blocked-traffic capture had never recorded a single IPv4 packet.** `capture-blocked-traffic.sh` read tshark's output with `IFS=$'\t'`. Tab is IFS *whitespace*, so bash collapses runs of it and strips leading/trailing separators; `ipv6.dst` is always empty for an IPv4 packet, so `"IP\t\tPORT\t"` parsed as `dst4=IP`, `dst6=PORT`, `tcp_port=""`, and the next line's `[[ -z "$dst" || -z "$port" ]] && continue` discarded **every** packet. The DNS-map builder had the same defect, which also made self-healing unreliable. Both parse sites now use `tshark -E "separator=|"` with a matching `IFS='|'`, which preserves empty fields. This is the *second* bug in this file: fixing the earlier `grep|grep` startup death let the daemon reach `init_output_files`, so it started, announced itself, and created all three output files — while silently recording nothing. Any check based on those files existing reported it healthy.
- **A baked npm prefix broke `nvm use`.** `/etc/skel/.npmrc` carried `prefix=${HOME}/.ai-tools/npm`, and nvm's `nvm_die_on_prefix` check **fails** `nvm use <version>` outright rather than merely warning, which broke the multi-version `node=22,20` workflow `sandbox.conf` advertises. `agent-tools-reconcile.sh` now passes `--prefix` per invocation (nvm inspects `.npmrc`/`$PREFIX`/`$NPM_CONFIG_PREFIX`, never a command's own flags), and a baked `npm-agent-tools` shell function preserves the `npm update -g` self-update workflow.
- **Discovery mode announced nothing.** It is the only mode combining unrestricted egress with a pcap that persists on the host after the container exits, and it was the only mode without a startup banner. It now states both facts plainly, and a test asserts all three modes announce themselves.
- **Removed three dead allowlist domains** — `cdn.azureedge.net`, `dist.sdkman.io`, `download.sdkman.io`. All NXDOMAIN: historical delivery paths that moved to GitHub releases, which is already allowlisted. `refresh-ipset-allowlist.sh` resolved them at every container start, warned, and admitted nothing.
- **rvm's prebuilt-binary mirrors were blocked** — all THREE of them, though the first fix only caught two. rvm HEAD-probes every mirror in its `config/db` on every `rvm install`, whichever Ruby you asked for: `rvm-io.global.ssl.fastly.net` (both `-` and `_` spellings — identical addresses, but self-healing matches by **name**), `rubies.travis-ci.org`, and `repo1.maven.org` under `maven2/org/jruby/jruby-dist`. The last is Maven Central, because that is where JRuby is published, and rvm asks it for CRuby too — installing 3.4.5 issues a HEAD for `…/jruby-dist/ruby-3.4.5.tar.bz2`, which cannot exist. Blocking them was never fatal (rvm compiles from source instead) but each cost a 5-second stall per address and left a permanent `blocked-domains.txt` entry that read like a misconfiguration. `repo1.maven.org` is listed in **both** `rvm.txt` and `openjdk.txt`: the latter is only assembled when a JVM key is set, so a Ruby-only image would never get it from there — which is the configuration it was found in.
  - **How the third one hid.** The first pass through `config/db` grepped for `fastly|travis|binary`, which matched the two mirrors whose hostnames contain those words and silently skipped `rvm_remote_server_url1=https://repo1.maven.org`, whose hostname contains none of them. The grep pattern chose the answer. Rediscovering it took two verification rounds, three intermediate PRs and a live `/proc/net/tcp` probe that caught the `curl` mid-flight — after a filesystem grep had pointed at pyenv's jython definitions, which turned out to be an unrelated file that merely mentions the same host. The comment in `rvm.txt` now says to grep the field name `rvm_remote_server` and read every hit.

- **A hard-blocked destination could not be checked.** `verify-on-host.sh` reported bare domain names under "add these to the allowlist", and the name comes from a reverse lookup through the sniffed DNS map — IP → first-seen name — so a CDN address shared by several zones can be labelled with a domain nothing ever contacted. One run reported `repo1.maven.org` blocked inside a Ruby-only container with no JVM component enabled, and the claim was neither confirmable nor refutable. The report now prints the destination IP, port, hit count and first timestamp from `blocked.log` beside each name, states that the name (not the address) is the inferred part, and the phase keeps `blocked.log` in `~/.cache/ai-containers-verify/last-blocked/` on **success** as well as failure — its own cleanup used to delete the only record of what the firewall dropped.
  - **Follow-up: the report now dumps the container's own lookup tables too.** Naming the address was still not enough to close `repo1.maven.org` — it reproduced identically in a second repo, on a container with every JVM key empty, so no SDKMAN, no `maven`, and no `openjdk.txt` in its allowlist. Two questions decide such a case and neither could be answered after the fact, because both tables die with the container: whether the name is allowlisted in **this** image (`/tmp/allowlist-domains.txt`), and which names the container actually resolved to the dropped address (the DNS map in the root-only `/run/agent-blocked-internal/`). Phase 3 now reads both over `docker exec` while the container is still up, prints the allowlist verdict and every name mapped to each dropped IP, and lists every name the container resolved during the run. One `PHASES=3` run now says what asked for the address instead of only where it went.

- **`verify-on-host.sh` reported `Phase 3 FAILED` for runs that passed.** "Keep the artifacts" and "the phase failed" shared one variable: the failure path set `KEEP_RUBY_IMAGE=1`, and the cleanup block read that same variable as the verdict. So setting `KEEP_RUBY_IMAGE=1` to probe a *healthy* image printed `Phase 3 FAILED — kept for re-probing` directly beneath a log showing Ruby installed, every binary resolving through a non-login shell, and the second run reusing the volume with no recompile. A verifier that reports the opposite of what it just measured is worse than one that reports nothing — it is "green because we did not look" inverted, and it teaches you to distrust the line that matters. The two reasons are now separate variables, the banner is chosen by the failure flag alone, a kept-but-passing run says so and names `KEEP_RUBY_IMAGE` as the reason, and the variable is documented as a supported input. Pinned by `tests/test-verify-on-host-keep.sh`, which fails three assertions against the pre-fix code.

### Documentation

- **Corrected the discovery-mode `NET_RAW` claim.** `AGENTS.md` and `entrypoint.sh` stated that discovery keeps `NET_RAW` so the sandbox user can run tcpdump. It never did: `capsh --user=` setuids from root, and the kernel clears the permitted and effective capability sets on that transition unless `PR_SET_KEEPCAPS` is set (`capsh --keep=1`, which is not used). So `--drop=cap_net_admin` and `--drop=cap_net_admin,cap_net_raw` are equivalent. Fixed the documentation rather than the code: the pcap daemon starts as root *before* the exec and needs nothing from the agent shell, so granting the agent raw-socket access to make a comment true would widen its capability surface for a convenience nobody has asked for.

### Added

- **A runtime integration test suite** (`tests/integration/`), 16 cases covering all three network modes, the blocked-traffic capture tier, self-healing, capability drops, and allowlist delivery. Cases assert **effect, not configuration** — they observe from outside the container whether the packet arrived, the file exists, the log line is present. `tests/test-entrypoint-wiring.sh` asserts the capture daemon is *wired into* `entrypoint.sh`, and it passed every day of a months-long outage, because the wiring was correct and the daemon died after being started.
  - Cases declare `tags:` and `requires:` in header comments; `tests/integration/run.sh` detects capabilities and selects. **Selection and skipping are reported as separate counts**, and `--require <tag>` makes a skip inside the selected set fatal — a case that cannot run is never counted as a pass. A run that selects *nothing* fails outright.
  - Every security case has been **demonstrated failing** against a known-bad configuration, including against the two real pre-fix daemons, which are kept as fixtures in `tests/integration/fixtures/` and must not be repaired or consolidated.
  - CI runs the `fast` tier on every PR and the whole corpus nightly, so a case excluded on cost is still a case that runs. The nightly also checks that every domain in `allowlist-domains.d/` still resolves.
- **Integration suite, increment 2** — eleven cases covering **mounts, container groups and volume lifecycle**, the domains increment 1 deferred. They test the launcher, not just the image: `launcher_up` drives **the real `sandbox.sh`**, because every mount decision lives there and a harness that recomposed those `-v` flags would be testing the recomposition. The hermetic fake-`docker` tests stay — they assert the argument string, which is the right check for "did the launcher decide `:ro`" and no check at all for "is it read-only in the container the agent gets".
  - `400` a `:ro` repo refuses the agent's writes while its `:rw` sibling accepts them, on **both** backends (bind, as Linux `auto` resolves; volume, as macOS always does). `410` the agent shell starts in the selected workdir and can write there — including the bare `/workspace` umbrella, which belongs to root until `chown_workspace_root` fixes it. `420` a `/workspace` name collision is refused **before any container starts**. `440` `PREVIEW_PORTS` actually publishes.
  - `430` closes a real gap left by increment 1: every capture case so far read its evidence with `docker exec`, **inside** the container, so all of them stay green when the host bind mount is wrong and the operator's `.agent-blocked/` is empty. That is the motivating incident one layer out — the record exists, nobody can see it. `430` only reads the host filesystem.
  - `500` one group's agent credentials are invisible from another group's container, asserted in both directions with a marker per group, because "B cannot see A's token" is also true when nothing is mounted at all. `510` what the agent writes to `~/.claude` survives into the group directory on the host, owned by the invoking user.
  - `600` a `:rwcopy` write stays in the per-workspace working copy and never reaches the shared base volume. `610`/`620` `group.sh rm` removes directory **and** volume and refuses while a container holds it; `gc` collects the orphan and leaves live groups and repo volumes alone. `630` the group's rvm home is a named volume the agent can write to (`chown_rvm_root`).
  - **`tests/integration/docker-shim.sh`** makes this possible without a test-only code path in a security-relevant launcher: a pass-through `docker` on `PATH` that rewrites the launcher's `-it` to `-d -i` and adds a `--name`/`--label`. `sandbox.sh:768` is the only `docker run -it` a launcher run can reach, and `tests/test-integration-shim.sh` pins that premise by file:line. `launcher` is a **probed** capability, so a machine that cannot drive the shim SKIPs those cases by name instead of failing them as if mounts were broken.
  - **`tests/integration/mutations/` + `mutate.sh`** turn the authoring rule — *not accepted until demonstrated failing against the known-bad configuration* — from prose into a mechanism. Increment 2's known-bad configurations live in production files, so they are patches, one per case, applied and reverted by `mutate.sh`. Patches rather than `sed`: a patch that no longer applies is a loud failure, while a stale `sed` matches nothing and reports success. `tests/test-mutations.sh` enforces both directions — every patch still applies, **and** every `mounts`/`groups`/`volumes` case has one, so a case added without a mutation fails at review time rather than sitting green forever.
- **Integration suite, increment 3** — seven cases covering the **`packages` tier**: the agent-tier tool installs, the native package builds, and the Ruby/rvm bootstrap that `verify-on-host.sh` used to check as Phases 1-3. Those phases are now **deleted**, not kept alongside: two implementations of one property drift, and the one that is not in CI is the one that rots. The corpus now runs the identical checks on Linux CI and on a macOS + Colima workstation, from the same case files.
  - The tier needs images that actually have those components on, so `run.sh` gained **image variants** — `agents` (the six agent-tier keys, plus `node=22,20`) and `native` (`db-clients`, `imagemagick`, `wkhtmltopdf`, `ruby`, so `KEEP_BUILD_TOOLCHAIN` is kept). The split is the one the **Dockerfile itself** makes: an image that strips `build-essential` versus one that keeps it. A case picks its variant with an `# image:` header; the runner builds each selected variant once, runs its cases, and reclaims it before the next, so peak disk is one image rather than three.
  - `700` every enabled agent-tier tool resolves and runs in a **non-interactive, non-login** shell — the shape `link-agent-tools.sh` exists for, and the one a `docker exec -T … bash -c` from CI actually uses. `710` a second container in the same group **reuses** the group-mounted `~/.ai-tools` instead of reinstalling (asserted on the binary's mtime, not on a log line). `720` `nvm use 20` and `nvm use 22` both succeed, which a baked npm `prefix` would fail outright — the defect that shipped.
  - `730` `psql`/`mysql`/`mongosh`/`convert`/`wkhtmltopdf`/`gcc` all run on the `native` image. `740` rvm bootstraps into a cold group volume and all **seven** linked binaries resolve non-interactively. `750` with two versions configured, both install and a project's `.ruby-version` selects the non-default one. `760` a second launch in the same group does **not** recompile — the rvm named volume, the fix for the macOS virtiofs `tar` failure, verified by effect.
  - Each of the seven has been **demonstrated failing** against a patch in `tests/integration/mutations/` that restores the real defect it guards, and each failure was compared against a prediction written *before* the run — looking for red is not the same as checking that the right thing went red. For 710/720/730/750/760 the case's unaffected assertions still passed, which is what separates a targeted demonstration from a case that merely falls over. For 700 and 740 there were no unaffected assertions to survive: their patches remove `link-agent-tools.sh`'s and `link-default-ruby.sh`'s symlinks, and every assertion those cases make goes through exactly that provider — so a wholesale failure *is* the targeted result, not a sloppy one. Two of the seven needed isolating dispatches after one mutation was found to mask another through a shared readiness gate.
  - `verify-on-host.sh` is now Phase 0 (an environment banner) plus Phase 4 (the corpus). Its `PHASES` input is validated against the phases it actually has, so a stale `PHASES="1 2 3"` is a recorded failure rather than a silent no-op that exits 0 having verified nothing.
- **Integration suite, increment 3 — follow-up: the fourteen parked minors.** Every finding the increment-3 reviews deferred, cleared in one pass. The two that were more than hygiene:
  - **Case `730`'s `gcc` assertion could not fail for the reason it was written for.** Its header claimed that if the Dockerfile ever stripped the build toolchain despite `KEEP_BUILD_TOOLCHAIN=1`, "nothing else in this corpus would notice" — and the corpus did not notice either. Measured, not argued: a mutation making the restore layer unreachable while `build.sh` still passes the flag left the case passing all six assertions. `gcc` survives `apt-get purge --auto-remove build-essential` on its own, because build-essential is a metapackage and `--auto-remove` keeps what other packages still need. The discriminating fingerprint is `libyaml-dev`, which appears exactly once in the Dockerfile — in that restore layer — so `/usr/include/yaml.h` is present if and only if it ran; it is also the header rvm needs to build psych, which is why a stripped toolchain really surfaces as a Ruby bootstrap failure rather than a missing compiler. The case now asserts it, and the mutation's header keeps the record of the attempt that did not demonstrate rather than quietly presenting the second one as the first.
  - **`assert_runs`'s "present but FAILED TO RUN" branch has now fired against a real rvm binstub.** The new `745-ruby-hooks-not-exposed` mutation removes `link-default-ruby.sh`'s `ruby_executable_hooks` exposure and its wrapper fallback — the state the file shipped in before those blocks were added — and case `740` reports `bundle` and `bundler` present-but-not-running while `ruby`/`gem`/`rake`/`irb`/`erb` still pass. That branch had hermetic vector coverage but no proof a container could produce the state, and its predecessor in `verify-on-host.sh` was unreachable for its whole existence.
  - Two mutation **ids** renamed to stop naming defects their patches do not create (`730-toolchain-stripped` → `730-db-clients-not-space-split`, `740-rvm-bind-mount-restored` → `740-default-ruby-not-linked`); the `# what:` headers were always accurate, only the filenames lied, and nothing enforced them.
  - `run.sh`'s `IT_SOURCE_ONLY` guard now refuses when the script is **executed** rather than sourced, instead of falling through `return` into a real image build. `mutate.sh`'s mid-batch rollback reports a failed reversal instead of swallowing it, names what it undid, and leaves `.applied` describing the tree; `revert` clears a state file whose patch is already absent rather than failing and blocking the next `apply` — a branch switch between demonstrations is ordinary, and this had already cost two wasted CI dispatches. The forensics report recognises IPv6 literals as addresses, and its blocked-ips merge no longer fabricates its target from a zero-byte source.
  - Declined, with the reasoning recorded in the code: `detect_caps`' real `curl https://example.com`. A cheaper probe either answers a narrower question than the capability claims or risks a false negative that `--require packages` turns into a red nightly blaming the wrong thing. A slow honest probe beats a fast one that cannot fail.
- **`tests/test-exec-bits.sh`** — guards the executable bit on the scripts that are *run as programs*, which is the fifth-plus recurrence of this defect here. The existing guard covered only `tests/integration/fixtures/`; the two classes that actually broke did not. A workflow step running `./tests/run-all.sh` with no interpreter dies with exit 126 the moment that file is `100644` (this shipped, and needed its own PR), and a `COPY` into `/usr/local/bin/` whose `chmod +x` was forgotten yields a container that starts normally and silently never refreshes the ipset or captures blocked traffic. Both sets are **derived** — from the workflow files and from the Dockerfile — so a new step or a new `COPY` is covered the day it is written; a hardcoded list would go stale exactly when it mattered. Working-tree mode and git index mode are checked separately, because `git update-index --chmod=+x` flips one and a later `git add` silently undoes it. Demonstrated failing against all three mutations.

### Breaking

- **BREAKING: The six agent-tier tools (Copilot CLI, Claude Code, Codex CLI, Gemini CLI, `graphify`, `vale`) moved from baked, unpinned build-time installs to a per-user `~/.ai-tools` installed at container runtime, and the periodic agent-refresh mechanism is removed.** Nothing agent-tier is baked into the image anymore — only scaffolding (an npm prefix, and `PATH`/`uv` env in `/etc/profile.d/ai-tools.sh`) ships in the build. At container start, `agent-tools-reconcile.sh` (sandbox user, `flock`-guarded against concurrent same-group starts) installs whichever enabled tool (`AI_RUNTIME_TOOLS`, derived from the existing `sandbox.conf` agent/`graphify`/`vale` keys) is missing from the group-mounted `~/.ai-tools` — **install-if-missing only**; keeping a tool current afterwards is that tool's own job (its own auto-updater, `npm update -g`, `uv tool upgrade`, …), which now works because the install lives in a user-writable directory instead of a root-owned image layer. `link-agent-tools.sh` then symlinks each installed binary onto `/usr/local/bin` (root, after the reconcile) so non-interactive, non-login shells resolve them too. Because the tool home is group-mounted like the agent dotfile dirs, an install is shared by every project using that group and persists across container restarts and rebuilds. This retires the entire `AGENTS_CACHE_BUST` build-arg / `.agents-cache-bust` persistence mechanism and the `AGENT_REBUILD_MAX_AGE_HOURS`/`AGENT_REBUILD_ACK`-driven staleness prompt in `sandbox.sh` — there is no longer a periodic "image is N hours old, refresh the agents?" rebuild step, and no build-arg to bust. **Kiro CLI** and every `tools.d`-described tool (`dtctl`, `dtmgd`, `acli`) are unaffected: they remain baked into the image at build time and refresh the same way any other baked component does — `./build.sh --no-cache`, or by pinning an exact version where the tool supports it (`dtctl=x.y.z`/`dtmgd=x.y.z`).

- **BREAKING: Ruby moved from a baked, single-version system rvm to a per-user `~/.rvm` installed at container runtime, and `rails=` is removed.** `ruby=` now accepts a **comma-separated list** of versions (e.g. `ruby=3.3.6,3.4.5`), exactly like `node`/`python`/`openjdk` — handy for migrating a project between Ruby versions. rvm itself, every configured Ruby version, and installed gems now live in the container-group-mounted `~/.rvm` (one more entry in the group home-dir mount list, alongside `~/.claude`/`~/.codex`/`~/.gemini`) instead of being baked into the image at build time. An additive reconcile at container start (`rvm-reconcile.sh`, run as the sandbox user, `flock`-guarded against concurrent same-group starts) installs any configured-but-missing version: the first start after adding a version compiles it from source (can take a few minutes), every later start is instant, and nothing is ever removed, so rubies and gems persist per group and accumulate across runs. `restricted` mode allowlists the Ruby-source hosts this needs (`cache.ruby-lang.org`, `www.ruby-lang.org`, alongside the existing RubyGems hosts). The `rails` key is removed entirely — Rails is an ordinary per-project gem installed with `bundle`/`gem install`, and never needed its own build-time key. `sandbox.conf` schema bumps to **v4**; the new `migrations/004-drop-rails.sh` hook strips a synced project's old `rails` line automatically (idempotent, comments/other keys untouched) — see [sandbox.conf schema versioning](#sandboxconf-schema-versioning). After the reconcile, the entrypoint (as root) symlinks the default Ruby's `ruby`/`gem`/`bundle`/`bundler`/`rake`/`irb`/`erb` onto `/usr/local/bin` (`link-default-ruby.sh`) so they resolve in **non-interactive, non-login** shells too — e.g. `docker exec -T <container> bash -c "bin/rails runner …"`, which otherwise got `command not found`; these expose the **default** Ruby only, and per-project gemset selection still comes from a project's `.ruby-version` via a login shell. If a requested version fails to install (every attempt, including the `rvm get stable` retry), reconcile now logs a clear `FAILED: ruby-<version>` line and sets the default to the first version that actually installed, rather than pointing it at a missing one.

- **BREAKING: `runme.sh` renamed, and the per-project launcher reclaims the name.** The run-the-container engine is now **`sandbox.sh`** (same CLI: `restricted` / `discovery`). The generated per-project launcher, previously `<project>-container.sh`, is now **`runme.sh`** — a single, stable entry point across every project. Running `./sync-to-projects.sh` **auto-migrates** existing projects: it removes the old-engine `runme.sh`, renames `<project>-container.sh` to `runme.sh`, and repoints its internal call to `./sandbox.sh` (idempotent). If you invoke the engine directly, use `./sandbox.sh`. Update any aliases, CI, or scripts that referenced `<project>-container.sh` or the old top-level `runme.sh`.

- **`VAULT_PATH` now mounts at `/workspace/vault` (was `/workspace/obsidian`)** and is re-exported as `VAULT_PATH=/workspace/vault` inside the container, consistent with `SPECS_PATH → /workspace/specs` and `DOCS_PATH → /workspace/docs`. The collision-guard name changed `obsidian → vault`. Runtime-safe for workflows that read `$VAULT_PATH` (they resolve the new value); update anything that hard-coded the literal `/workspace/obsidian`.

- **`install-dt-tools.sh` is renamed to `install-tools.sh`, and its `DTCTL_VERSION`/`DTMGD_VERSION` build args are removed in favor of a single `TOOL_VERSIONS` build arg.** `dtctl` and `dtmgd` are now driven by the generic `tools.d/` descriptor mechanism (see the **Added** entry below) instead of tool-specific Dockerfile code. The `sandbox.conf` grammar is unchanged (`dtctl=ON|x.y.z|OFF`, `dtmgd=ON|x.y.z|OFF`) — only the internal build-arg plumbing moved. This only affects a direct `docker build` invocation that passed `--build-arg DTCTL_VERSION=...`/`--build-arg DTMGD_VERSION=...` by hand, bypassing `build.sh`; normal `./build.sh` usage is unaffected. Update any such invocation to pass `--build-arg TOOL_VERSIONS="dtctl=0.25.0;dtmgd=0.0.23"` instead (semicolon-separated `name=version` pairs; `version` may also be `latest`).

### Added

- **New `open` network mode.** `./sandbox.sh open [primary]` runs with unrestricted egress and **no** capture — no firewall, no allowlist, no traffic logging — dropping both `NET_ADMIN` and `NET_RAW` from the agent shell. Equivalent to the historical `DISCOVERY_CAPTURE_ENABLED=0 ./sandbox.sh discovery`, but as an explicit, honestly named mode instead of a flag buried on `discovery`.

- **Project env-file injection: `container.env` / `SANDBOX_ENV_FILE`.** `sandbox.sh` now injects `<project>/.ai-containers/container.env` (or an explicit `SANDBOX_ENV_FILE` override) into the running container via `docker run --env-file`, for non-secret in-container **application** env (e.g. `DB_HOST`, `REDIS_URL`) — not a place for credentials. A missing explicit `SANDBOX_ENV_FILE` warns and is skipped rather than failing the run; the default `container.env` is silently skipped if absent.

- **`imagemagick=ON` and `wkhtmltopdf=ON` toggles.** Two new independent `sandbox.conf` flags. `imagemagick` installs the `imagemagick` apt package (`mini_magick`/`image_processing`/`carrierwave`). `wkhtmltopdf` installs the Qt/X11/font runtime libraries the `wkhtmltopdf` binary links against (so a gem-vendored binary, e.g. `wkhtmltopdf-binary`, can run) **and** the official standalone `wkhtmltox` binary from the `wkhtmltopdf/packaging` GitHub releases — no conflict between the two. Both off by default.

- **Database client tools: `db-clients=pg,mysql,mongo`.** New comma-separated `sandbox.conf` key installing **client-side** shells and dev libraries only — never a database server — for any subset of `pg` (`libpq-dev` + `postgresql-client`), `mysql` (`default-libmysqlclient-dev` + `default-mysql-client`), and `mongo` (`mongosh`, from MongoDB's own apt repository). Language-agnostic: serves Ruby's `pg`/`mysql2`, Python's `psycopg2`/`mysqlclient`, Node's `pg`, and similar drivers in any language. Selecting `mongo` adds `repo.mongodb.org` to the generated domain allowlist automatically. Setting `ruby=` to any version, or `db-clients=` to a non-empty value, makes `build.sh` set `KEEP_BUILD_TOOLCHAIN=1`, so the Dockerfile keeps `build-essential`/`libyaml-dev`/`zlib1g-dev`/`libssl-dev` (normally stripped after build) so native extensions can still compile **at container runtime**.

- **The official Atlassian CLI (`acli`) can now be installed: `acli=ON`.** Closes the gap where the sandbox had no Jira/Confluence path at all. Off by default. Two deliberate differences from the other `tools.d` tools, documented next to the key: the grammar is `ON | OFF` with **no version pinning** (Atlassian publishes every package behind a `latest` URL — a versioned path returns 403 — and supports each release for six months, so `acli --version` is how you check what you got; the existing 72-hour agent refresh re-fetches it), and **no `GITHUB_TOKEN` is involved** since the download is vendor-hosted. `acli` keeps its profiles *and* credentials in `~/.config/acli`, which the descriptor group-scopes, and the binary is static with no OS keyring dependency — verified by installing it in a container — so `echo "$TOKEN" | acli jira auth login --email … --site … --token` once per container group persists for every later container in that group. Endpoints arrive via `allowlist_fragment=atlassian` (new `allowlist-domains.d/atlassian.txt` with `api.`/`auth.atlassian.com` plus `acli.atlassian.com` for re-downloading the CLI itself, and `allowlist-proxy-domains.d/atlassian.txt` with `*.atlassian.net` for the per-organisation site host). The binary embeds a Segment analytics client (`https://api.segment.io`, no opt-out flag in 1.3.22); that host is deliberately **not** allowlisted, so telemetry fails closed in a `restricted` container.

- **New `tools.d` install mode: `install=url`** for a tool published outside GitHub. `url=` accepts `${OS}`, `${ARCH}` and `${VERSION}` placeholders; a `.tar.gz`/`.tgz` is unpacked and `binary=` is located **anywhere inside** the archive, because vendors commonly nest it in a version-named directory (`acli_1.3.22-stable_linux_arm64/acli`), while any other URL is treated as the binary itself. No GitHub API, no token, no release to resolve. Failures stay non-fatal and are all checked: an empty `url=`, a failed or empty download, an unpackable archive, an archive with no matching binary, and an unwritable install directory each warn and skip rather than reporting success. `${OS}`/`${ARCH}`/`${VERSION}` expansion is now shared with `repo_path=`, and accepts the **braced** forms only — an unbraced `$OS` is a plain substring match that also fires inside `$OSNAME`. Two further guards came out of review: a `.tar.gz` URL carrying a `?query`/`#fragment` is still recognised as an archive (matching the whole URL would have installed the tarball itself and reported success), and an archive holding two files with the target `binary=` name is refused instead of picking one by unspecified `find` order. A pinned version whose `url=` has no `${VERSION}` placeholder now prints a NOTE rather than silently installing whatever the URL serves.

- **`tools.d/` gains a second install mode for vendored binaries, and `config_dir=` accepts several paths.** `install=repo-file` (vs the default `release`) fetches a **prebuilt binary committed in the repo** at `repo_path=` — GitHub's contents API with `Accept: application/vnd.github.raw`, written straight to `/usr/local/bin` with no archive to unpack — for tools whose build artifacts are vendored into a git repo instead of published as releases. `repo_path` may contain `${ARCH}` (expanded to `amd64`/`arm64`), and `ref=` pins a branch/tag/commit with the `sandbox.conf` value taking precedence, so such a tool's key grammar is `ON | <git-ref> | OFF`. `private=yes`, the non-fatal skip on failure and the preflight token warning all apply unchanged, and because the tools layer sits after the `AGENTS_CACHE_BUST` marker, the existing 72-hour agent refresh re-fetches an unpinned vendored tool as well. Separately, `config_dir=` now accepts **several space-separated paths** for a tool that splits its state across directories (e.g. profile in one, credentials in another); every listed path is group-scoped, seeded once from `$HOME`, and mounted. `install-tools.sh`'s install directory is now overridable via `TOOLS_BIN_DIR` so both fetch modes are unit-testable. The fetch is defensive by design: the download goes to a `mktemp` file (not a guessable `/tmp` name that a pre-planted symlink could redirect), a JSON response is rejected rather than installed (GitHub answers a *directory* path with HTTP 200 and a JSON listing, which `curl -f` cannot distinguish from a file), and `mv`/`chmod` are checked so an unwritable install directory warns instead of printing "Installed". The multi-path `config_dir` is split with `read -ra` rather than an unquoted expansion, since bare word-splitting also globs — a descriptor containing a metacharacter would otherwise expand against the launch directory.

- **`sandbox.conf` is reconciled per-project on sync, via a schema-version marker and key-aware migrations.** A `# schema-version: N` comment marker (invisible to the parser) now lives in `sandbox.conf`; `sync-to-projects.sh` reconciles each project's hand-owned copy on every sync instead of only warning: it runs pending `migrations/NNN-*.sh` hooks, additively appends any new upstream keys under a dated banner (never touching a key the project already set), and ensures the marker — backfilling pre-existing projects with no one-time bootstrap. A migration hook is added only for a rare semantic change (rename / split / removal); plain new keys need neither a hook nor a bump. New authoring/CI helpers `bump-sandbox-version.sh` (scaffold the next idempotent key-only hook + bump the marker) and `check-sandbox-version.sh --check` (fail CI on a key removed/renamed without a matching hook and bump; additions pass silently) support the workflow. `check_config()` now exits with a clear error on a duplicate `key=` line, so a bad manual edit or interrupted reconcile is caught immediately instead of silently taking the first match.

- **`DOCS_PATH` mounts a product-documentation repo read-only at `/workspace/docs`.** Set `DOCS_PATH` to a host docs repo (e.g. `dynatrace-docs`) and `runme.sh` bind-mounts it **read-only** at `/workspace/docs` and re-exports `DOCS_PATH=/workspace/docs`, so grounding workflows (idea / VI / release-notes) resolve existing documentation at a stable path they cannot modify. To edit docs, mount the repo as the working dir instead. The `qmd=OFF` startup warning is now consolidated into one message naming all mounted markdown corpora (vault / specs / docs), replacing the vault-only warning. `DOCS_PATH` and `SPECS_PATH` also accept `@<name>` to mount a registered repo volume at `/workspace/<name>`; `DOCS_PATH` additionally accepts a `:ro`/`:rw` suffix (default `:ro`). When the docs repo is the working directory, `DOCS_PATH` re-points to that writable mount automatically. This re-introduces the previously removed `DOCS_PATH`, now under the `/workspace` umbrella, read-only by default, with env re-export and a name-collision guard.

- **`SPECS_PATH` mounts a specs/design/plans repo at `/workspace/specs`.** Set `SPECS_PATH` to a host directory and `runme.sh` bind-mounts it read-write at `/workspace/specs` and re-exports `SPECS_PATH=/workspace/specs` inside the container, mirroring `VAULT_PATH`. Spec-driven agent workflows (e.g. the dev-workflows plugin) resolve specifications at a stable path regardless of the host location. Export it in your host shell profile to make it the per-container default. This re-introduces the previously removed `SPECS_PATH`, now correctly placed under the `/workspace` umbrella with env re-export and a name-collision guard.

- **`qmd`'s search index persists across container restarts.** When `qmd=ON`, its cache (`~/.cache/qmd`, holding `index.sqlite`) is now group-scoped and mounted at the sandbox user's `~/.cache/qmd`, the same way agent dotfile dirs already are. Previously every container start reindexed `/workspace/vault`, `/workspace/specs`, and `/workspace/docs` from scratch; now a warm index carries over. Since a container group is reused across projects while `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH` can point at different host content each run, entries keyed by a reused in-container path (e.g. `/workspace/docs`) can go stale until qmd reindexes them — mount `DOCS_PATH`/`SPECS_PATH` via `@name` to give each source a distinct path (e.g. `/workspace/docs2`) and avoid the collision.

- **Generic `tools.d/` descriptor mechanism for external CLI tools.** Each tool the image can install (currently `dtctl`, `dtmgd`) is now described by one `tools.d/<name>.conf` file — `repo=`, `binary=`, `private=yes|no`, `config_dir=`, `allowlist_fragment=`, `skills=yes|no`, `skills_crossclient=` — parsed by the new shared `tools-lib.sh`. `build.sh` auto-discovers active descriptors, folds every enabled tool's `sandbox.conf` version into the single `TOOL_VERSIONS` build arg, and includes each tool's `allowlist_fragment` automatically (both `dtctl` and `dtmgd` share the existing `dynatrace` fragment). Adding a new tool no longer touches `build.sh`, the Dockerfile, or the allowlist-generation logic — only a new `.conf` file. The descriptor format supports private-repo tools (`private=yes`, requiring `GITHUB_TOKEN`) though this repo ships none; `build.sh` prints a non-fatal preflight warning if a private tool is enabled with no token set.

- **Automatic Agent Skill installation.** Tools whose descriptor sets `skills=yes` (both `dtctl` and `dtmgd` do) have their Agent Skill installed for every enabled AI agent automatically at container start (`install-agent-skills.sh`, run as the sandbox user just before the capability drop), including a cross-client skill install when the descriptor declares one (`skills_crossclient=`). A version-stamped marker (`~/.agents/.ai-containers-skills-stamp`) skips reinstall when no installed tool's version changed, so this never slows down a normal container start. `AI_AGENTS_ENABLED` (comma-separated enabled `sandbox.conf` agent keys, computed by `runme.sh`) is now passed into the container to drive this — no manual per-agent skill registration step, unlike `graphify`.

### Changed

- **Launcher config moved out of the generated `runme.sh` into two env files.** `project-init.sh` now writes a **portable** `sandbox.env` (tracked) — `IMAGE_NAME`, `AI_CONTAINER_GROUP`, `CONTAINER_*`, `SANDBOX_MODE`, `SANDBOX_WORKDIR` — and a **this-machine** `sandbox.local.env` (gitignored, always written — backing up any existing copy to `sandbox.local.env.pre-init` first) holding `EXTRA_MOUNTS`/`REPOS`, a commented `SANDBOX_MODE` override example, and any per-machine override. `runme.sh` becomes a thin wrapper (`gh` token → `./build.sh` → bare `./sandbox.sh`) with no config baked in, so regenerating it never clobbers your settings. `sandbox-common.sh`'s new `load_env_defaults` parses both files (never sources them — only `KEY=value`, so no arbitrary code runs) with set-if-unset semantics, loading local before portable, giving precedence **inline env > `sandbox.local.env` > `sandbox.env`**. `sandbox.sh`'s positional `<mode> <workdir>` now fall back to `SANDBOX_MODE`/`SANDBOX_WORKDIR` (a positional arg or inline env still wins; with neither, mode → help, workdir → the `/workspace` umbrella), which is what lets `runme.sh` call a bare `./sandbox.sh`. **Behavior change:** a `./sandbox.sh` run directly (not via `runme.sh`) now also applies `CONTAINER_*`/`EXTRA_MOUNTS`/`REPOS` from the env files — before, only `IMAGE_NAME` was read. Existing fat `runme.sh` launchers keep working (their inline `export`s win); re-run `project-init.sh` to adopt the split. The in-container `container.env` (application env, `--env-file`) is a separate layer and is unchanged.

- **`tests/run-all.sh` now fails a test file that exits 0 without asserting anything.** A file that exited cleanly but printed no `PASS`/`ok` line used to be reported as `PASS (0 assertion(s))` and counted towards the green total, which is precisely the shape of a test that silently stopped working (a bad guard, an early return, a renamed helper). It is now reported as `FAIL (exited 0 but asserted nothing)`.

- **Tool config dirs are now group-scoped and host-seeded, not host-direct.** `dtctl`'s and `dtmgd`'s config directory (and any future `tools.d`-described tool's `config_dir`) now lives under `~/.ai-containers/<group>/` like other agent credentials, instead of mounting `~/.config/dtctl`/`~/.config/dtmgd` directly from `$HOME`. The first time a group needs it, the directory is seeded once from the host's `$HOME` copy if one exists there (otherwise created empty); every later run mounts the group's copy, so a sandboxed agent never writes to the developer's real host config. The `host` group is unaffected — it still mounts directly from `$HOME`.

### Fixed

- **Every Ruby bootstrap printed a spurious `umask g+w` deprecation warning.** rvm decides whether `/etc/profile.d/rvm.sh` is the old "deprecated" loader by grepping it for `rvm_stored_umask`; the baked loader was a single `source` line, so the check failed and rvm warned that it *"causes you to have `umask g+w` set in your shell"*. It does not: the check never measures a umask, nothing in rvm 1.29.12 sets one (`__rvm_call_with_restored_umask` only saves and restores), and the `g+w` loader it refers to was the old SYSTEM-WIDE multi-user install that made a shared `/usr/local/rvm` group-writable. The baked loader now captures the umask before sourcing rvm — what rvm's own modern loader does, and what `__rvm_call_with_restored_umask` expects — so the warning is gone and the loader is correct rather than merely quiet. `verify-on-host.sh` Phase 3 now prints the measured umask in both a login and a non-login shell (expected `0022`), so this is evidence rather than assertion.

- **SECURITY-RELEVANT: the blocked-traffic capture daemon died silently at startup whenever an allowlist file had no entries, taking self-healing with it.** `capture-blocked-traffic.sh` runs `set -euo pipefail` and built its allowlist caches with `grep -v '^\s*#' F | grep -v '^\s*$' | sed …`. With no non-comment, non-blank line in `F`, the second `grep` exits 1, `pipefail` propagates it, and `set -e` killed the daemon roughly 150 lines before `init_output_files` — so `restricted` mode produced **no `blocked.log`, no `blocked-domains.txt`, no `blocked-ips.txt`, no NFLOG watcher, and no self-healing**, with nothing logged to say so. The firewall still dropped traffic (enforcement was never affected), but you lost every record of *what* it dropped, and dynamic CDN IPs behind an allowlisted wildcard stopped being auto-admitted, turning a working allowlist into intermittent failures. An empty allowlist is a perfectly legal configuration — the generated `allowlist-proxy-domains.txt` is nothing but its two header comments whenever no proxy-fragment component (`copilot`, `kiro`, `claude-code`, `codex`, `gemini`, `graphify`, or a `tools.d` tool declaring one) is enabled — which is exactly why this stayed invisible to anyone running with Copilot or Claude Code on. Both caches are now built by a single `awk`, which exits 0 whether or not it prints anything; the content it produces is unchanged (comments and blanks dropped, surrounding whitespace trimmed). `tests/test-blocked-capture.sh` drives the real script with fake `tshark`/`ipset` and asserts it reaches `init_output_files` and announces itself for comments-only, both-comments-only, and missing allowlist files, and guards against the `grep | grep` construct returning. `BLOCKED_INTERNAL_DIR` was added purely so the suite can run the daemon without root; the entrypoint never sets it and the internal state directory stays root-only in production.

- **BREAKING (macOS especially): the group's Ruby home `~/.rvm` moved from a host bind mount to a Docker named volume, and group deletion now needs `./group.sh rm`.** rvm could never bootstrap on macOS: it installs by extracting its release tarball, and GNU tar defers symlinks whose target contains `..` by first writing a **mode-000 placeholder file** — an operation macOS virtiofs (Colima / Docker Desktop) cannot service. tar failed on exactly the four such members in the rvm tarball (`bin/rvm-installer`, two `patches/ree/1.8.7/*.diff`, `scripts/zsh/Completion/_rvm`), exited non-zero, and the installer aborted with `Could not extract RVM sources` — so `ruby=` produced a container with no Ruby at all, on every start, in every group. Plain `ln -s ../x` on the same mount works fine (verified), which is why `~/.ai-tools` (npm/uv, direct `symlink()`) was never affected and stays a bind mount. `~/.rvm` is now `ai-containers-rvm-<group>`, a named volume, on **every** platform — one code path, since a macOS-only branch is precisely the divergence that let this sit undetected. The volume is created on first use and a pre-existing *healthy* bind-mounted `~/.rvm` is migrated into it once (predicate: a non-empty `scripts/rvm`, the same check the reconcile uses), leaving the old directory in place and telling you to remove it; the debris of a bootstrap that failed on this bug is deliberately not migrated. `entrypoint.sh` gained `chown_rvm_root`, because a fresh named volume mounts root-owned and `setup_sandbox_user`'s recursive `chown` uses `-xdev`, which by design does not cross into mounts — without it the sandbox user could not even open the reconcile lock. **`AI_CONTAINER_GROUP=host` keeps the plain bind mount** (that group's contract is "mount my real `$HOME`"), so rvm still cannot bootstrap there on macOS — use a named group for Ruby work. **Deleting a group is no longer just `rm -rf`**: it would orphan the volume. New `group.sh` (`list [--sizes]` / `rm <group> [--yes]` / `gc [--yes]`) removes directory and volume together and collects volumes orphaned by a manual `rm -rf`; it refuses while a running container mounts the volume, refuses the `host` group, and never touches repo volumes. The `-rvm-` infix is load-bearing — it is what keeps `repo.sh`'s discovery (`name=<prefix>-repo-`) and its registry-driven `sync/reset --all` from ever reaching a group's compiled rubies — and both `tests/test-repo-registry.sh` and the new `tests/test-rvm-volume.sh` assert that isolation directly, so widening the filter or renaming an infix fails in CI rather than in a workspace.

- **`bundle` resolved in a non-login shell but died on exec: `env: 'ruby_executable_hooks': No such file or directory`.** rvm rewrites gem binstub shebangs to `#!/usr/bin/env ruby_executable_hooks` (the `executable-hooks` gem, installed into the `@global` gemset), and a non-interactive, non-login shell has neither `~/.rvm/bin` nor that gemset's bin directory on `PATH`. `link-default-ruby.sh` symlinked the binstub and reported success, so `ruby` and `gem` (no rewritten shebang) worked while `bundle`/`bundler` were broken — invisible until the bootstrap itself started succeeding. The linker now also exposes `ruby_executable_hooks`, and then **verifies each link actually runs**, re-pointing any that doesn't at rvm's own `wrappers/` entry (generated by the `gem-wrappers` gem, which sets `GEM_HOME`/`GEM_PATH`/`PATH` and execs) — the direct binstub stays the fast path, the wrapper is the fallback, and a binary that can neither run nor be wrapped is now logged instead of silently shipped broken.

- **A failing rvm bootstrap blamed the network for errors that had nothing to do with it.** `rvm-reconcile.sh` ran `curl -fsSL https://get.rvm.io | bash -s stable` under `set -o pipefail`, so a *single* status covered two unrelated components, and the one message it printed — `FAILED: rvm bootstrap (network unreachable, or get.rvm.io not allowlisted)` — asserted a firewall/allowlist cause for what could equally be a GPG-verification, unpack, or permission failure inside the installer. The download and the run are now separate steps with separate messages, and the installer's own output (stdout **and** stderr) is echoed into the container log prefixed `[rvm-installer]`, so the actual error is attributable instead of being replaced by a guess. The installer-failure path says explicitly that it is *not* a blocked host.

- **The runtime rvm bootstrap could never succeed in `restricted` mode: `https://get.rvm.io` redirects to `bitbucket.org`, which was not allowlisted.** `rvm-reconcile.sh` fetches the installer with `curl -fsSL`, and `get.rvm.io` answers `301 → https://bitbucket.org/mpapis/rvm/raw/master/binscripts/rvm-installer`; `-L` follows the hop, the firewall dropped it, and every first start in a fresh container group logged `FAILED: rvm bootstrap (network unreachable, or get.rvm.io not allowlisted)` and left the container with no Ruby at all — on every subsequent start too, since nothing was ever written to `~/.rvm`. `allowlist-domains.d/rvm.txt` now includes the hosts the bootstrap and compile actually reach: `bitbucket.org` (the redirect target — also used by `rvm get stable`, reconcile's install-failure retry, which re-fetches through the same redirect and derives the signature URL from its `Location:` header), `api.bitbucket.org` (the installer's tag-resolution fallback when anonymous `api.github.com` is rate-limited — a per-public-IP limit shared by every container behind one NAT, where a 403 with the fallback blocked means "Exhausted all sources trying to fetch version"), and `ftp.ruby-lang.org` (rvm's `ruby_url_fallback_1` when `cache.ruby-lang.org` fails to serve the source tarball). The rest of the download path was already covered by `base.txt` (`github.com`, `codeload.github.com`, `release-assets.githubusercontent.com`, `api.github.com`), and `tests/test-rvm-config.sh` now asserts both sets so moving a host out of either fragment cannot silently break Ruby again.

- **`sandbox.env` / `sandbox.local.env` can no longer hand control of the shell to the launcher.** `load_env_defaults` parses rather than sources, which stops a *stray command* in the file from running — but it then `export`ed every well-formed `KEY=value` it accepted, including `BASH_ENV`. Since `sandbox.env` is designed to be **committed and shared with a team**, a single `BASH_ENV=./x.sh` line was enough to execute arbitrary code on a teammate's machine: the loader exported it, and the next child `bash` that `build.sh`/`sandbox.sh`/`repo.sh` spawn sourced it. Keys that configure the shell rather than the launcher — `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `CDPATH`, `IFS`, `PS4`, `PATH`, the `LD_*`/`DYLD_*` loader vars, and `BASH_FUNC_*` — are now refused with a warning, and parsing of the remaining keys continues. Surrounding double quotes are also stripped only as a **matched pair**, so a value legitimately containing one `"` is no longer silently mangled.

- **A version-list key set to the literal `OFF` now means "skip", like the documented empty `key=`.** `sandbox.conf` mixes boolean keys (whose skip value *is* `OFF`) with version-list keys (whose skip value is empty), so `ruby=OFF` is a natural thing to write — but `has_versions()` only tested for non-empty while `is_active()` excluded `OFF`, and the two disagreed. The result for `ruby=OFF` was the worst of both: `build.sh` set `RUBY_RUNTIME=1` and `KEEP_BUILD_TOOLCHAIN=1` (baking the entire Ruby build toolchain into the image), `sandbox.sh` passed `RUBY_VERSIONS=OFF` into the container, and `rvm-reconcile.sh` therefore bootstrapped rvm and ran `rvm install OFF` — failing on **every single container start** — into an `~/.rvm` that `sandbox.sh` (correctly using `is_active`) had never mounted, so the work was thrown away each time. `has_versions()` now treats `OFF` as unset, and a new `version_list()` helper normalises the *value* to empty everywhere one is emitted (`ruby`, `rust`, `go`, `db-clients`, `node`, `python`, and the JVM keys), so no build arg or container env var can carry the literal string `OFF`. `get_versions()` is unchanged — boolean keys still need it to return `OFF` verbatim.

- **`sync-to-projects.sh` now backfills the project's inner `.ai-containers/.gitignore`.** `sandbox.local.env` holds this machine's absolute mount paths, and its only protection from git is that inner ignore file — written solely by `project-init.sh`. Any project initialised before that pattern existed therefore had no protection, and sync never repaired it. This mattered most in exactly the case sync had just learned to support: a project that deliberately **tracks** `.ai-containers/` is skipped by the root-`.gitignore` step, so the inner file is the *only* guard. The backfill is append-only and idempotent — missing required patterns are appended, existing lines and the project's own additions are never removed or reordered, and a second sync adds nothing.

- **`rvm-reconcile.sh` no longer wedges a container group on a failed first bootstrap.** The `curl … | bash -s stable` bootstrap was unchecked, so an offline or interrupted first run left `~/.rvm` half-written; the `[[ ! -s scripts/rvm ]]` guard then considered it bootstrapped, sourced a broken rvm, and every later `rvm` call became "command not found" — on every start, for that group, forever, with no recovery short of deleting the group's `~/.rvm` by hand. The bootstrap result is now verified (and a zero-byte `scripts/rvm` triggers a re-bootstrap), a failure logs a clear `FAILED: rvm bootstrap` and exits cleanly instead of cascading, and version presence is matched with `grep -Fqx` so a version's dots are literal rather than regex wildcards.

- **A `db-clients` typo is rejected up front instead of silently enlarging the image.** `db-clients` is a closed set (`pg`/`mysql`/`mongo`), but an entry outside it only produced a warning buried in the `docker build` output — after `KEEP_BUILD_TOOLCHAIN=1` had already been flipped on. `build.sh`'s `validate_config` now fails with a clear error naming the bad entry and the allowed values.

- **Both container-start reconciles now say when they are waiting on another container.** `rvm-reconcile.sh` and `agent-tools-reconcile.sh` run *before* the interactive shell and `flock` on the shared group mount, so a second same-group container blocked silently for the whole multi-minute first-run Ruby compile and looked hung. They now try the lock without waiting first and print what they are waiting for before blocking. Vale's version resolution also rejects a value that is not version-shaped, rather than passing a whole URL into the download path.

- **The open-mode startup banner's box is aligned** (its last two lines were one column short of the border).

- **A `#` inside a `tools.d/` descriptor value is no longer treated as a comment.** The parser stripped from the first `#` on the whole line, so a `url=` carrying a URL fragment or a `#` in a query string was silently truncated — losing the rest of the value, placeholders included, with no warning. `#` now starts a comment only at the beginning of a line or after whitespace.

- **An accepted agent refresh is no longer undone by the next build, and the staleness prompt no longer reappears every launch.** `build.sh` now **persists** the `AGENTS_CACHE_BUST` token it used in `.agents-cache-bust` (gitignored, per project) and defaults to that value instead of `0`. Docker's build cache is keyed by build-arg *value*, so after `sandbox.sh`'s targeted refresh minted a fresh token, the next plain `./build.sh` with `0` cache-hit the pre-refresh image — and since that result is bit-identical to the original build, Docker moved the tag back onto the *same image ID* with the *same* `.Created`. The refreshed image was left dangling, the container started from the stale one, and `sandbox.sh` reported the same "image is N hour(s) old" prompt on every launch (most visibly because the generated `runme.sh` runs `./build.sh` before `./sandbox.sh`). An explicit `AGENTS_CACHE_BUST` still wins and replaces the persisted value; `--no-cache` mints a fresh token, since such a build refreshes the agent layers by definition and later plain builds must reproduce it; the token is written only after a successful build. Images built before this release have no token file, read as `0`, and self-heal on their first refresh.

- **A rebuild now removes the image it replaced.** Every build that produces a new image previously left the predecessor dangling — a few hundred MB per targeted agent refresh, the whole multi-GB image per `--no-cache` build, multiplied by every project. `build_image()` records the tag's image ID before building and `remove_replaced_image` (new, in `sandbox-common.sh`) drops it afterwards. Deliberately narrow: one explicit image ID, skipped when that image still carries any tag, and `docker rmi` **without** `--force`, so an image a container still references is kept and reported instead. Build-cache records are never removed automatically — a one-line hint suggests `docker builder prune --filter unused-for=720h`.

- **`repo.sh list` no longer shows a phantom concatenated repo.** `repo_name_from_volume` emitted each name without a trailing newline (`printf '%s'`), so `cmd_list`'s per-volume loop ran the names together — with two repos `cluster` and `docs` it produced a bogus `clusterdocs` entry (`TYPE ?`, `MISSING`), and more with additional repos. It now emits one name per line (`printf '%s\n'`). The artifact was display-only — `repos.conf` and the volumes were never affected — so existing setups self-heal on the next `list`.

- **Registry reads/writes are robust to a missing final newline in `repos.conf`.** On GNU coreutils (Linux), `grep`/`cut` preserve a final line that lacks a trailing newline, so a hand-edited or partially written registry could glue two records on the next `repo.sh add`/`sync` (`repo_registry_upsert` now adds the missing newline before appending) or yield an unterminated last name in the `list` union (`repo_registry_names` now uses `awk`, which always newline-terminates its output). No effect on well-formed registries; harmless on macOS/BSD, which already normalize the newline.

- **`.gitconfig` and `.gitignore_global` are now group-scoped.** `runme.sh` copies both files from `$HOME` into `~/.ai-containers/<group>/` on every container start and mounts from the group copy instead of directly from `$HOME`. This fixes a macOS VirtioFS stale-inode bug: when git, editors, or any tool atomically replace a file on the host after a container starts, Docker's bind mount still references the old inode (now with link count 0), so the file appears in directory listings but all reads fail with "No such file or directory". Mounting from the group copy — which nothing replaces while a container is running — avoids the issue. The `host` group is unchanged (still mounts directly from `$HOME`). If either file is edited on the host while a container is running, restart the container to pick up the changes.

### Added

- **Three named execution layers — PR, nightly, local — with an enforced `local ⊇ nightly ⊇ PR` containment invariant**, instead of the unstated, backwards relationship that had existed until now: `verify-on-host.sh` ran the integration corpus and nothing else, so a developer verifying locally before pushing checked *less* than CI would. `tests/test-layer-containment.sh` (new) holds the invariant up mechanically. It does **not** grep `verify-on-host.sh`'s source for a filename — an earlier version of this exact guard did, and a reviewer defeated it in one edit: commenting out the real `tests/run-all.sh` invocation while leaving a comment that still named it left the check passing, because that filename also appears in an existence guard and a failure message elsewhere in the file, and a substring search cannot tell "invoked" from "merely mentioned" apart. The fixed version (`tests/lib-verify-repo.sh`) builds a stub repo out of instrumented fakes that each record their own invocation to a witness log, runs the real `verify-on-host.sh` against it, and asserts the witness line — effect, not text. It also pins the **step count** of each CI job it mirrors against a recorded baseline, so a new CI step silently widens the PR gate past the local layer only if nobody updates that one number, not if nobody notices at all.
  - **The phase table gains 5 and 7; 1, 2 and 3 stay permanently retired; 6 is reserved.** Phase **5** runs the hermetic suite (`tests/run-all.sh`) plus the `sandbox.conf` schema gate, then the same suite again inside a container pinned to the declared bash floor. Phase **7** runs `bash -n` over every tracked script, the new dialect linter, and `shellcheck` as a gate. Both mirror a whole `tests.yml` CI job rather than a hand-picked step, which is what makes containment checkable by construction. Execution order is **0, 5, 7, 4** — cheap checks first, so a broken hermetic suite is reported in seconds rather than after an hour of image builds. `PHASES` now defaults to `"4 5 7"` (was `"4"`); a local layer nobody selects by default is not a local layer. 1, 2 and 3 (removed by increment 3) and 6 (reserved for increment 5's mutation tier) must never be filled in — reusing a retired number would make a stale `PHASES="1 2 3"` valid again and silently defeat the guard that exists specifically to reject it.
- **A single declared bash floor, raised to 5.1.** `bash-floor.sh` (new, sourced — never a second copy of the version check) replaces three contradictory claims that had accumulated in the repo: `sandbox-common.sh` enforced ≥4.3, `README.md` documented ≥4.4, and three test files claimed to target "bash 3.2" while already using `local -A`/`local -n`, which fails outright below 4.3 — a claim nothing could ever have exercised, since the product itself refuses to start under 4.3. 5.1 costs macOS nothing (any floor above 3.2 already needs a Homebrew bash there) and excludes only Ubuntu 20.04 (ESM-only since April 2025) and RHEL/Rocky 8 (a host-script-only concern; the container is `ubuntu:24.04`, bash 5.2.21, regardless of host). 5.2 was considered, to match what CI and the container both already run, and rejected: it would additionally drop RHEL/Rocky 9, Ubuntu 22.04 LTS, and Debian 11 for a floor that would keep drifting upward with the runner image anyway. **The floor is tested, not asserted** — CI's new `suite-floor` job and `verify-on-host.sh`'s new Phase 5 both run the full hermetic suite inside `ubuntu:22.04` (bash 5.1.16), and `tests/test-layer-containment.sh` fails if that image and the declared floor ever drift apart, closing the exact hole that let the 3.2 claim survive untested for months.
- **`tests/bash-dialect-lint.sh`** rejects any script construct newer than the declared floor (`${ cmd; }` value substitution, `BASH_MONOSECONDS`/`BASH_TRAPSIG`/`GLOBSORT`, post-5.1 `shopt` options, and more), reading the permitted ceiling from `bash-floor.sh` so raising or lowering the floor needs no second edit. Matching is deliberately raw-line and not shell-aware — an earlier version stripped comments first, which is unsound (a `#` opening a real comment cannot be told apart from one inside a quoted string or a parameter-expansion prefix by regex alone) — with a per-line, reason-required opt-out (`# dialect-lint: allow RULE-ID: reason`) for the handful of lines that must legitimately contain the construct they name (the rule's own definition, a test vector). This exists because the container/CI run bash 5.2, a developer's Mac typically runs 5.3 via Homebrew, and the floor is 5.1 — three different versions with nothing previously comparing them, so a `${ cmd; }` written comfortably on a Mac would have sailed through review and died at container start.
- **`tests/integration/run.sh --dry-run`** prints the case basenames the current `--tags`/`--exclude`/`--cases`/`--variant` selection would run and exits — no image build, no container, no docker call at all. An empty selection is fatal here exactly as in a real run. `--list` is deliberately unchanged and keeps its documented whole-corpus contract regardless of any selection flag — redefining an existing flag's meaning while keeping its name is the failure mode this project refuses everywhere (see `sandbox.conf`'s schema-versioning rule). `--dry-run` is what makes containment checkable as a set comparison: the new layer-containment guard asks `run.sh` what each layer's actual flags would select, rather than reimplementing the selection logic a second time and risking it going quietly wrong in the mgd port.
- **`tests/portability.sh`** — GNU/BSD-neutral helpers (`p_stat_mode`, `p_stat_meta`, `p_sha1`, `p_md5`, `p_realdir`) for the four call sites that used GNU-only `stat -c`/`sha1sum`/`md5sum` with no fallback, inconsistent with the rest of the suite, which already handled BSD correctly elsewhere. Written ahead of the hermetic suite's first-ever run on real BSD userland (macOS, via `verify-on-host.sh` Phase 5) — CI has always been ubuntu-only.
- **`shellcheck` now gates**, in CI (`tests.yml`'s `lint` job) and locally (Phase 7) — the `|| true` that made it advisory-only, and had been since it was added with a comment calling the tightening "a deliberate follow-up," is gone.

### Fixed

- **The two production bugs the macOS run surfaced, neither caught by CI because CI never runs on BSD userland or a developer's real project registry.**
  - **macOS canonicalises `/var/folders/…` to `/private/var/folders/…`, and `/bin/true` does not exist there** (it ships at `/usr/bin/true`). Together these accounted for 27 of the 29 hermetic-suite assertion failures the first real macOS run produced: `test-parsers.sh`, `test-mutations.sh`, and `test-tool-config-mounts.sh` each compared a resolved path against an unresolved `mktemp -d` expectation (19 failures), and `test-integration-lib.sh` hardcoded `/bin/true` as a stand-in executable (8 failures). Both are test-assumption bugs, not product defects — fixed via `tests/portability.sh`'s new `p_realdir` (an independently-derived canonical path, not a second call to the same `readlink -f` the code under test already uses) and by fabricating the stand-in executable in each test's own scratch directory instead of assuming a fixed path exists.
  - **`tests/test-parsers.sh` reported the developer's real, untouched `projects.conf` as modified — while the check that actually could have caught a real edit to that file was structurally blind to it.** `projects.conf` is gitignored, so `git diff --quiet -- projects.conf` and `git status --porcelain` can never observe a change to it; on a git failure (a real one turned up separately, see below) the same code reported a false "was touched." Fixed by hashing the file directly with `p_md5`, independent of git, matching the pattern already in use at `tests/test-sync-project.sh:34`.
- **Every project created or synced after the bash-floor change would have hard-crashed on its very first `build.sh`/`sandbox.sh` run.** `project-init.sh` and `sync-to-projects.sh` each copy a hand-maintained list of shared engine files into a project's `.ai-containers/` working copy, and both lists omitted the new `bash-floor.sh` — which `sandbox-common.sh` (itself copied) sources unconditionally. The 40/40 hermetic suite was green with this bug present, because `tests/test-sync-project.sh`'s own pinned file-list contract had the identical omission and ratified it instead of catching it. Root cause: three independent hand-maintained copies of "which files get copied" (`project-init.sh`, `sync-to-projects.sh`, and the test's expectation), which had *already* silently diverged once before this — `sync-to-projects.sh` copied `group.sh` and `project-init.sh` did not, so a freshly-initialised project had no `group.sh` until its first sync, and nothing had ever compared the two lists. Fixed by extracting the one true list into `shared-files.sh` (new, an array both callers source) and adding `tests/test-shared-files-parity.sh` to guard the two callers against drifting apart again.
- **`link-default-ruby.sh` silently linked a broken Ruby binstub onto `/usr/local/bin` with zero warning, in exactly the case its own comment claimed to prevent.** The verify-and-warn step that checks whether a linked binary (e.g. `bundle`) actually runs, and falls back to an rvm wrapper if not, was gated on an rvm wrapper directory existing at all — so when no wrapper directory existed, the check that was supposed to catch and report a broken binstub never ran, and the broken symlink shipped without a word. The verify-and-warn step is now unconditional; only the repair/fallback step stays gated on a wrapper directory actually being available to fall back to.

## v0.4.1 — 2026-06-16

### Added

- **pnpm component.** New optional `pnpm` flag in `sandbox.conf` (`ON`/`OFF`, default `OFF`) installs the [pnpm](https://pnpm.io) Node package manager globally via `npm install -g pnpm` at build time, mirroring the `yarn` component. Needed for projects whose CONTRIBUTING workflow uses pnpm/corepack: the non-root sandbox user cannot run `corepack enable` or `npm install -g` at runtime because the nvm Node directory is root-owned, so pnpm must be baked into the image. No allowlist change — pnpm fetches from `registry.npmjs.org`, already in `base.txt`.

## v0.4.0 — 2026-06-16

### Added

- **Vale component.** New optional `vale` flag in `sandbox.conf` (`ON`/`OFF`, default `OFF`) installs the [Vale](https://vale.sh) prose/style linter — a single self-contained Go binary — from GitHub releases (`vale-cli/vale`) at build time. Installed **unpinned** (latest), with the version resolved from the `releases/latest` redirect (no GitHub API token or rate limit). Useful in docs workspaces whose style-check phase otherwise warns that "Vale isn't installed". A new `allowlist-domains.d/vale.txt` fragment (`vale.sh`) is included when `vale=ON`; the binary download and `vale sync` style packages use GitHub hosts already in `base.txt`.

- **Docker volumes are now the source of truth for repo state, via labels.** Each base repo volume is created with `ai-containers.repo`/`.type`/`.source` labels, and each `:rwcopy` working copy with `ai-containers.repo`/`.workcopy`/`.launch-dir`. `repo.sh list` now reads existence and metadata directly from Docker (union of labeled volumes + registry; a registry entry whose volume is gone shows `MISSING`, and a `WC` column counts working copies). The registry (`repos.conf`) is demoted to a cache — authoritative only for Linux `bind`-backend repos (no volume to label) and the mutable last-synced timestamp (Docker labels are immutable after creation).

- **`repo.sh reindex`** — rebuild `repos.conf` from the base-volume labels. Recovers a lost or stale registry, or adopts repos seeded on another machine/checkout. Additive and non-destructive: it inserts/updates volume-backed repos (preserving known added/synced timestamps) and leaves `bind`-backend entries untouched.

- **`repo.sh gc [--repo <name>] [--unused] [--yes]`** — prune `:rwcopy` working-copy volumes. Removes all by default; `--repo` scopes to one repo, `--unused` keeps copies currently mounted by a running container, `--yes` skips confirmation. Working copies can hold uncommitted work, so it confirms before deleting.

- **`repo.sh list --copies`** — list `:rwcopy` working copies with their parent repo, originating launch directory (from the volume label), whether a running container currently mounts them, and (with `--sizes`) on-disk size.

### Changed

- **Repo volumes are now global (image-independent).** The backing Docker volume name dropped its `IMAGE_NAME` prefix and is now `ai-containers-repo-<name>` (working copies: `ai-containers-repo-<name>--wc-<tag>`). Previously it was `<image>-repo-<name>`, so a single (already global) registry entry resolved to a *different* volume in every project — seeding a repo from one project left it "missing" in another, and sharing one volume across projects required matching `IMAGE_NAME` by hand. Now you register a repo **once** with `./repo.sh add` and attach the same volume to any number of containers across any project or container group, with no `IMAGE_NAME` juggling. Set `REPO_VOLUME_PREFIX` to restore the legacy per-image scoping (e.g. `REPO_VOLUME_PREFIX="$IMAGE_NAME"`).

  **Upgrade note:** existing volumes keep their old `<image>-repo-<name>` names and will appear "missing." Recreate each affected repo: `./repo.sh rm <name>` (then `docker volume rm <old-volume>` if it lingers) and `./repo.sh add <name> <source>`, or re-seed in place with `./repo.sh sync <name>` (which creates the new global volume from source).

## v0.3.0 — 2026-06-12

### Breaking

- **`runme.sh` no longer builds.** The entry point was split into three scripts sharing a `sandbox-common.sh` library: `build.sh` (build only), `runme.sh` (run only — `restricted`/`discovery`), and `repo.sh` (repo-volume manager). `runme.sh build` now prints an error pointing to `./build.sh`. Update any scripts, launchers, or habits that called `runme.sh build`. Generated project launchers and `project-init.sh`/`sync-to-projects.sh` were updated to match.

- **`/workspace` is now an umbrella, not the primary repo.** Everything mounts as a subdirectory under `/workspace`: `REPOS` at `/workspace/<name>`, `EXTRA_MOUNTS` at `/workspace/<basename>`, the Obsidian vault at `/workspace/obsidian`. The `/repos/*` tree is gone — `EXTRA_MOUNTS` now lands under `/workspace/<basename>` instead of `/repos/<basename>`. A host-path positional argument (`runme.sh restricted /path/to/repo`) now mounts at `/workspace/<basename>` (not `/workspace`) and becomes the working directory.

- **`DOCS_PATH` and `SPECS_PATH` removed.** The `/docs` and `/specs` mounts are gone; if either env var is set, `runme.sh` prints a one-line note and ignores it. Keep documentation and specs inside a repo (mounted under `/workspace`) or in the Obsidian vault.

- **Obsidian vault path changed.** `VAULT_PATH` now mounts at `/workspace/obsidian` (was `/obsidian`) and is re-exported as `VAULT_PATH=/workspace/obsidian` inside the container.

- **Agent outputs moved to the launch directory.** `.agent-blocked/` and `.agent-discovery/` are now written to the host directory where `runme.sh` is invoked (surfaced under `/workspace/.agent-*`), instead of inside the workspace repo. They are added to `.gitignore` and `.dockerignore`.

### Added

- **`AGENTS.md` is now the canonical agent-instructions file.** The contents formerly in `CLAUDE.md` were promoted to `AGENTS.md` (the open standard read natively by Codex, GitHub Copilot, Gemini CLI, Cursor, and others). `CLAUDE.md` and `.github/copilot-instructions.md` are now **symlinks** to it, and a new `.kiro/steering/AGENTS.md` symlink exposes the same content to Kiro CLI (which loads `.kiro/steering/**/*.md`, not a root file). Edit `AGENTS.md` only — the rest follow. This also removes the duplicated condensed Copilot instructions, eliminating cross-file drift.

- **`repo.sh reset <name|--all> [--yes]`** — restore a repo volume to a clean state ("start clean"), distinct from `sync` (which fetches latest). Git sources: `git reset --hard` to the upstream (drops uncommitted changes and local commits) + `git clean -ffdx` (removes untracked and git-ignored files) — fully local, no re-clone. Path sources: re-mirror from the host source. Either way it also removes any `:rwcopy` working copies so they re-seed clean. Destructive — prompts for confirmation unless `--yes`. The Linux `bind` backend is left untouched (it prints how to clean the live host checkout).

- **`repo.sh` — shared repo-volume manager** (`add` / `sync` / `reset` / `list` / `rm`; `sync` and `reset` accept `<name | --all>`). Big repositories can be seeded **once** into a Docker named volume living inside the Docker/Colima VM, then attached to any number of containers at native in-VM speed — avoiding the macOS virtio-fs bind-mount penalty (~30–50× slower metadata ops). Repo volumes are global (shared across all container groups) and tracked in a registry at `~/.ai-containers/repos.conf`. Authentication for `git`-URL sources uses the host `~/.ssh` (mounted read-only into a short-lived seeding container); local-path sources need no credentials.

- **`REPOS` env var** — space-separated list of registered repos to attach under `/workspace/<name>`. Modes: `:ro` (shared, read-only; `GIT_OPTIONAL_LOCKS=0` set so read-only git works), `:rw` (shared base volume mounted writable directly, single-writer), `:rwcopy` (isolated per-workspace writable working copy seeded by a fast local copy). Unregistered or missing repos abort before the container starts; a name appearing in both `EXTRA_MOUNTS` and `REPOS` is an error.

- **`REPO_BACKEND` env var** (`auto` | `volume` | `bind`, default `auto`). On macOS `auto` uses named volumes; on Linux it uses direct host bind mounts for `path` repos (already native-speed there), so one `REPOS` line works on both platforms. The backend is decided at `repo.sh add` time and stored in the registry.

- **`@<repo>` positional argument** — selects a registered repo as the working directory at `/workspace/<repo>`, attached writable automatically (errors if explicitly listed `:ro`). This is the fast primary-repo path on macOS.

- **`rsync`** added to the image so `repo.sh sync` mirrors path-sourced repos exactly (with deletions); it falls back to `cp -a` if absent.

- **`repo.sh` honours `SANDBOX_UID`/`SANDBOX_GID`.** It previously hardcoded `id -u`/`id -g` for the `chown` of seeded/synced volume contents, while `runme.sh` creates the sandbox user from `SANDBOX_UID`/`SANDBOX_GID` (defaulting to `id -u`/`id -g`). Overriding those for `runme.sh` therefore left repo volumes owned by the wrong UID and caused in-container permission errors. `repo.sh` now resolves the identity the same way, so the override is symmetric — but you must export the **same** values for both `repo.sh` and `runme.sh` (with no override, the host user is used on both sides automatically). The Linux `bind` backend mounts the host path directly with no `chown` and is unaffected.

- **Dedicated `repo.sh` seed image (`Dockerfile.seed`).** `repo.sh add`/`sync` no longer require the sandbox image to exist. The copy/clone/rsync work runs in a small, shared helper image (`ai-containers-seed`, ~40 MB: Alpine + `git`, `openssh-client`, `rsync`, `bash`), built automatically on first use. Repo volumes can now be seeded **before** `./build.sh` is ever run. The seed image name is fixed and **project-independent** (not derived from `IMAGE_NAME`), so it is built once and reused by every project instead of producing a near-identical copy per project image. Override with `REPO_SEED_IMAGE` to reuse an existing image (e.g. `REPO_SEED_IMAGE="$IMAGE_NAME"`); a named-but-missing `REPO_SEED_IMAGE` errors instead of building. `Dockerfile.seed` is synced to projects by `project-init.sh`/`sync-to-projects.sh` and excluded from the main image build context. Because this helper runs as root while repo volumes are owned by the host UID, `repo.sh sync` of a git-sourced repo sets `git config --global safe.directory /dst` before `git pull --ff-only`, avoiding git's "dubious ownership" refusal.

- **`project-init.sh` ignores `.ai-containers/` in the project's root `.gitignore`.** The per-project `.ai-containers/` is a synced working copy of the central repo whose launcher embeds machine-specific paths (`EXTRA_MOUNTS`) and whose `custom.txt` may hold internal hostnames, so it should not be committed to the project. The rule is added idempotently (git repos only); `sync-to-projects.sh` backfills it for existing projects. Remove the line to version it instead, or set `AI_CONTAINERS_NO_GITIGNORE=1` to skip.

- **`sandbox.env` — persisted per-project `IMAGE_NAME`.** `project-init.sh` now writes `<project>/.ai-containers/sandbox.env` (`IMAGE_NAME=<image>`), and `sandbox-common.sh` sources it (when `IMAGE_NAME` is not already exported) before resolving the image name. This makes `build.sh`, `runme.sh`, and `repo.sh` agree on the image — and therefore the repo-volume names (`<image>-repo-<name>`) — even when a script is run directly instead of through the generated launcher. Previously `repo.sh` run standalone fell back to the default `ai-sandbox`, creating volumes a custom-named project's `runme.sh` could not find. An exported `IMAGE_NAME` still takes precedence. `sync-to-projects.sh` backfills `sandbox.env` for pre-existing projects (from the launcher's `IMAGE_NAME`) and never overwrites it.

- **`sandbox-common.sh`** — shared library (config parsing, container-group helpers, path/volume helpers, repo registry) sourced by `build.sh`, `runme.sh`, and `repo.sh`.

### Removed

- `runme.sh build` subcommand (use `./build.sh`).
- `DOCS_PATH` / `SPECS_PATH` env vars and the `/docs` / `/specs` mounts.
- The `/repos/*` mount tree (replaced by `/workspace/*`).

## v0.2.1

### Added

- **GoReleaser component.** New optional `goreleaser` flag in `sandbox.conf` (`ON`/`OFF`, default `OFF`) installs the latest GoReleaser OSS from the official apt repository at build time. It is self-contained and does **not** require `go` to be enabled — the apt package's recommended `golang` dependency is skipped via `--no-install-recommends`. A new `allowlist-domains.d/goreleaser.txt` fragment (`repo.goreleaser.com`, `goreleaser.com`, plus the already-baseline GitHub release hosts) is included when the component is enabled.

## v0.2.0

### Breaking

- **Linux default behavior changed.** Dotfile directories (`.claude`, `.copilot`, `.kiro`, `.codex`, `.gemini`, `.config/gh`, `.agents`, `.ssh`) are no longer auto-shared with the host on Linux. They now live under `~/.ai-containers/default/` by default on both Linux and macOS. To restore the previous Linux behavior and mount dotfiles directly from `$HOME`, set `AI_CONTAINER_GROUP=host`. On the first run after upgrade, an interactive prompt (TTY required) offers to copy host dotfiles into the `default` group. Non-interactive callers must set `AI_CONTAINER_GROUP_INIT=from:host` or `AI_CONTAINER_GROUP_INIT=clean` to avoid a hard failure.

- **`SSH_SCOPE_DIR` removed.** `.ssh` is now part of the container group and lives at `~/.ai-containers/<group>/.ssh/`. If `SSH_SCOPE_DIR` is set, `runme.sh` prints a one-line deprecation note to stderr and ignores the variable. To migrate a custom SSH directory: copy keys manually into `~/.ai-containers/<group>/.ssh/`, or initialize a new group with `AI_CONTAINER_GROUP_INIT=from:host` to copy the entire group-scoped slice from `$HOME`.

- **macOS `host` group requires explicit acknowledgement.** Setting `AI_CONTAINER_GROUP=host` on macOS prints a warning that Claude Code, GitHub Copilot CLI, Kiro CLI, and GitHub CLI store OAuth tokens in the macOS Keychain (unreachable from the container) and prompts `Type 'yes' to continue, anything else to abort:`. For non-interactive use, set `AI_CONTAINER_HOST_ACK=1`. On Linux, `AI_CONTAINER_GROUP=host` requires no acknowledgement and behaves identically to the previous default.

### Added

- **Container-group system.** A new env var `AI_CONTAINER_GROUP` selects which dotfile tree mounts into the container. The default group is `default`; use `host` to mount from `$HOME`; use any lowercase name (e.g. `docs`, `java-backend`, `ui`) for a purpose-specific isolated profile. Each named group is a directory at `~/.ai-containers/<group>/` containing its own agent auth state, skills, MCP config, and SSH keys. New supporting vars:
  - `AI_CONTAINER_GROUP` — selects the group (default: `default`).
  - `AI_CONTAINER_GROUP_INIT` — non-interactive bootstrap override when a group directory does not yet exist. Values: `clean` (start empty), `from:host` (copy group-scoped dotfiles from `$HOME`), `from:<existing-group>` (copy from another group under `~/.ai-containers/`).
  - `AI_CONTAINER_HOST_ACK` — set to `1` to silently bypass the macOS warning when `AI_CONTAINER_GROUP=host`. Per-invocation; not persisted.

### Removed

- `SSH_SCOPE_DIR` env var. See the breaking-change entry above for migration steps.

- Pre-grouping macOS auto-migration code (was an internal one-shot for moving the legacy flat `~/.ai-containers/.claude`-style layout into `~/.ai-containers/default/`). The only host that ever had that layout has been migrated by hand; new installs go straight to the group structure.

### Changed

- **`.ssh` is now mounted read-write.** The mount was previously read-only. Because `.ssh` now lives inside the group directory (`~/.ai-containers/<group>/.ssh/`) rather than the host's `$HOME/.ssh/`, the original rationale for read-only (preventing container writes from corrupting host SSH keys) no longer applies. The change allows SSH to update `known_hosts` inside the container, restores `ControlMaster` multiplexing, and eliminates `Failed to add the host to the list of known hosts` stderr noise.

- **macOS and Linux dotfile mount paths are now identical.** The previous platform-specific redirect (active only on macOS for Claude Code, Copilot CLI, Kiro CLI, and GitHub CLI) has been replaced by the unified group-root logic. Both platforms now resolve agent dotfile mounts through `~/.ai-containers/<group>/` (or `$HOME` when `AI_CONTAINER_GROUP=host`).
