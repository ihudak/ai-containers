#!/usr/bin/env bash
# host-preflight.sh: a CRLF engine file is REFUSED (by every entry point that
# sources it), a WSL /mnt/<drive> checkout is WARNED about, and neither fires
# on a healthy checkout. See host-preflight.sh's header for why each exists.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: this repo keeps the engine at the root, the mgd port under base/.
if [[ -f "$ROOT/base/host-preflight.sh" ]]; then ENGINE="$ROOT/base"; else ENGINE="$ROOT"; fi
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=/dev/null
source "$ENGINE/host-preflight.sh"

# ── host_crlf_files ──────────────────────────────────────────────────────────
d="$TMP/eng"; mkdir -p "$d/tools.d" "$d/allowlist-domains.d"
printf '#!/bin/bash\necho ok\n' > "$d/good.sh"
printf 'example.com\n' > "$d/allowlist-domains.d/base.txt"
printf 'ruby=OFF\r\n' > "$d/sandbox.conf"          # parsed CR-tolerantly: not scanned
[[ -z "$(host_crlf_files "$d")" ]] && pass "an all-LF tree reports nothing (sandbox.conf is not scanned)" \
  || fail "an all-LF tree reports nothing, got: $(host_crlf_files "$d")"
printf '#!/bin/bash\r\necho ok\r\n' > "$d/bad.sh"
printf 'example.com\r\n' > "$d/allowlist-domains.d/custom.txt"
printf 'repo=x/y\r\n' > "$d/tools.d/t.conf"
printf 'FROM x\r\n' > "$d/Dockerfile"
got="$(host_crlf_files "$d" | sort | tr '\n' ' ')"
want="Dockerfile allowlist-domains.d/custom.txt bad.sh tools.d/t.conf "
[[ "$got" == "$want" ]] && pass "CRLF found in scripts, Dockerfile, tools.d and allowlist fragments" \
  || fail "CRLF found in scripts, Dockerfile, tools.d and allowlist fragments: want '$want' got '$got'"

# ── host_real_path (the real one; later sections override it) ────────────────
ln -s "$d" "$TMP/link"
want="$(cd "$d" && pwd -P)"
got="$(host_real_path "$TMP/link")"
[[ "$got" == "$want" ]] && pass "host_real_path resolves a symlinked checkout to its target" \
  || fail "host_real_path resolves a symlinked checkout to its target: want '$want' got '$got'"
got="$(host_real_path "$TMP/does-not-exist")"
[[ "$got" == "$TMP/does-not-exist" ]] && pass "host_real_path returns an unresolvable path unchanged" \
  || fail "host_real_path returns an unresolvable path unchanged, got '$got'"

# ── host_checkout_preflight ──────────────────────────────────────────────────
host_is_wsl() { return 1; }
host_checkout_preflight "$d" 2>"$TMP/err"; rc=$?
[[ "$rc" -eq 1 ]] && grep -q 'CRLF' "$TMP/err" && grep -q 'bad.sh' "$TMP/err" \
  && pass "CRLF is refused, naming the file" || fail "CRLF is refused, naming the file (rc=$rc): $(cat "$TMP/err")"
grep -q "sed -i 's/\\\\r\$//'" "$TMP/err" && pass "the refusal names the fix" \
  || fail "the refusal names the fix: $(cat "$TMP/err")"

rm "$d/bad.sh" "$d/allowlist-domains.d/custom.txt" "$d/tools.d/t.conf" "$d/Dockerfile"
host_checkout_preflight "$d" 2>"$TMP/err"; rc=$?
[[ "$rc" -eq 0 && ! -s "$TMP/err" ]] && pass "a healthy non-WSL checkout passes silently" \
  || fail "a healthy non-WSL checkout passes silently (rc=$rc): $(cat "$TMP/err")"

# WSL: a /mnt/<drive> path is warned about, anything else is not. The
# canonical path is faked through host_real_path, so no real /mnt is needed.
host_is_wsl() { return 0; }
host_checkout_preflight "$d" 2>"$TMP/err"; rc=$?
[[ "$rc" -eq 0 && ! -s "$TMP/err" ]] && pass "WSL, ext4 checkout: no warning" \
  || fail "WSL, ext4 checkout: no warning (rc=$rc): $(cat "$TMP/err")"
host_real_path() { printf '/mnt/c/Users/x/ai-containers'; }
host_checkout_preflight "$d" 2>"$TMP/err"; rc=$?
[[ "$rc" -eq 0 ]] && grep -q 'Windows filesystem' "$TMP/err" && grep -qF 'e.g. ~/dev' "$TMP/err" \
  && pass "WSL, /mnt/c checkout: warned (not refused), naming the fix" \
  || fail "WSL, /mnt/c checkout: warned (not refused), naming the fix (rc=$rc): $(cat "$TMP/err")"
host_real_path() { printf '/mnt/wsl/docker-desktop'; }
host_checkout_preflight "$d" 2>"$TMP/err"; rc=$?
[[ "$rc" -eq 0 && ! -s "$TMP/err" ]] && pass "WSL, /mnt/wsl (not a drive letter): no warning" \
  || fail "WSL, /mnt/wsl (not a drive letter): no warning: $(cat "$TMP/err")"
host_real_path() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
host_is_wsl() { return 1; }

# ── every entry point actually calls it ──────────────────────────────────────
# Effect, not grep: a CRLF file planted in a copy of the real engine must stop
# each entry point with the preflight's message.
eng="$TMP/copy"; mkdir -p "$eng"
cp -a "$ENGINE/." "$eng/" 2>/dev/null
rm -rf "$eng/.git"
printf 'example.com\r\n' > "$eng/allowlist-domains.d/zz-crlf.txt"
# A docker that always fails: if a preflight call were missing, the entry point
# must not reach a real daemon — it fails, without the preflight's message.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 99\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
for ep in "build.sh" "sandbox.sh restricted" "project-init.sh" "sync-to-projects.sh $TMP"; do
  read -r -a argv <<<"$ep"
  ( cd "$eng" && HOME="$TMP/home" AI_CONTAINER_GROUP_INIT=clean PATH="$TMP/bin:$PATH" "$BASH" "${argv[@]}" ) \
    </dev/null >"$TMP/out" 2>"$TMP/err"; rc=$?
  [[ "$rc" -ne 0 ]] && grep -q 'zz-crlf.txt' "$TMP/err" \
    && pass "${argv[0]} refuses a CRLF checkout" \
    || fail "${argv[0]} refuses a CRLF checkout (rc=$rc): $(tail -3 "$TMP/err")"
done

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
