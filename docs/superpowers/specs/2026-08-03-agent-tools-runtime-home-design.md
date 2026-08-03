# Agent-tier Tools → Runtime Group-Mounted Home; Retire `AGENTS_CACHE_BUST`

_Design spec — 2026-08-03_

## Goal

Move six agent-tier tools — **Claude Code, Codex, Gemini, Copilot, graphify, Vale** —
out of the baked image into a per-group, user-writable home that is installed at
container start and persists across runs, so they update in place (via each tool's
own mechanism) and those updates stick per container group. Then **retire the entire
`AGENTS_CACHE_BUST` apparatus**. Kiro and the `tools.d` tools (dtctl / dtmgd / acli)
stay baked; they refresh via a full `./build.sh --no-cache` rebuild.

This reuses the `~/.rvm` primitive shipped in the rvm-home-in-group work: a
group-mounted, user-owned tool home plus a runtime reconcile run as the sandbox user.

## Background & Motivation

Today every agent CLI is installed at **build time** as root via `npm install -g`
(Copilot, Claude Code, Codex, Gemini), `uv tool install` (graphify), or `curl | tar`
(Vale), into root-owned locations under the image. Because those layers are cached by
Docker and the CLIs are installed **unpinned**, a normal `./build.sh` never picks up
newer versions. The `AGENTS_CACHE_BUST` build-arg exists to force a fast targeted
rebuild of just those layers, backed by a large apparatus:

- `ARG AGENTS_CACHE_BUST=0` at `Dockerfile:391`, referenced in the first agent layer,
  so it busts every layer below it.
- Token **persistence** in `.agents-cache-bust` (gitignored, per project), with
  read/write helpers in `sandbox-common.sh` and self-heal semantics in `build.sh`.
- A **staleness check** in `sandbox.sh` (`AGENT_REBUILD_MAX_AGE_HOURS`, default 72)
  that offers/an auto-rebuild when the image is old.
- Supporting tests (`test-agents-cache-bust.sh`, `test-image-staleness.sh`) and doc
  sections across README / AGENTS / CHANGELOG.

A non-root sandbox user cannot `npm i -g` at runtime because the nvm Node global dir
is root-owned, which is why the refresh must go through a rebuild at all. Moving the
agent-tier tools into a **user-writable, group-mounted** home removes that constraint:
the tools install once per group at first boot, persist, and self-update in place — no
rebuild, no cache-bust token, no staleness prompt.

The `AGENTS_CACHE_BUST` marker currently also gates Kiro, graphify, `tools.d`, and
Vale (every layer sits below it). After this change, graphify and Vale move to runtime,
so the only baked-and-unpinned residents left below the (removed) marker are **Kiro**
and **`tools.d` tools set to `latest`/`ON`**. Per the decision recorded during
brainstorming, those refresh via a full `--no-cache` rebuild; `tools.d` tools can also
be pinned (`dtctl=0.25.0`) to avoid needing a refresh at all.

## Non-Goals

- **Kiro is not moved.** Its custom `curl | bash` installer plus arch-specific `bun`
  binary make a runtime relocation high-risk and low-payoff. It stays baked.
- **`tools.d` (dtctl / dtmgd / acli) are not moved.** Some are `private=yes` and would
  need `GITHUB_TOKEN` plumbed to runtime; they are also pinnable. They stay baked.
- **No time-gated or every-boot auto-update.** The reconcile is stateless
  install-if-missing (see Update Policy). We are retiring a time-gated refresh; we do
  not reintroduce one.
- **No new pinning of the moved tools.** They remain unpinned (latest at install time),
  matching today's behaviour.

## Move Set & Rationale

| Tool | Baked install today | Runtime install | Verdict |
|---|---|---|---|
| Claude Code | `npm i -g @anthropic-ai/claude-code` | npm into group prefix | Move |
| Codex | `npm i -g @openai/codex` | npm into group prefix | Move |
| Gemini | `npm i -g @google/gemini-cli` | npm into group prefix | Move |
| Copilot | `npm i -g @github/copilot` | npm into group prefix | Move |
| graphify | `uv tool install graphifyy` | uv into group tool dir | Move |
| Vale | `curl | tar` GitHub release | curl+tar into group bin | Move |
| Kiro | `curl cli.kiro.dev/install \| bash` | — | **Stay baked** |
| tools.d | release/repo-file/url via `install-tools.sh` | — | **Stay baked** |

