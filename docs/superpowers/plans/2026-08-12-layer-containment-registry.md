# Layer-Containment Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three hand-maintained lists behind `tests/test-layer-containment.sh` with one registry, derive CI job/step enumeration from the workflow file instead of hardcoding it, give nightly the hermetic checks via a reusable workflow, and clear the eleven defects increment 4 parked.

**Architecture:** One data file (`tests/layer-checks.conf`) declares every hermetic check once — its CI step, how it is stubbed, and the witness line that proves it ran. One parser library (`tests/lib-layer-checks.sh`) reads it and extracts jobs/steps from workflow YAML. Two consumers replace their hardcoded lists with registry iteration: `tests/lib-verify-repo.sh` (builds the stubs) and `tests/test-layer-containment.sh` (asserts the witnesses, and additionally requires every step in the workflow to classify as either a registry check or declared setup).

**Tech Stack:** bash 5.1+, awk (POSIX), git, GitHub Actions reusable workflows (`on: workflow_call`).

**Spec:** `docs/superpowers/specs/2026-08-12-layer-containment-registry-design.md`

## Global Constraints

- **Bash floor is 5.1**, declared only in `bash-floor.sh`. No construct newer than 5.1 in any script. `tests/bash-dialect-lint.sh` enforces this; a line that must contain a flagged construct carries `# dialect-lint: allow RULE-ID: reason` (the reason is required and checked).
- **`shellcheck -S warning -e SC1091` is a GATE**, not advisory. New code lands clean, or carries `# shellcheck disable=SCxxxx: reason` at the site.
- **Every new guard must be demonstrated failing** before it is trusted. A demonstration must change observable behaviour *at the point the assertion reads* — name the exact variable or output line first, then confirm the break reaches it. Three demonstrations in increment 4's plan would have passed while proving nothing; see each task's demonstration step for the specific line each assertion inspects.
- **A check that cannot locate its target must FAIL, never report "not applicable"** and never return an empty result quietly.
- **Files sourced by tests are named `lib-*.sh`**, never `test-*.sh` — `tests/run-all.sh` globs `test-*.sh` and would execute them.
- **Layout tolerance:** upstream keeps the engine (`verify-on-host.sh`, `bash-floor.sh`) at the repo root beside `tests/`; `mgd-ai-containers` keeps it in `base/` with `tests/` one level up. Files that must serve both use the `ENGINE_DIR` fallback idiom already in `tests/test-layer-containment.sh:36-37`. `.github/workflows/` and `tests/` sit at the same place in both layouts.
- **The registry is the ONLY list.** The three it replaces are deleted, not supplemented.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `.github/workflows/hermetic-checks.yml` | The three hermetic jobs, callable via `workflow_call`. Single definition for both PR and nightly. |
| `tests/layer-checks.conf` | Data. One row per hermetic check, plus one row per declared-setup step. |
| `tests/lib-layer-checks.sh` | Parser. Reads the registry; extracts jobs and step identities from workflow YAML. Sourced, never executed. |
| `tests/test-layer-checks-parser.sh` | Fixture test for the parser — the parser is not trusted, it is tested. |

**Modified**

| File | Change |
|---|---|
| `bash-floor.sh` | Gains the floor→image map, so the floor and the image testing it cannot drift. |
| `.github/workflows/tests.yml` | Becomes a thin caller. |
| `.github/workflows/nightly.yml` | Gains a schedule-gated caller. |
| `tests/lib-verify-repo.sh` | `mk_repo()` builds stubs from the registry; opt-in probe; opt-in untracked-`.sh` mode. |
| `tests/test-layer-containment.sh` | Registry-driven assertions, step classification, retargeted to `hermetic-checks.yml`. |
| `tests/test-bash-floor.sh` | Asserts the image map is present and single. |
| `verify-on-host.sh` | Floor image from the map; §6.2, §6.3, §6.6, §6.10. |
| `tests/test-verify-exit-code.sh` | Case for §6.10. |
| `sandbox.sh` | §6.8 — `EXTRA_MOUNTS` / `PREVIEW_PORTS` glob expansion. |
| `tests/test-parsers.sh` | §6.5 and §6.8 coverage. |
| `tests/portability.sh` | §6.1 — remove the `stat -c … \|\| stat -f …` trap. |
| `tests/test-rvm-reconcile.sh` | §6.4 — exercise `boot_case()`'s missing branch. |
| `tests/test-bash-dialect-lint.sh` | §6.9 — exercise the "examined no files" guard. |
| `AGENTS.md`, `CHANGELOG.md`, `README.md` | Documentation. |

---

### Task 1: Floor→image map in `bash-floor.sh`

The `5.1 → ubuntu:22.04` mapping currently lives in `tests/test-layer-containment.sh:158-162`. The registry needs it too (`floor-suite`'s witness regex embeds the image), and `verify-on-host.sh:228` hardcodes it a third time. Move it to the one place the floor is declared.

**Critically, it must stay a MAP, not a free variable.** A bare `AI_CONTAINERS_BASH_FLOOR_IMAGE="ubuntu:22.04"` sitting beside the floor numbers would let someone bump the floor to 5.2 and leave the image at 22.04 — silently making the floor untested again, which is exactly what the current `case` statement prevents.

**Files:**
- Modify: `bash-floor.sh` (after the `AI_CONTAINERS_BASH_FLOOR_MINOR=1` assignment)
- Modify: `verify-on-host.sh:228` (`floor_img="ubuntu:22.04"`)
- Test: `tests/test-bash-floor.sh`

**Interfaces:**
- Produces: `AI_CONTAINERS_BASH_FLOOR_IMAGE` — a container image tag string, or the empty string when the declared floor has no mapped image. Every consumer must treat empty as a hard failure.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-bash-floor.sh`, before its final `printf '\n%d failure(s)\n'` line:

```bash
# ── The floor→image map ───────────────────────────────────────────────────────
# The image that TESTS the floor is part of declaring the floor. Kept as a map
# rather than a free variable so a floor bumped without a matching image yields
# empty (a hard failure downstream) instead of silently testing the wrong bash.
( source "$ENGINE_DIR/bash-floor.sh"
  [[ -n "${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}" ]] ) \
  && pass "bash-floor.sh maps the declared floor to a container image" \
  || fail "bash-floor.sh maps no image to the declared floor — suite-floor cannot test the claim"

# Bumping the floor without extending the map must yield EMPTY, not a stale image.
out="$( AI_CONTAINERS_BASH_FLOOR_MAJOR=9 AI_CONTAINERS_BASH_FLOOR_MINOR=9 \
        bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}"' \
             _ "$ENGINE_DIR/bash-floor.sh" )"
[[ -z "$out" ]] \
  && pass "an unmapped floor yields an empty image rather than a stale one" \
  || fail "an unmapped floor yielded '$out' — the map is not keyed on the declared floor"
```

`$ENGINE_DIR` is already defined at `tests/test-bash-floor.sh:15` and already used at line 28 to reach `bash-floor.sh`; no new variable is needed. `pass`/`fail` are defined in that file too.

- [ ] **Step 2: Run it and watch it fail**

```bash
bash tests/test-bash-floor.sh
```

Expected: `FAIL: bash-floor.sh does not map floor 5.1 to any image`. The second assertion passes vacuously right now (the variable is unset, so empty) — that is expected and is why the first assertion exists.

- [ ] **Step 3: Add the map to `bash-floor.sh`**

Immediately after `AI_CONTAINERS_BASH_FLOOR_MINOR=1`:

```bash
# The container image whose bash IS the declared floor, used by
# .github/workflows/hermetic-checks.yml's suite-floor job and by
# verify-on-host.sh's Phase 5. Declared as a MAP keyed on the floor above, not
# as a free variable: a floor raised without a matching image would silently
# return the floor to ASSERTED rather than TESTED — the exact defect suite-floor
# exists to prevent. An unmapped floor yields the empty string, and every
# consumer treats that as a hard failure rather than a default.
case "${AI_CONTAINERS_BASH_FLOOR_MAJOR}.${AI_CONTAINERS_BASH_FLOOR_MINOR}" in
  5.1) AI_CONTAINERS_BASH_FLOOR_IMAGE="ubuntu:22.04" ;;
  5.2) AI_CONTAINERS_BASH_FLOOR_IMAGE="ubuntu:24.04" ;;
  *)   AI_CONTAINERS_BASH_FLOOR_IMAGE="" ;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-bash-floor.sh
```

Expected: both new assertions PASS, and every pre-existing assertion in the file still passes.

- [ ] **Step 5: Point `verify-on-host.sh` at the map**

Replace `verify-on-host.sh`'s hardcoded `floor_img="ubuntu:22.04"` (currently line 228, inside Phase 5) with:

```bash
  # From bash-floor.sh's map — see its comment for why the image is declared
  # alongside the floor rather than duplicated here. Empty means the declared
  # floor has no mapped image, which must fail loudly: running the "floor" suite
  # in whatever image `docker run ""` resolves to would verify nothing.
  floor_img="${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}"
  if [[ -z "$floor_img" ]]; then
    phase_fail 5 "bash-floor.sh maps no container image to the declared floor — the floor suite did not run"
  else
```

and close that `if` with a matching `fi` immediately after the existing `[[ "$f_rc" -eq 0 ]] || phase_fail 5 "hermetic suite at the declared floor exited $f_rc"` line. Re-indent the enclosed block by two spaces.

- [ ] **Step 6: Verify `verify-on-host.sh` still parses and Phase 5 still selects the image**

```bash
bash -n verify-on-host.sh && grep -n 'AI_CONTAINERS_BASH_FLOOR_IMAGE' verify-on-host.sh
```

Expected: no parse error; the grep shows the assignment inside Phase 5. Do **not** run the full Phase 5 here — it pulls a container image; Task 5 exercises this path hermetically.

- [ ] **Step 7: Commit**

```bash
git add bash-floor.sh verify-on-host.sh tests/test-bash-floor.sh
git commit -m "$(cat <<'EOF'
refactor: declare the floor's test image beside the floor itself

The 5.1 -> ubuntu:22.04 mapping lived in three places: the containment guard's
case statement, verify-on-host.sh's Phase 5, and tests.yml's container: key.
Move it into bash-floor.sh, which AGENTS.md already names as the one place the
floor is declared -- the image that TESTS a claim is part of making it.

Kept as a case-map keyed on the declared floor, not a free variable: a floor
bumped without a matching image must yield empty (a hard failure at every
consumer) rather than silently running the "floor" suite at the wrong bash.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The reusable hermetic-checks workflow

Move `suite`, `suite-floor` and `lint` into a callable workflow so `tests.yml` and `nightly.yml` share one definition. This makes `local ⊇ nightly ⊇ PR` true over checks, not only over integration cases.

**Files:**
- Create: `.github/workflows/hermetic-checks.yml`
- Modify: `.github/workflows/tests.yml`
- Modify: `.github/workflows/nightly.yml`

**Interfaces:**
- Produces: a workflow at `.github/workflows/hermetic-checks.yml` with jobs `suite`, `suite-floor`, `lint`. Task 3's registry and Task 5's guard both read this file and depend on those exact job ids and on each step's `name:` text being unchanged.

- [ ] **Step 1: Create the reusable workflow**

Create `.github/workflows/hermetic-checks.yml`. Copy the three jobs from `.github/workflows/tests.yml` **verbatim** — every step, every comment, byte for byte — under this header:

