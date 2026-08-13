# Layer-containment registry, and the nightly checks leg — design

**Date:** 2026-08-12
**Status:** approved
**Predecessor:** `2026-08-11-execution-layers-and-portability-design.md` (increment 4, merged as PR #18 / mgd #16)

## Goal

Close the three holes increment 4 left in its own containment guard, and clear
the eleven mechanical defects it parked, so that increment 5 (`tests/falsify`)
measures a final tree rather than one still under repair.

## Why now, before increment 5

Increment 5 mutates `tests/integration/lib.sh`, `run.sh`, `mutate.sh` and the
production scripts. The work below rewrites `tests/test-layer-containment.sh`
and `tests/lib-verify-repo.sh` and adds a workflow file. Doing it after would
mean classifying the same survivors twice — and the two unexercised guards
(§6.9, §6.10) would surface as falsify survivors needing adjudication rather
than as the known defects they already are.

---

## 1. The defect

Increment 4 replaced the containment guard's text-grep rows with effect
witnesses, and that fix holds — for the rows that exist. What it did not fix is
**what forces a row to exist at all**.

Three lists must currently agree, and nothing makes them:

| List | Location |
|---|---|
| which stubs emit a witness line | `tests/lib-verify-repo.sh`, five hardcoded `printf` blocks |
| which checks are asserted | `tests/test-layer-containment.sh:99-104`, the `CHECKS` heredoc |
| how many steps each CI job has | `tests/test-layer-containment.sh:148-150`, `expect_steps 5 5 4` |

Add a new locally-run check and the step-count ratchet fires — but **bumping the
baseline plus adding the invocation to `verify-on-host.sh` is sufficient to go
green.** Nothing forces a matching stub or `CHECKS` row, so the new check runs
locally with zero effect-based verification: the same "unverified because nobody
remembered" failure the guard exists to close, one level up.

Two demonstrated bypasses:

- **Add a fourth job to `tests.yml` → 0 failures.** `expect_steps` is called
  with a hardcoded list of three job names. A new job is entirely invisible: no
  `CHECKS` row, no step count, no witness. It widens the PR gate past the local
  one with nothing noticing.
- **Restore `|| true` to CI's shellcheck step → 0 failures.** Each row's CI half
  is `grep -qE "$ci_re" "$TESTS_YML"` (line 110) — a substring match anywhere in
  the file, sitting directly beside the witness-based local half at line 119.
  It is the same shape as the defect the local half was fixed for.

And the third hole, recorded in `AGENTS.md` and deferred to a human:

- **`nightly ⊇ PR` is false over checks.** `nightly.yml` has four jobs
  (`integration-full`, `allowlist-health`, `packages-agents`, `packages-native`);
  `tests.yml` has three (`suite`, `suite-floor`, `lint`). Zero overlap. The
  documented three-layer contract holds over integration *cases* only.

---

## 2. The nightly checks leg — a reusable workflow

**Decision:** make the invariant true rather than narrow the claim.

Measured cost of the three hermetic jobs, from run `31587927837`:

| Job | Duration |
|---|---|
| Shell test suite | 46s |
| Shell test suite (bash floor) | 58s |
| Shell lint | 31s |

≈2¼ runner-minutes, ≈1 minute wall clock in parallel. Cost is not the deciding
factor, so the decision turns on duplication.

Create `.github/workflows/hermetic-checks.yml` holding `suite`, `suite-floor`
and `lint` **verbatim**, with `on: workflow_call` and its own
`permissions: contents: read`. `tests.yml` and `nightly.yml` each become
callers:

```yaml
jobs:
  hermetic:
    uses: ./.github/workflows/hermetic-checks.yml
```

Copying the three job definitions into `nightly.yml` instead was rejected: it
creates a second copy that must stay in step with the first, which is the
drifted-duplicate-list failure this repo keeps getting bitten by
(`shared-files.sh`, the `CHECKS` table, the mgd byte-identity gate). A guard
proving the two copies never drift is more machinery than the reusable workflow
it would be avoiding.

**Nightly's caller carries `if: github.event_name == 'schedule'`.**
`nightly.yml`'s `workflow_dispatch` inputs exist for mutation demonstrations,
which deliberately break production files; `run-all.sh` would go red there for
reasons unrelated to what the demonstration is proving. The invariant concerns
the scheduled nightly layer. The guard pins that exact condition, so `if: false`
cannot be substituted.

Beyond making the invariant true, the nightly run catches external drift on
`main` rather than in an unlucky PR: a new `shellcheck` release tightening the
gate, an `ubuntu:22.04` image update, an `actions/checkout` deprecation.

**Check-context rename.** `Shell test suite` becomes `hermetic / Shell test
suite`. Neither repo has branch protection with required checks (verified
2026-08-12, both return 404), so this is cosmetic today; it would need attention
if protection is added later.

---

## 3. The registry

One file defines each hermetic check once. Two consumers read it, replacing
three hand-maintained lists with one.

**`tests/layer-checks.conf`** — data, `|`-delimited, `#` comments. Two row
types, discriminated by the first field:

```
check|<id>|<job>|<ci_step>|<stub_kind>|<stub_target>|<rc_var>|<witness_target>|<witness_re>
setup|<job>|<ci_step>|<why it is not a check>
```

The `check` rows:

| id | job | ci step | kind | witness |
|---|---|---|---|---|
| `hermetic-suite` | `suite` | `Run tests` | `repo-script` | `^STUB:run-all\.sh$` |
| `schema-gate` | `suite` | `sandbox.conf schema gate` | `repo-script` | `^STUB:check-sandbox-version\.sh$` |
| `floor-suite` | `suite-floor` | `Run tests at the declared floor` | `none` | `^STUB:docker-run .*@FLOOR_IMAGE@` |
| `bash-n` | `lint` | `bash -n over every script` | `probe` | `PARSE ERROR: .*broken-syntax-probe\.sh` |
| `dialect-lint` | `lint` | `bash dialect (nothing newer than the declared floor)` | `repo-script` | `^STUB:bash-dialect-lint\.sh$` |
| `shellcheck` | `lint` | `shellcheck` | `path-bin` | `^STUB:shellcheck$` |

Stub kinds:

- **`repo-script`** — an executable at `<stub-repo>/<target>` printing
  `STUB:<basename>` to `$WITNESS_LOG`, exiting `${<rc_var>:-0}`.
- **`path-bin`** — the same, at `$TMP/bin/<target>`, ahead of the real tool on
  `PATH`.
- **`none`** — contributes an assertion but no stub. `floor-suite`'s witness is
  produced by the `docker` stub, which `lib-verify-repo.sh` must create anyway
  as Phase-0 infrastructure. A `none` row still declares a witness regex, so it
  carries the same proof obligation as any other row.
- **`probe`** — no stub; the check's effect is read from `verify-on-host.sh`'s
  own output. `mk_repo()` plants `<target>` containing a deliberate syntax
  error, before its `git add`/`commit`, so `git ls-files` sees it.

`@FLOOR_IMAGE@` is substituted from the floor→image map (§5).

**`tests/lib-layer-checks.sh`** — the parser, sourced by both consumers. Named
`lib-*` so `tests/run-all.sh`'s `test-*.sh` glob skips it, matching
`lib-verify-repo.sh`'s precedent. It must **fail loudly on an empty parse** —
zero rows, or zero rows of a requested type — never return empty quietly.

### Consumer changes

**`tests/lib-verify-repo.sh`** — `mk_repo()` iterates the registry instead of
five hardcoded `printf` blocks. The `docker` stub stays hand-written
(infrastructure, not a check).

The probe is **opt-in via `MK_REPO_PROBE=1`**, not planted unconditionally:
`tests/test-verify-exit-code.sh` shares `mk_repo()` and asserts canned exit
codes, and an always-present broken file would make its Phase 7 fail
independently of the RC under test. Only `test-layer-containment.sh` sets it.
This also moves the probe out of `test-layer-containment.sh:80-82`, so every
stub is created in one place.

**`tests/test-layer-containment.sh`** — builds its assertions from the registry.
Each `check` row yields two assertions:

1. its `ci_step` is present in the named job of `hermetic-checks.yml` — an
   **exact step-name match**, replacing today's substring-anywhere grep
2. its witness regex matches the declared haystack after a real `run_verify`

---

## 4. Step classification replaces the count ratchet

Parse `hermetic-checks.yml`. For every step of every job, resolve its identity —
the value of `name:` if present, else `uses:` — and classify:

- matches a `check` row's `ci_step` → **check**, must show its witness
- matches a `setup` row → **setup**, explicitly declared a non-check
- neither → **FAIL**: `step '<X>' in job '<Y>' is neither a registry check nor
  declared setup — classify it`

Matching is bidirectional: every `check` row's `ci_step` must also be found in
the YAML, which is how a removed step is caught.

This closes the "add a fourth job → 0 failures" hole, because the job list is
**derived from the file** rather than hardcoded as three names.

It also upgrades the *remedy*. The count ratchet's fix was "change 5 to 6".
This one's is "declare what your step is" — and declaring it a check forces a
registry row, which forces a stub and a local invocation, or the witness grep
fails. The `setup` rows remain an escape hatch, but a named and reviewable one:
each carries a required `why` field, and a reviewer reading
`setup|lint|shellcheck|not a check` will object.

**`expect_steps 5 5 4` is removed, not dropped.** If every step classifies and
every classification finds a step, the counts match by construction — the
assertion becomes redundant by proof rather than by omission.

### The YAML parser

Narrow `awk` over the exact shape these workflow files use:

```
jobs:
  <job>:
    steps:
      - uses: <x>
      - name: <y>
        run: |
```

Contract:

- `wf_jobs <file>` → job ids, one per line
- `wf_steps <file> <job>` → step identities, one per line
- a step's identity is its `name:` value, else its `uses:` value; surrounding
  quotes stripped; everything after `name: ` kept, including colons (one real
  step name contains one)
- **exits non-zero with a message on zero jobs, or on any job with zero steps**

A parser that silently returns nothing is this repo's signature defect, so it
gets its own fixture test rather than being trusted: `tests/test-layer-checks-parser.sh`
feeds it a well-formed two-job fixture and asserts exact output, then a
jobs-less fixture, a job with no steps, a quoted name containing a colon, and a
`uses:`-only step.

---

## 5. The floor→image map moves into `bash-floor.sh`

The `5.1 → ubuntu:22.04` map currently lives in `tests/test-layer-containment.sh:158-162`,
but the registry needs the image too (`floor-suite`'s `@FLOOR_IMAGE@`).
`AGENTS.md` states the floor is *"declared exactly once, in `bash-floor.sh`"* —
the image that tests it is part of that declaration. One edit when the floor
moves, not three.

### The floor stays 5.1 — re-decided 2026-08-12 with measurement

Raising it to 5.2 (ubuntu:24.04) was reconsidered and rejected again, on
different grounds than in `8b6c965`.

Measured from run `31587927837`:

| Environment | bash |
|---|---|
| `suite` (ubuntu-latest) | 5.2.21 |
| `suite-floor` (ubuntu:22.04) | 5.1.16 |
| container base (ubuntu:24.04) | 5.2.21 |

At a 5.2 floor, `suite-floor` on ubuntu:24.04 would run **5.2.21 — identical to
`suite`**. The floor job stops being a test and becomes a duplicate of its
neighbour, returning the floor to *asserted* rather than *tested*: exactly the
defect increment 4 existed to close.

Three further points:

- **Cost of keeping 5.1 is 12 seconds** (58s vs 46s, nearly all of it the
  container job's `apt-get install git rsync`) plus one ~30MB image.
- **The bump does not remove the dialect linter.** macOS runs 5.3, so two
  versions remain in play and the linter's only change is four fewer rules.
- **It defers rather than removes the structure.** When `ubuntu-latest` rolls to
  26.04, `suite` becomes 5.3 and a 5.2 floor is untested again.

Conceded: Debian 11's LTS ended this month, so the exclusion set is now two, not
three — RHEL/Rocky 9 (5.1.8, maintenance to 2032) and Ubuntu 22.04 LTS (5.1.16,
standard support to April 2027).

---

## 6. Parked defects cleared in this increment

Carried from `.superpowers/sdd/2026-08-11-execution-layers-and-portability/deferred-minors.md`
and increment 4's final review. No design content; listed so coverage is
traceable and nothing is dropped.

1. **`stat -c … || stat -f …` is a latent GNU trap.** On GNU, `-f` means
   `--file-system`, so the fallback does not error — it prints filesystem info.
   Harmless at every current call site; wrong for anyone reusing the idiom.
   Route through `tests/portability.sh`.
2. **Phase 7 reports success with no positive evidence.** It prints
   `parsed N script(s)` for `bash -n` and nothing for the dialect linter or
   shellcheck. Emit a count for each.
3. **GNU `xargs` without `-r`.** A zero-file shellcheck run still executes once,
   firing a second redundant `phase_fail 7` for one root cause.
4. **`boot_case()` never exercises its `command not found` branch** — the
   fixture always stubs `rvm` as a real binary.
5. **`tests/test-parsers.sh:407-412`** keeps a scratch-copy list missing four
   engine scripts that `shared-files.sh` names: `rvm-reconcile.sh`,
   `link-default-ruby.sh`, `agent-tools-reconcile.sh`, `link-agent-tools.sh`.
   (Recorded as `:323-327`; the line moved.) Not a second definition of the
   shared list — the test drives `project-init.sh` in isolation and does not
   depend on those four — but a fixture that silently diverges from the thing it
   fixtures is worth closing.
6. **`verify-on-host.sh:349`** comment says "the only remaining phase", stale
   now that three phases are selectable. (Recorded as `:293` in the deferred
   list; the line moved during increment 4's fix wave.)
7. **Three "why this cut" comments** (dry-run / wrapped-block / `IT_SOURCE_ONLY`)
   can drift apart; cross-reference them.
8. **`EXTRA_MOUNTS` (`sandbox.sh:351`) and `PREVIEW_PORTS` (`sandbox.sh:776`)
   still pathname-expand.** Increment 4's `split_repos_env()` fixed `REPOS`
   only. Same `set -f` treatment, same exact-state restore.
9. **`tests/bash-dialect-lint.sh:84-87` is unexercised.** Replacing its fatal
   with `exit 0` produces zero test failures — the "examined no files" guard is
   itself unverified.
10. **`verify-on-host.sh:279` is unexercised.** The `bash -n parsed no files`
    branch never runs in any fixture.
11. **Report-hygiene nits** from increment 4's task reports. Nothing to change
    in code; closed as recorded.

Items 9 and 10 are the same class as the eleven "checks that could not fail"
increment 4 found and fixed, and are the only two of that family still open.

---

## 7. Demonstrations

Every new guard is seen failing before it is trusted, per this project's
standing rule. Each mutation is applied, the guard run, red observed, then
reverted.

| Mutation | Expected |
|---|---|
| Add a fourth job with an unclassified step to `hermetic-checks.yml` | FAIL (today: 0 failures) |
| Add an unclassified step to `lint` | FAIL |
| Delete a `check` row's stub creation from the registry | FAIL — witness missing |
| Delete `nightly.yml`'s `uses:` caller | FAIL |
| Change nightly's caller `if:` to `false` | FAIL |
| Feed the parser a jobs-less YAML | FAIL loudly, non-zero, not silently empty |
| Feed the parser a job with `steps:` and no steps | FAIL |
| Point `suite-floor` at `ubuntu:24.04` with floor 5.1 | FAIL (existing assertion, retargeted) |
| Replace `bash-dialect-lint.sh`'s empty-file fatal with `exit 0` | FAIL (§6.9 — today: 0 failures) |
| Replace `verify-on-host.sh`'s parsed-no-files `phase_fail` with a no-op | FAIL (§6.10) |
| `EXTRA_MOUNTS='*'` in a directory containing files | mounts are the literal `*`, not the expansion (§6.8) |

---

## 8. Non-goals

- **`verify-on-host.sh` does not derive its invocations from the registry.** The
  local side carries real per-check logic — `BASE_REF` resolution, the floor
  container's `docker run`, the `xargs` pipeline. Table-driving that would be
  over-engineering. The registry describes *identity and witness*, so the two
  lists agree; it does not generate the work.
- **No change to which checks run in which layer**, beyond nightly gaining the
  three it lacked. The set of hermetic checks is unchanged.
- **Increment 5 is not started here.** Phase 6 stays absent from
  `VALID_PHASES`.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| The awk YAML parser breaks on a reformat of the workflow file | It fails loudly — zero jobs or zero steps is a hard error, never a silent pass. A break makes the whole guard red, which is the safe direction. Fixture test pins the contract. |
| `setup` rows are an escape hatch someone abuses to silence the guard | Each requires a stated reason and is visible in review. The alternative — deriving check-ness from the step's `run:` body — is heuristic and would fail in both directions. |
| Reusable workflow renames CI check contexts | Verified 2026-08-12: neither repo has branch protection (both 404), so nothing depends on the old names today. Recorded here in case protection is added. |
| mgd port drifts from upstream | Same files, byte-identical where the `base/` layout allows; `tests/test-layer-containment.sh` already carries the `ENGINE_DIR` fallback both layouts need. Ported in a parallel PR, as with increment 4. |
| The registry becomes a third list nobody updates | It is the *only* list — the three it replaces are deleted, not supplemented. The step-classification assertion fails if a step exists with no row. |

---

## 10. Files

**Created**

- `.github/workflows/hermetic-checks.yml`
- `tests/layer-checks.conf`
- `tests/lib-layer-checks.sh`
- `tests/test-layer-checks-parser.sh`

**Modified**

- `.github/workflows/tests.yml` — thin caller
- `.github/workflows/nightly.yml` — caller, schedule-gated
- `tests/lib-verify-repo.sh` — registry-driven stubs, opt-in probe
- `tests/test-layer-containment.sh` — registry-driven assertions, step
  classification, retargeted to `hermetic-checks.yml`
- `bash-floor.sh` — floor→image map
- `verify-on-host.sh` — §6.2, §6.3, §6.6, §6.10
- `sandbox.sh` — §6.8
- `tests/portability.sh` — §6.1
- `tests/bash-dialect-lint.sh` + its test — §6.9
- `tests/test-parsers.sh` — §6.5
- `tests/test-rvm-reconcile.sh` — §6.4 (`boot_case()` lives here, not in
  `tests/integration/lib.sh`)
- `AGENTS.md`, `CHANGELOG.md`, `README.md`
