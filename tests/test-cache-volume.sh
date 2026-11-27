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

if [[ "$fails" -eq 0 ]]; then printf 'ALL PASS\n'; else printf '%d FAILED\n' "$fails"; exit 1; fi
