#!/usr/bin/env bash
# Tests for generate_allowlists (and its include_fragment / include_if_enabled /
# include_if_has_versions helpers) in build.sh — the assembly of
# allowlist-domains.txt, allowlist-proxy-domains.txt and allowlist-cidrs.txt from
# the *.d/ fragment directories. This is the firewall's INPUT: a dropped fragment
# silently breaks agents at runtime, a stray one silently widens the sandbox, so
# this suite asserts the generated OUTPUT content, not just that build.sh runs.
#
# Hermetic: generates into a throwaway rsync copy of the repo (never the real
# allowlist-*.txt files), with a synthetic sandbox.conf supplied via the
# SANDBOX_CONF override hook (see sandbox-common.sh: config_file="${SANDBOX_CONF:-...}")
# and synthetic fragment directories (script_dir resolves to the temp copy once
# build.sh/sandbox-common.sh are sourced FROM there, so generate_allowlists reads
# and writes entirely inside the temp copy).
#
# tests/test-tools-d.sh already covers active_tool_fragments (listing, dedup,
# descriptor parsing) directly — this file only asserts that a tool's
# allowlist_fragment ends up (or doesn't) in the generated domains/proxy-domains
# output, which test-tools-d.sh does not check.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Isolated HOME: sandbox-common.sh reads ~/.ai-containers for the repo registry;
# not used by generate_allowlists itself but keep this hermetic against any
# future coupling, matching the rest of the suite's convention.
export HOME="$TMP/home"; mkdir -p "$HOME"

# ── Throwaway repo copy ──────────────────────────────────────────────────────────
# A real rsync copy (not just the two scripts) so relative sourcing
# (source "${_here}/sandbox-common.sh", source "${script_dir}/tools-lib.sh")
# resolves inside the copy. Exclude tests/ and heavy/irrelevant dirs; the real
# allowlist-*.txt / *.d/ fragment trees are excluded too — this suite writes its
# OWN synthetic fragment dirs into the copy so no real fragment leaks into what
# is being asserted on.
REPO="$TMP/repo"; mkdir -p "$REPO"
rsync -a --exclude='.git' --exclude='tests' --exclude='docs' \
      --exclude='allowlist-domains.d' --exclude='allowlist-proxy-domains.d' --exclude='allowlist-cidrs.d' \
      --exclude='allowlist-domains.txt' --exclude='allowlist-proxy-domains.txt' --exclude='allowlist-cidrs.txt' \
      --exclude='tools.d' \
      "$REPO_DIR"/ "$REPO"/

mkdir -p "$REPO/allowlist-domains.d" "$REPO/allowlist-proxy-domains.d" "$REPO/allowlist-cidrs.d" "$REPO/tools.d"

# Fingerprint the REAL repo's allowlist-*.txt (gitignored build output) before
# running anything, so we can prove at the end they were never regenerated.
real_txt_fingerprint() {
  for f in allowlist-domains.txt allowlist-proxy-domains.txt allowlist-cidrs.txt; do
    if [[ -f "$REPO_DIR/$f" ]]; then
      stat -c '%n %s %Y' "$REPO_DIR/$f"
    else
      printf '%s ABSENT\n' "$f"
    fi
  done
}
REAL_TXT_BEFORE="$(real_txt_fingerprint)"

# ── Synthetic sandbox.conf (via the SANDBOX_CONF override hook) ────────────────
CONF="$TMP/sandbox.conf"
cat > "$CONF" <<'EOF'
# schema-version: 3
copilot=OFF
github-cli=ON
codex=OFF
kiro=OFF
claude-code=OFF
gemini=OFF
graphify=OFF
yarn=OFF
kubectl=OFF
aws-cli=OFF
azure-cli=OFF
goreleaser=OFF
vale=OFF
angular-cli=OFF
openjdk=21.0.5
graalvm-ce=
graalvm-oracle=
kotlin=
scala=
maven=
gradle=
ruby=
rails=
rust=
go=
EOF

