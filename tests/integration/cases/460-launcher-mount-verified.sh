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
# The check rests on the launcher knowing the device:inode a container sees.
# Linux engines keep the host's across a bind mount; file-sharing layers (macOS
# Docker Desktop, Colima) do not. On Colima the launcher asks Colima's VM, which
# reports what the containers see (PLAT-3); where nothing does, the guard is
# designed to step aside with a one-line NOTE rather than refuse every launch. So
# the case first PROBES which kind of host this is and asserts the behaviour that
# host must have — every branch is a real assertion, none a skip:
#
#   verifiable:  the host's ids survive the bind, or Colima's VM reports them.
#                A real launch verifies (no NOTE); a crafted mismatch REFUSES;
#                a wrong anchor notes and proceeds.
#   not:         a real launch comes up and NOTEs; a crafted mismatch is NOT
#                refused (nothing here can be verified, and a launch must not be
#                blocked for it).
#   all:         an anchor with no manifest to read NOTEs and proceeds.
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck source=tests/portability.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../portability.sh"

host_id() { p_dev_ino "$1" | tr ' ' ':'; }
# What Colima's VM reports for a path, when docker is Colima's (the same test as
# sandbox.sh: `_colima_profile()`); nothing elsewhere.
colima_prof=""
if command -v colima >/dev/null 2>&1; then
  cbase="${COLIMA_HOME:-$HOME/.colima}"
  if [[ "${IT_DOCKER_HOST:-}" == "unix://$cbase/"*/docker.sock ]]; then
    colima_prof="${IT_DOCKER_HOST#"unix://$cbase/"}"; colima_prof="${colima_prof%/docker.sock}"
  fi
fi
vm_id() {
  [[ -n "$colima_prof" ]] || return 0
  printf '%s\0' "$1" | colima ssh -p "$colima_prof" -- xargs -0 stat '--printf=%d:%i' -- 2>/dev/null
}

# ── which kind of host is this? ───────────────────────────────────────────────
# IT_SELINUX_OPT here and in entry_run, as sandbox.sh passes it: an SELinux
# daemon's labelled container cannot stat the probe, which would read as a host
# that does not preserve device:inode
# (tests/integration/run.sh: `resolve_selinux_opt()`).
probe="$(it_scratch)/probe"; mkdir -p "$probe"
ctr="$(docker run --rm --label "$IT_LABEL" ${IT_SELINUX_OPT:+"$IT_SELINUX_OPT"} -v "$probe:/p:ro" --entrypoint stat "$IT_IMAGE" -c '%d:%i' /p 2>/dev/null)"
# id_of: the device:inode the launcher records for a path on this host.
if [[ -n "$ctr" && "$ctr" == "$(host_id "$probe")" ]]; then preserving=1; id_of() { host_id "$1"; }
elif [[ -n "$ctr" && "$ctr" == "$(vm_id "$probe")" ]]; then preserving=1; id_of() { vm_id "$1"; }
else preserving=0; id_of() { host_id "$1"; }; fi
printf '     (this daemon %s device:inode across a bind mount%s)\n' \
  "$([[ "$ctr" == "$(host_id "$probe")" ]] && echo preserves || echo does NOT preserve)" \
  "$([[ "$preserving" == 1 && "$ctr" != "$(host_id "$probe")" ]] && echo "; Colima's VM reports them")"

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
logs="$(docker logs "$IT_CID" 2>&1)"   # captured, not piped: see lib.sh
noted=0; if grep -q 'does not preserve device/inode' <<<"$logs"; then noted=1; fi
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
  IFS=: read -r dev ino < <(id_of "$dd"; echo)
  manino="$ino"; [[ "$2" == 0 ]] && manino=$((ino + 4096))
  printf '%s\0%s\0%s\0' "$dev" "$manino" "/workspace/dd" > "$vr/manifest"
  anchor="$(id_of "$vr")"; [[ "$1" == 0 ]] && anchor="999999:999999"
  out="$(docker run --rm --label "$IT_LABEL" ${IT_SELINUX_OPT:+"$IT_SELINUX_OPT"} \
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

# ── an anchor with no manifest to read → note and proceed, never in silence ──
# sandbox.sh passes the anchor only with the manifest mount, so this is a check
# that cannot run, not one with nothing to do. Under SELinux with
# SELINUX_LABEL=keep a confined container cannot read a manifest in an
# unlabelled ~/.ai-containers, and the entrypoint skipped the check without a
# word. No manifest mount at all reaches the same test on every host.
out="$(docker run --rm --label "$IT_LABEL" \
  -e DEV_CONTAINER_MODE=open -e SANDBOX_UID="$IT_LAUNCH_UID" -e SANDBOX_GID="$IT_LAUNCH_GID" \
  -e SANDBOX_USER=tester -e SANDBOX_GROUP=tester -e AI_LAUNCHER_ANCHOR=1:1 \
  "$IT_IMAGE" 2>&1 </dev/null)"
if grep -q 'manifest cannot be read' <<<"$out" && ! grep -q 'refusing to' <<<"$out"; then
  pass "an anchor with no manifest to read: noted, not refused"
else
  fail "an anchor with no manifest to read must NOTE that nothing is verified (out: $(tr '\n' ' ' <<<"$out"))"
fi

it_finish
