#!/usr/bin/env bash
# Tests for ai_containers_retag_check() (sandbox-common.sh) and the portable
# IMAGE_NAME rule (env_value_portable): ENV-7. A committed sandbox.env can name
# another project's image tag, or a base image such as ubuntu:24.04, and
# ./build.sh then retagged it with this project's image and allowlist.
#
# A fake `docker` answers `image inspect` from FAKE_LABELS: `none` (no such
# image), or the JSON docker prints for .Config.Labels.
#
# The project label is the id of the project's path since ENV-8, looked up in
# ~/.ai-containers/image-projects.conf; an image built before carries the path.
# The checks that judge another project run for both.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_DIR"; [[ -f "$REPO_DIR/base/entrypoint.sh" ]] && ENGINE="$REPO_DIR/base"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
# Guarded: p_timeout forks, and a child that inherits an unguarded trap removes
# the fixture when it is killed (tests/test-exit-trap-ownership.sh).
TMP_OWNER="$BASHPID"
trap '[[ "$BASHPID" == "$TMP_OWNER" ]] && rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ENGINE/sandbox-common.sh"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"

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

# bounded <fifo> <command…>: the command's output, run for at most 10 s. A FIFO
# that code under test should not open blocks a subshell it forked, which
# p_timeout's kill does not reach; its output goes to a file so it holds no
# pipe of this test's, and opening the FIFO read-write lets it go on, so a
# regression fails here rather than hanging the suite.
bounded() {
  local fifo="$1" rc i; shift
  p_timeout 10 "$@" > "$TMP/bounded.out" 2>&1; rc=$?
  if [[ "$rc" == 124 ]]; then
    for i in 1 2 3; do
      if [[ -p "$fifo" ]]; then { exec 3<>"$fifo"; exec 3>&-; } 2>/dev/null; fi
      sleep 1
    done
  fi
  cat "$TMP/bounded.out"
}

# check LABELS → sets rc and err
check() { err="$(FAKE_LABELS="$1" ai_containers_retag_check img:tag "$ME" 2>&1)"; rc=$?; }

check none
[[ "$rc" == 0 && -z "$err" ]] && pass "a tag no image carries yet is built" || fail "new tag (rc=$rc: $err)"

check '{"ai-containers.built-at":"x","ai-containers.project":"'"$ME"'"}'
[[ "$rc" == 0 && -z "$err" ]] && pass "this project's own image is rebuilt" || fail "own image (rc=$rc: $err)"

# lab <path>: the project label for <path> in the form under test ($KIND): the
# path, or its id, recorded with the path as build.sh records it.
lab() {
  if [[ "$KIND" == path ]]; then printf '%s' "$1"; return; fi
  ai_containers_project_record "$1"
  ai_containers_project_id "$1"
}
for KIND in path id; do
SIB="$TMP/sib/.ai-containers"; mkdir -p "$SIB"
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$(lab "$SIB")"'"}'
[[ "$rc" != 0 ]] && grep -qF "$SIB" <<<"$err" \
  && pass "[$KIND] another project's image is not retagged, and the project is named" \
  || fail "[$KIND] another project's image (rc=$rc: $err)"

# A project that moved left its old path behind: nothing there to overwrite
# (review of the batch 10 branch).
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$(lab "$TMP/gone/.ai-containers")"'"}'
[[ "$rc" == 0 ]] && grep -qF 'no longer exists' <<<"$err" && grep -qF "$TMP/gone" <<<"$err" \
  && pass "[$KIND] an image built for a path that no longer exists (a moved project) is rebuilt, with a NOTE" \
  || fail "[$KIND] moved project (rc=$rc: $err)"

