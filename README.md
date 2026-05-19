# AI Sandbox Container Assets (Public Example)

This directory is the repo-ready asset bundle for the Public-flavored AI sandbox container described in [Wiki: Use dev containers for development with AI agents](https://github.com/ihudak/bookstore/wiki/Use-dev-containers-for-development-with-Copilot).

It packages a CLI-only Docker-based workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, and others) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell.

## Requirements

- **Docker ≥ 23** (BuildKit is required and is the default since Docker 23). Verify with `docker --version`.
- **Bash ≥ 4.4** on the host (for `runme.sh`). Linux distributions ship this by default. macOS ships bash 3.2 — install a newer version via `brew install bash` if needed.

## What is included

- `Dockerfile` builds the image from a configurable set of optional components: AI agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI), JVM toolchains (via SDKMAN: OpenJDK, GraalVM CE, Kotlin, Scala, Maven, Gradle), Node.js versions (via nvm), Python versions (via pyenv), Ruby + Rails (via rvm), Rust (via rustup), Go, cloud CLIs (AWS, Azure, kubectl, GitHub CLI), dev tools (Angular CLI, qmd), and Dynatrace CLIs (dtctl, dtmgd). Node.js (latest LTS), Python (latest stable), git, jq, packet-capture tools, and the non-root sandbox user are always included.
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

