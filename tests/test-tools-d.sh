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

# --- install=repo-file + multi-path config_dir ----------------------------------
# A descriptor for a tool whose prebuilt binary is COMMITTED IN a repo instead of
# published as a release asset, and whose state spans two directories.
cat > "$TOOLS_D_DIR/ext.conf" <<'EOF'
repo=acme/vendored
binary=ext-cli
install=repo-file
repo_path=utils/ext/ext-cli-linux-${ARCH}
ref=main
config_dir=.ext .config/ext-cli
EOF
tools_read_descriptor ext
[[ "$TOOL_install" == "repo-file" ]] && pass "install parsed" || fail "install parsed ($TOOL_install)"
[[ "$TOOL_repo_path" == 'utils/ext/ext-cli-linux-${ARCH}' ]] \
  && pass "repo_path parsed verbatim (\${ARCH} not expanded at parse time)" \
  || fail "repo_path parsed ($TOOL_repo_path)"
[[ "$TOOL_ref" == "main" ]] && pass "ref parsed" || fail "ref parsed ($TOOL_ref)"
[[ "$TOOL_config_dir" == ".ext .config/ext-cli" ]] \
  && pass "config_dir keeps a space-separated list" || fail "config_dir list ($TOOL_config_dir)"
got="$(set -- $TOOL_config_dir; printf '%s|' "$@")"
[[ "$got" == ".ext|.config/ext-cli|" ]] \
  && pass "config_dir splits into 2 paths" || fail "config_dir splits ($got)"
tools_read_descriptor foo
[[ "$TOOL_install" == "release" ]] && pass "install defaults to release" || fail "install default ($TOOL_install)"
[[ -z "$TOOL_repo_path" && -z "$TOOL_ref" ]] && pass "repo_path/ref do not leak" || fail "repo_path/ref leak"
rm -f "$TOOLS_D_DIR/ext.conf"

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

# --- ARCH resolution --------------------------------------------------------------
# Both fetch modes key off ARCH: asset_name embeds it, and repo_path may template
# ${ARCH}. A wrong value installs a binary for the wrong machine and only fails at
# runtime with "cannot execute binary file", so pin the uname mapping. ARCH comes
# from `uname -m` INSIDE the build container, i.e. the image's own platform.
for _pair in "x86_64:amd64" "aarch64:arm64"; do
  _u="${_pair%%:*}"; _want="${_pair##*:}"
  mkdir -p "$TMP/un-$_u"
  printf '#!/usr/bin/env bash\nif [[ "$1" == "-s" ]]; then echo Linux; else echo %s; fi\n' "$_u" \
    > "$TMP/un-$_u/uname"
  chmod +x "$TMP/un-$_u/uname"
  _got="$(PATH="$TMP/un-$_u:$PATH" TOOLS_LIB="$REPO_DIR/tools-lib.sh" \
    bash -c 'unset ARCH OS; source "$TOOLS_LIB"; source '"$REPO_DIR"'/install-tools.sh; printf "%s/%s" "$OS" "$ARCH"')"
  [[ "$_got" == "linux/$_want" ]] \
    && pass "ARCH: uname -m $_u -> $_want" || fail "ARCH: uname -m $_u -> $_got (want linux/$_want)"
done

got="$(parse_versions 'dtctl=0.25.0;toolx=latest;empty=' | tr '\t' ':' | tr '\n' ' ')"
[[ "$got" == "dtctl:0.25.0 toolx:latest empty: " ]] \
  && pass "parse_versions" || fail "parse_versions ($got)"

# --- install=repo-file fetch (fake curl; nothing leaves the machine) -----------
cat > "$TOOLS_D_DIR/ext.conf" <<'EOF'
repo=acme/vendored
binary=ext-cli
install=repo-file
repo_path=utils/ext/ext-cli-linux-${ARCH}
EOF
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
CURL_LOG="$TMP/curl.log"
cat > "$FAKEBIN/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$CURL_LOG"
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
[[ -n "\$out" ]] && printf 'ELF-ish payload\n' > "\$out"
exit 0
CURL
chmod +x "$FAKEBIN/curl"

