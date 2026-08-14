# `falsify` — a Mutation Tier for the Hermetic Suite — Design

**Increment 5.** Designed and approved in substance on 2026-08-11, then
deferred behind increment 4 (`2026-08-11-execution-layers-and-portability-design.md`),
which settles the bash floor this harness is written against and creates the
layer model its work is assigned to.

**Revised 2026-08-14**, before planning, after re-reading the spec against the
tree and running the R1 pilot the spec itself required. Four things changed, and
each is recorded at the section it affects:

1. **The boundary rule rested on a false premise** — `sandbox.sh` has been
   *executed* by the hermetic suite since 2026-07-28, two weeks before this spec
   excluded it on the grounds that nothing runs it. A third category exists now.
2. **R1's re-scope trigger fired.** The pilot measured a 49.4 % survival rate
   against an assumed 8-20 %, projecting 814-1002 survivors against an assumed
   75-190. Both authorised levers are pulled: `stream-flip` is dropped and the
   target list is staged.
3. **The suite grew** from 39 files to 45, and from the ~635 `pass` call sites
   this spec counted to 1267 assertions actually executed.
4. **The network/security tier is in scope now** — its "demonstrated failing"
   guarantee turned out to be prose in a plan file that nothing executes.

## Problem

`tests/test-mutations.sh` makes the *"a case is not accepted until it has been
seen failing"* rule mechanical for the **launcher** tier of the integration
corpus. Nothing enforces it for the 45 hermetic test files in `tests/*.sh` —
1267 executed assertions — and, as increment 5's re-read discovered, nothing
enforces it for the integration corpus's **network/security** tier either
(see "The network/security tier" below).

That is where the holes actually are. Six checks that could not fail have been
found so far; **four were hermetic**, all four in tests that test the test
system:

| # | Where | Defect |
|---|---|---|
| 1 | `verify-on-host.sh` | exited 0 regardless of phase failure |
| 2 | `tests/test-integration-lib.sh` | tallied into a counter its `exit` never read |
| 3 | `tests/test-integration-lib.sh` | `launcher_prepare` assertion — variable set before a `source` that reset it |
| 4 | `tests/test-integration-lib.sh` | `ar_has 'error: ' && ar_has 'it-fake-missing-interp'` — the second conjunct was satisfied by an unrelated line |
| 5 | `tests/integration/cases/730-…` | `gcc` survives `apt-get purge --auto-remove build-essential`, so the assertion was unfalsifiable |
| 6 | `tests/test-mutations.sh` | a stdout assertion whose helper folded stderr into stdout |

`run-all.sh`'s `^FAIL:` guard catches #2's shape — a test printing `FAIL:` while
exiting 0. It cannot catch #3, #4 or #6: an assertion that runs, reports `PASS`,
and whose condition can never be false.

Two of those six were written *by the fix for another one*. The rule needs a
machine.

## Approach

Mutation testing, with the hermetic suite as the oracle. Damage a target file,
run the tests that cover it, and ask whether anything noticed. A mutant nothing
noticed — a **survivor** — is evidence that some assertion in that area either
does not exist or cannot fail.

This tier can afford what the integration tier cannot. `test-mutations.sh` only
checks that a patch *still applies*, because running a case costs minutes and a
Docker daemon. A hermetic test runs in seconds, so here the mutation is applied,
the test is run, and the verdict is produced **on every CI run** — a
demonstration executed, not a demonstration recorded in prose.

### The boundary rule

> **Mutate only what the hermetic suite executes. Never what it merely greps.**

The rule stands. Its original application did not: this spec excluded
`sandbox.sh` because "nothing runs them", and that was **already false when
written** — by a wider margin than the first pass of this revision recorded.
Two independent routes execute it:

- `tests/test-parsers.sh` has sourced it since commit `5e7d4ee` (2026-07-28),
  in a subshell with positional parameters cleared so it lands in the `usage`
  branch, then calls `mem_to_bytes`, `validate_memory_limits`,
  `parse_pointer_spec`, `pointer_repo_entry` and `split_env_list`.
