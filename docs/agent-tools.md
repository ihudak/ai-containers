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

Mirroring [Ruby (via rvm)](components/ruby.md): nothing agent-tier is baked into the image. Codex CLI, Gemini CLI, Copilot CLI, `graphify`, and `vale` install at **container start** into a per-user `~/.ai-tools` home (npm prefix `~/.ai-tools/npm`, `graphify`'s `uv` tool dir `~/.ai-tools/uv`, `vale`'s binary in `~/.ai-tools/bin`); **Claude Code** installs the same way but through its own **native** installer, into `~/.local/share/claude`. All of them are mounted from the active container **group** — the same mechanism as `~/.claude`/`~/.codex`/`~/.gemini` (see [Host configuration mounts](repos-and-mounts.md#host-configuration-mounts)) — so the install is shared by every project using that group and survives container restarts and rebuilds.

`agent-tools-reconcile.sh` (running as the sandbox user at container start, `flock`-guarded against concurrent same-group container starts) installs whichever enabled tools are missing. Because the install lives in a user-writable directory instead of a root-owned, read-only image layer, a tool can be brought up to date in place, with no rebuild — but **whether a tool can update itself is per-tool, and each row below was established by running it in a container**, not inferred from how it was installed:

| tool | keeps itself current? | how it is updated |
| --- | --- | --- |
| Claude Code | **yes** — native installer, no npm involved | `claude update`, or automatically |
| Copilot CLI | **yes** — downloads its own GitHub release | automatic; `copilot update` to force |
| Codex CLI | no — its `update` shells out to a bare `npm install -g` and fails `EACCES` | the reconcile re-installs it **on every container start** |
| Gemini CLI | no — ships no update mechanism at all | the reconcile re-installs it **on every container start** |
| `graphify` | yes | `uv tool upgrade graphify` |
| `vale` | no self-update | delete `~/.ai-tools/bin/vale` and restart the container |

Updating Codex and Gemini on every start costs about **7 s** with a warm npm cache (~24 s cold), measured in-container.

**Why Claude Code is the odd one out.** Installed through npm it hits the same wall Codex still does: its self-updater runs a bare `npm install -g`, and the image deliberately sets **no** global npm prefix anywhere — a `prefix=` line in any npmrc (user, project, **or node's builtin**, all of which nvm inspects) makes nvm's `nvm_die_on_prefix` check **fail** `nvm use <version>` outright rather than warn, which would break the multi-version `node=22,20` workflow `sandbox.conf` advertises. With no prefix configured, `npm prefix -g` resolves to nvm's own root-owned node directory, so the update aborts with *no write permission to npm prefix* instead of landing in `~/.ai-tools/npm`. Restoring the prefix is not a fix: nvm's own suggested escape hatch, `nvm use --delete-prefix`, silently deletes it again at runtime, so the repair undoes itself per user. The native installer avoids the conflict entirely by never invoking npm — verified in a **restricted-mode** container, where both the install and `claude update` succeed behind the firewall and `nvm use` still passes afterwards.

For the CLIs still installed through npm, `npm-agent-tools update -g` is the manual way through — the reconcile keeps Codex and Gemini current on its own, so you need this only to update them mid-session without restarting the container. It is a shell function baked into `/etc/profile.d/ai-tools.sh` that forwards `--prefix "$HOME/.ai-tools/npm"` to npm, which nvm does not object to because it inspects npmrc files and `$PREFIX`/`$NPM_CONFIG_PREFIX`, never a command's own flags. A bare `npm update -g` is the wrong command: it would update whatever node version nvm currently has active, not the group's tool home. Being a shell function, it is available in login and interactive shells only — a `docker exec -T` one-liner should call `npm --prefix "$HOME/.ai-tools/npm" update -g` directly. `link-agent-tools.sh` then symlinks each installed tool's binary onto `/usr/local/bin` so non-interactive, non-login shells (`docker exec -T <container> bash -c "claude …"`) resolve them too; for Claude Code it prefers the native launcher at `~/.local/bin/claude`.

**Reclaiming the old npm Claude Code.** A group provisioned before the switch still carries the npm copy under `~/.ai-tools/npm`. The reconcile does **not** delete it — other containers in the same group may be running against it — and falls back to it only when no native install is present. Once every container in that group is stopped:

```bash
rm -rf ~/.ai-containers/<group>/.ai-tools/npm/lib/node_modules/@anthropic-ai \
       ~/.ai-containers/<group>/.ai-tools/npm/bin/claude
```

Three modes are available:

- **restricted** — deny-by-default firewall (only allowlisted destinations reachable),
  with a background daemon logging blocked outbound destinations. Drops `NET_ADMIN`
  and `NET_RAW` from the agent shell. The default choice for day-to-day agent use.
- **discovery** — unrestricted egress **with** capture (pcap + DNS/TLS destination
  logging), used to observe what an agent actually reaches before writing a
  restricted allowlist. Names only `NET_ADMIN` in its drop, but the agent shell
  still ends up with no capabilities — capture is done by a root daemon forked
  before the drop, not by the shell (see [Security model](security.md)).
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
