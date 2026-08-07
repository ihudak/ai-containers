# AGENTS.md

This file is the **canonical instruction set** for AI coding agents working in this
repository (architecture, conventions, and commands). It follows the open
[AGENTS.md](https://agents.md) standard read natively by Codex, GitHub Copilot,
Gemini CLI, Cursor, and others.

For agents that look for a tool-specific filename, these are **symlinks to this file**:
- `CLAUDE.md` → `AGENTS.md` (Claude Code)
- `.github/copilot-instructions.md` → `AGENTS.md` (GitHub Copilot)
- `.kiro/steering/AGENTS.md` → `AGENTS.md` (Kiro CLI loads `.kiro/steering/**/*.md`, not a root file)

Edit **this file only**; the others update automatically.

## What this project is

A CLI-only Docker workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI) and related developer tools (graphify, qmd, etc.) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell. It is intentionally not a VS Code dev container.

## Component configuration

`sandbox.conf` is the single source of truth for which optional components are included. Set a component to `ON` or `OFF` and rebuild. The format is strictly `component=ON` or `component=OFF`, one per line; comments start with `#`.

Optional components: `copilot`, `kiro`, `claude-code`, `codex`, `gemini`, `graphify`, `openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`, `kubectl`, `aws-cli`, `azure-cli`, `github-cli`, `angular-cli`, `yarn`, `pnpm`, `bun`, `goreleaser`, `vale`, `qmd`, `dtctl`, `dtmgd`, `imagemagick`, `wkhtmltopdf`.

