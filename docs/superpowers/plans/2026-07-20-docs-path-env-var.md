# DOCS_PATH Read-Only Mount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reintroduce `DOCS_PATH` as a read-only host-path pointer that mounts a product-documentation repo at `/workspace/docs` for grounding, plus a consolidated `qmd` nudge and a `project-init.sh` auto-unset guard.

**Architecture:** `DOCS_PATH` mirrors the existing `SPECS_PATH` block in `runme.sh` but mounts `:ro`. A single consolidated `qmd=OFF` warning replaces the vault-only one. `project-init.sh` writes `unset DOCS_PATH` into a generated launcher when the project being initialized *is* the host's `$DOCS_PATH` repo. Verified by a fake-`docker` integration harness (no existing test framework).

**Tech Stack:** Bash (`runme.sh`, `project-init.sh`, `sandbox-common.sh`), Docker CLI, Markdown docs.

## Global Constraints

- Mount point is the fixed path `/workspace/docs`; access mode is read-only (`:ro`). Copy these verbatim.
- Re-export inside the container as `-e DOCS_PATH=/workspace/docs`.
- Missing directory → `WARNING` and continue. Name `docs` already claimed by `REPOS`/`EXTRA_MOUNTS`/primary → `ERROR` and `exit 1`.
- No workdir interception and no `:ro`/`:rw` suffix — writability comes only from mounting the docs repo as the working directory.
- The `qmd` warning is one consolidated message across `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH`; it replaces the inline vault-only warning.
- Edit canonical files only. `CLAUDE.md`, `.github/copilot-instructions.md`, `.kiro/steering/AGENTS.md` are symlinks to `AGENTS.md` — never edit them directly. Never hand-edit the `.ai-containers/` synced copy of `runme.sh`.
- Work stays on branch `docs-path-env-var`. Commit after every task.
- Match the existing `SPECS_PATH` code style exactly; edits are surgical.

---

### Task 1: `DOCS_PATH` read-only mount in `runme.sh`

**Files:**
- Modify: `runme.sh` (new docs block after the SPECS block ~line 546; docker-run wiring ~lines 695/700; usage text ~line 98; mount-layout header comment ~lines 30-32)
- Create: `tests/test-docs-path.sh`

**Interfaces:**
- Consumes: `resolve_path` (from `sandbox-common.sh`), the `repos_used` associative array (populated by the primary/`EXTRA_MOUNTS`/`REPOS` blocks earlier in `run_container`), and the `$DOCS_PATH` environment variable.
- Produces: shell arrays `docs_mount_flags` and `docs_env_args`, expanded into the `docker run` invocation. Mount flag form: `-v <real>:/workspace/docs:ro`. Env form: `-e DOCS_PATH=/workspace/docs`.

- [ ] **Step 1: Write the failing test harness + cases**

Create `tests/test-docs-path.sh`:

```bash
#!/usr/bin/env bash
# Integration tests for DOCS_PATH handling in runme.sh.
# Uses a fake `docker` on PATH to capture the assembled `docker run` args
# without launching a container.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export AI_CONTAINER_GROUP_INIT=clean   # non-interactive group bootstrap
  CAPTURE="$TMP/docker-args.txt"; : > "$CAPTURE"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAPTURE"; exit 0; fi
exit 1
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH"
}
teardown() { rm -rf "$TMP"; unset DOCS_PATH EXTRA_MOUNTS SANDBOX_CONF; }

# run runme.sh restricted <primary>; sets RC and writes stderr to $ERR.
run_runme() {
  ERR="$TMP/stderr.txt"
  ( cd "$REPO_DIR" && ./runme.sh restricted "$@" ) >"$TMP/stdout.txt" 2>"$ERR" </dev/null
  RC=$?
}

# Case 1: DOCS_PATH set, dir exists, not primary → :ro mount + env re-export.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
export DOCS_PATH="$TMP/mydocs"
run_runme "$TMP/app"
if grep -q "/workspace/docs:ro" "$CAPTURE" && grep -qx "DOCS_PATH=/workspace/docs" "$CAPTURE"; then
  pass "ro mount + env re-export"; else fail "ro mount + env re-export"; fi
teardown

# Case 2: DOCS_PATH set to a missing dir → WARNING, no docs mount.
setup
mkdir -p "$TMP/app"
export DOCS_PATH="$TMP/nope"
run_runme "$TMP/app"
if grep -q "WARNING: DOCS_PATH is set but directory does not exist" "$ERR" \
   && ! grep -q "/workspace/docs:ro" "$CAPTURE"; then
  pass "missing dir → warning, no mount"; else fail "missing dir → warning, no mount"; fi
teardown

# Case 3: name 'docs' already claimed (EXTRA_MOUNTS) → collision error, non-zero exit.
setup
mkdir -p "$TMP/docs" "$TMP/mydocs" "$TMP/app"
export EXTRA_MOUNTS="$TMP/docs"
export DOCS_PATH="$TMP/mydocs"
run_runme "$TMP/app"
if [[ $RC -ne 0 ]] && grep -q "name 'docs' is used by" "$ERR"; then
  pass "collision on docs → error"; else fail "collision on docs → error"; fi
teardown

# Case 4: docs repo passed as primary (non-docs basename) → coexists ro + rw.
setup
mkdir -p "$TMP/productdocs"
export DOCS_PATH="$TMP/productdocs"
run_runme "$TMP/productdocs"
if grep -q "/workspace/productdocs:rw" "$CAPTURE" && grep -q "/workspace/docs:ro" "$CAPTURE"; then
  pass "primary + DOCS coexist (ro + rw)"; else fail "primary + DOCS coexist (ro + rw)"; fi
teardown

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-docs-path.sh`
Expected: FAIL on "ro mount + env re-export", "collision on docs → error", and "primary + DOCS coexist" (DOCS_PATH is currently ignored). "missing dir → warning" also fails (no warning emitted). Non-zero exit.

- [ ] **Step 3: Add the DOCS_PATH block to `runme.sh`**

Immediately after the `SPECS_PATH` block (after `runme.sh:546`, the line `  fi` that closes the specs block), insert:

```bash

  # ── Docs repo → /workspace/docs (read-only) ──────────────────────────────────
  local docs_mount_flags=()
  local docs_env_args=()
  if [[ -n "${DOCS_PATH:-}" ]]; then
    local docs_real
    docs_real="$(resolve_path "${DOCS_PATH/#\~/$HOME}")"
    if [[ -d "$docs_real" ]]; then
      if [[ -n "${repos_used[docs]:-}" ]]; then
        printf "ERROR: name 'docs' is used by %s, but DOCS_PATH also mounts at /workspace/docs.\n" "${repos_used[docs]}" >&2
        exit 1
      fi
      docs_mount_flags+=(-v "$docs_real:/workspace/docs:ro")
      docs_env_args+=(-e DOCS_PATH=/workspace/docs)
    else
      printf 'WARNING: DOCS_PATH is set but directory does not exist: %s\n' "$DOCS_PATH" >&2
    fi
  fi
```

- [ ] **Step 4: Wire the docs flags into `docker run`**

In the `docker run` invocation, add the docs env args immediately after the `specs_env_args` line (`runme.sh:695`):

```bash
    ${specs_env_args[@]+"${specs_env_args[@]}"} \
    ${docs_env_args[@]+"${docs_env_args[@]}"} \
```

and add the docs mount flags immediately after the `specs_mount_flags` line (`runme.sh:700`):

```bash
    ${specs_mount_flags[@]+"${specs_mount_flags[@]}"} \
    ${docs_mount_flags[@]+"${docs_mount_flags[@]}"} \
```

- [ ] **Step 5: Add the usage-text entry**

After the `SPECS_PATH` usage entry (`runme.sh:98`), insert:

```
  DOCS_PATH           Host product-documentation repo mounted READ-ONLY at /workspace/docs
                      (also re-exported as DOCS_PATH=/workspace/docs inside the container).
                      To edit docs, mount the repo as the working dir instead.
```

- [ ] **Step 6: Update the mount-layout header comment**

