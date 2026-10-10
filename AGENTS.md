# AGENTS.md

This file is the **canonical instruction set** for AI coding agents working in this
repository (architecture, conventions, and commands). It follows the open
[AGENTS.md](https://agents.md) standard read natively by Claude Code (v2.1.277 and
later), Codex, GitHub Copilot, Gemini CLI, Cursor, and others.

There is deliberately no `CLAUDE.md`: Claude Code reads `AGENTS.md` only when no
`CLAUDE.md` sits in the working directory or above it, so one here would take its
place. On an older Claude Code, or with its built-in `agents-md` plugin disabled,
put `@AGENTS.md` in an untracked `CLAUDE.local.md`.

For agents that look for a tool-specific filename, these are **symlinks to this file**:
- `.github/copilot-instructions.md` → `AGENTS.md` (GitHub Copilot)
- `.kiro/steering/AGENTS.md` → `AGENTS.md` (Kiro CLI loads `.kiro/steering/**/*.md`, not a root file)

Edit **this file only**; the others update automatically.

## What this project is

A CLI-only Docker workspace for running AI coding agents (GitHub Copilot CLI, Kiro CLI, Claude Code, Codex CLI, Gemini CLI) and related developer tools (graphify, qmd, etc.) inside an isolated container with deny-by-default outbound network controls and a non-root agent shell. It is intentionally not a VS Code dev container.

## Component configuration

`sandbox.conf` is the single source of truth for which optional components are included. Set a component to `ON` or `OFF` and rebuild. The format is strictly `component=ON` or `component=OFF`, one per line; comments start with `#`.

Optional components: `copilot`, `kiro`, `claude-code`, `codex`, `gemini`, `graphify`, `openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`, `kubectl`, `aws-cli`, `azure-cli`, `github-cli`, `angular-cli`, `yarn`, `pnpm`, `bun`, `goreleaser`, `vale`, `qmd`, `dtctl`, `dtmgd`, `imagemagick`, `wkhtmltopdf`, `c-toolchain`, `playwright`, `postgres`, `redis`, `mysql`, `mariadb`, `mongo`, `shellcheck`.

**`c-toolchain=ON`** keeps a C compiler in the finished image — `build-essential`
(gcc, g++, make, binutils, `libc6-dev`) plus `libyaml-dev zlib1g-dev libssl-dev`,
the same layer `ruby` and `db-clients` already rely on. Without it the Dockerfile
purges `build-essential` at the end of the build, because most images never need
a compiler at runtime.

Turn it on when something compiles **inside** the container: `go test -race` (the
race detector needs cgo, which needs gcc), `cgo` builds generally, a `pip install`
of a source-only wheel, or `node-gyp`. It is **not** implied by `go=` — most Go
builds never touch cgo, and wiring it to the language key would grow every Go
image for a capability few of them use. It is opt-in for the same reason
`db-clients` is.

Before this key existed there was no way to *ask* for a compiler: one arrived
only as a side effect of `ruby=` or `db-clients=`, so the choice was enabling an
unrelated language runtime or working around it. One session did the latter —
relocating 31 architecture-specific `.deb`s into `~/.local`, then wrapping `gcc`
with `-B` flags so a displaced `cc1` could find its own support objects and
`LD_LIBRARY_PATH` so `cc1` could find `libisl`/`libmpc`/`libmpfr`. `c-toolchain=ON`
plus a rebuild replaces all of it. (Go tools installed with `go install`, such as
`golangci-lint` or `govulncheck`, are a separate matter — they need no C compiler
and are not covered by this key.)

`make` on its own does **not** need this key. It sits in the Dockerfile's
unconditional agent-utilities layer, beside `rg`, `fd`, `file` and the rest, so
a Makefile that only runs scripts works in every image. Do not drop it from
that layer as redundant with `build-essential`. The cleanup purge removes
`build-essential`'s copy too, which is exactly what mutation
`310-make-not-installed` breaks on purpose to prove the guard catches it.

**`playwright=ON | x.y.z | OFF`** bakes the OS packages Playwright's browsers link
against — `libnss3`, `libgbm1`, `libatk-bridge2.0-0t64`, the font set — by running
Playwright's own `install-deps` in a build layer. `ON` uses whatever
`playwright@latest` wants at build time; a pinned version is reproducible and is
what `--no-cache`-free refreshes need, since Docker caches the layer either way.
`build.sh` rejects a comma-separated value by name: one layer runs one
`install-deps`. The package list is **Playwright's**, deliberately not ours — a
hardcoded list rots against both new Playwright releases and Ubuntu renames (the
t64 transition moved most of that set).

It cannot be a runtime install, and that is the whole reason it is a build-time
key. `entrypoint.sh` permanently drops root via `capsh --user=` before the agent
shell exists, so the runtime-reconcile pattern the agent-tier tools and rvm use
is unavailable: nothing in the container can ever `apt-get install`. This is also
why `npx playwright install --with-deps` fails inside the container — the
`--with-deps` half needs root.

Only the LIBRARIES are baked. The browser binaries (~500 MB) are downloaded at
run time into `~/.cache/ms-playwright`, which `sandbox.sh` group-mounts exactly
as it does `~/.cache/qmd`, so containers running with `--rm` do not re-download
them every start. `allowlist-domains.d/playwright.txt` (gated on `is_active`, so
a pinned version counts) admits `cdn.playwright.dev` for that download.

**`/dev/shm` is the resource that actually bites, and `CONTAINER_MEMORY` does not
govern it.** It is a tmpfs sized independently of the memory cgroup, so a
container given 16g still has Docker's 64m default and headless Chromium dies
with `Target closed` — a message pointing nowhere near the cause. `sandbox.sh`
passes `--shm-size=1g` when the key is active, overridable via
`CONTAINER_SHM_SIZE`, and passes nothing at all otherwise, so every container
that does not ask for Playwright composes the `docker run` it always did.
Playwright's own docs suggest `--ipc=host` for this; that shares the host IPC
namespace and is not a trade this project makes.

**`postgres=ON | <major> | OFF`** bakes a PGDG PostgreSQL server into the image and
starts a throwaway cluster in every container, as the sandbox user, on loopback
only. `ON` is whatever PGDG's `postgresql` metapackage depends on at build time; a
pinned value is a major (a minor is refused). The image layer fails closed: it runs
`apt-get update --error-on=any` and refuses to build if PGDG's index did not load,
so a transient fetch failure cannot silently install Ubuntu's own PostgreSQL 16. It
is the first server on the shared runner described under
[In-container database servers](#in-container-database-servers);
`POSTGRES_ROLES` / `POSTGRES_DATABASES` in `container.env` provision it. User docs:
`docs/components/postgres.md`.

**`redis=ON | OFF`** bakes Ubuntu 24.04's `redis-server` (7.0) and starts it on the
same runner: `127.0.0.1` and `::1` only (Node 17 and later resolve `localhost` to
`::1` first; the `::1` bind is optional), no password, no snapshots and no
append-only file. It takes no version, because Ubuntu's archive carries one, and
`build.sh` refuses one rather than ignore it. Ready means **this** server
answering: the pid its `INFO` reports must be the one it wrote, so another Redis
on the port never passes for it. Its integration case runs on the `services`
image variant, which holds the servers that need no build toolchain. User docs:
`docs/components/redis.md`.

**`mysql=ON | OFF`** bakes Ubuntu 24.04's `mysql-server` (8.0) and a **template data
directory** initialised at build time, time zone tables loaded, which the adapter
copies at start: ~0.6 s to ready instead of `--initialize-insecure`'s ~5.6 s on every
launch. `mysqld` runs with `--no-defaults`, every option on its command line:
`127.0.0.1`, and `::1` only where the container has an IPv6 loopback (`mysqld` refuses
an address it cannot bind), the default socket, no X Protocol listener,
`performance_schema` off (147 MB idle instead of 376 MB) and durability off. `root`
and the sandbox user have no password; `MYSQL_USERS` (`name` or `name:password`;
`root:<pw>` is set last) and `MYSQL_DATABASES` (names — MySQL has no owners)
provision the rest. Not MariaDB, whose SQL has drifted from MySQL 8's (it rejects
`utf8mb4_0900_ai_ci`, `->>` and `LATERAL` — measured). User docs:
`docs/components/mysql.md`.

**`mariadb=ON | <series> | OFF`** is for projects whose production runs MariaDB. `ON`
is Ubuntu 24.04's `mariadb-server` (10.11), with no third-party repository; a pin is
a release series from MariaDB's own repository, checked for by its `Release` file
before apt sees it and installed from that series only, with
`mariadb-client-compat` so `mysql` works either way. Refused together with `mysql=`
(one port, one socket, conflicting packages). `services.d/mariadb.sh` **is the
MySQL adapter** — it sources `services.d/mysql.sh` for the accounts, `MYSQL_USERS` /
`MYSQL_DATABASES`, the endpoint and the ready line — with MariaDB's binaries and
template and its own start: `mariadbd` has no `--daemonize`, so it runs in the
background and is ready only when the server answering on the socket reports
**this** start's `@@pid_file`. `--no-defaults` also drops the package's character
set (bare 10.11 serves latin1), so the package's own `character-set-server` /
`collation-server` / `character-set-collations` are read back from
`--print-defaults` — the official images' utf8mb4 settings, per series. Its
integration case runs on its own `mariadb` image variant. User docs:
`docs/components/mariadb.md`.

**`mongo=ON | <series> | OFF`** bakes `mongod` and `mongosh` from MongoDB's own
repository (the one `db-clients=mongo` uses). `ON` is the 8.0 series; a pin is a
release **series**, `X.Y` (`8.2`), as the repository names them — a release
(`8.0.32`) and a bare major (`8`) are refused with the value to write instead. The
server is installed from that series only (`mongodb-org-server=<series>.*`),
whatever other MongoDB lists the image holds, and a series MongoDB does not
publish for the Ubuntu release fails the build by name before apt sees it. Every
series of a major is signed with the major's key (8.2 with `server-8.0.asc` — there
is no `server-8.2.asc`). At start: `127.0.0.1`, and `::1` (`--ipv6`) where the
container has an IPv6 loopback, no authentication, the WiredTiger cache capped at
0.25 GB (`AI_SERVICES_MONGO_CACHE_GB`; the default takes 1.5 GB of a 4 GB
container). Nothing to provision. x86-64 needs AVX. User docs:
`docs/components/mongo.md`.

