#!/usr/bin/env bash
# shellcheck disable=SC1090  # project.sh is sourced from a computed path, on purpose
# project.sh: `mv` — moving a setup with its working copies and records.
# Hermetic: HOME and an engine copy live in a temp dir; docker is a logging fake
# (tests/lib-project-tool.sh, shared with the other tests/test-project-*.sh).
# shellcheck source=tests/lib-project-tool.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-project-tool.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-project-tool.sh\n'; exit 1; }
# The engine copy's project.sh, named in this file so tests/falsify/derive-targets.sh,
# which reads each file's own assignments, sees that this test runs it.
P="$ENG/project.sh"

# ── mv ──
# mv takes emit_env_list from project-init.sh, which the dispatch tests replaced
# with a stub: the real one again.
cp -p "$REPO_DIR/project-init.sh" "$ENG/project-init.sh"
# cp, which FAKE_CP_CORRUPT=<file> makes change that file of a copy it makes to
# a directory named .ai-containers: the copy a move across filesystems makes is
# then not the original, though it holds the same names. FAKE_CP_TERM: see below.
REAL_CP="$(command -v cp)"; export REAL_CP
cat > "$TMP/bin/cp" <<'FAKECP'
#!/usr/bin/env bash
"$REAL_CP" "$@" || exit
last="${!#}"
if [[ -n "${FAKE_CP_CORRUPT:-}" && "${last##*/}" == .ai-containers && -f "$last/$FAKE_CP_CORRUPT" ]]; then
  printf 'x\n' >> "$last/$FAKE_CP_CORRUPT"
fi
# FAKE_CP_TERM: once that copy is made, the one who ran cp is sent TERM
if [[ -n "${FAKE_CP_TERM:-}" && "${last##*/}" == .ai-containers ]]; then kill -TERM "$PPID"; fi
exit 0
FAKECP
chmod +x "$TMP/bin/cp"
# mv, which FAKE_MV_PLANT=<path> makes put something at <path> just before it
# moves anything there — a directory holding a file, or with FAKE_MV_PLANT_TO=<dir>
# a link to <dir> — as a process racing the move would.
REAL_MV="$(command -v mv)"; export REAL_MV
cat > "$TMP/bin/mv" <<'FAKEMV'
#!/usr/bin/env bash
last="${!#}"
if [[ -n "${FAKE_MV_PLANT:-}" && "$last" == "$FAKE_MV_PLANT" && ! -e "$last" && ! -L "$last" ]]; then
  if [[ -n "${FAKE_MV_PLANT_TO:-}" ]]; then ln -s "$FAKE_MV_PLANT_TO" "$last"
  else mkdir "$last" && printf 'planted\n' > "$last/planted"; fi
fi
# FAKE_MV_TERM=<dest>: a TERM to whoever moves something to <dest>, before the
# move (nothing moved); FAKE_MV_TERM_AFTER=<dest>: right after it (PRJ-12).
if [[ -n "${FAKE_MV_TERM:-}" && "$last" == "$FAKE_MV_TERM" ]]; then kill -TERM "$PPID"; sleep 0.2; exit 1; fi
if [[ -n "${FAKE_MV_TERM_AFTER:-}" && "$last" == "$FAKE_MV_TERM_AFTER" ]]; then
  "$REAL_MV" "$@"; rc=$?; kill -TERM "$PPID"; exit "$rc"
fi
exec "$REAL_MV" "$@"
FAKEMV
chmod +x "$TMP/bin/mv"
# mvbsd: mv as on a mv without -T (BSD's), where only the check after the move
# stands between a planted directory and the setup moving into it. hash -r: this
# shell found the real mv before the fake one existed.
mvbsd() { ( hash -r && cd "$TMP" && source "$P" && _prj_mv_T=0 && cmd_mv "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
# wcname <repo> <launch dir>: the working copy a launch from there uses
wcname() { ( source "$P" && repo_workcopy_volume_name "$1" "$(workcopy_tag "$2")" ); }
wcwork() { cat "$VOLS/$1/data/work" 2>/dev/null; }
# moved_nothing <root> <projects.conf as it was>: no volume made or removed, no
# copy run (a read-only check may be), no image removed, the registry as it was
moved_nothing() {
  [[ -d "$1/.ai-containers" ]] && cmp -s "$ENG/projects.conf" "$2" && ! logged '^docker (volume (rm|create)|rmi)' \
    && [[ -z "$(grep '^docker run' "$DOCKER_LOG" | grep -v -- '--dry-run')" ]]
}
# mvproj <root> [<sandbox.env text>] [<sandbox.local.env text>]: a registered
# project in a directory that holds more than its setup, with one working copy of
# app holding work; the registry saved to $TMP/conf.before
mvproj() {
  mkproj "$@"; printf 'hi\n' > "$1/README"; mkbase app
  mkwc app 1 "$1/.ai-containers"; wcdata ai-containers-repo-app--wc-1 unpushed
  cp "$ENG/projects.conf" "$TMP/conf.before"
}
OLDWC=ai-containers-repo-app--wc-1
# WL: the test's directory through a link, for a path git and cd spell apart
# from its physical one
WL="$TMP/wl"; ln -s "$W" "$WL"

world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'
mkdir -p "$A/.ai-containers/.agent-blocked"; printf 'log\n' > "$A/.ai-containers/.agent-blocked/blocked.log"
printf '# head\n/x/before\n%s\n/x/after' "$A" > "$ENG/projects.conf"
N="$W/new/place/alpha2"
mvrun "$A" "$N" --yes; rc=$?
printf '# head\n/x/before\n%s\n/x/after' "$N" > "$TMP/expect"
ok "mv moves .ai-containers to <new-dir>, creating it, and rewrites the projects.conf line in place" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && [ "$(cat "$3/.ai-containers/sandbox.env")" = IMAGE_NAME=img-alpha ] \
           && [ "$(cat "$3/.ai-containers/.agent-blocked/blocked.log")" = log ] && cmp -s "$4" "$5" && [ -f "$2/README" ]' \
  _ "$rc" "$A" "$N" "$ENG/projects.conf" "$TMP/expect"
ok "  … adds the old root to a sandbox.local.env it creates" \
  bash -c '[ "$(cat "$1")" = "EXTRA_MOUNTS=\"$2\"" ]' _ "$N/.ai-containers/sandbox.local.env" "$A"
ok "  … and says nothing of a repository tracking .ai-containers where none does" lacks "repository tracks"
ok "  … printing what it does first, with --yes too" \
  bash -c 'grep -qxF "About to move project $1 to $2:" "$3" && grep -qxF "  directory   $1/.ai-containers → $2/.ai-containers" "$3"' \
  _ "$A" "$N" "$TMP/out"
ok "  … listing the projects.conf line as rewritten, and no image-projects.conf line where none names it" \
  bash -c 'grep -qxF "  registry    $1 → $2 (projects.conf, the line rewritten)" "$3" && ! grep -qF "image-projects.conf" "$3"' \
  _ "$A" "$N" "$TMP/out"
ok "  … saying what it added, and warning of nothing" \
  bash -c 'grep -qxF "Added $1 to EXTRA_MOUNTS in $2/.ai-containers/sandbox.local.env." "$3" && ! grep -qF "WARNING:" "$3" \
           && ! grep -qF "was not removed" "$3"' _ "$A" "$N" "$TMP/out"

world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkwc app 3 "$A/sub"
mvrun "$A" "$N" --yes; rc=$?
ok "mv copies each working copy to the new launch dir's volume name and label, then removes the old" \
  bash -c '[ "$1" = 0 ] && [ -n "$3" ] && [ ! -d "$2/$5" ] && [ "$(cat "$2/$3/data/work")" = unpushed ] \
           && grep -qxF "ai-containers.workcopy=1" "$2/$3/labels" && grep -qxF "ai-containers.repo=app" "$2/$3/labels" \
           && grep -qxF "ai-containers.launch-dir=$4/.ai-containers" "$2/$3/labels"' _ "$rc" "$VOLS" "$nv" "$N" "$OLDWC"
ok "  … removing the old one only after the copy's check" \
  bash -c 'c="$(grep -n -- "--dry-run" "$1" | head -1 | cut -d: -f1)"; r="$(grep -nxF "docker volume rm $2" "$1" | cut -d: -f1)"
           [ -n "$c" ] && [ -n "$r" ] && [ "$c" -lt "$r" ]' _ "$DOCKER_LOG" "$OLDWC"
ok "  … and lists it first" hasx "  working copy $OLDWC (app) → $nv"
ok "  … leaving one launched from elsewhere in the old root, which stays where it is" \
  bash -c 'grep -qxF "  working copy ai-containers-repo-app--wc-3 (app) — stays: launched from $1/sub, which does not move" "$2" \
           && grep -qxF "ai-containers.launch-dir=$1/sub" "$3/ai-containers-repo-app--wc-3/labels"' _ "$A" "$TMP/out" "$VOLS"

world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
export FAKE_COPY_BAD=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_COPY_BAD
ok "mv keeps the old working copy and directory when a copy's check finds a difference" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3/$9/data/work")" = unpushed ] && [ ! -e "$3/$4" ] \
           && [ -d "$5/.ai-containers" ] && [ ! -e "$6/.ai-containers" ] && cmp -s "$7" "$8"' \
  _ "$rc" "$TMP/out" "$VOLS" "$nv" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before" "$OLDWC"
ok "  … and nothing else" bash -c '[ -e "$1" ] && ! grep -q "^docker rmi" "$2"' _ "$IMGS/img-alpha" "$DOCKER_LOG"

world
A="$W/alpha"; mvproj "$A" '' $'# mine\nEXTRA_MOUNTS="/x/one:ro /x/two"\nREPOS=lib:ro\n'
N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
printf '# mine\nEXTRA_MOUNTS="\n  /x/one:ro\n  /x/two\n  %s\n"\nREPOS=lib:ro\n' "$A" > "$TMP/expect"
ok "mv adds the old root to EXTRA_MOUNTS, one entry per line, keeping existing entries" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"
world
A="$W/alpha"; mvproj "$A" '' $'export EXTRA_MOUNTS="\n  /x/one\n\n  /x/two\n"\nPREVIEW_PORTS=3000\n'
N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
printf 'export EXTRA_MOUNTS="\n  /x/one\n  /x/two\n  %s\n"\nPREVIEW_PORTS=3000\n' "$A" > "$TMP/expect"
ok "mv replaces an EXTRA_MOUNTS written over several lines whole, its export kept" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"

world
A="$W/alpha"; mvproj "$A" '' "EXTRA_MOUNTS=\"/x/one $W:z\""$'\n'
cp "$A/.ai-containers/sandbox.local.env" "$TMP/expect"
N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
ok "mv adds nothing when an entry already covers the old root" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"
ok "  … and says which" hasx "  EXTRA_MOUNTS $A is already covered by $W:z"

world
A="$W/setup/alpha"; mkproj "$A"; N="$W/dev/alpha"
mvrun "$A" "$N" --yes; rc=$?
ok "mv removes an old root it leaves empty, and adds nothing to EXTRA_MOUNTS" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && [ -d "$3/setup" ] && [ -f "$4/.ai-containers/sandbox.env" ] \
           && [ ! -e "$4/.ai-containers/sandbox.local.env" ]' _ "$rc" "$A" "$W" "$N"
ok "  … listing it first" hasx "  directory   $A (it holds nothing else once .ai-containers is moved)"
ok "  … and says nothing of working copies left to carry, for a registered project" lacks "is left to carry"

# a name the launcher would mount twice
clash() {  # <sandbox.local.env text> <new-dir> <what the error names> <assertion>
  world
  A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n' "$1"; built "$A" img-alpha
  : > "$DOCKER_LOG"
  mvrun "$A" "$2" --yes; rc=$?
  ok "$4" bash -c '[ "$1" = 1 ] && grep -qF "ERROR: " "$2" && grep -qF -- "$3" "$2" && [ ! -e "$4" ]' _ "$rc" "$TMP/out" "$3" "$2"
  ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
}
clash '' "$W/elsewhere/alpha" "/workspace/alpha" "mv refuses a <new-dir> with the old root's basename, changing nothing"
clash $'EXTRA_MOUNTS="/x/gamma:ro"\n' "$W/new/gamma" "/workspace/gamma" "mv refuses a <new-dir> with an EXTRA_MOUNTS entry's basename"
clash $'REPOS="lib:ro delta:rw"\n' "$W/new/delta" "/workspace/delta" "mv refuses a <new-dir> with a REPOS name"
clash $'EXTRA_MOUNTS=/x/alpha\n' "$W/new/beta" "/workspace/alpha" "mv refuses when the old root it would add to EXTRA_MOUNTS has an entry's basename"

world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; mkdir -p "$N/.ai-containers"; printf 'theirs\n' > "$N/.ai-containers/sandbox.env"
mvrun "$A" "$N" --yes; rc=$?
ok "mv refuses when both the old and the new .ai-containers exist" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3/.ai-containers/sandbox.env")" = theirs ]' _ "$rc" "$TMP/out" "$N"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# already moved: by hand, and with the old line gone (gc removed it)
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; nv="$(wcname app "$N/.ai-containers")"
printf '/x/before\n%s\n' "$A" > "$ENG/projects.conf"
mvrun "$A" "$N" --yes; rc=$?
ok "mv repairs a project already moved by hand" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "/x/before\n%s" "$3")" ] && [ ! -d "$4/$9" ] && [ "$(cat "$4/$5/data/work")" = unpushed ] \
           && [ "$(cat "$3/.ai-containers/sandbox.local.env")" = "EXTRA_MOUNTS=\"$6\"" ] && [ ! -e "$7" ] && [ -e "${10}" ] && ! grep -qF "$8" "${10}" \
           && [ ! -e "$6/.ai-containers" ]' \
  _ "$rc" "$ENG/projects.conf" "$N" "$VOLS" "$nv" "$A" "$IMGS/img-alpha" "$ida" "$OLDWC" "$IP"
