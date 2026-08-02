#!/usr/bin/env bash
# rvm-reconcile.sh — runs as the sandbox USER at container start. Bootstraps a
# per-user rvm into the (group-mounted) ~/.rvm on first use, then additively
# installs any configured-but-missing Ruby versions. Concurrency-safe via flock
# on the shared mount; sets the default Ruby only when none exists.
# NOTE: no `set -u` — rvm's scripts don't handle unset variables correctly (sourcing
# rvm under `set -u` dies with "_system_name: unbound variable"). This script is written
# to be safe without it (uses ${VAR:-} defaults).
set -o pipefail
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

# --autolibs=disable: don't let rvm apt-install requirements (needs root); the image pre-bakes the Ruby-build deps.
for v in $versions; do
  if rvm list strings 2>/dev/null | grep -qx "ruby-$v"; then
    log "ruby-$v already present"
  else
    log "installing ruby-$v…"
    if ! rvm install "$v" --autolibs=disable; then
      log "install failed; refreshing rvm definitions (rvm get stable) and retrying…"
      rvm get stable && rvm reload && rvm install "$v" --autolibs=disable
    fi
  fi
done

# Verify each requested version actually installed. The install loop above is
# otherwise silent on total/partial failure — surface a clear FAILED line so a
# broken container is diagnosable (the entrypoint runs this non-fatally). Collect
# the versions that are actually present, in requested order.
present=""
for v in $versions; do
  if rvm list strings 2>/dev/null | grep -qx "ruby-$v"; then
    present="${present:+$present }$v"
  else
    log "FAILED: ruby-$v is not installed (all install attempts failed)"
  fi
done

# Set the default Ruby ONCE: only if rvm has no default alias yet, and only to a
# version that is actually present (first in the requested list). Never re-point an
# existing default, and never point it at a version that failed to install.
if ! rvm alias list 2>/dev/null | grep -q '^default '; then
  if [[ -n "$present" ]]; then
    set -- $present
    log "setting default ruby-$1 (first bootstrap)"
    rvm --default use "$1"
  else
    log "no requested Ruby version is installed; not setting a default"
  fi
fi
log "done."
