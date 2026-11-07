# Platform-specific issues — 2026-10-26

- **Opened:** 2026-10-26, during bug-fix batch 1
- **Last reviewed commit:** `bec1c57` (the review), entries updated while fixing on `fix/batch-1-launcher-git`; PLAT-5, PLAT-6 and the pickup table added 2026-11-03 at `d41d47a`; PLAT-5 done and PLAT-3 confirmed and designed 2026-11-04 at `f0ad913`; PLAT-2 done 2026-11-04, run at `f0ad913`; PLAT-9 and the WSL native agent added 2026-11-07
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
| PLAT-2 | Windows + WSL2 | gap GAP-13 | The integration corpus and the local layer had never been run on WSL2 — **done**, Docker Desktop and a native Engine, both passed |
| PLAT-3 | macOS (Docker Desktop, Colima) | gap GAP-11 | The mount-swap check is skipped there altogether — **confirmed on Colima, designed**; no code yet |
| PLAT-4 | x86-64 CPU without AVX | bug SVC-2 | `mongo=ON` reports "no mongo server, rebuild" instead of the real failure |
| PLAT-5 | macOS (BSD userland) | bugs PRJ-10, PRJ-11 | The no-follow file writes take their non-Linux branches there, and nobody has run them — **done**, passed (GIT-27 and TST-28 found and fixed) |
| PLAT-7 | macOS without the Command Line Tools | bug GIT-24 | A launch where `/usr/bin/git` is only the installer shim must not run it, and must take the no-git branch — **not run**; git documented as a requirement |
| PLAT-6 | Windows + WSL2 + Docker Desktop | bugs PRJ-10, PRJ-11 | Re-run the hermetic suite at current `main`: the new no-follow tests rename, open `/dev/fd/N` and `noclobber`-create on drvfs — **done**, passed (TST-25 found and fixed) |
| PLAT-8 | macOS (APFS), WSL2 (drvfs), Docker Desktop | bugs GIT-38, GIT-41 | Paths spelled in another case where case is ignored, and whether a read-only bind of one file covers its other spellings — **done**: both halves passed; GIT-41 refused on drvfs, and on macOS reproduced on Colima and mitigated (Docker Desktop for Mac unmeasured) |
| PLAT-9 | macOS, WSL2 (Docker Desktop and a native Engine) | bugs GIT-29 to GIT-45 | The launcher's git checks and `project-files.sh` gained code since the last run on each, which has only ever run on Linux — **open** |

## Who picks up what (updated 2026-11-07)

Three platform agents work on this repository besides the Linux one. Each takes
the rows marked for its platform, starting from the current `origin/main`, and
reports by editing the entry's **Status** line (and docs/testing.md's
"Platforms exercised" table for a run).

| Agent | Its platform | Picks up | Cannot do |
|---|---|---|---|
| **Linux agent** (review machine) | Linux x86-64, native Docker Engine | the falsify work GAP-1 to GAP-4 | anything below |
| **WSL agent** | Windows + WSL2 (Ubuntu distro) + **Docker Desktop** with WSL integration. **Not** a native Docker Engine in the distro | **PLAT-9** (Docker Desktop); PLAT-6, and PLAT-8's drvfs half (GIT-41 there), done | a native Engine's runs: the WSL native agent's |
| **WSL native agent** | Windows + WSL2 (Ubuntu distro) + a **Docker Engine installed natively in the distro** (not Docker Desktop) | **PLAT-9** (native Engine); PLAT-2's native-Engine half done | GIT-41, which is Docker Desktop's |
| **Mac agent** | macOS, Docker Desktop and/or Colima | **PLAT-7** (git documented as a requirement; not run), GIT-41 on Docker Desktop for Mac, **PLAT-9**, **PLAT-3** (GAP-11, designed); PLAT-5 and PLAT-8's APFS half (GIT-41 on Colima) done | — |
| *nobody* | x86-64 CPU without AVX | PLAT-4: closed as not supported | — |

Any change of code an agent makes follows the rule at the top: reproduce
first, then fix test-first.

---

