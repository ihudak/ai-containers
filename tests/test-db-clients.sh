#!/usr/bin/env bash
# Unit tests for db-clients / native-build / imagemagick / wkhtmltopdf wiring
# in build.sh + sandbox-common.sh (pure functions; no docker build).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# Fixture 1: ruby + db-clients=pg,mongo + imagemagick/wkhtmltopdf ON
F1="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
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
F2="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
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

# Fixture 3: c-toolchain=ON ALONE → KEEP_BUILD_TOOLCHAIN=1
# Until this key existed there was no way to ASK for a C compiler: it arrived
# only as a side effect of ruby= or db-clients=, so a Go developer wanting
# `go test -race` (cgo, hence gcc) had to switch on an unrelated language
# runtime to get one. Fixture 2 above is the control that makes this case mean
# something — the SAME config without the key yields 0.
F3="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
cat > "$F3/sandbox.conf" <<'EOF'
# schema-version: 3
ruby=
db-clients=
c-toolchain=ON
EOF
(
  export SANDBOX_CONF="$F3/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  declare -a args=()
  build_args_from_config args
  has_arg() { local w="$1" a; for a in "${args[@]}"; do [[ "$a" == "$w" ]] && return 0; done; return 1; }
  has_arg "KEEP_BUILD_TOOLCHAIN=1" && printf 'PASS: c-toolchain=ON alone keeps the build toolchain\n' \
                                   || printf 'FAIL: c-toolchain=ON alone keeps the build toolchain\n'
  # It must not drag in anything else: the key buys a compiler, not a runtime.
  has_arg "RUBY_RUNTIME=1"    && printf 'FAIL: c-toolchain=ON pulled in the Ruby runtime\n' \
                              || printf 'PASS: c-toolchain=ON does not pull in the Ruby runtime\n'
  has_arg "DB_CLIENTS="       && printf 'PASS: c-toolchain=ON leaves DB_CLIENTS empty\n' \
                              || printf 'FAIL: c-toolchain=ON leaves DB_CLIENTS empty\n'
) | tee "$F3/out.txt"
grep -q '^FAIL:' "$F3/out.txt" && fails=$((fails+1))
rm -rf "$F3"

# Fixture 4: c-toolchain=OFF is OFF — the literal value, not just "absent".
F4="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
cat > "$F4/sandbox.conf" <<'EOF'
# schema-version: 3
ruby=
db-clients=
c-toolchain=OFF
EOF
(
  export SANDBOX_CONF="$F4/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  declare -a args=()
  build_args_from_config args
  has_arg() { local w="$1" a; for a in "${args[@]}"; do [[ "$a" == "$w" ]] && return 0; done; return 1; }
  has_arg "KEEP_BUILD_TOOLCHAIN=0" && printf 'PASS: c-toolchain=OFF still strips the toolchain\n' \
                                   || printf 'FAIL: c-toolchain=OFF still strips the toolchain\n'
) | tee "$F4/out.txt"
grep -q '^FAIL:' "$F4/out.txt" && fails=$((fails+1))
rm -rf "$F2"

# Allowlist gating: mongo present → mongodb.txt included; absent → excluded.
F3="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
cat > "$F3/sandbox.conf" <<'EOF'
# schema-version: 3
db-clients=pg
EOF
(
  export SANDBOX_CONF="$F3/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  db_clients_has mongo && printf 'FAIL: mongo absent but reported present\n' \
                       || printf 'PASS: mongo correctly absent (pg-only)\n'
) | tee "$F3/out.txt"
grep -q '^FAIL:' "$F3/out.txt" && fails=$((fails+1))
rm -rf "$F3"

[[ -f "$REPO_DIR/allowlist-domains.d/mongodb.txt" ]] \
  && printf 'PASS: mongodb.txt fragment exists\n' \
  || { printf 'FAIL: mongodb.txt fragment missing\n'; fails=$((fails+1)); }

# Exercise the ACTUAL gating line in generate_allowlists (build.sh) by running
# it inside an isolated copy of the repo and grepping the produced allowlist.
GA_TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
cp "$REPO_DIR/build.sh" "$REPO_DIR/sandbox-common.sh" "$REPO_DIR/tools-lib.sh" "$REPO_DIR/bash-floor.sh" "$GA_TMP/"
cp -r "$REPO_DIR/allowlist-domains.d" "$REPO_DIR/allowlist-proxy-domains.d" "$REPO_DIR/allowlist-cidrs.d" "$GA_TMP/"
mkdir -p "$GA_TMP/tools.d"

printf 'db-clients=pg,mongo\n' > "$GA_TMP/sandbox.conf"
( cd "$GA_TMP" && SANDBOX_CONF="$GA_TMP/sandbox.conf" bash -c 'source ./build.sh; generate_allowlists' ) >/dev/null 2>&1 || true
if grep -q 'repo.mongodb.org' "$GA_TMP/allowlist-domains.txt" 2>/dev/null; then
  pass "generate_allowlists includes mongodb.txt when db-clients has mongo"
else
  fail "generate_allowlists includes mongodb.txt when db-clients has mongo"
fi

printf 'db-clients=pg\n' > "$GA_TMP/sandbox.conf"
( cd "$GA_TMP" && SANDBOX_CONF="$GA_TMP/sandbox.conf" bash -c 'source ./build.sh; generate_allowlists' ) >/dev/null 2>&1 || true
if grep -q 'repo.mongodb.org' "$GA_TMP/allowlist-domains.txt" 2>/dev/null; then
  fail "generate_allowlists excludes mongodb.txt when db-clients lacks mongo"
else
  pass "generate_allowlists excludes mongodb.txt when db-clients lacks mongo"
fi
rm -rf "$GA_TMP"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
