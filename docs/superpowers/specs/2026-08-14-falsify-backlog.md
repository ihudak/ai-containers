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

## F5 — `300-allowlist-delivered` has no known-bad mutation, and its honest one needs an image rebuild — **RESOLVED 2026-08-19**

**Closed by giving the demonstrator a rebuild path**, which was the option that
did not weaken anything. The alternative on the table — find a delivery-breaking
mutation that needs no rebuild — turned out not to exist: the case compares the
image's `/tmp/allowlist-*.txt` against the snapshot `run.sh` takes from the same
build, so the only way to make the two diverge is to change what that build
delivers, and nothing outside the build can do that.

**The mutation** is `300-allowlist-not-delivered.patch`, and it ships
`allowlist-cidrs.txt` under the name `/tmp/allowlist-domains.txt` rather than
dropping the `COPY`. The choice is the finding: an ABSENT allowlist empties the
ipset and the container blocks everything, which is loud, whereas a **non-empty
allowlist nobody generated is silent** — every network case mounts its own over
`/it-allowlists` and never reads `/tmp` at all, so 010 still blocks, 020 still
admits, and only 300 can see it. Three adjacent, near-identical `COPY` lines are
exactly what invites that slip.

**The rebuild path.** `demonstrate-network-tier.sh` derives the build-input set
from the Dockerfile — itself, every path it `COPY`s, plus `build.sh`, which
produces both the build args and the `allowlist-*.txt` files it copies — and for
a patch against any of them drops `--reuse-image`, builds WITH the mutation,
then rebuilds clean from the reverted tree *before* classifying the result. Its
EXIT trap `docker rmi`s the image if that restore never happens: reverting the
tree does not un-build an image, and a deliberately wrong one left under the
`ai-sandbox-it` tag would be picked up silently by the next `--reuse-image` run.

Derived rather than listed because a missing entry fails **misleadingly** rather
than loudly: the case runs against an image that never contained the mutation,
passes, and is reported UNDEMONSTRATED — which reads as "this mutation no longer
damages its case" when the truth is "this mutation was never applied to
anything".

**Cost, measured:** the mutated build and the clean restore are both cache-warm
— the allowlist `COPY`s are the last layers in the Dockerfile — so the pair adds
about 18s. The whole `300` demonstration, including the initial image build, ran
in 27.6s.

**Demonstrated, all three directions:**

| break | what the run reads |
|---|---|
| the patch removed | `test-mutations.sh`: `FAIL: 300-allowlist-delivered has a known-bad mutation` |
| `patch_needs_rebuild` neutered | `ERROR (case did not run)`, exit 1 — the case SKIPs, see below |
| the clean restore made to fail | `ERROR-REBUILD`, exit 1, and `ai-sandbox-it` removed on the way out |

and positively: `FAIL: /tmp/allowlist-domains.txt differs from what build.sh
generated` with the mutation applied, `PASS (3 assertions)` without it.

**One measured detail worth not over-generalising.** With the detection neutered,
300 does not pass quietly — it SKIPs, because `--reuse-image` also suppresses the
generated-allowlist snapshot the case compares against, so the wrong path is loud
*for this case*. A mutation to another build input (say `entrypoint.sh`) has
nothing to skip on and would pass. That is the quiet failure the derivation
exists for, and it is the subject of F36, at the end of this file.

`delivery` is now a covered tier in `test-mutations.sh`, `run.sh --help` and
`AGENTS.md`, and the `case_exempt()` entry is gone.

## F6 — `it_wait`'s first parameter is documented as seconds but counts iterations — **FIXED 2026-08-19**

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

**Fixed 2026-08-19 — a real deadline, and no call site changed.** `it_wait` now
computes `deadline=$(( EPOCHSECONDS + t ))` and returns 1 once the clock passes
it. Every caller already wrote its argument meaning seconds, so all 22 call
sites (17 in cases, 5 in `lib.sh`) keep their numbers and simply start being
honest.

Re-deriving the entry before fixing it turned up two things it had not recorded,
both worse than the original framing:

  - **The declared case timeouts were unachievable.** `700`/`710`/`720` set
    `IT_SETTLE=900` and poll a `docker exec`, so two exhausted waits cost
    ~2700-3600s against headers of 2100/2400/2000. `720`'s header reasons
    explicitly about "~1810s … 2000s leaves ~190s of real margin" — that margin
    did not exist, and an exhausted run was killed by the runner instead of
    failing with its own message. Same shape at `080`: three waits whose
    predicate fires a `reach()` (curl, `IT_CONNECT_TIMEOUT`=5s) cost ~756s
    against the 300s default, so its exhausted path could never reach its second
    assertion. The fix makes all four headers correct as written.
  - **`it_wait 0` never evaluated its predicate.** `while i < 0` is entered zero
    times, so the old body reported failure without ever looking. Not reachable
    today (`IT_SETTLE` is floored at 60 and every other caller passes a
    literal), but it is now a guaranteed property rather than an accident.

Five `after ${IT_SETTLE}s` failure messages in `lib.sh` had also been naming a
duration the harness never waited; they are correct now without being touched.

Guarded by four new assertions in `tests/test-integration-lib.sh`. The two that
were already there poll a *free* predicate, and for a free predicate iterations
and seconds coincide — which is why an iteration-counting body sat here looking
correct. The new ones poll a 2s predicate so the two readings of `it_wait 6`
separate, and assert elapsed wall clock, poll count, and the
evaluate-at-least-once property. Demonstrated against the old body on a copied
tree (control run isolating the 8 failures the copy itself causes): 18s not 8s,
6 polls not 3, and 0 evaluations for `it_wait 0`. Full hermetic suite 55/55.

`tests/integration/lib.sh` is **not** in the falsify corpus (`targets.conf`), so
this fix moves no corpus number. Adding it would mostly yield UNPROVEN — the file
is dominated by docker verbs with no hermetic oracle — but the pure verbs
`test-integration-lib.sh` already covers are a real candidate, and this defect
lived in one of them. Recorded as a coverage question, not scheduled.

## F7 — `230-open-drops-capabilities` is named and tagged for open mode but launches discovery — **FIXED 2026-08-19**

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

**Correction 2026-08-19 — the sentence above was false, and it was the load-
bearing one.** There was no `240-open-grants-no-capabilities`. There never had
been: a repo-wide search found exactly one occurrence of that name, the sentence
in this entry asserting it existed. The case list goes `230` → `300`.

So F7 was not a naming defect with the coverage already handled. It was a
coverage hole that this entry had talked itself out of. Only two cases call
`pid1_caps`, and the three modes reach three different `exec capsh` calls:

| entrypoint.sh | mode | asserted by |
|---|---|---|
| `:243` | restricted | `070` |
| `:289` | discovery | `230` — the case tagged `open` |
| `:311` | **open** | **nothing** |

`210` and `220` do launch open mode, but they assert reachability and the
absence of a capture daemon; neither looks at capabilities. So `--tags open`
and `--tags security` both returned a green capability case for a mode nothing
exercised — the exact shape of "believing you are covered", and the reason this
correction is recorded rather than quietly fixed.

**Fixed 2026-08-19, in two parts.**

`230` renamed to `230-discovery-drops-capabilities`, with its `open` tag, its
summary and its header corrected to describe the discovery case it has always
been. Launching discovery stays deliberate: `sandbox_up` grants
`--cap-add=NET_ADMIN --cap-add=NET_RAW` to restricted and discovery
(`lib.sh:202`) and nothing to open (`lib.sh:203`), so it is the mode where the
drop has the most to take away.

`240-open-drops-capabilities` written — the case this entry had claimed. It
launches open mode and asserts the same two capabilities. `cap_net_admin` is
nearly free there (never granted); `cap_net_raw` is the load-bearing one, since
Docker's default bounding set includes it and nothing issues `--cap-drop`, so
only the handover to the sandbox user removes it.

Its known-bad took three attempts, and the two failures are the interesting
part. **Deleting `--drop=` from the open branch is an EQUIVALENT mutation** —
`capsh --user=` setuids from root and the kernel clears the permitted and
effective sets on that transition, which `230`'s own note records, so an
open-mode case still passes with no drop at all. The first patch therefore added
`--keep=1` (`PR_SET_KEEPCAPS`), reasoning that it suppresses the clearing. **It
was demonstrated on the host and came back UNDEMONSTRATED** — the case still
passed. `PR_SET_KEEPCAPS` preserves the *permitted* set across the UID change;
the *effective* set is zeroed regardless, and `pid1_caps` reads `CapEff`.

Measured directly in the integration image rather than reasoned about again —
`CapEff` of the process `capsh` execs:

| capsh options | CapEff |
|---|---|
| root, no setuid | `a80425fb` |
| `--drop=cap_net_admin,cap_net_raw --user=probe` | `00000000` |
| `--keep=1 --user=probe` | `00000000` |
| `--keep=1 --user=probe --inh=cap_net_raw --addamb=cap_net_raw` | **`00002000`** (`cap_net_raw`) |

**The finding underneath, worth more than the patch:** three plausible mutations
are equivalent — deleting `--drop=`, adding `--keep=1`, and granting `--cap-add`
to open mode in `sandbox_up`. None changes `CapEff`. The agent shell's empty
capability set is guaranteed by `capsh --user=`, **not** by the `--drop=` flag
every reader's eye goes to; the flag is belt-and-braces over a guarantee the
setuid already gives. Any future reviewer who "tightens" or "loosens" that flag
should know it moves nothing.

The shipped known-bad uses the ambient set (`--keep=1 … --inh= --addamb=`), the
one measured path that survives a root→non-root setuid and lands in `CapEff`.
PID 1 still becomes the sandbox user, so `sandbox_up`'s handover wait still
succeeds and the break reaches `240`'s own assertion instead of dying in setup —
a demonstration that kills the container before the assertion runs proves nothing
about the assertion. `230` shares `pid1_caps` but not that branch, so it is
untouched and still passes, which is precisely the coverage `240` adds.

Hermetic state: full suite green, all 35 mutation patches apply, and
`test-mutations.sh`'s coverage rule (every `network-mode` case must be named by
a patch) is satisfied for both the renamed `230` and the new `240`.

**Verified against real Docker, in CI, in both repos.** PR CI's integration job
runs `--tags fast --exclude needs-external,needs-dns --require security`, which
selects both cases:

    230-discovery-drops-capabilities   PASS  (3 assertions)
    240-open-drops-capabilities        PASS  (3 assertions)

(upstream run 32297181648, mgd run 32297210600). So the case is real, launches,
and its assertions hold against a live container — not merely authored.

**Demonstrated on the host, 2026-08-19. F7 is closed.**

    ── 240-open-keeps-capabilities   (rebuild) FAIL  ← demonstrated
    DEMONSTRATED 240-open-keeps-capabilities → 240-open-drops-capabilities
       FAIL: agent shell dropped cap_net_raw — still present in [0x0000000000002000=cap_net_raw]

The differential, both cases in one run with that same patch applied:

