#!/usr/bin/env bash
# Unit tests for db-clients / native-build / imagemagick / wkhtmltopdf wiring
# in build.sh + sandbox-common.sh (pure functions; no docker build).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Fixture 1: ruby + db-clients=pg,mongo + imagemagick/wkhtmltopdf ON
F1="$(mktemp -d)"
cat > "$F1/sandbox.conf" <<'EOF'
# schema-version: 3
ruby=3.4.5
db-clients=pg,mongo
imagemagick=ON
wkhtmltopdf=ON
EOF

(
  export SANDBOX_CONF="$F1/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"

  db_clients_has pg    && printf 'PASS: db_clients_has pg\n'    || printf 'FAIL: db_clients_has pg\n'
  db_clients_has mongo && printf 'PASS: db_clients_has mongo\n' || printf 'FAIL: db_clients_has mongo\n'
  db_clients_has mysql && printf 'FAIL: db_clients_has mysql (should be absent)\n' \
                       || printf 'PASS: db_clients_has mysql absent\n'

  declare -a args=()
  build_args_from_config args
  has_arg() { local w="$1" a; for a in "${args[@]}"; do [[ "$a" == "$w" ]] && return 0; done; return 1; }

  has_arg "DB_CLIENTS=pg mongo"    && printf 'PASS: DB_CLIENTS build-arg\n'        || printf 'FAIL: DB_CLIENTS build-arg\n'
  has_arg "KEEP_BUILD_TOOLCHAIN=1" && printf 'PASS: KEEP_BUILD_TOOLCHAIN=1\n'      || printf 'FAIL: KEEP_BUILD_TOOLCHAIN=1\n'
  has_arg "INSTALL_IMAGEMAGICK=1"  && printf 'PASS: INSTALL_IMAGEMAGICK=1\n'       || printf 'FAIL: INSTALL_IMAGEMAGICK=1\n'
  has_arg "INSTALL_WKHTMLTOPDF=1"  && printf 'PASS: INSTALL_WKHTMLTOPDF=1\n'       || printf 'FAIL: INSTALL_WKHTMLTOPDF=1\n'
) | tee "$F1/out.txt"
grep -q '^FAIL:' "$F1/out.txt" && fails=$((fails+1))
rm -rf "$F1"

# Fixture 2: no ruby, no db-clients → KEEP_BUILD_TOOLCHAIN=0
F2="$(mktemp -d)"
cat > "$F2/sandbox.conf" <<'EOF'
# schema-version: 3
ruby=
db-clients=
EOF
(
  export SANDBOX_CONF="$F2/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  declare -a args=()
  build_args_from_config args
  has_arg() { local w="$1" a; for a in "${args[@]}"; do [[ "$a" == "$w" ]] && return 0; done; return 1; }
  has_arg "KEEP_BUILD_TOOLCHAIN=0" && printf 'PASS: KEEP_BUILD_TOOLCHAIN=0 when unset\n' \
                                   || printf 'FAIL: KEEP_BUILD_TOOLCHAIN=0 when unset\n'
) | tee "$F2/out.txt"
grep -q '^FAIL:' "$F2/out.txt" && fails=$((fails+1))
rm -rf "$F2"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
