#!/usr/bin/env bash
# Drives link-node-globals.sh against a FAKE default-node prefix laid out the way
# npm lays one out, with a throwaway destination, then checks the Dockerfile runs
# it after every `npm install -g` and pins the package its qmd layer installs.
#
# Fake nodes stand in for real ones: each prints which node it is and then its
# arguments one per line, so a test can tell which node a command ran under
# (the defect this guards is commands that vanish after `nvm use`) and that the
# arguments arrived intact.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_DIR"; [[ -f "$REPO_DIR/base/entrypoint.sh" ]] && ENGINE="$REPO_DIR/base"
# shellcheck source=portability.sh
source "$REPO_DIR/tests/portability.sh"
SCRIPT="$ENGINE/link-node-globals.sh"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)" || { printf 'SCAFFOLD-FAILED: mktemp -d\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT
TMP="$(p_realdir "$TMP")"

bash -n "$SCRIPT" && pass "link-node-globals.sh bash -n" || fail "link-node-globals.sh bash -n"

# A node that is not the default one: what `nvm use` would put first on PATH.
mkdir -p "$TMP/active"
printf '#!/bin/sh\nprintf "%%s\\n" active-node "$@"\n' > "$TMP/active/node"
chmod 755 "$TMP/active/node"

# mk_cmd PREFIX PACKAGE PATH NAME KIND — what `npm install -g` leaves: the file
# at lib/node_modules/PACKAGE/PATH and bin/NAME linking to it, relatively.
# KIND node is a `#!/usr/bin/env node` script; native stands in for an ELF
# binary (pnpm 11, bun) that runs without any node.
mk_cmd() {
  local p="$1" pkg="$2" rel="$3" name="$4" kind="$5" f
  f="$p/lib/node_modules/$pkg/$rel"
  mkdir -p "${f%/*}" "$p/bin"
  printf '{"name":"%s"}\n' "$pkg" > "$p/lib/node_modules/$pkg/package.json"
  if [[ "$kind" == node ]]; then
    printf '#!/usr/bin/env node\n' > "$f"
  else
    printf '#!/bin/sh\nprintf "%%s\\n" native-%s "$@"\n' "$name" > "$f"
  fi
  chmod 755 "$f"
  ln -sfn "../lib/node_modules/$pkg/$rel" "$p/bin/$name"
}

# mk_prefix PREFIX — node, node's own npm and corepack, and the five packages
# the Dockerfile's npm-global layers install, with the commands each really
# installs (measured in an image: yarn's two names, pnpm's native binary, bun's
# bin/bun.exe, a scoped @angular/cli, a scoped @tobilu/qmd).
mk_prefix() {
  local p="$1"
  mkdir -p "$p/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" default-node "$@"\n' > "$p/bin/node"
  chmod 755 "$p/bin/node"
  mk_cmd "$p" npm bin/npm-cli.js npm node
  mk_cmd "$p" npm bin/npx-cli.js npx node
  mk_cmd "$p" corepack dist/corepack.js corepack node
  mk_cmd "$p" yarn bin/yarn.js yarn node
  mk_cmd "$p" yarn bin/yarn.js yarnpkg node
  mk_cmd "$p" pnpm pnpm pnpm native
  mk_cmd "$p" bun bin/bun.exe bun native
  mk_cmd "$p" @angular/cli bin/ng.js ng node
  mk_cmd "$p" @tobilu/qmd bin/qmd qmd node
}

# run_link PREFIX DEST [args…] — the nvm layer's /usr/local/bin/node link,
# outside DEST so DEST holds only what the script made.
run_link() {
  local p="$1" d="$2"; shift 2
  mkdir -p "$d" "$TMP/usrbin"
  ln -sfn "$p/bin/node" "$TMP/usrbin/node"
  NODE_LINK="$TMP/usrbin/node" LINK_DIR="$d" bash "$SCRIPT" "$@"
}

P="$TMP/v24/prefix"; D="$TMP/dest"
mk_prefix "$P"
out="$(run_link "$P" "$D" --pin @tobilu/qmd 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "links a full prefix (rc 0)" || fail "links a full prefix (rc $rc): $out"

# ── Every command a package installed is linked, to npm's own link ──
ok=1
for n in yarn yarnpkg pnpm bun ng; do
  [[ -L "$D/$n" && "$(readlink "$D/$n")" == "$P/bin/$n" ]] || { ok=0; fail "$n is linked to $P/bin/$n (got $(readlink "$D/$n" 2>/dev/null || echo nothing))"; }
done
[[ "$ok" == 1 ]] && pass "yarn, yarnpkg, pnpm, bun and ng are linked to the default node's bin"

# ── node's own commands are left to the nvm layer ──
ok=1
for n in node npm npx corepack; do
  [[ -e "$D/$n" || -L "$D/$n" ]] && { ok=0; fail "$n must not be linked by this script"; }
done
[[ "$ok" == 1 ]] && pass "node, npm, npx and corepack are not linked"

