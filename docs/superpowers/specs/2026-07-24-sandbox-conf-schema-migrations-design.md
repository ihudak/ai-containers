# Design: `sandbox.conf` schema-version marker + key-aware migrations

**Date:** 2026-07-24
**Status:** Approved

## Problem

`sandbox.conf` is a flat `key=value` file (with `#` comments) that selects which optional dev
tools (`kiro`, `pnpm`, `openjdk`, `node`, …) get installed into the AI sandbox image. Unlike every
other shared file, each project keeps its **own** copy: `project-init.sh` creates it once, and the
user hand-edits it per project. `sync-to-projects.sh` keeps all the other shared files
(`Dockerfile`, install scripts, `sandbox-common.sh`, …) byte-identical across registered projects by
plain overwrite, but deliberately **excludes** `sandbox.conf` from that overwrite, because a
project's tool selection is exactly what must not be clobbered.

The cost of that exclusion is drift. When central's schema evolves, `sync-to-projects.sh` prints one
line — `WARN sandbox.conf differs from upstream` — and does nothing else (see `sync-to-projects.sh`
~line 122). A project that never gets hand-reconciled silently misses every new tool key added
upstream, indefinitely.

Real git history of `sandbox.conf` (~20 changes over its life) shapes the solution:

- **~90% of changes are purely additive** — one new `newtool=OFF` line appended, nothing else
  touched.
- **Exactly 2 changes were genuinely semantic**, both during early rapid iteration, not an ongoing
  pattern: (1) per-version boolean keys `openjdk-21=ON` / `openjdk-25=OFF` collapsed into a single
  comma-list key `openjdk=21,25`; (2) a single `graalvm=` key split into `graalvm-ce=` /
  `graalvm-oracle=`.

The file is parsed by `get_versions()` / `is_enabled()` in `sandbox-common.sh`, via
`grep "^${key}=" "$config_file" | head -1 | cut -d= -f2-` — it is **not** `source`d as bash. That
tolerates arbitrary comments safely, but a **duplicate** `key=` line (from a bad manual edit)
silently resolves to whichever occurrence `head -1` hits first, with no error — a latent footgun,
independent of the sync problem but sharpened by it.

The mechanism below reconciles a project's copy against central's on every sync: additive changes
flow in automatically, the two-per-lifetime semantic changes are handled by explicit key-aware
hooks, and the duplicate-key footgun is closed.

## Design history: why not a line-based 3-way merge

