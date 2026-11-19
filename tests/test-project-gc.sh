#!/usr/bin/env bash
# shellcheck disable=SC1090  # project.sh is sourced from a computed path, on purpose
# project.sh: `gc` — what registered projects no longer need.
# Hermetic: HOME and an engine copy live in a temp dir; docker is a logging fake
# (tests/lib-project-tool.sh, shared with the other tests/test-project-*.sh).
# shellcheck source=tests/lib-project-tool.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-project-tool.sh" \
  || { printf 'SCAFFOLD-FAILED: cannot load tests/lib-project-tool.sh\n'; exit 1; }
# The engine copy's project.sh, named in this file so tests/falsify/derive-targets.sh,
# which reads each file's own assignments, sees that this test runs it.
P="$ENG/project.sh"

# ── gc ──
# gc's checks of what mv does after it run mv, which takes emit_env_list from
# project-init.sh: the real one, not the dispatch tests' stub.
cp -p "$REPO_DIR/project-init.sh" "$ENG/project-init.sh"
gcrun() { ( cd "$TMP" && bash "$P" gc "$@" ) > "$TMP/out" 2>&1 < /dev/null; }
# gcworld: world, with $W holding something: a path whose nearest existing
# directory is an empty one may be on a drive that is not mounted, and is kept.
gcworld() { world; mkdir -p "$W/other"; }
gc_nothing() {  # nothing was removed: no volume or image, the registries as saved
  ! logged '^docker (volume rm|rmi)' && cmp -s "$ENG/projects.conf" "$TMP/conf.before" && cmp -s "$IP" "$TMP/ip.before"
}
gc_save() { cp "$ENG/projects.conf" "$TMP/conf.before"; cp "$IP" "$TMP/ip.before"; }

gcworld
mkproj "$W/live"; mkproj "$W/alpha"; rm -rf "$W/alpha/.ai-containers"; printf 'hi\n' > "$W/alpha/README"
mkproj "$W/beta"; rm -rf "$W/beta"
gcrun --yes; rc=$?
ok "gc drops a projects.conf line whose project has no .ai-containers" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$3" ] && [ -f "$4/README" ]' _ "$rc" "$ENG/projects.conf" "$W/live" "$W/alpha"
ok "  … listing each first, with --yes too" \
  bash -c 'grep -qxF "About to remove:" "$1" && grep -qxF "  registry    $2 (projects.conf: it has no .ai-containers)" "$1" \
           && grep -qxF "  registry    $3 (projects.conf: it has no .ai-containers)" "$1"' _ "$TMP/out" "$W/alpha" "$W/beta"

gcworld
mkdir -p "$W/drive" "$W/mnt"; printf '%s\n%s\n' "$W/drive/proj" "$W/mnt" > "$ENG/projects.conf"
mkproj "$W/alpha"; rm -rf "$W/alpha"
gcrun --yes; rc=$?
ok "gc keeps and names a line whose nearest existing directory is empty" \
  bash -c '[ "$1" = 0 ] && [ "$(cat "$2")" = "$(printf "%s\n%s" "$3/drive/proj" "$3/mnt")" ] \
           && grep -qF "  registry    $3/drive/proj (projects.conf) — kept: it may be on a drive that is not mounted: $3/drive is empty" "$4" \
           && grep -qF "  registry    $3/mnt (projects.conf) — kept: it may be on a drive that is not mounted: $3/mnt is empty" "$4"' \
  _ "$rc" "$ENG/projects.conf" "$W" "$TMP/out"
ok "  … with the way out if it is gone for good" has_line "if it is gone for good, ./project.sh rm $W/drive/proj removes its line"

gcworld
mkproj "$W/live" $'IMAGE_NAME=img-live\n'
printf '# ai-containers: the project each image id names (build.sh). id|path\n' > "$IP"; built "$W/live" img-live
A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"
printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" >> "$IP"; rm -rf "$A"
idl="$(tid "$W/live/.ai-containers")"
gcrun --yes; rc=$?
printf '# ai-containers: the project each image id names (build.sh). id|path\n%s|%s\n' "$idl" "$(cd "$W/live/.ai-containers" && pwd -P)" > "$TMP/expect"
ok "gc drops an image-projects.conf line whose path is gone and whose id no image carries" \
  bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3" && [ -e "$4" ] && ! grep -q "^docker rmi" "$5"' _ "$rc" "$IP" "$TMP/expect" "$IMGS/img-live" "$DOCKER_LOG"