# …but a path under an empty directory is not proof either: it is what a drive
# that is not mounted leaves behind (ENV-9).
mkdir -p "$TMP/mnt9"
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$(lab "$TMP/mnt9/drive/proj/.ai-containers")"'"}'
[[ "$rc" != 0 ]] && grep -qF "$TMP/mnt9" <<<"$err" && grep -qF 'mount' <<<"$err" \
  && pass "[$KIND] an image built for a path under an empty directory (an unmounted drive) is not taken for a moved project" \
  || fail "[$KIND] path under an empty directory (rc=$rc: $err)"
rmdir "$TMP/mnt9"
# A nearest existing directory that is a LINK to one with entries is not empty:
# `find` given a link as its start does not follow it (review of 837daef).
mkdir -p "$TMP/real9/other"; ln -s "$TMP/real9" "$TMP/lnk9"
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$(lab "$TMP/lnk9/proj/.ai-containers")"'"}'
[[ "$rc" == 0 ]] && grep -qF 'no longer exists' <<<"$err" \
  && pass "[$KIND] a path under a link to a directory with entries is still a moved project" \
  || fail "[$KIND] a path under a linked, non-empty directory (rc=$rc: $err)"
rm -rf "$TMP/real9" "$TMP/lnk9"
# A path holding | is named whole: the id ends at the first one (review of the
# fix, L4).
SIBP="$TMP/a|b/.ai-containers"; mkdir -p "$SIBP"
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$(lab "$SIBP")"'"}'
[[ "$rc" != 0 ]] && grep -qF "$SIBP" <<<"$err" \
  && pass "[$KIND] another project whose path holds | is named whole" \
  || fail "[$KIND] a project path with | (rc=$rc: $err)"
# Where a drive's mount point goes away with it — macOS /Volumes/<drive>, Linux
# /media/<user>/<drive> or /run/media/<user>/<drive> — the nearest existing
# directory is the removable-media root, which holds other drives (review of 837daef).
rr=""
for d in /Volumes /media /media/u /media/u/ /run/media /run/media/u; do _ac_removable_root "$d" || rr+=" $d:no"; done
for d in /home/u /mnt /Volumes/x/y /media/u/drive /; do _ac_removable_root "$d" && rr+=" $d:yes"; done
[[ -z "$rr" ]] && pass "the removable-media roots are recognised, and only they" || fail "removable-media roots:$rr"

# …but a path you cannot stat is not proof it moved: under another user's 0700
# home it only looks absent (review of the batch 10 branch).
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$TMP/locked/proj/.ai-containers"; chmod 000 "$TMP/locked"
  check '{"ai-containers.built-at":"x","ai-containers.project":"'"$(lab "$TMP/locked/proj/.ai-containers")"'"}'
  chmod 755 "$TMP/locked"
  [[ "$rc" != 0 ]] && pass "[$KIND] an image built for a path this user cannot see is not taken for a moved project" \
    || fail "[$KIND] unstatable project path (rc=$rc: $err)"
fi
done

# The id alone (ENV-8). This project's own is recognised with no record at all:
# the record may have been removed, and the id is computed, not looked up…
rm -f "$HOME/.ai-containers/image-projects.conf"
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$(ai_containers_project_id "$ME")"'"}'
[[ "$rc" == 0 && -z "$err" ]] && pass "this project's own id is recognised with no record" || fail "own id with no record (rc=$rc: $err)"
# …but one made with a key since lost names nothing, the record included: a
# record line counts only if its id is its path's (review of the fix, M2).
old_id="$(ai_containers_project_id "$ME")"; ai_containers_project_record "$ME"
mv "$HOME/.ai-containers/project-id.key" "$TMP/key.saved"
check '{"ai-containers.built-at":"x","ai-containers.project":"'"$old_id"'"}'
[[ "$rc" != 0 ]] && grep -qF 'project-id.key' <<<"$err" \
  && pass "an id made with a key since lost is refused, naming the key" \
  || fail "an id from a lost key (rc=$rc: $err)"