# BIN_DIR is resolved from TOOLS_BIN_DIR when install-tools.sh is SOURCED (which
# already happened above), so set the in-scope variable directly. Belt and braces:
# also export TOOLS_BIN_DIR for anything that re-reads it.
export TOOLS_BIN_DIR="$TMP/bin"; mkdir -p "$TOOLS_BIN_DIR"
BIN_DIR="$TOOLS_BIN_DIR"
: > "$CURL_LOG"
out="$(PATH="$FAKEBIN:$PATH" ARCH=arm64 install_one ext latest 2>&1)"
if grep -q 'https://api.github.com/repos/acme/vendored/contents/utils/ext/ext-cli-linux-arm64$' "$CURL_LOG"; then
  pass "repo-file: contents API URL built, \${ARCH} expanded, no ref for latest"
else
  fail "repo-file URL ($(grep '^https' "$CURL_LOG" | head -1))"; fi
if grep -qx 'Accept: application/vnd.github.raw' "$CURL_LOG"; then
  pass "repo-file: raw media type requested"; else fail "repo-file: raw media type requested"; fi
if [[ -x "$TOOLS_BIN_DIR/ext-cli" ]]; then
  pass "repo-file: binary installed executable"; else fail "repo-file: binary installed executable"; fi

# An explicit ref (from the sandbox.conf value) must reach the URL.
: > "$CURL_LOG"; rm -f "$TOOLS_BIN_DIR/ext-cli"
PATH="$FAKEBIN:$PATH" ARCH=amd64 install_one ext 9f3c1ab >/dev/null 2>&1
if grep -q 'contents/utils/ext/ext-cli-linux-amd64?ref=9f3c1ab$' "$CURL_LOG"; then
  pass "repo-file: sandbox.conf value used as git ref"; else fail "repo-file ref ($(grep '^https' "$CURL_LOG" | head -1))"; fi

# The descriptor's own ref= is the default when the key is just ON (latest).
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext/ext-cli\nref=release-1\n' \
  > "$TOOLS_D_DIR/ext.conf"
: > "$CURL_LOG"; rm -f "$TOOLS_BIN_DIR/ext-cli"
PATH="$FAKEBIN:$PATH" install_one ext latest >/dev/null 2>&1
if grep -q 'contents/utils/ext/ext-cli?ref=release-1$' "$CURL_LOG"; then
  pass "repo-file: descriptor ref= is the default for ON"; else fail "repo-file descriptor ref ($(grep '^https' "$CURL_LOG" | head -1))"; fi

# A private repo-file tool with no token must skip BEFORE any curl.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nprivate=yes\nrepo_path=utils/ext/ext-cli\n' \
  > "$TOOLS_D_DIR/ext.conf"
: > "$CURL_LOG"; rm -f "$TOOLS_BIN_DIR/ext-cli"
out="$( unset GITHUB_TOKEN; PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1 )"
if [[ "$out" == *"requires GITHUB_TOKEN"* ]] && [[ ! -s "$CURL_LOG" ]] && [[ ! -e "$TOOLS_BIN_DIR/ext-cli" ]]; then
  pass "repo-file: private with no token skips before any fetch"
else
  fail "repo-file private/no-token guard"; fi

# A failed download must warn and install NOTHING. Until this case existed every
# fake curl in this file exited 0, so a "report success on failure" bug was
# invisible by construction.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext/ext-cli\n' > "$TOOLS_D_DIR/ext.conf"
cat > "$FAKEBIN/curl" <<'CURLFAIL'
#!/usr/bin/env bash
exit 22   # what curl -f returns for an HTTP 4xx
CURLFAIL
chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/ext-cli"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"download failed"* ]] && [[ "$out" != *"Installed ext"* ]] && [[ ! -e "$BIN_DIR/ext-cli" ]]; then
  pass "repo-file: failed download warns and installs nothing"