ok "  … and takes its comment line, though it holds a |, for no record" \
  bash -c '! grep -qF "registry    path " "$1" && ! grep -qF "(built for path" "$1"' _ "$TMP/out"
# a record after an empty line, and a last one with no newline, are read
gcworld; A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"; pa="$(cd "$A/.ai-containers" && pwd -P)"
B="$W/beta"; mkproj "$B"; idb="$(tid "$B/.ai-containers")"; pb="$(cd "$B/.ai-containers" && pwd -P)"
printf '\n%s|%s\n%s|%s' "$ida" "$pa" "$idb" "$pb" > "$IP"; rm -rf "$A" "$B"
gcrun --yes; rc=$?
ok "gc reads an image-projects.conf record after an empty line, and a last one with no newline" \
  bash -c '[ "$1" = 0 ] && grep -qxF "  registry    $2 (image-projects.conf, once no image carries its id)" "$4" \
           && grep -qxF "  registry    $3 (image-projects.conf, once no image carries its id)" "$4" \
           && ! grep -qF "$5" "$7" && ! grep -qF "$6" "$7"' _ "$rc" "$pa" "$pb" "$TMP/out" "$ida" "$idb" "$IP"

gcworld
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
pa="$(cd "$A/.ai-containers" && pwd -P)"; rm -rf "$A"
gcrun --yes; rc=$?
ok "gc lists an image whose project is gone, removes it on --yes, then drops its line" \
  bash -c '[ "$1" = 0 ] && grep -qxF "  image       img-alpha:latest (built for $2, which is gone)" "$3" && [ ! -e "$4" ] \
           && ! grep -q -- " -f" < <(grep "^docker rmi" "$5") && ! grep -qF "$6" "$7" \
           && r="$(grep -n "^docker rmi img-alpha" "$5" | cut -d: -f1)" && c="$(grep -n "^docker images -q" "$5" | tail -1 | cut -d: -f1)" \
           && [ -n "$r" ] && [ -n "$c" ] && [ "$r" -lt "$c" ]' \
  _ "$rc" "$pa" "$TMP/out" "$IMGS/img-alpha" "$DOCKER_LOG" "$ida" "$IP"
gcworld
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"; rm -rf "$A"
export FAKE_FAIL_RMI=1
gcrun --yes; rc=$?
unset FAKE_FAIL_RMI
ok "  … and keeps its line while an image it could not remove carries the id" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && grep -qF "NOTE: an image still carries" "$5"' \
  _ "$rc" "$IMGS/img-alpha" "$ida" "$IP" "$TMP/out"
gcworld
A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"
printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" > "$IP"; rm -rf "$A"
printf 'ai-containers.project=%s\n' "$ida" > "$IMGS/dangling-1"
gcrun --yes; rc=$?
ok "gc removes an image that has no tag by its id" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2" ] && grep -qxF "docker rmi dangling-1" "$3" && ! grep -qF "$4" "$5"' \
  _ "$rc" "$IMGS/dangling-1" "$DOCKER_LOG" "$ida" "$IP"

gcworld
mkproj "$W/live"; mkbase app
mkwc app 1 "$W/gone1/.ai-containers" "$CLEAN"
mkwc app 2 "$W/gone2/.ai-containers" $'PRIMARY|main\nBRANCH|main|0|current\nBRANCH|feature|2|\nWORKTREE|clean\nEND|inspect\n'
mkwc app 3 "$W/live/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc lists working copies whose launch dir is gone, with their risk, and removes them on --yes" \
  bash -c '[ "$1" = 0 ] \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $2/gone1/.ai-containers) — nothing at risk: every branch pushed, no stash, the checkout clean" "$3" \
           && grep -qF "  working copy ai-containers-repo-app--wc-2 (app, launched from $2/gone2/.ai-containers) — AT RISK: feature: 2 unpushed" "$3" \
           && grep -qxF "1 working cop(y/ies) at risk or not checked." "$3" \
           && [ "$(sed -n "s/^docker volume rm //p" "$4" | LC_ALL=C sort | tr "\n" " ")" = "ai-containers-repo-app--wc-1 ai-containers-repo-app--wc-2 " ] \
           && [ -d "$5/ai-containers-repo-app--wc-3" ]' _ "$rc" "$W" "$TMP/out" "$DOCKER_LOG" "$VOLS"

