# `~/.cache` on a per-group Docker volume

**Status:** design, 2026-11-27. Follows
[2026-11-25-var-tmp-volume-design.md](2026-11-25-var-tmp-volume-design.md), which
moved `/var/tmp` to a volume and kept `~/.cache` a host bind, and the macOS
re-check of 2026-11-26 (`docs/superpowers/plans/2026-11-26-mac-recheck.md`),
whose numbers reopened that choice.

## Why

The re-check (Colima 0.10.3, Docker 29.5.2, Apple M5 Pro) found:

- **Speed.** With `~/.cache` on the bind, against a volume: `uv pip install
  django sympy` took 14–16 s against 1.6–1.8 s from an empty cache, and 1.8 s
  against 0.2 s from a filled one; creating, reading and deleting 20,000 files
  of 4 KiB took 10 / 4–5 / 4 s against 0.2 / 0.1 / 0.1 s. The plan's own pip
  benchmark showed no difference, because pip keeps whole wheels, a few large
  files. uv, go-build's cache, node-gyp's headers and qmd's index are many small
  files, which virtiofs serves one slow request at a time.
- **One error, the same as before.** GNU tar cannot unpack an archive holding a
  `..` link into `~/.cache` on a Mac (mode-000 placeholder, virtiofs). No tool
  tried (uv, pip, node-gyp) hit it, but it is the bug that put `~/.rvm` and
  `/var/tmp` on volumes.

On Linux the bind costs nothing, and a volume nothing either: one code path on
every platform, as for `~/.rvm` and `/var/tmp`.

The user's decisions (2026-11-27):

- `~/.cache` moves to a Docker volume per group, on every platform. This
  reverses the 2026-11-25 choice to keep it a bind; the cost accepted is that
  the cache can no longer be browsed or cleared from the host directly.
- A group's existing host `.cache` is **copied into the volume once,
  automatically**, by the launch that makes the volume (as `~/.rvm` was). It
  holds what is costly to rebuild: qmd's index, Playwright's browsers (~500 MB).
- Everything else: the builder's calls, listed at the end.

## What it is

Every container of a group mounts the volume `<prefix>-cache-<group>` at
`~/.cache` (the prefix is `REPO_VOLUME_PREFIX`'s, as for the Ruby and temp
volumes). It is the temp volume's twin, minus the per-launch folders and the
pruning:

- **Name and labels.** `sanitize_volume_token` as for the others. Labels at
  creation: `ai-containers.cache-group=<group>`, and `ai-containers.owner=<id>`
  when the home's id is known. The `-cache-` infix keeps it out of `repo.sh`'s
  discovery and of the Ruby and temp code.
- **The label decides.** As for the temp volume, every cache volume is new, so
  none predates labels: a volume of the name with no cache label, or labelled
  for another group, **refuses the launch**, naming the `docker volume rm` that
  clears the way; so does one that cannot be made, or that docker cannot say
  exists. `vartmp_volume_ensure()` is generalised to both kinds, not copied.
- **Nested prefixes.** A Ruby-named volume carrying a cache label is not
  mounted as `~/.rvm` (as one carrying a temp label is not); `group.sh` never
  takes a volume with a cache label for a Ruby or temp volume, nor the reverse.
- **Mounted** `-v <volume>:<home>/.cache`. The launcher no longer makes
  `$group/.cache` and no longer binds it. `~/.local/state` stays a bind.
