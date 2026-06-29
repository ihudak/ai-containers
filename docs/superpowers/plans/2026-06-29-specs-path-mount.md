# `$SPECS_PATH` Mount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-introduce a `SPECS_PATH` host-path env var in `runme.sh` that bind-mounts a host specs/design/plans repo read-write at `/workspace/specs` and re-exports `SPECS_PATH=/workspace/specs` into the container, mirroring `VAULT_PATH`.

**Architecture:** Pure `runme.sh` (bash) change plus docs. `SPECS_PATH`/`DOCS_PATH` existed previously (mounted at top-level `/specs`) and were removed on 2026-06-12 during the `/workspace`-umbrella consolidation; this re-introduces **only** `SPECS_PATH`, correctly this time — under the umbrella at `/workspace/specs`, with env re-export and a name-collision guard (the old version had neither). `DOCS_PATH` stays removed. The new block is a structural clone of the existing Obsidian-vault block.

**Tech Stack:** Bash, Docker CLI. No test framework exists in this repo (no bats, no shellcheck); verification is `bash -n` plus a self-contained stubbed-`docker` smoke test run from the scratchpad.

## Global Constraints

- Match the existing `VAULT_PATH` code style exactly; new code is a structural clone of the vault block (`runme.sh:506-525`, `:672`, `:676`).
- `AGENTS.md` is the **canonical** instruction file; `CLAUDE.md`, `.github/copilot-instructions.md`, and `.kiro/steering/AGENTS.md` are symlinks that update automatically — edit `AGENTS.md` only.
- Mount mode is read-write (`:rw`). In-container path is the fixed string `/workspace/specs`. Re-exported env var is `SPECS_PATH=/workspace/specs`.
- No new `sandbox.conf` component, no `qmd` coupling/warning, no read-only variant, no `REPOS` auto-registration. Existence-check warning only.
- Use the scratchpad dir for the test script: `/private/tmp/claude-502/-Users-ivan-gudak-dev-ai-tools-ai-containers/babf2c1a-e9a3-4724-b0b1-be0b1f2eb517/scratchpad`. Do not commit the test script (repo has no test convention).

---

### Task 1: Re-introduce `SPECS_PATH` in `runme.sh`

**Files:**
- Modify: `runme.sh:31` (header mount-layout comment)
- Modify: `runme.sh:89-95` (usage text — add `SPECS_PATH` after the `VAULT_PATH` entry)
- Modify: `runme.sh:311-313` (narrow the removal note to `DOCS_PATH` only)
- Modify: `runme.sh` after the Obsidian-vault block (`:525`) — add the specs block
- Modify: `runme.sh:672` and `:676` (add specs flags to `docker run`)
- Test: `<scratchpad>/test-specs-path.sh` (not committed)

**Interfaces:**
- Consumes: existing helpers `resolve_path`, the `repos_used` associative array, and the `docker run` flag-array idiom `${arr[@]+"${arr[@]}"}`.
- Produces: two bash arrays `specs_mount_flags` / `specs_env_args` populated inside `run_container`, spliced into the final `docker run`. Behavior contract: when `SPECS_PATH` points to an existing dir, the assembled `docker run` contains `-v <real>:/workspace/specs:rw` and `-e SPECS_PATH=/workspace/specs`; the `DOCS_PATH/SPECS_PATH ... removed` note no longer fires for `SPECS_PATH`.

- [ ] **Step 1: Write the failing smoke test**

Create `<scratchpad>/test-specs-path.sh` (replace `REPO` with the absolute repo path `/Users/ivan.gudak/dev/ai-tools/ai-containers`):

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO=/Users/ivan.gudak/dev/ai-tools/ai-containers
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
specs="$tmp/specs"; launch="$tmp/launch"; bin="$tmp/bin"
mkdir -p "$specs" "$launch" "$bin"

# Stub docker: record args to $DOCKER_LOG, print nothing to stdout, succeed.
cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
exit 0
STUB
chmod +x "$bin/docker"
export DOCKER_LOG="$tmp/docker.log"; : >"$DOCKER_LOG"

