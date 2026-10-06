# MariaDB — a database server for your tests

```bash
mariadb=ON     # Ubuntu 24.04's mariadb-server (10.11)
mariadb=11.4   # pin a series, from MariaDB's own repository
mariadb=OFF    # default
```

Bakes a MariaDB **server** into the image and starts a fresh, empty server inside every container before your shell appears — for projects whose **production runs MariaDB**, so their test suite runs against the engine it will meet there, inside the sandbox, with the firewall on and nothing on the host.

**A MySQL app tests against [`mysql`](mysql.md), not this.** MariaDB's SQL has drifted from MySQL 8's: MariaDB 10.11 rejects MySQL 8's default collation `utf8mb4_0900_ai_ci` (what a MySQL 8 dump or a Rails `schema.rb` carries), the `->>` JSON operator and `LATERAL` (measured). A suite green on one says little about the other.

**Not together with `mysql=`.** Both serve `localhost:3306` and `/var/run/mysqld/mysqld.sock`, and their packages conflict, so `./build.sh` refuses both on.

## Values

- **`ON`** — Ubuntu's own `mariadb-server`, 10.11 (a long-term series, supported to 2028), with no third-party repository.
- **A series** (`11.4`) — any series MariaDB publishes for Ubuntu 24.04, from [its own repository](https://mariadb.org/download/): the long-term 10.11, 11.4, 11.8 and 12.3 as of 2026-10. The build installs the newest release of that series, from that series only, and fails, naming the series, if MariaDB does not publish it for this Ubuntu.
- **Not a release.** `mariadb=11.4.5` is refused with `mariadb=11.4` to pin instead: the repository installs the newest of its series.
- **`ON` and `OFF` must be capitals.**

## Why it is baked into the image

`entrypoint.sh` drops root permanently before your shell starts, so the server is installed at build time or not at all. The data directory is built then too — a **template**, root with no password and the time zone tables loaded, which every container start copies.

## What happens when the container starts

As for [MySQL](mysql.md#what-happens-when-the-container-starts): the template is copied to `/var/lib/ai-services/mariadb`, `mariadbd` starts **as your user** with every option on its command line, an account named after you is created, then the users and databases you asked for, and one line is printed before the prompt:

```
mariadb 11.4.13 ready on localhost:3306 (socket /var/run/mysqld/mysqld.sock), root and alice with no password; users: app_user; databases: myapp_test
```

| | |
|---|---|
| Listens on | `localhost:3306` — `127.0.0.1`, and `::1` where the container has IPv6 — and the socket `/var/run/mysqld/mysqld.sock`. Nothing outside the container |
| Accounts | `root` and your user, **no password** — a bare `mariadb` (or `mysql`) connects as you, and an app configured for `root` with an empty password connects too |
| Character set | **the package's own**: `utf8mb4` / `utf8mb4_general_ci` on Ubuntu's 10.11, `utf8mb4` / `utf8mb4_uca1400_ai_ci` on MariaDB's 11.4 — what the official `mariadb` image of the same series serves. (Started with no configuration at all, 10.11 would serve `latin1`; the server is given back the package's own character-set options and nothing else of its configuration) |
| Time zones | the zone tables are loaded, so `CONVERT_TZ(..., 'UTC', 'Europe/Berlin')` works |
| Durability | off (binary log, redo flush, doublewrite) — the data is thrown away anyway |
| Log | `/var/log/ai-services/mariadb.log` |

**Restricted mode needs nothing.** Loopback is always allowed by the firewall.

**If it fails to start, you still get your shell**, with a warning naming the log and its last lines.

## Users and databases

Exactly as for MySQL, and with the same variables — a project can switch engines without renaming them:

```bash
MYSQL_USERS=app_user,reporting:s3cret   # name, or name:password; each gets every privilege
MYSQL_DATABASES=myapp_test,myapp_dev    # names
```

The rules — valid names, passwords, `root:<password>`, no database owners — are under [Users and databases](mysql.md#users-and-databases) on the MySQL page. The official `mariadb` image's `MARIADB_*` / `MYSQL_ROOT_PASSWORD` variables are **not read**.

### Connecting

The same as [MySQL](mysql.md#connecting): `mysql2` and `trilogy`, Django's MySQL backend and every MySQL driver speak to MariaDB unchanged.

**A warning you can ignore.** MariaDB 11.4 and later's command-line client verifies the server's certificate by default, and on a TCP login with no password it cannot, so it says `WARNING: option --ssl-verify-server-cert is disabled, because of an insecure passwordless login.` and connects anyway. The socket (no `-h`) never prints it.

**With `db-clients=mysql`,** apt replaces MySQL's client with MariaDB's when the image is built, so `mysql` runs MariaDB's client (measured; on a pinned series through `mariadb-client-compat`). `libmysqlclient-dev` stays, so a native driver still compiles.

## The data is thrown away

The server starts from the same empty template in every container and disappears when the container exits. This is for tests.

## When the image and `sandbox.conf` disagree

Changing `mariadb=` without rebuilding starts the server the image **has**, and a pin it does not match says so:

```
WARNING: sandbox.conf asks for mariadb=10.11, this image has 11.4.13. Rebuild: ./build.sh
```

## Restarting it

```bash
mariadb-admin -uroot shutdown
rm -rf /var/lib/ai-services/mariadb/* && AI_SERVICES=mariadb=ON start-services.sh start
```

## Refreshing

A series resolves to its newest release at build time and Docker caches the layer, so a newer release is not picked up by a plain `./build.sh`. Rebuild with `./build.sh --no-cache`.

## Cost

About 295 MB of image either way — Ubuntu's 10.11 adds a 296 MB layer, MariaDB's 11.4 a 287 MB one (measured with `docker history`), each including its ~30–60 MB template — about 125 MB of RAM while idle, and well under a second added to container start with 10.11 (about 1.5 s with 11.4).

---

[← Components](README.md) · [Documentation index](../README.md)
