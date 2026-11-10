#!/usr/bin/env bash
# tests/test-project-files.sh — project-files.sh's helpers, called directly.
#
# project-files.sh is how sync-to-projects.sh, project-init.sh and
# migrate-runme.sh read and write a project's files without following a link the
# agent planted there (bugs review PRJ-10, PRJ-11). tests/test-sync-no-follow.sh
# and tests/test-init-no-follow.sh drive it through whole syncs and inits; this
# file calls each helper on the inputs those cannot reach (a command that fails,
# a FIFO, a mode, a status a caller under set -e depends on), which measuring it
# under the falsify tier found unasserted (feature gaps review GAP-2, the
# project-files.sh slice). Hermetic: no docker, a private HOME and git config.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (${3:-})"; fi; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset XDG_CONFIG_HOME AI_CONTAINERS_NO_GITIGNORE
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
ROOT=""; [[ "$(id -u)" == 0 ]] && ROOT=1

# shellcheck source=../version.sh
source "$REPO_DIR/version.sh"
# shellcheck source=../project-files.sh
source "$REPO_DIR/project-files.sh"
# Set by project-files.sh, and the out-variable the helpers here write: named
# for shellcheck, which does not follow the source.
: "${_proj_dest_fd:=}" "${_proj_why:=}"; v=""

# ── _proj_read ────────────────────────────────────────────────────────────────
printf 'hello\n' > "$TMP/r1"; chmod 640 "$TMP/r1"
_proj_read "$TMP/r1" "$TMP/r1.out"; rc=$?
check "_proj_read copies a regular file and reports its mode" \
  '[[ "$rc" == 0 && "$(cat "$TMP/r1.out")" == hello && "$_proj_perms" == rw-r----- ]]' "rc=$rc perms=$_proj_perms"
# A FIFO is refused before it is opened: opened, the read would wait for a
# writer for ever (the test before the open takes a regular file only).
mkfifo "$TMP/fifo1"
got="$(timeout 10 bash -c 'source "$1/version.sh"; source "$1/project-files.sh"; _proj_read "$2/fifo1" "$2/fifo1.out"; echo $?' _ "$REPO_DIR" "$TMP")"
check "_proj_read refuses a FIFO at once, without opening it" '[[ "$got" == 1 ]]' "got '$got'"
# A read that fails after the open (here the output cannot be written) is a
# failure, 1, whatever mode an earlier read left in _proj_perms.
_proj_perms=rw-r--r--
_proj_read "$TMP/r1" "$TMP/no-such-dir/out" 2>/dev/null; rc=$?
check "_proj_read whose copy cannot be written fails with 1, an earlier mode notwithstanding" '[[ "$rc" == 1 ]]' "rc=$rc"
head -c 70000 /dev/zero | tr '\0' a > "$TMP/big"
_proj_read "$TMP/big" "$TMP/big.out"; rc=$?
check "_proj_read of a file over its bound is 2" '[[ "$rc" == 2 ]]' "rc=$rc"

# ── _proj_fd_perms ───────────────────────────────────────────────────────────
# The mode of the file OPEN on the descriptor, not of what the name holds now:
# a file renamed over the name after the open does not lend it its mode.
printf 'a\n' > "$TMP/p1"; chmod 640 "$TMP/p1"; printf 'b\n' > "$TMP/p2"; chmod 600 "$TMP/p2"
exec {pfd}<"$TMP/p1"; mv -f "$TMP/p2" "$TMP/p1"
got="$(_proj_fd_perms "$TMP/p1" "$pfd")"; exec {pfd}<&-
if [[ -L "/dev/fd/0" ]]; then
  check "_proj_fd_perms gives the open file's mode, not the mode of what the name now holds" '[[ "$got" == rw-r----- ]]' "got '$got'"
else
  printf 'NOTE: /dev/fd is not a link here (macOS fdescfs); the descriptor-mode check is Linux-only\n'
fi

# ── _proj_write ──────────────────────────────────────────────────────────────
printf 'new\n' > "$TMP/src"
mkdir -p "$TMP/w"
_proj_write "$TMP/src" "$TMP/w/f" rwxr-x---; rc=$?
check "_proj_write writes the file with the mode asked for" \
  '[[ "$rc" == 0 && "$(cat "$TMP/w/f")" == new && "$(_perms_of "$TMP/w/f")" == rwxr-x--- ]]' "rc=$rc perms=$(_perms_of "$TMP/w/f")"