Version-list components (`node`, `python`, `ruby`, `rust`, `go`) accept comma-separated version values instead of `ON`/`OFF` (e.g., `node=22,20`). Constraints:
- `angular-cli` accepts only a **single version** (not a comma-separated list).
- `ruby` is a comma-separated list too, like `node`/`python` (e.g. `ruby=3.3.6,3.4.5`) — useful for migrating a project between Ruby versions. Nothing Ruby-related is baked into the image: rvm, every configured version, and installed gems live in a per-user `~/.rvm`, group-mounted like the agent dotfile dirs (see [Host directory mounts](#host-directory-mounts)) and installed additively at container start (`rvm-reconcile.sh`, `flock`-guarded against concurrent same-group starts) — a version's first install compiles it then (can take a few minutes), every later start is instant, and rubies/gems persist per group across container runs. The `rails` key has been removed entirely — Rails is an ordinary per-project gem, not a build-time/`sandbox.conf` concern. After the reconcile, the default Ruby's `ruby`/`gem`/`bundle`/`bundler`/`rake`/`irb`/`erb` are symlinked onto `/usr/local/bin` (`link-default-ruby.sh`, run by the entrypoint as root) so they resolve in **non-interactive, non-login** shells (`docker exec -u "$(id -u)" … bash -c "bin/rails …"`), not only in login/interactive shells that source rvm; per-project gemset selection still comes from `.ruby-version` via a login shell. If an install totally fails, reconcile logs `FAILED: ruby-<version>` and never points the default at a version that isn't installed.
- SDKMAN-managed components (`openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`) require **full patch versions** (e.g., `openjdk=21.0.11`, not `21`).
- Any tool described by a `tools.d/*.conf` descriptor (currently `dtctl`, `dtmgd`, `acli`) accepts `ON` (auto-detect latest from GitHub), `x.y.z` (pinned), or `OFF` — this grammar is independent of the tool, so a future tool added the same way follows it automatically. The one thing that narrows it is a descriptor that cannot *express* a version: `acli` is fetched from a vendor `/latest/` URL with no versioned path (a versioned one returns 403), so its grammar is `ON | OFF` and a pinned value is refused rather than silently ignored.
- `node` always installs the latest LTS (required by the AI agents); `node=20,22` adds those versions alongside it. `nvm-version` pins the nvm release used to install Node (e.g., `nvm-version=v0.40.5`); leave empty for the Dockerfile default.
- `db-clients` also accepts a comma-separated list, but drawn from the closed set `pg`, `mysql`, `mongo` (not version numbers) — installs **client** shells/dev libraries only (`libpq-dev`+`postgresql-client`, `default-libmysqlclient-dev`+`default-mysql-client`, `mongosh`), never a database server, and is language-agnostic. (A server is `postgres=`, below.) An entry outside that set is rejected by `build.sh`'s `validate_config` with a clear error rather than reaching the build. Selecting `mongo` adds `repo.mongodb.org` to the generated domain allowlist automatically. Setting `ruby` to any version, or `db-clients` to a non-empty value, makes `build.sh` set `KEEP_BUILD_TOOLCHAIN=1`, so the Dockerfile keeps `build-essential`/`libyaml-dev`/`zlib1g-dev`/`libssl-dev` instead of stripping them, letting native extensions compile at runtime.
- **A version-list key set to the literal `OFF` means "skip", exactly like the empty `key=`.** The two grammars share one file, so `ruby=OFF` is a natural thing to write; `version_list()` in `sandbox-common.sh` normalises it to empty and `has_versions()` reports it as unset, keeping both consistent with `is_active()`. Use `version_list` — never `get_versions` — wherever a version-list *value* is emitted into a build arg or the container env, because `get_versions` must keep returning `OFF` verbatim for the boolean keys. (Without this, `ruby=OFF` baked the whole Ruby build toolchain **and** shipped `RUBY_VERSIONS=OFF` into the container, so `rvm-reconcile.sh` bootstrapped rvm and ran `rvm install OFF` on every container start, into an `~/.rvm` that `sandbox.sh` — correctly using `is_active` — had not mounted.)

**Schema changes to `sandbox.conf`.** Adding a new on/off or version-list key needs nothing extra: no marker bump, no hook. `sync-to-projects.sh` reconciles each project's copy on every sync — it appends new upstream keys and never touches keys a project already set. Renaming a key, splitting it into multiple keys, removing it, or changing what its value means while keeping the same key name requires a `migrations/NNN-*.sh` hook — author it with `./bump-sandbox-version.sh <slug>`, and see the README "sandbox.conf schema versioning" section. Never redefine an existing key's semantics in place; always introduce a new key name for a semantic change. The reconcile mechanism assumes an existing key's meaning never silently changes underneath a project that has already set it — violating this discipline is not automatically detectable by tooling. `check-sandbox-version.sh --check` is the CI gate that blocks a removal/rename lacking a matching hook and marker bump — in CI it MUST be run with `BASE_REF` set to a ref that predates the change (e.g. `BASE_REF="$(git merge-base HEAD origin/main)"`), never left at its default `HEAD`, which silently no-ops once the change is committed (see README "sandbox.conf schema versioning").

## Commands

**Build the image:**
```bash
./build.sh [image-name]
```
`build.sh` reads `sandbox.conf`, assembles `allowlist-domains.txt`, `allowlist-proxy-domains.txt`, and `allowlist-cidrs.txt` from the `*.d/` fragment directories, then calls `docker build` with one `--build-arg` per component. External CLI tools described in `tools.d/*.conf` (currently `dtctl`, `dtmgd`, `acli`) are the one exception: instead of one `--build-arg` each, every active one is folded into a single `--build-arg TOOL_VERSIONS="dtctl=0.25.0;dtmgd=latest"` (see below). The generated `allowlist-*.txt` files are gitignored; always use `./build.sh`, not `docker build` directly. (`sandbox.sh build` was removed — it now errors and points here.)

The AI agents (Copilot, Claude Code, Codex, Gemini), `graphify`, and `vale` are **not** installed at build time at all — they install at container start into a per-user, group-mounted tool home — `~/.ai-tools` for the npm/uv/binary tools, `~/.local/share/claude` for Claude Code, which installs natively. Whether a tool then self-updates is per-tool and measured; see the table in "Agent-tier tools" below. **Kiro** and every `tools.d`-described tool (`dtctl`, `dtmgd`, `acli`) remain baked at build time and Docker caches those layers, so a normal `./build.sh` will not pick up a newer release of any of them — refresh with a full rebuild:
```bash
./build.sh --no-cache
```
or, where the tool supports it (`dtctl`/`dtmgd` accept a pinned `x.y.z` in `sandbox.conf`), bump the pinned version instead of rebuilding everything.

**Replaced images are cleaned up.** `build_image()` records the tag's image ID before the build and calls `remove_replaced_image` (in `sandbox-common.sh`) afterwards, so a dangling layer set does not accumulate per rebuild per project — from a few hundred MB up to the whole multi-GB image for a `--no-cache` rebuild. Keep that cleanup narrow: one explicit image ID, skipped when the image still carries any tag, `docker rmi` **without** `--force` so an image a container still references survives, and never a broad `docker image prune` (the daemon store is shared with `ai-containers-seed` and every other project's image). An `inspect` of the old ID that **fails** means the image is already gone — Docker's containerd image store deletes it as the build moves the tag — and is not reported; the tag count is read only from an `inspect` that succeeded, because Docker 29's prints an empty line even when it fails (hermetic `tests/test-remove-replaced-image.sh`). Build-cache records are only ever *suggested* for pruning (`docker builder prune --filter unused-for=720h`), never removed automatically.

**Agent-tier tools (`~/.ai-tools`).** Mirroring the per-user rvm approach above: nothing agent-tier is baked into the image. Claude Code, Codex, Gemini, Copilot, `graphify`, and `vale` install at container start into `~/.ai-tools` (npm packages land in `~/.ai-tools/npm`, `graphify`'s `uv` tool dir `~/.ai-tools/uv`, `vale`'s binary in `~/.ai-tools/bin`), group-mounted like the agent dotfile dirs (see [Host directory mounts](#host-directory-mounts)) so the install is shared by every project using that group and survives container restarts and rebuilds. Unlike `uv` (pointed at the tool home via exported `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR`, which nvm never looks at), npm gets **no** baked global prefix — nvm is sourced into every login/interactive shell (`/etc/bash.bashrc`), and its `nvm_die_on_prefix` check fails `nvm use <version>` outright, not just a warning, whenever `$HOME/.npmrc` sets a `prefix`, which broke the `node=` multi-version workflow `sandbox.conf` supports. `agent-tools-reconcile.sh` (sandbox user, `flock`-guarded against concurrent same-group starts) installs whichever `AI_RUNTIME_TOOLS`-enabled npm-based tool is missing with `npm install -g --prefix "$HOME/.ai-tools/npm" <pkg>`, non-fatal on failure. nvm's prefix check inspects `.npmrc`/`$PREFIX`/`$NPM_CONFIG_PREFIX`, never a command's own flags, so a per-invocation `--prefix` does not trip it (verified against nvm's `nvm_die_on_prefix` source, not assumed).

**Which tools can keep themselves current, and which the reconcile has to update.** "The install is user-writable, so each tool self-updates" held for the whole set only until the baked `.npmrc` was removed, and the loss went unrecorded for the sixteen days between that commit and a user hitting it, while the docs kept promising the updater worked. It is now **per-tool, and each row was established by running it in a container** rather than reasoned from the install method:

| Tool | Update mechanism | Reconcile does |
|---|---|---|
| Claude Code | **native** install under `~/.local/share/claude`; `claude update` replaces it in place | install-if-missing |
| Copilot | downloads its own GitHub release, installs in place | install-if-missing |
| Codex | its `update` shells out to a bare `npm install -g` → `EACCES`, `exit status: 243` | **updates every start** |
| Gemini | none — nothing matching update/upgrade in `--help` | **updates every start** |
| `graphify` | `uv tool upgrade` | install-if-missing |
| `vale` | pinned download | install-if-missing |

Claude Code is the reason the table exists. Installed via npm, its self-updater runs a bare `npm install -g`, which resolves to nvm's **root-owned** prefix and fails with `✘ Auto-update failed: no write permission to npm prefix`. Restoring the baked prefix is not the fix: it makes `nvm use <version>` **fail** rather than warn, and nvm's own suggested escape hatch — `nvm use --delete-prefix` — silently deletes the prefix again at runtime, so the repair would quietly undo itself per user. Three other candidates were tried and refuted by test (a wrapper exporting `NPM_CONFIG_PREFIX`, which `nvm_die_on_prefix` catches via an `awk` scan of `ENVIRON` and which a spawned shell inherits; a `prefix=` in node's builtin `etc/npmrc`, which nvm also catches because it reads the *effective* config; and reverting the removal). The native installer sidesteps all of it by not involving npm at any point — verified end-to-end in a **restricted-mode** container, where both the install and `claude update` succeed behind the firewall and `nvm use` still passes afterwards. Its hosts (`claude.ai`, `downloads.claude.ai`, `storage.googleapis.com`) are already in `allowlist-domains.d/claude-code.txt`, and it touches GitHub not at all, so no token is involved. Copilot's updater *does* fetch from GitHub, but `base.txt` already allowlists the release hosts and it needs no token either — also verified in restricted mode, with an empty `blocked-domains.txt`.

Updating Codex and Gemini on every start costs ~7s with a warm npm cache (~24s cold), measured in-container. A group provisioned before this change still carries the npm copy of Claude Code (~300 MB) under `~/.ai-tools/npm`; the reconcile deliberately does **not** delete it — other containers in the same group may be running against it — and falls back to it only when no native install is present. To reclaim it once every container in that group is stopped: `rm -rf ~/.ai-containers/<group>/.ai-tools/npm/lib/node_modules/@anthropic-ai ~/.ai-containers/<group>/.ai-tools/npm/bin/claude`.

For the CLIs still installed through npm, use the baked `npm-agent-tools` shell function instead of a bare `npm update -g` — e.g. `npm-agent-tools update -g` — which forwards `--prefix "$HOME/.ai-tools/npm"` so the update lands in the group-mounted tool home rather than nvm's own node directory (a bare `npm update -g` would update whatever nvm currently has active instead). `npm-agent-tools` is a shell function (not an exported env var), defined alongside `PATH`/`uv` env in `/etc/profile.d/ai-tools.sh`, available in login/interactive shells; it is deliberately not an env var because exporting `NPM_CONFIG_PREFIX` globally would trip the same nvm check the removed `.npmrc` prefix did. `link-agent-tools.sh` then symlinks each installed binary **of a tool this project enabled** (`AI_RUNTIME_TOOLS`) onto `/usr/local/bin` (root, run after the reconcile), and that is the only route onto `PATH` for every shell: the tool home's `npm/bin`, `uv/bin` and `bin` are deliberately **not** on `PATH`. `~/.ai-tools` is shared by the whole group, so it holds every tool *any* project in the group enabled; exposing its directories, or linking by presence alone, made a sibling project's `copilot` runnable in a project with `copilot=OFF` — without that project's `~/.copilot` mount or allowlist fragment, both gated on the key. For the same reason the reconcile's leftover-npm-Claude fallback fires only when `claude-code` is enabled. The `npm-agent-tools` convenience function stays login/interactive-only like the `uv` env.

**The `tools.d/` descriptor model.** Each external CLI tool the image can install (currently `dtctl`, `dtmgd`, `acli`) is described by one `tools.d/<name>.conf` file — `repo=` (GitHub `owner/repo`), `binary=` (installed executable name), `private=yes|no`, `config_dir=` (host-seeded, group-scoped config path, or several space-separated paths for a tool that splits config and credentials — see [Host directory mounts](#host-directory-mounts)), `allowlist_fragment=` (which `*.d/<fragment>.txt` to include), `skills=yes|no`, and `skills_crossclient=` (flags for a cross-client Agent Skill). `tools-lib.sh` is the shared parser, sourced by both host scripts (via `sandbox-common.sh`) and container scripts. `build.sh` turns every tool whose `sandbox.conf` key (`dtctl=`, `dtmgd=`) is `ON` or a pinned version into one `name=version` pair and passes them all as a single `--build-arg TOOL_VERSIONS="dtctl=0.25.0;dtmgd=latest"`. `install-tools.sh` reads `TOOL_VERSIONS` at build time and installs each tool from its descriptor's GitHub repo — adding a new tool this way needs only a new `.conf` file, no changes to `build.sh`, the Dockerfile, or the allowlist logic. `install=` selects how the binary is obtained: `release` (default) downloads the release asset `<binary>_<version>_<os>_<arch>.tar.gz`; `repo-file` fetches a **prebuilt binary committed in the repo** at `repo_path=` (via the contents API with `Accept: application/vnd.github.raw`, straight into `/usr/local/bin`, no archive to unpack); `url` downloads from an arbitrary **vendor-hosted** `url=`, for a tool published outside GitHub — a `.tar.gz`/`.tgz` is unpacked and `binary` is located *anywhere* inside it (vendors commonly nest it in a version-named directory, e.g. `acli_1.3.22-stable_linux_arm64/acli`), any other URL is treated as the binary itself, and no token is involved. `url=` and `repo_path=` accept the **braced** placeholders `${OS}`, `${ARCH}` and `${VERSION}` (braced only — an unbraced `$OS` would also match inside `$OSNAME`). A `url=` without `${VERSION}` cannot honour a pinned version, and says so instead of installing something else silently. An archive holding two files with the target `binary=` name is refused rather than guessed at. `repo_path` may contain `${ARCH}`, expanded to the image's `amd64`/`arm64`. `ref=` pins a branch/tag/commit and the `sandbox.conf` value wins over it, so a `repo-file` tool's key grammar is `ON | <git-ref> | OFF` — there are no release versions to pin. Everything else is identical: `private=yes` still makes `GITHUB_TOKEN` required, failures are still non-fatal, and the tool still lands in the same baked Dockerfile layer, so `./build.sh --no-cache` re-fetches an unpinned tool too (a pinned `ref=`/version is unaffected by cache state). `TOOL_VERSIONS` is `build.sh`'s internal transport: you only construct its `name=version;...` string by hand when calling `docker build` directly, bypassing `build.sh`.

**`GITHUB_TOKEN` essentiality** depends on the descriptor's `private` field:

| Tool visibility | `GITHUB_TOKEN` | Effect if unset |
|---|---|---|
| Public (`private=no` — `dtctl`, `dtmgd`) | Optional | Unauthenticated GitHub API, 60 req/h; pinning a version (e.g. `dtctl=0.25.0`) skips the API call entirely and needs no token at all |
| Private (`private=yes`) | Required | Tool is skipped with a warning; `build.sh` also prints a non-fatal preflight warning before the build starts if a private tool is enabled with no token set |

This open-source repo ships **no private tool** — both `dtctl` and `dtmgd` are public — so no tool in `tools.d/` *requires* a token. `build.sh` passes it automatically as a BuildKit secret if the env var is set (falling back to `GITHUB_PERSONAL_ACCESS_TOKEN`). If a public tool hits the rate limit, `install-tools.sh` prints a warning and skips it — the build still succeeds.

**Setting `GITHUB_TOKEN` is nevertheless STRONGLY RECOMMENDED for building the image, and the reason is not `tools.d/` at all.** Two build layers run vendor installers that `git clone` from github.com — nvm's own install.sh and pyenv's installer (four clones: pyenv, pyenv-doctor, pyenv-update, pyenv-virtualenv). Anonymous git traffic sits in GitHub's low-budget tier, and when that tier throttles the build host those clones fail with `fatal: could not read Username for 'https://github.com'` — a 401 on a **public** repo, which is what GitHub returns to an unauthenticated caller it is throttling. Measured 2026-09-02: this failed a whole build cycle, recurred in bursts over roughly half an hour, and survived a bounded retry loop at both 3 attempts over 30s and 5 over ~150s. In the same container at the same moment an anonymous clone took 401 while an **authenticated** one succeeded.

Both clone layers therefore mount the same `github_token` secret and present it through a **credential helper** (never a URL rewrite — git echoes remote URLs in some failure messages, which would publish the secret into the build log). Git still tries anonymously first and only authenticates when challenged, so the token is headroom rather than a change to the normal path.

**It remains optional, and that is asserted.** With no secret the clones are anonymous exactly as before and the build proceeds; a secret mount with nothing passed is simply empty. Without a token the build is not broken — it is merely at the mercy of GitHub's anonymous throttling, and the failure it produces looks like a network fault rather than a missing credential, which is what makes it worth setting in advance.

**Two variables, one preference.** `build.sh` reads `GITHUB_TOKEN` first and falls back to `GITHUB_PERSONAL_ACCESS_TOKEN`. It reads them from the environment of the shell that launches the build, so a token rotated in `gh` but stale in a shell profile silently reverts the build to the anonymous path — a quiet failure mode whose symptom is the 401 above.

**Run the container:**
```bash
./sandbox.sh restricted [primary]   # firewall on, NET_ADMIN+NET_RAW dropped from agent shell
./sandbox.sh discovery  [primary]   # unrestricted egress + background pcap
./sandbox.sh open       [primary]   # unrestricted egress, NO capture, NET_ADMIN+NET_RAW dropped
```
Everything mounts under a single `/workspace` umbrella. The positional `[primary]` sets the working directory:
- `@<repo>` — a registered repo volume (see `repo.sh`) becomes the working dir at `/workspace/<repo>` (fast on macOS; attached writable automatically, error if listed `:ro`).
- `<host-path>` — bind-mounted at `/workspace/<basename>` (rw) and used as the working dir (virtio-fs; slow on macOS).
- omitted — working dir is the `/workspace` umbrella itself.

**Manage shared repo volumes:**
```bash
./repo.sh add  <name> <host-path|git-url>   # seed a repo volume once + register it
./repo.sh sync <name|--all>                  # refresh (git pull, or re-copy a path source)
./repo.sh reset <name|--all> [--yes]         # clean slate: primary branch @ remote tip, other branches dropped
./repo.sh list [--sizes] [--copies]          # list repos; --copies lists :rwcopy working copies
./repo.sh rm   <name> [--yes]                # remove volume + working copies + registry entry
./repo.sh gc   [--repo <name>] [--unused] [--yes]   # prune :rwcopy working copies
./repo.sh reindex                            # rebuild registry from volume labels
```
Attach them at run time with `REPOS="cluster:ro lib:ro app:rw" ./sandbox.sh restricted @app`.

**`reset` is a full reset, and its git half is a separate file for a testability reason.** For a git-backed volume it fetches (pruning), resolves the remote's **primary branch** — `git remote set-head origin -a` then `refs/remotes/origin/HEAD`, falling back to `origin/main`, `origin/master`, then the checked-out branch, and never a hardcoded `main` — checks it out at the remote tip, runs `clean -ffdx`, and **deletes every other local branch**. Every run, `--yes` included, first prints the branch it will switch to and each branch it will drop, marking those whose commits are on no remote; that listing is built from a read-only `inspect` pass which **is** the fetch, so the counts are current rather than read from stale refs, and the primary branch the summary names is passed to the destructive pass rather than re-derived there. A failed fetch is not fatal: it warns, does the local half, and reports `STALE`. The helper speaks **records** (`DELETED|x`, `ON|y`, `AT|z`) so the tests can read them; `reset_git` captures that stream and renders it as prose, because unrendered it reaches the terminal looking like leaked debug output. Anything it does not recognise is printed **verbatim** rather than dropped — a record type added to the helper later must still reach the user, since silence is the one thing a destructive command must never report. stderr is deliberately not captured, so the helper's own `die` messages arrive unaltered. That git program lives in **`repo-git-reset.sh`**, mounted read-only into the seed container rather than embedded as a `docker run … bash -c '…'` string like `seed_from_git`/`sync_from_git` — because `tests/test-repo-destructive.sh`'s fake `docker` can only record such a string, never run it, and asserting the string is asserting configuration. As a file it runs directly against real repositories in `tests/test-repo-git-reset.sh` (git is available hermetically; docker is not), which is the only place the branch deletions are observed actually happening. It is therefore a **hard member of `AI_CONTAINERS_SHARED_FILES`**: `repo.sh` mounts it from its own directory, so a project copy without it has a broken `reset`.

**Manage container groups:**
```bash
./group.sh list [--sizes]        # groups + their rvm volumes; flags orphaned volumes
./group.sh rm   <group> [--yes]  # remove a group: its directory AND its rvm volume
./group.sh gc   [--yes]          # remove rvm volumes whose group directory is gone
```
A group owns a directory (`~/.ai-containers/<group>/`) **and**, once `ruby=` is set, a Docker volume for its Ruby home — so `rm -rf` alone orphans a multi-GB volume. `group.sh rm` removes both; `gc` cleans up after a manual `rm -rf`. It refuses while a running container mounts the volume, refuses the `host` group, and never touches repo volumes (global, `repo.sh` owns them).

**Initialise a new project** (copies shared files, writes `sandbox.env`, generates launch script, registers in `projects.conf`, and adds `/.ai-containers/` to the project's root `.gitignore`):
```bash
./project-init.sh /path/to/myproject [optional-name]
```
The per-project `.ai-containers/` is a synced working copy; its `sandbox.local.env` holds machine-specific `EXTRA_MOUNTS`/`REPOS` paths, so it is git-ignored in the project by default — idempotent, git repos only, and `sync-to-projects.sh` backfills it for existing projects. Remove the line to version the **portable** config (`sandbox.env`/`sandbox.conf`/thin `runme.sh`) with a team — `sandbox.local.env` stays gitignored on its own — or set `AI_CONTAINERS_NO_GITIGNORE=1` to skip.

**Migrate a project off the old fat `runme.sh`** (one-off; only for projects provisioned before the thin-launcher split):
```bash
./migrate-runme.sh --dry-run /path/to/project   # inspect what would change
./migrate-runme.sh /path/to/project             # migrate
./migrate-runme.sh                              # every project in projects.conf
```
Parses the old launcher's `export` lines into a portable `sandbox.env` plus a machine-local `sandbox.local.env`, then replaces it with the thin `runme.sh` that `project-init.sh` generates — the same `emit_launcher()` function, so the two cannot drift. Old files are copied to `*.pre-migrate` (timestamped if a backup already exists) and never deleted. `--dry-run` writes nothing. Non-interactive: it needs no stdin and prompts for nothing.

**Report what is registered here** (container group, network mode, resources, capture size, per project):
```bash
./ai-containers-report.sh [--markdown|--tsv] [--full-paths] [--no-notes] [--path-map HOST=LOCAL] [BASE_DIR ...]
```
Reads **this repo's `projects.conf`** and resolves each project from its `sandbox.env` (with `sandbox.local.env` overriding), the same precedence `sandbox-common.sh` applies. It deliberately does **not** search the filesystem: an earlier version walked a configurable root to a fixed depth collecting every `project-init.sh`, which answered "what does this whole machine have" rather than "what is this checkout responsible for", and made the answer depend on where it was run from. Naming a `BASE_DIR` is a path, not a search. The `BASE` column appears only when more than one base is in play (with one, the base is stated once above the table); `--tsv` always emits it, so a machine-readable schema does not change shape with the argument count. `VERSION` and `SCHEMA` follow `BASE` (and lead the table when it is absent) and are read through `version.sh`'s `version_engine`/`version_schema`, so they cannot disagree with what `./sandbox.sh --version` reports inside the same project — they are **per project**, because a `.ai-containers/` is a working copy that drifts from its base until it is synced. That makes `version.sh` a hard dependency sitting beside this script, exactly as `bash-floor.sh` is. Like `project-init.sh` and `sync-to-projects.sh` it is a **base-repo** tool and is deliberately **not** in `AI_CONTAINERS_SHARED_FILES` — a project is a leaf and has no registry of its own.

**Sync shared files to all registered projects** (after pulling updates to this repo):
```bash
./sync-to-projects.sh              # all projects in projects.conf
./sync-to-projects.sh /path/to/p   # single project
```

**Run the runtime integration tests** (needs a real Docker daemon — a host, not a sandbox container):
```bash
./tests/integration/run.sh                       # the whole corpus
./tests/integration/run.sh --list                # cases with their tags/requires
./tests/integration/run.sh --list-caps           # what this machine can actually do
./tests/integration/run.sh --tags fast --exclude needs-dns --require security
./tests/integration/run.sh --tags packages --variant native --require packages
```
Cases live in `tests/integration/cases/` and declare `tags:` and `requires:` in header comments; the runner detects capabilities and selects. **Selection and skipping are different outcomes and are reported separately** — `--tags`/`--exclude` choose what runs, a SKIP is a selected case whose requirement was unmet, and `--require <tag>` makes any such skip fail the run. A case that cannot run is never counted as a pass. `--cases <basename>[,…]` narrows further by name, and an unrecognised name fails loudly rather than quietly selecting nothing. `run.sh --help` carries the authoritative tag and capability vocabulary; the tiers are `network-mode`, `delivery`, `mounts`, `volumes`, `groups`, `packages` and `harness`, crossed with `security`, `fast`/`slow`, and the `needs-external`/`needs-netadmin`/`needs-dns`/`needs-multiruby` requirement tags.

**Before changing anything under `tests/`, read [docs/testing.md](docs/testing.md).** The corpus's tiers and image variants, the two harness verbs, the known-bad demonstrations, the falsify tier's measurement discipline and the local layer's phase table live there. What stays here are the rules a change must not break.

**Run everything a host can (the local layer):**
```bash
bash ./verify-on-host.sh
```
It runs phases 0, 5, 7, 6, 4 and **exits non-zero if any selected phase failed**. A new phase that records nothing through `phase_fail`, or a `PHASES` value naming a phase that does not exist, silently verifies nothing; `tests/test-verify-exit-code.sh` guards both.

**Every case must have been seen failing.** A case never observed failing is green because its primitive works, not because the product does. Two mechanisms hold that up ([docs/testing.md](docs/testing.md)): known-bad fixtures under `tests/integration/fixtures/`, which must never be "consolidated" or repaired, and patches under `tests/integration/mutations/` driven by `mutate.sh` — patches rather than `sed`, because a patch that no longer applies fails loudly where a stale `sed` matches nothing and reports success. Two mechanisms hold that rule up, by era:

**The `falsify` tier (`tests/falsify/`) is a different thing from `tests/integration/mutations/`, and the two must not be unified.** Both damage code on purpose; everything else about them differs — what is damaged, in which tree, what is checked, by which oracle, and at what cadence — tabulated in [docs/testing.md](docs/testing.md). A mutant nothing noticed is a **survivor**, and every survivor is owed an entry in `tests/falsify/survivors.txt` classified `GAP:`, `EQUIVALENT:` or `ENV-DEPENDENT:`. Those are different claims and conflating them is how the ledger stops protecting anything.

**Measuring the falsify tier is a batched, Linux-side job, and the per-slice evidence is the DEMONSTRATION, not the score** (the measurements behind that rule are in [docs/testing.md](docs/testing.md)):

- **Per slice: demonstrate.** Damage the specific line the new assertion claims to cover and require that assertion to go red. That costs minutes, and it is the CAUSAL claim — *this* assertion catches *this* damage. It is also the stronger evidence: a score moving by +8 does not say which assertion earned it.
- **Per batch: score, on Linux.** A mutation score is a COVERAGE metric answering "how much is left", which does not change meaningfully between one slice and the next. CI already scores the whole active corpus on every PR; a DEFERRED target needs a two-arm run to show a delta, so run that once per batch of slices, on a host where a mutant costs a second rather than twenty.
- **macOS runs the tier in `verify-on-host.sh` Phase 6**, before a release — not per change. What genuinely needs a Mac is BSD userland in the hermetic suite (Phase 5) and filesystem shapes like F31's APFS reserve band, which are minutes of work, not hours.

The corpus run and the ratchet are **one operation**, in CI and in Phase 6 alike. `check-ledger.sh` scores the ledger against a single run, so a killing assertion and its ledger edit have to be re-derived together on the tree under review; checking against a frozen artefact would measure a tree that no longer exists.

**Extract discovery results** (after exiting a discovery-mode container — the pcap is in `.agent-discovery/` of the launch directory, which is normally the project's `.ai-containers/`):
```bash
./extract-discovery.sh              # hostname lists + what this image would still block
./extract-discovery.sh --clean      # ... and delete the pcap once extracted
./extract-discovery.sh --discard    # drop a capture without extracting it (prompts; --yes skips)
```
`extract-discovery.sh` is a **host** script and ships in `AI_CONTAINERS_SHARED_FILES`, so it sits beside `sandbox.sh` in every project. It resolves `IMAGE_NAME` through `sandbox-common.sh` like every other entry point, defaults the capture directory to `$PWD/.agent-discovery` and falls back to the one beside itself, and mounts that directory **at** `/workspace/.agent-discovery` rather than exposing the whole launch dir. Its coverage report reads the image's own baked `/tmp/allowlist-domains.txt` and `/tmp/allowlist-proxy-domains.txt` and applies the same two matching rules `capture-blocked-traffic.sh` applies at runtime (exact full-line match; leading-`*` stripped and suffix-matched) — so it cannot disagree with what the container would actually do, and duplicates none of `build.sh`'s fragment assembly. **It deletes nothing by default**: the pcap is the only raw evidence and the only file that reaches gigabytes, so `--clean` (post-extract, keeps the hostname lists) and `--discard` (no extract at all) are explicit, and both remove only the specific filenames inside that one directory. `entrypoint.sh`'s discovery banner names the script first and keeps the raw `docker run` as the fallback for a launch directory that has no working copy in it:
```bash
docker run --rm --entrypoint capture-agent-destinations.sh \
  -v "/path/to/launch-dir:/workspace" "${IMAGE_NAME:-ai-sandbox}" extract /workspace/.agent-discovery
```

**Check a release describes what it contains** (run before tagging):
```bash
./changelog-coverage.sh            # what landed since the last tag, and how many Unreleased entries
./changelog-coverage.sh --check    # exit 1 when non-docs commits exist and Unreleased is EMPTY
```
It **reports**; it gates only under `--check`. A per-PR "you changed code, add an
entry" rule was designed first and rejected on measurement: over this repo's own
43 merges since v0.9.3 it fires on about twenty, most of them test-coverage
slices this project deliberately summarises at release time — and the refined
"Unreleased must be non-empty" variant additionally fires on **every release
commit**, because a release moves entries out of `Unreleased` and empties it by
construction (eight false positives in fourteen sampled). A check that cries
wolf on half of all commits is suppressed within a week and then catches
nothing, which is worse than none because it looks like coverage. So the one
mechanical alarm is raised where the omission actually costs something — at
release time, when notes would otherwise publish describing none of the fixes
they ship. That failure happened twice in two days (#200/#201, then #211/#212).

**Report what this is:**
```bash
./sandbox.sh --version     # anywhere; also -V, or `version`
./runme.sh --version       # in a project (short-circuits BEFORE its own ./build.sh)
```
Three numbers from three sources, assembled by `version.sh` (a shared file, so
every project has it after a sync): the **engine release**, the **`sandbox.conf`
schema version**, and the pinned **nvm version**.

The engine release is the only one that can lie, and the design is shaped around
that. In this repo it comes from `git describe --tags` — with the suffix, so a
tree eleven commits past a release reports `v0.7.0-11-g<sha>` rather than
claiming to be the release. A project's `.ai-containers/` is a working **copy**,
not a git repo, so it cannot derive anything: `project-init.sh` and
`sync-to-projects.sh` write `engine-version` into it at copy time, and
`version_engine` prefers that recorded value over git precisely so a copy sitting
inside some unrelated repo cannot report that repo's version. A copy that was
never told says `unknown`.

`nvm-version` is reported because it is **pinned rather than detected** — nvm's
latest cannot be resolved at build time behind a rate limit, and
`.github/workflows/update-nvm-version.yml` exists solely to keep the key current,
so this field is that job's output. An empty key reports the Dockerfile's `ARG
NVM_VERSION` default instead, labelled: the question is what the image will get.

`version.sh` is sourced by `sandbox.sh`, `project-init.sh` and
`sync-to-projects.sh` **directly**, not via `sandbox-common.sh`. That was tried
and reverted the same hour: several test fixtures copy a hand-picked set of
engine files into an isolated tree, and a new hard dependency inside
`sandbox-common.sh` broke twelve of them at once. Only the entry points that call
into it need it — the same reasoning that has nine entry points sourcing
`bash-floor.sh` directly.

**Key env vars for `sandbox.sh`:** set inline for one run (`VAULT_PATH=/path ./sandbox.sh restricted`)
or export in the host shell profile to default for every container. The **In container** column
marks visibility to agents inside the container: **forwarded** (passed through unchanged),
**→ `/path`** (re-exported pointing at the in-container mount path), **mount** (filesystem mount,
no env var inside), **—** (launcher/`docker run` only). `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH`/
`ARCHITECTURE_REPO_PATH` are host-directory pointers meant to be exported once in the host
profile; their effective default is the host-exported value (unset → mount skipped; a target
directory that doesn't exist warns).

The four pointers form a personal / team / product / architecture tier:

| Var | Mount | Meaning | Mode |
|---|---|---|---|
| `VAULT_PATH` | `/workspace/vault` | **Personal** knowledge base (Obsidian vault or any markdown KB) | read-write |
| `SPECS_PATH` | `/workspace/specs` | **Team / shared** specs, designs, plans | read-write |
| `DOCS_PATH` | `/workspace/docs` | **Product documentation** (grounding) | read-only (default) |
| `ARCHITECTURE_REPO_PATH` | `/workspace/architecture` | **Architecture** — standards, radar, ADRs (grounding) | read-only (default) |

| Variable | Purpose | Default | In container |
|---|---|---|---|
| `IMAGE_NAME` | Image tag to run. Persisted per project in `<project>/.ai-containers/sandbox.env` and sourced by `sandbox-common.sh` when not exported. | `ai-sandbox` | forwarded |
| `AI_CONTAINER_GROUP` | Which dotfile tree (group) to mount: `default`, `host` (mounts `$HOME`), or a custom `~/.ai-containers/<name>/`. | `default` | — |
| `AI_CONTAINER_GROUP_INIT` | Non-interactive first-time group bootstrap: `clean` \| `from:host` \| `from:<existing-group>`. | interactive prompt | — |
| `AI_CONTAINER_HOST_ACK` | Set `1` to silently bypass the macOS `host`-group warning. Ignored on Linux; per-invocation. | `0` | — |
| `SANDBOX_UID` / `SANDBOX_GID` / `SANDBOX_USER` / `SANDBOX_GROUP` | Override the auto-detected container user identity. | detected from host (`id`) | forwarded |
| `REPOS` | Space-separated **registered** repo volumes to attach under `/workspace/<name>`, each `:ro` (default), `:rw`, or `:rwcopy`. Register first with `./repo.sh add`; unregistered/missing → abort. | none | mount |
| `REPO_BACKEND` | How a repo is backed: `auto` \| `volume` \| `bind`. Decided at `repo.sh add` time and stored in the registry. | `auto` | — |
| `EXTRA_MOUNTS` | Space-separated extra host paths bind-mounted under `/workspace/<basename>`; append `:ro`/`:rw`. Same-basename collisions with `REPOS`/primary are errors. | none | mount |
| `VAULT_PATH` | Host directory mounted read-write at `/workspace/vault` — your **personal** knowledge base (an Obsidian vault is typical, but any markdown corpus works, e.g. imported Jira tickets under `$VAULT_PATH/jira-products`, read heavily by several workflows). Pair with `qmd=ON` for in-container search. | host `$VAULT_PATH` export | → `/workspace/vault` |
| `SPECS_PATH` | Host repo of AI-ready specifications, design documents, and development plans — the **team/shared** knowledge base — mounted read-write at `/workspace/specs`. Consumed by spec-driven workflows (e.g. the dev-workflows plugin). Accepts `@<name>` for a registered repo volume (mounted at `/workspace/<name>`; fast on macOS). | host `$SPECS_PATH` export | → `/workspace/specs` |
| `DOCS_PATH` | Host **product-documentation** repo mounted **read-only** by default at `/workspace/docs`, re-exported as `DOCS_PATH=/workspace/docs`. Grounding for plugin workflows (idea / VI / release-notes). Accepts `@<name>` (→ `/workspace/<name>`) and a `:ro`/`:rw` suffix (default `:ro`). When the docs repo is the working dir, `DOCS_PATH` re-points to that writable mount; to edit docs otherwise use `:rw`. | host `$DOCS_PATH` export | → `/workspace/docs` |
| `ARCHITECTURE_REPO_PATH` | Host **architecture** repo — standards, technology radar, ADRs — mounted **read-only** by default at `/workspace/architecture`, re-exported as `ARCHITECTURE_REPO_PATH=/workspace/architecture`. Grounding for architecture-aware workflows; the name is the one product-architecture's own MCP server and slash commands read, so they work inside the container unchanged. Same grammar and re-point rules as `DOCS_PATH`: `@<name>` (→ `/workspace/<name>`), a `:ro`/`:rw` suffix (default `:ro`), and the existing mount when that directory is already the working dir or a repo in `REPOS`. | host `$ARCHITECTURE_REPO_PATH` export | → `/workspace/architecture` |
| `REPOS_PATH` | Where code repositories live **inside** the container, for tools that need to find them (e.g. Claude Code plugins). Everything the launcher attaches — the positional `[primary]`, every `REPOS` entry, every `EXTRA_MOUNTS` path — lands under the `/workspace` umbrella, so that is the default. Note `/workspace` also holds `vault`/`specs`/`docs`/`architecture` and the `.agent-*` output dirs, so a consumer should filter (e.g. for a `.git` dir) rather than assume every entry is a repo. Distinct from `REPOS`, which selects **which** repo volumes to attach. | `/workspace` | forwarded |
| `PREVIEW_PORTS` | Space-separated ports (or `host:container` pairs) to publish for dev servers. | none | — |
| `CONTAINER_CPUS` | CPU limit for the running container: a time quota (`--cpus`), not a CPU count. `nproc` and Node's `os.availableParallelism()` still report every CPU the engine has, so a test runner that sizes its pool from them oversubscribes the quota (vitest timed out 16 of 883 tests at `CONTAINER_CPUS=4` on a 16-CPU engine); give it a worker count. | `1.0` | — |
| `CONTAINER_MEMORY` | Hard memory limit. | `4g` | — |
| `CONTAINER_MEMORY_RESERVATION` | Soft memory limit (must be ≤ `CONTAINER_MEMORY`). | `2g` | — |
| `CONTAINER_MEMORY_SWAP` | Memory + swap total (≥ `CONTAINER_MEMORY`; set equal to disable swap, `-1` for unlimited). | `4g` | — |
| `CONTAINER_NOFILE` | Open-file-descriptor limit, `soft[:hard]`. | `1048576:1048576` | — |
| `SELF_HEALING_ENABLED` | Set `0` to disable reactive IP auto-allowing (logging only). | `1` | forwarded |
| `ALLOW_IPV6_BYPASS` | Set `1` to suppress the `ip6tables`-unavailable warning (WSL2/nf_tables). Read by the container's firewall init (`entrypoint.sh`). | `0` | forwarded |
| `COPILOT_GITHUB_TOKEN` | Copilot CLI auth token; bypasses device-flow OAuth. When unset, auto-extracted from the group's `~/.config/gh/hosts.yml`. Accepts a fine-grained PAT with "Copilot Requests" permission or a `gh` OAuth token. | auto from `gh` | forwarded |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | Forwarded as-is for tools that expect this exact name (github MCP servers, Claude Code github plugin). | none | forwarded |
| `SKILL_CHAR_BUDGET` | Characters Copilot CLI may spend listing installed skills to the model, read from the `copilot` process's own environment. It fills the budget plugin by plugin in load order and lists a skill past it by name only, without its description, so the model cannot tell when to use it; each entry costs 93 + its name + its XML-escaped description. Copilot's own default is 15,000. Always passed (`sandbox.sh`: `-e SKILL_CHAR_BUDGET=`), defaulting in code for the reason `REPOS_PATH` does; a host value replaces the default. Being a launcher `-e`, it is refused from `container.env` (`sandbox.sh`: `container_env_filter()`). Hermetic `tests/test-skill-char-budget.sh`. | `25000` | forwarded |
| `SLASH_COMMAND_TOOL_CHAR_BUDGET` | Characters Claude Code may spend listing installed skills to the model. When it is a positive integer it is the budget outright; otherwise Claude Code computes context tokens × 4 × `skillListingBudgetFraction` (default 0.01: 8,000 at a 200K window, every 200K subagent included; 40,000 at 1M) and, over budget, shortens every description (`claude --debug` logs `Skill listing over budget`). **The trade-off:** it overrides `skillListingBudgetFraction` in the user's Claude Code settings, so inside the container that setting is dead and a user who wants another budget exports this variable on the host. The alternative — merging the fraction into the group's `~/.claude/settings.json` — was rejected: nothing in the launcher writes an agent's settings, and in the `host` group that file is the host's own. Always passed (`sandbox.sh`: `-e SLASH_COMMAND_TOOL_CHAR_BUDGET=`), defaulting in code for the reason `REPOS_PATH` does; a host value replaces the default; refused from `container.env` like every launcher `-e`. Hermetic `tests/test-skill-char-budget.sh`. | `40000` | forwarded |
| `CONTAINER_SHM_SIZE` | Size of `/dev/shm` (`--shm-size`). Its SIZE is **not** governed by `CONTAINER_MEMORY` — a 16g container still gets Docker's 64m default and headless Chromium dies on it — though the pages written there ARE charged to the memory cgroup, so it is not free. Passed through unreconciled, unlike the `CONTAINER_MEMORY*` trio. Passed automatically as `1g` when `playwright` is active; set explicitly, it wins for every run. `--ipc=host` is deliberately never used. | Docker's `64m`; `1g` with `playwright` | — |
| `CONTAINER_NAME` | Container name (`--name`), printed at launch. Default: `<project-folder>-<PID>` — the parent of the launch dir, sanitised to Docker's `[a-zA-Z0-9][a-zA-Z0-9_.-]*` (`workspace` if nothing usable is left) — so concurrent containers, even several against the very same workspace, get distinct, legible names instead of Docker's random `adjective_surname`. Set it **inline, for one run**: persisted in `sandbox.env`/`sandbox.local.env` it applies to every launch, and the second concurrent container fails on the name conflict. | derived (see left) | — |
| `SANDBOX_GIT_MAX` | How many git directories a launch protects before it refuses (see **git internals** under Mount layout): each adds bind mounts, and a bind mount adds ~50 ms to every container start on Docker Desktop. Raise it for a tree that legitimately holds more — an AOSP-style checkout. | `200` | — |
| `SANDBOX_ENV_FILE` | Path to a `KEY=VALUE` env-file of non-secret in-container **application** env (e.g. `DB_HOST`, `REDIS_URL`), not credentials. Parsed as docker parses an env-file, then filtered (`sandbox.sh`: `container_env_filter()`) and set aside from the root entrypoint, so it reaches only the sandbox user's processes — see **Launcher config — three env layers**. | `<project>/.ai-containers/container.env` if present, else unset | — |

## Architecture

### Container startup flow

`entrypoint.sh` runs as root and drives all three modes. Before anything else it sets `container.env` aside (`stash_app_env`, see **Launcher config — three env layers**) and checks the launcher mounts (`verify_launcher_mounts`); then:

1. **`setup_sandbox_user`** — creates/renames a user whose UID/GID match `SANDBOX_UID`/`SANDBOX_GID` (passed by `sandbox.sh` from `id -u`/`id -g`). Files in bind-mounted volumes are then accessible without chown. **`chown_workspace_root`** then chowns the in-image `/workspace` umbrella root to the sandbox user (non-recursive; sub-mounts keep their own ownership) so the agent can use it.

2. **restricted mode**: calls `apply_restricted_firewall` → forks the ipset refresh loop and `capture-blocked-traffic.sh` as root background daemons → `run_agent_skill_install` (see below) → `exec capsh --drop=cap_net_admin,cap_net_raw --user=<sandbox>` to drop firewall-modification capabilities from the agent shell.

3. **discovery mode**: calls `apply_discovery_firewall` (iptables OUTPUT ACCEPT) → starts `capture-agent-destinations.sh` for pcap → `run_agent_skill_install` → `exec capsh --drop=cap_net_admin --user=<sandbox>`. The drop names only `cap_net_admin`, but the agent shell ends up with **no capabilities at all**: `capsh --user=` setuids from root, and the kernel clears the permitted and effective sets on that transition unless `PR_SET_KEEPCAPS` is set (`capsh --keep=1`, which is not used). So `--drop=cap_net_admin` and `--drop=cap_net_admin,cap_net_raw` are equivalent here. This is deliberate: the pcap daemon is started as root (entrypoint.sh: `capture-agent-destinations.sh start`), before the exec that hands PID 1 to the agent shell, so it keeps its own capabilities and needs nothing from the agent shell. Verified by case `230-discovery-drops-capabilities` in the integration suite.

4. **open mode**: no firewall is applied and no capture daemon is started (unrestricted egress, no logging) → `run_agent_skill_install` → `exec capsh --drop=cap_net_admin,cap_net_raw --user=<sandbox>` (same capability drop as restricted mode). `sandbox.sh` passes an empty `capabilities=()` array for this mode (neither `--cap-add=NET_ADMIN` nor `--cap-add=NET_RAW`). Equivalent in effect to the historical `DISCOVERY_CAPTURE_ENABLED=0 ./sandbox.sh discovery`, but as an explicit, honestly named mode rather than a flag on discovery. The capability drop is verified by case `240-open-drops-capabilities`; until backlog F7 was closed, nothing verified it, because the case named for the job launched discovery instead.

In all three modes `run_services` is the last step before the `capsh` exec, so the
in-container servers' ready lines are the last output before the prompt — see
[In-container database servers](#in-container-database-servers).

Background daemons are forked **before** `exec capsh` so they retain root capabilities despite the exec. `run_agent_skill_install` runs as the sandbox user (via `runuser`) in all three modes, right before the `capsh` exec — see [Automatic Agent Skill installation](#automatic-agent-skill-installation) below.

### Automatic Agent Skill installation

`install-agent-skills.sh` (copied to `/usr/local/bin/` at build time) installs each installed `tools.d`-described tool's Agent Skill for every enabled AI agent. `entrypoint.sh` runs it via `runuser -u <sandbox> -- env AI_AGENTS_ENABLED="..." bash /usr/local/bin/install-agent-skills.sh`, non-fatally (`|| true` — it never blocks or fails container start). `AI_CONTAINER_GROUP`-independent: it acts on `$HOME` inside the container, i.e. the sandbox user's home, which is where the tool binaries and `~/.agents/` live regardless of group.

- **Which tools:** any descriptor with `skills=yes` (both `dtctl` and `dtmgd` do) whose binary is present on `PATH` (i.e. the tool was actually installed at build time).
- **Which agents:** `sandbox.sh` passes `AI_AGENTS_ENABLED` — a comma-separated list of `sandbox.conf` agent keys that are `ON` (from `sandbox-common.sh`'s `enabled_agents_csv`). `map_agent` translates a `sandbox.conf` key to the tool's `--for` agent name (currently only `claude-code → claude`; everything else passes through unchanged, e.g. `copilot → copilot`).
- **Cross-client skill:** if the descriptor sets `skills_crossclient=` (both `dtctl` and `dtmgd` do), that flag is passed once (e.g. `dtctl skills install --cross-client --global --force`) in addition to the per-agent installs.
- **Idempotent via a version stamp:** `current_stamp` builds one `name=$(binary --version)` line per skills-capable installed tool (sorted); if it matches `~/.agents/.ai-containers-skills-stamp` from the last run byte-for-byte, the whole install step is a no-op. This means a normal container start (same image, same tool versions) does the skill install exactly once, not on every start — it only re-runs after a tool's version changes (e.g. after a rebuild that picks up a newer release).
- **Never fails container start:** each `<tool> skills install ...` call is best-effort (`>/dev/null 2>&1`); a tool with no supported agent, or one that errors, is reported inline (`  <tool> → (no supported agents)`) and does not stop the loop.

### In-container database servers

`start-services.sh` (baked to `/usr/local/bin/`) starts the servers `sandbox.conf`
enabled. `sandbox.sh` passes them as `AI_SERVICES="name=value,…"`
(`sandbox-common.sh`: `services_csv()`), and `entrypoint.sh`'s `run_services`
calls the runner twice: `prepare` as **root**, which creates each service's
directories and hands them to the sandbox user, then `start` via `runuser` as the
**sandbox user** — so no server process is ever root. The runner's path is fixed;
there is deliberately no env override, so no project data file can choose what
root executes. For the same reason **`prepare` runs with a scrubbed environment**:
`env -i` with a fixed `PATH`, and only `PATH`, `AI_SERVICES`, `SANDBOX_UID` and
`SANDBOX_GID` reach it. Adapters run in `prepare` too — the postgres one executes
`<lib root>/<major>/bin/postgres --version` and chowns its socket directory — so
any adapter knob reaching root could choose what root runs or chowns, and a
strip-list would miss every knob added later. `container.env` is set aside from
root before any of this (`stash_app_env`, see **Launcher config — three env
layers**); `prepare`'s scrub does not depend on that alone. `start` runs as the
sandbox user and gets `container.env` back, because it needs its `POSTGRES_*` —
minus the runner's test-only path overrides (`AI_SERVICES_DIR`,
`AI_SERVICES_STATE_ROOT`, `AI_SERVICES_LOG_ROOT`), so `prepare` and `start` agree
on the directories. An adapter's own test knobs are namespaced
`AI_SERVICES_<NAME>_*` (`AI_SERVICES_PG_PORT`, …), never a name an app might set:
`start` sees all of the rest of `container.env`.

Each server is an **adapter**, `services.d/<name>.sh`, sourced in its own subshell
and required to define five functions:

| Function | Contract |
|---|---|
| `svc_installed_version` | print the installed version, or nothing if this image lacks the server. Runs in both phases — in `prepare` as root with the scrubbed environment |
| `svc_runtime_dirs` | print extra absolute directories `prepare` must create, one per line |
| `svc_start <datadir> <logfile>` | initialise and start; return 0 once it accepts connections. Its output goes to the log |
| `svc_provision` | create what the adapter's env asks for; warn per bad entry; print the ready-line suffix on stdout. **Must return 0** — a non-zero is reported as a start failure |
| `svc_endpoint` | print where to connect |

`svc_installed_version`, `svc_runtime_dirs` and `svc_endpoint` run **outside** the
watchdog, so they must return promptly; only `svc_start` and `svc_provision` are
bounded.

The runner owns everything else, once: the 60 s watchdog (`AI_SERVICES_TIMEOUT`;
it keeps the watchdog shape of `tests/portability.sh`'s `p_timeout()` — copied
because the image has no access to that file and macOS has no `timeout(1)` — but
starts the bounded command in its own process group and signals the whole group on
expiry, because adapters start children by design (`initdb`, `pg_ctl`, `psql`) and
a hung child must not survive the deadline), the ready line, the log tail on
failure, the "image has no such server — rebuild" and "sandbox.conf asks for X,
image has Y" warnings (a **warning, never a refusal**, matching
`ai_containers_provenance_warn()`), and the rule that every `prepare`/`start`
path exits 0 (a usage error exits 2). On expiry the group is KILLed again after
`wait`, because a child that ignores TERM outlives the watchdog that would have
sent it; and where `set -m` made no group (no job control) the watchdog signals
the PID instead.

Data is **ephemeral** (`/var/lib/ai-services/<name>` in the container layer, gone
with `--rm`). Do not group-mount it: two concurrent containers in one group would
start two servers on one data directory, and PostgreSQL's `postmaster.pid`
interlock compares PIDs, which are per-namespace.

**Adding a server** is: the key in `sandbox.conf` (+ `validate_config` and a build
arg in `build.sh`), one Dockerfile layer, its name in `services_csv()`, one
adapter, its `docs/components/<name>.md`, a hermetic test with the adapter as a
falsify target, and an integration case with mutations. The runner and the
entrypoint do not change.

### Mount layout (`/workspace` umbrella) and repo volumes

`/workspace` is an in-image directory used as a **mount root**, not a host bind mount. Everything attaches as a subdirectory:
- positional `[primary]` → `/workspace/<basename>` (host bind) or `/workspace/<repo>` (volume, via `@repo`); also sets `-w`
- `REPOS` → `/workspace/<name>` (Docker named volumes, or host binds on Linux)
- `EXTRA_MOUNTS` → `/workspace/<basename>` (host binds)
- `VAULT_PATH` → `/workspace/vault`
- `SPECS_PATH` → `/workspace/specs` (or `/workspace/<name>` via `@name`)
- `DOCS_PATH` → `/workspace/docs` (read-only by default; `/workspace/<name>` via `@name`; the working-dir mount when the docs repo is the working dir)
- `ARCHITECTURE_REPO_PATH` → `/workspace/architecture` (same rules as `DOCS_PATH`)
- outputs → `/workspace/.agent-blocked` and `/workspace/.agent-discovery`, bind-mounted from the host **launch directory** (`$PWD` where `sandbox.sh` ran), so they persist host-visibly and git/docker-ignored.
- launcher directories → mounted again **read-only** inside every writable host bind that exposes them (`sandbox.sh`: `launcher_ro_overlay()`): this launcher's own (`script_dir`, normally `<project>/.ai-containers`) and every other launcher a writable mount exposes (`launcher_dirs_in()`). A launcher is matched by **content** — a directory holding both `sandbox.sh` and `sandbox-common.sh`, ≤6 levels down, pruning `node_modules`/`.git`/`vendor`/`.venv`/`target` — not by the name `.ai-containers`, because an `ai-containers` checkout itself is just as dangerous writable. The default launch (`SANDBOX_WORKDIR=..`) mounts the whole project read-write, and that directory holds what the host runs or reads at the next launch — `sandbox.sh`, the `Dockerfile`/`entrypoint.sh` it builds, `sandbox.env`, `sandbox.conf`, `container.env` — gitignored, so an edit from inside would never show in `git status`. Docker orders mounts by destination depth, so a nested `:ro` bind lands on top regardless of argument order. **Directories between a mount root and a launcher are pinned**: each is bound onto itself `:rw`, because an ordinary directory above a mount point can be renamed and the overlay moves with it, while a mount point cannot be (EBUSY); the documented layout has nothing in between. Candidates are handled shallowest-first, so a launcher **nested** inside another is left under the outer `:ro` overlay rather than given a `:rw` pin that would punch a hole in it. **Robustness is part of the guarantee**, because `sandbox.sh` runs under `set -euo pipefail` and an agent can name and `chmod` directories: the scan and the overlay stay in arrays in the launching shell (`find -print0` into `mapfile -d ''`; no pipeline whose failure could end the loop and leave later mounts unprotected; no newline- or tab-separated records). Each bind is handed to docker in a form that carries it intact (`_bind_mount_arg()`): `-v` by default, which keeps trailing whitespace, tabs, newlines, commas and quotes; `--mount` with CSV-quoted fields only for a name holding `:` (`-v`'s separator), because `--mount` refuses a value ending in whitespace and folds CRLF. A launcher neither can carry — a name that is not valid UTF-8 as RFC 3629 and Go define it (`_utf8_valid()`, read as decimal bytes through `od`/`awk` so no locale or awk changes the answer; not `iconv`, whose glibc build accepts code points above U+10FFFF and five-byte forms), which the CLI rewrites to U+FFFD and Docker Desktop then *creates*, root-owned, in the host directory; or a `:` with trailing Unicode whitespace or any CR — is not mounted, with a `WARNING:`, rather than wedging the launch (`_mount_representable()`). A directory the launching user cannot list but the agent could still reach into — one the agent owns (it can `chmod` it back), or one whose mode lets the agent search it — cannot be searched, so it is treated as if it held a launcher: overlaid read-only, parents pinned, `WARNING:`. The agent's side is decided by mode bits and its single group (it has no supplementary groups; ACLs granting it access are not consulted); the launching user's side by the kernel (`-r`/`-x`), which every directory you do not own reaches, because only the kernel knows which class your supplementary groups and ACLs put you in. A directory nobody but its owner can enter (a database's data directory) hides nothing the agent can touch and is not reported. A writable mount **root** you cannot list can be neither searched nor overlaid, so it refuses the launch. A launcher's `sandbox.sh` may be a symlink. A symlink **inside** a launcher — this one included, mounted or not — whose way out leads somewhere the agent can change gets a `WARNING:`, once per link, naming the first such place: a file it could change, a link on the way it could repoint, or a directory the way steps out of with `..` that it could swap for a link. Links are resolved as the kernel does, one component at a time from a physical directory (`_link_walk()`), so `sub/../x` steps out of where `sub` really leads, and a target's bytes are read exactly (`_readlink_exact()`). Each step is judged **from the container side, after the overlays are decided**, through every writable bind that exposes it: it is safe only if each of them puts it under a read-only overlay, or — for a directory stepped out of — makes it a mount point (a mount root, a pin, an overlay root). A link that stays inside its launcher (and in no writable bind of the launcher's own, such as `.agent-blocked`), ends in another read-only launcher, or leaves every mount is silent. What the agent can write cannot make the check noisy or slow: links that sit in such an inner writable bind are not walked, a launcher that is itself a writable mount root (it got a `NOTE:`) is not walked, and at most 200 links per launcher are, with a `NOTE:` beyond that. A writable bind of a directory **inside** a launcher other than its output directories (say `EXTRA_MOUNTS=…/.ai-containers/tools.d`) keeps those files writable whatever overlay the launcher gets, and gets a `NOTE:` naming it. **A warning, not an overlay**: mounting link targets read-only was tried and made mounts of the wrong paths, file binds that turned `git checkout` of the target into `EBUSY` (a checkout whose `CLAUDE.md` links to `AGENTS.md`), and scans with no bound. `SANDBOX_UID`/`SANDBOX_GID` must be numeric and at most 4294967294, or the launch is refused. A **symlink** on the path this launcher was reached through cannot be pinned (it would be replaced, not renamed); one inside a writable mount gets a `WARNING:` naming the real path to launch from. Limits, pinned by `T27`: six levels below each mount root, and `node_modules`/`.git`/`vendor`/`.venv`/`target` are not searched. The scan costs hundredths of a second on ext4/APFS and far more on a WSL drvfs path under `/mnt/<drive>` (~1,700 entries/s measured), so a large Windows-side mount slows every launch. **A concurrent container on an overlapping writable tree** could swap a launcher mount's source for a symlink between the scan and the moment Docker resolves it, so `sandbox.sh` records each overlay/pin source's `device:inode` and destination in a manifest under `$HOME/.ai-containers/.verify-<pid>-<rand>/`, mounts it read-only at `/run/ai-launcher` (never from `/workspace`), and passes its own `device:inode` as `AI_LAUNCHER_ANCHOR`. The entrypoint's `verify_launcher_mounts()` runs as root before anything else and re-stats every destination: a swapped mount lands on a different inode, so it no longer matches, and the launch is refused. The verify directory is the anchor — if its own `device:inode` does not survive the bind (a file-sharing layer such as macOS Docker Desktop or Colima), verification is skipped with a one-line `NOTE:` rather than refusing every launch; case `460-launcher-mount-verified` probes which kind of host it is on and asserts the behaviour that host must have. The manifest and anchor come from `sandbox.sh`'s own `-v`/`-e`, never from `container.env`, and the verify directory is removed when the launcher exits. The two stats are the one place the host launcher reads an inode, so `_launcher_dev_ino()` probes GNU `stat -c` versus BSD `stat -f` once, as `tests/portability.sh` does (`p_dev_ino()`) — never a fallback on failure, since GNU `stat -f` succeeds and reports the filesystem instead; a stat that cannot run yields an empty anchor and the entrypoint skips. The verify directory is reachable from a container only through a writable mount that exposes `$HOME` itself (a primary or `EXTRA_MOUNTS` of `~`), which already hands the agent your shell's startup files; no group mounts `$HOME` whole — the `host` group mounts its dot-directories one by one. The stale-directory sweep removes only a verify directory older than an hour whose launcher pid is gone, and a removal that fails never stops the launch. Sources are canonicalised with `pwd -P` and compared per path component. A mount that **is** a launcher directory — one rooted at the engine itself (a checkout whose root holds the engine, as the working dir, or a nested engine directory such as mgd-ai-containers' `base/` mounted on its own), or one rooted at a project's `.ai-containers` — cannot be made read-only and stays writable with a `NOTE:`; an engine reached inside a larger writable mount is overlaid like any other launcher. Hermetic `tests/test-launcher-dir-ro.sh`; enforcement in cases `450-launcher-dir-read-only` and `455-launcher-dir-nested-mount` (`tests/integration/lib.sh`: `launcher_engine_in()`).
- git internals → mounted again **read-only** in place, in the same pass (`launcher_ro_overlay()`, after the launchers): the **host's** git runs what a repository's `.git` holds — `hooks/` at the next commit, and `config` keys that run programs (`core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, filters, diff and merge drivers) at the next commit or even `git status` — and nothing under `.git/` shows in `git status` or `git diff`. `git_dirs_in()` matches git directories by **content** (`HEAD` with `config` and `objects/`, or `commondir`): a repository's own `.git`, a bare repository, a submodule's under `.git/modules`, a linked worktree's under `.git/worktrees`. Each gets `hooks/`, `config`, `config.worktree` and `commondir` bound `:ro`, and every `.git` **file** (a linked worktree's or a submodule's checkout, naming its git directory) too. Submodules the scan cannot see — `vendor/` is pruned by name, and submodules often live there — are found through each git directory's `core.worktree` and through every gitlink its **index** records (read with `git -C <worktree> -c core.fsmonitor=false ls-files -s`, from the work tree's root, so a config tampered with before this existed runs nothing), including one whose `.git` is a directory embedded in the checkout. **Two files git honours that a repository normally lacks are made first, as you, so there is something to mount**: `commondir`, which git reads in *any* git directory (an agent could otherwise create one pointing git at a config and hooks of its own), made holding `./` — this directory, which git treats exactly as no `commondir` (measured over commit, merge, rebase, stash, worktrees, `git config`, gc, fsck, submodules and maintenance; the one difference is that `git rev-parse --git-common-dir` prints the path absolute, so a script comparing it with `--git-dir` as strings would take the repository for a linked worktree), as do libgit2 1.7 and 1.9, dulwich and gitoxide; **not** `.`, which libgit2 refuses (`Repository not found`), breaking GitKraken, gitui and the like — and `config.worktree`, made empty where `extensions.worktreeConfig` is on. **They stay**: removing one when the launcher exits would detach it in any other container still running on that repository. A `commondir` already there that is not `./` **refuses the launch**, naming it: git never writes one in a repository's own git directory, and it already sends the host's git elsewhere for config and hooks. `hooks/` is made where a repository lacks one. The directories down to each, **the git directory itself included**, are pinned, so `.git` cannot be renamed out from under the overlay; every bind joins the concurrent-swap manifest. Objects, refs and the index stay writable: commit, branch, push, rebase and stash work (measured). What writes `config` fails with `Resource busy`: `git config`, `git remote add`, `git submodule update --init` (exit 128), and the upstream `git push -u`, `--set-upstream-to` and a tracking `git checkout -b`/`git switch` would record — git prints that tracking was set up and exits 0, but none is recorded. A repository that existed at launch cannot be deleted or removed from inside (`rm -rf`, `git worktree remove`: its pins are mount points, `Resource busy`). A `.git` **symlink** cannot be pinned and gets a `WARNING:`; a `.git`, or a directory inside one, that you cannot list is bound `:ro` whole with a `WARNING:` naming the `chmod` that restores it (an agent owns those directories and could `chmod 000` one to hide what is inside from the next scan). A writable mount rooted **inside** a `.git` gets a `NOTE:`. A `core.hooksPath` that leads into a writable mount gets a `NOTE:`: hooks there are project files the overlay leaves writable, and hook managers keep the scripts they run gitignored (husky's `.husky/_`), so a change need not show in `git status`. So does a hook in `hooks/` that is a **symlink** whose way out the agent can change — judged as launcher links are (`_link_walk()`, `_walk_exposed()`), after every overlay is decided, and only for the names git runs (githooks(5)), so the count stays bounded whatever `hooks/` holds. An `include.path` or `includeIf.*.path` in a protected `config` or `config.worktree` that leads somewhere the agent can write — a file not there yet included — gets a `WARNING:`: git reads the included file as part of the config, so it can set `core.fsmonitor` from wherever it lies. The launch that **first** protects a repository — the one that makes its `commondir` placeholder — names, once, the keys its config already sets that make git run a program (`_git_exec_keys()`: `core.fsmonitor` unless boolean, `core.sshCommand`, filters, diff and merge drivers, credential helpers, `!` aliases, includes, …), names only and never values (a credential helper's can hold a secret), with the `git config --file … --list` that shows them: that launch is the one moment the config can only hold what was set before the protection existed. The same launch names, once, the hooks its `hooks/` already holds that git would run — a name from githooks(5), executable, through a link too — with the `ls -l` that shows them, unless `core.hooksPath` sends git elsewhere (from `config.worktree` only where `extensions.worktreeConfig` is on, since git reads it only then). Handled **shallowest first**, so a repository under a read-only overlay (inside a launcher, under another's `hooks/`) needs nothing more; a launcher that is a writable mount root still gets its `.git` protected. **Every repository is protected** — a cap that left some writable could be filled by the agent (it can make repositories and unlistable directories) to push a real one past it. Each costs four or five bind mounts, and a bind mount adds ~50 ms to every container start on Docker Desktop (measured: 200 binds +10 s), so past 30 a `NOTE:` says so, and past `SANDBOX_GIT_MAX` (200) the launch is **refused**, naming up to five git directories past the limit (the agent can plant them, so the refusal says where) — mount narrower directories, `:ro`, or raise `SANDBOX_GIT_MAX` for a tree that legitimately holds more. The index read passes `-c safe.directory='*'`, so a repository another user owns is followed too (ls-files runs nothing from config once fsmonitor is off). A **named group's** own directories are not scanned (the host's git never runs there, and the plugin marketplaces cloned into them are deleted and re-cloned by the tools that own them, which a pin would break); the `host` group's are, because the host's own tools run git in them — so there a plugin re-clone inside the container can fail with `Resource busy`. Limits: git directories to seven levels (a checkout's own `.git` to six, as for launchers). **Not covered**: configuration poisoned **before** this protection existed is frozen read-only as it is, and the host still runs it — the first protected launch names the keys but cannot tell yours from an agent's, and a repository whose placeholder an earlier engine made gets no list (only `commondir` is refused, because git never writes one there); a file that an included file includes in turn; and a `.git` the agent **creates** in a subdirectory, whose hooks the host's git would run for a command started there before the next launch protects it and names them. Hermetic `tests/test-git-internals-ro.sh`; enforcement in case `465-git-internals-read-only`.

**Repo volumes** (`repo.sh` + `REPOS`) solve the macOS virtio-fs penalty: a repo is seeded **once** into a Docker named volume inside the VM (`ai-containers-repo-<name>`), read at native speed, and shared across all projects/images and container groups. The volume name is **image-independent** (a fixed `ai-containers` prefix, overridable via `REPO_VOLUME_PREFIX`), so one registered repo maps to one global volume that any number of containers — in any project — can mount, with no `IMAGE_NAME` juggling. The registry is `~/.ai-containers/repos.conf` (machine-local, pipe-delimited: `name|type|source|added|synced|backend`). **Docker volumes are the source of truth, not the registry:** each base volume carries `ai-containers.repo`/`.type`/`.source` labels and each working copy carries `ai-containers.repo`/`.workcopy`/`.launch-dir`, so `repo.sh list`/`list --copies`/`gc` read state directly from Docker. The registry is a cache, authoritative only for Linux `bind`-backend repos (no volume to label) and the mutable last-synced time (labels are immutable after creation); `repo.sh reindex` rebuilds it from volume labels. `:rwcopy` creates a per-launch-dir working copy volume (`<base>--wc-<tag>`), prunable via `repo.sh gc`. On Linux, `auto` backend registers `path` repos as bind-mount aliases (no volume seeded); `sandbox.sh` bind-mounts the host path directly. Source-of-truth helpers live in `sandbox-common.sh`.

Seeding (`repo.sh add`/`sync`) runs in a small, **shared** helper image — `ai-containers-seed` (Alpine + git/openssh-client/rsync/bash), built on demand from `Dockerfile.seed`. It is deliberately independent of the sandbox image and of `IMAGE_NAME` (one image reused by every project, not one per project), so repos can be seeded before `./build.sh` is ever run. Override with `REPO_SEED_IMAGE`. These seeding containers run as a plain `docker run` (not via `entrypoint.sh`), so the firewall does not apply to them.

**Launcher config — three env layers.** `container.env` is the *in-container application* env (`DB_HOST`, `REDIS_URL`, …), auto-detected by `sandbox.sh` (`SANDBOX_ENV_FILE`) — unrelated to the two host-side files below. **It never reaches the root entrypoint.** Whoever can commit to the project writes it, and `docker run --env-file` alone hands it to root, where `PATH` picked the bash that `#!/usr/bin/env bash` runs, `XTABLES_LIBDIR` the plugins the firewall's `iptables` loads and `ALLOWLIST_CIDRS_FILE` the allowlist itself; no deny-list could name every key a root tool reads. Two halves: `sandbox.sh`'s `container_env_filter()` parses the file exactly as docker does (measured against the CLI: a BOM dropped from line 1, leading Unicode whitespace and one trailing CR from each line, values literal, a bare `NAME` passed bare for docker to look up) and refuses, with a `WARNING:` naming the line and never the value, what acts **before** the entrypoint's first line can (`env_key_denied`), names the entrypoint could not set aside or give back unchanged (a non-identifier; bash's own variables — those bash overrides or locks at start-up, which `tests/test-env-file.sh` re-measures against whichever bash runs it; `HOME`/`USER`/`LOGNAME`; the entrypoint's own `_aice_*` names; any key this launch passes with `-e` — read from the one `launcher_env` array those flags live in), knobs only root reads (`SELF_HEALING_ENABLED`/`ALLOW_IPV6_BYPASS`, which belong in `sandbox.env`, and the allowlist and capture settings — the test fails if a root-side script reads one that is neither refused nor passed with `-e`), and any variable line docker would refuse — refused **alone**, where docker would have failed the whole launch (a comment is dropped whatever its bytes). The rest goes to docker on a held-open descriptor (`--env-file /dev/fd/N`; a process substitution in an array assignment is closed before docker opens it), with the names in `AI_CONTAINER_ENV_KEYS`. `entrypoint.sh`'s `stash_app_env` sets those keys aside before anything reads the environment — under names that all start `_aice_`, so no key can collide with its own; splitting the list without `read`, so a `TMOUT` key cannot time it out; with `unset -v`, so a key cannot remove a function — and gives them back only to the sandbox user's processes: the `runuser` calls (`as_sandbox_user`), services' `start`, and the login shell, which `capsh` starts as the user (`-- -c 'exec env "$@" /bin/bash -l'`). A `docker exec` session still gets the container's configured environment, `container.env` included — run it with `-u` as the agent rather than as root. Hermetic `tests/test-env-file.sh`; enforcement in case `320-container-env-not-root`. `sandbox.env` (tracked, PORTABLE) and `sandbox.local.env` (gitignored, THIS MACHINE) hold the *host launcher* config: `sandbox.env` carries `IMAGE_NAME`, `AI_CONTAINER_GROUP`, `CONTAINER_*`, `SANDBOX_MODE`, `SANDBOX_WORKDIR`; `sandbox.local.env` carries `AI_CONTAINER_GROUP_INIT` (a host-referential one-time group bootstrap), `EXTRA_MOUNTS`/`REPOS`, and any per-machine override. `sandbox-common.sh`'s `load_env_defaults` parses both (never sources — only `KEY=value`, no arbitrary code) with **set-if-unset** semantics, loading local **before** portable, giving precedence **inline env > `sandbox.local.env` > `sandbox.env`**. Parsing alone is not sufficient for the "inert data" guarantee, so keys that would hand control of the **shell** to the file — `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `CDPATH`, `IFS`, `PS4`, `PATH`, `POSIXLY_CORRECT`, `BASH_COMPAT`, `BASH_XTRACEFD`, `GLOBIGNORE`, every `LD_*`/`DYLD_*` loader var, glibc's `GCONV_PATH`/`LOCPATH`/`GLIBC_TUNABLES`, and `BASH_FUNC_*` — are **refused with a warning** (`env_key_denied`, which `container.env` shares): `sandbox.env` is designed to be committed and shared, and a perfectly well-formed `BASH_ENV=./x.sh` line would otherwise be exported and then executed by the next child `bash` that `build.sh`/`sandbox.sh` spawn. These files configure the launcher, never the shell. Every entry point (`build.sh`/`sandbox.sh`/`repo.sh`) loads them, so all resolve the same config run directly or via the thin `runme.sh`. `sandbox.sh`'s positional `<mode> <workdir>` fall back to `SANDBOX_MODE`/`SANDBOX_WORKDIR` (a positional arg or inline env still wins; with neither, mode → `usage`, workdir → the `/workspace` umbrella), which is what lets `runme.sh` call a bare `./sandbox.sh`. `sync-to-projects.sh` backfills `sandbox.env` for older projects and never overwrites either file; it also **backfills the project's inner `.ai-containers/.gitignore`** (append-only, idempotent) so `sandbox.local.env` is ignored even in a project that predates that pattern — which matters most for a project that deliberately *tracks* `.ai-containers/`, where the root `.gitignore` protects nothing. (Repo-volume names use the global `ai-containers-repo-<name>` scheme, independent of `IMAGE_NAME`.)

### Network enforcement

- `refresh-ipset-allowlist.sh` resolves every FQDN in `allowlist-domains.txt` via `getent` and populates two ipset sets (`allowed_ipv4`, `allowed_ipv6`). It runs at startup and loops every 60 s as a background daemon.
- iptables OUTPUT chain: ESTABLISHED/RELATED → loopback → DNS (port 53) → ipset match → **NFLOG** → default DROP.
- The NFLOG target (group 100) delivers blocked packets to userspace via netlink, which works reliably in WSL2 / nf_tables environments where the LOG target does not.
- **WSL2/nf_tables caveat:** `ip6tables` may be unavailable; when it is, IPv6 outbound traffic is unrestricted. The container prints a warning to stderr at startup. IPv4 enforcement is unaffected.

### Blocked-traffic capture (`capture-blocked-traffic.sh`)

Two background tshark processes:
- **DNS map builder** — sniffs port-53 responses, builds `/run/agent-blocked-internal/dns-map.txt` (IP → FQDN), stored in a root-only directory inaccessible to the sandbox user.
- **NFLOG watcher** — reads packets from `nflog:100`, correlates each destination IP against the DNS map, and appends to:
  - `blocked.log` — full timestamped log
  - `blocked-domains.txt` — deduplicated domains for copy-paste into `allowlist-domains.d/custom.txt`
  - `blocked-ips.txt` — IPs with no known domain, for `allowlist-cidrs.d/custom.txt`

**Self-healing** (on by default): if a blocked IP resolves to a domain already in the baked-in `/tmp/allowlist-domains.txt` or matching a wildcard in `/tmp/allowlist-proxy-domains.txt` (both assembled at build time from the `*.d/` fragments), the daemon calls `ipset add` immediately without waiting for the 60-second refresh loop. This handles dynamic IPs behind CDNs (e.g. `*.githubcopilot.com`).

### Allowlist files

The three `allowlist-*.txt` files baked into the image are assembled at build time from fragment directories:

| Directory | Generated file | Always-included file |
|-----------|---------------|----------------------|
| `allowlist-domains.d/` | `allowlist-domains.txt` | `base.txt`, `custom.txt` |
| `allowlist-proxy-domains.d/` | `allowlist-proxy-domains.txt` | `custom.txt` |
| `allowlist-cidrs.d/` | `allowlist-cidrs.txt` | `base.txt`, `custom.txt` |

Per-component fragments — one `<component>.txt` for each component that needs one (`github-copilot.txt`, `kiro.txt`, `claude-code.txt`, `codex.txt`, `kubectl.txt`, `aws-cli.txt`, `azure-cli.txt`, `openjdk.txt`, … ; `ls allowlist-domains.d/` is the current set, and naming a subset here would rot on the next one added) — are only concatenated when the matching component is `ON` in `sandbox.conf`; `openjdk.txt` when any JDK variant is enabled. Tools described in `tools.d/` name their fragment via the descriptor's `allowlist_fragment=` field instead of a hardcoded component check: `build.sh` auto-discovers every active tool's fragment name and includes it once. Both `dtctl.conf` and `dtmgd.conf` set `allowlist_fragment=dynatrace`, so `dynatrace.txt` is included whenever either (or both) is active — a future tool can reuse that same fragment or declare its own by setting `allowlist_fragment=<name>` and adding `allowlist-domains.d/<name>.txt` (and the matching proxy-domains fragment if needed), with no change to `build.sh` itself.

To add domains not tied to any component (e.g. `google.com`, internal registries, MCP endpoints), edit the appropriate `custom.txt` file in the relevant `*.d/` directory.

**First-time setup:** each `allowlist-*.d/` directory ships a `custom.txt.example`. Copy it to `custom.txt` before adding entries — the `custom.txt` files are gitignored and won't be assembled into the image otherwise.

### Conditional installs in the Dockerfile

Every optional component still baked into the image has a corresponding `ARG INSTALL_<COMPONENT>=0|1` (or, for Angular CLI, `ARG ANGULAR_CLI_VERSION`) declared immediately before its `RUN` block — e.g. Angular CLI, Yarn, Kiro — each with its own `RUN` layer so toggling one doesn't invalidate the others. The six agent-tier tools (Copilot, Claude Code, Codex, Gemini, `graphify`, `vale`) have **no** `ARG`/`RUN` pair at all: they are not part of the Dockerfile build, only scaffolding (`PATH`/`uv` env, the `npm-agent-tools` wrapper function — deliberately no baked npm prefix, see "Agent-tier tools" above) is baked, and the tools themselves install at container start into `~/.ai-tools` (see "Agent-tier tools" above). `tools.d/`-described tools (`dtctl`, `dtmgd`) are the exception among the still-baked components: instead of one `ARG`/`RUN` pair per tool, a single `ARG TOOL_VERSIONS=""` feeds one `RUN` block that copies `tools.d/`, `tools-lib.sh`, and `install-tools.sh` into the image and lets the script loop over every `name=version` pair in `TOOL_VERSIONS`. A tool with no entry in `TOOL_VERSIONS` (its `sandbox.conf` key was `OFF`) is skipped by the script itself, not by a Dockerfile conditional. That one `RUN` layer always mounts the `github_token` BuildKit secret (`--mount=type=secret,id=github_token`), used for both public-tool rate-limit auth and — when a descriptor sets `private=yes` — required private-tool auth; this repo ships no private tool, so today the secret is only ever the optional rate-limit convenience. `install-agent-skills.sh` is copied into the image (`/usr/local/bin/install-agent-skills.sh`) alongside the installer but is not run at build time — it runs at container start (see [Container startup flow](#container-startup-flow)).

### Sandbox user identity

No user is baked into the image. `entrypoint.sh` calls `useradd`/`usermod` at runtime using the env vars from `sandbox.sh`. This means the same image works for any team member without rebuilding.

`sandbox.sh` passes `SANDBOX_UID="${SANDBOX_UID:-$(id -u)}"` / `SANDBOX_GID="${SANDBOX_GID:-$(id -g)}"`. `repo.sh` resolves the **same** values to `chown` repo-volume contents at seed/sync time (it previously hardcoded `id -u`/`id -g`, which broke the override). Because Linux permissions are by numeric UID/GID, you must use the **same** identity for both: with no override they both use the host user; if you override `SANDBOX_UID`/`SANDBOX_GID`, export the same values for both `repo.sh` and `sandbox.sh` or mounted repo volumes end up owned by the wrong UID and the agent hits permission errors. (Linux `bind`-backend repos are mounted directly with no `chown`, so they're unaffected.)

### Host directory mounts

Agent dotfile dirs (`.claude`, `.copilot`, `.kiro`, `.codex`, `.gemini`, `.config/gh`, `.agents`, `.ssh`) are mounted from a **container group**, as are two *install* dirs that are not dotfile config: `~/.local/share/kiro-cli`, and — since Claude Code moved to its native installer — `~/.local/share/claude` (the `versions/<v>` tree) plus `~/.local/state/claude` (the updater's bookkeeping). Those two are group-scoped for the same reason as the rest: without them the install is redone on every container start and every self-update dies with the container, which is the whole capability the native installer exists to restore. The group is a named directory under `~/.ai-containers/<group>/` — a named directory under `~/.ai-containers/<group>/`. The active group is selected by `AI_CONTAINER_GROUP` (default: `default`). To use a custom group, set the env var before running: `AI_CONTAINER_GROUP=docs ./sandbox.sh restricted /path/to/workspace`. A group is *mostly* a plain directory — `ls ~/.ai-containers/` and `cp -a` still inspect and duplicate one — but **deleting is not**: once a group has a Ruby home it also owns a Docker volume, and `rm -rf` orphans it. Use `./group.sh rm <group>` (removes directory + volume together), `./group.sh list`, and `./group.sh gc` (collects volumes orphaned by a manual `rm -rf`). `group.sh` refuses while a running container mounts the volume, refuses the `host` group, and never touches repo volumes (those are global — `repo.sh` owns them).

`sandbox.sh` always creates the group directory and its `.ssh/` + `.agents/` scaffold on first run. Per-component dirs (`.claude/`, `.copilot/`, etc.) are created only when the corresponding component is enabled in `sandbox.conf`.

When `qmd` is enabled, its search index cache (`~/.cache/qmd`, containing `index.sqlite`) is also group-scoped and mounted at `$dev_home/.cache/qmd`, so the index built from `/workspace/vault`, `/workspace/specs`, `/workspace/docs` and `/workspace/architecture` persists across container restarts instead of rebuilding from scratch each run. Because the group is reused across projects while `VAULT_PATH`/`SPECS_PATH`/`DOCS_PATH`/`ARCHITECTURE_REPO_PATH` can point at different host content on each run, the cached index can hold stale or mixed entries for a reused in-container path (e.g. `/workspace/docs` pointed at a different repo than last time) until qmd reindexes it — mounting `DOCS_PATH`/`SPECS_PATH`/`ARCHITECTURE_REPO_PATH` via `@name` gives each source its own path (e.g. `/workspace/docs2`) and avoids the collision. This is an accepted tradeoff: the extra index size/reindex churn is cheap next to rebuilding the whole corpus every run.

When `ruby` has at least one version configured, rvm and every installed Ruby version's gems live in `~/.rvm`, group-scoped like the dirs above but backed by a **Docker named volume** (`ai-containers-rvm-<group>`, `rvm_volume_name` in `sandbox-common.sh`) rather than a host bind mount, on **every** platform. This is not a preference: rvm bootstraps by extracting its release tarball, and GNU tar defers symlinks whose target contains `..` by first writing a mode-000 placeholder file — an operation macOS virtiofs cannot service, so tar fails on exactly the four such members in the rvm tarball and the installer aborts with `Could not extract RVM sources`. A bind-mounted `~/.rvm` therefore can never hold a working rvm on macOS. Plain symlink creation *does* work there (verified), which is why `~/.ai-tools` (npm/uv, direct `symlink()`) is unaffected and stays a bind mount. Linux uses the volume too — one code path beats a macOS-only branch, which is the divergence that hid this bug. `rvm_volume_ensure` creates the volume on first use and migrates a pre-existing *healthy* bind-mounted `~/.rvm` into it once (predicate: a non-empty `scripts/rvm`, the same check `rvm-reconcile.sh` uses), leaving the old directory in place; the debris of a failed bootstrap is deliberately not migrated. `entrypoint.sh`'s `chown_rvm_root` chowns the mount root before the reconcile, because a fresh named volume mounts root-owned and `setup_sandbox_user`'s recursive `chown` uses `-xdev`, which by design does not cross into mounts. `AI_CONTAINER_GROUP=host` keeps the plain bind mount (that group's contract is "mount my real `$HOME`"), so rvm cannot bootstrap in the `host` group on macOS — use a named group. The `-rvm-` infix is load-bearing: it is what keeps `repo.sh`'s discovery (`name=<prefix>-repo-`) and its registry-driven `--all` from ever reaching a group's rubies; `tests/test-repo-registry.sh` and `tests/test-rvm-volume.sh` both assert that isolation. See the README "Ruby (via rvm)" section for the runtime bootstrap/reconcile detail. The baked `/etc/profile.d/rvm.sh` also sets `rvm_stored_umask` before sourcing rvm: rvm decides a loader is "deprecated" by grepping for that variable, and without it every bootstrap prints *"…is deprecated and causes you to have `umask g+w` set in your shell"*. That warning is a **false positive** here — the check never measures a umask, and the `g+w` loader it describes was the old SYSTEM-WIDE multi-user one; this is a per-user install whose loader sets no umask.

`.aws`, `.azure`, `.kube` and `.yarn` are group-scoped too, each gated on its component key (`aws-cli`, `azure-cli`, `kubectl`, `yarn`). They were mounted straight from `$HOME` until this change — not by design, but because they predate the group system and were never revisited. A cloud credential does not deserve a weaker boundary than a Claude Code token, and the group also stops `kubectl config use-context` inside a container from flipping the host's current context out from under whatever else is using it. `_copy_group_slice` carries `.aws`/`.azure`/`.kube` into a group bootstrapped `from:host` or `from:<group>`, and deliberately omits `.yarn`: a regenerable package cache belongs with `.ai-tools`/`.rvm`/`.cache/ms-playwright`, which are group-mounted but never copied, because cloning a group should not clone gigabytes a tool rebuilds by itself.

**An existing group inherits nothing, and that is the one sharp edge.** The bootstrap runs only at group *creation*, so the first container after this change has an empty `~/.aws` and no kubeconfig — silently, since nothing errors — until the files are copied across once: `cp -a ~/.aws ~/.azure ~/.kube ~/.ai-containers/<group>/`. The break is deliberate and recorded in the CHANGELOG rather than papered over with a one-time auto-seed, which would copy real cloud credentials into the group without being asked.

`.gradle` and `.m2` are group-scoped whenever **any** JVM key is set (`openjdk`, `graalvm-ce`, `graalvm-oracle`, `kotlin`, `scala`, `maven`, `gradle`), not only `gradle=`/`maven=`, because `./gradlew` and `./mvnw` need just a JDK. Containers run with `--rm`, and before this every start re-downloaded the wrapper's Gradle distribution and every dependency. Both are caches, so `_copy_group_slice` does not carry them, like `.yarn`. Concurrent builds in two containers of one group share Gradle's file locks, but Gradle asks a lock's holder to release over loopback, which does not cross containers, so the second can wait out Gradle's 60 s lock timeout (hermetic `tests/test-tool-config-mounts.sh`).

Tool config dirs declared via `tools.d/` (`config_dir=`) are group-scoped and seeded once from the host. `dtctl`, `dtmgd` and `acli` are the current examples: on first use in a group, `sandbox.sh` copies the tool's `config_dir` (e.g. `.config/dtctl`) from `$HOME` into the group if it exists there and the group doesn't have it yet, or creates it empty otherwise; every later run mounts the group's copy. This mirrors the agent-credential pattern above, so a sandboxed agent never writes to the developer's real host config. `config_dir=` may list **several space-separated paths**, so a tool that keeps its profile in one directory and its credentials in another gets both group-scoped and mounted. `acli` needs only one (`.config/acli`) because its profiles *and* credentials both live there — the binary is static and uses no OS keyring, so a headless `echo "$TOKEN" | acli jira auth login --email … --site … --token` inside the container persists in the group and every later container in that group is already authenticated.

`.gitconfig` and `.gitignore_global` are **group-scoped** (non-`host` groups): `sandbox.sh` copies them from `$HOME` into `~/.ai-containers/<group>/` on every container start, then mounts from the group copy. This prevents a macOS VirtioFS stale-inode issue where atomically replacing a file on the host (as git, editors, and other tools do) causes the bind-mounted view inside the container to show link count 0 and fail all reads. With the `host` group both files are still mounted directly from `$HOME`. If you edit either file while a container is running, restart the container to pick up the changes.

### macOS host notes

The previous platform-specific redirect (macOS mounted four tools from `~/.ai-containers/` while Linux mounted them from `$HOME`) has been replaced by the unified group system. Both platforms now resolve agent dotfile mounts through the same group root (`~/.ai-containers/<group>/` by default, or `$HOME` when `AI_CONTAINER_GROUP=host`).

The macOS Keychain context remains relevant for the `host` group: Claude Code, GitHub Copilot CLI, Kiro CLI, and GitHub CLI store OAuth tokens in the macOS Keychain rather than in their dotfile dirs. When `AI_CONTAINER_GROUP=host` is set on macOS, a Linux container cannot read those tokens. This is why `sandbox.sh` prints a warning and requires explicit acknowledgement (`yes` at the prompt, or `AI_CONTAINER_HOST_ACK=1`) before proceeding. The default `default` group avoids this issue entirely — it stores all credentials in `~/.ai-containers/default/` using file-based auth that works on Linux and macOS alike.

## Execution layers

The suite that guards this repo runs in three places, and each has a different job:

| Layer | Trigger | Contract |
|---|---|---|
| **PR** | every pull request (`.github/workflows/tests.yml` → `hermetic-checks.yml`, `integration.yml`'s `fast` tier) | fast and cheap; blocks merge |
| **Nightly** | schedule (`.github/workflows/nightly.yml`) | every PR-selected integration **case**, plus whatever integration coverage is too slow or costly for a PR (the `slow`/`needs-dns` tiers, the `packages` tier's image builds, the allowlist-domain health check), plus the same hermetic checks the PR gate runs, via the shared `hermetic-checks.yml` workflow. |
| **Local** — `bash ./verify-on-host.sh` | a human, on a real host | everything nightly runs **+** what CI structurally cannot do: macOS, BSD userland, Colima, real unrestricted network, no cost cap |

The chain **`local ⊇ nightly ⊇ PR`** holds over both integration *cases* and hermetic *checks*, and `tests/test-layer-containment.sh` enforces both mechanically rather than leaving them as prose someone has to remember to keep true.

That guard checks by **effect** — instrumented fakes and a witness log — never by grepping a filename out of the source text. **Do not simplify it back to a text search:** an earlier version was defeated by a comment that merely *mentioned* the check's name, and passed having verified nothing. The full account, and the `tests/layer-checks.conf` registry that keeps its three lists in step, are in [docs/testing.md](docs/testing.md). The checks leg was false until 2026-08-12 — `nightly.yml` scheduled integration jobs only and ran none of `tests.yml`'s three — and was closed by moving `suite`, `suite-floor` and `lint` into `.github/workflows/hermetic-checks.yml`, a `workflow_call` workflow that both `tests.yml` and `nightly.yml` invoke. One definition, so the two layers cannot drift; nightly's caller is gated on the schedule event, because the `workflow_dispatch` inputs exist for mutation demonstrations that break the tree on purpose.

### The phase table

The phases, and the order they actually run in, are tabulated in [docs/testing.md](docs/testing.md).

**1, 2 and 3 are permanently burned and must never be reused.** Increment 3 removed those phases (agent-tier tool install, native package builds, the rvm/Ruby reconcile — all now covered by the integration corpus's `packages` tier instead) and left `VALID_PHASES` so that a stale `PHASES="1 2 3"` fails loudly, naming each phase as unrecognised, instead of `want_phase` matching nothing and the script declaring success having verified zero checks. Reusing 1, 2 or 3 for new content would make that stale value valid again and silently defeat the exact guard this paragraph describes. **Phase 6 was reserved for increment 5's mutation tier and is now defined** — it runs `tests/falsify/run.sh` over the whole corpus and then `tests/falsify/check-ledger.sh` against the result. Keeping it out of `VALID_PHASES` until the tier existed did its job: naming it early failed loudly instead of silently verifying nothing.

`PHASES` defaults to `"4 5 6 7"` (Phase 0 always runs, unconditionally, outside `want_phase`) — a local layer nobody selects by default is not a local layer. `tests/test-verify-exit-code.sh` pins this default explicitly.

### The bash floor

The floor is **5.1**, declared exactly once, in `bash-floor.sh` — a small sourced file, not asserted redundantly wherever it matters. `sandbox-common.sh` sources it (so the entry points that already pulled in the whole library inherit it for free); nine other entry points that don't need the rest of `sandbox-common.sh` source it directly. Raised from the 4.3 this guard enforced before increment 4, because 4.3 was one of three mutually contradictory claims in the repo (`sandbox-common.sh` said ≥4.3, `README.md` said ≥4.4, and three test files claimed to be "written for bash 3.2" while using `local -A`/`local -n` that fails outright below 4.3 — a claim nothing exercised or could exercise, since the product itself refuses to start below 4.3).

What 5.1 excludes, and the symlinked-`TMPDIR` arm that stands in for a Mac CI cannot provide, are in [docs/testing.md](docs/testing.md).

**The floor is tested, not asserted.** A declared floor that no layer exercises is exactly the defect that produced the three-way contradiction above — it survived for months because nothing ran under it. CI's `suite-floor` job and `verify-on-host.sh`'s Phase 5 both run the full hermetic suite inside `ubuntu:22.04` (bash 5.1.16, GNU coreutils) rather than trusting whatever bash the runner or the developer's Mac happens to have. `tests/test-layer-containment.sh` fails if the floor `bash-floor.sh` declares and the image `suite-floor` actually runs ever drift apart — the floor cannot silently become untested again the way 3.2 did.

**`tests/bash-dialect-lint.sh`** is the complementary check in the other direction: no script may use a construct *newer* than the declared floor. It matches raw, unstripped lines (an earlier version stripped comments first, which is unsound — a `#` opening a real comment cannot be told apart from one inside a quoted string or a parameter-expansion prefix by regex alone, and stripping either hid a real violation or created a false one) against a table of post-floor constructs read from `bash-floor.sh`'s declared numbers, so raising or lowering the floor changes what the linter permits with no second edit. A line that must legitimately contain a flagged construct — the rule's own definition, or a test vector whose entire job is to contain the bad code the rule detects — carries a per-line opt-out in the same idiom as this repo's `# shellcheck disable=SCxxxx` comments:

```
# dialect-lint: allow RULE-ID: reason
```

The reason is required and checked for, not merely documented by convention — a marker with nothing after the colon suppresses nothing. This exists because the three bash versions actually in play here are all *different*: the container and CI run 5.2, a developer's Mac typically runs 5.3 via Homebrew, and the floor is 5.1 — a construct written comfortably on the host (e.g. `${ cmd; }` value substitution, 5.3-only) would sail through review and die at container start with nothing else comparing the three.

### `run.sh --dry-run` vs `--list`

`--dry-run` applies the current selection and prints the case basenames it would run, then exits — no image, no container, no docker call. **`--list` is deliberately unchanged**: it catalogues the whole corpus regardless of any selection flag. Redefining what an existing flag means while keeping its name is the failure mode this project refuses everywhere. Detail, and why `--dry-run` is what makes the containment invariant checkable, in [docs/testing.md](docs/testing.md).

### Portability helpers (`tests/portability.sh`)

`tests/portability.sh` is the one place the GNU/BSD differences the hermetic suite depends on are resolved — `p_stat_mode`, `p_stat_meta`, `p_sha1`, `p_md5`, `p_realdir`. A new test that shells out to coreutils for one of those facts uses these helpers rather than open-coding a fallback per call site. What they exist for, and the two classes of failure that produced them, are in [docs/testing.md](docs/testing.md).

### `shared-files.sh`

The single definition of which engine files `project-init.sh` and `sync-to-projects.sh` copy into a project's `.ai-containers/` working copy — an array (`AI_CONTAINERS_SHARED_FILES`), sourced by both, replacing what had been two independently hand-maintained lists that had *already* diverged before this increment: `sync-to-projects.sh` copied `group.sh`, `project-init.sh` did not, and nothing compared the two to notice, so a freshly-initialised project had no `group.sh` until its first sync. `tests/test-shared-files-parity.sh` guards the two callers against drifting apart again. `bash-floor.sh` is a hard, load-bearing member of that list: `sandbox-common.sh` (also in the list) sources it unconditionally, so a project copy missing it fails on its very first `build.sh`/`sandbox.sh`/`repo.sh` invocation. `host-preflight.sh` is hard for the same reason: `build.sh`, `sandbox.sh`, `project-init.sh` and `sync-to-projects.sh` source it and call `host_checkout_preflight`, which **refuses** a CRLF script/Dockerfile/`tools.d` descriptor/allowlist fragment (a Windows-side checkout; a CRLF allowlist line resolves to nothing and silently allows nothing) and **warns** about a WSL checkout under `/mnt/<drive>`. `.gitattributes` (`* text=auto eol=lf`) prevents the CRLF case on a fresh clone; the preflight catches the rest.

### shellcheck gates

`shellcheck` runs as a **gate**, not an advisory, both in CI (`hermetic-checks.yml`'s `lint` job) and locally (Phase 7) — the `|| true` that made it advisory-only is gone. Increment 4 cleared the pre-existing findings backlog first (measured at 75 findings across 25 files: real defects fixed, structural false positives from `local -n` namerefs and sourced-library patterns suppressed at the site with a reason, in the same `# shellcheck disable=SCxxxx: reason` idiom as everywhere else) so the gate lands green rather than red on day one.

Every workflow job names a **pinned** runner image (`ubuntu-24.04`, never `ubuntu-latest`) so "CI passed" keeps meaning one toolchain; `tests/test-workflow-runner-pinned.sh` enforces it. Why that matters, and the measured difference between the two layers' shellcheck versions, are in [docs/testing.md](docs/testing.md).

### Citing code

Comments, docs and this file cite code by what it **says**, never by line
number. Write `<file>: ` followed by a backticked snippet, on one line: a
function as `name()`, or a short literal copied from the line meant.
`tests/test-code-references.sh` checks that every such snippet still occurs in
the file it names. It refuses a numbered reference to any tracked file unless
the line carries `ref-lint: allow: <reason>`, and it refuses a citation split
across two lines, which it could not check. CHANGELOG.md and docs/superpowers/
are dated records and keep their numbers.

Numbers rot on every edit above them, and one number cannot be right in this
repo and mgd-ai-containers at once. On 2026-10-02, 21 of the ~55 in `tests/`
pointed at the wrong code. Detail in [docs/testing.md](docs/testing.md#citing-code).

## Corporate customization

- Edit `sandbox.conf` to enable only the components your team uses.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints) to `allowlist-domains.d/custom.txt`.
- If agent traffic routes through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and proxy IPs/CIDRs to `allowlist-cidrs.d/custom.txt`.
- Review the `IMAGE_NAME` default in `sandbox.sh` before publishing.

