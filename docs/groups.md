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
│   ├── .rvm/              ← rvm + Ruby versions/gems (only when ruby= is set)
│   ├── .config/dtctl/    ← tools.d config dir, seeded once from $HOME if present
│   └── .config/dtmgd/    ← ditto
├── docs/               ← custom group, same shape
└── java-backend/       ← another custom group
```

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
  2) host
  3) <other custom groups, mtime-sorted>
  N) <empty>
  q) cancel
[1]: _
```

Pick `1)` to copy the group-scoped dotfile slice from `default` (or whichever group is listed first). Pick `host` to copy from `$HOME`. Pick `<empty>` to start with an empty group (only `.ssh/` and `.agents/` are scaffolded). Pick `q` to abort.

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

## The `host` group

`AI_CONTAINER_GROUP=host` is a special sentinel meaning "mount agent dotfiles directly from `$HOME`". No `~/.ai-containers/host/` directory is created.

**On Linux**, this restores the behavior that was the default before container groups were introduced — no warning, no prompt.

**On macOS**, `sandbox.sh` prints the following warning and prompts for explicit confirmation before starting the container:

```
WARNING: AI_CONTAINER_GROUP=host on macOS

The following tools store OAuth in the macOS Keychain and
will NOT have working credentials in the container:
  - Claude Code        (~/.claude)
  - GitHub Copilot CLI (~/.copilot)
  - Kiro CLI           (~/.kiro)  [also: per-arch bun binary conflict]
  - GitHub CLI         (~/.config/gh)

Codex, Gemini, and other dirs are unaffected.
```

Respond `yes` to continue. For non-interactive use, set `AI_CONTAINER_HOST_ACK=1`.

The warning exists because those tools store OAuth tokens in the macOS Keychain rather than in their dotfile dirs. A Linux container cannot access the Keychain, so the container would start with no credentials for those tools. The default `default` group avoids this entirely by storing all credentials in `~/.ai-containers/default/` using file-based auth that works on both platforms.

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
./group.sh list --sizes

# Back up a group's directory
tar czf docs-group.tgz -C "$HOME/.ai-containers" docs

# Duplicate a group's directory (credentials, agent config)
cp -a ~/.ai-containers/default ~/.ai-containers/new-project
```

**Deleting is the exception.** Once you have built with a `ruby=` version, the
group also owns a Docker volume holding its Ruby home (see
[Ruby (via rvm)](components/ruby.md) for why it can't be a directory), and a bare
`rm -rf` would orphan it — potentially several GB with nothing left pointing at
it. Use `group.sh`, which removes both halves together:

```bash
# Remove a group: its directory AND its rvm volume (irreversible)
./group.sh rm docs

# Already deleted directories by hand? Collect the orphaned volumes:
./group.sh gc
```

`group.sh rm` refuses while a running container still mounts the group's
volume, and refuses the `host` group (which is your real `$HOME`, not a managed
directory). It never touches repo volumes — those are global and shared across
every group; manage them with [`repo.sh`](repos-and-mounts.md#shared-repo-volumes-native-speed--reposh-and-repos).

`cp -a` duplicates the *directory* only. The copy starts with an empty Ruby
home and recompiles its configured versions on first use.

## Migration notes for upgrading users

**Linux users** will see the bootstrap prompt on first run after upgrade, because `~/.ai-containers/default/` does not exist yet. Choose `host` or another existing source to initialize from. To restore the previous behavior without any prompt, set `AI_CONTAINER_GROUP=host` permanently in your shell profile.

**`SSH_SCOPE_DIR` has been removed.** If you have it set, `sandbox.sh` prints a deprecation note to stderr and ignores the variable. To migrate: copy your custom SSH keys into `~/.ai-containers/<group>/.ssh/`, or initialize a group with `AI_CONTAINER_GROUP_INIT=from:host` to copy them automatically. See `CHANGELOG.md` for details.

---

[← Documentation index](README.md)
