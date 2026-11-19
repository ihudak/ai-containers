#!/usr/bin/env bash
# shellcheck disable=SC1090  # project.sh is sourced from a computed path, on purpose
# project.sh: `rm` — what it lists, removes and keeps, and what stops it.
# Hermetic: HOME and an engine copy live in a temp dir; docker is a logging fake
# (tests/lib-project-tool.sh, shared with the other tests/test-project-*.sh).
# shellcheck source=tests/lib-project-tool.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-project-tool.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-project-tool.sh\n'; exit 1; }
# The engine copy's project.sh, named in this file so tests/falsify/derive-targets.sh,
# which reads each file's own assignments, sees that this test runs it.
P="$ENG/project.sh"

# ── rm ──

# the whole of it, by --yes
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'
mkdir -p "$W/beta/.ai-containers"; printf '%s\n' "$W/beta" >> "$ENG/projects.conf"
printf 'sha256:keep-me|/elsewhere\n' >> "$IP"; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"
ida="$(tid "$A/.ai-containers")"; pa="$(cd "$A/.ai-containers" && pwd -P)"
rmrun "$A" --yes; rc=$?
ok "rm removes .ai-containers, its projects.conf line and its image-projects.conf line" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && ! grep -qxF "$2" "$3" && grep -qxF "$4" "$3" \
           && ! grep -qF "$5" "$6" && grep -qxF "sha256:keep-me|/elsewhere" "$6"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$W/beta" "$ida" "$IP"
ok "rm removes the image whose label is this project's id, without --force" \
  bash -c '[ ! -e "$1" ] && grep -qxF "docker rmi img-alpha" "$2" && ! grep -q -- "-f" < <(grep "^docker rmi" "$2")' \
  _ "$IMGS/img-alpha" "$DOCKER_LOG"
listing() {
  hasx "  directory   $A/.ai-containers" && hasx "  registry    $A (projects.conf)" && hasx "  image       img-alpha" \
    && hasx "  working copy ai-containers-repo-app--wc-1 (app, launched from $A/.ai-containers) — nothing at risk: every branch pushed, no stash, the checkout clean"
}
ok "rm --yes still prints the listing" listing
ok "  … naming the image-projects.conf line it drops" hasx "  registry    $pa (image-projects.conf, once no image carries its id)"

# the image: only the one this project's id is on
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-shared\n'
printf 'ai-containers.project=sha256:%064d\n' 7 > "$IMGS/img-shared"
rmrun "$A" --yes; rc=$?
ok "rm keeps an IMAGE_NAME whose label is another project's id" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && ! grep -q "^docker rmi" "$3" && grep -qF "  image       img-shared — kept: " "$4"' \
  _ "$rc" "$IMGS/img-shared" "$DOCKER_LOG" "$TMP/out"
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=ubuntu:24.04\n'
printf 'org.opencontainers.image.title=Ubuntu\n' > "$IMGS/ubuntu:24.04"
rmrun "$A" --yes; rc=$?
ok "rm keeps an IMAGE_NAME with no ai-containers labels" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && ! grep -q "^docker rmi" "$3" && grep -qF "  image       ubuntu:24.04 — kept: " "$4"' \
  _ "$rc" "$IMGS/ubuntu:24.04" "$DOCKER_LOG" "$TMP/out"

# the working copies launched from it, in either spelling of its path
world
mkdir -p "$W/real/alpha" "$W/real/alphax"; ln -s "$W/real" "$W/lnk"
A="$W/lnk/alpha"; mkproj "$A"; mkproj "$W/beta"; mkbase app; mkbase lib
mkwc app 1 "$A/.ai-containers" "$CLEAN"
mkwc app 2 "$W/real/alpha/.ai-containers" "$CLEAN"
mkwc lib 3 "$W/real/alpha/sub" "$CLEAN"
mkwc app 4 "$W/beta/.ai-containers" "$CLEAN"
mkwc app 5 "$W/real/alphax/.ai-containers" "$CLEAN"
mkvol ai-containers-repo-app--wc-6 "ai-containers.workcopy=1" "ai-containers.repo=app"
rmrun "$A" --yes; rc=$?
printf '%s\n' ai-containers-repo-app--wc-1 ai-containers-repo-app--wc-2 ai-containers-repo-lib--wc-3 > "$TMP/expect"
ok "rm removes exactly the working copies launched from this project" \
  bash -c '[ "$1" = 0 ] && [ "$(sed -n "s/^docker volume rm //p" "$2" | LC_ALL=C sort)" = "$(cat "$3")" ]' _ "$rc" "$DOCKER_LOG" "$TMP/expect"

world
O="$W/outer"; mkproj "$O"; mkproj "$O/inner"; mkbase app
mkwc app 1 "$O/.ai-containers" "$CLEAN"; mkwc app 2 "$O/inner/.ai-containers" "$CLEAN"
rmrun "$O" --yes; rc=$?
ok "rm leaves a working copy launched from a nested registered project" \
  bash -c '[ "$1" = 0 ] && [ "$(sed -n "s/^docker volume rm //p" "$2")" = ai-containers-repo-app--wc-1 ] \
           && [ -d "$3/ai-containers-repo-app--wc-2" ] && [ -d "$4/inner/.ai-containers" ] && grep -qxF "$4/inner" "$5"' \
  _ "$rc" "$DOCKER_LOG" "$VOLS" "$O" "$ENG/projects.conf"