ok "  … saying there was nothing to move" hasx "  directory   $N/.ai-containers (already there; nothing to move)"
ok "  … and nothing of <new-dir> being registered, which it is not" lacks "registered project already"
# moved by hand, the old root then removed whole: a copy launched from anywhere
# under it, not only from its .ai-containers, goes to the same place under <new-dir>
world
A="$W/alpha"; mvproj "$A"; mkwc app 3 "$A/sub"; N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; rm -rf "$A"
nv="$(wcname app "$N/sub")"
mvrun "$A" "$N" --yes; rc=$?
ok "mv of a setup moved by hand from a root that is gone carries a copy launched from under that root" \
  bash -c '[ "$1" = 0 ] && [ -n "$3" ] && grep -qxF "ai-containers.launch-dir=$4/sub" "$2/$3/labels" && [ ! -d "$2/ai-containers-repo-app--wc-3" ]' \
  _ "$rc" "$VOLS" "$nv" "$N"
# A setup moved by hand, interrupted: while copying, the copies made are
# removed; once the old copies start to go, what was done is listed. Either
# way the next run finishes the move (review of the PRJ-12 fix).
world
A="$W/alpha"; mvproj "$A"; N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; nv="$(wcname app "$N/.ai-containers")"
FAKE_RUN_TERM=1 mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 mv of a setup moved by hand, interrupted while copying, removes the copy made and keeps the old one" \
  bash -c '[ "$1" = 143 ] && [ ! -d "$2/$3" ] && [ "$(cat "$2/$4/data/work")" = unpushed ] && grep -qF "The old working copies are as they were" "$5"' \
  _ "$rc" "$VOLS" "$nv" "$OLDWC" "$TMP/out"
mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 ... and running it again finishes the move" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && [ "$(cat "$4/$5/data/work")" = unpushed ] && [ ! -d "$4/$6" ]' _ "$rc" "$N" "$ENG/projects.conf" "$VOLS" "$nv" "$OLDWC"
world
A="$W/alpha"; mvproj "$A"; N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; nv="$(wcname app "$N/.ai-containers")"
FAKE_VOLRM_TERM="$OLDWC" mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 mv of a setup moved by hand, interrupted once the old copies start to go, keeps the new copy" \
  bash -c '[ "$1" = 143 ] && [ "$(cat "$2/$3/data/work")" = unpushed ] && [ ! -d "$2/$4" ] && grep -qF "interrupted" "$5"' \
  _ "$rc" "$VOLS" "$nv" "$OLDWC" "$TMP/out"
mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 ... and running it again finishes the move" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && ! grep -qxF "$6" "$3" && [ "$(cat "$4/$5/data/work")" = unpushed ]' _ "$rc" "$N" "$ENG/projects.conf" "$VOLS" "$nv" "$A"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; nv="$(wcname app "$N/.ai-containers")"
printf '/x/other\n' > "$ENG/projects.conf"
# Given through a link, which is how it goes into EXTRA_MOUNTS: as given, not as
# its physical path. And first with a projects.conf that cannot be rewritten: mv
# stops there, exit 1, and the run after it finishes.
fake_mktemp
FAKE_MKTEMP_BAD='.projects.conf.new.*' FAKE_MKTEMP_HOW=dir mvrun "$WL/alpha" "$N" --yes; rc=$?
rm -f "$TMP/bin/mktemp"; hash -r
ok "mv of a project whose line gc removed exits 1 when it cannot add the new place to projects.conf" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: " "$2" && ! grep -qF "OK: moved" "$2" && [ "$(cat "$3")" = /x/other ]' \
  _ "$rc" "$TMP/out" "$ENG/projects.conf"
mvrun "$WL/alpha" "$N" --yes; rc=$?
ok "mv repairs a project whose line gc removed, given through a link" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "/x/other\n%s" "$3")" ] && [ ! -d "$4/$9" ] && [ "$(cat "$4/$5/data/work")" = unpushed ] \
           && [ "$(cat "$3/.ai-containers/sandbox.local.env")" = "EXTRA_MOUNTS=\"$6\"" ] && [ ! -e "$7" ] && [ -e "${10}" ] && ! grep -qF "$8" "${10}"' \
  _ "$rc" "$ENG/projects.conf" "$N" "$VOLS" "$nv" "$WL/alpha" "$IMGS/img-alpha" "$ida" "$OLDWC" "$IP"
ok "  … listing the new place as added to projects.conf" hasx "  registry    $N (projects.conf, added)"
world
A="$W/alpha"; mkdir -p "$A"; printf '/x/other\n' > "$ENG/projects.conf"; cp "$ENG/projects.conf" "$TMP/conf.before"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses a project that is not registered and was not moved" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*not a registered project" "$2" && [ ! -e "$3" ] && cmp -s "$4" "$5"' \
  _ "$rc" "$TMP/out" "$W/beta" "$ENG/projects.conf" "$TMP/conf.before"

# the image
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; printf 'sha256:keep-me|/elsewhere\n' >> "$IP"; built "$A" img-alpha
ida="$(tid "$A/.ai-containers")"; N="$W/beta"
mvrun "$A" "$N" --yes; rc=$?
ok "mv removes the old image and its image-projects.conf line, and says the next build rebuilds it" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && grep -qxF "docker rmi img-alpha" "$3" && ! grep -qF "$4" "$5" \
           && grep -qxF "sha256:keep-me|/elsewhere" "$5"' _ "$rc" "$IMGS/img-alpha" "$DOCKER_LOG" "$ida" "$IP"
ok "  … in those words" hasx "NOTE: the next ./build.sh (runme.sh runs it) builds img-alpha again, from the cache."
( cd "$TMP" && source "$P" && ai_containers_image_portable=1 ai_containers_build_retag_guard img-alpha "$N/.ai-containers" ) > "$TMP/err" 2>&1; rc=$?
ok "the retag guard passes for IMAGE_NAME right after mv" [ "$rc" = 0 ]
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"; N="$W/beta"
export FAKE_FAIL_RMI=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_FAIL_RMI
ok "mv keeps an image a stopped container references, and its line, and says so" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && grep -qF "NOTE: could not remove the image img-alpha" "$5" \
           && grep -qF "NOTE: an image still carries this project'"'"'s id" "$5" && ! grep -qF "builds img-alpha again" "$5"' \
  _ "$rc" "$IMGS/img-alpha" "$ida" "$IP" "$TMP/out"
( cd "$TMP" && source "$P" && ai_containers_image_portable=1 ai_containers_build_retag_guard img-alpha "$N/.ai-containers" ) > "$TMP/err" 2>&1; rc=$?
ok "  … which the next build replaces, with a NOTE" bash -c '[ "$1" = 0 ] && grep -q "^NOTE: img-alpha was built for" "$2"' _ "$rc" "$TMP/err"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-shared\n'; printf 'ai-containers.project=sha256:%064d\n' 7 > "$IMGS/img-shared"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv keeps an IMAGE_NAME whose label is another project's id" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && ! grep -q "^docker rmi" "$3" && grep -qF "  image       img-shared — kept: " "$4" \
           && ! grep -qF "builds img-shared again" "$4"' _ "$rc" "$IMGS/img-shared" "$DOCKER_LOG" "$TMP/out"
ok "  … and says nothing of the next build refusing an image that was never this project's" lacks "will refuse to replace"

world
O="$W/outer"; mkproj "$O"; mkproj "$O/inner"; mkbase app
mkwc app 1 "$O/.ai-containers"; mkwc app 2 "$O/inner/.ai-containers"
N="$W/newouter"; nv="$(wcname app "$N/.ai-containers")"
mvrun "$O" "$N" --yes; rc=$?
ok "mv leaves a working copy launched from a nested registered project" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/$3" ] && [ ! -d "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "ai-containers.launch-dir=$4/inner/.ai-containers" "$2/ai-containers-repo-app--wc-2/labels" \
           && [ -d "$4/inner/.ai-containers" ] && grep -qxF "$4/inner" "$5"' _ "$rc" "$VOLS" "$nv" "$O" "$ENG/projects.conf"

world
A="$W/alpha"; mvproj "$A"
git -C "$A" init -q 2>/dev/null && git -C "$A" add .ai-containers README
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv notes that the old repository tracks .ai-containers" \
  bash -c '[ "$1" = 0 ] && grep -qxF "NOTE: $2'"'"'s repository tracks .ai-containers/; those files now show as deleted there." "$3"' \
  _ "$rc" "$A" "$TMP/out"

