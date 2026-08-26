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
#   FALSIFY_TIMEOUT=300 FALSIFY_JOBS=6 PHASES=6 bash ./verify-on-host.sh
#                                              # Phase 6's per-mutant clock and
#                                              # worker count (default 120, auto)
#
# IT_EXTRA_ARGS is forwarded verbatim to tests/integration/run.sh in Phase 4, on
# top of the --require security this script always passes. Phase 4 deliberately
# runs the WHOLE corpus by default (a human running locally wants full coverage,
# including the slow and needs-dns tiers CI excludes on cost), so this is the
# hook for narrowing that when iterating — e.g. --tags fast, or -v.
#
# FALSIFY_TIMEOUT and FALSIFY_JOBS are Phase 6's equivalents, and exist because
# that phase tells you to reach for exactly those two when a run comes back with
# a chunk of the corpus unmeasured. Both default to what the phase always used
# (120 seconds per mutant, one worker per available CPU), and the phase banner
# prints the values it actually ran with.
#
# Phases (each independent; a later phase still runs if an earlier one fails).
# Numbers are IDENTIFIERS, not execution order — the script actually runs them
# 0, 5, 6, 7, 4: cheap checks first, the Docker-hungry corpus last. (6 sits
# between 5 and 7 in execution because it needs no Docker either; it is minutes
# rather than seconds, so it is listed after 7 in the table below, where the
# order is by cost of reading.)
#   0  environment sanity (daemon reachable, buildx, disk; Colima status on macOS)
#   5  the hermetic suite (tests/run-all.sh) + the sandbox.conf schema gate — and
#      the same suite again inside a container pinned to the declared bash floor.
#      Mirrors hermetic-checks.yml's `suite` + `suite-floor` jobs.
#   7  lint: bash -n over every tracked script, the bash-dialect floor check, and
#      a shellcheck run. Mirrors hermetic-checks.yml's `lint` job — same commands, same gate.
#   6  the falsify mutation tier: the WHOLE corpus, then the survivor-ledger
#      ratchet scored against that same fresh run. Mirrors hermetic-checks.yml's
#      `falsify` job. Needs no Docker; costs minutes, not seconds.
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
# added phases 5 and 7, and increment 5 defined the phase 6 those two left
# reserved (the falsify mutation tier) — adding a phase below without a
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
# shellcheck source=SCRIPTDIR/bash-floor.sh
source "$REPO/bash-floor.sh"

# Layout-tolerant tests dir: upstream ai-containers keeps tests/ next to build.sh;
# mgd-ai-containers keeps the engine in base/ and tests/ one level up, beside it.
# Resolving it here means ONE copy of this script serves both repos verbatim — a
# verifier that drifts from what it verifies is worse than none.
TESTS_DIR="$REPO/tests"
[[ -d "$TESTS_DIR" ]] || TESTS_DIR="$REPO/../tests"

# The repo root, as opposed to $REPO which is the ENGINE directory: the same in
# ai-containers (tests/ sits right there), one level up in mgd where the engine
# lives in base/. Derived from TESTS_DIR rather than branched on repo name, so
# this stays the one copy that serves both layouts.
#
# TWO consumers, and the second one was missing. Phase 5's bash-floor container
# mounts this so `tests/` resolves inside it. Phase 7's lint file list needs it
# for a sharper reason: `git ls-files` run from a subdirectory lists ONLY what
# is under that subdirectory, so building the list from $REPO linted the engine
# directory alone. In ai-containers $REPO is the repo root and the defect is
# invisible; in mgd-ai-containers it meant 23 of 136 tracked scripts checked,
# and a PASSED verdict over the rest — including, measured, a tracked script
# carrying a syntax error. The CI job Phase 7 claims to mirror runs from the
# checkout root and lints all of them, so the local layer was a strict SUBSET
# of the PR layer for the one leg where local is meant to be the superset.
# tests/test-verify-lint-scope.sh drives both layouts.
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Same base/-vs-repo-root duality as TESTS_DIR above, for the schema-gate
# script: upstream ai-containers keeps check-sandbox-version.sh next to
# build.sh; mgd-ai-containers keeps it at the repo root, one level above the
# base/ engine directory this script runs from. Without this fallback, $REPO
# (= base/ in real mgd usage) never finds it, the schema gate always hits the
# "not found" branch below, and the BASE_REF-resolution fix just above never
# actually runs against a real mgd checkout.
CHECK_SANDBOX_VERSION_SH="$REPO/check-sandbox-version.sh"
[[ -f "$CHECK_SANDBOX_VERSION_SH" ]] || CHECK_SANDBOX_VERSION_SH="$REPO/../check-sandbox-version.sh"

