# `sandbox.env` Launcher-Config Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move launcher config out of the generated `runme.sh` into a tracked portable `sandbox.env` + a gitignored machine-specific `sandbox.local.env`, loaded by a single set-if-unset loader in `sandbox-common.sh`, so `runme.sh` becomes a thin wrapper.

**Architecture:** `sandbox-common.sh` gains `load_env_defaults` (parse `KEY=value`, set only if unset) and calls it for `sandbox.local.env` then `sandbox.env` (first-writer-wins → precedence inline > local > portable). `sandbox.sh` defaults its `<mode> <workdir>` positional args from `SANDBOX_MODE`/`SANDBOX_WORKDIR`. `project-init.sh` writes both env files and a thin `runme.sh`.

**Tech Stack:** Bash (bash 3.2-compatible), the project's stub-based test harness (`tests/run-all.sh`).

**Spec:** `docs/superpowers/specs/2026-08-04-sandbox-env-consolidation-design.md`

## Global Constraints

- **Precedence: inline env > `sandbox.local.env` > `sandbox.env`.** Implemented by set-if-unset + loading local **before** portable (first writer wins). An already-set (inline/exported) var is never clobbered.
- **`load_env_defaults` PARSES, never sources** — only `KEY=value` assignments are honored (tolerate a leading `export`, strip one layer of surrounding double quotes, skip comment/blank/non-assignment lines). No arbitrary code from the file may execute.
- **Backward-compatible `sandbox.sh`:** a positional arg always wins; with no arg AND no env value, mode → `usage` (help), workdir → the `/workspace` umbrella. The `open`/`..` defaults live as DATA in `sandbox.env`, not as new hard-coded fallbacks.
- **Portable vs machine-specific:** `sandbox.env` (tracked) = `IMAGE_NAME`, `AI_CONTAINER_GROUP`(+`_INIT`), `CONTAINER_CPUS`/`CONTAINER_MEMORY`(+reservation/swap), `SANDBOX_MODE=open`, `SANDBOX_WORKDIR=..`, plus commented `EXTRA_MOUNTS`/`REPOS` examples. `sandbox.local.env` (gitignored) = `EXTRA_MOUNTS`, `REPOS`, any override. Machine paths never go in the portable file.
- **`container.env` is untouched** (a distinct in-container app-env layer).
- **bash 3.2-compatible** (stock macOS bash), matching the rest of the repo.
- Every host entry point (`build.sh`/`sandbox.sh`/`repo.sh`) sources `sandbox-common.sh`, so all get the full config.

**Verification note:** run the suite with `rm -f .agents-cache-bust; bash tests/run-all.sh`. `tests/test-env-file.sh` is the *`container.env`* layer — do NOT put `sandbox.env` tests there.

---

## File Structure

- **Modify `sandbox-common.sh`** (`:40-51`): replace the IMAGE_NAME-only source block with `load_env_defaults` + two load calls (local, then portable). Keep `image_name="${IMAGE_NAME:-ai-sandbox}"`.
- **Modify `sandbox.sh`** (entry `:796-810`, `usage()` `~:50-73`): mode/workdir fall back to `SANDBOX_MODE`/`SANDBOX_WORKDIR`.
- **Create `tests/test-sandbox-env.sh`**: loader precedence + parsing + load-order + `sandbox.sh` defaulting.
- **Modify `project-init.sh`** (`:277-285` sandbox.env, new sandbox.local.env write, `:298-304` gitignore, `:318-368` runme.sh): write portable `sandbox.env`, machine `sandbox.local.env`, thin `runme.sh`, gitignore `sandbox.local.env`.
- **Modify `tests/test-project-init.sh`**: assert the new file split + thin runme.sh.
- **Modify `README.md`, `AGENTS.md`, `CHANGELOG.md`**: document the two-layer model, precedence, migration. (`CLAUDE.md` is a symlink to `AGENTS.md` — covered.)

---

## Task 1: `load_env_defaults` loader + `sandbox.sh` mode/workdir defaulting

**Files:**
- Modify: `sandbox-common.sh` (replace `:40-51`)
- Modify: `sandbox.sh` (entry `:796-810`; `usage()` note)
- Test: `tests/test-sandbox-env.sh` (new)

