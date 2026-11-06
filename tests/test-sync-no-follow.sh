#!/usr/bin/env bash
# PRJ-10: sync_project never writes through, or reads through, a link the agent
# planted in a project. The project root is the agent's to write, and so is its
# .ai-containers/ when that directory is itself a writable mount (the launcher
# allows it with a NOTE). Every file sync writes there is built in a private
# directory and renamed in; every file it reads there is read through one open
# checked to be the regular file its path names.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
# git's global excludes file is $XDG_CONFIG_HOME/git/ignore where that is set:
# a developer's exported one would decide what these tests see.
unset XDG_CONFIG_HOME
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1

# shellcheck disable=SC1090
source "$REPO_DIR/sync-to-projects.sh"
set +e  # it turns errexit on; the checks below read non-zero returns

V="$TMP/victims"; DIRS="allowlist-domains.d allowlist-proxy-domains.d allowlist-cidrs.d tools.d services.d"
for x in $DIRS; do mkdir -p "$V/dir-$x"; done
for f in rootgi innergi conf engine shared; do printf 'victim %s\n' "$f" > "$V/$f"; chmod 600 "$V/$f"; done
snap() { local f x; for f in "$V"/*; do [[ -f "$f" ]] && printf '%s %s %s\n' "$f" "$(p_sha1 "$f")" "$(p_stat_mode "$f")"; done; for x in $DIRS; do ls -A "$V/dir-$x"; done; }

proj="$TMP/proj"; d="$proj/.ai-containers"; mkdir -p "$d"
git -C "$proj" init -q
# Links the agent could plant, each to a file of the user's.
ln -s "$V/rootgi"  "$proj/.gitignore"
ln -s "$V/innergi" "$d/.gitignore"
ln -s "$V/engine"  "$d/engine-version"
ln -s "$V/shared"  "$d/sandbox.sh"
for x in $DIRS; do ln -s "$V/dir-$x" "$d/$x"; done
ln -s "$V/created" "$d/sandbox.env"          # dangling: must not be created
# …and a launcher the sandbox.env backfill takes IMAGE_NAME from, so it writes.
printf '#!/usr/bin/env bash\nexport IMAGE_NAME=linked-proj\n./sandbox.sh\n' > "$d/zz-old.sh"
before="$(snap)"

out="$(sync_project "$proj" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "sync_project exits 0 over planted links" || fail "sync_project exits 0 over planted links: $out"
[[ "$before" == "$(snap)" ]] && pass "no file or directory a link pointed at was written, created or chmod'ed" \
  || fail "no file or directory a link pointed at was written, created or chmod'ed: $(diff <(printf '%s\n' "$before") <(snap))"
[[ ! -e "$V/created" && -f "$d/sandbox.env" && ! -L "$d/sandbox.env" ]] && grep -qx 'IMAGE_NAME=linked-proj' "$d/sandbox.env" \
  && pass "a dangling sandbox.env link is replaced by the backfilled file, not written through" \
  || fail "a dangling sandbox.env link is replaced by the backfilled file, not written through"

# What sync owns is replaced by a real file or directory; what it reads it does not follow.
[[ -f "$d/sandbox.sh" && ! -L "$d/sandbox.sh" ]] && cmp -s "$d/sandbox.sh" "$REPO_DIR/sandbox.sh" \
  && pass "a linked shared file is replaced by the engine's copy" || fail "a linked shared file is replaced by the engine's copy"
[[ "$(p_stat_mode "$d/sandbox.sh")" == "$(p_stat_mode "$REPO_DIR/sandbox.sh")" ]] \
  && pass "a shared file gets the engine copy's mode" || fail "a shared file gets the engine copy's mode ($(p_stat_mode "$d/sandbox.sh"))"
for x in $DIRS; do
  [[ -d "$d/$x" && ! -L "$d/$x" && ! -e "$d/$x/$x" ]] && diff -rq -x custom.txt "$REPO_DIR/$x" "$d/$x" >/dev/null \
    && pass "a linked $x is replaced by a real copy, with no nested $x/$x" \
    || fail "a linked $x is replaced by a real copy, with no nested $x/$x"
done
[[ -f "$d/engine-version" && ! -L "$d/engine-version" || ! -e "$d/engine-version" ]] \
  && pass "engine-version is written as a file of its own (or removed), never through its link" \
  || fail "engine-version is written as a file of its own (or removed), never through its link"
[[ -f "$d/.gitignore" && ! -L "$d/.gitignore" ]] && grep -qxF sandbox.local.env "$d/.gitignore" \
  && pass "the inner .gitignore is replaced by a file holding the patterns" \
  || fail "the inner .gitignore is replaced by a file holding the patterns"
[[ -L "$proj/.gitignore" ]] && pass "the project's own .gitignore link is left alone (it is the project's file)" \
  || fail "the project's own .gitignore link is left alone (it is the project's file)"
[[ "$out" == *NOTE*".gitignore"* ]] && pass "the linked root .gitignore is named in a NOTE" \
  || fail "the linked root .gitignore is named in a NOTE: $out"

# ── The sandbox.env backfill reads only regular files, through a checked open ──
# A FIFO among *.sh hung it, and a link was read through. If sync is still
# blocked after 20 s, the FIFO is fed so the test ends, and that is recorded.
projf="$TMP/projf"; df="$projf/.ai-containers"; mkdir -p "$df"
mkfifo "$df/aa-fifo.sh"
printf 'export IMAGE_NAME=secret-image\n' > "$V/launcher"; ln -s "$V/launcher" "$df/ab-link.sh"
printf '#!/usr/bin/env bash\nexport IMAGE_NAME=fat-image\n./sandbox.sh\n' > "$df/zz-old.sh"
( sleep 20; [[ -e "$TMP/done" ]] || { : > "$TMP/unblocked"; : > "$df/aa-fifo.sh"; } ) 2>/dev/null & ub=$!
out="$(sync_project "$projf" 2>&1)"; rc=$?
: > "$TMP/done"; pkill -P "$ub" 2>/dev/null; kill "$ub" 2>/dev/null; wait "$ub" 2>/dev/null
[[ ! -e "$TMP/unblocked" ]] && pass "a FIFO among *.sh does not block the sandbox.env backfill" \
  || fail "a FIFO among *.sh does not block the sandbox.env backfill"
[[ $rc -eq 0 && "$(grep '^IMAGE_NAME=' "$df/sandbox.env" 2>/dev/null)" == IMAGE_NAME=fat-image ]] \
  && pass "the backfill takes IMAGE_NAME from the regular launcher, not through a link" \
  || fail "the backfill takes IMAGE_NAME from the regular launcher, not through a link (rc=$rc): $(cat "$df/sandbox.env" 2>&1) $out"

# ── A dangling link as the project's .gitignore is the project's: kept and named ──
proj4="$TMP/proj4"; mkdir -p "$proj4/.ai-containers"; git -C "$proj4" init -q
ln -s "$V/no-such-gitignore" "$proj4/.gitignore"
out="$(sync_project "$proj4" 2>&1)"; rc=$?
[[ $rc -eq 0 && -L "$proj4/.gitignore" && ! -e "$V/no-such-gitignore" && "$out" == *NOTE*.gitignore* ]] \
  && pass "a dangling link as the project's .gitignore is kept, not replaced or written through, and named" \
  || fail "a dangling link as the project's .gitignore is kept, not replaced or written through, and named (rc=$rc): $out"

# ── sandbox.conf behind a link: not reconciled, named, and its target untouched ──
proj2="$TMP/proj2"; d2="$proj2/.ai-containers"; mkdir -p "$d2"
printf '# schema-version: 1\n' > "$V/conf"
ln -s "$V/conf" "$d2/sandbox.conf"
before="$(p_sha1 "$V/conf")"
out="$(sync_project "$proj2" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$before" == "$(p_sha1 "$V/conf")" && -L "$d2/sandbox.conf" && "$out" == *NOTE*sandbox.conf* ]] \
  && pass "a linked sandbox.conf is not reconciled through, and is named" \
  || fail "a linked sandbox.conf is not reconciled through, and is named (rc=$rc): $out"

# ── The ordinary case still works: a real sandbox.conf is reconciled, its mode kept ──
proj3="$TMP/proj3"; d3="$proj3/.ai-containers"; mkdir -p "$d3"; git -C "$proj3" init -q
printf '# schema-version: 1\ncopilot=OFF\n' > "$d3/sandbox.conf"; chmod 640 "$d3/sandbox.conf"
printf 'IMAGE_NAME=p3\n' > "$d3/sandbox.env"
sync_project "$proj3" >/dev/null 2>&1; rc=$?
want="$(conf_schema_version "$REPO_DIR/sandbox.conf")"
[[ $rc -eq 0 && "$(conf_schema_version "$d3/sandbox.conf")" == "$want" ]] && grep -qx 'copilot=OFF' "$d3/sandbox.conf" \
  && grep -q '^claude-code=' "$d3/sandbox.conf" && [[ "$(p_stat_mode "$d3/sandbox.conf")" == 640 ]] \
  && pass "a real sandbox.conf is reconciled in place of itself, mode 640 kept" \
  || fail "a real sandbox.conf is reconciled in place of itself, mode 640 kept (rc=$rc, mode $(p_stat_mode "$d3/sandbox.conf"))"
grep -qx '/.ai-containers/' "$proj3/.gitignore" && [[ ! -L "$proj3/.gitignore" ]] \
  && pass "a project with no .gitignore gets one ignoring /.ai-containers/" \
  || fail "a project with no .gitignore gets one ignoring /.ai-containers/"
leftover="$(find "$proj3" "$d3" -maxdepth 1 -name '.*.??????' 2>/dev/null)"
[[ -z "$leftover" ]] && pass "no temporary files are left in the project" || fail "no temporary files are left in the project: $leftover"

# ── A .ai-containers that is itself a link is not synced into ──
proj6="$TMP/proj6"; mkdir -p "$proj6" "$V/dir-dest"; ln -s "$V/dir-dest" "$proj6/.ai-containers"
out="$(sync_project "$proj6" 2>&1)"
[[ -z "$(ls -A "$V/dir-dest")" && "$out" == *ERROR*"is a link"* ]] \
  && pass "a .ai-containers that is a link is an ERROR and nothing is written through it" \
  || fail "a .ai-containers that is a link is an ERROR and nothing is written through it: $out"
_sync_errors=0

# ── The real script, all projects, under its own set -e: a directory planted
# where a shared file goes is an ERROR for that project, the next is still
# synced, and the run exits 1 ──
E="$TMP/engine"; mkdir -p "$E"
rsync -a --exclude='.git' --exclude='tests' --exclude='docs' --exclude='projects.conf' "$REPO_DIR/" "$E/"
pa="$TMP/pa"; pb="$TMP/pb"; mkdir -p "$pa/.ai-containers/build.sh" "$pb/.ai-containers"
# …and a non-empty directory where a fragment file goes, which rsync cannot replace.
mkdir -p "$pa/.ai-containers/tools.d/dtctl.conf/x"
printf '%s\n%s\n' "$pa" "$pb" > "$E/projects.conf"
out="$(bash "$E/sync-to-projects.sh" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"ERROR: could not write $pa/.ai-containers/build.sh"* && "$out" == *"ERROR: could not sync $pa/.ai-containers/tools.d"* \
   && -f "$pb/.ai-containers/sandbox.sh" && "$out" == *INCOMPLETE* ]] \
  && pass "a failed write is an ERROR for its project, later projects are synced, and the run exits 1" \
  || fail "a failed write is an ERROR for its project, later projects are synced, and the run exits 1 (rc=$rc): $out"

(( fails == 0 )) || { printf '%d failure(s)\n' "$fails"; exit 1; }
printf 'All sync no-follow checks passed.\n'
