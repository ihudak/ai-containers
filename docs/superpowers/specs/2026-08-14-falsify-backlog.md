# Increment 5 — parked findings

Committed, not scratch: the SDD workspace is deleted on completion and a
finding that lives only there is a finding that gets dropped.

**Status:** OPEN

---

## F1 — `repo.sh` executes 2 of its 19 functions under the hermetic suite

`tests/test-repo-registry.sh` sources `repo.sh` in a subshell deliberately
arranged so that "dispatch never runs, no side effects occur" (the test's own
comment). Only `is_git_url` and `fmt_epoch` are invoked. Every `cmd_*`
subcommand — `add`, `sync`, `reset`, `list`, `rm`, `gc`, `reindex` — plus
`seed_from_*` and `sync_from_*` is unexercised, and nothing else in the suite
shells out to `repo.sh` either.

Not a bug, and not an argument that the subshell arrangement is wrong — it is
there to stop the tests seeding real Docker volumes. But it means `repo.sh` is
effectively untested hermetically, and it is the script that owns destructive
operations (`rm`, `gc`, `reset`) against volumes shared by every project.

**Why it is parked rather than fixed here:** mutating `repo.sh` today would
yield survivors that measure the absence of a harness, not the quality of an
assertion — the failure mode the ledger exists to keep out. It needs coverage
first, then entry to the mutation tier.

## F2 — `sandbox.sh`'s discovery and open modes are never executed hermetically

`sandbox.sh` runs as a real subprocess (only `docker` faked) in
`test-docs-path.sh`, `test-tool-config-mounts.sh` and `test-tools-d.sh` — but
**only ever as `sandbox.sh restricted`**. `tests/test-open-mode.sh` greps and
`bash -n`s the other two modes rather than running them.

Covered by integration cases `110`, `120`, `210`, `220`, `230`, so this is a
tier gap rather than an absence of coverage. Worth closing because the hermetic
tier is the cheap one: the same fake-`docker` technique that already drives
restricted mode would extend to both other modes for very little.

## F3 — `any_active` in `sandbox-common.sh` is dead code

Zero callers repo-wide (verified by grep). Either a leftover or an intended
extension point that never landed. Deleting it is a one-line change; the reason
it is recorded rather than done is that it belongs to no task in this
increment's plan and a drive-by deletion is how unrelated breakage gets
attributed to the wrong change.

## F4 — `install-tools.sh:api_get` is unexercised

The release-type branch's GitHub API call. Confirmed unexercised within the 45
hermetic tests; not chased beyond that scope. Its siblings `install_repo_file`,
`install_url` and `expand_placeholders` all execute transitively via
`install_one`, so this is a single gap in an otherwise well-covered file.
