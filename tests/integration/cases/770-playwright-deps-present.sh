#!/usr/bin/env bash
# summary:  the OS packages Playwright's browsers need are installed in the image
# tags:     packages slow needs-external
# requires: docker launcher netadmin
# image:    native
# timeout:  3900
#
# THREE ASSERTIONS, AND THE SECOND IS THE ONE THAT HOLDS, BECAUSE
# `install-deps --dry-run` IS NOT A STABLE CONTRACT.
#
# The obvious oracle is Playwright's own `install-deps --dry-run`, and it is used
# below — but its behaviour CHANGED under this feature's own nose, and that is
# why it is not used alone. Measured, each against a real image:
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
# So on 1.62 it IS the dpkg-backed check its documentation describes, and on 1.58
# it was not. The `native` variant sets playwright=ON — LATEST AT BUILD TIME — so
# which contract an image meets is decided by whenever it happened to be built.
# An assertion resting on one output shape goes red on a correct image the next
# time that shape moves, which is precisely what an earlier version of this case
# did.
#
# Assertion 2 therefore does the work: a fixed set of packages checked against
# dpkg, which is the authority on what is installed and has no output format to
# change. Assertion 3 adds Playwright's own verdict where Playwright gives one,
# and CLASSIFIES what it got rather than assuming — an unrecognised shape fails
# loudly instead of quietly becoming a no-op.
#
# ── WHY A FIXED LIST HERE, WHEN THE DOCKERFILE DELIBERATELY HARDCODES NONE ─────
# Opposite jobs. The build layer must track whatever Playwright currently needs,
# so it asks Playwright. This case must fail when the image is wrong, which wants
# a probe that does not move underneath it.
#
# HOW THE LIST WAS ESTABLISHED, and the two caveats that come with it. Every
# package below was checked against a simulated `--no-install-recommends` install
# of every OTHER apt-installing layer of the `native` variant — the Dockerfile's
# base essentials, imagemagick, the wkhtmltopdf pre-libs, the pg/mysql clients,
# build-essential/libyaml/zlib/libssl and the ruby-build extras: 249 packages,
# containing none of these ten. That figure EXCLUDES the pyenv layer, and that
# exclusion is load-bearing:
#
#   1. libnss3 and libnspr4 ARE transitively reachable. The unconditional pyenv
#      layer installs libxmlsec1-dev, which pulls libxmlsec1-nss -> libnss3 ->
#      libnspr4 (adding the pyenv set to the same simulation raises it to 312
#      packages and both appear). They are absent from the finished image ONLY
#      because the cleanup layer purges libxmlsec1-dev with --auto-remove.
#      Verified in a built image: libxmlsec1-nss is gone, and libnss3's only
#      installed reverse-dependency is libsrtp2-1, itself part of this set. That
#      purge ends in `|| true`. If its package list ever loses libxmlsec1-dev,
#      two of these ten stop discriminating and this case gets quietly weaker —
#      which is why it is written down here rather than left to be rediscovered.
#   2. fonts-liberation is the weakest member. fontconfig-config (via fontconfig,
#      in the wkhtmltopdf layer) declares `Depends: fonts-dejavu-core |
#      fonts-liberation | …`; it is absent only because apt picks the first
#      satisfiable alternative. A base-image change to that alternation would put
#      it in the image independently of Playwright.
#
# AND THE LIST CAN BREAK THE OTHER WAY. If a future Playwright DROPS one of these
# from `install-deps`, a correct image legitimately will not have it and
# assertion 2 goes red — the same class of failure as the output-shape breakage
# above, relocated from format to list membership. xvfb is the likeliest
# candidate (headed runs only). Nothing catches that before nightly; nightly IS
# the detector, and the fix is to drop the package from PW_PKGS, not to loosen
# the assertion.
#
# needs-external is a TAG, not a `requires:` — the 700-series split. Assertion 3
# genuinely reaches registry.npmjs.org, and that it works in RESTRICTED mode is
# the allowlist doing its job (registry.npmjs.org comes from base.txt).
# Assertions 1 and 2 touch no network at all. netadmin IS required: launcher_up
# drives restricted mode, and a kernel that cannot run iptables/ipset kills the
# container before the agent shell exists.
#
# GROUP: $IT_RUBY_GROUP, deliberately shared with 730/740/750/760 for the reason
# their headers give — the native variant runs the two-version rvm reconcile at
# container start whatever this case does, and that gate is what IT_SETTLE
# covers. In filename order this case is last and finds the group warm; run alone
# (`--cases 770-playwright-deps-present`, which nightly's dispatch input allows)
# it pays the cold compile itself, so the ceiling must cover that.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=3600

