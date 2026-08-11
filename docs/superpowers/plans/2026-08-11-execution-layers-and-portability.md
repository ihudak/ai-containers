# Execution Layers and Host Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the suite three named execution layers with `local ⊇ nightly ⊇ PR` enforced by a test, raise the bash floor to 5.1 and enforce it where it is claimed, and make the hermetic suite pass on macOS.

**Architecture:** `verify-on-host.sh` gains Phases 5 and 7, each mirroring one whole CI job, so the local layer becomes a genuine superset of the PR gate. A new `bash-floor.sh` states the floor once and is sourced by every host entry point. A new `run.sh --dry-run` makes a layer's selection inspectable, which is what lets `tests/test-layer-containment.sh` check containment by set comparison rather than by reimplementing selection logic.

**Tech Stack:** bash (floor 5.1), GitHub Actions, shellcheck, the project's `tests/run-all.sh` harness.

## Global Constraints

- **Bash floor is 5.1.** Stated once in `bash-floor.sh` as `AI_CONTAINERS_BASH_FLOOR_MAJOR=5` / `AI_CONTAINERS_BASH_FLOOR_MINOR=1`. Never hardcode the floor anywhere else — read it from there.
- **New phase numbers are 5 and 7 only. Never 1, 2 or 3.** Those are burned identifiers; reusing them re-validates a stale `PHASES="1 2 3"` and destroys the increment-3 guard. Phase 6 is reserved for increment 5.
- **Every new guard must be demonstrated failing** by breaking the mechanism it checks — never by asserting the expected answer. A guard never observed failing is not accepted.
- **No churn of existing bash-3.2-style workarounds.** Space-padded membership tests and `"${arr[@]+"${arr[@]}"}"` stay. Only comments that state a now-false constraint get corrected.
- **`--list` keeps its documented whole-corpus catalogue behaviour.** The preview is a new `--dry-run` flag.
- **Every test file must print `PASS:`/`FAIL:` lines and exit non-zero on failure**, matching `tests/run-all.sh`'s verdict rule.
- **Historical plan documents under `docs/superpowers/plans/` are not edited.** They record constraints that applied when written.
- Ported to `Dynatrace-Internal/mgd-ai-containers` with the file list **derived from `git diff --name-only`**, never hand-written.

## File Structure

| File | Responsibility |
|---|---|
| `bash-floor.sh` *(new)* | Declares the floor once; exits with a clear message below it. Sourced, never executed. |
| `sandbox-common.sh` | Sources `bash-floor.sh` instead of inlining the check. |
| `migrate-runme.sh`, `project-init.sh`, `sync-to-projects.sh`, `bump-sandbox-version.sh`, `check-sandbox-version.sh`, `verify-on-host.sh` | Source `bash-floor.sh` directly. |
| `tests/bash-dialect-lint.sh` *(new)* | Rejects constructs newer than the floor. Reads the floor from `bash-floor.sh`. |
| `tests/portability.sh` *(new)* | `p_stat_mode`, `p_sha1`, `p_md5` — GNU/BSD-neutral helpers for tests. |
| `tests/integration/run.sh` | Adds `--dry-run`. |
| `verify-on-host.sh` | Adds Phases 5 and 7; `VALID_PHASES="0 4 5 7"`; default `PHASES` becomes `4 5 7`. |
| `.github/workflows/tests.yml` | Adds the `suite-floor` job (`ubuntu:22.04`, bash 5.1) and the dialect linter step in `lint`. |
| `tests/test-bash-floor.sh` *(new)* | Every host entry point reaches the floor guard. |
| `tests/test-layer-containment.sh` *(new)* | `local ⊇ nightly ⊇ PR`, plus the step-count ratchet. |
| `tests/test-verify-exit-code.sh` | Updated for the new default and phases. |

---

### Task 1: `bash-floor.sh` and the entry-point guards

**Files:**
- Create: `bash-floor.sh`
- Create: `tests/test-bash-floor.sh`
- Modify: `sandbox-common.sh:18-24`
- Modify: `migrate-runme.sh`, `project-init.sh`, `sync-to-projects.sh`, `bump-sandbox-version.sh`, `check-sandbox-version.sh`, `verify-on-host.sh` (add the source line after `set -…`)
- Modify: `README.md:38`

**Interfaces:**
- Produces: `bash-floor.sh` exporting `AI_CONTAINERS_BASH_FLOOR_MAJOR=5`, `AI_CONTAINERS_BASH_FLOOR_MINOR=1`, and guard variable `_AI_CONTAINERS_BASH_FLOOR_SOURCED=1`. Consumed by Tasks 2 and 6.

- [ ] **Step 1: Write the failing test**

Create `tests/test-bash-floor.sh`. The entry-point list is **derived**, never hand-written — a hand-written list validates only what someone remembered:

```bash
#!/usr/bin/env bash
# Every host entry point must reach the bash floor guard. The list is DERIVED
# from the repo, not hand-written: a hand-written list can only ever validate
# the files someone remembered to add to it, which is how the mgd port shipped
# with two files missing from its own byte-identity gate.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -f "$REPO_DIR/bash-floor.sh" ]] \
  && pass "bash-floor.sh exists" || fail "bash-floor.sh exists"

# The floor is stated exactly once. A second literal somewhere else is how the
# 4.3-vs-4.4-vs-3.2 contradiction happened in the first place.
floor_defs="$(grep -rlE 'AI_CONTAINERS_BASH_FLOOR_(MAJOR|MINOR)=' "$REPO_DIR" \
  --include='*.sh' 2>/dev/null | grep -v '/tests/' | wc -l | tr -d ' ')"
[[ "$floor_defs" == "1" ]] \
  && pass "the floor is defined in exactly one file" \
  || fail "the floor is defined in $floor_defs files — it must be exactly one"

# Derived entry-point list: executable *.sh at the repo root that are RUN, not
# sourced. In-container scripts are excluded by name because they never execute
# on a host at all.
in_container="entrypoint.sh rvm-reconcile.sh agent-tools-reconcile.sh
  link-agent-tools.sh link-default-ruby.sh install-tools.sh
  refresh-ipset-allowlist.sh capture-blocked-traffic.sh
  install-agent-skills.sh capture-agent-destinations.sh bash-floor.sh
  sandbox-common.sh tools-lib.sh"
n_checked=0
while IFS= read -r f; do
  base="$(basename "$f")"
  case " $in_container " in *" $base "*) continue ;; esac
  n_checked=$((n_checked+1))
  if grep -qE '^(source|\.) .*(bash-floor|sandbox-common)\.sh' "$REPO_DIR/$base"; then
    pass "$base reaches the bash floor guard"
  else
    fail "$base reaches the bash floor guard — it can run under an unsupported bash"
  fi
done < <(cd "$REPO_DIR" && git ls-files '*.sh' | grep -v '/')

# A derivation that found nothing must not report success.
[[ "$n_checked" -gt 0 ]] \
  && pass "checked $n_checked entry point(s)" \
  || fail "checked 0 entry points — the derivation matched nothing"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-bash-floor.sh`
Expected: FAIL — `bash-floor.sh exists`, plus one failure per unguarded entry point (6 of them).

- [ ] **Step 3: Create `bash-floor.sh`**

