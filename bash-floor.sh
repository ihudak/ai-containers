#!/usr/bin/env bash
# bash-floor.sh — the single declaration of this project's minimum bash version.
#
# SOURCED, never executed. Every host entry point sources this (directly, or via
# sandbox-common.sh) so an unsupported bash produces one clear message instead of
# a cryptic `local: -A: invalid option` somewhere in the middle of a run.
#
# 5.1 rather than the 4.3 this guard enforced before increment 4: macOS needs a
# Homebrew bash at ANY floor above 3.2, so the raise costs macOS users nothing,
# and every current Linux target clears it (Ubuntu 22.04+, Debian 11+,
# RHEL/Rocky 9+, and the container base ubuntu:24.04 at 5.2.21). The only
# realistic exclusion is a RHEL 8 workstation, and only for host scripts.
#
# THE FLOOR IS DECLARED HERE AND NOWHERE ELSE. tests/test-bash-floor.sh fails if
# a second definition appears; tests/bash-dialect-lint.sh reads these values to
# decide which constructs are permitted.

if [[ -n "${_AI_CONTAINERS_BASH_FLOOR_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_AI_CONTAINERS_BASH_FLOOR_SOURCED=1

AI_CONTAINERS_BASH_FLOOR_MAJOR=5
AI_CONTAINERS_BASH_FLOOR_MINOR=1

if (( BASH_VERSINFO[0] < AI_CONTAINERS_BASH_FLOOR_MAJOR \
   || (BASH_VERSINFO[0] == AI_CONTAINERS_BASH_FLOOR_MAJOR \
       && BASH_VERSINFO[1] < AI_CONTAINERS_BASH_FLOOR_MINOR) )); then
  echo "ERROR: bash >= ${AI_CONTAINERS_BASH_FLOOR_MAJOR}.${AI_CONTAINERS_BASH_FLOOR_MINOR} is required (running ${BASH_VERSION:-unknown})." >&2
  echo "       On macOS: brew install bash, then run the scripts with the newer bash." >&2
  exit 1
fi
