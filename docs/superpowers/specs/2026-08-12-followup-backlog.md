# Follow-up backlog — after the layer-containment registry, before increment 5

**Status:** CLOSED 2026-08-13. All three items resolved in
`docs/superpowers/specs/2026-08-13-lib-verify-repo-signalling-design.md`; see the
per-item resolutions below. This file is kept rather than deleted so the ruling
and the reasoning survive alongside the outcome.

**Ruling (2026-08-12):** these are scheduled work, not open-ended follow-up. They
are done **after** the layer-containment registry merges and **before** increment 5
(`tests/falsify`) begins. Bugs first.

**Why this file exists.** Every prior increment parked its minor findings in an SDD
workspace under `.superpowers/sdd/<plan>/`, which is git-ignored scratch and is
deleted when the plan completes. That worked only because someone remembered to
carry the list forward by hand. This file is committed, so the list survives the
workspace it came from — the same reasoning that put the bash floor in one file
and the hermetic checks in one workflow.

Each item below was found by the final whole-branch review of the
layer-containment registry branch (`docs/superpowers/specs/2026-08-12-layer-containment-registry-design.md`),
judged real, and deliberately not fixed in that branch because each needs a design
decision rather than a mechanical edit.

---

## 1. The `mk_repo` caller guards are a hand-maintained set — CLOSED

**Resolution (2026-08-13).** None of the three options below was taken, because
two do not survive contact: `exit` inside `mk_repo` kills only the
command-substitution subshell, and enumerating call sites from source is a
pattern match defeated by reformatting. The framing was also wrong — the guards
are a symptom of the library signalling four unrecoverable conditions with a
discardable status. Every such check moved to **source time**, where a plain
`exit 1` from a sourced file terminates the sourcing script; `mk_repo` was left
with no failure path; all 13 guards were deleted rather than policed. A further
finding fell out of it: the existing `return 1 2>/dev/null || exit 1` idiom never
reached its `exit` at all when sourced.



**Where:** `tests/test-verify-exit-code.sh` (12 sites), `tests/test-layer-containment.sh` (1 site).

**What.** `mk_repo` returns 1 when the registry yields no stubs, but callers invoke
it as `r="$(mk_repo 0)"` and a `return` inside a command substitution is swallowed.
Every call site therefore carries a hand-written guard:

```bash
r="$(mk_repo 0)"
[[ -n "$r" ]] || { echo "FAIL: mk_repo produced no repo path"; exit 1; }
```

All 13 sites are currently guarded. Nothing polices the set: a 14th call site needs
no matching entry to go green. This is the same shape as the named-list problem the
registry branch existed to remove, at small scale.

**Why it was not fixed inline.** The obvious mechanical fix — grep for `mk_repo`
call sites and require an adjacent guard — is itself a hand-written pattern match
and would be defeated by any reformatting. The real options need a decision:

- make `mk_repo` write its path to a caller-supplied variable (nameref) and return
  a status the caller cannot discard, changing 13 call sites; or
- have `mk_repo` `exit` rather than `return` on the unrecoverable case, which is
  blunt but leaves nothing to forget; or
- accept the guards and add a test that enumerates call sites from the source.

**Concrete failure this prevents:** an unguarded site with an empty `$r` previously
ran `( cd "$r" && git add -A && git commit )`, and because `cd ""` succeeds and stays
put, it committed the entire real working tree under a fake identity. That happened
on 2026-08-12 (commit `e462318`, since unwound). The structural fix landed, but the
class is still reachable at a new call site.

## 2. The `floor-suite` registry row is coupled to a hand-written stub in two places — CLOSED

**Resolution (2026-08-13).** Neither option below was taken. The measurement was
sharper than the item recorded: `DOCKER_RUN_RC` appeared in exactly two places —
the stub's default and the registry row — and **no test set it**, so
`verify-on-host.sh`'s "hermetic suite at the declared floor exited" branch had
never run. The fix is the missing test, reading the variable's *name* from the
registry row, which makes the column load-bearing by effect rather than by a
string comparison: rename it in the stub and the assertion goes red at its cause.
`witness_re` needed no work — its `STUB:docker-run` prefix was already
self-policing via the existing witness assertion.



**Where:** `tests/layer-checks.conf` (`floor-suite` row), `tests/lib-verify-repo.sh` (the `docker` stub).

**What.** The row declares `rc_var=DOCKER_RUN_RC` and a `witness_re` prefixed
`STUB:docker-run`, while the `docker` stub hardcodes both strings. Because the row's
`stub_kind` is `none`, the registry columns are inert — nothing reads them — so the
two can drift apart silently.

**Why it was not fixed inline.** The `docker` stub is deliberately hand-written: it
is Phase-0 infrastructure (`--version`, `buildx version`, `info`, `system df`) that
the `floor-suite` row happens to read, not a stub the registry creates. Folding it
into the registry loop would make the registry responsible for infrastructure it
does not own. The alternatives — have the `none` kind assert its columns match the
stub, or drop the inert columns and note the coupling — are both defensible.

## 3. `mkdir -p "$TMP/bin"` appears twice in `tests/lib-verify-repo.sh` — CLOSED

**Where:** `tests/lib-verify-repo.sh:74` and `:93`.

Idempotent and harmless; cosmetic only. Listed so the set is complete rather than
"the two interesting ones plus something nobody wrote down."

**Resolution (2026-08-13).** The second occurrence deleted.

---

## Closed, recorded here so the accounting reconciles

These were on the same deferred list and are resolved; do not re-open them.

| Item | Resolution |
|---|---|
| `test-exec-bits.sh` does not cover `verify-on-host.sh` | Not a bug. That file's stated scope excludes scripts invoked as `bash <file>`, and every invocation of `verify-on-host.sh` in the repo and its docs is exactly that. Mode is cosmetic there. |
| Stale "Mirrors `tests.yml`'s `<job>` job" comments | Fixed in the registry branch — all 7 sites in `verify-on-host.sh` plus `tests/bash-dialect-lint.sh:39` now name `hermetic-checks.yml`. |
| `sub "shellcheck exit: … over N script(s)"` recomputes `git ls-files` | No action. The two invocations are provably the same set today, so reuse would be equivalent rather than a correctness fix, and keeping the branches independent was the deliberate choice. Revisit only if the pathspecs diverge. |
| A task report said "19 PASS lines" where the run produces 20 | Closed as recorded. The report is a historical artifact; editing it would falsify the record. |
| `sed -i` dropped an executable bit three times during the branch | All three were caught and restored before merge (`verify-on-host.sh`, `tests/test-verify-exit-code.sh`, `tests/integration/docker-shim.sh` — all 100755). The pattern is a tooling habit, not a guard gap; the standing instruction is to use an editor that does not replace the file. |
