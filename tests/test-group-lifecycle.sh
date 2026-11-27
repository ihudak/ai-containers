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
        # FAKE_INSPECT_FAIL=<volume>: docker cannot say whether it exists (a
        # plain inspect; a read of its labels still answers).
        [[ "$name" == "${FAKE_INSPECT_FAIL:-}" && "$*" != *Labels* ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
        [[ -f "$FAKE_VOLUMES_DIR/$name" ]] || { echo "Error response from daemon: get $name: no such volume" >&2; exit 1; }
        fmt=""; prev=""
        for a in "${@:3}"; do [[ "$prev" == "--format" ]] && fmt="$a"; prev="$a"; done
        # FAKE_LABEL_FAIL=<volume>: docker says the volume exists, then cannot
        # be reached when its labels are read; FAKE_LABEL_FAIL_KEY=<key> only
        # when that one is.
        if [[ "$fmt" == *Labels* && "$name" == "${FAKE_LABEL_FAIL:-}" ]] \
           && [[ -z "${FAKE_LABEL_FAIL_KEY:-}" || "$fmt" == *"\"$FAKE_LABEL_FAIL_KEY\""* ]]; then
          echo "Cannot connect to the Docker daemon" >&2; exit 1
        fi
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
          case "$f" in *.labels|*.rmfail|*.size) continue ;; esac
          bn="$(basename "$f")"
          case "$bn" in *"$substr"*) printf '%s\n' "$bn" ;; esac
        done
        exit 0 ;;
      # A <name>.rmfail marker makes the removal fail, as a volume docker will
      # not let go of does.
      rm) [[ -f "$FAKE_VOLUMES_DIR/${3}.rmfail" ]] && exit 1
          rm -f "$FAKE_VOLUMES_DIR/${3}" "$FAKE_VOLUMES_DIR/${3}.labels" "$FAKE_VOLUMES_DIR/${3}.size"; exit 0 ;;
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
  # `system df -v`: a <name>.size file gives that volume's size, as the
  # --format group.sh asks for prints it ("<name> <size>" a line).
  # FAKE_DF_LOG=<file>: a line in it for each `system df` asked.
  system)
    if [[ "$2" == df ]]; then
      [[ -z "${FAKE_DF_LOG:-}" ]] || printf 'df\n' >> "$FAKE_DF_LOG"
      for f in "$FAKE_VOLUMES_DIR"/*.size; do
        [[ -f "$f" ]] && printf '%s %s\n' "$(basename "$f" .size)" "$(cat "$f")"
      done
    fi
    exit 0 ;;
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
# mktmpvol <volume> <group>: a temp (/var/tmp) volume this home's launch made,
# labelled as sandbox-common.sh: `vartmp_volume_ensure()` labels one; VOL_OWNER
# as for mkvol. One with no labels file is a volume of the name made outside a
# launch (a `docker run -v` of it).
mktmpvol() {
  : > "$FAKE_VOLUMES_DIR/$1"
  { printf 'ai-containers.vartmp-group=%s\n' "$2"; [[ -z "${VOL_OWNER-$OWN}" ]] || printf 'ai-containers.owner=%s\n' "${VOL_OWNER-$OWN}"; } > "$FAKE_VOLUMES_DIR/$1.labels"
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
grep -qE '^GROUP +RVM VOLUME +STATE +TEMP VOLUME +STATE +CACHE VOLUME +STATE$' <<<"$out" \
  && pass "list's header names the three volumes and their states" \
  || fail "list's header names the three volumes and their states (got: $out)"
grep -qE '^docs +- +none' <<<"$out" \
  && pass "list shows a group with no rvm volume as 'none'" \
  || fail "list shows a group with no rvm volume as 'none' (got: $out)"

# list --sizes adds the group directory's own size as its last column.
mkdir -p "$FAKE_HOME/.ai-containers/default/.cache"
dd if=/dev/zero of="$FAKE_HOME/.ai-containers/default/.cache/x" bs=1048576 count=2 2>/dev/null
out="$(run_group list --sizes)"
grep -qE '^GROUP +RVM VOLUME +SIZE +TEMP VOLUME +SIZE +CACHE VOLUME +SIZE +GROUP DIR$' <<<"$out" \
  && pass "list --sizes header names a SIZE column for each volume, then the GROUP DIR column" \
  || fail "list --sizes header names a SIZE column for each volume, then the GROUP DIR column (got: $out)"
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
  && pass "list --sizes shows ? for a du that prints nothing" \
  || fail "list --sizes shows ? for a du that prints nothing (got: $out)"

# du exits 1 when it cannot read part of the directory (a folder the agent made
# unreadable), after printing the total of what it could read: list shows that
# total as the least the directory holds, not "?" (open follow-up 6 of the
# 2026-11-26 /var/tmp backlog). A du that prints nothing is still "?", above.
printf '#!/bin/sh\nfor a; do p="$a"; done\nprintf "12M\\t%%s\\n" "$p"\necho "du: cannot read directory" >&2\nexit 1\n' > "$FAKE_DU/du"
out="$(PATH="$FAKE_DU:$PATH" run_group list --sizes)"
row="$(grep -E '^default ' <<<"$out")"
grep -qE '[[:space:]]at least 12M$' <<<"$row" \
  && pass "list --sizes shows a partial total, as at least that, where du could not read all of a group dir" \
  || fail "list --sizes with a partial du total (got: $out)"

# A du that pads the size with blanks, as BSD's prints a human size in four
# columns (" 12K"; FreeBSD's du.c, source-read): the cell drops them, and a
# partial total reads "at least 12M" with one blank.
printf '#!/bin/sh\nfor a; do p="$a"; done\nprintf " 12M\\t%%s\\n" "$p"\nexit 1\n' > "$FAKE_DU/du"
out="$(PATH="$FAKE_DU:$PATH" run_group list --sizes)"
row="$(grep -E '^default ' <<<"$out")"
grep -qE '[[:space:]]at least 12M$' <<<"$row" \
  && pass "list --sizes drops the blanks du pads a size with" \
  || fail "list --sizes with a blank-padded du size (got: $out)"

# du is asked in the C locale: in one whose decimal point is neither "." nor
# "," GNU du prints U+066B for it (LC_ALL=ps_AF.UTF-8, measured), which is no size here.
# The fake prints that unless LC_ALL is C.
printf '#!/bin/sh\nfor a; do p="$a"; done\nif [ "${LC_ALL:-}" = C ]; then printf "1.6M\\t%%s\\n" "$p"; else printf "1\\331\\2536M\\t%%s\\n" "$p"; fi\n' > "$FAKE_DU/du"
out="$(LC_ALL=C.UTF-8 PATH="$FAKE_DU:$PATH" run_group list --sizes)"
row="$(grep -E '^default ' <<<"$out")"
grep -qE '[[:space:]]1\.6M$' <<<"$row" \
  && pass "list --sizes asks du for the size in the C locale" \
  || fail "list --sizes in another locale's decimal point (got: $out)"

# Only what reads as a size is shown: a du that prints something else (a word,
# another line before the size, a word before the tab) is "?".
for body in 'printf "garbage\\n"' 'printf "oops\\n12M\\t%s\\n" "$p"' 'printf "garbage\\t%s\\n" "$p"'; do
  printf '#!/bin/sh\nfor a; do p="$a"; done\n%s\n' "$body" > "$FAKE_DU/du"
  out="$(PATH="$FAKE_DU:$PATH" run_group list --sizes)"
  row="$(grep -E '^default ' <<<"$out")"
  grep -qE '[[:space:]]\?$' <<<"$row" \
    && pass "list --sizes shows ? for a du output that is no size ($body)" \
    || fail "list --sizes with a du output that is no size, $body (got: $out)"
done

# A repo volume must never appear in group listings.
: > "$FAKE_VOLUMES_DIR/ai-containers-repo-app"
out="$(run_group list)"
grep -q 'ai-containers-repo-app' <<<"$out" \
  && fail "list must NOT show repo volumes" \
  || pass "list does not show repo volumes"

# Orphan detection: a volume whose group directory is gone.
mkvol "ai-containers-rvm-ghost" "ghost"
out="$(run_group list)"
grep -q 'Orphaned Ruby, temp and cache volume' <<<"$out" && grep -q 'ai-containers-rvm-ghost' <<<"$out" \
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
  && [[ "$out" == *"Nothing removed: 1 volume(s) skipped"* && "$out" != *"Nothing to collect"* ]] \
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
grep -qE '^busy2 +ai-containers-rvm-busy2 +present \(in use\) +- +none +- +none$' <<<"$out" \
  && pass "list marks an in-use rvm volume '(in use)'" \
  || fail "list marks an in-use rvm volume '(in use)' (got: $out)"
: > "$FAKE_RUNNING_VOL"
out="$(run_group list)"
grep -qE '^busy2 +ai-containers-rvm-busy2 +present +- +none +- +none$' <<<"$out" \
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

# ── The temp volume ─────────────────────────────────────────────────────────────
# A group's /var/tmp is a second volume, <prefix>-vartmp-<group>, beside its
# Ruby one. It is known by its ai-containers.vartmp-group label, never by its
# name alone: a name match is what let a nested REPO_VOLUME_PREFIX mistake one
# repo's volume for another's (REPO-11). list, rm and gc treat it as they treat
# the Ruby volume, each volume on its own.
GR="$FAKE_HOME/.ai-containers"
THEIRS="sha256:$(printf '%064d' 7)"
tvol() { [[ -f "$FAKE_VOLUMES_DIR/$1" ]]; }
tclean() { local v; for v in "$@"; do rm -f "${FAKE_VOLUMES_DIR:?}/$v" "${FAKE_VOLUMES_DIR:?}/$v".*; done; }

out="$(run_group --help)"
[[ "$(grep -cE '^  \./group\.sh (list|rm|gc) .*temp and cache volume' <<<"$out")" == 3 ]] \
  && grep -qF 'Docker volumes holding its containers'"'"' /var/tmp and ~/.cache' <<<"$out" \
  && pass "usage names the temp volume for list, rm and gc, and says what it holds" \
  || fail "usage names the temp volume (got: $out)"

# list: both volumes of a group, their states, and the in-use mark on the
# temp volume alone.
mkdir -p "$GR/tboth"; mkvol ai-containers-rvm-tboth tboth; mktmpvol ai-containers-vartmp-tboth tboth
mkdir -p "$GR/tonly"; mktmpvol ai-containers-vartmp-tonly tonly
out="$(run_group list)"
grep -qE '^tboth +ai-containers-rvm-tboth +present +ai-containers-vartmp-tboth +present +- +none$' <<<"$out" \
  && pass "list shows a group's Ruby and temp volumes, each present" \
  || fail "list shows a group's Ruby and temp volumes (got: $out)"
grep -qE '^tonly +- +none +ai-containers-vartmp-tonly +present +- +none$' <<<"$out" \
  && pass "list shows a group with a temp volume and no Ruby one" \
  || fail "list shows a group with a temp volume and no Ruby one (got: $out)"
printf 'ai-containers-vartmp-tboth' > "$FAKE_RUNNING_VOL"
out="$(run_group list)"
: > "$FAKE_RUNNING_VOL"
grep -qE '^tboth +ai-containers-rvm-tboth +present +ai-containers-vartmp-tboth +present \(in use\) +- +none$' <<<"$out" \
  && pass "list marks the temp volume a running container uses '(in use)', and only it" \
  || fail "list marks an in-use temp volume (got: $out)"
printf '1.5GB' > "$FAKE_VOLUMES_DIR/ai-containers-rvm-tboth.size"
printf '20MB' > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-tboth.size"
out="$(run_group list --sizes)"
grep -qE '^tboth +ai-containers-rvm-tboth +1\.5GB +ai-containers-vartmp-tboth +20MB +- +none +[0-9?][^ ]*$' <<<"$out" \
  && pass "list --sizes shows each volume's size, then the group directory's" \
  || fail "list --sizes shows each volume's size (got: $out)"
# One `docker system df -v` per list: it walks every volume on the daemon, and
# asked once per volume it made list --sizes slower with every group.
DFLOG="$TMP/df-calls"; : > "$DFLOG"
out="$(FAKE_DF_LOG="$DFLOG" run_group list --sizes)"
dfn="$(grep -c . "$DFLOG")"
[[ "$dfn" == 1 ]] && grep -qE '^tboth +ai-containers-rvm-tboth +1\.5GB +ai-containers-vartmp-tboth +20MB ' <<<"$out" \
  && grep -qE '^tonly +- +none +ai-containers-vartmp-tonly +- ' <<<"$out" \
  && pass "list --sizes asks docker system df once, however many volumes it sizes" \
  || fail "list --sizes asked docker system df $dfn time(s) (got: $out)"
: > "$DFLOG"
out="$(FAKE_DF_LOG="$DFLOG" run_group list)"
dfn="$(grep -c . "$DFLOG")"
[[ "$dfn" == 0 ]] \
  && pass "list without --sizes never asks docker system df" \
  || fail "list without --sizes asked docker system df $dfn time(s)"
EH="$TMP/empty-home-df"; mkdir -p "$EH"
out="$(HOME="$EH" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" FAKE_DF_LOG="$DFLOG" bash "$REPO_DIR/group.sh" list --sizes 2>&1)"
dfn="$(grep -c . "$DFLOG")"
[[ "$dfn" == 0 ]] \
  && pass "list --sizes with no group directory has nothing to size, and never asks docker system df" \
  || fail "list --sizes with no group directory asked docker system df $dfn time(s) (got: $out)"
rmdir "$EH"
out="$(FAKE_DOCKER_DOWN=1 run_group list)"
grep -qE '^tboth +ai-containers-rvm-tboth +unknown +ai-containers-vartmp-tboth +unknown +ai-containers-cache-tboth +unknown$' <<<"$out" \
  && pass "list with docker unreachable says both volumes are unknown" \
  || fail "list with docker unreachable, both volumes (got: $out)"
# A volume of the temp name that is not the group's (no label, or another
# group's) is named in its row as not the group's, never as its temp volume.
mkdir -p "$GR/tunl"; : > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-tunl"
mkdir -p "$GR/tmix"; mktmpvol ai-containers-vartmp-tmix tother
out="$(run_group list)"
grep -qE "^tunl +- +none +ai-containers-vartmp-tunl +not the group's +- +none$" <<<"$out" \
  && grep -qE "^tmix +- +none +ai-containers-vartmp-tmix +not the group's +- +none$" <<<"$out" \
  && pass "list names a volume of the temp name without the group's label as not the group's" \
  || fail "list, a temp-name volume not the group's (got: $out)"
rmdir "$GR/tunl" "$GR/tmix"; tclean ai-containers-vartmp-tunl ai-containers-vartmp-tmix

# list's orphans: a temp volume whose group directory is gone, with whose it is;
# one with no label, or whose name is not its label's group's temp volume (a
# nested prefix's, REPO-11), is no group's and is not named at all.
mktmpvol ai-containers-vartmp-tghost tghost
VOL_OWNER="$THEIRS" mktmpvol ai-containers-vartmp-ttheirs ttheirs
VOL_OWNER="" mktmpvol ai-containers-vartmp-told told
: > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-x"
mktmpvol ai-containers-vartmp-a-vartmp-tnest tnest
out="$(run_group list)"
grep -q '^Orphaned Ruby, temp and cache volume(s) with no group directory' <<<"$out" \
  && grep -qxF '  ai-containers-vartmp-tghost' <<<"$out" \
  && grep -qxF "  ai-containers-vartmp-ttheirs  (another home's: gc keeps it unless --all)" <<<"$out" \
  && grep -qxF '  ai-containers-vartmp-told  (no owner label: gc keeps it unless --all)' <<<"$out" \
  && pass "list names an orphaned temp volume under the orphans, with whose each is" \
  || fail "list, orphaned temp volumes (got: $out)"
[[ "$out" != *ai-containers-vartmp-x* ]] \
  && pass "list does not name an unlabelled volume of the temp name anywhere" \
  || fail "list names an unlabelled ai-containers-vartmp-x (got: $out)"
[[ "$out" != *ai-containers-vartmp-a-vartmp-tnest* ]] \
  && pass "list does not take a volume whose name is not its label's group's temp volume for an orphan" \
  || fail "list names a nested prefix's temp volume (got: $out)"

# gc: this home's orphaned temp volume goes; another home's and an unlabelled
# owner's stay unless --all; one with no group label, or another prefix's, is
# never touched, --all or not.
out="$(run_group gc --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"Removed ai-containers-vartmp-tghost"* ]] && ! tvol ai-containers-vartmp-tghost \
  && grep -qxF '  ai-containers-vartmp-tghost' <<<"$out" \
  && pass "gc collects this home's orphaned temp volume" \
  || fail "gc collects an orphaned temp volume (rc=$rc; got: $out)"
tvol ai-containers-vartmp-ttheirs && tvol ai-containers-vartmp-told \
  && grep -qF "  ai-containers-vartmp-ttheirs: another home's" <<<"$out" \
  && grep -qF '  ai-containers-vartmp-told: no owner label' <<<"$out" \
  && pass "gc keeps another home's temp volume and one with no owner label, naming them" \
  || fail "gc keeps another home's temp volume (got: $out)"
tvol ai-containers-vartmp-tboth && tvol ai-containers-vartmp-tonly \
  && pass "gc keeps a temp volume whose group still exists" \
  || fail "gc keeps a temp volume whose group still exists (got: $out)"
out="$(run_group gc --all --yes)"; rc=$?
[[ "$rc" -eq 0 ]] && ! tvol ai-containers-vartmp-ttheirs && ! tvol ai-containers-vartmp-told \
  && grep -qF "  ai-containers-vartmp-ttheirs  (another home's: its group of that name may use it)" <<<"$out" \
  && pass "gc --all takes another home's temp volume too, naming whose it is" \
  || fail "gc --all, temp volumes (rc=$rc; got: $out)"
tvol ai-containers-vartmp-x && tvol ai-containers-vartmp-a-vartmp-tnest \
  && [[ "$out" != *ai-containers-vartmp-x* && "$out" != *a-vartmp-tnest* ]] \
  && pass "gc --all passes over a volume with no group label, and another prefix's" \
  || fail "gc --all touched a volume that is no group's temp volume (got: $out)"
mktmpvol ai-containers-vartmp-tbusy tbusy
printf 'ai-containers-vartmp-tbusy' > "$FAKE_RUNNING_VOL"
out="$(run_group gc --yes)"
: > "$FAKE_RUNNING_VOL"
[[ "$out" == *"Skipping ai-containers-vartmp-tbusy — a running container is using it."* ]] && tvol ai-containers-vartmp-tbusy \
  && pass "gc skips a temp volume a running container uses" \
  || fail "gc skips an in-use temp volume (got: $out)"
tclean ai-containers-vartmp-tbusy
out="$(run_group gc --yes)"; rc=$?
[[ "$rc" -eq 0 ]] && grep -qxF 'Nothing to collect: every Ruby, temp and cache volume of this home has a group directory.' <<<"$out" \
  && pass "gc has nothing to collect when every Ruby and temp volume has its group directory" \
  || fail "gc with nothing to collect, temp volumes present (rc=$rc; got: $out)"
tclean ai-containers-vartmp-x ai-containers-vartmp-a-vartmp-tnest

# Under nested prefixes the temp volume of prefix ai-containers-rvm-x,
# ai-containers-rvm-x-vartmp-tn, is listed with this prefix's Ruby volumes. It
# carries no Ruby label, and by its name it was group x-vartmp-tn's, which has
# no directory: an orphan of this home's, which plain gc removed. A volume that
# carries a temp volume's label is never a Ruby volume.
mktmpvol ai-containers-rvm-x-vartmp-tn tn
out="$(run_group list)"
[[ "$out" != *ai-containers-rvm-x-vartmp-tn* ]] \
  && pass "list does not take a nested prefix's temp volume for an orphaned Ruby volume" \
  || fail "list names a nested prefix's temp volume as a Ruby orphan (got: $out)"
out="$(run_group gc --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" != *ai-containers-rvm-x-vartmp-tn* ]] && tvol ai-containers-rvm-x-vartmp-tn \
  && pass "gc leaves a nested prefix's temp volume that is named like a Ruby volume" \
  || fail "gc took a nested prefix's temp volume for a Ruby orphan (rc=$rc; got: $out)"
out="$(run_group gc --all --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" != *ai-containers-rvm-x-vartmp-tn* ]] && tvol ai-containers-rvm-x-vartmp-tn \
  && pass "gc --all leaves it too" \
  || fail "gc --all took a nested prefix's temp volume for a Ruby orphan (rc=$rc; got: $out)"
# And where ~/.ai-containers is gone, which makes every volume a group's is an orphan.
EH="$TMP/empty-home-nest"; mkdir -p "$EH"
out="$(HOME="$EH" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" gc --all --yes 2>&1)"; rc=$?
[[ "$rc" -eq 0 && "$out" != *ai-containers-rvm-x-vartmp-tn* ]] && tvol ai-containers-rvm-x-vartmp-tn \
  && pass "gc --all with no groups root leaves it too" \
  || fail "gc --all with no groups root took a nested prefix's temp volume (rc=$rc; got: $out)"
rmdir "$EH"
tclean ai-containers-rvm-x-vartmp-tn

# With ~/.ai-containers itself gone, every labelled temp volume is an orphan,
# and a volume of the temp name with no label is still no group's: list does not
# name it, and gc --all, which takes every orphan whoever made it, leaves it.
EH="$TMP/empty-home-tmp"; mkdir -p "$EH"
mktmpvol ai-containers-vartmp-tgone tgone; : > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-x"
out="$(HOME="$EH" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" list 2>&1)"
[[ "$out" == *"ai-containers-vartmp-tgone  (another home's"* && "$out" != *ai-containers-vartmp-x* ]] \
  && pass "list with no groups root names an orphaned temp volume, and not an unlabelled one" \
  || fail "list with no groups root, temp volumes (got: $out)"
out="$(HOME="$EH" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" gc --all --yes 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && ! tvol ai-containers-vartmp-tgone && tvol ai-containers-vartmp-x && [[ "$out" != *ai-containers-vartmp-x* ]] \
  && pass "gc --all with no groups root takes the orphaned temp volume and leaves an unlabelled one" \
  || fail "gc --all with no groups root, temp volumes (rc=$rc; got: $out)"
rmdir "$EH"; tclean ai-containers-vartmp-tgone ai-containers-vartmp-x

# rm: the directory and both volumes; every volume checked before anything goes.
mkdir -p "$GR/tb2"; mkvol ai-containers-rvm-tb2 tb2; mktmpvol ai-containers-vartmp-tb2 tb2
printf 'ai-containers-vartmp-tb2' > "$FAKE_RUNNING_VOL"
out="$(run_group rm tb2 --yes)"; rc=$?
: > "$FAKE_RUNNING_VOL"
[[ "$rc" -ne 0 && -d "$GR/tb2" && "$out" == *"a running container is still using ai-containers-vartmp-tb2. Stop it first."* ]] \
  && tvol ai-containers-rvm-tb2 && tvol ai-containers-vartmp-tb2 \
  && pass "rm refuses while only the temp volume is in use, and removes neither volume nor the directory" \
  || fail "rm with the temp volume in use (rc=$rc; got: $out)"
out="$(FAKE_PS_FAIL_VOL=ai-containers-vartmp-tb2 run_group rm tb2 --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/tb2" && "$out" == *"whether one uses ai-containers-vartmp-tb2 cannot be told"* ]] \
  && tvol ai-containers-rvm-tb2 && tvol ai-containers-vartmp-tb2 \
  && pass "rm refuses when docker cannot say whether a container uses the temp volume, removing nothing" \
  || fail "rm with the temp volume's use unknown (rc=$rc; got: $out)"
printf 'ai-containers-rvm-tb2' > "$FAKE_RUNNING_VOL"
out="$(run_group rm tb2 --yes)"; rc=$?
: > "$FAKE_RUNNING_VOL"
[[ "$rc" -ne 0 && -d "$GR/tb2" ]] && tvol ai-containers-rvm-tb2 && tvol ai-containers-vartmp-tb2 \
  && pass "rm refuses while only the Ruby volume is in use, and removes neither volume nor the directory" \
  || fail "rm with the Ruby volume in use, temp volume present (rc=$rc; got: $out)"
: > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-tb2.rmfail"
out="$(run_group rm tb2 --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/tb2" && "$out" == *"could not remove volume ai-containers-vartmp-tb2"* ]] \
  && pass "rm whose temp volume removal fails exits non-zero and leaves the directory" \
  || fail "rm whose temp volume removal fails (rc=$rc; got: $out)"
tclean ai-containers-vartmp-tb2.rmfail
# A Ruby volume docker will not remove does not stop rm trying the temp volume;
# the directory stays, since one of its volumes does.
mkvol ai-containers-rvm-tb2 tb2; mktmpvol ai-containers-vartmp-tb2 tb2
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-tb2.rmfail"
out="$(run_group rm tb2 --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/tb2" && "$out" == *"could not remove volume ai-containers-rvm-tb2"* ]] \
  && tvol ai-containers-rvm-tb2 && ! tvol ai-containers-vartmp-tb2 \
  && pass "rm whose Ruby volume removal fails still removes the temp volume, and leaves the directory" \
  || fail "rm whose Ruby volume removal fails (rc=$rc; got: $out)"
tclean ai-containers-rvm-tb2.rmfail
# The temp volume's existence docker cannot say, after it answered for the Ruby
# volume: refused, nothing removed.
mktmpvol ai-containers-vartmp-tb2 tb2
out="$(FAKE_INSPECT_FAIL=ai-containers-vartmp-tb2 run_group rm tb2 --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/tb2" && "$out" == *"docker could not say whether ai-containers-vartmp-tb2 exists"* ]] \
  && tvol ai-containers-rvm-tb2 && tvol ai-containers-vartmp-tb2 \
  && pass "rm refuses when docker cannot say whether the temp volume exists, removing nothing" \
  || fail "rm with the temp volume's existence unknown (rc=$rc; got: $out)"
mkvol ai-containers-rvm-tb2 tb2
out="$(run_group rm tb2 --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/tb2" ]] && ! tvol ai-containers-rvm-tb2 && ! tvol ai-containers-vartmp-tb2 \
  && grep -qxF '  rvm volume ai-containers-rvm-tb2 (installed rubies and gems)' <<<"$out" \
  && grep -qxF "  temp volume ai-containers-vartmp-tb2 (its containers' /var/tmp)" <<<"$out" \
  && [[ "$out" == *"Removed volume ai-containers-vartmp-tb2"* ]] \
  && pass "rm removes the directory and both volumes, listing each" \
  || fail "rm of a group with both volumes (rc=$rc; got: $out)"
# A temp volume another home made is kept and named; this home's Ruby volume
# and the directory go.
mkdir -p "$GR/tsh"; mkvol ai-containers-rvm-tsh tsh; VOL_OWNER="$THEIRS" mktmpvol ai-containers-vartmp-tsh tsh
out="$(run_group rm tsh --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/tsh" ]] && ! tvol ai-containers-rvm-tsh && tvol ai-containers-vartmp-tsh \
  && [[ "$out" == *"temp volume ai-containers-vartmp-tsh is kept: another home on this docker made it"* ]] \
  && pass "rm keeps and names a temp volume another home made, removing the Ruby volume and the directory" \
  || fail "rm with another home's temp volume (rc=$rc; got: $out)"
# With nothing else of the group left here, that volume alone is no group of
# this home's to remove.
out="$(run_group rm tsh --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"ai-containers-vartmp-tsh was made by another home"* && "$out" == *"docker volume rm ai-containers-vartmp-tsh"* ]] \
  && tvol ai-containers-vartmp-tsh \
  && pass "rm of only another home's temp volume is refused, with the command that removes it anyway" \
  || fail "rm of only another home's temp volume (rc=$rc; got: $out)"
tclean ai-containers-vartmp-tsh
# A volume of the temp name without the group's label is named, with its
# docker volume rm, and never removed; the rest of the group goes.
mkdir -p "$GR/tun"; mkvol ai-containers-rvm-tun tun; : > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-tun"
out="$(run_group rm tun --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/tun" && "$out" == *"docker volume rm ai-containers-vartmp-tun"* ]] \
  && ! tvol ai-containers-rvm-tun && tvol ai-containers-vartmp-tun && [[ "$out" != *"Removed volume ai-containers-vartmp-tun"* ]] \
  && [[ "$out" == *"it has no temp volume label, so it is not the temp volume of group \"tun\""* ]] \
  && pass "rm names an unlabelled volume of the temp name with its docker volume rm, and leaves it" \
  || fail "rm with an unlabelled temp-name volume (rc=$rc; got: $out)"
# That volume alone is no group: refused, still named.
out="$(run_group rm tun --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *'no such group "tun"'* && "$out" == *"docker volume rm ai-containers-vartmp-tun"* ]] && tvol ai-containers-vartmp-tun \
  && pass "rm of a group with only an unlabelled temp-name volume is no such group, the volume named and left" \
  || fail "rm of only an unlabelled temp-name volume (rc=$rc; got: $out)"
tclean ai-containers-vartmp-tun
mkdir -p "$GR/tlab"; mktmpvol ai-containers-vartmp-tlab tother
out="$(run_group rm tlab --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/tlab" && "$out" == *'its label names group "tother", so it is not the temp volume of group "tlab";'* ]] \
  && [[ "$out" == *"it may be that group's volume under another REPO_VOLUME_PREFIX"* && "$out" != *"docker volume rm ai-containers-vartmp-tlab"* ]] \
  && tvol ai-containers-vartmp-tlab \
  && pass "rm names a temp-name volume labelled for another group, and leaves it, with no command to remove it" \
  || fail "rm with a temp-name volume of another group (rc=$rc; got: $out)"
tclean ai-containers-vartmp-tlab
# A group that is only a temp volume, no directory and no Ruby volume, is found
# and removed.
mktmpvol ai-containers-vartmp-tlone tlone
out="$(run_group rm tlone --yes)"; rc=$?
[[ "$rc" -eq 0 ]] && ! tvol ai-containers-vartmp-tlone \
  && grep -qxF "  temp volume ai-containers-vartmp-tlone (its containers' /var/tmp)" <<<"$out" && [[ "$out" != *"  directory  "* ]] \
  && pass "rm finds and removes a group that is only a temp volume" \
  || fail "rm of a group that is only a temp volume (rc=$rc; got: $out)"

# A docker that says a volume exists and then cannot say whose it is is not one
# that says it has no label. Read so, rm took the group's own temp volume for
# not the group's, removed the directory and the Ruby volume and left the temp
# volume behind; and it took another home's Ruby volume for one with no owner
# label, and removed it. rm refuses, removing nothing, as it does when docker
# cannot say whether the volume exists; list says the state is unknown.
mkdir -p "$GR/tlf"; mkvol ai-containers-rvm-tlf tlf; mktmpvol ai-containers-vartmp-tlf tlf
out="$(FAKE_LABEL_FAIL=ai-containers-vartmp-tlf run_group rm tlf --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/tlf" && "$out" == *"docker could not say whose ai-containers-vartmp-tlf is"* ]] \
  && tvol ai-containers-rvm-tlf && tvol ai-containers-vartmp-tlf \
  && pass "rm refuses when docker cannot read the temp volume's labels, removing nothing" \
  || fail "rm with the temp volume's labels unreadable (rc=$rc; got: $out)"
mkdir -p "$GR/tlf"; mkvol ai-containers-rvm-tlf tlf; mktmpvol ai-containers-vartmp-tlf tlf
out="$(FAKE_LABEL_FAIL=ai-containers-vartmp-tlf run_group list)"; rc=$?
grep -qE '^tlf +ai-containers-rvm-tlf +present +ai-containers-vartmp-tlf +unknown +- +none$' <<<"$out" \
  && [[ "$rc" -ne 0 && "$out" == *"ERROR: docker could not say whether some volumes exist or whose they are"* ]] \
  && pass "list says a temp volume whose labels docker cannot read is unknown, not another group's, and exits 1" \
  || fail "list with the temp volume's labels unreadable (rc=$rc; got: $out)"
# Nor is a docker that cannot say whether the volume exists one that says it
# does not: the row's state is unknown, not none.
out="$(FAKE_INSPECT_FAIL=ai-containers-vartmp-tlf run_group list)"; rc=$?
grep -qE '^tlf +ai-containers-rvm-tlf +present +ai-containers-vartmp-tlf +unknown +- +none$' <<<"$out" \
  && [[ "$rc" -ne 0 && "$out" == *"ERROR: docker could not say whether some volumes exist or whose they are"* ]] \
  && pass "list says a volume docker cannot say exists is unknown, not none, and exits 1" \
  || fail "list with the temp volume's existence unknown (rc=$rc; got: $out)"
out="$(FAKE_INSPECT_FAIL=ai-containers-rvm-tlf run_group list)"; rc=$?
grep -qE '^tlf +ai-containers-rvm-tlf +unknown +ai-containers-vartmp-tlf +present +- +none$' <<<"$out" \
  && [[ "$rc" -ne 0 && "$out" == *"ERROR: docker could not say whether some volumes exist or whose they are"* ]] \
  && pass "list says a Ruby volume docker cannot say exists is unknown, and exits 1" \
  || fail "list with the Ruby volume's existence unknown (rc=$rc; got: $out)"
# With every volume known, list exits 0 and says nothing of the kind.
out="$(run_group list)"; rc=$?
grep -qE '^tlf +ai-containers-rvm-tlf +present +ai-containers-vartmp-tlf +present +- +none$' <<<"$out" \
  && [[ "$rc" -eq 0 && "$out" != *"ERROR:"* ]] \
  && pass "list with every volume known exits 0, with no ERROR" \
  || fail "list with every volume known (rc=$rc; got: $out)"
VOL_OWNER="$THEIRS" mkvol ai-containers-rvm-tlf tlf
out="$(FAKE_LABEL_FAIL=ai-containers-rvm-tlf run_group rm tlf --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/tlf" && "$out" == *"docker could not say whose ai-containers-rvm-tlf is"* ]] \
  && tvol ai-containers-rvm-tlf && tvol ai-containers-vartmp-tlf \
  && pass "rm refuses when docker cannot read the Ruby volume's labels, keeping another home's volume" \
  || fail "rm with the Ruby volume's labels unreadable (rc=$rc; got: $out)"
# Each label rm judges a Ruby volume by, read alone and failing, refuses too.
for key in ai-containers.vartmp-group ai-containers.rvm-group ai-containers.owner; do
  out="$(FAKE_LABEL_FAIL=ai-containers-rvm-tlf FAKE_LABEL_FAIL_KEY="$key" run_group rm tlf --yes)"; rc=$?
  [[ "$rc" -ne 0 && -d "$GR/tlf" && "$out" == *"docker could not say whose ai-containers-rvm-tlf is"* ]] \
    && tvol ai-containers-rvm-tlf && tvol ai-containers-vartmp-tlf \
    && pass "rm refuses when docker cannot read the Ruby volume's $key label alone" \
    || fail "rm with the Ruby volume's $key label unreadable (rc=$rc; got: $out)"
  mkdir -p "$GR/tlf"; VOL_OWNER="$THEIRS" mkvol ai-containers-rvm-tlf tlf; mktmpvol ai-containers-vartmp-tlf tlf
done
rm -rf "$GR/tlf"; tclean ai-containers-rvm-tlf ai-containers-vartmp-tlf

# A group's Ruby volume was its by its name alone in rm and in list's row, so a
# group named like another prefix's volume took that volume: prefix
# ai-containers-rvm-x's temp volume ai-containers-rvm-x-vartmp-tn has the Ruby
# volume name of group x-vartmp-tn here, and that prefix's Ruby volume of group
# g, ai-containers-rvm-x-rvm-g, the one of group x-rvm-g. A volume of the Ruby
# name that carries a temp volume's label, or another group's Ruby label, is not
# the group's: named and left, with no command to remove it, since it may be in
# use under its own prefix. One with no label, made before labels, is still the
# group's.
mktmpvol ai-containers-rvm-x-vartmp-tn tn
out="$(run_group rm x-vartmp-tn --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *'no such group "x-vartmp-tn"'* && "$out" != *"no volume ai-containers-rvm-x-vartmp-tn"* ]] \
  && [[ "$out" == *'it is a temp volume, its label naming group "tn", so it is not the Ruby volume of group "x-vartmp-tn";'* ]] \
  && [[ "$out" != *"docker volume rm ai-containers-rvm-x-vartmp-tn"* ]] && tvol ai-containers-rvm-x-vartmp-tn \
  && pass "rm leaves a nested prefix's temp volume that has the group's Ruby volume name, naming it" \
  || fail "rm took a nested prefix's temp volume for the group's Ruby volume (rc=$rc; got: $out)"
mkdir -p "$GR/x-vartmp-tn"
out="$(run_group list)"
grep -qE "^x-vartmp-tn +ai-containers-rvm-x-vartmp-tn +not the group's +" <<<"$out" \
  && pass "list names a temp volume with the group's Ruby volume name as not the group's" \
  || fail "list, a temp volume with the group's Ruby volume name (got: $out)"
rmdir "$GR/x-vartmp-tn"; tclean ai-containers-rvm-x-vartmp-tn
mkvol ai-containers-rvm-x-rvm-g g; mkdir -p "$GR/x-rvm-g"
out="$(run_group rm x-rvm-g --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/x-rvm-g" && "$out" == *'its label names group "g", so it is not the Ruby volume of group "x-rvm-g"'* ]] \
  && [[ "$out" != *"docker volume rm ai-containers-rvm-x-rvm-g"* ]] && tvol ai-containers-rvm-x-rvm-g \
  && pass "rm leaves a volume of the Ruby name labelled for another group, removing the directory" \
  || fail "rm took another group's Ruby volume by its name (rc=$rc; got: $out)"
rm -rf "$GR/x-rvm-g"; tclean ai-containers-rvm-x-rvm-g
# gc and list's orphans read a label docker failed to return as no label too.
# With --all, an orphaned Ruby volume of this home whose labels could not be read
# was removed all the same, and so was a nested prefix's temp volume named like
# a Ruby volume (ai-containers-rvm-x-vartmp-tn): no temp label read, its name
# made it group x-vartmp-tn's orphan, with no owner label. A temp volume whose
# label could not be read was passed over in silence. A volume gc cannot judge is
# skipped and named, and gc exits 1; list leaves it out of the orphans and exits 1.
mktmpvol ai-containers-rvm-x-vartmp-tn tn
out="$(FAKE_LABEL_FAIL=ai-containers-rvm-x-vartmp-tn run_group gc --all --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"Skipping ai-containers-rvm-x-vartmp-tn — docker could not say whose it is."* ]] \
  && tvol ai-containers-rvm-x-vartmp-tn \
  && pass "gc --all skips a nested prefix's temp volume whose labels docker cannot read, naming it, and exits 1" \
  || fail "gc --all with a nested prefix's temp volume's labels unreadable (rc=$rc; got: $out)"
tclean ai-containers-rvm-x-vartmp-tn
mkvol ai-containers-rvm-tgo tgo
for key in ai-containers.vartmp-group ai-containers.rvm-group ai-containers.owner; do
  out="$(FAKE_LABEL_FAIL=ai-containers-rvm-tgo FAKE_LABEL_FAIL_KEY="$key" run_group gc --all --yes)"; rc=$?
  [[ "$rc" -ne 0 && "$out" == *"Skipping ai-containers-rvm-tgo — docker could not say whose it is."* ]] && tvol ai-containers-rvm-tgo \
    && pass "gc --all skips an orphaned Ruby volume whose $key label docker cannot read, and exits 1" \
    || fail "gc --all with an orphaned Ruby volume's $key label unreadable (rc=$rc; got: $out)"
  mkvol ai-containers-rvm-tgo tgo
done
out="$(FAKE_LABEL_FAIL=ai-containers-rvm-tgo run_group list)"; rc=$?
[[ "$rc" -ne 0 && "$out" != *"  ai-containers-rvm-tgo"* && "$out" == *"ERROR: docker could not say whether some volumes exist or whose they are"* ]] \
  && pass "list does not name an orphan it cannot judge, and exits 1" \
  || fail "list with an orphan's labels unreadable (rc=$rc; got: $out)"
tclean ai-containers-rvm-tgo
mktmpvol ai-containers-vartmp-tgt tgt
out="$(FAKE_LABEL_FAIL=ai-containers-vartmp-tgt run_group gc --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"Skipping ai-containers-vartmp-tgt — docker could not say whose it is."* ]] && tvol ai-containers-vartmp-tgt \
  && pass "gc names a temp volume whose label docker cannot read, rather than pass it over, and exits 1" \
  || fail "gc with an orphaned temp volume's label unreadable (rc=$rc; got: $out)"
tclean ai-containers-vartmp-tgt
# A Ruby volume's group is its label's, and only one with no label is its
# name's: gc --all takes an orphaned Ruby volume with no label by its name, and
# keeps one whose label names a group that has a directory, whatever its name.
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-tnolab"
mkdir -p "$GR/g336"; mkvol ai-containers-rvm-x-rvm-g336 g336
out="$(run_group gc --all --yes)"; rc=$?
[[ "$rc" -eq 0 ]] && ! tvol ai-containers-rvm-tnolab && tvol ai-containers-rvm-x-rvm-g336 \
  && pass "gc --all takes an unlabelled orphaned Ruby volume by its name, and keeps one whose label names an existing group" \
  || fail "gc --all, a Ruby volume's group by label or name (rc=$rc; got: $out)"
rm -rf "$GR/g336"; tclean ai-containers-rvm-x-rvm-g336 ai-containers-rvm-tnolab
mkdir -p "$GR/tleg"; : > "$FAKE_VOLUMES_DIR/ai-containers-rvm-tleg"
out="$(run_group rm tleg --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/tleg" ]] && ! tvol ai-containers-rvm-tleg \
  && pass "rm still removes a Ruby volume with no label, made before labels" \
  || fail "rm of a group whose Ruby volume has no label (rc=$rc; got: $out)"
rm -rf "$GR/tleg"; tclean ai-containers-rvm-tleg
rmdir "$GR/tboth" "$GR/tonly"
tclean ai-containers-rvm-tboth ai-containers-vartmp-tboth ai-containers-vartmp-tonly

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

# ── The cache volume ────────────────────────────────────────────────────────────
# A group's ~/.cache is a third volume, <prefix>-cache-<group>, known by its
# ai-containers.cache-group label alone, as the temp volume is by its own. list,
# rm and gc treat it as they treat the other two, each volume on its own.
GR="$FAKE_HOME/.ai-containers"
THEIRS="sha256:$(printf '%064d' 7)"
# mkcvol <volume> <group>: a cache volume this home's launch made, labelled as
# sandbox-common.sh: `_group_volume_ensure()` labels one; VOL_OWNER as for mkvol.
mkcvol() {
  : > "$FAKE_VOLUMES_DIR/$1"
  { printf 'ai-containers.cache-group=%s\n' "$2"; [[ -z "${VOL_OWNER-$OWN}" ]] || printf 'ai-containers.owner=%s\n' "${VOL_OWNER-$OWN}"; } > "$FAKE_VOLUMES_DIR/$1.labels"
}
: > "$FAKE_RUNNING_VOL"

out="$(run_group --help)"
grep -qF 'docker volume rm <prefix>-cache-<group>' <<<"$out" \
  && pass "usage says how to empty a group's cache" || fail "usage: emptying the cache (got: $out)"

# list: the three volumes of a group, the cache one's state, in use, size.
mkdir -p "$GR/call"; mkvol ai-containers-rvm-call call; mktmpvol ai-containers-vartmp-call call; mkcvol ai-containers-cache-call call
mkdir -p "$GR/conly"; mkcvol ai-containers-cache-conly conly
out="$(run_group list)"
grep -qE '^call +ai-containers-rvm-call +present +ai-containers-vartmp-call +present +ai-containers-cache-call +present$' <<<"$out" \
  && grep -qE '^conly +- +none +- +none +ai-containers-cache-conly +present$' <<<"$out" \
  && pass "list shows a group's cache volume as the third, present" \
  || fail "list, cache volumes (got: $out)"
printf 'ai-containers-cache-call' > "$FAKE_RUNNING_VOL"
out="$(run_group list)"
grep -qE '^call +ai-containers-rvm-call +present +ai-containers-vartmp-call +present +ai-containers-cache-call +present \(in use\)$' <<<"$out" \
  && pass "list marks an in-use cache volume, and only it" || fail "list, cache in use (got: $out)"
: > "$FAKE_RUNNING_VOL"
printf '3.2GB' > "$FAKE_VOLUMES_DIR/ai-containers-cache-call.size"
out="$(run_group list --sizes)"
grep -qE '^call +ai-containers-rvm-call +- +ai-containers-vartmp-call +- +ai-containers-cache-call +3\.2GB +[0-9?]' <<<"$out" \
  && pass "list --sizes shows the cache volume's size" || fail "list --sizes, cache (got: $out)"
rm -f "$FAKE_VOLUMES_DIR/ai-containers-cache-call.size"
# One of the cache name with no label, or another group's: not the group's.
mkdir -p "$GR/cunl"; : > "$FAKE_VOLUMES_DIR/ai-containers-cache-cunl"
mkdir -p "$GR/cmix"; mkcvol ai-containers-cache-cmix cother
out="$(run_group list)"
grep -qE "^cunl +- +none +- +none +ai-containers-cache-cunl +not the group's$" <<<"$out" \
  && grep -qE "^cmix +- +none +- +none +ai-containers-cache-cmix +not the group's$" <<<"$out" \
  && pass "list shows a cache-named volume that is not the group's as such" \
  || fail "list, a cache-named volume not the group's (got: $out)"
# A cache volume docker cannot read the labels of is unknown, and list exits 1.
out="$(FAKE_LABEL_FAIL=ai-containers-cache-call FAKE_LABEL_FAIL_KEY=ai-containers.cache-group run_group list)"; rc=$?
grep -qE '^call +ai-containers-rvm-call +present +ai-containers-vartmp-call +present +ai-containers-cache-call +unknown$' <<<"$out" \
  && [[ "$rc" -ne 0 ]] \
  && pass "list says a cache volume whose labels docker cannot read is unknown, and exits 1" \
  || fail "list, cache labels unreadable (rc=$rc; got: $out)"

# rm of a group with a cache-named volume that is not its own: named, kept,
# with the docker volume rm only for the unlabelled one; the directory goes.
out="$(run_group rm cunl --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/cunl" ]] && tvol ai-containers-cache-cunl \
  && grep -qF '(volume ai-containers-cache-cunl is kept: it has no cache volume label, so it is not the cache volume of group "cunl".' <<<"$out" \
  && grep -qF 'Once nothing in it is needed: docker volume rm ai-containers-cache-cunl)' <<<"$out" \
  && pass "rm names an unlabelled cache-named volume with its docker volume rm, and keeps it" \
  || fail "rm, an unlabelled cache-named volume (rc=$rc; got: $out)"
out="$(run_group rm cmix --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/cmix" ]] && tvol ai-containers-cache-cmix \
  && grep -qF '(volume ai-containers-cache-cmix is kept: its label names group "cother", so it is not the cache volume of group "cmix";' <<<"$out" \
  && [[ "$out" != *"docker volume rm ai-containers-cache-cmix"* ]] \
  && pass "rm names another group's cache-named volume, with no docker volume rm, and keeps it" \
  || fail "rm, another group's cache-named volume (rc=$rc; got: $out)"
tclean ai-containers-cache-cunl ai-containers-cache-cmix

# list orphans and gc: this home's orphaned cache volume, another home's, one with
# no owner label; never an unlabelled one, nor one labelled for a group whose
# cache volume name it does not carry (a nested prefix's).
mkcvol ai-containers-cache-cghost cghost
VOL_OWNER="$THEIRS" mkcvol ai-containers-cache-ctheirs ctheirs
VOL_OWNER="" mkcvol ai-containers-cache-cold cold
: > "$FAKE_VOLUMES_DIR/ai-containers-cache-x"
mkcvol ai-containers-cache-a-cache-cnest cnest
out="$(run_group list)"
grep -q '^Orphaned Ruby, temp and cache volume(s) with no group directory' <<<"$out" \
  && grep -qxF '  ai-containers-cache-cghost' <<<"$out" \
  && grep -qxF "  ai-containers-cache-ctheirs  (another home's: gc keeps it unless --all)" <<<"$out" \
  && grep -qxF '  ai-containers-cache-cold  (no owner label: gc keeps it unless --all)' <<<"$out" \
  && [[ "$out" != *ai-containers-cache-x* && "$out" != *a-cache-cnest* ]] \
  && pass "list names orphaned cache volumes with their owners, never an unlabelled or a nested prefix's" \
  || fail "list, orphaned cache volumes (got: $out)"
out="$(run_group gc --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"Removed ai-containers-cache-cghost"* ]] && ! tvol ai-containers-cache-cghost \
  && tvol ai-containers-cache-ctheirs && tvol ai-containers-cache-cold \
  && tvol ai-containers-cache-x && tvol ai-containers-cache-a-cache-cnest \
  && tvol ai-containers-cache-call && tvol ai-containers-cache-conly \
  && pass "gc removes this home's orphaned cache volume, and keeps another's, an unlabelled one and every group's" \
  || fail "gc, cache volumes (rc=$rc; got: $out)"
out="$(run_group gc --all --yes)"; rc=$?
[[ "$rc" -eq 0 ]] && ! tvol ai-containers-cache-ctheirs && ! tvol ai-containers-cache-cold \
  && tvol ai-containers-cache-x && tvol ai-containers-cache-a-cache-cnest \
  && pass "gc --all takes the other orphaned cache volumes, and never an unlabelled or a nested prefix's" \
  || fail "gc --all, cache volumes (rc=$rc; got: $out)"
mkcvol ai-containers-cache-cbusy cbusy
printf 'ai-containers-cache-cbusy' > "$FAKE_RUNNING_VOL"
out="$(run_group gc --yes)"; rc=$?
[[ "$out" == *"Skipping ai-containers-cache-cbusy — a running container is using it."* ]] && tvol ai-containers-cache-cbusy \
  && pass "gc skips an orphaned cache volume a running container uses" || fail "gc, a busy cache volume (rc=$rc; got: $out)"
: > "$FAKE_RUNNING_VOL"
tclean ai-containers-cache-cbusy ai-containers-cache-x ai-containers-cache-a-cache-cnest

# With ~/.ai-containers itself gone, every labelled cache volume is an orphan,
# and one of the cache name with no label, or labelled for a group whose cache
# volume name it does not carry, is still no group's: list does not name them,
# and gc --all, which takes every orphan whoever made it, leaves them. In a
# volume store of its own: gc --all here takes every group's cache volume.
EH="$TMP/empty-home-cache"; mkdir -p "$EH"
FAKE_VOLUMES_SAVED="$FAKE_VOLUMES_DIR"; FAKE_VOLUMES_DIR="$TMP/volumes-cache-eh"; mkdir -p "$FAKE_VOLUMES_DIR"
mkcvol ai-containers-cache-cgone cgone; : > "$FAKE_VOLUMES_DIR/ai-containers-cache-x"
mkcvol ai-containers-cache-a-cache-cnest cnest
out="$(HOME="$EH" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" list 2>&1)"
[[ "$out" == *"ai-containers-cache-cgone  (another home's"* && "$out" != *ai-containers-cache-x* && "$out" != *a-cache-cnest* ]] \
  && pass "list with no groups root names an orphaned cache volume, and not an unlabelled or a nested prefix's" \
  || fail "list with no groups root, cache volumes (got: $out)"
out="$(HOME="$EH" PATH="$FAKE_BIN:$PATH" FAKE_VOLUMES_DIR="$FAKE_VOLUMES_DIR" FAKE_RUNNING_VOL="$FAKE_RUNNING_VOL" bash "$REPO_DIR/group.sh" gc --all --yes 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && ! tvol ai-containers-cache-cgone && tvol ai-containers-cache-x && tvol ai-containers-cache-a-cache-cnest \
  && [[ "$out" != *ai-containers-cache-x* && "$out" != *a-cache-cnest* ]] \
  && pass "gc --all with no groups root takes the orphaned cache volume and leaves an unlabelled and a nested prefix's" \
  || fail "gc --all with no groups root, cache volumes (rc=$rc; got: $out)"
rmdir "$EH"; rm -rf "${FAKE_VOLUMES_DIR:?}"; FAKE_VOLUMES_DIR="$FAKE_VOLUMES_SAVED"

# Under nested prefixes the cache volume of prefix ai-containers-rvm-x,
# ai-containers-rvm-x-cache-cn, is listed with this prefix's Ruby volumes; it
# carries a cache label, so it is never a Ruby volume: not an orphan of group
# x-cache-cn, not removed by gc, and named, not removed, by rm of that group.
mkcvol ai-containers-rvm-x-cache-cn cn
out="$(run_group list)"
[[ "$out" != *ai-containers-rvm-x-cache-cn* ]] \
  && pass "list does not take a nested prefix's cache volume for an orphaned Ruby volume" \
  || fail "list names a nested prefix's cache volume as a Ruby orphan (got: $out)"
out="$(run_group gc --all --yes)"; rc=$?
[[ "$rc" -eq 0 && "$out" != *ai-containers-rvm-x-cache-cn* ]] && tvol ai-containers-rvm-x-cache-cn \
  && pass "gc --all leaves a nested prefix's cache volume named like a Ruby volume" \
  || fail "gc --all took a nested prefix's cache volume (rc=$rc; got: $out)"
mkdir -p "$GR/x-cache-cn"
out="$(run_group rm x-cache-cn --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/x-cache-cn" ]] && tvol ai-containers-rvm-x-cache-cn \
  && grep -qF '(volume ai-containers-rvm-x-cache-cn is kept: it is a cache volume, its label naming group "cn", so it is not the Ruby volume of group "x-cache-cn";' <<<"$out" \
  && pass "rm names a cache volume of its Ruby volume name, and keeps it" \
  || fail "rm, a cache volume named like its Ruby volume (rc=$rc; got: $out)"
# One whose cache label docker cannot read is neither: list exits 1, rm refuses.
out="$(FAKE_LABEL_FAIL=ai-containers-rvm-x-cache-cn FAKE_LABEL_FAIL_KEY=ai-containers.cache-group run_group list)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"ERROR: docker could not say whether some volumes exist or whose they are"* ]] \
  && pass "list exits 1 when docker cannot read a Ruby-named volume's cache label" \
  || fail "list, a Ruby-named volume's cache label unreadable (rc=$rc; got: $out)"
mkdir -p "$GR/x-cache-cn"
out="$(FAKE_LABEL_FAIL=ai-containers-rvm-x-cache-cn FAKE_LABEL_FAIL_KEY=ai-containers.cache-group run_group rm x-cache-cn --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/x-cache-cn" && "$out" == *"docker could not say whose ai-containers-rvm-x-cache-cn is"* ]] \
  && tvol ai-containers-rvm-x-cache-cn \
  && pass "rm refuses when docker cannot read a Ruby-named volume's cache label" \
  || fail "rm, a Ruby-named volume's cache label unreadable (rc=$rc; got: $out)"
rmdir "$GR/x-cache-cn"; tclean ai-containers-rvm-x-cache-cn

# rm: the directory and all three volumes, each checked before anything goes.
printf 'ai-containers-cache-call' > "$FAKE_RUNNING_VOL"
out="$(run_group rm call --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/call" && "$out" == *"a running container is still using ai-containers-cache-call. Stop it first."* ]] \
  && tvol ai-containers-rvm-call && tvol ai-containers-vartmp-call && tvol ai-containers-cache-call \
  && pass "rm refuses while a running container uses the cache volume, removing nothing" \
  || fail "rm, an in-use cache volume (rc=$rc; got: $out)"
: > "$FAKE_RUNNING_VOL"
: > "$FAKE_VOLUMES_DIR/ai-containers-cache-call.rmfail"
out="$(run_group rm call --yes)"; rc=$?
[[ "$rc" -ne 0 && -d "$GR/call" && "$out" == *"could not remove volume ai-containers-cache-call"* ]] \
  && ! tvol ai-containers-rvm-call && ! tvol ai-containers-vartmp-call && tvol ai-containers-cache-call \
  && pass "rm tries every volume, and keeps the directory when the cache volume will not go" \
  || fail "rm, a cache volume docker will not remove (rc=$rc; got: $out)"
rm -f "$FAKE_VOLUMES_DIR/ai-containers-cache-call.rmfail"
mkvol ai-containers-rvm-call call; mktmpvol ai-containers-vartmp-call call
out="$(run_group rm call --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/call" ]] && ! tvol ai-containers-rvm-call && ! tvol ai-containers-vartmp-call && ! tvol ai-containers-cache-call \
  && grep -qF "  cache volume ai-containers-cache-call (its containers' ~/.cache)" <<<"$out" \
  && grep -qF 'Removed volume ai-containers-cache-call' <<<"$out" \
  && pass "rm removes the directory and all three volumes, naming the cache volume and what it holds" \
  || fail "rm of a group with three volumes (rc=$rc; got: $out)"
# Another home's cache volume is kept and named; the directory goes.
VOL_OWNER="$THEIRS" mkcvol ai-containers-cache-conly conly
out="$(run_group rm conly --yes)"; rc=$?
[[ "$rc" -eq 0 && ! -d "$GR/conly" ]] && tvol ai-containers-cache-conly \
  && grep -qF '(cache volume ai-containers-cache-conly is kept: another home on this docker made it' <<<"$out" \
  && pass "rm keeps another home's cache volume, and names it" \
  || fail "rm, another home's cache volume (rc=$rc; got: $out)"
# A group with no directory and only a cache volume of its own: rm removes it.
mkcvol ai-containers-cache-conly conly
out="$(run_group rm conly --yes)"; rc=$?
[[ "$rc" -eq 0 ]] && ! tvol ai-containers-cache-conly \
  && pass "rm of a group with no directory removes its cache volume" \
  || fail "rm, a cache volume with no directory (rc=$rc; got: $out)"
out="$(run_group rm cnone --yes)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *'no such group "cnone"'*"no Ruby, temp or cache volume of its own"* ]] \
  && pass "rm of no group at all says there is no directory and no volume of any kind" \
  || fail "rm of no group (rc=$rc; got: $out)"
tclean ai-containers-cache-ctheirs ai-containers-cache-cold

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