# Phase selection. Phase 0 is always cheap and always runs. Everything else
# defaults to selected — a local layer nobody selects is not a local layer.
#   PHASES=0 bash verify-on-host.sh      # environment banner only
#   PHASES="5 7" bash verify-on-host.sh  # skip the phases that need Docker
PHASES="${PHASES:-4 5 6 7}"
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
# are retired for good (see the header) and must never reappear here. 6 was
# reserved and is now DEFINED (increment 5's falsify mutation tier); keeping it
# out until the tier existed did its job — naming it early failed loudly
# instead of silently verifying nothing.
VALID_PHASES="0 4 5 6 7"
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
# Mirrors .github/workflows/hermetic-checks.yml's `suite` job. It exists because the local
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
  if [[ -f "$CHECK_SANDBOX_VERSION_SH" ]]; then
    # BASE_REF must predate the change under review. The script's own default
    # (BASE_REF=HEAD) diffs the WORKING TREE's sandbox.conf against HEAD's —
    # once a change is committed, those are the same content, so the gate
    # reports "OK, nothing removed" having compared a commit to itself. This
    # is a silent no-op, precisely the failure mode AGENTS.md's "sandbox.conf
    # schema versioning" section warns about, and hermetic-checks.yml never falls
    # into it because its schema-gate step always exports a real BASE_REF (the PR
    # base SHA, or event.before/HEAD^ for a push) before invoking the script.
    # Mirror that here: merge-base against origin/main is the common case for
    # a normal checkout; a fresh clone or the mgd base/ layout may have no
    # origin/main fetched at all, so fall back to HEAD^ — but only if THAT
    # resolves to a real commit. If neither resolves, this must fail loudly
    # rather than hand check-sandbox-version.sh an unusable ref: an
    # unresolvable BASE_REF makes `git show $BASE_REF:sandbox.conf` fail,
    # which the script itself treats as "no sandbox.conf at that ref — nothing
    # to compare" and exits 0 — the exact silent-pass this phase exists to
    # prevent, just relocated one level down.
    #
    # A merge-base EQUAL TO HEAD is not a usable base, and treating it as one is
    # how this block defeated itself for as long as it existed. It happens on the
    # most ordinary thing a person does here: run Phase 5 on `main` after a merge.
    # origin/main is then HEAD, merge-base returns HEAD, BASE_REF becomes HEAD —
    # which is check-sandbox-version.sh's own default — and the gate diffs HEAD's
    # sandbox.conf against a working tree identical to it, finds nothing removed,
    # and prints OK. That is the silent no-op the whole comment above is about,
    # reached through a route the emptiness check could not see. Measured on the
    # host 2026-08-19: `schema gate diffing sandbox.conf against aeb1421…`, where
    # aeb1421 WAS HEAD. Recorded as backlog F44.
    #
    # HEAD^ is the right fallback rather than an error: on main, "this change" is
    # the last commit, and for a merge commit HEAD^ is the previous main — the
    # same push semantics hermetic-checks.yml uses when there is no PR base.
    gate_head_sha="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
    gate_base_ref="$(git -C "$REPO" merge-base HEAD origin/main 2>/dev/null || true)"
    if [[ -z "$gate_base_ref" || "$gate_base_ref" == "$gate_head_sha" ]]; then
      gate_base_ref="$(git -C "$REPO" rev-parse --verify -q HEAD^ 2>/dev/null || true)"
    fi
    if [[ -z "$gate_base_ref" || "$gate_base_ref" == "$gate_head_sha" ]]; then
      phase_fail 5 "no usable BASE_REF for the schema gate (origin/main is HEAD or absent, and HEAD^ does not resolve) — refusing to run it against HEAD itself, which would compare a commit to itself and silently verify nothing"
    else
      sub "schema gate diffing sandbox.conf against $gate_base_ref"
      BASE_REF="$gate_base_ref" bash "$CHECK_SANDBOX_VERSION_SH" --check 2>&1 | sed "s/^/$LOG_PREFIX   /"
      s_rc="${PIPESTATUS[0]:-1}"
      [[ "$s_rc" -eq 0 ]] || phase_fail 5 "sandbox.conf schema gate exited $s_rc"
    fi
  else
    phase_fail 5 "check-sandbox-version.sh not found — the schema gate did not run"
  fi

  # The same suite at the DECLARED FLOOR, mirroring hermetic-checks.yml's suite-floor job.
  # This host runs whatever bash the developer installed (5.3 via Homebrew is
  # typical); the floor is 5.1, and a floor nothing exercises is the defect this
  # increment exists to remove. Docker is guaranteed here — Phase 0 hard-exits
  # without a reachable daemon.
  # From bash-floor.sh's map — see its comment for why the image is declared
  # alongside the floor rather than duplicated here. Empty means the declared
  # floor has no mapped image, which must fail loudly: running the "floor" suite
  # in whatever image `docker run ""` resolves to would verify nothing.
  floor_img="${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}"
  if [[ -z "$floor_img" ]]; then
    phase_fail 5 "bash-floor.sh maps no container image to the declared floor — the floor suite did not run"
  else
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
    docker run --rm -v "$REPO_ROOT:/w:ro" -w /w "$floor_img" bash -c \
      'apt-get update -qq && apt-get install -y -qq git rsync >/dev/null 2>&1 && \
       git config --global --add safe.directory /w && \
       bash --version | head -1 && ./tests/run-all.sh' 2>&1 | sed "s/^/$LOG_PREFIX   /"
    f_rc="${PIPESTATUS[0]:-1}"
    sub "floor suite exit: $f_rc"
    [[ "$f_rc" -eq 0 ]] || phase_fail 5 "hermetic suite at the declared floor exited $f_rc"
  fi
