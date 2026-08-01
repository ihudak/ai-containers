#!/usr/bin/env bash
# rvm-reconcile.sh — runs as the sandbox USER at container start. Bootstraps a
# per-user rvm into the (group-mounted) ~/.rvm on first use, then additively
# installs any configured-but-missing Ruby versions. Concurrency-safe via flock
# on the shared mount; sets the default Ruby only when none exists.
set -uo pipefail
versions="${RUBY_VERSIONS:-}"
[[ -z "${versions// /}" ]] && exit 0    # no Ruby configured → nothing to do

rvm_root="$HOME/.rvm"
mkdir -p "$rvm_root"

# Serialize concurrent same-group container starts (they share the mounted ~/.rvm).
exec 9>"$rvm_root/.reconcile.lock"
flock 9

log(){ printf '[rvm-reconcile] %s\n' "$*"; }

# First run for a fresh group: user-install rvm into ~/.rvm (keys pre-seeded in
# ~/.gnupg at build, so no keyserver fetch is needed).
if [[ ! -s "$rvm_root/scripts/rvm" ]]; then
  log "bootstrapping rvm into $rvm_root (first run for this group)…"
  curl -fsSL https://get.rvm.io | bash -s stable
fi
# shellcheck disable=SC1091
source "$rvm_root/scripts/rvm"

for v in $versions; do
  if rvm list strings 2>/dev/null | grep -qx "ruby-$v"; then
    log "ruby-$v already present"
  else
    log "installing ruby-$v…"
    if ! rvm install "$v"; then
      log "install failed; refreshing rvm definitions (rvm get stable) and retrying…"
      rvm get stable && rvm reload && rvm install "$v"
    fi
  fi
done

# Set the default Ruby ONCE: only if rvm has no default alias yet. Never re-point
# an existing default (so a later container never changes another's default).
if ! rvm alias list 2>/dev/null | grep -q '^default '; then
  set -- $versions
  log "setting default ruby-$1 (first bootstrap)"
  rvm --default use "$1"
fi
log "done."
