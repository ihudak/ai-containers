#!/usr/bin/env bash
# Unit tests for the `mysql` sandbox.conf key and its adapter.
#
# The key buys a MySQL SERVER inside the container: a build-time layer (Ubuntu's
# mysql-server, and a template data directory initialised once), a run-time env
# var (AI_SERVICES, read by start-services.sh) and an adapter
# (services.d/mysql.sh) that copies the template, starts the server as the
# sandbox user and provisions what container.env asks for.
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring and logic
# assertions, the adapter driven against fake binaries. That the layer BUILDS
# and a real server answers in a real container is integration case
# 790-mysql-server-runs (packages tier, `services` variant), demonstrated
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

# ── Part A: sandbox.conf value → INSTALL_MYSQL build arg ───────────────────────
# ON emits INSTALL_MYSQL=1. OFF, empty and absent emit NO arg at all — not
# INSTALL_MYSQL=0 — so a project that never enables the key keeps its config
# digest.
my_build_args() {  # $1 = sandbox.conf body → every docker build arg, one per line
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

out="$(my_build_args 'mysql=ON')"
grep -qx 'INSTALL_MYSQL=1' <<<"$out" && pass "mysql=ON → INSTALL_MYSQL=1" || fail "mysql=ON → INSTALL_MYSQL=1"
for off in 'mysql=OFF' 'mysql=' 'copilot=ON'; do
  out="$(my_build_args "$off")"
  if [[ -z "$out" ]]; then
    fail "'$off': build_args_from_config produced nothing at all — this assertion verified nothing"
  elif grep -q '^INSTALL_MYSQL=' <<<"$out"; then
    fail "'$off' → no INSTALL_MYSQL build arg (got: $(grep '^INSTALL_MYSQL=' <<<"$out"))"
  else
    pass "'$off' → no INSTALL_MYSQL build arg (never INSTALL_MYSQL=0)"
  fi
done

# ── Part B: validate_config — ON or OFF, in capitals ───────────────────────────
VC_TMP="$(mktemp -d "$TMP_ROOT/vc.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n'; exit 1; }
vc() {  # $1 = mysql value → sets VC_RC and VC_OUT
  printf '# schema-version: 4\nmysql=%s\n' "$1" > "$VC_TMP/sandbox.conf"
  VC_OUT="$(SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" 2>&1)"
  VC_RC=$?
}
for good in ON OFF ''; do
  vc "$good"
  [[ "$VC_RC" -eq 0 ]] && pass "validate_config accepts mysql=$good" \
    || fail "validate_config accepts mysql=$good (rc=$VC_RC, out='$VC_OUT')"
done
for bad in on Off; do
  vc "$bad"
  [[ "$VC_RC" -ne 0 && "$VC_OUT" == *mysql* && "$VC_OUT" == *capitals* ]] \
    && pass "validate_config refuses mysql=$bad, by name, asking for capitals" \
    || fail "validate_config refuses mysql=$bad, by name, asking for capitals (rc=$VC_RC, out='$VC_OUT')"
done
for bad in 8.0 8.4 latest mariadb; do
  vc "$bad"
  [[ "$VC_RC" -ne 0 && "$VC_OUT" == *mysql* && "$VC_OUT" == *"MySQL (8.0)"* && "$VC_OUT" == *"cannot be pinned"* ]] \
    && pass "validate_config refuses mysql=$bad, by name, saying Ubuntu carries one MySQL" \
    || fail "validate_config refuses mysql=$bad (rc=$VC_RC, out='$VC_OUT')"
done

# ── Part F: the shipped default ────────────────────────────────────────────────
grep -qx 'mysql=OFF' "$REPO_DIR/sandbox.conf" && pass "sandbox.conf ships mysql=OFF" || fail "sandbox.conf ships mysql=OFF"

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
ai_services_case 'mysql=ON'                                'mysql=ON'                        "mysql=ON → AI_SERVICES=mysql=ON"
ai_services_case $'postgres=17\nredis=ON\nmysql=ON'        'postgres=17,redis=ON,mysql=ON'   "three servers → one AI_SERVICES, all three"
ai_services_case 'mysql=OFF'                               ''                                "mysql=OFF → AI_SERVICES empty"

