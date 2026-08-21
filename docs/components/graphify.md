# graphify — code-to-knowledge-graph tool

`graphify` transforms code, docs, and other files into interactive knowledge graphs using Claude AI. It is a Claude Code skill — the binary is installed into the image at build time, but the skill must be registered in `~/.claude/` once at runtime.

```bash
graphify=ON    # install the graphify binary (PyPI package graphifyy — double-y)
graphify=OFF   # skip (default)
```

**First-time setup** (inside the container, after the first start):

```bash
graphify install   # registers the Claude Code skill; persists via the ~/.claude bind-mount
```

Because `~/.claude/` is bind-mounted from the host, running `graphify install` once inside any container makes the skill available in every subsequent container start without reinstalling.

> **Note:** Persistence requires `claude-code=ON` in `sandbox.conf`, which is what provides the `~/.claude/` host bind-mount.

> **Note:** Only the Anthropic API (`api.anthropic.com`) is allowlisted by default. graphify also supports Google Gemini, OpenAI, DeepSeek, Moonshot/Kimi, AWS Bedrock, and Ollama — if you configure graphify with a non-Anthropic provider, add its API domain to `allowlist-domains.d/custom.txt` and rebuild.

---

[← Components](README.md) · [Documentation index](../README.md)
