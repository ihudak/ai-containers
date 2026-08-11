#!/usr/bin/env bash
# summary:  the db clients and native image tools are present AND actually run
# tags:     packages slow needs-external
# requires: docker launcher netadmin
# image:    native
# timeout:  3900
#
# The wkhtmltopdf layer installs a JAMMY .deb on an ubuntu:24.04 (noble) base and
# pre-installs libjpeg-turbo8 by hand. That combination is the fragile one, and a
# .deb that installs cleanly can still produce a binary that cannot resolve its
# libraries — so PRESENCE is not the assertion, EXECUTION is. assert_runs (Task
# 6) checks the binary is on PATH AND that it actually runs, and on failure
# dumps the link target and shebang instead of just "MISSING" — the distinction
# CHANGELOG.md's Phase-2 bug-fix note describes: an earlier version of this
# check tested `head`'s exit status instead of the tool's, so "PRESENT BUT
# FAILED TO RUN" was unreachable for its entire existence.
#
# gcc is in the list because native extensions — the pg/mysql2 gems, Python
# source wheels — compile at container RUNTIME, not at image build time, so a
# missing compiler breaks every gem with a C extension at container start and
# nothing else in this corpus would notice.
#
# gcc is NOT, however, evidence that KEEP_BUILD_TOOLCHAIN's restore layer fired,
# and this comment used to claim it was. Measured, not reasoned: mutation
# 735-toolchain-not-restored makes that layer unreachable while build.sh still
# passes KEEP_BUILD_TOOLCHAIN=1, and this case still PASSED all six assertions
# (run 31466356415). gcc survives the Dockerfile:219 `apt-get purge
# --auto-remove build-essential` on its own — build-essential is a metapackage,
# and --auto-remove keeps anything another installed package still needs. So the
# gcc assertion could not fail for the reason it was written down for.
#
# The yaml.h check below is the discriminating one. libyaml-dev appears exactly
# once in the Dockerfile — in that restore layer (line 293) — so /usr/include/
# yaml.h is present if and only if the layer ran. It is also the header rvm
# needs to build psych, which is why a stripped toolchain shows up as a Ruby
# bootstrap failure rather than a missing compiler.
#
# All six answer --version cleanly per the per-binary conventions checked while
# writing this case (psql, mysql, mongosh, convert, wkhtmltopdf and gcc all
# support the flag and exit 0 on it independent of any server/network state).
# verify-on-host.sh's own Phase 2 runs the identical `"$c" --version 2>&1`
# probe over the identical list, which corroborates the choice; its claim of
# "real version strings in past runs" is cited here as an UNVERIFIED historical
# note, not evidence — no log artifact from that claim was inspected.
# CHANGELOG.md's Phase-2 fix was about capturing the WRONG process's exit
# status (`head`'s, not the tool's) — never about any of the six not
# supporting the flag. assert_runs is used unmodified.
#
# The requires line above lists docker, launcher and netadmin — and
# deliberately NOT external, checked rather than assumed, though narrower than
# "a network-less machine finishes faster" (reworded off a leading "requires:"
# at column 0, which parses as a second header key and is saved only by
# case_meta's head -1; case 750's header records the same hazard):
# psql/mysql/mongosh/convert/wkhtmltopdf/gcc are every one of them
# installed by a Dockerfile RUN layer (DB_CLIENTS, INSTALL_IMAGEMAGICK,
# INSTALL_WKHTMLTOPDF, KEEP_BUILD_TOOLCHAIN) at IMAGE BUILD time, so this
# case's own SIX ASSERTIONS never touch the network at container run time —
# that is the actual, checked reason external is omitted. The Ruby reconcile's
# own wall-clock is a separate question: a DNS-absent machine does fail
# rvm-reconcile.sh's bootstrap curl fast, but rvm-reconcile.sh:46 sets no
# `--connect-timeout`, so a machine with working DNS and a filtered route could
# stall on that curl considerably longer than "a few seconds" — this is not
# claimed to be fast, only that it cannot make the six assertions below fail.
# netadmin IS required: launcher_up drives restricted mode, entrypoint.sh's
# apply_restricted_firewall runs iptables/ipset under `set -euo pipefail`, and a
# kernel that cannot do that kills the container before PID 1 ever hands over to
# the sandbox user — indistinguishable from a mount bug without the probe naming
# it (see case 430, the other launcher-driven restricted-mode case, which
# requires the same two capabilities). needs-external stays a TAG ONLY, matching
# the 700-series and the increment's own design doc (tag-vs-requires is a
# deliberate split there): the Ruby reconcile below DOES make real network
# calls, which is what the tag exists to flag for PR-gate exclusion, but this
# case's six assertions never depend on those calls succeeding.
#
# The 3900s ceiling above, and IT_SETTLE=3600 below, are the real cost this
# case pays, and it has NOTHING to do with the six binaries above. (Reworded
# off a leading "timeout:" at column 0 for the same reason as the requires
# paragraph: a header reorder would make case_timeout read "3900 / IT_SETTLE:
# 3600 — …", return 1, and abort the WHOLE run with exit 2.) entrypoint.sh runs
# run_ruby_reconcile BEFORE the exec that hands PID 1 to the sandbox user (the
# same position case 630 and the 700-series document), and the `native` variant
# sets ruby=$IT_RUBY_VERSIONS (default 3.3.6,3.4.5 — TWO versions) via
# IT_VARIANT_OVERRIDES, which this case must NOT restate (lib.sh's
# launcher_conf folds it in automatically). This case never asserts anything
# about Ruby, but the reconcile still runs and still gates the pid-1 wait —
# there is no way to observe the six binaries without waiting behind it.
#
# GROUP: $IT_RUBY_GROUP, DELIBERATELY SHARED — not a case-private group. Cases
# 750/760 (packages tier, not this task) already rely on this same group and
# variant being warmed by whichever native-image case runs first; a rvm volume
# exists precisely to be reused, rvm-reconcile.sh is additive and idempotent,
# and this case writes nothing to $HOME/~/.rvm beyond what the reconcile itself
# does — its six probes are read-only `--version` execs against unrelated
# apt/GitHub-release binaries. run.sh executes cases in filename order, so 730
# is the FIRST native-variant case to reach this group and is the one that pays
# the cold bootstrap + two-version compile; 750/760 (which run later) then find
# it already warm. That is a real cost removed from the tier, not just a local
# optimisation: without sharing, 730 AND whichever of 750/760 runs first would
# each separately pay this same cold compile, three-for-three instead of once.
# IT_SETTLE/timeout below are UNCHANGED by this: this case may still be the one
# that pays the cold bootstrap (nothing guarantees another case warms the group
# first), so the ceiling must cover that case regardless of who benefits after.
# Sizing: verify-on-host.sh's Phase 3 established 1800s (90 x 20s polling) as
# headroom for ONE cold Ruby compile; this reconcile does TWO in one
# synchronous pass, so IT_SETTLE here doubles that proven single-version
# ceiling rather than reusing it as-is. This figure is reasoned from the
# product's own code and from verify-on-host.sh's precedent, not measured
# against this exact case: CI is first to prove it, the same as every number in
# the 700-series before its own baseline run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# See the header: launcher_up's own pid-1-handover wait is gated behind the
# WHOLE synchronous entrypoint sequence, dominated here by a cold, two-version
# rvm bootstrap+compile that this case does not otherwise care about — and
# which this case may or may not be the one paying, depending on run order.
IT_SETTLE=3600

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"
launcher_up restricted || it_finish

for b in psql mysql mongosh convert wkhtmltopdf gcc; do
  assert_runs "$IT_CID" "$b"
done

# The toolchain-restore layer's own fingerprint — see the header. A compiler on
# PATH does not imply this layer ran; this header does, because nothing else in
# the Dockerfile installs libyaml-dev.
if docker exec "$IT_CID" test -f /usr/include/yaml.h; then
  pass "libyaml-dev's header is present — KEEP_BUILD_TOOLCHAIN's restore layer ran"
else
  fail "libyaml-dev's header is MISSING — the toolchain restore layer did not run, so runtime native compilation (psych, pg, mysql2) will fail"
fi

it_finish
