# `falsify` — a Mutation Tier for the Hermetic Suite — Design

**Increment 5.** Designed and approved in substance on 2026-08-11, then
deferred behind increment 4 (`2026-08-11-execution-layers-and-portability-design.md`),
which settles the bash floor this harness is written against and creates the
layer model its work is assigned to. Not yet planned.

## Problem

`tests/test-mutations.sh` makes the *"a case is not accepted until it has been
seen failing"* rule mechanical for the integration corpus. Nothing enforces it
for the 39 hermetic test files in `tests/*.sh` — ~635 assertion sites.

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

`entrypoint.sh` and `sandbox.sh` are only grepped by hermetic tests — nothing
runs them, so nearly every mutant would survive as noise. They belong to the
integration tier. Eleven files qualify:

| Group | Files |
|---|---|
| harness | `tests/integration/{lib,run,mutate,docker-shim,minimal-conf}.sh` |
| product | `sandbox-common.sh`, `repo.sh`, `build.sh`, `install-tools.sh`, `sync-to-projects.sh`, `tools-lib.sh` |

`targets.conf` maps each target to its oracle tests. It is **derived, then
checked**: the candidate list comes from grepping the tests for what they
source, and an executed file missing from the map fails the gate. Excluding one
requires an explicit `EXCLUDED: <reason>`. A hand-written list can only validate
what someone remembered.

### The oracle

The runner invokes `tests/run-all.sh <name>` — not the test file directly — so
the killed/survived verdict is literally the same code path as the suite's own
(`FAIL:` line present, or non-zero exit, or asserted nothing). The two cannot
drift apart. Measured overhead: 55 ms.

A mutant that exceeds a per-mutant timeout counts as killed and is flagged.
A mutant that fails `bash -n` is discarded, not counted — a syntax error proves
nothing about any assertion.

### Operators and layers

Measured against the eleven targets. The full seven-operator set produces 4,742
mutants; `num-bump` alone is 655 of near-pure noise (array indices, `2>&1`, exit
codes) hiding perhaps five real thresholds.

| Operators | Layer | Mutants | Cost |
|---|---|---|---|
| `cond-negate`, `logic-flip`, `stream-flip`, `return-flip`, `cmp-flip` | **PR** | 935 | ~7 min at 8-way |
| `threshold` — explicit hand-listed sites | **PR** | ~5 | negligible |
| `stmt-delete`, enabled per-target | **Nightly** | ≤ 3,068 | ~32 min at 8-way |
| full matrix, on the host | **Local** (Phase 6) | — | 30-60 min |

`num-bump` is dropped rather than deferred: its problem is signal, and a longer
schedule does not fix signal. Rubber-stamping 400 `EQUIVALENT` entries is how a
ledger stops being read, which would undermine the gate protecting everything
else.

`stmt-delete` is the operator whose shape matches holes #3 and #4 most directly
— a behaviour silently missing — so it is enabled per target by a **measured**
criterion, not a guess: a target qualifies once its mutation score under the
five PR operators clears a threshold. A file whose oracle already kills ~95% of
gated mutants will kill most deletions too, yielding few and sharp survivors. A
file whose oracle kills 60% would flood the ledger with the same underlying gap
restated two hundred times. Fix the gap first, then deepen. The threshold is set
from the first full run's numbers.

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
- **Validation against the four historical holes.** All four are recoverable
  from git history. Each unfalsifiable assertion is reconstructed, the
  corresponding mutant is run, and the harness must report `SURVIVED`. A tool
  that cannot catch the bugs that motivated it does not ship.

## Naming

`tests/falsify/` — deliberately not `tests/mutation/`, which sits two letters
from the existing `tests/integration/mutations/` and would be conflated within a
week. The name states the property being measured rather than the technique.

## Risks

**Survivor count is unknown until the generator first runs.** At 935 mutants and
a plausible 8-20% survival rate that is roughly 75-190 entries to classify, and
it cannot be sized more tightly in advance. The classified-ledger policy is what
bounds it: every survivor is *classified* in this increment; `GAP` entries are
owed assertions and may be paid down in a follow-up.

**`stmt-delete` triage could still flood.** Mitigated by the measured per-target
entry criterion above, which is why that criterion exists.

## Non-goals

- No coverage percentage or mutation score as a target — the ledger is the
  artifact. Scores inform which targets earn `stmt-delete`, nothing more.
- No mutation of heredoc bodies.
- No replacement of `tests/integration/mutations/`; different tier, different
  economics.

## Port

Ported to `Dynatrace-Internal/mgd-ai-containers` as a parallel PR, with the file
list derived from `git diff --name-only`, never hand-written.