run() { # $1 = SPECS_PATH value
  : >"$DOCKER_LOG"
  PATH="$bin:$PATH" \
  AGENT_REBUILD_MAX_AGE_HOURS=0 \
  AI_CONTAINER_GROUP=specsphtest AI_CONTAINER_GROUP_INIT=clean \
  SPECS_PATH="$1" \
  bash "$REPO/runme.sh" restricted >"$tmp/out.log" 2>"$tmp/err.log" || true
}

fail() { echo "FAIL: $1"; echo "--- stderr ---"; cat "$tmp/err.log"; echo "--- docker ---"; cat "$DOCKER_LOG"; exit 1; }

# Positive: existing dir → mount + env present, no removal note.
run "$specs"
grep -q -- "-v $specs:/workspace/specs:rw" "$DOCKER_LOG" || fail "specs mount missing"
grep -q -- "-e SPECS_PATH=/workspace/specs" "$DOCKER_LOG"  || fail "specs env missing"
grep -qi "SPECS_PATH .*removed\|DOCS_PATH/SPECS_PATH" "$tmp/err.log" && fail "stale removal note still fires for SPECS_PATH"

# Negative: missing dir → warning, no mount.
run "$tmp/does-not-exist"
grep -q "SPECS_PATH is set but directory does not exist" "$tmp/err.log" || fail "missing-dir warning absent"
grep -q -- "/workspace/specs" "$DOCKER_LOG" && fail "specs mounted despite missing dir"

echo "PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash <scratchpad>/test-specs-path.sh`
Expected: `FAIL: specs mount missing` (the feature does not exist yet; the removal note also still fires).

- [ ] **Step 3: Narrow the removal note to `DOCS_PATH` only**

In `runme.sh`, replace the block at lines 311-313:

```bash
  if [[ -n "${DOCS_PATH:-}" || -n "${SPECS_PATH:-}" ]]; then
    echo "Note: DOCS_PATH/SPECS_PATH have been removed and are ignored. Keep docs/specs in a repo or the Obsidian vault." >&2
  fi
```

with:

```bash
  if [[ -n "${DOCS_PATH:-}" ]]; then
    echo "Note: DOCS_PATH has been removed and is ignored. Keep docs in a repo or the Obsidian vault." >&2
  fi
```

- [ ] **Step 4: Add the specs mount block after the Obsidian-vault block**

In `runme.sh`, immediately after the vault block (the line `  fi` that closes it at `:525`, just before the `# ── Group resolution ──` comment), insert:

```bash

  # ── Specs repo → /workspace/specs ────────────────────────────────────────────
  local specs_mount_flags=()
  local specs_env_args=()
  if [[ -n "${SPECS_PATH:-}" ]]; then
    local specs_real
    specs_real="$(resolve_path "${SPECS_PATH/#\~/$HOME}")"
    if [[ -d "$specs_real" ]]; then
      if [[ -n "${repos_used[specs]:-}" ]]; then
        printf "ERROR: name 'specs' is used by %s, but SPECS_PATH also mounts at /workspace/specs.\n" "${repos_used[specs]}" >&2
        exit 1
      fi
      specs_mount_flags+=(-v "$specs_real:/workspace/specs:rw")
      specs_env_args+=(-e SPECS_PATH=/workspace/specs)
    else
      printf 'WARNING: SPECS_PATH is set but directory does not exist: %s\n' "$SPECS_PATH" >&2
    fi
  fi
```

- [ ] **Step 5: Splice the specs flags into `docker run`**

In `runme.sh`, after the `vault_env_args` line (`:672`):

```bash
    ${vault_env_args[@]+"${vault_env_args[@]}"} \
```

add directly below it:

```bash
    ${specs_env_args[@]+"${specs_env_args[@]}"} \
```

Then after the `vault_mount_flags` line (`:676`):

