#!/usr/bin/env bash
# Integration test for project-init.sh's generated runme.sh launcher.
# Drives project-init non-interactively (scripted stdin) inside an isolated copy
# of the repo so its projects.conf/shared-file writes never touch the real tree,
# then asserts the generated launcher carries the guarded GITHUB_TOKEN block.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Isolated script_dir: a copy of the repo so projects.conf and shared-file copies
# land in TMP, not the working tree. Exclude heavy/irrelevant dirs.
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
rsync -a --exclude='.git' --exclude='tests' --exclude='docs' "$REPO_DIR/"/ "$SCRIPTS/"

# Isolated HOME so group-init prompts fire deterministically (no ~/.ai-containers).
export HOME="$TMP/home"; mkdir -p "$HOME"

# Target project (a git repo, as real projects are).
PROJ="$TMP/proj/myproj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q

# Scripted answers, in prompt order:
#   path, name(def), image(def), cpus(def), memory(def), reservation(def),
#   memory+swap(def), group(def "default"), group-init menu(1 → from:host),
#   extra-mounts(empty). Launcher doesn't exist yet, so no overwrite prompt.
printf '%s\n\n\n\n\n\n\n\n\n\n' "$PROJ" | bash "$SCRIPTS/project-init.sh" >/dev/null 2>&1

LAUNCHER="$PROJ/.ai-containers/runme.sh"
if [[ -f "$LAUNCHER" ]]; then
  pass "launcher generated"
else
  fail "launcher generated (missing $LAUNCHER)"; echo "$fails FAILED"; exit 1
fi

grep -q 'command -v gh' "$LAUNCHER"                    && pass "gh guard present"        || fail "gh guard present"
grep -q ': "${GITHUB_TOKEN:=$(gh auth token' "$LAUNCHER" && pass "non-clobbering assign" || fail "non-clobbering assign"
grep -q 'export GITHUB_TOKEN' "$LAUNCHER"              && pass "token exported"          || fail "token exported"

# The token block must come BEFORE ./build.sh (else the build can't see it).
tok_line="$(grep -n 'export GITHUB_TOKEN' "$LAUNCHER" | head -1 | cut -d: -f1)"
build_line="$(grep -n '^\./build\.sh' "$LAUNCHER" | head -1 | cut -d: -f1)"
if [[ -n "$tok_line" && -n "$build_line" && "$tok_line" -lt "$build_line" ]]; then
  pass "token block precedes ./build.sh"
else
  fail "token block precedes ./build.sh (tok=$tok_line build=$build_line)"
fi

# The generated launcher must be valid bash.
bash -n "$LAUNCHER" && pass "launcher parses" || fail "launcher parses"

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
