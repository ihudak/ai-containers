#!/usr/bin/env bash
# Unit tests for the `postgres` sandbox.conf key and its adapter.
#
# The key buys a PostgreSQL SERVER inside the container: a build-time layer (the
# PGDG packages), a run-time env var (AI_SERVICES, read by start-services.sh) and
# an adapter (services.d/postgres.sh) that initialises, starts and provisions a
# throwaway cluster as the sandbox user.
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring and logic
# assertions, the adapter driven against fake binaries. That the layer BUILDS
# and a real server answers in a real container is integration case
# 780-postgres-server-runs (packages tier, `native` variant), demonstrated
# failing by mutations 780-782. The runner's own contract is
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

# ── Part A: sandbox.conf value → POSTGRES_VERSION build arg ────────────────────
# ON cannot pass through as the literal "ON" — the layer would look for a package
# named postgresql-ON — so it becomes `latest`, which the layer resolves through
# PGDG's own `postgresql` metapackage. A pinned major passes verbatim. OFF and
# empty emit NO arg at all (not an empty one): the Dockerfile's ARG defaults to
# empty, and a project that never enables the key keeps the config digest it had.

pg_build_args() {  # $1 = sandbox.conf body → every docker build arg, one per line
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

out="$(pg_build_args 'postgres=ON')"
grep -qx 'POSTGRES_VERSION=latest' <<<"$out" \
  && pass "postgres=ON → POSTGRES_VERSION=latest" \
  || fail "postgres=ON → POSTGRES_VERSION=latest"

out="$(pg_build_args 'postgres=17')"
grep -qx 'POSTGRES_VERSION=17' <<<"$out" \
  && pass "postgres=17 → POSTGRES_VERSION=17 (pinned major, verbatim)" \
  || fail "postgres=17 → POSTGRES_VERSION=17"

for off in 'postgres=OFF' 'postgres=' 'copilot=ON'; do
  out="$(pg_build_args "$off")"
  if [[ -z "$out" ]]; then
    fail "'$off': build_args_from_config produced nothing at all — this assertion verified nothing"
  elif grep -q '^POSTGRES_VERSION=' <<<"$out"; then
    fail "'$off' → no POSTGRES_VERSION build arg (got: $(grep '^POSTGRES_VERSION=' <<<"$out"))"
  else
    pass "'$off' → no POSTGRES_VERSION build arg (never an empty or literal-OFF one)"
  fi
done

# ── Part B: validate_config — one value, capitals, a major ─────────────────────
VC_TMP="$(mktemp -d "$TMP_ROOT/vc.XXXXXX")" || { printf 'SCAFFOLD-FAILED: mktemp\n'; exit 1; }
vc() {  # $1 = postgres value → sets VC_RC and VC_OUT
  printf '# schema-version: 4\npostgres=%s\n' "$1" > "$VC_TMP/sandbox.conf"
  VC_OUT="$(SANDBOX_CONF="$VC_TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; validate_config" 2>&1)"
  VC_RC=$?
}

for good in ON OFF '' 10 17 18; do
  vc "$good"
  [[ "$VC_RC" -eq 0 ]] \
    && pass "validate_config accepts postgres=$good" \
    || fail "validate_config accepts postgres=$good (rc=$VC_RC, out='$VC_OUT')"
done

# Each refusal must NAME the key: an error that does not say "postgres" sends the
# reader looking everywhere but here.
for bad in '16,17' on Off oN latest 17beta1 abc 017 0 00; do
  vc "$bad"
  if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *postgres* ]]; then
    pass "validate_config refuses postgres=$bad, by name"
  else
    fail "validate_config refuses postgres=$bad, by name (rc=$VC_RC, out='$VC_OUT')"
  fi
done

# A minor is refused AND the message hands back the major to pin instead —
# without a leading zero, which would be refused next time.
for v in 17.2 017.2 017; do
  vc "$v"
  if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *"postgres=17"* && "$VC_OUT" != *"postgres=017 pins"* ]] \
     && ! grep -qE 'write postgres=0|instead: postgres=0' <<<"$VC_OUT"; then
    pass "validate_config refuses postgres=$v and suggests postgres=17"
  else
    fail "validate_config refuses postgres=$v and suggests postgres=17 (rc=$VC_RC, out='$VC_OUT')"
  fi
done