- **`tests/test-docs-path.sh`, `tests/test-tool-config-mounts.sh` and
  `tests/test-tools-d.sh` run it as a real, un-neutered subprocess** — `bash
  "$REPO_DIR/sandbox.sh" restricted …` with only `docker` faked on `PATH`.
  That reaches argv parsing, mode dispatch, group bootstrap, the whole of mount
  resolution, the `tools.d` `config_dir` logic, and `docker run` argument
  assembly.

So the excluded file is one of the *best*-executed scripts in the repo along its
restricted-mode path. **Discovery mode and open mode are the genuinely
grep-only parts** (`tests/test-open-mode.sh` only greps and `bash -n`s them),
which is the real boundary — a per-mode one, not a per-file one.

Excluding the largest product script on a premise contradicted by a two-week-old
commit is exactly the kind of unchecked claim this repo's guards exist to catch.
The rule now has **three** outcomes, not two:

| Category | Meaning | Mutation unit |
|---|---|---|
| `EXECUTED-WHOLE` | sourced or run such that essentially all its code can run | the **file** |
| `EXECUTED-PARTIAL` | reached only in an identifiable region — e.g. `sandbox.sh` via `test-parsers.sh`'s `run_fn` | the **named functions**, listed explicitly |
| `GREPPED-ONLY` | every reference is a text search, existence check, `bash -n`, or line-number assertion | not mutated |

`EXECUTED-PARTIAL` is what keeps the correction from swinging too far the other
way: most of `sandbox.sh` genuinely is grep-only, and mutating the file whole
would flood the ledger for the same reason the original exclusion was reaching
for. Mutating only the five functions the suite actually calls is both sound and
cheap. A `bash -n` or `shellcheck` invocation is **not** execution, and a stub
fake inside `tests/lib-verify-repo.sh`'s scratch repo is not the real script.

**Measured 2026-08-14** across the 19 candidates: 14 `EXECUTED-WHOLE`, 5
`EXECUTED-PARTIAL`, 0 `GREPPED-ONLY`. The five partials, with what is *not*
reached — which is the half that matters, because it is where a mutant would
survive for reasons that have nothing to do with assertion quality:

| Target | Reached | Not reached |
|---|---|---|
| `sandbox.sh` | restricted-mode path, whole; 5 parser fns | **discovery and open modes** |
| `repo.sh` | `is_git_url`, `fmt_epoch` — **2 of 19** | every `cmd_*` subcommand, `seed_from_*`, `sync_from_*` |
| `tests/integration/lib.sh` | 15 fns incl. the `launcher_*` family | `sidecar_up`, `sandbox_up`, `agent_exec*`, 5 asserts — existence-checked only |
| `build.sh` | 10 of 11 | `build_image` (needs a real `docker build`) |
| `install-tools.sh` | `asset_name`, `parse_versions`, `install_one` + transitive | `api_get`, `main` |

Zero `GREPPED-ONLY` is not evidence the category is unnecessary — these 19 were
pre-filtered as plausible candidates. It is the verdict `entrypoint.sh`,
`group.sh` and the capture daemons would receive, and the gate must still be
able to express it.

Two of those rows are coverage findings in their own right, independent of
mutation testing, and are recorded in the backlog rather than silently
absorbed: **`repo.sh` executes 2 of 19 functions** — every user-facing
subcommand is unexercised hermetically — and **`sandbox.sh`'s discovery and open
modes are never executed** by the hermetic suite (they are covered by
integration cases `110`/`120`/`210`/`220`/`230`, so this is a tier gap, not an
absence of coverage). Mutating either area today would produce survivors that
say nothing about assertion quality, which is why both wait for a later stage.

`targets.conf` maps each target to its oracle tests, carrying the category and —
for `EXECUTED-PARTIAL` — the function list. It is **derived, then checked**: the
candidate list comes from resolving what the tests source and run (including
through path variables such as `LIB=`, `RUNNER=`, `VERIFY=`, `src=`), and an
executed file missing from the map fails the gate. Excluding one requires an
explicit `EXCLUDED: <reason>`. A hand-written list can only validate what
someone remembered — and, as the `sandbox.sh` error shows, a hand-written
*premise* is no better.

