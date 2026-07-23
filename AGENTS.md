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

Optional components: `copilot`, `kiro`, `claude-code`, `codex`, `gemini`, `graphify`, `openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`, `kubectl`, `aws-cli`, `azure-cli`, `github-cli`, `angular-cli`, `yarn`, `pnpm`, `bun`, `goreleaser`, `vale`, `qmd`, `dtctl`, `dtmgd`.

Version-list components (`node`, `python`, `ruby`, `rails`, `rust`, `go`) accept comma-separated version values instead of `ON`/`OFF` (e.g., `node=22,20`). Constraints:
- `ruby`, `rails`, and `angular-cli` accept only a **single version** (not a comma-separated list).
- SDKMAN-managed components (`openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`) require **full patch versions** (e.g., `openjdk=21.0.11`, not `21`).
- `dtctl` and `dtmgd` accept `ON` (auto-detect latest from GitHub), `x.y.z` (pinned), or `OFF`.
- `node` always installs the latest LTS (required by the AI agents); `node=20,22` adds those versions alongside it. `nvm-version` pins the nvm release used to install Node (e.g., `nvm-version=v0.40.5`); leave empty for the Dockerfile default.

## Commands

**Build the image:**
```bash
./build.sh [image-name]
```
`build.sh` reads `sandbox.conf`, assembles `allowlist-domains.txt`, `allowlist-proxy-domains.txt`, and `allowlist-cidrs.txt` from the `*.d/` fragment directories, then calls `docker build` with one `--build-arg` per component. The generated `allowlist-*.txt` files are gitignored; always use `./build.sh`, not `docker build` directly. (`runme.sh build` was removed — it now errors and points here.)

The AI agents (Copilot/Claude/Codex/Gemini/Kiro) are installed **unpinned** and their layers are cached by Docker, so a normal `./build.sh` will not pick up newer agent versions. To force a fast, **targeted** agent refresh without rebuilding the heavy toolchain layers, set the `AGENTS_CACHE_BUST` build-arg (any changing token busts the agent-tier layers and everything after them, reusing Node/JVM/Python/Ruby/Rust/Go above):
```bash
AGENTS_CACHE_BUST=$(date +%s) ./build.sh
```
`runme.sh` does this automatically when it detects the image is older than `AGENT_REBUILD_MAX_AGE_HOURS` (see below). A full `--no-cache` rebuild is still available but rebuilds everything.

Set `GITHUB_TOKEN` in the environment before building to avoid GitHub API rate limits (60 req/h unauthenticated). This is required when `dtctl` or `dtmgd` is set to `ON` (auto-detect latest). `build.sh` passes it automatically as a BuildKit secret if the env var is set (falling back to `GITHUB_PERSONAL_ACCESS_TOKEN`). If rate-limited, `dtctl`/`dtmgd` are silently skipped — the build still succeeds.

**Run the container:**
```bash
./runme.sh restricted [primary]   # firewall on, NET_ADMIN+NET_RAW dropped from agent shell
./runme.sh discovery  [primary]   # unrestricted egress + background pcap
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
Attach them at run time with `REPOS="cluster:ro lib:ro app:rw" ./runme.sh restricted @app`.

**Initialise a new project** (copies shared files, writes `sandbox.env`, generates launch script, registers in `projects.conf`, and adds `/.ai-containers/` to the project's root `.gitignore`):
```bash
./project-init.sh /path/to/myproject [optional-name]
```
The per-project `.ai-containers/` is a synced working copy (its launcher embeds machine-specific `EXTRA_MOUNTS` paths), so it is git-ignored in the project by default — idempotent, git repos only, and `sync-to-projects.sh` backfills it for existing projects. Remove the line to version it instead, or set `AI_CONTAINERS_NO_GITIGNORE=1` to skip.

**Sync shared files to all registered projects** (after pulling updates to this repo):
```bash
./sync-to-projects.sh              # all projects in projects.conf
./sync-to-projects.sh /path/to/p   # single project
```

**Extract discovery results** (after exiting a discovery-mode container — the pcap is in `.agent-discovery/` of the launch directory):
```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/launch-dir:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

**Key env vars for `runme.sh`:** set inline for one run (`VAULT_PATH=/path ./runme.sh restricted`)
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
| `AGENT_REBUILD_MAX_AGE_HOURS` | Offer to refresh the bundled agents (targeted `AGENTS_CACHE_BUST` rebuild) when the image is at least this many hours old. `0`/`off`/`never` disables. | `72` | — |
| `AGENT_REBUILD_ACK` | On a non-TTY run, set `1` to rebuild a stale image without prompting. | `0` | — |
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

## Architecture

### Container startup flow

`entrypoint.sh` runs as root and drives both modes:

1. **`setup_sandbox_user`** — creates/renames a user whose UID/GID match `SANDBOX_UID`/`SANDBOX_GID` (passed by `runme.sh` from `id -u`/`id -g`). Files in bind-mounted volumes are then accessible without chown. **`chown_workspace_root`** then chowns the in-image `/workspace` umbrella root to the sandbox user (non-recursive; sub-mounts keep their own ownership) so the agent can use it.

