# Undiscardable Failure Signalling in `tests/lib-verify-repo.sh` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `tests/lib-verify-repo.sh` signal every unrecoverable condition in a way no caller can discard, so its 13 hand-maintained caller guards can be deleted rather than policed.

**Architecture:** `mk_repo` is invoked as `r="$(mk_repo 0)"`, inside a command-substitution subshell — so *no* failure raised inside `mk_repo` can ever abort its caller, whatever verb it uses. The fix is therefore to move every check that can fail up to **source time**, where a plain `exit 1` from a sourced file terminates the sourcing script. `mk_repo` is then left with no failure path, the caller guards have nothing to guard, and a 14th call site is safe by construction.

**Tech Stack:** bash (floor 5.1, declared in `bash-floor.sh`), the `tests/layer-checks.conf` registry, `tests/run-all.sh`.

**Spec:** `docs/superpowers/specs/2026-08-13-lib-verify-repo-signalling-design.md`

## Global Constraints

- **Test files only.** No product code changes. Every file touched is under `tests/`.
- **`tests/layer-checks.conf` must not change** — not one byte. It is byte-identical with mgd-ai-containers' copy, and that is what lets one containment guard serve both repos.
- **Assert effect, never source text.** Every new assertion reads a program's *output or exit code*, never a `grep` over a script's source. A comment naming a check satisfies a substring match while nothing runs — the historical defect this repo's whole suite exists to close.
- **Every new assertion must have been seen failing**, with the break confirmed to reach the exact variable or output line the assertion inspects. Each task below names that line explicitly.
- **Bash floor 5.1.** Nothing newer. `tests/bash-dialect-lint.sh` gates this.
- **Do not use `sed -i`** to edit repository files — it replaces the file and drops the executable bit. Use an editor that edits in place.
- **New test files must be `chmod +x`** and named `tests/test-*.sh` so `tests/run-all.sh`'s glob picks them up. `tests/test-exec-bits.sh` enforces the mode.
- Every test file's own failure idiom is `pass()`/`fail()` printing `PASS: `/`FAIL: ` and exiting `$fails`. `tests/run-all.sh` treats a printed `FAIL:` line as a failure *regardless of exit code*, and also fails a file that asserted nothing.

---

### Task 1: Source-time signalling in `tests/lib-verify-repo.sh`

**Files:**
- Create: `tests/test-lib-verify-repo.sh`
- Modify: `tests/lib-verify-repo.sh`

**Interfaces:**
- Consumes: `lc_rows check` from `tests/lib-layer-checks.sh` (rows with the type field stripped, so fields are `id|job|step|kind|target|rc_var|witness_tgt|witness_re`).
- Produces: after this task, sourcing `tests/lib-verify-repo.sh` either succeeds completely or terminates the sourcing script. `mk_repo` has no failure path. Task 2 relies on both.

- [ ] **Step 1: Write the failing test file**

