# Dynatrace CLIs (dtctl / dtmgd)

`dtctl` and `dtmgd` are the two tools currently shipped through the generic `tools.d/` descriptor mechanism (`tools.d/dtctl.conf`, `tools.d/dtmgd.conf` — see `AGENTS.md` for the field reference). Any future external CLI tool added the same way follows the identical `sandbox.conf` grammar, pinning guidance, and token behavior described here.

Each supports three modes:

```bash
dtctl=ON        # auto-detect and install the latest release (uses GitHub API)
dtctl=0.25.0    # install exactly v0.25.0 — no GitHub API call, fully reproducible
dtctl=OFF       # skip entirely
```

**When to pin a version instead of `ON`:**
- **Reproducibility** — a pinned build always installs the same binary; `ON` tracks upstream, so the same `sandbox.conf` can produce a different image on a later rebuild.
- **Rate-limit escape hatch** — pinning makes zero GitHub API calls, so it works with no `GITHUB_TOKEN` at all, even past the 60 req/h unauthenticated ceiling.
- **A broken upstream release** — if the current `latest` release regresses for your use case, pin the last known-good version until it's fixed upstream.

When set to `ON`, the build calls the GitHub API to find the latest release. The unauthenticated rate limit is 60 requests/hour. If you hit it:

**Option 1 — set a GitHub token** (raises limit to 5000 req/h, token never stored in the image):
From your project's `.ai-containers/` directory:

```bash
export GITHUB_TOKEN=ghp_yourtoken
./build.sh          # or just ./runme.sh, which builds and then starts the container
```

`./build.sh` also falls back to `GITHUB_PERSONAL_ACCESS_TOKEN` if `GITHUB_TOKEN` is unset, so if you already export the former in your shell profile (recommended — see [GitHub tokens at runtime](../security.md#github-tokens-at-runtime)) the build is authenticated automatically with no extra step.

**Option 2 — pin a specific version** (no API call at all):
```bash
# In sandbox.conf:
dtctl=0.25.0
dtmgd=0.0.23
```

If the API call fails (rate limit, bad token, or network error), the build prints a clear warning, skips the tool, and **continues successfully**. dtctl/dtmgd can be installed manually later, or by pinning a version and rebuilding. An expired or invalid `GITHUB_TOKEN` is treated the same as a network error — the build does not fail, but the tool is skipped with a warning.

> **Note on token security:** `GITHUB_TOKEN` is passed as a [BuildKit secret](https://docs.docker.com/build/building/secrets/) — it is never written to any image layer or visible in `docker history`. Safe to use even if you plan to publish the image. Requires Docker ≥ 23 (BuildKit default).

> **`GITHUB_TOKEN` is always optional for dtctl/dtmgd.** Both are public GitHub repositories, so the token is purely a rate-limit convenience — it raises the `ON` auto-detect API ceiling from 60 to 5000 req/h and nothing more; it is never *required* to install either tool. Pinning a version (Option 2 above) avoids needing a token at all. The `tools.d/` descriptor format also supports a `private=yes` flag for tools whose GitHub repo is private, which *would* make `GITHUB_TOKEN` required for that tool — but this open-source repo ships no private tool, so the token stays optional here regardless of which mode you use.

> **`TOOL_VERSIONS` is `build.sh`'s internal transport, not something you normally set.** `./build.sh` reads each tool's plain `sandbox.conf` key (`dtctl=`, `dtmgd=`) and generates one `--build-arg TOOL_VERSIONS="dtctl=0.25.0;dtmgd=latest"` (a semicolon-separated `name=version` list covering every active `tools.d`-described tool) passed to `docker build`. You never write `TOOL_VERSIONS=` by hand in normal use — only if you bypass `build.sh` and invoke `docker build` directly does its raw build-arg form matter, and even then you construct it by hand from the same `name=version` syntax.

> **Agent Skills install automatically.** Once `dtctl`/`dtmgd` is built into the image, its Agent Skill is installed for every enabled AI agent the first time a container starts, and refreshed automatically whenever the tool's version changes — no manual registration step, unlike `graphify` above (which needs `graphify install` run once by hand). See `install-agent-skills.sh` / `AGENTS.md` for details.

---

[← Components](README.md) · [Documentation index](../README.md)
