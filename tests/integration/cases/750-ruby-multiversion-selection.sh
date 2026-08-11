#!/usr/bin/env bash
# summary:  every configured Ruby version is installed, and .ruby-version selects
#           a non-default one
# tags:     packages slow needs-multiruby needs-external
# requires: docker launcher netadmin multiruby external
# image:    native
# timeout:  3900
#
# netadmin: corrected from a draft that omitted it. launcher_up drives
# restricted mode, and entrypoint.sh's apply_restricted_firewall runs
# iptables/ipset under `set -euo pipefail` — without netadmin the container
# dies before PID 1 ever hands over, which would look exactly like a mount or
# rvm bug rather than the missing capability it actually is (case 730 sets the
# same precedent for the same reason).
#
# The `multiruby` entry in requires: above exists because with one version
# configured there is nothing to select between, and this case must SKIP BY
# NAME rather than pass against a one-element list. The nightly may drop to a
# single version on cost; see nightly.yml. (Reworded off a leading "requires:"
# so a future header reorder can't be misread as a second requires: line by
# anything less forgiving than case_meta's current head -1.)
#
# needs-external: this case's group can reach it cold (see the IT_SETTLE
# comment below), which means the same real rvm/rubygems/ruby-lang.org network
# calls case 730 makes for the same reason — the tag has to be here too, or
# `--tags packages --exclude needs-external` would drop 730 (which correctly
# carries the tag) while still admitting this case into a cold bootstrap,
# defeating the point of that exclusion.
#
# The external CAPABILITY (in the requires line above) is a second, separate
# thing from that tag, and was missing at first: the tag only lets a caller
# EXCLUDE this case, whereas every assertion below needs a Ruby downloaded and
# compiled at container start. On a host with no outbound HTTPS the reconcile
# logs FAILED: and exits 0, the container comes up, and this case reports three
# named failures about missing rubies as if the product were broken. With the
# capability it SKIPs by name instead. 730 correctly omits it — its six
# binaries are Dockerfile RUN-layer artifacts, unreachable by a dead network.
#
# The mechanism this case leans on — a LOGIN, non-interactive shell picking up
# a directory's .ruby-version — is asserted nowhere else in this repo
# (verify-on-host.sh never exercises it; link-default-ruby.sh's header only
# claims it in prose). Rather than trust that claim, it was reproduced live: a
# throwaway rvm bootstrapped into a scratch $HOME here, a `.ruby-version` file
# dropped into a test directory, and `bash -lc 'cd "$dir" && rvm current'` (no
# `-i`, matching agent_exec_login/docker-exec's shape exactly) DID select the
# version named in the file. The mechanism is rvm's `scripts/cd`: sourcing rvm
# — which happens on every login shell here via /etc/profile.d/rvm.sh, not
# something this case's own `-lc` invocation does itself — replaces the `cd`
# builtin with a function and registers it in `chpwd_functions`, so every `cd`
# (not just an interactive prompt's PROMPT_COMMAND) re-runs
# `__rvm_project_rvmrc` against the new directory. This is genuine
# confirmation of the selection MECHANISM, not of this exact case end-to-end
# (that still needs a real two-version compile only CI can pay for) — see the
# task report for the precise boundary of what was and was not verified.
#
# BOTH `rvm list strings` below and the `.ruby-version` probe run as the
# SANDBOX USER via agent_exec_login, never a bare `docker exec`. A bare
# `docker exec ... bash -lc` runs as ROOT, and root's $HOME (e.g. /root) has
# no .rvm — rvm lives in the sandbox user's $HOME/.rvm (rvm-reconcile.sh runs
# via `runuser -u "$sandbox_user"`, never as root) — so /etc/profile.d/rvm.sh's
# `[ -s "$HOME/.rvm/scripts/rvm" ]` guard is false for root and the rvm
# function is never even defined. That is CI's actual failure mode this case
# shipped with: `rvm list strings` returned empty (rvm: command not found,
# swallowed by `2>/dev/null`) and `.ruby-version` selection silently fell back
# to the already-linked default (ruby-3.3.6), which is why the case reported
# "selected 3.3.6, expected 3.4.5" — a wrong-USER bug, not a broken selection
# mechanism. Verified against link-default-ruby.sh and rvm-reconcile.sh (both
# run the reconcile/link steps against the sandbox user's home, never root's)
# before this fix, not assumed. See the task report for the full trace,
# including why case 760's own root-run `docker exec ... stat` does NOT share
# this bug: it stats an explicit absolute path
# ($IT_LAUNCH_HOME_IN/.rvm/rubies/...), which root can read regardless of
# ownership, and never invokes `rvm` or depends on $HOME resolving to
# anything — there is no user-identity-sensitive step in a bare `stat`.
#
# IT_SETTLE=3600 / timeout=3900: reused from case 730's precedent for
# $IT_RUBY_GROUP, and NOT weakened just because this case usually runs after
# 730 has already warmed it. Nothing guarantees that ordering: a filtered
# selection (e.g. `--exclude needs-external`, which drops 730 but not this
# case — 730 tags needs-external, this one does not) can reach this case with
# the group still cold, so the budget has to cover a genuine cold two-version
# bootstrap+compile on its own, the same as 730/740. Whichever case actually
# pays the cost, the ceiling must be sized for the one that does.
#
# ruby_wait_ready(1800) below is not a second additive risk period, for the
# same code-verified reason case 740's header gives in full: entrypoint.sh
# gates PID 1's handover on run_ruby_reconcile finishing, and rvm-reconcile.sh
# logs one of its two terminal lines ("done." or "FAILED:") on every exit path
# before that call returns — so by the time launcher_up succeeds, the line
# ruby_wait_ready polls for already exists, and it resolves on its first
# check. The 1800 ceiling only guards a `docker logs` visibility race, not an
# expected cost.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

