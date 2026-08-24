#!/usr/bin/env bash
# tests/test-symlinked-tmp-guard.sh — the premise the symlinked-TMPDIR check
# rests on, asserted rather than assumed.
#
# WHY THIS EXISTS. CI is ubuntu-only, where the temp directory is not a symlink.
# macOS's is: /var is a symlink to /private/var, so `mktemp -d` hands back
# /var/folders/… while anything canonicalising reports /private/var/folders/….
# A test that compares one against the other therefore passes in CI and in the
# floor container and fails on every Mac. That class has now cost this repo
# twice: 19 assertions in increment 4, and three more on 2026-08-24
# (test-report.sh, test-docs-path.sh, and the docs orphan gate).
#
# The `suite-symlinked-tmp` job exists to catch it on Linux by pointing TMPDIR
# at a symlink — a stand-in for a Mac. This file guards the stand-in itself.
# Without it, someone could drop the TMPDIR export, or point it at an ordinary
# directory, and the job would go on passing while checking nothing: a green
# gate that has stopped gating, which is the failure mode this suite is built
# to refuse.
#
# It does that by DEMONSTRATION, not description: a deliberately path-naive
# fixture must FAIL under a symlinked TMPDIR and PASS under an ordinary one,
# and a p_realdir-correct fixture must pass under both. The first half proves
# the mechanism detects the bug; the second proves the symlink is the thing
# doing the detecting, not some accident of the fixture.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=portability.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# FULLY RESOLVED, and that is not tidiness: the "ordinary" arm below has to be a
# directory reached by a path containing no symlink at all. On macOS the raw
# mktemp -d output is itself under a symlinked /var, so building the ordinary
# arm on it would make that arm symlinked too — and this file would then report
# that a symlink changes nothing, on the one platform where it changes
# everything.
TMP="$(p_realdir "$TMP")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/plain" "$TMP/real" || { printf 'SCAFFOLD-FAILED: mkdir\n'; exit 1; }
ln -s "$TMP/real" "$TMP/link"     || { printf 'SCAFFOLD-FAILED: ln -s\n'; exit 1; }

# The scaffold's own premise, checked before anything is concluded from it: the
# two arms must actually differ in the property under test.
if [[ "$(p_realdir "$TMP/plain")" == "$TMP/plain" ]]; then
  pass "scaffold: the ordinary arm resolves to itself"
else
  printf 'SCAFFOLD-FAILED: %s resolves to %s — the ordinary arm is not symlink-free\n' \
    "$TMP/plain" "$(p_realdir "$TMP/plain")"
  exit 1
fi
if [[ "$(p_realdir "$TMP/link")" == "$TMP/real" ]]; then
  pass "scaffold: the symlinked arm resolves elsewhere"
else
  printf 'SCAFFOLD-FAILED: %s resolves to %s, expected %s\n' \
    "$TMP/link" "$(p_realdir "$TMP/link")" "$TMP/real"
  exit 1
fi

# ── the two fixtures ─────────────────────────────────────────────────────────
# NAIVE: the exact shape of every bug this check is for — a path from mktemp
# compared against the same path after something canonicalised it.
cat > "$TMP/naive.sh" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
d="$(mktemp -d)" || exit 2
resolved="$(cd "$d" && pwd -P)"
[[ "$d" == "$resolved" ]] || exit 1
exit 0
FIX
# CORRECT: the same comparison, resolved on both sides.
cat > "$TMP/correct.sh" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
d="$(mktemp -d)" || exit 2
d="$( cd "$d" && pwd -P )"
resolved="$(cd "$d" && pwd -P)"
[[ "$d" == "$resolved" ]] || exit 1
exit 0
FIX
chmod +x "$TMP/naive.sh" "$TMP/correct.sh"

run_under() {  # $1 = TMPDIR to use, $2 = fixture → echoes its exit code
  TMPDIR="$1" bash "$2" >/dev/null 2>&1
  printf '%s' "$?"
}

# ── 1. the symlinked arm detects the bug ─────────────────────────────────────
rc="$(run_under "$TMP/link" "$TMP/naive.sh")"
if [[ "$rc" == "1" ]]; then
  pass "a path-naive comparison FAILS under a symlinked TMPDIR"
else
  fail "a path-naive comparison fails under a symlinked TMPDIR (got rc=$rc, wanted 1)"
fi

# ── 2. …and the symlink is what does the detecting ───────────────────────────
# The load-bearing half. If this passes for the wrong reason — because the
# fixture is broken outright rather than because of the symlink — then the
# check above proves nothing about TMPDIR at all.
rc="$(run_under "$TMP/plain" "$TMP/naive.sh")"
if [[ "$rc" == "0" ]]; then
  pass "…and PASSES under an ordinary one, so the symlink is what detects it"
else
  fail "the same fixture passes under an ordinary TMPDIR (got rc=$rc, wanted 0) —
     the fixture is failing for some reason other than the symlink, so the
     symlinked check would be proving nothing"
fi

# ── 3. the corrected shape survives both ─────────────────────────────────────
rc_link="$(run_under "$TMP/link" "$TMP/correct.sh")"
rc_plain="$(run_under "$TMP/plain" "$TMP/correct.sh")"
if [[ "$rc_link" == "0" && "$rc_plain" == "0" ]]; then
  pass "a p_realdir-correct comparison passes under both"
else
  fail "a p_realdir-correct comparison passes under both (symlinked=$rc_link ordinary=$rc_plain)"
fi

# ── 4. the real suite is actually runnable this way ──────────────────────────
# Cheap end-to-end: one real test file, under the symlinked arm. Not the whole
# suite — that is the CI job's business — but enough that a TMPDIR the runner
# cannot even write into would be caught here rather than in CI.
if TMPDIR="$TMP/link" bash "$REPO_DIR/tests/test-portability.sh" >/dev/null 2>&1; then
  pass "a real test file runs under the symlinked TMPDIR"
else
  fail "a real test file runs under the symlinked TMPDIR — the arm is not usable"
fi

printf '\n%s\n' "----------------------------------------"
if [[ "$fails" -eq 0 ]]; then
  printf 'test-symlinked-tmp-guard.sh: all checks passed\n'; exit 0
fi
printf 'test-symlinked-tmp-guard.sh: %s check(s) failed\n' "$fails"
exit 1
