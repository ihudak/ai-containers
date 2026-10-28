# graphify — code-to-knowledge-graph tool

`graphify` transforms code, docs, and other files into interactive knowledge graphs using Claude AI. It is a Claude Code skill — the binary installs at container start into the group's `~/.ai-tools` (see [Agent-tier tools](../agent-tools.md)), but the skill must be registered in `~/.claude/` once at runtime.

```bash
graphify=ON    # install the graphify binary (PyPI package graphifyy — double-y)
graphify=OFF   # skip (default)
```

**First-time setup** (inside the container, after the first start):

```bash
graphify install   # registers the Claude Code skill; persists in the group's ~/.claude
```

`~/.claude/` is mounted from the container group (`~/.ai-containers/<group>/.claude` on the host), so running `graphify install` once makes the skill available in every later container of the **same group** without reinstalling. It does not reach other groups, or Claude Code on the host.

> **Note:** graphify depends on `tree-sitter`, which publishes compiled wheels and can lag a new CPython release. When the install fails on the image's Python, it is retried once on the previous minor, downloaded into the group's `~/.ai-tools/uv/python` if the image lacks it (see [Agent-tier tools](../agent-tools.md)).

> **Note:** Persistence requires `claude-code=ON` in `sandbox.conf`, which is what mounts the group's `~/.claude/`.

> **Note:** Only the Anthropic API (`api.anthropic.com`) is allowlisted by default. graphify also supports Google Gemini, OpenAI, DeepSeek, Moonshot/Kimi, AWS Bedrock, and Ollama — if you configure graphify with a non-Anthropic provider, add its API domain to `allowlist-domains.d/custom.txt` and rebuild.

---

[← Components](README.md) · [Documentation index](../README.md)