# what a working copy would lose, listed before the question
risk() {  # <base type> <records>: one copy of app, listed; the answer is no
  world; A="$W/alpha"; mkproj "$A"; mkbase app "$1"
  mkwc app 1 "$A/.ai-containers" "$2"
  rmrun "$A"
}
copy_line() { grep -F "  working copy ai-containers-repo-app--wc-$1 (app, launched from $A/.ai-containers) — " "$TMP/out"; }
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkwc app 1 "$A/.ai-containers" $'PRIMARY|main\nBRANCH|main|0|current\nBRANCH|feature|2|\nWORKTREE|clean\nEND|inspect\n'
mkwc app 2 "$A/.ai-containers" "$CLEAN"
rmrun "$A"
ok "rm lists a copy with 2 unpushed commits as at risk" \
  bash -c '[[ "$1" == *"AT RISK"*"feature"*"2 unpushed"* ]] && [[ "$2" != *"AT RISK"* ]] \
           && grep -qxF "1 working cop(y/ies) at risk or not checked." "$3"' _ "$(copy_line 1)" "$(copy_line 2)" "$TMP/out"
risk git $'PRIMARY|main\nBRANCH|main|0|current\nWORKTREE|changed\nEND|inspect\n'
ok "rm lists a copy with WORKTREE|changed as holding uncommitted work" \
  bash -c '[[ "$1" == *"AT RISK"*"uncommitted work"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"
risk path ""
ok "rm lists a copy of a path repo as not checked" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"path repo"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"
risk git $'STALE|could not clone\nBRANCH|main|?|current\nWORKTREE|?\nEND|inspect\n'
ok "rm lists a copy whose remote is STALE as not checked" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"could not clone"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"
risk git $'NESTED|vendor/lib\nPRIMARY|main\nBRANCH|main|0|current\nSTASH|2\nTAG|v5|no|no\nTAG|v6|moved|?\nTAG|v7|yes|yes\nWORKTREE|?\nEND|inspect\n'
ok "rm lists a stash, tags whose commit may be on no remote, a nested repository and an unknown checkout as at risk" \
  bash -c '[[ "$1" == *"AT RISK"* && "$1" == *"a stash (2"* && "$1" == *"tag v5"* && "$1" == *"tag v6"* && "$1" != *"tag v7"* \
            && "$1" == *"vendor/lib"* && "$1" == *"uncommitted work unknown"* ]]' _ "$(copy_line 1)"
# kept by the remote as repo.sh reset counts it: the tag itself, another on its
# commit, or the commit on a remote branch or tag
risk git $'PRIMARY|main\nBRANCH|main|0|current\nTAG|v1|yes|yes\nTAG|v2|same|no\nTAG|v3|moved|yes\nTAG|v4|no|yes\nWORKTREE|clean\nEND|inspect\n'
ok "rm lists a copy whose tags the remote keeps as nothing at risk" \
  bash -c '[[ "$1" == *"nothing at risk"* ]] && ! grep -q "at risk or not checked" "$2"' _ "$(copy_line 1)" "$TMP/out"
# REPO-21, REPO-20: commits on a detached HEAD, and a submodule's repository in
# .git/modules, go with the copy as with a reset
risk git $'PRIMARY|main\nBRANCH|main|0|current\nDETACHED|2\nMODULE|sub\nWORKTREE|?\nEND|inspect\n'
ok "rm lists a detached HEAD's unpushed commits and a submodule's repository as at risk" \
  bash -c '[[ "$1" == *"AT RISK"* && "$1" == *"a detached HEAD: 2 unpushed"* && "$1" == *".git/modules/sub: a submodule"* ]]' _ "$(copy_line 1)"
risk git $'PRIMARY|main\nBRANCH|main|0|current\nDETACHED|0\nWORKTREE|clean\nEND|inspect\n'
ok "rm lists a detached HEAD whose commits are all on the remote as nothing at risk" \
  bash -c '[[ "$1" == *"nothing at risk"* ]]' _ "$(copy_line 1)"
risk git $'PRIMARY|main\nBRANCH|main|0|current\n'
ok "rm lists a copy whose inspection was cut short as not checked" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"cut short"* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' _ "$(copy_line 1)" "$TMP/out"
risk git $'STALE|could not clone\nBRANCH|main|?|current\nSTASH|1\nWORKTREE|?\nEND|inspect\n'
ok "rm lists what a STALE inspection had already seen (a stash) on its not-checked line" \
  bash -c '[[ "$1" == *"NOT CHECKED"*"could not clone"*"a stash (1"* ]]' _ "$(copy_line 1)"
