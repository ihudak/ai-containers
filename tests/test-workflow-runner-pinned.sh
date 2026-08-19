#!/usr/bin/env bash
# tests/test-workflow-runner-pinned.sh — every CI job names a PINNED runner.
#
# `runs-on: ubuntu-latest` is a LABEL, and GitHub re-points it at a new Ubuntu
# LTS on their schedule rather than ours. The distro is what pins the toolchain
# a job's verdict depends on: Ubuntu 24.04 freezes shellcheck at 0.9.0 and bash
# at 5.2 for the life of the release. So an unpinned runner is an unpinned
# toolchain underneath a BLOCKING merge gate — what passes can change with
# nobody having edited this repo, which is the class of drift this project keeps
# finding rather than a hypothetical.
#
# It is not hypothetical here either. `cd ""` is a silent no-op on bash 5.1 and
# 5.2 and an ERROR on 5.3 (measured; survivors.txt entry 7 records the three
# versions side by side), so a runner label rolled forward onto a bash-5.3 image
# changes what the falsify tier reports about tests/integration/mutate.sh. The
# repo already pins the one image whose bash version it cares about — the
# suite-floor container — and left the HOST unpinned under the same reasoning
# it applied there.
#
# The rule has exactly two legal shapes, and a job must be one of them:
#   runs-on: <pinned image>   it has a runner, and the image is named outright
#   uses: <workflow>          it is a reusable-workflow caller and has no runner
#
# Pinning costs maintenance: GitHub eventually retires an image label and CI
# breaks. That is the point. It breaks LOUDLY, at a named place, on a day
# somebody chose — rather than a gate quietly starting to mean something else.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_DIR="$REPO_DIR/.github/workflows"
# shellcheck source=lib-layer-checks.sh
source "$REPO_DIR/tests/lib-layer-checks.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

n_files=0 n_jobs=0
declare -a images=()

for wf in "$WF_DIR"/*.yml; do
  [[ -f "$wf" ]] || continue
  n_files=$((n_files + 1))
  rel=".github/workflows/$(basename "$wf")"

  jobs_out="$(wf_jobs "$wf")" || { fail "$rel: could not read its job list"; continue; }
  mapfile -t jobs <<< "$jobs_out"

  for job in "${jobs[@]}"; do
    [[ -n "$job" ]] || continue
    n_jobs=$((n_jobs + 1))
    runner="$(wf_job_key "$wf" "$job" runs-on 2>/dev/null)" || runner=""
    uses="$(wf_job_key "$wf" "$job" uses 2>/dev/null)" || uses=""

    if [[ -n "$runner" ]]; then
      case "$runner" in
        *'${{'*)
          # An expression is not readable from here, so it cannot be called
          # pinned. Said as its own outcome rather than folded into the
          # moving-label failure: the fix is different.
          fail "$rel: job '$job' takes its runner from an expression ($runner) — this guard cannot see whether it is pinned" ;;
        *-latest)
          fail "$rel: job '$job' runs on '$runner', a label GitHub moves — name the image (e.g. ubuntu-24.04)" ;;
        *)
          pass "$rel: job '$job' pins its runner ($runner)"
          images+=("$runner") ;;
      esac
    elif [[ -n "$uses" ]]; then
      pass "$rel: job '$job' calls a reusable workflow and has no runner of its own"
    else
      fail "$rel: job '$job' declares neither runs-on nor uses"
    fi
  done
done

# A guard that inspected nothing must not report success — the same rule the
# lint job applies to its own file list. A renamed directory or a glob that
# stops matching would otherwise turn this into a green no-op.
if [[ "$n_files" -ge 1 && "$n_jobs" -ge 1 ]]; then
  pass "inspected $n_jobs job(s) across $n_files workflow file(s)"
else
  fail "inspected $n_jobs job(s) across $n_files workflow file(s) — nothing was verified"
fi

# One image across the repo. Not tidiness: "CI passed" has to name ONE
# toolchain, and `suite` running a different Ubuntu from `falsify` would make
# the two sentences mean different things while reading the same. A second
# image is a legitimate thing to want one day; it should arrive as a deliberate
# edit here, beside the job that needs it, not by drift.
if [[ "${#images[@]}" -gt 0 ]]; then
  mapfile -t distinct < <(printf '%s\n' "${images[@]}" | sort -u)
  if [[ "${#distinct[@]}" -eq 1 ]]; then
    pass "every pinned job names the same image (${distinct[0]})"
  else
    fail "the pinned jobs name ${#distinct[@]} different images (${distinct[*]}) — CI no longer means one toolchain"
  fi
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
