# Undiscardable failure signalling in `tests/lib-verify-repo.sh`

**Status:** approved 2026-08-13
**Closes:** all three open items in
`docs/superpowers/specs/2026-08-12-followup-backlog.md`, which the 2026-08-12
ruling scheduled after the layer-containment registry and before increment 5.

## The problem, restated

The backlog recorded item 1 as "the `mk_repo` caller guards are a hand-maintained
set" — 13 sites each carrying `[[ -n "$r" ]] || { …; exit 1; }`, with nothing
policing the set, so a 14th site needs no entry to go green.

That is a symptom. Reading the file, the defect is that `tests/lib-verify-repo.sh`
signals **four** unrecoverable conditions with a status the caller can discard:

| Site | Condition | Signal today |
|---|---|---|
| `:51` | `TMP` / `VERIFY` / `ENGINE_DIR` unset | `return 1 2>/dev/null \|\| exit 1` |
| `:56` | `lc_rows` not sourced | `return 1 2>/dev/null \|\| exit 1` |
| `:111` | registry yielded no `path-bin` stubs | `return 1 2>/dev/null \|\| exit 1` |
| `:188` | registry yielded no `repo-script` stubs | `return 1`, from inside `$( )` |

Both consumers run `set -uo pipefail` — **no `-e`** — so none of these aborts
anything by itself. The three source-time guards return to a `source` line whose
status nobody reads; the fourth returns into a command substitution.

The 13 caller guards exist to re-detect, one level down, a failure the library
already knew about. Policing the guards keeps the design that made them
necessary.

## Why two of the three recorded options do not survive contact

- **`exit` instead of `return` in `mk_repo`.** `mk_repo` is invoked as
  `r="$(mk_repo 0)"`, so it runs in a command-substitution subshell. `exit`
  there terminates the subshell and nothing else: `$r` is empty and the parent
  continues, byte-for-byte the behaviour we have now. The option is a no-op.
- **A test that enumerates call sites from source.** A pattern match over source
  text, defeated by any reformatting, and it leaves all 13 guards in place. This
  is the shape the registry increment spent its length removing.

The nameref option does work — `mk_repo` would run in the current shell, so
`exit` would propagate — but it changes 13 call signatures in order to police a
condition that is already knowable one level up, at source time.

## Design

### 1. Remove the failure path instead of policing it

`mk_repo`'s `repo-script` count depends only on `lc_rows check`, whose output is
fixed at source time — the same output the `path-bin` loop at `:95` already
consumes. Move the count and its guard into that loop.

`mk_repo` then has **no failure path at all**: delete `n_repo`, delete
`return 1`, and delete all 13 caller guards. A 14th call site is safe by
construction, with nothing for anyone to remember.

### 2. The source-time guards `exit`

All three become a plain `exit 1`. The file's own header (line 3) declares it
`SOURCED, never executed directly`; `exit` from a sourced file terminates the
sourcing script and cannot be discarded. The `return 1 2>/dev/null || exit 1`
idiom exists to support both invocation modes, and this file has only one.

### 3. `mk_repo`'s git block stops discarding its status

Same class, found while reading. `( cd … git init … git commit … ) >/dev/null 2>&1`
throws away its exit status, so a repo whose `git init` failed is handed back as
good and surfaces three phases later as `bash -n parsed no files` — a misleading
cause for a missing git. Make it fatal, with a message naming the real reason.

### 4. The four guards get their first test

No test covers `tests/lib-verify-repo.sh`. Its four abort paths have never been
seen failing, in a file whose entire subject is guards that cannot fail.

`tests/test-lib-verify-repo.sh` (new) drives each path by **effect**: it writes a
small harness script into its own scratch dir, points the harness at a doctored
`LAYER_CHECKS_CONF`, and asserts the harness exits non-zero **and never printed
the sentinel line that follows the source**. Source-text inspection proves
nothing here — the question is whether execution stopped.

One of its cases is the direct demonstration for item 1: a harness that calls
`mk_repo` with **no** local guard, against a registry with no `repo-script`
rows, asserting execution never reaches the next line. Under today's code that
harness proceeds with an empty `$r`.

### 5. `DOCKER_RUN_RC` is inert because nothing turns it

Backlog item 2 recorded the `floor-suite` row's `rc_var=DOCKER_RUN_RC` as inert
columns that could drift from the hand-written `docker` stub. The measurement is
sharper than that: `grep -rn DOCKER_RUN_RC` finds it in exactly two places — the
stub's own default and the registry row. **No test sets it.** Nothing asserts
that a failing floor-suite container makes Phase 5 fail, even though
`verify-on-host.sh:268` has that branch.

The fix is the missing test, taking the variable name from the registry rather
than hardcoding it:

```bash
floor_rc_var="$(lc_rows check | awk -F'|' '$1=="floor-suite"{print $6}')"
rc="$( export "${floor_rc_var}=1"; run_verify "$r" 5 )"
```

That makes the column load-bearing by effect. If the stub's variable is renamed,
the export stops reaching it, `docker run` exits 0, Phase 5 passes, and the
assertion goes red at its actual cause. This is strictly better than asserting
the two strings match, which would pass while the branch stayed unexercised.

`witness_re` needs no work: its `STUB:docker-run` prefix is already self-policing,
because a drifted prefix makes the existing witness assertion in
`tests/test-layer-containment.sh` fail.

### 6. The duplicate `mkdir`

`mkdir -p "$TMP/bin"` appears at `:74` and `:93`. Keep the first, delete the
second.

## What is deliberately not changed

- **`tests/layer-checks.conf`** — no format or row change, so the file stays
  byte-identical with mgd-ai-containers' copy, which is what lets one containment
  guard serve both repos.
- **`lc_rows`' own `return 1`.** It is an ordinary function return, and both
  consumers compensate with a count guard (`_n_pathbin > 0`, and after this
  change the same loop's `repo-script` count). Widening the change there would
  be scope creep with no defect behind it.
- **No product code.** Every file touched is under `tests/`.

## Verification

Each fix has one demonstration, and each names the exact line the assertion
reads:

| Fix | Break | Assertion that must go red |
|---|---|---|
| §1/§2 | restore `return 1 2>/dev/null \|\| exit 1` at the `repo-script` guard | the unguarded-call-site harness prints its post-`mk_repo` sentinel |
| §3 | put a `git` on `PATH` that exits 1 | the git-failure harness exits 0 |
| §5 | rename `DOCKER_RUN_RC` in the `docker` stub only | `phase 5: a failing floor-suite container exits non-zero` |

The rule from the previous increment applies: before writing "break X, expect
FAIL", name the variable or output line the assertion inspects and confirm the
break reaches it.

## Scope

`tests/lib-verify-repo.sh`, `tests/test-verify-exit-code.sh`,
`tests/test-layer-containment.sh`, and one new `tests/test-lib-verify-repo.sh`.
Three tasks. Ported to mgd-ai-containers as a parallel PR, with the file list
derived from `git diff --name-only`.
