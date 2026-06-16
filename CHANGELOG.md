# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

## v0.4.0 — 2026-06-16

### Added

- **Vale component.** New optional `vale` flag in `sandbox.conf` (`ON`/`OFF`, default `OFF`) installs the [Vale](https://vale.sh) prose/style linter — a single self-contained Go binary — from GitHub releases (`vale-cli/vale`) at build time. Installed **unpinned** (latest), with the version resolved from the `releases/latest` redirect (no GitHub API token or rate limit). Useful in docs workspaces whose style-check phase otherwise warns that "Vale isn't installed". A new `allowlist-domains.d/vale.txt` fragment (`vale.sh`) is included when `vale=ON`; the binary download and `vale sync` style packages use GitHub hosts already in `base.txt`.

- **Docker volumes are now the source of truth for repo state, via labels.** Each base repo volume is created with `ai-containers.repo`/`.type`/`.source` labels, and each `:rwcopy` working copy with `ai-containers.repo`/`.workcopy`/`.launch-dir`. `repo.sh list` now reads existence and metadata directly from Docker (union of labeled volumes + registry; a registry entry whose volume is gone shows `MISSING`, and a `WC` column counts working copies). The registry (`repos.conf`) is demoted to a cache — authoritative only for Linux `bind`-backend repos (no volume to label) and the mutable last-synced timestamp (Docker labels are immutable after creation).

- **`repo.sh reindex`** — rebuild `repos.conf` from the base-volume labels. Recovers a lost or stale registry, or adopts repos seeded on another machine/checkout. Additive and non-destructive: it inserts/updates volume-backed repos (preserving known added/synced timestamps) and leaves `bind`-backend entries untouched.

- **`repo.sh gc [--repo <name>] [--unused] [--yes]`** — prune `:rwcopy` working-copy volumes. Removes all by default; `--repo` scopes to one repo, `--unused` keeps copies currently mounted by a running container, `--yes` skips confirmation. Working copies can hold uncommitted work, so it confirms before deleting.

- **`repo.sh list --copies`** — list `:rwcopy` working copies with their parent repo, originating launch directory (from the volume label), whether a running container currently mounts them, and (with `--sizes`) on-disk size.

### Changed

- **Repo volumes are now global (image-independent).** The backing Docker volume name dropped its `IMAGE_NAME` prefix and is now `ai-containers-repo-<name>` (working copies: `ai-containers-repo-<name>--wc-<tag>`). Previously it was `<image>-repo-<name>`, so a single (already global) registry entry resolved to a *different* volume in every project — seeding a repo from one project left it "missing" in another, and sharing one volume across projects required matching `IMAGE_NAME` by hand. Now you register a repo **once** with `./repo.sh add` and attach the same volume to any number of containers across any project or container group, with no `IMAGE_NAME` juggling. Set `REPO_VOLUME_PREFIX` to restore the legacy per-image scoping (e.g. `REPO_VOLUME_PREFIX="$IMAGE_NAME"`).

  **Upgrade note:** existing volumes keep their old `<image>-repo-<name>` names and will appear "missing." Recreate each affected repo: `./repo.sh rm <name>` (then `docker volume rm <old-volume>` if it lingers) and `./repo.sh add <name> <source>`, or re-seed in place with `./repo.sh sync <name>` (which creates the new global volume from source).

## v0.3.0 — 2026-06-12

### Breaking

- **`runme.sh` no longer builds.** The entry point was split into three scripts sharing a `sandbox-common.sh` library: `build.sh` (build only), `runme.sh` (run only — `restricted`/`discovery`), and `repo.sh` (repo-volume manager). `runme.sh build` now prints an error pointing to `./build.sh`. Update any scripts, launchers, or habits that called `runme.sh build`. Generated project launchers and `project-init.sh`/`sync-to-projects.sh` were updated to match.

- **`/workspace` is now an umbrella, not the primary repo.** Everything mounts as a subdirectory under `/workspace`: `REPOS` at `/workspace/<name>`, `EXTRA_MOUNTS` at `/workspace/<basename>`, the Obsidian vault at `/workspace/obsidian`. The `/repos/*` tree is gone — `EXTRA_MOUNTS` now lands under `/workspace/<basename>` instead of `/repos/<basename>`. A host-path positional argument (`runme.sh restricted /path/to/repo`) now mounts at `/workspace/<basename>` (not `/workspace`) and becomes the working directory.

- **`DOCS_PATH` and `SPECS_PATH` removed.** The `/docs` and `/specs` mounts are gone; if either env var is set, `runme.sh` prints a one-line note and ignores it. Keep documentation and specs inside a repo (mounted under `/workspace`) or in the Obsidian vault.

- **Obsidian vault path changed.** `VAULT_PATH` now mounts at `/workspace/obsidian` (was `/obsidian`) and is re-exported as `VAULT_PATH=/workspace/obsidian` inside the container.

- **Agent outputs moved to the launch directory.** `.agent-blocked/` and `.agent-discovery/` are now written to the host directory where `runme.sh` is invoked (surfaced under `/workspace/.agent-*`), instead of inside the workspace repo. They are added to `.gitignore` and `.dockerignore`.

### Added

- **`AGENTS.md` is now the canonical agent-instructions file.** The contents formerly in `CLAUDE.md` were promoted to `AGENTS.md` (the open standard read natively by Codex, GitHub Copilot, Gemini CLI, Cursor, and others). `CLAUDE.md` and `.github/copilot-instructions.md` are now **symlinks** to it, and a new `.kiro/steering/AGENTS.md` symlink exposes the same content to Kiro CLI (which loads `.kiro/steering/**/*.md`, not a root file). Edit `AGENTS.md` only — the rest follow. This also removes the duplicated condensed Copilot instructions, eliminating cross-file drift.

- **`repo.sh reset <name|--all> [--yes]`** — restore a repo volume to a clean state ("start clean"), distinct from `sync` (which fetches latest). Git sources: `git reset --hard` to the upstream (drops uncommitted changes and local commits) + `git clean -ffdx` (removes untracked and git-ignored files) — fully local, no re-clone. Path sources: re-mirror from the host source. Either way it also removes any `:rwcopy` working copies so they re-seed clean. Destructive — prompts for confirmation unless `--yes`. The Linux `bind` backend is left untouched (it prints how to clean the live host checkout).

- **`repo.sh` — shared repo-volume manager** (`add` / `sync` / `reset` / `list` / `rm`; `sync` and `reset` accept `<name | --all>`). Big repositories can be seeded **once** into a Docker named volume living inside the Docker/Colima VM, then attached to any number of containers at native in-VM speed — avoiding the macOS virtio-fs bind-mount penalty (~30–50× slower metadata ops). Repo volumes are global (shared across all container groups) and tracked in a registry at `~/.ai-containers/repos.conf`. Authentication for `git`-URL sources uses the host `~/.ssh` (mounted read-only into a short-lived seeding container); local-path sources need no credentials.

- **`REPOS` env var** — space-separated list of registered repos to attach under `/workspace/<name>`. Modes: `:ro` (shared, read-only; `GIT_OPTIONAL_LOCKS=0` set so read-only git works), `:rw` (shared base volume mounted writable directly, single-writer), `:rwcopy` (isolated per-workspace writable working copy seeded by a fast local copy). Unregistered or missing repos abort before the container starts; a name appearing in both `EXTRA_MOUNTS` and `REPOS` is an error.

- **`REPO_BACKEND` env var** (`auto` | `volume` | `bind`, default `auto`). On macOS `auto` uses named volumes; on Linux it uses direct host bind mounts for `path` repos (already native-speed there), so one `REPOS` line works on both platforms. The backend is decided at `repo.sh add` time and stored in the registry.

- **`@<repo>` positional argument** — selects a registered repo as the working directory at `/workspace/<repo>`, attached writable automatically (errors if explicitly listed `:ro`). This is the fast primary-repo path on macOS.

- **`rsync`** added to the image so `repo.sh sync` mirrors path-sourced repos exactly (with deletions); it falls back to `cp -a` if absent.

- **`repo.sh` honours `SANDBOX_UID`/`SANDBOX_GID`.** It previously hardcoded `id -u`/`id -g` for the `chown` of seeded/synced volume contents, while `runme.sh` creates the sandbox user from `SANDBOX_UID`/`SANDBOX_GID` (defaulting to `id -u`/`id -g`). Overriding those for `runme.sh` therefore left repo volumes owned by the wrong UID and caused in-container permission errors. `repo.sh` now resolves the identity the same way, so the override is symmetric — but you must export the **same** values for both `repo.sh` and `runme.sh` (with no override, the host user is used on both sides automatically). The Linux `bind` backend mounts the host path directly with no `chown` and is unaffected.

- **Dedicated `repo.sh` seed image (`Dockerfile.seed`).** `repo.sh add`/`sync` no longer require the sandbox image to exist. The copy/clone/rsync work runs in a small, shared helper image (`ai-containers-seed`, ~40 MB: Alpine + `git`, `openssh-client`, `rsync`, `bash`), built automatically on first use. Repo volumes can now be seeded **before** `./build.sh` is ever run. The seed image name is fixed and **project-independent** (not derived from `IMAGE_NAME`), so it is built once and reused by every project instead of producing a near-identical copy per project image. Override with `REPO_SEED_IMAGE` to reuse an existing image (e.g. `REPO_SEED_IMAGE="$IMAGE_NAME"`); a named-but-missing `REPO_SEED_IMAGE` errors instead of building. `Dockerfile.seed` is synced to projects by `project-init.sh`/`sync-to-projects.sh` and excluded from the main image build context. Because this helper runs as root while repo volumes are owned by the host UID, `repo.sh sync` of a git-sourced repo sets `git config --global safe.directory /dst` before `git pull --ff-only`, avoiding git's "dubious ownership" refusal.

- **`project-init.sh` ignores `.ai-containers/` in the project's root `.gitignore`.** The per-project `.ai-containers/` is a synced working copy of the central repo whose launcher embeds machine-specific paths (`EXTRA_MOUNTS`) and whose `custom.txt` may hold internal hostnames, so it should not be committed to the project. The rule is added idempotently (git repos only); `sync-to-projects.sh` backfills it for existing projects. Remove the line to version it instead, or set `AI_CONTAINERS_NO_GITIGNORE=1` to skip.

- **`sandbox.env` — persisted per-project `IMAGE_NAME`.** `project-init.sh` now writes `<project>/.ai-containers/sandbox.env` (`IMAGE_NAME=<image>`), and `sandbox-common.sh` sources it (when `IMAGE_NAME` is not already exported) before resolving the image name. This makes `build.sh`, `runme.sh`, and `repo.sh` agree on the image — and therefore the repo-volume names (`<image>-repo-<name>`) — even when a script is run directly instead of through the generated launcher. Previously `repo.sh` run standalone fell back to the default `ai-sandbox`, creating volumes a custom-named project's `runme.sh` could not find. An exported `IMAGE_NAME` still takes precedence. `sync-to-projects.sh` backfills `sandbox.env` for pre-existing projects (from the launcher's `IMAGE_NAME`) and never overwrites it.

