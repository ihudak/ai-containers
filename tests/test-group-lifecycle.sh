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

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d)"
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
          case "$f" in *.labels) continue ;; esac
          bn="$(basename "$f")"
          case "$bn" in *"$substr"*) printf '%s\n' "$bn" ;; esac
        done
        exit 0 ;;
      rm) rm -f "$FAKE_VOLUMES_DIR/${3}" "$FAKE_VOLUMES_DIR/${3}.labels"; exit 0 ;;
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
out="$(run_group rm host --yes)"; rc=$?
grep -q 'refusing' <<<"$out" \
  && pass "rm refuses the 'host' group" \
  || fail "rm refuses the 'host' group (got: $out)"

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

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
