#!/usr/bin/env bash
# summary:  group.sh gc removes this home's volumes whose group directory is gone, and only those
# tags:     volumes fast
# requires: docker launcher
#
# gc is the cleanup for the mistake group.sh rm exists to prevent: someone runs
# `rm -rf ~/.ai-containers/<group>` — which is exactly what a group looked like
# before it owned a volume — and the Ruby home is orphaned.
#
# A gc is only as good as what it REFUSES to collect, and the failure mode is
# asymmetric: collecting nothing wastes disk, collecting too much destroys a
# working group's installed rubies or, worse, a repo volume shared by every
# project on the machine. So the case gives gc five volumes and requires it to
# take exactly one, and with --all exactly two more:
#
#   orphan   directory deleted, this home's owner label   → must go
#   old      directory deleted, no owner label            → stays; goes with --all
#   theirs   directory deleted, another home's label      → stays; goes with --all
#   live     directory present                            → must stay, --all too
#   a repo   not a group at all                           → must stay, --all too
#                                   (repo.sh owns those; the -rvm- vs -repo-
#                                    infix is the only separator, and
#                                    tests/test-repo-registry.sh pins the other
#                                    direction of the same boundary)
#
# One daemon serves several homes (Docker Desktop's, every WSL distro), so a
# group directory missing here may be another home's group: gc takes only the
# volumes labelled with this HOME's id (ai-containers.owner, which the launcher
# puts on an rvm volume it makes), and a volume made before the label cannot be
# told apart (bugs review PRJ-16). Until 2026-11-17 this case made its orphan
# unlabelled, and failed once gc kept such a volume.
#
# This ran for real in the originating session: two orphaned volumes from
# interrupted verification runs, collected correctly. The case makes that
# repeatable instead of anecdotal.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish

groups_root="$IT_LAUNCH_HOME/.ai-containers"
rvm_vol() { printf 'it-%s-rvm-%s' "$IT_RUN_ID" "$1"; }

# This HOME's id, from the launcher's own function, as it labels a volume.
own="$( export HOME="$IT_LAUNCH_HOME"
        # shellcheck source=sandbox-common.sh
        source "$IT_REPO_DIR/sandbox-common.sh" >/dev/null 2>&1
        ai_containers_owner_id )"
if [[ "$own" != sha256:* ]]; then fail "this home's owner id resolves ([$own])"; it_finish; fi

# A group whose directory was deleted by hand: its volume as the launcher made it.
docker volume create --label "$IT_LABEL" --label "ai-containers.owner=$own" "$(rvm_vol orphan)" >/dev/null 2>&1
# One made before owner labels, and one another home on this daemon made.
docker volume create --label "$IT_LABEL" "$(rvm_vol old)" >/dev/null 2>&1
docker volume create --label "$IT_LABEL" \
  --label "ai-containers.owner=sha256:$(printf '%064d' 0)" "$(rvm_vol theirs)" >/dev/null 2>&1

# A healthy group.
mkdir -p "$groups_root/live/.claude"
docker volume create --label "$IT_LABEL" "$(rvm_vol live)" >/dev/null 2>&1

# A repo volume.
repo_register_volume untouchable || it_finish
repo_vol="$(repo_fixture_volume_name untouchable)"

assert_volume_exists "$(rvm_vol orphan)"
assert_volume_exists "$(rvm_vol old)"
assert_volume_exists "$(rvm_vol theirs)"
assert_volume_exists "$(rvm_vol live)"
assert_volume_exists "$repo_vol"

# `list` must SEE the orphan before gc is asked to remove it: if discovery is
# broken, gc removing nothing looks identical to gc working on a clean machine.
launcher_script group.sh list
if grep -q "$(rvm_vol orphan)" "$IT_SCRIPT_OUT" 2>/dev/null; then
  pass "group.sh list reports the orphaned volume"
else
  fail "group.sh list reports the orphaned volume"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi

launcher_script group.sh gc --yes
if [[ "$IT_SCRIPT_RC" -eq 0 ]]; then
  pass "group.sh gc exited 0"
else
  fail "group.sh gc exited $IT_SCRIPT_RC"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi

assert_volume_absent "$(rvm_vol orphan)"
assert_volume_exists "$(rvm_vol old)"
assert_volume_exists "$(rvm_vol theirs)"
assert_volume_exists "$(rvm_vol live)"
assert_volume_exists "$repo_vol"
# The two it kept are named, with the way to remove them.
if grep -q "$(rvm_vol old)" "$IT_SCRIPT_OUT" 2>/dev/null && grep -q "$(rvm_vol theirs)" "$IT_SCRIPT_OUT" 2>/dev/null \
   && grep -q -- 'gc --all' "$IT_SCRIPT_OUT" 2>/dev/null; then
  pass "group.sh gc names the volumes it kept, and gc --all"
else
  fail "group.sh gc names the volumes it kept, and gc --all"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi

# --all takes those two, and still neither a live group's volume nor a repo's.
launcher_script group.sh gc --all --yes
if [[ "$IT_SCRIPT_RC" -eq 0 ]]; then
  pass "group.sh gc --all exited 0"
else
  fail "group.sh gc --all exited $IT_SCRIPT_RC"
  sed 's/^/     /' "$IT_SCRIPT_OUT"
fi
assert_volume_absent "$(rvm_vol old)"
assert_volume_absent "$(rvm_vol theirs)"
assert_volume_exists "$(rvm_vol live)"
assert_volume_exists "$repo_vol"
if [[ -d "$groups_root/live" ]]; then
  pass "the live group's directory is untouched"
else
  fail "the live group's directory is untouched — gc deleted it"
fi

it_finish