fi

# ── the suite again, with TMPDIR pointed at a SYMLINK ────────────────────────
# Mirrors hermetic-checks.yml's `suite-symlinked-tmp` job, and exists because CI
# is ubuntu-only, where the temp directory is not a symlink. macOS's is: /var is
# a symlink to /private/var, so `mktemp -d` returns /var/folders/… while
# anything canonicalising reports /private/var/folders/…. A test comparing one
# against the other passes in CI AND in the floor container and fails on every
# Mac — a shape that has cost this repo twice, 19 assertions in increment 4 and
# three more on 2026-08-24.
#
# This run is a stand-in for a Mac, so ON a Mac it is largely redundant: the
# host run above already has a symlinked TMPDIR by default. It runs anyway
# rather than being skipped on Darwin, because a conditional whose macOS branch
# nothing exercises is precisely the untested claim this repo keeps purging —
# and because the containment invariant requires every PR-gate check to exist
# here too. The cost is one more suite run; the alternative is a branch nobody
# can see fail.
#
# ON DARWIN IT IS INERT, not merely redundant, and that is worth stating rather
# than leaving a reader to infer "redundant" means "does the same thing twice".
# macOS's mktemp IGNORES TMPDIR when given no template and uses the per-user
# directory from confstr(_CS_DARWIN_USER_TEMP_DIR) — measured:
#
#   TMPDIR=/Users/x/tmp-plain mktemp -d
#   -> /var/folders/w9/…/T/tmp.UuY97xwbZb
#
# so the export below steers nothing there. The arm still costs nothing but a
# suite run, and it is still correct to run it — the point it exists to make is
# made on Linux, where TMPDIR does steer, and where CI's suite-symlinked-tmp job
# runs. tests/test-symlinked-tmp-guard.sh measures the same lever and says so
# when it is absent.
#
# tests/test-symlinked-tmp-guard.sh is what keeps this honest: it demonstrates
# that a path-naive comparison fails under the symlinked arm and PASSES under an
# ordinary one, so pointing TMPDIR at a plain directory by accident would be
# caught rather than silently reducing this to a second ordinary run.
# Gated on the ORDINARY run having passed. The two runs exercise the same suite
# in two environments, so a suite that is already broken fails both and reports
# the same problem twice — and the verdict counts failures, not distinct phases,
# so a single broken test would read as "2 phase(s)". Running the variant only
# when the baseline is green keeps the failure output pointed at the one thing
# that is actually wrong, and loses nothing: you fix that and re-run.
sl_tmp=""
if [[ "${h_rc:-1}" -eq 0 ]]; then
  sl_tmp="$(mktemp -d)" || phase_fail 5 "mktemp -d failed — nowhere to build the symlinked TMPDIR"
