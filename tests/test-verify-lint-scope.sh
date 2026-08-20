#!/usr/bin/env bash
# tests/test-verify-lint-scope.sh — Phase 7 lints THE WHOLE REPO, in both layouts.
#
# Phase 7 built its file list with `( cd "$REPO" && git ls-files '*.sh' )`, and
# `git ls-files` run from a subdirectory lists only what is under that
# subdirectory. In ai-containers $REPO IS the repo root, so the list is
# complete and the defect is invisible. In mgd-ai-containers $REPO is the base/
# engine dir -- the script's own startup error tells you to run it from there --
# so Phase 7 linted 23 of 136 tracked scripts and reported "PASSED", while the
# CI job it claims to mirror runs from the checkout root and lints all 136.
# Measured on macOS 2026-08-19: "parsed 23 script(s)" against upstream's 133.
#
# The 113 it skipped were the entire hermetic suite, the whole falsify engine
# and every integration case -- and the local layer is the one that exists to
# cover what CI structurally cannot (BSD userland, macOS). A macOS-only parse
# or lint finding in those files was invisible in BOTH layers at once, which
# makes `local >= nightly >= PR` false for the lint leg rather than merely
# untested.
#
# So this file drives the real verify-on-host.sh against a stub repo in the
# SIBLING layout that no other fixture builds, with a broken script planted
# OUTSIDE the engine dir, and requires Phase 7 to report it. The witness is
# bash -n's own "PARSE ERROR: <path>" line: it can only appear if bash -n
# genuinely ran against that file's content, which is the same standard
# tests/lib-verify-repo.sh's probe rows already hold the other checks to.
#
# The upstream layout is exercised too, as a CONTROL. Without it a fixture that
# silently built nothing would look like a pass in both directions.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/verify-on-host.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
# shellcheck disable=SC2034  # read by lc_rows() in the sourced lib-layer-checks.sh, which lib-verify-repo.sh calls at SOURCE time to build its stubs — shellcheck cannot see through the source
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib-layer-checks.sh
source "$REPO_DIR/tests/lib-layer-checks.sh"
# For $TMP/bin/{docker,shellcheck}: Phase 0 calls docker and dies without it,
# and Phase 7 gates on shellcheck's status, which must not depend on whether
# the machine running this suite happens to have a real one.
# shellcheck source=lib-verify-repo.sh
source "$REPO_DIR/tests/lib-verify-repo.sh"

# ── A stub repo in either layout ──────────────────────────────────────────────
# $1 = "upstream" (engine at the repo root) or "sibling" (engine in base/).
# Prints "<repo root>|<engine dir>". Phase 7 needs little: build.sh and
# sandbox.conf to be recognised as the engine dir, bash-floor.sh to source,
# a dialect-lint stub where TESTS_DIR resolves, and a git work tree.
mk_layout() {
  local layout="$1" root engine tests
  root="$TMP/$layout"
  if [[ "$layout" == "sibling" ]]; then engine="$root/base"; else engine="$root"; fi
  tests="$root/tests"          # both layouts keep tests/ beside the ENGINE's parent
  mkdir -p "$engine" "$tests"
  cp "$VERIFY" "$engine/verify-on-host.sh"
  cp "$ENGINE_DIR/bash-floor.sh" "$engine/bash-floor.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$engine/build.sh"
  printf 'copilot=OFF\n' > "$engine/sandbox.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tests/bash-dialect-lint.sh"
  # The subject: a tracked script with a REAL syntax error, sitting outside the
  # engine directory. In the sibling layout this is the file `cd $REPO` cannot
  # see. Named so the assertion can grep for it unambiguously.
  printf '#!/usr/bin/env bash\nif [ 1 -eq\n' > "$root/outside-engine-broken.sh"
  ( cd "$root" && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
      && git add -A \
      && git -c user.email=t@example -c user.name=t commit -q -m stub ) >/dev/null 2>&1
  printf '%s|%s' "$root" "$engine"
}

check_layout() {  # $1=upstream|sibling
  local layout="$1" root engine rc out n_tracked
  IFS='|' read -r root engine <<< "$(mk_layout "$layout")"

  # The fixture's own premise, asserted rather than assumed: the broken script
  # must be TRACKED (git ls-files only lists tracked files, so an untracked one
  # would make every assertion below vacuous), and in the sibling layout it must
  # genuinely sit outside the engine dir.
  if ( cd "$root" && git ls-files --error-unmatch outside-engine-broken.sh ) >/dev/null 2>&1; then
    pass "$layout: fixture tracks the broken script"
  else
    fail "$layout: fixture does not track the broken script — the checks below would prove nothing"
    return
  fi
  if [[ "$layout" == "sibling" && -e "$engine/outside-engine-broken.sh" ]]; then
    fail "sibling: the broken script is inside the engine dir — the layout under test is not the one built"
    return
  fi
  n_tracked="$( ( cd "$root" && git ls-files '*.sh' ) | grep -c . )"

  rc="$(run_verify "$engine" 7)"
  out="$(cat "$TMP/out.log")"

  # bash -n's own line, naming the file. Nothing but bash -n reading that file's
  # content can produce it.
  if grep -q 'PARSE ERROR: outside-engine-broken.sh' <<< "$out"; then
    pass "$layout: Phase 7 parses a script outside the engine dir"
  else
    fail "$layout: Phase 7 never parsed outside-engine-broken.sh — its file list is scoped to the engine dir, not the repo ($(grep -o 'parsed [0-9]* script' <<< "$out" | head -1), repo has $n_tracked)"
  fi

  # The count, so a future change that reports the file while checking a subset
  # cannot pass. Read from Phase 7's own output rather than recomputed here.
  parsed="$(sed -n 's/.*parsed \([0-9]*\) script(s).*/\1/p' <<< "$out" | head -1)"
  if [[ "$parsed" == "$n_tracked" ]]; then
    pass "$layout: Phase 7 parsed every tracked script ($parsed of $n_tracked)"
  else
    fail "$layout: Phase 7 parsed ${parsed:-no} script(s), the repo tracks $n_tracked"
  fi

  # And it must FAIL on that parse error rather than reporting a clean phase --
  # finding the file is worthless if the verdict ignores it.
  if [[ "$rc" != "0" ]]; then
    pass "$layout: the parse error fails the phase (rc=$rc)"
  else
    fail "$layout: Phase 7 exited 0 despite a syntax error in a tracked script"
  fi
}

