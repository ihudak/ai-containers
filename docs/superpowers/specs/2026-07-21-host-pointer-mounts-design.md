# Design: host-pointer mount grammar + consistent mount points

**Date:** 2026-07-21
**Status:** Approved
**Supersedes (in part):** `2026-07-20-docs-path-mount-design.md` — specifically its
`DOCS_PATH` **`unset`-on-docs-project** behavior (replaced by a working-dir re-point), its
*"No `:ro`/`:rw` override suffix"* and *"read-only convenience bind-mount"* framing (a `:ro`/`:rw`
suffix is now supported), and its fixed-`/workspace/docs`-only assumption (a `@name` form now mounts
at `/workspace/<name>`). The read-only **default** and the consolidated `qmd` nudge are unchanged.

## Problem

The container exposes three host-directory pointers, but they are inconsistent and limited:

1. **Inconsistent mount points.** `SPECS_PATH → /workspace/specs` and `DOCS_PATH → /workspace/docs`,
   but `VAULT_PATH → /workspace/obsidian` — a tool name baked into a generic capability, and the odd
   one out of the `<VAR>_PATH → /workspace/<var>` pattern.
2. **`DOCS_PATH` goes blind while authoring docs.** When the docs repo is the working dir,
   `project-init.sh` writes `unset DOCS_PATH` into the launcher, so grounding plugins that read
   `$DOCS_PATH` lose their pointer at the one moment the user is guaranteed to be looking at the docs.
3. **No named-volume option for the large corpora.** On macOS, virtio-fs bind mounts are slow; the
   whole `repo.sh`/`REPOS` named-volume system exists to avoid that penalty. But `DOCS_PATH` and
   `SPECS_PATH` — the two corpora most likely to be large and team-shared — can only be given a host
   path, so they cannot benefit from a fast named volume.
4. **No writable-docs escape hatch.** Docs are read-only unless mounted as the working dir. Editing a
   doc while the working dir is something else (e.g. fixing a typo spotted while coding) is impossible
   without switching the working dir.

## Solution

Introduce **one shared mount-spec grammar** for the host pointers and make the mount points
consistent:

```
<POINTER>=[@]<source>[:ro|:rw]
```

- **`<source>`** is either a **host path** (bind-mounted at a fixed, well-known point) or a
  **`@<name>`** registered repo volume (mounted at `/workspace/<name>`, exactly like `REPOS`/`@primary`).
- **`:ro` / `:rw`** is an optional writability override; each pointer has its own default.

Applied per pointer (the **Focused** scope):

| Var | Accepts | Default mode | Host-path mount | `@name` mount | Working-dir re-point |
|-----|---------|--------------|-----------------|---------------|----------------------|
| `DOCS_PATH`  | `[@]src[:ro\|:rw]` | `:ro` | `/workspace/docs`  | `/workspace/<name>` | **yes** |
| `SPECS_PATH` | `[@]src`           | `:rw` | `/workspace/specs` | `/workspace/<name>` | no |
| `VAULT_PATH` | `src`              | `:rw` | `/workspace/vault` | —                   | no |

Rationale for the asymmetry (all deliberate, none accidental):

- **Fixed mount for host paths, `/workspace/<name>` for named volumes** — by *category*, not by
  variable. A host path is an anonymous directory, so a fixed well-known point (`/workspace/docs`,
  `/workspace/specs`, `/workspace/vault`) is the stable choice. A `@name` is a *registered, reusable*
  volume whose identity **is** its name; mounting it at `/workspace/<name>` keeps it consistent across
  its `@primary`, `REPOS`, and pointer roles, and lets an already-mounted volume be **reused** instead
  of double-mounted. Plugins read the *value* of the pointer, so nothing hardcodes the path.
- **`DOCS_PATH` gets the `:ro`/`:rw` suffix; `SPECS_PATH`/`VAULT_PATH` do not** — only docs have a
  read-vs-write mode distinction worth overriding. Specs and the vault are always authored (`:rw`).
- **`VAULT_PATH` stays plain host-path** — a personal knowledge base is small and not a macOS-speed
  problem, so `@name` has no use case (YAGNI). The `/workspace/obsidian → /workspace/vault` rename
  (below) already makes its *mount point* consistent; `@name` support is an orthogonal capability, so
  omitting it is not a special case.

## Enhancement A — `DOCS_PATH` follows the working dir (replaces `unset`)

**Invariant:** `$DOCS_PATH` **always points at the docs; writable exactly when the docs repo is the
working dir, read-only otherwise.**

- **Host-path form:** if the resolved `DOCS_PATH` host path equals the resolved primary working-dir
  host path (`$primary_path`), the docs repo *is* the working dir. Skip the separate
  `:ro /workspace/docs` grounding mount entirely and re-export `DOCS_PATH=$workdir`
  (`= /workspace/<basename>`, the writable working-dir mount). Any `:ro`/`:rw` suffix is ignored — a
  working directory is always writable.
