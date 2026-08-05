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
# ~/.rvm is no longer a directory in the group: a named group gets a docker volume
# (a bind mount cannot host an rvm install on macOS — see tests/test-rvm-volume.sh,
# which owns the volume assertions). The bind mount survives ONLY inside the
# host-group branch, whose contract is "mount my real $HOME".
grep -q 'install -d "\$group_root/.rvm"' "$REPO_DIR/sandbox.sh" \
  && fail "sandbox.sh must NOT create a bind-mount .rvm dir (it is a volume now)" \
  || pass "sandbox.sh no longer creates a bind-mount .rvm dir"
grep -q 'add_mount_if_exists config_mount_flags "\$group_root/.rvm"' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh still bind-mounts .rvm for the host group" \
  || fail "sandbox.sh still bind-mounts .rvm for the host group"
grep -q 'RUBY_VERSIONS=' "$REPO_DIR/sandbox.sh" \
  && pass "sandbox.sh passes RUBY_VERSIONS" || fail "sandbox.sh passes RUBY_VERSIONS"

# Hosts the runtime rvm bootstrap + Ruby compile actually reach. Not obvious from
# the URLs in rvm-reconcile.sh, and each one silently breaks Ruby when missing:
#   bitbucket.org       https://get.rvm.io is a 301 to
#                       https://bitbucket.org/mpapis/rvm/raw/master/binscripts/rvm-installer.
#                       curl -fL follows it, so allowlisting get.rvm.io alone drops the
#                       bootstrap. rvm's own `rvm get stable` (reconcile's install retry)
#                       re-fetches through the same redirect, and reads the redirect's
#                       Location: to build the .asc URL — also on bitbucket.org.
#   api.bitbucket.org   the installer resolves the "stable" tag from api.github.com first
#                       and falls back to api.bitbucket.org; anonymous api.github.com is
#                       rate-limited per public IP, which every container behind one NAT
#                       shares. With the fallback blocked, a 403 = "Exhausted all sources".
#   ftp.ruby-lang.org   rvm's ruby_url_fallback_1 (config/db) when cache.ruby-lang.org
#                       fails to serve the source tarball.
for h in cache.ruby-lang.org keyserver.ubuntu.com bitbucket.org api.bitbucket.org ftp.ruby-lang.org; do
  grep -qx "$h" "$REPO_DIR/allowlist-domains.d/rvm.txt" \
    && pass "rvm.txt allowlists $h" || fail "rvm.txt allowlists $h"
done

# rvm decides whether /etc/profile.d/rvm.sh is the "deprecated" loader by grepping it
# for rvm_stored_umask — a pure heuristic that never measures a umask. Without the
# line, every bootstrap prints "…is deprecated and causes you to have umask g+w set
# in your shell", which is a false positive for a per-user install (the g+w loader was
# the old SYSTEM-WIDE multi-user one). Capturing the umask before sourcing is also what
# rvm expects of a loader, so this is the correct script, not just a silenced warning.
grep -q 'rvm_stored_umask' "$REPO_DIR/Dockerfile" \
  && pass "profile.d rvm loader stores the umask (no spurious deprecation warning)" \
  || fail "profile.d rvm loader stores the umask (no spurious deprecation warning)"

# The GitHub hosts the installer downloads rvm itself from live in base.txt (always
# included), not in rvm.txt — assert them where they actually are, so moving one out
# of base.txt cannot silently break the Ruby bootstrap.
#   github.com                          /rvm/rvm/archive/<v>.tar.gz + the release .asc
#   codeload.github.com                 where the archive URL redirects
#   release-assets.githubusercontent.com where the .asc release-asset URL redirects
#   api.github.com                      the tag list the "stable" version resolves from
for h in github.com codeload.github.com release-assets.githubusercontent.com api.github.com; do
  grep -qx "$h" "$REPO_DIR/allowlist-domains.d/base.txt" \
    && pass "base.txt allowlists $h (rvm bootstrap download path)" \
    || fail "base.txt allowlists $h (rvm bootstrap download path)"
done

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
