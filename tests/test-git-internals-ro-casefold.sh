#!/usr/bin/env bash
# tests/test-git-internals-ro-casefold.sh — the git-internals protection on a
# case-insensitive filesystem (bugs review GIT-38): macOS's default APFS, and a
# WSL path under /mnt/<drive>. There a path spelled in another case names the
# same directory, and every "inside this mount" test the launcher makes was a
# case-sensitive prefix match of a path kept as it was spelled: a .git file's
# gitdir, or a core.worktree, written in another case named a git directory the
# launch never protected.
#
# Where TMPDIR already ignores case (macOS's APFS by default, a TMPDIR on a WSL
# drive), the cases run there. Elsewhere on Linux a casefold tmpfs, mounted in a
# user namespace of the current user, holds TMPDIR, so every path the launcher
# resolves lies on it; the capabilities the namespace grants are dropped before
# the test runs. Not applicable, and it says so, where neither can be had:
# unprivileged user namespaces off (Ubuntu 24.04's AppArmor default, a
# container), or a tmpfs with no casefold (Linux before 6.13). Platform-issues
# PLAT-8 has the Mac and WSL agents run it.
set -uo pipefail

if [[ -z "${_CF_INNER:-}" ]]; then
  cf_probe="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  mkdir "$cf_probe/Probe" && [[ -d "$cf_probe/PROBE" ]] && _CF_INNER=native \
    && printf 'NOTE: TMPDIR ignores case here; the cases run in it\n'
  rm -rf "$cf_probe"
fi
if [[ -z "${_CF_INNER:-}" ]]; then
  if ! command -v unshare >/dev/null 2>&1 || ! command -v setpriv >/dev/null 2>&1 \
     || ! unshare --user --map-current-user --mount --keep-caps true 2>/dev/null; then
    # SKIP, not a NOTE: run-all.sh takes a test that asserts nothing and says
    # no SKIP for a failure (review of the GIT-38 fix).
    printf 'SKIP: no unprivileged user namespace here, and TMPDIR does not ignore case\n'
    printf '\n0 failure(s)\n'; exit 0
  fi
  cf_base="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
  rc=0
  _CF_INNER="$cf_base" unshare --user --map-current-user --mount --keep-caps bash -c '
    mount -t tmpfs -o casefold tmpfs "$_CF_INNER" 2>/dev/null && mkdir "$_CF_INNER/cf" \
      && chattr +F "$_CF_INNER/cf" 2>/dev/null && mkdir "$_CF_INNER/cf/Probe" && [[ -d "$_CF_INNER/cf/PROBE" ]] \
      && rmdir "$_CF_INNER/cf/Probe" || exit 77
    export TMPDIR="$_CF_INNER/cf"
    printf "NOTE: the cases run on a casefold tmpfs in a user namespace\n"
    exec setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all -- bash "$1"' _ "$0" || rc=$?
  rmdir "$cf_base" 2>/dev/null
  if (( rc == 77 )); then
    printf 'SKIP: no casefold tmpfs here (Linux 6.13 or later), and TMPDIR does not ignore case\n'
    printf '\n0 failure(s)\n'; exit 0
  fi
  exit "$rc"
fi

# shellcheck source=tests/lib-git-internals-ro.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-git-internals-ro.sh"
# $PROJ as written in another case: the same directory here.
UPROJ="${PROJ%/*}/PROJ"
[[ -d "$UPROJ" ]] || { printf 'SCAFFOLD-FAILED: TMPDIR is not case-insensitive\n'; exit 1; }

# ── G117: a path spelled in another case is the directory it names ─────────
# A .git file whose gitdir: goes out of the project and back in, spelled in
# another case, into a node_modules the scan prunes: the git directory is the
# project's, and protected under the spelling on disk.
mkdir -p "$PROJ/src117" "$PROJ/node_modules/x117" && "${G[@]}" init -q --bare "$PROJ/node_modules/x117/g" \
  && "${G[@]}" config --file "$PROJ/node_modules/x117/g/config" core.bare false \
  && printf 'gitdir: ../../PROJ/node_modules/x117/g\n' > "$PROJ/src117/.git" \
  || { printf 'SCAFFOLD-FAILED: G117 gitdir\n'; exit 1; }
