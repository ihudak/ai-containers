# GitHub Copilot CLI Dev Container Assets (Public Example)

This directory is the public-shareable asset bundle for the example described in [Wiki: Use dev containers for development with Copilot](https://github.com/ihudak/bookstore/wiki/Use-dev-containers-for-development-with-Copilot).

It packages a CLI-only Docker-based workspace for running GitHub Copilot CLI inside an isolated container with an optional restricted egress policy and a non-root agent shell.

## What is included

- `Dockerfile` builds the image with Git, GitHub CLI, GitHub Copilot CLI, Java, Node.js, Angular CLI, AWS CLI, Azure CLI, `kubectl`, packet capture tools, and a non-root sandbox user created at runtime.
- `entrypoint.sh` switches between `restricted` and `discovery` runtime modes. In both modes it creates the sandbox user and drops to it via `capsh`. Restricted mode drops `NET_ADMIN` and `NET_RAW`; discovery mode drops only `NET_ADMIN` (keeping `NET_RAW` for tcpdump).
- `refresh-ipset-allowlist.sh` resolves concrete hostnames into IPv4 and IPv6 `ipset` sets.
- `capture-blocked-traffic.sh` runs as a background root daemon in restricted mode, logging every blocked outbound destination to `/workspace/.copilot-blocked/`.
- `capture-copilot-destinations.sh` captures DNS and TLS metadata so you can refine your allowlist.
- `allowlist-domains.txt` contains a public-safe example domain list with placeholders instead of corporate endpoints.
- `allowlist-cidrs.txt` contains explicit IP and CIDR entries, typically loopback plus any proxy IPs you approve.
- `allowlist-proxy-domains.txt` contains the wildcard Copilot domain patterns used by the self-healing daemon for reactive auto-allowing, and optionally by an upstream proxy or FQDN-aware firewall.
- `runme.sh` is the convenience wrapper for building and running the example container.

## Usage

Build the image:

```bash
./runme.sh build
```

Run in restricted mode with a mounted project:

```bash
./runme.sh restricted /path/to/your/repo
```

Run in discovery mode to observe destinations before you lock the policy down:

```bash
./runme.sh discovery /path/to/your/repo
```

Inside the container, the repository is mounted at `/workspace`.

## Extracting discovery results

After running in discovery mode, reproduce the Copilot interaction you want to observe, then exit the container (`Ctrl+D`). The pcap capture file persists on the host in the `.copilot-discovery` directory inside your workspace.

Extract the DNS and TLS hostname lists:

```bash
docker run --rm --entrypoint capture-copilot-destinations.sh \
  -v "/path/to/your/repo:/workspace" copilot-sandbox extract /workspace/.copilot-discovery
```

The container prints this command with the correct path when discovery mode starts. The output lists:

- DNS queries — hostnames the container attempted to resolve.
- TLS SNI hostnames — HTTPS endpoints presented during TLS handshakes.

Add the discovered hostnames to `allowlist-domains.txt`, rebuild the image, and switch to restricted mode.

## Mounting additional repositories

Set `EXTRA_MOUNTS` to a space-separated list of host paths. Append `:ro` or `:rw` to control per-directory access. The default is read-write.

```bash
# primary workspace + a reference repo mounted read-only
EXTRA_MOUNTS="/path/to/shared-lib:ro /path/to/second-service" \
bash ./runme.sh restricted /path/to/your-main-repo
```

Each path is mounted at `/repos/<basename>` inside the container.

## Reviewing blocked traffic

When running in restricted mode, blocked outbound destinations are logged automatically to `/workspace/.copilot-blocked/`. These files persist on the host via the workspace mount.

| File | Purpose |
|------|---------|
| `blocked.log` | Timestamped log of every blocked connection attempt |
| `blocked-domains.txt` | Deduplicated domain list — copy-paste directly into `allowlist-domains.txt` |
| `blocked-ips.txt` | Deduplicated IPs with no known domain — copy-paste into `allowlist-cidrs.txt` |

To update the allowlist after a session:

```bash
cat /workspace/.copilot-blocked/blocked-domains.txt
# copy the domain lines (below the comment header) → paste into allowlist-domains.txt

cat /workspace/.copilot-blocked/blocked-ips.txt
# copy the IP lines → paste into allowlist-cidrs.txt
```

Then rebuild the image and restart the container.

## Security model (restricted mode)

1. **iptables** sets a deny-by-default OUTPUT policy and allows only the allowlisted destinations.
2. **Capability drop**: after iptables is configured, the agent shell is started via `capsh --drop=cap_net_admin,cap_net_raw`, so it cannot modify firewall rules or create raw sockets regardless of file permissions.
3. **Non-root user**: the agent runs as a sandbox user whose username, UID, and GID match the host user that started the container (detected automatically by `runme.sh` via `id -u`, `id -g`, `id -un`, `id -gn`). Override by setting `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP` before running.
4. **Background daemons**: the ipset refresh loop and the blocked-traffic capture daemon are forked before the capability drop and retain their root capabilities to do their jobs.
5. **Self-healing allowlist**: when a blocked IP maps to a domain that is already in `allowlist-domains.txt` or matches a wildcard pattern from `allowlist-proxy-domains.txt`, the daemon adds the IP to the active ipset on the fly. This cannot be exploited by the sandbox user: the internal lookup tables (DNS map, domain caches) are stored in a root-only directory (`/run/copilot-blocked-internal`, mode 700) inaccessible to the sandbox shell, and `CAP_NET_RAW` is dropped so DNS responses cannot be spoofed. Set `SELF_HEALING_ENABLED=0` to disable self-healing entirely and use logging-only mode.

Discovery mode runs as the sandbox user with unrestricted egress and `NET_RAW` retained (for tcpdump). It is intended for supervised traffic observation only.

## Public customization points

- Replace the placeholder entries in `allowlist-domains.txt` with the real documentation, package, Git, and MCP endpoints you need.
- If you use an HTTP proxy for Copilot wildcard domains, keep those wildcards in `allowlist-proxy-domains.txt` and add only the proxy IPs or narrow CIDRs to `allowlist-cidrs.txt`.
- The sandbox user identity (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP`) is detected automatically from the host user at runtime. No build-time args needed.
- Review the defaults in `runme.sh`, especially `IMAGE_NAME` and `SSH_SCOPE_DIR`, before using this as your own template repository.
- Keep secrets and personal configuration mounted from the host rather than copying them into the image.

## Important notes

- Wildcard Copilot domains such as `*.githubcopilot.com` cannot be pre-resolved into `iptables` rules. The self-healing daemon handles this reactively by auto-allowing IPs whose resolved domains match wildcard patterns in `allowlist-proxy-domains.txt`. An upstream proxy provides proactive enforcement if available.
- Direct-connect allowlists can drift as DNS answers and CDN backends change, so refresh and validate regularly.
- This repo is meant to be illustrative and reusable, so the included non-GitHub endpoints are placeholders by design.