```bash
    ${vault_mount_flags[@]+"${vault_mount_flags[@]}"} \
```

add directly below it:

```bash
    ${specs_mount_flags[@]+"${specs_mount_flags[@]}"} \
```

- [ ] **Step 6: Update the usage text**

In `runme.sh`, after the three `VAULT_PATH` usage lines (`:93-95`, the last being `                      Requires qmd=ON in sandbox.conf for in-container search.`), insert:

```bash
  SPECS_PATH          Host specs/design/plans repo mounted at /workspace/specs (also
                      re-exported as SPECS_PATH=/workspace/specs inside the container).
```

- [ ] **Step 7: Update the header mount-layout comment**

In `runme.sh`, replace line 31:

```bash
EXTRA_MOUNTS at /workspace/<basename>, the Obsidian vault at /workspace/obsidian.
```

with:

```bash
EXTRA_MOUNTS at /workspace/<basename>, the Obsidian vault at /workspace/obsidian,
the specs repo at /workspace/specs.
```

- [ ] **Step 8: Verify the script still parses**

Run: `bash -n /Users/ivan.gudak/dev/ai-tools/ai-containers/runme.sh`
Expected: no output, exit 0.

- [ ] **Step 9: Run the smoke test to verify it passes**

Run: `bash <scratchpad>/test-specs-path.sh`
Expected: `PASS`

- [ ] **Step 10: Commit**

```bash
git add runme.sh
git commit -m "feat: re-introduce SPECS_PATH mounting host specs repo at /workspace/specs

Mirrors VAULT_PATH: bind-mount read-write and re-export SPECS_PATH into
the container. Narrows the prior removal note to DOCS_PATH only.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Documentation

**Files:**
- Modify: `AGENTS.md:98` (env-var bullet) and `AGENTS.md:126` (mount-layout row)
- Modify: `README.md` (`## Mounting an Obsidian vault` section, ~lines 488-497)
- Modify: `CHANGELOG.md` (`## Unreleased` → `### Added`)
- Modify: `docs/superpowers/specs/2026-06-29-specs-path-mount-design.md` (add re-introduction note)

**Interfaces:**
- Consumes: the behavior contract from Task 1 (mount at `/workspace/specs:rw`, env re-export, existence-check warning).
- Produces: no code; documentation only.

- [ ] **Step 1: Add the `AGENTS.md` env-var bullet**

In `AGENTS.md`, after the `VAULT_PATH` bullet (`:98`), insert a new bullet:

```markdown
- `SPECS_PATH` — host repo of AI-ready specifications, design documents, and development plans, mounted read-write at `/workspace/specs`; also re-exported as `SPECS_PATH=/workspace/specs` inside the container. Consumed by spec-driven workflows (e.g. the dev-workflows plugin). Set it once in your host shell profile to make it the default for every container, the same way `VAULT_PATH` works.
```

- [ ] **Step 2: Add the `AGENTS.md` mount-layout row**

In `AGENTS.md`, after the `VAULT_PATH → /workspace/obsidian` line (`:126`), insert:

```markdown
- `SPECS_PATH` → `/workspace/specs`
```

- [ ] **Step 3: Add the README section and narrow the removal note**

In `README.md`, after the Obsidian-vault section's final paragraph (the `qmd` sentence, before the `> The previous DOCS_PATH...` blockquote), insert a new section:

```markdown
## Mounting a specs repository

Set `SPECS_PATH` to a host repository of AI-ready specifications, design documents, and development plans to mount it at `/workspace/specs` (read-write). It is also re-exported as `SPECS_PATH=/workspace/specs` inside the container so agent skills/workflows that consume the variable — for example the dev-workflows plugin, which reads specs to implement features and writes design docs and plans back — resolve to the in-container mount point.

```bash
SPECS_PATH=/path/to/specs \
./runme.sh restricted /path/to/repo
```

Export `SPECS_PATH` in your host shell profile to make it the default for every container, exactly as with `VAULT_PATH`.
```

