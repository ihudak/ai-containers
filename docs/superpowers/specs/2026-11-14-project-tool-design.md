# project.sh — removing, moving and tidying a project's container setup

**Status:** IMPLEMENTED 2026-11-15 on branch feat/project-tool; approved 2026-11-14; amended while planning (the image after `mv`,
the `WORKTREE` record), see the plan
`docs/superpowers/plans/2026-11-14-project-tool.md`; amended in the final review
(what `gc` before `mv` loses; working copies labelled by owner, the user's
choice; `gc --all`). The constraint "`project.sh` registered as a falsify
target" was not met when this said IMPLEMENTED: the row was deferred, its one
oracle too slow for CI (feature-gaps review GAP-28). Met 2026-11-18: the oracle
is four files by command, and `project.sh` has six CI shards of its own, one
slice of its mutants each (`run.sh --slice`).

Date: 2026-11-14.

## Why

Two of the three things a project's container setup is built from have a
management tool: groups have `group.sh`, repo volumes have `repo.sh`. The
project itself — its `.ai-containers/` working copy and everything that points
at it — has only `project-init.sh` to create it and `ai-containers-report.sh`
to read it. Removing or moving one is done by hand, and every step is easy to
miss:

- the `<project>/.ai-containers/` directory itself;
- its line in this checkout's `projects.conf`;
- its line in `~/.ai-containers/image-projects.conf`, which `build.sh` writes;
- its `:rwcopy` working copies, Docker volumes named after the directory it
  was launched from (`repo_workcopy_volume_name()`, `ws_tag` in `sandbox.sh`),
  which outlive the project and can hold unpushed work;
- its image.

The user removed several lab projects this way: volumes and groups with the
scripts, then directories and both registry lines by hand. On another machine
they had an agent move several projects' setups out of their repositories into
`~/dev/workspace/<name>`, because those were multi-repo containers whose
working directory should not be one of the repos. And on 2026-11-14 two stale
`image-projects.conf` lines were found, written by test builds from worktrees
that no longer existed — nothing removes such lines today.

## What it is

A new base-repo script, `project.sh`, with these commands:

| Command | Does |
|---|---|
| `project.sh init …` | runs `project-init.sh` with the same arguments |
| `project.sh report …` | runs `ai-containers-report.sh` with the same arguments |
| `project.sh sync …` | runs `sync-to-projects.sh` with the same arguments *(my call; drop it if unwanted)* |
| `project.sh rm <project>` | removes a project's setup (below) |
| `project.sh mv <project> <new-dir>` | moves a project's setup (below) |
| `project.sh gc` | removes what points at projects that are gone (below) |

**`project-init.sh` and `ai-containers-report.sh` stay as they are**, and the
delegating commands pass arguments through and return their exit status
unchanged. `project-init.sh` is also a library: `multiline-env.sh`,
`migrate-runme.sh` and `sync-to-projects.sh` source it for `emit_launcher` and
`emit_env_list`, and 26 tests and the docs call it by name. Folding its code
into `project.sh` would cost much and change nothing a user sees. The docs
present `project.sh` as the way in from now on.

Like `project-init.sh`, `project.sh` acts on **this checkout's**
`projects.conf`, so it is base-repo only and not in
`AI_CONTAINERS_SHARED_FILES`.

**Naming a project** *(my call)*: by its path, in any spelling that resolves to
a line of `projects.conf`; or by the project name the report prints, only when
exactly one registered project has it. Anything else is refused, listing the
candidates.

## `project.sh rm <project>`

Decided with the user:

- Removes the project's `.ai-containers/` directory and its lines in
  `projects.conf` and `~/.ai-containers/image-projects.conf`.
- Removes its image, the narrow way `remove_replaced_image()` does: no
  `--force`, so an image a container still references survives, and never a
  broad prune. Only an image whose `ai-containers.project` label is **this**
  project's id (`ai_containers_project_id()`): `IMAGE_NAME` is portable, and a
  tag that names a base image or another project's image is named and left
  alone.
