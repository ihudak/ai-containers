#!/usr/bin/env bash
# Unit tests for the `redis` sandbox.conf key and its adapter.
#
# The key buys a Redis SERVER inside the container: a build-time layer (Ubuntu's
# redis-server), a run-time env var (AI_SERVICES, read by start-services.sh) and
# an adapter (services.d/redis.sh) that starts a throwaway server as the sandbox
# user.
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring and logic
# assertions, the adapter driven against fake binaries. That the layer BUILDS
# and a real server answers in a real container is integration case
# 785-redis-server-runs (packages tier, `services` variant), demonstrated
# failing by its mutations. The runner's own contract is
# tests/test-start-services.sh.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
TMP_ROOT="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
# The fake server leaves a `sleep` behind as its "daemon"; every one is recorded
# in $TMP_ROOT/redis/daemons and killed on the way out.
cleanup() {
  [[ "$BASHPID" == "$TMP_OWNER" ]] || return 0
  local p
  if [[ -f "$TMP_ROOT/redis/daemons" ]]; then
    while IFS= read -r p; do kill "$p" 2>/dev/null; done < "$TMP_ROOT/redis/daemons"
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# ── Part A: sandbox.conf value → INSTALL_REDIS build arg ───────────────────────
# ON emits INSTALL_REDIS=1. OFF, empty and absent emit NO arg at all — not
# INSTALL_REDIS=0: the Dockerfile's ARG defaults to 0, and a project that never
# enables the key keeps the config digest it had.
rd_build_args() {  # $1 = sandbox.conf body → every docker build arg, one per line
  local d
  d="$(mktemp -d "$TMP_ROOT/ba.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n' >&2; return 1; }
  printf '# schema-version: 4\n%s\n' "$1" > "$d/sandbox.conf"
  ( export SANDBOX_CONF="$d/sandbox.conf"
    # shellcheck source=/dev/null
    source "$REPO_DIR/build.sh"
    declare -a args=()
    build_args_from_config args
    printf '%s\n' "${args[@]}" )
}

out="$(rd_build_args 'redis=ON')"
grep -qx 'INSTALL_REDIS=1' <<<"$out" \
  && pass "redis=ON → INSTALL_REDIS=1" \
  || fail "redis=ON → INSTALL_REDIS=1"

for off in 'redis=OFF' 'redis=' 'copilot=ON'; do
  out="$(rd_build_args "$off")"
  if [[ -z "$out" ]]; then
    fail "'$off': build_args_from_config produced nothing at all — this assertion verified nothing"
  elif grep -q '^INSTALL_REDIS=' <<<"$out"; then
    fail "'$off' → no INSTALL_REDIS build arg (got: $(grep '^INSTALL_REDIS=' <<<"$out"))"
  else
    pass "'$off' → no INSTALL_REDIS build arg (never INSTALL_REDIS=0)"
  fi
done

# ── Part B: validate_config — ON or OFF, in capitals ───────────────────────────
VC_TMP="$(mktemp -d "$TMP_ROOT/vc.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n'; exit 1; }
vc() {  # $1 = redis value → sets VC_RC and VC_OUT
  printf '# schema-version: 4\nredis=%s\n' "$1" > "$VC_TMP/sandbox.conf"
  VC_OUT="$(SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" 2>&1)"
  VC_RC=$?
}

for good in ON OFF ''; do
  vc "$good"
  [[ "$VC_RC" -eq 0 ]] \
    && pass "validate_config accepts redis=$good" \
    || fail "validate_config accepts redis=$good (rc=$VC_RC, out='$VC_OUT')"
done

# Each refusal must NAME the key, and say which mistake it was: a lowercase
# on/off would otherwise read as OFF without a word, and a version would be
# silently ignored, since Ubuntu's archive carries one Redis.
for bad in on Off oN; do
  vc "$bad"
  if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *redis* && "$VC_OUT" == *capitals* ]]; then
    pass "validate_config refuses redis=$bad, by name, asking for capitals"
  else
    fail "validate_config refuses redis=$bad, by name, asking for capitals (rc=$VC_RC, out='$VC_OUT')"
  fi
