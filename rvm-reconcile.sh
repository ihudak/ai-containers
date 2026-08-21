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
# This runs BEFORE the interactive shell, and a first-run Ruby compile takes minutes, so
# a silent block would look like a hung container: try without waiting first, and only
# then say what we are waiting for.
exec 9>"$rvm_root/.reconcile.lock"
if ! flock -n 9; then
  printf '[rvm-reconcile] another container in this group is installing Ruby — waiting for it to finish…\n'
  flock 9
fi

log(){ printf '[rvm-reconcile] %s\n' "$*"; }

# First run for a fresh group: user-install rvm into ~/.rvm (rvm signing keys are
# pre-seeded into /etc/skel/.gnupg at build, so a fresh home needs no keyserver
# fetch — but entrypoint.sh populates a home with `cp -rn`, so a group that
# already carries its own ~/.gnupg keyring keeps it and does NOT get them. The
# `host` group, which mounts the real $HOME, is the case that matters; that is
# why keyserver.ubuntu.com stays allowlisted). A half-written ~/.rvm from an
# interrupted or offline earlier run must be RE-bootstrapped, not sourced: sourcing a
# broken rvm makes every later `rvm` call a "command not found" and every version fail,
# on every subsequent start, with no way out short of deleting the group's ~/.rvm by hand.
if [[ ! -s "$rvm_root/scripts/rvm" ]]; then
  log "bootstrapping rvm into $rvm_root (first run for this group)…"
  # DOWNLOAD and RUN as two separate steps, not `curl … | bash -s stable`. Under
  # `set -o pipefail` a piped bootstrap reports ONE status for two very different
  # failures, and the message blamed the network for all of them — so a GPG,
  # unpack, or permission error inside the installer was indistinguishable from a
  # blocked host, and sent debugging after the firewall instead of the real cause.
  installer="$(mktemp 2>/dev/null)" || installer=""
  if [[ -z "$installer" ]]; then
    log "FAILED: rvm bootstrap — could not create a temp file for the installer."
    log "no Ruby will be available in this container; it will be retried on the next start."
    exit 0
  fi
  if ! curl -fsSL https://get.rvm.io -o "$installer" || [[ ! -s "$installer" ]]; then
    rm -f "$installer"
    log "FAILED: rvm bootstrap — could not download the installer from get.rvm.io."
    log "  get.rvm.io 301-redirects to bitbucket.org, so restricted mode needs BOTH"
    log "  hosts allowlisted (allowlist-domains.d/rvm.txt), not just get.rvm.io."
    log "no Ruby will be available in this container; it will be retried on the next start."
    exit 0
  fi
  # The installer's own output is the diagnosis when it fails; prefix it so it is
  # attributable in the container log rather than looking like reconcile's own.
  if ! bash "$installer" stable 2>&1 | sed 's/^/[rvm-installer] /'; then
    rm -f "$installer"
    log "FAILED: rvm bootstrap — the installer downloaded fine but exited non-zero."
    log "  This is NOT a blocked host: see the [rvm-installer] lines above for the cause."
    log "no Ruby will be available in this container; it will be retried on the next start."
    exit 0
  fi
  rm -f "$installer"
fi
if [[ ! -s "$rvm_root/scripts/rvm" ]]; then
  log "FAILED: $rvm_root/scripts/rvm still missing after bootstrap — skipping Ruby setup."
  exit 0
fi
# shellcheck disable=SC1091
if ! source "$rvm_root/scripts/rvm"; then
  log "FAILED: could not source $rvm_root/scripts/rvm — skipping Ruby setup."
  exit 0
fi

# --autolibs=disable: don't let rvm apt-install requirements (needs root); the image pre-bakes the Ruby-build deps.
# grep -Fqx: the version string is matched LITERALLY (its dots are not regex wildcards)
# and whole-line, so ruby-3.4.5 never matches ruby-3.4.50 or vice versa.
for v in $versions; do
  if grep -Fqx "ruby-$v" < <(rvm list strings 2>/dev/null); then
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
  if grep -Fqx "ruby-$v" < <(rvm list strings 2>/dev/null); then
    present="${present:+$present }$v"
  else
    log "FAILED: ruby-$v is not installed (all install attempts failed)"
  fi
done

# Set the default Ruby ONCE: only if rvm has no default alias yet, and only to a
# version that is actually present (first in the requested list). Never re-point an
# existing default, and never point it at a version that failed to install.
if ! grep -q '^default ' < <(rvm alias list 2>/dev/null); then
  if [[ -n "$present" ]]; then
    set -- $present
    log "setting default ruby-$1 (first bootstrap)"
    rvm --default use "$1"
  else
    log "no requested Ruby version is installed; not setting a default"
  fi
fi
log "done."
