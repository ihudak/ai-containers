#!/usr/bin/env bash
# summary:  rvm bootstraps and compiles behind the restricted firewall, and the
#           default Ruby's binstubs EXECUTE in a non-login shell
# tags:     packages security slow needs-external
# requires: docker netadmin launcher
# image:    native
# timeout:  3900
#
# IT_SETTLE=3600 / timeout=3900: the SAME cold two-version-compile precedent
# case 730 already established for $IT_RUBY_GROUP, reused verbatim here on
# purpose. This case's group ("itruby-cold-$$", see below) is guaranteed cold
# on EVERY run — unlike 730/750/760 it never gets to benefit from another case
# having warmed it first — so it always pays the full cost 730's own header
# sized IT_SETTLE for: entrypoint.sh runs run_ruby_reconcile BEFORE the exec
# that hands PID 1 to the sandbox user, and the native variant's
# ruby=$IT_RUBY_VERSIONS (default 3.3.6,3.4.5) means a cold rvm bootstrap plus
# TWO from-source compiles must finish before launcher_up's own pid-1-handover
# wait can succeed.
#
# The ruby_wait_ready(1800) call below is NOT a second independent risk period
# stacked on top of IT_SETTLE, unlike case 700's redundant `command -v claude`
# wait (which genuinely can burn its own full ceiling — a specific tool can
# stay missing forever after the reconcile ends, and a plain PATH probe has no
# way to tell "still pending" from "permanently decided"). ruby_wait_ready is
# built differently (lib.sh's _ruby_reconcile_done/_ruby_reconcile_ok): it
# polls for rvm-reconcile.sh's own TERMINAL log lines ("done." or a "FAILED:"
# line), and rvm-reconcile.sh (verified by reading it, not assumed) logs one
# of those two on EVERY exit path before returning — the early bootstrap
# failures included. Since entrypoint.sh's run_ruby_reconcile call is fully
# synchronous, PID 1 cannot hand over to the sandbox user (which is what
# launcher_up's own wait is gated on) until one of those lines already exists
# in `docker logs`. So the instant launcher_up returns success, ruby_wait_ready
# finds its answer on its FIRST poll — success or FAILED, either way — not
# after up to 1800 more seconds. The 1800 ceiling is a defensive bound for a
# `docker logs` visibility race, not a cost this case expects to actually pay;
# it sits comfortably inside the existing 300s margin over IT_SETTLE, the same
# margin 730 already carries with no second wait at all.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

IT_SETTLE=3600

fixture_scope_init || it_finish
# Its OWN group, not $IT_RUBY_GROUP: bootstrapping from cold is the property
# under test here, and a warm shared volume (as 750/760 deliberately use) would
# make this case assert nothing. "$$" keeps it unique per run.sh invocation so
# a re-run never finds this group pre-warmed by a previous CI attempt either.
export AI_CONTAINER_GROUP="itruby-cold-$$"
launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 1800 || { it_diagnose "$IT_CID"; it_finish; }

# link-default-ruby.sh's contract, verbatim: ruby/gem/bundle/rake/irb onto
# /usr/local/bin so a NON-login shell resolves them. `bundler` is deliberately
# absent from this list — it is not in that set, and requiring it would report
# a bug against a contract nothing makes. `bundle` executing is a separate
# assertion from `bundle` resolving: rvm rewrites gem binstub shebangs to
# `#!/usr/bin/env ruby_executable_hooks`, so a correctly-linked `bundle` can
# still die on exec — assert_runs (lib.sh) checks both and distinguishes them
# in its failure output.
for b in ruby gem bundle rake irb; do
  assert_runs "$IT_CID" "$b"
done

# The configured default must be the version that is actually installed. A
# reconcile that fails partway must never point the default at a missing
# version — rvm-reconcile.sh logs FAILED: ruby-<v> instead and only sets the
# default to a version confirmed present.
#
# The FIRST element, not the last — verified against rvm-reconcile.sh, not
# assumed: it iterates $RUBY_VERSIONS in the order sandbox.sh hands it down
# (versions_to_space is a bare `tr ',' ' '`, no reordering) and sets the
# default to `$1` after `set -- $present`, i.e. the first-listed version that
# actually installed. link-default-ruby.sh's own fallback comment says the
# same thing independently ("matches the default rvm-reconcile.sh selects —
# first present version, in requested order"). Getting this backwards
# (`##*,`, the LAST element) would make this assertion fail on every run
# regardless of whether the product works correctly.
want="${IT_RUBY_VERSIONS%%,*}"
if out="$(docker exec "$IT_CID" bash -c 'ruby -e "print RUBY_VERSION"' 2>&1)"; then
  if [[ "$out" == "$want" ]]; then
    pass "the default ruby is the configured default ($want)"
  else
    fail "the default ruby is $out, expected $want"
  fi
else
  fail "ruby could not report its version: $out"
fi

it_finish