Replace the header comment at `runme.sh:30-32`:

```
Everything is mounted under the /workspace umbrella: REPOS at /workspace/<name>,
EXTRA_MOUNTS at /workspace/<basename>, the Obsidian vault at /workspace/obsidian,
the specs repo at /workspace/specs.
```

with:

```
Everything is mounted under the /workspace umbrella: REPOS at /workspace/<name>,
EXTRA_MOUNTS at /workspace/<basename>, the Obsidian vault at /workspace/obsidian,
the specs repo at /workspace/specs, the docs repo (read-only) at /workspace/docs.
```

- [ ] **Step 7: Syntax-check and run the test to verify it passes**

Run: `bash -n runme.sh && bash tests/test-docs-path.sh`
Expected: `bash -n` clean; all four cases print `PASS`; `0 failure(s)`; exit 0.

- [ ] **Step 8: Commit**

```bash
git add runme.sh tests/test-docs-path.sh
git commit -m "feat: mount DOCS_PATH read-only at /workspace/docs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Consolidated `qmd` nudge + `SANDBOX_CONF` test hook

**Files:**
- Modify: `sandbox-common.sh:30` (config-file override hook)
- Modify: `runme.sh` (declare `qmd_corpora`; append in the vault/specs/docs blocks; remove the inline vault warning ~lines 522-524; add the consolidated warning after the docs block; generalize the vault usage line ~line 96)
- Modify: `tests/test-docs-path.sh` (append qmd cases)

**Interfaces:**
- Consumes: `is_enabled` (from `sandbox-common.sh`), the successful-mount paths of the vault/specs/docs blocks.
- Produces: a `qmd_corpora` array of corpus names (`VAULT_PATH`, `SPECS_PATH`, `DOCS_PATH`); one consolidated stderr warning when it is non-empty and `qmd` is disabled. `is_enabled` now reads `${SANDBOX_CONF:-<script_dir>/sandbox.conf}`.

- [ ] **Step 1: Write the failing qmd test cases**

Append to `tests/test-docs-path.sh`, before the final `printf '\n%d failure(s)\n'` line:

```bash
# Case 5: qmd=OFF (repo default) + DOCS mounted → exactly one warning naming DOCS_PATH.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
export DOCS_PATH="$TMP/mydocs"
run_runme "$TMP/app"
if grep -q "qmd=OFF in sandbox.conf, but markdown corpora are mounted (DOCS_PATH)" "$ERR" \
   && [[ "$(grep -c 'qmd=OFF' "$ERR")" -eq 1 ]]; then
  pass "qmd=OFF → one consolidated warning"; else fail "qmd=OFF → one consolidated warning"; fi
teardown

# Case 6: qmd=ON (via SANDBOX_CONF) + DOCS mounted → no qmd warning.
setup
mkdir -p "$TMP/mydocs" "$TMP/app"
sed 's/^qmd=.*/qmd=ON/' "$REPO_DIR/sandbox.conf" > "$TMP/conf-on"
export SANDBOX_CONF="$TMP/conf-on"
export DOCS_PATH="$TMP/mydocs"
run_runme "$TMP/app"
if ! grep -q "qmd=OFF" "$ERR"; then
  pass "qmd=ON → no warning"; else fail "qmd=ON → no warning"; fi
teardown

# Case 7: no corpus mounted → no qmd warning.
setup
mkdir -p "$TMP/app"
run_runme "$TMP/app"
if ! grep -q "qmd=OFF" "$ERR"; then
  pass "no corpus → no warning"; else fail "no corpus → no warning"; fi
teardown
```

- [ ] **Step 2: Run the test to verify the new cases fail**

Run: `bash tests/test-docs-path.sh`
Expected: Case 5 FAILS (current message text differs / only fires for the vault) and Case 6 FAILS if `SANDBOX_CONF` is not yet honored. Cases 1-4 still PASS.

- [ ] **Step 3: Add the `SANDBOX_CONF` override hook**

In `sandbox-common.sh:30`, replace:

```bash
config_file="${script_dir}/sandbox.conf"
```

with:

```bash
config_file="${SANDBOX_CONF:-${script_dir}/sandbox.conf}"
```

- [ ] **Step 4: Introduce `qmd_corpora` and populate it in each corpus block**

In `runme.sh`, declare the array on the line directly above the `# ── Obsidian vault → /workspace/obsidian` comment (~line 509):

