# Execution Layers and Host Portability — Design

**Increment 4 of the runtime verification work.** Increment 5 (`falsify`, the
mutation tier for hermetic tests) is designed separately in
`2026-08-11-falsify-mutation-tier-design.md` and depends on this one.

## Problem

The suite runs in three places — the PR gate, the nightly schedule, and a
human's host via `verify-on-host.sh` — and nothing states what each is *for*,
nothing enforces a relationship between them, and the relationship that exists
is the wrong way round.

Four defect classes, all found by inspection on 2026-08-11:

**The local layer is a subset, not a superset.** `verify-on-host.sh` has two
phases: 0 (environment) and 4 (integration corpus). It never runs
`tests/run-all.sh`, never runs the `sandbox.conf` schema gate, never lints. PR
CI runs all three. A developer who runs the host script before pushing verifies
*less* than CI will.

**The hermetic suite has never run on BSD userland, and would fail there.** Four
call sites use GNU-only utilities with no fallback, while neighbouring code in
the same suite already handles BSD correctly — so this is inconsistency, not an
unmade decision:

| Site | Construct | On macOS |
|---|---|---|
| `tests/test-allowlists.sh:55` | `stat -c '%n %s %Y'` | BSD `stat` has no `-c` |
| `tests/test-sync-project.sh:52` | `find … -exec stat -c` | same |
| `tests/test-sync-project.sh:34,254,408` | `md5sum` | macOS ships `md5` |
| `tests/test-launcher-migration.sh:33,35,47,49` | `sha1sum` | macOS ships `shasum` |

`tests/test-exec-bits.sh`, `tests/test-integration-fixtures.sh` and
`tests/test-sandbox-schema.sh` already use the `stat -c … || stat -f …`
fallback. The four sites above simply missed it.

**The declared bash floor is wrong in three different directions at once.**

- `sandbox-common.sh:20` enforces **≥ 4.3**.
- `README.md:38` documents **≥ 4.4**.
- `tests/run-all.sh:13`, `tests/integration/lib.sh:11` and
  `tests/integration/run.sh:15` claim the suite is *"written for bash 3.2
  (stock macOS bash)"*.

The 3.2 claim has no consumer. The product refuses to run below 4.3 and says so
with a clear message, so no user can ever execute this code under 3.2 — yet the
tests are held to a stricter standard than the code they test, and cannot model
the product's own idioms (`sandbox.sh` uses `local -A` and `local -n` freely).
Meanwhile `migrate-runme.sh:133` uses `local -A` and never reaches the guard,
so a 3.2 user gets `local: -A: invalid option` mid-migration instead of the
message. Six entry points skip the guard entirely.

Nothing above the floor is in use today, but nothing prevents it either: CI, the
container and a developer's Mac all run different bash versions, and no check
compares any of them against what the product claims to support.

**A selection cannot be previewed.** No flag answers "what would this selection
run?". `--list` deliberately catalogues the whole corpus and documents itself as
ignoring every selection flag, and nothing else offers the answer. For a suite
whose central discipline is that *selection and skipping are different
outcomes*, there is no way to see a selection short of running it — and no way
to check one layer's selection against another's.

## Goals

1. Three named layers with an enforced containment invariant.
2. `local ⊇ nightly ⊇ PR` — checked by a test, not asserted in prose.
3. One bash floor for the whole repository, enforced where it is claimed.
4. The hermetic suite green on macOS.
5. Every new guard demonstrated failing before it is trusted.

## Non-goals

- **No rewrite of existing bash-3.2-style workarounds.** Space-padded
  membership tests (`case " $list " in *" $x "*`) and the
  `"${arr[@]+"${arr[@]}"}"` empty-array ceremony stay exactly as they are.
  Raising the floor permits new code to use `declare -A` and a bare
  `"${arr[@]}"`; it does not licence churning working code.

  One exception, and it is a documentation fix rather than churn:
  `tests/test-open-mode.sh` *asserts* the empty-array ceremony is present and
  explains it with a comment citing bash 4.3. At a 5.1 floor that comment is
  false. The assertion stays — the guarded form is still correct — and the
  comment is corrected to say the ceremony is belt-and-braces below the floor.
  A live file must not document a constraint that no longer exists.
