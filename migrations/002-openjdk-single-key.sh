#!/usr/bin/env bash
# Migration 002: collapse the early per-version openjdk booleans
#   openjdk-21=ON / openjdk-25=OFF / ...
# into a single comma-list key
#   openjdk=<versions that were ON, in file order>
#
# Idempotent (no-op if no legacy openjdk-<N>= key exists). Key-only: comment
# lines and every other key pass through untouched. Receives the target
# sandbox.conf path as $1.
set -euo pipefail
file="$1"

# Precondition: at least one legacy per-version key present.
grep -qE '^openjdk-[0-9]+=' "$file" 2>/dev/null || exit 0

# Collect versions whose legacy key was ON, in file order.
versions=()
while IFS= read -r line; do
  key="${line%%=*}"                                  # openjdk-21
  val="${line#*=}"; val="${val%%#*}"; val="${val// /}"  # strip inline comment + spaces
  ver="${key#openjdk-}"                              # 21
  [[ "$val" == "ON" ]] && versions+=("$ver")
done < <(grep -E '^openjdk-[0-9]+=' "$file")

merged=""
if (( ${#versions[@]} > 0 )); then
  IFS=,; merged="${versions[*]}"; unset IFS
fi

# Rewrite: drop every legacy key line; emit the single openjdk= key where the
# FIRST legacy key was (so it keeps its section position).
tmp="$(mktemp)"
inserted=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^openjdk-[0-9]+= ]]; then
    if (( inserted == 0 )); then
      printf 'openjdk=%s\n' "$merged" >> "$tmp"
      inserted=1
    fi
    continue
  fi
  printf '%s\n' "$line" >> "$tmp"
done < "$file"
mv "$tmp" "$file"
