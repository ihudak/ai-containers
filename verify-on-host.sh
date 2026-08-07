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
#   PHASES=3 bash ./verify-on-host.sh          # just the Ruby phase
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
#   1  BLOCKING GATE: all six agent-tier tools install BEHIND the restricted firewall
#   2  db-clients (pg+mysql+mongo) + imagemagick + wkhtmltopdf actually BUILD on noble
#   3  Ruby runtime reconcile: rvm bootstraps, compiles, persists, and resolves
#      in a NON-login shell
#   4  the runtime integration corpus — delegated in full to
#      tests/integration/run.sh. No test logic lives here.
#
# Nothing here touches your real container groups, your images, or your projects:
# every phase uses a throwaway image tag and a throwaway group directory.
set -uo pipefail

REPO="${REPO:-$PWD}"
LOG_PREFIX="[host-verify]"
say() { printf '\n%s %s\n' "$LOG_PREFIX" "$*"; }
sub() { printf '%s   %s\n' "$LOG_PREFIX" "$*"; }

[[ -f "$REPO/build.sh" && -f "$REPO/sandbox.conf" ]] || {
  echo "ERROR: run this from an ai-containers checkout (or set REPO=/path/to/checkout)." >&2
  echo "       In mgd-ai-containers the engine lives in base/ — run it from there." >&2
  exit 2
}

# Layout-tolerant tests dir: upstream ai-containers keeps tests/ next to build.sh;
# mgd-ai-containers keeps the engine in base/ and tests/ one level up, beside it.
# Resolving it here means ONE copy of this script serves both repos verbatim, which
# is the same reason Phase 3 resolves ~/.rvm through sandbox-common.sh instead of
# hardcoding it — a verifier that drifts from what it verifies is worse than none.
TESTS_DIR="$REPO/tests"
[[ -d "$TESTS_DIR" ]] || TESTS_DIR="$REPO/../tests"

# Phase selection, so iterating on one failing phase does not re-pay for the others
# (Phase 1 alone runs a full six-tool network install). Phase 0 is always cheap and
# always runs.  PHASES="3" bash verify-on-host.sh
PHASES="${PHASES:-1 2 3 4}"
want_phase() { case " $PHASES " in (*" $1 "*) return 0 ;; (*) return 1 ;; esac; }

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

# ── Phase 1: BLOCKING GATE — six tools install behind the restricted firewall ────
# IMPORTANT: the firewall allowlist is assembled AT BUILD TIME from the sandbox.conf
# keys that are ON. Your sandbox.conf has only copilot+claude-code ON, so an image
# built from it does NOT allowlist codex/gemini/graphify/vale — the gate would fail
# for the wrong reason. So build against a temporary all-six-ON config via the
# SANDBOX_CONF override hook (sandbox-common.sh:32). Your real sandbox.conf is never
# touched.
# The phase bodies below are guarded but deliberately NOT re-indented, so the
# selector shows up as a two-line diff per phase instead of reflowing the script.
if want_phase 1; then
say "PHASE 1 — BLOCKING GATE: agent-tier tools install behind the restricted firewall"
SMOKE_CONF="$(mktemp -t smokeconf)"
sed -E 's/^(copilot|claude-code|codex|gemini|graphify|vale)=.*/\1=ON/' "$REPO/sandbox.conf" > "$SMOKE_CONF"
sub "temp config: $(grep -cE '^(copilot|claude-code|codex|gemini|graphify|vale)=ON' "$SMOKE_CONF") of 6 agent-tier keys forced ON"

