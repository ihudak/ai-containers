# macOS hermetic-suite findings — measured 2026-08-11

Measured by Ivan on macOS (darwin25, BSD userland) against
`test/execution-layers-portability` at `cb65f9a`, command:

```bash
bash tests/run-all.sh
```

**Result: 43 test files, 37 passed, 6 failed.** This is the first time the
hermetic suite has ever run on BSD userland — CI is ubuntu-only.

The four GNU-only call sites converted in Task 3 (`stat -c`, `sha1sum`,
`md5sum`) all passed: `test-allowlists.sh`, `test-launcher-migration.sh` and
`test-portability.sh` are green. Those were the *predicted* breakages and the
prediction held. Everything below is a behavioural difference a static scan
could not have found — which is precisely the risk R1 recorded, now realised.

> Note on the transcript: the run reported `exit=0`, but only because the
> command piped through `tee`, so `$?` captured tee's status. `run-all.sh`'s own
> summary says `6 failed` and it exits 1 on that path.

## The six failing files

### 1. `test-parsers.sh` — 5 failures — DIAGNOSED

```
FAIL: resolve_path: absolute existing dir resolves to itself
      (got '/private/var/folders/w9/…/tmp.Bkhcgi7H13/somedir')
FAIL: resolve_path: normalises ./ and trailing slash          (same shape)
FAIL: resolve_path: relative path resolves against cwd        (same shape)
FAIL: resolve_path: symlink resolves to its target            (same shape)
FAIL: real repo has no unexpected working-tree changes
```

**Cause: `/var` is a symlink to `/private/var` on macOS.** `mktemp -d` returns
`/var/folders/…`; `resolve_path` canonicalises it to `/private/var/folders/…`.
The test compares the resolved answer against the unresolved input, so it fails
on any platform where the temp root is itself a symlink. `resolve_path` is
behaving correctly — the *test's expectation* is what assumes a non-symlinked
temp dir.

The fifth failure is probably a consequence of the first four (a fixture left
behind by an aborted assertion), not an independent defect — confirm rather than
assume.

### 2. `test-mutations.sh` — 10 failures — LIKELY SAME ROOT CAUSE

```
error: invalid path '/var/folders/w9/…/tmp.TCHEuuhGrj/mutrepo/target.txt'
```

`git apply` rejects an **absolute** path in a patch. The fixture patch is
generated against a `mktemp -d` tree, and the same `/var` → `/private/var`
divergence makes the generated path absolute (or mismatched) rather than
repo-relative. Every downstream assertion then fails because nothing applied.

### 3. `test-integration-lib.sh` — 8 failures — NEEDS DIAGNOSIS

```
FAIL: launcher_prepare accepts an executable IT_REAL_DOCKER
      (rc=1, out=FAIL: launcher_prepare: cannot resolve the real docker binary [/bin/true])
FAIL: launcher_run's subshell receives a DOCKER_HOST matching the outer resolution (got: '')
FAIL: an unresolvable docker context leaves DOCKER_HOST unexported, not empty (got: '')
FAIL: launcher_script's subshell also receives the resolved DOCKER_HOST (got: '')
FAIL: an already-exported IT_DOCKER_HOST is used as-is (got: '')
FAIL: an already-exported IT_DOCKER_HOST must not trigger a docker subprocess
      (stderr: cat: : No such file or directory)
FAIL: an already-exported EMPTY IT_DOCKER_HOST is honoured, not re-resolved (got: '')
FAIL: an already-exported empty IT_DOCKER_HOST must not trigger a docker subprocess
      (stderr: cat: : No such file or directory)
```

Two distinct symptoms. The first rejects `/bin/true` as a stand-in docker
binary; the rest return an empty `DOCKER_HOST` where a value was expected, and
two report `cat: : No such file or directory` — a variable expanding empty into
a `cat` argument.

**This is the one to treat with suspicion rather than convenience.** These
assertions guard the macOS + Colima docker-context resolution that increment 2
fixed (`b6191da`) — the fix that made launcher-driven cases pass on macOS at
all. A failure *here, on macOS* may be a genuine regression in the thing the
assertions exist to protect, not a test-portability artifact. Do not "fix the
test" until the product behaviour is understood.

### 4. `test-sync-project.sh` — 1 failure — TREAT AS HIGH PRIORITY

```
FAIL: no real registered project directory was modified (fingerprint diff below)
```

This guard exists to prove the suite never writes to the operator's real
projects. Ivan's Mac has real entries in `projects.conf`; the Linux CI box has
none, so this assertion has effectively never been exercised until now.

