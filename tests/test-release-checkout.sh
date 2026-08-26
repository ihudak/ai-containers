#!/usr/bin/env bash
# tests/test-release-checkout.sh — the release job's checkout must hand
# release-title.sh a real annotated tag OBJECT.
#
# WHY THIS EXISTS. de3c706 made the release title come from the annotated tag's
# message and added `fetch-tags: true` so the tag object would be present. That
# combination was never exercised by a release — v0.7.0 had already been
# published from the previous configuration — and v0.8.0, the first release
# after it, failed at the checkout step before any of this repo's own scripts
# ran:
#
#   fatal: Cannot fetch both <sha> and refs/tags/v0.8.0 to refs/tags/v0.8.0
#
# `fetch-tags: true` drops checkout's `--no-tags`, so git's automatic
# tag-following targets refs/tags/<tag> at the same moment as checkout's own
# explicit `+<sha>:refs/tags/<tag>` refspec, and git refuses two sources for one
# destination.
#
# The trap is the obvious repair. Removing `fetch-tags` makes the fetch succeed
# and leaves refs/tags/<tag> pointing at a COMMIT — release-title.sh then reads
# a lightweight tag and falls back to the bare name, which is the exact defect
# de3c706 existed to fix. Green workflow, silently worse release.
#
# AND `fetch-depth: 0` alone is not the answer either, which the FIRST version of
# this file got wrong and shipped. It simulated ONE fetch. checkout performs TWO
# on a tag push, the second undoing the first — observed in the runner log:
#
#   git fetch ... +refs/heads/*:... +refs/tags/*:refs/tags/*   <- the tag object
#   git fetch --no-tags ... +<sha>:refs/tags/v0.8.0            <- clobbers it
#
# So this file passed on a configuration that published a bare-titled release,
# which is worse than no guard: it was consulted, and it agreed. The sequence
# below is now the one the runner actually issues, and the workflow's own
# recovery step is EXECUTED rather than assumed — a release.yml that stops
# restoring the tag object fails here.
#
# The property asserted is a usable annotated tag, never the spelling of a YAML
# key. A future edit that swaps one plausible-looking key for another has to
# survive that, not merely look reasonable in review.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_DIR/.github/workflows/release.yml"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -f "$WF" ]] || { printf 'SCAFFOLD-FAILED: no release.yml at %s\n' "$WF"; exit 1; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── Read the checkout's fetch configuration ───────────────────────────────────
# Scoped to the checkout step's own `with:` block, so an unrelated `fetch-depth`
# elsewhere in the file cannot be mistaken for this one.
block="$(awk '/uses: actions\/checkout/{f=1} f{print} f&&/^      - name:/{exit}' "$WF")"
depth="$(grep -oE '^\s*fetch-depth:\s*[0-9]+' <<<"$block" | grep -oE '[0-9]+$' | head -1)"
tags="$(grep -oE '^\s*fetch-tags:\s*(true|false)' <<<"$block" | grep -oE '(true|false)$' | head -1)"
depth="${depth:-1}"          # actions/checkout's documented default
tags="${tags:-false}"
printf 'release.yml checkout: fetch-depth=%s fetch-tags=%s\n' "$depth" "$tags"

# ── A fixture remote with a real annotated tag ────────────────────────────────
# Built here rather than borrowed from this repository: the assertion must hold
# on a CI runner whose checkout has no tags at all, and a fixture is the only
# way to be sure the tag under test is the one this file created.
UP="$TMP/upstream"; mkdir -p "$UP"
git -C "$UP" init -q -b main 2>/dev/null || git -C "$UP" init -q
# Identity in the repo's own config: `git tag -a` needs a TAGGER, and CI runners
# have no global one. A fixture that half-builds its repo and carries on is how
# an assertion ends up measuring the fallback path while claiming otherwise.
git -C "$UP" config user.email "fixture@example.invalid" || { printf 'SCAFFOLD-FAILED: git config\n'; exit 1; }
git -C "$UP" config user.name  "release fixture"        || { printf 'SCAFFOLD-FAILED: git config\n'; exit 1; }
git -C "$UP" commit -q --allow-empty -m init            || { printf 'SCAFFOLD-FAILED: git commit\n'; exit 1; }
git -C "$UP" tag -a v9.9.9 -m "v9.9.9 — the title under test" || { printf 'SCAFFOLD-FAILED: git tag -a\n'; exit 1; }
[[ "$(git -C "$UP" cat-file -t v9.9.9 2>/dev/null)" == "tag" ]] \
  || { printf 'SCAFFOLD-FAILED: the fixture tag is not an annotated object\n'; exit 1; }
