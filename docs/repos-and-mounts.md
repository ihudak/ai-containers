# Repositories, volumes and mounts

## Mounting additional repositories

Set `EXTRA_MOUNTS` to a space-separated list of host paths. Append `:ro` or `:rw` to control per-directory access. The default is read-write. **Paths with spaces are not supported** (the variable is split on whitespace).

```bash
# backend is the primary workspace; ui is read-write, reference-docs is read-only
EXTRA_MOUNTS="/path/to/myproject-ui /path/to/reference-docs:ro" \
bash ./sandbox.sh restricted /path/to/myproject-backend
```

Each path is mounted at `/workspace/<basename>` inside the container.

> **macOS performance note.** `EXTRA_MOUNTS` (and a host-path positional argument) are host **bind mounts**. On macOS, Docker runs inside a Linux VM and host directories are shared over a virtualized filesystem (virtiofs), which adds a large per-syscall penalty — metadata operations can be ~30–50× slower than native in-VM storage. For small or occasionally-read directories this is fine. For **large repositories that agents scan heavily** (reading thousands of files), use **repo volumes** instead — see the next section. On Linux the bind-mount penalty does not apply.

## Shared repo volumes (native speed) — `repo.sh` and `REPOS`

For big repositories that AI agents inspect repeatedly, host bind mounts are slow on macOS (see the note above). A **repo volume** is a Docker named volume living *inside* the Docker/Colima VM, so containers read it at native in-VM speed. You seed it **once** and then attach it to any number of containers — there is no re-clone or re-copy on each start.

Repo volumes are **global**: there is **one volume per repo name**, shared by containers in *any* project/image and *any* container group (they hold code, not credentials), and tracked in a registry at `~/.ai-containers/repos.conf`. The volume name is image-independent (`ai-containers-repo-<name>`), so you register a repo **once** and attach it to as many containers as you like — across different projects too — with no `IMAGE_NAME` juggling. The physical bytes live in the VM at `/var/lib/docker/volumes/ai-containers-repo-<name>/`, not on the host filesystem. (Set `REPO_VOLUME_PREFIX` to restore the legacy per-image scoping if you ever need it.)

## `repo.sh` — manage repo volumes

```bash
# Seed a repo volume ONCE, from an existing local checkout (fast, no network):
./repo.sh add cluster ~/dev/docs/cluster
# …or by cloning from the remote (authenticates with your host ~/.ssh):
./repo.sh add cluster ssh://git@example.org/team/cluster.git

./repo.sh sync cluster        # refresh ONE repo from its source (git pull, or re-copy a path source)
./repo.sh sync --all          # refresh EVERY registered repo — the usual start-of-day refresh
./repo.sh reset cluster       # clean slate: primary branch at the remote tip, other branches dropped
./repo.sh list                # show repos (add --sizes for on-disk size; --copies for :rwcopy working copies)
./repo.sh rm cluster          # remove the volume + any working copies + registry entry
./repo.sh gc                  # prune :rwcopy working copies (--repo <name>, --unused, --yes)
./repo.sh reindex             # rebuild the registry from volume labels (recover a lost/stale repos.conf)
```

> **Docker volumes are the source of truth; the registry is a cache.** Each base volume is labeled with its repo name, type, and source, and each `:rwcopy` working copy with its parent repo and originating launch directory. `list`, `list --copies`, and `gc` read those labels directly from Docker, so what you see reflects the volumes that actually exist (a registry entry whose volume is gone shows as `MISSING`). The registry at `~/.ai-containers/repos.conf` remains authoritative only for two things labels can't cover: **Linux `bind`-backend repos** (which have no volume to label) and the **mutable last-synced timestamp** (Docker labels are immutable after creation). If the registry is ever lost or out of sync, `./repo.sh reindex` rebuilds it from the volume labels.

> **Managing `:rwcopy` working copies.** `./repo.sh list --copies` shows every working-copy volume with its parent repo, the launch directory it was seeded for, whether a running container currently has it mounted, and (with `--sizes`) its on-disk size. `./repo.sh gc` removes them: all of them by default, or `--repo <name>` to scope to one repo, `--unused` to keep any currently mounted by a running container, and `--yes` to skip the confirmation. Working copies can hold uncommitted work, so `gc` confirms before deleting.

