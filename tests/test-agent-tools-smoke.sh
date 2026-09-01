#!/usr/bin/env bash
# SUPERSEDED 2026-09-01, AND NOT WIRED INTO ANY LAYER. Read this before running it.
#
# It calls itself a BLOCKING pre-merge gate below, and it has never run in any
# automated layer: nothing anywhere sets AGENT_TOOLS_SMOKE=1 — not CI, not
# nightly, not verify-on-host.sh. The only other references are in the plan that
# introduced it (2026-08-03), where its own "BLOCKING gate" checkbox is still
# unticked. It has skipped cleanly in every suite run for four weeks.
#
# That is not the gap it looks like. Its three claims are each covered by the
# integration corpus's `packages` tier, which nightly's `packages-agents` job
# runs against the `agents` image variant:
#
#   1. installs behind the restricted firewall  -> case 700, whose summary is
#      "all six agent-tier tools install behind the restricted firewall"
#   2. resolves under a non-login `docker exec` -> case 700, same summary:
#      "and resolve for the AGENT, in a non-login shell"
#   3. persists to a second container run       -> case 710, whose summary is
#      "a second container in the same group reuses ~/.ai-tools instead of
#      re-downloading every agent-tier tool"
#
# This is the same absorption that removed verify-on-host.sh's Phases 1-3 when
# the packages tier took over agent-tier install coverage (AGENTS.md's phase
# table records those numbers as permanently burned). Those phases were deleted;
# this file was not, and nobody noticed because a SKIP looks like a pass at a
# glance.
#
# WHAT IT STILL DOES THAT THE CASES DO NOT: it builds from the developer's REAL
# sandbox.conf and runs against their REAL $HOME group directory, where the
# cases use a minimal conf and an isolated HOME. That is a local sanity check of
# one machine's own configuration, not a gate — and it is the honest reason to
# keep the file rather than delete it outright. Whether that is worth 30+
# minutes of image build is the open question; see the backlog entry.
#
# THE `DOCKER_CONFIG` IN THE GATING NOTE BELOW IS STALE: this file never
# references that variable. It uses the real $HOME and calls `docker run`
# directly, so it needs no context redirection and runs the same under Colima
# and Docker Desktop.
#
# BLOCKING pre-merge gate. Builds the image and drives the REAL entrypoint in a
# RESTRICTED-mode container so that agent-tools-reconcile (as the sandbox user) and
# link-agent-tools (as root) actually run, then proves each enabled agent-tier tool:
#   1. installs BEHIND THE RESTRICTED FIREWALL (installs happen after the firewall is up),
#   2. resolves under a NON-LOGIN, non-interactive `docker exec` — i.e. the linker put it
#      on /usr/local/bin (the property the linker exists for; profile.d is NOT sourced here),
#   3. persists to a second container run against the same group home (no reinstall).
#
# It does NOT override the entrypoint and does NOT use a login shell — earlier drafts did
# both, which silently validated nothing (the reconcile never ran, and a login shell
# resolved tools via profile.d rather than the linker).
#
# Gated: only runs when AGENT_TOOLS_SMOKE=1 (needs Docker + network + DOCKER_CONFIG).
# Iteration knobs: SMOKE_IMAGE (tag), SMOKE_SKIP_BUILD=1 (reuse an existing image),
# SMOKE_KEEP=1 (keep the image, do not rmi), SMOKE_FIRST_TIMEOUT / SMOKE_SECOND_TIMEOUT (secs).
set -uo pipefail
[[ "${AGENT_TOOLS_SMOKE:-0}" == "1" ]] || { echo "SKIP: set AGENT_TOOLS_SMOKE=1 to run the real-container smoke test"; exit 0; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${SMOKE_IMAGE:-ai-sandbox-smoke}"
# The npm agents are large and their postinstalls download native binaries, so a single
# tool can take several minutes even with nothing blocked. Default to all six (the full
# gate); SMOKE_TOOLS lets you run a faster one-per-mechanism subset, e.g.
# SMOKE_TOOLS="claude-code,graphify,vale" (npm + uv + binary download).
TOOLS="${SMOKE_TOOLS:-claude-code,copilot,codex,gemini,graphify,vale}"
# Map each enabled key to its installed binary name (claude-code → claude; others match).
BINS=""
for _k in ${TOOLS//,/ }; do
  case "$_k" in
    claude-code) BINS="${BINS:+$BINS }claude" ;;
    *)           BINS="${BINS:+$BINS }$_k" ;;
  esac