# ── Part D: services.d/mysql.sh against fake binaries ──────────────────────────
# Isolate from the host environment: only what Part D or the adapter reads.
# MYSQL_PORT is unset too, because D13 sets it on purpose — an app's own
# variable, which must not move the server — and must be the only thing that does.
unset AI_SERVICES_MYSQL_MYSQLD AI_SERVICES_MYSQL_CLIENT AI_SERVICES_MYSQL_TEMPLATE AI_SERVICES_MYSQL_SOCKET_DIR \
      AI_SERVICES_MYSQL_PORT AI_SERVICES_MYSQL_SELF AI_SERVICES_MYSQL_IF_INET6 \
      MYSQL_USERS MYSQL_DATABASES MYSQL_PORT MYSQL_HOST MYSQL_PWD FAKE_MYSQLD_RC FAKE_SQL_FAIL
FAKE="$TMP_ROOT/my"; mkdir -p "$FAKE/bin" "$FAKE/template/mysql" "$FAKE/sock" "$FAKE/data"
printf 'ibd\n' > "$FAKE/template/mysql.ibd"; printf 'x\n' > "$FAKE/template/mysql/marker"
printf '00000000000000000000000000000001 01 80 10 80       lo\n' > "$FAKE/inet6-yes"
: > "$FAKE/inet6-no"

