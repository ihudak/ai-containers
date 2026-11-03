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
case "$1" in
  volume)
    case "$2" in
      inspect)
        name=""; prev=""
        for a in "${@:3}"; do
          if [[ "$prev" == "--format" ]]; then :; elif [[ "$a" != "--format" ]]; then name="$a"; fi
          prev="$a"
        done
        [[ -f "$FAKE_VOLUMES_DIR/$name" ]] || exit 1
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

mkvol() { : > "$FAKE_VOLUMES_DIR/$1"; printf 'ai-containers.rvm-group=%s\n' "$2" > "$FAKE_VOLUMES_DIR/$1.labels"; }

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
