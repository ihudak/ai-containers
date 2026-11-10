#!/usr/bin/env bash
# Unit tests for `--version` — what the engine reports about itself.
#
# Three numbers matter and they come from three different places, which is the
# whole reason this is a feature rather than an echo:
#
#   the ENGINE RELEASE   git tags, in the base repo. A project's .ai-containers/
#                        is not a git repo, so it cannot ask — it has to have
#                        been TOLD, at the moment it was copied.
#   the SCHEMA VERSION   sandbox.conf's `# schema-version:` marker.
#   the nvm VERSION      sandbox.conf's `nvm-version=`, which is pinned because
#                        nvm's latest cannot be detected at build time behind a
#                        rate limit — .github/workflows/update-nvm-version.yml
#                        exists solely to keep the Dockerfile's ARG NVM_VERSION
#                        current, which the empty default reports, so reporting
#                        it is normally reporting the output of that job.
#
# The engine release is the one that can LIE, and these tests are mostly about
# that: a project copy reports what it was told at sync time, and a copy that
# was never told must say so rather than inventing a number or printing a blank.
set -uo pipefail
# Hermetic: the developer's own pointers must not reach a launch — sandbox.sh
# mounts them writable and writes into the git repositories it protects there.
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS SANDBOX_ENV_FILE SANDBOX_WORKDIR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# GUARDED, because this file forks (GIT-28's bounded and interrupted checks): a
# background job inherits the EXIT trap, and an unguarded one could delete the
# fixture the script is still using (tests/test-exit-trap-ownership.sh).
TMP_OWNER="$BASHPID"
# The process groups GIT-28's checks start (`set -m`, job28), KILLed whole on the
# way out: tests/run-all.sh's clock stops this file's own group, TERM and then
# KILL, which does not reach them, and a job left behind ran on for up to 10 s
# (version.sh's bound). bash runs this trap on the TERM (measured, 5.1 and 5.3).
# A group found empty when the next job starts is dropped: an empty group's
# number can lead someone else's group once pids wrap, and a sibling falsify
# worker's test is one (review of this change, L1). A group with members cannot
# be renumbered; one emptied and renumbered before the next job starts, a few
# checks' time, is the window left.
JOBS28=()
job28() {
  local g keep=()
  for g in "${JOBS28[@]}"; do if kill -0 -- "-$g" 2>/dev/null; then keep+=("$g"); fi; done
  JOBS28=("${keep[@]}" "$1")
}
cleanup() {
  local g
  for g in "${JOBS28[@]}"; do if kill -0 -- "-$g" 2>/dev/null; then kill -KILL -- "-$g" 2>/dev/null; fi; done
  rm -rf "$TMP"
}
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && cleanup' EXIT

[[ -f "$REPO_DIR/version.sh" ]] \
  && pass "version.sh exists" \
  || { fail "version.sh exists"; printf '\n%d failure(s)\n' "$fails"; exit "$fails"; }

# ── The report names all three, by label ──────────────────────────────────────
# Asserted by LABEL rather than by value: the values move (that is the point),
# the fields must not silently stop being reported.
report="$(cd "$REPO_DIR" && bash ./sandbox.sh --version 2>&1)"; rc=$?
(( rc == 0 )) && pass "sandbox.sh --version exits 0" \
              || fail "sandbox.sh --version exits 0 (got $rc: $report)"
for label in ai-containers sandbox.conf nvm; do
  grep -q "^${label}" <<<"$report" \
    && pass "the report names '$label'" \
    || fail "the report names '$label' (got: $report)"
done

# ── It does not launch anything ───────────────────────────────────────────────
# --version must be pure output. The launcher runs ./build.sh before
# ./sandbox.sh, so a --version that fell through to run_container would build an
# image and start a container to answer a question about a version string.
grep -qiE 'docker run|Generating allowlists' <<<"$report" \
  && fail "--version neither builds nor launches" \
  || pass "--version neither builds nor launches"

# ── The engine release, derived from git: SYNTHETIC repos, not the ambient one ─
# These build the git state they need instead of hoping the checkout has it, and
# that is not belt-and-braces — it is the whole reason this block was rewritten.
# The version that read the AMBIENT repo passed here and left five mutants alive
# in CI, every one of them in version_engine's git branch. The falsify job checks
# out with a bare `actions/checkout@v5`: no `fetch-depth: 0`, therefore no tags,
# therefore `git describe --tags` came back empty, therefore the assertion took
# its "not applicable" branch and the whole git path went unasserted in the one
# environment that gates merges. A test whose coverage depends on how the caller
# happened to clone is not covering anything it can be relied on for.
#
# `git describe --tags` and not `describe --tags --abbrev=0`: the suffix is the
# honest part. A copy taken five commits after v0.7.0 is not v0.7.0, and saying
# so is the difference between a version and a wish.
mkrepo() {  # $1=dir  $2=tag (optional) → an initialised repo with one commit
  git -C "$1" init -q -b main 2>/dev/null || git -C "$1" init -q || return 1
  # The identity is set IN THE REPO, not inherited, and `git tag -a` needs a
  # TAGGER just as `commit` needs an author. Passing -c to the commit alone
  # worked on a developer machine with a global identity and silently produced an
  # UNTAGGED repo on a CI runner, which has none — so the tagged-repo assertion
  # measured the short-SHA fallback and reported a plausible wrong answer.
  git -C "$1" config user.email "fixture@example.invalid" || return 1
  git -C "$1" config user.name  "version.sh fixture"      || return 1
  # An ENGINE tree, not merely a git tree, because that is what the git fallback
  # is for and what it is now scoped to. version_engine asks git only about a
  # directory carrying project-init.sh — base-repo-only by construction, absent
  # from AI_CONTAINERS_SHARED_FILES — so that a project's .ai-containers/ cannot
  # answer with its ENCLOSING project's version. These fixtures existed to
  # exercise the engine path and were shaped as bare git repos only because
  # nothing distinguished the two before; the marker makes the intent explicit.
  : > "$1/project-init.sh"                                || return 1
  git -C "$1" add -A                                      || return 1
  git -C "$1" commit -q -m init                           || return 1
  if [[ -n "${2:-}" ]]; then
    git -C "$1" tag -a "$2" -m "$2" || return 1
    # The scaffold's own premise, checked rather than assumed: if the tag is not
    # actually describable, every assertion built on this repo is measuring the
    # fallback path while claiming to measure the tag path. A bare `return 0`
    # here is what let that happen once already.
    git -C "$1" describe --tags >/dev/null 2>&1 || return 1
  fi
  return 0
}

# Tagged: the report must carry the tag.
gtag="$TMP/gitrepo"; mkdir -p "$gtag"
if mkrepo "$gtag" v1.0.0; then
  got="$(bash -c "source '$REPO_DIR/version.sh'; version_engine '$gtag'" 2>&1)"
  [[ "$got" == v1.0.0* ]] \
    && pass "a git tree reports its tag ($got)" \
    || fail "a git tree reports its tag (got '$got')"
else
  printf 'SCAFFOLD-FAILED: could not build a tagged repo\n'; exit 1
fi

# Untagged: `describe` yields nothing, so the short SHA is the fallback. This is
# the arm CI actually runs in, and the arm that was never asserted before.
gbare="$TMP/gitnotag"; mkdir -p "$gbare"
if mkrepo "$gbare"; then
  want_sha="$(git -C "$gbare" rev-parse --short HEAD)"
  got="$(bash -c "source '$REPO_DIR/version.sh'; version_engine '$gbare'" 2>&1)"
  [[ "$got" == "$want_sha" ]] \
    && pass "an untagged git tree falls back to its short SHA ($got)" \
    || fail "an untagged git tree falls back to its short SHA (wanted '$want_sha', got '$got')"
  [[ "$got" != "unknown" ]] \
    && pass "an untagged git tree is not reported as unknown" \
    || fail "an untagged git tree is not reported as unknown"
else
  printf 'SCAFFOLD-FAILED: could not build an untagged repo\n'; exit 1
fi

# The ambient repo, as a bonus end-to-end check. Deliberately NOT load-bearing:
# it is skipped wherever the checkout has no tags, which is precisely how the
# gap above went unnoticed.
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  want="$(git -C "$REPO_DIR" describe --tags 2>/dev/null || true)"
  if [[ -n "$want" ]]; then
    grep -q -- "$want" <<<"$report" \
      && pass "the base repo reports its git-derived version ($want)" \
      || fail "the base repo reports its git-derived version ($want) (got: $report)"
  else
    printf 'NOTE: no tags reachable here; the git-derived assertion is not applicable\n'
  fi
fi

# ── A project copy: reports what it was TOLD ──────────────────────────────────
# Not a git repo, so there is nothing to derive from. This is the case the
# recorded file exists for, and the case a naive implementation gets wrong by
# reporting the version of whatever repo the caller happens to be standing in.
proj="$TMP/proj"; mkdir -p "$proj"
cp "$REPO_DIR/version.sh" "$REPO_DIR/sandbox.conf" "$proj/"
printf 'v9.9.9-recorded\n' > "$proj/engine-version"
got="$(cd "$proj" && bash -c 'source ./version.sh; version_engine .' 2>&1)"
[[ "$got" == "v9.9.9-recorded" ]] \
  && pass "a project copy reports the version recorded at sync time" \
  || fail "a project copy reports the version recorded at sync time (got '$got')"

# ── Neither git nor a record: says so, rather than inventing ──────────────────
bare="$TMP/bare"; mkdir -p "$bare"
cp "$REPO_DIR/version.sh" "$bare/"
got="$(cd "$bare" && bash -c 'source ./version.sh; version_engine .' 2>&1)"
[[ -n "$got" && "$got" == *unknown* ]] \
  && pass "with neither git nor a record, the version is reported as unknown" \
  || fail "with neither git nor a record, the version is reported as unknown (got '$got')"

