#!/usr/bin/env bash
# summary:  project.sh mv copies a working copy into the new launch dir's volume, intact, and removes the old
# tags:     volumes fast
# requires: docker
#
# `project.sh mv` moves a project's setup, and with it every :rwcopy working
# copy, which lives in a Docker volume named after the launch directory. A
# volume cannot be renamed, so mv copies it into the volume the next launch from
# the new place will name (workcopy_tag), checks the copy, and only then removes
# the old one. The hermetic test (tests/test-project-tool.sh) runs that against
# a fake docker; this is the one place the rsync runs in the real seed image.
#
# What a lossy copy would show is in the volume, so the assertions read the new
# volume from OUTSIDE mv, in a seed container: the file's content, the link's
# target (a followed link would copy the target's bytes instead) and the 0600
# mode (a copy that lost modes would show the umask's). The new volume's name
# and launch-dir label are what the launcher finds it by; a wrong name is a
# copy no launch ever mounts.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish

seed=ai-containers-seed
if ! docker image inspect "$seed" >/dev/null 2>&1; then
  docker build -q -t "$seed" -f "$IT_REPO_DIR/Dockerfile.seed" "$IT_REPO_DIR" >/dev/null 2>&1 \
    || { fail "the seed image could not be built"; it_finish; }
fi

# A temp copy of the engine, so mv edits that copy's projects.conf, never the repo's.
w="$(it_scratch)"
eng="$w/engine"; mkdir -p "$eng"
( cd "$IT_REPO_DIR" && git ls-files -z '*.sh' Dockerfile.seed projects.conf.example | grep -zv '^tests/' \
    | xargs -0 -I{} sh -c 'mkdir -p "$1/$(dirname "{}")" && cp -p "{}" "$1/{}"' _ "$eng" ) \
  || { fail "could not copy the engine"; it_finish; }
cp -p "$IT_REPO_DIR/project.sh" "$eng/project.sh"

proj="$w/alpha"; new="$w/beta"
mkdir -p "$proj/.ai-containers"
printf 'IMAGE_NAME=it-no-such-image-%s\n' "$IT_RUN_ID" > "$proj/.ai-containers/sandbox.env"
printf '%s\n' "$proj" > "$eng/projects.conf"
old_dot="$proj/.ai-containers"; new_dot="$new/.ai-containers"

# Names exactly as the launcher makes them, from its own functions.
names() {  # $1=launch dir → the working copy's volume name
  ( export HOME="$IT_LAUNCH_HOME" REPO_VOLUME_PREFIX
    # shellcheck source=sandbox-common.sh
    source "$IT_REPO_DIR/sandbox-common.sh" >/dev/null 2>&1
    repo_workcopy_volume_name wcrepo "$(workcopy_tag "$1")" )
}
old_vol="$(names "$old_dot")"; new_vol="$(names "$new_dot")"
base_vol="$(repo_fixture_volume_name wcrepo)"
if [[ -z "$old_vol" || -z "$new_vol" || "$old_vol" == "$new_vol" ]]; then
  fail "the working-copy volume names resolve ([$old_vol] [$new_vol])"; it_finish
fi

docker volume create --label "$IT_LABEL" --label "ai-containers.repo=wcrepo" \
  --label "ai-containers.type=path" --label "ai-containers.source=$w/src" "$base_vol" >/dev/null 2>&1 \
  || { fail "the base volume could not be made"; it_finish; }
docker volume create --label "$IT_LABEL" --label "ai-containers.workcopy=1" \
  --label "ai-containers.repo=wcrepo" --label "ai-containers.launch-dir=$old_dot" "$old_vol" >/dev/null 2>&1 \
  || { fail "the working-copy volume could not be made"; it_finish; }
# mv makes the new volume through the harness's shim, which labels it; this one
# is removed by name too in case the shim is bypassed.
it_track "dir:$w"

docker run --rm -v "$old_vol:/v" --entrypoint sh "$seed" -c '
  printf "known-content\n" > /v/FILE && ln -s FILE /v/LINK \
    && printf "secret\n" > /v/PRIVATE && chmod 600 /v/PRIVATE' >/dev/null 2>&1 \
  || { fail "the working copy could not be filled"; it_finish; }

# The engine copy's project.sh, in the harness's usual sandbox: scratch HOME,
# run-scoped volume prefix, shim on PATH.
(
  cd "$w" || exit 1
  export PATH="$IT_SHIM_DIR:$PATH" HOME="$IT_LAUNCH_HOME" IT_REAL_DOCKER IT_LABEL
  [[ -n "$IT_DOCKER_HOST" ]] && export DOCKER_HOST="$IT_DOCKER_HOST"
  exec bash "$eng/project.sh" mv "$proj" "$new" --yes
) >"$w/mv.out" 2>&1 </dev/null
rc=$?
if [[ "$rc" -eq 0 ]]; then pass "project.sh mv exited 0"
else fail "project.sh mv exited $rc"; sed 's/^/     /' "$w/mv.out"; fi

assert_volume_exists "$new_vol"
got="$(docker volume inspect --format '{{index .Labels "ai-containers.launch-dir"}}' "$new_vol" 2>/dev/null)"
if [[ "$got" == "$new_dot" ]]; then pass "the new volume's launch-dir label is the new launch dir"
else fail "the new volume's launch-dir label is [$got], want [$new_dot]"; fi

# Only if it exists: `docker run -v` would otherwise create it, unlabelled, and
# leave it behind for the runner's label-scoped sweep to miss.
out=""
if docker_volume_exists "$new_vol"; then
out="$(docker run --rm -v "$new_vol:/v:ro" --entrypoint sh "$seed" -c '
  printf "content=%s\n" "$(cat /v/FILE 2>&1)"
  printf "link=%s\n" "$(readlink /v/LINK 2>&1)"
  printf "mode=%s\n" "$(stat -c %a /v/PRIVATE 2>&1)"' 2>&1)"
fi
for want in "content=known-content" "link=FILE" "mode=600"; do
  if grep -qx -- "$want" <<<"$out"; then pass "the copy holds: $want"
  else fail "the copy holds: $want"; printf '%s\n' "$out" | sed 's/^/     /'; fi
done

assert_volume_absent "$old_vol"
it_finish