# ── F42: a script you have JUST WRITTEN is not yet tracked, and was skipped ───
# `git ls-files '*.sh'` lists the INDEX. Until `git add`, a new script is
# invisible to it — so the local gate reported clean over a file it never read,
# and the author's first feedback was a red CI job. It happened on the very PR
# whose subject was "the lint gate's file list silently omits files".
#
# The tracked broken script is REPAIRED first, so the only thing that can fail
# this phase is the untracked one. Without that, "the phase failed" would prove
# nothing — it already fails for the F40 reason.
check_untracked() {
  local root engine rc out parsed n_untracked
  IFS='|' read -r root engine <<< "$(mk_layout untracked)"

  printf '#!/usr/bin/env bash\ntrue\n' > "$root/outside-engine-broken.sh"
  ( cd "$root" && git add -A \
      && git -c user.email=t@example -c user.name=t commit -q -m repair ) >/dev/null 2>&1
  if [[ -n "$( cd "$root" && git status --porcelain )" ]]; then
    fail "untracked: the fixture tree is dirty before the subject is planted — the checks below would prove nothing"
    return
  fi

  # THE SUBJECT: written, not added. Exactly what an author has in hand.
  printf '#!/usr/bin/env bash\nif [ 2 -eq\n' > "$root/not-yet-added.sh"
  # AND THE CONTROL: deliberately ignored scratch, which must stay out of it.
  # `--exclude-standard` is the whole reason this is safe to turn on, so the
  # assertion that it is honoured belongs beside the one that it works.
  printf 'scratch-*.sh\n' > "$root/.gitignore"
  printf '#!/usr/bin/env bash\nif [ 3 -eq\n' > "$root/scratch-experiment.sh"

  rc="$(run_verify "$engine" 7)"
  out="$(cat "$TMP/out.log")"

  if grep -q 'PARSE ERROR: not-yet-added.sh' <<< "$out"; then
    pass "untracked: Phase 7 parses a script that is written but not yet added"
  else
    fail "untracked: Phase 7 never parsed not-yet-added.sh — the local gate still reports clean over a file it did not read ($(grep -o 'parsed [0-9]* script' <<< "$out" | head -1))"
  fi
  if [[ "$rc" != "0" ]]; then
    pass "untracked: and that parse error fails the phase (rc=$rc)"
  else
    fail "untracked: Phase 7 exited 0 with a syntax error in an untracked script — found and ignored is no better than not found"
  fi

  # THE CONTROL. An ignored file must never be linted, or every developer's
  # scratch directory becomes a gate failure.
  if grep -q 'PARSE ERROR: scratch-experiment.sh' <<< "$out"; then
    fail "untracked: a .gitignore'd script was linted — --exclude-standard is not being honoured"
  else
    pass "untracked: a .gitignore'd script is NOT linted"
  fi

  # And the phase must SAY it included them. Silence is what made the old
  # behaviour a surprise rather than a policy.
  n_untracked="$(sed -n 's/.*including \([0-9]*\) not yet tracked by git.*/\1/p' <<< "$out" | head -1)"
  if [[ "$n_untracked" == "1" ]]; then
    pass "untracked: Phase 7 says how many untracked scripts it included (1)"
  else
    fail "untracked: Phase 7 reported '${n_untracked:-no}' untracked script(s); the tree has exactly one non-ignored"
  fi
  if grep -q 'not-yet-added.sh' <<< "$(sed -n '/not yet tracked by git/,/only once committed/p' <<< "$out")"; then
    pass "untracked:   … and names it"
  else
    fail "untracked:   … and names it — the count alone does not say which file"
  fi

  # The count must cover tracked AND untracked, and NOT the ignored one.
  parsed="$(sed -n 's/.*parsed \([0-9]*\) script(s).*/\1/p' <<< "$out" | head -1)"
  expected=$(( $( ( cd "$root" && git ls-files '*.sh' ) | grep -c . ) + 1 ))
  if [[ "$parsed" == "$expected" ]]; then
    pass "untracked: the parsed count is tracked + untracked, and excludes the ignored one ($parsed)"
  else
    fail "untracked: Phase 7 parsed ${parsed:-no} script(s), expected $expected (tracked + 1 untracked, ignored excluded)"
  fi
}

check_layout upstream
check_layout sibling
check_untracked

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
