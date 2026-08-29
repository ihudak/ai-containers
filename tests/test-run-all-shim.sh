#!/usr/bin/env bash
# tests/test-run-all-shim.sh — a guard for the `mktemp` shim run-all.sh injects.
#
# run-all.sh generates a `mktemp` wrapper into a scratch bin/ and puts it on
# PATH for EVERY test in the suite, so that a test which calls bare `mktemp`
# lands under the per-test TMPDIR the runner steers rather than in the real
# /tmp. That shim is therefore the single most widely-executed piece of new code
# in the suite — and it had no assertion of any kind. run-all.sh cannot be
# covered by the falsify tier either (tests/falsify/targets.conf excludes it as
# the measuring instrument), so nothing anywhere observed the shim behaving.
#
# A regression in it would not read as "the shim is broken": it would surface as
# a wall of unrelated test failures, or — worse — as tests quietly writing to the
# real /tmp again, which is the exact leak the shim exists to stop and which is
# invisible in a green run.
#
# METHOD: extract the shim from run-all.sh's heredoc and run it directly. Not a
# copy of it — a copy would drift, and this file would then be asserting on code
# that no longer ships. Extracting means a change to the heredoc is a change to
# what is tested here, with no second edit.
#
# This deliberately does NOT invoke run-all.sh. This file is itself collected by
# run-all.sh's `test-*.sh` glob, so calling it would recurse.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ALL="$REPO_DIR/tests/run-all.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$RUN_ALL" ]] || { printf 'SCAFFOLD-FAILED: no run-all.sh at %s\n' "$RUN_ALL"; exit 1; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── extract the shim, and prove the extraction found something ────────────────
# An empty extraction would make every assertion below vacuous, so the marker
# and the body are both checked before anything runs.
SHIM="$TMP/bin/mktemp"
mkdir -p "$TMP/bin"
sed -n "/^cat > \"\$RA_TMPROOT\/bin\/mktemp\" <<'RA_MKTEMP_SHIM'\$/,/^RA_MKTEMP_SHIM\$/p" "$RUN_ALL" \
  | sed '1d;$d' > "$SHIM"
if [[ -s "$SHIM" ]] && grep -q '_ra_real' "$SHIM"; then
  pass "the mktemp shim was extracted from run-all.sh"
else
  printf 'SCAFFOLD-FAILED: could not extract the shim heredoc from run-all.sh\n'
  exit 1
fi
chmod +x "$SHIM"

STEER="$TMP/steer"; mkdir -p "$STEER"
ELSEWHERE="$TMP/elsewhere"; mkdir -p "$ELSEWHERE"

# The shim resolves the real mktemp by absolute path, never `command -v` (it is
# itself on PATH), so it is safe to call directly without PATH games.
shim() { TMPDIR="$STEER" "$SHIM" "$@"; }

# ── 1. the shim's whole purpose: an un-templated call is steered to TMPDIR ────
out="$(shim -d 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "$STEER"/* && -d "$out" ]]; then
  pass "mktemp -d with no template is steered into TMPDIR"
else
  fail "mktemp -d with no template is steered into TMPDIR (rc=$rc, got: $out)"
fi

out="$(shim 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "$STEER"/* && -f "$out" ]]; then
  pass "a bare mktemp is steered into TMPDIR"
else
  fail "a bare mktemp is steered into TMPDIR (rc=$rc, got: $out)"
fi

# ── 2. a caller that said where it wanted the file is left alone ──────────────
out="$(shim "$ELSEWHERE/explicit.XXXXXX" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "$ELSEWHERE"/* ]]; then
  pass "an explicit template is passed through untouched"
else
  fail "an explicit template is passed through untouched (rc=$rc, got: $out)"
fi

out="$(shim -p "$ELSEWHERE" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "$ELSEWHERE"/* ]]; then
  pass "-p DIR is passed through untouched"
else
  fail "-p DIR is passed through untouched (rc=$rc, got: $out)"
fi

# ── 3. GNU long options ───────────────────────────────────────────────────────
# --tmpdir/--suffix are GNU-only; BSD mktemp (a stock macOS) has neither, so the
# assertions are gated on the real mktemp actually supporting them rather than
# failing a correct shim on a platform that cannot express the input.
if /usr/bin/mktemp --tmpdir -u >/dev/null 2>&1; then
  # --tmpdir says "put it in TMPDIR", which is what the shim wants anyway — but
  # GNU REFUSES an absolute template alongside it ("with --tmpdir, it may not be
  # absolute"), so appending one turns a working call into an error. It has to
  # be recognised as the caller having named a directory.
  out="$(shim --tmpdir 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 && "$out" == "$STEER"/* ]]; then
    pass "--tmpdir is honoured rather than turned into an invalid-template error"
  else
    fail "--tmpdir is honoured rather than turned into an invalid-template error (rc=$rc, got: $out)"
  fi

  out="$(shim --tmpdir="$ELSEWHERE" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 && "$out" == "$ELSEWHERE"/* ]]; then
    pass "--tmpdir=DIR is passed through untouched"
  else
    fail "--tmpdir=DIR is passed through untouched (rc=$rc, got: $out)"
  fi

  # --suffix's VALUE is a separate argument, and it is not a template. Matched
  # by the operand arm it made the shim pass everything through, silently
  # dropping the steering this whole mechanism exists for.
  out="$(shim --suffix .txt 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 && "$out" == "$STEER"/*.txt ]]; then
    pass "--suffix VALUE keeps its suffix AND stays steered into TMPDIR"
  else
    fail "--suffix VALUE keeps its suffix AND stays steered into TMPDIR (rc=$rc, got: $out)"
  fi

  out="$(shim --suffix=.log 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 && "$out" == "$STEER"/*.log ]]; then
    pass "--suffix=VALUE keeps its suffix and stays steered"
  else
    fail "--suffix=VALUE keeps its suffix and stays steered (rc=$rc, got: $out)"
  fi
else
  printf 'SKIP: the GNU long-option assertions — this mktemp has no --tmpdir (BSD)\n'
fi

# ── 4. a TMPDIR with a trailing slash must not yield a doubled separator ──────
# macOS exports TMPDIR with one, and "$TMPDIR/x" then gives `//x`, a path that
# compares unequal to its own canonical form.
out="$(TMPDIR="$STEER/" "$SHIM" -d 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" != *"//"* ]]; then
  pass "a trailing slash on TMPDIR does not produce a doubled separator"
else
  fail "a trailing slash on TMPDIR does not produce a doubled separator (rc=$rc, got: $out)"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
