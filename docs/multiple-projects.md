# Managing projects — setup, launching and updates

If you use ai-containers across several projects, two scripts help you keep them in sync without manual copying.

## project-init.sh — initialise a project

Copies the shared infrastructure into `<project>/.ai-containers/`, generates a ready-to-edit launch script, and registers the project in `projects.conf`.

```bash
./project-init.sh          # takes no arguments — it prompts for the path and the name
```

What it does:

- Creates `<project>/.ai-containers/` and copies all shared files (Dockerfile, scripts, allowlist fragment files).
- Copies `sandbox.conf` as a starting point (only if one does not already exist).
- Writes two launcher-config files. **`sandbox.env`** (tracked, PORTABLE) holds the project-level settings that are the same on any machine — `IMAGE_NAME`, `AI_CONTAINER_GROUP`, the `CONTAINER_*` resource values, `SANDBOX_MODE` (default `open`), `SANDBOX_WORKDIR` (default `..`) — plus commented `EXTRA_MOUNTS`/`REPOS` examples. **`sandbox.local.env`** (gitignored, THIS MACHINE) is always written — backing up an existing file to `sandbox.local.env.pre-init` first — and documents every override (including a commented-out `SANDBOX_MODE` example — the live default lives in `sandbox.env`) and holds `AI_CONTAINER_GROUP_INIT` (the host-referential group bootstrap, e.g. `from:host`), `EXTRA_MOUNTS`, and is where `REPOS`, a named-volume `SANDBOX_WORKDIR=@app`, or per-machine resource **overrides** go. Both are read by `sandbox-common.sh`, so `build.sh`, `sandbox.sh`, and `repo.sh` resolve the same config even when run directly. **Precedence: inline env > `sandbox.local.env` > `sandbox.env`** (the highest-precedence source that defines a key wins) — so an exported `IMAGE_NAME`, or a one-off `CONTAINER_MEMORY=8g ./sandbox.sh`, still wins. Both files are **parsed, never sourced** (only `KEY=value` lines; values are literal, `$VAR` is not expanded), and keys that would control the **shell** rather than the launcher — `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `CDPATH`, `IFS`, `PS4`, `PATH`, the `LD_*`/`DYLD_*` loader vars, `BASH_FUNC_*` — are refused with a warning, so a committed `sandbox.env` cannot run code on a teammate's machine. (Repo-volume names are global — `ai-containers-repo-<name>` — so they are shared across projects regardless of `IMAGE_NAME`.)
- Generates a **thin** `<project>/.ai-containers/runme.sh` launcher: it resolves a build-time `GITHUB_TOKEN` via `gh`, runs `./build.sh`, then a bare `./sandbox.sh` (network mode + working dir come from `SANDBOX_MODE`/`SANDBOX_WORKDIR`). No config is baked into the launcher itself, so regenerating `runme.sh` never clobbers your settings; re-running `project-init.sh` also backs up an existing `sandbox.local.env` to `sandbox.local.env.pre-init` before rewriting it, so a hand-added override there survives too.
  - **Migrating an existing (fat) `runme.sh`:** move the portable `export`s (`IMAGE_NAME`, `CONTAINER_*`, `AI_CONTAINER_GROUP`) into `sandbox.env` as `KEY=value`, move `EXTRA_MOUNTS`/`REPOS` into `sandbox.local.env` (values are **literal** — write absolute paths, not `$HOME/…`, since the loader parses rather than sources), and replace the launch line with `./sandbox.sh` — or just re-run `project-init.sh`. An existing fat launcher keeps working meanwhile (its inline `export`s win, per the precedence above). **Cross-platform:** on macOS put `REPOS`/`SANDBOX_WORKDIR=@app` in `sandbox.local.env`; on Linux put `EXTRA_MOUNTS` there — the shared `sandbox.env` is identical on both.
- Registers the project path in `projects.conf` (created from `projects.conf.example` on first run).
- Adds `/.ai-containers/` to the project's **root `.gitignore`** (git repos only, idempotent), so the synced working copy — whose `sandbox.local.env` holds machine-specific paths (`EXTRA_MOUNTS`) and whose `custom.txt` may hold internal hostnames — isn't accidentally committed. To version the **portable** config with a team, remove that line: `sandbox.env`, `sandbox.conf`, and the thin `runme.sh` are portable, while `sandbox.local.env` stays gitignored on its own. Set `AI_CONTAINERS_NO_GITIGNORE=1` to skip this step entirely. `sync-to-projects.sh` applies the same rule to existing projects (never duplicating an entry already present).

> **Note on resource defaults:** the CPU/memory values `project-init.sh` pre-fills in its prompts (`4.0` CPU, `8g` memory, `4g` reservation, swap = memory) reflect the recommended **comfortable** tier from [Resource limits](resources.md), not `sandbox.sh`'s conservative fallback (`1.0` CPU / `4g` / `2g` / `4g`). This is intentional: the generated `sandbox.env` records the comfortable values as `CONTAINER_*`, while `sandbox.sh`'s fallbacks remain the bare minimum for a single agent doing light work. Edit `sandbox.env` to lower them if your Docker/Colima VM is smaller (or override just this machine in `sandbox.local.env`).

After init, edit `sandbox.conf` to choose components, then launch:

```bash
cd <project>/.ai-containers
./runme.sh
```

`runme.sh` runs `build.sh` itself, so there is no separate build step — running both would build twice.

## ai-containers-report.sh — what is registered, and how it is configured

```bash
./ai-containers-report.sh                     # this repo's registry
./ai-containers-report.sh --markdown          # a pipe table to paste somewhere
./ai-containers-report.sh --tsv               # for a script to read
```

Reads **this repo's `projects.conf`** and, for each registered project, resolves its settings from `<project>/.ai-containers/sandbox.env` (with `sandbox.local.env` overriding, exactly as the launcher resolves them). One row per project: the engine version and `sandbox.conf` schema that project's copy is on, its container group, network mode, CPUs, memory as limit/reservation/swap, the size of its `.agent-discovery`, and its path.

```
base: ~/dev/ai-tools/ai-containers