2. **restricted mode**: calls `apply_restricted_firewall` → forks the ipset refresh loop and `capture-blocked-traffic.sh` as root background daemons → `exec capsh --drop=cap_net_admin,cap_net_raw --user=<sandbox>` to drop firewall-modification capabilities from the agent shell.

3. **discovery mode**: calls `apply_discovery_firewall` (iptables OUTPUT ACCEPT) → starts `capture-agent-destinations.sh` for pcap → `exec capsh --drop=cap_net_admin --user=<sandbox>` (NET_RAW kept for tcpdump).

Background daemons are forked **before** `exec capsh` so they retain root capabilities despite the exec.

### Mount layout (`/workspace` umbrella) and repo volumes

`/workspace` is an in-image directory used as a **mount root**, not a host bind mount. Everything attaches as a subdirectory:
- positional `[primary]` → `/workspace/<basename>` (host bind) or `/workspace/<repo>` (volume, via `@repo`); also sets `-w`
- `REPOS` → `/workspace/<name>` (Docker named volumes, or host binds on Linux)
- `EXTRA_MOUNTS` → `/workspace/<basename>` (host binds)
- `VAULT_PATH` → `/workspace/vault`
- `SPECS_PATH` → `/workspace/specs` (or `/workspace/<name>` via `@name`)
- `DOCS_PATH` → `/workspace/docs` (read-only by default; `/workspace/<name>` via `@name`; the working-dir mount when the docs repo is the working dir)
- outputs → `/workspace/.agent-blocked` and `/workspace/.agent-discovery`, bind-mounted from the host **launch directory** (`$PWD` where `runme.sh` ran), so they persist host-visibly and git/docker-ignored.

**Repo volumes** (`repo.sh` + `REPOS`) solve the macOS virtio-fs penalty: a repo is seeded **once** into a Docker named volume inside the VM (`ai-containers-repo-<name>`), read at native speed, and shared across all projects/images and container groups. The volume name is **image-independent** (a fixed `ai-containers` prefix, overridable via `REPO_VOLUME_PREFIX`), so one registered repo maps to one global volume that any number of containers — in any project — can mount, with no `IMAGE_NAME` juggling. The registry is `~/.ai-containers/repos.conf` (machine-local, pipe-delimited: `name|type|source|added|synced|backend`). **Docker volumes are the source of truth, not the registry:** each base volume carries `ai-containers.repo`/`.type`/`.source` labels and each working copy carries `ai-containers.repo`/`.workcopy`/`.launch-dir`, so `repo.sh list`/`list --copies`/`gc` read state directly from Docker. The registry is a cache, authoritative only for Linux `bind`-backend repos (no volume to label) and the mutable last-synced time (labels are immutable after creation); `repo.sh reindex` rebuilds it from volume labels. `:rwcopy` creates a per-launch-dir working copy volume (`<base>--wc-<tag>`), prunable via `repo.sh gc`. On Linux, `auto` backend registers `path` repos as bind-mount aliases (no volume seeded); `runme.sh` bind-mounts the host path directly. Source-of-truth helpers live in `sandbox-common.sh`.

Seeding (`repo.sh add`/`sync`) runs in a small, **shared** helper image — `ai-containers-seed` (Alpine + git/openssh-client/rsync/bash), built on demand from `Dockerfile.seed`. It is deliberately independent of the sandbox image and of `IMAGE_NAME` (one image reused by every project, not one per project), so repos can be seeded before `./build.sh` is ever run. Override with `REPO_SEED_IMAGE`. These seeding containers run as a plain `docker run` (not via `entrypoint.sh`), so the firewall does not apply to them.

**`sandbox.env`** (per project, written by `project-init.sh`) persists `IMAGE_NAME`. `sandbox-common.sh` sources it when `IMAGE_NAME` is not already exported, so `build.sh`/`runme.sh`/`repo.sh` resolve the same image even when run directly instead of through the launcher. An exported `IMAGE_NAME` wins. `sync-to-projects.sh` backfills it for older projects and never overwrites it. (Repo-volume names no longer depend on `IMAGE_NAME` — they use the global `ai-containers-repo-<name>` scheme.)

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

Per-component fragments (`github-copilot.txt`, `kiro.txt`, `claude-code.txt`, `codex.txt`, `kubectl.txt`, `aws-cli.txt`, `azure-cli.txt`, `dynatrace.txt`, `openjdk.txt`) are only concatenated when the matching component is `ON` in `sandbox.conf`. The `dynatrace.txt` fragment is included when either `dtctl` or `dtmgd` is enabled; `openjdk.txt` when any JDK variant is enabled.

To add domains not tied to any component (e.g. `google.com`, internal registries, MCP endpoints), edit the appropriate `custom.txt` file in the relevant `*.d/` directory.

**First-time setup:** each `allowlist-*.d/` directory ships a `custom.txt.example`. Copy it to `custom.txt` before adding entries — the `custom.txt` files are gitignored and won't be assembled into the image otherwise.

### Conditional installs in the Dockerfile