launch ..
has_mount "$PROJ/node_modules/x117/g/config:/workspace/proj/node_modules/x117/g/config:ro" \
  && pass "G117 a gitdir: spelled in another case names a git directory that is protected" \
  || fail "G117 gitdir: in another case left the git directory writable (git mounts: $(git_mounts | grep -c x117); stderr: $(grep -F x117 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$PROJ/src117" "$PROJ/node_modules/x117"

# A submodule's core.worktree spelled so: the index is read against the
# worktree, and the nested submodule it records, under a pruned node_modules,
# is protected.
M117="$PROJ/m117"; "${G[@]}" init -q "$M117" && mkdir -p "$M117/node_modules/sm" \
  && "${G[@]}" init -q --bare "$M117/.git/modules/sm" \
  && "${G[@]}" config --file "$M117/.git/modules/sm/config" core.bare false \
  && "${G[@]}" config --file "$M117/.git/modules/sm/config" core.worktree "$UPROJ/m117/node_modules/sm" \
  && "${G[@]}" --git-dir="$M117/.git/modules/sm" --work-tree="$M117/node_modules/sm" \
       update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$M117/node_modules/sm/vendor/n" \
  || { printf 'SCAFFOLD-FAILED: G117 core.worktree\n'; exit 1; }
launch ..
has_mount "$M117/node_modules/sm/vendor/n/.git/config:/workspace/proj/m117/node_modules/sm/vendor/n/.git/config:ro" \
  && pass "G117 a core.worktree spelled in another case is the worktree whose submodules are protected" \
  || fail "G117 core.worktree in another case (git mounts: $(git_mounts | grep -c m117); stderr: $(grep -F m117 "$ERR" | head -2 | tr '\n' ' '))"
rm -rf "$M117"

# An include whose target lies in the writable project, spelled in another
# case, is one the agent can write, and is named.
printf '[core]\n' > "$PROJ/inc117.cfg" && "${G[@]}" -C "$PROJ" config include.path "$UPROJ/inc117.cfg" \
  || { printf 'SCAFFOLD-FAILED: G117 include\n'; exit 1; }
launch ..
grep -qF "WARNING: /workspace/proj/.git/config includes $UPROJ/inc117.cfg (include.path)" "$ERR" \
  && pass "G117 an include spelled in another case into the writable project is named" \
  || fail "G117 include in another case (stderr: $(grep -F inc117 "$ERR" | head -2 | tr '\n' ' '))"
"${G[@]}" -C "$PROJ" config --unset include.path; rm -f "$PROJ/inc117.cfg"

# A hook that is a link to a script in the writable project, its target spelled
# in another case: the agent can change the script, and the hook is named.
printf '#!/bin/sh\n' > "$PROJ/run117.sh" && chmod 755 "$PROJ/run117.sh" \
  && ln -s "$UPROJ/run117.sh" "$PROJ/.git/hooks/post-commit" || { printf 'SCAFFOLD-FAILED: G117 hook link\n'; exit 1; }
launch ..
grep -qF 'NOTE: /workspace/proj/.git/hooks/post-commit, a hook your host' "$ERR" \
  && pass "G117 a hook linked to a script in the writable project, spelled in another case, is named" \
  || fail "G117 hook link in another case (stderr: $(grep -F post-commit "$ERR" | head -2 | tr '\n' ' '))"
rm -f "$PROJ/.git/hooks/post-commit" "$PROJ/run117.sh"

# ── The rest of the fix, each part pinned (review of the GIT-38 fix) ────────
# A submodule its index records in another case than its checkout: bash keeps
# the spelling, and left as written it was a writable pin over the launcher
# overlay of the checkout. Not followed, and named.
EN="$PROJ/eng117"; mkdir -p "$EN" && : > "$EN/sandbox.sh" && : > "$EN/sandbox-common.sh" && "${G[@]}" init -q "$EN" \
  && "${G[@]}" -C "$PROJ" update-index --add --cacheinfo "160000,$(printf '%040d' 1),ENG117" \
  || { printf 'SCAFFOLD-FAILED: G117 gitlink\n'; exit 1; }
launch ..
! grep -qF 'ENG117' <<<"$(mounts)" && grep -qF 'is not where its index says' "$ERR" \
  && pass "G117 a submodule recorded in another case is not followed, and is named" \
  || fail "G117 gitlink in another case ($(mounts | grep -F ENG117 | head -3 | tr '\n' ' '); stderr: $(grep -F ENG117 "$ERR" | head -1))"
