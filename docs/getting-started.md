# Getting started

## Requirements

- **Docker ≥ 23** with BuildKit (default since Docker 23) and `docker buildx`. Verify with `docker --version` and `docker buildx version`.

  | Platform | Recommended runtime | Notes |
  |----------|---------------------|-------|
  | **Linux** | [Docker Engine](https://docs.docker.com/engine/install/) | Socket at `/var/run/docker.sock` by default. |
  | **macOS** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) or [Colima](https://github.com/abiosoft/colima) | See macOS note below. |
  | **Windows** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) + WSL2 backend | Run the scripts from inside a WSL2 shell. |

  **macOS with Colima:** Colima is a lightweight, open-source alternative to Docker Desktop. Install it with Homebrew, then follow these one-time setup steps:

  ```bash
  brew install colima docker docker-buildx
  ```

  1. **Start Colima before building or running containers.** Size the VM to fit the image you intend to build and the container resources you plan to use (see [Resource limits](resources.md)):
     ```bash
     colima start --cpu 4 --memory 8 --disk 100
     ```
     Check status at any time with `colima status`.

  2. **Set `DOCKER_HOST` to point to Colima's socket.** Colima places its socket at `~/.colima/default/docker.sock`, not `/var/run/docker.sock`. Without this, every `docker` command fails with `dial unix /var/run/docker.sock: connect: no such file or directory`. Add to your shell profile (`~/.zshrc` or `~/.bashrc`) and reload:
     ```bash
     export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
     ```

  3. **Register buildx as the default builder** (suppresses the legacy-builder deprecation warning and is required for BuildKit secrets used by `./build.sh`):
     ```bash
     docker buildx install
     ```
- **Bash ≥ 5.1** on the host (for `sandbox.sh`). Linux distributions from Ubuntu 22.04 / Debian 11 / RHEL 9 onward ship this. macOS ships bash 3.2 — install a newer one via `brew install bash`.

## Before you initialise

`project-init.sh` asks questions, and two of them are much easier to answer if you have already decided. Ten minutes here saves you from tearing a working setup apart later.

### Decide which container group to use

A **container group** is a named directory under `~/.ai-containers/<name>/` holding the agent's credentials, skills, MCP config and SSH keys. Everything a project uses is scoped to its group, so two projects in different groups cannot see each other's logins.

`project-init.sh` will ask you for one. **`default` is a fine answer** — you can move a project to another group later by editing `AI_CONTAINER_GROUP` in `sandbox.env`. Answer with something else when you want a project's credentials kept separate: a `docs` group with wiki access, a `work` group with corporate logins.

The first container start in a new group is empty — you log the agents in once, and that group keeps them. [Container groups](groups.md) covers bootstrapping a group from an existing one or from your `$HOME`.

### Decide what the container should see besides your code

Your project directory is mounted for you. Anything **else** the agent should reach is named by a path variable:

| Variable | What it mounts |
|---|---|
| `VAULT_PATH` | An Obsidian vault at `/obsidian` (set `qmd=ON` if you want search over it) |
| `DOCS_PATH` | A docs repository, read-only by default |
| `SPECS_PATH` | A specs repository |
| `EXTRA_MOUNTS` | Any other host paths, space-separated, `:ro` for read-only |

**Set them once in your shell profile.** A vault, a docs repo and a specs repo are usually one per *person*, not one per project — so exporting them from `~/.bashrc`, `~/.zshrc` or `~/.profile` means every project you ever initialise picks them up with nothing further to do:

```bash
# ~/.zshrc or ~/.bashrc
export VAULT_PATH="$HOME/obsidian/my-vault"
export DOCS_PATH="$HOME/dev/docs"
export SPECS_PATH="$HOME/dev/specs"
```

Do this **before** you initialise, and the first container start already has them.

**Or per project**, in `sandbox.local.env` inside the project's `.ai-containers/` — machine-specific and gitignored — when one project needs a different path from the rest.

> **If you use both, the exported one wins.** `sandbox.env` and `sandbox.local.env` set a variable only when it is not already set, so a value exported from your profile beats both files. That is what makes the profile approach reliable — and it means a per-project override in `sandbox.local.env` will *not* take effect while your profile exports the same name. Unset it for that shell, or pass the value inline: `VAULT_PATH=/other ./runme.sh`.