## Architecture

### 1. Tool-home layout — `~/.ai-tools/`

A single dedicated, group-mounted tree, chosen over wholesale-mounting `~/.local`
(which already carries independent sub-mounts such as `~/.local/share/kiro-cli`, per
`entrypoint.sh` `setup_sandbox_user`). Structure inside the sandbox user's home:

```
~/.ai-tools/
  npm/            # npm global prefix  (bin: ~/.ai-tools/npm/bin)
  uv/             # UV_TOOL_DIR         (bin: ~/.ai-tools/uv/bin via UV_TOOL_BIN_DIR)
  bin/            # single downloaded binaries (vale)
```

- **npm prefix** is set by a baked `/etc/skel/.npmrc` containing
  `prefix=${HOME}/.ai-tools/npm`. Every sandbox user inherits it via skel.
- **PATH** gains `~/.ai-tools/npm/bin`, `~/.ai-tools/uv/bin`, and `~/.ai-tools/bin`
  through a baked `/etc/profile.d/ai-tools.sh` (login + interactive shells), mirroring
  the existing `/etc/profile.d/rvm.sh`.
- **Claude Code's expected native path** `~/.local/bin/claude` is provided as a symlink
  into `~/.ai-tools/npm/bin/claude`, created by the reconcile when Claude Code is
  installed (replacing today's skel symlink into the nvm global).

Node, npm, and uv remain **baked toolchain** on the global PATH; only the tool packages
move. (Precondition to verify during planning: `node`/`npm`/`uv` are resolvable on the
global PATH for a non-login shell run as the sandbox user.)

### 2. Runtime reconcile — `agent-tools-reconcile.sh`

A new script shipped to `/usr/local/bin/agent-tools-reconcile.sh`, modelled on
`rvm-reconcile.sh`:

- **Invocation:** by `entrypoint.sh` as the sandbox user, in all three modes, in the
  same slot as `run_ruby_reconcile` / `run_agent_skill_install` (after the restricted
  firewall is applied, before the `capsh` cap-drop `exec`). Non-fatal (`|| true`) —
  never blocks container start.
- **Input:** a comma-separated `AI_RUNTIME_TOOLS` env (see Enablement Contract) listing
  which of the six tools are ON.
- **Behaviour per tool:** a small dispatch table maps each key to its install method
  and package coordinate:

  | key | method | coordinate |
  |---|---|---|
  | `claude-code` | npm | `@anthropic-ai/claude-code` |
  | `copilot` | npm | `@github/copilot` |
  | `codex` | npm | `@openai/codex` |
  | `gemini` | npm | `@google/gemini-cli` |
  | `graphify` | uv | `graphifyy` |
  | `vale` | binary | `github.com/vale-cli/vale` release, `vale_<ver>_Linux_<arch>.tar.gz` |

  For each enabled tool the reconcile **installs only if the binary is absent** from
  the group home (`command -v` / prefix check). Present → skip. Environment for the
  installs: npm uses the baked `.npmrc` prefix; uv is invoked with
  `UV_TOOL_DIR=~/.ai-tools/uv UV_TOOL_BIN_DIR=~/.ai-tools/uv/bin`; Vale is fetched with
  the same `releases/latest` redirect approach used in the Dockerfile today.
- **Concurrency:** the whole reconcile body is guarded by an `flock` on a lock file in
  the group home (a group can back several concurrent containers), exactly as
  `rvm-reconcile.sh` does.
- **Robustness:** offline-tolerant (a failed download logs and continues to the next
  tool; a tool that fails to install is simply absent, not fatal). Not `set -u`-
  dependent on tool internals. `kiro` never appears in `AI_RUNTIME_TOOLS`, so the
  reconcile never attempts to install it.

### 3. Non-interactive PATH linker

A root-run step after the reconcile symlinks the installed tool binaries
(`claude`, `codex`, `gemini`, `copilot`, `graphify`, `vale`) from the group home onto
`/usr/local/bin`, so `docker exec -T <ctr> bash -c "…"` (a non-login, non-interactive
shell that does not source profile.d) resolves them. This directly mirrors
`link-default-ruby.sh`:

- New `link-agent-tools.sh`, shipped to `/usr/local/bin`, invoked by `entrypoint.sh`
  as **root** after `agent-tools-reconcile`, in all three modes. `set -o pipefail`
  (not `-u`). Takes `dev_home="${1:-$HOME}"` and an optional `bin_dest="${2:-/usr/local/bin}"`
  (the `$2` override exists only for testing).
- For each of the six tool binaries, if an executable exists under the group home
  (`~/.ai-tools/npm/bin`, `~/.ai-tools/uv/bin`, or `~/.ai-tools/bin`), `ln -sf` it onto
  `$bin_dest`. Only links what exists; logs which were linked. Non-fatal.

### 4. Enablement contract — `AI_RUNTIME_TOOLS`

`AI_AGENTS_ENABLED` (from `enabled_agents_csv()`, which enumerates
`claude-code copilot codex gemini kiro`) stays as-is for `install-agent-skills.sh`.
The reconcile needs a **distinct** list — it must include graphify/vale and must
exclude kiro. Introduce:

- A new helper `runtime_tools_csv()` in `sandbox-common.sh` that iterates
  `claude-code copilot codex gemini graphify vale` and emits the ON ones as CSV
  (using the existing `is_enabled`).
- `sandbox.sh` passes `-e AI_RUNTIME_TOOLS="$(runtime_tools_csv)"` alongside the
  existing `-e AI_AGENTS_ENABLED=…` at the docker-run assembly (`sandbox.sh:865`).
- `entrypoint.sh`'s reconcile wrapper forwards `AI_RUNTIME_TOOLS` to the script (as it
  forwards `AI_AGENTS_ENABLED` to `install-agent-skills.sh`).

