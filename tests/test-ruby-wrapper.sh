#!/usr/bin/env bash
# Drives link-default-ruby.sh against a FAKE ~/.rvm tree + a throwaway dest dir
# (no real rvm, no writes to the real /usr/local/bin).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$REPO_DIR/link-default-ruby.sh" && pass "link-default-ruby.sh bash -n" || fail "link-default-ruby.sh bash -n"

# Build a fake rvm rubies tree under $home for the given versions (space list), each
# as rubies/ruby-<ver>/bin populated with the given executables (rvm's real naming).
# Usage: mk_rvm HOME "3.4.5 3.3.6" "ruby gem bundle"
mk_rvm() {
  local home="$1" versions="$2" execs="$3" v e
  for v in $versions; do
    install -d "$home/.rvm/rubies/ruby-$v/bin"
    for e in $execs; do printf '#!/bin/sh\n' > "$home/.rvm/rubies/ruby-$v/bin/$e"; chmod +x "$home/.rvm/rubies/ruby-$v/bin/$e"; done
  done
}

# ── Case 1: links the first requested present version's execs into the dest dir ──
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle bundler rake irb erb"
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
ok=1
for b in ruby gem bundle bundler rake irb erb; do
  [[ -L "$d/$b" && "$(readlink "$d/$b")" == "$h/.rvm/rubies/ruby-3.4.5/bin/$b" ]] || ok=0
done
[[ "$ok" == 1 ]] && pass "links all default Ruby execs into the dest dir" || fail "links all default Ruby execs into the dest dir"
rm -rf "$h" "$d"

# ── Case 2: prefers rvm's own rubies/default symlink when present ──
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle"
ln -s "ruby-3.4.5" "$h/.rvm/rubies/default"
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/ruby" && "$(readlink "$d/ruby")" == "$h/.rvm/rubies/default/bin/ruby" ]] \
  && pass "prefers rubies/default when the alias symlink exists" \
  || fail "prefers rubies/default when the alias symlink exists"
rm -rf "$h" "$d"

# ── Case 3: falls back to the FIRST requested version that is actually installed ──
# 3.3.6 requested first but NOT installed; 3.4.5 requested second and installed.
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle"
RUBY_VERSIONS="3.3.6 3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/ruby" && "$(readlink "$d/ruby")" == "$h/.rvm/rubies/ruby-3.4.5/bin/ruby" ]] \
  && pass "falls back to the first PRESENT requested version (skips uninstalled 3.3.6)" \
  || fail "falls back to the first PRESENT requested version (skips uninstalled 3.3.6)"
rm -rf "$h" "$d"