gcworld; mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
printf 'ctr-wc|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_RUNNING"
gcrun --yes; rc=$?
ok "gc keeps a working copy a running container uses" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers) — kept: a running container uses it (ctr-wc)" "$5" \
           && grep -qxF "Nothing to collect." "$5"' _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; ida="$(tid "$A/.ai-containers")"
mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"; rm -rf "$A"
printf 'ctr-old|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_STOPPED"
gcrun --yes; rc=$?
ok "gc keeps a working copy a stopped container uses, and collects the rest" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$9" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $3/gone/.ai-containers) — kept: a stopped container uses it (ctr-old); docker rm it first" "$4" \
           && [ ! -e "$5" ] && ! grep -qF "$6" "$7" && ! grep -qxF "$3/alpha" "$8"' \
  _ "$rc" "$VOLS" "$W" "$TMP/out" "$IMGS/img-alpha" "$ida" "$IP" "$ENG/projects.conf" "$DOCKER_LOG"
gcworld; mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
export FAKE_PS_FAIL=1
gcrun --yes; rc=$?
unset FAKE_PS_FAIL
ok "gc keeps a working copy when docker cannot tell whether a container uses it" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qF "ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers) — kept: docker could not list" "$5"' \
  _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"

gcworld; A="$W/alpha"; mkproj "$A"; rm -rf "$A"
gcrun; rc=$?
ok "gc points a vanished project at project.sh mv, saying what gc would cost it" \
  bash -c 'grep -qxF "              If $1 was moved rather than deleted, answer no and run ./project.sh mv $1 <new-dir>:" "$2" \
           && grep -qxF "              gc would remove the working copies launched from it, which mv carries to the new" "$2" \
           && grep -qxF "              place; after gc, mv only registers the new place." "$2" && ! grep -qF "also works after gc" "$2"' _ "$A" "$TMP/out"

gcworld
mkproj "$W/live" $'IMAGE_NAME=img-live\n'; built "$W/live" img-live; mkbase app; mkwc app 1 "$W/live/.ai-containers" "$CLEAN"
gc_save
gcrun --yes; rc=$?
ok "gc with nothing stale says so and exits 0" \
  bash -c '[ "$1" = 0 ] && grep -qxF "Nothing to collect." "$2" && ! grep -q "About to remove" "$2" && ! grep -q "^Kept:" "$2"' _ "$rc" "$TMP/out"
ok "  … changing nothing" gc_nothing

gcworld
A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
gcrun; rc=$?
ok "gc refuses on a non-TTY without --yes, changing nothing" \
  bash -c '[ "$1" = 1 ] && grep -q "About to remove" "$2" && grep -q "^ERROR: " "$2" && grep -qxF "Nothing was removed." "$2" \
           && [ -e "$3" ] && [ -d "$4/ai-containers-repo-app--wc-1" ]' _ "$rc" "$TMP/out" "$IMGS/img-alpha" "$VOLS"
ok "  … and the registries are as they were" gc_nothing

gcworld
mkdir -p "$W/live1/.ai-containers" "$W/live two/.ai-containers"
printf '# comment\n\n%s\r\n%s\nrel/proj\n%s' "$W/alpha" "$W/live two" "$W/live1" > "$ENG/projects.conf"
gcrun --yes; rc=$?
printf '# comment\n\n%s\nrel/proj\n%s' "$W/live two" "$W/live1" > "$TMP/expect"
ok "gc keeps every other projects.conf byte" bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$ENG/projects.conf" "$TMP/expect"
ok "  … and names a line that is not an absolute path, which it keeps" \
  has_line "  registry    rel/proj (projects.conf) — kept: it is not an absolute path"

