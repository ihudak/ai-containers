# Container groups

A container group is a named directory under `~/.ai-containers/<name>/` that holds all per-purpose agent dotfile state: auth credentials, skills, MCP config, SSH keys, and per-tool session data. Because each group is self-contained, you can keep completely separate agent profiles for different purposes — for example a `docs` group with Obsidian skills and wiki credentials, a `java-backend` group with infra creds and Dynatrace auth, and a `ui` group with Figma MCP config — and switch between them per invocation.

```bash
AI_CONTAINER_GROUP=docs ./sandbox.sh restricted /path/to/workspace
```

The default group is named `default`. Its directory is `~/.ai-containers/default/`. If `AI_CONTAINER_GROUP` is not set, `default` is used.

## Group layout

```text
~/.ai-containers/
├── default/
│   ├── .ssh/
│   ├── .agents/
│   ├── .claude/
│   ├── .claude.json
│   ├── .copilot/
│   ├── .config/gh/
│   ├── .kiro/
│   ├── .local/share/kiro-cli/
│   ├── .codex/
│   ├── .gemini/
│   ├── .aws/              ← cloud credentials (only when aws-cli= is ON)
│   ├── .azure/            ← ditto, when azure-cli= is ON
│   ├── .kube/             ← kubeconfig, when kubectl= is ON
│   ├── .yarn/             ← yarn home, when yarn= is ON (mounted, never copied)
│   ├── .gradle/           ← Gradle user home, when any JVM key is set (mounted, never copied)
│   ├── .m2/               ← Maven repository, ditto
│   ├── .cache/            ← mounted at ~/.cache, always (qmd's index, Playwright's browsers, pip's, uv's and node-gyp's caches)
│   ├── .local/state/      ← mounted at ~/.local/state, always
│   ├── .config/dtctl/    ← tools.d config dir, seeded once from $HOME if present
│   └── .config/dtmgd/    ← ditto
├── docs/               ← custom group, same shape
└── java-backend/       ← another custom group
```

