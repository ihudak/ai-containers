# Environment variables

These configure `sandbox.sh` at launch time. Set any of them **inline** for a single run
(`VAULT_PATH=/path ./sandbox.sh restricted`) or **export them in your host shell profile**
(`~/.bash_profile`, `~/.zshrc`) so they become the default for every container you start.
`VAULT_PATH`, `SPECS_PATH`, `DOCS_PATH`, and `ARCHITECTURE_REPO_PATH` are designed for the profile-export pattern: point them once at
host directories and every container mounts them and sees the variable re-exported to its
in-container path. Their effective default is therefore whatever the host environment exports;
override either inline to point at a different directory for a single run. If the variable is
unset the mount is simply skipped, and if it points at a directory that does not exist `sandbox.sh`
warns and skips it.

The **In container** column says whether the variable is visible to the agents *inside* the
container:

- **forwarded** — passed through unchanged (`-e VAR=$VAR`).
- **→ `/path`** — re-exported pointing at the in-container mount path (a host-directory pointer).
- **mount** — attaches a filesystem mount; not exposed as an environment variable inside.
- **—** — configures the launcher / `docker run` only; not visible inside the container.

| Variable | Purpose | Default | In container |
|---|---|---|---|
| `IMAGE_NAME` | Image tag to run. Persisted per project in `.ai-containers/sandbox.env`. | `ai-sandbox` | forwarded |
| `AI_CONTAINER_GROUP` | Which dotfile tree (group) to mount: `default`, `host` (mounts `$HOME`), or a custom `~/.ai-containers/<name>/`. | `default` | — |
| `AI_CONTAINER_GROUP_INIT` | Non-interactive first-time group bootstrap: `clean` \| `from:host` \| `from:<name>`. | interactive prompt | — |
| `SANDBOX_MODE` | Default network mode for a bare `./sandbox.sh` (`open` \| `discovery` \| `restricted`). Set in `sandbox.env`; a positional arg or inline env wins. | `open` (via `sandbox.env`) | — |
| `SANDBOX_WORKDIR` | Default primary working dir for a bare `./sandbox.sh` (`..`, a host path, or `@repo`). Set in `sandbox.env`; override per-machine in `sandbox.local.env`. | `..` (via `sandbox.env`) | — |
| `AI_CONTAINER_HOST_ACK` | Set `1` to skip the macOS `host`-group acknowledgement. Ignored on Linux. | `0` | — |
| `SANDBOX_UID` / `SANDBOX_GID` / `SANDBOX_USER` / `SANDBOX_GROUP` | Override the container user identity. | detected from host (`id`) | forwarded |
| `REPOS` | Space-separated **registered** repo volumes to attach under `/workspace/<name>`; append `:ro` (default), `:rw`, or `:rwcopy`. Register first with `./repo.sh add`. | none | mount |
| `REPO_BACKEND` | How a repo is backed: `auto` \| `volume` \| `bind` (chosen at `repo.sh add` time). | `auto` | — |
| `EXTRA_MOUNTS` | Space-separated extra host directories bind-mounted under `/workspace/<basename>`; append `:ro`/`:rw`. | none | mount |
| `VAULT_PATH` | Host directory mounted read-write at `/workspace/vault` — your **personal** knowledge base (an Obsidian vault is typical, but any markdown corpus works, e.g. imported Jira tickets under `$VAULT_PATH/jira-products`, read heavily by several workflows). Pair with `qmd=ON` for in-container search. | host `$VAULT_PATH` export | → `/workspace/vault` |
| `SPECS_PATH` | Host repo of AI-ready specifications, design documents, and development plans — the **team/shared** knowledge base — mounted read-write at `/workspace/specs`. Consumed by spec-driven workflows (e.g. the dev-workflows plugin). Accepts `@<name>` for a registered repo volume (mounted at `/workspace/<name>`; fast on macOS). | host `$SPECS_PATH` export | → `/workspace/specs` |
| `DOCS_PATH` | Host **product-documentation** repo mounted **read-only** by default at `/workspace/docs`, re-exported as `DOCS_PATH=/workspace/docs`. Grounding for plugin workflows (idea / VI / release-notes). Accepts `@<name>` (→ `/workspace/<name>`) and a `:ro`/`:rw` suffix (default `:ro`). When the docs repo is the working dir, `DOCS_PATH` re-points to that writable mount; to edit docs otherwise use `:rw`. | host `$DOCS_PATH` export | → `/workspace/docs` |
| `ARCHITECTURE_REPO_PATH` | Host **architecture** repo — standards, technology radar, ADRs — mounted **read-only** by default at `/workspace/architecture`, re-exported as `ARCHITECTURE_REPO_PATH=/workspace/architecture`. Grounding for architecture-aware workflows; the name is the one product-architecture's own MCP server and slash commands read, so they work inside the container unchanged. Same grammar and re-point rules as `DOCS_PATH`: `@<name>` (→ `/workspace/<name>`), a `:ro`/`:rw` suffix (default `:ro`), and the existing mount when that directory is already the working dir or a repo in `REPOS`. | host `$ARCHITECTURE_REPO_PATH` export | → `/workspace/architecture` |
| `REPOS_PATH` | Where code repositories live **inside** the container, for tools that need to find them (e.g. Claude Code plugins). Everything the launcher attaches — the positional `[primary]`, every `REPOS` entry, every `EXTRA_MOUNTS` path — lands under the `/workspace` umbrella, so that is the default. `/workspace` also holds `vault`/`specs`/`docs`/`architecture` and the `.agent-*` output dirs, so a consumer should filter (e.g. for a `.git` dir) rather than treat every entry as a repo. Distinct from `REPOS`, which selects **which** repo volumes to attach. A **host** path — the same variable exported in a host profile for host-side tools, as `VAULT_PATH` and the rest are — is never forwarded as is: a value under `/workspace` is kept, and any other is translated to where that host directory appears in the container (inside a bind mount: the same place under its mount point), or `/workspace` when no mount holds it, e.g. a directory that holds the mounted checkouts (`sandbox.sh`: `repos_path_in_container()`; hermetic `tests/test-repos-path.sh`). | `/workspace` | → in-container path |
| `PREVIEW_PORTS` | Space-separated ports (or `host:container` pairs) to publish for dev servers. | none | — |
| `CONTAINER_CPUS` | CPU limit: a time quota, not a CPU count. `nproc` still reports every CPU the Docker engine has, so give parallel test runners a worker count ([Resource limits](resources.md)). | `1.0` | — |
| `CONTAINER_MEMORY` | Hard memory limit. | `4g` | — |
| `CONTAINER_MEMORY_RESERVATION` | Soft memory limit (must be ≤ `CONTAINER_MEMORY`). | `2g` | — |
| `CONTAINER_MEMORY_SWAP` | Memory + swap total (≥ `CONTAINER_MEMORY`; set equal to disable swap, `-1` for unlimited). | `4g` | — |
| `CONTAINER_NOFILE` | Open-file-descriptor limit, `soft[:hard]`. | `1048576:1048576` | — |
| `CONTAINER_SHM_SIZE` | Size of `/dev/shm` (`--shm-size`). Its size is not governed by `CONTAINER_MEMORY` (whose 4g default leaves a 64m `/dev/shm` that crashes headless Chromium), though its pages are charged to that cgroup. Passed automatically as `1g` when `playwright` is active. | Docker's `64m`; `1g` with `playwright` | — |
| `CONTAINER_NAME` | Container name (`--name`), printed at launch. Default: `<project-folder>-<PID>` — the parent of the launch dir, sanitised to Docker's `[a-zA-Z0-9][a-zA-Z0-9_.-]*` (`workspace` if nothing usable is left) — so concurrent containers, even several against the very same workspace, get distinct, legible names instead of Docker's random `adjective_surname`. Set it **inline, for one run**: persisted in `sandbox.env`/`sandbox.local.env` it applies to every launch, and the second concurrent container fails on the name conflict. | derived (see left) | — |
| `SELF_HEALING_ENABLED` | Set `0` to disable reactive IP auto-allowing (logging only). | `1` | forwarded |
| `ALLOW_IPV6_BYPASS` | Set `1` to suppress the `ip6tables`-unavailable warning (WSL2/nf_tables). | `0` | forwarded |
| `COPILOT_GITHUB_TOKEN` | Copilot CLI auth token; bypasses device-flow OAuth. Auto-extracted from the group's `gh` `hosts.yml` when unset. | auto from `gh` | forwarded |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | Forwarded as-is for tools expecting this exact name (github MCP servers, Claude Code github plugin). | none | forwarded |
| `SKILL_CHAR_BUDGET` | How many characters Copilot CLI may spend listing installed skills to the model. It fills the budget plugin by plugin, in load order, and lists a skill past it by name only, without its description, so the model cannot tell when to use that skill. Each entry costs about 93 characters plus its name and description, so Copilot's own default of 15,000 runs out after a few plugins. Your exported value is passed instead of the default. Set it on the host (inline, profile, `sandbox.env`), not in `container.env`, which refuses it because the launcher sets it. | `25000` | forwarded |
| `SLASH_COMMAND_TOOL_CHAR_BUDGET` | How many characters Claude Code may spend listing installed skills to the model. Without it, Claude Code's budget is 4 characters per token of the context window times `skillListingBudgetFraction` (0.01 by default): 8,000 characters at a 200K window, which every 200K subagent also gets, and 40,000 at 1M. Over budget it shortens every skill's description, and `claude --debug` logs `Skill listing over budget`. The default here, 40,000, is the 1M figure. **It overrides `skillListingBudgetFraction` in your Claude Code settings**: inside the container that setting has no effect, so to choose a different budget, export this variable on the host instead. Your exported value is passed instead of the default. Set it on the host (inline, profile, `sandbox.env`), not in `container.env`, which refuses it because the launcher sets it. | `40000` | forwarded |
| `SANDBOX_GIT_MAX` | How many git repositories (and submodule or worktree git directories) a launch protects before it refuses. Each adds a little to every container start; raise it for a tree that legitimately holds more. | `200` | — |
| `SANDBOX_ENV_FILE` | Path to a `KEY=VALUE` env-file for non-secret in-container **application** env (e.g. `DB_HOST`, `REDIS_URL`), not credentials. Its variables reach your shell and the tools you run in it, never the container's root setup; read as `docker run --env-file` reads a file (values are literal: quotes and `#` are kept), except that a line which acts on the container's start (`PATH`, any `LD_*`, `BASH_ENV`, …), names a variable the launcher sets itself (`SANDBOX_UID`, `IMAGE_NAME`, …), one bash sets itself (`PWD`, `SHLVL`, `RANDOM`, …) or `HOME`/`USER`/`LOGNAME`, or which docker would refuse (`export NAME=…`, a space in the name) is skipped with a `WARNING:` naming its line, and the rest still apply. `SELF_HEALING_ENABLED` and `ALLOW_IPV6_BYPASS` configure the container's root setup, so they belong in `sandbox.env`, not here. It is also where [`POSTGRES_ROLES` / `POSTGRES_DATABASES`](components/postgres.md#roles-and-databases) go. | `<project>/.ai-containers/container.env` if present, else unset | — |