"${G[@]}" -C "$PROJ" update-index --force-remove ENG117; rm -rf "$EN"

# A mount given in another case than on disk: its sources are spelled as on
# disk, as the paths compared with them are.
M1="$TMP/m117"; mkdir -p "$M1/src" "$M1/node_modules/x" && "${G[@]}" init -q --bare "$M1/node_modules/x/g" \
  && "${G[@]}" config --file "$M1/node_modules/x/g/config" core.bare false \
  && printf 'gitdir: ../node_modules/x/g\n' > "$M1/src/.git" || { printf 'SCAFFOLD-FAILED: G117 mount\n'; exit 1; }
EXTRA_MOUNTS="$TMP/M117" launch "$TMP/app"
# mounts, not git_mounts: a bare git directory has no .git in its path.
has_mount "$M1/node_modules/x/g/config:/workspace/M117/node_modules/x/g/config:ro" \
  && pass "G117 a mount named in another case protects what is in it" \
  || fail "G117 mount in another case (mounts: $(mounts | grep -ciF m117); stderr: $(grep -F m117 "$ERR" | head -1))"
rm -rf "$M1"

# A hook link whose way steps out of a project directory with .., and one that
# goes through a link in the project, both written in another case, the target
# itself out of every mount: the step is the agent's to change.
mkdir -p "$PROJ/sub117" "$TMP/out117" && printf '#!/bin/sh\n' > "$TMP/out117/run.sh" && chmod 755 "$TMP/out117/run.sh" \
  && ln -s "$TMP/out117" "$PROJ/lnk117" || { printf 'SCAFFOLD-FAILED: G117 walk\n'; exit 1; }
for w117 in "$UPROJ/sub117/../../out117/run.sh" "$UPROJ/lnk117/run.sh"; do
  rm -f "$PROJ/.git/hooks/post-commit"; ln -s "$w117" "$PROJ/.git/hooks/post-commit"
  launch ..
  grep -qF 'NOTE: /workspace/proj/.git/hooks/post-commit, a hook your host' "$ERR" \
    && pass "G117 a hook link's way through the project in another case is judged ($w117)" \
    || fail "G117 hook link way $w117 (stderr: $(grep -F post-commit "$ERR" | head -2 | tr '\n' ' '))"
done
rm -rf "$PROJ/.git/hooks/post-commit" "$PROJ/sub117" "$PROJ/lnk117" "$TMP/out117"

# A gitdir: that does not exist yet, written in another case: the agent can make
# it, and it is named.
mkdir -p "$PROJ/src117b" && printf 'gitdir: ../../PROJ/node_modules/later117\n' > "$PROJ/src117b/.git" \
  || { printf 'SCAFFOLD-FAILED: G117 missing\n'; exit 1; }
launch ..
grep -qF 'later117, which does not exist' "$ERR" \
  && pass "G117 a gitdir: in another case that does not exist yet is named" \
  || fail "G117 missing gitdir in another case (stderr: $(grep -F later117 "$ERR" | head -1))"
rm -rf "$PROJ/src117b"

# The group's own directories are not scanned, whatever case HOME is written in:
# a pin there breaks the tools that re-clone them.
mkdir -p "$HOME/.ai-containers/default/.agents/m117" && "${G[@]}" init -q "$HOME/.ai-containers/default/.agents/m117" \
  || { printf 'SCAFFOLD-FAILED: G117 group\n'; exit 1; }
HOME="${HOME%/*}/HOME" launch ..
! grep -qF 'm117' <<<"$(git_mounts)" \
  && pass "G117 the group's directories are not scanned with HOME written in another case" \
  || fail "G117 group scanned ($(git_mounts | grep -F m117 | head -2 | tr '\n' ' '))"
rm -rf "$HOME/.ai-containers/default/.agents/m117"

# A walk that ends where a directory does not exist yet, written in another
# case: the agent can make it, and both a hook link and an include are named
# (second review of the GIT-38 fix).
ln -s "$UPROJ/later117/run.sh" "$PROJ/.git/hooks/post-commit" \
  && "${G[@]}" -C "$PROJ" config include.path "$UPROJ/later117/inc.cfg" || { printf 'SCAFFOLD-FAILED: G117 later\n'; exit 1; }
