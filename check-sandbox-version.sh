#!/usr/bin/env bash
# check-sandbox-version.sh — CI gate against a SILENT semantic sandbox.conf change.
#
#   ./check-sandbox-version.sh --check
#
# Compares the working-tree sandbox.conf key SET against a base ref's
# (default HEAD; override with BASE_REF). If a key was removed or renamed WITHOUT
# both a schema-version bump and a matching migrations/<NNN>-*.sh hook, it fails.
# Ordinary key ADDITIONS pass silently. Expected to fire ~twice in the whole
# history of the file — near-zero day-to-day friction.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="${script_dir}/sandbox.conf"
migrations_dir="${script_dir}/migrations"
base_ref="${BASE_REF:-HEAD}"

case "${1:-}" in
  --check) : ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Usage: $0 --check" >&2; exit 2 ;;
esac

# Read key names (text before the first '=') from stdin, sorted-unique.
# `|| true` guards the zero-match case (e.g. a conf with no key=value lines)
# from tripping `set -e`/`pipefail` before the result is even assigned.
_keys() { grep -E '^[A-Za-z0-9_-]+=' | sed -E 's/^([A-Za-z0-9_-]+)=.*/\1/' | sort -u || true; }
# Read the schema-version integer from stdin (empty → caller defaults to 0).
_ver()  { grep -E '^# schema-version:[[:space:]]*[0-9]+' | head -1 \
            | sed -E 's/^# schema-version:[[:space:]]*([0-9]+).*/\1/' || true; }

cur_keys="$(_keys < "$conf")"
cur_ver="$(_ver < "$conf")"; cur_ver="${cur_ver:-0}"

# Previous committed sandbox.conf. If the base ref has none (first commit), skip.
if ! prev_conf="$(git -C "$script_dir" show "${base_ref}:sandbox.conf" 2>/dev/null)"; then
  echo "check-sandbox-version: no sandbox.conf at ${base_ref} — nothing to compare."
  exit 0
fi
prev_keys="$(printf '%s\n' "$prev_conf" | _keys)"
prev_ver="$(printf '%s\n' "$prev_conf" | _ver)"; prev_ver="${prev_ver:-0}"

# Keys present in the base ref but gone now (removed or renamed away).
removed="$(comm -23 <(printf '%s\n' "$prev_keys") <(printf '%s\n' "$cur_keys") || true)"

if [[ -z "$removed" ]]; then
  echo "check-sandbox-version: OK (no key removed/renamed; additions are always allowed)."
  exit 0
fi

# A key disappeared → require BOTH a schema-version bump AND a matching hook.
if (( cur_ver <= prev_ver )); then
  echo "ERROR: sandbox.conf key(s) removed/renamed but schema-version was not bumped:" >&2
  printf '  %s\n' $removed >&2
  echo "       Author the change with ./bump-sandbox-version.sh <slug>, implement the hook, and bump." >&2
  exit 1
fi

printf -v nnn '%03d' "$cur_ver"
if ! ls "${migrations_dir}/${nnn}-"*.sh >/dev/null 2>&1; then
  echo "ERROR: schema-version bumped to ${cur_ver} but no migrations/${nnn}-*.sh hook exists to cover:" >&2
  printf '  %s\n' $removed >&2
  exit 1
fi

echo "check-sandbox-version: OK (removed/renamed key(s) covered by schema-version ${cur_ver} + hook)."