**Interfaces:**
- Produces: `load_env_defaults FILE` — sets each `KEY=value` from FILE only if the key is currently unset; exports it; parses (no sourcing). Called `load_env_defaults "$script_dir/sandbox.local.env"` then `load_env_defaults "$script_dir/sandbox.env"`.
- Produces: `sandbox.sh` reads `SANDBOX_MODE`/`SANDBOX_WORKDIR` (populated by the loader) as fallbacks for its positional `<mode> <workdir>`.

- [ ] **Step 1: Write the failing test** — `tests/test-sandbox-env.sh`:

```bash
#!/usr/bin/env bash
# Tests the sandbox.env/sandbox.local.env loader (load_env_defaults, precedence
# inline > local > portable) and sandbox.sh's SANDBOX_MODE/SANDBOX_WORKDIR defaulting.
# NOTE: tests/test-env-file.sh covers a DIFFERENT layer (in-container container.env).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0; pass() { printf 'PASS: %s\n' "$1"; }; fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/sandbox-common.sh" && pass "sandbox-common.sh bash -n" || fail "sandbox-common.sh bash -n"
bash -n "$REPO_DIR/sandbox.sh"        && pass "sandbox.sh bash -n"        || fail "sandbox.sh bash -n"

# Load the REAL load_env_defaults (extract just the function so the file's heavy
# top-level code does not run).
eval "$(sed -n '/^load_env_defaults()/,/^}/p' "$REPO_DIR/sandbox-common.sh")"
type load_env_defaults >/dev/null 2>&1 && pass "load_env_defaults defined" || { fail "load_env_defaults defined"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

# Apply exactly as sandbox-common.sh does: local first, then portable.
apply() { load_env_defaults "$LOCAL"; load_env_defaults "$PORTABLE"; }
mk() { LOCAL="$(mktemp)"; PORTABLE="$(mktemp)"; }
rmk() { rm -f "$LOCAL" "$PORTABLE"; }

# precedence: inline > local > portable
mk; printf 'CONTAINER_MEMORY=2g\n' > "$PORTABLE"; printf 'CONTAINER_MEMORY=4g\n' > "$LOCAL"
( unset CONTAINER_MEMORY; export CONTAINER_MEMORY=8g; apply; [[ "$CONTAINER_MEMORY" == 8g ]] ) \
  && pass "inline wins over local + portable" || fail "inline wins over local + portable"
( unset CONTAINER_MEMORY; apply; [[ "$CONTAINER_MEMORY" == 4g ]] ) \
  && pass "local wins over portable" || fail "local wins over portable"
rmk

# portable-only key applied
mk; printf 'IMAGE_NAME=proj-img\n' > "$PORTABLE"
( unset IMAGE_NAME; apply; [[ "$IMAGE_NAME" == proj-img ]] ) \
  && pass "portable-only key applied" || fail "portable-only key applied"
rmk

# missing local file is a no-op
mk; rm -f "$LOCAL"; printf 'IMAGE_NAME=x\n' > "$PORTABLE"
( unset IMAGE_NAME; apply; [[ "$IMAGE_NAME" == x ]] ) \
  && pass "missing sandbox.local.env is a clean no-op" || fail "missing sandbox.local.env is a clean no-op"
rm -f "$PORTABLE"

# comments / blank / export prefix / surrounding quotes / non-assignment ignored
mk
{ printf '# comment\n'; printf '\n'; printf 'export EXTRA_MOUNTS="/a /b"\n'; printf 'not an assignment\n'; } > "$PORTABLE"
( unset EXTRA_MOUNTS; apply; [[ "$EXTRA_MOUNTS" == "/a /b" ]] ) \
  && pass "export prefix + surrounding quotes handled" || fail "export prefix + surrounding quotes handled"
# a stray command line must NOT execute
marker="$(mktemp -u)"; printf 'touch %s\n' "$marker" >> "$PORTABLE"
( apply ) >/dev/null 2>&1
[[ ! -e "$marker" ]] && pass "non-assignment lines do not execute" || { fail "non-assignment lines do not execute"; rm -f "$marker"; }
rmk

# load ORDER in sandbox-common.sh: local before portable
loc_ln=$(grep -n 'load_env_defaults .*sandbox\.local\.env' "$REPO_DIR/sandbox-common.sh" | head -1 | cut -d: -f1)
por_ln=$(grep -n 'load_env_defaults .*/sandbox\.env' "$REPO_DIR/sandbox-common.sh" | head -1 | cut -d: -f1)
[[ -n "$loc_ln" && -n "$por_ln" && "$loc_ln" -lt "$por_ln" ]] \
  && pass "sandbox-common.sh loads local before portable ($loc_ln<$por_ln)" \
  || fail "sandbox-common.sh loads local before portable (local=$loc_ln portable=$por_ln)"

# sandbox.sh mode/workdir defaulting (structural — matches test-env-file.sh's grep style)
grep -qF 'command="${1:-${SANDBOX_MODE:-usage}}"' "$REPO_DIR/sandbox.sh" \
  && pass "mode falls back to SANDBOX_MODE (else usage)" || fail "mode falls back to SANDBOX_MODE"
grep -qF '${2:-${SANDBOX_WORKDIR:-}}' "$REPO_DIR/sandbox.sh" \
  && pass "workdir falls back to SANDBOX_WORKDIR" || fail "workdir falls back to SANDBOX_WORKDIR"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `bash tests/test-sandbox-env.sh`
Expected: FAIL — `load_env_defaults` is not defined yet; the load-order and `sandbox.sh` grep guards fail.

- [ ] **Step 3: Add the loader** — in `sandbox-common.sh`, replace the block at `:40-50` (the `# Persisted per-project environment …` comment through the `if [[ -z "${IMAGE_NAME:-}" … ]]; … fi`) with:

