# Feature-gaps review — 2026-11-17

- **Review date:** 2026-11-17
- **Last reviewed commit:** `104fcc8` (`104fcc8f5db456c1aef4bb11737da4f30c056c8c`, main, 2026-11-16)
- **Scope:** the window `bec1c57..104fcc8` (since the [2026-10-26 review](2026-10-26-feature-gaps-review.md)): every design, plan and backlog written or changed in it, the docs' promises, and the tests the code changed in it needs. Found by the same seven reviewers as the companion bugs review; GAP-1 to GAP-14 are known and not repeated.
- **Companion:** [2026-11-17-bugs-review.md](2026-11-17-bugs-review.md), which holds the method, the numbering and each reviewer's coverage.
- **A gap** is something promised, or needed to keep a promise, that is not there at the reviewed commit: a design or doc claim the code lacks, a test that cannot fail, a behaviour that matters with no test. Most here are the missing test of a bug in the companion log, named in the entry.
- **Who picks up what:** assigned 2026-11-17 in the "Who picks up what" table of [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md), each gap with the bugs of its area.

## Summary

15 gaps, by the priority each reviewer gave:

| ID | Area | Priority | Gap |
|---|---|---|---|
| GAP-15 | GIT | MEDIUM | a rebase the session leaves stopped runs `exec` lines on the host at `git rebase --continue`, and nothing names it |
| GAP-16 | GIT | LOW | git-lfs keys that run a program are not among the keys named or judged |
| GAP-17 | LNCH | MEDIUM | nothing tests what the launcher reads from inside a group directory the agent writes |
| GAP-18 | LNCH | LOW | the case/Windows refusal is not tested against the host paths LNCH-27 added to the verify list |
| GAP-19 | PRJ | MEDIUM | no test interrupts `mv` after the checked copy has landed |
| GAP-20 | PRJ | LOW | `prj_running()` is asserted only against a fake that reports host paths |
| GAP-21 | REPO | MEDIUM | nothing tests that `inspect` leaves a nested `.git` unread |
| GAP-22 | REPO | LOW | `repo.sh reset`'s STALE path has no test |
| GAP-23 | REPO | MEDIUM | no test pins what `reset` and `sync` do with a detached HEAD's commits or with `.git/modules` |
| GAP-24 | RT | HIGH | no test puts a link, or a stale file, where a root daemon writes its output |
| GAP-25 | TST | LOW | the code-citation lint checks one of the three spellings in use; about 350 citations are never looked at |
| GAP-26 | TST | LOW | a handful of "nothing is named / nothing is mounted" checks pass when their launch is refused outright |
| GAP-27 | TST | LOW | the weekly nvm bump PR is opened with `GITHUB_TOKEN`, so no `pull_request` workflow runs on it |
| GAP-28 | DOC | LOW | project.sh was to be an active falsify target; it is DEFERRED and its spec says IMPLEMENTED |
| GAP-29 | DOC | LOW | `REPO_HELPER_MEMORY` is documented only in AGENTS.md |

---

## 1. Host-side launcher: git internals

### GAP-15: a rebase the session leaves stopped runs `exec` lines on the host at `git rebase --continue`, and nothing names it
- Status: OPEN (filed 2026-11-17).
- **Area:** git internals, the launch scan and `_git_after_session()`
- **Source:** AGENTS.md: "the **host's** git runs what a repository's `.git` holds … and nothing under `.git/` shows in `git status` or `git diff`", and "Objects, refs and the index stay writable: commit, branch, push, rebase and stash work". The "Not covered" list does not mention sequencer state.
- **Current state:** `.git/rebase-merge/git-rebase-todo` (and `.git/sequencer/todo`) are writable, and an `exec <command>` line there is run by the host's `git rebase --continue`. `git status` on the host says a rebase is in progress and lists only the next two commands, so an `exec` placed third or later is not shown. Reproduced: in a session, `GIT_SEQUENCE_EDITOR="sed -i 1s/^pick/edit/" git rebase -i HEAD~3`, then `printf 'exec echo RAN > %s/ran\n' "$T" >> .git/rebase-merge/git-rebase-todo`; the launcher says nothing after the session or at the next launch; `git status` shows two `pick` lines; `git rebase --continue` on the host creates the file. `repo-git-reset.sh`'s `pull` already refuses these states (`rebase-merge/`, `sequencer/`, …) for volumes.
- **Value / priority:** MEDIUM. Host code execution from a file under `.git` that `git status` does not show, after an ordinary step (finishing a rebase the agent said it left for you). It needs the user to continue rather than abort.
- **Suggested approach:** when `docker run` returns (and at launch), name in a `WARNING:` every protected git directory that holds `rebase-merge/`, `rebase-apply/` or `sequencer/`, and say whether its todo holds an `exec` (or `x`) line; add the limit to AGENTS.md's "Not covered".