- **`sandbox-common.sh`** — shared library (config parsing, container-group helpers, path/volume helpers, repo registry) sourced by `build.sh`, `runme.sh`, and `repo.sh`.

### Removed

- `runme.sh build` subcommand (use `./build.sh`).
- `DOCS_PATH` / `SPECS_PATH` env vars and the `/docs` / `/specs` mounts.
- The `/repos/*` mount tree (replaced by `/workspace/*`).

## v0.2.1

### Added

- **GoReleaser component.** New optional `goreleaser` flag in `sandbox.conf` (`ON`/`OFF`, default `OFF`) installs the latest GoReleaser OSS from the official apt repository at build time. It is self-contained and does **not** require `go` to be enabled — the apt package's recommended `golang` dependency is skipped via `--no-install-recommends`. A new `allowlist-domains.d/goreleaser.txt` fragment (`repo.goreleaser.com`, `goreleaser.com`, plus the already-baseline GitHub release hosts) is included when the component is enabled.

## v0.2.0

### Breaking

- **Linux default behavior changed.** Dotfile directories (`.claude`, `.copilot`, `.kiro`, `.codex`, `.gemini`, `.config/gh`, `.agents`, `.ssh`) are no longer auto-shared with the host on Linux. They now live under `~/.ai-containers/default/` by default on both Linux and macOS. To restore the previous Linux behavior and mount dotfiles directly from `$HOME`, set `AI_CONTAINER_GROUP=host`. On the first run after upgrade, an interactive prompt (TTY required) offers to copy host dotfiles into the `default` group. Non-interactive callers must set `AI_CONTAINER_GROUP_INIT=from:host` or `AI_CONTAINER_GROUP_INIT=clean` to avoid a hard failure.

