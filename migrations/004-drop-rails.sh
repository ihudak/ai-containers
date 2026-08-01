#!/usr/bin/env bash
# Migration 004: remove the deprecated rails= key. Rails is now owned per-project
# by bundler; multi-Ruby support drops the build-time rails<->ruby pairing that
# forced a single Ruby version. Idempotent (no-op if no rails= line). Key-only.
# Target sandbox.conf path arrives as $1.
set -euo pipefail
file="$1"

grep -qE '^rails=' "$file" 2>/dev/null || exit 0

tmp="$(mktemp)"
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^rails= ]] && continue
  printf '%s\n' "$line" >> "$tmp"
done < "$file"
cat "$tmp" > "$file"
rm -f "$tmp"
