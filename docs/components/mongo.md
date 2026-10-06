# MongoDB — a server for your tests

```bash
mongo=ON     # the 8.0 series, from MongoDB's own repository
mongo=8.2    # pin a release series
mongo=OFF    # default
```

Bakes a MongoDB **server** — `mongod`, and the `mongosh` shell — into the image and starts it inside every container before your shell appears. It exists so a test suite that needs a real MongoDB runs inside the sandbox — with the firewall on, with no database on the host, and with nothing else to start first.

It is not [`db-clients`](db-clients.md)`=mongo`: that installs `mongosh` only. This key brings the server and the shell; with both on, `mongosh` is installed once.

## Values

- **`ON`** — the 8.0 series: MongoDB's current major, and the series `db-clients=mongo` installs `mongosh` from. Not "the newest series": MongoDB's later series on the same major (8.2, 8.3) are supported for less time.
- **A release series** (`8.2`) — any series MongoDB publishes for Ubuntu 24.04: 8.0, 8.2 and 8.3 as of 2026-10, and none before 8.0. The build installs the newest release of that series, from that series only, and fails, naming the series, if MongoDB does not publish it for this Ubuntu.
- **Not a release, not a bare major.** `mongo=8.0.32` is refused with `mongo=8.0` to pin instead — the repository installs the newest of its series — and `mongo=8` with `mongo=8.0`.
- **`ON` and `OFF` must be capitals.**
- **x86-64 needs AVX.** Every MongoDB since 5.0 does; a CPU or an emulator without it stops `mongod` with `Illegal instruction`, and the start says it failed, with the log. Apple silicon runs the arm64 build and is unaffected.

## Why it is baked into the image

`entrypoint.sh` drops root permanently before your shell starts. Nothing inside the container can install a package, so the server is installed at build time or not at all — the same reason [`postgres`](postgres.md) is a build-time key.

## What happens when the container starts

1. `start-services.sh prepare` runs as root, with an emptied environment, and creates directories and hands them over to your user. It starts nothing.
2. `start-services.sh start` runs **as your user** and starts `mongod` with every option on its command line (`/etc/mongod.conf` is not read). `--fork` returns once it accepts connections.
3. One line is printed just before the prompt:

```
mongo 8.0.32 ready on mongodb://localhost:27017
```

| | |
|---|---|
| Listens on | `127.0.0.1:27017`, and `[::1]:27017` where the container has IPv6, because Node 17 and later look up `localhost` as `::1` first — nothing outside the container. Its socket is `/tmp/mongodb-27017.sock`, readable by you alone |
| Authentication | none |
| Cache | WiredTiger's cache is capped at **0.25 GB**. Its default is half of (memory − 1 GB): 1.5 GB of a 4 GB container, for a server that holds test fixtures. Set `AI_SERVICES_MONGO_CACHE_GB=1` in `container.env` to raise it |
| Runs as | your user, never root and never the package's `mongodb` user |
| Log | `/var/log/ai-services/mongo.log` (MongoDB's structured JSON) |

Nothing needs configuring. A database and a collection exist once something writes to them, so there is nothing to create.

**Restricted mode needs nothing.** Loopback is always allowed by the firewall, so there is no allowlist entry to add.

**If it fails to start, you still get your shell**, with a warning naming the log and its last lines.

### Connecting

```bash
# most clients take a URL
MONGODB_URI=mongodb://localhost:27017/myapp_test
```

```yaml
# Rails with Mongoid — config/mongoid.yml
test:
  clients:
    default:
      uri: mongodb://localhost:27017/myapp_test
```

**Moving from a MongoDB on the host?** Remove the old settings from `container.env`. A `MONGODB_URI` or `MONGO_URL` still pointing at `host.docker.internal` is read before any default, so the app keeps talking to the old server — or, in restricted mode, to nothing. A `MONGO_PORT` there does not move this server: it stays on 27017.

## The data is thrown away

The server starts empty in every container and disappears when the container exits (`sandbox.sh` runs it with `--rm`). This is for tests. Data you want to keep belongs in a database outside the sandbox.

To start a test run from empty without restarting anything:

```bash
mongosh --quiet --eval 'db.getMongo().getDBNames().filter(n => !["admin","config","local"].includes(n)).forEach(n => db.getSiblingDB(n).dropDatabase())'
```

## When the image and `sandbox.conf` disagree

Changing `mongo=` without rebuilding starts the server the image **has**, and says so:

```
mongo 8.0.32 ready on mongodb://localhost:27017
WARNING: sandbox.conf asks for mongo=8.2, this image has 8.0.32. Rebuild: ./build.sh
```

`./runme.sh` rebuilds before it launches, so this only happens with a bare `./sandbox.sh`. If the key is on and the image has no server at all, the warning says that instead.

## Restarting it

The agent owns the server process, so it can stop it and start a fresh one the way the container did:

```bash
mongosh --quiet admin --eval 'db.shutdownServer()'
rm -rf /var/lib/ai-services/mongo/* && AI_SERVICES=mongo=ON start-services.sh start
```

From the host, `docker exec` runs as **root** unless told otherwise; pass your UID to be the container user:

```bash
docker exec -it -u "$(id -u)" <container> mongosh
```

## Refreshing

A series resolves to its newest release at build time and Docker caches the layer, so a newer release is not picked up by a plain `./build.sh`. Rebuild with `./build.sh --no-cache`.

## Cost

About 525 MB of image (its layer, measured with `docker history`) — `mongod` ~215 MB, `mongosh` ~290 MB (none of it if `db-clients=mongo` already brought `mongosh`) — 165 MB of RAM while idle with the cache capped, and under a second added to container start (measured with MongoDB 8.2.12).

---

[← Components](README.md) · [Documentation index](../README.md)