```bash
# Persisted per-project launcher config in two layers (both written by project-init.sh;
# KEY=value per line):
#   sandbox.env        — PORTABLE, tracked defaults (IMAGE_NAME, AI_CONTAINER_GROUP,
#                        CONTAINER_*, SANDBOX_MODE, SANDBOX_WORKDIR).
#   sandbox.local.env  — THIS MACHINE, gitignored (EXTRA_MOUNTS, REPOS, any override).
# Every entry point (build.sh / sandbox.sh / repo.sh) loads these, so all resolve the
# same config even when run directly instead of via the launcher.
#
# load_env_defaults sets each KEY only if unset (set-if-unset) → an inline/exported env
# var always wins. It PARSES (does not source): only KEY=value assignments are honoured,
# tolerating a leading `export` and stripping one layer of surrounding double quotes; no
# arbitrary code from the file runs. Precedence inline > local > portable is achieved by
# loading local BEFORE portable (first writer wins).
load_env_defaults() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"      # strip leading whitespace
    [[ -z "$line" || "$line" == '#'* ]] && continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val%\"}"; val="${val#\"}"             # strip one layer of surrounding double quotes
    [[ -n "${!key:-}" ]] && continue             # already set (inline env or earlier file) wins
    printf -v "$key" '%s' "$val"; export "$key"
  done < "$file"
}
load_env_defaults "${script_dir}/sandbox.local.env"   # this machine (higher precedence)
load_env_defaults "${script_dir}/sandbox.env"         # portable defaults
```

Leave the following line `image_name="${IMAGE_NAME:-ai-sandbox}"` (`:51`) unchanged.

- [ ] **Step 4: Wire `sandbox.sh` mode/workdir defaults** — at the entry point (`:796-800`), change:

```bash
command="${1:-usage}"

case "$command" in
  restricted|discovery|open)
    run_container "$command" "${2:-}"
    ;;
```

to:

```bash
# Mode + primary workdir fall back to SANDBOX_MODE / SANDBOX_WORKDIR (loaded from
# sandbox.env / sandbox.local.env by sandbox-common.sh) when the positional args are
# omitted — so a bare `./sandbox.sh` launches from config. A positional arg always wins;
# with no arg and no env value, mode → usage (help) and workdir → the /workspace umbrella.
command="${1:-${SANDBOX_MODE:-usage}}"

case "$command" in
  restricted|discovery|open)
    run_container "$command" "${2:-${SANDBOX_WORKDIR:-}}"
    ;;
```

Then in `usage()` add one line to the examples/notes area, e.g. after the mode descriptions:
`printf '  With no args, SANDBOX_MODE / SANDBOX_WORKDIR (from sandbox.env / sandbox.local.env) are used.\n'`

- [ ] **Step 5: Run tests — expect PASS**

Run: `bash tests/test-sandbox-env.sh && bash -n sandbox-common.sh && bash -n sandbox.sh`
Expected: `0 failure(s)`; both `bash -n` clean.

- [ ] **Step 6: Run the full suite (no regressions)**

Run: `rm -f .agents-cache-bust; bash tests/run-all.sh`
Expected: all green (existing `sandbox.env` IMAGE_NAME behavior still works — the loader sets `IMAGE_NAME` from the file when unset, exactly as before).

- [ ] **Step 7: Commit**

