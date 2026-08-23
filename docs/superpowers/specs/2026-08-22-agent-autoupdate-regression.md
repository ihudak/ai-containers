# Agent self-update is a REGRESSION, not a missing feature

**Status:** **CLOSED for Claude Code, 2026-08-23** — shipped, and verified in a
real container three times over (native install present, `nvm use` working
alongside it, the group-mounted install reused on restart rather than
re-downloaded). **Copilot was never affected**; it self-updates and was
deliberately left alone. **Codex and Gemini remain unable to self-update** — the
reconcile updates them on every container start instead, which is the working
arrangement and not a defect, and the Open question below is the only part of
this entry still live.

This status line said OPEN for a day after the work landed. That is the same
bookkeeping failure the falsify backlog's headings had, which cost real work
three times — see the note at the top of
`2026-08-14-falsify-backlog.md`. A status nobody can see is a status nobody acts
on, and one that is wrong is worse.

Originally recorded 2026-08-22, after a user hit it as an
unexplained error in a running container.

**The one-line version.** The machinery for refreshing the agent layer without a
full rebuild was deliberately retired, *on the stated grounds that each tool's own
auto-updater would take over*. Three days later a different fix removed the thing
that made those auto-updaters work. Neither half is in place now, and nothing
recorded the connection.

---

## The three commits

**1. 2026-08-03 — `23e6ad6`, and the CHANGELOG entry that goes with it.** The six
agent-tier tools moved from baked build-time installs to a runtime
`~/.ai-tools` home. The entry retires the old machinery in as many words:

> This retires the entire `AGENTS_CACHE_BUST` build-arg / `.agents-cache-bust`
> persistence mechanism and the `AGENT_REBUILD_MAX_AGE_HOURS`/`AGENT_REBUILD_ACK`-driven
> staleness prompt in `sandbox.sh` — there is no longer a periodic "image is N hours
> old, refresh the agents?" rebuild step, and no build-arg to bust.

and it says why that is safe:

> keeping a tool current afterwards is that tool's own job (its own auto-updater,
> `npm update -g`, `uv tool upgrade`, …), **which now works because the install lives
> in a user-writable directory instead of a root-owned image layer**

That is the promise the retirement was traded for. It was true when written: the
image baked `/etc/skel/.npmrc` with `prefix=${HOME}/.ai-tools/npm`, so
`npm prefix -g` resolved somewhere the sandbox user could write.

**2. 2026-08-06 — `bc2e551`, "stop baking a global npm prefix; it breaks `nvm use`".**
Correct on its own terms: a `prefix=` line makes nvm's `nvm_die_on_prefix` **fail**
`nvm use <version>` outright rather than warn, which broke the `node=22,20`
workflow `sandbox.conf` advertises. But removing it made `npm prefix -g` resolve to
nvm's own root-owned node directory, so **every npm-based agent CLI lost the ability
to update itself** — the exact capability three days of design had just leaned on.
The commit records what it fixed. Nothing records what it cost.

**3. 2026-08-22 — it surfaces.** A container reports
`✘ Auto-update failed: no write permission to npm prefix · Run claude doctor`.
`docs/agent-tools.md` still promised the auto-updater worked, so the first
conclusion drawn was a stale image. Fixed in ai-containers #88 / mgd #81, but that
only stopped the documentation lying — it left the regression standing.

## Why this is a regression and not a gap

Two capabilities existed at different times and neither exists now:

| | targeted agent refresh | tool self-update |
|---|---|---|
| before 2026-08-03 | yes (`AGENTS_CACHE_BUST`) | no (root-owned image layer) |
| 2026-08-03 → 08-06 | retired | **yes** |
| 2026-08-06 → today | retired | **no** |

The only way to update an agent today is a full image rebuild — which is worse than
either predecessor, and is the state the 2026-08-03 work existed to escape.

**Reimplementing `AGENTS_CACHE_BUST` is not the answer** and is explicitly not
proposed here. It was retired for good reasons (a build-arg cache-bust, a persisted
token file, a staleness prompt on every launch, and three CHANGELOG entries' worth
of follow-up bugs). The right fix restores the capability that replaced it.

## The fix, verified rather than argued

Claude Code ships a **native install** that uses no npm at all, so nvm's check never
fires and the multi-version workflow is untouched. Tested 2026-08-22 against an
isolated `HOME` in a running container:

```
✔ Claude Code successfully installed!    Version: 2.1.231
```

| fact | how it was established |
|---|---|
| the launcher is `~/.local/bin/claude`, a symlink | observed in the scratch install |
| versions live in `~/.local/share/claude/versions/<v>` | observed — **not** `~/.claude/local`, which an earlier reading of the binary's strings had suggested |
| the repo can group-mount that | `sandbox.sh:789,792` already mounts `~/.local/share/kiro-cli` the same way |
| the firewall already permits the updater | `allowlist-domains.d/claude-code.txt` carries `downloads.claude.ai` and `storage.googleapis.com`, the second with the comment "used by the native installer/auto-updater" |
| nvm is unaffected | no npm invocation, so no npmrc, `$PREFIX` or `$NPM_CONFIG_PREFIX` for `nvm_die_on_prefix` to find |

Someone had the native path in mind when that allowlist comment was written. It was
never revisited after the prefix was removed.

### Planned change

1. `agent-tools-reconcile.sh` — install `claude-code` natively instead of
   `npm install -g --prefix`; install-if-missing keyed on
   `~/.local/share/claude`.
2. `sandbox.sh` — group-mount `~/.local/share/claude` and `~/.local/state/claude`,
   beside the existing kiro-cli line, so versions survive container restarts the way
   `~/.ai-tools` does today.
3. `link-agent-tools.sh` — prefer the native launcher over an npm copy when both
   exist, so `/usr/local/bin/claude` resolves to the one that can update itself.
4. **Remove the superseded npm copy** of Claude Code from `~/.ai-tools/npm` once the
   native install is in place (~300 MB per group). Approved by the repo owner
   2026-08-22. Narrow by construction: only the package `agent-tools-reconcile.sh`
   installed itself, only when a working native install exists.
5. Tests — the reconcile oracle asserts the native path is taken, that no npm prefix
   reappears, and that the npm copy is removed only after the native install
   succeeds.

### Scope, stated plainly

**Claude Code only.** Codex, Gemini and Copilot CLI stay on npm and keep
`npm-agent-tools update -g`, because no native installer has been verified for them.
That leaves three tools still unable to self-update; it is a partial fix and is
recorded as one rather than described as a complete one.

### What cannot be checked in-container

The end-to-end proof needs a real image build and container start, which the
in-container agent cannot do. The hermetic reconcile oracle covers the logic against
stubs; the Host Agent has to confirm a built container installs natively, resolves
`claude` to the native launcher, self-updates, and still passes
`tests/integration/cases/720-node-multiversion-nvm-use.sh`.

## Open question

Whether the same treatment is available for the other three CLIs, or whether
`npm-agent-tools update -g` stays their answer permanently. Not investigated;
recorded so it is not mistaken for settled.