# A target that is a real directory is a failed write, and the temporary file
# made beside it does not stay.
mkdir -p "$TMP/w/d"
_proj_write "$TMP/src" "$TMP/w/d" rw-r--r--; rc=$?
check "_proj_write over a directory fails, and leaves no temporary file" \
  '[[ "$rc" != 0 && -z "$(ls -A "$TMP/w" | grep -F ".d.")" ]]' "rc=$rc left: $(ls -A "$TMP/w" | tr '\n' ' ')"
# No temporary name to be had, or no file to be made there: a failure, never 0.
got="$( ( mktemp() { return 1; }; _proj_write "$TMP/src" "$TMP/w/g" rw-r--r--; echo $? ) )"
check "_proj_write with no temporary name to be had fails" '[[ "$got" == 1 && ! -e "$TMP/w/g" ]]' "got '$got'"
if [[ -z "$ROOT" ]]; then
  mkdir -p "$TMP/ro"; chmod 555 "$TMP/ro"
  _proj_write "$TMP/src" "$TMP/ro/f" rw-r--r--; rc=$?; chmod 755 "$TMP/ro"
  check "_proj_write into a directory it cannot write fails" '[[ "$rc" == 1 && ! -e "$TMP/ro/f" ]]' "rc=$rc"
else
  printf 'NOTE: run as root, which writes any directory; the read-only directory check is not applicable\n'
fi

# ── _proj_ptr and _proj_resolve ──────────────────────────────────────────────
printf 'gitdir: /x\r\n' > "$TMP/ptr1"
_proj_ptr "$TMP/ptr1" v; rc=$?
check "_proj_ptr reads a pointer, its trailing CR and LF cut" '[[ "$rc" == 0 && "$v" == "gitdir: /x" ]]' "rc=$rc v='$v'"
printf 'gitdir: /x\0/y\n' > "$TMP/ptr2"
_proj_ptr "$TMP/ptr2" v; rc=$?
check "_proj_ptr refuses a pointer holding a NUL" '[[ "$rc" == 1 ]]' "rc=$rc v='$v'"
_proj_ptr "$TMP/no-such-ptr" v; rc=$?
check "_proj_ptr of a file that is not there fails" '[[ "$rc" == 1 && -z "$v" ]]' "rc=$rc"
got="$( ( mktemp() { return 1; }; _proj_ptr "$TMP/ptr1" v; echo $? ) )"
check "_proj_ptr with no temporary file to be had fails" '[[ "$got" == 1 ]]' "got '$got'"
_proj_resolve "$TMP" no-such-dir v; rc=$?
check "_proj_resolve of a directory that is not there fails, its result empty" '[[ "$rc" == 1 && -z "$v" ]]' "rc=$rc v='$v'"

# ── proj_backup, proj_version_record ─────────────────────────────────────────
got="$( ( mktemp() { return 1; }; proj_backup "$TMP/r1" "$TMP/bk"; echo $? ) )"
check "proj_backup with no temporary directory to be had fails" '[[ "$got" == 1 && ! -e "$TMP/bk" ]]' "got '$got'"
mkdir -p "$TMP/vsrc" "$TMP/vdst"; printf 'v9.9.9\n' > "$TMP/vsrc/engine-version"
got="$(proj_version_record "$TMP/vsrc" "$TMP/vdst"; echo "rc=$?")"
check "proj_version_record records the version, saying nothing" \
  '[[ "$got" == rc=0 && "$(cat "$TMP/vdst/engine-version")" == v9.9.9 ]]' "got '$got'"
got="$( ( mktemp() { return 1; }; proj_version_record "$TMP/vsrc" "$TMP/vdst"; echo $? ) )"
check "proj_version_record returns 0 with no temporary directory (its callers run under set -e)" '[[ "$got" == 0 ]]' "got '$got'"