# ── Synthetic fragment directories ──────────────────────────────────────────────
# base.txt — always included.
printf '# base domains\nbase-domain.example\n' > "$REPO/allowlist-domains.d/base.txt"
printf '# base cidrs\n10.0.0.0/8\n' > "$REPO/allowlist-cidrs.d/base.txt"

# An ENABLED boolean component (github-cli=ON above) — its fragment must be included.
printf 'enabled-component.example\n' > "$REPO/allowlist-domains.d/github-cli.txt"
# A DISABLED boolean component (copilot=OFF above) — its fragment must NOT be included.
printf 'disabled-component.example\n' > "$REPO/allowlist-domains.d/github-copilot.txt"

# A version-keyed component WITH a version set (openjdk=21.0.5) — sdkman.txt/openjdk.txt
# fragments are gated by any_has_versions on the JVM key group.
printf 'sdkman.example\n' > "$REPO/allowlist-domains.d/sdkman.txt"
printf 'openjdk-fragment.example\n' > "$REPO/allowlist-domains.d/openjdk.txt"
# A version-keyed component with NO versions anywhere (ruby empty) —
# rvm.txt must NOT be included.
printf 'rvm-fragment.example\n' > "$REPO/allowlist-domains.d/rvm.txt"

# custom.txt — included when present.
printf 'custom-domain.example\n' > "$REPO/allowlist-domains.d/custom.txt"

# Unconditionally-included fragments referenced by generate_allowlists
# (include_fragment with no gate) — nvm.txt / pyenv.txt.
printf 'nvm.example\n' > "$REPO/allowlist-domains.d/nvm.txt"
printf 'pyenv.example\n' > "$REPO/allowlist-domains.d/pyenv.txt"

# Proxy-domains family: its own base/custom + one enabled, one disabled fragment,
# distinct content from the domains family so a family mix-up is detectable.
printf 'proxy-enabled.example\n' > "$REPO/allowlist-proxy-domains.d/github-cli.txt"
printf 'proxy-custom.example\n' > "$REPO/allowlist-proxy-domains.d/custom.txt"
# NOTE: proxy family has no github-cli include_if_enabled call in build.sh (only
# copilot/kiro/claude-code/codex/gemini/graphify + tool fragments + custom are
# wired for allowlist-proxy-domains.txt) — kept here only to prove cross-family
# isolation: it must NEVER leak into allowlist-domains.txt or allowlist-cidrs.txt.

# Cidrs family: base + custom + copilot-gated fragment (copilot=OFF → excluded).
printf 'cidrs-custom.example\n' > "$REPO/allowlist-cidrs.d/custom.txt"
printf 'copilot-cidr.example/32\n' > "$REPO/allowlist-cidrs.d/github-copilot.txt"

# A tools.d-described tool with an allowlist_fragment, ACTIVE (dtctl-style: a
# version-keyed custom tool). Only active_tool_fragments' OUTPUT feeding into
# generate_allowlists is asserted here — dedup/listing itself is test-tools-d.sh's turf.
cat > "$REPO/tools.d/mytool.conf" <<'EOF'
repo=acme/mytool
binary=mytool
allowlist_fragment=mytool-frag
EOF
printf 'mytool-domain.example\n' > "$REPO/allowlist-domains.d/mytool-frag.txt"
printf 'mytool-proxy.example\n' > "$REPO/allowlist-proxy-domains.d/mytool-frag.txt"
echo 'mytool=1.0.0' >> "$CONF"

# A second tools.d tool sharing the SAME fragment, but INACTIVE — proves the
# fragment is included because mytool is active, not unconditionally.
cat > "$REPO/tools.d/othertool.conf" <<'EOF'
repo=acme/othertool
binary=othertool
allowlist_fragment=othertool-frag
EOF
printf 'othertool-domain.example\n' > "$REPO/allowlist-domains.d/othertool-frag.txt"
echo 'othertool=OFF' >> "$CONF"