# ── The schema and nvm values track the ACTIVE sandbox.conf ───────────────────
# Read from the file, never hardcoded: a report that printed a constant would
# pass every assertion above while telling the user nothing true.
conf="$TMP/alt.conf"
printf '# schema-version: 77\nnvm-version=v1.2.3\n' > "$conf"
alt="$(cd "$REPO_DIR" && SANDBOX_CONF="$conf" bash ./sandbox.sh --version 2>&1)"
# MATCHED ON ITS OWN LINE, NOT ANYWHERE IN THE REPORT. `grep -q '77'` searched
# the whole output, and the whole output contains the engine version -- so the
# assertion passed whenever the short git sha happened to contain those two
# digits, whatever the schema field actually said. Not hypothetical: with
# version_schema's `[[ -f "$conf" ]]` guard negated the report reads
# `schema unknown`, and this still passed at commit 9a3f774 because of the `77`
# inside `f774`. That is a mutant surviving on the value of HEAD, and it is
# exactly what happened -- CI killed it at one commit and reported it SURVIVED
# at the next, with nothing in between but a merge.
grep -qE '^sandbox\.conf[[:space:]]+schema[[:space:]]+77$' <<<"$alt" \
  && pass "the schema version is read from the active sandbox.conf" \
  || fail "the schema version is read from the active sandbox.conf (got: $alt)"
grep -qE '^nvm[[:space:]]+v1\.2\.3$' <<<"$alt" \
  && pass "the nvm version is read from the active sandbox.conf" \
  || fail "the nvm version is read from the active sandbox.conf (got: $alt)"

# An EMPTY nvm-version is not "no nvm" — it means the Dockerfile's own ARG
# default applies, and that is the version the image will actually get. A report
# that printed an empty field here would be accurate about the file and useless
# about the image.
conf2="$TMP/empty-nvm.conf"
printf '# schema-version: 4\nnvm-version=\n' > "$conf2"
dockerfile_default="$(grep -oE '^ARG NVM_VERSION=.*' "$REPO_DIR/Dockerfile" | head -1 | cut -d= -f2-)"
alt2="$(cd "$REPO_DIR" && SANDBOX_CONF="$conf2" bash ./sandbox.sh --version 2>&1)"
if [[ -n "$dockerfile_default" ]] && grep -q -- "$dockerfile_default" <<<"$alt2"; then
  pass "an empty nvm-version reports the Dockerfile's default ($dockerfile_default)"
else
  fail "an empty nvm-version reports the Dockerfile's default ($dockerfile_default) (got: $alt2)"
fi

# ── version_engine's exit STATUS, not only its output ─────────────────────────
# Every path returns 0; nothing above checked that, so flipping any early
# `return 0` to `return 1` changed nothing observable. Callers DO branch on it
# (version_record's `v="$(version_engine …)"` runs under callers that may use
# -e), so the status is part of the contract, not decoration.
for arm in "$proj" "$bare" "$REPO_DIR"; do
  ( cd "$arm" 2>/dev/null && bash -c "source '$REPO_DIR/version.sh'; version_engine ." >/dev/null 2>&1 )
  rc=$?
  (( rc == 0 )) \
    && pass "version_engine returns 0 for $(basename "$arm")" \
    || fail "version_engine returns 0 for $(basename "$arm") (got $rc)"
done

# ── the git fallback must not answer for SOMEBODY ELSE'S repository ───────────
# `git -C` resolves the ENCLOSING repository, and does so for an ignored
# directory exactly as for a tracked one. So a project's .ai-containers/ that was
# never told its version answered with the PROJECT's own `git describe` — a real
# release string, for entirely the wrong tree, with nothing marking it a guess.
#
# This is the COMMON case, not a corner: every project synced before
# `engine-version` existed is in that state until its next sync, and
# docs/configuration.md promises those report `unknown` "rather than guessing".
#
# The fixture is a project repo carrying its OWN tag, so a leaked answer is
# unmistakable rather than merely wrong-looking.
proj_repo="$TMP/enclosing"; mkdir -p "$proj_repo/.ai-containers"
git init -q --initial-branch=main "$proj_repo" >/dev/null 2>&1 || git init -q "$proj_repo" >/dev/null 2>&1
git -C "$proj_repo" config user.email t@example.invalid
git -C "$proj_repo" config user.name  t
printf 'x\n' > "$proj_repo/f"; git -C "$proj_repo" add -A >/dev/null 2>&1
git -C "$proj_repo" commit -qm init >/dev/null 2>&1
git -C "$proj_repo" tag -a v9.1.2 -m "the PROJECT's own release" >/dev/null 2>&1
printf '.ai-containers/\n' > "$proj_repo/.gitignore"

# Premise: the fixture really is a git repo with that tag, and the copy really is
# inside it. Without this the assertion below could pass because git failed.
if [[ "$(git -C "$proj_repo/.ai-containers" describe --tags 2>/dev/null)" == "v9.1.2" ]]; then
  pass "scaffold: the project copy sits inside a git repo tagged v9.1.2"
else
  fail "scaffold: the project copy sits inside a git repo tagged v9.1.2 — the assertion below cannot discriminate"
fi

got="$(bash -c "source '$REPO_DIR/version.sh'; version_engine '$proj_repo/.ai-containers'" 2>&1)"
[[ "$got" == "unknown" ]] \
  && pass "an untold project copy reports unknown, not its enclosing repo's version" \
  || fail "an untold project copy reports unknown, not its enclosing repo's version — got '$got', which describes the PROJECT, not the engine"

# ...and a copy that WAS told still wins over everything.
printf 'v0.4.2\n' > "$proj_repo/.ai-containers/engine-version"
got="$(bash -c "source '$REPO_DIR/version.sh'; version_engine '$proj_repo/.ai-containers'" 2>&1)"
[[ "$got" == "v0.4.2" ]] \
  && pass "a recorded version still wins inside an enclosing git repo" \
  || fail "a recorded version still wins inside an enclosing git repo (got '$got')"

# ...and the ENGINE tree itself must keep deriving from git, or the fix has
# traded one silent wrong answer for another. Asserted against THIS repo, which
# is an engine tree by construction.
got="$(bash -c "source '$REPO_DIR/version.sh'; version_engine '$REPO_DIR'" 2>&1)"
if [[ -f "$REPO_DIR/project-init.sh" ]] && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  [[ -n "$got" && "$got" != "unknown" ]] \
    && pass "an engine tree still derives its version from git" \
    || fail "an engine tree still derives its version from git (got '$got') — the fallback was narrowed too far"
else
  printf 'NOTE: this checkout is not a git engine tree, so the engine-side half of\n'
  printf '      the fallback narrowing was NOT exercised.\n'
fi

# ── version_record: the half that WRITES ──────────────────────────────────────
# Nothing exercised this function at all, which is why every mutant of it
# survived. It is what makes a project copy able to answer the question later,
# so its three behaviours are pinned here.
rec_src="$TMP/rec-src"; rec_dst="$TMP/rec-dst"; mkdir -p "$rec_src" "$rec_dst"
printf 'v1.2.3-recorded\n' > "$rec_src/engine-version"
( bash -c "source '$REPO_DIR/version.sh'; version_record '$rec_src' '$rec_dst'" )
[[ "$(cat "$rec_dst/engine-version" 2>/dev/null)" == "v1.2.3-recorded" ]] \
  && pass "version_record writes the source tree's version into the destination" \
  || fail "version_record writes the source tree's version into the destination (got '$(cat "$rec_dst/engine-version" 2>/dev/null)')"

# `unknown` must NOT be written. A file saying `unknown` is worse than no file:
# version_engine already reports `unknown` when the file is absent, so writing it
# only makes a later sync unable to tell "never recorded" from "recorded once,
# badly".
unk_src="$TMP/unk-src"; unk_dst="$TMP/unk-dst"; mkdir -p "$unk_src" "$unk_dst"
( bash -c "source '$REPO_DIR/version.sh'; version_record '$unk_src' '$unk_dst'" )
unk_rc=$?
[[ ! -e "$unk_dst/engine-version" ]] \
  && pass "version_record writes nothing when the source version is unknown" \
  || fail "version_record writes nothing when the source version is unknown (wrote '$(cat "$unk_dst/engine-version" 2>/dev/null)')"

# ...AND a STALE record must be REMOVED, not left standing. This is the case the
# rule above does not cover and that shipped without it: `unknown` for the SOURCE
# says nothing about what the DESTINATION already holds. A project recorded once
# from a git checkout and then re-synced from a release tarball (no .git, nothing
# recorded) kept reporting the old release forever — `--version` naming a tree
# the copy demonstrably did not come from, with nothing in the output hinting at
# it. That is the one thing this file's header says the engine field must never
# do.
#
# Asserted through the RECORDED value, not through the absence of the file, so
# the assertion still holds if a future version marks "cannot know" some other
# way.
stale_src="$TMP/stale-src"; stale_dst="$TMP/stale-dst"; mkdir -p "$stale_src" "$stale_dst"
printf 'v0.1.0-stale\n' > "$stale_dst/engine-version"
( bash -c "source '$REPO_DIR/version.sh'; version_record '$stale_src' '$stale_dst'" )
stale_rc=$?
stale_got="$(bash -c "source '$REPO_DIR/version.sh'; version_engine '$stale_dst'" 2>&1)"
[[ "$stale_got" == "unknown" ]] \
  && pass "version_record clears a stale record when the source version is unknown" \
  || fail "version_record clears a stale record when the source version is unknown — still reports '$stale_got', a version this copy did not come from"
(( stale_rc == 0 )) \
  && pass "version_record returns 0 when clearing a stale record" \
  || fail "version_record returns 0 when clearing a stale record (got $stale_rc) — its callers run under set -e and call it bare"

