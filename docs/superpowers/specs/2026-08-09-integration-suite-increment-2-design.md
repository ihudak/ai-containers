# Integration test suite, increment 2 — mounts, groups, volumes

**Date:** 2026-08-09
**Status:** approved, pending implementation plan
**Extends:** `2026-08-06-integration-test-suite-design.md` (the umbrella design —
its Principles, tag vocabulary, `--require` semantics and authoring rule all
apply unchanged here and are not restated)

## Scope

The umbrella design deferred four domains: *mounts and workspace semantics
(`:ro` enforcement, workdir, name collisions, `:rwcopy`, `PREVIEW_PORTS`),
container groups, volume lifecycle, and package installs.*

This increment takes the first three. **Package installs are deferred to
increment 3** — they are `verify-on-host.sh` Phases 1-3 today, they need
per-component images and real network, and they belong to a nightly tier with
different cost characteristics. Nothing here blocks them.

## The gap this increment closes

Increment 1 proved the *image* enforces the network contract. It never touched
`sandbox.sh`, which is where every mount decision is actually made.

Coverage today splits cleanly, and badly:

| Layer | Covered by | Verifies |
|---|---|---|
| Launcher composition — *which* `-v` flags | `tests/test-docs-path.sh` &co, fake `docker` on `PATH` | the argument string |
| Runtime effect — what those flags *do* | nothing | — |

The hermetic tier is good and stays. But it asserts **configuration**, and the
umbrella design exists because configuration assertions pass while the effect is
broken — `tests/test-entrypoint-wiring.sh` was green every day of the outage.

A fake-`docker` test cannot see:

- a `:ro` flag that reaches Docker but is defeated inside the container
- `setup_sandbox_user`'s recursive `chown` (which uses `-xdev` **and therefore
  does not cross into mounts**) leaving a mount unusable by the agent user
- capture output that is written inside the container and never reaches the host
  launch directory the user actually reads
- a `:rwcopy` write landing in the shared base volume
- one group's credentials being visible from another group's container

Every one of those is silent. Four of the five are the same shape as the
motivating incident: the mechanism runs, reports nothing, and the operator
believes a guarantee that no longer holds.

## Mechanism: `launcher_up`, and why it is not `sandbox_up`

Increment 1's `sandbox_up` composes its own `docker run`. That is correct for
the image tier — it isolates the entrypoint from the launcher. It is exactly
wrong here, because reproducing `sandbox.sh`'s mount logic in the harness would
test the reproduction.

So increment 2 adds a second verb that drives **the real `sandbox.sh`**:

```
launcher_up <mode> [primary]        # env comes from the case: REPOS, EXTRA_MOUNTS, …
```

Three obstacles and their resolutions:

**1. `sandbox.sh:768` is `docker run -it --rm`** — interactive, foreground, no
`--name`, no label. Nothing to exec into, nothing to sweep.

Resolved with a **pass-through `docker` shim on `PATH`** — the same mechanism
the hermetic tests already use, except it forwards to the real binary instead of
capturing. On the main run it injects a `--name` and the run's `ai-containers.it-run`
label, and rewrites `-it` to `-d -i`.

The rewrite targets `-it` specifically because **`sandbox.sh:768` is the only
`docker run -it` in the entire repository** (verified across `sandbox.sh`,
`sandbox-common.sh`, `repo.sh`, `group.sh`, `entrypoint.sh`, `verify-on-host.sh`
— every other one is a `--rm --entrypoint` helper). The shim therefore cannot
mistake `seed_workcopy_volume`'s copy container, or any `repo.sh` seeding
container, for the container under test.

`-d -i` and not `-d -i -t`: `verify-on-host.sh` already starts this exact image
with `docker run -di --rm` and execs into it, on macOS + Colima and on Linux,
and has done so for months. The shim reuses a proven invocation rather than
introducing `-dit`, which nothing here has ever run.

**No production file changes to make this testable.** A `SANDBOX_DETACH=1` knob
in `sandbox.sh` would have been shorter and would have put a test seam in a
security-relevant launcher; the shim keeps the launcher exactly as users run it.

**2. The shim could silently not work** — a daemon that rejects the rewritten
invocation would make every case fail in a way that looks like a mount bug.
So `launcher` is a **detected capability**, probed like `netadmin` is: the
runner drives one throwaway container through the shim and confirms a detached
container results. If it does not, the cases SKIP with `requires: launcher`
named, and `--require` can make that fatal. A case that cannot run is not a pass.

**3. `sandbox.sh` reads the invoking user's `$HOME`** for groups, the repo
registry and `.gitconfig`. Cases point `HOME` at scratch, as the hermetic tests
already do, plus `AI_CONTAINER_GROUP_INIT=clean` for a non-interactive bootstrap
and `SANDBOX_CONF` for a minimal component set.

`sandbox_up` is unchanged and keeps its cases. The two verbs answer different
questions and the split is the point:

- `sandbox_up` — *does the image honour this configuration?*
- `launcher_up` — *does `sandbox.sh` produce that configuration from this env?*

## Case set

Numbering continues the umbrella scheme: 4xx mounts, 5xx groups, 6xx volumes.

### Mounts (4xx)

