# AI Sandbox Container Assets (Public Example)

This directory is the repo-ready asset bundle for the Public-flavored AI sandbox container described in [Wiki: Use dev containers for development with AI agents](https://github.com/ihudak/bookstore/wiki/Use-dev-containers-for-development-with-Copilot).

It packages a CLI-only Docker-based workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, and others) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell.

## Requirements

- **Docker ≥ 23** (BuildKit is required and is the default since Docker 23). Verify with `docker --version`.
- **Bash ≥ 4.4** on the host (for `runme.sh`). Linux distributions ship this by default. macOS ships bash 3.2 — install a newer version via `brew install bash` if needed.

## What is included

- `Dockerfile` builds the image from a configurable set of optional components: AI agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI), JVM toolchains (via SDKMAN: OpenJDK, GraalVM CE, Kotlin, Scala, Maven, Gradle), Node.js versions (via nvm), Python versions (via pyenv), Ruby + Rails (via rvm), Rust (via rustup), Go, cloud CLIs (AWS, Azure, kubectl, GitHub CLI), dev tools (Angular CLI), and Dynatrace CLIs (dtctl, dtmgd). Node.js (latest LTS), Python (latest stable), git, packet-capture tools, and the non-root sandbox user are always included.
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
openjdk=21,25
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

**Option 2 — pin a specific version** (no API call at all):
```bash
# In sandbox.conf:
dtctl=0.25.0
dtmgd=0.0.23
```

If the API call fails (rate limit, bad token, or network error), the build prints a clear error message, skips the tool, and **continues successfully**. dtctl/dtmgd can be installed manually later. An expired or invalid `GITHUB_TOKEN` is treated the same as a network error — the build does not fail, but the tool is skipped with a warning.

> **Note on token security:** `GITHUB_TOKEN` is passed as a [BuildKit secret](https://docs.docker.com/build/building/secrets/) — it is never written to any image layer or visible in `docker history`. Safe to use even if you plan to publish the image. Requires Docker ≥ 23 (BuildKit default).

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

## Mounting additional repositories

Set `EXTRA_MOUNTS` to a space-separated list of host paths. Append `:ro` or `:rw` to control per-directory access. The default is read-write. **Paths with spaces are not supported** (the variable is split on whitespace).

```bash
# backend is the primary workspace; ui is read-write, reference-docs is read-only
SSH_SCOPE_DIR="$HOME/.ssh/myproject" \
EXTRA_MOUNTS="/path/to/myproject-ui /path/to/reference-docs:ro" \
bash ./runme.sh restricted /path/to/myproject-backend
```

Each path is mounted at `/repos/<basename>` inside the container.

## Host configuration mounts

The container automatically mounts the following directories from the host (if they exist) into the sandbox user's home:

Each directory is only mounted when its corresponding component is enabled in `sandbox.conf`. Missing directories are silently skipped.

| Host directory | Container path | Mode | Component |
|---|---|---|---|
| `~/.ssh` (or `SSH_SCOPE_DIR`) | `~/.ssh` | read-only | always |
| `~/.config/gh` | `~/.config/gh` | read-write | `github-cli` or `copilot` |
| `~/.copilot` | `~/.copilot` | read-write | `copilot` |
| `~/.kiro` | `~/.kiro` | read-write | `kiro` |
| `~/.local/share/kiro-cli` | `~/.local/share/kiro-cli` | read-write | `kiro` |
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
| `allowlist-proxy-domains.d/` | Wildcard patterns used by the self-healing daemon (e.g. `*.githubcopilot.com`) | `custom.txt` | `github-copilot.txt`, `kiro.txt`, `dynatrace.txt` |
| `allowlist-cidrs.d/` | Literal IP addresses and CIDR ranges added directly to ipset | `base.txt`, `custom.txt` | `github-copilot.txt` |

**Where to put your additions:**

| What you want to add | File to edit |
|----------------------|-------------|
| A domain needed by an enabled component (e.g. a missing Copilot endpoint) | `allowlist-domains.d/<component>.txt` |
| A domain not tied to any component (search engine, internal registry, MCP server) | `allowlist-domains.d/custom.txt` |
| A wildcard pattern for the self-healing daemon | `allowlist-proxy-domains.d/custom.txt` |
| A corporate proxy IP or narrow CIDR | `allowlist-cidrs.d/custom.txt` |

After editing any fragment file, run `./runme.sh build` to regenerate the image.

## Corporate customization points

- Edit `sandbox.conf` to enable only the components your team actually uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints, search engines) to `allowlist-domains.d/custom.txt`.
- If agent traffic must go through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and allow only the proxy IPs in `allowlist-cidrs.d/custom.txt`.
- The sandbox user identity (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP`) is detected automatically from the host user at runtime. No build-time args needed.
- Review the default values in `runme.sh`, especially `IMAGE_NAME` and `SSH_SCOPE_DIR`, before publishing this into a separate repository.

## Important notes

- Plain `iptables` cannot pre-resolve wildcard domains such as `*.githubcopilot.com` or `*.kiro.dev` into IP addresses. The self-healing daemon handles this reactively by auto-allowing IPs whose resolved domains match wildcard patterns in `allowlist-proxy-domains.d/`. An upstream proxy provides proactive enforcement if available.
- **DNS is unrestricted.** The firewall allows all outbound DNS (port 53) to any resolver. This is required for domain resolution but means DNS tunneling is theoretically possible. For higher-security deployments, restrict DNS to a specific resolver by adding `--dns 8.8.8.8` to the `docker run` command and tightening the iptables DNS rules in `entrypoint.sh`.
- **IPv6 firewall may be unavailable.** Some environments (notably WSL2 with the nf_tables backend) lack `ip6table_filter`. When this happens, the IPv4 firewall works normally but IPv6 egress is completely unrestricted. The container prints a prominent warning at startup. Set `ALLOW_IPV6_BYPASS=1` to acknowledge the risk and suppress the hint.
- **GraalVM Oracle licensing.** The `graalvm` key in `sandbox.conf` installs Oracle GraalVM, which is free for production use under the [GraalVM Free Terms and Conditions (GFTC)](https://www.oracle.com/downloads/licenses/graal-free-license.html) since September 2023. If you distribute images built with `graalvm=<version>`, ensure your use complies with the GFTC. GraalVM Community Edition (`graalvm-ce`) is fully open-source under GPLv2+CE.
- The per-component domain fragments are a practical baseline, not a guarantee that every future agent endpoint is covered. Use discovery mode to find gaps.
- The asset set is intentionally CLI-only and does not depend on VS Code dev containers.
- All optional components — including Kiro CLI — are controlled solely by `sandbox.conf`. There is no runtime auto-detection.
- **Angular CLI** (`angular-cli=ON`) is included as a dev tool because AI coding agents frequently scaffold and modify Angular projects. It is not an AI agent itself.
- **Image size** depends heavily on which components are enabled. A minimal image (just Node.js + Python + one AI agent) is ~2–3 GB. With all JVM toolchains, multiple Node/Python versions, Ruby, Rust, Go, and all AI agents enabled, expect 8–12 GB. Disable unused components in `sandbox.conf` to reduce size and build time.
