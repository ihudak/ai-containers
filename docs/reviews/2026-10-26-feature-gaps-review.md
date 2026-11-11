# Feature-gaps review — 2026-10-26

- **Review date:** 2026-10-26 (statuses updated through 2026-11-11)
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
  - **Found by the run:** the TIMEOUT note named `--timeout` (180 s) instead of the set's clock (TST-26, fixed); and test-git-internals-ro.sh (now `tests/test-git-internals-ro-config.sh`) went red on the pristine tree under this load, its G38 config refused by the 2 s read bound (GIT-23, fixed 2026-11-04). That failed one of the two control runs, so the run exited 1.
- **Decision on placement: sandbox.sh stays DEFERRED.** The levers, by their measured share:
  1. **Hangs, 33 %.** A hang paid the whole set's clock (24 × 180 s) even when one test hung. **Done 2026-11-04** (the user's choice): every test gets a clock of its own in `tests/run-all.sh`, five times its baseline time and never below `--timeout`. A hang now costs the tests before it plus the hung test's own clock, about 12 minutes for test-git-internals-ro.sh, instead of the set's 72. The multiplier is 5, not the 3 first proposed, because the slowest oracle ran 2.5 times slower under the run's own load. The run stops at the stopped test, so verdicts are the set's; letting the tests after it run, as first proposed, could score a kill on what the stopped test left behind (its review). docs/testing.md has the details.
  2. **test-git-internals-ro.sh, 25 %.** It was in most subsets for the git-internals code, at 143 s alone and ~357 s under load. **Done 2026-11-04** (the user's choice): it is five files by area, `tests/test-git-internals-ro-scan.sh`, `-config`, `-index`, `-reports` and `-reads`, which share `tests/lib-git-internals-ro.sh` and keep the G numbers. Together they give the same 204 check lines. The map can now select only the files a line reaches. A line every launch runs still selects all five, which now pay four more setups and first launches; the saving is not measured yet. This entry once said the split would also speed up the hermetic suite. It does not: `tests/run-all.sh` runs tests one after another, so the total stays about the same (a little more, for each file's own setup and first launch).
  3. **Survivors, 27 %.** These run the whole set by construction. Killing them, or classifying them, is the only way to cut this share.
  4. **Fail-fast** (stop `tests/run-all.sh` at the first failing test) only helps the 11 % of kills by 19 or more tests. It is smaller than this entry's earlier estimate.
- **Survivors in the sample, handled 2026-11-04:** 29, in `_utf8_valid` (5), `pointer_repo_entry` (1), `_git_index_read` (11) and `_git_config_bool` (12). 25 are now killed: by a byte table for `_utf8_valid` and a return-status check in `tests/test-parsers.sh`, and by G86's repaired premise and G95–G97 in test-git-internals-ro.sh (now split: G86 in `tests/test-git-internals-ro-reads.sh`, G95 and G96 in `tests/test-git-internals-ro-index.sh`) (an index that is missing, a directory, or under an unknown or path-like object format; a sha256 repository's linked worktree; the no-git fallback against git's own answers — G97 and G86's fallback checks went with the fallback when GIT-24 was fixed). Each was seen failing against its mutant, and `tests/falsify/run.sh` over the four functions with the new tests left 4 of the 29: two flips in `_git_index_read`'s `commondir` lookup that the launcher's own `./` placeholder makes equivalent, and two `return 1`→`return 0` after `_rd_fail()`, whose USR1 trap refuses the launch whatever the function returns. Two defects turned up on the way: G86 had passed vacuously under `tests/run-all.sh` (TST-27, fixed), and the fallback reads some spellings of true as false (GIT-24, fixed 2026-11-04 by removing it). The remaining 1,393 mutants of sandbox.sh were not in the sample and are unmeasured.
- **Slice 2, measured 2026-11-05:** the 15 git-internals helpers. They are `_is_git_dir`, `_is_common_dir`, `_gd_resolve`, `_gdi_follow`, `_git_usable`, `_git_config_get`, `_git_exec_keys`, `_git_runs`, `_git_ident`, `_git_reported_load`, `_git_reported`, `_git_report_record`, `_git_after_session`, `_git_file_config` and `_git_include_paths`.
  - **The run:** 245 mutants, `--select-oracles --jobs 10 --timeout 180`, against the 28 tests that execute sandbox.sh, at `fd49c3c`. It took 3 h 25 min of wall time and 111,918 s of CPU.
  - **Result:** 169 killed, 73 survived, 3 unproven.
  - **Cost:** a kill took 365 s on average; most selected the five git-internals files. A survivor always runs the whole set, 668 s, so the survivors took 44 % of the CPU.
  - **57 survivors and one of the 3 unproven are now killed,** each seen failing against its mutant with the final test files:
    - **G100–G110,** plus additions to G26, G27 and G94, in `tests/test-git-internals-ro-scan.sh`, `tests/test-git-internals-ro-index.sh` and `tests/test-git-internals-ro-reports.sh`.
    - **Two GIT-25 checks** in `tests/test-docs-path.sh`.
    - **A bounded launch** in G98 (`tests/test-git-internals-ro-config.sh`) and a primary argument for `launch_timed`.
  - **What the new checks cover:**
    - **What git would not take for a git directory** (no HEAD, no `objects/`, no `refs/`) is named, and nothing is made in it.
    - **A bare repository** whose HEAD links to a directory is protected.
    - **`.git` files naming nothing yet** get five WARNINGs and a count.
    - **A commondir** gives its common directory no worktree.
    - **A commondir or `hooks/` that is a link** is reported, and the launch goes on.
    - **An index is read once,** and read again for a referrer found only after the read.
    - **macOS's git shim** is judged by the git under `xcode-select -p`.
    - **`sendemail.smtpserver` given as a path** is named.
    - **A config.worktree that sets no `core.hooksPath`** leaves the config's in force.
    - **The record of reported repositories:**
      - it is read whole, and never read or written through a link, nor when it is a FIFO;
      - recording a repository already in it adds no line;
      - a line written after a hand-edited last line goes on its own line;
      - a path with a newline is named at every launch.
    - **`_git_ident`** keeps a link's target. Its BSD `stat` branch is checked with a fake `stat`.
    - **The rescan after the session:**
      - a new linked worktree is named with its common directory's hooks;
      - an unsearchable new `.git` is named;
      - a quiet session says nothing was cut short;
      - each record goes under its own WARNING.
    - **A repository with no config** has its index read as sha1.
  - **Five of those survivors ended the launch in silence.** Each is a `return 0` turned `return 1`:
    - in `_git_runs()`: a commondir or `hooks/` that is a link;
    - in `_git_report_record()`: a record that is a link or a FIFO, one that already holds the line, and a path with a newline.
    - Both functions are called as plain commands under `set -e` in `launcher_ro_overlay()`. No test asserted the launch's exit status in those cases.
  - **15 EQUIVALENT:**
    - **A status no caller reads** (5):
      - `_git_exec_keys` and `_git_include_paths` ×2: each is read through `mapfile < <(…)`;
      - `_git_config_get` ×2: every caller is `x="$(…)" || x=""`.
    - **`|| true` turned `&& true` on a command that returns 0 or exits** (3): `git_dirs_in`, `_git_runs` and `mapfile`.
    - **`|| true` turned `&& true` where the failing command is not the last of its `&&` list,** so errexit does not fire, and nothing reads the status (2).
    - **The same on a `while read` loop** (1), whose status is 0 once its file opens.
    - **`return 1` after "commondir, which leads nowhere"** (1). Only the rescan after the session reaches it, and it calls `_git_runs … || true`.
    - **`exit 1` after the deadline's record** (1), where the record already says the search was cut short.
    - **`2>/dev/null` turned `2</dev/null`** (1): git's diagnostics are lost either way.
    - **`mkdir -p` of a directory** that exists by then (1).
  - **One mutant was listed as equivalent and is not:** `[[ -n "$own" ]] || return 1` in `_git_runs()`. The review of the new tests reached it through a commondir holding `.\0/`, which the launch reads as `./`. Following that up found GIT-30 (bugs review, section 25), a HIGH. Since its fix, a NUL in a commondir refuses the launch before the report runs, so the mutant is unreachable again.
  - **2 UNPROVEN:** `_git_reported_load`'s `while read` turned into loops that never end once the record exists. The per-test clock stops them.
    - A third, in `_git_exec_keys`, spun on any config file that lists no key; in the corpus that was an empty config.worktree. On one that lists keys, it named none. G98's launch is now bounded, so it ends in a FAIL line instead.
  - **What is left of sandbox.sh:** 1,365 of today's 1,768 default mutants:
    - `launcher_ro_overlay()`: 454;
    - `run_container()`: 318;
    - `git_dirs_in()`: 239;
    - about 30 smaller helpers: 354.
