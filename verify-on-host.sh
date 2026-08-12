#!/usr/bin/env bash
# verify-on-host.sh — run the checks that CANNOT run inside a sandbox container
# (they need a real Docker daemon).
#
# PLATFORM-ADAPTIVE HOST ENTRY POINT, not a macOS one. "Host" means "a machine
# with a real Docker daemon", as opposed to inside the dev container. The same
# command runs on macOS + Colima and on a Linux workstation with native Docker;
# the only platform-specific part is the preflight hints below. There is
# deliberately no verify-on-linux-host.sh — a second entry point would
# reintroduce, at the wrapper level, the duplication this delegation removes.
#
#   cd ~/dev/ai-tools/ai-containers            # upstream: engine at the repo root
#   cd ~/dev/dt-utils/mgd-ai-containers/base   # mgd: engine in base/, tests one up
#   bash ./verify-on-host.sh 2>&1 | tee ./ai-containers-host-verify.log
#
# One copy serves both layouts (see TESTS_DIR below). Then paste the log back.
#
#   IT_EXTRA_ARGS='--tags fast' PHASES=4 bash ./verify-on-host.sh
#                                              # extra flags for Phase 4's runner
#   PHASES="5 7" bash ./verify-on-host.sh     # skip the phases that need Docker
#
# IT_EXTRA_ARGS is forwarded verbatim to tests/integration/run.sh in Phase 4, on
# top of the --require security this script always passes. Phase 4 deliberately
# runs the WHOLE corpus by default (a human running locally wants full coverage,
# including the slow and needs-dns tiers CI excludes on cost), so this is the
# hook for narrowing that when iterating — e.g. --tags fast, or -v.
#
# Phases (each independent; a later phase still runs if an earlier one fails).
# Numbers are IDENTIFIERS, not execution order — the script actually runs them
# 0, 5, 7, 4: cheap checks first, the Docker-hungry corpus last.
#   0  environment sanity (daemon reachable, buildx, disk; Colima status on macOS)
#   5  the hermetic suite (tests/run-all.sh) + the sandbox.conf schema gate — and
#      the same suite again inside a container pinned to the declared bash floor.
#      Mirrors tests.yml's `suite` + `suite-floor` jobs.
#   7  lint: bash -n over every tracked script, the bash-dialect floor check, and
#      a shellcheck run. Mirrors tests.yml's `lint` job — same commands, same gate.
#   4  the runtime integration corpus — delegated in full to
#      tests/integration/run.sh. No test logic lives here.
#
# This script was a SUBSET of the PR gate before phases 5 and 7 existed: it ran
# the integration corpus and nothing else, so a developer verifying locally
# checked LESS than CI would before ever pushing. Local now covers everything CI
# does — that is the point of this file existing at all.
#
# EXIT STATUS: 0 only if every selected phase passed. A phase that fails does not
# stop the others — each is independent and a full report is worth more than an
# early abort — but every failure is recorded and reprinted in a summary at the
# end, and the script exits 1.
#
# That is a correction, not a feature. This script was born (08ea799) as a
# human-read DIAGNOSTIC: something you run, read, and paste back. Increment 1
# then wired it into nightly CI as a GATE. A report says what it saw; a gate has
# to be able to say no. The conversion was never made, so `PHASES="1 2 3" bash
# ./verify-on-host.sh` printed "BUILD FAILED" and exited 0 — the packages job in
# both repos passed unconditionally and could not have done otherwise. Increment
# 3 moved what those phases checked (agent-tier tool install, native package
# builds, the rvm/Ruby reconcile) into the packages tier of the runtime
# integration corpus and retired 1, 2 and 3 — PERMANENTLY: those numbers must
# never be reused, because reusing one would make a stale `PHASES="1 2 3"` valid
# again and silence the exact guard this paragraph describes. Increment 4 then
# added phases 5 and 7 (6 is reserved for a later increment; do not fill it in
# ahead of that increment defining it) — adding a phase below without a
# phase_fail call recreates exactly the original defect.
# tests/test-verify-exit-code.sh holds the line, and fails if it stops holding.
#
# Nothing here touches your real container groups, your images, or your projects:
# Phase 4 delegates to the runtime integration corpus, which uses its own
# throwaway image tags and group directories.
set -uo pipefail

