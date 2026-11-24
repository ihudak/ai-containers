#!/usr/bin/env bash
# Tests for group.sh — the group lifecycle surface added when the group's Ruby home
# moved from a directory into a Docker named volume.
#
# The point of group.sh: a group used to be ONLY ~/.ai-containers/<group>/, so
# `rm -rf` was the whole delete story. With ~/.rvm in a volume, deleting the
# directory silently orphans a multi-GB volume. These tests pin the two halves
# staying in step, and pin the safety rails (in-use volume, the 'host' group,
# no confirmation on a non-TTY).
#
# Hermetic: HOME is a temp dir, docker is faked on PATH. Never touches the real
# ~/.ai-containers or any real volume.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.ai-containers"

FAKE_VOLUMES_DIR="$TMP/fake-volumes"; mkdir -p "$FAKE_VOLUMES_DIR"
FAKE_RUNNING_VOL="$TMP/fake-running-vol"; : > "$FAKE_RUNNING_VOL"
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# FAKE_DOCKER_DOWN: a docker that cannot be reached answers nothing.
[[ -n "${FAKE_DOCKER_DOWN:-}" ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1" in
  volume)
    case "$2" in
      inspect)
        name=""; prev=""
        for a in "${@:3}"; do
          if [[ "$prev" == "--format" ]]; then :; elif [[ "$a" != "--format" ]]; then name="$a"; fi
          prev="$a"
        done
        [[ -f "$FAKE_VOLUMES_DIR/$name" ]] || { echo "Error response from daemon: get $name: no such volume" >&2; exit 1; }
        fmt=""; prev=""
        for a in "${@:3}"; do [[ "$prev" == "--format" ]] && fmt="$a"; prev="$a"; done
        if [[ "$fmt" == *Labels* ]]; then
          key="$(printf '%s' "$fmt" | sed -n 's/.*index \.Labels "\([^"]*\)".*/\1/p')"
          val=""
          [[ -f "$FAKE_VOLUMES_DIR/$name.labels" ]] && \
            val="$(grep "^${key}=" "$FAKE_VOLUMES_DIR/$name.labels" 2>/dev/null | head -1 | cut -d= -f2-)"
          printf '%s\n' "$val"
        else
          printf '%s\n' "$name"
        fi
        exit 0 ;;
      ls)
        substr=""
        for a in "$@"; do case "$a" in name=*) substr="${a#name=}" ;; esac; done
        for f in "$FAKE_VOLUMES_DIR"/*; do
          [[ -f "$f" ]] || continue
          case "$f" in *.labels|*.rmfail) continue ;; esac
          bn="$(basename "$f")"
          case "$bn" in *"$substr"*) printf '%s\n' "$bn" ;; esac
        done
        exit 0 ;;
      # A <name>.rmfail marker makes the removal fail, as a volume docker will
      # not let go of does.
      rm) [[ -f "$FAKE_VOLUMES_DIR/${3}.rmfail" ]] && exit 1
          rm -f "$FAKE_VOLUMES_DIR/${3}" "$FAKE_VOLUMES_DIR/${3}.labels"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  ps)
    [[ -n "${FAKE_PS_FAIL:-}" ]] && exit 1
    # FAKE_PS_FAIL_VOL=<volume>: docker cannot list the containers of that one.
    for a in "$@"; do [[ "$a" == "volume=${FAKE_PS_FAIL_VOL:-}" ]] && exit 1; done
    for a in "$@"; do
      case "$a" in
        volume=*)
          v="${a#volume=}"
          [[ "$v" == "$(cat "$FAKE_RUNNING_VOL" 2>/dev/null || true)" ]] && printf 'fakecid\n' ;;
      esac
    done
    exit 0 ;;
  system) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"

# This HOME's owner id (sandbox-common.sh: `ai_containers_owner_id()`), which a
# launch labels the rvm volume it makes with (PRJ-16); made here, as a launch
# makes it, with the key it needs.
OWN="$(HOME="$FAKE_HOME" bash -c 'source "$1/sandbox-common.sh" && ai_containers_owner_id' _ "$REPO_DIR" 2>/dev/null)"
[[ "$OWN" == sha256:* ]] || { printf 'SCAFFOLD-FAILED: no owner id\n'; exit 1; }
# mkvol <volume> <group>: an rvm volume this home made; VOL_OWNER= another id,
# or empty for one made before owner labels.
mkvol() {
  : > "$FAKE_VOLUMES_DIR/$1"
  { printf 'ai-containers.rvm-group=%s\n' "$2"; [[ -z "${VOL_OWNER-$OWN}" ]] || printf 'ai-containers.owner=%s\n' "${VOL_OWNER-$OWN}"; } > "$FAKE_VOLUMES_DIR/$1.labels"
}

run_group() {  # run group.sh with the fake env; echoes output, sets RC
  HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" \
    FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" \
    bash "$REPO_DIR/group.sh" "$@" 2>&1
}

bash -n "$REPO_DIR/group.sh" && pass "group.sh bash -n" || fail "group.sh bash -n"

# ── list ────────────────────────────────────────────────────────────────────────
mkdir -p "$FAKE_HOME/.ai-containers/default" "$FAKE_HOME/.ai-containers/docs"
mkvol "ai-containers-rvm-default" "default"

out="$(run_group list)"
grep -q 'default .*ai-containers-rvm-default .*present' <<<"$out" \
  && pass "list shows a group with its rvm volume" \
  || fail "list shows a group with its rvm volume (got: $out)"
grep -qE '^docs +- +none' <<<"$out" \
  && pass "list shows a group with no rvm volume as 'none'" \
  || fail "list shows a group with no rvm volume as 'none' (got: $out)"

# list --sizes adds the group directory's own size as a fourth column.
mkdir -p "$FAKE_HOME/.ai-containers/default/.var-tmp"
dd if=/dev/zero of="$FAKE_HOME/.ai-containers/default/.var-tmp/x" bs=1048576 count=2 2>/dev/null
out="$(run_group list --sizes)"
grep -q 'GROUP DIR' <<<"$out" \
  && pass "list --sizes header names the GROUP DIR column" \
  || fail "list --sizes header names the GROUP DIR column (got: $out)"
row="$(grep -E '^default ' <<<"$out")"
grep -qE '[[:space:]][0-9][0-9.,]*[KMG]$' <<<"$row" \
  && pass "list --sizes ends the group's row in its directory size" \
  || fail "list --sizes ends the group's row in its directory size (got: $out)"
out="$(run_group list)"
grep -q 'GROUP DIR' <<<"$out" \
  && fail "list without --sizes must not show GROUP DIR" \
  || pass "list without --sizes has no GROUP DIR column"
row="$(grep -E '^default ' <<<"$out")"
grep -qE '[[:space:]][0-9][0-9.,]*[KMG]$' <<<"$row" \
  && fail "list without --sizes must not end a row in a size" \
  || pass "list without --sizes rows are unchanged"
FAKE_DU="$TMP/du-bin"; mkdir -p "$FAKE_DU"
printf '#!/bin/sh\nexit 1\n' > "$FAKE_DU/du"; chmod +x "$FAKE_DU/du"
out="$(PATH="$FAKE_DU:$PATH" run_group list --sizes)"
row="$(grep -E '^default ' <<<"$out")"
grep -qE '[[:space:]]\?$' <<<"$row" \
  && pass "list --sizes shows ? for a group dir du cannot read" \
  || fail "list --sizes shows ? for a group dir du cannot read (got: $out)"

# A repo volume must never appear in group listings.
: > "$FAKE_VOLUMES_DIR/ai-containers-repo-app"
out="$(run_group list)"
grep -q 'ai-containers-repo-app' <<<"$out" \
  && fail "list must NOT show repo volumes" \
  || pass "list does not show repo volumes"

# Orphan detection: a volume whose group directory is gone.
mkvol "ai-containers-rvm-ghost" "ghost"
out="$(run_group list)"
grep -q 'Orphaned rvm volume' <<<"$out" && grep -q 'ai-containers-rvm-ghost' <<<"$out" \
  && pass "list flags an orphaned rvm volume" \
  || fail "list flags an orphaned rvm volume (got: $out)"

# ── gc ──────────────────────────────────────────────────────────────────────────
out="$(run_group gc --yes)"
grep -q 'Removed ai-containers-rvm-ghost' <<<"$out" \
  && pass "gc removes the orphaned volume" \
  || fail "gc removes the orphaned volume (got: $out)"
[[ -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-default" ]] \
  && pass "gc keeps a volume whose group still exists" \
  || fail "gc keeps a volume whose group still exists"
[[ -f "$FAKE_VOLUMES_DIR/ai-containers-repo-app" ]] \
  && pass "gc never touches repo volumes" \
  || fail "gc never touches repo volumes"

out="$(run_group gc --yes)"
grep -q 'Nothing to collect' <<<"$out" \
  && pass "gc is a no-op when there are no orphans" \
  || fail "gc is a no-op when there are no orphans (got: $out)"

# gc must skip a volume a running container is using.
mkvol "ai-containers-rvm-busy" "busy"
printf 'ai-containers-rvm-busy' > "$FAKE_RUNNING_VOL"
out="$(run_group gc --yes)"
grep -q 'Skipping ai-containers-rvm-busy' <<<"$out" \
  && pass "gc skips an in-use volume" \
  || fail "gc skips an in-use volume (got: $out)"
[[ -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-busy" ]] \
  && pass "gc leaves the in-use volume in place" \
  || fail "gc leaves the in-use volume in place"
: > "$FAKE_RUNNING_VOL"
run_group gc --yes >/dev/null

# Whose volume (bugs review PRJ-16): one daemon serves several homes (Docker
# Desktop's, by every WSL distro), so a group directory missing here may be
# another home's group. gc takes only the volumes this home made; another
# home's, and one made before owner labels, are kept and named, and --all takes
# them, still named.
VOL_OWNER="sha256:$(printf '%064d' 7)" mkvol "ai-containers-rvm-theirs" "theirs"
VOL_OWNER="" mkvol "ai-containers-rvm-oldvol" "oldvol"
mkvol "ai-containers-rvm-mine" "mine"
out="$(run_group list)"
grep -qF 'ai-containers-rvm-theirs  (another home'"'"'s: gc keeps it unless --all)' <<<"$out" \
  && grep -qF 'ai-containers-rvm-oldvol  (no owner label: gc keeps it unless --all)' <<<"$out" \
  && grep -qxF '  ai-containers-rvm-mine' <<<"$out" && ! grep -qF 'no owner key' <<<"$out" \
  && pass "PRJ-16 list says which orphans gc keeps, and why" \
  || fail "PRJ-16 list (got: $out)"
out="$(run_group gc --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"Removed ai-containers-rvm-mine"* && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-theirs" && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-oldvol" ]] \
  && grep -qF 'ai-containers-rvm-theirs: another home'"'"'s' <<<"$out" && grep -qF 'ai-containers-rvm-oldvol: no owner label' <<<"$out" \
  && grep -qF './group.sh gc --all' <<<"$out" \
  && pass "PRJ-16 gc removes this home's orphan and keeps another home's and an unlabelled one, naming them" \
  || fail "PRJ-16 gc by owner (rc=$rc; got: $out)"
out="$(run_group gc --all --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"Removed ai-containers-rvm-theirs"* && "$out" == *"Removed ai-containers-rvm-oldvol"* ]] \
  && [[ ! -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-theirs" && ! -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-oldvol" ]] \
  && grep -qF 'ai-containers-rvm-theirs  (another home'"'"'s: its group of that name may use it)' <<<"$out" \
  && grep -qF 'ai-containers-rvm-oldvol  (no owner label: it may be another home'"'"'s)' <<<"$out" \
  && pass "PRJ-16 gc --all takes every orphan, whoever made it, naming whose each is" \
  || fail "PRJ-16 gc --all (rc=$rc; got: $out)"
# A docker that cannot list its containers is not read as "none use it": the
# volume is skipped, gc says nothing was removed, and exits 1.
mkvol "ai-containers-rvm-unsure" "unsure"
out="$(FAKE_PS_FAIL=1 run_group gc --yes)"; rc=$?
[[ "$rc" -ne 0 && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-unsure" && "$out" == *"Skipping ai-containers-rvm-unsure — docker could not list the containers"* ]] \
  && [[ "$out" == *"Nothing removed: 1 orphaned volume(s) of this home skipped"* && "$out" != *"Nothing to collect"* ]] \
  && pass "PRJ-16 gc skips a volume when docker cannot say whether a container uses it, and says so, rc 1" \
  || fail "PRJ-16 gc with docker ps failing (rc=$rc; got: $out)"
run_group gc --yes >/dev/null
# group.sh rm reads it the same way, and keeps a volume another home made.
mkdir -p "$FAKE_HOME/.ai-containers/shared16"; mkvol "ai-containers-rvm-shared16" "shared16"
out="$(FAKE_PS_FAIL=1 run_group rm shared16 --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$FAKE_HOME/.ai-containers/shared16" && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-shared16" && "$out" == *"docker could not list the containers"* ]] \
  && pass "PRJ-16 rm refuses when docker cannot say whether a container uses the volume" \
  || fail "PRJ-16 rm with docker ps failing (rc=$rc; got: $out)"
rm -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-shared16" "$FAKE_VOLUMES_DIR/ai-containers-rvm-shared16.labels"
VOL_OWNER="sha256:$(printf '%064d' 7)" mkvol "ai-containers-rvm-shared16" "shared16"
out="$(run_group rm shared16 --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$FAKE_HOME/.ai-containers/shared16" && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-shared16" ]] \
  && [[ "$out" == *"rvm volume ai-containers-rvm-shared16 is kept: another home on this docker made it"* ]] \
  && pass "PRJ-16 rm removes this home's group directory and keeps a volume another home made, naming it" \
  || fail "PRJ-16 rm of a group whose volume another home made (rc=$rc; got: $out)"
out="$(run_group rm shared16 --yes)"; rc=$?
[[ "$rc" -ne 0 && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-shared16" && "$out" == *"was made by another home"* && "$out" == *"docker volume rm ai-containers-rvm-shared16"* ]] \
  && pass "PRJ-16 rm of only another home's volume is refused, with the command that removes it anyway" \
  || fail "PRJ-16 rm of only another home's volume (rc=$rc; got: $out)"
rm -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-shared16" "$FAKE_VOLUMES_DIR/ai-containers-rvm-shared16.labels"
# A home whose owner key is gone (an rm -rf of ~/.ai-containers) cannot tell its
# own labelled volumes from another home's, and says so.
NOKEY="$TMP/nokey-home"; mkdir -p "$NOKEY/.ai-containers"
mkvol "ai-containers-rvm-lostkey" "lostkey"
out="$(HOME="$NOKEY" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" gc --yes 2>&1)"
[[ "$out" == *"ai-containers-rvm-lostkey: another home's"* && "$out" == *"this home has no owner key"* ]] \
  && pass "PRJ-16 a home with no owner key says why its labelled volumes look like another home's" \
  || fail "PRJ-16 a home with no owner key (got: $out)"
# list says it too, under the orphans it cannot tell apart; a home that has its
# key says nothing of the kind (asserted above).
out="$(HOME="$NOKEY" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" list 2>&1)"
[[ "$out" == *"ai-containers-rvm-lostkey  (another home's: gc keeps it unless --all)"* && "$out" == *"this home has no owner key"* ]] \
  && pass "PRJ-16 list, in a home with no owner key, says why its orphans look like another home's" \
  || fail "PRJ-16 list in a home with no owner key (got: $out)"
rm -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-lostkey" "$FAKE_VOLUMES_DIR/ai-containers-rvm-lostkey.labels"; rm -rf "$NOKEY"
# rm of a group whose volume has no owner label, made before there was one,
# removes the volume with its directory, as it always did, and says it may be
# another home's; only one another home labelled is kept. This home's own is
# removed with no such word. (The mutation tier found none of the three
# asserted: a volume with no label kept, and the note on the wrong one, passed.)
mkdir -p "$FAKE_HOME/.ai-containers/old16"; VOL_OWNER="" mkvol "ai-containers-rvm-old16" "old16"
out="$(run_group rm old16 --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$FAKE_HOME/.ai-containers/old16" && ! -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-old16" ]] \
  && grep -qxF "  rvm volume ai-containers-rvm-old16 (installed rubies and gems) — no owner label, so it may be another home's too" <<<"$out" \
  && [[ "$out" != *"is kept"* ]] \
  && pass "PRJ-16 rm removes a volume with no owner label, saying it may be another home's" \
  || fail "PRJ-16 rm of a group whose volume has no owner label (rc=$rc; got: $out)"
mkdir -p "$FAKE_HOME/.ai-containers/mine16"; mkvol "ai-containers-rvm-mine16" "mine16"
out="$(run_group rm mine16 --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$FAKE_HOME/.ai-containers/mine16" && ! -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-mine16" ]] \
  && grep -qxF "  rvm volume ai-containers-rvm-mine16 (installed rubies and gems)" <<<"$out" \
  && pass "PRJ-16 rm removes this home's own volume with no word about another home" \
  || fail "PRJ-16 rm of this home's own group (rc=$rc; got: $out)"

# A docker that cannot be reached is not one with no volume: rm keeps the
# directory, where it removed it and orphaned the volume, and gc says so, rc 1,
# where it said there was nothing to collect (review of the PRJ-16 fix).
mkdir -p "$FAKE_HOME/.ai-containers/down16"; mkvol "ai-containers-rvm-down16" "down16"
out="$(FAKE_DOCKER_DOWN=1 run_group rm down16 --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$FAKE_HOME/.ai-containers/down16" && "$out" == *"docker could not say whether ai-containers-rvm-down16 exists"* ]] \
  && pass "PRJ-16 rm with docker unreachable refuses and keeps the directory" \
  || fail "PRJ-16 rm with docker unreachable (rc=$rc; got: $out)"
out="$(FAKE_DOCKER_DOWN=1 run_group list)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"down16"*"unknown"* && "$out" != *"none"* && "$out" == *"docker could not list its volumes"* ]] \
  && pass "PRJ-16 list with docker unreachable lists the groups, their volumes unknown, and says so, rc 1" \
  || fail "PRJ-16 list with docker unreachable (rc=$rc; got: $out)"
out="$(FAKE_DOCKER_DOWN=1 run_group gc --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"docker could not list its volumes"* && "$out" != *"Nothing to collect"* ]] \
  && pass "PRJ-16 gc with docker unreachable says so, rc 1" || fail "PRJ-16 gc with docker unreachable (rc=$rc; got: $out)"
rm -rf "$FAKE_HOME/.ai-containers/down16"; rm -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-down16" "$FAKE_VOLUMES_DIR/ai-containers-rvm-down16.labels"
# Skipping one orphan it could not judge, gc removes the others and still exits 1.
mkvol "ai-containers-rvm-gone1" "gone1"; mkvol "ai-containers-rvm-gone2" "gone2"
out="$(FAKE_PS_FAIL_VOL=ai-containers-rvm-gone1 run_group gc --yes)"; rc=$?
[[ "$rc" -ne 0 && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-gone1" && ! -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-gone2" && "$out" == *"Removed ai-containers-rvm-gone2"* ]] \
  && pass "PRJ-16 gc removes what it can, skips the volume docker could not judge, and exits 1" \
  || fail "PRJ-16 gc with one volume unjudged (rc=$rc; got: $out)"
rm -f "$FAKE_VOLUMES_DIR"/ai-containers-rvm-gone1*
# rm keeps a volume another home made whatever uses it, so a container that
# does is no reason to refuse; and a home with no owner key says why it takes
# its own volume for another's.
mkdir -p "$FAKE_HOME/.ai-containers/busy16"; VOL_OWNER="sha256:$(printf '%064d' 7)" mkvol "ai-containers-rvm-busy16" "busy16"
printf 'ai-containers-rvm-busy16' > "$FAKE_RUNNING_VOL"
out="$(run_group rm busy16 --yes)"; rc=$?
: > "$FAKE_RUNNING_VOL"
[[ "$rc" -eq 0 && ! -d "$FAKE_HOME/.ai-containers/busy16" && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-busy16" && "$out" != *"Stop it first"* ]] \
  && pass "PRJ-16 rm of a group whose volume another home made and uses removes the directory, keeps the volume" \
  || fail "PRJ-16 rm with another home's volume in use (rc=$rc; got: $out)"
NOKEY2="$TMP/nokey-home2"; mkdir -p "$NOKEY2/.ai-containers/busy16"
out="$(HOME="$NOKEY2" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" rm busy16 --yes 2>&1)"
[[ "$out" == *"rvm volume ai-containers-rvm-busy16 is kept: another home on this docker, or this one before it lost its owner key, made it"* \
   && "$out" == *"this home has no owner key"* ]] \
  && pass "PRJ-16 rm in a home with no owner key says why it keeps the volume" || fail "PRJ-16 rm with no owner key (got: $out)"
rm -rf "$NOKEY2"; rm -f "$FAKE_VOLUMES_DIR"/ai-containers-rvm-busy16*

# What a launch keeps from a protected git file's place is under the hidden
# ~/.ai-containers/.restored, a name no group can have (bugs review PRJ-18):
# not listed, not offered, not removable as a group. A group named restored is
# a group like any other.
mkdir -p "$FAKE_HOME/.ai-containers/.restored/20261117-1"; : > "$FAKE_HOME/.ai-containers/.restored/20261117-1/config"
out="$(run_group list)"
! grep -qE '^\.?restored ' <<<"$out" && pass "PRJ-18 list does not show the launcher's .restored as a group" || fail "PRJ-18 list shows .restored (got: $out)"
out="$(run_group rm .restored --yes)"; rc=$?
[[ "$rc" -ne 0 && -f "$FAKE_HOME/.ai-containers/.restored/20261117-1/config" ]] \
  && pass "PRJ-18 rm .restored is refused, the kept files left" || fail "PRJ-18 rm .restored (rc=$rc; got: $out)"
out="$(HOME="$FAKE_HOME" bash -c 'source "$1/sandbox-common.sh" && group_menu_choices default' _ "$REPO_DIR" 2>&1)"
[[ "$out" != *restored* ]] && pass "PRJ-18 the bootstrap menu does not offer .restored" || fail "PRJ-18 the menu offers .restored (got: $out)"
out="$(HOME="$FAKE_HOME" bash -c 'eval "$(sed -n "/^valid_group_name() {/,/^}/p;/^existing_groups() {/,/^}/p" "$1/project-init.sh")"; existing_groups' _ "$REPO_DIR" 2>&1)"
[[ -n "$out" && "$out" != *restored* ]] && pass "PRJ-18 project-init does not offer .restored as a group" || fail "PRJ-18 project-init offers .restored (got: $out)"
mkdir -p "$FAKE_HOME/.ai-containers/restored"
out="$(run_group list)"
grep -qE '^restored ' <<<"$out" && pass "PRJ-18 a group named restored is listed like any other" || fail "PRJ-18 a group named restored is hidden (got: $out)"
out="$(HOME="$FAKE_HOME" bash -c 'source "$1/sandbox-common.sh" && validate_group_name restored && echo OK' _ "$REPO_DIR" 2>&1)"
[[ "$out" == OK ]] && pass "PRJ-18 AI_CONTAINER_GROUP=restored is a valid group" || fail "PRJ-18 restored refused as a group (got: $out)"
rm -rf "$FAKE_HOME/.ai-containers/.restored" "$FAKE_HOME/.ai-containers/restored"

# ── rm ──────────────────────────────────────────────────────────────────────────
# group.sh has TWO independent exit-1 paths a "host" run could hit: the host-guard
# (group.sh: `if [[ "$name" == "host" ]]`) and the generic "no such group"
# fallback (group.sh: `ERROR: no such group`),
# which fires whenever a name has neither a directory nor a volume. Without a real
# ~/.ai-containers/host directory, "host" would satisfy the fallback too, and an
# rc-only assertion could pass for the WRONG reason (the fallback, not the guard it
# is meant to cover). Pre-create the directory so has_dir=1 and the fallback's
# `has_dir == 0 && has_vol == 0` can never be true for this case — the only
# remaining source of a non-zero exit is the host-guard itself.
mkdir -p "$FAKE_HOME/.ai-containers/host"
out="$(run_group rm host --yes)"; rc=$?
grep -q 'refusing' <<<"$out" \
  && pass "rm refuses the 'host' group" \
  || fail "rm refuses the 'host' group (got: $out)"
[[ "$rc" -ne 0 && "$out" != *'no such group'* ]] \
  && pass "rm refuses the 'host' group with a non-zero exit (the host-guard, not the unrelated 'no such group' fallback)" \
  || fail "rm refuses the 'host' group with a non-zero exit (the host-guard, not the unrelated 'no such group' fallback) (rc=$rc, out: $out)"

out="$(run_group rm nosuchgroup --yes)"
grep -q 'no such group' <<<"$out" \
  && pass "rm errors on an unknown group" \
  || fail "rm errors on an unknown group (got: $out)"

# rm must refuse while a container is using the volume — and must NOT have deleted
# the directory first (the ordering bug this guards against).
printf 'ai-containers-rvm-default' > "$FAKE_RUNNING_VOL"
out="$(run_group rm default --yes)"
grep -q 'still using' <<<"$out" \
  && pass "rm refuses while a container uses the volume" \
  || fail "rm refuses while a container uses the volume (got: $out)"
[[ -d "$FAKE_HOME/.ai-containers/default" ]] \
  && pass "rm left the directory intact when it refused" \
  || fail "rm left the directory intact when it refused"
: > "$FAKE_RUNNING_VOL"

out="$(run_group rm default --yes)"
[[ ! -d "$FAKE_HOME/.ai-containers/default" ]] \
  && pass "rm removes the group directory" \
  || fail "rm removes the group directory"
[[ ! -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-default" ]] \
  && pass "rm removes the group's rvm volume too" \
  || fail "rm removes the group's rvm volume too"
[[ -f "$FAKE_VOLUMES_DIR/ai-containers-repo-app" ]] \
  && pass "rm never touches repo volumes" \
  || fail "rm never touches repo volumes"

# A group with a directory but no volume is still removable.
mkdir -p "$FAKE_HOME/.ai-containers/dirsonly"
run_group rm dirsonly --yes >/dev/null
[[ ! -d "$FAKE_HOME/.ai-containers/dirsonly" ]] \
  && pass "rm works for a group that has no rvm volume" \
  || fail "rm works for a group that has no rvm volume"

# Without --yes and without a TTY, destructive commands must refuse, not proceed.
mkdir -p "$FAKE_HOME/.ai-containers/keepme"
out="$(run_group rm keepme < /dev/null)"
[[ -d "$FAKE_HOME/.ai-containers/keepme" ]] \
  && pass "rm without --yes on a non-TTY does not delete" \
  || fail "rm without --yes on a non-TTY does not delete (got: $out)"

# PRJ-1: the name is spliced into a path handed to rm -rf, so it is validated as
# every other entry point validates a group name: `rm ../dev` deleted ~/dev.
mkdir -p "$FAKE_HOME/victim"; echo keep > "$FAKE_HOME/victim/data"
for bad in ../victim default/ 'a b' .hidden UPPER; do
  out="$(run_group rm "$bad" --yes)"; rc=$?
  [[ "$rc" != 0 && -f "$FAKE_HOME/victim/data" && "$out" == *"Invalid"* ]] \
    && pass "rm refuses the group name '$bad'" \
    || fail "rm accepted the group name '$bad' (rc=$rc; out: $out)"
done

# ── Exit statuses: every refusal is a FAILURE to the caller ─────────────────────
# A script driving group.sh (or a human's `&&` chain) reads success as "done". Each
# usage error, unknown name and refused removal must therefore exit non-zero, and
# the two clean no-ops (an empty list, nothing to collect) must exit zero.
for spec in "list --bogus" "rm --bogus keepme" "rm keepme docs" "rm" "gc --bogus" "frobnicate" \
            "rm nosuchgroup --yes"; do
  # shellcheck disable=SC2086  # the spec is split into arguments on purpose
  out="$(run_group $spec)"; rc=$?
  [[ "$rc" -ne 0 && "$out" == *ERROR* ]] \
    && pass "\`group.sh $spec\` fails with an ERROR" \
    || fail "\`group.sh $spec\` fails with an ERROR (rc=$rc; out: $out)"
done
[[ -d "$FAKE_HOME/.ai-containers/keepme" && -d "$FAKE_HOME/.ai-containers/docs" ]] \
  && pass "  … and none of those removed a group" \
  || fail "  … a refused rm removed a group"

# rm refused while the volume is in use: non-zero, and nothing removed.
mkdir -p "$FAKE_HOME/.ai-containers/busy2"; mkvol "ai-containers-rvm-busy2" "busy2"
printf 'ai-containers-rvm-busy2' > "$FAKE_RUNNING_VOL"
out="$(run_group rm busy2 --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$FAKE_HOME/.ai-containers/busy2" && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-busy2" ]] \
  && pass "rm of an in-use group exits non-zero and removes nothing" \
  || fail "rm of an in-use group exits non-zero and removes nothing (rc=$rc; out: $out)"

# list marks exactly the volume a running container uses as "(in use)".
out="$(run_group list)"
grep -qE '^busy2 +ai-containers-rvm-busy2 +present \(in use\)$' <<<"$out" \
  && pass "list marks an in-use rvm volume '(in use)'" \
  || fail "list marks an in-use rvm volume '(in use)' (got: $out)"
: > "$FAKE_RUNNING_VOL"
out="$(run_group list)"
grep -qE '^busy2 +ai-containers-rvm-busy2 +present$' <<<"$out" \
  && pass "  … and does not mark one nothing uses" \
  || fail "  … and does not mark one nothing uses (got: $out)"

# A volume docker will not remove: rm stops non-zero, says so, and keeps the
# directory (deleting it would orphan the volume this script exists to prevent).
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-busy2.rmfail"
out="$(run_group rm busy2 --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"could not remove volume"* && -d "$FAKE_HOME/.ai-containers/busy2" ]] \
  && pass "rm whose volume removal fails exits non-zero and leaves the directory" \
  || fail "rm whose volume removal fails exits non-zero and leaves the directory (rc=$rc; out: $out)"
rm -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-busy2.rmfail"

# What rm lists before asking is what it will remove: the directory line only
# when there is a directory, the volume line only when there is a volume.
dir_line="  directory  $FAKE_HOME/.ai-containers/busy2"
vol_line="  rvm volume ai-containers-rvm-busy2 (installed rubies and gems)"
out="$(run_group rm busy2 --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"$dir_line"* && "$out" == *"$vol_line"* ]] \
  && pass "rm lists both the directory and the volume it removes" \
  || fail "rm lists both the directory and the volume it removes (rc=$rc; out: $out)"
mkdir -p "$FAKE_HOME/.ai-containers/onlydir"
out="$(run_group rm onlydir --yes)"
[[ "$out" == *"  directory  $FAKE_HOME/.ai-containers/onlydir"* && "$out" != *"rvm volume"* ]] \
  && pass "rm of a directory-only group lists no volume" \
  || fail "rm of a directory-only group lists no volume (got: $out)"
mkvol "ai-containers-rvm-onlyvol" "onlyvol"
out="$(run_group rm onlyvol --yes)"
[[ "$out" == *"  rvm volume ai-containers-rvm-onlyvol"* && "$out" != *"  directory  "* \
   && ! -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-onlyvol" ]] \
  && pass "rm of a volume-only group lists no directory, and removes the volume" \
  || fail "rm of a volume-only group lists no directory, and removes the volume (got: $out)"

# No TTY and no --yes: refused with the reason, non-zero — even when "y" is
# waiting on stdin, because a piped "y" is not a person answering.
mkdir -p "$FAKE_HOME/.ai-containers/piped"
out="$(printf 'y\n' | run_group rm piped)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"stdin is not a TTY"* && -d "$FAKE_HOME/.ai-containers/piped" ]] \
  && pass "rm on a non-TTY refuses a piped 'y', non-zero, naming the TTY" \
  || fail "rm on a non-TTY refuses a piped 'y', non-zero, naming the TTY (rc=$rc; out: $out)"

# gc: the same refusal for orphans, then a clean collection prints no warning,
# and a volume docker will not remove is warned about.
mkvol "ai-containers-rvm-orph" "orph"
out="$(printf 'y\n' | run_group gc)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"stdin is not a TTY"* && -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-orph" ]] \
  && pass "gc on a non-TTY refuses, non-zero, and keeps the orphan" \
  || fail "gc on a non-TTY refuses, non-zero, and keeps the orphan (rc=$rc; out: $out)"
out="$(run_group gc --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"Removed ai-containers-rvm-orph"* && "$out" != *WARNING* ]] \
  && pass "gc that removes every orphan prints no WARNING" \
  || fail "gc that removes every orphan prints no WARNING (rc=$rc; out: $out)"
mkvol "ai-containers-rvm-stuck" "stuck"; : > "$FAKE_VOLUMES_DIR/ai-containers-rvm-stuck.rmfail"
out="$(run_group gc --yes)"
[[ "$out" == *"WARNING: could not remove ai-containers-rvm-stuck"* && "$out" != *"Removed ai-containers-rvm-stuck"* ]] \
  && pass "gc warns about a volume it could not remove" \
  || fail "gc warns about a volume it could not remove (got: $out)"
rm -f "$FAKE_VOLUMES_DIR/ai-containers-rvm-stuck" "$FAKE_VOLUMES_DIR/ai-containers-rvm-stuck".*
out="$(run_group gc --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"Nothing to collect"* ]] \
  && pass "gc with nothing to collect exits zero" \
  || fail "gc with nothing to collect exits zero (rc=$rc; out: $out)"

# list with no ~/.ai-containers at all: a clean, successful no-op.
out="$(HOME="$TMP/empty-home" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" \
  FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" list 2>&1)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"No container groups yet"* ]] \
  && pass "list with no groups root exits zero and says so" \
  || fail "list with no groups root exits zero and says so (rc=$rc; out: $out)"
# Every group directory deleted by hand leaves only orphans, and list names them
# still: it returned at "No container groups yet" before its orphan check
# (review of the PRJ-16 fix).
VOL_OWNER="" mkvol "ai-containers-rvm-left16" "left16"
out="$(HOME="$TMP/empty-home" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" \
  FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" list 2>&1)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"No container groups yet"* && "$out" == *"ai-containers-rvm-left16  (no owner label"* ]] \
  && pass "PRJ-16 list with no group directory left still names the orphaned volumes" \
  || fail "PRJ-16 list with no group directory left (rc=$rc; out: $out)"
rm -f "$FAKE_VOLUMES_DIR"/ai-containers-rvm-left16*
# ... and with docker unreachable it cannot tell whether there are any: it says
# so, rc 1, rather than "no groups" and success.
out="$(HOME="$TMP/empty-home" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_DOCKER_DOWN=1 \
  FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" list 2>&1)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"No container groups yet"* && "$out" == *"docker could not list its volumes"* ]] \
  && pass "PRJ-16 list with no group directory and docker unreachable says the orphans cannot be told, rc 1" \
  || fail "PRJ-16 list with no group directory and docker unreachable (rc=$rc; out: $out)"

# ── THE CONFIRMATION, ON A REAL TTY ─────────────────────────────────────────────
# Everything above runs without a terminal, so confirm()'s interactive branch —
# `read -r -p … [y/N]` and the answer it accepts — is reached only here. "y" and
# "Y" remove; anything else ("n") aborts non-zero and removes nothing. The yes
# cases also prove the answer reached the prompt, which the no case rests on.
if ! command -v script >/dev/null 2>&1; then
  printf 'SKIP: no script(1) on this host, so the confirmation prompt cannot be reached\n'
else
  # The answer is sent when the prompt appears (polled, not a fixed sleep, which
  # would be load-sensitive). Both waits also end as soon as group.sh has exited
  # (the .done marker): a damaged group.sh that never prompts must fail this
  # case at once, not after the 30 s + 10 s bounds, which pushed the falsify
  # tier's mutants past its per-mutant timeout.
  answer_when_prompted() {   # <answer> <transcript>: write once the prompt is up
    local ans="$1" out="$2" i=0
    while (( i < 600 )); do
      grep -q 'y/N' "$out" 2>/dev/null && break; [[ -e "$out.done" ]] && return 0
      sleep 0.05; i=$((i+1))
    done
    printf '%s\n' "$ans"
    i=0   # hold stdin open until the pty has echoed the answer
    while (( i < 200 )); do
      grep -q "N\] $ans" "$out" 2>/dev/null && break; [[ -e "$out.done" ]] && return 0
      sleep 0.05; i=$((i+1))
    done
    sleep 0.1
  }
  run_group_pty() {   # <answer> <args…>; sets RC and OUT
    local ans="$1"; shift
    OUT="$TMP/pty-out.txt"; : > "$OUT"; rm -f "$OUT.done"
    answer_when_prompted "$ans" "$OUT" \
      | ( export HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR FAKE_RUNNING_VOL
          p_pty bash "$REPO_DIR/group.sh" "$@"; r=$?; : > "$OUT.done"; exit "$r" ) > "$OUT" 2>&1
    RC=$?
  }
  for ans in y Y; do
    g="tty-$([[ "$ans" == y ]] && echo lower || echo upper)"   # a group name is lowercase
    mkdir -p "$FAKE_HOME/.ai-containers/$g"
    run_group_pty "$ans" rm "$g"
    [[ "$RC" -eq 0 && ! -d "$FAKE_HOME/.ai-containers/$g" ]] \
      && pass "rm answered '$ans' on a tty removes the group" \
      || fail "rm answered '$ans' on a tty removes the group (rc=$RC; out: $(tr -d '\r' < "$OUT" | tr '\n' ' '))"
  done
  mkdir -p "$FAKE_HOME/.ai-containers/ttyn"
  run_group_pty n rm ttyn
  [[ "$RC" -ne 0 && -d "$FAKE_HOME/.ai-containers/ttyn" ]] && grep -q 'Aborted' "$OUT" \
    && pass "rm answered 'n' on a tty aborts non-zero and removes nothing" \
    || fail "rm answered 'n' on a tty aborts non-zero and removes nothing (rc=$RC; out: $(tr -d '\r' < "$OUT" | tr '\n' ' '))"
fi

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
