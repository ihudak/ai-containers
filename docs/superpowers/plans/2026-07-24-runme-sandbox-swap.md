# runme.sh ↔ launcher Naming Swap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the run-the-container engine `runme.sh` → `sandbox.sh`, and rename the per-project launcher `<project>-container.sh` → `runme.sh`, so the imperative name lands on the file users actually run.

**Architecture:** Behavior is unchanged — this is a rename + reference sweep + one-time auto-migration. Authored opensource-first in `/workspace/ai-containers` (Phase A), then ported byte-identically to the three `mgd-ai-containers` presets (Phase B). Existing consumer projects are auto-migrated by `sync-to-projects.sh` using the fact that only a launcher contains `export IMAGE_NAME=<literal>` (the engine never does).

**Tech Stack:** Bash, Docker, `git mv`, `rsync`/`cp`, shell test scripts under `tests/`.

## Global Constraints

- **Opensource-first.** All shared-file changes are authored in `/workspace/ai-containers` first, then copied byte-identically to `mgd-ai-containers` `base/`, `docs/`, `.ai-containers/`. Never edit a shared file in mgd only. (Design §Sequencing)
- **Preserve git history:** rename tracked files with `git mv`, not delete+create.
- **Two renames, exact target names:** engine `runme.sh` → `sandbox.sh`; per-project launcher `<project>-container.sh` → `runme.sh`.
- **Marker fact (verified):** a launcher contains a line matching `^[[:space:]]*export[[:space:]]+IMAGE_NAME=` with a **literal** value; the engine never sets `IMAGE_NAME`. This is the sole discriminator for migration.
- **Leave history alone:** do NOT edit existing CHANGELOG entries or any `docs/superpowers/specs|plans/*` file. Add exactly one NEW CHANGELOG entry per repo.
- **Central vs. consumer:** in the central repo the top-level entry point is the engine run directly (`./sandbox.sh restricted /path`); the `runme.sh` launcher exists only inside consumer projects (emitted by `project-init.sh`). README must reflect both.
- **Green at every boundary:** the `tests/` suite must pass at the end of every task that touches opensource.

---

# Phase A — opensource (`/workspace/ai-containers`)

### Task 1: Rename the engine and repoint every consumer (keep suite green)

**Files:**
- Rename: `runme.sh` → `sandbox.sh`
- Modify: `sandbox.sh` (self-refs), `build.sh:33,313`, `repo.sh:11-12,41-42,45,52,59,235,239,260`, `sandbox-common.sh:2,30,42,150`, `Dockerfile`, `sandbox.conf` (comment), `.dockerignore`, `.gitignore`, `allowlist-domains.d/base.txt`
- Modify tests: `tests/test-docs-path.sh`, `tests/test-tools-d.sh`, `tests/test-sandbox-schema.sh`

**Interfaces:**
- Produces: an executable `sandbox.sh` with identical CLI (`sandbox.sh restricted|discovery [primary]`); no `runme.sh` file remains in the repo root.

- [ ] **Step 1: Rename the file (preserve history)**

```bash
cd /workspace/ai-containers
git mv runme.sh sandbox.sh
```

- [ ] **Step 2: Update the engine's own self-references**

In `sandbox.sh`, replace these exact lines (from `grep -n runme sandbox.sh`):

```
4:   # runme.sh — run the AI sandbox container.        → # sandbox.sh — run the AI sandbox container.
53:  ./runme.sh restricted [primary]                   → ./sandbox.sh restricted [primary]
54:  ./runme.sh discovery  [primary]                   → ./sandbox.sh discovery  [primary]
72:  directory where runme.sh is launched ...          → directory where sandbox.sh is launched ...
81:  ... runme.sh offers                               → ... sandbox.sh offers
350: # Host directory where runme.sh was invoked...    → # Host directory where sandbox.sh was invoked...
855: printf 'ERROR: "runme.sh build" has been removed. Use ./build.sh instead.\n' >&2
     → printf 'ERROR: "sandbox.sh build" has been removed. Use ./build.sh instead.\n' >&2
```

Do it mechanically and verify none remain:

```bash
sed -i 's/runme\.sh/sandbox.sh/g' sandbox.sh
grep -n runme sandbox.sh   # expect: no output
```

- [ ] **Step 3: Sweep the other shared scripts and build/config files**

