# Agent-tier Tools → Runtime Group-Mounted Home; Retire `AGENTS_CACHE_BUST` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Claude Code, Codex, Gemini, Copilot, graphify, and Vale out of the baked image into a per-group, user-writable `~/.ai-tools/` home installed at container start (install-if-missing), then retire the entire `AGENTS_CACHE_BUST` apparatus.

**Architecture:** Reuse the shipped `~/.rvm` primitive — a group-mounted user-owned tool home plus a runtime reconcile run as the sandbox user, and a root-run linker exposing binaries on `/usr/local/bin` for non-login shells. The six tools install once per group and self-update in place. Kiro and `tools.d` tools stay baked; they refresh via `./build.sh --no-cache`.

**Tech Stack:** Bash, Dockerfile (Ubuntu 24.04), npm (nvm-baked Node), uv (pyenv-baked), flock, iptables/ipset firewall, the project's stub-based bash test harness (`tests/run-all.sh`).

**Spec:** `docs/superpowers/specs/2026-08-03-agent-tools-runtime-home-design.md`

## Global Constraints

- **Move set (exact):** `claude-code`, `copilot`, `codex`, `gemini`, `graphify`, `vale`. Kiro and `tools.d` (dtctl/dtmgd/acli) stay baked — never move them.
- **Update policy:** install-if-missing only. The reconcile never auto-updates a present tool; staying current is each tool's own job. No timestamps, no threshold env.
- **Tool-home layout:** `~/.ai-tools/npm` (npm prefix; bin at `~/.ai-tools/npm/bin`), `~/.ai-tools/uv` (`UV_TOOL_DIR`; bin at `~/.ai-tools/uv/bin`), `~/.ai-tools/bin` (single binaries: vale).
- **Both runtime scripts:** `set -o pipefail` only — **never** `set -u` (parity with rvm scripts; tolerate unset envs via `${VAR:-}`). flock-guarded on the shared mount. Offline-tolerant and non-fatal — a failed install logs `FAILED:` and is skipped; the container still starts.
- **Enablement env:** `AI_RUNTIME_TOOLS` (comma-separated), produced by a new `runtime_tools_csv()` in `sandbox-common.sh`, passed via `sandbox.sh`'s `-e`. It **excludes kiro** and **includes graphify/vale** (distinct from `AI_AGENTS_ENABLED`).
- **Retire `AGENTS_CACHE_BUST` fully:** no `AGENTS_CACHE_BUST` or `AGENT_REBUILD_MAX_AGE_HOURS` references anywhere post-change (CHANGELOG history excepted).
- **Allowlist:** PyPI is **already** covered for graphify (`build.sh:136` includes `pyenv.txt` unconditionally). Adding PyPI to `graphify.txt` is optional decoupling hygiene, **not** a blocker.
- **No sandbox.conf schema migration:** no keys added/removed/renamed; the six keys keep `ON|OFF` grammar, only their effect changes (build-install → runtime-install).
- **Blocking pre-merge gate:** the restricted-mode real-container smoke test (Task 6) must pass — each of the six tools must install **behind the firewall** (postinstall/transitive fetches included).
- **Keep allowlist wiring:** when dropping a tool's `INSTALL_*` build-arg mapping, its `include_if_enabled …/<tool>.txt` allowlist line **stays** (still needed at runtime).

---

## File Structure

**New files:**
- `agent-tools-reconcile.sh` — runtime reconcile (install-if-missing), run as sandbox user.
- `link-agent-tools.sh` — root linker; symlinks tool binaries onto `/usr/local/bin`.
- `tests/test-runtime-tools-csv.sh` — unit test for `runtime_tools_csv()` + wiring greps.
- `tests/test-agent-tools-reconcile.sh` — stub-based behavioral test (fake npm/uv/curl/tar).
- `tests/test-link-agent-tools.sh` — stub-based linker test (fake `~/.ai-tools` tree).
- `tests/test-entrypoint-wiring.sh` — asserts both hooks wired in all 3 entrypoint modes.
- `tests/test-agent-tools-smoke.sh` — gated real-container restricted-mode smoke test.

**Modified:**
- `sandbox-common.sh` — add `runtime_tools_csv()`; (Phase 2) remove cache-bust helpers.
- `sandbox.sh` — add `~/.ai-tools` mount + `-e AI_RUNTIME_TOOLS`; (Phase 2) remove `maybe_rebuild_stale_image` + its call.
- `entrypoint.sh` — add `run_agent_tools_reconcile` + `link_agent_tools`, wired in all 3 modes.
- `Dockerfile` — skel scaffolding + COPY 2 scripts; remove 6 install layers; (Phase 2) remove marker.
- `build.sh` — drop 6 key→build-arg mappings; (Phase 2) remove cache-bust logic + help.
- `allowlist-domains.d/graphify.txt` — optional PyPI hygiene.
- `project-init.sh`, root `.gitignore`, `.dockerignore` — (Phase 2) remove `.agents-cache-bust`.
- `tests/test-sync-project.sh` — pinned contract: +2 new scripts, −`.agents-cache-bust`.
- `tests/test-project-init.sh`, `tests/test-repo-registry.sh` — (Phase 2) drop cache-bust refs.
- `README.md`, `AGENTS.md`, `CHANGELOG.md`, `tools.d/acli.conf` — docs sweep.

**Deleted:** `tests/test-agents-cache-bust.sh`, `tests/test-image-staleness.sh`.

**Verification note:** Dockerfile-editing tasks verify with `docker build --check "$PWD"` (BuildKit lint / dry-run — validates syntax and build-arg references without a full build) plus grep assertions. Run the full suite with `rm -f .agents-cache-bust; bash tests/run-all.sh`. Docker commands need `DOCKER_CONFIG=<dir with a `{}` config.json>` (see handoff).

---

# PHASE 1 — Move tools to runtime

## Task 1: `runtime_tools_csv()` helper + `AI_RUNTIME_TOOLS` wiring

**Files:**
- Modify: `sandbox-common.sh` (after `enabled_agents_csv`, ~`:228`)
- Modify: `sandbox.sh` (mount block ~`:749-754`; env block ~`:865`)
- Test: `tests/test-runtime-tools-csv.sh` (new)

**Interfaces:**
- Produces: `runtime_tools_csv()` → prints comma-separated ON keys from `claude-code copilot codex gemini graphify vale` (kiro excluded). Consumed by `sandbox.sh` (`-e AI_RUNTIME_TOOLS`) and, transitively, the reconcile/linker via the container env.

- [ ] **Step 1: Write the failing test** — `tests/test-runtime-tools-csv.sh`:

```bash
#!/usr/bin/env bash
# Unit test for runtime_tools_csv(): ON/OFF filtering, kiro excluded, graphify/vale included.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Stub the config layer runtime_tools_csv depends on: is_enabled reads a fake ON-set.
ENABLED_SET=""
is_enabled() { [[ " $ENABLED_SET " == *" $1 "* ]]; }

# Load the REAL runtime_tools_csv from sandbox-common.sh — extract just the function so
# the file's heavy top-level code does not run — and exercise it against our is_enabled stub.
eval "$(sed -n '/^runtime_tools_csv()/,/^}/p' "$REPO_DIR/sandbox-common.sh")"

ENABLED_SET="claude-code gemini kiro"
got="$(runtime_tools_csv)"
[[ "$got" == "claude-code,gemini" ]] && pass "filters ON tools, preserves order" || fail "filters ON tools (got '$got')"

ENABLED_SET="kiro"
[[ -z "$(runtime_tools_csv)" ]] && pass "kiro alone yields empty (kiro excluded)" || fail "kiro must be excluded"

ENABLED_SET="graphify vale copilot codex"
[[ "$(runtime_tools_csv)" == "copilot,codex,graphify,vale" ]] && pass "graphify+vale included" || fail "graphify+vale must be included"

# The REAL implementation in sandbox-common.sh must match this contract.
grep -q 'runtime_tools_csv()' "$REPO_DIR/sandbox-common.sh" && pass "sandbox-common.sh defines runtime_tools_csv" || fail "sandbox-common.sh must define runtime_tools_csv"
grep -q 'AI_RUNTIME_TOOLS' "$REPO_DIR/sandbox.sh" && pass "sandbox.sh passes AI_RUNTIME_TOOLS" || fail "sandbox.sh must pass AI_RUNTIME_TOOLS"
grep -q '\.ai-tools' "$REPO_DIR/sandbox.sh" && pass "sandbox.sh mounts ~/.ai-tools" || fail "sandbox.sh must mount ~/.ai-tools"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run it — expect FAIL** on the three `grep` guards (functions/wiring absent):

Run: `bash tests/test-runtime-tools-csv.sh`
Expected: the three "sandbox-common.sh defines…", "sandbox.sh passes…", "sandbox.sh mounts…" lines FAIL.

- [ ] **Step 3: Add `runtime_tools_csv()`** to `sandbox-common.sh` immediately after `enabled_agents_csv()` (after `:228`):

```bash
# runtime_tools_csv — comma-separated sandbox.conf keys for the agent-tier tools
# installed at container start into the group-mounted ~/.ai-tools (NOT kiro, which
# stays baked). Consumed by sandbox.sh (-e AI_RUNTIME_TOOLS) and agent-tools-reconcile.sh.
runtime_tools_csv() {
  local a out=()
  for a in claude-code copilot codex gemini graphify vale; do
    is_enabled "$a" && out+=("$a")
  done
  local IFS=,; printf '%s' "${out[*]}"
}
```

- [ ] **Step 4: Add the mount** in `sandbox.sh` immediately after the ruby `.rvm` block (after `:754`):

```bash
  if [[ -n "$(runtime_tools_csv)" ]]; then
    if [[ "$group" != "host" ]]; then
      install -d "$group_root/.ai-tools"
    fi
    add_mount_if_exists config_mount_flags "$group_root/.ai-tools" "$dev_home/.ai-tools"
  fi
```

- [ ] **Step 5: Pass the env** in `sandbox.sh` immediately after the `AI_AGENTS_ENABLED` line (`:865`):

```bash
    -e AI_RUNTIME_TOOLS="$(runtime_tools_csv)" \
```

- [ ] **Step 6: Run tests — expect PASS**

Run: `bash tests/test-runtime-tools-csv.sh && bash -n sandbox.sh && bash -n sandbox-common.sh`
Expected: `0 failure(s)`; both `bash -n` clean.

- [ ] **Step 7: Commit**

```bash
git add sandbox-common.sh sandbox.sh tests/test-runtime-tools-csv.sh
git commit -m "feat: runtime_tools_csv + AI_RUNTIME_TOOLS env + ~/.ai-tools group mount"
```

---

## Task 2: `agent-tools-reconcile.sh` + test

**Files:**
- Create: `agent-tools-reconcile.sh`
- Test: `tests/test-agent-tools-reconcile.sh`

**Interfaces:**
- Consumes: `AI_RUNTIME_TOOLS` (comma CSV), `HOME`. Baked `~/.npmrc` sets npm prefix `${HOME}/.ai-tools/npm`.
- Produces: installed binaries under `~/.ai-tools/{npm/bin,uv/bin,bin}` and a `~/.local/bin/claude` symlink when Claude Code is present.

- [ ] **Step 1: Write the failing test** — `tests/test-agent-tools-reconcile.sh`:

```bash
#!/usr/bin/env bash
# Drives agent-tools-reconcile.sh against STUBBED npm/uv/curl/tar/dpkg (no network).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/agent-tools-reconcile.sh" && pass "agent-tools-reconcile.sh bash -n" || fail "agent-tools-reconcile.sh bash -n"

# Create a fake toolchain in $1(bin dir), writing installs into $2(home). NPM_FAIL=1
# makes npm exit 1 (simulate offline). Each fake records to $2/calls.log.
mk_stubs() {
  local bin="$1" home="$2"
  cat > "$bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >> "$home/calls.log"
[[ "\${NPM_FAIL:-0}" == "1" ]] && exit 1
if [[ "\$1 \$2" == "install -g" ]]; then
  case "\$3" in
    @anthropic-ai/claude-code) b=claude ;; @github/copilot) b=copilot ;;
    @openai/codex) b=codex ;; @google/gemini-cli) b=gemini ;; *) b="" ;;
  esac
  [[ -n "\$b" ]] && { install -d "$home/.ai-tools/npm/bin"; printf '#!/bin/sh\n' > "$home/.ai-tools/npm/bin/\$b"; chmod +x "$home/.ai-tools/npm/bin/\$b"; }
fi
exit 0
EOF
  cat > "$bin/uv" <<EOF
#!/usr/bin/env bash
echo "uv \$*" >> "$home/calls.log"
if [[ "\$1 \$2" == "tool install" ]]; then
  d="\${UV_TOOL_BIN_DIR:-$home/.ai-tools/uv/bin}"; install -d "\$d"; printf '#!/bin/sh\n' > "\$d/graphify"; chmod +x "\$d/graphify"
fi
exit 0
EOF
  cat > "$bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$home/calls.log"
