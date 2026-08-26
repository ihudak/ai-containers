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
#                        exists solely to keep it current, so reporting it is
#                        reporting the output of that job.
#
# The engine release is the one that can LIE, and these tests are mostly about
# that: a project copy reports what it was told at sync time, and a copy that
# was never told must say so rather than inventing a number or printing a blank.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

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
grep -q '77' <<<"$alt" \
  && pass "the schema version is read from the active sandbox.conf" \
  || fail "the schema version is read from the active sandbox.conf (got: $alt)"
grep -q 'v1.2.3' <<<"$alt" \
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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