done
for bad in 7 7.0 7.2.4 latest 'ON,OFF' valkey; do
  vc "$bad"
  if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *redis* && "$VC_OUT" == *"cannot be pinned"* ]]; then
    pass "validate_config refuses redis=$bad, by name, saying a version cannot be pinned"
  else
    fail "validate_config refuses redis=$bad, by name, saying a version cannot be pinned (rc=$VC_RC, out='$VC_OUT')"
  fi
done

# ── Part F: the shipped default ────────────────────────────────────────────────
grep -qx 'redis=OFF' "$REPO_DIR/sandbox.conf" \
  && pass "sandbox.conf ships redis=OFF" \
  || fail "sandbox.conf ships redis=OFF"

# ── Part C: sandbox.sh passes AI_SERVICES to the container ─────────────────────
# Driven through a fake `docker` on PATH that captures the assembled `docker run`
# argv — the harness tests/test-postgres.sh uses. No daemon involved.
sb_run() {  # $1 = sandbox.conf body → prints the path of the captured argv file
  local d
  d="$(mktemp -d "$TMP_ROOT/sb.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n' >&2; return 1; }
  mkdir -p "$d/home" "$d/bin" "$d/app" "$d/launch"
  printf '# schema-version: 4\n%s\n' "$1" > "$d/sandbox.conf"
  cat > "$d/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$d/argv"; exit 0; fi
exit 1
DOCKER
  chmod +x "$d/bin/docker"
  ( HOME="$(p_realdir "$d/home")"; export HOME
    export PATH="$d/bin:$PATH" SANDBOX_CONF="$d/sandbox.conf" AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=dev
    unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS \
          AI_CONTAINER_GROUP CONTAINER_SHM_SIZE SANDBOX_ENV_FILE IMAGE_NAME CONTAINER_NAME \
          CONTAINER_CPUS CONTAINER_MEMORY CONTAINER_MEMORY_RESERVATION CONTAINER_MEMORY_SWAP
    cd "$d/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$d/app" ) >/dev/null 2>&1 </dev/null
  printf '%s' "$d/argv"
}

ai_services_case() {  # $1 = conf body, $2 = expected AI_SERVICES value, $3 = label
  local argv; argv="$(sb_run "$1")"
  if [[ ! -s "$argv" ]]; then
    fail "$3: sandbox.sh never reached docker run — nothing was verified"
  elif grep -qx -- "AI_SERVICES=$2" "$argv"; then
    pass "$3"
  else
    fail "$3 (got: $(grep '^AI_SERVICES=' "$argv" || printf 'no AI_SERVICES at all'))"
  fi
}
ai_services_case 'redis=ON'                'redis=ON'             "redis=ON → AI_SERVICES=redis=ON"
ai_services_case $'postgres=17\nredis=ON'  'postgres=17,redis=ON' "postgres=17 and redis=ON → both, in one AI_SERVICES"
ai_services_case 'redis=OFF'               ''                     "redis=OFF → AI_SERVICES empty"

# ── Part D: services.d/redis.sh against fake binaries ──────────────────────────
# Isolate from the host environment: only what Part D or the adapter reads.
# REDIS_* are unset too, because D9 sets REDIS_PORT on purpose — an app's own
# variable, which must not move the server — and must be the only thing that does.
unset AI_SERVICES_REDIS_SERVER AI_SERVICES_REDIS_CLI AI_SERVICES_REDIS_PORT AI_SERVICES_REDIS_TRIES \
      REDIS_SERVER REDIS_CLI REDIS_PORT REDIS_TRIES REDIS_URL FAKE_MODE
FAKE="$TMP_ROOT/redis"; mkdir -p "$FAKE/bin" "$FAKE/data"
: > "$FAKE/daemons"

# Not 6379, so an assertion on the port cannot pass by the default. The fakes
# never touch the network, so nothing has to be free.
PORT=46379