for a in "\$@"; do case "\$a" in *releases/latest) echo "https://github.com/vale-cli/vale/releases/tag/v3.0.0"; exit 0;; esac; done
prev=""; for a in "\$@"; do [[ "\$prev" == "-o" ]] && : > "\$a"; prev="\$a"; done
exit 0
EOF
  cat > "$bin/tar" <<EOF
#!/usr/bin/env bash
echo "tar \$*" >> "$home/calls.log"
d=""; prev=""; for a in "\$@"; do [[ "\$prev" == "-C" ]] && d="\$a"; prev="\$a"; done
[[ -n "\$d" ]] && { printf '#!/bin/sh\n' > "\$d/vale"; chmod +x "\$d/vale"; }
exit 0
EOF
  printf '#!/usr/bin/env bash\necho amd64\n' > "$bin/dpkg"
  chmod +x "$bin/npm" "$bin/uv" "$bin/curl" "$bin/tar" "$bin/dpkg"
}

# run_case WANT [HOME] [NPM_FAIL] -> echoes the home dir it used (caller inspects & cleans).
run_case() {
  local want="$1" home="${2:-$(mktemp -d)}" npm_fail="${3:-0}"
  local bin; bin="$(mktemp -d)"
  mk_stubs "$bin" "$home"
  PATH="$bin:$PATH" HOME="$home" AI_RUNTIME_TOOLS="$want" NPM_FAIL="$npm_fail" \
    bash "$REPO_DIR/agent-tools-reconcile.sh" >"$home/out.log" 2>&1
  rm -rf "$bin"
  printf '%s' "$home"
}

# ── All six install on a fresh home ──
h="$(run_case "claude-code,copilot,codex,gemini,graphify,vale")"
c="$h/calls.log"
grep -q 'npm install -g @anthropic-ai/claude-code' "$c" && pass "installs claude-code" || fail "installs claude-code"
grep -q 'npm install -g @github/copilot' "$c"           && pass "installs copilot"     || fail "installs copilot"
grep -q 'npm install -g @openai/codex' "$c"             && pass "installs codex"       || fail "installs codex"
grep -q 'npm install -g @google/gemini-cli' "$c"        && pass "installs gemini"      || fail "installs gemini"
grep -q 'uv tool install graphifyy' "$c"                && pass "installs graphify"    || fail "installs graphify"
grep -q 'tar ' "$c"                                     && pass "installs vale (tar)"  || fail "installs vale (tar)"
[[ -L "$h/.local/bin/claude" ]] && pass "claude native-path symlink created" || fail "claude native-path symlink created"
rm -rf "$h"

# ── Idempotent: a second run on the SAME home does NOT reinstall ──
h="$(mktemp -d)"; run_case "claude-code,graphify,vale" "$h" >/dev/null; : > "$h/calls.log"; run_case "claude-code,graphify,vale" "$h" >/dev/null
[[ ! -s "$h/calls.log" || -z "$(grep -E 'install' "$h/calls.log")" ]] && pass "idempotent: present tools not reinstalled" || fail "idempotent: present tools not reinstalled"
rm -rf "$h"

# ── Empty AI_RUNTIME_TOOLS → no-op ──
h="$(run_case "")"; [[ ! -s "$h/calls.log" ]] && pass "empty AI_RUNTIME_TOOLS is a no-op" || fail "empty AI_RUNTIME_TOOLS is a no-op"; rm -rf "$h"

# ── Selective: only codex requested → only codex installed ──
h="$(run_case "codex")"; { grep -q 'npm install -g @openai/codex' "$h/calls.log" && ! grep -q '@google/gemini-cli' "$h/calls.log"; } && pass "installs only requested tools" || fail "installs only requested tools"; rm -rf "$h"

# ── Offline npm: FAILED logged, non-fatal, other tools still attempted ──
h="$(run_case "claude-code,graphify" "" 1)"
{ grep -q 'FAILED' "$h/out.log" && grep -q 'uv tool install graphifyy' "$h/calls.log"; } && pass "npm failure is non-fatal; other tools proceed" || fail "npm failure is non-fatal; other tools proceed"; rm -rf "$h"

# ── Guards ──
grep -q 'flock' "$REPO_DIR/agent-tools-reconcile.sh" && pass "flock-guarded" || fail "flock-guarded"
grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/agent-tools-reconcile.sh" && fail "must NOT enable nounset" || pass "does not enable nounset"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

> Entrypoint wiring is verified in Task 4 (`tests/test-entrypoint-wiring.sh`), so this
> test contains no wiring assertion and is fully green at its own commit.

- [ ] **Step 2: Run it — expect FAIL** (`bash -n` fails: script does not exist yet).

Run: `bash tests/test-agent-tools-reconcile.sh`
Expected: FAIL (missing script).

- [ ] **Step 3: Create `agent-tools-reconcile.sh`:**