IT_SETTLE=3600

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"
launcher_up restricted || it_finish

# Deliberately NOT `ruby_wait_ready ... || { it_diagnose "$IT_CID"; it_finish; }`
# the way 740/760 correctly do for their own single-assertion shape. This
# case's whole point is the version-presence loop and the .ruby-version
# selection check below — ending the case here on a readiness failure would
# report ONLY "the reconcile reported FAILED", with no indication of WHICH
# version is missing, even though the next lines exist to say exactly that.
# ruby_wait_ready already calls fail() on every one of its three failure
# paths (see lib.sh), so it_fails is already nonzero by the time this line
# returns and the case is already guaranteed to end non-zero at it_finish
# below — nothing here needs to fail() again on its behalf; just keep going.
#
# Safe to fall through unconditionally, for all three of ruby_wait_ready's
# failure paths: "the reconcile reported FAILED" (this case's own mutation
# demonstration — only the LAST configured version installs) leaves the
# container fully up, because a per-version FAILED: line does not stop
# rvm-reconcile.sh from reaching its own "done." and letting entrypoint.sh
# hand over to the agent shell (lib.sh's _it_ruby_reconcile_ok comment traces
# this). "container exited" and "timed out" leave a container that is not
# usably running, but every call below is a `docker exec`, which fails FAST
# against a dead or missing container rather than hanging — so this case
# degrades to clearly-labeled per-version failures instead of compounding
# into a stuck run.
#
# it_diagnose is deliberately NOT called here. it_cleanup already dumps it
# automatically, exactly once, for any case that ends with it_fails > 0
# (lib.sh:79, the EXIT trap) — calling it again here would duplicate several
# dozen lines of firewall/ipset/capture diagnostics that have nothing to do
# with Ruby, and interleave them BETWEEN this failure and the
# version-presence loop that follows, burying the one piece of information
# (which version is missing) this report exists to surface. The automatic
# dump still runs, once, at the very end.
ruby_wait_ready "$IT_CID" 1800

# ruby= is a comma-separated LIST precisely so a project can migrate between
# versions, and per-project selection comes from .ruby-version via a login
# shell. Installing only the default would satisfy every other Ruby case here.
#
# `IFS=',' read -r -a want <<< "$IT_RUBY_VERSIONS"` — both the herestring and
# `read -a` predate bash 3.2 by years (2.05b and 2.0 respectively), so the
# construct itself is not the risk. The array LOOP below is: this repo targets
# bash 3.2, where "${arr[@]}" on a zero-element array is an unset-parameter
# reference and aborts under `set -u` (fixed only in bash 4.4+; see lib.sh's
# own header and the identical guard throughout sandbox.sh/docker-shim.sh).
# $IT_RUBY_VERSIONS reaching this case at all requires run.sh to have exported
# it (fixed in this same change — it previously did not) AND the `multiruby`
# capability to have gated this case in, which together guarantee 2+ elements
# here in practice; the guarded expansion is defense in depth against a FUTURE
# regression in either of those, consistent with this codebase's existing
# convention, not evidence that an empty case was observed.
installed="$(agent_exec_login "$IT_CID" 'rvm list strings 2>/dev/null' | tr -d '\r')"
IFS=',' read -r -a want <<< "$IT_RUBY_VERSIONS"

