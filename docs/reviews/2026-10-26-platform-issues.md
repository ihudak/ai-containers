# Platform-specific issues — 2026-10-26

- **Opened:** 2026-10-26, during bug-fix batch 1
- **Last reviewed commit:** `bec1c57` (the review), entries updated while fixing on `fix/batch-1-launcher-git`
- **Companions:** [2026-10-26-bugs-review.md](2026-10-26-bugs-review.md), [2026-10-26-feature-gaps-review.md](2026-10-26-feature-gaps-review.md)

These are issues that can only be confirmed, and then fixed, on a platform or
hardware the review machine does not have (it is Linux x86-64 with a native
Docker Engine). Each one is meant to be picked up by an agent running **on that
platform**: reproduce it first, and only if it reproduces, fix it test-first
like any other bug. If it does not reproduce, record what was run and close it
as not reproducible rather than changing code on a hypothesis — several of
these touch a security check, and a speculative fix would weaken it.

Each entry says what to set up, what to run, what a reproduction looks like,
and the constraints the fix must keep.

| ID | Platform | Source | What |
|---|---|---|---|
| PLAT-1 | Windows + WSL2 + Docker Desktop | bug LNCH-2 | A project under `/mnt/c` may be refused at every launch by the mount-swap check — **not reproducible**, closed |
| PLAT-2 | Windows + WSL2 | gap GAP-13 | The integration corpus and the local layer have never been run on WSL2 |
| PLAT-3 | macOS (Docker Desktop, Colima) | gap GAP-11 | The mount-swap check is skipped there altogether |
| PLAT-4 | x86-64 CPU without AVX | bug SVC-2 | `mongo=ON` reports "no mongo server, rebuild" instead of the real failure |

---

## PLAT-1: WSL2 — a project on `/mnt/<drive>` may be refused at every launch

