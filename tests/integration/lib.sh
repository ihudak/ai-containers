#!/usr/bin/env bash
# lib.sh — the verbs every integration case uses. SOURCED by a case, never run.
#
# Design rule the whole file follows: assert EFFECT, not configuration. A case
# observes from outside the container — did the packet arrive, does the file
# exist, does the log contain the line. tests/test-entrypoint-wiring.sh asserts
# the capture daemon is WIRED INTO entrypoint.sh, and it passed every single day
# of the outage, because the wiring was correct and the daemon died after being
# started.
#
# Written for bash 3.2 (stock macOS bash): no associative arrays, and empty
# arrays expand as "${a[@]+"${a[@]}"}" because a bare "${a[@]}" aborts under
# set -u on 3.2.

: "${IT_RUN_ID:?lib.sh: run cases through tests/integration/run.sh (IT_RUN_ID unset)}"
: "${IT_IMAGE:?lib.sh: run cases through tests/integration/run.sh (IT_IMAGE unset)}"
: "${IT_NET:?lib.sh: run cases through tests/integration/run.sh (IT_NET unset)}"

IT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IT_REPO_DIR="$(cd "$IT_LIB_DIR/../.." && pwd)"
[[ -f "$IT_REPO_DIR/build.sh" ]] || IT_REPO_DIR="$(cd "$IT_LIB_DIR/../../base" && pwd)"

IT_LABEL="${IT_LABEL:-ai-containers.it-run=$IT_RUN_ID}"
IT_SCRATCH="${IT_SCRATCH:-$HOME/.cache/ai-containers-it/$IT_RUN_ID}"
IT_CONNECT_TIMEOUT="${IT_CONNECT_TIMEOUT:-5}"

# IT_SETTLE floor, not a plain default. run.sh (Task 1, unmodified here) always
# exports its OWN default of 45 before a case's process even starts, so a bare
# "${IT_SETTLE:-60}" fallback below would never fire — by the time lib.sh is
# sourced, IT_SETTLE already has a value. Clamp a too-low value UP instead.
#
# Why 60: measured on ubuntu-latest (task-0/CI probe, 2026-08-06 — see
# docs/superpowers/plans/2026-08-06-integration-test-suite-increment-1.md),
# tshark takes ~22s just to ATTACH to the NFLOG group after the agent shell is
# already up, and that wait stacks on top of sandbox_up's own settle wait for
# the entrypoint→agent-shell handoff. 45s does not leave margin. A case that
# waits only for the agent shell, fires a blocked flow at t≈3s and reads the
# capture output at t≈13s will record NOTHING — not because NFLOG is broken
# (raw tshark on nflog:100 captured 9 dropped packets once given a real
# settle), but because the watcher was not listening yet. Waiting on
# blocked.log/blocked-domains.txt/blocked-ips.txt existing is NOT a substitute
# readiness signal either: capture-blocked-traffic.sh's init_output_files()
# creates those files long before start_blocked_watcher() launches tshark —
# see capture_ready()/sandbox_wait_capture() below, which poll tshark's own
# startup announcement instead. Do NOT "optimise" this floor away.
#
# A caller may still ask for MORE than 60 (e.g. a slower CI runner) by
# exporting IT_SETTLE explicitly; this only raises a too-low value, it never
# lowers a deliberately larger one.
#
# lib.sh is the SINGLE SOURCE of this number — run.sh (Task 1) deliberately
# carries no numeric default of its own (just "${IT_SETTLE:-}", still
# exported); see the comment there. Silently discarding an explicit low value
# would be its own decorative-check bug (a user who set IT_SETTLE=30 to speed
# up a local run deserves to know their run is actually waiting 60s), so a
# raise is never silent.
IT_SETTLE="${IT_SETTLE:-60}"
if [[ "$IT_SETTLE" -lt 60 ]]; then
  printf 'lib.sh: IT_SETTLE=%s is below the tshark-attach floor — raising to 60 (see lib.sh IT_SETTLE comment)\n' \
    "$IT_SETTLE" >&2
  IT_SETTLE=60
fi

IT_SIDECAR=""; IT_SIDECAR_IP=""; IT_CID=""; IT_DNS=""; IT_DNS_IP=""

it_fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; it_fails=$((it_fails + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; exit 77; }
it_finish() { printf '\n%d failure(s)\n' "$it_fails"; exit "$it_fails"; }

# ── Resource tracking ───────────────────────────────────────────────────────────
_it_resources=""
it_track() { _it_resources="${_it_resources}${_it_resources:+ }$1"; }
it_cleanup() {
  local r
  # Diagnostics BEFORE teardown: a failing case that tears down first leaves a
  # human with nothing but the assertion text, which costs a whole round trip.
  if [[ "$it_fails" -gt 0 && -n "$IT_CID" ]]; then it_diagnose "$IT_CID"; fi
  for r in $_it_resources; do
    case "$r" in
      container:*) docker rm -f "${r#container:}" >/dev/null 2>&1 || true ;;
      dir:*)       rm -rf "${r#dir:}" 2>/dev/null || true ;;
    esac
  done
}
trap 'it_cleanup' EXIT

it_scratch() {
  local d="$IT_SCRATCH/case-$$-$RANDOM"
  mkdir -p "$d"; it_track "dir:$d"; printf '%s' "$d"
}

# Poll a condition rather than sleeping a guess.
it_wait() {  # $1=timeout seconds, $2… = command
  local t="$1"; shift
  local i=0
  while [[ "$i" -lt "$t" ]]; do
    "$@" >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

it_strip_comments() { awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }'; }

# ── Allowlist synthesis ─────────────────────────────────────────────────────────
_it_alist() {  # $1=path $2=space-separated entries
  { printf '# synthetic allowlist — written by the integration harness\n'
    printf '# %s\n\n' "$IT_RUN_ID"
    local e
    for e in ${2:-}; do printf '%s\n' "$e"; done
  } > "$1"
}
allowlist_write() {  # $1=dir $2=domains $3=cidrs $4=proxy-domains
  local d="$1"; mkdir -p "$d"
  _it_alist "$d/allowlist-domains.txt"       "${2:-}"
  _it_alist "$d/allowlist-cidrs.txt"         "${3:-}"
  _it_alist "$d/allowlist-proxy-domains.txt" "${4:-}"
  chmod 755 "$d"; chmod 644 "$d"/allowlist-*.txt
}

# ── Sidecar: the controllable destination ───────────────────────────────────────
# node, not python3: the task-0 CI probe found python3 too (pyenv is installed
# unconditionally — the AI agents need it — so /opt/pyenv/shims/python3 exists
# even in a minimal image). But a shim is not a runtime: `command -v python3`
# finds the shim without ever executing it, and a pyenv shim with no configured
# version exits non-zero when actually invoked. The probe only proved node
# RUNS (`node --version` → v24.19.0); it never proved python3 does. node stays
# the sidecar for that reason, not because python3 is absent.
sidecar_up() {
  local name="it-sidecar-$$-$RANDOM"
  docker run -d --name "$name" --network "$IT_NET" --label "$IT_LABEL" \
    --entrypoint node "$IT_IMAGE" \
    -e 'require("http").createServer(function(q,s){s.end("sidecar-ok\n")}).listen(8080,"0.0.0.0")' \
    >/dev/null 2>&1 || { fail "sidecar_up: docker run failed"; return 1; }
  it_track "container:$name"
  if ! it_wait "$IT_SETTLE" docker exec "$name" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080'; then
    fail "sidecar_up: nothing listening on 8080 after ${IT_SETTLE}s"
    docker logs "$name" 2>&1 | tail -20 | sed 's/^/     /'
    return 1
  fi
  IT_SIDECAR="$name"
  IT_SIDECAR_IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$IT_NET\").IPAddress }}" "$name" 2>/dev/null)"
  [[ -n "$IT_SIDECAR_IP" ]] || { fail "sidecar_up: no IP on network $IT_NET"; return 1; }
  return 0
}
sidecar_down() { docker rm -f "${1:-$IT_SIDECAR}" >/dev/null 2>&1 || true; }

