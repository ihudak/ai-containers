# Plan: `~/.cache` on a per-group Docker volume

Design: [2026-11-27-cache-volume-design.md](../specs/2026-11-27-cache-volume-design.md).
Branch `feat/cache-volume`, one commit per task, each with its tests green.
Do not edit tracked files while `tests/run-all.sh` runs.

## Task 1 — volume helpers (`sandbox-common.sh`)

- Generalise `vartmp_volume_ensure()` into one function for the label-decided
  group volumes, taking the kind (`temp`, `cache`): name, label key, the words in
  its `ERROR:` lines. `vartmp_volume_ensure()` stays as a thin caller (its
  callers and tests keep working).
- Add `cache_volume_name()`, `cache_volumes()`, `cache_group_from_volume()`,
  `cache_volume_ensure()`; the ensure tells its caller whether this launch made
  the volume.
- `_group_volume_shared_note()` learns `cache`; `rvm_volume_ensure()` refuses a
  volume carrying a cache label as it refuses a temp one.
- Tests: `tests/test-vartmp-volume.sh` unchanged and green; new
  `tests/test-cache-volume.sh`, helper half.

## Task 2 — the launch (`sandbox.sh`, `sandbox-common.sh`)

- Mount `-v <cache volume>:<home>/.cache`; stop making and binding
  `$group/.cache`.
- The one-time copy (`sandbox-common.sh`, beside the rvm migration): only when
  the ensure made the volume and `$group/.cache` is a non-empty directory; root
  chowns the top and makes the staging folder; `setpriv` as the sandbox uid runs
  `cp -dR --preserve=mode,timestamps,links`; entries moved up; staging removed;
  `--network none`, `--pull=never`, SELinux option, `docker_bind()`. Lines before
  and after; a failure warns and the launch goes on.
- `_group_scratch_mount()`: drop `.cache`. Comments moved to the volume.
- Tests: `tests/test-cache-volume.sh`, launch half; update
  `tests/test-agent-tmp.sh`, `tests/test-playwright.sh`,
  `tests/test-launcher-dir-ro.sh` (T93), `tests/test-tool-config-mounts.sh`.

## Task 3 — `from:<group>` keeps the qmd index

- In the bootstrap, when the source group's cache volume exists and is that
  group's by its label, copy its `qmd/` into the new group's host `.cache/qmd`
  (container run as the sandbox uid); otherwise copy the host folder as today.
- Tests: `tests/test-cache-volume.sh`; `tests/test-agent-tmp.sh`'s bootstrap
  check still green.

## Task 4 — the start-up (`entrypoint.sh`): nothing

Built (`chown_cache_root()`, gated on a launcher variable) and dropped: the
start-up's `find "$home_dir" -xdev -exec chown` already gives the volume's mount
point to the sandbox user (measured on Colima).

## Task 5 — `group.sh`

- The kind dispatch gains `cache` (label-decided like `temp`); `list` columns,
  `--sizes`, `rm`, `gc`, usage and header.
- Tests: `tests/test-group-lifecycle.sh`; isolation in `tests/test-rvm-volume.sh`
  and `tests/test-vartmp-volume.sh`.

## Task 6 — integration

- Check the harness removes `it-<run>-cache-*` volumes as it does the others.
- Case 520: `~/.cache` a volume named for the group, a `..`-link tar unpacks,
  bytes persist; update `520-cache-not-mounted.patch`; add a bind mutation.
- New case 530: an old host `.cache` copied at the first launch, readable and
  writable by the agent, the old folder untouched; mutations: no copy, a root
  `cp -a`.
- Cases 610 and 620: the cache volume removed and collected; mutations.
- Run them on Colima; note which halves can be seen failing only on a Mac.

## Task 7 — docs

`AGENTS.md`, `docs/groups.md`, `docs/repos-and-mounts.md`,
`docs/troubleshooting.md`, component docs naming the host path, `sandbox.sh`
usage, `CHANGELOG.md` Unreleased, the 2026-11-26 backlog's macOS item.

## Task 8 — verification

`tests/run-all.sh` on the host (background), shellcheck, the dialect lint,
`tests/test-code-references.sh`, `tests/test-layer-containment.sh`; the
integration cases of task 6. Report what ran and what did not (Phase 5's floor
and symlinked arms, the falsify tier: Linux-side).