# ── Case 4: no RUBY_VERSIONS → no-op (creates nothing) ──
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle"
( unset RUBY_VERSIONS; bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" ) >/dev/null 2>&1
[[ -z "$(ls -A "$d")" ]] && pass "no RUBY_VERSIONS is a no-op (dest dir stays empty)" || fail "no RUBY_VERSIONS is a no-op (dest dir stays empty)"
rm -rf "$h" "$d"

# ── Case 5: RUBY_VERSIONS set but no ruby installed → no-op, no crash ──
h="$(mktemp -d)"; d="$(mktemp -d)"   # empty ~/.rvm (nothing installed yet)
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
rc=$?
[[ $rc -eq 0 && -z "$(ls -A "$d")" ]] && pass "no installed Ruby → clean no-op (exit 0, dest empty)" || fail "no installed Ruby → clean no-op (exit 0, dest empty)"
rm -rf "$h" "$d"

# ── Case 6: only links execs that exist (missing erb is skipped, not dangling) ──
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle"   # no rake/irb/erb
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/ruby" && ! -e "$d/erb" ]] \
  && pass "only links execs that exist (missing erb skipped, no dangling link)" \
  || fail "only links execs that exist (missing erb skipped, no dangling link)"
rm -rf "$h" "$d"

# ── Regression guard: must NOT enable nounset (parity with rvm-reconcile.sh) ──
if grep -qE '^set +-[a-z]*u|nounset' "$REPO_DIR/link-default-ruby.sh"; then
  fail "link-default-ruby.sh must NOT enable nounset"
else
  pass "link-default-ruby.sh does not enable nounset"
fi

# ── entrypoint wires the wrapper after the reconcile, in all three modes ──
if grep -q 'link_default_ruby' "$REPO_DIR/entrypoint.sh"; then
  pass "entrypoint calls link_default_ruby"
else
  fail "entrypoint calls link_default_ruby"
fi
n_reconcile="$(grep -c 'run_ruby_reconcile$' "$REPO_DIR/entrypoint.sh")"
n_link="$(grep -c 'link_default_ruby$' "$REPO_DIR/entrypoint.sh")"
# 3 mode call-sites for each (definitions end in '()' so don't match the '$' anchor).
[[ "$n_reconcile" -ge 3 ]] && pass "run_ruby_reconcile wired in all three modes ($n_reconcile call-sites)" \
  || fail "run_ruby_reconcile wired in all three modes ($n_reconcile call-sites)"
[[ "$n_link" -ge 3 ]] && pass "link_default_ruby wired in all three modes ($n_link call-sites)" \
  || fail "link_default_ruby wired in all three modes ($n_link call-sites)"

# ── ruby_executable_hooks + wrapper fallback ────────────────────────────────────
# rvm rewrites gem binstub shebangs to `#!/usr/bin/env ruby_executable_hooks` (the
# executable-hooks gem in the @global gemset). Linking the binstub alone left a
# `bundle` that resolved but died with "env: 'ruby_executable_hooks': No such file
# or directory", while `ruby`/`gem` (no rewritten shebang) worked — so the breakage
# was invisible until the bootstrap itself started succeeding.

# The hook is found in the @global gemset and linked alongside the binstubs.
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle"
install -d "$h/.rvm/gems/ruby-3.4.5@global/bin"
printf '#!/bin/sh\n' > "$h/.rvm/gems/ruby-3.4.5@global/bin/ruby_executable_hooks"
chmod +x "$h/.rvm/gems/ruby-3.4.5@global/bin/ruby_executable_hooks"
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/ruby_executable_hooks" \
   && "$(readlink "$d/ruby_executable_hooks")" == "$h/.rvm/gems/ruby-3.4.5@global/bin/ruby_executable_hooks" ]] \
  && pass "links ruby_executable_hooks from the @global gemset" \
  || fail "links ruby_executable_hooks from the @global gemset"
rm -rf "$h" "$d"

# …and from ~/.rvm/bin when rvm put it there instead.
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle"
install -d "$h/.rvm/bin"
printf '#!/bin/sh\n' > "$h/.rvm/bin/ruby_executable_hooks"; chmod +x "$h/.rvm/bin/ruby_executable_hooks"
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
[[ -L "$d/ruby_executable_hooks" ]] \
  && pass "links ruby_executable_hooks from ~/.rvm/bin" \
  || fail "links ruby_executable_hooks from ~/.rvm/bin"
rm -rf "$h" "$d"

# No hook anywhere → no dangling link (the glob must not be linked literally).
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem bundle"
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
[[ ! -e "$d/ruby_executable_hooks" && -z "$(find "$d" -name '*ruby_executable_hooks*' 2>/dev/null)" ]] \
  && pass "no hook present → no ruby_executable_hooks link created" \
  || fail "no hook present → no ruby_executable_hooks link created"
rm -rf "$h" "$d"

# A binstub that does NOT run is re-pointed at rvm's wrapper…
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem"
printf '#!/usr/bin/env definitely_not_on_path\n' > "$h/.rvm/rubies/ruby-3.4.5/bin/bundle"
chmod +x "$h/.rvm/rubies/ruby-3.4.5/bin/bundle"
install -d "$h/.rvm/wrappers/default"
printf '#!/bin/sh\n' > "$h/.rvm/wrappers/default/bundle"; chmod +x "$h/.rvm/wrappers/default/bundle"
RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" >/dev/null 2>&1
[[ "$(readlink "$d/bundle")" == "$h/.rvm/wrappers/default/bundle" ]] \
  && pass "a non-running binstub falls back to the rvm wrapper" \
  || fail "a non-running binstub falls back to the rvm wrapper (got: $(readlink "$d/bundle"))"
# …while a binstub that DOES run keeps the direct link (wrappers cost a bash exec).
[[ "$(readlink "$d/ruby")" == "$h/.rvm/rubies/ruby-3.4.5/bin/ruby" ]] \
  && pass "a working binstub keeps its direct link" \
  || fail "a working binstub keeps its direct link (got: $(readlink "$d/ruby"))"
rm -rf "$h" "$d"

# No wrappers dir at all → the broken binstub is reported, not silently left as OK.
h="$(mktemp -d)"; d="$(mktemp -d)"
mk_rvm "$h" "3.4.5" "ruby gem"
printf '#!/usr/bin/env definitely_not_on_path\n' > "$h/.rvm/rubies/ruby-3.4.5/bin/bundle"
chmod +x "$h/.rvm/rubies/ruby-3.4.5/bin/bundle"
out="$(RUBY_VERSIONS="3.4.5" bash "$REPO_DIR/link-default-ruby.sh" "$h" "$d" 2>&1)"
[[ -L "$d/bundle" ]] \
  && pass "with no wrappers dir the direct link is still made (no worse than before)" \
  || fail "with no wrappers dir the direct link is still made"
grep -q 'WARNING: bundle does not run' <<<"$out" \
  && pass "with no wrappers dir the broken binstub is still reported" \
  || fail "with no wrappers dir the broken binstub is still reported (got: $out)"
rm -rf "$h" "$d"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