mv -f "$TMP/key.saved" "$HOME/.ai-containers/project-id.key"; rm -f "$HOME/.ai-containers/image-projects.conf"
# A damaged or hand-edited record names nothing: another project that still
# exists is refused whatever its line has become, and an append after a last
# line with no newline starts a line of its own (review of the fix, M2).
REC="$HOME/.ai-containers/image-projects.conf"; SIB_ID="$(ai_containers_project_id "$SIB")"
bad=""
for dmg in crlf space conflict unterminated; do
  case "$dmg" in
    crlf)  printf '%s|%s\r\n' "$SIB_ID" "$SIB" > "$REC" ;;
    space) printf '%s|%s \n' "$SIB_ID" "$SIB" > "$REC" ;;
    conflict) printf '%s|%s\n' "$SIB_ID" "$TMP/nonexistent/x" > "$REC"; ai_containers_project_record "$SIB" ;;
    unterminated) printf '# a line with no newline' > "$REC"; ai_containers_project_record "$SIB" ;;
  esac
  check '{"ai-containers.built-at":"x","ai-containers.project":"'"$SIB_ID"'"}'
  [[ "$rc" != 0 ]] || bad+=" $dmg"
  if [[ "$dmg" == conflict || "$dmg" == unterminated ]]; then grep -qF "$SIB" <<<"$err" || bad+=" $dmg:unnamed"; fi
done
[[ -z "$bad" ]] && pass "a damaged or conflicting record line cannot turn a refusal into a rebuild" || fail "record damage:$bad"
rm -f "$REC"
# An id no record names was built on another machine, or by another user of this
# docker: there is no path to judge, and it is refused, naming the record.
ai_containers_project_record "$SIB"
check '{"ai-containers.built-at":"x","ai-containers.project":"sha256:'"$(printf 'elsewhere' | ai_containers_sha256)"'"}'
[[ "$rc" != 0 ]] && grep -qF 'image-projects.conf' <<<"$err" && grep -qF 'another machine' <<<"$err" && ! grep -qF "$SIB" <<<"$err" \
  && pass "an id no record names (another machine's project) is not retagged, and the record is named" \
  || fail "unrecorded id (rc=$rc: $err)"
# An id is 64 lowercase hex digits after sha256:; anything else is not this tool's.
bad=""
for v in "sha256:xyz" "sha256:$(printf '%064d' 0)0" "sha256:$(printf '%064d' 0 | tr 0 A)" "sha256:"; do
  check '{"ai-containers.built-at":"x","ai-containers.project":"'"$v"'"}'
  [[ "$rc" != 0 ]] && grep -qF 'did not write' <<<"$err" || bad+=" $v:$rc"
done
[[ -z "$bad" ]] && pass "a malformed id is a label this tool did not write" || fail "malformed ids:$bad"
# A record that is a FIFO hangs neither the lookup nor the record (review of the
# fix, L2), and one that cannot be written is passed by in silence.
mkdir -p "$HOME/.ai-containers"; rm -f "$REC"; mkfifo "$REC"
t0=$SECONDS
out="$(bounded "$REC" bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_project_record "$2"; ai_containers_project_path "$3"; echo "rc=$?"' _ "$ENGINE" "$SIB" "$SIB_ID")"
[[ "$out" == rc=1 && $((SECONDS - t0)) -lt 10 ]] && pass "a record that is a FIFO is neither read nor written" \
  || fail "a FIFO record (in $((SECONDS - t0))s: $out)"
rm -f "$REC"
# Under build.sh's set -euo pipefail: one that cannot be read ended the build in
# silence after docker build (second review of the fix, M1).
if [[ "$(id -u)" != 0 ]]; then
  bad=""
  for m in 444 000; do
    printf '# mode %s\n' "$m" > "$REC"; chmod "$m" "$REC"
    out="$(bash -c 'set -euo pipefail; source "$1/sandbox-common.sh" >/dev/null 2>&1
      ai_containers_project_record "$2"; ai_containers_project_path "$3" || echo "rc=$?"; echo done' _ "$ENGINE" "$SIB" "$SIB_ID" 2>&1)"
    chmod 644 "$REC"
    [[ "$out" == $'rc=1\ndone' ]] || bad+=" $m:[$out]"
  done
  [[ -z "$bad" ]] && pass "a record that cannot be written or read is passed by in silence, under set -e" \
    || fail "an unwritable or unreadable record:$bad"
  rm -f "$REC"
