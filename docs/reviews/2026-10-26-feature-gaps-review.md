# Feature-gaps review — 2026-10-26

- **Review date:** 2026-10-26 (statuses updated through 2026-11-03)
- **Last reviewed commit:** `bec1c57` (`bec1c5737acdc549143e2c55e4a4b945ae27a287`, main, 2026-10-18 — "Merge pull request #312")
- **Scope:** every design, plan and backlog in the repository, wherever written — `docs/superpowers/specs/`, `docs/superpowers/plans/`, the follow-up and falsify backlogs, `tests/falsify/survivors.txt` / `targets.conf`, AGENTS.md, README.md, `docs/`, CHANGELOG.md, and TODO/deferred/follow-up markers in code.
- **Companion:** [2026-10-26-bugs-review.md](2026-10-26-bugs-review.md) (defects; doc errors that mislead users are filed there as `DOC-*`).
- **Grouping:** each gap carries an `Area:` and a `Fix batch:` line. Gaps that touch the same code as a bug batch in the companion file are folded into that batch; the rest are a separate track.

## Fix-batch mapping

| Gap | Fix batch (bugs review) | How |
|---|---|---|
| GAP-5 | 7 — tests/CI | Root cause of TST-2: read the run.sh args from the workflows; one fix closes both. |
| GAP-8 | 7 — tests/CI | One more rule in `tests/bash-dialect-lint.sh`, next to TST-5. |
| GAP-9 | 7 — tests/CI | Same falsify plumbing as TST-3. |
| GAP-14 | 8 — docs | Docs-only edits; the `mode=`/`agents=` item is DOC-6. |
| GAP-12 (part) | 1 — git internals | Only following includes inside included files (`_git_include_paths`); the rest of GAP-12 is separate. |
| GAP-6 | 4 — lifecycle scripts (optional) | Same files as DOC-3/PRJ-3; grows the batch. |
| GAP-1 (part) | 3 and 4 (stretch) | Activate the deferred falsify targets for the files those batches fix: `link-default-ruby.sh`, `install-agent-skills.sh`, `agent-tools-reconcile.sh` (3); `group.sh` (4). |
| GAP-11, GAP-13 | platform log | PLAT-3 (macOS, Mac agent) and PLAT-2/PLAT-6 (WSL2, WSL agent) in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md), whose "Who picks up what" table assigns each platform row to an agent. |
| GAP-1 (rest), 2, 3, 4, 7, 10, 12 (rest) | separate track | Larger design or falsify work, or investigation/manual runs rather than code changes. |

A gap is something a design promised that is not in the code at the reviewed commit. Items that no longer make sense are listed under OBSOLETE with the reason, so they can be overruled. Items verified as done are listed at the end so coverage is visible.


