# Troubleshooting and host notes

## macOS host notes

The previous platform-specific behavior — where macOS redirected Claude Code, Copilot CLI, Kiro CLI, and GitHub CLI mounts to `~/.ai-containers/` while Linux kept them under `$HOME` — has been replaced by the unified container-group system described above. Both platforms now use the same group-root logic (`~/.ai-containers/<group>/` by default).

The `host` group, which mounted `$HOME`'s dot-directories directly, is gone; on macOS it only half-worked, because Claude Code, Copilot CLI, Kiro CLI and GitHub CLI keep their OAuth tokens in the Keychain, which a Linux container cannot read. Every group stores credentials as files in `~/.ai-containers/<group>/`, which works on both platforms.

> The `~/.ai-containers/` directory name is unrelated to the per-project `<project>/.ai-containers/` asset dirs created by `project-init.sh`. They never collide on disk because one lives under `$HOME` and the other under repo roots.

## Linux hosts with SELinux (openSUSE, Fedora)

openSUSE Tumbleweed and Fedora run the Docker daemon with SELinux enabled: `docker info --format '{{json .SecurityOptions}}'` lists `name=selinux`. A container there runs as the SELinux type `container_t`, and that breaks this project in two places:

- **Mounted host directories are unreadable.** `container_t` may read only files labelled for containers. Your project, vault and group directories carry your home directory's label, so inside the container `ls /workspace/<project>` prints `Permission denied`.
- **Restricted mode cannot build its firewall.** The firewall needs the kernel modules `ip_set_hash_net`, `nfnetlink_log` and `xt_NFLOG`, which the kernel loads on first use, but not when a `container_t` process asks. `ipset create` then fails with `Kernel error received: set type not supported`.

AppArmor, which confines containers on Ubuntu and Debian, blocks neither.