VERSION           SCHEMA  GROUP    PROJECT                NETWORK    CPUS  MEM(L/R/S)  DISCOVERY  PATH
----------------  ------  -------  ---------------------  ---------  ----  ----------  ---------  -----------------------------------
v0.8.1            4       ihudak   ai-containers          DISCOVERY  4.0   16g/4g/16g  352M       ~/dev/ai-tools/ai-containers
v0.7.0-5-gefce88  3       ihudak   ihudak-claude-plugins  DISCOVERY  4.0   8g/4g/8g    6.2G       ~/dev/ai-tools/ihudak-claude-plugins

2 registered project(s).
```

**`VERSION` and `SCHEMA` are per project, not per base** — that is the point of reporting them. A project's `.ai-containers/` is a working *copy*, and it drifts from the base it was made from until someone runs `sync-to-projects.sh`. The row above is the case worth catching: two projects from one base, on different engine releases and different schema versions, because only one of them has been synced recently.

- **`VERSION`** is the `engine-version` file `project-init.sh` / `sync-to-projects.sh` write into the copy at copy time. It is the same number [`./runme.sh --version`](configuration.md#reporting-versions) reports inside that project, from the same function.
- **`SCHEMA`** is the `# schema-version:` marker in that project's own `sandbox.conf`, which says which [migrations](../README.md) it has had applied.
- **`unknown`** means the copy was never told — it predates the `engine-version` file, or has no `sandbox.conf`. It is not a guess: a copy is never asked its enclosing project's git tags, which would report a version belonging to an entirely different tree.
- **`n/a`** means the registry entry's path does not exist, so nothing could be read at all.

**It does not search your filesystem.** The registry is the whole input, so what you get back is what *this* checkout is responsible for keeping in sync — the same set `sync-to-projects.sh` writes to. To report on another checkout, name it; the argument is a path, not a search:

```bash
./ai-containers-report.sh ~/dev/other/ai-containers          # that base instead
./ai-containers-report.sh . ~/dev/other/ai-containers        # both
```