else
  fail "repo-file: failed download ($out)"; fi
# ... and leaves no temp file behind.
if ! ls "${TMPDIR:-/tmp}"/ext-cli.* >/dev/null 2>&1; then
  pass "repo-file: failed download leaves no temp file"; else fail "repo-file: failed download leaves no temp file"; fi

# A JSON payload (what the contents API returns for a DIRECTORY path) must NOT be
# installed as the binary — curl -f cannot tell it from a file.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext\n' > "$TOOLS_D_DIR/ext.conf"
cat > "$FAKEBIN/curl" <<'CURLJSON'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] && printf '[{"name":"ext-cli-linux-arm64","type":"file"}]\n' > "$out"
exit 0
CURLJSON
chmod +x "$FAKEBIN/curl"
rm -f "$BIN_DIR/ext-cli"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"returned JSON"* ]] && [[ ! -e "$BIN_DIR/ext-cli" ]]; then
  pass "repo-file: JSON payload (directory path) rejected"; else fail "repo-file: JSON payload rejected ($out)"; fi

# An unwritable install dir must warn, not claim success.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\nrepo_path=utils/ext/ext-cli\n' > "$TOOLS_D_DIR/ext.conf"
cat > "$FAKEBIN/curl" <<'CURLOK'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] && printf 'payload\n' > "$out"
exit 0
CURLOK
chmod +x "$FAKEBIN/curl"
_saved_bin="$BIN_DIR"; BIN_DIR="$TMP/nonexistent-dir/bin"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"could not install"* ]] && [[ "$out" != *"Installed ext"* ]]; then
  pass "repo-file: unwritable install dir warns instead of claiming success"
else
  fail "repo-file: unwritable install dir ($out)"; fi
BIN_DIR="$_saved_bin"

# A repo-file descriptor missing repo_path warns instead of building a bad URL.
printf 'repo=acme/vendored\nbinary=ext-cli\ninstall=repo-file\n' > "$TOOLS_D_DIR/ext.conf"
: > "$CURL_LOG"
out="$(PATH="$FAKEBIN:$PATH" install_one ext latest 2>&1)"
if [[ "$out" == *"repo_path"* ]] && [[ ! -s "$CURL_LOG" ]]; then
  pass "repo-file: missing repo_path warns, no fetch"; else fail "repo-file missing repo_path ($out)"; fi
# Nothing may have leaked into the image's real install dir.
[[ ! -e /usr/local/bin/ext-cli ]] \
  && pass "repo-file: test never wrote to the real /usr/local/bin" \
  || fail "repo-file: test never wrote to the real /usr/local/bin"
unset TOOLS_BIN_DIR; BIN_DIR=/usr/local/bin
rm -f "$TOOLS_D_DIR/ext.conf"

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

# Every agent key must be reachable: with only OFF fixtures, dropping a key from
# the function's own list would go unnoticed. Flip each one ON in turn.
for _agent in claude-code copilot codex gemini kiro; do
  printf 'claude-code=OFF\ncopilot=OFF\ncodex=OFF\ngemini=OFF\nkiro=OFF\n' > "$CONF"
  conf_set() { sed -i.bak "s/^${1}=OFF/${1}=ON/" "$CONF" && rm -f "$CONF.bak"; }
  conf_set "$_agent"
  [[ "$(enabled_agents_csv)" == "$_agent" ]] \
    && pass "enabled_agents_csv: $_agent alone" \
    || fail "enabled_agents_csv: $_agent alone ($(enabled_agents_csv))"
done
# All five together, to pin the order the container relies on.
printf 'claude-code=ON\ncopilot=ON\ncodex=ON\ngemini=ON\nkiro=ON\n' > "$CONF"
[[ "$(enabled_agents_csv)" == "claude-code,copilot,codex,gemini,kiro" ]] \
  && pass "enabled_agents_csv: all five, stable order" \
  || fail "enabled_agents_csv: all five ($(enabled_agents_csv))"