`project-init.sh` prompts for **extra mounts** directly, so have those paths ready. It does *not* ask about the vault, docs or specs paths — those come from your profile or `sandbox.local.env`. See [Environment variables](configuration.md) and [Repositories, volumes and mounts](repos-and-mounts.md).

### On macOS, seed repo volumes now — not after the first run

**Skip this on Linux**, where host bind mounts are already native speed.

On macOS, Docker runs inside a Linux VM and host directories reach it over a network filesystem. For a large repository an agent scans repeatedly — greps, builds, test runs — that is slow enough to change how the product feels, and it is the most common reason a first macOS experience is a bad one.

Do it **before** you initialise, for two reasons: repo volumes are global and need neither the project nor the sandbox image to exist, and — the one that bites people — **a repository you attach as a volume must not also be listed in `EXTRA_MOUNTS`.** Both mount at `/workspace/<name>`, and `sandbox.sh` refuses to start when a name appears in both. Deciding after you have already answered the extra-mounts prompt means going back and undoing that answer.

Seed each repo once, from a checkout you already have:

```bash
./repo.sh add app ~/dev/app                            # from a local checkout — fast, no network
./repo.sh add lib ssh://git@example.org/team/lib.git   # or clone from the remote
```

You will attach them after init, in `sandbox.local.env`:

```bash
REPOS=app:rw lib:ro
SANDBOX_WORKDIR=@app
```

`:rw` for the repo you are editing, `:ro` for reference repos, `@app` to make that volume the working directory. Refresh them whenever you like — `./repo.sh sync --all` updates every registered repo in one command.

**The trade-off, stated plainly:** a repo volume is not synced with your host checkout. It holds what you seeded, and you commit and push from inside the container to get work out. That is what buys the speed. [Repositories, volumes and mounts](repos-and-mounts.md) covers `:rwcopy`, `repo.sh list`/`gc`, and the per-platform backend.

## Setting up your first project

You do not work in this repository. You initialise a project once, and the project gets its own launcher.

### 1. Initialise the project — from this repository

```bash
./project-init.sh /path/to/myproject
# optional second argument overrides the project name used for the image
./project-init.sh /path/to/myproject my-custom-name
```

It prompts for the image name, the container group, CPU and memory limits, and extra mounts — the decisions from the previous section. Then it copies the infrastructure into `<project>/.ai-containers/`, registers the project in `projects.conf`, and writes the launcher. [Managing projects](multiple-projects.md) covers everything it generates, and why the config is split into a portable `sandbox.env` and a machine-local `sandbox.local.env`.

### 2. Finish the configuration

```bash
cd /path/to/myproject/.ai-containers
$EDITOR sandbox.conf        # which languages, CLIs and tools go in the image
$EDITOR sandbox.local.env   # VAULT_PATH / DOCS_PATH / SPECS_PATH, and REPOS if you seeded volumes
```

Every `sandbox.conf` key is documented in [Components](components/README.md). Both files are optional on a first run — the defaults give you Node, Python, git and the agent CLIs, which is enough to start.

### 3. Launch

```bash
./runme.sh
```

`runme.sh` is the only command you need day to day. It resolves a build-time `GITHUB_TOKEN` from `gh` if you have one, builds the image when it needs to, and starts the container in the mode recorded in `sandbox.env`. **After changing `sandbox.conf`, run it again** — it rebuilds.

### Keeping projects up to date

When this repository changes, push the update into every registered project:

```bash
./sync-to-projects.sh              # all registered projects
./sync-to-projects.sh /path/to/p   # just one
```

## Running the scripts directly

`runme.sh` calls `build.sh` and then `sandbox.sh`. You normally never call them yourself — but they are ordinary scripts, and when you are working on this repository, or debugging a build, they are the ones to reach for.

```bash
./build.sh                 # read sandbox.conf, assemble the allowlists, build the image
./sandbox.sh restricted    # run the container with the firewall on
```

`build.sh` assembles the three `allowlist-*.txt` files from the matching fragments in `allowlist-*.d/` and passes a `--build-arg` for each component to `docker build`. The generated `allowlist-*.txt` files are gitignored; the `*.d/` fragment directories are the source of truth.

Docker cannot detect that a remote file fetched with `curl` has changed, so to pick up newer CLI tool versions force a full rebuild:

```bash
./build.sh --no-cache
NO_CACHE=1 ./build.sh
```


---

[← Documentation index](README.md)
