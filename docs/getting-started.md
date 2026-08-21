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

## Setting up your first project

You do not work in this repository. You initialise a project once, and the project gets its own launcher.

### 1. Initialise the project — from this repository

```bash
./project-init.sh /path/to/myproject
# optional second argument overrides the project name used for the image
./project-init.sh /path/to/myproject my-custom-name
```

It prompts for the image name, the [container group](groups.md), CPU and memory limits, and any extra mounts. Then it copies the infrastructure into `<project>/.ai-containers/`, registers the project in `projects.conf`, and writes the launcher. See [Managing projects](multiple-projects.md) for everything it generates and why the config is split into a portable `sandbox.env` and a machine-local `sandbox.local.env`.

### 2. Choose what goes in the image — optional on a first run

```bash
$EDITOR /path/to/myproject/.ai-containers/sandbox.conf
```

Every key is documented in [Components](components/README.md). The defaults give you Node, Python, git and the agent CLIs, which is enough to start.

### 3. Launch

```bash
cd /path/to/myproject/.ai-containers
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