# ── DNS sidecar (needs-dns cases only) ──────────────────────────────────────────
# Self-healing correlates a blocked IP to a domain through a map built by
# sniffing real port-53 RESPONSES. --add-host produces no DNS traffic at all, so
# without a real resolver the map stays empty and self-healing can never fire.
dns_up() {  # <fqdn> <ip> [<fqdn> <ip>…]
  local d name="it-dns-$$-$RANDOM" first_fqdn="$1"
  d="$(it_scratch)"
  { printf '.:53 {\n    hosts {\n'
    while [[ $# -ge 2 ]]; do printf '        %s %s\n' "$2" "$1"; shift 2; done
    printf '        fallthrough\n    }\n    errors\n}\n'
  } > "$d/Corefile"
  chmod 644 "$d/Corefile"
  docker run -d --name "$name" --network "$IT_NET" --label "$IT_LABEL" \
    -v "$d/Corefile:/Corefile:ro" "$IT_DNS_IMAGE" -conf /Corefile \
    >/dev/null 2>&1 || { fail "dns_up: docker run failed"; return 1; }
  it_track "container:$name"
  IT_DNS="$name"
  IT_DNS_IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"$IT_NET\").IPAddress }}" "$name" 2>/dev/null)"
  [[ -n "$IT_DNS_IP" ]] || { fail "dns_up: no IP on network $IT_NET"; return 1; }
  # Functional readiness, not a log grep. `docker logs <name>` returns 0 the
  # INSTANT the container exists, whether or not CoreDNS has parsed its
  # Corefile or bound port 53 — the previous `it_wait … docker logs … || true`
  # succeeded on its first check (~0s) and then threw even that result away
  # with `|| true`. It measured nothing. Cases 080/085 take dns_up's success
  # as proof the resolver is ANSWERING and fire the whole self-healing chain
  # through it; a CoreDNS that hasn't finished binding yet would surface
  # there as "the destination is unreachable" — indistinguishable from a real
  # firewall bug, sending someone hunting in the wrong place entirely.
  #
  # So: actually resolve the first registered name against $IT_DNS_IP, using
  # a throwaway container (dnsutils' nslookup ships in $IT_IMAGE). Spawning a
  # container per poll iteration is heavier than a log grep, but it converges
  # in one or two iterations in practice, and it is the difference between a
  # real check and a decorative one. dns_up now genuinely FAILS (returns 1)
  # if the resolver never answers — it no longer swallows that with `|| true`.
  if ! it_wait "$IT_SETTLE" _it_dns_answers "$first_fqdn"; then
    fail "dns_up: $IT_DNS_IP never answered $first_fqdn after ${IT_SETTLE}s"
    docker logs "$name" 2>&1 | tail -20 | sed 's/^/     /'
    return 1
  fi
  return 0
}
_it_dns_answers() {  # $1=fqdn — 0 iff $IT_DNS_IP actually resolves it
  docker run --rm --network "$IT_NET" --label "$IT_LABEL" \
    --entrypoint nslookup "$IT_IMAGE" -timeout=2 -retry=1 "$1" "$IT_DNS_IP" \
    >/dev/null 2>&1
}

# ── The sandbox under test ──────────────────────────────────────────────────────
sandbox_up() {  # $1=mode $2=allowlist dir; remaining args go to docker run
  local mode="$1" adir="$2"; shift 2
  local caps=""
  case "$mode" in
    restricted|discovery) caps="--cap-add=NET_ADMIN --cap-add=NET_RAW" ;;
    open)                 caps="" ;;   # sandbox.sh passes NO capabilities here
    *) fail "sandbox_up: unknown mode '$mode'"; return 1 ;;
  esac
  local cid
  cid="$(docker run -di --network "$IT_NET" --label "$IT_LABEL" $caps \
      -v "$adir:/it-allowlists:ro" \
      -e DEV_CONTAINER_MODE="$mode" \
      -e ALLOWLIST_DOMAINS_FILE=/it-allowlists/allowlist-domains.txt \
      -e ALLOWLIST_CIDRS_FILE=/it-allowlists/allowlist-cidrs.txt \
      -e ALLOWLIST_PROXY_DOMAINS_FILE=/it-allowlists/allowlist-proxy-domains.txt \
      -e SANDBOX_UID=1000 -e SANDBOX_GID=1000 \
      -e SANDBOX_USER=itsandbox -e SANDBOX_GROUP=itsandbox \
      -e ALLOW_IPV6_BYPASS=1 \
      "$@" "$IT_IMAGE" 2>&1)" || { fail "sandbox_up($mode): docker run failed: $cid"; return 1; }
  it_track "container:$cid"
  # Ready means the entrypoint finished and handed PID 1 to the agent shell:
  # it starts as root and becomes uid 1000 only after `exec capsh --user=`.
  # Anything weaker races the firewall setup and the capture daemon start.
  if ! it_wait "$IT_SETTLE" _it_pid1_is_sandbox "$cid"; then
    fail "sandbox_up($mode): entrypoint never handed over to the agent shell"
    docker logs "$cid" 2>&1 | tail -40 | sed 's/^/     /'
    return 1
  fi
  IT_CID="$cid"
  return 0
}
_it_pid1_is_sandbox() {
  [[ "$(docker exec "$1" awk '/^Uid:/{print $2; exit}' /proc/1/status 2>/dev/null | tr -dc '0-9')" == "1000" ]]
}
sandbox_exec() { docker exec "$1" bash -c "$2"; }
sandbox_down() { docker rm -f "${1:-$IT_CID}" >/dev/null 2>&1 || true; }

# ── Capture readiness (restricted/discovery only — open mode starts no daemon) ──
# capture_ready is the PURE predicate: tshark announces "Capturing on '<iface>'"
# to stderr the moment it actually attaches, and capture-blocked-traffic.sh
# redirects that stderr to tshark-nflog-errors.log (see capture_dir there). This
# is the ONLY reliable readiness signal — see the IT_SETTLE comment above for
# why waiting on blocked.log/blocked-domains.txt/blocked-ips.txt existing is
# NOT sufficient (they are created by init_output_files() long before
# start_blocked_watcher() launches tshark).
capture_ready() {  # $1=cid
  docker exec "$1" grep -q 'Capturing on' /workspace/.agent-blocked/tshark-nflog-errors.log 2>/dev/null
}
# sandbox_wait_capture is the opt-in wait, kept SEPARATE from sandbox_up so
# sandbox_up's signature — sandbox_up <mode> <allowlist-dir> [docker-run-args…]
# — stays stable for every later task that passes extra docker run args
# through it. Any case that generates traffic meant to be BLOCKED-AND-LOGGED
# (not just blocked) must call this after sandbox_up and before firing traffic,
# or it races tshark's own ~22s startup and silently observes nothing.
sandbox_wait_capture() {  # $1=cid
  if ! it_wait "$IT_SETTLE" capture_ready "$1"; then
    fail "sandbox_wait_capture: NFLOG watcher never attached after ${IT_SETTLE}s"
    docker exec "$1" cat /workspace/.agent-blocked/tshark-nflog-errors.log 2>&1 | tail -20 | sed 's/^/     /'
    return 1
  fi
  return 0
}

# ── The real launcher under test (mounts / groups / volumes tiers) ─────────────
#
# sandbox_up above composes its OWN `docker run`. That is right for the network
# tier — it isolates the entrypoint from the launcher — and exactly wrong for
# mounts, groups and volumes, where every decision belongs to sandbox.sh.
# Reproducing that logic here would test the reproduction.
#
# So launcher_* drives the REAL sandbox.sh, through tests/integration/docker-shim.sh
# (read its header for how the container under test is identified). The two verbs
# answer different questions and the split is deliberate:
#
#   sandbox_up   — does the IMAGE honour this configuration?
#   launcher_up  — does SANDBOX.SH produce that configuration from this env?
#
# Resolved BEFORE any shim reaches PATH, and passed down explicitly: the shim
# refuses to run without it rather than risk recursing into itself.
IT_REAL_DOCKER="${IT_REAL_DOCKER:-$(command -v docker 2>/dev/null)}"