With more than one base a `BASE` column is added and the rows stay grouped by base; with one, the base is stated once above the table rather than repeated on every row. `--tsv` always emits the base column, so a script reading it sees one schema either way.

Footnotes call out what needs attention: a registry entry whose path no longer exists, a project with no `.ai-containers/sandbox.env` (run `sync-to-projects.sh`), a project whose `sandbox.env` sets no group (so it is on `default` implicitly), and any surviving pre-rename `<project>-container.sh` launcher. `--no-notes` suppresses them.

Other flags: `--full-paths` (do not abbreviate `$HOME` to `~`), and `--path-map HOST=LOCAL` (repeatable) which changes only where the report **looks**, never what it prints — useful when running it inside a container where the host's paths are mounted elsewhere.

---

## sync-to-projects.sh — propagate updates

After pulling changes to this repo, run this to push the updated shared files to all registered projects:

```bash
./sync-to-projects.sh              # sync all projects in projects.conf
./sync-to-projects.sh /path/to/p   # sync a single project
```

**What is synced:** Dockerfile, `Dockerfile.seed`, all `*.sh` scripts, `.dockerignore`, the `tools.d/` tool descriptors, and the per-component allowlist fragments in `allowlist-*.d/` (excluding `custom.txt`).

**What is never touched:** `sandbox.conf`, `sandbox.env`, `sandbox.local.env`, `allowlist-*.d/custom.txt`, and the project's launch script. `sandbox.env` is **backfilled** (created from the launcher's `IMAGE_NAME`) if a project predates it, but an existing one is never overwritten. The project's inner `.ai-containers/.gitignore` is **backfilled append-only** — any required pattern it is missing (notably `sandbox.local.env`) is appended, existing lines and your own additions are never removed or reordered, and re-running sync adds nothing further. This matters for a project that deliberately **tracks** `.ai-containers/`: sync leaves such a project's root `.gitignore` alone, so this inner file is the only thing keeping the machine-specific `sandbox.local.env` out of the shared repo.