# ── A linked node script runs under the ACTIVE node: a package manager must ──
got="$(PATH="$TMP/active:$PATH" "$D/yarn" install 2>&1 | head -n 1)"
[[ "$got" == active-node ]] && pass "yarn runs under the active node after nvm use" \
  || fail "yarn runs under the active node after nvm use (got: $got)"
got="$(PATH="$TMP/active:$PATH" "$D/pnpm" x 2>&1 | head -n 1)"
[[ "$got" == native-pnpm ]] && pass "pnpm's native binary runs" || fail "pnpm's native binary runs (got: $got)"

# ── A pinned package runs under the DEFAULT node, whatever is active ──
if [[ -f "$D/qmd" && ! -L "$D/qmd" && -x "$D/qmd" ]]; then
  pass "qmd is an executable wrapper, not a link"
else
  fail "qmd is an executable wrapper, not a link"
fi
got="$(PATH="$TMP/active:$PATH" "$D/qmd" search 'a b' "c'd" '' 2>&1)"
want="$(printf '%s\n' default-node "$P/lib/node_modules/@tobilu/qmd/bin/qmd" search 'a b' "c'd" '')"
[[ "$got" == "$want" ]] && pass "qmd runs its script under the default node with its arguments intact" \
  || fail "qmd runs its script under the default node with its arguments intact
     got:  $(printf '%s' "$got" | tr '\n' '|')
     want: $(printf '%s' "$want" | tr '\n' '|')"

# ── The output names what it did ──
[[ "$out" == *"linked into $D: "*yarn* && "$out" == *"pinned to the default node: qmd"* ]] \
  && pass "reports what it linked and pinned" || fail "reports what it linked and pinned: $out"

# ── Running again over its own work is fine ──
out="$(run_link "$P" "$D" --pin @tobilu/qmd 2>&1)"; rc=$?
[[ "$rc" -eq 0 && -L "$D/yarn" && -f "$D/qmd" && ! -L "$D/qmd" ]] \
  && pass "a second run replaces only its own links and wrapper" || fail "a second run (rc $rc): $out"

# ── The wrapper survives quotes and spaces in the prefix ──
Q="$TMP/pre fix'q/v24"; DQ="$TMP/dest-q"
mk_prefix "$Q"
out="$(run_link "$Q" "$DQ" --pin @tobilu/qmd 2>&1)"; rc=$?
got="$(PATH="$TMP/active:$PATH" "$DQ/qmd" x 2>&1)"
want="$(printf '%s\n' default-node "$Q/lib/node_modules/@tobilu/qmd/bin/qmd" x)"
[[ "$rc" -eq 0 && "$got" == "$want" ]] && pass "a prefix holding a space and a quote is quoted in the wrapper" \
  || fail "a prefix holding a space and a quote (rc $rc, got $(printf '%s' "$got" | tr '\n' '|')): $out"

# ── A scope alone is not a package (it has no package.json): --pin @tobilu
#    pins nothing and leaves qmd a plain link ──
DS="$TMP/dest-scope"
out="$(run_link "$P" "$DS" --pin @tobilu 2>&1)"; rc=$?
[[ "$rc" -eq 0 && -L "$DS/qmd" ]] && pass "--pin matches a whole scoped name, not its scope" \
  || fail "--pin matches a whole scoped name, not its scope (rc $rc): $out"

# ── Pinning a package this image does not have is not an error ──
N="$TMP/noqmd/prefix"; DN="$TMP/dest-noqmd"
mk_prefix "$N"; rm -rf "$N/lib/node_modules/@tobilu" "$N/bin/qmd"
out="$(run_link "$N" "$DN" --pin @tobilu/qmd 2>&1)"; rc=$?
[[ "$rc" -eq 0 && -L "$DN/yarn" && ! -e "$DN/qmd" ]] && pass "--pin of a package not installed is skipped" \
  || fail "--pin of a package not installed is skipped (rc $rc): $out"

# ── Refusals ──
# expect_refusal NAME PREFIX DEST NEEDLE [args…]: rc non-zero and NEEDLE in the output.
expect_refusal() {
  local what="$1" p="$2" d="$3" needle="$4" o r; shift 4
  o="$(run_link "$p" "$d" "$@" 2>&1)"; r=$?
  if [[ "$r" -ne 0 && "$o" == *"$needle"* ]]; then pass "$what"; else fail "$what (rc $r): $o"; fi
}

DF="$TMP/dest-foreign"; mkdir -p "$DF"; printf 'mine\n' > "$DF/yarn"
expect_refusal "refuses to replace a file it did not make" "$P" "$DF" "$DF/yarn already exists"
[[ "$(cat "$DF/yarn")" == mine ]] && pass "the foreign file is left as it was" || fail "the foreign file is left as it was"

DL="$TMP/dest-foreign-link"; mkdir -p "$DL"; ln -s /bin/true "$DL/bun"
expect_refusal "refuses to replace a link it did not make" "$P" "$DL" "$DL/bun already exists"

