# Runtime integration test suite — design

**Date:** 2026-08-06
**Status:** approved, pending implementation plan
**Scope:** increment 1 of a long-term initiative

## Why

The suite exists to make **silent security regressions impossible**.

The motivating incident: `capture-blocked-traffic.sh` died at line 57 of its own
startup — a `grep -v … | grep -v …` pipeline returning 1 on an allowlist with no
non-comment lines, propagated by `pipefail`, fatal under `set -e`. For months,
`restricted` mode produced no `blocked.log`, no `blocked-domains.txt`, no NFLOG
watcher and **no self-healing**, with nothing logged to say so. Enforcement itself
never broke — packets were still dropped — but every record of *what* was dropped
was gone, and dynamic CDN IPs behind an allowlisted wildcard silently stopped being
admitted. It was found by accident.

The failure mode is therefore not "a test failed". It is **"nothing tested it, and
everyone assumed"**. A green build that means *we did not look* is worse than no
build, because it manufactures confidence.

## Principles

### 1. Assert effect, not configuration

`tests/test-entrypoint-wiring.sh` asserts the capture daemon is wired into
`entrypoint.sh`. It passed every single day of the outage, because the wiring *was*
correct — the daemon died after being started. Configuration assertions are cheap
and worth keeping, and they cannot catch this class of bug.

Integration cases observe from **outside** the container: did the packet arrive,
does the file exist, does the log contain the line.

### 2. A case that cannot run is not a pass

Outcomes are three-state: **PASS / FAIL / SKIP-with-reason**. Every skip prints its
unmet requirement. The runner accepts `--require <tag>`; any skip among cases
carrying a required tag is a **failure**.

**Selection and skipping are different things, and conflating them would reopen the
hole this suite exists to close.** `--tags` / `--exclude` decide which cases are
*selected* — a deliberate, visible choice recorded in the workflow. A **skip** is a
case that *was* selected and then could not run because a requirement was unmet.
`--require` applies only within the selected set. So excluding `needs-dns` from the
PR gate is legitimate and explicit; a selected security case silently not running is
not. The run report always prints both counts separately — `selected N of M` and
`skipped K` — so "we chose not to check this" can never be read as "this passed".

CI passes `--require security`. If the runner cannot obtain `NET_ADMIN`, the job
goes red with `3 security cases skipped: netadmin unavailable` — never green.

