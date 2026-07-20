# Design: `$DOCS_PATH` — mount a read-only product-documentation repo

**Date:** 2026-07-20
**Status:** Approved

## Problem

The container exposes two host-path pointers — `$VAULT_PATH` (`/workspace/obsidian`) and
`$SPECS_PATH` (`/workspace/specs`) — each a host directory bind-mounted at a fixed in-container
path and re-exported so in-container skills/workflows resolve it without knowing the host path.
Both are mounted **read-write**.

There is no equivalent for a repository of **product documentation** (e.g. `dynatrace-docs`).
Existing documentation is high-value grounding when planning and defining new work: the
`ihudak-claude-plugins` / `ihudak-copilot-plugins` workflows that create an idea, create or update a
Value Increment, and write Release Notes all read the docs to ground their output. Without a
stable, well-known location, those workflows have no access to the docs and produce weaker results.

Unlike specs (which workflows author) or the vault (which workflows write to), product docs are
**consumed as grounding** in these phases. The container should expose them **read-only** by
default so a grounding workflow cannot accidentally mutate the documentation repo.

## Solution

Add a `DOCS_PATH` host-path environment variable to `runme.sh`, structurally identical to
`SPECS_PATH` / `VAULT_PATH`, with **one difference: it is mounted read-only** (`:ro`). When set,
the host directory is bind-mounted at the fixed path `/workspace/docs` and
`DOCS_PATH=/workspace/docs` is re-exported into the container.

Because `runme.sh` reads `DOCS_PATH` from the invoking shell environment, an export in the host's
shell profile automatically becomes the container default — exactly as with `VAULT_PATH` /
`SPECS_PATH`. No additional defaulting logic is required.

**Note — re-introduction.** `DOCS_PATH` existed previously, mounted read-write at the top-level
`/docs`, and was removed on 2026-06-12 during the `/workspace`-umbrella consolidation (see
`2026-06-29-specs-path-mount-design.md`, which reintroduced only `SPECS_PATH` and left `DOCS_PATH`
removed). This reintroduces `DOCS_PATH` under the umbrella at `/workspace/docs`, now **read-only**,
with env re-export and a name-collision guard — none of which the old version had. The old
`DOCS_PATH`-removal notes in `runme.sh` and `README.md` are replaced with the new behavior.

## Editing docs: no special-casing

An earlier iteration proposed making `DOCS_PATH` writable when it was passed as the working
directory (interception of the positional primary). That was **dropped**. It could only detect a
host-path primary, not a named-volume primary (`@docs`), so "make docs writable" would silently
work one way and not the other — asymmetric magic worse than none.

Instead, reading and editing stay cleanly separate:

- **Grounding (read):** `$DOCS_PATH` is always `/workspace/docs`, always read-only. Plugins that
  read docs for grounding cannot write to it.
- **Authoring (write):** mount the docs repo as the **working directory** (a host-path primary, or
  an `@docs` repo volume). It becomes writable at its own mount point, and workflows write via the
  working dir / cwd — not via `$DOCS_PATH`.

Consequences (all acceptable, all predictable):

- If the docs repo is set as `DOCS_PATH` **and** passed as a host-path primary whose basename is
  **not** `docs`, it is bind-mounted twice — read-only at `/workspace/docs`, read-write at
  `/workspace/<basename>`. These are two views of the same inodes (no copy); a write through the
  read-write view is instantly visible through the read-only view.
- If that primary's basename **is** `docs`, both target `/workspace/docs` → the name-collision
  guard fires with a clear error. Same behavior as the existing `obsidian` / `specs` guards.

## Behavior (mirrors `SPECS_PATH`, read-only)

1. `runme.sh` reads `DOCS_PATH`, expands a leading `~`, and resolves the real path.
2. If the directory exists:
   - Bind-mount `"$docs_real:/workspace/docs:ro"`.
   - Pass `-e DOCS_PATH=/workspace/docs` into the container.
   - Error out if the name `docs` is already used by a `REPOS` / `EXTRA_MOUNTS` / primary mount
     (collision guard, identical to the `obsidian` / `specs` guards).