# The multiruby gate implies 2+ elements; assert it explicitly rather than
# only inheriting it, so a gate regression fails LOUDLY here instead of this
# loop quietly running once (or zero times) and everything downstream still
# reporting green.
if [[ "${#want[@]}" -lt 2 ]]; then
  fail "IT_RUBY_VERSIONS has ${#want[@]} element(s) despite the multiruby gate — nothing to select between: [$IT_RUBY_VERSIONS]"
fi

for v in ${want[@]+"${want[@]}"}; do
  # -F: the version string is matched LITERALLY, its dots are not regex
  # wildcards. -x: whole-line, not substring. Both matter for the same reason
  # rvm-reconcile.sh:74-76 already grep this way — without them "ruby-3.4.5"
  # also matches "ruby-3.4.50", and a plain `grep -q` here would reproduce the
  # exact anti-pattern the product hardened against, on the line whose only
  # job is confirming which versions actually installed.
  if grep -Fqx "ruby-$v" <<< "$installed"; then
    pass "ruby-$v is installed"
  else
    fail "ruby-$v is installed — rvm list: $(tr '\n' ' ' <<< "$installed")"
  fi
done

# Selection: a NON-default version, chosen through .ruby-version the way a
# project does it.
#
# The LAST element, not the first — verified against rvm-reconcile.sh, not
# assumed (see case 740's header for the full trace): the default is the
# FIRST-listed version that installs (`set -- $present; rvm --default use
# "$1"`, iterating $RUBY_VERSIONS in the order sandbox.sh hands it down with
# no reordering). Picking the first element here — as an earlier draft of
# this case did, reasoning it was the non-default — would select the version
# ALREADY active by default, making the .ruby-version assertion below pass
# vacuously: it would prove nothing about .ruby-version actually switching
# anything, which is precisely the shape of defect this suite exists to
# eliminate.
# Written and read as the SAME user throughout (the sandbox uid, via
# agent_exec/agent_exec_login) rather than root-writes-then-agent-reads: it
# removes a second, unrelated variable (a permissions mismatch) from a case
# whose whole point is the .ruby-version SELECTION mechanism, not file
# ownership across users.
other="${IT_RUBY_VERSIONS##*,}"

# Gated on $other actually having installed (already known from the loop
# above via $installed) rather than run unconditionally. If $other never
# installed, `ruby -e ...` under /tmp/proj would either fail outright or
# silently fall back to whatever default IS present — either way the
# resulting failure would be ABOUT the missing install the loop above
# already reported, not about .ruby-version's selection mechanism, and
# running it anyway would only produce a second, confusing failure for the
# same root cause. Gating on presence, rather than skipping unconditionally
# whenever the reconcile failed at all, keeps this check live for the common
# partial-failure shape where the LAST version (the one this check targets)
# is exactly the one that DID install — this case's own mutation
# demonstration is that shape (only the last configured version installs).
#
# One known limitation, not solved here: if $other is the ONLY version that
# installed, it is also — by the same rvm-reconcile.sh default-setting logic
# cited above — the version rvm falls back to as the default, so a pass
# below does not distinguish "the .ruby-version mechanism worked" from
# "there was only one ruby to fall back to anyway". That is the same
# vacuous-pass risk the element-choice comment above already exists to avoid
# in the NORMAL case; here it can recur as a side effect of a partial
# reconcile failure. Accepted rather than special-cased further: the
# version-presence loop above is what actually catches a partial-failure
# defect, and already does so unambiguously.
if grep -Fqx "ruby-$other" <<< "$installed"; then
  agent_exec "$IT_CID" "mkdir -p /tmp/proj && printf '%s\n' '$other' > /tmp/proj/.ruby-version"
  if out="$(agent_exec_login "$IT_CID" 'cd /tmp/proj && ruby -e "print RUBY_VERSION"' 2>&1)"; then
    if [[ "$out" == "$other" ]]; then
      pass ".ruby-version selects the non-default version ($other)"
    else
      fail ".ruby-version selected $out, expected $other"
    fi
  else
    fail "ruby failed to run under .ruby-version: $out"
  fi
else
  printf 'NOTE: skipping the .ruby-version selection check — ruby-%s was never installed (see the version-presence loop above); the check would only restate that failure, not test selection\n' "$other"
fi

it_finish
