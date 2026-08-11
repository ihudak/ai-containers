#!/usr/bin/env bash
# portability.sh — GNU/BSD-neutral helpers for the hermetic suite.
#
# SOURCED by tests, never executed. The suite runs on ubuntu CI (GNU coreutils)
# and, from increment 4 onward, on a developer's macOS host (BSD userland) via
# verify-on-host.sh Phase 5. `stat -c`, `sha1sum` and `md5sum` do not exist on
# macOS; `stat -f`, `shasum` and `md5` do.
#
# Every helper prints to stdout and must NEVER print empty on a supported
# platform: an empty string compares equal to another empty string, which turns
# a portability failure into a test that passes vacuously.

p_stat_mode() {  # $1=file → octal mode, e.g. 644
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

p_stat_meta() {  # $1=file → "name size mtime", for change detection
  stat -c '%n %s %Y' "$1" 2>/dev/null || stat -f '%N %z %m' "$1" 2>/dev/null
}

p_sha1() {  # $1=file → hex digest only
  if command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | cut -d' ' -f1
  else shasum -a 1 "$1" | cut -d' ' -f1; fi
}

p_md5() {  # $1=file → hex digest only
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
  else md5 -q "$1"; fi
}