fi
if [[ -n "$sl_tmp" && -d "$sl_tmp" ]]; then
  mkdir -p "$sl_tmp/real"
  ln -s "$sl_tmp/real" "$sl_tmp/symlinked-tmp"
  sub "running the suite with TMPDIR pointed at a symlink (the macOS shape)"
  TMPDIR="$sl_tmp/symlinked-tmp" "$TESTS_DIR/run-all.sh" 2>&1 | sed "s/^/$LOG_PREFIX   /"
  sl_rc="${PIPESTATUS[0]:-1}"
  sub "symlinked-TMPDIR suite exit: $sl_rc"
  [[ "$sl_rc" -eq 0 ]] || phase_fail 5 "hermetic suite under a symlinked TMPDIR exited $sl_rc"
  rm -rf "$sl_tmp"
fi
fi

# ── Phase 6: the falsify mutation tier ───────────────────────────────────────────
# Mirrors .github/workflows/hermetic-checks.yml's `falsify` job. Phase 6 was
# RESERVED for this increment and deliberately kept out of VALID_PHASES until it
# existed, so that naming it early would fail rather than silently verify nothing.
#
# The corpus run and the ledger check are ONE operation, for the reason spelled
# out at length in that CI job: check-ledger.sh scores the ledger against a
# single run, so a fix and its ledger edit must be re-derived together on the
# tree under test. Freezing a run artefact and checking against it would make
# this a historical measurement of a tree that no longer exists.
#
# --timeout 120 matches CI, and for the same reason: UNPROVEN means "the oracle
# timed out without printing FAIL:", so a slow machine turns a kill into an
# unclassified survivor and fails the ratchet for a reason that has nothing to
# do with the tree. A developer's laptop is exactly the loaded machine that
# happens on — measured on macOS during increment 5 (upstream backlog F26).
#
# $TESTS_DIR, not "$REPO/tests": $REPO is the ENGINE dir, and in
# mgd-ai-containers tests/ sits one level up beside it, so the "$REPO/tests"
# form resolves to a path that does not exist there. TESTS_DIR is the
# layout-tolerant handle this file already derives for exactly that reason (see
# its definition above), and using it keeps this ONE copy serving both layouts —
# the property the rest of the script is built around, and one this file had
# quietly stopped honouring in two places.
if want_phase 6; then
say "PHASE 6 — falsify mutation tier + survivor-ledger ratchet"
fl_run="$(mktemp)" || phase_fail 6 "mktemp failed — Phase 6 has nowhere to write the corpus run, and an empty path would make every later read of it report an empty corpus rather than a broken one"
# --jobs auto, NOT $(nproc). nproc reads the affinity MASK and does not see a
# `--cpus` cgroup quota, so inside a container — including one this repo's own
# sandbox.sh started, where CONTAINER_CPUS defaults to 1.0 — it reports the
# host's count and the tier oversubscribes. That lands on the per-mutant clock
# --timeout is measured against, and a mutant that trips it is scored UNPROVEN,
# which is not owed a ledger entry: a mutant that WAS killed leaves the measured
# set in silence. run.sh resolves the number and names both; surfaced here
# rather than left buried in $fl_run.
# Whether the log below survives the phase. Set by every branch that PRINTS
# SOMETHING POINTING INTO IT; read once at the end. A flag rather than a delete
# at each site so the two can never disagree about which runs are worth keeping.
fl_keep=0
# THE TWO KNOBS THE NOTES BELOW TELL THE OPERATOR TO REACH FOR. Both numbers used
# to be written into the invocation directly, which made "raise --timeout or
# reduce load" advice with nothing behind it: no variable, no flag and no
# argument moved either one, so following it meant editing this script in the
# middle of a verification — on a checkout that may be shared with an agent — or
# running the corpus by hand and skipping the ratchet Phase 6 exists to pair with
# it (backlog F48). Measured: the 2026-08-20 macOS run resolved auto to 18 on an
# 18-CPU host and lost 71 mutants to the 120s clock, 14% of the corpus
# unresolved, with the note naming the right lever and the lever not existing.
#
# The defaults ARE what was hardcoded, so an unset environment runs exactly what
# it always ran. Phase 4's IT_EXTRA_ARGS is the same idea for the same reason.
# `auto` IS WRONG ON DARWIN, and the number it picks is the reason Phase 6 could
# not complete on a Mac. fr_cpu_budget resolves `auto` to min(nproc, cgroup
# quota); macOS has no cgroup, so it takes nproc — 12 on the machine below — and
# every worker runs a WHOLE run-all.sh. The budget measures how many CPUs may be
# burned, when the binding constraint here is fork throughput.
#
# Measured, one Apple Silicon host, one target (version.sh, 30 mutants):
#
#   oracle baseline    136 ms on Linux   vs   2514 ms here   (~18x, unloaded)
#
#   --jobs auto (12)   many controls red, oracles red on PRISTINE trees, no score
#   --jobs 4           2 of 26 controls red, 4 mutants over a 300s clock, no score
#   --jobs 2           2 of 24 controls red, four oracles red on PRISTINE trees,
#                      no score — MEASURED 2026-08-26, whole corpus
#   --jobs 1           clean: baseline PASS, 29 killed / 1 survived / 0 unproven,
#                      controls 2 of 2 green, ~87s for the target
#
# A failed control invalidates every kill recorded near it, so the default is
# the only value observed clean rather than the largest that might work.
#
# 2 WAS THE OBVIOUS CANDIDATE AND IT FAILS. It is written down here because a
# negative result nobody records is a negative result somebody re-derives: the
# next reader's first instinct is "surely 2 is fine on a 12-core machine", and
# it is not. Do not raise this without a measurement, and put the measurement
# here when you have one.
#
# WHAT THE 2-JOB RUN ADDED, and it points away from CPU contention: assertions
# inside the red oracles reported rc=137 — SIGKILL, a process being shot, not a
# test failing. On that host Colima holds 36 GiB, and Phase 6 runs on the HOST
# beside it, so the ceiling being hit may be MEMORY rather than cores. If this
# is ever revisited, measure free host RAM during the run before reaching for
# the jobs number again.
#
# The cost is bounded: Phase 6's own banner already tells a macOS reader to
# expect ~45 minutes, and jobs=1 lands inside that.
if [[ -z "${FALSIFY_JOBS:-}" && "$(uname -s)" == "Darwin" ]]; then
  fl_jobs=1