# what stops it
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
printf 'ctr-one|other-image|/somewhere|%s/.ai-containers/.agent-blocked\n' "$A" > "$FAKE_RUNNING"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses while a container of the project runs, saying nothing was changed" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*ctr-one.*nothing was changed\.$" "$2" && ! grep -q "nothing was removed" "$2" && [ ! -e "$3" ]' \
  _ "$rc" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
printf 'ctr-late|img-alpha|/somewhere\n' > "$FAKE_RUNNING.later"
export FAKE_RUNNING_AFTER=4
mvrun "$A" "$W/beta" --yes; rc=$?
unset FAKE_RUNNING_AFTER
ok "mv checks again after the question, and refuses a container started meanwhile" \
  bash -c '[ "$1" = 1 ] && grep -q "About to move" "$2" && grep -q "ERROR.*started after the listing.*ctr-late" "$2"' _ "$rc" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"
mvrun "$A" "$W/beta"; rc=$?
ok "mv refuses on a non-TTY without --yes" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && grep -q "About to move" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mvrun "$A" "$W/beta" --bogus; rc=$?
ok "mv exits 1 on an unknown flag, naming it" bash -c '[ "$1" = 1 ] && grep -qxF "ERROR: unknown flag --bogus" "$2"' _ "$rc" "$TMP/out"
mvrun "$A" "$W/beta" "$W/gamma"; rc=$?
ok "mv exits 1 on a third argument, naming it" \
  bash -c '[ "$1" = 1 ] && grep -qxF "ERROR: unexpected argument $2" "$3"' _ "$rc" "$W/gamma" "$TMP/out"
mvrun "$A"; rc=$?
ok "mv exits 1 with its usage when <new-dir> is missing" \
  bash -c '[ "$1" = 1 ] && grep -qxF "ERROR: usage: ./project.sh mv <project> <new-dir> [--yes]" "$2"' _ "$rc" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"; export FAKE_DOCKER_DOWN=1
mvrun "$A" "$W/beta" --yes; rc=$?
unset FAKE_DOCKER_DOWN
ok "mv refuses when docker cannot be reached" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: docker cannot be reached" "$2" && [ -d "$3/.ai-containers" ] && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$A" "$W/beta"
world
A="$W/alpha"; mvproj "$A"; export FAKE_NO_SEED=1
mvrun "$A" "$W/beta" --yes; rc=$?
unset FAKE_NO_SEED
ok "mv refuses when the seed image that copies the working copies cannot be had" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*seed helper image" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"; printf 'EXTRA_MOUNTS=/x/mine\n' > "$TMP/real-local"
ln -s "$TMP/real-local" "$A/.ai-containers/sandbox.local.env"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses a linked sandbox.local.env it would add the old root to, and its target is untouched" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*sandbox.local.env" "$2" && [ "$(cat "$3")" = EXTRA_MOUNTS=/x/mine ] && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$TMP/real-local" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
world
A="$W/alpha"; mvproj "$A"; mkdir -p "$W/same"; ln -s "$W" "$W/same/up"
mvrun "$A" "$W/same/up/alpha" --yes; rc=$?
ok "mv refuses a <new-dir> that is the project itself" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*already" "$2"' _ "$rc" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mkdir -p "$W/real-beta"; ln -s "$W/real-beta" "$W/beta-link"
mvrun "$A" "$W/beta-link" --yes; rc=$?
ok "mv refuses a <new-dir> that is a link" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*is a link" "$2" && [ ! -e "$3/.ai-containers" ] && [ -L "$4" ]' \
  _ "$rc" "$TMP/out" "$W/real-beta" "$W/beta-link"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mvrun "$A" "$W/nope/../beta" --yes; rc=$?
ok "mv refuses a <new-dir> with .. where it does not exist yet" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*\.\. where it does not exist" "$2" && [ ! -e "$3" ] && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$W/nope" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
# <new-dir> that could be made when checked, and then cannot (a mkdir that
# fails for that one path): exit 1, and the working copies it made go again
printf '#!/usr/bin/env bash\nif [[ -n "${FAKE_MKDIR_FAIL:-}" && "${!#}" == "$FAKE_MKDIR_FAIL" ]]; then echo "mkdir: cannot create directory" >&2; exit 1; fi\nexec %q "$@"\n' \
  "$(command -v mkdir)" > "$TMP/bin/mkdir"
chmod +x "$TMP/bin/mkdir"; hash -r
nv="$(wcname app "$W/mk/beta/.ai-containers")"
FAKE_MKDIR_FAIL="$W/mk/beta" mvrun "$A" "$W/mk/beta" --yes; rc=$?
rm -f "$TMP/bin/mkdir"; hash -r
ok "mv exits 1 when it cannot make <new-dir>, removing the working copies it made" \
  bash -c '[ "$1" = 1 ] && grep -qxF "ERROR: could not make $2; nothing was changed." "$3" && [ ! -e "$2" ] && [ -n "$5" ] && [ ! -d "$4/$5" ] \
           && [ "$(cat "$4/$6/data/work")" = unpushed ] && [ -d "$7/.ai-containers" ] && cmp -s "$8" "$9"' \
  _ "$rc" "$W/mk/beta" "$TMP/out" "$VOLS" "$nv" "$OLDWC" "$A" "$ENG/projects.conf" "$TMP/conf.before"
: > "$DOCKER_LOG"   # the copy it made and removed is logged; moved_nothing below reads the log
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: a <new-dir> that cannot be made (running as root)\n'
else
  mkdir -p "$W/locked"; chmod 555 "$W/locked"
  mvrun "$A" "$W/locked/beta" --yes; rc=$?
  chmod 755 "$W/locked"
  ok "mv refuses a <new-dir> that cannot be made" \
    bash -c '[ "$1" = 1 ] && grep -q "ERROR.*cannot be made" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$W/locked/beta"
  ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
fi
world
A="$W/alpha"; mkdir -p "$A"; printf '%s\n' "$A" > "$ENG/projects.conf"; cp "$ENG/projects.conf" "$TMP/conf.before"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses when neither the old nor the new .ai-containers exists" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR: neither" "$2" && [ ! -e "$3" ] && cmp -s "$4" "$5"' \
  _ "$rc" "$TMP/out" "$W/beta" "$ENG/projects.conf" "$TMP/conf.before"

# The helpers rm and gc judge paths, registries and images by, asked directly.
mkdir -p "$W/u/d" "$W/u/nr"; printf 'x\n' > "$W/u/f"; printf 'x\n' > "$W/u/nf"
chmod 311 "$W/u/nr"; chmod 000 "$W/u/nf"
( source "$P"
  _ut() { local rc=0; "$@" || rc=$?; printf '|%s\n' "$rc"; }
  _ut _prj_maybe_unmounted "$W/u/f/gone"
  _ut _prj_maybe_unmounted "$W/u/nr/gone"
  _ut _prj_reg_bad "$W/u/none"
  _ut _prj_reg_bad "$W/u/d"
  _ut _prj_reg_bad "$W/u/nf"
  FAKE_DOCKER_DOWN=1 _ut _prj_id_images sha256:x
) > "$TMP/out" 2>&1
chmod 755 "$W/u/nr"; chmod 644 "$W/u/nf"
ok "_prj_maybe_unmounted takes a path under a regular file for gone, saying nothing" bash -c '[ "$(sed -n 1p "$1")" = "|1" ]' _ "$TMP/out"
ok "_prj_reg_bad lets a registry that is not there be, and names one that is not a regular file" \
  bash -c '[ "$(sed -n 3p "$1")" = "|1" ] && [ "$(sed -n 4p "$1")" = "it is not a regular file|0" ]' _ "$TMP/out"
ok "_prj_id_images fails when docker cannot list images" bash -c '[ "$(sed -n 6p "$1")" = "|1" ]' _ "$TMP/out"
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: a directory or registry that cannot be read (running as root)\n'
else
  ok "_prj_maybe_unmounted takes a path under a directory it can search but not read for gone" \
    bash -c '[ "$(sed -n 2p "$1")" = "|1" ]' _ "$TMP/out"
  ok "_prj_reg_bad names a registry that cannot be read" bash -c '[ "$(sed -n 5p "$1")" = "it cannot be read|0" ]' _ "$TMP/out"
fi

# a working copy's new name already taken
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkvol "$nv" "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$N/.ai-containers"; wcdata "$nv" unpushed
mvrun "$A" "$N" --yes; rc=$?
ok "mv takes an exact copy already at the new name (a run cut short) as done, and removes the old" \
  bash -c '[ "$1" = 0 ] && [ ! -d "$2/$5" ] && [ "$(cat "$2/$3/data/work")" = unpushed ] && ! grep -q "^docker volume create" "$4"' \
  _ "$rc" "$VOLS" "$nv" "$DOCKER_LOG" "$OLDWC"
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkvol "$nv" "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$N/.ai-containers"; wcdata "$nv" fresh
mvrun "$A" "$N" --yes; rc=$?
ok "mv refuses a working copy whose new name another volume holds" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: " "$2" && grep -qF "$5" "$2" && [ "$(cat "$3/$5/data/work")" = fresh ] \
           && [ "$(cat "$3/$4/data/work")" = unpushed ]' _ "$rc" "$TMP/out" "$VOLS" "$OLDWC" "$nv"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

world
S="$W/my proj"; mkproj "$S" $'IMAGE_NAME=img-space\n'; built "$S" img-space; mkbase app
mkwc app 1 "$S/.ai-containers"; wcdata "$OLDWC" unpushed
N="$W/new place/proj two"; nv="$(wcname app "$N/.ai-containers")"
mvrun "$S" "$N" --yes; rc=$?
ok "mv works when <new-dir> and the old root have spaces" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.ai-containers/sandbox.env" ] && [ ! -e "$3" ] && grep -qxF "$2" "$4" \
           && ! grep -qxF "$3" "$4" && [ "$(cat "$5/$6/data/work")" = unpushed ] && [ ! -d "$5/$8" ] && [ ! -e "$7" ] \
           && [ ! -e "$2/.ai-containers/sandbox.local.env" ]' \
  _ "$rc" "$N" "$S" "$ENG/projects.conf" "$VOLS" "$nv" "$IMGS/img-space" "$OLDWC"
world
S="$W/my proj"; mvproj "$S"
mvrun "$S" "$W/beta" --yes; rc=$?
ok "mv refuses an old root with whitespace that it would have to mount" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: $3 holds whitespace" "$2" && grep -qF "rename" "$2" && [ ! -e "$4" ]' \
  _ "$rc" "$TMP/out" "$S" "$W/beta"
ok "  … changing nothing" moved_nothing "$S" "$TMP/conf.before"
world
O="$W/outer"; S="$O/my proj"; mvproj "$S"
mvrun "$S" "$O" --yes; rc=$?
ok "mv adds nothing for an old root inside <new-dir>, whitespace or not" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.ai-containers/sandbox.env" ] && [ ! -e "$2/.ai-containers/sandbox.local.env" ] \
           && [ -f "$3/README" ] && [ ! -e "$3/.ai-containers" ]' _ "$rc" "$O" "$S"
ok "  … saying the container mounts it there" hasx "  EXTRA_MOUNTS $S lies inside $O, which the container mounts: nothing to add"