These are all comment/usage references to the engine — a blanket `runme.sh`→`sandbox.sh` is correct in each (none of these files reference the *launcher*):

```bash
cd /workspace/ai-containers
for f in build.sh repo.sh sandbox-common.sh Dockerfile sandbox.conf .dockerignore .gitignore allowlist-domains.d/base.txt; do
  [[ -f "$f" ]] && sed -i 's/runme\.sh/sandbox.sh/g' "$f"
done
grep -rn "runme" build.sh repo.sh sandbox-common.sh Dockerfile sandbox.conf .dockerignore .gitignore allowlist-domains.d/base.txt   # expect: no output
```

- [ ] **Step 4: Update the test suite (invocations + helper name)**

In `tests/test-docs-path.sh` the helper `run_runme()` invokes `./runme.sh`. Rename the helper and repoint the call, plus the file-header comment:

```bash
cd /workspace/ai-containers/tests
sed -i 's/run_runme/run_sandbox/g; s/runme\.sh/sandbox.sh/g' test-docs-path.sh
sed -i 's/runme\.sh/sandbox.sh/g' test-tools-d.sh test-sandbox-schema.sh
grep -rn "runme" .   # expect: no output
```

- [ ] **Step 5: Run the full suite to prove nothing broke**

```bash
cd /workspace/ai-containers
for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || { echo "FAIL $t"; break; }; done
```
Expected: every test prints its PASS summary; no `FAIL`.

- [ ] **Step 6: Commit**

```bash
cd /workspace/ai-containers
git add -A
git commit -m "refactor: rename engine runme.sh -> sandbox.sh

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: Emit the launcher as `runme.sh` calling `./sandbox.sh` (project-init)

**Files:**
- Modify: `project-init.sh:7,247,260,321,341,344,354-355`
- Rename: `.ai-containers/ai-containers-container.sh` → `.ai-containers/runme.sh` (the central repo's own working-copy launcher)

**Interfaces:**
- Consumes: `sandbox.sh` (from Task 1).
- Produces: `project-init.sh` writes `<project>/.ai-containers/runme.sh` whose active command is `./sandbox.sh discovery ..`; its copy list pulls `sandbox.sh` (not `runme.sh`).

- [ ] **Step 1: Write a failing test for the generated launcher**

Create `tests/test-launcher-naming.sh`:

```bash
#!/usr/bin/env bash
# Verifies project-init.sh emits a runme.sh launcher that calls ./sandbox.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
proj="$TMP/myproj"; mkdir -p "$proj"

# Drive project-init non-interactively: register the project dir, accept defaults.
# project-init.sh reads answers from stdin; feed path then blank/confirm lines.
printf '%s\n\n\n\n\ny\n' "$proj" | ( cd "$SCRIPT_DIR" && ./project-init.sh ) >/dev/null 2>&1 || true

