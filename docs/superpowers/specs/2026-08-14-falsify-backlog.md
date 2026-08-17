# Increment 5 — parked findings

Committed, not scratch: the SDD workspace is deleted on completion and a
finding that lives only there is a finding that gets dropped.

**Status:** OPEN

---

## F1 — `repo.sh` executes 2 of its 19 functions under the hermetic suite

`tests/test-repo-registry.sh` sources `repo.sh` in a subshell deliberately
arranged so that "dispatch never runs, no side effects occur" (the test's own
comment). Only `is_git_url` and `fmt_epoch` are invoked. Every `cmd_*`
subcommand — `add`, `sync`, `reset`, `list`, `rm`, `gc`, `reindex` — plus
`seed_from_*` and `sync_from_*` is unexercised, and nothing else in the suite
shells out to `repo.sh` either.

Not a bug, and not an argument that the subshell arrangement is wrong — it is
there to stop the tests seeding real Docker volumes. But it means `repo.sh` is
effectively untested hermetically, and it is the script that owns destructive
operations (`rm`, `gc`, `reset`) against volumes shared by every project.

**Why it is parked rather than fixed here:** mutating `repo.sh` today would
yield survivors that measure the absence of a harness, not the quality of an
assertion — the failure mode the ledger exists to keep out. It needs coverage
first, then entry to the mutation tier.

## F2 — `sandbox.sh`'s discovery and open modes are never executed hermetically — **PARTLY CLOSED 2026-08-14**

`tests/test-mode-capabilities.sh` now runs `sandbox.sh` in **all three** modes
against a fake `docker`, so the argv-parsing and mode-dispatch paths of discovery
and open are executed. What remains unexecuted is everything the three modes do
*differently* beyond the capability array — notably discovery's
`output_mount_flags` branch. The entry stays open for that remainder.

### Original finding

`sandbox.sh` runs as a real subprocess (only `docker` faked) in
`test-docs-path.sh`, `test-tool-config-mounts.sh` and `test-tools-d.sh` — but
**only ever as `sandbox.sh restricted`**. `tests/test-open-mode.sh` greps and
`bash -n`s the other two modes rather than running them.

Covered by integration cases `110`, `120`, `210`, `220`, `230`, so this is a
tier gap rather than an absence of coverage. Worth closing because the hermetic
tier is the cheap one: the same fake-`docker` technique that already drives
restricted mode would extend to both other modes for very little.

## F3 — `any_active` in `sandbox-common.sh` is dead code

Zero callers repo-wide (verified by grep). Either a leftover or an intended
extension point that never landed. Deleting it is a one-line change; the reason
it is recorded rather than done is that it belongs to no task in this
increment's plan and a drive-by deletion is how unrelated breakage gets
attributed to the wrong change.

## F4 — `install-tools.sh:api_get` is unexercised

The release-type branch's GitHub API call. Confirmed unexercised within the 45
hermetic tests; not chased beyond that scope. Its siblings `install_repo_file`,
`install_url` and `expand_placeholders` all execute transitively via
`install_one`, so this is a single gap in an otherwise well-covered file.

---

# Found by running the demonstrations on a real host (2026-08-14)

## F5 — `300-allowlist-delivered` has no known-bad mutation, and its honest one needs an image rebuild

The case asserts the allowlists inside the image are the ones `build.sh`
generated. Its own header explains the stake: `refresh-ipset-allowlist.sh` reads
those exact paths to build the ipset that **is** the firewall, so a mismatch is
"a silently wrong firewall" that `010` and `020` would both still pass.

It carries a `security` tag but not a tier tag, so the coverage ratchet does not
reach it. It is currently exempted **explicitly, as a tracked gap** in
`tests/test-mutations.sh`'s `case_exempt()`, with a pointer to this entry — not
silently skipped.

**Why it is not simply fixed:** the honest mutation breaks delivery, i.e. the
`COPY allowlist-*.txt /tmp/` lines in the Dockerfile. Every other demonstration
mutates a case file or a host script and runs against a **pre-built, reused**
image; a Dockerfile mutation only takes effect on a rebuild, which
`demonstrate-network-tier.sh --reuse-image` deliberately avoids. Closing this
needs either a rebuild path in that script for Dockerfile-touching patches, or a
mutation that breaks delivery without touching the image build. Do not "solve"
it by mutating the case instead of the product — that tests the test.

## F6 — `it_wait`'s first parameter is documented as seconds but counts iterations

`tests/integration/lib.sh:95` — `it_wait() { # $1=timeout seconds …` — and the
body is `while i < t; do "$@"; i++; sleep 1; done`. When the polled predicate is
cheap, iterations ≈ seconds and the name is harmless. When the predicate blocks,
wall-clock is `t × (predicate cost + 1s)`: `080`'s predicate calls `reach()`, a
`curl` with `--connect-timeout/--max-time IT_CONNECT_TIMEOUT` (5s), so
`it_wait 60` can cost 360-420s against a nominal 60.