**`sync --all` is the one to remember.** A repo volume does not track its source — it holds whatever was there when you seeded or last synced it (see *Repo volumes shadow the host* below). `./repo.sh sync --all` brings every registered repo up to date in one command: `git pull` for git sources, an `rsync -a --delete` mirror for path sources. Run it when you sit down to work, or after pulling on the host, rather than syncing repos one at a time. It leaves existing `:rwcopy` working copies alone, because they may hold uncommitted work — see the note below on refreshing those.

`reset` is the "start clean" button, and it is a *full* reset rather than a tidy-up of wherever you happen to be standing. For a git source it fetches (pruning), works out the remote's **primary branch**, checks that branch out at the remote's tip, discards uncommitted changes and untracked/ignored files (`clean -ffdx`, so build output and `node_modules` go too), and **deletes every other local branch**. For a path source it re-mirrors from the host source. Either way it removes any `:rwcopy` working copies. Reset every registered repo at once with `./repo.sh reset --all`. (The Linux `bind` backend is left untouched — its "volume" is your live host checkout — and `reset` just prints how to clean it yourself.)

**The primary branch is asked for, never assumed.** It comes from the remote's own `HEAD` (refreshed with `git remote set-head origin -a`, so a default branch renamed since you cloned is picked up), falling back to `origin/main`, then `origin/master`, and finally to whatever is checked out. Nothing hardcodes `main`: a repo whose default is `master`, `trunk`, or `develop` lands on its own default.

**It tells you what it will delete before it deletes it.** Every run — including `--yes` — prints the branch it will switch to and each local branch it will drop, marking those carrying commits that are on **no remote**:

```
About to RESET the following repo(s) to a clean state:
  - app: switches to 'main'
      DELETE feat/parser — 3 commit(s) not on any remote  <-- unpushed work
      DELETE fix/typo — pushed

WARNING: 1 branch(es) above carry commits that are on no remote. Deleting
         them discards those commits. Push them first if you want them.
```

It is **destructive and cannot be undone**, so it prompts for confirmation unless you pass `--yes`. The counts are measured *after* the fetch, so "not on any remote" reflects what the remote has now, not what this volume last saw.

Afterwards it says what it did, one line per branch:

```
Resetting volume "ai-containers-repo-app" to a clean checkout on "master" ...
  removed branch throwaway
  now on master at 3500160
  OK: app reset to a clean state.
```

**If the fetch fails, reset still cleans.** No network, no credentials, or a remote that has gone away leaves you with a warning and a local reset: the tree ends up clean and on the primary branch, at the remote tip **as last fetched**. The final line says `STALE — fetch failed` so you know the slate is clean but not fresh.

`reset` differs from `sync` in what it protects: `sync` is `git pull --ff-only` and keeps your branches and your work; `reset` keeps nothing.

`add` refuses to overwrite an existing repo — use `sync` to refresh or `rm` first. Authentication for `git-url` sources uses your **host `~/.ssh`** (mounted read-only into a short-lived seeding container); local-path sources need no credentials.

> **Seeding does not require the sandbox image.** `repo.sh` does the copy/clone/rsync work in a small dedicated helper image (`ai-containers-seed`, ~40 MB: Alpine + `git`, `openssh-client`, `rsync`, `bash`), built automatically from `Dockerfile.seed` the first time you run `repo.sh add`/`sync`. This means you can seed repo volumes **before** ever running `./build.sh` — you don't need the (large, slow) sandbox image just to populate a volume. The seed image name is **fixed and project-independent**: it is deliberately not derived from `IMAGE_NAME`, so it is built once and reused by every project rather than producing one near-identical copy per project image. Set `REPO_SEED_IMAGE` to reuse a different existing image that already has these tools (for example `REPO_SEED_IMAGE="$IMAGE_NAME"` once the sandbox image is built); if `REPO_SEED_IMAGE` names an image that is not present, `repo.sh` errors instead of building. The seed helper runs as a plain `docker run` (not through `entrypoint.sh`), so the deny-by-default firewall does not apply to it — the `git clone`/`pull` has normal network access.

