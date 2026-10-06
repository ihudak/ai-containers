#!/usr/bin/env bash
# Unit tests for the `mongo` sandbox.conf key and its adapter.
#
# The key buys a MongoDB SERVER inside the container: a build-time layer
# (mongod and mongosh from MongoDB's own repository, one release series), a
# run-time env var (AI_SERVICES, read by start-services.sh) and an adapter
# (services.d/mongo.sh) that starts a throwaway server as the sandbox user.
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring and logic
# assertions, the adapter driven against a fake mongod. That the layer BUILDS
# and a real server answers in a real container is integration case
# 800-mongo-server-runs (packages tier, `services` variant), demonstrated
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
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP_ROOT"' EXIT

# ── Part A: sandbox.conf value → MONGO_SERIES build arg ────────────────────────
# ON is 8.0, the series db-clients=mongo installs mongosh from; a pinned series
# passes verbatim; OFF, empty and absent emit NO arg, so a project that never
# enables the key keeps its config digest.
mg_build_args() {  # $1 = sandbox.conf body → every docker build arg, one per line
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
out="$(mg_build_args 'mongo=ON')"
grep -qx 'MONGO_SERIES=8.0' <<<"$out" && pass "mongo=ON → MONGO_SERIES=8.0" || fail "mongo=ON → MONGO_SERIES=8.0"
out="$(mg_build_args 'mongo=8.2')"
grep -qx 'MONGO_SERIES=8.2' <<<"$out" && pass "mongo=8.2 → MONGO_SERIES=8.2 (a pinned series, verbatim)" || fail "mongo=8.2 → MONGO_SERIES=8.2"
for off in 'mongo=OFF' 'mongo=' 'copilot=ON'; do
  out="$(mg_build_args "$off")"
  if [[ -z "$out" ]]; then
    fail "'$off': build_args_from_config produced nothing at all — this assertion verified nothing"
  elif grep -q '^MONGO_SERIES=' <<<"$out"; then
    fail "'$off' → no MONGO_SERIES build arg (got: $(grep '^MONGO_SERIES=' <<<"$out"))"
  else
    pass "'$off' → no MONGO_SERIES build arg (never an empty or literal-OFF one)"
  fi
done

# ── Part B: validate_config — one series, capitals ─────────────────────────────
VC_TMP="$(mktemp -d "$TMP_ROOT/vc.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n'; exit 1; }
vc() {  # $1 = mongo value → sets VC_RC and VC_OUT
  printf '# schema-version: 4\nmongo=%s\n' "$1" > "$VC_TMP/sandbox.conf"
  VC_OUT="$(SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" 2>&1)"
  VC_RC=$?
}
for good in ON OFF '' 8.0 8.2 10.0; do
  vc "$good"
  [[ "$VC_RC" -eq 0 ]] && pass "validate_config accepts mongo=$good" \
    || fail "validate_config accepts mongo=$good (rc=$VC_RC, out='$VC_OUT')"
done
# Each refusal names the key, and says what to write instead.
check_bad() {  # $1 = value, $2 = text the message must hold
  vc "$1"
  [[ "$VC_RC" -ne 0 && "$VC_OUT" == *mongo* && "$VC_OUT" == *"$2"* ]] \
    && pass "validate_config refuses mongo=$1, saying: $2" \
    || fail "validate_config refuses mongo=$1 with '$2' (rc=$VC_RC, out='$VC_OUT')"
}
check_bad '8.0,8.2' 'single value'
check_bad on        'capitals'
check_bad Off       'capitals'
check_bad 8.0.32    'pin the series instead: mongo=8.0'
check_bad 8         'mongo=8.0'
check_bad 08.0      'not ON, OFF or a release series'
check_bad latest    'not ON, OFF or a release series'
check_bad 8.x       'not ON, OFF or a release series'

# ── Part F: the shipped default ────────────────────────────────────────────────
grep -qx 'mongo=OFF' "$REPO_DIR/sandbox.conf" && pass "sandbox.conf ships mongo=OFF" || fail "sandbox.conf ships mongo=OFF"

# ── Part C: sandbox.sh passes AI_SERVICES to the container ─────────────────────
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
ai_services_case 'mongo=ON'   'mongo=ON'   "mongo=ON → AI_SERVICES=mongo=ON"
ai_services_case 'mongo=8.2'  'mongo=8.2'  "mongo=8.2 → AI_SERVICES=mongo=8.2 (the runner needs the pin to detect a stale image)"
ai_services_case $'postgres=17\nredis=ON\nmysql=ON\nmongo=8.0' 'postgres=17,redis=ON,mysql=ON,mongo=8.0' "all four servers → one AI_SERVICES"
ai_services_case 'mongo=OFF'  ''           "mongo=OFF → AI_SERVICES empty"