## PLAT-1: WSL2 — a project on `/mnt/<drive>` may be refused at every launch

- **Status: CLOSED — NOT REPRODUCIBLE (2026-10-26).** No code changed. Run on Windows + WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2, Ubuntu distro), Docker Desktop 29.9.2 with WSL integration, image built from `ed6287f`:
  - **Primitive:** the claim's mechanism does not hold. Docker Desktop binds the distro's **own** drvfs mount, not a second mount of `C:` — the container's `/proc/self/mountinfo` shows the bind on `0:70`, the same 9p superblock as the distro's `/mnt/c`. `stat -c '%d:%i'` of a directory under `/mnt/c` is identical on the host and in the container (`70:34621422135717400` both), as it is for ext4 under `~/.ai-containers` (`2096:260327` both).
  - **Step 3** (`/mnt/c/tmp/plat1`, `./sandbox.sh restricted ..`): started. No `ERROR`, and no `does not preserve device/inode` NOTE, so verification ran. The manifest read back from `/run/ai-launcher/manifest` held drvfs entries (`70 43065671436781336 /workspace/plat1/.ai-containers`, the repo's `.git`, `config`, `commondir`, `hooks`) beside ext4 ones (the vault's and specs' `.git` internals, device `2096`); every one matched. Host `stat` of the launcher: `70:43065671436781336`; in the container: the same.
  - **Step 4** (control under `~/plat1-control`): started, every entry on `2096` matched.
  - **The check still bites on drvfs:** a directory renamed away and recreated under `/mnt/c` gets a new inode, and the container sees the new one (`70:44473046320591098` recorded, `70:24206847997423872` after the swap), so a swap there is detected rather than masked.
  - **Native Engine, 2026-11-04 (PLAT-2's run, image built from `f0ad913`):** not reproducible either. A native Engine in the distro sees drvfs directly: the container's mountinfo shows the binds on `0:70`, the distro's own 9p superblock. Step 3 (`/mnt/c/tmp/plat1`, `./sandbox.sh restricted ..`) started with no `ERROR` and no skip `NOTE`. Its manifest held `70 1125899906943491 /workspace/plat1/.ai-containers`, `.git`, `config`, `commondir`, `hooks` and `.agent-blocked`, all on device `70`, and every one matched; the launcher is `70:1125899906943491` on the host and in the container. Step 4 (`~/plat1-control`): started, every entry on `2096` matched. A directory renamed away and recreated under `/mnt/c` got a new inode (`70:1688849860421936`, then `70:1688849860422076`), seen the same in a container, so a swap is detected there too.
  - **Not covered:** a setup where a launcher source reaches the daemon through a file-sharing layer while `$HOME` does not. LNCH-2's reasoning stays sound for such a host, but none has been seen; reopen with the `expected`/`got` pairs if one is.

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

- **Status: DONE (2026-11-04).** Both halves, results in docs/testing.md under "Platforms exercised". No code changed.
  - **Docker Desktop (2026-10-26):** from ext4 and from `/mnt/c`. The one failure that reproduced, G28, was a real bug on every Linux, fixed in #313 and #315. Phase 7 since passed with shellcheck 0.11.0.
  - **Native Engine (2026-11-04, at `f0ad913`):** an Azure Windows VM, WSL2 kernel 6.18.54.1-microsoft-standard-WSL2, Ubuntu 26.04.1 distro with systemd, Docker Engine 29.9.3 from Docker's apt packages (`docker context ls` shows only `default`, on `/var/run/docker.sock`), 2 CPUs and 5.8 GiB. From ext4, `bash ./verify-on-host.sh`, every phase: passed in 9 h 29 min. Phase 4 ran 50/50 with no case skipped, `netadmin` and `launcher` detected. From a fresh clone under `/mnt/c`, Phases 5, 7 and 4: passed in 4 h 16 min, and the drvfs flake did not recur. Nothing failed, so no bug was filed.
  - **`/mnt/c` warning:** `verify-on-host.sh` reaches no `host-preflight.sh` call, so it prints none. A launch from a project on `/mnt/c` did print it (`WARNING: … is on the Windows filesystem (/mnt/c)`).
  - **IPv6:** enforced. A restricted container's `ip6tables -S OUTPUT` is `-P OUTPUT DROP` with the `allowed_ipv6` set and the NFLOG rule, and no launch printed the `ip6tables`-unavailable warning, so `ALLOW_IPV6_BYPASS` is not needed here.
  - **PLAT-1's scenario** ran on this engine as well, and did not reproduce either (see PLAT-1).
  - **Not run:** Phase 6 from `/mnt/c`, with either engine (it took most of the 9.5 h from ext4). The 11 commits merged to `main` while it ran (`f0ad913..cd36db1`, among them the split of test-git-internals-ro.sh and GIT-23 to GIT-28) were not run on WSL2.

- **Picked up by:** the Docker Desktop half was done by the **WSL agent**. The native-Engine half is **the user's** (decided 2026-11-04), on an Azure VM set up for it. The WSL agent runs Docker Desktop only.
- **The VM:** it has to be a Windows VM for WSL2 to run at all, and its size has to support nested virtualization (WSL2 is a Hyper-V VM inside it). A Linux VM would run the corpus on native Linux, which CI already does every day, not on WSL2. Inside the WSL distro, install Docker Engine from Docker's apt repository (not Docker Desktop), with systemd enabled in `/etc/wsl.conf`, and check `docker info` reports no Desktop context.
- **Platform:** Windows + WSL2, both Docker Desktop and a native Engine in the distro if available.
- **Source:** feature-gaps review GAP-13 (the increment-3 design records WSL2 as "expected, **never exercised**").
- **Run:** `bash ./verify-on-host.sh` and `./tests/integration/run.sh` from an ext4 checkout, then once more with the checkout under `/mnt/c` (expect the `host-preflight.sh` WSL warning). Note `ALLOW_IPV6_BYPASS` behaviour: AGENTS.md says `ip6tables` may be unavailable under WSL2/nf_tables.
- **Record:** the results in docs/testing.md (which platforms have been exercised), and file each failure as its own bug with the output. PLAT-1's scenario is part of this run.

## PLAT-3: macOS — the mount-swap check is skipped on Docker Desktop and Colima

- **Status: CONFIRMED ON COLIMA; DESIGNED, NOT IMPLEMENTED (2026-11-04, at `f0ad913`).** macOS 26.7.2 on arm64, Colima 0.10.3 (Virtualization.Framework, virtiofs), Docker 29.5.2. Docker Desktop was not run.
  - **Confirm:** case `460-launcher-mount-verified` PASS (5 assertions): it found a host whose binds do not keep device:inode and saw the skip `NOTE:`. A directory under `$HOME` is `16777233:207971689` on the host and `37:424363` in a container.
  - **The nonce does not work.** The attacker the check exists for can swap the overlay source, so it can read the nonce and copy it into the directory it swaps in. A nonce the container can read proves nothing. A nonce it cannot read cannot be compared from inside either.
  - **The threat is real on Colima.** Colima shares all of `$HOME`. A source swapped for a symlink could make the launch bind any path under it read-only into the container, `~/.ssh` for example.
  - **What does work, on Colima only: the VM's own inode.** `colima ssh -- stat -c '%d:%i' <path>` reports the same device:inode the containers see. It takes about 0.28 s per call, and one call can stat every path. A swap shows as a different inode, and so does a symlink. So `sandbox.sh` could record the VM-side identity of each source in the manifest, and the entrypoint could compare it as it does on Linux.
  - **Limits of that design:**
    - It is Colima-only. Docker Desktop has no equivalent command, and it was not measured.
    - Right after a rename the VM briefly reported a stale inode (virtiofs caching), so a launch right after `git checkout` or a sync could be refused falsely. That needs a retry, or a measured bound.
    - A swap, then a swap back, then a swap again, timed around the two stats, is still possible in principle.
  - **Not done:** no code was changed. GAP-11 stays PARTIAL until the design above is picked up.
- **Picked up by:** the **Mac agent**.
- **Platform:** macOS, Docker Desktop and Colima (both file-sharing layers: virtiofs / sshfs / 9p).
- **Source:** feature-gaps review GAP-11. This is a missing protection, not a malfunction: AGENTS.md documents the skip and the one-line `NOTE:`.
- **Confirm first:** launch any project and check for `NOTE: this filesystem does not preserve device/inode across a bind mount; launcher mounts are not verified …`. Case 460 asserts which behaviour a host must have; run it (`./tests/integration/run.sh --cases 460-launcher-mount-verified`) and record its verdict.
- **Then design, don't patch:** the suggestion in GAP-11 is a per-launch nonce written into each overlay source and compared from inside the container instead of `device:inode`. Check whether a nonce file survives the file-sharing layer, whether a concurrent container could copy it into a swapped-in directory (it can read the source it is swapping, so a nonce it can read is not a secret — the design must account for that), and what it costs per launch.

## PLAT-4: x86-64 without AVX — mongo reports "no server, rebuild"

- **Status: CLOSED — NOT SUPPORTED (2026-11-03).** `mongo=` on an x86-64 CPU without AVX is not officially supported, and docs/components/mongo.md says so: no one working on this project has such a machine, and every MongoDB since 5.0 needs AVX anyway. The hermetic fix stays (batch 5, `657cb29`). What follows is what a run on such a host should show, kept in case one turns up. On a non-AVX host the fixed image should print `WARNING: mongo failed to start — log: …` with `mongod cannot run here: --version ended with exit 132 (SIGILL) — … need a CPU with AVX on x86-64` in the log tail, and no "Rebuild". Seeing that closes PLAT-4; seeing "no mongo server. Rebuild" on an image built from `657cb29` or later reopens SVC-2.

- **Picked up by:** no agent has this hardware. (An Apple Silicon Mac does not help: its containers are arm64, where AVX does not apply.)
- **Platform:** an x86-64 machine or VM whose CPU lacks AVX — e.g. a Proxmox/KVM guest with CPU type `kvm64` or `qemu64`. Check with `grep -c avx /proc/cpuinfo` (0 = no AVX).
- **Source:** bugs review SVC-2 (LOW, PLAUSIBLE). Hardware-specific rather than OS-specific, logged here because it equally cannot be reproduced on the review machine.
- **Reproduce:** `mongo=ON` in `sandbox.conf`, `./build.sh`, launch. A reproduction prints `sandbox.conf has mongo=ON, but this image has no mongo server. Rebuild: ./build.sh` — and the same after a rebuild — while `docker run --rm --entrypoint mongod <image> --version` exits 132 (SIGILL).
- **Fix direction (from SVC-2):** decide "installed" by `[[ -x "$MONGO_MONGOD" ]]` in `services.d/mongo.sh: svc_installed_version()` and report a failing `--version` as a start failure naming the exit status (and AVX), or correct docs/components/mongo.md. The hermetic part can be tested anywhere with a fake `mongod` that exits 132; only the confirmation needs the hardware.

## PLAT-5: macOS — the no-follow writes of sync, init and migrate have never run on BSD userland

- **Status: DONE (2026-11-04, at `f0ad913`).** macOS 26.7.2 on arm64, Homebrew bash 5.3.20. `rsync --version`: `openrsync: protocol version 29`.
  - **The focused run passed:** `test-sync-no-follow` 25, `test-init-no-follow` 49, `test-sync-project` 79, `test-project-init` 23, `test-migrate-runme` 47 assertions. Every BSD branch of project-files.sh (`mv -h -f`, `chmod` and `ls -lnL` through fdescfs `/dev/fd`, openrsync into the copy) behaves as on Linux.
  - **The first whole Phase 5 failed**, and none of the failures were in the no-follow code:
    - On the host, four test bugs, filed as bugs review TST-28 and fixed: BSD `paste -s` without `-`, no `flock` on macOS (two tests), and APFS refusing a name that is not UTF-8.
    - At the floor (`ubuntu:22.04` on Colima), one product bug: G93 did not report a re-made repository, because overlayfs reused the inode within the same second. Filed as GIT-27 and fixed test-first: the birth time is now kept to the nanosecond.
  - **With the fixes, Phase 5 passed:** 118/118 on the host, at the floor and with a symlinked `TMPDIR`, in 94 min.
- **Picked up by:** the **Mac agent**.
- **Platform:** macOS (any Docker; these tests are hermetic and need none), with the system `bash` replaced by a bash ≥ 5.1 (Homebrew), as for Phase 5.
- **Source:** bugs review PRJ-10 and PRJ-11 (both FIXED on Linux). project-files.sh has branches that only a non-GNU system takes, and they were written without running them:
  - `project-files.sh: _proj_replace()` tries GNU `mv -T -f` and falls back to BSD `mv -h -f` (replace a link at the destination rather than move into the directory it points at).
  - `_proj_write()` sets the mode with `chmod … "/dev/fd/$w"`. Where chmod cannot work through `/dev/fd`, it re-checks the name and chmods the path.
  - `_proj_read()` reads the mode with `ls -lnL "/dev/fd/$fd"`. macOS's `/dev/fd` is fdescfs, not Linux's `/proc` links.
  - The fragment directories are copied with `rsync` into the copy (no trailing slash). macOS 15 and later ship **openrsync**, whose handling of a destination that is a link is untested.
- **Run:** `bash tests/run-all.sh test-sync-no-follow.sh test-init-no-follow.sh test-sync-project.sh test-project-init.sh test-migrate-runme.sh`, then the whole of Phase 5 (`PHASES=5 bash ./verify-on-host.sh`). Record `rsync --version`'s first line, and the result in docs/testing.md.
- **A defect looks like:** a `FAIL:` line in those tests. In particular, a planted link that is written through, a launcher that loses its `+x`, or a `sandbox.local.env` backup with a mode other than the original's.
- **Fix constraints, if one reproduces:** never fall back to writing through a name. A branch that cannot do the check safely must refuse the write with the `ERROR:` the Linux path prints, not skip the check.

## PLAT-7: macOS — a launch where `/usr/bin/git` is the Command Line Tools shim

- **Status: OPEN** (2026-11-07). Not run: the Mac agent's machine has the Command Line Tools, and the user chose not to remove them. What the project needs from them was checked instead, at `15682eb`. On the host it needs git and nothing else they provide: no host script runs `make`, `cc` or `python3`; every host call of git asks `_git_usable()` or `_ver_git_runs()` first, or is project-files.sh's, which does too; `repo.sh`'s `git clone` runs in the seed container. Homebrew, which the documented macOS setup uses for bash 5, installs the Command Line Tools itself. So docs/getting-started.md now lists git as a requirement, from the Command Line Tools or Homebrew, and says what a launch skips without it. A Mac without them stays unmeasured.
- **Picked up by:** the **Mac agent**.
- **Platform:** macOS with the Command Line Tools removed (`sudo rm -rf /Library/Developer/CommandLineTools`, or a fresh user account on a Mac that never had them), no other git on `PATH`, any Docker.
- **Source:** bugs review GIT-24, and GIT-28 for `--version`. `sandbox.sh: _git_usable()` decides whether git runs for a launch. When `command -v git` is `/usr/bin/git` on Darwin and the directory `xcode-select -p` names holds no executable `usr/bin/git`, it counts git as absent without running it, because running the shim opens the installer. Otherwise it runs the shim once, and one that fails counts as absent too. `version.sh: _ver_git_runs()` makes the same decision for `--version` and for the version `project-init.sh` and `sync-to-projects.sh` record, without running git at all. Both were written without running them. Those two scripts also read the project's git index, through git, to keep `/.ai-containers/` in its `.gitignore`; since GIT-29's fix (2026-11-06) they ask `_ver_git_runs()` first and run git in no repository of the project's.
- **Run:** since GIT-25 and GIT-26 (2026-11-04), nothing on the way to a launch runs git unasked: `./build.sh` reads the commit for the image label as files, and the pointer check asks `_git_usable()` first. So run it the way a user would. In a project's `.ai-containers/`: `./runme.sh`, then `./sandbox.sh open ..` with `VAULT_PATH` set to a git checkout and `REPOS` holding a repo `./repo.sh add` seeded from a git URL (the pointer check reads git config only then). In the engine checkout: `./sandbox.sh --version`. Make the project with `./project-init.sh …` in a git repository, and sync it with `./sync-to-projects.sh <that project>`: both ask `_ver_git_runs()` before the `.gitignore` step and before the version they record. Do it all twice: on a Mac that never had the Command Line Tools, and after removing them. Record `xcode-select -p`'s output and exit status in both.
- **Expected:** no installer dialog at any step. Each launch prints one `WARNING: git is not installed on this host, is older than 2.18, or does not run, so …`. `.git/config.worktree` is made in the project's repository. `--version` in the engine checkout reports the engine release as `unknown`, and init and sync record none: the project's `.ai-containers/` gets no `engine-version`, so `--version` there says `unknown` too. Init and sync add no `/.ai-containers/` line and print a `NOTE:` that git does not run on this host, unless the project's `.gitignore`, its `.git/info/exclude` or `~/.config/git/ignore` already names the copy, in which case they print nothing.
- **A defect looks like:** the installer dialog opening (the shim was run), or no WARNING (git was taken as present). Also record whether `xcode-select -p` fails with Xcode.app installed but no Command Line Tools: then `/usr/bin/git` works, and taking it as absent would only cost the checks git makes.
- **Fix constraints, if one reproduces:** a git that cannot be shown to run counts as absent; never fall back to a parser.

## PLAT-8: macOS and WSL — paths spelled in another case on a filesystem that ignores case

- **Status: DONE** (2026-11-07): the drvfs half by the WSL agent, the APFS half on macOS.
  - **drvfs (WSL):**
    - **Host:** Windows + WSL2 (kernel 6.18.33.2-microsoft-standard-WSL2, Ubuntu distro), Docker Desktop 29.9.2. `TMPDIR` under `/mnt/d` (drvfs, `9p`, `aname=drvfs`, `stat -f` type `v9fs`).
    - **getcwd:** a defect. In a directory where Windows ignores case, `mkdir Proj; cd proj; /bin/pwd -P; cd ../PROJ; /bin/pwd -P` printed `…/proj`, then `…/PROJ`. All three spellings are one file (`-ef`, one device:inode).
    - **Test, ignoring case, at `15682eb`:** the first line said `NOTE: TMPDIR ignores case here; the cases run in it`. 11 failures, every G117 check that resolves a path written in another case.
    - **Test, case-sensitive directory** (`fsutil.exe file setCaseSensitiveInfo … enable`, which worked without elevation): `SKIP: no casefold tmpfs here`. The WSL kernel is 6.18 but has no `CONFIG_UNICODE`, so `mount -t tmpfs -o casefold` fails.
    - **GIT-41:** measured with `alpine:3.20` containers binding a drvfs directory as the launcher does, not through `./sandbox.sh`. It reproduces, and wider than modelled:
      - `.git/CONFIG` wrote the host's `.git/config`. A `mv` of it renamed the real file away.
      - `.git/HOOKS/post-commit` wrote into the read-only `hooks/`.
      - `sandbox.sh` through `.AI-CONTAINERS` wrote the launcher, past its read-only overlay.
      - `.GIT/config` wrote through a read-only bind of the whole `.git`.
      - A pinned directory was renamed through another spelling.
      - In a case-sensitive directory every other spelling was `nonexistent`, or a new file the host's git ignores, and the host's config was untouched.
      - From a container, `setfattr -n system.wsl_case_sensitive` is `Not supported`, so the agent cannot make a directory ignore case.
    - **Fixed** by GIT-41 and the drvfs part of GIT-38 (bugs review section 25). G121 in `tests/test-git-internals-ro-casefold.sh` runs where `TMPDIR` is on such a filesystem: 5 checks red before the fix, 0 failures after.

  - **APFS (macOS),** at `15682eb`, macOS 26.7.2 arm64, Homebrew bash 5.3.20:
    - `tests/test-git-internals-ro-casefold.sh` said `NOTE: TMPDIR ignores case here; the cases run in it`, then 21 `PASS: G117` and `0 failure(s)`.
    - `mkdir Proj; cd proj; /bin/pwd -P; cd ../PROJ; /bin/pwd -P` printed `…/Proj` both times, and so did Homebrew's GNU `gpwd -P`: macOS's `getcwd` spells a directory one way. Bash's builtin `pwd -P` prints the spelling it was reached by (`proJ`); `_disk_spell()` runs the external one (`type -P pwd`), which is why it holds.
    - **GIT-41** on Colima 0.10.3 (virtiofs) instead of Docker Desktop, which this Mac does not have: it **reproduced**. `.git/CONFIG`, `.git/Config.Worktree`, `.git/COMMONDIR` and a worktree's `.GIT` were written past their read-only binds; `config`, `hooks/` and `.git` under every spelling held. Mitigated by putting the files back when the container exits (bugs review GIT-41). Docker Desktop on macOS is still unmeasured.
- **Picked up by:** the **Mac agent** (APFS) and the **WSL agent** (drvfs).
- **Platform:** macOS with its default case-insensitive APFS. WSL2 with a directory under `/mnt/<drive>`.
- **Source:** bugs review GIT-38, fixed and measured on Linux only, and GIT-41, modelled only. `sandbox.sh: _disk_spell()` respells, from `getcwd` (an external `pwd -P`), each path that crosses a directory ignoring case, so every path compared with a mount is spelled one way. On Linux that holds because a directory has one dentry. Whether macOS's `getcwd` and WSL's drvfs spell a directory one way, however it was reached, has not been measured. GIT-41: Docker Desktop's file sharing may open `.git/CONFIG` as the host's `.git/config`, past the read-only bind of `config`.
- **Run:**
  - Mac: `bash tests/test-git-internals-ro-casefold.sh` at current `main`. `TMPDIR` is on APFS, so the cases run there directly.
  - WSL: `TMPDIR=/mnt/c/<a directory of yours> bash tests/test-git-internals-ro-casefold.sh`. Then the same with `TMPDIR` in a directory made case-sensitive (`fsutil.exe file setCaseSensitiveInfo <dir> enable`); there it should say `SKIP:`, or, on a kernel of 6.13 or later, run the cases on its own casefold tmpfs, which its first line says.
  - Both: the test's first line says which way it ran (`NOTE: TMPDIR ignores case here`); record it. Record the output of `cd <dir>; mkdir Proj; cd proj; /bin/pwd -P; cd ../PROJ; /bin/pwd -P` in that place.
  - GIT-41, both, on Docker Desktop: `./sandbox.sh restricted <a git checkout>`, then in the container `printf '[core]\n\tfsmonitor = touch /tmp/x\n' >> .git/CONFIG`. Exit, and on the host run `git config --file <checkout>/.git/config --get core.fsmonitor`.
- **Expected:** every `G117` line a `PASS`, and `0 failure(s)`. Both `pwd` lines print `Proj`. GIT-41: the write in the container fails (`Read-only file system`), and the host's config has no `core.fsmonitor`.
- **A defect looks like:** a `FAIL: G117 …`, or `pwd` printing the spelling it was reached by. Then `getcwd` does not spell a directory one way there, and "inside this mount" has to compare directories by identity (`[[ a -ef b ]]` on each ancestor), not by prefix. GIT-41: the write going through, and `touch /tmp/x` in the host's config.

## PLAT-9: macOS and WSL2 — re-run the hermetic suite at current `main`

- **Status: OPEN** (2026-11-07).
- **Picked up by:** the **Mac agent**, the **WSL agent** (Docker Desktop) and the **WSL native agent** (a native Engine), each on its platform.
- **Platform:** macOS with its BSD userland and APFS; Windows + WSL2 from ext4 and from `/mnt/c`, with each engine.
- **Source:** bugs GIT-29 to GIT-45. The last runs were PLAT-5 (Mac, `f0ad913`), PLAT-6 (WSL with Docker Desktop, `037e64c`) and PLAT-2 (WSL with a native Engine, `f0ad913`). Since then the launcher's git checks gained code that has only run on Linux:
  - **GIT-29** (`project-files.sh`): the project's `.gitignore` decided without running git in it;
  - **GIT-38**: paths respelled from `getcwd` where a directory ignores case (`_ci_path()`, `_disk_spell()`, an external `pwd -P`);
  - **GIT-39**: each writable mount's files with a second hard link listed with `find … -type f -links +1 -exec stat -f '%d %i' {} +` on BSD, `head -c`, `wc -c` (padded on BSD) and `grep -l -x -F`; the test reads `ps -o comm=`, which macOS prints as a path;
  - **GIT-35** and **GIT-44**: `core.hooksPath` walked, and the repositories that `git worktree add`, `git init --separate-git-dir` and a mount inside a repository make, judged outside every mount too.
- **Run:** at the `origin/main` of the day, from a clean clone:
  - Mac: `bash tests/run-all.sh` under Homebrew bash 5, or `PHASES=5 bash ./verify-on-host.sh`. Record `bash --version`, `git --version`, and which `find`, `stat` and `ps` are first on `PATH`.
  - WSL (each engine): from the ext4 checkout, `PHASES=5 bash ./verify-on-host.sh`; then the same from a clone under `/mnt/c`.
  - Watch above all: `tests/test-git-internals-ro-config.sh` (G114, G120, G122), `tests/test-git-internals-ro-reads.sh` (G112, G119), `tests/test-git-internals-ro-index.sh`, `tests/test-git-internals-ro-casefold.sh`, `tests/test-project-init.sh` and `tests/test-sync-project.sh`.
- **Expected:** `0 failure(s)` everywhere. The casefold test prints `SKIP:` where `TMPDIR` is case-sensitive and no case-folding filesystem can be made.
- **A defect looks like:** a `FAIL:` in those files. Re-run that file alone, and find whether the launcher or the test assumes GNU behaviour (`stat -c`, `find -printf`, `ps -o comm=` printing a bare name, `head -c` on a pipe). A launcher defect is a GIT- bug, a test-only one a TST- bug, each filed with its output, then fixed test-first, per the rule at the top.
- **Record:** one row per run in docs/testing.md's "Platforms exercised", with the commit.

## PLAT-6: WSL2 + Docker Desktop — re-run the hermetic suite at current `main`

- **Status: DONE** (2026-11-03, at `037e64c`; both runs are in docs/testing.md's "Platforms exercised"). The no-follow writes pass on drvfs and on ext4: `tests/test-sync-no-follow.sh` and `tests/test-init-no-follow.sh` passed on the host and with a symlinked `TMPDIR` from `/mnt/c`, and the drvfs flake did not recur. One failure reproduced: `tests/test-init-no-follow.sh` at the floor, from both checkouts. It is a test bug unrelated to WSL, filed as bugs review TST-25 and fixed by `024c9f8`. The full ext4 run with that fix passed every phase.
- **Picked up by:** the **WSL agent**.
- **Platform:** Windows + WSL2 + Docker Desktop, as in PLAT-1/PLAT-2.
- **Why again:** the last WSL run was at `3581af0`. Since then, PRJ-10 and PRJ-11 added tests/test-sync-no-follow.sh and tests/test-init-no-follow.sh, and project-files.sh. Every project file is now written by a `noclobber` create, a rename (`mv -T`), and a mode set through `/dev/fd/N`. drvfs (9p, every file `0777`, no `metadata` option) may treat each of those differently from ext4. The drvfs flake recorded in docs/testing.md came from the same class of operations.
- **Run:** from the ext4 checkout, `bash ./verify-on-host.sh` (every phase, Phase 7 included now that shellcheck is installed). Then Phase 5 again from the `/mnt/c` checkout (`PHASES=5 bash ./verify-on-host.sh`).
- **Record:** one row per run in docs/testing.md's "Platforms exercised", with the commit. File each failure that reproduces on a second run as its own bug, with the output. A failure only on `/mnt/c` that does not repeat goes with the recorded flake, with its file names.

