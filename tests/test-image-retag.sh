#!/usr/bin/env bash
# Tests for ai_containers_retag_check() (sandbox-common.sh) and the portable
# IMAGE_NAME rule (env_value_portable): ENV-7. A committed sandbox.env can name
# another project's image tag, or a base image such as ubuntu:24.04, and
# ./build.sh then retagged it with this project's image and allowlist.
#
# A fake `docker` answers `image inspect` from FAKE_LABELS: `none` (no such
# image), or the JSON docker prints for .Config.Labels.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_DIR"; [[ -f "$REPO_DIR/base/entrypoint.sh" ]] && ENGINE="$REPO_DIR/base"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ENGINE/sandbox-common.sh"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 ${2:-}" == "image inspect" ]] || exit 0
[[ "$FAKE_LABELS" == none ]] && { printf '\n'; exit 1; }
case "$*" in
  *'{{json .Config.Labels}}'*) printf '%s\n' "$FAKE_LABELS" ;;
  *'ai-containers.project'*)
    v="$(printf '%s' "$FAKE_LABELS" | sed -n 's/.*"ai-containers\.project":"\([^"]*\)".*/\1/p')"
    printf '%s\n' "$v" ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

ME="$TMP/proj/.ai-containers"; mkdir -p "$ME"; ME="$(cd "$ME" && pwd -P)"

# check LABELS → sets rc and err
check() { err="$(FAKE_LABELS="$1" ai_containers_retag_check img:tag "$ME" 2>&1)"; rc=$?; }

check none
[[ "$rc" == 0 && -z "$err" ]] && pass "a tag no image carries yet is built" || fail "new tag (rc=$rc: $err)"

check '{"ai-containers.built-at":"x","ai-containers.project":"'"$ME"'"}'
[[ "$rc" == 0 && -z "$err" ]] && pass "this project's own image is rebuilt" || fail "own image (rc=$rc: $err)"

SIB="$TMP/sib/.ai-containers"; mkdir -p "$SIB"
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$SIB"'"}'
[[ "$rc" != 0 ]] && grep -qF "$SIB" <<<"$err" \
  && pass "another project's image is not retagged, and the project is named" \
  || fail "another project's image (rc=$rc: $err)"

# A project that moved left its old path behind: nothing there to overwrite
# (review of the batch 10 branch).
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$TMP/gone/.ai-containers"'"}'
[[ "$rc" == 0 ]] && grep -qF 'no longer exists' <<<"$err" \
  && pass "an image built for a path that no longer exists (a moved project) is rebuilt, with a NOTE" \
  || fail "moved project (rc=$rc: $err)"

# …but a path you cannot stat is not proof it moved: under another user's 0700
# home it only looks absent (review of the batch 10 branch).
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$TMP/locked/proj/.ai-containers"; chmod 000 "$TMP/locked"
  check '{"ai-containers.built-at":"x","ai-containers.project":"'"$TMP/locked/proj/.ai-containers"'"}'
  chmod 755 "$TMP/locked"
  [[ "$rc" != 0 ]] && pass "an image built for a path this user cannot see is not taken for a moved project" \
    || fail "unstatable project path (rc=$rc: $err)"
fi

# A project label that is not an absolute path is not one this tool wrote, and
# the walk up for a moved project spun on it for ever (automated security
# review of 818cb3e).
t0=$SECONDS
err="$(FAKE_LABELS='{"ai-containers.built-at":"x","ai-containers.project":"relative"}' timeout 10 bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_retag_check img:tag "$2"' _ "$ENGINE" "$ME" 2>&1)"; rc=$?
[[ "$rc" != 0 && "$rc" != 124 && $((SECONDS - t0)) -lt 10 ]] && pass "a project label that is not an absolute path is refused, promptly" \
  || fail "relative project label (rc=$rc in $((SECONDS - t0))s: $err)"

# Only a committed IMAGE_NAME is checked: one you set in sandbox.local.env or the
# shell is yours, a second clone's or a test harness's included.
g1="$(FAKE_LABELS='{"maintainer":"ubuntu"}' bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; unset ai_containers_image_portable; ai_containers_build_retag_guard ubuntu:24.04 "$2"; echo "rc=$?"' _ "$ENGINE" "$ME" 2>/dev/null | tail -1)"
g2="$(FAKE_LABELS='{"maintainer":"ubuntu"}' bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_image_portable=1; ai_containers_build_retag_guard ubuntu:24.04 "$2"; echo "rc=$?"' _ "$ENGINE" "$ME" 2>/dev/null | tail -1)"
[[ "$g1" == rc=0 && "$g2" == rc=1 ]] && pass "only an IMAGE_NAME from the committed sandbox.env is checked" \
  || fail "the guard (local: $g1, committed: $g2)"