```bash
  # Corpus names collected for one consolidated qmd nudge (see below).
  local qmd_corpora=()
```

In the vault block, after `vault_env_args+=(-e VAULT_PATH=/workspace/obsidian)` (`runme.sh:521`), add:

```bash
      qmd_corpora+=("VAULT_PATH")
```

Then delete the inline vault warning (`runme.sh:522-524`):

```bash
      if ! is_enabled qmd; then
        printf 'WARNING: VAULT_PATH is set but qmd=OFF in sandbox.conf. Set qmd=ON and rebuild for in-container search.\n' >&2
      fi
```

In the specs block, after `specs_env_args+=(-e SPECS_PATH=/workspace/specs)` (`runme.sh:542`), add:

```bash
      qmd_corpora+=("SPECS_PATH")
```

In the docs block (added in Task 1), after `docs_env_args+=(-e DOCS_PATH=/workspace/docs)`, add:

```bash
      qmd_corpora+=("DOCS_PATH")
```

- [ ] **Step 5: Emit the consolidated warning after the docs block**

Immediately after the docs block's closing `fi` (before the `# ── Group resolution` section), insert:

```bash

  # ── Consolidated qmd search nudge ────────────────────────────────────────────
  # qmd is a single global sandbox.conf toggle, not a per-mount capability, so
  # warn once if any markdown corpus is mounted but in-container search was not
  # baked into the image.
  if [[ ${#qmd_corpora[@]} -gt 0 ]] && ! is_enabled qmd; then
    local qmd_joined
    printf -v qmd_joined '%s, ' "${qmd_corpora[@]}"
    qmd_joined="${qmd_joined%, }"
    printf 'WARNING: qmd=OFF in sandbox.conf, but markdown corpora are mounted (%s). Set qmd=ON and rebuild for in-container search.\n' \
      "$qmd_joined" >&2
  fi
```

- [ ] **Step 6: Generalize the vault usage line**

In `runme.sh:96`, replace:

```
                      Requires qmd=ON in sandbox.conf for in-container search.
```

with:

```
                      qmd=ON in sandbox.conf enables in-container search of mounted markdown corpora.
```

- [ ] **Step 7: Syntax-check and run the full test suite**

Run: `bash -n runme.sh && bash -n sandbox-common.sh && bash tests/test-docs-path.sh`
Expected: `bash -n` clean; all seven cases PASS; `0 failure(s)`.

- [ ] **Step 8: Commit**

```bash
git add runme.sh sandbox-common.sh tests/test-docs-path.sh
git commit -m "feat: consolidate qmd=OFF nudge across vault/specs/docs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `project-init.sh` auto-unset for a docs-repo project

**Files:**
- Modify: `project-init.sh` (launcher block, after the exports ~line 289)
- Create: `tests/test-project-init-docs.sh`

**Interfaces:**
- Consumes: `project_path` (already canonicalized via `cd … && pwd` at `project-init.sh:99`) and `$DOCS_PATH`.
- Produces: a literal `unset DOCS_PATH  # …` line written into the generated launcher when the resolved `$DOCS_PATH` equals `project_path`; nothing otherwise.

- [ ] **Step 1: Write the failing test**

Create `tests/test-project-init-docs.sh`:

```bash
#!/usr/bin/env bash
# Tests that project-init.sh writes `unset DOCS_PATH` into a generated launcher
# only when the project being initialized is the host's $DOCS_PATH docs repo.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Back up projects.conf so registration side effects are reverted.
CONF="$REPO_DIR/projects.conf"
CONF_BAK="$(mktemp)"; [[ -f "$CONF" ]] && cp "$CONF" "$CONF_BAK"
restore_conf() { [[ -f "$CONF_BAK" ]] && cp "$CONF_BAK" "$CONF" || rm -f "$CONF"; rm -f "$CONF_BAK"; }
trap restore_conf EXIT

# Drive project-init.sh non-interactively. Answers, in order:
#   project path, name, image, cpus, memory, reservation, memory+swap, group,
#   group-init (2 = clean, shown because a fresh HOME has no 'default' group),
#   extra-mounts.
run_init() {
  local projdir="$1"
  local input="$projdir"$'\n\n\n\n\n\n\n\n2\n\n'
  printf '%s' "$input" | ( cd "$REPO_DIR" && ./project-init.sh ) >/dev/null 2>&1
}

# Match case: project IS $DOCS_PATH → launcher contains `unset DOCS_PATH`.
TMP="$(mktemp -d)"; export HOME="$TMP/home"; mkdir -p "$HOME"
proj="$TMP/dynatrace-docs"; mkdir -p "$proj"
export DOCS_PATH="$proj"
run_init "$proj"
launcher="$(ls "$proj"/.ai-containers/*-container.sh 2>/dev/null | head -1)"
if [[ -n "$launcher" ]] && grep -q '^unset DOCS_PATH' "$launcher"; then
  pass "match → unset DOCS_PATH written"; else fail "match → unset DOCS_PATH written"; fi
rm -rf "$TMP"; unset DOCS_PATH

# Non-match case: project != $DOCS_PATH → no `unset DOCS_PATH`.
TMP="$(mktemp -d)"; export HOME="$TMP/home"; mkdir -p "$HOME"
proj="$TMP/app"; mkdir -p "$proj"; mkdir -p "$TMP/somewhere-else"
export DOCS_PATH="$TMP/somewhere-else"
run_init "$proj"
launcher="$(ls "$proj"/.ai-containers/*-container.sh 2>/dev/null | head -1)"
if [[ -n "$launcher" ]] && ! grep -q '^unset DOCS_PATH' "$launcher"; then
  pass "non-match → no unset"; else fail "non-match → no unset"; fi
rm -rf "$TMP"; unset DOCS_PATH

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-project-init-docs.sh`
Expected: FAIL on "match → unset DOCS_PATH written" (no such line yet). "non-match → no unset" PASSES vacuously. Non-zero exit.

- [ ] **Step 3: Emit the `unset` line in the launcher**

In `project-init.sh`, inside the `if (( write_launcher )); then { … } > "$launch_script"` block, between the `[[ -n "$extra_mounts" ]] && printf …` line (`project-init.sh:289`) and the following `cat <<'EOF'` (`project-init.sh:290`), insert:

```bash
    # If this project IS the host's $DOCS_PATH docs repo, unset DOCS_PATH so the
    # read-only /workspace/docs grounding mount does not collide with (or
    # duplicate) the docs repo mounted here as the working dir.
    if [[ -n "${DOCS_PATH:-}" ]]; then
      docs_real="$(cd "${DOCS_PATH/#\~/$HOME}" 2>/dev/null && pwd || true)"
      if [[ -n "$docs_real" && "$docs_real" == "$project_path" ]]; then
        printf 'unset DOCS_PATH  # this project IS your $DOCS_PATH docs repo; mounted here as the working dir\n'
      fi
    fi
```

- [ ] **Step 4: Syntax-check and run the test to verify it passes**

Run: `bash -n project-init.sh && bash tests/test-project-init-docs.sh`
Expected: `bash -n` clean; both cases PASS; `0 failure(s)`.

- [ ] **Step 5: Commit**