# The docker ENDPOINT, resolved the same way and for the same reason: launcher_run
# and launcher_script (below) redirect HOME to a per-case scratch directory to
# isolate group state, but the docker CLI resolves which daemon to talk to from
# $HOME/.docker/config.json's currentContext (and $HOME/.docker/contexts/) —
# redirecting HOME throws that away. On a host where the daemon really does sit
# at the CLI's built-in default (unix:///var/run/docker.sock) this is invisible;
# on macOS + Colima, which supplies its endpoint ONLY through the active
# context, every docker call made from inside a HOME-redirected subshell —
# sandbox.sh's/group.sh's/repo.sh's own, and the shim's `exec $IT_REAL_DOCKER`
# — fails to connect. Linux CI never sees this because /var/run/docker.sock
# genuinely exists there.
#
# DOCKER_HOST, not DOCKER_CONFIG. Pointing DOCKER_CONFIG at the developer's
# real ~/.docker instead would also fix this, and would additionally carry TLS
# material and credential-helper config for an endpoint that needs them — but
# it reintroduces the developer's real state into a harness whose whole point
# is per-case HOME isolation (a case's sandbox.sh run should not see the
# developer's own docker config any more than it should see their real
# ~/.claude). Colima's endpoint is a plain unix socket: no TLS, no stored
# credentials. DOCKER_HOST — one string, carrying nothing sensitive — covers
# that, and is the narrowest fix that does. A future endpoint that genuinely
# needs client certs or a credential helper would need DOCKER_CONFIG (or an
# explicit cert/key triplet); nothing this suite targets today does.
#
# An already-exported DOCKER_HOST wins outright: a caller who set it on
# purpose (e.g. pointing at a remote daemon) knows better than a context
# lookup. Resolution failure — no `docker context` subcommand, docker missing
# entirely, or a template result of "<no value>" (Go's own empty-field
# marker) — must leave IT_DOCKER_HOST EMPTY, never a fabricated string: the
# call sites below only ever export DOCKER_HOST when this is non-empty, so an
# empty value here means "do not touch DOCKER_HOST at all", the honest
# fallback. Exporting an empty DOCKER_HOST would be worse than exporting
# nothing — it overrides the CLI's own built-in default just as effectively as
# a wrong one.
#
# Resolved ONCE per run, not once per case: run.sh resolves this exact block
# itself (near its own execution loop, deliberately AFTER its --list/
# --list-caps early-exit paths — see the comment there for why) and exports
# IT_DOCKER_HOST — even to an empty string when resolution finds nothing, so
# `${IT_DOCKER_HOST+x}` below reads it as already-decided. `docker context
# inspect` is a real subprocess call, unlike IT_REAL_DOCKER's cheap `command
# -v`, so a run through run.sh must reach this block AT MOST once, not once
# per case's `bash "$f"`. The `[[ -z "${IT_DOCKER_HOST+x}" ]]` guard is what
# makes that true: it tests IS-SET, not IS-NON-EMPTY (the same "set-but-empty
# still counts as set" convention sandbox-common.sh's load_env_defaults uses),
# so run.sh's export short-circuits this whole block — no docker subprocess,
# even a failed one — for every case in the run. The fallback here only fires
# for a case executed standalone, outside run.sh. A developer who switches
# docker context mid-run gets a stale value until their next run — accepted,
# the same tradeoff IT_REAL_DOCKER already makes for the docker binary path.
if [[ -z "${IT_DOCKER_HOST+x}" ]]; then
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    IT_DOCKER_HOST="$DOCKER_HOST"
  else
    IT_DOCKER_HOST="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
    case "$IT_DOCKER_HOST" in *'<no value>'*) IT_DOCKER_HOST="" ;; esac
  fi
fi

IT_LAUNCH_HOME=""; IT_LAUNCH_DIR=""; IT_SHIM_DIR=""
IT_LAUNCH_NAME=""; IT_LAUNCH_RC=0; IT_LAUNCH_OUT=""; IT_LAUNCH_ERR=""
# The identity sandbox.sh will hand the container. Not a hardcoded 1000: the
# launcher passes `id -u`/`id -g` (or the SANDBOX_UID/GID override), so a CI
# runner whose user is 1001 must be waited for, and written as, at 1001.
IT_LAUNCH_UID="${SANDBOX_UID:-$(id -u)}"
IT_LAUNCH_GID="${SANDBOX_GID:-$(id -g)}"
# Where the group's dotfile dirs land inside the container. The same expression
# sandbox.sh uses for dev_home, so a case never hardcodes a username.
IT_LAUNCH_HOME_IN="/home/${SANDBOX_USER:-$(id -un)}"

# Creates the scratch $HOME, launch dir and shim dir this case's launcher runs
# in. Idempotent — a case that needs to seed the group tree calls it first, then
# writes under $IT_LAUNCH_HOME, then calls launcher_up.
launcher_prepare() {
  [[ -n "$IT_SHIM_DIR" ]] && return 0
  if [[ -z "$IT_REAL_DOCKER" || ! -x "$IT_REAL_DOCKER" ]]; then
    fail "launcher_prepare: cannot resolve the real docker binary [${IT_REAL_DOCKER:-<empty>}]"
    return 1
  fi
  local d; d="$(it_scratch)"
  IT_LAUNCH_HOME="$d/home"; IT_LAUNCH_DIR="$d/launch"; IT_SHIM_DIR="$d/bin"
  mkdir -p "$IT_LAUNCH_HOME/.ai-containers" "$IT_LAUNCH_DIR" "$IT_SHIM_DIR"
  ln -sf "$IT_LIB_DIR/docker-shim.sh" "$IT_SHIM_DIR/docker"
  launcher_conf || return 1
  return 0
}

# The sandbox.conf the launcher will read. Minimal by default — see
# minimal-conf.sh for why a case must never inherit the developer's own conf.
# Call again with overrides to switch one component back on:
#     launcher_conf claude-code=ON
launcher_conf() {  # $*=key=value overrides (the variant's are added first, automatically)
  local f="$IT_LAUNCH_HOME/sandbox.conf"
  # $IT_VARIANT_OVERRIDES comes FIRST so a case's own argument for the same key
  # wins — minimal-conf.sh applies overrides in order. A case never has to state
  # the variant's overrides, which is the point: it cannot forget them, and the
  # image config and the launcher config cannot drift apart.
  bash "$IT_LIB_DIR/minimal-conf.sh" "$IT_REPO_DIR/sandbox.conf" \
      ${IT_VARIANT_OVERRIDES:-} "$@" > "$f" \
    || { fail "launcher_conf: could not derive a minimal sandbox.conf"; return 1; }
  export SANDBOX_CONF="$f"
  return 0
}