```yaml
name: Hermetic checks

# The PR gate and the nightly run must execute the SAME hermetic checks, or the
# documented contract `local ⊇ nightly ⊇ PR` is false over checks even while it
# holds over integration cases — which is exactly what it was until this file
# existed. Defining the jobs once and calling them from both workflows is the
# only arrangement that cannot drift; copying them into nightly.yml would create
# a second list to keep in step, the failure this repo keeps getting bitten by
# (shared-files.sh, the CHECKS table, the mgd byte-identity gate).
#
# tests/test-layer-containment.sh reads THIS file: every step below must be
# either a `check` row in tests/layer-checks.conf (with a stub and a witness
# proving it also runs locally) or a `setup` row declaring why it is not a
# check. A step that is neither fails that test.
on:
  workflow_call:

permissions:
  contents: read

jobs:
```

Then the three job blocks, unchanged.

- [ ] **Step 2: Reduce `tests.yml` to a caller**

Replace `tests.yml`'s entire `jobs:` block with:

```yaml
jobs:
  # The hermetic checks live in their own callable workflow so this gate and the
  # nightly run cannot drift apart. See hermetic-checks.yml's header.
  hermetic:
    uses: ./.github/workflows/hermetic-checks.yml
```

Keep `tests.yml`'s `name:`, `on:` and `permissions:` blocks exactly as they are.

- [ ] **Step 3: Add the schedule-gated caller to `nightly.yml`**

Insert as the FIRST job under `nightly.yml`'s `jobs:` key, before `integration-full`:

```yaml
  # The same hermetic checks the PR gate runs, so `local ⊇ nightly ⊇ PR` holds
  # over CHECKS and not only over integration cases. ~2¼ runner-minutes.
  #
  # Schedule only. The workflow_dispatch inputs above exist for MUTATION
  # DEMONSTRATIONS, which deliberately break production files to prove a case
  # fails against a known-bad tree; run-all.sh would go red there for reasons
  # that have nothing to do with what the demonstration is proving, burying the
  # signal the dispatch was run to produce. The containment invariant concerns
  # the SCHEDULED nightly layer, so gating this costs the invariant nothing.
  # tests/test-layer-containment.sh pins this exact condition — `if: false`
  # cannot be substituted for it.
  hermetic:
    if: github.event_name == 'schedule'
    uses: ./.github/workflows/hermetic-checks.yml
```

- [ ] **Step 4: Validate all three workflows parse as YAML**

```bash
python3 -c '
import sys, yaml
for f in ["tests.yml", "nightly.yml", "hermetic-checks.yml"]:
    p = ".github/workflows/" + f
    d = yaml.safe_load(open(p))
    print(f, "->", sorted(d["jobs"].keys()))
'
```

Expected:
```
tests.yml -> ['hermetic']
nightly.yml -> ['allowlist-health', 'hermetic', 'integration-full', 'packages-agents', 'packages-native']
hermetic-checks.yml -> ['lint', 'suite', 'suite-floor']
```

If `python3` or PyYAML is unavailable, use `yq '.jobs | keys' <file>`; if neither exists, skip this step and rely on Step 5 plus the CI run itself.

- [ ] **Step 5: Confirm the three jobs were copied verbatim**

```bash
d="$(mktemp -d)"
git show HEAD:.github/workflows/tests.yml | sed -n '/^jobs:/,$p' | tail -n +2 > "$d/before.txt"
sed -n '/^jobs:/,$p' .github/workflows/hermetic-checks.yml | tail -n +2 > "$d/after.txt"
diff "$d/before.txt" "$d/after.txt" && echo "IDENTICAL"; rm -rf "$d"
```

`git show HEAD:` reads the pre-edit `tests.yml` from the last commit, so this works after the working tree has already been changed.

Expected: `IDENTICAL`. Any diff means a step or comment was altered during the move — revert it. Task 3's registry and Task 5's guard both key on the exact `name:` strings.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/hermetic-checks.yml .github/workflows/tests.yml .github/workflows/nightly.yml
git commit -m "$(cat <<'EOF'
ci: one definition of the hermetic checks, called by PR and nightly

AGENTS.md documents `local ⊇ nightly ⊇ PR` but the invariant was only ever true
over integration CASES. nightly.yml ran four integration jobs and zero of
tests.yml's three hermetic ones -- no overlap at all -- so nightly carried none
of the checks a PR runs, let alone a superset.

suite / suite-floor / lint move verbatim into a workflow_call workflow that both
tests.yml and nightly.yml invoke. Copying them into nightly.yml instead would
create a second copy to keep in step; a guard proving two copies never drift is
more machinery than the reusable workflow it avoids.

Measured at 2¼ runner-minutes total (46s + 58s + 31s), so cost did not decide
this -- duplication did. Nightly's caller is schedule-gated: the
workflow_dispatch inputs exist for mutation demonstrations against a
deliberately broken tree, where a red hermetic suite is noise rather than
signal.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The registry and its parser

**Files:**
- Create: `tests/layer-checks.conf`
- Create: `tests/lib-layer-checks.sh`
- Create: `tests/test-layer-checks-parser.sh`

