# Increment 5 — parked findings

Committed, not scratch: the SDD workspace is deleted on completion and a
finding that lives only there is a finding that gets dropped.

**Status:** OPEN

---

## F1 — `repo.sh` executes 2 of its 19 functions under the hermetic suite — **EXECUTION COVERAGE COMPLETE 2026-08-29 (22 of 22, measured); mutation-tier entry still OPEN**

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

## F2 — `sandbox.sh`'s discovery and open modes are never executed hermetically — **FIXED 2026-08-20**

`tests/test-mode-capabilities.sh` runs `sandbox.sh` in **all three** modes
against a fake `docker`, so the argv-parsing and mode-dispatch paths of discovery
and open are executed. What remained unexecuted was everything the three modes do
*differently* beyond the capability array — notably discovery's
`output_mount_flags` branch.

**The remainder is closed 2026-08-20** by `tests/test-mode-output-mounts.sh`,
which drives the same three modes through the same fake-`docker` technique and
asserts the block directly below the capability array — 18 assertions over three
independent decisions:

| mode | `DISCOVERY_CAPTURE_ENABLED` | output mount | dir created on host |
|---|---|---|---|
| restricted | `0` | `.agent-blocked` | `.agent-blocked` |
| discovery | **`1`** | `.agent-discovery` | `.agent-discovery` |
| open | `0` | **neither** | **neither** |

**The trap, measured before a line was written, and it would have made the whole
file vacuous.** `DISCOVERY_CAPTURE_DIR=/workspace/.agent-discovery` and
`BLOCKED_CAPTURE_DIR=/workspace/.agent-blocked` are on the argv in **all three
modes** — they are path constants the entrypoint reads, not mode decisions. An
assertion greping for either name passes in every mode, including the one that
must not have the mount, and goes on passing with the branch deleted. What
discriminates is the `-v` PAIR (the `:` is the whole difference) and the value
of `DISCOVERY_CAPTURE_ENABLED`.

**Two assertions earn their place by failing ALONE**, which is the only way to
show a check is not riding on its neighbours:

| damage | failures |
|---|---|
| `cond-negate` the discovery test | 11 |
| `cmp-flip` that same `==` to `!=` | 11 |
| `cond-negate` the restricted `elif` | 4 (open gains a mount) |
| set `capture_enabled` to `"0"` in the discovery branch | **1** — the flag alone |
| delete the discovery `mkdir`, keep its `-v` | **1** — the directory alone |

The mount and the `mkdir` are separate statements and only one of them is the
mount, so a `-v` pointing at a directory that was never created reads as a
perfectly good mount on the argv. `capture_enabled` is a third decision no mount
assertion can see — and it is the flag that decides whether the firewall capture
runs at all, which is the same class of thing as this project's founding example
of a check that reports success while doing nothing.

**And one damage that does NOTHING, recorded because it was in the test's header
first and was wrong:** turning the `elif` into a plain `if` changes nothing
observable — the two conditions are mutually exclusive. "Obviously that would
break it" is how a demonstration ends up proving nothing.

**A knock-on worth acting on later:** `targets.conf`'s DEFERRED row for
`sandbox.sh` says its whole-file oracle is "a restricted-mode-only whole-file
subprocess". That is now stale — two hermetic tests run it as a subprocess in
all three modes. Un-deferring `sandbox.sh` still needs its own increment (the
row's other half, the five sourced functions at a different granularity, is
unchanged), but the stated blocker is half gone.

### Original finding

`sandbox.sh` runs as a real subprocess (only `docker` faked) in
`test-docs-path.sh`, `test-tool-config-mounts.sh` and `test-tools-d.sh` — but
**only ever as `sandbox.sh restricted`**. `tests/test-open-mode.sh` greps and
`bash -n`s the other two modes rather than running them.

Covered by integration cases `110`, `120`, `210`, `220`, `230`, so this is a
tier gap rather than an absence of coverage. Worth closing because the hermetic
tier is the cheap one: the same fake-`docker` technique that already drives
restricted mode would extend to both other modes for very little.

## F3 — `any_active` in `sandbox-common.sh` is dead code — **FIXED 2026-08-20**

Zero callers repo-wide (verified by grep). Either a leftover or an intended
extension point that never landed. Deleting it is a one-line change; the reason
it was recorded rather than done is that it belonged to no task in that
increment's plan and a drive-by deletion is how unrelated breakage gets
attributed to the wrong change.

**Re-derived before deleting**, since the entry is a hypothesis like any other:
`any_active` appears exactly twice in each repo — its own definition and the
gitignored project copy under `.ai-containers/`, which regenerates. No indirect
call shapes (`eval`, `declare -F`, `$fn "$@"`) exist in the file. Its only
callee, `is_active`, keeps six real callers across `sandbox.sh` and `build.sh`,
so nothing became dead behind it. Removed from both repos.

## F4 — `install-tools.sh:api_get` is unexercised — **FIXED 2026-08-21, and it was hiding a defect**

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

**The rebuild path.** `demonstrate-network-delivery-tiers.sh` derives the build-input set
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

**The one unverified consequence, now measured on the host (2026-08-19).** The
fix was merged with a known open risk, stated at the time rather than discovered
later: `launcher_up`'s wait in `700`/`710`/`720` is the one caller that
legitimately polls for a long time — a cold agent-tools install — and its budget
went from `900 x (1s + docker-exec cost)` (roughly 1170-1800s) down to **exactly
900s**. Nothing in the hermetic suite or the PR gate covers those cases; only the
nightly `packages` tier does.

Run directly on the host, `./tests/integration/run.sh --tags packages --variant
agents --require packages`:

| case | result | wall |
|---|---|---|
| `700-agent-tools-install-restricted` | PASS (12 assertions) | **91s** |
| `710-agent-tools-reused-not-reinstalled` | PASS (3 assertions) | **86s** |
| `720-node-multiversion-nvm-use` | PASS (3 assertions) | **78s** |

`selected 3 of 35, passed 3, failed 0, skipped 0`. The real requirement is ~91s
against a 900s budget — an order of magnitude of headroom, so the reduction was
never close to biting. **This entry is now closed on measurement rather than on
argument**, which is the distinction the risk was flagged for in the first place.

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

## F14 — no mechanical guard against awk interval quantifiers — **ACCEPTED: a prose guard, weaker than this repo's norm and recorded as such**

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

## F22 — four damages hang the oracle instead of failing it; no oracle is time-bounded — **FIXED 2026-08-20**

The 4 UNPROVEN records. `tools-lib.sh:62` (two cond-negate damages) and
`tests/bash-dialect-lint.sh:105` (one) negate a `while read` condition, which at
EOF stays true forever; `tests/integration/docker-shim.sh:60`'s `cmp-flip` makes
the self-reference guard reject a REAL docker and accept the shim, so the shim
re-execs itself. In all four the per-mutant clock expired with no `FAIL:` line —
nothing was observed asserting.

All four are killed now, every one `exit+failline`:

| target | before | after |
|---|---|---|
| `tools-lib.sh` | 15/0 + 2 UNPROVEN | **17/17** |
| `tests/bash-dialect-lint.sh` | 26/0 + 1 UNPROVEN | **27/27** |
| `tests/integration/docker-shim.sh` | 28/0 + 1 UNPROVEN | **29/29** |

### Three things this entry got wrong, all of them found by trying to do what it said

**1. `timeout 10` is not available.** This entry prescribed it by name, three
times. `timeout(1)` is GNU coreutils and a stock macOS does not ship it — which
is not a hypothesis, it is written down twice in this repo already:
`tests/falsify/run.sh:357` hand-rolls its oracle clock and says why, and
`tests/integration/run.sh:182` carries a three-way `it_timeout()` added after
the first real macOS run (2026-08-08) hit exactly this. The prescribed fix would
have been a command-not-found on the one host these callers are verified on.

The bound is `p_timeout` in `tests/portability.sh` instead — the file whose
charter is GNU/BSD-neutral helpers, and which is itself a falsify target, so the
bound is mutation-covered (3 mutants, all killed).

**2. The docker-shim assertion already existed.** `test-integration-shim.sh:108`
has invoked the shim with a self-referencing `IT_REAL_DOCKER` and required exit
127 since the guard was written — word for word the "killing assertion" this
entry asked someone to write. What was missing was one wrapper around the call:
the mutant makes the shim `exec` ITSELF, so the command substitution never
returns and an assertion sitting on the very next line is never reached. Same
shape as F7. **A backlog entry describing a missing assertion is a hypothesis;
grep for it before writing it.**

**3. The obvious implementation of the bound is itself mutation-hangable.** The
first draft of `p_timeout` was the shape `it_timeout()` uses — poll `kill -0` in
a loop, then `wait`. Negate the liveness probe and the loop never runs, so
control falls to a `wait` on a child that is still alive and blocks forever;
measured, it hung `test-portability.sh` for the full two minutes it was given. A
bound whose own `cond-negate` mutant is UNPROVEN would have added a fifth
hanging mutant in the helper written to remove the other four. `p_timeout` uses
a watchdog instead: no loop, no conditional in front of the kill, so every path
through it terminates.

### What else the fix needed, beyond the bound

**A premise gate, in two of the three oracles.** Bounding one call is not enough
when every later assertion runs the same damaged code: `test-tools-d.sh` calls
`tools_read_descriptor` in-process from line 209 onward, and
`test-bash-dialect-lint.sh` runs the linter eighteen more times. Bounding only
the first leaves the file to hang on the next — a `FAIL:` printed and never
reported, which run.sh scores `timeout+failline`: a kill that depends on the
FAIL landing before the clock rather than on the run finishing. Both files now
stop at the premise, named and counted, through the file's own verdict path.
`test-tools-d.sh`'s verdict became a function for that reason: two exits, one
disk-full-versus-real-failure rule, and a second copy of it would drift.

**One assertion of mine that could not fail, caught the same way.** The first
version of `p_timeout`'s third property checked that the bounded command was no
longer alive after the bound expired. It cannot fail: `p_timeout` ends with
`wait "$cmd_pid"`, which does not return until the child is dead. It passed
against a damage that removed the kill outright. What is actually falsifiable is
that the bound CUTS THE COMMAND SHORT — bound a 30-second sleep at 1 second and
require both the 124 and an elapsed time nowhere near 30. Remove the kills and
the status is still 124 while `wait` sits out the full thirty seconds, so only
the clock catches it.

**And a redirect that turns out to be load-bearing.** The watchdog's stdio goes
to `/dev/null` because otherwise it — and the `sleep` it forks — inherit the
caller's stdout, so `out="$(p_timeout 10 …)"` blocks until the sleep finishes
even though the bounded command returned immediately and the watchdog was
already killed. A command substitution reads until every holder of the write end
lets go. Measured: 0s called directly, 10s the moment the same call was wrapped
in `$( )` — which is how two of the three callers use it.

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

> **How to read a heading here.** An entry's STATUS lives in its heading, and
> where an entry has several (F28, F32, F57, F59 …) the LAST one is current.
> Three entries below carried their resolution only in the body and read as open
> from the heading, which cost real work twice on 2026-08-22 — once when the
> Host Agent listed F57 as remaining, and once when this file's own reader
> almost began the 20-call-site increment F57's addendum had already declined.
> Their headings now say so. If you resolve an entry, say it in the heading —
> and `tests/test-docs.sh` now REQUIRES it, because saying it here was not
> enough. The first pass at this was keyword-based and still missed F4 and
> F1, whose resolutions are headed "covered, and the coverage found a defect"
> and "slice 4" — true, informative, and carrying no status a reader or a
> grep can act on. Both were reported as open work hours after the pass.

## F27 — mutation verdicts are environment-dependent, so the ledger could not be satisfied everywhere at once — **RESOLVED: the `ENV-DEPENDENT` classification, verified across the full matrix**

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

## F29 — CI killed a mutant the sandbox container could not, because the product installs itself at the default path — **FIXED 2026-08-17**

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

## F30 — a KILL is only trustworthy if the oracle would have passed under the same load — **CAUSE FOUND AND FIXED 2026-08-30, see F64 RESOLUTION**

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

## F31 — every test's `mktemp -d` is unchecked, and a failed one is scored as a KILL — **FIXED 2026-08-20**

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
but it does **not** fix the false kill on its own, because `run.sh` scores
KILLED on any `FAIL:` line or any non-zero exit. A test that correctly reports
its own scaffolding is broken would still be read as "the assertion noticed the
mutation". The tier cannot tell *the oracle failed* from *the oracle failed
BECAUSE OF THE MUTATION* unless it is told, and that distinction is the whole
tier.

### Re-derived 2026-08-20: most of this entry is no longer true

Both halves have since been built, and the entry still reads as if neither had.
Measured rather than read:

| this entry says | today |
|---|---|
| "the tier cannot tell the two apart" | `run.sh:falsify_has_scaffold_failure` greps for `SCAFFOLD-FAILED:` and scores such a run **UNPROVEN**, checked *before* the survived branch |
| "87 call sites, and NOT ONE checks the status" | **87 sites now guarded**; 15 unguarded assignments remain |
| the false kill | **closed** — every one of the 14 declared falsify oracles guards its `mktemp` |

The third row is the one that matters and it was not obvious from either
number: what makes a failed `mktemp` a FALSE KILL rather than an annoyance is
that the collapsed test is somebody's ORACLE. Intersecting the unguarded set
with the oracle column of `targets.conf` returns empty. The remaining fifteen
are product scripts and non-oracle tests, where a failed `mktemp` costs a
confusing run and cannot manufacture coverage.

**Two of those fifteen were infrastructure and are now guarded too**, because
"non-oracle" understates them:

- **`tests/run-all.sh:51`** — the DRIVER. Every falsify oracle *is*
  `tests/run-all.sh <name>`, so an empty `$log` makes `> "$log"` fail for every
  test in the run. Measured with a failing `mktemp` stub, before the guard:
  `── test-portability.sh` / `FAIL  (exit 1)` **and no `SCAFFOLD-FAILED:`
  anywhere** — the driver's redirect fails before the test can reach its own
  guard, so the test never gets to say its scaffolding broke. It now emits the
  scaffold channel itself.
- **`verify-on-host.sh:333`** — Phase 6's corpus log. An empty path made every
  later read of it report an empty corpus rather than a broken one.

Note how that first measurement lands: `FAIL  (exit 1)` has no colon, so
`falsify_has_fail_line` does not match it — the run would have been a kill with
**no assertion attached**, which is precisely what F43's new `ASSERTLESS`
counter now reports and CI now bounds at 0. The two fixes catch the same event
from opposite ends.

### Closed 2026-08-20 — and the last sweep found the one destructive instance

The remaining sites are guarded in both repos. Two things the sweep turned up
that the count alone did not:

**1. `mgd-ai-containers/tests/test-preset-overlay.sh` DELETED a tracked file.**
It backed up the real `base/projects.conf` around a `project-init.sh` run:

```bash
pc_bak=""; [[ -f "$pc" ]] && { pc_bak="$(mktemp)"; cp "$pc" "$pc_bak"; }
…
if [[ -n "$pc_bak" ]]; then cp "$pc_bak" "$pc"; rm -f "$pc_bak"; else rm -f "$pc"; fi
```

One variable carrying two facts: *where the backup is* and *whether there was
anything to back up*. The restore reads an empty `$pc_bak` as the second, so a
failed `mktemp` sent it down the `else` branch and **removed the tracked
projects.conf it was meant to restore**. The file has no errexit, so the failing
`cp` said nothing. Demonstrated in isolation: present before, absent after. Fixed
by splitting the two facts (`pc_existed`) rather than by guarding alone — the
guard stops the failure, the split stops the misreading.

**2. Three of the sites are `cat "$tmp" > "$file"`, and the shell truncates a
redirect target before it runs the command.** So an empty `$tmp` does not fail
harmlessly there; it empties the file being rewritten. Measured on the shape:
32 bytes → 0.

**But every production entry point was already protected, and saying otherwise
would be the overstatement this file exists to avoid.** `bump-sandbox-version.sh`,
`sync-to-projects.sh` and every migration carry `set -euo pipefail`, so errexit
aborts at the assignment. Verified against the real scripts with a failing
`mktemp` stub rather than argued: the migration exits 1 with the file intact at
36 bytes. The exposure was that this safety belongs to a shell option those files
do not set at the point it matters and cannot see from the call site — which is
exactly F43's finding, arriving from the other direction. The guards make the
safety explicit instead of incidental, and each one now names the file it
refused to touch.

`tests/integration/minimal-conf.sh` is the same story with a smaller blast
radius: no errexit and its stdout IS a config, but its only caller already
checks the status, so what changed is one named line on stderr in place of zero
bytes on stdout.

**A template was teaching the bug**: `bump-sandbox-version.sh`'s comment block
for authoring new migrations showed the unguarded `tmp="$(mktemp)"` idiom. Every
migration written from it inherited the shape. Updated too.

### The original list, for the record — the 15 unguarded assignments, none an oracle:
`bump-sandbox-version.sh:74`, `sandbox-common.sh:537,551`,
`sync-to-projects.sh:81`, `migrations/002:32`, `migrations/003:17`,
`migrations/004:11`, `tests/test-sandbox-schema.sh:184`,
`tests/test-sandbox-env.sh:20,70,118`, `tests/integration/minimal-conf.sh:31`.
Mechanical, and each wants the same one-line guard. Left out of this increment
deliberately rather than forgotten: they are a legibility fix, not a
correctness one, and bundling fifteen product-script edits into a tier change
is how an unrelated regression gets attributed to the wrong commit.

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

## F31 ADDENDUM — ENOSPC is a proven mechanism and an unproven trigger — **OPEN: needs a recurrence**

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

## F32 — three load-sensitive oracles, and the tier reads slowness as coverage — **CAUSE FOUND AND FIXED 2026-08-30, see F64 RESOLUTION** — **DETECTION LANDED 2026-08-21 (see F30), entry still open**

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

### Data point, 2026-08-19 — the same commit, two machines, 86% against 100%

Worth recording because it is the widest spread measured so far on a tree where
every GAP is closed, and because it shows the degradation is not uniform:

| | container (8 CPUs, cgroup quota) | Mac host (`--jobs auto` -> 18) |
|---|---|---|
| TOTAL | `255\|249\|2\|4` | `255\|218\|3\|34` |
| measured | 100% | **86%** |
| wall | 6m33s | 26m41s |

The 30 extra UNPROVEN are concentrated entirely in the two heaviest targets —
`tests/lib-verify-repo.sh` 49/49 -> 29 killed with 20 unproven, and
`tests/integration/mutate.sh` 59/59 -> 52 with 7 — while the six light targets
were fully measured on both. **The four targets the guard-cluster increment
touched had ZERO unproven on both machines**, which is the only reason its nine
kills could be confirmed on macOS at all: a partial reading of those targets
would have been indistinguishable from a coverage regression.

That is the practical shape of this finding. The tier does not degrade evenly;
it degrades where a single oracle is expensive, so whether a given conclusion
survives a loaded run depends on which target it rests on. F38's measured-fraction
line is what makes that visible at all — without it this run reports a plain
PASSED. Note also that `--jobs auto` picked 18 on an 18-core Mac: F38 taught it
to respect a cgroup quota, and with no quota present it takes every core, which
by F38's own table is already past the point where wall-clock stops improving.

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

## F36 — the launcher tier's hand procedure cannot demonstrate a mutation that lives in the image — **CLOSED 2026-08-20**

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
`demonstrate-network-delivery-tiers.sh` are the mechanism; what is missing is a
launcher/packages-tier demonstrator that uses them. Parked rather than done
because the packages tier's cases cost tens of minutes each and budgeting that
run is its own decision.

## F37 — `demonstrate-network-tier.sh` now covers two tiers and its name says one — **FIXED 2026-08-21**

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

**Blast radius re-derived 2026-08-20, and the entry undercounted it.** It names
`tests/falsify/targets.conf`, `AGENTS.md` and the mgd twin. The real set in this
repo is nine files: those two plus `tests/test-mutations.sh:114`, two mutation
patches that name the script in their own headers
(`300-allowlist-not-delivered.patch`, `240-open-keeps-capabilities.patch`), six
self-references inside the script, and three mentions in this backlog —
`targets.conf:120` among them, as a `GREPPED-ONLY` row.

**Held deliberately, and the reason is the one the entry already gives rather
than a preference for leaving it.** This is a HOST-FACING entry point the user
types by hand. Renaming it to `demonstrate-image-tier.sh` today and to
`demonstrate-mutations.sh` after F36 is two renames of the same command; one is
better than two. F37 is therefore sequenced AFTER F36, and that is the whole of
its remaining cost — the defect is real, the fix is mechanical, and the only
open question is which name it should land on.

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

## F42 — the local lint cannot see a script you have just written — **FIXED 2026-08-20**

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

## F43 — a test that sources a product script inherits its `set -e`, and an abort scores as a KILL — **FIXED 2026-08-20**

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
   it.** **FIXED 2026-08-20 — and it turned out to be a regression guard, not a
   bug report.**

   `run.sh` now counts kills whose signal carries no `failline`, warns per
   occurrence naming the mutant, emits `ASSERTLESS|<count>|<killed>` on its own
   line, and accepts `--max-assertless N`. CI passes 0; Phase 6 prints the
   number on the host.

   **The measurement that decided the shape: the count is 0 today, in both
   repos — all 262 kills are `exit+failline`.** So there was nothing to report.
   That is exactly the argument for building it now rather than later: this is
   the state the survivor ledger's own header warns about — *"the state in which
   it is easiest to let a new GAP in unnoticed: with nothing left to look at,
   nobody looks."* A number that reads 0 forever is cheap; the same number
   discovered at 3 in six months, by hand, on one mutant, is how F35, F30 and
   F43 were each found.

   Three design points worth keeping:

   - **The verdict stays KILLED.** The oracle genuinely distinguished the
     mutant; demoting it to UNPROVEN would be a second guess dressed as a
     measurement. What changed is that the run says how much of its coverage
     arrived that way.
   - **On its own line, not a tenth `TOTAL` field.** The ratchet,
     `check-ledger.sh` and `verify-on-host.sh` all parse `TOTAL` positionally,
     and a number nobody can read is the state this counter exists to end.
   - **The bound is opt-in, but for the MIRROR of `--max-unproven-pct`'s
     reason.** An assertless kill is a property of the oracle's code, not of
     the machine — a timeout, a signal death and a collapsed scaffold are all
     UNPROVEN *before* this counter sees them — so unlike the unproven fraction
     it IS satisfiable everywhere at once, and CI holds it at 0. It stays
     opt-in because a test whose contract genuinely is its exit status would be
     a legitimate non-zero, and discovering that on somebody's laptop mid-task
     is not how it should be raised.

   The fixture is the historical case, not a contrivance: an oracle green on
   the pristine tree that exits 1 in silence when mutated — which is precisely
   what errexit inherited from a sourced product script did to two of
   `shared-files.sh`'s mutants for weeks. Demonstrated failing three ways
   (never counting, counting the inverse, and a bound that never fires), each
   on a named assertion, plus a control proving the bound is satisfiable by an
   honest oracle rather than failing every run.
