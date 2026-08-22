#!/usr/bin/env bash
# tests/test-lint-empty-corpus.sh — a lint that scans nothing must not report a
# clean bill of health.
#
# THE EVENT. F58: during a full `run-all.sh`, `git ls-files '*.sh'` returned
# EMPTY with every file present, and the same command was correct seconds later.
# Any check whose whole corpus comes from that one derivation inherits its
# failure — and inherits it as a GREEN, because a loop over nothing finds no
# offenders and the file then says so.
#
# tests/test-array-key-expansion.sh did exactly that until 2026-08-22: with an
# empty `ls-files` it printed its own all-clear — the one naming the plus-guarded
# array-key expansion, spelled out in that file and deliberately NOT here, since
# this file is scanned by the very rule it is describing — and exited 0, having
# examined not one file. Its sibling test-grep-q-pipelines.sh had
# counted since the day it was written, and the two sat side by side in the same
# suite disagreeing about whether that mattered.
#
# So the rule is asserted here rather than left to each file's own care: every
# lint that derives its corpus from git must REFUSE an empty one, and say so
# through the scaffold channel — an empty derivation is the environment, not a
# verdict on the rule.
#
# Cheap by construction: these lints read files and fork nothing heavy, so
# driving all three against a stub costs about a second. That is the whole
# reason this guard can exist at all — the same rule in
# tests/test-falsify-historical.sh is NOT pinned this way, because exercising it
# there means a full run of nine real oracles.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Passes everything through EXCEPT `ls-files`, which succeeds with no output —
# the shape F58 observed. A stub that FAILED instead would be a different test:
# the whole point is that git reported success and nothing at all.
real_git="$(command -v git)" || { printf 'SCAFFOLD-FAILED: no git on PATH\n'; exit 1; }
mkdir -p "$TMP/bin"
{ printf '#!/bin/sh\n'
  printf 'for a in "$@"; do [ "$a" = "ls-files" ] && exit 0; done\n'
  printf 'exec %s "$@"\n' "$real_git"
} > "$TMP/bin/git"
chmod +x "$TMP/bin/git"

# Every lint whose corpus is `git ls-files`. Adding one here is how the rule
# stays enforced for it; leaving it out is how a green that examined nothing
# ships again.
for t in test-array-key-expansion.sh test-grep-q-pipelines.sh test-bash-floor.sh; do
  [[ -f "$TESTS_DIR/$t" ]] || { fail "$t exists to be checked"; continue; }
  out="$(PATH="$TMP/bin:$PATH" bash "$TESTS_DIR/$t" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    fail "$t refuses an empty corpus — it exited 0 having scanned nothing"
    printf '%s\n' "$out" | sed 's/^/     /' | head -4
  elif grep -q '^SCAFFOLD-FAILED:' <<<"$out"; then
    pass "$t refuses an empty corpus, through the scaffold channel"
  else
    # Non-zero is better than green, but a bare failure sends the reader hunting
    # for a defect in the rule when the cause is the environment.
    fail "$t refuses an empty corpus but does not name it as one (no SCAFFOLD-FAILED: line)"
    printf '%s\n' "$out" | grep '^FAIL:' | sed 's/^/     /' | head -3
  fi
done

# The control: with a working git the same three must be GREEN. Without it this
# file would pass just as happily against three lints that always refuse.
for t in test-array-key-expansion.sh test-grep-q-pipelines.sh test-bash-floor.sh; do
  [[ -f "$TESTS_DIR/$t" ]] || continue
  if bash "$TESTS_DIR/$t" >/dev/null 2>&1; then
    pass "$t is green on a real corpus — the refusal above is about the corpus, not the rule"
  else
    fail "$t is green on a real corpus"
  fi
done

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
