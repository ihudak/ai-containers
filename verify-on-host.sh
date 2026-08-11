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
#
# IT_EXTRA_ARGS is forwarded verbatim to tests/integration/run.sh in Phase 4, on
# top of the --require security this script always passes. Phase 4 deliberately
# runs the WHOLE corpus by default (a human running locally wants full coverage,
# including the slow and needs-dns tiers CI excludes on cost), so this is the
# hook for narrowing that when iterating — e.g. --tags fast, or -v.
#
# Phases (each independent; a later phase still runs if an earlier one fails):
#   0  environment sanity (daemon reachable, buildx, disk; Colima status on macOS)
#   4  the runtime integration corpus — delegated in full to
#      tests/integration/run.sh. No test logic lives here.
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
# integration corpus, so this script now only gates Phase 0 and the Phase 4
# corpus call — adding a phase below without a phase_fail call recreates exactly
# the original defect.
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
# never hides the state of any other. Two call sites remain after increment 3:
# Phase 4, and the VALID_PHASES selection check below — which records against
# the phase NUMBER the caller asked for, so a stale `PHASES="1 2 3"` reports
# three named failures rather than matching nothing and exiting 0. Phase 0 is
# the exception: it is an environment banner that hard-exits on a missing
# daemon rather than recording. The ledger is what makes any of those survive
# to the verdict at the bottom, and what a new phase must record into. The
# guard for both halves is tests/test-verify-exit-code.sh.
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

# Layout-tolerant tests dir: upstream ai-containers keeps tests/ next to build.sh;
# mgd-ai-containers keeps the engine in base/ and tests/ one level up, beside it.
# Resolving it here means ONE copy of this script serves both repos verbatim — a
# verifier that drifts from what it verifies is worse than none.
TESTS_DIR="$REPO/tests"
[[ -d "$TESTS_DIR" ]] || TESTS_DIR="$REPO/../tests"

# Phase selection. Phase 0 is always cheap and always runs.
#   PHASES=0 bash verify-on-host.sh
PHASES="${PHASES:-4}"
want_phase() { case " $PHASES " in (*" $1 "*) return 0 ;; (*) return 1 ;; esac; }

# A PHASES value naming only phases this script does not have must not verify
# nothing and exit 0 — that is the founding defect the failure ledger above
# exists to prevent (see the header), reachable here through phase SELECTION
# rather than phase REPORTING: `PHASES="1 2 3"` names phases removed by
# Increment 3, want_phase() matched nothing for any of them, no phase_fail
# call ever fired, and the script declared success having run zero checks.
# Same standard as the IT_RUNNER-not-found branch below (an unresolvable
# request is a recorded failure, not a silent skip) applied to the request
# itself. Phase 0 is exempt — it always runs regardless of $PHASES.
VALID_PHASES="0 4"
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
