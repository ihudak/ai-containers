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

## F12 — a timeout counts as a KILL, so `TOTAL`'s killed column overstates the kill signal

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

## F13 — nothing yet runs the ledger gate

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
