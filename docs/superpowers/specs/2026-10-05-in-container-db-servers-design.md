# In-container database servers, starting with PostgreSQL

**Status:** draft — awaiting review (2026-10-05)
**Scope of this spec:** a shared service runner plus its first adapter, PostgreSQL
(`postgres=` key). Redis, MySQL and MongoDB are follow-ups that reuse the runner,
one PR each; they are sketched under [Follow-ups](#follow-ups) only to show the
runner's contract holds for them.

## The problem

A test suite that needs a real database server cannot run inside an ai-container
today. `db-clients=pg` installs `libpq-dev` + `postgresql-client` — enough to
compile a driver, never a server, by design. The only way to get a server is to
run one *outside* the container (a host install, or a sibling `docker compose`
container publishing its port) and point the app at `host.docker.internal`.
That works, and it has three costs:

1. **It only works with the firewall off.** In `restricted` mode
   `host.docker.internal` resolves to the host gateway, which is not allowlisted.
   Allowlisting it exposes every port anything on the host publishes, not one
   database.
2. **It shares state.** The agent's test runs hit the same cluster as whatever
   else uses it, typically the developer's dev data, with credentials that can
   drop it. Two containers running a suite at once clobber one fixed test
   database.
3. **It is a second thing to start.** Tests pass only while the other stack is up.

Putting the agent container *into* a compose file does not help: `docker compose
run` can give a TTY, but only by re-stating everything `sandbox.sh` puts on its
`docker run` line (group mounts, capability drops, firewall mode, UID/GID,
`--add-host`, `/dev/shm`, `REPOS`/`EXTRA_MOUNTS`). That is a second launcher that
drifts from the first.

## Goals

- `postgres=ON` (or a pinned major) plus a rebuild gives every container a running
  PostgreSQL server on `localhost:5432`, started before the shell prompt appears,
  in all three network modes, with **no** allowlist change.
- A Rails / Django / plain-driver test suite runs against it unchanged, given at
  most two lines in the project's own `container.env`.
- Nothing about the agent's privileges changes: no new root processes, nothing
  published to the host.
- A failure to start never blocks the shell.
- The runner is shared, so the next three servers are one adapter file each.

## Non-goals

- **Persistence / dev data.** The cluster is created empty on every start and
  discarded with the container. Dev data with real content stays wherever it
  lives today.
- **Publishing the port to the host.** The server is for the agent's tests.
- **Supervision.** A server that crashes stays down until the next container
  start (the agent can restart it — it owns the process).
- **Minor-version pinning.** PGDG ships the latest minor of each major; a pin is a
  major.
- Redis, MySQL, MongoDB — follow-ups.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | The server runs **inside** the agent container. | Loopback is already allowed by the restricted firewall (`iptables -A OUTPUT -o lo -j ACCEPT`), so restricted mode works with no allowlist change; nothing is shared; nothing else has to be started. |
| D2 | Installed at **build time**, one `ARG`+`RUN` layer. | `entrypoint.sh` drops root permanently via `capsh --user=` before the shell exists; nothing in the container can `apt-get install`. Same reason `playwright` is a build-time key. |
| D3 | Started by the entrypoint **as the sandbox user** (`runuser`), before the `capsh` exec. | No new root process. `initdb` run as that user makes it the bootstrap superuser, so `psql` with no arguments just works. The agent owns the server and may restart or reconfigure it. |
| D4 | Listens on **`localhost` only**, plus the Debian default socket directory `/var/run/postgresql`. | Nothing reachable from outside the container; libpq's compiled-in default socket path means `psql`, `pg_dump` and a `database.yml` with no `host:` all find it without configuration. |
| D5 | Data is **ephemeral**: `initdb` into the container's own filesystem on every start. | Tests rebuild their schema anyway. A group-mounted data directory would let two concurrent containers in the same group start two postmasters on one directory — the `postmaster.pid` interlock compares PIDs, which are per-namespace, so it cannot be relied on to stop the second one. Throwaway data also means switching majors never needs `pg_upgrade`. |
| D6 | Packages come from **PGDG** (`apt.postgresql.org`), `main` component only. Grammar `ON \| <major> \| OFF`. | Lets a project match its CI's major. PGDG publishes betas in separate components (`19`, `20` today), so enabling `main` alone can never install a beta. |
| D7 | `ON` = **whatever PGDG's `postgresql` metapackage depends on** at build time. | The definition of "current" is PGDG's, not ours — the same principle as `playwright`'s package list being Playwright's. Measured 2026-10-05: `noble-pgdg main` carries majors 10–18; the metapackage depends on 18 (18.6). |
| D8 | Extra roles and databases come from **`POSTGRES_ROLES` / `POSTGRES_DATABASES`** in the project's `container.env`. | `container.env` is already injected into the container (`--env-file`) and is the project's in-container application env. Because data is ephemeral, anything not created automatically would have to be re-created by hand on every start. |
| D9 | `trust` authentication on the socket and on loopback. | The password in a project's DB config is irrelevant; only the role has to exist. The server is unreachable from outside the container, and the agent is its only client. |
| D10 | A config/image **version mismatch is a warning**, never a refusal; the installed server is started. | Consistent with `ai_containers_provenance_warn()` in `sandbox-common.sh` ("A WARNING, never a refusal"). Refusing leaves a shell with no database, which is worse than a database one major off. |
| D11 | **No `/dev/shm` change.** The cluster uses `dynamic_shared_memory_type = mmap`. | Docker's default `/dev/shm` is 64 MB and is not governed by `CONTAINER_MEMORY`. With `mmap`, PostgreSQL never allocates from it, so `sandbox.sh`'s `--shm-size` logic stays playwright-only. The cost (dynamic shared memory backed by files in the data directory) is irrelevant for a throwaway test cluster. |
| D12 | The cluster is created with locale **`en_US.UTF-8`**; the layer installs `locales` and generates it. | The image ships only `C`/`C.utf8`. The official `postgres` image — what CI service containers typically run — defaults to `en_US.utf8`, and collation decides `ORDER BY` on text. A suite green in CI must not go red here on sort order alone. |
| D13 | `postgres=` does **not** imply `db-clients=pg`. | The server package already brings `psql`. `libpq-dev` (and, through `db-clients`, the retained build toolchain) is only needed to compile a native driver; a pure-JS or pure-Go driver needs neither. The keys stay orthogonal. |
| D14 | A shared runner (`start-services.sh`) plus **one adapter per server** (`services.d/<name>.sh`). | Waiting, timeouts, logging, mismatch and failure reporting are written once. Rejected: an inline `run_postgres()` in `entrypoint.sh` (the second server forces a rewrite of tested code); a process supervisor (would replace the PID-1 model, where `capsh` execs the agent's login shell). |

### Measured cost (2026-10-05, Ubuntu 24.04 packages, 4 GB container)

| | Image growth | Idle RSS | Cold `initdb` + start |
|---|---|---|---|
| PostgreSQL 16 | 178 MB | 60 MB | 2.0 s |

(The same run measured MySQL 8.0 at 178 MB / 393 MB / 5.8 s, MongoDB 8.0 at
212 MB / 148 MB / 0.5 s and Redis 7.0 at 7 MB / 10 MB / <0.1 s, for the
follow-ups.)

## Design

### `sandbox.conf`

A new section after "Database clients", headed
`# ── Database servers (in-container, for tests) ──…`, holding `postgres=OFF`
under a comment block that states, in this order:

- **Values.** `ON` — the major PGDG's `postgresql` package depends on at build
  time (18 as of 2026-10); `<major>` — pinned, any major PGDG's `main` carries
  (10–18 as of 2026-10; 10–13 are past upstream end of life); `OFF` — default.
  `ON`/`OFF` must be capitals. A minor (`17.2`) is refused: pin a major.
- **What is installed.** The server, its bundled extensions (`pgcrypto`,
  `tablefunc`, `pg_stat_statements`, …) and `psql`. *Not* `libpq-dev`: compiling
  a native driver is still `db-clients=pg`'s job.
- **What happens at container start.** Started as your user on
  `localhost:5432` and the default socket `/var/run/postgresql`. Your user is the
  superuser; any password is accepted. The cluster is empty on every start and
  discarded on exit — this is for tests, not dev data.
- **Roles and databases.** `POSTGRES_ROLES` / `POSTGRES_DATABASES` in
  `container.env`, with generic examples.
- **Practicalities.** ~180 MB of image; ~60 MB RAM idle; ~2 s added to start.
- **Mismatch.** Changing the value without rebuilding starts the old server
  with a warning; `./runme.sh` rebuilds first, so this only happens with a bare
  `./sandbox.sh`.
- **Refreshing.** Docker caches the layer: `ON` keeps the major it resolved until
  `./build.sh --no-cache`; pin a major for reproducibility.
- Link to `docs/components/postgres.md`.

New key, so no migration hook and no schema-version bump: `sync-to-projects.sh`
appends it to every project's `sandbox.conf`.

### `build.sh`

`validate_config` (alongside the existing `playwright` checks):

| Value | Result |
|---|---|
| empty, `OFF` | off |
| `ON` | build arg `latest` |
| `^[0-9]+$` | build arg verbatim |
| contains `,` | error: single value only |
| `on`, `Off`, … (case-insensitive `on`/`off` that is not exactly `ON`/`OFF`) | error: must be capitals |
| `17.2`, `16.15` | error: pin a major (`17`); PGDG ships the latest minor |
| anything else | error naming the key and the accepted forms |

`build_args_from_config` emits `--build-arg POSTGRES_VERSION=<latest|major>` when
active and nothing otherwise. Because it is a build arg, it enters
`ai_containers_config_digest()` with no further change — which is what makes the
existing host-side "image was NOT built from the build-time settings in
sandbox.conf" warning fire on a changed `postgres=` value.

No allowlist fragment: the download happens at build time, outside the firewall,
and the server needs no network at runtime.

### Dockerfile

One layer, `ARG POSTGRES_VERSION=` + `RUN`, placed where the toolchain cleanup
(`apt-get purge -y --auto-remove build-essential`) cannot remove anything it
installs. When the arg is non-empty it:

1. installs `locales`, generates `en_US.UTF-8`;
2. adds PGDG's signing key and `deb … noble-pgdg main` (curl with the repo's
   standard `--retry 5 --retry-delay 2 --retry-all-errors`);
3. writes `create_main_cluster = false` to
   `/etc/postgresql-common/createcluster.conf` so the package does not create a
   cluster at build time;
4. resolves `latest` to the major PGDG's `postgresql` metapackage depends on;
5. installs `postgresql-<major>` with `--no-install-recommends`; if no such
   package exists, fails the build with a message naming `postgres=` and the
   majors that *are* available;
6. records the resolved major in `/etc/ai-containers/postgres-major` (the
   runner's source of truth for "what this image has");
7. removes apt lists.

`start-services.sh` is copied to `/usr/local/bin/`, `services.d/` to
`/etc/ai-containers/services.d/` — unconditionally, like `tools.d`.

### `sandbox.sh`

One new env var on the `docker run` line:

```
-e AI_SERVICES="$(services_csv)"
```

`services_csv` (in `sandbox-common.sh`, beside `runtime_tools_csv`) emits a
comma-separated `name=value` list of active server keys — for this PR only
`postgres=<ON|major>`, empty when off. Nothing else changes: no `--shm-size`
(D11), no mounts, no ports.

### `entrypoint.sh`

A new `run_services()`, called in all three modes **immediately before the
`capsh` exec** (after `run_agent_skill_install`), so the ready line is the last
thing printed before the prompt. Returns at once when `AI_SERVICES` is empty or
the runner is absent. Two calls, both non-fatal (`|| true`):

```
start-services.sh prepare                            # as root
runuser -u "$sandbox_user" -- start-services.sh start   # as the sandbox user
```

The entrypoint stays service-agnostic. It names no adapter variable:
`runuser -u` passes the container's environment through (verified 2026-10-05 on
`ubuntu:24.04`: `AI_SERVICES` and a `container.env`-style `POSTGRES_ROLES` arrive
intact, with `HOME`/`USER` set for the target user), and `container.env`'s
variables are already in that environment via `--env-file`. Which directories a
service needs is the adapter's business, carried out by the runner's `prepare`
phase.

### `start-services.sh` — the runner

Input: `AI_SERVICES` (`name=value,name=value`), plus each adapter's own env.

For each entry, in order:

1. **Unknown name** (no `services.d/<name>.sh`) → `WARNING: unknown service
   '<name>' — skipped`.
2. **Incomplete adapter** (any of the five functions below undefined after
   sourcing) → `WARNING: services.d/<name>.sh is incomplete — skipped`. Each
   adapter is sourced in its own subshell, so one adapter's functions can never
   stand in for another's.
3. **Not in this image** (`svc_installed_version` prints nothing) →
   `WARNING: sandbox.conf has <name>=<value>, but this image has no <name> server.
   Rebuild: ./build.sh` — skipped.
4. **`prepare`** (root): create `/var/lib/ai-services/<name>`,
   `/var/log/ai-services/` and every directory the adapter lists via
   `svc_runtime_dirs`, owned by `SANDBOX_UID:SANDBOX_GID`.
5. **`start`** (sandbox user): call `svc_start <datadir> <logfile>` and then
   `svc_provision` under one overall timeout per service (60 s default,
   overridable via `AI_SERVICES_TIMEOUT` so tests can shorten it; the postgres
   adapter's own `pg_ctl -t 30` sits inside it); on success print the ready line
   from `svc_endpoint`. If the requested value is a version (anything but `ON`)
   and the installed version neither equals it nor starts with it followed by a
   `.` (`17` matches `17.11`, not `170.1`), append the mismatch warning (D10).
6. **Failure** at any step → `WARNING: <name> failed to start — log:
   /var/log/ai-services/<name>.log`, followed by its last 20 lines. Continue with
   the next service.

The runner **always exits 0**. Output goes to stderr, like the other startup
warnings.

#### Adapter contract (`services.d/<name>.sh`, sourced)

| Function | Phase | Contract |
|---|---|---|
| `svc_installed_version` | both | print the installed version (e.g. `18.6`), or nothing if not installed |
| `svc_runtime_dirs` | prepare | print extra absolute directories to create and hand to the sandbox user, one per line |
| `svc_start <datadir> <logfile>` | start | initialise and start; return 0 only once the server accepts connections |
| `svc_provision` | start | create what the adapter's env asks for; warn per bad entry, never fail the service for one; print the ready-line suffix (`; roles: …`) on stdout |
| `svc_endpoint` | start | print the "where to connect" part of the ready line |

### `services.d/postgres.sh` — the first adapter

- `svc_installed_version`: read `/etc/ai-containers/postgres-major`; print the
  full version from `/usr/lib/postgresql/<major>/bin/postgres --version`.
- `svc_runtime_dirs`: `/var/run/postgresql`.
- `svc_start`:
  - `initdb -D <datadir> -U <sandbox user> --auth=trust --encoding=UTF8
    --locale=en_US.UTF-8`;
  - append to `postgresql.conf`: `listen_addresses = 'localhost'`,
    `port = 5432`, `unix_socket_directories = '/var/run/postgresql'`,
    `fsync = off`, `synchronous_commit = off`, `full_page_writes = off`,
    `dynamic_shared_memory_type = mmap`;
  - `pg_ctl -D <datadir> -l <logfile> -w -t 30 start`.
- `svc_provision`:
  - **`POSTGRES_ROLES`** — comma-separated; surrounding whitespace trimmed
    (including a `\r` from a `container.env` saved with CRLF line endings); a
    repeated name is created once; each
    name must match `^[a-z_][a-z0-9_]*$`, otherwise `WARNING: POSTGRES_ROLES:
    '<entry>' is not a valid role name — skipped`; a name equal to the sandbox
    user is skipped silently (it already exists); each other name →
    `CREATE ROLE "<name>" SUPERUSER LOGIN`.
  - **`POSTGRES_DATABASES`** — comma-separated `name` or `name:owner`, created
    after the roles; both parts must match the same pattern; owner defaults to
    the sandbox user and must exist (the sandbox user or a role from
    `POSTGRES_ROLES`), otherwise a warning naming the entry and a skip; each →
    `CREATE DATABASE "<name>" OWNER "<owner>"`. A repeated name is created once.
  - Identifiers are always double-quoted with embedded `"` doubled, so the
    sandbox user's own name — which comes from the host and is not held to the
    pattern (a macOS `John.Doe` is legal) — is safe as a default owner.
  - Statements go through `psql -v ON_ERROR_STOP=1` over the socket, one per
    entry, so one failure is reported against its own entry.
- `svc_endpoint`: `localhost:5432 (socket /var/run/postgresql), superuser
  <user>` plus `; roles: …` / `; databases: …` when any were created.

Example of the resulting start-up output:

```
postgres 18.6 ready on localhost:5432 (socket /var/run/postgresql), superuser alice; roles: app_user; databases: myapp_test
```

and with a mismatch:

```
postgres 16.15 ready on localhost:5432 (socket /var/run/postgresql), superuser alice
WARNING: sandbox.conf asks for postgres=17, this image has 16.15. Rebuild: ./build.sh
```

### Shipping to projects

- `start-services.sh` joins `AI_CONTAINERS_SHARED_FILES` (`shared-files.sh`).
- `services.d/` is copied by both `project-init.sh` and `sync-to-projects.sh` with
  the same `rsync -a` they use for `tools.d/`; `test-shared-files-parity.sh`
  extends to cover it.

### Failure modes

| Situation | Behaviour |
|---|---|
| `postgres=` changed, no rebuild | host: existing provenance warning; container: old server starts, mismatch warning (D10) |
| key active, image built without it | runner warning naming `./build.sh`; shell starts without a server |
| `initdb` / `pg_ctl` fails, or 30 s timeout | warning + log path + last 20 log lines; shell starts |
| invalid role / database entry, or unknown owner | warning naming the entry; other entries proceed |
| pinned major PGDG does not carry | build fails in the postgres layer, naming the key and the available majors |
| `AI_SERVICES` names a service with no adapter | warning; skipped |

## Tests

Every new assertion is demonstrated failing against deliberate damage before it
is trusted (AGENTS.md: "Every case must have been seen failing").

**Hermetic — `tests/test-postgres.sh`:**

- `validate_config`: every row of the table above, accepted and refused, with the
  refusal text naming the key.
- `build_args_from_config`: `ON` → `POSTGRES_VERSION=latest`; `17` →
  `POSTGRES_VERSION=17`; `OFF` / empty → no arg; the digest changes when the
  value changes.
- `services_csv`: `postgres=ON` / `postgres=17` / off.
- The runner, against fake adapters and fake binaries on `PATH`: unknown service;
  service not installed (rebuild warning, exit 0); mismatch line text; a failed
  `svc_start` prints the log tail and exits 0; one service failing does not stop
  the next; a `svc_start` that hangs is cut off at `AI_SERVICES_TIMEOUT` and
  reported as a failure.
- The postgres adapter's provisioning against a fake `psql` that records its
  statements: valid roles and databases produce the exact `CREATE` statements;
  `x; drop table y`, `Mixed`, an empty entry and an unknown owner are refused with
  warnings; the sandbox user's own name is skipped.

**Hermetic — existing files:** `test-entrypoint-wiring.sh` asserts
`run_services` is defined and wired in all three modes;
`test-shared-files-parity.sh` covers `start-services.sh` and `services.d/`.

**Integration — packages tier:** the `native` variant gains `postgres=ON`. A new
case (`tags: packages slow`, `image: native`) launches in **restricted** mode
with `POSTGRES_ROLES=app_user` and `POSTGRES_DATABASES=myapp_test:app_user` and
asserts, as the agent:

1. `psql -c 'select 1'` succeeds over the default socket and over
   `-h 127.0.0.1`;
2. the server process's UID is the sandbox UID, not 0;
3. it listens on loopback addresses only;
4. `app_user` exists with `rolsuper`, and `myapp_test` exists owned by it;
5. `CREATE DATABASE` and `CREATE EXTENSION pgcrypto` succeed;
6. the cluster's `lc_collate` is `en_US.UTF-8`.

Mutations under `tests/integration/mutations/` prove the case can fail: one makes
`run_services` a no-op, one sets `listen_addresses = '*'`, one drops the role
provisioning. The falsify tier gains rows for `start-services.sh` and
`services.d/postgres.sh`; every survivor is classified in
`tests/falsify/survivors.txt`.

## Documentation

All examples generic (`app_user`, `myapp_test`, `/path/to/project`).

- **`docs/components/postgres.md`** — new, in the shape of `playwright.md`:
  values and what each installs; why it is baked; what happens at start;
  roles and databases; connection recipes (Rails `database.yml` / `DATABASE_URL`,
  Django `DATABASES`, a plain `postgres://app_user@localhost/myapp_test` URL);
  the mismatch warning; refreshing; size and memory; limits (ephemeral, not for
  dev data, not published, not supervised); restricted-mode note (no allowlist
  change).
- `docs/components/README.md` — entry.
- `docs/configuration.md` — row for `postgres=`; `POSTGRES_ROLES` /
  `POSTGRES_DATABASES` documented as `container.env` variables.
- `docs/components/db-clients.md` — "need a server? see postgres.md".
- `AGENTS.md` — `postgres` in the optional-components list; a section on
  in-container servers (the runner, the adapter contract, D3/D5/D10) so the next
  adapters follow it; the `db-clients` "never a database server" sentence stays
  true and gains a pointer.
- `sandbox.conf` — the comment block above.
- `CHANGELOG.md` — `Unreleased` entry.

## Follow-ups

Each is one adapter plus its key, docs page, tests and integration assertions;
the runner does not change.

- **`redis=`** — Ubuntu's `redis-server`; `--bind 127.0.0.1 --save '' --appendonly
  no`; no provisioning.
- **`mysql=`** — `svc_start` runs `mysqld --initialize-insecure` (≈6 s of the
  start-up on every launch, measured); `MYSQL_USERS` / `MYSQL_DATABASES` mirror
  the postgres variables.
- **`mongo=`** — MongoDB's repo (already used by `db-clients=mongo`); cap
  `--wiredTigerCacheSizeGB 0.25`, because its default is 50 % of (memory limit −
  1 GB) — measured `cache_size=1536M` in a 4 GB container.