launcher="$proj/.ai-containers/runme.sh"
fail=0
[[ -f "$launcher" ]] || { echo "FAIL: launcher not named runme.sh"; fail=1; }
[[ ! -f "$proj/.ai-containers/myproj-container.sh" ]] || { echo "FAIL: legacy <project>-container.sh still emitted"; fail=1; }
grep -q './sandbox.sh' "$launcher" 2>/dev/null || { echo "FAIL: launcher does not call ./sandbox.sh"; fail=1; }
grep -q 'export IMAGE_NAME=' "$launcher" 2>/dev/null || { echo "FAIL: launcher missing IMAGE_NAME marker"; fail=1; }
(( fail == 0 )) && echo "PASS: launcher naming" || exit 1
```

```bash
chmod +x /workspace/ai-containers/tests/test-launcher-naming.sh
```

- [ ] **Step 2: Run it — expect FAIL**

```bash
bash /workspace/ai-containers/tests/test-launcher-naming.sh
```
Expected: `FAIL: launcher not named runme.sh` (and others), non-zero exit.

- [ ] **Step 3: Rename the launcher target and repoint its body in `project-init.sh`**

Apply these exact edits:

```
7:   # ... writes a ready-to-run <project-name>-container.sh   → ... writes a ready-to-run runme.sh launcher
247: launch_script="${dest}/${project_name}-container.sh"      → launch_script="${dest}/runme.sh"
260: for f in ... build.sh runme.sh repo.sh entrypoint.sh \    → for f in ... build.sh sandbox.sh repo.sh entrypoint.sh \
321: # ${project_name}-container.sh — launch the AI sandbox... → # runme.sh — launch the AI sandbox for ${project_name}.
341: #   ./repo.sh add <name> ..   then   ./runme.sh discovery @<name>  → ... then   ./sandbox.sh discovery @<name>
344: # ... runme.sh does NOT forward it                        → # ... sandbox.sh does NOT forward it
354: #./runme.sh restricted ..                                 → #./sandbox.sh restricted ..
355: ./runme.sh discovery ..                                   → ./sandbox.sh discovery ..
```

Comment references to the engine become `sandbox.sh`; the launcher **filename** becomes `runme.sh`. Note line 274/278 comments (`build.sh / runme.sh / repo.sh agree on the image`) are engine references → `sandbox.sh`:

```bash
cd /workspace/ai-containers
# engine references in comments:
sed -i 's#\./runme\.sh#./sandbox.sh#g; s/build\.sh \/ runme\.sh \/ repo\.sh/build.sh \/ sandbox.sh \/ repo.sh/g; s/build\.sh\/runme\.sh\/repo\.sh/build.sh\/sandbox.sh\/repo.sh/g' project-init.sh
# copy-list token (engine file being copied):
sed -i 's/ build\.sh runme\.sh repo\.sh / build.sh sandbox.sh repo.sh /' project-init.sh
```
Then hand-edit lines 7, 247, 321 as shown above (launcher filename/name — NOT a blanket sed, since these become `runme.sh`).
Verify:

```bash
grep -n 'runme\|container.sh' project-init.sh
# Expect: only the launcher heredoc header "# runme.sh — launch..." and launch_script="${dest}/runme.sh".
# No "<project>-container.sh"; no "./runme.sh" (engine calls are now ./sandbox.sh).
```

- [ ] **Step 4: Run the launcher test — expect PASS**

```bash
bash /workspace/ai-containers/tests/test-launcher-naming.sh
```
Expected: `PASS: launcher naming`.

- [ ] **Step 5: Rename the central repo's own working-copy launcher**

```bash
cd /workspace/ai-containers
git mv .ai-containers/ai-containers-container.sh .ai-containers/runme.sh
sed -i 's#\./runme\.sh#./sandbox.sh#g' .ai-containers/runme.sh   # repoint engine calls
grep -n 'runme\|sandbox.sh' .ai-containers/runme.sh              # sanity: calls ./sandbox.sh
```

- [ ] **Step 6: Commit**

```bash
cd /workspace/ai-containers
git add -A
git commit -m "feat: project-init emits runme.sh launcher calling ./sandbox.sh

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: Auto-migrate existing projects in `sync-to-projects.sh` (TDD)

**Files:**
- Modify: `sync-to-projects.sh:13,37,181` and `sync_project()` body (insert migration before the copy loop, ~line 180)
- Test: `tests/test-launcher-migration.sh` (new)

**Interfaces:**
- Consumes: the `export IMAGE_NAME=` marker fact.
- Produces: a function `migrate_launcher_naming <dest>` — idempotent; wired into `sync_project()`. Sourcing `sync-to-projects.sh` (guarded by the existing `BASH_SOURCE`/`return 0` at line 209) exposes it to tests.

- [ ] **Step 1: Write the failing migration test**

Create `tests/test-launcher-migration.sh`:

```bash
#!/usr/bin/env bash
# Verifies sync migrates a pre-swap project (old-engine runme.sh + <proj>-container.sh)
# to (sandbox.sh engine + runme.sh launcher calling ./sandbox.sh), idempotently.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source sync-to-projects.sh for its helpers without running a sync.
# shellcheck disable=SC1090
source "$SCRIPT_DIR/sync-to-projects.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
dest="$TMP/proj/.ai-containers"; mkdir -p "$dest"

# Old engine (marker-less) named runme.sh:
printf '#!/usr/bin/env bash\n# old engine\necho engine\n' > "$dest/runme.sh"
# Old launcher <project>-container.sh (has the IMAGE_NAME marker, calls ./runme.sh):
printf '#!/usr/bin/env bash\nexport IMAGE_NAME=proj-ai-container\n./runme.sh discovery ..\n' > "$dest/proj-container.sh"

migrate_launcher_naming "$dest"

fail=0
grep -q 'export IMAGE_NAME=' "$dest/runme.sh" 2>/dev/null || { echo "FAIL: runme.sh is not the launcher"; fail=1; }
grep -q './sandbox.sh' "$dest/runme.sh" 2>/dev/null       || { echo "FAIL: launcher still calls old engine"; fail=1; }
[[ ! -f "$dest/proj-container.sh" ]]                       || { echo "FAIL: legacy launcher not renamed"; fail=1; }
grep -q 'old engine' "$dest/runme.sh" 2>/dev/null          && { echo "FAIL: stale engine survived as runme.sh"; fail=1; }

# Idempotency: second run must not change anything.
before="$(sha1sum "$dest/runme.sh")"
migrate_launcher_naming "$dest"
after="$(sha1sum "$dest/runme.sh")"
[[ "$before" == "$after" ]] || { echo "FAIL: second migration mutated the launcher"; fail=1; }

(( fail == 0 )) && echo "PASS: launcher migration" || exit 1
```