REPO="${REPO:-$PWD}"
LOG_PREFIX="[host-verify]"
say() { printf '\n%s %s\n' "$LOG_PREFIX" "$*"; }
sub() { printf '%s   %s\n' "$LOG_PREFIX" "$*"; }

# Failure ledger. Phases record into it rather than exiting, so one broken phase
# never hides the state of any other. Call sites: phases 4, 5 and 7, and the
# VALID_PHASES selection check below — which records against the phase NUMBER
# the caller asked for, so a stale `PHASES="1 2 3"` reports three named failures
# rather than matching nothing and exiting 0. Phase 0 is the exception: it is an
# environment banner that hard-exits on a missing daemon rather than recording.
# The ledger is what makes any of those survive to the verdict at the bottom,
# and what a new phase must record into. The guard for all of it is
# tests/test-verify-exit-code.sh.
FAILED_PHASES=""
phase_fail() {  # $1=phase number  $2=one-line reason
  FAILED_PHASES="${FAILED_PHASES}${FAILED_PHASES:+$'\n'}$1|$2"
  printf '%s   ** PHASE %s FAILED: %s\n' "$LOG_PREFIX" "$1" "$2"
}

[[ -f "$REPO/build.sh" && -f "$REPO/sandbox.conf" ]] || {
  echo "ERROR: run this from an ai-containers checkout (or set REPO=/path/to/checkout)." >&2
  echo "       In mgd-ai-containers the engine lives in base/ — run it from there." >&2
  exit 2
}

# The bash floor is declared once, in bash-floor.sh. $REPO is now confirmed to
# be the engine directory (build.sh + sandbox.conf found above), so this works
# in both the upstream (repo root) and mgd (base/) layouts.
# shellcheck source=bash-floor.sh
source "$REPO/bash-floor.sh"

# Layout-tolerant tests dir: upstream ai-containers keeps tests/ next to build.sh;
# mgd-ai-containers keeps the engine in base/ and tests/ one level up, beside it.
# Resolving it here means ONE copy of this script serves both repos verbatim — a
# verifier that drifts from what it verifies is worse than none.
TESTS_DIR="$REPO/tests"
[[ -d "$TESTS_DIR" ]] || TESTS_DIR="$REPO/../tests"

# The directory that must be mounted for `tests/` to resolve inside Phase 5's
# bash-floor container: $REPO in ai-containers (tests/ is right there), $REPO/..
# in mgd where the engine lives in base/ and tests/ sits one level up beside it.
# Derived from TESTS_DIR rather than branched on repo name, so this stays the
# one copy that serves both layouts.
REPO_ROOT_FOR_MOUNT="$(cd "$TESTS_DIR/.." && pwd)"

# Phase selection. Phase 0 is always cheap and always runs. Everything else
# defaults to selected — a local layer nobody selects is not a local layer.
#   PHASES=0 bash verify-on-host.sh      # environment banner only
#   PHASES="5 7" bash verify-on-host.sh  # skip the phases that need Docker
PHASES="${PHASES:-4 5 7}"
want_phase() { case " $PHASES " in (*" $1 "*) return 0 ;; (*) return 1 ;; esac; }

# A PHASES value naming only phases this script does not have must not verify
# nothing and exit 0 — that is the founding defect the failure ledger above
# exists to prevent (see the header), reachable here through phase SELECTION
# rather than phase REPORTING: `PHASES="1 2 3"` names phases removed by
# Increment 3, want_phase() matched nothing for any of them, no phase_fail
# call ever fired, and the script declared success having run zero checks.
# Same standard as the IT_RUNNER-not-found branch below (an unresolvable
# request is a recorded failure, not a silent skip) applied to the request
# itself. Phase 0 is exempt — it always runs regardless of $PHASES. 1, 2 and 3
# are retired for good (see the header) and must never reappear here; 6 is
# reserved for a later increment and must stay absent until that increment
# defines it.
VALID_PHASES="0 4 5 7"
for _requested_phase in $PHASES; do
  case " $VALID_PHASES " in
    (*" $_requested_phase "*) : ;;
    (*) phase_fail "$_requested_phase" \
          "PHASES=\"$PHASES\" names phase $_requested_phase, which this script does not have (valid: $VALID_PHASES)" ;;
  esac
