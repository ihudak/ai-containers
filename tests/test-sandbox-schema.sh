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

# ── Migration hooks ─────────────────────────────────────────────────────────────
# 002: legacy openjdk-<N>=ON|OFF booleans collapse into one openjdk=<csv> key
# holding only the versions that were ON, and all legacy keys are removed.
H2_TMP="$(mktemp -d)"
cat > "$H2_TMP/sandbox.conf" <<'EOF'
# ── Java / JVM ──
openjdk-21=ON
openjdk-25=OFF
openjdk-17=ON
# trailing comment must survive untouched
node=
EOF
bash "$REPO_DIR/migrations/002-openjdk-single-key.sh" "$H2_TMP/sandbox.conf"
if grep -qx 'openjdk=21,17' "$H2_TMP/sandbox.conf" \
   && ! grep -qE '^openjdk-[0-9]+=' "$H2_TMP/sandbox.conf" \
   && grep -qx '# trailing comment must survive untouched' "$H2_TMP/sandbox.conf"; then
  pass "002 openjdk hook: collapse ON versions, drop legacy keys, keep comments"
else
  fail "002 openjdk hook: collapse ON versions, drop legacy keys, keep comments"
fi
# Idempotent: a second run (no legacy keys left) is a no-op.
before2="$(cat "$H2_TMP/sandbox.conf")"
bash "$REPO_DIR/migrations/002-openjdk-single-key.sh" "$H2_TMP/sandbox.conf"
[[ "$before2" == "$(cat "$H2_TMP/sandbox.conf")" ]] \
  && pass "002 openjdk hook: idempotent no-op on re-run" \
  || fail "002 openjdk hook: idempotent no-op on re-run"
# Regression test: file mode should be preserved across hook invocation.
H2_MODE_TMP="$(mktemp -d)"
cat > "$H2_MODE_TMP/sandbox.conf" <<'EOF'
openjdk-21=ON
openjdk-25=OFF
EOF
chmod 644 "$H2_MODE_TMP/sandbox.conf"  # Ensure standard config permissions
mode_before="$(stat -c %a "$H2_MODE_TMP/sandbox.conf" 2>/dev/null || stat -f %Lp "$H2_MODE_TMP/sandbox.conf")"
bash "$REPO_DIR/migrations/002-openjdk-single-key.sh" "$H2_MODE_TMP/sandbox.conf"
mode_after="$(stat -c %a "$H2_MODE_TMP/sandbox.conf" 2>/dev/null || stat -f %Lp "$H2_MODE_TMP/sandbox.conf")"
[[ "$mode_before" == "$mode_after" ]] \
  && pass "002 openjdk hook: preserves file mode (644)" \
  || fail "002 openjdk hook: preserves file mode (644) — was $mode_before, now $mode_after"
rm -rf "$H2_TMP" "$H2_MODE_TMP"

# 003: bare graalvm=<val> splits into graalvm-ce=<val> + graalvm-oracle= (empty).
H3_TMP="$(mktemp -d)"
cat > "$H3_TMP/sandbox.conf" <<'EOF'
graalvm=22.3.0
kotlin=
EOF
bash "$REPO_DIR/migrations/003-graalvm-split.sh" "$H3_TMP/sandbox.conf"
if grep -qx 'graalvm-ce=22.3.0' "$H3_TMP/sandbox.conf" \
   && grep -qx 'graalvm-oracle=' "$H3_TMP/sandbox.conf" \
   && ! grep -qE '^graalvm=' "$H3_TMP/sandbox.conf"; then
  pass "003 graalvm hook: split into ce (value) + oracle (empty)"
else
  fail "003 graalvm hook: split into ce (value) + oracle (empty)"
fi
# Idempotent: a second run (no bare graalvm= left) is a no-op.
before3="$(cat "$H3_TMP/sandbox.conf")"
bash "$REPO_DIR/migrations/003-graalvm-split.sh" "$H3_TMP/sandbox.conf"
[[ "$before3" == "$(cat "$H3_TMP/sandbox.conf")" ]] \
  && pass "003 graalvm hook: idempotent no-op on re-run" \
  || fail "003 graalvm hook: idempotent no-op on re-run"
