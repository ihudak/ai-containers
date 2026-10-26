#!/usr/bin/env bash
# build.sh's validate_config refuses, by key, the sandbox.conf values that would
# otherwise reach the build or the container as something else (bugs review
# BLD-5, BLD-6, BLD-7). Each case writes a one-key-different copy of the shipped
# sandbox.conf, so the baseline is the real file and a refusal names its key.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/build.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# vc <key=value>… — validate a copy of the shipped sandbox.conf with each key set.
vc() {
  local kv key
  cp "$ENGINE_DIR/sandbox.conf" "$TMP/sandbox.conf"
  for kv in "$@"; do
    key="${kv%%=*}"
    sed -i.bak "/^${key}=/d" "$TMP/sandbox.conf" && rm -f "$TMP/sandbox.conf.bak"
    printf '%s\n' "$kv" >> "$TMP/sandbox.conf"
  done
  VC_OUT="$(SANDBOX_CONF="$TMP/sandbox.conf" bash -c "source '$ENGINE_DIR/build.sh'; check_config; validate_config" 2>&1)"
  VC_RC=$?
}
accepts() { vc "$@"; [[ "$VC_RC" == 0 ]] && pass "accepts $*" || fail "refused $* (rc=$VC_RC: $VC_OUT)"; }
refuses() {  # <expected text> <key=value>…
  local want="$1"; shift
  vc "$@"
  [[ "$VC_RC" != 0 && "$VC_OUT" == *"$want"* ]] && pass "refuses $*, saying: $want" \
    || fail "did not refuse $* with '$want' (rc=$VC_RC: $VC_OUT)"
}

accepts                                 # the shipped file itself

# BLD-6: a lowercase on/off is not the boolean: has_versions/version_list and
# is_enabled compare the literal ON/OFF, so `ruby=off` brought back the ruby=OFF
# defect (rvm install off on every start), `dtctl=on` became a download of tag
# "von", and `c-toolchain=on` was silently OFF.
refuses 'ruby' 'ruby=off'
refuses 'dtctl' 'dtctl=on'
refuses 'c-toolchain' 'c-toolchain=on'
refuses 'copilot' 'copilot=Off'
accepts 'ruby=OFF' 'dtctl=ON' 'c-toolchain=ON'
# …and at LAUNCH: ruby installs at run time, so `ruby=off` reached the container
# without a rebuild. The check lives in check_config, which sandbox.sh runs too
# (review of batch 6, finding 1).
vc 'ruby=off'
L_OUT="$(SANDBOX_CONF="$TMP/sandbox.conf" bash -c "source '$ENGINE_DIR/sandbox-common.sh'; check_config" 2>&1)"; L_RC=$?
[[ "$L_RC" != 0 && "$L_OUT" == *ruby* ]] && pass "check_config (which sandbox.sh runs) refuses ruby=off" \
  || fail "check_config accepted ruby=off (rc=$L_RC: $L_OUT)"

# BLD-7: rust and go take ONE value; a list became a 404 URL or a toolchain
# named "stable,nightly", neither naming the key.
refuses 'go' 'go=1.24.2,1.23.1'
refuses 'rust' 'rust=stable,nightly'
accepts 'go=1.24.2' 'rust=stable'

# BLD-5: a tool whose url= cannot express a version (acli) cannot be pinned; a
# pin was installed as whatever /latest/ served, with a NOTE in the build log.
refuses 'acli' 'acli=1.3.22'
accepts 'acli=ON' 'dtctl=0.25.0'
accepts 'acli=latest'   # latest is not a pin; install_url treats it as unpinned

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