# ── Part D: services.d/mongo.sh against a fake mongod ──────────────────────────
# Isolate from the host environment. MONGO_PORT is unset too, because D7 sets
# it on purpose — an app's own variable, which must not move the server.
unset AI_SERVICES_MONGO_MONGOD AI_SERVICES_MONGO_PORT AI_SERVICES_MONGO_IF_INET6 AI_SERVICES_MONGO_CACHE_GB \
      MONGO_PORT MONGO_URL MONGODB_URI FAKE_MONGOD_RC
FAKE="$TMP_ROOT/mg"; mkdir -p "$FAKE/bin" "$FAKE/data"
printf '00000000000000000000000000000001 01 80 10 80       lo\n' > "$FAKE/inet6-yes"
: > "$FAKE/inet6-no"
cat > "$FAKE/bin/mongod" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'db version v8.0.32\nBuild Info: {\n    "version": "8.0.32"\n}\n'; exit 0
fi
printf '%s\n' "$@" > "$FAKE_DIR/mongod.args"
exit "${FAKE_MONGOD_RC:-0}"
EOF
chmod +x "$FAKE/bin/mongod"
mg() {
  ( export AI_SERVICES_MONGO_MONGOD="$FAKE/bin/mongod" AI_SERVICES_MONGO_PORT="${MG_PORT:-27017}" \
           AI_SERVICES_MONGO_IF_INET6="${MG_INET6:-$FAKE/inet6-no}" FAKE_DIR="$FAKE" FAKE_MONGOD_RC="${FAKE_MONGOD_RC:-0}"
    [[ -n "${MG_CACHE:-}" ]] && export AI_SERVICES_MONGO_CACHE_GB="$MG_CACHE"
    # shellcheck source=../services.d/mongo.sh
    source "$REPO_DIR/services.d/mongo.sh"
    "$@" )
}
mg_reset() { rm -f "$FAKE/mongod.args"; }
# arg_pair <a> <b> — <b> immediately follows <a> in mongod's argv.
arg_pair() { awk -v a="$1" -v b="$2" 'prev == a && $0 == b { f = 1 } { prev = $0 } END { exit !f }' "$FAKE/mongod.args" 2>/dev/null; }
has_arg() { grep -qxF -- "$1" "$FAKE/mongod.args" 2>/dev/null; }

# D1–D3 — what this image has.
got="$(mg svc_installed_version)"
[[ "$got" == "8.0.32" ]] && pass "D1 svc_installed_version reads 8.0.32 out of mongod's version output" || fail "D1 svc_installed_version (got '$got')"
got="$(AI_SERVICES_MONGO_MONGOD="$FAKE/bin/absent" bash -c 'source "$1"; svc_installed_version' _ "$REPO_DIR/services.d/mongo.sh")"; rc=$?
[[ -z "$got" && "$rc" -eq 0 ]] && pass "D2 no mongod → nothing installed, status 0" || fail "D2 no mongod (got '$got', rc=$rc)"
[[ -z "$(mg svc_runtime_dirs)" ]] && pass "D3 svc_runtime_dirs names nothing (the socket goes to /tmp, owner-only)" || fail "D3 svc_runtime_dirs"

# D4 — svc_start: the command line.
mg_reset; mg svc_start "$FAKE/data" "$FAKE/log"; rc=$?
[[ "$rc" -eq 0 ]] && pass "D4 svc_start returns 0 when mongod forks successfully" || fail "D4 svc_start returns 0 (rc=$rc)"
for pair in "--dbpath $FAKE/data" "--logpath $FAKE/log" "--pidfilepath $FAKE/data/mongod.pid" \
            "--port 27017" "--bind_ip 127.0.0.1" "--wiredTigerCacheSizeGB 0.25"; do
  arg_pair "${pair%% *}" "${pair#* }" && pass "D4 mongod gets $pair" || fail "D4 mongod gets $pair (args: $(tr '\n' ' ' < "$FAKE/mongod.args" 2>/dev/null))"
done
for want in --fork --logappend; do has_arg "$want" && pass "D4 mongod gets $want" || fail "D4 mongod gets $want"; done
! has_arg --ipv6 && ! has_arg --bind_ip_all && ! has_arg --config && ! has_arg -f \
  && pass "D4 without IPv6: no --ipv6, never --bind_ip_all, and no config file" || fail "D4 extra args ($(tr '\n' ' ' < "$FAKE/mongod.args"))"

# D5 — ::1 only where the container has an IPv6 loopback.
mg_reset; MG_INET6="$FAKE/inet6-yes" mg svc_start "$FAKE/data" "$FAKE/log"
arg_pair --bind_ip 127.0.0.1,::1 && has_arg --ipv6 && pass "D5 with an IPv6 loopback, ::1 is bound too (--ipv6)" || fail "D5 ::1 ($(tr '\n' ' ' < "$FAKE/mongod.args"))"
mg_reset; MG_INET6="$FAKE/absent" mg svc_start "$FAKE/data" "$FAKE/log"
arg_pair --bind_ip 127.0.0.1 && ! has_arg --ipv6 && pass "D5 without /proc/net/if_inet6 at all, 127.0.0.1 alone" || fail "D5 IPv4 only"

