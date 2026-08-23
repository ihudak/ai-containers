# Contributing

This page is for anyone changing this repository — human or agent. It covers the
rules a change has to satisfy, what CI does and does not check, and which tests
to run while you work as opposed to before you open a PR.

`AGENTS.md` in the repository root is the deeper reference: why each layer exists
and what it is guarding. This page is the practical one.

## The rules

1. **Every change ships with a test, and the test is demonstrated failing.** Not
   "a test exists" — you must have watched it go red without your fix and green
   with it, and the PR should say so. An assertion nobody has seen fail is the
   defect this project keeps finding in itself.
2. **The full hermetic suite must be green locally before you open a PR.** CI
   does not run everything (see below), so a green PR check is not the same as a
   green repository.
3. **If your change reads the machine, run it on macOS too.** CI has no macOS
   runner at all. This is not a formality — see [Linux green does not mean macOS
   green](#linux-green-does-not-mean-macos-green).
4. **Port it to the sibling repository.** `ai-containers` and `mgd-ai-containers`
   share an engine; a fix that lands in one and not the other is a fix that half
   your containers do not have.
5. **Leave the checkout clean.** No stray files, no uncommitted edits, and never
   a `sed -i` that quietly drops an exec bit — `tests/test-exec-bits.sh` exists
   because that has happened more than once.

## What CI covers, and what it does not

| Workflow | Trigger | What runs | Runner |
| --- | --- | --- | --- |
| `tests.yml` → `hermetic-checks.yml` | every push and PR | the hermetic suite, the same suite again under the declared bash floor, the falsify mutation tier, and lint | `ubuntu-24.04` |
| `integration.yml` | every push and PR | the integration corpus, but only `--tags fast --exclude needs-external,needs-dns` | `ubuntu-24.04` |
| `nightly.yml` | 03:17 daily | the whole integration corpus, allowlist health, and the `packages-agents` / `packages-native` image tiers | `ubuntu-24.04` |

**Every job runs on `ubuntu-24.04`. There is no macOS runner in any workflow.**
So the three things CI structurally cannot tell you are:

- **anything macOS-specific** — BSD userland, Colima, the Docker VM, Apple
  Silicon's core mix, `shasum` instead of `sha256sum`
- **the full integration corpus on a PR** — only the `fast` tag runs before
  merge; everything else waits for the nightly
- **real unrestricted network behaviour** — the nightly's allowlist-health job
  is the closest thing, and it is not on your PR

That is why rule 2 exists. A green PR is necessary and not sufficient.

## The layers, and how to run each

Two of these need a real Docker daemon and two do not. The ones that do not are
the ones you will run constantly.

| Layer | Command | Needs Docker | Roughly |
| --- | --- | --- | --- |
| Hermetic suite | `bash tests/run-all.sh` | no | a few minutes |
| Lint | `bash tests/bash-dialect-lint.sh`, `shellcheck` | no | seconds |
| Falsify mutation tier | `bash tests/falsify/run.sh --jobs auto` | no | ~76s in the container, **~45 min on macOS** |
| Integration corpus | `bash tests/integration/run.sh` | **yes** | tens of minutes; individual cases run 80–100s |

The hermetic suite takes a substring filter and a verbose flag:

```bash
bash tests/run-all.sh              # everything
bash tests/run-all.sh docs         # only tests whose name contains "docs"
bash tests/run-all.sh -v           # stream each test's full output
```

## verify-on-host.sh and its phases

`verify-on-host.sh` is the wrapper that runs the layers that need a real Docker
daemon, plus the ones that do not, in one command. It is **platform-adaptive,
not macOS-only**: the identical command runs on macOS + Colima and on a Linux
workstation with native Docker. There is deliberately no second entry point.

```bash
cd ~/dev/ai-tools/ai-containers            # upstream: engine at the repo root
cd ~/dev/dt-utils/mgd-ai-containers/base   # mgd: engine in base/, tests one up

bash ./verify-on-host.sh 2>&1 | tee ./ai-containers-host-verify.log
```

Note the `base` for the mgd port — the engine lives there, and one copy of the
script serves both layouts.

A later phase still runs if an earlier one failed: a full report beats an early
abort. The script exits non-zero if any selected phase failed, and prints a
`RESULT:` line naming each.

| Phase | What it checks | Docker | Run it when |
| --- | --- | --- | --- |
| **0** | environment banner — versions, Colima state, disk | no | always; it is free and it is what you paste into a bug report |
| **5** | the hermetic suite **and** the same suite under the declared bash floor, plus the `sandbox.conf` schema gate | no | **after every change.** This is the one you run constantly |
| **7** | lint — `bash -n`, the dialect floor, shellcheck | no | after any shell edit |
| **6** | the falsify mutation tier and the survivor-ledger ratchet | no | when you touch a falsify target or one of its oracles. **~45 min on macOS** — see below |
| **4** | the runtime integration corpus | **yes** | when you touch the launcher, the entrypoint, mounts, groups, allowlists or the Dockerfile |

Select phases with `PHASES`:

```bash
PHASES="5 7" bash ./verify-on-host.sh    # the fast pair — no Docker needed
PHASES=6 bash ./verify-on-host.sh        # just the mutation tier
PHASES=4 IT_EXTRA_ARGS='--tags fast' bash ./verify-on-host.sh
FALSIFY_TIMEOUT=300 FALSIFY_JOBS=6 PHASES=6 bash ./verify-on-host.sh
```

`IT_EXTRA_ARGS` is forwarded verbatim to the integration runner in Phase 4.

### While you work, and before the PR

**While you work:** `PHASES="5 7"`, or just `bash tests/run-all.sh` for the
tightest loop. Add Phase 6 if you are editing a falsify target, Phase 4 if you
are editing the launcher or the image.

**Before you open the PR:** the whole thing, `bash ./verify-on-host.sh` with no
`PHASES`, on a host with Docker. That is the run that covers what CI will not.

> **It takes a while, and it has not hung.** On macOS budget **an hour or more**
> for a full run — Phase 6 alone is around 45 minutes there, and Phase 4 builds
> and starts real containers. Phase 6 says so on screen before it starts. The
> tier forks constantly and macOS is slow at that; a quiet terminal is the
> normal state, not a stall. Start it and go and do something else. Killing it
> part-way costs you the whole phase, and the phases do not resume.

## Linux green does not mean macOS green

An assertion that **reads** the host cannot pin behaviour that **depends on**
the host. Verifying inside the container proves nothing about the Mac, and CI
never runs on one.

This is not hypothetical. On 2026-08-22 a fix that caps the mutation tier's
worker count at the machine's performance-core count shipped after a full green
in-container run, and was **red on `main` in both repositories from the moment
it merged**: a test pinned the worker count against what the OS reports, and on
Apple Silicon the OS reports 18 while the budget is 6. Linux has no performance
levels, so the cap never binds and the assertion never fires there.

The fix is not "remember to test on the Mac" — it is:

- **Stub the host inside the assertion.** Fake `sysctl`, `nproc`, `uname`, the
  digest tool. An assertion that fixes the topology is right on every machine;
  one that reads it is only right on the machine it was written on.
- **Then also run it on a host**, because stubbing is the fix and a host run is
  the detector.

### Timing, and where to run what

Measured on one Apple Silicon machine, the same 264-mutant corpus:

| Where | Wall clock |
| --- | --- |
| inside the Linux dev container (Colima), `--jobs auto` → 8 | **~76 seconds** |
| on macOS natively, `--jobs auto` → 6 | **~45 minutes** |

Same physical hardware — 35x. The tier is bound by process creation, and macOS
is dramatically slower at it. Two things follow:

- **Run the non-Docker layers inside the container** where they are fast, and
  use the host only for what genuinely needs it: Phase 4, and a confirming run
  of whatever is platform-sensitive.
- **When you do run Phase 6 on the host, expect the wait.** Forty-five minutes
  of near-silence is what a healthy run looks like there. It is not hung.

## Reading a falsify result

Phase 6 prints pipe-delimited records. The two that matter:

```
TOTAL|9|264|262|2|0|0|0|76185
      │ │   │   │ │ │ │ └─ milliseconds
      │ │   │   │ │ │ └─── unresolved %
      │ │   │   │ │ └───── timeouts
      │ │   │   │ └─────── unproven      ← must be 0
      │ │   │   └───────── survived      ← must match the ledger
      │ │   └───────────── killed
      │ └───────────────── mutants
      └─────────────────── targets
CONTROLS|18|0
          │  └─ failed    ← must be 0
          └──── control runs
```

- **A failed control means the kill count cannot be trusted.** A control is the
  *unmutated* code run under the same load; if it goes red, mutants scored
  KILLED near it may have been killed by the machine rather than by the damage.
  Re-run with fewer `--jobs` before believing anything.
- **`unproven` above zero means mutants left the measured set** without owing
  the ledger an entry. The tier measured less than it appears to.
- **Survivors must match `tests/falsify/survivors.txt`.** The ratchet
  (`tests/falsify/check-ledger.sh`) enforces it; a new survivor with no entry
  fails the run.
- Verdicts can legitimately differ by platform. `ENV-DEPENDENT` is the ledger's
  classification for that, and there is currently one such entry.

## Cutting a release

Push the tag. That is the whole procedure, and it is deliberately the *only*
step:

```bash
git checkout main && git pull --ff-only
git tag -a v0.7.0 -m "v0.7.0 — <one line>"
git push origin v0.7.0
```

`.github/workflows/release.yml` publishes the release from there, with
`changelog-section.sh` supplying the body from `CHANGELOG.md`'s matching
`## v0.7.0` section.

- **Write the CHANGELOG section first**, in its own PR, and merge it before you
  tag. A tag whose version has no section **fails the workflow** rather than
  publishing an empty release. That is the point of the arrangement, not an
  inconvenience to work around.
- **Do not also run `gh release create`.** Two authors for one body is what
  produced v0.5.0's duplicated notes and v0.6.0's duplicated "Full Changelog"
  line: the workflow and the CLI both write it, and neither waits for the other.
- **A section over 125,000 characters is refused**, naming its size — that is
  GitHub's release-body limit. Nearer than it sounds: v0.6.0's section was
  92,088 characters, 74% of the ceiling, because it absorbed everything that had
  accumulated under `Unreleased`.

See exactly what will be published, before the tag exists:

```bash
bash ./changelog-section.sh v0.7.0 | head -40
```

## Porting to the sibling repository

The two repositories share an engine, with one layout difference: upstream keeps
it at the repository root, the mgd port keeps it in `base/` with `tests/` one
level up.

- **`cmp` before you copy.** If the file is byte-identical between the repos,
  copy it. If it is not, the divergence is usually deliberate — the port's own
  path-resolution header, repo-specific commit ids — and copying will destroy
  it. Apply your change as an edit instead.
- **`cmp` after you copy, too**, and for files you edited compare the assertion
  names rather than assuming the edit was equivalent.
- Copy from the branch you actually changed, not from `main`.

## If you are an agent

Everything above applies unchanged. Three additions:

- Read `AGENTS.md` first — it is the working agreement, and it explains why the
  guards are shaped the way they are.
- If you share a checkout with a human or another agent, do not edit it while a
  host run is in flight, and do not ask for a host run while holding uncommitted
  edits. A corpus run copies the whole repository per worker slot.
- Hand long results over as a **file in the shared checkout**, not as a paste.
