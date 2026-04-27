# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A CLI-only Docker workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, etc.) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell. It is intentionally not a VS Code dev container.

## Component configuration

`sandbox.conf` is the single source of truth for which optional components are included. Set a component to `ON` or `OFF` and rebuild. The format is strictly `component=ON` or `component=OFF`, one per line; comments start with `#`.

Optional components: `copilot`, `kiro`, `claude-code`, `codex`, `gemini`, `openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`, `kubectl`, `aws-cli`, `azure-cli`, `github-cli`, `angular-cli`, `yarn`, `dtctl`, `dtmgd`.

## Commands

**Build the image:**
```bash
./runme.sh build [image-name]
```
`runme.sh build` reads `sandbox.conf`, assembles `allowlist-domains.txt`, `allowlist-proxy-domains.txt`, and `allowlist-cidrs.txt` from the `*.d/` fragment directories, then calls `docker build` with one `--build-arg` per component. The generated `allowlist-*.txt` files are gitignored; always use `./runme.sh build`, not `docker build` directly.

**Run the container:**
```bash
./runme.sh restricted /path/to/workspace   # firewall on, NET_ADMIN+NET_RAW dropped from agent shell
./runme.sh discovery /path/to/workspace    # unrestricted egress + background pcap
```

**Extract discovery results** (after exiting a discovery-mode container):
```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/workspace:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

**Key env vars for `runme.sh`:**
- `IMAGE_NAME` — image tag (default: `ai-sandbox`)
- `SSH_SCOPE_DIR` — host SSH directory to mount read-only as `~/.ssh`
- `SANDBOX_UID/GID/USER/GROUP` — override the auto-detected host user identity
- `EXTRA_MOUNTS` — space-separated extra host paths to mount under `/repos/<basename>`, e.g. `EXTRA_MOUNTS="/path/to/a:ro /path/to/b"`
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

### Conditional installs in the Dockerfile

Every optional component has a corresponding `ARG INSTALL_<COMPONENT>=0|1` declared immediately before its `RUN` block. The npm-based tools (Copilot, Angular CLI, Claude Code, Codex, Gemini, Yarn) each have their own `RUN` layer so toggling one doesn't invalidate the others. The dtctl/dtmgd block skips entirely when both are disabled.

### Sandbox user identity

No user is baked into the image. `entrypoint.sh` calls `useradd`/`usermod` at runtime using the env vars from `runme.sh`. This means the same image works for any team member without rebuilding.

## Corporate customization

- Edit `sandbox.conf` to enable only the components your team uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints) to `allowlist-domains.d/custom.txt`.
- If agent traffic routes through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and proxy IPs/CIDRs to `allowlist-cidrs.d/custom.txt`.
- Review `IMAGE_NAME` and `SSH_SCOPE_DIR` defaults in `runme.sh` before publishing.