# ...AND it must return 0 while doing so. This is not tidiness about exit codes:
# project-init.sh and sync-to-projects.sh both run under `set -euo pipefail` and
# both call version_record as a BARE command, so a non-zero return aborts them.
# The realistic trigger is a release tarball — no .git, no recorded version —
# where `unknown` is the correct answer and initialising a project must still
# work. The mutation tier is what surfaced this: every assertion above passed
# with the return flipped, because none of them looked at the status.
(( unk_rc == 0 )) \
  && pass "version_record returns 0 on an unknown version (its callers are set -e)" \
  || fail "version_record returns 0 on an unknown version — project-init.sh and sync-to-projects.sh run under set -e and call it bare, so this aborts them (got $unk_rc)"

# ...and non-fatal while CLEARING one, which is a different code path and needs a
# different fixture. The assertion above uses a destination that does not exist,
# where `rm -f` SUCCEEDS (that is what -f means) — so it cannot reach this. Only
# an existing directory that cannot be written to makes the removal itself fail.
#
# Run under `set -e`, because that is the failure this models: both callers run
# `set -euo pipefail` and call version_record BARE, so a non-zero status aborts
# project-init.sh or sync-to-projects.sh outright rather than returning anything
# for a caller to inspect. Without `set -e` the mutation tier's `&& true` variant
# survives — execution simply carries on to `return 0` and the status is never
# consulted.
#
# THE PREMISE IS CHECKED, not assumed. As root, or on a filesystem that ignores
# the mode, `rm` succeeds anyway and the assertion would pass without exercising
# anything. That is reported as a skip rather than counted as a pass.
unwr="$TMP/unwritable"; mkdir -p "$unwr"
printf 'v0.1.0-stale\n' > "$unwr/engine-version"
chmod 500 "$unwr" 2>/dev/null
if ( rm -f "$unwr/engine-version" ) 2>/dev/null; then
  chmod 700 "$unwr" 2>/dev/null
  printf 'NOTE: the unwritable-destination premise does not hold here (root, or a\n'
  printf '      filesystem ignoring the mode), so the clear-path non-fatality\n'
  printf '      assertion was NOT exercised.\n'
else
  ( bash -c "set -e; source '$REPO_DIR/version.sh'; version_record '$unk_src' '$unwr'; exit 0" ) 2>/dev/null
  unwr_rc=$?
  chmod 700 "$unwr" 2>/dev/null
  (( unwr_rc == 0 )) \
    && pass "version_record is non-fatal under set -e when a stale record cannot be removed" \
    || fail "version_record is non-fatal under set -e when a stale record cannot be removed (got $unwr_rc) — this aborts project-init.sh and sync-to-projects.sh, which call it bare"
fi

# Non-fatal on an unwritable destination: project-init.sh and sync-to-projects.sh
# call this for its side effect, and a project that cannot be told its version
# must still be initialised.
( bash -c "source '$REPO_DIR/version.sh'; version_record '$rec_src' '$TMP/does-not-exist'" ) 2>/dev/null
rc=$?
(( rc == 0 )) \
  && pass "version_record is non-fatal when the destination cannot be written" \
  || fail "version_record is non-fatal when the destination cannot be written (got $rc)"

# ── version.sh reaches projects ───────────────────────────────────────────────
# A shared file that sync does not copy is a feature every project lacks.
grep -q 'version\.sh' "$REPO_DIR/shared-files.sh" \
  && pass "version.sh is in AI_CONTAINERS_SHARED_FILES" \
  || fail "version.sh is in AI_CONTAINERS_SHARED_FILES"

# ── The generated launcher answers without building ───────────────────────────
# runme.sh runs ./build.sh unconditionally today. It must short-circuit BEFORE
# that for --version, or asking the version builds an image.
launcher="$TMP/runme.sh"
( cd "$REPO_DIR" && bash -c 'source ./project-init.sh 2>/dev/null || true; emit_launcher "'"$launcher"'" demo' ) >/dev/null 2>&1
if [[ -f "$launcher" ]]; then
  pass "emit_launcher produced a launcher to inspect"
  # The --version branch must appear BEFORE the ./build.sh line.
  v_line="$(grep -n -- '--version' "$launcher" | head -1 | cut -d: -f1)"
  b_line="$(grep -n '^\./build\.sh' "$launcher" | head -1 | cut -d: -f1)"
  if [[ -n "$v_line" && -n "$b_line" ]] && (( v_line < b_line )); then
    pass "runme.sh handles --version before it builds (line $v_line < $b_line)"
  else
    fail "runme.sh handles --version before it builds (version=$v_line build=$b_line)"
  fi
  grep -q 'sandbox\.sh" \?.*\$@\|sandbox\.sh "\$@"' "$launcher" \
    && pass "runme.sh forwards its arguments to sandbox.sh" \
    || fail "runme.sh forwards its arguments to sandbox.sh"
else
  fail "emit_launcher produced a launcher to inspect"
fi

# ── version_schema called on its own, as ai-containers-report.sh calls it ─────
# Through version_report its `dir` and `conf` are also the caller's locals, so
# bash's dynamic scoping hides a missing declaration (stmt-delete, GAP-4). A
# direct call with no SANDBOX_CONF must read the named directory's file.
sdir="$TMP/schema-dir"; mkdir -p "$sdir"
printf '# schema-version: 41\n' > "$sdir/sandbox.conf"
got="$(env -u SANDBOX_CONF bash -c "source '$REPO_DIR/version.sh'; version_schema '$sdir'" 2>&1)"
[[ "$got" == "41" ]] \
  && pass "version_schema DIR reads DIR's sandbox.conf when called directly" \
  || fail "version_schema DIR reads DIR's sandbox.conf when called directly (got '$got')"
got="$(env -u SANDBOX_CONF bash -c "source '$REPO_DIR/version.sh'; version_schema '$TMP/no-such-dir'" 2>&1)"
[[ "$got" == "unknown" ]] \
  && pass "version_schema of a directory with no sandbox.conf is unknown" \
  || fail "version_schema of a directory with no sandbox.conf is unknown (got '$got')"

# ── GIT-28: git reads nothing of the engine checkout but its objects ─────────
# version_engine ran `git describe --tags --dirty` in the engine checkout, whose
# config an agent can reach through an include when a launch mounts it: --dirty
# ran core.fsmonitor and a clean filter, a missing commit started a fetch that
# ran the remote's uploadpack and a credential helper, a FIFO an include named
# hung it, and copying the checkout's files for git let planted links fill
# memory and TMPDIR. Now git runs in a directory of version.sh's own, on refs
# read here as data, and -dirty is not reported (the user's choice).
ver28() {  # <dir> → version_engine's stdout and stderr
  bash -c 'source "$1/version.sh"; _ver_secs="${VER28_SECS:-10}"; version_engine "$2"' _ "$REPO_DIR" "$1" 2>&1
}
# ver28 in a process group of its own, KILLed whole at <seconds>: killing the
# shell alone left the git it ran blocked on a FIFO for good.
ver28_bounded() {  # <seconds> <dir> <out-file> → 0, or 124 when cut off
  local secs="$1" pid waited=0
  set -m
  VER28_SECS=2 bash -c 'source "$1/version.sh"; _ver_secs="$VER28_SECS"; version_engine "$2"' _ "$REPO_DIR" "$2" > "$3" 2>&1 &
  pid=$!
  set +m
  job28 "$pid"
  vb28="$pid"   # its process group, which anything it left running is still in
  while kill -0 "$pid" 2>/dev/null && (( waited < secs * 10 )); do sleep 0.1; waited=$(( waited + 1 )); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}