launch ..
grep -qF 'NOTE: /workspace/proj/.git/hooks/post-commit, a hook your host' "$ERR" \
  && pass "G117 a hook link into a directory not made yet, written in another case, is named" \
  || fail "G117 hook link into a missing directory (stderr: $(grep -F post-commit "$ERR" | head -1))"
grep -qF "WARNING: /workspace/proj/.git/config includes $UPROJ/later117/inc.cfg (include.path)" "$ERR" \
  && pass "G117 an include into a directory not made yet, written in another case, is named" \
  || fail "G117 include into a missing directory (stderr: $(grep -F later117 "$ERR" | head -1))"
rm -f "$PROJ/.git/hooks/post-commit"; "${G[@]}" -C "$PROJ" config --unset include.path

# git opens its own names however they are spelled here: a repository whose
# .git, HEAD, config and hooks the agent spelled otherwise is git's to use, and
# found, protected and named like any other (second review of the GIT-38 fix).
# Through another name: a rename to the same name in another case is a rename
# onto itself here, which mv refuses.
mvc() { mv "$1" "$1.mvc" && mv "$1.mvc" "$2"; }
mkup() {  # DIR: a repository with .GIT, head, OBJECTS, REFS, CONFIG, HOOKS
  "${G[@]}" init -q "$1" && mvc "$1/.git" "$1/.GIT" && mvc "$1/.GIT/HEAD" "$1/.GIT/head" \
    && mvc "$1/.GIT/objects" "$1/.GIT/OBJECTS" && mvc "$1/.GIT/refs" "$1/.GIT/REFS" \
    && mvc "$1/.GIT/config" "$1/.GIT/CONFIG" && mvc "$1/.GIT/hooks" "$1/.GIT/HOOKS"
}
# Its index is read against its worktree, so a submodule it records under a
# pruned vendor/ is protected too.
mkup "$PROJ/up117" && "${G[@]}" --git-dir="$PROJ/up117/.GIT" --work-tree="$PROJ/up117" \
    update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$PROJ/up117/vendor/n" || { printf 'SCAFFOLD-FAILED: G117 .GIT\n'; exit 1; }
launch ..
grep -qxF "$PROJ/up117/.GIT/config:/workspace/proj/up117/.GIT/config:ro" <<<"$(mounts)" \
  && grep -qxF "$PROJ/up117/.GIT/hooks:/workspace/proj/up117/.GIT/hooks:ro" <<<"$(mounts)" \
  && pass "G117 a repository spelled .GIT, head and so on is found and protected" \
  || fail "G117 .GIT repository ($(grep -ciF up117 <<<"$(mounts)") mounts)"
has_mount "$PROJ/up117/vendor/n/.git/config:/workspace/proj/up117/vendor/n/.git/config:ro" \
  && pass "G117 a .GIT repository's index is read against its worktree" \
  || fail "G117 .GIT repository's submodule (mounts: $(grep -c 'vendor/n' <<<"$(mounts)"))"
# …and so is one with no head: a .git directory counts whatever its HEAD holds (G77).
rm -f "$PROJ/up117/.GIT/head"
launch ..
grep -qxF "$PROJ/up117/.GIT/config:/workspace/proj/up117/.GIT/config:ro" <<<"$(mounts)" \
  && pass "G117 a .GIT directory with no head is protected" \
  || fail "G117 .GIT without head ($(grep -ciF up117 <<<"$(mounts)") mounts)"
rm -rf "$PROJ/up117"
mkdir -p "$PROJ/src117c" "$PROJ/node_modules/x117c" && "${G[@]}" init -q --bare "$PROJ/node_modules/x117c/g" \
  && "${G[@]}" config --file "$PROJ/node_modules/x117c/g/config" core.bare false \
  && printf 'gitdir: ../node_modules/x117c/g\n' > "$PROJ/src117c/.GIT" || { printf 'SCAFFOLD-FAILED: G117 .GIT file\n'; exit 1; }
"${G[@]}" --git-dir="$PROJ/node_modules/x117c/g" --work-tree="$PROJ/src117c" \
    update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  && "${G[@]}" init -q "$PROJ/src117c/vendor/n" || { printf 'SCAFFOLD-FAILED: G117 .GIT file index\n'; exit 1; }
