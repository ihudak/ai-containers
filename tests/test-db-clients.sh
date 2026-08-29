#!/usr/bin/env bash
# Unit tests for db-clients / native-build / imagemagick / wkhtmltopdf wiring
# in build.sh + sandbox-common.sh (pure functions; no docker build).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# EVERY FIXTURE, IN ONE TRAP. This file removes its six scratch dirs inline as
# it finishes with each one, which cleans up a run that reaches the end and
# nothing else: an interrupted run left all six behind, and a mis-typed variable
# in one of those inline removals left one behind on EVERY run (see $F4 below).
# The inline removals stay -- they keep the peak at one fixture rather than six
# -- and this backstops them. `${VAR:-}` because the trap can fire before any of
# them is assigned, and this file runs under `set -u` via the suite driver.
trap 'rm -rf "${F1:-}" "${F2:-}" "${F3:-}" "${F4:-}" "${GA_TMP:-}"' EXIT

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
# $F4, NOT $F2. This line said "$F2" -- a fixture already removed forty lines
# above, so the removal was a no-op and $F4 was leaked on every run, PASSING
# runs included. Measured 2026-08-29 under a TMPDIR-honouring mktemp: one clean
# `bash tests/test-db-clients.sh` (rc=0) left one `out.txt+sandbox.conf` tree
# behind, and this file is the only place that signature comes from.
rm -rf "$F4"

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

# ── F60: the composition, closed by construction rather than by a fourth image ─
# Fixture 3 above proves `c-toolchain=ON` ALONE yields KEEP_BUILD_TOOLCHAIN=1.
# Integration case 730 proves KEEP_BUILD_TOOLCHAIN=1 yields a working `gcc`, and
# mutation 735 demonstrates that assertion failing. What was never demonstrated
# is the JOIN — an image built from the key alone — because the `native` variant
# obtains the toolchain through db-clients and ruby regardless, so an assertion
# there would pass whatever the c-toolchain key did. Isolating it looked like it
# needed a FOURTH image variant, built nightly to exercise one boolean.
#
# It does not, and these three assertions are why. The Dockerfile's decision
# about the runtime toolchain reads ONE input: the KEEP_BUILD_TOOLCHAIN build
# arg. It cannot know, and does not ask, which key set it. So
# (key alone -> arg), already proven above, composes with (arg -> toolchain),
# already proven in the native variant, for EVERY key that sets the arg —
# including ones added later, which a fourth variant would not have covered.
#
# That is a stronger guarantee than the variant would have bought, and it costs
# no image build. What it does NOT cover is a Dockerfile change that makes the
# decision depend on something else — which is exactly what these assert.
DF="$REPO_DIR/Dockerfile"
if [[ ! -f "$DF" ]]; then
  fail "the Dockerfile is where the toolchain decision lives"
else
  # 1. The layer that RESTORES the toolchain is guarded by the arg alone.
  keep_cond="$(grep -n 'RUN if \[ "\$KEEP_BUILD_TOOLCHAIN" = "1" \]' "$DF" | head -1)"
  if [[ -n "$keep_cond" ]]; then
    pass "the toolchain-retention layer is guarded by KEEP_BUILD_TOOLCHAIN"
  else
    fail "the toolchain-retention layer is guarded by KEEP_BUILD_TOOLCHAIN — its condition changed shape, so F60's composition argument no longer holds"
  fi

  # 2. The retention BLOCK reads no other build arg. Scoped to the block rather
  #    than to every mention of the name, because line 334 legitimately pairs
  #    the two: it FAILS THE BUILD when RUBY_RUNTIME=1 arrives without
  #    KEEP_BUILD_TOOLCHAIN=1. That asserts the invariant, it does not decide
  #    the toolchain, and a check broad enough to flag it would be turned off.
  #    This is the assertion that catches the retention being made conditional
  #    on DB_CLIENTS or RUBY_RUNTIME — the only way F60's join comes apart.
  offenders="$(awk '/RUN if \[ "\$KEEP_BUILD_TOOLCHAIN" = "1" \]/{inb=1} inb{print} inb&&/^[[:space:]]*fi[[:space:]]*$/{exit}' "$DF" \
                 | grep -nE 'DB_CLIENTS|RUBY_RUNTIME|INSTALL_' || true)"
  if [[ -z "$offenders" ]]; then
    pass "no toolchain decision is conditioned on db-clients or ruby — the arg is the whole interface"
  else
    fail "no toolchain decision is conditioned on db-clients or ruby — the arg is the whole interface"
    printf '%s\n' "$offenders" | sed 's/^/     /'
  fi

  # 3. Every purge of build-essential is behind the same arg. A purge that is
  #    not would strip the toolchain behind the key's back, and neither half
  #    above would notice.
  bad_purge="$(grep -n 'apt-get purge.*build-essential' "$DF" | grep -v 'KEEP_BUILD_TOOLCHAIN' || true)"
  if [[ -z "$bad_purge" ]]; then
    pass "every purge of build-essential is conditioned on KEEP_BUILD_TOOLCHAIN"
  else
    fail "every purge of build-essential is conditioned on KEEP_BUILD_TOOLCHAIN"
    printf '%s\n' "$bad_purge" | sed 's/^/     /'
  fi
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