- **No change to the historical plan documents** under
  `docs/superpowers/plans/`. Those record the constraint that applied when they
  were written and are not live claims.
- **No `layers.conf` single-source-of-truth refactor.** Each workflow keeps its
  own selection arguments; the guard reads them and checks containment. Folding
  three workflows and the host script onto one declaration is a larger change
  and is deliberately not bundled with this one.
- **No mutation tier.** That is increment 5.

## The layer model

| Layer | Trigger | Contract |
|---|---|---|
| **PR** | every pull request | fast and cheap; blocks merge |
| **Nightly** | schedule | everything PR runs **+** what is too slow or costly for a PR |
| **Local** — `verify-on-host.sh` | a human, on a real host | everything nightly runs **+** what CI cannot do: macOS, BSD userland, Colima, real network, no cost cap |

The invariant is `local ⊇ nightly ⊇ PR`, over *checks* and over *selected
integration cases*. A check that is too expensive for one layer moves outward,
never disappears.

Two properties follow, and both are load-bearing:

- **Moving a check outward is a decision, not a default.** A check with no layer
  does not exist. The containment test fails on a check present in an inner
  layer and absent from an outer one.
- **The local layer is where platform-specific truth lives.** It is the only
  layer that sees BSD userland. Everything that could differ between GNU and
  BSD is verified there or nowhere.

### Phase numbering in `verify-on-host.sh`

New phases take **new numbers — 5, 6, 7 — never 1, 2 or 3.**

Increment 3 removed phases 1-3 and left a guard (`VALID_PHASES`) whose entire
job is to fail a stale `PHASES="1 2 3"` loudly rather than silently verifying
nothing. Reusing those numbers for different content would make that stale value
valid again and destroy the guard. Phase numbers are identifiers, not running
order.

| Phase | Content | Mirrors | Status |
|---|---|---|---|
| 0 | environment banner | — | existing |
| 4 | integration corpus (whole, no `--tags`) | `integration.yml` | existing |
| **5** | hermetic suite (`tests/run-all.sh`) + `sandbox.conf` schema gate + the same suite at the declared floor, in an `ubuntu:22.04` container | `tests.yml` jobs `suite` and `suite-floor` | new |
| **7** | `bash -n` over every script + dialect linter + `shellcheck` **as a gate** | `tests.yml` job `lint` | new |

Each new phase mirrors one whole CI job rather than a hand-picked step. That is
what makes containment satisfiable by construction: a check added to a CI job
has exactly one obvious place to appear locally, and the guard below has
something concrete to compare. Phase 7 therefore carries the dialect linter too
— it is a PR-layer check, and the invariant requires every PR-layer check to run
locally as well.

Phase 6 is reserved for increment 5's mutation tier and is not created here.

Execution order is 0, 5, 7, 4 — cheap checks first, so a broken hermetic suite
is reported in seconds rather than after an hour of image builds. `VALID_PHASES`
becomes `0 4 5 7`.

`PHASES` today defaults to `4` (`PHASES="${PHASES:-4}"`), which would leave the
new phases off unless asked for — and a local layer nobody selects is not a
local layer. The default becomes `4 5 7`; Phase 0 continues to run
unconditionally, outside `want_phase`. `tests/test-verify-exit-code.sh:155-156`
pins the current default explicitly and must be updated in the same task — it is
a guard doing its job, not an obstacle.

Phase 7 promotes an existing parked item. `.github/workflows/tests.yml:90` runs
`shellcheck … || true` with a comment stating that tightening it to a gate is
*"a deliberate follow-up"* — a follow-up never scheduled. The layer model gives
it a home: advisory in CI, gating locally, where a human is present to act on
it.