### GAP-1: Falsify "stage 2" — the nine named targets were never activated
- Status: DONE (2026-11-03). All nine are active rows in tests/falsify/targets.conf (the "STAGE 2" block). Measured together first: 535 mutants, 196 survived. New assertions in each oracle killed 172, among them every survivor of migrate-runme.sh, check-sandbox-version.sh, capture-blocked-traffic.sh, group.sh, link-default-ruby.sh and rvm-reconcile.sh. The other 24 are EQUIVALENT in survivors.txt section 24: a return status nothing reads, or a `cd /` that cannot fail. No product bug was found. The two capture-blocked-traffic.sh mutants that made a read loop spin forever are now killed by a bounded wait that prints `FAIL:`, instead of timing out as UNPROVEN.
- Fix batch: 3 and 4, stretch — only `link-default-ruby.sh`, `install-agent-skills.sh`, `agent-tools-reconcile.sh` (batch 3) and `group.sh` (batch 4); the other five targets are a separate track
- Source: docs/superpowers/specs/2026-08-11-falsify-mutation-tier-design.md: "The nine that meet (1) and await a later stage are named in `targets.conf`: `check-sandbox-version.sh`, `group.sh`, `migrate-runme.sh`, `capture-blocked-traffic.sh`, `link-agent-tools.sh`, `link-default-ruby.sh`, `agent-tools-reconcile.sh`, `rvm-reconcile.sh`, `install-agent-skills.sh`. They are the obvious stage 2"
- Area: tests/CI
- Current state at HEAD: all nine are still `#DEFERRED|…|EXECUTED-WHOLE|…|-|dedicated oracle, executed whole …; qualifies under the stage-1 rule but is not in the increment-5 set` in tests/falsify/targets.conf. The active set did grow (services.d/*, start-services.sh, extract-discovery.sh, repo-git-reset.sh, version.sh, …), but by new files, not these nine.
- What's missing: activating the rows, running the corpus, and classifying the survivors.
- Value / priority: MEDIUM. `group.sh` (it deletes volumes), `capture-blocked-traffic.sh` (self-healing allowlist) and the two reconcilers (run at every start) are exactly where an assertion that cannot fail does damage. Each already has a dedicated oracle, so this is the cheapest mutation coverage left.
- Suggested approach: uncomment one or two rows per batch, run the Linux-side batched score that AGENTS.md prescribes, and land the killing assertions or classified entries together.

### GAP-2: The large diffuse falsify targets are still deferred (sandbox.sh first)
- Status: PARTIAL
- Fix batch: separate track
- Source: same design: "The large diffuse targets (`sandbox.sh`, `tests/integration/{lib,run}.sh`, `repo.sh`, `sandbox-common.sh` …) … enter in later increments, one at a time"
- Area: tests/CI
- Current state at HEAD: still `#DEFERRED`: sandbox.sh (`193 killed / 74 SURVIVED over 50 lines`), repo.sh (`58 DISTINCT SURVIVING IDENTITIES`, explicitly "closed to the practical limit", not scheduled), sandbox-common.sh ("what it needs next is a MEASURED minimal killing set"), build.sh, install-tools.sh, tests/integration/{lib,run,minimal-conf}.sh, verify-on-host.sh, bump-sandbox-version.sh and the three migrations. The sandbox.sh row says its remaining security-adjacent survivors are "403, which needs a registered repo" and "691/702, the rvm branch, which needs `docker volume` support in this test's fake docker".
- What's missing: un-deferring sandbox.sh (the launcher, which is the security boundary on the host side), plus a minimal oracle set for sandbox-common.sh.
- Value / priority: MEDIUM for sandbox.sh (its mode and capability lines are already all KILLED, so the residue is credential seeding and group isolation); LOW for the rest. repo.sh's stop is a recorded decision.
- Suggested approach: add `docker volume` to test-tool-config-mounts.sh's fake docker and a registered-repo fixture, kill the two named security lines, then land sandbox.sh with the remainder classified.
- **Re-measured 2026-11-03 — the plan above no longer fits:**
  - **Mutants:** sandbox.sh now yields **1,567** default mutants, against 267 when the plan was written.
  - **Oracle set:** the derivation sees **24 tests** executing it. Their summed runtime is ~313 s per mutant, without the five `services.d` tests; test-git-internals-ro.sh alone takes 140 s.
  - **Cost:** activated whole, that is ~136 CPU-hours per measurement (~14 h at `--jobs 10`), far past CI's 90-minute falsify cap.
  - **The per-function unit does not help much here:** most of the launch, the REPOS mode gate and the rvm branch the plan names included, is one ~940-line `run_container()`.
- **Options, for a decision before work starts:**
  1. **Split sandbox.sh into units, each with its own oracles:** allow several rows per target, keyed by function list, each naming only the tests that reach those functions. That would cut the per-mutant cost to the one or two relevant tests. It needs `run_container()` split into functions first, which is a product refactor of the launcher, the security boundary.
  2. **Choose oracles per mutant:** map each mutated line to the tests that reach it, using line coverage gathered once with `BASH_XTRACEFD`/`PS4`, and run only those. This keeps sandbox.sh whole, but needs a coverage pass in the tier.
  3. **Accept the cost off the PR gate:** a nightly-only (or weekly) sandbox.sh shard, with its own ledger section. This is the cheapest to build. At ~14 h it is still too slow for a nightly job; it needs option 1 or 2 too.
- **Recommendation:** option 2 first. It is mechanical, changes no product code, and also speeds up every other multi-oracle target (lib-verify-repo.sh, entrypoint.sh). Then kill the security-adjacent survivors it shows, and only then decide whether sandbox.sh enters the PR gate or a scheduled shard.
- **Option 2 built, 2026-11-03** (`229eab8`, reviewed and fixed in `bb16e15`, `12e2064`, `307663a`, `8c02b99`): `tests/falsify/run.sh --select-oracles`, opt-in, used by no shard yet; how it works is in [docs/testing.md](../testing.md). A subset decides only a kill with a `FAIL:` line; anything else goes on to the rest of the set or the whole set, so the map can cost time but not change a verdict. Four review rounds found verdict-changing holes in the first three (a dirty tree carried into the second run, a timeout composite that dropped the rest's UNPROVEN, a clock per subset); the fourth found LOWs only.
- **Measured on sandbox.sh, 2026-11-03** (7 functions, 174 mutants, `--jobs 10 --timeout 180`, this Linux host under its own load):

  | What the mutant cost | Mutants | CPU time | Share | Average |
  |---|---|---|---|---|
  | killed by a subset without test-git-internals-ro.sh | 77 | 2,152 s | 3 % | 28 s |
  | killed by a subset with it | 50 | 17,837 s | 25 % | 357 s |
  | killed by 19 or more tests (a line every launch runs) | 13 | 7,872 s | 11 % | 606 s |
  | survived (always the whole set) | 29 | 19,359 s | 27 % | 668 s |
  | hung (the whole set's 72-minute clock) | 5 | 23,553 s | 33 % | 4,711 s |

  - **Total:** 70,774 s of CPU, 8,236 s wall. Run whole, the same mutants would cost ~134,400 s (169 × the 668 s a whole-set run took under that load, plus 5 × 4,320 s): **47 % less**, 58 % less leaving the hangs out.
  - **Misses:** 2 mutants survived their subset and were killed by the rest of the set; 3 subsets timed out and the rest ran. No verdict depended on the map.
  - **The whole file:** 1,567 mutants at the sample's rate is ~20 h wall at `--jobs 10`. Selection halves the cost; it does not bring sandbox.sh near CI's 90-minute cap, or a nightly run.
  - **Found by the run:** the TIMEOUT note named `--timeout` (180 s) instead of the set's clock (TST-26, fixed); and `tests/test-git-internals-ro.sh` went red on the pristine tree under this load, its G38 config refused by the 2 s read bound (GIT-23, fixed 2026-11-04). That failed one of the two control runs, so the run exited 1.
- **Decision on placement: sandbox.sh stays DEFERRED.** The levers, by their measured share:
  1. **Hangs, 33 %.** A hang pays the whole set's clock (24 × 180 s) even when one test hangs. A per-test clock in `tests/run-all.sh` would cap it near 180 s. It changes the shared driver and what a timeout means, so it needs a design decision first.
  2. **test-git-internals-ro.sh, 25 %.** It is in most subsets for the git-internals code, at 143 s alone and ~357 s under load. Splitting it into files by area would let the map select only the part that reaches a line, and would speed up the hermetic suite as well.
  3. **Survivors, 27 %.** These run the whole set by construction. Killing them, or classifying them, is the only way to cut this share.
  4. **Fail-fast** (stop `tests/run-all.sh` at the first failing test) only helps the 11 % of kills by 19 or more tests. It is smaller than this entry's earlier estimate.
- **Survivors in the sample, handled 2026-11-04:** 29, in `_utf8_valid` (5), `pointer_repo_entry` (1), `_git_index_read` (11) and `_git_config_bool` (12). 25 are now killed: by a byte table for `_utf8_valid` and a return-status check in `tests/test-parsers.sh`, and by G86's repaired premise and G95–G97 in `tests/test-git-internals-ro.sh` (an index that is missing, a directory, or under an unknown or path-like object format; a sha256 repository's linked worktree; the no-git fallback against git's own answers — G97 and G86's fallback checks went with the fallback when GIT-24 was fixed). Each was seen failing against its mutant, and `tests/falsify/run.sh` over the four functions with the new tests left 4 of the 29: two flips in `_git_index_read`'s `commondir` lookup that the launcher's own `./` placeholder makes equivalent, and two `return 1`→`return 0` after `_rd_fail()`, whose USR1 trap refuses the launch whatever the function returns. Two defects turned up on the way: G86 had passed vacuously under `tests/run-all.sh` (TST-27, fixed), and the fallback reads some spellings of true as false (GIT-24, fixed 2026-11-04 by removing it). The remaining 1,393 mutants of sandbox.sh were not in the sample and are unmeasured.

### GAP-3: Container-side firewall and capture scripts have no hermetic oracle; entrypoint.sh's row is stale
- Status: DONE (2026-11-03).
  - **The firewall and capture scripts:** tests/test-refresh-ipset.sh (fake ipset and getent) and tests/test-capture-destinations.sh (fake tcpdump and tshark) are the new oracles. Both scripts are EXECUTED-WHOLE targets: 34/34 and 21/25 mutants killed. The 4 left are `|| true` → `&& true` under `set -e`, the same program (EQUIVALENT).
  - **entrypoint.sh as its functions:** derive-targets.sh sees an awk or sed range extraction of `^name()` as execution of those functions (kind `extract`), and its gate holds an EXECUTED-PARTIAL row to the functions an oracle really runs. generate.sh's `FALSIFY_FUNCTIONS` limits mutants to them, and run.sh runs an active EXECUTED-PARTIAL row instead of refusing it. entrypoint.sh is EXECUTED-PARTIAL over six functions, with four oracles: 63 of 65 killed, 2 EQUIVALENT.
  - **Two security-relevant gaps the measurement found, now covered:** a launcher-mount refusal in `verify_launcher_mounts` that printed the error and exited 0 would have gone unnoticed (the test checked the words only); and `refuse_root_identity` was never tested with a user name, so a damaged fallback could refuse every real user or let an unresolvable one through.
  - **Also found:** test-ruby-wrapper.sh only read `link_default_ruby`'s text. It now runs it.
- Fix batch: separate track
- Source: tests/falsify/targets.conf GREPPED-ONLY block: "Every one of them is a container-side script … that no hermetic test runs"
- Area: tests/CI (entrypoint/firewall)
- Current state at HEAD: `refresh-ipset-allowlist.sh|GREPPED-ONLY|-` and `capture-agent-destinations.sh|GREPPED-ONLY|-` are covered only by integration cases (020/030/300, 120/220). `entrypoint.sh|GREPPED-ONLY|test-entrypoint-wiring.sh` understates the coverage: tests/test-launcher-verify.sh and tests/test-env-file.sh extract and *run* `verify_launcher_mounts` and `stash_app_env` under the entrypoint's `set -euo pipefail`. derive-targets.sh's textual resolution cannot see function extraction, so this execution is invisible to the gate.
- What's missing: a hermetic oracle for the ipset refresh (resolve → ipset add, with getent/ipset faked), and a per-function target unit, or derive-targets support, so the extracted entrypoint functions can enter the tier.
- Value / priority: MEDIUM. These are the firewall's own scripts. Integration cases cover behaviour, but only nightly or on a NET_ADMIN host, and nothing measures whether their assertions can fail.
- Suggested approach: give refresh-ipset-allowlist.sh a faked-`getent`/`ipset` test, as test-blocked-capture.sh does with faked tshark, and add an "extracted function" execution form to derive-targets.sh.

### GAP-4: The `stmt-delete` operator and the per-target `stream-flip` gate were never built
- Status: DONE (2026-11-03), with one decision recorded here.
  - **What was built:** tests/falsify/generate.sh has `stmt-delete` (off by default): a line that is one complete command (a simple command, or a list such as `[[ … ]] && return 1`) becomes `:`; never a line inside a literal that spans lines (a quoted awk program, an array's elements). tests/falsify/deep.conf gives a target extra operators (`stmt-delete` or `stream-flip`), with the measured score as its reason. `run.sh --deep` runs only those targets under only those operators. Every run records `OPERATORS|<target>|<list>`, and check-ledger.sh scopes its stale and obsolete checks by operator, so the default and deep passes share one ledger.
  - **Entry rule, from the first measurement:** stmt-delete alone over every active target except repo-git-reset.sh, 1,667 mutants, scored 45–98 %. A target qualifies at ≥ 90 % killed with no assertless kill. Four are in: version.sh, refresh-ipset-allowlist.sh, redis.sh and mariadb.sh. bash-dialect-lint.sh looked like 41/42 only because the operator still fired inside its rules array and awk programs. The review of this change caught that. Once the operator was fixed it measured 20/27, and it is out.
  - **Their survivors (final measurement):** 115 mutants, 112 killed. The kills include a real hole: deleting the poll's `sleep`, or the check that the try count is a number, left the redis and mariadb readiness waits with no time bound, and no test noticed. Tests D4b/D4c and D5b/D5c now cover it. The 3 left are EQUIVALENT (survivors.txt section 25). Most targets scored 50–80 %, so stmt-delete there would flood the ledger, as the design predicted.
  - **The decision:** the design placed stmt-delete in a nightly-only tier. The deep pass instead runs in **every** CI run (the falsify job's `deep` shard) and in Phase 6, because the four targets that qualify cost about five minutes together. A nightly-only shard becomes worth adding when a costly target earns an operator.
- Fix batch: separate track
- Source: falsify-mutation-tier-design.md operator table: "`stmt-delete`, enabled per-target on a measured score | Nightly" / "full matrix, on the host | Local (Phase 6)"; and stream-flip "may return as an opt-in per-target operator gated on a measured score"
- Area: tests/CI
- Current state at HEAD: tests/falsify/generate.sh has `FALSIFY_ALL_OPERATORS="cond-negate logic-flip return-flip cmp-flip stream-flip"` and no stmt-delete at all. `stream-flip` is opt-in globally via `FALSIFY_OPERATORS`, not per target. Nightly runs the same falsify job as PR (via hermetic-checks.yml), and verify-on-host.sh Phase 6 calls `falsify/run.sh --jobs "$fl_jobs" --timeout "$fl_timeout"` with the default operators.
- What's missing: the operator; a per-target operator column in targets.conf; and nightly and local runs that actually go deeper than PR. The operator table's Nightly and Local rows describe tiers that do not exist.
- Value / priority: LOW–MEDIUM. stmt-delete is the operator shaped like historical holes #3 and #4 ("a behaviour silently missing").
- Suggested approach: add `stmt-delete` to generate.sh behind an opt-in per-target field, and enable it nightly for the targets that score highest (mutate.sh, tools-lib.sh).

### GAP-5: The layer-containment guard checks a hand-maintained copy of the workflow selection args
- Status: DONE (batch 7) — `be63670`, with TST-2: there is no copy to maintain any more. The guard derives each layer's run.sh arguments from the workflows themselves (`wf_it_selections()` in tests/lib-layer-checks.sh) and fails by job and step on anything it cannot decide.
- Fix batch: 7 — tests/CI (same fix as TST-2)
- Source: execution-layers-and-portability-design.md: "Each workflow keeps its own selection arguments; the guard reads them and checks containment". Plan 2026-08-11-execution-layers-and-portability.md: "teaching the guard to read `--tags`/`--exclude` out of the workflow YAML instead of a maintained-by-hand copy … is real follow-up work"
- Area: tests/CI
- Current state at HEAD: tests/test-layer-containment.sh hardcodes `pr_set="$(sel --tags fast --exclude needs-external,needs-dns)"` and `nightly_set="$( { sel --exclude packages; sel --tags packages; } | sort -u )"`. The real args are in integration.yml (`args="--tags fast --exclude needs-external,needs-dns --require security"`) and nightly.yml.
- What's missing: if a workflow's args change, the guard keeps passing against the old copy.
- Value / priority: MEDIUM–LOW. The step-count ratchet catches added or removed steps, but not edited arguments, and `local ⊇ nightly ⊇ PR` is a central claim of AGENTS.md.
- Suggested approach: put each layer's `tests/integration/run.sh` args in one place (tests/layer-checks.conf, or an env file the workflows `source`), and have both the workflow and the guard read it.

### GAP-6: Changes to the generated `runme.sh` template never reach existing projects
- Status: DONE (2026-11-02) — `90f0417`, `123dd75`, `799f959`, `1ca06cf`. `launcher-templates/<n>.tmpl` records every thin launcher `project-init.sh` has generated (the name written `@@PROJECT_NAME@@`); the launcher names its template number (now 4). sync-to-projects.sh: `reconcile_launcher()` regenerates a `runme.sh` that is one of them, as generated or as earlier syncs left it, and keeps an edited, fat or linked one with a `NOTE:` naming the `diff` to compare. The old self-call repair no longer rewrites comments (it had turned the template's `./runme.sh` hints into `./sandbox.sh` in every synced project). Every write to `runme.sh` reads it once through a checked open and replaces it by an exclusive create and a rename; its reviews' leftover, the project's other files written by path, is bugs review PRJ-10. `tests/test-launcher-templates.sh`, each check killed by a demonstrated mutant.
- Fix batch: 4 — lifecycle scripts (optional)
- Source: sandbox-conf-schema-migrations-design.md "Out of scope": "The per-project generated launcher … if the launcher template later gains a new exported variable, already-initialized projects' launchers don't get it … deliberately deferred to a possible future design"
- Area: project/repo/group
- Current state at HEAD: the thin launcher (project-init.sh: `emit_launcher()`) narrowed the problem but did not close it. sync-to-projects.sh only rewrites a stale self-call (`sed -i.bak 's#\./runme\.sh#./sandbox.sh#g'`) and never regenerates the launcher. Concretely, the `--version` short-circuit (`-V|--version|version) exec ./sandbox.sh --version`, CHANGELOG: "the generated launcher short-circuits **before** its own `./build.sh`") is missing from every launcher generated before it, so `./runme.sh --version` there runs a build first.
- What's missing: a reconcile step: regenerate `runme.sh` when it matches a known prior template, and warn when it has been hand-edited.
- Value / priority: LOW–MEDIUM. It surfaces as "the docs say X, my project does Y".
- Suggested approach: stamp the template with a version comment, and have sync-to-projects.sh rewrite a launcher whose stamp is older and whose body matches that version's text exactly.

### GAP-7: Codex and Gemini still cannot update themselves (the regression doc's open question)
- Status: DONE (2026-11-03). **Codex** has one: OpenAI's standalone installer (`https://chatgpt.com/codex/install.sh`) puts releases under `~/.codex/packages/standalone`, and Codex, recognising itself as standalone by its binary's path, runs `update` by re-running that installer rather than npm (codex-rs/tui/src/update_action.rs). Measured in a container as a non-root user: 0.165.0 installed, `codex update` brought 0.166.0 in 15 s, no profile edited. The reconcile now installs it that way, install-if-missing on `current` (agent-tools-reconcile.sh: `install_codex_standalone()`); link-agent-tools.sh links `/usr/local/bin/codex` through `current`, and a leftover npm copy only while there is none; `releases.openai.com` joined allowlist-domains.d/codex.txt (`chatgpt.com` redirects there; the `*.openai.com` proxy pattern admits it only by self-healing, and with `SELF_HEALING_ENABLED=0` case 700 fails without the line and passes with it); case 700 asserts the standalone link and runs `codex update` behind the restricted firewall. Costs recorded in docs/agent-tools.md: two releases kept, ~940 MB against npm's 456 MB, and a sibling container running a release two updates old loses its helpers. **Gemini** has none: its only binaries are macOS builds, and its UI's auto-update runs a bare `npm install -g @google/gemini-cli@latest` for a global npm install (packages/cli/src/utils/installationInfo.ts; read, not run), the command that fails on nvm's prefix. It stays on the reconcile's update-when-the-registry-differs (RT-7). Before this, since `6836894`, both were on that path.
- Fix batch: separate track
- Source: docs/superpowers/specs/2026-08-22-agent-autoupdate-regression.md "Open question": "Whether the same treatment is available for the other three CLIs … Not investigated; recorded so it is not mistaken for settled."
- Area: runtime-tools
- Current state at HEAD: Claude Code installs natively; Copilot updates itself. For Codex and Gemini the reconcile updates them at start when the published version differs (AGENTS.md table; a reinstall costs ~7s warm, ~24s cold, and now happens only when there is a new release).
- What's missing: no one has checked whether Codex or Gemini have a native or standalone install that could update itself.
- Value / priority: LOW. It works today; the cost is a registry query per start and a reinstall per release.
- Suggested approach: test Codex's standalone GitHub-release binary in a restricted-mode container, the way Claude Code's native path was tested. If it updates itself, switch it to install-if-missing.

### GAP-8: No mechanical guard against awk interval quantifiers (falsify backlog F14)
- Status: DONE (batch 7) — `17b073f`, widened in `9142ea4`, `931c3fc` and `b3f18d7`: rule `awk-interval` in tests/bash-dialect-lint.sh reads every quoted argument of an awk command (single-quoted across lines, double-quoted within the line), with the usual marker as the escape hatch. Backlog F14 is marked FIXED.
- Fix batch: 7 — tests/CI (with TST-5)
- Source: 2026-08-14-falsify-backlog.md F14: "ACCEPTED: a prose guard, weaker than this repo's norm and recorded as such"
- Area: tests/CI
- Current state at HEAD: a prose warning in tests/portability.sh's header. tests/bash-dialect-lint.sh has no awk rule. The floor run (mawk on ubuntu:22.04) catches it late.
- What's missing: a lint-time check.
- Value / priority: LOW.
- Suggested approach: add a dialect-lint rule matching `{[0-9]` inside single-quoted `awk '…'` arguments, with the existing `# dialect-lint: allow` escape hatch.

### GAP-9: The empty-corpus rule is not pinned for test-falsify-historical.sh
- Status: DONE (batch 7) — `269f77d`: tests/test-lint-empty-corpus.sh drives test-falsify-historical.sh with an empty `git ls-files`. It stops at the seed before any oracle runs, so it costs about a second, and it now says SCAFFOLD-FAILED.
- Fix batch: 7 — tests/CI (with TST-3)
- Source: tests/test-lint-empty-corpus.sh header: "the same rule in tests/test-falsify-historical.sh is NOT pinned this way, because exercising it there means a full run of nine real oracles"
- Area: tests/CI
- Current state at HEAD: three lints are driven against an empty `git ls-files`; the historical gate is not.
- What's missing: an assertion that an empty derivation there reports `SCAFFOLD-FAILED:` rather than passing.
- Value / priority: LOW.
- Suggested approach: drive only the derivation step with a stubbed oracle list, so no real oracle runs.

### GAP-10: F58's trigger (an empty `git ls-files` under load) was never identified
- Status: PARTIAL
- Fix batch: separate track
- Source: falsify backlog F58: "GUARD FIXED; the TRIGGER is still unidentified"
- Area: tests/CI
- Current state at HEAD: the guard (one derivation, reported as `SCAFFOLD-FAILED`) is in place, and test-lint-empty-corpus.sh covers its siblings. The cause was never found. F64 later found a trap in a forked child deleting the scratch directory, which may be the same mechanism, but no one checked.
- What's missing: confirming or ruling out the F64 mechanism for F58.
- Value / priority: LOW. The harm is contained.
- Suggested approach: when it next happens, check whether F64's `dir=n` diagnostic fires; if so, close F58 as a duplicate of F64.

### GAP-11: The launcher-mount swap check is skipped on macOS Docker Desktop and Colima
- Status: PARTIAL. Confirmed on Colima 2026-11-04 (case 460 PASS). The nonce suggested below does not work, because the swapping container can read and copy it. A VM-side inode via `colima ssh` does work, Colima only; see PLAT-3's Status for the design and its limits. No code yet.
- Picked up by: the **Mac agent** (macOS, Docker Desktop and/or Colima), as PLAT-3
- Fix batch: platform log — PLAT-3 in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md) (needs that platform to run)
- Source: AGENTS.md mount layout: "if its own `device:inode` does not survive the bind (a file-sharing layer such as macOS Docker Desktop or Colima), verification is skipped with a one-line `NOTE:`"
- Area: launcher/mounts
- Current state at HEAD: `verify_launcher_mounts()` works on Linux; case 460 checks whichever host it runs on. On macOS the swap race (a concurrent container replacing an overlay source with a symlink) goes unchecked.
- What's missing: protection for macOS, the platform with the most users.
- Value / priority: MEDIUM. It is a security property that silently does not apply on one platform, though exploiting it needs a concurrent container on an overlapping writable tree.
- Suggested approach: on hosts where inodes do not survive the bind, compare a per-launch nonce file written into each overlay source instead of `device:inode`.

### GAP-12: Known holes in the git-internals protection
- Status: DONE (2026-11-03). Both remaining holes, test-first in `tests/test-git-internals-ro.sh`. **G93:** a repository whose `./` placeholder was already there (an earlier engine's, or planted with a repository the agent made) gets its keys and hooks named once. A host record, `~/.ai-containers/git-reported.conf`, holds one `<device inode birth-time> <path>` line per reported repository, written after the NOTE. **G94:** when `docker run` returns, `_git_after_session()` rescans the writable mounts the launch scanned, each in a subshell of its own (`git_dirs_in` refuses by exiting), with index reads made afresh and a 30 s deadline. It names each git directory new by identity whose config or hooks make git run something (`_git_runs()`, shared with the first-protection NOTE; a `commondir` or `hooks/` link included) or that cannot be listed, and, separately, each new `.git` file or link. A plain init or clone is not named. A search cut short (a refusal, `SANDBOX_GIT_MAX`, a read past its bound, the deadline) says so instead of refusing, and the container's exit status is kept. Its review (an Opus reviewer and the automated security review) found the refusal by exit lost silently, the launch's cached index reads reused, a `hooks/` or `commondir` link not judged, no deadline, the record written before the NOTE and keyed by path alone; all fixed, each with a check seen failing first except the record's order, which needs a read cut off inside `_git_runs()`. Not warned, by nature: a repository made while the container runs (until it exits), a launcher killed before the rescan, a sibling container's repository made after this one exits, and one where the launch scan does not look either.
- Fix batch: 1 — git internals, for following includes inside included files only; the post-launch `.git` warning and the exec-key report for earlier-protected repos are a separate track
- Source: AGENTS.md: "**Not covered**: configuration poisoned **before** this protection existed …; a file that an included file includes in turn; and a `.git` the agent **creates** in a subdirectory"
- Area: launcher/mounts
- Current state at HEAD: these are documented. The first protected launch names the exec keys (`_git_exec_keys()`) and the existing hooks, and a non-`./` `commondir` refuses the launch.
- Batch 1 (`b3d2362`): nested includes are now followed (test G29), and the config reads can no longer be silenced by an include loop (G30). Still missing below: protection, or at least a warning on the next launch, for a `.git` the agent created after the scan; and an exec-key report for repositories an earlier engine protected (the record says those "get no list").
- Value / priority: MEDIUM. The host's git runs whatever these files hold.
- Suggested approach: walk includes recursively with a depth bound (git's own limit is 10). On exit, rescan the writable mounts for git directories that are new since launch and print a `WARNING:` naming them.

### GAP-13: WSL2 has never been run
- Status: PARTIAL (2026-11-03 refresh). Docker Desktop + WSL2 was run on 2026-10-26 (docs/testing.md, "Platforms exercised"). A re-run at current `main` is PLAT-6. A Docker Engine installed natively in the distro has still never been run.
- Picked up by: the **WSL agent** (Windows + WSL2 + Docker Desktop; **not** a native Engine), as PLAT-6. The native-Engine half has no agent.
- Fix batch: platform log — PLAT-2 in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md) (needs that platform to run)
- Source: 2026-08-10-integration-suite-increment-3-design.md: "WSL2 | expected, **never exercised** … Recorded as expected-and-unverified rather than supported"
- Area: tests/CI
- Current state at HEAD: host-preflight.sh warns about `/mnt/<drive>` checkouts and `ALLOW_IPV6_BYPASS` exists, but there is no recorded run of the corpus or the local layer on WSL2.
- What's missing: one recorded run of the corpus and the local layer on WSL2.
- Value / priority: LOW (depends on how many users are on Windows).
- Suggested approach: run `bash ./verify-on-host.sh` once on a WSL2 host and record the result in docs/testing.md.

### GAP-14: Doc and comment drift found during the audit
- Status: DONE (batch 8) — `4d53bc9` … `5da9aeb`; every item listed below is fixed (the `integration.yml` trigger note was already gone).
- Fix batch: 8 — docs (overlaps DOC-6)
- Source: various live docs
- Area: docs
- Current state at HEAD:
  - docs/multiple-projects.md explains the config digest with sandbox.conf keys that do not exist ("runtime ones (`mode=`, `agents=`)", "switch `mode=` between `restricted` and `open`"). Mode is `SANDBOX_MODE` in sandbox.env, and sandbox.conf has no `mode=` or `agents=`.
  - .github/workflows/integration.yml says "push is also currently the ONLY trigger that fires here (see the temporary-trigger note above)", but `on:` now has `pull_request` too.
  - docs/testing.md says "`nightly.yml`'s `packages-agents` and `packages-native` jobs each invoke …", but nightly also has `packages-services` (services and mariadb variants). It also gives the falsify cadence as `--jobs $(nproc)`, while CI runs `--jobs auto`.
  - The falsify backlog header still says "4 `GAP:` entries in `tests/falsify/survivors.txt`"; there are 0.
  - docs/configuration.md links `POSTGRES_ROLES`/`POSTGRES_DATABASES` as container.env variables, but not the parallel `MYSQL_USERS`/`MYSQL_DATABASES` (documented only in docs/components/mysql.md).
- What's missing: the edits. (The `mode=`/`agents=` item is also filed as bug DOC-6; fix it once.)
- Value / priority: LOW. The `mode=` example could mislead someone reading about rebuild warnings.
- Suggested approach: one docs-only PR. The falsify backlog header is the file's own claim about itself, so update it rather than leave it.

---

## OBSOLETE (no longer applies)

- **Regression doc "Planned change 4/5": remove the superseded npm copy of Claude Code and test that removal.** Reversed on purpose. AGENTS.md: "the reconcile deliberately does **not** delete it — other containers in the same group may be running against it". The manual `rm -rf` is documented instead.
- **Agent-tools runtime-home design: skel `.npmrc` with `prefix=${HOME}/.ai-tools/npm`.** Removed (`bc2e551`) because it breaks `nvm use`. Replaced by the `npm-agent-tools` function and per-call `--prefix`.
- **Agent-tools runtime-home design: a BLOCKING real-container smoke test before merge.** Replaced by integration cases 700/710/720. The later smoke test was deleted (falsify backlog, "superseded AND rotted … CLOSED 2026-09-01").
- **runme-sandbox-swap design: delete a `runme.sh` that lacks the `export IMAGE_NAME=` marker.** Removed after it deleted every thin launcher (CHANGELOG). Pre-swap projects are told to re-run project-init.sh.
- **Increment-1 design: CI tables naming a `unit` job and `integration-fast`, and Phase 1–3 coverage in verify-on-host.sh.** Restructured into hermetic-checks.yml (`suite`, `suite-floor`, `lint`, `falsify`) and the `packages` tier; phases 1–3 are permanently burned.
- **host-pointer-mounts / agent-tools rollout follow-ups in other repos** (plugin READMEs that say `/workspace/obsidian`, fip re-sync, the mgd ports). Out of this repo's scope.
- **Increment-1 "tests.yml is a required check on both repos".** Branch protection could not be read (`gh api` returned 401); it is a repo setting, not code, so it cannot be checked here.
- **Falsify backlog F31 "DEFERRED remaining debt": guard the `mktemp -d` sites in mutate.sh and lib-verify-repo.sh.** Neither file calls `mktemp` any more, so there is nothing left to guard.

---

## Verified DONE (spot-checked against code)

- Followup backlog #1: no `mk_repo produced no repo path` guards left; the checks moved to source time.
- Followup backlog #2: test-verify-exit-code.sh reads the `rc_var` of the `floor-suite` row and sets it (`export "${floor_rc_var}=1"`).
- Followup backlog #3: one `mkdir -p "$TMP/bin"` left in lib-verify-repo.sh.
- `return 1 2>/dev/null || exit 1` idiom: only a comment mentions it now.
- DB-servers spec: postgres, plus all three follow-ups (redis, mysql, mongo) and mariadb. Adapters, cases 780–810, 25 mutation patches, falsify rows for every adapter and start-services.sh, docs/components pages, services.d sync in project-init and sync-to-projects, start-services.sh in shared-files.sh.
- Agent auto-update regression for Claude Code: native install, `~/.local/share/claude` and `~/.local/state/claude` group mounts, linker gated on `AI_RUNTIME_TOOLS`, case 710 checks the native path.
- Agent-tools runtime home: `~/.ai-tools`, reconcile, linker, `AGENTS_CACHE_BUST` retired.
- specs-path / docs-path / host-pointer mounts: `/workspace/vault` rename (no `workspace/obsidian` left in sandbox.sh), `@name` and `:ro`/`:rw` grammar, one consolidated qmd nudge (`qmd_corpora`).
- runme ↔ sandbox swap, the thin launcher, migrate-runme.sh using the real `emit_launcher()`.
- Schema migrations: migrations/002–004, bump-sandbox-version.sh (its `TODO:` is template text for the generated hook, by design), check-sandbox-version.sh, the duplicate-key guard in sandbox-common.sh.
- sandbox.env / sandbox.local.env split and `load_env_defaults`; the local-env SANDBOX_MODE comment.
- Integration increment 1: needs-dns cases 080/085 (the dnsmasq sidecar), the nightly allowlist-health job, diagnostics artifact upload, `it-run` labels, per-case timeouts.
- Integration increments 2 and 3: mounts/groups/volumes cases 400–630, packages tier 700–770, `dump_blocked_forensics` reached from the shared failure diagnostics.
- Falsify design "network/security tier": every case except 000-harness-selftest has a mutation patch, including the never-demonstrated 050 and 210, and test-mutations.sh's coverage loop includes `network-mode` and `delivery`.
- Layer-containment registry §6 parked defects: `split_env_list` with `set -f` covers `EXTRA_MOUNTS` and `PREVIEW_PORTS`; empty-corpus guards are exercised (test-lint-empty-corpus.sh, test-bash-dialect-lint.sh, test-verify-exit-code.sh).
- nightly ⊇ PR over checks: hermetic-checks.yml is called by both tests.yml and nightly.yml.
- Falsify backlog: every F-entry heading reads CLOSED/FIXED/RESOLVED except F14 (GAP-8) and F58 (GAP-10). F28 and F59 were later marked FIXED; F42's untracked-script notice is in Phase 7 (`not yet tracked by git`).
- macOS findings plan: all six fixed (`p_realdir`, `pwd -P` in mutate.sh, `$TRUE_STUB`, flock stub, …).
- GITHUB_TOKEN credential helper on the nvm and pyenv clone layers (Dockerfile: `credential.https://github.com.helper`).
- AGENTS.md mechanisms spot-checked as present: `group.sh gc`, `ai-containers-report.sh --tsv`, `changelog-coverage.sh --check`, `extract-discovery.sh --discard`, `repo.sh reset`/repo-git-reset.sh, `SANDBOX_GIT_MAX`, `_git_exec_keys`, `_utf8_valid`, `launcher_dirs_in`, `stash_app_env`, `verify_launcher_mounts`, `container_env_filter`, `selinux_security_opt`, `resolve_selinux_opt`, `remove_replaced_image`, `repos_path_in_container`, `SLASH_COMMAND_TOOL_CHAR_BUDGET`, uv `--no-managed-python` fallback, `services_csv`; every env var in AGENTS.md's table is also in docs/configuration.md.
- CHANGELOG Unreleased: empty, and correctly so (only test commits since v0.10.7).