Every optional component has a corresponding `ARG INSTALL_<COMPONENT>=0|1` declared immediately before its `RUN` block. The npm-based tools (Copilot, Angular CLI, Claude Code, Codex, Gemini, Yarn) each have their own `RUN` layer so toggling one doesn't invalidate the others. The dtctl/dtmgd block skips entirely when both are disabled.

`ARG AGENTS_CACHE_BUST=0` is declared immediately before the first agent layer (Copilot) and referenced in it. Because Docker's layer cache is linear, changing its value invalidates every layer from that point down (all agent installs, Kiro, graphify, …) while reusing the heavy toolchain layers above. This is the mechanism behind the fast agent refresh (`AGENTS_CACHE_BUST=$(date +%s) ./build.sh`, used automatically by `runme.sh`'s staleness check).

### Sandbox user identity

No user is baked into the image. `entrypoint.sh` calls `useradd`/`usermod` at runtime using the env vars from `runme.sh`. This means the same image works for any team member without rebuilding.

`runme.sh` passes `SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"` / `SANDBOX_GID="${SANDBOX_GID:-$(id -g)}"`. `repo.sh` resolves the **same** values to `chown` repo-volume contents at seed/sync time (it previously hardcoded `id -u`/`id -g`, which broke the override). Because Linux permissions are by numeric UID/GID, you must use the **same** identity for both: with no override they both use the host user; if you override `SANDBOX_UID`/`SANDBOX_GID`, export the same values for both `repo.sh` and `runme.sh` or mounted repo volumes end up owned by the wrong UID and the agent hits permission errors. (Linux `bind`-backend repos are mounted directly with no `chown`, so they're unaffected.)

### Host directory mounts

Agent dotfile dirs (`.claude`, `.copilot`, `.kiro`, `.codex`, `.gemini`, `.config/gh`, `.agents`, `.ssh`) are mounted from a **container group** — a named directory under `~/.ai-containers/<group>/`. The active group is selected by `AI_CONTAINER_GROUP` (default: `default`). To use a custom group, set the env var before running: `AI_CONTAINER_GROUP=docs ./runme.sh restricted /path/to/workspace`. Each group is a plain directory; use `ls ~/.ai-containers/`, `cp -a`, or `rm -rf` to inspect, duplicate, or delete groups.

`runme.sh` always creates the group directory and its `.ssh/` + `.agents/` scaffold on first run. Per-component dirs (`.claude/`, `.copilot/`, etc.) are created only when the corresponding component is enabled in `sandbox.conf`.

When `qmd` is enabled, its search index cache (`~/.cache/qmd`, containing `index.sqlite`) is also group-scoped and mounted at `$dev_home/.cache/qmd`, so the index built from `/workspace/vault`, `/workspace/specs`, and `/workspace/docs` persists across container restarts instead of rebuilding from scratch each run. Because the group is reused across projects while `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH` can point at different host content on each run, the cached index can hold stale or mixed entries for a reused in-container path (e.g. `/workspace/docs` pointed at a different repo than last time) until qmd reindexes it — mounting `DOCS_PATH`/`SPECS_PATH` via `@name` gives each source its own path (e.g. `/workspace/docs2`) and avoids the collision. This is an accepted tradeoff: the extra index size/reindex churn is cheap next to rebuilding the whole corpus every run.

Host-shared paths that are **not** group-scoped: `.aws`, `.azure`, `.kube`, `.config/dtctl`, `.config/dtmgd`, `.yarn`.

`.gitconfig` and `.gitignore_global` are **group-scoped** (non-`host` groups): `runme.sh` copies them from `$HOME` into `~/.ai-containers/<group>/` on every container start, then mounts from the group copy. This prevents a macOS VirtioFS stale-inode issue where atomically replacing a file on the host (as git, editors, and other tools do) causes the bind-mounted view inside the container to show link count 0 and fail all reads. With the `host` group both files are still mounted directly from `$HOME`. If you edit either file while a container is running, restart the container to pick up the changes.

### macOS host notes

The previous platform-specific redirect (macOS mounted four tools from `~/.ai-containers/` while Linux mounted them from `$HOME`) has been replaced by the unified group system. Both platforms now resolve agent dotfile mounts through the same group root (`~/.ai-containers/<group>/` by default, or `$HOME` when `AI_CONTAINER_GROUP=host`).

The macOS Keychain context remains relevant for the `host` group: Claude Code, GitHub Copilot CLI, Kiro CLI, and GitHub CLI store OAuth tokens in the macOS Keychain rather than in their dotfile dirs. When `AI_CONTAINER_GROUP=host` is set on macOS, a Linux container cannot read those tokens. This is why `runme.sh` prints a warning and requires explicit acknowledgement (`yes` at the prompt, or `AI_CONTAINER_HOST_ACK=1`) before proceeding. The default `default` group avoids this issue entirely — it stores all credentials in `~/.ai-containers/default/` using file-based auth that works on Linux and macOS alike.

## Corporate customization

- Edit `sandbox.conf` to enable only the components your team uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints) to `allowlist-domains.d/custom.txt`.
- If agent traffic routes through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and proxy IPs/CIDRs to `allowlist-cidrs.d/custom.txt`.
- Review the `IMAGE_NAME` default in `runme.sh` before publishing.