**There is nothing to set up: the scripts detect it.** When the daemon reports SELinux, every container that mounts a host directory runs with `--security-opt label=disable`, which starts it as `spc_t`, a type SELinux does not confine. That covers `sandbox.sh`'s container, `repo.sh`'s seeding containers, `extract-discovery.sh`'s, the floor suite `verify-on-host.sh` runs, and the integration suite's own (`tests/integration/run.sh`). A container that only copies between Docker volumes mounts nothing from the host and keeps its label. What running unconfined costs is in the [security model](security.md#security-model-restricted-mode).

The usual advice for this is the `:z` mount option. It is deliberately not used: it relabels the host directory itself, so every launch would relabel your real repositories, vault and specs, and it does nothing for the kernel modules.

**`SELINUX_LABEL` overrides the detection.** Set it inline, in `sandbox.local.env`, or in your shell profile:

| Value | Effect |
|---|---|
| `auto` (default) | Asks the daemon (`docker info`), and disables labelling only when it reports SELinux. |
| `disable` | Always passes `--security-opt label=disable`. |
| `keep` | Never passes it, so containers stay `container_t`. |

Any other value stops the launch with an `ERROR:`. `keep` works only if you have labelled every directory the launch mounts for containers yourself (for example `chcon -R -t container_file_t <dir>`, or a `semanage fcontext` rule so the label survives a relabel): your project, `~/.ai-containers` itself, `VAULT_PATH`, `SPECS_PATH` and the rest. Label `~/.ai-containers` itself, not only the group under it: each launch writes the record of its launcher mounts to a new `~/.ai-containers/.verify-*` directory, and a new directory takes its parent's label. If the container cannot read that record, the launch prints `NOTE: launcher mounts are not verified against a concurrent-container swap` and starts without the check. Restricted mode with `keep` also needs the three modules loaded before the container starts. A confined container can use them once they are loaded; it just cannot load them. Load them at every boot with:

```
# /etc/modules-load.d/ai-containers.conf
ip_set_hash_net
nfnetlink_log
xt_NFLOG
```

## Claude Code bug: `--dangerously-skip-permissions` still asks for permission

This is a **bug in Claude Code**, not in the container. Started with
`claude --dangerously-skip-permissions`, Claude Code is supposed to run every
tool call without asking. It doesn't: it keeps stopping for permission prompts,
so an unattended session stalls until someone answers it. Setting
`"skipDangerousModePermissionPrompt": true` doesn't help. It only skips the
one-time warning shown when entering that mode, not the prompts after it.

**Workaround:** add a `PermissionRequest` hook that approves every request. Put
it in the Claude Code settings of the [container group](groups.md) you run in,
`~/.ai-containers/<group>/.claude/settings.json` on the host (`default` unless
you set `AI_CONTAINER_GROUP`). Merge it into the existing JSON rather than
replacing the file:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}'"
          }
        ]
      }
    ]
  }
}
```

Restart Claude Code in the container to pick it up. Each group has its own
settings, so add the hook to every group you use.

Know what this does before adding it:

- It approves **every** permission request in **every** Claude Code session of
  that group, with or without `--dangerously-skip-permissions`. The container is
  then the only boundary, which is the point of running agents here: use
  `restricted` mode so egress stays deny-by-default.
- **Add it to the group's `~/.claude`, never your own.** In `~/.claude` on the
  host it would also approve everything for Claude Code running directly on
  your machine, outside any container.
- Remove it once Claude Code fixes the bug and the flag does its job again.

The bug is reported upstream, in several forms. Follow these to know when the
hook can go:
[#99899](https://github.com/anthropics/claude-code/issues/99899) (a deletion
prompt stalls unattended bypass-mode runs indefinitely),
[#99320](https://github.com/anthropics/claude-code/issues/99320) and
[#99894](https://github.com/anthropics/claude-code/issues/99894) (that deletion
check asks in bypass mode about commands that delete nothing),
[#100005](https://github.com/anthropics/claude-code/issues/100005) (Write/Edit
still asks in `--print` mode), and
[#91811](https://github.com/anthropics/claude-code/issues/91811) /
[#95401](https://github.com/anthropics/claude-code/issues/95401) (the VS Code
extension ignores bypass mode).

## Important notes

- Plain `iptables` cannot pre-resolve wildcard domains such as `*.githubcopilot.com` or `*.kiro.dev` into IP addresses. The self-healing daemon handles this reactively by auto-allowing IPs whose resolved domains match wildcard patterns in `allowlist-proxy-domains.d/`. An upstream proxy provides proactive enforcement if available.
- **DNS is unrestricted.** The firewall allows all outbound DNS (port 53) to any resolver. This is required for domain resolution but means DNS tunneling is theoretically possible. For higher-security deployments, restrict DNS to a specific resolver by adding `--dns 8.8.8.8` to the `docker run` command and tightening the iptables DNS rules in `entrypoint.sh`.
- **IPv6 firewall may be unavailable.** Some environments (notably WSL2 with the nf_tables backend) lack `ip6table_filter`. When this happens, the IPv4 firewall works normally but IPv6 egress is completely unrestricted. The container prints a prominent warning at startup. Set `ALLOW_IPV6_BYPASS=1` to acknowledge the risk and suppress the hint.
- **GraalVM Oracle licensing.** The `graalvm-oracle` key in `sandbox.conf` installs Oracle GraalVM, which is free for production use under the [GraalVM Free Terms and Conditions (GFTC)](https://www.oracle.com/downloads/licenses/graal-free-license.html) since September 2023. If you distribute images built with `graalvm-oracle=<version>`, ensure your use complies with the GFTC. GraalVM Community Edition (`graalvm-ce`) is fully open-source under GPLv2+CE.
- **Ruby gem native extensions.** Build tools (`gcc`, `make`, and `-dev` headers) are removed after the image build to reduce image size **unless** `c-toolchain=ON` is set, `ruby=` is set to any version, or `db-clients=` is non-empty, in which case `build.sh` sets `KEEP_BUILD_TOOLCHAIN=1` and the Dockerfile keeps `build-essential`, `libyaml-dev`, `zlib1g-dev`, and `libssl-dev` (see [c-toolchain](components/c-toolchain.md) and [db-clients](components/db-clients.md)). Without one of those keys set, gems with native C extensions (e.g. `nokogiri`, `pg`, `mysql2`) cannot be compiled inside the container with `gem install`; set `c-toolchain=ON` and rebuild. Do not edit the project's `.ai-containers/Dockerfile` instead: it is a shared file, and the next `sync-to-projects.sh` overwrites it without a word. (Ruby itself is installed at container start, not during the image build — see [Ruby (via rvm)](components/ruby.md) — so there is no longer a build-time rvm layer to pre-install gems into.)
- **Go: `go install` tools require `~/go/bin` on PATH.** `go install github.com/some/tool@latest` places the binary in `~/go/bin`. This directory is added to `PATH` via `/etc/bash.bashrc` when Go is enabled, so it is available in interactive shells. Non-interactive scripts that bypass `.bashrc` must set `export PATH="$HOME/go/bin:$PATH"` explicitly.
- **An agent CLI reports `no write permission to npm prefix` and cannot auto-update.** Expected for the CLIs still installed through npm, and not a broken image: there is deliberately no global npm prefix, because one would break `nvm use <version>`. Which CLIs this affects is now narrow — **Claude Code** installs natively and self-updates, and **Copilot** downloads its own release, so neither should ever print this; **Codex** does hit it, and **Gemini** has no updater at all, which is why the reconcile re-installs either one at container start whenever the registry's version differs from the installed one. If you see it from Claude Code, the container is running an image built before the native switch, or the group still holds the old npm copy and no native install — check `ls ~/.local/share/claude`. To update by hand, use `npm-agent-tools update -g` — see [Agent-tier tools](agent-tools.md#agent-tier-tools-ai-tools) for the per-tool table and the reasoning.
- **`WARNING: this image was NOT built from the files in …`** — the image was built from different assets than the ones next to it, which is exactly what you see after `sync-to-projects.sh` and before the next `./build.sh`. It is a warning, never a refusal. See [Which sources produced an image?](multiple-projects.md#which-sources-produced-an-image).
- **`ERROR: these files have Windows (CRLF) line endings`, or `$'\r': command not found`.** The checkout was made or edited by a Windows-side tool. Strip the CRs from the files it names in WSL (`sed -i 's/\r$//' <file>...`), or re-clone inside WSL. See [Getting started](getting-started.md) for why a Windows-native or `/mnt/c` checkout breaks.
- **`WARNING: … is on the Windows filesystem (/mnt/c)`.** It works, but mounts are slow and the repo's symlinks are unreadable to Windows-side git tools (`Function not implemented`). Clone inside WSL (e.g. `~/dev`) instead.
- **`project-init.sh`/`sync-to-projects.sh` require `rsync`, which Git for Windows' bundled bash does not ship.** Both scripts now check for it up front and exit with a clear error if it's missing — but before that check existed, a missing `rsync` under `set -euo pipefail` killed `sync-to-projects.sh` silently after only printing `Syncing → ...`, copying nothing at all (not even the files that would normally be copied before the first `rsync` call). This is the concrete failure behind the general "run the scripts from inside a WSL2 shell" rule in [Getting started](getting-started.md) for Windows — WSL distros ship `rsync` by default.
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