else
  fl_jobs="${FALSIFY_JOBS:-auto}"
fi
fl_timeout="${FALSIFY_TIMEOUT:-120}"
# HOW LONG, honestly, and platform-aware — because the previous wording was
# "a few minutes" and on macOS this phase takes about forty-five. A progress
# line that understates by 20x is how somebody decides the run has hung and
# kills it at minute ten, which costs them the whole phase and teaches them
# not to run it again. Measured on one Apple Silicon machine, same 264-mutant
# corpus, same hardware: ~76s inside the Linux dev container at --jobs 8,
# ~45 min on macOS natively at --jobs 6. This tier is bound by process
# creation, and macOS is far slower at it.
if [[ "$(uname -s)" == "Darwin" ]]; then
  sub "running the corpus (jobs=$fl_jobs, timeout=$fl_timeout) — EXPECT ~45 MINUTES on macOS."
  sub "  It is not hung: this tier forks constantly and macOS is slow at it. Leave it running."
else
  sub "running the corpus (jobs=$fl_jobs, timeout=$fl_timeout) — a few minutes"
fi
if bash "$TESTS_DIR/falsify/run.sh" --jobs "$fl_jobs" --timeout "$fl_timeout" > "$fl_run" 2>&1; then
  { grep -E '^falsify: --jobs auto ' "$fl_run" || true; } \
    | sed 's/^falsify: //' | while IFS= read -r l; do sub "$l"; done
  # BASELINE and NOTE are in this filter because leaving them out cost a day.
  # BASELINE is each oracle's honest cost on a quiet machine — the number that
  # tells "this oracle is slow" apart from "this machine was loaded", and the
  # single most informative record when a control goes over its ceiling. NOTE
  # carries the control diagnostics, including `control-clock`, which says how
  # late the watchdog NOTICED as distinct from how long the oracle ran. Both
  # were being computed and then discarded: the corpus log is a mktemp that is
  # deleted whenever the run is clean, so on a green run the only copy of them
  # went with it (backlog F47, in a place the F47 fix did not reach).
  grep -E '^(BASELINE|TARGET|TOTAL|ASSERTLESS|SKIPPED|UNATTEMPTED|CONTROL|CONTROLS|NOTE)\|' "$fl_run" | sed 's/^/  /' | while IFS= read -r l; do sub "$l"; done
  # HOW MUCH WAS ACTUALLY MEASURED. An UNPROVEN mutant produced no verdict at
  # all, so a run with many of them is measuring less than its pass suggests —
  # and the pass is honest only if that is said out loud rather than left in
  # stderr notes. Measured on macOS (upstream tree, same corpus): 4 unproven on
  # Linux against 14 and then 35 on the same commit, i.e. the number moves with
  # machine load, not with code.
  fl_tot="$(awk -F'|' '$1=="TOTAL" {print $3; exit}' "$fl_run")"
  fl_unp="$(awk -F'|' '$1=="TOTAL" {print $6; exit}' "$fl_run")"
  if [[ -n "$fl_tot" && -n "$fl_unp" && "$fl_tot" -gt 0 ]]; then
    sub "verdicts obtained for $(( fl_tot - fl_unp ))/$fl_tot mutants ($(( (fl_tot - fl_unp) * 100 / fl_tot ))%)"
    # ADVISORY HERE, A GATE IN CI, and the asymmetry is the same one --strict
    # already draws: ubuntu-latest is the REFERENCE environment and passes
    # --max-unproven-pct 10 (the same 10 as below, one concept with one number),
    # while a developer host legitimately times out and failing it here would be
    # the everywhere-at-once mistake backlog F27 records.
    if (( fl_unp * 100 / fl_tot >= 10 )); then
      fl_keep=1
      sub "NOTE: $fl_unp mutant(s) timed out and were not measured. FALSIFY_TIMEOUT"
      sub "      (now $fl_timeout) raises the per-mutant clock; FALSIFY_JOBS (now $fl_jobs)"
      sub "      lowers the load. Not a failure HERE: an unproven mutant is machine"
      sub "      state, not a property of the code. CI gates on it."
    fi
  fi
  # KILLS WITH NO ASSERTION ATTACHED. Reported here rather than gated, but for
  # the OPPOSITE reason to the unproven note above: that one is advisory because
  # a timeout is machine state, while this one is a property of the oracle's
  # code and should read the same everywhere. Which is exactly why it is worth
  # printing on a host — a non-zero here against CI's zero means an oracle
  # aborts on macOS and nowhere else, and that is a finding, not load.
  fl_al="$(awk -F'|' '$1=="ASSERTLESS" {print $2; exit}' "$fl_run")"
  if [[ -n "$fl_al" && "$fl_al" -gt 0 ]]; then
    fl_keep=1
    sub "NOTE: $fl_al kill(s) arrived with NO assertion — the oracle exited non-zero"
    sub "      without printing a FAIL: line. CI gates this at 0, so a non-zero here"
    sub "      is platform-specific and worth chasing. Grep the kept run log named"
    sub "      at the end of this phase for 'KILLED WITH NO ASSERTION ATTACHED' —"
    sub "      it names each mutant, and nothing else records which ones they were."
  fi
  # The ratchet is a SEPARATE step, as in CI: run.sh's stdout is the record and
  # its exit status is an independent signal, and a pipeline would discard one.
  if bash "$TESTS_DIR/falsify/check-ledger.sh" \
       --run-output "$fl_run" --ledger "$TESTS_DIR/falsify/survivors.txt"; then
    sub "survivor ledger: OK"
  else
    fl_keep=1
    phase_fail 6 "the survivor-ledger ratchet rejected tests/falsify/survivors.txt"
  fi