### The oracle

The runner invokes `tests/run-all.sh <name>` — not the test file directly — so
the killed/survived verdict is literally the same code path as the suite's own
(`FAIL:` line present, or non-zero exit, or asserted nothing). The two cannot
drift apart. Measured overhead: 55 ms.

Two properties of that entry point are **relied upon**, and the harness must not
be rewritten in a way that gives them up:

- **`run-all.sh` exits 2 when no test matches its filter.** A target whose
  oracle name is misspelled in `targets.conf` therefore fails loudly, rather
  than running zero tests and reporting every mutant as killed — which is the
  silent-success shape this whole tier exists to eliminate.
- **A dirty working tree does not, by itself, change the verdict.** Verified by
  control during the pilot: with a no-op comment appended, the oracle still
  passes. Without that property every "killed" would be suspect, because
  `mutate.sh`'s own `cmd_apply` carries a `git diff --quiet` gate.

A mutant that exceeds a per-mutant timeout counts as killed and is flagged.
A mutant that fails `bash -n` is discarded, not counted — a syntax error proves
nothing about any assertion.

### Operators and layers

**Measured 2026-08-14**, one mutant per applicable *token occurrence* (the
2026-08-11 estimates counted per line, which is why the totals moved — it is a
methodology difference, not drift). Across the 19 candidate files: **2028 valid
mutants, 0 discarded by `bash -n`** — all five operators are syntax-preserving
token substitutions by construction, confirmed by planting three malformed
candidates through the same gate and watching 3/3 be discarded.

| Operator | Mutants | Pilot survival | Layer |
|---|---|---|---|
| `cond-negate` | 608 | 4.5 % | **PR** |
| `logic-flip` | 471 | 27.3 % | **PR** |
| `return-flip` | 289 | 75.0 % | **PR** |
| `cmp-flip` | 219 | 0 % | **PR** |
| ~~`stream-flip`~~ | ~~441~~ | **100 %** | **dropped** |

**Correction, 2026-08-14 (second measurement).** The counts above came from an
exploratory generator whose `stream-flip` had **two** sub-forms: `>&2` → `>&1`,
*and* removing a `2>/dev/null` / `2>&1` suppression. This spec's operator table
defines only the first — deliberately, since the pilot measured the suppression-
removal form at 4/4 `EQUIVALENT` and recommended dropping it by name. But the
per-target counts were copied from the wide version, making the arithmetic
internally inconsistent, and the implementation caught it: `tests/portability.sh`
was credited with 4 `stream-flip` mutants while containing **zero** `>&2` (it has
exactly 4 `2>/dev/null`/`2>&1`), and the claimed 62 stage-1 `stream-flip` mutants
exceeded the 41 `>&2` occurrences that exist. Both verified directly.

Authoritative numbers are now the ones `tests/falsify/generate.sh` produces,
because that is the code that will run: **288** stage-1 mutants, 0 discarded by
`bash -n`, of which **41** are `stream-flip` — so **247** under the default set,
projecting ~60 survivors at the pilot's 24.1 % ex-`stream-flip` rate. Do not
"restore" the 300/62 figures; they describe an operator this spec does not have.
| `stmt-delete`, enabled per-target on a measured score | — | — | **Nightly** |
| full matrix, on the host | — | — | **Local** (Phase 6) |

`num-bump` was dropped in the original design because "its problem is signal,
and a longer schedule does not fix signal." **`stream-flip` is dropped on that
same criterion, applied to new data**: 441 mutants at a measured 100 % survival
is strictly worse than `num-bump` ever was. Dropping it takes projected
survivors from 814 to 373 — over half the adjudication cost of the whole tier,
for a handful of genuine finds.

This is a real loss and is recorded as one: `stream-flip` is the only operator
whose shape matches historical hole #6 (stream confusion). It may return as an
**opt-in per-target operator gated on a measured score**, exactly as
`stmt-delete` is.