Two things a group owns are **not** in this directory: they are Docker volumes,
on every platform. Its containers' `/var/tmp` is the volume
`ai-containers-vartmp-<group>`, which the group's first launch makes (see
[What survives a restart](#what-survives-a-restart)), and its Ruby home
(`~/.rvm` in the container: rvm, every Ruby version and its gems, only when
`ruby=` is set) is the volume `ai-containers-rvm-<group>`. With
`REPO_VOLUME_PREFIX` set, both names start with it instead of `ai-containers`.
Removing or backing up the group directory does not touch them:
`./group.sh rm <group>` removes all three, and `./group.sh gc` collects a volume
whose directory was deleted by hand. Volumes belong to a docker daemon, so each
daemon you use (through another docker context, say) has its own volumes for a
group. A docker that
several homes share (every WSL distro's, under Docker Desktop) has one Ruby
volume and one temp volume for a group name in all of them. Each home's `rm` and
`gc` keep a volume another home made, and a launch that mounts one says so, but
that is all: the home that made the volume can still remove it from under the
others, with its `rm`, or its plain `gc` once its own group directory is gone,
and any home can with `gc --all`. The other homes' groups then build their
Rubies again, or lose their old `/var/tmp` folders. See
[Several homes on one docker](troubleshooting.md#several-homes-on-one-docker-wsl-distros-or-users).

## What survives a restart

Containers run with `--rm`, so what survives is what is mounted. From a group:
the agent dotfile directories, `~/.ai-tools`, and three places mounted whole,
whatever `sandbox.conf` says: the group directory's `.cache` and `.local/state`
at `~/.cache` and `~/.local/state`, and the group's Docker volume at `/var/tmp`.
The rest of the container, `/tmp` among it, is gone when the container exits,
and so is anything made directly in the `/workspace` umbrella: only the
repositories and directories mounted inside it persist, in the places they come
from.

`/var/tmp` is a Docker volume rather than a folder of the group directory so
that archives unpack there on a Mac. GNU tar holds back a link whose target
contains `..` behind a placeholder file that macOS file sharing (virtiofs)
cannot open, so on a folder shared from the Mac it fails with
`Cannot open: Permission denied`, and a Node.js release tarball, for one, holds
such a link. **On a Mac, `~/.cache` and `~/.local/state` keep that limit**: they
stay folders of the group directory, so that you can look into and clear them
from the Mac. Unpack such an archive into `$TMPDIR` or `/tmp` instead. (Measured
on Colima; Docker Desktop was not measured.)

Each launch gets its own folder in `/var/tmp`, named
`<YYMMDD-HHMMSS-pid>`, which the container's start-up makes, and the agent's
shell has `TMPDIR` pointing at it, so tools that follow `TMPDIR` (Claude Code's
scratch folder, Python's `tempfile`, `mktemp`) write somewhere that is still
there after a restart, at the same path. Two containers of a group never share
a folder. Root, the start-up steps and the in-container database servers do not
get `TMPDIR`; a `TMPDIR` set in your `container.env` wins. A shell that cannot
write or enter its folder does not get it either, and keeps the default `/tmp`.
If the start-up cannot make the folder, a `WARNING:` names it, the container
starts all the same, and the agent's shell keeps `/tmp`. A `docker exec` session
gets the container's environment as it was at launch, so a login shell there
(`docker exec -u "$(id -u)" … bash -l`) takes the folder if it exists and that
user can write and enter it, even after such a warning. A tool that writes a
literal `/tmp/x` loses it: put state that must last in `~/.local/state`, or
`~/.cache` for what can be rebuilt.

At each start, folders in `/var/tmp` of containers that are no longer running
and that nothing has changed for 30 days are removed, at most 50 per start, with
a `NOTE:` saying how many and how much space. Another `NOTE:` says how many old
folders are left for the next launch, "at least" so many when there are more
than the 500 a start looks at. A folder kept because something in it changed
within 30 days, or that could not be removed, is looked at again 30 days later.
Only the folders of the user the container runs as are removed: a project of
the group with another `SANDBOX_UID` removes its own. Nothing else in
`/var/tmp`, `~/.cache` or `~/.local/state` is ever removed. One limit:

- "Changed" means the change time (ctime), of the folder and of everything in
  it, which nothing sets back: unpacking an archive or copying onto the folder
  (`tar x`, `cp -p`, `rsync -a`) gives files old modification dates, but not
  old change times. It counts from the last change, not from the container's
  exit, so the folder of a container that ran for over 30 days without changing
  anything in it can be removed at the first start after that container exits.

**Seeing and reclaiming the space.** `./group.sh list --sizes` shows the size
of each group directory and of each of its volumes. To see what `~/.cache` and
`~/.local/state` hold:

```bash
du -sh ~/.ai-containers/<group>/.cache/* ~/.ai-containers/<group>/.local/state/*
```

Remove what you no longer need with `rm -rf` while no container of that group
runs, since a running one may be using it: a tool's cache, say
(`rm -rf ~/.ai-containers/<group>/.cache/pip`). A cache is downloaded again when
a tool next needs it; what a long run keeps in `~/.local/state` is not.

`/var/tmp` is not on the host. From a running container of the group,
`du -sh /var/tmp/*` shows its folders, and `rm -rf /var/tmp/<YYMMDD-HHMMSS-pid>`
removes an old one of yours. Without a running container, once the group has
launched at least once:

```bash
docker run --rm --pull=never --entrypoint sh -v ai-containers-vartmp-<group>:/v <image> -c 'du -sh /v/*'
```

with your project's image (its `IMAGE_NAME`) and the volume's name as
`./group.sh list` prints it; `-c 'rm -rf /v/<YYMMDD-HHMMSS-pid>'` removes a
folder. **Never before the group's first launch**: that `docker run` would make
the volume itself, without the label a launch puts on the volume it makes, and
the group's next launch would refuse it, naming the `docker volume rm` that
clears the way. The folders running containers use are those
`docker ps --format '{{.Label "ai-containers.tmpslot"}}'` lists; leave them
alone.

**An old `.var-tmp`.** Before `/var/tmp` was a volume, a build of this
repository that was never released mounted the group directory's `.var-tmp`
there. If a group has one, every launch says so in a `NOTE:`, with the
`docker run` that copies it into the group's volume and the `rm -rf` that
removes it once nothing in it is needed and no container of the group runs.
The launcher never removes it.

**Do not run `git` or `./sandbox.sh` on the host inside a repository an agent
made in a group's `.cache` or `.local/state`.** The launcher does not scan them
for hooks and launchers, as it does not scan a group's other folders, because
the host is not meant to run anything from there: a repository's hooks and
config are the agent's. Read and copy its files freely.

After upgrading, rebuild the image (`./build.sh`) and run
`./sync-to-projects.sh` so an existing project gets the change. Until the image
is rebuilt, `TMPDIR` stays `/tmp` and nothing in `/var/tmp` is removed.

## Group-name rules

- Lowercase letters, digits, and dashes only.
- 1–32 characters; must start with a letter or digit.
- Examples of valid names: `default`, `docs`, `java-backend`, `ui2`.
- Examples of invalid names: `Docs` (uppercase), `_meta` (leading underscore), `my group` (space).

## First-time bootstrap

When you reference a group that does not yet exist, `sandbox.sh` asks how to initialize it.

**Interactive (TTY):**

```
Group 'docs' not found. Initialize from:
  1) default            (recommended, if it exists)
  2) host — a copy of $HOME's
  3) <other custom groups, mtime-sorted>
  N) <empty>
  q) cancel
[1]: _
```

Pick `1)` to copy the group-scoped dotfile slice from `default` (or whichever group is listed first). Pick `host` to copy from `$HOME`. Pick `<empty>` to start with an empty group (only `.ssh/` and `.agents/` are scaffolded). Pick `q` to abort.

The slice is credentials and settings — the agent dotfile dirs, `.ssh`, `.agents`, the `tools.d` config dirs, and `.aws`/`.azure`/`.kube` — and, as before, qmd's index (`.cache/qmd`). Regenerable installs and caches are group-scoped but **not** copied (`.ai-tools`, `.rvm`, `.local/share/claude`, `.cache` except qmd's index, `.local/state`, `.yarn`, `.gradle`, `.m2`, and the `/var/tmp` volume): cloning a group should not clone gigabytes that each tool rebuilds by itself.

**Non-interactive (no TTY or scripted use):**

```bash
# Start with an empty group
AI_CONTAINER_GROUP=docs AI_CONTAINER_GROUP_INIT=clean ./sandbox.sh restricted /path

# Copy dotfiles from the default group
AI_CONTAINER_GROUP=docs AI_CONTAINER_GROUP_INIT=from:default ./sandbox.sh restricted /path

# Copy dotfiles from $HOME
AI_CONTAINER_GROUP=docs AI_CONTAINER_GROUP_INIT=from:host ./sandbox.sh restricted /path
```

Without `AI_CONTAINER_GROUP_INIT`, a non-TTY invocation for a missing group exits with an error and prints the hint.

## No `host` group

`AI_CONTAINER_GROUP=host` used to mean "mount agent dotfiles directly from `$HOME`". It is gone, and the launcher refuses it:

- It handed the agent your **real** `~/.ssh`, `~/.aws`, `~/.kube`, `~/.config/gh` and `~/.claude`, read-write, where every other group gives it a copy.
- On macOS it only half-worked: Claude Code, GitHub Copilot CLI, Kiro CLI and GitHub CLI keep their OAuth tokens in the Keychain, which a Linux container cannot read, and rvm cannot bootstrap on a bind mount there.

To start a group with your `$HOME`'s credentials, bootstrap it once from them:

```bash
AI_CONTAINER_GROUP=mine AI_CONTAINER_GROUP_INIT=from:host ./sandbox.sh restricted /path
```

The group then holds a copy. What the agent changes there never reaches your real dotfiles.

For the same reason a group directory must be a directory of its own: one that is a link (to `$HOME`, or to another group) is refused, as is one that turns out to be `$HOME` itself, whatever path leads there (a bind mount or a firmlink counts). The refusal says where the link leads and what to do instead. To keep groups on another disk, make `~/.ai-containers` itself the link. `./build.sh` refuses `AI_CONTAINER_GROUP=host` too, so a project still on it is not built for a launch that cannot start.

## One-time login inside a fresh group

After creating a new group, log in to each tool from inside the container once:

```bash
gh auth login          # Required — Copilot CLI token is auto-derived from this
claude /login
# Kiro: log in on first interactive use
```

Once `gh auth login` completes, Copilot CLI is authenticated automatically (its token is extracted from `hosts.yml` and forwarded as `COPILOT_GITHUB_TOKEN`). No separate `copilot /login` is needed.

> **⚠️ You must fully restart the container after the *first* `gh auth login`.**
> `sandbox.sh` extracts the token from `hosts.yml` **at launch**, so on the very first run of a fresh
> group — where you authenticate `gh` *inside* the container — `COPILOT_GITHUB_TOKEN` was already
> set empty when the container started. Copilot will keep prompting for `/login` (and a Copilot
> `/restart` will **not** help — it reuses the same empty container environment). **Exit the
> container (`Ctrl+D`) and relaunch with `./sandbox.sh …`** so `sandbox.sh` re-reads the now-populated
> `hosts.yml`. From then on Copilot starts authenticated. See
> [GitHub tokens at runtime](security.md#github-tokens-at-runtime) for the full explanation.

> **Note:** If your `gh` token is a fine-grained PAT (`github_pat_*`), it must include the **Copilot Requests** permission. If it's an OAuth token from `gh auth login` browser flow (`gho_*`), it works directly.

The credentials are written into the group directory on the host and persist across all future runs of that group.

## Group maintenance

A group is mostly a plain directory, so standard shell tools still work for
inspecting, backing up, and duplicating one:

```bash
# List groups (and their Ruby and temp volumes)
./group.sh list
./group.sh list --sizes   # each volume's size, and a GROUP DIR column: du -sh of the group directory

# Back up a group's directory
tar czf docs-group.tgz -C "$HOME/.ai-containers" docs

# Duplicate a group's directory (credentials, agent config)
cp -a ~/.ai-containers/default ~/.ai-containers/new-project
```

Both take the whole directory, so they now carry every cache in `.cache` and the
state in `.local/state` too, which can be large (not `/var/tmp`, a volume):
`./group.sh list --sizes` shows how large, and
[What survives a restart](#what-survives-a-restart) how to clear them first.

**Deleting is the exception.** From its first launch the group also owns a
Docker volume holding its `/var/tmp`, and once you have built with a `ruby=`
version another holding its Ruby home (see
[What survives a restart](#what-survives-a-restart) and
[Ruby (via rvm)](components/ruby.md) for why neither can be a directory), and a
bare `rm -rf` would orphan them — potentially several GB with nothing left
pointing at them. Use `group.sh`, which removes all three together:

```bash
# Remove a group: its directory, its Ruby volume and its temp volume (irreversible)
./group.sh rm docs

# Already deleted directories by hand? Collect the orphaned volumes:
./group.sh gc
```

`gc` takes only the volumes this home made. One docker may serve several homes
(Docker Desktop's, by every WSL distro), and a group directory missing here may
be another home's group, so a volume another home made, or one made before
volumes carried their owner, is kept and named; `./group.sh gc --all` takes it
too. A volume whose labels docker cannot read is skipped and named, and `gc`
exits 1. `~/.ai-containers/.restored/` is not a group: it holds files a launch kept
from a protected git file's place, and `group.sh` neither lists nor removes it.

`group.sh` knows a group's temp volume by the label a launch puts on it. A
volume of that name without the label (one a `docker run -v` made before the
group's first launch, say) is shown by `list` as `not the group's`, named by
`rm` with the `docker volume rm` that removes it, and removed by neither `rm`
nor `gc`. A volume of the group's Ruby or temp volume name whose label names
another group (a temp volume's label, on a volume of the Ruby name) is not the
group's either: under nested `REPO_VOLUME_PREFIX` values another prefix's volume
can have that name. `list` shows it as `not the group's`, and `rm` names it and
leaves it, offering no command to remove it, since that prefix's group may be
using it. A Ruby volume with no label, made before volumes carried one, is
still the group's. A volume docker cannot say exists, or whose it is, shows as
`unknown`, and `list` then exits 1.

`group.sh rm` keeps a volume another home made, and removes this home's group
directory. It refuses while a running container still mounts a volume it would
remove, checking every such volume before it removes anything, refuses when
docker cannot say whether a volume exists or whose it is, and refuses `host`,
which is not a group. A launch of the group that starts while `rm` runs
can still find the temp volume just before `rm` removes it; docker then makes
the volume again as the container starts, without the group's label, and every
later launch of the group is refused, printing the `docker volume rm` that
clears the way. It never touches repo volumes — those are global and shared across
every group; manage them with [`repo.sh`](repos-and-mounts.md#shared-repo-volumes-native-speed--reposh-and-repos).

`cp -a` duplicates the *directory* only. The copy starts with an empty
`/var/tmp` and an empty Ruby home, and recompiles its configured versions on
first use.

## Migration notes for upgrading users

**Linux users** will see the bootstrap prompt on first run after upgrade, because `~/.ai-containers/default/` does not exist yet. Choose `host` (a copy of your `$HOME`'s credentials) or another existing source to initialize from, or set `AI_CONTAINER_GROUP_INIT=from:host` to skip the prompt.

**`AI_CONTAINER_GROUP=host` has been removed.** A launch with it is refused, naming the replacement: a named group bootstrapped with `AI_CONTAINER_GROUP_INIT=from:host` (see [No `host` group](#no-host-group)). `AI_CONTAINER_HOST_ACK` is no longer read.

**`SSH_SCOPE_DIR` has been removed.** If you have it set, `sandbox.sh` prints a deprecation note to stderr and ignores the variable. To migrate: copy your custom SSH keys into `~/.ai-containers/<group>/.ssh/`, or initialize a group with `AI_CONTAINER_GROUP_INIT=from:host` to copy them automatically. See `CHANGELOG.md` for details.

---

[← Documentation index](README.md)
