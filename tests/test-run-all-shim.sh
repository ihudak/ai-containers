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
# PROBED BY EFFECT, NOT BY EXIT STATUS, and the difference is the whole gate.
# `/usr/bin/mktemp --tmpdir -u` EXITS 0 ON BSD -- it treats `--` as the
# end-of-options marker, shrugs, and prints an ordinary path -- so an rc-only
# probe concludes "GNU long options supported" on a stock macOS and then runs
# four assertions the platform cannot express. Measured 2026-08-29: both
# `--suffix` cases failed with `mktemp: unrecognized option` in Phase 5 on a Mac
# while the whole file passed on Linux, which is this repo's most-repeated
# defect shape wearing a capability probe.
#
# So: require --tmpdir=DIR to actually PUT THE PATH IN DIR, and --suffix to be
# accepted at all. BSD satisfies neither, GNU satisfies both, and nothing in
# between is silently read as a yes.
# RESOLVED, not hardcoded. `/usr/bin/mktemp` is not where every host keeps it
# (NixOS, a stripped image, a Homebrew coreutils ahead of /usr/bin on a Mac),
# and on a host that has only /bin/mktemp this probe produced an empty $_probe,
# the `"" == /*` test was false, and four assertions below SKIPPED citing "this
# is not GNU mktemp" — the wrong reason, for a host that may well have had it.
# ── run-all.sh MUST NOT RESOLVE ITS "real" mktemp TO ANOTHER SHIM ────────────
# run-all.sh NESTS: a falsify oracle is `run-all.sh <name>`, and fixtures inside
# it run run-all.sh again. So the inner one resolves its system mktemp with an
# OUTER shim already first on PATH — and `command -v mktemp` hands back that
# shim. The inner shim then execs the outer, the outer execs what it was told is
# real, and they exec each other forever.
#
# Not hypothetical: introducing exactly this ran the suite 20 minutes into
# test-falsify-run.sh without finishing and made test-falsify-historical.sh
# report an oracle HUNG for 180s without asserting. Neither symptom named a
# cause, which is why the resolution is asserted here rather than trusted.
nest_dir="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d (nest probe)\n'; exit 1; }
mkdir -p "$nest_dir/run-all-tmp.PROBE/bin"
printf '#!/bin/sh\necho SHIM\n' > "$nest_dir/run-all-tmp.PROBE/bin/mktemp"
chmod +x "$nest_dir/run-all-tmp.PROBE/bin/mktemp"
# The premise: a bare `command -v` really would pick the shim here.
nest_naive="$(PATH="$nest_dir/run-all-tmp.PROBE/bin:$PATH" command -v mktemp)"
if [[ "$nest_naive" == *"/run-all-tmp.PROBE/bin/mktemp" ]]; then
  pass "scaffold: with a shim first on PATH, a bare resolution picks the shim"
else
  fail "scaffold: with a shim first on PATH, a bare resolution picks the shim — got '$nest_naive', so the assertion below proves nothing"
fi
nest_got="$(PATH="$nest_dir/run-all-tmp.PROBE/bin:$PATH" bash -c '
  RA_RESOLVE_PATH="$(printf "%s" "$PATH" | tr ":" "\n" | grep -v "/run-all-tmp\.[^/]*/bin$" | paste -sd: -)"
  PATH="$RA_RESOLVE_PATH" command -v mktemp')"
if [[ -n "$nest_got" && "$nest_got" != *"/run-all-tmp."* ]]; then
  pass "run-all.sh's resolution skips shim directories, so nesting cannot loop"
else
  fail "run-all.sh's resolution skips shim directories — got '$nest_got', which is a shim: nested run-all.sh would exec in a loop"
fi
# The rule the resolution depends on must match what run-all.sh actually writes.
grep -qF 'run-all-tmp\.[^/]*/bin$' "$REPO_DIR/tests/run-all.sh" \
  && pass "  … and run-all.sh uses that same exclusion" \
  || fail "  … and run-all.sh uses that same exclusion — the two have drifted"
rm -rf "$nest_dir"

_REAL_MKTEMP="$(command -v mktemp 2>/dev/null || true)"
if [[ -z "$_REAL_MKTEMP" ]]; then
  printf 'SCAFFOLD-FAILED: no mktemp on PATH — the GNU/BSD probe below cannot run\n'
  exit 1
fi
_probe="$("$_REAL_MKTEMP" -d)"
if [[ "$("$_REAL_MKTEMP" --tmpdir="$_probe" -u 2>/dev/null)" == "$_probe"/* ]] \
   && "$_REAL_MKTEMP" --suffix=.probe -u >/dev/null 2>&1; then
  rmdir "$_probe" 2>/dev/null || true
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

  # --suffix's VALUE is a separate argument and is not a template, so it matches
  # the OPERAND arm and the shim passes everything through.
  #
  # WHAT THAT GUARDS IS NOT WHAT THIS COMMENT FIRST SAID. It claimed the
  # pass-through "silently dropped the steering". Measured: it does not. GNU
  # mktemp implies --tmpdir when given no template, so `TMPDIR=$D mktemp
  # --suffix .txt` lands in $D whether the shim intervenes or not — the
  # assertion cannot fail for the reason stated. What it DOES pin is that an
  # operand-looking argument makes the shim pass through rather than APPEND its
  # own template: appending one here would hand mktemp two operands and the call
  # would error, which is a failure this assertion catches.
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
  rmdir "$_probe" 2>/dev/null || true
  printf 'SKIP: the GNU long-option assertions — this mktemp honours neither --tmpdir nor --suffix (BSD)\n'
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
