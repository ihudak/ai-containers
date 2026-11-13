# A git directory of the agent's own

**Status:** ON HOLD. Written 2026-11-13; the user decided the same day not to
build it now (D0 below). Nothing here is built. It is kept as a measured option:
a prototype showed it can be done, and a builder check found five errors in the
first draft, all mended below, and showed that it removes less than that draft
claimed. Come back to it if a HIGH lands again in the class it removes, or if
git that works fully inside the container becomes wanted.
**Scope of this spec:** how a container gets git in a host checkout without the
agent ever writing a git directory the host's git runs in. It covers every host
bind a launch makes: the primary, `EXTRA_MOUNTS`, the pointers, and on Linux a
`REPOS` entry with the `bind` backend. Repo **volumes** are out: git never runs
on a volume's own `.git`. Moving `.ai-containers` out of the project is a
separate question and is not part of this.

## The problem

A default launch mounts the project read-write, and the project's `.git` with
it. The host's git later runs what that directory holds: `hooks/`, and config
keys that name programs. So the launcher mounts `hooks/`, `config`,
`config.worktree` and `commondir` read-only inside every git directory it finds,
makes the two files a repository normally lacks so there is something to mount,
and then has to judge everything else git reads there: includes, hook paths,
programs named by path, `commondir` values, hard links, links, FIFOs, files that
only look like git's.

Each fix to that judging was reviewed, and the review found more. The bugs
review holds 92 `GIT-` entries. By the severity each entry records:

| Entries | HIGH | MEDIUM | LOW or NIT |
|---|---|---|---|
| GIT-1 to GIT-25 | 1 | 1 | 23 |
| GIT-26 to GIT-50 | 7 | 6 | 12 |
| GIT-51 to GIT-74 | 1 | 11 | 12 |
| GIT-75 to GIT-92 | 0 | 4 | 14 |

So the count has not stopped, but the severity has fallen: the last HIGH is
GIT-69, and the last eighteen hold none. `repo.sh` had the same history with
repo volumes and ended it by never running git on the volume's `.git`. This spec
works out the same answer for host checkouts and what it would cost.

## Goals, non-goals, anti-goals

**Goals**

1. No file inside a git directory that the host's git runs in is writable from a
   container, and none is made or changed there by a launch or a session. After
   a session the host's git directory is byte for byte what it was, until adopt,
   the one step that writes there, takes the agent's commits.
2. Git in the container works as in an ordinary clone, including what fails
   today with `Resource busy`: `git config`, `git remote add`, the tracking a
   `git push -u` records.
3. The project files stay one live directory. An edit in the container is on the
   host at once, as today.
4. After a session, the commits the agent made are in the host's repository
   without the user doing anything, wherever that is safe; where it is not, the
   work is kept and one launcher command takes it. No commit the agent made is
   ever lost to a successful import.

**Non-goals**

- Repo volumes. See the scope.
- The read-only launcher overlay. Unchanged.
- A project file the host's own config makes git run, such as husky's
  `.husky/_`, or a file in the checkout that the host's config includes. The
  checkout is the agent's to write. Today's `NOTE:` and `WARNING:` for these
  stay, and so does the code that finds them.
- A repository the agent creates in the checkout during a session. It is still
  found only by the scan after the session, and named.