# the copies that cannot be checked at all, each counted
unchecked() {  # <copy line pattern> <assertion name>
  ok "$2" bash -c '[[ "$1" == *"NOT CHECKED"*$3* ]] && grep -qxF "1 working cop(y/ies) at risk or not checked." "$2"' \
    _ "$(grep -F "  working copy ai-containers-repo-app--wc-1 (" "$TMP/out")" "$TMP/out" "$1"
}
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkvol ai-containers-repo-app--wc-1 "ai-containers.workcopy=1" "ai-containers.launch-dir=$A/.ai-containers"
rmrun "$A"; unchecked "no ai-containers.repo label" "rm lists a copy with no repo label as not checked"
world; A="$W/alpha"; mkproj "$A"; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rmrun "$A"; unchecked "is gone" "rm lists a copy whose base volume is gone as not checked"
world; A="$W/alpha"; mkproj "$A"; mkwc app 1 "$A/.ai-containers" "$CLEAN"
mkvol ai-containers-repo-app "ai-containers.repo=other" "ai-containers.type=git" "ai-containers.source=https://example.invalid/other.git"
rmrun "$A"; unchecked "not labelled as repo app" "rm lists a copy whose base volume is labelled for another repo as not checked (REPO-11)"
world; A="$W/alpha"; mkproj "$A"; mkbase app svn; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rmrun "$A"; unchecked "records no repo type" "rm lists a copy whose base volume is neither git nor path as not checked"
# a seed image that cannot be had makes the copies not checked, never stops rm
world; A="$W/alpha"; mkproj "$A"; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"; mkwc app 2 "$A/.ai-containers" "$CLEAN"
export FAKE_NO_SEED=1
rmrun "$A" --yes; rc=$?
unset FAKE_NO_SEED
ok "rm lists copies as not checked when the seed image cannot be had, and finishes" \
  bash -c '[ "$1" = 0 ] && grep -qF "(app, launched from $4/.ai-containers) — NOT CHECKED: the seed helper image" "$2" && [ ! -d "$3/ai-containers-repo-app--wc-1" ]' \
  _ "$rc" "$TMP/out" "$VOLS" "$A"
ok "  … resolving the seed image once, not per copy" \
  bash -c '[ "$(grep -c "^docker image inspect ai-containers-seed" "$1")" = 1 ]' _ "$DOCKER_LOG"

# the question, and what stops it
unchanged() {  # <root> <id>: nothing of the project was removed
  [[ -d "$1/.ai-containers" ]] && grep -qxF -- "$1" "$ENG/projects.conf" && grep -qF -- "$2" "$IP" \
    && ! logged '^docker (volume rm|rmi)'
}
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"; ida="$(tid "$A/.ai-containers")"
rmrun "$A"; rc=$?
ok "rm refuses on a non-TTY without --yes and changes nothing" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR" "$2" && [ -d "$3/ai-containers-repo-app--wc-1" ] && [ -e "$4" ]' \
  _ "$rc" "$TMP/out" "$VOLS" "$IMGS/img-alpha"
ok "  … and the directory and both lines are intact" unchanged "$A" "$ida"

printf 'ctr-one|other-image|/somewhere|%s/.ai-containers/.agent-blocked\n' "$A" > "$FAKE_RUNNING"; : > "$DOCKER_LOG"
rmrun "$A" --yes; rc=$?
ok "rm refuses while a container mounts the project's .ai-containers" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-one" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
printf 'ctr-two|img-alpha|/somewhere\n' > "$FAKE_RUNNING"; : > "$DOCKER_LOG"
rmrun "$A" --yes; rc=$?
ok "rm refuses while a container runs its image" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-two" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
world
mkdir -p "$W/real"; ln -s "$W/real" "$W/lnk"; L="$W/lnk/alpha"; mkproj "$L"
printf 'ctr-three|other-image|%s/.ai-containers\n' "$(cd "$W/real/alpha" && pwd -P)" > "$FAKE_RUNNING"
rmrun "$L" --yes; rc=$?
ok "rm refuses while a container mounts the project's .ai-containers by its physical path" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-three" "$2" && [ -d "$3/.ai-containers" ]' _ "$rc" "$TMP/out" "$L"
# docker that cannot list containers is no evidence that none runs
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
export FAKE_PS_FAIL=ancestor
rmrun "$A" --yes; rc=$?
unset FAKE_PS_FAIL
ok "rm refuses when docker cannot list the containers running its image" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: docker could not list the running containers" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
world; A="$W/alpha"; mkdir -p "$A/.ai-containers"; printf '%s\n' "$A" > "$ENG/projects.conf"
export FAKE_PS_FAIL=1
rmrun "$A" --yes; rc=$?
unset FAKE_PS_FAIL
ok "rm refuses when docker cannot list the running containers, for a project with no settings too" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: docker could not list the running containers" "$2" && [ -d "$3/.ai-containers" ]' \
  _ "$rc" "$TMP/out" "$A"
# a container launched while the question was asked: the first check makes two
# `ps` calls (mounts, then the image), the one after the question sees it
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
printf 'ctr-late|img-alpha|%s/.ai-containers/.agent-blocked\n' "$A" > "$FAKE_RUNNING.later"
export FAKE_RUNNING_AFTER=2
rmrun "$A" --yes; rc=$?
unset FAKE_RUNNING_AFTER
ok "rm checks again after the question, and refuses a container started meanwhile" \
  bash -c '[ "$1" = 1 ] && grep -q "About to remove" "$2" && grep -q "ERROR.*started after the listing.*ctr-late" "$2"' _ "$rc" "$TMP/out"
ok "  … and changes nothing" unchanged "$A" "$ida"
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'
export FAKE_DOCKER_DOWN=1
rmrun "$A" --yes; rc=$?
unset FAKE_DOCKER_DOWN
ok "rm refuses when docker cannot be reached, and changes nothing" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR" "$2" && [ -d "$3/.ai-containers" ] && grep -qxF "$3" "$4"' \
  _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf"

# groups and repos no other registered project uses are named, never removed
world
mkproj "$W/a1" $'AI_CONTAINER_GROUP=lonely\n' $'REPOS="solo:ro shared:rw"\nSPECS_PATH=@specsolo\n'
mkproj "$W/a2" $'AI_CONTAINER_GROUP=team\n' $'SPECS_PATH=@specshared\n'
mkproj "$W/a3" ''
mkproj "$W/b" $'AI_CONTAINER_GROUP=team\n' $'REPOS=shared:rwcopy\nDOCS_PATH=@specshared:ro\n'
mkdir -p "$W/gone"; printf '%s\n' "$W/gone" >> "$ENG/projects.conf"   # its .ai-containers deleted by hand
rmrun "$W/a1" --yes; cp "$TMP/out" "$TMP/out1"
ok "rm names an unused group with ./group.sh rm, as unused by this checkout's projects.conf" \
  hasx "NOTE: group lonely is used by no other project in this checkout's projects.conf; remove it with ./group.sh rm lonely"
ok "rm names an unused REPOS repo with ./repo.sh rm" \
  hasx "NOTE: repo solo is used by no other project in this checkout's projects.conf; remove it with ./repo.sh rm solo"
ok "rm does not name a REPOS repo another project uses" lacks "NOTE: repo shared "
ok "rm names an unused SPECS_PATH=@name repo with ./repo.sh rm" \
  hasx "NOTE: repo specsolo is used by no other project in this checkout's projects.conf; remove it with ./repo.sh rm specsolo"
rmrun "$W/a2" --yes
ok "rm does not name a group another project uses" lacks "NOTE: group team "
ok "rm does not name a SPECS_PATH=@name repo another project uses" lacks "NOTE: repo specshared "
rmrun "$W/a3" --yes
ok "rm does not count a registered project whose .ai-containers is gone as using a group" \
  hasx "NOTE: group default is used by no other project in this checkout's projects.conf; it is the"
ok "  … and never suggests removing the default group, which every launch naming none uses" \
  bash -c 'grep -qxF "      group of every launch that names none, so keep it." "$1" && ! grep -qF "group.sh rm default" "$1"' _ "$TMP/out"
ok "rm names nothing shared for a project that set nothing but the group" \
  bash -c '[ "$(grep -c "^NOTE: " "$1")" = 1 ]' _ "$TMP/out"

# the root it leaves
world
mkproj "$W/empty-after"; mkproj "$W/with-files"; printf 'hi\n' > "$W/with-files/README"
rmrun "$W/empty-after" --yes; rc1=$?
ok "rm removes the project root when it is left empty" bash -c '[ "$1" = 0 ] && [ ! -e "$2" ]' _ "$rc1" "$W/empty-after"
ok "  … and lists it first" hasx "  directory   $W/empty-after (it holds nothing else)"
rmrun "$W/with-files" --yes; rc2=$?
ok "rm keeps a root with other files" \
  bash -c '[ "$1" = 0 ] && [ "$(ls -A "$2")" = README ]' _ "$rc2" "$W/with-files"
ok "  … and does not list it" lacks "  directory   $W/with-files (it holds nothing else)"

# asking for an id makes no key
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
mv "$HOME/.ai-containers/project-id.key" "$TMP/key.saved"
rmrun "$A" --yes; rc=$?
ok "rm makes no project-id.key where there was none, and keeps the image it cannot tie to this project" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && [ -e "$3" ]' _ "$rc" "$HOME/.ai-containers/project-id.key" "$IMGS/img-alpha"
rm -f "$HOME/.ai-containers/project-id.key"; mv "$TMP/key.saved" "$HOME/.ai-containers/project-id.key"

# what it refuses to follow or touch
world
mkdir -p "$W/target-dir" "$W/linky"; printf 'keep\n' > "$W/target-dir/sandbox.env"
ln -s "$W/target-dir" "$W/linky/.ai-containers"; printf '%s\n' "$W/linky" >> "$ENG/projects.conf"
mkbase app; mkwc app 1 "$W/linky/.ai-containers" "$CLEAN"
rmrun "$W/linky" --yes; rc=$?
ok "rm refuses a .ai-containers that is a symlink, and the link's target is untouched" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ -L "$3/.ai-containers" ] && [ "$(cat "$4/sandbox.env")" = keep ] \
           && grep -qxF "$3" "$5" && ! grep -q "^docker volume rm" "$6"' \
  _ "$rc" "$TMP/out" "$W/linky" "$W/target-dir" "$ENG/projects.conf" "$DOCKER_LOG"
