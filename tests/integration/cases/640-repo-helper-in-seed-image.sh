#!/usr/bin/env bash
# summary:  the repo helper's own tests pass inside the seed image, on its git and its userland
# tags:     volumes fast
# requires: docker
#
# repo-git-reset.sh runs in production inside ai-containers-seed: Alpine, musl,
# its git (2.45 when this case was written) and busybox's grep and awk, as root.
# tests/test-repo-git-reset.sh runs it on the developer's host instead, with
# that host's git and GNU tools, so a construct the seed image reads otherwise
# passes the hermetic suite and fails where it matters. One did: a packed-refs
# check written as grep '^.\{4201\}' is an error under musl, whose regex allows
# no count past 255, and the check passed there in silence (bugs review REPO-10).
# That is mutation 640-packed-refs-grep-interval.
#
# So the same test file runs here, inside the image Dockerfile.seed builds, twice:
# as root, the helper's identity in production, and as an ordinary user, because
# the test's fail-closed find check needs one (root reads every directory).
#
# Not tagged needs-external, though building the image fetches alpine and its
# packages: that tag marks a case whose CONTAINER reaches the internet at run
# time, which this one never does, and the PR job excludes it. Every image
# variant's build fetches its packages the same way, untagged; an air-gapped
# host fails the build here as it fails every variant's.
#
# Built under a tag of its own, never ai-containers-seed: that one is the user's,
# reused by every project's repo.sh. Removing this tag at the end deletes the
# image only when no other tag holds it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

seed="ai-containers-it-seed"
ctx="$(it_scratch)"
out="$(docker build -q -t "$seed" -f "$IT_REPO_DIR/Dockerfile.seed" "$ctx" 2>&1)" \
  || { fail "the seed image did not build: $out"; it_finish; }

run_in_seed() {  # $1=root|user → the test's output; status is the test's
  local as="$1"
  docker run --rm --pull=never --label "$IT_LABEL" ${IT_SELINUX_OPT:+"$IT_SELINUX_OPT"} \
    -v "$IT_REPO_DIR:/src:ro" -e AS="$as" "$seed" sh -c '
      set -e
      if [ "$AS" = user ]; then
        adduser -D -u 1500 itest >/dev/null 2>&1
        exec su itest -s /bin/bash -c "git config --global user.email it@example.invalid && git config --global user.name it && bash /src/tests/test-repo-git-reset.sh"
      fi
      git config --global user.email it@example.invalid
      git config --global user.name it
      exec bash /src/tests/test-repo-git-reset.sh' 2>&1
}

for as in root user; do
  if out="$(run_in_seed "$as")" && grep -q 'all checks passed' <<<"$out"; then
    pass "the helper's tests pass in the seed image as $as ($(docker run --rm --pull=never "$seed" git --version))"
  else
    fail "the helper's tests failed in the seed image as $as"
    grep -E '^FAIL|ERROR|bad regex|command not found' <<<"$out" | head -20 | sed 's/^/     /'
  fi
done

docker rmi "$seed" >/dev/null 2>&1 || true
it_finish