sub "building ai-sandbox-smoke (expect 15-40 min on first run; heavy toolchains are OFF in your conf)…"
if SANDBOX_CONF="$SMOKE_CONF" IMAGE_NAME=ai-sandbox-smoke "$REPO/build.sh" ai-sandbox-smoke >/tmp/smoke-build.log 2>&1; then
  sub "build OK"
  sub "allowlisted tool domains in the image config:"
  for d in registry.npmjs.org api.anthropic.com pypi.org files.pythonhosted.org vale.sh github.com; do
    printf '%s     %-28s %s\n' "$LOG_PREFIX" "$d" \
      "$(grep -qxF "$d" "$REPO/allowlist-domains.txt" && echo present || echo MISSING)"
  done
  # SMOKE_SKIP_BUILD=1: reuse the image we just built with the right allowlist.
  AGENT_TOOLS_SMOKE=1 SMOKE_IMAGE=ai-sandbox-smoke SMOKE_SKIP_BUILD=1 SMOKE_KEEP=1 \
    bash "$TESTS_DIR/test-agent-tools-smoke.sh" 2>&1 | sed "s/^/$LOG_PREFIX   /"
  sub "PHASE 1 exit: ${PIPESTATUS[0]:-?}"
else
  sub "BUILD FAILED — last 40 lines:"
  tail -40 /tmp/smoke-build.log | sed "s/^/$LOG_PREFIX     /"
fi
fi

# ── Phase 2: db-clients + imagemagick + wkhtmltopdf build on the noble base ──────
# The wkhtmltopdf layer installs a JAMMY .deb on an ubuntu:24.04 (noble) base and
# pre-installs libjpeg-turbo8 etc. That combination was never built here, so it is
# the other unverified item. Build ONLY these layers by using a minimal config.
if want_phase 2; then
say "PHASE 2 — db-clients (pg,mysql,mongo) + imagemagick + wkhtmltopdf build on noble"
NATIVE_CONF="$(mktemp -t nativeconf)"
sed -E 's/^(copilot|claude-code|codex|gemini|graphify|vale|kiro|qmd)=.*/\1=OFF/;
        s/^db-clients=.*/db-clients=pg,mysql,mongo/;
        s/^imagemagick=.*/imagemagick=ON/;
        s/^wkhtmltopdf=.*/wkhtmltopdf=ON/' "$REPO/sandbox.conf" > "$NATIVE_CONF"
if SANDBOX_CONF="$NATIVE_CONF" IMAGE_NAME=ai-sandbox-native "$REPO/build.sh" ai-sandbox-native >/tmp/native-build.log 2>&1; then
  sub "build OK — verifying the tools actually run:"
  docker run --rm --entrypoint bash ai-sandbox-native -lc '
    for c in psql mysql mongosh convert wkhtmltopdf gcc; do
      printf "  %-12s " "$c"; command -v "$c" >/dev/null && "$c" --version 2>&1 | head -1 || echo MISSING
    done' 2>&1 | sed "s/^/$LOG_PREFIX   /"
  docker rmi ai-sandbox-native >/dev/null 2>&1 || true
else
  sub "BUILD FAILED — last 40 lines (this is the jammy-deb-on-noble risk):"
  tail -40 /tmp/native-build.log | sed "s/^/$LOG_PREFIX     /"
fi
fi

# ── Phase 3: Ruby runtime reconcile ─────────────────────────────────────────────
# Proves: rvm bootstraps into the group's ~/.rvm behind the firewall, compiles the
# requested Ruby, the default is linked onto /usr/local/bin (so a NON-login
# `docker exec` resolves it), and a second run reuses it with no recompile.
#
# ~/.rvm is a docker NAMED VOLUME, and the volume name comes from the SAME helper
# sandbox.sh uses (rvm_volume_ensure), sourced from sandbox-common.sh rather than
# hardcoded here. That matters: this phase drives `docker run` directly instead of
# going through sandbox.sh, so an independently-written mount here would keep
# passing (or failing) against a path the product no longer takes — which is
# exactly what happened when it kept bind-mounting ~/.rvm after the fix landed.
if want_phase 3; then
say "PHASE 3 — Ruby runtime reconcile (rvm bootstrap + compile + non-login resolve)"
RUBY_CONF="$(mktemp -t rubyconf)"
sed -E 's/^(copilot|claude-code|codex|gemini|graphify|vale|kiro|qmd)=.*/\1=OFF/;
        s/^ruby=.*/ruby=3.4.5/' "$REPO/sandbox.conf" > "$RUBY_CONF"
