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
│   ├── .var-tmp/          ← mounted at /var/tmp, always; one folder per container
│   ├── .config/dtctl/    ← tools.d config dir, seeded once from $HOME if present
│   └── .config/dtmgd/    ← ditto
├── docs/               ← custom group, same shape
└── java-backend/       ← another custom group
```

A group's Ruby home (`~/.rvm` in the container: rvm, every Ruby version and its
gems, only when `ruby=` is set) is **not** in this directory. It is the Docker
volume `ai-containers-rvm-<group>`, on every platform. Removing or backing up the group directory does
not touch it: `./group.sh rm <group>` removes both, and `./group.sh gc` collects a
volume whose directory was deleted by hand. A docker that several homes share
(every WSL distro's, under Docker Desktop) has one Ruby volume for a group name
in all of them. Each home's `rm` and `gc` keep a volume another home made, and a
launch that mounts one says so, but that is all: the home that made the volume
can still remove it from under the others, with its `rm`, or its plain `gc` once
its own group directory is gone, and any home can with `gc --all`. The other
homes' groups then build their Rubies again. See
[Several homes on one docker](troubleshooting.md#several-homes-on-one-docker-wsl-distros-or-users).

## What survives a restart

Containers run with `--rm`, so what survives is what is mounted. From a group:
the agent dotfile directories, `~/.ai-tools`, and three folders mounted whole,
whatever `sandbox.conf` says: `~/.cache`, `~/.local/state` and `/var/tmp`. The
rest of the container, `/tmp` among it, is gone when the container exits, and so
is anything made directly in the `/workspace` umbrella: only the repositories
and directories mounted inside it persist, in the places they come from.

Each launch gets its own folder in `/var/tmp`, named
`<YYMMDD-HHMMSS-pid>`, and the agent's shell has `TMPDIR` pointing at it, so
tools that follow `TMPDIR` (Claude Code's scratch folder, Python's `tempfile`,
`mktemp`) write somewhere that is still there after a restart, at the same
path. Two containers of a group never share a folder. Root, the start-up steps
and the in-container database servers do not get `TMPDIR`; a `TMPDIR` set in
your `container.env` wins. A shell that cannot write or enter its folder does
not get it either, and keeps the default `/tmp`: with `SANDBOX_UID` overridden
on native Linux the folder belongs to you, mode 0700. A tool that writes a
literal `/tmp/x` loses it: put state that must last in `~/.local/state`, or
`~/.cache` for what can be rebuilt.

At launch, folders in `/var/tmp` of containers that are no longer running and
that nothing has touched for 30 days are removed, at most 50 per launch, with a
`NOTE:` saying how many and how much space. Another `NOTE:` says how many old
folders are left for the next launch, "at least" so many when there are more
than the 500 a launch looks at. A folder kept because something in it changed
within 30 days, or that could not be removed, is looked at again 30 days later.
Nothing else in `/var/tmp`, `~/.cache` or `~/.local/state` is ever removed by
the launcher. Two limits:

- If you use several docker daemons or contexts from one home, they share a
  group's `.var-tmp`, but `docker ps` sees only the current one. A container
  running on another daemon whose folder went untouched for 30 days can be
  pruned.
- "Untouched" means modification time, of the folder and of everything in it,
  and it counts from the container's exit or the last change, whichever is
  later. The launcher touches a container's folder when the container exits,
  because unpacking an archive or a copy onto the folder itself (`tar x`,
  `cp -p`, `rsync -a`) gives it the source's old dates.

**Seeing and reclaiming the space.** `./group.sh list --sizes` shows each group
directory's size. To see what the three folders hold:

```bash
du -sh ~/.ai-containers/<group>/.cache/* ~/.ai-containers/<group>/.local/state/*
du -sh ~/.ai-containers/<group>/.var-tmp/*
```

Remove what you no longer need with `rm -rf` while no container of that group
runs, since a running one may be using it: a tool's cache
(`rm -rf ~/.ai-containers/<group>/.cache/pip`), or an old container's folder
(`rm -rf ~/.ai-containers/<group>/.var-tmp/<YYMMDD-HHMMSS-pid>`). The folders
running containers use are those `docker ps --format '{{.Label "ai-containers.tmpslot"}}'`
lists. A cache is downloaded again when a tool next needs it; what a long run
keeps in `~/.local/state` is not.

**Do not run `git` or `./sandbox.sh` on the host inside a repository an agent
made in these folders.** The launcher does not scan them for hooks and
launchers, as it does not scan a group's other folders, because the host is not
meant to run anything from there: a repository's hooks and config are the
agent's. Read and copy its files freely.

After upgrading, rebuild the image (`./build.sh`) and run
`./sync-to-projects.sh` so an existing project gets the change.

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

The slice is credentials and settings — the agent dotfile dirs, `.ssh`, `.agents`, the `tools.d` config dirs, and `.aws`/`.azure`/`.kube` — and, as before, qmd's index (`.cache/qmd`). Regenerable installs and caches are group-scoped but **not** copied (`.ai-tools`, `.rvm`, `.local/share/claude`, `.cache` except qmd's index, `.local/state`, `.var-tmp`, `.yarn`, `.gradle`, `.m2`): cloning a group should not clone gigabytes that each tool rebuilds by itself.

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
# List groups (and their rvm volumes)
./group.sh list
./group.sh list --sizes   # adds a GROUP DIR column: du -sh of the group directory

# Back up a group's directory
tar czf docs-group.tgz -C "$HOME/.ai-containers" docs

# Duplicate a group's directory (credentials, agent config)
cp -a ~/.ai-containers/default ~/.ai-containers/new-project
```

Both take the whole directory, so they now carry every cache in `.cache`, the
state in `.local/state` and the scratch in `.var-tmp` too, which can be large:
`./group.sh list --sizes` shows how large, and
[What survives a restart](#what-survives-a-restart) how to clear them first.

**Deleting is the exception.** Once you have built with a `ruby=` version, the
group also owns a Docker volume holding its Ruby home (see
[Ruby (via rvm)](components/ruby.md) for why it can't be a directory), and a bare
`rm -rf` would orphan it — potentially several GB with nothing left pointing at
it. Use `group.sh`, which removes both together:

```bash
# Remove a group: its directory and its rvm volume (irreversible)
./group.sh rm docs

# Already deleted directories by hand? Collect the orphaned volumes:
./group.sh gc
```

`gc` takes only the volumes this home made. One docker may serve several homes
(Docker Desktop's, by every WSL distro), and a group directory missing here may
be another home's group, so a volume another home made, or one made before
volumes carried their owner, is kept and named; `./group.sh gc --all` takes it
too. `~/.ai-containers/.restored/` is not a group: it holds files a launch kept
from a protected git file's place, and `group.sh` neither lists nor removes it.

`group.sh rm` keeps a volume another home made, and removes this home's group
directory. It refuses while a running container still mounts a volume it would
remove, and refuses `host`, which is not a group. It never touches repo volumes — those are global and shared across
every group; manage them with [`repo.sh`](repos-and-mounts.md#shared-repo-volumes-native-speed--reposh-and-repos).

`cp -a` duplicates the *directory* only. The copy starts with an empty Ruby
home and recompiles its configured versions on first use.

## Migration notes for upgrading users

**Linux users** will see the bootstrap prompt on first run after upgrade, because `~/.ai-containers/default/` does not exist yet. Choose `host` (a copy of your `$HOME`'s credentials) or another existing source to initialize from, or set `AI_CONTAINER_GROUP_INIT=from:host` to skip the prompt.

**`AI_CONTAINER_GROUP=host` has been removed.** A launch with it is refused, naming the replacement: a named group bootstrapped with `AI_CONTAINER_GROUP_INIT=from:host` (see [No `host` group](#no-host-group)). `AI_CONTAINER_HOST_ACK` is no longer read.

**`SSH_SCOPE_DIR` has been removed.** If you have it set, `sandbox.sh` prints a deprecation note to stderr and ignores the variable. To migrate: copy your custom SSH keys into `~/.ai-containers/<group>/.ssh/`, or initialize a group with `AI_CONTAINER_GROUP_INIT=from:host` to copy them automatically. See `CHANGELOG.md` for details.

---

[← Documentation index](README.md)