2. **`test-shared-files-parity.sh` should not silently run under errexit.**
   **FIXED 2026-08-20, and measured first as this item demanded.** `set +e`
   immediately after the source, with a comment saying why. Three measurements,
   in the order they were taken:

   | | before | after |
   |---|---|---|
   | `$-` at end of file | `ehuB` | `huB` |
   | the file's own output | — | **byte-identical** |
   | `shared-files.sh` mutants | 5 KILLED, **2 of them bare `exit`** | 5 KILLED, **all 5 `exit+failline`** |

   The third row is the one worth reading. The two mutants this entry names as
   being "killed" by an oracle that never asserted anything are now killed by an
   assertion — F15's guard block, which sits above the source line and was
   already doing the real work. Turning errexit off cost nothing and converted
   two fake kills into real ones, which is this entry's own thesis measured
   rather than argued.
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

## F44 — Phase 5's schema gate compared a commit to itself and reported OK — **FIXED 2026-08-19**

**Found by reading the code to answer a question about it, and confirmed on the
host the same evening.** `verify-on-host.sh`'s Phase 5 resolves a `BASE_REF` for
`check-sandbox-version.sh`, guarded by a twenty-line comment explaining that the
script's own default (`BASE_REF=HEAD`) is a silent no-op once a change is
committed. The guard it built checks that the resolved ref is **non-empty**:

```bash
gate_base_ref="$(git merge-base HEAD origin/main)"          # empty?
[[ -n "$gate_base_ref" ]] || gate_base_ref="$(git rev-parse HEAD^)"
[[ -n "$gate_base_ref" ]] || phase_fail 5 "no usable BASE_REF …"
```

On `main` — the most ordinary place to run Phase 5, right after a merge —
`origin/main` **is** HEAD, so `merge-base` returns HEAD. Non-empty, so both
guards pass, and `BASE_REF=HEAD` is exactly the default the comment warns about.
The gate then diffs HEAD's `sandbox.conf` against a working tree identical to it,
finds nothing removed, and prints OK.

Observed live, not inferred, on a host run of `PHASES="5"`:

```
schema gate diffing sandbox.conf against aeb1421c1cc89e625435a294f4c71ff468ee5c11
check-sandbox-version: OK (no key removed/renamed; additions are always allowed).
```

`aeb1421` was HEAD. CI is unaffected: `hermetic-checks.yml` always exports a real
PR base SHA.

### The test agreed with the defect

`tests/test-verify-exit-code.sh` had two blocks here. One asserted the loud
failure when NO base resolves — correct, and still passes. The other said:

> mk_repo's DEFAULT repo (add_origin=1, the origin/main ref stamped at HEAD)
> **DOES have a usable base**, so the gate still genuinely runs

It does not have a usable base; `origin/main == HEAD` is the defect. The
assertion under that sentence only grepped the witness log for `STUB:` — proof
the gate **ran**, which was never in doubt. Running and checking are different
things, and nothing could see the difference because nothing recorded the one
input that decides it.

### Fix

1. **`verify-on-host.sh`** — a resolved base equal to HEAD is treated as
   unusable, exactly like an empty one, and falls through to `HEAD^`. That is the
   right answer rather than an error: on main, "this change" is the last commit,
   and for a merge commit `HEAD^` is the previous main — the same push semantics
   CI uses when there is no PR base. If `HEAD^` also fails to resolve, the
   existing `phase_fail` fires with a message that now names the real condition.
2. **`tests/lib-verify-repo.sh`** — every `repo-script` stub writes a second
   witness line, `STUB-BASEREF:<name> <ref>`, recording the `BASE_REF` it was
   handed. The existing anchored `^STUB:<name>$` regex is untouched. Silent when
   `BASE_REF` is unset, so no other stub is affected.
3. **`mk_repo`** — the `add_origin=1` repo gets a **second commit** before the
   ref is stamped, so it models a normal checkout on main: `origin/main == HEAD`
   *and* `HEAD^` resolves. With only a root commit, "origin/main is HEAD" and "no
   base at all" are indistinguishable, and the fixture could not tell a gate that
   falls back to `HEAD^` from one that hands the gate HEAD. `add_origin=0` keeps
   its single commit — that IS the no-base case.
4. Four assertions replace the one that agreed with the defect: the fixture's own
   premise (HEAD and HEAD^ exist and differ, so the rest cannot pass vacuously),
   that a `BASE_REF` was recorded at all, that it is not HEAD, and that it is
   `HEAD^`.

Demonstrated by reverting only the resolution logic to its pre-fix form and
leaving the new assertions in place:

```
FAIL: the schema gate was handed BASE_REF=HEAD (da95516d…) — it compared HEAD's
      sandbox.conf against an identical working tree and reported OK, verifying nothing
FAIL: the schema gate fell back to HEAD^ when origin/main is HEAD —
      want '25a4f0d5…', got 'da95516d…'
```

### Why it is worth an entry rather than a one-line fix

This is the same shape as F43, four hours apart, and the shape the whole file
exists for: **a check that runs is not a check that checked.** F43's oracle
exited non-zero without asserting; this gate exited zero without comparing. Both
were invisible because the observable everyone looked at — did it run, what was
its status — is one level away from the thing that decides whether it means
anything. The generalisable move is the one used here: make the deciding INPUT
observable to the test, not just the outcome.

Worth noting that the emptiness guard was not careless. It was written
deliberately, with the failure mode named in the comment above it, by someone
looking straight at the problem — and it still missed the case where the wrong
answer is non-empty. Reading the warning does not transfer it to the code.

## F45 — `install_one`'s release path accepted an empty `repo=` and retried a doubled slash — **FIXED 2026-08-20**

Found while closing F22, by asking why three `tools-lib.sh` mutants were scored
`timeout+failline` rather than plainly KILLED — and the answer was not the one
the shape suggested.

`install-tools.sh`'s `install_one()` read `repo="$TOOL_repo"` and, on the
release path, handed it straight to `api_get`. With an empty value that is
`https://api.github.com/repos//releases/latest`, and `api_get` retries three
times with two `sleep 5`s between. So a malformed descriptor cost ten seconds
and then reported a doubled slash instead of the field that was missing.
`install_repo_file()` has refused this exact condition since it was written
(`repo=` or `repo_path=` empty → warn and skip); the release path never did, and
`install=url` genuinely has no repo, which is why the guard belongs after both
dispatches rather than beside the other descriptor reads.

**The tier is what surfaced it, and only via a second-order symptom.** Any
mutation that empties a descriptor makes every `install_one` in
`test-tools-d.sh` pay the retry, and the file then takes **141 s** — well past
run.sh's 60 s per-mutant clock. Three `tools-lib.sh:70` mutants were therefore
recorded `timeout+failline`: kills that survived scoring only because the
`FAIL:` line landed before the clock, not because the oracle finished. With the
guard the same three are `exit+failline` at ~330 ms, and the target's whole run
drops from 207 s to 28 s.

**Worth keeping: "the oracle timed out" is not one diagnosis.** It was read
first as a hang — the same word F22's group uses — and it is not one. The
damaged run terminates; it terminates in 141 seconds, because a `sleep 5` in the
product's retry loop is multiplied by every call the damage breaks. A hang wants
a bound; this wanted a guard at the source. Measuring how long it actually takes
before assuming which one it is cost one background run and changed the fix
entirely.

The assertion is the curl log rather than the elapsed time: a release-path
descriptor with no `repo=` must skip before any fetch, which stays true however
fast the machine is. Demonstrated failing by negating the guard — the FAIL line
carries `API attempt 1 failed, retrying in 5s...` as its evidence.

## F46 — `mgd-ai-containers` set `enospc_seen` and never read it, so a disk-full run scored as a KILL — **FIXED 2026-08-20**

Found while porting F22, by the port refusing to apply: the upstream end-of-file
block this increment was refactoring into a `verdict()` function **does not
exist in mgd-ai-containers**.

`tests/test-tools-d.sh` carries the whole APFS disk-full apparatus in both
repos — `enospc_seen`, `scaffold_can_write`, the probe inside `fail()` that
samples the filesystem AT THE MOMENT OF EACH FAILURE rather than at the end.
Upstream then reads it once at the bottom and prints `SCAFFOLD-FAILED:` instead
of a verdict when the failures were measured on a full disk. mgd received the
machinery and not the reader: `enospc_seen` was assigned, tested inside `fail()`
to gate one capture, and never consulted again.

**Why that matters more than it looks.** `SCAFFOLD-FAILED:` is a channel, not a
message — `run.sh` reads it as scaffolding and refuses to score the mutant. A
run that ends `N FAILED` is a non-zero exit with `FAIL:` lines, which is
`exit+failline`: **a kill.** So in mgd a full disk during a tier run was not
merely mis-reported, it was recorded as coverage. Upstream's own measurement of
this exact scenario is in the file: 40 onsets swept across the run, 6 of 18
scored KILLED before the guards, 3 of 40 after the per-step guards, 0 of 40 once
the probe moved into `fail()`. mgd had the probe and not the verdict, so it sat
somewhere before that last row.

Both repos now share one `verdict()` function, called from the normal end and
from F22's premise gate. Having two exits is what forced the extraction; the
divergence is what made extracting it worth doing in both.

**The generalisable part: a port that carries the mechanism can drop the
consumer, and nothing about the result looks unfinished.** Every line mgd had
was correct, referenced a real variable, and ran. What was missing was the one
place the variable is finally read — invisible to a reader of either file alone,
and visible immediately to anyone diffing them for a third reason.


## F47 — Phase 6 deletes the run log it just told you to grep — **FIXED 2026-08-20, in the increment that found it**

**Found by the 2026-08-20 host run, which is also the run that lost the evidence.**

`PHASES="5 6" bash ./verify-on-host.sh` on macOS reported:

```
ASSERTLESS|2|227
NOTE: 2 kill(s) arrived with NO assertion — the oracle exited non-zero
      without printing a FAIL: line. CI gates this at 0, so a non-zero here
      is platform-specific and worth chasing. Grep the log for
      'KILLED WITH NO ASSERTION ATTACHED'.
```

That note is correct and it is the whole point of F43's counter: CI holds
`--max-assertless 0`, so a non-zero reading on a host is a property of an
oracle that only shows on that platform. It is the first time the counter has
ever fired.

**The evidence for it no longer exists.** Phase 6 writes the corpus run to
`fl_run="$(mktemp)"` (`verify-on-host.sh:333`), captures both channels into it
(`> "$fl_run" 2>&1`, line 343), and ends the phase with an unconditional
`rm -f "$fl_run"` (line 410). The per-occurrence warnings — `fr_warn "KILLED
WITH NO ASSERTION ATTACHED (signal=…): <identity>"`, `run.sh:601`, the only
place the two mutants are named — and the `MUTANT|<verdict>|<identity>|…`
records for all 264 exist nowhere else. The path is never printed either, so
even before the delete the reader could not have known which file to open.

So the instruction names a file the reader cannot identify and cannot open.
Two mutants on macOS are killed by an oracle that reaches no assertion, and
which two is currently unknowable without a second host run.

**The same delete lands on the failure path.** `phase_fail` records and
returns — it does not exit — so line 410 runs after a failed corpus too, having
shown only `tail -6` of the notes. The run that most needs its log is the one
that keeps it least.

**Scope.** The unproven note ("raise --timeout or reduce load") points at the
same vanished log; its identities survived this run only because
`check-ledger.sh` happens to print them on its own stderr. The two files are
byte-identical across the repos, so both carry it.

**Fix.** Retain the log whenever the phase says something that points at it —
the assertless note, the unproven note, a rejected ledger, a corpus that did not
complete — and print its path at the point of the advice. Delete it only on a
run with nothing to chase, so a clean verification still leaves no litter.

**The generalisable part: an instruction is only as real as the thing it names.**
This note passed every review it has had, including the one that wrote it, because
it reads as correct — and it is correct, right up to the point where a reader
tries to follow it. Nothing in the suite could have caught that: the assertion
would have to be that the file survives the phase, and no test ran Phase 6's
success path at all. `test-verify-exit-code.sh` covered the failure path only.


## F48 — Phase 6's advice names two knobs the script hardcodes — **FIXED 2026-08-20, in the increment that found it**

F47's sibling, in the same twenty lines and of the same species: an instruction
the reader cannot act on.

When more than a tenth of the corpus goes unmeasured, Phase 6 printed:

```
NOTE: N mutant(s) timed out and were not measured — raise --timeout or
      reduce load for a fuller measurement.
```

Both numbers were written into the one invocation at `verify-on-host.sh:343`:

```bash
bash "$TESTS_DIR/falsify/run.sh" --jobs auto --timeout 120 > "$fl_run" 2>&1
```

No variable, no flag and no argument moved either. Following the advice meant
editing the script in the middle of a verification — on a checkout that may be
shared with an agent — or running `tests/falsify/run.sh` by hand and skipping
the ratchet Phase 6 exists to pair with it. The corpus run and the ledger score
are deliberately **one operation** (see AGENTS.md), so "just run the corpus
yourself" is not the same check.

**Measured.** The 2026-08-20 macOS run resolved `--jobs auto` to 18 on an
18-CPU host and lost 71 mutants to the 120-second clock: 34 UNPROVEN, 14% of
the corpus unresolved, `verdicts obtained for 230/264 mutants (87%)`. The note
fired correctly and named the right lever. The lever did not exist.

**Phase 4 already had the pattern.** `IT_EXTRA_ARGS` is forwarded verbatim to
that phase's runner, documented as "the hook for narrowing that when iterating".
Phase 6 was written without one.

**Fixed** with `FALSIFY_JOBS` and `FALSIFY_TIMEOUT`, defaulting to `auto` and
`120` — the values that were hardcoded, so an unset environment runs exactly
what it always ran. The banner prints the resolved pair, and the note names the
variables rather than the flags they feed.

**The generalisable part: advice is a feature, and it needs the review code
gets.** F47 and F48 are one defect wearing two hats — a note telling the reader
to open a file that was deleted, and a note telling the reader to turn a knob
that was never fitted. Both read as complete. Both were written by someone who
knew exactly what they meant. Neither was followed by anybody until a host run
made it necessary, and the first attempt to follow either one failed.


## F49 — the verify harness read the operator's shell, and F48 had just told operators to fill it — **FIXED 2026-08-20, one hour after the defect that created it**

F48 gave Phase 6 two environment knobs and documented them in the script's own
header: *"FALSIFY_TIMEOUT=300 FALSIFY_JOBS=6 PHASES=6 bash ./verify-on-host.sh"*.
The very next host run was made with `FALSIFY_TIMEOUT=600 FALSIFY_JOBS=8`,
exactly as instructed, and Phase 6 came back:

```
ERROR: oracle 'test-lib-verify-repo.sh,test-verify-exit-code.sh,test-layer-containment.sh'
is not green on the PRISTINE tree (rc=1, signal=exit+failline) — every mutant of
tests/lib-verify-repo.sh would be reported KILLED. Skipping tests/lib-verify-repo.sh.
** PHASE 6 FAILED: the falsify corpus did not complete — the ledger was not scored
```

`tests/lib-verify-repo.sh`'s `run_verify()` ran `verify-on-host.sh` with the
caller's environment intact, and F48's new test asserted:

```bash
rc="$(run_verify "$r" 6)"
case "$f48_argv" in (*"--jobs auto"*"--timeout 120"*) pass "…an unset environment…"
```

"An unset environment" is a property of **whoever ran the suite**, not of the
script. With the knobs exported the child got `--jobs 8 --timeout 600` and the
assertion failed — correctly, at what it was actually measuring.

**Why it could only fail on a host.** CI exports neither variable; the dev
container exports neither. The one layer where a developer plausibly has them
set is the one where the header tells them to set them. So the defect was
invisible to every gate and visible immediately to the first human who followed
the documentation.

**The blast radius was not one assertion.** That file is one of three oracles
for `tests/lib-verify-repo.sh`, run as a single invocation. A non-green pristine
oracle makes the tier **skip the whole target** — correctly, since every mutant
would otherwise report KILLED for the wrong reason — so one environment-sensitive
assertion cost all 55 of that target's mutants and aborted the corpus run, which
then scored no ledger at all. A test that reads the environment does not fail
alone.

**Fixed** by moving the environment into the harness: `run_verify()` removes
`FALSIFY_JOBS`, `FALSIFY_TIMEOUT` and `IT_EXTRA_ARGS` from the child's
environment and takes optional trailing `VAR=VALUE` arguments for a test that
wants one. The default case now exports `FALSIFY_JOBS=99 FALSIFY_TIMEOUT=99` **on
purpose** and asserts the child still sees `auto`/`120` — the only form of that
assertion that measures the script rather than the shell, and one that cannot
pass vacuously. A further case exports 99 *and* passes 4/600, pinning `env`'s
operands-after-options ordering on whichever platform runs it instead of assuming
GNU and BSD agree about it.

**The generalisable part: a documented knob is an input to every test that runs
the thing reading it.** F48 was correct, tested, reviewed and green in three
places. It created this defect in the same commit, because adding an environment
variable widens the input space of every existing assertion at once, and nothing
re-examines those assertions when it happens. The question F48 should have been
asked — and that any future knob must be — is *"which existing test now depends
on this being unset?"*


## F50 — a stale watchdog forged a timeout flag and truncated other workers' oracles — **FIXED 2026-08-20**

**Proven by the host run of 2026-08-20, `--jobs 8 --timeout 600`.** Every mutant
carrying a `timeout` signal, with its own measured elapsed:

```
59893ms KILLED    timeout+exit+failline  tests/integration/mutate.sh:return-flip:7efad11b
 6672ms KILLED    timeout+exit+failline  tests/lib-layer-checks.sh:logic-flip:62fc80a5
39867ms KILLED    timeout+exit+failline  tests/lib-verify-repo.sh:cond-negate:6c630c05
12396ms UNPROVEN  timeout                tests/bash-dialect-lint.sh:cond-negate:f204b4ce
12780ms UNPROVEN  timeout                tests/bash-dialect-lint.sh:logic-flip:b3f102dc
```

Not one ran a tenth of its 600-second clock. **All five timeouts were false.**

### The flag had no owner

`fr_run_mutant` sets `out="$FR_OUT/w$slot.log"` — one file per **worker slot**,
reused by every mutant that ever runs in that slot across every target — and
`falsify_run_oracle` derived its flag as `"$out.timedout"` and armed it with
`: > "$flag"`, an **empty file**. So "the flag exists" and "this invocation armed
the flag" were the same expression, and a flag written by any watchdog, at any
time, read as this run's timeout.

### CORRECTION: they were not laundered survivors

This entry first read those two bare-`timeout` records as **survivors** — no
`exit`, no `failline` means an oracle that ran to completion and passed — and
predicted that fixing the flag would surface them as `SURVIVED`, failing
`check-ledger`'s check B and exposing a macOS-only coverage gap in the dialect
linter.

**That prediction was wrong, and was measured wrong.** Once the flag carried an
owner, the same target on the same host reported:

```
TARGET|tests/bash-dialect-lint.sh|test-bash-dialect-lint.sh|27|27|0|0|0|176471
```

27 mutants, **27 KILLED**, zero survivors, zero unproven, zero timeouts — with
`cond-negate:f204b4ce` killed `exit+failline` at 27.0s and `logic-flip:b3f102dc`
at 10.8s. There is no coverage gap. The ledger owes nothing.

### What actually happened, and why it is worse than a mislabel

A stale watchdog did not merely write a flag. It went on to run

```bash
kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
sleep 1
kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
```

against a pid recorded up to `<timeout>` seconds earlier. On a busy macOS host
that pid — and its process-group id — can be **recycled** in that window, so the
kill lands on **another worker's live oracle**. Both `bash-dialect-lint.sh`
records are consistent with exactly that: reliable kills, cut short mid-run at
~12s, producing neither a killing exit nor a FAIL: line, and then labelled
UNPROVEN by the forged flag.

So the interference corrupts the **run**, not just its label — and that means it
is **not conservative in either direction**. These two happened to lose a kill.
A suite truncated *after* some unrelated test has already printed a FAIL: line
reads as `exit+failline`, which is a **KILL** — and a false kill is precisely how
a survivor disappears. The dangerous direction was always available; this run
simply did not take it.

### Fixed in three layers, because they fail differently

1. **The watchdog stops existing when its subject does.** `falsify_watch_until`
   polls the oracle's liveness once a second instead of `sleep "$limit"`, so a
   watchdog is never stale for more than a second — a window in which a pid
   cannot be recycled into another worker's oracle. Polling is the right shape
   *here*, unlike `p_timeout` in `tests/portability.sh` (F22), which is itself a
   mutation target where a negated liveness probe has to stay killable;
   `tests/falsify/run.sh` is the measuring instrument and is never mutated.
