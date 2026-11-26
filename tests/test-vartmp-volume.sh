#!/usr/bin/env bash
# Tests for the group's /var/tmp volume helpers in sandbox-common.sh:
# vartmp_volume_name, vartmp_volumes, vartmp_group_from_volume,
# vartmp_volume_ensure and _group_volume_shared_note (with _rvm_shared_note as
# its Ruby wrapper).
#
# The rule under test: a temp volume is recognised by its
# ai-containers.vartmp-group label only. A volume of the exact name that lacks
# it, or carries another group's, refuses the launch rather than being mounted.
#
# Hermetic: HOME points at a temp dir BEFORE sourcing sandbox-common.sh; docker
# is a fake on PATH that keeps labels per volume.
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
FAKE_VOLUMES_DIR="$TMP/fake-volumes"; mkdir -p "$FAKE_VOLUMES_DIR"; export FAKE_VOLUMES_DIR
FAKE_CREATE_LOG="$TMP/fake-create.log"; : > "$FAKE_CREATE_LOG"; export FAKE_CREATE_LOG
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# FAKE_RACE_AT=<n>: another launch of the group makes the volume FAKE_RACE_VOL,
# its labels FAKE_RACE_LABELS (one key=value a line; empty: none, as a
# `docker run -v` makes it), just before this docker answers its n-th `volume`
# call. Every `volume` call is counted in FAKE_CALLS.
if [[ "$1" == volume && -n "${FAKE_CALLS:-}" ]]; then
  n=$(( $(cat "$FAKE_CALLS" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" > "$FAKE_CALLS"
  if [[ -n "${FAKE_RACE_AT:-}" ]] && (( n == FAKE_RACE_AT )) && [[ ! -f "$FAKE_VOLUMES_DIR/$FAKE_RACE_VOL" ]]; then
    : > "$FAKE_VOLUMES_DIR/$FAKE_RACE_VOL"
    printf '%s' "${FAKE_RACE_LABELS-}" > "$FAKE_VOLUMES_DIR/$FAKE_RACE_VOL.labels"
  fi
fi
case "$1" in
  volume)
    case "$2" in
      inspect)
        # FAKE_INSPECT_DOWN: docker cannot answer, saying FAKE_INSPECT_MSG (set
        # and empty: saying nothing) on stderr.
        if [[ -n "${FAKE_INSPECT_DOWN:-}" ]]; then
          msg="${FAKE_INSPECT_MSG-Cannot connect to the Docker daemon}"
          [[ -z "$msg" ]] || printf '%s\n' "$msg" >&2
          exit 1
        fi
        name=""; fmt=""; prev=""
        for a in "${@:3}"; do
          if [[ "$prev" == "--format" ]]; then fmt="$a"; elif [[ "$a" != "--format" ]]; then name="$a"; fi
          prev="$a"
        done
        # FAKE_FORMAT_FAIL: an inspect with --format never finds the volume, a
        # plain one does: a volume there, then not, each time it is asked.
        [[ -n "${FAKE_FORMAT_FAIL:-}" && -n "$fmt" ]] && { echo "Error response from daemon: get $name: No such volume: $name" >&2; exit 1; }
        [[ -f "$FAKE_VOLUMES_DIR/$name" ]] || { echo "Error response from daemon: get $name: No such volume: $name" >&2; exit 1; }
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
          case "$f" in *.labels) continue ;; esac
          bn="$(basename "$f")"
          case "$bn" in *"$substr"*) printf '%s\n' "$bn" ;; esac
        done
        exit 0 ;;
      create)
        [[ -n "${FAKE_CREATE_FAIL:-}" ]] && exit 1
        name="${@: -1}"
        printf '%s\n' "$*" >> "$FAKE_CREATE_LOG"
        # As docker does: a volume already there is answered with success, and
        # keeps its own labels (measured, Docker 29.9.2).
        [[ -f "$FAKE_VOLUMES_DIR/$name" ]] && { printf '%s\n' "$name"; exit 0; }
        : > "$FAKE_VOLUMES_DIR/$name"; : > "$FAKE_VOLUMES_DIR/$name.labels"
        prev=""
        for a in "$@"; do
          [[ "$prev" == "--label" ]] && printf '%s\n' "$a" >> "$FAKE_VOLUMES_DIR/$name.labels"
          prev="$a"
        done
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"
export PATH="$FAKE_BIN:$PATH"
reset_volumes() { rm -f "$FAKE_VOLUMES_DIR"/*; : > "$FAKE_CREATE_LOG"; }

# ── Naming ──────────────────────────────────────────────────────────────────────
check "vartmp_volume_name uses the -vartmp- infix" \
  "ai-containers-vartmp-docs" "$(vartmp_volume_name docs)"
check "vartmp_volume_name honours REPO_VOLUME_PREFIX" \
  "pfx-vartmp-docs" "$(repo_volume_prefix=pfx vartmp_volume_name docs)"
check "vartmp_volume_name sanitizes an unsafe group token" \
  "ai-containers-vartmp-a_b" "$(vartmp_volume_name 'a/b')"

# ── Ensure: a missing volume is made, labelled ──────────────────────────────────
reset_volumes
own="$(ai_containers_owner_id)"
out="$(vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "ensure of a missing volume returns 0" "0" "$rc"
check "ensure prints the volume name" "ai-containers-vartmp-docs" "$out"
check "ensure made exactly one volume" "1" "$(wc -l < "$FAKE_CREATE_LOG" | tr -d ' ')"
[[ "$(cat "$FAKE_CREATE_LOG")" == *"--label ai-containers.vartmp-group=docs"* ]] \
  && pass "create carries the group label" || fail "create lacks the group label"
[[ "$(cat "$FAKE_CREATE_LOG")" == *"--label ai-containers.owner=${own}"* ]] \
  && pass "create carries the owner label" || fail "create lacks the owner label"
check "no output on stderr for a clean create" "" "$(cat "$TMP/err")"

# ── Ensure: an existing volume labelled for this group is used ──────────────────
: > "$FAKE_CREATE_LOG"
out="$(vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "ensure of this group's volume returns 0" "0" "$rc"
check "ensure of this group's volume prints its name" "ai-containers-vartmp-docs" "$out"
check "ensure of this group's volume creates nothing" "" "$(cat "$FAKE_CREATE_LOG")"
check "no note on this home's own volume" "" "$(cat "$TMP/err")"

# ── Ensure: refusals ────────────────────────────────────────────────────────────
reset_volumes
: > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs"; : > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs.labels"
out="$(vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "an unlabelled volume of the name returns 1" "1" "$rc"
check "an unlabelled volume prints nothing on stdout" "" "$out"
err="$(cat "$TMP/err")"
[[ "$err" == "ERROR: "*"ai-containers-vartmp-docs"* && "$err" == *"docker volume rm ai-containers-vartmp-docs"* ]] \
  && pass "the unlabelled refusal names the volume and the docker volume rm" \
  || fail "the unlabelled refusal is wrong (got: $err)"
check "a refusal creates nothing" "" "$(cat "$FAKE_CREATE_LOG")"

printf 'ai-containers.vartmp-group=other\n' > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs.labels"
out="$(vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "a volume labelled for another group returns 1" "1" "$rc"
check "a volume labelled for another group prints nothing on stdout" "" "$out"
err="$(cat "$TMP/err")"
[[ "$err" == "ERROR: "*'"other"'* && "$err" == *"docker volume rm ai-containers-vartmp-docs"* ]] \
  && pass "the other-group refusal names group other and the docker volume rm" \
  || fail "the other-group refusal is wrong (got: $err)"

# The label is anyone's to set (docker volume create --label), and the refusal
# prints it: a control character in it reaches the terminal as ?, never as itself.
printf 'ai-containers.vartmp-group=ot\033]0;x\aher\n' > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs.labels"
out="$(vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "a label holding control characters is refused too" "1" "$rc"
err="$(cat "$TMP/err")"
[[ "$err" == *'"ot?]0;x?her"'* && "$err" != *$'\033'* && "$err" != *$'\a'* ]] \
  && pass "the refusal prints the label with its control characters as ?" \
  || fail "the refusal prints the label as it is (got: $(printf '%q' "$err"))"

reset_volumes
out="$(FAKE_INSPECT_DOWN=1 vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "an inspect that fails for another reason returns 1" "1" "$rc"
check "that refusal prints nothing on stdout" "" "$out"
check "that refusal says docker could not say" \
  "ERROR: docker could not say whether ai-containers-vartmp-docs exists" "$(head -1 "$TMP/err")"
check "that refusal creates nothing" "" "$(cat "$FAKE_CREATE_LOG")"

# What docker said comes with it: a stopped daemon, or a socket that refuses this
# user, is the usual reason a launch fails here, and the ERROR alone names a volume.
down='Cannot connect to the Docker daemon at unix:///x. Is the docker daemon running?'
out="$(FAKE_INSPECT_DOWN=1 FAKE_INSPECT_MSG="$down" vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "a daemon that cannot be reached returns 1" "1" "$rc"
check "  with the ERROR and, under it, what docker said" \
  "ERROR: docker could not say whether ai-containers-vartmp-docs exists
       docker said: $down" "$(cat "$TMP/err")"
# Only its first line that holds anything, and a control character in it reaches
# the terminal as ?.
out="$(FAKE_INSPECT_DOWN=1 FAKE_INSPECT_MSG=$'\nbad \e]0;x\a daemon\r\nsecond line' vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "docker's message is made safe for the terminal, its first line only (rc=$rc)" \
  "ERROR: docker could not say whether ai-containers-vartmp-docs exists
       docker said: bad ?]0;x? daemon" "$(cat "$TMP/err")"
# A docker that says nothing gets no empty "docker said:" line.
out="$(FAKE_INSPECT_DOWN=1 FAKE_INSPECT_MSG='' vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "docker silent: the ERROR alone (rc=$rc)" \
  "ERROR: docker could not say whether ai-containers-vartmp-docs exists" "$(cat "$TMP/err")"

out="$(FAKE_CREATE_FAIL=1 vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "a create that fails returns 1" "1" "$rc"
check "a failed create prints nothing on stdout" "" "$out"
[[ "$(cat "$TMP/err")" == "ERROR: "*"ai-containers-vartmp-docs"* ]] \
  && pass "a failed create prints an ERROR naming the volume" || fail "a failed create has no ERROR"

# ── Ensure: another launch of the group makes the volume meanwhile ──────────────
# Two launches of a group starting together (every group's first launch after
# an upgrade makes its volume): the other one makes the volume between this
# one's calls. A volume that appeared is checked like any other, by its label.
# race <n> <labels> → runs ensure with the volume made before the n-th
# `docker volume` call (1 the first inspect, 2 the inspect asked only for
# docker's stderr, 3 the create); sets out, rc, err, calls.
FAKE_CALLS="$TMP/fake-calls"
race() {
  reset_volumes; : > "$FAKE_CALLS"
  out="$(FAKE_CALLS="$FAKE_CALLS" FAKE_RACE_AT="$1" FAKE_RACE_LABELS="$2" FAKE_RACE_VOL=ai-containers-vartmp-docs \
    vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"; calls="$(cat "$FAKE_CALLS")"
}
mine="ai-containers.vartmp-group=docs
ai-containers.owner=${own}
"
race 2 "$mine"
check "made by another launch between the two inspects: used (rc=$rc; err: $err)" \
  "0|ai-containers-vartmp-docs|" "$rc|$out|$err"
check "  and this launch makes none" "" "$(cat "$FAKE_CREATE_LOG")"
race 2 ""
[[ "$rc" -eq 1 && -z "$out" && "$err" == *"it has no temp volume label"* && "$err" == *"docker volume rm ai-containers-vartmp-docs"* ]] \
  && pass "made unlabelled between the two inspects: refused as a volume with no label" \
  || fail "made unlabelled between the two inspects (rc=$rc; out: $out; err: $err)"
# docker answers a create of a volume already there with success, and leaves its
# labels as they are: the volume this launch asked for is checked all the same.
race 3 ""
[[ "$rc" -eq 1 && -z "$out" && "$err" == *"it has no temp volume label"* && "$err" == *"docker volume rm ai-containers-vartmp-docs"* ]] \
  && pass "made unlabelled just before this launch's create: refused, not mounted" \
  || fail "made unlabelled just before the create (rc=$rc; out: $out; err: $err)"
race 3 "ai-containers.vartmp-group=docs
ai-containers.owner=sha256:$(printf '%064d' 7)
"
[[ "$rc" -eq 0 && "$out" == ai-containers-vartmp-docs \
   && "$err" == *"NOTE: the temp volume ai-containers-vartmp-docs was made by another home"* ]] \
  && pass "made by another home's launch just before the create: used, with the shared-volume NOTE" \
  || fail "made by another home just before the create (rc=$rc; out: $out; err: $err)"
race 3 "ai-containers.vartmp-group=other
"
[[ "$rc" -eq 1 && -z "$out" && "$err" == *'belongs to group "other"'* ]] \
  && pass "made for another group just before the create: refused" \
  || fail "made for another group just before the create (rc=$rc; out: $out; err: $err)"
# A volume that is there, then not, each time it is asked is asked about three
# times, never forever.
reset_volumes; : > "$FAKE_CALLS"; : > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs"
out="$(FAKE_CALLS="$FAKE_CALLS" FAKE_FORMAT_FAIL=1 vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
err="$(cat "$TMP/err")"; calls="$(cat "$FAKE_CALLS")"
[[ "$rc" -eq 1 && -z "$out" && "$calls" -le 6 \
   && "$err" == "ERROR: docker could not say whether ai-containers-vartmp-docs exists: it was there, then not, each"* ]] \
  && pass "a volume there, then not, at every ask: refused after three asks ($calls docker calls)" \
  || fail "a volume there, then not (rc=$rc; calls=$calls; err: $err)"

# ── Ensure: another home's volume is used, with a NOTE ──────────────────────────
reset_volumes
: > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs"
printf 'ai-containers.vartmp-group=docs\nai-containers.owner=sha256:%064d\n' 7 > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs.labels"
out="$(vartmp_volume_ensure docs 2>"$TMP/err")"; rc=$?
check "another home's temp volume is used (returns 0)" "0" "$rc"
check "another home's temp volume prints its name" "ai-containers-vartmp-docs" "$out"
err="$(cat "$TMP/err")"
[[ "$err" == *"NOTE: the temp volume ai-containers-vartmp-docs was made by another home"* && "$err" == *REPO_VOLUME_PREFIX* ]] \
  && pass "the shared-volume NOTE names the temp volume" || fail "no shared note (got: $err)"

# ── _rvm_shared_note's text is unchanged ────────────────────────────────────────
reset_volumes
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-docs"
printf 'ai-containers.owner=sha256:%064d\n' 7 > "$FAKE_VOLUMES_DIR/ai-containers-rvm-docs.labels"
ap="'"   # the text holds an apostrophe, which the falsify tier's quote scanner would take for a string
expected="NOTE: the Ruby volume ai-containers-rvm-docs was made by another home on this docker (another WSL distro or
      user), or by this one before ~/.ai-containers/project-id.key was lost. That home${ap}s group
      \"docs\" may use it too, and that home can remove it with group.sh (rm, or gc once its group
      is gone there); this group then builds its Rubies again.
      To keep homes apart, give each its own REPO_VOLUME_PREFIX (docs/troubleshooting.md)."
check "_rvm_shared_note output is byte-identical" "$expected" "$(_rvm_shared_note ai-containers-rvm-docs docs 2>&1)"

# ── Isolation and the label round trip ──────────────────────────────────────────
reset_volumes
: > "$FAKE_VOLUMES_DIR/ai-containers-repo-app"
: > "$FAKE_VOLUMES_DIR/ai-containers-rvm-docs"
: > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs"
check "vartmp_volumes lists only the temp volume" \
  "ai-containers-vartmp-docs" "$(vartmp_volumes | tr '\n' ' ' | sed 's/ $//')"
check "rvm_volumes does not list the temp volume" \
  "ai-containers-rvm-docs" "$(rvm_volumes | tr '\n' ' ' | sed 's/ $//')"
check "repo_base_volumes does not list the temp volume" \
  "ai-containers-repo-app" "$(repo_base_volumes | tr '\n' ' ' | sed 's/ $//')"

: > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs.labels"
check "vartmp_group_from_volume prints nothing for an unlabelled volume (no name fallback)" \
  "" "$(vartmp_group_from_volume ai-containers-vartmp-docs)"
printf 'ai-containers.vartmp-group=docs\n' > "$FAKE_VOLUMES_DIR/ai-containers-vartmp-docs.labels"
check "vartmp_group_from_volume round-trips the label" \
  "docs" "$(vartmp_group_from_volume ai-containers-vartmp-docs)"

if [[ "$fails" -eq 0 ]]; then printf 'ALL PASS\n'; else printf '%d FAILED\n' "$fails"; exit 1; fi
