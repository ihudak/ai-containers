# `falsify` — Mutation Tier + Network-Tier Demonstrations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make *"a check is not accepted until it has been seen failing"* mechanical for the hermetic suite (new `tests/falsify/` tier) and for the integration corpus's network/security cases (the existing patch mechanism, extended to the tier it never covered).

**Architecture:** Two independent halves, deliberately ordered network-first. Tasks 1-3 need **no new machinery** — they convert demonstrations already recorded as prose into `tests/integration/mutations/*.patch` and extend one tag filter. Tasks 4-11 build the mutation harness: generator → oracle → ledger → gate, staged behind a mechanical target-entry rule.

**Tech Stack:** bash 5.1 (the declared floor), `git apply`, `tests/run-all.sh` as the oracle, GitHub Actions.

**Source spec:** `docs/superpowers/specs/2026-08-11-falsify-mutation-tier-design.md` (revised 2026-08-14 — read the revision note first; four things changed after measurement).

## Global Constraints

- **Bash floor is 5.1**, declared once in `bash-floor.sh`. `declare -A`, `wait -n`, `EPOCHREALTIME` are available. `tests/bash-dialect-lint.sh` gates anything newer; a legitimately-flagged line carries `# dialect-lint: allow RULE-ID: reason` (the reason is required and checked).
- **Assert effect, never source text.** No guard may be satisfied by a filename appearing in a comment. This repo has been bitten four times by exactly that.
- **Every guard must be demonstrated failing**, and the demonstration must name the exact variable or output line the assertion reads, and confirm the break reaches it. A demonstration that would pass while proving nothing is a plan failure.
- **The runner never mutates the working tree.** Scratch trees only. `tests/integration/mutate.sh` mutates the real tree on purpose; these are opposite choices and both are correct.
- **`stream-flip` is dropped** from the default operator set. It exists in the generator, gated off, reachable per-target — Task 9 needs it.
- **Never mutate heredoc bodies.**
- **shellcheck is a gate**, not advisory: `git ls-files '*.sh' | xargs shellcheck -S warning -e SC1091` must pass. Suppress structurally at the site with `# shellcheck disable=SCxxxx: reason`.
- **`tests/layer-checks.conf` is the single registry** for hermetic checks. A new CI job or local check is added there, never as a fourth hand-maintained list.
- Ledger entries are `<file>:<operator>:<sha1 of trimmed original line>` — **never** `file:line`.
- Port everything to `Dynatrace-Internal/mgd-ai-containers` as a parallel PR, file list derived from `git diff --name-only`, never hand-written.

---

# Part A — the network/security tier (no new machinery) — **COMPLETE 2026-08-14**

All 14 network cases carry a mutation demonstrated FAILING on a real host with a
real assertion line. Deviations from this plan, each with its reason:

- **Tasks 1-3 as written, plus two the plan did not anticipate.** The mutations
  recorded for `070` and `230` were already the shipped configuration
  (`ef78b62` records both having been run as mutations and both PASSING), so the
  other recorded mutation for that pair was used; it damages
  `tests/integration/lib.sh`, which both cases consume, so it is **one patch
  declaring two cases**. `test-mutations.sh` validates every declared name now,
  not `head -1`.
- **Task 3's ratchet needed more than the tag filter.** With only the filter,
  narrowing it back made 15 coverage assertions *vanish* rather than fail. Every
  case is now classified tier-covered or explicitly exempt with a reason.
- **`080` needed `# timeout: 900`** as part of its mutation: `it_wait` counts
  iterations, not seconds, and its predicate blocks for 5s per poll.
- **A case was written, demonstrated, and withdrawn as a false positive.** It
  tried to cover `sandbox.sh`'s open-mode capability suppression through
  `sandbox_up`, which composes its own `docker run` and never invokes
  `sandbox.sh` — so it failed for an unrelated reason while reporting
  "demonstrated". Replaced by `tests/test-mode-capabilities.sh` (hermetic, fake
  `docker`). **If you are adding coverage for a launcher decision, it cannot go
  in a network case.**
