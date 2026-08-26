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
# $1, when given, is the directory to create in — the EXPLICIT form, which every
# mktemp honours. With no argument the bare form is used, which is what the real
# suite does and what TMPDIR is supposed to steer. Both forms exist because the
# lever is not universal; see the probe below.
cat > "$TMP/naive.sh" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
if [[ -n "${1:-}" ]]; then d="$(mktemp -d "$1/fixture.XXXXXX")" || exit 2
else                       d="$(mktemp -d)"                     || exit 2
fi
resolved="$(cd "$d" && pwd -P)"
[[ "$d" == "$resolved" ]] || exit 1
exit 0
FIX
# CORRECT: the same comparison, resolved on both sides.
cat > "$TMP/correct.sh" <<'FIX'
#!/usr/bin/env bash
set -uo pipefail
if [[ -n "${1:-}" ]]; then d="$(mktemp -d "$1/fixture.XXXXXX")" || exit 2
else                       d="$(mktemp -d)"                     || exit 2
fi
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
run_in_dir() { # $1 = directory to create in, $2 = fixture → echoes its exit code
  bash "$2" "$1" >/dev/null 2>&1
  printf '%s' "$?"
}

# ── THE LEVER, PROBED RATHER THAN ASSUMED ────────────────────────────────────
# Assertions 1 and 2 rest on TMPDIR steering `mktemp -d`. That is GNU coreutils
# behaviour and NOT universal: macOS's mktemp, given no template, ignores TMPDIR
# and uses the per-user directory from confstr(_CS_DARWIN_USER_TEMP_DIR) —
# /var/folders/…, itself behind the /var -> /private/var symlink. Measured on
# Darwin arm64, 2026-08-26:
#
#   TMPDIR=/Users/x/tmp-plain mktemp -d
#   -> /var/folders/w9/_yghn6w95_jcb_lrdjg06vj40000gp/T/tmp.UuY97xwbZb
#
# Where the lever is absent, those two assertions cannot mean what they say: the
# naive fixture then fails under BOTH arms, because every path it is handed is
# symlinked whatever TMPDIR says. Assertion 1 passes for the wrong reason and
# assertion 2 — the control that exists to catch exactly that — fails. THE GUARD
# IS RIGHT TO REFUSE; what it must not do is report a platform without the lever
# as though the mechanism were broken. That is how this file failed on every Mac
# while passing in CI, the very shape it was written to prevent.
#
# So the lever is measured, and where it is missing the SAME PROPERTY is
# demonstrated through the explicit form instead — the symlink still has to be
# what makes the naive comparison fail. What is lost is only the claim that
# TMPDIR is the lever, which is stated as a note rather than quietly skipped.
# Probed, not sniffed with `uname`: the question is what mktemp does here, and a
# platform test would be a proxy for it that can drift.
lever=0
_probe="$(TMPDIR="$TMP/plain" mktemp -d 2>/dev/null || true)"
case "$_probe" in "$TMP/plain"/*) lever=1 ;; esac
[[ -n "$_probe" ]] && rm -rf "$_probe"
if (( lever )); then
  pass "scaffold: TMPDIR steers mktemp -d here, so the TMPDIR lever is testable"
else
  printf 'NOTE: mktemp -d ignores TMPDIR on this platform (macOS does), so the\n'
  printf '      TMPDIR LEVER itself is not exercised below. The same property is\n'
  printf '      demonstrated through an explicit template, which every mktemp\n'
  printf '      honours. The lever is covered on Linux, by CI and by the floor\n'
  printf '      container, which is where the suite-symlinked-tmp job runs.\n'
fi

# arm <dir> <fixture> — drive a fixture at <dir> through whichever mechanism
# this platform actually has.
arm() {
  if (( lever )); then run_under "$1" "$2"; else run_in_dir "$1" "$2"; fi
}

# ── 1. the symlinked arm detects the bug ─────────────────────────────────────
rc="$(arm "$TMP/link" "$TMP/naive.sh")"
if [[ "$rc" == "1" ]]; then
  pass "a path-naive comparison FAILS under a symlinked TMPDIR"
else
  fail "a path-naive comparison fails under a symlinked TMPDIR (got rc=$rc, wanted 1)"
fi

# ── 2. …and the symlink is what does the detecting ───────────────────────────
# The load-bearing half. If this passes for the wrong reason — because the
# fixture is broken outright rather than because of the symlink — then the
# check above proves nothing about TMPDIR at all.
rc="$(arm "$TMP/plain" "$TMP/naive.sh")"
if [[ "$rc" == "0" ]]; then
  pass "…and PASSES under an ordinary one, so the symlink is what detects it"
else
  fail "the same fixture passes under an ordinary TMPDIR (got rc=$rc, wanted 0) —
     the fixture is failing for some reason other than the symlink, so the
     symlinked check would be proving nothing"
fi

# ── 3. the corrected shape survives both ─────────────────────────────────────
rc_link="$(arm "$TMP/link" "$TMP/correct.sh")"
rc_plain="$(arm "$TMP/plain" "$TMP/correct.sh")"
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
