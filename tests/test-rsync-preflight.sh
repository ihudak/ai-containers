#!/usr/bin/env bash
# project-init.sh and sync-to-projects.sh copy the shared files with rsync and
# run under `set -euo pipefail`. Without rsync on PATH (Git for Windows' bundled
# bash ships none), sync-to-projects.sh used to print "Syncing → …" and then die
# on a bare "rsync: command not found", copying nothing and saying nothing
# useful. Both now refuse up front with a message that names the fix.
#
# The third case is the one that is easy to get wrong: migrate-runme.sh SOURCES
# project-init.sh for emit_launcher() and never calls rsync, so the check must
# sit after project-init.sh's sourcing guard — a host without rsync must still
# be able to migrate a launcher.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Layout-tolerant: this repo keeps the engine at the root, the mgd port under base/.
if [[ -f "$ROOT/base/project-init.sh" ]]; then ENGINE="$ROOT/base"; else ENGINE="$ROOT"; fi
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A PATH holding every command the current PATH offers, except rsync.
mkdir -p "$tmp/bin"
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" == rsync || -e "$tmp/bin/$n" || ! -x "$f" || -d "$f" ]] && continue
    ln -s "$f" "$tmp/bin/$n"
  done
done
if PATH="$tmp/bin" command -v rsync >/dev/null 2>&1; then
  fail "fixture: rsync is still reachable on the stripped PATH"
else
  pass "fixture: the stripped PATH has no rsync"
fi

# ── 1. project-init.sh refuses before prompting ──────────────────────────────
out="$(PATH="$tmp/bin" "$BASH" "$ENGINE/project-init.sh" </dev/null 2>"$tmp/err")"; rc=$?
[[ "$rc" -eq 1 ]] && pass "project-init.sh exits 1 without rsync" \
  || fail "project-init.sh exits 1 without rsync (got $rc)"
grep -q 'rsync is required' "$tmp/err" && pass "project-init.sh names rsync as the cause" \
  || fail "project-init.sh names rsync as the cause: $(cat "$tmp/err")"
[[ -z "$out" ]] && pass "project-init.sh prompted for nothing before refusing" \
  || fail "project-init.sh prompted before refusing: $out"

# ── 2. sync-to-projects.sh refuses before touching a project ─────────────────
# A project that already has a working copy, so an unguarded sync reaches its
# first rsync call (without one, sync skips the project and exits 0 anyway).
mkdir -p "$tmp/proj/.ai-containers"
PATH="$tmp/bin" "$BASH" "$ENGINE/sync-to-projects.sh" "$tmp/proj" </dev/null >"$tmp/out" 2>"$tmp/err"; rc=$?
[[ "$rc" -eq 1 ]] && pass "sync-to-projects.sh exits 1 without rsync" \
  || fail "sync-to-projects.sh exits 1 without rsync (got $rc)"
grep -q 'rsync is required' "$tmp/err" && pass "sync-to-projects.sh names rsync as the cause" \
  || fail "sync-to-projects.sh names rsync as the cause: $(cat "$tmp/err")"
[[ -z "$(ls -A "$tmp/proj/.ai-containers")" ]] && pass "sync-to-projects.sh wrote nothing into the working copy" \
  || fail "sync-to-projects.sh wrote nothing into the working copy"
! grep -q 'Syncing' "$tmp/out" && pass "sync-to-projects.sh refused before announcing a sync" \
  || fail "sync-to-projects.sh refused before announcing a sync"

# ── 3. sourcing project-init.sh (migrate-runme.sh's use) needs no rsync ──────
# shellcheck disable=SC2016  # expanded by the child bash, not here
res="$(PATH="$tmp/bin" "$BASH" -c 'source "$1" && declare -F emit_launcher' _ "$ENGINE/project-init.sh" 2>&1)"; rc=$?
[[ "$rc" -eq 0 && "$res" == "emit_launcher" ]] \
  && pass "sourcing project-init.sh without rsync still yields emit_launcher" \
  || fail "sourcing project-init.sh without rsync still yields emit_launcher (rc=$rc): $res"

printf '\n%d failure(s)\n' "$fails"
[[ "$fails" -eq 0 ]]