# D6 — mongod failing to fork (the port taken, say) fails svc_start.
mg_reset; FAKE_MONGOD_RC=48 mg svc_start "$FAKE/data" "$FAKE/log"; rc=$?
[[ "$rc" -ne 0 ]] && pass "D6 mongod failing to start fails svc_start" || fail "D6 mongod failure ignored"

# D7 — the port knob moves it; an app's MONGO_PORT does not. The cache knob too.
mg_reset; MG_PORT=27117 mg svc_start "$FAKE/data" "$FAKE/log"
arg_pair --port 27117 && [[ "$(MG_PORT=27117 mg svc_endpoint)" == "mongodb://localhost:27117" ]] \
  && pass "D7 AI_SERVICES_MONGO_PORT moves the server and its endpoint" || fail "D7 port knob"
mg_reset; ( export MONGO_PORT=7777; mg svc_start "$FAKE/data" "$FAKE/log" )
arg_pair --port 27017 && pass "D7 an app's MONGO_PORT does not move it" || fail "D7 MONGO_PORT moved it ($(tr '\n' ' ' < "$FAKE/mongod.args"))"
mg_reset; MG_CACHE=1 mg svc_start "$FAKE/data" "$FAKE/log"
arg_pair --wiredTigerCacheSizeGB 1 && pass "D7 AI_SERVICES_MONGO_CACHE_GB raises the cache cap" || fail "D7 cache knob"

# D8 — nothing to provision; the endpoint is a URL clients take as is.
out="$(mg svc_provision)"; rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && pass "D8 svc_provision returns 0 and adds nothing" || fail "D8 svc_provision (rc=$rc, out='$out')"
[[ "$(mg svc_endpoint)" == "mongodb://localhost:27017" ]] && pass "D8 svc_endpoint is mongodb://localhost:27017" || fail "D8 endpoint"

# D9 — through the runner: the ready line a user sees.
mkdir -p "$TMP_ROOT/state/mongo" "$TMP_ROOT/logs"
out="$(AI_SERVICES=mongo=8.0 AI_SERVICES_DIR="$REPO_DIR/services.d" AI_SERVICES_STATE_ROOT="$TMP_ROOT/state" \
       AI_SERVICES_LOG_ROOT="$TMP_ROOT/logs" AI_SERVICES_MONGO_MONGOD="$FAKE/bin/mongod" \
       AI_SERVICES_MONGO_IF_INET6="$FAKE/inet6-no" FAKE_DIR="$FAKE" bash "$REPO_DIR/start-services.sh" start 2>&1)"
[[ "$out" == *"mongo 8.0.32 ready on mongodb://localhost:27017"* && "$out" != *WARNING* ]] \
  && pass "D9 start-services.sh prints 'mongo 8.0.32 ready on mongodb://localhost:27017', and mongo=8.0 matches 8.0.32" \
  || fail "D9 the runner's ready line (got: $out)"

# ── Part E: the Dockerfile layer's shape ──────────────────────────────────────
DF="$REPO_DIR/Dockerfile"
layer="$(awk '/^ARG MONGO_SERIES=$/{grab=1} grab{print} grab && /^$/{exit}' "$DF")"
[[ -n "$layer" ]] && pass "E the Dockerfile declares ARG MONGO_SERIES= (empty default = skip)" || fail "E ARG MONGO_SERIES="
grep -qF 'if [ -n "$MONGO_SERIES" ]' <<<"$layer" && pass "E the layer is skipped when the arg is empty" || fail "E skip guard"
grep -qF 'server-${major}.0.asc' <<<"$layer" \
  && pass "E the signing key is the MAJOR's (8.2 and 8.3 are signed with server-8.0.asc; there is no server-8.2.asc)" || fail "E key per major"
grep -qF 'apt-get update --error-on=any' <<<"$layer" && pass "E a failed index fetch fails the build" || fail "E --error-on=any"
grep -qF 'mongodb-org-server="${MONGO_SERIES}.*"' <<<"$layer" \
  && pass "E the server is installed from the requested series only, whatever other MongoDB lists are present" || fail "E series-pinned install"
grep -qF 'mongodb-mongosh' <<<"$layer" && pass "E mongosh, the shell, comes with the server" || fail "E mongosh"
grep -qF 'test -x /usr/bin/mongod' <<<"$layer" && pass "E the build fails unless mongod is there" || fail "E mongod check"

# ── Part G: shipping to projects ───────────────────────────────────────────────
payload="$(bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_payload_files "$1"' _ "$REPO_DIR")"
grep -qx 'services.d/mongo.sh' <<<"$payload" \
  && pass "G the provenance digest covers services.d/mongo.sh (it is built into the image)" || fail "G provenance digest"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
