# Design: `$SPECS_PATH` — mount a shared specs/design/plans repo

**Date:** 2026-06-29
**Status:** Approved

## Problem

The container already exposes `$VAULT_PATH`: a host directory (an Obsidian vault) bind-mounted
at a fixed in-container path (`/workspace/obsidian`) and re-exported as
`VAULT_PATH=/workspace/obsidian` so in-container skills/workflows resolve it without knowing the
host path.

There is no equivalent for a repository of **AI-ready specifications, design documents, and
development plans**. The `dev-workflows` plugin (and the superpowers brainstorming → writing-plans
flow) read and produce such specs. When that plugin runs inside an AI container it benefits from a
stable, well-known location for these artifacts, independent of where the repo lives on the host.

## Solution

Add a `SPECS_PATH` host-path environment variable to `runme.sh`, structurally identical to
`VAULT_PATH`. When set, the host directory is bind-mounted **read-write** at the fixed path
`/workspace/specs`, and `SPECS_PATH=/workspace/specs` is re-exported into the container.

Because `runme.sh` reads `SPECS_PATH` from the invoking shell environment, an export in the host's
shell profile (e.g. `.bash_profile`) automatically becomes the container default — exactly as with
`VAULT_PATH`. No additional defaulting logic is required.

**Note — re-introduction:** `SPECS_PATH` (and `DOCS_PATH`) existed previously, mounted at the
top-level `/specs`, and were removed on 2026-06-12 during the `/workspace`-umbrella consolidation.
This re-introduces only `SPECS_PATH`, now under the umbrella at `/workspace/specs` with env
re-export and a name-collision guard (neither of which the old version had). `DOCS_PATH` stays
removed; `runme.sh` and `README.md` narrow their removal notes to `DOCS_PATH` only.

## Behavior (mirrors `VAULT_PATH`)

1. `runme.sh` reads `SPECS_PATH`, expands a leading `~`, and resolves the real path.
2. If the directory exists:
   - Bind-mount `"$specs_real:/workspace/specs:rw"`.
   - Pass `-e SPECS_PATH=/workspace/specs` into the container.
   - Error out if the name `specs` is already used by a `REPOS` / `EXTRA_MOUNTS` mount
     (collision guard, identical to the `obsidian` guard).
3. If the directory does not exist: print
   `WARNING: SPECS_PATH is set but directory does not exist: <path>` and continue.
4. **No** companion-component warning. (`VAULT_PATH` warns when `qmd=OFF`; `SPECS_PATH` does not,
   because the consumer — the `dev-workflows` plugin — is a Claude plugin mounted via the container
   group, not a `sandbox.conf` component, so there is nothing to gate on.)

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Access mode | Read-write (`:rw`) | The agent both reads specs to implement features and writes design docs / plans back. Matches `VAULT_PATH`. |
| In-container mount point | `/workspace/specs` | Short, obvious; reserves the name `specs` against `REPOS`/`EXTRA_MOUNTS` collisions. |
| Startup warnings | Existence check only | No `sandbox.conf` component to gate on. |
| Host default | Host shell `SPECS_PATH` export | Same mechanism as `VAULT_PATH`; no extra code. |

## Changed files

All edits are surgical and match the existing `VAULT_PATH` style.

- **`runme.sh`**
  - New `specs_mount_flags` / `specs_env_args` block placed immediately after the Obsidian-vault
    block (~line 525), structurally identical to it.
  - Add `${specs_env_args[...]}` and `${specs_mount_flags[...]}` to the `docker run` invocation,
    adjacent to the vault flags (~lines 672 / 676).
  - Usage text (~lines 89–94) gains a `SPECS_PATH` entry.
  - Mount-layout header comment (~line 31) mentions `/workspace/specs`.
- **`AGENTS.md`** (canonical instruction file; `CLAUDE.md` / Copilot / Kiro are symlinks that
  update automatically)
  - New env-var bullet after the `VAULT_PATH` bullet (~line 98).
  - New mount-layout row `SPECS_PATH → /workspace/specs` (~line 126).
- **`README.md`** — short subsection beside the `VAULT_PATH` docs (~line 488): description, a
  `SPECS_PATH=/path/to/specs ./runme.sh …` example, and the `dev-workflows` use case.
- **`CHANGELOG.md`** — one "Added" entry.

## Out of scope (YAGNI)

- No new `sandbox.conf` component.
- No `qmd` coupling / search warning.
- No read-only variant.
- No auto-registration as a `REPOS` volume.

`SPECS_PATH` is purely a convenience bind-mount plus env propagation, exactly like `VAULT_PATH`.
