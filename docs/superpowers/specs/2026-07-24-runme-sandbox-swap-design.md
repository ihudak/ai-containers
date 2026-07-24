# Design: swap `runme.sh` ↔ launcher naming

**Date:** 2026-07-24
**Status:** Approved (design)
**Repos:** `ai-containers` (opensource, canonical) → `mgd-ai-containers` (3 presets)

## Problem

`runme.sh` is currently the run-the-container engine — a documented, first-class
command (sibling of `build.sh` / `repo.sh`). Its name reads as an imperative "run
ME", which made sense historically when users cloned the container files directly
and `runme.sh` *was* the right thing to start. Since the introduction of generated
per-project launchers (`<project>-container.sh`), the entry point users are meant to
run is the launcher — so the name `runme.sh` now points at the wrong file and creates
"which do I run?" confusion.

## Decision

A two-part rename that reassigns the imperative name to the imperative-appropriate
file:

1. **Engine:** `runme.sh` → `sandbox.sh` — "run the sandbox container". Still directly
   runnable, but demoted in docs to "the underlying engine `runme.sh` calls".
2. **Launcher:** `<project>-container.sh` → `runme.sh` — the per-project entry point
   users actually run. The imperative name is now *true*, and it is identical across
   every project ("always look for `runme.sh`").

Behavior is unchanged; this is a naming + migration change only.

### Rejected alternative

Engine-only rename (`runme.sh` → `sandbox.sh`, launcher keeps `<project>-container.sh`).
Simpler migration, but leaves the launcher with a per-project name users must remember
and does not reclaim the natural `runme.sh` entry point. The chosen swap is a bigger
one-time cost for a permanently coherent model.

## Sequencing (opensource-first)

1. Author in `/workspace/ai-containers` (flat repo + its own `.ai-containers/` working
   copy + `tests/`).
2. Port to `mgd-ai-containers` — 3 presets: `base/`, `docs/`, `.ai-containers/`.

Each repo performs its **own `git mv runme.sh sandbox.sh`** (the two repos share no
git history), preserving file history. The launcher rename in source working copies
(`.ai-containers/<repo>-container.sh` → `runme.sh`) is also a `git mv` where tracked.

## Reference sweep (both repos, all copies)

After `git mv`, update every **live** reference:

- **Shared scripts:** `build.sh`, `repo.sh`, `sandbox-common.sh`, `sync-to-projects.sh`,
  and `sandbox.sh` itself (usage/help text + the `"…build has been removed"` error
  message text).
- **Launcher generator `project-init.sh`:** write the launcher as `runme.sh`
  (`launch_script` target name, the preserved-file / synced-file lists, gitignore
  comment text), and emit `./sandbox.sh` as the engine call inside it (active line +
  commented examples).
- **Config/build/docs:** `Dockerfile`, `sandbox.conf` comment, `.dockerignore`,
  `.gitignore`, `allowlist-domains.d/base.txt` comment, `AGENTS.md`, `README.md`.
  Every `<project>-container.sh` mention → `runme.sh`.
- **Tests (opensource only):** `test-docs-path.sh`, `test-tools-d.sh`,
  `test-sandbox-schema.sh` — the `./runme.sh` invocations → `./sandbox.sh`; rename the
  `run_runme()` helper → `run_sandbox()` for consistency.
- **CHANGELOG:** add **one new** breaking-change entry per repo. **Leave existing
  historical CHANGELOG entries and `docs/superpowers/specs|plans/*` untouched** — they
  record what was true at the time; rewriting them would be revisionist.

## README framing

README centers on `./runme.sh` as the quick-start entry point. `sandbox.sh` is
documented as "the engine `runme.sh` calls (advanced / direct use)", listed alongside
`build.sh` / `repo.sh` under the hood — one obvious path for users, no co-equal
ambiguity.

## Migration of existing user projects (auto, via `sync-to-projects.sh`)

Existing projects have `runme.sh` = **old engine** and `<project>-container.sh` =
launcher. We want `runme.sh` = **launcher** and `sandbox.sh` = engine. The same-name
hazard (old engine vs. new launcher both named `runme.sh`) is resolved by a marker: a
**launcher contains `export IMAGE_NAME=<literal>`; the engine never does** (verified).

Per project, idempotently:

1. **Detect & remove stale engine.** If `runme.sh` exists and does **not** contain
   `export IMAGE_NAME=` → it is the old engine; delete it.
2. **Rename launcher.** If `<project>-container.sh` exists → `git mv`/`mv` it to
   `runme.sh`. (If a `runme.sh` launcher already exists — i.e. contains
   `export IMAGE_NAME=` — this project is already migrated; skip.)
3. **Repoint engine call.** In the launcher (`runme.sh`), sed `./runme.sh` →
   `./sandbox.sh` (all occurrences; targets only the internal engine call, idempotent).
4. **Drop engine in.** Copy the new `sandbox.sh` into the project's `.ai-containers/`
   (it is part of the renamed shared-file list, so this happens in the normal copy).

No per-project `.gitignore` change is needed: `project-init.sh` gitignores the entire
`/.ai-containers/` directory, not individual files.

**Idempotency:** on a second sync, step 1 finds no marker-less `runme.sh` (the engine is
now `sandbox.sh`), step 2 finds no `<project>-container.sh` (already renamed) and sees a
marker-bearing `runme.sh`, step 3's sed is a no-op. Second run changes nothing.

## Verification

- `grep -rn "runme" <repo>` returns **only** historical specs/plans + old CHANGELOG
  entries — zero hits in live code/scripts/README/AGENTS/tests — in each repo.
- Opensource `tests/` pass (including the renamed `run_sandbox` helper).
- New/updated migration test: a synthetic pre-swap project (old-engine `runme.sh` +
  `<project>-container.sh`) migrates to (`sandbox.sh` engine + `runme.sh` launcher
  calling `./sandbox.sh`); a **second** sync is a no-op.
- Fresh `project-init.sh` emits a `runme.sh` launcher that calls `./sandbox.sh`.
- mgd `sync-presets.sh --check` passes (confirms `base/`↔`docs/` byte-equality now
  includes `sandbox.sh` and picks up the rename automatically).
- Sanity: a generated `runme.sh` launcher runs and invokes the `sandbox.sh` engine.