done

# ── Phase 0: environment ────────────────────────────────────────────────────────
say "PHASE 0 — environment"
sub "uname:            $(uname -sm)"
sub "docker:           $(docker --version 2>&1 | head -1)"
sub "buildx:           $(docker buildx version 2>&1 | head -1)"
sub "DOCKER_HOST:      ${DOCKER_HOST:-<unset>}"
if command -v colima >/dev/null 2>&1; then
  sub "colima status:    $(colima status 2>&1 | tr '\n' ' ' | cut -c1-160)"
  sub "colima resources: $(colima list 2>&1 | tail -n +1 | tr '\n' ' ' | cut -c1-200)"
fi
if ! docker info >/dev/null 2>&1; then
  echo "$LOG_PREFIX FATAL: docker daemon unreachable. Start Colima and export DOCKER_HOST:" >&2
  echo "  colima start --cpu 6 --memory 12 --disk 120" >&2
  echo '  export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"' >&2
  exit 1
fi
sub "docker disk:      $(docker system df --format '{{.Type}}={{.Size}}' 2>/dev/null | tr '\n' ' ')"

# ── Phase 5: the hermetic suite ──────────────────────────────────────────────────
# Mirrors .github/workflows/tests.yml's `suite` job. It exists because the local
# layer was a SUBSET of the PR gate: this script ran the integration corpus and
# nothing else, so a developer verifying locally checked LESS than CI would.
#
# It also runs the hermetic suite against BSD userland for the first time. CI is
# ubuntu-only; `stat -c`, `sha1sum` and `md5sum` do not exist on macOS, and four
# call sites used them with no fallback (fixed in increment 4, tests/portability.sh).
if want_phase 5; then
say "PHASE 5 — hermetic suite (tests/run-all.sh) + sandbox.conf schema gate"
if [[ ! -f "$TESTS_DIR/run-all.sh" ]]; then
  phase_fail 5 "$TESTS_DIR/run-all.sh not found — the hermetic suite did not run"