# what may only look gone: a drive that is not mounted, a directory that cannot be searched
gcworld; mkdir -p "$W/drive"; idd="sha256:$(printf '%064d' 5)"
printf '%s|%s\n' "$idd" "$W/drive/proj/.ai-containers" > "$IP"; printf 'ai-containers.project=%s\n' "$idd" > "$IMGS/img-drive"
gcrun --yes; rc=$?
ok "gc keeps an image whose project path may be on an unmounted drive" \
  bash -c '[ "$1" = 0 ] && [ -e "$2" ] && grep -qF "$3" "$4" && ! grep -q "^docker rmi" "$5" \
           && grep -qxF "  image       img-drive:latest (built for $6/drive/proj/.ai-containers) — kept: it may be on a drive that is not mounted: $6/drive is empty" "$7" \
           && grep -qxF "  registry    $6/drive/proj/.ai-containers (image-projects.conf) — kept: it may be on a drive that is not mounted: $6/drive is empty" "$7"' \
  _ "$rc" "$IMGS/img-drive" "$idd" "$IP" "$DOCKER_LOG" "$W" "$TMP/out"
gcworld; mkdir -p "$W/drive"; mkbase app; mkwc app 1 "$W/drive/proj/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps a working copy whose launch dir may be on an unmounted drive" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/drive/proj/.ai-containers) — kept: it may be on a drive that is not mounted: $4/drive is empty" "$5"' \
  _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"
# a logical path (a projects.conf root, a launch dir) can cross a link whose
# target is on a drive that is not mounted: the link is there and leads nowhere
gcworld; ln -s "$W/nowhere/work" "$W/work"; mkbase app; mkwc app 1 "$W/work/proj/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps a working copy whose launch dir is reached through a link that leads nowhere" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && ! grep -q "^docker volume rm" "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/work/proj/.ai-containers) — kept: it may only look gone: $4/work is a link to something that is not there" "$5"' \
  _ "$rc" "$VOLS" "$DOCKER_LOG" "$W" "$TMP/out"
gcworld; ln -s "$W/nowhere/work" "$W/work"; printf '%s\n' "$W/work/proj" > "$ENG/projects.conf"
gcrun --yes; rc=$?
ok "gc keeps a projects.conf line whose root is reached through a link that leads nowhere" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" \
           && grep -qF "  registry    $2 (projects.conf) — kept: it may only look gone: $4/work is a link to something that is not there" "$5"' \
  _ "$rc" "$W/work/proj" "$ENG/projects.conf" "$W" "$TMP/out"
# a removable-media root (/media/<user>, /Volumes) cannot be made here: the
# helper's own test of one, with _ac_removable_root taking $W/media for one
gcworld; mkdir -p "$W/media/other"
r="$( cd "$TMP" && source "$P" && _ac_removable_root() { [[ "${1%/}" == "$W/media" ]]; } \
      && _prj_maybe_unmounted "$W/media/drive/proj/.ai-containers" )"; rc=$?
ok "gc keeps a path whose nearest existing directory is where removable drives are mounted" \
  bash -c '[ "$1" = 0 ] && [ "$2" = "it may be on a drive that is not mounted: $3/media is where removable drives are mounted" ]' _ "$rc" "$r" "$W"
if [[ "$(id -u)" == 0 ]]; then
  printf 'SKIP: a project under a directory that cannot be searched (running as root)\n'
else
  gcworld; mkproj "$W/locked/proj"; chmod 000 "$W/locked"
  gcrun --yes; rc=$?
  chmod 755 "$W/locked"
  ok "gc keeps a line under a directory it cannot search" \
    bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && grep -qF "  registry    $2 (projects.conf) — kept: it may only look gone: $4 cannot be searched" "$5"' \
    _ "$rc" "$W/locked/proj" "$ENG/projects.conf" "$W/locked" "$TMP/out"
fi