> **⚠️ Seed and run as the same user identity.** Repo-volume contents are `chown`ed to a numeric **UID/GID** when seeded/synced, and Linux permissions are enforced by those numbers. `repo.sh` and `sandbox.sh` resolve the identity the **same** way: `SANDBOX_UID`/`SANDBOX_GID` if set, otherwise your host `id -u`/`id -g`. So:
> - Using the **defaults** (no overrides), seeding and running both use your host identity — ownership always matches, nothing to do.
> - If you **override** `SANDBOX_UID`/`SANDBOX_GID`, you must export the **same** values for **both** `repo.sh` (at `add`/`sync` time) and `sandbox.sh` (at run time). Overriding one but not the other — or seeding as one user and running the container as another — leaves the mounted repo owned by the wrong UID, and the in-container agent gets permission errors.
> - This applies to the **named-volume** backend (notably macOS). The Linux `bind` backend mounts your host path directly with no `chown`, so it is unaffected.

## `REPOS` — attach repo volumes at run time

Set `REPOS` to a space-separated list of **registered** repo names, each mounted at `/workspace/<name>`. Append `:ro` (default), `:rw`, or `:rwcopy`:

```bash
# cluster + two libs read-only (shared), app writable
REPOS="cluster:ro lib-a:ro lib-b:ro app:rw" ./sandbox.sh restricted /path/to/primary
```

- **`:ro`** — shared, read-only. Many containers can mount the *same* volume simultaneously from a single on-disk copy. `GIT_OPTIONAL_LOCKS=0` is set so read-only git operations (`log`/`blame`/`status`) don't try to write to `.git`. This is the right choice for reference repos you only inspect.
- **`:rw`** — the shared base volume, mounted **writable directly** (no copy, no extra disk). Intended for a **single writer** at a time — the repo you're actively editing in one container. Two containers writing the *same* repo `:rw` concurrently can wedge git state (lock-file contention, lost edits); the underlying volume/filesystem is not damaged and the state is recoverable (`git reset`, or `repo.sh sync`/`rm`+`add`), but for genuine concurrent writers use `:rwcopy`.
- **`:rwcopy`** — an **isolated** per-workspace writable working copy, seeded once by a fast local copy from the shared base (no re-clone), keyed by the launch directory so the same project reuses its copy across runs. Each `:rwcopy` is a full copy (~repo size), so it costs disk; use it only when you need two containers writing the *same* repo at once. Volume backend only.

If a `REPOS` entry is not registered (or its volume is missing), `sandbox.sh` aborts **before** starting the container with a clear hint. A name appearing in **both** `EXTRA_MOUNTS` and `REPOS` is an error, since both mount under `/workspace/<name>`.

> **Repo volumes shadow the host.** A repo volume is *not* synced with any host directory — its contents live only in the VM volume (and persist across runs until you `repo.sh rm` it). Commit and push from inside the container to get work out. This is the intended trade-off for native speed: you give up live host-side editing for the repos you put in volumes.

> **`sync` and `:rwcopy` working copies.** `repo.sh sync` refreshes the shared base volume but does **not** touch existing `:rwcopy` working copies (they may contain uncommitted work). List them with `./repo.sh list --copies` and remove the ones you no longer need with `./repo.sh gc` (e.g. `./repo.sh gc --repo <name>`) so they re-seed from the refreshed base on the next run. For path-sourced repos, `sync` uses `rsync -a --delete` (exact mirror) when `rsync` is in the image, falling back to `cp -a` (adds/updates only) otherwise; git-sourced repos use `git pull`.

## Cross-platform backend (`REPO_BACKEND`)

The bind-mount penalty only exists on macOS — on Linux, host bind mounts are already native speed. So `REPOS` picks a backend per platform, controlled by `REPO_BACKEND` (default `auto`). **The backend is decided when you run `repo.sh add` and stored in the registry** — changing `REPO_BACKEND` later does not affect already-added repos (remove and re-add to change):

| `REPO_BACKEND` | `path` source | `git` source |
|----------------|---------------|--------------|
| `auto` (default) | **macOS:** named volume. **Linux:** direct host bind mount (no volume, no copy). | named volume (both platforms) |
| `volume` | named volume (both platforms) | named volume |
| `bind` | direct host bind mount | falls back to named volume (no local path to bind) |