3. If the directory does not exist: print
   `WARNING: DOCS_PATH is set but directory does not exist: <path>` and continue. (Fixes the old
   version's silent skip; matches `VAULT_PATH` / `SPECS_PATH`.)
4. When mounted, `DOCS_PATH` contributes to a **single consolidated `qmd` nudge** (see below) — a
   real docs repo is thousands of markdown files, where ranked full-text search beats `grep`.
5. Mode-agnostic — identical in `restricted` and `discovery`.

## Consolidated `qmd` search nudge

`qmd` (`@tobilu/qmd`) is a **generic** on-device markdown search CLI installed by a single global
`sandbox.conf` toggle; nothing wires it to a specific path. Today `runme.sh` prints a `qmd=OFF`
warning inline in the `VAULT_PATH` block only. Because `qmd` is one global capability, not a
per-mount one, this design **replaces** that vault-only warning with one consolidated nudge:

- Each of the `VAULT_PATH` / `SPECS_PATH` / `DOCS_PATH` blocks, on a successful mount, appends its
  name to a `qmd_corpora` list.
- After all three are resolved, if `qmd_corpora` is non-empty **and** `qmd` is not enabled, print a
  single warning naming the mounted corpora, e.g.
  `WARNING: qmd=OFF in sandbox.conf, but markdown corpora are mounted (VAULT_PATH, DOCS_PATH). Set qmd=ON and rebuild for in-container search.`
- The inline vault-only warning (~line 522) is removed.

This fires once regardless of how many corpora are mounted (no triple-warning), auto-covers any
future markdown corpus, and gives better signal than the old message (it names what is mounted).

## `project-init.sh`: auto-unset for a docs-repo project

When a project is initialized **for** the docs repo itself, grounding-mounting the same repo
read-only at `/workspace/docs` is redundant, and collides outright if the working dir is claimed via
an `@docs` volume or a `docs`-basename primary. `project-init.sh` prevents this at generation time:

- If the resolved target project path **equals** the resolved `$DOCS_PATH` at init time, the
  generated launcher gets an active `unset DOCS_PATH` line (with an explanatory comment), placed
  after the `export` block and before the `runme.sh` invocation.
- This covers both the default path-workdir launcher (`./runme.sh … ..`) and a hand-edited
  `@docs`-volume launcher (`./runme.sh … @docs`): `/workspace/docs` is claimed once, by the
  working dir, with no collision.
- **Graceful degradation:** if `$DOCS_PATH` is not exported when `project-init.sh` runs, the
  comparison simply does not match, no line is written, and the user falls back to the clear
  runtime collision error. No commented-out hint is written into non-matching launchers (avoids
  noise in the common non-docs project).

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Access mode | Read-only (`:ro`) | Docs are grounding, not an authoring target. A read-only guarantee makes grounding workflows safe. Differs from `VAULT_PATH` / `SPECS_PATH` (`:rw`). |
| Env var name | `DOCS_PATH` | Matches the `VAULT_PATH` / `SPECS_PATH` host-pointer convention; becomes the plugin contract. |
| In-container mount point | `/workspace/docs` | Short, obvious; fixed so `$DOCS_PATH` is stable for plugins; reserves the name `docs` against `REPOS` / `EXTRA_MOUNTS` / primary collisions. |
| Making docs writable | Mount as working dir (no interception) | Named-volume primaries can't be path-detected; explicit separation of read grounding vs. write authoring is simpler and symmetric. |
| `qmd` coupling | One consolidated nudge across vault/specs/docs | `qmd` is a single global toggle; a per-path warning would triple-fire and misrepresent it. Replaces the vault-only warning. |
| Host default | Host shell `DOCS_PATH` export | Same mechanism as `VAULT_PATH` / `SPECS_PATH`; no extra code. |
| Docs-repo project | `project-init.sh` auto-`unset` on path match | Prevents redundant mount / collision when containerizing the docs repo itself. |

## Changed files

All `runme.sh` edits are surgical and match the existing `SPECS_PATH` style.

- **`runme.sh`**
  - New `docs_mount_flags` / `docs_env_args` block placed immediately after the `SPECS_PATH` block
    (~line 546), structurally identical to it but mounting `:ro`.
  - Add `${docs_env_args[...]}` and `${docs_mount_flags[...]}` to the `docker run` invocation,
    adjacent to the specs flags (~lines 695 / 700).
  - Consolidated `qmd` nudge: each of the vault/specs/docs blocks appends to a `qmd_corpora` list on
    a successful mount; remove the inline vault-only warning (~line 522); after the docs block,
    print one `qmd=OFF` warning naming the mounted corpora when `qmd_corpora` is non-empty.
  - Usage text (~lines 97–98) gains a `DOCS_PATH` entry (note: read-only); the `VAULT_PATH`
    "Requires qmd=ON …" line (~line 96) is generalized to "mounted markdown corpora".
- **`project-init.sh`**
  - After computing `project_path`, resolve `$DOCS_PATH` and compare; when equal, emit
    `unset DOCS_PATH` into the generated launcher (after the `export` block, ~line 289).
- **`AGENTS.md`** (canonical instruction file; `CLAUDE.md` / Copilot / Kiro are symlinks that
  update automatically)
  - New env-var table row after `SPECS_PATH`, marked read-only, with a compact pointer: if the
    working dir is this same docs repo, unset it (project-init does so automatically) to avoid the
    `/workspace/docs` collision. In-container column: `→ /workspace/docs`.
  - Extend the "host-directory pointers" paragraph to include `DOCS_PATH`.
  - New Mount-layout row `DOCS_PATH → /workspace/docs`.
- **`README.md`**
  - New env-var table row beside `SPECS_PATH`.
  - New `DOCS_PATH` subsection beside the `SPECS_PATH` docs: description, a
    `DOCS_PATH=/path/to/docs ./runme.sh …` example, the read-only guarantee, the plugin use case
    (idea / VI / release-notes grounding), how to edit docs (mount as working dir), and the
    docs-repo-project `unset` guidance.
  - **Replace** the existing `DOCS_PATH`-removal note (~line 549) with the new behavior.
  - Generalize the `qmd` note (~line 547) from vault-specific to "any mounted markdown corpus
    (vault / specs / docs)", reflecting the consolidated nudge.
- **`CHANGELOG.md`** — one "Added" entry noting reintroduction as read-only under `/workspace/docs`.

## Testing

`runme.sh` assembles a `docker run` command, so verify by capturing the assembled mount/env flags:

1. `DOCS_PATH` set, existing dir, not primary → flags contain `-v <real>:/workspace/docs:ro` and
   `-e DOCS_PATH=/workspace/docs`.
2. `DOCS_PATH` set, missing dir → `WARNING: DOCS_PATH …`, no docs mount.
3. `DOCS_PATH` set + a `REPOS`/`EXTRA_MOUNTS` mount named `docs` → collision error, non-zero exit.
4. `DOCS_PATH` set + same dir passed as a host-path primary with a non-`docs` basename → both a
   `:ro` `/workspace/docs` mount and a `:rw` `/workspace/<basename>` mount are present.
5. `project-init.sh`: target path == `$DOCS_PATH` → generated launcher contains `unset DOCS_PATH`;
   a different target path → it does not.
6. Consolidated `qmd` nudge: with `qmd=OFF` and `DOCS_PATH` + `VAULT_PATH` mounted → exactly one
   warning naming both; with `qmd=ON` → no warning; with no corpus mounted → no warning.

## Out of scope (YAGNI)

- No workdir interception / writable-when-primary magic.
- No `:ro` / `:rw` override suffix (writability is decided solely by mounting as the working dir).
- No new `sandbox.conf` component. (`qmd` coupling is limited to the consolidated warning above — no
  auto-indexing or auto-search of any corpus.)
- No per-project persistence of `DOCS_PATH` in `sandbox.env` (it is a host-profile export, like
  `VAULT_PATH` / `SPECS_PATH`).
- No overlap warning when `DOCS_PATH` equals `SPECS_PATH` / `VAULT_PATH`.
- No commented-out `unset DOCS_PATH` hint in non-matching launchers.

`DOCS_PATH` is a read-only convenience bind-mount plus env propagation — `SPECS_PATH` with a `:ro`
flag and a small `project-init.sh` guard.