# A third tools.d tool installed from a vendored repo file (install=repo-file).
# Fragment inclusion must follow its sandbox.conf key exactly like a release-based
# tool — the fetch mode has no bearing on the allowlist.
cat > "$REPO/tools.d/exttool.conf" <<'EOF'
repo=acme/vendored
binary=ext-cli
install=repo-file
repo_path=utils/ext/ext-cli-linux-${ARCH}
allowlist_fragment=exttool-frag
EOF
printf 'exttool-domain.example\n' > "$REPO/allowlist-domains.d/exttool-frag.txt"
printf 'exttool-proxy.example\n' > "$REPO/allowlist-proxy-domains.d/exttool-frag.txt"
echo 'exttool=ON' >> "$CONF"

# ── Generate ─────────────────────────────────────────────────────────────────────
gen_out="$(cd "$REPO" && SANDBOX_CONF="$CONF" bash -c '
  set -euo pipefail
  source ./sandbox-common.sh
  source ./build.sh
  generate_allowlists
' 2>&1)"
gen_rc=$?

[[ "$gen_rc" -eq 0 ]] && pass "generate_allowlists runs to completion" \
                       || fail "generate_allowlists runs to completion (rc=$gen_rc): $gen_out"

DOMAINS="$REPO/allowlist-domains.txt"
PROXY="$REPO/allowlist-proxy-domains.txt"
CIDRS="$REPO/allowlist-cidrs.txt"

[[ -f "$DOMAINS" && -f "$PROXY" && -f "$CIDRS" ]] \
  && pass "all three allowlist output files were generated" \
  || fail "all three allowlist output files were generated"

# ── base.txt always included ────────────────────────────────────────────────────
grep -qxF 'base-domain.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: base.txt is always included" || fail "domains: base.txt is always included"
grep -qxF '10.0.0.0/8' "$CIDRS" 2>/dev/null \
  && pass "cidrs: base.txt is always included" || fail "cidrs: base.txt is always included"

# ── custom.txt included when present ────────────────────────────────────────────
grep -qxF 'custom-domain.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: custom.txt is included when present" || fail "domains: custom.txt is included when present"
grep -qxF 'cidrs-custom.example' "$CIDRS" 2>/dev/null \
  && pass "cidrs: custom.txt is included when present" || fail "cidrs: custom.txt is included when present"
grep -qxF 'proxy-custom.example' "$PROXY" 2>/dev/null \
  && pass "proxy-domains: custom.txt is included when present" || fail "proxy-domains: custom.txt is included when present"

# ── ENABLED component's fragment is included; DISABLED sibling is not ──────────
grep -qxF 'enabled-component.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: an ENABLED component's fragment is included" \
  || fail "domains: an ENABLED component's fragment is included"
grep -qxF 'disabled-component.example' "$DOMAINS" 2>/dev/null \
  && fail "domains: a DISABLED component's fragment must NOT be included" \
  || pass "domains: a DISABLED component's fragment must NOT be included"
grep -qxF 'copilot-cidr.example/32' "$CIDRS" 2>/dev/null \
  && fail "cidrs: a DISABLED component's (copilot=OFF) fragment must NOT be included" \
  || pass "cidrs: a DISABLED component's (copilot=OFF) fragment must NOT be included"

# ── version-keyed component: fragment included only when it HAS versions ──────
grep -qxF 'sdkman.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: version-keyed fragment (sdkman) included when a JVM component has versions" \
  || fail "domains: version-keyed fragment (sdkman) included when a JVM component has versions"
grep -qxF 'openjdk-fragment.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: openjdk.txt included when openjdk has versions" \
  || fail "domains: openjdk.txt included when openjdk has versions"
