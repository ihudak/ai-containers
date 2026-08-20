#!/usr/bin/env bash
# Migration 004: remove the deprecated rails= key. Rails is now owned per-project
# by bundler; multi-Ruby support drops the build-time rails<->ruby pairing that
# forced a single Ruby version. Idempotent (no-op if no rails= line). Key-only.
# Target sandbox.conf path arrives as $1.
set -euo pipefail
file="$1"

grep -qE '^rails=' "$file" 2>/dev/null || exit 0

# The mktemp guard is not decoration. The write-back below is
# `cat "$tmp" > "$file"`, and the shell TRUNCATES the redirect target before it
# runs cat — so an empty $tmp does not fail harmlessly, it empties the very file
# the migration was rewriting. Every migration carries `set -euo pipefail`, which
# already aborts at the assignment, but that safety belongs to a shell option
# these files do not set at the point it matters and cannot see from here.
tmp="$(mktemp)" || { printf 'ERROR: mktemp failed — refusing to rewrite %s\n' "$file" >&2; exit 1; }
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^rails= ]] && continue
  printf '%s\n' "$line" >> "$tmp"
done < "$file"
cat "$tmp" > "$file"
rm -f "$tmp"