- Open at merge, in `docs/superpowers/specs/2026-08-14-falsify-backlog.md`: F5
  (`300` needs a Dockerfile mutation + image rebuild), F6 (`it_wait`'s
  contract), F7 (rename `230`).

### Task 1: Convert the twelve recorded mutations into patches

**Files:**
- Create: `tests/integration/mutations/010-sidecar-allowlisted.patch` and eleven siblings (see table)
- Reference (read-only): `docs/superpowers/plans/2026-08-06-integration-test-suite-increment-1.md` lines 1448, 1833, 1960, 2199 — the four "Known-bad mutation" tables

**Interfaces:**
- Consumes: the existing patch format — a `# case: <basename-without-.sh>` header line, then a `git diff` body. See `tests/integration/mutations/400-ro-suffix-dropped.patch`.
- Produces: patches that `tests/integration/mutate.sh apply <id>` can apply and `revert` can reverse.

Each patch encodes the mutation recorded for its case:

| Case | Recorded mutation |
|---|---|
| `010` | allowlist the sidecar |
| `020` | allowlist nothing |
| `030` | drop the `--add-host` argument |
| `040` | `allowlist_write "$adir" "" "$IT_SIDECAR_IP" ""` |
| `060` | bind-mount fixture #1 (`capture-blocked-traffic.prefix.sh`) |
| `070` | `--privileged` with no drop |
| `080` | `-e SELF_HEALING_ENABLED=0` |
| `085` | remove `-e SELF_HEALING_ENABLED=0` |
| `110` | `sandbox_up restricted` instead of `discovery` |
| `120` | `-e DISCOVERY_CAPTURE_ENABLED=0` |
| `220` | `sandbox_up restricted` instead of `open` |
| `230` | `sandbox_up discovery` instead of `open` |

- [ ] **Step 1: Read the format from an existing patch**

```bash
head -20 tests/integration/mutations/400-ro-suffix-dropped.patch
bash tests/integration/mutate.sh list
```

- [ ] **Step 2: For each case, produce the patch by making the edit and capturing it**

Work one case at a time, on a clean tree:

```bash
# example for 010
$EDITOR tests/integration/cases/010-restricted-blocks-unlisted.sh   # apply the recorded mutation
{ printf '# case: 010-restricted-blocks-unlisted\n'
  printf '# what: the sidecar is allowlisted, so the destination it should block is reachable\n'
  printf '#\n'
  git diff -- tests/integration/cases/010-restricted-blocks-unlisted.sh
} > tests/integration/mutations/010-sidecar-allowlisted.patch
git checkout -- tests/integration/cases/010-restricted-blocks-unlisted.sh
```

The `# what:` line is not decoration — `mutate.sh list` prints it, and it is what a reader sees when deciding whether a mutation still describes a real bug.

- [ ] **Step 3: Verify every patch applies and reverses cleanly**

```bash
for p in tests/integration/mutations/{010,020,030,040,060,070,080,085,110,120,220,230}-*.patch; do
  id="$(basename "$p" .patch)"
  bash tests/integration/mutate.sh apply "$id"  || { echo "APPLY FAILED: $id"; break; }
  bash tests/integration/mutate.sh revert       || { echo "REVERT FAILED: $id"; break; }
done
git diff --quiet && echo "tree clean after all 12"
```
Expected: no `APPLY FAILED` / `REVERT FAILED`, and a clean tree at the end.

- [ ] **Step 4: Confirm `test-mutations.sh` sees the new patches**

```bash
bash tests/run-all.sh test-mutations
```
Expected: PASS, with a higher patch count than before (was 20, now 32). The coverage loop still does not check these cases — that is Task 3.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/mutations/
git commit -m "test(integration): patch-ify the twelve recorded network-tier mutations

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Author the two demonstrations that were never recorded