Create `tests/test-lib-verify-repo.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# tests/test-lib-verify-repo.sh — the first test of tests/lib-verify-repo.sh
# itself.
#
# That library has four unrecoverable conditions, and until this file none of
# them had ever been seen failing — four unfalsified guards inside the one file
# whose entire subject is guards that cannot fail.
#
# Every case here asserts by EFFECT: it writes a small harness script, runs it,
# and reads the harness's exit code and stdout. Specifically it asserts that a
# sentinel line placed AFTER the `source` never printed. Inspecting the
# library's source text would prove only that an `exit` is written somewhere in
# it, not that execution actually stopped — and "the string is present" is the
# exact false negative this repo's suite exists to close.
#
# The two positive controls are load-bearing, not padding: without them a
# library hard-wired to exit 1 unconditionally would satisfy every negative
# case in this file.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant, like the rest of the suite: upstream keeps the engine beside
# tests/, mgd-ai-containers keeps it in base/. One copy of this file serves both.
ENGINE_DIR="$REPO_DIR"
[[ -f "$ENGINE_DIR/verify-on-host.sh" ]] || ENGINE_DIR="$REPO_DIR/base"
VERIFY="$ENGINE_DIR/verify-on-host.sh"
REAL_CONF="$REPO_DIR/tests/layer-checks.conf"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$VERIFY" "$REAL_CONF" "$REPO_DIR/tests/lib-verify-repo.sh" \
         "$REPO_DIR/tests/lib-layer-checks.sh"; do
  [[ -f "$f" ]] || { fail "missing prerequisite: $f"; exit 1; }
done

hn=0
# Write a harness that sources the two libraries and then prints sentinels.
# $1 = LAYER_CHECKS_CONF to use
# $2 = "skip-lc" to deliberately NOT source lib-layer-checks.sh
# $3 = "no-tmp"  to deliberately leave TMP unset
# $4 = extra body appended after the source (may be empty)
mk_harness() {
  hn=$((hn + 1))
  local h="$TMP/harness-$hn.sh"
  cat > "$h" <<EOF
#!/usr/bin/env bash
set -uo pipefail
VERIFY=$(printf '%q' "$VERIFY")
ENGINE_DIR=$(printf '%q' "$ENGINE_DIR")
LAYER_CHECKS_CONF=$(printf '%q' "$1")
EOF
  # The library's contract check reads TMP; the "no-tmp" mode leaves it unset.
  # Quoted heredoc: $TMP here belongs to the harness at run time, not to us.
  [[ "$3" == "no-tmp" ]] || cat >> "$h" <<'EOF'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EOF
  [[ "$2" == "skip-lc" ]] || printf 'source %q\n' "$REPO_DIR/tests/lib-layer-checks.sh" >> "$h"
  printf 'source %q\n' "$REPO_DIR/tests/lib-verify-repo.sh" >> "$h"
  printf 'echo SENTINEL-SOURCED\n' >> "$h"
  printf '%s\n' "$4" >> "$h"
  chmod +x "$h"
  printf '%s' "$h"
}

# Run a harness. Prints its exit code; output lands in $TMP/harness.out.
# $2, when non-empty, is prepended to PATH (used to plant a broken `git`).
run_harness() {
  local extra_path="${2:-}"
  PATH="${extra_path:+$extra_path:}$PATH" bash "$1" > "$TMP/harness.out" 2>&1
  printf '%s' "$?"
}

# $1=label $2=harness rc. Asserts the harness stopped at the source line: a
# non-zero exit AND no SENTINEL-SOURCED. The sentinel is the discriminating
# half — a library that returned instead of exiting would let the sourcing
# script run on and print it while some later, unrelated step still made the
# harness exit non-zero.
expect_aborted() {
  local ok=1
  [[ "$2" != "0" ]] || { ok=0; fail "$1 — harness exited 0"; }
  if grep -q '^SENTINEL-SOURCED$' "$TMP/harness.out"; then
    ok=0
    fail "$1 — execution continued past the source (SENTINEL-SOURCED printed)"
  fi
  (( ok )) && pass "$1"
  (( ok )) || sed 's/^/       /' "$TMP/harness.out" | tail -8
}

# ── Positive control: a good registry sources cleanly ─────────────────────────
# Without this, every negative case below would also pass against a library
# that aborted unconditionally.
h="$(mk_harness "$REAL_CONF" "" "" "")"
rc="$(run_harness "$h")"
if [[ "$rc" == "0" ]] && grep -q '^SENTINEL-SOURCED$' "$TMP/harness.out"; then
  pass "control: the real registry sources cleanly and continues"
else
  fail "control: the real registry sources cleanly and continues — rc=$rc"
  sed 's/^/       /' "$TMP/harness.out" | tail -8
fi

# ── TMP/VERIFY/ENGINE_DIR unset ───────────────────────────────────────────────
h="$(mk_harness "$REAL_CONF" "" "no-tmp" "")"
expect_aborted "contract violation (TMP unset) aborts the sourcing script" "$(run_harness "$h")"

# ── lib-layer-checks.sh not sourced ───────────────────────────────────────────
h="$(mk_harness "$REAL_CONF" "skip-lc" "" "")"
expect_aborted "lc_rows undefined aborts the sourcing script" "$(run_harness "$h")"

# ── A registry with no path-bin rows ──────────────────────────────────────────
# Rewrites every check row's stub_kind to repo-script, so the registry is
# well-formed and non-empty but yields zero PATH stubs — the real shape of this
# failure, not a corrupt file.
conf_no_pathbin="$TMP/no-pathbin.conf"
awk -F'|' -v OFS='|' '/^check\|/ { if ($5 == "path-bin") $5 = "repo-script" } { print }' \
  "$REAL_CONF" > "$conf_no_pathbin"
if grep -q '^check|.*|path-bin|' "$conf_no_pathbin"; then
  fail "fixture is wrong: no-pathbin.conf still holds a path-bin row"
else
  pass "fixture: no-pathbin.conf holds no path-bin row"
fi
h="$(mk_harness "$conf_no_pathbin" "" "" "")"
expect_aborted "a registry yielding no path-bin stubs aborts the sourcing script" "$(run_harness "$h")"

# ── A registry with no repo-script rows ───────────────────────────────────────
# The condition mk_repo used to `return 1` for from inside a command
# substitution, where the status was swallowed and 13 hand-written caller
# guards had to re-detect it.
conf_no_reposcript="$TMP/no-reposcript.conf"
awk -F'|' -v OFS='|' '/^check\|/ { if ($5 == "repo-script") $5 = "none" } { print }' \
  "$REAL_CONF" > "$conf_no_reposcript"
if grep -q '^check|.*|repo-script|' "$conf_no_reposcript"; then
  fail "fixture is wrong: no-reposcript.conf still holds a repo-script row"
else
  pass "fixture: no-reposcript.conf holds no repo-script row"
fi
h="$(mk_harness "$conf_no_reposcript" "" "" "")"
expect_aborted "a registry yielding no repo-script stubs aborts the sourcing script" "$(run_harness "$h")"

# ── git unusable ──────────────────────────────────────────────────────────────
# mk_repo's stub repo must be a real git repo with tracked files. When git
# cannot deliver that, Phase 7 fails with "bash -n parsed no files" — a
# DIFFERENT failure that silently satisfies any assertion merely expecting the
# phase under test to fail. Probing at source time turns that into a loud stop.
mkdir -p "$TMP/badgit"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/badgit/git"
chmod +x "$TMP/badgit/git"
h="$(mk_harness "$REAL_CONF" "" "" "")"
expect_aborted "an unusable git aborts the sourcing script" "$(run_harness "$h" "$TMP/badgit")"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
```