else
  bash "$TESTS_DIR/run-all.sh" 2>&1 | sed "s/^/$LOG_PREFIX   /"
  h_rc="${PIPESTATUS[0]:-1}"
  sub "hermetic suite exit: $h_rc"
  [[ "$h_rc" -eq 0 ]] || phase_fail 5 "hermetic suite exited $h_rc"
  if [[ -f "$REPO/check-sandbox-version.sh" ]]; then
    bash "$REPO/check-sandbox-version.sh" --check 2>&1 | sed "s/^/$LOG_PREFIX   /"
    s_rc="${PIPESTATUS[0]:-1}"
    [[ "$s_rc" -eq 0 ]] || phase_fail 5 "sandbox.conf schema gate exited $s_rc"
  else
    phase_fail 5 "check-sandbox-version.sh not found — the schema gate did not run"
  fi

  # The same suite at the DECLARED FLOOR, mirroring tests.yml's suite-floor job.
  # This host runs whatever bash the developer installed (5.3 via Homebrew is
  # typical); the floor is 5.1, and a floor nothing exercises is the defect this
  # increment exists to remove. Docker is guaranteed here — Phase 0 hard-exits
  # without a reachable daemon.
  floor_img="ubuntu:22.04"
  sub "running the suite at the declared floor ($floor_img, bash 5.1)"
  # This container runs as root (the image's default user) against a repo
  # bind-mount owned by the HOST user, so git >= 2.35.2's ownership check
  # refuses every operation in here ("detected dubious ownership") unless the
  # mount is explicitly trusted first. CI's suite-floor job does not need
  # this: actions/checkout clones INSIDE that container, as root, so the
  # clone and the container user already match. Scoped to the literal mount
  # point (/w — always this exact path, never the host's), not the `*`
  # wildcard: this container is single-purpose and throwaway (--rm) and never
  # touches any other directory, so the wildcard would trust more than this
  # invocation could ever use.
  #
  # The mount itself is :ro — DO NOT drop this suffix, even if a future test
  # needs scratch space; give it a mktemp dir instead. This is root, against
  # the developer's real working tree, possibly holding uncommitted work.
  # Nothing in this sequence needs write access: apt-get writes only to the
  # container's own package DB; `git config --global` writes to $HOME/.gitconfig
  # (root's own home, never redirected here); every test file's scratch output
  # goes through mktemp/mktemp -d (confirmed by grepping every output
  # redirect in tests/*.sh for one that ISN'T $TMP-scoped — none are). Getting
  # this wrong fails LOUD: the very next write attempt errors immediately with
  # "Read-only file system" on the next run. The alternative — staying :rw and
  # being wrong about something above — is silent corruption of a real
  # checkout, discovered whenever someone next looks. That asymmetry is why
  # :ro wins even without a Docker-based end-to-end run to confirm it here.
  docker run --rm -v "$REPO_ROOT_FOR_MOUNT:/w:ro" -w /w "$floor_img" bash -c \
    'apt-get update -qq && apt-get install -y -qq git rsync >/dev/null 2>&1 && \
     git config --global --add safe.directory /w && \
     bash --version | head -1 && ./tests/run-all.sh' 2>&1 | sed "s/^/$LOG_PREFIX   /"
  f_rc="${PIPESTATUS[0]:-1}"
  sub "floor suite exit: $f_rc"
  [[ "$f_rc" -eq 0 ]] || phase_fail 5 "hermetic suite at the declared floor exited $f_rc"
fi
fi

# ── Phase 7: lint ────────────────────────────────────────────────────────────────
# Mirrors .github/workflows/tests.yml's `lint` job. shellcheck runs as a GATE
# both here and in CI: Task 9 (increment 4) cleared the pre-existing findings
# backlog — real defects fixed, everything else suppressed at the site with a
# reason — and dropped tests.yml's `|| true`, so the two now agree instead of
# this phase being the only one that gates.
if want_phase 7; then
say "PHASE 7 — lint (bash -n, dialect floor, shellcheck)"
n_parsed=0; parse_rc=0
while IFS= read -r f; do
  n_parsed=$((n_parsed + 1))
  bash -n "$REPO/$f" 2>/dev/null || { sub "PARSE ERROR: $f"; parse_rc=1; }
done < <(cd "$REPO" && git ls-files '*.sh' 2>/dev/null)
if [[ "$n_parsed" -eq 0 ]]; then
  phase_fail 7 "bash -n parsed no files — the pathspec matched nothing"
else
  sub "parsed $n_parsed script(s)"
  [[ "$parse_rc" -eq 0 ]] || phase_fail 7 "bash -n found a parse error"
fi

if [[ -f "$TESTS_DIR/bash-dialect-lint.sh" ]]; then
  bash "$TESTS_DIR/bash-dialect-lint.sh" 2>&1 | sed "s/^/$LOG_PREFIX   /"
  d_rc="${PIPESTATUS[0]:-1}"
  [[ "$d_rc" -eq 0 ]] || phase_fail 7 "bash dialect lint exited $d_rc"
else
  phase_fail 7 "bash-dialect-lint.sh not found — the dialect floor was not checked"
fi

if command -v shellcheck >/dev/null 2>&1; then
  ( cd "$REPO" && git ls-files '*.sh' | xargs shellcheck -S warning -e SC1091 ) \
    2>&1 | sed "s/^/$LOG_PREFIX   /"
  sc_rc="${PIPESTATUS[0]:-1}"
  [[ "$sc_rc" -eq 0 ]] || phase_fail 7 "shellcheck exited $sc_rc"
