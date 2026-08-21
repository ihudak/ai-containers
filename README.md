# AI Sandbox Container Assets

A CLI-only, Docker-based workspace for running AI coding agents — GitHub Copilot CLI, Claude Code, Codex, Gemini, Kiro — inside an isolated container with **deny-by-default outbound networking** and a non-root agent shell.

The agent gets your code and the network you explicitly allowed. Nothing else.

## Quick start

```bash
./build.sh                 # reads sandbox.conf, assembles the allowlists, builds the image
./sandbox.sh restricted    # run with the firewall on (the normal mode)
```

Edit **`sandbox.conf`** first to choose what goes in the image — languages, CLIs, database clients, and so on. Every key is listed in [Components](docs/components/README.md).

In a consumer project you normally start it through the generated `runme.sh` launcher instead. See [Managing multiple projects](docs/multiple-projects.md).

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
| [Managing multiple projects](docs/multiple-projects.md) | Rolling a change out to every project |
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
