# Agent work that survives a container restart — `/var/tmp`, `~/.cache`, `~/.local/state`

**Status:** APPROVED 2026-11-23.

Date: 2026-11-23.

## Why

Containers run with `--rm`. What survives a restart is what is mounted: the
group's directories (`~/.claude`, `~/.codex`, `~/.ai-tools`, `~/.cache/qmd`,
…) and each host directory or repo volume mounted *inside* `/workspace`.
Everything else — `/tmp`, the rest of `~/.cache`, the rest of `~/.local`, and
the `/workspace` umbrella itself, which is an in-image directory — lives in the
container layer and is gone when the container exits.

On 2026-11-21/23, in the `mywisy` group, a `/product-workflows:prd-ground
MWC-001-01` run (294 requirements against 7 repositories, about 156 verifier
agents, roughly three quarters done) paused when the user's usage limits ran
out. The user quit, and started a new container the next day. Lost:

- `/tmp/claude-1000` — Claude Code's own scratch folder, which holds every
  background agent's output (about 5,700 references in the session
  transcript);
- `~/.cache/shipwright-pg01` — the run folder the agent chose, believing
  `~/.cache` was kept.

It was recovered only by replaying the session transcripts, which survive
because `~/.claude` is group-mounted. The agent then moved its state to
`/workspace/.prd-ground-MWC-001-01`, believing `/workspace` was kept because
every folder inside it is; that too was in the container layer. It ended up in
`~/.claude/projects/<session>/`, found by trial and error with `findmnt`.

Agents cannot tell which paths survive, and they guessed wrong twice.

**The user's constraint:** the fix must be agent-neutral — "today it's Claude,
tomorrow it's codex". Nothing may need configuring per agent.

## What it is

Three places become persistent, each a directory in the group, bind-mounted
like the group's other directories:

| In the container | From the group (`~/.ai-containers/<group>/`) | Replaces |
|---|---|---|
| `/var/tmp` | `.var-tmp` | — |
| `~/.cache` | `.cache` | the `~/.cache/qmd` and `~/.cache/ms-playwright` mounts |
| `~/.local/state` | `.local/state` | the `~/.local/state/claude` mount |

and **`TMPDIR=/var/tmp/<container>`** is set for the agent's shell and
everything it starts.

`/tmp` itself is unchanged and stays disposable.

**One `TMPDIR` folder per container** (my call). The whole `.var-tmp` is
mounted at `/var/tmp`, so every earlier container's folder is still there at
the same absolute path — a path recorded in a transcript still resolves after
a restart — but each container writes into its own. That avoids what ruled out
a persistent `/tmp`: two containers of a group running at once never share a
temp folder, and PIDs, which repeat across containers, never name each other's
files; a new container starts with an empty `TMPDIR` rather than the last one's
stale sockets and locks. `<container>` is the container's name, shortened or
hashed so that `TMPDIR` stays well under 30 bytes. A long run's working state
does not depend on this: it goes to `~/.local/state` (the ai-workflows
follow-up), and a new Claude Code session gets a new scratch folder anyway.