# rm's safety pattern
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
export FAKE_DOCKER_DOWN=1
gcrun --yes; rc=$?
unset FAKE_DOCKER_DOWN
ok "gc refuses when docker cannot be reached" \
  bash -c '[ "$1" = 1 ] && grep -q "^ERROR: docker cannot be reached" "$2" && [ -e "$3" ] && [ -d "$4/ai-containers-repo-app--wc-1" ]' \
  _ "$rc" "$TMP/out" "$IMGS/img-alpha" "$VOLS"
ok "  … changing nothing" gc_nothing
# the listing makes three volume= ps calls for the copy (whether a running or a
# stopped container uses it, and the git helper's read-write check); the one
# after the question sees it in use
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
printf 'ctr-late|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_RUNNING.later"
export FAKE_VOLPS_AFTER=3
gcrun --yes; rc=$?
unset FAKE_VOLPS_AFTER
ok "gc checks again after the question, and refuses a copy a container started using meanwhile" \
  bash -c '[ "$1" = 1 ] && grep -q "About to remove" "$2" && grep -q "^ERROR: .*started using .*after the listing.*ctr-late" "$2" \
           && [ -d "$3/ai-containers-repo-app--wc-1" ] && [ -e "$4" ]' _ "$rc" "$TMP/out" "$VOLS" "$IMGS/img-alpha"
ok "  … changing nothing" gc_nothing
# … and refuses when docker cannot say then: $TMP/hook holds a docker whose
# `ps --filter volume=` calls past the HOOK_VOLPS_FAIL_AFTER-th fail, the rest
# handed to the fake
mkdir -p "$TMP/hook"
cat > "$TMP/hook/docker" <<'HOOK'
#!/usr/bin/env bash
if [[ "$1" == ps && "$*" == *volume=* && -n "${HOOK_VOLPS_FAIL_AFTER:-}" ]]; then
  n=0; [[ -f "$HOOK_COUNT" ]] && n="$(cat "$HOOK_COUNT")"
  n=$((n + 1)); printf '%s\n' "$n" > "$HOOK_COUNT"
  if (( n > HOOK_VOLPS_FAIL_AFTER )); then echo "Error: cannot list containers" >&2; exit 1; fi
fi
exec "$(dirname "$0")/../bin/docker" "$@"
HOOK
chmod +x "$TMP/hook/docker"
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save; rm -f "$TMP/hook.count"
( export PATH="$TMP/hook:$PATH" HOOK_VOLPS_FAIL_AFTER=3 HOOK_COUNT="$TMP/hook.count"; gcrun --yes ); rc=$?
ok "gc refuses, exit 1, when docker cannot list the running containers after the question" \
  bash -c '[ "$1" = 1 ] && grep -q "About to remove" "$2" && grep -q "^ERROR: docker could not list the running containers, so whether one uses the working copy" "$2" \
           && [ -d "$3/ai-containers-repo-app--wc-1" ] && [ -e "$4" ]' _ "$rc" "$TMP/out" "$VOLS" "$IMGS/img-alpha"
ok "  … changing nothing" gc_nothing
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app; mkwc app 1 "$A/.ai-containers" "$CLEAN"
rm -rf "$A"; gc_save
export FAKE_FAIL_VOLUME_RM='*'
gcrun --yes; rc=$?
unset FAKE_FAIL_VOLUME_RM
ok "gc stops when a working copy cannot be removed, before the images and the registry lines" \
  bash -c '[ "$1" = 1 ] && grep -q "^ERROR: could not remove the working copy" "$2" && [ -e "$3" ] && ! grep -q "^docker rmi" "$4"' \
  _ "$rc" "$TMP/out" "$IMGS/img-alpha" "$DOCKER_LOG"
ok "  … the registries as they were" bash -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4"' _ "$ENG/projects.conf" "$TMP/conf.before" "$IP" "$TMP/ip.before"

