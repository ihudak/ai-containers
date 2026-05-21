# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A CLI-only Docker workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI) and related developer tools (graphify, qmd, etc.) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell. It is intentionally not a VS Code dev container.

## Component configuration

`sandbox.conf` is the single source of truth for which optional components are included. Set a component to `ON` or `OFF` and rebuild. The format is strictly `component=ON` or `component=OFF`, one per line; comments start with `#`.

Optional components: `copilot`, `kiro`, `claude-code`, `codex`, `gemini`, `graphify`, `openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`, `kubectl`, `aws-cli`, `azure-cli`, `github-cli`, `angular-cli`, `yarn`, `bun`, `qmd`, `dtctl`, `dtmgd`.

Version-list components (`node`, `python`, `ruby`, `rails`, `rust`, `go`) accept comma-separated version values instead of `ON`/`OFF` (e.g., `node=22,20`). Constraints:
- `ruby`, `rails`, and `angular-cli` accept only a **single version** (not a comma-separated list).
- SDKMAN-managed components (`openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`) require **full patch versions** (e.g., `openjdk=21.0.11`, not `21`).
- `dtctl` and `dtmgd` accept `ON` (auto-detect latest from GitHub), `x.y.z` (pinned), or `OFF`.

## Commands

**Build the image:**
```bash
./runme.sh build [image-name]
```
`runme.sh build` reads `sandbox.conf`, assembles `allowlist-domains.txt`, `allowlist-proxy-domains.txt`, and `allowlist-cidrs.txt` from the `*.d/` fragment directories, then calls `docker build` with one `--build-arg` per component. The generated `allowlist-*.txt` files are gitignored; always use `./runme.sh build`, not `docker build` directly.

Set `GITHUB_TOKEN` in the environment before building to avoid GitHub API rate limits (60 req/h unauthenticated). This is required when `dtctl` or `dtmgd` is set to `ON` (auto-detect latest). `runme.sh build` passes it automatically as a BuildKit secret if the env var is set. If rate-limited, `dtctl`/`dtmgd` are silently skipped — the build still succeeds.

**Run the container:**
```bash
./runme.sh restricted /path/to/workspace   # firewall on, NET_ADMIN+NET_RAW dropped from agent shell
./runme.sh discovery /path/to/workspace    # unrestricted egress + background pcap
```

**Initialise a new project** (copies shared files, generates launch script, registers in `projects.conf`):
```bash
./project-init.sh /path/to/myproject [optional-name]
```

**Sync shared files to all registered projects** (after pulling updates to this repo):
```bash
./sync-to-projects.sh              # all projects in projects.conf
./sync-to-projects.sh /path/to/p   # single project
```