# Run sandbox.sh once. Sets IT_LAUNCH_RC / _OUT / _ERR / _NAME. Does NOT require
# the launch to succeed — case 420 asserts a REFUSED launch, and needs the rc.
launcher_run() {  # $1=mode [$2=primary]
  launcher_prepare || return 1
  local mode="$1" primary="${2:-}" k
  # A developer's exported EXTRA_MOUNTS, or a sandbox.env sitting in the repo,
  # must not perturb a case. sandbox-common.sh's load_env_defaults treats
  # SET-BUT-EMPTY as set (`[[ -n "${!key+x}" ]] && continue`), so exporting
  # empty is precisely the neutraliser it already honours — and only for keys
  # this case did not set itself.
  for k in EXTRA_MOUNTS REPOS VAULT_PATH SPECS_PATH DOCS_PATH PREVIEW_PORTS \
           SANDBOX_MODE SANDBOX_WORKDIR SANDBOX_ENV_FILE SELF_HEALING_ENABLED; do
    [[ -n "${!k+x}" ]] || export "$k="
  done
  IT_LAUNCH_NAME="it-launch-$$-$RANDOM"
  IT_LAUNCH_OUT="$IT_SCRATCH/$IT_LAUNCH_NAME.out"
  IT_LAUNCH_ERR="$IT_SCRATCH/$IT_LAUNCH_NAME.err"
  (
    cd "$IT_LAUNCH_DIR" || exit 1
    export PATH="$IT_SHIM_DIR:$PATH"
    export HOME="$IT_LAUNCH_HOME"
    # See the IT_DOCKER_HOST comment above (by IT_REAL_DOCKER) for the full
    # reasoning. Conditional on purpose: an empty IT_DOCKER_HOST means
    # resolution failed or found nothing to say, and exporting DOCKER_HOST=""
    # in that case would override the docker CLI's own built-in default —
    # worse than leaving DOCKER_HOST unexported entirely.
    [[ -n "$IT_DOCKER_HOST" ]] && export DOCKER_HOST="$IT_DOCKER_HOST"
    export IT_REAL_DOCKER IT_LAUNCH_NAME IT_LABEL
    export IMAGE_NAME="$IT_IMAGE"
    export AI_CONTAINER_GROUP_INIT="${AI_CONTAINER_GROUP_INIT:-clean}"
    exec bash "$IT_REPO_DIR/sandbox.sh" "$mode" ${primary:+"$primary"}
  ) >"$IT_LAUNCH_OUT" 2>"$IT_LAUNCH_ERR" </dev/null
  IT_LAUNCH_RC=$?
  return 0
}

# Run one of the repo's OTHER host scripts (group.sh, repo.sh) in the same
# sandboxed environment a launcher run gets: scratch HOME, run-scoped volume
# prefix, shim on PATH. Sets IT_SCRIPT_RC / IT_SCRIPT_OUT.
#
# IT_LAUNCH_NAME is deliberately NOT exported here — these scripts start no
# container under test, and a stray --name would collide the moment two of them
# ran in one case.
IT_SCRIPT_RC=0; IT_SCRIPT_OUT=""
launcher_script() {  # $1=script basename $2…=args
  launcher_prepare || return 1
  local s="$1"; shift
  IT_SCRIPT_OUT="$IT_SCRATCH/script-$$-$RANDOM.out"
  (
    cd "$IT_LAUNCH_DIR" || exit 1
    export PATH="$IT_SHIM_DIR:$PATH"
    export HOME="$IT_LAUNCH_HOME"
    # Same reasoning as launcher_run above: group.sh/repo.sh shell out to
    # docker too, and lose the real context the instant HOME is redirected.
    [[ -n "$IT_DOCKER_HOST" ]] && export DOCKER_HOST="$IT_DOCKER_HOST"
    export IT_REAL_DOCKER IT_LABEL
    export IMAGE_NAME="$IT_IMAGE"
    exec bash "$IT_REPO_DIR/$s" "$@"
  ) >"$IT_SCRIPT_OUT" 2>&1 </dev/null
  IT_SCRIPT_RC=$?
  return 0
}
docker_volume_exists() { docker volume inspect "$1" >/dev/null 2>&1; }
assert_volume_exists() {  # $1=volume
  if docker_volume_exists "$1"; then pass "volume exists: $1"; else fail "volume exists: $1"; fi
}
assert_volume_absent() {  # $1=volume
  if docker_volume_exists "$1"; then fail "volume removed: $1 — it STILL EXISTS"
  else pass "volume removed: $1"; fi
}

launcher_up() {  # $1=mode [$2=primary] → IT_CID
  launcher_run "$@" || return 1
  if [[ "$IT_LAUNCH_RC" -ne 0 ]]; then
    fail "launcher_up($1): sandbox.sh exited $IT_LAUNCH_RC"
    tail -20 "$IT_LAUNCH_ERR" | sed 's/^/     /'
    return 1
  fi
  it_track "container:$IT_LAUNCH_NAME"
  if ! it_wait "$IT_SETTLE" _it_pid1_is_uid "$IT_LAUNCH_NAME" "$IT_LAUNCH_UID"; then
    fail "launcher_up($1): entrypoint never handed over to the agent shell (uid $IT_LAUNCH_UID)"
    docker logs "$IT_LAUNCH_NAME" 2>&1 | tail -40 | sed 's/^/     /'
    return 1
  fi
  IT_CID="$IT_LAUNCH_NAME"
  return 0
}
# /proc/1/status, and only status. `capsh --user=` setuids away from root, which
# clears the process's DUMPABLE flag, so /proc/1 becomes ROOT-OWNED and most of
# what is under it — notably `cwd`, `exe`, `environ` — needs CAP_SYS_PTRACE,
# which Docker's default capability set does not grant. `status` is
# world-readable regardless, which is why this check works where a
# `readlink /proc/1/cwd` returns nothing useful (see case 410).
_it_pid1_is_uid() {  # $1=cid $2=expected uid
  [[ "$(docker exec "$1" awk '/^Uid:/{print $2; exit}' /proc/1/status 2>/dev/null | tr -dc '0-9')" == "$2" ]]
}

# Runs as the AGENT user, never root — and every writability assertion depends
# on that. `docker exec` defaults to root, and root writes straight through an
# ownership mistake, so a :rw mount left owned by root would look perfectly
# healthy. (A :ro mount refuses even root with EROFS, so that half would pass
# either way; using one primitive for both removes the asymmetry rather than
# leaving a reader to work out which assertions are trustworthy.)
agent_exec() {  # $1=cid $2=command
  docker exec -u "$IT_LAUNCH_UID:$IT_LAUNCH_GID" "$1" bash -c "$2"
}

# Same identity as agent_exec, but a LOGIN shell (`-l`), for the one class of
# check that genuinely needs one: anything that depends on /etc/profile.d
# being sourced — rvm above all (its scripts/cd hook, which is what makes
# `.ruby-version` selection work, is only registered by a login shell; see
# case 750's header for the live-reproduced trace). Plain agent_exec is
# deliberately non-login (see its own comment / case 700), so this is a
# separate helper rather than a flag on agent_exec, to keep that non-login
# contract obviously true by reading the function body alone.
#
# Root cause of the bug this helper exists to prevent (see task-14a report):
# a bare `docker exec` — no `-u` — runs as ROOT, whose $HOME (e.g. /root) has
# no .rvm, so /etc/profile.d/rvm.sh's own `[ -s "$HOME/.rvm/scripts/rvm" ]`
# guard is false and the rvm function is never defined at all. rvm lives in
# the SANDBOX USER's $HOME/.rvm (rvm-reconcile.sh runs via `runuser -u
# "$sandbox_user"`, never as root), so only a login shell running AS that uid
# sources a working rvm. Root is not "missing a login shell" here — it is the
# wrong user entirely, and no amount of `-l` fixes that on its own.
agent_exec_login() {  # $1=cid $2=command
  docker exec -u "$IT_LAUNCH_UID:$IT_LAUNCH_GID" "$1" bash -lc "$2"
}

