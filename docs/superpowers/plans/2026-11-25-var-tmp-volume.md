# `/var/tmp` on a per-group Docker volume — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every container of a group mounts the Docker volume `<prefix>-vartmp-<group>` at `/var/tmp` instead of the host folder `$group/.var-tmp`. The container's own start-up makes the launch's temp folder and prunes old ones, as the agent's user.

**Architecture:**
- **Launcher.** `sandbox.sh` ensures a labelled volume, mounts it, and passes the running containers' folder names (from `docker ps`) in `AI_AGENT_TMP_RUNNING`.
- **Start-up.** `entrypoint.sh` gains one step, `setup_agent_tmp`. It resets the volume's top folder as root, then runs a new baked script, `agent-tmp.sh`, as the sandbox user with an empty environment. The script prunes by change time and makes the folder.
- **`group.sh`** treats the temp volume as a second group volume beside the Ruby one.

**Tech Stack:** bash ≥ 5.1, Docker, GNU and BSD coreutils/findutils; the hermetic suite (`tests/run-all.sh`) and the integration corpus (`tests/integration/run.sh`).

**Spec:** `docs/superpowers/specs/2026-11-25-var-tmp-volume-design.md` (approved 2026-11-25). Read it before your task; this plan cites it as "the spec".

## Global Constraints

- **Names.** Volume `<prefix>-vartmp-<group>`, where `<prefix>` is `$repo_volume_prefix` (`REPO_VOLUME_PREFIX`, default `ai-containers`) and the group goes through `sanitize_volume_token`, exactly as `rvm_volume_name()` builds the Ruby one.
- **Labels.** `ai-containers.vartmp-group=<group>`, plus `ai-containers.owner=<id>` when `ai_containers_owner_id` answers. A temp volume is recognised by the `ai-containers.vartmp-group` label only, never by its name alone.
- **Folders.** The folder-name form is `^[0-9]{6}-[0-9]{6}-[0-9]+$`; folders are made `mkdir -m 0700`, never `-p`. "Untouched for 30 days" means no change time (ctime) newer than 30 days (2592000 s, 43200 min), for the folder or anything in it.
- **Bounds.** A start lists at most 500 old candidates and checks or removes at most 50. Only folders owned by the script's own uid are candidates.
- **Fixed PATH** for the start-up script: `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
- **Bash and portability.** Bash floor 5.1, enforced by `./tests/bash-dialect-lint.sh`. `agent-tmp.sh` must run under GNU and BSD userland alike, because the hermetic suite runs on macOS.
- **Citations.** Code is cited as `<file>: \`snippet\``, never by line number; `tests/test-code-references.sh` checks every citation. Any task that removes or renames a cited function fixes the citations it breaks in the same commit.
- **Lint.** shellcheck is a gate, run with `-S warning -e SC1091` (`PHASES=7 bash ./verify-on-host.sh`). If shellcheck isn't installed, run `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.9.0 -S warning -e SC1091 <files>`.
- **Seen failing.** Every new integration assertion has a patch under `tests/integration/mutations/` that turns it red. Every new hermetic assertion that guards a rule is demonstrated by damaging the line it covers, seeing it go red, then restoring; say so in the task report.
- **Falsify map.** `tests/falsify/targets.conf` is checked by `tests/test-falsify-targets.sh`. New executed code gets its row or function.
- **Docs.** `AGENTS.md` is the only instruction file; never edit its symlinks. `CHANGELOG.md` changes only in Task 7.
- **Commits.** One per task, ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus

1. **Two projects in one group with different `SANDBOX_UID`.** Each start makes its own folder and prunes only its own uid's. Neither start fails or warns about the other's folders. Test: Task 1, a fake `id` reporting another uid.
2. **`docker ps` returns a label value that is not a folder name** (another tool's container, a value with a space, `/` or `..`). It is dropped and never reaches a path. Tests: Task 1, the script ignores it; Task 3, the launcher drops it.
3. **A volume of the right name made outside a launch** (the docs' `docker run -v` recipe run first, or a mistyped group). The launch is refused with a message naming `docker volume rm <name>`; nothing is mounted. Test: Task 2.
4. **An old `$group/.var-tmp` from the bind version.** Every launch names it and how to copy from it. The copy command, run as printed, lets the next start use `/var/tmp` normally, and nothing is deleted. Tests: Task 3 (hermetic note) and Task 6 (case 525, end to end).
5. **The launch's folder name already exists in the volume.** The start goes on, with a `WARNING:`, and the shell keeps `/tmp`; the existing folder is never adopted. Tests: Task 1 (exit code) and Task 4 (`AI_AGENT_TMPDIR` unset).

---

### Task 1: `agent-tmp.sh`, the start-up's pruning and folder

**Files:**
- Create: `agent-tmp.sh`
- Modify: `Dockerfile` (COPY it beside `start-services.sh` and add it to that `chmod +x` line), `shared-files.sh` (add `agent-tmp.sh` to `AI_CONTAINERS_SHARED_FILES`), `tests/falsify/targets.conf` (row `agent-tmp.sh|EXECUTED-WHOLE|test-agent-tmp.sh`)
- Test: `tests/test-agent-tmp.sh`. Add a new section at the end. The launcher sections already there stay until Task 3.

**Interfaces:**
- Produces: `agent-tmp.sh <dir> <slot> <running> [--now <epoch>]`
  - `<dir>` is `/var/tmp` in the container, a temp folder in tests.
  - `<slot>` is the launch's folder name.
  - `<running>` is `?` (unknown: prune nothing) or a space-separated list of names in use (may be empty).
  - `--now` is the clock, for tests only; default is the real time. Never read from the environment.
  - Exit 0: folder made. Exit 1: not made, after a `WARNING:` on stderr. Exit 2: usage error. Pruning never changes the exit code.
  - Prints `NOTE:` and `WARNING:` lines on stderr only.

- [ ] **Step 1: Write the failing tests** in a new section `# ── agent-tmp.sh, run directly ──`. Run the script as `bash "$REPO_DIR/agent-tmp.sh" "$D" "$SLOT" "$RUN" --now "$NOW"` against `D="$(mktemp -d)"`.
  - **Clock.** Change time cannot be set back. Make every "old" item first, record `T=$(date +%s)`, `sleep 2`, then make the "recent" items, and pass `--now $((T + 1 + 2592000))`. Everything made before `T+1` is then over 30 days old and everything after is recent. Sections with no recent item pass `--now $(( $(date +%s) + 2592000 + 60 ))`.
  - **Assertions**, one `check` each:
    - an old folder `200101-000000-1` is removed, and stderr has `NOTE: removed 1 temp folder(s) of stopped containers, untouched for 30 days, from $D (` … `freed).`
    - a folder named in `<running>` is kept, however old
    - `<running>` = `?` removes nothing and still makes the folder (exit 0)
    - a folder holding a recently changed file is kept, and is touched (its own ctime is now after `T+1`). Make `200101-000000-4/sub/f` before `T`, and after the sleep append to `f`. Appending changes `f`'s ctime but not the folder's, so the folder is still listed as old and the inner check is what keeps it. Adding a new file would change the folder's own ctime, and the inner check would never run.
    - names of another form (`200101-000000-1x`, `notes`, a file `200101-000000-2`, a link `200101-000000-3 -> elsewhere`) are kept, and the link's target is untouched
    - **only folders of the script's own uid are candidates:** with a fake `id` on PATH printing `4242` for `id -u`, nothing is removed
    - 60 old folders: one run removes 50, and stderr has `NOTE: 10 more old temp folder(s) in $D are left for the next launch.`; a second run removes the other 10 and prints no `more old temp` line
    - 600 old folders: one run removes 50 and the note says `at least 450 more`
    - a folder `rm` cannot remove (fake `rm` on PATH refusing paths under `$D/`) gives `NOTE: could not remove $D/<name>; it is kept, and checked again in 30 days.` and is touched
    - the launch's own `<slot>` is never removed, even when it exists and is old (then exit 1, see below)
    - **folder made:** exit 0, `$D/$SLOT` exists with mode `700` (`p_stat_mode` from `tests/portability.sh`)
    - **an existing `$D/$SLOT`:** exit 1, a `WARNING:` naming `$D/$SLOT`, and the folder's content is untouched
    - **a `<slot>` not of the folder-name form** (`../x`, `a b`, empty): exit 1, a `WARNING:`, nothing made outside `$D`
    - **`<running>` holding a non-name** (`../200101-000000-1`, `x y`): ignored, so an old `200101-000000-1` is still removed
    - fewer than 3 positional arguments: exit 2

- [ ] **Step 2: Run them to see them fail**

Run: `bash tests/test-agent-tmp.sh 2>&1 | grep -c '^FAIL'`
Expected: every new check fails (`agent-tmp.sh` does not exist); the existing launcher checks still pass.

- [ ] **Step 3: Write `agent-tmp.sh`.** Port `agent_tmp_prune()` from `sandbox.sh`, keeping its comments' reasoning, with these differences:
  - **The listing.** One `find -P "$dir" -mindepth 1 -maxdepth 1` with the same two `-name` tests, `-type d -user "$(id -u)"`, and `! -cnewer "$ref"`, read with `mapfile -d '' -n 501`.
  - **The reference file** is made in the container's own temp, by `mktemp` (`TMPDIR` is unset, so `/tmp`), with mtime `now - 2592000`. Set the mtime with `touch -t "$(printf '%(%Y%m%d%H%M.%S)T' "$((now - 2592000))")"`. Bash's strftime and `touch -t` agree under GNU and BSD alike. Remove the file on exit.
  - **The "recent content" check** becomes `find -P "$d" -cnewer "$ref" -print -quit`.
  - **Liveness** comes from `<running>` (`?` means return before listing), not from `docker ps`.
  - **`<slot>` is excluded** from the candidates.
  - **The NOTE texts are unchanged**, with `$dir` in them.
  - **After pruning**, `mkdir -m 0700 -- "$dir/$slot"`. On failure print `WARNING: cannot create $dir/$slot; the shell keeps /tmp as its TMPDIR.` and exit 1.
  - **Validation:** validate `<slot>`, and every `<running>` entry, against the folder-name regex before any use. Use `set -uo pipefail`, but not `-e`: pruning must never abort the folder step.
  - **Header comment:** why it runs in the container as the agent's user (the spec's *Approaches*, B), and why ctime (the spec's *Second change*).

- [ ] **Step 4: Run the tests until they pass**

Run: `bash tests/test-agent-tmp.sh`
Expected: `ALL PASS`

Then run `bash tests/test-falsify-targets.sh` and `bash tests/test-shared-files-parity.sh`; both must pass.

- [ ] **Step 5: Demonstrate.** Damage each of these, see its check go red, then restore:
  - the `-user` test
  - `! -cnewer`
  - the `?` early return
  - the cap of 50

- [ ] **Step 6: Lint and commit**

```bash
git add agent-tmp.sh Dockerfile shared-files.sh tests/falsify/targets.conf tests/test-agent-tmp.sh
git commit -m "feat(image): agent-tmp.sh prunes old temp folders by change time and makes the launch's own"
```

---

### Task 2: The temp volume helpers in `sandbox-common.sh`

**Files:**
- Modify: `sandbox-common.sh`, beside the Ruby volume helpers after `rvm_volume_ensure()`
- Create: `tests/test-vartmp-volume.sh`, using a fake docker modelled on `tests/test-rvm-volume.sh`'s, with labels stored per volume

**Interfaces:**
- Consumes: `repo_volume_prefix`, `sanitize_volume_token`, `volumes_named`, `docker_volume_label`, `ai_containers_owner_id`, `_rvm_shared_note`.
- Produces:
  - `vartmp_volume_name <group>`: prints `<prefix>-vartmp-<token>`.
  - `vartmp_volumes`: prints every volume whose name starts `<prefix>-vartmp-`, one per line, labelled or not.
  - `vartmp_group_from_volume <volume>`: prints the `ai-containers.vartmp-group` label, or nothing. There is no fallback to the name.
  - `vartmp_volume_ensure <group>`: prints the volume name and returns 0, or prints an `ERROR:` to stderr and returns 1.
  - `_group_volume_shared_note <volume> <group> <kind>`, where `<kind>` is `ruby` or `temp`. `_rvm_shared_note <volume> <group>` becomes a one-line wrapper calling it with `ruby`, and its text stays byte-identical.

- [ ] **Step 1: Write the failing tests** in `tests/test-vartmp-volume.sh` (`set -uo pipefail`, `HOME` set to a temp folder before sourcing `sandbox-common.sh`, the `pass`/`fail`/`check` helpers of the sibling tests, ending `ALL PASS` or exit 1):
  - `vartmp_volume_name docs` is `ai-containers-vartmp-docs`; with `REPO_VOLUME_PREFIX=pfx` it is `pfx-vartmp-docs`; an unsafe group token is sanitised as `rvm_volume_name` sanitises it
  - **a missing volume:** `vartmp_volume_ensure docs` prints the name, returns 0, and the fake recorded one `volume create` carrying `--label ai-containers.vartmp-group=docs` and `--label ai-containers.owner=<id>`
  - **an existing volume labelled `docs`:** returns 0 and creates nothing
  - **an existing volume with no label:** returns 1, prints nothing on stdout, and stderr has an `ERROR:` naming the volume and `docker volume rm ai-containers-vartmp-docs`
  - **an existing volume labelled `other`:** returns 1, and the `ERROR:` names group `other`
  - **an inspect that fails without `no such volume`** (docker down): returns 1 with `ERROR: docker could not say whether ai-containers-vartmp-docs exists`
  - **a create that fails:** returns 1 with an `ERROR:`
  - **another home's volume** (owner label differs): returns 0, and stderr has the shared-volume `NOTE:` naming the temp volume
  - **`_rvm_shared_note`'s output is unchanged:** compare it against the text in `tests/test-rvm-volume.sh`
  - **isolation:** with volumes `ai-containers-repo-app`, `ai-containers-rvm-docs` and `ai-containers-vartmp-docs` present, `vartmp_volumes` lists only the last; `rvm_volumes` and `repo_base_volumes` do not list it
  - `vartmp_group_from_volume` round-trips the label and prints nothing for an unlabelled volume

- [ ] **Step 2: Run them to see them fail**

Run: `bash tests/test-vartmp-volume.sh`
Expected: FAIL (the functions are undefined)

- [ ] **Step 3: Implement the five functions.**
  - `vartmp_volume_ensure` inspects first, with `docker volume inspect --format '{{if .Labels}}{{index .Labels "ai-containers.vartmp-group"}}{{end}}' <name>`, keeping stdout and stderr apart.
  - If the inspect succeeds, compare the label with `<group>`.
  - If it fails and its stderr, lowercased, contains `no such volume`, create the volume with the labels, the same way `rvm_volume_ensure()` builds them.
  - Any other failure refuses.
  - The `ERROR:` for a wrong or missing label says three things: the volume was made outside a launch (by a `docker run -v`, or for another group); a launch cannot use it, because `group.sh` would never see it; and `docker volume rm <name>` clears the way once nothing in it is needed.
  - Comment the label-only rule with the REPO-11 reason (the spec's *The volume*).

- [ ] **Step 4: Run tests**

Run: `bash tests/test-vartmp-volume.sh && bash tests/test-rvm-volume.sh`
Expected: `ALL PASS` from both

- [ ] **Step 5: Demonstrate** the label comparison and the `no such volume` branch: damage each, see its check go red, restore.

- [ ] **Step 6: Lint and commit**

```bash
git add sandbox-common.sh tests/test-vartmp-volume.sh
git commit -m "feat(launcher): helpers for a group's labelled /var/tmp volume"
```

---

### Task 3: The launcher mounts the volume

**Files:**
- Modify: `sandbox.sh`
- Create: `tests/lib-fake-docker-volume.sh`
- Modify: `tests/test-agent-tmp.sh` (rewrite the launcher sections), `tests/test-launcher-dir-ro.sh` (T93), every hermetic test whose fake docker lets a launch reach `docker run` (Step 4), `AGENTS.md` (only the citations the removals break)

**Interfaces:**
- Consumes: `vartmp_volume_ensure`, `vartmp_volume_name` (Task 2).
- Produces:
  - **The container gets** `-v <volume>:/var/tmp`, `-e AI_AGENT_TMPDIR=/var/tmp/<slot>` (unchanged) and `-e AI_AGENT_TMP_RUNNING=<value>`. The value is `?` when `docker ps` failed; otherwise the space-separated names of the running containers' `ai-containers.tmpslot` labels that have the folder-name form, possibly empty.
  - **`tests/lib-fake-docker-volume.sh <state-dir> volume <sub> [args…]`** is a script a test's fake docker hands its `volume` calls to. It implements `create` (records labels, prints the name), `inspect` (`--format` with `index .Labels "<key>"`, or `no such volume` on stderr and exit 1), `rm` and `ls` (`--filter name=`). Its state lives in `<state-dir>`.

- [ ] **Step 1: Write the failing launcher tests** in `tests/test-agent-tmp.sh`:
  - **Remove** the old prune, touch and folder sections: everything from `# ── the launch's own folder` and the `old_slot`/`touched` prune cases. Task 1 now covers those rules.
  - **Fake docker:** hand `volume` calls to `tests/lib-fake-docker-volume.sh "$TMP/volumes"`; keep the `ps` answer to the exact `docker ps --filter label=ai-containers.tmpslot --format '{{.Label "ai-containers.tmpslot"}}'` query.
  - **Checks:**
    - `/var/tmp` is mounted from the volume: the capture has `-v`, then `ai-containers-vartmp-default:/var/tmp`
    - the volume was created with `ai-containers.vartmp-group=default`
    - no `$GROUP_ROOT/.var-tmp` is made, and no capture line ends `:/var/tmp:rw`
    - `AI_AGENT_TMP_RUNNING=` is passed, empty, with no container running
    - with `FAKE_RUNNING_SLOTS=$'200101-000000-1\n../x\nx y\n200101-000000-2'` it is exactly `AI_AGENT_TMP_RUNNING=200101-000000-1 200101-000000-2`
    - with `FAKE_PS_FAIL=1` it is `AI_AGENT_TMP_RUNNING=?`
    - `docker ps` is asked on every launch
    - a `container.env` line `AI_AGENT_TMP_RUNNING=x` is refused with a `WARNING:`, as `AI_AGENT_TMPDIR` already is
    - an unlabelled volume of that name refuses the launch: non-zero exit, no `docker run`, the `ERROR:` on stderr
    - with `$GROUP_ROOT/.var-tmp/200101-000000-1/f` present, the launch goes on, and stderr has a `NOTE:` naming `$GROUP_ROOT/.var-tmp`, the line `rm -rf $GROUP_ROOT/.var-tmp`, and a `docker run` line holding `-v $GROUP_ROOT/.var-tmp:/src:ro` and `-v ai-containers-vartmp-default:/dst`; the folder and its file are still there
    - without `$GROUP_ROOT/.var-tmp`, no such `NOTE:`
  - **Keep** the existing checks: the slot form, the 30-byte `TMPDIR` length, the `tmpslot` label, `TMPDIR` never passed, a slot per launch.

- [ ] **Step 2: Run them to see them fail**

Run: `bash tests/test-agent-tmp.sh`
Expected: the new launcher checks FAIL

- [ ] **Step 3: Change `sandbox.sh`.**
  - **Mounts.** Where it now runs `install -d "$group_root/.var-tmp"` and binds it, call `vartmp_volume_ensure "$group"`. Exit 1 if it fails; otherwise add `-v "$vol:/var/tmp"` to `config_mount_flags`.
  - **The old folder.** If `$group_root/.var-tmp` exists or is a link, print the `NOTE:`. Its first line: `NOTE: <path> is no longer mounted: /var/tmp is now the Docker volume <vol>.` Then the copy command, `docker run --rm --pull=never ${selinux_opt} --entrypoint cp -v <path>:/src:ro -v <vol>:/dst <image> -a /src/. /dst/`, and then `rm -rf <path>`, to run once nothing in it is needed and no container of the group runs. Quote the paths with `_q`, as the neighbouring messages do.
  - **The running list.** Where `agent_tmp_slot` is set, compute the list (one `docker ps`, the regex filter, `?` on failure), and add `-e AI_AGENT_TMP_RUNNING="$list"` to `launcher_env` next to `AI_AGENT_TMPDIR`.
  - **Remove:**
    - `agent_tmp_prune()` and its call
    - the host `mkdir` block
    - `_agent_tmp_made`
    - `_agent_tmp_touch()`, its call after `docker run`, and its call in the `EXIT` trap
    - the `.var-tmp` alternative in `_group_scratch_mount()`, and update that function's comment to two folders
  - **The comment above the mount** says why it is a volume: the tar `..` placeholder on virtiofs, citing the Ruby volume's note in `sandbox-common.sh`.

- [ ] **Step 4: Teach the other fakes the volume.**
  1. Write `tests/lib-fake-docker-volume.sh`.
  2. Run `./tests/run-all.sh`.
  3. In every test that now fails because a launch was refused or its fake mishandled `docker volume`, add one line before the fake's own handling: `[[ "\$1" == volume ]] && exec bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$TMP/volumes" "\$@"`. Use the test's own temp folder variable.
  4. A fake that already implements `volume` (repo, project, rvm tests) keeps its own code and gains only what the temp volume needs.

  The likely set is the launch-driving tests: `test-container-name`, `test-mode-capabilities`, `test-mode-output-mounts`, `test-env-file`, `lib-git-internals-ro`, `test-launcher-dir-ro`, `test-tool-config-mounts`, `test-skill-char-budget`, `test-docs-path`, `test-architecture-path`, `test-repos-path`, `test-host-binds`, `test-selinux-label`, `test-sandbox-env`, `test-sandbox-schema`, `test-tools-d`, `test-playwright`, `test-postgres`, `test-mysql`, `test-mariadb`, `test-mongo`, `test-redis`, `test-agent-tools-reconcile`, `test-rvm-volume`. The suite decides, not this list.

- [ ] **Step 5: Update T93 in `tests/test-launcher-dir-ro.sh`.**
  - The launcher-walk skip now covers `~/.cache` and `~/.local/state` only. Drop the `.var-tmp` launcher from the first T93 check.
  - Move the G92 control (`EXTRA_MOUNTS` of a group folder) and the "running launcher inside a group folder" check from `.var-tmp` to `.local/state`, with destination `/home/tester/.local/state/...`.
  - Rename the checks to say "~/.cache or ~/.local/state".

- [ ] **Step 6: Run the whole suite**

Run: `./tests/run-all.sh`
Expected: `0` failures. Also `bash tests/test-code-references.sh` passes; fix any `AGENTS.md` citation of a removed function by naming what replaced it, and leave prose rewrites to Task 7.

- [ ] **Step 7: Demonstrate** the regex filter on the running list and the `?` on a failed `docker ps`: damage each, see its check go red, restore.

- [ ] **Step 8: Lint and commit**

```bash
git add sandbox.sh tests/ AGENTS.md
git commit -m "feat(launcher): /var/tmp is the group's Docker volume; the start-up makes and prunes the folders"
```

---

### Task 4: The start-up step in `entrypoint.sh`

**Files:**
- Modify: `entrypoint.sh`, `Dockerfile` (the comment above the profile script that says "the per-container folder the launcher made"; it is now made by the start-up), `tests/falsify/targets.conf` (add `setup_agent_tmp` to `entrypoint.sh`'s function list)
- Test: `tests/test-entrypoint-wiring.sh`

**Interfaces:**
- Consumes: `agent-tmp.sh <dir> <slot> <running>` (Task 1); `AI_AGENT_TMPDIR` and `AI_AGENT_TMP_RUNNING` from the launcher (Task 3); `_user_step` and `sandbox_user` from `entrypoint.sh`.
- Produces: `setup_agent_tmp()`, called in all three modes after `setup_sandbox_user` and `chown_workspace_root`, just before `chown_rvm_root`. It always returns 0.

- [ ] **Step 1: Write the failing tests.** Extract `setup_agent_tmp` by name, as the `run_services` section does: with `awk`, the script path `/usr/local/bin/agent-tmp.sh` replaced by a fake that records its arguments and `env`, `runuser` and `setpriv` stubbed, and `chown`/`chmod` stubbed to record their arguments. Run it under `set -euo pipefail`, then check:
  - **variable unset:** with `AI_AGENT_TMP_RUNNING` unset (even with `AI_AGENT_TMPDIR=/var/tmp/200101-000000-1`), no `chown`, no `chmod` and no script run, and it returns 0
  - **variable set but empty:** `chown root:root /var/tmp` and `chmod 1777 /var/tmp` were run, on that path only, with no `-R`
  - **the script's arguments:** exactly `/var/tmp 200101-000000-1 <the running value>`
  - **the script's environment:** exactly `PATH` (the fixed value), even with `_aice_app_env=(APP=1)` and `APP=1` exported, plus whatever a shell adds itself (filter `PWD|OLDPWD|SHLVL|_`, as the `run_services` section does)
  - **the drop:** the script ran through the RT-8 setpriv (`--bounding-set=-net_admin,-net_raw --no-new-privs`) and `runuser -u <sandbox user> --`
  - **when the fake script exits 1:** `AI_AGENT_TMPDIR` is unset afterwards and the function still returns 0; when it exits 0, `AI_AGENT_TMPDIR` is kept
  - **an `AI_AGENT_TMPDIR` outside `/var/tmp/`** (`/etc/x`): the script is given an empty `<slot>`. The real script refuses that (Task 1); here, check only the argument.
  - **`AI_AGENT_TMP_RUNNING` is unset after the step** in every case
  - **wiring:** `setup_agent_tmp` is called in each of the three mode blocks, before `run_services` (the same `awk` block extraction the banner check uses)

- [ ] **Step 2: Run them to see them fail**

Run: `bash tests/test-entrypoint-wiring.sh`
Expected: the new checks FAIL

- [ ] **Step 3: Implement `setup_agent_tmp()`** in `entrypoint.sh`, next to `chown_rvm_root`, with a comment carrying the spec's steps 1 to 3 and their reasons:
  - **Gate:** do nothing unless `AI_AGENT_TMP_RUNNING` is set (`${AI_AGENT_TMP_RUNNING+x}`).
  - **Root part:** `chown root:root /var/tmp` and `chmod 1777 /var/tmp`, failures ignored.
  - **User part:** `"${_user_step[@]}" runuser -u "$sandbox_user" -- env -i PATH=<fixed> bash /usr/local/bin/agent-tmp.sh /var/tmp "<slot>" "$AI_AGENT_TMP_RUNNING"`, where `<slot>` is `${AI_AGENT_TMPDIR#/var/tmp/}` when `AI_AGENT_TMPDIR` starts with `/var/tmp/`, and empty otherwise. Use `runuser` directly, not `as_sandbox_user`, which hands `container.env` back.
  - **After the script:** on a non-zero exit, `unset AI_AGENT_TMPDIR`. Then always `unset AI_AGENT_TMP_RUNNING`.
  - **Wiring:** add the call to the three mode blocks.

- [ ] **Step 4: Run tests**

Run: `bash tests/test-entrypoint-wiring.sh && bash tests/test-falsify-targets.sh && bash tests/test-profile-scripts.sh`
Expected: all pass

- [ ] **Step 5: Demonstrate** the gate, `env -i`, and the unset on failure: damage each, see its check go red, restore.

- [ ] **Step 6: Lint and commit**

```bash
git add entrypoint.sh Dockerfile tests/test-entrypoint-wiring.sh tests/falsify/targets.conf
git commit -m "feat(image): the start-up makes the launch's /var/tmp folder and prunes old ones as the agent"
```

---

### Task 5: `group.sh` knows the temp volume

**Files:**
- Modify: `group.sh` (the header comment, `usage`, `cmd_list`, `cmd_rm`, `cmd_gc`)
- Test: `tests/test-group-lifecycle.sh`

**Interfaces:**
- Consumes: `vartmp_volume_name`, `vartmp_volumes`, `vartmp_group_from_volume` (Task 2), and the existing `_vol_owner_why`, `_vol_busy`, `volume_size`.
- Produces: the user-visible behaviour in the spec's *`group.sh`* section. Factor the per-volume logic (owner, busy, state) into helpers taking a volume name, used for both the Ruby and the temp volume; don't duplicate it.

- [ ] **Step 1: Write the failing tests** in `tests/test-group-lifecycle.sh`. Its fake docker stores a volume's labels in `<name>.labels`; create temp volumes with `ai-containers.vartmp-group=<g>` and an owner label.
  - **`list`:**
    - the header has the columns `GROUP`, `RVM VOLUME`, `STATE`, `TEMP VOLUME`, `STATE`
    - a group with both volumes shows both names and `present`
    - `(in use)` is shown for a temp volume a fake running container mounts
    - `--sizes` shows a size column for each volume
  - **`list` orphans:** an orphaned temp volume (label for a group with no directory) is listed under the orphans heading; an unlabelled `ai-containers-vartmp-x` is not listed anywhere
  - **`rm <g>`:**
    - removes the directory and both volumes
    - with only the temp volume in use, it refuses, and the directory and both volumes remain
    - a temp volume another home made is kept and named, and the Ruby volume and directory go
    - an unlabelled `ai-containers-vartmp-<g>` is named with `docker volume rm ai-containers-vartmp-<g>` and still exists afterwards
    - a group with only a temp volume and no directory or Ruby volume is still found and removed
  - **`gc`:**
    - collects an orphaned temp volume of this home
    - keeps another home's unless `--all`
    - skips one in use
    - "Nothing to collect" when every temp and Ruby volume has its group directory
  - **`usage` text:** names the temp volume
  - **Update the existing assertions** whose exact text changes (the `list` header, the gc messages), and keep every existing behaviour check.

- [ ] **Step 2: Run them to see them fail**

Run: `bash tests/test-group-lifecycle.sh`
Expected: the new checks FAIL

- [ ] **Step 3: Implement.** Keep the text of the existing messages except where they must name both volumes ("rvm volume" becomes "Ruby volume" / "temp volume" only in lines that now cover both). `rm` checks every volume it will remove for busy or unknown before deleting anything, as it does now for one.

- [ ] **Step 4: Run tests**

Run: `bash tests/test-group-lifecycle.sh && bash tests/test-rvm-volume.sh`
Expected: all pass

- [ ] **Step 5: Demonstrate** the temp volume's in-use refusal in `rm` and the label filter in `gc`: damage each, see its check go red, restore.

- [ ] **Step 6: Lint and commit**

```bash
git add group.sh tests/test-group-lifecycle.sh
git commit -m "feat(group.sh): list, rm and gc a group's temp volume beside its Ruby volume"
```

---

### Task 6: Integration cases

**Files:**
- Modify: `tests/integration/lib.sh` (`launcher_prepare` scopes the volume prefix), `tests/integration/cases/520-agent-files-persist-across-restart.sh`, `610-group-rm-removes-both.sh`, `620-group-gc-collects-orphan.sh`, `tests/integration/mutations/520-var-tmp-not-mounted.patch`
- Create: `tests/integration/cases/525-old-var-tmp-named-and-copyable.sh`, plus mutations `520-var-tmp-bind.patch`, `520-tmp-folder-made-by-root.patch`, `525-old-var-tmp-not-named.patch`, `525-var-tmp-top-not-reset.patch`, `610-group-rm-keeps-temp-volume.patch`, `620-gc-ignores-temp-volume.patch`
- Test: `tests/test-integration-lib.sh`, `tests/test-mutations.sh`

**Interfaces:**
- Consumes: everything above. Cases read the launcher's stderr through `$IT_LAUNCH_ERR` and the container's start-up output through `docker logs`.

- [ ] **Step 1: Scope the prefix.**
  - `launcher_prepare` exports `REPO_VOLUME_PREFIX="it-$IT_RUN_ID"` unconditionally, before its early return, so every case's launches create `it-<run>-vartmp-<group>`: never a developer's real `ai-containers-vartmp-default`, which a case would otherwise mount and prune. The shim labels the volume, and the runner's sweep removes it.
  - Add a check to `tests/test-integration-lib.sh` that `launcher_prepare` exports it even when the caller's shell set another `REPO_VOLUME_PREFIX`.
  - Update the comment above `fixture_scope_init`.

- [ ] **Step 2: Case 520.**
  - Drop `assert_host_file_exists "$group_dir/.var-tmp/$slot/a"`; the existing cross-container byte check covers persistence.
  - **Add**, against container A:
    - `docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/tmp"}}{{.Type}} {{.Name}}{{end}}{{end}}' "$cid_a"` equals `volume it-$IT_RUN_ID-vartmp-scratch`
    - `stat -c '%a %u' "$t1"`, run as the agent, is `700 <launch uid>`
    - as the agent, in a login shell: `cd "$TMPDIR" && mkdir -p s/a/b s/x && ln -s ../../x s/a/b/l && tar -C s -cf t.tar a x && mkdir u && tar -C u -xf t.tar && test -L u/a/b/l` succeeds (the Mac's failure)
  - Update the header comment: the volume, why, and that the tar check can go red only on a Mac (case 460's precedent).
  - **Mutations:**
    - update `520-var-tmp-not-mounted.patch` to drop the `-v "$vol:/var/tmp"` line
    - `520-var-tmp-bind.patch` restores the old host bind instead of the volume
    - `520-tmp-folder-made-by-root.patch` makes the folder as root in `setup_agent_tmp`
    - each names the assertion it turns red in its `what:` line

- [ ] **Step 3: Case 525** (`tags: groups fast`, `requires: docker launcher`).
  1. Before the first launch, make `$IT_LAUNCH_HOME/.ai-containers/<g>/.var-tmp/200101-000000-1/f` holding `old`.
  2. **Launch 1:** `$IT_LAUNCH_ERR` names the folder in the `NOTE:` and holds the copy command; the folder is still on the host.
  3. **Copy:** stop the container, run the copy command exactly as printed (taken from `$IT_LAUNCH_ERR`).
  4. **Damage the top folder:** run `docker run --rm -v <vol>:/v --entrypoint chmod <image> 0755 /v` as root, so it is closed to the agent.
  5. **Launch 2:** the agent reads `old` from `/var/tmp/200101-000000-1/f`, and its login shell's `TMPDIR` is its own new folder. That works only because the start-up reset the top folder to `1777`.
  6. **Mutations:** `525-old-var-tmp-not-named.patch` drops the `NOTE:`; `525-var-tmp-top-not-reset.patch` drops the `chown`/`chmod` in `setup_agent_tmp`.

- [ ] **Step 4: Cases 610 and 620.**
  - `make_group` also creates `it-$IT_RUN_ID-vartmp-<g>` with `ai-containers.vartmp-group=<g>` and the owner label, the same way 620 makes its Ruby volume.
  - 610 asserts `group.sh rm` removes it, and keeps it while a container mounts it.
  - 620 asserts `gc` collects an orphaned one.
  - Mutations: `610-group-rm-keeps-temp-volume.patch` and `620-gc-ignores-temp-volume.patch`.

- [ ] **Step 5: Run on this host's docker**

Run: `./tests/integration/run.sh --cases 520-agent-files-persist-across-restart,525-old-var-tmp-named-and-copyable,610-group-rm-removes-both,620-group-gc-collects-orphan`
Expected: every case PASS, no SKIP.

Then, for each new or changed patch: `./tests/integration/mutate.sh apply <patch name without .patch>`, then `./tests/integration/run.sh --reuse-image --cases <its case>`, then `./tests/integration/mutate.sh revert`.
Expected: the case it names goes red. The `520-var-tmp-bind.patch` tar assertion stays green on Linux; say so in the report.

Then: `bash tests/test-mutations.sh && bash tests/test-integration-lib.sh && bash tests/test-layer-containment.sh`
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add tests/integration
git commit -m "test(integration): /var/tmp is the group's volume, tar with .. links works there, group.sh owns it"
```

---

### Task 7: Docs and CHANGELOG

**Files:**
- Modify: `AGENTS.md`, `docs/groups.md`, `docs/repos-and-mounts.md`, `docs/troubleshooting.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: the behaviour and exact names from Tasks 1–6. The spec's *Docs* section lists what each file must say.

- [ ] **Step 1: `AGENTS.md`.**
  - In *Host directory mounts*, rewrite the paragraph on the three folders: `/var/tmp` is the group's volume, and why (the tar `..` placeholder, measured on Colima 2026-11-25); the start-up step and `agent-tmp.sh`; the ctime rule and its limit; the `NOTE:` for an old `.var-tmp`; the label-only rule and the refusal; the per-daemon volume. Keep `~/.cache` and `~/.local/state` as binds, with the macOS tar limit stated.
  - Update the launcher-walk sentence (`_group_scratch_mount()`) to two folders.
  - Update *Manage container groups* (a group owns a directory and up to two volumes).
  - In the Ruby volume paragraph, say `/var/tmp` is a volume for the same reason.
  - Cite code by snippet.

- [ ] **Step 2: `docs/groups.md`.**
  - The temp-folder section and its two limits: the several-daemons limit goes, and the ctime limit is added.
  - *Seeing and reclaiming the space*: from a running container of the group (`du -sh /var/tmp/*`, `rm -rf /var/tmp/<name>`), or once the group has launched, `docker run --rm --entrypoint sh -v <prefix>-vartmp-<group>:/v <image> -c 'du -sh /v/*'`, with the warning that running it before the first launch creates the volume unlabelled and the next launch refuses.
  - The macOS tar limit for `~/.cache` and `~/.local/state`.
  - The `group.sh` lines.

- [ ] **Step 3: `docs/repos-and-mounts.md` and `docs/troubleshooting.md`.**
  - The `/var/tmp` table row (now the volume) and its footnote ⁵.
  - "Several homes on one docker" covers the temp volume too.

- [ ] **Step 4: `CHANGELOG.md`.** Fold into the existing Unreleased entry for the persistent folders, which has not shipped. It says that `/var/tmp` is the group's volume `ai-containers-vartmp-<group>`, and why. It says what an existing project needs: `./sync-to-projects.sh` and a rebuild; until the rebuild, `TMPDIR` stays `/tmp` and nothing is pruned. It also covers the ctime rule, the note for an old `.var-tmp`, and `group.sh`.

- [ ] **Step 5: Check**

Run: `bash tests/test-code-references.sh && bash tests/test-docs.sh && ./changelog-coverage.sh`
Expected: pass. Also `git grep -n '\.var-tmp'` outside `docs/superpowers/` and `CHANGELOG.md` finds only the launcher's old-folder `NOTE:` code, its tests, case 525 and the docs that describe that note.

- [ ] **Step 6: Commit**

```bash
git add AGENTS.md docs CHANGELOG.md
git commit -m "docs: /var/tmp is a group's Docker volume"
```

---

## After the plan

The final review runs the whole hermetic suite (`./tests/run-all.sh`), lint (`PHASES=7 bash ./verify-on-host.sh`) and the four integration cases on this host.

The merge is the user's decision. After it:
1. The Mac agent re-runs its tar check in `$TMPDIR`, case 520 and 525, and the hermetic suite, on Colima, and on Docker Desktop if a Mac has it.
2. Then `.superpowers/sdd/2026-11-23-persistent-agent-scratch/` is deleted.