**Interfaces:**
- Consumes: `AI_CONTAINERS_BASH_FLOOR_IMAGE` from Task 1; `.github/workflows/hermetic-checks.yml` job/step names from Task 2.
- Produces, all from `tests/lib-layer-checks.sh` (sourced; requires `LAYER_CHECKS_CONF` set to the registry path beforehand):
  - `lc_rows <type>` — prints registry rows of type `check` or `setup`, one per line, `|`-delimited, with the leading type field stripped. Returns 1 and prints to stderr if none.
  - `wf_jobs <yaml>` — prints job ids, one per line. Returns 1 and prints to stderr if none.
  - `wf_steps <yaml> <job>` — prints step identities (the step's `name:` value, else its `uses:` value), one per line. Returns 1 and prints to stderr if none.

- [ ] **Step 1: Write the registry**

Create `tests/layer-checks.conf`:

```
# tests/layer-checks.conf — every hermetic check, declared ONCE.
#
# Read by tests/lib-verify-repo.sh (which builds each check's stub) and by
# tests/test-layer-containment.sh (which asserts each check's witness). Those
# two previously kept independent hand-written lists, plus a third
# hand-maintained step-count baseline, and nothing made the three agree: adding
# a fourth CI job produced ZERO failures, because the job list was hardcoded as
# three names. This file is the only list; all three are gone.
#
# check|<id>|<job>|<ci_step>|<stub_kind>|<stub_target>|<rc_var>|<witness_target>|<witness_re>
#
#   job          a job id in .github/workflows/hermetic-checks.yml
#   ci_step      that job's step `name:`, matched EXACTLY (not as a substring:
#                the old substring match is what let a filename appearing in a
#                comment satisfy the row)
#   stub_kind    repo-script  executable at <stub-repo>/<stub_target>
#                path-bin     executable at $TMP/bin/<stub_target>, ahead of PATH
#                probe        no stub; plant <stub_target> holding a real syntax
#                             error and read the effect from verify-on-host's log
#                none         no stub; the witness comes from infrastructure
#                             lib-verify-repo.sh creates anyway (the docker stub)
#   rc_var       env var carrying the stub's canned exit code; `-` for none
#   witness_tgt  witness = the shared witness log; log = verify-on-host's output
#   witness_re   an ERE that matches ONLY if the check genuinely ran.
#                @FLOOR_IMAGE@ expands to AI_CONTAINERS_BASH_FLOOR_IMAGE.
#
# setup|<job>|<ci_step>|<why this step is not a check>
#
# Every step of every job in hermetic-checks.yml must appear as one or the
# other. A step that is neither fails tests/test-layer-containment.sh, which is
# what forces a new CI step to be given a layer instead of silently widening the
# PR gate past the local one.

check|hermetic-suite|suite|Run tests|repo-script|tests/run-all.sh|SUITE_RC|witness|^STUB:run-all\.sh$
check|schema-gate|suite|sandbox.conf schema gate|repo-script|check-sandbox-version.sh|SCHEMA_RC|witness|^STUB:check-sandbox-version\.sh$
check|floor-suite|suite-floor|Run tests at the declared floor|none|-|DOCKER_RUN_RC|witness|^STUB:docker-run .*@FLOOR_IMAGE@
check|bash-n|lint|bash -n over every script|probe|tests/broken-syntax-probe.sh|-|log|PARSE ERROR: .*broken-syntax-probe\.sh
check|dialect-lint|lint|bash dialect (nothing newer than the declared floor)|repo-script|tests/bash-dialect-lint.sh|DIALECT_RC|witness|^STUB:bash-dialect-lint\.sh$
check|shellcheck|lint|shellcheck|path-bin|shellcheck|SHELLCHECK_RC|witness|^STUB:shellcheck$

setup|suite|actions/checkout@v5|clones the repo; runs nothing under test
setup|suite|Show bash version|diagnostic output only
setup|suite|Ensure rsync is available|installs a tool the suite needs
setup|suite-floor|Install git and rsync|installs tools actions/checkout and the suite need inside the container
setup|suite-floor|actions/checkout@v5|clones the repo; runs nothing under test
setup|suite-floor|Trust the checkout: container job's workspace is owned by the runner, not this container's root|git safe.directory for the uid mismatch; runs nothing under test
setup|suite-floor|Show bash version|diagnostic output only
setup|lint|actions/checkout@v5|clones the repo; runs nothing under test
```

- [ ] **Step 2: Write the parser's fixture test FIRST**

Create `tests/test-layer-checks-parser.sh`:

```bash
#!/usr/bin/env bash
# tests/test-layer-checks-parser.sh — the registry/YAML parser is TESTED, not
# trusted. A parser that silently returns nothing is this repo's signature
# defect: every consumer would then iterate zero rows and report success having
# checked nothing, which is precisely the class of failure the guard it feeds
# exists to close. So every function here must FAIL LOUDLY on an empty result,
# and those failure paths are exercised below, not merely written.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() {  # $1=label $2=expected $3=actual
  if [[ "$2" == "$3" ]]; then pass "$1"
  else fail "$1 (expected '$2', got '$3')"; fi
}

LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
# shellcheck source=lib-layer-checks.sh
source "$REPO_DIR/tests/lib-layer-checks.sh"

# ── A well-formed two-job fixture, covering every shape the real files use ────
cat > "$TMP/wf.yml" <<'YAML'
name: Fixture
on:
  workflow_call:

permissions:
  contents: read

jobs:
  alpha:
    name: Alpha job
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - name: Plain step
        run: echo hi

      - name: "Quoted: has a colon"
        run: |
          echo multi
          echo line

  beta:
    runs-on: ubuntu-latest
    container: ubuntu:22.04
    steps:
      - name: Only step
        run: echo solo
YAML

check "wf_jobs lists every job in order" \
  "$(printf 'alpha\nbeta')" "$(wf_jobs "$TMP/wf.yml")"

check "wf_steps resolves name:, falls back to uses:, and keeps colons in quoted names" \
  "$(printf 'actions/checkout@v5\nPlain step\nQuoted: has a colon')" \
  "$(wf_steps "$TMP/wf.yml" alpha)"

check "wf_steps does not leak steps across job boundaries" \
  "Only step" "$(wf_steps "$TMP/wf.yml" beta)"

# ── The failure paths, exercised ──────────────────────────────────────────────
printf 'name: NoJobs\non:\n  push:\n' > "$TMP/nojobs.yml"
if wf_jobs "$TMP/nojobs.yml" >/dev/null 2>&1; then
  fail "wf_jobs reported success on a file with no jobs"
else
  pass "wf_jobs fails loudly on a file with no jobs"
fi

printf 'jobs:\n  empty:\n    runs-on: x\n    steps:\n' > "$TMP/nosteps.yml"
if wf_steps "$TMP/nosteps.yml" empty >/dev/null 2>&1; then
  fail "wf_steps reported success on a job with no steps"
else
  pass "wf_steps fails loudly on a job with no steps"
fi

if wf_steps "$TMP/wf.yml" nosuchjob >/dev/null 2>&1; then
  fail "wf_steps reported success for a job that does not exist"
else
  pass "wf_steps fails loudly for a job that does not exist"
fi

# ── The registry ──────────────────────────────────────────────────────────────
n_check="$(lc_rows check | grep -c .)"
[[ "$n_check" -ge 1 ]] \
  && pass "lc_rows check returns $n_check row(s)" \
  || fail "lc_rows check returned nothing"

n_setup="$(lc_rows setup | grep -c .)"
[[ "$n_setup" -ge 1 ]] \
  && pass "lc_rows setup returns $n_setup row(s)" \
  || fail "lc_rows setup returned nothing"

lc_rows check | grep -q '^#' \
  && fail "lc_rows returned a comment line" \
  || pass "lc_rows strips comments and blank lines"

lc_rows check | grep -q '^check|' \
  && fail "lc_rows left the type field on the row" \
  || pass "lc_rows strips the leading type field"

LAYER_CHECKS_CONF="$TMP/empty.conf"; printf '# only a comment\n' > "$LAYER_CHECKS_CONF"
if lc_rows check >/dev/null 2>&1; then
  fail "lc_rows reported success on a registry with no rows"
else
  pass "lc_rows fails loudly on a registry with no rows"
fi
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
```

- [ ] **Step 3: Run it and watch every assertion fail**

```bash
bash tests/test-layer-checks-parser.sh
```

Expected: the `source` of the not-yet-existing `tests/lib-layer-checks.sh` fails, then every `wf_*`/`lc_rows` call reports `command not found` and the checks fail. This confirms the test is actually exercising the functions rather than something that happens to be defined already.

- [ ] **Step 4: Write the parser**

Create `tests/lib-layer-checks.sh`:

```bash
#!/usr/bin/env bash
# tests/lib-layer-checks.sh — parser for tests/layer-checks.conf and for the
# narrow slice of workflow YAML the containment guard needs. SOURCED, never
# executed directly, and deliberately NOT named test-*.sh so tests/run-all.sh's
# glob skips it (same reason as tests/lib-verify-repo.sh).
#
# CONTRACT: the sourcing file sets LAYER_CHECKS_CONF to the registry path before
# sourcing. Provides lc_rows(), wf_jobs(), wf_steps().
#
# EVERY function here fails loudly and non-zero on an empty result. That is the
# whole point: a parser returning nothing quietly would make its consumer
# iterate zero rows and report success having verified nothing -- the exact
# defect the guard this feeds was written to catch.
#
# The YAML handling is a narrow awk reader for the shape these workflow files
# use (2-space job ids, 4-space `steps:`, 6-space `- ` step starts, 8-space step
# keys), NOT a general YAML parser. yq is not guaranteed on a developer's
# machine and skipping the check when it is absent would mean a check that does
# not run. A reformat that breaks this reader makes the guard RED, never green:
# zero jobs and zero steps are both hard errors.

lc_rows() {  # $1=check|setup → matching rows, type field stripped
  local want="${1:?lc_rows: row type required}" out
  [[ -f "${LAYER_CHECKS_CONF:-}" ]] || {
    echo "lib-layer-checks: LAYER_CHECKS_CONF is unset or missing: ${LAYER_CHECKS_CONF:-<unset>}" >&2
    return 1
  }
  out="$(grep -v '^[[:space:]]*#' "$LAYER_CHECKS_CONF" \
         | grep "^${want}|" \
         | sed "s/^${want}|//")"
  [[ -n "$out" ]] || {
    echo "lib-layer-checks: no '$want' rows in $LAYER_CHECKS_CONF" >&2
    return 1
  }
  printf '%s\n' "$out"
}

_wf_awk() {  # $1=yaml  $2=job filter ('' = list jobs instead of steps)
  awk -v job="$2" '
    function val(s) {
      sub(/^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]*/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      return s
    }
    function grab(s) {
      if (s ~ /^name:[[:space:]]/)      { nm = val(s) }
      else if (s ~ /^uses:[[:space:]]/) { us = val(s) }
    }
    function flush() {
      if (started) { print (nm != "" ? nm : (us != "" ? us : "(unnamed step)")) }
      started = 0; nm = ""; us = ""
    }
    BEGIN { inj = 0; injob = 0; insteps = 0; started = 0; nm = ""; us = "" }
    /^jobs:[[:space:]]*$/ { inj = 1; next }
    # Any column-0 key ends the jobs block (permissions:, on:, a trailing key).
    inj && /^[^[:space:]#]/ { flush(); inj = 0; injob = 0; insteps = 0 }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      flush()
      cur = $0; sub(/^  /, "", cur); sub(/:[[:space:]]*$/, "", cur)
      if (job == "") { print cur }
      injob = (cur == job); insteps = 0; next
    }
    injob && /^    steps:[[:space:]]*$/ { insteps = 1; next }
    # A 4-space key after steps: ends the step list (none today, but a job with
    # `steps:` followed by another job-level key must not swallow it).
    injob && insteps && /^    [A-Za-z]/ { flush(); insteps = 0; next }
    insteps && /^      - / {
      flush(); started = 1
      line = $0; sub(/^      - /, "", line); grab(line); next
    }
    insteps && started && /^        [A-Za-z]/ {
      line = $0; sub(/^        /, "", line); grab(line); next
    }
    END { flush() }
  ' "$1"
}

wf_jobs() {  # $1=workflow yaml → job ids, one per line
  local f="${1:?wf_jobs: workflow path required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(_wf_awk "$f" "")"
  [[ -n "$out" ]] || { echo "lib-layer-checks: no jobs found in $f" >&2; return 1; }
  printf '%s\n' "$out"
}

wf_steps() {  # $1=workflow yaml  $2=job id → step identities, one per line
  local f="${1:?wf_steps: workflow path required}"
  local j="${2:?wf_steps: job id required}" out
  [[ -f "$f" ]] || { echo "lib-layer-checks: no such workflow: $f" >&2; return 1; }
  out="$(_wf_awk "$f" "$j")"
  [[ -n "$out" ]] || { echo "lib-layer-checks: job '$j' in $f has no steps" >&2; return 1; }
  printf '%s\n' "$out"
}
```

- [ ] **Step 5: Run the parser test to verify it passes**

```bash
bash tests/test-layer-checks-parser.sh
```

Expected: every assertion PASS, `0 failure(s)`.

- [ ] **Step 6: Verify the parser against the REAL workflow, not just the fixture**

```bash
LAYER_CHECKS_CONF=tests/layer-checks.conf
source tests/lib-layer-checks.sh
wf_jobs .github/workflows/hermetic-checks.yml
for j in suite suite-floor lint; do echo "--- $j ---"; wf_steps .github/workflows/hermetic-checks.yml "$j"; done
```

Expected exactly:
```
suite
suite-floor
lint
--- suite ---
actions/checkout@v5
Show bash version
Ensure rsync is available
Run tests
sandbox.conf schema gate
--- suite-floor ---
Install git and rsync
actions/checkout@v5
Trust the checkout: container job's workspace is owned by the runner, not this container's root
Show bash version
Run tests at the declared floor
--- lint ---
actions/checkout@v5
bash -n over every script
bash dialect (nothing newer than the declared floor)
shellcheck
```

If any line differs from a `ci_step` value in `tests/layer-checks.conf`, fix the **registry** to match the workflow (the workflow was copied verbatim in Task 2 and is the source of truth).

- [ ] **Step 7: Demonstrate the empty-result guards actually fail**

The assertion each break must reach is named explicitly:

```bash
# Break 1 — assertion reads: wf_jobs' EXIT CODE, in the "fails loudly on a file
# with no jobs" case. Remove the emptiness check so the function returns 0.
cp tests/lib-layer-checks.sh /tmp/lc.bak
perl -0pi -e 's/\[\[ -n "\$out" \]\] \|\| \{ echo "lib-layer-checks: no jobs found in \$f" >&2; return 1; \}\n//' tests/lib-layer-checks.sh
bash tests/test-layer-checks-parser.sh; echo "exit=$?"
# Expected: FAIL: wf_jobs reported success on a file with no jobs   (exit >= 1)
cp /tmp/lc.bak tests/lib-layer-checks.sh

# Break 2 — assertion reads: wf_steps' EXIT CODE, in the "fails loudly on a job
# with no steps" case. Same shape as Break 1 but a different function, because
# the two guards are separate code and only one of them being real is exactly
# the kind of half-fix this project keeps finding.
cp tests/lib-layer-checks.sh /tmp/lc.bak
perl -0pi -e "s/\[\[ -n \"\\\$out\" \]\] \|\| \{ echo \"lib-layer-checks: job '\\\$j' in \\\$f has no steps\" >&2; return 1; \}\n//" tests/lib-layer-checks.sh
bash tests/test-layer-checks-parser.sh; echo "exit=$?"
# Expected: FAIL: wf_steps reported success on a job with no steps
#           FAIL: wf_steps reported success for a job that does not exist
cp /tmp/lc.bak tests/lib-layer-checks.sh

# Break 3 — assertion reads: lc_rows' STDOUT, in the "strips the leading type
# field" case. Drop the sed that removes it.
cp tests/lib-layer-checks.sh /tmp/lc.bak
perl -0pi -e 's/\n         \| sed "s\/\^\$\{want\}\|\/\/"//' tests/lib-layer-checks.sh
bash tests/test-layer-checks-parser.sh; echo "exit=$?"
# Expected: FAIL: lc_rows left the type field on the row   (exit >= 1)
cp /tmp/lc.bak tests/lib-layer-checks.sh
rm -f /tmp/lc.bak
```

If either break produces `0 failure(s)`, **the mechanism is weak, not the demonstration** — do not escalate the edit. Report it: the assertion is reading something the break does not reach.

- [ ] **Step 8: Confirm the suite picks up the new test and lints clean**

```bash
bash tests/run-all.sh 2>&1 | tail -5
shellcheck -S warning -e SC1091 tests/lib-layer-checks.sh tests/test-layer-checks-parser.sh
bash tests/bash-dialect-lint.sh
```

Expected: `run-all.sh` reports one more test file than before, all passing; shellcheck silent; dialect lint clean.

- [ ] **Step 9: Commit**

```bash
git add tests/layer-checks.conf tests/lib-layer-checks.sh tests/test-layer-checks-parser.sh
git commit -m "$(cat <<'EOF'
test: one registry for the hermetic checks, with a tested parser

tests/lib-verify-repo.sh's stub list, test-layer-containment.sh's CHECKS table
and its expect_steps baselines all had to agree, and nothing made them. Adding a
locally-run check fired the step-count ratchet, but bumping the baseline plus
adding the invocation was SUFFICIENT to go green -- no stub, no CHECKS row, no
effect-based verification. The same "unverified because nobody remembered"
failure the guard exists to close, one level up.

layer-checks.conf declares each check once: its CI step, how it is stubbed, and
the witness line that proves it ran. lib-layer-checks.sh reads it, and reads the
narrow slice of workflow YAML the guard needs -- deliberately not yq, which is
not guaranteed on a developer's machine, and a check that skips when its tool is
missing is a check that does not run.

Every function fails loudly on an empty result, and those paths are exercised by
test-layer-checks-parser.sh rather than merely written: a parser returning
nothing quietly makes its consumer iterate zero rows and report success.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Registry-driven stubs in `tests/lib-verify-repo.sh`

`mk_repo()` currently hardcodes five stub-creating `printf` blocks. Drive them from the registry instead, and add the two opt-in modes later tasks need.

**Files:**
- Modify: `tests/lib-verify-repo.sh`

**Interfaces:**
- Consumes: `lc_rows`, from `tests/lib-layer-checks.sh` (Task 3). The sourcing file must set `LAYER_CHECKS_CONF` and source `lib-layer-checks.sh` **before** `lib-verify-repo.sh`.
- Produces:
  - `mk_repo()` — unchanged signature (`$1` = build.sh exit code, `$2` = stamp origin/main, default 1). Stubs now come from the registry.
  - `MK_REPO_PROBE=1` — plant every `probe`-kind row's target holding a real syntax error, tracked in the stub repo's git index. Default off.
  - `MK_REPO_UNTRACK_SH=1` — after committing, remove every `*.sh` from the index (files stay on disk) so `git ls-files '*.sh'` returns nothing. Default off.

- [ ] **Step 1: Add the registry dependency and the two knobs to the header contract**

In `tests/lib-verify-repo.sh`'s header comment block, extend the `CONTRACT:` paragraph:

```
# CONTRACT: the sourcing file must set TMP (a scratch dir it owns and tears
# down via its own EXIT trap), VERIFY (path to the real verify-on-host.sh
# under test) and ENGINE_DIR (dir containing the real bash-floor.sh) BEFORE
# sourcing this file, and must have already set LAYER_CHECKS_CONF and sourced
# tests/lib-layer-checks.sh (this file calls lc_rows). Provides: mk_repo(),
# run_verify(), stub binaries at $TMP/bin/{docker,shellcheck}, and $WITNESS_LOG.
#
# Two opt-in modes, both default OFF because test-verify-exit-code.sh shares
# mk_repo() and asserts canned exit codes:
#   MK_REPO_PROBE=1       plant each `probe` row's target holding a REAL syntax
#                         error, tracked, so Phase 7's bash -n emits a
#                         "PARSE ERROR: <path>" line. Always-on would make that
#                         file's Phase 7 fail independently of the RC under test.
#   MK_REPO_UNTRACK_SH=1  after the commit, drop every *.sh from the index so
#                         `git ls-files '*.sh'` is empty while the files remain
#                         on disk. Exercises the "parsed no files" branch.
```

Add the guard beside the existing `TMP`/`VERIFY`/`ENGINE_DIR` check:

```bash
declare -F lc_rows >/dev/null 2>&1 || {
  echo "lib-verify-repo.sh: source tests/lib-layer-checks.sh (with LAYER_CHECKS_CONF set) first" >&2
  return 1 2>/dev/null || exit 1
}
```

- [ ] **Step 2: Replace the hardcoded `path-bin` stub with a registry loop**

Replace the hand-written `shellcheck` stub block (`cat > "$TMP/bin/shellcheck"` … `chmod +x`) with, keeping the surrounding explanatory comment about why the stub always wins over PATH:

```bash
mkdir -p "$TMP/bin"
_n_pathbin=0
while IFS='|' read -r id job step kind target rc_var wtgt wre; do
  [[ "$kind" == "path-bin" ]] || continue
  cat > "$TMP/bin/$target" <<EOF
#!/usr/bin/env bash
printf 'STUB:%s\n' "$target" >> "$WITNESS_LOG"
exit "\${${rc_var}:-0}"
EOF
  chmod +x "$TMP/bin/$target"
  _n_pathbin=$((_n_pathbin+1))
done < <(lc_rows check)
# A registry read that produced no path-bin stub means the registry is empty,
# malformed, or lc_rows failed — all of which would otherwise leave the REAL
# shellcheck on PATH and let this "hermetic" library depend on the host.
(( _n_pathbin > 0 )) || {
  echo "lib-verify-repo.sh: no path-bin stubs built from $LAYER_CHECKS_CONF" >&2
  return 1 2>/dev/null || exit 1
}
```

Leave the `docker` stub exactly as it is: it is Phase-0 infrastructure that the `floor-suite` row (kind `none`) happens to read, not a stub the registry creates.

- [ ] **Step 3: Replace the three hardcoded `repo-script` stubs inside `mk_repo()`**

Delete the three hand-written blocks creating `tests/run-all.sh`, `check-sandbox-version.sh` and `tests/bash-dialect-lint.sh`, and insert before `mk_repo`'s `git init` subshell:

```bash
  # Stubs from the registry (tests/layer-checks.conf) rather than one hardcoded
  # printf per check. The two lists used to be maintained separately and nothing
  # made them agree.
  local id job step kind target rc_var wtgt wre rc_val
  local n_repo=0
  while IFS='|' read -r id job step kind target rc_var wtgt wre; do
    case "$kind" in
      repo-script)
        mkdir -p "$r/$(dirname "$target")"
        # Indirect expansion, not eval: the registry supplies the VARIABLE NAME
        # (SUITE_RC, SCHEMA_RC, …) and the caller may have set it to a canned
        # exit code. eval here would execute registry content as shell.
        rc_val="${!rc_var:-0}"
        printf '#!/usr/bin/env bash\nprintf "STUB:%s\\n" >> "%s"\nexit %s\n' \
          "$(basename "$target")" "$WITNESS_LOG" "$rc_val" > "$r/$target"
        chmod +x "$r/$target"
        n_repo=$((n_repo+1))
        ;;
      probe)
        [[ "${MK_REPO_PROBE:-0}" == "1" ]] || continue
        mkdir -p "$r/$(dirname "$target")"
        # A REAL syntax error: Phase 7 can only print "PARSE ERROR: <path>" for
        # this if bash -n genuinely ran against its content. A comment merely
        # naming "bash -n" could never produce that line.
        printf '#!/usr/bin/env bash\nif [ 1 -eq\n' > "$r/$target"
        ;;
    esac
  done < <(lc_rows check)
  # Same reasoning as the path-bin guard above: a stub repo built from an empty
  # or unreadable registry would still look like a valid repo, and every witness
  # assertion downstream would fail with a misleading cause.
  (( n_repo > 0 )) || {
    echo "mk_repo: no repo-script stubs built from $LAYER_CHECKS_CONF" >&2
    return 1
  }