if SANDBOX_CONF="$RUBY_CONF" IMAGE_NAME=ai-sandbox-ruby "$REPO/build.sh" ai-sandbox-ruby >/tmp/ruby-build.log 2>&1; then
  sub "build OK — starting a restricted container (first Ruby compile takes several minutes)…"
  RVMGROUP="hostverify-ruby-$$"
  # Under $HOME but NOT under ~/.ai-containers/. Both constraints are load-bearing:
  #   * not in ~/.ai-containers/ — a throwaway group directory there is
  #     indistinguishable from a real one, so every failed run left a
  #     "hostverify-ruby-<pid>" entry in `./group.sh list` to puzzle over;
  #   * under $HOME — this directory is a BIND-MOUNT SOURCE (the blocked-capture
  #     output below), and on macOS the VM only shares $HOME. `mktemp -d` lands in
  #     $TMPDIR (/var/folders/...), which Colima does NOT share: the mount then
  #     silently resolves inside the VM, the container writes there happily, and the
  #     host reads an empty directory — which this script reported as
  #     "capture DID NOT START", a flatly wrong conclusion about a healthy daemon.
  GRPDIR="$HOME/.cache/ai-containers-verify/hostverify-ruby-$$"
  mkdir -p "$GRPDIR"
  # Same helper sandbox.sh calls — creates the labeled volume (and would migrate a
  # legacy bind-mounted ~/.rvm, of which a throwaway group has none).
  RVMVOL="$(cd "$REPO" && SANDBOX_CONF="$RUBY_CONF" bash -c \
      'source ./sandbox-common.sh; rvm_volume_ensure "$1" "$2" ai-sandbox-ruby' \
      _ "$RVMGROUP" "$GRPDIR" 2>/dev/null)"
  if [[ -z "$RVMVOL" ]]; then
    sub "ERROR: could not resolve/create the rvm volume — aborting phase 3."
    RVMVOL=""
  fi
  sub "rvm home: docker volume $RVMVOL (NOT a bind mount — that is the fix)"
  # Bind-mount the blocked-traffic capture dir out to the host. Without it the
  # restricted firewall's blocked-domains.txt dies with the --rm container, and a
  # bootstrap failure gives you "network unreachable" with no idea WHICH host was
  # dropped — which is exactly what happened on the first run of this script.
  BLK="$GRPDIR/blocked"; mkdir -p "$BLK"
  # Prove the bind mount is actually shared with the VM BEFORE drawing conclusions
  # from what is (or is not) in it. A host path the VM does not share mounts as a
  # VM-local directory: writes succeed inside the container and are invisible here,
  # so an empty $BLK means either "nothing was written" or "we cannot see it" — and
  # this script confidently reported the second as the first.
  BLK_VISIBLE=1
  docker run --rm -v "$BLK:/probe" --entrypoint bash ai-sandbox-ruby \
    -c 'touch /probe/.mount-check' >/dev/null 2>&1 || true
  if [[ -f "$BLK/.mount-check" ]]; then
    rm -f "$BLK/.mount-check"
  else
    BLK_VISIBLE=0
    sub "WARNING: $BLK is not shared with the Docker VM — blocked-capture output"
    sub "         will be invisible here. Treat capture results below as UNKNOWN."
  fi
  cid="$(docker run -di --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
      -e DEV_CONTAINER_MODE=restricted -e RUBY_VERSIONS=3.4.5 \
      -e SANDBOX_UID="$(id -u)" -e SANDBOX_GID="$(id -g)" \
      -e SANDBOX_USER="$(id -un)" -e SANDBOX_GROUP="$(id -gn)" \
      -v "$RVMVOL:/home/$(id -un)/.rvm" -v "$BLK:/workspace/.agent-blocked" ai-sandbox-ruby)"
  # Poll until ruby resolves, the container dies, OR the reconcile reports it is
  # done/failed — a failed bootstrap exits in seconds, so without that last check
  # this loop burned the full 30 minutes waiting for a compile that never started.
  for i in $(seq 1 90); do
    docker exec "$cid" bash -c 'command -v ruby >/dev/null' 2>/dev/null && break
    docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true || break
    docker logs "$cid" 2>&1 | grep -qE '\[rvm-reconcile\] (done\.|FAILED:)' && break
    sleep 20
  done
  sub "non-login resolve (this is what link-default-ruby.sh exists for):"
  # Resolving is not the same as RUNNING: rvm rewrites gem binstub shebangs to
  # `#!/usr/bin/env ruby_executable_hooks`, so `bundle` can be perfectly linked and
  # still die on exec. On any failure, dump the link target and the shebang — that
  # is the whole diagnosis, and printing MISSING alone hid it once already.
  docker exec "$cid" bash -c '
    for c in ruby gem bundle bundler rake; do
      printf "  %-8s " "$c"
      if ! command -v "$c" >/dev/null 2>&1; then echo "NOT ON PATH"; continue; fi
      if out="$("$c" --version 2>&1 | head -1)"; then
        echo "$out"
      else
        p="$(command -v "$c")"
        echo "PRESENT BUT FAILED TO RUN"
        printf "             path:    %s -> %s\n" "$p" "$(readlink -f "$p" 2>/dev/null)"
        printf "             shebang: %s\n" "$(head -1 "$(readlink -f "$p")" 2>/dev/null)"
        printf "             error:   %s\n" "$out"
      fi
    done' 2>&1 | sed "s/^/$LOG_PREFIX   /"
  # rvm warns that /etc/profile.d/rvm.sh "causes you to have umask g+w set in your
  # shell". That check is a heuristic (it greps for rvm_stored_umask) and never
  # measures anything, so measure it here instead of trusting either side. 0022 is
  # the expected value; anything group-writable (e.g. 0002) would be a real finding.
  sub "umask in the container (rvm claims its loader forces g+w — verify, don't trust):"
  docker exec "$cid" bash -lc 'printf "  login shell:      %s\n" "$(umask)"' 2>&1 | sed "s/^/$LOG_PREFIX   /"
  docker exec "$cid" bash -c  'printf "  non-login shell:  %s\n" "$(umask)"' 2>&1 | sed "s/^/$LOG_PREFIX   /"
  sub "reconcile log:"
  docker logs "$cid" 2>&1 | grep -i 'rvm-reconcile\|rvm-installer\|link-default-ruby' | tail -30 | sed "s/^/$LOG_PREFIX     /"
  # What the firewall did during the bootstrap. blocked.log is the AUTHORITATIVE
  # record: log_blocked() returns early after self-healing an allowlisted domain
  # (capture-blocked-traffic.sh:126-131), writing the "(auto-allowed)" line to
  # blocked.log ONLY — never to blocked-domains.txt/blocked-ips.txt. Reading just
  # those two therefore reports "blocked nothing" for traffic that WAS dropped and
  # then admitted, which is the difference between "the firewall is innocent" and
  # "the firewall is involved but recovered".
  # Health FIRST, and judged on the files EXISTING: init_output_files seeds each
  # output file with explanatory header comments, so their mere presence proves the
  # daemon got past startup. That is the check that matters — it silently died there
  # for months, taking self-healing with it.
  if [[ "$BLK_VISIBLE" != "1" ]]; then
    sub "blocked-traffic capture: UNKNOWN — the output mount is not visible from the host"
  elif [[ -f "$BLK/blocked.log" ]]; then
    sub "blocked-traffic capture: RUNNING (daemon reached init_output_files)"
  else
    sub "blocked-traffic capture: DID NOT START — no output files. Diagnostics:"
    for f in tshark-nflog-errors.log tshark-dns-errors.log; do
      if [[ -f "$BLK/$f" ]]; then
        printf '%s     %-26s %s\n' "$LOG_PREFIX" "$f" \
          "$([[ -s "$BLK/$f" ]] && echo "NON-EMPTY (tshark failed)" || echo "empty (tshark started)")"
        [[ -s "$BLK/$f" ]] && head -5 "$BLK/$f" | sed "s/^/$LOG_PREFIX       /"
      else
        printf '%s     %-26s %s\n' "$LOG_PREFIX" "$f" "ABSENT — died before starting tshark"
      fi
    done
  fi

  # What it actually recorded. Every output file is seeded with header COMMENTS, so
  # `-s` (non-empty) is true even when nothing was blocked — that misreported a clean
  # run as "HARD-BLOCKED" and then listed the headers as if they were destinations.
  # Count real entries only. blocked.log stays the authoritative record: log_blocked()
  # returns early after self-healing an allowlisted domain
  # (capture-blocked-traffic.sh:126-131), writing the "(auto-allowed)" line to
  # blocked.log ONLY — never to blocked-domains.txt/blocked-ips.txt.
  entries() { cat "$@" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' || true; }
  hard_blocked="$(entries "$BLK/blocked-domains.txt" "$BLK/blocked-ips.txt" | sort -u)"
  self_healed="$(grep '(auto-allowed)' "$BLK/blocked.log" 2>/dev/null \
                   | awk '{print $NF, $(NF-1)}' | sort -u | head -20)"
  if [[ -n "$hard_blocked" ]]; then
    sub "HARD-BLOCKED by the firewall (never admitted) — add these to the allowlist:"
    printf '%s\n' "$hard_blocked" | sed "s/^/$LOG_PREFIX     /"
  fi
  if [[ -n "$self_healed" ]]; then
    sub "dropped then SELF-HEALED (allowlisted, admitted after the first packet):"
    printf '%s\n' "$self_healed" | sed "s/^/$LOG_PREFIX     /"
  fi
  if [[ -z "$hard_blocked" && -z "$self_healed" ]]; then
    # Only a RUNNING capture can license "nothing was dropped". With a dead daemon
    # the honest answer is that we do not know — conflating the two is what made an
    # earlier run's "firewall blocked nothing" look like evidence when it was not.
    if [[ -f "$BLK/blocked.log" ]]; then
      sub "firewall dropped nothing during the bootstrap"
    else
      sub "what the firewall dropped is UNKNOWN — the capture never ran"
    fi
  fi

  # ── Failure diagnostics ───────────────────────────────────────────────────────
  # Only on failure, and only here: the greps above are a summary, and a summary is
  # exactly what hid the real error last time. Dump the raw log and probe each
  # boundary the bootstrap crosses, so one run identifies the failing component.
  if ! docker exec "$cid" bash -c 'command -v ruby >/dev/null' 2>/dev/null; then
    sub "RUBY MISSING — raw container log (unfiltered, last 60 lines):"
    docker logs "$cid" 2>&1 | tail -60 | sed "s/^/$LOG_PREFIX     /"
    sub "in-container boundary probes (as the sandbox user):"
    docker exec -u "$(id -u):$(id -g)" "$cid" bash -c '
      echo "--- identity ---"; id; echo "HOME=$HOME"
      echo "--- ~/.gnupg (rvm signing keys, seeded from /etc/skel at user setup) ---"
      ls -la "$HOME/.gnupg" 2>&1 | head -5
      gpg --list-keys 2>&1 | head -12
      # Must be a docker volume, not virtiofs. A fresh volume also mounts
      # root-owned, so this doubles as the check on entrypoint chown_rvm_root.
      echo "--- ~/.rvm (docker volume; must be writable by this uid) ---"
      df -h "$HOME/.rvm" 2>&1 | tail -1 | sed "s/^/    fs: /"
      ls -ld "$HOME/.rvm"
      touch "$HOME/.rvm/.writetest" 2>&1 && echo "writable" && rm -f "$HOME/.rvm/.writetest" || echo "NOT WRITABLE"
      echo "--- installer download through the firewall ---"
      curl -fsSL https://get.rvm.io -o /tmp/probe-installer \
        && echo "get.rvm.io OK ($(wc -c </tmp/probe-installer) bytes)" \
        || echo "get.rvm.io FAILED (rc=$?)"
      echo "--- tag resolution (installer needs one of these to answer) ---"
      curl -fsS -o /dev/null -w "  api.github.com %{http_code}\n" https://api.github.com/repos/rvm/rvm/tags \
        || echo "  api.github.com UNREACHABLE"
      curl -fsS -o /dev/null -w "  api.bitbucket.org %{http_code}\n" \
        "https://api.bitbucket.org/2.0/repositories/mpapis/rvm/refs/tags?pagelen=1" \
        || echo "  api.bitbucket.org UNREACHABLE"
      echo "--- disk (a full VM disk fails the unpack, not the download) ---"
      df -h "$HOME/.rvm" / 2>&1 | sed "s/^/  /"
    ' 2>&1 | sed "s/^/$LOG_PREFIX     /"
    KEEP_RUBY_IMAGE=1
  fi
  docker stop "$cid" >/dev/null 2>&1 || true
  sub "second run (must be instant, no recompile):"
  cid2="$(docker run -di --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
      -e DEV_CONTAINER_MODE=restricted -e RUBY_VERSIONS=3.4.5 \
      -e SANDBOX_UID="$(id -u)" -e SANDBOX_GID="$(id -g)" \
      -e SANDBOX_USER="$(id -un)" -e SANDBOX_GROUP="$(id -gn)" \
      -v "$RVMVOL:/home/$(id -un)/.rvm" ai-sandbox-ruby)"
  sleep 45
  docker logs "$cid2" 2>&1 | grep -i 'rvm-reconcile' | tail -8 | sed "s/^/$LOG_PREFIX     /"
  docker stop "$cid2" >/dev/null 2>&1 || true
  # Keep the image, group dir AND volume when Phase 3 failed: re-probing a deleted
  # image costs a rebuild, and a half-written ~/.rvm is itself evidence.
  if [[ "${KEEP_RUBY_IMAGE:-0}" == "1" ]]; then
    sub "Phase 3 FAILED — kept for re-probing:"
    sub "  image:      ai-sandbox-ruby   (docker rmi ai-sandbox-ruby when done)"
    sub "  group dir:  $GRPDIR"
    sub "  rvm volume: $RVMVOL   (./group.sh rm $RVMGROUP removes it)"
  else
    # Exercise the real cleanup path rather than rm -rf'ing behind its back: if
    # group.sh stops removing the volume, this phase is where it should show up.
    # GRPDIR is scratch under ~/.cache, not a group directory, so group.sh only has
    # the volume to remove — drop the directory here regardless of how that went.
    (cd "$REPO" && bash ./group.sh rm "$RVMGROUP" --yes >/dev/null 2>&1) \
      || docker volume rm "$RVMVOL" >/dev/null 2>&1 || true
    rm -rf "$GRPDIR"
    rmdir "$HOME/.cache/ai-containers-verify" 2>/dev/null || true
    if docker volume inspect "$RVMVOL" >/dev/null 2>&1; then
      sub "WARNING: rvm volume $RVMVOL survived cleanup — remove it by hand."
    fi
    docker rmi ai-sandbox-ruby >/dev/null 2>&1 || true
  fi
else
  sub "BUILD FAILED — last 40 lines:"
  tail -40 /tmp/ruby-build.log | sed "s/^/$LOG_PREFIX     /"
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
else
  sub "capabilities detected on this host:"
  bash "$IT_RUNNER" --list-caps 2>&1 | sed "s/^/$LOG_PREFIX     /"
  # No --tags: a human running this locally wants the whole corpus, including
  # the slow and needs-dns cases CI excludes on cost.
  bash "$IT_RUNNER" --require security ${IT_EXTRA_ARGS:-} 2>&1 | sed "s/^/$LOG_PREFIX   /"
  it_rc="${PIPESTATUS[0]:-1}"
  sub "PHASE 4 exit: $it_rc"
  if [[ "$it_rc" -ne 0 ]]; then
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

# :- defaults: a skipped phase never assigned its conf var, and `set -u` would
# abort the cleanup rather than the script finishing normally.
rm -f "${SMOKE_CONF:-}" "${NATIVE_CONF:-}" "${RUBY_CONF:-}" 2>/dev/null || true
say "DONE. Regenerate your real allowlists before your next normal build:  ./build.sh"
say "Leftover throwaway image (kept for re-runs):  docker rmi ai-sandbox-smoke"