else
  fl_keep=1
  sub "corpus exit: non-zero"
  # THE `ERROR:` LINES FIRST, AND UNCONDITIONALLY. `falsify:` is run.sh's
  # ROUTINE progress channel — one note per timed-out mutant, and a loaded
  # machine produces dozens — while `ERROR:` is the reason it gave up. Matching
  # both in one grep and taking `tail -10` therefore shows ten timeout notes and
  # DROPS the only line that says what went wrong. Not hypothetical: a macOS
  # A Phase 6 run in mgd-ai-containers on 2026-08-17 reported "the corpus did
  # not complete" above exactly ten TIMEOUT notes, with the cause nowhere on
  # screen — the same shape as the `head -1` truncation this project has now
  # fixed three times. The two channels are read separately: every ERROR line,
  # then a tail of the notes for context.
  fl_errs="$(grep -E '^ERROR:' "$fl_run" || true)"
  if [[ -n "$fl_errs" ]]; then
    while IFS= read -r l; do sub "$l"; done <<< "$fl_errs"
  else
    sub "(run.sh printed no ERROR: line — the notes below are all it said)"
  fi
  grep -E '^falsify:' "$fl_run" | tail -6 | while IFS= read -r l; do sub "$l"; done
  phase_fail 6 "the falsify corpus did not complete — the ledger was not scored"