- [ ] **Step 2: Run it and confirm which cases are red**

Run: `bash tests/test-lib-verify-repo.sh; echo "rc=$?"`

Expected against the **current** library: the control passes, both fixture checks pass, and **all five negative cases FAIL**.

All five, not two — including the three conditions that already look guarded. Their `return 1 2>/dev/null || exit 1` idiom does **not** exit when the file is sourced: `return` succeeds from a sourced script, so it returns immediately with status 1 and the `|| exit 1` half is never evaluated. The status lands on a `source` line nobody reads, and the harness runs on to its sentinel. That idiom only reaches `exit` when the file is *executed*, which this one never is.

```
FAIL: contract violation (TMP unset) aborts the sourcing script — execution continued past the source (SENTINEL-SOURCED printed)
FAIL: lc_rows undefined aborts the sourcing script — execution continued past the source (SENTINEL-SOURCED printed)
FAIL: a registry yielding no path-bin stubs aborts the sourcing script — execution continued past the source (SENTINEL-SOURCED printed)
FAIL: a registry yielding no repo-script stubs aborts the sourcing script — execution continued past the source (SENTINEL-SOURCED printed)
FAIL: an unusable git aborts the sourcing script — harness exited 0
```

Record the actual output in the task report. If a case you expected red comes out green, **stop and report it** — a demonstration that will not fail means the assertion is not reading what it claims to read, not that the break needs to be bigger.

- [ ] **Step 3: Make the three source-time guards `exit`**

In `tests/lib-verify-repo.sh`, replace each of the three `return 1 2>/dev/null || exit 1` occurrences with a plain `exit 1`. They are in the `TMP`/`VERIFY`/`ENGINE_DIR` contract check, the `declare -F lc_rows` check, and the `_n_pathbin` guard.

Add this rationale immediately above the first one:

```bash
# Every failure below is UNRECOVERABLE and identical for every caller, and this
# file is sourced, never executed (see the header). `exit` from a sourced file
# terminates the sourcing script and cannot be discarded; the usual
# `return 1 2>/dev/null || exit 1` idiom exists to support both invocation
# modes, and returning here would hand the caller a status nothing reads —
# which is precisely what made 13 hand-written caller guards necessary.
```

- [ ] **Step 4: Move the repo-script count up to source time**

The `repo-script` count depends only on `lc_rows check`, whose output is fixed at source time — the same output the `path-bin` loop already consumes. Count both in that one loop.

In the stub-shellcheck loop, add a counter beside `_n_pathbin`:

```bash
_n_pathbin=0
_n_reposcript=0
while IFS='|' read -r id job step kind target rc_var wtgt wre; do
  [[ "$kind" != "repo-script" ]] || _n_reposcript=$((_n_reposcript+1))
  [[ "$kind" == "path-bin" ]] || continue
  ...
done < <(lc_rows check)
```

and add, beside the existing `_n_pathbin` guard:

```bash
# Counted HERE rather than inside mk_repo, which is invoked as
# `r="$(mk_repo 0)"` — a command-substitution subshell, where neither `return`
# nor `exit` can reach the caller. Both read the same lc_rows output, fixed at
# source time, so nothing is lost by checking it once, early, where a failure
# can actually stop the run.
(( _n_reposcript > 0 )) || {
  echo "lib-verify-repo.sh: no repo-script stubs declared in $LAYER_CHECKS_CONF" >&2
  exit 1
}
```

- [ ] **Step 5: Probe git at source time**

Add, after the guards from Step 4 and before the `mk_repo` definition:

```bash
# ── git probe ────────────────────────────────────────────────────────────────
# mk_repo's stub repo must be a real git repository with at least one tracked
# file: Phase 7 runs `git ls-files '*.sh'` against it. If git cannot deliver
# that, Phase 7 fails with "bash -n parsed no files" — a DIFFERENT failure that
# still satisfies every assertion merely expecting the phase under test to
# fail, turning a real test into a vacuous one. Probe once, here, where a
# failure can stop the run; mk_repo itself cannot signal one.
_gitprobe="$TMP/.gitprobe"
rm -rf "$_gitprobe"; mkdir -p "$_gitprobe"
(
  cd "$_gitprobe" \
    && { git init -q -b main . || git init -q .; } \
    && : > f && git add f \
    && git -c user.email=t@example -c user.name=t commit -q -m probe
) >/dev/null 2>&1 || {
  echo "lib-verify-repo.sh: git cannot create a repo and commit under $TMP — mk_repo's stub repo would have no tracked files, and Phase 7 would fail with 'parsed no files' instead of the condition under test" >&2
  exit 1
}
rm -rf "$_gitprobe"
```

- [ ] **Step 6: Strip `mk_repo`'s failure path and the duplicate `mkdir`**

In `mk_repo`, delete `local n_repo=0`, the `n_repo=$((n_repo+1))` line, and the whole `(( n_repo > 0 )) || { … return 1; }` block with its comment. Leave the `local id job step kind target rc_var wtgt wre rc_val` declaration (minus `n_repo` if it were listed there) and the loop otherwise unchanged.

Add above the function:

```bash
# mk_repo has NO failure path: every condition that could make it fail is
# checked at source time above, because a `return`/`exit` from inside the
# `r="$(mk_repo 0)"` command substitution its callers use cannot reach them.
# That is what lets its call sites carry no guard.
```

Delete the second `mkdir -p "$TMP/bin"` (the one immediately above `_n_pathbin=0`); the first, above the docker stub, already created it.

- [ ] **Step 7: Run the new test — all green**

Run: `bash tests/test-lib-verify-repo.sh; echo "rc=$?"`
Expected: every line `PASS:`, final `0 failure(s)`, `rc=0`.

- [ ] **Step 8: Run the whole hermetic suite**

Run: `bash tests/run-all.sh`
Expected: every file passes, including `test-verify-exit-code.sh` and `test-layer-containment.sh`, whose caller guards are still present and now simply never fire. Record the totals line in the report.

- [ ] **Step 9: Demonstrate the new guards failing**