| case | verdict | agent shell's CapEff |
|---|---|---|
| `230-discovery-drops-capabilities` | **PASS** (3 assertions) | `0x0000000000000000=` |
| `240-open-drops-capabilities` | **FAIL** | `0x0000000000002000=cap_net_raw` |

That table is the entry's whole point in two rows: one patch, `230` unaffected,
`240` red. It is the coverage `230` could never provide, and it is what nothing
in the suite had before.

Three details make it a demonstration rather than a red mark. The break landed on
`240`'s own `assert_no_capability`, not on `sandbox_up`'s handover wait — the
container came up, PID 1 became the sandbox user, and the case reached its
assertions. `cap_net_admin` still **passed** in the mutated run, so exactly one
assertion failed, the load-bearing one. And the first assertion — "read the agent
shell's effective capabilities" — passed in both runs, so neither verdict was
vacuous. Tree clean after `mutate.sh revert`.

## F8 — three surviving mutants in `tests/integration/mutate.sh`'s guard cluster — **CLOSED 2026-08-19, superseded by F20**

Superseded and closed by F20, which recorded five refusal paths (these three plus
`:242` and `:206`) and was fixed on 2026-08-19. `tests/integration/mutate.sh` now
measures **59 killed / 0 survived**. The heading said "open" for a while after the
mutants were dead; corrected here rather than left to mislead the next inventory.

Original finding:


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

## F10 — a single-clause `if [[ X ]];` yields two semantically identical mutants — **FIXED**

Implemented as specified: `tests/falsify/check-ledger.sh:282` carries
`CL_SURV_TEXT`, keyed on `identity|mutated-text` and commented "the F10 dedupe
key", and `tests/falsify/survivors.txt`'s header states the rule — survivors are
deduplicated by (identity, mutated line) before being counted. Dedupe at ledger
build time, not by suppressing generation, exactly as the entry asked.

Original finding:


`cond-negate` produces two distinct mutants that damage the condition the same
way, so any survivor among them is double-counted in the ledger. Harmless to
correctness, wasteful to review, and it inflates the survivor count that R1's
re-scope trigger reads. Dedupe survivors by mutated text when the ledger is built
(Task 7), rather than by suppressing generation — two mutants that happen to
coincide today may diverge if the operator changes.

## F11 — two survivors in `tools-lib.sh`, the tier's first real output — **FIXED 2026-08-19**

**FIXED 2026-08-19.** The second survivor — `tools-lib.sh:42`'s
`[[ -d "$TOOLS_D_DIR" ]] || return 0` — is now killed. `tools-lib.sh` went from
`17|14|1|2` to `17|15|0|2`; its two UNPROVEN records are unchanged and remain
F22's.

The killing assertion is the one this entry named: point `TOOLS_D_DIR` at a path
under the test's own scratch dir that does not exist, and require status 0 with
no names printed. The **status** is the whole assertion — the output is empty
either way — and the 0 is contractual: callers read non-zero as a listing
failure, so `return 1` turns "no tools are configured" into "listing the tools
failed". A guard asserting the fixture really is absent runs first, so the
assertion cannot quietly measure the normal path instead.

Demonstrated against the damage, by hand, in `tests/test-tools-d.sh`:

```
FAIL: tools_list_names returns 0 when TOOLS_D_DIR does not exist — got 1, which
      every caller reads as a listing failure rather than as an empty list
```

Ledger entry 12 is retired. That retirement fired the deliberate canary in
`tests/test-falsify-ledger.sh`, exactly as that file said it would ("this
assertion fires again to make someone re-measure — the canary doing its job, not
noise"); the pin has been re-measured and moved. See F43.

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

## F15 — `bash-floor.sh`'s re-entry guard: 3 survivors on one line — **FIXED 2026-08-19**

**FIXED 2026-08-19.** All the direct-execution survivors are killed.
`bash-floor.sh` went from `11|9|2` to `11|11|0` and `shared-files.sh` from
`5|3|2` to `5|5|0`.

Each file is now RUN directly by its own oracle — once plainly, once with its
`_AI_CONTAINERS_*_SOURCED` variable preset — and sourced twice in a child shell.
**Three observations, because no one of them separates all three damages:**

| line 19 / line 28 | re-source rc | exec rc (sentinel) | ran on past the guard |
|---|---|---|---|
| pristine `… \|\| exit 0` | 0 | 0 | no |
| damage A `… \|\| exit 1` | 0 | **1** | no |
| damage B `… && exit 0` | 0 | 0 | **YES** |
| damage C `return 1 \|\| exit 0` | **1** | 0 | no |

B moves neither status: it short-circuits, falls through the guard and re-runs
the whole file, which on a bash at or above the floor still ends in status 0. So
"ran on past the guard" is read from an **xtrace** — the first statement after
the guard is the sentinel assignment, so its trace line appears if and only if
the guard failed to stop the file. The plain run is kept as the **control** for
that detector and must report that it DID run on; without it a mistyped marker
would make the fall-through assertion pass for the wrong reason, which is the
same vacuity this entry is about.

All six damages (three per file) were demonstrated by hand, each failing on a
named assertion with the test running through to its failure count — for example:

```
FAIL: executing bash-floor.sh with the sentinel already set stops AT the guard —
      the xtrace shows '_AI_CONTAINERS_BASH_FLOOR_SOURCED=1' running, so
      execution fell through and re-ran the whole file
```

**One thing this entry did not know, found while fixing it, and it cost a
rewrite:** `tests/test-shared-files-parity.sh` sources the PRODUCT script
`sync-to-projects.sh`, which sets `-euo pipefail`, so every line of that test
after it runs under errexit. Two of `shared-files.sh`'s mutants were being
"killed" by a silent abort rather than by an assertion. That is F43.

Ledger entries 1 and 2 are retired. Entry 2's second request — assert the
re-source status in `test-bash-floor.sh` itself "rather than by accident three
files away" — is included rather than deferred.

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

## F16 — **RESOLVED 2026-08-18.** The oracle field is a SET, and the eight real kills it was hiding are kills again

`tests/falsify/targets.conf`'s oracle field now takes several comma-separated
test basenames, run as ONE `run-all.sh -v a.sh b.sh` invocation: run-all.sh
OR-combines its filters and reports one aggregate status, so a `FAIL:` from any
member is that target's kill and the baseline requires every member green.
`derive-targets.sh` checks each member on its own — exists, selected uniquely,
not repeated — and checks the field's SHAPE before splitting it, because
`IFS=, read -a` silently drops a trailing empty member and `a.sh,` would
otherwise pass as `a.sh` with the author's second oracle gone without a word.

Two rows changed, and the ledger with them:

| Row | Oracle set now | Effect |
|---|---|---|
| `tests/lib-verify-repo.sh` | `+ test-verify-exit-code.sh, test-layer-containment.sh` | 11 survivors → 3; ledger entry 3 retired outright |
| `bash-floor.sh` | `+ test-migrate-runme.sh` | the `return 1` half of entry 2's identity is now killed |

Measured at `--jobs 1` as well as `--jobs 6`, and the two agree.

### The third row in the original table was wrong, and its correction is the
### more useful half of this entry

The table below claimed `tests/portability.sh:36` (`p_stat_meta`) was killed by
`test-allowlists.sh` and `test-falsify-generate.sh`. **It is not**, and the row
stays 1:1 deliberately. Ledger entry 13 had already re-measured it and moved it
out of this group; what was still missing was WHY it ever looked killed, and
that turns out to be a reproducible instance of F30 rather than a slip:

* The damage makes `p_stat_meta` run `stat -f '%N %z %m' F`. On GNU, `-f` means
  `--file-system` — so the format string is taken as a filename, and the call
  prints the FILESYSTEM's block counts plus an error, not the file's metadata.
* `test-falsify-generate.sh` compares two `p_stat_meta` samples taken either
  side of a generator run, to assert the generator left the targets untouched.
* Sequentially the free-block count does not move between the samples, the two
  garbage strings match, and the mutant survives — correctly, because nothing
  is watching that branch.
* Under concurrent workers the free-block count DOES move, the strings differ,
  and the assertion fails **on disk jitter**. The tier records a kill.

Reproduced deterministically: six concurrent copies of the damaged tree, six
identical `FAIL: generating mutants leaves the target files byte-identical`.
Run alone, the same tree passes all three tests. At `--jobs 6` the tier reported
3 of 10 portability mutants KILLED; at `--jobs 1`, 0 of them.

**So the rule that came out of this is written into `targets.conf`'s header: an
extra oracle is not free and not automatically right — name one only when it is
measured to kill something the others do not, and measure that at `--jobs 1`.**
Adding `test-falsify-generate.sh` here would have retired a real, documented gap
(entry 13, backlog F25) on the strength of machine load.

### Original finding


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

## F17 — `tests/lib-verify-repo.sh`'s git bootstrap and probe are never run under a failing git — **FIXED 2026-08-19**

Fixed exactly as this entry specified, and the entry's analysis held on
re-derivation — all three flips still survived, and the killing assertion it
named is the one that works. Two fakes on `PATH`, each **delegating to the real
git** for everything it does not deliberately break (a fake that answered
everything itself would be testing the fake): one rejects `git init -b` the way
git < 2.28 does, one adds fine and refuses to `commit`. Each fake is checked in
both directions before any case relies on it.

Applying the three exact mutants, each new case fails and names the right thing:

| mutant | what goes red |
|---|---|
| `:181` `\|\|` → `&&` | the probe now aborts under a `-b`-rejecting git (rc=1) |
| `:322` `\|\|` → `&&` | `mk_repo` yields no commit and no tracked `*.sh` |
| `:183` `&&` → `\|\|` | sourcing does NOT abort under a commit-refusing git, and the harness body runs on |

`tests/lib-verify-repo.sh` went from **46 killed / 3 survived to 49 / 0**, and
the corpus from `220|27` to `223|24`. Ledger entry 4 is retired — and unlike
entry 3, which F16 retired by fixing the target map, this one was retired by
writing the assertion.

Original finding:


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

## F18 — `lib-layer-checks.sh`'s missing-file and unset-registry paths return the wrong status — **FIXED 2026-08-19**

Fixed as this entry specified, and the entry's analysis held on re-derivation:
all four flips still survived, the count was right, and the killing assertion it
named is the one that works. The entry's LINE NUMBERS had drifted (`:116` is now
`:144`, the killed wf_triggers_on twin `:165` is now `:193`) — which is the case
for identity-by-sha1 rather than by `file:line`, made once more.

One thing the entry did not say, and the fix turns on it: **status alone does
not kill the deletion of these guards.** Remove the `[[ -f "$f" ]]` line
outright and every function still exits non-zero on a missing file — `awk:
cannot open ...` from wf_jobs/wf_steps/wf_job_key, `grep: ... No such file` from
lc_rows, and an `unbound variable` abort from the unset case under `set -u`. So
each new assertion reads BOTH halves of a loud failure, through a `fails_naming`
helper: non-zero status **and** the message that names the cause. Measured in
both directions before the ledger entry was retired.