# Restore the fixture the later build.sh assertions append to.
printf 'claude-code=ON\ncopilot=ON\ncodex=OFF\ngemini=OFF\nkiro=OFF\n' > "$CONF"

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

# Dedup: two DISTINCT active tools naming the same fragment must yield it once
# (the case sort -u exists for — dtctl and dtmgd both use `dynatrace`). Isolated
# in a subshell with its own TOOLS_D_DIR/SANDBOX_CONF so the main fixture is untouched.
_ddir="$TMP/dedup.d"; mkdir -p "$_ddir"
printf 'allowlist_fragment=shared\n' > "$_ddir/aa.conf"
printf 'allowlist_fragment=shared\n' > "$_ddir/bb.conf"
printf 'aa=ON\nbb=ON\n' > "$TMP/dedup.conf"
dedup_out="$(TOOLS_D_DIR="$_ddir" SANDBOX_CONF="$TMP/dedup.conf" bash -c '
  source "'"$REPO_DIR"'/sandbox-common.sh"; source "'"$REPO_DIR"'/build.sh"
  active_tool_fragments' | tr '\n' ' ')"
[[ "$dedup_out" == "shared " ]] && pass "active_tool_fragments dedup" || fail "active_tool_fragments dedup ($dedup_out)"


# foo is private + no token → preflight must warn on stderr, non-fatally.
( unset GITHUB_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; preflight_private_tools ) 2>"$TMP/pf.err"
grep -q "PRIVATE tool is enabled" "$TMP/pf.err" && pass "preflight warns" || fail "preflight warns"

# --- sandbox.sh group-scoped tool config + AI_AGENTS_ENABLED ---------------------
RTMP="$(mktemp -d)"
export HOME="$RTMP/home"; mkdir -p "$HOME/.config/dtctl"; echo hostcfg > "$HOME/.config/dtctl/config"
export AI_CONTAINER_GROUP_INIT=clean
unset VAULT_PATH SPECS_PATH DOCS_PATH
unset TOOLS_D_DIR   # earlier sections in this file point it at a synthetic foo/bar
                    # dir; sandbox.sh must resolve the real repo tools.d (dtctl/dtmgd).
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
PATH="$RTMP/bin:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$RTMP" "$REPO_DIR/sandbox.sh" restricted "$RTMP/app" \
  >/dev/null 2>&1 </dev/null || true

grep -q "\.ai-containers/.*/\.config/dtctl:" "$CAP" && pass "dtctl config mounted from group" || fail "dtctl config mount"
grep -qx "AI_AGENTS_ENABLED=claude-code" "$CAP" && pass "AI_AGENTS_ENABLED passed" || fail "AI_AGENTS_ENABLED"
# Seed: group copy created from host, containing the host's file.
GROOT="$HOME/.ai-containers"
find "$GROOT" -path '*/.config/dtctl/config' | grep -q . && pass "group dtctl seeded from host" || fail "seed from host"

# Second run: group dir already exists → must NOT be re-seeded (group state wins).
# Prove it by changing the host file and confirming the group copy is untouched.
echo hostcfg-changed > "$HOME/.config/dtctl/config"
PATH="$RTMP/bin:$PATH" bash -c 'cd "$1" && shift && exec bash "$@"' _ "$RTMP" "$REPO_DIR/sandbox.sh" restricted "$RTMP/app" \
  >/dev/null 2>&1 </dev/null || true
GROUP_CFG="$(find "$GROOT" -path '*/.config/dtctl/config' | head -n1)"
[[ -n "$GROUP_CFG" ]] && [[ "$(cat "$GROUP_CFG")" == "hostcfg" ]] \
  && pass "group dtctl not re-seeded on second run" || fail "group dtctl not re-seeded on second run"
rm -rf "$RTMP"

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