It cannot be gated on anything cheaper, and one appealing idea was tried and
**refuted**: "enable it only where the oracle captures stdout and stderr
separately" does not work. `tests/test-mutations.sh` captures stderr separately
in nine places and still let all 27 `stream-flip` mutants survive. Whether a
stream flip is killable is not statically predictable from the oracle's capture
idiom, so measurement is the only gate available.

`stmt-delete` is the operator whose shape matches holes #3 and #4 most directly
— a behaviour silently missing — so it is enabled per target by a **measured**
criterion, not a guess: a target qualifies once its mutation score under the
five PR operators clears a threshold. A file whose oracle already kills ~95% of
gated mutants will kill most deletions too, yielding few and sharp survivors. A
file whose oracle kills 60% would flood the ledger with the same underlying gap
restated two hundred times. Fix the gap first, then deepen. The threshold is set
from the first full run's numbers.

### Staging the target list

The second lever R1 authorises. Even with `stream-flip` gone the full corpus
projects 373 survivors, and every `GAP` among them is owed a killing assertion
under this project's "none dropped" rule. Committing to 373 IOUs in one
increment is how that rule stops being true.

Entry has **two** conditions, and only the first is mechanical. Stating this
precisely matters, because an earlier draft of this section claimed the criterion
alone was "mechanical … not a judgement call about which files feel important",
and the implementation disproved it: the rule as written admits **at least
eighteen** targets, not nine. Strict 1:1 name-matching selects only four of the
nine below; the other five (`mutate.sh` → `test-mutations.sh`, `tools-lib.sh` →
`test-tools-d.sh`, `lib-layer-checks.sh` → `test-layer-checks-parser.sh`,
`docker-shim.sh` → `test-integration-shim.sh`, `shared-files.sh` →
`test-shared-files-parity.sh`) were judgement calls dressed as derivation.

1. **Necessary and mechanical:** the target is `EXECUTED-WHOLE` and has an
   identifiable primary oracle. `derive-targets.sh` checks this and gates it.
2. **A stage-1 budget cap, which is a decision:** of the targets meeting (1),
   these nine are activated first — the smallest set that exercises every part of
   the machine while keeping the ledger reviewable. `targets.conf` records the
   rest as `#DEFERRED|` **with this reason stated in its header**, so nobody
   later mistakes the active set for the rule's output.

Nine active targets:

| Target | Oracle | Mutants |
|---|---|---|
| `tests/integration/mutate.sh` | `test-mutations.sh` | 81 |
| `tests/lib-layer-checks.sh` | `test-layer-checks-parser.sh` | 60 |
| `tests/lib-verify-repo.sh` | `test-lib-verify-repo.sh` | 60 |
| `tests/bash-dialect-lint.sh` | `test-bash-dialect-lint.sh` | 27 |
| `tests/integration/docker-shim.sh` | `test-integration-shim.sh` | 26 |
| `tools-lib.sh` | `test-tools-d.sh` | 17 |
| `bash-floor.sh` | `test-bash-floor.sh` | 12 |
| `tests/portability.sh` | `test-portability.sh` | 12 |
| `shared-files.sh` | `test-shared-files-parity.sh` | 5 |
| | **total** | **300** |

The per-file figures in that table are the exploratory generator's. The
implementation measures **288** across the nine, less **41** `stream-flip`, so
**247** under the default set — projecting **~60 survivors** at the pilot's
24.1 % ex-`stream-flip` rate. A corpus a reviewer will actually read, which is
the whole point of R3's mitigation. See the correction under "Operators and
layers" for why the two counts differ.

`tests/integration/minimal-conf.sh` waits because its coverage is split across
**three** tests rather than one, so it has no primary oracle. That is condition
(1) doing real work — but it is the only near miss of its kind, which is exactly
why condition (2) has to exist and be named as a decision.