Two demonstrations. For each: apply the break, run *only* `tests/test-lib-verify-repo.sh`, confirm the **named** assertion is the one that turns red, then revert.

1. Restore the old signalling for the repo-script condition: change the Step 4 guard's `exit 1` back to `return 1 2>/dev/null || exit 1`.
   Assertion that must go red: `a registry yielding no repo-script stubs aborts the sourcing script`. It reads the presence of `SENTINEL-SOURCED` in `$TMP/harness.out` and the harness's exit code — the break reaches both, because the harness's `source` line ignores the return and runs on to the `echo`.
2. Delete the Step 5 git probe block.
   Assertion that must go red: `an unusable git aborts the sourcing script`, same two reads.

Paste the exact `FAIL:` lines from both runs into the report, and confirm `git diff` is clean afterwards.

- [ ] **Step 10: `bash -n`, dialect lint, shellcheck, exec bit**

```bash
chmod +x tests/test-lib-verify-repo.sh
bash -n tests/test-lib-verify-repo.sh tests/lib-verify-repo.sh
bash tests/bash-dialect-lint.sh
shellcheck tests/test-lib-verify-repo.sh tests/lib-verify-repo.sh
bash tests/test-exec-bits.sh
```
Expected: all clean, exit 0. Fix any finding at its cause; if a shellcheck finding is a genuine false positive, suppress it at the site with `# shellcheck disable=SCxxxx: <reason>` — the reason is required, matching this repo's existing idiom.

- [ ] **Step 11: Commit**

```bash
git add tests/lib-verify-repo.sh tests/test-lib-verify-repo.sh
git commit -m "fix: lib-verify-repo.sh signals unrecoverable failures where they can stop the run

mk_repo is invoked as r=\"\$(mk_repo 0)\", inside a command substitution, so no
verb used inside it can abort the caller — \`exit\` there kills only the
subshell. Move every check that can fail to source time, where a plain \`exit\`
from a sourced file terminates the sourcing script: the repo-script count joins
the path-bin count in the loop that already reads lc_rows, git gains a probe,
and the three existing source-time guards stop returning a status nobody reads.
mk_repo is left with no failure path at all.

tests/test-lib-verify-repo.sh is the first test of the library, driving all
five abort paths by effect — a sentinel after the source that must never print
— plus a positive control, without which a library hard-wired to exit 1 would
satisfy every negative case.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Delete the 13 caller guards

**Files:**
- Modify: `tests/test-verify-exit-code.sh` (12 guards)
- Modify: `tests/test-layer-containment.sh` (1 guard, plus its explanatory comment)
- Modify: `tests/test-lib-verify-repo.sh` (add the unguarded-call-site control)

**Interfaces:**
- Consumes: Task 1's guarantee that sourcing `tests/lib-verify-repo.sh` either succeeds completely or terminates the sourcing script, and that `mk_repo` has no failure path.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Add the unguarded-call-site control to `tests/test-lib-verify-repo.sh`**

Insert immediately before the final `printf '\n%d failure(s)\n' "$fails"`:

```bash
# ── An unguarded call site is safe ────────────────────────────────────────────
# The point of Task 1, stated as a test. Against a GOOD registry, the bare
# `r="$(mk_repo 0)"` form — no `[[ -n "$r" ]] ||` guard after it, which is how
# all 13 call sites now read — produces a usable path and execution continues.
# Its other half is the no-repo-script case above: with a bad registry, control
# never reaches this line at all, because the source aborted.
h="$(mk_harness "$REAL_CONF" "" "" '
r="$(mk_repo 0)"
[[ -d "$r/.git" ]] && echo "SENTINEL-REPO-OK"
echo "SENTINEL-AFTER-MKREPO"')"
rc="$(run_harness "$h")"
if [[ "$rc" == "0" ]] \
   && grep -q '^SENTINEL-REPO-OK$' "$TMP/harness.out" \
   && grep -q '^SENTINEL-AFTER-MKREPO$' "$TMP/harness.out"; then
  pass "control: an unguarded mk_repo call site yields a usable repo and continues"
else
  fail "control: an unguarded mk_repo call site yields a usable repo and continues — rc=$rc"
  sed 's/^/       /' "$TMP/harness.out" | tail -8