2. **The flag carries the token of the invocation that armed it** —
   `$BASHPID.<microseconds>`, `$BASHPID` and never `$$`, which inside a forked
   worker is still the top-level shell's pid and would be shared by every slot.
   `falsify_flag_is_mine` is a separate predicate so it can be asserted directly,
   and an **empty** flag — the form the old code wrote — is deliberately not
   mine: a flag with no owner is what cannot be attributed.
3. **A foreign flag is reported, not ignored:**
   `NOTE|foreign-timeout-flag|<identity>|slot N held a timeout flag armed by
   <token>`, with a `FOREIGN TIMEOUT FLAG` warning naming the mutant and the
   slot. If anything still gets through, it is a named event rather than a silent
   reclassification.

### Guards

`tests/test-falsify-run.sh` asserts all four cases of the ownership predicate —
missing, empty, another invocation's, and my own — with the positive case present
so an ownership check that merely disabled timeouts fails too. For the wait it
asserts both directions, and the second is the one that bites: a subject
outliving the clock must report the clock expiring, **and a subject that exits
first must end the wait immediately**. Demonstrated against a deliberately blind
`sleep "$secs"` inside the function, which passes the first and fails the second:

```
PASS:   … a subject that outlives the clock reports the clock expiring (3s)
FAIL:   … a subject that exits first ends the wait immediately — rc=0 after 20s
        of a 20s clock, so the watchdog outlives its oracle and still holds a
        pid that may be recycled
```

Case 11's genuine hang still reports UNPROVEN, so the timeout path is intact.

### Never reproduced on Linux

`--jobs 16 --timeout 900` and `--jobs 16 --timeout 20` — a clock above the
slowest real oracle in the corpus (10.6s) and well inside the 68-second run, so
any watchdog outliving its kill would fire during a later mutant — both give
`TOTAL|9|264|262|2|0|0|0` with zero timeouts.

### The generalisable part

Two of them, and the second was the expensive one.

**A shared mutable path is not a signal until it says who wrote it.** The flag
was correct while one invocation at a time could reach it, and became a lie the
moment a slot outlived a watchdog.

**And a wrong diagnosis survives being carefully reasoned.** "Bare `timeout`
means the oracle passed, therefore a survivor" is sound as far as it goes, and it
was still wrong, because it assumed the oracle had been left alone to finish.
The reading that would have caught it — that the same mechanism which forges a
flag also fires a kill — was available in the six lines directly beneath the
write. It took a measurement, not more thought, to find that out.


## F51 — `ASSERTLESS` was claimed machine-independent on an argument, not a measurement — **RESOLVED 2026-08-20**

`run.sh`'s header states the counter "is a property of the oracle's CODE, not of
the machine … so it is satisfiable everywhere at once and CI passes 0", and
`hermetic-checks.yml` holds `--max-assertless 0` on that basis. The argument is
that every machine-dependent channel — timeout, signal death, collapsed scaffold
— becomes UNPROVEN before it can reach the counter.

The claim was worth challenging on two grounds. It rested on a timeout
classifier that F50 showed could fire without a timeout; and the counter had
read **2** on one macOS run and **0** on every other, which is the shape of a
number that moves with the machine.

**Measured, and the claim holds.** `--jobs 32 --timeout 5` in the dev container —
four workers per CPU against a five-second clock — induced **58 timeouts** across
the 264-mutant corpus:

```
TOTAL|9|264|233|2|29|58|11|46952
ASSERTLESS|0|233

    204 KILLED    exit+failline
     29 KILLED    timeout+failline
     29 UNPROVEN  timeout
      2 SURVIVED  none
```

22% of the corpus hit the clock. Every one landed in the timeout channel and was
routed correctly — no failline → UNPROVEN, failline → still a kill — and the
assertless counter stayed at **zero**. That is the argument's own prediction,
under the load that would break it if it were wrong.

**And the counter-example is explained.** The single reading of 2 came from the
2026-08-20 host run that F50 later showed was riddled with forged timeout flags,
where a stale watchdog was issuing kills against recycled pids and truncating
**other workers' oracles mid-run**. An oracle cut short exits non-zero having
printed no FAIL: line — which is precisely an assertless kill. Since F50 was
fixed the counter reads 0 on both platforms, including the host run that first
produced the 2.

The claim now carries this measurement in `run.sh` beside the check, so the next
person to doubt it finds the evidence rather than the argument.

**The caveat is closed too.** The same experiment was then run on macOS:

```
TOTAL|9|106|43|0|63|103|59|195540
ASSERTLESS|0|43
```

103 induced timeouts, and the counter still **zero**. The claim now holds on both
platforms under load that makes the machine-dependent channel fire constantly,
which is the condition that would expose it if it were machine-dependent. (That
run also surfaced something unrelated and new — 158 of 264 mutants produced no
verdict at all on macOS where Linux produced 264 — which is F52, not this.)

**The generalisable part: an argument that predicts an observation should be made
to produce it.** This one was correct, and it had been sitting in a comment as
reasoning for as long as the counter existed — believed because it was
persuasive, at the head of a CI gate that fails the build. It cost one command to
turn it into evidence.


## F52 — under a clock tight enough to fire the watchdog, macOS loses more than half its workers — **RESOLVED 2026-08-20: THE PREMISE WAS WRONG, AND IT WAS NEVER MEASURED**

> **Read the resolution at the bottom of this entry before the entry.** The
> mutants were not lost. They were never attempted, for a reason the run states
> in four named ERROR lines. What follows is the original filing, kept verbatim
> because how it went wrong is the useful part.

**ORIGINALLY FILED AS OPEN.** Loud, not silent — the run fails with a named error and a non-zero exit
— and only reachable under a clock tight enough that mutants time out en masse.
Filed because it is the same family as F50 (a mutant leaving the measured set)
and because the platform asymmetry is total.

Same command, same commit, same flags, two platforms:

| | Linux (dev container, 8 CPUs) | macOS (18 CPUs) |
|---|---|---|
| `--jobs 32 --timeout 5` | `TOTAL\|9\|264\|233\|2\|29\|58\|11` | `TOTAL\|9\|106\|43\|0\|63\|103\|59` |
| mutants that produced a verdict | **264 of 264** | **106 of 264** |
| timeouts | 58 | 103 |

`TOTAL`'s third field is `FR_T_KILLED + FR_T_SURVIVED + FR_T_UNPROVEN` — mutants
that produced a verdict, not the corpus size. So on macOS **158 mutants produced
none at all**, against zero on Linux.

`fr_reap` names the condition exactly:

```bash
if [[ ! -s "$res" ]]; then
  fr_err "a mutant worker produced no verdict at all (slot $slot) — not counted as a kill"
  FR_BROKEN=$(( FR_BROKEN + 1 ))
```

and the run then ends `FR_BROKEN mutant(s) produced no verdict — they are NOT
counted as kills` with `rc=1`. The worker never reached its
`printf 'MUTANT|…' > "$res"`.

**Why it is not urgent.** It needs the watchdog to actually fire, and at the
clocks anyone really uses it does not: the last full host run at `--timeout 600`
had **zero** timeouts across all 264 mutants. And when it does happen the tier
refuses the run rather than reporting a smaller corpus as a pass — the opposite
of F50, which was silent.

**Why it is still worth chasing.** The mutants that vanish are not UNPROVEN, not
survivors, and owed nothing by the ledger; they are simply absent. Today that is
caught by `FR_BROKEN`'s gate. A future change that made the gate advisory, or a
partial failure small enough to look like noise, would put it back in F50's
territory.

**What is NOT yet established** — and this entry deliberately stops short of the
theory, because two confident mechanisms in this chain have already been wrong.
The suspicion is that with a 5-second clock nearly every mutant times out, so the
watchdog runs `kill -TERM -"$pid"` and then `kill -KILL -"$pid"` on the oracle's
process group, and on macOS that is taking the worker with it. Not demonstrated.
`set -m`'s behaviour in a non-interactive forked worker without a controlling
terminal is the obvious thing to measure first, and it differs between the two
platforms in exactly the way that would explain a total asymmetry.

**Reproduction:** `bash tests/falsify/run.sh --jobs 32 --timeout 5` on macOS.
Two minutes. Compare `TOTAL`'s third field against 264, and read stderr rather
than filtering it — the ERROR lines are the finding.

### 2026-08-20 (morning) — the pool now names the cause

`fr_harvest` reported the absence and nothing else: *a mutant worker produced no
verdict at all (slot N)*. That sentence cannot tell a worker that gave up from
one something else killed, which is exactly the distinction this entry needed
and could not make.

**The pool HELD the missing fact and threw it away.** `wait -n` returns the
finished child's status; `fr_wait_for_slot` discarded it, then went looking for
which worker had finished with `kill -0` — a question about whether *some*
process holds that pid, not about whether it is still my worker. Both halves
mattered: the discarded status is the only evidence of cause, and on a host that
recycles pids quickly the `kill -0` answer can be about somebody else's process.

Fixed with `wait -n -p` (bash 5.0; `bash-floor.sh` declares 5.1), which names the
reaped pid and keeps its status. `fr_exit_cause` turns that status into a clause,
so the same line now reads:

```
ERROR: a mutant worker produced no verdict at all (slot 7; it was KILLED BY SIGKILL) — not counted as a kill
```

Ten assertions in `tests/test-falsify-run.sh` §11d — six on the clause, four on
the wiring through the real pool — and each guard demonstrated failing:

| damage | assertions that flip |
|---|---|
| signal naming removed from `fr_exit_cause` | 3, incl. the wiring one (`it exited 137`) |
| `st > 128` → `st >= 128` | 1 — status 128 was reported as `SIGEXIT` |
| the pool stops recording the status it was handed | 1 — only the wiring one (`exit status not captured`) |

Corpus unchanged on Linux after the change: `TOTAL|9|264|262|2|0|0|0`,
`ASSERTLESS|0|262`, ledger `OK: 0 problem(s)`, suite 56/56.

**THIS IS INSTRUMENTATION, NOT A ROOT CAUSE.** What it buys is that the next
macOS run under a tight clock says whether those 158 workers were killed, and by
what, instead of only that they were gone. It did exactly that — see the
resolution below, where the answer turned out to be that no worker was killed at
all.

**A repo-free probe exists, and it does NOT reproduce on Linux.** 32 workers
running the exact shape of `falsify_run_oracle` — `set -m`, fork oracle with
children, watchdog, `kill -TERM -PID`, `sleep 1`, `kill -KILL -PID` — against a
5-second clock and a 30-second oracle, so the watchdog always fires:

| variant | verdicts | worker exit statuses |
|---|---|---|
| A — shipped: `set -m` + group kill | 32/32 | 32×0 |
| B — no `set -m`, group kill | 32/32 | 32×0 |
| C — `set -m`, direct kill only | 32/32 | 32×0 |

and `set -m` in a forked non-interactive worker DOES give the background job its
own process group here (job pid 3178657, pgid 3178657, against the worker's own
pgid 3178645), so variant A really is the shipped code path. On Linux the
pattern loses nothing with no test suite involved. **The same probe on macOS is
the next measurement**, and if it loses workers there, the mechanism is in these
~40 lines rather than anywhere in the tier.

### 2026-08-20 (evening) — RESOLVED. Nothing was losing workers.

The macOS repro was run again with the morning's instrumentation in place, and
the answer is that **the 158 mutants were never attempted.** Four of the nine
targets were skipped whole, each with a named error:

```
ERROR: oracle 'test-mutations.sh' is not green on the PRISTINE tree (rc=143, signal=timeout) — every mutant of tests/integration/mutate.sh would be reported KILLED. Skipping tests/integration/mutate.sh.
ERROR: oracle 'test-lib-verify-repo.sh,test-verify-exit-code.sh,test-layer-containment.sh' … (rc=143, signal=timeout) … Skipping tests/lib-verify-repo.sh.
ERROR: oracle 'test-bash-dialect-lint.sh' … (rc=143, signal=timeout) … Skipping tests/bash-dialect-lint.sh.
ERROR: oracle 'test-tools-d.sh' … (rc=143, signal=timeout+failline) … Skipping tools-lib.sh.
```

59 + 55 + 27 + 17 = **158.** Exactly the shortfall this entry was filed for.

`rc=143` is 128+15 — SIGTERM, the per-mutant watchdog killing the **pristine**
baseline. At a 5-second clock the UNDAMAGED suite does not finish on macOS: the
same run measured `bash-floor.sh`'s oracle at 8.5s, `tests/portability.sh`'s at
10.2s and `shared-files.sh`'s at 9.1s. So the tier refused to score those four
targets, which is what `run.sh` is supposed to do — an oracle that is not green
on the unmutated tree would report every mutant KILLED. It prints one ERROR per
target, dumps the baseline tail, and `run.sh:992` sets `rc=1`.

**And `FR_BROKEN` never fired.** Not one `produced no verdict at all` line in the
whole run. The condition this entry named as its mechanism did not occur.

**How it went wrong, because that is the reusable part.** The shortfall was real
and the subtraction was right; everything after it was inference. `fr_reap` was
read, its error path quoted, and `264 − 106 = 158` was attributed to it — from
the source, not from the output. The output that would have refuted it (four
ERROR lines naming four skipped targets, present in the very run being quoted)
was not reconciled against the total. **Three mechanisms in this chain have now
been asserted confidently and been wrong: F50's twice, and this one.** The rule
that keeps surviving contact: a count that dropped is a measurement; WHY it
dropped is not, until an output line says so.

**What it cost, and what it bought.** Cost: one entry filed on a mechanism that
did not exist. Bought: the morning's `fr_exit_cause` instrumentation, which is
correct and now proves its own absence on every run — a `TOTAL` short of the
corpus with zero broken workers is exactly the fingerprint of a skipped target
rather than a lost one — plus two genuine findings the same run surfaced, F53
and F54 below.

**The residual question, deliberately not folded back in here:** at
`--jobs 32 --timeout 5` the tier measures 106 of 264 mutants on macOS and 264 of
264 on Linux. That asymmetry is real and it is just slowness — an 18-CPU machine
running 32 workers, against a container running 8. It is not a defect; it is what
`--max-unproven-pct` exists to bound. Nothing to fix.

---

## F53 — a watchdog from another invocation killed a live oracle, and the mechanism is not established — **RESOLVED 2026-08-20: THERE WAS NO OTHER INVOCATION**

> **Read the resolution at the bottom first.** The oracle really was killed and
> the measurement really was lost, but not by anyone else: a worker mistook its
> OWN flag, because the write it was racing was not atomic. The original filing
> is kept verbatim below — it deliberately refused to guess a mechanism, and the
> instrumentation it shipped instead is what produced the answer in one run.

**ORIGINALLY FILED AS OPEN.** Observed twice in one macOS run, 2026-08-20,
`bash tests/falsify/run.sh --jobs 32 --timeout 5`. Two mutants lost their verdict
to a signal from something that was not their own watchdog:

```
MUTANT|UNPROVEN|tests/lib-layer-checks.sh:cond-negate:27da7c0e…|test-layer-checks-parser.sh|1|40|signal|5045|
falsify: ORACLE KILLED BY A SIGNAL (UNPROVEN — nothing was observed asserting)
NOTE|foreign-timeout-flag|…|slot 0 held a timeout flag armed by 50776.1787249974304247, not by this run

MUTANT|UNPROVEN|tests/integration/docker-shim.sh:cond-negate:21828b2b…|test-integration-shim.sh|1|47|signal|5175|
falsify: ORACLE KILLED BY A SIGNAL (UNPROVEN — nothing was observed asserting)
NOTE|foreign-timeout-flag|…|slot 15 held a timeout flag armed by 55974.1787250031250895, not by this run
```

Both are `seq 1` — the first mutant dispatched to that slot — and both carry
`signal` with no `timeout`, meaning this invocation's own clock never fired: the
oracle was killed by somebody else. This is F50's leak, still live. F50's fix
made it **visible** (the flag now carries an owner, so it is a named NOTE instead
of a silently mislabelled timeout) and bounded the FIRST kill's staleness to
about a second. It did not stop the kill.

**THE MECHANISM IS NOT ESTABLISHED, AND THIS ENTRY WILL NOT GUESS AT IT.**
`falsify_run_oracle` does `wait "$dog"` before it returns, so on the face of it a
watchdog cannot outlive its own invocation and reach the next one on that slot.
Three explanations were constructed and each was refuted by the code:

* *the baseline's watchdog leaked* — no: the baseline's flag path is
  `baseline.log.timedout`, and a slot's is `w<slot>.log.timedout`.
* *two invocations overlapped on one slot* — no: a slot returns to
  `FR_FREE_SLOTS` only inside `fr_harvest`, which runs after the pool has seen
  that worker finish.
* *a stale flag survived from an earlier run* — no: `FR_OUT` lives under a fresh
  `mktemp -d` per run, and `falsify_run_oracle` unlinks the flag on entry.

Given F52, F50 and F50-again, a fourth confident mechanism is worth less than one
measurement. **Next step is instrumentation, not a fix:** the NOTE prints only
the FOREIGN token, so there is nothing to compare it against. Print this
invocation's own token beside it, and widen the token from `<pid>.<µs>` to
`<slot>.<seq>.<pid>.<µs>` so a foreign flag names the mutant whose watchdog wrote
it. The next occurrence then explains itself instead of being reasoned about.

**Cost today:** two mutants per tight-clock run leave the measured set as
UNPROVEN, which the ledger does not require an entry for (F27). Bounded by
`--max-unproven-pct`, loud on stderr, and not reachable at the clocks anyone
actually uses — the last full host run at `--timeout 600` had zero.

**Reproduction:** `bash tests/falsify/run.sh --jobs 32 --timeout 5` on macOS, and
grep stderr for `FOREIGN TIMEOUT FLAG`. Not yet reproduced on Linux.

---

## F54 — `TOTAL` reports the targets it LOADED, not the targets it measured — **FIXED 2026-08-20**

**ORIGINALLY FILED AS OPEN.** From the same run. Four of nine targets were skipped for an unusable
pristine baseline, and the summary line says:

```
TOTAL|9|106|5|0|101|104|95|217887
```

Nine targets. 106 mutants. Both numbers are the wrong ones: nine is what
`fr_load_targets` accepted, and 106 is what survived being attempted — 158
mutants of four targets were never run, and **nothing in this line says so.**

The information exists, one line per skipped target on stderr and in the earlier
`RUN|…|mutants=264` record, so a reader who compares `RUN` against `TOTAL` can
recover it. That is the defect: a summary that needs a second line to be true.
`check-ledger.sh`, `verify-on-host.sh` Phase 6 and the ratchet all parse `TOTAL`
positionally, and a 106-mutant corpus checked against the ledger reports `OK`
while 158 mutants sit unmeasured.

**What stops this being silent today:** `run.sh:992` sets `rc=1` on a skipped
target, so the run exits non-zero and Phase 6 fails. That is real protection and
it is why this is filed rather than treated as urgent. But it is protection that
lives in the exit code alone; every human-readable and machine-parsed summary of
the run still reports nine targets and calls itself complete.

**The fix:** carry the skipped-target and unattempted-mutant counts in the
summary, so one line states what was measured and what was not. Positional
parsers make appending fields the mechanical part; deciding whether it is a new
field on `TOTAL` or a separate `SKIPPED|` record — the shape `ASSERTLESS|` took,
and for the same reason — is the part to get right.

### 2026-08-20 (evening) — RESOLVED. The flag was mine, read too early.

The macOS repro this entry asked for, run with the instrumentation the entry
shipped, came back with both tokens printed side by side:

```
NOTE|foreign-timeout-flag|tests/lib-layer-checks.sh:logic-flip:27da7c0e…|slot 1 held a timeout flag armed by s1.m2.67442.1787254686507373, not by this invocation, whose own token was s1.m2.67442.1787254686507373
```

**The same string, on both sides of "not by this invocation".** The flag was
armed by the very worker that then failed to recognise it.

**The mechanism.** `printf '%s' "$token" > "$flag"` is TWO operations: the
redirection creates and truncates the destination, and only then does the token
land in it. `falsify_run_oracle` reads the flag twice a few microseconds apart —
once through `falsify_flag_is_mine`, once to build the NOTE:

```bash
if [[ -f "$flag" ]]; then
  if falsify_flag_is_mine "$flag" "$token"; then      # read 1: incomplete file
    FALSIFY_TIMED_OUT=1
  else
    FALSIFY_FOREIGN_FLAG="$(cat "$flag" …)"           # read 2: the whole token
```

The first read landed inside that window and got a file that existed and did not
yet hold the token; the second landed after it and got the token in full. Two
reads of one file, disagreeing, is the entire finding — and it is why the two
tokens in the NOTE are identical.

**Fixed by making the write atomic.** `falsify_arm_flag` writes the token to
`<flag>.<pid>.arming` and renames it into place. A rename within a directory is
atomic, so a reader sees no file or the whole token, never a half-written one.

**Three assertions were already true of the broken code**, which is why the
contract alone is not a guard: the flag held exactly the token, arming again
replaced it, and what it wrote read back as mine. `tests/test-falsify-run.sh`
§11f asserts those anyway, and then adds the one that matters — it overrides
`printf` with a shell function so the token takes two seconds to produce, and
asserts that **the destination does not exist while the token is still being
written**. Demonstrated failing on the bare redirection: `it exists and is
EMPTY, which is exactly the state a reader calls somebody else's flag`, with the
other four still passing.

**What this closes, and what it does not.** F50 fixed the flag having no owner —
that was real, and the ownership check is what made this diagnosable at all.
F53's *observation* was real too: two mutants per tight-clock run lost their
verdict. What was wrong was the story, twice over — the flag was never foreign,
and no watchdog outlived its invocation. The three refuted explanations recorded
in the original filing were all refuted for the right reason: none of them was
happening.

**The pattern, now three for three.** F50, F52, F53: every time a mechanism was
inferred from reading the source it was wrong, and every time the fix was to
make the code SAY what happened and then run it once. The instrumentation is
cheaper than the theory and it is the only thing that has ever produced an
answer here.

