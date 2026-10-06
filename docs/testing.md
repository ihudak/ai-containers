# Testing and CI

The **rules** an agent must follow live in [AGENTS.md](../AGENTS.md) — this page
is the evidence behind them: what was measured, what was tried and refuted, and
why each guard is shaped the way it is. AGENTS.md links here from each rule it
keeps.

Read this before changing anything under `tests/`. A rule in AGENTS.md whose
reasoning you cannot find here has lost its evidence, which is itself worth
fixing.


## The integration corpus

**Image variants.** Most cases run against one default image, but the `packages` tier does not: it exists to prove that what `sandbox.conf` asks for is actually *there and working* at runtime, which needs images built with those components on. `tests/integration/run.sh` therefore knows four variants — `default`, `agents` (the six agent-tier keys `ON`, plus `node=22,20`, with `KEEP_BUILD_TOOLCHAIN` left unset) and `native` (`db-clients=pg,mysql,mongo`, `imagemagick=ON`, `wkhtmltopdf=ON`, `playwright=ON`, `postgres=ON`, `ruby=$IT_RUBY_VERSIONS`, so the toolchain is kept) and `services` (`redis=ON`: the in-container servers that need no toolchain). The agents/native split is not arbitrary: it is the distinction the **Dockerfile itself** makes, between an image that strips `build-essential` and one that keeps it. `services` is split off for cost: its servers need neither Ruby nor Playwright, and `native`'s nightly job is already at its budget. A case selects its variant with an `# image:` header comment (absent means `default`), the runner builds each selected variant once, runs that variant's cases, then `docker rmi`s it before moving to the next (the `default` variant's image is left to the run's own `sweep()` at exit, which already owns it and honours `--keep`) — so peak disk stays at one image, not four. `--variant NAME` narrows a run to one of them.

`IT_RUBY_VERSIONS` (default `3.3.6,3.4.5`) is the cost lever for the `native` variant: both versions are compiled from source at container start, which is most of that tier's wall-clock. Setting it to a single version cuts the tier roughly in half but withdraws the `multiruby` capability (`probe_multiruby` requires a comma), so every `needs-multiruby` case SKIPs — and with `--require packages`, skipping fails the run rather than passing quietly. `nightly.yml`'s `packages-native` job documents that trade-off, and the disk/wall-clock figures to decide on, at the point where the switch would be thrown.

The suite asserts **effect, not configuration**: it observes from outside the container whether the packet arrived, the file exists, the log line is present. `tests/test-entrypoint-wiring.sh` asserts the capture daemon is *wired into* `entrypoint.sh` and passed every day of a months-long outage, because the wiring was correct and the daemon died after being started.

**Two tiers, two verbs.** Network cases call `sandbox_up`, which composes its own `docker run` — that isolates the image and the entrypoint from the launcher. Mounts, groups and volumes cases call `launcher_up`, which drives **the real `sandbox.sh`**, because every mount decision lives there and reproducing it in the harness would test the reproduction. `launcher_up` works through `tests/integration/docker-shim.sh`, a pass-through `docker` on `PATH` that rewrites the launcher's `-it` to `-d -i` and replaces the launcher's own `--name` with its own (Docker takes the last of two, so it strips rather than out-orders) and adds a `--label`, so a case can exec into the container and the runner can sweep it. sandbox.sh: `docker run -it --rm` is the only `docker run -it` a launcher run can reach, which is what makes that identification sound; `tests/test-integration-shim.sh` pins that premise by content, so a second one fails at its cause. These cases carry `requires: launcher`, a probed capability — a machine that cannot drive the shim SKIPs them by name rather than failing them as if mounts were broken. A launcher case never inherits the developer's `sandbox.conf` (`tests/integration/minimal-conf.sh`, shared with `tests/integration/run.sh`'s image build): a `ruby=` there would bootstrap rvm before the agent shell appeared. Launcher-driven cases only started passing on macOS + Colima in `b6191da`: `launcher_run`/`launcher_script` redirect `HOME` to a per-case scratch dir to isolate group state, which also threw away `$HOME/.docker/config.json`'s `currentContext` — invisible on a host where the daemon sits at the CLI's built-in default socket (Linux CI), fatal on macOS + Colima, which supplies its endpoint only through the active context. Before that fix, all 17 launcher-driven cases failed identically there.

