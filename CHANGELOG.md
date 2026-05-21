# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
