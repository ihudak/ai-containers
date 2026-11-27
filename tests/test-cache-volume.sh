#!/usr/bin/env bash
# Tests for the group's ~/.cache volume (sandbox-common.sh): cache_volume_name,
# cache_volumes, cache_group_from_volume and cache_volume_ensure, which shares
# _group_volume_ensure with the temp volume (its failure paths, asked of docker
# the same way for both kinds, are tested in tests/test-vartmp-volume.sh), and
# rvm_volume_ensure's refusal of a volume carrying a cache label.
#
# The rule under test: a cache volume is recognised by its
# ai-containers.cache-group label only. A volume of the exact name that lacks
# it, or carries another group's, refuses the launch rather than being mounted.
#
# Hermetic: HOME points at a temp dir BEFORE sourcing sandbox-common.sh; docker
# is a fake on PATH (tests/lib-fake-docker-volume.sh) that keeps labels per
# volume.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset REPO_VOLUME_PREFIX REPO_BACKEND

# shellcheck disable=SC1091
source "$REPO_DIR/sandbox-common.sh"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"

# ── Fake docker ─────────────────────────────────────────────────────────────────
# FAKE_CREATE_FAIL: `docker volume create` fails.
VOLS="$TMP/volumes"
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<FAKE
#!/usr/bin/env bash
if [[ "\$1" == volume ]]; then
  [[ "\$2" == create && -n "\${FAKE_CREATE_FAIL:-}" ]] && exit 1
  exec bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$VOLS" "\$@"