fi
# THE LOG IS THIS PHASE'S EVIDENCE, NOT ITS SCRATCH. Everything above prints a
# SUMMARY drawn out of $fl_run — a count of assertless kills, a count of unproven
# mutants, six of however many notes — while the file itself is the only place
# the per-mutant `MUTANT|<verdict>|<identity>|…` records and the per-occurrence
# `falsify:` warnings exist at all. Deleting it unconditionally meant the two
# notes that say GO READ THIS named a file with no printed path that was already
# gone (backlog F47). Measured: the 2026-08-20 macOS run reported ASSERTLESS|2|227
# — the first time that counter has ever fired, and platform-specific by
# construction since CI holds --max-assertless 0 — and both identities became
# unrecoverable the moment the phase ended.
#
# Kept only when something above pointed into it, so a verification with nothing
# to chase still leaves nothing behind; a fix that merely dropped the delete
# would fill $TMPDIR with a full corpus log per run. tests/test-verify-exit-code.sh
# asserts both directions.
if (( fl_keep )); then
  sub "corpus run log kept at: $fl_run"
  sub "  One MUTANT|<verdict>|<identity>|… record per mutant, plus every falsify:"
  sub "  note — the detail the summaries above are counts of. Nothing else will"
  sub "  remove it."
else
  rm -f "$fl_run"
fi
fi

# ── Phase 7: lint ────────────────────────────────────────────────────────────────
# Mirrors .github/workflows/hermetic-checks.yml's `lint` job. shellcheck runs as a GATE
# both here and in CI: Task 9 (increment 4) cleared the pre-existing findings
# backlog — real defects fixed, everything else suppressed at the site with a
# reason — and dropped hermetic-checks.yml's `|| true`, so the two now agree instead of
# this phase being the only one that gates.
# ── EVERY script this phase must examine ──────────────────────────────────────
# TRACKED, plus UNTRACKED-AND-NOT-IGNORED. `git ls-files '*.sh'` alone lists the
# INDEX, so a script you have just written is invisible until `git add` — and
# the local gate then reports clean over a file it never read, the author's
# first feedback being a red CI job. That is not hypothetical: it happened on
# the very PR whose subject was "the lint gate's file list silently omits
# files" (backlog F40, then F42).
#
# `--exclude-standard` honours .gitignore, so what this adds is exactly the
# files you are about to commit — not a developer's ignored scratch.
#
# CI IS DELIBERATELY NOT CHANGED. It checks out a branch where everything is
# committed, so the two lists are identical there; this can only ever differ on
# a developer's machine, which is where the surprise was. tests/bash-dialect-lint.sh
# keeps its own tracked-only default for exactly that reason and is handed this
# list explicitly instead.
vh_tracked_scripts()   { ( cd "$REPO_ROOT" 2>/dev/null && git ls-files '*.sh' 2>/dev/null ); }
vh_untracked_scripts() { ( cd "$REPO_ROOT" 2>/dev/null && git ls-files --others --exclude-standard '*.sh' 2>/dev/null ); }
vh_all_scripts()       { { vh_tracked_scripts; vh_untracked_scripts; } | sort -u; }