```bash
chmod +x /workspace/ai-containers/tests/test-launcher-migration.sh
```

- [ ] **Step 2: Run it — expect FAIL**

```bash
bash /workspace/ai-containers/tests/test-launcher-migration.sh
```
Expected: `migrate_launcher_naming: command not found` or a `FAIL:` line, non-zero exit.

- [ ] **Step 3: Add `migrate_launcher_naming()` and wire it in**

In `sync-to-projects.sh`, add the function above `sync_project()` (near the other helpers, before line 209's source-guard so it is exported when sourced):

```bash
# One-time migration for the runme.sh<->launcher naming swap.
# Old layout: runme.sh = engine (no IMAGE_NAME marker), <project>-container.sh = launcher.
# New layout: sandbox.sh = engine,                      runme.sh              = launcher.
# Discriminator: only a launcher sets `export IMAGE_NAME=<literal>`. Idempotent.
migrate_launcher_naming() {
  local dest="$1"

  # 1. Remove a stale old-engine runme.sh (present AND has no IMAGE_NAME marker).
  if [[ -f "${dest}/runme.sh" ]] \
     && ! grep -qE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "${dest}/runme.sh"; then
    rm -f "${dest}/runme.sh"
  fi

  # 2. Rename a legacy <project>-container.sh launcher to runme.sh, unless a
  #    runme.sh launcher (marker-bearing) already exists (already migrated).
  if [[ ! -f "${dest}/runme.sh" ]] \
     || ! grep -qE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "${dest}/runme.sh"; then
    local legacy
    for legacy in "${dest}"/*-container.sh; do
      [[ -e "$legacy" ]] || continue
      if grep -qE '^[[:space:]]*export[[:space:]]+IMAGE_NAME=' "$legacy"; then
        mv "$legacy" "${dest}/runme.sh"
        break
      fi
    done
  fi

  # 3. Repoint the launcher's engine call to ./sandbox.sh (idempotent).
  if [[ -f "${dest}/runme.sh" ]]; then
    sed -i 's#\./runme\.sh#./sandbox.sh#g' "${dest}/runme.sh"
  fi
}
```

Wire it into `sync_project()` immediately before the shared-scripts copy loop (currently line 180, the `# Shared scripts and build files` comment):

```bash
  # Migrate legacy runme.sh<->launcher naming before copying shared files.
  migrate_launcher_naming "$dest"

  # Shared scripts and build files
  for f in Dockerfile Dockerfile.seed .dockerignore sandbox-common.sh build.sh sandbox.sh repo.sh entrypoint.sh \
```

Note the copy list at line 181 changes `runme.sh` → `sandbox.sh`. Also fix the two header comments:

```
13: #   sandbox.conf, sandbox.env, allowlist-*.d/custom.txt, <project>-container.sh, projects.conf
    → #   sandbox.conf, sandbox.env, allowlist-*.d/custom.txt, runme.sh (launcher), projects.conf
37: # ... (launcher names are not always "<name>-container.sh") ...   (leave as-is: still true historically; the scan is by marker, not name)
```
And the engine-reference comment at line 54 (`build.sh / runme.sh / repo.sh agree on the image`) → `sandbox.sh`:

```bash
cd /workspace/ai-containers
sed -i 's/build\.sh \/ runme\.sh \/ repo\.sh/build.sh \/ sandbox.sh \/ repo.sh/g' sync-to-projects.sh
```

- [ ] **Step 4: Run the migration test — expect PASS**

```bash
bash /workspace/ai-containers/tests/test-launcher-migration.sh
```
Expected: `PASS: launcher migration`.

- [ ] **Step 5: Run the whole suite (regression guard)**

```bash
cd /workspace/ai-containers
for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || { echo "FAIL $t"; break; }; done
```
Expected: all PASS, no `FAIL`.

- [ ] **Step 6: Commit**

```bash
cd /workspace/ai-containers
git add -A
git commit -m "feat: auto-migrate legacy runme.sh<->launcher naming on sync

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: Docs framing + CHANGELOG (opensource)

**Files:**
- Modify: `README.md` (scripts list ~52, quick-start ~104-125, project-init section ~848,859, plus mechanical mentions), `AGENTS.md`, `CHANGELOG.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Reframe the README scripts list (line ~52)**

Replace the single engine bullet with an engine bullet + a launcher note:

```
- `runme.sh` runs the container (`restricted` / `discovery`).
```
becomes
```
- `sandbox.sh` runs the container engine (`restricted` / `discovery`). In a consumer project you normally invoke it indirectly through the generated `runme.sh` launcher (see project-init below).
```

- [ ] **Step 2: Reframe the README quick-start (lines ~104-125)**

The central-repo direct-run examples call the engine → change `./runme.sh` to `./sandbox.sh` in both code blocks and the surrounding prose (`launched runme.sh` → `launched sandbox.sh`):

```bash
cd /workspace/ai-containers
sed -i 's#\./runme\.sh#./sandbox.sh#g; s/launched runme\.sh/launched sandbox.sh/g; s/where you launched runme\.sh/where you launched sandbox.sh/g' README.md
```

- [ ] **Step 3: Update the project-init section (lines ~848, ~859) to the runme.sh launcher**

```
848: - Generates `<project>/.ai-containers/<project-name>-container.sh` with `IMAGE_NAME` ...
     → - Generates `<project>/.ai-containers/runme.sh` (the per-project launcher) with `IMAGE_NAME` ...
859: ./<project-name>-container.sh
     → ./runme.sh
```

- [ ] **Step 4: Mechanical sweep of remaining engine mentions in README/AGENTS**

Any residual `runme.sh` in README/AGENTS refers to the engine (all launcher spots handled above) → `sandbox.sh`:

```bash
cd /workspace/ai-containers
sed -i 's/runme\.sh/sandbox.sh/g' README.md AGENTS.md
grep -n 'runme\|<project>-container.sh\|project-name>-container.sh' README.md AGENTS.md
# Expect: no output (launcher now called runme.sh, handled in steps 1-3; step 3 already replaced the <project>-container forms).
```
If step 4's blanket sed touched an intended `runme.sh` launcher mention created in steps 1/3, re-apply those specific launcher lines by hand (they should read `runme.sh`, not `sandbox.sh`). Re-verify:
```bash
grep -n 'runme' README.md   # Expect: only the intended launcher mentions ("runme.sh launcher").
```

- [ ] **Step 5: Add ONE new CHANGELOG breaking-change entry**

At the top of the `CHANGELOG.md` "Unreleased"/latest section, add:

```markdown
- **BREAKING: `runme.sh` renamed, and the per-project launcher reclaims the name.** The run-the-container engine is now **`sandbox.sh`** (same CLI: `restricted` / `discovery`). The generated per-project launcher, previously `<project>-container.sh`, is now **`runme.sh`** — a single, stable entry point across every project. Running `./sync-to-projects.sh` **auto-migrates** existing projects: it removes the old-engine `runme.sh`, renames `<project>-container.sh` to `runme.sh`, and repoints its internal call to `./sandbox.sh` (idempotent). If you invoke the engine directly, use `./sandbox.sh`. Update any aliases, CI, or scripts that referenced `<project>-container.sh` or the old top-level `runme.sh`.
```

- [ ] **Step 6: Full opensource audit + commit**

```bash
cd /workspace/ai-containers
# Live-code audit: no stray engine refs outside history.
grep -rn "runme" --include='*.sh' --include='*.md' --include='Dockerfile*' --include='*.conf' --include='*.txt' . \
  | grep -v 'docs/superpowers/' | grep -v 'CHANGELOG.md' | grep -vE 'runme\.sh (launcher|—|-)' | grep -vE '\.ai-containers/runme\.sh'
# Expect: no output (only launcher mentions + history remain).
for t in tests/test-*.sh; do echo "== $t =="; bash "$t" || { echo "FAIL $t"; break; }; done
git add -A
git commit -m "docs: reframe README/AGENTS on sandbox.sh engine + runme.sh launcher; CHANGELOG

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

# Phase B — port to `mgd-ai-containers`

### Task 5: Port shared files to `base/` and `docs/` (byte-identical)

**Files (mgd):**
- Rename: `base/runme.sh`→`base/sandbox.sh`, `docs/runme.sh`→`docs/sandbox.sh`
- Overwrite from opensource: the shared scripts in `base/` and `docs/`
- Modify per-preset: `base/sandbox.conf`, `docs/sandbox.conf` (engine comment), `base/.gitignore`, `docs/.gitignore`, allowlist `base.txt` comments

**Interfaces:**
- Consumes: the finished opensource shared files.
- Produces: `base/` and `docs/` with `sandbox.sh` engine + updated shared scripts, byte-identical to opensource for the shared surface.

- [ ] **Step 1: git mv the engine in both presets**

```bash
cd /workspace/mgd-ai-containers
git mv base/runme.sh base/sandbox.sh
git mv docs/runme.sh docs/sandbox.sh
```

- [ ] **Step 2: Copy the updated shared scripts from opensource into both presets**

The shared surface must stay byte-identical to opensource. Copy each updated shared file:

```bash
cd /workspace/mgd-ai-containers
OSS=/workspace/ai-containers
for preset in base docs; do
  for f in sandbox.sh build.sh repo.sh sandbox-common.sh project-init.sh sync-to-projects.sh \
           entrypoint.sh install-tools.sh install-agent-skills.sh tools-lib.sh Dockerfile .dockerignore; do
    [[ -f "$OSS/$f" ]] && cp "$OSS/$f" "$preset/$f"
  done
done
```
(If a shared file legitimately differs in mgd for a Dynatrace reason, reconcile by hand rather than clobbering — but per the topology memo the shared scripts are byte-identical.)

- [ ] **Step 3: Sweep per-preset non-shared files that mention the engine**

`sandbox.conf`, `.gitignore`, and the allowlist fragment carry engine comments and differ per preset (don't overwrite them) — sed them:

```bash
cd /workspace/mgd-ai-containers
for f in base/sandbox.conf docs/sandbox.conf base/.gitignore docs/.gitignore \
         base/allowlist-domains.d/base.txt docs/allowlist-domains.d/base.txt; do
  [[ -f "$f" ]] && sed -i 's/runme\.sh/sandbox.sh/g' "$f"
done
```

- [ ] **Step 4: Verify base↔docs shared-surface equality**

```bash
cd /workspace/mgd-ai-containers
./sync-presets.sh --check
```
Expected: exits 0 (no drift on the shared surface, which now includes `sandbox.sh`). If it reports `sandbox.sh` missing from its file set, confirm `sync-presets.sh` derives the list dynamically; if it hardcodes `runme.sh`, update that token to `sandbox.sh` and re-run.

- [ ] **Step 5: Commit**

```bash
cd /workspace/mgd-ai-containers
git add -A
git commit -m "refactor(mgd): rename engine runme.sh -> sandbox.sh in base/ and docs/

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: mgd `.ai-containers/` working copy, docs, CHANGELOG + final audit

**Files (mgd):**
- Rename: `.ai-containers/runme.sh`→`.ai-containers/sandbox.sh` (engine copy) and `.ai-containers/mgd-ai-containers-container.sh`→`.ai-containers/runme.sh` (launcher)
- Overwrite from opensource: `.ai-containers/` shared scripts
- Modify: `base/README.md`, `docs/README.md` (docs preset), `base/AGENTS.md`, `docs/AGENTS.md`, `base/CHANGELOG.md`, `docs/CHANGELOG.md`

**Interfaces:** none downstream.

- [ ] **Step 1: Fix the mgd `.ai-containers/` working copy**

```bash
cd /workspace/mgd-ai-containers
git mv .ai-containers/runme.sh .ai-containers/sandbox.sh                       # engine copy
git mv .ai-containers/mgd-ai-containers-container.sh .ai-containers/runme.sh    # launcher
sed -i 's#\./runme\.sh#./sandbox.sh#g' .ai-containers/runme.sh                  # repoint engine call
# Refresh the other shared scripts in the working copy from opensource:
OSS=/workspace/ai-containers
for f in sandbox.sh build.sh repo.sh sandbox-common.sh install-tools.sh install-agent-skills.sh tools-lib.sh Dockerfile .dockerignore; do
  [[ -f "$OSS/$f" ]] && cp "$OSS/$f" ".ai-containers/$f"
done
grep -n 'runme\|sandbox.sh' .ai-containers/runme.sh   # launcher calls ./sandbox.sh, exports IMAGE_NAME
```

- [ ] **Step 2: Apply the README/AGENTS framing edits to base/ and docs/**

Same reframing as Task 4 (engine bullet → `sandbox.sh`; `<project>-container.sh` → `runme.sh`; residual engine mentions → `sandbox.sh`), applied concretely to all four mgd docs. First the hand-edits, mirroring Task 4 Steps 1 & 3 in each `README.md`:

- scripts-list engine bullet → `` - `sandbox.sh` runs the container engine (`restricted` / `discovery`). In a consumer project you normally invoke it indirectly through the generated `runme.sh` launcher. ``
- project-init generation line → `` Generates `<project>/.ai-containers/runme.sh` (the per-project launcher) with `IMAGE_NAME` ... `` and the example `./<project-name>-container.sh` → `./runme.sh`.

Then the mechanical sweep (mirrors Task 4 Steps 2 & 4) — but re-apply the two hand-edited launcher lines afterward if the blanket sed rewrote them to `sandbox.sh`:

```bash
cd /workspace/mgd-ai-containers
for f in base/README.md docs/README.md base/AGENTS.md docs/AGENTS.md; do
  [[ -f "$f" ]] || continue
  sed -i 's#<project>-container\.sh#runme.sh#g; s#<project-name>-container\.sh#runme.sh#g; s/runme\.sh/sandbox.sh/g' "$f"
done
# The last clause turned launcher mentions into sandbox.sh too — restore the intended
# "runme.sh (the per-project launcher)" wording by hand in each README (2 spots each:
# scripts list + project-init section), then verify:
grep -rn 'runme' base/README.md docs/README.md base/AGENTS.md docs/AGENTS.md
# Expect: only intended launcher mentions ("runme.sh launcher" / "runme.sh (the per-project launcher)").
```

- [ ] **Step 3: Add the CHANGELOG breaking entry to base/ and docs/**

Add the same entry as Task 4 Step 5 to the top of `base/CHANGELOG.md` and `docs/CHANGELOG.md`.

- [ ] **Step 4: Final repo-wide audit (both repos)**

```bash
for repo in /workspace/ai-containers /workspace/mgd-ai-containers; do
  echo "== $repo =="
  grep -rn "runme" "$repo" --include='*.sh' --include='*.md' --include='Dockerfile*' --include='*.conf' --include='*.txt' \
    | grep -v 'docs/superpowers/' | grep -v 'CHANGELOG' | grep -vE 'runme\.sh (launcher|—|-)' | grep -vE '/\.ai-containers/runme\.sh' \
    | grep -v '/.git/'
done
# Expect: no output from either repo (only history, CHANGELOG, and intentional launcher refs remain).
```

- [ ] **Step 5: Verify base↔docs equality once more and commit mgd**

```bash
cd /workspace/mgd-ai-containers
./sync-presets.sh --check
git add -A
git commit -m "docs(mgd): sandbox.sh/runme.sh naming in READMEs, AGENTS, CHANGELOG; working copy

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Notes for the executor

- The two repos share no git history; each `git mv` and commit is independent.
- **Task 2 Step 1 caveat:** the `printf '%s\n\n\n\n\ny\n' ...` feed into `project-init.sh` is an approximation of its interactive prompts. Because stdin is piped (no tty), it cannot hang; if the prompt sequence differs, the launcher simply won't be written and the test FAILs (never a false PASS). The executor should adjust the fed answer lines to match the actual prompts if the first run fails on setup rather than on an assertion.
- Watch the Task 4 Step 4 hazard: the blanket README sed can overwrite an intended `runme.sh` **launcher** mention created in Steps 1/3. Do Steps 1-3 (which set the launcher wording) and let Step 4 handle only leftovers; re-verify with the grep.
- `migrate_launcher_naming` is intentionally name-agnostic for the legacy launcher (`*-container.sh` glob + marker check) so projects that were renamed at init still migrate.
- Do not touch files under any `docs/superpowers/` directory or existing CHANGELOG entries — those are history.
