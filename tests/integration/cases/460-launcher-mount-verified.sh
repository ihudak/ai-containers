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
# The check rests on the daemon preserving device:inode across a bind mount.
# Linux engines do; file-sharing layers (macOS Docker Desktop, Colima) do not,
# and there the guard is designed to step aside with a one-line NOTE rather than
# refuse every launch. So the case first PROBES which kind of host this is and
# asserts the behaviour that host must have — both branches are real
# assertions, neither a skip:
#
#   preserving:  a real launch verifies (no NOTE); a crafted mismatch REFUSES;
#                a wrong anchor notes and proceeds.
#   not:         a real launch comes up and NOTEs; a crafted mismatch is NOT
#                refused (nothing here can be verified, and a launch must not be
#                blocked for it).
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck source=tests/portability.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../portability.sh"

host_id() { p_dev_ino "$1" | tr ' ' ':'; }

# ── which kind of host is this? ───────────────────────────────────────────────
probe="$(it_scratch)/probe"; mkdir -p "$probe"
ctr="$(docker run --rm --label "$IT_LABEL" -v "$probe:/p:ro" --entrypoint stat "$IT_IMAGE" -c '%d:%i' /p 2>/dev/null)"
if [[ -n "$ctr" && "$ctr" == "$(host_id "$probe")" ]]; then preserving=1; else preserving=0; fi
printf '     (this daemon %s device:inode across a bind mount)\n' \
  "$([[ "$preserving" == 1 ]] && echo preserves || echo does NOT preserve)"

# ── a real launch with launcher mounts ───────────────────────────────────────
grp="$(it_scratch)/grp"
launcher_engine_in "$grp/proj" || it_finish
export EXTRA_MOUNTS="$grp"
launcher_up open "$grp/proj" || it_finish
if docker exec "$IT_CID" stat -c '%d:%i' /run/ai-launcher >/dev/null 2>&1; then
  pass "a launch with launcher mounts carries the read-only verify mount"
else
  fail "a launch with launcher mounts carries the read-only verify mount"
fi
noted=0; docker logs "$IT_CID" 2>&1 | grep -q 'does not preserve device/inode' && noted=1
if [[ "$preserving" == 1 ]]; then
  [[ "$noted" == 0 ]] \
    && pass "the guard is active here: the launch verified its mounts (no NOTE)" \
    || fail "the guard is active here: the launch verified its mounts — it NOTEd a skip instead"
else
  [[ "$noted" == 1 ]] \
    && pass "the guard steps aside here, and the launch says so in one NOTE" \
    || fail "on a non-preserving host the launch must NOTE that mounts are not verified"
fi
sandbox_down "$IT_CID"
unset EXTRA_MOUNTS

# Drive the baked entrypoint directly with a crafted manifest.
d="$(it_scratch)"
# $1=anchor-ok(1/0) $2=entry-ok(1/0) → prints "<rc>\n<output>"
entry_run() {
  local vr dd dev ino manino anchor out rc
  vr="$d/vr$RANDOM"; dd="$d/dd$RANDOM"; mkdir -p "$vr" "$dd"
  read -r dev ino < <(p_dev_ino "$dd")
  manino="$ino"; [[ "$2" == 0 ]] && manino=$((ino + 4096))
  printf '%s\0%s\0%s\0' "$dev" "$manino" "/workspace/dd" > "$vr/manifest"
  anchor="$(host_id "$vr")"; [[ "$1" == 0 ]] && anchor="999999:999999"
  out="$(docker run --rm --label "$IT_LABEL" \
    -e DEV_CONTAINER_MODE=open -e SANDBOX_UID="$IT_LAUNCH_UID" -e SANDBOX_GID="$IT_LAUNCH_GID" \
    -e SANDBOX_USER=tester -e SANDBOX_GROUP=tester \
    -e AI_LAUNCHER_ANCHOR="$anchor" \
    -v "$vr:/run/ai-launcher:ro" -v "$dd:/workspace/dd" \
    "$IT_IMAGE" 2>&1 </dev/null)"; rc=$?
  printf '%s\n%s' "$rc" "$out"
}

# ── a mount that is not what was recorded ─────────────────────────────────────
res="$(entry_run 1 0)"; rc="${res%%$'\n'*}"; out="${res#*$'\n'}"
if [[ "$preserving" == 1 ]]; then
  if [[ "$rc" -ne 0 ]] && grep -q 'is not the directory it was checked as' <<<"$out" \
     && grep -q 'refusing to' <<<"$out"; then
    pass "a mount that is not what sandbox.sh recorded refuses the launch, naming it"
  else
    fail "a crafted mismatch refuses the launch (rc=$rc, out: $(tr '\n' ' ' <<<"$out"))"
  fi
else
  if ! grep -q 'refusing to' <<<"$out" && grep -q 'does not preserve device/inode' <<<"$out"; then
    pass "here nothing can be verified: a mismatch is noted, never a refused launch"
  else
    fail "a non-preserving host must not refuse (out: $(tr '\n' ' ' <<<"$out"))"
  fi
fi

# ── the anchor itself does not survive → note and proceed ─────────────────────
res="$(entry_run 0 0)"; out="${res#*$'\n'}"
if grep -q 'does not preserve device/inode' <<<"$out" \
   && ! grep -q 'is not the directory it was checked as' <<<"$out"; then
  pass "an anchor that does not survive the mount: noted, not refused"
else
  fail "the skip path notes and does not refuse (out: $(tr '\n' ' ' <<<"$out"))"
fi

it_finish