## Components

### 1. `run.sh --dry-run` — selection preview

A new flag that applies the same `--tags` / `--exclude` / `--cases` /
`--variant` filtering a real run applies, prints the selected case basenames in
run order, and exits without building an image or starting a container.

**`--list` is deliberately left alone.** Its whole-corpus catalogue behaviour is
not incidental — `usage()` states it outright: *"it has no effect on `--list`,
which always catalogues the whole corpus regardless of any selection flag."*
Redefining a documented contract in place is the failure mode this project
refuses everywhere else (see AGENTS.md on never changing what a `sandbox.conf`
key means while keeping its name). A new flag costs one `case` arm and breaks
nothing.

Zero selection stays fatal, exactly as in a real run: `--dry-run` with a
selection that matches nothing exits non-zero rather than printing an empty
list. That is the same guard that stops a mistyped `--tags` from passing
silently.

This is what makes containment checkable as a set comparison instead of a
reimplementation of the selection logic — the guard asks `run.sh` what it would
select, rather than deciding for itself and being right in one repo and quietly
wrong in the fork.

### 2. `bash-floor.sh` — the extracted version guard

A small sourced file carrying the `BASH_VERSINFO` check currently inlined at
`sandbox-common.sh:19-22`, with the floor stated once:

```sh
AI_CONTAINERS_BASH_FLOOR_MAJOR=5
AI_CONTAINERS_BASH_FLOOR_MINOR=1
```

`sandbox-common.sh` sources it, so the four already-guarded entry points keep
their behaviour and gain the new floor. The six unguarded ones source it
directly rather than pulling in all of `sandbox-common.sh` for a version check.

**The floor is 5.1**, raised from the 4.3 the guard enforces today. macOS
requires a Homebrew bash at any floor above 3.2, so the raise costs macOS users
nothing, and every current Linux target clears it:

| Platform | bash | ≥ 5.1 |
|---|---|---|
| Ubuntu 26.04 / 24.04 (the container base) | 5.3 / 5.2.21 | yes |
| Ubuntu 22.04, Debian 12/11, RHEL·Rocky 9 | 5.1.16 / 5.2.15 / 5.1.4 / 5.1.8 | yes |
| macOS + Homebrew | 5.3 | yes |
| Ubuntu 20.04 | 5.0.17 | no — ESM-only since April 2025 |
| RHEL·Rocky 8 | 4.4.20 | no — supported to 2029 |

A RHEL 8 workstation is the only realistic exclusion, and it is a host-script
concern only: the container is `ubuntu:24.04` (bash 5.2.21), so every
in-container script clears the floor regardless of the host.

What the floor buys, beyond ending the three-way contradiction: `${var@Q}` for
safe requoting, `EPOCHSECONDS`/`EPOCHREALTIME` for timing without forking
`date` — which matters when increment 5 times thousands of mutants — and it
retires the `"${arr[@]+"${arr[@]}"}"` empty-array ceremony for new code.

**The floor is tested, not asserted.** A declared floor that no layer exercises
is precisely the defect this increment exists to remove — the 3.2 claim survived
for months because nothing ran it. CI's `ubuntu-latest` ships bash 5.2, so
without help the 5.1 claim would be untested, and `ubuntu-latest` is a *moving
target*: when GitHub rolls it to 26.04 the tested version silently becomes 5.3
and the gap widens with nobody deciding anything.

So a second CI job, `suite-floor`, runs the hermetic suite inside an
`ubuntu:22.04` container — bash 5.1.16 with GNU coreutils — pinning the floor to
something exercised on every PR. Phase 5 runs the same containerised check
locally, so the invariant holds without an exception carved out for it.

