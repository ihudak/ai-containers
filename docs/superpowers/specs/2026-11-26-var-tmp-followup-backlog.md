# /var/tmp volume: open follow-ups (2026-11-26)

**Status:** OPEN, 2026-11-26, for the macOS re-check and a first WSL run,
below. The eight Linux items are done (2026-11-26, the Linux agent): each
item says how.

What is still open after the persistent agent scratch work (plans
2026-11-23-persistent-agent-scratch and 2026-11-25-var-tmp-volume) and its two
follow-up branches, all on `main` at 413284b. The task reviews of those plans
deferred 48 minor findings. 40 of them are fixed on `main`, ledgered in
`tests/falsify/survivors.txt`, or no longer apply since `/var/tmp` became a
Docker volume. The review's F3 leftover (`group.sh rm` of a contrived group
name taking another prefix's temp volume) is fixed by `group.sh`: `_vol_not_ours()`.
The 8 below were open. None broke normal use, and each was a small change.

## Linux: open items

Tests:

1. **T93 passes vacuously as root.** In `tests/test-launcher-dir-ro.sh`, T93's
   "a folder the agent made unlistable in the group's cache does not refuse
   the launch" uses mode 000 and 100 folders, which do not stop root, and CI's
   floor job runs the suite as root. Give it the `id -u` branch or `NOTE:` that
   T25 and T26 have.
   **Done:** where a mode-000 folder can be listed (root) T93 prints a
   `NOTE:` instead, as T62 does. Seen: `main`'s T93 passed as root against a
   `sandbox.sh` that walks the group's cache, and as an ordinary user the same
   `sandbox.sh` fails it.
2. **No test for an unlistable folder in a group scratch folder that is also
   mounted through `EXTRA_MOUNTS`** (`EXTRA_MOUNTS=$G/.cache` with a mode-000
   folder in it). Expected: the folder is read-only in both views, the
   `/workspace` one and `~/.cache`.
   **Done** in T93, test only, since the launcher already did this: a mode-000
   folder there is read-only in both views, each named in its `WARNING:`, and a
   mode-100 one refuses the launch, as in any writable mount. Seen red with the
   both-views loop in `launcher_ro_overlay()` skipping another mount of the
   same source.
3. **Untested: `group.sh rm` still tries the temp volume after the Ruby
   volume's removal fails.** The existing tests make each removal fail on its
   own (`.rmfail` markers in `tests/test-group-lifecycle.sh`), never the Ruby
   one followed by a check that the temp volume was still attempted.
   **Already done** before this list was written, by `4df8e30`: "rm whose Ruby
   volume removal fails still removes the temp volume, and leaves the
   directory" in `tests/test-group-lifecycle.sh`. It fails with a `break` after
   the Ruby volume's failure.
4. **Untested: two group names that map to one temp volume name** (`a/b` and
   `a_b` both give `ai-containers-vartmp-a_b`, `sandbox-common.sh`:
   `vartmp_volume_name()`). The second group's launch should be refused with
   "belongs to group a/b", which is safe. First check whether a group name can
   hold `/` at all. If it cannot, close this item.
   **Closed:** it cannot. `validate_group_name()` (`sandbox-common.sh`) allows
   lowercase letters, digits and dashes only, and the launch, `build.sh` and
   `group.sh rm` call it before any volume is named; on those characters
   `sanitize_volume_token()` changes nothing, so two groups never share a
   volume name.

Wording and docs:

5. **`agent-tmp.sh`'s "could not remove …; it is kept" is wrong after a partial
   `rm -rf`**, which removes part of the folder. Its freed-size figure is also
   rounded differently from `du -h` (no `T`).
   **Done:** the `NOTE:` says what is left of the folder is kept, and the freed
   size is rounded as GNU `du -h` rounds it, through `T`, checked against du
   9.12 for a table of sizes and for 3,007 random ones.
6. **`group.sh list --sizes` hides a partial size.** `du -sh` over a group
   directory with an unreadable folder exits 1, and the cell is left empty
   rather than showing the partial total. Show the partial total marked as
   partial, or at least say so in the comment above it.
   **Done:** the cell shows the total du printed, as `at least <size>`; a du
   that prints nothing, or anything that does not read as a size, is `?`.
7. **`docs/groups.md` has a ragged source wrap** in the paragraph on several
   homes sharing one docker (a line ending "them. Each home's `rm` and").
   **Done:** rewrapped.
8. **`AGENTS.md` ("Host directory mounts") repeats detail `docs/groups.md`
   carries**, so the two must be kept in step by hand. Trim `AGENTS.md` to what
   an agent needs, pointing to `docs/groups.md` for the rest.
   **Done:** the six paragraphs link to `docs/groups.md` for what a user sees
   and keep the rules a change must not break (10,010 characters become
   8,181).

## Other platforms

- **macOS (Colima, and Docker Desktop where a Mac has it):**
  `docs/superpowers/plans/2026-11-26-mac-recheck.md`. Report only. Its numbers
  decide two questions:
  - whether `~/.cache` becomes a per-group volume like `/var/tmp`;
  - whether the launch's three extra docker calls are trimmed.

  After the report, delete the git-ignored
  `.superpowers/sdd/2026-11-23-persistent-agent-scratch/`.
- **WSL (Docker Desktop on Windows): not run yet.** Nothing of this work has run
  there. A WSL agent, report only:
  - `PHASES=5 bash ./verify-on-host.sh`;
  - `tests/integration/run.sh --cases 520-agent-files-persist-across-restart,525-old-var-tmp-named-and-copyable,610-group-rm-removes-both,620-group-gc-collects-orphan`;
  - one launch of the same group from a second WSL distro. Docker Desktop is
    the docker several homes share, so that launch must print the `NOTE:` that
    names the temp volume as another home's (`sandbox-common.sh`:
    `_group_volume_shared_note()`), and `group.sh gc` in either distro must
    keep the other's volume.

## CI

The Tests and Integration runs for 413284b were still running when this was
written. That push gave `group.sh` a falsify shard of its own, because the
`rest` shard had been cancelled at its 90-minute cap. If `rest` or `group`
fails or nears the cap again, split again by the rule in
`.github/workflows/hermetic-checks.yml`. Do not raise the cap.