### GAP-16: git-lfs keys that run a program are not among the keys named or judged
- Status: OPEN (filed 2026-11-17).
- **Area:** `_git_prog_keys` (`_git_exec_keys()`, `_git_runs()`, the program check)
- **Source:** AGENTS.md: the first protection "names, once, the keys its config already sets that make git run a program", and the check after a session names a new repository "whose config or hooks make git run something. A plain `git init` or clone is not named."
- **Current state:** the list covers git's own keys (and `guitool`, `instaweb`, `sendemail`, p4 hooks) but not git-lfs's `lfs.customtransfer.<name>.path` (with `lfs.standalonetransferagent` / `lfs.<url>.standalonetransferagent`), which git-lfs reads from the repository's config and runs as the transfer program whenever a smudge has to fetch an object (checkout, pull, stash, restore) on a host where `git lfs install` put the lfs filter in the global config. A repository the session makes with those keys is "plain" to `_git_after_session()`, and the first protection lists nothing. Not run here: git-lfs is not installed on this host; from git-lfs's documented custom-transfer configuration. PLAUSIBLE.
- **Value / priority:** LOW. A third-party tool, but a very common one, and its smudge runs on ordinary git commands.
- **Suggested approach:** add `lfs\.customtransfer\..+\.(path|args)` and `lfs\.(.+\.)?standalonetransferagent` to `_git_prog_keys`, the `path` one judged as a whole path like `gpg.program`.


---

## 2. Host-side launcher: mounts, binds and the verify manifest

### GAP-17: nothing tests what the launcher reads from inside a group directory the agent writes
- Status: OPEN (filed 2026-11-17).
- **Area:** LNCH (group mounts)
- **Source:** AGENTS.md, "Host directory mounts": "so a sandboxed agent never writes to the
  developer's real host config", and the feature-gaps review's slice for
  `tests/test-tool-config-mounts.sh`: "`COPILOT_GITHUB_TOKEN` comes from the group's `gh`
  login when Copilot is on and none is set … (5)".
- **Current state:** the five assertions use a regular `hosts.yml`. None makes it a link, a
  FIFO or unreadable, so LNCH-29 passes the suite. It is the one file the host launcher
  reads from inside a mounted group directory.
- **Value / priority:** MEDIUM: it is the path by which a host credential crosses the group
  boundary.
- **Suggested approach:** with the fix for LNCH-29, add the link, the mode-000 and the
  non-regular-file cases, each asserting no `COPILOT_GITHUB_TOKEN` and rc 0.

### GAP-18: the case/Windows refusal is not tested against the host paths LNCH-27 added to the verify list
- Status: OPEN (filed 2026-11-17).
- **Area:** LNCH (verify manifest)
- **Source:** AGENTS.md, "Mount layout": "a launch that needs any overlay, pin or file bind
  below a writable mount root is refused".
- **Current state:** T90 asserts that every mounted host path is in the manifest; T62, T63
  and G121 to G123 assert the refusal for overlays. No test launches with a host path inside
  a writable mount where `_win_fs` or `_ci_alias_fs` holds, which is LNCH-30.
- **Value / priority:** LOW.
- **Suggested approach:** a T-case that overrides `_win_fs` for one scratch directory (as T63
  does for `_disk_spell`) and expects rc 0 for a nested pointer with nothing to protect.

---

## 3. Host lifecycle scripts

### GAP-19: no test interrupts `mv` after the checked copy has landed
- Status: OPEN (filed 2026-11-17).
- **Area:** PRJ / tests
- **Source:** `docs/multiple-projects.md`: "An interrupt (Ctrl-C) before the old copies start to go removes the copies made so far; the old ones are untouched, and running `mv` again starts over."; `tests/test-project-tool.sh` has `FAKE_CP_TERM` (during `cp`) and `FAKE_RUN_TERM` (during a volume copy) only.
- **Current state:** the window between the rename of the checked copy and the end of the old directory's removal is untested, and behaves as PRJ-12 describes.
- **Value / priority:** MEDIUM: it is the one point where `mv` has two setups on disk.
- **Suggested approach:** a fake `rm` that signals the caller on the old `.ai-containers`, asserting the state and that a re-run finishes.

