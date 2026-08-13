#!/usr/bin/env bash
# Every host entry point must reach the bash floor guard. The list is DERIVED
# from the repo, not hand-written: a hand-written list can only ever validate
# the files someone remembered to add to it, which is how the mgd port shipped
# with two files missing from its own byte-identity gate.
#
# Layout-tolerant: the engine directory (bash-floor.sh, sandbox-common.sh, and
# the entry-point scripts) is "the directory containing build.sh and
# sandbox.conf" — the repo root here, but base/ in the mgd-ai-containers port,
# where tests/ sits one level up beside it instead. Resolve it the same way
# verify-on-host.sh does, rather than assuming tests/.. is the engine dir.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
if [[ ! -f "$ENGINE_DIR/build.sh" || ! -f "$ENGINE_DIR/sandbox.conf" ]]; then
  ENGINE_DIR="$(cd "$TESTS_DIR/../base" && pwd)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

[[ -f "$ENGINE_DIR/build.sh" && -f "$ENGINE_DIR/sandbox.conf" ]] \
  && pass "engine directory resolved ($ENGINE_DIR)" \
  || fail "engine directory resolved — could not find build.sh + sandbox.conf under repo root or base/"

[[ -f "$ENGINE_DIR/bash-floor.sh" ]] \
  && pass "bash-floor.sh exists" || fail "bash-floor.sh exists"

# The floor is stated exactly once. A second literal somewhere else is how the
# 4.3-vs-4.4-vs-3.2 contradiction happened in the first place.
floor_defs="$(grep -rlE 'AI_CONTAINERS_BASH_FLOOR_(MAJOR|MINOR)=' "$ENGINE_DIR" \
  --include='*.sh' 2>/dev/null | grep -v '/tests/' | wc -l | tr -d ' ')"
[[ "$floor_defs" == "1" ]] \
  && pass "the floor is defined in exactly one file" \
  || fail "the floor is defined in $floor_defs files — it must be exactly one"

# Derived entry-point list: executable *.sh at the engine directory's top level
# (not nested) that are RUN, not sourced. In-container scripts are excluded by
# name because they never execute on a host at all.
in_container="entrypoint.sh rvm-reconcile.sh agent-tools-reconcile.sh
  link-agent-tools.sh link-default-ruby.sh install-tools.sh
  refresh-ipset-allowlist.sh capture-blocked-traffic.sh
  install-agent-skills.sh capture-agent-destinations.sh bash-floor.sh
  sandbox-common.sh tools-lib.sh shared-files.sh"
# The multi-line string above embeds literal newlines; normalize them to spaces
# before substring-matching, otherwise an entry at the end of a physical line
# (immediately before its embedded \n, not a space) never matches " $base ".
in_container_flat=" ${in_container//$'\n'/ } "
n_checked=0
while IFS= read -r f; do
  base="$(basename "$f")"
  case "$in_container_flat" in *" $base "*) continue ;; esac
  n_checked=$((n_checked+1))
  if grep -qE '^(source|\.) .*(bash-floor|sandbox-common)\.sh' "$ENGINE_DIR/$base"; then
    pass "$base reaches the bash floor guard"
  else
    fail "$base reaches the bash floor guard — it can run under an unsupported bash"
  fi
done < <(cd "$ENGINE_DIR" && git ls-files '*.sh' | grep -v '/')

# A derivation that found nothing must not report success.
[[ "$n_checked" -gt 0 ]] \
  && pass "checked $n_checked entry point(s)" \
  || fail "checked 0 entry points — the derivation matched nothing"

# ── The floor→image map ───────────────────────────────────────────────────────
# The image that TESTS the floor is part of declaring the floor. Kept as a map
# rather than a free variable so a floor bumped without a matching image yields
# empty (a hard failure downstream) instead of silently testing the wrong bash.
( source "$ENGINE_DIR/bash-floor.sh"
  [[ -n "${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}" ]] ) \
  && pass "bash-floor.sh maps the declared floor to a container image" \
  || fail "bash-floor.sh maps no image to the declared floor — suite-floor cannot test the claim"

# Bumping the floor without extending the map must yield EMPTY, not a stale
# image. Tested against a COPY with rewritten floor numbers, NOT an env
# override: bash-floor.sh is the single declaration of the floor and six entry
# points source it as a guard, so making its assignments env-overridable to suit
# this test would let any stray AI_CONTAINERS_BASH_FLOOR_MAJOR silently lower
# that guard. Fix the test's assumption, never the product.
#
# 5.0 rather than a high number: sourcing the copy runs the version guard too,
# and a floor ABOVE the running bash would exit before reaching the map. 5.0 is
# below every bash this suite can run on (the real floor is 5.1) and is absent
# from the map, which is exactly the condition under test.
sed -e 's/^AI_CONTAINERS_BASH_FLOOR_MAJOR=.*/AI_CONTAINERS_BASH_FLOOR_MAJOR=5/' \
    -e 's/^AI_CONTAINERS_BASH_FLOOR_MINOR=.*/AI_CONTAINERS_BASH_FLOOR_MINOR=0/' \
    "$ENGINE_DIR/bash-floor.sh" > "$TMP/floor-unmapped.sh"
# A sed that matched nothing would leave the real floor in place and make the
# assertion below pass for the wrong reason.
grep -q '^AI_CONTAINERS_BASH_FLOOR_MINOR=0$' "$TMP/floor-unmapped.sh" \
  || fail "the unmapped-floor fixture was not rewritten — the assertion below would be vacuous"
out="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${AI_CONTAINERS_BASH_FLOOR_IMAGE:-}"' \
         _ "$TMP/floor-unmapped.sh")"
[[ -z "$out" ]] \
  && pass "an unmapped floor yields an empty image rather than a stale one" \
  || fail "an unmapped floor yielded '$out' — the map is not keyed on the declared floor"

printf '\n%d failure(s)\n' "$fails"; exit "$fails"
