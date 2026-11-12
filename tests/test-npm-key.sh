#!/usr/bin/env bash
# Unit tests for the `npm` sandbox.conf key: the npm of the DEFAULT Node,
# replaced at build time because nothing in the container can replace it later
# (the Node install is root's, and the agent shell never is root).
#
# WHAT THIS FILE CANNOT COVER, and what does: these are wiring assertions, that
# the key produces the right build arg and that validate_config refuses a list.
# That the layer then installs that npm, and only for the default Node, is a
# claim about the image: integration case 725-npm-pinned-default-node.sh (the
# agents variant pins npm), with mutation 725-npm-arg-not-passed to demonstrate
# it failing.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# npm_args <conf-body> — every NPM_VERSION build arg build.sh emits, one per line,
# or nothing. Sources the real build.sh, so the assertion is against the shipped
# function and not a copy of its logic. "Emitted empty" and "not emitted" differ,
# so the whole argument is printed, not only its value.
npm_args() {
  printf '# schema-version: 4\n%s\n' "$1" > "$TMP/sandbox.conf"
  (
    export SANDBOX_CONF="$TMP/sandbox.conf"
    # shellcheck source=/dev/null
    source "$REPO_DIR/build.sh"
    declare -a args=()
    build_args_from_config args
    local a
    for a in "${args[@]}"; do
      [[ "$a" == NPM_VERSION=* ]] && printf '%s\n' "$a"
    done
  )
}

# ON cannot pass through as the literal string: npm would look for a dist-tag
# named ON. A pinned version and a dist-tag pass verbatim.
for c in 'ON|NPM_VERSION=latest' '12.2.2|NPM_VERSION=12.2.2' 'next-12|NPM_VERSION=next-12'; do
  val="${c%%|*}"; want="${c#*|}"
  got="$(npm_args "npm=$val")"
  [[ "$got" == "$want" ]] && pass "npm=$val → $want" || fail "npm=$val → $want (got '$got')"
done

# OFF, empty and absent emit NOTHING, never NPM_VERSION=OFF (the ruby=OFF defect:
# the literal reached the build as a version) and never an empty argument, which
# would move the config digest of every project that leaves the key alone.
for body in 'npm=OFF' 'npm=' 'copilot=ON'; do
  got="$(npm_args "$body")"
  [[ -z "$got" ]] && pass "'$body' emits no NPM_VERSION build arg" \
    || fail "'$body' emits no NPM_VERSION build arg (got '$got')"
done

# One layer runs one `npm install -g npm@<ver>`, so a list has no meaning; it is
# refused by name rather than reaching npm as a package called "npm@11.6.2,12.2.2".
validate() {
  printf '# schema-version: 4\nnpm=%s\n' "$1" > "$TMP/sandbox.conf"
  SANDBOX_CONF="$TMP/sandbox.conf" bash -c "source '$REPO_DIR/build.sh'; check_config; validate_config" 2>&1
}
out="$(validate 11.6.2,12.2.2)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"npm only supports a single version"* ]]; then
  pass "validate_config refuses a comma-separated npm value, by name"
else
  fail "validate_config refuses a comma-separated npm value (rc=$rc, out='$out')"
fi
# The controls: what the key does take is accepted, or the refusal above would
# pass against a validate_config that refuses everything.
for good in ON OFF 12.2.2 next-12; do
  if out="$(validate "$good")"; then
    pass "validate_config accepts npm=$good"
  else
    fail "validate_config accepts npm=$good ($out)"
  fi
done

# sync-to-projects.sh appends the key with the value this file ships, so it must
# ship the setting that changes nothing.
grep -qx 'npm=OFF' "$REPO_DIR/sandbox.conf" \
  && pass "sandbox.conf ships npm=OFF (so sync-to-projects changes no project's npm)" \
  || fail "sandbox.conf ships npm=OFF"

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