```bash
#!/usr/bin/env bash
# bash-floor.sh — the single declaration of this project's minimum bash version.
#
# SOURCED, never executed. Every host entry point sources this (directly, or via
# sandbox-common.sh) so an unsupported bash produces one clear message instead of
# a cryptic `local: -A: invalid option` somewhere in the middle of a run.
#
# 5.1 rather than the 4.3 this guard enforced before increment 4: macOS needs a
# Homebrew bash at ANY floor above 3.2, so the raise costs macOS users nothing,
# and every current Linux target clears it (Ubuntu 22.04+, Debian 11+,
# RHEL/Rocky 9+, and the container base ubuntu:24.04 at 5.2.21). The only
# realistic exclusion is a RHEL 8 workstation, and only for host scripts.
#
# THE FLOOR IS DECLARED HERE AND NOWHERE ELSE. tests/test-bash-floor.sh fails if
# a second definition appears; tests/bash-dialect-lint.sh reads these values to
# decide which constructs are permitted.

if [[ -n "${_AI_CONTAINERS_BASH_FLOOR_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_AI_CONTAINERS_BASH_FLOOR_SOURCED=1

AI_CONTAINERS_BASH_FLOOR_MAJOR=5
AI_CONTAINERS_BASH_FLOOR_MINOR=1

if (( BASH_VERSINFO[0] < AI_CONTAINERS_BASH_FLOOR_MAJOR \
   || (BASH_VERSINFO[0] == AI_CONTAINERS_BASH_FLOOR_MAJOR \
       && BASH_VERSINFO[1] < AI_CONTAINERS_BASH_FLOOR_MINOR) )); then
  echo "ERROR: bash >= ${AI_CONTAINERS_BASH_FLOOR_MAJOR}.${AI_CONTAINERS_BASH_FLOOR_MINOR} is required (running ${BASH_VERSION:-unknown})." >&2
  echo "       On macOS: brew install bash, then run the scripts with the newer bash." >&2
  exit 1
fi
```

- [ ] **Step 4: Replace the inlined guard in `sandbox-common.sh`**

Replace lines 18-24 (`# Require bash >= 4.3 …` through the closing `fi`) with:

```bash
# The bash floor is declared once, in bash-floor.sh, and sourced here so the
# three entry points that source this library inherit it.
# shellcheck source=bash-floor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-floor.sh"
```

- [ ] **Step 5: Add the source line to the six unguarded entry points**

In each of `migrate-runme.sh`, `project-init.sh`, `sync-to-projects.sh`, `bump-sandbox-version.sh`, `check-sandbox-version.sh`, `verify-on-host.sh`, immediately after the existing `set -…` line:

```bash
# shellcheck source=bash-floor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-floor.sh"
```

For `verify-on-host.sh` the engine directory is `$REPO`, which is resolved later
in the file — put the source line after `REPO` is resolved and use
`source "$REPO/bash-floor.sh"`, so the mgd `base/` layout keeps working.

- [ ] **Step 6: Correct `README.md:38`**

Change `**Bash ≥ 4.4** on the host` to `**Bash ≥ 5.1** on the host`, and update the sentence to read: `Linux distributions from Ubuntu 22.04 / Debian 11 / RHEL 9 onward ship this. macOS ships bash 3.2 — install a newer one via `brew install bash`.`

- [ ] **Step 7: Add the `suite-floor` CI job, so the floor is tested rather than asserted**

A declared floor no layer exercises is the defect this increment removes — the
3.2 claim survived for months because nothing ran it. CI's `ubuntu-latest` is
bash 5.2 **and is a moving target**: when GitHub rolls it to 26.04 the tested
version silently becomes 5.3.

Add to `.github/workflows/tests.yml`, as a sibling of `suite`:

```yaml
  suite-floor:
    name: Shell test suite (bash floor)
    runs-on: ubuntu-latest
    # ubuntu:22.04 ships bash 5.1.16 — the declared floor — with GNU coreutils.
    # `suite` above runs on whatever bash ubuntu-latest happens to ship, which
    # drifts upward with the runner image; this job pins the CLAIM. Raising the
    # floor means changing this image and bash-floor.sh together.
    container: ubuntu:22.04

    steps:
      # BEFORE checkout: actions/checkout needs git inside the container, and
      # without it silently falls back to a REST download with no .git — which
      # tests/test-mutations.sh detects and fails on (it needs a git work tree
      # for `git apply --check`). rsync is needed by the project-init tests.
      - name: Install git and rsync
        run: apt-get update -qq && apt-get install -y -qq git rsync ca-certificates

      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - name: Show bash version
        run: bash --version | head -1

      - name: Run tests at the declared floor
        run: ./tests/run-all.sh
```

- [ ] **Step 8: Verify the job would actually run at 5.1**

Reproduce it locally to confirm the image ships the expected bash and the suite
passes there — a job that silently runs the wrong version proves nothing:

```bash
docker run --rm -v "$PWD:/w" -w /w ubuntu:22.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq git rsync >/dev/null && \
   bash --version | head -1 && ./tests/run-all.sh'
```

Expected: `GNU bash, version 5.1.16(1)-release`, and the suite green. Record the
version line in the commit message.

- [ ] **Step 9: Run the test and the suite**

Run: `bash tests/test-bash-floor.sh && bash tests/run-all.sh`
Expected: `tests/test-bash-floor.sh` PASSes; the full suite stays green.

- [ ] **Step 10: Demonstrate the guard failing**

Remove the `source` line from `migrate-runme.sh`, run `bash tests/test-bash-floor.sh`, confirm it FAILs naming `migrate-runme.sh`, then restore the line. Record the observed output in the commit message.

- [ ] **Step 11: Commit**

```bash
git add bash-floor.sh sandbox-common.sh migrate-runme.sh project-init.sh \
        sync-to-projects.sh bump-sandbox-version.sh check-sandbox-version.sh \
        verify-on-host.sh README.md tests/test-bash-floor.sh \
        .github/workflows/tests.yml
git commit -m "feat: declare the bash floor once, at 5.1, and test it rather than assert it"
```

---

### Task 2: the bash dialect linter

**Files:**
- Create: `tests/bash-dialect-lint.sh`
- Create: `tests/test-bash-dialect-lint.sh`
- Modify: `.github/workflows/tests.yml` (add a step to the `lint` job)

**Interfaces:**
- Consumes: `bash-floor.sh`'s `AI_CONTAINERS_BASH_FLOOR_MAJOR`/`MINOR` from Task 1.
- Produces: `tests/bash-dialect-lint.sh`, exit 0 clean / 1 on violation. Consumed by Task 5 (Phase 7).

- [ ] **Step 1: Write the failing test**

Create `tests/test-bash-dialect-lint.sh`:

```bash
#!/usr/bin/env bash
# The dialect linter must reject constructs newer than the declared floor.
# Vectors run against throwaway files, never the real tree.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$REPO_DIR/tests/bash-dialect-lint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

bash -n "$LINT" && pass "bash-dialect-lint.sh bash -n" || fail "bash-dialect-lint.sh bash -n"

# $1=label $2=file content $3=expected rc
vector() {
  printf '%s\n' "$2" > "$TMP/v.sh"
  bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -eq "$3" ]]; then pass "$1"; else fail "$1 — expected rc $3, got $rc"; fi
}

vector "plain script passes"            'printf "%s\n" "$1"'                 0
vector "5.3 value substitution rejected" 'x=${ printf hi; }'                  1
vector "5.3 BASH_MONOSECONDS rejected"   'echo "$BASH_MONOSECONDS"'           1
vector "5.3 GLOBSORT rejected"           'GLOBSORT=name'                      1
vector "5.2 globskipdots rejected"       'shopt -s globskipdots'              1
vector "5.1 SRANDOM allowed (at floor)"  'echo "$SRANDOM"'                    0
vector "5.0 EPOCHREALTIME allowed"       'echo "$EPOCHREALTIME"'              0
vector "4.4 \${var@Q} allowed"           'echo "${x@Q}"'                      0
vector "4.3 local -n allowed"            'f() { local -n r=$1; }'             0
# A construct inside a comment is not a use.
vector "commented construct allowed"     '# x=${ printf hi; }'                0

# The linter must read the floor rather than hardcoding it: with the floor
# lowered to 4.4, a 5.0 construct becomes a violation.
printf '%s\n' 'echo "$EPOCHREALTIME"' > "$TMP/v.sh"
if AI_CONTAINERS_BASH_FLOOR_MAJOR=4 AI_CONTAINERS_BASH_FLOOR_MINOR=4 \
     bash "$LINT" "$TMP/v.sh" >/dev/null 2>&1; then
  fail "the linter reads the floor — a 5.0 construct passed at a 4.4 floor"
else
  pass "the linter reads the floor rather than hardcoding it"
fi

# Run against the real tree: it must be clean today.
bash "$LINT" >/dev/null 2>&1 \
  && pass "the repository is clean at the current floor" \
  || fail "the repository is clean at the current floor"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-bash-dialect-lint.sh`
Expected: FAIL — `bash-dialect-lint.sh bash -n` (the file does not exist yet).

- [ ] **Step 3: Write the linter**

Create `tests/bash-dialect-lint.sh`:

```bash
#!/usr/bin/env bash
# bash-dialect-lint.sh — reject bash constructs newer than the declared floor.
#
# WHY THIS EXISTS: the three bash versions in play are all different. The
# container and CI run 5.2, a developer's Mac runs 5.3, and the floor is 5.1.
# Nothing else compares them, so a `${ cmd; }` written comfortably on the host
# would sail through review and CI and die at container start.
#
# Usage: bash-dialect-lint.sh [file…]   (no args = every tracked *.sh)
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bash-floor.sh
[[ -n "${AI_CONTAINERS_BASH_FLOOR_MAJOR:-}" ]] || source "$REPO_DIR/bash-floor.sh"
FLOOR_MAJOR="$AI_CONTAINERS_BASH_FLOOR_MAJOR"
FLOOR_MINOR="$AI_CONTAINERS_BASH_FLOOR_MINOR"

# One row per construct: <major> <minor> <extended-regex> <description>
# Only constructs ABOVE the floor are reported, so raising or lowering the floor
# in bash-floor.sh changes what this permits with no edit here.
RULES='
5 3|\$\{[[:space:]]|${ command; } value substitution
5 3|BASH_MONOSECONDS|BASH_MONOSECONDS
5 3|BASH_TRAPSIG|BASH_TRAPSIG
5 3|GLOBSORT|GLOBSORT
5 2|shopt[[:space:]]+-[su][[:space:]]+globskipdots|shopt globskipdots
5 2|shopt[[:space:]]+-[su][[:space:]]+noexpand_translation|shopt noexpand_translation
5 2|shopt[[:space:]]+-[su][[:space:]]+varredir_close|shopt varredir_close
5 1|SRANDOM|SRANDOM
5 1|\$\{[A-Za-z_][A-Za-z0-9_]*@[UuLKk]\}|${var@U/@u/@L/@K/@k}
5 0|EPOCHSECONDS|EPOCHSECONDS
5 0|EPOCHREALTIME|EPOCHREALTIME
5 0|BASH_ARGV0|BASH_ARGV0
4 4|\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAa]\}|${var@Q/@E/@P/@A/@a}
'

files=("$@")
if [[ "${#files[@]}" -eq 0 ]]; then
  while IFS= read -r f; do files+=("$REPO_DIR/$f"); done \
    < <(cd "$REPO_DIR" && git ls-files '*.sh')
fi
# A lint run that examined nothing must not report success — the same rule the
# `bash -n over every script` CI step already applies to itself.
if [[ "${#files[@]}" -eq 0 ]]; then
  echo "ERROR: bash-dialect-lint.sh examined no files" >&2
  exit 1
fi

rc=0
while IFS= read -r rule; do
  [[ -n "$rule" ]] || continue
  ver="${rule%%|*}"; rest="${rule#*|}"
  re="${rest%%|*}"; desc="${rest#*|}"
  rmaj="${ver%% *}"; rmin="${ver##* }"
  # Permitted at or below the floor.
  (( rmaj < FLOOR_MAJOR || (rmaj == FLOOR_MAJOR && rmin <= FLOOR_MINOR) )) && continue
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    # Strip comments before matching: a construct named in a comment is not a use.
    if sed 's/[[:space:]]*#.*$//' "$f" | grep -qE "$re"; then
      printf '%s: uses %s (bash %s.%s) — floor is %s.%s\n' \
        "${f#"$REPO_DIR"/}" "$desc" "$rmaj" "$rmin" "$FLOOR_MAJOR" "$FLOOR_MINOR" >&2
      rc=1
    fi
  done
done <<< "$RULES"
exit "$rc"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-bash-dialect-lint.sh`
Expected: PASS on every vector, including "the repository is clean at the current floor".

- [ ] **Step 5: Wire it into CI**

In `.github/workflows/tests.yml`, in the `lint` job, add after the `bash -n over every script` step:

```yaml
      # The floor is 5.1 while CI runs 5.2 and a developer's Mac runs 5.3.
      # Nothing else compares them, so this is the only thing standing between
      # a comfortable ${ cmd; } on the host and a container that will not start.
      - name: bash dialect (nothing newer than the declared floor)
        run: ./tests/bash-dialect-lint.sh
```

- [ ] **Step 6: Demonstrate the linter failing**

Append `x=${ printf hi; }` to a scratch copy of a real script, run
`./tests/bash-dialect-lint.sh <that file>`, confirm exit 1 with the construct
named, and delete the scratch file. Record the output in the commit message.

- [ ] **Step 7: Commit**

```bash
git add tests/bash-dialect-lint.sh tests/test-bash-dialect-lint.sh .github/workflows/tests.yml
git commit -m "feat: reject bash constructs newer than the declared floor"
```

---

### Task 3: portability helpers and the four known macOS defects

**Files:**
- Create: `tests/portability.sh`
- Modify: `tests/test-allowlists.sh:55`
- Modify: `tests/test-sync-project.sh:34,52,254,408`
- Modify: `tests/test-launcher-migration.sh:33,35,47,49`
- Modify: `tests/test-open-mode.sh` (comment only)

**Interfaces:**
- Produces: `tests/portability.sh` defining `p_stat_mode <file>` (octal mode), `p_stat_meta <file>` (name size mtime), `p_sha1 <file>`, `p_md5 <file>`. Consumed by Task 4's macOS run.

- [ ] **Step 1: Write the failing test**

Create `tests/test-portability.sh`:

```bash
#!/usr/bin/env bash
# The GNU/BSD-neutral helpers must agree with the platform's own tools.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

printf 'content\n' > "$TMP/f"; chmod 644 "$TMP/f"

[[ "$(p_stat_mode "$TMP/f")" == "644" ]] \
  && pass "p_stat_mode reports the octal mode" \
  || fail "p_stat_mode reports the octal mode — got '$(p_stat_mode "$TMP/f")'"

chmod 755 "$TMP/f"
[[ "$(p_stat_mode "$TMP/f")" == "755" ]] \
  && pass "p_stat_mode tracks a mode change" \
  || fail "p_stat_mode tracks a mode change — got '$(p_stat_mode "$TMP/f")'"

# The digest helpers must be stable and must differ for differing content.
a="$(p_sha1 "$TMP/f")"; b="$(p_sha1 "$TMP/f")"
[[ -n "$a" && "$a" == "$b" ]] \
  && pass "p_sha1 is non-empty and stable" || fail "p_sha1 is non-empty and stable"
printf 'other\n' > "$TMP/g"
[[ "$(p_sha1 "$TMP/f")" != "$(p_sha1 "$TMP/g")" ]] \
  && pass "p_sha1 distinguishes different content" \
  || fail "p_sha1 distinguishes different content"

m="$(p_md5 "$TMP/f")"
[[ -n "$m" && "$m" == "$(p_md5 "$TMP/f")" ]] \
  && pass "p_md5 is non-empty and stable" || fail "p_md5 is non-empty and stable"
[[ "$(p_md5 "$TMP/f")" != "$(p_md5 "$TMP/g")" ]] \
  && pass "p_md5 distinguishes different content" \
  || fail "p_md5 distinguishes different content"

meta="$(p_stat_meta "$TMP/f")"
[[ -n "$meta" ]] && pass "p_stat_meta returns something" || fail "p_stat_meta returns something"

# No helper may leave the caller with an empty answer on THIS platform: an empty
# string compares equal to another empty string, which is how a portability bug
# turns into a test that passes by accident.
for h in p_stat_mode p_sha1 p_md5 p_stat_meta; do
  if [[ -n "$($h "$TMP/f")" ]]; then pass "$h is non-empty on this platform"
  else fail "$h returned empty — comparisons using it would pass vacuously"; fi
done

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-portability.sh`
Expected: FAIL — `tests/portability.sh` does not exist, so `source` errors.

- [ ] **Step 3: Write the helpers**

Create `tests/portability.sh`:

```bash
#!/usr/bin/env bash
# portability.sh — GNU/BSD-neutral helpers for the hermetic suite.
#
# SOURCED by tests, never executed. The suite runs on ubuntu CI (GNU coreutils)
# and, from increment 4 onward, on a developer's macOS host (BSD userland) via
# verify-on-host.sh Phase 5. `stat -c`, `sha1sum` and `md5sum` do not exist on
# macOS; `stat -f`, `shasum` and `md5` do.
#
# Every helper prints to stdout and must NEVER print empty on a supported
# platform: an empty string compares equal to another empty string, which turns
# a portability failure into a test that passes vacuously.

p_stat_mode() {  # $1=file → octal mode, e.g. 644
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

p_stat_meta() {  # $1=file → "name size mtime", for change detection
  stat -c '%n %s %Y' "$1" 2>/dev/null || stat -f '%N %z %m' "$1" 2>/dev/null
}

p_sha1() {  # $1=file → hex digest only
  if command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | cut -d' ' -f1
  else shasum -a 1 "$1" | cut -d' ' -f1; fi
}

p_md5() {  # $1=file → hex digest only
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
  else md5 -q "$1"; fi
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-portability.sh`
Expected: PASS on every assertion.

- [ ] **Step 5: Convert the four defect sites**

In each file, add the source line after `REPO_DIR` is resolved:

```bash
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
```

Then replace:

| File | From | To |
|---|---|---|
| `tests/test-allowlists.sh:55` | `stat -c '%n %s %Y' "$REPO_DIR/$f"` | `p_stat_meta "$REPO_DIR/$f"` |
| `tests/test-sync-project.sh:34,254,408` | `md5sum "$REAL_PROJECTS_CONF" \| cut -d' ' -f1` | `p_md5 "$REAL_PROJECTS_CONF"` |
| `tests/test-launcher-migration.sh:33,35,47,49` | `sha1sum "$dest1/runme.sh"` | `p_sha1 "$dest1/runme.sh"` |

`tests/test-sync-project.sh:52` needs more than a substitution, because
`find -exec` cannot call a shell function. Replace:

```bash
        find "$p/.ai-containers" -exec stat -c '%n %s %Y' {} \; 2>/dev/null | sort >> "$out"
```

with:

```bash
        # p_stat_meta is a shell function, so it cannot be reached by -exec.
        while IFS= read -r _entry; do
          p_stat_meta "$_entry"
        done < <(find "$p/.ai-containers" 2>/dev/null) | sort >> "$out"
```

The output shape is unchanged — one `name size mtime` line per entry, sorted —
so the surrounding before/after comparison keeps working untouched.

`tests/test-launcher-migration.sh` resolves `SCRIPT_DIR`, not `REPO_DIR` — source
`"$SCRIPT_DIR/tests/portability.sh"` there.

- [ ] **Step 6: Correct the now-false comment in `tests/test-open-mode.sh`**

The comment reads *"a bare expansion aborts under `set -u` on bash 4.3"*. At a
5.1 floor that is no longer a supported configuration. Replace the rationale
sentence with: `The guarded form is retained as belt-and-braces: it is correct at
any version, and rewriting working code for a version we no longer support would
be churn. The floor (bash-floor.sh) is 5.1, where a bare expansion is safe.`
Leave the assertion itself untouched.

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run-all.sh`
Expected: every test still passes on Linux — the helpers take the GNU branch here.

- [ ] **Step 8: Demonstrate the non-empty assertions can fail**

The riskiest thing about these helpers is that a broken one returns an empty
string, and `[[ "" == "" ]]` is true — a portability bug that makes tests pass
*more* readily. `tests/test-portability.sh` asserts non-emptiness for exactly
that reason, so prove those assertions can fail.

Temporarily replace `p_md5`'s body with `:` (returns nothing, exit 0), run
`bash tests/test-portability.sh`, and confirm **both** `p_md5 is non-empty and
stable` and `p_md5 is non-empty on this platform` FAIL. Then restore the body.

Record the observed output in the commit message. Do not substitute a
demonstration that breaks the *test* instead of the *helper* — breaking the
mechanism under test is the whole point.

- [ ] **Step 9: Commit**

```bash
git add tests/portability.sh tests/test-portability.sh tests/test-allowlists.sh \
        tests/test-sync-project.sh tests/test-launcher-migration.sh tests/test-open-mode.sh
git commit -m "fix: GNU/BSD-neutral helpers for the four macOS-breaking test sites"
```

---

### Task 4: `run.sh --dry-run`

**Files:**
- Modify: `tests/integration/run.sh` (option parsing ~line 157; selection block ~line 885-900; usage text ~line 34-40)
- Modify: `tests/test-integration-runner.sh` (add vectors)

**Interfaces:**
- Produces: `run.sh --dry-run` printing one selected case basename per line, exit 0; exit non-zero when the selection is empty. Consumed by Task 6.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-integration-runner.sh` (it defines `pass`/`fail`/`check`
and `$RUN` already):