Raising the floor to 5.2 to match CI was considered and rejected: it would drop
RHEL·Rocky 9 (bash 5.1.8, supported to 2032), Ubuntu 22.04 LTS (5.1.16) and
Debian 11 (5.1.4) — a far larger exclusion than RHEL 8, and it would leave the
floor drifting with the runner image anyway.

`README.md`'s 4.4 is corrected to 5.1. A sourced guard is sufficient because
every construct in question (`local -A`, `local -n`, `mapfile`) fails at
*runtime*, not at parse time; the guard runs first and exits before reaching
them.

### 3. The dialect linter

A check that no script uses a construct newer than the declared floor. Runs in
the **PR layer** — static, deterministic, needs no exotic bash.

At a 5.1 floor the three bash versions in play are all *different*, which is
exactly why the check is needed: the container and CI run 5.2, a developer's Mac
runs 5.3, and the floor is 5.1. Nothing else compares them.

Flagged constructs (post-5.1):

| Construct | Introduced |
|---|---|
| `${ command; }` value substitution | 5.3 |
| `BASH_MONOSECONDS`, `BASH_TRAPSIG`, `GLOBSORT` | 5.3 |
| `shopt -s globskipdots`, `noexpand_translation`, `varredir_close` | 5.2 |

The Mac's 5.3 being *ahead* of CI's 5.2 makes this concrete rather than
theoretical: a `${ cmd; }` written comfortably on the host would fail in CI and
in the container. The linter catches it at authoring time with a message naming
the floor, instead of at container start.

The linter reads the floor from `bash-floor.sh`, so raising or lowering the
floor updates what it permits rather than requiring a second edit in a second
place.

### 4. `tests/test-bash-floor.sh`

Asserts that every executable host entry point either sources the guard or uses
no construct above the floor — so a new top-level script cannot quietly skip it.
The list of entry points is **derived** (`git ls-files '*.sh'` at repo root,
minus in-container scripts), never hand-written: a hand-written list can only
validate what someone remembered to add.

### 5. `tests/test-layer-containment.sh`

Enforces the invariant by reading the three definitions directly:

- each check invoked by `.github/workflows/tests.yml` — `run-all.sh`, the schema
  gate, `bash -n`, the dialect linter, `shellcheck` — is also invoked by
  `verify-on-host.sh`
- the PR gate's selected case set ⊆ the nightly jobs' union, computed by asking
  `run.sh --dry-run` with each layer's actual arguments
- the nightly union ⊆ the local layer's selection
- `VALID_PHASES` names exactly the phases `verify-on-host.sh` defines — extended
  from the existing check to cover both directions
- every phase records failure through `phase_fail` (the increment-3 rule,
  restated for the new phases)

The workflow arguments are extracted from the YAML rather than duplicated, so a
change to a workflow's selection is seen by the guard instead of being shadowed
by a stale copy.

**A named-check list can only validate the checks it names**, which is the
failure mode this project has already paid for once, in the mgd port whose
byte-identity gate iterated the same hand-written list it was meant to police.
So the guard also pins the **number of steps** in each `tests.yml` job against a
recorded baseline. Adding a CI step without giving it a layer fails here, at
review time, rather than silently widening the PR gate past the local one. The
baseline is a number with a comment naming what the steps are — cheap to update
deliberately, impossible to drift past accidentally.

### 6. Portability fixes

The four sites in the table above, each taking the fallback idiom already used
elsewhere in the suite:

- `stat -c '%a' f 2>/dev/null || stat -f '%Lp' f 2>/dev/null`
- `sha1sum` → a helper resolving `sha1sum` or `shasum -a 1`
- `md5sum` → a helper resolving `md5sum` or `md5 -q`

The helpers live in one place and are used by both call sites, rather than being
open-coded per test.

## Verification

Every guard is demonstrated failing before it is trusted. The rule has caught
six unfalsifiable checks so far, two of them written inside the fix for another,
so it applies to this increment's own work without exception.

