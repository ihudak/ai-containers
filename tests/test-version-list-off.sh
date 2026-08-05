#!/usr/bin/env bash
# A version-list key set to the literal `OFF` must behave exactly like the documented
# `key=` skip — through has_versions, version_list, the generated build args, AND the
# container env sandbox.sh passes.
#
# Why this matters: sandbox.conf mixes boolean keys (whose skip value IS `OFF`) with
# version-list keys (whose skip value is empty), so `ruby=OFF` is a natural thing to
# write. Before the fix, has_versions() only tested non-empty, so `ruby=OFF` meant:
#   - RUBY_RUNTIME=1 + KEEP_BUILD_TOOLCHAIN=1  → the whole Ruby build toolchain baked in
#   - RUBY_VERSIONS="OFF" into the container    → rvm-reconcile.sh bootstrapped rvm and
#     ran `rvm install OFF`, failing on EVERY container start, into an ephemeral ~/.rvm
#     (sandbox.sh gates that group mount on is_active, which DID treat OFF as inactive —
#     the two helpers disagreed).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# ── 1. has_versions / is_active / version_list agree on OFF ─────────────────────
F1="$(mktemp -d)"
cat > "$F1/sandbox.conf" <<'EOF'
# schema-version: 4
ruby=OFF
rust=OFF
go=OFF
db-clients=OFF
openjdk=OFF
node=OFF
kubectl=OFF
EOF
(
  export SANDBOX_CONF="$F1/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"

  for k in ruby rust go db-clients openjdk node; do
    has_versions "$k" && printf 'FAIL: has_versions %s must be false for OFF\n' "$k" \
                      || printf 'PASS: has_versions %s false for OFF\n' "$k"
    is_active "$k"    && printf 'FAIL: is_active %s must be false for OFF\n' "$k" \
                      || printf 'PASS: is_active %s false for OFF\n' "$k"
    [[ -z "$(version_list "$k")" ]] && printf 'PASS: version_list %s empty for OFF\n' "$k" \
                                    || printf 'FAIL: version_list %s must be empty for OFF (got %s)\n' "$k" "$(version_list "$k")"
  done

  # get_versions MUST still report OFF verbatim — boolean keys depend on it.
  [[ "$(get_versions kubectl)" == "OFF" ]] \
    && printf 'PASS: get_versions still returns OFF verbatim (boolean keys)\n' \
    || printf 'FAIL: get_versions must return OFF verbatim\n'
) | tee "$F1/out.txt"
grep -q '^FAIL:' "$F1/out.txt" && fails=$((fails+1))

# ── 2. build args treat OFF as skip (no "OFF" leaks into a --build-arg value) ────
(
  export SANDBOX_CONF="$F1/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  declare -a args=()
  build_args_from_config args
  has_arg() { local w="$1" a; for a in "${args[@]}"; do [[ "$a" == "$w" ]] && return 0; done; return 1; }

  has_arg "RUBY_RUNTIME=0"          && printf 'PASS: RUBY_RUNTIME=0 for ruby=OFF\n'          || printf 'FAIL: RUBY_RUNTIME=0 for ruby=OFF\n'
  has_arg "KEEP_BUILD_TOOLCHAIN=0"  && printf 'PASS: KEEP_BUILD_TOOLCHAIN=0 for OFF\n'       || printf 'FAIL: KEEP_BUILD_TOOLCHAIN=0 for OFF\n'
  has_arg "RUST_TOOLCHAIN="         && printf 'PASS: RUST_TOOLCHAIN empty for rust=OFF\n'    || printf 'FAIL: RUST_TOOLCHAIN empty for rust=OFF\n'
  has_arg "GO_VERSION="             && printf 'PASS: GO_VERSION empty for go=OFF\n'          || printf 'FAIL: GO_VERSION empty for go=OFF\n'
  has_arg "DB_CLIENTS="             && printf 'PASS: DB_CLIENTS empty for db-clients=OFF\n'  || printf 'FAIL: DB_CLIENTS empty for db-clients=OFF\n'
  has_arg "INSTALL_SDKMAN=0"        && printf 'PASS: INSTALL_SDKMAN=0 for openjdk=OFF\n'     || printf 'FAIL: INSTALL_SDKMAN=0 for openjdk=OFF\n'

  # No build-arg value may be the bare string OFF (that is what reached rvm/rustup).
  leaked=""
  for a in "${args[@]}"; do [[ "$a" == *"=OFF" ]] && leaked="${leaked} $a"; done
  [[ -z "$leaked" ]] && printf 'PASS: no build-arg carries the literal value OFF\n' \
                     || printf 'FAIL: build-arg(s) carry the literal OFF:%s\n' "$leaked"
) | tee "$F1/args.txt"
grep -q '^FAIL:' "$F1/args.txt" && fails=$((fails+1))

# ── 3. validate_config still accepts OFF on a JVM key (no bogus "major version" error) ──
(
  export SANDBOX_CONF="$F1/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  if validate_config >/dev/null 2>&1; then
    printf 'PASS: validate_config accepts openjdk=OFF\n'
  else
    printf 'FAIL: validate_config rejects openjdk=OFF\n'
  fi
) | tee "$F1/val.txt"
grep -q '^FAIL:' "$F1/val.txt" && fails=$((fails+1))
rm -rf "$F1"

# ── 4. db-clients closed-set validation rejects a typo ──────────────────────────
# validate_config calls `exit 1`, and build.sh is sourced WITH `set -e`, so the
# assignment must tolerate a non-zero status explicitly or the subshell dies here
# before asserting anything.
F2="$(mktemp -d)"
printf '# schema-version: 4\ndb-clients=postgres\n' > "$F2/sandbox.conf"
(
  export SANDBOX_CONF="$F2/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  set +e
  out="$(validate_config 2>&1)"; rc=$?
  set -e
  if (( rc != 0 )) && grep -q 'unknown db-clients entry' <<<"$out"; then
    printf 'PASS: validate_config rejects db-clients=postgres with a clear error\n'
  else
    printf 'FAIL: validate_config must reject db-clients=postgres (rc=%s out=%s)\n' "$rc" "$out"
  fi
) | tee "$F2/out.txt"
grep -q '^PASS: validate_config rejects db-clients=postgres' "$F2/out.txt" \
  || { printf 'FAIL: db-clients typo rejection assertion did not run\n'; fails=$((fails+1)); }

printf '# schema-version: 4\ndb-clients=pg,mysql,mongo\n' > "$F2/sandbox.conf"
(
  export SANDBOX_CONF="$F2/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  validate_config >/dev/null 2>&1 \
    && printf 'PASS: validate_config accepts the full db-clients set\n' \
    || printf 'FAIL: validate_config accepts the full db-clients set\n'
) | tee "$F2/ok.txt"
grep -q '^FAIL:' "$F2/ok.txt" && fails=$((fails+1))
rm -rf "$F2"

# ── 5. sandbox.sh must emit RUBY_VERSIONS through version_list, not get_versions ──
# (a structural pin: the value crosses into the container, where "OFF" became
# `rvm install OFF` on every start.)
grep -qF -- '-e RUBY_VERSIONS="$(versions_to_space "$(version_list ruby)")"' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh passes RUBY_VERSIONS via version_list (OFF-normalised)" \
  || fail "sandbox.sh passes RUBY_VERSIONS via version_list (OFF-normalised)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