### GAP-20: `prj_running()` is asserted only against a fake that reports host paths
- Status: OPEN (filed 2026-11-17).
- **Area:** PRJ / tests
- **Source:** design: "Tests … an integration case for what needs a real daemon"; `tests/integration/cases/650-project-mv-moves-workcopy.sh` is the only case that names `project.sh`, and it covers the volume copy.
- **Current state:** nothing runs `rm` or `mv` against a real running container, so what a real daemon reports for mount sources (PRJ-17) is unobserved on every platform.
- **Value / priority:** LOW to MEDIUM: the refusal is what keeps `rm` from deleting a live setup.
- **Suggested approach:** an integration case that launches through `sandbox.sh`, runs `project.sh rm <root> --yes` with `IMAGE_NAME` unset in the project's files, and expects the refusal.

Checked and found sound (no finding): the registry edits (`_prj_edit()`, `_prj_rewrite()`: other bytes kept, a link refused, failed writes leave the file); `_prj_guard()` (HOME, `~/.ai-containers`, the engine, a linked `.ai-containers`); `rm`'s order and re-run after each failure point; `mv`'s re-run after a failure at steps 3 to 6 and after a same-filesystem interrupt; the copy check and undo in `prj_copy_volume()`; a pre-existing target volume refused unless an exact, labelled copy; `gc`'s keeps (maybe-unmounted, in use, other owner, unlabelled and unknown) and that nothing is removed that was not listed; `prj_copy_risk()` never reading "could not check" as safe (detached HEAD, cut-short inspection, stale remote, missing base); the label table against a comma, quote or newline in a launch directory; `prj_add_mount()`'s read-back; no-follow writes in `sync-to-projects.sh`, `project-init.sh` and `migrate-runme.sh` through `_proj_read()`/`_proj_write()`; functions ending in an `&&` list under `set -e` (all are called in conditions).

---

## 4. Repo volumes, env layers, version and build

### GAP-21: nothing tests that `inspect` leaves a nested `.git` unread
- Status: OPEN (filed 2026-11-17).
- **Area:** repo
- **Source:** AGENTS.md, "Manage shared repo volumes": "`reset`, which deletes such a repository anyway, lists each in its confirmation (`NESTED|` records) and removes it with `rm -rf` before any git runs"; `repo-git-reset.sh` header: "so git never reads one"
- **Current state:** `tests/test-repo-git-reset.sh` plants the gitlink-and-FIFO fixture for `reset` only (the block after "remote has a gitlink at sub, checkout reads sub/.git"). The WORKTREE tests (section 1c) run `inspect` on volumes with no nested `.git`. REPO-19 passed the whole file.
- **Value / priority:** MEDIUM: it is the one property the REPO-5 design rests on, and a feature added afterwards broke it unnoticed.
- **Suggested approach:** run that fixture through `inspect` under `p_timeout`, with the FIFO writer, and require `WORKTREE|?` and `END|inspect` before the writer opens the FIFO.

### GAP-22: `repo.sh reset`'s STALE path has no test
- Status: OPEN (filed 2026-11-17).
- **Area:** repo
- **Source:** `docs/repos-and-mounts.md`: "leaves the repo **untouched**, with the reason in the summary (`STALE`)"; AGENTS.md: "when the recorded URL cannot be cloned, `inspect` reports `STALE`, names no primary and counts nothing, and the repo is left untouched"
- **Current state:** `tests/test-repo-git-reset.sh` asserts the helper's `STALE|` record. `tests/test-repo-destructive.sh` has no fake helper that prints one (`grep STALE` finds nothing there), so the summary text, the "LOCAL reset" warning, the removal of working copies and the exit status of REPO-22 are unasserted.
- **Value / priority:** LOW: one fake-helper case.
- **Suggested approach:** a fake `docker run` printing `STALE|x` and `END|inspect`; assert the summary names the reason, no `volume rm` is logged, and the status is non-zero.

### GAP-23: no test pins what `reset` and `sync` do with a detached HEAD's commits or with `.git/modules`
- Status: OPEN (filed 2026-11-17).
- **Area:** repo
- **Source:** `repo-git-reset.sh` usage: "pull … Refused when … anything would be lost" (header: "refused if anything would be lost"); AGENTS.md's list of what `sync` refuses and what `reset` lists
- **Current state:** the detached-HEAD tests assert only `WORKTREE|?` and the no-remote, no-primary case; no fixture has a `.git/modules` directory. REPO-20 and REPO-21 pass the suite.
- **Value / priority:** MEDIUM: both are losses of committed work.
- **Suggested approach:** two fixtures with real git, as the file already builds them: assert the refusal (sync) and the at-risk record (inspect), and that the commit is still readable after a refused sync.

