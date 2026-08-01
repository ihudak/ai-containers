#!/usr/bin/env bash
# Unit tests for the rvm-home-in-group build.sh changes (pure functions; no docker).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# A multi-version ruby= must pass validate_config (no single-version error) and
# must NOT emit RUBY_VERSION/RAILS_VERSION build-args; KEEP_BUILD_TOOLCHAIN stays 1.
F1="$(mktemp -d)"
cat > "$F1/sandbox.conf" <<'EOF'
# schema-version: 4
ruby=3.3.6,3.4.5
EOF
(
  export SANDBOX_CONF="$F1/sandbox.conf"
  # shellcheck source=/dev/null
  source "$REPO_DIR/build.sh"
  if validate_config 2>/dev/null; then printf 'PASS: multi-version ruby passes validate_config\n'
  else printf 'FAIL: multi-version ruby passes validate_config\n'; fi
  declare -a args=(); build_args_from_config args
  joined=" ${args[*]} "
  case "$joined" in *" RUBY_VERSION="*) printf 'FAIL: RUBY_VERSION build-arg removed\n' ;; *) printf 'PASS: RUBY_VERSION build-arg removed\n' ;; esac
  case "$joined" in *" RAILS_VERSION="*) printf 'FAIL: RAILS_VERSION build-arg removed\n' ;; *) printf 'PASS: RAILS_VERSION build-arg removed\n' ;; esac
  has_arg() { local w="$1" a; for a in "${args[@]}"; do [[ "$a" == "$w" ]] && return 0; done; return 1; }
  has_arg "KEEP_BUILD_TOOLCHAIN=1" && printf 'PASS: KEEP_BUILD_TOOLCHAIN=1 with ruby set\n' || printf 'FAIL: KEEP_BUILD_TOOLCHAIN=1 with ruby set\n'
) | tee "$F1/out.txt"
grep -q '^FAIL:' "$F1/out.txt" && fails=$((fails+1))
rm -rf "$F1"

bash -n "$REPO_DIR/sandbox.sh" && pass "sandbox.sh bash -n" || fail "sandbox.sh bash -n"
grep -q 'install -d "\$group_root/.rvm"' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh creates the group .rvm dir" || fail "sandbox.sh creates the group .rvm dir"
grep -q 'add_mount_if_exists config_mount_flags "\$group_root/.rvm"' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh mounts the group .rvm" || fail "sandbox.sh mounts the group .rvm"
grep -q 'RUBY_VERSIONS=' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh passes RUBY_VERSIONS" || fail "sandbox.sh passes RUBY_VERSIONS"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
