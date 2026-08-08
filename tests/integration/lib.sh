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
}