> On **macOS hosts**, the host-side files referenced in this table are mounted from `~/.ai-containers/.copilot/`, `~/.ai-containers/.config/gh/`, etc. — see the [macOS host notes](#macos-host-notes) below for why and how. The container path inside the table is unchanged.

| Tool inside the container | Auth source |
|---|---|
| Copilot CLI | `~/.copilot/config.json` OAuth (mounted from host) |
| `gh` CLI | `~/.config/gh/hosts.yml` (mounted from host) |
| Copilot CLI's built-in GitHub MCP server (`api.business.githubcopilot.com/mcp/*`) | Copilot's OAuth token — no PAT needed |
| `github/github-mcp-server` / `@modelcontextprotocol/server-github` (stdio) | `GITHUB_PERSONAL_ACCESS_TOKEN` |
| Claude Code's official `github` plugin (`api.githubcopilot.com/mcp/`) | `GITHUB_PERSONAL_ACCESS_TOKEN` — PAT must include the **Copilot Requests** fine-grained permission |
| `git` over HTTPS, `curl api.github.com`, skills/scripts | `GITHUB_PERSONAL_ACCESS_TOKEN` |

**Why `GITHUB_TOKEN` / `GH_TOKEN` are blocked at runtime:** when those vars are set, Copilot CLI prefers them over its OAuth login and treats them as a direct Copilot-API bearer. If the PAT lacks the `Copilot Requests` fine-grained permission (currently required by GitHub), every Copilot request fails with `401 "Personal Access Token does not have 'Copilot Requests' permission"`, forcing `/login`. When the host and container each hold their own Copilot CLI, the resulting token rotation ping-pongs between them. Forwarding only `GITHUB_PERSONAL_ACCESS_TOKEN` keeps the PAT available for tools that explicitly consume it, while leaving Copilot CLI and `gh` CLI on their own on-disk credentials.

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

By default the container runs with `--cpus=4.0` and `--memory=8g`. Override either at run time:

```bash
CONTAINER_CPUS=2 CONTAINER_MEMORY=4g ./runme.sh restricted /path/to/repo
```

The values must fit within the resources allocated to your Docker engine. On Colima the VM-level limits are set when starting Colima — for example `colima start --cpu 6 --memory 12 --disk 100`. If `CONTAINER_CPUS` exceeds the VM's CPU count, `docker run` fails with `range of CPUs is from 0.01 to N` and the container does not start. Resize Colima or lower the limit.

These variables affect `restricted` and `discovery` runs only; the `build` step is unaffected.

## Mounting additional repositories

Set `EXTRA_MOUNTS` to a space-separated list of host paths. Append `:ro` or `:rw` to control per-directory access. The default is read-write. **Paths with spaces are not supported** (the variable is split on whitespace).

```bash
# backend is the primary workspace; ui is read-write, reference-docs is read-only
SSH_SCOPE_DIR="$HOME/.ssh/myproject" \
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

| Host directory | Container path | Mode | Component |
|---|---|---|---|
| `~/.ssh` (or `SSH_SCOPE_DIR`) | `~/.ssh` | read-only | always |
| `~/.agents` | `~/.agents` | read-write | always |
| `~/.config/gh` | `~/.config/gh` | read-write | `github-cli` or `copilot` |
| `~/.copilot` | `~/.copilot` | read-write | `copilot` |
| `~/.kiro` | `~/.kiro` | read-write | `kiro` |
| `~/.local/share/kiro-cli` | `~/.local/share/kiro-cli` | read-write | `kiro` (on macOS the host source is redirected under `~/.ai-containers/` — see [macOS notes](#macos-host-notes)) |
| `~/.claude` | `~/.claude` | read-write | `claude-code` |
| `~/.claude.json` | `~/.claude.json` | read-write | `claude-code` |
| `~/.codex` | `~/.codex` | read-write | `codex` |
| `~/.gemini` | `~/.gemini` | read-write | `gemini` |
| `~/.aws` | `~/.aws` | read-write | `aws-cli` |
| `~/.azure` | `~/.azure` | read-write | `azure-cli` |
| `~/.kube` | `~/.kube` | read-write | `kubectl` |
| `~/.yarn` | `~/.yarn` | read-write | `yarn` |
| `~/.config/dtctl` | `~/.config/dtctl` | read-write | `dtctl` |
| `~/.config/dtmgd` | `~/.config/dtmgd` | read-write | `dtmgd` |

## macOS host notes

Most CLIs (`aws`, `azure`, `kubectl`, `yarn`, `codex`, `gemini`, `dtctl`, `dtmgd`) behave identically on Linux and macOS hosts — their config dirs live in the same dotfile paths and contain only cross-platform data, so the host mounts in the table above carry credentials and settings into the container without any extra work.

Four tools need different handling on macOS: **Claude Code**, **Copilot CLI**, **gh CLI**, and **Kiro CLI**. Each of them stores its OAuth token in the **macOS Keychain**, not in the dotfile dir, and Copilot/Kiro additionally keep SQLite state in those dirs. Sharing the host dotfiles with the Linux container would therefore (a) carry no token across the boundary anyway, and (b) expose the container's SQLite writes to host writes over Colima's virtio-fs bridge, where SQLite locking is more fragile than on a single OS.

### How `runme.sh` handles this on macOS

When `runme.sh` detects `Darwin`, it transparently swaps the host source for these four tools' mounts to a parallel tree under `~/.ai-containers/` instead of `~/`. The container still sees its standard paths (`~/.copilot`, `~/.claude`, etc.) — only the host backing dir changes. Every container on this Mac (any project, any image) shares the same `~/.ai-containers/` tree, so a one-time in-container `/login` propagates to all future containers.

```text
~/.ai-containers/
├── .copilot/                      ← container's Copilot CLI state + SQLite
├── .claude/                       ← container's Claude Code state + .credentials.json
├── .claude.json                   ← container's Claude Code app state (file mount)
├── .config/gh/                    ← container's gh CLI hosts.yml
├── .kiro/                         ← container's Kiro CLI sessions, history, auth
└── .local/share/kiro-cli/         ← container's Kiro CLI data, KBs, runtime
```

The host's Mac-side `~/.copilot/`, `~/.claude/`, `~/.config/gh/`, `~/.kiro/`, and `~/Library/Application Support/kiro-cli/` are untouched. Host CLIs continue to use macOS Keychain; container CLIs use the file-based credentials they write inside `~/.ai-containers/`. The two are fully independent OAuth sessions; both work.

> The directory name `~/.ai-containers/` is unrelated to the per-project `<project>/.ai-containers/` asset dirs created by `project-init.sh`. They never collide on disk because one lives under `$HOME` and the other under repo roots.

On **Linux hosts**, none of this redirection happens — host and container continue to share `~/.copilot/`, `~/.claude/`, etc. directly, exactly as before.

### Auth fix — one-time login per tool inside the container

Because macOS host CLIs cache tokens in Keychain that the container can't read, do a single `/login` per tool inside any container. The Linux build of each CLI has no Keychain to fall back to, so it writes the token into the mounted `~/.ai-containers/` subdir on the host:

```bash
# Inside the container (any project)
gh auth login        # writes  ~/.ai-containers/.config/gh/hosts.yml
copilot /login       # writes  ~/.ai-containers/.copilot/config.json
claude /login        # writes  ~/.ai-containers/.claude/.credentials.json
# Kiro: log in on first interactive use; the token is written under ~/.ai-containers/.kiro/
```

Verification on the host after the logins:

```bash
ls -la ~/.ai-containers/.claude/.credentials.json   # now exists
```

### First-run prerequisite — auto-created on macOS

`runme.sh` automatically creates `~/.ai-containers/` and the per-tool subpaths for whichever components are enabled in `sandbox.conf`, before evaluating the mounts. It also seeds `~/.ai-containers/.claude.json` with `{}` so the file mount succeeds cleanly on a brand-new Mac. You don't need to pre-create anything by hand.

> **Footnote — `~/.ai-containers/.claude.json` is a *file* mount.** File bind mounts are tied to an inode at mount time. If the container's Claude Code rewrites `.claude.json` via atomic-rename (write tmp + rename), the new file lives at a different inode and host writes stop reflecting through the mount. Auth is unaffected — the OAuth token lives in `~/.ai-containers/.claude/.credentials.json`, *inside* the `~/.ai-containers/.claude/` directory mount, where atomic renames work correctly. Only non-auth state in `.claude.json` is subject to this drift.

### Wiping or backing up container credentials

Because everything container-related is under one root, it's easy to manage:

```bash
# Reset all container-side credentials and state (host CLIs unaffected)
rm -rf ~/.ai-containers
# Backup
tar czf ai-containers-creds.tgz -C "$HOME" .ai-containers
```

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
- Generates `<project>/.ai-containers/<project-name>-container.sh` with `IMAGE_NAME`, `SSH_SCOPE_DIR`, and commented hints for `EXTRA_MOUNTS` and `PREVIEW_PORTS`.
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
- Review the default values in `runme.sh`, especially `IMAGE_NAME` and `SSH_SCOPE_DIR`, before publishing this into a separate repository.

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
