#!/usr/bin/env bash
# summary:  group.sh rm deletes the group's directory AND its rvm, temp and cache volumes, and refuses while in use
# tags:     volumes fast
# requires: docker launcher
#
# group.sh exists because a group stopped being just a directory. Once it has a
# Ruby home, `rm -rf ~/.ai-containers/<g>` leaves a multi-GB volume with nothing
# pointing at it — invisible until a disk fills months later. The group's temp
# and cache volumes (/var/tmp, <prefix>-vartmp-<g>; ~/.cache, <prefix>-cache-<g>)
# are the same kind of thing and go the same way: with the directory and the
# Ruby volume, never alone, and not while a container mounts one.
#
# tests/test-group-lifecycle.sh already covers this against a FAKE docker, and
# that test is the right shape for "did group.sh issue the right commands". It
# cannot see the two things below, because a fake docker agrees with whatever it
# is asked:
#   - `docker volume rm` actually removing the volume
#   - the in-use refusal, which rests on `docker ps --filter volume=` genuinely
#     matching a running container that mounts it
#
# The refusal half matters more than it looks. Without it, group.sh deletes the
# directory, then fails to remove the volume docker is holding, and the group is
# left in the one state nothing can clean up: a volume with no directory to name
# it. The case therefore checks that BOTH survive a refused rm — an error
# message with the directory already gone would be the bug, not the fix.
#
# Everything here is scoped by REPO_VOLUME_PREFIX (see fixture_scope_init):
# rvm_volume_name and rvm_volumes both derive from it, so this case cannot see —
# let alone gc — a developer's real group volumes.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish

groups_root="$IT_LAUNCH_HOME/.ai-containers"
rvm_vol() { printf 'it-%s-rvm-%s' "$IT_RUN_ID" "$1"; }
tmp_vol() { printf 'it-%s-vartmp-%s' "$IT_RUN_ID" "$1"; }
cache_vol() { printf 'it-%s-cache-%s' "$IT_RUN_ID" "$1"; }

# This HOME's id, from the launcher's own function, as it labels a volume.
own="$( export HOME="$IT_LAUNCH_HOME"
        # shellcheck source=sandbox-common.sh
        source "$IT_REPO_DIR/sandbox-common.sh" >/dev/null 2>&1
        ai_containers_owner_id )"
if [[ "$own" != sha256:* ]]; then fail "this home's owner id resolves ([$own])"; it_finish; fi

make_group() {  # $1=name — directory + rvm, temp and cache volumes, as a launched group has
  mkdir -p "$groups_root/$1/.claude"
  docker volume create --label "$IT_LABEL" "$(rvm_vol "$1")" >/dev/null 2>&1
  docker volume create --label "$IT_LABEL" --label "ai-containers.vartmp-group=$1" \
    --label "ai-containers.owner=$own" "$(tmp_vol "$1")" >/dev/null 2>&1
  docker volume create --label "$IT_LABEL" --label "ai-containers.cache-group=$1" \
    --label "ai-containers.owner=$own" "$(cache_vol "$1")" >/dev/null 2>&1
}

# A repo volume that must be untouched: group.sh owns groups, repo.sh owns
# repos, and the -rvm-/-repo- infix is the only thing keeping them apart.
repo_register_volume keepme || it_finish
keep="$(repo_fixture_volume_name keepme)"

# ── The happy path ─────────────────────────────────────────────────────────────
make_group gone
assert_volume_exists "$(rvm_vol gone)"
assert_volume_exists "$(tmp_vol gone)"
assert_volume_exists "$(cache_vol gone)"

launcher_script group.sh rm gone --yes
if [[ "$IT_SCRIPT_RC" -eq 0 ]]; then
  pass "group.sh rm exited 0"
else
  fail "group.sh rm exited $IT_SCRIPT_RC"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi
assert_host_file_absent "$groups_root/gone"
assert_volume_absent "$(rvm_vol gone)"
assert_volume_absent "$(tmp_vol gone)"
assert_volume_absent "$(cache_vol gone)"
assert_volume_exists "$keep"