# ── Repo registry fixtures (mounts / volumes tiers) ────────────────────────────
#
# Cases write registry records directly instead of calling `repo.sh add`, which
# would build the ai-containers-seed image and clone over the network for what
# is, at this level, one line of registry and one volume. The records are the
# exact shape repo.sh writes (name|type|source|added|synced|backend), so
# sandbox.sh cannot tell the difference — repo.sh's own seeding path is covered
# by tests/test-repo-registry.sh.
#
# REPO_VOLUME_PREFIX is scoped to the run, and that is a SAFETY property, not
# tidiness: without it a fixture named "app" would be `ai-containers-repo-app`
# — the same volume as the "app" a developer has been working in all week, which
# the runner's sweep would then delete. With it, the fixture is
# `it-<run-id>-repo-app` and cannot collide with anything real.
fixture_scope_init() {
  export REPO_VOLUME_PREFIX="it-$IT_RUN_ID"
  launcher_prepare || return 1
  : > "$IT_LAUNCH_HOME/.ai-containers/repos.conf"
  return 0
}
repo_registry_add() {  # $1=name $2=source $3=backend
  printf '%s|path|%s|0|0|%s\n' "$1" "$2" "$3" >> "$IT_LAUNCH_HOME/.ai-containers/repos.conf"
}
# A bind-backed repo: what `auto` resolves to on Linux for a path source.
repo_register_bind() {  # $1=name → creates the dir, seeds MARKER, registers it
  local d="$IT_LAUNCH_HOME/repos/$1"
  mkdir -p "$d" && printf '%s\n' "marker-$1" > "$d/MARKER" || { fail "repo_register_bind($1): setup"; return 1; }
  repo_registry_add "$1" "$d" bind
}
# A volume-backed repo: what macOS always uses, and what :rwcopy requires.
# Seeded and chowned to the launch identity exactly as repo.sh's seeding step
# does — a root-owned volume would make every write assertion fail for an
# unrelated reason and send someone hunting for a mount bug.
repo_register_volume() {  # $1=name
  local vol="it-$IT_RUN_ID-repo-$1"
  docker volume create --label "$IT_LABEL" "$vol" >/dev/null 2>&1 \
    || { fail "repo_register_volume($1): docker volume create failed"; return 1; }
  docker run --rm --label "$IT_LABEL" -v "$vol:/v" --entrypoint bash "$IT_IMAGE" \
    -c "printf 'marker-%s\n' '$1' > /v/MARKER && chown -R $IT_LAUNCH_UID:$IT_LAUNCH_GID /v" \
    >/dev/null 2>&1 \
    || { fail "repo_register_volume($1): seeding the volume failed"; return 1; }
  repo_registry_add "$1" "/fixture/$1" volume
}
repo_fixture_volume_name() { printf 'it-%s-repo-%s' "$IT_RUN_ID" "$1"; }

# ── Ruby-case helpers (packages tier) ───────────────────────────────────────────
# rvm_volume_name (sandbox-common.sh) derives the rvm volume from
# $REPO_VOLUME_PREFIX, which fixture_scope_init above already scopes to
# it-$IT_RUN_ID — so the rvm volume for a given AI_CONTAINER_GROUP name is
# ALREADY shared across every case in one run, and the volume does the warming
# implicitly: the first case to launch this group pays the rvm bootstrap and
# compile, every later one in the same run reuses it instantly. run.sh runs
# cases serially, so there is no concurrency for a flock to guard — a lock with
# nothing to guard against is a lock that gets maintained forever for no reason.
#
# 740-ruby-bootstraps-and-resolves deliberately uses its OWN group instead of
# this one: bootstrapping from cold is the thing IT tests, and a warm shared
# volume would make it assert nothing.
IT_RUBY_GROUP="${IT_RUBY_GROUP:-itruby}"

# The two halves of readiness, kept as SEPARATE predicates on purpose. Both are
# decided from captured log text (stdin), never from a live container, which is
# what makes them hermetically testable in tests/test-integration-lib.sh with no
# daemon involved — ruby_wait_ready below is the only piece that actually needs
# docker, and it is a thin polling shell around these two.
#
# _ruby_reconcile_done: has the reconcile REACHED A TERMINAL LINE at all. A
# failed bootstrap exits in seconds; if readiness polled only for `ruby` landing
# on PATH, a failed compile would never satisfy it and the wait would burn its
# entire timeout (up to 30 minutes) on a reconcile that died at second 10.
# rvm-reconcile.sh's own terminal lines — "done." on success, "FAILED: ruby-<v>"
# on failure — are therefore part of the condition, not just the eventual binary.
_ruby_reconcile_done() { grep -qE '\[rvm-reconcile\] (done\.|FAILED:)'; }
# _ruby_reconcile_ok: GIVEN a terminal line, was it the successful one. "done."
# and "FAILED:" both END the wait but mean opposite things, so success has to be
# asked as a question separate from "is the wait over".
#
# NOT just "does done. appear": rvm-reconcile.sh's per-version verification
# failure (log "FAILED: ruby-$v is not installed …") does NOT exit — it falls
# through to the default-setting block and unconditionally logs "done." at the
# end regardless. So a reconcile where one requested version compiled and
# another did not produces a log with BOTH a FAILED: line and a later done.
# line, and a predicate that only checks for done. reports that partial failure
# as success. Requires done. present AND no FAILED: line anywhere.
#
# Read stdin ONCE into a variable and test the captured text twice — two greps
# chained on the SAME pipe (`grep -q done. && ! grep -q FAILED:`) would have the
# first grep consume stdin, leaving the second nothing to read, so it would
# always report no match regardless of the input.
_ruby_reconcile_ok() {
  local logs; logs="$(cat)"
  grep -q   '\[rvm-reconcile\] done\.'   <<< "$logs" || return 1
  grep -q   '\[rvm-reconcile\] FAILED:'  <<< "$logs" && return 1
  return 0
}

ruby_wait_ready() {  # $1=cid $2=timeout seconds (default 1800 — a cold compile is slow)
  local cid="$1" deadline=$(( SECONDS + ${2:-1800} )) logs
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    logs="$(docker logs "$cid" 2>&1)"
    if _ruby_reconcile_done <<< "$logs"; then
      _ruby_reconcile_ok <<< "$logs" && return 0
      fail "ruby_wait_ready: the reconcile reported FAILED"
      printf '%s\n' "$logs" | grep -i 'rvm-reconcile' | tail -20 | sed 's/^/     /'
      return 1
    fi
    # A dead container will never print a terminal reconcile line, so the loop
    # above would otherwise spin silently until the timeout. Catch that early
    # and say so, rather than reporting a generic timeout for a different cause.
    docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true || {
      fail "ruby_wait_ready: the container exited before the reconcile finished"
      return 1
    }
    sleep 10
  done
  fail "ruby_wait_ready: timed out after ${2:-1800}s"
  return 1
}

assert_runs() {  # $1=cid $2=binary — asserts the binary is on PATH AND EXECUTES
  local out
  if ! docker exec "$1" bash -c "command -v $2 >/dev/null 2>&1"; then
    fail "$2 is on PATH"
    return 1
  fi
  # Capture the command's output FIRST, `head` it afterwards. `if out="$(cmd |
  # head -1)"` tests HEAD's exit status, and head succeeds on the empty output
  # of a binary that just died — that exact mistake made the equivalent check in
  # verify-on-host.sh unreachable for its entire existence. rvm rewrites gem
  # binstub shebangs to `#!/usr/bin/env ruby_executable_hooks`, so a correctly
  # linked `bundle` can still die on exec; "on PATH" and "runs" are genuinely
  # different failures and need different diagnostics.
  if out="$(docker exec "$1" bash -c "$2 --version 2>&1")"; then
    pass "$2 runs: $(printf '%s\n' "$out" | head -1)"
    return 0
  fi
  fail "$2 is present but FAILED TO RUN"
  docker exec "$1" bash -c \
    "p=\$(command -v $2); printf '     path:    %s -> %s\n' \"\$p\" \"\$(readlink -f \"\$p\")\";
     printf '     shebang: %s\n' \"\$(head -1 \"\$(readlink -f \"\$p\")\" 2>/dev/null)\"" 2>&1
  printf '     error:   %s\n' "$(printf '%s\n' "$out" | head -1)"
  return 1
}

