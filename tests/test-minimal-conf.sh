#!/usr/bin/env bash
# tests/test-minimal-conf.sh — tests/integration/minimal-conf.sh turns EVERY
# component off, whatever value the developer's sandbox.conf gives it.
#
# docs/testing.md promises that a launcher case never inherits the developer's
# sandbox.conf, and both run.sh's image builds and lib.sh's launcher read the
# conf through this script. It used to reset `=ON` and a hand-kept list of
# version-list keys, and nothing else, so every key added since kept a pinned
# value: `postgres=16` put a PostgreSQL server in the default image and every
# launcher case, and `mariadb=11.4` made the services variant refuse to build
# ("mysql and mariadb are both on") and failed 785/790/800 (TST-4).
#
# The second half is DERIVED from the real sandbox.conf, so a key added
# tomorrow is checked without an edit here.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/sandbox.conf" ]] || ENGINE_DIR="$REPO_DIR/base"
MINIMAL="$REPO_DIR/tests/integration/minimal-conf.sh"
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # $1=label $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
val() { grep -E "^$1=" <<<"$2" | head -n 1 | cut -d= -f2-; }   # $1=key $2=conf text

for f in "$MINIMAL" "$ENGINE_DIR/sandbox.conf"; do
  [[ -f "$f" ]] || { fail "$f exists"; printf '\n%d failure(s)\n' "$fails"; exit 1; }
done

# ── A developer's conf: every shape a value takes ─────────────────────────────
cat > "$TMP/dev.conf" <<'CONF'
# a comment that names postgres=16 must survive untouched
copilot=ON
kiro=OFF
node=22,20
nvm-version=v0.40.5
python=
ruby=OFF
postgres=16
mariadb=11.4
mongo=8.2
playwright=1.50.0
dtctl=0.25.0
angular-cli=19
db-clients=pg,mongo
redis=ON  # an inline comment
CONF
out="$(bash "$MINIMAL" "$TMP/dev.conf")"; rc=$?
check "minimal-conf.sh exits 0" 0 "$rc"
for k in copilot kiro node ruby postgres mariadb mongo playwright dtctl angular-cli db-clients redis; do
  check "$k is OFF" OFF "$(val "$k" "$out")"
done
check "an empty value stays empty" "" "$(val python "$out")"
check "nvm-version, a setting rather than a component, goes back to the Dockerfile default (empty)" \
  "" "$(val nvm-version "$out")"
check "comment lines are untouched" \
  "# a comment that names postgres=16 must survive untouched" "$(head -n 1 <<<"$out")"

# The review's failure: the services variant turned three servers on over a
# conf that pinned mariadb, and build.sh refused the pair.
out="$(bash "$MINIMAL" "$TMP/dev.conf" redis=ON mysql=ON mongo=ON)"
check "an override turns one component back on" ON "$(val redis "$out")"
check "an override for a key the conf lacks is appended" ON "$(val mysql "$out")"
check "an override replaces a reset value" ON "$(val mongo "$out")"
check "a pinned mariadb does not ride along into the services variant" OFF "$(val mariadb "$out")"

# ── Derived: every key the real sandbox.conf has, pinned, comes back off ──────
# Each key is given a value no reset list could anticipate. Whatever comes back
# must be OFF, or empty — never the pin.
n=0
while IFS= read -r line; do
  [[ "$line" =~ ^([a-z0-9-]+)= ]] || continue
  printf '%s=9.9.9\n' "${BASH_REMATCH[1]}"
  n=$((n+1))
done < "$ENGINE_DIR/sandbox.conf" > "$TMP/pinned.conf"
if (( n > 10 )); then
  pass "read $n keys from the real sandbox.conf"
else
  fail "read only $n keys from the real sandbox.conf — the derived check below would prove little"
fi
out="$(bash "$MINIMAL" "$TMP/pinned.conf")"
leaked=""
while IFS= read -r line; do
  [[ "$line" =~ ^([a-z0-9-]+)=(.*)$ ]] || continue
  case "${BASH_REMATCH[2]}" in OFF|'') ;; *) leaked+="${BASH_REMATCH[1]}=${BASH_REMATCH[2]} " ;; esac
done <<<"$out"
if [[ -z "$leaked" ]]; then
  pass "no key of the real sandbox.conf keeps a pinned value"
else
  fail "keys of the real sandbox.conf that keep a pinned value: $leaked"
fi
check "every key comes back, none dropped" "$n" "$(grep -cE '^[a-z0-9-]+=' <<<"$out")"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