# Regression test: file mode should be preserved across hook invocation.
H3_MODE_TMP="$(mktemp -d)"
cat > "$H3_MODE_TMP/sandbox.conf" <<'EOF'
graalvm=22.3.0
kotlin=
EOF
chmod 644 "$H3_MODE_TMP/sandbox.conf"  # Ensure standard config permissions
mode_before="$(stat -c %a "$H3_MODE_TMP/sandbox.conf" 2>/dev/null || stat -f %Lp "$H3_MODE_TMP/sandbox.conf")"
bash "$REPO_DIR/migrations/003-graalvm-split.sh" "$H3_MODE_TMP/sandbox.conf"
mode_after="$(stat -c %a "$H3_MODE_TMP/sandbox.conf" 2>/dev/null || stat -f %Lp "$H3_MODE_TMP/sandbox.conf")"
[[ "$mode_before" == "$mode_after" ]] \
  && pass "003 graalvm hook: preserves file mode (644)" \
  || fail "003 graalvm hook: preserves file mode (644) — was $mode_before, now $mode_after"
rm -rf "$H3_TMP" "$H3_MODE_TMP"

# ── reconcile_sandbox_conf ──────────────────────────────────────────────────────
# Source the (now guarded) sync-to-projects.sh for its helpers, pointing at a
# fixture central + migrations dir so the real repo is never touched.
# shellcheck source=/dev/null
source "$REPO_DIR/sync-to-projects.sh"

R_TMP="$(mktemp -d)"
mkdir -p "$R_TMP/migrations"
# Fixture central: current schema, with a brand-new additive key (bun) and the
# post-migration graalvm-ce / graalvm-oracle keys.
cat > "$R_TMP/central.conf" <<'EOF'
# schema-version: 3
copilot=ON
graalvm-ce=
graalvm-oracle=
bun=ON
EOF
# Fixture migration 003 that the reconcile must run against an old project file.
cat > "$R_TMP/migrations/003-graalvm-split.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="$1"
grep -qE '^graalvm=' "$file" 2>/dev/null || exit 0
old="$(grep -E '^graalvm=' "$file" | head -1 | cut -d= -f2-)"
tmp="$(mktemp)"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^graalvm= ]]; then
    printf 'graalvm-ce=%s\n' "$old" >> "$tmp"
    printf 'graalvm-oracle=\n' >> "$tmp"
    continue
  fi
  printf '%s\n' "$line" >> "$tmp"
done < "$file"
mv "$tmp" "$file"
EOF

# Project fixture: schema-version 2 (below 3, so 003 must run), a bare graalvm=
# key (to be migrated), a customized copilot value (must be PRESERVED), and no
# bun key (must be appended additively).
cat > "$R_TMP/project.conf" <<'EOF'
# schema-version: 2
copilot=OFF
graalvm=22.3.0
EOF

reconcile_sandbox_conf "$R_TMP/central.conf" "$R_TMP/project.conf" "$R_TMP/migrations" >/dev/null

# Hook ran: graalvm split; project's own copilot value preserved; new bun added;
# marker advanced to 3.
if grep -qx 'graalvm-ce=22.3.0' "$R_TMP/project.conf" \
   && grep -qx 'graalvm-oracle=' "$R_TMP/project.conf" \
   && ! grep -qE '^graalvm=' "$R_TMP/project.conf" \
   && grep -qx 'copilot=OFF' "$R_TMP/project.conf" \
   && grep -qx 'bun=ON' "$R_TMP/project.conf" \
   && [[ "$(conf_schema_version "$R_TMP/project.conf")" == "3" ]]; then
  pass "reconcile: hook runs, project keys preserved, new key added, marker → 3"
else
  fail "reconcile: hook runs, project keys preserved, new key added, marker → 3"
fi

# Idempotency: a second reconcile is a no-op — no duplicate keys, marker unchanged.
snapshot="$(cat "$R_TMP/project.conf")"
reconcile_sandbox_conf "$R_TMP/central.conf" "$R_TMP/project.conf" "$R_TMP/migrations" >/dev/null
dup_bun="$(grep -c '^bun=' "$R_TMP/project.conf")"
if [[ "$snapshot" == "$(cat "$R_TMP/project.conf")" ]] && [[ "$dup_bun" -eq 1 ]]; then
  pass "reconcile: second run is a no-op (no dup keys, marker unchanged)"
else
  fail "reconcile: second run is a no-op (no dup keys, marker unchanged)"
fi

# Marker backfill: a project file with NO marker is treated as version 0 and
# gets the marker on reconcile even when it needs no key additions.
cat > "$R_TMP/nomarker.conf" <<'EOF'
copilot=ON
graalvm-ce=
graalvm-oracle=
bun=ON
EOF
reconcile_sandbox_conf "$R_TMP/central.conf" "$R_TMP/nomarker.conf" "$R_TMP/migrations" >/dev/null
[[ "$(conf_schema_version "$R_TMP/nomarker.conf")" == "3" ]] \
  && pass "reconcile: pre-marker file (v0) is backfilled to the current marker" \
  || fail "reconcile: pre-marker file (v0) is backfilled to the current marker"
rm -rf "$R_TMP"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
