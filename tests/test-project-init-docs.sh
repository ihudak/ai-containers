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