The nine that meet (1) and await a later stage are named in `targets.conf`:
`check-sandbox-version.sh`, `group.sh`, `migrate-runme.sh`,
`capture-blocked-traffic.sh`, `link-agent-tools.sh`, `link-default-ruby.sh`,
`agent-tools-reconcile.sh`, `rvm-reconcile.sh`, `install-agent-skills.sh`. They
are the obvious stage 2 and roughly double the corpus. The large diffuse targets
(`sandbox.sh`, `tests/integration/{lib,run}.sh`, `repo.sh`,
`sandbox-common.sh` — 1329 mutants between them) are precisely the ones that
would flood, and they enter in later increments, one at a time, each with its
own `GAP`-fixing work.

Staging is not deferral. The machine — generator, oracle, ledger, gate — ships
whole in this increment; only the target list grows.

### Mutant identity

`<file>:<operator>:<sha1 of the original line, trimmed>` — **not** `file:line`.
Line numbers shift on every edit and would invalidate the ledger wholesale;
content hashes survive shifts and break exactly when the code changes, which is
the desired behaviour. A ledger entry naming a mutant that no longer exists is
**stale and fails loudly**, mirroring the existing rule that a patch which no
longer applies must fail rather than quietly matching nothing.

### Isolation

The runner **never mutates the working tree.** Each worker gets a scratch tree
(tracked files plus `.git`, ~17 MB); per mutant it writes the damaged file, runs
the oracle, and restores from a pristine cache. This is the opposite choice from
`tests/integration/mutate.sh`, which mutates the real tree deliberately for
hand-driven demonstrations. Both are correct for their purpose; the README must
say so, or someone will unify them.

Re-checked 2026-08-14: `mutate.sh` changed twice since this section was written
(`5c43b6a`, `d1970f6`), but for unrelated reasons — pathname expansion and git
usability in the floor run. The contrast this section rests on is intact.

### The survivor ledger

`tests/falsify/survivors.txt`, one block per survivor, classification mandatory:

```
repo.sh:stream-flip:9f3c21a
  repo_die() { printf 'repo.sh: %s\n' "$1" >&2; exit 1; }
  EQUIVALENT: no hermetic test reads repo_die's stream; the message is
  asserted by content, and stderr-vs-stdout on a fatal path is observable
  only through the launcher tier.
```

Four hard failures:

| Condition | Why |
|---|---|
| survivor with no classification | the ratchet — a new hole cannot land silently |
| survivor absent from the ledger | same |
| entry whose mutant no longer exists | stale, like a stale patch |
| entry whose mutant is now **killed** | obsolete amnesty; delete it |

`GAP` entries are owed a killing assertion and follow the established pattern:
one fixed before merge, the rest in a follow-up merge, none dropped.

## Verification

The harness must be seen failing before it is trusted — the rule that has caught
six of these, including two written inside the fixes for the others.

- `tests/test-falsify-harness.sh` drives a fixture tree holding one
  known-killable and one known-surviving mutant, and demonstrates each of the
  four gate failures by breaking the mechanism, never by asserting the expected
  answer.
- **Validation against the four historical holes.** All four are recoverable,
  and the commits are named here so the task does not begin with a search:

  | Hole | Fixed in | Defective test | Mutation target |
  |---|---|---|---|
  | #2 tallied into a counter its `exit` never read | `44676f5` | `tests/test-integration-lib.sh` | `tests/integration/lib.sh` |
  | #3 `launcher_prepare` — variable reset by a later `source` | `421d25d` | `tests/test-integration-lib.sh` | `tests/integration/lib.sh` |
  | #4 conjunct satisfied by an unrelated line | `9b64bd3` | `tests/test-integration-lib.sh` | `tests/integration/lib.sh` |
  | #6 stdout assertion whose helper folded stderr in | `7d1970f` | `tests/test-mutations.sh` | `tests/integration/mutate.sh` |

  The structure is what makes this validation sound: in each case the defect
  lived in a **test** whose **target** is on the mutation list, so an
  unfalsifiable assertion is precisely a surviving mutant. Restore the pre-fix
  test with `git show <sha>^:<file>`, run the corresponding mutant, and the
  harness must report `SURVIVED`. A tool that cannot catch the bugs that
  motivated it does not ship.

  **Hole #6 is the honest exception and must be run as one.** Its shape is
  `stream-flip`, the operator this revision drops — so with the default operator
  set it will report `KILLED`-by-absence, not `SURVIVED`. The validation runs it
  with `stream-flip` explicitly enabled for that one target, which demonstrates
  two things at once: that the harness catches it, and exactly what dropping the
  operator costs. Silently letting hole #6 pass because its operator is gone
  would be the same "verified nothing" failure this suite keeps finding.