### 2026-08-20 — FIXED. Two records, and neither of them is a tenth `TOTAL` field.

`TOTAL` did not grow a field. It is parsed POSITIONALLY by `check-ledger.sh`,
`verify-on-host.sh` Phase 6 and five places in this repo's own tests, and
`ASSERTLESS` already set the precedent for a fact that deserves its own line.

Two records, both on **stdout** — beside `MUTANT`/`TARGET`/`TOTAL`, because
stderr is where this event already was and stderr is what a summary reader
filters out:

```
SKIPPED|<target>|<oracle>|<mutants-not-attempted>|<no-test-matched|baseline-not-green>
UNATTEMPTED|<targets-skipped>|<mutants-not-attempted>|<corpus-size>
```

`UNATTEMPTED` is emitted **always**, at zero like `ASSERTLESS`, for the same
reason: the number can only go up, and the state with nothing to look at is the
state in which nobody looks. A healthy run now closes with
`UNATTEMPTED|0|0|264`.

The macOS run that produced this finding would now read `UNATTEMPTED|4|158|264`
beside its `TOTAL|9|106|…` — one line saying what the other cannot.

**Phase 6 surfaces both.** `verify-on-host.sh`'s summary grep was
`^(TARGET|TOTAL|ASSERTLESS)\|` and is now `^(TARGET|TOTAL|ASSERTLESS|SKIPPED|UNATTEMPTED)\|`.

**No new gate.** `run.sh:992` already sets `rc=1` on a skipped target, which is
what stops this being silent and is asserted directly in
`tests/test-falsify-run.sh` §6. This entry was never about the run passing when
it should not; it was about every human-readable and machine-parsed summary of
the run still saying nine targets.

**Five assertions in §6b**, on the misspelled-oracle fixture — one target, four
mutants, none attempted — plus the zero control. Each guard demonstrated
failing:

| damage | assertion that flips |
|---|---|
| the `SKIPPED` record is not emitted | "a skipped target is recorded on stdout, with the mutants it took with it" |
| `UNATTEMPTED`'s mutant field reports the TARGET count | "…and the run says how much of the corpus was never attempted" |

The second damage leaves the zero control passing, because at zero the target
count and the mutant count are the same number — which is exactly why the
non-zero case had to be asserted separately rather than trusting the control.

### 2026-08-20 — FIXED, and the entry's own two options were not exclusive

The entry offered `-o --exclude-standard` in Phase 7 **or** having Phase 7 merely
SAY what it skipped, and left it undecided. Both were done, because they answer
different halves: including the files is what removes the red-CI surprise, and
saying so is what stops the new policy being as silent as the old one.

Phase 7 now builds its list ONCE, from `vh_all_scripts` — tracked plus
untracked-and-not-ignored — and hands the same list to all three checks:
`bash -n`, `tests/bash-dialect-lint.sh` (explicitly, as arguments), and
`shellcheck`. Previously each rebuilt its own, and the dialect lint would have
kept its tracked-only default while the other two moved.

```
parsed 137 script(s)
  including 1 not yet tracked by git:
    tests/test-something-new.sh
  (they are linted here and in CI only once committed; .gitignore'd files are never included)
```

**CI is deliberately unchanged.** It checks out a branch where everything is
committed, so the two lists are identical there — this can only ever differ on a
developer's machine, which is where the surprise was. `bash-dialect-lint.sh`
keeps its tracked-only default for exactly that reason.

**Six assertions** in `tests/test-verify-lint-scope.sh`, on a fixture whose
tracked broken script is REPAIRED first so the untracked one is the only thing
that can fail the phase. Each guard demonstrated failing:

| damage | assertions that flip |
|---|---|
| the list goes back to tracked-only | 3 — including *"the local gate still reports clean over a file it did not read"* |
| `--exclude-standard` dropped | 3 — the ignored scratch file gets linted and the count is wrong |
| the phase stops saying what it included | 2 — only the reporting pair |

**It broke two other tests, and both were right to break.**

`tests/test-grep-q-pipelines.sh` caught a `producer | grep -q` under `pipefail`
in the new test code itself — F34's rule, enforced over every tracked script,
firing on the increment that was written moments earlier. Rewritten as
`[[ -n "$(…)" ]]`.

`tests/test-verify-exit-code.sh`'s "parsed no files" fixture stopped reaching the
branch it exists for. `MK_REPO_UNTRACK_SH=1` drops `*.sh` from the index while
leaving the files on disk — which, after this change, no longer empties the list:
the same files come back as untracked and Phase 7 lints them, exactly as
intended. Both halves of the list now have to be empty, so the fixture adds a
`.gitignore` containing `*.sh`. That is a fixture change, not a weakened
assertion: the branch still fails the phase and still names itself.

---

## F1 — progress: every subcommand is covered, and it is STILL not enough, 2026-08-20/21

**STILL OPEN.** One of the seven `cmd_*` subcommands is now exercised. The
entry's reason for parking the rest is unchanged.

`tests/test-repo-destructive.sh` runs `repo.sh` as a **real subprocess** —
dispatch included — against a fake `docker` that never contacts a daemon and
whose defining feature is that it **records every argv**. Volumes are marker
files; `docker volume rm` deletes one and logs the call. The assertions read
that log, so what is checked is the exact set of volumes `repo.sh` asked to
destroy, not a side effect that happened to be survivable.

Nineteen assertions over seven cases: the non-interactive refusal, the removal
set, the blast radius, the registry edit, the unknown-name path, name validation,
and the no-argument path. Three guards demonstrated failing against real damage
to `repo.sh`:

| damage | what it does | assertions that flip |
|---|---|---|
| `--filter "name=${vol}--wc-"` loses its `--wc-` anchor | **`rm docs` destroys `docs-archive` and its working copy** | 3 |
| the non-interactive refusal becomes a warning | `rm docs` with no `--yes` deletes all three volumes | 3 |
| `validate_repo_name` is skipped | `../../etc` reaches `docker volume ls --filter` | 2 |

The first is the one this file exists for. `docker volume ls --filter name=X` is
a SUBSTRING match, so a bystander repo whose name merely BEGINS with the
subject's is inside the blast radius of a single dropped suffix — and nothing
anywhere asserted otherwise.

### Slice 2, 2026-08-21 — `cmd_reset` and `cmd_gc`

The destructive trio is complete. 36 more assertions in the same harness, which
gained two things it needed: `docker volume inspect --format` now answers from a
per-volume `.labels` sidecar, and `docker ps --filter volume=` answers from a
one-name-per-line "in use" file — the only reason the fake knows `docker ps` at
all is `gc --unused`.

**`reset` and `rm` destroy different things, and that difference is the subject.**
`rm` takes the base volume away; `reset` puts the base volume BACK to a clean
state and removes only the working copies. A reset that removed the base would
still look like success — the repo would simply be re-seeded on next use — so
"the base volume survived" is asserted outright rather than inferred.

Five guards demonstrated failing:

| damage | what it does | assertions that flip |
|---|---|---|
| `reset_one`'s `--wc-` filter loses its anchor | `reset docs` reaches `docs-archive` **and** takes both base volumes | 3 |
| a `docker volume rm "$vol"` is added to `reset_one` | `reset` silently becomes `rm` | 2 |
| the bind-backend early return is dropped | `reset` seeds a volume no container will mount, and reports "reset to a clean state" | 1 |
| `gc`'s `--unused` test is inverted | it removes exactly the copies a running container **is** using | 1 |
| `gc`'s non-interactive refusal becomes a warning | every working copy on the machine is deleted without `--yes` | 2 |

**One comment in this file was wrong and was corrected before it landed.** The
bind-backend case originally claimed a reset without that guard "would delete a
developer's uncommitted work on the host". It would not: `sync_from_path` copies
INTO a volume, never over the host path. The real consequence is quieter and
worth stating precisely — the user is told the repo they are about to run
against was reset, while the thing that was reset is a volume no container will
mount. The `DIRTY` file the case plants is therefore a **control**, not the
guard, and the comment now says so.

### Slice 3, 2026-08-21 — `add`, `sync`, `reindex`, and `list`'s flag handling

Nothing in slice 3 deletes, so it is aimed at what these paths DO carry: the
seeding helpers mount **host paths and the developer's private SSH keys** into a
**root** container, and the mount MODE is the only thing between "read the
source" and "write to it". That is argv, and argv is what this harness already
records. Four guards demonstrated failing:

| damage | what the recorded argv then shows |
|---|---|
| `seed_from_path` drops `:ro` | `-v /…/newsrc:/src` — the root seed helper can write back into the developer's tree |
| `seed_from_git` drops `:ro` | `-v /…/.ssh:/root/.ssh-host` — root, read-write, over the private keys |
| `host_uid`/`host_gid` revert to `id -u`/`id -g` | `chown -R 502:20` while `SANDBOX_UID=4242` was set |
| `cmd_add`'s stray-volume guard is dropped | `add` seeds straight over an unregistered volume |

The third is not hypothetical: `AGENTS.md` records that exact regression as
having already shipped once, breaking the documented override and leaving seeded
volumes owned by the wrong UID.

Also covered: `sync`'s read-only `~/.ssh`, `sync --all`, the bind-backend no-op,
and that **`reindex` never removes a registry entry** — it exists to *recover* a
lost registry, so dropping the bind entry would unregister a repo with no volume
to rediscover it from.

**`tests/test-grep-q-pipelines.sh` caught the new test code twice in one day.**
Five `producer | grep -q` pipelines under `pipefail` — F34's rule, enforced over
every tracked script, firing on the increment that had just been written.
Rewritten through a `run_has` herestring helper, and one damage re-run afterwards
to confirm the new form still flips rather than having gone quietly vacuous.

### AND THE MEASUREMENT SAYS IT IS STILL NOT ENOUGH

The stated goal of slice 3 was to finish F1 so `repo.sh` could leave DEFERRED and
enter the mutation tier. **It does not.** Measured with all three slices in
place, whole-file, under the derived two-test oracle set:

| | mutants | killed | survived | unresolved |
|---|---|---|---|---|
| `repo.sh`, all three slices | 249 | 120 | **129** over 82 lines | **51%** |
| `sandbox.sh`, for comparison | 267 | 193 | 74 | 27% |

Against a corpus that carries **2** survivors. `repo.sh` is in worse shape than
the target this project deliberately left deferred, after three slices of work.

**Where they are, because it decides what comes next.** The survivors are
overwhelmingly in *what the user is told*, not in *what is done*:

```
cmd_list 15 · list_copies 8 · cmd_gc 8 · ensure_seed_image 7 · cmd_sync 7
cmd_rm 7 · cmd_reset 6 · cmd_reindex 6 · sync_one 4 · reset_one 4 · rest 10
```

`cmd_rm` and `cmd_gc` still carry survivors **despite slices 1 and 2**, because
those assertions check what was REMOVED, not what was PRINTED before the
removal — the *"About to remove …"* summary a human reads before typing `yes`.
That summary is not cosmetic: it is the entire basis on which someone consents
to a destructive operation, and every mutant of it survives today.

And the interactive confirmation itself — `[[ "$reply" == "yes" ]]` — survives in
both, because every case here drives the **non-interactive** path. `read -r -p`
needs a tty, and nothing in the hermetic suite has one.

**One thing slice 3's own measurement found and fixed immediately:** `exit 1` →
`exit 0` SURVIVED on both of `cmd_list`'s flag-error lines, so
`repo.sh list --nonsense` printed an error and reported **success**. The same
refusal was already asserted for `gc` and `reset`; `list` had simply been missed.
Four assertions added, demonstrated failing, and they killed 5 mutants.

**The next slice is a different KIND of test** — assert the rendered output, and
find a way to exercise the tty branch — and it is larger than the three before
it. `repo.sh` stays DEFERRED **on that measurement**, not on the original
argument, which slices 1-3 have now retired.

**It also exposed a fixture that had silently become a no-op.**
`tests/test-falsify-targets.sh`'s gate-4c fixture rewrote the `repo.sh` row by
matching its function list VERBATIM. The day that list changed — this day — the
`sed` matched nothing, `gate4c.conf` was byte-identical to the real map, the
gate passed, and the failure message read *"gate 4: an undefined function name
was accepted"*: blaming the gate for the fixture's silence. Gate 5 already
asserts its own premise; gate 4c now does too, and the pattern matches the
field's SHAPE rather than its contents. Demonstrated by making the fixture a
no-op again — the premise assertion fires first and names itself.

---

## F55 — `test-falsify-run.sh` failed once under full-suite load and did not reproduce — **RESOLVED 2026-08-21, it reproduced and had a mechanism**

**OPEN, and deliberately thin.** On 2026-08-20 a full `tests/run-all.sh` reported
`57 test(s), 56 passed, 1 failed — Failing: test-falsify-run.sh`. Run alone
immediately afterwards it passed, and three subsequent full-suite runs were
`57/57`.

**The failing assertion was not captured.** The run's output was piped to
`tail -3`, so the `FAIL:` line scrolled past unread. That is an operator error,
not a harness gap — `run-all.sh` does print it — and it is recorded because the
alternative is pretending the event did not happen.

**What is known:** the failure occurred under full-suite load and not in
isolation. **What is not known:** which assertion, and therefore whether this is
a timing sensitivity, a resource limit, or a genuine intermittent defect.

**Prior art that makes this worth chasing rather than shrugging at:** F26 was
exactly this file being timing-sensitive on macOS, and F32 records three
load-sensitive oracles where the tier reads slowness as coverage. This file now
also carries §11f, whose atomicity guard deliberately makes a write take two
seconds and inspects the filesystem one second in — a construction that is
correct but is, by design, about wall-clock.

**Next step is capture, not theory:** run `tests/run-all.sh` with its output
retained rather than tailed, and keep the log of any failing run. One captured
`FAIL:` line settles this; nothing else will.

---

## F30 / F32 — 2026-08-21: control runs, and what they do and do not settle

**Candidate fix 1 is built.** F30 listed three, in order, and said of the first
that it "is the only proposal here that would have caught the measured case,
because it asks the right question — *is this oracle green under these
conditions?* — instead of guessing at a proxy for it." That is what landed.

`fr_run_control` runs the **unmutated** tree through a real worker slot,
interleaved among the mutants at positions computed from each target's own
count, so the controls sample the run early, in the middle and late rather than
clustering where the machine happens to be quiet. Two per target by default;
`--controls N` / `FALSIFY_CONTROLS`, `0` disables.

```
CONTROL|<PASS|FAIL>|<target>|<oracle>|<n>|<signal>|<ms>
CONTROLS|<total>|<failed>
```

`CONTROLS` is emitted **always**, like `ASSERTLESS` and `UNATTEMPTED`, and its
first field is the total: *"no controls ran"* and *"controls ran and passed"* are
different claims and must not read the same. A failed control names itself on
stderr at the moment it happens and fails the run.

**Why a control and not a re-verify.** F30's own measurement ruled out the
obvious remedy: the contaminated oracle failed with signal `exit+failline` at
**2.5 seconds**, no timeout involved. Scoping a re-verify to timed-out kills
would have missed it entirely. Slowness is a symptom of the load, not the vector.

**Cost, measured:** 18 controls over the 9-target corpus, wall time **74s against
73s** without them. They fill slots that were idle at each target's tail, so the
detection is very nearly free. That is the argument for a non-zero default.

**Demonstrated by removing the dispatch**, which is the pre-F30 tier. The fixture
is an oracle that counts its own invocations and goes red from the Nth, so at
`--jobs 1` the ordering is fixed and the BASELINE passes while the CONTROL fails
— precisely the case F32 says the per-target baseline cannot see. With the
dispatch removed:

```
FAIL:   … and the run FAILS rather than reporting a clean corpus (expected '1', got '0')
PASS:   … while the mutants after it were indeed scored KILLED, which is the harm
```

Same contaminated corpus, same false kills, reported clean and exiting 0. That
pair is the whole finding.

**What this does NOT do, stated plainly.**

* It does not identify **which** kills are contaminated. A failed control says
  the run's kills cannot be trusted; F30's fix 2 (re-verify every kill in a run
  whose control failed) is deliberately not built, because it is only worth
  building once there is a run that trips this in the wild.
* It does not make a contaminated run **safe**. It makes it **loud**, which is
  the difference between a gap that is invisible and one that is reported.
* It cannot catch contamination that lands entirely between two controls. Two
  per target is a sampling rate, not a proof, and raising it trades wall time
  for resolution.

**F32's remaining items are unchanged in kind.** Its listed options were
"re-check the baseline mid-target", "scale `--timeout` from a measured
per-oracle baseline", and "cap concurrency below `nproc`". The first is now
built; the third exists as `--jobs auto` reading the cgroup quota (F38). The
second is not built and should stay unbuilt until a control failure demands it —
F32's own history is that **two of its four cases turned out to be specific
defects rather than a need for more time** (F34's `grep -q` pipeline, F35's OOM
kill), and the entry's standing advice is to look for a mechanism before
reaching for `--timeout`.

**STILL OPEN, and needing one host run.** F30 records that the macOS reading
which surfaced it came from a tree whose exact commit is not known, so whether
it already carried the `/tmp` fix is unresolved — and if it did, there is a
second contamination path nobody has identified. The entry names the experiment:
re-run Phase 6 on current `main` and check whether
`tools-lib.sh:return-flip:f128fd8d` still appears in the obsolete-amnesty list.
With controls in place that run now also answers a second question it could not
before: whether a real 18-way macOS run trips a control at all.

---

## F30 — CONFIRMED IN THE WILD, 2026-08-21, on the first real host run

The control ran for the first time on macOS and **fired immediately**:

```
ERROR: CONTROL FAILED — the PRISTINE oracle went red under this run's own load
(signal=exit+failline, 95.4s): tests/bash-dialect-lint.sh via test-bash-dialect-lint.sh.
Kills recorded near it cannot be trusted.
ERROR: 1 of 18 control run(s) FAILED …
** PHASE 6 FAILED: the falsify corpus did not complete — the ledger was not scored
```

`FALSIFY_JOBS=8 FALSIFY_TIMEOUT=600`, Colima 12 CPU / 36 GiB. **Not a timeout** —
`exit+failline`, which is exactly the shape F30 measured in 2026-08-17 and
exactly why the entry ruled out scoping a re-verify to timed-out kills. The
oracle took 95.4s where the container runs it in ~14s, so load is plainly
involved; but the verdict is an assertion that FAILED, not a clock that ran out.

**What this settles.** F30 is no longer a reconstruction from one macOS report of
unknown provenance. The mechanism is real, it is reachable at a job count a
person would actually use, and the tier now refuses the run instead of scoring a
ledger against kills it cannot vouch for. Before this, the same machine reported
`RESULT: PASSED` with the same contamination present and undetected.

**What it does NOT settle**, and this is the part that matters: the original
question — whether `tools-lib.sh:return-flip:f128fd8d` still appears in the
obsolete-amnesty list — **was not answered, because the run stopped before the
ledger was scored.** That is the correct behaviour and it is also a real
consequence: a host that trips a control cannot complete Phase 6 at all.

### The finding the finding exposed: a failed control could not say what failed

The error names the target, the oracle, the signal and the elapsed time. It does
**not** name the assertion that went red — and that is the one fact separating
*"this oracle is load-sensitive"* from *"this oracle has a defect"*, which is
precisely the distinction F32's standing advice turns on ("look for a mechanism
before adding a timeout"; two of its four cases turned out to be F34's `grep -q`
pipeline and F35's OOM kill, not slowness at all).

The oracle's output went to `$FR_OUT/w<slot>.log` — **per SLOT**, overwritten by
the next mutant that lands there, and removed with the scratch tree at exit. By
the time anyone read the error it was gone.

Fixed: a failed control now carries its own `FAIL:` / `SCAFFOLD-FAILED:` lines
out on the record stream as `NOTE|control-output|<target>|<line>`, echoed to
stderr beside the error they explain. An oracle that went red with no such line
at all says *that*, rather than looking like output nobody captured.

### `tests/bash-dialect-lint.sh` is a FIFTH load-sensitive oracle (F32)

F32 lists four. This is the fifth, and it is the first one observed **as a
pristine control** rather than as a mutant verdict — which means it was
previously invisible: a red oracle mid-target simply became kills.

**No mechanism is proposed here.** F32's own history is that half its cases had
specific, fixable defects rather than a need for more time, and this project has
been wrong five times running when it inferred a mechanism from reading source
(F50 twice, F52, F53, the gate-4c fixture). The next host run carries the
diagnosis; that is what decides it.

**Reproduction:** `FALSIFY_TIMEOUT=600 FALSIFY_JOBS=8 PHASES=6 bash ./verify-on-host.sh`
on macOS, and read the `NOTE|control-output|` lines beside the `CONTROL FAILED`
error.

---

## F32 — 2026-08-21: the first captured diagnosis, and two things it exposed

The second host run (same command, same `--jobs 8`) tripped **two** controls and
carried their evidence out:

```
ERROR: CONTROL FAILED — … (signal=exit+failline, 80.3s): tests/bash-dialect-lint.sh …
ERROR: CONTROL FAILED — … (signal=exit+failline, 47.4s): tests/integration/docker-shim.sh …
falsify:   control output: FAIL: volume create: labelled
falsify:   control output: FAIL: network create: labelled
falsify:   control output: FAIL: volume rm is passed through untouched (no label injection)
falsify:   control output: FAIL: an unrelated subcommand is passed through untouched
falsify:   control output: FAIL: inspect is passed through untouched
falsify:   control output: FAIL: refuses with 127 when IT_REAL_DOCKER is unset
                            (rc=127, out=env: /var/folders/…/tmp.G1R3ZjNW6O/bin/docker: No such file or directory)
```

**IT IS NOT SLOWNESS.** `No such file or directory` for `$TMP/bin/docker` — the
fake docker `test-integration-shim.sh` builds for itself, a symlink to
`$REPO_DIR/tests/integration/docker-shim.sh` in the worker tree. Something the
test depends on was **gone**, and no amount of `--timeout` addresses that. F32's
standing advice — look for a mechanism before reaching for a clock — holds for a
third case out of five.

