# To test — what a fix could not verify where it was made

A fix is tested where it is written. Some of it can only be checked on another
platform: BSD userland (macOS), the floor container (`ubuntu:22.04`: bash
5.1.16, mawk 1.3.4-20200120 with interval quantifiers disabled, git 2.34), a
Docker host, a root user, or GitHub's own runners. Each fix batch lists here
what it could not run, so whoever has that platform can check it.

How to use this file:

- Each item names the **platform**, the **command**, the **expected result**, and
  the batch and finding it came from.
- When you run one, change its box to `[x]` and add the date, the platform
  (OS, versions), the commit you tested, and what happened. If it failed, say
  how, and log the defect in the bugs review it came from.
- Add new items under your own batch's heading. Don't edit other batches' items
  except to record a result.

## Batch 7 — test harness and CI (2026-10-26)

Made on Ubuntu 24.04 (aarch64) with GNU userland: bash 5.2.21, mawk
1.3.4-20240123, git 2.43, shellcheck 0.9.0. No docker, no root, no BSD tools.
`en_US.UTF-8` was built locally with `localedef` and selected with `LOCPATH`.

### macOS (BSD userland, `verify-on-host.sh` Phase 5)

- [x] **BSD `sed -i` in the nvm workflow test** (TST-8). The test renders the
  workflow's `sed -i "s/…/" Dockerfile` as `sed -i.bak …`, because BSD sed
  treats the word after `-i` as a backup suffix.
  `bash tests/run-all.sh nvm-update-workflow` → PASS (4 assertions).
  - 2026-10-26, macOS 26.7.1 (arm64), bash 5.3.20, BSD awk 20200816 and BSD sed first on PATH, at `3ffc58d`: PASS (4 assertions).
- [x] **The new awk readers under macOS awk** (TST-2, TST-6, GAP-5). These are
  `wf_triggers_on`, `_wf_it_awk` (records separated by `\037`, `match`/`RSTART`)
  and `_wf_job_has_key` in `tests/lib-layer-checks.sh`.
  `bash tests/run-all.sh layer-checks-parser layer-containment` → both PASS.
  - 2026-10-26, macOS 26.7.1 (arm64), bash 5.3.20, BSD awk 20200816 and BSD sed first on PATH, at `3ffc58d`: both PASS (101 and 46 assertions).
- [x] **The awk-interval scan under macOS awk** (GAP-8, TST-5). macOS awk
  supports interval quantifiers itself; this checks the scanner, not the rule.
  `bash tests/run-all.sh bash-dialect-lint` → PASS, and
  `bash tests/bash-dialect-lint.sh` exits 0.
  - 2026-10-26, macOS 26.7.1 (arm64), bash 5.3.20, BSD awk 20200816 and BSD sed first on PATH, at `3ffc58d`: PASS (61 assertions), and the lint exits 0.
- [x] **The other new tests use BSD tools too.** test-minimal-conf.sh uses
  `sed -E` and sources build.sh; test-demonstrate-needs-rebuild.sh uses `cp -R`,
  `git init -b` and an awk `--help` extraction.
  `bash tests/run-all.sh minimal-conf demonstrate-needs-rebuild` → both PASS.
  - 2026-10-26, macOS 26.7.1 (arm64), bash 5.3.20, BSD awk 20200816 and BSD sed first on PATH, at `3ffc58d`: both PASS (29 and 10 assertions).
- [x] **The whole suite under en_US.UTF-8** (TST-1). macOS collates UTF-8
  locales in code-point order, so nothing new is expected; this confirms it.
  `LC_ALL=en_US.UTF-8 bash tests/run-all.sh` → every test PASSes.
  - 2026-10-26, macOS 26.7.1 (arm64), bash 5.3.20, BSD awk 20200816 and BSD sed first on PATH, at `3ffc58d`: 105 tests, 105 passed.

### Floor container (`ubuntu:22.04`, mawk 1.3.4-20200120)

The floor job is red on main for reasons that predate batch 7 (TST-9, TST-10; see "Root" below).
Until that is fixed, run these files on their own:

```
docker run --rm -v "$PWD:/w:ro" -w /w ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq git rsync >/dev/null 2>&1 &&
  git config --global --add safe.directory "*" &&
  ./tests/run-all.sh layer-checks-parser layer-containment bash-dialect-lint \
    minimal-conf nvm-update-workflow demonstrate-needs-rebuild falsify-ledger \
    lint-empty-corpus'
```

- [x] **The new awk code under the floor mawk** (TST-2, TST-6, GAP-5, GAP-8):
  every file in the command above → PASS. The awk code avoids interval
  quantifiers and bracket expressions that open with `[`. This mawk is the
  reason for that, and it was not available where the code was written.
  - 2026-10-26, Docker Desktop 29.9.2 on WSL2 (x86-64), `ubuntu:22.04` (mawk 1.3.4 20200120, bash 5.1.16, git 2.34.1), at `3ffc58d`: all 8 files PASS (101, 46, 61, 29, 4, 10, 88 and 7
    assertions).
  - 2026-10-26, Colima (Docker 29.5.2) on macOS 26.7.1 (arm64), `ubuntu:22.04` (mawk 1.3.4 20200120, bash 5.1.16, git 2.34.1), at `3ffc58d`: all 8 files PASS, the same counts.