```

- [ ] **Step 4: Add the untrack mode after the commit**

Extend `mk_repo`'s `git init` subshell so the final `git update-ref` line is followed by:

```bash
      && { [[ "${MK_REPO_UNTRACK_SH:-0}" != "1" ]] || {
             git rm -q --cached -- '*.sh' >/dev/null 2>&1
             git -c user.email=t@example -c user.name=t commit -q -m untrack-sh
           }; } \
```

Place it before the closing `) >/dev/null 2>&1`. The files remain on disk, so every `[[ -f ... ]]` existence check in `verify-on-host.sh` still passes; only `git ls-files '*.sh'` goes empty.

- [ ] **Step 5: Verify the existing consumers still pass unchanged**

`tests/test-verify-exit-code.sh` must be updated only to source the new library — add, above its `source .../lib-verify-repo.sh` line:

```bash
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
# shellcheck source=lib-layer-checks.sh
source "$REPO_DIR/tests/lib-layer-checks.sh"
```

Then:

```bash
bash tests/test-verify-exit-code.sh
```

Expected: identical pass/fail output to before this task — every case still passes. Neither opt-in mode is set, so `mk_repo()` behaves exactly as it did.

- [ ] **Step 6: Verify both opt-in modes do what they claim**

```bash
cat > /tmp/probe-check.sh <<'EOF'
set -uo pipefail
REPO_DIR="$(pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
VERIFY="$REPO_DIR/verify-on-host.sh"; ENGINE_DIR="$REPO_DIR"
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
source "$REPO_DIR/tests/lib-layer-checks.sh"
source "$REPO_DIR/tests/lib-verify-repo.sh"
r="$(MK_REPO_PROBE=1 mk_repo 0)"
echo "probe planted: $( [[ -f "$r/tests/broken-syntax-probe.sh" ]] && echo yes || echo NO )"
echo "probe tracked: $(cd "$r" && git ls-files tests/broken-syntax-probe.sh)"
r2="$(MK_REPO_UNTRACK_SH=1 mk_repo 0)"
echo "untracked mode, .sh still on disk: $( [[ -f "$r2/tests/run-all.sh" ]] && echo yes || echo NO )"
echo "untracked mode, git ls-files '*.sh' count: $(cd "$r2" && git ls-files '*.sh' | grep -c . )"
r3="$(mk_repo 0)"
echo "default mode, probe absent: $( [[ -f "$r3/tests/broken-syntax-probe.sh" ]] && echo NO || echo yes )"
echo "default mode, git ls-files '*.sh' count: $(cd "$r3" && git ls-files '*.sh' | grep -c . )"
EOF
bash /tmp/probe-check.sh; rm -f /tmp/probe-check.sh
```

Expected:
```
probe planted: yes
probe tracked: tests/broken-syntax-probe.sh
untracked mode, .sh still on disk: yes
untracked mode, git ls-files '*.sh' count: 0
default mode, probe absent: yes
default mode, git ls-files '*.sh' count: 4
```

(The default count is the four `.sh` files `mk_repo` writes: `verify-on-host.sh`, `bash-floor.sh`, `build.sh`, and the three registry stubs, minus whichever are not `.sh` — accept any count ≥ 1; the assertion that matters is `0` in untracked mode and non-zero in default mode.)

- [ ] **Step 7: Lint and commit**

```bash
shellcheck -S warning -e SC1091 tests/lib-verify-repo.sh tests/test-verify-exit-code.sh
bash tests/bash-dialect-lint.sh
git add tests/lib-verify-repo.sh tests/test-verify-exit-code.sh
git commit -m "$(cat <<'EOF'
test: build verify-repo stubs from the registry, not five hardcoded printfs

mk_repo() hand-wrote one stub per check and test-layer-containment.sh hand-wrote
a matching regex per check. Two lists, no mechanism keeping them in step. Both
now iterate tests/layer-checks.conf.

Adds two opt-in modes, both default OFF because test-verify-exit-code.sh shares
mk_repo() and asserts canned exit codes: MK_REPO_PROBE plants the broken-syntax
file (moved in from test-layer-containment.sh, so every stub is created in one
place), and MK_REPO_UNTRACK_SH drops *.sh from the index while leaving the files
on disk, which is what makes verify-on-host's "parsed no files" branch reachable.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Rewrite `tests/test-layer-containment.sh`

**Files:**
- Modify: `tests/test-layer-containment.sh`

**Interfaces:**
- Consumes: `lc_rows`, `wf_jobs`, `wf_steps` (Task 3); `mk_repo`, `run_verify`, `WITNESS_LOG`, `MK_REPO_PROBE` (Task 4); `AI_CONTAINERS_BASH_FLOOR_IMAGE` (Task 1); `.github/workflows/hermetic-checks.yml` (Task 2).

- [ ] **Step 1: Retarget the file's inputs**

Replace the `TESTS_YML=` assignment and add the new paths:

```bash
HERMETIC_YML="$REPO_DIR/.github/workflows/hermetic-checks.yml"
TESTS_YML="$REPO_DIR/.github/workflows/tests.yml"
NIGHTLY_YML="$REPO_DIR/.github/workflows/nightly.yml"
LAYER_CHECKS_CONF="$REPO_DIR/tests/layer-checks.conf"
LIB_LAYER_CHECKS="$REPO_DIR/tests/lib-layer-checks.sh"
```

Add `$HERMETIC_YML`, `$NIGHTLY_YML`, `$LAYER_CHECKS_CONF` and `$LIB_LAYER_CHECKS` to the existing `for f in ...` required-files preflight loop, keeping its "report EVERY missing file" behaviour.

Source the parser before `lib-verify-repo.sh`:

```bash
# shellcheck source=lib-layer-checks.sh
source "$LIB_LAYER_CHECKS"
```

- [ ] **Step 2: Assert both workflows call the reusable one**

Insert after the preflight block:

```bash
# ── Both layers call the one definition ───────────────────────────────────────
# The reusable workflow only makes `nightly ⊇ PR` true over checks if BOTH
# workflows actually call it. Extracting the jobs and forgetting to wire nightly
# would leave the invariant exactly as false as before, with a file present that
# makes it LOOK addressed.
for wf in "$TESTS_YML" "$NIGHTLY_YML"; do
  if grep -qF 'uses: ./.github/workflows/hermetic-checks.yml' "$wf"; then
    pass "$(basename "$wf") calls hermetic-checks.yml"
  else
    fail "$(basename "$wf") does not call hermetic-checks.yml — the hermetic checks do not run in that layer"
  fi
done

# Nightly's caller is schedule-gated ON PURPOSE (mutation dispatches break the
# tree deliberately). Pin the exact condition so `if: false` — which would
# silently remove nightly's hermetic leg while leaving the `uses:` above intact,
# passing the assertion right before this one — cannot be substituted for it.
if grep -qF "if: github.event_name == 'schedule'" "$NIGHTLY_YML"; then
  pass "nightly's hermetic caller is gated on the schedule event, not disabled"
else
  fail "nightly's hermetic caller does not carry the expected schedule condition — it may have been disabled rather than gated"
fi
```

- [ ] **Step 3: Build the stub repo with the probe from the registry**

Replace the current hand-written probe block (`printf '#!/usr/bin/env bash\nif [ 1 -eq\n' > "$r/tests/broken-syntax-probe.sh"` and its `git add`/`commit`) with:

```bash
r="$(MK_REPO_PROBE=1 mk_repo 0)"
```

The probe is now planted and committed by `mk_repo()` itself (Task 4).

Keep the `run_verify "$r" "5 7" >/dev/null` call and its explanatory comment.

- [ ] **Step 4: Replace the CHECKS heredoc with registry iteration**

Delete the `CHECKS='...'` heredoc and its `while IFS= read -r row` loop entirely. Replace with:

```bash
# ── Every PR-layer check also runs locally — EFFECT, not text presence ─────────
# Rows come from tests/layer-checks.conf; see its header. Two assertions per row:
# the CI step exists (by EXACT step name, not a substring anywhere in the file —
# the substring form is what let a filename in a comment satisfy a row), and the
# witness line proving the check genuinely ran locally is present.
floor_img="${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}"
if [[ -z "$floor_img" ]]; then
  fail "bash-floor.sh maps no image to floor $floor — the floor-suite row cannot be checked"
fi

while IFS='|' read -r id job step kind target rc_var wtgt wre; do
  # Exact step-name match within the named job.
  if wf_steps "$HERMETIC_YML" "$job" 2>/dev/null | grep -qxF "$step"; then
    pass "$id: hermetic-checks.yml job '$job' has step '$step'"
  else
    fail "$id: hermetic-checks.yml job '$job' has NO step named '$step' — this registry row is stale"
    continue
  fi

  case "$wtgt" in
    witness) hay="$WITNESS_LOG" ;;
    log)     hay="$TMP/out.log" ;;
    *) fail "$id: unrecognised witness target '$wtgt' — this registry row is broken"; continue ;;
  esac

  expect_re="${wre//@FLOOR_IMAGE@/$floor_img}"
  if grep -qE "$expect_re" "$hay"; then
    pass "$id runs in the local layer too (observed actually running)"
  else
    fail "$id runs in CI but was NOT OBSERVED RUNNING in verify-on-host.sh (no witness — local is not a superset)"
  fi
done < <(lc_rows check)
```

- [ ] **Step 5: Replace `expect_steps` with step classification**

Delete the `expect_steps()` function and its three calls (`expect_steps suite 5` etc.) entirely. Replace with:

```bash
# ── Every step is classified: a check with a witness, or declared setup ────────
# A hand-written list can only police what it names. The previous version pinned
# a STEP COUNT per job against a baseline, with a hardcoded list of three job
# names — so a fourth CI job was entirely invisible (no row, no count, no
# witness), and even for a named job the remedy for a new step was "change 5 to
# 6". Here the job list is DERIVED from the workflow, and the remedy is to
# declare what the step is: calling it a check forces a registry row, which
# forces a stub and a local invocation, or the witness assertion above fails.
#
# This subsumes the count assertion rather than dropping it: if every step
# classifies and every registry row finds its step (above), the counts agree by
# construction.
classified=0
while IFS= read -r job; do
  while IFS= read -r step; do
    if lc_rows check | awk -F'|' -v j="$job" -v s="$step" '$2==j && $3==s {found=1} END{exit !found}'; then
      classified=$((classified+1))
    elif lc_rows setup | awk -F'|' -v j="$job" -v s="$step" '$1==j && $2==s {found=1} END{exit !found}'; then
      classified=$((classified+1))
    else
      fail "step '$step' in job '$job' is neither a registry check nor declared setup — classify it in tests/layer-checks.conf"
    fi
  done < <(wf_steps "$HERMETIC_YML" "$job")
done < <(wf_jobs "$HERMETIC_YML")

# A classification pass that classified NOTHING must not report success: a
# parser change or a workflow reorganisation would otherwise turn this whole
# section into a silent no-op that still goes green.
if [[ "$classified" -gt 0 ]]; then
  pass "every step in hermetic-checks.yml is classified ($classified step(s))"
else
  fail "classified no steps at all — the workflow parse returned nothing"
fi
```

- [ ] **Step 6: Simplify the floor-image assertion to read the shared map**

Replace the `case "$floor" in 5.1) want_img=... esac` block and its three-branch `if` with:

```bash
# The floor job must run the image matching the DECLARED floor. The map lives in
# bash-floor.sh (see its comment); this asserts the workflow agrees with it.
if [[ -z "$floor_img" ]]; then
  fail "no container image is mapped to floor $floor — suite-floor cannot test the claim"
elif grep -qF "container: $floor_img" "$HERMETIC_YML"; then
  pass "suite-floor runs $floor_img, matching the declared floor $floor"
else
  fail "suite-floor does not run $floor_img — the declared floor $floor is untested"
fi
```

Keep the existing `source "$ENGINE_DIR/bash-floor.sh"` and `floor="${AI_CONTAINERS_BASH_FLOOR_MAJOR}.${AI_CONTAINERS_BASH_FLOOR_MINOR}"` lines above it, and move them **above** Step 4's block so `$floor_img` and `$floor` are set before first use.

- [ ] **Step 7: Update the file's header comment**

Replace the `FIX ROUND 1 (review finding, Critical):` paragraph's final sentences with an added paragraph:

```
# INCREMENT 4 FOLLOW-UP: the effect-witness fix above holds for the rows that
# exist — but nothing forced a row to EXIST. Three lists had to agree
# (lib-verify-repo.sh's stubs, the CHECKS table here, and the expect_steps
# baselines) and nothing made them: adding a fourth CI job produced ZERO
# failures, because the job list was hardcoded as three names. All three are now
# tests/layer-checks.conf, the job list is derived from the workflow, and every
# step must classify as a registry check or declared setup.
```

- [ ] **Step 8: Run it and confirm it passes**

```bash
bash tests/test-layer-containment.sh
```

Expected: `0 failure(s)`, with one `PASS` per registry check row (two each), the two caller assertions, the schedule-condition assertion, the classification total, the floor-image assertion, and the three integration-case containment assertions.

- [ ] **Step 9: Demonstrate the new guards failing — the hole this task exists to close**

Each break below names the exact assertion output it must reach. Apply, run, observe red, revert.

```bash
# ── Break A: a fourth CI job with an unclassified step ────────────────────────
# Assertion read: the `fail "step '...' is neither a registry check nor declared
# setup"` line inside the classification loop. This is THE hole — today the same
# edit produces 0 failures because expect_steps iterates three hardcoded names.
cp .github/workflows/hermetic-checks.yml /tmp/h.bak
cat >> .github/workflows/hermetic-checks.yml <<'YAML'

  sneaky:
    runs-on: ubuntu-latest
    steps:
      - name: Something nobody gave a layer
        run: echo gotcha
YAML
bash tests/test-layer-containment.sh | grep -E '^FAIL'; echo "exit=${PIPESTATUS[0]}"
# Expected: FAIL: step 'Something nobody gave a layer' in job 'sneaky' is neither…
cp /tmp/h.bak .github/workflows/hermetic-checks.yml

# ── Break B: a new step in an EXISTING job ────────────────────────────────────
# Assertion read: the same classification `fail` line. Under the old
# expect_steps this failed too, but its remedy was "change 4 to 5"; here the
# remedy is to declare the step, which forces a stub and a witness.
cp .github/workflows/hermetic-checks.yml /tmp/h.bak
perl -0pi -e "s/(      - name: shellcheck\n)/      - name: Undeclared extra\n        run: echo x\n\n\$1/" .github/workflows/hermetic-checks.yml
bash tests/test-layer-containment.sh | grep -E '^FAIL'
# Expected: FAIL: step 'Undeclared extra' in job 'lint' is neither…
cp /tmp/h.bak .github/workflows/hermetic-checks.yml

# ── Break C: a registry check whose stub never runs ───────────────────────────
# Assertion read: the `fail "$id runs in CI but was NOT OBSERVED RUNNING"` line.
# Comment out verify-on-host.sh's real dialect-lint invocation while LEAVING the
# comment that names the file — the precise edit that defeated the pre-increment-4
# text-grep version.
cp verify-on-host.sh /tmp/v.bak
perl -0pi -e 's{^(  bash "\$TESTS_DIR/bash-dialect-lint\.sh".*)$}{  # $1}m' verify-on-host.sh
bash tests/test-layer-containment.sh | grep -E '^FAIL'
# Expected: FAIL: dialect-lint runs in CI but was NOT OBSERVED RUNNING…
cp /tmp/v.bak verify-on-host.sh

# ── Break D: nightly stops calling the reusable workflow ──────────────────────
# Assertion read: `fail "nightly.yml does not call hermetic-checks.yml"`.
cp .github/workflows/nightly.yml /tmp/n.bak
perl -0pi -e 's{^    uses: \./\.github/workflows/hermetic-checks\.yml\n}{}m' .github/workflows/nightly.yml
bash tests/test-layer-containment.sh | grep -E '^FAIL'
# Expected: FAIL: nightly.yml does not call hermetic-checks.yml…
cp /tmp/n.bak .github/workflows/nightly.yml