```bash
# ── --dry-run previews a selection; --list deliberately does not ──────────────
# The containment guard (tests/test-layer-containment.sh) compares one layer's
# selection against another's. It asks run.sh what it WOULD select rather than
# reimplementing the selection logic, because a second copy would be right in
# this repo and quietly wrong in the fork.
all_n="$(IT_CASES_DIR="$CASES" bash "$RUN" --list 2>/dev/null | grep -cE '^[0-9]{3}-')"
dry_n="$(IT_CASES_DIR="$CASES" bash "$RUN" --dry-run --tags fast 2>/dev/null | grep -cE '^[0-9]{3}-')"
if [[ "$dry_n" -gt 0 && "$dry_n" -lt "$all_n" ]]; then
  pass "--dry-run --tags fast selects a proper subset ($dry_n of $all_n)"
else
  fail "--dry-run --tags fast selects a proper subset — got $dry_n of $all_n"
fi

# --list must NOT have changed: its whole-corpus contract is documented in usage().
list_tagged="$(IT_CASES_DIR="$CASES" bash "$RUN" --list --tags fast 2>/dev/null | grep -cE '^[0-9]{3}-')"
check "--list still ignores --tags (documented contract)" "$all_n" "$list_tagged"

# An empty selection is fatal, exactly as in a real run.
if IT_CASES_DIR="$CASES" bash "$RUN" --dry-run --tags no-such-tag >/dev/null 2>&1; then
  fail "--dry-run with an empty selection exits non-zero"
else
  pass "--dry-run with an empty selection exits non-zero"
fi

# --dry-run must not build an image or start a container: with a docker that
# fails on every call, it must still succeed.
if PATH="$DH_BIN_FAIL:$PATH" IT_CASES_DIR="$CASES" bash "$RUN" --dry-run --tags fast >/dev/null 2>&1; then
  pass "--dry-run touches no docker"
else
  fail "--dry-run touches no docker — it invoked the daemon"
fi
```

If `$DH_BIN_FAIL` is not already defined in that file, use the existing
always-failing fake-docker directory it builds (`dh-bin-fail`, referenced near
line 389) and assign it to `DH_BIN_FAIL` beside its creation.

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-integration-runner.sh 2>&1 | grep -E '^(FAIL|PASS).*dry-run'`
Expected: every `--dry-run` assertion FAILs — the flag is unrecognised.

- [ ] **Step 3: Add the flag**

In the option-parsing `case` (beside `--list)` at line 157):

```bash
    --dry-run)  do_dry_run=1; shift ;;
```

Declare `do_dry_run=0` beside `do_list=0` on line 64.

- [ ] **Step 4: Print the selection and exit**

Immediately **after** the selection block completes (after `selected` and the
variant narrowing are final, and after the existing zero-selection fatal check
so an empty `--dry-run` inherits it), insert:

```bash
if [[ "$do_dry_run" -eq 1 ]]; then
  # The selection, and nothing else: no image build, no container, no daemon
  # call. This is what tests/test-layer-containment.sh compares between layers.
  for f in $selected; do basename "$f"; done
  exit 0
fi
```

- [ ] **Step 5: Document it in `usage()`**

Add beneath the `--list` line:

```
  --dry-run          print the cases the current selection WOULD run, one per
                      line, and exit — no image build, no container. Unlike
                      --list, it honours --tags/--exclude/--cases/--variant.
```

and leave the existing `--list` sentence about ignoring selection flags exactly
as it is — it is still true and now contrasts with `--dry-run`.

- [ ] **Step 6: Run the tests**

Run: `bash tests/run-all.sh integration-runner`
Expected: PASS, including the four new assertions.

- [ ] **Step 7: Demonstrate the assertion can fail**

Temporarily make `--dry-run` print `$(all_cases)` instead of `$selected`, confirm
`--dry-run --tags fast selects a proper subset` FAILs (it will report the full
corpus count on both sides), then revert. Record the output in the commit message.

> **Corrected 2026-08-11.** This step originally said to swap in
> `$selected_pre_variant`. That would have demonstrated **nothing**: that variable
> is populated *after* `--tags` filtering (`run.sh:945`), so the "break" changes
> no observable behaviour and the assertion passes — recording a successful
> demonstration of a guard nobody tested. Caught only because the implementer was
> required to actually run it. The break must bypass the filter entirely.

- [ ] **Step 8: Commit**

```bash
git add tests/integration/run.sh tests/test-integration-runner.sh
git commit -m "feat: run.sh --dry-run previews a selection without running it"
```

---

### Task 5: `verify-on-host.sh` Phases 5 and 7

**Files:**
- Modify: `verify-on-host.sh` (`PHASES` default line 90; `VALID_PHASES` line 102; new phase blocks before the Phase 4 block at line 129; header comment lines 14-30)
- Modify: `tests/test-verify-exit-code.sh:119-160`

**Interfaces:**
- Consumes: `tests/bash-dialect-lint.sh` (Task 2).
- Produces: phases 5 and 7 recording through `phase_fail`; `VALID_PHASES="0 4 5 7"`; default `PHASES="4 5 7"`. Consumed by Task 6.

- [ ] **Step 1: Update the existing guard test first**

`tests/test-verify-exit-code.sh:155-156` pins `${PHASES:-4}`. Change that
assertion to expect the new default and add coverage for the new phases:

```bash
# The default selection must name every phase this script has. A local layer
# nobody selects is not a local layer.
grep -qE 'PHASES="\$\{PHASES:-4 5 7\}"' "$VERIFY" \
  && pass "PHASES defaults to every phase (4 5 7)" \
  || fail "PHASES defaults to every phase (4 5 7)"
grep -qE '^VALID_PHASES="0 4 5 7"' "$VERIFY" \
  && pass "VALID_PHASES names 0 4 5 7" || fail "VALID_PHASES names 0 4 5 7"

# Every phase must record through phase_fail — the founding defect was a phase
# that failed while the script exited 0.
for p in 5 7; do
  if awk -v p="$p" '$0 ~ "PHASE "p" —" {g=1} g && /phase_fail '"$p"'/ {found=1} END{exit !found}' "$VERIFY"; then
    pass "phase $p records through phase_fail"
  else
    fail "phase $p records through phase_fail — a failure there would exit 0"
  fi
done

# The stale-selection guard must SURVIVE the addition of phases 5 and 7.
expect_rc "PHASES=\"1 2 3\" still fails after 5 and 7 exist" 1 "$(run_verify "$r" "1 2 3")"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/test-verify-exit-code.sh`
Expected: FAIL on the new default, `VALID_PHASES`, and both `phase_fail` assertions.

- [ ] **Step 3: Change the selection lines**

Line 90: `PHASES="${PHASES:-4 5 7}"`
Line 102: `VALID_PHASES="0 4 5 7"`

- [ ] **Step 4: Add Phase 5, before the Phase 4 block**

```bash
# ── Phase 5: the hermetic suite ─────────────────────────────────────────────────
# Mirrors .github/workflows/tests.yml's `suite` job. It exists because the local
# layer was a SUBSET of the PR gate: this script ran the integration corpus and
# nothing else, so a developer verifying locally checked LESS than CI would.
#
# It also runs the hermetic suite against BSD userland for the first time. CI is
# ubuntu-only; `stat -c`, `sha1sum` and `md5sum` do not exist on macOS, and four
# call sites used them with no fallback (fixed in increment 4, tests/portability.sh).
if want_phase 5; then
say "PHASE 5 — hermetic suite (tests/run-all.sh) + sandbox.conf schema gate"
if [[ ! -f "$TESTS_DIR/run-all.sh" ]]; then
  phase_fail 5 "$TESTS_DIR/run-all.sh not found — the hermetic suite did not run"
