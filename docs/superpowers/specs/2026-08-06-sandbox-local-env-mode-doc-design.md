# sandbox.local.env: document SANDBOX_MODE and always write the file

**Status:** IMPLEMENTED — `SANDBOX_MODE` / `SANDBOX_WORKDIR` fall back through `sandbox.local.env`, and the docs describe it.

## Problem

`project-init.sh` writes `SANDBOX_MODE=open` into `sandbox.env` (the portable,
tracked config), but `sandbox.local.env` (the gitignored, machine-specific
config) currently:

- is only written when `extra_mounts` or `group_init` was supplied at init
  time — a project with neither gets no `sandbox.local.env` at all, and no
  hint that one is available for local overrides.
- never mentions `SANDBOX_MODE`, so a developer wanting to run one project in
  `restricted` mode locally (while the shared portable default stays `open`)
  has no discoverable way to find out that's possible.

## Design

1. `sandbox.local.env` is always written, unconditionally, alongside
   `sandbox.env`.
2. Its header comment documents every override option as a reference (each
   line commented out except the active `AI_CONTAINER_GROUP_INIT=`/
   `EXTRA_MOUNTS=` lines already conditionally appended today):

   ```
   # sandbox.local.env — THIS MACHINE's launcher config (gitignored, not shared).
   # Overrides sandbox.env (loaded at higher precedence: inline env > sandbox.local.env > sandbox.env).
   # Uncomment/add only what this machine or this one-off run needs:
   #   EXTRA_MOUNTS="/abs/path /another:ro"   # host bind mounts (Linux-native; absolute paths)
   #   REPOS="app:rw lib:ro"                  # named-volume repos (./repo.sh add; macOS perf)
   #   SANDBOX_WORKDIR=@app                   # named-volume working dir (macOS)
   #   AI_CONTAINER_GROUP_INIT=from:host      # one-time group bootstrap: clean|from:host|from:<group>
   #
   # SANDBOX_MODE overrides the portable default (currently "open" in sandbox.env). Options:
   #   restricted  firewall enabled, NET_ADMIN/NET_RAW dropped from the agent shell
   #   discovery   unrestricted egress + background pcap capture
   #   open        unrestricted egress, no capture
   #SANDBOX_MODE=open
   ```

3. `SANDBOX_MODE` is deliberately left as a commented-out example, not a live
   value. It's already a live default in `sandbox.env` (the portable file);
   duplicating an active `SANDBOX_MODE=open` into `sandbox.local.env` would
   create two sources of truth for the same setting, and — because local
   wins over portable — would silently keep overriding any future change to
   the shared default in `sandbox.env` for every already-provisioned
   project. A commented example avoids that while still answering "how do I
   override this locally?"
4. No change to `sandbox.sh` / `sandbox-common.sh` / the env-file precedence
   logic. This is a `project-init.sh` output change only.

## Scope

Applied identically in two repos (structurally identical code in both):

- `ai-containers` (this repo): `project-init.sh`, `README.md` (the line
  describing when `sandbox.local.env` is written).
- `dt-utils/mgd-ai-containers/base`: same two files, same edits — this repo
  carries a preset-overlay feature on top, but the `sandbox.env`/
  `sandbox.local.env`-writing block is otherwise identical.

## Out of scope

- No change to already-provisioned projects' existing `sandbox.local.env`
  files (gitignored, machine-local — not something this repo can reach).
- No change to `sync-to-projects.sh` (it doesn't touch `sandbox.local.env`
  today and doesn't need to for this change).