# ── The refusal ────────────────────────────────────────────────────────────────
make_group busy
holder="it-vol-holder-$$-$RANDOM"
docker run -d --name "$holder" --label "$IT_LABEL" \
  -v "$(rvm_vol busy):/mnt" --entrypoint sleep "$IT_IMAGE" 600 >/dev/null 2>&1 \
  || { fail "could not start a container to hold the volume"; it_finish; }
it_track "container:$holder"

launcher_script group.sh rm busy --yes
if [[ "$IT_SCRIPT_RC" -ne 0 ]]; then
  pass "group.sh rm refuses while a running container holds the volume"
else
  fail "group.sh rm refuses while a running container holds the volume — it PROCEEDED"
fi
if grep -q 'still using' "$IT_SCRIPT_OUT" 2>/dev/null; then
  pass "the refusal says why"
else
  fail "the refusal says why"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi
# Neither half may have been deleted on the way to refusing.
if [[ -d "$groups_root/busy" ]]; then
  pass "the refused group's directory survives"
else
  fail "the refused group's directory survives — it was deleted before the refusal"
fi
assert_volume_exists "$(rvm_vol busy)"
assert_volume_exists "$(tmp_vol busy)"
assert_volume_exists "$(cache_vol busy)"

# ── The refusal, when only the temp volume is held ─────────────────────────────
# The Ruby volume is idle, so a busy check that looked at it alone would let rm
# go on and take the directory and the Ruby volume out from under a running
# container.
make_group busytmp
holder2="it-vol-holder2-$$-$RANDOM"
docker run -d --name "$holder2" --label "$IT_LABEL" \
  -v "$(tmp_vol busytmp):/mnt" --entrypoint sleep "$IT_IMAGE" 600 >/dev/null 2>&1 \
  || { fail "could not start a container to hold the temp volume"; it_finish; }
it_track "container:$holder2"

launcher_script group.sh rm busytmp --yes
if [[ "$IT_SCRIPT_RC" -ne 0 ]] && grep -q 'still using' "$IT_SCRIPT_OUT" 2>/dev/null; then
  pass "group.sh rm refuses while a running container holds the temp volume"
else
  fail "group.sh rm refuses while a running container holds the temp volume — rc $IT_SCRIPT_RC"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi
if [[ -d "$groups_root/busytmp" ]]; then
  pass "the group's directory survives that refusal"
else
  fail "the group's directory survives that refusal — it was deleted"
fi
assert_volume_exists "$(rvm_vol busytmp)"
assert_volume_exists "$(tmp_vol busytmp)"
assert_volume_exists "$(cache_vol busytmp)"

# ── The refusal, when only the cache volume is held ────────────────────────────
make_group busycache
holder3="it-vol-holder3-$$-$RANDOM"
docker run -d --name "$holder3" --label "$IT_LABEL" \
  -v "$(cache_vol busycache):/mnt" --entrypoint sleep "$IT_IMAGE" 600 >/dev/null 2>&1 \
  || { fail "could not start a container to hold the cache volume"; it_finish; }
it_track "container:$holder3"

launcher_script group.sh rm busycache --yes
if [[ "$IT_SCRIPT_RC" -ne 0 ]] && grep -q 'still using' "$IT_SCRIPT_OUT" 2>/dev/null; then
  pass "group.sh rm refuses while a running container holds the cache volume"
else
  fail "group.sh rm refuses while a running container holds the cache volume — rc $IT_SCRIPT_RC"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi
if [[ -d "$groups_root/busycache" ]]; then
  pass "the group's directory survives that refusal"
else
  fail "the group's directory survives that refusal — it was deleted"
fi
assert_volume_exists "$(rvm_vol busycache)"
assert_volume_exists "$(tmp_vol busycache)"
assert_volume_exists "$(cache_vol busycache)"

it_finish