The six sandbox.conf keys (`claude-code=`, `copilot=`, `codex=`, `gemini=`,
`graphify=`, `vale=`) keep their `ON | OFF` grammar; only their **effect** changes from
"install at build" to "install at runtime". No keys are added, removed, or renamed.

### 5. Group-mount wiring

`sandbox.sh` already stages and mounts `~/.rvm` from the group
(`install -d "$group_root/.rvm"` + `add_mount_if_exists … "$dev_home/.rvm"`, ~`:751`).
Add the analogous block for the tool home: `install -d "$group_root/ai-tools"` and
`add_mount_if_exists config_mount_flags "$group_root/ai-tools" "$dev_home/.ai-tools"`.
One mount, created lazily like `.rvm`.

### 6. Dockerfile changes

- **Remove** the six baked install layers: Copilot (`:392-394`), Claude Code
  (`:405-413`), Codex (`:415-416`), Gemini (`:418-419`), graphify (`:466-471`), Vale
  (`:224-234`).
- **Remove** `ARG AGENTS_CACHE_BUST=0` and its marker echo line (`:391-393`).
- **Bake scaffolding** into `/etc/skel`: `.npmrc` (`prefix=${HOME}/.ai-tools/npm`), the
  `~/.local/bin` dir (for the Claude symlink), and `/etc/profile.d/ai-tools.sh` (PATH).
- **COPY** the two new scripts (`agent-tools-reconcile.sh`, `link-agent-tools.sh`) to
  `/usr/local/bin` and `chmod +x`, next to the rvm scripts.
- **Keep** node/nvm, uv, curl, tar (prerequisites) and the Kiro + `tools.d` layers. With
  the marker gone, those layers cache normally and refresh on `--no-cache`.
