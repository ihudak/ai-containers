#!/usr/bin/env bash
# docker-shim.sh — a PASS-THROUGH `docker`, placed on PATH ahead of the real one
# while an integration case drives the REAL sandbox.sh.
#
# WHY THIS EXISTS
#
# The launcher's sandbox.sh: `docker run -it --rm` is foreground, interactive, with no
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
#   any --name the launcher itself passed → stripped, then
#   +    --name  $IT_LAUNCH_NAME
#   +    --label $IT_LABEL
#
# sandbox.sh now passes its own --name (a legible default, or CONTAINER_NAME).
# Docker's flag parsing takes the LAST --name when a command line carries two,
# so simply appending ours after the launcher's own would make ordering alone
# decide which one wins — implicit, and one launcher-side arg reorder away
# from silently breaking again. Stripping the launcher's --name outright
# leaves no ambiguity: there is only ever one --name by the time docker runs.
# A run that mounts a launcher verify directory (/run/ai-launcher) is also held
# until the entrypoint has handed over, so sandbox.sh cannot remove that
# directory while the entrypoint is reading it (see the wait below).
#
# And it labels every `docker volume create` / `docker network create` so the
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
      skip_next=0
      verify=0
      for a in "$@"; do
        if [[ "$skip_next" -eq 1 ]]; then skip_next=0; continue; fi
        if [[ "$a" == "--name" ]]; then skip_next=1; continue; fi
        [[ "$a" == *:/run/ai-launcher || "$a" == *:/run/ai-launcher:* ]] && verify=1
        if [[ "$a" == "-it" || "$a" == "-ti" ]]; then args+=(-d -i); else args+=("$a"); fi
      done
      # Nothing to wait for: exec, as before. With the self-reference guard
      # above mutated, a child call here recurses into a chain of shims that
      # outlives p_timeout's kill of the first (the oracle hung past 120 s,
      # measured); exec loops in one process, which it can kill.
      if [[ "$verify" -eq 0 || -z "${IT_LAUNCH_NAME:-}" ]]; then
        exec "$real" run ${pre[@]+"${pre[@]}"} "${args[@]}"
      fi
      "$real" run ${pre[@]+"${pre[@]}"} "${args[@]}"
      rc=$?
      # Detached, sandbox.sh exits as soon as this returns, and its EXIT trap
      # removes the verify directory the container mounts at /run/ai-launcher.
      # In the foreground that happens after the container is gone; here it
      # landed while the entrypoint was between `-f manifest` and reading it,
      # and under set -e the entrypoint died: "launcher_up(open): entrypoint
      # never handed over", with --rm erasing the one line that said why
      # (/run/ai-launcher/manifest: No such file or directory). So a run that
      # mounts one returns only once PID 1 has left root — the entrypoint reads
      # the manifest as root, before anything else — or the container has
      # stopped, or IT_SETTLE has passed.
      if [[ "$rc" -eq 0 ]]; then
        deadline=$(( SECONDS + ${IT_SETTLE:-60} ))
        while (( SECONDS < deadline )); do
          [[ "$("$real" inspect -f '{{.State.Running}}' "$IT_LAUNCH_NAME" 2>/dev/null)" == true ]] || break
          uid="$("$real" exec "$IT_LAUNCH_NAME" awk '/^Uid:/{print $2; exit}' /proc/1/status 2>/dev/null | tr -dc '0-9')"
          [[ -n "$uid" && "$uid" != 0 ]] && break
          sleep 0.2
        done
      fi
      exit "$rc"
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
