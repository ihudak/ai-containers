#!/usr/bin/env bash
# Unit tests for tools-lib.sh descriptor parsing.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TOOLS_D_DIR="$TMP/tools.d"; mkdir -p "$TOOLS_D_DIR"
cat > "$TOOLS_D_DIR/foo.conf" <<'EOF'
repo=acme/foo
binary=foo
private=yes
config_dir=.config/foo
allowlist_fragment=acme
skills=yes
skills_crossclient=--for cross-client   # inline comment ignored
EOF
cat > "$TOOLS_D_DIR/bar.conf" <<'EOF'
repo=acme/bar
EOF

# shellcheck source=/dev/null
source "$REPO_DIR/tools-lib.sh"

names="$(tools_list_names | sort | tr '\n' ' ')"
[[ "$names" == "bar foo " ]] && pass "list names" || fail "list names ($names)"

tools_read_descriptor foo
[[ "$TOOL_repo" == "acme/foo" ]] && pass "repo" || fail "repo ($TOOL_repo)"
[[ "$TOOL_private" == "yes" ]] && pass "private" || fail "private"
[[ "$TOOL_config_dir" == ".config/foo" ]] && pass "config_dir" || fail "config_dir"
[[ "$TOOL_skills_crossclient" == "--for cross-client" ]] && pass "crossclient trims comment" || fail "crossclient ($TOOL_skills_crossclient)"

# Defaults + reset: bar omits everything; binary defaults to name, private to no,
# and foo's values must not leak.
tools_read_descriptor bar
[[ "$TOOL_binary" == "bar" ]] && pass "binary default" || fail "binary default ($TOOL_binary)"
[[ "$TOOL_private" == "no" ]] && pass "private default" || fail "private default"
[[ -z "$TOOL_config_dir" ]] && pass "no leak" || fail "no leak ($TOOL_config_dir)"

tools_read_descriptor missing && fail "missing returns 0" || pass "missing returns 1"

# Real descriptors: pin the dtctl/dtmgd cross-client invocations, which differ
# by a subtle space (--cross-client vs --for cross-client). Field-level, not
# list-level, so this holds in repos that ship additional descriptors.
_saved_td="$TOOLS_D_DIR"; export TOOLS_D_DIR="$REPO_DIR/tools.d"
tools_read_descriptor dtctl
[[ "$TOOL_repo" == "dynatrace-oss/dtctl" && "$TOOL_skills_crossclient" == "--cross-client" ]] \
  && pass "dtctl descriptor" || fail "dtctl descriptor ($TOOL_repo / $TOOL_skills_crossclient)"
tools_read_descriptor dtmgd
[[ "$TOOL_repo" == "dynatrace-oss/dtmgd" && "$TOOL_skills_crossclient" == "--for cross-client" ]] \
  && pass "dtmgd descriptor" || fail "dtmgd descriptor ($TOOL_repo / $TOOL_skills_crossclient)"
export TOOLS_D_DIR="$_saved_td"

# --- install-tools.sh pure helpers ---------------------------------------------
export TOOLS_LIB="$REPO_DIR/tools-lib.sh"
OS=linux ARCH=amd64
# shellcheck source=/dev/null
source "$REPO_DIR/install-tools.sh"   # sourced, not executed (guarded main)

[[ "$(asset_name dtctl v0.25.0)" == "dtctl_0.25.0_linux_amd64.tar.gz" ]] \
  && pass "asset_name" || fail "asset_name ($(asset_name dtctl v0.25.0))"

got="$(parse_versions 'dtctl=0.25.0;toolx=latest;empty=' | tr '\t' ':' | tr '\n' ' ')"
[[ "$got" == "dtctl:0.25.0 toolx:latest empty: " ]] \
  && pass "parse_versions" || fail "parse_versions ($got)"

# --- enabled_agents_csv --------------------------------------------------------
CONF="$TMP/sandbox.conf"
cat > "$CONF" <<'EOF'
claude-code=ON
copilot=ON
codex=OFF
gemini=OFF
kiro=OFF
EOF
export SANDBOX_CONF="$CONF"
# shellcheck source=/dev/null
source "$REPO_DIR/sandbox-common.sh"
[[ "$(enabled_agents_csv)" == "claude-code,copilot" ]] \
  && pass "enabled_agents_csv" || fail "enabled_agents_csv ($(enabled_agents_csv))"

