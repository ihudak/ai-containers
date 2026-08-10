#!/usr/bin/env bash
# summary:  the group's rvm home is a named volume the agent can actually write to
# tags:     volumes slow
# requires: docker launcher
#
# Two claims, one container.
#
# 1. ~/.rvm is a NAMED VOLUME, on every platform. Not a preference: rvm
#    bootstraps by extracting its release tarball, and GNU tar defers symlinks
#    whose target contains '..' by first writing a mode-000 placeholder — an
#    operation macOS virtiofs cannot service, so tar fails on exactly the four
#    such members and the install aborts with "Could not extract RVM sources".
#    A bind-mounted ~/.rvm can therefore never hold a working rvm on macOS. The
#    tempting "simplification" is a Linux-only bind mount, which works fine on
#    the machine of whoever writes it — this asserts the mount TYPE for that
#    reason.
#
# 2. The agent can write there. A fresh docker volume mounts ROOT-OWNED: docker
#    only copies ownership from the image for a path the image already contains,
#    and /home/<user> is created at runtime.
#
#    THE EFFECT HAS TWO PROVIDERS, which a mutation run established rather than
#    reasoning. Disabling chown_rvm_root alone changed nothing — the case still
#    passed — because setup_sandbox_user's `find "$home_dir" -xdev -exec chown`
#    also reaches this directory: -xdev stops find DESCENDING into another
#    filesystem, but the mount point itself is still visited and chowned. So on
#    Linux + Docker, chown_rvm_root is currently redundant.
#
#    It is kept, and this case asserts the EFFECT rather than either mechanism,
#    which is the right shape for a claim two things provide: it fails when the
#    agent cannot write, whichever provider was lost. The known-bad patch removes
#    both, because a mutation that leaves a second provider standing
#    demonstrates nothing.
#
# WHY THIS DOES NOT DEPEND ON RVM INSTALLING ANYTHING. RUBY_VERSIONS is set to a
# version that cannot exist, so rvm-reconcile.sh bootstraps, fails that install
# fast and logs FAILED — deliberately. The mount and the chown both happen
# before any of it (entrypoint.sh calls chown_rvm_root, then run_ruby_reconcile),
# and the case asserts only those. Compiling a real Ruby would add minutes and
# assert nothing extra. It is `slow` anyway because the bootstrap still runs, and
# offline it runs through its retry path first.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# The pid-1 handover waits behind the whole reconcile, which the 60s network
# floor was never sized for. Raised here rather than globally: no other case
# pays this.
IT_SETTLE=300

fixture_scope_init || it_finish
# Any non-empty ruby list turns the volume and the chown on; 9.9.9 guarantees
# the install itself fails instead of compiling for minutes.
launcher_conf ruby=9.9.9 || it_finish

export AI_CONTAINER_GROUP=rubygrp
launcher_up open || it_finish

vol="it-$IT_RUN_ID-rvm-rubygrp"
assert_volume_exists "$vol"

# The mount must be a volume, not a bind — claim 1.
mtype="$(docker inspect -f \
  "{{range .Mounts}}{{if eq .Destination \"$IT_LAUNCH_HOME_IN/.rvm\"}}{{.Type}}{{end}}{{end}}" \
  "$IT_CID" 2>/dev/null)"
if [[ "$mtype" == "volume" ]]; then
  pass "~/.rvm is mounted as a named volume"
else
  fail "~/.rvm is mounted as a named volume — got '${mtype:-<no such mount>}'"
  docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' \
    "$IT_CID" 2>&1 | sed 's/^/     /'
fi

# Claim 2 — the one chown_rvm_root exists for.
assert_writable "$IT_CID" "$IT_LAUNCH_HOME_IN/.rvm"

# And the mount root belongs to the agent, which is what the chown actually did.
owner="$(docker exec "$IT_CID" stat -c '%u' "$IT_LAUNCH_HOME_IN/.rvm" 2>/dev/null)"
if [[ "$owner" == "$IT_LAUNCH_UID" ]]; then
  pass "the rvm mount root belongs to the agent ($IT_LAUNCH_UID)"
else
  fail "the rvm mount root belongs to the agent ($IT_LAUNCH_UID) — owned by uid '${owner:-?}'"
fi

it_finish
