#!/usr/bin/env bash
# shared-files.sh — the single list of engine files project-init.sh and
# sync-to-projects.sh copy into every project's .ai-containers/ working copy.
#
# SOURCED, never executed, by both scripts, so the two copy operations can
# never again diverge the way they already had, silently, before this file
# existed: sync-to-projects.sh copied group.sh (added when group.sh itself
# was introduced), project-init.sh did not, and nothing compared the two
# lists to notice — a freshly-initialised project had no group.sh until its
# first sync. Same failure mode as tests/test-bash-floor.sh's in_container
# list: a fact stated more than once eventually disagrees with itself.
#
# bash-floor.sh MUST be in this list: sandbox-common.sh (also in this list)
# unconditionally sources it, so a project copy missing bash-floor.sh fails
# on its very first `build.sh`/`sandbox.sh`/`repo.sh` invocation with
# ".../bash-floor.sh: No such file or directory".
#
# shared-files.sh itself must NOT be in this list: a project is a leaf that
# never runs project-init.sh/sync-to-projects.sh, so it never needs its own
# copy of the file that drives those copies.
#
# tests/test-shared-files-parity.sh pins both of those facts independently
# (hand-written, not derived from this array — see that file for why), and
# tests/test-sync-project.sh's expected_shared_files is the second,
# independent hand-written witness for the array's full contents.

if [[ -n "${_AI_CONTAINERS_SHARED_FILES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_AI_CONTAINERS_SHARED_FILES_SOURCED=1

# shellcheck disable=SC2034  # consumed by project-init.sh and sync-to-projects.sh, which source this file
AI_CONTAINERS_SHARED_FILES=(
  Dockerfile Dockerfile.seed .dockerignore
  bash-floor.sh sandbox-common.sh tools-lib.sh
  build.sh sandbox.sh repo.sh group.sh entrypoint.sh
  repo-git-reset.sh
  rvm-reconcile.sh link-default-ruby.sh
  agent-tools-reconcile.sh link-agent-tools.sh
  refresh-ipset-allowlist.sh capture-blocked-traffic.sh
  capture-agent-destinations.sh install-tools.sh install-agent-skills.sh
  extract-discovery.sh
)
