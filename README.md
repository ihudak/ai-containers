# AI Sandbox Container Assets

A CLI-only, Docker-based workspace for running AI coding agents — GitHub Copilot CLI, Claude Code, Codex, Gemini, Kiro — inside an isolated container with **deny-by-default outbound networking** and a non-root agent shell.

The agent gets your code and the network you explicitly allowed. Nothing else.

## Quick start

You do not run this repository directly. You point it at a project once, and from then on the project has its own launcher.

### First, three decisions

`project-init.sh` asks about two of these, and the third is painful to retrofit — so make them before you start. Details in [Getting started](docs/getting-started.md).

1. **Which [container group](docs/groups.md)?** A named home for the agent's credentials and config, so two projects need not share logins. `default` is a fine answer; init will ask.
2. **What should the container see besides your code?** An Obsidian vault (`VAULT_PATH`), docs (`DOCS_PATH`), specs (`SPECS_PATH`), anything else (`EXTRA_MOUNTS`). Export the first three from `~/.bashrc` or `~/.zshrc` **once** and every project picks them up — they are usually one per person, not per project. Init asks about extra mounts separately.
3. **On macOS with a large repository — seed a [repo volume](docs/repos-and-mounts.md) first.** Host directories reach Docker's Linux VM over a network filesystem, which is slow enough for a big repo to sour the whole experience. Seed it *before* init: a repo attached as a volume must **not** also appear in `EXTRA_MOUNTS`, or the container refuses to start. On Linux, bind mounts are already native speed — nothing to do.

```bash
./repo.sh add app ~/dev/app     # macOS, big repo — do this before init
```

### Then

```bash
# 1. once per project, from here
./project-init.sh /path/to/myproject

# 2. configure it, in the project
cd /path/to/myproject/.ai-containers
$EDITOR sandbox.conf         # languages, CLIs, tools — see docs/components/
$EDITOR sandbox.local.env    # VAULT_PATH / DOCS_PATH / SPECS_PATH, REPOS

# 3. launch it, every time after that
./runme.sh
```

`runme.sh` builds the image when it needs to and starts the container. It is the only command you need day to day; after changing `sandbox.conf`, run it again.

**Later, to pick up changes to this repository:**

```bash
./sync-to-projects.sh          # from here — updates every registered project
```

> `build.sh` and `sandbox.sh` are what `runme.sh` calls. Run them by hand only when you are working on this repository itself, or debugging a build.

## Documentation

**New here? → [Getting started](docs/getting-started.md).**

| | |
|---|---|
| [What is in the box](docs/overview.md) | Which file does what |
| [Components](docs/components/README.md) | Every `sandbox.conf` key, and how to switch things on |
| [Environment variables](docs/configuration.md) | What you can change without rebuilding |
| [Container groups](docs/groups.md) | Keeping one project's credentials apart from another's |
| [Repositories, volumes and mounts](docs/repos-and-mounts.md) | Getting code, vaults, docs and specs into the container |
| [Agent-tier tools](docs/agent-tools.md) | Where the agent CLIs live, and how to update them |
| [Resource limits](docs/resources.md) | CPU and memory per agent |
| [Security model, allowlists and tokens](docs/security.md) | What is blocked, how to allow it, where tokens go |
| [Managing projects](docs/multiple-projects.md) | What `project-init.sh` generates, and keeping projects in sync |
| [Troubleshooting and host notes](docs/troubleshooting.md) | When it does not work, and macOS specifics |

The full index is [docs/README.md](docs/README.md).

## Requirements at a glance

- **Docker ≥ 23** with BuildKit and `docker buildx`
- **Bash ≥ 5.1** on the host — macOS ships 3.2, so `brew install bash`

Full details, including Colima setup on macOS, are in [Getting started](docs/getting-started.md).

## Three network modes

| Mode | Outbound network | Used for |
|---|---|---|
| `restricted` | Deny-by-default, allowlist only | Normal work |
| `discovery` | Open, but every destination is captured | Finding out what a new tool needs |
| `open` | Unrestricted, nothing captured | Escape hatch |

Restricted mode is the point of this project. [Security model](docs/security.md) explains what it does and does not protect against.

## Contributing

`AGENTS.md` is the working agreement for changing this repository — the test suite, the mutation and falsify tiers, and what a change has to satisfy before it lands.