# ── The primitive most network cases reduce to ─────────────────────────────────
reach() {  # $1=cid $2=host-or-ip [$3=port]
  docker exec "$1" curl -fsS --connect-timeout "$IT_CONNECT_TIMEOUT" \
    --max-time "$IT_CONNECT_TIMEOUT" -o /dev/null "http://$2:${3:-8080}/" >/dev/null 2>&1
}

# The agent shell's capabilities, NOT a fresh docker exec's. `docker exec` starts
# from the container's capability bounding set and does not inherit the drops
# from `exec capsh --drop=…`, so asking it directly would report NET_ADMIN
# present in a container that correctly dropped it.
pid1_caps() {  # $1=cid
  docker exec "$1" bash -c \
    'capsh --decode=$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/1/status) 2>/dev/null' 2>/dev/null
}

blocked_entries() {  # $1=cid [$2=file basename]
  docker exec "$1" cat "/workspace/.agent-blocked/${2:-blocked-ips.txt}" 2>/dev/null \
    | it_strip_comments
}

# ── Assertions ──────────────────────────────────────────────────────────────────
assert_reachable() {  # $1=cid $2=host [$3=port]
  if reach "$@"; then pass "reachable: $2:${3:-8080}"
  else fail "reachable: $2:${3:-8080} — curl could not connect"; fi
}
assert_blocked() {
  if reach "$@"; then fail "blocked: $2:${3:-8080} — it was REACHABLE"
  else pass "blocked: $2:${3:-8080}"; fi
}
assert_file_exists() {  # $1=cid $2=path
  if docker exec "$1" test -f "$2" 2>/dev/null; then pass "exists in container: $2"
  else fail "exists in container: $2"; fi
}
assert_file_absent() {
  if docker exec "$1" test -e "$2" 2>/dev/null; then fail "absent in container: $2 — it EXISTS"
  else pass "absent in container: $2"; fi
}

# ── Mounts / groups / volumes assertions ───────────────────────────────────────
# Writability is probed as the agent user (see agent_exec) and always in PAIRS
# in the cases that use it: "the :ro mount refuses a write" is also satisfied by
# a container whose whole /workspace is broken, so a :rw sibling proving the
# write path works is what turns it into evidence of ENFORCEMENT.
assert_writable() {  # $1=cid $2=dir
  if agent_exec "$1" "touch '$2/.it-write-probe' && rm -f '$2/.it-write-probe'" >/dev/null 2>&1
  then pass "agent can write: $2"
  else fail "agent can write: $2 — the write was REFUSED"; fi
}
# The mount happened at all. Pairs with assert_not_writable: an empty directory
# where a mount should be is also not writable, and would satisfy the :ro
# assertion on its own.
assert_agent_reads() {  # $1=cid $2=file $3=expected content
  local got; got="$(agent_exec "$1" "cat '$2' 2>/dev/null" 2>/dev/null | tr -d '\r\n')"
  if [[ "$got" == "$3" ]]; then pass "agent reads $2 [$3]"
  else fail "agent reads $2 — expected '$3', got '${got:-<nothing>}'"; fi
}
assert_not_writable() {  # $1=cid $2=dir
  if agent_exec "$1" "touch '$2/.it-write-probe'" >/dev/null 2>&1; then
    fail "agent cannot write: $2 — the write SUCCEEDED"
    agent_exec "$1" "rm -f '$2/.it-write-probe'" >/dev/null 2>&1 || true
  else
    pass "agent cannot write: $2"
  fi
}
# HOST-side, not in-container: the whole point of several cases is that a file
# the container produced reaches the host directory a human actually reads.
# Asserting it inside the container proves only that the container wrote it.
assert_host_file_exists() {  # $1=path
  if [[ -f "$1" ]]; then pass "exists on host: $1"; else fail "exists on host: $1"; fi
}
assert_host_file_absent() {  # $1=path
  if [[ -e "$1" ]]; then fail "absent on host: $1 — it EXISTS"; else pass "absent on host: $1"; fi
}
assert_host_readable() {  # $1=path
  if [[ -r "$1" ]]; then pass "readable by the invoking user: $1"
  else fail "readable by the invoking user: $1"; fi
}
# The launcher refused, and refused BEFORE creating anything. A collision check
# that printed an error and started the container anyway would satisfy a bare
# exit-code assertion.
assert_launcher_refused() {  # $1=expected stderr ERE
  if [[ "$IT_LAUNCH_RC" -ne 0 ]]; then pass "launcher exited non-zero ($IT_LAUNCH_RC)"
  else fail "launcher exited 0 — it should have refused"; fi
  if grep -qE "$1" "$IT_LAUNCH_ERR" 2>/dev/null; then pass "launcher stderr matches: $1"
  else
    fail "launcher stderr matches: $1"
    tail -20 "$IT_LAUNCH_ERR" 2>/dev/null | sed 's/^/     /'
  fi
  local found
  found="$(docker ps -aq --filter "name=^${IT_LAUNCH_NAME}\$" 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$found" ]]; then pass "no container was created"
  else fail "no container was created — found $found"; fi
}
assert_log_contains() {  # $1=cid $2=ERE
  if docker logs "$1" 2>&1 | grep -qE "$2"; then pass "container log matches: $2"
  else fail "container log matches: $2"; fi
}
# A "capability is absent" claim is a NEGATIVE assertion, and a negative built on
# a substring search passes for two very different reasons: the capability really
# is gone, or the string we searched was never a capability list at all. The
# second reading must be rejected explicitly, because it FAILS OPEN — and it does
# so in exactly the worst case.
#
# Observed, not theorised (CI run 31153258705): with `pid1_caps` pointed at
# `capsh --print` in a `--privileged` container, the value came back as the
# shorthand `=ep` — libcap prints that instead of enumerating when a process
# holds EVERY capability. `=ep` is non-empty, so an emptiness check passes it,
# and it contains no "cap_net_admin" substring, so the search finds nothing and
# the case cheerfully reports the capability dropped. A fully privileged
# container produced the most reassuring possible result.
#
# So validate the FORMAT before trusting a negative — and validate the format,
# not the content. `capsh --decode` always answers `0x<hex>=<comma-list>`, and
# the list is EMPTY exactly when the process holds no capabilities:
#   all dropped   0x0000000000000000=
#   some held     0x00000000a80425fb=cap_chown,cap_dac_override,…
#   the shorthand =ep                     (capsh --print, never --decode)
# An earlier version of this guard required the string to contain "cap_", which
# rejected the first line above — i.e. it refused to verify the one case the
# assertion exists to confirm, failing every correctly-hardened container (CI run
# 31153628047). Testing for the `0x…=` envelope accepts the empty enumeration as
# the meaningful answer it is, while still rejecting `=ep` and an empty string.
assert_no_capability() {  # $1=cid $2=cap name, e.g. cap_net_admin
  local caps; caps="$(pid1_caps "$1")"
  case "$caps" in
    0x*=*) : ;;   # the capsh --decode envelope — safe to search
    *) fail "cannot verify $2: capability set is not in capsh --decode form [${caps:-<empty>}]"
       return ;;
  esac
  case "$caps" in
    *"$2"*) fail "agent shell dropped $2 — still present in [$caps]" ;;
    *)      pass "agent shell dropped $2" ;;
  esac
}

