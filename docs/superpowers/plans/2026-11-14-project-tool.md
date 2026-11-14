# project.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A base-repo `project.sh` that removes, moves and tidies a project's container setup in one command, and fronts `project-init.sh`, `ai-containers-report.sh` and `sync-to-projects.sh`.

**Architecture:** `project.sh` follows `group.sh`'s shape (one `cmd_*` per verb, `confirm`, `--yes`) and sources `sandbox-common.sh` and `repo.sh` (behind a new sourcing guard) for the volume, label, seed-image and git-helper code it reuses. Working copies are inspected through `repo-git-reset.sh inspect`, which gains a `WORKTREE` record, and are copied volume to volume with `rsync` in the seed image. Everything destructive is listed first, confirmed, and ordered so a re-run or `gc` finishes a partial failure.

**Tech Stack:** bash (floor 5.1), Docker CLI, the `ai-containers-seed` image (Alpine, git, rsync), the hermetic suite's fake-`docker` pattern, the integration harness.

**Spec:** `docs/superpowers/specs/2026-11-14-project-tool-design.md` (approved; amended while planning — the image after `mv`, the `WORKTREE` record).

**Branch:** `feat/project-tool` in the main checkout, not a worktree: `verify-on-host.sh`'s bash-5.1 arm fails from a git worktree.

## Global Constraints