- **`@name` form:** if `DOCS_PATH=@docs2` names the same volume that is the `@primary` working dir,
  the reuse rule (below) already mounts it once at `/workspace/docs2`; `DOCS_PATH` re-exports to
  `/workspace/docs2`. Same invariant, falls out for free.

**`project-init.sh`:** the `unset DOCS_PATH` block (added in the superseded design) is **removed**.
The launcher inherits `DOCS_PATH` from the host profile and the `runme.sh` re-point handles the
docs-project case automatically. Its dedicated test (`tests/test-project-init-docs.sh`) is removed
with it; the behavior is now covered by the `runme.sh` harness.

## The `@name` selector (`DOCS_PATH` / `SPECS_PATH`)

**Mechanism — desugar into `REPOS`.** A `@name[:mode]` pointer value is treated as if
`name:mode` were listed in `REPOS`, so it is mounted at `/workspace/<name>` by the **existing** repo
path — reusing its registration check, backend selection (volume vs Linux bind), and logging. No
volume-mounting logic is duplicated in the pointer blocks.

1. **Desugar (pre-pass, before the effective `repos_list` is built):** for each of `DOCS_PATH` /
   `SPECS_PATH`, if the value is `@name[:mode]`, append `name:<mode>` (default `:ro` for docs, `:rw`
   for specs) to `repos_list` **unless `name` is already present** (from `REPOS` or `@primary`).
2. **Reuse:** if `name` is already listed, keep the existing entry and its mode; do **not** add a
   second mount. If the pointer requested a different mode than the existing entry, print a
   non-fatal note (the explicit `REPOS`/primary entry wins).
3. **Re-export (pointer block):** set `<VAR>=/workspace/<name>` and add the var to the `qmd` corpus
   list. Registration / mode errors already surfaced from the repo loop.
4. An **unregistered** `@name` is an error, identical to an unregistered `@primary` / `REPOS` entry.

## The `:ro` / `:rw` suffix (`DOCS_PATH` only)

- A trailing `:ro` or `:rw` on the value sets the **grounding mount's** mode; default `:ro`.
- The **working-dir re-point case ignores the suffix** — the working dir is always `:rw`; you cannot
  make your own cwd read-only. No error, just ignored.
- When the `@name` volume is already mounted via `REPOS`/`@primary`, that mount's mode wins and the
  suffix only produces the divergence note above; the suffix takes effect only when the pointer is
  what introduces the mount.

## Enhancement B — `VAULT_PATH` → `/workspace/vault` + documented three-tier model

Rename the vault mount point and re-export from `/workspace/obsidian` to `/workspace/vault`; the
collision-guard key and messages change `obsidian → vault` (a mount named `vault` now collides; the
name `obsidian` is freed). This is a **breaking change** (the in-container value becomes
`VAULT_PATH=/workspace/vault`), recorded in `CHANGELOG.md` as breaking, mirroring the prior
`/obsidian → /workspace/obsidian` note.

**Runtime-safe for the plugins:** a scan of `ihudak-claude-plugins` / `ihudak-copilot-plugins` found
no hardcoded `/workspace/obsidian` in executable code — the vault is referenced via `$VAULT_PATH`
throughout (the correct, path-agnostic way). The only fallout is documentation prose in those repos,
a follow-up in *those* repos (out of scope here).

**Document the three-tier model** in `README.md` and `AGENTS.md`:

| Var | Mount | Meaning | Mode |
|-----|-------|---------|------|
| `VAULT_PATH` | `/workspace/vault`  | **Personal** knowledge base (Obsidian vault or any markdown KB) | read-write |
| `SPECS_PATH` | `/workspace/specs`  | **Team / shared** specs, designs, plans | read-write |
| `DOCS_PATH`  | `/workspace/docs`   | **Product documentation** (grounding) | read-only (default) |

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Vault mount point | `/workspace/vault` | Consistency with `/workspace/specs`, `/workspace/docs`; drops the tool-specific `obsidian`. Breaking → CHANGELOG note. |
| `@name` mount point | `/workspace/<name>` (not fixed) | Named volumes have a system-wide identity; keeps them consistent across primary/REPOS/pointer roles and reuse-friendly. |
| `@name` mechanism | Desugar into `REPOS` | Reuses registration, backend, and mount logic; zero duplication. |
| `DOCS_PATH` writability | `:ro`/`:rw` suffix, default `:ro` | Docs are the one pointer with a read-vs-write distinction; suffix is a cheap escape hatch (reverses the earlier YAGNI call, deliberately). |
| `DOCS_PATH` when it is the working dir | Re-point to the working-dir mount (replaces `unset`) | Keeps `$DOCS_PATH` alive and writable while authoring; removes `project-init` special-casing. |
| `SPECS_PATH` `@name` | Supported (`:rw`) | Specs can be large and team-shared — the macOS named-volume speed case. |
| `VAULT_PATH` `@name` / suffix | Not supported | Personal/small; no use case (YAGNI). Mount-point rename already makes it consistent. |

