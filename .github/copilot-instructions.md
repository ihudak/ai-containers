# GitHub Copilot Instructions

## What this project is

A CLI-only Docker workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, etc.) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell. Intentionally not a VS Code dev container.

## Commands

**Build:**
```bash
./runme.sh build [image-name]
```
Always use `./runme.sh build`, never `docker build` directly — it assembles the allowlist files from `*.d/` fragments before calling `docker build`.

Set `GITHUB_TOKEN` before building to avoid GitHub API rate limits (required when `dtctl=ON` or `dtmgd=ON`).

**Run:**
```bash
./runme.sh restricted /path/to/workspace   # firewall on, NET_ADMIN+NET_RAW dropped from agent shell
./runme.sh discovery /path/to/workspace    # unrestricted egress + background pcap
```

**Project init / sync:**
```bash
./project-init.sh /path/to/myproject [optional-name]   # init new project
./sync-to-projects.sh                                   # sync shared files to all registered projects
```

There are no automated tests or linting in this repository.

## Architecture

### Configuration: `sandbox.conf`

`sandbox.conf` is the single source of truth for what goes into the image. `runme.sh build` reads it and passes one `--build-arg INSTALL_<COMPONENT>=0|1` per component to `docker build`.

- Boolean components: `ON` / `OFF`
- Version-list components (`node`, `python`, `rust`, `go`): comma-separated versions
- `ruby` and `rails`: single version only (multi-version is ambiguous due to rails/ruby pairing)
- SDKMAN components (`openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`): require full patch versions (e.g. `openjdk=21.0.11`, not `21`)
- `dtctl`/`dtmgd`: `ON` (auto-detect latest), `x.y.z` (pinned), or `OFF`

### Allowlist assembly

Three allowlist files are assembled at build time from fragment directories:

| Directory | Generated file |
|-----------|---------------|
| `allowlist-domains.d/` | `allowlist-domains.txt` |
| `allowlist-proxy-domains.d/` | `allowlist-proxy-domains.txt` |
| `allowlist-cidrs.d/` | `allowlist-cidrs.txt` |

Per-component fragments (e.g. `github-copilot.txt`, `claude-code.txt`) are only included when the component is `ON`. The generated `allowlist-*.txt` files are gitignored.

**`custom.txt` files are gitignored.** Each `*.d/` directory ships a `custom.txt.example` — copy it to `custom.txt` before adding entries or they won't be assembled into the image.

### Container startup flow (`entrypoint.sh`)

1. **`setup_sandbox_user`** — creates/renames a user whose UID/GID match `SANDBOX_UID`/`SANDBOX_GID` from the host. No user is baked into the image so the same image works for any team member.
2. **restricted mode**: applies iptables rules → forks the ipset refresh loop and `capture-blocked-traffic.sh` as **root** background daemons → `exec capsh --drop=cap_net_admin,cap_net_raw` to drop firewall capabilities from the agent shell.
3. **discovery mode**: opens egress → starts `capture-agent-destinations.sh` for pcap → `exec capsh --drop=cap_net_admin`.

Background daemons are forked **before** `exec capsh` — this is intentional so they retain root capabilities.

### Network enforcement

- `refresh-ipset-allowlist.sh` resolves FQDNs from `allowlist-domains.txt` into two ipsets (`allowed_ipv4`, `allowed_ipv6`), runs at startup and loops every 60s.
- iptables OUTPUT chain: ESTABLISHED/RELATED → loopback → DNS (53) → ipset match → NFLOG (group 100) → DROP.
- NFLOG is used instead of LOG because it works reliably in WSL2/nf_tables environments.
- **Self-healing**: `capture-blocked-traffic.sh` watches NFLOG group 100 and calls `ipset add` immediately when a blocked IP resolves to a domain already in the baked-in allowlist (handles CDN IP churn without waiting for the 60s refresh loop).

### Dockerfile conventions

- Each npm-based tool (`copilot`, `angular-cli`, `claude-code`, `codex`, `gemini`, `yarn`, `qmd`, `bun`) has its own `RUN` layer so toggling one component doesn't bust the Docker cache for others.
- Every optional component has an `ARG INSTALL_<COMPONENT>=0|1` declared immediately before its `RUN` block.
- `dtctl`/`dtmgd` use a BuildKit `--mount=type=secret,id=github_token` — the token is never written into image layers.

## Key conventions

- **`GITHUB_PERSONAL_ACCESS_TOKEN` vs `GITHUB_TOKEN`**: `GITHUB_PERSONAL_ACCESS_TOKEN` is forwarded into the running container (used by MCP servers and Claude Code's GitHub plugin). `GITHUB_TOKEN` and `GH_TOKEN` are deliberately **not** forwarded — Copilot CLI would attempt to use them and fail with a 401 if the PAT lacks the `Copilot Requests` permission.
- **`PREVIEW_PORTS`** env var: space-separated port specs (`3000`, `8080:3000`) published so the host browser can reach dev servers inside the container.
- **`EXTRA_MOUNTS`**: space-separated host paths mounted under `/repos/<basename>`. Append `:ro` or `:rw` per path.
- **`VAULT_PATH`**: host Obsidian vault mounted as `/obsidian`; also re-exported inside the container as `VAULT_PATH=/obsidian`. Pair with `qmd=ON` for in-container markdown search.
- When adding domains for a new component, add a fragment file in each relevant `allowlist-*.d/` directory and reference it from `runme.sh build`'s assembly logic.
