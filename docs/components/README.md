# Components

Everything optional in the image is switched on or off in one file: **`sandbox.conf`**, in your project's `.ai-containers/` directory. Nothing here is installed unless you ask for it.

After changing the file, rebuild:

```bash
./.ai-containers/build.sh
```

## Two kinds of key

**Boolean components** are `ON` or `OFF`. Commenting the line out means the same as `OFF`.

```bash
copilot=ON
kubectl=ON
azure-cli=OFF
```

**Version-list components** take a comma-separated list of versions to install:

```bash
node=20,22          # in addition to the always-on latest LTS
python=3.12,3.11
openjdk=21.0.11,25.0.2
```

Leaving the key empty (`key=`) skips the component. Because the same file holds boolean keys, an explicit **`key=OFF` is accepted on a version-list key too, and means exactly the same as empty** — so `ruby=OFF` skips Ruby rather than being read as a version named "OFF".

Two runtimes have an always-on baseline that you get whether you ask or not, because the AI agents need them: **latest LTS Node** and **latest stable Python**. A version list adds versions *alongside* that baseline; it does not replace it.

JVM versions must be **SDKMAN identifiers**, which are full patch versions — `21.0.11`, not `21`. Run `sdk list java` inside a container to see what is available.

## The complete key reference

Every key in `sandbox.conf`. Keys with more to say than a line link to their own page.

### AI agents

| Key | Values | What it does |
|---|---|---|
| `copilot` | ON / OFF | GitHub Copilot CLI |
| `claude-code` | ON / OFF | Claude Code CLI |
| `codex` | ON / OFF | OpenAI Codex CLI |
| `gemini` | ON / OFF | Google Gemini CLI |
| `kiro` | ON / OFF | Kiro CLI |
| `graphify` | ON / OFF | [Code-to-knowledge-graph tool](graphify.md) |

The agent CLIs themselves are **not baked into the image** — they install at container start into a group-mounted `~/.ai-tools`. See [Agent-tier tools](../agent-tools.md).

### Java / JVM (via SDKMAN)

SDKMAN is installed automatically as soon as any JVM key has a version. SDKMAN itself is always the latest release — it cannot be pinned — so use `./build.sh --no-cache` to pick up SDKMAN updates.

| Key | Values | What it does |
|---|---|---|
| `openjdk` | versions | Adoptium Temurin JDK (`21.0.11` → `21.0.11-tem`) |
| `graalvm-ce` | versions | GraalVM Community Edition (`25.0.2` → `25.0.2-graalce`) |
| `graalvm-oracle` | versions | GraalVM Oracle, free for production since 2023 (`25.0.3` → `25.0.3-graal`) |
| `kotlin` | version | Kotlin compiler |
| `scala` | version | Scala compiler |
| `maven` | version | Apache Maven, e.g. `maven=3.9.9` |
| `gradle` | version | Gradle build tool |

Both GraalVM variants also install the `native-image` toolchain.

### Node.js (via nvm)

| Key | Values | What it does |
|---|---|---|
| `node` | versions | Extra Node versions **alongside** the always-on latest LTS |
| `nvm-version` | tag | Pins the nvm release itself (e.g. `v0.40.6`); empty uses the Dockerfile default |
| `yarn` | ON / OFF | Yarn package manager |
| `pnpm` | ON / OFF | pnpm package manager |
| `bun` | ON / OFF | Bun runtime and package manager |
| `angular-cli` | ON / version / OFF | Angular CLI, **single version only**. Adds ~300–500 MB |

`pnpm=ON` installs pnpm globally via npm at build time rather than through corepack: corepack ships with Node, but the sandbox user cannot enable it at runtime because the nvm directory is root-owned.

### Other language runtimes

| Key | Values | What it does |
|---|---|---|
| `python` | versions | Extra Python versions alongside the always-on latest stable (via pyenv) |
| `ruby` | versions | [Ruby via rvm](ruby.md) — installed at container start, not baked |
| `rust` | `stable` / `beta` / `nightly` / version | Rust toolchain via rustup |
| `go` | version | Go, from the official go.dev tarball |
| `goreleaser` | ON / OFF | [Release automation](goreleaser.md); does not require `go` |

### Cloud and infrastructure

| Key | Values | What it does |
|---|---|---|
| `github-cli` | ON / OFF | GitHub CLI (`gh`) |
| `kubectl` | ON / OFF | Kubernetes CLI |
| `aws-cli` | ON / OFF | AWS CLI |
| `azure-cli` | ON / OFF | Azure CLI |

### Vendor CLIs

| Key | Values | What it does |
|---|---|---|
| `dtctl` | ON / version / OFF | [Dynatrace CLI](dynatrace-clis.md) |
| `dtmgd` | ON / version / OFF | [Dynatrace managed CLI](dynatrace-clis.md) |
| `acli` | ON / OFF | [Atlassian CLI](acli.md) — **no version pinning** |

### Build and native tooling

| Key | Values | What it does |
|---|---|---|
| `db-clients` | `pg`, `mysql`, `mongo` | [Database client tools](db-clients.md) — clients only, never servers |
| `c-toolchain` | ON / OFF | [A C compiler and headers](c-toolchain.md), for cgo and native extensions |
| `shellcheck` | ON / OFF | The shell linter this repo gates on — Ubuntu's package, the **same version CI runs** |

### Browser automation

| Key | Values | What it does |
|---|---|---|
| `playwright` | ON / version / OFF | [Playwright browser OS dependencies](playwright.md) — baked at build time; **raises `/dev/shm`** |

### Media and documents

| Key | Values | What it does |
|---|---|---|
| `imagemagick` | ON / OFF | [ImageMagick](imagemagick.md) |
| `wkhtmltopdf` | ON / OFF | [wkhtmltopdf](imagemagick.md) runtime libraries plus the standalone binary |
| `vale` | ON / OFF | [Prose and style linter](vale.md) |
| `qmd` | ON / OFF | On-device markdown search, for use with `VAULT_PATH` |

## Schema versioning

`sandbox.conf` carries a `# schema-version:` line. It is bumped **only** when a `migrations/` hook is added — a rename, split, or removal. Adding a plain new key needs no bump, and `sync-to-projects.sh` appends new upstream keys without touching values a project has already set.

---

[← Documentation index](../README.md)
