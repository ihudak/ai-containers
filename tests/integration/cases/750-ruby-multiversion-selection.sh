#!/usr/bin/env bash
# summary:  every configured Ruby version is installed, and .ruby-version selects
#           a non-default one
# tags:     packages slow needs-multiruby
# requires: docker launcher netadmin multiruby
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
# requires: multiruby — with one version configured there is nothing to select
# between, and this case must SKIP BY NAME rather than pass against a
# one-element list. The nightly may drop to a single version on cost; see
# nightly.yml.
#
# The mechanism this case leans on — a LOGIN, non-interactive shell picking up
# a directory's .ruby-version — is asserted nowhere else in this repo
# (verify-on-host.sh never exercises it; link-default-ruby.sh's header only
# claims it in prose). Rather than trust that claim, it was reproduced live: a
# throwaway rvm bootstrapped into a scratch $HOME here, a `.ruby-version` file
# dropped into a test directory, and `bash -lc 'cd "$dir" && rvm current'` (no
# `-i`, matching agent_exec/docker-exec's shape exactly) DID select the
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
ruby_wait_ready "$IT_CID" 1800 || { it_diagnose "$IT_CID"; it_finish; }

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
installed="$(docker exec "$IT_CID" bash -lc 'rvm list strings 2>/dev/null' | tr -d '\r')"
IFS=',' read -r -a want <<< "$IT_RUBY_VERSIONS"
for v in ${want[@]+"${want[@]}"}; do
  if grep -q "ruby-$v" <<< "$installed"; then
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
other="${IT_RUBY_VERSIONS##*,}"
docker exec "$IT_CID" bash -c "mkdir -p /tmp/proj && printf '%s\n' '$other' > /tmp/proj/.ruby-version"
if out="$(docker exec "$IT_CID" bash -lc 'cd /tmp/proj && ruby -e "print RUBY_VERSION"' 2>&1)"; then
  if [[ "$out" == "$other" ]]; then
    pass ".ruby-version selects the non-default version ($other)"
  else
    fail ".ruby-version selected $out, expected $other"
  fi
else
  fail "ruby failed to run under .ruby-version: $out"
fi

it_finish