- Removes its `:rwcopy` working copies — the volumes whose
  `ai-containers.launch-dir` label lies inside the project (normally its
  `.ai-containers/`, where `runme.sh` launches from). A launch directory inside
  a **nested** registered project belongs to that one.
- Before anything is removed it prints everything it will remove, and for each
  working copy what would be lost: unpushed branches, a stash, uncommitted
  changes — as `repo.sh reset` prints at-risk branches. It then asks. `--yes`
  skips the question, never the listing. A "yes", or `--yes`, removes
  everything listed, at-risk copies included, as `repo.sh reset --yes` does.
- *(My call, following `repo.sh reset`'s "unpushed count unknown")* A working
  copy whose state cannot be checked is listed as **not checked** and counted
  at risk, never as safe: one with no URL to compare against (the URL is the
  base volume's `ai-containers.source`; a working copy carries none), a
  `path`-type repo's (no remote), one whose remote cannot be reached (`STALE`),
  an unlabelled one, or one whose base volume is gone. So `rm` needs no network
  to finish: an unreachable remote makes a copy "not checked", not a reason to
  stop.
- Leaves the project's group and the repo volumes it attached alone: other
  projects may use them. It names any that no registered project uses any
  more, each with the `group.sh rm` / `repo.sh rm` command that removes it.
- Refuses while a container of that project is running.

My calls:

- The project's root directory is removed only if it is empty once
  `.ai-containers/` is gone (a `~/dev/workspace/<name>` setup leaves nothing
  else behind). Otherwise it stays, with whatever else is in it.
- The `/.ai-containers/` line in the project's `.gitignore` stays.
- It can be run again after a partial failure and finishes the job: the steps
  are ordered so that a failure part-way leaves either the registry line (so a
  re-run finds the project) or nothing to point at (so `gc` finds the rest).

## `project.sh mv <project> <new-dir>`

`<new-dir>` is the project's new root; the setup lands in
`<new-dir>/.ai-containers/`. Decided with the user:

- Moves `.ai-containers/` there, creating `<new-dir>` if needed, and rewrites
  the project's line in `projects.conf` in place. The project keeps its
  `IMAGE_NAME`, its group and its settings. The agent's output directories
  (`.agent-blocked/`, `.agent-discovery/`) move with it.
- **Already moved by hand**: if `<project>` no longer holds `.ai-containers/`
  and `<new-dir>` does, `mv` does everything but move the files: it updates the
  records, moves the working copies and adds the old directory to
  `EXTRA_MOUNTS`, all as below. This is also how a project whose whole
  directory the user renamed is repaired.
- *(My call)* In that mode `<project>` may be a path `projects.conf` no longer
  lists, because `gc` removed its line: `mv` then registers `<new-dir>` and
  finds what to repair by the old path itself — the working copies whose
  `ai-containers.launch-dir` lies under it, and the `image-projects.conf` line
  that names it (an id is a keyed hash of the path string,
  `ai_containers_project_id()`, so it is computable for a path that is gone).
  *(Corrected in the final review: this said running `gc` first loses nothing
  a later `mv` needs, which was false.)* What survives `gc`: the moved
  `.ai-containers` and its settings, and nothing else `mv` needs — `gc` drops
  the old `projects.conf` line, which `mv` does not need. What does not: the
  working copies, whose launch directory is gone, which `gc` removes, unpushed
  work and all; and the old image with its `image-projects.conf` line, which
  `mv` would have removed anyway (the next build rebuilds it from cache). So
  after `gc`, `mv` only registers the new place, and says no copy is left to
  carry; `gc` says, on the vanished project's line and on each of its copies'
  lines, to answer no and run `mv` first.
- **The image** is tied to where the project lived (its
  `ai-containers.project` label). *(Settled while planning, replacing an
  earlier call that changed `build.sh`.)* `mv` removes that image — only when
  its label is the old location's id, the narrow way `rm` does — and then the
  old location's `image-projects.conf` line, which no image carries any more.
  The next `./build.sh` (which `runme.sh` runs before every launch) builds the
  image again: measured 2026-11-14, BuildKit's cache survives `docker rmi`, so
  every step comes from the cache. With no image under the tag the retag guard
  has nothing to refuse, so this also covers the case where the old location's
  nearest surviving directory is empty. `mv` says that the next build rebuilds
  the image. Where the image cannot be removed (a stopped container still
  references it), both stay and `mv` says so; the next build then replaces the
  image with a NOTE, and `gc` drops the line later. `build.sh` is not changed.
- **Working copies** are named after the launch directory, so after a move the
  next launch would start fresh copies and strand the old ones with any
  unpushed work. Docker cannot rename a volume, so `mv` copies each working
  copy to the name and `ai-containers.launch-dir` label of the new launch
  directory, checks the copy, then removes the old volume.
- **The directory it left**: when it still exists (the usual case, moving out
  of a repository), `mv` adds it to `EXTRA_MOUNTS` in `sandbox.local.env`,
  written one entry per line (`emit_env_list`), unless an entry already covers
  it, so the container still sees it. The `/.ai-containers/` line in its
  `.gitignore` stays.
- Refuses while a container of that project is running.

My calls:

- **A name clash is refused before anything moves.** `EXTRA_MOUNTS` and the
  working directory both land at `/workspace/<basename>`, and the launcher
  refuses two mounts of one basename. Moving `~/dev/app/.ai-containers` to
  `~/dev/workspace/app` and adding `~/dev/app` would make every launch fail, so
  `mv` refuses, naming the clash and asking for another `<new-dir>`.
- `<new-dir>/.ai-containers` that already exists (outside the already-moved
  case) is refused.
- A repository whose index tracks files under the moved `.ai-containers/` is
  told that those files now show as deleted there; committing that is the
  user's.
- **The project must be buildable and launchable after `mv`, with no manual
  edit.** Deleting the old `image-projects.conf` line while the old image
  keeps its tag would break that: `build.sh` refuses an image whose project id
  that file does not name (ENV-8). So the line goes only after the image does
  (above), and a test proves the retag guard passes right after `mv`.

## `project.sh gc`

My calls:

- Drops `projects.conf` lines whose project has no `.ai-containers/`, and
  `image-projects.conf` lines whose path is gone — but an `image-projects.conf`
  line only once **no local image carries its id**, or the next build of a
  moved project would be refused (above).
- Skips, and names, a `projects.conf` line whose path may be on an unmounted
  drive (its nearest existing directory is empty, or a removable-media root),
  as the retag guard does; the drive may come back.
- Lists the working copies whose launch directory is gone, with what each
  would lose (checked as for `rm`), and removes them on confirmation (`--yes`
  as for `rm`).
- Lists each local image whose `ai-containers.project` id `image-projects.conf`
  maps to a path that is gone, and removes it on confirmation, the narrow way
  `rm` does (no `--force`; one a container still references survives). This
  completes, for projects deleted by hand, what `rm` does for the image. Then
  that image's line goes by the rule above.
- For every vanished project it lists, the listing says that a project that
  was **moved** rather than deleted should be repaired with
  `project.sh mv <old> <new>` instead: answering "no" keeps everything, and
  after `gc` `mv` only registers the new place, the working copies gone (above);
  each copy launched from the vanished project says so on its own line.
  Removing the old image of a project moved by hand costs only a rebuild.
- *(Added in the final review; labelling by owner is the user's choice.)* One
  Docker daemon can serve several homes — Docker Desktop shares one between WSL
  distros, where one user name gives the same paths — so a launch directory
  that is gone here may exist in another home. A launch labels each working
  copy it makes `ai-containers.owner=<id>`, the keyed hash of
  `ai_containers_project_id()` over a fixed string (per `HOME`, revealing
  nothing). `gc` offers this home's copies; keeps another home's; and offers
  one with no owner label (made before the label) only under a path this home's
  registries know — a `projects.conf` root, gone or not, or a project
  `image-projects.conf` maps. `rm` and `mv` never take another home's copy, and
  take an unlabelled one by its launch directory, as before. `gc --all` offers
  every copy whose launch directory is gone, whoever made it — for copies from
  before the label, or from a distro or user that no longer exists — with the
  same listing, question and keeps (an unmounted drive, a container using it).
  `repo.sh gc` and `list --copies` do not read the label yet.
- Prints what it would do first, every run.

## Constraints

These come from how the project already works; the builder should not need to
rediscover them.

- **Never run git on a working copy's own `.git`.** It is agent-writable, and
  git reads more from a `.git` than any guard can enumerate. The at-risk
  listing reuses `repo-git-reset.sh`'s read-only `inspect` pass, which clones
  the recorded URL and reads the volume's refs as plain files. *(Settled while
  planning.)* `inspect` gains one record, `WORKTREE|clean|changed|?`, which
  compares the checkout's files with its branch's commit through the private
  clone's git, as `pull` already does, so uncommitted and untracked work can be
  listed; a change only staged and then undone in the file is not seen.
  `git_helper_run` takes a working copy's URL from its base volume's
  `ai-containers.source`, and `project.sh` reaches it by sourcing `repo.sh`,
  which gains a sourcing guard like `project-init.sh`'s.
- A project directory is agent-writable. Writes go through `project-files.sh`'s
  no-follow helpers, a `.ai-containers` that is itself a link is refused (as
  `sync-to-projects.sh` refuses it), and a removal that cannot finish (a
  directory made unreadable) is reported, not retried with force.
- Image removal stays narrow (above). Build cache is never pruned.
- A `docker run` that bind-mounts a host path passes `selinux_security_opt()`
  and hands the path over through `docker_bind()`; a copy between volumes does
  not need the option. Runs of a project image pass `--pull=never`.
- Bash 5.1 floor, BSD userland on macOS, shellcheck and the dialect lint as for
  every script. Code is cited by what it says, never by line number.
- Tests per [docs/testing.md](../../testing.md): a hermetic test with a fake
  `docker` for every refusal and every removal (as `tests/test-repo-destructive.sh`
  and `tests/test-image-retag.sh` do), `project.sh` registered as a falsify
  target, and an integration case for what needs a real daemon (copying a
  working copy) — each case seen failing.
- Docs: the Commands section of AGENTS.md, README, `docs/multiple-projects.md`,
  and a CHANGELOG entry.

## Goals

- Removing or moving a project is one command that leaves nothing behind and
  nothing pointing at the old place.
- Stale records — including ones left by test builds — can be cleaned up
  without opening a file.
- One front door for project-level work (`init`, `report`, `sync`, `rm`, `mv`,
  `gc`), matching `group.sh` and `repo.sh`.

## Non-goals

- Removing groups or repo volumes. `rm` names unused ones; their own tools
  remove them.
- Moving a repository. The user moves it; `mv` then repairs the records.
- Renaming a project or its `IMAGE_NAME`.
- Merging `project-init.sh` or `ai-containers-report.sh` into `project.sh`.
- Managing another checkout's projects, or another machine's.

## Anti-goals

It has failed, even if it works, if it:

- removes anything it did not list first;
- removes a working copy without having named it as at risk or not checked
  when it holds unpushed or uncommitted work;
- removes an image or a volume another project uses;
- follows a link an agent planted into a place outside the project;
- leaves a moved project that does not build or launch without a manual edit.

## Left to the builder

- **How "a container of this project is running" is detected.** Launched
  containers carry no project label today. Candidates: a running container's
  mounts include the project's `.ai-containers/` or root, or its image is the
  project's. Adding a label in `sandbox.sh` is an option if neither is sound.
- How a working copy is copied and checked, and how a move across filesystems
  is done (copy, check, then remove).
- How "no registered project uses it" is computed for a group or a repo
  volume, resolved the way the report resolves settings (`sandbox.local.env`
  over `sandbox.env`, and `@name` pointers as well as `REPOS`).
- Wording, prompts and output layout, following `group.sh` and `repo.sh`.
