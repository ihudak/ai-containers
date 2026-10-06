# Claude Code's own sandbox

```bash
claude-code-sandbox=ON    # sandbox the shell commands Claude Code runs
```

Off by default. It adds a second boundary inside the container, around the shell
commands Claude Code itself starts — a test run, a build, a package install and
the install scripts it pulls in — and nothing else: Claude Code's own file edits
and web fetches are untouched, and so is every other agent. Copilot, Codex, Gemini
and Kiro run in the same container exactly as before, and their commands get no
sandbox from this key — but they do run under its cost (below).

## What it does

The image gains `bubblewrap` and `socat`, and
`/etc/claude-code/managed-settings.json` from
[`claude-managed-settings.json`](../../claude-managed-settings.json). Claude Code
reads that file in every session, and neither user nor project settings can
override it. A command Claude runs then:

| Boundary | Inside the container today | With `claude-code-sandbox=ON` |
|---|---|---|
| Network | every allowlisted domain (GitHub, Atlassian, registries, …) | package registries only (`network.allowedDomains`); any other host is refused, never prompted (`strictAllowlist`) |
| Writes | everything the agent user can write, `~/.ssh` and other mounted repositories included | `/workspace`, the per-user temp directory and the package caches (`filesystem.allowWrite`); Claude Code's own configuration is always protected |
| Credentials | `GITHUB_PERSONAL_ACCESS_TOKEN`, `COPILOT_GITHUB_TOKEN` and the rest of the environment | those, `GITHUB_TOKEN` and `GH_TOKEN` unset before each command (`credentials.envVars`) |
| Escape | — | none: Claude cannot rerun a failed command outside the sandbox (`allowUnsandboxedCommands: false`), and a session whose sandbox cannot start exits rather than run without it (`failIfUnavailable`) |

The sandbox holds under `--dangerously-skip-permissions`: that flag decides
whether a tool call runs, not what a sandboxed command can reach. What it does
change is the unsandboxed retry, which it would run without asking — the reason
the file sets `allowUnsandboxedCommands` to `false`.

### Commands that run outside it

`git`, `gh`, `acli`, `dtctl` and `dtmgd` are listed in
`excludedCommands`: they need hosts and tokens a registries-only sandbox refuses
(`git push` over SSH cannot go through the sandbox's proxy at all). They run as
they do today, with the container's firewall as their boundary. A repository's
git hooks run with them.

## What it costs

**The container runs under two profiles of its own:** `--security-opt
seccomp=<…>/ai-containers-sandbox.seccomp.json --security-opt
apparmor=ai-containers-sandbox`. bubblewrap has to create its namespaces, then
mount and `pivot_root` inside them, and Docker's default profiles refuse both:

- **The namespace — AppArmor.** Where Docker's kernel is Ubuntu 24.04's — on a
  Mac, the Linux VM Docker runs in; measured in a Lima VM —
  `kernel.apparmor_restrict_unprivileged_userns=1` refuses it under
  `docker-default` (`unshare(CLONE_NEWUSER)` fails with `EPERM`), and still
  strips it of its capabilities under `apparmor=unconfined` (integration case 790:
  `setting up uid map: Permission denied`). A process confined by a profile that
  grants `userns` is exempt, so the container runs under
  [`ai-containers-sandbox.apparmor`](../../ai-containers-sandbox.apparmor):
  Docker's default profile plus `userns`, `mount` and `pivot_root`.
- **The namespaces and the mounts — seccomp.** Docker's seccomp profile refuses
  `clone` with a namespace flag, `unshare`, `mount` and `umount2` to a container
  without `CAP_SYS_ADMIN`, which this one never holds, and `pivot_root` to every
  container.
  [`ai-containers-sandbox.seccomp.json`](../../ai-containers-sandbox.seccomp.json)
  is Docker's default profile, as Docker 29.8 ships it, with those five allowed:
  what bubblewrap 0.9 calls on the path Claude Code takes — `unshare` for the
  second user namespace it creates whenever it mounts `/dev`. `setns`, `bpf`,
  `sethostname` and the rest of what Docker reserves for `CAP_SYS_ADMIN` stay
  refused. Unlike the AppArmor profile it needs no loading: the Docker client
  reads the file and sends it with the container.

Both apply to every process in the container — every agent's, Copilot's, Codex's,
Gemini's and Kiro's included, none of which gains the inner sandbox: five more
syscalls than Docker's seccomp profile allows, and AppArmor confinement with three
more permissions than Docker's default. The network firewall, the non-root user
and the dropped capabilities are unchanged.

**Measured.** Integration case 790 passes under both profiles, network namespace
included, on an `ubuntu-24.04` runner, with bubblewrap given the flags Claude Code
passes it. Two of the seccomp profile's five additions were measured
load-bearing: without `unshare`, bubblewrap stops at `unshare user ns: Operation
not permitted`; without `pivot_root` (mutation `790-seccomp-refuses-pivot-root`),
at `pivot_root: Operation not permitted`. The other three, `clone`, `mount` and
`umount2`, it calls on every start.

On a Mac, with the AppArmor profile loaded in its Colima VM and
seccomp still lifted entirely — the run predates the seccomp profile — a Claude
Code session started with the sandbox up (`failIfUnavailable` on) and its
sandbox refused a write to the home directory (`Read-only file system`) and a
request to a host off the allowlist (the sandbox proxy's `403`) — in a container
in OPEN mode, with no firewall of its own.

`enableWeakerNestedSandbox` is set because, in a container, bubblewrap cannot
mount a fresh `/proc`; the sandbox bind-mounts the container's instead, so a
sandboxed command can see the container's other processes. Claude Code's
documentation says to use it only where the outer container is the isolation
boundary — which here it is.

## Before turning it on

- **Load the profile once, as root, where Docker's kernel runs** — on a Mac, in
  the VM Docker runs in, not macOS. A copy under `/etc/apparmor.d` is loaded again
  on every boot:

  ```bash
  # Mac, Colima (Lima: limactl shell <instance> -- …; Linux: run it with sudo directly)
  colima ssh -- sudo sh -c "cp '<path>/ai-containers-sandbox.apparmor' /etc/apparmor.d/ai-containers-sandbox && apparmor_parser -r /etc/apparmor.d/ai-containers-sandbox"
  ```

  The path is your project's `.ai-containers/ai-containers-sandbox.apparmor`;
  Colima and Lima share your home directory with the VM by default. Until the
  profile is loaded, `sandbox.sh` stops before starting the container and prints
  these commands with the path filled in — a container started without it would
  stop every Claude Code session at startup (`failIfUnavailable`).
- **Not measured: Docker Desktop.** Its LinuxKit VM's AppArmor and user-namespace
  settings were not examined.
- A package source outside the list — a private registry, a Git dependency — is
  refused. Add its host to `network.allowedDomains` in
  `claude-managed-settings.json` and rebuild.
- A token your env file passes under another name reaches sandboxed commands
  unless you add it to `credentials.envVars`.
- **Not yet measured:** whether a sandboxed command reaches a service this
  container runs (`services.d`, such as `postgres=ON`) on `localhost`. The sandbox
  routes a command's network through Claude Code's proxy, so a test suite that
  connects to the database directly may be refused.

---

[← Components](README.md) · [Documentation index](../README.md)