# --- build.sh pure helpers -----------------------------------------------------
# Reuse the earlier foo(private)/bar descriptors; enable foo (pinned) + bar (ON).
cat >> "$CONF" <<'EOF'
foo=1.2.3
bar=ON
EOF
# shellcheck source=/dev/null
source "$REPO_DIR/build.sh"   # guarded: sourcing must not build
set +e   # build.sh's `set -euo pipefail` leaks into this file via source; restore
         # this suite's intended mode so later non-idiom lines can't abort it.

tv="$(tool_versions_arg)"
[[ "$tv" == *"foo=1.2.3"* && "$tv" == *"bar=latest"* ]] \
  && pass "tool_versions_arg" || fail "tool_versions_arg ($tv)"

frags="$(active_tool_fragments | tr '\n' ' ')"
[[ "$frags" == *"acme"* ]] && pass "active_tool_fragments" || fail "active_tool_fragments ($frags)"

# foo is private + no token → preflight must warn on stderr, non-fatally.
( unset GITHUB_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; preflight_private_tools ) 2>"$TMP/pf.err"
grep -q "PRIVATE tool is enabled" "$TMP/pf.err" && pass "preflight warns" || fail "preflight warns"

# --- runme.sh group-scoped tool config + AI_AGENTS_ENABLED ---------------------
RTMP="$(mktemp -d)"
export HOME="$RTMP/home"; mkdir -p "$HOME/.config/dtctl"; echo hostcfg > "$HOME/.config/dtctl/config"
export AI_CONTAINER_GROUP_INIT=clean
unset VAULT_PATH SPECS_PATH DOCS_PATH
unset TOOLS_D_DIR   # earlier sections in this file point it at a synthetic foo/bar
                    # dir; runme.sh must resolve the real repo tools.d (dtctl/dtmgd).
RCONF="$RTMP/sandbox.conf"
cat > "$RCONF" <<'EOF'
claude-code=ON
copilot=OFF
codex=OFF
gemini=OFF
kiro=OFF
dtctl=0.25.0
dtmgd=OFF
EOF
export SANDBOX_CONF="$RCONF"
mkdir -p "$RTMP/bin" "$RTMP/app"; CAP="$RTMP/args.txt"
cat > "$RTMP/bin/docker" <<DOCKER
#!/usr/bin/env bash
if [[ "\$1" == "run" ]]; then shift; printf '%s\n' "\$@" > "$CAP"; exit 0; fi
exit 1
DOCKER
chmod +x "$RTMP/bin/docker"
PATH="$RTMP/bin:$PATH" bash "$REPO_DIR/runme.sh" restricted "$RTMP/app" \
  >/dev/null 2>&1 </dev/null || true

grep -q "/.config/dtctl:" "$CAP" && pass "dtctl config mounted from group" || fail "dtctl config mount"
grep -qx "AI_AGENTS_ENABLED=claude-code" "$CAP" && pass "AI_AGENTS_ENABLED passed" || fail "AI_AGENTS_ENABLED"
# Seed: group copy created from host, containing the host's file.
GROOT="$HOME/.ai-containers"
find "$GROOT" -path '*/.config/dtctl/config' | grep -q . && pass "group dtctl seeded from host" || fail "seed from host"

# Second run: group dir already exists → must NOT be re-seeded (group state wins).
# Prove it by changing the host file and confirming the group copy is untouched.
echo hostcfg-changed > "$HOME/.config/dtctl/config"
PATH="$RTMP/bin:$PATH" bash "$REPO_DIR/runme.sh" restricted "$RTMP/app" \
  >/dev/null 2>&1 </dev/null || true
GROUP_CFG="$(find "$GROOT" -path '*/.config/dtctl/config' | head -n1)"
[[ -n "$GROUP_CFG" ]] && [[ "$(cat "$GROUP_CFG")" == "hostcfg" ]] \
  && pass "group dtctl not re-seeded on second run" || fail "group dtctl not re-seeded on second run"
rm -rf "$RTMP"

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