# ── Part F: the shipped default ────────────────────────────────────────────────
# New keys reach every project through sync's append, so the upstream default is
# what every project gets until someone opts in. Off, because it costs ~180 MB.
grep -qx 'postgres=OFF' "$REPO_DIR/sandbox.conf" \
  && pass "sandbox.conf ships postgres=OFF" \
  || fail "sandbox.conf ships postgres=OFF"

# ── Part C: sandbox.sh passes AI_SERVICES to the container ─────────────────────
# Driven through a fake `docker` on PATH that captures the assembled `docker run`
# argv — the harness tests/test-playwright.sh uses. No daemon involved.
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
ai_services_case 'postgres=ON'  'postgres=ON' "postgres=ON → AI_SERVICES=postgres=ON"
ai_services_case 'postgres=17'  'postgres=17' "postgres=17 → AI_SERVICES=postgres=17 (the runner needs the pin to detect a stale image)"
ai_services_case 'postgres=OFF' ''            "postgres=OFF → AI_SERVICES empty (is_active, never the literal OFF)"
ai_services_case 'copilot=ON'   ''            "postgres absent → AI_SERVICES empty"

# ── Part D: services.d/postgres.sh against fake binaries ───────────────────────
# Isolate from the host environment: only what Part D or the adapter reads. The
# adapter's knobs carry the AI_SERVICES_PG_ prefix so that an app's own PG_PORT
# in container.env cannot move the server; PG_* are unset too, because D18
# sets them on purpose and must be the only thing that does.
unset POSTGRES_ROLES POSTGRES_DATABASES PG_SUPERUSER_TEST FAKE_PSQL_FAIL FAKE_INITDB_RC FAKE_CONF_AS_DIR FAKE_PGCTL_RC \
      AI_SERVICES_PG_MAJOR_FILE AI_SERVICES_PG_LIB_ROOT AI_SERVICES_PG_SOCKET_DIR AI_SERVICES_PG_PORT AI_SERVICES_PG_SUPERUSER \
      PG_MAJOR_FILE PG_LIB_ROOT PG_SOCKET_DIR PG_PORT PG_SUPERUSER