else
  bash "$TESTS_DIR/run-all.sh" 2>&1 | sed "s/^/$LOG_PREFIX   /"
  h_rc="${PIPESTATUS[0]:-1}"
  sub "hermetic suite exit: $h_rc"
  [[ "$h_rc" -eq 0 ]] || phase_fail 5 "hermetic suite exited $h_rc"
  if [[ -f "$REPO/check-sandbox-version.sh" ]]; then
    bash "$REPO/check-sandbox-version.sh" --check 2>&1 | sed "s/^/$LOG_PREFIX   /"
    s_rc="${PIPESTATUS[0]:-1}"
    [[ "$s_rc" -eq 0 ]] || phase_fail 5 "sandbox.conf schema gate exited $s_rc"
  else
    phase_fail 5 "check-sandbox-version.sh not found — the schema gate did not run"
  fi

  # The same suite at the DECLARED FLOOR, mirroring tests.yml's suite-floor job.
  # This host runs whatever bash the developer installed (5.3 via Homebrew is
  # typical); the floor is 5.1, and a floor nothing exercises is the defect this
  # increment exists to remove. Docker is guaranteed here — Phase 0 hard-exits
  # without a reachable daemon.
  floor_img="ubuntu:22.04"
  sub "running the suite at the declared floor ($floor_img, bash 5.1)"
  docker run --rm -v "$REPO_ROOT_FOR_MOUNT:/w" -w /w "$floor_img" bash -c \
    'apt-get update -qq && apt-get install -y -qq git rsync >/dev/null 2>&1 && \
     bash --version | head -1 && ./tests/run-all.sh' 2>&1 | sed "s/^/$LOG_PREFIX   /"
  f_rc="${PIPESTATUS[0]:-1}"
  sub "floor suite exit: $f_rc"
  [[ "$f_rc" -eq 0 ]] || phase_fail 5 "hermetic suite at the declared floor exited $f_rc"
fi
fi
```

`REPO_ROOT_FOR_MOUNT` is the directory that must be mounted for `tests/` to
resolve: `$REPO` in ai-containers, `$REPO/..` in mgd where the engine lives in
`base/`. Derive it from `TESTS_DIR` rather than branching on repo name —
`REPO_ROOT_FOR_MOUNT="$(cd "$TESTS_DIR/.." && pwd)"` — so one copy of this
script serves both layouts, which is the standing rule for this file.

- [ ] **Step 5: Add Phase 7, after Phase 5**

```bash
# ── Phase 7: lint ───────────────────────────────────────────────────────────────
# Mirrors .github/workflows/tests.yml's `lint` job, with one difference that is
# the whole point: shellcheck runs as a GATE here, not `|| true`. That advisory
# carried a comment calling a gate "a deliberate follow-up" — a follow-up nobody
# scheduled. The layer model gives it a home: advisory in CI, gating locally,
# where a human is present to act on it.
if want_phase 7; then
say "PHASE 7 — lint (bash -n, dialect floor, shellcheck)"
n_parsed=0; parse_rc=0
while IFS= read -r f; do
  n_parsed=$((n_parsed + 1))
  bash -n "$REPO/$f" 2>/dev/null || { sub "PARSE ERROR: $f"; parse_rc=1; }
done < <(cd "$REPO" && git ls-files '*.sh' 2>/dev/null)
if [[ "$n_parsed" -eq 0 ]]; then
  phase_fail 7 "bash -n parsed no files — the pathspec matched nothing"
else
  sub "parsed $n_parsed script(s)"
  [[ "$parse_rc" -eq 0 ]] || phase_fail 7 "bash -n found a parse error"
fi

if [[ -f "$TESTS_DIR/bash-dialect-lint.sh" ]]; then
  bash "$TESTS_DIR/bash-dialect-lint.sh" 2>&1 | sed "s/^/$LOG_PREFIX   /"
  d_rc="${PIPESTATUS[0]:-1}"
  [[ "$d_rc" -eq 0 ]] || phase_fail 7 "bash dialect lint exited $d_rc"
else
  phase_fail 7 "bash-dialect-lint.sh not found — the dialect floor was not checked"
fi

if command -v shellcheck >/dev/null 2>&1; then
  ( cd "$REPO" && git ls-files '*.sh' | xargs shellcheck -S warning -e SC1091 ) \
    2>&1 | sed "s/^/$LOG_PREFIX   /"
  sc_rc="${PIPESTATUS[0]:-1}"
  [[ "$sc_rc" -eq 0 ]] || phase_fail 7 "shellcheck exited $sc_rc"
else
  phase_fail 7 "shellcheck not installed — install it (brew install shellcheck) or deselect phase 7"
