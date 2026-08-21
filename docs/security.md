# Security model, allowlists and tokens

## Security model (restricted mode)

1. **iptables** sets a deny-by-default OUTPUT policy and allows only the allowlisted destinations.
2. **Capability drop**: after iptables is configured, the agent shell is started via `capsh --drop=cap_net_admin,cap_net_raw`, so it cannot modify firewall rules or create raw sockets regardless of file permissions.
3. **Non-root user**: the agent runs as a sandbox user whose username, UID, and GID match the host user that started the container (detected automatically by `sandbox.sh` via `id -u`, `id -g`, `id -un`, `id -gn`). Override by setting `SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP` before running.
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

## Reviewing blocked traffic

When running in restricted mode, blocked outbound destinations are logged automatically to `/workspace/.agent-blocked/`. These files persist on the host in the `.agent-blocked` directory of the launch directory (where you ran `sandbox.sh`).

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

## GitHub tokens at runtime

`sandbox.sh` deliberately does **not** forward `GITHUB_TOKEN` or `GH_TOKEN` into the running container, even if set on the host. Only `GITHUB_PERSONAL_ACCESS_TOKEN` is forwarded.

> Auth files for Copilot CLI and `gh` CLI are sourced from the active container group (`~/.ai-containers/<group>/.copilot/`, `~/.ai-containers/<group>/.config/gh/`, etc. by default). See [Container groups](groups.md) for details. The container path inside the table is unchanged.

| Tool inside the container | Auth source |
|---|---|
| Copilot CLI | `COPILOT_GITHUB_TOKEN` env var (auto-extracted from group's `gh` hosts.yml; or set explicitly) |
| `gh` CLI | `~/.config/gh/hosts.yml` (mounted from host) |
| Copilot CLI's built-in GitHub MCP server (`api.business.githubcopilot.com/mcp/*`) | Copilot's OAuth token — no PAT needed |
| `github/github-mcp-server` / `@modelcontextprotocol/server-github` (stdio) | `GITHUB_PERSONAL_ACCESS_TOKEN` |
| Claude Code's official `github` plugin (`api.githubcopilot.com/mcp/`) | `GITHUB_PERSONAL_ACCESS_TOKEN` — PAT must include the **Copilot Requests** fine-grained permission |
| `git` over HTTPS, `curl api.github.com`, skills/scripts | `GITHUB_PERSONAL_ACCESS_TOKEN` |

**Copilot CLI authentication:** `sandbox.sh` automatically extracts the OAuth token from the active group's `~/.config/gh/hosts.yml` and forwards it as `COPILOT_GITHUB_TOKEN`. This means:
- No `/login` is needed inside the container (if `gh auth` is configured in the group)
- Multiple containers can run simultaneously without revoking each other's sessions (device-flow OAuth is single-session per user; env-var token auth is not)
- You can override by setting `COPILOT_GITHUB_TOKEN` explicitly on the host

> **⚠️ The token is extracted once, at container launch — not while the container runs.**
> `sandbox.sh` reads `hosts.yml` and sets `COPILOT_GITHUB_TOKEN` **before** `docker run` starts the
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
> **The fix:** authenticate **first**, then start (or fully restart) the container so `sandbox.sh`
> can pick up the freshly written token:
> 1. `gh auth login` (on the host, or once inside any container of that group — it persists to
>    `~/.ai-containers/<group>/.config/gh/hosts.yml`).
> 2. **Exit the container completely** (`Ctrl+D`) and relaunch with `./sandbox.sh …` — *not* a
>    Copilot `/restart`. Only a full container relaunch re-runs `sandbox.sh` and re-extracts the token.
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

This keeps every other CLI tool authenticated automatically while preventing Copilot CLI from treating your PAT as a Copilot-API bearer. The container Copilot CLI is already protected because `sandbox.sh` does not forward `GITHUB_TOKEN`/`GH_TOKEN`.

Build-time rate-limit avoidance: `./build.sh` automatically uses `GITHUB_PERSONAL_ACCESS_TOKEN` as the GitHub API token when `GITHUB_TOKEN` is unset, so the recommended setup above is already sufficient for authenticated API calls (5000 req/h). No extra export is needed. If you explicitly want to use a *different* token for the build than the one in your shell profile, set `GITHUB_TOKEN` for that one invocation: `GITHUB_TOKEN=ghp_build_specific ./build.sh`. Either way, the value is consumed only by BuildKit and never lands in the image or the running container.

## Extracting discovery results

After running in discovery mode, reproduce the AI agent interaction you want to observe, then exit the container (`Ctrl+D`). The pcap capture file persists on the host in the `.agent-discovery` directory of the **launch directory** (where you ran `sandbox.sh`).

Extract the DNS and TLS hostname lists:

```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/launch-dir:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

The container prints this command with the correct path when discovery mode starts. The output lists:

- DNS queries — hostnames the container attempted to resolve.
- TLS SNI hostnames — HTTPS endpoints presented during TLS handshakes.

Add the discovered hostnames to `allowlist-domains.d/custom.txt`, rebuild the image with `./build.sh`, and switch to restricted mode.

---

[← Documentation index](README.md)
