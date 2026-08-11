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
| `native` | `db-clients=pg,mysql,mongo`, `imagemagick=ON`, `wkhtmltopdf=ON`, `ruby=$IT_RUBY_VERSIONS` (default `3.3.6,3.4.5`) | everything that makes `build.sh` set `KEEP_BUILD_TOOLCHAIN=1` |

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

### `IT_RUBY_VERSIONS`, and the CI-cost escape hatch

The `native` variant takes its Ruby list from `IT_RUBY_VERSIONS`, default
`3.3.6,3.4.5`. One env var, one code path — not a `$CI` branch inside `run.sh`.
A platform-conditional hidden in the runner is the divergence that hid the
virtiofs bug; a value set visibly in a workflow file is not.

**The cost of a second Ruby is compile wall-clock and runner disk, not API rate
limits.** The limit that does bite is `install-tools.sh`'s unauthenticated
60 req/h against `api.github.com` at *build* time, plus rvm's tag resolution
during bootstrap — both are per-run and unchanged by how many versions are
installed. The decision must be made on time and disk, or it will be made
against the wrong number.

**Ship with two, then measure.** The nightly `packages` job has
`timeout-minutes: 120`. It is unknown today whether two compiles fit, partly
because rvm may fetch a prebuilt binary rather than compile now that its three
mirrors are allowlisted — a difference of minutes versus tens of minutes, and
one nobody has measured. Degrading CI coverage in advance of that measurement
would be a guess.

The plan therefore carries an explicit measurement task: record the packages
job's wall-clock and peak disk on the first full nightly. **If the job exceeds
75 minutes or peaks above 11 GB**, set `IT_RUBY_VERSIONS=3.4.5` in
`nightly.yml` and add `--exclude needs-multiruby` to the run.

If that switch is thrown, `750-ruby-multiversion-selection` becomes a
**local-only case, and that is a named gap, not a rounding error.** It would be
covered by `verify-on-host.sh` on a workstation and by nothing in CI —
materially weaker than every other case in the corpus. Two rules keep it
honest:

- **Exclusion by selection, never by skip.** `750` carries its own
  `needs-multiruby` tag so the nightly drops it deliberately, the way the PR gate
  drops `slow` and `needs-dns`. Tag `needs-multiruby`, capability `multiruby` —
  the same two-sided naming the suite already uses for `needs-dns`/`dns`, and
  deliberately Ruby-specific: `720-node-multiversion-nvm-use` must NOT be dropped
  by this switch, because Node's second version is baked at build time and costs
  no compile. A SKIP under `--require packages` would fail the
  job, which is correct — a requirement that cannot be met is not a pass.
- **The gap is written where it is incurred.** `nightly.yml`'s comment must
  state that multi-version Ruby selection is untested in CI and name the
  measurement that caused it. A trade-off recorded only in a spec is a trade-off
  nobody will find.

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
| `750-ruby-multiversion-selection` | native | both configured versions present; `.ruby-version` selects the non-default one | `packages slow needs-multiruby` | `docker launcher multiruby` |
| `760-ruby-persists-no-recompile` | native | a second launch reuses the group volume with no recompile | `packages slow` | `docker launcher` |

`needs-external` is a **tag**, not a requirement: the PR gate excludes it by
selection. This paragraph originally continued *"and there is no capability
probe for 'the internet works'. A packages run that cannot reach the network
fails loudly, which is correct — that is what the tier measures."*

**Both halves of that turned out to be wrong, and the `requires:` column above
is superseded by the implementation.** There *is* an `external` probe
(`run.sh`'s `probe_external`), it predates this increment, and every case in
this tier carries it in `requires:` except `730`. The reasoning that changed:

- "Fails loudly, which is correct" conflates two different loud failures. A
  packages case cannot produce its *subject* without the network — rvm has
  nothing to download and compile — so what a dead network yields is not a
  measurement of the tier, it is three red cases naming rvm, missing rubies and
  the group volume. That is a missing capability reported as a broken product,
  which is the one thing this suite is built to never do. The correct outcome is
  the same one the `multiruby` paragraph below argues for: SKIP **by name**.
- `730` is the genuine exception and keeps omitting `external`: its six binaries
  are Dockerfile RUN-layer artifacts baked before the case starts, so no dead
  network can make its assertions fail.

Caught by the final whole-branch review (finding I1), which noted that
`700`/`710`/`720` already declared the capability while `740`/`750`/`760`
declared only the tag — the tier was internally inconsistent on exactly this
axis. The `requires:` column above is left as written to keep the record of what
was designed; read the case headers for what shipped.

`multiruby` is a real probed capability, read from the resolved
`IT_RUBY_VERSIONS` rather than assumed: with a single version configured, `750`
has nothing to select between and must SKIP **by name**. Deriving it from the
variant's own config is the point — a hardcoded `true` would make the case pass
by testing a one-element list, which is the decorative-check pattern this suite
exists to eliminate.

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
- **A third Ruby version, or Python/Rust/Go version lists.** Two versions cover
  the multi-version mechanism, and the mechanism is shared across the version-list
  keys.
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
5. Peak disk during a packages run is one image, **measured** on a GitHub runner
   and recorded alongside the job's wall-clock — the two numbers that decide
   whether `IT_RUBY_VERSIONS` stays at two versions in CI. An unmeasured budget
   is how a tier silently outgrows its runner.
6. `dump_blocked_forensics` is reachable from every restricted-mode case, and the
   `repo1.maven.org` class of question — which name, which IP, was it allowlisted
   here, what resolved it — is answerable from a single failing run's output.