**The failing set is contiguous and it starts partway through.** These passed:
`bash -n`, `is executable`, the three `main run:` cases, `helper run:`. These
failed: everything from `volume create: labelled` onward. So the fake docker
existed when the test began and was missing by the time it reached that case.

**NOT REPRODUCED IN THE CONTAINER**, at `--jobs 16 --controls 6` against that
target alone: `CONTROLS|6|0`. So it is macOS-observed and this entry does not
claim a mechanism. Five separate times this project has inferred one from
reading source and been wrong (F50 twice, F52, F53, the gate-4c fixture); the
next diagnosis decides it, not this paragraph.

### What the capture got wrong, and now does not

**Five of the six captured lines were bare assertion NAMES with no evidence.**
`tests/run-all.sh`'s `check` helper prints the name on the `FAIL:` line and the
`expected:` / `got:` pair INDENTED underneath — and the capture grepped `^FAIL:`
only. The one line that told anybody anything was the sixth, whose message
happened to fit on one line. The capture now takes each `FAIL:` /
`SCAFFOLD-FAILED:` line **plus the indented lines beneath it**, capped at 6
failures and 30 lines.

### And a defect in the pool's own reporting, from the same run

The `bash-floor` CI job failed once on this PR chain with:

```
FAIL: … got: ERROR: a mutant worker produced no verdict at all (slot 7; it exited 127)
```

Re-running the identical job passed, and the same content had passed on the four
runs before it — so it is **intermittent on bash 5.1**, which is the declared
floor. `wait -n -p` there can return **127** for a child that has already
terminated, and 127 is `wait`'s OWN *"there are no unwaited-for children"*, not a
status any child exited with.

`fr_wait_for_slot` recorded it as the worker's exit status, so `fr_exit_cause`
printed *"it exited 127"* — **a number nothing measured**, about a worker that
had in fact been SIGKILLed. That is precisely the failure mode this channel was
built to end. Fixed: 127 is recorded as no status at all, and reads as
`exit status not captured`.

The §11d assertion now accepts either the real signal **or** an explicit
non-capture — because at the floor bash genuinely cannot always supply one — and
a second, version-independent assertion pins the part that is never acceptable:
**a `wait`-internal code must never be reported as a worker exit status.** Both
demonstrated failing.

**Honest limitation:** the fallback's own guard is only asserted where bash can
supply a status, i.e. at 5.2. At the floor, "the fallback is present but bash
had nothing" and "the fallback is absent" produce the same message, and no
assertion distinguishes them.

**This also gives F55 what it was waiting for** — a captured intermittent
failure with its message intact, and a cause: bash 5.1's `wait -n -p`.

---

## F4 — 2026-08-21: covered, and the coverage found a defect — **CLOSED: fourteen assertions, and the `api_get` defect they found is fixed**

Fourteen assertions in `tests/test-tools-d.sh`. Writing them found a real bug in
`api_get`, which is the argument for writing them.

**THE DEFECT: a failed transfer became the response.** `api_get` does

```bash
body=$(curl -fsSL … "$url") && [ -n "$body" ] && break
```

and, on reaching the end of the retry loop, `printf '%s' "$body"`. If curl exits
non-zero having ALREADY written to stdout, `body` keeps that fragment and it is
returned as the API's answer — `install_one` then parses it for a tag. `-f`
suppresses an HTTP *error page*, so the obvious reading is that this cannot
happen; it does not suppress a **connection reset part-way through a successful
response**, which is exactly a partial body plus a non-zero exit. One line:
`body=""` after the failed attempt.

**TIME IS CONTROLLED, NOT WAITED OUT.** `api_get` sleeps 5s between attempts, so
a faithful "it retries three times" costs 10s per case — and this file already
carries a comment about that cost. `sleep` is overridden with a shell FUNCTION,
which takes precedence for a function sourced into the same shell, so the wait
is RECORDED. That proves more than waiting would: the delay happened **and** it
asked for 5 seconds.

**What is asserted:** the body is returned on success with exactly one call and
no sleep; three attempts and two 5-second waits on failure, giving up empty; an
empty body from a *successful* curl counts as failure and is retried (the
`&& [ -n "$body" ]` half — the API answers a rate-limit that way); the API media
type, the URL and `-f` reach curl; the token header is sent when configured and
**no `Authorization` header is sent when none is**.

Guards demonstrated failing: removing the `body=""` discard, removing the
empty-body check, and leaking an `Authorization` header on the tokenless path.

### Three things went wrong writing this, and all three are recorded

1. **The block was inserted mid-file and its fake `curl` displaced the
   repo-file fixture**, taking five unrelated assertions down. It now sits last,
   with the reason written at the site — the next person will reach for the same
   `$FAKEBIN`.
2. **It called `check`, which this file does not define.** bash printed
   `check: command not found` on stderr and the file still reported **ALL
   PASS** — every new assertion silently absent. Renamed `ag_check` so it cannot
   be mistaken for a shared helper. That a missing helper produces a passing run
   is worth knowing about this harness.
3. **A comment claimed something untrue.** `${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}`
   was described as the guard stopping `set -u` from aborting the installer when
   no token is set. Measured on bash 5.2 with `set -u` in force: an unset array
   expands to nothing without error, and has since 4.4. The guard is vestigial
   at the declared floor, removing it changes nothing, and no assertion here can
   demonstrate it failing. The comment now says that instead.

**Also recorded from the same day:** `500-group-isolation` failed once on
`mgd-ai-containers` CI —
`FAIL: launcher_up(open): entrypoint never handed over to the agent shell (uid 1001)`
— on a diff touching only the falsify engine, which the integration tier never
reads, after nine consecutive successes. It passed on re-run. That is F32's
family arriving in the **integration** tier, which has no control-run mechanism
of its own; one occurrence, message captured, no mechanism claimed.

---

## F32 — 2026-08-21: the two "load-sensitive oracles" were UNGUARDED SCAFFOLD WRITES

The kept log from the 06:06 host run gave both controls' diagnoses, and they say
the same thing:

```
CONTROL|FAIL|tests/bash-dialect-lint.sh|…|exit+failline|80350
NOTE|control-output|…|FAIL: the empty run failed, but not with the 'examined no files' message
   (got: bash: …/tmp.xYa06HxEye/emptyrepo/tests/bash-dialect-lint.sh: No such file or directory)

CONTROL|FAIL|tests/integration/docker-shim.sh|…|exit+failline|47467
NOTE|control-output|…|FAIL: refuses with 127 when IT_REAL_DOCKER is unset
   (rc=127, out=env: …/tmp.G1R3ZjNW6O/bin/docker: No such file or directory)
```

**`No such file or directory`, both times, for a file the test had just written
into its own `mktemp -d`.** Not slowness, and no `--timeout` addresses it. Each
test guards `mktemp -d` itself and nothing after it, so:

* `test-bash-dialect-lint.sh` — `cp "$LINT" "$empty_repo/tests/…"`, unchecked
* `test-integration-shim.sh` — `ln -sf "$SHIM" "$TMP/bin/docker"`, unchecked

That is **F31's family exactly** — "guard every unchecked `mktemp`" — one step
further along: guard every unchecked scaffold WRITE. `test-tools-d.sh` already
carries `scaffold_file`/`scaffold_exec` for precisely this, with its own note
about ENOSPC leaving files empty on APFS.

**Why it mattered more than a red test.** With the write unguarded, a lost
scaffold reads as an assertion FAILURE. For a control that is merely
mislabelled; **for a mutant it is a false KILL** — the oracle exits non-zero, the
mutant is scored killed, and the survivor the ledger was owed disappears. That
is F30's harm, arriving through the harness rather than through load.

Both now emit `SCAFFOLD-FAILED:`, which is a CHANNEL and not a louder failure:
`tests/run-all.sh` checks it **before** the generic failure branch and surfaces
only those lines, and `falsify_verdict` scores such a mutant **UNPROVEN, not
KILLED** (`run.sh:597`). Verified end to end by deleting the symlink mid-file:
`FAIL (could not set itself up — the environment, not the code)`.

**One thing the first draft got wrong, measured rather than reasoned.** The
`shim()` guard printed to stdout and `exit 1`. `shim` is called inside `$( … )`,
so stdout is captured as the value under assertion and the exit leaves only the
subshell: nine assertion failures, and **not one SCAFFOLD-FAILED line anywhere**.
Moved to stderr, which escapes the substitution and which both harnesses merge
and read. The direct `$TMP/bin/docker` callers get the guard in the outer shell,
where the exit actually stops the file.

**Also measured, and it kills a theory rather than confirming one:** a bash
subshell does **not** fire an inherited `EXIT` trap — checked on 5.2 for `$( )`,
`( )` and `( exit 3 )`. The `trap 'rm -rf "$TMP"' EXIT` in both files is not the
mechanism.

**The trigger is still unidentified**, and this entry does not guess at it. What
changed is that the next occurrence names itself as scaffolding and costs an
UNPROVEN instead of a false kill.

### The second host run passed clean, which is itself the point

Same command, same commit, quiet machine: `TOTAL|9|264|261|3|0|0|1`,
`CONTROLS|18|0`, ledger OK, `RESULT: PASSED`. Both controls that failed at 06:06
passed at 09:21. The failure is **intermittent**, which is exactly the condition
a sampled control detects and a one-shot baseline cannot — and exactly why
`CONTROLS|18|0` on a green run is worth printing rather than omitting.

---

## F55 — RESOLVED 2026-08-21. A one-second clock measuring a three-second wait.

It happened again, with the log kept this time, and the message was the whole
finding:

```
FAIL:   … a subject that outlives the clock reports the clock expiring —
        rc=1 after 2s, so a real hang would no longer time out
```

**`rc=1` was CORRECT.** The clock did expire and `falsify_watch_until` reported
it. Only the *elapsed reading* was wrong.

§11c measured with `$SECONDS`, whose resolution is one second, against a wait of
about 3.00 s. The reading is therefore 2 or 3 depending only on where the start
landed inside a second, and `>= 3` fails whenever the boundaries fall badly.
Measured in milliseconds across three consecutive runs: **3032, 2905, 3034**.
The middle one is under three seconds — so `$SECONDS` reads `2` and the old
assertion fails. The flake reproduced and explained in one command.

Both §11c cases now measure with `run.sh`'s own `fr_now_us`. The threshold is
deliberately BELOW the nominal clock: what the case separates is *waited for the
clock* from *returned immediately without waiting*, and the margins are enormous
— an immediate return finishes in **5 ms**, correct behaviour sits at
**2905–3034 ms**, and a blind `sleep "$secs"` takes **19794 ms**. 2000 ms
discriminates all three with a second of slack either side. Both demonstrated.

**The operator error F55 was filed for is also closed:** the original message was
lost to a `tail -3`. Full suite logs are kept now, which is the only reason this
entry has a mechanism rather than a second unreproduced sighting.

---

## F1 — slice 4, 2026-08-21: the summary somebody reads before typing `yes` — **CLOSED to the hermetic limit; the remainder needs a tty and `targets.conf` says so**

Slice 3's measurement located the gap: after every DECISION was asserted, 129 of
249 mutants survived, clustered in what the user is TOLD rather than in what is
done.

**That summary is not cosmetic.** It is the entire basis on which a person
consents to deleting a volume, and every mutant of it survived.

Fifteen assertions on `cmd_rm`'s and `cmd_gc`'s summaries, all on the REFUSAL
path — no `--yes` — because both print before they ask, so no case here deletes
anything. Three guards demonstrated failing:

| damage | what the summary then says |
|---|---|
| `has_base` inverted | offers to remove a volume that is not there, while silent about the one that is |
| **the working-copies test inverted** | **`rm docs` deletes projA and projB without listing them** — only the base volume and the registry entry appear |
| `gc`'s unknown-label fallbacks inverted | every labelled copy reads `?`, the unlabelled one reads blank — exactly backwards |

The second is why the slice exists. That list is the sole warning that a volume
may hold uncommitted work.

**Re-measured: 129 KILLED / 120 SURVIVED of 249, 48% unresolved**, from 120/129.

**What remains is largely unreachable hermetically**, and `targets.conf` says so
rather than implying another slice would close it: the confirmation itself,
`[[ -t 0 ]]` and `[[ "$reply" == "yes" ]]` in all three subcommands. Every case
drives the non-interactive path because `read -r -p` needs a tty and nothing
hermetic has one.

---

## F37 — FIXED 2026-08-21. Renamed, and F36 changed which name was right.

`tests/integration/demonstrate-network-tier.sh` is now
**`demonstrate-network-delivery-tiers.sh`**. Nine files, exactly as the
re-derived blast radius said: the script itself (8 self-references),
`AGENTS.md`, `tests/falsify/targets.conf:120`, `tests/test-mutations.sh:114`,
two mutation patch headers, `lib-rebuild.sh`, `demonstrate-needs-rebuild.sh`
(then still `demonstrate-launcher-tier.sh`),
and this file.

**Both names the entry proposed turned out to be wrong, and F36 is why.** F37
predicted that if F36 landed first "the complement collapses and the script
becomes the demonstrator for everything, at which point
`demonstrate-mutations.sh` is simply correct." F36 did not collapse anything —
it landed as a SECOND script, `demonstrate-launcher-tier.sh`, and the two now
partition the set:

| selector | script | patches |
|---|---|---|
| tagged `network-mode` or `delivery` | this one | 16 pairs, 2 needing a rebuild |
| needs a rebuild, and NOT those tags | `demonstrate-needs-rebuild.sh` | 9 |
| everything else | hand-driven per AGENTS.md | 11 |

So `demonstrate-image-tier.sh` — the entry's other candidate — would have been
worse than the name it replaced: the image-baked set is precisely what the OTHER
script owns. The honest name is the two tags it selects, and the plural is the
whole point of the entry.

Derived from the patches themselves rather than read off the headers, since that
is what produced the correction.

---

## F56 — `demonstrate-launcher-tier.sh` has F37's defect, and its honest name needs a decision — **FIXED 2026-08-21**

Found while closing F37, by deriving what each demonstrator actually selects.

Its selector is `patch_needs_rebuild && NOT network-mode|delivery`, which today
is nine patches spanning **three** tiers — `mounts` (410), `volumes` (630) and
`packages` (700, 720, 730, 735, 740, 745, 750). Its own header says
"LAUNCHER/PACKAGES-tier", so the undersell is known and written down, exactly as
F37's was.

**But it is not F37's mechanical fix, which is why this is filed rather than
folded into that rename.** `demonstrate-launcher-packages-tiers.sh` would
OVERCLAIM: the script does not demonstrate the launcher tier: it demonstrates
the rebuild-needing 2 of its 11 members (410 and 630), and 400/420/430/440/500/
510/600/610/620 stay hand-driven. Its selection is not tier-based at all. The
accurate name describes the PREDICATE — something like
`demonstrate-image-baked.sh` or `demonstrate-rebuild-required.sh` — and picking
one introduces a word the project's tier vocabulary does not yet have.

That is a naming decision, not a rename, and it is the reason F37 took two
attempts to name one file correctly.

**Cost is one coordinated change across both repos**, same shape as F37: the
script, `targets.conf`, `AGENTS.md`, and whatever references accumulate. Cheaper
now than after the name spreads further.

---

## F56 — FIXED 2026-08-21. The name says the predicate, because the selector is one.

`tests/integration/demonstrate-launcher-tier.sh` is now
**`demonstrate-needs-rebuild.sh`**, and the filename now agrees with
`patch_needs_rebuild()` — the function in `lib-rebuild.sh` that actually
implements the selection, so a reader finds one from the other.

**The decision F56 was filed for, made:** every tier-based name overclaims. The
script covers **2 of the launcher tier's 11** mutations (410, 630) and **7 of
the packages tier's 9**, so `demonstrate-launcher-packages-tiers.sh` would have
named two tiers it does not cover and omitted `volumes` and `mounts`, which it
partly does. The selector was never a tier.

**The two names are deliberately asymmetric, and that asymmetry is the point:**

| script | selects by |
|---|---|
| `demonstrate-network-delivery-tiers.sh` | tags — `network-mode` or `delivery` |
| `demonstrate-needs-rebuild.sh` | a predicate — `patch_needs_rebuild()` |

Naming both as tiers would have hidden that one of them is not tag-driven at
all, which is the misreading that produced F37's two wrong candidates.

**A falsified prediction removed rather than left in place.** The script's NAMING
paragraph, written when F36 landed, said that when F37 landed "both collapse
into demonstrate-mutations.sh and this comment goes with them". They did not
collapse — F37 was a rename, not a merger. The paragraph now records what
happened instead of what was expected, because a stale prediction left in a
header is the same defect as a stale measurement left in a row (see the mgd
`#DEFERRED` fix of the same date).

---

## F36 — CLOSED 2026-08-20 on the host. Nine of nine, and the projection was 10x wrong.

Run by the Host Agent on a real daemon, against images genuinely rebuilt with
each mutation applied. **Nine patches, nine DEMONSTRATED, zero UNDEMONSTRATED,
zero not-run.** Every one carried a real `FAIL:` assertion line, so none is the
hollow "exited 0 but asserted nothing" verdict the INCONCLUSIVE outcome exists
to catch.

| patch | case | variant | wall | the assertion that fired |
|---|---|---|---|---|
| 410-workspace-root-not-chowned | 410-workdir-and-umbrella | default | — | the write was REFUSED |
| 630-rvm-root-not-chowned | 630-rvm-volume-writable | default | 14s | agent can write …/.rvm — REFUSED |
| 700-agent-tools-not-linked | 700-agent-tools-install-restricted | agents | 1003s | reconcile did not finish within 900s |
| 720-npmrc-prefix-restored | 720-node-multiversion-nvm-use | agents | 99s | `nvm use 20` FAILED |
| 730-db-clients-not-space-split | 730-native-clients-run | native | 372s | psql is on PATH |
| 735-toolchain-not-restored | 730-native-clients-run | native | 135s | libyaml-dev's header is MISSING |
| 740-default-ruby-not-linked | 740-ruby-bootstraps-and-resolves | native | 360s | ruby is on PATH |
| 745-ruby-hooks-not-exposed | 740-ruby-bootstraps-and-resolves | native | 318s | bundle present but FAILED TO RUN |
| 750-only-default-ruby-installed | 750-ruby-multiversion-selection | native | 177s | ruby_wait_ready: reconcile FAILED |

**THE COST PROJECTION WAS WRONG BY 10x, AND THE REASON IS REUSABLE.** Summing
the declared timeouts gave **403 minutes**. The measurement was **~42**. A
declared timeout is a *hang detector*, not a cost estimate — a sound upper bound
used as a point estimate. The tell that was missed: ceilings cluster on round
numbers (300 / 2000 / 2100 / 3900), and a number that looks *chosen* rather than
*observed* is not an estimate. Worth remembering before any future tier is
deferred as "too expensive" on the strength of its own timeouts.

`IT_RUBY_VERSIONS` is recorded as a standing cost lever rather than a deferral:
one version roughly halves the native tier, at the price of withdrawing the
multiruby capability — which would make `750-ruby-multiversion-selection` SKIP
honestly. Nobody needs that at the measured cost, but a slower machine might.

---

## F57 — `it_wait` cannot distinguish "not yet" from "never" — **RESOLVED 2026-08-21, see the ADDENDUM below**

Found by the Host Agent during F36's run, and recorded here because it was not
recorded anywhere: it lived only in a chat message until 2026-08-21.

`tests/integration/lib.sh:122` polls until success or deadline:

```bash
it_wait() {  # $1=timeout in wall-clock seconds, $2… = command
  local t="$1"; shift
  local deadline=$(( EPOCHSECONDS + t ))
  while :; do
    "$@" >/dev/null 2>&1 && return 0
    (( EPOCHSECONDS >= deadline )) && return 1
    sleep 1
  done
}
```

It expresses **not yet**. It has no channel for **never**. Any mutation that
permanently falsifies the condition burns the entire ceiling by construction,
every time, and returns a timeout indistinguishable from a real hang.

**Measured, with its own control.** Both numbers come from F36's run:

| | call site | ceiling | whole run | why |
|---|---|---|---|---|
| `700` | `700:72`, `it_wait 900` | 900s | **1003s** | its mutation removes the claude link, so the condition is permanently false — ~900s of polling a decided question, ~100s for everything else |
| `720` | `720:52`, `it_wait 900` | 900s | **99s** | its mutation breaks `nvm use 20`, not the link, so the *same* poll returns at once |

Identical primitive, identical budget, identical failure message
(`the agent-tools reconcile did not finish within 900s`) — and the cost decided
entirely by whether the condition ever becomes true. `700`'s failure at `700:73`
is bound to that `it_wait`, not to `launcher_up`'s settle: line 68 either
succeeded or execution never reached 72.

**Not a defect in case 700.** Its header reasons about exactly this and sizes
2100s for margin. The defect is in the primitive.

**WHY IT MATTERS BEYOND COST, which is the part worth keeping.** The falsify
tier detects load-dependent verdicts through several channels — `timeout`,
`scaffold`, `signal`. The integration tier detects **none** of them. A verdict
that took the full ceiling and a verdict that failed instantly are reported the
same way, so the tier cannot tell "this assertion can fail" from "this machine
was slow", which is the F30/F32 family of defect in a place nothing checks for
it.

**Blast radius, re-derived 2026-08-21 and unchanged: 20 call sites across 11
case files**, three of them at 900s (`700:72`, `710:98`, `720:52`). An earlier
count of "16 case files" was files *mentioning* `it_wait`, not calling it — the
Host Agent's correction, verified here.

**Deliberately not fixed inline.** A new primitive with 20 callers is its own
increment, and the validation needs the integration corpus, which needs a
daemon. Sketch, so the increment starts from a position rather than a blank
page: a companion that separates the two outcomes — a `never` predicate
evaluated alongside the `not yet` one, or a returned reason code — so a
permanently-false condition fails fast and REPORTS that it did, rather than
being billed the full ceiling and read as a hang.