ok "  … before anything is listed or removed" lacks "About to remove"

# the same directory registered under another spelling is this project, not one inside it
world
A="$W/alpha"; mkproj "$A"; ln -s . "$A/self"; printf '%s\n' "$A/self" >> "$ENG/projects.conf"; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"
rmrun "$A" --yes; rc=$?
ok "rm takes the same directory registered under another spelling as this project, not a nested one" \
  bash -c '[ "$1" = 0 ] && [ "$(sed -n "s/^docker volume rm //p" "$2")" = ai-containers-repo-app--wc-1 ]' _ "$rc" "$DOCKER_LOG"
ok "  … and does not count that spelling as another project using its group" \
  hasx "NOTE: group default is used by no other project in this checkout's projects.conf; it is the"

# an image that cannot be removed keeps the record that names it
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
export FAKE_FAIL_RMI=1
rmrun "$A" --yes; rc=$?
unset FAKE_FAIL_RMI
ok "rm keeps the image-projects.conf line while the image it could not remove carries the id, and finishes the rest" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && ! grep -qxF "$5" "$6" && [ ! -e "$5/.ai-containers" ]' \
  _ "$rc" "$IMGS/img-alpha" "$ida" "$IP" "$A" "$ENG/projects.conf"
ok "  … and says what docker said" has_line "NOTE: could not remove the image img-alpha (docker said: Error: conflict: the image is used by a stopped container)"