ran28() {  # what ran since the last call, by the markers the programs leave
  local r=""
  [[ -e "$TMP/ran28-fsmon" ]] && r+="core.fsmonitor "
  [[ -e "$TMP/ran28-clean" ]] && r+="a clean filter "
  [[ -e "$TMP/ran28-fetch" ]] && r+="a fetch"
  rm -f "$TMP/ran28-fsmon" "$TMP/ran28-clean" "$TMP/ran28-fetch"
  printf '%s' "$r"
}
gq28() { git -C "$g28" -c core.fsmonitor=false -c filter.pwn28.clean=cat "$@" >/dev/null 2>&1; }
want28() { git -C "$1" -c core.fsmonitor=false describe --tags 2>/dev/null; }   # git's own answer
# SIGINT reaches the check only where it is not ignored: a job started in the
# background of a shell without job control ignores it, as the falsify tier's
# oracles are started, and nothing undoes that but GNU env's --default-signal.
sigpre28=()
if env --default-signal=INT true 2>/dev/null; then sigpre28=(env --default-signal=INT); fi
g28="$TMP/g28"; mkdir -p "$g28"
printf '*.c filter=pwn28\n' > "$g28/.gitattributes"; printf 'int x;\n' > "$g28/a.c"; printf 'f\n' > "$g28/f"
if mkrepo "$g28" v2.8.0; then
  printf '#!/bin/sh\ntouch "%s"\ncat\n' "$TMP/ran28-clean" > "$TMP/clean28"
  printf '#!/bin/sh\ntouch "%s"\n' "$TMP/ran28-fsmon" > "$TMP/fsmon28"
  chmod +x "$TMP/clean28" "$TMP/fsmon28"
  git -C "$g28" config filter.pwn28.clean "$TMP/clean28"
  git -C "$g28" config core.fsmonitor "$TMP/fsmon28"
  # A tracked file changed: the version is the tag, no -dirty, and nothing the
  # config names runs (describe --dirty ran both programs).
  printf 'int y;\n' > "$g28/a.c"; touch "$g28/f"; ran28 >/dev/null
  got="$(ver28 "$g28")"; r="$(ran28)"
  [[ "$got" == v2.8.0 && -z "$r" ]] \
    && pass "GIT-28 a changed tree gives the tag with no -dirty, and nothing the config names runs" \
    || fail "GIT-28 a changed tree (got '$got'; ran: ${r:-nothing})"
  gq28 checkout -q -- a.c
  # A commit after the tag, in loose refs and then packed: git's own answer.
  printf 'g\n' >> "$g28/f"; gq28 commit -qam two
  got="$(ver28 "$g28")"; w="$(want28 "$g28")"
  [[ "$got" == v2.8.0-1-g* && "$got" == "$w" ]] && pass "GIT-28 loose refs give git's own describe" \
    || fail "GIT-28 loose refs (got '$got', git says '$w')"
  gq28 pack-refs --all
  got="$(ver28 "$g28")"
  [[ "$got" == "$w" && ! -e "$g28/.git/refs/tags/v2.8.0" ]] && pass "GIT-28 packed refs give git's own describe" \
    || fail "GIT-28 packed refs (got '$got', git says '$w')"
  # A loose tag over a packed one of the same name, as git reads them; and
  # core.abbrev, carried as data.
  gq28 tag -f -a v2.8.0 -m again
  git -C "$g28" config core.abbrev 12
  got="$(ver28 "$g28")"; w="$(want28 "$g28")"
  [[ "$got" == v2.8.0 && "$got" == "$w" ]] && pass "GIT-28 a loose tag is read over the packed one" \
    || fail "GIT-28 a loose tag over a packed one (got '$got', git says '$w')"
  gq28 commit -qam three --allow-empty
  got="$(ver28 "$g28")"; w="$(want28 "$g28")"
  [[ "$got" == "$w" && "${got##*-g}" =~ ^[0-9a-f]{12}$ ]] && pass "GIT-28 core.abbrev is carried" \
    || fail "GIT-28 core.abbrev (got '$got', git says '$w')"
  git -C "$g28" config --unset core.abbrev
  # A default object format other than the repository's is not taken.
  got="$(GIT_DEFAULT_HASH=sha256 ver28 "$g28")"; w="$(want28 "$g28")"
  [[ "$got" == "$w" ]] && pass "GIT-28 GIT_DEFAULT_HASH is not the repository's format" \
    || fail "GIT-28 GIT_DEFAULT_HASH=sha256 (got '$got', git says '$w')"
  # A default ref format of reftable is not the files this writes (review of the
  # GIT-28 fix): every version came out unknown.
  printf '[init]\n\tdefaultRefFormat = reftable\n' > "$TMP/gc28"
  got="$(GIT_CONFIG_GLOBAL="$TMP/gc28" ver28 "$g28")"
  [[ "$got" == "$w" ]] && pass "GIT-28 a reftable default ref format is not taken" \
    || fail "GIT-28 init.defaultRefFormat=reftable (got '$got', git says '$w')"
  # Links planted among the refs, the objects and the index are never read: one
  # to /dev/zero took git to gigabytes in under a second. Memory capped where
  # ulimit -v works, so a regression cannot take the host's.
  ln -s /dev/zero "$g28/.git/refs/tags/zero28"
  mkdir -p "$g28/.git/objects/info"; ln -s /dev/zero "$g28/.git/objects/info/alternates"
  mv "$g28/.git/index" "$TMP/index28"; ln -s /dev/zero "$g28/.git/index"; t28=$SECONDS
  got="$(bash -c 'ulimit -v 4000000 2>/dev/null; source "$1/version.sh"; version_engine "$2"' _ "$REPO_DIR" "$g28" 2>&1)"; e28=$(( SECONDS - t28 ))
  rm -f "$g28/.git/refs/tags/zero28" "$g28/.git/objects/info/alternates" "$g28/.git/index"; mv "$TMP/index28" "$g28/.git/index"
  [[ "$got" == "$w" ]] && (( e28 < 5 )) && pass "GIT-28 links to /dev/zero among the refs, the objects and the index are not read" \
    || fail "GIT-28 links to /dev/zero (got '$got' in $e28 s)"
  # The branch HEAD names, as a link: no answer, rather than reading it.
  b28="$(git -C "$g28" symbolic-ref HEAD)"; cp "$g28/.git/$b28" "$TMP/branch28" 2>/dev/null || git -C "$g28" rev-parse HEAD > "$TMP/branch28"
  rm -f "$g28/.git/$b28"; ln -s /dev/zero "$g28/.git/$b28"
  got="$(bash -c 'ulimit -v 4000000 2>/dev/null; source "$1/version.sh"; version_engine "$2"' _ "$REPO_DIR" "$g28" 2>&1)"
  rm -f "$g28/.git/$b28"; cp "$TMP/branch28" "$g28/.git/$b28"
  [[ "$got" == unknown ]] && pass "GIT-28 a branch that is a link gives no answer" || fail "GIT-28 a branch that is a link (got '$got')"
  # Hard links of a big file into refs/tags, in a directory you cannot write:
  # each is read 100 bytes at most, and TMPDIR is left empty.
  mkdir -p "$TMP/tmp28h" "$g28/.git/refs/tags/ro28"; dd if=/dev/zero of="$TMP/big28" bs=1048576 count=8 2>/dev/null
  for i28 in 1 2 3 4; do ln "$TMP/big28" "$g28/.git/refs/tags/ro28/h$i28" 2>/dev/null; done
  chmod 555 "$g28/.git/refs/tags/ro28"
  got="$(TMPDIR="$TMP/tmp28h" ver28 "$g28")"
  chmod 755 "$g28/.git/refs/tags/ro28"; rm -rf "$g28/.git/refs/tags/ro28" "$TMP/big28"
  [[ "$got" == "$w" && -z "$(ls -A "$TMP/tmp28h")" ]] \
    && pass "GIT-28 hard links into a read-only tags directory: not copied, TMPDIR left empty" \
    || fail "GIT-28 hard links into a read-only tags directory (got '$got'; left: $(ls -A "$TMP/tmp28h" | head -1))"
  # A config value with a newline in it prints a line of its own: not decided on.
  git -C "$g28" config core.abbrev "$(printf '8\nextensions.objectformat sha256')"
  got="$(ver28 "$g28")"
  git -C "$g28" config --unset core.abbrev
  [[ "$got" == unknown ]] && pass "GIT-28 a config value with a newline in it is not decided on" \
    || fail "GIT-28 a config value with a newline (got '$got')"
  # Interrupted while it works: its temporary directory goes with it, and the
  # command it was running (a slow ln here).
  mkdir -p "$TMP/slow28" "$TMP/tmpsig28"
  printf '#!/bin/sh\necho "$$" > "%s"\nexec sleep 5\n' "$TMP/ln28.pid" > "$TMP/slow28/ln"; chmod +x "$TMP/slow28/ln"
  for sig28 in INT TERM HUP; do
    if [[ "$sig28" == INT && -n "$(${sigpre28[@]+"${sigpre28[@]}"} bash -c 'trap -p INT')" ]]; then
      printf 'NOTE: SIGINT is ignored where this runs; the SIGINT check is not applicable\n'
      continue
    fi
    set -m
    TMPDIR="$TMP/tmpsig28" PATH="$TMP/slow28:$PATH" ${sigpre28[@]+"${sigpre28[@]}"} bash -c 'source "$1/version.sh"; version_engine "$2"' _ "$REPO_DIR" "$g28" >/dev/null 2>&1 &
    p28=$!
    set +m
    job28 "$p28"
    w28=0; while [[ ! -s "$TMP/ln28.pid" ]] && kill -0 "$p28" 2>/dev/null && (( w28 < 100 )); do sleep 0.1; w28=$(( w28 + 1 )); done
    saw28="$(ls -A "$TMP/tmpsig28")"
    kill -"$sig28" -"$p28" 2>/dev/null; wait "$p28" 2>/dev/null
    w28=0; while [[ -n "$(ls -A "$TMP/tmpsig28")" ]] && (( w28 < 30 )); do sleep 0.1; w28=$(( w28 + 1 )); done
    sleep 0.3; c28="$(cat "$TMP/ln28.pid" 2>/dev/null)"
    [[ -n "$saw28" && -z "$(ls -A "$TMP/tmpsig28")" && -n "$c28" ]] && ! kill -0 "$c28" 2>/dev/null \
      && pass "GIT-28 a check stopped by SIG$sig28 while it works removes its temporary directory and what it ran" \
      || fail "GIT-28 a check stopped by SIG$sig28 (made: '${saw28:-nothing}'; left: '$(ls -A "$TMP/tmpsig28")'; ln ${c28:-?} $(kill -0 "${c28:-0}" 2>/dev/null && echo running || echo gone))"
    if [[ -n "$c28" ]]; then kill -KILL "$c28" 2>/dev/null; fi; rm -f "$TMP/ln28.pid"; rm -rf "${TMP:?}/tmpsig28/"*
  done
  # The same signals sent to the subshell that asks git alone, not to its
  # group, as `kill <pid>` sends them: what it runs gets nothing, so only the
  # trap's kill (_ver_stop) stops it. The check above shows that only for
  # SIGINT, only on bash 5.3 (5.1 and 5.2 do not make a process substitution
  # ignore it; measured), and only where GNU env can undo an ignored SIGINT:
  # TERM and HUP sent to the group reach the command itself on any bash. The
  # slow ln records its parent, which is that subshell.
  mkdir -p "$TMP/slow28b"
  printf '#!/bin/sh\necho "$$ $PPID" > "%s"\nexec sleep 5\n' "$TMP/ln28b.pid" > "$TMP/slow28b/ln"; chmod +x "$TMP/slow28b/ln"
  for sig28 in INT TERM HUP; do
    if [[ "$sig28" == INT && -n "$(${sigpre28[@]+"${sigpre28[@]}"} bash -c 'trap -p INT')" ]]; then
      printf 'NOTE: SIGINT is ignored where this runs; the SIGINT check of the subshell alone is not applicable\n'
      continue
    fi
    set -m
    TMPDIR="$TMP/tmpsig28" PATH="$TMP/slow28b:$PATH" ${sigpre28[@]+"${sigpre28[@]}"} bash -c 'source "$1/version.sh"; version_engine "$2"' _ "$REPO_DIR" "$g28" >/dev/null 2>&1 &
    p28=$!
    set +m
    job28 "$p28"
    w28=0; while [[ ! -s "$TMP/ln28b.pid" ]] && kill -0 "$p28" 2>/dev/null && (( w28 < 100 )); do sleep 0.1; w28=$(( w28 + 1 )); done
    sleep 0.2; c28="" s28=""; read -r c28 s28 2>/dev/null < "$TMP/ln28b.pid" || true
    saw28="$(ls -A "$TMP/tmpsig28")"
    # Still running when signalled, so a stall that let it finish on its own
    # cannot pass for the trap's kill.
    ran28=""; if [[ -n "$c28" ]] && kill -0 "$c28" 2>/dev/null; then ran28=yes; fi
    if [[ -n "$s28" && "$s28" != "$p28" ]]; then kill -"$sig28" "$s28" 2>/dev/null; fi
    w28=0; while kill -0 "$p28" 2>/dev/null && (( w28 < 30 )); do sleep 0.1; w28=$(( w28 + 1 )); done
    sleep 0.3
    [[ -n "$saw28" && -n "$ran28" && -n "$s28" && "$s28" != "$p28" && -z "$(ls -A "$TMP/tmpsig28")" ]] && ! kill -0 "$c28" 2>/dev/null \
      && pass "GIT-28 SIG$sig28 sent to the subshell that asks git alone stops what it ran and removes its temporary directory" \
      || fail "GIT-28 SIG$sig28 sent to the subshell alone (subshell ${s28:-?} of ${p28}; made: '${saw28:-nothing}'; left: '$(ls -A "$TMP/tmpsig28")'; ln ${c28:-?} ${ran28:+running when signalled, }$( [[ -n "$c28" ]] && kill -0 "$c28" 2>/dev/null && echo running || echo gone))"
    if [[ -n "$c28" ]]; then kill -KILL "$c28" 2>/dev/null; fi; kill -KILL -"$p28" 2>/dev/null; wait "$p28" 2>/dev/null
    rm -f "$TMP/ln28b.pid"; rm -rf "${TMP:?}/tmpsig28/"*
  done
  # No temporary directory to be had: no answer.
  got="$(TMPDIR="$TMP/no-such-tmp28" ver28 "$g28")"
  [[ "$got" == unknown ]] && pass "GIT-28 where no temporary directory can be made, the version is unknown" \
    || fail "GIT-28 with no temporary directory (got '$got')"
  # A shell with no descriptor left for _ver_run's {fd}: it has started the
  # command all the same, which wrote on into the temporary directory as it was
  # removed and left it behind.
  mkdir -p "$TMP/fd28"
  if bash -c 'ulimit -n 10' 2>/dev/null; then
    for _ in 1 2 3; do
      got="$(TMPDIR="$TMP/fd28" bash -c 'ulimit -n 10; source "$1/version.sh"; version_engine "$2"' _ "$REPO_DIR" "$g28" 2>&1)"
    done
    sleep 0.5
    [[ "$got" == unknown && -z "$(ls -A "$TMP/fd28")" ]] \
      && pass "GIT-28 with no descriptor to spare, the version is unknown, nothing else is said, and nothing is left in TMPDIR" \
      || fail "GIT-28 with no descriptor to spare (got '$got'; left: $(ls -A "$TMP/fd28" | tr '\n' ' '))"
  else
    printf 'NOTE: ulimit -n 10 is refused here; the descriptor check is not applicable\n'
  fi
  # A linked worktree: its own HEAD, the common refs.
  if gq28 worktree add -q "$TMP/wt28" && git -C "$TMP/wt28" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wt; then
    got="$(ver28 "$TMP/wt28")"; w="$(want28 "$TMP/wt28")"
    [[ "$got" == "$w" && "$got" != "$(ver28 "$g28")" ]] && pass "GIT-28 a linked worktree gives its own HEAD's describe" \
      || fail "GIT-28 a linked worktree (got '$got', git says '$w')"
  else
    fail "GIT-28 scaffold: git worktree add failed"
  fi
  # Called in the caller's own shell, not in $(…): no variable of the caller's
  # changes, and nothing is left in TMPDIR.
  mkdir -p "$TMP/tmp28"; w="$(want28 "$g28")"
  got="$(TMPDIR="$TMP/tmp28" bash -c 'source "$1/version.sh"; g=keep; version_engine "$2"; printf " %s" "$g"' _ "$REPO_DIR" "$g28" 2>&1)"
  [[ "$got" == "$w keep" && -z "$(ls -A "$TMP/tmp28")" ]] \
    && pass "GIT-28 a direct call leaves the caller's variables and TMPDIR as they were" \
    || fail "GIT-28 a direct call (got '$got'; left in TMPDIR: $(ls -A "$TMP/tmp28" | head -1))"
  # GIT-50: _ver_run's status does not come from a wait on a process
  # substitution. Once one has finished, bash 5.1 to 5.3 report that wait failed
  # now and then under load (7 of 48,000 in _ver_run's form, bash 5.2.21; TST-29),
  # and the version came out unknown. A wait that fails for every process that
  # is not one of the shell's jobs stands in for that, through BASH_ENV, which
  # the shell reads before its first line: `jobs -p` lists a running background
  # job, and never a process substitution. The command closes its output and
  # runs on a little, so its job is still running when it is waited for: bash
  # 5.1 drops a finished job from `jobs -p` once a process substitution has run.
  printf '%s\n' "wait() {" \
    "  local p j f='$TMP/jobs50.'\"\$BASHPID\"" \
    "  jobs -p > \"\$f\" 2>/dev/null; j=\" \$(tr '\\n' ' ' < \"\$f\") \"; rm -f \"\$f\"" \
    "  for p; do [[ \"\$p\" == -* || \"\$j\" == *\" \$p \"* ]] || return 127; done" \
    "  builtin wait \"\$@\"" \
    "}" > "$TMP/wait50.bash"
  mkdir -p "$TMP/tmp50"
  got="$(TMPDIR="$TMP/tmp50" BASH_ENV="$TMP/wait50.bash" bash -c 'source "$1/version.sh"
           _ver_run o sh -c "printf x; exec >&-; sleep 0.5; exit 3"; printf "%s %s" "$?" "$o"' _ "$REPO_DIR" 2>&1)"
  [[ "$got" == "3 x" && -z "$(ls -A "$TMP/tmp50")" ]] \
    && pass "GIT-50 _ver_run's status comes from no wait on a process substitution, and TMPDIR is left as it was" \
    || fail "GIT-50 _ver_run with a wait on a process substitution that fails (status and output: '$got'; left in TMPDIR: $(ls -A "$TMP/tmp50" | head -1))"
  # The fake's premise: it passes a wait on a running background job, and fails
  # one on a process substitution.
  got="$(BASH_ENV="$TMP/wait50.bash" bash -c 'sleep 0.5 & q=$!; wait "$q"; a=$?; exec {f}< <(exit 0); p=$!; sleep 0.2; wait "$p"; printf "%s %s" "$a" "$?"' 2>/dev/null)"
  [[ "$got" == "0 127" ]] && pass "GIT-50 scaffold: the fake wait passes a background job and fails a process substitution" \
    || fail "GIT-50 scaffold: the fake wait (background job, process substitution: '$got')"
  # No directory for a call's FIFO: a TMPDIR that cannot hold one, or a _ver_dir
  # that is not there. No answer either way, and TMPDIR left as it was.
  got="$(TMPDIR="$TMP/no-such-tmp50" bash -c 'source "$1/version.sh"; _ver_run o printf x; printf "%s [%s]" "$?" "$o"' _ "$REPO_DIR" 2>&1)"
  [[ "$got" == "1 []" ]] && pass "GIT-50 _ver_run with no temporary directory to be had fails, starting nothing" \
    || fail "GIT-50 _ver_run with no temporary directory (status and output: '$got')"
  got="$(TMPDIR="$TMP/tmp50" bash -c 'source "$1/version.sh"; _ver_dir="$2/no-such-dir50"; _ver_run o printf x; printf "%s [%s]" "$?" "$o"' _ "$REPO_DIR" "$TMP" 2>&1)"
  [[ "$got" == "1 []" && -z "$(ls -A "$TMP/tmp50")" ]] && pass "GIT-50 _ver_run with no FIFO to be made fails, starting nothing" \
    || fail "GIT-50 _ver_run with no FIFO (status and output: '$got'; left in TMPDIR: $(ls -A "$TMP/tmp50" | head -1))"
  # One temporary directory for the whole of a version_engine that asks git:
  # every _ver_run of _ver_git_version makes its FIFO there, not a directory of
  # its own each.
  mkdir -p "$TMP/mkt50"; : > "$TMP/mkt50.log"
  printf '#!/bin/sh\necho x >> "%s"\nexec %s "$@"\n' "$TMP/mkt50.log" "$(command -v mktemp)" > "$TMP/mkt50/mktemp"; chmod +x "$TMP/mkt50/mktemp"
  w="$(want28 "$g28")"; got="$(PATH="$TMP/mkt50:$PATH" ver28 "$g28")"
  [[ -n "$w" && "$got" == "$w" && "$(wc -l < "$TMP/mkt50.log")" -eq 1 ]] \
    && pass "GIT-50 a version_engine that asks git makes one temporary directory" \
    || fail "GIT-50 temporary directories made (got '$got', git says '$w'; mktemp ran $(wc -l < "$TMP/mkt50.log") times)"
