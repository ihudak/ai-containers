# AI Sandbox Container Assets (Public Example)

This directory is the repo-ready asset bundle for the Public-flavored AI sandbox container described in [Wiki: Use dev containers for development with AI agents](https://github.com/ihudak/bookstore/wiki/Use-dev-containers-for-development-with-Copilot).

It packages a CLI-only Docker-based workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, and others) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell.

## Requirements

- **Docker ≥ 23** with BuildKit (default since Docker 23) and `docker buildx`. Verify with `docker --version` and `docker buildx version`.

  | Platform | Recommended runtime | Notes |
  |----------|---------------------|-------|
  | **Linux** | [Docker Engine](https://docs.docker.com/engine/install/) | Socket at `/var/run/docker.sock` by default. |
  | **macOS** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) or [Colima](https://github.com/abiosoft/colima) | See macOS note below. |
  | **Windows** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) + WSL2 backend | Run the scripts from inside a WSL2 shell. |

  **macOS with Colima:** Colima is a lightweight, open-source alternative to Docker Desktop. Install it with Homebrew, then follow these one-time setup steps:

  ```bash
  brew install colima docker docker-buildx
  ```

  1. **Start Colima before building or running containers.** Size the VM to fit the image you intend to build and the container resources you plan to use (see [Resource limits](#resource-limits)):
     ```bash
     colima start --cpu 4 --memory 8 --disk 100
     ```
     Check status at any time with `colima status`.

  2. **Set `DOCKER_HOST` to point to Colima's socket.** Colima places its socket at `~/.colima/default/docker.sock`, not `/var/run/docker.sock`. Without this, every `docker` command fails with `dial unix /var/run/docker.sock: connect: no such file or directory`. Add to your shell profile (`~/.zshrc` or `~/.bashrc`) and reload:
     ```bash
     export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
     ```

  3. **Register buildx as the default builder** (suppresses the legacy-builder deprecation warning and is required for BuildKit secrets used by `./build.sh`):
     ```bash
     docker buildx install
     ```
- **Bash ≥ 4.4** on the host (for `runme.sh`). Linux distributions ship this by default. macOS ships bash 3.2 — install a newer version via `brew install bash` if needed.

## What is included

- `Dockerfile` builds the image from a configurable set of optional components: AI agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI), JVM toolchains (via SDKMAN: OpenJDK, GraalVM CE, Kotlin, Scala, Maven, Gradle), Node.js versions (via nvm), Python versions (via pyenv), Ruby + Rails (via rvm), Rust (via rustup), Go, cloud CLIs (AWS, Azure, kubectl, GitHub CLI), dev tools (Angular CLI, qmd, graphify, GoReleaser, Vale), and Dynatrace CLIs (dtctl, dtmgd). Node.js (latest LTS), Python (latest stable), git, jq, packet-capture tools, and the non-root sandbox user are always included.
- `sandbox.conf` controls which optional components are built into the image and which credential directories are mounted at runtime.
- `install-dt-tools.sh` is a build-time helper script that installs dtctl and dtmgd from GitHub releases, with optional authentication via `GITHUB_TOKEN`.
- `entrypoint.sh` applies either a restricted firewall or a discovery mode at container startup. In both modes it creates the sandbox user and drops to it via `capsh`. Restricted mode drops `NET_ADMIN` and `NET_RAW`; discovery mode drops only `NET_ADMIN` (keeping `NET_RAW` for tcpdump).
- `refresh-ipset-allowlist.sh` resolves the concrete allowlist domains into IPv4 and IPv6 `ipset` sets.
- `capture-blocked-traffic.sh` runs as a background root daemon in restricted mode, logging every blocked outbound destination to `/workspace/.agent-blocked/`.
- `capture-agent-destinations.sh` helps you discover additional AI-agent-related DNS and TLS destinations in discovery mode.
- `allowlist-domains.d/`, `allowlist-proxy-domains.d/`, `allowlist-cidrs.d/` contain per-component allowlist fragments. `build.sh` assembles the active fragments into the three `allowlist-*.txt` files that the Dockerfile copies into the image. Each directory also contains a `custom.txt` file that is always included regardless of which components are enabled.
- `sandbox-common.sh` is a shared library (config parsing, container-group helpers, path/volume helpers, the repo registry) sourced by the three entry-point scripts below.
- `build.sh` builds the image (reads `sandbox.conf`, regenerates the allowlists).
- `runme.sh` runs the container (`restricted` / `discovery`).
- `repo.sh` manages shared, native-speed repo volumes (`add` / `sync` / `reset` / `list` / `rm`).
- `Dockerfile.seed` builds the small, shared helper image (`ai-containers-seed`: Alpine + `git`, `openssh-client`, `rsync`, `bash`) that `repo.sh` uses to seed and sync repo volumes. It is independent of the main sandbox image (and of `IMAGE_NAME`), so it is built once and reused by every project, and repo volumes can be seeded before `./build.sh` is ever run.

## Usage

Edit `sandbox.conf` to choose which optional components to include, then build the image:

```bash
./build.sh
```

`build.sh` reads `sandbox.conf`, assembles the three `allowlist-*.txt` files from the matching fragments in `allowlist-*.d/`, and passes a `--build-arg` flag for each component to `docker build`. The generated `allowlist-*.txt` files are gitignored; the `*.d/` fragment directories are the source of truth.

To force a full rebuild from scratch (bypassing Docker's layer cache), pass `--no-cache` or set `NO_CACHE=1`:

```bash
./build.sh --no-cache
NO_CACHE=1 ./build.sh
```

This is useful when you want to pick up newer versions of CLI tools installed via `curl`/`wget` inside the Dockerfile, since Docker cannot detect remote content changes automatically.

### Keeping the AI agents up to date

The AI agents (Copilot CLI, Claude Code, Codex CLI, Gemini CLI, Kiro CLI) are installed **unpinned** at build time, and Docker caches those layers. So once an image is built, a plain `./build.sh` will *not* pull newer agent versions — and a long-lived image gradually falls behind, eventually too old to run the latest models.

Two mechanisms keep them fresh:

**1. Targeted agent refresh (fast).** Set the `AGENTS_CACHE_BUST` build-arg to any changing value. It busts only the agent-tier layers (and everything after them) while reusing the heavy toolchain layers above (Node, JVM, Python, Ruby, Rust, Go), so the rebuild takes ~1–2 min instead of a full `--no-cache` rebuild:

```bash
AGENTS_CACHE_BUST=$(date +%s) ./build.sh
```

**2. Age-based auto-rebuild (automatic).** When you launch a container, `runme.sh` checks how old the image is. If it is at least `AGENT_REBUILD_MAX_AGE_HOURS` old (**default 72 = 3 days**), it offers to refresh the agents using the targeted rebuild above before starting:

```bash
# Rebuild agents if the image is 24+ hours old instead of the default 72
AGENT_REBUILD_MAX_AGE_HOURS=24 ./runme.sh restricted /path/to/repo

# Disable the check entirely for this run
AGENT_REBUILD_MAX_AGE_HOURS=0 ./runme.sh restricted /path/to/repo
```

| Env var | Default | Meaning |
|---------|---------|---------|
| `AGENT_REBUILD_MAX_AGE_HOURS` | `72` | Rebuild (refresh agents) if the image is at least this many hours old. `0`, `off`, or `never` disables the check. |
| `AGENT_REBUILD_ACK` | unset | On a **non-TTY** run (CI/scripts), set to `1` to perform the rebuild without prompting. Without it, a non-TTY run with a stale image just warns and continues with the existing image. |

On an interactive terminal, the launcher prompts (`[Y/n]`, default yes) before rebuilding so a slow rebuild never ambushes you. The rebuild reuses the heavy toolchain layers, so in practice it only re-fetches the agent CLIs.

Run in restricted mode with the firewall enabled:

```bash
./runme.sh restricted /path/to/your/repo
```

Run in discovery mode to capture outbound destinations before tightening the allowlist:

```bash
./runme.sh discovery /path/to/your/repo
```

Everything is mounted under a single `/workspace` umbrella: the positional argument
(a host path here) is bind-mounted at `/workspace/<basename>` and becomes the working
directory; `REPOS` entries appear at `/workspace/<name>`, `EXTRA_MOUNTS` at
`/workspace/<basename>`, and the Obsidian vault at `/workspace/obsidian`. The positional
argument may also be `@<repo>` to use a registered repo volume as the working directory
(fast on macOS) — see [Shared repo volumes](#shared-repo-volumes-native-speed--reposh-and-repos).
Agent outputs (`.agent-blocked/`, `.agent-discovery/`) are written to the host directory
where you launched `runme.sh` (and are git- and docker-ignored).

## sandbox.conf — component configuration

### Boolean components (ON / OFF)

AI agents, cloud CLIs, and dev tools use simple `ON`/`OFF` flags:

```bash
copilot=ON
kubectl=ON
azure-cli=OFF
```

### Version-list components

Language runtimes accept a comma-separated list of versions to install. The always-on baseline (latest LTS for Node, latest stable for Python) is installed regardless.

```bash
# Install OpenJDK 21 and 25 via SDKMAN (SDKMAN auto-installed when any JVM version is set)
# IMPORTANT: SDKMAN requires full patch versions (e.g. 21.0.5, not 21).
# Run `sdk list java` inside a container to see available identifiers.
openjdk=21.0.11,25.0.2
graalvm-ce=          # empty = skip
kotlin=
maven=3.9.9

# Extra Node versions alongside the always-on latest LTS
node=20,22

# Pin the nvm release (leave empty to use the Dockerfile default)
nvm-version=v0.40.4

# Extra Python versions alongside the always-on latest stable
python=3.12,3.11

# Ruby + Rails (rvm auto-installed when ruby is set; rails requires ruby)
# SINGLE VERSION ONLY — unlike openjdk/node/python, ruby and rails do not
# accept comma-separated lists. Specifying multiple versions will fail at build time.
ruby=3.4.3
rails=8.0.2

# Rust toolchain: stable | beta | nightly | specific version
rust=stable

# Go (direct tarball from go.dev/dl)
go=1.24.2
```

### graphify — code-to-knowledge-graph tool

`graphify` transforms code, docs, and other files into interactive knowledge graphs using Claude AI. It is a Claude Code skill — the binary is installed into the image at build time, but the skill must be registered in `~/.claude/` once at runtime.

```bash
graphify=ON    # install the graphify binary (PyPI package graphifyy — double-y)
graphify=OFF   # skip (default)
```

**First-time setup** (inside the container, after the first start):

```bash
graphify install   # registers the Claude Code skill; persists via the ~/.claude bind-mount
```

Because `~/.claude/` is bind-mounted from the host, running `graphify install` once inside any container makes the skill available in every subsequent container start without reinstalling.

> **Note:** Persistence requires `claude-code=ON` in `sandbox.conf`, which is what provides the `~/.claude/` host bind-mount.

> **Note:** Only the Anthropic API (`api.anthropic.com`) is allowlisted by default. graphify also supports Google Gemini, OpenAI, DeepSeek, Moonshot/Kimi, AWS Bedrock, and Ollama — if you configure graphify with a non-Anthropic provider, add its API domain to `allowlist-domains.d/custom.txt` and rebuild.

### goreleaser — release automation

`goreleaser` automates building and publishing release artifacts for Go (and other) projects. The latest GoReleaser OSS is installed from the official apt repository at build time.

```bash
goreleaser=ON    # install the goreleaser binary from repo.goreleaser.com
goreleaser=OFF   # skip (default)
```

> **Note:** GoReleaser is self-contained and does **not** require `go` to be enabled — the apt package's recommended `golang` dependency is skipped (`--no-install-recommends`). Enable `go` alongside it only if you also want the Go toolchain for building. The two are independent.

> **Note:** Publishing a release reaches `github.com` (and `objects.githubusercontent.com`), which are allowlisted by default. If you publish to a different host (GitLab, Gitea, a custom registry), add its domain to `allowlist-domains.d/custom.txt` and rebuild.

### vale — prose / style linter

`vale` is a markup-aware linter for prose ([vale.sh](https://vale.sh)). It is commonly run as a "style check" phase in documentation workflows; without it installed, that phase is skipped with a warning. It is a single self-contained Go binary (no extra dependencies), installed from GitHub releases (`vale-cli/vale`) at build time.

```bash
vale=ON    # install the latest Vale binary from GitHub releases
vale=OFF   # skip (default)
```

> **Note:** Like the AI agents and GoReleaser, Vale is installed **unpinned** (latest at build time). The version is resolved from the `releases/latest` redirect, so no GitHub API token is needed and there is no rate-limit concern. Use `./build.sh --no-cache` (or bump a cache-busting build-arg) to pick up a newer Vale later.

> **Note:** The binary download and `vale sync` (which fetches style packages such as `Google`, `Microsoft`, `write-good`) use GitHub hosts (`github.com`, `*.githubusercontent.com`) that are allowlisted by default; `vale.sh` is added when `vale=ON` for package-index lookups. If your `.vale.ini` pulls packages from another host, add it to `allowlist-domains.d/custom.txt` and rebuild. Repos that vendor their `StylesPath` need no network at all.

### Dynatrace CLIs (dtctl / dtmgd)

These support three modes:

```bash
dtctl=ON        # auto-detect and install the latest release (uses GitHub API)
dtctl=0.25.0    # install exactly v0.25.0 — no GitHub API call, fully reproducible
dtctl=OFF       # skip entirely
```

When set to `ON`, the build calls the GitHub API to find the latest release. The unauthenticated rate limit is 60 requests/hour. If you hit it:

**Option 1 — set a GitHub token** (raises limit to 5000 req/h, token never stored in the image):
```bash
export GITHUB_TOKEN=ghp_yourtoken
./build.sh
```

`./build.sh` also falls back to `GITHUB_PERSONAL_ACCESS_TOKEN` if `GITHUB_TOKEN` is unset, so if you already export the former in your shell profile (recommended — see [GitHub tokens at runtime](#github-tokens-at-runtime) below) the build is authenticated automatically with no extra step.

**Option 2 — pin a specific version** (no API call at all):
```bash
# In sandbox.conf:
dtctl=0.25.0
dtmgd=0.0.23
```

If the API call fails (rate limit, bad token, or network error), the build prints a clear error message, skips the tool, and **continues successfully**. dtctl/dtmgd can be installed manually later. An expired or invalid `GITHUB_TOKEN` is treated the same as a network error — the build does not fail, but the tool is skipped with a warning.

> **Note on token security:** `GITHUB_TOKEN` is passed as a [BuildKit secret](https://docs.docker.com/build/building/secrets/) — it is never written to any image layer or visible in `docker history`. Safe to use even if you plan to publish the image. Requires Docker ≥ 23 (BuildKit default).

## GitHub tokens at runtime

`runme.sh` deliberately does **not** forward `GITHUB_TOKEN` or `GH_TOKEN` into the running container, even if set on the host. Only `GITHUB_PERSONAL_ACCESS_TOKEN` is forwarded.

> Auth files for Copilot CLI and `gh` CLI are sourced from the active container group (`~/.ai-containers/<group>/.copilot/`, `~/.ai-containers/<group>/.config/gh/`, etc. by default). See [Container groups](#container-groups) for details. The container path inside the table is unchanged.

| Tool inside the container | Auth source |
|---|---|
| Copilot CLI | `COPILOT_GITHUB_TOKEN` env var (auto-extracted from group's `gh` hosts.yml; or set explicitly) |
| `gh` CLI | `~/.config/gh/hosts.yml` (mounted from host) |
| Copilot CLI's built-in GitHub MCP server (`api.business.githubcopilot.com/mcp/*`) | Copilot's OAuth token — no PAT needed |
| `github/github-mcp-server` / `@modelcontextprotocol/server-github` (stdio) | `GITHUB_PERSONAL_ACCESS_TOKEN` |
| Claude Code's official `github` plugin (`api.githubcopilot.com/mcp/`) | `GITHUB_PERSONAL_ACCESS_TOKEN` — PAT must include the **Copilot Requests** fine-grained permission |
| `git` over HTTPS, `curl api.github.com`, skills/scripts | `GITHUB_PERSONAL_ACCESS_TOKEN` |

**Copilot CLI authentication:** `runme.sh` automatically extracts the OAuth token from the active group's `~/.config/gh/hosts.yml` and forwards it as `COPILOT_GITHUB_TOKEN`. This means:
- No `/login` is needed inside the container (if `gh auth` is configured in the group)
- Multiple containers can run simultaneously without revoking each other's sessions (device-flow OAuth is single-session per user; env-var token auth is not)
- You can override by setting `COPILOT_GITHUB_TOKEN` explicitly on the host

> **⚠️ The token is extracted once, at container launch — not while the container runs.**
> `runme.sh` reads `hosts.yml` and sets `COPILOT_GITHUB_TOKEN` **before** `docker run` starts the
> container. If the group is **not yet authenticated** when you launch (no `oauth_token` in
> `hosts.yml`), the env var is **empty for the entire life of that container**, and Copilot CLI
> falls back to interactive device-flow `/login` every time it starts. Running `gh auth login`
> **inside** the running container writes the token to `hosts.yml` for *next* time, but it does
> **not** retroactively inject `COPILOT_GITHUB_TOKEN` into the already-running container's
> environment.
>
> **A Copilot `/restart` does NOT fix this.** `/restart` relaunches only the Copilot process; it
> inherits the same (empty) container environment, so Copilot still has no token and prompts for
> `/login` again. Container env vars are fixed at `docker run` time and cannot be changed by an
> in-container `/restart`.
>
> **The fix:** authenticate **first**, then start (or fully restart) the container so `runme.sh`
> can pick up the freshly written token:
> 1. `gh auth login` (on the host, or once inside any container of that group — it persists to
>    `~/.ai-containers/<group>/.config/gh/hosts.yml`).
> 2. **Exit the container completely** (`Ctrl+D`) and relaunch with `./runme.sh …` — *not* a
>    Copilot `/restart`. Only a full container relaunch re-runs `runme.sh` and re-extracts the token.
> 3. Copilot is now authenticated from `COPILOT_GITHUB_TOKEN` with no `/login` prompt.

**Token requirements:** The `gh` token must be compatible with Copilot CLI. Supported types:
- `gho_*` — OAuth token from `gh auth login` (browser flow) — works directly
- `github_pat_*` — fine-grained PAT — must include the **Copilot Requests** permission

**Why `GITHUB_TOKEN` / `GH_TOKEN` are still blocked at runtime:** forwarding these generic env vars would affect all tools inside the container, not just Copilot CLI. `COPILOT_GITHUB_TOKEN` is scoped specifically to Copilot CLI and does not interfere with `gh` CLI or other tools.

Recommended host setup — export only the one name nothing auto-picks-up implicitly:

```bash
# ~/.bashrc
export GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_...
# do NOT export GITHUB_TOKEN or GH_TOKEN globally
```

**Optional — keep `GITHUB_TOKEN`/`GH_TOKEN` exported for third-party tools.** Some tools (e.g. `act`, `pre-commit`, `terraform` module fetches, `brew`) prefer `GITHUB_TOKEN` over `GITHUB_PERSONAL_ACCESS_TOKEN`. If you want the convenience of all three being set globally, add a shell function that shields Copilot CLI from the env-var Copilot-API fallback path:

```bash
# ~/.bashrc
export GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_...
export GITHUB_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"
export GH_TOKEN="$GITHUB_TOKEN"

# Shield host Copilot CLI from env-var PAT auth (see 'GitHub tokens at runtime' above).
# The subshell '( ... )' unsets only for the copilot process; parent shell keeps the vars.
copilot() {
    ( unset GITHUB_TOKEN GH_TOKEN COPILOT_GITHUB_TOKEN
      command copilot "$@"
    )
}
```

This keeps every other CLI tool authenticated automatically while preventing Copilot CLI from treating your PAT as a Copilot-API bearer. The container Copilot CLI is already protected because `runme.sh` does not forward `GITHUB_TOKEN`/`GH_TOKEN`.

Build-time rate-limit avoidance: `./build.sh` automatically uses `GITHUB_PERSONAL_ACCESS_TOKEN` as the GitHub API token when `GITHUB_TOKEN` is unset, so the recommended setup above is already sufficient for authenticated API calls (5000 req/h). No extra export is needed. If you explicitly want to use a *different* token for the build than the one in your shell profile, set `GITHUB_TOKEN` for that one invocation: `GITHUB_TOKEN=ghp_build_specific ./build.sh`. Either way, the value is consumed only by BuildKit and never lands in the image or the running container.

## Extracting discovery results

After running in discovery mode, reproduce the AI agent interaction you want to observe, then exit the container (`Ctrl+D`). The pcap capture file persists on the host in the `.agent-discovery` directory of the **launch directory** (where you ran `runme.sh`).

Extract the DNS and TLS hostname lists:

```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/launch-dir:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

The container prints this command with the correct path when discovery mode starts. The output lists:

- DNS queries — hostnames the container attempted to resolve.
- TLS SNI hostnames — HTTPS endpoints presented during TLS handshakes.

Add the discovered hostnames to `allowlist-domains.d/custom.txt`, rebuild the image with `./build.sh`, and switch to restricted mode.

## Resource limits

By default the container runs with `--cpus=1.0`, `--memory=4g`, `--memory-reservation=2g`, and `--memory-swap=4g`. Override any of them at run time:

```bash
CONTAINER_CPUS=2 CONTAINER_MEMORY=8g ./runme.sh restricted /path/to/repo
```

| Env var | Docker flag | Default | Meaning |
|---------|-------------|---------|---------|
| `CONTAINER_CPUS` | `--cpus` | `1.0` | CPU limit (fractional allowed, e.g. `2.5`). |
| `CONTAINER_MEMORY` | `--memory` | `4g` | **Hard** memory limit. The container is OOM-killed if it tries to exceed this. |
| `CONTAINER_MEMORY_RESERVATION` | `--memory-reservation` | `2g` | **Soft** limit. Under host memory pressure Docker tries to keep usage at or below this, but the container may still climb to `CONTAINER_MEMORY`. Must be `<= CONTAINER_MEMORY`. |
| `CONTAINER_MEMORY_SWAP` | `--memory-swap` | `4g` | **Total** memory + swap. Swap available to the container is `CONTAINER_MEMORY_SWAP - CONTAINER_MEMORY`. Must be `>= CONTAINER_MEMORY`, or `-1` for unlimited swap. |
| `CONTAINER_NOFILE` | `--ulimit nofile` | `1048576:1048576` | Open-file-descriptor limit, in `soft[:hard]` form. Raise/keep high if an agent crashes with `EMFILE: too many open files`. |

The values must fit within the resources allocated to your Docker engine. On Colima the VM-level limits are set when starting Colima — for example `colima start --cpu 6 --memory 12 --disk 100`. If `CONTAINER_CPUS` exceeds the VM's CPU count, `docker run` fails with `range of CPUs is from 0.01 to N` and the container does not start. Resize Colima or lower the limit.

**Automatic reconciliation.** Before starting the container, `runme.sh` parses the three memory values and fixes inconsistent combinations so `docker run` does not fail mid-launch:

- If `CONTAINER_MEMORY_RESERVATION` is greater than `CONTAINER_MEMORY`, it is lowered to the hard limit and a warning is printed (a soft limit above the hard limit is meaningless).
- If `CONTAINER_MEMORY_SWAP` is less than `CONTAINER_MEMORY`, it is raised to the hard limit (swap disabled) and a warning is printed, because Docker rejects a swap total below the memory limit. This commonly happens when you raise `CONTAINER_MEMORY` (e.g. to `8g`) but leave `CONTAINER_MEMORY_SWAP` at its `4g` default — the reconciliation prevents the otherwise-confusing `Minimum memoryswap limit should be larger than memory limit` error.

A value of `-1` for `CONTAINER_MEMORY_SWAP` (unlimited swap) is left untouched.

**File descriptors vs. memory.** `EMFILE: too many open files` is *not* a memory problem — it means the process hit the open-file-descriptor limit (`ulimit -n`). A container starved of RAM is OOM-killed (exit 137); it does not throw `EMFILE`. On macOS this is also **not** the host's low `launchctl limit maxfiles` (often 256): Docker runs the container inside a Linux VM, so the limit comes from the Docker daemon there, not from the macOS host shell. Agents that scan large repos or doc trees (plus file watchers, where each inotify instance is an fd) can exhaust a low default soft limit. `runme.sh` sets `--ulimit nofile` to a high value (`1048576:1048576`) so this does not happen; override with `CONTAINER_NOFILE` if needed. Inside a container, check the active limit with `ulimit -Sn` (soft) and `ulimit -Hn` (hard).

**Does swap make sense here?** For AI coding agents the answer is usually **no**. Agents and the build tools they invoke (compilers, `npm`/`pip` installs, language servers) are latency-sensitive; if they spill into swap the whole session thrashes and feels frozen, which is worse than a clean OOM. The recommended setup is therefore **no swap** — set `CONTAINER_MEMORY_SWAP` equal to `CONTAINER_MEMORY` so the container is hard-capped and fails fast if it runs out of memory:

```bash
CONTAINER_MEMORY=8g CONTAINER_MEMORY_SWAP=8g ./runme.sh restricted /path/to/repo
```

A small amount of swap (e.g. memory `8g`, swap `10g` → 2g of swap) is only worth it if you hit occasional short memory spikes during large builds and would rather absorb a brief slowdown than have the build killed. Unlimited swap (`-1`) is not recommended: it hides genuine memory leaks and can drag the whole host down.

These variables affect `restricted` and `discovery` runs only; the `build` step is unaffected.

> **Note on defaults:** the launcher defaults above (`1.0` CPU / `4g` memory) are the minimum for a single agent doing light work. For comfortable day-to-day use with one of the agents plus a real build toolchain, `CONTAINER_CPUS=4` and `CONTAINER_MEMORY=8g` (with `CONTAINER_MEMORY_SWAP=8g`) is a better starting point. See the per-agent minimums below.

### Minimum CPU and memory per agent

The CLI agents themselves are lightweight Node/Rust processes; the real memory pressure comes from the toolchains and language servers they drive (TypeScript/`tsserver`, JVM builds, bundlers, test runners). The figures below are practical guidance, not vendor-published hard requirements — treat them as floors, not targets.

| Agent | Bare-minimum to launch | Comfortable (agent + typical build) |
|-------|------------------------|-------------------------------------|
| Kiro CLI | 1 CPU / 2g | 2–4 CPU / 6–8g |
| Claude Code | 1 CPU / 2g | 2–4 CPU / 6–8g |
| OpenAI Codex CLI | 1 CPU / 2g | 2–4 CPU / 6–8g |
| GitHub Copilot CLI | 1 CPU / 2g | 2–4 CPU / 6–8g |

Notes:

- **Below ~2g the agent process itself can start, but real work is fragile.** A single agent idling at a prompt fits in ~512m–1g, but as soon as it reads a large repo, runs a build, or starts a language server, 2g is the realistic floor and 4g+ is recommended.
- **Memory, not CPU, is the binding constraint.** All four agents run fine on 1 CPU for the agent loop itself; add CPUs to speed up the compiles/tests they trigger, not the agent.
- **Running multiple agents or heavy toolchains in one container raises the floor.** JVM builds (Maven/Gradle), large Node monorepos, and Rust compiles can each consume several GB on their own — size `CONTAINER_MEMORY` for the heaviest workload you expect, then keep `CONTAINER_MEMORY_SWAP` equal to it.


## Mounting additional repositories

Set `EXTRA_MOUNTS` to a space-separated list of host paths. Append `:ro` or `:rw` to control per-directory access. The default is read-write. **Paths with spaces are not supported** (the variable is split on whitespace).

```bash
# backend is the primary workspace; ui is read-write, reference-docs is read-only
EXTRA_MOUNTS="/path/to/myproject-ui /path/to/reference-docs:ro" \
bash ./runme.sh restricted /path/to/myproject-backend
```

Each path is mounted at `/workspace/<basename>` inside the container.

> **macOS performance note.** `EXTRA_MOUNTS` (and a host-path positional argument) are host **bind mounts**. On macOS, Docker runs inside a Linux VM and host directories are shared over a virtualized filesystem (virtiofs), which adds a large per-syscall penalty — metadata operations can be ~30–50× slower than native in-VM storage. For small or occasionally-read directories this is fine. For **large repositories that agents scan heavily** (reading thousands of files), use **repo volumes** instead — see the next section. On Linux the bind-mount penalty does not apply.

## Shared repo volumes (native speed) — `repo.sh` and `REPOS`

For big repositories that AI agents inspect repeatedly, host bind mounts are slow on macOS (see the note above). A **repo volume** is a Docker named volume living *inside* the Docker/Colima VM, so containers read it at native in-VM speed. You seed it **once** and then attach it to any number of containers — there is no re-clone or re-copy on each start.

Repo volumes are **global**: there is **one volume per repo name**, shared by containers in *any* project/image and *any* container group (they hold code, not credentials), and tracked in a registry at `~/.ai-containers/repos.conf`. The volume name is image-independent (`ai-containers-repo-<name>`), so you register a repo **once** and attach it to as many containers as you like — across different projects too — with no `IMAGE_NAME` juggling. The physical bytes live in the VM at `/var/lib/docker/volumes/ai-containers-repo-<name>/`, not on the host filesystem. (Set `REPO_VOLUME_PREFIX` to restore the legacy per-image scoping if you ever need it.)

### `repo.sh` — manage repo volumes

```bash
# Seed a repo volume ONCE, from an existing local checkout (fast, no network):
./repo.sh add cluster ~/dev/docs/cluster
# …or by cloning from the remote (authenticates with your host ~/.ssh):
./repo.sh add cluster ssh://git@example.org/team/cluster.git

./repo.sh sync cluster        # refresh when you choose (git pull, or re-copy a path source); sync --all does every repo
./repo.sh reset cluster       # discard local changes — clean slate (keeps the repo registered)
./repo.sh list                # show repos (add --sizes for on-disk size; --copies for :rwcopy working copies)
./repo.sh rm cluster          # remove the volume + any working copies + registry entry
./repo.sh gc                  # prune :rwcopy working copies (--repo <name>, --unused, --yes)
./repo.sh reindex             # rebuild the registry from volume labels (recover a lost/stale repos.conf)
```

> **Docker volumes are the source of truth; the registry is a cache.** Each base volume is labeled with its repo name, type, and source, and each `:rwcopy` working copy with its parent repo and originating launch directory. `list`, `list --copies`, and `gc` read those labels directly from Docker, so what you see reflects the volumes that actually exist (a registry entry whose volume is gone shows as `MISSING`). The registry at `~/.ai-containers/repos.conf` remains authoritative only for two things labels can't cover: **Linux `bind`-backend repos** (which have no volume to label) and the **mutable last-synced timestamp** (Docker labels are immutable after creation). If the registry is ever lost or out of sync, `./repo.sh reindex` rebuilds it from the volume labels.

> **Managing `:rwcopy` working copies.** `./repo.sh list --copies` shows every working-copy volume with its parent repo, the launch directory it was seeded for, whether a running container currently has it mounted, and (with `--sizes`) its on-disk size. `./repo.sh gc` removes them: all of them by default, or `--repo <name>` to scope to one repo, `--unused` to keep any currently mounted by a running container, and `--yes` to skip the confirmation. Working copies can hold uncommitted work, so `gc` confirms before deleting.

`reset` is the "start clean" button, distinct from `sync` (which *fetches* the latest): it **discards local state** and removes any `:rwcopy` working copies. For a git source it runs `git reset --hard` to the upstream (dropping uncommitted changes **and** local commits) plus `git clean -ffdx` (removing untracked **and** git-ignored files such as build output / `node_modules`); for a path source it re-mirrors from the host source. It is **destructive and cannot be undone**, so it prompts for confirmation unless you pass `--yes`. Reset every registered repo at once with `./repo.sh reset --all`. (The Linux `bind` backend is left untouched — its "volume" is your live host checkout — and `reset` just prints how to clean it yourself.)

`add` refuses to overwrite an existing repo — use `sync` to refresh or `rm` first. Authentication for `git-url` sources uses your **host `~/.ssh`** (mounted read-only into a short-lived seeding container); local-path sources need no credentials.

> **Seeding does not require the sandbox image.** `repo.sh` does the copy/clone/rsync work in a small dedicated helper image (`ai-containers-seed`, ~40 MB: Alpine + `git`, `openssh-client`, `rsync`, `bash`), built automatically from `Dockerfile.seed` the first time you run `repo.sh add`/`sync`. This means you can seed repo volumes **before** ever running `./build.sh` — you don't need the (large, slow) sandbox image just to populate a volume. The seed image name is **fixed and project-independent**: it is deliberately not derived from `IMAGE_NAME`, so it is built once and reused by every project rather than producing one near-identical copy per project image. Set `REPO_SEED_IMAGE` to reuse a different existing image that already has these tools (for example `REPO_SEED_IMAGE="$IMAGE_NAME"` once the sandbox image is built); if `REPO_SEED_IMAGE` names an image that is not present, `repo.sh` errors instead of building. The seed helper runs as a plain `docker run` (not through `entrypoint.sh`), so the deny-by-default firewall does not apply to it — the `git clone`/`pull` has normal network access.

> **⚠️ Seed and run as the same user identity.** Repo-volume contents are `chown`ed to a numeric **UID/GID** when seeded/synced, and Linux permissions are enforced by those numbers. `repo.sh` and `runme.sh` resolve the identity the **same** way: `SANDBOX_UID`/`SANDBOX_GID` if set, otherwise your host `id -u`/`id -g`. So:
> - Using the **defaults** (no overrides), seeding and running both use your host identity — ownership always matches, nothing to do.
> - If you **override** `SANDBOX_UID`/`SANDBOX_GID`, you must export the **same** values for **both** `repo.sh` (at `add`/`sync` time) and `runme.sh` (at run time). Overriding one but not the other — or seeding as one user and running the container as another — leaves the mounted repo owned by the wrong UID, and the in-container agent gets permission errors.
> - This applies to the **named-volume** backend (notably macOS). The Linux `bind` backend mounts your host path directly with no `chown`, so it is unaffected.

### `REPOS` — attach repo volumes at run time

Set `REPOS` to a space-separated list of **registered** repo names, each mounted at `/workspace/<name>`. Append `:ro` (default), `:rw`, or `:rwcopy`:

```bash
# cluster + two libs read-only (shared), app writable
REPOS="cluster:ro lib-a:ro lib-b:ro app:rw" ./runme.sh restricted /path/to/primary
```

- **`:ro`** — shared, read-only. Many containers can mount the *same* volume simultaneously from a single on-disk copy. `GIT_OPTIONAL_LOCKS=0` is set so read-only git operations (`log`/`blame`/`status`) don't try to write to `.git`. This is the right choice for reference repos you only inspect.
- **`:rw`** — the shared base volume, mounted **writable directly** (no copy, no extra disk). Intended for a **single writer** at a time — the repo you're actively editing in one container. Two containers writing the *same* repo `:rw` concurrently can wedge git state (lock-file contention, lost edits); the underlying volume/filesystem is not damaged and the state is recoverable (`git reset`, or `repo.sh sync`/`rm`+`add`), but for genuine concurrent writers use `:rwcopy`.
- **`:rwcopy`** — an **isolated** per-workspace writable working copy, seeded once by a fast local copy from the shared base (no re-clone), keyed by the launch directory so the same project reuses its copy across runs. Each `:rwcopy` is a full copy (~repo size), so it costs disk; use it only when you need two containers writing the *same* repo at once. Volume backend only.

If a `REPOS` entry is not registered (or its volume is missing), `runme.sh` aborts **before** starting the container with a clear hint. A name appearing in **both** `EXTRA_MOUNTS` and `REPOS` is an error, since both mount under `/workspace/<name>`.

> **Repo volumes shadow the host.** A repo volume is *not* synced with any host directory — its contents live only in the VM volume (and persist across runs until you `repo.sh rm` it). Commit and push from inside the container to get work out. This is the intended trade-off for native speed: you give up live host-side editing for the repos you put in volumes.

> **`sync` and `:rwcopy` working copies.** `repo.sh sync` refreshes the shared base volume but does **not** touch existing `:rwcopy` working copies (they may contain uncommitted work). List them with `./repo.sh list --copies` and remove the ones you no longer need with `./repo.sh gc` (e.g. `./repo.sh gc --repo <name>`) so they re-seed from the refreshed base on the next run. For path-sourced repos, `sync` uses `rsync -a --delete` (exact mirror) when `rsync` is in the image, falling back to `cp -a` (adds/updates only) otherwise; git-sourced repos use `git pull`.

### Cross-platform backend (`REPO_BACKEND`)

The bind-mount penalty only exists on macOS — on Linux, host bind mounts are already native speed. So `REPOS` picks a backend per platform, controlled by `REPO_BACKEND` (default `auto`). **The backend is decided when you run `repo.sh add` and stored in the registry** — changing `REPO_BACKEND` later does not affect already-added repos (remove and re-add to change):

| `REPO_BACKEND` | `path` source | `git` source |
|----------------|---------------|--------------|
| `auto` (default) | **macOS:** named volume. **Linux:** direct host bind mount (no volume, no copy). | named volume (both platforms) |
| `volume` | named volume (both platforms) | named volume |
| `bind` | direct host bind mount | falls back to named volume (no local path to bind) |

This means **one `REPOS="cluster:ro app:rw"` line works on both platforms** — you get native-speed volumes on macOS and zero-copy bind mounts on Linux without maintaining separate launch scripts. On Linux, `repo.sh add <name> <path>` simply records the name→path mapping in the registry (no volume is seeded); `repo.sh sync` is a no-op for those (the bind mount is always live).

> **One behavioural difference with `auto`/`bind`:** `:rw` on a bind-mounted repo writes **live** to the host source (changes are visible on the host immediately), whereas `:rw` on a volume-backed repo writes to the shared base **inside the VM** (not visible on the host). `:ro` behaves identically either way, and `:rwcopy` (volume backend) is always an isolated in-VM copy. Set `REPO_BACKEND=volume` if you want byte-identical behaviour on every platform.

## Mounting an Obsidian vault

Set `VAULT_PATH` to a host Obsidian vault to mount it at `/workspace/obsidian` (read-write). It is also re-exported as `VAULT_PATH=/workspace/obsidian` inside the container so agent skills/workflows that consume the variable resolve to the in-container mount point.

```bash
VAULT_PATH=/path/to/obsidian-vault \
./runme.sh restricted /path/to/repo
```

When `VAULT_PATH` is set, set `qmd=ON` in `sandbox.conf` and rebuild — `runme.sh` warns at startup if the vault is mounted but qmd was not baked into the image. `qmd` is the on-device markdown search engine [@tobilu/qmd](https://github.com/tobi/qmd), installed globally via npm.

> The previous `DOCS_PATH` (`/docs`) and `SPECS_PATH` (`/specs`) mounts have been removed. Keep documentation and specs inside a repo (mounted under `/workspace`) or in the Obsidian vault.

## Host configuration mounts

The container automatically mounts the following directories from the host (if they exist) into the sandbox user's home:

Each directory is only mounted when its corresponding component is enabled in `sandbox.conf`. Missing directories are silently skipped.

Agent dotfile directories are sourced from the active container group (`~/.ai-containers/<group>/` by default). The group is selected by `AI_CONTAINER_GROUP` — see [Container groups](#container-groups) for details.

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
| `~/.aws` | `~/.aws` | read-write | `aws-cli` |
| `~/.azure` | `~/.azure` | read-write | `azure-cli` |
| `~/.kube` | `~/.kube` | read-write | `kubectl` |
| `~/.yarn` | `~/.yarn` | read-write | `yarn` |
| `~/.config/dtctl` | `~/.config/dtctl` | read-write | `dtctl` |
| `~/.config/dtmgd` | `~/.config/dtmgd` | read-write | `dtmgd` |

¹ `runme.sh` copies these files from `$HOME` into the group directory on every container start and mounts from the copy. This avoids a macOS VirtioFS issue where atomically replacing a file on the host (as git and most editors do) causes the bind-mounted view inside the container to become unreadable. If you edit either file while a container is running, restart the container to pick up the changes.

When `AI_CONTAINER_GROUP=host`, all group-scoped paths above are sourced directly from `$HOME` instead (including `.gitconfig` and `.gitignore_global`).

## Container groups

A container group is a named directory under `~/.ai-containers/<name>/` that holds all per-purpose agent dotfile state: auth credentials, skills, MCP config, SSH keys, and per-tool session data. Because each group is self-contained, you can keep completely separate agent profiles for different purposes — for example a `docs` group with Obsidian skills and wiki credentials, a `java-backend` group with infra creds and Dynatrace auth, and a `ui` group with Figma MCP config — and switch between them per invocation.

```bash
AI_CONTAINER_GROUP=docs ./runme.sh restricted /path/to/workspace
```

The default group is named `default`. Its directory is `~/.ai-containers/default/`. If `AI_CONTAINER_GROUP` is not set, `default` is used.

### Group layout

```text
~/.ai-containers/
├── default/
│   ├── .ssh/
│   ├── .agents/
│   ├── .claude/
│   ├── .claude.json
│   ├── .copilot/
│   ├── .config/gh/
│   ├── .kiro/
│   ├── .local/share/kiro-cli/
│   ├── .codex/
│   └── .gemini/
├── docs/               ← custom group, same shape
└── java-backend/       ← another custom group
```

### Group-name rules

- Lowercase letters, digits, and dashes only.
- 1–32 characters; must start with a letter or digit.
- Examples of valid names: `default`, `docs`, `java-backend`, `ui2`.
- Examples of invalid names: `Docs` (uppercase), `_meta` (leading underscore), `my group` (space).

### First-time bootstrap

When you reference a group that does not yet exist, `runme.sh` asks how to initialize it.

**Interactive (TTY):**

```
Group 'docs' not found. Initialize from:
  1) default            (recommended, if it exists)
  2) host
  3) <other custom groups, mtime-sorted>
  N) <empty>
  q) cancel
[1]: _
```

Pick `1)` to copy the group-scoped dotfile slice from `default` (or whichever group is listed first). Pick `host` to copy from `$HOME`. Pick `<empty>` to start with an empty group (only `.ssh/` and `.agents/` are scaffolded). Pick `q` to abort.

**Non-interactive (no TTY or scripted use):**

```bash
# Start with an empty group
AI_CONTAINER_GROUP=docs AI_CONTAINER_GROUP_INIT=clean ./runme.sh restricted /path

# Copy dotfiles from the default group
AI_CONTAINER_GROUP=docs AI_CONTAINER_GROUP_INIT=from:default ./runme.sh restricted /path

# Copy dotfiles from $HOME
AI_CONTAINER_GROUP=docs AI_CONTAINER_GROUP_INIT=from:host ./runme.sh restricted /path
```

Without `AI_CONTAINER_GROUP_INIT`, a non-TTY invocation for a missing group exits with an error and prints the hint.

### The `host` group

`AI_CONTAINER_GROUP=host` is a special sentinel meaning "mount agent dotfiles directly from `$HOME`". No `~/.ai-containers/host/` directory is created.

**On Linux**, this restores the behavior that was the default before container groups were introduced — no warning, no prompt.

**On macOS**, `runme.sh` prints the following warning and prompts for explicit confirmation before starting the container:

```
WARNING: AI_CONTAINER_GROUP=host on macOS

The following tools store OAuth in the macOS Keychain and
will NOT have working credentials in the container:
  - Claude Code        (~/.claude)
  - GitHub Copilot CLI (~/.copilot)
  - Kiro CLI           (~/.kiro)  [also: per-arch bun binary conflict]
  - GitHub CLI         (~/.config/gh)

Codex, Gemini, and other dirs are unaffected.
```

Respond `yes` to continue. For non-interactive use, set `AI_CONTAINER_HOST_ACK=1`.

The warning exists because those tools store OAuth tokens in the macOS Keychain rather than in their dotfile dirs. A Linux container cannot access the Keychain, so the container would start with no credentials for those tools. The default `default` group avoids this entirely by storing all credentials in `~/.ai-containers/default/` using file-based auth that works on both platforms.

### One-time login inside a fresh group

After creating a new group, log in to each tool from inside the container once:

```bash
gh auth login          # Required — Copilot CLI token is auto-derived from this
claude /login
# Kiro: log in on first interactive use
```

Once `gh auth login` completes, Copilot CLI is authenticated automatically (its token is extracted from `hosts.yml` and forwarded as `COPILOT_GITHUB_TOKEN`). No separate `copilot /login` is needed.

> **⚠️ You must fully restart the container after the *first* `gh auth login`.**
> `runme.sh` extracts the token from `hosts.yml` **at launch**, so on the very first run of a fresh
> group — where you authenticate `gh` *inside* the container — `COPILOT_GITHUB_TOKEN` was already
> set empty when the container started. Copilot will keep prompting for `/login` (and a Copilot
> `/restart` will **not** help — it reuses the same empty container environment). **Exit the
> container (`Ctrl+D`) and relaunch with `./runme.sh …`** so `runme.sh` re-reads the now-populated
> `hosts.yml`. From then on Copilot starts authenticated. See
> [GitHub tokens at runtime](#github-tokens-at-runtime) for the full explanation.

> **Note:** If your `gh` token is a fine-grained PAT (`github_pat_*`), it must include the **Copilot Requests** permission. If it's an OAuth token from `gh auth login` browser flow (`gho_*`), it works directly.

The credentials are written into the group directory on the host and persist across all future runs of that group.

### Group maintenance

Groups are plain directories. Use standard shell tools:

```bash
# List groups
ls ~/.ai-containers/

# Back up a group
tar czf docs-group.tgz -C "$HOME/.ai-containers" docs

# Duplicate a group
cp -a ~/.ai-containers/default ~/.ai-containers/new-project

# Remove a group (irreversible — deletes all auth state for that group)
rm -rf ~/.ai-containers/docs
```

### Migration notes for upgrading users

**Linux users** will see the bootstrap prompt on first run after upgrade, because `~/.ai-containers/default/` does not exist yet. Choose `host` or another existing source to initialize from. To restore the previous behavior without any prompt, set `AI_CONTAINER_GROUP=host` permanently in your shell profile.

**`SSH_SCOPE_DIR` has been removed.** If you have it set, `runme.sh` prints a deprecation note to stderr and ignores the variable. To migrate: copy your custom SSH keys into `~/.ai-containers/<group>/.ssh/`, or initialize a group with `AI_CONTAINER_GROUP_INIT=from:host` to copy them automatically. See `CHANGELOG.md` for details.

## macOS host notes

The previous platform-specific behavior — where macOS redirected Claude Code, Copilot CLI, Kiro CLI, and GitHub CLI mounts to `~/.ai-containers/` while Linux kept them under `$HOME` — has been replaced by the unified container-group system described above. Both platforms now use the same group-root logic (`~/.ai-containers/<group>/` by default).

The macOS Keychain context is still relevant if you use `AI_CONTAINER_GROUP=host`. Those four tools store OAuth tokens in the Keychain rather than in their dotfile dirs, which is why the `host` group on macOS prints a warning and requires explicit acknowledgement. With the default `default` group, credentials are stored in `~/.ai-containers/default/` as plain files, and there is no Keychain barrier.

> The `~/.ai-containers/` directory name is unrelated to the per-project `<project>/.ai-containers/` asset dirs created by `project-init.sh`. They never collide on disk because one lives under `$HOME` and the other under repo roots.

## Reviewing blocked traffic

When running in restricted mode, blocked outbound destinations are logged automatically to `/workspace/.agent-blocked/`. These files persist on the host in the `.agent-blocked` directory of the launch directory (where you ran `runme.sh`).

| File | Purpose |
|------|---------|
| `blocked.log` | Timestamped log of every blocked connection attempt |
| `blocked-domains.txt` | Deduplicated domain list — copy-paste into `allowlist-domains.d/custom.txt` |
| `blocked-ips.txt` | Deduplicated IPs with no known domain — copy-paste into `allowlist-cidrs.d/custom.txt` |

To update the allowlist after a session:

```bash
cat /workspace/.agent-blocked/blocked-domains.txt
# copy the domain lines → paste into allowlist-domains.d/custom.txt
#   (or into the relevant component fragment if you know which component needs them)

cat /workspace/.agent-blocked/blocked-ips.txt
# copy the IP lines → paste into allowlist-cidrs.d/custom.txt
```

Then rebuild the image with `./build.sh` and restart the container.

## Security model (restricted mode)

1. **iptables** sets a deny-by-default OUTPUT policy and allows only the allowlisted destinations.
2. **Capability drop**: after iptables is configured, the agent shell is started via `capsh --drop=cap_net_admin,cap_net_raw`, so it cannot modify firewall rules or create raw sockets regardless of file permissions.
3. **Non-root user**: the agent runs as a sandbox user whose username, UID, and GID match the host user that started the container (detected automatically by `runme.sh` via `id -u`, `id -g`, `id -un`, `id -gn`). Override by setting `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP` before running.
4. **Background daemons**: the ipset refresh loop and the blocked-traffic capture daemon are forked before the capability drop and retain their root capabilities to do their jobs.
5. **Self-healing allowlist**: when a blocked IP maps to a domain that is already in `allowlist-domains.txt` or matches a wildcard pattern from `allowlist-proxy-domains.txt`, the daemon adds the IP to the active ipset on the fly. This cannot be exploited by the sandbox user: the internal lookup tables (DNS map, domain caches) are stored in a root-only directory (`/run/agent-blocked-internal`, mode 700) inaccessible to the sandbox shell, and `CAP_NET_RAW` is dropped so DNS responses cannot be spoofed. Set `SELF_HEALING_ENABLED=0` to disable self-healing entirely and use logging-only mode.

Discovery mode runs as the sandbox user with unrestricted egress and `NET_RAW` retained (for tcpdump). It is intended for supervised traffic observation only.

## Allowlist structure

Three `*.d/` directories hold the source-of-truth fragment files. `build.sh` assembles them into the `allowlist-*.txt` files that get baked into the image.

| Directory | Controls | Always included | Per-component |
|-----------|----------|-----------------|---------------|
| `allowlist-domains.d/` | Concrete FQDNs resolved to IPs at startup and every 60 s | `base.txt`, `custom.txt` | one file per component |
| `allowlist-proxy-domains.d/` | Wildcard patterns used by the self-healing daemon (e.g. `*.githubcopilot.com`) | `custom.txt` | `github-copilot.txt`, `kiro.txt`, `claude-code.txt`, `codex.txt`, `gemini.txt`, `dynatrace.txt` |
| `allowlist-cidrs.d/` | Literal IP addresses and CIDR ranges added directly to ipset | `base.txt`, `custom.txt` | `github-copilot.txt` |

**Where to put your additions:**

| What you want to add | File to edit |
|----------------------|-------------|
| A domain needed by an enabled component (e.g. a missing Copilot endpoint) | `allowlist-domains.d/<component>.txt` |
| A domain not tied to any component (search engine, internal registry, MCP server) | `allowlist-domains.d/custom.txt` |
| A wildcard pattern for the self-healing daemon | `allowlist-proxy-domains.d/custom.txt` |
| A corporate proxy IP or narrow CIDR | `allowlist-cidrs.d/custom.txt` |

After editing any fragment file, run `./build.sh` to regenerate the image.

## Managing multiple projects

If you use ai-containers across several projects, two scripts help you keep them in sync without manual copying.

### project-init.sh — initialise a project

Copies the shared infrastructure into `<project>/.ai-containers/`, generates a ready-to-edit launch script, and registers the project in `projects.conf`.

```bash
./project-init.sh /path/to/myproject
# Optional: override the project name (used for the image name and launch script)
./project-init.sh /path/to/myproject my-custom-name
```

What it does:

- Creates `<project>/.ai-containers/` and copies all shared files (Dockerfile, scripts, allowlist fragment files).
- Copies `sandbox.conf` as a starting point (only if one does not already exist).
- Writes `<project>/.ai-containers/sandbox.env` with `IMAGE_NAME=<image>`. This is read by `sandbox-common.sh` so `build.sh`, `runme.sh`, and `repo.sh` all resolve the **same** image name even when you run a script directly instead of through the generated launcher. An exported `IMAGE_NAME` still takes precedence. (Repo-volume names are global — `ai-containers-repo-<name>`, independent of `IMAGE_NAME` — so they are shared across projects regardless of this value.)
- Generates `<project>/.ai-containers/<project-name>-container.sh` with `IMAGE_NAME` and commented hints for `AI_CONTAINER_GROUP`, `EXTRA_MOUNTS`, `REPOS`, and `PREVIEW_PORTS`.
- Registers the project path in `projects.conf` (created from `projects.conf.example` on first run).
- Adds `/.ai-containers/` to the project's **root `.gitignore`** (git repos only, idempotent), so the synced working copy — whose launcher embeds machine-specific paths (`EXTRA_MOUNTS`) and whose `custom.txt` may hold internal hostnames — isn't accidentally committed. To version it instead (e.g. to share sandbox config with a team), remove that line; set `AI_CONTAINERS_NO_GITIGNORE=1` to skip this step entirely. `sync-to-projects.sh` applies the same rule to existing projects (never duplicating an entry already present).

> **Note on resource defaults:** the CPU/memory values `project-init.sh` pre-fills in its prompts (`4.0` CPU, `8g` memory, `4g` reservation, swap = memory) reflect the recommended **comfortable** tier from [Resource limits](#resource-limits), not `runme.sh`'s conservative fallback (`1.0` CPU / `4g` / `2g` / `4g`). This is intentional: the generated launch script bakes the comfortable values in as explicit `CONTAINER_*` exports, while `runme.sh`'s fallbacks remain the bare minimum for a single agent doing light work. Edit the generated launch script to lower them if your Docker/Colima VM is smaller.

After init, edit `sandbox.conf` to choose components, review the launch script, then build:

```bash
cd <project>/.ai-containers
./build.sh
./<project-name>-container.sh
```

### sync-to-projects.sh — propagate updates

After pulling changes to this repo, run this to push the updated shared files to all registered projects:

```bash
./sync-to-projects.sh              # sync all projects in projects.conf
./sync-to-projects.sh /path/to/p   # sync a single project
```

**What is synced:** Dockerfile, `Dockerfile.seed`, all `*.sh` scripts, `.dockerignore`, and the per-component allowlist fragments in `allowlist-*.d/` (excluding `custom.txt`).

**What is never touched:** `sandbox.conf`, `sandbox.env`, `allowlist-*.d/custom.txt`, and the project's launch script. `sandbox.env` is **backfilled** (created from the launcher's `IMAGE_NAME`) if a project predates it, but an existing one is never overwritten.

**sandbox.conf drift warning:** If a project's `sandbox.conf` differs from the one in this repo (e.g. a new component was added), the script prints a warning and the `diff` command to review the changes. You decide whether to adopt them.

### projects.conf

`projects.conf` is the registry of project paths. It is gitignored (to avoid committing personal paths). `projects.conf.example` is the committed template — `project-init.sh` copies it automatically on first use.

You can also edit `projects.conf` manually: one absolute project path per line, blank lines and `#` comments are ignored.

## Corporate customization points

- Edit `sandbox.conf` to enable only the components your team actually uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints, search engines) to `allowlist-domains.d/custom.txt`.
- If agent traffic must go through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and allow only the proxy IPs in `allowlist-cidrs.d/custom.txt`.
- The `custom.txt` files in each `*.d/` directory are **gitignored** to prevent internal hostnames and IPs from being committed. Each directory ships a `custom.txt.example` template; `./build.sh` auto-copies it to `custom.txt` on first run.
- The sandbox user identity (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP`) is detected automatically from the host user at runtime. No build-time args needed. If you override `SANDBOX_UID`/`SANDBOX_GID`, set the **same** values when running `repo.sh` (it chowns repo-volume contents to that identity) as when running `runme.sh` — see the identity warning under [Shared repo volumes](#shared-repo-volumes-native-speed--reposh-and-repos).
- Review the default values in `runme.sh`, especially `IMAGE_NAME`, before publishing this into a separate repository.

## Important notes

- Plain `iptables` cannot pre-resolve wildcard domains such as `*.githubcopilot.com` or `*.kiro.dev` into IP addresses. The self-healing daemon handles this reactively by auto-allowing IPs whose resolved domains match wildcard patterns in `allowlist-proxy-domains.d/`. An upstream proxy provides proactive enforcement if available.
- **DNS is unrestricted.** The firewall allows all outbound DNS (port 53) to any resolver. This is required for domain resolution but means DNS tunneling is theoretically possible. For higher-security deployments, restrict DNS to a specific resolver by adding `--dns 8.8.8.8` to the `docker run` command and tightening the iptables DNS rules in `entrypoint.sh`.
- **IPv6 firewall may be unavailable.** Some environments (notably WSL2 with the nf_tables backend) lack `ip6table_filter`. When this happens, the IPv4 firewall works normally but IPv6 egress is completely unrestricted. The container prints a prominent warning at startup. Set `ALLOW_IPV6_BYPASS=1` to acknowledge the risk and suppress the hint.
- **GraalVM Oracle licensing.** The `graalvm-oracle` key in `sandbox.conf` installs Oracle GraalVM, which is free for production use under the [GraalVM Free Terms and Conditions (GFTC)](https://www.oracle.com/downloads/licenses/graal-free-license.html) since September 2023. If you distribute images built with `graalvm-oracle=<version>`, ensure your use complies with the GFTC. GraalVM Community Edition (`graalvm-ce`) is fully open-source under GPLv2+CE.
- **Ruby gem native extensions.** Build tools (`gcc`, `make`, and `-dev` headers) are removed after the image build to reduce image size. Gems with native C extensions (e.g. `nokogiri`, `pg`, `mysql2`) cannot be compiled inside the container with `gem install`. Pre-install them during the build by adding a `RUN` step after the rvm layer, or add `build-essential` back to the Dockerfile if you need to install such gems at runtime.
- **Go: `go install` tools require `~/go/bin` on PATH.** `go install github.com/some/tool@latest` places the binary in `~/go/bin`. This directory is added to `PATH` via `/etc/bash.bashrc` when Go is enabled, so it is available in interactive shells. Non-interactive scripts that bypass `.bashrc` must set `export PATH="$HOME/go/bin:$PATH"` explicitly.
- The per-component domain fragments are a practical baseline, not a guarantee that every future agent endpoint is covered. Use discovery mode to find gaps.
- The asset set is intentionally CLI-only and does not depend on VS Code dev containers.
- All optional components — including Kiro CLI — are controlled solely by `sandbox.conf`. There is no runtime auto-detection.
- **Angular CLI** (`angular-cli=ON`) is included as a dev tool because AI coding agents frequently scaffold and modify Angular projects. It is not an AI agent itself.
- **Image size** depends heavily on which components are enabled. A minimal image (just Node.js + Python + one AI agent) is ~2–3 GB. With all JVM toolchains, multiple Node/Python versions, Ruby, Rust, Go, and all AI agents enabled, expect 8–12 GB. Disable unused components in `sandbox.conf` to reduce size and build time.
