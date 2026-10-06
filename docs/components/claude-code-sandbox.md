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

**The container runs with `--security-opt seccomp=unconfined --security-opt
apparmor=unconfined`.** bubblewrap has to create a user namespace, then mount and
`pivot_root` inside it, and Docker's default profiles refuse both:

- **The namespace — AppArmor.** In a running container of this image (its mgd flavour) on a Mac,
  whose Docker runs in a Lima VM on Ubuntu 24.04's kernel, `unshare(CLONE_NEWUSER)` fails with `EPERM` under the
  `docker-default` profile. Docker's seccomp profile allows that call
  ([Docker: seccomp](https://docs.docker.com/engine/security/seccomp/)), so the
  refusal is AppArmor's.
- **The mounts — seccomp.** Docker's seccomp profile gates `mount`, `umount2`,
  `pivot_root` and `setns` on `CAP_SYS_ADMIN`, which this container never holds.

Lifting both weakens the outer container for every process in it — every agent's,
Copilot's, Codex's, Gemini's and Kiro's included, none of which gains the inner
sandbox — to strengthen the boundary around Claude Code's commands alone. Where
agents other than Claude Code do much of the work, that is a poor trade. The
network firewall, the non-root user and the dropped capabilities are unchanged.

`enableWeakerNestedSandbox` is set because, in a container, bubblewrap cannot
mount a fresh `/proc`; the sandbox bind-mounts the container's instead, so a
sandboxed command can see the container's other processes. Claude Code's
documentation says to use it only where the outer container is the isolation
boundary — which here it is.

## Before turning it on

- **It does not start where Docker's kernel is Ubuntu 24.04's.** On a Mac that
  is the Linux VM Docker runs in — Colima's and Lima's default Ubuntu image
  among them — not macOS. Measured by integration case
  790 on GitHub's `ubuntu-24.04` runners, with both profiles lifted: bubblewrap
  creates its user namespace but cannot use it — `setting up uid map: Permission
  denied` without a network namespace, and `loopback: Failed RTM_NEWADDR:
  Operation not permitted` with one, which Claude Code's network isolation needs.
  The host's `kernel.apparmor_restrict_unprivileged_userns=1` strips the
  namespace of an unconfined process of its capabilities, and nothing inside the
  container can lift it. It takes a change where that kernel runs — in the VM,
  on a Mac (`colima ssh`, or `limactl shell <instance>`): that setting turned off
  there, or an AppArmor profile for the container that grants `userns`.
  Where the sandbox cannot start, Claude Code exits at startup
  (`failIfUnavailable`) rather than run unsandboxed — so on such a host, turning
  the key on stops every Claude Code session.
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
