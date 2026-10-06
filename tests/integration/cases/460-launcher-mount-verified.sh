#!/usr/bin/env bash
# summary:  the entrypoint refuses to start when a launcher mount is not the directory sandbox.sh recorded
# tags:     security mounts fast
# requires: docker launcher
#
# A container already running on an overlapping writable tree could swap the
# SOURCE of a launcher overlay/pin for a symlink between sandbox.sh's scan and
# the moment Docker resolves it, so this new container would mount an arbitrary
# host path. sandbox.sh records each launcher mount's source device:inode and
# destination in /run/ai-launcher/manifest (mounted read-only, the anchor), and
# the entrypoint re-checks every mount as root before the agent shell exists.
#
# Positive, end to end: a normal launch with launcher mounts comes up, carries
# the verify mount, and on this daemon the guard is active (no "does not
# preserve" skip). Negative and skip: the baked entrypoint is driven directly
# with a crafted manifest — a mismatch refuses the launch, a wrong anchor
# (a filesystem that does not preserve device:inode) warns and proceeds.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# ── positive: a real launch verifies its mounts and comes up ──────────────────
grp="$(it_scratch)/grp"
launcher_engine_in "$grp/proj" || it_finish
export EXTRA_MOUNTS="$grp"
launcher_up open "$grp/proj" || it_finish
if docker exec "$IT_CID" stat -c '%d:%i' /run/ai-launcher >/dev/null 2>&1; then
  pass "a verified launch carries the read-only verify mount"
else
  fail "a verified launch carries the read-only verify mount"
fi
if docker logs "$IT_CID" 2>&1 | grep -q 'does not preserve device/inode'; then
  fail "the guard is active on this daemon (device:inode is preserved, verification not skipped)"
else
  pass "the guard is active on this daemon (device:inode is preserved, verification not skipped)"
fi
sandbox_down "$IT_CID"
unset EXTRA_MOUNTS

# Drive the baked entrypoint directly with a crafted manifest.
d="$(it_scratch)"
# $1=anchor-ok(1/0) $2=entry-ok(1/0) → prints "<rc> <output>"
entry_run() {
  local vr dd dev ino manino anchor out rc
  vr="$d/vr$RANDOM"; dd="$d/dd$RANDOM"; mkdir -p "$vr" "$dd"
  read -r dev ino < <(stat -c '%d %i' "$dd")
  manino="$ino"; [[ "$2" == 0 ]] && manino=$((ino + 4096))
  printf '%s\0%s\0%s\0' "$dev" "$manino" "/workspace/dd" > "$vr/manifest"
  anchor="$(stat -c '%d:%i' "$vr")"; [[ "$1" == 0 ]] && anchor="999999:999999"
  out="$(docker run --rm --label "$IT_LABEL" \
    -e DEV_CONTAINER_MODE=open -e SANDBOX_UID="$IT_LAUNCH_UID" -e SANDBOX_GID="$IT_LAUNCH_GID" \
    -e SANDBOX_USER=tester -e SANDBOX_GROUP=tester \
    -e AI_LAUNCHER_ANCHOR="$anchor" \
    -v "$vr:/run/ai-launcher:ro" -v "$dd:/workspace/dd" \
    "$IT_IMAGE" 2>&1 </dev/null)"; rc=$?
  printf '%s\n%s' "$rc" "$out"
}

# ── negative: the mount is a different inode than recorded → refuse ────────────
res="$(entry_run 1 0)"; rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
if [[ "$rc" -ne 0 ]] && grep -q 'is not the directory it was checked as' <<<"$out" \
   && grep -q 'refusing to' <<<"$out"; then
  pass "a mount that is not what sandbox.sh recorded refuses the launch, naming it"
else
  fail "a crafted mismatch refuses the launch (rc=$rc, out: $(tr '\n' ' ' <<<"$out"))"
fi

# ── skip: the anchor itself does not survive → warn and proceed ───────────────
res="$(entry_run 0 0)"; out="${res#*$'\n'}"
if grep -q 'does not preserve device/inode' <<<"$out" \
   && ! grep -q 'is not the directory it was checked as' <<<"$out"; then
  pass "a filesystem that does not preserve device:inode warns and does not refuse"
else
  fail "the skip path warns and does not refuse (out: $(tr '\n' ' ' <<<"$out"))"
fi

it_finish