fi
```

- [ ] **Step 2: Run it — expect green**

Run: `bash tests/test-lib-verify-repo.sh`
Expected: all `PASS:`, `0 failure(s)`.

- [ ] **Step 3: Delete the 12 guards in `tests/test-verify-exit-code.sh`**

Delete every line reading exactly:

```bash
[[ -n "$r" ]] || { echo "FAIL: mk_repo produced no repo path"; exit 1; }
```

There are 12, each on the line directly after an `r="$(… mk_repo …)"` assignment. Delete only the guard lines; leave the assignments and everything else untouched.

- [ ] **Step 4: Delete the guard in `tests/test-layer-containment.sh`**

Replace the block that currently runs from the `# M9:` comment through the `[[ -n "$r" ]] || { fail …; exit "$fails"; }` line (the comment and the guard together) with:

```bash
# No guard follows: tests/lib-verify-repo.sh aborts the sourcing script if it
# cannot build its stubs, so control never reaches this line with a registry
# that would yield an empty $r. The guard this replaces existed because that
# failure used to arrive as a discarded `return` — and an empty $r once fed a
# bare `cd "$r"`, which SUCCEEDS and stays put, committing the whole real
# working tree under a fake identity.
```

Keep the `MK_REPO_PROBE=1` comment above the assignment and the assignment itself exactly as they are.

- [ ] **Step 5: Run both files and the whole suite**

```bash
bash tests/test-verify-exit-code.sh; echo "rc=$?"
bash tests/test-layer-containment.sh; echo "rc=$?"
bash tests/run-all.sh
```
Expected: both exit 0 with `0 failure(s)`, and the full suite green. Record the totals line.

- [ ] **Step 6: Confirm no guard survived**

```bash
grep -rn 'mk_repo produced no repo path' tests/ ; echo "grep rc=$?"
```
Expected: no output, `grep rc=1`. This is a completeness check on the deletion, not a guard — the property itself is tested in Step 1.

- [ ] **Step 7: Demonstrate the control failing**

Break: in `tests/lib-verify-repo.sh`'s `mk_repo`, change the final `printf '%s' "$r"` to `printf ''`.
Assertion that must go red: `control: an unguarded mk_repo call site yields a usable repo and continues`. It reads `$rc` plus the two sentinel lines in `$TMP/harness.out`; with no path printed, `[[ -d "$r/.git" ]]` is false, `SENTINEL-REPO-OK` never prints, and the assertion fails.

Run `bash tests/test-lib-verify-repo.sh`, paste the `FAIL:` line into the report, revert, and confirm `git diff` is clean for that file.

- [ ] **Step 8: Lint**

```bash
bash -n tests/test-verify-exit-code.sh tests/test-layer-containment.sh tests/test-lib-verify-repo.sh
bash tests/bash-dialect-lint.sh
shellcheck tests/test-verify-exit-code.sh tests/test-layer-containment.sh tests/test-lib-verify-repo.sh
```
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add tests/test-verify-exit-code.sh tests/test-layer-containment.sh tests/test-lib-verify-repo.sh
git commit -m "fix: drop the 13 hand-maintained mk_repo caller guards

Nothing policed the set — a 14th call site needed no entry to go green, the
same named-list defect the layer-containment registry existed to remove, at
small scale. With the library aborting at source time, the guards have nothing
left to detect: they are deleted rather than policed, and a new call site is
safe by construction.

A positive control in tests/test-lib-verify-repo.sh pins the property from the
other side: the bare, unguarded r=\"\$(mk_repo 0)\" form yields a usable repo
and continues.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Exercise the `floor-suite` row's `rc_var`

**Files:**
- Modify: `tests/test-verify-exit-code.sh`

**Interfaces:**
- Consumes: `lc_rows`, `mk_repo`, `run_verify`, `expect_rc`, `pass`, `fail`, `$TMP/out.log` — all already in scope in that file.
- Produces: nothing later tasks depend on.