# Every fake appends to $FAKE_DIR/calls, so an assertion can read the ORDER the
# adapter ran things in, not merely that each ran.
cat > "$FAKE/bin/mysqld" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf '/usr/sbin/mysqld  Ver 8.0.46-0ubuntu0.24.04.4 for Linux on x86_64 ((Ubuntu))\n'; exit 0
fi
printf 'mysqld\n' >> "$FAKE_DIR/calls"
printf '%s\n' "$@" > "$FAKE_DIR/mysqld.args"
exit "${FAKE_MYSQLD_RC:-0}"
EOF
# The client records each -e statement, and fails on one matching FAKE_SQL_FAIL
# the way mysql does — message on stderr, exit 1.
cat > "$FAKE/bin/mysql" <<'EOF'
#!/usr/bin/env bash
sql=""
for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_DIR/client.args"; done
while (( $# )); do [[ "$1" == -e ]] && { sql="$2"; shift; }; shift; done
printf 'sql|%s\n' "$sql" >> "$FAKE_DIR/calls"
printf '%s\n' "$sql" >> "$FAKE_DIR/sql.log"
if [[ -n "${FAKE_SQL_FAIL:-}" ]] && grep -qE -- "$FAKE_SQL_FAIL" <<<"$sql"; then
  printf 'ERROR 1396 (HY000) at line 1: boom for %s\n' "$sql" >&2; exit 1
fi
EOF
chmod +x "$FAKE"/bin/*

# my <function> [args] — run one adapter function in a FRESH subshell, the way
# start-services.sh does, against the fakes.
my() {
  ( export AI_SERVICES_MYSQL_MYSQLD="$FAKE/bin/mysqld" AI_SERVICES_MYSQL_CLIENT="$FAKE/bin/mysql" \
           AI_SERVICES_MYSQL_TEMPLATE="${MY_TEMPLATE:-$FAKE/template}" AI_SERVICES_MYSQL_SOCKET_DIR="$FAKE/sock" \
           AI_SERVICES_MYSQL_PORT="${MY_PORT:-3306}" AI_SERVICES_MYSQL_SELF="${MY_SELF:-alice}" \
           AI_SERVICES_MYSQL_IF_INET6="${MY_INET6:-$FAKE/inet6-no}" \
           FAKE_DIR="$FAKE" FAKE_MYSQLD_RC="${FAKE_MYSQLD_RC:-0}" FAKE_SQL_FAIL="${FAKE_SQL_FAIL:-}"
    # shellcheck source=../services.d/mysql.sh
    source "$REPO_DIR/services.d/mysql.sh"
    "$@" )
}
my_reset() { rm -f "$FAKE"/{calls,mysqld.args,client.args,sql.log}; rm -rf "$FAKE/data"; mkdir -p "$FAKE/data"; }
calls()    { if [[ -f "$FAKE/calls" ]]; then tr '\n' ' ' < "$FAKE/calls"; fi; }
sql_has()  { grep -qxF -- "$1" "$FAKE/sql.log" 2>/dev/null; }
has_arg()  { grep -qxF -- "$1" "$FAKE/mysqld.args" 2>/dev/null; }

# D1–D3 — what this image has.
got="$(my svc_installed_version)"
[[ "$got" == "8.0.46" ]] && pass "D1 svc_installed_version reads 8.0.46 out of Ubuntu's version line" || fail "D1 svc_installed_version (got '$got')"
got="$(MY_TEMPLATE="$FAKE/absent" my svc_installed_version)"; rc=$?
[[ -z "$got" && "$rc" -eq 0 ]] && pass "D2 no template → nothing installed (a bare mysqld is not this layer), status 0" \
  || fail "D2 no template (got '$got', rc=$rc)"
got="$(AI_SERVICES_MYSQL_MYSQLD="$FAKE/bin/absent" bash -c 'source "$1"; svc_installed_version' _ "$REPO_DIR/services.d/mysql.sh")"; rc=$?
[[ -z "$got" && "$rc" -eq 0 ]] && pass "D2 no mysqld → nothing installed, status 0" || fail "D2 no mysqld (got '$got', rc=$rc)"
[[ "$(my svc_runtime_dirs)" == "$FAKE/sock" ]] && pass "D3 svc_runtime_dirs is the socket directory" || fail "D3 svc_runtime_dirs"

# D4 — svc_start: the template copied in, the command line, the user's account.
my_reset; my svc_start "$FAKE/data" "$FAKE/log" >/dev/null; rc=$?
[[ "$rc" -eq 0 ]] && pass "D4 svc_start returns 0" || fail "D4 svc_start returns 0 (rc=$rc)"
[[ -f "$FAKE/data/mysql.ibd" && -f "$FAKE/data/mysql/marker" ]] \
  && pass "D4 the template's contents are copied into the data directory" || fail "D4 template copy"
[[ "$(head -1 "$FAKE/mysqld.args" 2>/dev/null)" == --no-defaults ]] \
  && pass "D4 --no-defaults comes first: no packaged my.cnf is read" || fail "D4 --no-defaults first (got $(head -1 "$FAKE/mysqld.args" 2>/dev/null))"
for want in "--datadir=$FAKE/data" "--socket=$FAKE/sock/mysqld.sock" --port=3306 --bind-address=127.0.0.1 \
            --mysqlx=OFF "--pid-file=$FAKE/data/mysqld.pid" "--log-error=$FAKE/log" --performance-schema=OFF \
            --skip-log-bin --innodb-flush-log-at-trx-commit=0 --innodb-doublewrite=OFF --daemonize; do
  has_arg "$want" && pass "D4 mysqld gets $want" || fail "D4 mysqld gets $want"
done
sql_has "CREATE USER 'alice'@'localhost'; GRANT ALL PRIVILEGES ON *.* TO 'alice'@'localhost' WITH GRANT OPTION" \
  && pass "D4 your own account is created, with every privilege and no password, so a bare mysql connects" \
  || fail "D4 own account (sql: $(tr '\n' '|' < "$FAKE/sql.log" 2>/dev/null))"
[[ "$(calls)" == "mysqld sql|"* ]] && pass "D4 the account is made after the server is up" || fail "D4 order (calls: $(calls))"
grep -qxF -- "--socket=$FAKE/sock/mysqld.sock" "$FAKE/client.args" 2>/dev/null && grep -qxF -- -uroot "$FAKE/client.args" \
  && pass "D4 statements run as root over the socket" || fail "D4 client args (got: $(tr '\n' ' ' < "$FAKE/client.args" 2>/dev/null))"

# D5 — ::1 only where the container has an IPv6 loopback: mysqld refuses to start
# on an address it cannot bind.
my_reset; MY_INET6="$FAKE/inet6-yes" my svc_start "$FAKE/data" "$FAKE/log" >/dev/null
has_arg --bind-address=127.0.0.1,::1 && pass "D5 with an IPv6 loopback, ::1 is bound too" || fail "D5 ::1 bound (args: $(grep bind "$FAKE/mysqld.args"))"
my_reset; MY_INET6="$FAKE/absent" my svc_start "$FAKE/data" "$FAKE/log" >/dev/null
has_arg --bind-address=127.0.0.1 && pass "D5 without one (no /proc/net/if_inet6 at all), 127.0.0.1 alone" || fail "D5 IPv4 only"

# D6 — a server that cannot start fails svc_start, and nothing is run against it.
my_reset; FAKE_MYSQLD_RC=1 my svc_start "$FAKE/data" "$FAKE/log" >/dev/null; rc=$?
[[ "$rc" -ne 0 && ! -f "$FAKE/sql.log" ]] && pass "D6 mysqld failing to start fails svc_start, and no SQL is sent" \
  || fail "D6 mysqld failure (rc=$rc, calls: $(calls))"

# D7 — the account cannot be made: a failure that names it.
my_reset; out="$(FAKE_SQL_FAIL='CREATE USER' my svc_start "$FAKE/data" "$FAKE/log")"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"could not create the account 'alice'"* && "$out" == *boom* ]] \
  && pass "D7 an account that cannot be made fails svc_start, naming it and the error" || fail "D7 (rc=$rc, out='$out')"

# D8 — the user's own name comes from the host and is quoted, not held to the
# pattern; root makes no account.
my_reset; MY_SELF="John.O'Neil\\x" my svc_start "$FAKE/data" "$FAKE/log" >/dev/null
sql_has "CREATE USER 'John.O''Neil\\\\x'@'localhost'; GRANT ALL PRIVILEGES ON *.* TO 'John.O''Neil\\\\x'@'localhost' WITH GRANT OPTION" \
  && pass "D8 a host name like John.O'Neil is quoted: ' doubled, \\ escaped" || fail "D8 quoting (sql: $(cat "$FAKE/sql.log" 2>/dev/null))"
my_reset; MY_SELF=root my svc_start "$FAKE/data" "$FAKE/log" >/dev/null; rc=$?
[[ "$rc" -eq 0 && ! -f "$FAKE/sql.log" ]] && pass "D8 running as root, no account is made (root exists), and the start succeeds" \
  || fail "D8 root self (rc=$rc)"

# D8b — a template that cannot be copied fails the start before mysqld runs.
my_reset; my svc_start "$FAKE/no-such-parent/data" "$FAKE/log" >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 && ! -f "$FAKE/mysqld.args" ]] && pass "D8b a failed template copy fails svc_start, and mysqld never runs" \
  || fail "D8b failed copy (rc=$rc, mysqld ran: $([[ -f "$FAKE/mysqld.args" ]] && echo yes || echo no))"

# D9 — MYSQL_USERS: name or name:password; root's password set LAST.
my_reset
out="$(MYSQL_USERS=" app_user, reporting:s3cr'et ,bad-name,alice,root:r00t,app_user, x:a b\\c,y:" my svc_provision 2>"$FAKE/err")"; rc=$?
[[ "$rc" -eq 0 ]] && pass "D9 svc_provision returns 0" || fail "D9 rc=$rc"
sql_has "CREATE USER 'app_user'@'localhost' IDENTIFIED BY ''; GRANT ALL PRIVILEGES ON *.* TO 'app_user'@'localhost' WITH GRANT OPTION" \
  && pass "D9 a bare name: a user with no password and every privilege" || fail "D9 app_user (sql: $(tr '\n' '|' < "$FAKE/sql.log"))"
sql_has "CREATE USER 'reporting'@'localhost' IDENTIFIED BY 's3cr''et'; GRANT ALL PRIVILEGES ON *.* TO 'reporting'@'localhost' WITH GRANT OPTION" \
  && pass "D9 name:password — the password quoted, ' doubled" || fail "D9 reporting"
sql_has "CREATE USER 'x'@'localhost' IDENTIFIED BY 'a b\\\\c'; GRANT ALL PRIVILEGES ON *.* TO 'x'@'localhost' WITH GRANT OPTION" \
  && pass "D9 a space inside a password is kept, a backslash escaped" || fail "D9 x (sql: $(grep "'x'" "$FAKE/sql.log"))"
[[ "$(grep -c "CREATE USER 'app_user'" "$FAKE/sql.log")" == 1 ]] && ! grep -q "'alice'" "$FAKE/sql.log" \
  && pass "D9 a name listed twice, or your own, is created once or not at all" || fail "D9 duplicates"
grep -q "bad-name" "$FAKE/err" && ! grep -q "bad-name" "$FAKE/sql.log" \
  && pass "D9 an invalid name is skipped with a warning naming it, and never reaches SQL" || fail "D9 invalid name"
[[ "$(tail -1 "$FAKE/sql.log")" == "ALTER USER 'root'@'localhost' IDENTIFIED BY 'r00t'" ]] \
  && pass "D9 root's password is set last, after every statement that runs as root" || fail "D9 root last (last: $(tail -1 "$FAKE/sql.log"))"
[[ "$out" == "; users: app_user, reporting, x, y, root" ]] \
  && pass "D9 the ready line lists the users made, root last, never a password" || fail "D9 suffix (got '$out')"

# D10 — MYSQL_DATABASES: plain names; no owners in MySQL.
my_reset
out="$(MYSQL_DATABASES="myapp_test, myapp_test,other:app_user,Bad,myapp_dev" my svc_provision 2>"$FAKE/err")"
sql_has 'CREATE DATABASE IF NOT EXISTS `myapp_test`' && sql_has 'CREATE DATABASE IF NOT EXISTS `myapp_dev`' \
  && [[ "$(grep -c myapp_test "$FAKE/sql.log")" == 1 ]] \
  && pass "D10 each database is created once, even when listed twice" || fail "D10 databases (sql: $(tr '\n' '|' < "$FAKE/sql.log"))"
grep -q "other:app_user.*no owner" "$FAKE/err" && grep -q "'Bad'" "$FAKE/err" && ! grep -qE 'other|Bad' "$FAKE/sql.log" \
  && pass "D10 name:owner and an invalid name are skipped with a warning saying why" || fail "D10 warnings ($(cat "$FAKE/err"))"
[[ "$out" == "; databases: myapp_test, myapp_dev" ]] && pass "D10 the ready line lists each database once" || fail "D10 suffix (got '$out')"

# D11 — a statement that fails is warned about, and the rest still run.
my_reset
out="$(FAKE_SQL_FAIL="'app_user'" MYSQL_USERS="app_user,second" my svc_provision 2>"$FAKE/err")"; rc=$?
[[ "$rc" -eq 0 && "$out" == "; users: second" ]] && grep -q "could not create user 'app_user'.*boom" "$FAKE/err" \
  && pass "D11 a failing CREATE is warned about and skipped; the next still runs; status 0" || fail "D11 (rc=$rc, out='$out', err=$(cat "$FAKE/err"))"

# D12 — the endpoint says who has no password.
[[ "$(my svc_endpoint)" == "localhost:3306 (socket $FAKE/sock/mysqld.sock), root and alice with no password" ]] \
  && pass "D12 svc_endpoint: port, socket, and root and you with no password" || fail "D12 endpoint (got '$(my svc_endpoint)')"
[[ "$(MYSQL_USERS="app_user, root:pw" my svc_endpoint)" == "localhost:3306 (socket $FAKE/sock/mysqld.sock), alice with no password" ]] \
  && pass "D12 once MYSQL_USERS gives root a password, the endpoint no longer says root has none" || fail "D12 root pw endpoint"
for u in "reporting:pw" "root" "app_user, root ,x:y"; do
  [[ "$(MYSQL_USERS="$u" my svc_endpoint)" == *"root and alice with no password" ]] \
    && pass "D12 MYSQL_USERS='$u' gives root no password: the endpoint still says root has none" \
    || fail "D12 MYSQL_USERS='$u' endpoint (got '$(MYSQL_USERS="$u" my svc_endpoint)')"
done

# D13 — the port knob moves it; an app's own MYSQL_PORT does not.
my_reset; MY_PORT=13306 my svc_start "$FAKE/data" "$FAKE/log" >/dev/null
has_arg --port=13306 && pass "D13 AI_SERVICES_MYSQL_PORT moves the server" || fail "D13 port knob"
my_reset; ( export MYSQL_PORT=7777; my svc_start "$FAKE/data" "$FAKE/log" >/dev/null )
has_arg --port=3306 && pass "D13 an app's MYSQL_PORT does not move it" || fail "D13 MYSQL_PORT moved it ($(grep port "$FAKE/mysqld.args"))"

# D14 — through the runner: the ready line a user sees.
my_reset; mkdir -p "$TMP_ROOT/state/mysql" "$TMP_ROOT/logs"
out="$(AI_SERVICES=mysql=ON AI_SERVICES_DIR="$REPO_DIR/services.d" AI_SERVICES_STATE_ROOT="$TMP_ROOT/state" \
       AI_SERVICES_LOG_ROOT="$TMP_ROOT/logs" AI_SERVICES_MYSQL_MYSQLD="$FAKE/bin/mysqld" AI_SERVICES_MYSQL_CLIENT="$FAKE/bin/mysql" \
       AI_SERVICES_MYSQL_TEMPLATE="$FAKE/template" AI_SERVICES_MYSQL_SOCKET_DIR="$FAKE/sock" AI_SERVICES_MYSQL_SELF=alice \
       AI_SERVICES_MYSQL_IF_INET6="$FAKE/inet6-no" FAKE_DIR="$FAKE" MYSQL_USERS=app_user MYSQL_DATABASES=myapp_test \
       bash "$REPO_DIR/start-services.sh" start 2>&1)"
[[ "$out" == *"mysql 8.0.46 ready on localhost:3306 (socket $FAKE/sock/mysqld.sock), root and alice with no password; users: app_user; databases: myapp_test"* ]] \
  && pass "D14 start-services.sh prints the ready line with what was provisioned" || fail "D14 runner ready line (got: $out)"

# ── Part E: the Dockerfile layer's shape ──────────────────────────────────────
# Shape only: that it BUILDS and the template starts is integration case 790.
DF="$REPO_DIR/Dockerfile"
layer="$(awk '/^ARG INSTALL_MYSQL=0$/{grab=1} grab{print} grab && /^$/{exit}' "$DF")"
[[ -n "$layer" ]] && pass "E the Dockerfile declares ARG INSTALL_MYSQL=0 (skipped unless ON)" || fail "E ARG INSTALL_MYSQL=0"
grep -qF 'if [ "$INSTALL_MYSQL" = "1" ]' <<<"$layer" && pass "E the layer runs only for INSTALL_MYSQL=1" || fail "E skip guard"
grep -qF 'apt-get install -y --no-install-recommends mysql-server tzdata' <<<"$layer" \
  && pass "E it installs Ubuntu's mysql-server, and tzdata for the zone tables" || fail "E install"
grep -qF 'rm -rf /var/lib/apt/lists/* /var/lib/mysql/*' <<<"$layer" \
  && pass "E the package's own data directory (181 MB, unused) is emptied" || fail "E /var/lib/mysql emptied"
grep -qF -- '--initialize-insecure' <<<"$layer" && grep -qF 'tpl=/usr/share/ai-containers/mysql-template' <<<"$layer" \
  && pass "E the template is initialised at build time, where the adapter looks for it" || fail "E template"
grep -qF -- '--skip-networking' <<<"$layer" && pass "E the bootstrap server listens on no port" || fail "E --skip-networking"
grep -qF 'mysql_tzinfo_to_sql /usr/share/zoneinfo' <<<"$layer" && pass "E the time zone tables are loaded, as the official image does" || fail "E zones"
grep -qF '[ ! -e "$bs/pid" ]' <<<"$layer" && pass "E the layer waits for the bootstrap server to exit before it is snapshot" || fail "E waits for exit"
grep -qF 'chmod -R a+rX "$tpl"' <<<"$layer" && pass "E the template is readable by the sandbox user, who copies it" || fail "E a+rX"
grep -qF 'test -f "$tpl/mysql.ibd"' <<<"$layer" && pass "E the build fails unless the template holds a data directory" || fail "E template check"

# ── Part G: shipping to projects ───────────────────────────────────────────────
payload="$(bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_payload_files "$1"' _ "$REPO_DIR")"
grep -qx 'services.d/mysql.sh' <<<"$payload" \
  && pass "G the provenance digest covers services.d/mysql.sh (it is built into the image)" || fail "G provenance digest"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