| damage | what goes red |
|---|---|
| `lc_rows` `:33` `return 1` → `return 0` | both lc_rows registry cases: "reported success, rc 0" |
| `wf_jobs` `:87` same | "wf_jobs fails loudly for a workflow file that does not exist (reported success, rc 0)" |
| `wf_steps` `:96` same | the wf_steps twin |
| `wf_job_key` `:144` same | the wf_job_key twin |
| any of the four guards **deleted** | the same case, at the other half: "failed, but stderr never named the cause" |

Each mutant makes exactly its own case fail and no other — no collateral, which
is what says the assertion is aimed rather than incidental.

`tests/lib-layer-checks.sh` went from **42 killed / 6 survived to 46 / 2**, and
the corpus from `223|24` to `227|20`. The two that remain are ledger entry 6's
EQUIVALENT pair, which no test could kill. Ledger entry 5 is retired.

The library header is corrected at the same time, because it is where the gap
came from: it promised loud failure "on an empty result" only, the test followed
the promise, and the missing-file guards sat outside it. It now names both
classes.

Original finding:


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

## F19 — `mutate.sh`'s sibling-layout resolution is unexercised, and survives by accident — **FIXED 2026-08-19**

Fixed as this entry specified: two fixture trees, both driven from a CWD
**outside** them. One is mgd-shaped — `build.sh` under `base/`, a git root above
it — plus a **decoy** `target.txt` at that root with the same content as
`base/target.txt`. The decoy is what turns a status into an observation: without
it a lost `APPLY_PREFIX` only makes `apply` fail, with it the patch has somewhere
wrong to land and the assertion reads *which file changed*. The second tree is
not a git repository at all, which is where `:52`'s fallback is load-bearing —
`mutate.sh`'s own header promises `check` still works there, and it only does if
`GIT_ROOT` falls back to the engine directory.

**One prediction in this entry was wrong, and the fixture corrected it.** `:52`'s
damage was expected to leave the patch landing in `base/` regardless, making the
mgd fixture blind to it. It does not: `git apply` resolves its paths against the
**repository root**, not the current directory, so cd-ing into `base/` with an
empty prefix patches the file at the git root — the decoy. Both fixtures kill
`:52`.

| damage | what goes red |
|---|---|
| `:41` `-f` → `! -f` | the patch lands at the git root, not `base/`; and `check` dies in the no-git tree |
| `:41` `\|\|` → `&&` | identical |
| `:52` `\|\|` → `&&` | the patch lands at the git root; `check` in the no-git tree exits 1 with empty output — `GIT_ROOT` was the empty string and `cd ""` never moved |

The bash-version fact this entry established is kept in the ledger tombstone,
because it is about the repo rather than these three mutants: `cd ""` is a silent
no-op on bash 5.1.16 and 5.2.21 and an **error** on 5.3.15, so a primitive's
semantics changed above the declared floor. The new assertions do not depend on
it in either direction — the undamaged script never runs `cd ""`.

Original finding:


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

## F20 — five `mutate.sh` refusal paths report success (supersedes F8) — **FIXED 2026-08-19**

Fixed as this entry specified, with one thing the entry did not say. **`:74` and
`:143` are two damages to the same refusal, and the message cannot tell them
apart** — `require_git_usable` prints its diagnosis *before* returning, so "git
is unusable" appears whichever one is damaged. What separates them is the tree:
`:143` exits 0 having applied nothing, while `:74` lets the apply proceed and the
mutation **lands**, on a tree whose cleanliness was never established. So the
git-unusable case reads the status, the message and the tree, and it is the tree
assertion that catches `:74`.

| damage | what goes red |
|---|---|
| `:141` `exit 1` → `exit 0` | `apply refuses while a mutation is still applied (rc=0)` |
| `:143` `\|\| exit 1` → `\|\| exit 0` | `apply refuses when git is unusable (rc=0)` |
| `:74` `return 1` → `return 0` | the same case, plus `applied nothing (state: p-good, dirty: yes)` |
| `:206` `return 0` → `return 1` | `revert with nothing applied succeeds (rc=1)` |
| `:242` `exit 1` → `exit 0` | `revert fails when a recorded patch reverses in neither direction (rc=0)` |

The fake `git` is scoped to `--git-dir` alone and delegates everything else to
the real one, so the script's own `rev-parse --show-toplevel` still resolves; it
is checked in both directions before anything relies on it.

Original finding:


`:141` and `:242` (`exit 1` -> `exit 0`, one shared ledger identity), `:143`
(`require_git_usable || exit 1` -> `exit 0`), `:74` (`return 1` -> `return 0`),
`:206` (`revert` with nothing applied, `return 0` -> `return 1`). None killed
(measured). Every one is a STATUS, and `mutate.sh` is driven by CI
demonstrations and by a human's shell, both of which branch on `$?`.

**Killing assertions:** apply twice without reverting, requiring a non-zero exit
that names the applied mutation; a faked `git` that cannot resolve `--git-dir`,
requiring `apply` to refuse non-zero; and `revert` with no state file, requiring
exit 0.

## F21 — `mutate.sh revert` reverses twice on any host with `tac` — **FIXED 2026-08-19**

Fixed as this entry specified: two patches, the second **generated against the
tree the first leaves behind**, so its context carries the first patch's change
and reversing them in the order they were applied cannot work. That is what makes
the reverse-order invariant testable rather than decorative. The assertions are
exactly one `Reverted <id>` line per id, newest first, and no `Already absent`
line.

**This entry's prediction — "revert still exits 0" — is confirmed for ONE applied
patch and is not what happens with two dependent ones.** Worth writing down,
because the difference is instructive rather than a correction. Measured with the
`&&` damage in place:

| applied | what `revert` does under the damage |
|---|---|
| one patch | `Reverted p-good`, then `Already absent: p-good`, **exit 0** |
| two patches | both `Reverted`, then the second pass finds `p-second` reversible in **neither** direction (`p-good` is already undone, so its context no longer matches), **exit 1** |

Either way both invariants that block's own comment insists on are violated. The
fixture uses the two-patch form because it pins the order as well as the
double-read.

This also retires a kill that was never an assertion: the mutant read KILLED on
macOS only because macOS ships no `tac`, so `tac && sed` short-circuited and the
loop read nothing. It is now killed on every host.

Original finding:


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

## F23 — `p_sha1`'s platform probe can be inverted with every test green — **FIXED 2026-08-19**

**FIXED 2026-08-19.** Killed by the assertion this entry named.
`tests/portability.sh` went from `10|6|4` to `10|10|0` (with F25).

`p_sha1` is now run with a `PATH` holding exactly ONE of the two digest tools —
symlinks built in the test's own scratch dir — and required to produce a literal
expected digest. Whichever half runs, the inverted probe reaches for the tool
that is **absent** and yields an empty digest, so the assertion kills the mutant
on a GNU host and on a BSD one without either having to be the reference:

| PATH holds | pristine picks | mutated picks |
|---|---|---|
| `sha1sum` only | `sha1sum` (correct) | `shasum` (absent → empty) |
| `shasum` only | `shasum` (correct) | `sha1sum` (absent → empty) |

Both halves run on this machine and both fail against the damage; a host with
one tool runs one of them, and a host with neither fails a guard that says so
rather than asserting zero times. `shasum` is a perl script with an absolute
shebang, so restricting `PATH` does not break it (verified).

The expected digest is a **literal**, not a second call to `p_sha1`: checking a
helper against itself is `assert f(x) == f(x)`, which is how this branch went
unasserted in the first place. A guard checks the fixture still holds the bytes
that digest was computed for.

Demonstrated against the damage:

```
FAIL: p_sha1 digests correctly when sha1sum is the only digest tool on PATH —
      want '7fe70820e08a1aac0ef224d9c66ab66831cc4ab1', got ''
FAIL: p_sha1 digests correctly when shasum is the only digest tool on PATH —
      want '7fe70820e08a1aac0ef224d9c66ab66831cc4ab1', got ''
```

Ledger entry 11 is retired.

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

## F25 — `p_stat_meta`'s GNU/BSD branch swap survives the entire suite — **FIXED 2026-08-19**

**FIXED 2026-08-19.** Both mutants killed, by the fix this entry specified:
assert `p_stat_meta`'s VALUE the way its `p_stat_mode` sibling one line up always
did — exactly three whitespace-separated fields, the middle one the file's real
byte size, the last one numeric.

The helper is called from inside the scratch dir with a bare filename, so
"exactly three fields" is a property of the helper rather than of whether
`TMPDIR` happens to contain a space.

**The old `[[ -n "$meta" ]]` check is kept, and it still PASSES against both
damages** — measured while fixing this, and it is the whole point of the entry.
On GNU, `stat -f` is not an invalid option that falls through: it means
`--file-system`, so the swapped branch prints a multi-line filesystem report plus
an error, and that garbage is non-empty. A non-emptiness assertion could never
have caught it. Measured:

```
pristine: f 8 1787174058
mutated:  stat: cannot read file system information for '%N %z %m': ...
            File: "f"
              ID: 622806a99446626e Namelen: 255     Type: overlayfs
          (and four more lines)
```

Demonstrated against both damages (`cmp-flip` and `cond-negate` of the same
selector), each failing on the new assertions while the non-emptiness one passes:

```
FAIL: p_stat_meta returns exactly three fields — got 27 in '  File: "f"
FAIL: p_stat_meta's second field is the file's byte size — want '8', got '"f"'
FAIL: p_stat_meta's third field is a numeric mtime — got 'ID:'
```

