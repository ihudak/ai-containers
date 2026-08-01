#!/usr/bin/env bash
# Drives rvm-reconcile.sh against a STUBBED rvm + curl (no network, no real rvm).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/rvm-reconcile.sh" && pass "rvm-reconcile.sh bash -n" || fail "rvm-reconcile.sh bash -n"

run_case() {           # $1=preinstalled(space list)  $2=RUBY_VERSIONS  -> echoes the rvm-call log
  local pre="$1" want="$2"
  local home; home="$(mktemp -d)"
  local bin; bin="$(mktemp -d)"
  # Fake rvm: records calls; 'list strings' prints preinstalled; 'alias list' empty first run.
  cat > "$bin/rvm" <<EOF
#!/usr/bin/env bash
echo "rvm \$*" >> "$home/calls.log"
case "\$1 \$2" in
  "list strings") for r in $pre; do echo "ruby-\$r"; done ;;
  "alias list")   : ;;   # no default yet
esac
exit 0
EOF
  chmod +x "$bin/rvm"
  # Fake curl (bootstrap) + a pre-existing rvm script so no bootstrap fetch runs.
  install -d "$home/.rvm/scripts"; printf 'true\n' > "$home/.rvm/scripts/rvm"
  PATH="$bin:$PATH" HOME="$home" RUBY_VERSIONS="$want" bash "$REPO_DIR/rvm-reconcile.sh" >/dev/null 2>&1
  cat "$home/calls.log" 2>/dev/null
  rm -rf "$home" "$bin"
}

log="$(run_case "3.3.6" "3.3.6 3.4.5")"
grep -q 'rvm install 3.4.5' <<<"$log"      && pass "installs the missing version (3.4.5)" || fail "installs the missing version (3.4.5)"
grep -q 'rvm install 3.3.6' <<<"$log"       && fail "must NOT reinstall present 3.3.6"      || pass "does not reinstall present 3.3.6"
grep -qE 'rvm (--default use|use .*--default|default use)' <<<"$log" \
  && pass "sets a default when none exists" || fail "sets a default when none exists"

# Empty RUBY_VERSIONS → no-op.
log2="$(run_case "" "")"
[[ -z "$log2" ]] && pass "empty RUBY_VERSIONS is a no-op" || fail "empty RUBY_VERSIONS is a no-op"

# entrypoint wires the reconcile in all three modes, before agent-skill install.
grep -q 'run_ruby_reconcile' "$REPO_DIR/entrypoint.sh" \
  && pass "entrypoint calls run_ruby_reconcile" || fail "entrypoint calls run_ruby_reconcile"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
