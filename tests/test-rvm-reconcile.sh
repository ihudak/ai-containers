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

# An install failure triggers the get-stable + reload retry, IN THAT ORDER
# (reconcile runs `rvm get stable && rvm reload && rvm install`).
log_fail="$(STUB_INSTALL_FAILS=1 run_case "" "3.4.5")"
gs_ln="$(grep -n 'rvm get stable' <<<"$log_fail" | head -1 | cut -d: -f1)"
rl_ln="$(grep -n 'rvm reload'     <<<"$log_fail" | head -1 | cut -d: -f1)"
{ [[ -n "$gs_ln" && -n "$rl_ln" && "$gs_ln" -lt "$rl_ln" ]]; } \
  && pass "install failure triggers get-stable BEFORE reload retry" \
  || fail "install failure triggers get-stable+reload retry (in order; gs=$gs_ln rl=$rl_ln)"

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

# ── Bootstrap failure + broken-~/.rvm repair ────────────────────────────────────
# run_case above pre-creates a working ~/.rvm/scripts/rvm, so it never exercises the
# bootstrap path. These cases do. The reconcile must (a) notice a failed bootstrap
# instead of sourcing nothing and then reporting every `rvm` call as not-found, and
# (b) RE-bootstrap a half-written ~/.rvm rather than sourcing it forever — a group left
# with a broken ~/.rvm by an interrupted/offline first run would otherwise fail on every
# later start with no recovery short of deleting the group's ~/.rvm by hand.
boot_case() {   # $1=curl exit code  $2=the installer body the fake curl delivers
  local curl_rc="$1" payload="$2"
  local home bin; home="$(mktemp -d)"; bin="$(mktemp -d)"
  # Only curl is stubbed (stubbing bash would shadow the reconcile's own
  # interpreter). The reconcile downloads the installer to a file with `curl -o`
  # and runs it as a SEPARATE step, so the stub honours -o; a stub that only ever
  # wrote to stdout would make every case look like a failed download.
  cat > "$bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$home/calls.log"
__out=""; __prev=""
for __a in "\$@"; do
  [[ "\$__prev" == "-o" ]] && __out="\$__a"
  __prev="\$__a"
done
if [[ -n "\$__out" ]]; then printf '%s' '$payload' > "\$__out"; else printf '%s' '$payload'; fi
exit $curl_rc
EOF
  chmod +x "$bin/curl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/rvm"; chmod +x "$bin/rvm"
  PATH="$bin:$PATH" HOME="$home" RUBY_VERSIONS="3.4.5" \
    bash "$REPO_DIR/rvm-reconcile.sh" >"$home/out.log" 2>&1
  printf '%s\n---CALLS---\n%s\n' "$(cat "$home/out.log" 2>/dev/null)" "$(cat "$home/calls.log" 2>/dev/null)"
  rm -rf "$home" "$bin"
}

# curl fails → a clear FAILED line, and no attempt to source a nonexistent rvm.
boot_fail="$(boot_case 1 "")"
grep -q 'FAILED: rvm bootstrap' <<<"$boot_fail" \
  && pass "failed bootstrap logs 'FAILED: rvm bootstrap'" \
  || fail "failed bootstrap logs 'FAILED: rvm bootstrap' (got: $boot_fail)"
grep -qE 'command not found|No such file' <<<"$boot_fail" \
  && fail "failed bootstrap must not fall through into not-found errors" \
  || pass "failed bootstrap exits cleanly (no not-found fallthrough)"

# curl succeeds but the installer writes no scripts/rvm (aborted mid-way) → still caught,
# and still no attempt to source a file that is not there.
boot_partial="$(boot_case 0 'true')"
grep -q 'FAILED:.*still missing after bootstrap' <<<"$boot_partial" \
  && pass "bootstrap that produces no scripts/rvm is caught" \
  || fail "bootstrap that produces no scripts/rvm is caught (got: $boot_partial)"