---

## F57 — ADDENDUM 2026-08-21: the fix is not a new primitive, and the case headers already said so — **RESOLVED, CONFIRMED ON A REAL DAEMON**

F57 proposed a companion primitive that could express "never". Before building
it, two things were read that changed the answer.

**FIRST: at these three call sites there is nothing to wait for.** `entrypoint.sh`
runs `run_agent_tools_reconcile` and then `link_agent_tools` **synchronously** —
once per mode, at 239-240, 285-286 and 307-308 — and only then does `exec capsh`
hand pid 1 to the sandbox user. `launcher_up` returns only after
`_it_pid1_is_uid` observes that handover. So by the time `it_wait 900` runs, the
reconcile has already finished. The condition is not "not yet decided"; it is
decided, and the ceiling can only ever be spent confirming it.

**SECOND, and this is the uncomfortable part: all three case headers already
say this.** 700's says the condition is "already permanently decided, and
it_wait has no way to know that; it will poll its own full 900s before giving
up". 710 and 720 both call the wait "the redundant wait". The mechanism F57 was
filed to discover was documented in the cases themselves — and each header then
budgeted a full 900s ceiling for it anyway. **The defect was never that nobody
knew. It was that the knowledge sat in a comment while the code did the opposite.**

**The change: 900 → 10 at all three sites**, plus a message that stops lying.
The old one — `the agent-tools reconcile did not finish within 900s` — is FALSE
in 700's mutated run: the reconcile finished normally, the symlink was removed.
It now reads `claude is absent after the reconcile completed — entrypoint runs
it before handover, so this is not a timeout`.

Ten rather than zero because the argument above is a code read, and this project
has been wrong about read-derived mechanisms often enough to pay 10s for margin.

**No new primitive, no engine change, and `it_wait`'s other 17 call sites are
untouched** — so the "20 callers" risk F57 was deferred for does not arise.

**Case timeouts (2100 / 2400 / 2000) are deliberately NOT re-tightened.** The
compound bounds drop from ~1800 to ~910-950, but a declared timeout is a hang
detector, not a cost estimate — F36's 403-minute projection against a measured
42 is the lesson. Their derivation arithmetic is updated; the values stand.

**CONFIRMED ON A REAL DAEMON, 2026-08-21**, both parts, by the Host Agent.

*Part 1 — unmutated must still pass.* All three do, and **none failed at the 10s
wait**, which was the falsifier: nothing resolves after the capsh handover.

| case | run.sh case time | verdict |
|---|---|---|
| 700-agent-tools-install-restricted | 93s | PASS (12 assertions) |
| 710-agent-tools-reused-not-reinstalled | 87s | PASS (3 assertions) |
| 720-node-multiversion-nvm-use | 82s | PASS (3 assertions) |

*Part 2 — mutated must still FAIL, faster.* `700-agent-tools-not-linked` applied:
**FAIL, exit 13, 73s case time / 86s wall**, against **1003s** before. The new
message fires as the FIRST assertion rather than as a timeout at the end:

```
FAIL: claude is absent after the reconcile completed — entrypoint runs it
      before handover, so this is not a timeout
```

**−917s, and the number is the evidence.** The saving is not merely "large": it
equals the ~900s the old `it_wait 900` was predicted to spend confirming a
settled condition. A diagnosis whose predicted waste matches the measured saving
to within ~2% is confirmed, not just consistent.

**A cost INVERSION was removed, which nobody had named.** Under the old code the
mutated run (1003s) cost 5x the healthy one (198s) — a failing test more
expensive than a passing one, so every demonstration of this case was billed for
the assertion working correctly. It is now 86s against 198s: the failing run is
cheaper, because it stops at the first assertion instead of reaching the
six-tool loops.

**The durable half of the fix is the message, not the 917s.** "…so this is not a
timeout" tells a future reader the condition was already decided, which means the
answer is never "raise the ceiling" — the change that would reintroduce exactly
this defect.

**Not run in mgd-ai-containers, deliberately.** Every component of the mechanism
is byte-identical across the repos — `entrypoint.sh`, `lib.sh` (`launcher_up` /
`_it_pid1_is_uid`) and all three case files — so the only thing a second run
could catch is a layout difference in code that is not layout-dependent. mgd's
nightly runs `packages-agents`/`packages-native`, so those three cases execute
there anyway at no marginal cost.


---

## F32 — 2026-08-21, second investigation: three mechanisms refuted, one measured, one NEW instance caught

The trigger is **still unidentified**, and this entry does not guess either. What
it does is narrow the space and make the next occurrence answer for itself.

### Refuted, each cheaply

1. **A straggler with a delayed action.** `wait "$pid"` returns when the oracle
   DRIVER exits, not when its process group is empty — so a `( sleep N; rm … ) &`
   left behind could fire into a re-seeded tree. Instrumented over one
   264-mutant run at `--jobs 12` on a loaded machine: **97 of the invocations
   left stragglers, 739 processes in total — and every one was a bare `sleep`
   whose parent shell had already exited.** Orphans run nothing after they wake,
   so this is not it.
2. **A tree rebuilt under a running oracle.** `fr_seed_slot`'s `rm -rf` + `cp -a`
   is the only window in which a tracked file is genuinely ABSENT — but it runs
   only when the fingerprint says the oracle left debris, and that run recorded
   **zero `NOTE|reseed`**.
3. **Two concurrent instances colliding on a shared path.** The same oracle does
   run in up to 12 slots at once, but neither failing test has a fixed path:
   everything is under `$REPO_DIR` (per-slot, isolated) or a per-process
   `mktemp -d`.

Startup seeding was already ruled out by the code: the parallel `fr_seed_slot`
loop is followed by `wait` and a per-slot existence check.

### Measured, and acted on

The process group is **not** drained when `wait` returns. The orphans are not
the trigger, but they are self-inflicted load on a tier whose open findings are
about load-sensitivity — up to 30s of residual processes per invocation across
12 slots. `falsify_run_oracle` now TERMs its own group after `wait`; the group
is this invocation's by construction and the driver has already exited, so
anything left in it is an orphan.

**Peak concurrent orphaned `sleep`s over a full corpus run: 556 → 116** (a second
run of the new code gave 149). Both runs `TOTAL|9|264|262|2|0|0|0`,
`CONTROLS|18|0`.

### Reproduction attempt, stated with its bound

Both failing oracles were run concurrently under 8 CPU burners on Linux. **12
runs completed before the attempt hit its time budget; all 12 were clean.** That
is not "does not reproduce on Linux" — it is twelve samples of a failure whose
only recorded occurrence is on macOS.

### The next occurrence now names its own trigger

One fact splits the hypothesis space in half and the recorded occurrence could
not supply it: was the **source** gone (the worker tree evaporated under a
running oracle) or the **destination** gone (the test's own `mktemp -d` went
away)? Both guards now print it on the same `SCAFFOLD-FAILED:` channel —
source existence and size, tree existence, tmp existence, and for the shim
whether the LINK exists separately from its TARGET, since `-e` follows symlinks
and the two are different findings. Demonstrated in both shapes.

---

## F58 — `git ls-files` returned NOTHING under full-suite load, and two checks called it a code defect — **GUARD FIXED; the TRIGGER is still unidentified**

Caught while investigating F32, in a full `run-all.sh`:

```
── test-bash-floor.sh
   FAIL  (exit 2)
     FAIL: the floor is defined in 0 files — it must be exactly one
     FAIL: checked 0 entry points — the derivation matched nothing
```

Both assertions derive from `git ls-files '*.sh'`, and it had returned **empty**.
The same command run seconds later listed the files correctly, and the test
passed standalone and through `run-all.sh` immediately afterwards.

**Zero tracked `*.sh` is impossible in a healthy checkout**, so both messages
state something FALSE about the code: they report a missing floor definition and
an unreachable entry-point set when the truth is that a scaffold step produced
nothing. That is F31/F32's family exactly — an unchecked derivation reading as
an assertion failure — and on a mutant it would be a **false KILL**.

**Not introduced by the `git ls-files` fix**, and the entry says so rather than
letting the timing imply it: the entry-point check has used this same derivation
since long before that fix; the floor count became a second consumer of it. What
the fix changed is that there are now two ways for one empty derivation to show.

**Fixed:** one derivation, guarded once. An empty result is now
`SCAFFOLD-FAILED:` and the file exits, rather than two assertions failing.

Demonstrated with a `git` shim whose `ls-files` returns nothing, run from the
same location so `REPO_DIR` resolves identically (a first attempt that ran the
old copy from a scratch dir was invalid and is not the evidence here):

| | assertion failures | `SCAFFOLD-FAILED:` lines |
|---|---|---|
| before | **2** — the exact pair seen in the wild | 0 |
| after | 0 | **1** |

**The trigger of the empty `ls-files` is itself unidentified**, and is left that
way deliberately: it was seen once in five full-suite runs, and the guard turns
the next occurrence into a named scaffold event instead of a false statement
about the code. Whether it shares F32's root cause is unknown — the two share a
shape, not a proven mechanism.

---

## F30/F32 — a fourth sighting, in CI, with a diagnosis nobody could use — **OPEN: needs a recurrence; the diagnostics are in place and will name the half that failed**

`mgd-ai-containers` PR #76, GitHub Actions run 32523718531, 2026-08-21. One of
eighteen control runs failed on a diff that touched a documentation page and two
comments — nothing the oracle reads:

```
falsify: control output: FAIL: p_md5 returned empty — comparisons using it
                               would pass vacuously
falsify: control output: FAIL: p_stat_meta returned empty …
ERROR: 1 of 18 control run(s) FAILED: the PRISTINE oracle went red under this
       run's own load
```

**The corpus measured normally in the same run** — `TOTAL|9|264|262|2|0|0|0`,
identical to a local run on the same commit — and a re-run of the same job
passed in 6m52s. So: intermittent, load-dependent, and the control machinery did
exactly its job, refusing to trust a kill count it could not vouch for.

**A NEW SHAPE.** Every earlier sighting was a missing file reported as
`No such file or directory`. This one is two portability helpers returning
EMPTY, which is a different symptom of possibly the same cause — and the report
could not say which, because both helpers hide their own failure:

* `p_md5` and `p_sha1` are PIPELINES — `md5sum "$1" | cut -d' ' -f1`. A failing
  `md5sum` still leaves `cut` succeeding with empty output. No error, anywhere.
* `p_stat_meta` writes to stderr and leaves stdout empty.

Both went empty in the same instant, which *suggests* the scratch file was gone
— F32's trigger — but nothing in the output distinguishes that from "the tool
failed on a file that is right there". Fixed the way the scaffold guards were:
`tests/test-portability.sh` now prints whether the file exists, its size, and
the helper's own stderr, so the next occurrence separates the two.

**Also worth recording: the same run showed what a red oracle COSTS the tier.**
While `tests/test-integration-shim.sh` was red for an unrelated reason (a stale
pinned line number), its target was SKIPPED, and the corpus reported
`TOTAL|9|235|233|2|0|0|0` with `CONTROLS|16|0` — 29 fewer mutants and two fewer
controls, with no failure of its own. `SKIPPED|` lines say so (F54), but a
reader watching only `TOTAL` sees a green run that measured 11% less.

---

## F28 — CAUSE FOUND 2026-08-21: a 120s clock against a three-oracle target

Measured on the host, a controlled 2x2 on one machine, same code, same day:

| | `timeout=120` | `timeout=600` |
|---|---|---|
| `jobs=8` | 4 unproven, **2** controls red, 35.5 min, FAIL | 0 unproven, **0** controls red, ~6 min, PASS |
| `jobs=18` | 7 unproven, **4** controls red, 28.6 min, FAIL | — |

**The clock moves the outcome; the job count only moves its severity.** Halving
`--jobs` took the run from four failed controls to two and cost seven minutes.
Raising the clock took it to zero.

**The damage is one target, and it is the only one with a SET of three oracles.**
`tests/lib-verify-repo.sh` — `test-lib-verify-repo.sh,test-verify-exit-code.sh,
test-layer-containment.sh` — timed out **42 of its 55 mutants** and accounted for
every unproven verdict, while all eight single-oracle targets recorded zero
timeouts and zero unproven in the same run. Two of its PRISTINE controls ran
**132.8s and 156.0s against a 120s clock**, with the machine only half-loaded: an
unmutated oracle cannot finish inside the budget, so no amount of load
management fixes it.

The same ratio is visible on Linux, far below the ceiling: ~2.6s per mutant for
that target against ~0.78s for a single-oracle one. Three oracles, three times
the work.

**FIXED by deriving the clock rather than tuning it.** `fr_effective_timeout`
multiplies `FR_TIMEOUT` by the number of oracle files in the target's set, so
the three-oracle target gets 360s where a single-oracle target gets 120s.
Derived from the set, not configured per target: nothing has to be remembered
when a target gains or loses an oracle. This is F36's lesson applied — a
declared timeout is a HANG DETECTOR, not a cost estimate, and one ceiling cannot
be right for a 5-second target and a 200-second one.