```bash
git add sandbox-common.sh sandbox.sh tests/test-sandbox-env.sh
git commit -m "feat: load_env_defaults (inline>local>portable) + sandbox.sh mode/workdir from env"
```

---

## Task 2: `project-init.sh` — write `sandbox.env` + `sandbox.local.env` + thin `runme.sh`

**Files:**
- Modify: `project-init.sh` (`:277-285`, new local-env write, `:298-304`, `:318-368`)
- Test: `tests/test-project-init.sh` (extend)

**Interfaces:**
- Consumes: the loader + `sandbox.sh` defaulting from Task 1 (the generated files feed them).
- Produces: `.ai-containers/sandbox.env` (portable keys incl. `SANDBOX_MODE=open`, `SANDBOX_WORKDIR=..`); `.ai-containers/sandbox.local.env` (only when machine mounts given); a thin `runme.sh` calling bare `./sandbox.sh`.

- [ ] **Step 1: Add the failing assertions** — extend `tests/test-project-init.sh`. After the existing `bash -n "$LAUNCHER"` assertion (before the final summary line), insert:

```bash
# ── §3: launcher config lives in sandbox.env / sandbox.local.env; runme.sh is thin ──
SBENV="$PROJ/.ai-containers/sandbox.env"
grep -q '^IMAGE_NAME='        "$SBENV" && pass "sandbox.env has IMAGE_NAME"       || fail "sandbox.env has IMAGE_NAME"
grep -q '^SANDBOX_MODE=open'  "$SBENV" && pass "sandbox.env has SANDBOX_MODE"     || fail "sandbox.env has SANDBOX_MODE"
grep -q '^SANDBOX_WORKDIR=\.\.' "$SBENV" && pass "sandbox.env has SANDBOX_WORKDIR" || fail "sandbox.env has SANDBOX_WORKDIR"
grep -q '^CONTAINER_CPUS='    "$SBENV" && pass "sandbox.env has CONTAINER_CPUS"   || fail "sandbox.env has CONTAINER_CPUS"
! grep -qE '^export (IMAGE_NAME|CONTAINER_)' "$LAUNCHER" && pass "runme.sh is thin (no baked config exports)" || fail "runme.sh is thin (no baked config exports)"
grep -qxF './sandbox.sh' "$LAUNCHER" && pass "runme.sh calls bare ./sandbox.sh" || fail "runme.sh calls bare ./sandbox.sh"
grep -qxF 'sandbox.local.env' "$PROJ/.ai-containers/.gitignore" && pass "sandbox.local.env is gitignored" || fail "sandbox.local.env is gitignored"
[[ ! -f "$PROJ/.ai-containers/sandbox.local.env" ]] && pass "no sandbox.local.env without extra mounts" || fail "no sandbox.local.env without extra mounts"

# A second project WITH an extra-mount answer → EXTRA_MOUNTS in sandbox.local.env only.
PROJ2="$TMP/proj/withmounts"; mkdir -p "$PROJ2"; git -C "$PROJ2" init -q
printf '%s\n\n\n\n\n\n\n\n\n%s\n' "$PROJ2" "$TMP" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1
SBLOCAL="$PROJ2/.ai-containers/sandbox.local.env"
{ [[ -f "$SBLOCAL" ]] && grep -q '^EXTRA_MOUNTS=' "$SBLOCAL"; } && pass "extra mounts → sandbox.local.env" || fail "extra mounts → sandbox.local.env"
! grep -q 'EXTRA_MOUNTS' "$PROJ2/.ai-containers/runme.sh"     && pass "EXTRA_MOUNTS not baked into runme.sh"     || fail "EXTRA_MOUNTS not baked into runme.sh"
! grep -q '^EXTRA_MOUNTS=' "$PROJ2/.ai-containers/sandbox.env" && pass "EXTRA_MOUNTS not in portable sandbox.env" || fail "EXTRA_MOUNTS not in portable sandbox.env"
```

- [ ] **Step 2: Run it — expect FAIL** (project-init still writes the old fat `runme.sh` + IMAGE_NAME-only `sandbox.env`).

Run: `bash tests/test-project-init.sh`
Expected: the new §3 assertions FAIL.

- [ ] **Step 3: Write the portable `sandbox.env`** — replace the `cat > "${dest}/sandbox.env" …` block (`:277-285`) with:

```bash
# Portable launcher config (tracked/shareable — same on any machine). Loaded by
# sandbox-common.sh so build.sh / sandbox.sh / repo.sh / the thin runme.sh all agree.
# Precedence: inline env > sandbox.local.env > sandbox.env. Not overwritten by sync.
{
  cat <<EOF
# sandbox.env — PORTABLE launcher config for ${project_name}'s AI sandbox.
IMAGE_NAME=${image_name}
AI_CONTAINER_GROUP=${group_name}
CONTAINER_CPUS=${container_cpus}
CONTAINER_MEMORY=${container_memory}
CONTAINER_MEMORY_RESERVATION=${container_memory_reservation}
CONTAINER_MEMORY_SWAP=${container_memory_swap}
SANDBOX_MODE=open
SANDBOX_WORKDIR=..
EOF
  [[ -n "$group_init" ]] && printf 'AI_CONTAINER_GROUP_INIT=%s\n' "$group_init"
  cat <<'EOF'
# Machine-specific settings belong in sandbox.local.env (gitignored), NOT here:
#   EXTRA_MOUNTS="/abs/path /another:ro"   # host bind mounts (Linux-native; absolute paths)
#   REPOS="app:rw lib:ro"                  # named-volume repos (./repo.sh add; macOS perf)
#   SANDBOX_WORKDIR=@app                   # named-volume working dir (macOS)
EOF
} > "${dest}/sandbox.env"
printf '  Wrote sandbox.env (portable config).\n'

# Machine-specific config → sandbox.local.env (gitignored), only when the user gave mounts.
if [[ -n "$extra_mounts" ]]; then
  {
    cat <<'EOF'
# sandbox.local.env — THIS MACHINE's launcher config (gitignored, not shared).
# Overrides sandbox.env (loaded at higher precedence). Machine/platform-specific:
# absolute bind paths, named-volume repos, workdir/resource overrides.
EOF
    printf 'EXTRA_MOUNTS="%s"\n' "$extra_mounts"
  } > "${dest}/sandbox.local.env"
  printf '  Wrote sandbox.local.env (machine-specific: EXTRA_MOUNTS).\n'
fi
```

- [ ] **Step 4: Gitignore `sandbox.local.env`** — in the `.ai-containers/.gitignore` pattern loop (`:298-300`), add `'sandbox.local.env'` to the pattern list:

```bash
for pat in '.agent-blocked/' '.agent-discovery/' 'sandbox.local.env' \
           'allowlist-domains.txt' 'allowlist-proxy-domains.txt' 'allowlist-cidrs.txt' \
           'allowlist-domains.d/custom.txt' 'allowlist-proxy-domains.d/custom.txt' 'allowlist-cidrs.d/custom.txt'; do
```

- [ ] **Step 5: Make `runme.sh` thin** — replace the launcher heredoc block inside `if (( write_launcher )); then … fi` (`:318-368`, from the `{ cat <<EOF … EOF … } > "$launch_script"`) with:

```bash
if (( write_launcher )); then
  cat > "$launch_script" <<EOF
#!/usr/bin/env bash
# runme.sh — launch the AI sandbox for ${project_name}. Thin wrapper generated by
# project-init.sh (re-run it to regenerate). Config lives in sandbox.env (portable) and
# sandbox.local.env (this machine); precedence inline > local > portable.
set -euo pipefail
cd "\$(dirname "\${BASH_SOURCE[0]}")"

# Build-time GitHub token for private tool downloads. build.sh passes it to docker build
# as a BuildKit secret; sandbox.sh does NOT forward it into the container. Non-clobbering
# (an already-set token wins), gh-optional (absence degrades to "no token").
if command -v gh >/dev/null 2>&1; then
  : "\${GITHUB_TOKEN:=\$(gh auth token 2>/dev/null || true)}"
  export GITHUB_TOKEN
fi

./build.sh
#./build.sh --no-cache

# Network mode + working dir come from SANDBOX_MODE / SANDBOX_WORKDIR (sandbox.env /
# sandbox.local.env). One-off override:  SANDBOX_MODE=restricted ./runme.sh
# Or drive sandbox.sh directly:           ./sandbox.sh restricted @app
./sandbox.sh
EOF
  chmod +x "$launch_script"
  printf '  Wrote runme.sh (thin wrapper).\n'
else
  printf '  Kept existing %s.\n' "$(basename "$launch_script")"
fi
```

- [ ] **Step 6: Run tests — expect PASS**

Run: `bash tests/test-project-init.sh && bash -n project-init.sh`
Expected: all `pass` incl. the §3 assertions; `bash -n` clean.

