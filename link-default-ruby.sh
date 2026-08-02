#!/usr/bin/env bash
# link-default-ruby.sh — runs as ROOT at container start, AFTER rvm-reconcile.sh has
# installed and defaulted the per-user rvm. Symlinks the default Ruby's executables
# onto the global PATH (/usr/local/bin) so NON-interactive, NON-login shells resolve
# ruby/gem/bundle without sourcing rvm — e.g. `docker exec -T <ctr> bash -c "bin/rails …"`,
# which otherwise gets "command not found". (Login and interactive shells already source
# rvm via /etc/profile.d/rvm.sh and /etc/bash.bashrc; those paths are unaffected.)
#
# Scope: this exposes the DEFAULT Ruby only. Per-project gemset selection still comes
# from .ruby-version when a shell sources rvm; a non-interactive caller that needs the
# project gemset must go through a login shell. See rvm-home-in-group design §3e/§6.
#
# No `set -u`: keep parity with rvm-reconcile.sh and tolerate an unset RUBY_VERSIONS.
set -o pipefail

[[ -n "${RUBY_VERSIONS:-}" ]] || exit 0   # no Ruby configured → nothing to expose

dev_home="${1:-$HOME}"
bin_dest="${2:-/usr/local/bin}"   # override only for testing; entrypoint uses the default
rvm_root="$dev_home/.rvm"

log(){ printf '[link-default-ruby] %s\n' "$*"; }

# Resolve the default Ruby's bin dir. Prefer rvm's own 'default' alias symlink when the
# installed rvm creates it; otherwise fall back to the first requested version that is
# actually installed — which matches the default rvm-reconcile.sh selects (first present
# version, in requested order).
bindir=""
if [[ -d "$rvm_root/rubies/default/bin" ]]; then
  bindir="$rvm_root/rubies/default/bin"
else
  for v in ${RUBY_VERSIONS:-}; do
    if [[ -d "$rvm_root/rubies/ruby-$v/bin" ]]; then
      bindir="$rvm_root/rubies/ruby-$v/bin"
      break
    fi
  done
fi

if [[ -z "$bindir" ]]; then
  log "no installed Ruby found under $rvm_root/rubies; nothing to link"
  exit 0
fi

linked=""
for b in ruby gem bundle bundler rake irb erb; do
  if [[ -x "$bindir/$b" ]]; then
    ln -sf "$bindir/$b" "$bin_dest/$b"
    linked="${linked:+$linked }$b"
  fi
done
log "linked default Ruby from $bindir into $bin_dest: ${linked:-none}"