- **Status: CLOSED — NOT REPRODUCIBLE (2026-10-26).** No code changed. Run on Windows + WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2, Ubuntu distro), Docker Desktop 29.9.2 with WSL integration, image built from `ed6287f`:
  - **Primitive:** the claim's mechanism does not hold. Docker Desktop binds the distro's **own** drvfs mount, not a second mount of `C:` — the container's `/proc/self/mountinfo` shows the bind on `0:70`, the same 9p superblock as the distro's `/mnt/c`. `stat -c '%d:%i'` of a directory under `/mnt/c` is identical on the host and in the container (`70:34621422135717400` both), as it is for ext4 under `~/.ai-containers` (`2096:260327` both).
  - **Step 3** (`/mnt/c/tmp/plat1`, `./sandbox.sh restricted ..`): started. No `ERROR`, and no `does not preserve device/inode` NOTE, so verification ran. The manifest read back from `/run/ai-launcher/manifest` held drvfs entries (`70 43065671436781336 /workspace/plat1/.ai-containers`, the repo's `.git`, `config`, `commondir`, `hooks`) beside ext4 ones (the vault's and specs' `.git` internals, device `2096`); every one matched. Host `stat` of the launcher: `70:43065671436781336`; in the container: the same.
  - **Step 4** (control under `~/plat1-control`): started, every entry on `2096` matched.
  - **The check still bites on drvfs:** a directory renamed away and recreated under `/mnt/c` gets a new inode, and the container sees the new one (`70:44473046320591098` recorded, `70:24206847997423872` after the swap), so a swap there is detected rather than masked.
  - **Not covered:** a native Docker Engine installed inside the distro (the different case named below), and a setup where a launcher source reaches the daemon through a file-sharing layer while `$HOME` does not. LNCH-2's reasoning stays sound for such a host, but none has been seen; reopen with the `expected`/`got` pairs if one is.

- **Platform:** Windows 10/11, WSL2 distro (Ubuntu), Docker Desktop with WSL integration. Not a native Docker Engine installed inside the distro — that one sees drvfs directly and is a different case worth recording too.
- **Source:** bugs review LNCH-2 (MEDIUM, PLAUSIBLE). Deferred from batch 1 by decision: no fix without a reproduction, because every candidate fix weakens the concurrent-swap check.
- **Claim to test:** `entrypoint.sh: verify_launcher_mounts()` checks one anchor — the verify directory under `$HOME/.ai-containers`, on the distro's ext4 — and, if that anchor's `device:inode` survives the bind, requires every manifest entry to match. A launcher overlay whose source is on `/mnt/c` (drvfs) may reach the daemon through Docker Desktop's own file-sharing mount, with a different `st_dev`/`st_ino`. Then the anchor matches, the entries do not, and the launch is refused with `ERROR: a launcher mount changed between the host scan and the mount — refusing to start`.

**Reproduce:**

1. In the WSL2 distro, clone this repo onto ext4 (`~/src/ai-containers`) and build the image: `./build.sh`.
2. Make a project on the Windows drive and initialise it: `mkdir -p /mnt/c/tmp/plat1 && git -C /mnt/c/tmp/plat1 init`, then run `~/src/ai-containers/project-init.sh` and give it `/mnt/c/tmp/plat1` at the prompt (it ignores command-line arguments until bug DOC-3 is fixed). The launcher is generated into `/mnt/c/tmp/plat1/.ai-containers`.
3. Launch from it: `cd /mnt/c/tmp/plat1/.ai-containers && ./sandbox.sh restricted ..`
4. Also launch a control from ext4: a project under `~/plat1-control`, same steps.

**A reproduction looks like:** step 3 prints the `ERROR: … is not the directory it was checked as (expected D:I, got D':I')` lines and refuses; step 4 starts. Record both `expected` and `got` pairs, the output of `stat -c '%d:%i' /mnt/c/tmp/plat1/.ai-containers` on the host, and `docker run --rm -v /mnt/c/tmp/plat1:/x ubuntu stat -c '%d:%i' /x/.ai-containers`.

**Not a reproduction:** the launch prints `NOTE: this filesystem does not preserve device/inode …` and starts (the anchor itself did not survive — the existing skip path), or it verifies and starts.

**Fix constraints, if it reproduces:**
- The check exists to catch a concurrent container swapping an overlay source for a symlink. A rule of the form "this entry's filesystem does not keep inode numbers, so skip it" must not be satisfiable by that swap. In particular, comparing against the *mount root* is only sound when the mount root itself cannot be swapped by a container — i.e. it is not inside another writable mount.
- Keep `/run/ai-launcher/manifest` readable by an older entrypoint: an image not yet rebuilt runs with a newer `sandbox.sh` after a sync. Add information in a second file, never by changing the manifest's record shape.
- Extend `tests/test-launcher-verify.sh` (hermetic) and case `460-launcher-mount-verified`, which today probes one scratch directory only.

## PLAT-2: WSL2 — the corpus and the local layer have never been run

- **Platform:** Windows + WSL2, both Docker Desktop and a native Engine in the distro if available.
- **Source:** feature-gaps review GAP-13 (the increment-3 design records WSL2 as "expected, **never exercised**").
- **Run:** `bash ./verify-on-host.sh` and `./tests/integration/run.sh` from an ext4 checkout, then once more with the checkout under `/mnt/c` (expect the `host-preflight.sh` WSL warning). Note `ALLOW_IPV6_BYPASS` behaviour: AGENTS.md says `ip6tables` may be unavailable under WSL2/nf_tables.
- **Record:** the results in docs/testing.md (which platforms have been exercised), and file each failure as its own bug with the output. PLAT-1's scenario is part of this run.

## PLAT-3: macOS — the mount-swap check is skipped on Docker Desktop and Colima

- **Platform:** macOS, Docker Desktop and Colima (both file-sharing layers: virtiofs / sshfs / 9p).
- **Source:** feature-gaps review GAP-11. This is a missing protection, not a malfunction: AGENTS.md documents the skip and the one-line `NOTE:`.
- **Confirm first:** launch any project and check for `NOTE: this filesystem does not preserve device/inode across a bind mount; launcher mounts are not verified …`. Case 460 asserts which behaviour a host must have; run it (`./tests/integration/run.sh --cases 460-launcher-mount-verified`) and record its verdict.
- **Then design, don't patch:** the suggestion in GAP-11 is a per-launch nonce written into each overlay source and compared from inside the container instead of `device:inode`. Check whether a nonce file survives the file-sharing layer, whether a concurrent container could copy it into a swapped-in directory (it can read the source it is swapping, so a nonce it can read is not a secret — the design must account for that), and what it costs per launch.

## PLAT-4: x86-64 without AVX — mongo reports "no server, rebuild"

- **Platform:** an x86-64 machine or VM whose CPU lacks AVX — e.g. a Proxmox/KVM guest with CPU type `kvm64` or `qemu64`. Check with `grep -c avx /proc/cpuinfo` (0 = no AVX).
- **Source:** bugs review SVC-2 (LOW, PLAUSIBLE). Hardware-specific rather than OS-specific, logged here because it equally cannot be reproduced on the review machine.
- **Reproduce:** `mongo=ON` in `sandbox.conf`, `./build.sh`, launch. A reproduction prints `sandbox.conf has mongo=ON, but this image has no mongo server. Rebuild: ./build.sh` — and the same after a rebuild — while `docker run --rm --entrypoint mongod <image> --version` exits 132 (SIGILL).
- **Fix direction (from SVC-2):** decide "installed" by `[[ -x "$MONGO_MONGOD" ]]` in `services.d/mongo.sh: svc_installed_version()` and report a failing `--version` as a start failure naming the exit status (and AVX), or correct docs/components/mongo.md. The hermetic part can be tested anywhere with a fake `mongod` that exits 132; only the confirmation needs the hardware.