- Bash 5.1 floor: no 5.2+ constructs; `tests/bash-dialect-lint.sh` and `shellcheck` (0.11.0) clean, `# shellcheck disable=SCxxxx: reason` at the site when needed.
- BSD userland too (macOS): no `readlink -f`, `stat -c`, `sed -i`, `find -printf`; use `tests/portability.sh` helpers in tests and `pwd -P` in code.
- Cite code by what it says (`file: \`name()\``), never by line number (`tests/test-code-references.sh`).
- `project.sh` is base-repo only: not in `AI_CONTAINERS_SHARED_FILES`.
- Never run git on a working copy's own `.git`; only through `repo-git-reset.sh` in the seed container (`git_helper_run`).
- Image removal: one named image, `docker rmi` without `--force`, only when its `ai-containers.project` label equals the project's id (`ai_containers_project_id()` of the `.ai-containers` directory's physical path). Never `docker image prune`, never build-cache pruning.
- Every seed-container `docker run` resolves `seed_selinux_opt` through `ensure_seed_image` and passes it; host paths go through `docker_bind()`.
- Files in a project directory are agent-writable: read and write them through `project-files.sh` (`_proj_read`, `_proj_write`); refuse a `.ai-containers` that is a link; `projects.conf` and `~/.ai-containers/image-projects.conf` are rewritten through a temp file beside them and a rename, refusing a link or non-regular file.
- Destructive commands print their full listing on every run; `--yes` skips only the question; a non-TTY stdin without `--yes` refuses having changed nothing (as `group.sh`'s `confirm()`).
- Exit status: 0 done or nothing to do, 1 refused or failed (as `group.sh`).
- Tests are hermetic: `HOME` and the engine copy in a temp dir, a fake `docker` on `PATH` that logs argv; the real `~/.ai-containers` is never read or written.
- After adding or changing a test, run `bash tests/test-falsify-targets.sh`; when it reports a mismatch, fix `tests/falsify/targets.conf` as `bash tests/falsify/derive-targets.sh --evidence` shows.
- Every new assertion is seen failing: damage the line it covers, watch it go red, restore (record the demonstration in the commit message).
- Commit messages end with the session's attribution lines.

## Review Focus

1. **Paths with a space** in the project root or `<new-dir>`: `rm`, `mv` and `gc` work, and the projects.conf line is matched whole (tests in Task 4 and Task 5).
2. **Stdin not a TTY, no `--yes`**: `rm`, `mv` and `gc` refuse having removed, moved or written nothing (Tasks 4, 5, 6).
3. **`IMAGE_NAME` naming a base image or another project's image**: never removed by `rm`, `mv` or `gc` (Tasks 4, 5).
4. **A hand-edited `projects.conf`** (comments, blank lines, CRLF line, no trailing newline): every other line byte-identical after `rm`, `mv`, `gc` (Task 3 helpers, Task 4 end-to-end).
5. **A working copy launched from a nested registered project**: belongs to the nested one; `rm`/`mv`/`gc` of the outer project never touch it (Tasks 4, 5).

---

### Task 1: `inspect` reports whether the checkout's files differ from its branch

**Files:**
- Modify: `repo-git-reset.sh` (`cmd_inspect()`; header comment's mode table)
- Test: `tests/test-repo-git-reset.sh`

**Interfaces:**
- Produces: one record `WORKTREE|clean`, `WORKTREE|changed` or `WORKTREE|?`, printed by `inspect` after the `TAG|` records and before `END|inspect`, every run. `changed` = a tracked file differs from the checked-out branch's tip, or an untracked file not ignored by the checkout's own ignore rules exists. `?` = not cloned (`STALE`), detached HEAD, the tip unreadable (`?`), or any git step failing.

- [ ] **Step 1: Write the failing tests** in `tests/test-repo-git-reset.sh`, using its existing fixture builders (a remote plus a volume-shaped checkout):
  - `inspect reports WORKTREE|clean for a checkout matching its branch`
  - `inspect reports WORKTREE|changed for an edited tracked file`
  - `inspect reports WORKTREE|changed for an untracked file`
  - `inspect reports WORKTREE|clean when the only extra file is ignored by the checkout's .gitignore`
  - `inspect reports WORKTREE|? when the remote cannot be cloned`
  - `inspect reports WORKTREE|? on a detached HEAD`
  - `inspect changes nothing in the checkout` — a sorted `find … -exec cksum` listing of the checkout (worktree and `.git`) is identical before and after.
  Each asserts the exact record line, e.g. `[[ "$(grep '^WORKTREE|' <<<"$out")" == 'WORKTREE|changed' ]]`, and that it precedes `END|inspect`.

- [ ] **Step 2: Run them to verify they fail**
Run: `bash tests/run-all.sh test-repo-git-reset.sh`
Expected: the six `WORKTREE` assertions FAIL (no such record); the "changes nothing" one passes.

- [ ] **Step 3: Implement in `cmd_inspect()`**: after the tag loop, when the clone succeeded and `volume_head` named a branch whose tip `volume_branches` read: `mark_safe_directory "$dir"`, then through `git --git-dir="$F/.git" --work-tree="$dir"`: `read-tree <tip>`, `update-index -q --ignore-submodules --refresh`, `diff-files --ignore-submodules=all --quiet` (0 clean, 1 changed, other `?`); when clean, `ls-files --others --exclude-standard -z` with any output → changed. Print `?` on every other path. Add `WORKTREE` to the header's description of `inspect`.

- [ ] **Step 4: Run the tests to verify they pass**
Run: `bash tests/run-all.sh test-repo-git-reset.sh`
Expected: PASS, every assertion.

- [ ] **Step 5: Demonstrate** three mutants, each red then restored: always print `clean`; drop the untracked check; drop `--exclude-standard`.

- [ ] **Step 6: Score the target on Linux** (long; run in the background):
Run: `bash tests/falsify/run.sh --target repo-git-reset.sh --jobs auto && bash tests/falsify/check-ledger.sh`
Expected: no new unledgered survivor. Kill a new survivor with an assertion, or classify it in `tests/falsify/survivors.txt` (`GAP:`/`EQUIVALENT:`/`ENV-DEPENDENT:` with the reason).

- [ ] **Step 7: Commit** `feat(repo): inspect reports whether a checkout's files differ from its branch (WORKTREE)`.

### Task 2: Shared plumbing — the working-copy tag, `repo.sh` as a library, a working copy's URL

**Files:**
- Modify: `sandbox-common.sh` (new `workcopy_tag()`), `sandbox.sh` (the `ws_tag` line uses it), `repo.sh` (sourcing guard before dispatch; `git_helper_run()` URL fallback)
- Test: `tests/test-sourced-guards.sh`, `tests/test-repo-destructive.sh`, and the test that already asserts a `:rwcopy` volume name (`grep -ln -- '--wc-' tests/test-*.sh`)

**Interfaces:**
- Produces: `workcopy_tag <launch_dir>` → prints the tag `sandbox.sh` uses in `repo_workcopy_volume_name`, byte-identical to today's `ws_tag` formula (sanitised basename, `_`, first 8 digits of `cksum` of the full path).
- Produces: `source repo.sh` defines its functions and globals (`ensure_seed_image`, `seed_selinux_opt`, `git_helper_run`, `inspect_git`, `host_uid`, `host_gid`) and returns before dispatch — the guard is `(return 0 2>/dev/null) && return 0`, as in `project-init.sh`.
- Produces: `git_helper_run <vol> …` on a volume with no `ai-containers.source` whose `ai-containers.workcopy` is `1` uses the `ai-containers.source` of `repo_volume_name "<its ai-containers.repo>"`; with neither, it refuses as today.

- [ ] **Step 1: Write the failing tests**
  - `tests/test-sourced-guards.sh`: `sourcing repo.sh runs no docker command and returns 0` (fake `docker` on `PATH` logging argv; log empty) and `an EXECUTED repo.sh still dispatches` (`repo.sh --help` prints its usage).
  - `tests/test-repo-destructive.sh`: in a subshell that sources `repo.sh` with the file's fake docker: `git_helper_run on a working copy passes its base volume's recorded URL` (log contains `-e AI_REPO_URL=<base url>`) and `git_helper_run refuses a working copy whose base volume records no URL` (rc 1, no `docker run` logged).
  - The rwcopy-name test: `workcopy_tag gives the tag sandbox.sh names working copies with` — equals the tag inside the volume name that test already expects.

- [ ] **Step 2: Run them to verify they fail**
Run: `bash tests/run-all.sh test-sourced-guards.sh test-repo-destructive.sh <rwcopy test>`
Expected: FAIL — sourcing `repo.sh` runs its dispatch (usage); the fallback logs no URL; `workcopy_tag` is not defined.

- [ ] **Step 3: Implement** `workcopy_tag()` in `sandbox-common.sh` beside `repo_workcopy_volume_name()`, and replace the formula in `sandbox.sh` with a call; add the guard to `repo.sh` immediately before its `case "${1:-}" in` dispatch; add the fallback to `git_helper_run()` before its "carries no recorded source URL" refusal.

- [ ] **Step 4: Run the tests to verify they pass**, plus `bash tests/run-all.sh test-repo-registry.sh test-repo-ids.sh` (they source `repo.sh` today and must keep working).
Expected: PASS.

- [ ] **Step 5: Demonstrate** the guard (remove it → the sourced-guard test is red) and the fallback (remove it → the URL test is red).

- [ ] **Step 6: Commit** `refactor: workcopy_tag() in sandbox-common.sh; repo.sh can be sourced; a working copy's helper uses its base's URL`.

### Task 3: `project.sh` — the front door, naming a project, editing the registries

**Files:**
- Create: `project.sh` (mode 755), `tests/test-project-tool.sh`
- Modify: `tests/falsify/targets.conf` only if `tests/test-falsify-targets.sh` asks (Task 8 adds the active row)

**Interfaces:**
- Consumes: `sandbox-common.sh`, `repo.sh` (sourced, Task 2).
- Produces (all in `project.sh`):
  - `prj_conf` — `"$_here/projects.conf"`.
  - `prj_roots` → each registered root, one per line (blank and `#` lines skipped; trailing whitespace and CR stripped for matching only).
  - `prj_resolve <arg> [unregistered-ok]` → sets `PRJ_ROOT` (the registered line's text, or the absolute path when `unregistered-ok` and nothing matches) and `PRJ_DOT` (`$PRJ_ROOT/.ai-containers`); exits 1 naming the candidates otherwise. A match is: the same physical directory (`cd … && pwd -P` on both sides, when both exist), else the same string after removing a trailing `/` and making it absolute, else a basename that exactly one registered root has.
  - `prj_conf_remove <root>`, `prj_conf_replace <old-root> <new-root>`, `prj_conf_add <root>` — change only the matching line; every other byte stays.
  - `prj_image_projects_drop <id>` — removes the lines of `~/.ai-containers/image-projects.conf` whose id field is `<id>`.
  - `_prj_rewrite <file> <new-content-file>` — refuses a link or non-regular `<file>` (rc 1, `ERROR:`), keeps its mode, writes a temp file in the same directory and renames it over.
  - Dispatch: `init|report|sync` → `exec "$_here/project-init.sh"|"$_here/ai-containers-report.sh"|"$_here/sync-to-projects.sh" "$@"`; `rm|mv|gc` → `cmd_rm|cmd_mv|cmd_gc` (stubs that exit 1 "not yet" until Tasks 4–6); `-h|--help|help|""` → usage, 0; anything else → `ERROR: unknown command: X`, usage on stderr, 1.

- [ ] **Step 1: Write the failing tests** in `tests/test-project-tool.sh`. Setup: copy the engine's tracked `*.sh`, `Dockerfile.seed` and `projects.conf.example` into `$TMP/engine` (as `tests/test-project-init.sh` does), `HOME=$TMP/home`, fake `docker` on `PATH` (argv to `$DOCKER_LOG`). Replace `project-init.sh`, `ai-containers-report.sh` and `sync-to-projects.sh` in the copy with stubs that log `"$0 $*"` and exit 7.
  - `init passes its arguments through and returns project-init.sh's status` (log has `project-init.sh /p name`; rc 7); the same for `report --tsv` and `sync /p`.
  - `no command prints usage and exits 0`; `an unknown command exits 1 and names it`.
  - `resolve finds a project by its registered path`, `… with a trailing slash`, `… by a relative path`, `… through a symlink to it`, `… by its unique basename`; `resolve refuses a basename two projects share, naming both`; `resolve refuses an unregistered path`; `resolve accepts an unregistered path when allowed`.
  - `prj_conf_remove keeps every other byte`: a `projects.conf` with a comment, a blank line, a CRLF line, a path with a space and no trailing newline; after removing one line, `cmp` against the expected bytes.
  - `prj_conf_replace rewrites the line in place`; `prj_conf_add appends once`.
  - `a linked projects.conf is refused and its target unchanged`.
  - `prj_image_projects_drop removes exactly the lines of that id`.
  `project.sh` gets the same sourcing guard as `repo.sh` (before its dispatch); the helper tests source it in a subshell, the command tests run it as a program.

- [ ] **Step 2: Run to verify they fail**
Run: `bash tests/run-all.sh test-project-tool.sh`
Expected: FAIL — `project.sh` does not exist.

- [ ] **Step 3: Implement** `project.sh` with the interfaces above: header comment in `group.sh`'s style (what a project's setup is, why this exists, its scope: never groups or repo volumes), `set -euo pipefail`, `unset CDPATH`, `usage()`, `confirm()` as in `group.sh`, the sourcing guard before dispatch.

- [ ] **Step 4: Run to verify they pass**
Run: `bash tests/run-all.sh test-project-tool.sh && bash tests/test-falsify-targets.sh`
Expected: PASS.

- [ ] **Step 5: Demonstrate** a mutant of `prj_resolve` (drop the uniqueness check → the shared-basename test is red) and of `_prj_rewrite` (drop the link check → the link test is red).

- [ ] **Step 6: Commit** `feat(project): project.sh fronts init, report and sync, and names a project`.

### Task 4: `project.sh rm`

**Files:**
- Modify: `project.sh`
- Test: `tests/test-project-tool.sh`

**Interfaces:**
- Consumes: Task 3's helpers; `inspect_git`, `ensure_seed_image` (Task 2); `docker_volume_label`, `docker_volume_labels_load`, `repo_workcopy_volumes`, `docker_volume_in_use`, `ai_containers_project_id`, `load_env_defaults` (`sandbox-common.sh`); `confirm`.
- Produces (used by Tasks 5 and 6):
  - `prj_env <dot> <KEY> [default]` → the value `sandbox.sh` would use: in a subshell, `unset KEY`, `load_env_defaults "<dot>/sandbox.local.env" local`, `load_env_defaults "<dot>/sandbox.env"`, print `${KEY:-default}`.
  - `prj_id <path>` → `ai_containers_project_id` of `pwd -P` of `<path>` when it exists, else of the string as given.
  - `prj_running <root>` → prints the names of running containers that bind-mount `<root>/.ai-containers` or anything under it (`docker inspect --format '{{range .Mounts}}{{.Source}}…'`, compared with both the logical and physical forms) or whose image is the project's `IMAGE_NAME` (`docker ps --filter ancestor=`); rc 0 when it printed any.
  - `prj_workcopies <root>` → working-copy volumes whose `ai-containers.launch-dir` equals `<root>/.ai-containers` or lies under `<root>` (logical or physical form), excluding those under a deeper registered root.
  - `prj_copy_risk <vol>` → prints one line describing what the copy would lose and returns 1 when it is at risk or not checked, 0 when nothing is at risk. Not checked (rc 1, the line says why): no `ai-containers.repo`, a base volume that is gone, a base of `ai-containers.type` `path`, `STALE`, no `END|inspect`. At risk: a `BRANCH` with an unpushed count > 0 or `?`, a `STASH`, a `TAG` the remote lacks whose commit it does not keep, `NESTED`, `WORKTREE|changed` or `WORKTREE|?`.
  - `prj_image_remove <image> <id>` → `docker rmi <image>` (no `--force`) when `docker image inspect` gives `ai-containers.project` = `<id>`; otherwise prints why it is kept; never fails the caller.
  - `prj_unused_shared <root>` → for the project's `AI_CONTAINER_GROUP` (default `default`), each `REPOS` name and each `@name` in `SPECS_PATH`/`DOCS_PATH`/`ARCHITECTURE_REPO_PATH`: when no other registered project's resolved settings use it, prints `NOTE: group <g> is used by no other registered project; remove it with ./group.sh rm <g>` (or `… repo <r> … ./repo.sh rm <r>`).
  - `cmd_rm <project> [--yes]`.

Order inside `cmd_rm`: resolve → refuse a linked `.ai-containers` → refuse while `prj_running` → gather the image decision, the working copies with `prj_copy_risk`, the unused-shared notes → print the listing → `confirm` → `docker volume rm` each copy (a failure stops here, exit 1, nothing else removed) → `prj_image_remove` → `rm -rf "$PRJ_DOT"` (a failure: exit 1, the lines stay) → `prj_image_projects_drop <id>` once no image carries the id (`docker images -q --filter label=ai-containers.project=<id>` empty) → `prj_conf_remove` → `rmdir "$PRJ_ROOT"` if empty → print the unused-shared notes.

- [ ] **Step 1: Write the failing tests** (fake docker: volumes are directories under `$VOLS` with a `labels` file; `docker run … inspect` prints the records in `$FAKE_INSPECT_<volume>`; `ps`/`inspect` mounts from `$FAKE_RUNNING`; `rmi`/`volume rm` log and act; `$FAKE_FAIL_VOLUME_RM` makes `volume rm` fail):
  - `rm removes .ai-containers, its projects.conf line and its image-projects.conf line`
  - `rm removes the image whose label is this project's id, without --force` (log has `rmi <IMAGE_NAME>`, no `--force`)
  - `rm keeps an IMAGE_NAME whose label is another project's id`; `rm keeps an IMAGE_NAME with no ai-containers labels`
  - `rm removes exactly the working copies launched from this project` (log's `volume rm` set == expected set)
  - `rm leaves a working copy launched from a nested registered project`
  - `rm lists a copy with 2 unpushed commits as at risk`; `… with WORKTREE|changed as holding uncommitted work`; `… of a path repo as not checked`; `… whose remote is STALE as not checked`; `… whose inspection was cut short as not checked`
  - `rm refuses on a non-TTY without --yes and changes nothing` (no `rm`/`rmi` in the log; directory and both lines intact)
  - `rm --yes still prints the listing`
  - `rm refuses while a container mounts the project's .ai-containers`; `… while a container runs its image` — nothing changed
  - `rm names an unused group with ./group.sh rm`; `rm does not name a group another project uses`; the same for a `REPOS` repo and a `SPECS_PATH=@name` repo
  - `rm removes the project root when it is left empty`; `rm keeps a root with other files`
  - `rm refuses a .ai-containers that is a symlink, and the link's target is untouched`
  - `rm works on a project whose path has a space`
  - `rm keeps the projects.conf line when a working copy cannot be removed` (exit 1; a re-run with the volume removable completes)
  - `rm keeps every other projects.conf byte` (the Task 3 fixture file)

- [ ] **Step 2: Run to verify they fail** — `bash tests/run-all.sh test-project-tool.sh`; Expected: the `rm` assertions FAIL ("not yet").

- [ ] **Step 3: Implement** the helpers and `cmd_rm` above. Listing lines, one per item: `  directory   <dot>`, `  registry    <line> (projects.conf)`, `  image       <IMAGE_NAME>` or `  image       <IMAGE_NAME> — kept: <why>`, `  working copy <vol> (<repo>) — <risk line>`, then `<n> working cop(y/ies) at risk or not checked.` when any.

- [ ] **Step 4: Run to verify they pass** — `bash tests/run-all.sh test-project-tool.sh`; Expected: PASS.

- [ ] **Step 5: Demonstrate** mutants: drop the running check; drop the label/id comparison in `prj_image_remove`; make `prj_copy_risk` return 0 for "not checked"; drop the nested-project exclusion. Each turns a named test red.

- [ ] **Step 6: Commit** `feat(project): project.sh rm removes a project's setup, image and working copies`.

### Task 5: `project.sh mv`

**Files:**
- Modify: `project.sh`
- Test: `tests/test-project-tool.sh`

**Interfaces:**
- Consumes: Task 3 and Task 4 helpers; `workcopy_tag`, `repo_workcopy_volume_name`; `emit_env_list` (source `project-init.sh`, guarded); `_proj_read`, `_proj_write`, `_proj_index_tracks` (`project-files.sh`).
- Produces:
  - `prj_copy_volume <old-vol> <new-vol> <repo> <launch-dir>` → `docker volume create` with labels `ai-containers.workcopy=1`, `ai-containers.repo=<repo>`, `ai-containers.launch-dir=<launch-dir>`; one seed-image run `rsync -aH --numeric-ids /src/ /dst/`, then `rsync -aH --numeric-ids --checksum --delete --dry-run --itemize-changes /src/ /dst/` whose output must be empty; on any failure removes the new volume and returns 1. The old volume is removed by the caller only after this returns 0.
  - `prj_add_mount <dot> <path>` → adds `<path>` to `EXTRA_MOUNTS` in `<dot>/sandbox.local.env` (created if absent) unless an entry (its `:mode` suffix removed) is `<path>` or an ancestor of it; the old assignment, one line or several, is replaced by `emit_env_list EXTRA_MOUNTS "<old entries> <path>"`; the result is read back with `load_env_defaults … local` and must equal the old list plus `<path>`, or the file is not written (rc 1).
  - `cmd_mv <project> <new-dir> [--yes]`.

Rules (from the spec): the new launch directory is `"$(cd "<new-dir>" && pwd)/.ai-containers"` (logical, as `runme.sh`'s `cd` produces). Refused before anything changes: a running container; `<new-dir>/.ai-containers` existing while the old one exists; `basename <new-dir>` equal to the old root's basename (when the old root survives and would be added), to any `EXTRA_MOUNTS` entry's basename, or to a `REPOS` name. Already moved: the old root has no `.ai-containers` and `<new-dir>` has one → skip the file move, do the rest; the old root may be unregistered (`prj_resolve … unregistered-ok`). Order after `confirm`: copy each working copy (`prj_copy_volume`; failure → exit 1, nothing else changed) → move the directory (`mv` on one filesystem; across filesystems copy to a temp name in `<new-dir>`, compare the file lists and `cksum`s, rename into place, then `rm -rf` the old) → remove the old copies → `prj_add_mount <new dot> <old root>` when the old root exists → `prj_conf_replace` (or `prj_conf_add` when unregistered) → `prj_image_remove <IMAGE_NAME> <old id>`, then `prj_image_projects_drop <old id>` once no image carries it → `NOTE: the next ./build.sh (runme.sh runs it) builds IMAGE_NAME again, from the cache.` → when `_proj_index_tracks` finds the old repository's index recording files under `.ai-containers/`: `NOTE: <old root>'s repository tracks .ai-containers/; those files now show as deleted there.`

- [ ] **Step 1: Write the failing tests:**
  - `mv moves .ai-containers to <new-dir>, creating it, and rewrites the projects.conf line in place`
  - `mv copies each working copy to the new launch dir's volume name and label, then removes the old` (new name == `repo_workcopy_volume_name <repo> "$(workcopy_tag <new launch dir>)"`)
  - `mv keeps the old working copy and directory when a copy's check finds a difference` (exit 1)
  - `mv adds the old root to EXTRA_MOUNTS, one entry per line, keeping existing entries`
  - `mv adds nothing when an entry already covers the old root` (`<parent>:ro`)
  - `mv refuses a <new-dir> with the old root's basename, changing nothing`; `… with an EXTRA_MOUNTS entry's basename`; `… with a REPOS name`
  - `mv refuses when both the old and the new .ai-containers exist`
  - `mv repairs a project already moved by hand` (no file move; records, copies, mount done)
  - `mv repairs a project whose line gc removed` (old path unregistered; `<new-dir>` registered)
  - `mv removes the old image and its image-projects.conf line, and says the next build rebuilds it`
  - `the retag guard passes for IMAGE_NAME right after mv` (`ai_containers_image_portable=1 ai_containers_build_retag_guard "$IMAGE_NAME" "<new>/.ai-containers"` returns 0 against the fake docker)
  - `mv keeps an image a stopped container references, and its line, and says so`
  - `mv keeps an IMAGE_NAME whose label is another project's id`
  - `mv leaves a working copy launched from a nested registered project`
  - `mv notes that the old repository tracks .ai-containers`
  - `mv refuses while a container of the project runs`; `mv refuses on a non-TTY without --yes`
  - `mv works when <new-dir> and the old root have spaces`

- [ ] **Step 2: Run to verify they fail** — Expected: the `mv` assertions FAIL ("not yet").

- [ ] **Step 3: Implement** `prj_copy_volume`, `prj_add_mount` and `cmd_mv` as specified.

- [ ] **Step 4: Run to verify they pass** — `bash tests/run-all.sh test-project-tool.sh`; Expected: PASS.

- [ ] **Step 5: Demonstrate** mutants: skip the `rsync` check; remove the old copy before the new one is checked; drop the coverage test in `prj_add_mount`; drop the basename-clash refusal.

- [ ] **Step 6: Commit** `feat(project): project.sh mv moves a project's setup with its working copies and image record`.

### Task 6: `project.sh gc`

**Files:**
- Modify: `project.sh`
- Test: `tests/test-project-tool.sh`

**Interfaces:**
- Consumes: Tasks 3–5 helpers; `_ac_removable_root` (`sandbox-common.sh`).
- Produces: `cmd_gc [--yes]`.

Rules: a `projects.conf` line is stale when `<root>/.ai-containers` is not a directory; it is kept and named instead when the nearest existing ancestor of `<root>` is empty or `_ac_removable_root` (may be an unmounted drive). An `image-projects.conf` line is stale when its path is gone; while an image carries its id, that image is listed for removal (`prj_image_remove`) and the line goes only after it. Working copies whose `ai-containers.launch-dir` is gone are listed with `prj_copy_risk`; copies a running container uses are listed as kept. For each stale project line the listing says: `If <root> was moved rather than deleted, answer no and run ./project.sh mv <root> <new-dir> (it also works after gc).` Nothing stale → `Nothing to collect.`, exit 0.

- [ ] **Step 1: Write the failing tests:**
  - `gc drops a projects.conf line whose project has no .ai-containers`
  - `gc keeps and names a line whose nearest existing directory is empty`
  - `gc drops an image-projects.conf line whose path is gone and whose id no image carries`
  - `gc lists an image whose project is gone, removes it on --yes, then drops its line`
  - `gc lists working copies whose launch dir is gone, with their risk, and removes them on --yes`
  - `gc keeps a working copy a running container uses`
  - `gc points a vanished project at project.sh mv`
  - `gc with nothing stale says so and exits 0`
  - `gc refuses on a non-TTY without --yes, changing nothing`
  - `gc keeps every other projects.conf byte`

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement `cmd_gc`.** **Step 4: Run to verify they pass.**

- [ ] **Step 5: Demonstrate** mutants: drop the unmounted-drive skip; drop the "no image carries the id" condition.

- [ ] **Step 6: Commit** `feat(project): project.sh gc removes what points at projects that are gone`.

### Task 7: Integration case — `mv` carries a real working copy

**Files:**
- Create: `tests/integration/cases/650-project-mv-moves-workcopy.sh`, `tests/integration/mutations/650-project-mv-skips-copy.patch`

**Interfaces:**
- Consumes: `fixture_scope_init` (scopes `REPO_VOLUME_PREFIX`), the seed image (`ensure_seed_image` builds it), `cmd_mv`.

Case header: `# summary: project.sh mv copies a working copy into the new launch dir's volume, intact, and removes the old` / `# tags: volumes fast` / `# requires: docker`. It runs `project.sh` from a temp copy of the engine with `HOME` in a temp dir, creates a labelled base volume and a working copy (labels as `seed_workcopy_volume()` sets them) holding a file with known content, a symlink and a 0600 file, runs `project.sh mv <proj> <new> --yes`, and asserts: the new volume exists under `repo_workcopy_volume_name <repo> "$(workcopy_tag <new>/.ai-containers)"` with the new `ai-containers.launch-dir` label; the file content, the link target and the mode are the same (read in a seed container); the old volume is gone. Cleanup removes every volume it made.

The mutation replaces the copying `rsync` in `prj_copy_volume` with `:`; the case must then FAIL (mv exits 1 on the check, and the new volume does not hold the file).

- [ ] **Step 1: Write the case.** **Step 2: Run it** — `./tests/integration/run.sh --cases 650-project-mv-moves-workcopy`; Expected: PASS.
- [ ] **Step 3: Apply the mutation and run** — `tests/integration/mutate.sh apply 650-project-mv-skips-copy && ./tests/integration/run.sh --cases 650-project-mv-moves-workcopy; tests/integration/mutate.sh revert 650-project-mv-skips-copy`; Expected: FAIL, then reverted; `tests/integration/mutate.sh verify` lists every patch as applying.
- [ ] **Step 4: Check the layers** — `bash tests/test-layer-containment.sh` and `bash tests/test-integration-runner.sh`; Expected: PASS (the case is in the PR and nightly selections through its tags).
- [ ] **Step 5: Commit** `test(integration): 650 — project.sh mv carries a real working copy`.

### Task 8: Falsify registration, docs, and the whole gate

**Files:**
- Modify: `tests/falsify/targets.conf` (active row `project.sh|EXECUTED-WHOLE|test-project-tool.sh`), `tests/falsify/survivors.txt` if needed, `AGENTS.md` (Commands: a `project.sh` block beside `group.sh`'s; `project-init.sh` and the report presented through it), `README.md`, `docs/multiple-projects.md` (moving and removing a project), `CHANGELOG.md` (Unreleased → Added), the spec's status line.

- [ ] **Step 1: Register and score** — add the row; run `bash tests/test-falsify-targets.sh`, then `bash tests/falsify/run.sh --target project.sh --jobs auto && bash tests/falsify/check-ledger.sh`; Expected: no unledgered survivor — kill each with an assertion in `tests/test-project-tool.sh` or classify it in `survivors.txt`.
- [ ] **Step 2: Docs** — AGENTS.md's Commands section gets `./project.sh init|report|sync|rm|mv|gc` with one paragraph on what `rm`, `mv` and `gc` remove, move and keep (groups and repo volumes only named), citing functions by name; `docs/multiple-projects.md` gets "Moving a project" (the `~/dev/workspace/<name>` case) and "Removing a project"; CHANGELOG entry; README's quick start mentions `./project.sh init`.
- [ ] **Step 3: Run the doc checks** — `bash tests/run-all.sh test-docs.sh test-code-references.sh test-changelog-section.sh`; Expected: PASS.
- [ ] **Step 4: The whole local gate** — `PHASES="5 7" bash ./verify-on-host.sh`; Expected: `RESULT: PASSED — phases [5 7]` (plain, symlinked TMPDIR and bash-5.1 arms, shellcheck).
- [ ] **Step 5: Commit** `docs(project): project.sh in AGENTS.md, the README and multiple-projects; falsify row`.
- [ ] **Step 6: Clean up** — remove the seed-image volumes and any `ai-sandbox-it*` images the integration runs left, and any `~/.ai-containers/image-projects.conf` lines a test build added (check with `grep -v '/dev/' ~/.ai-containers/image-projects.conf`); report the branch ready to push.
