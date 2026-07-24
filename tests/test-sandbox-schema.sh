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

# ── Duplicate-key guard ─────────────────────────────────────────────────────────
# A file with a deliberately duplicated key must make get_versions() exit non-zero
# with a message naming the file and the duplicated key.
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
  get_versions copilot
) >/dev/null 2>"$dup_err"
dup_rc=$?
if [[ $dup_rc -ne 0 ]] && grep -q 'duplicate key "copilot"' "$dup_err" \
   && grep -q "$DUP_TMP/sandbox.conf" "$dup_err"; then
  pass "duplicate key → get_versions exits non-zero with a clear message"
else
  fail "duplicate key → get_versions exits non-zero with a clear message (rc=$dup_rc)"
fi

# A single (non-duplicated) key must still resolve normally.
(
  export SANDBOX_CONF="$DUP_TMP/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/sandbox-common.sh"
  [[ "$(get_versions kubectl)" == "OFF" ]]
) && pass "single key still resolves" || fail "single key still resolves"
rm -rf "$DUP_TMP"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