This extends an instinct already present in `tests/run-all.sh` ("Exiting 0 without
asserting anything is not a pass") from the test body to the environment.

### 3. One corpus, tags select

Cases never know whether they are on CI. They declare requirements; the runner
decides. The same corpus runs on macOS, on Linux workstations, and on GitHub
Actions — CI simply selects the subset that is permitted and affordable there.

A case too expensive for CI today still exists and still runs locally; promoting it
later is a filter change, not a port.

## Architecture

**One image per run.** Every firewall knob is already runtime-overridable:
`ALLOWLIST_DOMAINS_FILE`, `ALLOWLIST_PROXY_DOMAINS_FILE`, `ALLOWLIST_CIDRS_FILE`,
`ALLOWLIST_IPV4_SET`, `DEV_CONTAINER_MODE`, `SELF_HEALING_ENABLED`, `NFLOG_GROUP`,
`BLOCKED_CAPTURE_DIR`, `DISCOVERY_CAPTURE_DIR`. A scenario is therefore *env vars +
a bind-mounted synthetic allowlist* — seconds, not a rebuild. The image is built
from a minimal `sandbox.conf` (all optional components OFF).

**Sidecar destinations, not the real internet.** A controllable responder runs on a
user-defined Docker network using the sandbox image itself
(`--entrypoint python3 … -m http.server`), so no extra image is pulled. Its IP goes
into — or is omitted from — the synthetic allowlist. "Blocked" and "allowed" become
deterministic and offline, so the security cases carry no `needs-external` tag and
run on every PR.

**`verify-on-host.sh` becomes a thin, platform-adaptive host entry point** — *not* a
macOS one. "Host" means "a machine with a real Docker daemon", as opposed to inside
the dev container. The same command runs on macOS + Colima and on a Linux
workstation with native Docker; the only platform-specific part is the preflight
*hints*, which is already conditional today (`if command -v colima`) and stays that
way. There is deliberately no `verify-on-linux-host.sh`: a second entry point would
reintroduce, at the wrapper level, exactly the duplication this design removes at
the case level.

It keeps three jobs and no test logic: the environment banner (daemon reachable,
disk, Colima/native), a sensible default selection (everything, since a human
running it locally wants full coverage), and platform-specific remediation hints on
failure. Everything else delegates to `tests/integration/run.sh`. One definition of
the integration tests; the drift that made the old script keep bind-mounting
`~/.rvm` after the volume fix landed becomes structurally impossible.

## Layout

Identical in both repos (`lib-paths.sh` already resolves `BASE_DIR` for
mgd-ai-containers):

```
tests/
  run-all.sh                        # existing unit suite, untouched
  integration/
    run.sh                          # capability detect → select → execute → report
    lib.sh                          # the verbs every case uses
    cases/
      010-restricted-blocks-unlisted.sh
      ...
```

### Case contract

```bash
#!/usr/bin/env bash
# summary:  restricted mode drops a destination absent from the allowlist
# tags:     security network-mode restricted fast
# requires: docker netadmin sidecar
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
```

The runner parses `tags:` and `requires:`; the body is plain bash.

### `lib.sh` verbs

| Verb | Purpose |
|---|---|
| `it_image` | build once per run, reuse across cases (`--reuse-image` locally) |
| `sidecar_up` / `sidecar_ip` / `sidecar_down` | the controllable destination |
| `allowlist_write <file> <entries…>` | synthesise a scenario's allowlist |
| `sandbox_up <mode> [env…]` → cid | start a container in a mode |
| `sandbox_exec` / `sandbox_down` | drive and tear down |
| `reach <cid> <dest>` → 0/1 | the primitive most network cases reduce to |
| `blocked_entries <dir>` | **non-comment lines only** |
| `assert_reachable` / `assert_blocked` / `assert_file_exists` / `assert_log_contains` | assertions |

`blocked_entries` filters comments because `init_output_files` seeds every output
file with explanatory headers — reading raw `-s` reported a clean run as
"HARD-BLOCKED" and listed the headers as blocked destinations.

### Tag vocabulary

- **domain:** `network-mode`, `mounts`, `volumes`, `groups`, `packages`
- **risk:** `security`
- **cost:** `fast` (<30s), `slow`
- **needs:** `needs-external`, `needs-netadmin`, `needs-dns`

## Allowlist coverage: what goes where

| Concern | Covered today | Home |
|---|---|---|
| **Assembly** — component ON → fragment in generated file | ✅ 44 assertions in `test-allowlists.sh` | stays hermetic; a container adds only minutes |
| **Delivery** — that file reaches `/tmp/` in the image | ❌ nothing, anywhere | increment 1 |
| **Efficacy** — listed entry admitted, absent entry dropped | ❌ | increment 1, synthetic |
| **Fragment health** — a fragment's domains still resolve | ❌, rots silently | nightly, `needs-external` |
| **End-to-end** — real tools install through the real allowlist | `verify-on-host.sh` Phase 1 | packages tier, `slow` |

Efficacy is deliberately component-agnostic: ipset/iptables does not know which
fragment a domain came from, so proving admit/drop once proves it for every
fragment. Building N images to re-prove it per component costs a great deal and
adds nothing.

Delivery is currently unverified by anything — `Dockerfile:467` does
`COPY allowlist-domains.txt /tmp/`, and no test checks the file landed or matches
what `build.sh` generated. A Dockerfile edit could ship a stale or absent allowlist
with every existing test green.

## Increment 1 case set

### Restricted

| Case | Asserts | Tags |
|---|---|---|
| `010-blocks-unlisted` | sidecar absent from allowlist → unreachable | security, fast |
| `020-allows-listed-cidr` | sidecar IP in `allowlist-cidrs` → reachable | security, fast |
| `030-allows-listed-domain` | fake host via `--add-host`, domain listed → reachable (exercises the `getent` path, not only the literal-IP branch) | security, fast |
| `040-records-blocked` | after a blocked attempt, a **real (non-comment)** entry appears in `blocked-domains.txt`/`blocked-ips.txt` | security, fast |
| `050-capture-starts` | the three output files exist — the daemon reached `init_output_files` | security, fast |
| `060-empty-allowlist-still-captures` | comments-only proxy-domains file, daemon still starts — the regression, against real `tshark` under real `NET_ADMIN` rather than stubs | security, fast |
| `070-drops-capabilities` | the agent shell holds neither `NET_ADMIN` nor `NET_RAW` | security, fast |

### Self-healing

| Case | Asserts | Tags |
|---|---|---|
| `080-admits-wildcard` | dnsmasq sidecar + `*.wild.test` in proxy-domains → first packet dropped and logged, then auto-allowed and reachable | security, needs-dns |
| `085-disabled-stays-blocked` | `SELF_HEALING_ENABLED=0` → stays blocked, recorded as a hard block | security, fast |

### Discovery

| Case | Asserts | Tags |
|---|---|---|
| `110-does-not-block` | the allowlist that blocks under restricted does not block here | network-mode, fast |
| `120-collects` | pcap non-empty; extraction lists the destination | network-mode, slow |

### Open

| Case | Asserts | Tags |
|---|---|---|
| `210-no-firewall` | OUTPUT policy ACCEPT, sidecar reachable | network-mode, fast |
| `220-no-capture` | no capture daemon and no output dirs — open mode's documented promise | network-mode, fast |
| `230-drops-capabilities` | `NET_ADMIN` and `NET_RAW` both dropped | security, fast |

### Delivery

| Case | Asserts | Tags |
|---|---|---|
| `300-allowlist-delivered` | in-image `/tmp/allowlist-*.txt` match what `build.sh` generated | fast |

### Known hard part

Self-healing correlates a blocked IP to a domain through the DNS map that
`capture-blocked-traffic.sh` builds by sniffing real port-53 responses.
`--add-host` produces no DNS traffic, so the map stays empty and self-healing
cannot fire. Testing it offline needs a real resolver in the test network — a
`dnsmasq` sidecar plus `--dns <ip>`. Planned as the last case of increment 1,
tagged `needs-dns`, rather than assumed to fall out for free.

## Authoring rule for security cases

**A security case is not accepted until it has been demonstrated to FAIL against the
known-bad configuration.** `010` must be shown failing when the sidecar *is*
allowlisted; `050` must be shown failing against the pre-fix `grep|grep` pipeline.

This is the only thing distinguishing a real regression test from one that is green
because its primitive is broken. It was done for `tests/test-blocked-capture.sh`
(7 failures against the old code, 0 against the fix) and it caught a bad assumption
twice during that session. A security case never observed failing manufactures
exactly the false confidence this suite exists to eliminate.

## CI

### `tests.yml` — PR and push to main, blocking

| Job | Runs |
|---|---|
| `unit` | `bash tests/run-all.sh` — no Docker, ~1 min |
| `lint` | `bash -n` over every script, plus shellcheck |
| `integration-fast` | build minimal image, then `run.sh --require security --tags fast --exclude needs-external,needs-dns` |

### `nightly.yml` — schedule + `workflow_dispatch`, non-blocking but loud

| Job | Runs |
|---|---|
| `integration-full` | everything, including `needs-dns` and `slow` |
| `allowlist-health` | `getent` over every domain in every fragment |
| `packages` | today's Phase 1 and Phase 2 — real installs, real allowlist, per-component images |

### Operational rules

- **Per-case timeout.** Each case runs as its own process under `timeout`. This
  session had a poll loop that would have burned 30 minutes on a container that
  failed in 10 seconds; CI must never pay that.
- **Labelled resources.** Everything created carries `ai-containers.it-run=<id>` so
  a crashed run's containers, networks and volumes are swept in one command instead
  of leaking into the runner or a developer's machine.
- **Diagnostics on failure, automatically.** A failing case dumps container logs,
  `iptables -S`, `ipset list` and the capture directory before teardown, uploaded
  as a CI artifact. The first version of `verify-on-host.sh` printed a *summary* and
  discarded the actual error, which cost several round trips; the harness must never
  make a human ask for the next round of output.
- **Disk.** GitHub runners have ~14 GB free. Each job builds one image and starts
  clean; the multi-image nightly jobs are separated for that reason.
- **No BuildKit layer caching initially.** It is a common source of "green locally,
  strange in CI". Add only if the build measurably dominates.
- In `mgd-ai-containers`, which already requires PRs, these become required checks.

## Platform scope

Linux only in CI — GitHub's macOS runners bill at 10× and have no Docker daemon.

This is an accepted, *named* limitation: the virtiofs/tar delayed-link failure that
made Ruby impossible on macOS is invisible on Linux, and so is the Colima
`$TMPDIR`-not-shared class of bug. Of the six bugs fixed in the originating session,
Linux CI would have caught five and sailed green past the headline one. macOS
coverage remains a local command — the same corpus, via the `verify-on-host.sh`
entry point — and should be run before a release.

## Explicitly out of scope for increment 1

Mounts and workspace semantics (`:ro` enforcement, workdir, name collisions,
`:rwcopy`, `PREVIEW_PORTS`), container groups, volume lifecycle, and package
installs. All are intended for later increments against the same harness; network
modes go first because they are the security core and they stress the harness
hardest (`NET_ADMIN`, ipset, NFLOG, sidecar), so any CI limitation surfaces
immediately rather than after three increments of investment.

## Success criteria

1. `run.sh` runs unchanged on macOS, Linux and GitHub Actions, selecting by tag.
2. All fifteen increment-1 cases pass in a full local run (`run.sh` with no
   filters) on both Linux and macOS.
3. The CI-selected subset — the 13 `fast` cases, `needs-dns` and `slow`
   excluded by deliberate selection — passes on Linux CI, or fails loudly with a
   named unmet requirement. No selected case ever skips silently.
4. Each security case has been demonstrated failing against its known-bad
   configuration.
5. `tests.yml` is a required check on both repos.
6. `verify-on-host.sh` contains no test logic of its own — only a platform-adaptive host preflight
   and a call into the shared runner.
