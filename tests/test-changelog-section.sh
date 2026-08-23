#!/usr/bin/env bash
# tests/test-changelog-section.sh — the release notes come from the CHANGELOG.
#
# `.github/workflows/release.yml` publishes whatever changelog-section.sh prints
# for the pushed tag. Everything that script can get wrong is therefore a wrong
# RELEASE — published, linked from a LinkedIn post, and awkward to correct — so
# each failure mode below is asserted on its own outcome rather than on "it
# exited non-zero". Two of them (missing version, oversized body) are the ones a
# human meets first, and both must say enough to act on without opening the
# script.
#
# The script it replaces was `generate_release_notes: true`, which could not
# fail: it published SOMETHING for any tag, so no assertion here has an
# equivalent in the old arrangement.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/changelog-section.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
SCRIPT="$ENGINE_DIR/changelog-section.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -x "$SCRIPT" ]] || { printf 'SCAFFOLD-FAILED: no executable changelog-section.sh under %s\n' "$ENGINE_DIR"; exit 1; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
[[ -d "$TMP" ]] || { printf 'SCAFFOLD-FAILED: scratch dir %s is not a directory\n' "$TMP"; exit 1; }

# One fixture exercising every shape at once: a normal section, a following
# section that must bound it, a duplicate, an empty one, a fenced block whose
# `## ` is CONTENT, and a last section with no heading after it.
FIX="$TMP/CHANGELOG.md"
cat > "$FIX" <<'EOF'
# Changelog

Preamble that belongs to no section.

## v2.0.0 — 2026-01-02

Body of two-oh.

- a bullet

## v1.9.0

Body of one-nine.

```
## v0.0.0 — this line is INSIDE a fence and is not a heading
```

Still one-nine.

## v1.8.0 — 2026-01-01

## v1.7.0

Duplicated below.

## v1.7.0

Second copy.

## v1.0.0

The last section, with no heading after it.
EOF
[[ -s "$FIX" ]] || { printf 'SCAFFOLD-FAILED: fixture %s was not written\n' "$FIX"; exit 1; }

run() { "$SCRIPT" "$1" "${2:-$FIX}" 2>"$TMP/err"; }

# ── §1 extraction ─────────────────────────────────────────────────────────────
out="$(run v2.0.0)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *'Body of two-oh.'* ]]; then
  pass "§1.1 extracts the named section's body"
else
  fail "§1.1 v2.0.0 body not extracted (rc=$rc): $out"
fi

if [[ "$out" != *'Body of one-nine.'* && "$out" != *'## v1.9.0'* ]]; then
  pass "§1.2 the next \`## \` heading bounds the section"
else
  fail "§1.2 v2.0.0 output bled into the following section"
fi

if [[ "$out" != *'Preamble'* ]]; then
  pass "§1.3 text before the first heading is not included"
else
  fail "§1.3 preamble leaked into the section"
fi

# The last section has no following heading; the loop's terminating condition is
# end-of-file, which is a different code path from "the next heading".
out="$(run v1.0.0)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *'The last section, with no heading after it.'* ]]; then
  pass "§1.4 the FINAL section is extracted (no following heading)"
else
  fail "§1.4 last section not extracted (rc=$rc): $out"
fi

# ── §2 trimming ───────────────────────────────────────────────────────────────
# Asserted against the FILE, never against `$(…)`. Command substitution strips
# trailing newlines, so an `[[ "$out" == *'a bullet' ]]` check passes whether or
# not the script trimmed anything — which is exactly how it read here first, and
# the mutation tier caught it: flipping `(( end > start ))` to `end < start`
# disables the trailing trim entirely and SURVIVED that assertion.
"$SCRIPT" v2.0.0 "$FIX" > "$TMP/out.txt" 2>"$TMP/err" || { fail "§2 v2.0.0 did not run: $(cat "$TMP/err")"; }
if [[ -s "$TMP/out.txt" ]]; then
  first_content="$(grep -n '[^[:space:]]' "$TMP/out.txt" | head -1 | cut -d: -f1)"
  last_content="$(grep -n '[^[:space:]]' "$TMP/out.txt" | tail -1 | cut -d: -f1)"
  n_all="$(wc -l < "$TMP/out.txt")"
  if [[ "$first_content" == "1" ]]; then
    pass "§2.1 the output's FIRST line is content (no leading blank lines)"
  else
    fail "§2.1 first content is on line $first_content, not line 1"
  fi
  if (( n_all == last_content )); then
    pass "§2.2 the output's LAST line is content (no trailing blank lines)"
  else
    fail "§2.2 file has $n_all lines but last content is on line $last_content"
  fi
  # One trailing newline, not zero: a body that does not end in a newline
  # concatenates badly with anything appended after it.
  # `$(…)` strips trailing newlines, so a last byte of \n substitutes to the
  # empty string and any other last byte substitutes to itself. The file is
  # non-empty (guarded above), so empty here means exactly "ends in a newline".
  if [[ -z "$(tail -c 1 "$TMP/out.txt")" ]]; then
    pass "§2.3 the output ends with exactly one newline"
  else
    fail "§2.3 output ends with $(printf '%q' "$(tail -c 1 "$TMP/out.txt")"), not a newline"
  fi
