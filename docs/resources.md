# Resource limits

By default the container runs with `--cpus=1.0`, `--memory=4g`, `--memory-reservation=2g`, and `--memory-swap=4g`. Override any of them at run time:

```bash
CONTAINER_CPUS=2 CONTAINER_MEMORY=8g ./sandbox.sh restricted /path/to/repo
```

| Env var | Docker flag | Default | Meaning |
|---------|-------------|---------|---------|
| `CONTAINER_CPUS` | `--cpus` | `1.0` | CPU limit (fractional allowed, e.g. `2.5`). |
| `CONTAINER_MEMORY` | `--memory` | `4g` | **Hard** memory limit. The container is OOM-killed if it tries to exceed this. |
| `CONTAINER_MEMORY_RESERVATION` | `--memory-reservation` | `2g` | **Soft** limit. Under host memory pressure Docker tries to keep usage at or below this, but the container may still climb to `CONTAINER_MEMORY`. Must be `<= CONTAINER_MEMORY`. |
| `CONTAINER_MEMORY_SWAP` | `--memory-swap` | `4g` | **Total** memory + swap. Swap available to the container is `CONTAINER_MEMORY_SWAP - CONTAINER_MEMORY`. Must be `>= CONTAINER_MEMORY`, or `-1` for unlimited swap. |
| `CONTAINER_NOFILE` | `--ulimit nofile` | `1048576:1048576` | Open-file-descriptor limit, in `soft[:hard]` form. Raise/keep high if an agent crashes with `EMFILE: too many open files`. |
| `CONTAINER_SHM_SIZE` | `--shm-size` | Docker's `64m`, or `1g` when `playwright` is active | Size of `/dev/shm`. Set explicitly here, this wins for **every** run; left unset, the flag is passed only when `playwright` is active in `sandbox.conf`. |

The values must fit within the resources allocated to your Docker engine. On Colima the VM-level limits are set when starting Colima — for example `colima start --cpu 6 --memory 12 --disk 100`. If `CONTAINER_CPUS` exceeds the VM's CPU count, `docker run` fails with `range of CPUs is from 0.01 to N` and the container does not start. Resize Colima or lower the limit.

**Automatic reconciliation.** Before starting the container, `sandbox.sh` parses the three memory values and fixes inconsistent combinations so `docker run` does not fail mid-launch:

- If `CONTAINER_MEMORY_RESERVATION` is greater than `CONTAINER_MEMORY`, it is lowered to the hard limit and a warning is printed (a soft limit above the hard limit is meaningless).
- If `CONTAINER_MEMORY_SWAP` is less than `CONTAINER_MEMORY`, it is raised to the hard limit (swap disabled) and a warning is printed, because Docker rejects a swap total below the memory limit. This commonly happens when you raise `CONTAINER_MEMORY` (e.g. to `8g`) but leave `CONTAINER_MEMORY_SWAP` at its `4g` default — the reconciliation prevents the otherwise-confusing `Minimum memoryswap limit should be larger than memory limit` error.

A value of `-1` for `CONTAINER_MEMORY_SWAP` (unlimited swap) is left untouched.

**File descriptors vs. memory.** `EMFILE: too many open files` is *not* a memory problem — it means the process hit the open-file-descriptor limit (`ulimit -n`). A container starved of RAM is OOM-killed (exit 137); it does not throw `EMFILE`. On macOS this is also **not** the host's low `launchctl limit maxfiles` (often 256): Docker runs the container inside a Linux VM, so the limit comes from the Docker daemon there, not from the macOS host shell. Agents that scan large repos or doc trees (plus file watchers, where each inotify instance is an fd) can exhaust a low default soft limit. `sandbox.sh` sets `--ulimit nofile` to a high value (`1048576:1048576`) so this does not happen; override with `CONTAINER_NOFILE` if needed. Inside a container, check the active limit with `ulimit -Sn` (soft) and `ulimit -Hn` (hard).

**Shared memory (`/dev/shm`) is sized separately from memory — but still charged to it.** Docker gives every container a 64 MB `/dev/shm` by default, and **`CONTAINER_MEMORY` does not govern its size** — it is a tmpfs sized independently of the memory cgroup, so a container handed 16 GB of RAM still has 64 MB of shared memory. Headless Chromium is the common casualty: it dies with `Target closed` or `Browser closed unexpectedly`, which reads like a browser bug and is really an out-of-shared-memory. `sandbox.sh` therefore passes `--shm-size=1g` automatically whenever `playwright` is active in `sandbox.conf`, and `CONTAINER_SHM_SIZE` overrides that (and works on its own for anything else needing shared memory, such as a database client or a PyTorch dataloader). Containers that ask for neither get exactly the `docker run` they always got.