**What this does NOT establish.** The process-group drain shipped the same day
cannot be credited from these runs: the only green run predates the comparison
and used both a different clock and a different job count. Unproven fell
14/35 (F28's original baseline) to 7 to 4, which is the right direction and not
attributable.

---

## F59 — `--jobs auto` reads the HOST's CPU count, not the Docker VM's

Found while measuring F28. On macOS + Colima, `jobs=auto` resolved to **18** —
`hw.ncpu` — while Colima holds **12** of those CPUs for the Docker VM the tier's
own oracles run against. The tier took every CPU on the machine and then
competed with the VM it depends on.

**This is F38's other half.** F38 fixed `nproc` reading an affinity mask inside a
quota'd container. This is the same mistake from outside: the number the host
reports is not the number available to the work.

Measured cost: at `jobs=18`, four of eighteen pristine controls went red and the
run took **28.6 min**; at `jobs=8` on the same machine and commit, two went red
and it took **35.5 min**. Slower and better — the oversubscribed run was buying
wall clock with trustworthiness.

**Not fixed, and the reason is that the right number is not derivable from the
host.** A macOS host cannot see how many CPUs Colima or Docker Desktop reserved;
`docker info` reports the VM's own view, which is a daemon round-trip the runner
does not currently make. The options are to ask the daemon, to cap `auto` at
some fraction of `hw.ncpu`, or to document `FALSIFY_JOBS` as required on macOS.
Recorded rather than guessed at.

---

## F60 — `c-toolchain=ON` alone is CONFIRMED IN THE FIELD and UNGUARDED by a case — **CLOSED 2026-08-22 BY CONSTRUCTION, no fourth variant**

Not a doubt about whether it works. It does — confirmed twice on 2026-08-22, by
the user directly (`gcc` present and working in a container) and by the agent
working on the dtmgd Go CLI, the same use case whose failure produced the key:

```
cgo: C compiler "gcc" not found: exec: "gcc": executable file not found in $PATH
```

**Both halves are demonstrated automatically; only their composition is not.**

| step | demonstrated by |
|---|---|
| the key → the build arg | `tests/test-db-clients.sh`, four fixtures, both directions (dropping the new arm loses the ON case; making it unconditional loses both OFF cases) |
| the build arg → a toolchain in the image | integration case `730-native-clients-run` asserts `gcc` and `/usr/include/yaml.h`, and mutation `735-toolchain-not-restored` demonstrates that assertion failing |
| **the key alone, with nothing else set** | **nothing** |

The gap exists because the `native` variant obtains the toolchain through
`db-clients` and `ruby` regardless, so an assertion there would pass whatever
the `c-toolchain` key did. Isolating it needs a **fourth image variant** built
solely to exercise one boolean — a nightly image build, per run.

**Recorded as UNGUARDED rather than unverified, and deliberately not bought.** A
regression would have to break one of the two demonstrated halves to reach a
user, and the field confirmation says the composition holds today. Revisit if
someone reports setting `c-toolchain=ON` and finding no compiler — at which
point the variant is justified by evidence rather than by symmetry.

### CLOSED 2026-08-22 — the join needed an argument, not an image

The fourth variant was never necessary, and the reason is one line of the
Dockerfile: **the toolchain decision reads exactly one input, the
`KEEP_BUILD_TOOLCHAIN` build arg.** That layer cannot know, and does not ask,
which key set it.

So the two demonstrated halves compose without anything further being built:

```
c-toolchain=ON alone  ──►  KEEP_BUILD_TOOLCHAIN=1   (test-db-clients.sh, fixture 3)
KEEP_BUILD_TOOLCHAIN=1 ──►  a working gcc            (case 730 + mutation 735)
```

The middle term is the same variable in both rows. Nothing between them varies
with `db-clients` or `ruby`, so the composition holds for **every** key that
sets the arg — including keys added later, which a variant built today would
not have covered. That is a stronger guarantee than the variant, at no build
cost.

**What the argument depends on is now asserted**, because an argument that
nothing checks decays into a comment. Three assertions in
`tests/test-db-clients.sh`:

| assertion | catches |
|---|---|
| the retention layer is guarded by `KEEP_BUILD_TOOLCHAIN` | the condition changing shape — which would make the next assertion match nothing and pass vacuously |
| no toolchain decision is conditioned on db-clients or ruby | the retention being coupled to another key again, the only way the join comes apart |
| every purge of `build-essential` is conditioned on the arg | a purge added elsewhere stripping the toolchain behind the key's back |

Demonstrated, all three: coupling the retention to `$DB_CLIENTS` reddens the
second; adding an unguarded `apt-get purge build-essential` reddens the third;
rewriting the condition as `test "x$KEEP_BUILD_TOOLCHAIN" = "x1"` reddens the
first **while the second passes** — which is precisely the vacuity the first one
exists to catch.

**Two stale comments fixed on the way.** The Dockerfile said the arg was "set by
build.sh for ruby OR db-clients" in two places. `c-toolchain` has set it since
the key was added, and the file whose behaviour depends on the arg was
describing the wrong set of triggers.

**The scope limit, stated.** This closes the composition, not the field. Nothing
here builds an image from `c-toolchain=ON` alone; if the retention layer itself
regressed, case 730 in the `native` variant is what would catch it, and it does.

The general shape is worth keeping: **six components are enabled by no variant
at all** — `goreleaser`, `qmd`, `acli`, `angular-cli`, `pnpm`, `bun` — so
nothing builds them and no case can assert them. That is a cost boundary of the
three-variant design, not an oversight, and the same question applies to each.

---

## F28 — CONFIRMED ON THE HOST 2026-08-22, and the residue named — **FIXED**

Phase 6 re-run at defaults on `6cddfce` (`FALSIFY_JOBS`/`FALSIFY_TIMEOUT` both
unset, banner `jobs=18, timeout=120`), against the same machine's pre-fix
baseline:

| | killed | unproven | timeouts | unresolved | controls red | wall |
|---|---|---|---|---|---|---|
| before (`jobs=18`, flat 120s) | 254 | 7 | 43 | 3% | 4 | 28.6 min |
| after (`jobs=18`, 120s x oracles) | 261 | **0** | 34 | 1% | 2 | 41.5 min |

`tests/lib-verify-repo.sh` — the three-oracle target the cause was found on —
went to **55 mutants, 55 killed, 0 unproven**. Every mutant now carries a
verdict. The extra 13 minutes is the previously-truncated oracles running to
completion, which is the fix working rather than a cost.

The two controls still red were both `lib-verify-repo`, at **445.8s and 430.1s
against its scaled 360s clock** — so the clock was necessary and NOT sufficient.
That residue is F59, and the run below isolates it.

**A third survivor on macOS is not a regression.** Linux scores 262/2 and macOS
261/3, and the difference is entirely
`tests/portability.sh:cond-negate:4fcb6275…`, whose ledger entry has said since
2026-08-16 that it is KILLED on Linux and SURVIVES on a mac carrying both digest
tools. The other two are the single `tests/lib-layer-checks.sh:logic-flip:b6554f5a…`
identity, which yields two mutants — verified with `generate.sh`, not assumed.
Both macOS runs land on exactly the ledgered set.

---

## F59 — ISOLATED 2026-08-22: oversubscription, measured on one pristine oracle

The clean discriminator, both runs on `6cddfce` with the scaled clock, only
`--jobs` differing:

| | timeouts | controls red | `lib-verify-repo` controls | wall |
|---|---|---|---|---|
| `jobs=18` | 34 | 2 | 445.8s / 430.1s — FAIL | 41.5 min |
| `jobs=8` | **0** | 1 (a different target) | **251s / 244s — PASS** | 43.4 min |

Halving the jobs with the clock untouched cut the SAME pristine oracle's runtime
by ~44% and took every one of the nine targets to zero timeouts. That is
oversubscription measured directly rather than inferred, and it is the evidence
this entry was waiting for. The earlier numbers here (4 red at 28.6 min vs 2 red
at 35.5 min) predate the F28 fix and confounded the clock with the load; these
do not.

### FIXED 2026-08-22: the number IS derivable, and it was the core MIX

The host's topology, measured rather than assumed:

| | |
|---|---|
| `hw.ncpu` | 18 |
| `hw.physicalcpu` | 18 (no SMT — all 18 are real cores) |
| `hw.perflevel0.logicalcpu` | **6** — performance cores |
| `hw.perflevel1.logicalcpu` | 12 — efficiency cores |
| `docker info` NCPU | 12 |

`hw.ncpu` counts twelve efficiency cores as equals against six performance ones,
which for oracles that spend over half their wall time creating processes they are
not: `tests/bash-dialect-lint.sh` costs 3.7-5.2s idle against 2.2s of user+sys, so
under half of it is computation.

Both candidate derivations give **6** on this machine — `hw.perflevel0.logicalcpu`,
and `hw.ncpu` minus the VM's 12. They cannot be told apart here, and that agreement
is a coincidence of one configuration rather than evidence they agree in general.
The P-core cap was chosen on independent grounds: derivable from `sysctl` alone, no
daemon round-trip inside an otherwise hermetic runner, correct when Docker is not
running at all, and it names the real constraint — the workload, not a co-tenant.

`fr_cpu_budget` now takes the minimum of the reported count, the cgroup quota, and
the performance-core count. Each narrows and none widens, so a probe that returns
nothing costs nothing, and Linux — which has no performance levels — is unchanged.

**This is F38's third face.** F38 fixed `nproc` reading an affinity mask inside a
quota'd container; this entry's first half was the host count ignoring a VM's
reservation; this is the count treating unequal cores as equal. Every one of them is
the same error: the number the OS reports is not the number available to the work.

### The original recording, kept

Still not fixed at the time of writing, and the reason given was that **the right
number is not derivable from the host.** `hw.ncpu` reports 18; Colima holds 12 for its VM;
neither figure is "CPUs free for this tier". The options remain (a) ask the
daemon — `docker info` knows its own NCPU, at the price of a round-trip and a
dependency in an otherwise hermetic runner, (b) cap `auto` at a fraction of
`hw.ncpu` on Darwin, which is a guess with a friendlier failure mode, or
(c) document `FALSIFY_JOBS` as required on macOS and warn when it is unset.

---

## F61 — the per-mutant clock counted SLEEPS, not seconds (FIXED)

`falsify_watch_until` was `for (( i = 0; i < secs; i++ )); do kill -0; sleep 1;
done`. One iteration is a sleep PLUS a fork, a `kill -0`, and whatever the
scheduler adds, so on a loaded machine the ceiling stretches by exactly the load
it exists to bound.

**Field evidence, from the jobs=8 run above:** a pristine control of
`tests/bash-dialect-lint.sh` — a single-oracle target, so a 120s ceiling — was
recorded at **132.2s having exited on its own**, not having been cut. The run
reported `timeout=120` and enforced 132.

Why it matters beyond tidiness: every timeout and unproven count is then a
function of the machine, two runs at "the same clock" are not comparable, and
the numbers used to judge F28 and F59 were themselves ~10% off in the direction
that flatters them.

**Fixed** by fixing the deadline once from `fr_now_us` (EPOCHREALTIME) and
polling against it. Demonstrated by stubbing both the clock and `sleep` and
reading the POLL COUNT — deliberately not a wall-clock margin, because a
timing assertion inside an oracle is the F62 defect: `tests/test-falsify-run.sh`
§16, "the ceiling is reached in elapsed time, not in sleeps" (60 polls before,
6 after) and "a poll that returns early does not spend the budget" (2 before,
20 after).

---

## F62 — a `p_timeout` that `fail`s on expiry converts SLOWNESS into a FALSE KILL (FIXED)

The one error this tier cannot detect from its own output, found in its own
oracle set.

`tests/test-bash-dialect-lint.sh` bounded its whole-tree run at a flat 30s and
called `fail` on expiry. Under `run.sh` a `FAIL:` line is a KILL — so an
overrun credits the oracle with catching a mutation it never noticed. The
mutant leaves the survivor set, `check-ledger.sh` never demands an entry, and
the gap becomes invisible. That is F30's shape, arriving through a clock
instead of through contamination.

Not hypothetical: on macOS + Colima at `--jobs 8` (2026-08-22) the **pristine**
file blew the 30s bound and went red, while the second control of the same run
passed in 8s — a 16x spread inside one run. Only the control mechanism made it
visible, which is precisely what controls are for.

**Why the bound was reachable.** It was flat where the cost is relative:
measured in-container, a single-file lint is ~6ms and the whole tree (141
scripts, one startup shared) ~580ms — a ratio of **97x** — yet the tree run was
given only 3x the single-vector bound of 10s. The two costs move together on a
loaded machine; the ratio is the stable quantity, not either number.

**Fixed** by deriving the bound from the WORST single-file lint the same process
measured (`unit_ms * 300 / 1000`, floor 30s) — 3x the observed ratio, and it
tracks the machine automatically, the same shape as F28's fix. Deliberately NOT
capped against `run.sh`'s per-mutant ceiling: on a host loaded past that point
the honest outcome is the oracle hitting the ceiling and the mutant scoring
UNPROVEN, and a cap would trade that for the false kill this entry is about. A
hang is infinite and trips any bound, so F22's kill survives wherever the
machine is fast enough to measure at all.

Demonstrated on fixed inputs, because on a healthy machine the live run lands on
the floor and looks exactly like the constant it replaced: "a 50x slower machine
gets a 50x bound, not the same 30s" (30s before, 90s after) and "the bound
tracks the measured cost, with no ceiling above it" (30s before, 300s after).

**The other four `p_timeout` sites that `fail` on expiry were checked, not
assumed:** `vector()`'s 10s, the floor-reading 10s and the empty-repo 10s in the
same file, and `tests/test-integration-shim.sh`'s 10s. Each bounds a
single-invocation cost of a few milliseconds — headroom of ~1600x against the
97x that was not enough here — so each is left alone. The rule this entry
establishes is about the RATIO, not about the presence of a bound.

---

## F63 — the watchdog paid three FORKS a second to find out what time it was — **FIXED**

Found in the host's raw `CONTROL|` records for the F61/F62 run, which the summary
had hidden inside a single number.

```
RUN|…|jobs=18|timeout=120|…
CONTROL|FAIL|tests/bash-dialect-lint.sh|test-bash-dialect-lint.sh|1|timeout|152603
CONTROL|FAIL|tests/bash-dialect-lint.sh|test-bash-dialect-lint.sh|2|timeout|149972
BASELINE|tests/bash-dialect-lint.sh|test-bash-dialect-lint.sh|PASS|10945
TARGET|tests/bash-dialect-lint.sh|test-bash-dialect-lint.sh|27|26|0|1|9|168484
```

A **120s** ceiling, and the control recorded at **152.6s** — while `tools-lib`
overshot by 0.2-0.3s and `lib-verify-repo` by 1.0-2.8s in the same run. One
target out of nine, and the ~32s is not a rounding difference.

**It cannot be the kill.** After the watchdog fires it sends TERM, waits one
second, then SIGKILL, which nothing can ignore — so everything after the fire is
bounded at a second or two. The lateness is therefore BEFORE the fire: the
watchdog did not get scheduled.

**Why that target.** `falsify_watch_until` polled once a second, and each poll
cost three forks — two command substitutions around `fr_now_us`, plus
`/bin/sleep`. Per in-flight oracle. `tests/bash-dialect-lint.sh` is the most
fork-heavy oracle in the corpus: it scans 141 tracked scripts, and its 10.9s
BASELINE against 2.2s of user+sys means over half its wall time is process
creation rather than computation. Its watchdog was competing for exactly the
resource whose exhaustion it existed to measure. The other eight targets never
saturate forks, so their watchdogs stayed accurate.

**The `BASELINE|` record is what made this legible** and it had never been
surfaced before: 10.9s pristine against a 120s ceiling proves the oracle is not
the problem, and 14x that under 18-way load proves the contention is.

**A hypothesis tested and discarded first.** Before reading the raw lines, the
same lateness was attributed to the polling loop being slow in general. Measured
in-container: a 10s budget under a 24-way fork storm on 12 CPUs returned 10.0s
(as shipped) against 10.9s (fork-free) — a 9% overshoot at 2x oversubscription,
nowhere near 27%. That result did not survive, and the entry records it because
"the loop is slow" and "the loop is slow WHERE THE ORACLE FORKS" are different
claims with different fixes.

**Fixed** two ways, both cheap:

- `EPOCHREALTIME` read into a variable instead of through a subshell, and the
  one-second wait taken as a `read -t 1` on a fifo opened READ-WRITE — which
  never reports EOF and has no writer, so the read blocks for exactly its
  timeout inside the shell. The poll now forks **nothing**. A host that cannot
  create a fifo falls back to `sleep 1`, bounded rather than spinning.
- Every timeout now records **how late the watchdog noticed**, beside the flag
  rather than inside it (`falsify_flag_is_mine` compares the flag's whole
  content to the token, so a second field there would make every timeout
  foreign). A failing control prints it as a `NOTE|control-clock|` record, so
  "the oracle overran" and "the watchdog ran late" stop being indistinguishable
  — the ambiguity that cost a day here.

Demonstrated: "the one-second wait forks nothing when a fifo can be opened"
(forked → no-fork), "a timeout records how late the watchdog noticed" (empty →
3000ms on a fake clock), "a watchdog that fires on the deadline reports no
lateness" (empty → 0), and the fallback asserted in the opposite direction so a
broken `mkfifo` still yields a bounded wait.

**What this does NOT claim.** That the 32s is fully explained. The deduction
bounds it to the pre-fire path and the fix removes the only per-poll cost there,
but the next host run is what confirms it — and it will now say so in a number
rather than leaving it to be inferred.

---

## F59 — FOLLOW-UP: the fix was verified on Linux, and was red on macOS the whole time — **FIXED**

Reported by the Host Agent on 2026-08-22, from a real checkout on the host:

```
FAIL: no quota: the budget is what the OS reports (expected '18', got '6')
FAIL: a quota larger than the machine does not inflate the budget (expected '18', got '6')
```

`tests/test-falsify-run.sh` pinned `fr_cpu_budget` against `fr_host_cpus` — the
number the OS reports. F59 capped the budget at the PERFORMANCE-core count, so
on Apple Silicon the OS reports 18 and the budget is 6, and both assertions went
red. On Linux there are no performance levels, the cap never binds, and both
stayed green: **every gate run before shipping was blind to it by construction.**

The §17 assertions added WITH F59 stub `sysctl` and are machine-independent by
design. These two predate it and read the real machine. The lesson is not "run
the tests on macOS" — it is that an assertion which reads the host cannot pin
behaviour that depends on the host's topology, and the fix belongs in the
stubbed section that can fix the topology instead of reading it.

**The second assertion was worse than stale.** It is about cgroup-quota
handling; once it fails on the baseline number it can no longer be evaluated for
the property it was written to check. A stale expectation had **disabled a
distinct guard** — the Host Agent's observation, and the sharper half of the
finding.

**Fixed** by asserting the properties that hold on every machine: the no-quota
budget is a positive integer never above what the OS reports, and a quota larger
than the machine leaves the budget UNCHANGED — compared against the no-quota
budget rather than against a constant, so it still fails an implementation that
hands out the quota. Demonstrated by simulating a 6-performance-core machine in
`fr_perf_cpus`: the old pair reproduces the host's failure verbatim, the new
pair passes.

**Also retracted here, because it was recorded as measured:** the
`test-falsify-historical` "flakiness in both repos" was one methodological error
made twice, not two observations. Those baselines ran inside `git worktree`
checkouts, where `.git` is a FILE, and that test refuses to run without a real
work tree — it failed deterministically and said so. It is not flaky. The
investigation it prompted was not wasted: it found a genuinely vacuous isolation
check (an assertion that could not fail) in the same file, fixed separately.

---

## F30/F32 — TWO RECURRENCES IN ONE HOUR, and the diagnostic could not reach the report — **OPEN, but the channel is fixed**

2026-08-23. The entry said "needs a recurrence". It got two, forty minutes apart,
both on `tests/portability.sh`, both pristine-oracle failures under the tier's
own load.

**One, in CI** (ai-containers `main`, run 32635611521, the falsify job):

```
falsify:   control output: FAIL: p_sha1 returned empty — comparisons using it would pass vacuously
falsify:   control output: FAIL: p_md5 returned empty — comparisons using it would pass vacuously
falsify:   control output: FAIL: p_stat_meta returned empty — comparisons using it would pass vacuously
ERROR: 1 of 18 control run(s) FAILED
```

The corpus itself scored `TOTAL|9|264|262|2|0|0|0` — identical to a quiet
in-container run. Only the control went red. A re-run of the same job passed, so
the failure is load-dependent, not a regression from the commit under it.

**Two, locally**, in the very next corpus run, immediately after a full
`run-all.sh` had loaded the machine: the same oracle's BASELINE went red
(`rc=0, signal=failline`), so the whole target was skipped —
`SKIPPED|tests/portability.sh|test-portability.sh|13|baseline-not-green`,
`UNATTEMPTED|1|13|264`, `rc=1`. The harness handled that correctly: the skip is
named, the true denominator is printed, and the run fails. Nothing to fix there.

**The one fact that survived, and it is a real clue.** In CI the loop
`for h in p_stat_mode p_sha1 p_md5 p_stat_meta` reported **p_stat_mode passing
and the other three failing** — and p_stat_mode is FIRST. So the fixture was
readable at the first call and not for the three after it. That points at the
file or the directory going away mid-loop rather than at any one tool failing,
which is F32's "unguarded scaffold write" shape rather than a portability bug.

### The diagnostic existed and could not be seen — FIXED

`tests/test-portability.sh` has carried, since 2026-08-21, two `diag:` lines
written for exactly this: is the file gone, or is the tool failing on a file
that is right there? CI printed **three FAIL: lines and not one diag line**.

The cause is a stream mismatch. `fail()` writes to **stdout**; the diags were
written to **stderr**. The harness captures an oracle with `> "$out" 2>&1` and
`fr_run_control` keeps a `FAIL:` line plus the indented lines **immediately
following** it. stdout to a file is block-buffered and stderr is not, so the
diagnostic is flushed out of order, stops being adjacent to the FAIL: it
explains, and is dropped by the very mechanism meant to carry it.

Fixed by putting the diags on stdout, guarded by an assertion on this file's own
text — the property is invisible from inside a passing run, because the diag
lines only appear when a helper fails and by then the reporter has already
decided whether it could attach them. Demonstrated by putting one back on
stderr.

### And a process failure worth recording

The CI logs for the first recurrence are **gone**, because the re-run was
triggered before they were saved. `gh run rerun` replaces them. The evidence
this entry had been waiting weeks for was destroyed by the command used to find
out whether it was reproducible. **Capture the log before re-running anything.**

---

## F64 — F30/F32's fifth sighting, and the field that finally separates the two candidates — **`dir=n`: the whole scratch directory was gone. FIXED 2026-08-30 — reproduced, mechanism identified, guard added**

`ai-containers` PR-gate run
[33245548932](https://github.com/ihudak/ai-containers/actions/runs/33245548932),
2026-08-29, on `189ebda` (a push to main). Log captured **before** any re-run,
per the warning at the end of F30/F32's fourth-sighting entry.

```
ERROR: CONTROL FAILED — the PRISTINE oracle went red under this run's own load
       (signal=exit+failline, 1.3s): tests/portability.sh via test-portability.sh.
       Kills recorded near it cannot be trusted.
falsify:   control output: FAIL: p_stat_mode returned empty … [fixture=/tmp/tmp.tneErmsnvo/f
           dir=n exists=n size=? left=0 | p_stat_mode stderr: stat: cannot statx
           '/tmp/tmp.tneErmsnvo/f': No such file or directory]
falsify:   control output: FAIL: p_sha1 returned empty …      [same fields]
falsify:   control output: FAIL: p_md5 returned empty …       [same fields]
falsify:   control output: FAIL: p_stat_meta returned empty … [same fields]
ERROR: 1 of 32 control run(s) FAILED …
TOTAL|16|548|538|10|0|0|1|641571
```

**This is the answer the fourth-sighting entry was parked waiting for.**
`tests/test-portability.sh` states the two remaining candidates and the one
field that separates them:

> `dir=n` something removed the whole scratch directory — a trap that fired
> early, or a cleanup that reached too far
> `dir=y` something removed this file specifically, or it was never written

This run reports **`dir=n`**, with `left=0`. So it is not targeted removal of the
fixture and not a fixture step that failed to write: **the entire `mktemp -d`
scratch directory was gone by the time the helpers ran.** The 2026-08-27 sighting
established `exists=n`; this one establishes which side of `exists=n` it is.

The diagnostic installed on 2026-08-21 did exactly the job it was added for, on
its second real firing, and the investigation can now drop the `dir=y` branch
entirely.

**What this does NOT settle.** Which of the two `dir=n` mechanisms — an early
trap or an over-reaching cleanup — is still open, and nothing here distinguishes
them. Note the shape of the run: 32 controls, one red, corpus measuring
normally (`548` mutants, matching a local run on the same commit), the tier
correctly refusing to vouch for kills near it. Same intermittent,
load-dependent signature as all four prior sightings.

**Bearing on recent work, stated so it is not assumed either way.** The
2026-08-29 releases (v0.9.2 and the review fixes after it) changed temp-directory
handling in three places — `run-all.sh` now gives each test its own `TMPDIR`
under one root it removes at exit, `it_cleanup` moved from a quoted `trap` to a
resource registry, and four tests stopped leaking their own `$TMP`. None of them
can be the CAUSE here: this run is `189ebda`, which predates all but the first,
and the four prior sightings predate every one of them. But they are edits to
exactly the mechanism this entry is chasing — an early trap, or a cleanup that
reaches too far — so the next sighting should be read against them rather than
assumed independent of them.

---

## F65 — `tests/run-all.sh` decides every verdict in the suite and is asserted on almost not at all — **FIXED 2026-08-29: shim half by test-run-all-shim.sh, verdict logic by test-run-all.sh**

Found by an adversarial review of v0.9.2 (2026-08-29). `run-all.sh` gained ~140
lines in that release — a per-test `TMPDIR`, a leaked-temp counter, and a
`mktemp` shim injected on `PATH` **for every test in the suite** — with no test
of any kind. It cannot get one from the mutation tier either:
`tests/falsify/targets.conf:277` excludes it deliberately, as the instrument the
tier measures with.

`tests/test-run-all-shim.sh` (added 2026-08-29) closes the shim half: it
extracts the shim from the heredoc rather than copying it, so the two cannot
drift, and it caught a real defect on arrival — `--tmpdir` was treated as a
generic flag, so the shim appended an absolute template and GNU refused it.

**Still uncovered, and this is the part that matters:** the runner's own VERDICT
logic. Nothing asserts that

* a test printing `FAIL:` while exiting 0 is reported FAIL (the `^FAIL:` guard —
  the very mechanism that hole #2 of the historical scorecard says makes that
  class catchable at all),
* `PASS` takes precedence over `SKIP` for a file that did both,
* a test exiting 0 having asserted nothing is reported FAIL, not PASS,
* the `left in TMPDIR:` counter fires, and names the test that leaked.

A regression in any of those does not read as "run-all.sh is broken" — it reads
as every other test's verdict being wrong, or as a green run that measured
nothing. That is precisely the failure class this repo built the falsify tier to
end, sitting in the one file the tier is not allowed to look at.

**Not fixed here** because the honest shape is a `tests/test-run-all.sh` that
drives the real runner over a synthetic corpus of planted tests (one that fails
loudly, one that fails silently with rc 0, one that asserts nothing, one that
skips, one that leaks a temp dir) and asserts the verdict for each. That is a
new test file rather than a mechanical edit, and it must not invoke `run-all.sh`
recursively — this repo's own glob would collect it.

---

## F64 ADDENDUM — every sighting happened in a configuration that no longer exists — **OPEN: the next sighting is a different experiment**

Established 2026-08-29, after F64 was filed, by following the failing run's
fixture path rather than its symptom.

**The path is the clue.** The failing control reported
`fixture=/tmp/tmp.tneErmsnvo/f` — a `mktemp -d` default template sitting
**directly under `/tmp`**. If the oracle had been rooted anywhere, the path
would have been nested. It was not, and the reason is that on `189ebda` nothing
rooted it:

| | at `189ebda` (and all 5 sightings) | on `main` today |
|---|---|---|
| falsify → oracle | inherits the host's `TMPDIR`, i.e. `/tmp` in CI | `export TMPDIR="$FR_SCRATCH/tmp"`, per run (`run.sh:822`) |
| `run-all.sh` scratch | none — only `log="$(mktemp)"` | `RA_TMPROOT`, one per invocation, under `TMPDIR` (`run-all.sh:76`) |
| a test's `mktemp -d` | **flat, in a `/tmp` shared by every parallel worker** | `$FR_SCRATCH/tmp/run-all-tmp.XXX/<test>/tmp.XXX` |

`git log -S` dates the first row precisely: the rooting arrived in **`6e5bfc7`**
(PR #160, merged 2026-08-29 14:43 UTC) — roughly three hours **after** the
`189ebda` failure this entry records, and after every earlier sighting. The
second row arrived in the same day's `3c2264f` / `352a2eb`.

**What this does and does not license.**

It does NOT say the bug is fixed. No mechanism was ever established, so nothing
here can be said to have removed one. What it says is narrower and checkable:
every sighting occurred while all parallel workers created their scratch
directories in ONE flat, shared namespace, and that namespace is gone. Two
concurrent oracles are now separated by three levels of per-run and
per-invocation nesting, so a collision or an over-reaching removal in a flat
`/tmp` — the shape `dir=n` describes — has no structure left to occur in.

**Consequently the prior evidence has a shelf life.** The five sightings
describe a configuration that cannot recur, so re-reading them for a mechanism
is now archaeology rather than debugging. The useful next datum is a **sighting
under the new regime**, which would mean the cause is something else entirely
and would be worth more than all five prior ones combined.

**If it does not recur, that is weak evidence, not a fix.** The failure is
intermittent at roughly one run in several days; silence for a week says little.
Close this only on a deliberate reproduction attempt under load, or leave it
open and let a recurrence reopen the question with better data.

**One thing that is NOT resolved by the nesting:** `$FR_SCRATCH/tmp` is still
shared by every worker WITHIN a run — `FR_SCRATCH` is one `mktemp -d` per run,
not per worker. Nothing removes it mid-run (`mkdir -p` before each oracle
launch; `rm -rf` only in `fr_cleanup` at the end), so it is not a live
candidate, but it is the one shared surface that survives and the first place
to look if this recurs.


**REPRODUCTION ATTEMPT 2026-08-29 — NEGATIVE, and the shared surface removed anyway.**

The flat namespace was deliberately restored — both rootings reverted in a
scratch tree, so oracles and their `run-all.sh` invocations shared one `/tmp`
exactly as they did at `189ebda` — and the tier run three times at `--jobs 12`
with `--controls 6` against `tests/portability.sh`, the target that failed.

**Result: 0 `dir=n`, 0 control failures, three for three.** The flat namespace
alone did not trigger it.

Read this narrowly. It does not exonerate the flat namespace and it does not
identify anything: the five sightings were on **Linux CI**, this attempt was on
macOS, where fork and filesystem behaviour differ; and three attempts is a small
sample against a failure seen roughly once in several days. Per this entry's own
rule — *"If it does not recur, that is weak evidence, not a fix"* — the entry
stays **OPEN**.

What did change is the surface named above. `$FR_SCRATCH/tmp` is no longer
shared: `falsify_run_oracle` gives each invocation `$FR_SCRATCH/tmp/$token`.
Per INVOCATION rather than per slot, deliberately — slots are reused across
mutants, so a per-slot directory would still be shared between a timed-out
oracle whose children outlive the `kill -KILL` and the next mutant dispatched
into that slot. This is removal of a wrong shared namespace, not a fix for
`dir=n`; nothing here licenses closing this entry.

**The reproduction that would still be worth running is on a Linux HOST** — CI's
falsify job is `runs-on: ubuntu-24.04` with no `container:`, so all five
sightings had the runner's real `/tmp`. A container would supply its own and
change the thing under test.
---

## F66 — a Phase 4 run leaves empty `IT_RUN_ID`-shaped directories in the real cache — **FIXED 2026-08-29: `probe_launcher` hung its PATH dir off `$IT_SCRATCH`**

Observed 2026-08-29 on a Linux host, after `PHASES="4" bash ./verify-on-host.sh`
against `0a9a129`. The run itself was clean — `36/36 passed`, no
`Permission denied`, no root-owned files — and afterwards
`~/.cache/ai-containers-it` held **eight empty directories**, 4.0K each, in two
bursts of four at three-second intervals, both inside the run's window.

**What is established:**

* Their names are `IT_RUN_ID`-shaped (`<UTC timestamp>-<pid>`), so something
  computed a fresh run id and created the DEFAULT `IT_SCRATCH`
  (`$HOME/.cache/ai-containers-it/$IT_RUN_ID`) eight separate times.
* They contain no `logs/`. That matters: `run.sh:891` is the only place that
  creates this path and it creates `$IT_SCRATCH/logs`, so these did **not** come
  from there.
* `run.sh` DOES `export IT_SCRATCH` (line 966), so an ordinary case inherits the
  run's own scratch and cannot produce one of these.

**Ruled out by direct measurement, not by reading:**

| Candidate | Result |
|---|---|
| the whole hermetic suite (`tests/run-all.sh`) | 0 directories |
| `tests/test-integration-runner.sh` alone | 0 |
| `tests/test-integration-lib.sh` alone | 0 — it redirects `IT_SCRATCH` to its own `$TMP` before its `mkdir` |
| `tests/integration/run.sh --list-caps` | 0 |

**Not established: what creates them.** Five probes did not find it. The two
bursts of four at a three-second cadence suggest four short-lived invocations
repeated once, which matches Phase 4's two capability-detection passes in
shape — but `--list-caps` on its own creates nothing, so that shape is a
coincidence until something demonstrates otherwise.

**Severity, stated honestly so nobody re-derives it:** functional but trivial —
the harness writes stray empty directories into the developer's real cache. No
data loss, no effect on any verdict, 4K each. It is filed because it is a known
defect and this file's rule is that a finding living only in a session log is a
finding that gets dropped, not because it is urgent.

**Cheapest way to close it:** it appears during a real Phase 4, which already
costs ~50 minutes, so it needs no run of its own. Whoever next runs Phase 4
should empty `~/.cache/ai-containers-it` first and check it afterwards; if the
directories reappear, bisect by watching the cache while running one tier at a
time with `--reuse-image` against an image that already exists.

**One unresolved timing note.** The full `verify-on-host.sh` run earlier the same
day, on `v0.9.2` before that day's later fixes, left **zero** such directories,
while the Phase-4-only run on `0a9a129` left eight. That is suggestive of a
change in between, but no mechanism connects them and the two runs differed in
more than the commit (whole script versus one phase), so it is recorded as an
observation rather than a lead.

---


**RESOLUTION 2026-08-29 — the source, and why five probes missed it.**

`probe_launcher` needs somewhere to hold one `docker` symlink for `PATH`. It used
`$IT_SCRATCH/launcher-probe`, so `mkdir -p` created the **scratch root** as a side
effect and the `rm -rf "$d"` at the end removed only the child. The parent it
left is exactly the observed artefact: empty, no `logs/`, `IT_RUN_ID`-shaped.

Permanent rather than transient for two compounding reasons, both in the entry's
own evidence and neither previously connected: `--list-caps` exits **before**
`run.sh` installs `trap 'sweep' EXIT` and before it creates `$IT_SCRATCH/logs`,
so nothing collects it; and each invocation computes a fresh `IT_RUN_ID` from
`$$`, so they accumulate one per call rather than overwriting.

**Why `--list-caps` measured zero in the table above.** `detect_caps` only
*attempts* `probe_launcher` when `--reuse-image` is set or
`docker image inspect "$IT_CAPS_IMAGE"` succeeds. A bare `--list-caps` on a
machine with nothing built never reaches the probe — so the probe that ruled it
out was measuring a path that does not run. The first regression test written
for this fix made the identical mistake and **passed against the unfixed code**;
it was the mandatory pre-fix demonstration that caught it, not review.

**How it was found:** by watching rather than reading, after five probes had
failed. The real cache was emptied, a poller sampled it every 200 ms and captured
the process table on each new entry, and a full Phase 4 ran. It left exactly four
— 22:24:12–22:24:15, four distinct pids, each holding `launcher-probe` at birth
and nothing afterwards — while the run's own scratch was swept correctly in the
same run, which is what tells the two apart. That host had 61 banked.

**The fix:** the probe uses its own `mktemp -d` and creates nothing it does not
remove. The regression test passes `--reuse-image` and a stub satisfying the
liveness check, redirects `HOME` so it asserts the real default path, and
deliberately leaves `IT_SCRATCH` unset — setting it is precisely what hides the
defect. Demonstrated FAIL before, PASS after.

**The timing note in this entry is now explained.** The earlier full
`verify-on-host.sh` run left zero while the Phase-4-only run left eight: a full
run's `--list-caps`-shaped invocations come from `tests/test-integration-runner.sh`,
whose stubs mostly fail `image inspect`; the count tracks how many invocations
reached the probe, not the commit.

## F65 RESOLUTION — the verdict logic now has a test, and it drives the real runner — **FIXED 2026-08-29**

`tests/test-run-all.sh`. Fifteen assertions over the rules every other result in
the suite depends on.

**The method is what makes it worth having.** `run-all.sh` resolves its corpus
from `BASH_SOURCE[0]` and sources nothing, so the test copies the SHIPPED file
into a scratch `tests/` dir beside a synthetic corpus and runs it there. Not a
reimplementation of the verdict logic — a copy of the real script, so a change
to it is a change to what is asserted. It also cannot recurse: this file is
itself collected by the `test-*.sh` glob, and it never invokes the runner in the
real tests directory.

**Each planted test is one verdict vector**, and the two that matter most are
those where the exit status and the truth disagree — both are "green" to
anything reading only `$?`:

* `FAIL:` printed while exiting 0 → must be FAIL. The historical scorecard
  (hole #2) names this as the shape `run-all.sh`'s `^FAIL:` guard exists to
  catch, and puts it OUT of the mutation tier's remit for that reason. So this
  guard was the only thing between that shape and a false green, and nothing
  asserted it.
* exit 0 having asserted nothing → must be FAIL, not PASS.

Also covered: the assertion COUNT on a pass, `SKIP` with its reason, PASS's
precedence over SKIP for a file that does both, the leaked-temp counter firing
AND naming the leaker, a tidy test not being reported as leaking, the mixed
summary tally, and the corpus exit status in both directions.

**Every rule was demonstrated failing**, by mutating the real `run-all.sh` and
re-running:

| mutation | outcome |
|---|---|
| drop the `^FAIL:`-with-rc-0 guard | KILLED — 2 assertions red |
| drop the assertless guard | KILLED |
| invert PASS-over-SKIP precedence | KILLED |
| silence the leak counter | KILLED |

One demonstration is worth recording because it nearly produced a wrong
conclusion. The first precedence mutant made the PASS branch unreachable for
EVERY file (`-gt 0` → `-gt 99999`), which trips this file's own scaffold check
and exits before the precedence assertion is ever reached — reporting SURVIVED
for an assertion that is in fact discriminating. A precise mutant that inverts
precedence only for files carrying both markers kills it immediately. **A
mutation broad enough to break the harness measures the harness, not the rule.**

`run-all.sh` remains outside the falsify tier by design
(`tests/falsify/targets.conf:277`, as the instrument the tier measures with), so
this file is the only coverage it will ever have. That is why the mutation
demonstrations above are recorded here rather than left as a one-off.

---

## F66 ADDENDUM — two measurements, one refuted hypothesis, and a narrower question — **CLOSED 2026-08-30: superseded by the F66 RESOLUTION above; the refutation below is unsound**

2026-08-29, same host, after the entry above.

**Hypothesis tried: `probe_launcher` leaves `$IT_SCRATCH` behind.** It is the one
place that creates the scratch path outside `run.sh:891` — `mkdir -p
"$IT_SCRATCH/launcher-probe"` creates `$IT_SCRATCH` as a parent side effect, and
the probe's own `rm -rf "$d"` removes only the `launcher-probe` child. That
would produce exactly the observed shape: a directory with no `logs/` in it.

**REFUTED by measurement.** A real run with an image present —
`run.sh --cases 000-harness-selftest`, which builds the default variant and so
reaches `detect_caps` twice WITH something to probe against — was watched at
0.3s resolution while it ran. Exactly **one** directory ever appeared, the run's
own (`build-default.log logs minimal-sandbox-default.conf saved-allowlists`),
and the sweep removed it. **Zero left behind.**

A second measurement explains why an earlier `--list-caps` probe showed nothing
and is worth keeping: with no image built, `detect_caps` reports `netadmin` and
`launcher` as *undetermined* and never calls `probe_launcher` at all, so that
code path is unreachable without an image. The first `--list-caps` result was
therefore not evidence about the probe either way.

**So the ordinary path is clean**, in both configurations that can be tested
cheaply: the hermetic suite alone leaves zero, and a real build-and-run leaves
zero.

**The narrower question.** The eight directories carried eight distinct
`IT_RUN_ID`s, and `IT_RUN_ID` is minted only by `run.sh` itself
(`run.sh:25`); `lib.sh` refuses to load without one (`:?`). So eight separate
`run.sh` invocations minted them. A single Phase 4 is one invocation. What is
still unexplained is what performed the other seven — and the one circumstance
the two observed bursts share, which no reproduction so far has recreated, is
that a `tests/run-all.sh` was running CONCURRENTLY with Phase 4 on the same host
at both moments.

That is stated as the next thing to try, not as a finding: run the hermetic
suite and a Phase 4 at the same time, with the watcher above running, and see
whether the bursts reappear.

### SUPERSEDED 2026-08-30 — the refutation is unsound, and the experiment it prescribes is not owed

**Read this entry against the F66 RESOLUTION, which sits ninety lines ABOVE it
and was written an hour AFTER it.** This file is ordered chronologically by
commit, not by finding: the addendum landed in `8ba954b`, the fix and its
resolution in `3f83739`, and that resolution was written into the ORIGINAL F66
entry rather than appended here. So a reader arriving at the end of the file
meets the stale record last and takes it for the current one — the same
two-records-disagreeing defect this file has had to correct before, and the
reason this section exists rather than a silent deletion.

**Why "REFUTED by measurement" was wrong.** The observation was right; the
inference was not. `run.sh --cases 000-harness-selftest` *does* reach
`probe_launcher` — it builds the default variant, so `docker image inspect`
succeeds and `detect_caps` probes — and the pre-fix
`mkdir -p "$IT_SCRATCH/launcher-probe"` created the scratch root in that run
too. It was invisible because that root is the same directory the run was going
to create anyway, and any invocation that proceeds past selection installs
`trap 'sweep' EXIT` and removes it. "Exactly one directory ever appeared, the
run's own" is precisely what a littering probe looks like from inside a complete
run.

**The discriminator is not whether the probe runs. It is whether the invocation
reaches the sweep.** Only an invocation that exits BEFORE `trap 'sweep' EXIT`
can leave the artefact, and `--list-caps` is that invocation. A complete run
could not have separated the two hypotheses at all, so that measurement had no
power to refute anything — the same shape as a test that passes against unfixed
code, which this fix's own first regression test also had until the mandatory
pre-fix demonstration caught it.

**The narrower question is answered above**, in the resolution's closing
paragraph: the `--list-caps`-shaped invocations come from
`tests/test-integration-runner.sh`, and the count tracks how many of them
reached the probe. That is also the concurrency correlation this entry could not
explain — the concurrent `tests/run-all.sh` WAS the source, not a condition
acting on Phase 4. The prescribed experiment (a hermetic suite and a Phase 4 at
once) would re-derive a settled fact and is not owed.

**Post-fix measurement, 2026-08-30, same host.** The four directories still
banked here were stamped 22:24:11–22:24:15 on 2026-08-29; the fix merged at
23:29:34 the same evening. They are the residue of the very run the resolution
quotes, not a recurrence. They were removed, and the full hermetic suite was
then run with the real `$HOME` under the same 200 ms poller: **73 tests, 73
passed, and zero directories ever appeared — not one created, not one left.**
`tests/test-integration-runner.sh` and `tests/test-layer-containment.sh`, the
two files that invoke `run.sh`, both ran inside the watched window. `--dry-run`
was checked at the same time and makes no docker call at all (the
`do_dry_run -eq 0` guard covers the trap and network setup), so there is no
second early-exit path able to reach the probe.

---

## F1 RESOLUTION (first half) — measured, not estimated: 22 of 22 — **execution coverage FIXED 2026-08-29; the tier half remains OPEN**

**The entry's headline number was two generations stale.** "2 of 19" described
the suite before `tests/test-repo-destructive.sh` existed. Rather than trust
either number, every function in `repo.sh` was instrumented in a scratch copy of
the tree — an appended marker line per function — and the three repo test files
run against it.

**Result before this change: 21 of 22.** Every `cmd_*`, every `seed_*`/`sync_*`
except one, `reset_git`, `collect_inspections`, `git_helper_run`, `list_copies`
— all reached. The single function nothing had ever executed was
**`sync_from_path`**.

**The reason it was missed is worth more than the fact.** It was a gap in the
FIXTURES, not the tests: reaching it needs a repo that is `path`-TYPED and
`volume`-BACKED, and every path repo in the suite was bind-backed, which
`sync_one` answers with "nothing to sync" before it gets there. That
combination is not exotic — on Linux `auto` registers a path repo as a bind
alias, but on macOS it cannot, so **on a Mac every path repo is volume-backed
and every `repo.sh sync` of one runs this function.** The one unexecuted
function was the one an entire platform takes on its normal path.

**And it deletes.** `sync_from_path` mirrors with `rsync -a --delete /src/
/dst/`, so its "source no longer exists" guard is load-bearing: without it the
mirror runs from nothing and the volume's contents are what gets removed by the
command meant to update them.

Twelve assertions added to `tests/test-repo-destructive.sh` (its harness already
runs `repo.sh` as a real subprocess against a recording fake `docker`). They
cover the mirror's two mounts, the `:ro` on the source as its own assertion, the
host file being untouched, the vanished-source guard refusing AND starting no
mirror at all, and `reset`'s arm through the same function. Coverage is now
**22 of 22**, re-measured the same way.

Each was demonstrated failing against a mutated `repo.sh`: dropping the
vanished-source guard, dropping `:ro`, mirroring into the wrong volume, and
skipping the mirror entirely — all KILLED.

**A note on the demonstrations, because it cost two false conclusions here and
one in F65.** Twice a mutant was reported SURVIVED when it was in fact killed:
the demo harness greps for one expected FAIL: line, and both times the mutation
was caught by a DIFFERENT assertion than the one named. A demonstration must
check that the suite went red, not that a particular string did.

**What remains OPEN is the entry's second half**, unchanged and still correct:
execution is not assertion. `repo.sh` is still not a falsify target, so nothing
measures whether these 22 functions are *asserted* or merely *run*. That is the
next step, and it is now safe to take — the entry parked it because mutating
`repo.sh` would have yielded survivors measuring the absence of a harness. The
harness exists now.

**A path-shape defect in the new assertions, caught by the arm that exists for
it.** The first version compared the mount against `$TMP/pathsrc` — the
UNRESOLVED path. `sync_from_path` calls `resolve_path` before mounting, so the
mount carries the physical path, and the two differ whenever `TMPDIR` contains a
symlink. It passed the ordinary suite AND the bash-floor container, and failed
`suite-symlinked-tmp` — the macOS shape, exactly the class AGENTS.md records
this repo having paid for twice before.

Fixed with `p_realdir`, deliberately not `readlink -f`: `resolve_path` itself
uses `readlink -f`, and canonicalising the expected value with the same
primitive as the code under test is `assert f(x) == f(x)`.

Worth recording because of what it makes the assertion sensitive to. A mutant
that drops the `resolve_path` call — `real="$src"` — now dies, but **only in the
symlinked arm**: under an ordinary `TMPDIR` resolved and unresolved are the same
string, so that mutant is unobservable there by construction, not merely
unnoticed. Measured both ways: 1 red under a symlinked `TMPDIR`, 0 under an
ordinary one. That is the clearest demonstration in this file of why the third
arm is a separate arm.

---

## F64 RESOLUTION — reproduced on Linux, and the mechanism is a trap firing in a forked child — **FIXED 2026-08-30**

Five sightings over nine days (2026-08-21, 08-23, 08-26, 08-27, 08-29), a macOS
reproduction attempt that failed, and an addendum concluding the prior evidence
described a configuration that no longer exists. Settled here.

### Reproduced

macOS was the wrong platform: the sightings are Linux, on a real host `/tmp`.
On a Linux host (WSL2, 16 cores, Xeon W-10885M, `/tmp` on disk), in a SCRATCH
tree with both rootings reverted to restore 189ebda's flat shared `/tmp`:

```
tests/falsify/run.sh --target tests/portability.sh --jobs 32 --controls 12 --timeout 120
```

`--jobs 32` on 16 cores deliberately — F59 records oversubscription raising the
red-control rate, and if the mechanism is a race then interleaving is the
variable. **Three reproductions, at iterations 23, 11 and 2 of separate 60-run
loops** (~36 iterations, ~432 controls). Each carried the sightings' exact
signature:

```
ERROR: CONTROL FAILED — the PRISTINE oracle went red under this run's own load
       (signal=exit+failline, 1.9s): tests/portability.sh via test-portability.sh
FAIL: p_stat_mode returned empty … [fixture=/tmp/tmp.ufhI3yMh0z/f dir=n exists=n size=? left=0]
```

### The mechanism, caught directly

An `rm` shim on `PATH` logging every removal of a `/tmp` fixture with its parent
chain showed the fixture removed **twice** — once by the test's own EXIT trap at
teardown, and once 1.1s EARLIER by a process whose parent and grandparent were
both `test-portability.sh`. An instrumented trap then named it outright:

```
TRAPFIRE pid=2284480 bashpid=2285462 subshell=1
         cmd=[local cmd_pid=$!] fn=[p_timeout main]
```

`BASH_SUBSHELL=1`, `BASHPID != $$`: **the script's `trap 'rm -rf "$TMP"' EXIT`
ran in a forked child of the script, inside `p_timeout`, at its `"$@" &` fork.**
The child deleted the fixture the script was still using; the four `p_*` helpers
then returned empty and reported four symptoms of that one fact.

`p_timeout` backgrounds two children — the timed command and a watchdog — and a
child can end up running the caller's EXIT trap. **47 test files** in this suite
set `trap 'rm -rf "$TMP"' EXIT`, so each of those children carries a loaded
`rm -rf` aimed at its caller's own fixture.

### Why it is load-dependent, and why five sightings were not enough

Whether a child FIRES the trap depends on scheduling; whether it is HANDED one
does not. That asymmetry is why this took nine days and 276 controls to see once
— and it is why the guard is asserted on the second property, not the first.

### The fix, and one that was tried and reverted

`tests/test-portability.sh` now owns its fixture explicitly:

```bash
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
```

`$BASHPID`, not `$$`: `$$` is the script's pid and is unchanged in a subshell,
so comparing it to itself would guard nothing.

**A fix in `p_timeout` was tried first and REVERTED, and the reason is worth
keeping.** Clearing the caller's EXIT trap across the two forks and restoring it
after made the failure DETERMINISTIC — 4 failures on every run, the exact
`dir=n` signature. Bash neutralises an *inherited* trap in a subshell, but an
explicitly re-armed one fires: the restore converted a dormant trap into a live
one in every subshell `p_timeout` runs inside, such as a command substitution.
Isolated by running the fixed helper against the ORIGINAL test file (4 failures)
and the original helper against the original test file (0). The hazard belongs
to whoever owns the fixture, not to the helper that forks.

### Verified

The guard asserted deterministically in `test-portability.sh` — the trap's own
action, run in a forked child, must leave the fixture alone — and demonstrated
FAILING against the unguarded trap (`dir=n file=n`). A second assertion pins
that the guard is not inert, since a condition that never holds would trade a
destroyed fixture for one leaked on every run.

Then the reproduction re-run under identical conditions with the guard in place:
**117 iterations, 1404 controls, 0 control failures**, against ~1 failure per
144 controls without it — roughly ten times the exposure, clean.

### What this does not claim

The rootings (`6e5bfc7`, `#175`) are not redundant: they remove the shared
namespace that made a *cross-worker* collision possible, and this entry never
proved that mechanism absent. What it proves is that the `dir=n` sightings were
NOT cross-worker at all — the destroyer was always the test's own forked child,
and the flat `/tmp` was a coincidence of where the fixture happened to live.
