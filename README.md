# AI Sandbox Container Assets

A CLI-only, Docker-based workspace for running AI coding agents — GitHub Copilot CLI, Claude Code, Codex, Gemini, Kiro — inside an isolated container with **deny-by-default outbound networking** and a non-root agent shell.

The agent gets your code and the network you explicitly allowed. Nothing else.

## Quick start

You do not run this repository directly. You point it at a project once, and from then on the project has its own launcher.

**1. Set the project up — once, from here:**

```bash
./project-init.sh /path/to/myproject
```

It asks for the image name, container group, CPU and memory, and any extra mounts; copies the infrastructure into `<project>/.ai-containers/`; registers the project; and generates the launcher.

**2. Choose what goes in the image — in the project:**

```bash
$EDITOR /path/to/myproject/.ai-containers/sandbox.conf
```

Languages, CLIs, database clients and tools. Every key is in [Components](docs/components/README.md). Optional, and skippable on a first run — the defaults work.

**3. Launch it — from the project, every time after that:**

```bash
cd /path/to/myproject/.ai-containers
./runme.sh
```

`runme.sh` builds the image if it needs to and starts the container, using the network mode and working directory recorded in `sandbox.env`. It is the only command you need day to day; after changing `sandbox.conf`, just run it again.

**Later, to pick up changes to this repository:**

```bash
./sync-to-projects.sh          # from here — updates every registered project
```

Two things worth knowing before you settle in. [Container groups](docs/groups.md) keep one project's credentials and agent config separate from another's. And **on macOS, put large repositories in a [repo volume](docs/repos-and-mounts.md)** rather than a bind mount — host directories reach Docker's Linux VM over a network filesystem, which is slow enough for a big repo to sour the whole experience. On Linux, bind mounts are already native speed and there is nothing to do.

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