# never into or out of ~/.ai-containers, nor into the old .ai-containers
world
mkdir -p "$HOME/.ai-containers/default/.claude"; printf '%s\n' "$HOME" > "$ENG/projects.conf"
mvrun "$HOME" "$W/newhome" --yes; rc=$?
ok "mv refuses a project registered at HOME" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ -f "$3/project-id.key" ] && [ -d "$3/default/.claude" ] \
           && [ ! -e "$4" ] && [ "$(cat "$5")" = "$6" ]' _ "$rc" "$TMP/out" "$HOME/.ai-containers" "$W/newhome" "$ENG/projects.conf" "$HOME"
ok "  … saying to remove its line by hand" has_line "and the registries live; refusing. Remove its line from $ENG/projects.conf by hand."
world
A="$W/alpha"; mvproj "$A"
mvrun "$A" "$HOME/.ai-containers/x" --yes; rc=$?
ok "mv refuses a <new-dir> inside ~/.ai-containers" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*where every group" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$HOME/.ai-containers/x"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mvrun "$A" "$A/.ai-containers/sub" --yes; rc=$?
ok "mv refuses a <new-dir> inside the old .ai-containers" \
  bash -c '[ "$1" = 1 ] && grep -q "ERROR.*inside" "$2" && [ ! -e "$3" ]' _ "$rc" "$TMP/out" "$A/.ai-containers/sub"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
mvrun "$A" "$WL/alpha/.ai-containers/sub" --yes; rc=$?
ok "mv refuses a <new-dir> inside the old .ai-containers named through a link" \
  bash -c '[ "$1" = 1 ] && grep -qxF "ERROR: $2 lies inside $3/.ai-containers, which is what moves; refusing." "$4" && [ ! -e "$3/.ai-containers/sub" ]' \
  _ "$rc" "$WL/alpha/.ai-containers/sub" "$A" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
rm -rf "$HOME/.ai-containers/default"

# across filesystems (forced: the test's directories are all on one)
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'
mkdir -p "$A/.ai-containers/.agent-discovery"; printf 'pcap\n' > "$A/.ai-containers/.agent-discovery/cap.pcap"
ln -s ../sandbox.env "$A/.ai-containers/.agent-discovery/link"
N="$W/beta"; export AI_CONTAINERS_MV_COPY=1
mvrun "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY
ok "mv across filesystems copies .ai-containers, checks the copy, then removes the old" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/.ai-containers" ] && [ "$(cat "$3/.ai-containers/sandbox.env")" = IMAGE_NAME=img-alpha ] \
           && [ "$(cat "$3/.ai-containers/.agent-discovery/cap.pcap")" = pcap ] && [ -L "$3/.ai-containers/.agent-discovery/link" ] \
           && [ "$(ls -A "$3")" = .ai-containers ] && grep -qxF "$3" "$4"' _ "$rc" "$A" "$N" "$ENG/projects.conf"
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
mkdir -p "$W/p0"; N="$W/p0/p1/p2/beta"; nv="$(wcname app "$N/.ai-containers")"; export AI_CONTAINERS_MV_COPY=1 FAKE_CP_CORRUPT=sandbox.env
mvrun "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY FAKE_CP_CORRUPT
ok "mv across filesystems keeps the old .ai-containers and removes the temp copy when the copy differs" \
  bash -c '[ "$1" = 1 ] && grep -q ERROR "$2" && [ "$(cat "$3/.ai-containers/sandbox.env")" = IMAGE_NAME=img-alpha ] \
           && [ -z "$(ls -A "$4" 2>/dev/null)" ] && cmp -s "$5" "$6"' _ "$rc" "$TMP/out" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before"
ok "  … and the directories it made for <new-dir>, and only those" bash -c '[ ! -e "$1" ] && [ -d "$2" ]' _ "$W/p0/p1" "$W/p0"
ok "  … and the working copies as they were" \
  bash -c '[ "$(cat "$1/$3/data/work")" = unpushed ] && [ ! -e "$1/$2" ] && [ -e "$4" ]' _ "$VOLS" "$nv" "$OLDWC" "$IMGS/img-alpha"

# the setup must land at <new-dir>/.ai-containers itself: something put there
# just before the rename (a racing process) takes it in, on a mv without -T
landed_not() {  # <assertion> <where the setup or its copy went> <old .ai-containers kept: 1|0>
  ok "$1" bash -c '[ "$1" = 1 ] && [ -d "$3" ] && grep -qF -- "$(cd "$3" && pwd -P)" "$2" && cmp -s "$4" "$5" \
                   && [ "$(cat "$6/$8/data/work")" = unpushed ] && [ ! -e "$6/$7" ] && [ -e "$9" ] \
                   && { [ "${10}" = 0 ] || [ -f "${11}/.ai-containers/sandbox.env" ]; } && [ ! -e "$3/sandbox.local.env" ]' \
    _ "$rc" "$TMP/out" "$2" "$ENG/projects.conf" "$TMP/conf.before" "$VOLS" "$nv" "$OLDWC" "$IMGS/img-alpha" "$3" "$A"
}
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
export FAKE_MV_PLANT="$N/.ai-containers"
mvbsd "$A" "$N" --yes; rc=$?
unset FAKE_MV_PLANT
landed_not "mv exits 1 when a directory appears where the setup goes, saying where it went, recording nothing" \
  "$N/.ai-containers/.ai-containers" 0
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkdir -p "$W/elsewhere"; export FAKE_MV_PLANT="$N/.ai-containers" FAKE_MV_PLANT_TO="$W/elsewhere"
mvbsd "$A" "$N" --yes; rc=$?
unset FAKE_MV_PLANT FAKE_MV_PLANT_TO
landed_not "mv exits 1 when a link appears where the setup goes, writing nothing through it" "$W/elsewhere/.ai-containers" 0
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
export AI_CONTAINERS_MV_COPY=1 FAKE_MV_PLANT="$N/.ai-containers"
mvbsd "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY FAKE_MV_PLANT
landed_not "mv across filesystems exits 1 when a directory appears where the checked copy goes, keeping the old" \
  "$N/.ai-containers/.ai-containers" 1
ok "  … and leaves no temp directory" bash -c '[ "$(ls -A "$1")" = .ai-containers ]' _ "$N"
pd="$(mktemp -d "$TMP/probe.XXXXXX")"; mkdir "$pd/a"
if "$REAL_MV" -T "$pd/a" "$pd/b" 2>/dev/null; then
  world
  A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; N="$W/beta"
  export FAKE_MV_PLANT="$N/.ai-containers"
  mvrun "$A" "$N" --yes; rc=$?
  unset FAKE_MV_PLANT
  ok "with mv -T, a directory that appears where the setup goes stops the move" \
    bash -c '[ "$1" = 1 ] && [ -f "$2/.ai-containers/sandbox.env" ] && [ ! -e "$3/.ai-containers/.ai-containers" ] && cmp -s "$4" "$5" \
             && grep -qF "it is where it was" "$6"' _ "$rc" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before" "$TMP/out"
else
  printf 'SKIP: mv -T on this mv (it has none)\n'
fi
rm -rf "$pd"

# what the launcher would resolve against the launch directory, which moves
relative() {  # <sandbox.local.env text> <what the error names> <assertion>
  world
  A="$W/alpha"; mvproj "$A" '' "$1"
  mvrun "$A" "$W/beta" --yes; rc=$?
  ok "$3" bash -c '[ "$1" = 1 ] && grep -q "^ERROR: " "$2" && grep -qF -- "$3" "$2" && [ ! -e "$4" ]' _ "$rc" "$TMP/out" "$2" "$W/beta"
  ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
}
relative $'EXTRA_MOUNTS="/x/one ../shared:ro"\n' "EXTRA_MOUNTS entry ../shared:ro" "mv refuses a relative EXTRA_MOUNTS entry, naming it"
relative $'SANDBOX_WORKDIR=@app\n' "SANDBOX_WORKDIR=@app" "mv refuses a SANDBOX_WORKDIR other than .. in sandbox.local.env, naming it"
relative $'VAULT_PATH=notes\n' "VAULT_PATH=notes" "mv refuses a relative pointer in sandbox.local.env, naming it"
world
A="$W/alpha"; mvproj "$A" '' $'SANDBOX_WORKDIR=..\nVAULT_PATH=~/notes\nDOCS_PATH=@docs:ro\nEXTRA_MOUNTS=~/x\n'
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv takes SANDBOX_WORKDIR=.., a ~ path and an @name as they are" bash -c '[ "$1" = 0 ]' _ "$rc"

# an image a stopped container keeps, and the old root it leaves empty
retag() { ( cd "$TMP" && source "$P" && ai_containers_image_portable=1 ai_containers_build_retag_guard img-alpha "$1/.ai-containers" ) > "$TMP/err" 2>&1; }
world
mkdir -p "$W/setup"; printf 'x\n' > "$W/setup/other"; A="$W/setup/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
N="$W/dev/beta"; export FAKE_FAIL_RMI=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_FAIL_RMI
retag "$N"; rc2=$?
ok "mv removes the old root it left empty though the image stays, so the next build replaces the image" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && [ -e "$3" ] && [ "$4" = 0 ] && grep -q "^NOTE: img-alpha was built for" "$5"' \
  _ "$rc" "$A" "$IMGS/img-alpha" "$rc2" "$TMP/err"
ok "  … and says nothing of the next build refusing" lacks "will refuse to replace"
world
mkdir -p "$W/setup"; A="$W/setup/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha
N="$W/dev/beta"; export FAKE_FAIL_RMI=1
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_FAIL_RMI
retag "$N"; rc2=$?
ok "mv says when the next build will refuse the image it could not remove, and how to remove it" \
  bash -c '[ "$1" = 0 ] && [ "$2" = 1 ] && grep -qF "NOTE: the next ./build.sh will refuse to replace img-alpha" "$3" \
           && grep -qF "docker rmi img-alpha" "$3"' _ "$rc" "$rc2" "$TMP/out"

# a move across filesystems: an old .ai-containers it cannot remove whole, and an interrupt
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: an old .ai-containers that cannot be removed whole (running as root)\n'
else
  world
  A="$W/alpha"; mvproj "$A"; mkdir -p "$A/.ai-containers/stuck"; printf 'x\n' > "$A/.ai-containers/stuck/file"
  chmod 555 "$A/.ai-containers/stuck"; N="$W/beta"; export AI_CONTAINERS_MV_COPY=1
  mvrun "$A" "$N" --yes; rc=$?
  unset AI_CONTAINERS_MV_COPY
  ok "mv says to remove by hand what is left of an old .ai-containers it could not remove, not to run it again" \
    bash -c '[ "$1" = 1 ] && grep -qF "what is left of $3/.ai-containers is only a copy" "$2" && grep -qF "remove it by hand" "$2" \
             && ! grep -qF "project.sh mv" "$2" && [ -f "$4/.ai-containers/sandbox.env" ] && grep -qxF "$4" "$5"' \
    _ "$rc" "$TMP/out" "$A" "$N" "$ENG/projects.conf"
fi
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; export AI_CONTAINERS_MV_COPY=1 FAKE_CP_TERM=1
mvrun "$A" "$N" --yes; rc=$?
unset AI_CONTAINERS_MV_COPY FAKE_CP_TERM
ok "mv interrupted while it copies .ai-containers leaves no temp copy in <new-dir>" \
  bash -c '[ "$1" = 143 ] && [ -z "$(ls -A "$2" 2>/dev/null)" ] && [ -f "$3/.ai-containers/sandbox.env" ] && cmp -s "$4" "$5" \
           && grep -q "ERROR: interrupted" "$6"' _ "$rc" "$N" "$A" "$ENG/projects.conf" "$TMP/conf.before" "$TMP/out"
