#!/usr/bin/env bash
# summary:  a second launch in the same group reuses the compiled rubies instead
#           of recompiling
# tags:     packages slow needs-external
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
# needs-external: like 750, $IT_RUBY_GROUP can reach this case cold (nothing
# guarantees 730 warmed it first — see the IT_SETTLE reasoning below), which
# means launch1 can make the same real rvm/rubygems/ruby-lang.org calls 730
# makes. Without the tag, `--tags packages --exclude needs-external` would
# drop 730 but still admit this case into a cold bootstrap — the opposite of
# what that exclusion means to do.
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
# two near-instant mtime probes, the docker rm) + ~10s (final assert_runs)
# ≈ 7250s. 7600 leaves
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

# The evidence is the compiled ruby BINARY'S MTIME, not a log grep — this
# case shipped first with a log grep for 'Installing Ruby from source|rvm
# install', dropped on review. The mechanism trace behind that grep was
# correct as far as it went (rvm_log is an unredirected printf, and
# entrypoint.sh runs the reconcile with no redirection either, so the text
# does reach `docker logs`) but incomplete: `rvm install <v>` HEAD-probes
# THREE precompiled-binary mirrors before falling through to
# __rvm_install_source's "Installing Ruby from source" — and if a mirror ever
# served a binary, a genuine reinstall would print NEITHER pattern, and this
# case would report a false "reused". allowlist-domains.d/rvm.txt already
# allowlists (and documents) all three mirrors — rvm-io.global.ssl.fastly.net
# (both spellings), rubies.travis-ci.org, repo1.maven.org — and explains
# exactly why the probe reliably 404s anyway for the CRuby versions this repo
# installs (repo1.maven.org's path is JRuby's; the other two are legacy and
# defunct), which is a real, environment-specific reason the grep would have
# stayed correct here — but it is still a second file's behavior this case
# would have depended on without saying so, and it stops being true the
# moment a mirror starts serving a matching binary or IT_RUBY_VERSIONS names
# a version one of them actually has. The mtime of
# ~/.rvm/rubies/ruby-<default>/bin/ruby is insensitive to which path rvm
# takes to get there: reused means UNCHANGED, recompiled (source OR binary)
# means REWRITTEN, and the file is on the same persistent group volume across
# both launches (docker rm -f only removes the CONTAINER between them).
# $IT_LAUNCH_HOME_IN comes from lib.sh, so this block has to sit after the
# source line above, not before it.
default="${IT_RUBY_VERSIONS%%,*}"
ruby_bin="$IT_LAUNCH_HOME_IN/.rvm/rubies/ruby-$default/bin/ruby"
mtime_of() { docker exec "$1" bash -c "stat -c %Y '$ruby_bin' 2>/dev/null"; }

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"

launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 1800 || { it_diagnose "$IT_CID"; it_finish; }
first_mtime="$(mtime_of "$IT_CID")"
if [[ -z "$first_mtime" ]]; then
  fail "the compiled ruby binary is missing after the first launch: $ruby_bin"
  it_diagnose "$IT_CID"
  it_finish
fi
first="$IT_CID"
docker rm -f "$first" >/dev/null 2>&1 || true

launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 300 \
  || { fail "the second launch did not settle within 300s — it is recompiling"; it_diagnose "$IT_CID"; it_finish; }

second_mtime="$(mtime_of "$IT_CID")"
if [[ -z "$second_mtime" ]]; then
  fail "the compiled ruby binary is missing after the second launch: $ruby_bin"
  it_diagnose "$IT_CID"
elif [[ "$second_mtime" == "$first_mtime" ]]; then
  pass "the second launch reused the group's compiled ruby-$default (mtime unchanged: $first_mtime)"
else
  fail "the second launch RECOMPILED ruby-$default — the group's rvm volume was not reused (mtime $first_mtime -> $second_mtime)"
  docker logs "$IT_CID" 2>&1 | grep -iE 'rvm-reconcile|Installing Ruby' | tail -10 | sed 's/^/     /'
fi
assert_runs "$IT_CID" ruby

it_finish