FAKE="$TMP_ROOT/pg"; mkdir -p "$FAKE/lib/18/bin" "$FAKE/sock" "$FAKE/data"
printf '18\n' > "$FAKE/major"
cat > "$FAKE/lib/18/bin/postgres" <<'EOF'
#!/usr/bin/env bash
printf 'postgres (PostgreSQL) 18.6 (Ubuntu 18.6-1.pgdg24.04+2)\n'
EOF
# Every fake appends its name to $FAKE_DIR/calls, so an assertion can read the
# ORDER the adapter ran them in, not merely that each ran.
cat > "$FAKE/lib/18/bin/initdb" <<'EOF'
#!/usr/bin/env bash
printf 'initdb\n' >> "$FAKE_DIR/calls"
printf '%s\n' "$@" > "$FAKE_DIR/initdb.args"
[[ "${FAKE_INITDB_RC:-0}" -eq 0 ]] || exit "$FAKE_INITDB_RC"
while (( $# )); do [[ "$1" == -D ]] && { mkdir -p "$2"; if [[ -n "${FAKE_CONF_AS_DIR:-}" ]]; then mkdir -p "$2/postgresql.conf"; else printf '# initdb default\n' > "$2/postgresql.conf"; fi; }; shift; done
EOF
cat > "$FAKE/lib/18/bin/pg_ctl" <<'EOF'
#!/usr/bin/env bash
printf 'pg_ctl\n' >> "$FAKE_DIR/calls"
printf '%s ' "$@" > "$FAKE_DIR/pg_ctl.args"
exit "${FAKE_PGCTL_RC:-0}"
EOF
# psql: records each -c statement and its -U; fails on a statement matching
# FAKE_PSQL_FAIL, the way psql does — message on stderr, exit 1.
cat > "$FAKE/lib/18/bin/psql" <<'EOF'
#!/usr/bin/env bash
sql="" user=""
while (( $# )); do
  case "$1" in -c) sql="$2"; shift ;; -U) user="$2"; shift ;; esac
  shift
done
printf 'psql|%s\n' "$sql" >> "$FAKE_DIR/calls"
printf '%s\n' "$sql" >> "$FAKE_DIR/sql.log"
printf '%s\n' "$user" >> "$FAKE_DIR/psql.users"
if [[ -n "${FAKE_PSQL_FAIL:-}" ]] && grep -qE -- "$FAKE_PSQL_FAIL" <<<"$sql"; then
  printf 'ERROR:  boom for %s\n' "$sql" >&2; exit 1
fi
EOF
chmod +x "$FAKE"/lib/18/bin/*

# pg <function> [args] — run one adapter function in a FRESH subshell, the way
# start-services.sh does, against the fakes. Env set on the call (POSTGRES_ROLES,
# FAKE_PSQL_FAIL, …) is visible to the function; the FAKE_* the binaries read
# are exported explicitly.
pg() {
  ( export AI_SERVICES_PG_MAJOR_FILE="$FAKE/major" AI_SERVICES_PG_LIB_ROOT="$FAKE/lib" \
           AI_SERVICES_PG_SOCKET_DIR="$FAKE/sock" AI_SERVICES_PG_SUPERUSER="${PG_SUPERUSER_TEST:-alice}" FAKE_DIR="$FAKE" \
           FAKE_PSQL_FAIL="${FAKE_PSQL_FAIL:-}" FAKE_INITDB_RC="${FAKE_INITDB_RC:-0}" FAKE_CONF_AS_DIR="${FAKE_CONF_AS_DIR:-}" \
           FAKE_PGCTL_RC="${FAKE_PGCTL_RC:-0}"
    # shellcheck source=../services.d/postgres.sh
    source "$REPO_DIR/services.d/postgres.sh"
    "$@" )
}
pg_reset() { rm -f "$FAKE"/{sql.log,psql.users,initdb.args,pg_ctl.args,calls}; rm -rf "$FAKE/data"; }
calls()    { if [[ -f "$FAKE/calls" ]]; then tr '\n' ' ' < "$FAKE/calls"; fi; }
sql_has()   { grep -qxF -- "$1" "$FAKE/sql.log" 2>/dev/null; }
sql_count() { if [[ -f "$FAKE/sql.log" ]]; then grep -c . "$FAKE/sql.log"; else printf '0'; fi; }

# D1–D3 — what this image has.
got="$(pg svc_installed_version)"
[[ "$got" == "18.6" ]] && pass "D1 svc_installed_version reads 18.6 out of PGDG's version string" || fail "D1 svc_installed_version (got '$got')"
mv "$FAKE/major" "$FAKE/major.off"
got="$(pg svc_installed_version)"; rc=$?
[[ -z "$got" && "$rc" -eq 0 ]] && pass "D2 no major marker → nothing installed, status 0" || fail "D2 no major marker (got '$got', rc=$rc)"
printf '17\n' > "$FAKE/major"
got="$(pg svc_installed_version)"; rc=$?
[[ -z "$got" && "$rc" -eq 0 ]] && pass "D3 a marker naming a major with no binaries → nothing installed, status 0" || fail "D3 marker without binaries (got '$got', rc=$rc)"
mv "$FAKE/major.off" "$FAKE/major"

# D4 — the socket directory is the one runtime dir.
[[ "$(pg svc_runtime_dirs)" == "$FAKE/sock" ]] && pass "D4 svc_runtime_dirs is the socket directory" || fail "D4 svc_runtime_dirs"

# D5 — svc_start: initdb flags, appended config, pg_ctl flags.
pg_reset; pg svc_start "$FAKE/data" "$FAKE/log"; rc=$?
[[ "$rc" -eq 0 ]] && pass "D5 svc_start returns 0" || fail "D5 svc_start returns 0 (rc=$rc)"
# --no-sync: initdb's own fsync of the new cluster, skipped for the same reason
# the appended config switches fsync off.
for want in -D "$FAKE/data" -U alice --auth=trust --encoding=UTF8 --locale=en_US.UTF-8 --no-sync; do
  grep -qxF -- "$want" "$FAKE/initdb.args" 2>/dev/null \
    && pass "D5 initdb gets $want" || fail "D5 initdb gets $want"
done
for want in "listen_addresses = 'localhost'" "port = 5432" "unix_socket_directories = '$FAKE/sock'" \
            "fsync = off" "synchronous_commit = off" "full_page_writes = off" "dynamic_shared_memory_type = mmap"; do
  grep -qxF -- "$want" "$FAKE/data/postgresql.conf" 2>/dev/null \
    && pass "D5 postgresql.conf: $want" || fail "D5 postgresql.conf: $want"
done
[[ "$(cat "$FAKE/pg_ctl.args" 2>/dev/null)" == "-D $FAKE/data -l $FAKE/log -w -t 30 start " ]] \
  && pass "D5 pg_ctl -D <data> -l <log> -w -t 30 start" \
  || fail "D5 pg_ctl arguments (got '$(cat "$FAKE/pg_ctl.args" 2>/dev/null)')"
# psql and libpq default the DATABASE name to the user name, and initdb creates
# only postgres/template0/template1 — so without this, a bare `psql` fails with
# `database "alice" does not exist`. Created once the server is up, and nothing
# else is: provisioning is svc_provision's job.
[[ "$(calls)" == 'initdb pg_ctl psql|CREATE DATABASE "alice" OWNER "alice" ' ]] \
  && pass "D5 after pg_ctl, the superuser's own database is created (so a bare psql connects)" \
  || fail "D5 superuser's database after pg_ctl (calls: $(calls))"

# D5b — a superuser named postgres already has its database: no statement.
pg_reset; PG_SUPERUSER_TEST=postgres pg svc_start "$FAKE/data" "$FAKE/log" >/dev/null; rc=$?
[[ "$rc" -eq 0 && "$(calls)" == 'initdb pg_ctl ' ]] \
  && pass "D5b a superuser named postgres creates no database (initdb made it)" \
  || fail "D5b superuser postgres (rc=$rc, calls: $(calls))"

# D5c — that CREATE DATABASE fails: svc_start fails, saying why. Its output is
# the log, whose tail the runner prints.
pg_reset; out="$(FAKE_PSQL_FAIL='CREATE DATABASE' pg svc_start "$FAKE/data" "$FAKE/log" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "D5c a failed CREATE DATABASE for the superuser fails svc_start" \
                  || fail "D5c a failed CREATE DATABASE for the superuser fails svc_start (rc=$rc)"
[[ "$out" == *'"alice"'*'ERROR:  boom'* ]] \
  && pass "D5c the failure names the database and carries psql's error" \
  || fail "D5c failure text (got '$out')"

# D5d — a superuser name that is not a plain identifier is quoted here too.
pg_reset; PG_SUPERUSER_TEST='John.Doe' pg svc_start "$FAKE/data" "$FAKE/log" >/dev/null
sql_has 'CREATE DATABASE "John.Doe" OWNER "John.Doe"' \
  && pass "D5d the superuser's own database is a quoted identifier (John.Doe)" \
  || fail "D5d quoted superuser database (sql: $(cat "$FAKE/sql.log" 2>/dev/null))"

# D6 — initdb fails: svc_start fails, and nothing is started.
pg_reset; mkdir -p "$FAKE/data"   # the runner pre-creates the data dir
FAKE_INITDB_RC=1 pg svc_start "$FAKE/data" "$FAKE/log"; rc=$?
[[ "$rc" -ne 0 && ! -e "$FAKE/pg_ctl.args" ]] \
  && pass "D6 a failed initdb fails svc_start and never reaches pg_ctl" \
  || fail "D6 failed initdb (rc=$rc)"

# D6b — initdb succeeds but the config append fails (postgresql.conf is a
# directory, which fails even for root): svc_start fails, pg_ctl never runs.
pg_reset; mkdir -p "$FAKE/data"; FAKE_CONF_AS_DIR=1 pg svc_start "$FAKE/data" "$FAKE/log" 2>/dev/null; rc=$?
[[ "$rc" -ne 0 && ! -e "$FAKE/pg_ctl.args" ]] \
  && pass "D6b a failed config append fails svc_start and never reaches pg_ctl" \
  || fail "D6b failed append (rc=$rc)"

# D6c — pg_ctl fails: svc_start fails, and no SQL is sent to a server that is not up.
pg_reset; FAKE_PGCTL_RC=1 pg svc_start "$FAKE/data" "$FAKE/log" >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 && "$(calls)" == 'initdb pg_ctl ' ]] \
  && pass "D6c a failed pg_ctl fails svc_start and sends no SQL" \
  || fail "D6c failed pg_ctl (rc=$rc, calls: $(calls))"

# D7 — roles.
pg_reset; out="$(POSTGRES_ROLES=' app_user , reporting' pg svc_provision 2>"$FAKE/err")"
sql_has 'CREATE ROLE "app_user" SUPERUSER LOGIN' && sql_has 'CREATE ROLE "reporting" SUPERUSER LOGIN' \
  && pass "D7 each POSTGRES_ROLES entry → CREATE ROLE \"<name>\" SUPERUSER LOGIN" \
  || fail "D7 roles (sql: $(cat "$FAKE/sql.log" 2>/dev/null))"
[[ "$out" == "; roles: app_user, reporting" ]] && pass "D7 suffix lists the roles" || fail "D7 suffix (got '$out')"
grep -qxF -- "alice" "$FAKE/psql.users" && pass "D7 psql connects as the superuser" || fail "D7 psql -U"

# D8 — invalid entries: warned, never reach SQL.
pg_reset; POSTGRES_ROLES='x; drop table y,Mixed,,ok_role' pg svc_provision >/dev/null 2>"$FAKE/err"
[[ "$(sql_count)" -eq 1 ]] && sql_has 'CREATE ROLE "ok_role" SUPERUSER LOGIN' \
  && pass "D8 only the valid role reaches SQL" \
  || fail "D8 only the valid role reaches SQL (sql: $(cat "$FAKE/sql.log" 2>/dev/null))"
[[ "$(grep -c 'is not a valid role name' "$FAKE/err")" -eq 3 ]] \
  && grep -qF "'x; drop table y'" "$FAKE/err" && grep -qF "'Mixed'" "$FAKE/err" \
  && pass "D8 each invalid entry (including an empty one) is warned about by value" \
  || fail "D8 warnings (got: $(cat "$FAKE/err"))"

# D9 — the superuser's own name and a repeat are skipped quietly (Review Focus 3).
pg_reset; POSTGRES_ROLES='alice,app_user,app_user' pg svc_provision >/dev/null 2>"$FAKE/err"
[[ "$(sql_count)" -eq 1 && ! -s "$FAKE/err" ]] \
  && pass "D9 own name skipped, repeated role created once, no warnings" \
  || fail "D9 (sql: $(cat "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"

# D9b — the superuser's own name is skipped silently even when it is NOT a plain
# identifier: it comes from the host, where a macOS John.Doe is legal, and a
# project listing it must not be told its user's name is invalid.
pg_reset; PG_SUPERUSER_TEST='John.Doe' POSTGRES_ROLES='John.Doe,app_user' pg svc_provision >/dev/null 2>"$FAKE/err"
[[ "$(sql_count)" -eq 1 ]] && sql_has 'CREATE ROLE "app_user" SUPERUSER LOGIN' && [[ ! -s "$FAKE/err" ]] \
  && pass "D9b a non-identifier superuser listed in POSTGRES_ROLES is skipped without a warning" \
  || fail "D9b (sql: $(cat "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"

# D10 — CRLF from a Windows-saved container.env (Review Focus 1).
pg_reset; POSTGRES_ROLES=$'app_user\r' pg svc_provision >/dev/null 2>"$FAKE/err"
sql_has 'CREATE ROLE "app_user" SUPERUSER LOGIN' && [[ ! -s "$FAKE/err" ]] \
  && pass "D10 a trailing \\r is trimmed, not rejected" \
  || fail "D10 CRLF (sql: $(cat "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"

# D11 — databases: name:owner, default owner, repeats (Review Focus 3).
pg_reset
out="$(POSTGRES_ROLES=app_user POSTGRES_DATABASES='myapp_test:app_user, myapp_dev,myapp_test:app_user' pg svc_provision 2>"$FAKE/err")"
sql_has 'CREATE DATABASE "myapp_test" OWNER "app_user"' && sql_has 'CREATE DATABASE "myapp_dev" OWNER "alice"' \
  && [[ "$(grep -c 'CREATE DATABASE' "$FAKE/sql.log")" -eq 2 ]] \
  && pass "D11 name:owner honoured, owner defaults to the superuser, a repeat is created once" \
  || fail "D11 databases (sql: $(cat "$FAKE/sql.log" 2>/dev/null))"
[[ "$out" == "; roles: app_user; databases: myapp_test, myapp_dev" ]] \
  && pass "D11 suffix lists roles then databases" || fail "D11 suffix (got '$out')"

# D12 — an owner that is not a role here.
pg_reset; POSTGRES_DATABASES='x_test:ghost' pg svc_provision >/dev/null 2>"$FAKE/err"
[[ "$(sql_count)" -eq 0 ]] && grep -qF "owner 'ghost'" "$FAKE/err" && grep -qF 'POSTGRES_ROLES' "$FAKE/err" \
  && pass "D12 an unknown owner is refused, pointing at POSTGRES_ROLES" \
  || fail "D12 unknown owner (err: $(cat "$FAKE/err"))"

# D13 — invalid database entries.
pg_reset; POSTGRES_DATABASES='my-app,x:Bad' pg svc_provision >/dev/null 2>"$FAKE/err"
[[ "$(sql_count)" -eq 0 && "$(grep -c 'is not name or name:owner' "$FAKE/err")" -eq 2 ]] \
  && pass "D13 invalid database names and owners are refused" \
  || fail "D13 (err: $(cat "$FAKE/err"))"

# D14 — a role that fails to create cannot own a database (Review Focus 4).
pg_reset
out="$(FAKE_PSQL_FAIL='"reporting"' POSTGRES_ROLES='app_user,reporting' POSTGRES_DATABASES='r_db:reporting' pg svc_provision 2>"$FAKE/err")"
grep -qF "could not create role 'reporting': ERROR:  boom" "$FAKE/err" \
  && pass "D14 a psql failure is reported against its own entry, with psql's error" \
  || fail "D14 role failure message (err: $(cat "$FAKE/err"))"
grep -qF "'r_db:reporting' — owner 'reporting' is not a role here" "$FAKE/err" && ! grep -q 'CREATE DATABASE' "$FAKE/sql.log" \
  && pass "D14 a database owned by the failed role is refused by name, never attempted" \
  || fail "D14 dependent database (err: $(cat "$FAKE/err"))"
[[ "$out" == "; roles: app_user" ]] && pass "D14 the suffix lists only what exists" || fail "D14 suffix (got '$out')"

# D15 — a superuser name that is not a plain identifier (Review Focus 2).
pg_reset; PG_SUPERUSER_TEST='John.Doe' POSTGRES_DATABASES='myapp_test' pg svc_provision >/dev/null 2>"$FAKE/err"
sql_has 'CREATE DATABASE "myapp_test" OWNER "John.Doe"' \
  && pass "D15 a macOS-style superuser name is a quoted default owner" \
  || fail "D15 (sql: $(cat "$FAKE/sql.log" 2>/dev/null))"
pg_reset; PG_SUPERUSER_TEST='o"brien' POSTGRES_DATABASES='myapp_test' pg svc_provision >/dev/null 2>"$FAKE/err"
sql_has 'CREATE DATABASE "myapp_test" OWNER "o""brien"' \
  && pass "D15 an embedded double quote is doubled, never closing the identifier" \
  || fail "D15 quote (sql: $(cat "$FAKE/sql.log" 2>/dev/null))"

# D16 — endpoint text.
[[ "$(pg svc_endpoint)" == "localhost:5432 (socket $FAKE/sock), superuser alice" ]] \
  && pass "D16 svc_endpoint" || fail "D16 svc_endpoint (got '$(pg svc_endpoint)')"

# D17 — nothing requested: no SQL, no suffix.
pg_reset; out="$(POSTGRES_ROLES='' POSTGRES_DATABASES='' pg svc_provision 2>"$FAKE/err")"; rc=$?
[[ "$rc" -eq 0 && -z "$out" && "$(sql_count)" -eq 0 && ! -s "$FAKE/err" ]] \
  && pass "D17 nothing requested: nothing run, nothing printed" \
  || fail "D17 (rc=$rc out='$out')"

# D18 — an app's own PG_* variables in container.env reach `start`, and are not
# the adapter's knobs: PG_PORT=5433 is a common app setting, and read as a knob
# it would move the server off 5432 and away from libpq's default socket.
got="$(PG_PORT=5433 PG_SUPERUSER=reporting PG_SOCKET_DIR=/nowhere PG_MAJOR_FILE=/nowhere PG_LIB_ROOT=/nowhere pg svc_endpoint)"
[[ "$got" == "localhost:5432 (socket $FAKE/sock), superuser alice" ]] \
  && pass "D18 an app's PG_PORT/PG_SUPERUSER/PG_SOCKET_DIR do not move the server" \
  || fail "D18 app PG_* variables (got '$got')"
got="$(PG_MAJOR_FILE=/nowhere PG_LIB_ROOT=/nowhere pg svc_installed_version)"
[[ "$got" == "18.6" ]] \
  && pass "D18 an app's PG_MAJOR_FILE/PG_LIB_ROOT do not hide the installed server" \
  || fail "D18 app PG_MAJOR_FILE/PG_LIB_ROOT (got '$got')"

# D19 — the two databases that exist before provisioning: initdb's postgres, and
# the superuser's own (svc_start). Listing one with an owner gives it to that
# owner; CREATE would fail with "already exists" and the owner would be lost.
pg_reset
out="$(POSTGRES_ROLES=app_user POSTGRES_DATABASES='alice:app_user,postgres:app_user' pg svc_provision 2>"$FAKE/err")"
sql_has 'ALTER DATABASE "alice" OWNER TO "app_user"' && sql_has 'ALTER DATABASE "postgres" OWNER TO "app_user"' \
  && ! grep -q 'CREATE DATABASE' "$FAKE/sql.log" && [[ ! -s "$FAKE/err" ]] \
  && pass "D19 the superuser's own database and postgres change owner, never CREATE" \
  || fail "D19 existing databases (sql: $(tr '\n' '|' < "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"
[[ "$out" == "; roles: app_user; databases: alice, postgres" ]] \
  && pass "D19 … and the suffix lists them" || fail "D19 suffix (got '$out')"
pg_reset; out="$(POSTGRES_DATABASES='alice' pg svc_provision 2>"$FAKE/err")"
[[ "$(sql_count)" -eq 0 && ! -s "$FAKE/err" && "$out" == "; databases: alice" ]] \
  && pass "D19 the superuser's own database with no owner: nothing to do, nothing warned" \
  || fail "D19 own database, no owner (sql: $(sql_count); err: $(cat "$FAKE/err"); out '$out')"
pg_reset; PG_SUPERUSER_TEST='John.Doe' POSTGRES_ROLES=app_user POSTGRES_DATABASES='John.Doe:app_user' pg svc_provision >/dev/null 2>"$FAKE/err"
sql_has 'ALTER DATABASE "John.Doe" OWNER TO "app_user"' && [[ ! -s "$FAKE/err" ]] \
  && pass "D19 a macOS-style superuser's own database is not held to the name pattern" \
  || fail "D19 John.Doe (sql: $(cat "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"
pg_reset; FAKE_PSQL_FAIL='^ALTER DATABASE' POSTGRES_ROLES=app_user POSTGRES_DATABASES='alice:app_user' pg svc_provision >/dev/null 2>"$FAKE/err"
grep -qF "could not give database 'alice' to 'app_user': ERROR:  boom" "$FAKE/err" \
  && pass "D19 an ALTER that fails is reported with psql's error" \
  || fail "D19 failing ALTER (err: $(cat "$FAKE/err"))"

# D20 — whitespace around the ':' is the writer's, not part of a name.
pg_reset; POSTGRES_ROLES=app_user POSTGRES_DATABASES=$' myapp_test : app_user ,\tmyapp_dev\t:\tapp_user' pg svc_provision >/dev/null 2>"$FAKE/err"
sql_has 'CREATE DATABASE "myapp_test" OWNER "app_user"' && sql_has 'CREATE DATABASE "myapp_dev" OWNER "app_user"' && [[ ! -s "$FAKE/err" ]] \
  && pass "D20 spaces and tabs around ':' are trimmed from each half" \
  || fail "D20 (sql: $(tr '\n' '|' < "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"
pg_reset; POSTGRES_DATABASES='myapp_test : ' pg svc_provision >/dev/null 2>"$FAKE/err"
[[ "$(sql_count)" -eq 0 ]] && grep -qF 'is not name or name:owner' "$FAKE/err" \
  && pass "D20 … but a ':' with no owner after it is still refused" \
  || fail "D20 empty owner (err: $(cat "$FAKE/err"))"

# D21 — one database, two owners: warned, and the first VALID listing kept. A
# listing refused for its owner does not count as the first.
pg_reset; POSTGRES_ROLES=app_user POSTGRES_DATABASES='x_db:app_user,x_db:alice,x_db:app_user' pg svc_provision >/dev/null 2>"$FAKE/err"
sql_has 'CREATE DATABASE "x_db" OWNER "app_user"' && [[ "$(grep -c 'CREATE DATABASE' "$FAKE/sql.log")" -eq 1 ]] \
  && grep -qF "'x_db' is listed with two owners, 'app_user' and 'alice' — keeping 'app_user'" "$FAKE/err" \
  && [[ "$(grep -c 'two owners' "$FAKE/err")" -eq 1 ]] \
  && pass "D21 a database listed with a second owner is warned about once; the first is kept, a same-owner repeat is quiet" \
  || fail "D21 two owners (sql: $(tr '\n' '|' < "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"
pg_reset; POSTGRES_ROLES=app_user POSTGRES_DATABASES='x_db:ghost,x_db:app_user' pg svc_provision >/dev/null 2>"$FAKE/err"
sql_has 'CREATE DATABASE "x_db" OWNER "app_user"' && ! grep -q 'two owners' "$FAKE/err" \
  && pass "D21 a listing refused for its owner does not shadow a valid one" \
  || fail "D21 refused then valid (sql: $(cat "$FAKE/sql.log" 2>/dev/null); err: $(cat "$FAKE/err"))"

# ── Part E: the Dockerfile layer's shape ──────────────────────────────────────
# Shape only: that it BUILDS is integration case 780. These pin the properties
# the spec decided, so a later edit that drops one fails here, in seconds.
DF="$REPO_DIR/Dockerfile"
layer="$(awk '/^ARG POSTGRES_VERSION=$/{grab=1} grab{print} grab && /^$/{exit}' "$DF")"
[[ -n "$layer" ]] && pass "E the Dockerfile declares ARG POSTGRES_VERSION= (empty default = skip)" \
                  || fail "E the Dockerfile declares ARG POSTGRES_VERSION="
grep -qF 'if [ -n "$POSTGRES_VERSION" ]' <<<"$layer" && pass "E the layer is skipped when the arg is empty" || fail "E skip guard"
grep -qF -- '-pgdg main" ' <<<"$layer" && ! grep -qE -- '-pgdg main [0-9]' <<<"$layer" \
  && pass "E PGDG's main component only — betas live in other components" \
  || fail "E PGDG main component only"
grep -qF 'create_main_cluster = false' <<<"$layer" && pass "E no cluster is created at build time" || fail "E create_main_cluster"
grep -qF 'apt-cache depends postgresql' <<<"$layer" && pass "E ON resolves through PGDG's postgresql metapackage" || fail "E latest resolution"
grep -qF 'locale-gen en_US.UTF-8' <<<"$layer" && pass "E en_US.UTF-8 is generated" || fail "E locale"
grep -qF '/etc/ai-containers/postgres-major' <<<"$layer" && pass "E the resolved major is recorded for the adapter" || fail "E major marker"
grep -qx 'COPY start-services.sh /usr/local/bin/start-services.sh' "$DF" && pass "E the runner is copied into the image" || fail "E COPY start-services.sh"
grep -qx 'COPY services.d /etc/ai-containers/services.d' "$DF" && pass "E the adapters are copied into the image" || fail "E COPY services.d"
grep -qE '^(services\.d|start-services\.sh)' "$REPO_DIR/.dockerignore" \
  && fail "E .dockerignore must not exclude the runner or its adapters" \
  || pass "E .dockerignore keeps the runner and its adapters in the build context"

grep -qF -- 'apt-get update --error-on=any' <<<"$layer" && pass "E a failed index fetch fails the build (--error-on=any)" || fail "E --error-on=any"
pgdg_at="$(grep -nF 'apt.postgresql.org' <<<"$layer" | sed -n '2p' | cut -d: -f1)"
resolve_at="$(grep -nF 'apt-cache depends postgresql' <<<"$layer" | head -1 | cut -d: -f1)"
[[ -n "$pgdg_at" && -n "$resolve_at" && "$pgdg_at" -lt "$resolve_at" ]] \
  && pass "E PGDG's index is asserted loaded before the major is resolved" \
  || fail "E PGDG index check precedes resolution (check=$pgdg_at resolve=$resolve_at)"

# ── Part G: shipping to projects ───────────────────────────────────────────────
shared_list="$( source "$REPO_DIR/shared-files.sh"; printf '%s\n' "${AI_CONTAINERS_SHARED_FILES[@]}" )"
grep -qx 'start-services.sh' <<<"$shared_list" \
  && pass "G start-services.sh is a shared file (a project's build COPYs it)" \
  || fail "G start-services.sh is a shared file"
payload="$(bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_payload_files "$1"' _ "$REPO_DIR")"
grep -qx 'services.d/postgres.sh' <<<"$payload" && grep -qx 'start-services.sh' <<<"$payload" \
  && pass "G the provenance digest covers the runner and services.d/ (they are built into the image)" \
  || fail "G provenance digest coverage"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