else
  fail "GIT-28 scaffold: could not build a tagged repo"
fi
# A partial clone whose missing commit git would fetch, through config allowing
# the file protocol by name: the config is never read, so nothing is fetched.
p28="$TMP/p28"; mkdir -p "$p28"
if mkrepo "$p28" v2.8.8 && printf 'p\n' > "$p28/p" && git -C "$p28" add p && git -C "$p28" commit -qm two; then
  # HEAD's own commit missing: describe must parse it, and fetches it.
  c1="$(git -C "$p28" rev-parse HEAD)"; git init -q --bare "$TMP/remote28.git"
  printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$TMP/ran28-fetch" > "$TMP/up28"; chmod +x "$TMP/up28"
  git -C "$p28" config core.repositoryformatversion 1
  git -C "$p28" config extensions.partialClone p
  git -C "$p28" config remote.p.promisor true
  git -C "$p28" config remote.p.url "$TMP/remote28.git"
  git -C "$p28" config remote.p.uploadpack "$TMP/up28"
  git -C "$p28" config protocol.file.allow always
  rm -f "$p28/.git/objects/${c1:0:2}/${c1:2}"
  # The scaffold's premise: plain git, asked the same, does fetch.
  git -C "$p28" -c core.fsmonitor=false describe --tags >/dev/null 2>&1
  pre28="$([[ -e "$TMP/ran28-fetch" ]] && echo yes)"; rm -f "$TMP/ran28-fetch"
  ver28 "$p28" >/dev/null
  [[ -n "$pre28" && ! -e "$TMP/ran28-fetch" ]] \
    && pass "GIT-28 a missing object is not fetched: the checkout's config is never read" \
    || fail "GIT-28 a missing object (git itself fetches it: ${pre28:-no, so this check cannot tell}; version.sh ran uploadpack: $([[ -e "$TMP/ran28-fetch" ]] && echo yes || echo no))"