Two things follow that are easy to get wrong in opposite directions. `CONTAINER_MEMORY` does not *size* `/dev/shm`, so raising it will not fix a Chromium crash — but the pages written into that tmpfs **are** charged to the container's memory cgroup, so `/dev/shm` is not free either: the automatic `1g` can occupy a quarter of the default `CONTAINER_MEMORY=4g` if a browser actually fills it. That is a further reason to raise `CONTAINER_MEMORY` for browser work, and it is why the two settings are worth thinking about together rather than one at a time.

`CONTAINER_SHM_SIZE` is passed to Docker as written and is **not** reconciled the way the three memory values are; a bare number or a nonsense unit fails at `docker run` rather than being corrected. Use Docker's own form: `512m`, `1g`, `2g`.

Note that the sandbox deliberately does **not** use `--ipc=host`, which is what Playwright's own documentation suggests for this problem: that flag shares the *host's* IPC namespace with the container, and `--shm-size` fixes the same failure without spending that isolation. See [Playwright](components/playwright.md).

**Does swap make sense here?** For AI coding agents the answer is usually **no**. Agents and the build tools they invoke (compilers, `npm`/`pip` installs, language servers) are latency-sensitive; if they spill into swap the whole session thrashes and feels frozen, which is worse than a clean OOM. The recommended setup is therefore **no swap** — set `CONTAINER_MEMORY_SWAP` equal to `CONTAINER_MEMORY` so the container is hard-capped and fails fast if it runs out of memory:

```bash
CONTAINER_MEMORY=8g CONTAINER_MEMORY_SWAP=8g ./sandbox.sh restricted /path/to/repo
```

A small amount of swap (e.g. memory `8g`, swap `10g` → 2g of swap) is only worth it if you hit occasional short memory spikes during large builds and would rather absorb a brief slowdown than have the build killed. Unlimited swap (`-1`) is not recommended: it hides genuine memory leaks and can drag the whole host down.

These variables affect `restricted` and `discovery` runs only; the `build` step is unaffected.

> **Note on defaults:** the launcher defaults above (`1.0` CPU / `4g` memory) are the minimum for a single agent doing light work. For comfortable day-to-day use with one of the agents plus a real build toolchain, `CONTAINER_CPUS=4` and `CONTAINER_MEMORY=8g` (with `CONTAINER_MEMORY_SWAP=8g`) is a better starting point. See the per-agent minimums below.

## Minimum CPU and memory per agent

The CLI agents themselves are lightweight Node/Rust processes; the real memory pressure comes from the toolchains and language servers they drive (TypeScript/`tsserver`, JVM builds, bundlers, test runners). The figures below are practical guidance, not vendor-published hard requirements — treat them as floors, not targets.

| Agent | Bare-minimum to launch | Comfortable (agent + typical build) |
|-------|------------------------|-------------------------------------|
| Kiro CLI | 1 CPU / 2g | 2–4 CPU / 6–8g |
| Claude Code | 1 CPU / 2g | 2–4 CPU / 6–8g |
| OpenAI Codex CLI | 1 CPU / 2g | 2–4 CPU / 6–8g |
| GitHub Copilot CLI | 1 CPU / 2g | 2–4 CPU / 6–8g |

Notes:

- **Below ~2g the agent process itself can start, but real work is fragile.** A single agent idling at a prompt fits in ~512m–1g, but as soon as it reads a large repo, runs a build, or starts a language server, 2g is the realistic floor and 4g+ is recommended.
- **Memory, not CPU, is the binding constraint.** All four agents run fine on 1 CPU for the agent loop itself; add CPUs to speed up the compiles/tests they trigger, not the agent.
- **Running multiple agents or heavy toolchains in one container raises the floor.** JVM builds (Maven/Gradle), large Node monorepos, and Rust compiles can each consume several GB on their own — size `CONTAINER_MEMORY` for the heaviest workload you expect, then keep `CONTAINER_MEMORY_SWAP` equal to it.

---

[← Documentation index](README.md)