# ── proj_dest_pin, proj_dest_unpin, _proj_dest_same, proj_dest_ok ────────────
mkdir -p "$TMP/dest"
proj_dest_pin "$TMP/no-such-dest"; rc=$?
check "proj_dest_pin of a directory that is not there fails" '[[ "$rc" == 1 && -z "$_proj_dest_fd" ]]' "rc=$rc"
proj_dest_pin "$TMP/r1"; rc=$?
check "proj_dest_pin of a regular file fails, and pins nothing" '[[ "$rc" == 1 && -z "$_proj_dest_fd" ]]' "rc=$rc"
proj_dest_pin "$TMP/dest"; rc=$?; pfd="$_proj_dest_fd"
check "proj_dest_pin of a directory pins it" '[[ "$rc" == 0 && -n "$pfd" ]] && _proj_dest_same' "rc=$rc"
# Renamed and replaced by a link to where it went: the same directory, by way of
# a link the agent made, which is not the directory this run started in.
mv "$TMP/dest" "$TMP/dest2" && ln -s "$TMP/dest2" "$TMP/dest"
_proj_dest_same; rc=$?
check "_proj_dest_same refuses a destination replaced by a link to the same directory" '[[ "$rc" == 1 ]]' "rc=$rc"
proj_dest_unpin
check "proj_dest_unpin closes the descriptor it pinned" '[[ -z "$_proj_dest_fd" && ! -e "/proc/$$/fd/$pfd" ]]' "fd $pfd"
got="$(proj_dest_unpin 2>&1; echo "rc=$?")"
check "proj_dest_unpin with nothing pinned does nothing, quietly" '[[ "$got" == rc=0 ]]' "got '$got'"
proj_dest_ok "$TMP/dest" 2>/dev/null; rc1=$?
proj_dest_ok "$TMP/r1" 2>/dev/null; rc2=$?
proj_dest_ok "$TMP/dest2"; rc3=$?
check "proj_dest_ok refuses a link and a file, and takes a directory" '[[ "$rc1" == 1 && "$rc2" == 1 && "$rc3" == 0 ]]' "link $rc1, file $rc2, directory $rc3"

