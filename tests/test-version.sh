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

# ── The engine release, in the base repo: derived from git ────────────────────
# `git describe --tags` and not `describe --tags --abbrev=0`: the suffix is the
# honest part. A copy taken five commits after v0.7.0 is not v0.7.0, and saying
# so is the difference between a version and a wish.
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