# Interrupted after the checked copy has landed, while the old .ai-containers is
# removed (bugs review PRJ-12): the trap undid the working copies and said the
# old ones were as they were and to run mv again, which then refused because both
# directories existed, the old one half removed. The landed copy is the setup
# now: the working copies stay, and the message names the leftover to remove and
# the run that finishes the move. Here an rm that removes part of the old
# directory and then sends TERM to project.sh, or (FAKE_RM_TERM_AFTER) removes
# all of it first.
REAL_RM="$(command -v rm)"; export REAL_RM
cat > "$TMP/bin/rm" <<'FAKERM'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ -n "${FAKE_RM_TERM:-}" && "$a" == "$FAKE_RM_TERM" ]]; then
    "$REAL_RM" -f -- "$a/sandbox.env" "$a/sandbox.local.env"; kill -TERM "$PPID"; exit 130
  fi
  if [[ -n "${FAKE_RM_TERM_AFTER:-}" && "$a" == "$FAKE_RM_TERM_AFTER" ]]; then
    "$REAL_RM" "$@"; kill -TERM "$PPID"; exit 0
  fi
done
exec "$REAL_RM" "$@"
FAKERM
chmod +x "$TMP/bin/rm"; hash -r
world
A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img\n' $'VAULT_PATH=/v\n'; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
AI_CONTAINERS_MV_COPY=1 FAKE_RM_TERM="$A/.ai-containers" mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 mv interrupted while it removes the old .ai-containers keeps the checked copy and the new working copy, and names the leftover" \
  bash -c '[ "$1" = 143 ] && [ -f "$2/.ai-containers/sandbox.local.env" ] && [ -d "$3/$4" ] && [ -d "$3/$5" ] && cmp -s "$6" "$7" \
           && grep -qF "$2/.ai-containers is in place, the checked copy of $8/.ai-containers" "$9" && grep -qF "rm -rf $8/.ai-containers" "$9" \
           && ! grep -qF "The old working copies are as they were" "$9"' \
  _ "$rc" "$N" "$VOLS" "$nv" "$OLDWC" "$ENG/projects.conf" "$TMP/conf.before" "$A" "$TMP/out"
# The way out it names: remove the leftover, run mv again. That finishes the
# move: the registry names the new place, the new copy is taken as done, the
# old one goes.
"$REAL_RM" -rf -- "$A/.ai-containers"
mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 removing that leftover and running mv again finishes the move" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && ! grep -qxF "$4" "$3" && [ -d "$5/$6" ] && [ ! -d "$5/$7" ] && [ "$(cat "$5/$6/data/work")" = unpushed ]' \
  _ "$rc" "$N" "$ENG/projects.conf" "$A" "$VOLS" "$nv" "$OLDWC"
# The TERM that comes once the old directory is gone entirely: nothing is left
# over, and a run again is all that finishing takes.
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
AI_CONTAINERS_MV_COPY=1 FAKE_RM_TERM_AFTER="$A/.ai-containers" mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 mv interrupted just after the old .ai-containers is gone says only to run it again, the new working copy kept" \
  bash -c '[ "$1" = 143 ] && [ ! -e "$2/.ai-containers" ] && [ -d "$3/$4" ] && grep -qF "$5/.ai-containers is in place. Run ./project.sh mv" "$6" \
           && ! grep -qF "leftover" "$6" && ! grep -qF "The old working copies are as they were" "$6"' \
  _ "$rc" "$A" "$VOLS" "$nv" "$N" "$TMP/out"
mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 ... and running it again finishes the move" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && [ -d "$4/$5" ] && [ ! -d "$4/$6" ]' _ "$rc" "$N" "$ENG/projects.conf" "$VOLS" "$nv" "$OLDWC"
"$REAL_RM" -f -- "$TMP/bin/rm"; hash -r
# Interrupted right after the rename that lands the checked copy, before the
# old directory is touched (review of the PRJ-12 fix): it is in place, so the
# working copies stay. An rmdir of the emptied temp directory sends the TERM.
REAL_RMDIR="$(command -v rmdir)"; export REAL_RMDIR
cat > "$TMP/bin/rmdir" <<'FAKERMDIR'
#!/usr/bin/env bash
"$REAL_RMDIR" "$@"; rc=$?
for a in "$@"; do [[ -n "${FAKE_RMDIR_TERM:-}" && "${a##*/}" == .ai-containers.* ]] && kill -TERM "$PPID"; done
exit "$rc"
FAKERMDIR
chmod +x "$TMP/bin/rmdir"; hash -r
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
AI_CONTAINERS_MV_COPY=1 FAKE_RMDIR_TERM=1 mvrun "$A" "$N" --yes; rc=$?
"$REAL_RM" -f -- "$TMP/bin/rmdir"; hash -r
ok "PRJ-12 mv interrupted right after the checked copy lands keeps the new working copy and names the old directory as the leftover" \
  bash -c '[ "$1" = 143 ] && [ -d "$2/.ai-containers" ] && [ -d "$3/$4" ] && grep -qF "$2/.ai-containers is in place, the checked copy of $5/.ai-containers" "$6" \
           && ! grep -qF "The old working copies are as they were" "$6"' _ "$rc" "$N" "$VOLS" "$nv" "$A" "$TMP/out"
"$REAL_RM" -rf -- "$A/.ai-containers"; mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 ... and its way out finishes the move" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && [ -d "$4/$5" ] && [ ! -d "$4/$6" ]' _ "$rc" "$N" "$ENG/projects.conf" "$VOLS" "$nv" "$OLDWC"

# On one filesystem the move is a rename, marked landed just before it, by the
# directory's own inode: an interrupt right after it says to run mv again, and
# keeps the new working copies (review of the PRJ-12 fix).
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
FAKE_MV_TERM_AFTER="$N/.ai-containers" mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 mv interrupted right after its rename on one filesystem keeps the new working copy and says to run it again" \
  bash -c '[ "$1" = 143 ] && [ -d "$2/.ai-containers" ] && [ ! -e "$5/.ai-containers" ] && [ -d "$3/$4" ] \
           && grep -qF "$2/.ai-containers is in place. Run ./project.sh mv" "$6" && ! grep -qF "The old working copies are as they were" "$6"' \
  _ "$rc" "$N" "$VOLS" "$nv" "$A" "$TMP/out"
mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 ... and running it again finishes the move" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && [ -d "$4/$5" ] && [ ! -d "$4/$6" ]' _ "$rc" "$N" "$ENG/projects.conf" "$VOLS" "$nv" "$OLDWC"
# Something put at <new-dir>/.ai-containers just before the rename, then a TERM
# before it: the copy has not landed, though something is there, and only its
# inode tells; the copies made are undone.
world
A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
AI_CONTAINERS_MV_COPY=1 FAKE_MV_PLANT="$N/.ai-containers" FAKE_MV_TERM="$N/.ai-containers" mvrun "$A" "$N" --yes; rc=$?
ok "PRJ-12 mv interrupted before its rename, with something put where the copy goes, does not take that for the copy" \
  bash -c '[ "$1" = 143 ] && [ -f "$2/.ai-containers/sandbox.env" ] && [ ! -d "$3/$4" ] && ! grep -qF "is in place" "$5" \
           && grep -qF "The old working copies are as they were" "$5"' _ "$rc" "$A" "$VOLS" "$nv" "$TMP/out"

# Two copies of one repo, launched through a link to the project and through
# its real path, would both take one new name (bugs review PRJ-14): refused
# before the question, naming both, rather than failing after it every time.
world; mkdir -p "$W/real"; ln -s "$W/real" "$W/link"
A="$W/real/alpha"; mkproj "$A"; printf 'hi\n' > "$A/README"; mkbase app
mkwc app 1 "$A/.ai-containers"; mkwc app 2 "$W/link/alpha/.ai-containers"
cp "$ENG/projects.conf" "$TMP/conf.before"
mvrun "$A" "$W/new" --yes; rc=$?
ok "PRJ-14 mv refuses two copies of one repo that would take one new name, before the question, naming both" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: the working copies ai-containers-repo-app--wc-1 (launched from $2/.ai-containers) and" "$3" \
           && grep -qF "ai-containers-repo-app--wc-2 (launched from $4/.ai-containers) are of one repo" "$3" \
           && ! grep -qF "Move all of the above?" "$3" && [ -d "$2/.ai-containers" ] && [ ! -e "$5/.ai-containers" ] && cmp -s "$6" "$7" \
           && [ -d "$8/ai-containers-repo-app--wc-1" ] && [ -d "$8/ai-containers-repo-app--wc-2" ]' \
  _ "$rc" "$A" "$TMP/out" "$W/link/alpha" "$W/new" "$ENG/projects.conf" "$TMP/conf.before" "$VOLS"

# a checkout whose .git is a file naming its git directory
world
A="$W/alpha"; mvproj "$A"
git init -q --separate-git-dir "$W/gitdir" "$A" 2>/dev/null && git -C "$A" add .ai-containers
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv notes that the old repository tracks .ai-containers when its .git is a file" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.git" ] && grep -qxF "NOTE: $2'"'"'s repository tracks .ai-containers/; those files now show as deleted there." "$3"' \
  _ "$rc" "$A" "$TMP/out"

# whose copies: this home's are carried and labelled this home's; another
# home's, launched from the same path on a shared daemon, stay
world; A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkbase lib; WC_OWNER="$OTHER" mkwc lib 1 "$A/.ai-containers"
mvrun "$A" "$N" --yes; rc=$?
ok "mv labels the copy it makes with this home's owner id, and leaves another home's copy of the same launch dir" \
  bash -c '[ "$1" = 0 ] && grep -qxF "ai-containers.owner=$4" "$2/$3/labels" && [ -d "$2/ai-containers-repo-lib--wc-1" ] \
           && grep -qxF "ai-containers.launch-dir=$5/.ai-containers" "$2/ai-containers-repo-lib--wc-1/labels" \
           && ! grep -q "^docker volume create .*ai-containers.repo=lib" "$6"' _ "$rc" "$VOLS" "$nv" "$OWN" "$A" "$DOCKER_LOG"
ok "  … listing it as staying, and why" \
  hasx "  working copy ai-containers-repo-lib--wc-1 (lib) — stays: made by another home or user on this docker"
world; A="$W/alpha"; mvproj "$A"; N="$W/beta"; nv="$(wcname app "$N/.ai-containers")"
mkvol "$nv" "ai-containers.workcopy=1" "ai-containers.repo=app" "ai-containers.launch-dir=$N/.ai-containers" "ai-containers.owner=$OTHER"
wcdata "$nv" unpushed
mvrun "$A" "$N" --yes; rc=$?
ok "mv does not take another home's copy at the new name for one a run cut short made, though it is exact" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: the working copy $3 would be copied to $4, which exists and is not an exact copy" "$2" \
           && [ -d "$5/$3" ] && [ -d "$5/$4" ]' _ "$rc" "$TMP/out" "$OLDWC" "$nv" "$VOLS"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
