# Agent-tier tools and keeping them current

## Keeping tools up to date

The AI agents (Copilot CLI, Claude Code, Codex CLI, Gemini CLI), `graphify`, and `vale` are **not** baked into the image at all — see [Agent-tier tools (`~/.ai-tools`)](#agent-tier-tools-ai-tools) below for how they stay current without ever rebuilding.

**Kiro CLI** and every `tools.d`-described tool (`dtctl`, `dtmgd`, `acli`) *are* baked into the image at build time, and Docker caches those layers — a plain `./build.sh` will *not* pick up a newer release of any of them. To refresh, from your project's `.ai-containers/` directory:

```bash
./build.sh --no-cache      # then ./runme.sh as usual
```

(The generated `runme.sh` carries a commented-out `--no-cache` line for exactly this.)

or, for the tools that support it (`dtctl`/`dtmgd` accept an exact `x.y.z` in `sandbox.conf`), bump the pinned version by hand instead of rebuilding everything.

Each rebuild that produces a new image also drops the image it replaced, so dangling layer sets do not accumulate per project. The cleanup is deliberately narrow: one explicit image ID, skipped if that image still carries a tag, and `docker rmi` without `--force` so an image a container still references is kept. Build-cache records are never touched automatically — reclaim them yourself when needed:

```bash
docker builder prune --filter unused-for=720h
```

## Agent-tier tools (`~/.ai-tools`)

Mirroring [Ruby (via rvm)](components/ruby.md): nothing agent-tier is baked into the image. Claude Code, Codex CLI, Gemini CLI, Copilot CLI, `graphify`, and `vale` install at **container start** into a per-user `~/.ai-tools` home (npm prefix `~/.ai-tools/npm`, `graphify`'s `uv` tool dir `~/.ai-tools/uv`, `vale`'s binary in `~/.ai-tools/bin`), mounted from the active container **group** — the same mechanism as `~/.claude`/`~/.codex`/`~/.gemini` (see [Host configuration mounts](repos-and-mounts.md#host-configuration-mounts)) — so the install is shared by every project using that group and survives container restarts and rebuilds.

`agent-tools-reconcile.sh` (running as the sandbox user at container start, `flock`-guarded against concurrent same-group container starts) installs whichever enabled tools are missing from the group's `~/.ai-tools` — **install-if-missing only**. Because the install lives in a user-writable directory instead of a root-owned, read-only image layer, each tool can self-update in place using its own updater (e.g. the agent CLI's own `/update` or auto-updater, `npm update -g`, `uv tool upgrade`) — no rebuild required. `link-agent-tools.sh` then symlinks each installed tool's binary onto `/usr/local/bin` so non-interactive, non-login shells (`docker exec -T <container> bash -c "claude …"`) resolve them too, not only login/interactive shells that source `/etc/profile.d/ai-tools.sh`.

Three modes are available:

- **restricted** — deny-by-default firewall (only allowlisted destinations reachable),
  with a background daemon logging blocked outbound destinations. Drops `NET_ADMIN`
  and `NET_RAW` from the agent shell. The default choice for day-to-day agent use.
- **discovery** — unrestricted egress **with** capture (pcap + DNS/TLS destination
  logging), used to observe what an agent actually reaches before writing a
  restricted allowlist. Drops only `NET_ADMIN` (keeps `NET_RAW` for tcpdump).
- **open** — unrestricted egress and **no** capture (no firewall, no allowlist, no
  traffic logging). For projects that do not need network isolation. Drops both
  `NET_ADMIN` and `NET_RAW`. Equivalent to the historical
  `DISCOVERY_CAPTURE_ENABLED=0 ./sandbox.sh discovery`, but honestly named.

Run in restricted mode with the firewall enabled:

```bash
./sandbox.sh restricted /path/to/your/repo
```

Run in discovery mode to capture outbound destinations before tightening the allowlist:

```bash
./sandbox.sh discovery /path/to/your/repo
```

Run in open mode for unrestricted egress with no capture:

```bash
./sandbox.sh open /path/to/your/repo
```

Everything is mounted under a single `/workspace` umbrella: the positional argument
(a host path here) is bind-mounted at `/workspace/<basename>` and becomes the working
directory; `REPOS` entries appear at `/workspace/<name>`, `EXTRA_MOUNTS` at
`/workspace/<basename>`, and the personal vault at `/workspace/vault`. The positional
argument may also be `@<repo>` to use a registered repo volume as the working directory
(fast on macOS) — see [Shared repo volumes](repos-and-mounts.md#shared-repo-volumes-native-speed--reposh-and-repos).
Agent outputs (`.agent-blocked/`, `.agent-discovery/`) are written to the host directory
where you launched `sandbox.sh` (and are git- and docker-ignored).

---

[← Documentation index](README.md)