else
  fail "GIT-28 scaffold: could not build the partial-clone fixture"
fi
# A shallow clone: its shallow file is written for git, which otherwise looks
# for parents the clone does not have.
sh28="$TMP/sh28src"; mkdir -p "$sh28"
if mkrepo "$sh28" v2.8.4 && git -C "$sh28" commit -q --allow-empty -m a && git -C "$sh28" commit -q --allow-empty -m b \
   && git -C "$sh28" tag -a v2.8.5 -m v HEAD~1 && git -C "$sh28" commit -q --allow-empty -m c \
   && git clone -q --depth 3 "file://$sh28" "$TMP/sh28" 2>/dev/null && [[ -f "$TMP/sh28/.git/shallow" ]]; then
  : > "$TMP/sh28/project-init.sh"
  got="$(ver28 "$TMP/sh28")"; w="$(want28 "$TMP/sh28")"
  [[ -n "$w" && "$got" == "$w" ]] && pass "GIT-28 a shallow clone gives git's own describe" \
    || fail "GIT-28 a shallow clone (got '$got', git says '$w')"
else
  fail "GIT-28 scaffold: could not make a shallow clone"
fi
# _ver_run whose exec has no descriptor left kills what it started, and only
# that: a job of the caller's, running since before, is left alone. What it
# started is $!, as _ver_run itself finds it: a pid file the command wrote is
# not, since dash (Ubuntu's sh) writes nothing with ten descriptors, and the
# check passed with the kill removed (CI, cd36db1).
if bash -c 'ulimit -n 10' 2>/dev/null; then
  mkdir -p "$TMP/fdr50"
  got="$(TMPDIR="$TMP/fdr50" bash -c 'source "$1/version.sh"; sleep 30 & j=$!; ulimit -n 10
           _ver_run o sleep 30; r=$?; s=$!
           sleep 0.3
           [[ "$s" != "$j" ]] && c=started || c=not-started
           kill -0 "$s" 2>/dev/null && a=alive || a=gone
           kill -0 "$j" 2>/dev/null && b=alive || b=gone
           [[ -z "$_ver_cur" ]] && u=clear || u=set
           kill "$j" "$s" 2>/dev/null; printf "%s %s %s %s %s" "$r" "$c" "$a" "$b" "$u"' _ "$REPO_DIR" 2>/dev/null)"
  [[ "$got" == "1 started gone alive clear" && -z "$(ls -A "$TMP/fdr50")" ]] \
    && pass "GIT-28 _ver_run with no descriptor kills the command it started, and not the caller's job, and leaves nothing behind" \
    || fail "GIT-28 _ver_run with no descriptor (status, whether it started its command, that command, the caller's job, _ver_cur: '$got'; left in TMPDIR: $(ls -A "$TMP/fdr50" | head -1))"
else
  printf 'NOTE: ulimit -n 10 is refused here; the descriptor check is not applicable\n'
fi
# A packed-refs padded with newlines, and a tag whose name ends in them: read in
# time linear in their size. A trim of trailing newlines in bash was quadratic,
# and a planted 2 MiB file held --version for hours, SIGINT and all (sixth
# review of the GIT-28 fix).
n28="$TMP/n28"; mkdir -p "$n28"
if mkrepo "$n28" v2.8.3 && git -C "$n28" pack-refs --all; then
  w="$(want28 "$n28")"
  awk 'BEGIN { for (i = 0; i < 200000; i++) printf "\n" }' >> "$n28/.git/packed-refs"
  # An empty tag file must not cost the answer either.
  nl28="$(printf 'x%0200dx' 0 | tr 0 '\n')"; nl28="${nl28#x}"; nl28="${nl28%x}"
  : > "$n28/.git/refs/tags/nl28$nl28"; : > "$n28/.git/refs/tags/empty28"
  t28=$SECONDS; ver28_bounded 20 "$n28" "$TMP/out28n"; rc=$?; e28=$(( SECONDS - t28 ))
  [[ "$rc" == 0 && "$(cat "$TMP/out28n")" == "$w" ]] && (( e28 < 8 )) \
    && pass "GIT-28 a packed-refs padded with newlines, a tag name ending in them and an empty tag are read in linear time" \
    || fail "GIT-28 newlines in packed-refs and a tag name (rc=$rc in $e28 s; got '$(tr '\n' ';' < "$TMP/out28n")', git says '$w')"
else
  fail "GIT-28 scaffold: could not build the packed-refs fixture"
fi
# A shallow clone whose tags were fetched to a depth of their own: git stops at
# the shallow boundary, and so must the repository written for it, or it walks
# on to a tag git cannot reach (sixth review of the GIT-28 fix).
sd28="$TMP/sd28src"; mkdir -p "$sd28"
if mkrepo "$sd28" v2.8.2; then
  for i28 in $(seq 1 20); do git -C "$sd28" commit -q --allow-empty -m "c$i28"; done
  git -C "$sd28" tag -d v2.8.2 >/dev/null && git -C "$sd28" tag -a v2.8.2 -m v HEAD~10
  if git clone -q --depth 10 "file://$sd28" "$TMP/sd28" 2>/dev/null && git -C "$TMP/sd28" fetch -q --depth 10 --tags 2>/dev/null; then
    : > "$TMP/sd28/project-init.sh"
    # No tag within it: git describes nothing, and the answer is the short commit.
    got="$(ver28 "$TMP/sd28")"; w="$(want28 "$TMP/sd28")"
    [[ -n "$w" ]] || w="$(git -C "$TMP/sd28" rev-parse --short HEAD)"
    [[ "$got" == "$w" && "$got" != v* ]] && pass "GIT-28 a shallow clone stops at its shallow boundary, as git does" \
      || fail "GIT-28 a shallow clone's boundary (got '$got', git says '$w')"
  else
    fail "GIT-28 scaffold: could not make the shallow clone"
  fi
else
  fail "GIT-28 scaffold: could not build the shallow source"
fi
# git is asked with a cap on what it allocates: a forged loose object that
# declared 1.5 GiB took git to that much memory (sixth review of the GIT-28
# fix). Seen in the environment of the describe it runs.
mkdir -p "$TMP/al28"; : > "$TMP/al28.log"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "${GIT_ALLOC_LIMIT:-unset}" "$*" >> "%s"\nexec %s "$@"\n' "$TMP/al28.log" "$(command -v git)" > "$TMP/al28/git"
chmod +x "$TMP/al28/git"
PATH="$TMP/al28:$PATH" ver28 "$gtag" >/dev/null
# git config too, which reads a config a port's base/ mounted alone leaves
# writable (seventh review).
grep -q '^64m .*describe --tags' "$TMP/al28.log" && grep -q '^64m config --file' "$TMP/al28.log" \
  && ! grep -q -e '^unset .*describe' -e '^unset config --file' "$TMP/al28.log" \
  && pass "GIT-28 git describes, and reads the config, with GIT_ALLOC_LIMIT set" \
  || fail "GIT-28 GIT_ALLOC_LIMIT ($(grep -e describe -e 'config --file' "$TMP/al28.log" | tr '\n' ';'))"
# A loose tag written without its newline is read, as git reads it.
nn28="$TMP/nn28"; mkdir -p "$nn28"
if mkrepo "$nn28"; then
  printf '%s' "$(git -C "$nn28" rev-parse HEAD)" > "$nn28/.git/refs/tags/v2.8.1-nonl"
  got="$(ver28 "$nn28")"; w="$(want28 "$nn28")"
  [[ "$got" == v2.8.1-nonl && "$got" == "$w" ]] && pass "GIT-28 a loose tag without its newline is read" \
    || fail "GIT-28 a loose tag without its newline (got '$got', git says '$w')"
else
  fail "GIT-28 scaffold: could not build the no-newline fixture"
fi
# A recorded engine-version is its first line, whitespace dropped, as before.
ew28="$TMP/ew28"; mkdir -p "$ew28"; printf '  v9.8.7 \t\nsecond line\n' > "$ew28/engine-version"
got="$(ver28 "$ew28")"
[[ "$got" == v9.8.7 ]] && pass "GIT-28 a recorded engine-version is its first line, whitespace dropped" \
  || fail "GIT-28 a recorded engine-version's first line (got '$got')"
# A recorded engine-version that is a sparse file of no newline: read 4096
# bytes at most, at once (`head -1` read all of it).
ev28="$TMP/ev28"; mkdir -p "$ev28"
if dd if=/dev/null of="$ev28/engine-version" bs=1 count=0 seek=17179869184 2>/dev/null; then
  ver28_bounded 15 "$ev28" "$TMP/out28e"; rc=$?
  [[ "$rc" == 0 && "$(cat "$TMP/out28e")" == unknown ]] \
    && pass "GIT-28 a huge engine-version with no newline is read 4096 bytes at most" \
    || fail "GIT-28 a huge engine-version (rc=$rc; $(tr '\n' ';' < "$TMP/out28e"))"
