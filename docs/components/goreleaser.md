# goreleaser — release automation

`goreleaser` automates building and publishing release artifacts for Go (and other) projects. The latest GoReleaser OSS is installed from the official apt repository at build time.

```bash
goreleaser=ON    # install the goreleaser binary from repo.goreleaser.com
goreleaser=OFF   # skip (default)
```

> **Note:** GoReleaser is self-contained and does **not** require `go` to be enabled — the apt package's recommended `golang` dependency is skipped (`--no-install-recommends`). Enable `go` alongside it only if you also want the Go toolchain for building. The two are independent.

> **Note:** Publishing a release reaches `github.com` (and `objects.githubusercontent.com`), which are allowlisted by default. If you publish to a different host (GitLab, Gitea, a custom registry), add its domain to `allowlist-domains.d/custom.txt` and rebuild.

---

[← Components](README.md) · [Documentation index](../README.md)