launch ..
has_mount "$PROJ/node_modules/x117c/g/config:/workspace/proj/node_modules/x117c/g/config:ro" \
  && pass "G117 a .git file spelled .GIT is followed" \
  || fail "G117 .GIT file (mounts: $(grep -c x117c <<<"$(mounts)"))"
has_mount "$PROJ/src117c/vendor/n/.git/config:/workspace/proj/src117c/vendor/n/.git/config:ro" \
  && pass "G117 the git directory a .GIT file names is read against its directory" \
  || fail "G117 .GIT file's worktree index (mounts: $(grep -c 'src117c/vendor' <<<"$(mounts)"))"
rm -rf "$PROJ/src117c" "$PROJ/node_modules/x117c"
# …and one the session makes is named when it ends.
mkdir -p "$TMP/ps117"
FAKE_SESSION="$(declare -f mvc mkup); G=(${G[*]}); mkup '$TMP/ps117/s' && printf '[core]\n\tfsmonitor = touch x\n' >> '$TMP/ps117/s/.GIT/CONFIG'" \
  EXTRA_MOUNTS="$TMP/ps117" launch "$TMP/app"
grep -qF "$TMP/ps117/s/.GIT" <<<"$(sed -n '/WARNING: the session made git repositories/,$p' "$ERR")" \
  && pass "G117 a repository the session spells .GIT is named when it ends" \
  || fail "G117 .GIT made in the session (rc=$LAUNCH_RC; stderr: $(tail -4 "$ERR" | tr '\n' ' '))"
rm -rf "$TMP/ps117"

# A hook hard-linked to a project file, its name spelled otherwise: git runs
# hooks/PRE-COMMIT as pre-commit, and its second name lets the agent change it
# (third review of the GIT-38 fix).
ln "$PROJ/README" "$PROJ/.git/hooks/PRE-COMMIT" || { printf 'SCAFFOLD-FAILED: G117 hard link\n'; exit 1; }
launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'has more than one hard link' "$ERR" \
  && pass "G117 a hook named in another case with a second name refuses the launch" \
  || fail "G117 hard-linked PRE-COMMIT (rc=$LAUNCH_RC; stderr: $(grep -F ERROR "$ERR" | head -1))"
rm -f "$PROJ/.git/hooks/PRE-COMMIT"

# A linked worktree checked out outside every mount, its gitdir written in
# another case: it names its git directory back, and is no "worktree unknown".
OW="$TMP/ow117"; "${G[@]}" -C "$PROJ" worktree add -q "$OW" 2>/dev/null \
  && printf '%s/.git\n' "${OW%/*}/OW117" > "$PROJ/.git/worktrees/ow117/gitdir" \
  && "${G[@]}" -C "$OW" update-index --add --cacheinfo "160000,$(printf '%040d' 1),vendor/n" \
  || { printf 'SCAFFOLD-FAILED: G117 worktree\n'; exit 1; }
launch ..
! grep -qF 'no worktree is known' "$ERR" \
  && pass "G117 a worktree outside the mounts, its gitdir in another case, is known" \
  || fail "G117 worktree gitdir in another case ($(grep -F 'no worktree' "$ERR" | head -1))"
"${G[@]}" -C "$PROJ" worktree remove --force "$OW" 2>/dev/null; rm -rf "$OW"; "${G[@]}" -C "$PROJ" worktree prune

# What the agent can make this cost is bounded: past the budget the launch is
# refused, and says why.
AI_CONTAINERS_SPELL_MAX=2 launch ..
[[ "$LAUNCH_RC" != 0 ]] && grep -qF 'ERROR: more than 2 directories on a filesystem that ignores case' "$ERR" \
  && pass "G117 past its budget of directories to spell, the launch is refused" \
  || fail "G117 spell budget (rc=$LAUNCH_RC; stderr: $(grep ERROR "$ERR" | head -1))"