### `GITHUB_TOKEN` — build time, strongly recommended

Not in the table above: it is read by `build.sh`, never forwarded into the
container. Set it anyway.

Two build layers run vendor installers that `git clone` from github.com — nvm's
install.sh, and pyenv's installer (four clones: pyenv, pyenv-doctor,
pyenv-update, pyenv-virtualenv). Anonymous git traffic sits in GitHub's
low-budget tier, and when that tier throttles your host those clones fail with:

```
fatal: could not read Username for 'https://github.com': No such device or address
```

That is a 401 on a **public** repo — what GitHub returns to an unauthenticated
caller it is throttling. It reads like a network fault or a broken Dockerfile,
which is what makes it worth pre-empting. Measured 2026-09-02, it failed a whole
build cycle, recurred in bursts over about half an hour, and was not cured by
retrying (5 attempts over ~150s all failed); in the same container at the same
moment an authenticated clone succeeded where the anonymous one got 401.

With a token set, `build.sh` passes it as a BuildKit secret, both clone layers
mount it, and git presents it **when challenged** — so the anonymous path is
unchanged and the token is pure headroom. It is never written into an image
layer, and it is presented through a credential helper rather than a URL, so it
cannot leak into the build log via a git error message.

```bash
export GITHUB_TOKEN="$(gh auth token)"     # or a PAT; put it in ~/.bashrc / ~/.zshrc
```