- **`SSH_SCOPE_DIR` removed.** `.ssh` is now part of the container group and lives at `~/.ai-containers/<group>/.ssh/`. If `SSH_SCOPE_DIR` is set, `runme.sh` prints a one-line deprecation note to stderr and ignores the variable. To migrate a custom SSH directory: copy keys manually into `~/.ai-containers/<group>/.ssh/`, or initialize a new group with `AI_CONTAINER_GROUP_INIT=from:host` to copy the entire group-scoped slice from `$HOME`.

- **macOS `host` group requires explicit acknowledgement.** Setting `AI_CONTAINER_GROUP=host` on macOS prints a warning that Claude Code, GitHub Copilot CLI, Kiro CLI, and GitHub CLI store OAuth tokens in the macOS Keychain (unreachable from the container) and prompts `Type 'yes' to continue, anything else to abort:`. For non-interactive use, set `AI_CONTAINER_HOST_ACK=1`. On Linux, `AI_CONTAINER_GROUP=host` requires no acknowledgement and behaves identically to the previous default.

### Added

- **Container-group system.** A new env var `AI_CONTAINER_GROUP` selects which dotfile tree mounts into the container. The default group is `default`; use `host` to mount from `$HOME`; use any lowercase name (e.g. `docs`, `java-backend`, `ui`) for a purpose-specific isolated profile. Each named group is a directory at `~/.ai-containers/<group>/` containing its own agent auth state, skills, MCP config, and SSH keys. New supporting vars:
  - `AI_CONTAINER_GROUP` — selects the group (default: `default`).
  - `AI_CONTAINER_GROUP_INIT` — non-interactive bootstrap override when a group directory does not yet exist. Values: `clean` (start empty), `from:host` (copy group-scoped dotfiles from `$HOME`), `from:<existing-group>` (copy from another group under `~/.ai-containers/`).
  - `AI_CONTAINER_HOST_ACK` — set to `1` to silently bypass the macOS warning when `AI_CONTAINER_GROUP=host`. Per-invocation; not persisted.

### Removed

- `SSH_SCOPE_DIR` env var. See the breaking-change entry above for migration steps.

- Pre-grouping macOS auto-migration code (was an internal one-shot for moving the legacy flat `~/.ai-containers/.claude`-style layout into `~/.ai-containers/default/`). The only host that ever had that layout has been migrated by hand; new installs go straight to the group structure.

### Changed

- **`.ssh` is now mounted read-write.** The mount was previously read-only. Because `.ssh` now lives inside the group directory (`~/.ai-containers/<group>/.ssh/`) rather than the host's `$HOME/.ssh/`, the original rationale for read-only (preventing container writes from corrupting host SSH keys) no longer applies. The change allows SSH to update `known_hosts` inside the container, restores `ControlMaster` multiplexing, and eliminates `Failed to add the host to the list of known hosts` stderr noise.

- **macOS and Linux dotfile mount paths are now identical.** The previous platform-specific redirect (active only on macOS for Claude Code, Copilot CLI, Kiro CLI, and GitHub CLI) has been replaced by the unified group-root logic. Both platforms now resolve agent dotfile mounts through `~/.ai-containers/<group>/` (or `$HOME` when `AI_CONTAINER_GROUP=host`).