# Packages installed by the Playwright layer and by nothing else in this image.
# See the header for how that was established and what it depends on.
PW_PKGS=(
  libnss3 libnspr4                         # chromium: NSS (see caveat 1 above)
  libgbm1                                  # chromium: GPU buffer management
  libatk-bridge2.0-0t64 libatspi2.0-0t64   # chromium: accessibility bridge
  libcups2t64                              # chromium: printing
  libgtk-3-0t64                            # firefox
  libgstreamer-plugins-bad1.0-0            # webkit: media
  fonts-liberation                         # text rendering (see caveat 2 above)
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
# reason — the container gone, dpkg-query absent — returns empty stdout, which is
# indistinguishable from "nothing was missing" and would report a PASS having
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

# ── 3. Playwright's own verdict, CLASSIFIED ────────────────────────────────────
# Pinned to the version the image was BUILT against, not to `latest`: `ON`
# resolves at build time, so asking latest here would compare this image against
# a dependency list published after it was built and fail for drift rather than
# for a defect.
#
# THE OUTPUT IS CLASSIFIED, NOT REDUCED TO AN EXIT CODE, and the reason is that
# `npx` can fail for reasons that have nothing to do with this image's packages.
# Branching on rc alone reported "Playwright reports its own dependencies
# unsatisfied" when registry.npmjs.org was unreachable — one line after assertion
# 2 had proved via dpkg that they were installed. Two assertions contradicting
# each other send the reader to the Playwright layer instead of to the allowlist.
# Note also that `docker exec`'s OWN failure text goes to the local stderr, not
# into deps_out (the 2>&1 is inside the remote shell), so the unclassified branch
# must lead with rc rather than with output it may not have.
deps_out="$(agent_exec_login "$IT_CID" \
  "npx --yes playwright@${pw_version} install-deps --dry-run 2>&1")"
deps_rc=$?

if grep -q 'All system dependencies are installed' <<<"$deps_out"; then
  if (( deps_rc == 0 )); then
    pass "Playwright $pw_version confirms every system dependency is installed"
  else
    fail "Playwright $pw_version printed its all-installed line but exited $deps_rc — its contract has changed again"
  fi
elif grep -qE 'Missing system dependencies|has no installation candidate|Unable to locate package|Failed to install browser dependencies' <<<"$deps_out"; then
  fail "Playwright $pw_version reports its own dependencies unsatisfied (exit $deps_rc)"
  printf '%s\n' "$deps_out" | head -6 | sed 's/^/     /'
elif grep -q -- '--no-install-recommends' <<<"$deps_out"; then
  # The pre-1.62 contract, identified by the apt command it prints rather than
  # assumed from "rc 0 and no success line". Reported as neither pass nor
  # failure, because it is neither: nothing was checked, and a PASS here would
  # grow the coverage claim without the coverage.
  printf 'NOTE: playwright %s printed the apt command instead of verifying it (the\n' "$pw_version"
  printf '      pre-1.62 --dry-run contract), so assertion 3 checked nothing here.\n'
  printf '      Assertion 2 above is the one that holds for this image.\n'
else
  # Neither contract. Either the probe never ran (no network, no npx, container
  # gone) or Playwright has a third output shape. Both need a human, and neither
  # may be silently absorbed into a passing case.
  fail "the Playwright probe could not be classified (exit $deps_rc) — assertion 3 verified nothing; this is a probe or contract problem, NOT a verdict on the packages (assertion 2 above is)"
  printf '%s\n' "$deps_out" | head -6 | sed 's/^/     /'
fi

it_finish
