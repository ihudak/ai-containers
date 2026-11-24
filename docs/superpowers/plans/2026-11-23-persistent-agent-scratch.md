# Persistent agent scratch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** What an agent writes through `TMPDIR`, into `~/.cache` or into `~/.local/state` survives the container stopping, for every agent, with no per-agent setup.

**Architecture:** Three group directories are bind-mounted whole — `.cache` → `~/.cache`, `.local/state` → `~/.local/state`, `.var-tmp` → `/var/tmp` — replacing today's nested `~/.cache/qmd`, `~/.cache/ms-playwright` and `~/.local/state/claude` mounts. Each launch makes its own folder under `.var-tmp`, passes its in-container path as `AI_AGENT_TMPDIR`, labels the container with it, and the image's profile script exports `TMPDIR` from it for non-root shells only. The launcher's walk for planted launchers skips the three mounts, and old container folders are pruned at launch.

**Tech Stack:** bash (floor 5.1), POSIX sh for the profile script, Docker, the repo's hermetic test suite (`tests/run-all.sh`), integration corpus (`tests/integration/run.sh`) and falsify tier (`tests/falsify/run.sh`).

**Spec:** `docs/superpowers/specs/2026-11-23-persistent-agent-scratch-design.md`

**Before touching `tests/`:** read `docs/testing.md` (an `AGENTS.md` rule).

## Global Constraints

- Group directories: `.var-tmp` → `/var/tmp`, `.cache` → `~/.cache`, `.local/state` → `~/.local/state`, all `:rw`, mounted whatever `sandbox.conf` says.
- Per-container folder name: `<YYMMDD>-<HHMMSS>-<launcher pid>` (`date +%y%m%d-%H%M%S`, then `-$$`), so `TMPDIR` is `/var/tmp/<that>`, at most 30 bytes.
- In-container variable `AI_AGENT_TMPDIR`; container label `ai-containers.tmpslot=<folder name>`.
- `TMPDIR` is exported only by the image's profile script, only when `TMPDIR` is unset, `AI_AGENT_TMPDIR` names an existing directory, and `id -u` is not `0`. Never `docker run -e TMPDIR`.
- Pruning: only entries of `.var-tmp` named `^[0-9]{6}-[0-9]{6}-[0-9]+$`, untouched for 30 days (nothing inside modified within `-mtime -30`), whose slot no running container carries. A `docker ps` that fails removes nothing.
- The three mounts are skipped by `launcher_dirs_in()`'s walk only when their destination is outside `/workspace`; the git scan already skips them; `_fs_linked_in()` is unchanged.
- `_copy_group_slice` is unchanged (it keeps copying `.cache/qmd`; nothing else of the three is copied).
- bash 5.1 floor (`tests/bash-dialect-lint.sh`), no interval quantifier in awk, GNU and BSD userland both (`find`, `du`, `touch`, `date`).
- Cite code by snippet, never line number (`tests/test-code-references.sh`).
- Every integration case must have been seen failing: each gets a mutation patch.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A group directory mounted into `/workspace` through `EXTRA_MOUNTS` (e.g. `EXTRA_MOUNTS=~/.ai-containers/<g>/.var-tmp`) is the agent's like any other mount and must still be walked for launchers (G92's rule) — test in Task 5.
2. A group's `.cache`, `.local/state` or `.var-tmp` that is a link out of the group gets the same `WARNING:` as every group path (`_warn_group_link_out`), and is then walked, not skipped, because its resolved source no longer matches — test in Task 5.
3. A pruned folder holding a link to a file outside it, or a directory the launcher cannot read: the outside file survives and the launch still starts — tests in Task 6.
4. Two launches of one group at once: the second's pruning never removes the first's fresh folder, running or not yet labelled — test in Task 6.
5. `container.env`: its `TMPDIR` is kept in the agent's shell; its `AI_AGENT_TMPDIR` is refused like every launcher `-e` key — tests in Tasks 3 and 4.

---

### Task 1: macOS spike (a person, on a Mac)