```bash
#!/usr/bin/env bash
# agent-tools-reconcile.sh — runs as the sandbox USER at container start. Installs the
# enabled agent-tier tools (Claude Code, Codex, Gemini, Copilot, graphify, Vale) into
# the group-mounted ~/.ai-tools home on first use — INSTALL-IF-MISSING only; keeping
# them current is each tool's own job (/update, npm update -g, uv tool upgrade).
# Concurrency-safe via flock on the shared mount. Offline-tolerant and non-fatal: a tool
# that fails to install logs FAILED and is skipped, never blocking container start.
# No `set -u` (parity with rvm-reconcile.sh; tolerate unset envs via ${VAR:-}).
set -o pipefail

tools="${AI_RUNTIME_TOOLS:-}"
[[ -z "${tools//,/}" ]] && exit 0        # nothing enabled → nothing to do

home_root="$HOME/.ai-tools"
mkdir -p "$home_root/npm" "$home_root/uv/bin" "$home_root/bin"

# Serialize concurrent same-group container starts (they share the mounted ~/.ai-tools).
exec 9>"$home_root/.reconcile.lock"
flock 9

log(){ printf '[agent-tools-reconcile] %s\n' "$*"; }

# npm prefix comes from the baked ~/.npmrc; uv is pointed at the group-mounted tool dir.
export UV_TOOL_DIR="$home_root/uv"
export UV_TOOL_BIN_DIR="$home_root/uv/bin"
npm_bin="$home_root/npm/bin"

install_npm() {   # $1=binary  $2=package
  local bin="$1" pkg="$2"
  if [[ -x "$npm_bin/$bin" ]]; then log "$bin already present"; return 0; fi
  log "installing $pkg…"
  npm install -g "$pkg" || log "FAILED: npm install -g $pkg (skipped)"
}

install_uv() {    # $1=binary  $2=package
  local bin="$1" pkg="$2"
  if [[ -x "$UV_TOOL_BIN_DIR/$bin" ]]; then log "$bin already present"; return 0; fi
  log "installing $pkg (uv)…"
  uv tool install "$pkg" || log "FAILED: uv tool install $pkg (skipped)"
}

install_vale() {
  if [[ -x "$home_root/bin/vale" ]]; then log "vale already present"; return 0; fi
  log "installing vale…"
  local arch ver
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/vale-cli/vale/releases/latest 2>/dev/null | sed 's#.*/tag/v##')"
  if [[ -z "$ver" ]]; then log "FAILED: could not resolve latest Vale version (skipped)"; return 0; fi
  if curl -fsSL -o /tmp/vale.tar.gz \
       "https://github.com/vale-cli/vale/releases/download/v${ver}/vale_${ver}_Linux_${arch}.tar.gz" 2>/dev/null; then
    tar -xzf /tmp/vale.tar.gz -C "$home_root/bin" vale 2>/dev/null || log "FAILED: extract Vale (skipped)"
    rm -f /tmp/vale.tar.gz
  else
    log "FAILED: download Vale (skipped)"
  fi
}

IFS=, read -ra want <<<"$tools"
for t in "${want[@]}"; do
  case "$t" in
    claude-code) install_npm claude "@anthropic-ai/claude-code" ;;
    copilot)     install_npm copilot "@github/copilot" ;;
    codex)       install_npm codex "@openai/codex" ;;
    gemini)      install_npm gemini "@google/gemini-cli" ;;
    graphify)    install_uv graphify "graphifyy" ;;
    vale)        install_vale ;;
    *)           log "unknown tool '$t' (skipped)" ;;
  esac
done

# Claude Code plugins expect the native path ~/.local/bin/claude; point it at the
# group-mounted npm install when present.
if [[ -x "$npm_bin/claude" ]]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$npm_bin/claude" "$HOME/.local/bin/claude"
fi

log "done."
```

- [ ] **Step 4: `chmod +x agent-tools-reconcile.sh`** and re-run the test — fully green.

Run: `chmod +x agent-tools-reconcile.sh && bash tests/test-agent-tools-reconcile.sh`
Expected: `0 failure(s)` — every install/idempotent/no-op/selective/offline/guard assertion PASSES.

- [ ] **Step 5: Commit**

```bash
git add agent-tools-reconcile.sh tests/test-agent-tools-reconcile.sh
git commit -m "feat: agent-tools-reconcile.sh — install-if-missing runtime tool home"
```

---

## Task 3: `link-agent-tools.sh` + test

**Files:**
- Create: `link-agent-tools.sh`
- Test: `tests/test-link-agent-tools.sh`

**Interfaces:**
- Consumes: `AI_RUNTIME_TOOLS`, `$1` dev_home (default `$HOME`), `$2` bin_dest (default `/usr/local/bin`, override for tests).
- Produces: symlinks `claude/copilot/codex/gemini/graphify/vale` → their `~/.ai-tools` paths, for each that exists.

- [ ] **Step 1: Write the failing test** — `tests/test-link-agent-tools.sh`:

```bash
#!/usr/bin/env bash
# Drives link-agent-tools.sh against a FAKE ~/.ai-tools tree + a throwaway dest dir.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/link-agent-tools.sh" && pass "link-agent-tools.sh bash -n" || fail "link-agent-tools.sh bash -n"

# mk_tool HOME rel/path/binary → creates an executable stub at $HOME/.ai-tools/<rel>.
mk_tool() { install -d "$1/.ai-tools/$(dirname "$2")"; printf '#!/bin/sh\n' > "$1/.ai-tools/$2"; chmod +x "$1/.ai-tools/$2"; }

# ── Links every present tool binary into dest ──
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_tool "$h" npm/bin/claude; mk_tool "$h" npm/bin/copilot; mk_tool "$h" npm/bin/codex
mk_tool "$h" npm/bin/gemini; mk_tool "$h" uv/bin/graphify; mk_tool "$h" bin/vale
AI_RUNTIME_TOOLS="claude-code,copilot,codex,gemini,graphify,vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
ok=1
[[ -L "$d/claude"   && "$(readlink "$d/claude")"   == "$h/.ai-tools/npm/bin/claude" ]]   || ok=0
[[ -L "$d/graphify" && "$(readlink "$d/graphify")" == "$h/.ai-tools/uv/bin/graphify" ]]   || ok=0
[[ -L "$d/vale"     && "$(readlink "$d/vale")"     == "$h/.ai-tools/bin/vale" ]]          || ok=0
[[ "$ok" == 1 ]] && pass "links all present tools (npm/uv/bin sources)" || fail "links all present tools"
rm -rf "$h" "$d"

# ── Only links what exists (missing gemini is skipped, no dangling link) ──
h="$(mktemp -d)"; d="$(mktemp -d)"; mk_tool "$h" npm/bin/claude
AI_RUNTIME_TOOLS="claude-code,gemini" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/claude" && ! -e "$d/gemini" ]] && pass "only links existing binaries (no dangling)" || fail "only links existing binaries"
rm -rf "$h" "$d"

# ── Empty tool home → clean no-op ──
h="$(mktemp -d)"; d="$(mktemp -d)"
AI_RUNTIME_TOOLS="claude-code,vale" bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && -z "$(ls -A "$d")" ]] && pass "empty tool home → exit 0, dest empty" || fail "empty tool home → exit 0, dest empty"
rm -rf "$h" "$d"

# ── No AI_RUNTIME_TOOLS → no-op ──
h="$(mktemp -d)"; d="$(mktemp -d)"; mk_tool "$h" npm/bin/claude
( unset AI_RUNTIME_TOOLS; bash "$REPO_DIR/link-agent-tools.sh" "$h" "$d" ) >/dev/null 2>&1
[[ -z "$(ls -A "$d")" ]] && pass "no AI_RUNTIME_TOOLS is a no-op" || fail "no AI_RUNTIME_TOOLS is a no-op"
rm -rf "$h" "$d"

# ── Guards ──
grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/link-agent-tools.sh" && fail "must NOT enable nounset" || pass "does not enable nounset"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

> Entrypoint wiring is verified in Task 4 (`tests/test-entrypoint-wiring.sh`), so this
> test contains no wiring assertion and is fully green at its own commit.

- [ ] **Step 2: Run it — expect FAIL** (`bash -n` fails: script missing).

Run: `bash tests/test-link-agent-tools.sh`
Expected: FAIL.

- [ ] **Step 3: Create `link-agent-tools.sh`:**

```bash
#!/usr/bin/env bash
# link-agent-tools.sh — runs as ROOT at container start, AFTER agent-tools-reconcile.sh
# installs the enabled tools into the group-mounted ~/.ai-tools home. Symlinks each
# installed tool's executable onto the global PATH (/usr/local/bin) so NON-interactive,
# NON-login shells resolve them without sourcing profile.d — e.g. `docker exec -T <ctr>
# bash -c "claude …"`. Login/interactive shells already get them via /etc/profile.d/ai-tools.sh.
# No `set -u` (parity with link-default-ruby.sh; tolerate unset envs).
set -o pipefail

