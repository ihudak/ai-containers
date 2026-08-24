#!/usr/bin/env bash
# tests/test-release-title.sh — release-title.sh against real tags.
#
# The property worth guarding is the DISCRIMINATION, not the happy path: a
# lightweight tag and an annotated tag whose object was never fetched both yield
# an empty `%(contents:subject)`, and treating them alike would let a shallow
# checkout publish a bare title that looks exactly like a deliberate one. So the
# lightweight case must FALL BACK and the absent case must FAIL, and both are
# asserted here against tags this file creates.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/release-title.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
SCRIPT="$ENGINE_DIR/release-title.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$SCRIPT" ]] || { printf 'SCAFFOLD-FAILED: no release-title.sh under %s\n' "$ENGINE_DIR"; exit 1; }
bash -n "$SCRIPT" && pass "release-title.sh bash -n" || fail "release-title.sh bash -n"

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

R="$TMP/repo"
git init -q --initial-branch=main "$R" >/dev/null 2>&1 || { printf 'SCAFFOLD-FAILED: git init\n'; exit 1; }
printf 'x\n' > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm init

run() { OUT="$(cd "$R" && bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
OUT=""; RC=0

# ── 1. an annotated tag supplies the title ───────────────────────────────────
git -C "$R" tag -a v1.0.0 -m "v1.0.0 — a real repo reset, two host helper scripts" >/dev/null 2>&1
run v1.0.0
if [[ "$RC" -eq 0 && "$OUT" == "v1.0.0 — a real repo reset, two host helper scripts" ]]; then
  pass "an annotated tag's message becomes the title"
else
  fail "an annotated tag's message becomes the title (rc=$RC, got '$OUT')"
fi

# ── 2. only the first line ───────────────────────────────────────────────────
# `git tag -m a -m b` produces a subject and a body; a release title is one line.
git -C "$R" tag -a v1.1.0 -m "v1.1.0 — the subject" -m "a body paragraph that must not appear" >/dev/null 2>&1
run v1.1.0
if [[ "$OUT" == "v1.1.0 — the subject" ]]; then
  pass "a multi-line tag message contributes only its subject"
else
  fail "a multi-line tag message contributes only its subject (got '$OUT')"
fi

# ── 3. a LIGHTWEIGHT tag falls back, and does not fail ───────────────────────
git -C "$R" tag v1.2.0 >/dev/null 2>&1
run v1.2.0
if [[ "$RC" -eq 0 && "$OUT" == "v1.2.0" ]]; then
  pass "a lightweight tag falls back to the tag name, without failing"
else
  fail "a lightweight tag falls back to the tag name (rc=$RC, got '$OUT')"
fi

# ── 4. an annotated tag with an EMPTY message falls back too ─────────────────
git -C "$R" tag -a v1.3.0 -m "" >/dev/null 2>&1
run v1.3.0
if [[ "$RC" -eq 0 && "$OUT" == "v1.3.0" ]]; then
  pass "an annotated tag with an empty message falls back rather than publishing a blank title"
else
  fail "an annotated tag with an empty message falls back (rc=$RC, got '$OUT')"
fi

# ── 5. whitespace is trimmed ─────────────────────────────────────────────────
git -C "$R" tag -a v1.4.0 -m "   v1.4.0 — padded   " >/dev/null 2>&1
run v1.4.0
if [[ "$OUT" == "v1.4.0 — padded" ]]; then
  pass "surrounding whitespace is trimmed"
else
  fail "surrounding whitespace is trimmed (got '$OUT')"
fi

# ── 6. THE DISCRIMINATION: absent is an ERROR, not a fallback ────────────────
# This is the whole point. A shallow fetch that omitted tag objects yields the
# same empty subject as a lightweight tag; if both fell back, the release would
# publish a bare title that looks deliberate and nobody would learn the fetch
# was wrong.
run v9.9.9
if [[ "$RC" -ne 0 ]] && grep -q 'no such tag: v9.9.9' <<<"$OUT"; then
  pass "an absent tag FAILS loudly instead of falling back"
else
  fail "an absent tag fails loudly instead of falling back (rc=$RC, got '$OUT')"
fi
if grep -qi 'shallow' <<<"$OUT"; then
  pass "…and the message names the shallow-fetch case, which is what it usually is"
else
  fail "…and the message names the shallow-fetch case
$OUT"
fi

# ── 7. refusals ──────────────────────────────────────────────────────────────
run
if [[ "$RC" -ne 0 ]] && grep -q 'usage' <<<"$OUT"; then
  pass "no argument is refused with a usage line"
else
  fail "no argument is refused with a usage line (rc=$RC)"
fi

OUT="$(cd "$TMP" && bash "$SCRIPT" v1.0.0 2>&1)"; RC=$?
if [[ "$RC" -ne 0 ]] && grep -q 'not a git repository' <<<"$OUT"; then
  pass "running outside a git repository is refused by name"
else
  fail "running outside a git repository is refused by name (rc=$RC, got '$OUT')"
fi

# ── 8. the real repository's own tags, if it has any ─────────────────────────
# Not a fixture: the convention this script assumes — that release tags are
# annotated with a descriptive subject — is either true of this repo's history
# or the script is built on sand.
last_tag="$(git -C "$REPO_DIR" tag --sort=-v:refname 2>/dev/null | head -1)"
if [[ -n "$last_tag" ]]; then
  t="$(cd "$REPO_DIR" && bash "$SCRIPT" "$last_tag" 2>&1)"
  if [[ "$t" != "$last_tag" ]]; then
    pass "this repo's most recent tag ($last_tag) carries a descriptive message"
  else
    fail "this repo's most recent tag ($last_tag) has no message — the convention this script rests on is not being followed"
  fi
else
  pass "no tags in this repository yet — nothing to check the convention against"
fi

printf '\n%s\n' "----------------------------------------"
if [[ "$fails" -eq 0 ]]; then
  printf 'test-release-title.sh: all checks passed\n'; exit 0
fi
printf 'test-release-title.sh: %s check(s) failed\n' "$fails"
exit 1