fi
# The record holds one line per project, and none for a path it could not give
# back whole.
: > "$HOME/.ai-containers/image-projects.conf"
ai_containers_project_record "$SIB"; ai_containers_project_record "$SIB"; ai_containers_project_record "$TMP/new"$'\n'"line"
n="$(grep -c . "$HOME/.ai-containers/image-projects.conf")"
grep -qxF -- "$(ai_containers_project_id "$SIB")|$SIB" "$HOME/.ai-containers/image-projects.conf" && [[ "$n" == 1 ]] \
  && pass "the record holds each project once, as id|path, and no path with a newline" \
  || fail "the record ($n lines: $(cat "$HOME/.ai-containers/image-projects.conf"))"

# A project label that is not an absolute path is not one this tool wrote, and
# the walk up for a moved project spun on it for ever (automated security
# review of 818cb3e).
t0=$SECONDS
err="$(FAKE_LABELS='{"ai-containers.built-at":"x","ai-containers.project":"relative"}' p_timeout 10 bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_retag_check img:tag "$2"' _ "$ENGINE" "$ME" 2>&1)"; rc=$?
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

# A symlinked engine copy is the same project: the id is of the physical path
# (carried over from main's ENV-7 tests).
ME_ID="$(ai_containers_project_id "$ME")"
mkdir -p "$TMP/linkdir"; ln -s "$ME" "$TMP/linkdir/lnk"
grep -qxF -- "ai-containers.project=$ME_ID" <<<"$(ai_containers_provenance_labels "$TMP/linkdir/lnk" 2026-01-01T00:00:00Z)" \
  && pass "a symlinked engine copy records the same project" || fail "symlinked engine copy"
# Every build is stamped with the project it came from, by its id: `docker push`
# publishes every label, and the path names the user and their directories
# (ENV-8). No label carries the path, and the id is keyed: not the plain SHA-256
# of the path, which anyone who guessed the path could confirm.
lbls="$(ai_containers_provenance_labels "$ME" 2026-01-01T00:00:00Z)"
[[ "$ME_ID" == sha256:* && ${#ME_ID} == 71 && "$ME_ID" != "sha256:$(printf '%s' "$ME" | ai_containers_sha256)" ]] \
  && grep -qxF -- "ai-containers.project=$ME_ID" <<<"$lbls" && ! grep -qF -- "$TMP" <<<"$lbls" \
  && pass "the labels name the project by a keyed id, and carry no path" || fail "project label ($ME_ID): $lbls"
# The key is this user's: made once, 0600, and another key gives another id.
key="$HOME/.ai-containers/project-id.key"
other_id="$(HOME="$TMP/home2" bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_project_id "$2"' _ "$ENGINE" "$ME")"
[[ "$(p_stat_mode "$key")" == 600 && "$(ai_containers_project_id "$ME")" == "$ME_ID" \
   && "$other_id" == sha256:* && "$other_id" != "$ME_ID" ]] \
  && pass "the id's key is this user's, 0600, and stable; another key gives another id" \
  || fail "the id's key (mode $(p_stat_mode "$key"); again: $(ai_containers_project_id "$ME"); other: $other_id)"
# A key that is not one this tool made gives no id, promptly and quietly: a FIFO,
# a directory, a short or uppercase one, one it cannot read (second review of
# the fix, L3, L5); and where hard links fail, the key is made all the same.
mv "$key" "$TMP/key.saved"; bad=""
for k in fifo dir short upper unreadable; do
  case "$k" in
    fifo) mkfifo "$key" ;; dir) mkdir "$key" ;;
    short) printf 'abc\n' > "$key" ;; upper) printf '%064d\n' 0 | tr 0 A > "$key" ;;
    unreadable) printf '%064d\n' 0 > "$key"; chmod 000 "$key" ;;
  esac
  [[ "$k" == unreadable && "$(id -u)" == 0 ]] && { rm -f "$key"; continue; }
  out="$(bounded "$key" bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ai_containers_project_id "$2"; echo "rc=$?"' _ "$ENGINE" "$ME")"
  [[ "$out" == rc=1 ]] || bad+=" $k:[$out]"
  chmod 644 "$key" 2>/dev/null; rm -rf "$key"
