# AI Sandbox Container Assets (Public Example)

This directory is the repo-ready asset bundle for the Public-flavored AI sandbox container described in [Wiki: Use dev containers for development with AI agents](https://github.com/ihudak/bookstore/wiki/Use-dev-containers-for-development-with-Copilot).

It packages a CLI-only Docker-based workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, and others) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell.

## Requirements

- **Docker ≥ 23** (BuildKit is required and is the default since Docker 23). Verify with `docker --version`.
- **Bash ≥ 4.4** on the host (for `runme.sh`). Linux distributions ship this by default. macOS ships bash 3.2 — install a newer version via `brew install bash` if needed.

## What is included

- `Dockerfile` builds the image from a configurable set of optional components: AI agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI), JVM toolchains (via SDKMAN: OpenJDK, GraalVM CE, Kotlin, Scala, Maven, Gradle), Node.js versions (via nvm), Python versions (via pyenv), Ruby + Rails (via rvm), Rust (via rustup), Go, cloud CLIs (AWS, Azure, kubectl, GitHub CLI), dev tools (Angular CLI, qmd, graphify, GoReleaser), and Dynatrace CLIs (dtctl, dtmgd). Node.js (latest LTS), Python (latest stable), git, jq, packet-capture tools, and the non-root sandbox user are always included.
- `sandbox.conf` controls which optional components are built into the image and which credential directories are mounted at runtime.
- `install-dt-tools.sh` is a build-time helper script that installs dtctl and dtmgd from GitHub releases, with optional authentication via `GITHUB_TOKEN`.
- `entrypoint.sh` applies either a restricted firewall or a discovery mode at container startup. In both modes it creates the sandbox user and drops to it via `capsh`. Restricted mode drops `NET_ADMIN` and `NET_RAW`; discovery mode drops only `NET_ADMIN` (keeping `NET_RAW` for tcpdump).
- `refresh-ipset-allowlist.sh` resolves the concrete allowlist domains into IPv4 and IPv6 `ipset` sets.
- `capture-blocked-traffic.sh` runs as a background root daemon in restricted mode, logging every blocked outbound destination to `/workspace/.agent-blocked/`.
- `capture-agent-destinations.sh` helps you discover additional AI-agent-related DNS and TLS destinations in discovery mode.
- `allowlist-domains.d/`, `allowlist-proxy-domains.d/`, `allowlist-cidrs.d/` contain per-component allowlist fragments. `runme.sh build` assembles the active fragments into the three `allowlist-*.txt` files that the Dockerfile copies into the image. Each directory also contains a `custom.txt` file that is always included regardless of which components are enabled.
- `runme.sh` is the entry point for building and running the container.

## Usage

Edit `sandbox.conf` to choose which optional components to include, then build the image:

```bash
./runme.sh build
```

`runme.sh build` reads `sandbox.conf`, assembles the three `allowlist-*.txt` files from the matching fragments in `allowlist-*.d/`, and passes a `--build-arg` flag for each component to `docker build`. The generated `allowlist-*.txt` files are gitignored; the `*.d/` fragment directories are the source of truth.