- **Slice 3, measured 2026-11-08:** the path and link walkers and the spelling helpers. They are `_walk_exposed`, `_path_walk`, `_link_walk`, `_readlink_exact`, `_cd_bash`, `_cd_phys`, `_ci_path`, `_disk_spell`, `_spell_rec`, `_canon_lex`, `_lex_link_dir`, `_lex_norm` and `_gref_add`. GIT-41's `_ci_alias_fs` and `_ds_readdir` were left out: they act only on drvfs.
  - **The run:** 182 mutants, `--select-oracles --jobs 10 --timeout 180`, against the 29 tests that execute sandbox.sh (slice 2's 28 and `tests/test-git-internals-ro-casefold.sh`, which ran on a casefold tmpfs in a user namespace), at `7d959f8`. It took 3 h 17 min of wall time. Both controls passed; every kill printed a `FAIL:` line.
  - **Result:** 147 killed, 26 survived, 9 unproven. A survivor ran the whole set, about 1,000 s under that load.
  - **17 survivors are now killed,** each seen failing against its mutant on the final test files, rebased onto `2880376` (GIT-41's last commit) by the line's text:
    - **The `<home>` rule of `_walk_exposed()`** (7): a step inside the launcher whose links are walked, and in none of its own writable binds, is not judged. A launcher with an overlay is read-only either way, so only one left writable shows it: T64 in `tests/test-launcher-dir-ro.sh`, a launcher whose name docker cannot carry, with and without a writable bind inside it (an `EXTRA_MOUNTS` bind when slice 3 was measured; since the LNCH-22 fix, the primary, inside a launcher named `c:o `).
    - **The mount-root rule** (1): only a `..` step out of a mount root or a pin is safe there. T65: a launcher link to the working dir's root is warned about.
    - **`_readlink_exact()`'s failure** (1): T37, with a `readlink` that fails, as for a link removed between the scan and the read.
    - **`_disk_spell()`'s status** (4), which is `_cd_phys`'s, and a caller drops a mount when it fails: G124 in `tests/test-git-internals-ro-casefold.sh` asks twice, with no `pwd`, a failing one and one printing a relative path.
    - **`_lex_link_dir()`** (3): a `gitdir:` in another case inside the project was warned about as reached through a link. G117 now asserts it is not.
    - **Spelling every path** (1): GIT-41 rewrote the line since; its counterpart in the new line is killed by G125 in `tests/test-git-internals-ro-scan.sh`: on a filesystem that heeds case, `AI_CONTAINERS_SPELL_MAX=0` refuses nothing.
  - **8 EQUIVALENT:**
    - **A status no caller reads** (5): `_link_walk` ×2 and `_path_walk` ×3. Every caller reads them through `mapfile < <(…)`, or as `_link_walk`'s last command.
    - **`_ci_path`'s check for a relative path** (1): every caller passes an absolute one (`$PWD`, a walk's records, `find` under a mount root).
    - **The spell budget's refusal** (2):
      - `kill -s USR1 "$$" … && true`: kill's status is read by nothing, and `exit` follows.
      - `exit 1` made `exit 0`: at launch, the kill makes the launcher's `trap 'exit 1' USR1` end it with 1 whatever the subshell exits with. In the rescan after the session, whose trap is `_gas_cut=1`, the kill alone marks the search cut short, and the mount's subshell ends either way.
  - **1 ENV-DEPENDENT:** `_disk_spell`'s return after `_ds_readdir` spelled the path. At `7d959f8` that happened only where a directory ignores case and its kernel does not: drvfs, and Linux filesystems other than ext4, f2fs and tmpfs (vfat, exfat, …). GIT-41 rewrote the line since.
  - **9 UNPROVEN, all loops that never end:** `_cd_bash`'s `//` loop (3), `_ci_path`'s component loop (3), `_spell_rec`'s (2) and `_canon_lex`'s (1). Any test that reaches them hangs, and the per-test clock stops it.
  - **Found on the way:** LNCH-22 (bugs review, section 26): a host path holding `:` cannot be mounted, and the launch fails at docker.
  - **What is left of sandbox.sh:** it now yields 2,373 default mutants. The largest units are `launcher_ro_overlay()` (655), `run_container()` (314) and `git_dirs_in()` (268); the smaller helpers not yet measured come next (`_ro_fifo_search`, the `_fs_*` and `_rd_*` helpers, `container_env_filter`, …).
- **Slice 4, measured 2026-11-08:** the FIFO and hard-link searches, the bounded reads and the env-file filter. They are `_ro_fifo_search`, `_fs_linked_in`, `_fs_other_names`, `_fs_reachable`, `_fs_in_rw`, `_fs_target`, `_fs_ml_drop`, `_rd_run`, `_rd_left`, `_rd_prep`, `_rd_fail`, `_git_ptr_read`, `container_env_filter` and `_checkout_origin_url`.
  - **The run:** 322 mutants, `--select-oracles --jobs 10 --timeout 180`, against the 29 tests that execute sandbox.sh, at `3b98ecd`. It took 5 h 7 min of wall time. Both controls passed.
  - **Result:** 255 killed, 59 survived, 8 unproven.
  - **38 survivors are now killed,** each seen failing against its mutant:
    - **The FIFO search** (`_ro_fifo_search()`): T68 in `tests/test-launcher-dir-ro.sh`, a read-only source that is itself a FIFO or a device (a file a concurrent container swapped); T69, each search's bound (at most 30 s, at most what the launch's 90 s have left) and a search that runs out of time with no writable mount inside the source to prune.
    - **The hard-link check of what git reads by name** (`_ro_fifo_search()`'s second half): T70, its list of files alone (no `hooks/` to search), its bound, a search that runs out of time, no temporary file, and the `find … -samefile` it gives, which searches the widest writable mount that holds the file.
    - **The listing of linked files** (`_fs_linked_in()`): G128 in `tests/test-git-internals-ro-reads.sh`, which lists only the mounts on the file's device, at most 30 s and what the budget has left, keeps every whole line of a listing cut short, and refuses with no temporary directory.
    - **A file reached through a link** (`_fs_reachable()`, `_fs_in_rw()`): G129, which fails closed: a target inside a writable mount, whatever device it is on there, one whose way cannot be followed, and one that cannot be stat'ed all count as reachable.
    - **The bounded reads** (`_rd_prep()`, `_rd_left()`, `_rd_run()`): G130, the count of slow reads is made only in the launcher's own shell; G99, with `ok` gone a read gets the first bound, a counted read keeps the longer one, and a count that is a link, to a file or to nothing, is never written through, one made a link during a slow read included.
    - **The env-file filter** (`container_env_filter()`): E1 in `tests/test-env-file.sh`, a value in UTF-8 that is not ASCII reaches docker. Refusing every such line survived.
  - **21 EQUIVALENT:**
    - **A status no caller reads** (10): `_rd_left` ×3, whose one caller, `_rd_run`, runs with errexit off and reads only `_rd_lim`; `_rd_fail`'s `kill … && true`, run with errexit off too; `_fs_ml_drop`'s `rm -rf … && true`; and `_checkout_origin_url`'s early returns ×5, made `return 0`: its one caller takes its output (`$(…) || true`), and it prints nothing before them.
    - **`|| true` turned `&& true` where the failing command is not the last of its list,** so errexit does not fire and nothing reads the status (5): in `_fs_linked_in`, the placeholder for a spent listing, the cut line's removal (one of its two flips; G128 kills the other), and the `grep` for the answer; in `_checkout_origin_url`, its two `_git_ptr_read`s, after which the value is empty either way.
    - **`(cd / || exit 0`** (1): `cd /` does not fail.
    - **A complete listing's last line** (1): a listing that exits 0 was not cut by `head` (that sets it failed), so it ends in a newline and has no partial line to drop.
    - **A refusal returning 0** (3): `_rd_run` after a read cut off, and `_git_ptr_read` after an odd file and after a `gitdir` ending in a space or tab. Each calls `_rd_fail`, whose USR1 makes the launcher's trap exit 1 whatever the function returns; in the rescan after the session the trap marks the search cut short, which is all a cut read may say there.
    - **`git ls-remote --get-url` taken when it succeeds or prints something** (1): it prints the URL, never nothing, when it succeeds, and nothing on stdout when it fails.
  - **8 UNPROVEN, all loops that never end or reads with no bound:** `container_env_filter`'s whitespace loop, negated (3); `_rd_prep` never initialising, so a planted FIFO blocks a read (2); `_rd_run`'s first bound and its count (3). The per-test clock stops them.
  - **What was left of sandbox.sh:** slice 5, the smaller helpers not yet measured, and then `launcher_ro_overlay()` (655), `run_container()` (314) and `git_dirs_in()` (268).
- **Slice 5, measured 2026-11-08:** the smaller helpers: `_ro_files_restore`, `_ro_files_snapshot`, `_win_fs`, `_win_mounts`, `_win_path`, `_ds_readdir`, `_case_flip`, `_u8_locale`, `_ci_alias_fs`, `_git_push_hooks`, and 35 more (`validate_sandbox_ids`, `seed_workcopy_volume`, `_colima_profile`, `_vm_dev_ino_load`, `repos_path_in_container`, `launcher_dirs_in`, `split_env_list`, `_q`, `_bind_read`, …); four of the 45 yield no mutant (`usage`, `_term`, `_rd`, `normalise_git_url`).
  - **The run:** 464 mutants of 45 functions, `--select-oracles --jobs 10 --timeout 180`, against the 29 tests that execute sandbox.sh, at `3c9e3bb`. It took 10 h 48 min of wall time, the suite and reviews of four fixes running beside it. Both controls passed.
  - **Result:** 308 killed, 139 survived, 17 unproven.
  - **128 survivors are now killed,** each seen failing against its mutant (by applying it to a copy of sandbox.sh and running the test that claims it), mostly by calling the function on its own, under the launcher's `set -euo pipefail`:
    - **The files put back after a session** (`_ro_files_restore()`): G136 in `tests/test-git-internals-ro-reads.sh`, a file unchanged, changed, removed, replaced by a link (to one that holds the same too), by a FIFO and by a directory; a restored directory an earlier launch made, one that is a link, and one that cannot be made; the copy kept at launch gone (an empty file made for it was moved over the git file and said put back), the directory for this restore already there or swapped for a link once made, and a FIFO planted at the name the copy is written to. G127 runs only where a filesystem ignores case; these run everywhere.
    - **What is kept at launch** (`_ro_files_snapshot()`): G141, on a case-sensitive directory with the other spelling made a hard link: a file kept with its mode, a link and a file over 1 MiB named and not kept, a TMPDIR it cannot write in named, the launch going on. It SKIPs where TMPDIR ignores case (macOS's APFS), as G139 does: G127 covers that.
    - **A name turned over in case** (`_case_flip()`, `_u8_locale()`): G137, an ASCII name in place, two with no ASCII letter through a UTF-8 locale under the launcher's C, a repeat from the cache, and with no UTF-8 locale one with an ASCII letter (`Aд`) turned over in it and one WARNING for the others.
    - **Which mounts are Windows's** (`_win_mounts()`, `_win_fs()`, `_win_path()`): G138 on a mountinfo of the test's own, its path swapped into a copy of the functions: optional fields, 9p as drvfs or not, an escaped space, a Linux mount nested in a Windows one (and `_win_path` finding it by its parents), one Windows mount alone (the first pass's `!=` dropped the path's own match), virtiofs on and off a WSL kernel, a Windows mount at `/`, off Linux, and the statfs fallback.
    - **A name spelled as readdir lists it** (`_ds_readdir()`): G139, the directory itself chosen over a link and another spelling, a name with no ASCII letter under a UTF-8 locale, a prefix read once keeping its status.
    - **Where push hooks run** (`_git_push_hooks()`): G140 in `tests/test-git-internals-ro-config.sh`, each directory once, both readings of `:(optional)`, and what is there already named once.
    - **The small helpers:** T72 and T73 in `tests/test-launcher-dir-ro.sh`: a foreign repo volume's prefix line; a group file that links out warning, one inside or unguarded not, none ending the launch; ids not numeric, too large or root, each refused with status 1; `split_env_list` leaving globbing on; a device stat'ed once; an empty option list and another flag being no bind; `_ci_alias_fs` on and off Linux; a working copy made once with the labels it has a value for, an existing one left alone; no colima or no endpoint giving no profile and loading nothing (a load with none recorded every source `0:0`, refusing every launch), a record without numeric ids dropped; a pointer translated only through a bind into `/workspace`; a launcher holding both its files.
  - **4 gone since `3c9e3bb`:** `_win_fs`'s `virtiofs)` arm (3), removed by GIT-47; `_git_walk_keys`'s read (1), rewritten by GIT-42 and GIT-49.
  - **4 EQUIVALENT:**
    - **A status no caller reads** (2): `split_env_list`'s and `_git_walk_keys`'s early returns, made `return 1`; every caller reads them through `< <(…)`.
    - **`_q`'s byte-by-byte branch** (2): `_q` sets `LC_ALL=C`, where `printf %q` escapes every byte past ASCII and every control character, so `_term` never changes what it gives and the branch does not run. Its loop turned, and the plain branch's `return 0` made `return 1` (every caller takes `_q` inside `printf`'s arguments), are the same program.
    - **Not EQUIVALENT after all:** the review of the slice found 7 of the first 11 claimed so killable, and each is killed above: `_case_flip`'s `&&` made `||` (with no UTF-8 locale a name like `Aд` came back unchanged, with a WARNING), `_win_fs`'s first pass (2: with one Windows mount the path's own match was dropped), and 4 in `_ro_files_restore` claimed races (a missing copy, a restore directory already there or swapped, a FIFO at a name made predictable).
  - **3 ENV-DEPENDENT:** `_ro_files_restore`'s `mv -h` fallback, which runs only where `mv -T` does not exist (macOS); GNU's never fails for a file.
  - **17 unproven:** 14 are now killed by G136 and G141 (their oracle's case-folding scaffold failed beside them, so the tier would not count the kill). 3 stay: `_overlay_buildable`'s loop negated never ends, and the per-test clock stops it.
  - **Found on the way:** `_git_push_hooks` takes namerefs beside unprefixed locals, every one of which a caller's array could be named: one named `pre` resolves to the function's own, and its directories come back twice (G140 names its arrays as the launcher's caller does). The launcher's caller (`hgro`, `hgpre`) is not affected.
  - **What is left of sandbox.sh:** `launcher_ro_overlay()` (655 at `3b98ecd`), `run_container()` (314) and `git_dirs_in()` (268), each a slice of its own.
- **Slice 6, measured 2026-11-09 to 2026-11-10:** `git_dirs_in()`, the git-directory scan, alone.
  - **The run:** 268 mutants, `--select-oracles --jobs 10 --timeout 180`, against the 29 tests that execute sandbox.sh, at `7ed3cd9`. It took 8 h 45 min of wall time, with TST-29's fix and its reviews, then GIT-51's and GIT-53's, running beside it. Both controls passed.
  - **Result:** 173 killed, 75 survived, 20 unproven.
  - **64 survivors are now killed,** each seen failing against its mutant (applied to a copy of sandbox.sh, by line, with the test file that claims it run whole):
    - **What the scan takes for a git directory inside a `.git`** (G144 in `tests/test-git-internals-ro-scan.sh`): a `.git`, and a directory in one, that you can read but not search is read-only whole and named, as one you can do neither with is; a directory in `.git/worktrees` with neither `commondir` nor `gitdir`, or elsewhere in `.git` with a `gitdir`, gets nothing made in it; a linked worktree's directory whose `commondir` is a link, with no `HEAD`, is found and the link named; a submodule's git directory with no `HEAD` is protected holding any one of `objects/`, `refs/`, `config`, `hooks/` or `index`, and a plain directory in one is not.
    - **The walk up from a mount** (G145 in `tests/test-git-internals-ro-index.sh`): a `.git` above the mount that is no repository gets nothing made in it; a `.git` file above is followed to its git directory's index, quietly when that index cannot be read outside every writable mount and named inside one; the repository two levels up is read, past a dangling `.git` link; a `.git` link to a directory that is no repository is passed over; the repository above a `.git` link the walk followed is not judged.
    - **A linked worktree's checkout through `gitdir`** (G146): under a pruned `node_modules`; one deleted and never pruned is not read against, so not warned about; one outside every mount that does not point back, or whose `.git` is a link back, leaves the worktree named, since only a regular `.git` file pointing back makes it quiet.
    - **An absorbed submodule's checkout through `core.worktree`** (G147): its `.git` file, reached no other way, is read-only; one `core.worktree` puts outside the mount is not bound, under any name (the mutant bound it at `<mount><host path>`).
    - **The gitlinks an index records** (G148): a `.git` link under a pruned directory is named; a submodule the scan and the index both find is protected, and said so, once.
    - **A git directory waiting for its checkout** (G149): read once the `.git` file naming it turns up through the index of the repository the mount lies in, read after the scan's own; G58 never reached that retry, since `find` queues a repository's `.git` before the module directories inside it.
    - **The refusal past twenty `.git` files** (G57): it names five of them.
    - **A `./` commondir is not followed** (G151): followed, it was named as a git directory in another writable mount, for one in the group's own directories a NOTE that a `.git` file there is not yours.
    - **An empty `core.worktree` in a common config** (G146): it gives a linked worktree no checkout, so the git directory is not read against itself.
    - **Only the checkouts inside the mount are spelled** (G150 in `tests/test-git-internals-ro-casefold.sh`): twenty recorded outside it, spelled too, used up the budget the launch needs six of. It runs where a filesystem ignores case (here a casefold tmpfs in a user namespace) and is skipped elsewhere, CI's runner included, where the mutant survives.
    - **A `gitdir` taken whole, unresolved** (G143): GIT-53 makes a relative one absolute by prefixing the git directory, and only `_cd_phys` resolves the `..`; skipping it queued a checkout spelled with `..`, whose submodule then failed the physical-path check.
  - **11 EQUIVALENT:**
    - **`|| true` made `&& true`** (7), after `_git_ptr_read`, under `set -e`: a failing command that is not the last of an `&&` list does not exit, and nothing reads the status.
    - **A `.git` that reaches the depth check** (1): `find` prints a `.git` only as a file, a link or a directory, and the branches before it take files, links and directories you cannot list, so only a directory reaches the `-d` it turns; and `had` is not yet set for it there, since `find` prints a directory before anything inside it, so no `HEAD` or `commondir` found in it has queued it yet.
    - **Its common config's `core.worktree` read with a `commondir` of `./`, `.` or nothing** (2): it is the git directory's own config, whose `core.worktree` the loop before it added already.
    - **A `gitdir` taken relative** (1): since GIT-53 every value that is not empty is made absolute first, and `-d ""` is false.
  - **20 unproven:** turned, a condition of the scan's own classification or of its queue, or `git_dirs_in`'s final `return 0` made `return 1` (which ends every launch), breaks the tests' own fixtures, whose scaffold then fails beside the kill (11); turned, the loop over a git directory's referrers or the retry of those still waiting (`[[ -n "$gchanged" ]] || break`) runs past the per-test clock (9).
  - **Not EQUIVALENT after all:** the review of this record found 4 of the first 15 claimed so killable (the `./` commondir follow, twice; an empty `core.worktree`; the `gitdir` resolution G143 already killed), and the one claimed ENV-DEPENDENT killable here; each is killed above.
  - **Found on the way:** GIT-51 (MEDIUM, FIXED): what one writable mount's scan found was protected in that mount's view alone. GIT-53 (LOW, FIXED): a linked worktree's relative `gitdir` was not followed. From the reviews of those fixes, GIT-55 and GIT-58 (MEDIUM) and GIT-57 (LOW) are FIXED; GIT-59 and GIT-60 (MEDIUM), GIT-52, GIT-54, GIT-56 and GIT-61 (LOW) were found open and are FIXED since by the WSL native agent (bugs review section 28).
  - **What is left of sandbox.sh:** `launcher_ro_overlay()` (655 mutants at `3b98ecd`) and `run_container()` (314), each a slice of its own.
- **project-files.sh, measured 2026-11-10** (the WSL native agent, taken from the Linux agent's list): the first slice off sandbox.sh, and the target is now active (`tests/falsify/targets.conf`).
  - **The first run:** 269 mutants, `--select-oracles --jobs 4 --timeout 180`, against the four tests that reach it through syncs and inits (`tests/test-sync-no-follow.sh`, `tests/test-init-no-follow.sh`, `tests/test-project-init.sh`, `tests/test-sync-project.sh`): 196 killed, 73 survived, two of the kills with no assertion (a return of 1 where the caller runs under `set -e`). 2 h 50 min, about 150 s of test time a mutant: as an active target with that oracle set, the CI shard that holds it would pass its 90-minute cap.
  - **A dedicated oracle:** `tests/test-project-files.sh` calls the helpers directly, 4 s for the whole file. It covers what the first run left and what the four tests reached only at their cost: a command that fails (`mktemp` made to), a FIFO, a mode, a destination swapped after it was pinned, every way out of `ensure_ai_containers_ignored` returning 0 under its callers' `set -e`, the index read's refusals (a FIFO, a corrupt index, a slow read, a sparse index read in part and one that lists the copy, a split index part that is a FIFO, a git directory that can be read but not searched, an object format git does not know), the global excludes as git takes them, and the `.gitignore` edits (no blank line, no lost final newline, a complete one not rewritten). Alone it kills 242 of 269, with no assertionless kill, in 8 min at `--jobs 4`. Each check added for a survivor was seen failing against its mutant.
  - **27 left, in survivors.txt section 27** (22 identities): 21 ENV-DEPENDENT, the branches only macOS's fdescfs takes (`_proj_fd_is`'s inode comparison, `_proj_fd_perms` by name, `_proj_write`'s chmod by name) and BSD's `mv -h` in `_proj_replace`; 5 GAP, checks against a name swapped between two calls, which no hermetic test can place without a hook; 1 EQUIVALENT, `|| true` made `&& true` after a read to end of input.
  - **CI cost:** about 8 min more on the shard that runs every target but `repo-git-reset.sh`, which took 69 min on PR #338.
- **Slice 7, measured 2026-11-10 to 2026-11-11:** `launcher_ro_overlay()`, the overlay pass, alone.
  - **The run:** 817 mutants, `--select-oracles --jobs 10 --timeout 180`, against the 29 tests that execute sandbox.sh, at `4860249`. It took 24 hours of wall time, with the GIT-59 fixes (`f3a74e1`) landing and four batches of tests written beside it. Both controls passed. The function gained about 75 lines between `4860249` and `f3a74e1`, so each survivor was mapped onto main's sandbox.sh by its text before a test was written for it.
  - **Result:** 601 killed, 123 survived, 93 unproven.
  - **97 survivors are now killed,** each seen failing against its mutant (applied by line to a copy of main's sandbox.sh, with the test file that claims it run whole):
    - **The launcher overlay** (`tests/test-launcher-dir-ro.sh`): T22 names the real path to launch from; T26's refused launch exits non-zero; T76: a launcher deeper than the scan, or under `node_modules`, is overlaid and its link warned about once, one nested in another stays under the outer `:ro` with no `:rw` pin, an unrepresentable name is warned about once, a renamed launcher at a mount root gets the NOTE, and a `.git` link under an overlaid launcher is not named; T77 pins the `SANDBOX_LAUNCHER_MAX` listing; T46: a launcher reached past the shared 200-link budget is named without being searched.
    - **The protection loop** (`tests/test-git-internals-ro-scan.sh`): G158, the exact `SANDBOX_GIT_MAX` listing, "(at …)" included; G159, a `HEAD`, `config` or `hooks` of the wrong type refused with the right remedy; G160, a `commondir` in a module's git directory refused, a worktree's `./` remade and bound, a foreign one bound; G161, a hard-linked `.git` file or hook under a launcher overlay refused; G163, a group directory linked out of the group scanned; G1, no "could not be made" warning for a plain repository; G165, what a `commondir` leading back to its own `.git` draws today (GIT-64).
    - **Targets in other mounts** (`tests/test-git-internals-ro-index.sh`): G162, a worktree's `commondir` targets, one WARNING for one that is no git directory, a FIFO `commondir` refused; G164, a target under the other mount's launcher overlay not named, one docker cannot be handed named, with no count of more; G51, a group directory's NOTE with no count of more.
    - **The config walk** (`tests/test-git-internals-ro-config.sh`): G132's push-hooks sentence; G25, a protected config that is a link named, its includes not walked through it, and not called overlaid; G29, a loop back to the config itself, and git's depth of ten; G126, exactly `SANDBOX_GIT_MAX` git directories judged outside every mount; G135, entries after a long key still read, and the walk of a file cut past 1000 of them; G120: a `core.worktree` past a cut walk is still a base, from `config` and from `config.worktree`; a relative `core.hooksPath` is judged from where the `.git` lies, never from the root; a `gitdir` file in a repository's own git directory is no checkout to judge from; two values leading to one directory walk it once; an `:(optional)` value naming `hooks/` walks it once, and its link is named with what to do about a link; a linked worktree's checkout, named by its `.git` file and by its `gitdir`, is one base, and an `:(optional)` value's plain reading is judged once — each spends the walk budget once, at its last way (994 include entries pass, 995 are cut, from a project and a group of the check's own).
    - **Where a directory ignores case** (`tests/test-git-internals-ro-casefold.sh`): G117, a `core.hooksPath` directory two repositories name in two cases is walked once, known by device and inode; G121, where a directory ignores case and its kernel does not, and it is no Windows filesystem, a launch that needs a read-only bind there is refused. No test reached that branch on any platform: G121's other cases run on WSL's drvfs, which takes the Windows branch. Here the casefold tmpfs ignores case, and a `stat` that reports a FUSE share for it stands in for such a share, on Linux only. These eight kills (G117's and G121's) need that file to run them: Linux 6.13 or later with unprivileged user namespaces, or a `TMPDIR` whose kernel ignores case (macOS: G117's kill only; not WSL's drvfs, where the file runs G121's Windows cases instead). It is skipped on CI's runner and in the floor container, where the eight survive, so once sandbox.sh is an active target they need `ENV-DEPENDENT:` entries.
  - **19 EQUIVALENT:**
    - **`|| true` made `&& true`** (7), under `set -e`: a failing command that is not the last of an `&&` list does not exit, and nothing reads the status.
    - **Unreachable** (6): `validate_sandbox_ids` runs first in `run_container()` and refuses every identity these checks of `SANDBOX_UID` and `SANDBOX_GID` would.
    - **Every flag pair the launch passes is `-v` or `--mount`** (1).
    - **Making a name that exists** (3): turned, an existing `config`, `hooks` or `commondir`, a link included, is made again; the exclusive create or `mkdir` fails on it, and `_git_cant_make` returns 0 for a name that exists.
    - **An empty `commondir` and the `./` placeholder** (1): both resolve to the git directory itself, whose `config` is read either way, and which is not judged twice: the loop marked it (`pgk`) when it took it, before reading its `commondir`.
    - **A regular hook in a repository's own `hooks/`** (1): it lies under that directory's read-only bind, and one with a second name refuses the launch before the walk (GIT-31).
  - **1 ENV-DEPENDENT:** the Windows branch's refusal made to exit 0. It runs only where Windows looks names up, and G121 should kill it there (WSL's drvfs; not yet run there, platform-issues' WSL agent row); `_win_fs` reads `/proc/self/mountinfo`, which no hermetic test can make name a Windows mount.
  - **6 GAP, tied to open bugs:** GIT-62 (5: a `commondir` that is a link switches the protection off), GIT-65 (1: a common directory past a mount's scan that an outside worktree names).
  - **93 unproven:**
    - **83 a fixture failed beside the kill:** a condition turned that breaks nearly every launch (the identity checks, the reading of the launch's own binds, the overlay's limits, the protection loop's classification, the binds made for it, the GIT-41 refusal turned on for every filesystem) failed assertions across the set, and two fixtures with them. G133's helper in `tests/test-git-internals-ro-config.sh` printed `SCAFFOLD-FAILED` when the first launch failed or made no `commondir`, the launch's doing; G127's sessions in `tests/test-git-internals-ro-casefold.sh` left a `commondir` naming `../planted` when the launch did not put it back, and `git worktree add` then failed. G133 now FAILs and skips its checks, as G108 does, and G127 puts the repository back. Every one of the 83, run against both files with the final tests (by hand where main's code moved: the read-only bind test is now an `if` of several lines), ends in FAIL lines in at least one of them and in no fixture failure in either: 138 in the config test where nothing is protected. The next measurement shows whether another file of the set adds one.
    - **10 past the per-test clock:** the overlay's depth loop with its bound turned (1), and a walk over a path's components that no longer shortens it (9).
  - **Found on the way:** GIT-62 and GIT-64 (MEDIUM), GIT-63 and GIT-65 (LOW), and, by the review of the fourth batch, TST-34 (LOW, test only), all fixed 2026-11-11 by the WSL native agent (bugs review section 29). The GAP tied to GIT-65, slice 7's mutant 498 on the GIT-44 loop's `! _in_writable "$ocd"`, is to be classified again by the next measurement: a common directory in a writable mount is now protected by the scan's follow (`_gdi_out_cd()`), and that loop's condition, unchanged, decides only whether such a directory is also judged as one outside every mount. G168 kills none of the three forms tried by hand (the `!` dropped, the term dropped, the first `&&` made `||`), so it is likely EQUIVALENT now, no longer a GAP tied to an open bug.
  - **What is left of sandbox.sh:** `run_container()` (314 mutants at `3b98ecd`).

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
- Status: PARTIAL. Since 2026-11-05 `tests/run-all.sh` also shows up to five lines a test printed above its `SCAFFOLD-FAILED:` marker. For F58 that is still only the symptom: both derivations that came back empty discard git's own error (`git ls-files '*.sh' 2>/dev/null` in `tests/test-bash-floor.sh`, and `git ls-files -z 2>/dev/null` in `tests/falsify/run.sh: falsify_seed_tree()`). Keeping it is the step before the next sighting can name a cause.
- Fix batch: separate track
- Source: falsify backlog F58: "GUARD FIXED; the TRIGGER is still unidentified"
- Area: tests/CI
- Current state at HEAD: the guard (one derivation, reported as `SCAFFOLD-FAILED`) is in place, and test-lint-empty-corpus.sh covers its siblings. The cause was never found. F64 later found a trap in a forked child deleting the scratch directory, which may be the same mechanism, but no one checked.
- What's missing: confirming or ruling out the F64 mechanism for F58.
- Value / priority: LOW. The harm is contained.
- Suggested approach: when it next happens, check whether F64's `dir=n` diagnostic fires; if so, close F58 as a duplicate of F64.
- **2026-11-09 (WSL agent):** one cause of the same symptom class found, not F58's own: from a WSL checkout under `/mnt/c`, the directory the tests inherit from `tests/run-all.sh` went stale during a long run, and a git that cannot read its working directory prints nothing on stdout, so `git ls-files 2>/dev/null` comes back empty (docs/testing.md, the drvfs flake). The runner now enters its directory again before each test. F58's sightings were in CI, on ext4, where that mechanism has not been seen, so this stays PARTIAL.

### GAP-11: The launcher-mount swap check is skipped on macOS Docker Desktop and Colima
- Status: DONE ON COLIMA (2026-11-08); Docker Desktop for Mac stays unprotected and unmeasured. The nonce suggested below does not work, because the swapping container can read and copy it. On Colima, `sandbox.sh` now records each source's device:inode as Colima's VM reports it, and the entrypoint checks as on Linux; see PLAT-3's Status.
- Picked up by: the **Mac agent** (macOS, Docker Desktop and/or Colima), as PLAT-3
- Fix batch: platform log — PLAT-3 in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md) (needs that platform to run)
- Source: AGENTS.md mount layout: "if its own `device:inode` does not survive the bind (a file-sharing layer such as macOS Docker Desktop or Colima), verification is skipped with a one-line `NOTE:`"
- Area: launcher/mounts
- Current state at HEAD: `verify_launcher_mounts()` works on Linux; case 460 checks whichever host it runs on. On macOS the swap race (a concurrent container replacing an overlay source with a symlink) goes unchecked.
- What's missing: protection for macOS, the platform with the most users.
- Value / priority: MEDIUM. It is a security property that silently does not apply on one platform, though exploiting it needs a concurrent container on an overlapping writable tree.
- Suggested approach: on hosts where inodes do not survive the bind, compare a per-launch nonce file written into each overlay source instead of `device:inode`.

### GAP-12: Known holes in the git-internals protection
- Status: DONE (2026-11-03). Both remaining holes, test-first in test-git-internals-ro.sh (now `tests/test-git-internals-ro-reports.sh`). **G93:** a repository whose `./` placeholder was already there (an earlier engine's, or planted with a repository the agent made) gets its keys and hooks named once. A host record, `~/.ai-containers/git-reported.conf`, holds one `<device inode birth-time> <path>` line per reported repository, written after the NOTE. **G94:** when `docker run` returns, `_git_after_session()` rescans the writable mounts the launch scanned, each in a subshell of its own (`git_dirs_in` refuses by exiting), with index reads made afresh and a 30 s deadline. It names each git directory new by identity whose config or hooks make git run something (`_git_runs()`, shared with the first-protection NOTE; a `commondir` or `hooks/` link included) or that cannot be listed, and, separately, each new `.git` file or link. A plain init or clone is not named. A search cut short (a refusal, `SANDBOX_GIT_MAX`, a read past its bound, the deadline) says so instead of refusing, and the container's exit status is kept. Its review (an Opus reviewer and the automated security review) found the refusal by exit lost silently, the launch's cached index reads reused, a `hooks/` or `commondir` link not judged, no deadline, the record written before the NOTE and keyed by path alone; all fixed, each with a check seen failing first except the record's order, which needs a read cut off inside `_git_runs()`. Not warned, by nature: a repository made while the container runs (until it exits), a launcher killed before the rescan, a sibling container's repository made after this one exits, and one where the launch scan does not look either.
- Fix batch: 1 — git internals, for following includes inside included files only; the post-launch `.git` warning and the exec-key report for earlier-protected repos are a separate track
- Source: AGENTS.md: "**Not covered**: configuration poisoned **before** this protection existed …; a file that an included file includes in turn; and a `.git` the agent **creates** in a subdirectory"
- Area: launcher/mounts
- Current state at HEAD: these are documented. The first protected launch names the exec keys (`_git_exec_keys()`) and the existing hooks, and a non-`./` `commondir` refuses the launch.
- Batch 1 (`b3d2362`): nested includes are now followed (test G29), and the config reads can no longer be silenced by an include loop (G30). Still missing below: protection, or at least a warning on the next launch, for a `.git` the agent created after the scan; and an exec-key report for repositories an earlier engine protected (the record says those "get no list").
- Value / priority: MEDIUM. The host's git runs whatever these files hold.
- Suggested approach: walk includes recursively with a depth bound (git's own limit is 10). On exit, rescan the writable mounts for git directories that are new since launch and print a `WARNING:` naming them.

### GAP-13: WSL2 has never been run
- Status: DONE (2026-11-04). Docker Desktop + WSL2 was run on 2026-10-26, and re-run at `037e64c` as PLAT-6. A Docker Engine installed natively in the distro was run on 2026-11-04 at `f0ad913`, on an Azure Windows VM: every phase of `verify-on-host.sh` from ext4, and Phases 5, 7 and 4 from `/mnt/c`, all passed, with the integration corpus 50/50 and none skipped. Both are in docs/testing.md, "Platforms exercised", and PLAT-2's Status.
- Picked up by: the **WSL agent** (Windows + WSL2 + Docker Desktop; **not** a native Engine), as PLAT-6. The native-Engine half was the user's, run on an Azure VM (PLAT-2).
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
