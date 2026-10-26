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

- [ ] **BSD `sed -i` in the nvm workflow test** (TST-8). The test renders the
  workflow's `sed -i "s/…/" Dockerfile` as `sed -i.bak …`, because BSD sed
  treats the word after `-i` as a backup suffix.
  `bash tests/run-all.sh nvm-update-workflow` → PASS (4 assertions).
- [ ] **The new awk readers under macOS awk** (TST-2, TST-6, GAP-5). These are
  `wf_triggers_on`, `_wf_it_awk` (records separated by `\037`, `match`/`RSTART`)
  and `_wf_job_has_key` in `tests/lib-layer-checks.sh`.
  `bash tests/run-all.sh layer-checks-parser layer-containment` → both PASS.
- [ ] **The awk-interval scan under macOS awk** (GAP-8, TST-5). macOS awk
  supports interval quantifiers itself; this checks the scanner, not the rule.
  `bash tests/run-all.sh bash-dialect-lint` → PASS, and
  `bash tests/bash-dialect-lint.sh` exits 0.
- [ ] **The other new tests use BSD tools too.** test-minimal-conf.sh uses
  `sed -E` and sources build.sh; test-demonstrate-needs-rebuild.sh uses `cp -R`,
  `git init -b` and an awk `--help` extraction.
  `bash tests/run-all.sh minimal-conf demonstrate-needs-rebuild` → both PASS.
- [ ] **The whole suite under en_US.UTF-8** (TST-1). macOS collates UTF-8
  locales in code-point order, so nothing new is expected; this confirms it.
  `LC_ALL=en_US.UTF-8 bash tests/run-all.sh` → every test PASSes.

### Floor container (`ubuntu:22.04`, mawk 1.3.4-20200120)

The floor job is red on main for reasons that predate batch 7 (see "Root" below).
Until that is fixed, run these files on their own:

```
docker run --rm -v "$PWD:/w:ro" -w /w ubuntu:22.04 bash -c '
  apt-get update -qq && apt-get install -y -qq git rsync >/dev/null 2>&1 &&
  git config --global --add safe.directory "*" &&
  ./tests/run-all.sh layer-checks-parser layer-containment bash-dialect-lint \
    minimal-conf nvm-update-workflow demonstrate-needs-rebuild falsify-ledger \
    lint-empty-corpus'
```

- [ ] **The new awk code under the floor mawk** (TST-2, TST-6, GAP-5, GAP-8):
  every file in the command above → PASS. The awk code avoids interval
  quantifiers and bracket expressions that open with `[`. This mawk is the
  reason for that, and it was not available where the code was written.
- [ ] **The TST-5 rows match what bash 5.1.16 rejects.** The review confirmed
  these on ubuntu:22.04; they were not re-checked during the fix.
  `docker run --rm ubuntu:22.04 bash -c 'x=1; echo "${x@k}"'` → `bad substitution`;
  `… bash -c 'shopt -s patsub_replacement'` → `invalid shell option name`;
  `… bash -c 'echo "${|REPLY=x;}"'` → `bad substitution`.

### GitHub Actions (`ubuntu-24.04` runners)

- [ ] **The `suite` job under en_US.UTF-8** (TST-1). Its "Run tests" step
  generates the locale if the runner lacks it, and refuses to run if the locale
  sorts like C. In the first `Tests` run after the merge, that step logs no
  `::error::`, and the suite passes there exactly as it does in
  `suite-symlinked-tmp`.
- [ ] **integration.yml's split Run step** (TST-2, GAP-5). On a push to main,
  `Run` runs `--tags fast --exclude needs-external,needs-dns --require security`
  and `Run (workflow_dispatch)` is skipped. A manual dispatch
  (`gh workflow run integration.yml -f tags=fast`) runs `Run (workflow_dispatch)`,
  whose log prints `run.sh  --tags fast --exclude needs-external,needs-dns,packages --require security`,
  and skips `Run`.
- [ ] **The nvm bump PR body** (TST-8). The next automated
  `chore: update nvm to …` PR lists only `Dockerfile` under **Changed files**.

### Docker host (Linux, or Colima / Docker Desktop on a Mac)

- [ ] **demonstrate-needs-rebuild.sh cleans up every variant's image when
  interrupted** (TST-7). Run `bash tests/integration/demonstrate-needs-rebuild.sh 785`
  (the services variant), press Ctrl-C while the image builds, then run
  `docker images --format '{{.Repository}}' | grep '^ai-sandbox-it'`. Expect no
  `ai-sandbox-it-services` left, and none of the other variant tags. The
  hermetic test checks this with a stub docker only.

### Root (the CI floor container, `verify-on-host.sh`'s floor container)

- [ ] **The hermetic suite as root.** This is NOT fixed by batch 7 — it is
  logged as an open item in `docs/reviews/2026-10-26-bugs-review.md`.
  `suite-floor` runs the suite as root and has failed on main since batch 2:
  - 19 launcher tests stop at sandbox.sh's refusal of UID 0 (ENV-4).
  - test-repo-git-reset.sh fails because git 2.34 and 2.43 create an empty
    `.git/branches` in every new clone.

  Once that is fixed, the floor command above, run without a file filter, should
  PASS every test.