---

## 5. Container-start runtime and the capture daemons

### GAP-24: no test puts a link, or a stale file, where a root daemon writes its output
- Status: OPEN (filed 2026-11-17).
- **Area:** RT (capture daemons)
- **Source:** `capture-blocked-traffic.sh`'s header: "Internal state … is stored under a root-only directory … so the sandbox user cannot tamper with the self-healing lookup tables"; docs/security.md item 5, "This cannot be exploited by the sandbox user".
- **Current state:** `tests/test-blocked-capture.sh` pins what self-healing decides from a given DNS feed, never where the feed may come from, and no scenario has an output file that is a link. `tests/test-capture-destinations.sh` (C2) asserts that a pid file with a live pid means "already running", which is the behaviour RT-15 abuses. No integration case writes into `.agent-blocked` from the agent's side and then checks the allowlist or the ipset.
- **Value / priority:** HIGH. These are the two daemons that hold root and NET_ADMIN for the whole session, and RT-13 and RT-14 both went unseen.
- **Suggested approach:** hermetic cases with each output path a link to a sentinel file that must stay unchanged; an integration case (`security`, `needs-netadmin`) that plants the link as the agent, triggers a block, waits one refresh and asserts the address is still dropped; one that forges a response for an allowlisted name and asserts no `ipset add`.

---

## 6. Test harness and CI

### GAP-25: the code-citation lint checks one of the three spellings in use; about 350 citations are never looked at
- Status: OPEN (filed 2026-11-17).
- **Area:** TST (`tests/test-code-references.sh`)
- **Source:** AGENTS.md, "Citing code": "`tests/test-code-references.sh` checks that every such snippet still occurs in the file it names."
- **Current state:** `ref_check()`'s `cite_re` matches only a bare file name followed by `: ` and a backticked snippet. Two other spellings are common, AGENTS.md's own among them, and match nothing. One has file and snippet inside one pair of backticks, as in `sandbox.sh: _pointer_missing()` or `entrypoint.sh: as_sandbox_user()`: about 310 in the scanned files. The other backticks the file on its own, as in `sandbox.sh`: `repos_path_in_container()`: about 37. A function renamed tomorrow leaves those citations stale and the test green. None is stale today: I resolved every one of both forms against the tree, and the only misses were quoted error messages, which are not citations.
- **Value / priority:** LOW. The guard exists because 21 of about 55 references had rotted; most of today's citations sit outside it.
- **Suggested approach:** teach `cite_re` the two other forms (same resolution, same `grep -qF`), with fixture lines for each; treat a snippet that names no tracked file as prose, as the numbered rule already does.

### GAP-26: a handful of "nothing is named / nothing is mounted" checks pass when their launch is refused outright
- Status: OPEN (filed 2026-11-17).
- **Area:** TST (git-internals and launcher tests)
- **Source:** AGENTS.md, "Every case must have been seen failing"; the brief's "a fixture that never reaches the code path its name claims".
- **Current state:** `launch()` leaves an empty mount list and only an `ERROR:` in `$ERR` when the launcher refuses, and these checks assert only absences, with no `LAUNCH_RC` and no positive check on the same launch:
  - `tests/test-git-internals-ro-scan.sh`: "G11 a stray HEAD file is not taken for a git directory", "G18 a repository inside another's read-only hooks/ is left under it", "G63 removed, deinit'd and outside-worktree git directories do not warn".
  - `tests/test-git-internals-ro-config.sh`: "G72 empty include entries in planted repositories do not cut the walk of yours".
  - `tests/test-git-internals-ro-index.sh`: "G47 a target the other mount's own scan protects is not named".
  - `tests/test-git-internals-ro-casefold.sh`: "G117 the group's directories are not scanned with HOME written in another case", "G117 a worktree outside the mounts, its gitdir in another case, is known".
  - `tests/test-launcher-dir-ro.sh`: "T38 a link planted in the launcher's output directory is not walked".

  Today they do reach their code: the three scan launches exit 0 with mounts captured (instrumented run), and G72 goes red under a planted mutant. The other four were read, not run. The gap is that a later change which makes any of these fixtures refuse (a new refusal rule is the common kind of change here) turns the check into one that cannot fail, silently. For the mutation tier, a mutant that makes the launch die is still caught by neighbouring checks.
