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
# gcc is in the list because KEEP_BUILD_TOOLCHAIN=1 is what keeps it
# (sandbox-common.sh: db-clients and ruby both set it), and native extensions —
# the pg/mysql2 gems, Python source wheels — compile at container RUNTIME, not
# at image build time. If the Dockerfile ever stripped the toolchain again
# despite the flag, every gem with a C extension would break at container start
# and nothing else in this corpus would notice; db-clients/imagemagick/
# wkhtmltopdf are otherwise unrelated to gcc.
#
# All six answer --version cleanly. Verified against verify-on-host.sh's own
# Phase 2, which runs the identical `"$c" --version 2>&1` probe over the
# identical list (psql mysql mongosh convert wkhtmltopdf gcc) and has reported
# real version strings in past runs. CHANGELOG.md's Phase-2 fix was about
# capturing the WRONG process's exit status (`head`'s, not the tool's) — never
# about any of the six not supporting the flag. assert_runs is used unmodified.
#
# requires: docker launcher netadmin — and deliberately NOT external, checked
# rather than assumed. psql/mysql/mongosh/convert/wkhtmltopdf/gcc are every one
# of them installed by a Dockerfile RUN layer (DB_CLIENTS, INSTALL_IMAGEMAGICK,
# INSTALL_WKHTMLTOPDF, KEEP_BUILD_TOOLCHAIN) at IMAGE BUILD time, so this case's
# own assertions never touch the network at container run time. netadmin IS
# required: launcher_up drives restricted mode, entrypoint.sh's
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
# timeout: 3900 / IT_SETTLE: 3600 — the real cost this case pays, and it has
# NOTHING to do with the six binaries above. entrypoint.sh runs
# run_ruby_reconcile BEFORE the exec that hands PID 1 to the sandbox user (the
# same position case 630 and the 700-series document), and the `native` variant
# sets ruby=$IT_RUBY_VERSIONS (default 3.3.6,3.4.5 — TWO versions) via
# IT_VARIANT_OVERRIDES, which this case must NOT restate (lib.sh's
# launcher_conf folds it in automatically). Group `nativetools` is unique to
# this case — nothing else in a run warms it — so rvm-reconcile.sh bootstraps
# rvm from cold AND compiles BOTH Ruby versions from source, in sequence,
# synchronously, before launcher_up's pid-1 wait can ever succeed, even though
# nothing this case asserts is about Ruby. It is not skippable by overriding
# ruby= away from the variant's value: that would exercise a synthetic config
# nobody ships, exactly the per-component-image gap run.sh's own variant
# comment says a single simplified image would leave uncovered. Sizing:
# verify-on-host.sh's Phase 3 established 1800s (90 x 20s polling) as headroom
# for ONE cold Ruby compile; this reconcile does TWO in one synchronous pass, so
# IT_SETTLE here doubles that proven single-version ceiling rather than reusing
# it as-is. If the machine has no internet, rvm-reconcile.sh's own
# bootstrap-download guard fails FAST and non-fatally (a few seconds, `exit 0`)
# instead of hanging, so a network-less machine finishes this case QUICKER, not
# slower or falsely failing — the six assertions below never depend on Ruby
# succeeding. This figure is reasoned from the product's own code and from
# verify-on-host.sh's precedent, not measured against this exact case: CI is
# first to prove it, the same as every number in the 700-series before its own
# baseline run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# See the header: launcher_up's own pid-1-handover wait is gated behind the
# WHOLE synchronous entrypoint sequence, dominated here by a cold, two-version
# rvm bootstrap+compile that this case does not otherwise care about.
IT_SETTLE=3600

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=nativetools
launcher_up restricted || it_finish

for b in psql mysql mongosh convert wkhtmltopdf gcc; do
  assert_runs "$IT_CID" "$b"
done

it_finish
