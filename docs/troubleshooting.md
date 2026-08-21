# Troubleshooting and host notes

## macOS host notes

The previous platform-specific behavior — where macOS redirected Claude Code, Copilot CLI, Kiro CLI, and GitHub CLI mounts to `~/.ai-containers/` while Linux kept them under `$HOME` — has been replaced by the unified container-group system described above. Both platforms now use the same group-root logic (`~/.ai-containers/<group>/` by default).

The macOS Keychain context is still relevant if you use `AI_CONTAINER_GROUP=host`. Those four tools store OAuth tokens in the Keychain rather than in their dotfile dirs, which is why the `host` group on macOS prints a warning and requires explicit acknowledgement. With the default `default` group, credentials are stored in `~/.ai-containers/default/` as plain files, and there is no Keychain barrier.

> The `~/.ai-containers/` directory name is unrelated to the per-project `<project>/.ai-containers/` asset dirs created by `project-init.sh`. They never collide on disk because one lives under `$HOME` and the other under repo roots.

## Important notes

- Plain `iptables` cannot pre-resolve wildcard domains such as `*.githubcopilot.com` or `*.kiro.dev` into IP addresses. The self-healing daemon handles this reactively by auto-allowing IPs whose resolved domains match wildcard patterns in `allowlist-proxy-domains.d/`. An upstream proxy provides proactive enforcement if available.
- **DNS is unrestricted.** The firewall allows all outbound DNS (port 53) to any resolver. This is required for domain resolution but means DNS tunneling is theoretically possible. For higher-security deployments, restrict DNS to a specific resolver by adding `--dns 8.8.8.8` to the `docker run` command and tightening the iptables DNS rules in `entrypoint.sh`.
- **IPv6 firewall may be unavailable.** Some environments (notably WSL2 with the nf_tables backend) lack `ip6table_filter`. When this happens, the IPv4 firewall works normally but IPv6 egress is completely unrestricted. The container prints a prominent warning at startup. Set `ALLOW_IPV6_BYPASS=1` to acknowledge the risk and suppress the hint.
- **GraalVM Oracle licensing.** The `graalvm-oracle` key in `sandbox.conf` installs Oracle GraalVM, which is free for production use under the [GraalVM Free Terms and Conditions (GFTC)](https://www.oracle.com/downloads/licenses/graal-free-license.html) since September 2023. If you distribute images built with `graalvm-oracle=<version>`, ensure your use complies with the GFTC. GraalVM Community Edition (`graalvm-ce`) is fully open-source under GPLv2+CE.
- **Ruby gem native extensions.** Build tools (`gcc`, `make`, and `-dev` headers) are removed after the image build to reduce image size **unless** `ruby=` is set to any version or `db-clients=` is non-empty, in which case `build.sh` sets `KEEP_BUILD_TOOLCHAIN=1` and the Dockerfile keeps `build-essential`, `libyaml-dev`, `zlib1g-dev`, and `libssl-dev` (see [db-clients](components/db-clients.md)). Without one of those two keys set, gems with native C extensions (e.g. `nokogiri`, `pg`, `mysql2`) cannot be compiled inside the container with `gem install`; add `build-essential` back to the Dockerfile if you need to install such gems at runtime. (Ruby itself is installed at container start, not during the image build — see [Ruby (via rvm)](components/ruby.md) — so there is no longer a build-time rvm layer to pre-install gems into.)
- **Go: `go install` tools require `~/go/bin` on PATH.** `go install github.com/some/tool@latest` places the binary in `~/go/bin`. This directory is added to `PATH` via `/etc/bash.bashrc` when Go is enabled, so it is available in interactive shells. Non-interactive scripts that bypass `.bashrc` must set `export PATH="$HOME/go/bin:$PATH"` explicitly.
- The per-component domain fragments are a practical baseline, not a guarantee that every future agent endpoint is covered. Use discovery mode to find gaps.
- The asset set is intentionally CLI-only and does not depend on VS Code dev containers.
- All optional components — including Kiro CLI — are controlled solely by `sandbox.conf`. There is no runtime auto-detection.
- **Angular CLI** (`angular-cli=ON`) is included as a dev tool because AI coding agents frequently scaffold and modify Angular projects. It is not an AI agent itself.
- **Image size** depends heavily on which components are enabled. A minimal image (just Node.js + Python + one AI agent) is ~2–3 GB. With all JVM toolchains, multiple Node/Python versions, Ruby, Rust, Go, and all AI agents enabled, expect 8–12 GB. Disable unused components in `sandbox.conf` to reduce size and build time.

## Corporate customization points

- Edit `sandbox.conf` to enable only the components your team actually uses.
- Edit these in **your project's** `.ai-containers/` — `custom.txt` is never synced, so the central copy does not reach an existing project.
- Add environment-specific FQDNs (internal Git, artifact repos, MCP endpoints, search engines) to `allowlist-domains.d/custom.txt`.
- If agent traffic must go through a corporate proxy, add wildcard patterns to `allowlist-proxy-domains.d/custom.txt` and allow only the proxy IPs in `allowlist-cidrs.d/custom.txt`.
- The `custom.txt` files in each `*.d/` directory are **gitignored** to prevent internal hostnames and IPs from being committed. Each directory ships a `custom.txt.example` template; `./build.sh` auto-copies it to `custom.txt` on first run.
- The sandbox user identity (`SANDBOX_UID`, `SANDBOX_GID`, `SANDBOX_USER`, `SANDBOX_GROUP`) is detected automatically from the host user at runtime. No build-time args needed. If you override `SANDBOX_UID`/`SANDBOX_GID`, set the **same** values when running `repo.sh` (it chowns repo-volume contents to that identity) as when running `sandbox.sh` — see the identity warning under [Shared repo volumes](repos-and-mounts.md#shared-repo-volumes-native-speed--reposh-and-repos).
- Review the default values in `sandbox.sh`, especially `IMAGE_NAME`, before publishing this into a separate repository.

---

[← Documentation index](README.md)