**Context.** `grep -rn DOCKER_RUN_RC` currently finds it in exactly two places: the `docker` stub's own default in `tests/lib-verify-repo.sh`, and the `floor-suite` row in `tests/layer-checks.conf`. **No test sets it.** So the Phase 5 branch at `verify-on-host.sh`'s `hermetic suite at the declared floor exited $f_rc` has never been exercised, and the registry's `rc_var` column for that row is inert. Reading the variable's name *from the registry* is what makes the column load-bearing: rename it in the stub and this assertion goes red at its cause.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-verify-exit-code.sh`, immediately before its final `printf '\n%d failure(s)\n' "$fails"`:

```bash
# ── The floor-suite container's exit code must reach the verdict ──────────────
# The registry's floor-suite row declares WHICH env var carries that exit code;
# read it from there rather than hardcoding the name, so a rename in
# lib-verify-repo.sh's docker stub makes this assertion red at its cause
# instead of leaving an inert column nobody reads. That row's stub_kind is
# `none` — the docker stub is Phase-0 infrastructure the library writes by hand
# rather than something the registry loop builds — so this is the only thing
# that ties the two together.
floor_rc_var="$(lc_rows check | awk -F'|' '$1 == "floor-suite" { print $6 }')"
if [[ -z "$floor_rc_var" || "$floor_rc_var" == "-" ]]; then
  fail "the registry's floor-suite row names an rc_var"
else
  pass "the registry's floor-suite row names an rc_var ($floor_rc_var)"
  r="$(mk_repo 0)"
  rc="$( export "${floor_rc_var}=1"; run_verify "$r" 5 )"
  expect_rc "phase 5: a failing floor-suite container exits non-zero" 1 "$rc"
  grep -q 'hermetic suite at the declared floor exited 1' "$TMP/out.log" \
    && pass "phase 5: the verdict names the floor suite as what failed" \
    || fail "phase 5: the verdict names the floor suite as what failed"
fi
```

Note `lc_rows check` strips the row-type field, so the fields are `id|job|step|kind|target|rc_var|witness_tgt|witness_re` and `rc_var` is `$6`.

- [ ] **Step 2: Run it — expect green immediately**

Run: `bash tests/test-verify-exit-code.sh; echo "rc=$?"`
Expected: all `PASS:`, `0 failure(s)`. This case documents an *untested existing* branch rather than a broken one, so it passes on first run — which is exactly why Step 3 is mandatory rather than optional.

- [ ] **Step 3: Demonstrate it failing — twice, in different places**

A case that passes on first write has proved nothing until it has been seen failing. Two independent breaks, each reverted after:

1. **The coupling this case exists to police.** In `tests/lib-verify-repo.sh`'s `docker` stub, rename `DOCKER_RUN_RC` to `DOCKER_RUN_RC_X` (its one occurrence inside the heredoc, `exit "\${DOCKER_RUN_RC:-0}"`).
   Assertion that must go red: `phase 5: a failing floor-suite container exits non-zero`. The `export` still sets the registry-named variable, the stub now reads a different one, defaults to 0, `docker run` succeeds, Phase 5 passes, and `expect_rc` reads `$rc` as `0` against an expected `1`.
2. **The product branch it covers.** In `verify-on-host.sh`, delete the `|| phase_fail 5 "hermetic suite at the declared floor exited $f_rc"` clause.
   Assertions that must go red: both of them — `expect_rc` reads `$rc` (now 0, nothing recorded the failure) and the `grep` reads `$TMP/out.log` for the message that is no longer emitted.

Paste the `FAIL:` lines from both runs into the report and confirm `git diff` is clean afterwards.

- [ ] **Step 4: Run the whole suite and lint**

```bash
bash tests/run-all.sh
bash -n tests/test-verify-exit-code.sh
bash tests/bash-dialect-lint.sh
shellcheck tests/test-verify-exit-code.sh
```
Expected: all green. Record the suite totals line.

- [ ] **Step 5: Commit**

```bash
git add tests/test-verify-exit-code.sh
git commit -m "test: exercise the floor-suite container's exit code, reading its var from the registry

DOCKER_RUN_RC appeared in exactly two places — the docker stub's own default
and the floor-suite registry row — and no test set it, so verify-on-host.sh's
'hermetic suite at the declared floor exited' branch had never run and the
row's rc_var column was inert. Taking the name from the registry makes the
column load-bearing by effect: rename it in the stub and this assertion goes
red at its cause, which asserting that the two strings match would not.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