| Guard | Demonstrated by |
|---|---|
| `--dry-run` filtering | a selection whose expected set differs from the whole corpus, so an unfiltered answer fails; plus an empty selection, which must exit non-zero |
| bash floor guard | an entry point stripped of its `source` line must fail `test-bash-floor.sh` |
| dialect linter | a script carrying `${var@Q}` must be rejected |
| layer containment | removing the Phase 5 step from `verify-on-host.sh` must fail the test |
| step-count ratchet | adding a step to a `tests.yml` job without touching `verify-on-host.sh` must fail the test |
| phase validity | `PHASES="1 2 3"` must still fail loudly (the increment-3 behaviour must survive the addition of phases 5 and 7) |
| portability fixes | the hermetic suite passing on macOS, reported from the host |

Demonstrations break the *mechanism* and require the failure — never assert the
expected answer, which is how an unfalsifiable check is born.

The acceptance evidence for the whole increment is one command on macOS:
`bash ./verify-on-host.sh` reporting `RESULT: PASSED — phases [0 4 5 7]`, having
run the hermetic suite on BSD userland for the first time.

## Risks and mitigations

Each risk carries a mitigation that makes it *measured* rather than discovered
late. Where a number could be obtained now, it was.

### R1 — the macOS run surfaces defects beyond the four known sites

Phase 5 runs 39 test files against BSD userland for the first time. The static
scan finds GNU-only *utilities*; it cannot find behavioural differences (BSD
`sed -i` argument handling, `date`, `du` output shape, locale-dependent `sort`).

**Mitigation — measure before committing to the work, in one scheduled
hand-off.** The plan front-loads the portability helpers and the four known
fixes, then reaches a single measurement point: `bash tests/run-all.sh` is run
once on macOS and its output recorded. This session runs on Linux and cannot
perform that step, so it is an explicit hand-off to the human partner at a
planned moment — one round trip, not a discovery loop spread across the
increment. Every dependent task is planned *after* the list exists.

If the list is long, the standing rule applies unchanged: a subset is fixed
before merge and the remainder is carried in a follow-up merge with a ledger
entry each. Nothing is dropped.

### R2 — the shellcheck backlog blocks Phase 7

**Measured, 2026-08-11, shellcheck 0.11.0: 75 findings across 25 files.** No
longer an unknown. The shape matters more than the count:

| Code | Count | Character |
|---|---|---|
| `SC2178` / `SC2128` | 31 | nameref false positives — shellcheck does not model `local -n`; 23 of them in `tests/test-parsers.sh` alone |
| `SC2034` | 24 | unused variable, mostly in sourced libraries where the consumer is another file |
| `SC2154` | 10 | referenced-but-not-assigned, same sourcing cause |
| others | 10 | genuinely worth reading |

**Mitigation — triage, not a baseline file.** Roughly 10-20 findings are
actionable; the rest are structural false positives for a codebase built on
namerefs and sourced libraries. They are handled as (a) real fixes, (b) inline
`# shellcheck disable=SCxxxx` carrying a one-line reason at the nameref sites,
(c) a documented `-e` list for codes that are categorically wrong here. The gate
lands green within this increment. At 75 findings a classified baseline file
would be more machinery than the problem justifies.

### R3 — the step-count ratchet adds friction to every future CI edit

**Mitigation — make updating it a one-line deliberate act.** The baseline is one
number per job with a comment naming the steps it counts, and the failure
message states exactly what changed and what to do. The friction is the point —
a new CI step must be given a layer — but it must cost seconds, not an
investigation.

## Port

Ported to `Dynatrace-Internal/mgd-ai-containers` as a parallel PR. The file list
is derived from `git diff --name-only <merge-base>..HEAD`, never hand-written,
and the byte-identity gate is built from that same derived list. `base/` layout
applies to the engine scripts and `verify-on-host.sh`; `tests/` is at the repo
root in both.
