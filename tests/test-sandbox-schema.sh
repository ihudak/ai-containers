#!/usr/bin/env bash
# Unit tests for the sandbox.conf schema-version + key-aware migration machinery:
#   - the duplicate-key guard in get_versions() (sandbox-common.sh)
#   - the migrations/ hooks (Task 2)
#   - reconcile_sandbox_conf() in sync-to-projects.sh (Task 3)
#   - bump-sandbox-version.sh (Task 4)
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# ── Duplicate-key guard (in check_config, not get_versions) ────────────────────
# check_config is always called as a plain statement (never via $(...)), so its
# exit actually terminates the script; get_versions is always called inside
# $(...) by every real caller, where exit would be silently swallowed by the
# subshell — so the guard belongs in check_config, not get_versions.
DUP_TMP="$(mktemp -d)"
cat > "$DUP_TMP/sandbox.conf" <<'EOF'
# schema-version: 3
copilot=ON
kubectl=OFF
copilot=OFF
EOF
dup_err="$DUP_TMP/err.txt"
(
  export SANDBOX_CONF="$DUP_TMP/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/sandbox-common.sh"
  check_config
) >/dev/null 2>"$dup_err"
dup_rc=$?
if [[ $dup_rc -ne 0 ]] && grep -q 'duplicate key' "$dup_err" \
   && grep -q 'copilot' "$dup_err" && grep -q "$DUP_TMP/sandbox.conf" "$dup_err"; then
  pass "duplicate key → check_config exits non-zero with a clear message"
else
  fail "duplicate key → check_config exits non-zero with a clear message (rc=$dup_rc)"
fi
rm -rf "$DUP_TMP"

# A clean file (no duplicates) passes check_config, and get_versions (unguarded)
# still resolves a single key normally.
CLEAN_TMP="$(mktemp -d)"
cat > "$CLEAN_TMP/sandbox.conf" <<'EOF'
# schema-version: 3
copilot=ON
kubectl=OFF
EOF
(
  export SANDBOX_CONF="$CLEAN_TMP/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/sandbox-common.sh"
  check_config && [[ "$(get_versions kubectl)" == "OFF" ]]
) && pass "clean file: check_config passes, get_versions still resolves" \
  || fail "clean file: check_config passes, get_versions still resolves"
rm -rf "$CLEAN_TMP"

# Regression test for zero-match edge case: a file with only comments/blanks.
# This test runs under set -euo pipefail (like real callers build.sh/runme.sh)
# to ensure the guard's pipeline doesn't die silently when grep finds zero matches.
EMPTY_TMP="$(mktemp -d)"
cat > "$EMPTY_TMP/sandbox.conf" <<'EOF'
# Just a comment
# No actual key=value lines

EOF
empty_err="$EMPTY_TMP/err.txt"
# This subshell must run under set -euo pipefail to match production behavior
(
  set -euo pipefail
  export SANDBOX_CONF="$EMPTY_TMP/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/sandbox-common.sh"
  check_config
) >/dev/null 2>"$empty_err"
empty_rc=$?
if [[ $empty_rc -eq 0 ]]; then
  pass "zero-match edge case (only comments): check_config exits 0, no silent death"
else
  fail "zero-match edge case (only comments): check_config exits 0, no silent death (rc=$empty_rc, stderr: $(cat "$empty_err"))"
fi
rm -rf "$EMPTY_TMP"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