fi
exit 0
FAKE
chmod +x "$FAKE_BIN/docker"
export PATH="$FAKE_BIN:$PATH"
fake_volume() { bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$VOLS" volume "$@" >/dev/null; }
reset_volumes() { rm -rf "$VOLS"; mkdir -p "$VOLS"; }
labels_of() { cat "$VOLS/$1/labels" 2>/dev/null; }
reset_volumes

# ── Naming ──────────────────────────────────────────────────────────────────────
check "cache_volume_name uses the -cache- infix" \
  "ai-containers-cache-docs" "$(cache_volume_name docs)"
check "cache_volume_name honours REPO_VOLUME_PREFIX" \
  "pfx-cache-docs" "$(repo_volume_prefix=pfx cache_volume_name docs)"
check "cache_volume_name sanitizes an unsafe group token" \
  "ai-containers-cache-a_b" "$(cache_volume_name 'a/b')"

# ── Ensure: a missing volume is made, labelled, and said to be made ─────────────
own="$(ai_containers_owner_id)"
vol=unset made=unset
cache_volume_ensure docs vol made 2>"$TMP/err"; rc=$?
check "ensure of a missing volume returns 0" "0" "$rc"
check "ensure sets the volume name" "ai-containers-cache-docs" "$vol"
check "ensure says this launch made it" "1" "$made"
check "the new volume carries the group and owner labels" \
  "ai-containers.cache-group=docs
ai-containers.owner=${own}" "$(labels_of ai-containers-cache-docs)"
check "no output on stderr for a clean create" "" "$(cat "$TMP/err")"
check "nothing else was made" "ai-containers-cache-docs" "$(ls "$VOLS")"

# ── Ensure: an existing volume labelled for this group is used, not made ────────
vol=unset made=unset
cache_volume_ensure docs vol made 2>"$TMP/err"; rc=$?
check "ensure of this group's volume returns 0" "0" "$rc"
check "ensure of this group's volume sets its name" "ai-containers-cache-docs" "$vol"
check "ensure of this group's volume says it was not made now" "0" "$made"
check "no note on this home's own volume" "" "$(cat "$TMP/err")"

# ── Ensure: refusals ────────────────────────────────────────────────────────────
expect_refused() {  # $1 = label, $2.. = what the ERROR must hold
  local what="$1" w; shift
  vol=unset made=unset
  cache_volume_ensure docs vol made 2>"$TMP/err"; rc=$?
  local err; err="$(cat "$TMP/err")"
  check "$what: returns 1" "1" "$rc"
  check "$what: sets no name" "unset" "$vol"
  for w in "$@"; do
    [[ "$err" == *"$w"* ]] && pass "$what: the ERROR says '$w'" || fail "$what: the ERROR lacks '$w' (got: $err)"
  done
}
reset_volumes; fake_volume create ai-containers-cache-docs
expect_refused "an unlabelled volume of the name" \
  'ERROR: the volume ai-containers-cache-docs exists but is not a cache volume of group "docs": it has no cache volume label.' \
  "knows a group's cache volume by its label" "docker volume rm ai-containers-cache-docs"
reset_volumes; fake_volume create --label ai-containers.cache-group=other ai-containers-cache-docs
expect_refused "a volume labelled for another group" 'belongs to group "other", not "docs"' "docker volume rm ai-containers-cache-docs"
# Under nested prefixes the name can be another kind's volume: a temp volume of
# this name has no cache label, and is refused as one without it.
reset_volumes; fake_volume create --label ai-containers.vartmp-group=docs ai-containers-cache-docs
expect_refused "a temp volume of the cache volume's name" "it has no cache volume label"
reset_volumes
vol=unset made=unset
FAKE_CREATE_FAIL=1 cache_volume_ensure docs vol made 2>"$TMP/err"; rc=$?
check "a create that fails returns 1, sets nothing" "1|unset|unset" "$rc|$vol|$made"
check "  with an ERROR naming the cache volume" \
  "ERROR: could not create the cache volume ai-containers-cache-docs" "$(cat "$TMP/err")"

# ── Another home's cache volume: used, with a NOTE naming it ────────────────────
reset_volumes
fake_volume create --label ai-containers.cache-group=docs --label "ai-containers.owner=sha256:$(printf '%064d' 7)" ai-containers-cache-docs
cache_volume_ensure docs vol made 2>"$TMP/err"; rc=$?
check "another home's cache volume is used, not made now" "0|ai-containers-cache-docs|0" "$rc|$vol|$made"
err="$(cat "$TMP/err")"
[[ "$err" == "NOTE: the cache volume ai-containers-cache-docs was made by another home"* \
   && "$err" == *"this group then fills its caches again."* && "$err" == *REPO_VOLUME_PREFIX* ]] \
  && pass "the shared-volume NOTE names the cache volume" || fail "no cache shared note (got: $err)"

# ── The Ruby volume code never takes a cache volume ─────────────────────────────
# Prefix p-rvm-x's cache volume of group g, p-rvm-x-cache-g, is group
# x-cache-g's Ruby volume name under prefix p.
reset_volumes
fake_volume create --label ai-containers.cache-group=g p-rvm-x-cache-g
out="$(repo_volume_prefix=p rvm_volume_ensure x-cache-g "$TMP/nogroup" img 2>"$TMP/err")"; rc=$?
check "rvm_volume_ensure refuses a volume with a cache label" "1|" "$rc|$out"
check "  saying whose cache volume it is" \
  'ERROR: the volume p-rvm-x-cache-g is a cache volume of group "g", not the Ruby volume of group "x-cache-g".' \
  "$(head -1 "$TMP/err")"

# ── Isolation and the label round trip ──────────────────────────────────────────
reset_volumes
fake_volume create ai-containers-repo-app
fake_volume create ai-containers-rvm-docs
fake_volume create ai-containers-vartmp-docs
fake_volume create ai-containers-cache-docs
check "cache_volumes lists only the cache volume" \
  "ai-containers-cache-docs" "$(cache_volumes | tr '\n' ' ' | sed 's/ $//')"
check "vartmp_volumes does not list the cache volume" \
  "ai-containers-vartmp-docs" "$(vartmp_volumes | tr '\n' ' ' | sed 's/ $//')"
check "rvm_volumes does not list the cache volume" \
  "ai-containers-rvm-docs" "$(rvm_volumes | tr '\n' ' ' | sed 's/ $//')"
check "repo_base_volumes does not list the cache volume" \
  "ai-containers-repo-app" "$(repo_base_volumes | tr '\n' ' ' | sed 's/ $//')"
check "cache_group_from_volume prints nothing for an unlabelled volume (no name fallback)" \
  "" "$(cache_group_from_volume ai-containers-cache-docs)"
reset_volumes; fake_volume create --label ai-containers.cache-group=docs ai-containers-cache-docs
check "cache_group_from_volume round-trips the label" \
  "docs" "$(cache_group_from_volume ai-containers-cache-docs)"

# ════════════════════════════════════════════════════════════════════════════════
# The launch (sandbox.sh): ~/.cache is the group's volume, filled once from the
# host folder the bind was.
#
# A fake docker on PATH records every `docker run` (one file per run, one
# argument a line, in order) and runs nothing: the copy's run is answered with
# FAKE_COPY_RC and FAKE_COPY_ERR on stderr, the launch's with 0. `volume` calls go
# to tests/lib-fake-docker-volume.sh; `ps` answers nothing; anything else fails,
# as in tests/test-agent-tmp.sh.
# ════════════════════════════════════════════════════════════════════════════════
export HOME="$TMP/lhome"; mkdir -p "$HOME"
HOME="$(p_realdir "$HOME")"; export HOME
export AI_CONTAINER_GROUP_INIT=clean SANDBOX_USER=dev
unset VAULT_PATH SPECS_PATH DOCS_PATH ARCHITECTURE_REPO_PATH EXTRA_MOUNTS REPOS AI_CONTAINER_GROUP SANDBOX_UID SANDBOX_GID
export SANDBOX_CONF="$TMP/sandbox.conf"
printf '# schema-version: 4\nqmd=OFF\nplaywright=OFF\nclaude-code=OFF\n' > "$SANDBOX_CONF"
LVOLS="$TMP/lvolumes"; RUNS="$TMP/runs"
mkdir -p "$TMP/lbin" "$TMP/app" "$TMP/launch"
cat > "$TMP/lbin/docker" <<DOCKER
#!/usr/bin/env bash
[[ "\$1" == volume ]] && exec bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$LVOLS" "\$@"
if [[ "\$1" == run ]]; then
  shift; mkdir -p "$RUNS"; n=\$(ls "$RUNS" | wc -l); n=\$((n + 1))
  printf '%s\n' "\$@" > "$RUNS/\$n"
  for a in "\$@"; do
    if [[ "\$a" == *:/dst ]]; then
      [[ -z "\${FAKE_COPY_ERR:-}" ]] || printf '%s\n' "\$FAKE_COPY_ERR" >&2
      exit "\${FAKE_COPY_RC:-0}"
    fi
  done
  exit 0
fi
[[ "\$1" == ps ]] && exit 0
exit 1
DOCKER
chmod +x "$TMP/lbin/docker"
PATH="$TMP/lbin:$PATH"
G="$HOME/.ai-containers/default"
CV=ai-containers-cache-default
# lrun: one launch; sets RC and ERR (stderr's file); RUNS holds its docker runs.
lrun() {
  rm -rf "$RUNS"; ERR="$TMP/lerr"
  ( cd "$TMP/launch" && bash "$REPO_DIR/sandbox.sh" restricted "$TMP/app" ) >/dev/null 2>"$ERR" </dev/null; RC=$?
}
nruns() { ls "$RUNS" 2>/dev/null | wc -l | tr -d ' '; }
last_run() { cat "$RUNS/$(nruns)"; }
# has_pair <file> <a> <b>: <a> is followed at once by <b> in that run's arguments.
has_pair() { awk -v a="$2" -v b="$3" 'p && $0 == b { f = 1 } { p = ($0 == a) } END { exit !f }' "$1"; }

# ── A new group: the volume, no host folder, no copy ────────────────────────────
lrun
check "a launch of a new group exits 0" "0" "$RC"
check "  one docker run: the launch, no copy" "1" "$(nruns)"
has_pair "$RUNS/1" -v "$CV:/home/dev/.cache" \
  && pass "  ~/.cache is the group's cache volume" || fail "  ~/.cache is not the cache volume ($(grep -F .cache "$RUNS/1" | tr '\n' ' '))"
grep -qF "$G/.cache" "$RUNS/1" && fail "  the group's host .cache is bound" || pass "  the group's host .cache is not bound"
[[ -e "$G/.cache" ]] && fail "  the launch made the group's host .cache" || pass "  the launch makes no host .cache"
has_pair "$RUNS/1" -e AI_CACHE_ON_VOLUME=1 \
  && pass "  AI_CACHE_ON_VOLUME=1 is passed" || fail "  AI_CACHE_ON_VOLUME=1 is not passed"
check "  the volume carries the group label" "default" "$(grep '^ai-containers.cache-group=' "$LVOLS/$CV/labels" | cut -d= -f2-)"
grep -qF "$G/.local/state:/home/dev/.local/state" "$RUNS/1" \
  && pass "  ~/.local/state is still the group's host folder" || fail "  ~/.local/state is no longer bound"

# ── A group with an old host .cache: copied once, by the launch that makes the volume
rm -rf "$LVOLS" "$G"; mkdir -p "$G/.cache/qmd"; printf i > "$G/.cache/qmd/index"
lrun
check "a launch with an old .cache exits 0" "0" "$RC"
check "  two docker runs: the copy, then the launch" "2" "$(nruns)"
C="$RUNS/1"
has_pair "$C" -v "$CV:/dst" && pass "  the copy mounts the new volume at /dst" || fail "  the copy does not mount the volume at /dst"
has_pair "$C" -v "$G/.cache:/src:ro" && pass "  the copy binds the old folder read-only at /src" || fail "  the copy's /src ($(grep -F /src "$C" | tr '\n' ' '))"
grep -qxF -- --pull=never "$C" && grep -qxF -- --rm "$C" \
  && pass "  the copy runs --rm --pull=never" || fail "  the copy lacks --rm or --pull=never"
has_pair "$C" --network none && pass "  the copy has no network" || fail "  the copy has a network"
has_pair "$C" --entrypoint bash && pass "  the copy runs bash, not the entrypoint" || fail "  the copy runs the entrypoint"
grep -qF 'setpriv --reuid="$u" --regid="$g" --clear-groups -- cp -dR --preserve=mode,timestamps,links "/src/$e" "$s/"' "$C" \
  && pass "  the copy runs cp as the agent, ownership given, not preserved" || fail "  the copy's cp is not the agent's"
check "  its last arguments: _ uid gid, a pid, and . for all of /src" "_ $(id -u) $(id -g)|." "$(tail -5 "$C" | head -3 | tr '\n' ' ' | sed 's/ $//')|$(tail -1 "$C")"
[[ "$(tail -2 "$C" | head -1)" =~ ^[0-9]+$ ]] && pass "  the fourth is a pid" || fail "  the fourth is not a pid ($(tail -2 "$C" | head -1))"
has_pair "$RUNS/2" -v "$CV:/home/dev/.cache" && pass "  then the launch mounts the volume" || fail "  the launch after the copy"
grep -qF "Copying this group's ~/.cache into the docker volume $CV" "$ERR" \
  && grep -qF 'Copied.' "$ERR" && grep -qxF "  rm -rf $G/.cache" "$ERR" \
  && pass "  the launch says so before and after, with the rm -rf for the old folder" \
  || fail "  the copy's lines ($(tr '\n' ' ' < "$ERR"))"
check "  the old folder is untouched" "i" "$(cat "$G/.cache/qmd/index")"
lrun
check "the next launch, the volume there: no copy, though the old folder is" "0|1" "$RC|$(nruns)"
grep -qF Copying "$ERR" && fail "  it says it copies" || pass "  nothing said about a copy"

# The identity the agent runs as is the one the files are given.
rm -rf "$LVOLS"
SANDBOX_UID=4242 SANDBOX_GID=4343 lrun
check "SANDBOX_UID/GID: the copy gives the files that identity" "_ 4242 4343" "$(tail -5 "$RUNS/1" | head -3 | tr '\n' ' ' | sed 's/ $//')"

# ── What is not copied ──────────────────────────────────────────────────────────
rm -rf "$LVOLS" "$G"; mkdir -p "$G/.cache"
lrun
check "an empty old .cache: no copy" "0|1" "$RC|$(nruns)"
rm -rf "$LVOLS" "$G"; mkdir -p "$G"; printf x > "$G/.cache"
lrun
check "an old .cache that is a file: no copy" "0|1" "$RC|$(nruns)"
rm -rf "$LVOLS" "$G"; mkdir -p "$G" "$TMP/away/qmd"; printf j > "$TMP/away/qmd/index"; ln -s "$TMP/away" "$G/.cache"
lrun
check "an old .cache that is a link: copied" "0|2" "$RC|$(nruns)"
has_pair "$RUNS/1" -v "$(p_realdir "$TMP/away"):/src:ro" \
  && pass "  from where the link leads, as the bind followed it" || fail "  the link's copy ($(grep -F /src "$RUNS/1" | tr '\n' ' '))"
rm -f "$G/.cache"; rm -rf "$TMP/away"

# ── A copy that fails warns, and the launch goes on ─────────────────────────────
rm -rf "$LVOLS" "$G"; mkdir -p "$G/.cache/qmd"; printf i > "$G/.cache/qmd/index"
FAKE_COPY_RC=1 FAKE_COPY_ERR=$'cp: cannot open \'/src/qmd/x\' for reading: Permission denied\n\e]0;t\a' lrun
check "a failed copy: the launch goes on" "0|2" "$RC|$(nruns)"
grep -qF "WARNING: copying $G/.cache into the docker volume $CV failed" "$ERR" \
  && grep -qF "It said: ?]0;t?" "$ERR" \
  && pass "  a WARNING, with the copy's last line made safe for the terminal" \
  || fail "  the failed copy's WARNING ($(tr '\n' ' ' < "$ERR"))"
grep -qF 'Copied.' "$ERR" && fail "  it says Copied" || pass "  it does not say Copied"
check "  the old folder is kept" "i" "$(cat "$G/.cache/qmd/index")"

# ── A group made from another gets its qmd index out of that group's volume ────
# lvol <name> [--label k=v]...: a volume of the launch's fake docker.
lvol() { local n="$1"; shift; bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$LVOLS" volume create "$@" "$n" >/dev/null; }
rm -rf "$LVOLS" "$G"
mkdir -p "$HOME/.ai-containers/src"
lvol ai-containers-cache-src --label ai-containers.cache-group=src
AI_CONTAINER_GROUP=newg AI_CONTAINER_GROUP_INIT=from:src lrun
check "from:src with a cache volume: the qmd copy, then the launch" "0|2" "$RC|$(nruns)"
Q="$RUNS/1"
has_pair "$Q" -v "ai-containers-cache-src:/src:ro" && has_pair "$Q" -v "ai-containers-cache-newg:/dst" \
  && pass "  from src's volume, read-only, into the new group's" || fail "  the qmd copy's volumes ($(grep -F ':/' "$Q" | tr '\n' ' '))"
check "  only its qmd" "qmd" "$(tail -1 "$Q")"
has_pair "$Q" --network none && pass "  with no network" || fail "  the qmd copy has a network"
grep -qF 'Copying group "src"'"'"'s qmd index into the docker volume ai-containers-cache-newg' "$ERR" \
  && pass "  said so" || fail "  not said ($(tr '\n' ' ' < "$ERR"))"
# Its host .cache/qmd, which the group copy carries too, follows: the volume's first.
rm -rf "$LVOLS" "$HOME/.ai-containers/newg"
mkdir -p "$HOME/.ai-containers/src/.cache/qmd"; printf old > "$HOME/.ai-containers/src/.cache/qmd/index"
lvol ai-containers-cache-src --label ai-containers.cache-group=src
AI_CONTAINER_GROUP=newg AI_CONTAINER_GROUP_INIT=from:src lrun
check "from:src with a volume and an old host qmd: the volume's qmd first, then the old folder, then the launch" \
  "0|3|qmd|." "$RC|$(nruns)|$(tail -1 "$RUNS/1")|$(tail -1 "$RUNS/2")"
has_pair "$RUNS/2" -v "$HOME/.ai-containers/newg/.cache:/src:ro" \
  && pass "  the second from the new group's old folder" || fail "  the second copy ($(grep -F /src "$RUNS/2" | tr '\n' ' '))"
# A source with no cache volume: its host folder, as before, carried by the old-folder copy.
rm -rf "$LVOLS" "$HOME/.ai-containers/newg"
AI_CONTAINER_GROUP=newg AI_CONTAINER_GROUP_INIT=from:src lrun
check "from:src with no cache volume: no qmd copy, the old folder's copy" "0|2|." "$RC|$(nruns)|$(tail -1 "$RUNS/1")"
check "  which the group copy filled from src's host qmd" "old" "$(cat "$HOME/.ai-containers/newg/.cache/qmd/index" 2>/dev/null)"
# A volume of src's cache name that is not src's by its label is not read.
rm -rf "$LVOLS" "$HOME/.ai-containers/newg" "$HOME/.ai-containers/src/.cache"
lvol ai-containers-cache-src
AI_CONTAINER_GROUP=newg AI_CONTAINER_GROUP_INIT=from:src lrun
check "from:src whose cache-named volume has no label: nothing copied" "0|1" "$RC|$(nruns)"
# Only the launch that makes the new group copies: the group there already, no qmd copy.
rm -rf "$LVOLS"
lvol ai-containers-cache-src --label ai-containers.cache-group=src
AI_CONTAINER_GROUP=newg AI_CONTAINER_GROUP_INIT=from:src lrun
check "a group that already exists is not made from src again: no qmd copy" "0|1" "$RC|$(nruns)"
# A qmd copy that fails warns, and the launch goes on.
rm -rf "$LVOLS" "$HOME/.ai-containers/newg"
lvol ai-containers-cache-src --label ai-containers.cache-group=src
AI_CONTAINER_GROUP=newg AI_CONTAINER_GROUP_INIT=from:src FAKE_COPY_RC=1 FAKE_COPY_ERR='no space left' lrun
check "a failed qmd copy: the launch goes on" "0|2" "$RC|$(nruns)"
grep -qF 'WARNING: copying group "src"'"'"'s qmd index from ai-containers-cache-src failed' "$ERR" \
  && grep -qF 'It said: no space left' "$ERR" \
  && pass "  a WARNING with what the copy said" || fail "  the qmd copy's WARNING ($(tr '\n' ' ' < "$ERR"))"
rm -rf "$HOME/.ai-containers/newg" "$HOME/.ai-containers/src"

# ── A volume of the name that is not the group's refuses the launch ─────────────
rm -rf "$LVOLS" "$G"
bash "$REPO_DIR/tests/lib-fake-docker-volume.sh" "$LVOLS" volume create "$CV" >/dev/null
lrun
[[ "$RC" != 0 && "$(nruns)" == 0 ]] && grep -qF "docker volume rm $CV" "$ERR" \
  && pass "an unlabelled cache volume of the name refuses the launch, naming the docker volume rm" \
  || fail "an unlabelled cache volume (rc=$RC; runs=$(nruns); $(grep -F ERROR "$ERR" | head -1))"

if [[ "$fails" -eq 0 ]]; then printf 'ALL PASS\n'; else printf '%d FAILED\n' "$fails"; exit 1; fi
