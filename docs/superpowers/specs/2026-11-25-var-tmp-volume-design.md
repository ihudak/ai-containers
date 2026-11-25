# `/var/tmp` on a per-group Docker volume

**Status:** design, 2026-11-25. Follows
[2026-11-23-persistent-agent-scratch-design.md](2026-11-23-persistent-agent-scratch-design.md),
which merged `/var/tmp`, `~/.cache` and `~/.local/state` as group bind mounts
(main 164ea09) and owed a macOS check.

## Why

The macOS check came back on 2026-11-25 (Colima 0.10.3, Docker 29.5.2; Docker
Desktop not installed). Unix sockets and git work on the `/var/tmp` bind; GNU
tar does not. Tar holds back a symlink whose target contains `..`, writing a
mode-000 placeholder file first and replacing it at the end, and virtiofs
cannot open that placeholder: `tar: a/b/l: Cannot open: Permission denied`.
This is the bug that put `~/.rvm` on a volume. It is not exotic: Node.js
release tarballs carry such a link (`bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js`),
so an agent unpacking one into `$TMPDIR` fails on a Mac.

A follow-up check on the same Mac: tar FAILs on both binds (`/var/tmp`,
`~/.cache`) and PASSes on a named volume and on the container's own `/tmp`.

The user's decisions (2026-11-25):

- Only `/var/tmp` moves, to a Docker named volume per group, on every
  platform, as `~/.rvm` did. `~/.cache` and `~/.local/state` stay host binds
  and keep the macOS tar limit, which is documented, not fixed.
- The 30-day pruning of old container folders runs inside the new container's
  start-up, as the agent's user (approach B below).

## What it is

Every container of a group mounts the volume `<prefix>-vartmp-<group>` (the
prefix is `REPO_VOLUME_PREFIX`, `ai-containers` by default, as for the Ruby
volume) at `/var/tmp`. Everything the persistent-scratch design promised for
`/var/tmp` still holds, except what depends on it being a host folder:

