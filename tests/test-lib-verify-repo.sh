#!/usr/bin/env bash
# tests/test-lib-verify-repo.sh — the first test of tests/lib-verify-repo.sh
# itself.
#
# That library has four unrecoverable conditions, and until this file none of
# them had ever been seen failing — four unfalsified guards inside the one file
# whose entire subject is guards that cannot fail.
#
# Every case here asserts by EFFECT: it writes a small harness script, runs it,
# and reads the harness's exit code and stdout. Specifically it asserts that a
# sentinel line placed AFTER the `source` never printed. Inspecting the
# library's source text would prove only that an `exit` is written somewhere in
# it, not that execution actually stopped — and "the string is present" is the
# exact false negative this repo's suite exists to close.
#
# The two positive controls are load-bearing, not padding: without them a
# library hard-wired to exit 1 unconditionally would satisfy every negative
# case in this file.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like the rest of the suite: upstream keeps the engine beside
# tests/, mgd-ai-containers keeps it in base/. One copy of this file serves both.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/verify-on-host.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
REAL_CONF="$REPO_DIR/tests/layer-checks.conf"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$VERIFY" "$REAL_CONF" "$REPO_DIR/tests/lib-verify-repo.sh" \
         "$REPO_DIR/tests/lib-layer-checks.sh"; do
  [[ -f "$f" ]] || { fail "missing prerequisite: $f"; exit 1; }
done

hn=0
# Write a harness that sources the two libraries and then prints sentinels.
# $1 = LAYER_CHECKS_CONF to use
# $2 = "skip-lc" to deliberately NOT source lib-layer-checks.sh
# $3 = "no-tmp"  to deliberately leave TMP unset
# $4 = extra body appended after the source (may be empty)
mk_harness() {
  hn=$((hn + 1))
  local h="$TMP/harness-$hn.sh"
  cat > "$h" <<EOF
#!/usr/bin/env bash
set -uo pipefail
VERIFY=$(printf '%q' "$VERIFY")
ENGINE_DIR=$(printf '%q' "$ENGINE_DIR")
LAYER_CHECKS_CONF=$(printf '%q' "$1")
EOF
  # The library's contract check reads TMP; the "no-tmp" mode leaves it unset.
  # Quoted heredoc: $TMP here belongs to the harness at run time, not to us.
  [[ "$3" == "no-tmp" ]] || cat >> "$h" <<'EOF'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EOF
  [[ "$2" == "skip-lc" ]] || printf 'source %q\n' "$REPO_DIR/tests/lib-layer-checks.sh" >> "$h"
  printf 'source %q\n' "$REPO_DIR/tests/lib-verify-repo.sh" >> "$h"
  printf 'echo SENTINEL-SOURCED\n' >> "$h"
  printf '%s\n' "$4" >> "$h"
  chmod +x "$h"
  printf '%s' "$h"
}

# Run a harness. Prints its exit code; output lands in $TMP/harness.out.
# $2, when non-empty, is prepended to PATH (used to plant a broken `git`).
run_harness() {
  local extra_path="${2:-}"
  PATH="${extra_path:+$extra_path:}$PATH" bash "$1" > "$TMP/harness.out" 2>&1
  printf '%s' "$?"
}

# $1=label $2=harness rc. Asserts the harness stopped at the source line: a
# non-zero exit AND no SENTINEL-SOURCED. The sentinel is the discriminating
# half — a library that returned instead of exiting would let the sourcing
# script run on and print it while some later, unrelated step still made the
# harness exit non-zero.
expect_aborted() {
  local ok=1
  [[ "$2" != "0" ]] || { ok=0; fail "$1 — harness exited 0"; }
  if grep -q '^SENTINEL-SOURCED$' "$TMP/harness.out"; then
    ok=0
    fail "$1 — execution continued past the source (SENTINEL-SOURCED printed)"
  fi
  (( ok )) && pass "$1"
  (( ok )) || sed 's/^/       /' "$TMP/harness.out" | tail -8
}

# ── Positive control: a good registry sources cleanly ─────────────────────────
# Without this, every negative case below would also pass against a library
# that aborted unconditionally.
h="$(mk_harness "$REAL_CONF" "" "" "")"
rc="$(run_harness "$h")"
if [[ "$rc" == "0" ]] && grep -q '^SENTINEL-SOURCED$' "$TMP/harness.out"; then
  pass "control: the real registry sources cleanly and continues"
else
  fail "control: the real registry sources cleanly and continues — rc=$rc"
  sed 's/^/       /' "$TMP/harness.out" | tail -8
fi

# ── TMP/VERIFY/ENGINE_DIR unset ───────────────────────────────────────────────
h="$(mk_harness "$REAL_CONF" "" "no-tmp" "")"
expect_aborted "contract violation (TMP unset) aborts the sourcing script" "$(run_harness "$h")"

# ── lib-layer-checks.sh not sourced ───────────────────────────────────────────
h="$(mk_harness "$REAL_CONF" "skip-lc" "" "")"
expect_aborted "lc_rows undefined aborts the sourcing script" "$(run_harness "$h")"

# ── A registry with no path-bin rows ──────────────────────────────────────────
# Rewrites every check row's stub_kind to repo-script, so the registry is
# well-formed and non-empty but yields zero PATH stubs — the real shape of this
# failure, not a corrupt file.
conf_no_pathbin="$TMP/no-pathbin.conf"
awk -F'|' -v OFS='|' '/^check\|/ { if ($5 == "path-bin") $5 = "repo-script" } { print }' \
  "$REAL_CONF" > "$conf_no_pathbin"
if grep -q '^check|.*|path-bin|' "$conf_no_pathbin"; then
  fail "fixture is wrong: no-pathbin.conf still holds a path-bin row"
else
  pass "fixture: no-pathbin.conf holds no path-bin row"
fi
h="$(mk_harness "$conf_no_pathbin" "" "" "")"
expect_aborted "a registry yielding no path-bin stubs aborts the sourcing script" "$(run_harness "$h")"

# ── A registry with no repo-script rows ───────────────────────────────────────
# The condition mk_repo used to `return 1` for from inside a command
# substitution, where the status was swallowed and 13 hand-written caller
# guards had to re-detect it.
conf_no_reposcript="$TMP/no-reposcript.conf"
awk -F'|' -v OFS='|' '/^check\|/ { if ($5 == "repo-script") $5 = "none" } { print }' \
  "$REAL_CONF" > "$conf_no_reposcript"
if grep -q '^check|.*|repo-script|' "$conf_no_reposcript"; then
  fail "fixture is wrong: no-reposcript.conf still holds a repo-script row"
else
  pass "fixture: no-reposcript.conf holds no repo-script row"
fi
h="$(mk_harness "$conf_no_reposcript" "" "" "")"
expect_aborted "a registry yielding no repo-script stubs aborts the sourcing script" "$(run_harness "$h")"

# ── git unusable ──────────────────────────────────────────────────────────────
# mk_repo's stub repo must be a real git repo with tracked files. When git
# cannot deliver that, Phase 7 fails with "bash -n parsed no files" — a
# DIFFERENT failure that silently satisfies any assertion merely expecting the
# phase under test to fail. Probing at source time turns that into a loud stop.
mkdir -p "$TMP/badgit"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/badgit/git"
chmod +x "$TMP/badgit/git"
h="$(mk_harness "$REAL_CONF" "" "" "")"
expect_aborted "an unusable git aborts the sourcing script" "$(run_harness "$h" "$TMP/badgit")"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