**Extract discovery results** (after exiting a discovery-mode container):
```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/workspace:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

**Key env vars for `runme.sh`:**
- `AI_CONTAINER_GROUP` — selects which dotfile tree mounts into the container: `default` (the implicit default), `host` (mount $HOME directly — Linux backward-compatible behavior; macOS shows a warning and requires `yes` or `AI_CONTAINER_HOST_ACK=1`), or a custom name (e.g. `docs`, `java-backend`). Custom groups live at `~/.ai-containers/<name>/`.
- `AI_CONTAINER_GROUP_INIT` — non-interactive bootstrap override when a group dir doesn't exist yet. Values: `clean` (start empty), `from:host` (copy from $HOME), `from:<existing-group>` (copy from another group). When unset on a TTY, an interactive prompt asks instead.
- `AI_CONTAINER_HOST_ACK` — set to `1` to silently bypass the macOS warning when `AI_CONTAINER_GROUP=host`. Ignored on Linux. Per-invocation; not persisted.
- `IMAGE_NAME` — image tag (default: `ai-sandbox`)
- `SANDBOX_UID/GID/USER/GROUP` — override the auto-detected host user identity
- `EXTRA_MOUNTS` — space-separated extra host paths to mount under `/repos/<basename>`, e.g. `EXTRA_MOUNTS="/path/to/a:ro /path/to/b"`
- `DOCS_PATH` — host directory mounted as `/docs` inside the container
- `SPECS_PATH` — host directory mounted as `/specs` inside the container
- `VAULT_PATH` — host Obsidian vault mounted as `/obsidian`; also re-exported as `VAULT_PATH=/obsidian` inside the container so agent skills/workflows resolve to the in-container path. Pair with `qmd=ON` in `sandbox.conf` for in-container markdown search.
- `PREVIEW_PORTS` — space-separated ports (or `host:container` pairs) to publish for dev servers, e.g. `PREVIEW_PORTS="3000 8080:8080"`
- `CONTAINER_CPUS` — CPU limit for the running container (default: `4.0`)
- `CONTAINER_MEMORY` — memory limit for the running container (default: `8g`)
- `ALLOW_IPV6_BYPASS=1` — suppress the visual warning when `ip6tables` is unavailable (WSL2/nf_tables environments)
- `SELF_HEALING_ENABLED=0` — disable reactive IP auto-allowing (logging only)

## Architecture

### Container startup flow

`entrypoint.sh` runs as root and drives both modes:

1. **`setup_sandbox_user`** — creates/renames a user whose UID/GID match `SANDBOX_UID`/`SANDBOX_GID` (passed by `runme.sh` from `id -u`/`id -g`). Files in bind-mounted volumes are then accessible without chown.

2. **restricted mode**: calls `apply_restricted_firewall` → forks the ipset refresh loop and `capture-blocked-traffic.sh` as root background daemons → `exec capsh --drop=cap_net_admin,cap_net_raw --user=<sandbox>` to drop firewall-modification capabilities from the agent shell.

3. **discovery mode**: calls `apply_discovery_firewall` (iptables OUTPUT ACCEPT) → starts `capture-agent-destinations.sh` for pcap → `exec capsh --drop=cap_net_admin --user=<sandbox>` (NET_RAW kept for tcpdump).

Background daemons are forked **before** `exec capsh` so they retain root capabilities despite the exec.

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

### Sandbox user identity

No user is baked into the image. `entrypoint.sh` calls `useradd`/`usermod` at runtime using the env vars from `runme.sh`. This means the same image works for any team member without rebuilding.

### Host directory mounts

Agent dotfile dirs (`.claude`, `.copilot`, `.kiro`, `.codex`, `.gemini`, `.config/gh`, `.agents`, `.ssh`) are mounted from a **container group** — a named directory under `~/.ai-containers/<group>/`. The active group is selected by `AI_CONTAINER_GROUP` (default: `default`). To use a custom group, set the env var before running: `AI_CONTAINER_GROUP=docs ./runme.sh restricted /path/to/workspace`. Each group is a plain directory; use `ls ~/.ai-containers/`, `cp -a`, or `rm -rf` to inspect, duplicate, or delete groups.

`runme.sh` always creates the group directory and its `.ssh/` + `.agents/` scaffold on first run. Per-component dirs (`.claude/`, `.copilot/`, etc.) are created only when the corresponding component is enabled in `sandbox.conf`.

Host-shared paths that are not group-scoped (unchanged): `.gitconfig` (ro), `.aws`, `.azure`, `.kube`, `.config/dtctl`, `.config/dtmgd`, `.yarn`.

### macOS host notes

The previous platform-specific redirect (macOS mounted four tools from `~/.ai-containers/` while Linux mounted them from `$HOME`) has been replaced by the unified group system. Both platforms now resolve agent dotfile mounts through the same group root (`~/.ai-containers/<group>/` by default, or `$HOME` when `AI_CONTAINER_GROUP=host`).

The macOS Keychain context remains relevant for the `host` group: Claude Code, GitHub Copilot CLI, Kiro CLI, and GitHub CLI store OAuth tokens in the macOS Keychain rather than in their dotfile dirs. When `AI_CONTAINER_GROUP=host` is set on macOS, a Linux container cannot read those tokens. This is why `runme.sh` prints a warning and requires explicit acknowledgement (`yes` at the prompt, or `AI_CONTAINER_HOST_ACK=1`) before proceeding. The default `default` group avoids this issue entirely — it stores all credentials in `~/.ai-containers/default/` using file-based auth that works on Linux and macOS alike.

On macOS, the first run after upgrading from a pre-grouping version automatically moves the legacy flat layout (`~/.ai-containers/.claude`, etc.) into `~/.ai-containers/default/` and prints a verbose log to stderr. The migration is idempotent.

## Corporate customization

- Edit `sandbox.conf` to enable only the components your team uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints) to `allowlist-domains.d/custom.txt`.
- If agent traffic routes through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and proxy IPs/CIDRs to `allowlist-cidrs.d/custom.txt`.
- Review the `IMAGE_NAME` default in `runme.sh` before publishing.