The spec requires this before the rest is built. An agent on Linux cannot run it: **stop and ask the user to run the script on a Mac**, under Docker Desktop and under Colima, and paste the output. If either has no Mac, ask whether to proceed without it.

**Files:**
- Create (scratchpad, not committed): `spike-var-tmp.sh`

- [ ] **Step 1: Give the user this script** (needs an image built from this repo; `IMG` names it)

```bash
#!/usr/bin/env bash
# Does /var/tmp and ~/.cache on a host bind work under this Mac's docker?
set -u
IMG="${IMG:-ai-sandbox}"; H="$(mktemp -d "$HOME/.spike-XXXX")"; mkdir -p "$H/vt" "$H/cache"
docker run --rm --pull=never --entrypoint bash -u "$(id -u):$(id -g)" -e HOME=/tmp/h \
  -v "$H/vt:/var/tmp" -v "$H/cache:/tmp/h/.cache" "$IMG" -c '
  ok() { printf "PASS %s\n" "$1"; }; no() { printf "FAIL %s\n" "$1"; }
  python3 -c "import socket; socket.socket(socket.AF_UNIX).bind(\"/var/tmp/s.sock\")" && ok socket || no socket
  cd /var/tmp && mkdir -p t/a/b && ln -s ../../x t/a/b/l && tar -C t -cf t.tar a && mkdir u && tar -C u -xf t.tar && ok tar-dotdot-link || no tar-dotdot-link
  git init -q g && cd g && echo x > f && git add f && git -c user.email=a@b -c user.name=n commit -qm x && ok git || no git
  for d in /tmp /var/tmp; do s=$(date +%s); python3 -m venv "$d/v" && "$d/v/bin/pip" install -q --cache-dir "$HOME/.cache/pip" requests >/dev/null 2>&1; echo "TIME $d $(( $(date +%s) - s ))s"; done'
rm -rf "$H"
```

- [ ] **Step 2: Read the result**

Any `FAIL` line → stop: the spec then switches all three to named volumes, which changes this plan; take it back to the user. Only `TIME` differences → record them in the PR description and continue.

---

### Task 2: `~/.cache` and `~/.local/state` mounted whole