`build.sh` falls back to `GITHUB_PERSONAL_ACCESS_TOKEN` when `GITHUB_TOKEN` is
unset. It reads both from the environment of the shell you launch the build
from — so a token rotated in `gh` but stale in your profile quietly puts you back
on the anonymous path.

**Still optional.** With no token the clones are anonymous exactly as before and
the build proceeds; nothing in this repo *requires* one (both `tools.d/` tools,
`dtctl` and `dtmgd`, are public). Without it you are simply exposed to GitHub's
anonymous throttling.

See [Mounting an Obsidian vault](repos-and-mounts.md#mounting-an-obsidian-vault),
[Mounting a specs repository](repos-and-mounts.md#mounting-a-specs-repository),
[Mounting additional repositories](repos-and-mounts.md#mounting-additional-repositories), and
[Resource limits](resources.md) for the longer treatments.

## Reporting versions

```bash
./runme.sh --version      # in a project (also -V, or `version`)
./sandbox.sh --version    # anywhere, including this repo
```

```
ai-containers   v0.7.0-11-gefce881
sandbox.conf    schema 4
nvm             v0.40.7
```

Three numbers from three places, and they answer different questions:

| Field | Where it comes from | Why it is worth reporting |
|---|---|---|
| `ai-containers` | `git describe --tags` in this repo; the `engine-version` file in a project copy | A project's `.ai-containers/` is a working **copy**, not a git repo, so it cannot derive this — it is told at `project-init.sh`/`sync-to-projects.sh` time. A copy taken five commits after a release reports `v0.7.0-5-g<sha>`, not `v0.7.0`, because it is not that release. |
| `sandbox.conf` | the `# schema-version:` marker | Says which migrations a project has already had applied. |
| `nvm` | `nvm-version=` in `sandbox.conf` | Pinned rather than detected: nvm's latest cannot be resolved at build time behind a rate limit, so [`update-nvm-version.yml`](../.github/workflows/update-nvm-version.yml) keeps it current. Reporting it is reporting that job's output. An empty key reports the `Dockerfile`'s own default instead, labelled — the question is what the **image** gets, not what the file happens to say. |

`--version` is pure output: it builds nothing and starts no container. The generated `runme.sh` short-circuits to `sandbox.sh --version` **before** its own `./build.sh`, so asking the version never triggers a build.

A project copy that predates this feature reports `unknown` for the engine release until its next sync, and says so rather than guessing.

**Older projects.** `sync-to-projects.sh` does not regenerate `runme.sh` — it is a generated file people edit (uncommenting `./build.sh --no-cache` is right there in the template), and this repo does not clobber project-local files. So a project synced from an older release gets `./sandbox.sh --version` immediately, and `./runme.sh --version` once its launcher is next regenerated by `project-init.sh`.


---

[← Documentation index](README.md)
