#!/usr/bin/env bash
# summary:  the OS packages Playwright's browsers need are installed in the image
# tags:     packages slow needs-external
# requires: docker launcher netadmin
# image:    native
# timeout:  3900
#
# TWO ASSERTIONS, ON PURPOSE, BECAUSE `install-deps --dry-run` IS NOT STABLE.
#
# The obvious oracle is Playwright's own `install-deps --dry-run`, and it is used
# below — but its behaviour CHANGED under this feature's own nose, and that is
# why it is not used alone. Measured, both against real images:
#
#   playwright@1.58.2, on a host with none of the packages installed:
#     printed the `sudo -- sh -c "apt-get install -y --no-install-recommends …"`
#     command it WOULD run, and exited 0. It did not consult dpkg.
#   playwright@1.62.1, in an image with every package installed:
#     printed `All system dependencies are installed.` and exited 0.
#   playwright@1.62.1, same image with libnss3 and libgbm1 removed:
#     printed `Failed to install browser dependencies … has no installation
#     candidate` and exited 1.
#
# So on 1.62 it IS the dpkg-backed check its documentation describes, and on
# 1.58 it was not. The `native` variant sets playwright=ON, i.e. LATEST AT BUILD
# TIME, so which of those two contracts this case meets is decided by whenever
# the image happened to be built. An assertion resting on one output shape is an
# assertion that goes red on a correct image the next time that shape moves —
# which is exactly what an earlier version of this case did.
#
# Assertion 2 is therefore the one that holds regardless: a fixed set of packages
# checked against dpkg, which is the authority on what is installed and has no
# output format to change. Assertion 3 then adds Playwright's own verdict where
# Playwright is willing to give one, and says so explicitly where it is not,
# rather than reporting a version that checks nothing as a pass.
#
# WHY A FIXED LIST HERE, WHEN THE DOCKERFILE DELIBERATELY DOES NOT HARDCODE ONE.
# Opposite jobs. The build layer must track whatever Playwright currently needs,
# so it asks Playwright. This case must fail when the image is wrong, which
# wants a probe that does not move under it. Every package below was MEASURED to
# be installed by no other layer of the `native` variant — checked by simulating
# imagemagick, wkhtmltopdf, the pg/mysql clients and the build toolchain on a
# clean ubuntu:24.04 and confirming none of them pulls any of these in. They
# span all three engines (chromium's NSS/GBM/a11y stack, GTK for firefox,
# gstreamer for webkit, plus fonts and xvfb), so a layer that ran partially is
# caught, not just one that did not run at all.
#
# needs-external is a TAG, not a `requires:` — the 700-series split. Assertion 3
# genuinely reaches registry.npmjs.org, and that it works in RESTRICTED mode is
# the allowlist doing its job (registry.npmjs.org comes from base.txt).
# Assertion 2 touches no network at all. netadmin IS required: launcher_up
# drives restricted mode, and a kernel that cannot run iptables/ipset kills the
# container before the agent shell exists.
#
# GROUP: $IT_RUBY_GROUP, deliberately shared with 730/740/750/760 for the reason
# their headers give — the native variant runs the two-version rvm reconcile at
# container start whatever this case does, and that gate is what IT_SETTLE
# covers. In filename order this case is last and finds the group warm; run
# alone it pays the cold compile itself, so the ceiling must cover that.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=3600

# Packages installed by the Playwright layer and by nothing else in this image.
# See the header for how that was established.
PW_PKGS=(
  libnss3 libnspr4 libgbm1                 # chromium: NSS, GPU buffer management
  libatk-bridge2.0-0t64 libatspi2.0-0t64   # chromium: accessibility bridge
  libcups2t64                              # chromium: printing
  libgtk-3-0t64                            # firefox
  libgstreamer-plugins-bad1.0-0            # webkit: media
  fonts-liberation                         # text rendering
  xvfb                                     # headed runs under a virtual display
)

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"
launcher_up restricted || it_finish

# ── 1. The layer ran at all ────────────────────────────────────────────────────
VERSION_FILE=/etc/ai-containers-playwright-version
if ! pw_version="$(docker exec "$IT_CID" cat "$VERSION_FILE" 2>/dev/null)"; then
  fail "$VERSION_FILE could not be read — the playwright build layer did not run, so no browser dependency is installed"
  it_finish
fi
pw_version="$(printf '%s' "$pw_version" | tr -d '[:space:]')"
if [[ -z "$pw_version" ]]; then
  fail "$VERSION_FILE is empty — the playwright build layer left no usable record of what it built against"
  it_finish
fi
pass "the playwright layer ran — image built against Playwright $pw_version"

# ── 2. dpkg: every representative package is installed ─────────────────────────
# The list is passed as ARGUMENTS, never interpolated into the script text, so a
# package name cannot alter the program that checks it. `install ok installed` is
# the only status meaning the files are actually on disk — a half-configured
# package satisfies `test -f` on some of its files and satisfies nothing else.
#
# The exit status is CHECKED. Without that, a docker exec that failed for any
# reason — the container gone, dpkg-query absent — returns empty stdout, which
# is indistinguishable from "nothing was missing" and would report a PASS having
# queried nothing.
if ! missing="$(docker exec "$IT_CID" bash -c '
      for p in "$@"; do
        s=$(dpkg-query -W -f="\${Status}" "$p" 2>/dev/null)
        [ "$s" = "install ok installed" ] || printf "%s\n" "$p"
      done' _ "${PW_PKGS[@]}")"; then
  fail "the dpkg probe could not run in the container — this case verified nothing about the installed packages"
  it_finish
fi

missing="$(printf '%s\n' "$missing" | sed '/^$/d')"
if [[ -z "$missing" ]]; then
  pass "all ${#PW_PKGS[@]} representative Playwright OS dependencies are installed (dpkg: install ok installed)"
else
  n="$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
  fail "$n of ${#PW_PKGS[@]} representative Playwright OS dependencies are NOT installed — browsers will fail to launch"
  printf '%s\n' "$missing" | sed 's/^/     missing: /'
fi

# ── 3. Playwright's own verdict, where it gives one ────────────────────────────
# Pinned to the version the image was BUILT against, not to `latest`: `ON`
# resolves at build time, so asking latest here would compare this image against
# a dependency list published after it was built and fail for drift rather than
# for a defect.
deps_out="$(agent_exec_login "$IT_CID" \
  "npx --yes playwright@${pw_version} install-deps --dry-run 2>&1")"
deps_rc=$?

if (( deps_rc != 0 )); then
  fail "Playwright reports its own dependencies unsatisfied (\`install-deps --dry-run\` exited $deps_rc)"
  printf '%s\n' "$deps_out" | head -6 | sed 's/^/     /'
elif grep -q 'All system dependencies are installed' <<<"$deps_out"; then
  pass "Playwright $pw_version confirms every system dependency is installed"
else
  # Exited 0 without verifying anything — the pre-1.62 contract. Reported as
  # neither a pass nor a failure, because it is neither: nothing was checked
  # here, and printing PASS would grow the coverage claim without the coverage.
  printf 'NOTE: playwright %s exited 0 from --dry-run without a verification line;\n' "$pw_version"
  printf '      this version does not check dpkg, so assertion 3 checked nothing.\n'
  printf '      Assertion 2 above is the one that holds for this image.\n'
fi

it_finish