- **`build.sh` key→build-arg mapping (`:177-190`):** drop the six moved tools' entries
  (`copilot:INSTALL_COPILOT`, `claude-code:INSTALL_CLAUDE_CODE`, `codex:INSTALL_CODEX`,
  `gemini:INSTALL_GEMINI`, `graphify:INSTALL_GRAPHIFY`, `vale:INSTALL_VALE`), since those
  build-args no longer exist in the Dockerfile. **Keep** the allowlist wiring for the
  same keys (`include_if_enabled …/github-copilot.txt copilot`, `…/claude-code.txt`,
  etc., and the CIDR/proxy equivalents) — the domain fragments are still needed, now for
  the **runtime** install and the tool's own traffic. Removing a build-arg must not
  remove the tool's allowlist fragment.

### 7. Retire `AGENTS_CACHE_BUST` — deletion inventory

- **Dockerfile:** `ARG AGENTS_CACHE_BUST` + marker (covered in §6).
- **`build.sh`:** the `--build-arg AGENTS_CACHE_BUST=…` pass, `read_agents_cache_bust`
  call, `write_agents_cache_bust` call, and the help text mentioning it (`:29-36`,
  `:318-357`).
- **`sandbox-common.sh`:** `agents_cache_bust_file`, `read_agents_cache_bust`,
  `write_agents_cache_bust` (`:66-104`).
- **`sandbox.sh`:** the staleness check, auto-rebuild prompt, and
  `AGENT_REBUILD_MAX_AGE_HOURS` handling (`:293-350`).
- **`project-init.sh`:** the `.agents-cache-bust` entry in the gitignore pattern list
  (`:298`) and any project `.gitignore` seeding of it.
- **Tests:** delete `test-agents-cache-bust.sh` and `test-image-staleness.sh`; drop the
  `.agents-cache-bust` line from `test-sync-project.sh`'s pinned contract (`:116`,
  `:315`); update `test-project-init.sh` (`:42-47`) and the `test-repo-registry.sh`
  comment (`:25`).
- **Docs:** remove the `AGENTS_CACHE_BUST` / `AGENT_REBUILD_MAX_AGE_HOURS` sections from
  README (`:81-87`, `:180`, `:397` note), AGENTS.md (`:43-53`, `:127-129`, `:230`), and
  add a CHANGELOG breaking entry.

### 8. Allowlist change

Add `pypi.org` and `files.pythonhosted.org` to `allowlist-domains.d/graphify.txt`
(currently only `api.anthropic.com`; PyPI lives only in `pyenv.txt` today). This is the
sole allowlist gap for restricted-mode runtime installs:

- npm agents install from `registry.npmjs.org` — already in `base.txt`.
- Vale installs from `github.com` + `release-assets/objects.githubusercontent.com` —
  already in `base.txt`.
- graphify installs from PyPI — **needs the addition above**.

## Update Policy