An earlier iteration used full per-version file snapshots (`.migrates/sandbox.conf.v1`, `.v2`, …)
plus a line-based 3-way merge via `git merge-file` (base = the project's recorded-version snapshot,
theirs = current central, ours = the project's actual file), writing `<<<<<<< / ======= / >>>>>>>`
conflict markers directly into a project's `sandbox.conf` on conflict, guarded by a fail-fast scan
in `check_config()`. It was **rejected** after an independent Opus design review, for three reasons:

1. **`sandbox.conf` is a set of `key=value` pairs, not ordered prose.** Line-based merge is needlessly
   sensitive to reordering, whitespace, and comment-wording changes, and can raise spurious conflicts
   when nothing semantically conflicts.
2. **Writing conflict markers into a file parsed by `grep "^key=" | head -1` is actively dangerous.**
   A duplicated key from an unresolved conflict resolves silently to one side with no error — defeating
   the whole point.
3. **The snapshot-per-version approach has a bootstrap gap.** A project file predating the whole system
   has no matching ancestor snapshot to diff against.

The adopted design fixes all three by being **key-aware rather than line-based**, and needs no
snapshots at all.

## Solution

Five pieces, plus one independent safety guard:

1. A `# schema-version: N` marker inside `sandbox.conf` itself.
2. A git-tracked `migrations/` directory holding one small key-aware hook per **semantic** change.
3. A **reconcile** step that replaces today's WARN-only branch in `sync-to-projects.sh`.
4. `bump-sandbox-version.sh` — authoring helper that scaffolds a hook and bumps central's marker.
5. `check-sandbox-version.sh --check` — a CI gate that blocks a silent semantic change.
6. A duplicate-key guard inside `get_versions()` (independent of the above, but what makes it safe).

## 1. Schema-version marker

A single comment line lives directly inside `sandbox.conf` — in central's copy and in every
project's copy:

```
# schema-version: 3
```

- It is a **plain integer**.
- It is **invisible to the parser**: a comment line never matches `grep "^${key}="`, so
  `get_versions()` and friends never see it.
- It is bumped **only when a `migrations/` hook is added** — i.e. only for semantic changes
  (renames / splits / removals), **never** for ordinary additive changes.
- A project file **missing the line entirely is treated as version 0**.

**The marker is ensured — inserted if absent, updated in place if present — unconditionally on every
sync run**, regardless of whether any hook fired or any key was added. This is what backfills every
pre-existing project with no dedicated one-time bootstrap script: the first sync after this feature
ships already walks every registered project (that is what `sync-to-projects.sh` does today), and on
that pass every project missing the line gets it for free, as a side effect of the reconcile step
running unconditionally. Every later sync keeps it current. Without this "always ensure" rule, a
project that happens to need no key additions would never receive the marker at all.

## 2. The `migrations/` directory

A git-tracked directory at the `ai-containers` repo root, named `migrations/`. It holds **one small
script per semantic change** (rename, split, or pure removal — **not** one per ordinary change),
named by the version it migrates **to**:

```
migrations/002-openjdk-single-key.sh
migrations/003-graalvm-split.sh
```

Given the real history, this directory holds on the order of **2 files total** to date — not one per
version.

**Why `migrations/` and not `.migrates/`.** A hidden `.migrates/` was considered and rejected:
"migrates" is grammatically odd as a noun; hidden dot-directories in this repo mean generated /
user-local working copies (`.ai-containers/`), not committed source; and this repo's other committed
infrastructure directories are visible (`allowlist-domains.d/`, `tools.d/`).

**Rules for hook scripts:**

- They may contain real **per-key translation logic**, not just static line inserts. The `openjdk`
  hook, for example, reads which per-version boolean keys were `ON`, computes the merged comma-list
  value, deletes the old keys, and inserts the new one.
- They must be **idempotent** — check their own precondition (e.g. "does `openjdk-21=` exist in this
  file?") and no-op otherwise — because sync can run repeatedly, including after an interrupted run.
- They must touch **only `key=value` lines, never comment text** — both for robustness and because
  central's comment wording has genuinely changed over real history and must never be able to break a
  hook's matching. A leftover stale comment for a removed key is a cosmetic non-issue, not a
  correctness one.
- **Pure key removal** (a tool deprecated with no replacement) is also a hook — delete-only, no
  insert.

## 3. Reconcile algorithm

Replaces today's WARN-only branch in `sync-to-projects.sh` (~line 122). Runs per registered project,
on every sync:

1. Read the project's recorded `schema-version` (0 if absent).
2. Run every `migrations/NNN-*.sh` whose `NNN` is greater than that version, in **ascending numeric
   order**, against the project's file.
3. **Additive reconcile:** for every key present in central's **current** `sandbox.conf` but absent
   from the (now hook-migrated) project file, append it with central's current default value, grouped
   under a single `# New options synced from upstream (<date>)` banner at the end of the project's
   file. New keys are **not** re-threaded into their original section-by-section position — simplicity
   over cosmetic layout.
4. Keys **already present** in the project's file are **never** touched or overwritten, whatever their
   value — preserving per-project customization is the entire reason `sandbox.conf` is excluded from
   the normal overwrite-sync.
5. **Ensure** (insert-if-absent, else update-in-place) the project's `# schema-version:` line to match
   central's current version — **unconditionally, every sync** (see section 1; this is not conditional
   on step 2 or 3 having done anything).

**Optional enhancement (nice-to-have, not required):** since the file is already open, a cheap scan
for pre-existing duplicate `key=` lines can warn at sync time rather than waiting for the next
build/run failure. Mention it; do not require it.

## 4. `bump-sandbox-version.sh`

Used **only when authoring a semantic change**. In one step it scaffolds the next
`migrations/NNN-*.sh` file (with the idempotent-precondition skeleton) and bumps central's
`# schema-version:` line. Adding a plain new `newtool=OFF` line needs **neither this script nor any
version bump**.

## 5. `check-sandbox-version.sh --check` (CI gate)

Mirrors the existing `sync-presets.sh --check` pattern (already present in the sibling
`mgd-ai-containers` repo for a different parity concern — same style and spirit). It compares
central's current key **set** against the previous commit's:

- If a key **disappeared or was renamed** without a matching new `migrations/` file **and** version
  bump, **fail** with a clear message naming the missing / changed key.
- Ordinary key **additions pass silently**.

This fires roughly **twice across the file's entire history** — near-zero day-to-day friction, while
still blocking silent drift on the rare case that actually matters.

## 6. Duplicate-key defense (independent, but what makes the above safe)

`get_versions()` in `sandbox-common.sh` — the actual runtime parser, reached via `check_config()` and
directly by `build.sh` and `runme.sh` — gets a guard: if `grep "^${key}="` returns **more than one**
match for a key, exit immediately with a clear error naming the file and the duplicated key, instead
of silently taking `head -1`'s first match as it does today.

This is a general-purpose guard against any bad manual edit, not specific to the sync mechanism — and
it is precisely what makes it safe to avoid the rejected conflict-marker approach: no code path is
left that can silently misparse a duplicated or conflicted key.

The guard belongs **inside `get_versions()` itself**, so it protects every current and future caller.
`repo.sh` also sources `sandbox-common.sh` but was confirmed (by grep) to call none of
`get_versions` / `is_enabled` / `any_enabled` — it only manages repo volumes, so it is not a live
exposure today; putting the guard in the parser covers it regardless.

## 7. Documentation updates

- **`README.md`:** full mechanism write-up — the schema-version marker, `migrations/`, when a hook is
  needed (renames / splits / removals) vs. not needed (plain additions), and the CI gate.
- **`AGENTS.md`** (the canonical instruction file; `CLAUDE.md` and `.github/copilot-instructions.md`
  are symlinks to it, so this one edit reaches Claude Code, Copilot, and any other
  AGENTS.md-convention agent, e.g. Codex): add a short, explicit rule:

  > Adding a new on/off or version-list key to `sandbox.conf` needs nothing extra: no bump, no hook.
  > Renaming a key, splitting it into multiple keys, removing it, or changing what its value means
  > while keeping the same key name requires a `migrations/` hook — see README. Never redefine an
  > existing key's semantics in place; always introduce a new key name for a semantic change. The
  > reconcile mechanism assumes an existing key's meaning never silently changes underneath a project
  > that has already set it — violating this discipline is not automatically detectable by tooling.

## mgd-ai-containers adaptation

Per this project's **opensource-first port policy** — generic features are authored in `ai-containers`
first, then ported down to `mgd-ai-containers` — this section records the porting shape so the later
port is mechanical rather than a redesign.

`mgd-ai-containers` ships **three copies** of this infrastructure: `base/` (the canonical preset),
`docs/` (the documentation preset), and a gitignored `.ai-containers/` working copy.

- `base/sandbox.conf` and `docs/sandbox.conf` were confirmed (by diffing their key lists) to have
  **identical key sets** — only the default ON/OFF values differ between the two presets. Therefore
  `migrations/` is shared **once at the mgd repo root**, not duplicated per preset, and serves both
  `base/` and `docs/`.
- `sync-to-projects.sh` is byte-identical between `base/` and `docs/` today, and each preset has its
  **own** `projects.conf` (`base/projects.conf` has real registered entries; `docs/projects.conf`
  does not exist yet). Each preset already syncs only its own registered projects, treating its own
  `sandbox.conf` as "central" — **no preset-tagging mechanism is needed**.
- The one porting wrinkle: the copies of `sync-to-projects.sh` inside `base/` and `docs/` must resolve
  the shared `migrations/` directory **one level up** from their own preset directory (e.g.
  `"$script_dir/../migrations"`), since it lives at the mgd repo root rather than per preset.
- mgd's equivalent of `check-sandbox-version.sh --check` should mirror the CI-gate style of the
  existing `sync-presets.sh --check` script already accepted in that repo.

## Edge cases

- **Pre-system / pre-marker project files.** Treated as version 0; naturally backfilled by the
  always-unconditional marker-ensure step (section 1). No dedicated one-time bootstrap script.
- **Same-key semantic drift without a rename** (someone violates the "always introduce a new key for a
  semantic change" discipline). **Not** automatically detectable by the reconcile tooling — the key
  set is unchanged, so the CI gate sees nothing, and reconcile treats the key as already-present and
  leaves it alone. This is an **accepted residual risk**, mitigated only by code review and the
  `AGENTS.md` rule, not by tooling. Stated here explicitly as a known limitation, not glossed over.
- **Pre-existing duplicate `key=value` lines predating this system.** The reconcile "does this key
  already exist" test is an **existence** check, not a uniqueness check, so it behaves correctly
  regardless of duplicate count. The `get_versions()` guard (section 6) catches the duplicate at
  build / run time; optionally `sync-to-projects.sh` can also warn about it at sync time (section 3).

## Changed files

- **`sync-to-projects.sh`** — replace the WARN-only `sandbox.conf` branch (~line 122) with the
  reconcile step (sections 3, 1). Resolve `migrations/` relative to `script_dir`.
- **`sandbox-common.sh`** — add the duplicate-key guard to `get_versions()` (section 6).
- **`sandbox.conf`** — add the `# schema-version: N` marker line (section 1).
- **`migrations/`** (new directory) — `002-openjdk-single-key.sh`, `003-graalvm-split.sh`
  (the two real historical semantic changes), each idempotent and key-only (section 2).
- **`bump-sandbox-version.sh`** (new) — authoring helper (section 4).
- **`check-sandbox-version.sh`** (new) — `--check` CI gate (section 5).
- **`README.md`** — full mechanism write-up (section 7).
- **`AGENTS.md`** — the semantic-change rule (section 7); reaches Claude Code / Copilot / Codex via
  the existing symlinks.
- **`CHANGELOG.md`** — one "Added" entry.
- The `.ai-containers/` synced copies are regenerated by `sync-to-projects.sh` — never hand-edited.

## Testing

Match this repo's existing test style — plain bash scripts under `tests/`, `pass` / `fail` helpers,
temp fixtures via `mktemp -d`, sourcing the real library or running the real script and asserting on
output (see `tests/test-tools-d.sh` for the source-and-assert pattern and `tests/test-docs-path.sh`
for the run-the-script-and-grep pattern).

- **Reconcile unit tests.** Fixture project files at various schema-versions (missing / 0, mid-range,
  current) synced against a fixture central `sandbox.conf` + fixture `migrations/` hooks; assert the
  final key set, values, and marker line are correct.
- **Hook tests.** One test per real hook, feeding it the actual pre-migration key shape (e.g.
  `openjdk-21=ON`, `openjdk-25=OFF`) and asserting the correct post-hook shape (e.g. `openjdk=21`).
- **Idempotency test.** Run reconcile twice on the same project fixture; assert the second run is a
  no-op — no duplicate keys created, marker unchanged.
- **Duplicate-key guard test.** Fixture file with a deliberately duplicated key; assert
  `get_versions()` / `is_enabled()` exits non-zero with a clear error message naming the file and key.
- **CI gate test.** Fixture before/after central `sandbox.conf` pairs — one purely additive (must pass
  `check-sandbox-version.sh --check` silently), one with a key removed but no new hook / version bump
  (must fail with a clear message naming the missing key).

## Out of scope (YAGNI)

- **The per-project generated launcher (`<project>-container.sh`).** It has an analogous
  "template evolves, existing copies go stale" problem — e.g. if the launcher template later gains a
  new exported variable, already-initialized projects' launchers don't get it, and nothing re-syncs
  them. This was **considered during brainstorming and deliberately deferred** to a possible future
  design; this design is scoped to `sandbox.conf` only. Recorded here so a future reader knows it was
  a conscious choice, not an oversight.
- **Snapshot-per-version files and any line-based 3-way merge** — rejected (see *Design history*).
- **Re-threading synced-in keys into their original sections** — new keys land under one banner at the
  end (section 3).
- **Automatic detection of same-key semantic drift** — not tooling-detectable; covered by review and
  the `AGENTS.md` rule (see *Edge cases*).
