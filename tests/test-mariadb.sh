#!/usr/bin/env bash
# Unit tests for the `mariadb` sandbox.conf key and its adapter.
#
# The key buys a MariaDB SERVER inside the container: a build-time layer
# (Ubuntu's mariadb-server for ON, a series from MariaDB's own repository for a
# pin, and a template data directory initialised once), a run-time env var
# (AI_SERVICES, read by start-services.sh) and an adapter (services.d/mariadb.sh)
# that is the MySQL adapter with MariaDB's binaries, template and start.
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring and logic
# assertions, the adapter driven against fake binaries. That the layer BUILDS
# and a real server answers in a real container is integration case
# 810-mariadb-server-runs (packages tier, `mariadb` variant), demonstrated
# failing by its mutations. What the adapter shares with MySQL (provisioning,
# the endpoint) is tests/test-mysql.sh's; this file asserts it is wired here.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
TMP_ROOT="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
# The fake server stays up as a `sleep`, as a real one would; every one is
# recorded in $TMP_ROOT/md/daemons and killed on the way out.
cleanup() {
  [[ "$BASHPID" == "$TMP_OWNER" ]] || return 0
  local p
  if [[ -f "$TMP_ROOT/md/daemons" ]]; then
    while IFS= read -r p; do kill "$p" 2>/dev/null; done < "$TMP_ROOT/md/daemons"
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# ── Part A: sandbox.conf value → MARIADB_SERIES build arg ──────────────────────
md_build_args() {  # $1 = sandbox.conf body → every docker build arg, one per line
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
out="$(md_build_args 'mariadb=ON')"
grep -qx 'MARIADB_SERIES=ubuntu' <<<"$out" && pass "mariadb=ON → MARIADB_SERIES=ubuntu (Ubuntu's own package)" || fail "mariadb=ON → MARIADB_SERIES=ubuntu"
out="$(md_build_args 'mariadb=11.4')"
grep -qx 'MARIADB_SERIES=11.4' <<<"$out" && pass "mariadb=11.4 → MARIADB_SERIES=11.4 (MariaDB's repository)" || fail "mariadb=11.4 → MARIADB_SERIES=11.4"
for off in 'mariadb=OFF' 'mariadb=' 'copilot=ON'; do
  out="$(md_build_args "$off")"
  if [[ -z "$out" ]]; then
    fail "'$off': build_args_from_config produced nothing at all — this assertion verified nothing"
  elif grep -q '^MARIADB_SERIES=' <<<"$out"; then
    fail "'$off' → no MARIADB_SERIES build arg (got: $(grep '^MARIADB_SERIES=' <<<"$out"))"
  else
    pass "'$off' → no MARIADB_SERIES build arg"
  fi
done

# ── Part B: validate_config ────────────────────────────────────────────────────
VC_TMP="$(mktemp -d "$TMP_ROOT/vc.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n'; exit 1; }
vc() {  # $1 = sandbox.conf body → sets VC_RC and VC_OUT
  printf '# schema-version: 4\n%s\n' "$1" > "$VC_TMP/sandbox.conf"
  VC_OUT="$(SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" 2>&1)"
  VC_RC=$?
}
for good in ON OFF '' 10.11 11.4 12.3; do
  vc "mariadb=$good"
  [[ "$VC_RC" -eq 0 ]] && pass "validate_config accepts mariadb=$good" || fail "validate_config accepts mariadb=$good (rc=$VC_RC, out='$VC_OUT')"
done
check_bad() {  # $1 = conf body, $2 = text the message must hold
  vc "$1"
  [[ "$VC_RC" -ne 0 && "$VC_OUT" == *mariadb* && "$VC_OUT" == *"$2"* ]] \
    && pass "validate_config refuses '${1//$'\n'/ }', saying: $2" \
    || fail "validate_config refuses '${1//$'\n'/ }' with '$2' (rc=$VC_RC, out='$VC_OUT')"
}
check_bad 'mariadb=11.4,11.8'        'single value'
check_bad 'mariadb=on'               'capitals'
check_bad 'mariadb=Off'              'capitals'
check_bad 'mariadb=11.4.5'           'pin the series instead: mariadb=11.4'
check_bad 'mariadb=11'               'not ON, OFF or a release series'
check_bad 'mariadb=latest'           'not ON, OFF or a release series'
check_bad $'mysql=ON\nmariadb=ON'    'choose one'
check_bad $'mysql=ON\nmariadb=11.4'  'choose one'
vc $'mysql=OFF\nmariadb=ON'
[[ "$VC_RC" -eq 0 ]] && pass "validate_config accepts mariadb=ON beside mysql=OFF" || fail "mariadb beside mysql=OFF (out='$VC_OUT')"

# ── Part F: the shipped default ────────────────────────────────────────────────
grep -qx 'mariadb=OFF' "$REPO_DIR/sandbox.conf" && pass "sandbox.conf ships mariadb=OFF" || fail "sandbox.conf ships mariadb=OFF"

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
ai_services_case 'mariadb=ON'    'mariadb=ON'    "mariadb=ON → AI_SERVICES=mariadb=ON"
ai_services_case 'mariadb=11.4'  'mariadb=11.4'  "mariadb=11.4 → AI_SERVICES=mariadb=11.4 (the runner needs the pin to detect a stale image)"
ai_services_case $'postgres=17\nredis=ON\nmariadb=11.4\nmongo=8.0' 'postgres=17,redis=ON,mariadb=11.4,mongo=8.0' "with the others → one AI_SERVICES"
ai_services_case 'mariadb=OFF'   ''              "mariadb=OFF → AI_SERVICES empty"

# ── Part D: services.d/mariadb.sh against fake binaries ────────────────────────
# Isolate from the host environment. The app-side names (MYSQL_PORT,
# MARIADB_PORT) and MySQL's own knob (AI_SERVICES_MYSQL_PORT) are unset too,
# because D10 sets each on purpose and must be the only thing that does.
unset AI_SERVICES_MARIADB_MARIADBD AI_SERVICES_MARIADB_CLIENT AI_SERVICES_MARIADB_TEMPLATE \
      AI_SERVICES_MARIADB_SOCKET_DIR AI_SERVICES_MARIADB_PORT AI_SERVICES_MARIADB_SELF \
      AI_SERVICES_MARIADB_IF_INET6 AI_SERVICES_MARIADB_TRIES \
      AI_SERVICES_MYSQL_MYSQLD AI_SERVICES_MYSQL_CLIENT AI_SERVICES_MYSQL_TEMPLATE AI_SERVICES_MYSQL_SOCKET_DIR \
      AI_SERVICES_MYSQL_PORT AI_SERVICES_MYSQL_SELF AI_SERVICES_MYSQL_IF_INET6 \
      MYSQL_USERS MYSQL_DATABASES MYSQL_PORT MARIADB_PORT FAKE_MODE FAKE_SQL_FAIL
FAKE="$TMP_ROOT/md"; mkdir -p "$FAKE/bin" "$FAKE/template/mysql" "$FAKE/sock" "$FAKE/data"
: > "$FAKE/daemons"
printf 'frm\n' > "$FAKE/template/mysql/global_priv.frm"
printf '00000000000000000000000000000001 01 80 10 80       lo\n' > "$FAKE/inet6-yes"
: > "$FAKE/inet6-no"

# The fake server: --version and --print-defaults answer as MariaDB 11.4's do
# (its package config sets the character set, the collation, and options that
# must NOT be passed back, such as --socket); a start records its argv and, by
# FAKE_MODE, stays up as the server (`ok`, exec'ing a sleep so the adapter's pid
# is the server's) or exits at once (`exit`, a port already taken).
cat > "$FAKE/bin/mariadbd" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'mariadbd  Ver 11.4.13-MariaDB-ubu2404 for debian-linux-gnu on x86_64 (mariadb.org binary distribution)\n'; exit 0 ;;
  --print-defaults)
    printf 'mariadbd would have been started with the following arguments:\n'
    printf -- '--socket=/run/mysqld/mysqld.sock --expire_logs_days=10 --character-set-server=utf8mb4 --character-set-collations=utf8mb4=uca1400_ai_ci\n'
    exit 0 ;;