# a copy launched from a directory in the project that holds a launcher of its own
world; A="$W/alpha"; mvproj "$A"; mkdir -p "$A/.ai-containers/base"
: > "$A/.ai-containers/base/sandbox.sh"; : > "$A/.ai-containers/base/sandbox-common.sh"
mkwc app 2 "$A/.ai-containers/base"; N="$W/beta"
mvrun "$A" "$N" --yes; rc=$?
ok "mv leaves a working copy launched from a directory in the setup that holds a launcher of its own" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && grep -qxF "ai-containers.launch-dir=$3/.ai-containers/base" "$2/ai-containers-repo-app--wc-2/labels"' \
  _ "$rc" "$VOLS" "$A"
ok "  … listing it as staying, and why" \
  hasx "  working copy ai-containers-repo-app--wc-2 (app) — stays: launched from $A/.ai-containers/base, which holds a launcher of its own"

# the pointers the launcher mounts beside the working directory
clash $'VAULT_PATH=/x/notes\n' "$W/new/vault" "and VAULT_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/vault" \
  "mv refuses a <new-dir> named vault where VAULT_PATH is set"
clash $'SPECS_PATH=/x/plans\n' "$W/new/specs" "and SPECS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/specs" \
  "mv refuses a <new-dir> named specs where SPECS_PATH is a host path"
clash $'DOCS_PATH=/x/manual:ro\n' "$W/new/docs" "and DOCS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/docs" \
  "mv refuses a <new-dir> named docs where DOCS_PATH is a host path, its :ro aside"
clash $'ARCHITECTURE_REPO_PATH=~/adr:rw\n' "$W/new/architecture" "and ARCHITECTURE_REPO_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/architecture" \
  "mv refuses a <new-dir> named architecture where ARCHITECTURE_REPO_PATH is set"
clash $'DOCS_PATH=@manual:ro\n' "$W/new/manual" "and DOCS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/manual" \
  "mv refuses a <new-dir> with the name of the repo an @name pointer attaches"
clash $'SPECS_PATH=@plans\n' "$W/new/plans" "and SPECS_PATH (set in $W/alpha/.ai-containers/sandbox.local.env) would both be mounted at /workspace/plans" \
  "mv refuses a <new-dir> with the name of SPECS_PATH's @name"
clash "VAULT_PATH=$W/new/vault"$'\n' "$W/new/vault" "/workspace/vault" \
  "mv refuses a <new-dir> named vault that VAULT_PATH itself names: the launcher mounts it twice"
export DOCS_PATH=/x/manual
clash '' "$W/new/docs" "and DOCS_PATH (set in your shell) would both be mounted at /workspace/docs" \
  "mv refuses a <new-dir> named docs where the shell sets DOCS_PATH"
export DOCS_PATH=''
world; A="$W/alpha"; mvproj "$A" '' $'DOCS_PATH=/x/manual\n'
mvrun "$A" "$W/new/docs" --yes; rc=$?
unset DOCS_PATH
ok "mv takes the shell's empty DOCS_PATH over the project's, as the launcher does" bash -c '[ "$1" = 0 ]' _ "$rc"

# EXTRA_MOUNTS and REPOS the shell exports: the launcher reads them over the
# project's sandbox.local.env, so mv checks them too, and says when the old root
# it adds to that file is not in the shell's list (it cannot write the shell).
export EXTRA_MOUNTS=/x/gamma
clash '' "$W/new/gamma" "and the EXTRA_MOUNTS entry /x/gamma (set in your shell) would both be mounted at /workspace/gamma" \
  "mv refuses a <new-dir> with the basename of an EXTRA_MOUNTS entry the shell sets"
export EXTRA_MOUNTS='/x/one ../shared'
relative '' "the EXTRA_MOUNTS entry ../shared in your shell is relative" "mv refuses a relative EXTRA_MOUNTS entry the shell sets, naming it and the shell"
unset EXTRA_MOUNTS
export REPOS='lib:ro delta:rw'
clash '' "$W/new/delta" "and the REPOS repo delta (set in your shell) would both be mounted at /workspace/delta" \
  "mv refuses a <new-dir> with the name of a REPOS repo the shell sets"
unset REPOS
# Not the engine's own: project.sh loads this checkout's sandbox.local.env into
# itself, and that is not what a project's launcher reads.
printf 'EXTRA_MOUNTS=/x/gamma\nREPOS=delta:rw\n' > "$ENG/sandbox.local.env"
world; A="$W/alpha"; mvproj "$A"
mvrun "$A" "$W/new/gamma" --yes; rc=$?
world; A="$W/alpha"; mvproj "$A"
mvrun "$A" "$W/new/delta" --yes; rc3=$?
rm -f "$ENG/sandbox.local.env"
ok "mv does not take the engine checkout's own EXTRA_MOUNTS or REPOS for the shell's" \
  bash -c '[ "$1" = 0 ] && [ "$2" = 0 ] && [ -f "$3/new/delta/.ai-containers/sandbox.env" ]' _ "$rc" "$rc3" "$W"
# The old root added to sandbox.local.env, which the shell's EXTRA_MOUNTS
# shadows: said before the question and again at the end.
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS=/x/one
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS does not mount the old root still adds it to sandbox.local.env" \
  bash -c '[ "$1" = 0 ] && grep -qxF "EXTRA_MOUNTS=\"$2\"" "$3/.ai-containers/sandbox.local.env"' _ "$rc" "$A" "$N"
ok "  … warning before the question that the shell's list does not mount it" \
  bash -c 'grep -qxF "WARNING: your shell exports EXTRA_MOUNTS, which the launcher reads instead of sandbox.local.env," "$1" \
           && grep -qxF "         and it does not mount $2: add it there, or the container will not see that" "$1" \
           && [ "$(grep -n "^WARNING: your shell" "$1" | cut -d: -f1)" -lt "$(grep -n "^Copied " "$1" | cut -d: -f1)" ]' _ "$TMP/out" "$A"
ok "  … and again at the end" hasx "WARNING: add $A to the EXTRA_MOUNTS your shell exports: the launcher reads that one, not"
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS="/x/one $W"
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS mounts the old root read-write warns of nothing" \
  bash -c '[ "$1" = 0 ] && ! grep -q "your shell" "$2"' _ "$rc" "$TMP/out"
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS="$W:ro"
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS mounts the old root only read-only says so, naming the entry" \
  bash -c '[ "$1" = 0 ] && grep -qxF "         and mounts $2 only read-only ($3:ro): add $2 to it, or the container" "$4"' _ "$rc" "$A" "$W" "$TMP/out"
# The launcher mounts the shell's EXTRA_MOUNTS or sandbox.local.env's, never
# both: the old root mv adds to the file cannot clash with a shell entry, and
# listing the old root there, as the warning says to, must not stop mv.
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS="$A"
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where the shell's EXTRA_MOUNTS lists the old root itself moves, warning of nothing" \
  bash -c '[ "$1" = 0 ] && ! grep -q "your shell" "$2" && grep -qxF "EXTRA_MOUNTS=\"$3\"" "$4/.ai-containers/sandbox.local.env"' _ "$rc" "$TMP/out" "$A" "$N"
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS=/mnt/other/alpha
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv where a shell entry has the old root's basename moves, and says that adding it there would clash" \
  bash -c '[ "$1" = 0 ] && grep -qxF "         Its entry /mnt/other/alpha has the same basename, /workspace/alpha: the launcher would refuse" "$2"' _ "$rc" "$TMP/out"
# The closing warning is not lost when a later step fails.
world; A="$W/alpha"; mvproj "$A"; N="$W/new/beta"
export EXTRA_MOUNTS=/x/one FAKE_FAIL_VOLUME_RM='*--wc-1'
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS FAKE_FAIL_VOLUME_RM
ok "mv that fails to remove an old working copy still says to add the old root to the shell's EXTRA_MOUNTS" \
  bash -c '[ "$1" = 1 ] && grep -qxF "WARNING: add $2 to the EXTRA_MOUNTS your shell exports: the launcher reads that one, not" "$3"' _ "$rc" "$A" "$TMP/out"
ok "  … and to run it again once that copy can be removed" \
  has_line "ERROR: not every old working copy could be removed (see above); once they can be, run"

# A step after the move that fails stops mv there, exit 1, and a run again
# finishes: sandbox.local.env that cannot be written, then projects.conf, then
# image-projects.conf.
fake_mktemp
world; A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"; N="$W/new/beta"
FAKE_MKTEMP_BAD='.sandbox.local.env.*' FAKE_MKTEMP_HOW=dir mvrun "$A" "$N" --yes; rc=$?
ok "mv exits 1 when it cannot add the old root to EXTRA_MOUNTS, the registry as it was" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: $2 is not in EXTRA_MOUNTS yet" "$3" && ! grep -qF "OK: moved" "$3" && [ -d "$4/.ai-containers" ] \
           && cmp -s "$5" "$6"' _ "$rc" "$A" "$TMP/out" "$N" "$ENG/projects.conf" "$TMP/conf.before"
FAKE_MKTEMP_BAD='.projects.conf.new.*' FAKE_MKTEMP_HOW=dir mvrun "$A" "$N" --yes; rc=$?
ok "  … run again, exits 1 when it cannot rewrite the projects.conf line, the image kept" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: " "$2" && ! grep -qF "OK: moved" "$2" && cmp -s "$3" "$4" && [ -e "$5" ]' \
  _ "$rc" "$TMP/out" "$ENG/projects.conf" "$TMP/conf.before" "$IMGS/img-alpha"
FAKE_MKTEMP_BAD='.image-projects.conf.new.*' FAKE_MKTEMP_HOW=dir mvrun "$A" "$N" --yes; rc=$?
ok "  … and again, exits 1 when it cannot drop the image-projects.conf line, saying to run it again" \
  bash -c '[ "$1" = 1 ] && grep -qF "Run ./project.sh mv $2 $3 again to finish." "$4" && grep -qxF "$3" "$5" && grep -qF "$6" "$7"' \
  _ "$rc" "$A" "$N" "$TMP/out" "$ENG/projects.conf" "$ida" "$IP"
mvrun "$A" "$N" --yes; rc=$?
rm -f "$TMP/bin/mktemp"; hash -r
ok "  … and once more, finishes" \
  bash -c '[ "$1" = 0 ] && ! grep -qF "$2" "$3" && grep -qxF "$4" "$5" && ! grep -qxF "$6" "$5"' _ "$rc" "$ida" "$IP" "$N" "$ENG/projects.conf" "$A"

world; A="$W/outer/alpha"; mvproj "$A"; N="$WL/outer"
export EXTRA_MOUNTS=/x/one
mvrun "$A" "$N" --yes; rc=$?
unset EXTRA_MOUNTS
ok "mv into a directory that holds the old root, named through a link, warns of nothing about the shell's EXTRA_MOUNTS" \
  bash -c '[ "$1" = 0 ] && grep -qF "lies inside $3, which the container mounts" "$2" && ! grep -q "your shell" "$2"' _ "$rc" "$TMP/out" "$N"
world; A="$W/alpha"; N="$W/new/docs"; mvproj "$A" '' "DOCS_PATH=$N:ro"$'\n'
mvrun "$A" "$N" --yes; rc=$?
ok "mv takes a <new-dir> named docs that DOCS_PATH itself names: the launcher mounts the working directory once" \
  bash -c '[ "$1" = 0 ] && [ -f "$2/.ai-containers/sandbox.env" ]' _ "$rc" "$N"