- The host tools that run git themselves (`version.sh`, the sync's ignore line,
  the build's label). They were mended separately and stay as they are.

**Anti-goals** (a design that does one of these has failed, even if it works)

- The launcher runs git in a directory an agent has written.
- A parser of the launcher's stands in for git: refs, config or an index read by
  `grep`/`awk` to decide something that matters.
- A list of config keys or file names is used as a safety gate. A list may feed
  a report; it may not decide whether something is safe.
- A message prints a git command built from a name the agent chose (a branch, a
  path). Branch names may hold `;`, `$` and quotes.

## What was measured

A throwaway prototype, run on Linux on 2026-11-13 (git 2.56 on the host, 2.45 in
a local `ai-containers-seed` image built before that image moved to Alpine 3.24)
against a clone of this repository, a repository
with a submodule, and repositories in both the files and the reftable ref
format. It is not in the tree. What it showed:

- **Making the agent's directory** from the host's `.git` by copying files took
  23 ms and 76 KB for this repository (137 MB of objects, none copied).
- **Everyday git in the container** all passed: commit, switch, merge, rebase,
  stash, tag, gc, fsck, `worktree add`, log and blame over the host's history,
  `git config`, `git remote add`, `git push -u` with its tracking recorded, a
  commit inside a submodule and the bump in its parent.
- **The host's `.git` was byte-identical after the session**, its `modules/`
  included, and still identical after the import below.
- **Import with no git run in the host's repository or in the agent's
  directory** worked in both ref formats. A hostile agent directory (hooks under
  every name git runs, config keys that name programs, a FIFO `include.path`, a
  FIFO `objects/info/alternates`, FIFO, linked and bogus refs) ran nothing and
  hung nothing. A plain `git fetch` from that directory hung on the FIFO
  include.
- **A FIFO among the agent's object files** makes git block when it opens it, so
  the import must refuse one before git sees the directory.
- **A nested repository needs the directory above its `.git` pinned.** Without
  the pin, `mv n n2 && git init n` in the container left a new repository with a
  hook where the user's had been. With it, the `mv` fails with `Resource busy`.

Not tried: macOS, Docker Desktop, Colima, WSL; git-lfs; partial and shallow
clones; SHA-256 repositories; a host repository that itself uses alternates;
linked worktrees; a detached `HEAD` (the prototype's submodule sat on a branch,
which a real one does not); two containers on one checkout.

## The design

### Terms

- **Host git directory**: a git directory on the host that a writable mount
  exposes: a checkout's `.git`, a bare repository, a submodule's directory under
  `.git/modules`.
- **Agent git directory**: a directory the launcher makes for one host git
  directory, outside every checkout, and mounts in its place in the container.
- **Outbox**: a bare repository of the launcher's own, one per host git
  directory, that holds what agents committed until the host takes it. Its
  config is the launcher's. It is never mounted.
- **View**: a throwaway git directory of the launcher's own, with a copy of some
  git directory's ref storage and its objects reached as data. It is how the
  launcher reads refs it does not trust: git parses them, under a config that is
  the launcher's.

All three live under `~/.ai-containers/agent-git/<id>/`, where `<id>` is derived
from the host git directory's physical path. Only the agent git directory is
ever mounted. What the launcher records about a session (the host's `HEAD`,
branch tip and index at launch, whether the repository counts as the user's) is
kept beside it, never inside it.

### At launch

The scan that finds git directories is today's (sandbox.sh: `git_dirs_in()`),
and so are the pins of the directories above each one, the read-only bind of
every `.git` **file** with its hard-link check and, on a share that ignores
case, its restore after the session, `SANDBOX_GIT_MAX`, the treatment of a git
directory that cannot be listed, the refusal on a filesystem where a bind does
not cover every spelling of a name, and the verify manifest. Every bind this
design adds joins that manifest.

The launch is refused, naming what is in the way, when:

- a running container already has the host git directory itself mounted
  writable (another mode, or an older engine copy). Two modes on one git
  directory cannot both keep their promises;
- a writable mount of this launch is rooted inside a host git directory. Today
  one inside a `.git` gets a `NOTE:` and one inside a bare repository gets
  nothing; here either would break goal 1.

For each host git directory found, in each writable mount that exposes it, the
launcher:

1. **Makes the agent git directory** by copying files out of the host git
   directory. No git runs there. Copied: `HEAD`; the ref storage as it is
   (`packed-refs` and `refs/`, or `reftable/`), so no ref is parsed on the host;
   `logs/`; the index, with any shared index it names; `config` and
   `config.worktree` whole; `hooks/`; `info/`; `shallow`; and each directory
   under `worktrees/`, so a linked worktree whose paths resolve in the container
   keeps working. Not copied: `objects/`. Each copy takes regular files only,
   never through a link, under the launcher's existing read bound, and a host
   git directory that cannot be copied within it refuses the launch by name. A
   git directory that cannot be listed is not copied at all: it keeps today's
   treatment (mounted read-only whole with a `WARNING:`, or refused where it can
   be searched) and gets no agent directory.
2. **Points it at the host's objects.** Its `objects/info/alternates` names the
   in-container path where the host git directory's `objects/` is mounted
   read-only. The existing search for a FIFO or device in a read-only source
   (sandbox.sh: `_ro_fifo_search()`) covers that mount. Where the host's object
   store has alternates of its own, each one that lies inside a mount of this
   launch is named in the agent's alternates by its in-container path. One
   outside every mount is as unreachable from the container as it is today, and
   the launch says so in a `NOTE:`.
3. **Does the same for each git directory under `modules/`**, so a submodule's
   checkout, whose `.git` file names it by a relative path, finds its own agent
   directory at the same relative place.
4. **Mounts the agent git directory in place of the host git directory.** Where
   the host git directory is itself a mount's root (a bare repository given in
   `EXTRA_MOUNTS`), the agent directory becomes that mount's source: Docker
   refuses two mounts on one destination. From the container the host's
   `config`, `hooks/` and the rest cannot be reached at all.

Two binds a git directory instead of today's five.

The launcher stops making `config`, `commondir`, `config.worktree`, `hooks/` and
the push-hook directories in the user's repositories. Placeholders an earlier engine
made stay where they are; nothing depends on them and nothing removes them.

An agent git directory lives for one session. If one is already there:

- and a running container mounts it, this launch shares it (two containers on
  one checkout must share one index and one `HEAD`);
- and no container mounts it, a launcher was killed before it could import. The
  launch imports it first, as below, and then makes a fresh one. If that import
  fails, the directory is set aside under a dated name with a `WARNING:` and the
  launch goes on.

### In the container

Git finds an ordinary repository at `.git`. Its branches, tags, remotes, stash,
reflogs and hooks are the host's as they stood at launch, because they were
copied. What the agent changes there (config, hooks, refs, index) stays in its
own directory.

### When the last container on a checkout exits: import

The import moves the agent's commits into the outbox. It runs no git in the host
git directory and none in the agent git directory.

1. Refuse, naming the file, if anything but a regular file or a directory lies
   among the agent's object files.
2. Build a view of the agent git directory: a copy of its ref storage and
   reflogs, and its objects through a directory of links to its `pack/` and
   fan-out directories only, so its own `objects/info/alternates` is never read.
   The host's objects are reached as git itself reaches them on the host, the
   host store's own alternates included, relative ones too.
3. Build a view of the host git directory the same way, for its tips.
4. In the agent's view, pack **everything the agent's refs, its `HEAD` and its
   reflogs reach** that the host's tips do not, and index that pack into the
   outbox with strict object checks. The outbox reads the host's objects as an
   alternate, and its config sets `core.alternateRefsCommand` so that git never
   goes into the host's repository to list refs.
5. Write into the outbox the agent's branches, tags and every stash entry, each
   only if its object arrived; its `HEAD`, as the branch it names or, detached,
   as the commit; and a ref for each commit only a reflog reaches. A submodule's
   `HEAD` is normally detached, and so is one left by an unfinished rebase.

A git directory the agent made **inside** its own (a submodule it added or
initialised gets a `modules/<name>` with no host counterpart) is imported into
an outbox of its own, and the message names it. It is not made on the host: the
user initialises the submodule there, and adopt then finds the outbox. The
`.git` file such a session leaves in the checkout is named by the scan after the
session, as any new one is.

Every git call is bounded in time. An import that is refused or cut off leaves
the agent git directory where it is, with a `WARNING:` that names
`./sandbox.sh adopt` as what retries it. An import that succeeds removes the
agent git directory. The container's exit status stays the launcher's.

### Adopt

Adopt is the one step that runs git in the host's repository. It fetches from
the outbox, a repository the launcher made, into `refs/agent/`. Every git
command it runs has hooks switched off and the file-system monitor off
(`core.hooksPath` and `core.fsmonitor` set on the command line), automatic
maintenance off, and never refreshes the index, so that no filter runs.

Adopt moves nothing, and says why, unless all of these hold:

- the repository counts as the user's (D1);
- git, asked where each config value it reads for this repository comes from,
  names no file inside a writable mount of the launch;
- no running container has the host git directory mounted writable;
- the host's `HEAD`, branch tip and index are what they were at launch, and no
  operation (merge, rebase, cherry-pick, bisect) is in progress there.

Then, for a checkout:

- If the agent's `HEAD` names a branch whose tip descends from the commit the
  host was on, the host's branch is moved to it (created if new), `HEAD` is
  pointed at it, and the index is set to it with the working tree left alone.
  The working tree already holds that content: it is the same directory. The
  branch's reflog records the move. A detached `HEAD` that moved forward (a
  submodule's) is moved the same way, detached.
- Every other branch the agent made or moved forward is created or
  fast-forwarded, **except one that is checked out in another worktree**, whose
  index adopt is not setting. A new tag is created; an existing tag is never
  moved.
- Anything else stays under `refs/agent/` and one message says what and why.

For a bare repository, adopt is the fetch and the fast-forwards only.

A ref under `refs/agent/` that a host branch has caught up with is deleted by
the next adopt, so the namespace does not grow.

Not taken from the agent, ever: its config (the remotes it added, the tracking
`push -u` recorded), its hooks, its index, its remote-tracking refs. An agent
can set `origin/main` to anything; the host's stay the host's.

`./sandbox.sh adopt [<project directory>]` runs import, if one is pending, and
adopt by hand. It takes no branch name. Messages that name a branch print it
quoted and never as part of a command.

### What this removes, and what it does not

The first draft said about half of the git protection would go. The builder
check showed that was too much, for one reason: the host's own config can still
send git into the checkout (`core.hooksPath=.husky/_`, an include of a project
file, a filter that is a project script), and the launcher must still find and
name that. So the code that reads config, walks includes and judges hook paths
and programs stays. What changes for it is its input: in a repository that has
been hidden since before any agent could write it, that config is the user's.

By the titles in the bugs review (an estimate, not a measurement), of the 92
`GIT-` entries:

| Class | Entries | Under this design |
|---|---|---|
| `commondir` checks and their remedies, placeholders, `config.worktree`, hard links and moved-aside files inside a git directory | about 27 | Code and tests deleted in phase 3 |
| Config readers, the include walk, hook-path and program judging, the first-launch report | about 15 | Stay, reading a config the agent can no longer write in the user's repositories |
| Reads of `.git` files, `gitdir`, `core.worktree`; bounds on those reads | about 12 | Stay, some simpler |
| Finding git directories and `.git` files, scan bounds, unlistable directories, other mounts' views, the host tools | about 38 | Stay unchanged |

Of the last eighteen entries, eight are in the first row.

Against that, this design adds a subsystem that does not exist today: agent
directories and their lifetime, views, the outbox, import, adopt, the records,
and a lock for the last exit. The builder check found a way to lose commits in
the first draft of it within minutes. It should be expected to draw its own
series of review findings.

### Limits

- **The host's git reads objects and ref storage the agent wrote**, through
  views and the outbox, with strict checks. That is the trust git gives a remote
  it fetches from.
- **During a session the host does not see the agent's commits.** `git log` on
  the host shows the old tip and `git status` shows the agent's work as
  uncommitted, until the last container exits.
- **A launcher that is killed** leaves the work in the agent git directory. The
  next launch on that checkout, or `./sandbox.sh adopt`, imports it.
- **An operation in progress on the host at launch** (a merge with conflicts, a
  rebase) must either be carried into the agent's directory faithfully or be
  named in a `NOTE:` at launch. Adopt does not run after such a session.
- **A git directory tracked as content of an enclosing checkout** (a bare
  repository kept as a test fixture) can no longer be changed from a container:
  the agent's changes go to its own directory, not to the tracked files. The
  enclosing repository must still see those files as they are, so such a
  directory is copied whole, objects included, under a size bound.
- **A submodule the agent adds or initialises** exists only in the container
  until the user initialises it on the host. These commands fail today.
- **Kinds of repository.** Phase 1 must support, with a test each: shallow
  clones, SHA-256 repositories, and a host repository that uses alternates.
  Partial clones and git-lfs (whose store is inside the hidden `.git`) are
  measured in phase 1; each is then either supported or named in a `NOTE:` at
  launch for a repository that uses it. Phase 2 does not happen while either is
  only named.
- **Where git does not run on the host** (no git, or macOS's shim with no
  developer directory), the agent git directory is still made, since making it
  needs no git, and the session works. Import cannot run. The work is kept and a
  message says to install git and run `./sandbox.sh adopt`.
- **A reftable repository needs a host git that reads reftable** (2.45) for the
  import. An older host git gets the same message.
- **`$HOME` mounted writable** exposes the outbox and the records, as it already
  exposes the user's shell startup files. Unchanged.

## Rollout

Only if D0 says to build. As recommended in D2:

1. **Phase 1, opt-in.** `SANDBOX_GIT_MODE=private` selects this design;
   the default, `overlay`, is today's protection, untouched. The variable is
   machine-only (`sandbox.local.env` or the shell) until the default changes, so
   a commit cannot choose the mode. The new code is a file of its own beside
   `sandbox.sh`, in `AI_CONTAINERS_SHARED_FILES`, and a falsify target from its
   first commit.
2. **Phase 2, default.** After the Linux, macOS, WSL with Docker Desktop and WSL
   with native Docker agents have each run the integration case, `private`
   becomes the default and `overlay` stays selectable for one release.
3. **Phase 3, removal.** The first row of the table above is deleted, with its
   tests and its documentation in `AGENTS.md`.

## Testing

- **Hermetic**, with real git and no docker, as `tests/test-repo-git-reset.sh`
  does for the repo helper: making an agent git directory from fixtures in both
  ref formats; the import against a hostile agent directory, where each planted
  thing is a case that must be seen failing with its guard removed; a detached
  `HEAD` and a commit only a reflog reaches, both kept; adopt in each of its
  outcomes, each condition that stops it seen stopping it; the leftover from a
  killed launcher.
- **The floor.** Ubuntu 22.04's git 2.34 has no reftable, no
  `git init --ref-format` and no `git reset --no-refresh`. The files path must
  not need any of them.
- **Integration**, one new case with mutations: git works in a restricted
  container; the host's git directory is byte-identical after the session; a
  hook and a config key planted in the agent's directory do not run on the host
  through import and adopt; the nested-repository rename fails.
- **Each platform agent** runs that case before phase 2.

## Decisions for the user

**D0. Build this at all?** **Decided 2026-11-13: not now.**
- *Recommended, and chosen: not now.* The prototype shows it can be done. The builder check
  shows what it buys is narrower than first claimed: about 27 of 92 entries'
  worth of code goes, the config readers stay, and a new subsystem with its own
  review history is added. Meanwhile the existing protection is complete as far
  as is known, has no open bug, and its recent findings are LOW with a few
  MEDIUM. Keep this document as the measured option, and come back to it if a
  HIGH lands again in the class it removes, or if git that works fully inside
  the container (goal 2) becomes something users ask for.
- *Alternative: build phase 1.* The reasons to: goal 1 holds by construction
  rather than by checks; `git config` and `push -u` work in the container; the
  launcher stops writing files into the user's repositories; two binds a
  repository instead of five, which is launch time on Docker Desktop.

The rest apply only if D0 says to build.

**D1. When does adopt run by itself?**
- *Recommended:* automatically when every condition under [Adopt](#adopt) holds,
  where "the user's" means: not a repository the scan after a session saw the
  agent create, and not the first session after a launch hides a repository for
  the first time (it may have been writable by agents before, and that launch
  reports what its config and hooks hold). Otherwise the work waits in the
  outbox and a message names `./sandbox.sh adopt`.
- *Alternative:* never automatically. Every session that made commits ends with
  a message, and the user runs `./sandbox.sh adopt`. Simpler and safer; one
  command more after each session.

**D2. Rollout.**
- *Recommended:* the three phases above.
- *Alternative:* replace today's protection in one change. Less code alive at
  once, but no fallback while the other platforms are untested.

**D3. GAP-2**, the whole-file falsify measurement of `sandbox.sh` (about 20
hours).
- *Recommended:* if D0 is "not now", run it as planned. If D0 is "build", run it
  after phase 3 on what is left. **With D0 decided, it runs as planned.**

## Calls made in writing this (the author's, not yet the user's)

- The agent git directory lives for one session, and the host's repository stays
  the only lasting record. A lasting one would keep the agent's config, at the
  price of reconciling two sets of branches at every launch.
- The outbox exists so that import never writes into the host's git directory,
  not even a ref file, and works whatever ref format the host uses.
- Config and hooks are copied whole into the agent's directory, so git in the
  container behaves as today's does. Only the container reads the copies.
- Only `objects/` of the host git directory is mounted read-only, not the whole
  directory.
- New tags and fast-forwardable branches are adopted, not only the checked-out
  branch, because today they simply appear.
- A launch is refused while another container has the same host git directory
  mounted writable, rather than carrying on with a warning.
- A tracked git-directory fixture is copied whole rather than exempted. Nothing
  can exempt a git directory (bugs review LNCH-16).
- Partial clones and git-lfs may be named rather than supported in phase 1, but
  block phase 2 until supported.
- The mode variable is `SANDBOX_GIT_MODE` with values `overlay` and `private`.

## Left to the builder

The file's name and its functions; how `<id>` is derived; the lock that decides
which exit is the last; the format of the records; how stash entries and
reflog-only commits are named in the outbox; whether an operation in progress is
carried or named; how the views reach the host's objects so that its alternates
resolve as git resolves them; the size bound for a tracked fixture; whether
adopt is a mode of `sandbox.sh` or a script of its own; the integration case's
number and its mutations; what phase 3 deletes, function by function, each
deletion shown by the tests that go with it.