**Files:**
- Create: `tests/integration/mutations/050-capture-not-started.patch`
- Create: `tests/integration/mutations/210-firewall-applied.patch`
- Read: `tests/integration/cases/050-restricted-capture-starts.sh`, `tests/integration/cases/210-open-no-firewall.sh`

**Interfaces:**
- Consumes: the same patch format as Task 1.
- Produces: nothing later tasks import.

`050` and `210` are the two network cases with no failing demonstration on record. `050` has only a "must still PASS against the known-bad daemon with a populated allowlist" observation — a real and valuable asymmetry, but the opposite of what is needed here. `210` has nothing at all.

- [ ] **Step 1: Read both cases and identify what each actually asserts**

State it explicitly before writing anything: `050` asserts the capture daemon *started*; `210` asserts *no firewall* is applied in open mode. The mutation must make that specific assertion false — not merely break the case.

- [ ] **Step 2: Write `050`'s mutation**

The case asserts the daemon is running. A mutation that prevents it starting must be observable *as that assertion failing*, not as a container that never came up. Bind-mounting a non-executable stand-in over `/usr/local/bin/capture-blocked-traffic.sh` is the shape that matches the real incident (see `tests/test-integration-fixtures.sh`'s header on mode-vs-content).

- [ ] **Step 3: Write `210`'s mutation**

`210` asserts open mode applies no firewall. Launching it as `sandbox_up restricted` makes that false — the mirror of `220`'s recorded mutation.

- [ ] **Step 4: Demonstrate BOTH failing — this is the point of the task**

```bash
bash tests/integration/mutate.sh apply 050-capture-not-started
tests/integration/run.sh --reuse-image --cases 050-restricted-capture-starts
```
Expected: `050 … FAIL`. Record the **exact assertion line** printed. Then `mutate.sh revert` and repeat for `210`.

A mutation that makes the case ERROR (container failed to start) rather than FAIL (assertion false) does not count and must be reworked — an errored case proves the harness noticed something broke, not that the assertion can fail.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/mutations/
git commit -m "test(integration): demonstrate 050 and 210 failing for the first time

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Extend the coverage ratchet to `network-mode`

**Files:**
- Modify: `tests/test-mutations.sh` (the coverage loop, currently near line 88)

**Interfaces:**
- Consumes: the 14 patches from Tasks 1-2.
- Produces: the assertion that a future network case without a demonstration fails at review time.

This is the ratchet. It must land **with** Tasks 1-2, never before — turned on early it fails 14 cases at once.

- [ ] **Step 1: Extend the tag filter**

```bash
  case " $tags " in
    *" mounts "*|*" groups "*|*" volumes "*|*" packages "*|*" network-mode "*) : ;;
    *) continue ;;
  esac
```

- [ ] **Step 2: Update the section comment to say what it now covers**

The current comment says "Every launcher-tier case has a mutation." That is no longer true and a stale comment here is exactly the kind of thing that misleads the next reader into re-narrowing the filter. State that it covers the launcher **and** network/security tiers, and why the network tier was added late.

- [ ] **Step 3: Run it**

```bash
bash tests/run-all.sh test-mutations
```
Expected: PASS, with 14 additional `has a known-bad mutation` assertions.

- [ ] **Step 4: DEMONSTRATE the ratchet failing**

The guard must be seen rejecting a case with no demonstration:

```bash
cp tests/integration/cases/010-restricted-blocks-unlisted.sh \
   tests/integration/cases/015-demo-no-mutation.sh          # carries network-mode tag, has no patch
bash tests/run-all.sh test-mutations
```
Expected: **FAIL**, and the failing line must be exactly
`FAIL: 015-demo-no-mutation has a known-bad mutation — add one under tests/integration/mutations/`.
Confirm that specific line appears, then `rm tests/integration/cases/015-demo-no-mutation.sh` and re-run to confirm green.

Also demonstrate the *other* direction, which is the one a careless edit breaks: revert the filter change, re-run, and confirm the 14 assertions **disappear** (count drops) rather than fail — a silent narrowing is the failure mode this whole task exists to close.

- [ ] **Step 5: Update `AGENTS.md`**

The current text says the network cases "keep their fixture-based demonstrations under `tests/integration/fixtures/`" and that they are "deliberately not converted". Both are now wrong. Rewrite that bullet to state: the two fixtures remain (they preserve code that no longer exists, so no patch could apply to them), *and* every network case now carries a patch like the launcher tier.

- [ ] **Step 6: Commit**

```bash
git add tests/test-mutations.sh AGENTS.md
git commit -m "test(mutations): the coverage ratchet now protects the security tier too

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

# Part B — the `falsify` harness

### Task 4: The generator

**Files:**
- Create: `tests/falsify/generate.sh`
- Create: `tests/test-falsify-generate.sh`

**Interfaces:**
- Produces: `falsify_generate <file>` → one line per mutant on stdout: `<operator>\t<line-no>\t<sha1>\t<mutated-line>`. Consumed by Task 5's runner and Task 8's self-test.

Operators (default set — **four**, `stream-flip` present but gated off):

| Operator | Transformation |
|---|---|
| `cond-negate` | `[[ x ]]` → `[[ ! x ]]`; `if cmd;` → `if ! cmd;` |
| `logic-flip` | `&&` ↔ `\|\|` |
| `return-flip` | `return 0` ↔ `return 1`, `exit 0` ↔ `exit 1` |
| `cmp-flip` | `-eq`↔`-ne`, `-lt`↔`-ge`, `-gt`↔`-le`, `==`↔`!=`, `<`↔`>` |
| `stream-flip` | `>&2` → `>&1` — **off unless `FALSIFY_OPERATORS` names it** |

- [ ] **Step 1: Write the failing test first**

```bash
# tests/test-falsify-generate.sh
cat > "$TMP/t.sh" <<'EOF'
f() { [[ -n "$1" ]] && return 0 || return 1; }
EOF
out="$(bash "$GEN" "$TMP/t.sh")"
grep -q '^cond-negate' <<<"$out" && pass "cond-negate emitted" || fail "cond-negate emitted"
grep -q '^stream-flip' <<<"$out" && fail "stream-flip is off by default" || pass "stream-flip is off by default"
```

- [ ] **Step 2: Run it, confirm it fails** — `bash tests/run-all.sh test-falsify-generate` → FAIL, "no such file".

- [ ] **Step 3: Implement `generate.sh`**

One mutant per applicable **token occurrence**, not per line. `<`↔`>` only inside `[[ ]]`/`(( ))` spans, or redirections get mangled. Skip: heredoc bodies, full-line comments, the shebang, and quote-aware trailing comments.

- [ ] **Step 4: Every emitted mutant must pass `bash -n`**

Discard those that do not, and count discards separately — a syntax error proves nothing about any assertion. On the 19 candidate files this should discard **0**; a non-zero count means the generator produces malformed output and is a bug, not a tolerance.

- [ ] **Step 5: DEMONSTRATE the `bash -n` gate works**

Feed three deliberately malformed candidates through the same `check_syntax()` path and assert 3/3 are discarded and 5/5 well-formed ones are accepted. Without this the gate is untested and could be a no-op that discards nothing.

- [ ] **Step 6: Pin the measured counts as a regression fence**

Assert the generator yields exactly the measured totals for three stable targets — `tools-lib.sh` 17, `bash-floor.sh` 12, `shared-files.sh` 5. If a target's real content changes these move legitimately; the point is that a silent generator regression (an operator quietly matching nothing) fails here instead of showing up as "everything is killed".

- [ ] **Step 7: Commit**

---

### Task 5: The runner, oracle and isolation

**Files:**
- Create: `tests/falsify/run.sh`
- Create: `tests/test-falsify-run.sh`

**Interfaces:**
- Consumes: `generate.sh`; `tests/run-all.sh <name>` as the oracle.
- Produces: `run.sh [--target <file>] [--jobs N]` → per-mutant `KILLED`/`SURVIVED` verdicts.

- [ ] **Step 1: Scratch-tree isolation**

Each worker gets its own tree (tracked files plus `.git`, ~17 MB). Per mutant: write the damaged file, run the oracle, restore from a pristine cache. **The working tree is never touched.**

- [ ] **Step 2: Assert the isolation, do not assume it**

The test records `git -C "$REPO_DIR" rev-parse HEAD` and `git status --porcelain` before and after a full run and asserts both are byte-identical. This is the single most damaging thing this harness could get wrong.

- [ ] **Step 3: The oracle contract**

Invoke `tests/run-all.sh <name>`, never the test file directly — the killed/survived verdict is then literally the suite's own code path. KILLED = non-zero exit **or** a `FAIL:` line. Both were true for every kill in the pilot.

- [ ] **Step 4: Assert the two relied-upon oracle properties**

- `run-all.sh` with a filter matching nothing exits **2**. Assert it. A misspelled oracle name in `targets.conf` must fail loudly, not report every mutant killed.
- A dirty tree does not by itself change the verdict: append a no-op comment, run the oracle, assert it still passes. Without this every "killed" is suspect, because `mutate.sh`'s `cmd_apply` has a `git diff --quiet` gate.

- [ ] **Step 5: Timeout and parallelism**

A mutant exceeding the per-mutant timeout counts as KILLED and is flagged. Worker pool via `wait -n` (bash 5.1). Per-mutant timing via `EPOCHREALTIME`, not a forked `date` — it runs thousands of times.

- [ ] **Step 6: DEMONSTRATE both verdicts**

Against a fixture with one known-killable and one known-surviving mutant, assert `KILLED` and `SURVIVED` respectively. Then break the verdict logic (make `FAIL:` detection always false) and confirm the known-killable mutant flips to `SURVIVED` — proving the assertion reads the verdict and not a constant.

- [ ] **Step 7: Commit**

---

### Task 6: `targets.conf` — derived, then checked

**Files:**
- Create: `tests/falsify/targets.conf`
- Create: `tests/falsify/derive-targets.sh`
- Create: `tests/test-falsify-targets.sh`

**Interfaces:**
- Produces: `<target>|<category>|<oracle-test>[|<functions>]` rows. `run.sh` reads them.

Categories are the spec's three: `EXECUTED-WHOLE`, `EXECUTED-PARTIAL` (mutation unit is the named **functions**), `GREPPED-ONLY` (never mutated).

**Stage 1 target list** — entry rule is *a dedicated 1:1 oracle test*, a mechanical criterion, not a judgement call:

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

- [ ] **Step 1: Derive the candidate list mechanically**

Resolve what the hermetic tests source and run, **including through path variables** (`LIB=`, `RUNNER=`, `VERIFY=`, `DH_LIB=`, `src=`). A `bash -n` or `shellcheck` invocation is **not** execution. A stub fake inside `lib-verify-repo.sh`'s scratch repo is **not** the real script.

- [ ] **Step 2: The gate — an executed file missing from the map fails**

Excluding one requires an explicit `EXCLUDED: <reason>`. Record `sandbox.sh` as `EXECUTED-PARTIAL` now, deferred to a later stage, with its five reachable functions listed: `mem_to_bytes`, `validate_memory_limits`, `parse_pointer_spec`, `pointer_repo_entry`, `split_env_list`.

- [ ] **Step 3: DEMONSTRATE the gate failing**

Delete a row for a genuinely-executed target; the gate must name that file. Then add a row for a `GREPPED-ONLY` file and confirm it is rejected — both directions, since a gate that only catches omissions lets a wrong classification through.

- [ ] **Step 4: DEMONSTRATE the misspelled-oracle case**

Point a row at a nonexistent oracle test. Expected: loud failure via `run-all.sh`'s exit 2, **not** a clean run reporting every mutant killed.

- [ ] **Step 5: Commit**

---

### Task 7: The survivor ledger and its four hard failures

**Files:**
- Create: `tests/falsify/survivors.txt`
- Create: `tests/falsify/check-ledger.sh`
- Create: `tests/test-falsify-ledger.sh`

**Interfaces:**
- Consumes: `run.sh`'s survivor list; `survivors.txt`.
- Produces: the gate's exit status.

Identity is `<file>:<operator>:<sha1 of trimmed original line>` — **never** `file:line`, which every edit would invalidate wholesale.

Four hard failures:

| Condition | Why |
|---|---|
| survivor with no classification | the ratchet — a new hole cannot land silently |
| survivor absent from the ledger | same |
| entry whose mutant no longer exists | stale, like a stale patch |
| entry whose mutant is now **killed** | obsolete amnesty; delete it |

- [ ] **Step 1: Format**

```
repo.sh:stream-flip:9f3c21a
  repo_die() { printf 'repo.sh: %s\n' "$1" >&2; exit 1; }
  EQUIVALENT: no hermetic test reads repo_die's stream; the message is
  asserted by content, and stderr-vs-stdout on a fatal path is observable
  only through the launcher tier.
```
`EQUIVALENT` must state *why no test could ever kill this mutant*, not merely that none does — the second is a `GAP`. Group classification is permitted: N survivors from one underlying cause cost one entry.

- [ ] **Step 2: Implement the four checks.**

- [ ] **Step 3: DEMONSTRATE each of the four failing, separately**

One at a time, each naming the specific output line asserted:
1. Add a survivor to the run, omit it from the ledger → must fail naming that mutant id.
2. Add an entry with an empty classification → must fail. A `GAP:`/`EQUIVALENT:` marker with nothing after the colon suppresses nothing (the same trap `# dialect-lint: allow` already guards).
3. Add an entry whose sha1 matches no current mutant → must fail as stale.
4. Add an entry for a mutant that is now killed → must fail as obsolete.

Four separate demonstrations. A single test that trips all four cannot distinguish which check fired, and three of them could be dead code.

- [ ] **Step 4: Commit**

---

### Task 8: The harness self-test

**Files:**
- Create: `tests/test-falsify-harness.sh`
- Create: `tests/falsify/fixtures/` (one known-killable, one known-surviving mutant)

- [ ] **Step 1: Fixture tree** — a minimal target plus its oracle, one mutant of each kind.
- [ ] **Step 2: Assert both verdicts** against the fixture.
- [ ] **Step 3: Demonstrate by breaking the mechanism, never by asserting the expected answer.** For each of the four gate failures, break the mechanism and require the old permissive behaviour to come back — the pattern `tests/test-verify-exit-code.sh` already uses.
- [ ] **Step 4: Register in `tests/layer-checks.conf`** if it becomes a CI job; otherwise confirm `run-all.sh` picks it up by name.
- [ ] **Step 5: Commit**

---

### Task 9: Validation against the four historical holes

**Files:**
- Create: `tests/test-falsify-historical.sh`

This is the task that decides whether the tool ships. A mutation harness that cannot catch the bugs that motivated it is decoration.

| Hole | Fixed in | Defective test | Mutation target |
|---|---|---|---|
| #2 tallied into a counter its `exit` never read | `44676f5` | `tests/test-integration-lib.sh` | `tests/integration/lib.sh` |
| #3 `launcher_prepare` — variable reset by a later `source` | `421d25d` | `tests/test-integration-lib.sh` | `tests/integration/lib.sh` |
| #4 conjunct satisfied by an unrelated line | `9b64bd3` | `tests/test-integration-lib.sh` | `tests/integration/lib.sh` |
| #6 stdout assertion whose helper folded stderr in | `7d1970f` | `tests/test-mutations.sh` | `tests/integration/mutate.sh` |

- [ ] **Step 1: Restore each pre-fix test** with `git show <sha>^:<file>` into a scratch tree.
- [ ] **Step 2: Run the corresponding mutant. The harness must report `SURVIVED`.**
- [ ] **Step 3: Confirm the fixed version reports `KILLED`** — otherwise the assertion is measuring the harness's inability to kill anything, not the hole.
- [ ] **Step 4: Hole #6 runs with `stream-flip` explicitly enabled**, since the default set drops it. This demonstrates both that the harness catches it and exactly what dropping the operator costs. Do **not** let #6 quietly pass because its operator is absent — that is the "verified nothing" failure this suite keeps finding.
- [ ] **Step 5: Commit**

---

### Task 10: First real run, classification, and the `GAP` fixed before merge

**Files:**
- Modify: `tests/falsify/survivors.txt`
- Modify: whichever test earns the first killing assertion
- Create: `docs/superpowers/specs/2026-08-14-falsify-backlog.md`

Projected ~57 survivors from 238 mutants across the nine stage-1 targets.

- [ ] **Step 1: Run the full stage-1 set.** Record actual mutants, killed, survived, wall clock. If survivors materially exceed ~80, stop and report before classifying — that is R1's trigger again, and the response is re-scoping, not grinding.
- [ ] **Step 2: Classify every survivor** as `GAP` or `EQUIVALENT`, grouping shared causes.
- [ ] **Step 3: Fix `mutate.sh:144` — the known real hole.**

Independently verified: `( cd "$GIT_ROOT" && git diff --quiet )` mutated to `||` disables the clean-tree gate entirely (`cd` succeeds, `||` short-circuits, the negation is false) and the suite stays green. Write the killing assertion in `tests/test-mutations.sh`, confirm the mutant flips to `KILLED`, and confirm the assertion fails against the mutated file — both directions.

- [ ] **Step 4: Record every remaining `GAP` in the committed backlog file**, one per line with its mutant id. Per this project's rule: one fixed before merge, the rest in a follow-up merge, **none dropped**. The SDD workspace is deleted on completion; the backlog is not.
- [ ] **Step 5: Commit**

---

### Task 11: Wire into the layers

**Files:**
- Modify: `.github/workflows/hermetic-checks.yml`
- Modify: `tests/layer-checks.conf`
- Modify: `verify-on-host.sh` (Phase 6)
- Modify: `tests/lib-verify-repo.sh`, `tests/test-layer-containment.sh` as the registry requires
- Modify: `AGENTS.md`

- [ ] **Step 1: Add the PR-layer job** to `hermetic-checks.yml`, so both `tests.yml` and `nightly.yml` inherit it from the one definition.
- [ ] **Step 2: Add its row to `tests/layer-checks.conf`** — the single registry. Adding a job without a row is the exact defect the registry was built to catch; confirm the containment test fails if the row is omitted.
- [ ] **Step 3: Define Phase 6 in `verify-on-host.sh`.**

`AGENTS.md` reserves Phase 6 for this increment and requires it stay absent from `VALID_PHASES` until the increment defines it. Add `6` to `VALID_PHASES`, run the full matrix locally, and record through `phase_fail` — a phase that records nothing recreates the always-zero hole.

- [ ] **Step 4: Decide and state whether Phase 6 joins the `PHASES` default.**

Default is `"4 5 7"`. `tests/test-verify-exit-code.sh` pins it explicitly, so this is a deliberate choice with a test to update either way. Recommendation: **include it** — "a local layer nobody selects by default is not a local layer" is the stated reasoning for the existing default.

- [ ] **Step 5: Confirm `local ⊇ nightly ⊇ PR` still holds** — `tests/test-layer-containment.sh`, and demonstrate it failing by adding the job to `tests.yml` only.
- [ ] **Step 6: Update `AGENTS.md`** — the phase table, the `falsify` tier, the boundary rule's three categories, and the `tests/falsify/` vs `tests/integration/mutations/` distinction the spec warns will otherwise be "unified" by a future reader.
- [ ] **Step 7: Commit**

---

### Task 12: Port to `mgd-ai-containers`

**Port hazard found in advance, 2026-08-16 — do not rediscover it.**
`tests/falsify/targets.conf` names its targets by repo-relative path, and three
ACTIVE ones sit at the engine root here but under `base/` in mgd:
`tools-lib.sh`, `bash-floor.sh`, `shared-files.sh` (plus several DEFERRED rows:
`entrypoint.sh`, `capture-agent-destinations.sh`, `refresh-ipset-allowlist.sh`).
Nothing resolves this automatically — `run.sh` makes only the *driver* path
(`FR_DRIVER_REL`) layout-tolerant, deliberately and with a comment saying so;
target paths are not covered.

That is legitimate: `targets.conf` is per-repo configuration — it lists that
repo's targets, its oracles, and its own DEFERRED reasons — so mgd's copy is
*expected* to differ, exactly as `sandbox.conf` does. Prefix the moved rows with
`base/` rather than teaching the runner a second layout rule.

Two consequences to verify there, not assume: `derive-targets.sh`'s gate must
still classify correctly under `base/`, and the mgd corpus will have DIFFERENT
survivor counts, so its `survivors.txt` is its own artifact and must be
generated from an mgd run — never copied from here.

- [x] **Step 1: Derive the file list from `git diff --name-only main...HEAD`** — never hand-written.
- [x] **Step 2: Apply to the sibling repo's `base/` layout.** `ENGINE_DIR` resolves differently there; anything path-sensitive needs checking, not assuming.
- [x] **Step 3: Run the full hermetic suite and the falsify tier there.** Numbers will differ — that is expected, and the ledger is per-repo.
- [x] **Step 4: Open the parallel PR.**

**COMPLETE, 2026-08-17 — mgd-ai-containers PR #20.** 38 files (the 41-path range
minus this repo's three `docs/superpowers/` artifacts, which mgd does not carry).
Four adaptations, each forced rather than chosen: the `base/` prefix on
`targets.conf`'s engine rows; a layout *probe* rather than a typed path for
`test-falsify-ledger.sh`'s survivor pin; this repo's own commit id for
`test-falsify-historical.sh`'s hole #6, whose control restores a pre-fix file
whole from git and would otherwise restore nothing; and `lib-paths.sh` for
`test-mode-capabilities.sh`'s `REPO_DIR`.

mgd's corpus is **253 mutants / 215 killed / 34 survived / 4 unproven** against
this repo's 249/209/36/4 — its `survivors.txt` was measured there, not copied,
and every surviving damage was re-run against mgd's whole 53-test suite (twice:
six-at-a-time, then one at a time, because the parallel pass produces false
kills).

**That port found a bug in a file both repos share**, which is why the two-way
verification exists: `test-tools-d.sh`'s "leaves no temp file" assertion globbed
the shared `/tmp`, so any concurrent copy of the suite failed it — and
`tests/falsify/run.sh` runs up to `nproc` oracles at once with that test as
`tools-lib.sh`'s declared oracle, so the tier could have scored a mutant KILLED
on another worker's temp file. Fixed in both repos (this one: PR #24).

---

## Self-review notes

- **Spec coverage:** boundary rule → Task 6; oracle → Task 5; operators → Task 4; staging → Task 6; identity → Task 7; isolation → Task 5; ledger → Task 7; verification → Tasks 8-9; network tier → Tasks 1-3; bash floor → Global Constraints; port → Task 12.
- **R1's re-scope trigger is live, not historical.** Task 10 Step 1 re-arms it: if stage 1's survivors materially exceed the projection, the response is re-scoping, not grinding through classification.
- **The two halves are independent.** Tasks 1-3 deliver security-tier coverage with no new machinery and can merge alone if Part B stalls.