# ── Break E: the caller is disabled rather than gated ─────────────────────────
# Assertion read: `fail "nightly's hermetic caller does not carry the expected
# schedule condition"`. Note the `uses:` line SURVIVES this edit, so Break D's
# assertion still passes — which is exactly why this second assertion exists.
cp .github/workflows/nightly.yml /tmp/n.bak
perl -0pi -e "s/if: github\.event_name == 'schedule'/if: false/" .github/workflows/nightly.yml
bash tests/test-layer-containment.sh | grep -E '^FAIL'
# Expected: FAIL: nightly's hermetic caller does not carry the expected schedule condition…
cp /tmp/n.bak .github/workflows/nightly.yml

# ── Break F: floor and image drift apart ──────────────────────────────────────
# Assertion read: `fail "suite-floor does not run <img>"`. Bump the floor in
# bash-floor.sh; its map yields ubuntu:24.04 while the workflow still says 22.04.
cp bash-floor.sh /tmp/b.bak
perl -0pi -e 's/^AI_CONTAINERS_BASH_FLOOR_MINOR=1$/AI_CONTAINERS_BASH_FLOOR_MINOR=2/m' bash-floor.sh
bash tests/test-layer-containment.sh | grep -E '^FAIL'
# Expected: FAIL: suite-floor does not run ubuntu:24.04 — the declared floor 5.2 is untested
cp /tmp/b.bak bash-floor.sh

rm -f /tmp/h.bak /tmp/v.bak /tmp/n.bak /tmp/b.bak
```

**If any break produces zero `FAIL` lines, stop and report it.** The first hypothesis is that the mechanism is weak, not that the break needs to be bigger.

- [ ] **Step 10: Confirm the tree is back to green and lint clean**

```bash
git diff --stat            # expect: only tests/test-layer-containment.sh modified
bash tests/run-all.sh 2>&1 | tail -5
shellcheck -S warning -e SC1091 tests/test-layer-containment.sh
bash tests/bash-dialect-lint.sh
```

Expected: every demonstration reverted (no stray diff in the workflow files, `verify-on-host.sh` or `bash-floor.sh`), whole suite green, lints silent.

- [ ] **Step 11: Commit**

```bash
git add tests/test-layer-containment.sh
git commit -m "$(cat <<'EOF'
test: derive the containment guard from the workflow, not three hardcoded lists

Adding a fourth job to tests.yml produced ZERO failures. expect_steps iterated a
hardcoded list of three job names, so a new job had no row, no step count and no
witness -- it could widen the PR gate past the local layer with nothing noticing.
Demonstrated before this change and after; see the plan's Break A.

The job list now comes from the workflow file. Every step must classify as a
registry check (which forces a stub and a witness proving it runs locally) or as
declared setup with a stated reason. That subsumes expect_steps rather than
dropping it: if every step classifies and every row finds its step, the counts
agree by construction.

Each row's CI half is now an EXACT step-name match. It was `grep -qE` over the
whole file -- the same substring shape that, before increment 4, let a filename
in a comment satisfy a row whose check had been commented out.

Also asserts both workflows call the reusable one, and that nightly's caller is
schedule-GATED rather than disabled: `if: false` leaves the `uses:` line intact
and would satisfy the caller assertion on its own.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `verify-on-host.sh` defects (§6.2, §6.3, §6.6, §6.10)

**Files:**
- Modify: `verify-on-host.sh` (Phase 7 block, and the comment at line 349)
- Modify: `tests/test-verify-exit-code.sh`

- [ ] **Step 1: Write the failing test for §6.10 (the unexercised "parsed no files" branch)**

Append to `tests/test-verify-exit-code.sh`, before its final tally:

```bash
# ── Phase 7's "parsed no files" branch, exercised ─────────────────────────────
# This branch existed unexercised: no fixture ever produced an empty
# `git ls-files '*.sh'`, so replacing its phase_fail with a no-op changed
# nothing. MK_REPO_UNTRACK_SH drops *.sh from the index while leaving the files
# on disk, so every existence check still passes and this is the ONLY thing that
# fails — which is what makes both assertions below meaningful.
r="$(MK_REPO_UNTRACK_SH=1 mk_repo 0)"
rc="$(run_verify "$r" "7")"
[[ "$rc" != "0" ]] \
  && pass "a run whose bash -n matched no files exits non-zero" \
  || fail "a run whose bash -n matched no files exited 0 — it verified nothing and said so with a zero"
grep -q "bash -n parsed no files" "$TMP/out.log" \
  && pass "the empty-pathspec run names 'bash -n parsed no files'" \
  || fail "the empty-pathspec run did not report 'bash -n parsed no files' (got: $(tail -3 "$TMP/out.log" | tr '\n' ' '))"
```

- [ ] **Step 2: Run it and confirm it passes ALREADY, then prove it can fail**

```bash
bash tests/test-verify-exit-code.sh
```

Expected: both new assertions PASS — the branch is correct, it was merely untested. Now prove the test can fail:

```bash
cp verify-on-host.sh /tmp/v.bak
perl -0pi -e 's{^  phase_fail 7 "bash -n parsed no files.*$}{  :}m' verify-on-host.sh
bash tests/test-verify-exit-code.sh | grep -E '^FAIL'
# Assertion read: BOTH new ones — the exit code (now 0, since nothing else in
# Phase 7 fails for this repo) and the absent log line.
# Expected: FAIL: a run whose bash -n matched no files exited 0…
#           FAIL: the empty-pathspec run did not report 'bash -n parsed no files'…
cp /tmp/v.bak verify-on-host.sh; rm -f /tmp/v.bak
```

If this produces no `FAIL` lines, the untracked-mode repo is failing Phase 7 for some *other* reason and both assertions are passing for the wrong cause — investigate before continuing.

- [ ] **Step 3: Fix §6.3 — `xargs` without `-r` fires a second `phase_fail`**

In Phase 7's shellcheck block, replace the `git ls-files '*.sh' | xargs shellcheck ...` pipeline:

```bash
  # -r/--no-run-if-empty: GNU xargs runs the command ONCE with no arguments when
  # its input is empty, so shellcheck would lint the whole tree from stdin and
  # this phase would record a SECOND phase_fail for the one root cause already
  # reported by the bash -n branch above ("RESULT: FAILED — 2 phase(s)" for a
  # single problem). BSD xargs is no-run-if-empty by default and does not accept
  # -r before macOS 13, so probe for it rather than assuming.
  xargs_r=()
  printf '' | xargs -r true >/dev/null 2>&1 && xargs_r=(-r)
  ( cd "$REPO" && git ls-files '*.sh' | xargs "${xargs_r[@]}" shellcheck -S warning -e SC1091 ) \
    2>&1 | sed "s/^/$LOG_PREFIX   /"
```

- [ ] **Step 4: Fix §6.2 — Phase 7 reports success with no positive evidence**

After the dialect-lint block's `[[ "$d_rc" -eq 0 ]] || phase_fail ...` line, add:

```bash
  sub "dialect lint exit: $d_rc"
```

And after the shellcheck block's `[[ "$sc_rc" -eq 0 ]] || phase_fail ...` line, add:

```bash
  sub "shellcheck exit: $sc_rc over $( ( cd "$REPO" && git ls-files '*.sh' ) | grep -c . ) script(s)"
```

Rationale to put in a comment above the first one:

```bash
  # Both of these are silent when clean, so a phase that ran them and a phase
  # that skipped them looked identical in the log. In a project whose recurring
  # bug is checks reporting success without doing anything, "passed silently" is
  # not good enough evidence — say what ran and over how much.
```

- [ ] **Step 5: Fix §6.6 — the stale comment**

At `verify-on-host.sh:349`, replace `# ones back. The only remaining phase delegates to tests/integration/run.sh, which` with:

```bash
# ones back. Phase 4 — the only phase that invokes build.sh — delegates to
# tests/integration/run.sh, which
```

- [ ] **Step 6: Verify and commit**

```bash
bash -n verify-on-host.sh
bash tests/test-verify-exit-code.sh
shellcheck -S warning -e SC1091 verify-on-host.sh tests/test-verify-exit-code.sh
bash tests/bash-dialect-lint.sh
git add verify-on-host.sh tests/test-verify-exit-code.sh
git commit -m "$(cat <<'EOF'
fix: Phase 7 evidence, xargs -r, and the unexercised parsed-no-files branch

The "bash -n parsed no files" guard had never run: no fixture produced an empty
git ls-files, so replacing its phase_fail with a no-op changed nothing.
MK_REPO_UNTRACK_SH gives it a fixture, and the demonstration confirms both
assertions go red when the guard is neutered.

GNU xargs without -r runs the command once on empty input, so a zero-file
shellcheck run recorded a SECOND phase_fail for the one root cause already
reported ("FAILED — 2 phase(s)" for a single problem). Probed rather than
assumed: BSD xargs is no-run-if-empty by default and rejects -r before macOS 13.

The dialect linter and shellcheck are both silent when clean, so a phase that
ran them looked identical to one that skipped them. Each now reports its exit
code, and shellcheck the file count it covered.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `EXTRA_MOUNTS` and `PREVIEW_PORTS` glob expansion (§6.8)

Increment 4 added `split_repos_env()` with `set -f` for `REPOS` only. `EXTRA_MOUNTS="*.txt"` and `PREVIEW_PORTS="*"` still pathname-expand against the launch directory.

**Files:**
- Modify: `sandbox.sh:270-284` (rename), `sandbox.sh:351`, `sandbox.sh:776`
- Modify: `tests/test-parsers.sh:254-294`

- [ ] **Step 1: Write the failing tests**

In `tests/test-parsers.sh`, after the existing `split_repos_env` block (which ends at the "an unset value produces no entries" check), add:

```bash
# The same protection for the other two whitespace-separated env lists. REPOS
# got it in increment 4; these two were explicitly left for the follow-up and
# still expanded against the launch directory.
out="$(cd "$TMP" && touch a.txt b.txt && run_fn split_env_list "*.txt")"
check "split_env_list: a glob-looking value stays literal for EXTRA_MOUNTS shape" "*.txt" "$out"