This means **one `REPOS="cluster:ro app:rw"` line works on both platforms** — you get native-speed volumes on macOS and zero-copy bind mounts on Linux without maintaining separate launch scripts. On Linux, `repo.sh add <name> <path>` simply records the name→path mapping in the registry (no volume is seeded); `repo.sh sync` is a no-op for those (the bind mount is always live).

> **One behavioural difference with `auto`/`bind`:** `:rw` on a bind-mounted repo writes **live** to the host source (changes are visible on the host immediately), whereas `:rw` on a volume-backed repo writes to the shared base **inside the VM** (not visible on the host). `:ro` behaves identically either way, and `:rwcopy` (volume backend) is always an isolated in-VM copy. Set `REPO_BACKEND=volume` if you want byte-identical behaviour on every platform.

## Mounting an Obsidian vault

Set `VAULT_PATH` to a host directory — your **personal** knowledge base — to mount it at `/workspace/vault` (read-write). It is also re-exported as `VAULT_PATH=/workspace/vault` inside the container so agent skills/workflows that consume the variable resolve to the in-container mount point.

An Obsidian vault is the typical source, but `VAULT_PATH` is useful even without Obsidian — it works as a vault for any markdown corpus. A common pattern is imported Jira documents under `$VAULT_PATH/jira-products`: Jira tickets exported as markdown together with their images, attachments, comments, and linked tickets. Several in-container workflows read this tree heavily, so pointing `VAULT_PATH` at such a directory is valuable on its own.

```bash
VAULT_PATH=/path/to/obsidian-vault \
./sandbox.sh restricted /path/to/repo
```