**sandbox.conf reconcile:** Instead of a bare drift warning, `sync-to-projects.sh` now reconciles each project's `sandbox.conf` against this repo's on every sync — pending `migrations/` hooks run, any new upstream keys are appended under a dated banner, and the `# schema-version:` marker is ensured. A key the project already set is never touched, so per-project tool selections are preserved. See [sandbox.conf schema versioning](components/README.md#schema-versioning).

## Which sources produced an image?

Syncing and rebuilding are two steps, and getting only the second one done is
invisible: `./build.sh` faithfully rebuilds whatever is in the project's
`.ai-containers/`, so a project that was never synced produces a freshly-built
image carrying month-old engine files. Nothing about the image looks stale.

Every build now stamps the image with three labels:

| label | what it records |
| --- | --- |
| `ai-containers.payload-digest` | a digest of every file that reaches the image — the engine scripts, `Dockerfile`, the allowlist fragments and `tools.d/` |
| `ai-containers.built-at` | when the build ran, in UTC |
| `ai-containers.source-commit` | the commit, **when the build ran from a git checkout**. A project's `.ai-containers/` is a copy with no history, so this is absent there — which is itself the answer to "was this built from the central repo or from a project copy?" |

Read them back with:

```bash
docker image inspect ai-sandbox --format '{{json .Config.Labels}}' | tr ',' '\n' | grep ai-containers
```

`sandbox.sh` compares the stamped digest against the files sitting next to it at
every launch, and prints a warning — never a refusal — when they disagree:

```
WARNING: this image was NOT built from the files in /path/to/.ai-containers.
         Rebuild before trusting it:  ./build.sh    (or ./runme.sh, which builds first)
```

That is what you should expect to see immediately after a sync, and it clears
on the next build. An image built before this existed carries no label and is
never warned about, since an absent stamp is not evidence of drift.

**`sandbox.conf` is covered too, but not by digesting the file.** It mixes
build-time keys (`ruby=`, `db-clients=`) with runtime ones (`mode=`, `agents=`),
and digesting it whole would demand a rebuild after changing `mode=`, which
rebuilds nothing — a warning that fires when nothing is wrong is one you learn
to dismiss, and it takes the true ones with it.

So a second label, `ai-containers.config-digest`, records what `build.sh`
*derives* from the config: the `--build-arg` list, which contains every
build-time key by construction and no runtime key at all. Change `ruby=` and the
launcher says so; switch `mode=` between `restricted` and `open` and it stays
quiet. A build-time key added to the tool in future is covered automatically,
because it becomes a build arg with no list to update.

The two are reported separately, because they mean different things:

```
WARNING: this image was NOT built from the build-time settings in sandbox.conf in /path/.ai-containers.
         settings: built from 881d7e28e230, sandbox.conf now asks for 8763665c2041
         Rebuild before trusting it:  ./build.sh    (or ./runme.sh, which builds first)
```

**What it still does not cover:** `sandbox.env` and `sandbox.local.env`, which
are runtime-only, and anything that changes outside this directory.

## sandbox.conf schema versioning

Every project keeps its **own** hand-edited `sandbox.conf` (its tool selection is exactly what must not be clobbered), so `sync-to-projects.sh` cannot simply overwrite it the way it does the other shared files. Instead it **reconciles**:

- **A `# schema-version: N` marker** lives inside `sandbox.conf` (a comment line, invisible to the parser). Central's copy and every project's copy carry it; a file missing the line is treated as version `0`.
- **The vast majority of changes are additive** — one new `newtool=OFF` line. These need **nothing extra**: no marker bump, no hook. On the next sync, reconcile appends the new key to every project (with central's default) under a `# New options synced from upstream (<date>)` banner, and never touches keys a project already has.
- **A genuinely semantic change** — renaming a key, splitting one key into several, removing a key, or changing what an existing key's value *means* — is rare (twice in this file's entire history). Each one gets a small, idempotent, key-only hook under **`migrations/NNN-*.sh`** (named by the version it migrates *to*), plus a marker bump. Reconcile runs every hook whose `NNN` is above a project's recorded version, in order, before the additive step.

**Authoring a semantic change:** run `./bump-sandbox-version.sh <slug>`. It scaffolds the next `migrations/NNN-<slug>.sh` (an idempotent, key-only skeleton) and bumps the marker in one step. Implement the translation in the hook (check a precondition and `exit 0` if already applied; touch only `key=value` lines, never comments), then commit both files.

**CI gate:** `./check-sandbox-version.sh --check` compares the working tree's key set against a base ref's (`BASE_REF`, default `HEAD`) and **fails** if a key was removed or renamed without both a marker bump and a matching `migrations/` hook. Ordinary additions pass silently.

> **In CI, `BASE_REF` must be set explicitly to a ref that predates the change under review.** The default `HEAD` only works as a *local, uncommitted* pre-commit check — it compares the working tree against the last commit, so it catches an in-progress edit before you `git commit` it. Once the change is committed (as it always is by the time CI checks out and runs a PR), the working tree *is* `HEAD`, the diff is empty, and the gate silently reports "OK" even for a genuinely uncovered key removal. Point it instead at the merge-base with the target branch, or the PR's base SHA:
>
> ```bash
> BASE_REF="$(git merge-base HEAD origin/main)" ./check-sandbox-version.sh --check
> ```

`check_config()` also guards against a duplicate `key=` line from a bad manual edit or interrupted reconcile, exiting immediately with a clear error.

> **Never redefine an existing key's meaning in place.** Reconcile assumes a key's semantics never change silently underneath a project that already set it. Always introduce a *new* key name for a semantic change — that is what the marker + hook + CI gate protect. A same-key meaning change is not automatically detectable by the tooling.

## projects.conf

`projects.conf` is the registry of project paths. It is gitignored (to avoid committing personal paths). `projects.conf.example` is the committed template — `project-init.sh` copies it automatically on first use.

You can also edit `projects.conf` manually: one absolute project path per line, blank lines and `#` comments are ignored.

---

[← Documentation index](README.md)
