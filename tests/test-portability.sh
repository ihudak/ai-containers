#!/usr/bin/env bash
# The GNU/BSD-neutral helpers must agree with the platform's own tools.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

printf 'content\n' > "$TMP/f"; chmod 644 "$TMP/f"

[[ "$(p_stat_mode "$TMP/f")" == "644" ]] \
  && pass "p_stat_mode reports the octal mode" \
  || fail "p_stat_mode reports the octal mode — got '$(p_stat_mode "$TMP/f")'"

chmod 755 "$TMP/f"
[[ "$(p_stat_mode "$TMP/f")" == "755" ]] \
  && pass "p_stat_mode tracks a mode change" \
  || fail "p_stat_mode tracks a mode change — got '$(p_stat_mode "$TMP/f")'"

# The digest helpers must be stable and must differ for differing content.
a="$(p_sha1 "$TMP/f")"; b="$(p_sha1 "$TMP/f")"
[[ -n "$a" && "$a" == "$b" ]] \
  && pass "p_sha1 is non-empty and stable" || fail "p_sha1 is non-empty and stable"
printf 'other\n' > "$TMP/g"
[[ "$(p_sha1 "$TMP/f")" != "$(p_sha1 "$TMP/g")" ]] \
  && pass "p_sha1 distinguishes different content" \
  || fail "p_sha1 distinguishes different content"

m="$(p_md5 "$TMP/f")"
[[ -n "$m" && "$m" == "$(p_md5 "$TMP/f")" ]] \
  && pass "p_md5 is non-empty and stable" || fail "p_md5 is non-empty and stable"
[[ "$(p_md5 "$TMP/f")" != "$(p_md5 "$TMP/g")" ]] \
  && pass "p_md5 distinguishes different content" \
  || fail "p_md5 distinguishes different content"

meta="$(p_stat_meta "$TMP/f")"
[[ -n "$meta" ]] && pass "p_stat_meta returns something" || fail "p_stat_meta returns something"

# No helper may leave the caller with an empty answer on THIS platform: an empty
# string compares equal to another empty string, which is how a portability bug
# turns into a test that passes by accident.
for h in p_stat_mode p_sha1 p_md5 p_stat_meta; do
  if [[ -n "$($h "$TMP/f")" ]]; then pass "$h is non-empty on this platform"
  else fail "$h returned empty — comparisons using it would pass vacuously"; fi
done

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