else
  fail "§2 produced no output for v2.0.0"
fi

# ── §3 fenced blocks ──────────────────────────────────────────────────────────
# A `## ` inside a fence is content. If the script treated it as a heading, the
# v1.9.0 section would stop early and "Still one-nine." would be missing —
# asserted on that specific line, so the case cannot pass on a bad reason.
out="$(run v1.9.0)"
if [[ "$out" == *'Still one-nine.'* ]]; then
  pass "§3.1 a \`## \` inside a fenced block does not end the section"
else
  fail "§3.1 fenced \`## \` truncated the section: $out"
fi
if [[ "$out" == *'## v0.0.0 — this line is INSIDE a fence'* ]]; then
  pass "§3.2 the fenced line is emitted as content"
else
  fail "§3.2 the fenced line went missing"
fi

# ── §4 refusals ───────────────────────────────────────────────────────────────
# A version that is a PREFIX of a real one must not match it: the space after
# the version is required. Without this, `v1.9` would publish v1.9.0's notes.
if ! run v1.9 >/dev/null; then
  pass "§4.1 a prefix of a real version does not match it"
else
  fail "§4.1 v1.9 matched the \`## v1.9.0\` heading"
fi

run v9.9.9 >/dev/null; rc=$?
err="$(cat "$TMP/err")"
if (( rc == 1 )) && [[ "$err" == *'no "## v9.9.9" heading'* ]]; then
  pass "§4.2 a missing version fails and names the version"
else
  fail "§4.2 missing version: rc=$rc err=$err"
fi
# The list of what IS there is the whole value of that error — without it the
# reader cannot tell a typo from an unwritten section.
if [[ "$err" == *'## v2.0.0 — 2026-01-02'* && "$err" == *'## v1.0.0'* ]]; then
  pass "§4.3 the missing-version error lists the headings the file does have"
else
  fail "§4.3 error did not list available headings: $err"
fi

run v1.7.0 >/dev/null; rc=$?
err="$(cat "$TMP/err")"
if (( rc == 1 )) && [[ "$err" == *'2 headings match'* ]]; then
  pass "§4.4 a duplicated heading fails rather than concatenating both bodies"
else
  fail "§4.4 duplicate heading: rc=$rc err=$err"
fi

run v1.8.0 >/dev/null; rc=$?
err="$(cat "$TMP/err")"
if (( rc == 1 )) && [[ "$err" == *'is empty'* ]]; then
  pass "§4.5 an empty section fails rather than publishing an empty release"
else
  fail "§4.5 empty section: rc=$rc err=$err"
fi

"$SCRIPT" v1.0.0 "$TMP/does-not-exist.md" >/dev/null 2>"$TMP/err"; rc=$?
err="$(cat "$TMP/err")"
if (( rc == 1 )) && [[ "$err" == *'cannot read changelog'* ]]; then
  pass "§4.6 an unreadable changelog fails and says so"
else
  fail "§4.6 unreadable changelog: rc=$rc err=$err"
fi

"$SCRIPT" >/dev/null 2>"$TMP/err"; rc=$?
if (( rc == 2 )); then
  pass "§4.7 no arguments is a usage error (exit 2), distinct from a data error"
else
  fail "§4.7 no args gave rc=$rc, expected 2"
fi
"$SCRIPT" a b c >/dev/null 2>"$TMP/err"; rc=$?
if (( rc == 2 )); then
  pass "§4.8 too many arguments is a usage error (exit 2)"
else
  fail "§4.8 three args gave rc=$rc, expected 2"