# ── Blocked-traffic forensics ───────────────────────────────────────────────────
# Lifted from verify-on-host.sh's Phase 3 (its HARD-BLOCKED block), which is being
# deleted once every case gets this for free. That phase carries the only tooling
# that can settle the repo1.maven.org class of question: a blocked destination was
# reported by NAME, the name comes from a reverse lookup through a sniffed DNS map,
# and on a shared CDN address that name can be wrong. Working that out took two
# full verification rounds and three intermediate PRs, because the two tables that
# could have settled it on the spot — the DNS map and the baked allowlist — both
# die with the container, and by the time anyone went looking they were already
# gone. This function exists so the read happens while the evidence still does.
#
# forensics_report is the PURE half: four file paths in, a text report out, no
# docker anywhere in it — so it is unit-tested directly against fixtures in
# tests/test-integration-lib.sh, with no daemon required. dump_blocked_forensics
# below is the thin wrapper that pulls those four files out of a live container.
#
# Column layout, verified against the ACTUAL writer (capture-blocked-traffic.sh's
# log_blocked()), not assumed: `printf '%-25s  %-10s  %-42s  %s\n' "$timestamp"
# "$proto:$dst_port" "$dst_ip" "${domain:-(no domain)}"`. Field-split by awk that
# is timestamp($1), "proto:port" COMBINED as one field($2), destination IP($3),
# domain($4) — never five separate columns, and proto/port are never split apart.
# A self-healed line appends " (auto-allowed)" after the domain as a further
# field($5). blocked-ips.txt entries are bare IPs with no domain at all, which is
# why the match below tests both the IP column and the domain column.
forensics_report() {  # $1=blocked.log $2=blocked-domains/ips $3=dns-map $4=baked allowlist
  local blog="$1" bdom="$2" dmap="$3" allow="$4"
  # `cat … | it_strip_comments`, not `it_strip_comments < "$bdom"`: a bare `<`
  # on a file that legitimately doesn't exist (dump_blocked_forensics leaves it
  # absent on a failed read, by design) is a SHELL-level open failure — bash
  # reports it on stderr itself, before the command even starts, so the
  # trailing `2>/dev/null` never gets the chance to catch it. Piping through
  # `cat` instead makes the missing-file case an ordinary command failure that
  # `2>/dev/null` on `cat` actually suppresses, leaving `hard` correctly empty
  # with no stray "No such file or directory" in a case's diagnostics.
  local hard; hard="$(cat "$bdom" 2>/dev/null | it_strip_comments | sort -u)"
  local healed
  healed="$(grep '(auto-allowed)' "$blog" 2>/dev/null | awk '{print $NF, $(NF-1)}' | sort -u | head -20)"

  if [[ -n "$hard" ]]; then
    printf '   HARD-BLOCKED by the firewall (never admitted):\n'
    local what
    while IFS= read -r what; do
      [[ -z "$what" ]] && continue
      # Match the domain column ($4) or the IP column ($3): blocked-ips.txt
      # entries are bare IPs with no domain. Timestamps carry no space
      # (%Y-%m-%dT%H:%M:%S) and proto:port is one field, so the columns are
      # stable at 4 fields for a hard-blocked line.
      #
      # Piped through `cat`, not handed to awk as a bare filename argument:
      # when awk cannot OPEN a named file at all it skips the whole program,
      # including END — so on a legitimately-absent $blog this would print
      # NOTHING for the entry, not even the "(no matching line)" fallback
      # below, silently degrading the report instead of stating the honest
      # answer. Reading from stdin instead makes an absent/empty $blog just
      # zero input records, and END still runs.
      cat "$blog" 2>/dev/null | awk -v want="$what" '
        $3 == want || $4 == want {
          key = $3 " " $2
          if (!(key in seen)) { first[key] = $1; order[++n] = key }
          seen[key]++
        }
        END {
          if (n == 0) { printf "     %-38s (no matching line in blocked.log)\n", want; exit }
          for (i = 1; i <= n; i++) {
            k = order[i]
            printf "     %-38s %-24s x%-4d first %s\n", want, k, seen[k], first[k]
          }
        }'

      # Was this name allowlisted in THIS image? "no" rules out the whole family
      # of "an allowlisted host under an alias the self-healer could not match",
      # which is otherwise the first thing to suspect and takes a round trip to
      # exclude.
      if grep -qxF "$what" "$allow" 2>/dev/null; then
        printf '       allowlisted in this image: YES — a self-healing or refresh-timing\n'
        printf '                                       failure, not policy\n'
      else
        printf '       allowlisted in this image: no\n'
      fi

      # Every name the DNS map holds for the addresses this entry was dropped
      # on. More than one means the label above is a coin flip between them;
      # exactly one means the container really did resolve that name.
      local ip names
      # Same `cat |` reasoning as above, for consistency — this particular awk
      # has no END block so a missing $blog isn't currently observable here,
      # but a bare filename argument is the wrong default to leave lying
      # around in a function that now routinely receives absent files.
      for ip in $(cat "$blog" 2>/dev/null | awk -v want="$what" '$3 == want || $4 == want {print $3}' | sort -u); do
        names="$(awk -v ip="$ip" '$1 == ip {print $2}' "$dmap" 2>/dev/null | sort -u | tr '\n' ' ')"
        printf '       names resolved to %-18s %s\n' "$ip" \
          "${names:-(none — the container never resolved this address)}"
      done
    done <<< "$hard"
    printf '   ^ the NAME is reverse-mapped from the IP and can be wrong on a shared\n'
    printf '     CDN address; the IP and port cannot. Confirm before allowlisting.\n'

    # The full resolved-name list, SPLIT BY ALLOWLIST MEMBERSHIP. Both file
    # paths are already parameters, so this stays in the pure half.
    #
    # A raw "every name this container resolved" list mixes two completely
    # different populations and reading it as one is misleading: the ipset
    # refresh loop re-resolves EVERY allowlisted domain every 60 seconds and
    # makes no TCP connection at all, so most of a resolved-name list is just
    # the allowlist echoing itself back, not evidence of traffic. Phase 3's own
    # history: a 49-name list once looked like a container talking to 49 hosts;
    # 47 of them were simply the allowlist being re-resolved. The short list
    # that actually matters is the complement: names this container looked up
    # that it was never authorised to reach.
    if [[ -s "$dmap" ]]; then
      local resolved unlisted n_all n_un
      resolved="$(awk '{print $2}' "$dmap" 2>/dev/null | sort -u)"
      unlisted="$(comm -23 <(printf '%s\n' "$resolved") <(sort -u "$allow" 2>/dev/null))"
      n_all="$(printf '%s\n' "$resolved" | grep -c . || true)"
      n_un="$(printf '%s\n' "$unlisted" | grep -c . || true)"
      printf '   names resolved during the run: %s total, %s NOT allowlisted\n' "$n_all" "$n_un"
      if [[ "$n_un" -gt 0 ]]; then
        printf '     resolved but NOT allowlisted (what the container reached for uninvited):\n'
        printf '%s\n' "$unlisted" | grep . | sed 's/^/       /'
      fi
      printf '     all %s (the rest are the allowlist itself, re-resolved every 60s):\n' "$n_all"
      printf '%s\n' "$resolved" | sed 's/^/       /'
    else
      printf "   the container's DNS map is empty or unreadable — cannot say what it resolved\n"
    fi
  fi

  if [[ -n "$healed" ]]; then
    printf '   dropped then SELF-HEALED (allowlisted, admitted after the first packet):\n'
    printf '%s\n' "$healed" | sed 's/^/     /'
  fi

  if [[ -z "$hard" && -z "$healed" ]]; then
    # Only a RUNNING capture licenses "nothing was dropped". With a dead daemon
    # the honest answer is that we do not know — and that distinction is only
    # as trustworthy as the caller's file-presence semantics: `-f "$blog"` must
    # mean "the container really had this file", never "a local scratch file
    # exists because something touched it". dump_blocked_forensics below is
    # the only thing standing between this branch and a false "clean run": if
    # it ever fabricates an empty $blog on a failed read, this reports "nothing
    # was dropped" for a capture that never ran at all — precisely the false
    # negative that let this repo's capture daemon die silently for months
    # while "nothing was blocked" read as evidence instead of as ignorance.
    if [[ -f "$blog" ]]; then
      printf '   firewall dropped nothing\n'
    else
      printf '   what the firewall dropped is UNKNOWN — the capture never ran\n'
    fi
  fi
}

