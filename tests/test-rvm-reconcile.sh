#!/usr/bin/env bash
# Drives rvm-reconcile.sh against a STUBBED rvm + curl (no network, no real rvm).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/rvm-reconcile.sh" && pass "rvm-reconcile.sh bash -n" || fail "rvm-reconcile.sh bash -n"

run_case() {           # $1=preinstalled  $2=RUBY_VERSIONS  [$3=out sink: calls|out (default calls)]
  local pre="$1" want="$2" sink="${3:-calls}"
  local home; home="$(mktemp -d)"
  local bin; bin="$(mktemp -d)"
  # Fake rvm: records calls; 'list strings' prints preinstalled PLUS anything a prior
  # 'install' recorded (so a successful install becomes visible, like real rvm); an
  # install fails when STUB_INSTALL_FAILS=1 or the version is in STUB_FAIL_VERSIONS.
  cat > "$bin/rvm" <<EOF
#!/usr/bin/env bash
echo "rvm \$*" >> "$home/calls.log"
case "\$1 \$2" in
  "list strings") for r in $pre; do echo "ruby-\$r"; done; [[ -f "$home/installed" ]] && cat "$home/installed" ;;
  "alias list")   [[ "\${STUB_HAS_DEFAULT:-0}" == "1" ]] && echo "default => ruby-default (default)" ;;
  "install "*)
    [[ "\${STUB_INSTALL_FAILS:-0}" == "1" ]] && exit 1
    for fv in \${STUB_FAIL_VERSIONS:-}; do [[ "\$2" == "\$fv" ]] && exit 1; done
    echo "ruby-\$2" >> "$home/installed" ;;
esac
exit 0
EOF
  chmod +x "$bin/rvm"
  # Fake curl (bootstrap) + a pre-existing rvm script so no bootstrap fetch runs.
  install -d "$home/.rvm/scripts"; printf 'true\n' > "$home/.rvm/scripts/rvm"
  PATH="$bin:$PATH" HOME="$home" RUBY_VERSIONS="$want" \
    STUB_HAS_DEFAULT="${STUB_HAS_DEFAULT:-0}" STUB_INSTALL_FAILS="${STUB_INSTALL_FAILS:-0}" \
    STUB_FAIL_VERSIONS="${STUB_FAIL_VERSIONS:-}" \
    bash "$REPO_DIR/rvm-reconcile.sh" >"$home/out.log" 2>&1
  # Return the requested stream: 'out' = the reconcile's own log lines; 'calls' = the rvm calls.
  if [[ "$sink" == "out" ]]; then cat "$home/out.log" 2>/dev/null; else cat "$home/calls.log" 2>/dev/null; fi
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

# An EXISTING default must never be re-pointed.
log_def="$(STUB_HAS_DEFAULT=1 run_case "3.3.6 3.4.5" "3.3.6 3.4.5")"
grep -q 'rvm --default use' <<<"$log_def" \
  && fail "must NOT re-point an existing default" \
  || pass "does not re-point an existing default"

# An install failure triggers the get-stable + reload retry.
log_fail="$(STUB_INSTALL_FAILS=1 run_case "" "3.4.5")"
{ grep -q 'rvm get stable' <<<"$log_fail" && grep -q 'rvm reload' <<<"$log_fail"; } \
  && pass "install failure triggers get-stable+reload retry" \
  || fail "install failure triggers get-stable+reload retry"

# Prefix collision: 3.4.50 present must NOT satisfy a request for 3.4.5.
log_pfx="$(run_case "3.4.50" "3.4.5")"
grep -q 'rvm install 3.4.5' <<<"$log_pfx" \
  && pass "prefix-collision: installs 3.4.5 despite 3.4.50 present" \
  || fail "prefix-collision: installs 3.4.5 despite 3.4.50 present"

# Total install failure must be VISIBLE (a FAILED line per version) …
out_totalfail="$(STUB_INSTALL_FAILS=1 run_case "" "3.4.5" out)"
grep -q 'FAILED: ruby-3.4.5' <<<"$out_totalfail" \
  && pass "total install failure logs FAILED: ruby-3.4.5" \
  || fail "total install failure logs FAILED: ruby-3.4.5"

# … and must NOT set a default to a version that failed to install.
calls_totalfail="$(STUB_INSTALL_FAILS=1 run_case "" "3.4.5")"
grep -q 'rvm --default use' <<<"$calls_totalfail" \
  && fail "must NOT set a default when no version installed" \
  || pass "does not set a default when no version installed"

# A version that installs successfully must NOT be reported FAILED.
out_ok="$(run_case "3.3.6" "3.3.6 3.4.5" out)"
grep -q 'FAILED:' <<<"$out_ok" \
  && fail "successful installs must not be reported FAILED" \
  || pass "successful installs are not reported FAILED"

# Partial failure: the default must skip the failed first version and use the first
# version that is actually present (3.4.5), not the first configured (3.3.6).
calls_partial="$(STUB_FAIL_VERSIONS='3.3.6' run_case "" "3.3.6 3.4.5")"
{ grep -q 'FAILED: ruby-3.3.6' <(STUB_FAIL_VERSIONS='3.3.6' run_case "" "3.3.6 3.4.5" out) \
  && grep -q 'rvm --default use 3.4.5' <<<"$calls_partial" \
  && ! grep -q 'rvm --default use 3.3.6' <<<"$calls_partial"; } \
  && pass "partial failure: default uses first PRESENT version (3.4.5), not failed 3.3.6" \
  || fail "partial failure: default uses first PRESENT version (3.4.5), not failed 3.3.6"

# Regression guard: rvm is not nounset-safe, so the reconcile must NOT enable set -u.
if grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/rvm-reconcile.sh"; then
  fail "rvm-reconcile.sh must NOT enable nounset (breaks real rvm)"
else
  pass "rvm-reconcile.sh does not enable nounset"
fi

# Regression guard: rvm install must pass --autolibs=disable (non-root; deps pre-baked).
if grep -q 'rvm install "$v" --autolibs=disable' "$REPO_DIR/rvm-reconcile.sh"; then
  pass "reconcile passes --autolibs=disable to rvm install"
else
  fail "reconcile passes --autolibs=disable to rvm install"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
