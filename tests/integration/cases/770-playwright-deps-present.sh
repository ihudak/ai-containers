#!/usr/bin/env bash
# summary:  every OS package Playwright asks for is actually installed in the image
# tags:     packages slow needs-external
# requires: docker launcher netadmin
# image:    native
# timeout:  3900
#
# WHAT THIS PROVES, AND WHY THE OBVIOUS ORACLE IS NOT USED.
#
# `playwright install-deps --dry-run` looks like the oracle for this case, and
# Playwright's own CLI documentation describes it as one: "On Linux, simulates
# the install via apt-get and exits with a non-zero code if any required
# packages are missing." IT DOES NOT DO THAT. Measured against playwright@1.58.2
# on a host with none of those packages installed: it printed the `sudo -- sh -c
# "apt-get install …"` command it WOULD run and exited 0. It never consults dpkg
# at all. A case asserting `--dry-run` exits 0 would therefore pass against an
# image with not one dependency installed — green because npx works, which is
# precisely the failure mode "every case must have been seen failing" exists to
# prevent. The documented behaviour and the observed behaviour disagree, and the
# observation wins.
#
# So the command is used for the ONE thing it does do reliably: report the
# package list for this Playwright version, on this distro. That list is
# Playwright's own — the same table `install-deps` installs from — and the
# assertion is made against dpkg, which is the authority on what is installed.
# Asking the tool what it needs and checking the image separately is what makes
# this a test of the IMAGE rather than a test of the tool.
#
# THE VERSION IS PINNED TO THE IMAGE, NOT TO `latest`. The native variant sets
# playwright=ON, which resolves to whatever was latest AT BUILD TIME. Asking
# `playwright@latest` here would compare this image against a dependency list
# published after it was built — a real possibility for a reused local image,
# and a failure meaning "Playwright shipped a release", not "the layer is
# broken". The Dockerfile records the resolved version at
# /etc/ai-containers-playwright-version for exactly this, and reading it is also
# assertion 1: that file exists if and only if the layer ran.
#
# needs-external is a TAG, not a `requires:` — the same split the 700-series
# uses. npx genuinely reaches registry.npmjs.org here, so the tag is what
# excludes this from the PR gate; that this works in RESTRICTED mode is not
# incidental, it is the allowlist doing its job (registry.npmjs.org comes from
# base.txt). netadmin IS required: launcher_up drives restricted mode, and a
# kernel that cannot run iptables/ipset kills the container before the agent
# shell exists — indistinguishable from a broken image without the probe naming
# it.
#
# GROUP: $IT_RUBY_GROUP, deliberately shared with 730/740/750/760 for the reason
# their headers give — the native variant runs the two-version rvm reconcile at
# container start whatever this case does, and that gate is what IT_SETTLE below
# covers. Run in filename order this case is last and finds the group warm; run
# alone (--cases 770-playwright-deps-present) it pays the cold compile itself,
# so the ceiling has to cover that.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=3600

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"
launcher_up restricted || it_finish

# ── 1. The layer ran at all ────────────────────────────────────────────────────
VERSION_FILE=/etc/ai-containers-playwright-version
pw_version="$(docker exec "$IT_CID" cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
if [[ -n "$pw_version" ]]; then
  pass "the playwright layer ran — image built against Playwright $pw_version"
else
  fail "$VERSION_FILE is missing or empty — the playwright build layer did not run, so no browser dependency is installed"
  it_finish
fi

# ── 2. Playwright's own package list for this version ──────────────────────────
# Parsed out of the apt command --dry-run prints. Everything after
# --no-install-recommends up to the closing quote is the list.
deps_raw="$(agent_exec_login "$IT_CID" \
  "npx --yes playwright@${pw_version} install-deps --dry-run 2>/dev/null")"
mapfile -t pkgs < <(printf '%s\n' "$deps_raw" \
  | sed -n 's/.*--no-install-recommends \(.*\)"[[:space:]]*$/\1/p' \
  | tr ' ' '\n' | sed '/^$/d' | sort -u)

# A DERIVATION THAT FOUND ALMOST NOTHING MUST NOT REPORT SUCCESS. If npx failed,
# or Playwright changed the shape of that line, the loop below would iterate zero
# times and every assertion would pass vacuously — the case would go green having
# checked no package at all. The floor is deliberately well below the ~75 seen on
# 1.58.2 (it must not become a version-drift tripwire) and well above zero.
if (( ${#pkgs[@]} < 20 )); then
  fail "Playwright named only ${#pkgs[@]} package(s) — the list could not be derived, so this case checked nothing"
  printf '     raw output: %s\n' "$(printf '%s\n' "$deps_raw" | head -3)"
  it_finish
fi
pass "Playwright names ${#pkgs[@]} OS packages for version $pw_version"

# ── 3. dpkg says every one of them is installed ────────────────────────────────
# dpkg-query is the authority, not `ldconfig`/`test -f`: a package can be
# half-configured, and "install ok installed" is the only status that means the
# files are actually there.
missing="$(docker exec "$IT_CID" bash -c '
  for p in '"${pkgs[*]}"'; do
    s=$(dpkg-query -W -f="\${Status}" "$p" 2>/dev/null)
    [ "$s" = "install ok installed" ] || printf "%s\n" "$p"
  done')"

if [[ -z "$missing" ]]; then
  pass "all ${#pkgs[@]} Playwright OS dependencies are installed (dpkg: install ok installed)"
else
  n="$(printf '%s\n' "$missing" | sed '/^$/d' | wc -l | tr -d ' ')"
  fail "$n of ${#pkgs[@]} Playwright OS dependencies are NOT installed — browsers will fail to launch"
  printf '%s\n' "$missing" | sed '/^$/d' | head -20 | sed 's/^/     missing: /'
fi

it_finish