**Why `TMPDIR` makes it agent-neutral.** Most programs take their temp folder
from `TMPDIR`. Claude Code 2.1.330 does, read from its code: on Linux it uses
`CLAUDE_CODE_TMPDIR`, else `TMPDIR`/`TMP`/`TEMP`, else `/tmp`, and puts its
per-user scratch folder (`claude-<uid>`) there. Codex (Rust's
`std::env::temp_dir`), Gemini and Copilot (Node's `os.tmpdir()`), Python's
`tempfile` and `mktemp` follow `TMPDIR` through their standard libraries — not
verified per agent; the integration case below verifies the agents it can.

**Why `/var/tmp`.** It is the Linux convention for temporary files that
survive a reboot, so a tool that writes there literally gets the expected
behaviour too. It is short: Claude Code warns when its per-user temp path is
longer than about 30 bytes (the `AF_UNIX` socket path limit) and then gives
child processes another `TMPDIR`. `/var/tmp/claude-1000` is 20.

**Why `~/.local/state` as a whole.** It is XDG's place for state that should
survive a restart. The follow-up change in ai-workflows (below) puts a long
run's working state at `${XDG_STATE_HOME:-~/.local/state}/ai-workflows/<run>/`,
which this makes durable in the container.

**Against what was lost on 2026-11-23:** the scratch folder and
`~/.cache/shipwright-pg01` both survive. A literal `/tmp/update.json` and the
`/workspace/.prd-ground…` folder still do not (non-goals).

## Approaches

Considered, with what each trades:

1. **Keep `/tmp` and `~/.cache` themselves across restarts.** Catches even a
   literal `/tmp/x`. Rejected by the user: the image bakes the firewall's
   allowlists into `/tmp` (`/tmp/allowlist-*.txt`, root-owned), so they would
   have to move first; stale sockets and lock files from the last container
   would come back and confuse tools that expect a clean `/tmp`; two
   containers running at once would share one `/tmp`.
2. **Configure each agent** (`CLAUDE_CODE_TMPDIR`, a note in each agent's
   instructions about where to write). Rejected: per agent, the opposite of
   the constraint.
3. **Chosen: a persistent `/var/tmp` with `TMPDIR` pointed at it, plus
   `~/.cache` and `~/.local/state` kept whole**, all from the group.

Within 3, two ways to store them:

- **Chosen: bind mounts from the group directory**, like every other group
  directory. Visible on the host, which is where the 2026-11-23 recovery was
  checked from.
- **Named volumes**, as `~/.rvm` is. Faster on macOS (virtiofs) and immune to
  its quirks, but invisible from the host without `docker`. Not chosen —
  unless the macOS spike (below) finds something that does not *work* on
  virtiofs. Then named volumes everywhere, not a Mac-only branch: the rvm
  precedent in `AGENTS.md` ("one code path beats a macOS-only branch").

**Per group, not per project** (my call; earlier I described it as per
project). It matches `~/.cache` and every other group directory, and the
launcher's git scan skips the group's own mounts (`_git_skip_root` in
`sandbox.sh`): repositories an agent clones into its temp folder add no bind
mounts to later launches and count nothing toward `SANDBOX_GIT_MAX`. A
per-project folder would sit in the scanned project tree. The cost: projects
sharing a group share the folder, as they already share `~/.cache/qmd`.

**The launcher-directory scan is different.** `launcher_dirs_in()` walks every
writable bind, group mounts included — there is no group exemption there — and
`_fs_linked_in()` lists them too. See *Group folders and the launch's scans*.

## Group folders and the launch's scans

**The user's choice:** the three new mounts are skipped by the walk for
launchers and unlistable directories (`launcher_dirs_in()`), as the git scan
already skips every group mount. Walking them would make every launch slower
as the caches grow (pip's and uv's trees are deep), lock read-only any copy of
ai-containers an agent clones into its temp folder, refuse the launch past 50
such copies, and refuse it for any folder there the agent makes unlistable.

The premise is the git scan's: the host never runs a launcher or git from
inside a group folder. The docs say so where they say what survives: read and
copy files there freely from the host, but do not run `git` or `./sandbox.sh`
inside a repository an agent made there — its hooks and config are the
agent's.

**Not skipped** (my call): the hard-link check (`_fs_linked_in()`). It guards
a different thing — a file git reads by name, written through a second name in
a writable mount — and a hard link from a project's `.git/config` into
`/var/tmp` is exactly that case. The builder measures what it costs on a large
`~/.cache` and comes back if it is significant.

## Constraints

- **`TMPDIR` never reaches a root process.** `/var/tmp` is agent-writable and
  now persists between sessions, so the agent can leave links or FIFOs there
  for the next launch; a root process writing a fixed-name temp file there
  would follow them. Never by `docker run -e`, which reaches the root
  entrypoint. A `/etc/profile.d` export, if used for `docker exec` login
  shells, is skipped for uid 0.
- **Only the agent's shell and its children get it** (my call): the `capsh`
  login shell, and `docker exec` login shells as the agent. Not the start-time
  steps that run through `as_sandbox_user` (skill installs, the rvm and
  agent-tool reconciles), which need nothing kept, and not services' `start`:
  `mysqld --no-defaults` would put its temporary tables on a persistent,
  group-shared folder while its data stays deliberately throwaway.
- **A `TMPDIR` the project sets in `container.env` wins** (my call): it is an
  explicit choice, and `container.env` already delivers it to the agent's
  processes today.
- **Nothing is copied on group bootstrap.** `_copy_group_slice` leaves the
  three out, like `.cache/ms-playwright` and `.ai-tools`: cloning a group
  should not clone scratch, caches or another group's runs.
- **Existing groups need no migration.** `.cache/qmd`, `.cache/ms-playwright`
  and `.local/state/claude` already sit where the whole-directory mounts put
  them.
- **Mounted whatever `sandbox.conf` says**, including a project with
  `qmd=OFF` in a group where another has it on: it sees that project's index
  as data. Acceptable — none of it is executable.
- **Same trust boundary as the group.** An agent can leave something in
  `~/.cache` (a pip or uv cache entry) that a later container in the same group
  uses, as it already can in `~/.ai-tools`, `~/.gradle` and `~/.m2`. A group is
  one trust domain; `docs/security.md` says so for these too.
- **`/tmp` is untouched**, so the firewall files and everything else baked
  there are unaffected.

## Goals

- Nothing any agent writes through `TMPDIR`, or into `~/.cache` or
  `~/.local/state`, is lost when a container stops, with no per-agent setup.
- Claude Code's scratch folder and its background agents' output land on disk.
- `group.sh rm` removes them with the group; `group.sh list --sizes` counts
  them (new code: today it sizes only the rvm volume).

## Non-goals

- A literal `/tmp/...` path. It stays disposable.
- The `/workspace` umbrella. A folder made directly in `/workspace` is still
  lost; the docs say so.
- **The ai-workflows run folder** — a separate design, next: long runs
  (`/prd-ground` first) keep their working state at
  `${XDG_STATE_HOME:-~/.local/state}/ai-workflows/<run-key>/`, a fixed name a
  new session finds, on hosts and in containers alike.
- Processes surviving a restart; only files do.
- Recovering what was already lost.

## Anti-goals

- `TMPDIR` reaching root.
- Slower launches: the new folders must not be walked like a project
  directory.
- Removing a folder a running container still uses.
- Breaking the existing group-scoped caches (`qmd`, Playwright) or Claude
  Code's update state in `~/.local/state/claude`.

## Disk growth: pruning old container folders

**The user's choice:** at launch, before `docker run`, the launcher removes
each container folder under the group's `.var-tmp` that has gone untouched for
30 days (systemd's own default for `/var/tmp`) and whose container is no
longer running. It runs on the host as you, never as root, and never follows a
link out of the folder. A docker that cannot list its containers is never read
as "none running": then nothing is removed. A one-line `NOTE:` says how many
folders went and how much space that freed (my call).

Never pruned automatically: anything else in `/var/tmp` (a tool's literal
`/var/tmp/x`), `~/.cache`, and `~/.local/state`, where long runs keep their
state. `group.sh list --sizes` shows all of it, and the docs give the commands
to reclaim it.

## Testing

Per the repo's rule that every case is seen failing:

- **Hermetic**: the launch's mount arguments include the three mounts and no
  longer the three nested ones they replace (alongside
  `tests/test-tool-config-mounts.sh`); `TMPDIR` is in the sandbox user's
  environment and not in root's, `container.env`'s `TMPDIR` wins (alongside
  `tests/test-env-file.sh`).
- **Hermetic, pruning**: a folder past 30 days with no running container goes;
  one of a running container, one touched within 30 days, and everything
  outside the container folders stay; a docker that cannot list containers
  removes nothing; a link inside a pruned folder is removed, not followed.
- **Integration case**: one container writes, as the agent, into `$TMPDIR`,
  `~/.cache/x` and `~/.local/state/x`; a second container of the same group
  reads them back. In restricted mode, the root daemons'
  `/proc/<pid>/environ` holds no `TMPDIR`. Where an agent CLI is installed,
  its temp folder resolves under `/var/tmp` (Claude Code at least). A mutation
  patch that drops each mount, and one that hands `TMPDIR` to root, must turn
  it red.
- **macOS spike, first, before the rest is built**: on Docker Desktop and on
  Colima, in `/var/tmp` and `~/.cache` on virtiofs — a Unix socket, GNU tar's
  mode-000 placeholder (the rvm failure), a `uv`/`pip` install timed against
  the container layer, and a Claude Code session's scratch folder. Anything
  that fails switches all three to named volumes (above); a slowdown alone is
  reported, not acted on.

## Docs

`AGENTS.md` (*Host directory mounts*), `docs/groups.md` (what a group holds and
what survives a restart, including that `/tmp` and `/workspace` itself do not),
`docs/security.md` (the trust note), `CHANGELOG.md`.

## Left to the builder

- Where exactly `TMPDIR` is added to the sandbox user's environment in
  `entrypoint.sh`, and whether a `/etc/profile.d` export for `docker exec`
  shells is worth it.
- Whether the three mounts are created in `_ensure_group`-style setup or at
  the mount site, and the order relative to the other group mounts.
- How `group.sh list --sizes` already sizes a group (if it sums the directory,
  nothing to do).
- The integration case's number and tags.