- Each launch gets its own folder, `/var/tmp/<YYMMDD-HHMMSS-pid>`, mode 0700,
  and the agent's login and interactive shells get `TMPDIR` pointing at it
  (the profile script's rule is unchanged). Two containers never share one.
  An earlier container's folder stays at the same path in every later
  container of the group.
- Folders of containers that are gone and untouched for 30 days are removed,
  at most 50 per start, with the same `NOTE:` lines.
- The `ai-containers.tmpslot` label on the container stays: it is how a launch
  learns which folders are in use.

What changes for the user:

- The folders are no longer on the host. They are reached from any container
  of the group (`ls /var/tmp`), or, once the group has launched, with a
  throwaway container:
  `docker run --rm --entrypoint sh -v ai-containers-vartmp-<group>:/v <image> -c 'du -sh /v/*'`.
- `./group.sh list` shows the volume, `rm` removes it with the group, `gc`
  collects one whose group directory is gone.
- On a Mac, tar and everything else in `$TMPDIR` work, and run at the VM's
  disk speed rather than through virtiofs.
- The documented limit "several docker daemons share one `.var-tmp`, and
  `docker ps` sees only the current one" goes away: each daemon has its own
  volume, and `docker ps` on it sees every container that can use it.

## Approaches

- **A. Prune in a helper container** (the first proposal). Before each launch
  the launcher runs a short container of the project image with only the
  volume mounted and no network. Costs a container start per launch, 0.3 s
  measured on Linux and probably about a second on a Mac (not measured), and
  has root working inside files the agent writes (contained, since nothing
  else is mounted). Rejected for the cost and the root work.
- **B. Prune in the container's own start-up (chosen).** The launcher still
  asks `docker ps` which folders are in use and passes the list in; the
  entrypoint runs one script as the sandbox user that removes old folders and
  makes this launch's folder, before the agent's shell starts. No extra
  container, nothing root inside the agent's files, and the step that has to
  make the folder anyway (the host cannot make one inside a volume on a Mac)
  does both. Cost: the cleanup notes appear in the container's start-up
  output, and an image must be rebuilt before anything is pruned (the
  rebuild is needed for the folder step anyway).
- **All three folders on volumes** (the old plan's rule for any FAIL).
  Rejected by the user: `~/.cache` holds tool caches users inspect and clear
  from the host, and the tar limit there is accepted.
- **Keep the bind, document the limit.** Rejected: `$TMPDIR` is where tools
  unpack archives, so the limit would bite routinely.

## The volume

- Name `<prefix>-vartmp-<group>`, built the way `rvm_volume_name()` builds the
  Ruby one (same `sanitize_volume_token`). The `-vartmp-` infix keeps it out
  of `repo.sh`'s discovery (`<prefix>-repo-`) and of the Ruby volume code
  (`<prefix>-rvm-`).
- Labels at creation: `ai-containers.vartmp-group=<group>` and, when the
  home's id is known, `ai-containers.owner=<id>` (as `rvm_volume_ensure()`
  does). Every temp volume is new, so none predates the labels:
  `group.sh` recognises a temp volume **by its label**, never by its name
  alone. (A name match alone is what let a nested `REPO_VOLUME_PREFIX` mistake
  one repo's volume for another's, REPO-11.)
- Made by the launch that first needs it; a volume another home made gets the
  same `NOTE:` the Ruby volume gets (`_rvm_shared_note()`, generalised to name
  which volume it is). A volume that cannot be made **refuses the launch**:
  `docker run -v name:/var/tmp` would otherwise create it itself, unlabelled,
  and `group.sh` would never see it.
- A volume of that exact name **without the label, or labelled for another
  group, refuses the launch** too. Labels cannot be added afterwards, and
  mounting it would give the group a temp volume `group.sh` never lists or
  removes. It is easy to make by accident: any `docker run -v <name>:…` before
  the group's first launch, or with a mistyped group, creates the volume
  unlabelled. The refusal says so and gives the `docker volume rm` that clears
  the way, to run once nothing in it is needed. (Under nesting
  `REPO_VOLUME_PREFIX` values the name can also be another prefix's volume,
  REPO-11's shape, which is why the label decides.)
- Mounted `-v <volume>:/var/tmp` with the group's other mounts. The launcher no
  longer makes `$group/.var-tmp` and no longer binds it.

Measured on this Linux host (Docker 29.9.2): a new empty volume mounted at
`/var/tmp` comes up `root:root 1777`, copied from the image's own `/var/tmp`,
even when another container mounted it elsewhere first; uid 1000 can make its
0700 folder there, and a tar archive with a `..` link unpacks.

## The launch's folder and the pruning

The launcher passes, besides `AI_AGENT_TMPDIR=/var/tmp/<slot>` (unchanged), a
second variable with the folder names of the running containers: the
`ai-containers.tmpslot` labels from one `docker ps`, each kept only if it has
the folder-name form. When `docker ps` fails it passes a value meaning
"unknown", and the start-up then removes nothing. The launcher runs that
`docker ps` on every launch now (today it asks only when it found a candidate),
since it cannot look inside the volume first.

The entrypoint gains one step, in all three modes, after the sandbox user
exists and before the services start:

1. **As root, only when the launcher passed the new variable** (so `/var/tmp`
   is the volume): set the mount's top folder to `root:root`, mode 1777. Only
   that folder, a mount point nothing in the container can swap, never
   anything in it. A volume first mounted at `/var/tmp` already comes up so
   (measured, below); this covers one something else wrote into first (a
   `docker run -v <name>:/v` that made a file there), where Docker copies
   nothing and the top folder stays `root 0755`, closed to the agent. Without
   the variable (an older launcher with a newer image, `/var/tmp` a host
   bind) it does nothing: chowning a host folder to root would lock the user
   out of it.
2. **As the sandbox user, also only when the launcher passed the new
   variable**, with a fixed environment (`PATH` and the two launcher
   variables) and not `container.env`. (`as_sandbox_user` gives
   `container.env` back, so this step needs its own `runuser` with `env -i`,
   or an option to that function.) It runs a new script, `agent-tmp.sh`,
   baked into the image. The script prunes, then makes this launch's folder
   with `mkdir -m 0700` (no `-p`: a name that exists is never reused).
3. If the folder could not be made: a `WARNING:`, and the entrypoint unsets
   `AI_AGENT_TMPDIR` before the shell starts, so the shell keeps `/tmp`
   instead of using a folder it did not make. The start is never refused over
   this.

The pruning rule is today's `agent_tmp_prune()`, moved into the script, with
two changes. Unchanged: only per-container names (`^[0-9]{6}-[0-9]{6}-[0-9]+$`),
never a link or a file; one `find` lists at most 500 old candidates; at most 50
are checked and removed per start; a folder with anything changed in it
within 30 days is kept and touched, as is one `rm` could not remove; a running
container's folder is never removed, nor this launch's; anything uncertain is
kept; the `NOTE:` texts keep their meaning.

First change: **only folders owned by the script's own uid are candidates.**
The host user ran today's pruning and owned every folder. In the volume, a
folder another uid made (a project in the group with another `SANDBOX_UID`)
can be neither removed nor touched by this uid under the sticky top folder:
it would fail at every start and, 50 of them, use up the cap for good. That
uid's own containers prune it.

Second change: **"untouched" is measured by change time (ctime), not
modification time.** Tar, `cp -p` and `rsync -a` can give a folder and its
files old modification dates, which is why the launcher today touches a
container's folder when it exits. A host step at exit is no longer possible
without a container run, but ctime cannot be set back by anyone without the
clock: setting an old date is itself a change, at the current time (measured:
`touch -d 2020-01-01` left ctime at the moment of the call). So the exit touch
(`_agent_tmp_touch()`) goes. What this gives up: "untouched" now counts from
the last change, not from the container's exit. A container that ran for over
30 days without changing its folder can lose that folder at the first start
after it exits. This is stated in the docs as a limit.

Because ctime cannot be set back, the script takes the current time as an
argument that only the tests pass. The entrypoint never passes it, and it is
never read from the environment, so `container.env` cannot shorten the 30
days.

## An old `.var-tmp`: named, not copied

The bind version of `/var/tmp` (main 164ea09, 2026-11-24) has never been in a
release: v0.11.0 predates it and its CHANGELOG entry is still under
Unreleased. Only a checkout of main since then has a `$group/.var-tmp`, and on
the maintainer's Linux host none exists. A copy into the volume would need
its own failure handling (a copy that fails, a launcher killed mid-copy, files
owned by the uid a Mac's file sharing shows), all for that population. So
there is no copy.

Instead, a launch that finds `$group/.var-tmp` prints a `NOTE:` that it is no
longer mounted, and gives two commands: the `docker run` that copies it into
the group's volume, and the `rm -rf` that removes it once nothing in it is
needed and no container of the group runs. The launcher never deletes it. The
note repeats at every launch until the folder is gone.

## `group.sh`

A group now owns a directory and up to two volumes, Ruby and temp. The Ruby
volume's code is generalised to both, not copied:

- `list`: each group with both volumes and their state (`present`, `in use`,
  `none`), sizes with `--sizes`; orphans of both kinds, with the same owner
  notes.
- `rm <group>`: the directory and both volumes. Each volume follows today's
  rules on its own: one another home made is kept and named; one a running
  container mounts, or whose use docker cannot report, refuses the whole
  `rm` before anything is removed. A volume of the temp name without this
  group's label is named, with its `docker volume rm`, and never removed.
- `gc`: orphaned volumes of both kinds, this home's only unless `--all`.
- The usage text and the header comment say what a group owns.

`project.sh rm` is unchanged: it names a group no other project uses and
never removes it.

## Other launcher changes

- `_group_scratch_mount()` no longer lists `.var-tmp` (there is no such bind);
  `~/.cache` and `~/.local/state` keep their exclusion from the launcher walk.
- `agent_tmp_prune()`, `_agent_tmp_touch()`, `_agent_tmp_made` and its call in
  the `EXIT` trap, and the host `mkdir` of the folder are removed.
- An image built before this change, run by this launcher: the volume is
  mounted, no folder is made, so `TMPDIR` stays `/tmp`, and nothing is pruned.
  The launcher's existing provenance warning already says the image is older
  than its files; nothing else is added.

## Constraints

- One code path on every platform, no macOS branch (the rvm precedent).
- Bash floor 5.1; `agent-tmp.sh` runs in the container but also on the host in
  the hermetic suite, which runs on macOS with BSD userland, so it stays
  portable between GNU and BSD `find`, `touch`, `du`, `stat`, as
  `agent_tmp_prune()` is today.
- `agent-tmp.sh` is copied into the image by the Dockerfile, so it joins
  `AI_CONTAINERS_SHARED_FILES` (`shared-files.sh`).
- Code is cited by snippet, never line number (`tests/test-code-references.sh`).
- Every new integration assertion is seen failing, through a patch under
  `tests/integration/mutations/`.
- `tests/falsify/targets.conf` is derived and checked: the new script and the
  new entrypoint function get rows, with their oracle tests.
- `AGENTS.md` is the only instruction file edited; `CHANGELOG.md` gets an
  Unreleased entry.

## Goals

- GNU tar, and anything else virtiofs breaks, works in `$TMPDIR` on a Mac.
- Nothing in an old `.var-tmp` is deleted; the launcher names it and how to
  copy from it.
- No launch gets slower by a container run; only a group's first launch after
  the change pays for creating the volume.
- No root process works inside the agent's files.

## Non-goals

- `~/.cache` and `~/.local/state`: they stay binds, with the macOS tar limit
  documented.
- A `group.sh` command to browse or clean the temp folders; the docs give the
  `docker run` and in-container commands.
- Any change to the `TMPDIR` rules in the profile script, to the folder names,
  or to `/tmp`, which stays disposable.

## Anti-goals

- A volume made unlabelled by `docker run`, which `group.sh` would never find.
- Removing anything whose state is uncertain: a `docker ps` that failed, a
  name of another form, a link.
- A `container.env` setting that changes what the pruning removes.

## Testing

Hermetic:

- `tests/test-agent-tmp.sh`, rewritten: `agent-tmp.sh` run directly on
  temporary folders, the clock passed as the argument. Every rule above:
  name forms, links and files left alone, the 500 and 50 bounds and their
  `NOTE:`s, kept-for-content folders touched, an `rm` that fails, the running
  list, an "unknown" list removing nothing, this launch's name never removed,
  another uid's folders never candidates; the folder made 0700, an existing
  name not reused and reported by exit code.
- The launcher, with the fake `docker`: the volume created with both labels
  and mounted at `/var/tmp`; no host `.var-tmp` made or bound; the two
  variables passed, "unknown" when `docker ps` fails; a launch refused when the
  volume cannot be made, and when one of its name exists unlabelled or
  labelled for another group; the `NOTE:` for an old `.var-tmp`, and none
  without one.
- The entrypoint step, extracted and run like the other entrypoint functions
  (`tests/test-entrypoint-wiring.sh`): both parts do nothing without the
  launcher's variable; the script runs as the sandbox user without
  `container.env`; `AI_AGENT_TMPDIR` is unset for the shell when the folder
  could not be made.
- `tests/test-group-lifecycle.sh`: the temp volume in `list`, `rm` and `gc`,
  the owner rules and the in-use refusal for each volume.
- Isolation, as `tests/test-rvm-volume.sh` does for the Ruby volume: `repo.sh`
  never sees a temp volume, and the Ruby and temp volume code never take each
  other's.

Integration (each new assertion with a mutation):

- Case 520: `/var/tmp` is a Docker volume named for the group (`docker
  inspect`, mount type `volume`), and an archive holding a `..` link unpacks
  with GNU tar into `$TMPDIR`. The host-file check for `/var/tmp` is replaced
  by the existing check that the next container reads the same bytes. A new
  mutation mounts a host bind instead, which the volume assertion catches on
  Linux; the tar assertion can be seen failing only on a Mac, under that
  same mutation, as case 460 has its host-dependent half. The existing
  `520-var-tmp-not-mounted.patch` is updated to the new mount.
- Cases 610 and 620: `group.sh rm` removes the temp volume too; `gc` collects
  an orphaned one.
- Volumes are global to the daemon, so the harness must keep the cases' temp
  volumes apart from a developer's real groups (its own `REPO_VOLUME_PREFIX`,
  as the Ruby cases need), and remove them afterwards.

After merge: the Mac agent re-runs its tar check in `$TMPDIR`, case 520 and the
hermetic suite on Colima, and on Docker Desktop if a Mac has it. Then
`.superpowers/sdd/2026-11-23-persistent-agent-scratch/` is deleted.

## Docs

- `AGENTS.md`: the *Host directory mounts* paragraph on the three folders (the
  volume, the start-up's folder and pruning, ctime, the note for an old
  `.var-tmp`), the walk exclusion, the *Manage container groups* section, and
  the Ruby volume paragraph where it explains why `~/.rvm` is a volume.
- `docs/groups.md`: the temp-folder section, *Seeing and reclaiming the
  space* (from a running container of the group, or a `docker run` with
  `--entrypoint` and the glob run inside the container, never before the
  group's first launch, since that run would create the volume unlabelled),
  the two limits (the several-daemons one goes; the ctime one is added), the
  macOS tar limit for `~/.cache` and `~/.local/state`.
- `docs/repos-and-mounts.md`: its table row for `/var/tmp`.
- `docs/troubleshooting.md`: "Several homes on one docker" covers the temp
  volume as well as the Ruby one.
- The Dockerfile comment above the profile script: the folder is made by the
  start-up, no longer by the launcher.
- `CHANGELOG.md`: folded into the Unreleased entry for the persistent folders,
  which has not shipped: `/var/tmp` is a volume, the rebuild and
  `./sync-to-projects.sh` an existing project needs, the ctime rule, the note
  for an old `.var-tmp`.

## Left to the builder

- Function and variable names (the volume-ensure function, the running-list
  variable and its "unknown" value, the entrypoint step), within the names
  fixed above (`agent-tmp.sh`, `<prefix>-vartmp-<group>`,
  `ai-containers.vartmp-group`).
- The exact place of the entrypoint step between the user setup and
  `run_services`, the wording of new `NOTE:`/`WARNING:` lines, and the column
  layout of `group.sh list`.
- How the script compares change times against the clock argument (for
  example `find -cnewer` against a reference file dated with `touch`), as long
  as GNU and BSD agree.

## Calls made without the user

Listed so they can be checked:

1. Change time replaces modification time and the exit touch goes; the limit
   for a container that ran over 30 days without changing its folder is
   documented, not fixed.
2. A volume that cannot be made refuses the launch.
3. A folder that cannot be made does not refuse the start: a `WARNING:` and
   `/tmp`.
4. The pruning runs without `container.env`, and its clock is an argument, not
   an environment variable.
5. No copy of an old `.var-tmp` into the volume: it never shipped in a
   release, so a launch names the folder and how to copy from it, and never
   deletes it.
6. Temp volumes are recognised by their label only; one of the right name
   without it (or labelled for another group) refuses the launch, and
   `group.sh rm` names it without removing it.
7. Only the script's own uid's folders are pruned; another uid's are left to
   that uid's containers.