- **Ownership.** A fresh volume at `~/.cache` comes up `root:root 0755`
  (measured on Colima: the image has no such path to copy from). Nothing new is
  needed for it: the start-up's recursive `find "$home_dir" -xdev -exec chown`
  (`setup_sandbox_user`) already gives every mount point under the home to the
  sandbox user without descending into it (measured on Colima for a volume at
  `/home/x/.cache`; case 630's mutation relies on the same for `~/.rvm`). A
  `chown_cache_root` like `chown_rvm_root` was built first and dropped as
  redundant.

What changes for the user:

- The cache is no longer on the host. It is reached from any container of the
  group, sized by `./group.sh list --sizes`, and cleared by removing the volume
  while no container of the group runs (`docker volume rm <prefix>-cache-<group>`);
  the next launch makes a fresh one.
- `./group.sh list` shows a third volume per group; `rm` removes it with the
  group; `gc` collects one whose group directory is gone.
- On a Mac, the cache runs at the VM's disk speed, and tar works there.

## Approaches

- **A. A volume of its own per group (chosen).** Clearing the cache is removing
  its volume; `group.sh` lists its size. Costs a third volume kind in
  `group.sh` and its nested-prefix checks.
- **B. Inside the group's temp volume** (a folder there, mounted at `~/.cache`
  with Docker's volume subpath or reached through a link the start-up makes).
  No new volume kind, but the cache and `/var/tmp` could only be cleared
  together, a subpath needs Docker 26 and must exist before the mount, and a
  "temp" volume holding the cache is a muddle. Rejected.
- **C. Redirect the heavy tools only** (`UV_CACHE_DIR`, `GOCACHE`, … into the
  temp volume). The per-tool approach the persistent-scratch design dropped:
  every tool not listed stays slow. Rejected.

## The one-time copy

When **this launch made the volume** (it was not there when first asked) and
`$group/.cache` is a non-empty directory (followed if it is a link, as the bind
followed it), the launcher copies it into the volume before the container
starts, printing one line before and one after:

- One `docker run --pull=never --network none` of the project image, the old
  folder bound read-only (`docker_bind()`, SELinux option as every host bind),
  the volume read-write. As root it chowns the volume's top folder to the
  sandbox uid and makes a staging folder in it, `0700`, owned by that uid; then
  the copy runs **as the sandbox uid** (`setpriv --reuid --regid
  --clear-groups`), `cp -dR --preserve=mode,timestamps,links` into the staging
  folder. Ownership is not preserved but given: on a Mac, root reads the host
  user's files as `0:0`, and `cp -a` as root put root-owned files in the volume
  that the agent could not enter (case 525's failure). Measured on Colima: files
  come out `502:20`, a `0700` folder stays readable, links and times are kept.
- Each top-level entry is then moved out of the staging folder into the
  volume's top, one rename each, skipping a name already there (two first
  launches together), and the staging folder is removed. So a tool's cache is
  either all there or absent, never half-copied.
- A copy that fails: a `WARNING:`; the staging folder is removed; the group
  starts with an empty cache; the old folder is kept and named. The launch is
  not refused.
- A launcher killed during the copy leaves the hidden staging folder in the
  volume, taking space until the volume is removed; the cache refills from
  scratch. A stated limit.
- The old folder is **never** removed. The line after a copy names it with the
  `rm -rf` to run once satisfied, and says that projects of the group still on
  an older engine (not yet synced) keep using it.

`AI_CONTAINER_GROUP_INIT=from:<group>` copies the source group's qmd index
(`.cache/qmd`) into the new group. Once the source has a cache volume, that
index is in the volume, not in its host folder: the launch that makes the new
group and its volume copies the source volume's `qmd/` straight into the new
volume (`cache_volume_copy_qmd`, one container run, as the sandbox uid, volume
to volume), before the old-folder copy, which then leaves that `qmd` alone.
Without a source volume, the host folder is copied as today, and the old-folder
copy carries it in. `from:host` is unchanged (it copies `~/.cache/qmd` of your
real home).

## `group.sh`

A group owns a directory and up to three volumes: Ruby, temp, cache. The kind
dispatch (`_group_vol`, `_group_volumes`, `_vol_group`, `_vol_not_ours`) gains
`cache`, recognised by its label alone, as `temp` is. `list` adds a column pair
(`CACHE VOLUME`, `STATE`, and its size with `--sizes`); `rm` removes the three,
each by today's rules (another home's kept and named, one in use refusing the
whole `rm`, one not the group's named with its `docker volume rm`); `gc` takes
orphaned cache volumes too. Usage text and header comment updated.

## Other launcher changes

- `_group_scratch_mount()` no longer lists `.cache`: there is no such bind.
  `~/.local/state` keeps its exclusion from the launcher walk. An
  `EXTRA_MOUNTS` of the old `$group/.cache` is walked like any mount.
- The comment that justifies the whole-folder mount moves to the volume.
- `UV_LINK_MODE=copy` stays: the uv cache and `~/.ai-tools` are still two
  mounts, so `link()` between them still fails with `EXDEV`.

## Constraints

As for the temp volume: one code path on every platform; bash 5.1 floor and
GNU/BSD portability for anything the hermetic suite runs on the host; code cited
by snippet; every new integration assertion seen failing through a patch under
`tests/integration/mutations/`; `tests/falsify/targets.conf` kept true;
`AGENTS.md` the only instruction file; an Unreleased `CHANGELOG.md` entry.

## Goals

- `~/.cache` at volume speed on a Mac, and tar working there.
- Nothing a group's cache holds is lost: copied once, the old folder kept.
- No launch slower by a container run, but the one launch per group that copies.

## Non-goals

- `~/.local/state`, `.ai-tools`, `.gradle`, `.m2`, `.yarn`: they stay binds
  (many small files too; not measured, a possible follow-up).
- A `group.sh` command to browse or clear the cache; the docs give
  `docker volume rm` and the in-container commands.
- Retrying a copy that failed: the old folder is named for a copy by hand.

## Anti-goals

- A volume made unlabelled by `docker run -v`, which `group.sh` would never find.
- Files in the volume the agent cannot write: no root-owned copy.
- Deleting or changing the old host folder.

## Testing

Hermetic:

- A new `tests/test-cache-volume.sh`, with the fake docker: the volume created
  with both labels and mounted at `~/.cache`; no host `.cache` made or bound;
  refusals for a volume that cannot be made, an
  unlabelled one, one of another group, one docker cannot judge; the copy run
  only when this launch made the volume and the old folder is a non-empty
  directory (a link followed), never otherwise; its command (uid, flags,
  staging, read-only source, no network); the line before and after; a failed
  copy warns and the launch goes on; `from:<group>` taking qmd from the source
  volume, or the host folder without one.
- `tests/test-agent-tmp.sh`, `tests/test-playwright.sh`,
  `tests/test-launcher-dir-ro.sh` (T93), `tests/test-tool-config-mounts.sh`:
  updated from the bind to the volume.
- `tests/test-group-lifecycle.sh`: the cache volume in `list`, `rm`, `gc`, with
  the owner rules and the in-use refusal; `tests/test-rvm-volume.sh` and
  `tests/test-vartmp-volume.sh`: the three kinds never take each other's
  volumes, and `repo.sh` sees none.

Integration (each new assertion with a mutation):

- Case 520: `~/.cache` is a volume named for the group, a `..`-link archive
  unpacks there with GNU tar, the next container reads the same bytes. The
  existing `520-cache-not-mounted.patch` is updated; a new mutation binds a
  host folder instead (the tar half seen failing only on a Mac, as in 520's
  `/var/tmp` half).
- A new case: a group with an old host `.cache` (a file, and a `0700` folder
  holding one) gets them copied at its first launch, readable and writable by
  the agent, the old folder untouched. Mutations: no copy; a copy as root with
  `cp -a` (seen failing only on a Mac).
- Cases 610 and 620: `rm` removes the cache volume too; `gc` collects an
  orphaned one.

After merge: the Mac agent runs the new case, 520, 610 and 620 on Colima.

## Docs

`AGENTS.md` (*Host directory mounts*: the volume, the copy, the walk exclusion;
*Manage container groups*; the Playwright and qmd paragraphs; the `UV_LINK_MODE`
reason), `docs/groups.md`, `docs/repos-and-mounts.md`, `docs/troubleshooting.md`
(several homes), the Playwright and qmd component docs where they name the
host path, `sandbox.sh`'s usage text, `CHANGELOG.md` (folded into the
Unreleased persistent-folders entry), and the 2026-11-26 backlog's macOS item
(answered).

## Calls made without the user

1. Its own volume (approach A), named `<prefix>-cache-<group>`, label
   `ai-containers.cache-group`, recognised by the label alone.
2. `~/.local/state` stays a bind.
3. The copy runs as the sandbox uid into a staging folder, moved up entry by
   entry; ownership given, not preserved.
4. Only the launch that made the volume copies; a failed copy warns and goes on;
   a killed one leaves a hidden staging folder (a stated limit).
5. The old folder is never removed; it is named once, at the copy.
6. `from:<group>` keeps copying the qmd index, now from the source's volume,
   volume to volume (changed while building: simpler than through the host).
7. Clearing the cache is `docker volume rm`; no new `group.sh` command.
8. Projects of one group with different `SANDBOX_UID`s: the top folder is
   chowned to each launch's uid, a tool's folder made by another uid stays
   that uid's. The same limit `~/.rvm` has.