## Known-bad demonstrations

- Two known-bad daemons are kept in `tests/integration/fixtures/`, each preserving a *different* real bug that shipped, so the increment-1 cases that catch them can be demonstrated failing. Do not "consolidate" or repair them.
- Increment 2's known-bad configurations live in **production** files, so they are kept as patches under `tests/integration/mutations/` and driven by `tests/integration/mutate.sh` (`list` / `apply <id>` / `revert` / `verify`). Patches rather than `sed`, deliberately: a patch that no longer applies is a loud failure, whereas a stale `sed` matches nothing and reports success. `tests/test-mutations.sh` enforces both directions — every patch still applies, **and** every case in a covered tier (`mounts`/`groups`/`volumes`/`packages`/`network-mode`/`delivery`) has one, so a new case with no mutation fails at review time. A case in no tier must be named in that file's `case_exempt()` with a reason; an unexplained omission fails too. `tests/integration/demonstrate-network-delivery-tiers.sh` is the host-side companion that proves each `network-mode`/`delivery` mutation still makes its case FAIL — applying is not the same as damaging. A patch that changes an **image build input** (the `Dockerfile`, or anything it `COPY`s — derived from the Dockerfile, not listed) is run there with a real rebuild instead of `--reuse-image`, and the clean image is rebuilt afterwards: a Dockerfile mutation is invisible to an image built before it, so `--reuse-image` would report the case passing and call the mutation dead when it was never applied to anything. `tests/integration/demonstrate-needs-rebuild.sh` is the counterpart for every OTHER patch that needs a rebuild — nine today, across `mounts`, `volumes` and `packages` — because the hand-driven `--reuse-image` procedure above is silently wrong for exactly those: the image predates the mutation, the case passes, and the mutation is reported dead having never been applied to anything.

```bash
tests/integration/mutate.sh apply 400-ro-suffix-dropped
tests/integration/run.sh --reuse-image --tags mounts     # expect 400 to FAIL
tests/integration/mutate.sh revert
```

## The falsify tier and its ledger

| | `tests/integration/mutations/` | `tests/falsify/` |
|---|---|---|
| What is damaged | a case file or the launcher, by a **hand-written patch** | any line of a target, by a **generated** mutant |
| The tree | the **real** working tree, deliberately, for a human demonstration | a **scratch** tree per worker; the working tree is never touched |
| What is checked | that the patch still **applies** | that the oracle **notices** — killed, survived or unproven |
| Which oracle | n/a | the target's row names it; the field is a **set**, comma-separated, run as one invocation, and every member must be a test the derivation observes EXECUTING that target |
| Cadence | hand-driven | every CI run, ~10 min over the whole corpus (`--jobs $(nproc)`, `--timeout 120`) |