Version-list components (`node`, `python`, `ruby`, `rust`, `go`) accept comma-separated version values instead of `ON`/`OFF` (e.g., `node=22,20`). Constraints:
- `angular-cli` accepts only a **single version** (not a comma-separated list).
- `ruby` is a comma-separated list too, like `node`/`python` (e.g. `ruby=3.3.6,3.4.5`) — useful for migrating a project between Ruby versions. Nothing Ruby-related is baked into the image: rvm, every configured version, and installed gems live in a per-user `~/.rvm`, group-mounted like the agent dotfile dirs (see [Host directory mounts](#host-directory-mounts)) and installed additively at container start (`rvm-reconcile.sh`, `flock`-guarded against concurrent same-group starts) — a version's first install compiles it then (can take a few minutes), every later start is instant, and rubies/gems persist per group across container runs. The `rails` key has been removed entirely — Rails is an ordinary per-project gem, not a build-time/`sandbox.conf` concern. After the reconcile, the default Ruby's `ruby`/`gem`/`bundle`/`rake`/`irb` are symlinked onto `/usr/local/bin` (`link-default-ruby.sh`, run by the entrypoint as root) so they resolve in **non-interactive, non-login** shells (`docker exec -T … bash -c "bin/rails …"`), not only in login/interactive shells that source rvm; per-project gemset selection still comes from `.ruby-version` via a login shell. If an install totally fails, reconcile logs `FAILED: ruby-<version>` and never points the default at a version that isn't installed.
- SDKMAN-managed components (`openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`) require **full patch versions** (e.g., `openjdk=21.0.11`, not `21`).
- Any tool described by a `tools.d/*.conf` descriptor (currently `dtctl`, `dtmgd`) accepts `ON` (auto-detect latest from GitHub), `x.y.z` (pinned), or `OFF` — this grammar is independent of the tool, so a future tool added the same way follows it automatically.
- `node` always installs the latest LTS (required by the AI agents); `node=20,22` adds those versions alongside it. `nvm-version` pins the nvm release used to install Node (e.g., `nvm-version=v0.40.5`); leave empty for the Dockerfile default.
- `db-clients` also accepts a comma-separated list, but drawn from the closed set `pg`, `mysql`, `mongo` (not version numbers) — installs **client** shells/dev libraries only (`libpq-dev`+`postgresql-client`, `default-libmysqlclient-dev`+`default-mysql-client`, `mongosh`), never a database server, and is language-agnostic. An entry outside that set is rejected by `build.sh`'s `validate_config` with a clear error rather than reaching the build. Selecting `mongo` adds `repo.mongodb.org` to the generated domain allowlist automatically. Setting `ruby` to any version, or `db-clients` to a non-empty value, makes `build.sh` set `KEEP_BUILD_TOOLCHAIN=1`, so the Dockerfile keeps `build-essential`/`libyaml-dev`/`zlib1g-dev`/`libssl-dev` instead of stripping them, letting native extensions compile at runtime.
- **A version-list key set to the literal `OFF` means "skip", exactly like the empty `key=`.** The two grammars share one file, so `ruby=OFF` is a natural thing to write; `version_list()` in `sandbox-common.sh` normalises it to empty and `has_versions()` reports it as unset, keeping both consistent with `is_active()`. Use `version_list` — never `get_versions` — wherever a version-list *value* is emitted into a build arg or the container env, because `get_versions` must keep returning `OFF` verbatim for the boolean keys. (Without this, `ruby=OFF` baked the whole Ruby build toolchain **and** shipped `RUBY_VERSIONS=OFF` into the container, so `rvm-reconcile.sh` bootstrapped rvm and ran `rvm install OFF` on every container start, into an `~/.rvm` that `sandbox.sh` — correctly using `is_active` — had not mounted.)

**Schema changes to `sandbox.conf`.** Adding a new on/off or version-list key needs nothing extra: no marker bump, no hook. `sync-to-projects.sh` reconciles each project's copy on every sync — it appends new upstream keys and never touches keys a project already set. Renaming a key, splitting it into multiple keys, removing it, or changing what its value means while keeping the same key name requires a `migrations/NNN-*.sh` hook — author it with `./bump-sandbox-version.sh <slug>`, and see the README "sandbox.conf schema versioning" section. Never redefine an existing key's semantics in place; always introduce a new key name for a semantic change. The reconcile mechanism assumes an existing key's meaning never silently changes underneath a project that has already set it — violating this discipline is not automatically detectable by tooling. `check-sandbox-version.sh --check` is the CI gate that blocks a removal/rename lacking a matching hook and marker bump — in CI it MUST be run with `BASE_REF` set to a ref that predates the change (e.g. `BASE_REF="$(git merge-base HEAD origin/main)"`), never left at its default `HEAD`, which silently no-ops once the change is committed (see README "sandbox.conf schema versioning").

## Commands

**Build the image:**
```bash
./build.sh [image-name]
```
`build.sh` reads `sandbox.conf`, assembles `allowlist-domains.txt`, `allowlist-proxy-domains.txt`, and `allowlist-cidrs.txt` from the `*.d/` fragment directories, then calls `docker build` with one `--build-arg` per component. External CLI tools described in `tools.d/*.conf` (currently `dtctl`, `dtmgd`) are the one exception: instead of one `--build-arg` each, every active one is folded into a single `--build-arg TOOL_VERSIONS="dtctl=0.25.0;dtmgd=latest"` (see below). The generated `allowlist-*.txt` files are gitignored; always use `./build.sh`, not `docker build` directly. (`sandbox.sh build` was removed — it now errors and points here.)

The AI agents (Copilot, Claude Code, Codex, Gemini), `graphify`, and `vale` are **not** installed at build time at all — they install at container start into a per-user, group-mounted `~/.ai-tools` home and self-update in place; see "Agent-tier tools" below. **Kiro** and every `tools.d`-described tool (`dtctl`, `dtmgd`, `acli`) remain baked at build time and Docker caches those layers, so a normal `./build.sh` will not pick up a newer release of any of them — refresh with a full rebuild:
```bash
./build.sh --no-cache
```
or, where the tool supports it (`dtctl`/`dtmgd` accept a pinned `x.y.z` in `sandbox.conf`), bump the pinned version instead of rebuilding everything.

**Replaced images are cleaned up.** `build_image()` records the tag's image ID before the build and calls `remove_replaced_image` (in `sandbox-common.sh`) afterwards, so a dangling layer set does not accumulate per rebuild per project — from a few hundred MB up to the whole multi-GB image for a `--no-cache` rebuild. Keep that cleanup narrow: one explicit image ID, skipped when the image still carries any tag, `docker rmi` **without** `--force` so an image a container still references survives, and never a broad `docker image prune` (the daemon store is shared with `ai-containers-seed` and every other project's image). Build-cache records are only ever *suggested* for pruning (`docker builder prune --filter unused-for=720h`), never removed automatically.

**Agent-tier tools (`~/.ai-tools`).** Mirroring the per-user rvm approach above: nothing agent-tier is baked into the image. Claude Code, Codex, Gemini, Copilot, `graphify`, and `vale` install at container start into `~/.ai-tools` (npm packages land in `~/.ai-tools/npm`, `graphify`'s `uv` tool dir `~/.ai-tools/uv`, `vale`'s binary in `~/.ai-tools/bin`), group-mounted like the agent dotfile dirs (see [Host directory mounts](#host-directory-mounts)) so the install is shared by every project using that group and survives container restarts and rebuilds. Unlike `uv` (pointed at the tool home via exported `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR`, which nvm never looks at), npm gets **no** baked global prefix — nvm is sourced into every login/interactive shell (`/etc/bash.bashrc`), and its `nvm_die_on_prefix` check fails `nvm use <version>` outright, not just a warning, whenever `$HOME/.npmrc` sets a `prefix`, which broke the `node=` multi-version workflow `sandbox.conf` supports. `agent-tools-reconcile.sh` (sandbox user, `flock`-guarded against concurrent same-group starts) installs whichever `AI_RUNTIME_TOOLS`-enabled npm-based tool is missing with `npm install -g --prefix "$HOME/.ai-tools/npm" <pkg>` — install-if-missing only, non-fatal on failure. nvm's prefix check inspects `.npmrc`/`$PREFIX`/`$NPM_CONFIG_PREFIX`, never a command's own flags, so a per-invocation `--prefix` does not trip it (verified against nvm's `nvm_die_on_prefix` source, not assumed). Because the install lives in a user-writable directory rather than a root-owned image layer, each tool keeps itself current with its own updater (e.g. the CLI's own auto-updater, `uv tool upgrade`); for the npm-installed CLIs (Claude Code, Codex, Gemini, Copilot), use the baked `npm-agent-tools` shell function instead of a bare `npm update -g` — e.g. `npm-agent-tools update -g` — which forwards `--prefix "$HOME/.ai-tools/npm"` so the update lands in the group-mounted tool home rather than nvm's own node directory (a bare `npm update -g` would update whatever nvm currently has active instead). `npm-agent-tools` is a shell function (not an exported env var), defined alongside `PATH`/`uv` env in `/etc/profile.d/ai-tools.sh`, available in login/interactive shells; it is deliberately not an env var because exporting `NPM_CONFIG_PREFIX` globally would trip the same nvm check the removed `.npmrc` prefix did. `link-agent-tools.sh` then symlinks each installed binary onto `/usr/local/bin` (root, run after the reconcile) so non-interactive, non-login shells resolve the tools themselves too — though not the `npm-agent-tools` convenience function, which stays login/interactive-only like `PATH`/`uv` env.

**The `tools.d/` descriptor model.** Each external CLI tool the image can install (currently `dtctl`, `dtmgd`, `acli`) is described by one `tools.d/<name>.conf` file — `repo=` (GitHub `owner/repo`), `binary=` (installed executable name), `private=yes|no`, `config_dir=` (host-seeded, group-scoped config path, or several space-separated paths for a tool that splits config and credentials — see [Host directory mounts](#host-directory-mounts)), `allowlist_fragment=` (which `*.d/<fragment>.txt` to include), `skills=yes|no`, and `skills_crossclient=` (flags for a cross-client Agent Skill). `tools-lib.sh` is the shared parser, sourced by both host scripts (via `sandbox-common.sh`) and container scripts. `build.sh` turns every tool whose `sandbox.conf` key (`dtctl=`, `dtmgd=`) is `ON` or a pinned version into one `name=version` pair and passes them all as a single `--build-arg TOOL_VERSIONS="dtctl=0.25.0;dtmgd=latest"`. `install-tools.sh` reads `TOOL_VERSIONS` at build time and installs each tool from its descriptor's GitHub repo — adding a new tool this way needs only a new `.conf` file, no changes to `build.sh`, the Dockerfile, or the allowlist logic. `install=` selects how the binary is obtained: `release` (default) downloads the release asset `<binary>_<version>_<os>_<arch>.tar.gz`; `repo-file` fetches a **prebuilt binary committed in the repo** at `repo_path=` (via the contents API with `Accept: application/vnd.github.raw`, straight into `/usr/local/bin`, no archive to unpack); `url` downloads from an arbitrary **vendor-hosted** `url=`, for a tool published outside GitHub — a `.tar.gz`/`.tgz` is unpacked and `binary` is located *anywhere* inside it (vendors commonly nest it in a version-named directory, e.g. `acli_1.3.22-stable_linux_arm64/acli`), any other URL is treated as the binary itself, and no token is involved. `url=` and `repo_path=` accept the **braced** placeholders `${OS}`, `${ARCH}` and `${VERSION}` (braced only — an unbraced `$OS` would also match inside `$OSNAME`). A `url=` without `${VERSION}` cannot honour a pinned version, and says so instead of installing something else silently. An archive holding two files with the target `binary=` name is refused rather than guessed at. `repo_path` may contain `${ARCH}`, expanded to the image's `amd64`/`arm64`. `ref=` pins a branch/tag/commit and the `sandbox.conf` value wins over it, so a `repo-file` tool's key grammar is `ON | <git-ref> | OFF` — there are no release versions to pin. Everything else is identical: `private=yes` still makes `GITHUB_TOKEN` required, failures are still non-fatal, and the tool still lands in the same baked Dockerfile layer, so `./build.sh --no-cache` re-fetches an unpinned tool too (a pinned `ref=`/version is unaffected by cache state). `TOOL_VERSIONS` is `build.sh`'s internal transport: you only construct its `name=version;...` string by hand when calling `docker build` directly, bypassing `build.sh`.

**`GITHUB_TOKEN` essentiality** depends on the descriptor's `private` field:

| Tool visibility | `GITHUB_TOKEN` | Effect if unset |
|---|---|---|
| Public (`private=no` — `dtctl`, `dtmgd`) | Optional | Unauthenticated GitHub API, 60 req/h; pinning a version (e.g. `dtctl=0.25.0`) skips the API call entirely and needs no token at all |
| Private (`private=yes`) | Required | Tool is skipped with a warning; `build.sh` also prints a non-fatal preflight warning before the build starts if a private tool is enabled with no token set |

This open-source repo ships **no private tool** — both `dtctl` and `dtmgd` are public, so `GITHUB_TOKEN` here is always an optional rate-limit convenience, never a requirement. `build.sh` passes it automatically as a BuildKit secret if the env var is set (falling back to `GITHUB_PERSONAL_ACCESS_TOKEN`). If a public tool hits the rate limit, `install-tools.sh` prints a warning and skips it — the build still succeeds.

**Run the container:**
```bash
./sandbox.sh restricted [primary]   # firewall on, NET_ADMIN+NET_RAW dropped from agent shell
./sandbox.sh discovery  [primary]   # unrestricted egress + background pcap
./sandbox.sh open       [primary]   # unrestricted egress, NO capture, NET_ADMIN+NET_RAW dropped
```
Everything mounts under a single `/workspace` umbrella. The positional `[primary]` sets the working directory:
- `@<repo>` — a registered repo volume (see `repo.sh`) becomes the working dir at `/workspace/<repo>` (fast on macOS; attached writable automatically, error if listed `:ro`).
- `<host-path>` — bind-mounted at `/workspace/<basename>` (rw) and used as the working dir (virtio-fs; slow on macOS).
- omitted — working dir is the `/workspace` umbrella itself.

**Manage shared repo volumes:**
```bash
./repo.sh add  <name> <host-path|git-url>   # seed a repo volume once + register it
./repo.sh sync <name|--all>                  # refresh (git pull, or re-copy a path source)
./repo.sh reset <name|--all> [--yes]         # discard local changes → clean slate (keeps registry)
./repo.sh list [--sizes] [--copies]          # list repos; --copies lists :rwcopy working copies
./repo.sh rm   <name> [--yes]                # remove volume + working copies + registry entry
./repo.sh gc   [--repo <name>] [--unused] [--yes]   # prune :rwcopy working copies
./repo.sh reindex                            # rebuild registry from volume labels
```
Attach them at run time with `REPOS="cluster:ro lib:ro app:rw" ./sandbox.sh restricted @app`.

**Manage container groups:**
```bash
./group.sh list [--sizes]        # groups + their rvm volumes; flags orphaned volumes
./group.sh rm   <group> [--yes]  # remove a group: its directory AND its rvm volume
./group.sh gc   [--yes]          # remove rvm volumes whose group directory is gone
```
A group owns a directory (`~/.ai-containers/<group>/`) **and**, once `ruby=` is set, a Docker volume for its Ruby home — so `rm -rf` alone orphans a multi-GB volume. `group.sh rm` removes both; `gc` cleans up after a manual `rm -rf`. It refuses while a running container mounts the volume, refuses the `host` group, and never touches repo volumes (global, `repo.sh` owns them).

**Initialise a new project** (copies shared files, writes `sandbox.env`, generates launch script, registers in `projects.conf`, and adds `/.ai-containers/` to the project's root `.gitignore`):
```bash
./project-init.sh /path/to/myproject [optional-name]
```
The per-project `.ai-containers/` is a synced working copy; its `sandbox.local.env` holds machine-specific `EXTRA_MOUNTS`/`REPOS` paths, so it is git-ignored in the project by default — idempotent, git repos only, and `sync-to-projects.sh` backfills it for existing projects. Remove the line to version the **portable** config (`sandbox.env`/`sandbox.conf`/thin `runme.sh`) with a team — `sandbox.local.env` stays gitignored on its own — or set `AI_CONTAINERS_NO_GITIGNORE=1` to skip.

**Migrate a project off the old fat `runme.sh`** (one-off; only for projects provisioned before the thin-launcher split):
```bash
./migrate-runme.sh --dry-run /path/to/project   # inspect what would change
./migrate-runme.sh /path/to/project             # migrate
./migrate-runme.sh                              # every project in projects.conf
```
Parses the old launcher's `export` lines into a portable `sandbox.env` plus a machine-local `sandbox.local.env`, then replaces it with the thin `runme.sh` that `project-init.sh` generates — the same `emit_launcher()` function, so the two cannot drift. Old files are copied to `*.pre-migrate` (timestamped if a backup already exists) and never deleted. `--dry-run` writes nothing. Non-interactive: it needs no stdin and prompts for nothing.

**Sync shared files to all registered projects** (after pulling updates to this repo):
```bash
./sync-to-projects.sh              # all projects in projects.conf
./sync-to-projects.sh /path/to/p   # single project
```

**Run the runtime integration tests** (needs a real Docker daemon — a host, not a sandbox container):
```bash
./tests/integration/run.sh                       # the whole corpus
./tests/integration/run.sh --list                # cases with their tags/requires
./tests/integration/run.sh --list-caps           # what this machine can actually do
./tests/integration/run.sh --tags fast --exclude needs-dns --require security
```
Cases live in `tests/integration/cases/` and declare `tags:` and `requires:` in header comments; the runner detects capabilities and selects. **Selection and skipping are different outcomes and are reported separately** — `--tags`/`--exclude` choose what runs, a SKIP is a selected case whose requirement was unmet, and `--require <tag>` makes any such skip fail the run. A case that cannot run is never counted as a pass.

The suite asserts **effect, not configuration**: it observes from outside the container whether the packet arrived, the file exists, the log line is present. `tests/test-entrypoint-wiring.sh` asserts the capture daemon is *wired into* `entrypoint.sh` and passed every day of a months-long outage, because the wiring was correct and the daemon died after being started.

Two known-bad daemons are kept in `tests/integration/fixtures/`, each preserving a *different* real bug that shipped, so the cases that catch them can be demonstrated failing. Do not "consolidate" or repair them.

`bash ./verify-on-host.sh` runs the same corpus (Phase 4) plus the package/Ruby phases that have no case coverage yet. It is a platform-adaptive **host** entry point: the identical command on macOS + Colima and on Linux.

CI runs the `fast` tier on every PR (`.github/workflows/integration.yml`) and the **whole** corpus nightly (`.github/workflows/nightly.yml`), including the `slow` and `needs-dns` cases the gate excludes on cost — so a case excluded on cost is still a case that runs. `nightly.yml` also checks that every domain in `allowlist-domains.d/` still resolves; fragments rot silently, and the only symptom is a tool that mysteriously cannot install behind the firewall.

**Extract discovery results** (after exiting a discovery-mode container — the pcap is in `.agent-discovery/` of the launch directory):
```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/launch-dir:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

**Key env vars for `sandbox.sh`:** set inline for one run (`VAULT_PATH=/path ./sandbox.sh restricted`)
or export in the host shell profile to default for every container. The **In container** column
marks visibility to agents inside the container: **forwarded** (passed through unchanged),
**→ `/path`** (re-exported pointing at the in-container mount path), **mount** (filesystem mount,
no env var inside), **—** (launcher/`docker run` only). `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH` are
host-directory pointers meant to be exported once in the host profile; their effective default is
the host-exported value (unset → mount skipped; a target directory that doesn't exist warns).

The three pointers form a personal / team / product tier:

| Var | Mount | Meaning | Mode |
|---|---|---|---|
| `VAULT_PATH` | `/workspace/vault` | **Personal** knowledge base (Obsidian vault or any markdown KB) | read-write |
| `SPECS_PATH` | `/workspace/specs` | **Team / shared** specs, designs, plans | read-write |
| `DOCS_PATH` | `/workspace/docs` | **Product documentation** (grounding) | read-only (default) |

| Variable | Purpose | Default | In container |
|---|---|---|---|
| `IMAGE_NAME` | Image tag to run. Persisted per project in `<project>/.ai-containers/sandbox.env` and sourced by `sandbox-common.sh` when not exported. | `ai-sandbox` | forwarded |
| `AI_CONTAINER_GROUP` | Which dotfile tree (group) to mount: `default`, `host` (mounts `$HOME`), or a custom `~/.ai-containers/<name>/`. | `default` | — |
| `AI_CONTAINER_GROUP_INIT` | Non-interactive first-time group bootstrap: `clean` \| `from:host` \| `from:<existing-group>`. | interactive prompt | — |
| `AI_CONTAINER_HOST_ACK` | Set `1` to silently bypass the macOS `host`-group warning. Ignored on Linux; per-invocation. | `0` | — |
| `SANDBOX_UID` / `SANDBOX_GID` / `SANDBOX_USER` / `SANDBOX_GROUP` | Override the auto-detected container user identity. | detected from host (`id`) | forwarded |
| `REPOS` | Space-separated **registered** repo volumes to attach under `/workspace/<name>`, each `:ro` (default), `:rw`, or `:rwcopy`. Register first with `./repo.sh add`; unregistered/missing → abort. | none | mount |
| `REPO_BACKEND` | How a repo is backed: `auto` \| `volume` \| `bind`. Decided at `repo.sh add` time and stored in the registry. | `auto` | — |
| `EXTRA_MOUNTS` | Space-separated extra host paths bind-mounted under `/workspace/<basename>`; append `:ro`/`:rw`. Same-basename collisions with `REPOS`/primary are errors. | none | mount |
| `VAULT_PATH` | Host directory mounted read-write at `/workspace/vault` — your **personal** knowledge base (an Obsidian vault is typical, but any markdown corpus works, e.g. imported Jira tickets under `$VAULT_PATH/jira-products`, read heavily by several workflows). Pair with `qmd=ON` for in-container search. | host `$VAULT_PATH` export | → `/workspace/vault` |
| `SPECS_PATH` | Host repo of AI-ready specifications, design documents, and development plans — the **team/shared** knowledge base — mounted read-write at `/workspace/specs`. Consumed by spec-driven workflows (e.g. the dev-workflows plugin). Accepts `@<name>` for a registered repo volume (mounted at `/workspace/<name>`; fast on macOS). | host `$SPECS_PATH` export | → `/workspace/specs` |
| `DOCS_PATH` | Host **product-documentation** repo mounted **read-only** by default at `/workspace/docs`, re-exported as `DOCS_PATH=/workspace/docs`. Grounding for plugin workflows (idea / VI / release-notes). Accepts `@<name>` (→ `/workspace/<name>`) and a `:ro`/`:rw` suffix (default `:ro`). When the docs repo is the working dir, `DOCS_PATH` re-points to that writable mount; to edit docs otherwise use `:rw`. | host `$DOCS_PATH` export | → `/workspace/docs` |
| `PREVIEW_PORTS` | Space-separated ports (or `host:container` pairs) to publish for dev servers. | none | — |
| `CONTAINER_CPUS` | CPU limit for the running container. | `1.0` | — |
| `CONTAINER_MEMORY` | Hard memory limit. | `4g` | — |
| `CONTAINER_MEMORY_RESERVATION` | Soft memory limit (must be ≤ `CONTAINER_MEMORY`). | `2g` | — |
| `CONTAINER_MEMORY_SWAP` | Memory + swap total (≥ `CONTAINER_MEMORY`; set equal to disable swap, `-1` for unlimited). | `4g` | — |
| `CONTAINER_NOFILE` | Open-file-descriptor limit, `soft[:hard]`. | `1048576:1048576` | — |
| `SELF_HEALING_ENABLED` | Set `0` to disable reactive IP auto-allowing (logging only). | `1` | forwarded |
| `ALLOW_IPV6_BYPASS` | Set `1` to suppress the `ip6tables`-unavailable warning (WSL2/nf_tables). Read by the container's firewall init (`entrypoint.sh`). | `0` | forwarded |
| `COPILOT_GITHUB_TOKEN` | Copilot CLI auth token; bypasses device-flow OAuth. When unset, auto-extracted from the group's `~/.config/gh/hosts.yml`. Accepts a fine-grained PAT with "Copilot Requests" permission or a `gh` OAuth token. | auto from `gh` | forwarded |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | Forwarded as-is for tools that expect this exact name (github MCP servers, Claude Code github plugin). | none | forwarded |
| `SANDBOX_ENV_FILE` | Path to a `KEY=VALUE` env-file injected into the container via `docker run --env-file` — non-secret in-container **application** env (e.g. `DB_HOST`, `REDIS_URL`), not credentials. | `<project>/.ai-containers/container.env` if present, else unset | — |

## Architecture

### Container startup flow

`entrypoint.sh` runs as root and drives all three modes:

1. **`setup_sandbox_user`** — creates/renames a user whose UID/GID match `SANDBOX_UID`/`SANDBOX_GID` (passed by `sandbox.sh` from `id -u`/`id -g`). Files in bind-mounted volumes are then accessible without chown. **`chown_workspace_root`** then chowns the in-image `/workspace` umbrella root to the sandbox user (non-recursive; sub-mounts keep their own ownership) so the agent can use it.

2. **restricted mode**: calls `apply_restricted_firewall` → forks the ipset refresh loop and `capture-blocked-traffic.sh` as root background daemons → `run_agent_skill_install` (see below) → `exec capsh --drop=cap_net_admin,cap_net_raw --user=<sandbox>` to drop firewall-modification capabilities from the agent shell.

3. **discovery mode**: calls `apply_discovery_firewall` (iptables OUTPUT ACCEPT) → starts `capture-agent-destinations.sh` for pcap → `run_agent_skill_install` → `exec capsh --drop=cap_net_admin --user=<sandbox>`. The drop names only `cap_net_admin`, but the agent shell ends up with **no capabilities at all**: `capsh --user=` setuids from root, and the kernel clears the permitted and effective sets on that transition unless `PR_SET_KEEPCAPS` is set (`capsh --keep=1`, which is not used). So `--drop=cap_net_admin` and `--drop=cap_net_admin,cap_net_raw` are equivalent here. This is deliberate: the pcap daemon is started as root at `entrypoint.sh:203`, before the exec at line 243, so it keeps its own capabilities and needs nothing from the agent shell. Verified by case `230` in the integration suite.

4. **open mode**: no firewall is applied and no capture daemon is started (unrestricted egress, no logging) → `run_agent_skill_install` → `exec capsh --drop=cap_net_admin,cap_net_raw --user=<sandbox>` (same capability drop as restricted mode). `sandbox.sh` passes an empty `capabilities=()` array for this mode (neither `--cap-add=NET_ADMIN` nor `--cap-add=NET_RAW`). Equivalent in effect to the historical `DISCOVERY_CAPTURE_ENABLED=0 ./sandbox.sh discovery`, but as an explicit, honestly named mode rather than a flag on discovery.

Background daemons are forked **before** `exec capsh` so they retain root capabilities despite the exec. `run_agent_skill_install` runs as the sandbox user (via `runuser`) in all three modes, right before the `capsh` exec — see [Automatic Agent Skill installation](#automatic-agent-skill-installation) below.

### Automatic Agent Skill installation

`install-agent-skills.sh` (copied to `/usr/local/bin/` at build time) installs each installed `tools.d`-described tool's Agent Skill for every enabled AI agent. `entrypoint.sh` runs it via `runuser -u <sandbox> -- env AI_AGENTS_ENABLED="..." bash /usr/local/bin/install-agent-skills.sh`, non-fatally (`|| true` — it never blocks or fails container start). `AI_CONTAINER_GROUP`-independent: it acts on `$HOME` inside the container, i.e. the sandbox user's home, which is where the tool binaries and `~/.agents/` live regardless of group.

- **Which tools:** any descriptor with `skills=yes` (both `dtctl` and `dtmgd` do) whose binary is present on `PATH` (i.e. the tool was actually installed at build time).
- **Which agents:** `sandbox.sh` passes `AI_AGENTS_ENABLED` — a comma-separated list of `sandbox.conf` agent keys that are `ON` (from `sandbox-common.sh`'s `enabled_agents_csv`). `map_agent` translates a `sandbox.conf` key to the tool's `--for` agent name (currently only `claude-code → claude`; everything else passes through unchanged, e.g. `copilot → copilot`).
- **Cross-client skill:** if the descriptor sets `skills_crossclient=` (both `dtctl` and `dtmgd` do), that flag is passed once (e.g. `dtctl skills install --cross-client --global --force`) in addition to the per-agent installs.
- **Idempotent via a version stamp:** `current_stamp` builds one `name=$(binary --version)` line per skills-capable installed tool (sorted); if it matches `~/.agents/.ai-containers-skills-stamp` from the last run byte-for-byte, the whole install step is a no-op. This means a normal container start (same image, same tool versions) does the skill install exactly once, not on every start — it only re-runs after a tool's version changes (e.g. after a rebuild that picks up a newer release).
- **Never fails container start:** each `<tool> skills install ...` call is best-effort (`>/dev/null 2>&1`); a tool with no supported agent, or one that errors, is reported inline (`  <tool> → (no supported agents)`) and does not stop the loop.

### Mount layout (`/workspace` umbrella) and repo volumes

`/workspace` is an in-image directory used as a **mount root**, not a host bind mount. Everything attaches as a subdirectory:
- positional `[primary]` → `/workspace/<basename>` (host bind) or `/workspace/<repo>` (volume, via `@repo`); also sets `-w`
- `REPOS` → `/workspace/<name>` (Docker named volumes, or host binds on Linux)
- `EXTRA_MOUNTS` → `/workspace/<basename>` (host binds)
- `VAULT_PATH` → `/workspace/vault`
- `SPECS_PATH` → `/workspace/specs` (or `/workspace/<name>` via `@name`)
- `DOCS_PATH` → `/workspace/docs` (read-only by default; `/workspace/<name>` via `@name`; the working-dir mount when the docs repo is the working dir)
- outputs → `/workspace/.agent-blocked` and `/workspace/.agent-discovery`, bind-mounted from the host **launch directory** (`$PWD` where `sandbox.sh` ran), so they persist host-visibly and git/docker-ignored.

**Repo volumes** (`repo.sh` + `REPOS`) solve the macOS virtio-fs penalty: a repo is seeded **once** into a Docker named volume inside the VM (`ai-containers-repo-<name>`), read at native speed, and shared across all projects/images and container groups. The volume name is **image-independent** (a fixed `ai-containers` prefix, overridable via `REPO_VOLUME_PREFIX`), so one registered repo maps to one global volume that any number of containers — in any project — can mount, with no `IMAGE_NAME` juggling. The registry is `~/.ai-containers/repos.conf` (machine-local, pipe-delimited: `name|type|source|added|synced|backend`). **Docker volumes are the source of truth, not the registry:** each base volume carries `ai-containers.repo`/`.type`/`.source` labels and each working copy carries `ai-containers.repo`/`.workcopy`/`.launch-dir`, so `repo.sh list`/`list --copies`/`gc` read state directly from Docker. The registry is a cache, authoritative only for Linux `bind`-backend repos (no volume to label) and the mutable last-synced time (labels are immutable after creation); `repo.sh reindex` rebuilds it from volume labels. `:rwcopy` creates a per-launch-dir working copy volume (`<base>--wc-<tag>`), prunable via `repo.sh gc`. On Linux, `auto` backend registers `path` repos as bind-mount aliases (no volume seeded); `sandbox.sh` bind-mounts the host path directly. Source-of-truth helpers live in `sandbox-common.sh`.

Seeding (`repo.sh add`/`sync`) runs in a small, **shared** helper image — `ai-containers-seed` (Alpine + git/openssh-client/rsync/bash), built on demand from `Dockerfile.seed`. It is deliberately independent of the sandbox image and of `IMAGE_NAME` (one image reused by every project, not one per project), so repos can be seeded before `./build.sh` is ever run. Override with `REPO_SEED_IMAGE`. These seeding containers run as a plain `docker run` (not via `entrypoint.sh`), so the firewall does not apply to them.

**Launcher config — three env layers.** `container.env` is the *in-container application* env (`DB_HOST`, `REDIS_URL`, …), auto-detected by `sandbox.sh` and injected via `docker run --env-file` (`SANDBOX_ENV_FILE`) — unrelated to the two host-side files below. `sandbox.env` (tracked, PORTABLE) and `sandbox.local.env` (gitignored, THIS MACHINE) hold the *host launcher* config: `sandbox.env` carries `IMAGE_NAME`, `AI_CONTAINER_GROUP`, `CONTAINER_*`, `SANDBOX_MODE`, `SANDBOX_WORKDIR`; `sandbox.local.env` carries `AI_CONTAINER_GROUP_INIT` (a host-referential one-time group bootstrap), `EXTRA_MOUNTS`/`REPOS`, and any per-machine override. `sandbox-common.sh`'s `load_env_defaults` parses both (never sources — only `KEY=value`, no arbitrary code) with **set-if-unset** semantics, loading local **before** portable, giving precedence **inline env > `sandbox.local.env` > `sandbox.env`**. Parsing alone is not sufficient for the "inert data" guarantee, so keys that would hand control of the **shell** to the file — `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `CDPATH`, `IFS`, `PS4`, `PATH`, the `LD_*`/`DYLD_*` loader vars, and `BASH_FUNC_*` — are **refused with a warning** (`env_key_denied`): `sandbox.env` is designed to be committed and shared, and a perfectly well-formed `BASH_ENV=./x.sh` line would otherwise be exported and then executed by the next child `bash` that `build.sh`/`sandbox.sh` spawn. These files configure the launcher, never the shell. Every entry point (`build.sh`/`sandbox.sh`/`repo.sh`) loads them, so all resolve the same config run directly or via the thin `runme.sh`. `sandbox.sh`'s positional `<mode> <workdir>` fall back to `SANDBOX_MODE`/`SANDBOX_WORKDIR` (a positional arg or inline env still wins; with neither, mode → `usage`, workdir → the `/workspace` umbrella), which is what lets `runme.sh` call a bare `./sandbox.sh`. `sync-to-projects.sh` backfills `sandbox.env` for older projects and never overwrites either file; it also **backfills the project's inner `.ai-containers/.gitignore`** (append-only, idempotent) so `sandbox.local.env` is ignored even in a project that predates that pattern — which matters most for a project that deliberately *tracks* `.ai-containers/`, where the root `.gitignore` protects nothing. (Repo-volume names use the global `ai-containers-repo-<name>` scheme, independent of `IMAGE_NAME`.)

### Network enforcement

- `refresh-ipset-allowlist.sh` resolves every FQDN in `allowlist-domains.txt` via `getent` and populates two ipset sets (`allowed_ipv4`, `allowed_ipv6`). It runs at startup and loops every 60 s as a background daemon.
- iptables OUTPUT chain: ESTABLISHED/RELATED → loopback → DNS (port 53) → ipset match → **NFLOG** → default DROP.
- The NFLOG target (group 100) delivers blocked packets to userspace via netlink, which works reliably in WSL2 / nf_tables environments where the LOG target does not.
- **WSL2/nf_tables caveat:** `ip6tables` may be unavailable; when it is, IPv6 outbound traffic is unrestricted. The container prints a warning to stderr at startup. IPv4 enforcement is unaffected.

### Blocked-traffic capture (`capture-blocked-traffic.sh`)

Two background tshark processes:
- **DNS map builder** — sniffs port-53 responses, builds `/run/agent-blocked-internal/dns-map.txt` (IP → FQDN), stored in a root-only directory inaccessible to the sandbox user.
- **NFLOG watcher** — reads packets from `nflog:100`, correlates each destination IP against the DNS map, and appends to:
  - `blocked.log` — full timestamped log
  - `blocked-domains.txt` — deduplicated domains for copy-paste into `allowlist-domains.d/custom.txt`
  - `blocked-ips.txt` — IPs with no known domain, for `allowlist-cidrs.d/custom.txt`

**Self-healing** (on by default): if a blocked IP resolves to a domain already in the baked-in `/tmp/allowlist-domains.txt` or matching a wildcard in `/tmp/allowlist-proxy-domains.txt` (both assembled at build time from the `*.d/` fragments), the daemon calls `ipset add` immediately without waiting for the 60-second refresh loop. This handles dynamic IPs behind CDNs (e.g. `*.githubcopilot.com`).

### Allowlist files

The three `allowlist-*.txt` files baked into the image are assembled at build time from fragment directories:

| Directory | Generated file | Always-included file |
|-----------|---------------|----------------------|
| `allowlist-domains.d/` | `allowlist-domains.txt` | `base.txt`, `custom.txt` |
| `allowlist-proxy-domains.d/` | `allowlist-proxy-domains.txt` | `custom.txt` |
| `allowlist-cidrs.d/` | `allowlist-cidrs.txt` | `base.txt`, `custom.txt` |

Per-component fragments (`github-copilot.txt`, `kiro.txt`, `claude-code.txt`, `codex.txt`, `kubectl.txt`, `aws-cli.txt`, `azure-cli.txt`, `openjdk.txt`) are only concatenated when the matching component is `ON` in `sandbox.conf`; `openjdk.txt` when any JDK variant is enabled. Tools described in `tools.d/` name their fragment via the descriptor's `allowlist_fragment=` field instead of a hardcoded component check: `build.sh` auto-discovers every active tool's fragment name and includes it once. Both `dtctl.conf` and `dtmgd.conf` set `allowlist_fragment=dynatrace`, so `dynatrace.txt` is included whenever either (or both) is active — a future tool can reuse that same fragment or declare its own by setting `allowlist_fragment=<name>` and adding `allowlist-domains.d/<name>.txt` (and the matching proxy-domains fragment if needed), with no change to `build.sh` itself.

To add domains not tied to any component (e.g. `google.com`, internal registries, MCP endpoints), edit the appropriate `custom.txt` file in the relevant `*.d/` directory.

**First-time setup:** each `allowlist-*.d/` directory ships a `custom.txt.example`. Copy it to `custom.txt` before adding entries — the `custom.txt` files are gitignored and won't be assembled into the image otherwise.

### Conditional installs in the Dockerfile

Every optional component still baked into the image has a corresponding `ARG INSTALL_<COMPONENT>=0|1` (or, for Angular CLI, `ARG ANGULAR_CLI_VERSION`) declared immediately before its `RUN` block — e.g. Angular CLI, Yarn, Kiro — each with its own `RUN` layer so toggling one doesn't invalidate the others. The six agent-tier tools (Copilot, Claude Code, Codex, Gemini, `graphify`, `vale`) have **no** `ARG`/`RUN` pair at all: they are not part of the Dockerfile build, only scaffolding (`PATH`/`uv` env, the `npm-agent-tools` wrapper function — deliberately no baked npm prefix, see "Agent-tier tools" above) is baked, and the tools themselves install at container start into `~/.ai-tools` (see "Agent-tier tools" above). `tools.d/`-described tools (`dtctl`, `dtmgd`) are the exception among the still-baked components: instead of one `ARG`/`RUN` pair per tool, a single `ARG TOOL_VERSIONS=""` feeds one `RUN` block that copies `tools.d/`, `tools-lib.sh`, and `install-tools.sh` into the image and lets the script loop over every `name=version` pair in `TOOL_VERSIONS`. A tool with no entry in `TOOL_VERSIONS` (its `sandbox.conf` key was `OFF`) is skipped by the script itself, not by a Dockerfile conditional. That one `RUN` layer always mounts the `github_token` BuildKit secret (`--mount=type=secret,id=github_token`), used for both public-tool rate-limit auth and — when a descriptor sets `private=yes` — required private-tool auth; this repo ships no private tool, so today the secret is only ever the optional rate-limit convenience. `install-agent-skills.sh` is copied into the image (`/usr/local/bin/install-agent-skills.sh`) alongside the installer but is not run at build time — it runs at container start (see [Container startup flow](#container-startup-flow)).

### Sandbox user identity

No user is baked into the image. `entrypoint.sh` calls `useradd`/`usermod` at runtime using the env vars from `sandbox.sh`. This means the same image works for any team member without rebuilding.

`sandbox.sh` passes `SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"` / `SANDBOX_GID="${SANDBOX_GID:-$(id -g)}"`. `repo.sh` resolves the **same** values to `chown` repo-volume contents at seed/sync time (it previously hardcoded `id -u`/`id -g`, which broke the override). Because Linux permissions are by numeric UID/GID, you must use the **same** identity for both: with no override they both use the host user; if you override `SANDBOX_UID`/`SANDBOX_GID`, export the same values for both `repo.sh` and `sandbox.sh` or mounted repo volumes end up owned by the wrong UID and the agent hits permission errors. (Linux `bind`-backend repos are mounted directly with no `chown`, so they're unaffected.)

### Host directory mounts

Agent dotfile dirs (`.claude`, `.copilot`, `.kiro`, `.codex`, `.gemini`, `.config/gh`, `.agents`, `.ssh`) are mounted from a **container group** — a named directory under `~/.ai-containers/<group>/`. The active group is selected by `AI_CONTAINER_GROUP` (default: `default`). To use a custom group, set the env var before running: `AI_CONTAINER_GROUP=docs ./sandbox.sh restricted /path/to/workspace`. A group is *mostly* a plain directory — `ls ~/.ai-containers/` and `cp -a` still inspect and duplicate one — but **deleting is not**: once a group has a Ruby home it also owns a Docker volume, and `rm -rf` orphans it. Use `./group.sh rm <group>` (removes directory + volume together), `./group.sh list`, and `./group.sh gc` (collects volumes orphaned by a manual `rm -rf`). `group.sh` refuses while a running container mounts the volume, refuses the `host` group, and never touches repo volumes (those are global — `repo.sh` owns them).

`sandbox.sh` always creates the group directory and its `.ssh/` + `.agents/` scaffold on first run. Per-component dirs (`.claude/`, `.copilot/`, etc.) are created only when the corresponding component is enabled in `sandbox.conf`.

When `qmd` is enabled, its search index cache (`~/.cache/qmd`, containing `index.sqlite`) is also group-scoped and mounted at `$dev_home/.cache/qmd`, so the index built from `/workspace/vault`, `/workspace/specs`, and `/workspace/docs` persists across container restarts instead of rebuilding from scratch each run. Because the group is reused across projects while `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH` can point at different host content on each run, the cached index can hold stale or mixed entries for a reused in-container path (e.g. `/workspace/docs` pointed at a different repo than last time) until qmd reindexes it — mounting `DOCS_PATH`/`SPECS_PATH` via `@name` gives each source its own path (e.g. `/workspace/docs2`) and avoids the collision. This is an accepted tradeoff: the extra index size/reindex churn is cheap next to rebuilding the whole corpus every run.

When `ruby` has at least one version configured, rvm and every installed Ruby version's gems live in `~/.rvm`, group-scoped like the dirs above but backed by a **Docker named volume** (`ai-containers-rvm-<group>`, `rvm_volume_name` in `sandbox-common.sh`) rather than a host bind mount, on **every** platform. This is not a preference: rvm bootstraps by extracting its release tarball, and GNU tar defers symlinks whose target contains `..` by first writing a mode-000 placeholder file — an operation macOS virtiofs cannot service, so tar fails on exactly the four such members in the rvm tarball and the installer aborts with `Could not extract RVM sources`. A bind-mounted `~/.rvm` therefore can never hold a working rvm on macOS. Plain symlink creation *does* work there (verified), which is why `~/.ai-tools` (npm/uv, direct `symlink()`) is unaffected and stays a bind mount. Linux uses the volume too — one code path beats a macOS-only branch, which is the divergence that hid this bug. `rvm_volume_ensure` creates the volume on first use and migrates a pre-existing *healthy* bind-mounted `~/.rvm` into it once (predicate: a non-empty `scripts/rvm`, the same check `rvm-reconcile.sh` uses), leaving the old directory in place; the debris of a failed bootstrap is deliberately not migrated. `entrypoint.sh`'s `chown_rvm_root` chowns the mount root before the reconcile, because a fresh named volume mounts root-owned and `setup_sandbox_user`'s recursive `chown` uses `-xdev`, which by design does not cross into mounts. `AI_CONTAINER_GROUP=host` keeps the plain bind mount (that group's contract is "mount my real `$HOME`"), so rvm cannot bootstrap in the `host` group on macOS — use a named group. The `-rvm-` infix is load-bearing: it is what keeps `repo.sh`'s discovery (`name=<prefix>-repo-`) and its registry-driven `--all` from ever reaching a group's rubies; `tests/test-repo-registry.sh` and `tests/test-rvm-volume.sh` both assert that isolation. See the README "Ruby (via rvm)" section for the runtime bootstrap/reconcile detail. The baked `/etc/profile.d/rvm.sh` also sets `rvm_stored_umask` before sourcing rvm: rvm decides a loader is "deprecated" by grepping for that variable, and without it every bootstrap prints *"…is deprecated and causes you to have `umask g+w` set in your shell"*. That warning is a **false positive** here — the check never measures a umask, and the `g+w` loader it describes was the old SYSTEM-WIDE multi-user one; this is a per-user install whose loader sets no umask (verify-on-host.sh Phase 3 prints the measured umask, expected `0022`).

Host-shared paths that are **not** group-scoped: `.aws`, `.azure`, `.kube`, `.yarn`.

Tool config dirs declared via `tools.d/` (`config_dir=`) are group-scoped and seeded once from the host. `dtctl`, `dtmgd` and `acli` are the current examples: on first use in a group, `sandbox.sh` copies the tool's `config_dir` (e.g. `.config/dtctl`) from `$HOME` into the group if it exists there and the group doesn't have it yet, or creates it empty otherwise; every later run mounts the group's copy. This mirrors the agent-credential pattern above, so a sandboxed agent never writes to the developer's real host config. `config_dir=` may list **several space-separated paths**, so a tool that keeps its profile in one directory and its credentials in another gets both group-scoped and mounted. `acli` needs only one (`.config/acli`) because its profiles *and* credentials both live there — the binary is static and uses no OS keyring, so a headless `echo "$TOKEN" | acli jira auth login --email … --site … --token` inside the container persists in the group and every later container in that group is already authenticated.

`.gitconfig` and `.gitignore_global` are **group-scoped** (non-`host` groups): `sandbox.sh` copies them from `$HOME` into `~/.ai-containers/<group>/` on every container start, then mounts from the group copy. This prevents a macOS VirtioFS stale-inode issue where atomically replacing a file on the host (as git, editors, and other tools do) causes the bind-mounted view inside the container to show link count 0 and fail all reads. With the `host` group both files are still mounted directly from `$HOME`. If you edit either file while a container is running, restart the container to pick up the changes.

### macOS host notes

The previous platform-specific redirect (macOS mounted four tools from `~/.ai-containers/` while Linux mounted them from `$HOME`) has been replaced by the unified group system. Both platforms now resolve agent dotfile mounts through the same group root (`~/.ai-containers/<group>/` by default, or `$HOME` when `AI_CONTAINER_GROUP=host`).

The macOS Keychain context remains relevant for the `host` group: Claude Code, GitHub Copilot CLI, Kiro CLI, and GitHub CLI store OAuth tokens in the macOS Keychain rather than in their dotfile dirs. When `AI_CONTAINER_GROUP=host` is set on macOS, a Linux container cannot read those tokens. This is why `sandbox.sh` prints a warning and requires explicit acknowledgement (`yes` at the prompt, or `AI_CONTAINER_HOST_ACK=1`) before proceeding. The default `default` group avoids this issue entirely — it stores all credentials in `~/.ai-containers/default/` using file-based auth that works on Linux and macOS alike.

## Corporate customization

- Edit `sandbox.conf` to enable only the components your team uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints) to `allowlist-domains.d/custom.txt`.
- If agent traffic routes through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and proxy IPs/CIDRs to `allowlist-cidrs.d/custom.txt`.
- Review the `IMAGE_NAME` default in `sandbox.sh` before publishing.