## The network/security tier

**Added to scope 2026-08-14.** Not mutation testing, and not hermetic — it is
the same rule this increment exists to mechanise, applied to the one tier that
never got it.

`tests/test-mutations.sh` asserts two directions for the launcher tier: every
patch still applies, **and** every case has one. Its coverage loop filters on
`mounts|groups|volumes|packages`. All 14 network/security cases carry
`network-mode`, so **none of them is checked** — and that set is every
restricted-mode assertion the product has: `010-restricted-blocks-unlisted`,
`070-restricted-drops-capabilities`, `230-open-drops-capabilities`, and the
self-heal pair.

`AGENTS.md` states these cases "keep their fixture-based demonstrations under
`tests/integration/fixtures/`". Two findings against that:

- **Only two cases have a fixture at all** — the known-bad daemons name `040`
  and `060` specifically. The other twelve have none.
- **No case mounts either fixture.** Every reference to them in
  `tests/integration/cases/` is a comment; `tests/test-integration-fixtures.sh`
  only guards their executable bit. The demonstration was a manual, one-time
  procedure — the increment-1 plan ends it with
  `git checkout -- tests/integration/cases/`.

So the guarantee is prose in a plan file that nothing executes: the exact
distinction this spec draws when it contrasts "a demonstration executed" with
"a demonstration recorded in prose". A new restricted-mode case can ship today
with no demonstration whatever, and nothing anywhere reports it.

The existing justification — that the fixtures are "copies of code that no
longer exists, so there is nothing for a patch to apply to" — is true of the two
*fixtures* and does not extend to the other twelve cases, whose recorded
mutations are ordinary edits to case files that still exist.

**The work is a conversion, not an invention.** Every mutation was recorded in
the increment-1 plan's four "Known-bad mutation" tables:

| Case | Recorded mutation |
|---|---|
| `010` | allowlist the sidecar |
| `020` | allowlist nothing |
| `030` | drop the `--add-host` argument |
| `040` | `allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""` |
| `060` | bind-mount fixture #1 (`…prefix.sh`) |
| `070` | `pid1_caps` reads a fresh exec; and `--privileged` with no drop |
| `080` | `SELF_HEALING_ENABLED=0`; and bind-mount the known-bad daemon |
| `085` | remove `SELF_HEALING_ENABLED=0` |
| `110` | `sandbox_up restricted` |
| `120` | `-e DISCOVERY_CAPTURE_ENABLED=0` |
| `220` | `sandbox_up restricted` |
| `230` | `sandbox_up discovery` |

Three deliverables:

1. Convert those twelve into `tests/integration/mutations/NNN-*.patch`, the same
   mechanism and `# case:` header the launcher tier already uses — a patch that
   stops applying fails loudly, which prose cannot.
2. **Author the two that were never demonstrated.** `050` has only a "must still
   PASS against the known-bad daemon with a populated allowlist" observation —
   which is a real and valuable asymmetry, but it is not a failing
   demonstration; and `210-open-no-firewall` has nothing recorded at all.
   (`000-harness-selftest` is tagged `harness`, not `network-mode`, and is out
   of this set.)
3. Extend the coverage loop's tag filter to include `network-mode`, so the
   assertion that has protected the launcher tier since increment 2 protects the
   security tier too.

Step 3 is the ratchet and must land **with** steps 1 and 2, never before: turned
on early it fails 14 cases at once, and turned on late it is one more thing
nothing enforces.

## Naming

`tests/falsify/` — deliberately not `tests/mutation/`, which sits two letters
from the existing `tests/integration/mutations/` and would be conflated within a
week. The name states the property being measured rather than the technique.

## Risks and mitigations

### R1 — survivor count is unknown until the generator first runs — **RESOLVED 2026-08-14, trigger fired**