done
fails=0; pass(){ printf 'PASS: %s\n' "$1"; }; fail(){ printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

# ── Build (unless reusing an existing image) ─────────────────────────────────────
if [[ "${SMOKE_SKIP_BUILD:-0}" != "1" ]]; then
  printf '── building %s (this takes a while)…\n' "$IMG"
  IMAGE_NAME="$IMG" "$REPO_DIR/build.sh" "$IMG" \
    || { fail "image build"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }
fi

uid="$(id -u)"; gid="$(id -g)"; usern="$(id -un)"; groupn="$(id -gn)"
group="smoke-$$"
groupdir="$HOME/.ai-containers/$group/.ai-tools"
mkdir -p "$groupdir"

c1=""; c2=""
cleanup() {
  [[ -n "$c1" ]] && docker stop "$c1" >/dev/null 2>&1 || true
  [[ -n "$c2" ]] && docker stop "$c2" >/dev/null 2>&1 || true
  [[ "${SMOKE_KEEP:-0}" == "1" ]] || docker rmi "$IMG" >/dev/null 2>&1 || true
  rm -rf "$HOME/.ai-containers/$group" 2>/dev/null || true
}
trap cleanup EXIT

# Start a detached, restricted container whose real entrypoint runs the reconcile+linker.
# -di keeps the final interactive login shell alive (stdin held open) so `docker exec` works.
start() {
  docker run -di --rm \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -e DEV_CONTAINER_MODE=restricted \
    -e AI_RUNTIME_TOOLS="$TOOLS" \
    -e SANDBOX_UID="$uid" -e SANDBOX_GID="$gid" \
    -e SANDBOX_USER="$usern" -e SANDBOX_GROUP="$groupn" \
    -v "$groupdir:/home/$usern/.ai-tools" \
    "$IMG"
}

# Nap between polls. A `sleep` killed by a signal is harmless here — the loop is
# bounded by $SECONDS, so waking early just polls sooner — but bash announces a
# signal-killed child on its own stderr:
#   tests/test-agent-tools-smoke.sh: line 73: 26653 Killed: 9  sleep 10
# which lands mid-log looking like a failure (observed once during a long Phase 1
# run). Redirecting the compound command's stderr suppresses the notice; a bare
# subshell does NOT (verified both ways). `|| true` keeps the loop going regardless.
nap() { { sleep "$1"; } 2>/dev/null || true; }

# Poll (via NON-LOGIN docker exec) until all six tools resolve on the global PATH, or the
# container dies, or timeout. Returns 0 only when all six resolve.
wait_for_tools() { # $1=container  $2=timeout_secs
  local c="$1" timeout="$2" start_ts=$SECONDS
  while (( SECONDS - start_ts < timeout )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]]; then
      printf '   (container %s is no longer running)\n' "${c:0:12}" >&2
      return 2
    fi
    if docker exec "$c" bash -c "for t in $BINS; do command -v \$t >/dev/null || exit 1; done" 2>/dev/null; then
      return 0
    fi
    nap 10
  done
  return 1
}

diagnose() { # $1=container
  local c="$1"
  echo "   ── reconcile/entrypoint logs (tail) ──"
  docker logs "$c" 2>&1 | tail -50 | sed 's/^/     /'
  echo "   ── per-tool resolution (non-login docker exec) ──"
  docker exec "$c" bash -c 'for t in '"$BINS"'; do printf "     %-9s " "$t"; command -v "$t" || echo MISSING; done' 2>&1 || true
}

# ── Run 1: fresh group — tools install behind the firewall + resolve non-login ──
c1="$(start)"
if wait_for_tools "$c1" "${SMOKE_FIRST_TIMEOUT:-2400}"; then
  pass "all enabled tools ($TOOLS) install behind the restricted firewall + resolve via non-login docker exec (run 1)"
else
  fail "all enabled tools ($TOOLS) install behind the restricted firewall + resolve via non-login docker exec (run 1)"
  diagnose "$c1"
fi
docker stop "$c1" >/dev/null 2>&1 || true; c1=""

# ── Run 2: same group home — tools persist, no reinstall ──
c2="$(start)"
if wait_for_tools "$c2" "${SMOKE_SECOND_TIMEOUT:-300}"; then
  pass "tools persist to a second container against the same group home (no reinstall)"
else
  fail "tools persist to a second container against the same group home"
  diagnose "$c2"
fi
docker stop "$c2" >/dev/null 2>&1 || true; c2=""

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
