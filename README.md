# GitHub Copilot CLI Dev Container Assets (Public Example)

This directory is the public-shareable asset bundle for the example described in [Wiki: Use dev containers for development with Copilot](https://github.com/ihudak/bookstore/wiki/Use-dev-containers-for-development-with-Copilot).

It packages a CLI-only Docker-based workspace for running GitHub Copilot CLI inside an isolated container with an optional restricted egress policy.

## What is included

- `Dockerfile` builds the image with Git, GitHub CLI, GitHub Copilot CLI, Java, Node.js, Angular CLI, AWS CLI, Azure CLI, `kubectl`, and packet capture tools.
- `entrypoint.sh` switches between `restricted` and `discovery` runtime modes.
- `refresh-ipset-allowlist.sh` resolves concrete hostnames into IPv4 and IPv6 `ipset` sets.
- `capture-copilot-destinations.sh` captures DNS and TLS metadata so you can refine your allowlist.
- `allowlist-domains.txt` contains a public-safe example domain list with placeholders instead of corporate endpoints.
- `allowlist-cidrs.txt` contains explicit IP and CIDR entries, typically loopback plus any proxy IPs you approve.
- `allowlist-proxy-domains.txt` documents the wildcard Copilot domains that must be enforced by a proxy or FQDN-aware firewall.
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

## Public customization points

- Replace the placeholder entries in `allowlist-domains.txt` with the real documentation, package, Git, and MCP endpoints you need.
- If you use an HTTP proxy for Copilot wildcard domains, keep those wildcards in `allowlist-proxy-domains.txt` and add only the proxy IPs or narrow CIDRs to `allowlist-cidrs.txt`.
- Review the defaults in `runme.sh`, especially `IMAGE_NAME` and `SSH_SCOPE_DIR`, before using this as your own template repository.
- Keep secrets and personal configuration mounted from the host rather than copying them into the image.

## Important notes

- Wildcard Copilot domains such as `*.githubcopilot.com` cannot be represented safely with plain `iptables` alone.
- Direct-connect allowlists can drift as DNS answers and CDN backends change, so refresh and validate regularly.
- This repo is meant to be illustrative and reusable, so the included non-GitHub endpoints are placeholders by design.