grep -qxF 'rvm-fragment.example' "$DOMAINS" 2>/dev/null \
  && fail "domains: rvm.txt must NOT be included when ruby has no versions" \
  || pass "domains: rvm.txt must NOT be included when ruby has no versions"

# ── unconditional fragments (no gate) still land ────────────────────────────────
grep -qxF 'nvm.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: unconditional nvm.txt fragment is included" \
  || fail "domains: unconditional nvm.txt fragment is included"
grep -qxF 'pyenv.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: unconditional pyenv.txt fragment is included" \
  || fail "domains: unconditional pyenv.txt fragment is included"

# ── tools.d allowlist_fragment: included only when the tool is ACTIVE ──────────
grep -qxF 'mytool-domain.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: active tool's allowlist_fragment is included" \
  || fail "domains: active tool's allowlist_fragment is included"
grep -qxF 'mytool-proxy.example' "$PROXY" 2>/dev/null \
  && pass "proxy-domains: active tool's allowlist_fragment is included" \
  || fail "proxy-domains: active tool's allowlist_fragment is included"
grep -qxF 'othertool-domain.example' "$DOMAINS" 2>/dev/null \
  && fail "domains: an INACTIVE tool's allowlist_fragment must NOT be included" \
  || pass "domains: an INACTIVE tool's allowlist_fragment must NOT be included"

# install=repo-file changes only HOW the binary is fetched, never the allowlist:
# an active repo-file tool's fragment lands in both families.
grep -qxF 'exttool-domain.example' "$DOMAINS" 2>/dev/null \
  && pass "domains: active repo-file tool's allowlist_fragment is included" \
  || fail "domains: active repo-file tool's allowlist_fragment is included"
grep -qxF 'exttool-proxy.example' "$PROXY" 2>/dev/null \
  && pass "proxy-domains: active repo-file tool's allowlist_fragment is included" \
  || fail "proxy-domains: active repo-file tool's allowlist_fragment is included"

# ── Each output file only gets its OWN fragment family (no cross-family leaks) ──
grep -qxF 'proxy-enabled.example' "$DOMAINS" 2>/dev/null \
  && fail "domains: must not leak proxy-domains.d fragments" \
  || pass "domains: must not leak proxy-domains.d fragments"
grep -qxF 'base-domain.example' "$PROXY" 2>/dev/null \
  && fail "proxy-domains: must not leak allowlist-domains.d/base.txt" \
  || pass "proxy-domains: must not leak allowlist-domains.d/base.txt"
grep -qxF 'base-domain.example' "$CIDRS" 2>/dev/null \
  && fail "cidrs: must not leak allowlist-domains.d fragments" \
  || pass "cidrs: must not leak allowlist-domains.d fragments"
grep -qxF '10.0.0.0/8' "$DOMAINS" 2>/dev/null \
  && fail "domains: must not leak allowlist-cidrs.d fragments" \
  || pass "domains: must not leak allowlist-cidrs.d fragments"

# ── Comments / blank lines pass through verbatim (no filtering at assembly time) ──
# include_fragment is a plain `cat` with no comment/blank stripping — the
# generated file must therefore still carry the fragment's own '#' comment line.
grep -qxF '# base domains' "$DOMAINS" 2>/dev/null \
  && pass "domains: fragment comment lines pass through verbatim" \
  || fail "domains: fragment comment lines pass through verbatim"

# ── Deduplication: two DISTINCT active tools sharing one allowlist_fragment ────
# yield that fragment's content exactly once (active_tool_fragments pipes through
# `sort -u` on fragment NAMES before generate_allowlists includes each by name).
cat > "$REPO/tools.d/thirdtool.conf" <<'EOF'
repo=acme/thirdtool
binary=thirdtool
allowlist_fragment=mytool-frag
EOF
echo 'thirdtool=1.0.0' >> "$CONF"
gen_out2="$(cd "$REPO" && SANDBOX_CONF="$CONF" bash -c '
  set -euo pipefail
  source ./sandbox-common.sh
  source ./build.sh
  generate_allowlists