world; A="$W/docs"; mvproj "$A" '' $'DOCS_PATH=/x/manual\n'
mvrun "$A" "$W/new/beta" --yes; rc=$?
ok "mv refuses an old root named docs it would add to EXTRA_MOUNTS where DOCS_PATH is set" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: $2, which mv would add to EXTRA_MOUNTS, and DOCS_PATH (set in $2/.ai-containers/sandbox.local.env) would both be mounted at" "$3" \
           && [ ! -e "$4" ]' _ "$rc" "$A" "$TMP/out" "$W/new/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# a read-only entry that covers the old root: it was the read-write working
# directory, and the container must not see it read-only after the move
world; A="$W/alpha"; mvproj "$A" '' "EXTRA_MOUNTS=\"/x/one $W:ro\""$'\n'; N="$W/new/beta"
mvrun "$A" "$N" --yes; rc=$?
printf 'EXTRA_MOUNTS="\n  /x/one\n  %s:ro\n  %s\n"\n' "$W" "$A" > "$TMP/expect"
ok "mv adds the old root itself where only a read-only entry covers it" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$N/.ai-containers/sandbox.local.env" "$TMP/expect"
ok "  … saying why" hasx "              $W:ro covers it read-only, and it was the read-write working directory"

# interrupted while it copies the working copies: what it made goes again
world; A="$W/alpha"; mvproj "$A"; mkbase lib; mkwc lib 1 "$A/.ai-containers"; wcdata ai-containers-repo-lib--wc-1 libwork
N="$W/new/beta"; nva="$(wcname app "$N/.ai-containers")"; nvl="$(wcname lib "$N/.ai-containers")"
export FAKE_RUN_TERM=2
mvrun "$A" "$N" --yes; rc=$?
unset FAKE_RUN_TERM
ok "mv interrupted while it copies the working copies removes those it made, the one it was making too" \
  bash -c '[ "$1" = 143 ] && [ ! -e "$2/$3" ] && [ ! -e "$2/$4" ] && [ "$(cat "$2/$5/data/work")" = unpushed ] \
           && [ "$(cat "$2/ai-containers-repo-lib--wc-1/data/work")" = libwork ] && [ -f "$6/.ai-containers/sandbox.env" ] \
           && [ ! -e "$7" ] && cmp -s "$8" "$9"' _ "$rc" "$VOLS" "$nva" "$nvl" "$OLDWC" "$A" "$N" "$ENG/projects.conf" "$TMP/conf.before"
ok "  … naming the real <new-dir>, and the command that finishes" \
  bash -c 'grep -qxF "ERROR: interrupted; what was done is listed above, and no temporary copy is left in $2." "$1" \
           && grep -qF "run ./project.sh mv $3 $2 again" "$1"' _ "$TMP/out" "$N" "$A"

# another REPO_VOLUME_PREFIX in the project's sandbox.local.env
world; A="$W/alpha"; mvproj "$A" '' $'REPO_VOLUME_PREFIX=other\n'
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses a project whose sandbox.local.env sets another REPO_VOLUME_PREFIX, saying how to run it" \
  bash -c '[ "$1" = 1 ] && grep -qxF "         REPO_VOLUME_PREFIX=other ./project.sh mv $2 $3" "$4" && [ ! -e "$3" ]' _ "$rc" "$A" "$W/beta" "$TMP/out"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# a stopped container that uses an old copy: docker would refuse to remove it
# once the setup had moved
world; A="$W/alpha"; mvproj "$A"
printf 'ctr-old|some-image|/var/lib/docker/volumes/%s/_data\n' "$OLDWC" > "$FAKE_STOPPED"
mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses up front when a stopped container uses an old working copy, naming it and docker rm" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: the working copy $2 is used by the container(s) ctr-old" "$3" && grep -qF "(docker rm ctr-old;" "$3" \
           && [ ! -e "$4" ]' _ "$rc" "$OLDWC" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"
# and a docker that cannot list the containers that use one
mkdir -p "$TMP/bin-vps"
printf '#!/usr/bin/env bash\nif [[ "$1" == ps && " $* " == *" volume="* ]]; then echo "Error: cannot list containers" >&2; exit 1; fi\nexec %q "$@"\n' \
  "$TMP/bin/docker" > "$TMP/bin-vps/docker"
chmod +x "$TMP/bin-vps/docker"
PATH="$TMP/bin-vps:$PATH" mvrun "$A" "$W/beta" --yes; rc=$?
ok "mv refuses when docker cannot say which containers use an old working copy" \
  bash -c '[ "$1" = 1 ] && grep -qF "ERROR: docker could not list the containers, so whether one uses the working copy $2 cannot" "$3" \
           && [ ! -e "$4" ]' _ "$rc" "$OLDWC" "$TMP/out" "$W/beta"
ok "  … changing nothing" moved_nothing "$A" "$TMP/conf.before"

# a <new-dir> registered already
world; A="$W/alpha"; mvproj "$A" $'IMAGE_NAME=img-alpha\n'
N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"; printf '%s/\n' "$N" >> "$ENG/projects.conf"
built "$N" img-alpha
fake_mktemp
FAKE_MKTEMP_BAD='.projects.conf.new.*' FAKE_MKTEMP_HOW=dir mvrun "$A" "$N" --yes; rc=$?
rm -f "$TMP/bin/mktemp"; hash -r
ok "mv into a <new-dir> registered already exits 1 when it cannot remove the old line" \
  bash -c '[ "$1" = 1 ] && grep -qxF "$2" "$3" && ! grep -qF "OK: moved" "$4"' _ "$rc" "$A" "$ENG/projects.conf" "$TMP/out"
mvrun "$A" "$N" --yes; rc=$?
if [[ "$rc" == 0 && "$(sed -n 2p "$TMP/out")" == "WARNING: $N/ is a registered project already, IMAGE_NAME img-alpha: mv takes its .ai-containers" ]]; then
  pass "mv into a <new-dir> registered already warns first, naming its IMAGE_NAME"
else
  fail "mv into a <new-dir> registered already warns first, naming its IMAGE_NAME (rc=$rc; lines 1-3: $(sed -n 1,3p "$TMP/out" | tr '\n' '|'))"
fi
ok "  … and leaves one projects.conf line for it, as it was spelled" bash -c '[ "$(cat "$1")" = "$2/" ]' _ "$ENG/projects.conf" "$N"
ok "  … listing the old line as removed, and the image as the new place's" \
  bash -c 'grep -qxF "  registry    $1 (projects.conf, its line removed: $2 is there already)" "$3" \
           && grep -qxF "  image       img-alpha — kept: it was built for the new place already" "$3"' _ "$A" "$N" "$TMP/out"
world; A="$W/alpha"; mvproj "$A"; N="$W/moved"; mkdir -p "$N"; mv "$A/.ai-containers" "$N/.ai-containers"
printf '/x/other\n%s/\n' "$N" > "$ENG/projects.conf"
mvrun "$A" "$N" --yes; rc=$?
ok "mv of a project gc dropped, into a <new-dir> registered under another spelling, adds no second line" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "/x/other\n%s/" "$3")" ]' _ "$rc" "$ENG/projects.conf" "$N"
ok "  … and does not take an image that is not there for one built for the new place" lacks "built for the new place"


world; S="$W/my proj"; mkproj "$S"; mkbase app; mkwc app 1 "$S/.ai-containers"; wcdata "$OLDWC" unpushed
N="$W/new place/proj two"; export FAKE_FAIL_VOLUME_RM="$OLDWC"
mvrun "$S" "$N" --yes
unset FAKE_FAIL_VOLUME_RM
ok "mv's run-it-again command keeps both paths with a space as one argument each" \
  bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(cmd_word "again to remove them" "       " " again" 3)" "$S" \
  "$(cmd_word "again to remove them" "       " " again" 4)" "$N"
world; S="$W/my proj"; mkproj "$S"; mkbase app; mkwc app 1 "$S/.ai-containers"; wcdata "$OLDWC" unpushed
N="$W/new place/proj two"; export FAKE_RUN_TERM=1
mvrun "$S" "$N" --yes
unset FAKE_RUN_TERM
ok "mv's command after an interrupt keeps both paths with a space as one argument each" \
  bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(cmd_word "again to move the project" "; run " " again" 3)" "$S" \
  "$(cmd_word "again to move the project" "; run " " again" 4)" "$N"

# _prj_registered_as, which mv asks: a <new-dir> registered through a link is
# registered already, and its line is kept as it was spelled
world; A="$W/alpha"; mkproj "$A"; N="$W/moved"; mkdir -p "$N"; ln -s "$W" "$TMP/wlink"
printf '%s\n' "$TMP/wlink/moved" >> "$ENG/projects.conf"
mvrun "$A" "$N" --yes; rc=$?
ok "mv into a <new-dir> registered through a link keeps that one line, as spelled" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$3" ] && [ -d "$4/.ai-containers" ]' _ "$rc" "$ENG/projects.conf" "$TMP/wlink/moved" "$N"
rm -f "$TMP/wlink"