# the listing's decision on the image holds: one it said it keeps is not removed,
# though its label has become this project's by the time of removal
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
mv "$IMGS/img-alpha" "$IMGS/img-alpha.next"; printf 'org.opencontainers.image.title=Other\n' > "$IMGS/img-alpha"
rmrun "$A" --yes; rc=$?
ok "rm never removes an image the listing said it keeps" \
  bash -c '[ "$1" = 0 ] && grep -qF "  image       img-alpha — kept: " "$2" && ! grep -q "^docker rmi" "$3" && [ -e "$4" ]' \
  _ "$rc" "$TMP/out" "$DOCKER_LOG" "$IMGS/img-alpha"

world
printf '/\n' > "$ENG/projects.conf"
if [[ -e /.ai-containers ]]; then
  printf 'SKIP: a registered root of / (this machine has a /.ai-containers)\n'
else
  rmrun / --yes; rc=$?
  ok "rm refuses a registered root of / and changes nothing" \
    bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3")" = / ]' _ "$rc" "$TMP/out" "$ENG/projects.conf"
fi
world
mkdir -p "$W/cwd/relproj/.ai-containers"; printf 'relproj\n' > "$ENG/projects.conf"
( cd "$W/cwd" && bash "$P" rm relproj --yes ) > "$TMP/out" 2>&1 < /dev/null; rc=$?
ok "rm refuses a registered root that is not absolute and changes nothing" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ -d "$3/relproj/.ai-containers" ] && [ "$(cat "$4")" = relproj ]' \
  _ "$rc" "$TMP/out" "$W/cwd" "$ENG/projects.conf"

world
S="$W/my proj"; mkproj "$S" $'IMAGE_NAME=img-space\n'; built "$S" img-space; mkbase app
mkwc app 1 "$S/.ai-containers" "$CLEAN"
rmrun "$S" --yes; rc=$?
ok "rm works on a project whose path has a space" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && ! grep -qF "$2" "$3" && [ ! -e "$4" ] && [ ! -e "$5/ai-containers-repo-app--wc-1" ] && [ ! -s "$6" ]' \
  _ "$rc" "$S" "$ENG/projects.conf" "$IMGS/img-space" "$VOLS" "$IP"

# a failure part-way leaves what a re-run needs to finish
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"; ida="$(tid "$A/.ai-containers")"
export FAKE_FAIL_VOLUME_RM='*'
rmrun "$A" --yes; rc=$?
unset FAKE_FAIL_VOLUME_RM
ok "rm keeps the projects.conf line when a working copy cannot be removed" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && grep -qxF "$3" "$4" && [ -d "$3/.ai-containers" ] && [ -e "$5" ] \
           && ! grep -q "^docker rmi" "$6"' _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$IMGS/img-alpha" "$DOCKER_LOG"
rmrun "$A" --yes; rc=$?
ok "  … and a re-run with the volume removable completes" \
  bash -c '[ "$1" = 0 ] && ! grep -qxF "$2" "$3" && [ ! -e "$2" ] && [ ! -d "$4/ai-containers-repo-app--wc-1" ] && ! grep -qF "$5" "$6"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$VOLS" "$ida" "$IP"

if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: an .ai-containers that cannot be removed (running as root)\n'
else
  world
  A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
  mkdir -p "$A/.ai-containers/stuck"; printf 'x\n' > "$A/.ai-containers/stuck/file"; chmod 555 "$A/.ai-containers/stuck"
  rmrun "$A" --yes; rc=$?
  ok "rm keeps both registry lines when .ai-containers cannot be removed" \
    bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && grep -qxF "$3" "$4" && grep -qF "$5" "$6"' \
    _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$ida" "$IP"
  chmod 755 "$A/.ai-containers/stuck"
fi

world
A="$W/alpha"; mkdir -p "$A/.ai-containers"
printf '# comment\n\n%s\r\n/b/two words\n/c/three' "$A" > "$ENG/projects.conf"
rmrun "$A" --yes; rc=$?
printf '# comment\n\n/b/two words\n/c/three' > "$TMP/expect"
ok "rm keeps every other projects.conf byte" bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$ENG/projects.conf" "$TMP/expect"

# a project whose .ai-containers was already deleted by hand
world
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"; ida="$(tid "$A/.ai-containers")"
rm -f "$IMGS/img-alpha"; rm -rf "$A/.ai-containers"; printf 'hi\n' > "$A/README"
rmrun "$A" --yes; rc=$?
ok "rm finishes a project whose .ai-containers is already gone" \
  bash -c '[ "$1" = 0 ] && ! grep -qxF "$2" "$3" && ! grep -qF "$4" "$5" && [ ! -d "$6/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "  image       (unknown — no sandbox.env; ./project.sh gc removes the image image-projects.conf" "$7"' \
  _ "$rc" "$A" "$ENG/projects.conf" "$ida" "$IP" "$VOLS" "$TMP/out"