Then change the existing blockquote (currently the last line of the section):

```markdown
> The previous `DOCS_PATH` (`/docs`) and `SPECS_PATH` (`/specs`) mounts have been removed. Keep documentation and specs inside a repo (mounted under `/workspace`) or in the Obsidian vault.
```

to:

```markdown
> The previous `DOCS_PATH` (`/docs`) mount has been removed. Keep documentation inside a repo (mounted under `/workspace`) or in the Obsidian vault. (`SPECS_PATH` now mounts at `/workspace/specs` — see above.)
```

- [ ] **Step 4: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `## Unreleased`, add an `### Added` section directly below the `## Unreleased` heading (above the existing `### Fixed`):

```markdown
### Added

- **`SPECS_PATH` mounts a specs/design/plans repo at `/workspace/specs`.** Set `SPECS_PATH` to a host directory and `runme.sh` bind-mounts it read-write at `/workspace/specs` and re-exports `SPECS_PATH=/workspace/specs` inside the container, mirroring `VAULT_PATH`. Spec-driven agent workflows (e.g. the dev-workflows plugin) resolve specifications at a stable path regardless of the host location. Export it in your host shell profile to make it the per-container default. This re-introduces the previously removed `SPECS_PATH`, now correctly placed under the `/workspace` umbrella with env re-export and a name-collision guard; `DOCS_PATH` remains removed.
```

- [ ] **Step 5: Add the re-introduction note to the design spec**

In `docs/superpowers/specs/2026-06-29-specs-path-mount-design.md`, add a short paragraph at the end of the `## Solution` section:

```markdown
**Note — re-introduction:** `SPECS_PATH` (and `DOCS_PATH`) existed previously, mounted at the
top-level `/specs`, and were removed on 2026-06-12 during the `/workspace`-umbrella consolidation.
This re-introduces only `SPECS_PATH`, now under the umbrella at `/workspace/specs` with env
re-export and a name-collision guard (neither of which the old version had). `DOCS_PATH` stays
removed; `runme.sh` and `README.md` narrow their removal notes to `DOCS_PATH` only.
```

- [ ] **Step 6: Verify docs reference the correct path and the symlink resolves**

Run:
```bash
cd /Users/ivan.gudak/dev/ai-tools/ai-containers && \
grep -n "SPECS_PATH" AGENTS.md README.md CHANGELOG.md && \
grep -c "SPECS_PATH" CLAUDE.md
```
Expected: `SPECS_PATH` appears in `AGENTS.md` (2×), `README.md` (≥3×), `CHANGELOG.md` (≥1×), and `CLAUDE.md` count ≥3 (confirms the symlink surfaces the `AGENTS.md` edits).

- [ ] **Step 7: Commit**

```bash
git add AGENTS.md README.md CHANGELOG.md docs/superpowers/specs/2026-06-29-specs-path-mount-design.md
git commit -m "docs: document SPECS_PATH mount (AGENTS, README, CHANGELOG, spec)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- RW mount at `/workspace/specs` → Task 1 Steps 4-5. ✓
- Env re-export `SPECS_PATH=/workspace/specs` → Task 1 Step 4-5. ✓
- Collision guard vs `REPOS`/`EXTRA_MOUNTS` → Task 1 Step 4 (`repos_used[specs]`). ✓
- Existence-check warning, no qmd warning → Task 1 Step 4 (`else` branch only). ✓
- Host-shell default → no code (env read from environment); documented in Task 2 Steps 1,3,4. ✓
- Docs in AGENTS.md, README.md, CHANGELOG.md → Task 2. ✓
- Re-introduction nuance (narrow removal notes) → Task 1 Step 3, Task 2 Step 3, Step 5. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**Type/name consistency:** Array names `specs_mount_flags` / `specs_env_args` and key `repos_used[specs]` are used identically across Task 1 Steps 4, 5, and the test contract. Mount string `/workspace/specs` and env `SPECS_PATH=/workspace/specs` are byte-identical everywhere. ✓