# ── _proj_index_tracks ───────────────────────────────────────────────────────
mkrepo() { git init -q "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i; }
mkrepo "$TMP/it"
got="$( ( unset -f _ver_git_runs; _proj_index_tracks "$TMP/it/.git" "$TMP/it/.git"; printf '%s|%s' "$?" "$_proj_why" ) )"
check "_proj_index_tracks with only half of version.sh loaded says version.sh is not loaded" \
  '[[ "$got" == "2|version.sh is not loaded" ]]' "got '$got'"
if [[ -z "$ROOT" ]]; then
  chmod 600 "$TMP/it/.git"
  _proj_index_tracks "$TMP/it/.git" "$TMP/it/.git"; rc=$?; chmod 755 "$TMP/it/.git"
  check "_proj_index_tracks of a git directory that can be read but not searched is not known" \
    '[[ "$rc" == 2 && "$_proj_why" == "its git directory cannot be searched" ]]' "rc=$rc why='$_proj_why'"
fi
: > "$TMP/it/.git/index" 2>/dev/null; git -C "$TMP/it" add -A 2>/dev/null
mkfifo "$TMP/it/.git/sharedindex.0000000000000000000000000000000000000000"
_proj_index_tracks "$TMP/it/.git" "$TMP/it/.git"; rc=$?
check "_proj_index_tracks with a split index part that is a FIFO is not known" \
  '[[ "$rc" == 2 && "$_proj_why" == "its split index is not a regular file" ]]' "rc=$rc why='$_proj_why'"
rm -f "$TMP/it/.git"/sharedindex.*
# A config that is not a regular file is not read: the default object format.
mkrepo "$TMP/ic"; mkdir -p "$TMP/icfg"
_proj_index_tracks "$TMP/ic/.git" "$TMP/icfg"; rc=$?
mkdir -p "$TMP/icfg/config"
_proj_index_tracks "$TMP/ic/.git" "$TMP/icfg"; rc2=$?
check "_proj_index_tracks reads no config that is not a regular file" '[[ "$rc" == "$rc2" && "$rc2" != 2 ]]' "plain $rc, config a directory $rc2 ($_proj_why)"
# An object format that passes the name check but that git does not know.
mkrepo "$TMP/if"; git -C "$TMP/if" config extensions.objectformat md5
_proj_index_tracks "$TMP/if/.git" "$TMP/if/.git"; rc=$?
check "_proj_index_tracks of an object format git does not know says so" \
  '[[ "$rc" == 2 && "$_proj_why" == "its object format is not one git knows" ]]' "rc=$rc why='$_proj_why'"

# ── _proj_ignored_elsewhere ──────────────────────────────────────────────────
mkrepo "$TMP/ie"
got="$( ( unset -f _ver_run _ver_git_runs; _proj_ignored_elsewhere "$TMP/ie/.git" "$TMP/ie"; echo $? ) )"
check "_proj_ignored_elsewhere with version.sh not loaded says not ignored" '[[ "$got" == 1 ]]' "got '$got'"
# Half of it loaded, and the global excludes file holding the line: still not
# taken for ignored, since without git the excludes file in use is not known.
mkdir -p "$HOME/.config/git"; printf '/.ai-containers/\n' > "$HOME/.config/git/ignore"
got="$( ( unset -f _ver_git_runs; _proj_ignored_elsewhere "$TMP/ie/.git" "$TMP/ie"; echo $? ) )"
rm -f "$HOME/.config/git/ignore"
check "_proj_ignored_elsewhere with half of version.sh loaded says not ignored" '[[ "$got" == 1 ]]' "got '$got'"

# ── ensure_ai_containers_ignored ─────────────────────────────────────────────
# Every way out returns 0: sync-to-projects.sh and project-init.sh run under
# set -e, and a 1 ended the sync of every project after this one.
eai() { ensure_ai_containers_ignored "$1" > "$TMP/eai.out" 2>&1; echo $?; }
P="$TMP/eai"
mkrepo "$P/plain"
got="$(AI_CONTAINERS_NO_GITIGNORE=1 eai "$P/plain")"
check "with AI_CONTAINERS_NO_GITIGNORE=1 it returns 0 and writes nothing" '[[ "$got" == 0 && ! -e "$P/plain/.gitignore" ]]' "got '$got'"
got="$(eai "$P/plain")"
check "a plain repository gets the line, and is told so" \
  '[[ "$got" == 0 ]] && grep -qx "/.ai-containers/" "$P/plain/.gitignore" && grep -qF "Added /.ai-containers/ to plain/.gitignore" "$TMP/eai.out"' "got '$got': $(cat "$TMP/eai.out")"
# A .gitignore ending in a newline gets no blank line before the added ones.
mkrepo "$P/nl"; printf 'node_modules/\n' > "$P/nl/.gitignore"
got="$(eai "$P/nl")"
check "a .gitignore that ends in a newline gets none added before the line" \
  '[[ "$got" == 0 && "$(sed -n 2p "$P/nl/.gitignore")" == "# AI sandbox tooling"* ]]' "got '$got': $(head -3 "$P/nl/.gitignore" | tr '\n' '|')"
mkdir -p "$P/lnk" && mkrepo "$TMP/lnktarget" && ln -s "$TMP/lnktarget/.git" "$P/lnk/.git"
got="$(eai "$P/lnk")"
check "a .git that is a link: 0, named" '[[ "$got" == 0 ]] && grep -qF "its .git is a link" "$TMP/eai.out"' "got '$got'"
mkdir -p "$P/badfile" && printf 'not a pointer\n' > "$P/badfile/.git"
got="$(eai "$P/badfile")"
check "a .git file that is no pointer: 0, named" '[[ "$got" == 0 ]] && grep -qF "names no git directory" "$TMP/eai.out"' "got '$got'"
# A .git file without its "gitdir: " that names a directory is no pointer
# either: git refuses it, and so does this.
mkdir -p "$P/bare" && printf '%s\n' "$TMP/lnktarget/.git" > "$P/bare/.git"
got="$(eai "$P/bare")"
check "a .git file naming a directory without gitdir: is no pointer" \
  '[[ "$got" == 0 && ! -e "$P/bare/.gitignore" ]] && grep -qF "names no git directory" "$TMP/eai.out"' "got '$got': $(cat "$TMP/eai.out")"
mkrepo "$P/gil" && ln -s "$TMP/r1" "$P/gil/.gitignore"
got="$(eai "$P/gil")"
check "a .gitignore that is a link: 0, named" '[[ "$got" == 0 && "$(cat "$TMP/r1")" == hello ]] && grep -qF "is a link" "$TMP/eai.out"' "got '$got'"
mkrepo "$P/gib" && head -c 4200000 /dev/zero | tr '\0' a > "$P/gib/.gitignore"
got="$(eai "$P/gib")"
check "a .gitignore too large to read: 0, named" '[[ "$got" == 0 ]] && grep -qF "too large to read" "$TMP/eai.out"' "got '$got'"
mkrepo "$P/cd" && printf 'nowhere\n' > "$P/cd/.git/commondir"
got="$(eai "$P/cd")"
check "a commondir that cannot be read: 0, named" '[[ "$got" == 0 ]] && grep -qF "commondir of its git directory cannot be read" "$TMP/eai.out"' "got '$got'"
mkrepo "$P/ex" && printf '/.ai-containers/\n' > "$P/ex/.git/info/exclude"
got="$(eai "$P/ex")"
check "a repository whose info/exclude holds the line: 0, nothing written" '[[ "$got" == 0 && ! -e "$P/ex/.gitignore" ]]' "got '$got'"
mkrepo "$P/tr" && mkdir -p "$P/tr/.ai-containers" && : > "$P/tr/.ai-containers/x" && git -C "$P/tr" add -f .ai-containers/x
got="$(eai "$P/tr")"
check "a repository that tracks .ai-containers/: 0, nothing written" '[[ "$got" == 0 && ! -e "$P/tr/.gitignore" ]]' "got '$got': $(cat "$TMP/eai.out")"
mkrepo "$P/plain3"
got="$( ( mktemp() { return 1; }; ensure_ai_containers_ignored "$P/plain3" >/dev/null 2>&1; echo $? ) )"
check "with no temporary directory to be had: 0, nothing written" '[[ "$got" == 0 && ! -e "$P/plain3/.gitignore" ]]' "got '$got'"

# ── ensure_inner_gitignore ───────────────────────────────────────────────────
I="$TMP/inner"; mkdir -p "$I"
got="$(ensure_inner_gitignore "$I"; echo "rc=$?")"
check "a missing inner .gitignore is written, and that is said" '[[ "$got" == *"Backfilled .ai-containers/.gitignore patterns."*rc=0 ]] && grep -qx sandbox.local.env "$I/.gitignore"' "got '$got'"
# Complete already: not rewritten (its inode stays), nothing said.
ino1="$(ls -i "$I/.gitignore" | awk '{print $1}')"
got="$(ensure_inner_gitignore "$I"; echo "rc=$?")"
ino2="$(ls -i "$I/.gitignore" | awk '{print $1}')"
check "a complete inner .gitignore is not rewritten" '[[ "$got" == rc=0 && "$ino1" == "$ino2" ]]' "got '$got', inode $ino1 then $ino2"
# Ending in a newline, missing patterns: no blank line before them.
printf 'mine\n' > "$I/.gitignore"
ensure_inner_gitignore "$I" >/dev/null
check "an inner .gitignore that ends in a newline gets none added before the patterns" '[[ "$(sed -n 2p "$I/.gitignore")" == .agent-blocked/ ]]' "$(head -3 "$I/.gitignore" | tr '\n' '|')"
got="$( ( mktemp() { return 1; }; ensure_inner_gitignore "$TMP/inner2"; echo $? ) )"
check "ensure_inner_gitignore returns 0 with no temporary directory (its callers run under set -e)" '[[ "$got" == 0 ]]' "got '$got'"

# ── More of what the syncing tests reach, here on its own ────────────────────
# So that this file alone kills what tests/test-sync-project.sh and
# tests/test-init-no-follow.sh do, at a fraction of their time per mutant.
G6=(git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main)
# _proj_fd_is: a descriptor open on another file is not the path's.
printf 'x\n' > "$TMP/fa"; printf 'y\n' > "$TMP/fb"
exec {qfd}<"$TMP/fb"; _proj_fd_is "$TMP/fa" "$qfd"; rc=$?; exec {qfd}<&-
check "_proj_fd_is of a path and a descriptor open on another file is false" '[[ "$rc" == 1 ]]' "rc=$rc"
if [[ -z "$ROOT" ]]; then
  printf 's\n' > "$TMP/unr"; chmod 000 "$TMP/unr"
  _proj_read "$TMP/unr" "$TMP/unr.out" 2>/dev/null; rc=$?; chmod 600 "$TMP/unr"
  check "_proj_read of a file that cannot be opened fails" '[[ "$rc" == 1 ]]' "rc=$rc"
  got="$( ( chmod 000 "$TMP/unr"; proj_backup "$TMP/unr" "$TMP/unr.bak"; echo $? ) )"; chmod 600 "$TMP/unr"
  check "proj_backup of a file that cannot be read fails, and writes nothing" '[[ "$got" == 1 && ! -e "$TMP/unr.bak" ]]' "got '$got'"
fi
printf 'secret\n' > "$TMP/sec"; chmod 600 "$TMP/sec"
proj_backup "$TMP/sec" "$TMP/sec.bak"; rc=$?
check "proj_backup copies the file with its mode" '[[ "$rc" == 0 && "$(cat "$TMP/sec.bak")" == secret && "$(_perms_of "$TMP/sec.bak")" == rw------- ]]' "rc=$rc perms=$(_perms_of "$TMP/sec.bak")"
# _proj_write refuses once the pinned destination is no longer the directory
# this run started in.
mkdir -p "$TMP/pd"; proj_dest_pin "$TMP/pd"
mv "$TMP/pd" "$TMP/pd2" && mkdir -p "$TMP/pd"
_proj_write "$TMP/src" "$TMP/pd/f" rw-r--r-- 2>/dev/null; rc=$?; proj_dest_unpin
check "_proj_write refuses once the destination was replaced" '[[ "$rc" == 1 && ! -e "$TMP/pd/f" ]]' "rc=$rc"
# _proj_resolve, relative from the directory given, absolute as it is,
# wherever it is called from.
mkdir -p "$TMP/rs/sub"
# shellcheck disable=SC2034  # read in check's condition, which shellcheck does not parse
rsp="$(cd -P "$TMP/rs/sub" && pwd)"
got1="$(cd / && _proj_resolve "$TMP/rs" sub v && printf '%s' "$v")"
got2="$(cd / && _proj_resolve "$TMP/elsewhere" "$TMP/rs/sub" v && printf '%s' "$v")"
check "_proj_resolve takes a relative path from the directory given, an absolute one as it is" '[[ "$got1" == "$rsp" && "$got2" == "$rsp" ]]' "rel '$got1' abs '$got2'"
# ensure_ai_containers_ignored, more of its ways.
mkdir -p "$P/norepo"
got="$(eai "$P/norepo")"
check "a project that is no repository: 0, nothing written" '[[ "$got" == 0 && ! -e "$P/norepo/.gitignore" && ! -s "$TMP/eai.out" ]]' "got '$got'"
mkrepo "$P/dl" && ln -s "$TMP/dangling-target" "$P/dl/.gitignore"
got="$(eai "$P/dl")"
check "a dangling link as .gitignore is kept, not written through, and named" \
  '[[ "$got" == 0 && -L "$P/dl/.gitignore" && ! -e "$TMP/dangling-target" ]] && grep -qF "is a link" "$TMP/eai.out"' "got '$got'"
mkrepo "$P/has" && printf 'x\n/.ai-containers/\n' > "$P/has/.gitignore"; ino1="$(ls -i "$P/has/.gitignore" | awk '{print $1}')"
got="$(eai "$P/has")"; ino2="$(ls -i "$P/has/.gitignore" | awk '{print $1}')"
check "a .gitignore that holds the line already is left as it is" '[[ "$got" == 0 && "$ino1" == "$ino2" && ! -s "$TMP/eai.out" ]]' "got '$got', inode $ino1 then $ino2"
mkrepo "$P/nonl" && printf 'node_modules/' > "$P/nonl/.gitignore"
got="$(eai "$P/nonl")"
check "a .gitignore with no final newline keeps its last line apart" \
  '[[ "$got" == 0 && "$(sed -n 1p "$P/nonl/.gitignore")" == node_modules/ && "$(sed -n 2p "$P/nonl/.gitignore")" == "# AI sandbox tooling"* ]]' "$(head -2 "$P/nonl/.gitignore" | tr '\n' '|')"
mkdir -p "$P/noidx" && "${G6[@]}" -C "$P/noidx" init -q && rm -f "$P/noidx/.git/index"
got="$(eai "$P/noidx")"
check "a repository with no index gets the line" '[[ "$got" == 0 ]] && grep -qx "/.ai-containers/" "$P/noidx/.gitignore"' "got '$got': $(cat "$TMP/eai.out")"
mkdir -p "$P/bad" && "${G6[@]}" -C "$P/bad" init -q && printf 'garbage' > "$P/bad/.git/index"
got="$(eai "$P/bad")"
check "an index git cannot read adds nothing, and is named" '[[ "$got" == 0 && ! -e "$P/bad/.gitignore" ]] && grep -qF "git could not read its index" "$TMP/eai.out"' "got '$got': $(cat "$TMP/eai.out")"
FI="$P/fifoidx"; mkdir -p "$FI" && "${G6[@]}" -C "$FI" init -q && rm -f "$FI/.git/index" && mkfifo "$FI/.git/index"
( exec 3<>"$FI/.git/index"; exec sleep 20 ) & w6=$!
got="$(eai "$FI")"; kill "$w6" 2>/dev/null; wait "$w6" 2>/dev/null
check "a FIFO index adds nothing, and is named" '[[ "$got" == 0 && ! -e "$FI/.gitignore" ]] && grep -qF "its index is not a regular file" "$TMP/eai.out"' "got '$got': $(cat "$TMP/eai.out")"
rg6="$(command -v git)"; mkdir -p "$TMP/slowgit"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = ls-files ] && exec sleep 8; done\nexec %q "$@"\n' "$rg6" > "$TMP/slowgit/git"; chmod +x "$TMP/slowgit/git"
SG="$P/slow"; mkdir -p "$SG" && "${G6[@]}" -C "$SG" init -q && : > "$SG/f" && "${G6[@]}" -C "$SG" add f
t6=$SECONDS; got="$( _ver_secs=1; PATH="$TMP/slowgit:$PATH"; eai "$SG" )"; t6=$(( SECONDS - t6 ))
check "an index read that takes too long adds nothing, and is named" '[[ "$got" == 0 && ! -e "$SG/.gitignore" ]] && grep -qF "within 1 s" "$TMP/eai.out" && (( t6 < 6 ))' "got '$got' in ${t6}s: $(cat "$TMP/eai.out")"
mksparse() {  # DIR CONE-DIR
  mkdir -p "$1/.ai-containers" "$1/src" && "${G6[@]}" -C "$1" init -q && : > "$1/.ai-containers/x" && : > "$1/src/y" \
    && "${G6[@]}" -C "$1" add . && "${G6[@]}" -C "$1" commit -qm s \
    && "${G6[@]}" -C "$1" sparse-checkout init --cone --sparse-index >/dev/null 2>&1 \
    && "${G6[@]}" -C "$1" sparse-checkout set "$2" >/dev/null 2>&1 \
    && [[ "$("${G6[@]}" -C "$1" config --get index.sparse)" == true ]]
}
if mksparse "$P/sp" src && mksparse "$P/spc" .ai-containers; then
  got="$(eai "$P/sp")"
  check "a sparse index git can read only in part adds nothing, and is named" '[[ "$got" == 0 && ! -e "$P/sp/.gitignore" ]] && grep -qF "only in part" "$TMP/eai.out"' "got '$got': $(cat "$TMP/eai.out")"
  got="$(eai "$P/spc")"
  check "a sparse index that lists the copy counts as tracking it" '[[ "$got" == 0 && ! -e "$P/spc/.gitignore" && ! -s "$TMP/eai.out" ]]' "got '$got': $(cat "$TMP/eai.out")"