fi
fi
```

- [ ] **Step 6: Update the header comment**

Lines 14-30 describe the phase set. Update the usage example and the sentence
naming Phase 4 as "the only remaining phase" to name 4, 5 and 7, and state the
execution order (0, 5, 7, 4 — cheap checks first).

- [ ] **Step 7: Run the guard test**

Run: `bash tests/test-verify-exit-code.sh && bash tests/run-all.sh verify`
Expected: PASS, including `PHASES="1 2 3" still fails after 5 and 7 exist`.

- [ ] **Step 8: Demonstrate Phase 5 failing**

Point `TESTS_DIR` at an empty directory and run
`PHASES=5 bash ./verify-on-host.sh`; confirm `RESULT: FAILED` naming phase 5 and
exit 1. Record the output in the commit message.

- [ ] **Step 9: Commit**

```bash
git add verify-on-host.sh tests/test-verify-exit-code.sh
git commit -m "feat: verify-on-host phases 5 (hermetic suite) and 7 (lint, shellcheck gating)"
```

---

### Task 6: the layer containment guard

**Files:**
- Create: `tests/test-layer-containment.sh`

**Interfaces:**
- Consumes: `run.sh --dry-run` (Task 4); `verify-on-host.sh` phases (Task 5); `tests/bash-dialect-lint.sh` (Task 2).

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# tests/test-layer-containment.sh — the suite runs in three layers, and the
# invariant is local ⊇ nightly ⊇ PR.
#
# Stated as prose this decays, exactly as the "seen failing" rule decayed before
# tests/test-mutations.sh made it mechanical. The concrete failure this catches:
# verify-on-host.sh ran the integration corpus and NOTHING else, so a developer
# verifying locally checked less than CI would — the local layer was a SUBSET of
# the PR gate.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_YML="$REPO_DIR/.github/workflows/tests.yml"
VERIFY="$REPO_DIR/verify-on-host.sh"
RUN="$REPO_DIR/tests/integration/run.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

for f in "$TESTS_YML" "$VERIFY" "$RUN"; do
  [[ -f "$f" ]] || { fail "$(basename "$f") not found — nothing below is checked"; \
    printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }
done

# ── Every PR-layer check also runs locally ─────────────────────────────────────
# name|regex matching its invocation in tests.yml|regex matching it in verify-on-host.sh
CHECKS='hermetic suite|run-all\.sh|run-all\.sh
schema gate|check-sandbox-version\.sh|check-sandbox-version\.sh
floor suite|container: ubuntu:22\.04|ubuntu:22\.04
bash -n|bash -n|bash -n
dialect lint|bash-dialect-lint\.sh|bash-dialect-lint\.sh
shellcheck|shellcheck|shellcheck'
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  name="${row%%|*}"; rest="${row#*|}"
  ci_re="${rest%%|*}"; local_re="${rest#*|}"
  if ! grep -qE "$ci_re" "$TESTS_YML"; then
    fail "$name is invoked by tests.yml — it is not, so this row is stale"
    continue
  fi
  if grep -qE "$local_re" "$VERIFY"; then
    pass "$name runs in the local layer too"
  else
    fail "$name runs in CI but NOT in verify-on-host.sh — local is not a superset"
  fi
done <<< "$CHECKS"

# ── The named list cannot police what it does not name ─────────────────────────
# A hand-written list validates only what someone remembered — the exact failure
# the mgd port shipped, where the byte-identity gate iterated the same list it
# was meant to police. So pin the STEP COUNT per job: a new CI step must be
# given a layer, and cannot widen the PR gate past the local one unnoticed.
#   suite:       checkout, bash version, rsync, run tests, schema gate  = 5
#   suite-floor: install git+rsync, checkout, bash version, run tests   = 4
#   lint:        checkout, bash -n, dialect lint, shellcheck            = 4
expect_steps() {  # $1=job $2=expected count
  local got
  got="$(awk -v j="$1" '
    $0 ~ "^  "j":$" {inj=1; next}
    inj && /^  [a-z]/ {inj=0}
    inj && /^      - / {c++}
    END {print c+0}' "$TESTS_YML")"
  if [[ "$got" == "$2" ]]; then
    pass "tests.yml job '$1' has $2 step(s)"
  else
    fail "tests.yml job '$1' has $got step(s), baseline says $2 — a step was added or removed; give it a layer in verify-on-host.sh, then update this baseline"
  fi
}
expect_steps suite 5
expect_steps suite-floor 4
expect_steps lint 4

# The floor job must run the image matching the DECLARED floor. If bash-floor.sh
# says 5.1 and the job runs ubuntu:24.04 (bash 5.2), the floor is untested again
# and nothing else would notice.
# shellcheck source=../bash-floor.sh
source "$REPO_DIR/bash-floor.sh"
floor="${AI_CONTAINERS_BASH_FLOOR_MAJOR}.${AI_CONTAINERS_BASH_FLOOR_MINOR}"
case "$floor" in
  5.1) want_img="ubuntu:22.04" ;;
  5.2) want_img="ubuntu:24.04" ;;
  *)   want_img="" ;;
esac
if [[ -z "$want_img" ]]; then
  fail "no container image is mapped to floor $floor — suite-floor cannot test the claim"
elif grep -qF "container: $want_img" "$TESTS_YML"; then
  pass "suite-floor runs $want_img, matching the declared floor $floor"
else
  fail "suite-floor does not run $want_img — the declared floor $floor is untested"
fi

# ── Integration-case containment, asked of run.sh rather than reimplemented ────
sel() { bash "$RUN" --dry-run "$@" 2>/dev/null | grep -E '^[0-9]{3}-' | sort; }
pr_set="$(sel --tags fast --exclude needs-external,needs-dns)"
nightly_set="$( { sel --exclude packages; sel --tags packages; } | sort -u )"
local_set="$(sel)"

[[ -n "$pr_set" && -n "$nightly_set" && -n "$local_set" ]] \
  && pass "all three selections are non-empty" \
  || fail "a selection came back empty — containment below would pass vacuously"

missing="$(comm -23 <(printf '%s\n' "$pr_set") <(printf '%s\n' "$nightly_set"))"
[[ -z "$missing" ]] \
  && pass "PR selection ⊆ nightly selection" \
  || fail "PR selection ⊄ nightly: $(printf '%s' "$missing" | tr '\n' ' ')"

missing="$(comm -23 <(printf '%s\n' "$nightly_set") <(printf '%s\n' "$local_set"))"
[[ -z "$missing" ]] \
  && pass "nightly selection ⊆ local selection" \
  || fail "nightly selection ⊄ local: $(printf '%s' "$missing" | tr '\n' ' ')"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
```

- [ ] **Step 2: Run it**

Run: `bash tests/test-layer-containment.sh`
Expected: PASS on every assertion (Tasks 2, 4 and 5 have landed the pieces).

- [ ] **Step 3: Demonstrate it failing — the containment half**

Neuter the Phase 5 block's real `run-all.sh` invocation in `verify-on-host.sh`
(replace the `bash "$TESTS_DIR/run-all.sh" …` call with `h_rc=0; true`, leaving a
comment that still names the file), run the test, confirm the hermetic-suite row
FAILs, then restore. Repeat for a second row — the schema gate — because the
weakness this guards against is systemic, not per-row.

> **Corrected 2026-08-11.** This step originally said to comment out the
> invocation and expect a failure. It does not fail: `verify-on-host.sh` mentions
> the literal string `run-all.sh` six times (existence guard, `phase_fail`
> message, header phase table, floor-container invocation), so a whole-file
> `grep` still matches. That non-failure was the *symptom of a Critical design
> defect* — the check proved a string existed rather than that the check ran —
> and the fix was to assert by effect via a witness log, not to find a bigger
> hammer for the demonstration. See the CHECKS table's current implementation.

- [ ] **Step 4: Demonstrate it failing — the ratchet half**

Add a trivial step (`- name: noop` / `run: 'true'`) to the `lint` job in
`tests.yml`, run the test, confirm the step-count assertion FAILs naming the
job, then remove the step.

- [ ] **Step 5: Demonstrate it failing — the floor-image half**

Change `bash-floor.sh` to `AI_CONTAINERS_BASH_FLOOR_MINOR=2` without touching
`tests.yml`, run the test, confirm `suite-floor does not run ubuntu:24.04 — the
declared floor 5.2 is untested` FAILs, then revert. This is the assertion that
stops the floor and the image it is tested at from drifting apart.

- [ ] **Step 6: Demonstrate it failing — the set-comparison half**

Temporarily merge `fast` into the existing exclude of the `nightly_set`
computation — `sel --exclude packages,fast` — confirm `PR selection ⊆ nightly
selection` FAILs listing the missing cases, then revert.

