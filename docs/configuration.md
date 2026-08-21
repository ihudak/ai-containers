# Environment variables

These configure `sandbox.sh` at launch time. Set any of them **inline** for a single run
(`VAULT_PATH=/path ./sandbox.sh restricted`) or **export them in your host shell profile**
(`~/.bash_profile`, `~/.zshrc`) so they become the default for every container you start.
`VAULT_PATH`, `SPECS_PATH`, and `DOCS_PATH` are designed for the profile-export pattern: point them once at
host directories and every container mounts them and sees the variable re-exported to its
in-container path. Their effective default is therefore whatever the host environment exports;
override either inline to point at a different directory for a single run. If the variable is
unset the mount is simply skipped, and if it points at a directory that does not exist `sandbox.sh`
warns and skips it.

The **In container** column says whether the variable is visible to the agents *inside* the
container:

- **forwarded** — passed through unchanged (`-e VAR=$VAR`).
- **→ `/path`** — re-exported pointing at the in-container mount path (a host-directory pointer).
- **mount** — attaches a filesystem mount; not exposed as an environment variable inside.
- **—** — configures the launcher / `docker run` only; not visible inside the container.

| Variable | Purpose | Default | In container |
|---|---|---|---|
| `IMAGE_NAME` | Image tag to run. Persisted per project in `.ai-containers/sandbox.env`. | `ai-sandbox` | forwarded |
| `AI_CONTAINER_GROUP` | Which dotfile tree (group) to mount: `default`, `host` (mounts `$HOME`), or a custom `~/.ai-containers/<name>/`. | `default` | — |
| `AI_CONTAINER_GROUP_INIT` | Non-interactive first-time group bootstrap: `clean` \| `from:host` \| `from:<name>`. | interactive prompt | — |
| `SANDBOX_MODE` | Default network mode for a bare `./sandbox.sh` (`open` \| `discovery` \| `restricted`). Set in `sandbox.env`; a positional arg or inline env wins. | `open` (via `sandbox.env`) | — |
| `SANDBOX_WORKDIR` | Default primary working dir for a bare `./sandbox.sh` (`..`, a host path, or `@repo`). Set in `sandbox.env`; override per-machine in `sandbox.local.env`. | `..` (via `sandbox.env`) | — |
| `AI_CONTAINER_HOST_ACK` | Set `1` to skip the macOS `host`-group acknowledgement. Ignored on Linux. | `0` | — |
| `SANDBOX_UID` / `SANDBOX_GID` / `SANDBOX_USER` / `SANDBOX_GROUP` | Override the container user identity. | detected from host (`id`) | forwarded |
| `REPOS` | Space-separated **registered** repo volumes to attach under `/workspace/<name>`; append `:ro` (default), `:rw`, or `:rwcopy`. Register first with `./repo.sh add`. | none | mount |
| `REPO_BACKEND` | How a repo is backed: `auto` \| `volume` \| `bind` (chosen at `repo.sh add` time). | `auto` | — |
| `EXTRA_MOUNTS` | Space-separated extra host directories bind-mounted under `/workspace/<basename>`; append `:ro`/`:rw`. | none | mount |
| `VAULT_PATH` | Host directory mounted read-write at `/workspace/vault` — your **personal** knowledge base (an Obsidian vault is typical, but any markdown corpus works, e.g. imported Jira tickets under `$VAULT_PATH/jira-products`, read heavily by several workflows). Pair with `qmd=ON` for in-container search. | host `$VAULT_PATH` export | → `/workspace/vault` |
| `SPECS_PATH` | Host repo of AI-ready specifications, design documents, and development plans — the **team/shared** knowledge base — mounted read-write at `/workspace/specs`. Consumed by spec-driven workflows (e.g. the dev-workflows plugin). Accepts `@<name>` for a registered repo volume (mounted at `/workspace/<name>`; fast on macOS). | host `$SPECS_PATH` export | → `/workspace/specs` |
| `DOCS_PATH` | Host **product-documentation** repo mounted **read-only** by default at `/workspace/docs`, re-exported as `DOCS_PATH=/workspace/docs`. Grounding for plugin workflows (idea / VI / release-notes). Accepts `@<name>` (→ `/workspace/<name>`) and a `:ro`/`:rw` suffix (default `:ro`). When the docs repo is the working dir, `DOCS_PATH` re-points to that writable mount; to edit docs otherwise use `:rw`. | host `$DOCS_PATH` export | → `/workspace/docs` |
| `PREVIEW_PORTS` | Space-separated ports (or `host:container` pairs) to publish for dev servers. | none | — |
| `CONTAINER_CPUS` | CPU limit. | `1.0` | — |
| `CONTAINER_MEMORY` | Hard memory limit. | `4g` | — |
| `CONTAINER_MEMORY_RESERVATION` | Soft memory limit (must be ≤ `CONTAINER_MEMORY`). | `2g` | — |
| `CONTAINER_MEMORY_SWAP` | Memory + swap total (≥ `CONTAINER_MEMORY`; set equal to disable swap, `-1` for unlimited). | `4g` | — |
| `CONTAINER_NOFILE` | Open-file-descriptor limit, `soft[:hard]`. | `1048576:1048576` | — |
| `SELF_HEALING_ENABLED` | Set `0` to disable reactive IP auto-allowing (logging only). | `1` | forwarded |
| `ALLOW_IPV6_BYPASS` | Set `1` to suppress the `ip6tables`-unavailable warning (WSL2/nf_tables). | `0` | forwarded |
| `COPILOT_GITHUB_TOKEN` | Copilot CLI auth token; bypasses device-flow OAuth. Auto-extracted from the group's `gh` `hosts.yml` when unset. | auto from `gh` | forwarded |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | Forwarded as-is for tools expecting this exact name (github MCP servers, Claude Code github plugin). | none | forwarded |
| `SANDBOX_ENV_FILE` | Path to a `KEY=VALUE` env-file injected into the container via `docker run --env-file` — for non-secret in-container **application** env (e.g. `DB_HOST`, `REDIS_URL`), not credentials. | `<project>/.ai-containers/container.env` if present, else unset | — |

See [Mounting an Obsidian vault](repos-and-mounts.md#mounting-an-obsidian-vault),
[Mounting a specs repository](repos-and-mounts.md#mounting-a-specs-repository),
[Mounting additional repositories](repos-and-mounts.md#mounting-additional-repositories), and
[Resource limits](resources.md) for the longer treatments.

---

[← Documentation index](README.md)