out="$(cd "$TMP" && run_fn split_env_list "$(printf '8080\n3000')")"
check "split_env_list: newline-separated ports are NOT dropped" "$(printf '8080\n3000')" "$out"
```

Rename every existing `split_repos_env` reference in this file to `split_env_list`, keeping the assertion labels' meaning intact (change `"split_repos_env: ..."` to `"split_env_list: ..."`).

- [ ] **Step 2: Run and watch it fail**

```bash
bash tests/test-parsers.sh 2>&1 | grep -E 'split_env_list|FAIL' | head
```

Expected: failures naming `split_env_list` as an unknown function.

- [ ] **Step 3: Rename the helper and widen its comment**

In `sandbox.sh`, rename `split_repos_env` to `split_env_list` and replace its header comment:

```bash
split_env_list() {  # $1=raw value (e.g. "$REPOS", "$EXTRA_MOUNTS", "$PREVIEW_PORTS")
  # Word-split a whitespace-separated env list WITHOUT pathname expansion.
  # Unquoted `for x in $VAR` splits on $IFS but also globs, so a value like
  # "*.txt" silently becomes whatever the launch directory happens to contain.
  # `set -f` blocks that; the prior state is captured and restored so this never
  # leaks noglob into the caller.
```

Keep the body unchanged.

- [ ] **Step 4: Route the two remaining call sites through it**

At `sandbox.sh:351`, replace:

```bash
    for entry in $EXTRA_MOUNTS; do
```
with:
```bash
    while IFS= read -r entry; do
```
and change that loop's closing `done` to `done < <(split_env_list "$EXTRA_MOUNTS")`.

At `sandbox.sh:776`, replace:

```bash
    for p in $PREVIEW_PORTS; do
      port_flags+=(-p "$p")
    done
```
with:
```bash
    while IFS= read -r p; do
      port_flags+=(-p "$p")
    done < <(split_env_list "$PREVIEW_PORTS")
```

Update the `REPOS` call site's comment at `sandbox.sh:386` from `split_repos_env (defined above)` to `split_env_list (defined above)`.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash tests/test-parsers.sh 2>&1 | tail -3
grep -c 'split_repos_env' sandbox.sh tests/test-parsers.sh
```

Expected: `0 failure(s)`; both grep counts `0`.

- [ ] **Step 6: Demonstrate the fix is load-bearing**

```bash
# Assertion read: the "a glob-looking value stays literal for EXTRA_MOUNTS
# shape" check's `$out`. Remove set -f from the helper and it expands.
cp sandbox.sh /tmp/s.bak
perl -0pi -e 's/^  set -f$//m' sandbox.sh
bash tests/test-parsers.sh 2>&1 | grep -E '^FAIL.*split_env_list'
# Expected: FAIL: split_env_list: a glob-looking value stays literal … (got 'a.txt b.txt')
cp /tmp/s.bak sandbox.sh; rm -f /tmp/s.bak
```

- [ ] **Step 7: Verify the launcher still starts a container**

```bash
bash -n sandbox.sh
EXTRA_MOUNTS="/tmp:ro" PREVIEW_PORTS="8080 3000" bash -c '
  set -uo pipefail
  source ./sandbox-common.sh 2>/dev/null || true
  echo "syntax and sourcing OK"'
shellcheck -S warning -e SC1091 sandbox.sh
```

Expected: no parse errors, shellcheck silent. A real container launch is Phase 4's job, not this task's.

- [ ] **Step 8: Commit**

```bash
git add sandbox.sh tests/test-parsers.sh
git commit -m "$(cat <<'EOF'
fix: EXTRA_MOUNTS and PREVIEW_PORTS no longer pathname-expand

Increment 4 added split_repos_env() with set -f, scoped to REPOS only -- the
reviewer deliberately left the other two for this follow-up. EXTRA_MOUNTS="*.txt"
and PREVIEW_PORTS="*" still globbed against the launch directory, mounting or
publishing whatever happened to be sitting there.

The helper was already generic; renamed split_env_list and pointed at all three
call sites, which also fixes newline-separated values being dropped in the same
two places.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Portability and fixture defects (§6.1, §6.4, §6.5, §6.7, §6.9)

**Files:**
- Modify: `tests/portability.sh` (§6.1)
- Modify: `tests/test-rvm-reconcile.sh` (§6.4)
- Modify: `tests/test-parsers.sh:407-412` (§6.5)
- Modify: `tests/bash-dialect-lint.sh`, `tests/integration/run.sh`, `tests/integration/lib.sh` comments (§6.7)
- Modify: `tests/test-bash-dialect-lint.sh` (§6.9)

- [ ] **Step 1: §6.1 — remove the `stat -c … || stat -f …` trap**

In `tests/portability.sh`, replace `p_stat_mode` and `p_stat_meta` with a one-time platform probe:

```bash
# GNU `stat -f` is NOT an invalid option that falls through — it means
# --file-system, so on GNU the old `stat -c … || stat -f …` fallback did not
# error, it printed filesystem information to stdout. Harmless at today's call
# sites (all pre-check existence) and silently wrong for anyone reusing the
# idiom for a new field. Probe the platform once instead of relying on one
# invocation failing.
if stat -c '%a' . >/dev/null 2>&1; then _P_STAT_GNU=1; else _P_STAT_GNU=0; fi

p_stat_mode() {  # $1=file → octal mode, e.g. 644
  if [[ "$_P_STAT_GNU" == "1" ]]; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

p_stat_meta() {  # $1=file → "name size mtime", for change detection
  if [[ "$_P_STAT_GNU" == "1" ]]; then stat -c '%n %s %Y' "$1"; else stat -f '%N %z %m' "$1"; fi
}
```

- [ ] **Step 2: §6.1 — verify on this machine**

```bash
bash -c 'source tests/portability.sh; echo "GNU=$_P_STAT_GNU"; p_stat_mode tests/portability.sh; p_stat_meta tests/portability.sh'
bash tests/test-portability.sh
```

Expected: `GNU=1` on Linux (`0` on macOS), a three-digit mode, a `name size mtime` triple, and `0 failure(s)` from the portability test.

- [ ] **Step 3: §6.9 — exercise the dialect linter's "examined no files" guard**

Append to `tests/test-bash-dialect-lint.sh`, before its final tally:

```bash
# ── The "examined no files" guard, exercised ──────────────────────────────────
# bash-dialect-lint.sh:84-87 refuses to report success when it examined nothing
# — the same rule the bash -n CI step applies to itself. It had never run:
# replacing its `exit 1` with `exit 0` produced zero test failures. A scratch git
# repo whose only tracked file is not a .sh, with the linter copied in UNTRACKED,
# makes `git ls-files '*.sh'` empty for real.
empty_repo="$TMP/emptyrepo"; mkdir -p "$empty_repo/tests"
( cd "$empty_repo" \
    && { git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1; } \
    && printf 'placeholder\n' > README.md && git add README.md \
    && git -c user.email=t@example -c user.name=t commit -q -m init ) >/dev/null 2>&1
cp "$LINT" "$empty_repo/tests/bash-dialect-lint.sh"   # deliberately NOT git-added
# The floor is passed in so the copy needs no bash-floor.sh beside it (the
# linter skips its own source when both vars are already set).
if AI_CONTAINERS_BASH_FLOOR_MAJOR=5 AI_CONTAINERS_BASH_FLOOR_MINOR=1 \
     bash "$empty_repo/tests/bash-dialect-lint.sh" > "$TMP/empty.out" 2>&1; then
  fail "a lint run that examined no files reported SUCCESS"
elif grep -q 'examined no files' "$TMP/empty.out"; then
  pass "a lint run that examined no files fails, and says why"
else
  fail "the empty run failed, but not with the 'examined no files' message (got: $(head -2 "$TMP/empty.out" | tr '\n' ' '))"
fi
```

`$LINT` is already defined at `tests/test-bash-dialect-lint.sh:13`, and `$TMP`, `pass` and `fail` are defined in that file too.

- [ ] **Step 4: §6.9 — run it, then demonstrate it can fail**

```bash
bash tests/test-bash-dialect-lint.sh | tail -3
```
Expected: the new assertion PASSes and the file still reports `0 failure(s)`.

```bash
# Assertion read: the `fail "a lint run that examined no files reported
# SUCCESS"` line — reached via the linter's EXIT CODE.
cp tests/bash-dialect-lint.sh /tmp/d.bak
perl -0pi -e 's{^(  echo "ERROR: bash-dialect-lint\.sh examined no files" >&2\n)  exit 1$}{$1  exit 0}m' tests/bash-dialect-lint.sh
bash tests/test-bash-dialect-lint.sh | grep -E '^FAIL'
# Expected: FAIL: a lint run that examined no files reported SUCCESS
cp /tmp/d.bak tests/bash-dialect-lint.sh; rm -f /tmp/d.bak
```

- [ ] **Step 5: §6.4 — exercise `boot_case()`'s `command not found` branch**

`boot_case()` always writes a working `rvm` stub, so only the "No such file" source-failure branch is reached. Add a third parameter and a case. In `tests/test-rvm-reconcile.sh`, change the signature line and the `rvm` stub line:

```bash
boot_case() {   # $1=curl exit code  $2=the installer body the fake curl delivers
                # $3=1 to OMIT the rvm stub entirely (default 0), so the
                #    reconcile hits `rvm: command not found` rather than the
                #    "No such file" source failure. Both branches of that guard
                #    now have a case; only the second one ever did.
  local curl_rc="$1" payload="$2" no_rvm="${3:-0}"
```

and:

```bash
  if [[ "$no_rvm" != "1" ]]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/rvm"; chmod +x "$bin/rvm"
  fi
```

Then add a case beside the existing `boot_fail` one:

```bash
# rvm absent from PATH entirely → the reconcile must still report an
# rvm-attributable failure, not crash or silently succeed. This is the branch
# the fixture could not reach while it always stubbed rvm as a real binary.
boot_nocmd="$(boot_case 0 'echo installing' 1)"
grep -qE 'FAILED: rvm bootstrap|rvm: command not found|not found' <<<"$boot_nocmd" \
  && pass "a missing rvm binary is reported, not silently ignored" \
  || fail "a missing rvm binary produced no diagnostic (got: $boot_nocmd)"
```

- [ ] **Step 6: §6.4 — run it**

```bash
bash tests/test-rvm-reconcile.sh 2>&1 | tail -5
```

Expected: `0 failure(s)`, with the new assertion passing. If the new case fails, read `$boot_nocmd` before changing the assertion — the reconcile's actual message is the fact here, and the assertion should match what it really prints, not the reverse.

- [ ] **Step 7: §6.5 — align the scratch-copy list**

At `tests/test-parsers.sh:407-412`, add the four missing engine scripts to the `for f in ...` list:

```bash
for f in project-init.sh projects.conf.example sandbox-common.sh sandbox.sh build.sh \
         repo.sh group.sh entrypoint.sh tools-lib.sh install-tools.sh install-agent-skills.sh \
         bash-floor.sh shared-files.sh \
         rvm-reconcile.sh link-default-ruby.sh agent-tools-reconcile.sh link-agent-tools.sh \
         Dockerfile Dockerfile.seed .dockerignore sandbox.conf \
         refresh-ipset-allowlist.sh capture-blocked-traffic.sh capture-agent-destinations.sh; do
```

and extend the comment above it:

```bash
# A throwaway copy of the repo so project-init.sh's file copies / projects.conf
# writes never touch the real tree (mirrors tests/test-project-init.sh).
# This is a FIXTURE, not a second definition of shared-files.sh's list — the
# test drives project-init.sh in isolation and does not depend on the runtime
# reconcile scripts. It is kept aligned anyway: a fixture that silently diverges
# from the thing it fixtures stops resembling the case it claims to reproduce.
```

- [ ] **Step 8: §6.7 — cross-reference the three drift-prone comments**

Three comments explain the same `IT_SOURCE_ONLY` cut from different sides, and an edit to one should check the other two. They are:

| Site | What it explains |
|---|---|
| `tests/integration/run.sh:128-134` | why the CLI-option loop is skipped when sourced — `source` shares `$@` with its caller, so parsing would `exit 2` and kill the sourcing process |
| `tests/integration/run.sh:782-788` | why the early `return 0` sits where it does, and why an *executed* `run.sh` with the var set exits 2 rather than 0 |
| `tests/test-integration-runner.sh:35-41` | the consumer side — why sourcing with the var set is a safe way to reach `run.sh`'s functions |

Add one line to each, naming the other two:

```bash
# Same IT_SOURCE_ONLY cut is explained from the other two sides at
# tests/integration/run.sh:782 and tests/test-integration-runner.sh:35 — an edit
# to any of the three should check the other two have not drifted.
```

Adjust each line's two references so it names the *other* two, not itself. Verify the line numbers with `grep -n IT_SOURCE_ONLY` after editing, since adding these comments shifts them.

- [ ] **Step 9: Run the whole suite and lint**

```bash
bash tests/run-all.sh 2>&1 | tail -5
shellcheck -S warning -e SC1091 tests/portability.sh tests/test-bash-dialect-lint.sh tests/test-rvm-reconcile.sh tests/test-parsers.sh
bash tests/bash-dialect-lint.sh
```

Expected: whole suite green, both lints silent.

- [ ] **Step 10: Commit**

```bash
git add tests/portability.sh tests/test-bash-dialect-lint.sh tests/test-rvm-reconcile.sh tests/test-parsers.sh tests/integration/
git commit -m "$(cat <<'EOF'
fix: the last unexercised guard, the stat -f trap, and three fixture gaps

bash-dialect-lint.sh's "examined no files" refusal had never run: replacing its
exit 1 with exit 0 produced zero test failures. A scratch git repo whose only
tracked file is not a .sh, with the linter copied in untracked, makes the empty
pathspec real. That was the last of the family increment 4 found -- twelve
checks that could not fail, all now demonstrated failing.

GNU `stat -f` means --file-system, so `stat -c … || stat -f …` did not error on
GNU, it printed filesystem info to stdout. Probe the platform once instead.

boot_case() always stubbed rvm as a real binary, so only the "No such file"
branch of that guard was ever reached; a third parameter omits the stub.
test-parsers.sh's scratch-copy fixture was missing four engine scripts that
shared-files.sh names.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Documentation

**Files:**
- Modify: `AGENTS.md` (lines 311-312, 318, 322, 331-332, 373)
- Modify: `CHANGELOG.md`
- Modify: `README.md` (only if it names `tests.yml`'s jobs)

- [ ] **Step 1: Correct the execution-layers table**

In `AGENTS.md`'s layer table (~line 311), change the **Nightly** row's contract cell from `Runs **none** of tests.yml's hermetic checks — see below.` to:

```
plus the same hermetic checks the PR gate runs, via the shared `hermetic-checks.yml` workflow.
```

and the **PR** row's trigger cell from `.github/workflows/tests.yml` to `.github/workflows/tests.yml` → `hermetic-checks.yml`.

- [ ] **Step 2: Replace the two-invariant paragraph with one**

Replace the `Two invariants are actually enforced by tests/test-layer-containment.sh, not one clean three-layer chain` block and its two bullets, plus the following "Closing that gap … tracked as follow-up work, not implemented as part of this change" paragraph, with:

```markdown
The chain **`local ⊇ nightly ⊇ PR`** holds over both integration *cases* and
hermetic *checks*, and `tests/test-layer-containment.sh` enforces both
mechanically rather than leaving them as prose someone has to remember to keep
true. The checks leg was false until 2026-08-12 — `nightly.yml` scheduled
integration jobs only and ran none of `tests.yml`'s three — and was closed by
moving `suite`, `suite-floor` and `lint` into `.github/workflows/hermetic-checks.yml`,
a `workflow_call` workflow that both `tests.yml` and `nightly.yml` invoke. One
definition, so the two layers cannot drift; nightly's caller is gated on the
schedule event, because the `workflow_dispatch` inputs exist for mutation
demonstrations that break the tree on purpose.
```

- [ ] **Step 3: Rewrite the guard paragraph's tail**

In the `That guard checks by *effect*, not by grepping for a filename` paragraph (~line 322), replace the final sentence (`The same test also pins the **step count** of each tests.yml job against a recorded baseline … so the two cannot drift apart unnoticed.`) with:

```markdown
The effect fix held for the rows that existed, but nothing forced a row to
**exist**: three lists had to agree — `lib-verify-repo.sh`'s stubs, the `CHECKS`
table, and a per-job step-count baseline — and adding a fourth CI job produced
zero failures, because the job list was hardcoded as three names. All three are
now one registry, `tests/layer-checks.conf`, read by both consumers. The job
list is **derived from `hermetic-checks.yml`**, and every step must classify as
either a registry check (which forces a stub and a witness proving it also runs
locally) or a `setup` row stating why it is not one. That subsumes the step
count rather than dropping it: if every step classifies and every row finds its
step, the counts agree by construction. The floor→image map lives in
`bash-floor.sh` beside the floor it tests, so a floor raised without a matching
image yields empty and fails loudly instead of testing the wrong bash.
```

- [ ] **Step 4: Update the phase table's Mirrors column**

In the phase table (~lines 331-332), change both `tests.yml` references to `hermetic-checks.yml`:

- Phase 5: `` `hermetic-checks.yml` jobs `suite` + `suite-floor` ``
- Phase 7: `` `hermetic-checks.yml` job `lint` ``

Also update the shellcheck-gate paragraph (~line 373): `in CI (`tests.yml`'s `lint` job)` → `in CI (`hermetic-checks.yml`'s `lint` job)`.

- [ ] **Step 5: Add the CHANGELOG entry**

Add at the top of `CHANGELOG.md`'s unreleased section:

```markdown
### Layer-containment registry, and the nightly checks leg

- **One registry replaces three hand-maintained lists.** `tests/layer-checks.conf`
  declares each hermetic check once — its CI step, how it is stubbed, and the
  witness line proving it ran. `tests/lib-verify-repo.sh` builds stubs from it
  and `tests/test-layer-containment.sh` asserts witnesses from it, replacing two
  independent lists plus a per-job step-count baseline. Adding a fourth CI job
  produced **zero failures** before this change; the job list is now derived from
  the workflow file, and every step must classify as a registry check or as
  declared setup with a stated reason.
- **`nightly ⊇ PR` now holds over checks, not only over integration cases.**
  `suite`, `suite-floor` and `lint` moved verbatim into
  `.github/workflows/hermetic-checks.yml` (`on: workflow_call`), called by both
  `tests.yml` and `nightly.yml`. Measured at 2¼ runner-minutes; duplication, not
  cost, decided the shape. Nightly's caller is schedule-gated so mutation
  dispatches — which break the tree on purpose — do not bury their own signal.
- **The floor's test image is declared with the floor.** `bash-floor.sh` gains a
  map keyed on the declared floor, so raising it without extending the map yields
  the empty string and fails loudly rather than running the "floor" suite at the
  wrong bash. The floor stays **5.1**: at 5.2 the `suite-floor` job would run
  ubuntu:24.04's bash 5.2.21, identical to what `suite` already runs on
  ubuntu-latest, returning the floor to *asserted* rather than *tested*.
- **The last two guards that could not fail are now demonstrated failing** —
  `bash-dialect-lint.sh`'s "examined no files" refusal and `verify-on-host.sh`'s
  "bash -n parsed no files" branch. Both were correct; neither had ever run.
- **Nine further parked defects cleared**: `EXTRA_MOUNTS`/`PREVIEW_PORTS` glob
  expansion, the GNU `stat -f` fallback trap, `xargs` without `-r` double-counting
  one failure, Phase 7's silent success, `boot_case()`'s unreachable branch,
  `test-parsers.sh`'s divergent fixture list, and three stale or drift-prone
  comments.
```

- [ ] **Step 6: Close §6.11 explicitly**

Spec §6.11 (report-hygiene nits in increment 4's task reports) has **nothing to change in code** — the reports it concerns are historical artifacts in `.superpowers/sdd/2026-08-11-execution-layers-and-portability/`, already written and already reviewed. Do not edit them. Note in the CHANGELOG entry above that it is closed as recorded, so the "none dropped" rule has a visible resolution for all eleven items rather than ten and a silence.

- [ ] **Step 7: Check `README.md` and verify no stale references remain**

```bash
grep -rn "tests\.yml" README.md AGENTS.md | grep -v "hermetic-checks"
```

Expected: only references where `tests.yml` genuinely still is the right file (its `on:` triggers). Any line describing `suite`/`suite-floor`/`lint` as living in `tests.yml` must say `hermetic-checks.yml`.

- [ ] **Step 8: Commit**

```bash
git add AGENTS.md CHANGELOG.md README.md
git commit -m "$(cat <<'EOF'
docs: the containment invariant now holds over checks too

AGENTS.md recorded honestly that `nightly ⊇ PR` was true over integration cases
and FALSE over hermetic checks, and flagged closing it as a human decision. It
is closed: one reusable workflow, both callers, and the prose says so.

Also replaces the step-count description with the registry and step
classification that superseded it, and moves the floor->image mapping note to
bash-floor.sh where the map now lives.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Port to `mgd-ai-containers`

**Files:** the same set, in the sibling repo at `../mgd-ai-containers` (engine files under `base/`, `tests/` and `.github/` at the repo root).

- [ ] **Step 1: Derive the file list from the diff — never hand-write it**

```bash
git log --oneline main..HEAD
git diff --name-only main..HEAD | sort
```

Use that output as the port's file list. A hand-written list cannot validate its own omissions, which is how `group.sh` went missing from `project-init.sh` for months.

- [ ] **Step 2: Map each path to the mgd layout**

| Upstream | mgd |
|---|---|
| `bash-floor.sh`, `verify-on-host.sh`, `sandbox.sh` | `base/<same>` |
| `tests/**` | `tests/**` (unchanged) |
| `.github/workflows/**` | `.github/workflows/**` (unchanged) |
| `AGENTS.md`, `CHANGELOG.md`, `README.md` | same names, mgd's own copies |

`tests/test-layer-containment.sh`, `tests/lib-layer-checks.sh`, `tests/lib-verify-repo.sh` and `tests/layer-checks.conf` must be **byte-identical** across the two repos — they already carry the `ENGINE_DIR` fallback that makes one copy serve both layouts. Verify after copying:

```bash
for f in tests/test-layer-containment.sh tests/lib-layer-checks.sh \
         tests/lib-verify-repo.sh tests/layer-checks.conf \
         tests/test-layer-checks-parser.sh; do
  diff -q "$f" "../mgd-ai-containers/$f" && echo "IDENTICAL $f"
done
```

Expected: `IDENTICAL` for all five.

- [ ] **Step 3: Run the suite in mgd**

```bash
cd ../mgd-ai-containers && bash tests/run-all.sh 2>&1 | tail -5
```

Expected: `0 failure(s)`. If `test-layer-containment.sh` fails only there, the cause is a layout assumption — fix it in the shared file (upstream first, then re-copy) so byte-identity survives, exactly as `fd82f33` did for `check-sandbox-version.sh`.

- [ ] **Step 4: Commit in mgd and open both PRs**

```bash
cd ../mgd-ai-containers
git add -A && git commit -m "$(cat <<'EOF'
port: layer-containment registry and the nightly checks leg

Ports ai-containers' increment 4 follow-up. tests/layer-checks.conf,
lib-layer-checks.sh, lib-verify-repo.sh, test-layer-containment.sh and
test-layer-checks-parser.sh are byte-identical to upstream; the engine changes
land under base/ per this repo's layout.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
gh pr create --fill
cd - && gh pr create --fill
```

- [ ] **Step 5: Watch both PRs to green**

```bash
gh pr checks --watch
```

Expected in both: `Integration cases`, `hermetic / Shell test suite`, `hermetic / Shell test suite (bash floor)`, `hermetic / Shell lint` all SUCCESS. The `hermetic / ` prefix is new and expected — the reusable workflow nests the job names. Neither repo has branch protection keyed on the old names (verified 2026-08-12), so nothing needs reconfiguring.

---

## Local verification before merge

After Task 10's PRs are green, run the local layer — it is the only layer that covers macOS, BSD userland and Colima:

```bash
bash ./verify-on-host.sh
```

Expected: `RESULT: PASSED`. Phase 5 exercises the new floor-image lookup against a real container; Phase 7 exercises the `xargs -r` probe and the new evidence lines.