esac
printf '%s\n' "$@" > "$FAKE_DIR/mariadbd.args"
printf 'mariadbd\n' >> "$FAKE_DIR/calls"
[[ "${FAKE_MODE:-ok}" == exit ]] && exit 1
for a in "$@"; do [[ "$a" == --pid-file=* ]] && printf '%s\n' "${a#--pid-file=}" > "$FAKE_DIR/pid_file"; done
printf '%s\n' "$$" >> "$FAKE_DIR/daemons"
exec sleep 300
EOF
# The fake client: `SELECT @@pid_file` answers with $FAKE_DIR/answer.pid_file
# when that exists (ANOTHER server on the socket), else with the one the fake
# server was given — and with nothing (exit 1) when no server is up. Every other
# statement is recorded, and fails on FAKE_SQL_FAIL as the client does.
cat > "$FAKE/bin/mariadb" <<'EOF'
#!/usr/bin/env bash
sql=""
for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_DIR/client.args"; done
while (( $# )); do [[ "$1" == -e ]] && { sql="$2"; shift; }; shift; done
if [[ "$sql" == 'SELECT @@pid_file' ]]; then
  if [[ -f "$FAKE_DIR/answer.pid_file" ]]; then cat "$FAKE_DIR/answer.pid_file"; exit 0; fi
  [[ -f "$FAKE_DIR/pid_file" ]] || exit 1
  cat "$FAKE_DIR/pid_file"; exit 0
fi
printf 'sql|%s\n' "$sql" >> "$FAKE_DIR/calls"
printf '%s\n' "$sql" >> "$FAKE_DIR/sql.log"
if [[ -n "${FAKE_SQL_FAIL:-}" ]] && grep -qE -- "$FAKE_SQL_FAIL" <<<"$sql"; then
  printf 'ERROR 1396 (HY000) at line 1: boom for %s\n' "$sql" >&2; exit 1
fi
EOF
chmod +x "$FAKE"/bin/*

md() {
  ( export AI_SERVICES_MARIADB_MARIADBD="$FAKE/bin/mariadbd" AI_SERVICES_MARIADB_CLIENT="$FAKE/bin/mariadb" \
           AI_SERVICES_MARIADB_TEMPLATE="${MD_TEMPLATE:-$FAKE/template}" AI_SERVICES_MARIADB_SOCKET_DIR="$FAKE/sock" \
           AI_SERVICES_MARIADB_PORT="${MD_PORT:-3306}" AI_SERVICES_MARIADB_SELF="${MD_SELF:-alice}" \
           AI_SERVICES_MARIADB_IF_INET6="${MD_INET6:-$FAKE/inet6-no}" AI_SERVICES_MARIADB_TRIES="${MD_TRIES:-50}" \
           FAKE_DIR="$FAKE" FAKE_MODE="${FAKE_MODE:-ok}" FAKE_SQL_FAIL="${FAKE_SQL_FAIL:-}"
    # shellcheck source=../services.d/mariadb.sh
    source "$REPO_DIR/services.d/mariadb.sh"
    "$@" )
}
md_reset() { rm -f "$FAKE"/{calls,mariadbd.args,client.args,sql.log,pid_file,answer.pid_file}; rm -rf "$FAKE/data"; mkdir -p "$FAKE/data"; }
calls()   { if [[ -f "$FAKE/calls" ]]; then tr '\n' ' ' < "$FAKE/calls"; fi; }
sql_has() { grep -qxF -- "$1" "$FAKE/sql.log" 2>/dev/null; }
has_arg() { grep -qxF -- "$1" "$FAKE/mariadbd.args" 2>/dev/null; }

# D1–D3 — what this image has: the MySQL adapter's checks, on MariaDB's paths.
got="$(md svc_installed_version)"
[[ "$got" == "11.4.13" ]] && pass "D1 svc_installed_version reads 11.4.13 out of mariadbd's version line" || fail "D1 (got '$got')"
got="$(MD_TEMPLATE="$FAKE/absent" md svc_installed_version)"; rc=$?
[[ -z "$got" && "$rc" -eq 0 ]] && pass "D2 no template → nothing installed, status 0" || fail "D2 no template (got '$got', rc=$rc)"
[[ "$(md svc_runtime_dirs)" == "$FAKE/sock" ]] && pass "D3 svc_runtime_dirs is the socket directory" || fail "D3 svc_runtime_dirs"

# D4 — svc_start: the template, the command line, the character set, the account.
md_reset; md svc_start "$FAKE/data" "$FAKE/log" >/dev/null; rc=$?
[[ "$rc" -eq 0 ]] && pass "D4 svc_start returns 0 once the server it started answers" || fail "D4 svc_start (rc=$rc)"
[[ -f "$FAKE/data/mysql/global_priv.frm" ]] && pass "D4 the template is copied into the data directory" || fail "D4 template copy"
[[ "$(head -1 "$FAKE/mariadbd.args" 2>/dev/null)" == --no-defaults ]] && pass "D4 --no-defaults comes first" || fail "D4 --no-defaults first"
for want in "--datadir=$FAKE/data" "--socket=$FAKE/sock/mysqld.sock" --port=3306 --bind-address=127.0.0.1 \
            "--pid-file=$FAKE/data/mariadbd.pid" "--log-error=$FAKE/log" --skip-log-bin --innodb-log-file-size=8388608 \
            --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=OFF; do
  has_arg "$want" && pass "D4 mariadbd gets $want" || fail "D4 mariadbd gets $want"
done
has_arg --character-set-server=utf8mb4 && has_arg --character-set-collations=utf8mb4=uca1400_ai_ci \
  && pass "D4 the package's own character set and collation are passed back (run bare, 10.11 serves latin1)" \
  || fail "D4 character set from the package defaults (args: $(tr '\n' ' ' < "$FAKE/mariadbd.args"))"
! has_arg --socket=/run/mysqld/mysqld.sock && ! has_arg --expire_logs_days=10 && ! has_arg --daemonize \
  && pass "D4 nothing else of the package defaults is passed, and no --daemonize (mariadbd has none)" \
  || fail "D4 stray args (args: $(tr '\n' ' ' < "$FAKE/mariadbd.args"))"
sql_has "CREATE USER 'alice'@'localhost'; GRANT ALL PRIVILEGES ON *.* TO 'alice'@'localhost' WITH GRANT OPTION" \
  && [[ "$(calls)" == "mariadbd sql|"* ]] \
  && pass "D4 your own account is created, after the server answers, through MariaDB's client" \
  || fail "D4 own account (calls: $(calls))"

# D5 — ::1 only where the container has an IPv6 loopback.
md_reset; MD_INET6="$FAKE/inet6-yes" md svc_start "$FAKE/data" "$FAKE/log" >/dev/null
has_arg --bind-address=127.0.0.1,::1 && pass "D5 with an IPv6 loopback, ::1 is bound too" || fail "D5 ::1"

# D6 — another server on the socket is never taken for this one; the wait is
# bounded by AI_SERVICES_MARIADB_TRIES (3 tries is 0.3 s, not the 30 s default).
md_reset; printf '/elsewhere/mariadbd.pid\n' > "$FAKE/answer.pid_file"
start=$(date +%s); out="$(MD_TRIES=3 md svc_start "$FAKE/data" "$FAKE/log")"; rc=$?; took=$(( $(date +%s) - start ))
[[ "$rc" -ne 0 && "$out" == *"did not answer"* && ! -f "$FAKE/sql.log" ]] \
  && pass "D6 another server answering on the socket is not this one: not ready, and no account is made on it" \
  || fail "D6 another server (rc=$rc, out='$out', sql: $(cat "$FAKE/sql.log" 2>/dev/null))"
# 15 s, not 5: half the 30 s an unbounded wait takes, so ignoring the bound still
# fails, with room for a host loaded by a falsify run beside it (7-8 s measured).
[[ "$took" -le 15 ]] && pass "D6 AI_SERVICES_MARIADB_TRIES bounds the wait (${took}s for 3 tries)" || fail "D6 tries ignored (${took}s)"

# D7 — a server that exits at once (the port taken) fails at once, not after
# the 30 s wait.
md_reset; start=$(date +%s); out="$(FAKE_MODE=exit MD_TRIES=300 md svc_start "$FAKE/data" "$FAKE/log")"; rc=$?; took=$(( $(date +%s) - start ))
[[ "$rc" -ne 0 && "$out" == *"exited before answering"* && "$took" -le 15 ]] \
  && pass "D7 a server that exits before answering fails at once (${took}s), naming its pid" \
  || fail "D7 exited server (rc=$rc, took ${took}s, out='$out')"

# D8 — a template that cannot be copied fails before mariadbd runs; an account
# that cannot be made fails the start, naming it.
md_reset; md svc_start "$FAKE/no-such-parent/data" "$FAKE/log" >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 && ! -f "$FAKE/mariadbd.args" ]] && pass "D8 a failed template copy fails svc_start, and mariadbd never runs" || fail "D8 copy (rc=$rc)"
md_reset; out="$(FAKE_SQL_FAIL='CREATE USER' md svc_start "$FAKE/data" "$FAKE/log")"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"could not create the account 'alice'"* ]] && pass "D8 an account that cannot be made fails the start, naming it" || fail "D8 account (rc=$rc, out='$out')"

# D9 — provisioning is MySQL's, through MariaDB's client.
md_reset
out="$(MYSQL_USERS='app_user,rep:p@ss' MYSQL_DATABASES=myapp_test md svc_provision 2>&1)"
sql_has "CREATE USER 'rep'@'localhost' IDENTIFIED BY 'p@ss'; GRANT ALL PRIVILEGES ON *.* TO 'rep'@'localhost' WITH GRANT OPTION" \
  && sql_has 'CREATE DATABASE IF NOT EXISTS `myapp_test`' && [[ "$out" == "; users: app_user, rep; databases: myapp_test" ]] \
  && pass "D9 MYSQL_USERS / MYSQL_DATABASES provision MariaDB as they do MySQL" || fail "D9 provisioning (out='$out')"

# D10 — the knob moves it; an app's MYSQL_PORT or MARIADB_PORT, or MySQL's own
# knob, does not.
md_reset; MD_PORT=13306 md svc_start "$FAKE/data" "$FAKE/log" >/dev/null
has_arg --port=13306 && pass "D10 AI_SERVICES_MARIADB_PORT moves the server" || fail "D10 port knob"
md_reset; ( export MYSQL_PORT=7777 MARIADB_PORT=7778 AI_SERVICES_MYSQL_PORT=7779; md svc_start "$FAKE/data" "$FAKE/log" >/dev/null )
has_arg --port=3306 && pass "D10 an app's MYSQL_PORT / MARIADB_PORT, and MySQL's own knob, do not move it" || fail "D10 ($(grep port "$FAKE/mariadbd.args"))"

# D11 — through the runner: the ready line, and the stale-image warning a pin gets.
md_reset; mkdir -p "$TMP_ROOT/state/mariadb" "$TMP_ROOT/logs"
runner() {  # $1 = AI_SERVICES value
  AI_SERVICES="$1" AI_SERVICES_DIR="$REPO_DIR/services.d" AI_SERVICES_STATE_ROOT="$TMP_ROOT/state" \
  AI_SERVICES_LOG_ROOT="$TMP_ROOT/logs" AI_SERVICES_MARIADB_MARIADBD="$FAKE/bin/mariadbd" \
  AI_SERVICES_MARIADB_CLIENT="$FAKE/bin/mariadb" AI_SERVICES_MARIADB_TEMPLATE="$FAKE/template" \
  AI_SERVICES_MARIADB_SOCKET_DIR="$FAKE/sock" AI_SERVICES_MARIADB_SELF=alice AI_SERVICES_MARIADB_IF_INET6="$FAKE/inet6-no" \
  FAKE_DIR="$FAKE" MYSQL_USERS=app_user MYSQL_DATABASES=myapp_test bash "$REPO_DIR/start-services.sh" start 2>&1
}
out="$(runner mariadb=11.4)"
[[ "$out" == *"mariadb 11.4.13 ready on localhost:3306 (socket $FAKE/sock/mysqld.sock), root and alice with no password; users: app_user; databases: myapp_test"* && "$out" != *WARNING* ]] \
  && pass "D11 start-services.sh prints the ready line, and mariadb=11.4 matches 11.4.13" || fail "D11 ready line (got: $out)"
md_reset; rm -rf "$TMP_ROOT/state/mariadb"/*
out="$(runner mariadb=10.11)"
[[ "$out" == *"WARNING: sandbox.conf asks for mariadb=10.11, this image has 11.4.13. Rebuild: ./build.sh"* ]] \
  && pass "D11 a pin the image does not hold is named in a warning" || fail "D11 stale image (got: $out)"

# ── Part E: the Dockerfile layer's shape ──────────────────────────────────────
DF="$REPO_DIR/Dockerfile"
layer="$(awk '/^ARG MARIADB_SERIES=$/{grab=1} grab{print} grab && /^$/{exit}' "$DF")"
[[ -n "$layer" ]] && pass "E the Dockerfile declares ARG MARIADB_SERIES= (empty default = skip)" || fail "E ARG MARIADB_SERIES="
grep -qF 'if [ -n "$MARIADB_SERIES" ]' <<<"$layer" && pass "E the layer is skipped when the arg is empty" || fail "E skip guard"
grep -qF 'pkgs=(mariadb-server)' <<<"$layer" && grep -qF 'if [ "$MARIADB_SERIES" != ubuntu ]' <<<"$layer" \
  && pass "E ON installs Ubuntu's own mariadb-server, with no third-party repository" || fail "E ubuntu path"
rel_at="$(grep -nF '/Release"' <<<"$layer" | head -1 | cut -d: -f1)"
upd_at="$(grep -nF 'apt-get update --error-on=any' <<<"$layer" | head -1 | cut -d: -f1)"
[[ -n "$rel_at" && -n "$upd_at" && "$rel_at" -lt "$upd_at" ]] \
  && pass "E a pinned series is checked for (its Release file) before apt sees the repository" || fail "E Release check order"
grep -qF 'https://supplychain.mariadb.com/mariadb-keyring-2019.gpg' <<<"$layer" && pass "E MariaDB's signing keyring" || fail "E keyring"
grep -qF '"mariadb-server=1:${MARIADB_SERIES}.*" "mariadb-client-compat=1:${MARIADB_SERIES}.*"' <<<"$layer" \
  && pass "E a pinned series installs from that series only, with the client's \`mysql\` links" || fail "E series-pinned install"
grep -qF 'rm -rf /var/lib/apt/lists/* /var/lib/mysql/*' <<<"$layer" && pass "E the package's own data directory is emptied" || fail "E /var/lib/mysql"
grep -qF -- '--auth-root-authentication-method=normal' <<<"$layer" && grep -qF -- '--innodb-log-file-size=8388608' <<<"$layer" \
  && pass "E the template: root with a (empty) password, not unix_socket; an 8 MB redo log" || fail "E template options"
grep -qF -- '--skip-networking' <<<"$layer" && pass "E the bootstrap server listens on no port" || fail "E --skip-networking"
grep -qF 'mariadb-tzinfo-to-sql /usr/share/zoneinfo' <<<"$layer" && pass "E the time zone tables are loaded" || fail "E zones"
grep -qF '[ ! -e "$bs/pid" ]' <<<"$layer" && pass "E the layer waits for the bootstrap server to exit before it is snapshot" || fail "E waits for exit"
grep -qF 'test -e /usr/bin/mysql' <<<"$layer" && pass "E the build fails unless \`mysql\` runs MariaDB's client" || fail "E mysql link check"

# ── Part G: shipping to projects ───────────────────────────────────────────────
payload="$(bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_payload_files "$1"' _ "$REPO_DIR")"
grep -qx 'services.d/mariadb.sh' <<<"$payload" \
  && pass "G the provenance digest covers services.d/mariadb.sh (it is built into the image)" || fail "G provenance digest"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
