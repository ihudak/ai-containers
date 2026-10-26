#!/usr/bin/env bash
# tests/test-nvm-update-workflow.sh — the weekly nvm bump's pull request says
# which files it changed, and that list must be the files the job changes.
#
# The body told every reviewer that `sandbox.conf` (`nvm-version`) was
# updated. Since f7cdc3c the job edits only the Dockerfile's ARG NVM_VERSION —
# the key is empty by design and defers to it — so the claim was false on every
# automated PR (TST-8).
#
# By EFFECT, not by reading prose: the job's own "Update files" step is cut out
# of the workflow, its two step outputs rendered, and run against a scratch
# copy of the Dockerfile and sandbox.conf in a throwaway git repository. What
# git then reports as modified is compared with the body's list.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_DIR/.github/workflows/update-nvm-version.yml"
STEP="Update files if version changed"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# mgd-ai-containers does not ship this workflow (tests/layer-checks.conf's
# `workflow` rows say why), so its absence there is not a defect.
if [[ ! -f "$WF" ]]; then
  printf 'SKIP: %s is not in this repository\n' "${WF#"$REPO_DIR"/}"
  exit 0
fi
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# The step's `run: |` block, its indentation removed.
awk -v step="$STEP" '
  $0 == "      - name: " step { instep = 1; next }
  instep && /^      - / { exit }
  instep && /^        run: \|[[:space:]]*$/ { inrun = 1; next }
  inrun && /^[[:space:]]*$/ { print ""; next }
  inrun && /^          / { sub(/^          /, ""); print; next }
  inrun { exit }
' "$WF" > "$TMP/step.sh"
if [[ -s "$TMP/step.sh" ]]; then
  pass "the workflow has a '$STEP' step with a run: block"
else
  fail "the workflow has a '$STEP' step with a run: block — nothing below can be checked"
  printf '\n%d failure(s)\n' "$fails"; exit "$fails"
fi

# The files the PR body lists, one per `- \`file\` — …` line under the heading.
listed="$(awk '
  /\*\*Changed files:\*\*/ { on = 1; next }
  on && /^[[:space:]]*$/ { exit }
  on { if (match($0, /`[^`]+`/)) print substr($0, RSTART + 1, RLENGTH - 2) }
' "$WF" | LC_ALL=C sort)"
if [[ -n "$listed" ]]; then
  pass "the PR body lists the files it changed"
else
  fail "the PR body lists the files it changed (no **Changed files:** list found)"
fi

# A scratch repository holding the two files the job could touch.
mkdir -p "$TMP/r"
cp "$REPO_DIR/Dockerfile" "$REPO_DIR/sandbox.conf" "$TMP/r/" \
  || { printf 'SCAFFOLD-FAILED: could not copy the Dockerfile and sandbox.conf\n'; exit 1; }
( cd "$TMP/r" \
    && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
    && git add -A && git -c user.email=t@example -c user.name=t commit -q -m base ) >/dev/null 2>&1 \
  || { printf 'SCAFFOLD-FAILED: could not commit the scratch repository\n'; exit 1; }
current="$(sed -n 's/^ARG NVM_VERSION=//p' "$TMP/r/Dockerfile")"
[[ -n "$current" ]] || { printf 'SCAFFOLD-FAILED: the Dockerfile has no ARG NVM_VERSION= line\n'; exit 1; }

# Render the two step outputs the script reads, as GitHub would. `sed -i ` is
# GNU's form; BSD sed (stock macOS, where verify-on-host.sh runs this suite)
# takes the next word as -i's suffix, so the step is given `-i.bak`, which both
# accept. The .bak file is untracked and git diff does not list it.
sed -e 's/\${{ steps\.latest\.outputs\.tag }}/v9.9.9/g' \
    -e "s/\${{ steps\.current\.outputs\.dockerfile }}/$current/g" \
    -e 's/sed -i /sed -i.bak /g' \
    "$TMP/step.sh" > "$TMP/rendered.sh"
if grep -q '\${{' "$TMP/rendered.sh"; then
  fail "every \${{ }} in the step is rendered (left: $(grep -o '\${{[^}]*}}' "$TMP/rendered.sh" | head -n 1))"
fi
( cd "$TMP/r" && GITHUB_OUTPUT="$TMP/out" bash -e "$TMP/rendered.sh" ) >/dev/null 2>&1; rc=$?
if [[ "$rc" == 0 ]] && grep -qx 'changed=true' "$TMP/out" 2>/dev/null; then
  pass "the step updates the version and reports changed=true"
else
  fail "the step updates the version and reports changed=true (rc $rc)"
fi
changed="$(cd "$TMP/r" && git diff --name-only | LC_ALL=C sort)"

if [[ -n "$changed" && "$changed" == "$listed" ]]; then
  pass "the PR body lists exactly the files the job changes ($(tr '\n' ' ' <<<"$changed"))"
else
  fail "the PR body lists exactly the files the job changes — it lists '$(tr '\n' ' ' <<<"$listed")', the job changed '$(tr '\n' ' ' <<<"$changed")'"
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
