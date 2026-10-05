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

Only PGDG's `main` component is enabled, so a beta can never be installed. The build also fails closed: if PGDG's package index does not load, it stops rather than quietly installing Ubuntu's own PostgreSQL 16.

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