# The guard compares physical paths: this project's own image, rebuilt through a
# link to it, is not "another project" (review of 162d4c3).
mkdir -p "$TMP/via"; ln -s "$ME" "$TMP/via/me"
g3="$(FAKE_LABELS='{"ai-containers.built-at":"x","ai-containers.project":"'"$ME"'"}' bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_image_portable=1; ai_containers_build_retag_guard img:tag "$2"; echo "rc=$?"' _ "$ENGINE" "$TMP/via/me" 2>/dev/null | tail -1)"
[[ "$g3" == rc=0 ]] && pass "the project's own image, rebuilt through a link to it, passes" || fail "own image through a link ($g3)"

check '{"maintainer":"ubuntu"}'
[[ "$rc" != 0 ]] && grep -qF 'did not build' <<<"$err" \
  && pass "an image with no ai-containers labels (a base image) is not retagged" \
  || fail "base image (rc=$rc: $err)"

check 'null'
[[ "$rc" != 0 ]] && pass "an image with no labels at all is not retagged" || fail "no labels (rc=$rc: $err)"

# The label is a KEY: the same text inside another label's value is not one
# (review of the batch 10 merge). JSON escapes the quotes inside a value.
check '{"maintainer":"see \"ai-containers.project\" docs"}'
[[ "$rc" != 0 ]] && pass "ai-containers. inside another label's value does not pass for an ai-containers label" \
  || fail "label text in a value (rc=$rc: $err)"

# An image ai-containers built before v0.6.0 added its labels carries only the
# Dockerfile's image title; it is rebuilt, with the NOTE (carried over from the
# ENV-7 fix on main).
check '{"org.opencontainers.image.title":"AI Sandbox Container"}'
[[ "$rc" == 0 ]] && grep -qF 'NOTE' <<<"$err" \
  && pass "an image built before ai-containers labelled its images is rebuilt, with a NOTE" \
  || fail "pre-v0.6.0 image (rc=$rc: $err)"
# …as a real one carries it: after other keys, which docker sorts before it
# (review of 162d4c3).
check '{"maintainer":"x","org.opencontainers.image.description":"y","org.opencontainers.image.source":"z","org.opencontainers.image.title":"AI Sandbox Container"}'
[[ "$rc" == 0 ]] && pass "the pre-v0.6.0 title is found after other keys" || fail "pre-v0.6.0 title after other keys (rc=$rc: $err)"
# An ai-containers key after another key is ours too.
check '{"a.b":"x","ai-containers.built-at":"x","ai-containers.project":"'"$ME"'"}'
[[ "$rc" == 0 ]] && pass "an ai-containers key after another key is recognised" || fail "ai-containers key after another (rc=$rc: $err)"

check '{"ai-containers.built-at":"x"}'
[[ "$rc" == 0 ]] && grep -qF 'NOTE' <<<"$err" \
  && pass "an image built before the project label is rebuilt, with a NOTE" \
  || fail "pre-label image (rc=$rc: $err)"

# A symlinked engine copy is the same project: the label is the physical path
# (carried over from main's ENV-7 tests).
mkdir -p "$TMP/linkdir"; ln -s "$ME" "$TMP/linkdir/lnk"
grep -qxF -- "ai-containers.project=$ME" <<<"$(ai_containers_provenance_labels "$TMP/linkdir/lnk" 2026-01-01T00:00:00Z)" \
  && pass "a symlinked engine copy records the same project" || fail "symlinked engine copy"
# Every build is stamped with the project it came from.
grep -qxF -- "ai-containers.project=$ME" <<<"$(ai_containers_provenance_labels "$ME" 2026-01-01T00:00:00Z)" \
  && pass "the labels carry the project's own directory" || fail "no project label"

# A committed IMAGE_NAME names a local image: a registry host or a namespace is
# refused from sandbox.env (sandbox.local.env and the shell are yours).
r=""
env_value_portable IMAGE_NAME ghcr.io/x/img && r+=" registry"
env_value_portable IMAGE_NAME library/ubuntu && r+=" namespace"
env_value_portable IMAGE_NAME my-proj-img || r+=" plain-refused"
env_value_portable IMAGE_NAME my-proj-img:dev || r+=" tag-refused"
[[ -z "$r" ]] && pass "a portable IMAGE_NAME is a local name: no registry host, no namespace" || fail "IMAGE_NAME rule:$r"

# SANDBOX_GIT_FIXTURES is gone: a committed list could exempt a bare repository
# you push to from its placeholders (LNCH-16). sandbox.env ignores it now.
env_key_portable SANDBOX_GIT_FIXTURES && fail "SANDBOX_GIT_FIXTURES is still a portable key" \
  || pass "SANDBOX_GIT_FIXTURES is no longer a portable key"

# build.sh itself runs the guard, before docker build: an engine copy whose
# committed sandbox.env names a base image is refused, and docker build is never
# called (review of the batch 10 branch: deleting the call passed everything).
E="$TMP/eng"; mkdir -p "$E"
( cd "$ENGINE" && git ls-files -z 2>/dev/null | xargs -0 -I{} cp --parents {} "$E/" ) 2>/dev/null \
  || cp -R "$ENGINE"/. "$E/"