if want_phase 7; then
say "PHASE 7 — lint (bash -n, dialect floor, shellcheck)"
n_parsed=0; parse_rc=0
while IFS= read -r f; do
  n_parsed=$((n_parsed + 1))
  bash -n "$REPO_ROOT/$f" 2>/dev/null || { sub "PARSE ERROR: $f"; parse_rc=1; }
done < <(vh_all_scripts)
n_untracked="$(vh_untracked_scripts | grep -c . )"
if [[ "$n_parsed" -eq 0 ]]; then
  phase_fail 7 "bash -n parsed no files — the pathspec matched nothing"
else
  sub "parsed $n_parsed script(s)"
  # SAY when the list included files git does not track yet. Silence here is
  # what made the old behaviour a surprise rather than a policy: a reader could
  # not tell whether a new script had been checked or skipped.
  if (( n_untracked > 0 )); then
    sub "  including $n_untracked not yet tracked by git:"
    vh_untracked_scripts | while IFS= read -r u; do sub "    $u"; done
    sub "  (they are linted here and in CI only once committed; .gitignore'd files are never included)"
  fi
  [[ "$parse_rc" -eq 0 ]] || phase_fail 7 "bash -n found a parse error"
fi

if [[ -f "$TESTS_DIR/bash-dialect-lint.sh" ]]; then
  # Handed the SAME list the other two checks use, absolute, so all three agree
  # on what "every script" means. Its own default stays tracked-only for CI.
  vh_dl_files=()
  while IFS= read -r f; do vh_dl_files+=("$REPO_ROOT/$f"); done < <(vh_all_scripts)
  bash "$TESTS_DIR/bash-dialect-lint.sh" ${vh_dl_files[@]+"${vh_dl_files[@]}"} 2>&1 | sed "s/^/$LOG_PREFIX   /"
  d_rc="${PIPESTATUS[0]:-1}"
  [[ "$d_rc" -eq 0 ]] || phase_fail 7 "bash dialect lint exited $d_rc"
  # Both of these are silent when clean, so a phase that ran them and a phase
  # that skipped them looked identical in the log. In a project whose recurring
  # bug is checks reporting success without doing anything, "passed silently" is
  # not good enough evidence — say what ran and over how much.
  sub "dialect lint exit: $d_rc"
else
  phase_fail 7 "bash-dialect-lint.sh not found — the dialect floor was not checked"
fi

if command -v shellcheck >/dev/null 2>&1; then
  # -r/--no-run-if-empty: GNU xargs runs the command ONCE even when its input is
  # empty. shellcheck with zero file arguments does not read stdin — it prints
  # "No files specified." and exits 3, which xargs reports as 123 — so this
  # phase would record a SECOND phase_fail for the one root cause the bash -n
  # branch above already reported ("RESULT: FAILED — 2 phase(s)" for a single
  # problem). BSD xargs is no-run-if-empty by default and does not accept -r
  # before macOS 13, so probe for it rather than assuming.
  xargs_r=()
  printf '' | xargs -r true >/dev/null 2>&1 && xargs_r=(-r)
  ( cd "$REPO_ROOT" && vh_all_scripts | xargs "${xargs_r[@]}" shellcheck -S warning -e SC1091 ) \
    2>&1 | sed "s/^/$LOG_PREFIX   /"
  sc_rc="${PIPESTATUS[0]:-1}"
  [[ "$sc_rc" -eq 0 ]] || phase_fail 7 "shellcheck exited $sc_rc"
  # Say WHICH shellcheck, for the same reason the CI step does. This is the one
  # place the two layers genuinely differ: CI takes the version its pinned
  # runner image ships (ubuntu-24.04 -> 0.9.0), and this host takes whatever is
  # installed (Homebrew ships current). Measured 2026-08-19 over the same 132
  # scripts, 0.9.0 and 0.11.0 both returned 0 — so they agree on this tree, and
  # the exposure is a finding that exists in one layer and not the other.
  # Reported, not asserted: pinning a number here would be a claim that drifts
  # from the runner image, and failing on a mismatch would break every Mac.
  sc_ver="$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }')"
  sub "shellcheck exit: $sc_rc over $( vh_all_scripts | grep -c . ) script(s), version ${sc_ver:-unknown}"
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
# ones back. Phase 4 — the only phase that invokes build.sh — delegates to
# tests/integration/run.sh, which
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
