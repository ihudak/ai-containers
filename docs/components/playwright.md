# Playwright — browser automation

```bash
playwright=ON       # deps for whatever playwright@latest wants at build time
playwright=1.58.2   # pin the Playwright version whose dep list is used
playwright=OFF      # default
```

Installs the operating-system packages Playwright's browsers link against — `libnss3`, `libgbm1`, `libatk-bridge2.0-0t64`, the font packages, and the rest of the set — by running Playwright's own `install-deps` at image-build time. The package list is Playwright's, not this repo's, so it does not rot against new Playwright releases or Ubuntu package renames.

**Single version only.** `playwright=1.50.0,1.58.2` is rejected by `build.sh` with an error naming the key. One layer runs one `install-deps`.

**`ON` and `OFF` must be capitals.** Every value that is not literally `ON` or `OFF` is read as a version, so `playwright=on` would become `npx playwright@on` and fail at npm with a message naming neither this key nor this file. `build.sh` refuses a lowercase or mixed-case spelling of either word up front. npm dist-tags are still valid versions here — `playwright=next` and `playwright=beta` work, and pin exactly what they say.

## Why it has to be baked into the image

`entrypoint.sh` permanently drops root via `capsh --user=` before the agent shell ever starts. Nothing inside the container can `apt-get install` anything, so the runtime-reconcile pattern that the agent-tier tools and rvm use is not available here. These packages are baked at build time or they are not there at all.

That is also why running `npx playwright install --with-deps` inside the container does **not** work: the `--with-deps` half needs root. Set this key and rebuild instead.

## What is baked, and what is not

| | Where it comes from | Where it lives |
|---|---|---|
| OS libraries and fonts | image build (`install-deps`) | in the image |
| Browser binaries (~500 MB) | `npx playwright install`, at run time | `~/.cache/ms-playwright`, **group-mounted** |

Run `npx playwright install` once inside the container. `sandbox.sh` group-mounts `~/.cache/ms-playwright` — the same treatment `~/.cache/qmd` gets — so the download is paid once per container group rather than once per container start, and survives the container exiting (`sandbox.sh` runs `docker run --rm`).

In `restricted` mode that download needs `cdn.playwright.dev`, which `allowlist-domains.d/playwright.txt` supplies automatically whenever this key is active.

## Resources: `/dev/shm` is the one that bites

**Headless Chromium crashes on Docker's default 64 MB `/dev/shm`, and `CONTAINER_MEMORY` does not fix it.** `/dev/shm` is a tmpfs sized independently of the memory cgroup, so a container given 16 GB of RAM still dies with `Target closed` or `Browser closed unexpectedly` if its shared memory is 64 MB.

When this key is active, `sandbox.sh` passes `--shm-size=1g` automatically. Override it with [`CONTAINER_SHM_SIZE`](../resources.md):

```bash
CONTAINER_SHM_SIZE=2g ./sandbox.sh restricted /path/to/repo
```

Playwright's own documentation reaches for `--ipc=host` here. This project does not: that flag shares the **host's** IPC namespace with the container, which is at odds with the isolation the sandbox exists to provide. `--shm-size` achieves the same result without it.

CPU and memory also matter. The launcher defaults (`1.0` CPU / `4g`) are the minimum for a single agent doing light work, and a browser is not light work — a Playwright suite alongside an agent wants something closer to:

```bash
CONTAINER_CPUS=4 CONTAINER_MEMORY=8g CONTAINER_MEMORY_SWAP=8g ./sandbox.sh restricted /path/to/repo
```

See [Resource limits](../resources.md) for the full set.

## Image size

The deps for all three browser engines add several hundred MB, most of it WebKit's GStreamer and codec set. Off by default for that reason.

## Refreshing

An unpinned `playwright=ON` resolves "latest" **at build time**, and Docker then caches the layer — a later `./build.sh` will not pick up a newer Playwright. Either rebuild with `./build.sh --no-cache`, or pin a version and bump it, which is reproducible and cheaper. This is the same caveat that applies to Kiro and the `tools.d` CLIs.

---

[← Components](README.md) · [Documentation index](../README.md)