# what the agent can write reaches the terminal without its escapes
ESC=$'\e'
world
mkproj "$W/a1" "AI_CONTAINER_GROUP=${ESC}[31mred"$'\n'
rmrun "$W/a1" --yes; rc=$?
ok "rm prints an AI_CONTAINER_GROUP holding an ESC byte without it" \
  bash -c '[ "$1" = 0 ] && grep -q "^NOTE: group ?\[31mred " "$2" && ! grep -q "$3" "$2"' _ "$rc" "$TMP/out" "$ESC"
world
mkproj "$W/x/dup${ESC}[2Jn"; mkproj "$W/y/dup${ESC}[2Jn"
rmrun "dup${ESC}[2Jn" --yes; rc=$?
ok "rm names the projects sharing a basename without their ESC bytes" \
  bash -c '[ "$1" = 1 ] && grep -q "is the name of 2 registered projects" "$2" && ! grep -q "$3" "$2"' _ "$rc" "$TMP/out" "$ESC"
rmrun "$W/nope${ESC}[2Jx" --yes; rc=$?
ok "rm names an unregistered project and the registered ones without their ESC bytes" \
  bash -c '[ "$1" = 1 ] && grep -q "is not a registered project" "$2" && grep -q "dup?\[2Jn" "$2" && ! grep -q "$3" "$2"' \
  _ "$rc" "$TMP/out" "$ESC"
world
E="$W/esc${ESC}[2Jdir"; mkproj "$E"
rmrun "$E" --yes; rc=$?
ok "rm prints a registered root holding an ESC byte without it" \
  bash -c '[ "$1" = 0 ] && grep -q "About to remove" "$2" && ! grep -q "$3" "$2" && [ ! -e "$4" ]' _ "$rc" "$TMP/out" "$ESC" "$E"

# never ~/.ai-containers, which holds every group, the id key and the registries,
# nor the engine itself
world
mkdir -p "$HOME/.ai-containers/default/.claude"
printf '%s\n' "$HOME" > "$ENG/projects.conf"
rmrun "$HOME" --yes; rc=$?
ok "rm refuses a project registered at \$HOME, and ~/.ai-containers is untouched" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ -f "$3/project-id.key" ] && [ -d "$3/default/.claude" ] \
           && [ "$(cat "$4")" = "$5" ]' _ "$rc" "$TMP/out" "$HOME/.ai-containers" "$ENG/projects.conf" "$HOME"
world
ln -s "$HOME" "$W/homelink"; printf '%s\n' "$W/homelink" > "$ENG/projects.conf"
rmrun "$W/homelink" --yes; rc=$?
ok "rm refuses a project whose root is a symlink to \$HOME" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ -f "$3/project-id.key" ] && [ -d "$3/default/.claude" ]' \
  _ "$rc" "$TMP/out" "$HOME/.ai-containers"
world
mkdir -p "$W/eroot/.ai-containers"; cp -a "$ENG" "$W/eroot/.ai-containers/base"
printf '%s\n' "$W/eroot" > "$W/eroot/.ai-containers/base/projects.conf"
( cd "$TMP" && bash "$W/eroot/.ai-containers/base/project.sh" rm "$W/eroot" --yes ) > "$TMP/out" 2>&1 < /dev/null; rc=$?
ok "rm refuses a project whose .ai-containers holds the engine it runs from" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*holds this engine" "$2" && [ -f "$3/project.sh" ]' \
  _ "$rc" "$TMP/out" "$W/eroot/.ai-containers/base"
# compared per path component: ~/.ai-containers-old is not ~/.ai-containers
world
O="$HOME/.ai-containers-old/proj"; mkproj "$O"
rmrun "$O" --yes; rc=$?
ok "rm removes a project under ~/.ai-containers-old, which only starts like ~/.ai-containers" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && [ -f "$3/project-id.key" ]' _ "$rc" "$O" "$HOME/.ai-containers"
rm -rf "$HOME/.ai-containers-old" "$HOME/.ai-containers/default"

# a copy another home made on a shared daemon — the same user name in another
# WSL distro gives the same paths — is not this project's to remove
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkwc app 1 "$A/.ai-containers" "$CLEAN"
WC_OWNER="sha256:$(printf '%064d' 9)" mkwc app 2 "$A/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 3 "$A/.ai-containers" "$CLEAN"
rmrun "$A" --yes; rc=$?
ok "rm keeps a working copy another home made, launched from the same path, and removes this home's and an unlabelled one" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && [ ! -d "$2/ai-containers-repo-app--wc-1" ] && [ ! -d "$2/ai-containers-repo-app--wc-3" ] \
           && ! grep -qxF "docker volume rm ai-containers-repo-app--wc-2" "$3"' _ "$rc" "$VOLS" "$DOCKER_LOG"
ok "  … naming it as kept" \
  hasx "  working copy ai-containers-repo-app--wc-2 (app, launched from $A/.ai-containers) — kept: made by another home or user on this docker"