Two possibilities, and they are not equally acceptable:
- the fingerprint is over-sensitive on BSD (e.g. `p_stat_meta`'s mtime field
  moving for a benign reason), or
- **the suite genuinely modified a real project directory.**

Establish which before touching anything. If it is the second, that is the most
serious defect in this increment and it outranks everything else here.

### 5. `test-tool-config-mounts.sh` — 4 failures — NEEDS DIAGNOSIS

```
FAIL: active tool: config dir mounted from group
FAIL: multi-path: first config dir mounted
FAIL: multi-path: second config dir mounted (space-separated list)
FAIL: host group: mounted from $HOME
```

All four assert that a `-v` mount argument appears in a composed `docker run`
command line. Likely a path-comparison difference (again plausibly the
`/private/var` canonicalisation, since group dirs are built under a temp HOME),
but it must be confirmed, not assumed — a genuinely missing mount would look
identical from this summary.

### 6. `test-rvm-reconcile.sh` — 1 failure — NEEDS DIAGNOSIS

```
FAIL: failed bootstrap must not fall through into not-found errors
```

No detail in the summary. This assertion guards a real shipped defect, so
understand it before altering it.

## Classification required per finding

Per the plan, each finding is one of:

- **portability** — a GNU/BSD divergence in the *test*; fix via
  `tests/portability.sh`, adding a helper rather than open-coding a fallback.
- **real defect** — the test found a genuine bug that Linux hid. Fix the product.
- **environment** — a tool genuinely absent on the host; the test must SKIP
  explicitly (`SKIP:` is a first-class outcome in `run-all.sh`), never silently.

Findings 3, 4 and 6 must NOT be classified as portability by default. Two of
them guard defects that actually shipped once, and finding 4 guards the
operator's real files.

## What this does not tell us

`tests/run-all.sh` only. `verify-on-host.sh`'s Phases 4, 5 and 7 have still
never run on macOS — Phase 7 was red by design until `cb65f9a`, and Phase 4
needs an image build. A green hermetic suite on macOS is a precondition for that
run, not a substitute for it.

---

# Diagnosis after the `-v` run (2026-08-11)

Ivan re-ran the four undiagnosed files with `-v`. Four of the six are now
root-caused; two still need work.

## `test-sync-project.sh` — NOT A DEFECT. Guard is over-broad.

The fingerprint diff names one file:

```
< …/ihudak-claude-plugins/.ai-containers/.agent-discovery/agent-traffic.pcap 6004247243 1786465114
> …/ihudak-claude-plugins/.ai-containers/.agent-discovery/agent-traffic.pcap 6004325250 1786465121
```

Same path, size +78 026 bytes, mtime +7 seconds — **a discovery-mode container
was running on the host and appending to its pcap while the suite ran.** The
suite modified nothing.

Note every other assertion in that file passed, including `real ./projects.conf
md5sum unchanged after the full suite`. Only the recursive directory fingerprint
tripped.

**Classification: portability/robustness of the TEST, not a product defect.** The
guard fingerprints whole real project directories, including `.agent-discovery/`
and `.agent-blocked/` — git-ignored OUTPUT directories that other processes
legitimately write to, by design (`sandbox.sh` bind-mounts them from the launch
directory precisely so they persist host-visibly). The guard exists to prove the
suite never writes a project's *config*; outputs are not that.

**Fix:** exclude the output directories from the fingerprint. Do NOT relax the
comparison itself (e.g. dropping mtime), which would weaken the guard against
the modification it does exist to catch. This has never fired on CI because the
Linux box has no registered projects — the assertion has effectively been inert
there, which is its own finding.

## `test-tool-config-mounts.sh` — 4 failures, near-certainly the `/private/var` symlink

The pattern is diagnostic: for every failing pair, `group config dir created`
PASSES and `config dir mounted` FAILS. So `sandbox.sh` creates the directory and
composes a `-v` argument; the assertion just cannot find the path it expects.

Under a `mktemp -d` HOME on macOS, `sandbox.sh` emits the canonicalised
`/private/var/folders/…` path while the test compares against the `/var/folders/…`
form it built. Same root cause as `test-parsers.sh`.

Confirm before fixing — a genuinely missing mount would look identical in this
summary. Compare the composed `docker run` line against the expected path
directly.

## `test-rvm-reconcile.sh` — 1 failure, still undiagnosed

