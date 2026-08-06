# sandbox.local.env SANDBOX_MODE Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `project-init.sh` always write `sandbox.local.env`, with a header comment documenting every override option — including a commented-out `SANDBOX_MODE` example — instead of writing the file only when extra mounts or a group-bootstrap answer were given, and instead of never mentioning `SANDBOX_MODE` at all.

**Architecture:** Pure output-shape change to one function's write block in `project-init.sh`, applied identically in two repos (`ai-containers` and its downstream fork `dt-utils/mgd-ai-containers/base`, which carries the same block unmodified aside from an unrelated preset-overlay feature). No runtime script (`sandbox.sh`, `sandbox-common.sh`) changes — the env-file precedence logic (`inline > sandbox.local.env > sandbox.env`) is untouched.

**Tech Stack:** bash (project-init.sh, tests/test-project-init.sh), Markdown (README.md).

## Global Constraints

- `SANDBOX_MODE` stays a **commented-out example** (`#SANDBOX_MODE=open`) in `sandbox.local.env`, never a live value — the live default lives only in `sandbox.env` (per design doc `docs/superpowers/specs/2026-08-06-sandbox-local-env-mode-doc-design.md`, to avoid two sources of truth for the same setting).
- `sandbox.local.env` must be written on every `project-init.sh` run, regardless of whether `extra_mounts` or `group_init` are empty.
- The active `AI_CONTAINER_GROUP_INIT=`/`EXTRA_MOUNTS=` lines are still appended only when their corresponding prompt was answered — this part of the behavior does not change.
- Both repos' changes must be byte-for-byte equivalent in the new comment block text (so the fork stays a mechanical superset of upstream in this area).

---

### Task 1: ai-containers — always-write sandbox.local.env with documented SANDBOX_MODE example

**Files:**
- Modify: `project-init.sh:298-312`
- Test: `tests/test-project-init.sh`

**Interfaces:**
- Consumes: existing shell vars `dest`, `group_init`, `extra_mounts`, `project_name` already in scope at this point in `project-init.sh` (unchanged).
- Produces: `${dest}/sandbox.local.env` is now unconditionally created by every `project-init.sh` run — later tasks (README wording, the fork port) rely on this file always existing at that path with the new header text below.

- [ ] **Step 1: Add a failing test for "sandbox.local.env is always written, with no group-init and no extra-mounts answered"**

`tests/test-project-init.sh` currently only exercises two cases: a *new* group (`group_init` set, `extra_mounts` empty) and an *existing* group with mounts (`extra_mounts` set, `group_init` empty). Add a third project that reuses the already-bootstrapped `default` group (created by the `PROJ` run earlier in the same test file) and answers no extra mounts, so both `group_init` and `extra_mounts` are empty — today's code would skip writing the file entirely for this case.

Insert this block right before the final `[[ "$fails" -eq 0 ]] ...` line (i.e. after the existing PROJ2 assertions, at what is currently line 76/90 depending on repo):

```bash
# A third project reusing the already-bootstrapped "default" group, with no extra
# mounts either → group_init AND extra_mounts are both empty. sandbox.local.env must
# still be written (previously it was skipped entirely in this case), and its header
# must document the SANDBOX_MODE override as a commented example.
PROJ3="$TMP/proj/plain"; mkdir -p "$PROJ3"; git -C "$PROJ3" init -q
printf '%s\n\n\n\n\n\n\n\n\n\n\n' "$PROJ3" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
SBLOCAL3="$PROJ3/.ai-containers/sandbox.local.env"
[[ -f "$SBLOCAL3" ]] && pass "sandbox.local.env always written (no mounts, no group-init)" || fail "sandbox.local.env always written (no mounts, no group-init)"
grep -q '^#SANDBOX_MODE=open' "$SBLOCAL3" && pass "sandbox.local.env documents SANDBOX_MODE example" || fail "sandbox.local.env documents SANDBOX_MODE example"
grep -q 'restricted  firewall enabled' "$SBLOCAL3" && pass "sandbox.local.env documents restricted mode" || fail "sandbox.local.env documents restricted mode"
! grep -q '^SANDBOX_MODE=' "$SBLOCAL3" && pass "SANDBOX_MODE stays commented (no live duplicate)" || fail "SANDBOX_MODE stays commented (no live duplicate)"
! grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBLOCAL3" && pass "no stray GROUP_INIT when not answered" || fail "no stray GROUP_INIT when not answered"
! grep -q '^EXTRA_MOUNTS=' "$SBLOCAL3" && pass "no stray EXTRA_MOUNTS when not answered" || fail "no stray EXTRA_MOUNTS when not answered"
```