# cp -R (BSD cp has no --parents) also copies a built checkout's generated
# allowlists, which the "writes nothing" check below must not find (review of
# 162d4c3).
rm -f "$E"/allowlist-*.txt
printf 'IMAGE_NAME=ubuntu:24.04\n' > "$E/sandbox.env"; rm -f "$E/sandbox.local.env"
cat > "$TMP/bin/docker" <<'FAKE2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 ${2:-}" in
  "image inspect") case "$*" in *'{{json .Config.Labels}}'*) printf '{"maintainer":"ubuntu"}\n' ;; *) printf 'sha256:abc\n' ;; esac; exit 0 ;;
esac
exit 0
FAKE2
chmod +x "$TMP/bin/docker"; export DOCKER_LOG="$TMP/docker.log"; : > "$DOCKER_LOG"
( cd "$E" && unset IMAGE_NAME && bash ./build.sh ) >/dev/null 2>"$TMP/build.err"; brc=$?
# …and before anything is written: the allowlists are generated after the guard
# (review of the batch 10 merge; main's ENV-7 tests checked this).
[[ "$brc" != 0 ]] && grep -qF 'did not build' "$TMP/build.err" && ! grep -q '^build ' "$DOCKER_LOG" \
  && [[ ! -e "$E/allowlist-domains.txt" ]] \
  && pass "build.sh refuses to retag a base image a committed sandbox.env names, before anything is written" \
  || fail "build.sh retag guard (rc=$brc; $(grep -E 'ERROR|did not' "$TMP/build.err" | head -1); docker build called: $(grep -c '^build ' "$DOCKER_LOG"))"

# The same base image named where the user chose it is built: in
# sandbox.local.env (which wins over sandbox.env), inline in the shell, or a
# different name given as build.sh's argument; the committed name given as the
# argument is still checked (reviews of 162d4c3 and f596986).
reached() { grep -q '^build ' "$DOCKER_LOG"; }
: > "$DOCKER_LOG"; printf 'IMAGE_NAME=ubuntu:24.04\n' > "$E/sandbox.local.env"
( cd "$E" && unset IMAGE_NAME && bash ./build.sh ) >/dev/null 2>"$TMP/build.err"; r1=$?; reached && r1=built
rm -f "$E/sandbox.local.env"; : > "$DOCKER_LOG"
( cd "$E" && IMAGE_NAME=ubuntu:24.04 bash ./build.sh ) >/dev/null 2>"$TMP/build.err"; r2=$?; reached && r2=built
: > "$DOCKER_LOG"
( cd "$E" && unset IMAGE_NAME && bash ./build.sh other:tag ) >/dev/null 2>"$TMP/build.err"; r3=$?; reached && r3=built
: > "$DOCKER_LOG"
( cd "$E" && unset IMAGE_NAME && bash ./build.sh ubuntu:24.04 ) >/dev/null 2>"$TMP/build.err"; r4=$?; reached && r4=built
[[ "$r1" == built && "$r2" == built && "$r3" == built && "$r4" == 1 ]] \
  && pass "an IMAGE_NAME from sandbox.local.env, the shell or a different argument is built; the committed one as the argument is checked" \
  || fail "user-chosen names (local: $r1, shell: $r2, other argument: $r3, committed argument: $r4)"
rm -f "$E"/allowlist-*.txt

# A project still on the removed host group is refused by build.sh too, before
# docker build: runme.sh builds first, and the whole image was built for a launch
# that is refused (LNCH-20).
: > "$DOCKER_LOG"
( cd "$E" && AI_CONTAINER_GROUP=host bash ./build.sh other:tag ) >/dev/null 2>"$TMP/build.err"; rh=$?
[[ "$rh" != 0 ]] && grep -qF 'AI_CONTAINER_GROUP=host is no longer supported' "$TMP/build.err" && ! reached \
  && [[ ! -e "$E/allowlist-domains.txt" ]] \
  && pass "build.sh refuses the removed host group before anything is built or written" \
  || fail "build.sh and the host group (rc=$rh; $(head -1 "$TMP/build.err"); docker build called: $(grep -c '^build ' "$DOCKER_LOG"))"
rm -f "$E"/allowlist-*.txt

# The other half (from main's ENV-7 tests): a tag no image carries yet reaches
# docker build, labelled with the project.
cat > "$TMP/bin/docker" <<'FAKE3'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 ${2:-}" in "image inspect") printf '\n'; exit 1 ;; esac
exit 0
FAKE3
chmod +x "$TMP/bin/docker"; : > "$DOCKER_LOG"
( cd "$E" && unset IMAGE_NAME && bash ./build.sh ) >/dev/null 2>"$TMP/build.err"; brc=$?
Ep="$(cd "$E" && pwd -P)"
grep -q '^build ' "$DOCKER_LOG" && grep -qF -- "ai-containers.project=$Ep" "$DOCKER_LOG" \
  && pass "build.sh builds a new tag, labelled with its project" \
  || fail "build.sh new tag (rc=$brc; $(grep -E 'ERROR' "$TMP/build.err" | head -1))"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