When any markdown corpus (`VAULT_PATH`, `SPECS_PATH`, or `DOCS_PATH`) is mounted, set `qmd=ON` in `sandbox.conf` and rebuild — `sandbox.sh` prints one startup warning naming the mounted corpora if qmd was not baked into the image. `qmd` is the on-device markdown search engine [@tobilu/qmd](https://github.com/tobi/qmd), installed globally via npm.

## Mounting a docs repository (read-only by default)

Set `DOCS_PATH` to a host product-documentation repo (e.g. `dynatrace-docs`) to mount it **read-only** at `/workspace/docs`. It is re-exported as `DOCS_PATH=/workspace/docs` inside the container, so grounding workflows — creating an idea, creating or updating a Value Increment, writing Release Notes — resolve existing documentation at a stable path without being able to modify it.

```bash
DOCS_PATH=/path/to/docs \
./sandbox.sh restricted /path/to/repo
```

Export `DOCS_PATH` in your host shell profile to make it the default for every container, exactly as with `VAULT_PATH` / `SPECS_PATH`.

`DOCS_PATH` accepts a small grammar: `@<name>` mounts a registered repo volume at `/workspace/<name>` (fast on macOS; see [Shared repo volumes](#shared-repo-volumes-native-speed--reposh-and-repos)), and a trailing `:ro`/`:rw` sets the mount mode (default `:ro`). To **edit** the docs, either mount the docs repo as the working directory or pass `DOCS_PATH=/path:rw`.

> **A pointer never fights a mount that is already there.** If the directory `DOCS_PATH` names is already attached to the container — as the working directory, or as a repo listed in `REPOS` — the pointer **re-points at that mount** instead of mounting it a second time, and inherits that mount's mode. So exporting `DOCS_PATH` once on your host stays safe even for the project that *is* the docs repository: attached `:rw`, the docs are writable, which is correct when that repo is what you are working in. The `:ro` default applies to a docs repo mounted *by the pointer*, not to one you deliberately attached for editing. `VAULT_PATH` and `SPECS_PATH` behave the same way.
>
> Identity is proven, not guessed: only a **path-sourced** repo has a host directory to compare, and both sides are resolved first. A genuinely different directory colliding on the same name is still refused, and the error now says the two are different so you can rename the repo or re-point the variable.

## Mounting a specs repository

Set `SPECS_PATH` to a host repository of AI-ready specifications, design documents, and development plans to mount it at `/workspace/specs` (read-write). It is also re-exported as `SPECS_PATH=/workspace/specs` inside the container so agent skills/workflows that consume the variable — for example the dev-workflows plugin, which reads specs to implement features and writes design docs and plans back — resolve to the in-container mount point.

```bash
SPECS_PATH=/path/to/specs \
./sandbox.sh restricted /path/to/repo
```

Export `SPECS_PATH` in your host shell profile to make it the default for every container, exactly as with `VAULT_PATH`. `SPECS_PATH` also accepts `@<name>` to mount a registered repo volume at `/workspace/<name>` instead of a host path — useful on macOS for a large, team-shared specs repo.

## Host configuration mounts

The container automatically mounts the following directories from the host (if they exist) into the sandbox user's home:

Each directory is only mounted when its corresponding component is enabled in `sandbox.conf`. Missing directories are silently skipped.

Agent dotfile directories are sourced from the active container group (`~/.ai-containers/<group>/` by default). The group is selected by `AI_CONTAINER_GROUP` — see [Container groups](groups.md) for details.

| Host source (within group root) | Container path | Mode | Component |
|---|---|---|---|
| `<group>/.ssh/` | `~/.ssh` | read-write | always |
| `<group>/.agents/` | `~/.agents` | read-write | always |
| `<group>/.gitconfig` ¹ | `~/.gitconfig` | read-only | always (if file exists) |
| `<group>/.gitignore_global` ¹ | `~/.gitignore_global` | read-only | always (if file exists) |
| `<group>/.config/gh/` | `~/.config/gh` | read-write | `github-cli` or `copilot` |
| `<group>/.copilot/` | `~/.copilot` | read-write | `copilot` |
| `<group>/.kiro/` | `~/.kiro` | read-write | `kiro` |
| `<group>/.local/share/kiro-cli/` | `~/.local/share/kiro-cli` | read-write | `kiro` |
| `<group>/.claude/` | `~/.claude` | read-write | `claude-code` |
| `<group>/.claude.json` | `~/.claude.json` | read-write | `claude-code` |
| `<group>/.codex/` | `~/.codex` | read-write | `codex` |
| `<group>/.gemini/` | `~/.gemini` | read-write | `gemini` |
| `<group>/.rvm/` | `~/.rvm` | read-write | `ruby` |
| `<group>/.ai-tools/` | `~/.ai-tools` | read-write | any of `claude-code`/`copilot`/`codex`/`gemini`/`graphify`/`vale` |
| `<group>/.config/dtctl/` ² | `~/.config/dtctl` | read-write | `dtctl` |
| `<group>/.config/dtmgd/` ² | `~/.config/dtmgd` | read-write | `dtmgd` |
| `~/.aws` | `~/.aws` | read-write | `aws-cli` |
| `~/.azure` | `~/.azure` | read-write | `azure-cli` |
| `~/.kube` | `~/.kube` | read-write | `kubectl` |
| `~/.yarn` | `~/.yarn` | read-write | `yarn` |

¹ `sandbox.sh` copies these files from `$HOME` into the group directory on every container start and mounts from the copy. This avoids a macOS VirtioFS issue where atomically replacing a file on the host (as git and most editors do) causes the bind-mounted view inside the container to become unreadable. If you edit either file while a container is running, restart the container to pick up the changes.

² Tool config dirs declared via `tools.d/` (`config_dir=` in the tool's descriptor — currently `dtctl`, `dtmgd`) are group-scoped like agent dotfiles, **not** mounted straight from `$HOME` like `.aws`/`.azure`/`.kube`/`.yarn` above. The first time a group needs one, it is seeded once from the host's copy at `$HOME` if one exists (otherwise created empty); every later run mounts the group's copy instead, so a sandboxed agent never writes to your real host config. A descriptor may list several space-separated paths in `config_dir=`, for a tool that splits its config and its credentials across two directories; each path is group-scoped and mounted.

When `AI_CONTAINER_GROUP=host`, all group-scoped paths above are sourced directly from `$HOME` instead (including `.gitconfig`, `.gitignore_global`, and the tool config dirs).

---

[← Documentation index](README.md)