# a copy launched from a directory in the project that holds a launcher of its
# own is that (unregistered) project's
world; A="$W/alpha"; mkproj "$A"; mkbase app
mkdir -p "$A/sub/.ai-containers"; : > "$A/sub/.ai-containers/sandbox.sh"; : > "$A/sub/.ai-containers/sandbox-common.sh"
mkwc app 1 "$A/.ai-containers" "$CLEAN"; mkwc app 2 "$A/sub/.ai-containers" "$CLEAN"; mkwc app 3 "$A/sub" "$CLEAN"
rmrun "$A" --yes; rc=$?
ok "rm keeps a working copy launched from a directory in the project that holds a launcher of its own" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && [ ! -d "$2/ai-containers-repo-app--wc-1" ] && [ ! -d "$2/ai-containers-repo-app--wc-3" ]' \
  _ "$rc" "$VOLS"
ok "  … naming it as kept, with where it was launched from" \
  hasx "  working copy ai-containers-repo-app--wc-2 (app, launched from $A/sub/.ai-containers) — kept: launched from $A/sub/.ai-containers, which holds a launcher of its own"

# a project whose own sandbox.local.env names its repo volumes under another
# REPO_VOLUME_PREFIX: rm would see other copies than its launcher makes
world; A="$W/alpha"; mkproj "$A" '' $'REPO_VOLUME_PREFIX=other\n'
mkvol other-repo-app "ai-containers.repo=app" "ai-containers.type=git" "ai-containers.source=https://example.invalid/app.git"
mkvol other-repo-app--wc-1 "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$A/.ai-containers" "ai-containers.owner=$OWN"
printf '%s' "$CLEAN" > "$VOLS/other-repo-app--wc-1/inspect"
rmrun "$A" --yes; rc=$?
ok "rm refuses a project whose sandbox.local.env sets another REPO_VOLUME_PREFIX, saying how to run it" \
  bash -c '[ "$1" = 1 ] && grep -qF "names its repo volumes under REPO_VOLUME_PREFIX=other (from its sandbox.local.env)" "$2" \
           && grep -qxF "         REPO_VOLUME_PREFIX=other ./project.sh rm $3" "$2" \
           && [ -d "$3/.ai-containers" ] && grep -qxF "$3" "$4" && ! grep -q "^docker volume rm" "$5"' \
  _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$DOCKER_LOG"
( export REPO_VOLUME_PREFIX=other; rmrun "$A" --yes ); rc=$?
ok "  … and run so, removes the copies under that prefix" \
  bash -c '[ "$1" = 0 ] && [ ! -d "$2/other-repo-app--wc-1" ] && [ ! -e "$3/.ai-containers" ]' _ "$rc" "$VOLS" "$A"

# a project whose root may be on a drive that is not mounted: rm names why, and
# what to do if it was moved, and goes on when told to
world; mkdir -p "$W/other" "$W/drive"; D="$W/drive/proj"; printf '%s\n' "$D" > "$ENG/projects.conf"
rmrun "$D" --yes; rc=$?
ok "rm lists a project whose root may be on an unmounted drive with why, and the mv way out, then removes its line" \
  bash -c '[ "$1" = 0 ] && grep -qxF "  directory   $2/.ai-containers (not there: it may be on a drive that is not mounted: $3 is empty)" "$4" \
           && grep -qxF "              If $2 was moved rather than deleted, answer no and run ./project.sh mv $2 <new-dir>:" "$4" \
           && grep -qxF "              rm would remove its working copies, which mv carries to the new place." "$4" && ! grep -qxF "$2" "$5"' \
  _ "$rc" "$D" "$W/drive" "$TMP/out" "$ENG/projects.conf"
ok "  … and does not list the root, which is not there, as left empty" lacks "  directory   $D (it holds nothing else)"
# with no settings and no image-projects.conf line, the image is found by its id only
world; A="$W/alpha"; mkdir -p "$A/.ai-containers"; printf '%s\n' "$A" > "$ENG/projects.conf"; ida="$(tid "$A/.ai-containers")"
rmrun "$A" --yes; rc=$?
ok "rm says how to find the image of a project with no settings that no image-projects.conf line names" \
  bash -c '[ "$1" = 0 ] && grep -qxF "              is listed by docker images --filter label=ai-containers.project=$2)" "$3" \
           && ! grep -qF "./project.sh gc removes the image" "$3"' _ "$rc" "$ida" "$TMP/out"
ok "  … and lists no image-projects.conf line, nor says it removed one" \
  bash -c '! grep -qF "image-projects.conf, once" "$1" && ! grep -qF "from image-projects.conf." "$1"' _ "$TMP/out"


world; S="$W/my proj"; mkproj "$S" '' $'REPO_VOLUME_PREFIX=other\n'
rmrun "$S" --yes
ok "the REPO_VOLUME_PREFIX refusal's command keeps a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ]' _ "$(cmd_word "REPO_VOLUME_PREFIX=other ./project.sh rm" "" "" 4)" "$S"
world; S="$W/my proj"; mkproj "$S"; mkbase app; mkwc app 1 "$S/.ai-containers" "$CLEAN"
export FAKE_FAIL_VOLUME_RM='*'
rmrun "$S" --yes
unset FAKE_FAIL_VOLUME_RM
ok "rm's run-it-again command keeps a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ]' _ "$(cmd_word "again once it can be" "run " " again" 3)" "$S"
world; S="$W/my proj"; mkproj "$S"; rm -rf "$S/.ai-containers"
rmrun "$S"
ok "rm's mv hint keeps a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ]' _ "$(cmd_word "answer no and run ./project.sh mv" "and run " " <new-dir>" 3)" "$S"
world; mkproj "$W/a1" '' $'AI_CONTAINER_GROUP=my group\n'
rmrun "$W/a1" --yes
ok "rm's ./group.sh rm keeps a group name with a space as one argument" \
  bash -c '[ "$1" = "my group" ]' _ "$(cmd_word "remove it with ./group.sh rm" "remove it with " "" 3)"

