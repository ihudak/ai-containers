#!/usr/bin/env bash
# summary:  under a writable PARENT mount, launchers stay read-only (even under an odd name) and the directories above them cannot be moved
# tags:     security mounts fast
# requires: docker launcher
#
# Case 450 covers the documented launch, where the project is the mount root and
# .ai-containers its direct child. A mount rooted higher up — EXTRA_MOUNTS of a
# parent directory, a vault or specs tree holding projects — puts ordinary
# directories between the mount root and the launcher. An ordinary directory
# above a mount point can be renamed, and the read-only overlay moves with it,
# leaving the path the host reads free to be recreated. sandbox.sh therefore
# binds each directory in between onto itself, which makes it a mount point the
# kernel refuses to move (EBUSY) while leaving it exactly as writable as before.
#
# The same mount also exposes ANOTHER project's launcher, which must be read-only
# too: the host runs it at that project's next launch.
#
# Three more sit under names an agent can create, one per way docker is handed a
# path: `odd,name` and `tr ` (trailing space) go through -v, which keeps both;
# `c:o,n` holds -v's separator, so it goes through --mount, whose value docker
# reads as CSV — quoted fields, or the comma splits one. Handed over wrongly,
# any of them makes docker refuse the whole `docker run`, at every launch.
#
# One more holds bytes that are not valid UTF-8 (a code point above U+10FFFF —
# which glibc's iconv accepts and Go does not). docker's CLI would rewrite it to
# U+FFFD, and Docker Desktop then CREATES the rewritten path, root-owned, in the
# host tree. It is not mounted at all, with a WARNING; the launch goes ahead and
# nothing root-owned appears on the host.
#
# Paired as everywhere in this tier: the parent and the pinned directory must
# still accept writes, so "cannot move" cannot mean "nothing here works".
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

grp="$(it_scratch)/grp"
launcher_engine_in "$grp/proj" || it_finish
mkdir -p "$grp/other/.ai-containers"
# A real launcher is a directory holding both sandbox.sh and sandbox-common.sh
# (what launcher_dirs_in matches, and what ./sandbox.sh needs to run at all).
printf '#!/usr/bin/env bash\n' > "$grp/other/.ai-containers/sandbox.sh"
: > "$grp/other/.ai-containers/sandbox-common.sh"
mkdir -p "$grp/odd,name/.ai-containers"
printf '#!/usr/bin/env bash\n' > "$grp/odd,name/.ai-containers/sandbox.sh"
: > "$grp/odd,name/.ai-containers/sandbox-common.sh"
printf 'marker-odd\n'   > "$grp/odd,name/.ai-containers/MARKER"
for n in "tr " "c:o,n"; do
  mkdir -p "$grp/$n/.ai-containers"
  printf '#!/usr/bin/env bash\n' > "$grp/$n/.ai-containers/sandbox.sh"
  : > "$grp/$n/.ai-containers/sandbox-common.sh"
  printf 'marker-%s\n' "$n" > "$grp/$n/.ai-containers/MARKER"
done
printf 'marker-proj\n'  > "$grp/proj/.ai-containers/MARKER"
printf 'marker-other\n' > "$grp/other/.ai-containers/MARKER"

bad_ok=0
bad="$grp/bad"$'\xf4\x90\x80\x80'
if mkdir -p "$bad/.ai-containers" 2>/dev/null; then
  : > "$bad/.ai-containers/sandbox.sh"; : > "$bad/.ai-containers/sandbox-common.sh"; bad_ok=1
fi

export EXTRA_MOUNTS="$grp"
launcher_up open "$grp/proj" || it_finish

# Both launchers are visible through the parent mount ...
assert_agent_reads "$IT_CID" /workspace/grp/proj/.ai-containers/MARKER  marker-proj
assert_agent_reads "$IT_CID" /workspace/grp/other/.ai-containers/MARKER marker-other
# ... and neither accepts a write, while what surrounds them does.
assert_not_writable "$IT_CID" /workspace/grp/proj/.ai-containers
assert_not_writable "$IT_CID" /workspace/grp/other/.ai-containers
assert_agent_reads  "$IT_CID" "/workspace/grp/odd,name/.ai-containers/MARKER" marker-odd
assert_not_writable "$IT_CID" "/workspace/grp/odd,name/.ai-containers"
for n in "tr " "c:o,n"; do
  assert_agent_reads  "$IT_CID" "/workspace/grp/$n/.ai-containers/MARKER" "marker-$n"
  assert_not_writable "$IT_CID" "/workspace/grp/$n/.ai-containers"
done
assert_writable     "$IT_CID" /workspace/grp
assert_writable     "$IT_CID" /workspace/grp/proj

if [[ "$bad_ok" -eq 1 ]]; then
  grep -aqF "WARNING: cannot protect $bad" "$IT_LAUNCH_ERR" \
    && pass "a launcher under a name docker cannot carry is skipped with a warning" \
    || fail "a launcher under a name docker cannot carry is skipped with a warning"
  junk="$(find "$grp" ! -user "$IT_LAUNCH_UID" -print 2>/dev/null | head -3)"
  [[ -z "$junk" ]] \
    && pass "nothing owned by another user appeared in the host tree" \
    || fail "nothing owned by another user appeared in the host tree — found: $junk"
else
  pass "(this filesystem refuses a name that is not valid UTF-8; nothing to check)"
fi

# The directory between the mount root and the launcher stays where it is.
if agent_exec "$IT_CID" 'mv /workspace/grp/proj /workspace/grp/proj.moved' >/dev/null 2>&1; then
  fail "the directory above the launcher cannot be moved — the move SUCCEEDED"
  agent_exec "$IT_CID" 'mv /workspace/grp/proj.moved /workspace/grp/proj' >/dev/null 2>&1 || true
else
  pass "the directory above the launcher cannot be moved"
fi
assert_host_file_exists "$grp/proj/.ai-containers/MARKER"

it_finish