To force a full rebuild from scratch (bypassing Docker's layer cache), pass `--no-cache` or set `NO_CACHE=1`:

```bash
./runme.sh build --no-cache
NO_CACHE=1 ./runme.sh build
```

This is useful when you want to pick up newer versions of CLI tools installed via `curl`/`wget` inside the Dockerfile, since Docker cannot detect remote content changes automatically.

Run in restricted mode with the firewall enabled:

```bash
./runme.sh restricted /path/to/your/repo
```

Run in discovery mode to capture outbound destinations before tightening the allowlist:

```bash
./runme.sh discovery /path/to/your/repo
```

Inside the container, the repository is mounted at `/workspace`.

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
./runme.sh build
```

`./runme.sh build` also falls back to `GITHUB_PERSONAL_ACCESS_TOKEN` if `GITHUB_TOKEN` is unset, so if you already export the former in your shell profile (recommended — see [GitHub tokens at runtime](#github-tokens-at-runtime) below) the build is authenticated automatically with no extra step.

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

Build-time rate-limit avoidance: `./runme.sh build` automatically uses `GITHUB_PERSONAL_ACCESS_TOKEN` as the GitHub API token when `GITHUB_TOKEN` is unset, so the recommended setup above is already sufficient for authenticated API calls (5000 req/h). No extra export is needed. If you explicitly want to use a *different* token for the build than the one in your shell profile, set `GITHUB_TOKEN` for that one invocation: `GITHUB_TOKEN=ghp_build_specific ./runme.sh build`. Either way, the value is consumed only by BuildKit and never lands in the image or the running container.

## Extracting discovery results

After running in discovery mode, reproduce the AI agent interaction you want to observe, then exit the container (`Ctrl+D`). The pcap capture file persists on the host in the `.agent-discovery` directory inside your workspace.

Extract the DNS and TLS hostname lists:

```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/your/repo:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

The container prints this command with the correct path when discovery mode starts. The output lists:

- DNS queries — hostnames the container attempted to resolve.
- TLS SNI hostnames — HTTPS endpoints presented during TLS handshakes.

Add the discovered hostnames to `allowlist-domains.d/custom.txt`, rebuild the image with `./runme.sh build`, and switch to restricted mode.

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

The values must fit within the resources allocated to your Docker engine. On Colima the VM-level limits are set when starting Colima — for example `colima start --cpu 6 --memory 12 --disk 100`. If `CONTAINER_CPUS` exceeds the VM's CPU count, `docker run` fails with `range of CPUs is from 0.01 to N` and the container does not start. Resize Colima or lower the limit.

**Automatic reconciliation.** Before starting the container, `runme.sh` parses the three memory values and fixes inconsistent combinations so `docker run` does not fail mid-launch:

- If `CONTAINER_MEMORY_RESERVATION` is greater than `CONTAINER_MEMORY`, it is lowered to the hard limit and a warning is printed (a soft limit above the hard limit is meaningless).
- If `CONTAINER_MEMORY_SWAP` is less than `CONTAINER_MEMORY`, it is raised to the hard limit (swap disabled) and a warning is printed, because Docker rejects a swap total below the memory limit. This commonly happens when you raise `CONTAINER_MEMORY` (e.g. to `8g`) but leave `CONTAINER_MEMORY_SWAP` at its `4g` default — the reconciliation prevents the otherwise-confusing `Minimum memoryswap limit should be larger than memory limit` error.

A value of `-1` for `CONTAINER_MEMORY_SWAP` (unlimited swap) is left untouched.

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

Each path is mounted at `/repos/<basename>` inside the container.

## Mounting docs, specs, and an Obsidian vault

Three host env vars give AI agents convenient, well-known paths for reference material:

| Env var | Container path | Notes |
|---------|---------------|-------|
| `DOCS_PATH`  | `/docs`     | Documentation root (read-write) |
| `SPECS_PATH` | `/specs`    | Specifications root (read-write) |
| `VAULT_PATH` | `/obsidian` | Obsidian vault (read-write). Also re-exported as `VAULT_PATH=/obsidian` inside the container so agent skills/workflows that consume the variable resolve to the in-container mount point. |

```bash
DOCS_PATH=/path/to/docs \
SPECS_PATH=/path/to/specs \
VAULT_PATH=/path/to/obsidian-vault \
./runme.sh restricted /path/to/repo
```

When `VAULT_PATH` is set, set `qmd=ON` in `sandbox.conf` and rebuild — `runme.sh` warns at startup if the vault is mounted but qmd was not baked into the image. `qmd` is the on-device markdown search engine [@tobilu/qmd](https://github.com/tobi/qmd), installed globally via npm.

## Host configuration mounts

The container automatically mounts the following directories from the host (if they exist) into the sandbox user's home:

Each directory is only mounted when its corresponding component is enabled in `sandbox.conf`. Missing directories are silently skipped.

Agent dotfile directories are sourced from the active container group (`~/.ai-containers/<group>/` by default). The group is selected by `AI_CONTAINER_GROUP` — see [Container groups](#container-groups) for details.

| Host source (within group root) | Container path | Mode | Component |
|---|---|---|---|
| `<group>/.ssh/` | `~/.ssh` | read-write | always |
| `<group>/.agents/` | `~/.agents` | read-write | always |
| `~/.gitconfig` | `~/.gitconfig` | read-only | always (if file exists) |
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

When `AI_CONTAINER_GROUP=host`, all group-scoped paths above are sourced directly from `$HOME` instead.

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

When running in restricted mode, blocked outbound destinations are logged automatically to `/workspace/.agent-blocked/`. These files persist on the host via the workspace mount.

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

Then rebuild the image with `./runme.sh build` and restart the container.

## Security model (restricted mode)

1. **iptables** sets a deny-by-default OUTPUT policy and allows only the allowlisted destinations.
2. **Capability drop**: after iptables is configured, the agent shell is started via `capsh --drop=cap_net_admin,cap_net_raw`, so it cannot modify firewall rules or create raw sockets regardless of file permissions.
3. **Non-root user**: the agent runs as a sandbox user whose username, UID, and GID match the host user that started the container (detected automatically by `runme.sh` via `id -u`, `id -g`, `id -un`, `id -gn`). Override by setting `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP` before running.
4. **Background daemons**: the ipset refresh loop and the blocked-traffic capture daemon are forked before the capability drop and retain their root capabilities to do their jobs.
5. **Self-healing allowlist**: when a blocked IP maps to a domain that is already in `allowlist-domains.txt` or matches a wildcard pattern from `allowlist-proxy-domains.txt`, the daemon adds the IP to the active ipset on the fly. This cannot be exploited by the sandbox user: the internal lookup tables (DNS map, domain caches) are stored in a root-only directory (`/run/agent-blocked-internal`, mode 700) inaccessible to the sandbox shell, and `CAP_NET_RAW` is dropped so DNS responses cannot be spoofed. Set `SELF_HEALING_ENABLED=0` to disable self-healing entirely and use logging-only mode.

Discovery mode runs as the sandbox user with unrestricted egress and `NET_RAW` retained (for tcpdump). It is intended for supervised traffic observation only.

## Allowlist structure

Three `*.d/` directories hold the source-of-truth fragment files. `runme.sh build` assembles them into the `allowlist-*.txt` files that get baked into the image.

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

After editing any fragment file, run `./runme.sh build` to regenerate the image.

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
- Generates `<project>/.ai-containers/<project-name>-container.sh` with `IMAGE_NAME` and commented hints for `AI_CONTAINER_GROUP`, `EXTRA_MOUNTS`, and `PREVIEW_PORTS`.
- Registers the project path in `projects.conf` (created from `projects.conf.example` on first run).

After init, edit `sandbox.conf` to choose components, review the launch script, then build:

```bash
cd <project>/.ai-containers
./runme.sh build
./<project-name>-container.sh
```

### sync-to-projects.sh — propagate updates

After pulling changes to this repo, run this to push the updated shared files to all registered projects:

```bash
./sync-to-projects.sh              # sync all projects in projects.conf
./sync-to-projects.sh /path/to/p   # sync a single project
```

**What is synced:** Dockerfile, all `*.sh` scripts, `.dockerignore`, and the per-component allowlist fragments in `allowlist-*.d/` (excluding `custom.txt`).

**What is never touched:** `sandbox.conf`, `allowlist-*.d/custom.txt`, and the project's launch script.

**sandbox.conf drift warning:** If a project's `sandbox.conf` differs from the one in this repo (e.g. a new component was added), the script prints a warning and the `diff` command to review the changes. You decide whether to adopt them.

### projects.conf

`projects.conf` is the registry of project paths. It is gitignored (to avoid committing personal paths). `projects.conf.example` is the committed template — `project-init.sh` copies it automatically on first use.

You can also edit `projects.conf` manually: one absolute project path per line, blank lines and `#` comments are ignored.

## Corporate customization points

- Edit `sandbox.conf` to enable only the components your team actually uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints, search engines) to `allowlist-domains.d/custom.txt`.
- If agent traffic must go through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and allow only the proxy IPs in `allowlist-cidrs.d/custom.txt`.
- The `custom.txt` files in each `*.d/` directory are **gitignored** to prevent internal hostnames and IPs from being committed. Each directory ships a `custom.txt.example` template; `./runme.sh build` auto-copies it to `custom.txt` on first run.
- The sandbox user identity (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP`) is detected automatically from the host user at runtime. No build-time args needed.
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
