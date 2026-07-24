#!/usr/bin/env bash
# bump-sandbox-version.sh — author a SEMANTIC sandbox.conf schema change.
#
# Use ONLY for a rename / split / removal / in-place-meaning change. Adding a
# plain new key (e.g. `newtool=OFF`) needs NEITHER this script NOR a bump —
# sync-to-projects.sh backfills it automatically.
#
# In one step it (1) scaffolds the next migrations/<NNN>-<slug>.sh idempotent
# key-only hook and (2) bumps the '# schema-version:' marker in sandbox.conf.
#
# Usage: ./bump-sandbox-version.sh <slug>      (e.g. graalvm-split)
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="${script_dir}/sandbox.conf"
migrations_dir="${script_dir}/migrations"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "Usage: $0 <slug>   (e.g. graalvm-split)" >&2
  exit 2
fi
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "ERROR: slug must be lowercase letters, digits, and dashes; start alphanumeric." >&2
  exit 2
}
[[ -f "$conf" ]] || { echo "ERROR: sandbox.conf not found at $conf" >&2; exit 1; }

cur="$(grep -E '^# schema-version:[[:space:]]*[0-9]+' "$conf" 2>/dev/null | head -1 \
        | sed -E 's/^# schema-version:[[:space:]]*([0-9]+).*/\1/' || true)"
cur="${cur:-0}"
next=$(( cur + 1 ))
printf -v nnn '%03d' "$next"

mkdir -p "$migrations_dir"
hook="${migrations_dir}/${nnn}-${slug}.sh"
# Refuse to create a duplicate migration with the same slug, even at a different version.
# Use [0-9][0-9][0-9]- to anchor the match, preventing false positives like foo-bar vs bar.
if [[ -e "$hook" ]] || [[ -n "$(find "$migrations_dir" -maxdepth 1 -name "[0-9][0-9][0-9]-${slug}.sh" 2>/dev/null)" ]]; then
  echo "ERROR: a migration with slug '$slug' already exists — pick a different slug." >&2
  exit 1
fi

cat > "$hook" <<'SKEL'
#!/usr/bin/env bash
# Migration NNN: <describe the semantic change — rename / split / removal>.
#
# Rules (see README "sandbox.conf schema versioning"):
#   - Idempotent: check your own precondition and `exit 0` if already applied.
#   - Touch ONLY key=value lines, never comment text.
#   - The target project's sandbox.conf path arrives as $1.
set -euo pipefail
file="$1"

# Precondition guard — no-op if this migration was already applied. Example:
#   grep -qE '^oldkey=' "$file" 2>/dev/null || exit 0

# TODO: implement the key-only translation via a temp file, e.g.:
#   tmp="$(mktemp)"
#   while IFS= read -r line || [[ -n "$line" ]]; do
#     if [[ "$line" =~ ^oldkey= ]]; then
#       printf 'newkey=%s\n' "${line#*=}" >> "$tmp"; continue
#     fi
#     printf '%s\n' "$line" >> "$tmp"
#   done < "$file"
#   mv "$tmp" "$file"
SKEL
chmod +x "$hook"

# Bump the marker (update in place, or append if somehow missing).
if grep -qE '^# schema-version:' "$conf"; then
  tmp="$(mktemp)"
  sed -E "s/^# schema-version:.*/# schema-version: ${next}/" "$conf" > "$tmp"
  chmod --reference="$conf" "$tmp"
  mv "$tmp" "$conf"
else
  printf '# schema-version: %s\n' "$next" >> "$conf"
fi

printf 'Scaffolded %s and bumped sandbox.conf to schema-version %s.\n' "$hook" "$next"
printf 'Now implement the key-only translation in the hook, then commit both files.\n'