pass "scaffold: the fixture upstream carries an annotated tag"
SHA="$(git -C "$UP" rev-parse 'v9.9.9^{commit}')"

# ── Perform the fetch release.yml's configuration implies ─────────────────────
# Mirrors what actions/checkout issues for a TAG push: with a shallow depth it
# maps the commit onto the tag ref explicitly, and passes --no-tags unless
# fetch-tags asked otherwise; with depth 0 it fetches heads and tags wholesale.
DOWN="$TMP/runner"; mkdir -p "$DOWN"
git -C "$DOWN" init -q
git -C "$DOWN" remote add origin "$UP"
fetch_ok=1
if [[ "$depth" != "0" ]]; then
  # Shallow: one fetch, mapping the commit onto the tag ref. --no-tags unless
  # fetch-tags asked otherwise, which is the combination that fails outright.
  shallow=(fetch --prune --no-recurse-submodules --depth="$depth")
  [[ "$tags" == "true" ]] || shallow+=(--no-tags)
  shallow+=(origin "+${SHA}:refs/tags/v9.9.9")
  git -C "$DOWN" "${shallow[@]}" >/dev/null 2>&1 || fetch_ok=0
else
  # depth 0: checkout fetches heads AND tags, then STILL force-updates the tag
  # ref to the commit. Both are issued here because both happen.
  git -C "$DOWN" fetch --prune --no-recurse-submodules origin \
      '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*' >/dev/null 2>&1 || fetch_ok=0
  git -C "$DOWN" fetch --no-tags --prune --no-recurse-submodules origin \
      "+${SHA}:refs/tags/v9.9.9" >/dev/null 2>&1 || fetch_ok=0
fi

if (( fetch_ok )); then
  pass "the configured checkout fetch SUCCEEDS on a tag push"
else
  fail "the configured checkout fetch SUCCEEDS on a tag push — this is the 'Cannot fetch both <sha> and refs/tags/<tag>' failure that broke v0.8.0's first release attempt"
fi

# ── Now run the workflow's OWN recovery, whatever it is ───────────────────────
# Extracted from release.yml rather than restated, so a workflow that stops
# restoring the tag object cannot keep this file green. The tag name is
# substituted for the fixture's; nothing else about the command is interpreted.
# `.*`, not `[^\n]*`: in a POSIX bracket expression that reads as "not backslash,
# not the letter n", so it truncated `origin` to `origi` and the restore silently
# fetched from a remote that does not exist. grep is line-oriented anyway.
mapfile -t restores < <(grep -oE '^[[:space:]]*git fetch .*' "$WF" | sed 's/^[[:space:]]*//')
if (( ${#restores[@]} == 0 )); then
  fail "release.yml runs no git fetch of its own — checkout leaves refs/tags/<tag> on a COMMIT, so the title degrades to the bare tag name"
else
  pass "release.yml restores the tag object itself (${#restores[@]} fetch command(s))"
  for r in "${restores[@]}"; do
    # The workflow names the tag through $GITHUB_REF_NAME; the fixture's tag
    # stands in for it. sed rather than parameter expansion so the brace form
    # needs no escaping gymnastics to match.
    cmd="$(printf '%s' "$r" | sed 's/\${GITHUB_REF_NAME}/v9.9.9/g')"
    ( cd "$DOWN" && eval "$cmd" ) >/dev/null 2>&1 || true
  done
fi

# ── What landed must be a tag OBJECT, not a ref onto a commit ─────────────────
kind="$(git -C "$DOWN" cat-file -t v9.9.9 2>/dev/null || echo missing)"
if [[ "$kind" == "tag" ]]; then
  pass "refs/tags/<tag> is an annotated tag object, so the message is available"
else
  fail "refs/tags/<tag> is an annotated tag object — got '$kind', so release-title.sh sees a lightweight tag and publishes the bare tag name instead of the title"
fi

# ── The end of the chain: the real script, against that fetch ─────────────────
# The two assertions above describe the mechanism; this one is the outcome
# anybody actually cares about, and it is checked with the SHIPPED script rather
# than a restatement of what it should do.
# bash-floor.sh travels with it: release-title.sh sources the floor guard, and
# without it the script still prints the right title but emits a "No such file"
# line first — which is exactly the kind of noise that turns a real assertion
# into a confusing one.
cp "$REPO_DIR/release-title.sh" "$REPO_DIR/bash-floor.sh" "$DOWN/" 2>/dev/null
title="$( cd "$DOWN" && bash ./release-title.sh v9.9.9 2>&1 )"
if [[ "$title" == "v9.9.9 — the title under test" ]]; then
  pass "release-title.sh renders the tag's message under this configuration"
else
  fail "release-title.sh renders the tag's message under this configuration (got: '$title')"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