# An installer that DOWNLOADS fine but exits non-zero (GPG failure, bad unpack,
# unwritable target) must not be reported as a network/allowlist problem. Piping
# curl into bash under `set -o pipefail` collapsed both into one message that
# blamed the firewall, which sent a real investigation after the wrong component.
boot_inst_fail="$(boot_case 0 'echo "gpg: Cannot check signature: No public key" >&2; exit 2')"
grep -q 'installer downloaded fine but exited non-zero' <<<"$boot_inst_fail" \
  && pass "installer failure is reported as an installer failure" \
  || fail "installer failure is reported as an installer failure (got: $boot_inst_fail)"
grep -q 'could not download the installer' <<<"$boot_inst_fail" \
  && fail "installer failure must NOT be reported as a download failure" \
  || pass "installer failure is not reported as a download failure"
# The installer's own output is the diagnosis — it must reach the container log,
# attributed, including anything it wrote to stderr.
grep -q '\[rvm-installer\] gpg: Cannot check signature' <<<"$boot_inst_fail" \
  && pass "installer output (incl. stderr) is surfaced with an [rvm-installer] prefix" \
  || fail "installer output (incl. stderr) is surfaced with an [rvm-installer] prefix (got: $boot_inst_fail)"

# Regression guard on the property that caused the misdiagnosis: download and run
# must stay separate, never `curl … | bash`. Comment lines are stripped first —
# the code documents the pipe it deliberately avoids, and matching that prose
# would make this guard fire on a correct script.
grep -vE '^[[:space:]]*#' "$REPO_DIR/rvm-reconcile.sh" \
  | grep -qE 'curl[^|]*\|[[:space:]]*bash' \
  && fail "reconcile must NOT pipe curl straight into bash (collapses two failures into one)" \
  || pass "reconcile downloads the installer and runs it as separate steps"

# An EMPTY (zero-byte) ~/.rvm/scripts/rvm must trigger a re-bootstrap, not be sourced.
rebootstrap_home="$(mktemp -d)"; rebootstrap_bin="$(mktemp -d)"
install -d "$rebootstrap_home/.rvm/scripts"; : > "$rebootstrap_home/.rvm/scripts/rvm"   # zero bytes
printf '#!/usr/bin/env bash\necho "curl $*" >> %s/calls.log\nexit 1\n' "$rebootstrap_home" > "$rebootstrap_bin/curl"
chmod +x "$rebootstrap_bin/curl"
PATH="$rebootstrap_bin:$PATH" HOME="$rebootstrap_home" RUBY_VERSIONS="3.4.5" \
  bash "$REPO_DIR/rvm-reconcile.sh" >"$rebootstrap_home/out.log" 2>&1
grep -q 'bootstrapping rvm' "$rebootstrap_home/out.log" \
  && pass "a zero-byte ~/.rvm/scripts/rvm triggers a re-bootstrap" \
  || fail "a zero-byte ~/.rvm/scripts/rvm triggers a re-bootstrap ($(cat "$rebootstrap_home/out.log"))"
rm -rf "$rebootstrap_home" "$rebootstrap_bin"

# Version matching must be LITERAL (grep -F), so a version's dots are not regex wildcards.
grep -q 'grep -Fqx "ruby-\$v"' "$REPO_DIR/rvm-reconcile.sh" \
  && pass "version match uses grep -Fqx (dots are literal)" \
  || fail "version match uses grep -Fqx (dots are literal)"

# The flock wait must be reported, not silent: a first-run Ruby compile takes minutes and
# this runs BEFORE the shell, so a silent block is indistinguishable from a hung container.
grep -q 'flock -n 9' "$REPO_DIR/rvm-reconcile.sh" \
  && pass "reconcile tries a non-blocking flock first" \
  || fail "reconcile tries a non-blocking flock first"
grep -q 'waiting for it to finish' "$REPO_DIR/rvm-reconcile.sh" \
  && pass "reconcile announces that it is waiting on another container" \
  || fail "reconcile announces that it is waiting on another container"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
