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
# The step takes the tags from its environment (TST-39), as the workflow's env: gives them.
if ! grep -q '\${{' "$TMP/step.sh"; then
  pass "TST-39 the step's script holds no \${{ }}: what it uses comes through env:, never pasted into the script"
else
  fail "TST-39 the step's script holds \${{ }} (left: $(grep -o '\${{[^}]*}}' "$TMP/step.sh" | head -n 1))"
fi
# The step's environment is its own env: mapping, rendered as GitHub would, not
# names this test sets: a mapping that swapped the two, or was lost, must fail
# here (review of the TST-39 fix).
stepenv=()
while IFS= read -r kv; do
  kv="${kv//'${{ steps.latest.outputs.tag }}'/v9.9.9}"
  kv="${kv//'${{ steps.current.outputs.dockerfile }}'/$current}"
  stepenv+=("${kv%%: *}=${kv#*: }")
done < <(awk -v step="$STEP" '
  $0 == "      - name: " step { instep = 1; next }
  instep && /^      - / { exit }
  instep && /^        env:[[:space:]]*$/ { inenv = 1; next }
  instep && inenv && /^          [A-Za-z_][A-Za-z0-9_]*: / { sub(/^          /, ""); print; next }
  inenv { inenv = 0 }
' "$WF")
if (( ${#stepenv[@]} )) && ! printf '%s\n' "${stepenv[@]}" | grep -q '\${{'; then
  pass "the step's env: mapping is read and every value in it rendered (${#stepenv[@]} names)"
else
  fail "the step's env: mapping is read and every value in it rendered (got: ${stepenv[*]:-nothing})"
fi
( cd "$TMP/r" && env -u LATEST -u CURRENT ${stepenv[@]+"${stepenv[@]}"} GITHUB_OUTPUT="$TMP/out" bash -e "$TMP/rendered.sh" ) >/dev/null 2>&1; rc=$?
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

# A tag that is not nvm's shape is refused before anything uses it (TST-39):
# one with a quote and a command substitution, and one with an & that sed would
# take for the matched text, writing a line nobody asked for (a slash, which sed
# refuses by itself, would pass with no check at all).
for bad in 'v1.0.0"$(touch "$PWN")"' 'v1.0.0&'; do
  ( cd "$TMP/r" && git checkout -q -- . && PWN="$TMP/pwned" GITHUB_OUTPUT="$TMP/out2" LATEST="$bad" CURRENT="$current" \
      bash -e "$TMP/rendered.sh" ) >/dev/null 2>&1; rc=$?
  if [[ "$rc" != 0 && ! -e "$TMP/pwned" ]] && [[ -z "$(cd "$TMP/r" && git diff --name-only)" ]]; then
    pass "TST-39 the update step refuses the tag $bad and changes nothing"
  else
    fail "TST-39 the update step took the tag $bad (rc $rc)"
  fi
done
# The step that fetches the tag checks its shape where it is first read.
awk -v step="Get latest nvm release tag" '
  $0 == "      - name: " step { instep = 1; next }
  instep && /^      - / { exit }
  instep && /^        run: \|[[:space:]]*$/ { inrun = 1; next }
  inrun && /^[[:space:]]*$/ { print ""; next }
  inrun && /^          / { sub(/^          /, ""); print; next }
  inrun { exit }
' "$WF" | sed 's/\${{ secrets\.GITHUB_TOKEN }}/x/g' > "$TMP/latest.sh"
if ! command -v jq >/dev/null 2>&1; then
  printf "SKIP: TST-39 the fetch step's check: no jq here\n"
else
  mkdir -p "$TMP/fakebin"
  printf '#!/bin/sh\nprintf "%%s" "$FAKE_JSON"\n' > "$TMP/fakebin/curl"; chmod +x "$TMP/fakebin/curl"
  for tag in 'v0.40.5' 'v1.0.0"; touch pwned; "' 'main'; do
    : > "$TMP/out3"
    PATH="$TMP/fakebin:$PATH" FAKE_JSON="$(jq -n --arg t "$tag" '{tag_name: $t}')" GITHUB_OUTPUT="$TMP/out3" \
      bash -e "$TMP/latest.sh" >/dev/null 2>&1; rc=$?
    if [[ "$tag" == v0.40.5 ]]; then
      [[ "$rc" == 0 ]] && grep -qx 'tag=v0.40.5' "$TMP/out3" \
        && pass "TST-39 the fetch step passes nvm's own tag" || fail "TST-39 the fetch step refused v0.40.5 (rc $rc)"
    else
      [[ "$rc" != 0 && ! -s "$TMP/out3" ]] \
        && pass "TST-39 the fetch step refuses the tag $tag" || fail "TST-39 the fetch step took the tag $tag (rc $rc)"
    fi
  done
fi

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