[[ -n "${AI_RUNTIME_TOOLS:-}" ]] || exit 0   # nothing enabled → nothing to expose

dev_home="${1:-$HOME}"
bin_dest="${2:-/usr/local/bin}"   # override only for testing; entrypoint uses the default
home_root="$dev_home/.ai-tools"

log(){ printf '[link-agent-tools] %s\n' "$*"; }

# tool binary → its location under the group home (npm prefix, uv bin, or plain bin).
srcs=(
  "claude:$home_root/npm/bin/claude"
  "copilot:$home_root/npm/bin/copilot"
  "codex:$home_root/npm/bin/codex"
  "gemini:$home_root/npm/bin/gemini"
  "graphify:$home_root/uv/bin/graphify"
  "vale:$home_root/bin/vale"
)

linked=""
for entry in "${srcs[@]}"; do
  name="${entry%%:*}"; path="${entry#*:}"
  if [[ -x "$path" ]]; then
    ln -sf "$path" "$bin_dest/$name"
    linked="${linked:+$linked }$name"
  fi
done
log "linked agent tools into $bin_dest: ${linked:-none}"
```

- [ ] **Step 4: `chmod +x link-agent-tools.sh`** and re-run the test — fully green.

Run: `chmod +x link-agent-tools.sh && bash tests/test-link-agent-tools.sh`
Expected: `0 failure(s)` — all linking + guard assertions PASS.

- [ ] **Step 5: Commit**

```bash
git add link-agent-tools.sh tests/test-link-agent-tools.sh
git commit -m "feat: link-agent-tools.sh — expose runtime tools on /usr/local/bin"
```

---

## Task 4: Wire scripts into `entrypoint.sh` + Dockerfile scaffolding & COPY

**Files:**
- Modify: `entrypoint.sh` (add 2 functions after `link_default_ruby` ~`:42`; add 2 calls in each of 3 modes)
- Modify: `Dockerfile` (skel scaffolding + COPY 2 scripts, near the rvm COPY ~`:369-376`)
- Test: `tests/test-entrypoint-wiring.sh` (new — verifies both hooks wired in all 3 modes)

**Interfaces:**
- Consumes: `agent-tools-reconcile.sh`, `link-agent-tools.sh` (Tasks 2-3); `AI_RUNTIME_TOOLS`, `$sandbox_user`.

- [ ] **Step 1: Add the two entrypoint functions** after `link_default_ruby()` (after `:42`):

```bash
# Bootstrap/reconcile the enabled agent-tier tools into the group-mounted ~/.ai-tools
# as the sandbox user. Offline-tolerant, non-fatal — never blocks container start.
run_agent_tools_reconcile() {
  [[ -n "${AI_RUNTIME_TOOLS:-}" ]] || return 0
  [[ -x /usr/local/bin/agent-tools-reconcile.sh ]] || return 0
  runuser -u "$sandbox_user" -- \
    env HOME="/home/$sandbox_user" AI_RUNTIME_TOOLS="${AI_RUNTIME_TOOLS}" \
    bash /usr/local/bin/agent-tools-reconcile.sh || true
}

# Expose the enabled agent tools on the global PATH (/usr/local/bin) for non-interactive,
# non-login shells. Runs as ROOT AFTER run_agent_tools_reconcile. Non-fatal.
link_agent_tools() {
  [[ -n "${AI_RUNTIME_TOOLS:-}" ]] || return 0
  [[ -x /usr/local/bin/link-agent-tools.sh ]] || return 0
  env AI_RUNTIME_TOOLS="${AI_RUNTIME_TOOLS}" \
    bash /usr/local/bin/link-agent-tools.sh "/home/$sandbox_user" || true
}
```

- [ ] **Step 2: Insert the two calls** in **each** of the three modes, immediately after the existing `link_default_ruby` line and before `run_agent_skill_install` (three sites — `restricted` ~`:204`, `discovery` ~`:223`, `open` ~`:242`). After each `link_default_ruby` line add:

```bash
    run_agent_tools_reconcile
    link_agent_tools
```

The per-mode sequence becomes: `run_ruby_reconcile` → `link_default_ruby` → `run_agent_tools_reconcile` → `link_agent_tools` → `run_agent_skill_install`.

- [ ] **Step 3: Add the Dockerfile scaffolding + COPY** immediately after the `link-default-ruby.sh` COPY/chmod block (after `:376`):

```dockerfile
# ── Agent-tier tool home (runtime-installed into the group-mounted ~/.ai-tools) ──
# Bake only scaffolding: an npm prefix under the tool home, PATH + uv env for login /
# interactive shells, and the ~/.local/bin dir Claude Code's native path uses. The six
# tools (Claude Code, Codex, Gemini, Copilot, graphify, Vale) install at container start
# via agent-tools-reconcile.sh; nothing agent-tier is baked.
RUN printf 'prefix=${HOME}/.ai-tools/npm\n' > /etc/skel/.npmrc && \
    install -d /etc/skel/.local/bin && \
    printf '%s\n' \
      'export UV_TOOL_DIR="$HOME/.ai-tools/uv"' \
      'export UV_TOOL_BIN_DIR="$HOME/.ai-tools/uv/bin"' \
      'export PATH="$HOME/.ai-tools/npm/bin:$HOME/.ai-tools/uv/bin:$HOME/.ai-tools/bin:$HOME/.local/bin:$PATH"' \
      | tee /etc/profile.d/ai-tools.sh >> /etc/bash.bashrc

