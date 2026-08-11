# Integration Suite Increment 3 — Packages Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `verify-on-host.sh` Phases 1-3 with seven first-class integration cases running on two new image variants, closing umbrella success criterion 6.

**Architecture:** `tests/integration/run.sh` gains an image-variant table and schedules selected cases grouped by variant (build → run → `docker rmi` → next), exporting `IT_IMAGE` and `IT_VARIANT_OVERRIDES` per variant. `lib.sh` gains the Ruby-group helpers and the blocked-traffic forensics lifted out of Phase 3. Seven cases replace three phases; `verify-on-host.sh` keeps only Phase 0 and the delegation to `run.sh`.

**Tech Stack:** bash 3.2-compatible shell, Docker CLI, `tests/integration/` harness (`run.sh`, `lib.sh`, `minimal-conf.sh`, `docker-shim.sh`, `mutate.sh`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-10-integration-suite-increment-3-design.md`

## Global Constraints

- **bash 3.2 compatible.** Stock macOS bash. No associative arrays, no `${var^^}`, no `mapfile`. Existing code uses space-separated strings and `case " $list " in *" $x "*)` membership tests — follow that.
- **Layout tolerance.** Upstream `ai-containers` keeps the engine at the repo root; `mgd-ai-containers` keeps it in `base/` with `tests/` one level up. Every shared file must serve both verbatim. Existing pattern: `ENGINE_DIR="$REPO_DIR"; [[ -f "$ENGINE_DIR/sandbox.sh" ]] || ENGINE_DIR="$REPO_DIR/base"`.
- **No local Docker daemon in the implementation environment.** Hermetic tests (`tests/test-*.sh`) run locally; runtime cases are verified by pushing the branch and reading CI. Never claim a runtime case passes without a CI run to cite.
- **A case is not accepted until it has been seen FAILING** against the known-bad configuration it exists to catch. Mechanised by `tests/integration/mutations/` + `mutate.sh` + `tests/test-mutations.sh`.
- **Patches, not `sed`, for mutations.** A patch that no longer applies fails loudly; a stale `sed` matches nothing and reports success.
- **Selection and skipping are different outcomes.** `--tags`/`--exclude` choose what runs; a SKIP is a selected case whose requirement was unmet; `--require <tag>` makes such a skip fail the run. A case that cannot run is never counted as a pass.
- **Assert effect, not configuration.** Observe from outside whether the packet arrived, the file exists, the binary ran.
- **Present is not runnable.** A binary that resolves on `PATH` and dies on exec is a distinct failure from an absent one and must be reported distinctly.
- **Never test the wrong process's status.** `if out="$(cmd | head -1)"` reports `head`'s exit code. Capture first, `head` afterwards.
- **`bundler` is reported, never required.** `link-default-ruby.sh` links `ruby`/`gem`/`bundle`/`rake`/`irb` only.
- **Default Ruby list is `IT_RUBY_VERSIONS="${IT_RUBY_VERSIONS:-3.3.6,3.4.5}"`.** One env var, one code path — never a `$CI` branch inside `run.sh`.
- **Every change ports to `mgd-ai-containers` via PR** (that repo requires PRs). Shared files must end byte-identical; verify with `diff -q`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `tests/integration/run.sh` | variant table, `image:` header, per-variant scheduling, `multiruby` capability | 1, 2, 4 |
| `tests/integration/lib.sh` | `launcher_conf` variant fold-in, Ruby group constant + readiness wait, `dump_blocked_forensics`, `assert_runs` | 3, 5, 6 |
| `tests/integration/cases/700..760-*.sh` | the seven cases | 7, 8, 9 |
| `tests/integration/mutate.sh` | multi-apply for batched demonstrations | 10 |
| `tests/integration/mutations/*.patch` | seven known-bad demonstrations | 11 |
| `tests/test-integration-runner.sh` | hermetic tests for run.sh variant logic | 1, 2, 4 |
| `tests/test-integration-lib.sh` | hermetic tests for lib.sh additions | 3, 5, 6 |
| `tests/test-mutations.sh` | multi-apply tests; tag list gains `packages` | 10, 11 |
| `verify-on-host.sh` | Phases 1-3 deleted | 11 |
| `tests/test-verify-exit-code.sh` | phase 1/2/3 assertions removed | 11 |
| `tests/test-verify-on-host-keep.sh` | **deleted** (tests Phase 3's keep logic) | 11 |
| `.github/workflows/nightly.yml` | `packages` job rewritten; measurement instrumentation | 12 |
| `AGENTS.md`, `CHANGELOG.md` | documentation | 13 |

---

### Task 1: `image:` header and the variant table

**Files:**
- Modify: `tests/integration/run.sh`
- Test: `tests/test-integration-runner.sh`

**Interfaces:**
- Consumes: `case_meta "$f" <key>` (existing, `run.sh:158`) — reads `# <key>: value` from a case header.
- Produces:
  - `IT_RUBY_VERSIONS` — env var, default `3.3.6,3.4.5`
  - `variant_overrides <name>` → prints space-separated `key=value` pairs; returns 1 for an unknown variant
  - `variant_image <name>` → prints the image tag for that variant
  - `case_variant <file>` → prints the case's variant, `default` when the header is absent

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-integration-runner.sh`, before its final `printf '\n%d failure(s)\n'`:

```bash
# ── Image variants ─────────────────────────────────────────────────────────────
# The packages tier needs images the default minimal one cannot provide. A typo
# in an `image:` header must be a hard error: silently falling back to `default`
# would run a Ruby case against an image with no Ruby and report the product
# broken.
vsh() { IT_RUBY_VERSIONS="${IT_RUBY_VERSIONS:-3.3.6,3.4.5}" IT_IMAGE=ai-sandbox-it \
        bash -c 'source "$1" --source-only 2>/dev/null || true; shift; "$@"' _ "$RUNNER" "$@"; }

out="$(RUNNER_FUNC=variant_overrides bash "$TMP/callfn.sh" variant_overrides agents)"
case "$out" in
  *copilot=ON*claude-code=ON*codex=ON*gemini=ON*graphify=ON*vale=ON*node=22,20*)
    pass "variant agents turns on all six agent-tier keys and multi-version node" ;;
  *) fail "variant agents overrides — got: $out" ;;
esac

out="$(bash "$TMP/callfn.sh" variant_overrides native)"
case "$out" in
  *db-clients=pg,mysql,mongo*imagemagick=ON*wkhtmltopdf=ON*ruby=3.3.6,3.4.5*)
    pass "variant native carries the KEEP_BUILD_TOOLCHAIN components and both rubies" ;;
  *) fail "variant native overrides — got: $out" ;;
esac

out="$(IT_RUBY_VERSIONS=3.4.5 bash "$TMP/callfn.sh" variant_overrides native)"
case "$out" in
  *ruby=3.4.5*) pass "IT_RUBY_VERSIONS overrides the native variant's ruby list" ;;
  *)            fail "IT_RUBY_VERSIONS override — got: $out" ;;
esac

bash "$TMP/callfn.sh" variant_overrides no-such-variant >/dev/null 2>&1
if [[ "$?" -ne 0 ]]; then
  pass "an unknown variant is rejected, not silently treated as default"
else
  fail "an unknown variant is rejected — a typo would run a case on the wrong image"
fi

check "variant_image default is the plain image tag" \
  "ai-sandbox-it" "$(bash "$TMP/callfn.sh" variant_image default)"
check "variant_image agents is suffixed" \
  "ai-sandbox-it-agents" "$(bash "$TMP/callfn.sh" variant_image agents)"

# case_variant: header present, header absent, header with extra spacing
printf '#!/usr/bin/env bash\n# tags:  packages\n# image:    agents\n' > "$TMP/c-with.sh"
printf '#!/usr/bin/env bash\n# tags:  mounts\n' > "$TMP/c-without.sh"
check "case_variant reads the image header" \
  "agents" "$(bash "$TMP/callfn.sh" case_variant "$TMP/c-with.sh")"
check "case_variant defaults when the header is absent" \
  "default" "$(bash "$TMP/callfn.sh" case_variant "$TMP/c-without.sh")"
```

Add this helper near the top of `tests/test-integration-runner.sh`, after `TMP` is created — it lets the hermetic tests call `run.sh`'s functions without running a whole suite:

```bash
# run.sh is a script, not a library. Sourcing it with IT_SOURCE_ONLY=1 stops it
# before the selection/execution phase so its pure functions can be unit-tested.
# Without this the only way to test variant resolution would be a full run,
# which needs a Docker daemon this suite does not have.
cat > "$TMP/callfn.sh" <<EOF
#!/usr/bin/env bash
export IT_SOURCE_ONLY=1
export IT_IMAGE="\${IT_IMAGE:-ai-sandbox-it}"
source "$RUNNER"
"\$@"
EOF
chmod +x "$TMP/callfn.sh"
```

and set `RUNNER="$REPO_DIR_ENGINE/tests/integration/run.sh"` using the same layout resolution the file already performs for other paths.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-integration-runner.sh`
Expected: FAIL on every new assertion — `variant_overrides: command not found`, because none of these functions exist yet.

- [ ] **Step 3: Add the variant table to `run.sh`**

Insert immediately after the `IT_IMAGE` assignment (currently `run.sh:31`):

```bash
# ── Image variants ──────────────────────────────────────────────────────────────
# The corpus ran on ONE image until the packages tier: the firewall does not know
# which fragment a domain came from, so proving admit/drop once proves it for
# every fragment, and N per-component images bought nothing. The packages tier is
# the exception — it asserts that components INSTALL, which is per-component by
# construction.
#
# Two variants, not three. The split is KEEP_BUILD_TOOLCHAIN, a distinction the
# Dockerfile itself makes: `agents` has it unset (the configuration most users
# ship), `native` has it set by ruby=/db-clients=. A single kitchen-sink image
# could only ever exercise the toolchain-kept path, so the agent-tier tools would
# never be tested in the configuration they actually ship in.
IT_RUBY_VERSIONS="${IT_RUBY_VERSIONS:-3.3.6,3.4.5}"

variant_overrides() {  # $1=variant → space-separated key=value; rc 1 if unknown
  case "$1" in
    default) printf '' ;;
    agents)  printf 'copilot=ON claude-code=ON codex=ON gemini=ON graphify=ON vale=ON node=22,20' ;;
    native)  printf 'db-clients=pg,mysql,mongo imagemagick=ON wkhtmltopdf=ON ruby=%s' "$IT_RUBY_VERSIONS" ;;
    *)       return 1 ;;
  esac
  return 0
}

variant_image() {  # $1=variant → the image tag to build/run
  case "$1" in
    default) printf '%s' "$IT_IMAGE" ;;
    *)       printf '%s-%s' "$IT_IMAGE" "$1" ;;
  esac
}

case_variant() {  # $1=case file → its variant, or `default`
  local v; v="$(case_meta "$1" image)"
  printf '%s' "${v:-default}"
}
```

`case_variant` must be defined *after* `case_meta` (`run.sh:158`); move the three functions below it if bash reports an undefined function at call time — they are only called after both definitions are read, so top-level placement is fine, but keep them together.

- [ ] **Step 4: Add the `IT_SOURCE_ONLY` early return**

Immediately before `run.sh`'s `# ── Selection ───` banner, insert:

```bash
# Sourced by tests/test-integration-runner.sh to unit-test the pure functions
# above without a Docker daemon. Everything below this line performs I/O.
[[ -n "${IT_SOURCE_ONLY:-}" ]] && return 0 2>/dev/null
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test-integration-runner.sh`
Expected: PASS on all eight new assertions, and no regression in the existing ones.

- [ ] **Step 6: Commit**

```bash
git add tests/integration/run.sh tests/test-integration-runner.sh
git commit -m "test(integration): image variant table and the image: case header"
```

---

### Task 2: Schedule cases by variant

**Files:**
- Modify: `tests/integration/run.sh`
- Test: `tests/test-integration-runner.sh`

**Interfaces:**
- Consumes: `variant_overrides`, `variant_image`, `case_variant` (Task 1); `build_image` (existing, `run.sh:304`).
- Produces:
  - `build_image <variant>` — now takes a variant argument; builds `variant_image <variant>` from `minimal-conf.sh` plus `variant_overrides <variant>`
  - `selected_variants <files…>` → distinct variants in first-seen order
  - exports `IT_VARIANT_OVERRIDES` before each variant's cases run

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-integration-runner.sh`:

```bash
# ── Variant scheduling ─────────────────────────────────────────────────────────
# Grouping matters for DISK, not tidiness: a GitHub runner has ~14 GB free and
# these images are multi-GB. Building all variants up front and removing them at
# the end would peak at the sum. Build → run that variant's cases → rmi → next
# peaks at one.
printf '#!/usr/bin/env bash\n# image: agents\n'  > "$TMP/v-a1.sh"
printf '#!/usr/bin/env bash\n# image: native\n'  > "$TMP/v-n1.sh"
printf '#!/usr/bin/env bash\n# tags: mounts\n'   > "$TMP/v-d1.sh"
printf '#!/usr/bin/env bash\n# image: agents\n'  > "$TMP/v-a2.sh"

check "selected_variants lists each variant once, in first-seen order" \
  "agents native default" \
  "$(bash "$TMP/callfn.sh" selected_variants "$TMP/v-a1.sh" "$TMP/v-n1.sh" "$TMP/v-d1.sh" "$TMP/v-a2.sh")"

check "selected_variants of a default-only selection does not name a packages variant" \
  "default" "$(bash "$TMP/callfn.sh" selected_variants "$TMP/v-d1.sh")"
```

`selected_variants` is the whole testable surface here. Do **not** add an
assertion that greps `run.sh` for a literal call like `build_image "$v"`: the
Global Constraints require asserting effect rather than configuration, and a
grep for a code string fails on refactors that are entirely correct. That the
runner never builds a variant nothing selected is verified for real by the CI
run in Task 13, where a `--tags mounts` run must build exactly one image.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test-integration-runner.sh`
Expected: FAIL — `selected_variants: command not found`.

- [ ] **Step 3: Add `selected_variants` and re-shape `build_image`**

Add beside the Task 1 functions:

```bash
selected_variants() {  # $@=case files → distinct variants, first-seen order
  # bash 3.2: no associative arrays. Space-padded membership test, the same
  # shape have_cap() and list_intersects() already use.
  local f v seen=""
  for f in "$@"; do
    v="$(case_variant "$f")"
    case " $seen " in *" $v "*) ;; *) seen="${seen:+$seen }$v" ;; esac
  done
  printf '%s' "$seen"
}
```

Change `build_image()`'s signature and body (`run.sh:304`):

```bash
build_image() {  # $1=variant
  local variant="${1:-default}"
  local img; img="$(variant_image "$variant")"
  local overrides; overrides="$(variant_overrides "$variant")" || {
    warn "run.sh: unknown image variant '$variant'"
    return 1
  }
  local conf="$IT_SCRATCH/minimal-sandbox-$variant.conf"
  # Everything optional OFF, then the variant's overrides applied on top. The
  # rule lives in minimal-conf.sh because lib.sh's launcher_conf needs the SAME
  # one — a case drives the real sandbox.sh, which re-reads sandbox.conf at
  # launch time. Two copies of this derivation drifted apart once already; the
  # image then carried a component the launcher did not mount, and the case
  # failed on a missing directory that was correct behaviour.
  bash "$INT_DIR/minimal-conf.sh" "$REPO_DIR/sandbox.conf" $overrides > "$conf" || {
    warn "run.sh: could not derive a minimal sandbox.conf for variant '$variant'"
    return 1
  }
  say "── building $img (variant: $variant)…"
  ( cd "$REPO_DIR" && SANDBOX_CONF="$conf" IMAGE_NAME="$img" ./build.sh "$img" ) \
    > "$IT_SCRATCH/build-$variant.log" 2>&1 || {
      warn "run.sh: image build FAILED for variant '$variant' — last 40 lines of $IT_SCRATCH/build-$variant.log:"
      tail -40 "$IT_SCRATCH/build-$variant.log" >&2
      return 1
    }
  # Snapshot what build.sh generated, for the delivery case (300). Only the
  # default variant: 300 asserts the corpus image's allowlist, and a later
  # variant's build would overwrite the snapshot with a different one.
  if [[ "$variant" == "default" ]]; then
    mkdir -p "$IT_GENERATED_ALLOWLIST_DIR"
    local f
    for f in allowlist-domains.txt allowlist-cidrs.txt allowlist-proxy-domains.txt; do
      cp "$REPO_DIR/$f" "$IT_GENERATED_ALLOWLIST_DIR/$f"
    done
  fi
  say "   build OK"
}
```

- [ ] **Step 4: Re-shape the execution loop**

Replace the `for f in $selected; do` loop's header and closing with a variant-outer / case-inner structure. The body of the loop is unchanged — only the wrapper and the two exports are new:

```bash
for v in $(selected_variants $selected); do
  IT_VARIANT_OVERRIDES="$(variant_overrides "$v")" || {
    printf 'ERROR: case declares unknown image variant: %s\n' "$v" >&2
    exit 1
  }
  IT_IMAGE_ACTIVE="$(variant_image "$v")"
  export IT_VARIANT_OVERRIDES
  export IT_IMAGE="$IT_IMAGE_ACTIVE"

  if [[ "$reuse_image" -eq 0 ]]; then
    build_image "$v" || {
      # A variant that will not build fails ITS cases by name rather than
      # aborting the run: the other variants' cases are unaffected and their
      # result is worth having. Reporting them as passed, or not reporting them
      # at all, is the failure this suite exists to prevent.
      for f in $selected; do
        [[ "$(case_variant "$f")" == "$v" ]] || continue
        printf '%-46s  FAIL  (image variant %s failed to build)\n' "$(basename "$f" .sh)" "$v"
        n_sel=$((n_sel + 1)); n_fail=$((n_fail + 1))
        failed_names="${failed_names:+$failed_names }$(basename "$f" .sh)"
      done
      continue
    }
  fi

  for f in $selected; do
    [[ "$(case_variant "$f")" == "$v" ]] || continue
    ### ── existing per-case body, unchanged ──
  done

  # Reclaim the disk before the next variant. Never the default variant: --keep
  # and the existing sweep() own that one, and removing it here would break
  # a --reuse-image workflow the next run depends on.
  if [[ "$v" != "default" && "$reuse_image" -eq 0 && "$keep" -eq 0 ]]; then
    docker rmi "$(variant_image "$v")" >/dev/null 2>&1 || true
  fi
done
```

Move `detect_caps` and the `capabilities:` banner to *before* this loop (it already is), and note that `probe_netadmin`/`probe_launcher` run against whatever `IT_IMAGE` held at that moment — the default variant. That is correct: they probe the host's kernel and daemon, not the image's contents.

- [ ] **Step 5: Run the hermetic suite**

Run: `bash tests/run-all.sh`
Expected: 39/39 passing, including the new runner assertions.

- [ ] **Step 6: Commit**

```bash
git add tests/integration/run.sh tests/test-integration-runner.sh
git commit -m "test(integration): schedule cases by image variant, one image at a time"
```

---

### Task 3: `launcher_conf` folds in the variant's overrides

**Files:**
- Modify: `tests/integration/lib.sh:312-320`
- Test: `tests/test-integration-lib.sh`

**Interfaces:**
- Consumes: `IT_VARIANT_OVERRIDES` (Task 2).
- Produces: `launcher_conf` behaviour — variant overrides applied first, the case's own arguments second (so a case can still override the variant).

- [ ] **Step 1: Write the failing test**

Append to `tests/test-integration-lib.sh`:

```bash
# ── launcher_conf folds in the variant's overrides ─────────────────────────────
# launcher_up drives the REAL sandbox.sh, which re-reads sandbox.conf at LAUNCH
# time. If the launcher config and the image config disagree, the launcher does
# not mount what the image contains and the case fails on correct behaviour.
# That already happened once. The fix is that a case never states the variant's
# overrides, so it cannot forget them.
export IT_VARIANT_OVERRIDES='ruby=3.3.6,3.4.5 imagemagick=ON'
launcher_prepare >/dev/null 2>&1
launcher_conf >/dev/null 2>&1
conf="$IT_LAUNCH_HOME/sandbox.conf"
grep -qx 'ruby=3.3.6,3.4.5' "$conf" \
  && pass "launcher_conf applies the variant's overrides with no case arguments" \
  || fail "launcher_conf applies the variant's overrides with no case arguments"
grep -qx 'imagemagick=ON' "$conf" \
  && pass "launcher_conf applies every variant override, not just the first" \
  || fail "launcher_conf applies every variant override, not just the first"

# A case's own argument must win over the variant's value for the same key,
# so a case can narrow the variant deliberately.
launcher_conf ruby=3.4.5 >/dev/null 2>&1
grep -qx 'ruby=3.4.5' "$conf" \
  && pass "a case argument overrides the variant's value for the same key" \
  || fail "a case argument overrides the variant's value for the same key"

# And with no variant set, behaviour is exactly as before.
unset IT_VARIANT_OVERRIDES
launcher_conf claude-code=ON >/dev/null 2>&1
grep -qx 'claude-code=ON' "$conf" \
  && pass "launcher_conf still works with no variant overrides set" \
  || fail "launcher_conf still works with no variant overrides set"
grep -qx 'ruby=' "$conf" \
  && pass "an unset variant leaves the version lists empty" \
  || fail "an unset variant leaves the version lists empty"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-integration-lib.sh`
Expected: FAIL on the first two assertions — the conf has `ruby=` (emptied by `minimal-conf.sh`), not `ruby=3.3.6,3.4.5`.

- [ ] **Step 3: Implement**

Replace `launcher_conf` (`lib.sh:312`):

```bash
launcher_conf() {  # $*=key=value overrides (the variant's are added first, automatically)
  local f="$IT_LAUNCH_HOME/sandbox.conf"
  # $IT_VARIANT_OVERRIDES comes FIRST so a case's own argument for the same key
  # wins — minimal-conf.sh applies overrides in order. A case never has to state
  # the variant's overrides, which is the point: it cannot forget them, and the
  # image config and the launcher config cannot drift apart.
  bash "$IT_LIB_DIR/minimal-conf.sh" "$IT_REPO_DIR/sandbox.conf" \
      ${IT_VARIANT_OVERRIDES:-} "$@" > "$f" \
    || { fail "launcher_conf: could not derive a minimal sandbox.conf"; return 1; }
  export SANDBOX_CONF="$f"
  return 0
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-integration-lib.sh`
Expected: PASS on all five new assertions.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/lib.sh tests/test-integration-lib.sh
git commit -m "test(integration): launcher_conf folds in the variant's overrides"
```

---

### Task 4: the `multiruby` capability and `IT_RUBY_VERSIONS`

**Files:**
- Modify: `tests/integration/run.sh` (`detect_caps`, `run.sh:176`)
- Test: `tests/test-integration-runner.sh`

**Interfaces:**
- Consumes: `IT_RUBY_VERSIONS` (Task 1), `have_cap` / `detect_caps` (existing).
- Produces: capability `multiruby`, present iff `IT_RUBY_VERSIONS` names two or more versions.

- [ ] **Step 1: Write the failing tests**

```bash
# ── multiruby capability ───────────────────────────────────────────────────────
# 750 has nothing to select between when one version is configured, so it must
# SKIP BY NAME rather than pass by testing a one-element list. Derived from the
# resolved IT_RUBY_VERSIONS — a hardcoded `true` here would be exactly the
# decorative check this suite exists to eliminate.
probe_out="$(IT_RUBY_VERSIONS=3.3.6,3.4.5 bash "$TMP/callfn.sh" probe_multiruby; echo "rc=$?")"
case "$probe_out" in *rc=0*) pass "multiruby is present with two versions" ;;
                     *)      fail "multiruby is present with two versions ($probe_out)" ;; esac

probe_out="$(IT_RUBY_VERSIONS=3.4.5 bash "$TMP/callfn.sh" probe_multiruby; echo "rc=$?")"
case "$probe_out" in *rc=1*) pass "multiruby is absent with one version" ;;
                     *)      fail "multiruby is absent with one version ($probe_out)" ;; esac

probe_out="$(IT_RUBY_VERSIONS= bash "$TMP/callfn.sh" probe_multiruby; echo "rc=$?")"
case "$probe_out" in *rc=1*) pass "multiruby is absent with an empty version list" ;;
                     *)      fail "multiruby is absent with an empty version list ($probe_out)" ;; esac

grep -q 'probe_multiruby && c="$c multiruby"' "$RUNNER" \
  && pass "detect_caps registers multiruby" \
  || fail "detect_caps registers multiruby — the probe exists but nothing calls it"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-integration-runner.sh`
Expected: FAIL — `probe_multiruby: command not found`.

- [ ] **Step 3: Implement**

Add beside the other probes (after `probe_launcher`, `run.sh:229`):

```bash
probe_multiruby() {
  # Read from the resolved list, never assumed. With one version configured,
  # 750-ruby-multiversion-selection has nothing to select between and must skip
  # by name — a case that "passes" against a one-element list is a case that
  # tests nothing.
  case "$IT_RUBY_VERSIONS" in *,*) return 0 ;; *) return 1 ;; esac
}
```

In `detect_caps`, add the registration **outside** the `docker image inspect` gate that wraps `probe_netadmin`/`probe_launcher` — this probe needs no image:

```bash
  probe_multiruby && c="$c multiruby"
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-integration-runner.sh`
Expected: PASS on all four.

- [ ] **Step 5: Confirm `--list-caps` reports it**

Run: `bash tests/integration/run.sh --list-caps`
Expected: the printed capability list includes `multiruby` (this machine has no Docker daemon, so `netadmin`/`launcher` will be absent — that is correct and not a failure).

- [ ] **Step 6: Commit**

```bash
git add tests/integration/run.sh tests/test-integration-runner.sh
git commit -m "test(integration): multiruby capability derived from IT_RUBY_VERSIONS"
```

---

### Task 5: `dump_blocked_forensics` — lift Phase 3's correlation into the harness

**Files:**
- Modify: `tests/integration/lib.sh` (add function; call from `it_diagnose`, `lib.sh:599`)
- Test: `tests/test-integration-lib.sh`

**Interfaces:**
- Produces: `dump_blocked_forensics <cid>` — prints, for each hard-blocked entry, the IP/port/count/first-timestamp from `blocked.log`, whether the name is in the image's baked allowlist, and every name the container's DNS map maps to that address.
- Consumed by: `it_diagnose` (existing failure path).

**Why this task exists:** Phase 3 is being deleted in Task 11, and it carries the only tooling that can answer the `repo1.maven.org` class of question — which took two verification rounds and three intermediate PRs to settle. Both tables it reads die with the container (`/run/agent-blocked-internal/dns-map.txt` is a root-only tmpfs; `/tmp/allowlist-domains.txt` is an image file), so the read must happen while the container lives.

- [ ] **Step 1: Write the failing test**

The correlation logic is pure text processing, so test it against fixture files rather than a container. Append to `tests/test-integration-lib.sh`:

```bash
# ── dump_blocked_forensics ─────────────────────────────────────────────────────
# The reverse-mapped NAME can be wrong on a shared CDN address; the IP and port
# cannot. A report that prints only the name is unfalsifiable — that is what made
# repo1.maven.org unexplainable across two verification rounds.
fx="$TMP/forensics"; mkdir -p "$fx"
cat > "$fx/blocked.log" <<'EOF'
# blocked destinations
2026-08-10T04:00:01 tcp 203.0.113.9 443 repo1.maven.org
2026-08-10T04:00:03 tcp 203.0.113.9 443 repo1.maven.org
2026-08-10T04:00:09 tcp 198.51.100.4 443 (auto-allowed) api.anthropic.com
EOF
printf 'repo1.maven.org\n' > "$fx/blocked-domains.txt"
printf '203.0.113.9 repo1.maven.org\n203.0.113.9 jruby.example\n' > "$fx/dns-map.txt"
printf 'api.anthropic.com\nregistry.npmjs.org\n' > "$fx/allowlist.txt"

out="$(forensics_report "$fx/blocked.log" "$fx/blocked-domains.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"

grep -q '203\.0\.113\.9' <<< "$out" \
  && pass "forensics prints the destination IP, which cannot be mis-attributed" \
  || fail "forensics prints the destination IP"
grep -qE 'x2|2 ' <<< "$out" \
  && pass "forensics prints the hit count" \
  || fail "forensics prints the hit count"
grep -qi 'allowlisted in this image: no' <<< "$out" \
  && pass "forensics states the allowlist verdict for the blocked name" \
  || fail "forensics states the allowlist verdict"
grep -q 'jruby.example' <<< "$out" \
  && pass "forensics lists EVERY name mapped to the address, so a CDN collision is visible" \
  || fail "forensics lists every name mapped to the address"
grep -q 'api.anthropic.com' <<< "$out" \
  && pass "forensics reports the self-healed entry separately from the hard block" \
  || fail "forensics reports the self-healed entry"

# The header comments in every output file are NOT entries. init_output_files
# seeds them, and counting them as destinations once reported a clean run as
# HARD-BLOCKED and listed the headers as the addresses.
printf '# blocked destinations\n#\n' > "$fx/empty-domains.txt"
out="$(forensics_report "$fx/blocked.log" "$fx/empty-domains.txt" \
        "$fx/dns-map.txt" "$fx/allowlist.txt" 2>&1)"
grep -qi 'hard-blocked' <<< "$out" \
  && fail "a comments-only blocked-domains.txt must not report a hard block" \
  || pass "a comments-only blocked-domains.txt reports no hard block"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-integration-lib.sh`
Expected: FAIL — `forensics_report: command not found`.

- [ ] **Step 3: Implement the pure function**

Add to `lib.sh`. Split deliberately: `forensics_report` is pure (four file paths in, text out) and therefore testable without a daemon; `dump_blocked_forensics` is the thin container-reading wrapper.

```bash
forensics_report() {  # $1=blocked.log $2=blocked-domains/ips $3=dns-map $4=baked allowlist
  local blog="$1" bdom="$2" dmap="$3" allow="$4"
  local hard; hard="$(it_strip_comments < "$bdom" 2>/dev/null | sort -u)"
  local healed
  healed="$(grep '(auto-allowed)' "$blog" 2>/dev/null | awk '{print $NF, $(NF-1)}' | sort -u | head -20)"

  if [[ -n "$hard" ]]; then
    printf '   HARD-BLOCKED by the firewall (never admitted):\n'
    local what ip names
    while IFS= read -r what; do
      [[ -z "$what" ]] && continue
      # Match the domain column ($5) or the IP column ($3): blocked-ips.txt
      # entries are bare IPs with no domain. Timestamps carry no space, so the
      # columns are stable.
      awk -v want="$what" '
        $3 == want || $5 == want {
          key = $3 " " $4
          if (!(key in seen)) { first[key] = $1; order[++n] = key }
          seen[key]++
        }
        END {
          if (n == 0) { printf "     %-38s (no matching line in blocked.log)\n", want; exit }
          for (i = 1; i <= n; i++) {
            k = order[i]
            printf "     %-38s %-24s x%-4d first %s\n", want, k, seen[k], first[k]
          }
        }' "$blog" 2>/dev/null

      if grep -qxF "$what" "$allow" 2>/dev/null; then
        printf '       allowlisted in this image: YES — a self-healing or refresh-timing\n'
        printf '                                       failure, not policy\n'
      else
        printf '       allowlisted in this image: no\n'
      fi

      # Every name the DNS map holds for the addresses this entry was dropped
      # on. More than one means the label above is a coin flip between them.
      for ip in $(awk -v want="$what" '$3 == want || $5 == want {print $3}' "$blog" 2>/dev/null | sort -u); do
        names="$(awk -v ip="$ip" '$1 == ip {print $2}' "$dmap" 2>/dev/null | sort -u | tr '\n' ' ')"
        printf '       names resolved to %-18s %s\n' "$ip" \
          "${names:-(none — the container never resolved this address)}"
      done
    done <<< "$hard"
    printf '   ^ the NAME is reverse-mapped from the IP and can be wrong on a shared\n'
    printf '     CDN address; the IP and port cannot. Confirm before allowlisting.\n'
  fi

  if [[ -n "$healed" ]]; then
    printf '   dropped then SELF-HEALED (allowlisted, admitted after the first packet):\n'
    printf '%s\n' "$healed" | sed 's/^/     /'
  fi

  if [[ -z "$hard" && -z "$healed" ]]; then
    # Only a RUNNING capture licenses "nothing was dropped". With a dead daemon
    # the honest answer is that we do not know.
    if [[ -f "$blog" ]]; then
      printf '   firewall dropped nothing\n'
    else
      printf '   what the firewall dropped is UNKNOWN — the capture never ran\n'
    fi
  fi
}
```

Confirm the column indices against the real writer before finalising: read `capture-blocked-traffic.sh`'s `log_blocked()` and match `$3`/`$4`/`$5` to the fields it actually writes. If they differ, fix the awk and the fixture together — the fixture must mirror the real format, or this tests a format nothing produces.

- [ ] **Step 4: Implement the container-reading wrapper and wire it in**

```bash
dump_blocked_forensics() {  # $1=cid — MUST run while the container is alive
  local cid="$1" d; d="$(it_scratch)"
  # Both tables die with the container: the DNS map lives in a root-only tmpfs
  # (/run/agent-blocked-internal) and the baked allowlist is an image file. Read
  # them now or lose the only evidence that can settle a mis-attributed name.
  docker exec "$cid" cat /run/agent-blocked-internal/dns-map.txt > "$d/dns-map.txt" 2>/dev/null || : > "$d/dns-map.txt"
  docker exec "$cid" cat /tmp/allowlist-domains.txt 2>/dev/null \
    | it_strip_comments > "$d/allowlist.txt" || : > "$d/allowlist.txt"
  local f
  for f in blocked.log blocked-domains.txt blocked-ips.txt; do
    docker exec "$cid" cat "/workspace/.agent-blocked/$f" > "$d/$f" 2>/dev/null || : > "$d/$f"
  done
  cat "$d/blocked-ips.txt" >> "$d/blocked-domains.txt" 2>/dev/null || true
  printf '   ── blocked-traffic forensics ──\n'
  forensics_report "$d/blocked.log" "$d/blocked-domains.txt" "$d/dns-map.txt" "$d/allowlist.txt"
}
```

Add the call at the end of `it_diagnose` (`lib.sh:599`), after the capture-dirs block:

```bash
  dump_blocked_forensics "$1"
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test-integration-lib.sh`
Expected: PASS on all six new assertions.

- [ ] **Step 6: Commit**

```bash
git add tests/integration/lib.sh tests/test-integration-lib.sh
git commit -m "test(integration): blocked-traffic forensics for every restricted case"
```

---

### Task 6: Ruby group constant and readiness wait

**Files:**
- Modify: `tests/integration/lib.sh`
- Test: `tests/test-integration-lib.sh`

**Interfaces:**
- Produces:
  - `IT_RUBY_GROUP` — the shared group name (`itruby`) whose rvm volume is reused across cases in one run
  - `ruby_wait_ready <cid> <timeout-seconds>` → 0 when the reconcile finished, 1 on failure or timeout
  - `assert_runs <cid> <binary>` → asserts the binary is on `PATH` **and executes**

**Design note — the spec's `ruby_group_warm` reduces to this.** `rvm_volume_name` uses `$repo_volume_prefix`, which `fixture_scope_init` sets to `it-$IT_RUN_ID`, so the rvm volume for a given group name is already shared across every case in one run — the volume does the warming implicitly. And `run.sh` runs cases serially, so there is no concurrency for a `flock` to guard. What remains is a stable group name and a readiness wait. Do not add the lock; a mechanism with nothing to guard against is a mechanism that will be maintained forever for no reason.

- [ ] **Step 1: Write the failing tests**

```bash
# ── ruby_wait_ready ────────────────────────────────────────────────────────────
# A failed bootstrap exits in SECONDS. Polling only for `ruby` on PATH burned the
# full timeout on a compile that never started, which is why the reconcile's own
# terminal lines are part of the condition.
check "IT_RUBY_GROUP is a stable name shared across cases in one run" \
  "itruby" "$IT_RUBY_GROUP"

# The predicate, tested against captured log text rather than a live container.
_ruby_reconcile_done <<< '[rvm-reconcile] done.' \
  && pass "ruby readiness recognises a completed reconcile" \
  || fail "ruby readiness recognises a completed reconcile"
_ruby_reconcile_done <<< '[rvm-reconcile] FAILED: ruby-3.4.5' \
  && pass "ruby readiness recognises a FAILED reconcile (does not wait out the timeout)" \
  || fail "ruby readiness recognises a FAILED reconcile"
_ruby_reconcile_done <<< '[rvm-reconcile] installing ruby-3.4.5…' \
  && fail "an in-progress reconcile must not be reported ready" \
  || pass "an in-progress reconcile is not reported ready"

# `done.` and `FAILED:` are not the same outcome even though both end the wait.
_ruby_reconcile_ok <<< '[rvm-reconcile] done.' \
  && pass "a completed reconcile is distinguished from a failed one" \
  || fail "a completed reconcile is distinguished from a failed one"
_ruby_reconcile_ok <<< '[rvm-reconcile] FAILED: ruby-3.4.5' \
  && fail "FAILED must not be reported as success" \
  || pass "FAILED is not reported as success"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-integration-lib.sh`
Expected: FAIL — `IT_RUBY_GROUP: unbound variable` and `_ruby_reconcile_done: command not found`.

- [ ] **Step 3: Implement**

```bash
# The rvm volume is named it-$IT_RUN_ID-rvm-<group> (rvm_volume_name, via the
# REPO_VOLUME_PREFIX fixture_scope_init exports), so every case using this group
# name in one run shares one compiled Ruby home. The first case to launch pays
# the compile; the rest are instant. No lock: run.sh runs cases serially, and a
# case that runs alone simply pays it itself.
#
# 740 deliberately uses its OWN group. Bootstrapping from cold is what it tests.
IT_RUBY_GROUP="${IT_RUBY_GROUP:-itruby}"

_ruby_reconcile_done() { grep -qE '\[rvm-reconcile\] (done\.|FAILED:)'; }
_ruby_reconcile_ok()   { grep -q '\[rvm-reconcile\] done\.'; }

ruby_wait_ready() {  # $1=cid $2=timeout seconds
  local cid="$1" deadline=$(( SECONDS + ${2:-1800} )) logs
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    logs="$(docker logs "$cid" 2>&1)"
    if _ruby_reconcile_done <<< "$logs"; then
      _ruby_reconcile_ok <<< "$logs" && return 0
      fail "ruby_wait_ready: the reconcile reported FAILED"
      printf '%s\n' "$logs" | grep -i 'rvm-reconcile' | tail -20 | sed 's/^/     /'
      return 1
    fi
    docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true || {
      fail "ruby_wait_ready: the container exited before the reconcile finished"
      return 1
    }
    sleep 10
  done
  fail "ruby_wait_ready: timed out after ${2:-1800}s"
  return 1
}

assert_runs() {  # $1=cid $2=binary — on PATH AND executes
  local out
  if ! docker exec "$1" bash -c "command -v $2 >/dev/null 2>&1"; then
    fail "$2 is on PATH"
    return 1
  fi
  # Capture first, head afterwards. `if out="$(cmd | head -1)"` reports HEAD's
  # status, and head succeeds on the empty output of a binary that just died —
  # which made the equivalent check in verify-on-host.sh Phase 3 unreachable for
  # the whole time it existed.
  if out="$(docker exec "$1" bash -c "$2 --version 2>&1")"; then
    pass "$2 runs: $(printf '%s\n' "$out" | head -1)"
    return 0
  fi
  fail "$2 is present but FAILED TO RUN"
  docker exec "$1" bash -c \
    "p=\$(command -v $2); printf '     path:    %s -> %s\n' \"\$p\" \"\$(readlink -f \"\$p\")\";
     printf '     shebang: %s\n' \"\$(head -1 \"\$(readlink -f \"\$p\")\" 2>/dev/null)\"" 2>&1
  printf '     error:   %s\n' "$(printf '%s\n' "$out" | head -1)"
  return 1
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/run-all.sh`
Expected: 39/39.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/lib.sh tests/test-integration-lib.sh
git commit -m "test(integration): Ruby group constant, reconcile readiness, assert_runs"
```

---

### Task 7: Cases 700, 710, 720 — the `agents` variant

**Files:**
- Create: `tests/integration/cases/700-agent-tools-install-restricted.sh`
- Create: `tests/integration/cases/710-agent-tools-reused-not-reinstalled.sh`
- Create: `tests/integration/cases/720-node-multiversion-nvm-use.sh`

**Interfaces:**
- Consumes: `sandbox_up`, `sandbox_exec`, `sandbox_down`, `agent_exec`, `launcher_up`, `launcher_conf`, `fixture_scope_init`, `assert_runs` (Task 6), `pass`/`fail`/`it_finish`, `allowlist_write`.

- [ ] **Step 1: Write case 700**

```bash
#!/usr/bin/env bash
# summary:  all six agent-tier tools install behind the restricted firewall and
#           resolve in a NON-login shell
# tags:     packages security slow needs-external
# requires: docker netadmin
# image:    agents
#
# THIS IS THE BLOCKING GATE. Nothing agent-tier is baked into the image: Copilot,
# Claude Code, Codex, Gemini, graphify and vale install at container start into a
# group-mounted ~/.ai-tools. So "the image built" says nothing about whether the
# tools exist — the install happens later, over the network, THROUGH the
# restricted firewall, and a missing allowlist fragment breaks it silently.
#
# Non-login resolution is asserted separately because it has its own provider:
# link-agent-tools.sh symlinks each binary onto /usr/local/bin so
# `docker exec -T … bash -c "claude …"` works. PATH from /etc/profile.d only
# covers login and interactive shells, which is not how an agent is driven.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=agenttools
launcher_up restricted || it_finish

# The reconcile is install-if-missing and non-fatal on failure, so poll for the
# binaries rather than for an exit code that is always 0.
it_wait 900 bash -c "docker exec '$IT_CID' bash -c 'command -v claude >/dev/null'" \
  || fail "the agent-tools reconcile did not finish within 900s"

for b in claude codex gemini copilot graphify vale; do
  assert_runs "$IT_CID" "$b"
done

# NON-login, NON-interactive: the shape `docker exec -T … bash -c` produces, and
# the one PATH-from-profile does not cover.
for b in claude codex gemini copilot graphify vale; do
  if docker exec "$IT_CID" bash -c "command -v $b >/dev/null 2>&1"; then
    pass "$b resolves in a non-login shell (link-agent-tools.sh)"
  else
    fail "$b resolves in a non-login shell — installed but not linked onto /usr/local/bin"
  fi
done

it_finish
```

- [ ] **Step 2: Write case 710**

```bash
#!/usr/bin/env bash
# summary:  a second container in the same group reuses ~/.ai-tools instead of
#           re-downloading every agent-tier tool
# tags:     packages slow needs-external
# requires: docker launcher
# image:    agents
#
# The whole reason ~/.ai-tools is group-mounted rather than baked. If reuse
# breaks, nothing FAILS — every container just pays a full six-tool network
# install at every start, which looks like slowness rather than a bug and would
# never be noticed. Asserting the effect (no install lines the second time)
# rather than the mount configuration is what makes it observable.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=agentreuse

launcher_up restricted || it_finish
it_wait 900 bash -c "docker exec '$IT_CID' bash -c 'command -v claude >/dev/null'" \
  || { fail "first container never finished installing"; it_finish; }
first="$IT_CID"
docker logs "$first" 2>&1 | grep -q 'agent-tools-reconcile' \
  && pass "the first start ran the reconcile" \
  || fail "the first start ran the reconcile"
docker rm -f "$first" >/dev/null 2>&1 || true

launcher_up restricted || it_finish
it_wait 120 bash -c "docker exec '$IT_CID' bash -c 'command -v claude >/dev/null'" \
  || fail "the second container did not have the tools available within 120s"

# `npm install -g` prints its added-package summary only when it actually
# installs. Its absence on the second start is the evidence of reuse.
if docker logs "$IT_CID" 2>&1 | grep -qE 'added [0-9]+ package'; then
  fail "the second start RE-INSTALLED — ~/.ai-tools was not reused"
  docker logs "$IT_CID" 2>&1 | grep -E 'added [0-9]+ package' | head -5 | sed 's/^/     /'
else
  pass "the second start reused ~/.ai-tools (no npm install occurred)"
fi
assert_runs "$IT_CID" claude

it_finish
```

- [ ] **Step 3: Write case 720**

```bash
#!/usr/bin/env bash
# summary:  nvm can still switch Node versions once ~/.ai-tools holds the
#           agent-tier npm packages
# tags:     packages needs-external
# requires: docker launcher
# image:    agents
#
# The regression this exists for shipped: /etc/skel/.npmrc carried
# `prefix=${HOME}/.ai-tools/npm`, and nvm's nvm_die_on_prefix check FAILS
# `nvm use <version>` outright rather than warning — so the multi-version
# node=22,20 workflow sandbox.conf advertises was broken by the agent-tier tool
# home. The fix passes --prefix per invocation instead, because nvm inspects
# .npmrc/$PREFIX/$NPM_CONFIG_PREFIX and never a command's own flags.
#
# Needs a SECOND version to switch to, which is why the agents variant sets
# node=22,20. With only the LTS installed this case would pass against a
# one-element list.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=nodemulti
launcher_up restricted || it_finish
it_wait 900 bash -c "docker exec '$IT_CID' bash -c 'command -v claude >/dev/null'" \
  || fail "the agent-tools reconcile did not finish within 900s"

for v in 20 22; do
  if out="$(agent_exec "$IT_CID" "source /etc/bash.bashrc >/dev/null 2>&1; nvm use $v 2>&1")"; then
    pass "nvm use $v succeeds with ~/.ai-tools populated: $(printf '%s\n' "$out" | tail -1)"
  else
    fail "nvm use $v FAILED — a baked npm prefix breaks nvm outright, it does not warn"
    printf '%s\n' "$out" | tail -5 | sed 's/^/     /'
  fi
done

# The mechanism, asserted directly: no npm prefix may be set anywhere nvm looks.
if agent_exec "$IT_CID" 'test -f "$HOME/.npmrc" && grep -q "^prefix=" "$HOME/.npmrc"'; then
  fail "~/.npmrc sets a prefix — this is exactly what trips nvm_die_on_prefix"
else
  pass "~/.npmrc sets no prefix"
fi

it_finish
```

- [ ] **Step 4: Syntax-check and confirm the headers parse**

```bash
for f in tests/integration/cases/7[0-2]0-*.sh; do bash -n "$f" || echo "SYNTAX: $f"; done
bash tests/integration/run.sh --list | grep -E '^7[0-2]0'
```

Expected: no syntax errors, and three lines showing the right `tags:`/`requires:`.

- [ ] **Step 5: Verify the exec bits**

Run: `bash tests/test-exec-bits.sh`
Expected: PASS. If it fails, `chmod +x` the three new case files.

- [ ] **Step 6: Commit**

```bash
git add tests/integration/cases/700-*.sh tests/integration/cases/710-*.sh tests/integration/cases/720-*.sh
git commit -m "test(integration): agent-tier install, reuse and nvm multi-version cases"
```

---

### Task 8: Case 730 — native clients

**Files:**
- Create: `tests/integration/cases/730-native-clients-run.sh`

**Interfaces:**
- Consumes: `sandbox_up`/`launcher_up`, `assert_runs` (Task 6).

- [ ] **Step 1: Write the case**

```bash
#!/usr/bin/env bash
# summary:  the db clients and native image tools are present AND actually run
# tags:     packages slow needs-external
# requires: docker launcher
# image:    native
#
# The wkhtmltopdf layer installs a JAMMY .deb on an ubuntu:24.04 (noble) base and
# pre-installs libjpeg-turbo8 by hand. That combination is the fragile one, and a
# .deb that installs cleanly can still produce a binary that cannot resolve its
# libraries — so PRESENCE is not the assertion, EXECUTION is.
#
# gcc is in the list because KEEP_BUILD_TOOLCHAIN=1 is what keeps it: db-clients
# and ruby both set it, and native extensions compile at RUNTIME. If the
# Dockerfile started stripping the toolchain again despite the flag, every gem
# with a C extension would break at container start and nothing else here would
# notice.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP=nativetools
launcher_up restricted || it_finish

for b in psql mysql mongosh convert wkhtmltopdf gcc; do
  assert_runs "$IT_CID" "$b"
done

it_finish
```

- [ ] **Step 2: Confirm each binary answers `--version`**

Some of these do not. Check before relying on it:

```bash
grep -n "convert\|wkhtmltopdf" verify-on-host.sh | head
```

Phase 2 used `--version` for all six and reported real version strings in past logs, so `--version` is correct for this set. If a CI run shows one of them exiting non-zero on `--version` despite working, change `assert_runs` to accept a per-binary probe argument rather than weakening the assertion for all six.

- [ ] **Step 3: Syntax and listing check**

```bash
bash -n tests/integration/cases/730-native-clients-run.sh
bash tests/integration/run.sh --list | grep '^730'
bash tests/test-exec-bits.sh
```

- [ ] **Step 4: Commit**

```bash
git add tests/integration/cases/730-native-clients-run.sh
git commit -m "test(integration): native clients are present and runnable"
```

---

### Task 9: Cases 740, 750, 760 — Ruby

**Files:**
- Create: `tests/integration/cases/740-ruby-bootstraps-and-resolves.sh`
- Create: `tests/integration/cases/750-ruby-multiversion-selection.sh`
- Create: `tests/integration/cases/760-ruby-persists-no-recompile.sh`

**Interfaces:**
- Consumes: `launcher_up`, `ruby_wait_ready`, `assert_runs`, `IT_RUBY_GROUP` (Task 6), `IT_RUBY_VERSIONS` (Task 1).

- [ ] **Step 1: Write case 740**

```bash
#!/usr/bin/env bash
# summary:  rvm bootstraps and compiles behind the restricted firewall, and the
#           default Ruby's binstubs EXECUTE in a non-login shell
# tags:     packages security slow needs-external
# requires: docker netadmin launcher
# image:    native
#
# This case is the reason increment 3 exists. verify-on-host.sh Phase 3 asserted
# the same property by composing its own `docker run`, and therefore kept
# bind-mounting ~/.rvm for two full verification rounds after the named-volume
# fix landed: it re-implemented what the product does instead of calling it.
# launcher_up drives the REAL sandbox.sh, so rvm_volume_ensure, the group
# resolution and the mount decisions are exercised as the product performs them.
#
# Its OWN group, not IT_RUBY_GROUP: bootstrapping from cold is the thing under
# test, and a warm shared volume would make it assert nothing.
#
# `bundle` executing is a separate assertion from `bundle` resolving. rvm
# rewrites gem binstub shebangs to `#!/usr/bin/env ruby_executable_hooks`, so a
# perfectly linked bundle can still die on exec — and the Phase 3 check written
# for exactly that could never fire, because it tested `head`'s exit status.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="itruby-cold-$$"
launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 1800 || { it_diagnose "$IT_CID"; it_finish; }

# link-default-ruby.sh's contract, verbatim: ruby/gem/bundle/rake/irb onto
# /usr/local/bin so a NON-login shell resolves them. `bundler` is deliberately
# absent from this list — it is not in that set, and requiring it would report a
# bug against a contract nothing makes.
for b in ruby gem bundle rake irb; do
  assert_runs "$IT_CID" "$b"
done

# The configured default must be the version that is actually installed. A
# reconcile that fails partway must never point the default at a missing
# version — it logs FAILED: ruby-<v> instead.
want="${IT_RUBY_VERSIONS##*,}"
if out="$(docker exec "$IT_CID" bash -c 'ruby -e "print RUBY_VERSION"' 2>&1)"; then
  if [[ "$out" == "$want" ]]; then
    pass "the default ruby is the configured default ($want)"
  else
    fail "the default ruby is $out, expected $want"
  fi
else
  fail "ruby could not report its version: $out"
fi

it_finish
```

- [ ] **Step 2: Write case 750**

```bash
#!/usr/bin/env bash
# summary:  every configured Ruby version is installed, and .ruby-version selects
#           a non-default one
# tags:     packages slow needs-multiruby
# requires: docker launcher multiruby
# image:    native
#
# ruby= is a comma-separated LIST precisely so a project can migrate between
# versions, and per-project selection comes from .ruby-version via a login shell.
# Installing only the default would satisfy every other Ruby case here.
#
# requires: multiruby — with one version configured there is nothing to select
# between, and this case must SKIP BY NAME rather than pass against a
# one-element list. The nightly may drop to a single version on cost; see
# nightly.yml.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"
launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 1800 || { it_diagnose "$IT_CID"; it_finish; }

installed="$(docker exec "$IT_CID" bash -lc 'rvm list strings 2>/dev/null' | tr -d '\r')"
IFS=',' read -r -a want <<< "$IT_RUBY_VERSIONS"
for v in "${want[@]}"; do
  if grep -q "ruby-$v" <<< "$installed"; then
    pass "ruby-$v is installed"
  else
    fail "ruby-$v is installed — rvm list: $(tr '\n' ' ' <<< "$installed")"
  fi
done

# Selection: the NON-default version, chosen through .ruby-version the way a
# project does it. IT_RUBY_VERSIONS' last element is the default.
other="${IT_RUBY_VERSIONS%%,*}"
docker exec "$IT_CID" bash -c "mkdir -p /tmp/proj && printf '%s\n' '$other' > /tmp/proj/.ruby-version"
if out="$(docker exec "$IT_CID" bash -lc 'cd /tmp/proj && ruby -e "print RUBY_VERSION"' 2>&1)"; then
  if [[ "$out" == "$other" ]]; then
    pass ".ruby-version selects the non-default version ($other)"
  else
    fail ".ruby-version selected $out, expected $other"
  fi
else
  fail "ruby failed to run under .ruby-version: $out"
fi

it_finish
```

- [ ] **Step 3: Write case 760**

```bash
#!/usr/bin/env bash
# summary:  a second launch in the same group reuses the compiled rubies instead
#           of recompiling
# tags:     packages slow
# requires: docker launcher
# image:    native
#
# The property the whole group-scoped rvm volume exists for. When it breaks,
# nothing FAILS — every container start just recompiles Ruby, which reads as
# slowness rather than a bug, on a machine where a Ruby compile is expected to
# take minutes anyway. That is the shape of defect this suite exists to make
# observable.
#
# Two launches of its own, so the case is self-contained and order-independent:
# whether another case already warmed IT_RUBY_GROUP changes the wall-clock, not
# the assertion.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish
export AI_CONTAINER_GROUP="$IT_RUBY_GROUP"

launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 1800 || { it_diagnose "$IT_CID"; it_finish; }
first="$IT_CID"
docker rm -f "$first" >/dev/null 2>&1 || true

launcher_up restricted || it_finish
ruby_wait_ready "$IT_CID" 300 \
  || { fail "the second launch did not settle within 300s — it is recompiling"; it_diagnose "$IT_CID"; it_finish; }

# rvm prints its install banner only when it actually installs. Its absence is
# the evidence; asserting on elapsed time would be a flaky proxy for it.
if docker logs "$IT_CID" 2>&1 | grep -qE 'Installing Ruby from source|rvm install'; then
  fail "the second launch RECOMPILED — the group's rvm volume was not reused"
  docker logs "$IT_CID" 2>&1 | grep -iE 'rvm-reconcile|Installing Ruby' | tail -10 | sed 's/^/     /'
else
  pass "the second launch reused the group's compiled rubies"
fi
assert_runs "$IT_CID" ruby

it_finish
```

- [ ] **Step 4: Syntax, listing and exec-bit checks**

```bash
for f in tests/integration/cases/7[4-6]0-*.sh; do bash -n "$f" || echo "SYNTAX: $f"; done
bash tests/integration/run.sh --list | grep -E '^7[4-6]0'
bash tests/test-exec-bits.sh
bash tests/run-all.sh
```

Expected: no syntax errors; three cases listed with the right metadata; 39/39.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/cases/740-*.sh tests/integration/cases/750-*.sh tests/integration/cases/760-*.sh
git commit -m "test(integration): Ruby bootstrap, multi-version selection and persistence"
```

---

### Task 10: Batched mutation demonstrations — `mutate.sh` multi-apply and a nightly `tags` input

**Files:**
- Modify: `tests/integration/mutate.sh`
- Modify: `tests/test-mutations.sh`
- Modify: `.github/workflows/nightly.yml`

**Interfaces:**
- Produces: `mutate.sh apply <id> [<id>…]` — applies several patches in one go; `.applied` holds one id per line; `revert` reverses them in **reverse order**.
- Produces: `nightly.yml` `workflow_dispatch` inputs `tags` and `exclude`, both defaulting to today's behaviour.

**Why this task exists.** Seven mutations demonstrated one-per-run costs seven
full nightly dispatches of up to two hours each, and the existing workflow has
no input to narrow what runs, so each demo would also re-run
`integration-full` and `allowlist-health` for nothing. Increment 2 demonstrated
its eleven mutations in **two batches** — batch A broke eight cases and left
three passing, batch B the inverse. Both halves matter: a batch that breaks
everything proves nothing about which case catches what. `mutate.sh` currently
refuses a second `apply` while one is active, so batching needs the state file
to become a list.

- [ ] **Step 1: Write the failing tests for multi-apply**

Append to `tests/test-mutations.sh`, before its final summary:

```bash
# ── Multi-apply ────────────────────────────────────────────────────────────────
# Batched demonstrations need several known-bad patches applied at once. The
# state file becomes a LIST, and revert must reverse in the opposite order —
# two patches touching the same file apply cleanly forwards and conflict
# backwards if reversed in the order they were applied.
out="$(bash "$MUTATE" apply 400-ro-suffix-dropped no-such-mutation 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'no such mutation' <<< "$out"; then
  pass "multi-apply rejects the whole batch when any id is unknown"
else
  fail "multi-apply rejects the whole batch when any id is unknown (rc=$rc)"
fi
if [[ ! -f "$MUT_DIR/.applied" ]]; then
  pass "a rejected batch applies nothing (no state file left behind)"
else
  fail "a rejected batch applies nothing — .applied exists after a refused batch"
  bash "$MUTATE" revert >/dev/null 2>&1
fi

grep -q 'apply <id>\.\.\.' "$MUTATE" || grep -q 'apply.*\[<id>' "$MUTATE" \
  && pass "usage documents multi-apply" \
  || fail "usage documents multi-apply"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-mutations.sh`
Expected: FAIL on the batch-rejection assertions — today `cmd_apply` reads only
`$1` and silently ignores the rest, so a batch with a bad id applies the good
one and reports success.

- [ ] **Step 3: Implement multi-apply**

Rewrite `cmd_apply` and `cmd_revert` in `tests/integration/mutate.sh`:

```bash
cmd_apply() {  # $@ = one or more mutation ids
  [[ "$#" -gt 0 ]] || { printf 'mutate.sh: apply needs at least one mutation id (see `list`)\n' >&2; exit 2; }
  local id
  # Validate the WHOLE batch before touching the tree. A batch that applies
  # three patches and then rejects the fourth leaves a state no one asked for,
  # and the demonstration it was meant to produce is silently a different one.
  for id in "$@"; do
    [[ -f "$MUT_DIR/$id.patch" ]] || { printf 'mutate.sh: no such mutation: %s\n' "$id" >&2; exit 2; }
  done
  if [[ -f "$STATE" ]]; then
    printf 'mutate.sh: still applied — revert first:\n' >&2
    sed 's/^/  /' "$STATE" >&2
    exit 1
  fi
  if ! ( cd "$GIT_ROOT" && git diff --quiet ); then
    printf 'mutate.sh: the working tree has unstaged changes — commit or stash first.\n' >&2
    printf '           A mutation must be the only difference, or reverting it is a guess.\n' >&2
    exit 1
  fi
  for id in "$@"; do
    git_apply "$MUT_DIR/$id.patch" || {
      printf 'mutate.sh: %s no longer applies. The code it breaks has changed; regenerate it.\n' "$id" >&2
      # Roll back what this batch already applied, newest first, so the tree is
      # left exactly as found rather than half-mutated.
      if [[ -f "$STATE" ]]; then
        local done_id
        while IFS= read -r done_id; do
          [[ -n "$done_id" ]] && git_apply -R "$MUT_DIR/$done_id.patch" 2>/dev/null
        done < <(tac "$STATE" 2>/dev/null || sed '1!G;h;$!d' "$STATE")
        rm -f "$STATE"
      fi
      exit 1
    }
    printf '%s\n' "$id" >> "$STATE"
    printf 'Applied %s — %s\n' "$id" "$(patch_field "$MUT_DIR/$id.patch" what)"
  done
  printf '\nNow run:  tests/integration/run.sh --reuse-image --tags <tier>\n'
  printf 'Expect these cases to FAIL, and every other case to still PASS:\n'
  for id in "$@"; do printf '  %s\n' "$(patch_field "$MUT_DIR/$id.patch" case)"; done
  printf 'Then:     tests/integration/mutate.sh revert\n'
}

cmd_revert() {
  [[ -f "$STATE" ]] || { printf 'mutate.sh: nothing applied.\n'; return 0; }
  local id
  # Reverse order. Two patches touching the same file apply cleanly forwards and
  # conflict backwards if reversed in the order they were applied.
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    git_apply -R "$MUT_DIR/$id.patch" || {
      printf 'mutate.sh: could not reverse %s cleanly. Recover with: git checkout -- <file>\n' "$id" >&2
      exit 1
    }
    printf 'Reverted %s\n' "$id"
  done < <(tac "$STATE" 2>/dev/null || sed '1!G;h;$!d' "$STATE")
  rm -f "$STATE"
}
```

`tac` is GNU-only; the `sed '1!G;h;$!d'` fallback covers stock macOS, where this
suite also runs. Update the `usage()` heredoc: `apply <id>...   apply one or
more mutations (refuses unless the tree is clean)`.

Change the dispatch arm to pass every argument:

```bash
  apply)  shift; cmd_apply "$@" ;;
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-mutations.sh`
Expected: 0 failures, including the pre-existing single-id assertions — a
single id is just a one-element batch and must keep working unchanged.

- [ ] **Step 5: Add the nightly dispatch inputs**

In `.github/workflows/nightly.yml`:

```yaml
  workflow_dispatch:
    inputs:
      tags:
        description: 'run.sh --tags for the integration jobs (empty = the whole corpus)'
        required: false
        default: ''
      exclude:
        description: 'run.sh --exclude for the integration jobs'
        required: false
        default: ''
```

Thread them into the integration and packages steps as
`${{ inputs.tags && format('--tags {0}', inputs.tags) || '' }}` and the
equivalent for `--exclude`. A scheduled run supplies neither, so its behaviour
is byte-for-byte what it is today — verify that by reading the rendered command
in a scheduled run's log, not by assuming it.

The reason this input exists belongs in a comment above it: a mutation
demonstration needs to run ONE tier against a deliberately broken tree, and
without it every demonstration also re-runs `integration-full` and
`allowlist-health` for no benefit.

- [ ] **Step 6: Verify the workflow still parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/nightly.yml'))" && echo "YAML OK"
bash tests/run-all.sh
```

Expected: `YAML OK`, and the hermetic suite green.

- [ ] **Step 7: Commit**

```bash
git add tests/integration/mutate.sh tests/test-mutations.sh .github/workflows/nightly.yml
git commit -m "test(mutations): batched demonstrations — multi-apply and a nightly tags input"
```

---

### Task 11: Seven mutations, and extend the coverage assertion

**Files:**
- Create: `tests/integration/mutations/700-agent-tools-not-linked.patch`
- Create: `tests/integration/mutations/710-ai-tools-not-group-mounted.patch`
- Create: `tests/integration/mutations/720-npmrc-prefix-restored.patch`
- Create: `tests/integration/mutations/730-toolchain-stripped.patch`
- Create: `tests/integration/mutations/740-rvm-bind-mount-restored.patch`
- Create: `tests/integration/mutations/750-only-default-ruby-installed.patch`
- Create: `tests/integration/mutations/760-rvm-volume-not-reused.patch`
- Modify: `tests/test-mutations.sh`

**Interfaces:**
- Consumes: `mutate.sh list|apply|revert|verify|check` (existing).
- Each patch carries `# case:` and `# what:` headers — `test-mutations.sh` requires both.

- [ ] **Step 1: Extend the coverage assertion to `packages`**

In `tests/test-mutations.sh`, the tag filter (line ~95):

```bash
  case " $tags " in
    *" mounts "*|*" groups "*|*" volumes "*|*" packages "*) : ;;
    *) continue ;;
  esac
```

- [ ] **Step 2: Run it and watch it fail for the right reason**

Run: `bash tests/test-mutations.sh`
Expected: FAIL, seven times — `700-agent-tools-install-restricted has a known-bad mutation — add one under tests/integration/mutations/`, and the same for 710-760. This is the mechanism working: a case with no demonstration is rejected at review time.

- [ ] **Step 3: Author each patch against the real production defect**

Each mutation must reproduce a defect that actually shipped or that the code actively prevents. Generate each with `git diff` after hand-editing, then revert the edit:

| Patch | Production file | The known-bad configuration |
|---|---|---|
| `700-agent-tools-not-linked` | `entrypoint.sh` | skip the `link-agent-tools.sh` call, so tools install but resolve only in login shells |
| `710-ai-tools-not-group-mounted` | `sandbox.sh` | drop the `~/.ai-tools` mount, so each container installs from scratch |
| `720-npmrc-prefix-restored` | `Dockerfile` | re-add `prefix=${HOME}/.ai-tools/npm` to `/etc/skel/.npmrc` — the exact regression that broke `nvm use` |
| `730-toolchain-stripped` | `build.sh` | stop setting `KEEP_BUILD_TOOLCHAIN=1` for `db-clients`, so `gcc` is stripped |
| `740-rvm-bind-mount-restored` | `sandbox.sh` | bind-mount `~/.rvm` instead of using `rvm_volume_ensure` — the pre-fix behaviour |
| `750-only-default-ruby-installed` | `rvm-reconcile.sh` | install only the last element of `RUBY_VERSIONS` |
| `760-rvm-volume-not-reused` | `sandbox-common.sh` | make `rvm_volume_name` include `$$` so every launch gets a fresh volume |

Patch file format, e.g. `700-agent-tools-not-linked.patch`:

```
# case: 700-agent-tools-install-restricted
# what: entrypoint no longer runs link-agent-tools.sh, so the tools install but
#       resolve only in login shells — a `docker exec -T … bash -c` cannot find them
diff --git a/entrypoint.sh b/entrypoint.sh
...
```

- [ ] **Step 4: Verify every patch still applies**

Run: `bash tests/integration/mutate.sh verify`
Expected: `ok` for all eighteen (eleven existing plus seven new). A `STALE` line means the patch was generated against different code — regenerate it.

- [ ] **Step 5: Run the coverage assertion**

Run: `bash tests/test-mutations.sh`
Expected: 0 failures.

- [ ] **Step 6: Demonstrate the cases failing, in CI, in two batches**

There is no local Docker daemon, so the demonstration runs on CI. Two batches,
not seven runs — and **both halves of each batch matter**: the mutated cases
must FAIL and every other packages case must still PASS. A batch that breaks
everything proves nothing about which case catches what.

Batch A — the `agents` variant plus one native:

```bash
bash tests/integration/mutate.sh apply \
  700-agent-tools-not-linked 710-ai-tools-not-group-mounted \
  720-npmrc-prefix-restored 730-toolchain-stripped
git commit -am "TEMP: mutation demo batch A — DO NOT MERGE"
git push -f origin HEAD:mutation-demo
gh workflow run nightly.yml --ref mutation-demo -f tags=packages
```

Expected: 700, 710, 720, 730 FAIL; 740, 750, 760 PASS.

Batch B — the Ruby mutations:

```bash
bash tests/integration/mutate.sh revert
bash tests/integration/mutate.sh apply \
  740-rvm-bind-mount-restored 750-only-default-ruby-installed 760-rvm-volume-not-reused
git commit -am "TEMP: mutation demo batch B — DO NOT MERGE"
git push -f origin HEAD:mutation-demo
gh workflow run nightly.yml --ref mutation-demo -f tags=packages
```

Expected: 740, 750, 760 FAIL; 700, 710, 720, 730 PASS.

Record each batch's run URL and the observed pass/fail split — they go in the
Task 11 commit message. Then:

```bash
bash tests/integration/mutate.sh revert
git reset --hard HEAD~1          # drop the TEMP commit
git push -d origin mutation-demo
git status --short               # MUST be clean before continuing
```

**The demo commits must never reach the PR branch.** A previous increment lost
two regenerated patches exactly this way — committed onto a throwaway branch,
deleted with it, while the transcript still claimed they were applied. Confirm
with `git log --oneline -1` that HEAD is the Step 5 commit, and with
`bash tests/integration/mutate.sh verify` that all eighteen patches still apply
to a clean tree.

- [ ] **Step 7: Commit**

```bash
git add tests/integration/mutations tests/test-mutations.sh
git commit -m "test(mutations): known-bad demonstrations for all seven packages cases"
```

---

### Task 12: Delete Phases 1-3 from `verify-on-host.sh`

**Files:**
- Modify: `verify-on-host.sh`
- Modify: `tests/test-verify-exit-code.sh`
- Delete: `tests/test-verify-on-host-keep.sh`
- Modify: `tests/test-verify-on-host-phase4.sh` (only if it references the deleted phases)

**Interfaces:**
- Produces: `verify-on-host.sh` with Phase 0 and Phase 4 only; `PHASES="${PHASES:-4}"`; the `phase_fail` ledger retained.

**Do this task only after Task 11 confirms every case passes in CI.** Deleting the old coverage before the new coverage is proven is the one ordering mistake with no cheap recovery.

- [ ] **Step 1: Delete the phase bodies**

Remove the `if want_phase 1; then … fi`, `if want_phase 2; then … fi` and `if want_phase 3; then … fi` blocks in full, plus the now-unused `SMOKE_CONF`/`NATIVE_CONF`/`RUBY_CONF` cleanup at the foot of the file. Update:

- the header's phase list to name only 0 and 4
- `PHASES="${PHASES:-4}"`
- the `KEEP_RUBY_IMAGE` documentation block (delete — it belonged to Phase 3)
- the closing `say "Leftover throwaway image …  docker rmi ai-sandbox-smoke"` line (delete — no such image is built any more)

Keep the failure ledger (`phase_fail`, `FAILED_PHASES`, the `RESULT:` verdict, the `exit 1`) and its header comment. Update that comment: it currently explains the ledger by reference to the packages job, which no longer runs this script's phases — it now gates Phase 0 and the corpus call.

- [ ] **Step 2: Trim the exit-code test to what still exists**

In `tests/test-verify-exit-code.sh`, delete the assertions naming phases 1, 2 and 3 (the `mk_repo` build-failure cases and the whole Phase 2 tool-loop section), keep the Phase 4 assertions and the verdict-mechanism tests, and **keep the final demonstration** — the verdict block still has to be shown capable of failing. Update the "all four phases fail" test to the phases that remain.

Update the file's header: the historical explanation stays (it is why the ledger exists), but it must no longer claim to test phases the script does not have.

- [ ] **Step 3: Delete the Phase 3 keep-logic test**

```bash
git rm tests/test-verify-on-host-keep.sh
```

Its entire subject — `KEEP_RUBY_IMAGE` versus `RUBY_PHASE_FAILED` — is Phase 3. Nothing it asserts survives.

- [ ] **Step 4: Run the hermetic suite**

Run: `bash tests/run-all.sh`
Expected: 38 tests (one deleted), 0 failures.

- [ ] **Step 5: Confirm criterion 6 mechanically**

```bash
grep -nE 'docker (run|build)|build\.sh' verify-on-host.sh
```

Expected: no matches outside Phase 0's `docker info`/`docker system df`/`docker --version` banner lines. Any `docker run` or `build.sh` call remaining means test logic still lives here and the criterion is not met.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(verify): delete Phases 1-3, now covered by the packages tier"
```

---

### Task 13: The nightly `packages` job

**Files:**
- Modify: `.github/workflows/nightly.yml`

**Interfaces:**
- Consumes: `run.sh --tags packages --require packages`.

- [ ] **Step 1: Replace the job body**

```yaml
  packages:
    name: Package installs (real allowlist, per-variant images)
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v5

      # Disk headroom before anything builds. Two multi-GB images are built
      # SERIALLY and removed between variants, so the peak is one image — but a
      # runner that starts near full fails the second build with an error that
      # looks nothing like "out of space".
      - name: Free disk
        run: |
          df -h / | tail -1
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
          df -h / | tail -1

      # --require packages: a selected case whose requirement is unmet FAILS the
      # job rather than skipping quietly. A case that cannot run is never a pass.
      - name: Packages tier
        run: bash tests/integration/run.sh --tags packages --require packages

      # The two numbers that decide whether IT_RUBY_VERSIONS stays at two
      # versions. Recorded every night, because an unmeasured budget is how a
      # tier silently outgrows its runner.
      - name: Budget
        if: always()
        run: |
          df -h / | tail -1
          docker system df
```

- [ ] **Step 2: Record the cost decision where it is incurred**

Add above the `Packages tier` step:

```yaml
      # COST SWITCH. IT_RUBY_VERSIONS defaults to 3.3.6,3.4.5 and the native
      # variant compiles both at container start. If this job exceeds 75 minutes
      # or the Budget step shows the runner peaking above 11 GB, set
      #   env: { IT_RUBY_VERSIONS: "3.4.5" }
      # here and add --exclude needs-multiruby to the step below.
      #
      # If you do: 750-ruby-multiversion-selection becomes a LOCAL-ONLY case,
      # covered by verify-on-host.sh on a workstation and by nothing in CI. That
      # is a real gap, and this comment is where it must be recorded — a
      # trade-off written only in a spec is a trade-off nobody will find.
```

- [ ] **Step 3: Verify the workflow parses and the exec-bit guard still passes**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/nightly.yml'))" && echo "YAML OK"
bash tests/test-exec-bits.sh
```

The second is not incidental: `test-exec-bits.sh`'s Class A2 scans the `*.d/` directories a workflow globs, and a workflow edit is exactly when that guard earns its place.

- [ ] **Step 4: Dispatch the nightly on the branch and read the result**

```bash
git push origin HEAD
gh workflow run nightly.yml --ref "$(git branch --show-current)"
gh run watch "$(gh run list --workflow=nightly.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```

Expected: the `packages` job passes, all seven cases PASS, none SKIP. Record the job's wall-clock and the Budget step's disk figures — they decide the `IT_RUBY_VERSIONS` question. If either threshold is exceeded, throw the cost switch in Step 2 and note it in the CHANGELOG in Task 14.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/nightly.yml
git commit -m "ci(nightly): run the packages tier through run.sh with --require packages"
```

---

### Task 14: Documentation

**Files:**
- Modify: `AGENTS.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update `AGENTS.md`**

Three edits:

1. The `verify-on-host.sh` sentence (currently "runs the same corpus (Phase 4) plus the package/Ruby phases that have no case coverage yet") — the phases are gone. Replace with a statement that it is Phase 0 plus the corpus, and that the packages tier is now part of the corpus.
2. The tag vocabulary — add `packages` and `needs-multiruby`, and the `multiruby` capability.
3. A short paragraph in the integration-tests section on image variants: what `agents` and `native` are, why the split is `KEEP_BUILD_TOOLCHAIN`, that a case selects one with `# image:`, and that `IT_RUBY_VERSIONS` is the cost lever.

- [ ] **Step 2: Update `CHANGELOG.md`**

Add under `## Unreleased` → `### Added`, naming what is now covered that was not, and — if the cost switch was thrown in Task 13 — the named gap.

- [ ] **Step 3: Verify the doc symlinks still resolve**

```bash
ls -l CLAUDE.md .github/copilot-instructions.md .kiro/steering/AGENTS.md
```

Expected: all three are symlinks to `AGENTS.md`. Edit only `AGENTS.md`.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md CHANGELOG.md
git commit -m "docs: the packages tier, image variants and IT_RUBY_VERSIONS"
```

---

### Task 15: Port to `mgd-ai-containers`

**Files:** the same set, at that repo's paths — engine files under `base/`, `tests/` at the repo root.

- [ ] **Step 1: Branch from main and copy the shared files**

```bash
M=/workspace/dev/dt-utils/mgd-ai-containers
git -C "$M" fetch -q origin
git -C "$M" switch -c test/integration-increment-3 origin/main
cp verify-on-host.sh "$M/base/verify-on-host.sh"
cp -r tests/integration/cases/7*.sh "$M/tests/integration/cases/"
cp tests/integration/{run.sh,lib.sh} "$M/tests/integration/"
cp -r tests/integration/mutations/7*.patch "$M/tests/integration/mutations/"
cp tests/{test-mutations.sh,test-integration-runner.sh,test-integration-lib.sh,test-verify-exit-code.sh} "$M/tests/"
git -C "$M" rm -q tests/test-verify-on-host-keep.sh
chmod +x "$M"/tests/integration/cases/7*.sh
```

- [ ] **Step 2: Confirm byte-identity of every shared file**

```bash
for f in verify-on-host.sh; do diff -q "$f" "$M/base/$f" || echo "DIFFERS: $f"; done
for f in tests/integration/run.sh tests/integration/lib.sh tests/test-mutations.sh \
         tests/test-integration-runner.sh tests/test-integration-lib.sh tests/test-verify-exit-code.sh; do
  diff -q "$f" "$M/$f" || echo "DIFFERS: $f"
done
```

Expected: no output. A difference here means a file has a hardcoded path that should have been layout-resolved.

- [ ] **Step 3: Port the workflow and docs by hand**

`nightly.yml` differs between the repos (mgd's steps carry `working-directory: base` where they run engine scripts) — apply the same job change, keeping that. `base/AGENTS.md` and `base/CHANGELOG.md` take the same text; mgd's CHANGELOG has extra sections above `### Fixed`, so insert at the matching heading rather than by line number.

- [ ] **Step 4: Run the suite there**

```bash
bash "$M/tests/run-all.sh"
bash "$M/tests/integration/mutate.sh" verify
```

Expected: all tests pass (mgd carries one extra test file), and every patch applies — `mutate.sh` resolves the `base/` layout via `--directory=base`, so the same patches serve both.

- [ ] **Step 5: Open the PR and dispatch the nightly**

```bash
git -C "$M" push -u origin test/integration-increment-3
cd "$M" && gh pr create --title "test(integration): increment 3 — the packages tier" --body "…"
gh workflow run nightly.yml --ref test/integration-increment-3
```

Expected: PR checks green, and the dispatched nightly's `packages` job green with seven cases passing and none skipping.

- [ ] **Step 6: Commit and report**

Report both PR URLs, the measured packages-job wall-clock and peak disk from each repo, and whether the `IT_RUBY_VERSIONS` cost switch was thrown.

---

## Self-Review

**Spec coverage.** Batched mutation demonstrations (`mutate.sh` multi-apply, nightly `tags` input) → Task 10, added pre-flight after the plan as first written would have cost seven full nightly dispatches. Image variants → Tasks 1-2. `image:` header → Task 1. Variant scheduling and one-image peak disk → Task 2. `IT_VARIANT_OVERRIDES` / `launcher_conf` fold-in → Task 3. `IT_RUBY_VERSIONS` and `multiruby` → Tasks 1, 4. `dump_blocked_forensics` → Task 5. The Ruby group helper → Task 6 (reduced from the spec's `ruby_group_warm`, with the reason recorded in the task). Seven cases → Tasks 7-9. Mutations and the extended coverage assertion → Task 11. Deleting Phases 1-3 and criterion 6 → Task 12. Nightly job, `--require packages`, the cost switch and its named gap → Task 13. Docs → Task 14. mgd port → Task 15. Platform reach is covered by Global Constraints (layout tolerance) and by capability probing, which already skips by name.

**Deviations from the spec, both deliberate and recorded in-task:**
- `ruby_group_warm` reduced to a shared group constant plus `ruby_wait_ready`. The rvm volume is already run-scoped and shared, and `run.sh` runs cases serially, so the `flock` guards nothing.
- Task 2 fails a variant's cases by name when its image will not build, rather than aborting the run. Not stated in the spec; it follows directly from the suite's rule that a case which cannot run is never a pass.

**Type consistency.** `variant_overrides`/`variant_image`/`case_variant`/`selected_variants` are used with the same signatures in Tasks 1, 2 and 4. `assert_runs <cid> <binary>` is defined in Task 6 and used in Tasks 7, 8, 9. `ruby_wait_ready <cid> <timeout>` is defined in Task 6 and used in Task 9. `IT_RUBY_GROUP` is defined in Task 6 and used in cases 750 and 760 — case 740 deliberately does not use it. `forensics_report <blocked.log> <domains> <dns-map> <allowlist>` is defined and consumed only in Task 5.

**Known risk carried into execution.** Task 5's awk column indices are asserted against a fixture written from Phase 3's format. Task 5 Step 3 requires checking them against `capture-blocked-traffic.sh`'s `log_blocked()` before finalising, because a fixture that mirrors an assumption rather than the writer would make the test pass against a format nothing produces.