# links: a project's .ai-containers, and the registries themselves
gcworld; mkdir -p "$W/linky"; ln -s "$W/nowhere" "$W/linky/.ai-containers"; printf '%s\n' "$W/linky" > "$ENG/projects.conf"
gcrun --yes; rc=$?
ok "gc keeps and names a line whose .ai-containers is a link" \
  bash -c '[ "$1" = 0 ] && grep -qxF "$2" "$3" && grep -qF "  registry    $2 (projects.conf) — kept: its .ai-containers is a link" "$4"' \
  _ "$rc" "$W/linky" "$ENG/projects.conf" "$TMP/out"
gcworld; mkdir -p "$W/live/.ai-containers"; printf '%s\n%s\n' "$W/live" "$W/gone" > "$TMP/real-conf"
ln -s "$TMP/real-conf" "$ENG/projects.conf"; mkbase app; mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc does not read a linked projects.conf, and still collects the rest" \
  bash -c '[ "$1" = 0 ] && [ -L "$2" ] && [ "$(cat "$3")" = "$(printf "%s\n%s" "$4/live" "$4/gone")" ] \
           && grep -qF "  registry    $2 — not read: it is a link" "$5" && [ ! -d "$6/ai-containers-repo-app--wc-1" ]' \
  _ "$rc" "$ENG/projects.conf" "$TMP/real-conf" "$W" "$TMP/out" "$VOLS"
gcworld; rm -f "$ENG/projects.conf"
A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"; rm -rf "$A"; rm -f "$ENG/projects.conf"
printf '%s|%s\n' "$ida" "$A/.ai-containers" > "$TMP/real-ip"; ln -s "$TMP/real-ip" "$IP"
printf 'ai-containers.project=%s\n' "$ida" > "$IMGS/img-alpha"
gcrun --yes; rc=$?
ok "gc does not read a linked image-projects.conf, and removes no image through it" \
  bash -c '[ "$1" = 0 ] && [ -L "$2" ] && [ -e "$3" ] && ! grep -q "^docker rmi" "$4" && grep -qF "  registry    $2 — not read: it is a link" "$5"' \
  _ "$rc" "$IP" "$IMGS/img-alpha" "$DOCKER_LOG" "$TMP/out"
rm -f "$IP"

# a project moved by hand, its line stale: gc says on its copy's line that mv
# carries that copy; after gc, mv has nothing left to carry, and says so
gcworld; A="$W/alpha"; mkproj "$A" $'IMAGE_NAME=img-alpha\n'; built "$A" img-alpha; mkbase app
mkwc app 1 "$A/.ai-containers" $'PRIMARY|main\nBRANCH|main|3|current\nWORKTREE|clean\nEND|inspect\n'; wcdata ai-containers-repo-app--wc-1 unpushed
N="$W/moved"; mv "$A" "$N"
gcrun; rc=$?
ok "gc says on the copy line of a project whose line it drops that mv would carry the copy" \
  bash -c '[ "$1" = 1 ] && awk -v c="  working copy ai-containers-repo-app--wc-1 (app, launched from $2/.ai-containers) — AT RISK: main: 3 unpushed commit(s)" \
             -v h="              From $2, listed above: if it was moved, answer no and run ./project.sh mv, which" \
             '"'"'p { ok = ($0 == h); p = 0 } $0 == c { p = 1 } END { exit !ok }'"'"' "$3"' _ "$rc" "$A" "$TMP/out"
ok "  … counting that one copy, and only it, as at risk" hasx "1 working cop(y/ies) at risk or not checked."
gcrun --yes; rc1=$?
mvrun "$A" "$N" --yes; rc2=$?
ok "  … and once gc removed it, mv only registers the new place, saying no copy is left to carry" \
  bash -c '[ "$1" = 0 ] && [ "$2" = 0 ] && [ ! -e "$3/ai-containers-repo-app--wc-1" ] && [ "$(cat "$4")" = "$5" ] \
           && grep -qxF "  working copy none launched from $6 is left to carry (./project.sh gc, run since the" "$7" \
           && ! grep -qF "Copied the working copy" "$7"' _ "$rc1" "$rc2" "$VOLS" "$ENG/projects.conf" "$N" "$A" "$TMP/out"