DW="$TMP/dest-foreign-wrapper"; mkdir -p "$DW"; printf '#!/bin/sh\nexec true\n' > "$DW/qmd"
expect_refusal "refuses to replace a script that is not its wrapper" "$P" "$DW" "$DW/qmd already exists" --pin @tobilu/qmd

expect_refusal "refuses to pin a command that is not a node script" "$P" "$TMP/dest-pin-native" "not a node script" --pin pnpm

U="$TMP/unknown/prefix"; mk_prefix "$U"; ln -s /bin/true "$U/bin/weird"
expect_refusal "refuses a link npm did not make" "$U" "$TMP/dest-unknown" "cannot tell which package owns weird"

U2="$TMP/unscoped/prefix"; mk_prefix "$U2"; ln -s ../lib/node_modules/lonely "$U2/bin/lonely"
expect_refusal "refuses a link to a package with no path inside it" "$U2" "$TMP/dest-unscoped" "cannot tell which package owns lonely"

E="$TMP/empty-pin/prefix"; mk_prefix "$E"; rm -f "$E/bin/qmd"
expect_refusal "refuses a pinned package that is installed but put no command in bin" "$E" "$TMP/dest-empty" "put no command" --pin @tobilu/qmd

expect_refusal "refuses an unknown argument" "$P" "$TMP/dest-arg" "unknown argument" --bogus
expect_refusal "refuses --pin with no package" "$P" "$TMP/dest-arg2" "needs a package name" --pin

B="$TMP/no-node"; mkdir -p "$B/bin" "$TMP/dest-nonode"
o="$(NODE_LINK="$B/bin/node" LINK_DIR="$TMP/dest-nonode" bash "$SCRIPT" 2>&1)"; r=$?
[[ "$r" -ne 0 && "$o" == *"does not lead to a node prefix"* ]] && pass "refuses a node link that leads to no node" \
  || fail "refuses a node link that leads to no node (rc $r): $o"

# ── The Dockerfile runs it after every npm-global layer ──
DF_PATH="$ENGINE/Dockerfile"
# Line numbers of real (non-comment) lines; a comment that mentions either must not count.
run_lines="$(awk '/^[[:space:]]*#/ {next} /bash \/tmp\/link-node-globals\.sh/ {print NR}' "$DF_PATH")"
npm_lines="$(awk '/^[[:space:]]*#/ {next} /npm install -g/ {print NR}' "$DF_PATH")"
if [[ "$(printf '%s\n' "$run_lines" | grep -c .)" -eq 1 ]]; then
  pass "the Dockerfile runs link-node-globals.sh exactly once"
else
  fail "the Dockerfile runs link-node-globals.sh exactly once (lines: ${run_lines:-none})"
fi
late=""
while IFS= read -r n; do
  [[ -n "$n" && -n "$run_lines" && "$n" -gt "$run_lines" ]] && late+=" $n"
done <<< "$npm_lines"
if [[ -z "$npm_lines" ]]; then
  fail "the Dockerfile scan found no npm install -g (scanner is broken)"
elif [[ -z "$late" ]]; then
  pass "every npm install -g ($(printf '%s\n' "$npm_lines" | grep -c .) lines) comes before link-node-globals.sh"
else
  fail "npm install -g after link-node-globals.sh, so not linked, at line(s):$late"
fi

# Each --pin names a package an npm-global layer installs, so renaming qmd's
# package cannot quietly leave it unpinned, and following `nvm use` onto a node
# older than the 22 it requires.
pins="$(awk '/^[[:space:]]*#/ {next} /bash \/tmp\/link-node-globals\.sh/' "$DF_PATH" | grep -oE -- '--pin [^ ]+' | cut -d' ' -f2)"
if [[ -z "$pins" ]]; then
  fail "the Dockerfile pins qmd to the default node (no --pin found)"
else
  while IFS= read -r pin; do
    if grep -qE -- "npm install -g \"?${pin}(@|\"|[[:space:]]|\$)" <<< "$(awk '/^[[:space:]]*#/ {next} {print}' "$DF_PATH")"; then
      pass "--pin $pin names a package an npm-global layer installs"
    else
      fail "--pin $pin names a package an npm-global layer installs"
    fi
  done <<< "$pins"
fi
grep -qE -- '--pin @tobilu/qmd( |&|$)' <<< "$(grep -F 'bash /tmp/link-node-globals.sh' "$DF_PATH")" \
  && pass "qmd is pinned to the default node" || fail "qmd is pinned to the default node"

# The Dockerfile COPYs it from the build context, which in a project is its
# .ai-containers/ copy: a project without it cannot build.
# shellcheck source=../shared-files.sh
source "$ENGINE/shared-files.sh"
case " ${AI_CONTAINERS_SHARED_FILES[*]} " in
  *" link-node-globals.sh "*) pass "link-node-globals.sh is a shared file" ;;
  *) fail "link-node-globals.sh is a shared file (the Dockerfile COPYs it)" ;;
esac

printf '\n%d failure(s)\n' "$fails"
exit "$fails"
