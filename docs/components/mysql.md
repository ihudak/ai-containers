# MySQL — a database server for your tests

```bash
mysql=ON    # Ubuntu 24.04's mysql-server (8.0)
mysql=OFF   # default
```

Bakes a MySQL **server** into the image and starts a fresh, empty server inside every container before your shell appears. It exists so a test suite that needs a real MySQL runs inside the sandbox — with the firewall on, with no database on the host, and with nothing else to start first.

It is not [`db-clients`](db-clients.md): that key installs client libraries and shells only. Compiling a native driver (Ruby `mysql2`, Python `mysqlclient`) still needs `db-clients=mysql`; this key brings the server and the `mysql` shell.

## Values

- **`ON`** — Ubuntu's own `mysql-server`, 8.0 on 24.04. Upstream support for 8.0 ended in April 2026; Ubuntu still ships its security fixes.
- **No version can be pinned.** Ubuntu's archive carries one MySQL, so `./build.sh` refuses `mysql=8.4` rather than install 8.0 under another name. MySQL 8.4 is published only in Oracle's own repository, whose client packages replace Ubuntu's — and so would collide with `db-clients=mysql`.
- **`ON` and `OFF` must be capitals.** `mysql=on` is refused rather than read as `OFF`.
- **Not MariaDB.** Its SQL has drifted from MySQL 8's: MariaDB 10.11 (Ubuntu 24.04's) rejects MySQL 8's default collation `utf8mb4_0900_ai_ci` — which a MySQL 8 schema dump or a Rails `schema.rb` carries — the `->>` JSON operator, and `LATERAL` (measured). Test a MySQL app against MySQL; a project whose production runs MariaDB has [`mariadb`](mariadb.md). The two keys cannot both be on.

## Why it is baked into the image

`entrypoint.sh` drops root permanently before your shell starts. Nothing inside the container can install a package, so the server is installed at build time or not at all — the same reason [`postgres`](postgres.md) is a build-time key.

The data directory is built then too. `mysqld --initialize-insecure` takes about 5.6 s, so the image holds an initialised **template**, time zone tables loaded, and every container start copies it (about 50 ms) instead of initialising one.

## What happens when the container starts

1. `start-services.sh prepare` runs as root, with an emptied environment, and creates directories and hands them over to your user. It starts nothing.
2. `start-services.sh start` runs **as your user**: the template is copied to `/var/lib/ai-services/mysql`, `mysqld` starts with every option on its command line (no `my.cnf` is read), an account named after you is created, and then the users and databases you asked for.
3. One line is printed just before the prompt:

```
mysql 8.0.46 ready on localhost:3306 (socket /var/run/mysqld/mysqld.sock), root and alice with no password; users: app_user; databases: myapp_test
```

| | |
|---|---|
| Listens on | `localhost:3306` — `127.0.0.1`, and `::1` where the container has IPv6, because Node 17 and later look up `localhost` as `::1` first — and the socket `/var/run/mysqld/mysqld.sock`. Nothing outside the container. No X Protocol listener (33060) |
| Accounts | `root` and your user, **no password** — a bare `mysql` connects as you, and an app configured for `root` with an empty password (Rails' default) connects too |
| Character set | `utf8mb4` / `utf8mb4_0900_ai_ci`, MySQL 8's defaults — as in the official `mysql` image |
| Time zones | the zone tables are loaded, as the official image loads them, so `CONVERT_TZ(..., 'UTC', 'Europe/Berlin')` works |
| Durability | off (binary log, redo flush, doublewrite) — the data is thrown away anyway |
| `performance_schema` | **off**: 147 MB of RAM idle instead of 376 MB (measured). A test that queries it, or the `sys` schema built on it, will not find it |
| Log | `/var/log/ai-services/mysql.log` |

**Restricted mode needs nothing.** Loopback is always allowed by the firewall, so there is no allowlist entry to add.

**If it fails to start, you still get your shell**, with a warning naming the log and its last lines.

## Users and databases

`root` and your user exist, with every privilege and no password. Anything else goes in the project's `.ai-containers/container.env`, and is created at every start:

```bash
MYSQL_USERS=app_user,reporting:s3cret   # name, or name:password; each gets every privilege
MYSQL_DATABASES=myapp_test,myapp_dev    # names
```

- Names must be lowercase letters, digits and `_`. An invalid entry is skipped with a warning naming it; the rest are still created. A name listed twice, or your own, is skipped quietly.
- A password is everything after the first `:`, spaces inside it included; it cannot contain a comma. It never appears in the ready line.
- `root:<password>` gives root that password — set last, after everything else is created. For an app that insists on one; root then needs it everywhere, and the ready line stops saying root has none.
- A database has no owner in MySQL, and every user here has every privilege, so `MYSQL_DATABASES` takes names only; `name:owner` is skipped with a warning saying so.

The official `mysql` image's `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, `MYSQL_PASSWORD` and `MYSQL_DATABASE` are **not read** — a `container.env` copied from a `docker compose` setup creates nothing through them. Use `MYSQL_USERS` and `MYSQL_DATABASES`. While `mysql=` is `OFF`, the sandbox ignores them.

Most frameworks create their own databases — `bin/rails db:prepare`, Django's test runner, migration tools — so with `root` and no password you may need nothing here at all.

### Connecting

```yaml
# Rails — config/database.yml (its generated default works as is)
test:
  adapter: mysql2      # or trilogy
  host: 127.0.0.1      # or leave host out to use the socket
  username: root
  password:
  database: myapp_test
```

```bash
# anything that takes a URL
DATABASE_URL=mysql2://root@127.0.0.1:3306/myapp_test
```

**Moving from a database on the host?** Remove the old settings from `container.env`. A `DATABASE_URL`, `DB_HOST` or `MYSQL_HOST` still pointing at `host.docker.internal` is read before any default, so the app keeps talking to the old server — or, in restricted mode, to nothing. A `MYSQL_PORT` there does not move this server: it stays on 3306.

## The data is thrown away

The server starts from the same empty template in every container and disappears when the container exits (`sandbox.sh` runs it with `--rm`). This is for tests. Data you want to keep belongs in a database outside the sandbox.

## When the image and `sandbox.conf` disagree

Setting `mysql=ON` without rebuilding leaves the image without a server, and the start says so:

```
WARNING: sandbox.conf has mysql=ON, but this image has no mysql server. Rebuild: ./build.sh
```

`./runme.sh` rebuilds before it launches, so this only happens with a bare `./sandbox.sh`.

## Restarting it

The agent owns the server process, so it can stop it and start a fresh one the way the container did:

```bash
mysqladmin -uroot shutdown
rm -rf /var/lib/ai-services/mysql/* && AI_SERVICES=mysql=ON start-services.sh start
```

From the host, `docker exec` runs as **root** unless told otherwise, and root's client would log in as `root` over the socket, which works too; to be your user, pass your UID:

```bash
docker exec -it -u "$(id -u)" <container> mysql
```

## Cost

About 285 MB of image (its layer, measured with `docker history`: the server ~195 MB and the template ~90 MB), 150 MB of RAM while idle, and under a second added to container start (measured with MySQL 8.0.46).

---

[← Components](README.md) · [Documentation index](../README.md)