else
  printf 'NOTE: could not make a sparse file here; the engine-version check is not applicable\n'
fi
# A port's base/: the enclosing repository's describe.
m28="$TMP/m28"; mkdir -p "$m28/base"; : > "$m28/base/project-init.sh"
if git -C "$m28" init -q && git -C "$m28" add -A && git -C "$m28" -c user.email=t@t -c user.name=t commit -qm m \
   && git -C "$m28" -c user.email=t@t -c user.name=t tag -a v2.8.7 -m v; then
  got="$(ver28 "$m28/base")"
  [[ "$got" == v2.8.7 ]] && pass "GIT-28 a port's base/ gives its repository's describe" || fail "GIT-28 a port's base/ (got '$got')"
else
  fail "GIT-28 scaffold: could not build a port's base/"
fi
# A sha256 repository: its own format, from its config.
g28s="$TMP/g28s"; mkdir -p "$g28s"
if git -C "$g28s" init -q --object-format=sha256 >/dev/null 2>&1; then
  : > "$g28s/project-init.sh"
  git -C "$g28s" add -A && git -C "$g28s" -c user.email=t@t -c user.name=t commit -qm s \
    && git -C "$g28s" -c user.email=t@t -c user.name=t tag -a v2.8.6 -m v
  got="$(ver28 "$g28s")"
  [[ "$got" == v2.8.6 ]] && pass "GIT-28 a sha256 repository is read in its own format" || fail "GIT-28 a sha256 repository (got '$got')"
else
  printf 'NOTE: this git cannot make a sha256 repository; that check is not applicable\n'
fi
# How the checkout is found, as git finds it. A .git file is a gitdir: line,
# its CR and LF dropped; without the prefix git refuses it, and so does this.
r28="$TMP/r28"; mkdir -p "$r28"
if mkrepo "$r28" v2.8.9; then
  mkdir -p "$TMP/w28"; : > "$TMP/w28/project-init.sh"
  printf 'gitdir: %s\r\n' "$r28/.git" > "$TMP/w28/.git"
  got="$(ver28 "$TMP/w28")"
  [[ "$got" == v2.8.9 ]] && pass "GIT-28 a .git file ending in CRLF is followed" || fail "GIT-28 a .git file ending in CRLF (got '$got')"
  printf '%s\n' "$r28/.git" > "$TMP/w28/.git"
  got="$(ver28 "$TMP/w28")"
  [[ "$got" == unknown ]] && pass "GIT-28 a .git file without its gitdir: prefix is refused, as git refuses it" \
    || fail "GIT-28 a .git file without the prefix (got '$got')"
  # The reftable format keeps refs in no file this can read: no answer, rather
  # than a wrong one. The files format, written out, is read as before. Written
  # as a file: git itself refuses a repository it takes for reftable.
  GIT_DIR=/dev/null git config --file "$r28/.git/config" extensions.refStorage reftable
  got="$(ver28 "$r28")"
  [[ "$got" == unknown ]] && pass "GIT-28 a reftable repository is not read" || fail "GIT-28 a reftable repository (got '$got')"
  GIT_DIR=/dev/null git config --file "$r28/.git/config" extensions.refStorage files
  got="$(ver28 "$r28")"
  [[ "$got" == v2.8.9 ]] && pass "GIT-28 extensions.refStorage=files is read" || fail "GIT-28 extensions.refStorage=files (got '$got')"
  GIT_DIR=/dev/null git config --file "$r28/.git/config" --unset extensions.refStorage
  # HEAD a link to a regular file, HEAD naming a branch with `..` in it, and a
  # branch that is a link to a regular file: none is read, so no answer (git
  # follows the links, and refuses the `..`).
  git -C "$r28" rev-parse HEAD > "$TMP/oid28"; b28="$(git -C "$r28" symbolic-ref HEAD)"
  mv "$r28/.git/HEAD" "$TMP/head28"; cp "$TMP/head28" "$TMP/headcopy28"; ln -s "$TMP/headcopy28" "$r28/.git/HEAD"
  got="$(ver28 "$r28")"; rm -f "$r28/.git/HEAD"; mv "$TMP/head28" "$r28/.git/HEAD"
  [[ "$got" == unknown ]] && pass "GIT-28 a HEAD that is a link is not read" || fail "GIT-28 a HEAD that is a link (got '$got')"
  cp "$TMP/oid28" "$r28/.git/other28"; cp "$r28/.git/HEAD" "$TMP/head28"
  printf 'ref: refs/heads/../../other28\n' > "$r28/.git/HEAD"
  got="$(ver28 "$r28")"; cp "$TMP/head28" "$r28/.git/HEAD"; rm -f "$r28/.git/other28"
  [[ "$got" == unknown ]] && pass "GIT-28 a HEAD naming a branch with .. in it is refused" || fail "GIT-28 a HEAD with .. (got '$got')"
  mv "$r28/.git/$b28" "$TMP/branch28"; ln -s "$TMP/branch28" "$r28/.git/$b28"
  got="$(ver28 "$r28")"; rm -f "$r28/.git/$b28"; mv "$TMP/branch28" "$r28/.git/$b28"
  [[ "$got" == unknown ]] && pass "GIT-28 a branch that is a link to a file is not read" || fail "GIT-28 a branch that is a link to a file (got '$got')"
  # A refs/tags that is a link to a directory of tags: not followed, so only the
  # packed tags count (none here): the short commit.
  mv "$r28/.git/refs/tags" "$TMP/tags28"; ln -s "$TMP/tags28" "$r28/.git/refs/tags"
  got="$(ver28 "$r28")"; rm -f "$r28/.git/refs/tags"; mv "$TMP/tags28" "$r28/.git/refs/tags"
  [[ "$got" == "$(git -C "$r28" rev-parse --short HEAD)" ]] && pass "GIT-28 a refs/tags that is a link is not followed" \
    || fail "GIT-28 a refs/tags that is a link (got '$got')"
  # A tag line without an object id, packed or loose: dropped, as git would not
  # read it, so the refs written for git stay readable and the tag still counts.
  printf 'not-an-oid refs/tags/junk28\n' >> "$r28/.git/packed-refs"; printf 'zz\n' > "$r28/.git/refs/tags/junk28b"
  got="$(ver28 "$r28")"
  sed -i.bak '/junk28/d' "$r28/.git/packed-refs"; rm -f "$r28/.git/packed-refs.bak" "$r28/.git/refs/tags/junk28b"
  [[ "$got" == v2.8.9 ]] && pass "GIT-28 a tag with no object id, packed or loose, is dropped" \
    || fail "GIT-28 a tag with no object id (got '$got')"
  # HEAD with trailing whitespace, as git trims it; and a detached HEAD.
  cp "$r28/.git/HEAD" "$TMP/head28"; printf 'ref: %s \n' "$b28" > "$r28/.git/HEAD"
  got="$(ver28 "$r28")"; cp "$TMP/head28" "$r28/.git/HEAD"
  [[ "$got" == v2.8.9 ]] && pass "GIT-28 a HEAD with trailing whitespace is read as git reads it" || fail "GIT-28 a HEAD with trailing whitespace (got '$got')"
  git -C "$r28" commit -q --allow-empty -m d && git -C "$r28" checkout -q --detach HEAD
  got="$(ver28 "$r28")"; w="$(want28 "$r28")"
  git -C "$r28" checkout -q "${b28#refs/heads/}" && git -C "$r28" reset -q --hard HEAD~1
  [[ "$got" == v2.8.9-1-g* && "$got" == "$w" ]] && pass "GIT-28 a detached HEAD gives git's own describe" || fail "GIT-28 a detached HEAD (got '$got', git says '$w')"
  # A HEAD that is a FIFO is not read: no answer, at once.
  mv "$r28/.git/HEAD" "$TMP/head28"; mkfifo "$r28/.git/HEAD"
  got="$(VER28_SECS=2 ver28 "$r28")"
  rm -f "$r28/.git/HEAD"; mv "$TMP/head28" "$r28/.git/HEAD"
  [[ "$got" == unknown ]] && pass "GIT-28 a HEAD that is a FIFO gives no answer, without waiting on it" \
    || fail "GIT-28 a HEAD that is a FIFO (got '$got')"
  # An include naming a FIFO: the config is never read by git, so it is never
  # opened, and the version is given.
  git -C "$r28" config include.path "$TMP/inc28"; mkfifo "$TMP/inc28"
  ver28_bounded 40 "$r28" "$TMP/out28"; rc=$?
  left28="$(pgrep -g "$vb28" 2>/dev/null | head -1)"
  ( exec 3<>"$TMP/inc28" ) 2>/dev/null; rm -f "$TMP/inc28"; git -C "$r28" config --unset include.path
  if (( rc == 0 )) && [[ -z "$left28" ]] && grep -qx v2.8.9 "$TMP/out28"; then
    pass "GIT-28 an include that names a FIFO is never read: the checkout's config is not git's"
  else
    fail "GIT-28 an include that names a FIFO (rc=$rc; reader left: ${left28:-none}; $(tr '\n' ';' < "$TMP/out28"))"
  fi
  # HEAD's commit a FIFO among the loose objects, which git does open: describe
  # is cut off at the bound, and that is named.
  c28="$(git -C "$r28" rev-parse HEAD)"; o28="$r28/.git/objects/${c28:0:2}/${c28:2}"
  mv "$o28" "$TMP/obj28"; mkfifo "$o28"
  ver28_bounded 40 "$r28" "$TMP/out28"; rc=$?
  left28="$(pgrep -g "$vb28" 2>/dev/null | head -1)"
  if (( rc == 0 )) && [[ -z "$left28" ]] && grep -qx unknown "$TMP/out28" && grep -q 'NOTE: git did not answer within 2 s' "$TMP/out28"; then
    pass "GIT-28 an object that is a FIFO does not hold the version, and is named"
  else
    fail "GIT-28 an object that is a FIFO (rc=$rc; reader left: ${left28:-none}; $(tr '\n' ';' < "$TMP/out28"))"
  fi
  # Interrupted while git waits on that FIFO: the git it was running is gone too,
  # though it ignores SIGINT.
  if [[ -n "$(${sigpre28[@]+"${sigpre28[@]}"} bash -c 'trap -p INT')" ]]; then
    printf 'NOTE: SIGINT is ignored where this runs; the interrupted-read check is not applicable\n'
  else
    set -m
    ${sigpre28[@]+"${sigpre28[@]}"} bash -c 'source "$1/version.sh"; version_engine "$2"' _ "$REPO_DIR" "$r28" >/dev/null 2>&1 &
    p28=$!
    set +m
    job28 "$p28"
    sleep 1; kill -INT -"$p28" 2>/dev/null; wait "$p28" 2>/dev/null; sleep 0.3
    left28="$(pgrep -g "$p28" 2>/dev/null | head -1)"
    [[ -z "$left28" ]] \
      && pass "GIT-28 a check interrupted while git reads a FIFO leaves no git behind" \
      || fail "GIT-28 an interrupted check left git $left28 blocked on the FIFO"
  fi
  ( exec 3<>"$o28" ) 2>/dev/null; rm -f "$o28"; mv "$TMP/obj28" "$o28"