> **Corrected 2026-08-11.** This step originally said to "add `--exclude fast`".
> Read as a separate `sel --exclude fast` union branch that is a true no-op:
> `run.sh:152` **assigns** `excl_tags` rather than accumulating, and the union
> with `--tags packages` re-admits everything, so the demonstration proves
> nothing. The exclusion must be merged into the one call to actually widen it.

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run-all.sh`
Expected: all tests pass, including the three new files.

- [ ] **Step 8: Commit**

```bash
git add tests/test-layer-containment.sh
git commit -m "test: enforce local ⊇ nightly ⊇ PR instead of asserting it in prose"
```

---

### Task 7: the macOS measurement hand-off

**This task is a HAND-OFF, not an implementation task.** This session runs on
Linux and cannot execute it. Do not attempt to simulate, emulate or skip it.

**Files:** none changed by this task.

- [ ] **Step 1: Ask the human partner to run the local layer on macOS**

Ask them to run, from the repo root on their Mac:

```bash
bash tests/run-all.sh 2>&1 | tee /tmp/macos-hermetic.log; echo "exit=$?"
```

and paste the output. `tests/run-all.sh` alone — not the full
`verify-on-host.sh`, which would spend an hour building images before reporting
anything about portability.

- [ ] **Step 2: Record every failure**

Write the complete failure list to `docs/superpowers/plans/2026-08-11-macos-findings.md`,
one entry per failing test file with the specific error line. This file is the
input to Task 8 and the evidence that the list is complete rather than
convenient.

- [ ] **Step 3: Commit the findings**

```bash
git add docs/superpowers/plans/2026-08-11-macos-findings.md
git commit -m "docs: record the macOS hermetic-suite failures measured on the host"
```

---

### Task 8: fix what the macOS run found

**Files:** determined by Task 7's findings file. Do not guess them in advance.

- [ ] **Step 1: Classify each finding**

For each failure in `docs/superpowers/plans/2026-08-11-macos-findings.md`, record
one of:
- **portability** — a GNU-ism; fix with a `tests/portability.sh` helper, adding
  a new helper there if the existing four do not cover it
- **real defect** — the test found a genuine bug that Linux hid; fix the product
- **environment** — a missing tool on the host; the test must SKIP explicitly
  (`SKIP:` line, a first-class outcome in `run-all.sh`) rather than fail

- [ ] **Step 2: Fix every portability finding**

Each fix routes through `tests/portability.sh` so a fifth GNU-ism does not become
a fifth open-coded fallback. Add helpers there rather than inline `|| ` chains.

- [ ] **Step 3: Add a test vector per new helper**

Extend `tests/test-portability.sh` with the same shape as the existing four:
non-empty on this platform, stable across calls, and distinguishing for differing
inputs.

- [ ] **Step 4: Ask for a confirming macOS run**

Hand off again: the same `bash tests/run-all.sh` on the Mac, expecting green.
If findings remain, they are parked per the standing rule — a subset fixed before
merge, the remainder carried into a follow-up merge with one ledger entry each,
recorded in the PR description so they survive the merge boundary.

- [ ] **Step 5: Commit**

```bash
git add tests/portability.sh tests/test-portability.sh docs/superpowers/plans/2026-08-11-macos-findings.md
git commit -m "fix: the macOS hermetic-suite failures measured on the host"
```

---

### Task 9: shellcheck triage, so Phase 7 gates green

**Files:**
- Modify: the files carrying actionable findings (determined by triage)
- Modify: `.github/workflows/tests.yml` (the `-e` list, if any code is categorically wrong here)

**Context for the implementer:** measured on 2026-08-11 with shellcheck 0.11.0 —
**75 findings across 25 files**. Roughly 31 are `SC2178`/`SC2128` nameref false
positives (shellcheck does not model `local -n`), 23 of those in
`tests/test-parsers.sh` alone; 24 are `SC2034` unused-variable in sourced
libraries where the consumer is a different file; 10 are `SC2154`. Perhaps 10-20
are genuinely worth acting on.

- [ ] **Step 1: Reproduce the baseline**

```bash
git ls-files '*.sh' | xargs shellcheck -S warning -e SC1091 -f gcc > /tmp/sc.txt
wc -l /tmp/sc.txt; grep -oE 'SC[0-9]+' /tmp/sc.txt | sort | uniq -c | sort -rn
```

Expected: about 75 findings. A materially different count means the tree moved —
re-triage rather than applying this task's assumptions.

- [ ] **Step 2: Fix the actionable findings**

Everything that is a real defect or a trivially correct tightening. Do not
suppress something merely because suppressing is faster.

- [ ] **Step 3: Suppress the nameref false positives at the site**

For each `SC2178`/`SC2128` on a `local -n` variable, add directly above it:

```bash
# shellcheck disable=SC2178,SC2128  # nameref: shellcheck does not model `local -n`
```

Inline and reasoned, not a blanket `-e` — a blanket disable would also hide a
genuine array-assigned-a-string bug elsewhere.

- [ ] **Step 4: Decide the `-e` list**

Only for codes categorically wrong for this codebase across many files. Each
addition gets a comment in `tests.yml` naming why. If no code qualifies, add
none.

- [ ] **Step 5: Verify the gate is green**

```bash
git ls-files '*.sh' | xargs shellcheck -S warning -e SC1091 && echo "CLEAN"
```

Expected: `CLEAN`.

- [ ] **Step 6: Promote CI's shellcheck from advisory to gate**

In `.github/workflows/tests.yml`, drop the trailing `|| true` and replace the
"ADVISORY, not a gate" comment with one recording that increment 4 cleared the
backlog and gated it, and that Phase 7 runs the same check locally.

- [ ] **Step 7: Run everything**

Run: `bash tests/run-all.sh && bash tests/bash-dialect-lint.sh`
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add -u
git commit -m "fix: clear the shellcheck backlog and gate on it"
```

---

### Task 10: documentation and the mgd port

**Files:**
- Modify: `AGENTS.md` (new "Execution layers" section; bash floor; `--dry-run`)
- Modify: `CHANGELOG.md`
- Port: `Dynatrace-Internal/mgd-ai-containers`

- [ ] **Step 1: Document the layer model in `AGENTS.md`**

Add a section covering: the three layers and their contracts; the
`local ⊇ nightly ⊇ PR` invariant and that `tests/test-layer-containment.sh`
enforces it; the phase table (0, 4, 5, 7) **including why 1-3 are burned
identifiers and 6 is reserved**; the bash floor at 5.1 declared once in
`bash-floor.sh`; `run.sh --dry-run` versus `--list`'s whole-corpus contract.

- [ ] **Step 2: Update `CHANGELOG.md`**

Insert an entry by matching the heading, never by line number.

- [ ] **Step 3: Derive the port's file list**

```bash
git diff --name-only "$(git merge-base HEAD origin/main)"..HEAD
```

Never hand-write it, and build the byte-identity gate from this same derived
list — a checklist cannot validate its own omissions.

- [ ] **Step 4: Port**

`tests/` is at the repo root in both. The engine scripts and `verify-on-host.sh`
live under `base/` in mgd, so `bash-floor.sh` → `base/bash-floor.sh` and the
`source` lines resolve relative to `BASH_SOURCE`, unchanged. `.github/workflows/*`
and `base/AGENTS.md` / `base/CHANGELOG.md` are hand-adapted, never copied.

- [ ] **Step 5: Verify byte-identity for the shared files**

For every file in the derived list that is not hand-adapted, `diff` the two
copies and require empty output.

- [ ] **Step 6: Run both suites**

Run `bash tests/run-all.sh` in each repo. mgd has one more test file than
ai-containers, so the expected counts differ by one — that is normal, not a port
defect.

- [ ] **Step 7: Commit and open both PRs**

Carry any parked findings from Tasks 8 and 9 into both PR descriptions so they
survive the merge boundary.

---

## Self-Review

**Spec coverage.** Every spec component maps to a task: `--dry-run` → 4;
`bash-floor.sh` → 1; dialect linter → 2; `test-bash-floor.sh` → 1;
`test-layer-containment.sh` → 6; portability fixes → 3; phases → 5; R1's
measurement hand-off → 7 and 8; R2's shellcheck triage → 9; docs and port → 10.

**Ordering.** Tasks 1-6 are Linux-only and land the machinery. Task 7 is the
single scheduled hand-off. Tasks 8-9 depend on measured data. Task 10 closes.
The one blocking dependency on the human sits at a planned point, not scattered
through the increment.

**Known gap.** Task 8's file list cannot be written in advance — it is the
output of Task 7's measurement. Naming files there would be fabrication, so the
task specifies the classification procedure and the routing rule instead. This
is the one place the plan is deliberately open, and R1's mitigation is exactly
why.
