#!/usr/bin/env bash
# docker-shim.sh — a PASS-THROUGH `docker`, placed on PATH ahead of the real one
# while an integration case drives the REAL sandbox.sh.
#
# WHY THIS EXISTS
#
# sandbox.sh:937 runs `docker run -it --rm …`: foreground, interactive, with no
# --name and no label. There is nothing for a case to exec into and nothing for
# the runner to sweep afterwards. The alternative was a test-only detach knob
# inside a security-relevant launcher; this keeps sandbox.sh exactly as users
# run it and puts the seam in the harness instead.
#
# It is a pass-through, not the capturing fake used by the hermetic tests
# (tests/test-docs-path.sh &co): those assert the argument STRING, this one lets
# the real container start so a case can assert the EFFECT.
#
# WHAT IT CHANGES, and only on the container under test:
#   -it  →  -d -i        detached, so the case observes from outside
#   +    --name  $IT_LAUNCH_NAME
#   +    --label $IT_LABEL
# and it labels every `docker volume create` / `docker network create` so the
# runner's sweep can find volumes the launcher creates on its own (the rvm
# volume, a :rwcopy working copy) instead of leaking multi-GB debris.
#
# `-d -i`, NOT `-d -i -t`: verify-on-host.sh already starts this same image with
# `docker run -di --rm` and execs into it — on macOS + Colima and on Linux, for
# months. That is a proven invocation. `-dit` is not; nothing in this repo has
# ever run it, and a harness is the wrong place to find out.
#
# HOW THE CONTAINER UNDER TEST IS IDENTIFIED
#
# It is the ONLY `docker run` in the repository carrying `-it`. Verified across
# sandbox.sh, sandbox-common.sh, repo.sh, group.sh, entrypoint.sh and
# verify-on-host.sh: every other one is a `--rm --entrypoint` helper — the
# :rwcopy copy container, repo.sh's five seeding containers, the rvm migration.
# Matching on `-it` therefore cannot capture a helper by mistake, which a
# heuristic like "the last run wins" or "the one without --entrypoint" could.
#
# If someone later adds a second `docker run -it`, this shim will rename and
# detach THAT one too. The affected case then fails on a container that is not
# the sandbox — loudly, at the assertion — rather than quietly testing the wrong
# thing. tests/test-integration-lib.sh pins the single-`-it` premise so the
# breakage is reported at its cause instead.
set -u

real="${IT_REAL_DOCKER:-}"
if [[ -z "$real" ]]; then
  printf 'docker-shim: IT_REAL_DOCKER is unset — the harness must resolve the real docker before putting this on PATH\n' >&2
  exit 127
fi
if [[ ! -x "$real" ]]; then
  printf 'docker-shim: IT_REAL_DOCKER is not executable: %s\n' "$real" >&2
  exit 127
fi
# Self-reference would recurse until the process table gives out. Observed, not
# theorised: neutralising this condition during mutation testing (2026-08-09)
# hung tests/test-integration-shim.sh until it was killed — no error, no output,
# just a runner that never returns. Hence the check, and hence it exits 127
# rather than warning.
if [[ "$(basename "$real")" == "docker" && "$(dirname "$real")" == "$(cd "$(dirname "$0")" && pwd)" ]]; then
  printf 'docker-shim: IT_REAL_DOCKER points back at the shim: %s\n' "$real" >&2
  exit 127
fi

pre=()
[[ -n "${IT_LABEL:-}" ]] && pre+=(--label "$IT_LABEL")

case "${1:-}" in
  run)
    shift
    main=0
    for a in "$@"; do
      # -ti as well as -it: they are the same flag pair to docker, so a shim
      # that only knew one spelling would silently fall through to the
      # pass-through branch and start a FOREGROUND container the case then
      # waits on until its timeout — a hang, reported as a timeout, ten files
      # away from the one-character cause.
      if [[ "$a" == "-it" || "$a" == "-ti" ]]; then main=1; break; fi
    done
    if [[ "$main" -eq 1 ]]; then
      [[ -n "${IT_LAUNCH_NAME:-}" ]] && pre+=(--name "$IT_LAUNCH_NAME")
      args=()
      for a in "$@"; do
        if [[ "$a" == "-it" || "$a" == "-ti" ]]; then args+=(-d -i); else args+=("$a"); fi
      done
      exec "$real" run ${pre[@]+"${pre[@]}"} "${args[@]}"
    fi
    exec "$real" run ${pre[@]+"${pre[@]}"} "$@"
    ;;
  volume|network)
    if [[ "${2:-}" == "create" ]]; then
      sub="$1"; shift 2
      exec "$real" "$sub" create ${pre[@]+"${pre[@]}"} "$@"
    fi
    ;;
esac

exec "$real" "$@"