| Case | Asserts | Tags |
|---|---|---|
| `400-ro-repo-not-writable` | `REPOS="lib:ro app:rw"` → the agent user's write to `/workspace/lib` **fails** and its write to `/workspace/app` **succeeds**, in one container | mounts, security, fast |
| `410-workdir-and-umbrella-writable` | primary host path → the agent shell's cwd is `/workspace/<basename>` and is writable; with no primary, cwd is the `/workspace` umbrella and is writable (`chown_workspace_root`, non-recursive) | mounts, fast |
| `420-collision-launches-nothing` | an `EXTRA_MOUNTS` basename colliding with a `REPOS` name → non-zero exit **and zero containers created** (counted by label) | mounts, fast |
| `430-blocked-output-reaches-host` | restricted mode, a blocked destination → a real (non-comment) entry appears in `blocked-domains.txt`/`blocked-ips.txt` **on the host launch dir**, readable by the invoking user | mounts, security, fast |
| `440-preview-ports-published` | `PREVIEW_PORTS="<hostport>:8080"` → a listener started inside the container answers from the **host** | mounts, fast |

The positive control in `400` is not decoration. A mount that is unwritable
because the whole `/workspace` tree is broken would satisfy a bare
"`:ro` is not writable" assertion; the `:rw` sibling in the same container is
what distinguishes enforcement from breakage.

`430` needs no sidecar and no DNS: under restricted mode `sandbox.sh` uses the
**real** baked allowlist, so `192.0.2.1` (RFC 5737 TEST-NET-1, in no fragment
and routable nowhere) is a deterministic blocked destination. It is tagged
`fast` despite paying the ~22s tshark attach, matching increment 1's `040`,
because the blast radius — the operator's only record of what was dropped, which
is precisely what the motivating incident destroyed — justifies a PR-gate slot.

### Groups (5xx)

| Case | Asserts | Tags |
|---|---|---|
| `500-group-isolation` | a marker in group A's `.claude` is **absent** from a group-B container and **present** in a group-A container | groups, security, fast |
| `510-credentials-persist-to-host` | a file written to `~/.claude/` inside the container appears on the host under `~/.ai-containers/<group>/.claude/`, owned by the invoking uid | groups, fast |

`500` is the credential-leak case. Both halves run, because "absent from B" alone
also passes when the mount is broken in both.

### Volumes (6xx)

| Case | Asserts | Tags |
|---|---|---|
| `600-rwcopy-isolated` | a write inside a `:rwcopy` repo does **not** appear in the base volume; a later `:ro` attach of the base does not see it | volumes, fast |
| `610-group-rm-removes-both` | `group.sh rm` removes the group directory **and** its rvm volume against a real daemon; refuses while a running container mounts the volume | volumes, fast |
| `620-group-gc-collects-orphan` | after a manual `rm -rf` of the directory, `group.sh gc` removes the orphaned volume and leaves repo volumes untouched | volumes, fast |
| `630-rvm-volume-writable-by-agent` | a fresh (root-owned) named volume at `~/.rvm` is writable by the agent user after `chown_rvm_root` | volumes, slow, needs-external |

`610`/`620` have hermetic counterparts in `tests/test-group-lifecycle.sh` that
run against a fake `docker`. Those stay; they pin the argument construction. The
integration versions add what a fake cannot: real `docker volume` semantics, and
the in-use refusal, which depends on `docker ps --filter volume=` actually
matching — a fake `docker` will agree with whatever the script asks it.

`630` is `slow` and `needs-external` because `chown_rvm_root` is gated on
`RUBY_VERSIONS` being non-empty (`entrypoint.sh:32`), and setting it also runs
`rvm-reconcile.sh`, which bootstraps rvm over the network. The case requests a
version that cannot exist so the install fails fast after the bootstrap instead
of compiling a Ruby. Nightly, not the gate.

## Authoring rule

Unchanged from the umbrella design, and it binds every case above, not only the
ones tagged `security`: **a case is not accepted until it has been demonstrated
failing against the known-bad configuration.** Concretely, each case names its
mutation and the run that produced the failure:

| Case | Known-bad mutation |
|---|---|
| `400` | drop the `:ro` suffix in `sandbox.sh`'s repo loop |
| `410` | remove `chown_workspace_root` from the entrypoint |
| `420` | make the collision check a warning instead of `exit 1` |
| `430` | point `BLOCKED_CAPTURE_DIR` at a container-local path (no host mount) |
| `440` | drop the `-p` flags from the `docker run` |
| `500` | mount `$HOME/.claude` instead of the group's |
| `510` | mount the group dir `:ro` |
| `600` | mount the base volume instead of the working copy |
| `610` | remove the volume-removal half of `group.sh rm` |
| `620` | make `gc`'s discovery filter match repo volumes too |
| `630` | remove `chown_rvm_root` |

## CI

No new workflow. The `integration-fast` gate keeps
`--require security --tags fast --exclude needs-external,needs-dns`, which picks
up the nine new `fast` cases automatically. `630` lands in nightly by tag. The
`launcher` capability joins `netadmin` in the probe list, so a runner that
cannot drive the shim reports it by name.

## Out of scope

Package installs (increment 3). `repo.sh add`/`sync` against real git remotes —
network-bound, and the registry logic already has 721 lines of hermetic coverage
in `tests/test-repo-registry.sh`. macOS-specific mount behaviour: the corpus runs
there via `verify-on-host.sh`, but nothing in this increment is macOS-conditional.

## Success criteria

1. Eleven new cases pass in a full local run on Linux, and the ten
   non-`needs-external` ones pass on macOS via `verify-on-host.sh`.
2. Each has been observed failing against the mutation named above, and the
   mutation reverted.
3. The `launcher` capability is detected, and a machine without it SKIPs the
   affected cases with that requirement named — never silently.
4. No production file gains a test-only code path.
5. Ported to `mgd-ai-containers` byte-identically, via PR.