else
  phase_fail 7 "shellcheck not installed — install it (brew install shellcheck) or deselect phase 7"
fi
fi

# ── Phase 4: the runtime integration corpus ─────────────────────────────────────
# Delegation, not duplication. This script owns three jobs and no test logic: the
# environment banner (Phase 0), a sensible default selection (everything — a
# human running locally wants full coverage), and platform-specific remediation
# hints on failure. The cases themselves live in tests/integration/cases/ and are
# the SAME ones CI runs; CI simply selects a cheaper subset by tag.
#
# The old Phase 3 is why this matters: it kept bind-mounting ~/.rvm for two full
# rounds after the volume fix landed, because it re-implemented what sandbox.sh
# does instead of calling it. A verifier that drifts from what it verifies is
# worse than no verifier.
if want_phase 4; then
say "PHASE 4 — runtime integration corpus (tests/integration/run.sh)"
IT_RUNNER="$TESTS_DIR/integration/run.sh"
if [[ ! -x "$IT_RUNNER" && ! -f "$IT_RUNNER" ]]; then
  sub "SKIP: $IT_RUNNER not found — nothing to delegate to."
  phase_fail 4 "$IT_RUNNER not found — the corpus did not run"
else
  sub "capabilities detected on this host:"
  bash "$IT_RUNNER" --list-caps 2>&1 | sed "s/^/$LOG_PREFIX     /"
  # No --tags: a human running this locally wants the whole corpus, including
  # the slow and needs-dns cases CI excludes on cost.
  bash "$IT_RUNNER" --require security ${IT_EXTRA_ARGS:-} 2>&1 | sed "s/^/$LOG_PREFIX   /"
  it_rc="${PIPESTATUS[0]:-1}"
  sub "PHASE 4 exit: $it_rc"
  if [[ "$it_rc" -ne 0 ]]; then
    phase_fail 4 "integration corpus exited $it_rc"
    sub "remediation hints for this platform:"
    if command -v colima >/dev/null 2>&1; then
      sub "  * ipset/NFLOG need the Colima VM's kernel modules. If the security"
      sub "    cases report 'requires: netadmin', restart with more headroom:"
      sub "      colima stop && colima start --cpu 6 --memory 12 --disk 120"
      sub "  * a bind-mount source outside \$HOME is NOT shared with the VM."
    else
      sub "  * ipset/NFLOG need ip_set and nfnetlink_log on this kernel:"
      sub "      sudo modprobe ip_set nfnetlink_log"
      sub "  * a rootless daemon cannot grant NET_ADMIN; the security cases will"
      sub "    report 'requires: netadmin' rather than silently passing."
    fi
  fi
fi
fi

# No "regenerate your allowlists" advice here any more, deliberately. Phases 1-3
# were what clobbered the developer's generated allowlist-*.txt — they invoked
# build.sh with their own SMOKE_CONF/NATIVE_CONF/RUBY_CONF and never put the real
# ones back. The only remaining phase delegates to tests/integration/run.sh, which
# snapshots those files before it builds and restores them in its own EXIT trap
# (`snapshot_real_allowlists`/`restore_real_allowlists`, skipped entirely under
# --reuse-image because no build ran). Telling the operator to repair something
# that was not broken teaches them to ignore the line that matters.
say "DONE."

# ── Verdict ─────────────────────────────────────────────────────────────────────
# Reprinted here because the per-phase failures scrolled past thousands of lines
# of build output, and because a CI log is read from the bottom.
if [[ -n "$FAILED_PHASES" ]]; then
  say "RESULT: FAILED — $(printf '%s\n' "$FAILED_PHASES" | grep -c .) phase(s) of [$PHASES]"
  while IFS='|' read -r n why; do
    [[ -n "$n" ]] && sub "phase $n: $why"
  done <<< "$FAILED_PHASES"
  exit 1
fi
say "RESULT: PASSED — phases [$PHASES]"