- **Value / priority:** LOW.
- **Suggested approach:** add `[[ "$LAUNCH_RC" == 0 ]] &&` to each, as the neighbouring checks have. A lint in the style of `tests/test-grep-q-pipelines.sh` could refuse a check whose every conjunct is negated.

### GAP-27: the weekly nvm bump PR is opened with `GITHUB_TOKEN`, so no `pull_request` workflow runs on it
- Status: OPEN (filed 2026-11-17).
- **Area:** CI (`.github/workflows/update-nvm-version.yml`)
- **Source:** AGENTS.md, "Execution layers": the PR layer is "every pull request … blocks merge".
- **Current state:** the PR is created by `peter-evans/create-pull-request` with `token: ${{ secrets.GITHUB_TOKEN }}`. GitHub starts no workflow run for events caused by that token (other than `workflow_dispatch` and `repository_dispatch`), so `tests.yml` and `integration.yml` do not run on the one PR that changes the Dockerfile's nvm pin. Either it shows no checks and is merged unverified (the first real run is the push to main), or required checks keep it unmergeable until someone closes and reopens it. PLAUSIBLE: this is GitHub's documented behaviour; I could not look at this repository's PR history or branch protection.
- **Value / priority:** LOW. A broken nvm release would first show on main.
- **Suggested approach:** create the PR with a fine-grained PAT or a GitHub App token, or have the job start the two workflows on the branch by `workflow_dispatch` after opening the PR. One PR's check list would confirm which case applies.

---

## 7. Designs, plans and docs

### GAP-28: project.sh was to be an active falsify target; it is DEFERRED and its spec says IMPLEMENTED
- Status: OPEN (filed 2026-11-17).
- **Area:** tests / falsify
- **Source:** docs/superpowers/specs/2026-11-14-project-tool-design.md, Constraints: "`project.sh` registered as a falsify target"; docs/superpowers/plans/2026-11-14-project-tool.md, Task 8: "Modify: `tests/falsify/targets.conf` (active row `project.sh|EXECUTED-WHOLE|test-project-tool.sh`)", "Expected: no unledgered survivor". The spec's status line reads "IMPLEMENTED 2026-11-15" and lists its amendments, this one not among them.
- **Current state:** tests/falsify/targets.conf: `#DEFERRED|project.sh|EXECUTED-WHOLE|test-project-tool.sh|-|scored once 2026-11-15 at 37fd86b … 1129 mutants, 800 killed, 6 survived … 323 unproven (oracle timeouts under load, not verdicts)`. So CI never scores a 2300-line tool whose commands delete directories, images and volumes; 29% of its mutants have no verdict at all, and the fixes made after `37fd86b` (`7733768` and later: owner labels in mv, the shell's `EXTRA_MOUNTS`/`REPOS`) were never scored. The row states the reason, so it is not hidden, but neither the spec, the plan nor the feature-gaps review records it as owed (GAP-2 covers the files deferred at the time of that review, not this one).
- **Value / priority:** LOW to MEDIUM. The anti-goals of the spec ("removes anything it did not list first", "removes a working copy without having named it as at risk") are exactly what a surviving mutant in `cmd_rm()`/`cmd_gc()` would break.
- **Suggested approach:** split tests/test-project-tool.sh by command (rm, mv, gc, plumbing) so each oracle fits a shard, activate the row per `--target` shard as `repo-git-reset.sh` has, and note the deferral in the spec's status line until then.

### GAP-29: `REPO_HELPER_MEMORY` is documented only in AGENTS.md
- Status: OPEN (filed 2026-11-17).
- **Area:** docs / repo.sh
- **Source:** docs/reviews/2026-10-26-bugs-review.md, REPO-7: "Status: FIXED (batch 4) … `REPO_HELPER_MEMORY` validated, documented and machine-only"; docs/multiple-projects.md says `sandbox.env` may set only the launcher's own variables, "those in configuration.md".
- **Current state:** the variable is in AGENTS.md's table and in repo.sh: `git_helper_run()` (default `4g`), and in no user doc: `grep -rn REPO_HELPER_MEMORY docs/*.md docs/components README.md` prints nothing. It is the only row of AGENTS.md's variable table missing from docs/configuration.md (diffed by script). A user learns of it only from the out-of-memory error text.
- **Value / priority:** LOW.
- **Suggested approach:** add the row to docs/configuration.md and a line under `reset`/`sync` in docs/repos-and-mounts.md.
