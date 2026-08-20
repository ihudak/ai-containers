#!/usr/bin/env bash
# Migration 003: split the single graalvm=<val> key into two:
#   graalvm-ce=<val>      (Community Edition inherits the old value)
#   graalvm-oracle=       (empty — opt in explicitly)
#
# Idempotent (no-op if no bare graalvm= key exists — note ^graalvm= does NOT match
# the already-split graalvm-ce= / graalvm-oracle= keys). Key-only. Receives the
# target sandbox.conf path as $1.
set -euo pipefail
file="$1"

grep -qE '^graalvm=' "$file" 2>/dev/null || exit 0

# Capture the old value (raw remainder after '=', first occurrence).
old="$(grep -E '^graalvm=' "$file" | head -1 | cut -d= -f2-)"

# The mktemp guard is not decoration. The write-back below is
# `cat "$tmp" > "$file"`, and the shell TRUNCATES the redirect target before it
# runs cat — so an empty $tmp does not fail harmlessly, it empties the very file
# the migration was rewriting. Every migration carries `set -euo pipefail`, which
# already aborts at the assignment, but that safety belongs to a shell option
# these files do not set at the point it matters and cannot see from here.
tmp="$(mktemp)" || { printf 'ERROR: mktemp failed — refusing to rewrite %s\n' "$file" >&2; exit 1; }
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^graalvm= ]]; then
    printf 'graalvm-ce=%s\n' "$old" >> "$tmp"
    printf 'graalvm-oracle=\n' >> "$tmp"
    continue
  fi
  printf '%s\n' "$line" >> "$tmp"
done < "$file"
cat "$tmp" > "$file"
rm -f "$tmp"
