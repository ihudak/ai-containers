#!/usr/bin/env bash
# Tests for check-sandbox-version.sh --check, the CI gate against a SILENT
# semantic sandbox.conf change. Builds a throwaway git repo per case so the real
# repo history is never involved.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Stand up a temp git repo containing the script, a committed baseline
# sandbox.conf, and a migrations/ dir. Echoes the repo path.
make_repo() {
  local d; d="$(mktemp -d)"
  cp "$REPO_DIR/check-sandbox-version.sh" "$d/"
  mkdir -p "$d/migrations"
  cat > "$d/sandbox.conf" <<'EOF'
# schema-version: 3
copilot=ON
kubectl=OFF
graalvm-ce=
graalvm-oracle=
EOF
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm baseline
  printf '%s' "$d"
}

# Case 1: purely additive change (new key, no removal) → passes silently, exit 0.
d="$(make_repo)"
printf 'newtool=OFF\n' >> "$d/sandbox.conf"
( cd "$d" && bash ./check-sandbox-version.sh --check ) >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "additive change passes" || fail "additive change passes"
rm -rf "$d"

# Case 2: key removed, no bump, no hook → fails, exit 1, names the key.
d="$(make_repo)"
grep -v '^kubectl=' "$d/sandbox.conf" > "$d/tmp" && mv "$d/tmp" "$d/sandbox.conf"
err="$(cd "$d" && bash ./check-sandbox-version.sh --check 2>&1 >/dev/null)"; rc=$?
if [[ $rc -ne 0 ]] && printf '%s' "$err" | grep -q 'kubectl'; then
  pass "silent key removal fails and names the key"
else
  fail "silent key removal fails and names the key (rc=$rc)"
fi
rm -rf "$d"

# Case 3: key removed WITH a marker bump AND a matching hook → passes, exit 0.
d="$(make_repo)"
grep -v '^kubectl=' "$d/sandbox.conf" > "$d/tmp" && mv "$d/tmp" "$d/sandbox.conf"
sed -E 's/^# schema-version:.*/# schema-version: 4/' "$d/sandbox.conf" > "$d/tmp" && mv "$d/tmp" "$d/sandbox.conf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/migrations/004-drop-kubectl.sh"
( cd "$d" && bash ./check-sandbox-version.sh --check ) >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "covered key removal passes" || fail "covered key removal passes"
rm -rf "$d"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