' 2>&1)"
count="$(grep -cxF 'mytool-domain.example' "$DOMAINS" 2>/dev/null)"
[[ "$count" -eq 1 ]] \
  && pass "domains: a fragment shared by two active tools is included exactly once" \
  || fail "domains: a fragment shared by two active tools is included exactly once (found $count times)"

# ── Header lines are present (sanity: real generated-file shape) ───────────────
grep -q '^# AUTO-GENERATED by build.sh' "$DOMAINS" 2>/dev/null \
  && pass "domains: AUTO-GENERATED header present" || fail "domains: AUTO-GENERATED header present"
grep -q '^# AUTO-GENERATED by build.sh' "$PROXY" 2>/dev/null \
  && pass "proxy-domains: AUTO-GENERATED header present" || fail "proxy-domains: AUTO-GENERATED header present"
grep -q '^# AUTO-GENERATED by build.sh' "$CIDRS" 2>/dev/null \
  && pass "cidrs: AUTO-GENERATED header present" || fail "cidrs: AUTO-GENERATED header present"

# ── include_fragment / include_if_enabled / include_if_has_versions directly ───
# Unit-level check of the three helpers in isolation, beyond their effect on the
# assembled files above.
( cd "$REPO" && SANDBOX_CONF="$CONF" bash -c '
  set -euo pipefail
  source ./sandbox-common.sh
  source ./build.sh
  out1="$(include_fragment "allowlist-domains.d/base.txt")"
  [[ "$out1" == *"base-domain.example"* ]] && echo "PASS: include_fragment cats an existing fragment" \
    || echo "FAIL: include_fragment cats an existing fragment"
  out2="$(include_fragment "allowlist-domains.d/does-not-exist.txt")"
  [[ -z "$out2" ]] && echo "PASS: include_fragment is silent for a missing fragment" \
    || echo "FAIL: include_fragment is silent for a missing fragment"
  out3="$(include_if_enabled "allowlist-domains.d/github-cli.txt" github-cli)"
  [[ "$out3" == *"enabled-component.example"* ]] && echo "PASS: include_if_enabled includes when the component is ON" \
    || echo "FAIL: include_if_enabled includes when the component is ON"
  out4="$(include_if_enabled "allowlist-domains.d/github-copilot.txt" copilot)"
  [[ -z "$out4" ]] && echo "PASS: include_if_enabled excludes when the component is OFF" \
    || echo "FAIL: include_if_enabled excludes when the component is OFF"
  out5="$(include_if_has_versions "allowlist-domains.d/sdkman.txt" openjdk graalvm-ce graalvm-oracle kotlin scala maven gradle)"
  [[ "$out5" == *"sdkman.example"* ]] && echo "PASS: include_if_has_versions includes when a key in the group has versions" \
    || echo "FAIL: include_if_has_versions includes when a key in the group has versions"
  out6="$(include_if_has_versions "allowlist-domains.d/rvm.txt" ruby)"
  [[ -z "$out6" ]] && echo "PASS: include_if_has_versions excludes when no key in the group has versions" \
    || echo "FAIL: include_if_has_versions excludes when no key in the group has versions"
' ) > "$TMP/helpers.out" 2>&1
cat "$TMP/helpers.out"
fails=$(( fails + $(grep -c '^FAIL' "$TMP/helpers.out") ))

# ── Hermeticity: the real repo's allowlist-*.txt build output was never touched ──
REAL_TXT_AFTER="$(real_txt_fingerprint)"
[[ "$REAL_TXT_BEFORE" == "$REAL_TXT_AFTER" ]] \
  && pass "real repo's allowlist-*.txt files were never regenerated" \
  || fail "real repo's allowlist-*.txt files were never regenerated"

printf '\n%d failure(s)\n' "$fails"
exit "$([[ "$fails" -eq 0 ]] && echo 0 || echo 1)"