The pilot ran, exactly as this section required, and its number was bad enough
to re-scope the increment. Recording both the prediction and the outcome,
because the gap between them is the finding:

| | Predicted 2026-08-11 | Measured 2026-08-14 |
|---|---|---|
| Mutants | 935 | 2028 |
| Survival rate | 8-20 % | **49.4 %** (24.1 % without `stream-flip`) |
| Survivors to classify | 75-190 | **814-1002**, and that is a floor |
| Wall clock | ~7 min | 1.5 h at 8× — *not* the constraint |

Pilot: `tests/integration/mutate.sh` × `tests/run-all.sh test-mutations`,
81 mutants, 41 killed, 40 survived, 25.0 s total at 0.309 s/mutant. The baseline
was confirmed passing before any mutant ran, and confirmed insensitive to a
dirty tree, so neither could manufacture a kill.

The projection is a **floor**, not a midpoint: the pilot target is the
best-covered file in the set (123 assertions over 256 lines), and `cmp-flip`'s
rate rests on n=2 while `return-flip`'s rests on n=8. Targets with only
indirect coverage will survive more.

**Compute was never the risk; adjudication was.** Both authorised levers are
therefore pulled — `stream-flip` dropped (see "Operators and layers") and the
target list staged (see "Staging the target list") — taking this increment's
classification load from 814-1002 to **~57**.

**The pilot also justified the tier on its first target.** Independently
re-verified, not taken on report: mutating `mutate.sh:144` from
`( cd "$GIT_ROOT" && git diff --quiet )` to `||` **disables the clean-tree gate
entirely** — `cd` succeeds, `||` short-circuits, the negation is false — and the
hermetic suite stays green. That gate is the guarantee that a mutation is the
only difference in the tree, which is what makes reverting one safe rather than
a guess. It is a real hole, in a file with a dedicated 123-assertion test, found
in the first 25 seconds of running the machine.

**Second mitigation — shared rationales.** Survivors from one underlying cause
are common (one unasserted stream, one uncovered function). The ledger format
permits one classification to cover a named group, so N survivors from a single
gap cost one entry, not N. This is what keeps the count from becoming the work.

### R2 — `stmt-delete` triage floods the ledger

**Mitigation — the measured per-target entry criterion**, which exists for this
reason: a target earns `stmt-delete` only once its mutation score under the five
PR operators clears a threshold, so the operator is only ever enabled where the
oracle is already strong enough to kill most of it.

### R3 — `EQUIVALENT` classifications degrade into rubber-stamping

The gate can require a non-empty reason; it cannot detect a lazy one. A ledger
whose entries nobody reads stops protecting anything, and it would be protecting
the whole hermetic tier.

**Mitigation — make the reason answer a specific question, and keep the corpus
small enough to review.** An `EQUIVALENT` entry must state *why no test could
ever kill this mutant*, not merely that none does — those are different claims,
and the second one is a `GAP`. Dropping `num-bump` (655 near-noise mutants) and,
after measurement, `stream-flip` (441 more) exists partly to serve this, as does
staging the target list: together they take this increment's ledger from
814-1002 entries to ~57 — the difference between a corpus a reviewer reads and
one they scroll past. This mitigation is review discipline, not machinery, and
is stated as such rather than pretending the gate enforces it.

## Bash floor

Increment 4 sets the repository floor at **5.1**, so this harness may use
`declare -A` for the mutant→verdict map, `wait -n` for the worker pool, and
`EPOCHREALTIME` for per-mutant timing without forking `date` — the last of which
matters across thousands of mutants. None of the bash-3.2 workarounds apply to
new code here.

## Non-goals

- No coverage percentage or mutation score as a target — the ledger is the
  artifact. Scores inform which targets earn `stmt-delete`, nothing more.
- No mutation of heredoc bodies.
- No replacement of `tests/integration/mutations/`; different tier, different
  economics.

## Port

Ported to `Dynatrace-Internal/mgd-ai-containers` as a parallel PR, with the file
list derived from `git diff --name-only`, never hand-written.