A mutant nothing noticed is a **survivor**, and every survivor is owed an entry in `tests/falsify/survivors.txt` classified `GAP:` (no test kills it today), `EQUIVALENT:` (no test *could*), or `ENV-DEPENDENT:` (the verdict moves with the machine, and neither reading is wrong). Those are different claims and conflating them is how the ledger stops protecting anything. `UNPROVEN` means nothing was observed asserting either. It has three channels, named apart because each sends a reader somewhere different: the oracle **timed out**, it printed `SCAFFOLD-FAILED:` (it could not set *itself* up), or it was **killed by a signal** (`wait` returned 128+N — the OOM killer's signature on a memory-capped host). All three used to read as `KILLED`, which removes a survivor the ledger was owed and grows the coverage claim without growing the coverage. An entry for one is **accepted but not required**: the timeout that produced it is a property of the machine, and a ratchet that cannot be satisfied everywhere at once is not a ratchet. The price of that exemption is that unproven mutants leave the measured set in silence, so the reference environment bounds the fraction with `--max-unproven-pct` instead — measured on one commit on one day, 223 killed / 4 unproven on one machine against 210 / 26 on another, both scoring green.

**Measuring the tier is a batched, Linux-side job. The per-slice evidence is the DEMONSTRATION, not the score.** Measured 2026-08-30 over the same corpus: CI's falsify job scores 548 mutants in 11m06s (~1.2s per mutant); a macOS host scores 289 mutants of ONE deferred target in ~100 minutes (~21s per mutant) — **~17x slower per mutant**, and it cannot be bought back with workers, because the fork ceiling returns 1.21x at `--jobs 6` and converts KILLED into UNPROVEN (recorded beside `fr_fork_cost_cap`). So:

Two hours of measurement per small change is the shape this rule exists to prevent. It was reached honestly, twice in one day, before anyone wrote it down.

## The local layer: verify-on-host.sh

`bash ./verify-on-host.sh` delegates the runtime integration corpus to Phase 4 — one of five phases the script runs (0, 5, 7, 6, 4; see [Execution layers](../AGENTS.md#execution-layers) below for the full table). What used to be Phases 1-3 (agent-tier tool install, native package builds, the rvm/Ruby reconcile) now has full case coverage of its own, in the corpus's `packages` tier (`tests/integration/cases/`, tag `packages`), so Phase 4 no longer duplicates it. It is a platform-adaptive **host** entry point: the identical command on macOS + Colima and on Linux. It **exits non-zero if any selected phase failed**, printing a `RESULT:` verdict that names each one; a failed phase does not stop the others, because the phases are independent and a full report beats an early abort. That is load-bearing, not cosmetic — `nightly.yml`'s `packages-agents` and `packages-native` jobs each invoke `tests/integration/run.sh --tags packages --variant <name> --require packages` directly, not this script — and this script's own `PHASES` selection is validated against the phases it actually has: a stale `PHASES="1 2 3"` (naming phases Increment 3 removed) is a recorded failure, not a silent no-op that exits 0 having verified nothing, which is the exact defect this ledger existed to prevent, now reachable through selection instead of reporting. A new phase that records nothing through `phase_fail`, or a `PHASES` value naming a phase that doesn't exist, recreates the hole; `tests/test-verify-exit-code.sh` is the guard for both, and it demonstrates itself failing by stripping the verdict block out and requiring the old always-zero behaviour to come back.

CI runs the `fast` tier on every PR (`.github/workflows/integration.yml`) and the **whole** corpus nightly (`.github/workflows/nightly.yml`), including the `slow` and `needs-dns` cases the gate excludes on cost — so a case excluded on cost is still a case that runs. `nightly.yml` also checks that every domain in `allowlist-domains.d/` still resolves; fragments rot silently, and the only symptom is a tool that mysteriously cannot install behind the firewall.

## The phase table

`verify-on-host.sh` runs numbered, independent phases (a later phase still runs if an earlier one failed — a full report beats an early abort):

| Phase | Content | Mirrors |
|---|---|---|
| 0 | environment banner (daemon reachable, buildx, disk; Colima status on macOS) | — |
| **5** | the hermetic suite (`tests/run-all.sh`) + the `sandbox.conf` schema gate, then the same suite again inside a container pinned to the declared bash floor, then a third time with `TMPDIR` pointed at a symlink | `hermetic-checks.yml` jobs `suite` + `suite-floor` + `suite-symlinked-tmp` |
| **7** | `bash -n` over every tracked script, the bash-dialect floor linter, and `shellcheck` as a gate | `hermetic-checks.yml` job `lint` |
| **6** | the `falsify` mutation tier: the whole corpus, then the survivor-ledger ratchet | `hermetic-checks.yml` job `falsify` |
| 4 | the runtime integration corpus, delegated whole to `tests/integration/run.sh` | `integration.yml` / `nightly.yml` |

**Phase numbers are identifiers, not execution order** — the script actually runs them **0, 5, 7, 6, 4**: cheap checks first, so a broken hermetic suite or a lint error is reported in seconds rather than after eleven minutes of mutation scoring or an hour of image builds. The table below is in that execution order. Phase 6 ran *before* Phase 7 until 2026-09-02, which inverted exactly the property this ordering exists for — a 13-second lint sat behind an 11-minute corpus — and the phases are independent, so the swap changes nothing but the order a failure is reported in.

## How the layers are kept contained

**That guard checks by *effect*, not by grepping for a filename, and the reason is load-bearing.** An earlier version asked "does `verify-on-host.sh`'s source text contain the string `tests/run-all.sh`?" — and a reviewer defeated it by commenting out the real invocation while leaving a comment that still named it: the check still passed, having verified nothing. Five of its six original rows had the same shape, because the filename each one searched for also appears in an existence guard, a `phase_fail` message, and the phase-table comment, all of which are non-comment text that satisfies a substring match with nothing actually running. The fix (`tests/lib-verify-repo.sh`) builds a stub repo with instrumented fakes — each records `STUB:<name>` to a witness log only when it is genuinely invoked — runs the real, current `verify-on-host.sh` against that stub repo, and asserts the witness line, not the source text. `bash -n` has no external command to stub, so its row instead plants a tracked file with a real syntax error and asserts the specific `PARSE ERROR: <path>` line that only appears if `bash -n` truly ran against it. Do not "simplify" this back to a text search — a comment mentioning a check's name is exactly the kind of edit that looks harmless and would silently re-break the guard. The effect fix held for the rows that existed, but nothing forced a row to **exist**: three lists had to agree — `tests/lib-verify-repo.sh`'s stubs, the `CHECKS` table, and a per-job step-count baseline — and adding a fourth CI job produced zero failures, because the job list was hardcoded as three names. All three are now one registry, `tests/layer-checks.conf`, read by both consumers. The job list is **derived from `hermetic-checks.yml`**, and every step must classify as either a registry check (which forces a stub and a witness proving it also runs locally) or a `setup` row stating why it is not one. That subsumes the step count rather than dropping it: if every step classifies and every row finds its step, the counts agree by construction. The floor→image map lives in `bash-floor.sh` beside the floor it tests, so a floor raised without a matching image yields empty and fails loudly instead of testing the wrong bash.

## The bash floor: what it excludes, and how it is exercised

5.1 excludes exactly two realistic platforms: **Ubuntu 20.04** (bash 5.0.17, ESM-only since April 2025) and **RHEL/Rocky 8** (bash 4.4.20, supported to 2029, a host-script concern only — the container itself is `ubuntu:24.04`, bash 5.2.21, which clears the floor regardless of the host running it). Raising the floor further, to 5.2 to match what CI's `ubuntu-latest` and the container both happen to ship, was considered and rejected: it would additionally drop **RHEL/Rocky 9** (bash 5.1.8, supported to 2032), **Ubuntu 22.04 LTS** (5.1.16), and **Debian 11** (5.1.4) — a far larger exclusion for a floor that would keep drifting upward with the runner image anyway, deciding nothing.

**The symlinked-`TMPDIR` run is a stand-in for a Mac, and it is guarded like one.** CI is ubuntu-only, where the temp directory is not a symlink; macOS's is, so `mktemp -d` returns `/var/folders/…` while anything canonicalising reports `/private/var/folders/…`. A test comparing one against the other passes in `suite` **and** in `suite-floor` and fails on every Mac — a shape that has cost this repo twice, 19 assertions in increment 4 and three more on 2026-08-24 (`tests/test-report.sh`, `tests/test-docs-path.sh`, and the docs orphan gate). `suite-symlinked-tmp` runs the same suite with `TMPDIR` pointed at a symlink, and `verify-on-host.sh` Phase 5 mirrors it so the containment invariant holds. Two things keep it from becoming a green gate that gates nothing: the CI step asserts its own arm is a symlink and resolves elsewhere before running anything, and `tests/test-symlinked-tmp-guard.sh` demonstrates that a path-naive comparison **fails** under the symlinked arm and **passes** under an ordinary one — so pointing `TMPDIR` at a plain directory by mistake is caught rather than silently reducing this to a second ordinary run. Phase 5's copy is gated on the ordinary run having passed, because the two exercise one suite in two environments and a suite that is already broken would otherwise report the same problem twice into a verdict that counts failures rather than distinct phases. It does **not** replace a real Mac: it catches the path-resolution class only, and the GNU-vs-BSD class is invisible to it — `realpath -m --relative-to` was found by a host run, not by this.

## `run.sh --dry-run` vs `--list`

`tests/integration/run.sh --dry-run` applies the current `--tags`/`--exclude`/`--cases`/`--variant` selection and prints the case basenames that selection would run, one per line, then exits — no image build, no container, no docker call of any kind. An empty selection is fatal here exactly as in a real run, not a silently empty list. **`--list` is deliberately unchanged**: it catalogues the *whole* corpus regardless of any selection flag, a documented contract stated outright in its own `usage()` text, and redefining what an existing flag means while keeping its name is the failure mode this project refuses everywhere (see the `sandbox.conf` schema-versioning rule above — a key's meaning never silently changes underneath a value already relying on it). `--dry-run` is what makes the containment invariant checkable as a set comparison in the first place: `tests/test-layer-containment.sh` asks `run.sh --dry-run` what the PR layer's flags would select and what the nightly layer's flags would select, rather than reimplementing that selection logic a second time and being right in this repo while silently drifting wrong in the mgd port.

## Portability helpers (`tests/portability.sh`)

GNU coreutils and BSD/macOS userland disagree on several flags the hermetic suite depends on, and `tests/portability.sh` is the one place that difference is resolved: `p_stat_mode`/`p_stat_meta` (`stat -c` vs `stat -f`), `p_sha1`/`p_md5` (`sha1sum`/`md5sum` vs `shasum -a 1`/`md5 -q`), and `p_realdir` (symlink-free absolute path via `cd` + `pwd -P`, deliberately *not* `readlink -f` — a test that canonicalises its expected value with the same primitive as the code it is checking is `assert f(x) == f(x)`, not a test). New tests that shell out to coreutils for one of these facts use these helpers rather than open-coding a fallback per call site.

They exist because Increment 4's local layer ran the hermetic suite on BSD userland for the first time ever — CI is ubuntu-only — and it found two classes of failure a static scan for GNU-only *commands* could never catch, because both are *path-shape* facts: **macOS canonicalises `/var/folders/…` to `/private/var/folders/…`** (`/var` is itself a symlink to `/private/var`), which broke 19 assertions across `tests/test-parsers.sh`, `tests/test-mutations.sh`, and `tests/test-tool-config-mounts.sh` — every one of them compared a resolved path against an unresolved expectation, not a product defect; and **`/bin/true` does not exist on macOS** (it ships at `/usr/bin/true`), which broke all 8 `tests/test-integration-lib.sh` assertions that hardcoded it as a stand-in executable. Both classes were fixed at the *test's* assumption, never the product: `p_realdir` supplies an independently-derived canonical path instead of comparing against the raw `mktemp -d` output, and the stand-in executable is now fabricated in the test's own scratch dir instead of assumed to exist at a fixed path.

## shellcheck: the pinned runner, and what the two layers differ on

**The version of that gate comes from the runner image, which is therefore pinned.** Every job says `runs-on: ubuntu-24.04`, never `ubuntu-latest` — a label GitHub re-points at a new Ubuntu LTS on their schedule, not this repo's. The distro is what holds the toolchain still (24.04 freezes shellcheck at 0.9.0 and bash at 5.2 for the life of the release), so an unpinned runner is an unpinned toolchain underneath a blocking merge gate: what passes could change with nobody having edited this repo. That is not hypothetical here — `cd ""` is a silent no-op on bash 5.1 and 5.2 and an **error** on 5.3 (measured; `survivors.txt` entry 7 records all three), so a label rolled onto a bash-5.3 image changes what the falsify tier reports. The repo already pinned the one image whose bash version it cared about (the `suite-floor` container) and had left the host unpinned under the same reasoning. `tests/test-workflow-runner-pinned.sh` enforces it: every job either names a pinned image or is a reusable-workflow caller with no runner of its own, and all pinned jobs must name the *same* image, so "CI passed" keeps meaning one toolchain. Pinning costs maintenance — GitHub eventually retires an image label and CI breaks — and that is the point: it breaks loudly, at a named place, rather than a gate quietly starting to mean something else.

The two layers still run **different shellcheck binaries**, and this is reported rather than asserted: CI takes the version its pinned image ships, Phase 7 takes whatever the developer has (Homebrew ships current). Both now print it. Neither pins a number, because a number written in either place is a second claim that can drift from the image. Measured 2026-08-19 over the same 132 scripts, 0.9.0 and 0.11.0 both returned 0 — they agree on this tree, and the exposure is a finding that exists in one layer and not the other.

The `lint` job's `apt-get` is **bounded and retried** (three attempts, five minutes each). It is the only network operation in the gate, and on 2026-08-19 a mirror stall left it `in_progress` for 72 minutes against a normal 40 seconds, on both repos at once, with nothing to stop it short of GitHub's six-hour ceiling. An unbounded install cannot fail a PR wrongly, but it can hold one hostage; the analysis itself is ~13s over ~130 scripts, so anything past a few minutes there is the network, not shellcheck.

---

[← Documentation index](README.md)

## Citing code

**Measured, 2026-10-02.** Of the ~55 `file:line` references under `tests/`, 21
pointed at the wrong line (ai-containers #260). None had landed on a blank line,
so the guard of the time — the one in `tests/test-docs.sh`, which scanned only AGENTS.md and
the docs pages and flagged only a blank or out-of-range target — saw none of
them. Five more were right in one repository and wrong in the other: the citing
file is byte-identical in mgd-ai-containers, the cited file is not.

**Why not check each numbered line's content instead.** It would catch the drift,
and then fire on every edit above every reference, which is the common edit. One
Dockerfile insertion that week moved three references at once. A gate that
demands hand-renumbering after ordinary edits is the gate people learn to work
around.

**What replaced it.** A citation names code by a snippet: `<file>: ` and a
backticked function name or literal, on one line. `tests/test-code-references.sh`
resolves the file — a path matches a tracked path or a suffix of one, so the
same text resolves under mgd's `base/`; a bare name is tried beside the citing
file, then as a unique basename — and requires the snippet to occur in it. It
also refuses a numbered reference to a tracked file (an untracked one, such as a
fixture written at run time or nvm's own source, is skipped), unless the line
carries `ref-lint: allow: <reason>`; and it refuses a citation split across two
lines. A sentence that ends in a file name and a colon and carries on in words
is left alone: the split rule fires only when the next line opens with a
backtick. The test proves each rule can fail on a fixture tree before it checks
the real one.

**What it cannot catch.** A snippet that still occurs but now means something
else, and a number written as prose ("line 24"). It proves the cited text
exists, not that the sentence around it is still true.

**The shim test changed with it.** `tests/test-integration-shim.sh` pinned the
launcher's one `docker run -it` by line number, so any edit above that line in
`sandbox.sh` failed it, and it kept its own guard for every comment repeating
the number. It now checks the premise itself — exactly one `-it` among the
scripts a launcher run reaches, in `sandbox.sh`, on its `docker run` — and the
general guard covers the comments.