**Why it went unnoticed:** on the success path the predicate returns true on the
first or second poll, so the loop never approaches its bound. Only the
*exhausted* path — which nothing exercised until these demonstrations — pays the
multiplied cost. `080`'s mutated run hit the 300s case timeout during the first
of three waits.

Worked around at the call site (`080`'s patch carries `# timeout: 900`) rather
than changed here, because renaming or re-basing `it_wait`'s parameter touches
every caller in the corpus and belongs in its own change. Candidate fixes: rename
the parameter to `max_polls`, or make it a real deadline with `EPOCHREALTIME`.

## F7 — `230-open-drops-capabilities` is named and tagged for open mode but launches discovery

**Partly addressed 2026-08-14:** the header's false "both belts" claim is
corrected in place, because a comment asserting something demonstrably untrue
misleads the next reader more than no comment would. The rename remains.

Its code is `sandbox_up discovery "$adir" -e DISCOVERY_CAPTURE_ENABLED=0`, which
is a deliberate and correct strengthening (discovery *grants* NET_ADMIN/NET_RAW,
so proving the agent shell holds neither there is stronger than proving it where
nothing was granted). But the case's basename, its `tags: … open`, its
`summary:` line, and the header sentence claiming it asserts "both belts" all
describe a case that no longer exists.

The missing belt is now covered by `240-open-grants-no-capabilities`. What
remains is to make `230` say what it does: rename it (e.g.
`230-discovery-drops-capabilities`), fix its tags and summary, and delete the
"both belts" sentence, which `240` now owns. A rename touches its mutation
patch's `# case:` header and `AGENTS.md`'s reference to "case 230", so it is a
small coordinated change rather than a one-liner.

## F8 — three surviving mutants in `tests/integration/mutate.sh`'s guard cluster

The falsify pilot found five survivors around `mutate.sh`'s entry guards. The
clean-tree gate is **fixed** (`tests/test-mutations.sh` now asserts `apply`
refuses a dirty tree, says why, and records no state), and that one assertion
kills two of the five — `L144 && -> ||` and `L147 exit 1 -> exit 0`. Measured,
both directions, not assumed.

Three still survive, each a genuinely separate gap:

| Mutant | What it disables | Why nothing notices |
|---|---|---|
| `L141 exit 1 -> exit 0` | the already-applied guard's refusal | the suite asserts `apply` is *not* blocked once state clears; never that it *is* blocked while state exists |
| `L143 require_git_usable \|\| exit 1 -> exit 0` | the git-unusable path's status | that path is never exercised |
| `L74 return 1 -> return 0` | `require_git_usable`'s own verdict | same — no test makes git unusable |

`L141` needs one assertion in the existing `MT_REPO` fixture: apply, then apply
again without reverting, and require a non-zero exit naming the applied mutation.
`L143`/`L74` need a fixture where git is genuinely unusable — the ownership-
mismatch shape `require_git_usable` was written for. `tests/test-mutations.sh`
already fakes `git` on `PATH` for the rollback test, so the technique exists.

**Corrected 2026-08-16 (Task 10).** Three was an undercount, from a partial pilot
run. The full corpus finds **five** damages in this cause, and F20 supersedes
this entry: `L242 exit 1 -> exit 0` (`cmd_revert`'s "still records what could not
be reverted") and `L206 return 0 -> return 1` (`cmd_revert` with nothing applied)
are the two this table missed. `L141` and `L242` are the same trimmed line, so
they share one ledger identity and one entry must speak for both.

Kept as a backlog entry rather than fixed inline because the falsify tier's own
ledger is the right home for survivor accounting, and these three are its first
entries — recorded here so Task 10 starts from a known state instead of
rediscovering them and treating them as new.

## F9 — the generator cannot reach a comparison inside a backslash-continued `(( ))` — **FIXED 2026-08-14**

`falsify_scan_line` now takes an incoming span depth and publishes the depth it
ends at; the caller carries that forward whenever a line ends in a backslash.
Measured strictly additive — exactly one mutant gained on `bash-floor.sh`, none
lost — and two across the stage-1 corpus (247 -> 249). The pinned count moved
12 -> 13, and the `34` total that duplicated it is now derived from `PINNED`
rather than hardcoded a second time, since raising one left the other stale.
Demonstrated: reverting the carry fails both assertions by name.

### Original finding

`tests/falsify/generate.sh` scans `[[ ]]`/`(( ))` spans **per line**, with no
continuation tracking, so `<`/`>` inside a multi-line arithmetic condition is
never mutated. The span restriction itself is necessary — without it the operator
mangles redirections — but the per-line implementation under-generates silently,
which is the worse failure direction for a tool whose whole job is finding gaps.

The instance that exposed it is not incidental: `bash-floor.sh:40-42` is the
**bash floor check itself**, the comparison that decides whether this repo
refuses to run at all, and it holds **two** unmutatable `<` operators:

```
if (( BASH_VERSINFO[0] < AI_CONTAINERS_BASH_FLOOR_MAJOR \
   || (BASH_VERSINFO[0] == AI_CONTAINERS_BASH_FLOOR_MAJOR \
       && BASH_VERSINFO[1] < AI_CONTAINERS_BASH_FLOOR_MINOR) )); then
```

`tests/test-bash-floor.sh` may well assert the floor correctly — the gap is that
the mutation tier cannot *check* whether it does, so this comparison is outside
the guarantee the tier exists to provide.

Fixing it moves `bash-floor.sh`'s pinned count from 12 to at least 13, so the
pinned-count assertions in `tests/test-falsify-generate.sh` must be updated in
the same change — deliberately, so the count cannot drift silently. Joining
continuation lines before the span scan is the obvious approach; the mutated
output must still be written back to the correct single physical line.

## F10 — a single-clause `if [[ X ]];` yields two semantically identical mutants

`cond-negate` produces two distinct mutants that damage the condition the same
way, so any survivor among them is double-counted in the ledger. Harmless to
correctness, wasteful to review, and it inflates the survivor count that R1's
re-scope trigger reads. Dedupe survivors by mutated text when the ledger is built
(Task 7), rather than by suppressing generation — two mutants that happen to
coincide today may diverge if the operator changes.

## F11 — two survivors in `tools-lib.sh`, the tier's first real output — **ONE FIXED 2026-08-14**

`tools-lib.sh:62` is killed: `tests/test-tools-d.sh` now parses a descriptor with a
blank line mid-file and a final line carrying no trailing newline. Re-measured
through the tier: 17 mutants, **16 killed, 1 survived** (was 15/2).

The `tools-lib.sh:42` return-flip survivor remains — `tools_list_names`'s
"no descriptor directory" path, still unexercised.

**Re-measured 2026-08-16 (Task 10):** `17|14|1|2` — 14 killed, 1 survived, **2
unproven**. The "16 killed" above was counted before the `UNPROVEN` verdict
existed (F12, fixed 2026-08-16): the two `tools-lib.sh:62` **cond-negate**
damages hang rather than assert and are now recorded honestly as unproven, in
F22. The **logic-flip** on that line — the `||` -> `&&` this entry's fix was
aimed at — is genuinely killed, so the fix stands; only the accounting moved.
The `tools-lib.sh:42` survivor is unchanged and is entry 12 of the ledger.

### Original finding

`tests/falsify/run.sh --target tools-lib.sh` — 17 mutants, 15 killed, 2 survived
(11.8 %, better than the pilot's 24.1 % ex-`stream-flip` projection). Both are
`GAP`, not `EQUIVALENT`, and the second is a live product risk.

**`tools-lib.sh:62` `logic-flip` (`e46b949d`) — GAP, product-relevant.**

    while IFS= read -r line || [[ -n "$line" ]]; do     ->  && 

The `||` is the standard idiom for reading a final line that carries no trailing
newline. With `&&` the loop stops at the first EMPTY line instead. Verified by
running both against a descriptor holding a blank line between two keys:

    pristine:  repo=[a/b] binary=[x]        <- correct
    mutated:   repo=[]    binary=[blank]    <- silently wrong

Nothing in the suite notices, so a `tools.d/*.conf` with a blank line — or one
whose last line lacks a newline — could parse wrong with every test green. The
killing assertion is a fixture descriptor containing both shapes.

**`tools-lib.sh:42` `return-flip` (`f128fd8d`) — GAP, narrow.**

    [[ -d "$TOOLS_D_DIR" ]] || return 0     ->  return 1

`tools_list_names`'s "no descriptor directory" path. Callers treat non-zero as an
error, so the status is contractual, and no test exercises a missing
`TOOLS_D_DIR` at all.

Both are the first entries the tier produced on real code rather than on its own
fixtures, which is the evidence Task 9's ship gate is aimed at.

## F12 — a timeout counts as a KILL — **FIXED 2026-08-16, after it fired for real**

A timeout is now its own verdict, `UNPROVEN`, and `check-ledger.sh` demands a
classification for it exactly as for a survivor. A timeout that ALSO produced a
`FAIL:` line stays a kill — the assertion was observed failing before the clock
ran out.

This was upgraded from a prediction to a demonstrated defect by a macOS host
run: the fixture mutant in a function **nothing calls** — which cannot hang —
timed out under load and was reported KILLED. A slow oracle was silently
reclassifying a real survivor as killed, which is the one failure direction this
tier cannot tolerate: it hides the only output it exists to produce.

(The load was self-inflicted — a background agent was seeding scratch trees in
the same working tree. That explains the trigger, not the defect: the verdict
logic was wrong either way, and a busy CI runner would have done the same.)

### Original finding

`run.sh` counts a per-mutant timeout as KILLED and flags it — deliberate, and its
header says why: an oracle that hung "was not observed asserting anything". But
the `TOTAL` line's killed column folds those in, so a reader sees a kill rate
that is partly hangs.

Measured on `tools-lib.sh` (`TOTAL|1|17|15|2|5|11|…`), the 15 kills are three
different things:

| Signal | Count | What it means |
|---|---|---|
| `exit+failline` | 10 | clean kill — the oracle ran and an assertion failed |
| `timeout+exit+failline` | 3 | asserted a failure, *then* ran long — a real kill, slow |
| `timeout+exit` | **2** | hung with no `FAIL:` line — **no assertion was observed** |

So the proven signal is 13/17, not 15/17, with 2 unproven — not the 10/17 first
reported, since three of the five timeouts did assert before hanging.

Both unproven mutants are the same line, `tools-lib.sh:62`'s `while IFS= read -r
line || [[ -n "$line" ]]`, negated. That makes the read loop never terminate, so
the mutant is "detected" only in the sense that CI would eventually time out.
That is a real property of the test — it would hang rather than report — but it
is not evidence that an assertion exists, which is the only thing this tier
measures.

**For Task 10:** do not read `TOTAL`'s killed column as the kill rate. Split it
by the `signal` field and treat `timeout` without `failline` as UNPROVEN — a
third verdict beside KILLED and SURVIVED. An unproven mutant deserves the same
ledger treatment as a survivor: it names a place where the suite does not
demonstrably assert anything.

## F13 — nothing yet runs the ledger gate — **FIXED 2026-08-16**

The `falsify` job in `hermetic-checks.yml` (so both PR and nightly inherit it
from one definition) and Phase 6 in `verify-on-host.sh`. Both run the whole
corpus and then the ratchet, as one operation. Two registry rows in
`tests/layer-checks.conf`; `local ⊇ nightly ⊇ PR` re-verified.

### Original finding

`check-ledger.sh` exists and is tested against fixtures, but no CI job and no
`verify-on-host.sh` phase feeds it a real corpus run. Until Task 11 wires it, the
ratchet protects nothing in practice.

It must be wired to a **full-corpus** run: under a partial selection the scope
rule makes the stale and obsolete checks vacuous for unselected files. And
`run.sh`'s exit status is a separate signal from its stdout, so a naive
`run.sh | check-ledger.sh -` discards it — capture to a file and check both.

## F14 — no mechanical guard against awk interval quantifiers

The floor run caught `/^[0-9a-f]{40}$/` in `tests/test-falsify-generate.sh`:
ubuntu:22.04's mawk has intervals disabled, so the pattern matched no sha1 and
every well-formed line was counted malformed. Fixed at the site, and the trap is
documented in `tests/portability.sh`'s header.

What does NOT exist is a check. `tests/bash-dialect-lint.sh` is version-gated for
*bash* constructs against a declared bash floor; there is no declared awk floor,
and detecting an interval inside an awk program string by regex is unreliable
because those programs span lines and are quoted several ways.

So the guard here is prose plus one worked example — weaker than this repo's
norm, recorded as such rather than pretended otherwise. The floor run does catch
it, which is how this one was found; the gap is that it catches it late rather
than at lint time.

## F15 — `bash-floor.sh`'s re-entry guard: 3 survivors on one line

`bash-floor.sh:19` — `return 0 2>/dev/null || exit 0`, the guard that makes the
file a no-op on a second source. Three mutants of that one line survive:

| Mutant | Effect |
|---|---|
| `return 1 … \|\| exit 0` | a re-source returns 1 instead of 0 |
| `return 0 … && exit 0` | when EXECUTED, `return` fails, `&&` short-circuits, and execution falls THROUGH the guard into the rest of the file |
| `return 0 … \|\| exit 1` | when EXECUTED, exits 1 instead of 0 |

**Corrected 2026-08-16 (Task 10): the sentence below is wrong for one of the
three.** `return 1 … || exit 0` is NOT direct-execution-only — a plain SECOND
SOURCE then returns 1 and the `source` command's status becomes 1. Measured, that
damage IS killed by a hermetic test: `tests/test-migrate-runme.sh`, whose
`source ./project-init.sh; printf "rc=%s" "$?"` assertion sees it
(`project-init.sh:18` sources `bash-floor.sh`, `sandbox-common.sh` sources it
again). It survives the tier only because `test-bash-floor.sh` — the oracle
`targets.conf` names for this target — is not that test, which makes it an
instance of F16 rather than of this entry. The other two are direct-execution
only, as stated. `shared-files.sh:28` carries the identical guard and the
identical three mutants; its `return 1` damage is killed by its OWN oracle
(`test-shared-files-parity.sh`, and `test-sync-project.sh`), so only two of its
three survive. Both files' surviving direct-execution damages are entries 1-2 of
`tests/falsify/survivors.txt`.

All three concern what happens when `bash-floor.sh` is **executed directly**
rather than sourced, and nothing exercises that. The idiom is subtle in exactly
the way this repo has already been bitten by: `return` SUCCEEDS when sourced and
returns immediately, so the `||` half is never evaluated; it is only reached when
the file is executed, where `return` fails. A guard written as "fail loudly"
under this idiom can therefore never have failed at all — that is a defect this
project found once already, in `tests/lib-verify-repo.sh`.

`GAP`, all three, one shared cause. The killing assertion is to execute
`bash-floor.sh` directly — once plainly, once with
`_AI_CONTAINERS_BASH_FLOOR_SOURCED=1` preset — and assert the exit status and
that it does not fall through. Not fixed here because this increment's
bugs-first slot went to the floor COMPARISON above, which was the graver of the
two: it inverted the guard rather than mis-reporting its status.

---

# Found by classifying the first full corpus run (Task 10, 2026-08-16)

`tests/falsify/survivors.txt` now carries all 32 identities (36 SURVIVED + 4
UNPROVEN = 40 records) as **12 entries**: 31 GAP, 1 EQUIVALENT. Every entry below
states a **measured** fact — each surviving damage was applied to a throwaway
copy of the tree and the **whole 52-test suite** run against it, so "no test
kills this" is an observation, not a reading of the source. That measurement
overturned three classifications that a static read would have got wrong (see
the F8, F11 and F15 corrections above, and F16 below).

## F16 — the tier's oracle map is 1:1, but three targets are driven by several tests

**Nine of the 32 ledger identities (11 distinct damages) are killed by a
hermetic test that is not the oracle `targets.conf` names for their target.**
Measured one damage at a time against the full suite:

| Target · line | Damages | Killed by | Declared oracle |
|---|---|---|---|
| `tests/lib-verify-repo.sh:325` (`add_origin`) | 4 | `test-verify-exit-code.sh`, `test-layer-containment.sh` | `test-lib-verify-repo.sh` |
| `tests/lib-verify-repo.sh:313` (`MK_REPO_PROBE`) | 3 | both of the above | same |
| `tests/lib-verify-repo.sh:326` (`MK_REPO_UNTRACK_SH`) | 1 | `test-verify-exit-code.sh` | same |
| `tests/portability.sh:36` (`p_stat_meta`) | 3 | `test-allowlists.sh`, `test-falsify-generate.sh` | `test-portability.sh` |
| `bash-floor.sh:19` (`return 1` half) | 1 | `test-migrate-runme.sh` | `test-bash-floor.sh` |

This is `targets.conf`'s own documented failure mode arriving from the opposite
direction. That file guards against a target whose code the oracle never
executes (the GREPPED-ONLY rows); it has no defence against a target whose code
**three** tests drive while the row format allows one name. The tier then reports
eleven kills as survivors, and a reader who trusts the ledger goes looking for
assertions that already exist.

`tests/lib-verify-repo.sh` is the clear case: it is a shared harness library, and
its `mk_repo` knobs exist *for* the other two tests — `test-verify-exit-code.sh`
asserts both directions of `add_origin` (`mk_repo 0 0` must make Phase 5 fail
with "no usable BASE_REF", `mk_repo 0` must make it pass) and
`test-layer-containment.sh` owns `MK_REPO_PROBE`. `tests/portability.sh` is the
subtler one: `test-portability.sh` only requires `p_stat_meta` non-empty, and on
GNU `stat -f '%N %z %m' F` is not an invalid option — it means `--file-system`
and prints filesystem information, non-empty — so its own oracle structurally
cannot see the branch swap, while two other tests that fingerprint files with it
catch it by effect.

**Fix:** the multi-oracle row type already named as a prerequisite on the
DEFERRED `sandbox-common.sh` row. With it, these eleven damages become kills with
no new assertion written. **Do not** "fix" this by adding duplicate assertions to
the declared oracles — that would test the same fact twice to satisfy a mapping
defect. Until it lands, `verify-on-host.sh`'s and CI's survivor count is
overstated by nine identities.

## F17 — `tests/lib-verify-repo.sh`'s git bootstrap and probe are never run under a failing git

Three surviving logic-flips, no test anywhere kills them (measured):

| Line | Damage | What it disables |
|---|---|---|
| `181` | `git init -b main \|\| git init` -> `&&` | the git < 2.28 fallback in the probe |
| `322` | same, in `mk_repo` | the same fallback in the stub repo |
| `183` | `git add f && git commit` -> `\|\|` | the probe's commit step, silently skipped |

On any modern git the second `init` is an idempotent re-init, so the `&&` form is
indistinguishable; the damage appears only where `git init -b` FAILS, leaving a
repo with no commit — which is the "Phase 7 parsed no files" vacuous pass the
probe above them exists to prevent. `183` is worse in kind: `git add f || git
commit` skips the commit whenever `git add` succeeds, so the probe stops proving
git can commit while still reporting success — a guard that cannot fail, the
defect class this file was rewritten to remove.

**Killing assertion:** a faked `git` on `PATH` (the technique
`tests/test-mutations.sh` already uses) in two shapes — one that rejects `-b`,
requiring `mk_repo` to still yield a repo with a tracked committed file; one
whose `commit` fails, requiring the source of `lib-verify-repo.sh` to abort with
its named probe message.

## F18 — `lib-layer-checks.sh`'s missing-file and unset-registry paths return the wrong status

`wf_jobs:87`, `wf_steps:96`, `wf_job_key:116` all carry
`[[ -f "$f" ]] || { echo "no such workflow: $f" >&2; return 1; }`; flipping the
status to 0 keeps the message and tells the caller it succeeded. Same for
`lc_rows:33`, the `LAYER_CHECKS_CONF` unset/missing branch. Nothing kills any of
them (measured).

The file's header promises "EVERY function here fails loudly and non-zero on an
empty result", and `test-layer-checks-parser.sh` does exercise that for every
EMPTY-RESULT path — but for the MISSING-FILE path only in `wf_triggers_on`, whose
identical `return 1` at `:165` is killed for exactly that reason. The three
functions the containment guard actually calls are unprotected.

**Killing assertion:** four more calls in the idiom already in that file —
`wf_jobs`/`wf_steps`/`wf_job_key` against a nonexistent path, and `lc_rows check`
with `LAYER_CHECKS_CONF` pointing at an absent file — each required to fail.

## F19 — `mutate.sh`'s sibling-layout resolution is unexercised, and survives by accident

`:41`'s `base/` fallback and `:52`'s `GIT_ROOT` resolution exist for
mgd-ai-containers, where the engine lives under `base/` and `APPLY_PREFIX` must
become `base` so one patch set serves both repos. In this repo the fallback never
fires, and inverting it is nearly harmless **by accident**: `cd` into a
nonexistent `base/` fails, the substitution yields the empty string, `cd ""`
succeeds without moving, `GIT_ROOT` resolves from the caller's own directory, and
`${REPO_DIR#"$GIT_ROOT"/}` on an empty `REPO_DIR` is empty, so
`${APPLY_PREFIX:+…}` expands to nothing and every patch still applies. Verified
each step in a shell.

The accident is the finding: a resolution that is load-bearing for the port
depends on the CWD to come out right here.

**Killing assertion:** two fixture trees — `build.sh` at the root, and the engine
under `base/` — asserting the `REPO_DIR`/`GIT_ROOT`/`APPLY_PREFIX` triple derived
for each, from a CWD outside both.

## F20 — five `mutate.sh` refusal paths report success (supersedes F8)

`:141` and `:242` (`exit 1` -> `exit 0`, one shared ledger identity), `:143`
(`require_git_usable || exit 1` -> `exit 0`), `:74` (`return 1` -> `return 0`),
`:206` (`revert` with nothing applied, `return 0` -> `return 1`). None killed
(measured). Every one is a STATUS, and `mutate.sh` is driven by CI
demonstrations and by a human's shell, both of which branch on `$?`.

**Killing assertions:** apply twice without reverting, requiring a non-zero exit
that names the applied mutation; a faked `git` that cannot resolve `--git-dir`,
requiring `apply` to refuse non-zero; and `revert` with no state file, requiring
exit 0.

## F21 — `mutate.sh revert` reverses twice on any host with `tac`

`:236`'s `done < <(tac "$STATE" 2>/dev/null || sed '1!G;h;$!d' "$STATE")` picks
ONE reverser. With `&&`, on any host that has `tac` BOTH run, so every applied id
is fed to the loop twice; the second pass finds the patch already gone, takes the
`git apply --check` branch, prints "Already absent", and `revert` still exits 0
with the state file removed. The two facts that block comment insists on —
reverse order, and "I undid it" vs "it was already gone" being different outcomes
— are both violated with the suite green. Not killed (measured).

**Killing assertion:** apply two mutations and require `revert` to print exactly
one `Reverted <id>` line per id, in reverse order, and no "Already absent" line.

## F22 — four damages hang the oracle instead of failing it; no oracle is time-bounded

The 4 UNPROVEN records. `tools-lib.sh:62` (two cond-negate damages) and
`tests/bash-dialect-lint.sh:105` (one) negate a `while read` condition, which at
EOF stays true forever; `tests/integration/docker-shim.sh:60`'s `cmp-flip` makes
the self-reference guard reject a REAL docker and accept the shim, so the shim
re-execs itself. In all four the per-mutant clock expires with no `FAIL:` line —
nothing was observed asserting.

**This is a GAP, not equivalence-by-hang.** The mutated program is observably
different (it does not terminate), the difference is cheap to observe, and
`docker-shim.sh`'s own header records this exact hang being hit by hand on
2026-08-09 — which is why that guard exits 127 rather than warning. What is
missing is a BOUND.

**Killing assertion:** run the damaged path under an explicit `timeout` and fail
by name when it expires — parse a descriptor under `timeout 10` requiring both
completion and the parsed values; run `bash-dialect-lint.sh` over a fixture under
`timeout 10` requiring its exit status; invoke the shim with a self-referencing
`IT_REAL_DOCKER` under `timeout 10` requiring exit 127. Note that three siblings
of the docker-shim damage on the same line DID print a `FAIL:` before their clock
ran out and are recorded as kills, so the distinction is real rather than an
artefact of load.

## F23 — `p_sha1`'s platform probe can be inverted with every test green

`tests/portability.sh:40`. Not killed by anything (measured), and the only
portability survivor of which that is true — the `p_stat_meta` ones belong to
F16. This machine has BOTH `sha1sum` and `shasum` and they print the same digest
for the same file (verified), so no assertion on `p_sha1`'s OUTPUT can
distinguish the branches. Its `p_md5` sibling is killed only by an accident of
tool population: `md5 -q` does not exist on Linux, so the inverted probe prints
empty and the non-empty assertion catches it — a kill that measures the platform,
not an assertion aimed at branch selection, and one that would stop working on a
host carrying both.

**Killing assertion:** run `p_sha1` with a `PATH` from which `shasum` is absent
and require a correct digest (and the mirror on a BSD host with `sha1sum`
absent), so the helper is asserted to pick the tool the platform actually has.

## F24 — **RESOLVED 2026-08-16.** The run and the check are one operation on the commit under review, in CI and Phase 6 alike, so re-scoring every entry is the normal case rather than an accident to avoid — and the only circumstance in which the ledger is actually true. A fix and its ledger edit land in one commit: forget the edit and check D (obsolete amnesty) fails; make the edit without the fix and check B (survivor with no entry) fails. Original finding: a fix and its ledger entry cannot land in the same commit as the run that justified them

Structural, found while deciding whether to close a GAP here.
`check-ledger.sh --run-output <file>` checks the ledger against **one** recorded
run. Adding the assertion that kills a survivor does not change that file, so the
entry must STAY (check B: a survivor with no entry fails) while now describing a
closed gap; and re-running the corpus to remove it invalidates every other entry
that the new run happens to score differently — the UNPROVEN verdicts especially,
since they are timing-dependent. So "fix a GAP" and "update the ledger" are one
atomic operation gated on a fresh full-corpus run, not two edits.

Task 11 wires the gate, and this is the constraint it has to design for: either
the run output becomes a committed artefact regenerated with the ledger, or the
gate runs the corpus itself. It also means the bugs-first policy cannot be
satisfied *inside* a classification task without re-baselining — which is why
Task 10 records eight causes and closes none.

## F25 — `p_stat_meta`'s GNU/BSD branch swap survives the entire suite

`tests/portability.sh:36`. Both mutants of that line — `cmp-flip` and
`cond-negate` of `[[ "$_P_STAT_GNU" == "1" ]]` — swap the GNU and BSD branches,
and **nothing in the 52-test suite notices**. Measured one damage at a time
against the whole suite in a scratch tree, not inferred.

The damage is real. On GNU, `stat -f '%N %z %m' F` is not an invalid option —
it means `--file-system` — so the swapped branch emits filesystem information
plus an error instead of `path size mtime`:

```
pristine: tests/portability.sh 3074 1786868760
mutated:  stat: cannot read file system information for '%N %z %m' …
```

`test-portability.sh` asserts only that `p_stat_meta` is NON-EMPTY, and that
garbage is non-empty. `p_stat_mode` one line up has a VALUE assertion and all
three of its mutants die — which is why the meta line looked covered by
association, and why Task 10 initially filed these two under F16 ("killed by a
non-declared oracle"). They are not; they are a plain missing assertion, and I
moved them out of that group.

Worth stating why this one matters beyond its size: F16's thesis is that eleven
damages are a target-map defect rather than absent coverage, i.e. *do not read
these as missing assertions*. That thesis is right for the rest of the group and
was wrong for these two, and applying it uniformly would have retired a genuine
gap with no coverage written — the exact failure mode the ledger exists to
prevent.

**Fix:** assert `p_stat_meta`'s VALUE like its sibling — three
whitespace-separated fields, the middle one the file's real byte size.

## F26 — `test-falsify-run.sh` was timing-sensitive on macOS — **FIXED 2026-08-16**

Three consecutive macOS host runs failed this file at three DIFFERENT
assertions, and all three were one cause: the fixture oracles inherited
`run.sh`'s 60s per-mutant default, and on that host it was reachable.

The worst shape is worth recording because it reads like a different bug. When
the **baseline** times out, `run.sh` skips the whole target — correctly, since
an oracle that is not green on the pristine tree cannot distinguish anything —
so no `MUTANT` line is emitted and every later verdict lookup returns `MISSING`.
That looks like a broken runner, not a slow host, and the runner's own
explanation was on stderr where no assertion read it.

Fixed in `fx_run`, one place rather than twelve call sites: a generous default
`--timeout 300` (every fixture oracle is sub-second, so any timeout at all means
the machine was slow), overridable via `FX_TIMEOUT`, and skipped entirely when
the caller passes its own `--timeout` — case 11 uses `--timeout 1` deliberately
to exercise the timeout path and must not be overridden. `fx_run` now also
prints the runner's stderr when a run emits no `MUTANT` line at all.

Verified both halves: case 11 still reports `UNPROVEN` with `timeout+exit`, and
forcing `FX_TIMEOUT=1` produces the diagnostic naming `oracle … is not green on
the PRISTINE tree`.

**This is a test-fragility fix, not a product fix**, and the distinction matters
for the ledger: no mutation-tier verdict changes, and nothing about `run.sh`'s
behaviour changed. What changed is that a slow host now fails honestly or not at
all, instead of failing somewhere unrelated.

## F27 — mutation verdicts are environment-dependent, so the ledger could not be satisfied everywhere at once

Phase 6's first real host run (macOS, 2026-08-16) failed with 12 findings, and
none of them was a code defect. The same 249 mutants on the same commit:

| | Linux | macOS |
|---|---|---|
| killed / survived / unproven | 209 / 36 / 4 | 211 / 24 / 14 |
| timeouts | 11 | **63** |
| wall clock | 3.4 min | **16 min** |

Two distinct causes, both now handled rather than tuned around.

**Timeouts are machine speed, not code.** Requiring a ledger entry per UNPROVEN
identity made the ledger say different things on different hosts. UNPROVEN is
now REPORTED and may be classified, but is no longer REQUIRED to be.

**Some verdicts genuinely differ by environment.** `tests/portability.sh`'s
`p_md5` branch inversion is KILLED on Linux — only `md5sum` exists, so the
flipped branch reaches a missing `md5` — and SURVIVES on a mac carrying both,
where either branch works. Filing it `GAP` demands an assertion that cannot
exist there; `EQUIVALENT` is false on Linux; leaving it unfiled fails check B on
the mac while filing it fails check D in CI. Hence a third classification,
`ENV-DEPENDENT`, exempt from check D only and still required to give a reason.

**And obsolete amnesty is hygiene, not safety**, so it is fatal only under
`--strict`, which the reference environment (CI, ubuntu-latest) uses. Check B —
a survivor with no entry — stays fatal everywhere, because that is the ratchet:
a stricter host simply requires MORE entries, which is always satisfiable.

Verified across the full matrix: Linux `--strict` 0 problems, macOS-equivalent
default 0 problems, and a plain `GAP` entry for a killed mutant still fails
under `--strict` while an `ENV-DEPENDENT` one does not.

## F28 — the tier measures materially less on macOS, and the shortfall is variable

Phase 6 passes on macOS, but it should not be read as measuring what it measures
on Linux. Same 249 mutants, same commit:

| run | killed | survived | unproven | timeouts | wall |
|---|---|---|---|---|---|
| Linux | 209 | 36 | 4 | 11 | 3.4 min |
| macOS #1 | 211 | 24 | 14 | 63 | 16 min |
| macOS #2 | 192 | 22 | **35** | 71 | 16 min |

**14 % of the corpus produced no verdict** on the second run, and the number
moved 4 → 14 → 35 across runs of the same code, so `--timeout 120` sits right at
the edge there rather than comfortably above it. The shortfall concentrates in
the two most fork-heavy oracles: `test-bash-dialect-lint.sh` (11 of 27
unmeasured) and `test-mutations.sh` (17 of 55) — both spawn many subprocesses
per assertion, and process creation is markedly slower on macOS.

This is correctly NOT a gate failure (F27: an unproven mutant is machine state,
not a property of the code). The risk is subtler: a green Phase 6 on macOS can be
green partly because a third of the interesting mutants were never scored, and
19 stderr notes are not where a reader looks. Phase 6 now prints the measured
fraction and warns above 10 %.

**Not fixed, and the options all cost something.** A higher `--timeout` extends a
run already at 16 minutes; fewer jobs may or may not help, since the host has
more cores than the workers can saturate and the bottleneck looks like process
creation rather than CPU. Worth measuring before choosing: run Phase 6 with
`--timeout 300` and with `--jobs 6` and compare the unproven count against the
wall clock. **CI (ubuntu-latest) is the reference environment and does not have
this problem**, so the ratchet's strength is unaffected; what degrades is the
local layer's ability to add information beyond CI.

## F29 — CI killed a mutant the sandbox container could not, because the product installs itself at the default path

The `falsify` job's first CI run failed with one finding:
`tools-lib.sh:return-flip:f128fd8d` was a ledger entry for a mutant CI reports
KILLED. It survives in the authoring container. Root-caused rather than
reclassified on suspicion:

`tools-lib.sh:37` defaults `TOOLS_D_DIR` to `/etc/ai-containers/tools.d`.

- On `ubuntu-latest` that path is **absent**, so `[[ -d … ]] || return 0` fires,
  the mutated `return 1` reaches a caller, and the oracle sees it → **KILLED**.
- Inside a **built ai-containers sandbox** the product installs its own
  descriptors there (`dtctl.conf`, `dtmgd.conf`, …), the guard passes, the
  mutated return is never evaluated → **SURVIVED**, against the whole 52-test
  suite.

That single mutant is the entire difference between CI's `210/35/4` and the
container's `209/36/4` on the same commit.

Reclassified `ENV-DEPENDENT`, which is exactly the case that classification was
added for. **The underlying gap (F11) is still real and still worth closing** —
no test points `TOOLS_D_DIR` at a missing directory deliberately. Writing that
assertion makes the verdict KILLED everywhere, at which point the entry should
be **deleted**, not downgraded.

Worth noting for anyone running the tier: **a repo whose product is installed
system-wide can mask its own mutants.** The authoring environment here is a
sandbox built from this very repo, which is convenient and, for this one line,
made the environment part of the measurement.
