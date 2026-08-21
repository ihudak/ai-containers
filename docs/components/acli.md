# Atlassian CLI (acli)

`acli=ON` installs the **official Atlassian CLI** (Jira, Confluence, and the admin/assets/guard namespaces it ships). It is off by default.

Two things differ from the other tools:

- **No version pinning.** Atlassian publishes every package behind a `latest` URL and supports each release for six months, so the grammar is `ON | OFF` and `acli --version` tells you what you got. Unlike the agent-tier tools, `acli` is baked into the image at build time, so picking up a newer release means `./build.sh --no-cache` (there is no pinned version to bump instead). No `GITHUB_TOKEN` is involved — the download is vendor-hosted.
- **Authenticate once per container group.** `acli` keeps its profiles *and* credentials in `~/.config/acli`, which is group-scoped, and the binary is static with no OS keyring dependency. So a headless login inside the container persists for every later container in that group:

  ```bash
  echo "$ATLASSIAN_API_TOKEN" | acli jira auth login \
    --email you@example.com --site your-org.atlassian.net --token
  ```

  Confluence shares the same credentials. Create the token at <https://id.atlassian.com/manage-profile/security/api-tokens> (a browser step, on your host). Do **not** put the token in the generated `runme.sh`: `sandbox.sh` forwards only an explicit list of variables, so it would not reach the container anyway, and the group-scoped login makes it unnecessary. The interactive `--web` OAuth flow does not work in a container: it binds a loopback callback and expects a local browser.

Its endpoints are allowlisted through the descriptor's `allowlist_fragment=atlassian` (`api.`/`auth.atlassian.com`, plus `acli.atlassian.com` so you can re-download or upgrade the CLI from inside a container, and the `*.atlassian.net` self-healing wildcard for your per-organisation site host). Attachment/media hosts (`api.media.atlassian.com`, `*.frontend.public.atl-paas.net`) and the `acli admin` namespace's `admin.atlassian.com` are **not** included — add them to `allowlist-domains.d/custom.txt` if you need them.

> **Telemetry:** the acli binary embeds a Segment analytics client (`https://api.segment.io` is compiled in and 1.3.22 exposes no opt-out flag). That host is deliberately left out of the allowlist, so usage telemetry **fails closed** inside a `restricted` container. Add it to `custom.txt` only if you want it to leave the sandbox.

---

[← Components](README.md) · [Documentation index](../README.md)