dump_blocked_forensics() {  # $1=cid — MUST run while the container is alive
  local cid="$1" d; d="$(it_scratch)"
  printf '   ── blocked-traffic forensics ──\n'

  # A container that has already exited tells us NOTHING about whether the
  # capture ran: every docker exec below would fail identically whether the
  # daemon crashed before writing a single line or was never started, and
  # letting that collapse into forensics_report's "the capture never ran"
  # branch would assert an absence we cannot actually vouch for. Probe once,
  # up front, and say so plainly — "we could not check" is a different claim
  # from "we checked and it was empty", and only the second is
  # forensics_report's file-presence logic entitled to make.
  if [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]]; then
    printf '     could not read the capture output — the container is no longer\n'
    printf '     running, so capture state is UNKNOWN (this is NOT "nothing was blocked")\n'
    return
  fi

  # Both tables die with the container: the DNS map lives in a root-only tmpfs
  # (/run/agent-blocked-internal) and the baked allowlist is an image file. Read
  # them now, while docker exec can still reach them, or lose the only evidence
  # that can settle a mis-attributed name.
  #
  # A failed read must leave the local file ABSENT (`rm -f`), never a fabricated
  # empty stand-in (`: > file`) — forensics_report tells "the capture never ran"
  # apart from "it ran and saw nothing" purely by whether the file exists, and
  # this wrapper is the only place that distinction can be preserved or lost.
  # Every read below MUST let `docker exec`'s own exit status govern the
  # fallback — never pipe its output through another command first. A pipeline's
  # `$?` is its LAST stage's, not `docker exec`'s: `cmd | it_strip_comments`
  # exits 0 on empty input regardless of whether `cmd` itself failed, so a
  # piped `|| rm -f` never fires on a failed exec and silently reverts to the
  # fabricated-empty-file defect this block exists to eliminate. (Nothing in
  # the production call chain sets `pipefail` — cases run as a fresh `bash "$f"`
  # with no inherited shell options — so this is not merely a style nit.)
  docker exec "$cid" cat /run/agent-blocked-internal/dns-map.txt > "$d/dns-map.txt" 2>/dev/null \
    || rm -f "$d/dns-map.txt"
  if docker exec "$cid" cat /tmp/allowlist-domains.txt > "$d/allowlist.raw" 2>/dev/null; then
    it_strip_comments < "$d/allowlist.raw" > "$d/allowlist.txt"
  else
    rm -f "$d/allowlist.txt"
  fi
  rm -f "$d/allowlist.raw"
  local f
  for f in blocked.log blocked-domains.txt blocked-ips.txt; do
    docker exec "$cid" cat "/workspace/.agent-blocked/$f" > "$d/$f" 2>/dev/null || rm -f "$d/$f"
  done
  # Merge blocked-ips.txt into blocked-domains.txt so forensics_report's single
  # "hard-blocked" parameter covers both bare-IP and named entries. Guarded on
  # the SOURCE existing, not on the target: `>>` creates its target before `cat`
  # even runs, so an unguarded merge re-fabricates blocked-domains.txt as an
  # empty file whenever both reads above already failed and were correctly
  # rm -f'd — the identical redirection-on-a-failure-path defect this whole
  # function was just cleared of, one line after the loop that cleared it.
  # `>>` legitimately creating blocked-domains.txt when it was absent but
  # blocked-ips.txt is PRESENT is fine and must keep working — a bare-IP entry
  # is a real hard-blocked destination with no domain, and that is the only
  # copy of it. What must never happen is creating the target when there is
  # nothing to append.
  if [[ -f "$d/blocked-ips.txt" ]]; then
    cat "$d/blocked-ips.txt" >> "$d/blocked-domains.txt"
  fi
  forensics_report "$d/blocked.log" "$d/blocked-domains.txt" "$d/dns-map.txt" "$d/allowlist.txt"

  # WHICH FILE IN THE IMAGE KNOWS THIS NAME. Everything forensics_report prints
  # above establishes that a name was resolved and connected to; none of it says
  # what asked. A hostname a program contacts is almost always a literal in that
  # program or its config, so grepping the image for the string names the
  # culprit directly — and grepping the IMAGE (not the host) is what makes the
  # answer trustworthy: it is the same filesystem the connection came from. This
  # needs a live container (docker exec), which is the one thing forensics_report
  # is deliberately kept free of, so it lives here instead.
  #
  # Bounded in TWO dimensions, deliberately. Each grep is bounded on its own —
  # timeout, a handful of paths rather than /, first 5 hits — exactly as Phase 3
  # ran it. But Phase 3 ran this ONCE, in one controlled phase; it_diagnose now
  # runs it on every failing restricted-mode case, so a broadly-broken case that
  # blocks dozens of hostnames would otherwise cost N × 90s and look like a hang
  # in CI. Cap the NAME count too (first 10, mirroring the existing 5-hit-per-name
  # cap), and say how many were skipped — a silent truncation is its own small lie.
  local hard what owner n=0 max=10 skipped=0
  # `cat | it_strip_comments`, not a bare `<` — see the matching comment in
  # forensics_report. blocked-domains.txt can now legitimately be absent (both
  # source reads failed and were correctly left un-fabricated), and a bare `<`
  # on that would leak a shell-level "No such file or directory" past this
  # command's own `2>/dev/null`.
  hard="$(cat "$d/blocked-domains.txt" 2>/dev/null | it_strip_comments | sort -u)"
  while IFS= read -r what; do
    [[ -z "$what" ]] && continue
    # Bare IPv4 literal: nothing to grep the image for. Phase 3's own check,
    # inherited as-is: it does not match a bare IPv6 literal (this repo's
    # WSL2/nf_tables caveat means IPv6 enforcement can be degraded, so
    # blocked-ips.txt could in principle hold one). Harmless here — an IPv6
    # literal just falls through to the grep below instead of being skipped,
    # and the grep stays bounded either way.
    [[ "$what" =~ ^[0-9.]+$ ]] && continue
    if [[ "$n" -ge "$max" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    n=$((n + 1))
    owner="$(docker exec "$cid" timeout 90 grep -rlsF "$what" \
               /usr/local /opt /etc /home /usr/lib/node_modules /usr/share \
               2>/dev/null | head -5)"
    if [[ -n "$owner" ]]; then
      printf '     files in the image containing %s:\n' "$what"
      printf '%s\n' "$owner" | sed 's/^/       /'
    else
      printf '     no file under /usr/local /opt /etc /home /usr/share mentions %s\n' "$what"
      printf '       — so nothing baked into the image asked for it by literal.\n'
    fi
  done <<< "$hard"
  if [[ "$skipped" -gt 0 ]]; then
    printf '     … %d more hard-blocked name(s) skipped (image-grep capped at %d)\n' "$skipped" "$max"
  fi
}

# ── Diagnostics, printed automatically by it_cleanup when a case failed ────────
it_diagnose() {  # $1=cid
  printf '── DIAGNOSTICS %s ──\n' "$1"
  printf '   ── docker logs (last 60) ──\n'
  docker logs "$1" 2>&1 | tail -60 | sed 's/^/     /'
  printf '   ── iptables -S OUTPUT ──\n'
  docker exec "$1" iptables -S OUTPUT 2>&1 | sed 's/^/     /'
  printf '   ── ipset ──\n'
  docker exec "$1" bash -c \
    'for s in $(ipset list -n 2>/dev/null); do printf "%s: %s entries\n" "$s" "$(ipset list "$s" 2>/dev/null | sed -n "/^Members:/,\$p" | tail -n +2 | grep -c .)"; done' \
    2>&1 | sed 's/^/     /'
  printf '   ── capture dirs ──\n'
  docker exec "$1" bash -c \
    'ls -la /workspace/.agent-blocked /workspace/.agent-discovery 2>&1;
     for f in /workspace/.agent-blocked/*; do [ -f "$f" ] && { echo "--- $f"; head -20 "$f"; }; done' \
    2>&1 | sed 's/^/     /'
  dump_blocked_forensics "$1"
}
