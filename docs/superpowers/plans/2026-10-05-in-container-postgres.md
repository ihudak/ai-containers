# In-container PostgreSQL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `postgres=ON | <major> | OFF` in `sandbox.conf` bakes a PGDG PostgreSQL server into the image, and every container starts a throwaway cluster on loopback, as the sandbox user, before the shell prompt — through a shared service runner that later servers reuse.

**Architecture:** `build.sh` turns the key into `POSTGRES_VERSION`; one Dockerfile layer installs the server from PGDG. `sandbox.sh` passes `AI_SERVICES=postgres=<value>`. `entrypoint.sh`'s new `run_services` calls `start-services.sh prepare` as root (directories only) and `start-services.sh start` as the sandbox user; the runner sources `services.d/postgres.sh` (the adapter) in a subshell, starts it under a watchdog timeout, provisions `POSTGRES_ROLES`/`POSTGRES_DATABASES` from `container.env`, and prints one ready line or a warning — never failing the shell.

**Tech Stack:** bash ≥ 5.1, Docker/BuildKit, Ubuntu 24.04, PGDG apt repo, PostgreSQL 10–18, the repo's hermetic test idiom (`PASS:`/`FAIL:` lines, exit = failure count), integration corpus (`tests/integration/`), mutation patches, falsify tier.

**Spec:** `docs/superpowers/specs/2026-10-05-in-container-db-servers-design.md` — read it first; this plan argues from it.

## Global Constraints

- **Public repo.** No private project, database, role or host names anywhere committed. Examples are `app_user`, `reporting`, `myapp_test`, `myapp_dev`, `/path/to/project`.
- **bash floor 5.1.** No construct newer than 5.1 (`tests/bash-dialect-lint.sh` enforces it).
- **shellcheck is a gate.** Suppress only at the site, as `# shellcheck disable=SCxxxx: reason` or the repo's existing `# shellcheck source=…` forms.
- **Cite code by snippet, never by line number** (`tests/test-code-references.sh`): write `<file>: ` + a backticked snippet on one line.
- **Key grammar:** `postgres=ON | <major> | OFF`, single value, `ON`/`OFF` in capitals; a minor (`17.2`) is refused; `ON` → build arg `latest`; off → **no** `POSTGRES_VERSION` build arg at all.
- **PGDG `main` component only**; `ON` resolves through PGDG's `postgresql` metapackage; cluster locale `en_US.UTF-8`.
- **Fixed paths:** data `/var/lib/ai-services/<name>`, log `/var/log/ai-services/<name>.log`, socket `/var/run/postgresql`, port `5432`, adapter dir `/etc/ai-containers/services.d`, runner `/usr/local/bin/start-services.sh`, major marker `/etc/ai-containers/postgres-major`.
- **Timeouts:** runner default `AI_SERVICES_TIMEOUT=60` per service; `pg_ctl -w -t 30` inside it.
- **Names:** service `^[a-z][a-z0-9-]*$`; role/database `^[a-z_][a-z0-9_]*$`; identifiers always double-quoted with `"` doubled.
- **Runner exit status:** always 0 for `prepare`/`start`; 2 for a usage error only.
- **Nothing new as root at runtime; no `--shm-size`, no mounts, no ports, no allowlist fragment** for this key.
- **Tests:** `PASS: …` / `FAIL: …` lines, `exit "$fails"`; scaffold problems print `SCAFFOLD-FAILED: …`. A temp-removing EXIT trap uses the `$BASHPID` owner guard (`tests/test-exit-trap-ownership.sh`).
- **Commits:** conventional (`feat(postgres): …`, `test(postgres): …`, `docs(postgres): …`), each ending with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never commit to `main`; the branch is `feat/in-container-postgres`.

## Review Focus

1. **A `container.env` saved with CRLF line endings** (`POSTGRES_ROLES=app_user\r`) — a person expects `app_user` to be created, not a "not a valid role name" warning. Pinned in Task 4 (test D10).
2. **A sandbox username that is not a plain lowercase identifier** (macOS `John.Doe`, or one containing `"`) — the superuser role and default database owner must still work, with identifiers quoted. Pinned in Task 4 (test D15).
3. **The same role or database listed twice** — created once, with no warning. Pinned in Task 4 (tests D9, D11).
4. **A role whose `CREATE` fails** — a database owned by it must be refused with a warning naming the owner, not a raw psql error about a missing role. Pinned in Task 4 (test D14).
5. **`AI_SERVICES` entries without `=value` or with stray spaces** (`postgres`, ` postgres=ON , `) — treated as `ON`, no mismatch warning, no crash. Pinned in Task 3 (tests T11, T17).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `sandbox.conf` | modify | the `postgres=OFF` key and its comment block |
| `build.sh` | modify | `validate_config` grammar check; `POSTGRES_VERSION` build arg |
| `sandbox-common.sh` | modify | `services_csv()`; `services.d/*` in `ai_containers_payload_files()` |
| `sandbox.sh` | modify | `-e AI_SERVICES=…` on the `docker run` line |
| `start-services.sh` | **create** | the runner: phases, adapter loading, watchdog, reporting |
| `services.d/postgres.sh` | **create** | the PostgreSQL adapter (initdb/pg_ctl/provisioning) |
| `entrypoint.sh` | modify | `run_services()` and its call in all three modes |
| `Dockerfile` | modify | the PGDG layer; `COPY` of runner and adapters |
| `shared-files.sh` | modify | `start-services.sh` joins `AI_CONTAINERS_SHARED_FILES` |
| `project-init.sh`, `sync-to-projects.sh` | modify | `rsync` `services.d/` like `tools.d/` |
| `tests/test-postgres.sh` | **create** | key, build arg, `AI_SERVICES`, adapter logic, image/shipping shape |
| `tests/test-start-services.sh` | **create** | the runner's contract against fake adapters |
| `tests/test-entrypoint-wiring.sh` | modify | `run_services` defined, wired, and ordered in all three modes |
| `tests/test-sync-project.sh`, `tests/test-shared-files-parity.sh` | modify | `services.d/` lands in synced and initialised projects |
| `tests/falsify/targets.conf`, `tests/falsify/survivors.txt` | modify | rows for the two new scripts; classified survivors |
| `tests/integration/cases/780-postgres-server-runs.sh` | **create** | the real-image proof |
| `tests/integration/mutations/780-…`, `781-…`, `782-…` | **create** | known-bad patches proving 780 can fail |
| `tests/integration/run.sh`, `tests/test-integration-runner.sh` | modify | `postgres=ON` in the `native` variant |
| `docs/components/postgres.md` | **create** | the component page |
| `docs/components/README.md`, `docs/components/db-clients.md`, `docs/configuration.md`, `AGENTS.md`, `CHANGELOG.md` | modify | documentation |

---

### Task 1: The `postgres=` key — config, validation, build arg