# what it refuses on the command line, by its exit status
world; A="$W/alpha"; mkproj "$A"
rm_refused() {  # <what> <rm's arguments…>
  rmrun "${@:2}"; local rc=$?
  ok "rm $1 exits 1, saying why, and removes nothing" \
    bash -c '[ "$1" = 1 ] && grep -q "^ERROR: " "$2" && [ -d "$3/.ai-containers" ] && ! grep -q "About to remove" "$2"' _ "$rc" "$TMP/out" "$A"
}
rm_refused "with an unknown flag" "$A" --bogus
rm_refused "with a second project" "$A" "$W/other"
rm_refused "with no project"

# What only a change made while rm runs reaches: $TMP/hook holds a docker that,
# before a `volume rm`, runs HOOK_VOLRM (the change), then hands the call to the
# fake; and an rm that, asked to remove RM_KEEP, reports success and leaves a
# directory there (a launch that made it again).
mkdir -p "$TMP/hook"
cat > "$TMP/hook/docker" <<'HOOK'
#!/usr/bin/env bash
if [[ "$1 ${2-}" == "volume rm" && -n "${HOOK_VOLRM:-}" ]]; then bash -c "$HOOK_VOLRM"; fi
exec "$(dirname "$0")/../bin/docker" "$@"
HOOK
{ printf '#!/usr/bin/env bash\n'
  printf 'if [[ -n "${RM_KEEP:-}" && "$*" == "-rf -- $RM_KEEP" ]]; then %q "$@"; mkdir -p "$RM_KEEP"; exit 0; fi\n' "$(command -v rm)"
  printf 'exec %q "$@"\n' "$(command -v rm)"; } > "$TMP/hook/rm"
chmod +x "$TMP/hook/docker" "$TMP/hook/rm"
world; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
( export PATH="$TMP/hook:$PATH" HOOK_VOLRM="mv '$A/.ai-containers' '$A/moved' && ln -s '$A/moved' '$A/.ai-containers'"
  rmrun "$A" --yes ); rc=$?
ok "rm stops, exit 1, at an .ai-containers that became a link after the listing, keeping both registry lines" \
  bash -c '[ "$1" = 1 ] && grep -qF "has become a link since it was checked" "$2" && [ -L "$3/.ai-containers" ] && [ -f "$3/moved/sandbox.env" ] \
           && grep -qxF "$3" "$4" && grep -qF "$5" "$6"' _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$ida" "$IP"
world; A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"; printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" > "$IP"
( export PATH="$TMP/hook:$PATH" RM_KEEP="$A/.ai-containers"; rmrun "$A" --yes ); rc=$?
ok "rm stops, exit 1, when .ai-containers is still there after rm -rf said it removed it, keeping both registry lines" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: could not remove $3/.ai-containers" "$2" && grep -qxF "$3" "$4" && grep -qF "$5" "$6" \
           && ! grep -qF "Removed $3/.ai-containers." "$2"' _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$ida" "$IP"
# the root goes only if the listing said so: one emptied while rm ran stays
world; A="$W/alpha"; mkproj "$A"; printf 'hi\n' > "$A/README"; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
( export PATH="$TMP/hook:$PATH" HOOK_VOLRM="rm -f '$A/README'"; rmrun "$A" --yes ); rc=$?
ok "rm keeps a root it did not list as left empty, though it is empty by the end" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/README" ] && [ -d "$2" ] && ! grep -qF "Removed the empty directory" "$3"' _ "$rc" "$A" "$TMP/out"

# a registry it cannot rewrite stops it, exit 1, before the lines a re-run needs
fake_mktemp
world; A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"; printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" > "$IP"
( export FAKE_MKTEMP_BAD='.image-projects.conf.new.*' FAKE_MKTEMP_HOW=dir; rmrun "$A" --yes ); rc=$?
rm -rf "$HOME/.ai-containers"/.image-projects.conf.new.*
ok "rm exits 1 when its image-projects.conf line cannot be dropped, keeping the projects.conf line" \
  bash -c '[ "$1" = 1 ] && grep -qxF "       The projects.conf line is kept; run ./project.sh rm $3 again." "$2" && grep -qxF "$3" "$4" \
           && grep -qF "$5" "$6" && ! grep -q "^OK:" "$2"' _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf" "$ida" "$IP"
world; A="$W/alpha"; mkproj "$A"
( export FAKE_MKTEMP_BAD='.projects.conf.new.*' FAKE_MKTEMP_HOW=dir; rmrun "$A" --yes ); rc=$?
rm -rf "$ENG"/.projects.conf.new.*
ok "rm exits 1 when its projects.conf line cannot be dropped" \
  bash -c '[ "$1" = 1 ] && grep -qxF "$3" "$4" && ! grep -q "^OK:" "$2" && ! grep -qF "from projects.conf." "$2"' \
  _ "$rc" "$TMP/out" "$A" "$ENG/projects.conf"
rm -f "$TMP/bin/mktemp"

echo
# shellcheck disable=SC2154  # fails is the counter tests/lib-project-tool.sh defines
[[ "$fails" == 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILED"; exit 1; }