Note: `PROJ3` runs after `PROJ` in the same `HOME`, so the `default` group already exists — `project-init.sh` will not re-prompt the group-bootstrap menu, keeping `group_init` empty for this run (mirroring how `PROJ2`'s existing test comment already documents this HOME-reuse behavior).

- [ ] **Step 2: Run the test to verify the new assertions fail**

Run: `bash tests/test-project-init.sh`
Expected: the four new `pass`/`fail` lines print `FAIL` for "sandbox.local.env always written..." and "sandbox.local.env documents SANDBOX_MODE example" (file doesn't exist yet in this case), overall exit 1.

- [ ] **Step 3: Modify project-init.sh to always write sandbox.local.env with the documented header**

Replace the block at `project-init.sh:298-312`:

```bash
# Machine-specific config → sandbox.local.env (gitignored). AI_CONTAINER_GROUP_INIT is a
# host-referential one-time group-bootstrap directive (e.g. from:host), so it belongs here,
# not in the shared portable file; EXTRA_MOUNTS holds this machine's absolute bind paths.
if [[ -n "$extra_mounts" || -n "$group_init" ]]; then
  {
    cat <<'EOF'
# sandbox.local.env — THIS MACHINE's launcher config (gitignored, not shared).
# Overrides sandbox.env (loaded at higher precedence). Machine/platform-specific:
# absolute bind paths, named-volume repos, the group bootstrap, workdir/resource overrides.
EOF
    [[ -n "$group_init"   ]] && printf 'AI_CONTAINER_GROUP_INIT=%s\n' "$group_init"
    [[ -n "$extra_mounts" ]] && printf 'EXTRA_MOUNTS="%s"\n' "$extra_mounts"
  } > "${dest}/sandbox.local.env"
  printf '  Wrote sandbox.local.env (machine-specific).\n'
fi
```

with:

```bash
# Machine-specific config → sandbox.local.env (gitignored). Always written (even with
# no EXTRA_MOUNTS/group-init answered) so every project has a documented place for
# machine-local overrides. AI_CONTAINER_GROUP_INIT is a host-referential one-time
# group-bootstrap directive (e.g. from:host), so it belongs here, not in the shared
# portable file; EXTRA_MOUNTS holds this machine's absolute bind paths.
{
  cat <<'EOF'
# sandbox.local.env — THIS MACHINE's launcher config (gitignored, not shared).
# Overrides sandbox.env (loaded at higher precedence: inline env > sandbox.local.env > sandbox.env).
# Uncomment/add only what this machine or this one-off run needs:
#   EXTRA_MOUNTS="/abs/path /another:ro"   # host bind mounts (Linux-native; absolute paths)
#   REPOS="app:rw lib:ro"                  # named-volume repos (./repo.sh add; macOS perf)
#   SANDBOX_WORKDIR=@app                   # named-volume working dir (macOS)
#   AI_CONTAINER_GROUP_INIT=from:host      # one-time group bootstrap: clean|from:host|from:<group>
#
# SANDBOX_MODE overrides the portable default (currently "open" in sandbox.env). Options:
#   restricted  firewall enabled, NET_ADMIN/NET_RAW dropped from the agent shell
#   discovery   unrestricted egress + background pcap capture
#   open        unrestricted egress, no capture
#SANDBOX_MODE=open
EOF
  [[ -n "$group_init"   ]] && printf 'AI_CONTAINER_GROUP_INIT=%s\n' "$group_init"
  [[ -n "$extra_mounts" ]] && printf 'EXTRA_MOUNTS="%s"\n' "$extra_mounts"
} > "${dest}/sandbox.local.env"
printf '  Wrote sandbox.local.env (machine-specific).\n'
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-project-init.sh`
Expected: `ALL PASS`, exit 0. (Confirms the pre-existing PROJ/PROJ2 assertions about `AI_CONTAINER_GROUP_INIT`/`EXTRA_MOUNTS` placement still hold, plus the new PROJ3 assertions.)

- [ ] **Step 5: Commit**

```bash
git add project-init.sh tests/test-project-init.sh
git commit -m "feat(project-init): always write sandbox.local.env, document SANDBOX_MODE"
```

---

### Task 2: ai-containers — fix README wording for sandbox.local.env

**Files:**
- Modify: `README.md` (the paragraph describing `project-init.sh`'s generated files, containing the sentence starting "Writes two launcher-config files.")

**Interfaces:**
- Consumes: nothing from Task 1 except the fact that the behavior it describes has changed.
- Produces: nothing consumed by later tasks — this is documentation only.

- [ ] **Step 1: Update the sentence describing when sandbox.local.env is written**

Find this exact substring in `README.md` (appears once):

```
is written when you supply machine paths at init or when bootstrapping a new group; it holds
```

Replace with:

```
is always written; it documents every override (including a commented-out `SANDBOX_MODE` example — the live default lives in `sandbox.env`) and holds
```

- [ ] **Step 2: Verify the replacement**

Run: `grep -n "is always written; it documents every override" README.md`
Expected: one match, in the `project-init.sh` description paragraph.

Run: `grep -n "is written when you supply machine paths at init" README.md`
Expected: no matches (old wording fully replaced).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: sandbox.local.env is always written by project-init.sh"
```

---

### Task 3: dt-utils/mgd-ai-containers — port the always-write + SANDBOX_MODE doc change

**Files:**
- Modify: `/Users/ivan.gudak/dev/dt-utils/mgd-ai-containers/base/project-init.sh:448-462`
- Test: `/Users/ivan.gudak/dev/dt-utils/mgd-ai-containers/tests/test-project-init.sh`

**Interfaces:**
- Consumes: nothing from ai-containers directly (separate repo/checkout) — this task re-applies the same edit shape from Task 1, adjusted for this repo's line numbers and its extra `preview_ports` prompt (one more empty answer needed in scripted stdin).
- Produces: `${dest}/sandbox.local.env` in this repo also always created — no later task depends on this beyond Task 4 (README).

- [ ] **Step 1: Add the equivalent failing test in this repo**

In `/Users/ivan.gudak/dev/dt-utils/mgd-ai-containers/tests/test-project-init.sh`, insert before the final `[[ "$fails" -eq 0 ]] ...` line:

```bash
# A third project reusing the already-bootstrapped "default" group, with no extra
# mounts either → group_init AND extra_mounts are both empty. sandbox.local.env must
# still be written (previously it was skipped entirely in this case), and its header
# must document the SANDBOX_MODE override as a commented example.
# Prompt order here has one more slot (preview-ports) than upstream ai-containers.
PROJ3="$TMP/proj/plain"; mkdir -p "$PROJ3"; git -C "$PROJ3" init -q
printf '%s\n\n\n\n\n\n\n\n\n\n\n\n' "$PROJ3" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
SBLOCAL3="$PROJ3/.ai-containers/sandbox.local.env"
[[ -f "$SBLOCAL3" ]] && pass "sandbox.local.env always written (no mounts, no group-init)" || fail "sandbox.local.env always written (no mounts, no group-init)"
grep -q '^#SANDBOX_MODE=open' "$SBLOCAL3" && pass "sandbox.local.env documents SANDBOX_MODE example" || fail "sandbox.local.env documents SANDBOX_MODE example"
grep -q 'restricted  firewall enabled' "$SBLOCAL3" && pass "sandbox.local.env documents restricted mode" || fail "sandbox.local.env documents restricted mode"
! grep -q '^SANDBOX_MODE=' "$SBLOCAL3" && pass "SANDBOX_MODE stays commented (no live duplicate)" || fail "SANDBOX_MODE stays commented (no live duplicate)"
! grep -q '^AI_CONTAINER_GROUP_INIT=' "$SBLOCAL3" && pass "no stray GROUP_INIT when not answered" || fail "no stray GROUP_INIT when not answered"
! grep -q '^EXTRA_MOUNTS=' "$SBLOCAL3" && pass "no stray EXTRA_MOUNTS when not answered" || fail "no stray EXTRA_MOUNTS when not answered"
```

(One extra trailing `\n` versus Task 1's PROJ3 block, matching this file's existing PROJ/PROJ2 pattern of one extra empty answer for the `preview_ports` prompt.)

- [ ] **Step 2: Run the test to verify the new assertions fail**

Run: `bash tests/test-project-init.sh` (from `/Users/ivan.gudak/dev/dt-utils/mgd-ai-containers`)
Expected: the new PROJ3 assertions print `FAIL`, overall exit 1.

- [ ] **Step 3: Apply the same project-init.sh edit as Task 1**

Replace the block at `base/project-init.sh:448-462`:

```bash
# Machine-specific config → sandbox.local.env (gitignored). AI_CONTAINER_GROUP_INIT is a
# host-referential one-time group-bootstrap directive (e.g. from:host), so it belongs here,
# not in the shared portable file; EXTRA_MOUNTS holds this machine's absolute bind paths.
if [[ -n "$extra_mounts" || -n "$group_init" ]]; then
  {
    cat <<'EOF'
# sandbox.local.env — THIS MACHINE's launcher config (gitignored, not shared).
# Overrides sandbox.env (loaded at higher precedence). Machine/platform-specific:
# absolute bind paths, named-volume repos, the group bootstrap, workdir/resource overrides.
EOF
    [[ -n "$group_init"   ]] && printf 'AI_CONTAINER_GROUP_INIT=%s\n' "$group_init"
    [[ -n "$extra_mounts" ]] && printf 'EXTRA_MOUNTS="%s"\n' "$extra_mounts"
  } > "${dest}/sandbox.local.env"
  printf '  Wrote sandbox.local.env (machine-specific).\n'
fi
```

with the identical replacement text used in Task 1, Step 3 (same comment block, same heredoc, same trailing append lines — this repo's block is byte-for-byte identical to upstream's at this location).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-project-init.sh` (from `/Users/ivan.gudak/dev/dt-utils/mgd-ai-containers`)
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git -C /Users/ivan.gudak/dev/dt-utils/mgd-ai-containers add base/project-init.sh tests/test-project-init.sh
git -C /Users/ivan.gudak/dev/dt-utils/mgd-ai-containers commit -m "feat(project-init): always write sandbox.local.env, document SANDBOX_MODE"
```

---

### Task 4: dt-utils/mgd-ai-containers — port the README wording fix

**Files:**
- Modify: `/Users/ivan.gudak/dev/dt-utils/mgd-ai-containers/base/README.md` (same sentence as Task 2, in this repo's copy)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Update the sentence describing when sandbox.local.env is written**

Find this exact substring in `base/README.md` (appears once):

```
is written when you supply machine paths at init or when bootstrapping a new group; it holds
```

Replace with the same replacement text used in Task 2, Step 1:

```
is always written; it documents every override (including a commented-out `SANDBOX_MODE` example — the live default lives in `sandbox.env`) and holds
```

- [ ] **Step 2: Verify the replacement**

Run: `grep -n "is always written; it documents every override" /Users/ivan.gudak/dev/dt-utils/mgd-ai-containers/base/README.md`
Expected: one match.

Run: `grep -n "is written when you supply machine paths at init" /Users/ivan.gudak/dev/dt-utils/mgd-ai-containers/base/README.md`
Expected: no matches.

- [ ] **Step 3: Commit**

```bash
git -C /Users/ivan.gudak/dev/dt-utils/mgd-ai-containers add base/README.md
git -C /Users/ivan.gudak/dev/dt-utils/mgd-ai-containers commit -m "docs: sandbox.local.env is always written by project-init.sh"
```