# ── G121: a file bound read-only on its own is put back when the session ends
# (bugs review GIT-41) ───────────────────────────────────────────────────────
# A container's kernel compares names case-sensitively, so .git/CONFIG is not
# the mount point of .git/config's read-only bind; a host share that ignores
# case (Colima's and Docker Desktop's virtiofs on macOS, measured on Colima)
# opens it as config all the same, and the write lands. A directory has one
# dentry in the guest, so hooks/ and .git hold. Modelled here by the fake
# docker's session writing the host's files under the other spelling.
cfg0="$(cat "$PROJ/.git/config")"
asides() { find "$PROJ/.git" "$PROJ/wt121" -maxdepth 1 -name '*.changed-*' 2>/dev/null; }
FAKE_SESSION="printf '[core]\n\tfsmonitor = touch $TMP/pwned121\n' >> '$PROJ/.git/CONFIG'" launch ..
a121="$(asides | grep -F '/.git/config.changed-' | head -1)"
[[ "$(cat "$PROJ/.git/config")" == "$cfg0" && -n "$a121" ]] && grep -qF fsmonitor "$a121" \
  && grep -qF "WARNING: $PROJ/.git/config changed while the container ran" "$ERR" \
  && pass "G121 a config written as .git/CONFIG is put back, and what it held is kept and named" \
  || fail "G121 .git/CONFIG (config now: $(grep -c fsmonitor "$PROJ/.git/config") fsmonitor line(s); aside: ${a121:-none}; stderr: $(grep -F 'container ran' "$ERR" | head -1))"
rm -f "$PROJ"/.git/config.changed-*

FAKE_SESSION="printf '../planted\n' > '$PROJ/.git/COMMONDIR'" launch ..
[[ "$(cat "$PROJ/.git/commondir")" == ./ ]] \
  && pass "G121 a commondir written as .git/COMMONDIR is put back" \
  || fail "G121 .git/COMMONDIR (commondir now: $(cat "$PROJ/.git/commondir"))"
rm -f "$PROJ"/.git/commondir.changed-*

# Removed, or replaced by a link or a FIFO: put back as a regular file, and the
# FIFO neither hangs the launcher nor is read.
for what121 in removes "replaces with a link" "replaces with a FIFO"; do
  how121="rm -f '$PROJ/.git/CONFIG'"
  case "$what121" in
    *link) how121+=" && ln -s '$TMP/elsewhere121' '$PROJ/.git/CONFIG'" ;;
    *FIFO) how121+=" && mkfifo '$PROJ/.git/CONFIG'" ;;
  esac
  FAKE_SESSION="$how121" launch_timed 60 ..
  [[ "$LAUNCH_RC" == 0 && -f "$PROJ/.git/config" && ! -L "$PROJ/.git/config" && "$(cat "$PROJ/.git/config")" == "$cfg0" ]] \
    && pass "G121 a config the session $what121 is put back as it was" \
    || fail "G121 a config the session $what121 (rc=$LAUNCH_RC in ${LAUNCH_S}s; stderr: $(grep -F -e WARNING -e ERROR "$ERR" | tail -2 | tr '\n' ' '))"
  rm -f "$PROJ"/.git/config.changed-*
done

# A linked worktree's .git file, written as .GIT.
"${G[@]}" -C "$PROJ" worktree add -q "$PROJ/wt121" 2>/dev/null || { printf 'SCAFFOLD-FAILED: G121 worktree\n'; exit 1; }
wt0="$(cat "$PROJ/wt121/.git")"
FAKE_SESSION="printf 'gitdir: $TMP/evil121\n' > '$PROJ/wt121/.GIT'" launch ..
[[ "$(cat "$PROJ/wt121/.git")" == "$wt0" ]] \
  && pass "G121 a worktree's .git file written as .GIT is put back" \
  || fail "G121 wt/.GIT (now: $(cat "$PROJ/wt121/.git"))"
"${G[@]}" -C "$PROJ" worktree remove --force "$PROJ/wt121" 2>/dev/null; rm -rf "$PROJ/wt121"; "${G[@]}" -C "$PROJ" worktree prune

# Nothing changed: nothing is said or left behind, and the container's exit
# status is still the launcher's.
FAKE_DOCKER_RC=3 FAKE_SESSION=":" launch ..
[[ "$LAUNCH_RC" == 3 && -z "$(asides)" ]] && ! grep -qF 'changed while the container ran' "$ERR" \
  && pass "G121 a session that changes nothing puts nothing back, and keeps its exit status" \
  || fail "G121 no change (rc=$LAUNCH_RC; asides: $(asides | tr '\n' ' '); stderr: $(grep -F 'container ran' "$ERR" | head -1))"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
