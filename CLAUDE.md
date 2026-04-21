# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A CLI-only Docker workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, Claude Code, etc.) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell. It is intentionally not a VS Code dev container.

## Commands

**Build the image:**
```bash
./runme.sh build [image-name]
```
`runme.sh` auto-detects whether to include Kiro CLI: it passes `--build-arg INSTALL_KIRO=1` only when `~/.kiro` exists on the host or `kiro.dev` is reachable.

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
  - `blocked-domains.txt` — deduplicated domains for copy-paste into `allowlist-domains.txt`
  - `blocked-ips.txt` — IPs with no known domain, for `allowlist-cidrs.txt`

**Self-healing** (on by default): if a blocked IP resolves to a domain already in `allowlist-domains.txt` or matching a wildcard in `allowlist-proxy-domains.txt`, the daemon calls `ipset add` immediately without waiting for the 60-second refresh loop. This handles dynamic IPs behind CDNs (e.g. `*.githubcopilot.com`).

### Allowlist files

| File | Purpose |
|------|---------|
| `allowlist-domains.txt` | Concrete FQDNs; resolved to IPs at startup and every 60 s |
| `allowlist-cidrs.txt` | Literal IPs and CIDRs added directly to ipset |
| `allowlist-proxy-domains.txt` | Wildcard patterns (e.g. `*.githubcopilot.com`) used only by the self-healing daemon for reactive IP matching |

### Conditional Kiro CLI installation

The `Dockerfile` accepts `ARG INSTALL_KIRO=0`. When `1`, the Kiro install script runs and the three Kiro binaries are copied to `/usr/local/bin`. The `runme.sh` build function sets this automatically.

### Sandbox user identity

No user is baked into the image. `entrypoint.sh` calls `useradd`/`usermod` at runtime using the env vars from `runme.sh`. This means the same image works for any team member without rebuilding.

## Corporate customization

- Add environment-specific FQDNs (Dynatrace, internal Git, artifact repos, MCP endpoints) to `allowlist-domains.txt`.
- If agent traffic routes through a corporate proxy, keep wildcard domains in `allowlist-proxy-domains.txt` and allow only proxy IPs in `allowlist-cidrs.txt`.
- Review `IMAGE_NAME` and `SSH_SCOPE_DIR` defaults in `runme.sh` before publishing.
- `runme.sh` also mounts `~/.config/dtctl` and `~/.config/dtmgd` into the sandbox home when they exist on the host.
