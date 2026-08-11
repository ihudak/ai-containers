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

Nothing newer than 4.3 is in use today, but CI runs bash 5.x and cannot see the
difference. A `${var@Q}` or `EPOCHSECONDS` would pass every check and break
every 4.3/4.4 user.

**A selection cannot be previewed.** `run.sh --list` ignores `--tags`,
`--exclude`, `--cases` and `--variant`; it prints all 34 cases whatever you
pass. For a suite whose central discipline is that *selection and skipping are
different outcomes*, there is no way to ask what a given selection would run
short of running it — and no way to check one layer's selection against
another's.

## Goals

1. Three named layers with an enforced containment invariant.
2. `local ⊇ nightly ⊇ PR` — checked by a test, not asserted in prose.
3. One bash floor for the whole repository, enforced where it is claimed.
4. The hermetic suite green on macOS.
5. Every new guard demonstrated failing before it is trusted.

## Non-goals

- **No rewrite of existing bash-3.2-style workarounds.** Space-padded
  membership tests (`case " $list " in *" $x "*`) stay exactly as they are.
  Raising the floor permits new code to use `declare -A`; it does not licence
  churning working code.
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
| **5** | hermetic suite (`tests/run-all.sh`) + `sandbox.conf` schema gate | `tests.yml` job `suite` | new |
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
becomes `0 4 5 7`, and `PHASES` continues to default to every valid phase.

Phase 7 promotes an existing parked item. `.github/workflows/tests.yml:90` runs
`shellcheck … || true` with a comment stating that tightening it to a gate is
*"a deliberate follow-up"* — a follow-up never scheduled. The layer model gives
it a home: advisory in CI, gating locally, where a human is present to act on
it.

## Components

### 1. `run.sh --list` honours the selection flags

`--list` gains the filtering that `--tags`, `--exclude`, `--cases` and
`--variant` already apply to a real run, and prints the cases that selection
would run. With no selection flags the output is byte-identical to today's, so
the existing `Case corpus` steps in both workflows are unaffected.

This is what makes containment checkable as a set comparison instead of a
reimplementation of the selection logic — the guard asks `run.sh` what it would
select, rather than deciding for itself and being right in one repo and quietly
wrong in the fork.

Zero-selection stays fatal, exactly as in a real run: `--list` with a selection
that matches nothing exits non-zero rather than printing an empty list.

### 2. `bash-floor.sh` — the extracted version guard

A small sourced file carrying the `BASH_VERSINFO` check currently inlined at
`sandbox-common.sh:19-22`, with the floor stated once:

```sh
AI_CONTAINERS_BASH_FLOOR_MAJOR=4
AI_CONTAINERS_BASH_FLOOR_MINOR=3
```

`sandbox-common.sh` sources it, so the four already-guarded entry points are
unchanged in behaviour. The six unguarded ones source it directly rather than
pulling in all of `sandbox-common.sh` for a version check.

The floor is **4.3** — what the code actually requires (`local -n`, bash 4.3).
`README.md`'s 4.4 is corrected to match. Raising the floor later is a two-line
change here plus one entry in the dialect linter.

A sourced guard is sufficient because every construct in question
(`local -A`, `local -n`, `mapfile`) fails at *runtime*, not at parse time; the
guard runs first and exits before reaching them.

### 3. The dialect linter

A check that no script uses a construct newer than the declared floor. Runs in
the **PR layer** — static, deterministic, needs no exotic bash. It is the only
thing standing between a CI runner on bash 5.x and a user on 4.3.

Flagged constructs (all post-4.3):

| Construct | Introduced |
|---|---|
| `${var@Q}` `@E` `@P` `@A` `@a` | 4.4 |
| `mapfile -d` / `readarray -d` | 4.4 |
| `EPOCHSECONDS`, `EPOCHREALTIME`, `BASH_ARGV0`, `wait -f`, `localvar_inherit` | 5.0 |
| `SRANDOM`, `${var@U}` `@u` `@L` `@K` `@k` | 5.1 |

The linter reads the floor from `bash-floor.sh`, so raising the floor updates
what it permits rather than requiring a second edit in a second place.

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
  `run.sh --list` with each layer's actual arguments
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
| `--list` filtering | a selection whose expected set differs from the corpus; unfiltered `--list` must produce the wrong answer |
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

## Risks

**The macOS run will surface defects beyond the four known sites.** Phase 5 runs
39 test files against BSD userland for the first time; the static scan finds
GNU-only *utilities*, but not behavioural differences (BSD `sed -i` argument
handling, `date`, `du` output shape, locale-dependent `sort`). Unknown until it
runs. Per the standing rule, everything found is fixed — one before merge, the
rest in a follow-up merge, none dropped.

**Phase 7 may produce a large shellcheck backlog.** The advisory has been
accumulating since it was added. If the count is large it lands as a
classified baseline rather than a wall of failures, using the same
classify-or-fail discipline chosen for increment 5's survivor ledger.

## Port

Ported to `Dynatrace-Internal/mgd-ai-containers` as a parallel PR. The file list
is derived from `git diff --name-only <merge-base>..HEAD`, never hand-written,
and the byte-identity gate is built from that same derived list. `base/` layout
applies to the engine scripts and `verify-on-host.sh`; `tests/` is at the repo
root in both.
