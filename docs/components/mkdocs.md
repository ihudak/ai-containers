# mkdocs — documentation site generator

`mkdocs` builds and serves a static documentation site from Markdown ([mkdocs.org](https://www.mkdocs.org)). It is installed **with** the [Material theme](https://squidfunk.github.io/mkdocs-material/) in its environment, `uv tool install mkdocs --with mkdocs-material`, because that is the one requirement a docs scaffold typically pins (a `/docs-init` scaffold's `requirements-docs.txt` holds only `mkdocs-material`) and a uv tool sees only the packages it was installed with. It installs at **container start**, not at build time; see the notes below.

```bash
mkdocs=ON    # install mkdocs + mkdocs-material at container start
mkdocs=OFF   # skip (default)
```

Turn it on per project, in a project that builds or serves a docs site. Most projects never need it, which is why it is off by default.

> **Note:** MkDocs is not baked into the image. Like the other agent-tier tools, it installs **unpinned** at container start into the group-mounted `~/.ai-tools` (see [Agent-tier tools (`~/.ai-tools`)](../agent-tools.md)) and is linked onto `PATH`, so it works in non-login shells too. Once installed, later starts reuse it; `uv tool upgrade mkdocs` brings it (and the theme) up to date. Installing the two together also holds `mkdocs` below 2.0: mkdocs-material requires `mkdocs<2,>=1.6`, and MkDocs 2.0 drops the theme and plugin system Material is built on.

> **Note:** The install fetches from PyPI (`pypi.org`, `files.pythonhosted.org`), which is allowlisted in every image, so it works in `restricted` mode with no extra fragment. Plugins a project adds to its own requirements file go in that project's virtualenv (`uv venv && uv pip install -r requirements-docs.txt`), not into the shared tool.

---

[← Components](README.md) · [Documentation index](../README.md)