## Changed files

- **`runme.sh`**
  - Factor a shared helper for the host-path pointer branch (parse optional `:ro`/`:rw` suffix,
    `resolve_path`, dir-check + WARNING, fixed-mount collision guard, bind-mount at the fixed point
    with the resolved mode, env re-export, `qmd` corpus append), parameterised per pointer
    (var name, fixed mount, default mode, whether a suffix is allowed, whether re-point applies).
  - `@name` desugaring pre-pass for `DOCS_PATH`/`SPECS_PATH` (append `name:mode` to `repos_list`
    unless already present), placed after the `@primary` injection and before the repo loop.
  - Pointer blocks: `@name` re-export (`/workspace/<name>`) vs host-path (helper); `DOCS_PATH`
    re-point when the host-path/volume equals the working dir.
  - Rename the vault block, its collision key/messages, and the mount/env from `obsidian` to `vault`.
  - Usage text and the mount-layout header comment updated (vault `/workspace/vault`; `DOCS_PATH` /
    `SPECS_PATH` accept `@name`; `DOCS_PATH` accepts `:ro`/`:rw`).
- **`project-init.sh`** — remove the `unset DOCS_PATH` block (obsolete).
- **`AGENTS.md`** — env-var table rows and mount-layout list updated (`/workspace/vault`; `@name` +
  suffix grammar for docs/specs); add the three-tier meaning table; `DOCS_PATH` row no longer
  mentions `unset`.
- **`README.md`** — vault section + table rows updated to `/workspace/vault`; three-tier model
  documented; `DOCS_PATH` section gains the `@name` and `:ro`/`:rw` forms and the re-point behavior;
  `SPECS_PATH` section notes `@name`.
- **`CHANGELOG.md`** — one "Changed (breaking)" entry for the vault mount-point rename; one "Added"
  entry for the `@name`/suffix grammar and the docs re-point.
- **`tests/test-docs-path.sh`** — add cases for re-point, `@name` docs, `:rw` suffix, and a vault
  `/workspace/vault` assertion (see Testing).
- **`tests/test-project-init-docs.sh`** — removed.
- The `.ai-containers/` synced copies are regenerated by `sync-to-projects.sh` — never hand-edited.

## Testing

Extend the fake-`docker` harness (`tests/test-docs-path.sh`):

1. **Vault rename:** `VAULT_PATH` set → capture contains `-v <real>:/workspace/vault:rw` and
   `-e VAULT_PATH=/workspace/vault`, and **no** `/workspace/obsidian`.
2. **Docs re-point (host path == working dir):** primary host path equals `$DOCS_PATH` → capture
   contains `-e DOCS_PATH=/workspace/<basename>` and **no** `/workspace/docs:ro`.
3. **Docs host-path grounding (unchanged):** `DOCS_PATH` set, dir exists, not the primary →
   `-v <real>:/workspace/docs:ro` + `-e DOCS_PATH=/workspace/docs`.
4. **Docs `:rw` suffix:** `DOCS_PATH=<path>:rw`, not the primary → `-v <real>:/workspace/docs:rw`.
5. **Docs `@name`:** `DOCS_PATH=@<name>` for a registered repo → mount at `/workspace/<name>` (`:ro`)
   and `-e DOCS_PATH=/workspace/<name>`.
6. **Specs `@name`:** `SPECS_PATH=@<name>` → mount at `/workspace/<name>` (`:rw`) and
   `-e SPECS_PATH=/workspace/<name>`.
7. **Missing dir / collision (unchanged):** missing host-path dir → WARNING, no mount; name `docs`
   already claimed by a host-path form → error, non-zero exit.
8. **qmd nudge (unchanged):** one consolidated warning naming the mounted corpora when `qmd=OFF`;
   none when `qmd=ON` (via `SANDBOX_CONF`) or no corpus mounted.

Registered-repo cases (5, 6) need a registered repo in a temp `~/.ai-containers/repos.conf`; if
seeding a real volume is impractical in the harness, assert on the desugared `repos_list` mount flag
the same way the other cases assert on captured `docker run` args, and document the seam.

## Out of scope (YAGNI)

- `VAULT_PATH` `@name` or `:ro`/`:rw` suffix.
- `SPECS_PATH` `:ro`/`:rw` suffix (always `:rw`).
- Named-volume auto-detection tied to `$DOCS_PATH` correlation (the `@name` form is explicit).
- `obsidian → vault` back-compat symlink (clean break + CHANGELOG note).
- Updating the plugin repos' README prose (follow-up in those repos).
- Per-project persistence of any pointer in `sandbox.env` (they are host-profile exports).