# Ship the runtime agent-tool scripts (invoked by entrypoint: reconcile as the sandbox
# user, linker as root).
COPY agent-tools-reconcile.sh /usr/local/bin/agent-tools-reconcile.sh
COPY link-agent-tools.sh /usr/local/bin/link-agent-tools.sh
RUN chmod +x /usr/local/bin/agent-tools-reconcile.sh /usr/local/bin/link-agent-tools.sh
```

> Note: `printf 'prefix=${HOME}/.ai-tools/npm\n'` is single-quoted so `${HOME}` stays **literal**; npm expands `${VAR}` in npmrc at runtime, per renamed sandbox user.

- [ ] **Step 4: Create the wiring test** — `tests/test-entrypoint-wiring.sh`:

```bash
#!/usr/bin/env bash
# Asserts the runtime agent-tool hooks are defined and wired into entrypoint.sh in all
# three modes. (grep '<name>$' matches only the call-sites; the '<name>() {' def line
# ends in '{', not the name, so it is not counted.)
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0; pass(){ printf 'PASS: %s\n' "$1"; }; fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
bash -n "$REPO_DIR/entrypoint.sh" && pass "entrypoint.sh bash -n" || fail "entrypoint.sh bash -n"
grep -q 'run_agent_tools_reconcile()' "$REPO_DIR/entrypoint.sh" && pass "defines run_agent_tools_reconcile" || fail "defines run_agent_tools_reconcile"
grep -q 'link_agent_tools()' "$REPO_DIR/entrypoint.sh" && pass "defines link_agent_tools" || fail "defines link_agent_tools"
nr="$(grep -c 'run_agent_tools_reconcile$' "$REPO_DIR/entrypoint.sh")"; [[ "$nr" -ge 3 ]] && pass "reconcile wired in 3 modes ($nr)" || fail "reconcile wired in 3 modes ($nr)"
nl="$(grep -c 'link_agent_tools$' "$REPO_DIR/entrypoint.sh")"; [[ "$nl" -ge 3 ]] && pass "linker wired in 3 modes ($nl)" || fail "linker wired in 3 modes ($nl)"
printf '\n%d failure(s)\n' "$fails"; exit "$fails"
```

- [ ] **Step 5: Verify wiring + Dockerfile syntax**

Run: `bash tests/test-entrypoint-wiring.sh && bash tests/test-agent-tools-reconcile.sh && bash tests/test-link-agent-tools.sh && docker build --check "$PWD"`
Expected: all three test files report `0 failure(s)`; `docker build --check` reports no errors.

- [ ] **Step 6: Commit**

```bash
git add entrypoint.sh Dockerfile tests/test-entrypoint-wiring.sh
git commit -m "feat: wire agent-tools reconcile + linker into entrypoint; bake tool-home scaffolding"
```

---

## Task 5: Remove the six baked install layers + drop their build.sh mappings + graphify.txt hygiene

**Files:**
- Modify: `Dockerfile` (remove Vale `:224-234`; Copilot install in `:392-394`; Claude `:405-413`; Codex `:415-416`; Gemini `:418-419`; graphify `:466-471`; and their `ARG INSTALL_*` lines)
- Modify: `build.sh` (`bool_mappings` `:176-195` — drop 6 entries)
- Modify: `allowlist-domains.d/graphify.txt`

**Interfaces:** none produced; removes build-time installs so the runtime reconcile is the sole installer.

- [ ] **Step 1: Remove the Vale layer** — delete the whole block starting at `ARG INSTALL_VALE=0` (`:224`) through its `RUN … vale --version; … fi` (`:234`), plus the 3-line `# ── Vale …` comment above it (`:216-223`).

- [ ] **Step 2: Remove the npm-agent install layers.** Delete:
  - `ARG INSTALL_CLAUDE_CODE=0` + its `RUN …` block (`:405-413`).
  - `ARG INSTALL_CODEX=0` + `RUN if [ "$INSTALL_CODEX" = "1" ]; then npm install -g @openai/codex; fi` (`:415-416`).
  - `ARG INSTALL_GEMINI=0` + `RUN if [ "$INSTALL_GEMINI" = "1" ]; then npm install -g @google/gemini-cli; fi` (`:418-419`).
  - For Copilot, change the marker RUN (`:392-394`) to drop the install but **keep the marker** (removed in Phase 2). Replace:
    ```dockerfile
    ARG INSTALL_COPILOT=0
    RUN echo "agents cache-bust token: ${AGENTS_CACHE_BUST}" >/dev/null && \
        if [ "$INSTALL_COPILOT" = "1" ]; then npm install -g @github/copilot; fi
    ```
    with:
    ```dockerfile
    RUN echo "agents cache-bust token: ${AGENTS_CACHE_BUST}" >/dev/null
    ```

- [ ] **Step 3: Remove the graphify layer** — delete `ARG INSTALL_GRAPHIFY=0` + its `RUN … uv tool install graphifyy …` block (`:466-471`) and the `# ── Optional: graphify` comment above it.

- [ ] **Step 4: Drop the six `build.sh` mappings.** In `bool_mappings` (`:176-195`), delete exactly these lines (keep `kiro:INSTALL_KIRO` and all others):

```
    "copilot:INSTALL_COPILOT"
    "claude-code:INSTALL_CLAUDE_CODE"
    "codex:INSTALL_CODEX"
    "gemini:INSTALL_GEMINI"
    "graphify:INSTALL_GRAPHIFY"
    "vale:INSTALL_VALE"
```

Leave the allowlist `include_if_enabled …/{github-copilot,claude-code,codex,gemini,graphify,vale}.txt` lines (`:125-126,142,150-155` etc.) **untouched** — still needed at runtime.

- [ ] **Step 5: graphify.txt PyPI hygiene (optional, do it).** Append to `allowlist-domains.d/graphify.txt` so graphify's runtime PyPI install does not depend on the pyenv fragment:

```
# PyPI — graphify installs at runtime via `uv tool install` (also covered by pyenv.txt).
pypi.org
files.pythonhosted.org
```

- [ ] **Step 6: Verify**

