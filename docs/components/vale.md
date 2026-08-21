# vale — prose / style linter

`vale` is a markup-aware linter for prose ([vale.sh](https://vale.sh)). It is commonly run as a "style check" phase in documentation workflows; without it installed, that phase is skipped with a warning. It is a single self-contained Go binary (no extra dependencies), installed from GitHub releases (`vale-cli/vale`) — at **container start**, not at build time. See the note below.

```bash
vale=ON    # install the latest Vale binary from GitHub releases
vale=OFF   # skip (default)
```

> **Note:** Vale is not baked into the image — like the other agent-tier tools, it installs **unpinned** at container start into the group-mounted `~/.ai-tools` (see [Agent-tier tools (`~/.ai-tools`)](../agent-tools.md)) and self-updates in place; there is no build-time step to refresh.

> **Note:** The binary download and `vale sync` (which fetches style packages such as `Google`, `Microsoft`, `write-good`) use GitHub hosts (`github.com`, `*.githubusercontent.com`) that are allowlisted by default; `vale.sh` is added when `vale=ON` for package-index lookups. If your `.vale.ini` pulls packages from another host, add it to `allowlist-domains.d/custom.txt` and rebuild. Repos that vendor their `StylesPath` need no network at all.

---

[← Components](README.md) · [Documentation index](../README.md)