done
mv "$TMP/key.saved" "$key"
nolink="$(HOME="$TMP/home3" bash -c 'source "$1/sandbox-common.sh" >/dev/null 2>&1; ln() { return 1; }
  ai_containers_project_id "$2"' _ "$ENGINE" "$ME" 2>&1)"
[[ "$nolink" == sha256:* ]] && nolink="$(p_stat_mode "$TMP/home3/.ai-containers/project-id.key")"
[[ -z "$bad" && "$nolink" == 600 ]] && pass "a key this tool did not make gives no id; with no hard links one is still made, 0600" \
  || fail "keys:$bad; with no hard links: $nolink"
# With no id to give, the image records no project, and the build says so
# (review of the fix, L1).
nolab="$( ( ai_containers_sha256() { return 1; }; ai_containers_provenance_labels "$ME" 2026-01-01T00:00:00Z ) 2>&1)"
grep -qF 'WARNING: this image records no project' <<<"$nolab" && ! grep -qF 'ai-containers.project=' <<<"$nolab" \
  && pass "an image built with no id to give says it records no project" || fail "no id: $nolab"

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
# runme.sh runs build.sh first, so it is build.sh that must name the file to edit
# (review of 9700c64).
printf 'AI_CONTAINER_GROUP=host\n' > "$E/sandbox.local.env"
( cd "$E" && unset AI_CONTAINER_GROUP && bash ./build.sh other:tag ) >/dev/null 2>"$TMP/build.err"; rh=$?
[[ "$rh" != 0 ]] && grep -q 'NOTE: AI_CONTAINER_GROUP=host is set in .*/sandbox\.local\.env' "$TMP/build.err" \
  && pass "build.sh names the file that sets the host group" \
  || fail "build.sh did not name the file that sets the host group (rc=$rh; $(head -2 "$TMP/build.err" | tr '\n' ' '))"
rm -f "$E/sandbox.local.env"
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
# Through a link to the engine copy: the record holds the physical path, as the
# label's id is of it (review of the fix, L4). Builds above recorded it already.
ln -s "$E" "$TMP/elink"; rm -f "$HOME/.ai-containers/image-projects.conf"
( cd "$TMP/elink" && unset IMAGE_NAME && bash ./build.sh ) >/dev/null 2>"$TMP/build.err"; brc=$?
Ep="$(cd "$E" && pwd -P)"
Ep_ID="$(ai_containers_project_id "$Ep")"
grep -q '^build ' "$DOCKER_LOG" && grep -qF -- "ai-containers.project=$Ep_ID" "$DOCKER_LOG" \
  && ! grep -qF -- "ai-containers.project=$Ep" "$DOCKER_LOG" \
  && pass "build.sh builds a new tag, labelled with its project's id" \
  || fail "build.sh new tag (rc=$brc; $(grep -E 'ERROR' "$TMP/build.err" | head -1))"
# …and records the id with the path, so that another project's build can name it.
grep -qxF -- "$Ep_ID|$Ep" "$HOME/.ai-containers/image-projects.conf" \
  && pass "build.sh records the project's id and path in ~/.ai-containers/image-projects.conf" \
  || fail "build.sh did not record the project ($(cat "$HOME/.ai-containers/image-projects.conf" 2>&1))"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