Ledger entry 13 is retired. Its live instruction is carried into the retirement
note: **do not** add `test-falsify-generate.sh` to this target's oracle set — it
reports these mutants KILLED at `--jobs 6` and none at `--jobs 1`, which is disk
jitter, not coverage (F30's addendum).

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

---

### CORRECTION, 2026-08-17 (same day): the diagnosis above is wrong

The `/etc/ai-containers/tools.d` explanation does not survive contact with the
oracle. **`test-tools-d.sh` never leaves `TOOLS_D_DIR` unset or pointing at a
missing path** — it exports it to a directory it creates under its own
`mktemp -d`, and the one place it repoints it (`"$REPO_DIR/tools.d"`, to read
the real descriptors) names a directory that is checked in. So
`tools-lib.sh:37`'s default is never consulted, the guard is unreachable in
*every* environment, and the mutant survives everywhere.

**What actually caused the divergence:** the shared-`/tmp` race in
`test-tools-d.sh`'s "failed download leaves no temp file" assertion, which
globbed `"${TMPDIR:-/tmp}"/ext-cli.*` — a name every copy of that test uses.
`tests/falsify/run.sh` drives up to `nproc` copies of that oracle at once
(it is `tools-lib.sh`'s declared oracle), so before the fix they could fail each
other and a mutant could be scored KILLED on a sibling worker's temp file. A
4-core runner and a 12-core container do not have the same timing, which is why
it showed up as a place-to-place difference. Fixed 2026-08-17; with the fix in,
CI reproduces the container's totals exactly (`209/36/4` both), and the entry is
back to **`GAP`**, which is what F11 said all along.

**The lesson, which is bigger than this line.** Two machines disagreeing is a
fact. *Which* difference between them is operative is a **hypothesis**, and the
most visible difference was not it. This project's rule is root cause before
mitigation; re-measuring satisfied the letter of it while the causal claim went
unchecked. The check that would have caught it costs one grep: the proposed
mechanism said a default was consulted, and the oracle never lets it be.

**A second lesson about the tier itself:** its parallelism is part of its
measurement apparatus, so any oracle that is not isolated from a concurrent copy
of itself can make the tier report coverage that does not exist. That is a
sharper reason to keep tests hermetic than tidiness, and it is worth scanning
for the pattern (shared paths, fixed ports, global state) in any test named as
an oracle in `targets.conf`. Scanned on 2026-08-17: `test-tools-d.sh` was the
only test in the suite globbing a shared directory.

---

## F30 — a KILL is only trustworthy if the oracle would have passed under the same load

`tests/falsify/run.sh` scores a mutant KILLED when the oracle exits non-zero or
prints a `FAIL:` line, and a `timeout` that *also* carried a `FAIL:` line is
still a kill (`falsify_verdict`, and the long comment above it explaining why a
bare timeout must NOT be). That is right as far as it goes, and it fixed F12.
It rests on one unstated assumption:

> the `FAIL:` line was caused by the mutation.

Under contention that assumption can be false. An oracle can fail because the
machine is loaded — and the tier itself is what loads it, running up to `nproc`
oracles at once.

**How it surfaced.** A macOS Phase 6 host run (2026-08-17, `jobs=18` on a
machine also hosting Colima) scored `tools-lib.sh:return-flip:f128fd8d` KILLED
and reported it as *obsolete amnesty* — i.e. "your ledger excuses a mutant that
is now covered". Re-run on the same host and the same tree at
`--jobs 2 --timeout 300`, the same mutant SURVIVED with signal `none` in ~10 s,
**in both repos independently**. Nothing about the code changed between those two
readings; only the concurrency did. That run reported **80 timeouts and 13
unproven** against the reference environment's 11 and 4.

**Why this is the tier's own failure mode, not a nuisance.** The whole point of
the tier is that a survivor is evidence of a missing assertion. A false KILL
deletes that evidence: the mutant never appears in the run's survivor set, so
`check-ledger.sh` never demands an entry, and the gap it represents becomes
invisible. It is the exact inversion F12 closed, arriving through a different
door — F12 was "a slow oracle is reported as a kill", this is "a *failing-because-
slow* oracle is reported as a kill", and only the first is currently caught.

**Why the existing baseline does not cover it.** `run.sh` does run each target's
oracle on the pristine tree and requires PASS before mutating — but once, at the
start, with no workers running. It establishes that the oracle is green on a
quiet machine, which is not the condition the mutants are measured under.

**MEASURED, 2026-08-17, before proposing anything.** The mechanism was
reproduced end to end on Linux rather than inferred from the macOS report:

| tree | `--jobs 24 --timeout 120` on 12 cores | verdict for `f128fd8d` |
|---|---|---|
| pre-fix (`74b8b20`) | run 1 | **KILLED**, signal `exit+failline`, 2.5 s |
| pre-fix (`74b8b20`) | runs 2-3 | SURVIVED, `none` |
| post-fix (`6586acb`) | runs 1-2 | SURVIVED, `none` |

So it is intermittent, it is the shared-`/tmp` race, and it is gone on the fixed
tree. The deterministic half of the demonstration is in that fix's own commit:
`touch /tmp/ext-cli.ZZZZZZ` and nothing else turns the suite red.

**THE MEASUREMENT CORRECTED THE FIX LIST, WHICH IS WHY IT CAME FIRST.** The
signal was `exit+failline` at **2.5 seconds** — no timeout at all. The obvious
remedy ("re-verify any kill that also timed out") would have missed this case
completely: a contaminated oracle can fail *fast*. Slowness is a symptom of the
load, not the vector.

**Candidate fixes, in the order they should be considered:**

1. **Control runs (detection, cheap, catches the fast case).** Interleave a
   handful of PRISTINE oracle runs among the mutants, in real worker slots,
   under the same load. A control that FAILs proves the run's kills are
   contaminated; say so loudly with a `NOTE|` line and a non-zero exit rather
   than reporting a clean corpus. This is the only proposal here that would have
   caught the measured case, because it asks the right question — *is this
   oracle green under these conditions?* — instead of guessing at a proxy for it.
2. **Re-verify suspicious kills (correction, bounded).** Re-run alone, and
   record the second verdict. Scoping it to `timeout`-signalled mutants is
   tempting and, per the table above, **wrong**; the honest scope is "every kill
   in a run whose control failed", which makes it a follow-on to fix 1 rather
   than an alternative to it.
3. **A jobs knob for Phase 6 (mitigation, trivial).** Phase 6 derives its job
   count from `nproc`/`hw.ncpu` with no override, which is how a developer's Mac
   ended up at 18 while also hosting Colima. Worth having regardless, but it is
   a mitigation: it lowers the chance of the condition without making it
   detectable, so it must not land alone.

**Still open on the macOS reading specifically.** The host run that surfaced this
was made from a tree whose exact commit is not recorded, so whether it already
carried the `/tmp` fix is unknown. If it did, there is a second contamination
path here that has not been identified. Re-running Phase 6 on current `main` and
checking whether `tools-lib.sh:return-flip:f128fd8d` still appears in the
"obsolete here" list settles it in one run.

**Do not read a kill from a run with a high unresolved fraction as evidence that
a gap has closed.** `verify-on-host.sh` Phase 6 already prints the measured
fraction (94% in that run) — that number is the signal, and until fix 1 exists it
is the only one.


---

### ADDENDUM 2026-08-18 — the mechanism, reproducible on demand

F30's original instance could not be reproduced deliberately: it was a mutant
that scored KILLED once under `jobs=18` and SURVIVED on re-run, with the cause
inferred. There is now a case that reproduces **every time**, which makes the
finding demonstrable rather than argued.

`tests/portability.sh`'s `p_stat_meta` branch swap makes the function print
FILESYSTEM block counts instead of file metadata (`stat -f` on GNU means
`--file-system`). `tests/test-falsify-generate.sh` fingerprints its target files
with `p_stat_meta` before and after a generator run and requires the two samples
to match. Sequentially the free-block count is stable between the samples and
the mutant survives. With other workers writing, it is not, and the assertion
fails — on **disk jitter**, with nothing having observed the damaged branch.

Six concurrent copies of the damaged tree: six identical failures. The same
tree run alone: green. At `--jobs 6` the tier scored 3 of `tests/portability.sh`'s
10 mutants KILLED; at `--jobs 1`, none of them.

Two things follow. First, the false kill is not confined to scaffolding
collapse, so the F31 marker channel cannot catch it — the oracle set itself up
fine and asserted something true about a world that moved underneath it. Second,
it is a *specific* shape worth looking for elsewhere: **an assertion that
compares two samples of an environment-derived value**. Under mutation, a
damaged accessor can turn such an assertion into a load detector. That is what
made `tests/portability.sh` stay a 1:1 row (see F16).

## F31 — every test's `mktemp -d` is unchecked, and a failed one is scored as a KILL

**This is the cause of F30's macOS false kills.** Root-caused 2026-08-18, after
three wrong hypotheses (the `/etc/ai-containers/tools.d` default, the
shared-`/tmp` glob, and a timeout-based reading — all measured and discarded).

`tests/test-tools-d.sh:9` is the whole of it:

```bash
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
```

No status check, and the suite runs under `set -uo pipefail` — no `-e`. If
`mktemp -d` fails, `$TMP` is the EMPTY STRING and the test carries on: it writes
its descriptors to `/tools.d`, its fake `curl` to `/fakebin`, its install dir to
`/bin`. None of that works, so every descriptor read returns defaults, URLs get
built with an empty repo (`https://api.github.com/repos//releases/latest`), and
`install-tools.sh:36` retries three times with `sleep 5` — which is why the
oracle took **44-57 s** on the host against 0.3 s standalone.

**And `$TOOLS_D_DIR` then does not exist, which makes the mutated guard
REACHABLE.** `tools-lib.sh:42`'s `[[ -d "$TOOLS_D_DIR" ]] || return 0` is
unreachable in a healthy run — that is exactly why the mutant is a GAP — but a
collapsed scaffold reaches it, the mutated `return 1` propagates, assertions
differ, and the tier records **KILLED**. The false kill is not noise landing on
an unrelated assertion; it is the mutation being genuinely detected in a state
no real run is ever in.

**The evidence is a signature match, not an argument.** Stubbing `mktemp -d` to
fail on Linux reproduces the host's failure list line for line — `list names ()`,
`repo ()`, `private`, `config_dir`, `crossclient ()`, `binary default ()`,
`'#' inside a value ()`, `trailing comment ()`, `a key before the blank line is
read (repo=)`, `a key after a blank line is read — got the '' fallback`, `a
non-default value after a blank line survives (private=no)`, `a final line with
no trailing newline is read (skills=no)` — every one of which appears verbatim
in the macOS worker logs.

It also explains what nothing else did: macOS-only (`ulimit -n` 256 there
against 1048576 on the container), intermittent (1 in 3), absent at `--jobs 2`,
and reproducible **without the falsify runner at all** — 18 concurrent copies of
`tests/run-all.sh test-tools-d.sh` on the host reproduce it; the same 18 on
Linux do not.

**Scale: 87 call sites across 45 files, and NOT ONE checks the status.** Only 9
of those files source `tests/portability.sh`, so there is no existing shared
home for the guard.

### Why the obvious guard is not sufficient on its own

```bash
TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
```

turns sixty misleading assertion failures into one true line — worth having —
but it does **not** fix the false kill, because `run.sh` scores KILLED on any
`FAIL:` line or any non-zero exit. A test that correctly reports its own
scaffolding is broken would still be read as "the assertion noticed the
mutation". The tier cannot currently tell *the oracle failed* from *the oracle
failed BECAUSE OF THE MUTATION*, and that distinction is the whole tier.

### The fix, in two halves

1. **A scaffolding-failure channel the tier understands.** A test whose own
   setup fails emits a distinct marker (not `FAIL:`) and a reserved exit status;
   `run.sh` maps that to a verdict that is *never* KILLED, reported like
   UNPROVEN and owed a ledger entry the same way. Then a collapsed oracle
   subtracts from what was measured instead of adding a phantom kill.
2. **The guard itself, at all 87 sites**, emitting that marker.

Note that `run.sh` ALREADY has the right check in the right shape for the other
half of F30 — it verifies each oracle on the pristine tree and refuses to
measure a target whose baseline is not green (this is what aborted the host's
Phase 6, correctly). It simply runs once, at the start of a target, so
contamination arriving later is invisible. Re-checking that baseline during or
after a target's mutants is a much smaller change than the control-run design
F30 proposed, and subsumes it.

### STATUS: fixed 2026-08-18, in two halves, with one part deferred

**Both mechanisms are in.** A test whose own setup fails prints
`SCAFFOLD-FAILED: <what>` and exits non-zero; `tests/run-all.sh` reports that as
*"could not set itself up — the environment, not the code"* and surfaces the
marker instead of the assertion greps a collapsed test fills with noise; and
`falsify_verdict` maps the marker to **UNPROVEN**, with `scaffold` in the signal,
ahead of every other signal.

UNPROVEN rather than a fourth verdict, deliberately: "nothing was observed
asserting" is exactly what a collapsed oracle is, and reusing it leaves the
ledger grammar and `check-ledger.sh` untouched — an UNPROVEN identity is already
reported and already not required to be classified.

The scaffold check runs BEFORE the SURVIVED branch, not merely before the kill
branch: a collapsed oracle that happened to exit 0 quietly would otherwise be
recorded as a survivor, which is the worse of the two errors. A survivor is a
claim that the suite ran and noticed nothing; that oracle never ran.

Demonstrated failing in both halves, against a fixture that reproduces the field
signature — marker line, real `FAIL:` line and non-zero exit together. Without
the verdict branch the mutant is `KILLED signal=exit+failline`; with it,
`UNPROVEN signal=exit+failline+scaffold`. Without the driver branch the operator
gets `FAIL (exit 1)` and never sees the marker.

**100 guard sites across 43 `tests/test-*.sh` files.** The corpus is unchanged by
them (`TOTAL|9|249|209|36|4|11|16`, ledger clean under `--strict`), which is the
check that they touched no target.

**DEFERRED, and this is the remaining debt:** two `mktemp -d` sites live in
falsify TARGETS — `tests/integration/mutate.sh` and `tests/lib-verify-repo.sh`.
Guarding them is equally correct and equally needed (a library whose temp dir
fails corrupts its oracle in exactly the same way), but the guard's `||` and
`exit 1` generate new mutants, which changes the corpus and forces the ledger to
be re-derived and the new survivors classified. A self-contained follow-up, not
a reason to leave it undone.

### One thing still unproven

That `mktemp -d` is what fails on the host, rather than `$TMP` being emptied by
something else afterwards, is inferred from the signature — both produce an
identical picture. The guard is the instrument that settles it: with it in
place, a host re-run either aborts naming `mktemp` (confirmed) or reproduces the
old picture (something else empties `$TMP`, and the search continues). It is
correct to add either way, which is why it is not blocked on the answer.

---

## F31 ADDENDUM — ENOSPC is a proven mechanism and an unproven trigger

Measured on the affected host, 2026-08-18. **`mktemp -d` was never the cause**;
the guard built to confirm it eliminated it instead, which is the guard working.

**The real class is "the artefact exists but is wrong".** Injected into an
UNMUTATED tree, each of these scored `KILLED | exit+failline` — the tier scoring
an environmental failure as a kill with no mutation present at all:

| injected damage | observed | matches the field report |
|---|---|---|
| `foo.conf` written but empty | 6 × `FAIL:`, KILLED | `FAIL: repo ()` |
| `ext.conf` written but empty | `repos//releases/latest`, 7.9 s → 16.3 s | the exact URL, and the slowdown |
| `amb.tar.gz` non-empty but truncated | exactly one `FAIL:`, ambiguous archive | "one copy failed ONLY at ambiguous archive" |
| fake `curl` present, not executable | PATH resolves to `/usr/bin/curl` | drives the code under test at the real network |

Every one passes `-e` and `-r`, which is why the first guard never fired.

**The filesystem decides the shape, and only one of them matches the field:**

| | ENOSPC failure shape |
|---|---|
| HFS+ | fails at `open()` → artefacts absent |
| **APFS** (what `/var/folders` is) | `cat > f` leaves the file **created and empty** — 17 of 30 measured |

**`df` cannot be used as the probe.** APFS still reported ~1.8 MB free while
writes were already coming back empty. A `df`-based check would have read
healthy throughout and become the next wrong hypothesis. The probe has to
attempt a real write and read it back for content.

**It also has to sample at the moment of failure.** An end-of-run probe passes
because `rm -rf "$RTMP"` frees the exhausted space two lines earlier — measured,
and the run is scored KILLED anyway (6 of 16).

### Closing the path the guards could not see

Out of disk, `sandbox.sh` never reaches `docker run`, `$CAP` is empty, and the
launcher assertions fail with every scaffolding artefact intact. Guarding `$CAP`
is not the answer: it *is* the artefact under assertion. The write probe in
`fail()` is. Measured across 40 onsets, no mutation anywhere:

| tree | KILLED |
|---|---|
| `-e`/`-r` guards | 6 of 18 |
| + per-step content guards | 3 of 40 — all the launcher path |
| + at-failure write probe | **0 of 40** (those three → UNPROVEN) |

### What is still open, stated as open

**ENOSPC is a sufficient mechanism, not the demonstrated trigger on that host.**
Free space there never moves: 199 samples over three 18-way rounds, 665.3–665.6 GB,
a 321 MB swing. ~350 concurrent runs and 11 falsify runs produced zero natural
collapses; the ledgered survivor stayed SURVIVED 11 of 11.

So this entry deliberately does **not** say "the trigger is ENOSPC". What closes
it is one datum from a failing run: the write probe's result at the moment it
trips, which `capture-on-host.sh` now records along with `df`, `tmutil
listlocalsnapshots /` and the APFS snapshot context. Per the measurement above
the write probe is the load-bearing half — `df` reads healthy while writes fail.

The clock is no longer evidence, either: the 03:19–04:09 clustering is when the
tier was *run*, not when the machine is vulnerable. The APFS-local-snapshot
hypothesis (pinned space that `df` still reports free) stands on its own and is
untested — current baseline is zero local snapshots.

Also newly ruled out by measurement: the EXIT trap firing in a `( )`/`$( )`/
failing subshell (it does not, bash 5.3); `mktemp -d` collision (BSD mktemp, 10
random chars); inode exhaustion.

**Correction to an earlier figure in this file:** "0.3 s standalone" was measured
in a Linux container, not on the affected host, where the same test takes 7.9 s.
The 44–57 s under load is a ~6× slowdown, not 150×.

---

## F32 — three load-sensitive oracles, and the tier reads slowness as coverage

Distinct from F31 and unfixed. Three separate oracles have now been observed
failing or timing out purely under concurrent load, on trees that are green when
run alone:

1. `tests/test-falsify-run.sh` — fails roughly 1 full-suite run in 4 under load.
   The inner fixture run produces no verdict at all (`FR_BROKEN`), so its
   FAIL:-line-detection case reads `expected 'SURVIVED', got 'MISSING'`. A test
   *about* verdict detection silently stops testing it.
2. `tests/test-integration-shim.sh` — blew the 120 s budget on the PRISTINE tree
   under 18-way load (4.7 s standalone, and it passed twice in Phase 5 of the
   same run). `run.sh` handled it correctly, refusing to measure that target
   rather than reporting every mutant killed.
3. `tests/test-tools-d.sh` — F31, now guarded.
4. `tests/test-layer-containment.sh` — **cause found and fixed, see F34.** It was
   not slowness at all: a `producer | grep -q` pipeline under `pipefail`, whose
   status flips to the producer's SIGPIPE whenever grep's early exit wins the
   race. Worth stating plainly because it changes what this entry is: at least
   one of these "load-sensitive oracles" had a specific, fixable defect rather
   than a need for more time. Look for a mechanism before adding a timeout.

**2026-08-19: a second one of these had a mechanism too — see F35.** Chasing
case 1 rather than adding time found that the tier's own concurrency is a
MEMORY problem before it is a timing one: this container's cgroup reports
`oom_kill 7` against an 8 GiB `memory.max`, and `--jobs $(nproc)` workers each
run a whole `run-all.sh`. The kernel picks one and SIGKILLs it. When it picks
the WORKER, the result file is empty and run.sh reports FR_BROKEN — which is
exactly case 1's symptom, honestly reported. When it picks the ORACLE, the
verdict was `KILLED`, which was not honest at all. F35 fixes the second and
explains the first. That is now two of the four items in this entry whose cause
was a specific defect rather than a need for more time; read the remaining one
the same way before reaching for `--timeout`.

The pattern is the tier's own concurrency turning healthy oracles unhealthy, and
the two remaining cases are not scaffolding failures, so the F31 channel does
not catch them. `run.sh`'s per-target pristine baseline catches the case where
the oracle is *already* red when the target starts; it cannot catch an oracle
that goes red partway through a target's mutants.

Options, unranked and unbuilt: re-check the baseline mid-target rather than only
at its start; or scale `--timeout` from a measured per-oracle baseline instead
of one global number; or cap concurrency below `nproc` on hosts where the tier
competes with a VM for cores (Phase 6 chose 18 on an 18-core Mac also running
Colima).

## F33 — the gate cannot yet require that a row's oracle actually executes its target — **RESOLVED 2026-08-19**

**Both halves landed together, as this entry said they had to.** The derivation
learned the two run-time shapes and `derive-targets.sh --check` gained the
`oracle ∈ executors` gate, in one commit — the gate alone rejects correct rows
and the derivation alone buys only a more honest `--evidence`.

**The entry was right about the mechanism and wrong about the count.** It named
one blind shape (`printf 'source %q\n' … >> "$h"`). Running the gate against the
old derivation found **two** rows failing, not one:

| row | oracle it names | why the derivation could not see it |
|---|---|---|
| `tests/lib-verify-repo.sh` | `test-lib-verify-repo.sh` | the path is printf'd into a harness that is then run |
| `sandbox.sh` | `test-parsers.sh` | the path is the ARGUMENT of `bash -c 'src="$1"; … source "$src"' _ "$REPO_DIR/sandbox.sh"` |

The second shape also hides `tests/test-tools-d.sh:806`, which reaches
`sandbox.sh` through `bash -c 'cd "$1" && shift && exec bash "$@"' _ …`. Both
were invisible for the same underlying reason and neither is exotic: they are
how a test drives a file it must not source into its own shell.

**The rules are deliberately coarse, and that is the finding.** Binding the
positional parameters properly — the obvious fix — was worked through and
**misses both real shapes**: one body copies `"$1"` into a local before
sourcing it, the other `shift`s before `exec bash "$@"`, and a textual
substitution of `$1`/`$@` resolves neither. What works is simpler: a printf
whose output is REDIRECTED INTO A FILE is walked as code, and a `bash -c` body
that runs something it cannot name literally has its arguments read as
candidates. Each rule is paired in the fixture with the negative that says what
it is keyed on — the same `source <path>` text sent to stderr must stay
NOT-EXECUTED, and a body naming a literal path must not drag its own arguments
in — because the positive alone would be satisfied by a rule that fires on
everything.

Evidence stayed exact: the whole-repo `--evidence` diff is **11 added lines and
zero removed**, every one a real execution, and no candidate changed its
EXECUTED/NOT-EXECUTED verdict.

**What the gate refuses, and what it deliberately does not offer.** There is no
per-row escape hatch. If a genuine oracle is invisible, `derive-targets.sh` is
what gets fixed — the doctrine is that the map is derived and checked against,
never trusted, and a hand-written "trust me" marker is precisely the way a
bogus oracle would get in. The gate applies to `EXECUTED-*` rows only: a
GREPPED-ONLY target is by definition executed by nobody, and its oracle asserts
about the file's text.

**A coverage question the fix opened, and closed by measuring.**
`tests/lib-layer-checks.sh` gained three newly-visible executors, which is
exactly the shape that made the oracle field a SET in F16. Each was run against
that target at `--jobs 1`: 48 mutants, 42 killed, **the same 6 survived** in all
three. They execute the file without asserting on anything the six damage, so
the row stays 1:1 and the measurement is recorded beside it, so nobody re-derives
the answer from the executor list.

Original finding:


`derive-targets.sh --check` gates the oracle field on three things: the test
exists, `run-all.sh` selects it uniquely, and it is not named twice. It does
**not** check the one thing that would matter most — that the named test is
among the tests the derivation observed EXECUTING that target.

The consequence is asymmetric, which is why this is a gap rather than a hole: a
bogus oracle produces false SURVIVORS, never false kills, so it inflates the
ledger's debt instead of hiding it. Every survivor still has to be classified by
hand, and a reviewer classifying eleven survivors of a target whose oracle never
touches it would notice. But it is checkable and is not checked.

**Why it cannot simply be switched on.** The derivation resolves execution
statically, and it misses at least one real shape: `tests/lib-verify-repo.sh` is
executed by its own dedicated oracle `tests/test-lib-verify-repo.sh`, which
builds a harness script with

```bash
printf 'source %q\n' "$REPO_DIR/tests/lib-verify-repo.sh" >> "$h"
```

and then runs it. The scan sees no `source` at a command position, so
`--list` reports that file as executed by `test-layer-containment.sh` and
`test-verify-exit-code.sh` only. Turning the gate on today would reject a row
that is correct. Note the derivation is UNDER-reporting here, so `--evidence`
understates what drives a target — which is the same blind spot F16 was about,
one level down.

**Shape of the fix:** teach the derivation to recognise a target path written
into a file that is later executed (the `printf … >> "$h"; bash "$h"` idiom),
then add the `oracle ∈ executors` gate with its own demonstration. Both halves
are needed: the gate without the derivation fix is a false alarm, and the
derivation fix without the gate buys only a more honest `--evidence`.

## F34 — `producer | grep -q` under `pipefail` reports absence for something present — **FIXED**

Closed by `wf_has_step()` in `tests/lib-layer-checks.sh` (capture first, match
against a complete value — the producer's status is then read directly and cannot
race) and by `tests/test-grep-q-pipelines.sh`, which enforces the rule repo-wide
and passes. Verified 2026-08-19.

Original finding:


**Found by the falsify tier, in a test the tier had just started running several
copies of at once.** `tests/test-layer-containment.sh` failed with
`hermetic-checks.yml job 'suite' has NO step named 'Run tests' — this registry
row is stale` on a machine where nothing was stale, and passed on the next run.

The mechanism, measured rather than argued:

```bash
set -o pipefail
wf_steps "$f" "$job" | grep -qxF "$step"      # says "no" about a step that is there
```

`grep -q` exits the instant it matches. The producer, still writing, takes the
broken pipe and dies 141 — and `pipefail` promotes that over grep's success, so
the pipeline reports failure for a successful match. Reproduced two ways:

* **Deterministically, by size.** A producer larger than the pipe buffer with the
  match on its FIRST line: **200 false negatives out of 200**. A five-line
  producer: 0 out of 2000, because the whole output lands in the pipe buffer
  before grep runs.
* **Under load, at four lines.** On a 4-core CI runner with four concurrent
  copies, 2 of 4 PRISTINE trees failed. Instrumented at the failure point, a
  captured call made microseconds earlier returned rc=0 with the step present,
  while the piped call on the next line said no.

That second reading is the dangerous one: the guard's failure mode is a LOUD,
plausible, wrong message about a registry being stale, arriving only on a busy
machine — and, through the falsify tier, arriving as a KILLED verdict for a
mutant nothing had actually noticed.

**Fixed here:** `wf_has_step()` in `tests/lib-layer-checks.sh` captures the
producer's output and status first, then matches; `tests/test-layer-containment.sh`
uses it. `tests/test-layer-checks-parser.sh` pins it with an 8000-step fixture
that loses the race 100% of the time, plus a control asserting the piped
spelling really does fail on that fixture — so the assertion measures the fix
and not a fixture that never raced. Two more early-matching sites inside falsify
ORACLES were fixed the same way: `tests/test-tools-d.sh`'s
`find … | grep -q .` and `tests/test-mutations.sh`'s `sed … | head -1 | grep -q .`.

### CORRECTION 2026-08-19 — "a site asserting ABSENCE is safe" was WRONG

This entry originally said:

> A site asserting ABSENCE is safe by construction: grep consumes the whole
> input, never exits early, and its own 1 is the correct status.

That is true only while nothing matches — i.e. only while the guarded defect is
absent. **The moment the defect appears, grep matches, exits early, and the
producer's broken pipe becomes the pipeline's status under `pipefail` — so the
`if … then fail; else pass` guard takes the `else` branch and reports NO
DEFECT.** Measured on the same fixture as the original finding: **50/50 runs
silently reported no defect while the defect was present.**

That is the worse of the two directions, and the reason is exactly why it slipped
past: a match-expected site fails loudly and gets noticed, while an
absence-expected site is green on a healthy tree and lies only in the one moment
it exists to speak up. Four real guards were in that shape — the `grep|grep`
regression guard in `test-blocked-capture.sh`, the `curl | bash` one in
`test-rvm-reconcile.sh`, the bare-`timeout` one in `test-integration-runner.sh`,
and two `lc_rows` checks in `test-layer-checks-parser.sh`.

**So the rule is unconditional: no `producer | grep -q` under `pipefail`, either
direction.** Two correct spellings, both verified against the same input:

```bash
grep -q X < <(producer)          # producer is not in the pipeline; use when only the match matters
out="$(producer)" || return 1    # keeps the producer's status, which some callers need
grep -q X <<<"$out"
```

### RESOLVED 2026-08-19 — swept, and guarded

All 53 sites converted (37 mechanically, 16 by hand); one deliberate fixture —
the control in `tests/test-layer-checks-parser.sh` whose job is to BE the piped
spelling — carries the opt-out `# grep-q-ok: <reason>`, and the reason is
checked, exactly like `# dialect-lint: allow`.

`tests/test-grep-q-pipelines.sh` is the guard. It does not merely grep for the
shape: it first **measures the hazard on the machine it is running on**, in both
directions, and asserts that both replacement spellings work — so a reader who
doubts the rule sees it reproduced rather than asserted. It then scans every
tracked `*.sh` that sets `pipefail`, and fails when it scanned nothing at all
(the vacuous-pass case that this repo keeps rediscovering).

Demonstrated failing four ways: reintroducing one piped `grep -q` in product
code; blanking an opt-out's reason; removing the repo's `.git` so the scan finds
no files; and — found BY the guard rather than by review — the guard's own two
`printf … | grep -q` lines, which were invisible while the file was still
untracked. That last one is the `capture-on-host.sh` trap again: `git ls-files`
cannot see a file you have not added, so a new checker's verdict changes at
`git add` time.

A `bash-dialect-lint.sh` rule was considered and rejected: that linter's subject
is "no construct newer than the declared bash floor", and this is a correctness
idiom available in every bash version. Mixing them would blur what a
dialect-lint failure means.

## F35 — an oracle KILLED BY A SIGNAL was scored as a KILL — **FIXED 2026-08-19**

**Found by chasing F32 case 1 for a mechanism instead of raising a timeout.**

`falsify_exit_kills()` was `[[ "$1" -ne 0 ]]`. `wait` reports a signal death as
128+N, so 137 (SIGKILL) satisfied it, and with no `FAIL:` line and no watchdog
flag the verdict was **`KILLED`, signal `exit`** — a mutant nothing asserted
about, recorded as caught.

Measured, not theorised:

```
oracle rc=0   → SURVIVED  none        oracle rc=137 → KILLED  exit
oracle rc=1   → KILLED    exit        oracle rc=143 → KILLED  exit
oracle rc=2   → KILLED    exit        oracle rc=139 → KILLED  exit
```

**The trigger is present, not hypothetical.** The tier runs `--jobs $(nproc)`
workers, each running a WHOLE `run-all.sh`; the container this was found in
reports `oom_kill 7` and `max 82844` against an 8 GiB `memory.max`. The kernel
picks a process and SIGKILLs it. Which one it picks decides the symptom:

| kernel picks | result file | what the tier reported | honest? |
|---|---|---|---|
| the **worker** | empty | `FR_BROKEN`, `rc=1`, named on stderr | yes — this is F32 case 1's symptom |
| the **oracle** | a `MUTANT\|KILLED\|…\|exit` line | a kill | **no** |

This is the same inversion F12 found in the timeout path and F31 found in the
scaffold path, arriving through a third channel. It fails in the one direction
this tier must never fail in: it REMOVES a survivor the ledger was owed, so
`check-ledger.sh` stops demanding an entry and the coverage claim grows while
the coverage does not.

**The fix.** `falsify_died_of_signal()` (`rc >= 128`); `falsify_exit_kills()`
excludes it; and `falsify_verdict()` gains a third "the oracle never observed
anything" branch, ordered after `scaffold` and before `SURVIVED`, yielding
`UNPROVEN` with signal `signal`. A `FAIL:` line printed before the signal still
wins — the assertion WAS observed failing, and the process dying afterwards
does not unsee it. A timeout still owns its own branch, because "raise
`--timeout`" and "the host ran out of memory" send a reader to different
places; the runner now warns on stderr naming `--jobs` and the memory cap.

**The 128 boundary is sound, and pinned by effect.** `tests/run-all.sh` returns
0, 1 or 2 and never a failure COUNT, so no honest driver status can reach 128.
`tests/test-falsify-run.sh` runs the real driver all four reachable ways and
records what it returns, rather than trusting that sentence.

**Demonstrated failing**, with a fixture oracle (I) that SIGKILLs its own
`$PPID` — which IS the driver, since `falsify_run_oracle` `exec`s it in the
subshell it waits on:

| break | what the case reads |
|---|---|
| the boundary moved to 256 | `KILLED`, signal `exit` — the original bug, exactly |
| the verdict branch deleted | `SURVIVED`, signal `none` — the other wrong answer |
| `falsify_exit_kills` reverted | signal `exit+signal`, claiming the driver chose 137 |
| the stderr warning suppressed | no actionable diagnosis on the run |

Corpus after the fix: `251|220|27|4`, byte-identical — the change is inert on a
healthy run and only fires when the environment shoots an oracle. That is
deliberate: it converts a silent over-count into a loud, ledger-visible
failure, which will turn a transiently OOM-killed CI run red rather than green.
That trade is the whole point.

**Not fixed here:** capping `--jobs` below `$(nproc)` on a memory-capped host
(F32's third option). The tier no longer LIES under memory pressure, which is
the half that mattered; how much pressure to allow is a tuning decision with
its own measurement.

---

## F36 — the launcher tier's hand procedure cannot demonstrate a mutation that lives in the image

Found by the F5 work, from the same derivation. `AGENTS.md` documents the
launcher-tier demonstration as:

```bash
tests/integration/mutate.sh apply 400-ro-suffix-dropped
tests/integration/run.sh --reuse-image --tags mounts     # expect 400 to FAIL
```

`--reuse-image` is correct for `400`: `sandbox.sh` is a host script, read from
the working tree at launch time. It is **wrong** for every patch whose target is
baked into the image, and running `patch_needs_rebuild` over the whole mutation
set names them:

| patch | target | tier |
|---|---|---|
| `410-workspace-root-not-chowned` | `entrypoint.sh` | mounts |
| `630-rvm-root-not-chowned` | `entrypoint.sh` | volumes |
| `700-agent-tools-not-linked` | `entrypoint.sh` | packages |
| `740-default-ruby-not-linked` | `entrypoint.sh` | packages |
| `745-ruby-hooks-not-exposed` | `link-default-ruby.sh` | packages |
| `750-only-default-ruby-installed` | `rvm-reconcile.sh` | packages |
| `720-npmrc-prefix-restored` | `Dockerfile` | packages |
| `735-toolchain-not-restored` | `Dockerfile` | packages |
| `730-db-clients-not-space-split` | `build.sh` | packages |

Nine patches whose documented demonstration procedure applies the mutation to a
file the container never reads. Each would report its case PASSING, i.e. the
mutation dead, having tested an image built before the patch existed.

**Not the same defect as F5, and not closed by it.** F5 was one case with no
mutation at all; this is nine mutations with a demonstration procedure that
cannot exercise them. Nothing here is known to be broken — the patches may well
be perfectly good — which is precisely the point: nobody can currently tell,
because the only procedure on offer answers a different question.

`patch_needs_rebuild()` and `build_clean_image()` in
`demonstrate-network-tier.sh` are the mechanism; what is missing is a
launcher/packages-tier demonstrator that uses them. Parked rather than done
because the packages tier's cases cost tens of minutes each and budgeting that
run is its own decision.

## F37 — `demonstrate-network-tier.sh` now covers two tiers and its name says one

It selects `network-mode` **and** `delivery` as of F5. The filename, its usage
text, and its own error messages still say "network tier". Same shape as F7 —
a name describing a script that no longer exists — and recorded the same way
rather than fixed inline, because renaming it touches
`tests/falsify/targets.conf`, `AGENTS.md`, and the identically-named file in
`mgd-ai-containers`, which is a coordinated change rather than a `git mv`.

The honest name is awkward on purpose: the set is "every mutation whose case
must be run against a real image", which is the complement of the hand-driven
launcher tier and the expensive packages tier. If F36 lands first, the
complement collapses and the script becomes the demonstrator for everything,
at which point `demonstrate-mutations.sh` is simply correct.

## F38 — `--jobs $(nproc)` oversubscribes a CPU quota, and nothing bounded how much a run left unmeasured — **FIXED 2026-08-19**

**Found by two machines disagreeing about the same commit on the same day.**
A host run of the merged tree reported `251|210|15|26`; the same commit here
reported `251|223|24|4`. Thirteen mutants that are killed moved to UNPROVEN,
nine survivors moved with them — and **both runs scored green**.

### 1. `nproc` is not the number of CPUs you may burn

`nproc` reads the affinity MASK. `docker run --cpus=N` sets a CFS QUOTA and
leaves the mask alone, so inside such a container `nproc` reports the HOST's
count. This repo's own `sandbox.sh:810` starts every container with
`--cpus="${CONTAINER_CPUS:-1.0}"`, and both callers sized the tier with
`$(nproc)` — `verify-on-host.sh` and `hermetic-checks.yml`.

Measured here, one target (`tests/lib-verify-repo.sh`, 49 mutants, no
structural timeouts), `nproc` 12, quota 8, **verdicts identical on every row**:

| `--jobs` | 1 | 2 | 4 | **8** (quota) | 12 (`nproc`) | 16 | 32 | 48 |
|---|---|---|---|---|---|---|---|---|
| wall | 55 s | 31 s | 20 s | **16 s** | 15 s | 15 s | 17 s | 18 s |
| ms/mutant | 1041 | 1124 | 1351 | **1901** | 2881 | 3539 | 7541 | 11294 |
| slowdown | 1.00× | 1.08× | 1.30× | **1.83×** | 2.77× | 3.40× | 7.24× | 10.85× |

Wall-clock stops improving AT the quota and then gets worse; the per-mutant
clock keeps climbing. Going from the quota to `nproc`'s 12 buys **one second**
and spends **52%** of every mutant's timeout budget — and that budget is what
decides KILLED versus UNPROVEN.

**Fixed:** `run.sh --jobs auto` = `min(what the OS reports, the cgroup quota)`,
reading cgroup v2 `cpu.max` and v1 `cpu.cfs_quota_us`/`cfs_period_us`. Both
callers pass `auto`. On a runner with no quota it resolves to exactly
`$(nproc)`, so CI's numbers do not move; it stops being a lie elsewhere. The
runner prints BOTH numbers, because `jobs=8` alone leaves a reader unable to
tell a quota from a small machine and that gap is the whole finding.

One design correction made mid-work: `fr_quota_cpus` first had THREE separate
rejections (v2's literal `max`, v1's `-1`, a regex) and the test could not
break any of them individually — each was covered by the others. **An assertion
no single change can falsify is not a guard**, which is F17's lesson arriving
from the other side. Collapsed to one.

### 2. Nothing bounded how much a run left unmeasured

An UNPROVEN mutant is deliberately NOT owed a ledger entry (F27: the timeout is
machine state, and a ratchet that cannot be satisfied everywhere at once is not
a ratchet). That exemption is right. Its price was never paid: **an unbounded
number of mutants could drop out of the measured set with nothing failing.**
`verify-on-host.sh` already said so out loud at ≥10% — but only advisorily, and
CI, the REFERENCE environment that runs `--strict`, had no such check at all.
The strict environment was the one with no floor on how much it measured.

**Fixed:** `run.sh --max-unproven-pct N`, opt-in, judged where the run's
trustworthiness already is. CI passes 10 — the same number Phase 6 warns at,
one concept with one number. Phase 6 stays advisory, the same asymmetry
`--strict` already draws.

### 3. Three places said UNPROVEN is owed a ledger entry. The gate says otherwise

`run.sh`'s header ("It is owed a ledger entry like a survivor"), its
`falsify_verdict` note, and `AGENTS.md` all claimed the requirement that
`check-ledger.sh`'s check B explicitly declines to impose. **The AGENTS.md
sentence was made worse by F35's edit**, which expanded it while keeping the
wrong claim. A reader hitting a red ledger would have gone looking for an entry
the gate never wanted. All three now state the actual contract — accepted, not
required — and name what bounds it instead.

### Demonstrated failing

| break | what goes red |
|---|---|
| `fr_cpu_budget` returns the host count | every quota case, and `--jobs auto` resolves to 12 |
| cgroup v1 layout not read | the v1 case only |
| the single rejection guard removed | `max`, `-1` and garbage all become a quota of 1 |
| the fractional floor removed | a half-CPU quota yields **0** workers |
| the unproven budget never fires | a 100%-unproven run passes a budget of 50 |
| the budget's validation removed | `--max-unproven-pct banana` exits 1, not 2 |

### A correction CI made, on a machine smaller than this one

The first version shipped two defects that a 12-CPU host cannot see, and a
**2-CPU runner caught both**:

- the resolution note branched on whether the quota **binds** (`quota < host`)
  rather than on whether one **exists**. Against a 2-CPU quota on a 2-CPU
  runner it printed "no cgroup CPU quota in effect" — the opposite of the
  truth, and precisely the fact a reader came for. It now branches on
  existence, and a case plants a quota equal to `fr_host_cpus` so the
  regression is visible on ANY machine.
- the cases asserted "quota 3 → budget 3", which hard-codes a host with at
  least 3 CPUs. Now what is READ from each layout (a machine-independent fact)
  and what it BECOMES are checked separately, and the capping is pinned with a
  1-CPU quota, which binds everywhere. A helper that recomputed
  `min(quota, host)` to build the expectation was considered and rejected: that
  is the implementation written twice, agreeing with itself however wrong it is.

Corpus unchanged: `251|223|24|4`, ledger clean under `--strict`.


## F39 — `mutate.sh` has diverged between the two repos, and the file itself says it must not — **FIXED 2026-08-19, in the increment that found it**

Found while porting F19/F20/F21. `tests/integration/mutate.sh` is no longer
byte-identical across `ai-containers` and `mgd-ai-containers`. mgd's copy carries
a `patch_prefix()` function — roughly sixty lines — that upstream does not, and
mgd's own comment on it says:

> Upstream's copy of this file carries the same latent defect; it is invisible
> there for exactly that reason. Deciding the prefix from the PATCH rather than
> from the repo is the fix in both, and leaves the upstream behaviour
> bit-for-bit unchanged.

So the fix was written, its author noted that upstream needs it too, and it never
travelled. The defect: `APPLY_PREFIX` was decided **per repo** rather than **per
patch**, which is correct only while every patch damages an engine file. The
network-tier mutations damage `tests/integration/cases/*.sh` and
`tests/integration/lib.sh`, which live at the repo root in **both** layouts —
`tests/` is never under `base/` — so a blanket `--directory=base` turns them into
`base/tests/integration/…`, a path that exists nowhere.

**This is not a live defect upstream** — with an empty `APPLY_PREFIX` the
short-circuit fires before anything is inspected, so today upstream behaves
identically either way. What is live is the divergence itself, and `mutate.sh`'s
own header is the thing it contradicts:

> One mutation set serves both layouts, and the shared files stay
> byte-identical, which is the property that lets a fix in one repo be a
> straight copy into the other.

That property is now false for this file. The next fix to `mutate.sh` in either
repo is a merge, not a copy, and the falsify tier already reads the difference:
mgd measures 59 mutants on this target where upstream measures 55.

**The fix:** port `patch_prefix()` upstream, restoring byte-identity. Behaviour
upstream is unchanged by construction, so the assertion that it landed correctly
is the corpus itself — upstream's mutant count rises 55 → 59 and every one of the
four new mutants must be KILLED by `test-mutations.sh`, which is what mgd already
measures. `tests/test-shared-files-parity.sh` guards a different list (the files
`project-init.sh`/`sync-to-projects.sh` copy into a project) and would not have
caught this; whether a cross-repo parity check is worth building is a separate
question from making these two files equal again.

**Fixed in the same commit.** `patch_prefix()` was copied upstream verbatim and
the two files are byte-identical again. The corpus is the check, exactly as
stated above: upstream's mutant count on this target rose **55 → 59**, all four
new mutants are KILLED by `test-mutations.sh`, and upstream's whole-corpus TOTAL
is now `9|255|240|11|4|11|5` — the same reading mgd measures, line for line.
`mutate.sh verify` still reports every one of the 33 real mutations applying.

Left open deliberately: whether a mechanical cross-repo parity check is worth
building. `tests/test-shared-files-parity.sh` guards a different list and could
not have caught this; nothing today compares the two repos' copies of a shared
file, and this divergence was found by a human reading a diff during a port.

## F40 — Phase 7 lints only the engine directory, and reports PASSED over the rest — **FIXED 2026-08-19**

Found by running Phase 7 on the Mac to verify F-nothing-in-particular — the
version-reporting change from the previous increment. The verification found a
defect the change had nothing to do with.

`verify-on-host.sh` Phase 7 built its file list with
`( cd "$REPO" && git ls-files '*.sh' )`. **`git ls-files` run from a
subdirectory lists only what is under that subdirectory.** `$REPO` is the
ENGINE directory — the repo root in ai-containers, `base/` in
mgd-ai-containers, which is why the script's own startup error tells you to run
it from there. So in mgd, Phase 7 checked `base/**` and nothing else.

Measured on macOS, 2026-08-19, the same command in each repo:

| | scripts Phase 7 checked | scripts CI's `lint` job checks |
|---|---|---|
| ai-containers | 133 | 133 |
| mgd-ai-containers | **23** | **136** |

The 113 it skipped were the entire hermetic suite, the whole falsify engine and
every integration case — the code every guard in this project lives in.

**Why "CI catches it anyway" is not the answer.** CI does, so nothing merges
unlinted. But the local layer exists to cover what CI *structurally cannot*:
BSD userland, macOS, a real network. A macOS-only parse or shellcheck finding
in those 113 files was invisible in **both** layers at once — CI is Linux, and
local skipped the files. `local ⊇ nightly ⊇ PR` was false for the lint leg,
with local a strict SUBSET.

Two of Phase 7's three checks were affected. The dialect lint was not: it is
invoked through `$TESTS_DIR`, which already carries a `$REPO/../tests` fallback
for this exact layout, and it resolves its own root. So one of the three call
sites had already been fixed for the sibling layout and the other two had not.

**The fix** reuses the derivation the file already had. `REPO_ROOT_FOR_MOUNT`
(`$(cd "$TESTS_DIR/.." && pwd)`) is *the repo root in both layouts* and had
exactly one consumer, Phase 5's container mount. Renamed to `REPO_ROOT` and
given its second consumer. A no-op in ai-containers, where `$REPO` is already
the root.

**The guard**, `tests/test-verify-lint-scope.sh`, was written first and watched
failing. It drives the real `verify-on-host.sh` against stub repos in BOTH
layouts, with a tracked script carrying a real syntax error planted OUTSIDE the
engine directory, and requires Phase 7 to report it. The witness is `bash -n`'s
own `PARSE ERROR: <path>` line — it cannot appear unless `bash -n` genuinely
read that file. Against the unfixed tree:

```
PASS: upstream: Phase 7 parsed every tracked script (5 of 5)
PASS: upstream: the parse error fails the phase (rc=1)
FAIL: sibling: Phase 7 never parsed outside-engine-broken.sh … (parsed 3 script, repo has 5)
FAIL: sibling: Phase 7 exited 0 despite a syntax error in a tracked script
```

The upstream layout is a control: without it, a fixture that silently built
nothing would look like a pass in both directions. The sibling layout is the
first fixture in this repo to build one at all — every existing stub repo puts
the engine at the git root, which is precisely why nothing saw this.

## F41 — `verify-on-host.sh` had drifted between the repos, in three places — **FIXED 2026-08-19**

F39's pattern, in a second file, found the same way: by diffing the two copies
while porting F40. This file states the invariant it was breaking, in its own
words:

> Resolving it here means ONE copy of this script serves both repos verbatim —
> a verifier that drifts from what it verifies is worse than none.

Three differences, all of them mgd corrections that never travelled upstream:

1. **Stale Phase 6 comments.** Upstream said "6 is reserved for a later
   increment; do not fill it in ahead of that increment defining it" and "6 …
   must stay absent until that increment defines it" — while the same file
   carried `VALID_PHASES="0 4 5 6 7"`, `PHASES` defaulting to `"4 5 6 7"`, and a
   fully implemented `PHASE 6 — falsify mutation tier`. A maintainer following
   the comment would delete a working phase. `AGENTS.md` had the correct account
   the whole time.
2. **`$REPO/tests/falsify/...`** in Phase 6's two invocations, where mgd used
   `$TESTS_DIR`. Correct upstream, resolves to a nonexistent path in mgd —
   *the same defect class as F40*, in the same file, already fixed once locally
   without being fixed at the source.
3. Repo-relative prose ("here", "this repo", "measured upstream").

All three are resolved and the two copies are now **byte-identical**. The prose
was made repo-neutral rather than picking a side, so the claim above is true as
written and a future fix in either repo is a straight copy.

**Third data point for F39's open question.** Two shared files have now drifted,
both times hiding something: `mutate.sh` hid a latent prefix defect, this one hid
a live coverage defect. Both are byte-identical again, so a mechanical cross-repo
parity check now has concrete files to compare. Still not built, and still
recorded rather than assumed worth building — but "found by a human reading a
diff during a port" has happened twice in one day.

## F42 — the local lint cannot see a script you have just written

Found the hard way, in the increment that fixed F40: CI failed the very PR whose
subject was *"the lint gate's file list silently omits files"*, on an SC2034 in
the new test file, after the local gate had reported clean over all 133 scripts.

Both layers build the list with `git ls-files '*.sh'`, which lists **tracked**
files. A brand-new script is untracked until `git add`, so the local run skips
it and says nothing — the author's first feedback is a red CI job. CI is
unaffected: it checks out a branch where the file is committed.

This is the same failure shape as F40 — a gate reporting success over a file it
never read — reached by a different route: not the wrong directory, but the
wrong side of the index. And it bit while fixing F40, which is the strongest
argument that "the file list is complete" deserves to be checked rather than
assumed.

**Mitigation in the meantime** (used to re-verify this increment):

```bash
git add -N .          # intent-to-add: makes new files visible to git ls-files
git ls-files '*.sh' | xargs shellcheck -S warning -e SC1091
```

**Not yet decided.** `git ls-files` meaning "what is in the repo" is defensible,
and `--others --exclude-standard` would pull in every stray scratch file in a
developer's tree, which is its own false-positive problem. Options worth
weighing: add `-o --exclude-standard` only in Phase 7 (local, where a dirty tree
is normal) and leave CI on tracked-only; or have Phase 7 simply SAY when the
working tree holds untracked `*.sh` it did not check, which costs nothing and
removes the surprise. Recorded rather than guessed at.

## F43 — a test that sources a product script inherits its `set -e`, and an abort scores as a KILL

**Found 2026-08-19 while closing F15, by a demonstration that produced no
`FAIL:` line.** The mutant was scored KILLED by the tier and the oracle exited
1, but nothing had asserted anything.

`tests/test-shared-files-parity.sh:129` sources the **product** script
`sync-to-projects.sh` in order to call its `sync_project()` function.
`sync-to-projects.sh:21` is `set -euo pipefail`. `set -e` is a shell option, not
a property of the sourced file, so **every line of the test after line 129 runs
under errexit** — which that test never asks for and its own `set -uo pipefail`
on line 24 says it did not want. Measured: `$-` reads `ehuB` at the end of the
file.

The consequence is specific and bad. Under errexit a bare command that returns
non-zero ends the test **where it stands**: no `FAIL:` line, no failure count,
just exit 1. And exit 1 is precisely what the falsify tier reads as a kill. So a
mutant that makes any post-line-129 command fail is recorded as caught by an
oracle that never reached its assertion.

Two of `shared-files.sh`'s three re-entry-guard damages were being "killed"
exactly that way. The tier's own evidence column had been saying so all along
and nobody had read it — a real assertion failure is logged `exit+failline`,
these were logged plain `exit`:

```
MUTANT|KILLED|shared-files.sh:return-flip:7bfb0010…|test-shared-files-parity.sh|3|28|exit|278|  return 1 2>/dev/null || exit 0
MUTANT|KILLED|shared-files.sh:return-flip:7bfb0010…|test-shared-files-parity.sh|5|28|exit|412|  return 0 2>/dev/null || exit 1
MUTANT|KILLED|shared-files.sh:cond-negate:9684484e…|test-shared-files-parity.sh|1|27|exit+failline|439|…
```

### What was done here, and what was not

F15's new assertions are written to survive it: each runs its subject as the
CONDITION of an `if` rather than as a bare statement, and the whole block is
placed **above** line 129 rather than at the end of the file — which is what
lets damage C fail on a named assertion instead of aborting the run before the
assertion is reached. That is a local fix for the assertions this increment
added. **It is not a fix for the file, and it is not a fix for the class.**

Three things remain open, in order of value:

1. **`exit` versus `exit+failline` is already the evidence and nothing uses
   it.** `run.sh` records which channel produced a kill. A kill with no
   `failline` means the oracle exited non-zero without printing an assertion
   failure — sometimes legitimate (a test whose contract IS its exit status),
   often a scaffold abort. A report, or a ratchet, over that column would have
   surfaced this without anyone stumbling into it. This is the cheapest of the
   three and the one that generalises.
2. **`test-shared-files-parity.sh` should not silently run under errexit.** The
   honest options are to restore the file's own options after the source
   (`set +e` immediately after, with a comment saying why), or to call
   `sync_project()` in a subshell. Restoring is a one-line change; the reason it
   is not made blind is that eleven existing assertions have been running under
   errexit and are green, and turning it off could change what they do. Measure
   before changing.
3. **Any other test that sources a product script has the same exposure.**
   **Swept 2026-08-19, by measurement rather than by reading.** Thirteen test
   files source a product script that carries `set -e`; `$-` was sampled at the
   end of each actual run, and **four** of the thirteen end under errexit — all
   four through `sync-to-projects.sh`:

   | test | `$-` at end | a falsify oracle? |
   |---|---|---|
   | `test-launcher-migration.sh` | `ehuB` | no |
   | `test-sandbox-schema.sh` | `ehuB` | no |
   | `test-shared-files-parity.sh` | `ehuB` | **yes — `shared-files.sh`** |
   | `test-sync-project.sh` | `ehuB` | no |

   The other nine (sourcing `build.sh`, `repo.sh`, `project-init.sh`) end
   `huB` — they source in a subshell or never reach the `set -e`. So the tier's
   exposure today is exactly one target, the one this increment already
   handled; the other three are ordinary suite tests where an abort costs a
   silent partial run rather than a false kill. Static reading would have put
   thirteen files on this list and been wrong about nine of them.

### Why this is a finding and not a footnote

It is the mutation tier's own failure mode: the tier measures "did the oracle
notice", and it infers that from an exit status, so any mechanism that makes an
oracle exit non-zero *without noticing* inflates the coverage claim. That is the
same family as F35 (a signal death scored as a kill) and F30 (a load-induced
kill), and it is the third member found. Each one was found by hand, on one
mutant, by someone looking closely; none was found by the gate.

The three together are the argument for item 1 above: the tier should be able to
say how many of its kills came with an assertion attached, the way it already
says how many mutants it left unmeasured (F38).