# ── GAP-28: the move helpers ──
# The helpers mv runs, driven one at a time: project.sh sourced in a subshell
# (it returns before its dispatch), and the command a helper runs replaced by a
# function where a whole mv cannot reach the failure (feature-gaps review
# GAP-28). Each check prints `ok <name>` or `no <name>`, counted below; `end`
# says the batch ran to its last check.
world; GH="$TMP/gap28"; mkdir -p "$GH"
( cd "$TMP" && source "$P" && set +e
  chk() { if "${@:2}"; then printf 'ok %s\n' "$1"; else printf 'no %s\n' "$1"; fi; }
  mkdir -p "$GH/f/sub" "$GH/p" "$GH/t" "$GH/w" "$GH/tr"
  printf 'x\n' > "$GH/tr/file"; ln -s file "$GH/tr/link"
  ghp="$(cd "$GH" && pwd -P)"

  # _prj_rebase: a path outside <from> gives nothing, rc 0 (cmd_mv assigns it)
  r="$(_prj_rebase "$GH/p" "$GH/f" "$GH/t")"; rc=$?
  chk "_prj_rebase: a path outside the old place gives nothing, rc 0" [ "$rc:$r" = "0:" ]
  r="$(_prj_rebase "$GH/f/sub" "$GH/f" "$GH/t")"
  chk "_prj_rebase: a path inside the old place is the same place under the new" [ "$r" = "$GH/t/sub" ]
  # _prj_dev: a stat that fails is no device, not an empty one (two empty ones match)
  r="$( stat() { return 1; }; _prj_dev "$GH" )"; rc=$?
  chk "_prj_dev: a stat that fails is rc 1" [ "$rc:$r" = "1:" ]
  # _prj_tree: whatever cannot be read is rc 1, not a shorter tree
  _prj_tree "$GH/none" >/dev/null 2>&1; rc=$?
  chk "_prj_tree: a directory it cannot enter is rc 1" [ "$rc" = 1 ]
  ( readlink() { return 1; }; _prj_tree "$GH/tr" ) >/dev/null 2>&1; rc=$?
  chk "_prj_tree: a link it cannot read is rc 1" [ "$rc" = 1 ]
  ( cksum() { return 1; }; _prj_tree "$GH/tr" ) >/dev/null 2>&1; rc=$?
  chk "_prj_tree: a file it cannot checksum is rc 1" [ "$rc" = 1 ]
  # _prj_ino: no inode is rc 1
  _prj_ino "$GH/none" >/dev/null 2>&1; rc=$?
  chk "_prj_ino: a path that is not there is rc 1" [ "$rc" = 1 ]
  ( ls() { printf 'x y\n'; }; _prj_ino "$GH" ) >/dev/null 2>&1; rc=$?
  chk "_prj_ino: an ls that prints no number is rc 1" [ "$rc" = 1 ]
  # _prj_mv_to's probe takes -T only from an mv -T that succeeded AND moved
  mkdir -p "$GH/m1" "$GH/m3"
  ( _prj_mv_T=""
    mv() { if [[ "$1" == -T && "$2" == */a ]]; then command cp -R "$2" "$3"; return 0; fi; command mv "$@"; }
    _prj_mv_to "$GH/m1" "$GH/m2"
    chk "_prj_mv_to: an mv -T that leaves its source is not taken" [ "$_prj_mv_T" = 0 ] )
  ( _prj_mv_T=""
    mv() { if [[ "$1" == -T && "$2" == */a ]]; then command mv "$2" "$3"; return 1; fi; command mv "$@"; }
    _prj_mv_to "$GH/m3" "$GH/m4"
    chk "_prj_mv_to: an mv -T that fails is not taken, whatever it did" [ "$_prj_mv_T" = 0 ] )
  # _prj_where: rc 0 whether it finds the inode or not (cmd_mv assigns it)
  ino="$(_prj_ino "$GH/w")"
  r="$(_prj_where "$ino" "$GH/none" "$GH/w")"; rc=$?
  chk "_prj_where: the path with the inode, rc 0" [ "$rc:$r" = "0:$ghp/w" ]
  r="$(_prj_where "$ino" "$GH/none")"; rc=$?
  chk "_prj_where: nothing, rc 0, where no path has it" [ "$rc:$r" = "0:" ]

  # _prj_move_dot. md <n>: an old setup holding a file, and the new root, empty.
  md() { O="$GH/md$1/old/.ai-containers"; R="$GH/md$1/new"; N="$R/.ai-containers"; mkdir -p "$O" "$R"; printf 'k\n' > "$O/keep"; }
  md 1; mkdir "$N"
  _prj_move_dot "$O" "$R" 2>/dev/null; rc=$?
  chk "_prj_move_dot: a directory at the new name refuses, rc 1, and nothing moves" \
    eval '[ "$rc" = 1 ] && [ -f "$O/keep" ] && [ -z "$(ls -A "$N")" ]'
  md 2; mv "$O" "$GH/md2/real"; ln -s "$GH/md2/real" "$O"
  _prj_move_dot "$O" "$R" 2>/dev/null; rc=$?
  chk "_prj_move_dot: an old setup that is a link refuses, rc 1, and the link stays" \
    eval '[ "$rc" = 1 ] && [ -L "$O" ] && [ ! -e "$N" ] && [ ! -L "$N" ]'
  md 3
  ( mv() { command mv "$@"; local r=$?; if [[ "${!#}" == "$N" ]]; then mkdir -p "$O"; fi; return "$r"; }
    _prj_move_dot "$O" "$R" 2>/dev/null; rc=$?
    chk "_prj_move_dot: a rename after which the old name is there again is rc 1" [ "$rc" = 1 ] )
  md 4
  ( export AI_CONTAINERS_MV_COPY=1; mktemp() { return 1; }
    _prj_move_dot "$O" "$R" 2>/dev/null; rc=$?
    chk "_prj_move_dot: no temporary directory in the new root is rc 1, the setup kept" \
      eval '[ "$rc" = 1 ] && [ -f "$O/keep" ]' )
  md 5
  ( export AI_CONTAINERS_MV_COPY=1
    cp() { command cp "$@"; local r=$?; mkdir -p "$N"; return "$r"; }
    _prj_move_dot "$O" "$R" 2>/dev/null; rc=$?
    chk "_prj_move_dot: a directory put at the new name during the copy refuses, rc 1, the setup kept" \
      eval '[ "$rc" = 1 ] && [ -f "$O/keep" ] && [ -z "$(ls -A "$N")" ]' )
  md 6
  ( export AI_CONTAINERS_MV_COPY=1; _prj_mv_to() { return 1; }
    _prj_move_dot "$O" "$R" 2>"$GH/md6.err"; rc=$?
    chk "_prj_move_dot: a checked copy that cannot be renamed is removed, rc 1, the setup kept" \
      eval '[ "$rc" = 1 ] && [ -f "$O/keep" ] && [ -z "$(ls -A "$R")" ]'
    chk "_prj_move_dot: ... and says so" grep -qF 'could not move the checked copy' "$GH/md6.err" )
  md 7
  ( export AI_CONTAINERS_MV_COPY=1
    rm() { command rm "$@"; local r=$?; if [[ "${!#}" == "$O" ]]; then mkdir -p "$O"; fi; return "$r"; }
    _prj_move_dot "$O" "$R" 2>/dev/null; rc=$?
    chk "_prj_move_dot: the copy in place but the old name there again is rc 2" \
      eval '[ "$rc" = 2 ] && [ -f "$N/keep" ]' )

  # prj_copy_volume and _prj_unmake, against the fake docker's volumes
  mkvol src "ai-containers.workcopy=1"; wcdata src work
  mkvol taken "ai-containers.workcopy=1"
  prj_copy_volume src taken app /x 2>/dev/null; rc=$?
  chk "prj_copy_volume: a volume of that name already is rc 1" [ "$rc" = 1 ]
  ( export FAKE_DOCKER_DOWN=1; prj_copy_volume src fresh app /x 2>/dev/null; rc=$?
    chk "prj_copy_volume: a volume that cannot be created is rc 1" [ "$rc" = 1 ] )
  ( export FAKE_COPY_BAD=1; prj_copy_volume src bad app /x 2>"$GH/cv.err"; rc=$?
    chk "prj_copy_volume: a copy that differs is rc 1 and removed" eval '[ "$rc" = 1 ] && [ ! -d "$VOLS/bad" ]'
    chk "prj_copy_volume: ... with no NOTE that it could not be" eval '! grep -qF "could not remove the failed copy" "$GH/cv.err"' )
  mkvol made1 "ai-containers.workcopy=1"
  _prj_unmake made1 2>"$GH/um.err"
  chk "_prj_unmake: a copy removed is said to be" eval 'grep -qF "Removed the new copy made1 again." "$GH/um.err" && [ ! -d "$VOLS/made1" ]'

  # _prj_load_init: a project-init.sh that fails, or lacks emit_env_list, is rc 1
  mkdir -p "$GH/init1" "$GH/init2"; printf 'return 1\n' > "$GH/init1/project-init.sh"; printf 'true\n' > "$GH/init2/project-init.sh"
  ( _here="$GH/init1"; _prj_init_loaded=""; _prj_load_init; rc=$?
    chk "_prj_load_init: a project-init.sh that fails is rc 1" [ "$rc" = 1 ] )
  ( _here="$GH/init2"; _prj_init_loaded=""; unset -f emit_env_list; _prj_load_init; rc=$?
    chk "_prj_load_init: a project-init.sh with no emit_env_list is rc 1" [ "$rc" = 1 ] )
  # prj_add_mount: every failure is rc 1, and the file is not written
  mkdir -p "$GH/pa/.ai-containers" "$GH/pa-old"
  ( _here="$GH/init1"; _prj_init_loaded=""; prj_add_mount "$GH/pa/.ai-containers" "$GH/pa-old" 2>/dev/null; rc=$?
    chk "prj_add_mount: emit_env_list not loaded is rc 1" [ "$rc" = 1 ] )
  # project-init.sh, loaded, sets -e again: off, so that a status can be read
  _prj_load_init; set +e
  ( mktemp() { return 1; }; prj_add_mount "$GH/pa/.ai-containers" "$GH/pa-old" 2>/dev/null; rc=$?
    chk "prj_add_mount: no temporary directory is rc 1" [ "$rc" = 1 ] )
  ( _prj_mounts_rewrite() { return 1; }; prj_add_mount "$GH/pa/.ai-containers" "$GH/pa-old" 2>/dev/null; rc=$?
    chk "prj_add_mount: a rewrite that fails is rc 1, nothing written" \
      eval '[ "$rc" = 1 ] && [ ! -e "$GH/pa/.ai-containers/sandbox.local.env" ]' )
  ( _proj_write() { return 1; }; prj_add_mount "$GH/pa/.ai-containers" "$GH/pa-old" 2>/dev/null; rc=$?
    chk "prj_add_mount: a write that fails is rc 1" [ "$rc" = 1 ] )
  # _prj_mount_dir: a ':' that does not start options belongs to the path
  chk "_prj_mount_dir: /x:y is a path" [ "$(_prj_mount_dir /x:y)" = /x:y ]
  chk "_prj_mount_dir: /x:ro,z is /x and its options" [ "$(_prj_mount_dir /x:ro,z)" = /x ]
  # _prj_env_dump: what the file sets, and nothing this shell exported
  printf 'GAP28_SET=bar\nEXTRA_MOUNTS=/a\n' > "$GH/env1"
  r="$( export GAP28_LEAK=1; _prj_env_dump "$GH/env1" EXTRA_MOUNTS )"
  chk "_prj_env_dump: the file's keys but the one named, and no exported one" [ "$r" = "GAP28_SET=bar" ]

  # _prj_tracks_dot: only a .git git takes, and a commondir it can read
  mkdir -p "$GH/repo/.ai-containers" "$GH/td1" "$GH/td2" "$GH/td3" "$GH/td4/.git"
  printf 'x\n' > "$GH/repo/.ai-containers/f"
  git init -q "$GH/repo" && git -C "$GH/repo" add .ai-containers/f
  printf 'gitdir: %s\n' "$GH/repo/.git" > "$GH/td1/.git"
  printf '%s\n' "$GH/repo/.git" > "$GH/td2/.git"
  ln -s "$GH/repo/.git" "$GH/td3/.git"
  printf '../nowhere\n' > "$GH/td4/.git/commondir"
  chk "_prj_tracks_dot: a .git file naming a repository that tracks it is rc 0" _prj_tracks_dot "$GH/td1"
  chk "_prj_tracks_dot: a .git file without gitdir: is rc 1" eval '! _prj_tracks_dot "$GH/td2"'
  chk "_prj_tracks_dot: a .git link is rc 1" eval '! _prj_tracks_dot "$GH/td3"'
  chk "_prj_tracks_dot: a commondir naming nothing is rc 1" eval '! _prj_tracks_dot "$GH/td4"'
  printf 'end\n'
) > "$TMP/gap28.out" 2>"$TMP/gap28.err"
while read -r v name; do
  case "$v" in ok) pass "$name" ;; no) fail "$name" ;; esac
done < "$TMP/gap28.out"
# Every check, nested subshells too: one that dies before its chk prints nothing.
ok "the move helpers' checks ran to their end, all 38 of them" \
  eval 'grep -qx end "$TMP/gap28.out" && [ "$(grep -cE "^(ok|no) " "$TMP/gap28.out")" = 38 ]'
echo
# shellcheck disable=SC2154  # fails is the counter tests/lib-project-tool.sh defines
[[ "$fails" == 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILED"; exit 1; }
