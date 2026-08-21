# db-clients — database client tools

`db-clients` installs **client-side** tools only — the shells and dev headers needed to
connect to, and compile drivers against, external databases. It never installs a
database *server*, and it is language-agnostic: the same client libraries serve Ruby's
`pg`/`mysql2`, Python's `psycopg2`/`mysqlclient`, Node's `pg`, etc. The value is a
comma-separated subset of `pg`, `mysql`, `mongo`:

```bash
db-clients=pg,mysql,mongo   # any comma-separated subset of: pg, mysql, mongo
db-clients=                 # empty = skip (default)
```

| Value | Installs |
|-------|----------|
| `pg` | `libpq-dev` (client dev headers) + `postgresql-client` (the `psql` shell) |
| `mysql` | `default-libmysqlclient-dev` (client dev headers) + `default-mysql-client` (the `mysql` shell) |
| `mongo` | `mongosh`, installed from MongoDB's own apt repository (not Ubuntu-packaged) |

> **Note:** the list is a **closed set**. An entry outside `pg`/`mysql`/`mongo` (e.g. `db-clients=postgres`) is rejected by `./build.sh` up front with a clear error, instead of silently doing nothing while still enlarging the image via `KEEP_BUILD_TOOLCHAIN=1`.

> **Note:** selecting `mongo` adds `repo.mongodb.org` to the generated domain allowlist automatically (needed to fetch the MongoDB apt repo and the `mongosh` package) — no manual `allowlist-domains.d/custom.txt` edit required.

> **Note — retained runtime build toolchain.** Setting `ruby=` to any version, or `db-clients=` to a non-empty value, makes `build.sh` set `KEEP_BUILD_TOOLCHAIN=1`, which keeps `build-essential`, `libyaml-dev`, `zlib1g-dev`, and `libssl-dev` in the built image instead of stripping them (see [Important notes](../troubleshooting.md)). This lets native extensions — the `pg`/`mysql2` gems, Python source wheels, and similar — compile **at container runtime**, not only at build time.

---

[← Components](README.md) · [Documentation index](../README.md)
