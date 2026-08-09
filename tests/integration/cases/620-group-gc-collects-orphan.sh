#!/usr/bin/env bash
# summary:  group.sh gc removes volumes whose group directory is gone, and only those
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
# project on the machine. So the case gives gc three volumes and requires it to
# take exactly one:
#
#   orphan   directory deleted     → must go
#   live     directory present     → must stay
#   a repo   not a group at all    → must stay (repo.sh owns those; the -rvm-
#                                    vs -repo- infix is the only separator, and
#                                    tests/test-repo-registry.sh pins the other
#                                    direction of the same boundary)
#
# This ran for real in the originating session: two orphaned volumes from
# interrupted verification runs, collected correctly. The case makes that
# repeatable instead of anecdotal.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

fixture_scope_init || it_finish

groups_root="$IT_LAUNCH_HOME/.ai-containers"
rvm_vol() { printf 'it-%s-rvm-%s' "$IT_RUN_ID" "$1"; }

# A group whose directory was deleted by hand.
mkdir -p "$groups_root/orphan"
docker volume create --label "$IT_LABEL" "$(rvm_vol orphan)" >/dev/null 2>&1
rm -rf "$groups_root/orphan"

# A healthy group.
mkdir -p "$groups_root/live/.claude"
docker volume create --label "$IT_LABEL" "$(rvm_vol live)" >/dev/null 2>&1

# A repo volume.
repo_register_volume untouchable || it_finish
repo_vol="$(repo_fixture_volume_name untouchable)"

assert_volume_exists "$(rvm_vol orphan)"
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
assert_volume_exists "$(rvm_vol live)"
assert_volume_exists "$repo_vol"
if [[ -d "$groups_root/live" ]]; then
  pass "the live group's directory is untouched"
else
  fail "the live group's directory is untouched — gc deleted it"
fi

it_finish
