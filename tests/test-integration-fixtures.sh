#!/usr/bin/env bash
# Guards tests/integration/fixtures/*.sh against losing their executable bit.
#
# Why this needs its own check: every fixture in that directory is bind-mounted
# by an integration case (via sandbox_up's pass-through docker-run args)
# directly OVER /usr/local/bin/capture-blocked-traffic.sh, which entrypoint.sh
# execs directly (`/usr/local/bin/capture-blocked-traffic.sh &`, not
# `bash <script>`). A Docker bind mount replaces the target path's CONTENT
# *and* mode with the SOURCE file's — mount a 644 fixture over a 755 target
# and the daemon inside the container is 644: it cannot execute and never
# starts at all. That failure looks identical from outside the container to
# the very bug some fixtures exist to preserve ("the daemon never starts"
# vs. "the daemon starts but is broken"), so a case built on a wrong-mode
# fixture can print the right-looking FAIL line for the WRONG reason —
# exactly the trap this whole suite exists to avoid (AGENTS.md: "assert
# effect, not configuration"; see also the task-5 report for the real
# incident this caused).
#
# Checks BOTH the working tree and the committed git mode. The two can
# diverge silently: `git update-index --chmod=+x` alone flips the index
# without touching the working-tree bit, and a later `git add` of that same
# path re-reads the working tree and quietly undoes it. Checking only one of
# the two would miss exactly that regression.
#
# Hermetic: filesystem + git metadata only, no Docker, no root.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$REPO_DIR/tests/integration/fixtures"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

if [[ ! -d "$FIXTURES_DIR" ]]; then
  fail "fixtures directory exists: $FIXTURES_DIR"
  printf '\n%d failure(s)\n' "$fails"
  exit "$fails"
fi
pass "fixtures directory exists: tests/integration/fixtures"

shopt -s nullglob
fixtures=("$FIXTURES_DIR"/*.sh)
shopt -u nullglob

if [[ "${#fixtures[@]}" -eq 0 ]]; then
  fail "at least one *.sh fixture exists under tests/integration/fixtures/"
else
  pass "found ${#fixtures[@]} *.sh fixture(s) under tests/integration/fixtures/"
fi

for f in "${fixtures[@]}"; do
  name="$(basename "$f")"

  # Working-tree mode: what a case would actually bind-mount right now, on
  # THIS checkout, regardless of what git has recorded.
  if [[ -x "$f" ]]; then
    pass "$name is executable on disk (working tree)"
  else
    got="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
    fail "$name is executable on disk (working tree) — got mode ${got:-unknown}"
  fi

  # Committed mode: what the NEXT `git add`/`checkout` will (re)impose on the
  # working tree regardless of any local `chmod`. `git ls-files -s` prints
  # "<mode> <sha> <stage>\t<path>"; the mode is the first field.
  rel="tests/integration/fixtures/$name"
  mode="$(cd "$REPO_DIR" && git ls-files -s -- "$rel" 2>/dev/null | awk '{print $1}')"
  if [[ "$mode" == "100755" ]]; then
    pass "$name is committed as 100755 (git ls-files -s)"
  elif [[ -z "$mode" ]]; then
    fail "$name is committed as 100755 (git ls-files -s) — not tracked by git"
  else
    fail "$name is committed as 100755 (git ls-files -s) — got $mode"
  fi
done

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