else
  fail "GIT-28 scaffold: could not build the .git-file fixture"
fi
# An engine tree in no repository at all: unknown, and the search for a .git
# ends at /.
mkdir -p "$TMP/lone28"; : > "$TMP/lone28/project-init.sh"
ver28_bounded 30 "$TMP/lone28" "$TMP/out28l"; rc=$?
[[ "$rc" == 0 && "$(cat "$TMP/out28l")" == unknown ]] \
  && pass "GIT-28 an engine tree in no repository is unknown, the search for .git ending at /" \
  || fail "GIT-28 an engine tree in no repository (rc=$rc; $(tr '\n' ';' < "$TMP/out28l"))"
# _ver_run on its own: a read cut off leaves nothing behind for the next one,
# its descriptor is closed, and _ver_cur, which the traps kill, names nothing
# once a call is over. Bounded: a _ver_run that cannot cut a read off waits on
# the FIFO, and must fail here, not at the falsify tier's clock.
mkfifo "$TMP/f28"; : > "$TMP/out28r"
set -m
bash -c 'source "$1/version.sh"; _ver_secs=1; o=""
         _ver_run o cat -- "$2"; a=$?; c1="[$_ver_cur]"
         n1="$(ls /dev/fd | wc -l)"; _ver_run o printf x; b=$?; n2="$(ls /dev/fd | wc -l)"
         printf "%s %s %s %s %s %s%s" "$a" "$b" "$o" "$(( n2 - n1 ))" "${_vr_p-unset}" "$c1" "[$_ver_cur]"' _ "$REPO_DIR" "$TMP/f28" > "$TMP/out28r" 2>&1 &
p28=$!
set +m
job28 "$p28"
w28=0; while kill -0 "$p28" 2>/dev/null && (( w28 < 200 )); do sleep 0.1; w28=$(( w28 + 1 )); done
if kill -0 "$p28" 2>/dev/null; then kill -KILL -"$p28" 2>/dev/null || kill -KILL "$p28" 2>/dev/null; fi
wait "$p28" 2>/dev/null
( exec 3<>"$TMP/f28" ) 2>/dev/null; rm -f "$TMP/f28"
got="$(cat "$TMP/out28r")"
[[ "$got" == "124 0 x 0 unset [][]" ]] \
  && pass "GIT-28 _ver_run: a read cut off does not spoil the next, its descriptor is closed, its variables are its own" \
  || fail "GIT-28 _ver_run (cut-off status, next status, next output, descriptors left, _vr_p, _ver_cur after each: '$got')"
# The caller killed alone, while git is slow but answering: the subshell asking
# git goes on, and died of SIGPIPE at its answer, which came before its
# temporary directory was removed (seventh review of the GIT-28 fix).
mkdir -p "$TMP/tmpp28" "$TMP/slowgit28"
printf '#!/bin/sh\nsleep 1\nexec %s "$@"\n' "$(command -v git)" > "$TMP/slowgit28/git"; chmod +x "$TMP/slowgit28/git"
set -m
TMPDIR="$TMP/tmpp28" PATH="$TMP/slowgit28:$PATH" bash -c 'source "$1/version.sh"; version_engine "$2"' _ "$REPO_DIR" "$gtag" >/dev/null 2>&1 &
p28=$!
set +m
job28 "$p28"
w28=0; while [[ -z "$(ls -A "$TMP/tmpp28")" ]] && kill -0 "$p28" 2>/dev/null && (( w28 < 100 )); do sleep 0.1; w28=$(( w28 + 1 )); done
saw28="$(ls -A "$TMP/tmpp28")"
kill -TERM "$p28" 2>/dev/null; wait "$p28" 2>/dev/null
w28=0; while [[ -n "$(ls -A "$TMP/tmpp28")" ]] && (( w28 < 150 )); do sleep 0.1; w28=$(( w28 + 1 )); done
[[ -n "$saw28" && -z "$(ls -A "$TMP/tmpp28")" ]] \
  && pass "GIT-28 a caller killed alone leaves no temporary directory behind" \
  || fail "GIT-28 a caller killed alone (made: '${saw28:-nothing}'; left: '$(ls -A "$TMP/tmpp28")')"
kill -KILL -"$p28" 2>/dev/null
# macOS's /usr/bin/git with no developer directory holding a git: not run (it
# opens the Command Line Tools' installer). Faked with uname and xcode-select.
mkdir -p "$TMP/mac28" "$TMP/xcs28" "$TMP/brew28"
printf '#!/bin/sh\necho Darwin\n' > "$TMP/mac28/uname"
printf '#!/bin/sh\necho /nonexistent/CommandLineTools\n' > "$TMP/xcs28/xcode-select"
chmod +x "$TMP/mac28/uname" "$TMP/xcs28/xcode-select"
# Only that git: one installed elsewhere (Homebrew's) runs on such a Mac, and
# off macOS what xcode-select says does not matter.
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v git)" > "$TMP/brew28/git"; chmod +x "$TMP/brew28/git"
got="$(PATH="$TMP/brew28:$TMP/mac28:$TMP/xcs28:$PATH" ver28 "$gtag")"
[[ "$got" == v1.0.0* ]] \
  && pass "GIT-28 a git other than /usr/bin/git runs on a Mac without the Command Line Tools" \
  || fail "GIT-28 a Homebrew git on a Mac without the Command Line Tools (got '$got')"
got="$(PATH="$TMP/xcs28:$PATH" ver28 "$gtag")"
[[ "$got" == v1.0.0* ]] \
  && pass "GIT-28 off macOS, xcode-select's answer does not stop git" \
  || fail "GIT-28 off macOS, xcode-select stopped git (got '$got')"
# With git on PATH not at all: nothing is started to ask it (env, here). What
# _ver_run itself runs is there (mktemp, mkfifo, head, rm), so only git is missing.
mkdir -p "$TMP/nogit28"; : > "$TMP/env28.log"
for c in bash mktemp mkfifo head rm; do ln -s "$(command -v "$c")" "$TMP/nogit28/$c"; done
printf '#!%s\nprintf "%%s\\n" "$*" >> "%s"\nexec %s "$@"\n' "$(command -v bash)" "$TMP/env28.log" "$(command -v env)" > "$TMP/nogit28/env"
chmod +x "$TMP/nogit28/env"
got="$(PATH="$TMP/nogit28" ver28 "$gtag")"
[[ "$got" == unknown && ! -s "$TMP/env28.log" ]] \
  && pass "GIT-28 with no git on PATH, nothing is started to ask it" \
  || fail "GIT-28 with no git on PATH (got '$got'; started: $(head -1 "$TMP/env28.log"))"
if [[ "$(command -v git)" == /usr/bin/git ]]; then
  # xcode-select -p fails outright on a Mac that never had the tools: that is
  # not a developer directory holding a git. Through PATH as /usr//bin, which is
  # still the shim (compared with -ef).
  mkdir -p "$TMP/xcf28"; printf '#!/bin/sh\nexit 2\n' > "$TMP/xcf28/xcode-select"; chmod +x "$TMP/xcf28/xcode-select"
  got="$(PATH="$TMP/mac28:$TMP/xcf28:/usr//bin:$PATH" ver28 "$gtag")"
  [[ "$got" == unknown ]] \
    && pass "GIT-28 macOS's git shim is not run when xcode-select -p fails" \
    || fail "GIT-28 macOS's git shim was run when xcode-select -p failed (got '$got')"
  # A Mac with the tools: their developer directory holds a git, so it runs.
  mkdir -p "$TMP/dev28/usr/bin" "$TMP/xcd28"; : > "$TMP/dev28/usr/bin/git"; chmod +x "$TMP/dev28/usr/bin/git"
  printf '#!/bin/sh\necho %s\n' "$TMP/dev28" > "$TMP/xcd28/xcode-select"; chmod +x "$TMP/xcd28/xcode-select"
  got="$(PATH="$TMP/mac28:$TMP/xcd28:$PATH" ver28 "$gtag")"
  [[ "$got" == v1.0.0* ]] \
    && pass "GIT-28 macOS's git runs where the Command Line Tools are installed" \
    || fail "GIT-28 macOS's git with the Command Line Tools installed (got '$got')"
  got="$(PATH="$TMP/mac28:$TMP/xcs28:$PATH" ver28 "$gtag")"
  [[ "$got" == unknown ]] \
    && pass "GIT-28 macOS's git shim with no Command Line Tools is not run" \
    || fail "GIT-28 macOS's git shim was run (got '$got')"
else
  printf 'NOTE: git is not /usr/bin/git here; the macOS shim checks are not applicable\n'
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