# whose copies gc offers: this home's; another home's, on a daemon several share,
# only with --all
gcworld; mkbase app; WC_OWNER="$OTHER" mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps a working copy another home made" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && grep -qxF "Nothing to collect." "$3" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers) — kept: made by another home or user on this docker (./project.sh gc --all offers it)" "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
gcrun --all --yes; rc=$?
ok "  … and gc --all offers it, saying whose it is, and removes it" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/gone/.ai-containers; made by another home or user on this docker) — nothing at risk: every branch pushed, no stash, the checkout clean" "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
# one with no owner label (made before there was one): offered under a path this
# home's registries know, kept elsewhere
gcworld; mkbase app; mkproj "$W/live"; printf '%s\n' "$W/stale" >> "$ENG/projects.conf"
printf 'sha256:%064d|%s\n' 4 "$W/built/.ai-containers" > "$IP"
WC_OWNER='' mkwc app 1 "$W/nowhere/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 2 "$W/stale/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 3 "$W/built/.ai-containers" "$CLEAN"
WC_OWNER='' mkwc app 4 "$W/live/gone-sub" "$CLEAN"
gcrun --yes; rc=$?
ok "gc keeps an unlabelled working copy under no path this home's registries know" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/nowhere/.ai-containers) — kept: unlabelled, under no path this home knows (./project.sh gc --all offers it)" "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
ok "  … and removes one under a stale or live projects.conf root, or a project image-projects.conf maps" \
  bash -c '[ ! -e "$1/ai-containers-repo-app--wc-2" ] && [ ! -e "$1/ai-containers-repo-app--wc-3" ] && [ ! -e "$1/ai-containers-repo-app--wc-4" ]' _ "$VOLS"
gcrun --all --yes; rc=$?
ok "  … which gc --all offers, saying it is unlabelled" \
  bash -c '[ "$1" = 0 ] && [ ! -e "$2/ai-containers-repo-app--wc-1" ] \
           && grep -qF "  working copy ai-containers-repo-app--wc-1 (app, launched from $4/nowhere/.ai-containers; unlabelled, under no path this home knows) — " "$3"' \
  _ "$rc" "$VOLS" "$TMP/out" "$W"
# with --all, another home's copy is still kept while a container, running or
# stopped, uses it, or while its launch dir may only look gone
gcworld; mkbase app
WC_OWNER="$OTHER" mkwc app 1 "$W/gone/.ai-containers" "$CLEAN"
WC_OWNER="$OTHER" mkwc app 2 "$W/gone2/.ai-containers" "$CLEAN"
printf 'ctr-run|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-1/_data\n' > "$FAKE_RUNNING"
printf 'ctr-old|some-image|/var/lib/docker/volumes/ai-containers-repo-app--wc-2/_data\n' > "$FAKE_STOPPED"
gcrun --all --yes; rc=$?
ok "gc --all keeps another home's copy a container uses, running or stopped, saying so" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-1" ] && [ -d "$2/ai-containers-repo-app--wc-2" ] && ! grep -q "^docker volume rm" "$5" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-1 (app, launched from $3/gone/.ai-containers; made by another home or user on this docker) — kept: a running container uses it (ctr-run)" "$4" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-2 (app, launched from $3/gone2/.ai-containers; made by another home or user on this docker) — kept: a stopped container uses it (ctr-old); docker rm it first" "$4"' \
  _ "$rc" "$VOLS" "$W" "$TMP/out" "$DOCKER_LOG"
gcworld; mkbase app; mkdir -p "$W/drive"; WC_OWNER="$OTHER" mkwc app 3 "$W/drive/proj/.ai-containers" "$CLEAN"
gcrun --all --yes; rc=$?
ok "gc --all keeps another home's copy whose launch dir may be on a drive that is not mounted, saying so" \
  bash -c '[ "$1" = 0 ] && [ -d "$2/ai-containers-repo-app--wc-3" ] && grep -qxF "Nothing to collect." "$4" \
           && grep -qxF "  working copy ai-containers-repo-app--wc-3 (app, launched from $3/drive/proj/.ai-containers; made by another home or user on this docker) — kept: it may be on a drive that is not mounted: $3/drive is empty" "$4"' \
  _ "$rc" "$VOLS" "$W" "$TMP/out"