# The fake server records its argv one per line and, by FAKE_MODE, behaves as:
#   ok     detaches a `sleep` as the daemon and writes its pid to --pidfile
#   dead   writes the pid of a process that has already exited
#   nopid  detaches nothing and writes no pid file (a server that failed to bind)
#   fail   exits 1 at once
cat > "$FAKE/bin/redis-server" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'Redis server v=7.0.15 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=d064f9f48c901a92\n'; exit 0
fi
printf '%s\n' "$@" > "$FAKE_DIR/server.args"
printf 'redis-server\n' >> "$FAKE_DIR/calls"
pidfile=""
while (( $# )); do [[ "$1" == --pidfile ]] && pidfile="$2"; shift; done
printf '%s\n' "$pidfile" > "$FAKE_DIR/pidfile.path"
case "${FAKE_MODE:-ok}" in
  ok)    sleep 300 >/dev/null 2>&1 </dev/null & pid=$!
         printf '%s\n' "$pid" >> "$FAKE_DIR/daemons"; printf '%s\n' "$pid" > "$pidfile" ;;
  dead)  sleep 0 & pid=$!; wait "$pid"; printf '%s\n' "$pid" > "$pidfile" ;;
  nopid) ;;
  fail)  exit 1 ;;
esac
exit 0
EOF
# The fake CLI answers `info server` with the pid in $FAKE_DIR/answer.pid when
# that exists (ANOTHER server on the port), else with the one the fake server
# wrote to its --pidfile — and with nothing when no server is up.
cat > "$FAKE/bin/redis-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/cli.args"
[[ " $* " == *" info server "* ]] || exit 1
pid=""
if [[ -f "$FAKE_DIR/answer.pid" ]]; then pid="$(cat "$FAKE_DIR/answer.pid")"
elif [[ -f "$FAKE_DIR/pidfile.path" ]]; then
  pid="$(cat "$(cat "$FAKE_DIR/pidfile.path")" 2>/dev/null)"
  # A server that has exited answers nothing.
  [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && pid=""
fi
[[ -n "$pid" ]] || exit 1
printf '# Server\r\nredis_version:7.0.15\r\nprocess_id:%s\r\ntcp_port:6379\r\n' "$pid"
EOF
chmod +x "$FAKE"/bin/*

# rd <function> [args] — run one adapter function in a FRESH subshell, the way
# start-services.sh does, against the fakes.
rd() {
  ( export AI_SERVICES_REDIS_SERVER="$FAKE/bin/redis-server" AI_SERVICES_REDIS_CLI="$FAKE/bin/redis-cli" \
           AI_SERVICES_REDIS_PORT="${RD_PORT:-$PORT}" AI_SERVICES_REDIS_TRIES="${RD_TRIES:-50}" \
           FAKE_DIR="$FAKE" FAKE_MODE="${FAKE_MODE:-ok}"
    # shellcheck source=../services.d/redis.sh
    source "$REPO_DIR/services.d/redis.sh"
    "$@" )
}
rd_reset() { rm -f "$FAKE"/{server.args,cli.args,calls,answer.pid,pidfile.path}; rm -rf "$FAKE/data"; mkdir -p "$FAKE/data"; }
# arg_pair <a> <b> — <b> immediately follows <a> in the server's argv.
arg_pair() { awk -v a="$1" -v b="$2" 'prev == a && $0 == b { f = 1 } { prev = $0 } END { exit !f }' "$FAKE/server.args" 2>/dev/null; }

# D1–D3 — what this image has.
got="$(rd svc_installed_version)"
[[ "$got" == "7.0.15" ]] && pass "D1 svc_installed_version reads 7.0.15 out of redis-server's version line" || fail "D1 svc_installed_version (got '$got')"
got="$(AI_SERVICES_REDIS_SERVER="$FAKE/bin/absent" bash -c 'source "$1"; svc_installed_version' _ "$REPO_DIR/services.d/redis.sh")"; rc=$?
[[ -z "$got" && "$rc" -eq 0 ]] && pass "D2 no redis-server binary → nothing installed, status 0" || fail "D2 no binary (got '$got', rc=$rc)"
got="$(rd svc_runtime_dirs)"
[[ -z "$got" ]] && pass "D3 svc_runtime_dirs names nothing (the pid file lives in the data directory; no socket)" || fail "D3 svc_runtime_dirs (got '$got')"

# D4 — svc_start: the command line, then ready once THIS server answers.
rd_reset; rd svc_start "$FAKE/data" "$FAKE/log" >/dev/null; rc=$?
[[ "$rc" -eq 0 ]] && pass "D4 svc_start returns 0 once the server it started answers" || fail "D4 svc_start returns 0 (rc=$rc)"
arg_pair --bind 127.0.0.1 && arg_pair 127.0.0.1 -::1 \
  && pass "D4 binds 127.0.0.1 and ::1 only (::1 optional, so no IPv6 is no failure)" \
  || fail "D4 --bind 127.0.0.1 -::1 (args: $(tr '\n' ' ' < "$FAKE/server.args" 2>/dev/null))"
for pair in "--port $PORT" "--daemonize yes" "--pidfile $FAKE/data/redis.pid" "--logfile $FAKE/log" \
            "--dir $FAKE/data" "--appendonly no"; do
  arg_pair "${pair%% *}" "${pair#* }" && pass "D4 redis-server gets $pair" || fail "D4 redis-server gets $pair"
done
# --save takes an EMPTY argument (no snapshots at all), not a missing one.
arg_pair --save '' && pass "D4 --save '' — no snapshots, the empty argument passed intact" \
  || fail "D4 --save '' (args: $(tr '\n' '|' < "$FAKE/server.args" 2>/dev/null))"
[[ "$(head -1 "$FAKE/server.args" 2>/dev/null)" == --* ]] \
  && pass "D4 no config file is read: every option is on the command line" \
  || fail "D4 a config file was passed: $(head -1 "$FAKE/server.args" 2>/dev/null)"

# D5 — another Redis answering on the port is never taken for this one: its
# pid is not the one this server wrote. Bounded by the adapter's own wait.
rd_reset; printf '99999\n' > "$FAKE/answer.pid"
start=$(date +%s)
out="$(RD_TRIES=3 rd svc_start "$FAKE/data" "$FAKE/log")"; rc=$?
took=$(( $(date +%s) - start ))
[[ "$rc" -ne 0 && "$out" == *"did not answer"* ]] \
  && pass "D5 another server answering on the port is not this one: not ready (rc=$rc)" \
  || fail "D5 another server's answer taken for this one (rc=$rc, out='$out')"
# AI_SERVICES_REDIS_TRIES bounds the wait: 3 tries is 0.3 s, never the 30 s default.
[[ "$took" -le 5 ]] && pass "D5 AI_SERVICES_REDIS_TRIES bounds the wait (${took}s for 3 tries)" \
  || fail "D5 AI_SERVICES_REDIS_TRIES ignored: 3 tries took ${took}s"

# D6 — a server that never wrote its pid (the port was taken, so it exited) is
# not ready, and says so; the runner adds the log's tail, which names the cause.
rd_reset
out="$(FAKE_MODE=nopid RD_TRIES=3 rd svc_start "$FAKE/data" "$FAKE/log")"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"did not answer"* ]] \
  && pass "D6 no pid file written → not ready, said so (rc=$rc)" \
  || fail "D6 no pid file (rc=$rc, out='$out')"

# D7 — a server that died after writing its pid fails AT ONCE, not at the end
# of the wait: 300 tries would be 30 s.
rd_reset
start=$(date +%s)
out="$(FAKE_MODE=dead RD_TRIES=300 rd svc_start "$FAKE/data" "$FAKE/log")"; rc=$?
took=$(( $(date +%s) - start ))
[[ "$rc" -ne 0 && "$out" == *"exited before answering"* && "$took" -le 5 ]] \
  && pass "D7 a server that died after starting fails at once (${took}s), naming its pid" \
  || fail "D7 dead server (rc=$rc, took ${took}s, out='$out')"

# D8 — redis-server itself failing fails svc_start.
rd_reset
FAKE_MODE=fail rd svc_start "$FAKE/data" "$FAKE/log" >/dev/null; rc=$?
[[ "$rc" -ne 0 ]] && pass "D8 redis-server exiting non-zero fails svc_start" || fail "D8 redis-server failure ignored"

# D9 — the port knob moves it; an app's own REDIS_PORT (container.env reaches
# `start`) does not.
rd_reset
other=$(( PORT + 100 ))
RD_PORT="$other" rd svc_start "$FAKE/data" "$FAKE/log" >/dev/null
arg_pair --port "$other" && [[ "$(RD_PORT="$other" rd svc_endpoint)" == "redis://localhost:$other" ]] \
  && pass "D9 AI_SERVICES_REDIS_PORT moves the server and its endpoint" \
  || fail "D9 AI_SERVICES_REDIS_PORT (args: $(tr '\n' ' ' < "$FAKE/server.args" 2>/dev/null))"
rd_reset
( export REDIS_PORT=7777; rd svc_start "$FAKE/data" "$FAKE/log" >/dev/null )
arg_pair --port "$PORT" && ! grep -qx 7777 "$FAKE/server.args" \
  && pass "D9 an app's REDIS_PORT does not move the server" \
  || fail "D9 REDIS_PORT moved the server (args: $(tr '\n' ' ' < "$FAKE/server.args" 2>/dev/null))"

# D10 — nothing to provision; the endpoint is a URL clients take as is.
out="$(rd svc_provision)"; rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && pass "D10 svc_provision returns 0 and adds nothing to the ready line" || fail "D10 svc_provision (rc=$rc, out='$out')"
[[ "$(rd svc_endpoint)" == "redis://localhost:$PORT" ]] && pass "D10 svc_endpoint is redis://localhost:<port>" || fail "D10 svc_endpoint (got '$(rd svc_endpoint)')"

# D11 — through the runner: the ready line a user sees.
rd_reset
mkdir -p "$TMP_ROOT/state/redis" "$TMP_ROOT/logs"
out="$(AI_SERVICES=redis=ON AI_SERVICES_DIR="$REPO_DIR/services.d" AI_SERVICES_STATE_ROOT="$TMP_ROOT/state" \
       AI_SERVICES_LOG_ROOT="$TMP_ROOT/logs" AI_SERVICES_REDIS_SERVER="$FAKE/bin/redis-server" \
       AI_SERVICES_REDIS_CLI="$FAKE/bin/redis-cli" AI_SERVICES_REDIS_PORT="$PORT" FAKE_DIR="$FAKE" \
       bash "$REPO_DIR/start-services.sh" start 2>&1)"
if [[ "$out" == *"redis 7.0.15 ready on redis://localhost:$PORT"* ]]; then
  pass "D11 start-services.sh prints 'redis 7.0.15 ready on redis://localhost:<port>'"
else
  fail "D11 the runner's ready line (got: $out)"
fi

# ── Part E: the Dockerfile layer's shape ──────────────────────────────────────
# Shape only: that it BUILDS is integration case 785.
DF="$REPO_DIR/Dockerfile"
layer="$(awk '/^ARG INSTALL_REDIS=0$/{grab=1} grab{print} grab && /^$/{exit}' "$DF")"
[[ -n "$layer" ]] && pass "E the Dockerfile declares ARG INSTALL_REDIS=0 (skipped unless ON)" \
                  || fail "E the Dockerfile declares ARG INSTALL_REDIS=0"
grep -qF 'if [ "$INSTALL_REDIS" = "1" ]' <<<"$layer" && pass "E the layer runs only for INSTALL_REDIS=1" || fail "E skip guard"
grep -qF 'apt-get install -y --no-install-recommends redis-server' <<<"$layer" \
  && pass "E it installs Ubuntu's redis-server, without recommends" || fail "E redis-server install"
grep -qF 'test -x /usr/bin/redis-server' <<<"$layer" && grep -qF 'test -x /usr/bin/redis-cli' <<<"$layer" \
  && pass "E the build fails unless both binaries the adapter calls are there" || fail "E binary checks"

# ── Part G: shipping to projects ───────────────────────────────────────────────
payload="$(bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_payload_files "$1"' _ "$REPO_DIR")"
grep -qx 'services.d/redis.sh' <<<"$payload" \
  && pass "G the provenance digest covers services.d/redis.sh (it is built into the image)" \
  || fail "G provenance digest covers services.d/redis.sh"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