Run: `docker build --check "$PWD" && grep -c 'INSTALL_CLAUDE_CODE\|INSTALL_CODEX\|INSTALL_GEMINI\|INSTALL_GRAPHIFY\|INSTALL_VALE\|npm install -g @github/copilot' Dockerfile; ./build.sh --help >/dev/null && echo help-ok`
Expected: `docker build --check` clean; the grep count is `0`; `help-ok`. Also confirm the six allowlist `include_if_enabled` lines still exist: `grep -c 'claude-code.txt\|codex.txt\|gemini.txt\|graphify.txt\|vale.txt\|github-copilot.txt' build.sh` ≥ 6.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile build.sh allowlist-domains.d/graphify.txt
git commit -m "feat: stop baking the six agent-tier tools (runtime-installed now); keep allowlists"
```

---

## Task 6: Real-container restricted-mode smoke test (BLOCKING pre-merge gate)

**Files:**
- Create: `tests/test-agent-tools-smoke.sh` (gated; not run by default `run-all.sh`)

**Interfaces:** validates the whole Phase-1 chain end-to-end behind the firewall.

- [ ] **Step 1: Create the gated smoke test** — `tests/test-agent-tools-smoke.sh`:

```bash
#!/usr/bin/env bash
# BLOCKING pre-merge gate. Builds the image and runs a RESTRICTED-mode container against
# a scratch group, proving each enabled agent-tier tool installs BEHIND THE FIREWALL,
# persists across runs, and resolves under a non-login `docker exec`.
# Gated: only runs when AGENT_TOOLS_SMOKE=1 (needs Docker + network + DOCKER_CONFIG).
set -uo pipefail
[[ "${AGENT_TOOLS_SMOKE:-0}" == "1" ]] || { echo "SKIP: set AGENT_TOOLS_SMOKE=1 to run the real-container smoke test"; exit 0; }
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="ai-sandbox-smoke"
fails=0; pass(){ printf 'PASS: %s\n' "$1"; }; fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# 1. A normal build suffices: the install-source hosts (npm registry + GitHub in
#    base.txt, PyPI in pyenv.txt) are included in the restricted allowlist
#    UNCONDITIONALLY (build.sh:119/:136), independent of which tools are ON. The
#    firewall still applies at runtime — this gate proves install works behind it.
IMAGE_NAME="$IMG" "$REPO_DIR/build.sh" "$IMG" || { fail "image build"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

group="smoke-$$"
run() { # run a restricted container to completion of a probe command
  docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -e DEV_CONTAINER_MODE=restricted \
    -e AI_RUNTIME_TOOLS="claude-code,copilot,codex,gemini,graphify,vale" \
    -e AI_CONTAINER_GROUP="$group" \
    -v "$HOME/.ai-containers/$group/.ai-tools:/home/$(id -un)/.ai-tools" \
    --entrypoint bash "$IMG" -lc "$1"
}

# 2. First run: tools install behind the firewall; assert each resolves via non-login exec.
run 'for t in claude codex gemini copilot graphify vale; do command -v "$t" >/dev/null || { echo MISSING:$t; exit 3; }; done; echo ALLPRESENT' \
  | grep -q ALLPRESENT && pass "all six install + resolve behind the firewall (first run)" \
  || fail "all six install + resolve behind the firewall (first run)"

# 3. Second run: tools persist in the group home and still resolve (no reinstall needed).
run 'for t in claude graphify vale; do command -v "$t" >/dev/null || { echo MISSING:$t; exit 3; }; done; echo PERSISTED' \
  | grep -q PERSISTED && pass "tools persist to a second run (no reinstall needed)" \
  || fail "tools persist to a second run"

docker rmi "$IMG" >/dev/null 2>&1 || true
rm -rf "$HOME/.ai-containers/$group" 2>/dev/null || true
printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run the gate** (manually / in CI, with Docker available):

Run: `DOCKER_CONFIG=<cfg-dir> AGENT_TOOLS_SMOKE=1 bash tests/test-agent-tools-smoke.sh`
Expected: `0 failure(s)` — all six install behind the firewall on the first run and persist on the second. **If any tool needs a host beyond `base.txt`/its fragment, add it to that tool's `allowlist-domains.d/<tool>.txt`, rebuild, and re-run until green.** This gate must pass before merge.

- [ ] **Step 3: Confirm the default suite still ignores it**

Run: `rm -f .agents-cache-bust; bash tests/run-all.sh`
Expected: green; the smoke test prints `SKIP` (not gated on).

- [ ] **Step 4: Commit**

```bash
git add tests/test-agent-tools-smoke.sh
git commit -m "test: gated restricted-mode real-container smoke gate for runtime tools"
```

---

# PHASE 2 — Retire `AGENTS_CACHE_BUST`

> Safe only after Phase 1: the marker's agent customers are gone.

## Task 7: Remove the marker (Dockerfile) + cache-bust logic (build.sh) + helpers (sandbox-common.sh)

**Files:**
- Modify: `Dockerfile` (`:378-393` — comment + `ARG AGENTS_CACHE_BUST=0` + marker RUN)
- Modify: `build.sh` (`:318-334` cache-bust build-arg; `:357` write call; help `:25-40`)
- Modify: `sandbox-common.sh` (`:66-106` cache-bust helpers + file var)

- [ ] **Step 1: Dockerfile** — delete the `# ── Optional: npm-based agent tools …` / `AGENTS_CACHE_BUST` comment block (`:378-390`), the `ARG AGENTS_CACHE_BUST=0` line (`:391`), and the marker `RUN echo "agents cache-bust token: ${AGENTS_CACHE_BUST}" >/dev/null` left by Task 5. Replace the region with a one-line successor comment:

```dockerfile
# ── Agent CLIs are NOT baked — they install at container start into ~/.ai-tools ──
```

- [ ] **Step 2: build.sh** — delete the cache-bust comment + block (`:318-334`): the `local agents_bust=…` through `build_args+=(--build-arg "AGENTS_CACHE_BUST=${agents_bust}")`. Delete the `write_agents_cache_bust "$agents_bust"` line (`:357`) and its 2-line comment above it (`:355-356`). In the help text (`:29-40`) delete the entire `AGENTS_CACHE_BUST` paragraph.

- [ ] **Step 3: sandbox-common.sh** — delete the `# ── Agent-layer cache-bust token …` block (`:66-106`): the comment, `agents_cache_bust_file=…`, `read_agents_cache_bust()`, and `write_agents_cache_bust()`. (Leave the image-cleanup helper below `:108` intact — it is not cache-bust-specific.)

- [ ] **Step 4: Verify**

Run: `docker build --check "$PWD" && bash -n build.sh && bash -n sandbox-common.sh && ! grep -rn 'AGENTS_CACHE_BUST' Dockerfile build.sh sandbox-common.sh && ./build.sh --help >/dev/null && echo ok`
Expected: `ok` (grep finds nothing in those three files; syntax clean).

- [ ] **Step 5: Commit**

```bash
git add Dockerfile build.sh sandbox-common.sh
git commit -m "refactor: retire AGENTS_CACHE_BUST marker + build.sh persistence + helpers"
```

---

## Task 8: Remove the staleness check from `sandbox.sh`

**Files:**
- Modify: `sandbox.sh` (`maybe_rebuild_stale_image` `:290-352`; its call `:356`)

- [ ] **Step 1** — delete the `maybe_rebuild_stale_image()` function and its leading comment (`:290-352`), and the `image_age_hours` helper above it **only if** it has no other caller (verify: `grep -n image_age_hours sandbox.sh` — if `maybe_rebuild_stale_image` is its sole caller, remove it too).

- [ ] **Step 2** — delete the lone `maybe_rebuild_stale_image` call inside `run_container()` (`:356`).

- [ ] **Step 3: Verify**

Run: `bash -n sandbox.sh && ! grep -n 'maybe_rebuild_stale_image\|AGENT_REBUILD_MAX_AGE_HOURS\|AGENT_REBUILD_ACK' sandbox.sh && echo ok`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add sandbox.sh
git commit -m "refactor: drop image-staleness auto-rebuild (agents self-update at runtime)"
```

---

## Task 9: Retire ignore-file entries + cache-bust tests; fix the pinned sync contract

**Files:**
- Modify: `project-init.sh` (`:298`), root `.gitignore` (`:36`), `.dockerignore` (`:13`)
- Delete: `tests/test-agents-cache-bust.sh`, `tests/test-image-staleness.sh`
- Modify: `tests/test-sync-project.sh` (`:116`, `:315`), `tests/test-project-init.sh` (`:42-47`), `tests/test-repo-registry.sh` (`:25`)

- [ ] **Step 1** — remove `.agents-cache-bust` from the `project-init.sh` gitignore pattern list (`:298`), from root `.gitignore` (`:36`, `/.agents-cache-bust`), and from `.dockerignore` (`:13`).

- [ ] **Step 2** — `git rm tests/test-agents-cache-bust.sh tests/test-image-staleness.sh`.

- [ ] **Step 3** — update the pinned shared-file contract in `tests/test-sync-project.sh`: in the `expected_shared_files` array and its comment (`:116` area) **remove** `.agents-cache-bust` and **add** `agent-tools-reconcile.sh` and `link-agent-tools.sh`; drop `.agents-cache-bust` from the ignore-pattern assertion (`:315`).

- [ ] **Step 4** — in `tests/test-project-init.sh` (`:42-47`) remove the "cache-bust token is gitignored" assertion. In `tests/test-repo-registry.sh` (`:25`) update the comment that references `test-agents-cache-bust.sh` to name a still-existing fake-`docker` test (e.g. `test-repo-registry.sh` itself, or drop the cross-reference).

- [ ] **Step 5: Verify the whole suite**

Run: `rm -f .agents-cache-bust; bash tests/run-all.sh`
Expected: green — the two deleted tests no longer run; `test-sync-project.sh`, `test-project-init.sh`, `test-repo-registry.sh`, and the new tests all pass. (Auto-discovery picks up the new `tests/test-*.sh`.)

- [ ] **Step 6: Commit**

```bash
git add -A project-init.sh .gitignore .dockerignore tests/
git commit -m "test: delete cache-bust tests; pin the two new runtime scripts; drop cache-bust ignores"
```

---

## Task 10: Docs sweep

**Files:**
- Modify: `README.md` (`:81-87`, `:180`, `:397`, `:404-410`), `AGENTS.md` (`:43-53`, `:127-129`, `:230`), `tools.d/acli.conf` (`:13`), `CHANGELOG.md`

- [ ] **Step 1: README.md** — remove the "Targeted agent refresh" section (`:81-87`) and the `AGENTS_CACHE_BUST` env-table row (`:180`); replace with a short note that agents/graphify/Vale install at container start into the group-mounted `~/.ai-tools` and self-update in place, and that **baked** tools (Kiro, `tools.d`) refresh via `./build.sh --no-cache`. Rewrite the Vale/GoReleaser 72h note (`:397`) and the acli "The regular 72-hour agent refresh re-fetches it" claim (`:404-410`) to the `--no-cache`/pin reality.

- [ ] **Step 2: AGENTS.md** — remove the `AGENTS_CACHE_BUST` explainer (`:43-53`), the two env-table rows (`AGENT_REBUILD_MAX_AGE_HOURS`, `AGENTS_CACHE_BUST` — `:127-129`), and the `ARG AGENTS_CACHE_BUST` architecture paragraph (`:230`). Add one paragraph on the runtime tool home mirroring the rvm section.

- [ ] **Step 3: tools.d/acli.conf** — rewrite the `:13` comment that references "the Dockerfile's AGENTS_CACHE_BUST … 72-hour agent refresh" to: the tools layer is baked and refreshes via `./build.sh --no-cache` (or pin the version).

- [ ] **Step 4: CHANGELOG.md** — add an Unreleased **Breaking** entry: the six agent-tier tools now install at container start into the group-mounted `~/.ai-tools` (install-if-missing; self-update in place; persist per group); `AGENTS_CACHE_BUST` and `AGENT_REBUILD_MAX_AGE_HOURS` are removed; Kiro and `tools.d` stay baked and refresh via `--no-cache`.

- [ ] **Step 5: Verify no stale claims remain**

Run: `! grep -rn 'AGENTS_CACHE_BUST\|AGENT_REBUILD_MAX_AGE_HOURS\|72-hour agent refresh\|regular 72-hour' README.md AGENTS.md tools.d/ && echo ok` (CHANGELOG keeps history — exclude it).
Expected: `ok`.

- [ ] **Step 6: Commit**

```bash
git add README.md AGENTS.md tools.d/acli.conf CHANGELOG.md
git commit -m "docs: runtime tool home + --no-cache refresh for baked tools; purge AGENTS_CACHE_BUST"
```

---

## Final verification (before the whole-branch review)

- [ ] `rm -f .agents-cache-bust; bash tests/run-all.sh` → green.
- [ ] `! grep -rn 'AGENTS_CACHE_BUST\|AGENT_REBUILD_MAX_AGE_HOURS' --include='*.sh' --include='Dockerfile*' --include='*.md' . | grep -v CHANGELOG` → empty.
- [x] ~~`AGENT_TOOLS_SMOKE=1 bash tests/test-agent-tools-smoke.sh` (the BLOCKING gate)~~ — **the file was deleted 2026-09-01 as superseded.**
      It never ran in any layer, and its two claims are each WEAKER than the
      packages-tier cases that absorbed them: it polled as **root** where case
      700 asserts resolution as the non-root agent, and its second run passed
      even on a full reinstall, which is exactly what case 710 exists to detect.
      (Its `DOCKER_CONFIG` was also never referenced by the file.) Running it
      once before deleting was not ceremony: it exposed a fork bomb in
      `build.sh`, fixed in the same change and now guarded by
      `tests/test-provenance.sh`.
- [ ] `docker build --check "$PWD"` → clean.
