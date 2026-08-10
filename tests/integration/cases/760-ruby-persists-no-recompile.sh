#!/usr/bin/env bash
# summary:  a second launch in the same group reuses the compiled rubies instead
#           of recompiling
# tags:     packages slow
# requires: docker launcher netadmin
# image:    native
# timeout:  7600
#
# netadmin: corrected from a draft that omitted it. Both launches below drive
# restricted mode, and entrypoint.sh's apply_restricted_firewall runs
# iptables/ipset under `set -euo pipefail` — without netadmin the container
# dies before PID 1 ever hands over, which would look exactly like a broken
# rvm volume rather than the missing capability it actually is (case 730 sets
# the same precedent for the same reason).
#
# IT_SETTLE=3600 / timeout=7600: TWO launcher_up calls, each its own
# cold-two-version-compile ceiling (the same 3600 case 730/740/750 already
# establish, for the same reason — nothing guarantees $IT_RUBY_GROUP is warm
# when this case reaches it; see 750's header). The two ceilings are summed
# deliberately, mirroring case 710's own compound-launcher reasoning for its
# structurally identical two-phase shape (fresh-install-then-reuse), NOT
# treated as free because "the second one should be fast": launch2's own
# IT_SETTLE ceiling is the thing that must stay near-full-sized specifically
# BECAUSE this case exists to catch launch2 needing a full recompile — that
# IS the bug. If reuse is genuinely broken, launch2 pays the same cold cost
# launch1 did, and the case must still reach its own named fail() rather than
# be killed ambiguously by the outer timeout mid-recompile (case 700's header
# names this exact failure mode: a named assertion downgraded into an
# ambiguous "timed out after Ns").
#
# Unlike case 710's redundant `command -v claude` wait, though, NEITHER
# ruby_wait_ready call here is a comparable third/fourth independent risk:
# see case 740's header for the code-verified reason (rvm-reconcile.sh logs a
# terminal "done."/"FAILED:" line on every exit path, and PID 1 cannot hand
# over before that line exists) — both ruby_wait_ready calls resolve on their
# first poll once their own launcher_up has already returned success, success
# or failure alike. Their 1800/300 ceilings are `docker logs` visibility
# safety nets, not expected costs, which is why they are not ALSO summed at
# full value here.
#
# Sum: 3600 (launch1, cold) + 3600 (launch2, "only near ceiling if reuse is
# genuinely broken") + ~40s (two near-instant ruby_wait_ready confirmations,
# the docker rm) + ~20s (log grep + final assert_runs) ≈ 7260s. 7600 leaves
# ~340s of margin over that — the same flat-margin sizing 730 uses, scaled to
# a two-launch case. This is reasoned from the product's own code, the same
# as every number in the 700-series before its own baseline run: CI is first
# to prove it, and this is by far the most expensive number in the corpus,
# because it is the only case that can legitimately need TWO full cold
# compiles to reach a clean diagnosis of the bug it exists to catch.
#
# Two launches of its own, so the case is self-contained and order-independent:
# whether another case already warmed IT_RUBY_GROUP changes the wall-clock, not
# the assertion.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

IT_SETTLE=3600

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"

launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 1800 || { it_diagnose "$IT_CID"; it_finish; }
first="$IT_CID"
docker rm -f "$first" >/dev/null 2>&1 || true

launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 300 \
  || { fail "the second launch did not settle within 300s — it is recompiling"; it_diagnose "$IT_CID"; it_finish; }

# rvm prints its install banner only when it actually installs. Its absence is
# the evidence; asserting on elapsed time would be a flaky proxy for it.
# "Installing Ruby from source to: ..." is verified against rvm's own upstream
# source (scripts/functions/manage/base_install, via rvm_log — plain stdout,
# gated only on rvm_quiet_flag, which nothing here sets), not assumed: it is
# the message __rvm_install_source prints immediately before compiling, and
# base_install is the generic MRI install path `rvm install <version>` takes
# (confirmed by reading rvm/rvm's scripts/functions/manage/base, which sources
# base_install and is what every plain `ruby-x.y.z` install goes through).
# rvm-reconcile.sh does not redirect rvm's output, and entrypoint.sh runs the
# whole reconcile synchronously with no redirection either (same reasoning
# case 710 verified for agent-tools-reconcile.sh's npm output) — so this
# reaches the container's own stdout, which `docker logs` captures. The bare
# `rvm install` alternative is a secondary, harmless net: it appears in rvm's
# OWN "not installed, run this" advice (scripts/functions/selector), which
# fires only when `rvm use` is asked for a version that genuinely is not
# present — never on the warm/already-installed path this second launch is
# expected to take — so it adds no false-positive risk on a correct run.
if docker logs "$IT_CID" 2>&1 | grep -qE 'Installing Ruby from source|rvm install'; then
  fail "the second launch RECOMPILED — the group's rvm volume was not reused"
  docker logs "$IT_CID" 2>&1 | grep -iE 'rvm-reconcile|Installing Ruby' | tail -10 | sed 's/^/     /'
else
  pass "the second launch reused the group's compiled rubies"
fi
assert_runs "$IT_CID" ruby

it_finish