gcworld; S="$W/my proj"; mkproj "$S"; rm -rf "$S"; mkdir -p "$W/drive"; printf '%s\n' "$W/drive/my proj" >> "$ENG/projects.conf"
gcrun
ok "gc's mv hint and its rm hint keep a project path with a space as one argument" \
  bash -c '[ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$(cmd_word "answer no and run ./project.sh mv" "and run " " <new-dir>" 3)" "$S" \
  "$(cmd_word "if it is gone for good" "gone for good, " " removes its line" 3)" "$W/drive/my proj"
# gc that cannot rewrite a registry it drops a line from exits 1, and leaves
# what a re-run needs: an image-projects.conf line first (the projects.conf
# lines kept), a projects.conf line last
fake_mktemp
gcworld; A="$W/alpha"; mkproj "$A"; ida="$(tid "$A/.ai-containers")"
printf '%s|%s\n' "$ida" "$(cd "$A/.ai-containers" && pwd -P)" > "$IP"; rm -rf "$A"; gc_save
( export FAKE_MKTEMP_BAD='.image-projects.conf.new.*' FAKE_MKTEMP_HOW=dir; gcrun --yes ); rc=$?
rm -rf "$HOME/.ai-containers"/.image-projects.conf.new.*
ok "gc exits 1 when an image-projects.conf line it drops cannot be rewritten, and keeps the projects.conf lines" \
  bash -c '[ "$1" = 1 ] && grep -qxF "       The projects.conf lines are kept; run ./project.sh gc again." "$2" && ! grep -q "^OK:" "$2" \
           && cmp -s "$3" "$4" && cmp -s "$5" "$6"' _ "$rc" "$TMP/out" "$ENG/projects.conf" "$TMP/conf.before" "$IP" "$TMP/ip.before"
gcworld; mkproj "$W/alpha"; rm -rf "$W/alpha"; cp "$ENG/projects.conf" "$TMP/conf.before"
( export FAKE_MKTEMP_BAD='.projects.conf.new.*' FAKE_MKTEMP_HOW=dir; gcrun --yes ); rc=$?
rm -rf "$ENG"/.projects.conf.new.*
ok "gc exits 1 when a projects.conf line it drops cannot be rewritten, saying so" \
  bash -c '[ "$1" = 1 ] && grep -q "^ERROR: cannot read .*projects.conf, or write its new content beside it" "$2" && ! grep -q "^OK:" "$2" \
           && cmp -s "$3" "$4"' _ "$rc" "$TMP/out" "$ENG/projects.conf" "$TMP/conf.before"
rm -f "$TMP/bin/mktemp"

# what a label or a registry line holds reaches the terminal without its escapes
gcworld; E="$W/esc${ESC}[2Jgone"; printf '%s\n' "$E" > "$ENG/projects.conf"; mkbase app; mkwc app 1 "$E/.ai-containers" "$CLEAN"
gcrun; rc=$?
ok "gc prints a registered root and a launch dir holding an ESC byte without it" \
  bash -c '[ "$1" = 1 ] && grep -qF "registry    $2/esc?[2Jgone (projects.conf" "$3" && grep -qF "launched from $2/esc?[2Jgone/.ai-containers" "$3" \
           && ! grep -q "$4" "$3"' _ "$rc" "$W" "$TMP/out" "$ESC"

# what it refuses on the command line, by its exit status
gcworld; mkproj "$W/alpha"; rm -rf "$W/alpha"; printf 'sha256:%064d|/nowhere\n' 3 > "$IP"; gc_save
for args in --bogus extra; do
  gcrun "$args" --yes; rc=$?
  ok "gc $args exits 1, saying why, and removes nothing" \
    bash -c '[ "$1" = 1 ] && grep -q "^ERROR: " "$2" && ! grep -q "About to remove" "$2"' _ "$rc" "$TMP/out"
  ok "  … the registries as they were" gc_nothing
done

echo
# shellcheck disable=SC2154  # fails is the counter tests/lib-project-tool.sh defines
[[ "$fails" == 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "$fails FAILED"; exit 1; }
