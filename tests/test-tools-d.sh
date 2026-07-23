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

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