**Install-if-missing + self-update.** The boot reconcile installs a tool only when it
is absent from the group home; keeping current is each tool's own responsibility
(`/update`, `npm update -g`, `uv tool upgrade`, `vale`'s own updater). Rationale: keeps
the reconcile stateless (no timestamps, no threshold env), preserves offline tolerance
and fast boots, and is consistent with retiring the time-gated staleness apparatus
rather than re-creating it at runtime. First boot of a fresh group installs latest
(network required, same tradeoff as the rvm first-boot Ruby compile).

## Error Handling & Edge Cases

- **Offline / registry unreachable at first boot:** each tool's install failure logs
  and is skipped; the container still starts. The tool is simply unavailable until a
  later boot with connectivity. Non-fatal, matching rvm.
- **Concurrent containers on one group:** `flock` serialises the reconcile; a
  second container either waits or sees the tools already present and skips.
- **Restricted mode:** installs run after the firewall is up; the required source
  domains are in the allowlist (§8), included whenever the tool is enabled.
- **`node`/`uv` not on PATH for the reconcile:** treated as a precondition; if a tool's
  installer command is missing, that tool logs a skip rather than aborting the reconcile.
- **Stale `/usr/local/bin` symlinks:** `link-agent-tools.sh` uses `ln -sf` and only
  links binaries that currently exist, so a group whose tools were removed simply
  re-points or leaves dangling links unreplaced; a follow-up boot re-links after
  reinstall. (Acceptable; dangling links resolve on next successful install.)
- **Kiro exclusion:** enforced by `runtime_tools_csv()` omitting kiro, so the reconcile
  never attempts an npm/uv/binary install for it.

## Testing Strategy

- **New `test-agent-tools-reconcile.sh`** (stub-based, following
  `test-rvm-reconcile.sh`): fake `npm`/`uv`/`curl` on PATH. Assertions: installs each
  enabled tool once; skips when already present (idempotent); only installs the tools
  in `AI_RUNTIME_TOOLS`; never touches kiro; offline/failed install is non-fatal and
  isolated; `flock` guard present; correct dispatch (npm vs uv vs binary) per key.
- **New `test-link-agent-tools.sh`** (mirrors `test-ruby-wrapper.sh`): links only
  existing binaries onto the `$2` bin dest; no-op when the tool home is empty; no
  `set -u`; entrypoint wiring present in all three modes.
- **`runtime_tools_csv()` unit coverage** in the sandbox-common test (ON/OFF filtering;
  kiro excluded; graphify/vale included).
- **Delete** `test-agents-cache-bust.sh` and `test-image-staleness.sh`.
- **Update** `test-sync-project.sh` (pinned shared-file contract gains the two new
  scripts, loses `.agents-cache-bust`), `test-project-init.sh`, and the allowlist test
  for the graphify PyPI domains.
- **Real-container smoke test** (folding in the deferral noted from the rvm work, since
  this is an image-touching change): build the image with a couple of tools enabled,
  run a container against a scratch group, assert the tools install into `~/.ai-tools`,
  persist to a second run (no reinstall), and resolve under `docker exec` (non-login).
  Gated so the default `tests/run-all.sh` stays fast; documented in the plan.

## Rollout / Migration

- **sandbox.conf schema:** no key added/removed/renamed, so **no schema bump or
  migration** is required (confirm during planning against the schema-migration
  mechanism in `docs/superpowers/specs/2026-07-24-sandbox-conf-schema-migrations-design.md`).
- **Existing groups:** on first boot after the new image, the reconcile populates
  `~/.ai-tools` in the group; nothing to migrate from the old baked locations.
- **fip re-sync:** after this lands centrally, re-sync fip's tracked `.ai-containers/`
  via `sync-to-projects.sh` so the two new shared scripts propagate (BACKLOG §5).
- **Refresh of remaining baked tools:** documented as `./build.sh --no-cache` for Kiro
  and `tools.d` (or pin `tools.d` versions).

## Risks & Mitigations

- **First-boot latency / network dependency** for a fresh group — inherent to the
  model; mitigated by persistence (paid once per group) and offline-tolerant skips.
- **Node/npm reachability for a non-login reconcile** — verify the global PATH exposes
  `node`/`npm`/`uv` for the sandbox user during planning; if not, add a minimal PATH
  shim analogous to the rvm profile.d line.
- **Dangling `/usr/local/bin` symlinks** after a tool is disabled — cosmetic; resolved
  on next successful install. Optionally prune in `link-agent-tools.sh` if cheap.
- **Behavioural-only tests** (stubs) not catching a real install regression — mitigated
  by the gated real-container smoke test.

## Phases (single plan, coupled)

1. **Phase 1 — Move tools to runtime:** tool-home scaffolding (skel `.npmrc`,
   profile.d, group mount), `agent-tools-reconcile.sh`, `link-agent-tools.sh`,
   `runtime_tools_csv()` + `AI_RUNTIME_TOOLS` wiring, remove the six baked install
   layers, graphify PyPI allowlist, tests. Deliverable: enabled tools install at
   runtime into the group home and resolve interactively and via `docker exec`.
2. **Phase 2 — Retire `AGENTS_CACHE_BUST`:** delete the marker + all machinery per the
   §7 inventory, delete the two tests, update the pinned contract and docs. Safe only
   after Phase 1, because the marker's agent customers are gone. Deliverable: no
   `AGENTS_CACHE_BUST` / `AGENT_REBUILD_MAX_AGE_HOURS` anywhere; remaining baked tools
   documented as `--no-cache` refresh.
