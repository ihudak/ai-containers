# Redis — a server for your tests

```bash
redis=ON    # Ubuntu 24.04's redis-server (7.0)
redis=OFF   # default
```

Bakes a Redis **server** into the image and starts it inside every container before your shell appears. It exists so a test suite or a dev server that expects a Redis (Sidekiq, Action Cable, Celery, BullMQ, a cache) runs inside the sandbox, with the firewall on, with no Redis on the host, and with nothing else to start first.

## Values

- **`ON`**: Ubuntu's own `redis-server`, 7.0 on 24.04. Redis 7.0 is still under the BSD license; later releases changed it.
- **No version can be pinned.** Ubuntu's archive carries one Redis, so `./build.sh` refuses `redis=7.2` rather than install 7.0 under another name.
- **`ON` and `OFF` must be capitals.** `redis=on` is refused rather than read as `OFF`.

## Why it is baked into the image

`entrypoint.sh` drops root permanently before your shell starts. Nothing inside the container can install a package, so the server is installed at build time or not at all. [`postgres`](postgres.md) is a build-time key for the same reason.

## What happens when the container starts

1. `start-services.sh prepare` runs as root, with an emptied environment. It creates the data directory and hands it over to your user. It starts nothing.
2. `start-services.sh start` runs **as your user** and starts `redis-server`. Every option is passed on its command line; the package's `/etc/redis/redis.conf` is not read.
3. One line is printed just before the prompt:

```
redis 7.0.15 ready on redis://localhost:6379
```

| | |
|---|---|
| Listens on | `127.0.0.1:6379` and `[::1]:6379`, nothing outside the container. Both are bound because Node 17 and later look up `localhost` as `::1` first. A container without IPv6 starts on `127.0.0.1` alone |
| Authentication | none |
| Persistence | off: no snapshots (`save ""`) and no append-only file |
| Runs as | your user, never root and never the package's `redis` user |
| Log | `/var/log/ai-services/redis.log` |

Nothing needs configuring. There are no users or databases to create, and the 16 numbered databases exist from the start.

**Restricted mode needs nothing.** The firewall always allows loopback, so there is no allowlist entry to add.

**If it fails to start, you still get your shell**, with a warning naming the log and its last lines.

### Connecting

```bash
# most clients default to this anyway
REDIS_URL=redis://localhost:6379/0
```

```yaml
# Rails — config/cable.yml
test:
  adapter: redis
  url: redis://localhost:6379/1
```

**Moving from a Redis on the host?** Remove the old settings from `container.env`. A `REDIS_URL` or `REDIS_HOST` still pointing at `host.docker.internal` is read before any default, so the app keeps talking to the old server. In restricted mode it reaches nothing at all. A `REDIS_PORT` in `container.env` does not move this server: it stays on 6379.

## The data is thrown away

The server starts empty in every container and disappears when the container exits (`sandbox.sh` runs it with `--rm`). Nothing reaches the disk even while it runs. This is for tests. Data you want to keep belongs in a Redis outside the sandbox.

To start a test run from empty without restarting anything:

```bash
redis-cli flushall
```

## When the image and `sandbox.conf` disagree

Setting `redis=ON` without rebuilding leaves the image without a server, and the start says so:

```
WARNING: sandbox.conf has redis=ON, but this image has no redis server. Rebuild: ./build.sh
```

`./runme.sh` rebuilds before it launches, so this only happens with a bare `./sandbox.sh`.

## Restarting it

The agent owns the server process, so it can stop it and start it again the way the container did:

```bash
redis-cli shutdown nosave
AI_SERVICES=redis=ON start-services.sh start
```

From the host, `docker exec` runs as **root** unless told otherwise. Pass your UID, which is the container user's:

```bash
docker exec -it -u "$(id -u)" <container> redis-cli
```

## Cost

About 7 MB of image and 11 MB of RAM while idle. It adds about 30 ms to container start (measured with Redis 7.0.15).

---

[← Components](README.md) · [Documentation index](../README.md)
