#!/usr/bin/env bash
# entrypoint.sh: verify_launcher_mounts refuses to start when a launcher mount
# is not the directory sandbox.sh resolved — the concurrent-container swap guard.
#
# The function is extracted and its fixed /run/ai-launcher base is pointed at a
# scratch dir, so the real stat/compare logic runs as an ordinary user. The
# device:inode a bind mount preserves (relied on here) is proven separately by
# integration case 460-launcher-mount-verified against a real daemon; this
# checks the decision the entrypoint makes given a manifest.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_DIR"; [[ -f "$REPO_DIR/base/entrypoint.sh" ]] && ENGINE="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# shellcheck source=tests/portability.sh
source "$REPO_DIR/tests/portability.sh"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# The function under test is container code: it runs on Linux and calls GNU
# `stat -c`. On a BSD host (a Mac running this suite), hand it a `stat` that
# serves -c by asking the native -f for the same %d/%i fields, so what is tested
# is the function's decision, not the host's userland.
if [[ "$_P_STAT_GNU" != "1" ]]; then
  REAL_STAT="$(command -v stat)"
  mkdir -p "$TMP/statbin"
  cat > "$TMP/statbin/stat" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == -c ]]; then shift; exec "$REAL_STAT" -f "\$@"; fi
exec "$REAL_STAT" "\$@"
SHIM
  chmod +x "$TMP/statbin/stat"
  export PATH="$TMP/statbin:$PATH"
fi

grep -q '^verify_launcher_mounts()' "$ENGINE/entrypoint.sh" \
  && pass "entrypoint defines verify_launcher_mounts" || { fail "entrypoint defines verify_launcher_mounts"; exit "$fails"; }
grep -q '^verify_launcher_mounts$' "$ENGINE/entrypoint.sh" \
  && pass "entrypoint calls verify_launcher_mounts" || fail "entrypoint calls verify_launcher_mounts"
# It must run BEFORE the mode case (so a mismatch stops the launch before the
# firewall, the service daemons, or the agent shell).
call_ln="$(grep -n '^verify_launcher_mounts$' "$ENGINE/entrypoint.sh" | head -1 | cut -d: -f1)"
case_ln="$(grep -n '^case "$mode" in' "$ENGINE/entrypoint.sh" | head -1 | cut -d: -f1)"
[[ -n "$call_ln" && -n "$case_ln" && "$call_ln" -lt "$case_ln" ]] \
  && pass "verify_launcher_mounts runs before the mode case" \
  || fail "verify_launcher_mounts runs before the mode case (call=$call_ln case=$case_ln)"

# Extract the function and repoint its fixed base at $TMP/run.
RUN="$TMP/run"
fn="$TMP/fn.sh"
awk '/^verify_launcher_mounts\(\) \{/,/^}$/' "$ENGINE/entrypoint.sh" \
  | sed "s#/run/ai-launcher#$RUN#g" > "$fn"

# $1=anchor-ok(1/0) $2=entry-ok(1/0); builds a verify dir + a dest, runs the
# extracted function, prints "rc=<n>" plus any output.
run_case() {
  local anchor_ok="$1" entry_ok="$2" d="$TMP/c$RANDOM"
  rm -rf "$RUN" "$d"; mkdir -p "$RUN" "$d/dest"
  local dev ino
  read -r dev ino < <(p_dev_ino "$d/dest")
  if [[ "$entry_ok" == 0 ]]; then ino=$((ino + 1000000)); fi   # a dest that is not what was recorded
  printf '%s\0%s\0%s\0' "$dev" "$ino" "$d/dest" > "$RUN/manifest"
  local anchor; anchor="$(p_dev_ino "$RUN" | tr ' ' ':')"
  [[ "$anchor_ok" == 0 ]] && anchor="999999:999999"
  ( set -uo pipefail
    # shellcheck source=/dev/null
    source "$fn"
    AI_LAUNCHER_ANCHOR="$anchor" verify_launcher_mounts
    printf 'rc=%s\n' "$?" ) 2>&1
}

# 1) anchor matches, the mount is what was recorded → starts (rc 0, no error)
out="$(run_case 1 1)"
[[ "$out" == *"rc=0"* ]] && ! grep -q 'ERROR' <<<"$out" \
  && pass "a verified mount lets the launch proceed" \
  || fail "a verified mount lets the launch proceed (got: $(tr '\n' ' ' <<<"$out"))"

# 2) anchor matches, the mount is a different inode → refuses (the function exits
# non-zero, so the subshell carries it; no rc=0 line is printed)
out="$(run_case 1 0)"
grep -q 'ERROR:.*is not the directory it was checked as' <<<"$out" \
  && grep -q 'refusing to' <<<"$out" && [[ "$out" != *"rc=0"* ]] \
  && pass "a swapped mount (different inode) refuses the launch, naming it" \
  || fail "a swapped mount refuses the launch (got: $(tr '\n' ' ' <<<"$out"))"

# 3) anchor does NOT match → this filesystem does not preserve device:inode, so
# verification is skipped with a warning rather than refusing (even though the
# entry would mismatch)
out="$(run_case 0 0)"
[[ "$out" == *"rc=0"* ]] && grep -q 'does not preserve device/inode' <<<"$out" \
  && ! grep -q 'ERROR' <<<"$out" \
  && pass "an anchor mismatch notes and skips, so a non-preserving filesystem still launches" \
  || fail "anchor mismatch notes and skips (got: $(tr '\n' ' ' <<<"$out"))"

# 4) no anchor / no manifest → nothing to do
# shellcheck source=/dev/null
out="$( set -uo pipefail; source "$fn"; unset AI_LAUNCHER_ANCHOR; verify_launcher_mounts; printf 'rc=%s\n' "$?" 2>&1 )"
[[ "$out" == *"rc=0"* ]] && pass "no anchor → nothing to verify, launch proceeds" \
  || fail "no anchor → nothing to verify (got: $out)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