fi

# ── §5 the release-body ceiling ───────────────────────────────────────────────
# GitHub rejects a body over 125,000 characters. The v0.6.0 section is already
# 74% of that, so this is the next release's problem, not a hypothetical one.
# Generated by ONE awk, not a shell loop. The first version of this fixture ran
# 1300 `seq` subshells and took most of a second; under the mutation tier that
# scaffold cost dominated every one of this target's 49 mutant runs.
mkbig() {  # <path> <n-lines>
  awk -v n="$2" 'BEGIN { s = sprintf("%99s", ""); gsub(/ /, "x", s)
                         printf "## v3.0.0\n\n"
                         for (i = 0; i < n; i++) print s }' > "$1"
}

BIG="$TMP/big.md"
mkbig "$BIG" 1300
big_bytes="$(wc -c < "$BIG")"
(( big_bytes > 125000 )) || { printf 'SCAFFOLD-FAILED: oversized fixture is only %s bytes\n' "$big_bytes"; exit 1; }
"$SCRIPT" v3.0.0 "$BIG" >/dev/null 2>"$TMP/err"; rc=$?
err="$(cat "$TMP/err")"
if (( rc == 1 )) && [[ "$err" == *'release-body limit is 125000'* ]]; then
  pass "§5.1 an oversized section is refused, naming the limit"
else
  fail "§5.1 oversized section: rc=$rc err=$err"
fi
if [[ "$err" == *'characters;'* ]]; then
  pass "§5.2 the refusal names the actual size, not only the limit"
else
  fail "§5.2 refusal did not state the actual size: $err"
fi

# The warning threshold sits between BODY_WARN and BODY_MAX. Without a case here
# it is a branch nothing observes — the mutation tier scored exactly that,
# surviving both a negation and a comparison flip of the `> BODY_WARN` test.
WARNY="$TMP/warn.md"
mkbig "$WARNY" 1100          # ~110,000 chars: over BODY_WARN, under BODY_MAX
warn_bytes="$(wc -c < "$WARNY")"
if (( warn_bytes > 100000 && warn_bytes < 125000 )); then
  pass "§5.3 the warning fixture lands between the two thresholds ($warn_bytes bytes)"
else
  printf 'SCAFFOLD-FAILED: warn fixture is %s bytes, not between 100000 and 125000\n' "$warn_bytes"; exit 1
fi
out="$("$SCRIPT" v3.0.0 "$WARNY" 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"
if (( rc == 0 )) && [[ -n "$out" ]]; then
  pass "§5.4 a section under the limit still publishes"
else
  fail "§5.4 near-limit section did not publish (rc=$rc): $err"
fi
if [[ "$err" == *'warning:'* && "$err" == *'% of the 125000 limit'* ]]; then
  pass "§5.5 approaching the limit warns, naming the percentage"
else
  fail "§5.5 no threshold warning for a $warn_bytes-character section: $err"
fi
# A small section must NOT warn, or the warning means nothing.
"$SCRIPT" v2.0.0 "$FIX" >/dev/null 2>"$TMP/err"
if [[ -z "$(cat "$TMP/err")" ]]; then
  pass "§5.6 a small section warns about nothing"
else
  fail "§5.6 small section produced stderr: $(cat "$TMP/err")"
fi

# ── §6 the real CHANGELOG ─────────────────────────────────────────────────────
# The fixture proves the logic; this proves it against the file the workflow
# will actually read. A released tag must resolve, or the workflow that publishes
# it is broken for the version it was written for.
REAL="$ENGINE_DIR/CHANGELOG.md"
if [[ -r "$REAL" ]]; then
  out="$("$SCRIPT" v0.6.0 "$REAL" 2>"$TMP/err")"; rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    pass "§6.1 v0.6.0 resolves against the real CHANGELOG"
  else
    fail "§6.1 v0.6.0 did not resolve (rc=$rc): $(cat "$TMP/err")"
  fi
  if [[ "$out" != *'## v0.4.1'* ]]; then
    pass "§6.2 the real v0.6.0 section stops before v0.4.1"
  else
    fail "§6.2 the real section ran past its boundary"
  fi
else
  printf 'SCAFFOLD-FAILED: no readable CHANGELOG.md under %s\n' "$ENGINE_DIR"; exit 1
fi

printf '\n%s failure(s)\n' "$fails"
(( fails == 0 ))
