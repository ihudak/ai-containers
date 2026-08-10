# Integration suite increment 3 — the packages tier

**Status:** design, approved 2026-08-10
**Predecessors:** `2026-08-06-integration-test-suite-design.md` (umbrella),
`2026-08-09-integration-suite-increment-2-design.md` (mounts/groups/volumes)

## Why this increment exists

The umbrella design named four domains beyond network modes: mounts, groups,
volumes and **package installs**. Increment 2 took the first three. This is the
fourth, and it closes success criterion 6, which increment 1 rescoped in writing
rather than dropping:

> `verify-on-host.sh` contains no **network-mode** test logic of its own […]
> Rescoped from the original "no test logic of its own": Phases 1-3 are the only
> coverage of agent-tier tool installs, native-package builds and the Ruby/rvm
> bootstrap […] Full criterion 6 lands with that tier.

This is **not** an uncovered gap being closed late. `verify-on-host.sh` Phases
1-3 cover that surface today and the nightly `packages` job runs them. What
changes is the form.

### What the current form costs

- **A phase fails as a unit.** No per-case naming, no tag selection, no
  capability detection, no SKIP accounting, no `--require`.
- **It is invisible to `run.sh --list`.** A reader cannot see what is covered.
- **It duplicates harness logic.** Phase 3 composes its own `docker run` rather
  than driving `sandbox.sh`. That is not hypothetical drift: the phase kept
  bind-mounting `~/.rvm` for two full verification rounds after the named-volume
  fix landed, because it re-implemented what the product does instead of calling
  it. Increment 2's `launcher_up` did not exist when Phase 3 was written.

### What was found while scoping this