- [x] **The TST-5 rows match what bash 5.1.16 rejects.** The review confirmed
  these on ubuntu:22.04; they were not re-checked during the fix.
  `docker run --rm ubuntu:22.04 bash -c 'x=1; echo "${x@k}"'` → `bad substitution`;
  `… bash -c 'shopt -s patsub_replacement'` → `invalid shell option name`;
  `… bash -c 'echo "${|REPLY=x;}"'` → `bad substitution`.
  - 2026-10-26, Docker Desktop 29.9.2 on WSL2 (x86-64), `ubuntu:22.04` (mawk 1.3.4 20200120, bash 5.1.16, git 2.34.1), at `3ffc58d`: all three refused as stated (rc 1 each).
  - 2026-10-26, Colima (Docker 29.5.2) on macOS 26.7.1 (arm64), `ubuntu:22.04` (mawk 1.3.4 20200120, bash 5.1.16, git 2.34.1), at `3ffc58d`: all three refused with the stated messages.

### GitHub Actions (`ubuntu-24.04` runners)

- [x] **The `suite` job under en_US.UTF-8** (TST-1). Its "Run tests" step
  generates the locale if the runner lacks it, and refuses to run if the locale
  sorts like C. In the first `Tests` run after the merge, that step logs no
  `::error::`, and the suite passes there exactly as it does in
  `suite-symlinked-tmp`.
  - 2026-10-26, `Tests` run 40405941031 at `3ffc58d`: the step printed no
    `::error::` and the suite passed, 105 of 105, as `suite-symlinked-tmp` did.
- [x] **integration.yml's split Run step** (TST-2, GAP-5). On a push to main,
  `Run` runs `--tags fast --exclude needs-external,needs-dns --require security`
  and `Run (workflow_dispatch)` is skipped. A manual dispatch
  (`gh workflow run integration.yml -f tags=fast`) runs `Run (workflow_dispatch)`,
  whose log prints `run.sh  --tags fast --exclude needs-external,needs-dns,packages --require security`,
  and skips `Run`.
  - 2026-10-26 at `3ffc58d`: push run 40405940986 ran `Run` and skipped
    `Run (workflow_dispatch)`; dispatch run 40408666668 did the reverse and
    printed exactly that line. Both green.
- [ ] **The nvm bump PR body** (TST-8). The next automated
  `chore: update nvm to …` PR lists only `Dockerfile` under **Changed files**.

### Docker host (Linux, or Colima / Docker Desktop on a Mac)

- [x] **demonstrate-needs-rebuild.sh cleans up every variant's image when
  interrupted** (TST-7). Run `bash tests/integration/demonstrate-needs-rebuild.sh 785`
  (the services variant). Wait until the build has FINISHED and the case is
  running: the tag exists only then, so an interrupt during the build passes
  with the old three-tag cleanup too. Confirm `docker image inspect
  ai-sandbox-it-services` succeeds, press Ctrl-C, and run it again: it must now
  fail ("No such image"). The hermetic test checks this with a stub docker
  only.
  - 2026-10-26, Docker Desktop 29.9.2 on WSL2, at `3ffc58d`, with patch 786
    (case 785, services). SIGINT went to the run's process group while the case
    container ran from `ai-sandbox-it-services`. Afterwards `docker image inspect
    ai-sandbox-it-services` said "No such image", so the cleanup works. But the
    run did not stop: it printed its verdict and summary as if not
    interrupted. That is TST-13, fixed in `494ee11`; the hermetic test now
    checks that an interrupt ends the run.
  - 2026-10-26, Colima (Docker 29.5.2) on macOS 26.7.1, at `3ffc58d`: the same
    finding. With an INT during 786, the run went on to rebuild and run 787 and
    788 and exited 0.
  - 2026-10-27, same host, with this fix applied (the same code as `494ee11`):
    INT during 786, with `ai-sandbox-it-services` present, ended the run with
    exit 130 ten seconds later. No later patch started, `docker image inspect
    ai-sandbox-it-services` then said "No such image", and the tree was clean.

### Root (the CI floor container, `verify-on-host.sh`'s floor container)

- [x] **The hermetic suite as root.** This was NOT fixed by batch 7 — it was
  logged as open items TST-9 and TST-10 in
  `docs/reviews/2026-10-26-bugs-review.md`, and a follow-up fixed both.
  `suite-floor` runs the suite as root and has failed on main since batch 2:
  - 19 launcher tests stop at sandbox.sh's refusal of UID 0 (ENV-4).
  - test-repo-git-reset.sh fails because git 2.34 and 2.43 create an empty
    `.git/branches` in every new clone.

  Once that is fixed, the floor command above, run without a file filter, should
  PASS every test.
  - 2026-10-26, Docker Desktop 29.9.2 on WSL2, `ubuntu:22.04` as root, with the
    follow-up fixes (`bf820bd`, `4cdd310`): the floor command without a filter
    gives 106 tests, 106 passed. At `3ffc58d`, CI's floor job had 20 failures,
    the 19 above plus test-repo-git-reset.sh.