else
  printf 'NOTE: this git makes no sparse index; the sparse-index checks are not applicable\n'
fi
# Ignored by your global excludes, as git takes them: core.excludesFile, also
# relative (from the work tree's top, wherever the sync runs), and the XDG
# default only where core.excludesFile is not set.
mkdir -p "$P/gx" && "${G6[@]}" -C "$P/gx" init -q && printf '/.ai-containers/\n' > "$TMP/gx-file"
printf '[core]\n\texcludesFile = %s\n' "$TMP/gx-file" > "$TMP/gx.cfg"
got="$(GIT_CONFIG_GLOBAL="$TMP/gx.cfg" eai "$P/gx")"
check "a copy your core.excludesFile ignores gets no line" '[[ "$got" == 0 && ! -e "$P/gx/.gitignore" ]]' "got '$got': $(cat "$TMP/eai.out")"
mkdir -p "$P/rx" && "${G6[@]}" -C "$P/rx" init -q && printf '.ai-containers/\n' > "$P/rx/rel-ignore"
printf '[core]\n\texcludesFile = rel-ignore\n' > "$TMP/rx.cfg"
got="$(cd / && GIT_CONFIG_GLOBAL="$TMP/rx.cfg" eai "$P/rx")"
check "a relative core.excludesFile is read from the work tree's top" '[[ "$got" == 0 && ! -e "$P/rx/.gitignore" ]]' "got '$got': $(cat "$TMP/eai.out")"
mkdir -p "$P/xg" "$TMP/xdg/git" && "${G6[@]}" -C "$P/xg" init -q && printf '.ai-containers/\n' > "$TMP/xdg/git/ignore" && : > "$TMP/empty.cfg"
got="$(GIT_CONFIG_GLOBAL="$TMP/empty.cfg" XDG_CONFIG_HOME="$TMP/xdg" eai "$P/xg")"
check "a copy git's default global excludes file ignores gets no line" '[[ "$got" == 0 && ! -e "$P/xg/.gitignore" ]]' "got '$got': $(cat "$TMP/eai.out")"
mkdir -p "$P/xo" && "${G6[@]}" -C "$P/xo" init -q && printf 'other\n' > "$TMP/gx-other"
printf '[core]\n\texcludesFile = %s\n' "$TMP/gx-other" > "$TMP/gxo.cfg"
got="$(GIT_CONFIG_GLOBAL="$TMP/gxo.cfg" XDG_CONFIG_HOME="$TMP/xdg" eai "$P/xo")"
check "with core.excludesFile set, the XDG default is not git's, and the line is added" '[[ "$got" == 0 ]] && grep -qx "/.ai-containers/" "$P/xo/.gitignore"' "got '$got': $(cat "$TMP/eai.out")"
# ensure_inner_gitignore: an inner .gitignore too large to read is left alone.
mkdir -p "$TMP/inner3" && head -c 4200000 /dev/zero | tr '\0' a > "$TMP/inner3/.gitignore"
got="$(ensure_inner_gitignore "$TMP/inner3"; echo "rc=$?")"
check "an inner .gitignore too large to read: 0, named, left alone" '[[ "$got" == *"too large to read"*rc=0 && "$(wc -c < "$TMP/inner3/.gitignore")" -eq 4200000 ]]' "got '${got:0:200}'"

# ... and one with no final newline keeps its last line apart.
mkdir -p "$TMP/inner4" && printf 'mine' > "$TMP/inner4/.gitignore"
ensure_inner_gitignore "$TMP/inner4" >/dev/null
check "an inner .gitignore with no final newline keeps its last line apart" \
  '[[ "$(sed -n 1p "$TMP/inner4/.gitignore")" == mine && "$(sed -n 2p "$TMP/inner4/.gitignore")" == .agent-blocked/ ]]' "$(head -2 "$TMP/inner4/.gitignore" | tr '\n' '|')"
# _proj_index_tracks reads no config that is a FIFO: git would wait on it.
mkrepo "$TMP/ifc"; mkdir -p "$TMP/ifcc" && mkfifo "$TMP/ifcc/config"
got="$( _ver_secs=1; _proj_index_tracks "$TMP/ifc/.git" "$TMP/ifcc"; printf '%s|%s' "$?" "$_proj_why" )"
check "_proj_index_tracks reads no config that is a FIFO" '[[ "$got" != 2* ]]' "got '$got'"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