Three defects in `verify-on-host.sh`, fixed ahead of this increment
(ai-containers#13, mgd-ai-containers#11) because designing a replacement for
coverage of unknown health is guesswork:

1. **The nightly `packages` job could not fail, and never had.** Every phase
   recorded failure by *printing* it; the file's last statement was a `printf`.
   `PHASES="1 2 3" bash ./verify-on-host.sh` exited 0 whatever happened. Root
   cause: the script was born as a human-read **diagnostic** and later reused as
   a **gate** without the conversion that requires.
2. **Phase 2's tool loop printed `MISSING` and returned 0.**
3. **`if out="$(cmd | head -1)"` reports `head`'s status,** so Phase 3's
   `PRESENT BUT FAILED TO RUN` branch — written specifically to catch a `bundle`
   killed by an rvm-rewritten shebang — was unreachable.

All three are the same shape: a check that cannot report the thing it was
written to report. They inform this design's acceptance rules below.

## Architecture

### Image variants

`run.sh` today builds one minimal image and every case shares it. The packages
tier needs different images. It gains a variant table:

| Variant | `sandbox.conf` overrides | Rationale |
|---|---|---|
| *(default)* | everything OFF | today's corpus image, unchanged |
| `agents` | six agent-tier keys `ON`, `node=22,20` | `KEEP_BUILD_TOOLCHAIN` **unset** — the configuration most users ship. Multi-version Node lives here because the regression it guards is npm-prefix × `nvm use`, which needs a second version to switch to. |
| `native` | `db-clients=pg,mysql,mongo`, `imagemagick=ON`, `wkhtmltopdf=ON`, `ruby=3.3.6,3.4.5` | everything that makes `build.sh` set `KEEP_BUILD_TOOLCHAIN=1` |

**Two variants, not three.** The split is a distinction the Dockerfile itself
makes, not a convenience. A single kitchen-sink image could only ever exercise
the toolchain-kept path, so the agent-tier tools would never be tested in the
configuration they actually ship in. A third variant splitting `ruby` from
`native` would test the same build path twice and buy only isolation.

Three images per nightly including the corpus one — **fewer than today's four.**

#### Declaration and scheduling

A case declares its variant in the header block it already uses:

```bash
# summary:  all six agent-tier tools install behind the restricted firewall
# tags:     packages security slow needs-external
# requires: docker netadmin
# image:    agents
```

Space-separated, matching the existing `tags:`/`requires:` convention exactly —
`case_meta` already parses that shape, so `image:` is one more key, not a new
grammar.

`IT_IMAGE` is a single exported variable that all of `lib.sh` reads, so
**`lib.sh` requires no change** — `run.sh` exports the right value per case. A
case with no `image:` line gets the default variant, so every existing case is
unaffected.

`run.sh` groups selected cases by variant and processes them serially: build →
run that variant's cases → `docker rmi` → next. Peak disk is one image, not
three, which is what keeps this inside a GitHub runner's ~14 GB.

#### The coupling that must not drift

`launcher_up` drives the real `sandbox.sh`, which re-reads `sandbox.conf` at
**launch** time. The launcher config must therefore match the image config. Two
copies of that derivation drifted apart once already — the image carried a
component the launcher did not mount, and the case failed on a missing directory
that was correct behaviour. That is why `minimal-conf.sh` is shared between
`run.sh` and `lib.sh` today.

So `run.sh` exports `IT_VARIANT_OVERRIDES` and **`launcher_conf` folds it in
automatically**. A case cannot forget it, because a case never states it.

### The expensive-bootstrap problem

The `native` variant compiles two Rubies at container start. Paying that per
case would exceed the nightly budget; making cases depend on each other's
leftovers would make them non-runnable alone, which the suite forbids.

`lib.sh` gains `ruby_group_warm` — idempotent per run, `flock`-guarded, mirroring
what `rvm-reconcile.sh` itself does for concurrent same-group starts. The first
case to call it pays the compile; later ones are instant; any case still runs
alone.

`740-ruby-bootstraps-and-resolves` deliberately does **not** call it. Bootstrapping
from cold is the thing it tests.

### Failure forensics must survive the deletion

Phase 3 carries the blocked-traffic correlation that finally settled the
`repo1.maven.org` mystery after two verification rounds and three intermediate
PRs: `blocked.log`'s IP/port/count evidence beside each inferred name, the
container's own DNS map and baked allowlist read over `docker exec` **while the
container still lives** (both die with it), and a bounded grep for which file in
the image mentions the name.

`it_diagnose` today dumps container logs, `iptables -S`, ipset counts and capture
directory listings — none of that correlation. It moves into `lib.sh` as
`dump_blocked_forensics`, called from the existing failure path.

This is a **strict gain**: every restricted-mode case acquires forensics that
only the Ruby phase had. It is also the precondition for deleting Phase 3
without losing anything.

## Case set

Seven cases replacing three phases. One case per *operation*, not per artifact:
the six agent-tier tools install in a single `agent-tools-reconcile.sh` run, so
six cases would start six containers to repeat the same work, and the harness
already prints a `PASS:` line per assertion — splitting only moves the name from
the log into the summary line.

| Case | Image | Asserts | `tags:` | `requires:` |
|---|---|---|---|---|
| `700-agent-tools-install-restricted` | agents | all six install into `~/.ai-tools` behind the restricted firewall; each resolves in a **non-login** shell (`docker exec -T bash -c`) | `packages security slow needs-external` | `docker netadmin` |
| `710-agent-tools-reused-not-reinstalled` | agents | second container in the same group performs no re-download | `packages slow needs-external` | `docker` |
| `720-node-multiversion-nvm-use` | agents | `nvm use 20` **and** `nvm use 22` both succeed with `~/.ai-tools` populated | `packages needs-external` | `docker` |
| `730-native-clients-run` | native | `psql`, `mysql`, `mongosh`, `convert`, `wkhtmltopdf`, `gcc` present **and runnable** | `packages slow needs-external` | `docker` |
| `740-ruby-bootstraps-and-resolves` | native | via `launcher_up`: rvm bootstraps and compiles behind the firewall; the default Ruby resolves non-login; `bundle` **executes** | `packages security slow needs-external` | `docker netadmin launcher` |
| `750-ruby-multiversion-selection` | native | both configured versions present; `.ruby-version` selects the non-default one | `packages slow` | `docker launcher` |
| `760-ruby-persists-no-recompile` | native | a second launch reuses the group volume with no recompile | `packages slow` | `docker launcher` |

`needs-external` is a **tag**, not a requirement: the PR gate excludes it by
selection, and there is no capability probe for "the internet works". A packages
run that cannot reach the network fails loudly, which is correct — that is what
the tier measures.

### Assertion rules these cases inherit from the three defects found

- **Present is not runnable.** A binary that resolves on `PATH` and dies on exec
  is a distinct failure from an absent one, reported distinctly. `730` and `740`
  both assert execution, not presence.
- **Never test the wrong process's status.** Capture output first and `head` it
  afterwards; `head` succeeds on the empty output of a binary that just died.
- **`bundler` is reported, never required.** `link-default-ruby.sh` links
  `ruby`/`gem`/`bundle`/`rake`/`irb`. Failing on `bundler`'s absence would report
  a bug against a contract nothing makes.

### What `740` buys that Phase 3 cannot

Phase 3 composes its own `docker run`. `740` drives the real `sandbox.sh` through
`launcher_up`, so the mount decisions, the group resolution and
`rvm_volume_ensure` are exercised as the product performs them rather than as the
test reproduces them. This is the single largest coverage increase in the
increment, and it is only possible because increment 2 built `launcher_up`.

## Every case demonstrated failing

Seven new patches under `tests/integration/mutations/`, driven by `mutate.sh`.
`tests/test-mutations.sh` already asserts that every `mounts`/`groups`/`volumes`
case has one; its tag list gains `packages`, so a packages case authored without
a mutation fails at review time rather than passing forever.

Patches rather than `sed`, for the reason already recorded: a patch that no
longer applies is a loud failure, whereas a stale `sed` matches nothing and
reports success.

## `verify-on-host.sh` after this increment

Retains Phase 0 (environment banner, platform-specific remediation hints) and the
delegation to `run.sh`. Phases 1-3 are deleted. Criterion 6 is met in full: no
test logic of its own.

The failure ledger added in ai-containers#13 stays — it still gates Phase 0 and
the corpus call, and it is what makes the entry point usable as a gate at all.

`nightly.yml`'s `packages` job becomes:

```yaml
- run: bash tests/integration/run.sh --tags packages --require packages
```

`--require packages` makes an unmet requirement **fail** the job rather than skip
quietly, which is the whole reason the runner distinguishes selection from
skipping.

## Platform reach

The suite must stay runnable on a developer workstation, not only in CI. Stated
per platform, distinguishing verified from expected:

| Platform | Status | Notes |
|---|---|---|
| **Linux workstation** | verified | Native Docker. No caveats. |
| **macOS + Colima** | verified for the existing corpus; this increment is designed for it | The `native` variant's Ruby cases are the reason `~/.rvm` is a **named volume**: GNU tar defers symlinks whose target contains `..` by writing a mode-000 placeholder, which virtiofs cannot service, so a bind-mounted `~/.rvm` can never hold a working rvm there. `~/.ai-tools` stays a bind mount because plain `symlink()` does work. `NET_ADMIN` depends on the Colima VM carrying `ip_set`/`nfnetlink_log`; without them `probe_netadmin` makes `700` and `740` SKIP **by name** rather than fail as if the product were broken. Bind-mount sources must be under `$HOME` — `$TMPDIR` is not shared with the VM. |
| **WSL2** | expected, **never exercised** | `run.sh` sees a Linux kernel. The one documented divergence is already handled: `ip6tables` may be unavailable, leaving IPv6 egress unrestricted while IPv4 enforcement is unaffected (`ALLOW_IPV6_BYPASS=1` silences the warning), and NFLOG was chosen over the `LOG` target precisely because it works under nf_tables. Recorded as expected-and-unverified rather than supported: nothing in this suite has been run there, and claiming otherwise is the failure mode this project keeps finding. |

CI remains Linux-only, for the reason the umbrella spec already names: GitHub's
macOS runners bill at 10× and have no Docker daemon.

Local cost is unchanged — `verify-on-host.sh` already ran Phases 1-4, and these
cases are the same work. New capability: `--exclude packages` for a fast local
pass.

## Out of scope

- **Per-component images.** Proving that the firewall admits a listed domain is
  component-agnostic; building N images to re-prove it per fragment costs a great
  deal and adds nothing. The two variants exist because they differ in a *build
  path*, not because they differ in components.
- **A third Ruby version, or Python/Rust/Go version lists.** `ruby=3.3.6,3.4.5`
  covers the multi-version mechanism; the mechanism is shared.
- **SDKMAN components** (`openjdk`, `graalvm-*`, `kotlin`, `scala`, `maven`,
  `gradle`). Baked, allowlist-covered, and no runtime reconcile — nothing the
  packages tier would assert that the build succeeding does not already.
- **macOS or WSL2 in CI.**

## Success criteria

1. All seven cases pass in a full local run on Linux, and on macOS + Colima where
   the host provides `netadmin` (SKIP by name where it does not).
2. Each of the seven has been demonstrated **failing** against a mutation under
   `tests/integration/mutations/`, and `tests/test-mutations.sh` enforces that a
   packages case without one fails at review time.
3. `verify-on-host.sh` contains no test logic — criterion 6 of the umbrella
   design, in full.
4. The nightly `packages` job runs the tier through `run.sh --require packages`,
   and an unmet requirement fails it rather than skipping quietly.
5. Peak disk during a packages run is one image, verified on a GitHub runner.
6. `dump_blocked_forensics` is reachable from every restricted-mode case, and the
   `repo1.maven.org` class of question — which name, which IP, was it allowlisted
   here, what resolved it — is answerable from a single failing run's output.