**Files:**
- Modify: `sandbox.sh` — the group mount section of `run_container()`: the `if is_enabled qmd; then` block, the `if is_active playwright; then` block, and the claude-code block's `"$group_root/.local/state/claude"` mount line
- Create: `tests/test-agent-tmp.sh` (harness copied from `tests/test-tool-config-mounts.sh`: temp `HOME`, `SANDBOX_USER=dev`, fake `docker` capturing `run` args, `run_sandbox`, `mounted`)
- Modify: `tests/test-tool-config-mounts.sh` (`BUILTIN_DIRS`: `.cache/qmd` → `.cache`; fix the comment's count), `tests/test-playwright.sh` (the two "browser cache mounted from the group" and the "group browser-cache dir created" assertions)

**Interfaces:**
- Produces: `tests/test-agent-tmp.sh` with `setup`, `teardown`, `run_sandbox`, `mounted <src> <dst>` and a fake `docker` that later tasks extend (`ps` in Task 6).

- [ ] **Step 1: Write the failing tests** in `tests/test-agent-tmp.sh`, with `sandbox.conf` = `qmd=OFF`, `playwright=OFF`, `claude-code=OFF` unless stated:

```bash
mounted "$GROUP_ROOT/.cache" "/home/dev/.cache"               # "cache: ~/.cache mounted whole from the group, whatever sandbox.conf says"
mounted "$GROUP_ROOT/.local/state" "/home/dev/.local/state"   # "state: ~/.local/state mounted whole"
[[ -d "$GROUP_ROOT/.cache" && -d "$GROUP_ROOT/.local/state" ]] # "both made in the group"
# with qmd=ON playwright=ON claude-code=ON:
! grep -qE ':/home/dev/\.(cache|local/state)/' "$CAPTURE"      # "no nested mount under ~/.cache or ~/.local/state"
# group bootstrap from:<group> (source group holds .cache/qmd/i, .cache/pip/p, .local/state/s):
[[ -f "$NEW/.cache/qmd/i" && ! -e "$NEW/.cache/pip/p" && ! -e "$NEW/.local/state/s" ]]  # "slice: qmd still copied, other caches and state not"
```

- [ ] **Step 2: Run and see them fail**

Run: `bash tests/run-all.sh test-agent-tmp.sh`
Expected: FAIL on the whole-directory mounts and the nested-mount check.

- [ ] **Step 3: Implement in `sandbox.sh`**: `install -d "$group_root/.cache" "$group_root/.local/state"` and two `add_mount_if_exists config_mount_flags` lines beside the other group mounts, unconditional; delete the nested `.cache/qmd`, `.cache/ms-playwright` and `.local/state/claude` mounts and the `install -d` of the first two. Rewrite their comments to say the whole directory is mounted (the Playwright comment's reason — browsers survive `--rm` — still holds).

- [ ] **Step 4: Update the two existing tests** — `BUILTIN_DIRS` lists `.cache` instead of `.cache/qmd`; `test-playwright.sh`'s ON and pinned cases assert `$GROUP_ROOT/.cache:/home/dev/.cache:rw` and no `ms-playwright` mount; drop "group browser-cache dir created". Its OFF case stays as is.

- [ ] **Step 5: Run**

Run: `bash tests/run-all.sh test-agent-tmp.sh test-tool-config-mounts.sh test-playwright.sh test-mutations.sh`
Expected: all PASS. If `test-mutations.sh` says `510-group-claude-readonly.patch` no longer applies, refresh its context lines (the case and the damage stay the same).

- [ ] **Step 6: Commit** — `feat(launcher): keep ~/.cache and ~/.local/state across restarts`

---

### Task 3: A `/var/tmp` folder per container

**Files:**
- Modify: `sandbox.sh` — `run_container()`: the group mount section, where `container_name` is set, the `launcher_env` array, just before `docker run -it --rm`, and the `docker run` arguments
- Modify: `tests/test-agent-tmp.sh`

**Interfaces:**
- Produces: local `agent_tmp_slot` in `run_container()` (the folder name); `-e AI_AGENT_TMPDIR="/var/tmp/$agent_tmp_slot"` in `launcher_env`; `--label "ai-containers.tmpslot=$agent_tmp_slot"` on `docker run`; the host folder `$group_root/.var-tmp/$agent_tmp_slot`, mode 0700, made just before `docker run` (Task 6 prunes just before that).

- [ ] **Step 1: Write the failing tests**

```bash
mounted "$GROUP_ROOT/.var-tmp" "/var/tmp"                                  # "/var/tmp mounted from the group"
slot="$(sed -n 's|^AI_AGENT_TMPDIR=/var/tmp/||p' "$CAPTURE")"
[[ "$slot" =~ ^[0-9]{6}-[0-9]{6}-[0-9]+$ ]]                                # "AI_AGENT_TMPDIR names a per-container folder"
(( ${#slot} + 9 <= 30 ))                                                   # "TMPDIR stays within 30 bytes"
grep -qxF "ai-containers.tmpslot=$slot" "$CAPTURE"                          # "the container carries its folder as a label"
[[ -d "$GROUP_ROOT/.var-tmp/$slot" && "$(p_stat_mode "$GROUP_ROOT/.var-tmp/$slot")" == 700 ]]  # "folder made on the host, 0700"
! grep -qE '^TMPDIR=' "$CAPTURE"                                           # "TMPDIR itself is never passed to docker"
# a second launch → a different slot                                        # "each launch gets its own folder"
# container.env holding AI_AGENT_TMPDIR=/etc → a WARNING naming the line, and the captured value is still /var/tmp/<slot>
```

(`p_stat_mode` is in `tests/portability.sh`; check its output format there and compare accordingly.)

- [ ] **Step 2: Run and see them fail** — `bash tests/run-all.sh test-agent-tmp.sh`, FAIL on each new assertion.

- [ ] **Step 3: Implement** — `install -d "$group_root/.var-tmp"` and its `add_mount_if_exists` to `/var/tmp`; `agent_tmp_slot="$(date +%y%m%d-%H%M%S)-$$"` beside `container_name`; the `-e` and `--label`; before `docker run`, `mkdir -m 0700` the folder, and on failure print `ERROR:` naming it and `exit 1` (no reuse of an existing folder). A comment on why `TMPDIR` is not passed here: the root entrypoint would get it.

- [ ] **Step 4: Run** — `bash tests/run-all.sh test-agent-tmp.sh test-env-file.sh`, all PASS.

- [ ] **Step 5: Commit** — `feat(launcher): give each container a folder under a persistent /var/tmp`

---

### Task 4: `TMPDIR` for the agent's shell

**Files:**
- Modify: `Dockerfile` — the `printf '%s\n'` list piped to `| tee /etc/profile.d/ai-tools.sh >> /etc/bash.bashrc`
- Modify: `tests/test-profile-scripts.sh`

**Interfaces:**
- Consumes: `AI_AGENT_TMPDIR` (Task 3).

- [ ] **Step 1: Write the failing tests** in `tests/test-profile-scripts.sh`, under dash, bash and posix-mode bash, against the `ai-tools.sh` the file already generates from the Dockerfile. A fake `id` on `PATH` prints `1000` (or `0`) for `-u`, because CI's floor container runs as root. Each prints `${TMPDIR-unset}` after sourcing:

| Case | Env | Expected |
|---|---|---|
| sets it | `AI_AGENT_TMPDIR=$TMP/slot` (exists), `TMPDIR` unset, id 1000 | `$TMP/slot` |
| keeps container.env's | same, `TMPDIR=/keep` | `/keep` |
| missing folder | `AI_AGENT_TMPDIR=$TMP/none` | `unset` |
| root | id `0` | `unset` |
| no variable | `AI_AGENT_TMPDIR` unset | `unset` |

- [ ] **Step 2: Run and see them fail** — `bash tests/run-all.sh test-profile-scripts.sh`.

- [ ] **Step 3: Add one line to the list**, POSIX sh, no single quotes in it:

```sh
if [ -z "${TMPDIR:-}" ] && [ -n "${AI_AGENT_TMPDIR:-}" ] && [ -d "$AI_AGENT_TMPDIR" ] && [ "$(id -u)" != 0 ]; then export TMPDIR="$AI_AGENT_TMPDIR"; fi
```

Extend the comment above the `RUN`: why only here (login and interactive shells of the agent, the `capsh` shell and `docker exec` ones; never root, never the start-up steps run through `runuser`, never services), and why an existing `TMPDIR` wins.

- [ ] **Step 4: Run** — `bash tests/run-all.sh test-profile-scripts.sh test-dockerfile-layers.sh`, all PASS.

- [ ] **Step 5: Commit** — `feat(image): export TMPDIR from AI_AGENT_TMPDIR for the agent's shells`

---

### Task 5: The launcher walk skips the three group mounts

**Files:**
- Modify: `sandbox.sh` — in `launcher_ro_overlay()`, the loop whose body calls `launcher_dirs_in found unreadable "$src" "$uid" "$gid" "$you"`; a new helper beside it
- Modify: `tests/test-launcher-dir-ro.sh` (new `T93`, after `T92`)

**Interfaces:**
- Produces: `_group_scratch_mount <physical-src> <dst>` → status 0 when `<dst>` is neither `/workspace` nor below it and `<src>` is exactly `$_git_skip_root/.var-tmp`, `$_git_skip_root/.cache` or `$_git_skip_root/.local/state`; 1 otherwise (and when `_git_skip_root` is empty).

- [ ] **Step 1: Write the failing tests** (`T93`; `mk_launcher`, `launch`, `mounts`, `err_names` exist in the file; `G=$HOME/.ai-containers/<the group that file's launches use>`):

```bash
# launchers planted in each of the three: launch rc 0, and no mount line whose source starts with them
mk_launcher "$G/.var-tmp/p"; mk_launcher "$G/.cache/pip/p"; mk_launcher "$G/.local/state/p"
#   "T93 a launcher in the group's /var/tmp, ~/.cache or ~/.local/state is not overlaid"
# an unlistable directory there (chmod 000 "$G/.cache/locked"): rc 0, no ERROR naming it
#   "T93 a folder the agent made unlistable in the group's cache does not refuse the launch"
# control, scope: a launcher in "$G/.claude/p" is still overlaid :ro
#   "T93 the skip covers only the three, not the rest of the group"
# control, G92: EXTRA_MOUNTS="$G/.var-tmp" with the launcher in it → overlaid :ro at /workspace/.var-tmp/p/.ai-containers
#   "T93 the group's /var/tmp mounted into /workspace is walked like any mount"
# Review Focus 2: "$G/.cache" a link to "$TMP/elsewhere" holding a launcher → the link WARNING, and the launcher overlaid
#   "T93 a group cache that links out of the group is walked"
```

Restore modes in the test before cleanup (`chmod 700`), or `rm -rf` fails.

- [ ] **Step 2: Run and see them fail** — `bash tests/run-all.sh test-launcher-dir-ro.sh`: the first two FAIL, the controls PASS.

- [ ] **Step 3: Implement** `_group_scratch_mount` and `if _group_scratch_mount "$src" "$dst"; then continue; fi` at the top of that loop. Comment: the git scan's premise (the host never runs git or a launcher from a group folder), what walking them cost (deep pip/uv trees on every launch, planted clones locked or refusing the launch), and that `_fs_linked_in()` still covers them.

- [ ] **Step 4: Run** — `bash tests/run-all.sh test-launcher-dir-ro.sh test-git-internals-ro-scan.sh test-agent-tmp.sh`, all PASS.

- [ ] **Step 5: Measure the hard-link check the spec keeps** (`_fs_linked_in()` still lists the three). With the fake `docker` of `tests/test-agent-tmp.sh`, time one launch with an empty group and one with 100,000 small files spread over `$G/.cache` (a few hundred directories, as pip lays them out). Record both times in the PR description. More than a few seconds' difference → stop and tell the user before going on; the spec says to come back.

- [ ] **Step 6: Commit** — `feat(launcher): don't walk the group's cache, state and temp folders for launchers`

---

### Task 6: Pruning old container folders

**Files:**
- Modify: `sandbox.sh` — new function near the other `run_container()` helpers; one call just before Task 3's `mkdir` of the slot
- Modify: `tests/test-agent-tmp.sh` (fake `docker ps`: prints `$FAKE_RUNNING_SLOTS`, one per line; exits 1 when `FAKE_PS_FAIL=1`)

**Interfaces:**
- Produces: `agent_tmp_prune <var-tmp-dir>` → always returns 0; prints at most one line, exactly:
  `NOTE: removed <n> temp folder(s) of stopped containers, untouched for 30 days, from <dir> (<size> freed).`
  (`<size>` from `du -sk` before removal, rendered like `du -h`.)

- [ ] **Step 1: Write the failing tests.** Age a folder by `touch -h -t 202001010000` on every path, deepest first (`find "$d" -depth`); each case launches once, with an old folder named `200101-000000-1` unless stated.

```bash
# no running container                     → removed, and the NOTE says 1                 "an old folder of a stopped container is removed"
# FAKE_RUNNING_SLOTS=200101-000000-1        → kept                                         "a running container's folder is kept, however old"
# one file inside touched now               → kept                                         "a folder touched within 30 days is kept"
# a fresh folder, no running container      → kept (Review Focus 4)                        "a concurrent launch's new folder is kept"
# old "keepme" dir and old file "x"         → kept                                         "only per-container folders are pruned"
# FAKE_PS_FAIL=1                            → kept, no NOTE                                "docker that cannot list containers removes nothing"
# old folder with link → "$TMP/outside/f"   → folder gone, "$TMP/outside/f" still there    "a link in a pruned folder is not followed"
# old folder with a chmod 000 subdirectory  → launch rc 0                                  "an unreadable folder does not stop the launch"
```

- [ ] **Step 2: Run and see them fail** — `bash tests/run-all.sh test-agent-tmp.sh`.

- [ ] **Step 3: Implement `agent_tmp_prune`.** Running slots from `docker ps --filter label=ai-containers.tmpslot --format '{{.Label "ai-containers.tmpslot"}}'` (failure → return). For each entry: name matches the slot pattern, is a directory and not a link, not running, and `find -P "$d" -mtime -30 -print -quit` prints nothing *and* exits 0 (an error keeps it) → `rm -rf -- "$d"`; a failed removal is named in its own `NOTE:` and the launch goes on.

- [ ] **Step 4: Run** — `bash tests/run-all.sh test-agent-tmp.sh`, all PASS.

- [ ] **Step 5: Commit** — `feat(launcher): prune container temp folders untouched for 30 days`

---

### Task 7: `group.sh list --sizes` shows the group directory's size

**Files:**
- Modify: `group.sh` — `cmd_list()`
- Modify: `tests/test-group-lifecycle.sh` (the `# ── list` section)

**Interfaces:**
- Produces: with `--sizes`, a fourth column headed `GROUP DIR`, each row `du -sh <group dir>`'s size, `?` when `du` fails. Without `--sizes`, output unchanged.

- [ ] **Step 1: Write the failing tests** — a group holding a 2 MiB file in `.var-tmp/x`:

```bash
# list --sizes: header has GROUP DIR; that group's row ends in a size matching ^[0-9][0-9.,]*[KMG]$, not ?
# list (no --sizes): no GROUP DIR in the header, rows have three columns as today
# a group dir du cannot read (fake du on PATH exiting 1): its row ends in ?
```

- [ ] **Step 2: Run and see them fail** — `bash tests/run-all.sh test-group-lifecycle.sh`.

- [ ] **Step 3: Implement** in `cmd_list()`.

- [ ] **Step 4: Run** — `bash tests/run-all.sh test-group-lifecycle.sh`, PASS.

- [ ] **Step 5: Score `group.sh`** (an `EXECUTED-WHOLE` falsify target, scored in CI on every PR):

Run: `bash tests/falsify/run.sh --target group.sh --jobs auto --timeout 120 | bash tests/falsify/check-ledger.sh --run-output -`
Expected: the ledger check passes. A new survivor on the new lines → add the assertion that kills it (demonstrate: damage that line by hand, see the assertion go red, restore); only one no test could kill goes in `tests/falsify/survivors.txt` as `EQUIVALENT:`.

- [ ] **Step 6: Commit** — `feat(group): list --sizes shows each group directory's size`

---

### Task 8: Integration case 520 and its mutations

**Files:**
- Create: `tests/integration/cases/520-agent-files-persist-across-restart.sh` (`tags: groups fast`, `requires: docker launcher`; modelled on `510-credentials-persist-to-host.sh`)
- Create, in the format of `510-group-claude-readonly.patch` (`# case:` and `# what:` header, then a diff):
  - `tests/integration/mutations/520-var-tmp-not-mounted.patch`, `520-cache-not-mounted.patch`, `520-state-not-mounted.patch` — each deletes one `add_mount_if_exists` line from `sandbox.sh`;
  - `tests/integration/mutations/520-tmpdir-for-root.patch` — drops `&& [ "$(id -u)" != 0 ]` from the `Dockerfile` line. It changes an image build input, so it is demonstrated with a rebuild, never `--reuse-image` (`docs/testing.md`, *Known-bad demonstrations*; `tests/integration/demonstrate-needs-rebuild.sh --dry-run` should list it).

The spec's "root daemons' `/proc/<pid>/environ`" check is covered differently, because it needs restricted mode and `netadmin`: `TMPDIR` can reach a root process only through `docker run -e` (Task 3 asserts the launcher never passes it) or the profile script (this case's root login shell). The spec's "Claude Code's temp folder resolves under `/var/tmp`" needs a logged-in Claude session in CI and is not automated; it rests on the code reading recorded in the spec.

**Interfaces:**
- Consumes: `launcher_prepare`, `launcher_conf`, `launcher_up open`, `agent_exec_login`, `agent_exec`, `sandbox_down`, `assert_host_file_exists`, `IT_LAUNCH_HOME`, `IT_LAUNCH_HOME_IN` from `tests/integration/lib.sh`.

- [ ] **Step 1: Write the case.** `AI_CONTAINER_GROUP=scratch`, container A:

```bash
t1="$(agent_exec_login "$IT_CID" 'printf %s "$TMPDIR"')"
# [[ "$t1" =~ ^/var/tmp/[0-9]{6}-[0-9]{6}-[0-9]+$ ]]           "the agent's login shell has TMPDIR in its own /var/tmp folder"
# agent writes "$t1/a", "$HOME/.cache/it/b", "$HOME/.local/state/it/c"
# the three exist under $IT_LAUNCH_HOME/.ai-containers/scratch/{.var-tmp/<slot>,.cache/it,.local/state/it}   "… on the host"
# docker exec (root) bash -lc 'printf %s "${TMPDIR-unset}"' == unset                       "a root login shell gets no TMPDIR"
sandbox_down "$IT_CID"
# container B, same group: all three readable at the same absolute paths                  "they survive into the next container"
# B's TMPDIR != t1                                                                          "the next container gets a folder of its own"
```

- [ ] **Step 2: Run it on a fresh image** (Task 4 changed the Dockerfile, so do not `--reuse-image` an older one):

Run: `tests/integration/run.sh --cases 520-agent-files-persist-across-restart`
Expected: PASS.

- [ ] **Step 3: See each mutation fail it**

```bash
tests/integration/mutate.sh apply 520-var-tmp-not-mounted
tests/integration/run.sh --reuse-image --cases 520-agent-files-persist-across-restart   # expect FAIL
tests/integration/mutate.sh revert
```

Same for `520-cache-not-mounted` and `520-state-not-mounted`. For `520-tmpdir-for-root`, apply it and run without `--reuse-image` (a rebuild), expect FAIL on "a root login shell gets no TMPDIR", revert, and rebuild once more before anything else uses the image. Then `bash tests/run-all.sh test-mutations.sh` PASS.

- [ ] **Step 4: Commit** — `test(integration): files an agent writes survive into the next container`

---

### Task 9: Docs, changelog, full verification

**Files:**
- Modify: `AGENTS.md` — *Host directory mounts* (a paragraph: the three mounts, `AI_AGENT_TMPDIR`/`TMPDIR`, per-container folders, pruning, the walk skip, and that `/tmp` and the `/workspace` umbrella still do not survive); the qmd paragraph and the `playwright=` paragraph, which describe the nested mounts
- Modify: `docs/groups.md` (*Group layout*: the three directories; a short *What survives a restart* section, with the warning not to run `git` or `./sandbox.sh` in a repository an agent made there; *Group maintenance*: `list --sizes`), `docs/security.md` (a group is one trust domain: `~/.cache` and `/var/tmp` join `~/.ai-tools`, `~/.gradle`, `~/.m2`), any other page `grep -rn 'cache/qmd\|ms-playwright\|local/state' docs` finds describing the old mounts
- Modify: `CHANGELOG.md` — under `## Unreleased`: `### Added` (persistent `/var/tmp`, `~/.cache`, `~/.local/state`; `TMPDIR`; pruning; `list --sizes`) and `### Changed` (the nested mounts are gone; an image rebuild and `./sync-to-projects.sh` are needed)

- [ ] **Step 1: Write the docs and changelog.**

- [ ] **Step 2: Run everything a host can without Docker**

Run: `bash tests/run-all.sh` then `bash tests/bash-dialect-lint.sh` then `shellcheck sandbox.sh group.sh tests/test-agent-tmp.sh tests/integration/cases/520-agent-files-persist-across-restart.sh`
Expected: `0 failure(s)` from run-all; no lint or shellcheck findings.

- [ ] **Step 3: Commit** — `docs: what survives a container restart`