```bash
git add project-init.sh tests/test-project-init-docs.sh
git commit -m "feat: project-init unsets DOCS_PATH for a docs-repo project

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Documentation (`AGENTS.md`, `README.md`, `CHANGELOG.md`)

**Files:**
- Modify: `AGENTS.md` (env-var table row after `SPECS_PATH` ~line 108; host-pointer paragraph ~lines 91-92; mount-layout list ~line 141)
- Modify: `README.md` (env-var table row after `SPECS_PATH` ~line 158; host-pointer paragraph ~line 130; new subsection ~line 550; replace removal note ~line 549; generalize qmd note ~line 547)
- Modify: `CHANGELOG.md` (new "Added" entry; drop the stale "`DOCS_PATH` remains removed" clause in the existing `SPECS_PATH` entry)

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: user-facing docs describing `DOCS_PATH` — read-only mount at `/workspace/docs`, the edit-via-workdir pattern, the docs-repo `unset` guidance, and the consolidated `qmd` note.

- [ ] **Step 1: Add the `AGENTS.md` env-var table row**

After the `SPECS_PATH` table row (`AGENTS.md:108`), insert:

```
| `DOCS_PATH` | Host product-documentation repo mounted **read-only** at `/workspace/docs`, re-exported as `DOCS_PATH=/workspace/docs`. Grounding for plugin workflows (idea / VI / release-notes). To edit docs, mount the repo as the working dir instead; if the working dir *is* this docs repo, unset it (`project-init.sh` does so automatically) to avoid the `/workspace/docs` name collision. | host `$DOCS_PATH` export | → `/workspace/docs` |
```

- [ ] **Step 2: Extend the `AGENTS.md` host-pointer paragraph**

In `AGENTS.md:91-92`, replace:

```
no env var inside), **—** (launcher/`docker run` only). `VAULT_PATH`/`SPECS_PATH` are
host-directory pointers meant to be exported once in the host profile; their effective default is
```

with:

```
no env var inside), **—** (launcher/`docker run` only). `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH` are
host-directory pointers meant to be exported once in the host profile; their effective default is
```

- [ ] **Step 3: Add the `AGENTS.md` mount-layout row**

After the `SPECS_PATH → /workspace/specs` list item (`AGENTS.md:141`), insert:

```
- `DOCS_PATH` → `/workspace/docs` (read-only)
```

- [ ] **Step 4: Add the `README.md` env-var table row**

After the `SPECS_PATH` table row (`README.md:158`), insert the identical row from Step 1:

```
| `DOCS_PATH` | Host product-documentation repo mounted **read-only** at `/workspace/docs`, re-exported as `DOCS_PATH=/workspace/docs`. Grounding for plugin workflows (idea / VI / release-notes). To edit docs, mount the repo as the working dir instead; if the working dir *is* this docs repo, unset it (`project-init.sh` does so automatically) to avoid the `/workspace/docs` name collision. | host `$DOCS_PATH` export | → `/workspace/docs` |
```

- [ ] **Step 5: Extend the `README.md` host-pointer paragraph**

In `README.md:130`, replace:

```
`VAULT_PATH` and `SPECS_PATH` are designed for the profile-export pattern: point them once at
```

with:

```
`VAULT_PATH`, `SPECS_PATH`, and `DOCS_PATH` are designed for the profile-export pattern: point them once at
```

- [ ] **Step 6: Replace the `README.md` removal note and generalize the qmd note**

In `README.md:547`, replace:

```
When `VAULT_PATH` is set, set `qmd=ON` in `sandbox.conf` and rebuild — `runme.sh` warns at startup if the vault is mounted but qmd was not baked into the image. `qmd` is the on-device markdown search engine [@tobilu/qmd](https://github.com/tobi/qmd), installed globally via npm.
```

with:

```
When any markdown corpus (`VAULT_PATH`, `SPECS_PATH`, or `DOCS_PATH`) is mounted, set `qmd=ON` in `sandbox.conf` and rebuild — `runme.sh` prints one startup warning naming the mounted corpora if qmd was not baked into the image. `qmd` is the on-device markdown search engine [@tobilu/qmd](https://github.com/tobi/qmd), installed globally via npm.
```

In `README.md:549`, replace the removal note:

```
> The previous `DOCS_PATH` (`/docs`) mount has been removed. Keep documentation inside a repo (mounted under `/workspace`) or in the Obsidian vault. (`SPECS_PATH` now mounts at `/workspace/specs` — see the next section.)
```

with:

```
## Mounting a docs repository (read-only)

Set `DOCS_PATH` to a host product-documentation repo (e.g. `dynatrace-docs`) to mount it **read-only** at `/workspace/docs`. It is re-exported as `DOCS_PATH=/workspace/docs` inside the container, so grounding workflows — creating an idea, creating or updating a Value Increment, writing Release Notes — resolve existing documentation at a stable path without being able to modify it.

```bash
DOCS_PATH=/path/to/docs \
./runme.sh restricted /path/to/repo
```

Export `DOCS_PATH` in your host shell profile to make it the default for every container, exactly as with `VAULT_PATH` / `SPECS_PATH`.

To **edit** the docs instead of reading them, mount the docs repo as the working directory (a host-path primary, or an `@docs` repo volume). It becomes writable at its own mount point, and you write via the working dir — `$DOCS_PATH` stays read-only at `/workspace/docs`. If the working dir *is* the same repo as `$DOCS_PATH`, unset `DOCS_PATH` for that run to avoid the `/workspace/docs` name collision; `project-init.sh` writes `unset DOCS_PATH` into a generated launcher automatically when it detects the project is your `$DOCS_PATH`.
```

- [ ] **Step 7: Update `CHANGELOG.md`**

In the existing `SPECS_PATH` "Added" entry (`CHANGELOG.md`), replace the trailing clause:

```
now correctly placed under the `/workspace` umbrella with env re-export and a name-collision guard; `DOCS_PATH` remains removed.
```

with:

```
now correctly placed under the `/workspace` umbrella with env re-export and a name-collision guard.
```

Then add a new entry at the top of the `### Added` list:

```
- **`DOCS_PATH` mounts a product-documentation repo read-only at `/workspace/docs`.** Set `DOCS_PATH` to a host docs repo (e.g. `dynatrace-docs`) and `runme.sh` bind-mounts it **read-only** at `/workspace/docs` and re-exports `DOCS_PATH=/workspace/docs`, so grounding workflows (idea / VI / release-notes) resolve existing documentation at a stable path they cannot modify. To edit docs, mount the repo as the working dir instead. The `qmd=OFF` startup warning is now consolidated into one message naming all mounted markdown corpora (vault / specs / docs), replacing the vault-only warning. `project-init.sh` writes `unset DOCS_PATH` into a generated launcher when the project being initialized is the host's `$DOCS_PATH` repo, so a `docs`-named working-dir volume does not collide with the grounding mount. This re-introduces the previously removed `DOCS_PATH`, now under the `/workspace` umbrella, read-only, with env re-export and a name-collision guard.
```

- [ ] **Step 8: Verify the doc edits**

Run:
```bash
grep -c "DOCS_PATH" AGENTS.md README.md CHANGELOG.md
grep -q "Mounting a docs repository" README.md && echo "subsection OK"
! grep -q "previous .DOCS_PATH.*has been removed" README.md && echo "removal note gone"
! grep -q "DOCS_PATH. remains removed" CHANGELOG.md && echo "changelog clause gone"
```
Expected: each file's `DOCS_PATH` count is ≥ 1; `subsection OK`; `removal note gone`; `changelog clause gone`.

- [ ] **Step 9: Commit**

```bash
git add AGENTS.md README.md CHANGELOG.md
git commit -m "docs: document read-only DOCS_PATH mount and consolidated qmd nudge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Line numbers are approximate anchors.** Match on the quoted surrounding text, not the number — earlier tasks do not shift the anchors of later ones because each task edits distinct regions.
- **Do not edit** `CLAUDE.md`, `.github/copilot-instructions.md`, `.kiro/steering/AGENTS.md` (symlinks to `AGENTS.md`) or the `.ai-containers/` synced copy of `runme.sh`. `sync-to-projects.sh` propagates `runme.sh` to project copies; that is out of scope here.
- **If a runme test hangs**, the group bootstrap prompt was reached — confirm `AI_CONTAINER_GROUP_INIT=clean` is exported and `runme.sh` is invoked with `</dev/null` (both already in the harness).
- After all tasks, the full check is: `bash tests/test-docs-path.sh && bash tests/test-project-init-docs.sh`.
