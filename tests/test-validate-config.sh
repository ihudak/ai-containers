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

# BLD-8: an unreadable sandbox.conf is refused, not read as one with every key
# unset. Root reads any file, so this is a non-root check.
if [[ "$(id -u)" != 0 ]]; then
  cp "$ENGINE_DIR/sandbox.conf" "$TMP/unreadable.conf"; chmod 000 "$TMP/unreadable.conf"
  out="$(SANDBOX_CONF="$TMP/unreadable.conf" bash -c "source '$ENGINE_DIR/build.sh'; check_config" 2>&1)"; rc=$?
  chmod 600 "$TMP/unreadable.conf"
  [[ "$rc" != 0 && "$out" == *"cannot be read"* ]] && pass "an unreadable sandbox.conf is refused by name (BLD-8)" \
    || fail "an unreadable sandbox.conf passed check_config (rc $rc: $out)"
else
  printf 'SKIP: the unreadable sandbox.conf check needs a non-root run\n'
fi

# BLD-8: check_config reads each value from its own line, as get_versions reads
# it, so spacing, an inline comment and a CR are cut the same way…
refuses 'ruby' 'ruby=  off   # a comment'
refuses 'dtctl' $'dtctl=on\r'
refuses 'ruby' $'ruby=\toff'
accepts 'ruby=OFF   # capitals, commented' 'dtctl=0.25.0=x'
# The value is everything after the FIRST `=`: `3.4.5=off` is not `off`.
cp "$ENGINE_DIR/sandbox.conf" "$TMP/sandbox.conf"; sed -i.bak '/^ruby=/d' "$TMP/sandbox.conf" && rm -f "$TMP/sandbox.conf.bak"
printf 'ruby=3.4.5=off\n' >> "$TMP/sandbox.conf"
out="$(SANDBOX_CONF="$TMP/sandbox.conf" bash -c "source '$ENGINE_DIR/sandbox-common.sh'; check_config" 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && pass "check_config reads a value from the first =, as get_versions does" || fail "check_config and ruby=3.4.5=off (rc $rc: $out)"
# …and without a process per key: three per key cost about 0.2 s of every launch
# and build. Shims count grep, sed, cut and head: the duplicate check's grep and
# sed and the key list's grep, whatever the number of keys.
mkdir -p "$TMP/grep-bin"
for tool in grep sed cut head; do
  printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' "$tool" "$TMP/grep-calls" "$(command -v "$tool")" > "$TMP/grep-bin/$tool"
  chmod +x "$TMP/grep-bin/$tool"
done
cp "$ENGINE_DIR/sandbox.conf" "$TMP/sandbox.conf"; : > "$TMP/grep-calls"
out="$(SANDBOX_CONF="$TMP/sandbox.conf" bash -c "source '$ENGINE_DIR/sandbox-common.sh'; PATH='$TMP/grep-bin':\$PATH; check_config" 2>&1)"; rc=$?
calls="$(wc -l < "$TMP/grep-calls" | tr -d ' ')"
keys="$(grep -cE '^[A-Za-z0-9_-]+=' "$TMP/sandbox.conf")"
[[ "$rc" == 0 && "$calls" -le 3 && "$keys" -gt 20 ]] && pass "check_config runs $calls of grep, sed, cut and head for $keys keys (BLD-8)" \
  || fail "check_config ran $calls of grep, sed, cut and head for $keys keys (rc $rc: $out)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