`FAIL: failed bootstrap must not fall through into not-found errors`, while its
neighbour `failed bootstrap logs 'FAILED: rvm bootstrap'` PASSES. So the failure
IS logged; something additionally emits a not-found error the assertion forbids.
Most likely a BSD/GNU divergence in the stub or in the error text being matched.

This assertion guards a real shipped defect. Understand it before altering it.

## `test-integration-lib.sh` — 8 failures, still undiagnosed, HIGHEST SUSPICION

The `assert_runs` block passes in full. All 8 failures are in `launcher_prepare`
and docker-context resolution:

```
launcher_prepare: cannot resolve the real docker binary [/bin/true]
… DOCKER_HOST matching the outer resolution (got: '')
… an already-exported IT_DOCKER_HOST must not trigger a docker subprocess
  (stderr: cat: : No such file or directory)
```

**This is exactly the code increment 2 fixed in `b6191da`**, and AGENTS.md
records why it matters: `launcher_run`/`launcher_script` redirect `HOME` to a
per-case scratch dir, which discards `$HOME/.docker/config.json`'s
`currentContext` — *"invisible on a host where the daemon sits at the CLI's
built-in default socket (Linux CI), fatal on macOS + Colima."* Before that fix,
all 17 launcher-driven cases failed identically on macOS.

So a failure here, on macOS, is plausibly a **genuine regression in the macOS
docker-context resolution** — the thing these assertions exist to protect — and
not a test-portability artifact. The `cat: : No such file or directory` on stderr
says a variable expanded empty into a `cat` argument, which is a concrete lead.

**Do not classify this as portability by default, and do not "fix the test"
until the product behaviour is understood.** If `launcher_prepare` genuinely
cannot resolve a docker binary on macOS, every launcher-driven integration case
is affected and that outranks everything else in this file.

## `test-integration-lib.sh` — DIAGNOSED. One root cause, eight failures. NOT a regression.

Ivan's host: context `colima`, endpoint
`unix:///Users/ivan.gudak/.colima/default/docker.sock`, Colima running. Docker
context resolution works. So this is not the increment-2 macOS regression it
resembled.

**`tests/test-integration-lib.sh` hardcodes `IT_REAL_DOCKER=/bin/true`** at three
sites — line 260 (the direct assertion), line 426 (`dh_run_launcher`) and line
445 (`dh_run_launcher_preset`). macOS ships `true` at **`/usr/bin/true`**; there
is no `/bin/true`. So `launcher_prepare`'s guard
(`tests/integration/lib.sh`: `[[ -z "$IT_REAL_DOCKER" || ! -x "$IT_REAL_DOCKER" ]]`)
correctly rejects a nonexistent path, and the seven `DOCKER_HOST` assertions all
inherit that failure — the stub never ran, so its witness file was never written,
producing `cat: : No such file or directory`.

**The product code is correct in all eight cases.** `launcher_prepare` is doing
exactly its job; the test asserted a Linux filesystem layout.

**Fix:** do not hunt for the system `true`. The semantic requirement is "a path
that is an executable file", so fabricate one in the test's own scratch dir
(`printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/true-stub"; chmod +x`). That is
portable by construction and states the intent. Note `command -v true` is NOT a
substitute — `true` is a shell builtin, so it returns `true`, not a path;
`type -P true` would work but still depends on the host having one.

`/bin/true` appears nowhere else in `tests/`.

---

# Final classification

| # | File | Failures | Class | Root cause |
|---|---|---|---|---|
| 1 | `test-parsers.sh` | 5 | portability (test) | `/var` → `/private/var` symlink |
| 2 | `test-mutations.sh` | 10 | portability (test) | same, via `git apply` path |
| 3 | `test-integration-lib.sh` | 8 | portability (test) | `/bin/true` absent on macOS |
| 4 | `test-sync-project.sh` | 1 | robustness (test) | guard fingerprints output dirs another process writes |
| 5 | `test-tool-config-mounts.sh` | 4 | portability (test) | `/var` → `/private/var`, in composed `-v` args |
| 6 | `test-rvm-reconcile.sh` | 1 | UNDIAGNOSED | — |

**No product defects among the diagnosed five.** Every one is a test asserting a
Linux-specific fact. That is worth stating plainly: the suite's *product*
coverage held up on a platform it had never run on, and what broke was the
scaffolding's assumptions about its host.

Finding 4 also exposes a second-order fact: that guard has never fired on CI
because the Linux box has no registered projects, so it has been effectively
inert there since it was written.