- [ ] **Step 7: Full suite**

Run: `rm -f .agents-cache-bust; bash tests/run-all.sh`
Expected: green. (`tests/test-sync-project.sh` is unaffected — `sandbox.env`/`sandbox.local.env` are per-project, not sync-copied shared scripts.)

- [ ] **Step 8: Commit**

```bash
git add project-init.sh tests/test-project-init.sh
git commit -m "feat: project-init writes portable sandbox.env + machine sandbox.local.env; thin runme.sh"
```

---

## Task 3: Docs — README + AGENTS.md + CHANGELOG.md

**Files:**
- Modify: `README.md`, `AGENTS.md`, `CHANGELOG.md`

**Interfaces:** none (documentation of Tasks 1-2).

- [ ] **Step 1: README** — add/replace the launcher-config documentation with a "Launcher configuration — `sandbox.env` / `sandbox.local.env`" subsection that states:
  - the two layers: portable `sandbox.env` (tracked) vs machine-specific `sandbox.local.env` (gitignored), and exactly which keys go where (the Global Constraints split);
  - the precedence **inline env > `sandbox.local.env` > `sandbox.env`**, "highest-precedence source that defines the key wins";
  - `runme.sh` is now a thin wrapper (`build` + bare `./sandbox.sh`); mode/workdir come from `SANDBOX_MODE`/`SANDBOX_WORKDIR`; a positional arg or inline env still wins;
  - a **"Migrating an existing `runme.sh`"** note: move the portable `export`s into `sandbox.env` (as `KEY=value`), move `EXTRA_MOUNTS`/`REPOS` into `sandbox.local.env`, replace the launch line with `./sandbox.sh`; or just re-run `project-init.sh`;
  - the cross-platform point: on macOS use `REPOS`/named-volume `SANDBOX_WORKDIR=@app` in `sandbox.local.env`; on Linux use `EXTRA_MOUNTS` — the shared `sandbox.env` is unchanged.

- [ ] **Step 2: AGENTS.md** — add one architecture paragraph (mirroring the existing env-layer / launcher docs) covering: the three env layers now in play — `container.env` (in-container app env, unchanged), `sandbox.env` (portable host launcher config), `sandbox.local.env` (this-machine host launcher config); the `load_env_defaults` set-if-unset loader in `sandbox-common.sh` and its precedence; and `sandbox.sh`'s `SANDBOX_MODE`/`SANDBOX_WORKDIR` defaulting. (`CLAUDE.md` → `AGENTS.md` symlink, so it is covered automatically.)

- [ ] **Step 3: CHANGELOG.md** — add an Unreleased entry: launcher config moved out of the generated `runme.sh` into a portable `sandbox.env` + gitignored `sandbox.local.env` (precedence inline > local > portable); `runme.sh` is now a thin wrapper; `sandbox.sh` mode/workdir default from `SANDBOX_MODE`/`SANDBOX_WORKDIR`. **Call out the behavior change:** a direct `./sandbox.sh` now also applies `CONTAINER_*`/`EXTRA_MOUNTS`/`REPOS` from the env files (before, only `IMAGE_NAME`); existing fat `runme.sh` files keep working; re-run `project-init.sh` to adopt the new shape.

- [ ] **Step 4: Verify**

Run: `grep -l 'sandbox.local.env' README.md AGENTS.md CHANGELOG.md && grep -qi 'inline > local > portable\|inline env > ' README.md AGENTS.md && echo docs-ok && rm -f .agents-cache-bust && bash tests/run-all.sh | tail -2`
Expected: all three files mention `sandbox.local.env`; README/AGENTS state the precedence; suite green.

- [ ] **Step 5: Commit**

```bash
git add README.md AGENTS.md CHANGELOG.md
git commit -m "docs: sandbox.env / sandbox.local.env launcher config + migration + precedence"
```

---

## Final verification (before the whole-branch review)

- [ ] `rm -f .agents-cache-bust; bash tests/run-all.sh` → green (incl. new `test-sandbox-env.sh`, extended `test-project-init.sh`).
- [ ] `bash -n sandbox-common.sh sandbox.sh project-init.sh` → clean.
- [ ] Grep confirms no `EXTRA_MOUNTS`/`REPOS`/`export IMAGE_NAME`/`export CONTAINER_` baked into a freshly generated `runme.sh`; `sandbox.local.env` gitignored; docs mention the new layers + precedence.
