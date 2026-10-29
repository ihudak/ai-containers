#!/usr/bin/env bash
# install-node-lts.sh <nvm-installer>: nvm into $NVM_DIR, then the newest Node
# LTS as the default, at image build time (the Dockerfile's nvm layer).
#
# RETRIED, ON A CLEAN SLATE. nvm's install.sh clones nvm from github.com with no
# retry of its own, and GitHub answers an unauthenticated clone it is throttling
# with 401 (measured 2026-09-02: a whole build cycle failed on it); a half-made
# clone leaves $NVM_DIR/.git, which install.sh then takes for an installed nvm.
# So each attempt starts from an empty $NVM_DIR, and `nvm install --lts`, which
# downloads from nodejs.org, retries with it.
#
# THE RELEASE BEFORE IT WHEN THE NEWEST IS NOT PUBLISHED WHOLE YET. On the day a
# Node release becomes LTS, nodejs.org can list it before its checksums, and nvm
# then refuses the binary ("Provided checksum to compare to is empty."), tries a
# source build, and fails: on 2026-10-28 every build failed for over an hour
# (bugs review BLD-9). Once `nvm install --lts` has failed that way twice, the
# newest LTS release before it is installed instead, as the default, with a
# WARNING naming it: the same line's previous patch when there is one, else the
# previous line's newest (the agents need an LTS, not the newest one). Only on
# that message: any other failure, a mismatched checksum above all, is retried
# and then fails the build as before (review of BLD-9). Docker caches the layer,
# so only a `./build.sh --no-cache` picks the newest up later.
#
# Test knobs, not build arguments: AI_NODE_ATTEMPTS (5) and AI_NODE_SLEEP (15,
# the seconds of backoff per attempt number). tests/test-install-node-lts.sh.
set -uo pipefail

installer="${1:-}"
[[ -n "$installer" && -f "$installer" ]] || { printf 'usage: install-node-lts.sh <nvm-installer>\n' >&2; exit 2; }
: "${NVM_DIR:?NVM_DIR must be set}"
attempts="${AI_NODE_ATTEMPTS:-5}"
sleep_unit="${AI_NODE_SLEEP:-15}"
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=5
[[ "$sleep_unit" =~ ^[0-9]+$ ]] || sleep_unit=15
err="$(mktemp)" || { printf 'install-node-lts.sh: cannot make a temporary file\n' >&2; exit 1; }
trap 'rm -f "$err"' EXIT

nvm_run() { bash -c "source \"\$NVM_DIR/nvm.sh\" && $1"; }

# previous_lts: on stdin `nvm ls-remote --lts`; the newest LTS release other than
# the newest one, or nothing. The list is sorted here, by version: nvm's order is
# not relied on, and a plain sort put v6 above v24.
previous_lts() {
  local all=()
  mapfile -t all < <(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | uniq)
  (( ${#all[@]} >= 2 )) || return 0
  printf '%s' "${all[-2]}"
}

unpublished=0
for (( attempt = 1; attempt <= attempts; attempt++ )); do
  # Fatal here as it was under the RUN's -e: a slate that is not clean is no retry.
  rm -rf "$NVM_DIR" && mkdir -p "$NVM_DIR" || { printf 'install-node-lts.sh: cannot reset %s\n' "$NVM_DIR" >&2; exit 1; }
  if PROFILE=/dev/null bash "$installer"; then
    if nvm_run "nvm install --lts && nvm alias default 'lts/*'" 2>"$err"; then
      cat "$err" >&2
      exit 0
    fi
    cat "$err" >&2
    grep -q 'Provided checksum to compare to is empty' "$err" && unpublished=$(( unpublished + 1 ))
    if (( unpublished >= 2 )); then
      prev="$(nvm_run 'nvm ls-remote --lts --no-colors' 2>/dev/null | previous_lts)" || prev=""
      if [[ -n "$prev" ]] && nvm_run "nvm install '$prev' && nvm alias default '$prev'"; then
        printf 'WARNING: the newest Node LTS is listed but its checksums are not published yet, so the default node is %s, the LTS release before it. `./build.sh --no-cache` later picks up the newest: a plain build reuses this layer.\n' "$prev" >&2
        exit 0
      fi
    fi
  fi
  if (( attempt == attempts )); then
    printf 'nvm bootstrap failed after %s attempts\n' "$attempts" >&2
    exit 1
  fi
  sleep $(( attempt * sleep_unit ))
done