**Files:**
- Modify: `sandbox.conf` (after the `db-clients=` line)
- Modify: `build.sh` — `validate_config()` and `build_args_from_config()`
- Modify: `docs/components/README.md` (a row, so `tests/test-docs.sh`'s "every sandbox.conf key is documented" stays green)
- Create: `tests/test-postgres.sh`

**Interfaces:**
- Produces: build arg `POSTGRES_VERSION=<latest|major>` (absent when off) — consumed by the Dockerfile layer in Task 6. `tests/test-postgres.sh` with helpers `pg_build_args` and `vc` that later tasks append to.

- [ ] **Step 1: Create the test file with Parts A, B and F**

Create `tests/test-postgres.sh` (mode 644 is fine — it is run as `bash <file>`):

```bash
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
for bad in '16,17' on Off oN latest 17beta1 abc; do
  vc "$bad"
  if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *postgres* ]]; then
    pass "validate_config refuses postgres=$bad, by name"
  else
    fail "validate_config refuses postgres=$bad, by name (rc=$VC_RC, out='$VC_OUT')"
  fi
done

# A minor is refused AND the message hands back the major to pin instead.
vc '17.2'
if [[ "$VC_RC" -ne 0 && "$VC_OUT" == *"postgres=17"* ]]; then
  pass "validate_config refuses postgres=17.2 and suggests postgres=17"
else
  fail "validate_config refuses postgres=17.2 and suggests postgres=17 (rc=$VC_RC, out='$VC_OUT')"
fi

# ── Part F: the shipped default ────────────────────────────────────────────────
# New keys reach every project through sync's append, so the upstream default is
# what every project gets until someone opts in. Off, because it costs ~180 MB.
grep -qx 'postgres=OFF' "$REPO_DIR/sandbox.conf" \
  && pass "sandbox.conf ships postgres=OFF" \
  || fail "sandbox.conf ships postgres=OFF"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/run-all.sh test-postgres.sh`
Expected: FAIL on every Part A positive case, on the Part B refusals (`validate_config` accepts everything today), and on Part F.

- [ ] **Step 3: Add the key to `sandbox.conf`**

Insert after the line `db-clients=` (keep one blank line before the new header):

```
# ── Database servers (in-container, for tests) ─────────────────────────────────
# A real database SERVER inside the container, started before your shell appears,
# for test suites that need one. Not db-clients (above), which installs clients
# only. Baked at build time: nothing in the container can install packages once
# the entrypoint has dropped root. See docs/components/postgres.md.
#
# postgres: ON | <major> | OFF  (single value; ON and OFF in capitals)
#   ON       the newest major PGDG (apt.postgresql.org) offers at BUILD time —
#            whatever its own `postgresql` package depends on (18 as of 2026-10).
#            Docker caches the layer, so it stays that major until
#            ./build.sh --no-cache. Pin a major for reproducibility.
#   <major>  e.g. 17. Any major PGDG carries for Ubuntu 24.04 (10-18 as of
#            2026-10; 10-13 are past upstream end of life). A minor (17.2) is
#            refused: PGDG ships only the latest minor of each major.
#   OFF      default.
# Installs the server, its bundled extensions (pgcrypto, tablefunc,
# pg_stat_statements, ...) and psql. NOT libpq-dev: compiling a native driver
# (Ruby pg, Python psycopg2) is still db-clients=pg.
# At container start, as YOUR user (never root): an EMPTY cluster on
# localhost:5432 and the default socket /var/run/postgresql. You are its
# superuser and any password is accepted, so the password in an app's DB config
# is irrelevant — only the role has to exist. Thrown away when the container
# exits: for tests, not for data you want to keep. Works unchanged in restricted
# mode (loopback is always allowed).
# Extra roles and databases, created at every start, go in
# .ai-containers/container.env:
#   POSTGRES_ROLES=app_user,reporting                 (each SUPERUSER LOGIN)
#   POSTGRES_DATABASES=myapp_test:app_user,myapp_dev  (name, or name:owner)
# Cost: ~180 MB of image, ~60 MB RAM idle, ~2 s added to container start.
# Changing this value without rebuilding starts the OLD server with a warning;
# ./runme.sh rebuilds first, so that only happens with a bare ./sandbox.sh.
postgres=OFF
```

- [ ] **Step 4: Add the validation to `build.sh`**

In `validate_config()`, insert immediately after the `playwright` capitals check (the block ending with `Lowercase is read as a version and becomes`… `exit 1` / `fi`) and before `local jvm_key jvm_val ver`:

```bash
  # postgres names ONE server major (spec D6/D7). Checked here because every
  # mistake below otherwise surfaces as an apt error inside the build — "Unable to
  # locate package postgresql-on" — which names neither this key nor this file.
  # Order matters: a list, then a case-variant of the two reserved words, then a
  # minor (with the major to pin instead), then anything that is not a number.
  local pg_val; pg_val=$(get_versions postgres)
  if [[ -n "$pg_val" && "$pg_val" != "ON" && "$pg_val" != "OFF" ]]; then
    if [[ "$pg_val" == *,* ]]; then
      printf 'ERROR: postgres only supports a single value (got: "%s").\n' "$pg_val" >&2
      printf '       Use ON (newest major at build time), a major version (e.g. 17), or OFF.\n' >&2
      exit 1
    elif [[ "${pg_val^^}" == "ON" || "${pg_val^^}" == "OFF" ]]; then
      printf 'ERROR: postgres value "%s" must be written in capitals (ON or OFF).\n' "$pg_val" >&2
      exit 1
    elif [[ "$pg_val" =~ ^[0-9]+\.[0-9.]*$ ]]; then
      printf 'ERROR: postgres=%s pins a minor version; pin the major instead: postgres=%s\n' "$pg_val" "${pg_val%%.*}" >&2
      printf '       PGDG ships only the latest minor of each major.\n' >&2
      exit 1
    elif [[ ! "$pg_val" =~ ^[0-9]+$ ]]; then
      printf 'ERROR: postgres value "%s" is not ON, OFF or a major version number (e.g. 17).\n' "$pg_val" >&2
      exit 1
    fi
  fi
```

- [ ] **Step 5: Emit the build arg in `build.sh`**

In `build_args_from_config()`, insert immediately after the `PLAYWRIGHT_VERSION` if/elif/else block:

```bash
  # PostgreSQL server major for the in-container test cluster (PGDG). ON becomes
  # `latest`, which the Dockerfile layer resolves through PGDG's own `postgresql`
  # metapackage; a pinned major passes verbatim. OFF and empty emit NOTHING — not
  # an empty arg — so the config digest of a project that never enables the key
  # is unaffected by the key existing.
  local pg_raw; pg_raw=$(get_versions postgres)
  if [[ "$pg_raw" == "ON" ]]; then
    _args+=(--build-arg "POSTGRES_VERSION=latest")
  elif [[ -n "$pg_raw" && "$pg_raw" != "OFF" ]]; then
    _args+=(--build-arg "POSTGRES_VERSION=${pg_raw}")
  fi
```

- [ ] **Step 6: Document the key in `docs/components/README.md`**

Insert a new section immediately before `### Browser automation`:

```markdown
### Database servers

| Key | Values | What it does |
|---|---|---|
| `postgres` | ON / major / OFF | A PostgreSQL server inside the container, for test suites — loopback only, data thrown away on exit |

```

(Task 10 turns the description into a link once `postgres.md` exists.)

- [ ] **Step 7: Run the tests**

Run: `bash tests/run-all.sh test-postgres.sh test-docs.sh test-check-sandbox-version.sh test-sandbox-schema.sh`
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add sandbox.conf build.sh docs/components/README.md tests/test-postgres.sh
git commit -m "feat(postgres): the postgres= key, its validation and build arg

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `AI_SERVICES` — telling the container which servers to start

**Files:**
- Modify: `sandbox-common.sh` — new `services_csv()` beside `runtime_tools_csv()`
- Modify: `sandbox.sh` — the `docker run` line
- Modify: `tests/test-postgres.sh` — Part C

**Interfaces:**
- Consumes: the `postgres` key (Task 1).
- Produces: `services_csv` → `"postgres=<ON|major>"` or `""`; container env `AI_SERVICES` — consumed by the runner (Task 3) and `run_services` (Task 5).

- [ ] **Step 1: Append Part C to `tests/test-postgres.sh`** (insert before the final `printf '\n%d failure(s)\n'` line)

```bash
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
```

- [ ] **Step 2: Run it and watch Part C fail**

Run: `bash tests/run-all.sh test-postgres.sh`
Expected: the four Part C assertions FAIL with `no AI_SERVICES at all`; Parts A, B, F still PASS.

- [ ] **Step 3: Add `services_csv` to `sandbox-common.sh`**

Insert immediately after the `runtime_tools_csv()` function:

```bash
# services_csv — comma-separated name=value for every in-container server key that
# is ACTIVE (ON or a pinned version), e.g. "postgres=17". is_active, not
# is_enabled: a pinned major must start the server too, and the value travels
# with the name so start-services.sh can tell an image built for another major.
# Consumed by sandbox.sh (-e AI_SERVICES) and start-services.sh. Empty when none.
services_csv() {
  local s out=()
  for s in postgres; do
    is_active "$s" && out+=("$s=$(get_versions "$s")")
  done
  local IFS=,; printf '%s' "${out[*]}"
}
```

- [ ] **Step 4: Pass it in `sandbox.sh`**

In the `docker run -it --rm` line, insert directly after the line `-e RUBY_VERSIONS="$(versions_to_space "$(version_list ruby)")" \`:

```bash
    -e AI_SERVICES="$(services_csv)" \
```

- [ ] **Step 5: Run the tests**

Run: `bash tests/run-all.sh test-postgres.sh test-runtime-tools-csv.sh test-playwright.sh test-mode-output-mounts.sh test-parsers.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add sandbox-common.sh sandbox.sh tests/test-postgres.sh
git commit -m "feat(postgres): pass AI_SERVICES from sandbox.conf into the container

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The service runner `start-services.sh`

**Files:**
- Create: `start-services.sh` (mode 755)
- Create: `tests/test-start-services.sh`
- Modify: `tests/falsify/targets.conf`

**Interfaces:**
- Consumes: env `AI_SERVICES` (`name=value,…`), `SANDBOX_UID`/`SANDBOX_GID` (prepare phase); test overrides `AI_SERVICES_DIR`, `AI_SERVICES_STATE_ROOT`, `AI_SERVICES_LOG_ROOT`, `AI_SERVICES_TIMEOUT`.
- Produces: `start-services.sh prepare|start`; the adapter contract every `services.d/<name>.sh` must meet (sourced; defines all five):
  - `svc_installed_version` → prints the installed version (e.g. `18.6`) or nothing
  - `svc_runtime_dirs` → prints extra absolute directories, one per line
  - `svc_start <datadir> <logfile>` → returns 0 once accepting connections (its stdout/stderr go to the log)
  - `svc_provision` → warnings on stderr; prints the ready-line suffix (e.g. `; roles: app_user`) on stdout
  - `svc_endpoint` → prints the "where to connect" text

- [ ] **Step 1: Write the failing test `tests/test-start-services.sh`**

```bash
#!/usr/bin/env bash
# Unit tests for start-services.sh, the in-container service runner.
#
# Driven against FAKE adapters in a scratch services.d, so what is asserted is
# the runner's own contract — phases, warnings, the watchdog timeout, adapter
# isolation, exit status — and not any one server. services.d/postgres.sh has
# its own file (test-postgres.sh), and that a real server starts in a real image
# is integration case 780-postgres-server-runs.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_DIR/start-services.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT

ADAPTERS="$TMP/services.d"; mkdir -p "$ADAPTERS"
TRACE="$TMP/trace"

# fake: complete; behaviour chosen per test through FAKE_* env.
cat > "$ADAPTERS/fake.sh" <<'EOF'
svc_installed_version() { printf '%s' "${FAKE_VERSION-1.2}"; }
svc_runtime_dirs()      { printf '%s\n' "$FAKE_RUNTIME_DIR"; }
svc_start() {
  printf 'start|%s|%s\n' "$1" "$2" >> "$FAKE_TRACE"
  case "${FAKE_START:-ok}" in
    ok)   printf 'fake server log line\n' ;;
    fail) printf 'boom: disk on fire\n'; return 1 ;;
    hang) exec sleep 30 ;;
  esac
}
svc_provision() { printf 'provision\n' >> "$FAKE_TRACE"; printf '; extras: %s' "${FAKE_EXTRAS:-none}"; }
svc_endpoint()  { printf 'fake:1234'; }
EOF
# bad: complete, always fails to start.
cat > "$ADAPTERS/bad.sh" <<'EOF'
svc_installed_version() { printf '9.9'; }
svc_runtime_dirs()      { :; }
svc_start()             { printf 'bad: refused\n'; return 1; }
svc_provision()         { :; }
svc_endpoint()          { printf 'bad:0'; }
EOF
# partial: missing svc_runtime_dirs, svc_provision and svc_endpoint.
cat > "$ADAPTERS/partial.sh" <<'EOF'
svc_installed_version() { printf '1.0'; }
svc_start()             { printf 'start|partial\n' >> "$FAKE_TRACE"; }
EOF
# evil: OUTSIDE services.d; must never be sourced through a crafted name.
printf 'touch "%s/evil-ran"\n' "$TMP" > "$TMP/evil.sh"

reset() { rm -rf "$TMP/state" "$TMP/log" "$TMP/run"; mkdir -p "$TMP/state" "$TMP/log"; : > "$TRACE"; }
run_runner() {  # $1 = phase, $2… = extra VAR=value → sets OUT (stdout+stderr) and RC
  local phase="$1"; shift
  OUT="$(env AI_SERVICES_DIR="$ADAPTERS" AI_SERVICES_STATE_ROOT="$TMP/state" \
             AI_SERVICES_LOG_ROOT="$TMP/log" FAKE_TRACE="$TRACE" \
             FAKE_RUNTIME_DIR="$TMP/run/fake" \
             SANDBOX_UID="$(id -u)" SANDBOX_GID="$(id -g)" "$@" \
             bash "$RUNNER" "$phase" 2>&1)"
  RC=$?
}
has()  { grep -qF -- "$1" <<<"$OUT"; }

# T1 — the happy path: ready line, svc_start's chatter in the log not on screen.
reset; run_runner start AI_SERVICES=fake=ON
[[ "$RC" -eq 0 ]] && pass "T1 start exits 0" || fail "T1 start exits 0 (rc=$RC)"
has "fake 1.2 ready on fake:1234; extras: none" \
  && pass "T1 prints '<name> <version> ready on <endpoint><suffix>'" \
  || fail "T1 ready line (got: $OUT)"
grep -qx "start|$TMP/state/fake|$TMP/log/fake.log" "$TRACE" \
  && pass "T1 svc_start gets <state-root>/<name> and <log-root>/<name>.log" \
  || fail "T1 svc_start arguments (trace: $(cat "$TRACE"))"
grep -qx 'provision' "$TRACE" && pass "T1 svc_provision runs after a successful start" || fail "T1 svc_provision ran"
! has 'fake server log line' && grep -q 'fake server log line' "$TMP/log/fake.log" \
  && pass "T1 svc_start's stdout goes to the log, not the terminal" \
  || fail "T1 svc_start's stdout goes to the log, not the terminal"

# T2 — prepare creates and owns the directories, and starts nothing.
rm -rf "$TMP/state" "$TMP/log" "$TMP/run"; : > "$TRACE"
run_runner prepare AI_SERVICES=fake=ON
[[ "$RC" -eq 0 && -d "$TMP/state/fake" && -d "$TMP/log" && -d "$TMP/run/fake" ]] \
  && pass "T2 prepare creates the data, log and runtime directories" \
  || fail "T2 prepare creates the data, log and runtime directories (rc=$RC, out=$OUT)"
[[ -z "$OUT" && ! -s "$TRACE" ]] \
  && pass "T2 prepare is silent and starts nothing" \
  || fail "T2 prepare is silent and starts nothing (out=$OUT, trace=$(cat "$TRACE"))"

# T3 — prepare skips a service the image does not have.
rm -rf "$TMP/state" "$TMP/log" "$TMP/run"
run_runner prepare AI_SERVICES=fake=ON FAKE_VERSION=
[[ ! -d "$TMP/state/fake" && -z "$OUT" ]] \
  && pass "T3 prepare skips a server this image lacks, silently (start reports it)" \
  || fail "T3 prepare skips a server this image lacks (out=$OUT)"

# T4 — unknown service.
reset; run_runner start AI_SERVICES=nosuch=ON
[[ "$RC" -eq 0 ]] && has "WARNING: unknown service 'nosuch'" \
  && pass "T4 an unknown service warns and exits 0" \
  || fail "T4 an unknown service warns and exits 0 (rc=$RC, out=$OUT)"

# T5 — a name that could escape services.d is refused in BOTH phases.
reset; rm -f "$TMP/evil-ran"
run_runner start 'AI_SERVICES=../evil=ON'
has "is not a valid service name" \
  && pass "T5 '../evil' is refused as a service name" \
  || fail "T5 '../evil' is refused as a service name (out=$OUT)"
run_runner prepare 'AI_SERVICES=../evil=ON'
[[ ! -e "$TMP/evil-ran" ]] \
  && pass "T5 no file outside services.d is ever sourced" \
  || fail "T5 a crafted name sourced a file outside services.d"

# T6 — key on, image without the server.
reset; run_runner start AI_SERVICES=fake=17 FAKE_VERSION=
has "WARNING: sandbox.conf has fake=17, but this image has no fake server. Rebuild: ./build.sh" \
  && pass "T6 a server missing from the image is named, with the rebuild command" \
  || fail "T6 missing-server warning (out=$OUT)"
[[ ! -s "$TRACE" ]] && pass "T6 svc_start is not called" || fail "T6 svc_start is not called"

# T7 — an incomplete adapter is skipped, and another adapter's functions never stand in.
reset; run_runner start AI_SERVICES=fake=ON,partial=ON
has "WARNING: services.d/partial.sh is incomplete — skipped" \
  && pass "T7 an incomplete adapter is skipped with a warning" \
  || fail "T7 incomplete adapter warning (out=$OUT)"
has "fake 1.2 ready on fake:1234" && ! grep -q 'start|partial' "$TRACE" \
  && pass "T7 adapters are isolated: fake's functions did not complete partial" \
  || fail "T7 adapters are isolated (out=$OUT, trace=$(cat "$TRACE"))"

# T8 — mismatch: ready line AND the warning.
reset; run_runner start AI_SERVICES=fake=17 FAKE_VERSION=16.15
has "fake 16.15 ready on fake:1234" \
  && has "WARNING: sandbox.conf asks for fake=17, this image has 16.15. Rebuild: ./build.sh" \
  && pass "T8 a stale image still starts, with the mismatch named" \
  || fail "T8 mismatch (out=$OUT)"

# T9 — no false mismatch.
for pair in '17:17.11' '17:17' 'ON:16.15'; do
  reset; run_runner start "AI_SERVICES=fake=${pair%%:*}" "FAKE_VERSION=${pair#*:}"
  ! has "asks for" \
    && pass "T9 fake=${pair%%:*} with ${pair#*:} installed is not a mismatch" \
    || fail "T9 fake=${pair%%:*} with ${pair#*:} installed is not a mismatch (out=$OUT)"
done

# T10 — the prefix trap: 17 must not match 170.1.
reset; run_runner start AI_SERVICES=fake=17 FAKE_VERSION=170.1
has "asks for fake=17, this image has 170.1" \
  && pass "T10 17 does not match 170.1" \
  || fail "T10 17 does not match 170.1 (out=$OUT)"

# T11 — an entry with no value is ON.
reset; run_runner start AI_SERVICES=fake FAKE_VERSION=16.15
has "fake 16.15 ready" && ! has "asks for" \
  && pass "T11 'fake' alone is treated as fake=ON" \
  || fail "T11 'fake' alone is treated as fake=ON (out=$OUT)"

# T12 — start failure: warning, log path, log tail, exit 0, no provisioning.
reset; run_runner start AI_SERVICES=fake=ON FAKE_START=fail
[[ "$RC" -eq 0 ]] && has "WARNING: fake failed to start — log: $TMP/log/fake.log" \
  && has "    boom: disk on fire" && ! has "ready on" \
  && pass "T12 a failed start prints the log path and its tail, and exits 0" \
  || fail "T12 failed start (rc=$RC, out=$OUT)"
! grep -qx 'provision' "$TRACE" && pass "T12 nothing is provisioned after a failed start" || fail "T12 provisioned after a failed start"

# T13 — one failure does not stop the next.
reset; run_runner start AI_SERVICES=bad=ON,fake=ON
has "WARNING: bad failed to start" && has "fake 1.2 ready on fake:1234" \
  && pass "T13 a failing service does not stop the next one" \
  || fail "T13 a failing service does not stop the next one (out=$OUT)"

# T14 — the watchdog: a hung start is cut off and reported.
reset; started=$SECONDS
run_runner start AI_SERVICES=fake=ON FAKE_START=hang AI_SERVICES_TIMEOUT=1
took=$((SECONDS - started))
[[ "$RC" -eq 0 ]] && has "WARNING: fake did not become ready within 1s" && (( took < 10 )) \
  && pass "T14 a hung start is cut off at AI_SERVICES_TIMEOUT (${took}s) and reported" \
  || fail "T14 watchdog (rc=$RC, took=${took}s, out=$OUT)"

# T15 — nothing asked for: nothing said.
reset; run_runner start AI_SERVICES=
[[ "$RC" -eq 0 && -z "$OUT" ]] && pass "T15 empty AI_SERVICES: silent, exit 0" || fail "T15 empty AI_SERVICES (rc=$RC, out=$OUT)"

# T16 — usage error is the ONE non-zero exit.
OUT="$(bash "$RUNNER" bogus 2>&1)"; RC=$?
[[ "$RC" -eq 2 && "$OUT" == *usage* ]] && pass "T16 an unknown phase is a usage error (exit 2)" || fail "T16 usage (rc=$RC, out=$OUT)"

# T17 — stray whitespace and empty entries.
reset; run_runner start 'AI_SERVICES= fake=ON , '
has "fake 1.2 ready on fake:1234" && ! has WARNING \
  && pass "T17 whitespace and an empty entry are tolerated" \
  || fail "T17 whitespace (out=$OUT)"

# T18 — a nonsense timeout falls back to the default rather than timing out at once.
reset; run_runner start AI_SERVICES=fake=ON AI_SERVICES_TIMEOUT=abc
has "fake 1.2 ready on fake:1234" \
  && pass "T18 a non-numeric AI_SERVICES_TIMEOUT falls back to the default" \
  || fail "T18 non-numeric timeout (out=$OUT)"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/run-all.sh test-start-services.sh`
Expected: FAIL throughout (`bash: …/start-services.sh: No such file or directory`).

- [ ] **Step 3: Create `start-services.sh`**

```bash
#!/usr/bin/env bash
# start-services.sh — start the in-container database servers sandbox.conf enabled.
#
# Two phases, because the entrypoint holds root only until it execs the agent
# shell, and a server must never run as root:
#
#   start-services.sh prepare   ROOT. Creates each enabled service's data, log
#                               and runtime directories and hands them to the
#                               sandbox user. Starts nothing, says nothing.
#   start-services.sh start     SANDBOX USER. Initialises and starts each server,
#                               provisions what the project asked for, and prints
#                               one ready line — or a warning and the log's tail.
#
# Input is AI_SERVICES ("name=value,name=value"), built by sandbox.sh from
# sandbox.conf (sandbox-common.sh: `services_csv()`). Each name has an adapter,
# services.d/<name>.sh, sourced in its OWN subshell so one adapter's functions
# can never stand in for another's. The adapter contract is in AGENTS.md
# ("In-container database servers").
#
# Never fatal: a server that fails to start must not cost the user their shell.
# Every path through `prepare` and `start` exits 0; only a usage error does not.
set -o pipefail

SERVICES_DIR="${AI_SERVICES_DIR:-/etc/ai-containers/services.d}"
STATE_ROOT="${AI_SERVICES_STATE_ROOT:-/var/lib/ai-services}"
LOG_ROOT="${AI_SERVICES_LOG_ROOT:-/var/log/ai-services}"
TIMEOUT="${AI_SERVICES_TIMEOUT:-60}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=60
# A name becomes a PATH ($SERVICES_DIR/<name>.sh), so it is held to a pattern
# with no `/` and no `.` — nothing can name a file outside services.d.
NAME_RE='^[a-z][a-z0-9-]*$'
ADAPTER_FUNCS=(svc_installed_version svc_runtime_dirs svc_start svc_provision svc_endpoint)

warn() { printf 'WARNING: %s\n' "$*" >&2; }

# run_bounded <seconds> <command…> — the command's own status, or 124 if the
# clock expired. The watchdog shape of tests/portability.sh: `p_timeout()`,
# copied rather than sourced because that file is not in the image; its comment
# explains why this is a watchdog and not a polling loop, and why the watchdog's
# stdio goes to /dev/null. Not timeout(1): this file's tests run on macOS hosts,
# which do not ship it.
run_bounded() {
  local secs="$1"; shift
  local flag; flag="$(mktemp "${TMPDIR:-/tmp}/ai-services.XXXXXX")" || return 125
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"
    printf 'x' > "$flag"
    kill -TERM "$cmd_pid" 2>/dev/null
    sleep 1
    kill -KILL "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local dog_pid=$!
  wait "$cmd_pid"
  local rc=$?
  kill -TERM "$dog_pid" 2>/dev/null
  wait "$dog_pid" 2>/dev/null
  if [[ -s "$flag" ]]; then rm -f "$flag"; return 124; fi
  rm -f "$flag"
  return "$rc"
}

# version_matches <requested> <installed> — 0 when <installed> IS the requested
# version or a release of it: `17` matches `17` and `17.11`, never `170.1`.
version_matches() {
  [[ "$2" == "$1" || "$2" == "$1".* ]]
}

# load_adapter <name> — source the adapter into THIS shell (callers are always
# inside a subshell). 0 = loaded and complete, 1 = failed to load, 2 = incomplete.
load_adapter() {
  local fn
  # shellcheck source=/dev/null
  source "$SERVICES_DIR/$1.sh" || return 1
  for fn in "${ADAPTER_FUNCS[@]}"; do
    declare -F "$fn" >/dev/null || return 2
  done
  return 0
}

# svc_up <datadir> <logfile> <suffix-file> — start, then provision. svc_start's
# output goes to the log: on success it is initdb/pg_ctl chatter, and on failure
# the runner prints the log's tail anyway. svc_provision's warnings reach the
# terminal; its stdout — the ready-line suffix — goes to a FILE, because this
# runs in the background under run_bounded and has no caller to capture it.
svc_up() {
  svc_start "$1" "$2" >>"$2" 2>&1 || return 1
  svc_provision > "$3"
}

# each_service <callback> — <callback> <name> <value> for every AI_SERVICES entry.
# Whitespace around an entry is dropped, an empty entry is skipped, and an entry
# with no `=value` (or an empty one) means ON.
each_service() {
  local cb="$1" entry name value
  local -a entries=()
  IFS=',' read -ra entries <<< "${AI_SERVICES:-}"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    value=""
    [[ "$entry" == *=* ]] && value="${entry#*=}"
    [[ -n "$value" ]] || value="ON"
    "$cb" "$name" "$value"
  done
}

# prepare_one <name> <value> — ROOT. Silent by design: every warning belongs to
# `start`, which runs next and would otherwise print each one twice.
prepare_one() {
  local name="$1"
  [[ "$name" =~ $NAME_RE && -f "$SERVICES_DIR/$name.sh" ]] || return 0
  (
    load_adapter "$name" || exit 0
    [[ -n "$(svc_installed_version)" ]] || exit 0
    owner="${SANDBOX_UID:-1000}:${SANDBOX_GID:-1000}"
    dirs=("$STATE_ROOT/$name" "$LOG_ROOT")
    while IFS= read -r d; do
      [[ -n "$d" ]] && dirs+=("$d")
    done < <(svc_runtime_dirs)
    for d in "${dirs[@]}"; do
      mkdir -p "$d" && chown "$owner" "$d"
    done
  )
  return 0
}

# start_one <name> <value> — SANDBOX USER.
start_one() {
  local name="$1" value="$2"
  if [[ ! "$name" =~ $NAME_RE ]]; then
    warn "AI_SERVICES: '$name' is not a valid service name — skipped"
    return 0
  fi
  if [[ ! -f "$SERVICES_DIR/$name.sh" ]]; then
    warn "unknown service '$name' (no $SERVICES_DIR/$name.sh) — skipped"
    return 0
  fi
  (
    load_adapter "$name"
    case $? in
      0) ;;
      1) warn "services.d/$name.sh failed to load — skipped"; exit 0 ;;
      *) warn "services.d/$name.sh is incomplete — skipped"; exit 0 ;;
    esac
    installed="$(svc_installed_version)"
    if [[ -z "$installed" ]]; then
      warn "sandbox.conf has $name=$value, but this image has no $name server. Rebuild: ./build.sh"
      exit 0
    fi
    logfile="$LOG_ROOT/$name.log"
    suffix_file="$(mktemp "${TMPDIR:-/tmp}/ai-services-suffix.XXXXXX")" || exit 0
    run_bounded "$TIMEOUT" svc_up "$STATE_ROOT/$name" "$logfile" "$suffix_file"
    rc=$?
    if (( rc == 0 )); then
      printf '%s %s ready on %s%s\n' "$name" "$installed" "$(svc_endpoint)" "$(cat "$suffix_file")" >&2
      if [[ "$value" != "ON" ]] && ! version_matches "$value" "$installed"; then
        warn "sandbox.conf asks for $name=$value, this image has $installed. Rebuild: ./build.sh"
      fi
    else
      if (( rc == 124 )); then
        warn "$name did not become ready within ${TIMEOUT}s — log: $logfile"
      else
        warn "$name failed to start — log: $logfile"
      fi
      tail -n 20 "$logfile" 2>/dev/null | sed 's/^/    /' >&2
    fi
    rm -f "$suffix_file"
  )
  return 0
}

case "${1:-}" in
  prepare) each_service prepare_one ;;
  start)   each_service start_one ;;
  *)       printf 'usage: start-services.sh prepare|start\n' >&2; exit 2 ;;
esac
exit 0
```

Then: `chmod 755 start-services.sh`.

- [ ] **Step 4: Run the runner tests**

Run: `bash tests/run-all.sh test-start-services.sh`
Expected: all PASS. If T14 is flaky under load, do NOT raise the bound past 10 s — investigate first (the watchdog must cut at `TIMEOUT` + 1 s).

- [ ] **Step 5: Register the falsify target**

The test now EXECUTES `start-services.sh`, so `tests/test-falsify-targets.sh` requires a row. In `tests/falsify/targets.conf`, append after the line `ai-containers-report.sh|EXECUTED-WHOLE|test-report.sh`:

```
start-services.sh|EXECUTED-WHOLE|test-start-services.sh
```

- [ ] **Step 6: Lint and re-run the gates this touches**

Run: `shellcheck -S warning -e SC1091 start-services.sh tests/test-start-services.sh && bash tests/bash-dialect-lint.sh start-services.sh tests/test-start-services.sh; bash tests/run-all.sh test-start-services.sh test-falsify-targets.sh test-bash-dialect-lint.sh test-exit-trap-ownership.sh`
(`-S warning -e SC1091` is exactly the CI/Phase 7 gate.) Expected: no shellcheck output; all PASS. If `test-falsify-targets.sh` reports a disagreement, follow its message (it names the derivation's verdict); do not hand-edit the derivation.

- [ ] **Step 7: Commit**

```bash
git add start-services.sh tests/test-start-services.sh tests/falsify/targets.conf
git commit -m "feat(services): start-services.sh, the shared in-container service runner

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The PostgreSQL adapter `services.d/postgres.sh`

**Files:**
- Create: `services.d/postgres.sh` (mode 644 — sourced, never executed)
- Modify: `tests/test-postgres.sh` — Part D
- Modify: `tests/falsify/targets.conf`

**Interfaces:**
- Consumes: the adapter contract (Task 3); env `POSTGRES_ROLES`, `POSTGRES_DATABASES`; overrides `PG_MAJOR_FILE`, `PG_LIB_ROOT`, `PG_SOCKET_DIR`, `PG_PORT`, `PG_SUPERUSER` (tests only).
- Produces: `/var/run/postgresql` via `svc_runtime_dirs`; the ready line `postgres <ver> ready on localhost:5432 (socket /var/run/postgresql), superuser <user>[; roles: …][; databases: …]`.

- [ ] **Step 1: Append Part D to `tests/test-postgres.sh`** (before the final summary line)

```bash
# ── Part D: services.d/postgres.sh against fake binaries ───────────────────────
FAKE="$TMP_ROOT/pg"; mkdir -p "$FAKE/lib/18/bin" "$FAKE/sock" "$FAKE/data"
printf '18\n' > "$FAKE/major"
cat > "$FAKE/lib/18/bin/postgres" <<'EOF'
#!/usr/bin/env bash
printf 'postgres (PostgreSQL) 18.6 (Ubuntu 18.6-1.pgdg24.04+2)\n'
EOF
cat > "$FAKE/lib/18/bin/initdb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/initdb.args"
[[ "${FAKE_INITDB_RC:-0}" -eq 0 ]] || exit "$FAKE_INITDB_RC"
while (( $# )); do [[ "$1" == -D ]] && { mkdir -p "$2"; printf '# initdb default\n' > "$2/postgresql.conf"; }; shift; done
EOF
cat > "$FAKE/lib/18/bin/pg_ctl" <<'EOF'
#!/usr/bin/env bash
printf '%s ' "$@" > "$FAKE_DIR/pg_ctl.args"
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
  ( export PG_MAJOR_FILE="$FAKE/major" PG_LIB_ROOT="$FAKE/lib" PG_SOCKET_DIR="$FAKE/sock" \
           PG_SUPERUSER="${PG_SUPERUSER_TEST:-alice}" FAKE_DIR="$FAKE" \
           FAKE_PSQL_FAIL="${FAKE_PSQL_FAIL:-}" FAKE_INITDB_RC="${FAKE_INITDB_RC:-0}"
    # shellcheck source=../services.d/postgres.sh
    source "$REPO_DIR/services.d/postgres.sh"
    "$@" )
}
pg_reset() { rm -f "$FAKE"/{sql.log,psql.users,initdb.args,pg_ctl.args}; rm -rf "$FAKE/data"; }
sql_has()   { grep -qxF -- "$1" "$FAKE/sql.log" 2>/dev/null; }
sql_count() { if [[ -f "$FAKE/sql.log" ]]; then grep -c . "$FAKE/sql.log"; else printf '0'; fi; }

# D1–D3 — what this image has.
got="$(pg svc_installed_version)"
[[ "$got" == "18.6" ]] && pass "D1 svc_installed_version reads 18.6 out of PGDG's version string" || fail "D1 svc_installed_version (got '$got')"
mv "$FAKE/major" "$FAKE/major.off"
got="$(pg svc_installed_version)"
[[ -z "$got" ]] && pass "D2 no major marker → nothing installed" || fail "D2 no major marker (got '$got')"
printf '17\n' > "$FAKE/major"
got="$(pg svc_installed_version)"
[[ -z "$got" ]] && pass "D3 a marker naming a major with no binaries → nothing installed" || fail "D3 marker without binaries (got '$got')"
mv "$FAKE/major.off" "$FAKE/major"

# D4 — the socket directory is the one runtime dir.
[[ "$(pg svc_runtime_dirs)" == "$FAKE/sock" ]] && pass "D4 svc_runtime_dirs is the socket directory" || fail "D4 svc_runtime_dirs"

# D5 — svc_start: initdb flags, appended config, pg_ctl flags.
pg_reset; pg svc_start "$FAKE/data" "$FAKE/log"; rc=$?
[[ "$rc" -eq 0 ]] && pass "D5 svc_start returns 0" || fail "D5 svc_start returns 0 (rc=$rc)"
for want in -D "$FAKE/data" -U alice --auth=trust --encoding=UTF8 --locale=en_US.UTF-8; do
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

# D6 — initdb fails: svc_start fails, and nothing is started.
pg_reset; FAKE_INITDB_RC=1 pg svc_start "$FAKE/data" "$FAKE/log"; rc=$?
[[ "$rc" -ne 0 && ! -e "$FAKE/pg_ctl.args" ]] \
  && pass "D6 a failed initdb fails svc_start and never reaches pg_ctl" \
  || fail "D6 failed initdb (rc=$rc)"

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
pg_reset; out="$(POSTGRES_ROLES= POSTGRES_DATABASES= pg svc_provision 2>"$FAKE/err")"; rc=$?
[[ "$rc" -eq 0 && -z "$out" && "$(sql_count)" -eq 0 && ! -s "$FAKE/err" ]] \
  && pass "D17 nothing requested: nothing run, nothing printed" \
  || fail "D17 (rc=$rc out='$out')"
```

- [ ] **Step 2: Run it and watch Part D fail**

Run: `bash tests/run-all.sh test-postgres.sh`
Expected: every D assertion FAILs (`services.d/postgres.sh: No such file or directory`); Parts A–C, F PASS.

- [ ] **Step 3: Create `services.d/postgres.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# services.d/postgres.sh — the PostgreSQL adapter for start-services.sh.
#
# SOURCED by start-services.sh (never executed), in a subshell of its own, and
# implementing the adapter contract in AGENTS.md ("In-container database
# servers").
#
# What it builds is a THROWAWAY TEST CLUSTER: initdb into the container's own
# filesystem on every start, trust authentication, listening on localhost and
# the Debian default socket only, durability switched off. Nothing here is fit
# for data anyone wants to keep, and nothing here has to be — sandbox.sh runs
# the container with --rm.
#
# Every path is overridable from the environment so tests/test-postgres.sh can
# drive this file against fake binaries. Nothing in the image sets them.

PG_MAJOR_FILE="${PG_MAJOR_FILE:-/etc/ai-containers/postgres-major}"
PG_LIB_ROOT="${PG_LIB_ROOT:-/usr/lib/postgresql}"
PG_SOCKET_DIR="${PG_SOCKET_DIR:-/var/run/postgresql}"
PG_PORT="${PG_PORT:-5432}"
PG_SUPERUSER="${PG_SUPERUSER:-$(id -un)}"
# Role and database names a project may ask for. Deliberately narrow — every
# name reaches SQL — and the superuser's own name is NOT held to it: it comes
# from the host, where a macOS `John.Doe` is legal. _pg_ident quotes either.
PG_NAME_RE='^[a-z_][a-z0-9_]*$'

_pg_bin() {
  local major
  # 2>/dev/null BEFORE the <: redirections apply left to right, and a missing
  # marker must fail silently — it is how "not in this image" is detected.
  major="$(tr -d '[:space:]' 2>/dev/null < "$PG_MAJOR_FILE")"
  printf '%s/%s/bin' "$PG_LIB_ROOT" "$major"
}

# Whitespace off both ends — [[:space:]] includes the \r a CRLF container.env leaves.
_pg_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# An SQL identifier: double-quoted, any embedded " doubled.
_pg_ident() { printf '"%s"' "${1//\"/\"\"}"; }

_pg_in() {  # <needle> <haystack…> → 0 if present
  local x="$1" y; shift
  for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done
  return 1
}

_pg_join() {  # <item…> → "a, b, c"
  local out="$1" y; shift
  for y in "$@"; do out+=", $y"; done
  printf '%s' "$out"
}

# _pg_sql <statement> — run it as the superuser over the socket. Prints psql's
# error text (one line) on failure and returns psql's status.
_pg_sql() {
  local err rc
  err="$("$(_pg_bin)/psql" -X -q -v ON_ERROR_STOP=1 -h "$PG_SOCKET_DIR" -p "$PG_PORT" \
           -U "$PG_SUPERUSER" -d postgres -c "$1" 2>&1 >/dev/null)"
  rc=$?
  (( rc == 0 )) || printf '%s' "${err//$'\n'/ }"
  return "$rc"
}

svc_installed_version() {
  local bin; bin="$(_pg_bin)/postgres"
  [[ -x "$bin" ]] || return 0
  "$bin" --version 2>/dev/null | sed -n 's/^postgres (PostgreSQL) \([0-9][0-9.]*\).*/\1/p'
}

svc_runtime_dirs() { printf '%s\n' "$PG_SOCKET_DIR"; }

svc_start() {  # <datadir> <logfile>
  local datadir="$1" logfile="$2" bin
  bin="$(_pg_bin)"
  # en_US.UTF-8, not the image's C.utf8: the official postgres image — what CI
  # service containers usually run — defaults to it, and collation decides
  # ORDER BY on text. A suite green in CI must not go red here on sort order.
  "$bin/initdb" -D "$datadir" -U "$PG_SUPERUSER" --auth=trust \
    --encoding=UTF8 --locale=en_US.UTF-8 || return 1
  # fsync/synchronous_commit/full_page_writes off: durability buys nothing for a
  # cluster deleted on exit. mmap: dynamic shared memory from files in the data
  # directory, so Docker's 64 MB /dev/shm never limits it and sandbox.sh's
  # --shm-size stays playwright's business.
  cat >> "$datadir/postgresql.conf" <<EOF || return 1

# ── ai-containers (services.d/postgres.sh): a throwaway test cluster ──
listen_addresses = 'localhost'
port = $PG_PORT
unix_socket_directories = '$PG_SOCKET_DIR'
fsync = off
synchronous_commit = off
full_page_writes = off
dynamic_shared_memory_type = mmap
EOF
  "$bin/pg_ctl" -D "$datadir" -l "$logfile" -w -t 30 start
}

svc_provision() {
  local entry name owner err
  local -a entries=() roles=() dbs=() known=("$PG_SUPERUSER")

  IFS=',' read -ra entries <<< "${POSTGRES_ROLES:-}"
  for entry in "${entries[@]}"; do
    name="$(_pg_trim "$entry")"
    if [[ ! "$name" =~ $PG_NAME_RE ]]; then
      printf "WARNING: POSTGRES_ROLES: '%s' is not a valid role name (lowercase letters, digits, _) — skipped\n" "$name" >&2
      continue
    fi
    _pg_in "$name" "${known[@]}" && continue   # the superuser itself, or a repeat
    if err="$(_pg_sql "CREATE ROLE $(_pg_ident "$name") SUPERUSER LOGIN")"; then
      roles+=("$name"); known+=("$name")
    else
      printf "WARNING: POSTGRES_ROLES: could not create role '%s': %s\n" "$name" "$err" >&2
    fi
  done

  entries=()
  IFS=',' read -ra entries <<< "${POSTGRES_DATABASES:-}"
  for entry in "${entries[@]}"; do
    entry="$(_pg_trim "$entry")"
    name="${entry%%:*}"
    owner="$PG_SUPERUSER"
    [[ "$entry" == *:* ]] && owner="${entry#*:}"
    if [[ ! "$name" =~ $PG_NAME_RE ]] || { [[ "$entry" == *:* ]] && [[ ! "$owner" =~ $PG_NAME_RE ]]; }; then
      printf "WARNING: POSTGRES_DATABASES: '%s' is not name or name:owner (lowercase letters, digits, _) — skipped\n" "$entry" >&2
      continue
    fi
    if ! _pg_in "$owner" "${known[@]}"; then
      printf "WARNING: POSTGRES_DATABASES: '%s' — owner '%s' is not a role here (add it to POSTGRES_ROLES) — skipped\n" "$entry" "$owner" >&2
      continue
    fi
    _pg_in "$name" "${dbs[@]}" && continue
    if err="$(_pg_sql "CREATE DATABASE $(_pg_ident "$name") OWNER $(_pg_ident "$owner")")"; then
      dbs+=("$name")
    else
      printf "WARNING: POSTGRES_DATABASES: could not create database '%s': %s\n" "$name" "$err" >&2
    fi
  done

  (( ${#roles[@]} )) && printf '; roles: %s' "$(_pg_join "${roles[@]}")"
  (( ${#dbs[@]} )) && printf '; databases: %s' "$(_pg_join "${dbs[@]}")"
  return 0
}

svc_endpoint() {
  printf 'localhost:%s (socket %s), superuser %s' "$PG_PORT" "$PG_SOCKET_DIR" "$PG_SUPERUSER"
}
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/run-all.sh test-postgres.sh test-start-services.sh`
Expected: all PASS.

- [ ] **Step 5: Register the falsify target**

Append to `tests/falsify/targets.conf`, after the `start-services.sh` row:

```
services.d/postgres.sh|EXECUTED-WHOLE|test-postgres.sh
```

- [ ] **Step 6: Lint and gates**

Run: `shellcheck -S warning -e SC1091 services.d/postgres.sh tests/test-postgres.sh && bash tests/bash-dialect-lint.sh services.d/postgres.sh tests/test-postgres.sh; bash tests/run-all.sh test-postgres.sh test-falsify-targets.sh test-bash-dialect-lint.sh test-exit-trap-ownership.sh`
Expected: clean; all PASS.

- [ ] **Step 7: Commit**

```bash
git add services.d/postgres.sh tests/test-postgres.sh tests/falsify/targets.conf
git commit -m "feat(postgres): the PostgreSQL adapter — throwaway cluster, roles and databases

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Wire `run_services` into the entrypoint

**Files:**
- Modify: `entrypoint.sh`
- Modify: `tests/test-entrypoint-wiring.sh`

**Interfaces:**
- Consumes: `/usr/local/bin/start-services.sh` (installed by Task 6), env `AI_SERVICES` (Task 2).

- [ ] **Step 1: Add the failing assertions to `tests/test-entrypoint-wiring.sh`**

Insert before its final `printf '\n%d failure(s)\n'` line:

```bash
# ── in-container database servers ──────────────────────────────────────────────
# Grep-level, like the rest of this file: entrypoint.sh runs as root and is
# GREPPED-ONLY in the falsify tier. That a real server starts is integration case
# 780-postgres-server-runs. run_services deliberately takes NO env override for
# the runner's path — container.env reaches this root process, and an override
# would let a project's data file choose what root executes.
grep -q '^run_services() {' "$REPO_DIR/entrypoint.sh" && pass "defines run_services" || fail "defines run_services"
ns="$(grep -c '^[[:space:]]*run_services$' "$REPO_DIR/entrypoint.sh")"
[[ "$ns" -ge 3 ]] && pass "run_services wired in 3 modes ($ns)" || fail "run_services wired in 3 modes ($ns)"
grep -q 'runuser -u "$sandbox_user" -- /usr/local/bin/start-services.sh start' "$REPO_DIR/entrypoint.sh" \
  && pass "the start phase runs as the sandbox user" \
  || fail "the start phase runs as the sandbox user"
grep -q 'AI_SERVICES_RUNNER' "$REPO_DIR/entrypoint.sh" \
  && fail "run_services takes no env override for the runner path" \
  || pass "run_services takes no env override for the runner path"
# LAST before the exec in each mode, so the ready line is the last thing printed
# before the prompt.
for m in restricted discovery open; do
  block="$(awk -v m="$m" '
    $0 ~ "^[[:space:]]*"m"\\)" {grab=1; next}
    grab && /;;/ {grab=0}
    grab {print}
  ' "$REPO_DIR/entrypoint.sh")"
  order="$(grep -E '^[[:space:]]*(run_agent_skill_install|run_services|exec capsh)' <<<"$block" \
           | awk '{print $1}' | tr '\n' ' ')"
  [[ "$order" == "run_agent_skill_install run_services exec " ]] \
    && pass "$m: run_services runs after the skill install and immediately before exec capsh" \
    || fail "$m: run_services order (got: $order)"
done
```

- [ ] **Step 2: Run and watch it fail**

Run: `bash tests/run-all.sh test-entrypoint-wiring.sh`
Expected: the new assertions FAIL (`defines run_services`, `wired in 3 modes (0)`, the three order checks); the AI_SERVICES_RUNNER negative PASSes.

- [ ] **Step 3: Add `run_services` to `entrypoint.sh`**

Insert immediately after the `link_agent_tools()` function:

```bash
# Start the in-container database servers sandbox.conf enabled (AI_SERVICES).
# `prepare` runs as ROOT and only creates directories for the sandbox user;
# `start` runs as the sandbox user, so no server process is ever root. Both are
# non-fatal: a server that fails to start must not cost the user their shell.
# The runner's path is fixed on purpose — container.env reaches this process,
# and no project data file may choose what root executes.
run_services() {
  [[ -n "${AI_SERVICES:-}" ]] || return 0
  [[ -x /usr/local/bin/start-services.sh ]] || return 0
  /usr/local/bin/start-services.sh prepare || true
  runuser -u "$sandbox_user" -- /usr/local/bin/start-services.sh start || true
}
```

- [ ] **Step 4: Call it in all three modes**

In each of the `restricted)`, `discovery)` and `open)` branches, insert a line `    run_services` immediately after the existing `    run_agent_skill_install` line (and therefore before the blank line and `exec capsh`).

- [ ] **Step 5: Run the tests**

Run: `bash tests/run-all.sh test-entrypoint-wiring.sh test-mode-capabilities.sh test-open-mode.sh && bash -n entrypoint.sh && shellcheck -S warning -e SC1091 entrypoint.sh`
Expected: all PASS; no shellcheck output.

- [ ] **Step 6: Commit**

```bash
git add entrypoint.sh tests/test-entrypoint-wiring.sh
git commit -m "feat(services): start enabled servers from the entrypoint, as the sandbox user

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The image layer and shipping to projects

**Files:**
- Modify: `Dockerfile` (new layer after the shellcheck layer; `COPY` beside `install-agent-skills.sh`)
- Modify: `shared-files.sh`, `project-init.sh`, `sync-to-projects.sh`
- Modify: `sandbox-common.sh` — `ai_containers_payload_files()`
- Modify: `tests/test-postgres.sh` (Parts E, G), `tests/test-sync-project.sh`, `tests/test-shared-files-parity.sh`

**Interfaces:**
- Consumes: build arg `POSTGRES_VERSION` (Task 1); `start-services.sh`, `services.d/` (Tasks 3–4).
- Produces: `/usr/lib/postgresql/<major>/bin/*`, `/etc/ai-containers/postgres-major`, `/usr/local/bin/start-services.sh`, `/etc/ai-containers/services.d/postgres.sh` in the image.

- [ ] **Step 1: Append Parts E and G to `tests/test-postgres.sh`** (before the final summary line)

```bash
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

# ── Part G: shipping to projects ───────────────────────────────────────────────
( source "$REPO_DIR/shared-files.sh"; printf '%s\n' "${AI_CONTAINERS_SHARED_FILES[@]}" ) | grep -qx 'start-services.sh' \
  && pass "G start-services.sh is a shared file (a project's build COPYs it)" \
  || fail "G start-services.sh is a shared file"
payload="$(bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_payload_files "$1"' _ "$REPO_DIR")"
grep -qx 'services.d/postgres.sh' <<<"$payload" && grep -qx 'start-services.sh' <<<"$payload" \
  && pass "G the provenance digest covers the runner and services.d/ (they are built into the image)" \
  || fail "G provenance digest coverage"
```

- [ ] **Step 2: Add the project-copy assertions**

In `tests/test-sync-project.sh`, directly after the `tools.d/ fragments synced` if/else block:

```bash
if [[ -f "$DEST/services.d/postgres.sh" ]] && cmp -s "$REPO_DIR/services.d/postgres.sh" "$DEST/services.d/postgres.sh" 2>/dev/null; then
  pass "services.d/ adapters synced"
else
  fail "services.d/ adapters synced"
fi
```

In `tests/test-shared-files-parity.sh`, before its final `printf '\n%d failure(s)\n'` line:

```bash
# services.d/ is a directory, so it is copied by rsync beside tools.d/ rather than
# listed in AI_CONTAINERS_SHARED_FILES — which makes it the one engine input this
# file's list-parity check cannot see. Asserted by effect in both callers.
for d in "$DEST_A" "$DEST_B"; do
  if cmp -s "$REPO_DIR/services.d/postgres.sh" "$d/services.d/postgres.sh" 2>/dev/null; then
    pass "services.d/ lands in $(basename "$(dirname "$d")")"
  else
    fail "services.d/ lands in $(basename "$(dirname "$d")")"
  fi
done
```

- [ ] **Step 3: Run and watch them fail**

Run: `bash tests/run-all.sh test-postgres.sh test-sync-project.sh test-shared-files-parity.sh`
Expected: Parts E and G FAIL, and the three `services.d/` copy assertions FAIL.

- [ ] **Step 4: Add the Dockerfile layer**

Insert immediately after the shellcheck layer's closing `    fi` (the `RUN if [ "$INSTALL_SHELLCHECK" = "1" ]` block) and its following blank line, before `# ── Ruby runtime prerequisites`:

```dockerfile
# ── Optional: PostgreSQL server (in-container, for tests) ──────────────────────
# POSTGRES_VERSION: empty = skip; `latest` (from postgres=ON) or a major (17).
# From PGDG (apt.postgresql.org), `main` component ONLY — PGDG publishes betas
# in per-major components (`19`, `20`), so main alone can never install one.
# `latest` resolves through PGDG's own `postgresql` metapackage: the definition
# of "current" is PGDG's, not this file's. A major PGDG does not carry fails the
# build with the majors it does.
#
# create_main_cluster = false: the Debian packaging would otherwise create a
# cluster at BUILD time, owned by the `postgres` user, which nothing uses —
# services.d/postgres.sh initdb's a fresh one as the sandbox user at every start.
# en_US.UTF-8 is generated because the base image ships only C/C.utf8, and the
# adapter creates the cluster with the official postgres image's default
# collation (see services.d/postgres.sh).
#
# The resolved major is recorded at /etc/ai-containers/postgres-major: it is how
# the adapter finds /usr/lib/postgresql/<major>/bin, and what the runner compares
# against a pinned postgres= to warn about a stale image.
#
# After the cleanup purge above, alongside playwright/shellcheck: apt marks these
# packages manual, so the later qmd-layer purge's --auto-remove leaves them.
ARG POSTGRES_VERSION=
RUN if [ -n "$POSTGRES_VERSION" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends locales gnupg && \
      locale-gen en_US.UTF-8 && \
      codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" && \
      curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql-pgdg.gpg && \
      echo "deb [signed-by=/usr/share/keyrings/postgresql-pgdg.gpg] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
        > /etc/apt/sources.list.d/postgresql-pgdg.list && \
      mkdir -p /etc/postgresql-common && \
      echo 'create_main_cluster = false' > /etc/postgresql-common/createcluster.conf && \
      apt-get update && \
      major="$POSTGRES_VERSION" && \
      if [ "$major" = "latest" ]; then \
        major="$(apt-cache depends postgresql | sed -n 's/^ *Depends: postgresql-\([0-9][0-9]*\)$/\1/p' | head -1)"; \
      fi && \
      if [ -z "$major" ] || ! apt-cache show "postgresql-$major" >/dev/null 2>&1; then \
        echo "ERROR: postgres=$POSTGRES_VERSION in sandbox.conf: PGDG has no postgresql-${major:-?} for ${codename}." >&2; \
        echo "       Majors it does carry: $(apt-cache search --names-only '^postgresql-[0-9]+$' | sed 's/^postgresql-\([0-9]*\) .*/\1/' | sort -n | tr '\n' ' ')" >&2; \
        exit 1; \
      fi && \
      apt-get install -y --no-install-recommends "postgresql-$major" && \
      test -x "/usr/lib/postgresql/$major/bin/postgres" && \
      mkdir -p /etc/ai-containers && printf '%s\n' "$major" > /etc/ai-containers/postgres-major && \
      rm -rf /var/lib/apt/lists/*; \
    fi

```

- [ ] **Step 5: Copy the runner and adapters into the image**

In `Dockerfile`, replace:

```dockerfile
COPY install-agent-skills.sh /usr/local/bin/install-agent-skills.sh
RUN chmod +x /usr/local/bin/install-agent-skills.sh
```

with:

```dockerfile
COPY install-agent-skills.sh /usr/local/bin/install-agent-skills.sh
COPY start-services.sh /usr/local/bin/start-services.sh
COPY services.d /etc/ai-containers/services.d
RUN chmod +x /usr/local/bin/install-agent-skills.sh /usr/local/bin/start-services.sh
```

- [ ] **Step 6: Ship to projects**

`shared-files.sh` — in `AI_CONTAINERS_SHARED_FILES`, change the line `  agent-tools-reconcile.sh link-agent-tools.sh` to:

```bash
  agent-tools-reconcile.sh link-agent-tools.sh start-services.sh
```

`project-init.sh` — after `rsync -a "${script_dir}/tools.d/" "${dest}/tools.d/"` add:

```bash
rsync -a "${script_dir}/services.d/" "${dest}/services.d/"
```

`sync-to-projects.sh` — after `  rsync -a "${script_dir}/tools.d/" "${dest}/tools.d/"` add:

```bash
  rsync -a "${script_dir}/services.d/" "${dest}/services.d/"
```

`sandbox-common.sh` — in `ai_containers_payload_files()`, change:

```bash
      for f in allowlist-*.d/*.txt tools.d/*; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
```

to:

```bash
      for f in allowlist-*.d/*.txt tools.d/* services.d/*; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
```

- [ ] **Step 7: Run the tests**

Run: `bash tests/run-all.sh test-postgres.sh test-sync-project.sh test-shared-files-parity.sh test-project-init.sh test-provenance.sh test-host-preflight.sh`
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add Dockerfile shared-files.sh project-init.sh sync-to-projects.sh sandbox-common.sh \
        tests/test-postgres.sh tests/test-sync-project.sh tests/test-shared-files-parity.sh
git commit -m "feat(postgres): the PGDG image layer, and shipping the runner to projects

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Smoke-test a real image (verification only — no commit)

Cheap proof before the expensive integration run: build a minimal image with only `postgres=ON` and start it in restricted mode.

- [ ] **Step 1: Build a minimal image from a scratch config**

```bash
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/pg-smoke"
bash tests/integration/minimal-conf.sh sandbox.conf postgres=ON > "$SCRATCH/pg-smoke/sandbox.conf"
SANDBOX_CONF="$SCRATCH/pg-smoke/sandbox.conf" ./build.sh ai-pg-smoke
```

Expected: build succeeds; the log shows `postgresql-18` being installed.

- [ ] **Step 2: Start it detached, in restricted mode, with roles and a database**

`sandbox.sh` runs `docker run -it` and needs a terminal, so the smoke test starts
the image the way the integration launcher's shim does — detached with a TTY —
passing what `sandbox.sh` would. (`AI_SERVICES` coming from `sandbox.conf` is
already proven by `tests/test-postgres.sh` Part C.)

```bash
printf 'POSTGRES_ROLES=app_user\nPOSTGRES_DATABASES=myapp_test:app_user\n' > "$SCRATCH/pg-smoke/container.env"
docker run -dit --rm --name ai-pg-smoke --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e DEV_CONTAINER_MODE=restricted -e AI_SERVICES=postgres=ON \
  -e SANDBOX_UID="$(id -u)" -e SANDBOX_GID="$(id -g)" \
  -e SANDBOX_USER="$(id -un)" -e SANDBOX_GROUP="$(id -gn)" \
  --env-file "$SCRATCH/pg-smoke/container.env" ai-pg-smoke
timeout 120 bash -c 'until docker logs ai-pg-smoke 2>&1 | grep -qE "postgres .* ready on|postgres (failed|did not)"; do sleep 2; done'
docker logs ai-pg-smoke 2>&1 | grep -E 'postgres|WARNING'
```

Expected: `postgres 18.6 ready on localhost:5432 (socket /var/run/postgresql), superuser <you>; roles: app_user; databases: myapp_test`, and no `WARNING` about postgres.

- [ ] **Step 3: Check, as the agent user, what the integration case will check**

```bash
U="$(id -u):$(id -g)"
docker exec -u "$U" ai-pg-smoke psql -X -At -d postgres -c 'select current_user, version()'
docker exec -u "$U" -e PGPASSWORD=whatever ai-pg-smoke psql -X -At -q -h 127.0.0.1 -U app_user -d myapp_test -c 'create extension pgcrypto' -c 'select 1'
docker exec -u "$U" ai-pg-smoke psql -X -At -d postgres -c "select datcollate from pg_database where datname='postgres'"
docker exec ai-pg-smoke awk 'NR>1 && $4=="0A" && $2 ~ /:1538$/ {print FILENAME": "$2}' /proc/net/tcp /proc/net/tcp6
```

Expected: your user + `PostgreSQL 18.6`; `1`; `en_US.UTF-8`; listeners only `0100007F:1538` and `00000000000000000000000001000000:1538`. If any fails, fix it here — with a hermetic test first if it is logic — before Task 8.

- [ ] **Step 4: Clean up**

```bash
docker rm -f ai-pg-smoke
docker rmi ai-pg-smoke
rm -rf "$SCRATCH/pg-smoke"
```

---

### Task 8: Integration case 780 and its mutations

**Files:**
- Create: `tests/integration/cases/780-postgres-server-runs.sh`
- Create: `tests/integration/mutations/780-postgres-not-started.patch`, `781-postgres-listens-everywhere.patch`, `782-postgres-roles-not-provisioned.patch`
- Modify: `tests/integration/run.sh` — `variant_overrides()`
- Modify: `tests/test-integration-runner.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–6; `tests/integration/lib.sh` helpers `fixture_scope_init`, `it_scratch`, `launcher_up`, `agent_exec`, `assert_log_contains`, `pass`/`fail`/`it_finish`, `IT_CID`, `IT_LAUNCH_UID`, `IT_RUBY_GROUP`.

- [ ] **Step 1: Put `postgres=ON` into the `native` variant (test first)**

In `tests/test-integration-runner.sh`, replace:

```bash
  *db-clients=pg,mysql,mongo*imagemagick=ON*wkhtmltopdf=ON*playwright=ON*ruby=3.3.6,3.4.5*)
    pass "variant native carries the KEEP_BUILD_TOOLCHAIN components, playwright and both rubies" ;;
```

with:

```bash
  *db-clients=pg,mysql,mongo*imagemagick=ON*wkhtmltopdf=ON*playwright=ON*postgres=ON*ruby=3.3.6,3.4.5*)
    pass "variant native carries the KEEP_BUILD_TOOLCHAIN components, playwright, postgres and both rubies" ;;
```

Run: `bash tests/run-all.sh test-integration-runner.sh` → Expected: that assertion FAILs.

In `tests/integration/run.sh` `variant_overrides()`, change the `native)` line to:

```bash
    native)  printf 'db-clients=pg,mysql,mongo imagemagick=ON wkhtmltopdf=ON playwright=ON postgres=ON ruby=%s' "$IT_RUBY_VERSIONS" ;;
```

Run: `bash tests/run-all.sh test-integration-runner.sh` → Expected: PASS.

- [ ] **Step 2: Write the case `tests/integration/cases/780-postgres-server-runs.sh`**

```bash
#!/usr/bin/env bash
# summary:  postgres=ON starts a loopback-only server owned by the agent, before the shell
# tags:     packages slow
# requires: docker launcher netadmin
# image:    native
# timeout:  3900
#
# WHAT IS PROVEN, against the real image the `native` variant builds with
# postgres=ON, in RESTRICTED mode:
#   1. a server answers over the default socket AND over 127.0.0.1 — so the
#      entrypoint started it before handing over, and the firewall did not get
#      in the way (loopback is allowed; no allowlist entry exists for it);
#   2. every postgres process runs as the sandbox UID, never root;
#   3. it listens on loopback addresses only;
#   4. POSTGRES_ROLES / POSTGRES_DATABASES from the project's container.env were
#      provisioned: app_user is a superuser and owns myapp_test;
#   5. app_user connects over TCP with a password the server never checks, and
#      can create a contrib extension (pgcrypto) and a database;
#   6. the cluster's collation is en_US.UTF-8, the official postgres image's
#      default, so ORDER BY behaves as it does in CI;
#   7. the entrypoint printed the ready line.
#
# The hermetic halves — validation, the build arg, the runner, the adapter's
# SQL — are tests/test-postgres.sh and tests/test-start-services.sh. Neither can
# show a server starting in a real image; this case is the only place that is.
#
# Not needs-external: nothing here touches the network at run time. netadmin IS
# required — launcher_up drives restricted mode.
#
# GROUP: $IT_RUBY_GROUP, shared with 730–770 for the reason 770's header gives —
# the native variant runs the rvm reconcile at every container start, and a cold
# one compiles Ruby; IT_SETTLE covers it.
#
# Mutations 780, 781 and 782 demonstrate this case failing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# shellcheck disable=SC2034  # consumed by tests/integration/lib.sh's it_wait/run.sh, which read it after this case is sourced
IT_SETTLE=3600

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"
scratch="$(it_scratch)"
printf 'POSTGRES_ROLES=app_user\nPOSTGRES_DATABASES=myapp_test:app_user\n' > "$scratch/container.env"
export SANDBOX_ENV_FILE="$scratch/container.env"
launcher_up restricted || it_finish

# Every query runs AS THE AGENT (agent_exec), never as root: the claim is that
# the agent's own shell can use the server with no setup at all.
q() { agent_exec "$IT_CID" "psql -X -At -q -v ON_ERROR_STOP=1 $1" 2>&1; }

# ── 1. The server answers, over the socket and over TCP ─────────────────────────
if [[ "$(q "-d postgres -c 'select 1'")" == "1" ]]; then
  pass "psql over the default socket answers, as the agent"
else
  fail "psql over the default socket did not answer — no server, or not where libpq looks"
  docker exec "$IT_CID" tail -n 30 /var/log/ai-services/postgres.log 2>&1 | sed 's/^/     /'
  docker logs "$IT_CID" 2>&1 | grep -iE 'postgres|services' | tail -n 10 | sed 's/^/     /'
  it_finish
fi
[[ "$(q "-h 127.0.0.1 -d postgres -c 'select 1'")" == "1" ]] \
  && pass "psql over 127.0.0.1:5432 answers in restricted mode (loopback needs no allowlist entry)" \
  || fail "psql over 127.0.0.1:5432 did not answer in restricted mode"

# ── 2. Owned by the agent, never root ──────────────────────────────────────────
# From /proc rather than ps: procps is not guaranteed in every variant.
uids="$(docker exec "$IT_CID" bash -c 'for p in /proc/[0-9]*; do
          [ "$(cat "$p/comm" 2>/dev/null)" = postgres ] && awk "/^Uid:/{print \$2}" "$p/status"
        done | sort -u' 2>/dev/null)"
if [[ -z "$uids" ]]; then
  fail "no postgres process found in /proc — assertion 2 verified nothing"
elif [[ "$uids" == "$IT_LAUNCH_UID" ]]; then
  pass "every postgres process runs as the sandbox UID ($IT_LAUNCH_UID), not root"
else
  fail "postgres runs as UID(s) $(tr '\n' ' ' <<<"$uids")— expected only $IT_LAUNCH_UID"
fi

# ── 3. Loopback only ───────────────────────────────────────────────────────────
# /proc/net/tcp{,6}: state 0A is LISTEN; port 5432 is 1538 in hex. 0100007F is
# 127.0.0.1 and the 32-digit form is ::1. Anything else is exposure.
listeners="$(docker exec "$IT_CID" awk 'NR>1 && $4=="0A" && $2 ~ /:1538$/ {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if [[ -z "$listeners" ]]; then
  fail "no listener on port 5432 in /proc/net — assertion 3 verified nothing"
elif exposed="$(grep -vE '^(0100007F|00000000000000000000000001000000):1538$' <<<"$listeners")"; then
  fail "postgres listens beyond loopback: $(tr '\n' ' ' <<<"$exposed")"
else
  pass "port 5432 is bound to loopback only ($(tr '\n' ' ' <<<"$listeners"))"
fi

# ── 4. Provisioning from container.env ─────────────────────────────────────────
[[ "$(q "-d postgres -c \"select rolsuper from pg_roles where rolname='app_user'\"")" == "t" ]] \
  && pass "POSTGRES_ROLES: app_user exists as a superuser" \
  || fail "POSTGRES_ROLES: app_user is missing or not a superuser"
[[ "$(q "-d postgres -c \"select pg_get_userbyid(datdba) from pg_database where datname='myapp_test'\"")" == "app_user" ]] \
  && pass "POSTGRES_DATABASES: myapp_test exists, owned by app_user" \
  || fail "POSTGRES_DATABASES: myapp_test is missing or not owned by app_user"

# ── 5. The app role over TCP, with a password nobody checks ────────────────────
out="$(agent_exec "$IT_CID" "PGPASSWORD=not-checked psql -X -At -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U app_user -d myapp_test \
        -c 'create extension pgcrypto' -c 'create database it_scratch_db' -c 'select 1'" 2>&1)"
[[ "$(tail -n 1 <<<"$out")" == "1" ]] \
  && pass "app_user (any password) creates a contrib extension and a database over TCP" \
  || fail "app_user over TCP: $out"

# ── 6. Collation matches the official postgres image ───────────────────────────
coll="$(q "-d postgres -c \"select datcollate from pg_database where datname='postgres'\"")"
[[ "$coll" == "en_US.UTF-8" ]] \
  && pass "the cluster's collation is en_US.UTF-8" \
  || fail "the cluster's collation is '$coll', not en_US.UTF-8"

# ── 7. The ready line reached the terminal ─────────────────────────────────────
assert_log_contains "$IT_CID" 'postgres [0-9]+\.[0-9]+ ready on localhost:5432'

it_finish
```

- [ ] **Step 3: Create the three mutation patches**

For each, make the edit, capture the diff, prepend the header, revert. Do them one at a time, with a scratch directory for the diffs: `SCRATCH="$(mktemp -d)"`.

**780** — `entrypoint.sh`: in `run_services()`, replace `  [[ -n "${AI_SERVICES:-}" ]] || return 0` with `  return 0`.

```bash
git diff -- entrypoint.sh > "$SCRATCH/780.diff"
git checkout -- entrypoint.sh
{ cat <<'EOF'
# case: 780-postgres-server-runs
# what: run_services returns before doing anything, so the image carries a server
#       and the container never starts it — the state of every container before
#       the entrypoint learned to. Everything else stays truthful: the key, the
#       build arg, the layer and AI_SERVICES are all correct.
#
#       Expected: assertion 1 FAILs on the socket (no server answers) and the
#       case finishes there, printing the empty log path's tail. A FAIL anywhere
#       else first would mean the case is measuring something other than "was
#       the server started".
EOF
  cat "$SCRATCH/780.diff"
} > tests/integration/mutations/780-postgres-not-started.patch
```

**781** — `services.d/postgres.sh`: replace `listen_addresses = 'localhost'` with `listen_addresses = '*'`; same diff/checkout/header procedure into `tests/integration/mutations/781-postgres-listens-everywhere.patch`, header:

```
# case: 780-postgres-server-runs
# what: the server listens on every address instead of loopback only. Everything
#       a test suite would notice still works — that is the point: exposure is
#       invisible to the app, so only assertion 3 can catch it.
#
#       Expected: assertions 1, 2, 4, 5, 6 and 7 PASS; assertion 3 FAILs, naming
#       the 0.0.0.0 (00000000:1538) and :: listeners.
```

**782** — `services.d/postgres.sh`: in `svc_provision()`, insert `  return 0` as the first line of the body (before `  local entry name owner err`); diff into `tests/integration/mutations/782-postgres-roles-not-provisioned.patch`, header:

```
# case: 780-postgres-server-runs
# what: provisioning is skipped: the server starts and answers, but
#       POSTGRES_ROLES and POSTGRES_DATABASES are silently ignored — the failure a
#       project would meet as "role app_user does not exist" from its own suite.
#
#       Expected: assertions 1, 2, 3, 6 and 7 PASS; both halves of assertion 4
#       FAIL, and assertion 5 FAILs (app_user cannot connect).
```

- [ ] **Step 4: Check the patches apply, and the case has its mutations**

Run: `bash tests/run-all.sh test-mutations.sh test-integration-runner.sh && shellcheck -S warning -e SC1091 tests/integration/cases/780-postgres-server-runs.sh`
Expected: PASS (every patch applies with `git apply --check`; case 780 has a mutation); no shellcheck output.

- [ ] **Step 5: Run the case for real (long — run in the background)**

`IT_RUBY_VERSIONS` is the documented cost lever; one Ruby is enough for this case.

```bash
IT_RUBY_VERSIONS=3.4.5 bash tests/integration/run.sh --variant native --cases 780-postgres-server-runs --require packages
```

Expected: `780-postgres-server-runs` PASS with all seven assertion groups green. This builds the native image (several minutes; Ruby compiles on first container start).

- [ ] **Step 6: Demonstrate each mutation failing (long — background)**

```bash
IT_RUBY_VERSIONS=3.4.5 bash tests/integration/demonstrate-needs-rebuild.sh --variant native 780 781 782
```

Expected: each patch reported DEMONSTRATED, failing exactly the assertions its header names. If a patch fails a *different* assertion first, the patch or the case is wrong — fix that, do not edit the header to match.

- [ ] **Step 7: Update the patch counts in `tests/integration/demonstrate-needs-rebuild.sh`**

Run `bash tests/integration/demonstrate-needs-rebuild.sh --dry-run` and update the prose counts in that file's header (`Today that is … patches`, `# all …` in Usage) to the numbers the dry run now lists.

- [ ] **Step 8: Commit**

```bash
git add tests/integration/cases/780-postgres-server-runs.sh tests/integration/mutations/78[0-2]-*.patch \
        tests/integration/run.sh tests/test-integration-runner.sh tests/integration/demonstrate-needs-rebuild.sh
git commit -m "test(postgres): integration case 780 and mutations 780-782

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Falsify the two new scripts and settle the ledger

**Files:**
- Modify: `tests/test-start-services.sh`, `tests/test-postgres.sh` (assertions that kill survivors)
- Modify: `tests/falsify/survivors.txt` (survivors no test could or yet does kill)

- [ ] **Step 1: Score the two targets**

```bash
S="$(mktemp -d)"
bash tests/falsify/run.sh --target start-services.sh --jobs auto > "$S/falsify-runner.txt"
bash tests/falsify/run.sh --target services.d/postgres.sh --jobs auto > "$S/falsify-pg.txt"
grep -hE '^(TARGET|MUTANT\|(SURVIVED|UNPROVEN))\|' "$S"/falsify-*.txt
```

- [ ] **Step 2: Kill what can be killed**

For each `MUTANT|SURVIVED|…` line, read the mutated line it prints. If a reasonable assertion would notice the damage, add that assertion to the oracle test (`test-start-services.sh` for the runner, `test-postgres.sh` for the adapter), confirm it fails against the mutant by hand-applying the damage, revert, and re-run the target. Prefer this to a ledger entry every time.

- [ ] **Step 3: Ledger the rest**

For each remaining survivor, append an entry to `tests/falsify/survivors.txt` in its grammar (column-0 identity from the `MUTANT` record; indented context; a classification with a non-empty reason):

```
<identity from the MUTANT record>
  :<lineno>  <original line>
  the damages:  <mutated line>
  GAP: <why no test kills it today, and what assertion would>
```

Use `EQUIVALENT:` only when *no* test could ever kill it (say why), and `ENV-DEPENDENT:` only per the file's own asymmetry rule. "Nothing currently asserts it" is a `GAP:`.

- [ ] **Step 4: Run the whole corpus and the ratchet, exactly as CI does**

```bash
bash tests/falsify/run.sh --jobs auto --timeout 120 --max-unproven-pct 10 > "$S/falsify-all.txt"
bash tests/falsify/check-ledger.sh --run-output "$S/falsify-all.txt" --ledger tests/falsify/survivors.txt --strict
```

Expected: `check-ledger.sh` exits 0. Then `bash tests/run-all.sh test-falsify-ledger.sh test-falsify-targets.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/test-start-services.sh tests/test-postgres.sh tests/falsify/survivors.txt
git commit -m "test(falsify): score start-services.sh and services.d/postgres.sh; ledger survivors

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Documentation

**Files:**
- Create: `docs/components/postgres.md`
- Modify: `docs/components/README.md`, `docs/components/db-clients.md`, `docs/configuration.md`, `AGENTS.md`, `CHANGELOG.md`

- [ ] **Step 1: Create `docs/components/postgres.md`**

````markdown
# PostgreSQL — a database server for your tests

```bash
postgres=ON    # the newest major PGDG offers at build time (18 as of 2026-10)
postgres=17    # pin a major
postgres=OFF   # default
```

Bakes a PostgreSQL **server** into the image, from [PGDG](https://apt.postgresql.org), and starts a fresh, empty cluster inside every container before your shell appears. It exists so a test suite that needs a real database runs inside the sandbox — with the firewall on, with no database on the host, and with nothing else to start first.

It is not [`db-clients`](db-clients.md): that key installs client libraries and shells only. Compiling a native driver (Ruby `pg`, Python `psycopg2`) still needs `db-clients=pg`; this key brings the server and `psql`.

## Values

- **`ON`** — whatever PGDG's own `postgresql` package depends on when the image is built. PGDG decides what "current" means, not this repo.
- **A major** (`17`) — any major PGDG carries for Ubuntu 24.04 (10–18 as of 2026-10; 10–13 are past upstream end of life, and allowed because an older project's CI may still use one). A minor (`17.2`) is refused by `./build.sh`: PGDG ships only the latest minor of each major.
- **`ON` and `OFF` must be capitals.** `postgres=on` is refused rather than read as a version.

Only PGDG's `main` component is enabled, so a beta can never be installed.

## Why it is baked into the image

`entrypoint.sh` drops root permanently before your shell starts. Nothing inside the container can install a package, so the server is installed at build time or not at all — the same reason [`playwright`](playwright.md) is a build-time key.

## What happens when the container starts

1. `start-services.sh prepare` runs as root and only creates directories for your user.
2. `start-services.sh start` runs **as your user**: `initdb` creates an empty cluster in `/var/lib/ai-services/postgres`, the server starts, and the roles and databases you asked for are created.
3. One line is printed just before the prompt:

```
postgres 18.6 ready on localhost:5432 (socket /var/run/postgresql), superuser alice; roles: app_user; databases: myapp_test
```

| | |
|---|---|
| Listens on | `localhost:5432` and the socket `/var/run/postgresql` — nothing outside the container |
| Superuser | your user, so `psql` with no arguments just works |
| Authentication | `trust`: any password is accepted, so the one in your app's config does not matter |
| Collation | `en_US.UTF-8`, the official `postgres` image's default — `ORDER BY` sorts as it does in CI |
| Durability | off (`fsync`, `synchronous_commit`, `full_page_writes`) — the data is thrown away anyway |
| Log | `/var/log/ai-services/postgres.log` |

**Restricted mode needs nothing.** Loopback is always allowed by the firewall, so there is no allowlist entry to add.

**If it fails to start, you still get your shell**, with a warning naming the log and its last lines.

## Roles and databases

Your user exists as superuser. Anything else goes in the project's `.ai-containers/container.env`, and is created at every start:

```bash
POSTGRES_ROLES=app_user,reporting                  # each created SUPERUSER LOGIN
POSTGRES_DATABASES=myapp_test:app_user,myapp_dev   # name, or name:owner (owner defaults to you)
```

Names must be lowercase letters, digits and `_`. An invalid entry, or a database whose owner is not a role here, is skipped with a warning naming it; the rest are still created. A repeated name is created once.

Most frameworks create their own databases — `bin/rails db:prepare`, Django's test runner, migration tools — so `POSTGRES_ROLES` is often all you need. `POSTGRES_DATABASES` is for apps that expect the database to exist already.

### Connecting

```yaml
# Rails — config/database.yml
test:
  adapter: postgresql
  host: localhost        # or leave host out to use the socket
  username: app_user     # any password works
  database: myapp_test
```

```python
# Django — settings.py
DATABASES = {"default": {"ENGINE": "django.db.backends.postgresql",
                         "HOST": "localhost", "USER": "app_user", "NAME": "myapp"}}
```

```bash
# anything that takes a URL
DATABASE_URL=postgres://app_user@localhost:5432/myapp_test
```

## The data is thrown away

The cluster is created empty on every container start and disappears when the container exits (`sandbox.sh` runs it with `--rm`). This is for tests. Data you want to keep belongs in a database outside the sandbox.

That is also why switching majors needs no migration: there is never old data to upgrade.

## When the image and `sandbox.conf` disagree

Changing `postgres=` without rebuilding starts the server the image **has**, and says so:

```
postgres 16.15 ready on localhost:5432 (socket /var/run/postgresql), superuser alice
WARNING: sandbox.conf asks for postgres=17, this image has 16.15. Rebuild: ./build.sh
```

`./runme.sh` rebuilds before it launches, so this only happens with a bare `./sandbox.sh`. If the key is on and the image has no server at all, the warning says that instead.

## Restarting it

The agent owns the server process, so it can stop and restart it:

```bash
/usr/lib/postgresql/$(cat /etc/ai-containers/postgres-major)/bin/pg_ctl \
  -D /var/lib/ai-services/postgres -l /var/log/ai-services/postgres.log restart
```

## Refreshing

`ON` resolves at build time and Docker caches the layer, so a newer major is not picked up by a plain `./build.sh`. Rebuild with `./build.sh --no-cache`, or pin a major and bump it.

## Cost

About 180 MB of image, 60 MB of RAM while idle, and 2 seconds added to container start (measured with PostgreSQL 16 in a 4 GB container).

---

[← Components](README.md) · [Documentation index](../README.md)
````

- [ ] **Step 2: Link it**

`docs/components/README.md` — in the row added in Task 1, replace `A PostgreSQL server inside the container, for test suites — loopback only, data thrown away on exit` with `[A PostgreSQL server inside the container](postgres.md), for test suites — loopback only, data thrown away on exit`.

`docs/components/db-clients.md` — append before the closing `---` line:

```markdown
> **Need a server, not a client?** [`postgres=`](postgres.md) runs a PostgreSQL server inside the container for your tests.

```

`docs/configuration.md` — in the `SANDBOX_ENV_FILE` row, after `not credentials.` insert ` It is also where [`POSTGRES_ROLES` / `POSTGRES_DATABASES`](components/postgres.md#roles-and-databases) go.`

- [ ] **Step 3: `AGENTS.md`**

(a) In the `Optional components:` line, insert `` `postgres`, `` after `` `playwright`, ``.

(b) In the `db-clients` bullet, after `never a database server, and is language-agnostic.` insert ` (A server is `postgres=`, below.)`

(c) Insert after the paragraph that begins `**`/dev/shm` is the resource that actually bites`:

```markdown
**`postgres=ON | <major> | OFF`** bakes a PGDG PostgreSQL server into the image and
starts a throwaway cluster in every container, as the sandbox user, on loopback
only. `ON` is whatever PGDG's `postgresql` metapackage depends on at build time; a
pinned value is a major (a minor is refused). It is the first server on the shared
runner described under [In-container database servers](#in-container-database-servers);
`POSTGRES_ROLES` / `POSTGRES_DATABASES` in `container.env` provision it. User docs:
`docs/components/postgres.md`.
```

(d) In "Container startup flow", after item 4 (open mode), add:

```markdown
In all three modes `run_services` is the last step before the `capsh` exec, so the
in-container servers' ready lines are the last output before the prompt — see
[In-container database servers](#in-container-database-servers).
```

(e) Insert a new section before `### Mount layout (`/workspace` umbrella) and repo volumes`:

```markdown
### In-container database servers

`start-services.sh` (baked to `/usr/local/bin/`) starts the servers `sandbox.conf`
enabled. `sandbox.sh` passes them as `AI_SERVICES="name=value,…"`
(`sandbox-common.sh`: `services_csv()`), and `entrypoint.sh`'s `run_services`
calls the runner twice: `prepare` as **root**, which only creates each service's
directories and chowns them to the sandbox user, then `start` via `runuser` as the
**sandbox user** — so no server process is ever root. The runner's path is fixed;
there is deliberately no env override, because `container.env` reaches that root
process.

Each server is an **adapter**, `services.d/<name>.sh`, sourced in its own subshell
and required to define five functions:

| Function | Contract |
|---|---|
| `svc_installed_version` | print the installed version, or nothing if this image lacks the server |
| `svc_runtime_dirs` | print extra absolute directories `prepare` must create, one per line |
| `svc_start <datadir> <logfile>` | initialise and start; return 0 once it accepts connections. Its output goes to the log |
| `svc_provision` | create what the adapter's env asks for; warn per bad entry; print the ready-line suffix on stdout |
| `svc_endpoint` | print where to connect |

The runner owns everything else, once: the 60 s watchdog (`AI_SERVICES_TIMEOUT`;
a copy of `tests/portability.sh`'s `p_timeout()` shape, because the image has no
access to that file and macOS has no `timeout(1)`), the ready line, the log tail on
failure, the "image has no such server — rebuild" and "sandbox.conf asks for X,
image has Y" warnings (a **warning, never a refusal**, matching
`ai_containers_provenance_warn()`), and the rule that every path exits 0.

Data is **ephemeral** (`/var/lib/ai-services/<name>` in the container layer, gone
with `--rm`). Do not group-mount it: two concurrent containers in one group would
start two servers on one data directory, and PostgreSQL's `postmaster.pid`
interlock compares PIDs, which are per-namespace.

**Adding a server** is: the key in `sandbox.conf` (+ `validate_config` and a build
arg in `build.sh`), one Dockerfile layer, its name in `services_csv()`, one
adapter, its `docs/components/<name>.md`, a hermetic test with the adapter as a
falsify target, and an integration case with mutations. The runner and the
entrypoint do not change.
```

- [ ] **Step 4: `CHANGELOG.md`**

Under `## Unreleased`, insert:

```markdown
### Added

- **A PostgreSQL server inside the container: `postgres=ON | <major> | OFF`.**
  Test suites that need a real database now run inside the sandbox, in every
  network mode, with nothing on the host and nothing else to start. The key bakes
  the server from PGDG at build time (`ON` is whatever PGDG's `postgresql`
  package depends on — 18 today; a pin is a major, and a minor is refused), and
  every container starts an empty, throwaway cluster as your user on
  `localhost:5432` and `/var/run/postgresql`, before the prompt. Loopback is
  always allowed, so restricted mode needs no allowlist change. `POSTGRES_ROLES`
  and `POSTGRES_DATABASES` in `container.env` create roles (superuser) and
  databases at every start. A server that fails to start leaves you a shell and a
  warning with its log; an image built for another major starts anyway and says
  so. It runs on a new shared runner, `start-services.sh` with one adapter per
  server under `services.d/`, which Redis, MySQL and MongoDB will reuse. See
  `docs/components/postgres.md`.
```

- [ ] **Step 5: Run the doc gates**

Run: `bash tests/run-all.sh test-docs.sh test-code-references.sh test-changelog-section.sh`
Expected: all PASS. Then read `git diff main --stat` and `git diff main -- docs AGENTS.md CHANGELOG.md sandbox.conf` once more for any private project, database, role or host name: this repo is public, and only the generic examples in Global Constraints may appear.

- [ ] **Step 6: Commit**

```bash
git add docs/components/postgres.md docs/components/README.md docs/components/db-clients.md \
        docs/configuration.md AGENTS.md CHANGELOG.md
git commit -m "docs(postgres): component page, AGENTS.md runner section, changelog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Full verification and handoff

- [ ] **Step 1: The hermetic suite, the floor and the lint gate**

```bash
bash tests/run-all.sh
PHASES=5 bash ./verify-on-host.sh
PHASES=7 bash ./verify-on-host.sh
bash ./check-sandbox-version.sh --check
```

Expected: everything PASS / exit 0. (`check-sandbox-version.sh --check` must pass: a new key is an addition.)

- [ ] **Step 2: Re-read the spec against the branch**

Walk `docs/superpowers/specs/2026-10-05-in-container-db-servers-design.md` section by section (Decisions D1–D14, Design, Failure modes, Tests, Documentation) and confirm each is implemented; fix anything missing in its owning file with a test.

- [ ] **Step 3: Finish the branch**

Use superpowers:finishing-a-development-branch.
